{-# LANGUAGE DuplicateRecordFields #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Contains the a state-ful interface to transaction construction and observation.
--
-- It defines the 'ChainStateType tx' to be used in the 'Hydra.Chain.Direct'
-- layer and it's constituents.
module Hydra.Chain.Direct.State where

import Hydra.Prelude hiding (init)

import Cardano.Api.UTxO qualified as UTxO
import Data.List ((\\))
import Data.Map qualified as Map
import Data.Maybe (fromJust)
import Hydra.Cardano.Api (
  AssetId (..),
  AssetName (AssetName),
  ChainPoint (..),
  CtxUTxO,
  Key (SigningKey, VerificationKey, verificationKeyHash),
  KeyWitnessInCtx (..),
  NetworkId (Mainnet, Testnet),
  NetworkMagic (NetworkMagic),
  PaymentKey,
  PlutusScriptV2,
  Quantity (..),
  SerialiseAsRawBytes (serialiseToRawBytes),
  SlotNo (SlotNo),
  Tx,
  TxIn,
  TxOut,
  UTxO,
  UTxO' (UTxO),
  WitCtxTxIn,
  Witness,
  chainPointToSlotNo,
  fromPlutusScript,
  genTxIn,
  isScriptTxOut,
  modifyTxOutValue,
  selectAsset,
  selectLovelace,
  txIns',
  txOutReferenceScript,
  txOutValue,
  valueFromList,
  valueToList,
  pattern ByronAddressInEra,
  pattern KeyWitness,
  pattern ReferenceScript,
  pattern ReferenceScriptNone,
  pattern ShelleyAddressInEra,
  pattern TxOut,
 )
import Hydra.Chain (
  ChainStateType,
  HeadParameters (..),
  IsChainState (..),
  OnChainTx (..),
  PostTxError (..),
  maxMainnetLovelace,
  maximumNumberOfParties,
 )
import Hydra.Chain.Direct.ScriptRegistry (
  ScriptRegistry (..),
  genScriptRegistry,
  registryUTxO,
 )
import Hydra.Chain.Direct.TimeHandle (PointInTime)
import Hydra.Chain.Direct.Tx (
  AbortObservation (AbortObservation),
  AbortTxError (..),
  CloseObservation (..),
  CloseTxError (..),
  ClosedThreadOutput (..),
  ClosingSnapshot (..),
  CollectComObservation (..),
  CommitObservation (..),
  ContestObservation (..),
  ContestTxError (..),
  FanoutObservation (FanoutObservation),
  InitObservation (..),
  InitialThreadOutput (..),
  NotAnInit (..),
  OpenThreadOutput (..),
  UTxOHash (UTxOHash),
  abortTx,
  closeTx,
  collectComTx,
  commitTx,
  contestTx,
  fanoutTx,
  headIdToPolicyId,
  initTx,
  observeAbortTx,
  observeCloseTx,
  observeCollectComTx,
  observeCommitTx,
  observeContestTx,
  observeFanoutTx,
  observeInitTx,
  observeRawInitTx,
  txInToHeadSeed,
 )
import Hydra.ContestationPeriod (ContestationPeriod)
import Hydra.ContestationPeriod qualified as ContestationPeriod
import Hydra.Contract.Commit qualified as Commit
import Hydra.Contract.Head qualified as Head
import Hydra.Contract.HeadTokens (headPolicyId, mkHeadTokenScript)
import Hydra.Contract.Initial qualified as Initial
import Hydra.Crypto (HydraKey)
import Hydra.HeadId (HeadId (..))
import Hydra.Ledger (ChainSlot (ChainSlot), IsTx (hashUTxO))
import Hydra.Ledger.Cardano (genOneUTxOFor, genUTxOAdaOnlyOfSize, genVerificationKey)
import Hydra.Ledger.Cardano.Evaluate (genPointInTimeBefore, genValidityBoundsFromContestationPeriod, slotNoFromUTCTime)
import Hydra.Ledger.Cardano.Json ()
import Hydra.Party (Party, deriveParty)
import Hydra.Party qualified as Party
import Hydra.Plutus.Extras (posixToUTCTime)
import Hydra.Snapshot (
  ConfirmedSnapshot (..),
  Snapshot (..),
  SnapshotNumber,
  genConfirmedSnapshot,
  getSnapshot,
 )
import Test.QuickCheck (choose, frequency, oneof, sized, vector)
import Test.QuickCheck.Gen (elements)
import Test.QuickCheck.Modifiers (Positive (Positive))

-- | A class for accessing the known 'UTxO' set in a type. This is useful to get
-- all the relevant UTxO for resolving transaction inputs.
class HasKnownUTxO a where
  getKnownUTxO :: a -> UTxO

-- * States & transitions

-- | The chain state used by the Hydra.Chain.Direct implementation. It records
-- the actual 'ChainState' paired with a 'ChainSlot' (used to know up to which
-- point to rewind on rollbacks).
data ChainStateAt = ChainStateAt
  { chainState :: UTxO
  , recordedAt :: Maybe ChainPoint
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Arbitrary ChainStateAt where
  arbitrary = genericArbitrary
  shrink = genericShrink

instance IsChainState Tx where
  type ChainStateType Tx = ChainStateAt

  chainStateSlot ChainStateAt{recordedAt} =
    maybe (ChainSlot 0) chainSlotFromPoint recordedAt

-- | Get a generic 'ChainSlot' from a Cardano 'ChainPoint'. Slot 0 is used for
-- the genesis point.
chainSlotFromPoint :: ChainPoint -> ChainSlot
chainSlotFromPoint p =
  case chainPointToSlotNo p of
    Nothing -> ChainSlot 0
    Just (SlotNo s) -> ChainSlot $ fromIntegral s

-- | A definition of all transitions between 'ChainState's. Enumerable and
-- bounded to be used as labels for checking coverage.
data ChainTransition
  = Init
  | Abort
  | Commit
  | Collect
  | Close
  | Contest
  | Fanout
  deriving stock (Eq, Show, Enum, Bounded)

-- | An enumeration of all possible on-chain states of a Hydra Head, where each
-- case stores the relevant information to construct & observe transactions to
-- other states.
data ChainState
  = -- | The idle state does not contain any head-specific information and exists to
    -- be used as a starting and terminal state.
    Idle
  | Initial InitialState
  | Open OpenState
  | Closed ClosedState
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Arbitrary ChainState where
  arbitrary = genChainState
  shrink = genericShrink

instance HasKnownUTxO ChainState where
  getKnownUTxO :: ChainState -> UTxO
  getKnownUTxO = \case
    Idle -> mempty
    Initial st -> getKnownUTxO st
    Open st -> getKnownUTxO st
    Closed st -> getKnownUTxO st

-- | Defines the starting state of the direct chain layer.
initialChainState :: ChainStateType Tx
initialChainState =
  ChainStateAt
    { chainState = mempty
    , recordedAt = Nothing
    }

-- | Read-only chain-specific data. This is different to 'HydraContext' as it
-- only contains data known to single peer.
data ChainContext = ChainContext
  { networkId :: NetworkId
  , peerVerificationKeys :: [VerificationKey PaymentKey]
  , ownVerificationKey :: VerificationKey PaymentKey
  , ownParty :: Party
  , otherParties :: [Party]
  , scriptRegistry :: ScriptRegistry
  , contestationPeriod :: ContestationPeriod
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance HasKnownUTxO ChainContext where
  getKnownUTxO ChainContext{scriptRegistry} = registryUTxO scriptRegistry

instance Arbitrary ChainContext where
  arbitrary = sized $ \n -> do
    networkId <- Testnet . NetworkMagic <$> arbitrary
    peerVerificationKeys <- replicateM n genVerificationKey
    ownVerificationKey <- genVerificationKey
    otherParties <- arbitrary
    ownParty <- elements otherParties
    scriptRegistry <- genScriptRegistry
    contestationPeriod <- arbitrary
    pure
      ChainContext
        { networkId
        , peerVerificationKeys
        , ownVerificationKey
        , ownParty
        , otherParties
        , scriptRegistry
        , contestationPeriod
        }

-- | Get all cardano verification keys available in the chain context.
allVerificationKeys :: ChainContext -> [VerificationKey PaymentKey]
allVerificationKeys ChainContext{peerVerificationKeys, ownVerificationKey} =
  ownVerificationKey : peerVerificationKeys

-- | Get all hydra verification keys available in the chain context.
allParties :: ChainContext -> [Party]
allParties ChainContext{ownParty, otherParties} =
  ownParty : otherParties

data InitialState = InitialState
  { initialThreadOutput :: InitialThreadOutput
  , initialInitials :: [(TxIn, TxOut CtxUTxO)]
  , initialCommits :: [(TxIn, TxOut CtxUTxO)]
  , headId :: HeadId
  , seedTxIn :: TxIn
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Arbitrary InitialState where
  arbitrary = do
    ctx <- genHydraContext maxGenParties
    snd <$> genStInitial ctx

  shrink = genericShrink

instance HasKnownUTxO InitialState where
  getKnownUTxO st =
    UTxO $
      Map.fromList $
        initialThreadUTxO : initialCommits <> initialInitials
   where
    InitialState
      { initialThreadOutput = InitialThreadOutput{initialThreadUTxO}
      , initialInitials
      , initialCommits
      } = st

data OpenState = OpenState
  { openThreadOutput :: OpenThreadOutput
  , headId :: HeadId
  , seedTxIn :: TxIn
  , openUtxoHash :: UTxOHash
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Arbitrary OpenState where
  arbitrary = do
    ctx <- genHydraContext maxGenParties
    snd <$> genStOpen ctx

  shrink = genericShrink

instance HasKnownUTxO OpenState where
  getKnownUTxO st =
    UTxO.singleton openThreadUTxO
   where
    OpenState
      { openThreadOutput = OpenThreadOutput{openThreadUTxO}
      } = st

data ClosedState = ClosedState
  { closedThreadOutput :: ClosedThreadOutput
  , headId :: HeadId
  , seedTxIn :: TxIn
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

instance Arbitrary ClosedState where
  arbitrary = do
    -- XXX: Untangle the whole generator mess here
    (_, st, _) <- genFanoutTx maxGenParties maxGenAssets
    pure st

  shrink = genericShrink

instance HasKnownUTxO ClosedState where
  getKnownUTxO st =
    UTxO.singleton closedThreadUTxO
   where
    ClosedState
      { closedThreadOutput = ClosedThreadOutput{closedThreadUTxO}
      } = st

-- * Constructing transactions

-- | Construct an init transaction given some general 'ChainContext', the
-- 'HeadParameters' and a seed 'TxIn' which will be spent.
initialize ::
  ChainContext ->
  HeadParameters ->
  -- | Seed input.
  TxIn ->
  Tx
initialize ctx =
  initTx networkId (allVerificationKeys ctx)
 where
  ChainContext{networkId} = ctx

-- | Construct a commit transaction based on known, spendable UTxO and some
-- arbitrary UTxOs to commit. This does look for "our initial output" to spend
-- and check the given 'UTxO' to be compatible. Hence, this function does fail
-- if already committed or if the head is not initializing.
--
-- NOTE: This version of 'commit' does only commit outputs which are held by
-- payment keys. For a variant which supports committing scripts, see `commit'`.
commit ::
  ChainContext ->
  HeadId ->
  -- | Spendable 'UTxO'
  UTxO ->
  -- | 'UTxO' to commit. All outputs are assumed to be owned by public keys.
  UTxO ->
  Either (PostTxError Tx) Tx
commit ctx headId spendableUTxO utxoToCommit =
  commit' ctx headId spendableUTxO $ utxoToCommit <&> (,KeyWitness KeyWitnessForSpending)

-- | Construct a commit transaction based on known, spendable UTxO and some
-- arbitrary UTxOs to commit. This does look for "our initial output" to spend
-- and check the given 'UTxO' to be compatible. Hence, this function does fail
-- if already committed or if the head is not initializing.
--
-- NOTE: A simpler variant only supporting pubkey outputs is 'commit'.
commit' ::
  ChainContext ->
  HeadId ->
  -- | Spendable 'UTxO'
  UTxO ->
  -- | 'UTxO' to commit, along with witnesses to spend them.
  UTxO' (TxOut CtxUTxO, Witness WitCtxTxIn) ->
  Either (PostTxError Tx) Tx
commit' ctx headId spendableUTxO utxoToCommit = do
  case ownInitial of
    Nothing ->
      Left (CannotFindOwnInitial{knownUTxO = spendableUTxO})
    Just (i, o) -> do
      let utxo = fst <$> utxoToCommit
      rejectByronAddress utxo
      rejectReferenceScripts utxo
      rejectMoreThanMainnetLimit networkId utxo
      pure $ commitTx networkId scriptRegistry headId ownParty utxoToCommit (i, o, vkh)
 where
  ChainContext{networkId, ownParty, scriptRegistry, ownVerificationKey} = ctx

  vkh = verificationKeyHash ownVerificationKey

  ownInitial =
    UTxO.find (hasMatchingPT . txOutValue) spendableUTxO

  hasMatchingPT val =
    selectAsset val (AssetId (headIdToPolicyId headId) (AssetName (serialiseToRawBytes vkh))) == 1

rejectByronAddress :: UTxO -> Either (PostTxError Tx) ()
rejectByronAddress u = do
  forM_ u $ \case
    (TxOut (ByronAddressInEra addr) _ _ _) ->
      Left (UnsupportedLegacyOutput addr)
    (TxOut ShelleyAddressInEra{} _ _ _) ->
      Right ()

rejectReferenceScripts :: UTxO -> Either (PostTxError Tx) ()
rejectReferenceScripts u =
  when (any hasReferenceScript u) $
    Left CannotCommitReferenceScript
 where
  hasReferenceScript out =
    case txOutReferenceScript out of
      ReferenceScript{} -> True
      ReferenceScriptNone -> False

-- Rejects outputs with more than 'maxMainnetLovelace' lovelace on mainnet
-- NOTE: Remove this limit once we have more experiments on mainnet.
rejectMoreThanMainnetLimit :: NetworkId -> UTxO -> Either (PostTxError Tx) ()
rejectMoreThanMainnetLimit network u = do
  when (network == Mainnet && lovelaceAmt > maxMainnetLovelace) $
    Left $
      CommittedTooMuchADAForMainnet lovelaceAmt maxMainnetLovelace
 where
  lovelaceAmt = foldMap (selectLovelace . txOutValue) u

-- | Construct a collect transaction based on the 'InitialState'. This will
-- reimburse all the already committed outputs.
abort ::
  ChainContext ->
  -- | Seed TxIn
  TxIn ->
  -- | Spendable UTxO containing head, initial and commit outputs
  UTxO ->
  -- | Committed UTxOs to reimburse.
  UTxO ->
  Either AbortTxError Tx
abort ctx seedTxIn spendableUTxO committedUTxO = do
  headUTxO <-
    maybe (Left CannotFindHeadOutputToAbort) pure $
      UTxO.find (isScriptTxOut headScript) utxoOfThisHead
  abortTx committedUTxO scriptRegistry ownVerificationKey headUTxO headTokenScript initials commits
 where
  initials =
    UTxO.toMap $ UTxO.filter (isScriptTxOut initialScript) utxoOfThisHead

  commits =
    UTxO.toMap $ UTxO.filter (isScriptTxOut commitScript) utxoOfThisHead

  utxoOfThisHead = UTxO.filter hasHeadToken spendableUTxO

  hasHeadToken =
    isJust . find isHeadToken . valueToList . txOutValue

  isHeadToken (assetId, quantity) =
    case assetId of
      AdaAssetId -> False
      AssetId pid _ -> pid == headPolicyId seedTxIn && quantity == 1

  commitScript = fromPlutusScript @PlutusScriptV2 Commit.validatorScript

  headScript = fromPlutusScript @PlutusScriptV2 Head.validatorScript

  initialScript = fromPlutusScript @PlutusScriptV2 Initial.validatorScript

  headTokenScript = mkHeadTokenScript seedTxIn

  ChainContext{ownVerificationKey, scriptRegistry} = ctx

data CollectTxError
  = CannotFindHeadOutputToCollect
  deriving stock (Show)

-- | Construct a collect transaction based on the 'InitialState'. This will know
-- collect all the committed outputs.
collect ::
  ChainContext ->
  HeadId ->
  -- | Spendable UTxO containing head, initial and commit outputs
  UTxO ->
  Either CollectTxError Tx
collect ctx headId spendableUTxO = do
  headUTxO <-
    maybe (Left CannotFindHeadOutputToCollect) pure $
      UTxO.find (isScriptTxOut headScript) utxoOfThisHead
  let commits =
        UTxO.toMap $ UTxO.filter (isScriptTxOut commitScript) utxoOfThisHead
  pure $ collectComTx networkId scriptRegistry ownVerificationKey (allParties ctx) contestationPeriod headUTxO commits headId
 where
  utxoOfThisHead = UTxO.filter hasHeadToken spendableUTxO

  hasHeadToken =
    isJust . find isHeadToken . valueToList . txOutValue

  -- This can be either ST or a PT, only the head policy needs to match
  isHeadToken (assetId, quantity) =
    case assetId of
      AdaAssetId -> False
      AssetId pid _ -> pid == headIdToPolicyId headId && quantity == 1

  headScript = fromPlutusScript @PlutusScriptV2 Head.validatorScript

  commitScript = fromPlutusScript @PlutusScriptV2 Commit.validatorScript

  ChainContext{networkId, ownVerificationKey, scriptRegistry, contestationPeriod} = ctx

-- | Construct a close transaction based on the 'OpenState' and a confirmed
-- snapshot.
--  - 'SlotNo' parameter will be used as the 'Tx' lower bound.
--  - 'PointInTime' parameter will be used as an upper validity bound and
--       will define the start of the contestation period.
-- NB: lower and upper bound slot difference should not exceed contestation period
close ::
  ChainContext ->
  -- | Spendable UTxO containing head, initial and commit outputs
  UTxO ->
  HeadId ->
  HeadParameters ->
  ConfirmedSnapshot Tx ->
  -- | 'Tx' validity lower bound
  SlotNo ->
  -- | 'Tx' validity upper bound
  PointInTime ->
  Either CloseTxError Tx
close ctx spendableUTxO headId HeadParameters{contestationPeriod, parties} confirmedSnapshot startSlotNo pointInTime = do
  headUTxO <-
    maybe (Left CannotFindHeadOutputToClose) pure $
      UTxO.find (isScriptTxOut headScript) utxoOfThisHead

  let openThreadOutput =
        OpenThreadOutput
          { openThreadUTxO = headUTxO
          , openContestationPeriod = ContestationPeriod.toChain contestationPeriod
          , openParties = Party.partyToChain <$> parties
          }
  pure $ closeTx scriptRegistry ownVerificationKey closingSnapshot startSlotNo pointInTime openThreadOutput headId
 where
  headScript = fromPlutusScript @PlutusScriptV2 Head.validatorScript

  closingSnapshot = case confirmedSnapshot of
    -- REVIEW: Check if this is as good as using the deserialized output from the datum.
    InitialSnapshot{initialUTxO} -> CloseWithInitialSnapshot{openUtxoHash = UTxOHash $ hashUTxO @Tx initialUTxO}
    ConfirmedSnapshot{snapshot = Snapshot{number, utxo}, signatures} ->
      CloseWithConfirmedSnapshot
        { snapshotNumber = number
        , closeUtxoHash = UTxOHash $ hashUTxO @Tx utxo
        , signatures
        }

  ChainContext{ownVerificationKey, scriptRegistry} = ctx

  utxoOfThisHead = UTxO.filter hasHeadToken spendableUTxO

  hasHeadToken =
    isJust . find isHeadToken . valueToList . txOutValue

  isHeadToken (assetId, quantity) =
    case assetId of
      AdaAssetId -> False
      AssetId pid _ -> pid == headIdToPolicyId headId && quantity == 1

-- | Construct a contest transaction based on the 'ClosedState' and a confirmed
-- snapshot. The given 'PointInTime' will be used as an upper validity bound and
-- needs to be before the deadline.
contest ::
  ChainContext ->
  -- | Spendable UTxO containing head, initial and commit outputs
  UTxO ->
  HeadId ->
  ConfirmedSnapshot Tx ->
  PointInTime ->
  Either ContestTxError Tx
contest ctx spendableUTxO headId confirmedSnapshot pointInTime = do
  headUTxO <-
    maybe (Left CannotFindHeadOutputToContest) pure $
      UTxO.find (isScriptTxOut headScript) utxoOfThisHead

  let closedThreadUTxO = headUTxO
      closedParties = Party.partyToChain <$> [undefined]
      closedContestationDeadline = undefined
      closedContesters = undefined
      closedThreadOutput =
        ClosedThreadOutput
          { closedThreadUTxO
          , closedParties
          , closedContestationDeadline
          , closedContesters
          }
  pure $ contestTx scriptRegistry ownVerificationKey sn sigs pointInTime closedThreadOutput headId contestationPeriod
 where
  (sn, sigs) =
    case confirmedSnapshot of
      ConfirmedSnapshot{signatures} -> (getSnapshot confirmedSnapshot, signatures)
      _ -> (getSnapshot confirmedSnapshot, mempty)

  ChainContext{contestationPeriod, ownVerificationKey, scriptRegistry} = ctx

  headScript = fromPlutusScript @PlutusScriptV2 Head.validatorScript

  utxoOfThisHead = UTxO.filter hasHeadToken spendableUTxO

  hasHeadToken =
    isJust . find isHeadToken . valueToList . txOutValue

  isHeadToken (assetId, quantity) =
    case assetId of
      AdaAssetId -> False
      AssetId pid _ -> pid == headIdToPolicyId headId && quantity == 1

-- | Construct a fanout transaction based on the 'ClosedState' and off-chain
-- agreed 'UTxO' set to fan out.
fanout ::
  ChainContext ->
  ClosedState ->
  UTxO ->
  -- | Contestation deadline as SlotNo, used to set lower tx validity bound.
  SlotNo ->
  Tx
fanout ctx st utxo deadlineSlotNo = do
  fanoutTx scriptRegistry utxo closedThreadUTxO deadlineSlotNo headTokenScript
 where
  headTokenScript = mkHeadTokenScript seedTxIn

  ChainContext{scriptRegistry} = ctx

  ClosedState{closedThreadOutput, seedTxIn} = st

  ClosedThreadOutput{closedThreadUTxO} = closedThreadOutput

-- * Observing Transitions

data NoObservation
  = NoObservation
  | NotAnInitTx NotAnInit
  deriving (Eq, Show)

-- ** IdleState transitions

-- | Observe an init transition using a 'InitialState' and 'observeInitTx'.
observeInit ::
  ChainContext ->
  Tx ->
  Either NotAnInit (OnChainTx Tx, InitialState)
observeInit ctx tx = do
  observed <-
    first NotAnInit $
      observeRawInitTx tx

  observation <-
    first NotAnInitForUs $
      observeInitTx
        (allVerificationKeys ctx)
        (Hydra.Chain.Direct.State.contestationPeriod ctx)
        ownParty
        otherParties
        observed
  pure (toEvent observation, toState observation)
 where
  toEvent InitObservation{contestationPeriod, parties, headId, seedTxIn} =
    OnInitTx{contestationPeriod, parties, headId, headSeed = txInToHeadSeed seedTxIn}

  toState InitObservation{threadOutput, initials, commits, headId, seedTxIn} =
    InitialState
      { initialThreadOutput = threadOutput
      , initialInitials = initials
      , initialCommits = commits
      , headId
      , seedTxIn
      }

  ChainContext{ownParty, otherParties} = ctx

-- ** InitialState transitions

-- | Observe an commit transition using a 'InitialState' and 'observeCommitTx'.
observeCommit ::
  ChainContext ->
  InitialState ->
  Tx ->
  Maybe (OnChainTx Tx, InitialState)
observeCommit ctx st tx = do
  let utxo = getKnownUTxO st
  observation <- observeCommitTx networkId utxo tx
  let CommitObservation{commitOutput, party, committed, headId = commitHeadId} = observation
  guard $ commitHeadId == headId
  let event = OnCommitTx{party, committed}
  let st' =
        st
          { initialInitials =
              -- NOTE: A commit tx has been observed and thus we can
              -- remove all it's inputs from our tracked initials
              filter ((`notElem` txIns' tx) . fst) initialInitials
          , initialCommits =
              commitOutput : initialCommits
          }
  pure (event, st')
 where
  ChainContext{networkId} = ctx

  InitialState
    { initialCommits
    , initialInitials
    , headId
    } = st

-- | Observe an collect transition using a 'InitialState' and 'observeCollectComTx'.
-- This function checks the head id and ignores if not relevant.
observeCollect ::
  InitialState ->
  Tx ->
  Maybe (OnChainTx Tx, OpenState)
observeCollect st tx = do
  let utxo = getKnownUTxO st
  observation <- observeCollectComTx utxo tx
  let CollectComObservation{threadOutput = threadOutput@OpenThreadOutput{openThreadUTxO}, headId = collectComHeadId, utxoHash} = observation
  guard (headId == collectComHeadId)
  -- REVIEW: is it enough to pass here just the 'openThreadUTxO' or we need also
  -- the known utxo (getKnownUTxO st)?
  let event = OnCollectComTx{collected = UTxO.singleton openThreadUTxO, headId}
  let st' =
        OpenState
          { openThreadOutput = threadOutput
          , headId
          , seedTxIn
          , openUtxoHash = utxoHash
          }
  pure (event, st')
 where
  InitialState
    { headId
    , seedTxIn
    } = st

-- | Observe an abort transition using a 'InitialState' and 'observeAbortTx'.
observeAbort ::
  InitialState ->
  Tx ->
  Maybe (OnChainTx Tx)
observeAbort st tx = do
  let utxo = getKnownUTxO st
  AbortObservation{} <- observeAbortTx utxo tx
  pure OnAbortTx

-- ** OpenState transitions

-- | Observe a close transition using a 'OpenState' and 'observeCloseTx'.
-- This function checks the head id and ignores if not relevant.
observeClose ::
  OpenState ->
  Tx ->
  Maybe (OnChainTx Tx, ClosedState)
observeClose st tx = do
  let utxo = getKnownUTxO st
  observation <- observeCloseTx utxo tx
  let CloseObservation{threadOutput, headId = closeObservationHeadId, snapshotNumber} = observation
  guard (headId == closeObservationHeadId)
  let ClosedThreadOutput{closedContestationDeadline} = threadOutput
  let event =
        OnCloseTx
          { headId = closeObservationHeadId
          , snapshotNumber
          , contestationDeadline = posixToUTCTime closedContestationDeadline
          }
  let st' =
        ClosedState
          { closedThreadOutput = threadOutput
          , headId
          , seedTxIn
          }
  pure (event, st')
 where
  OpenState
    { headId
    , seedTxIn
    } = st

-- ** ClosedState transitions

-- | Observe a fanout transition using a 'ClosedState' and 'observeContestTx'.
-- This function checks the head id and ignores if not relevant.
observeContest ::
  ClosedState ->
  Tx ->
  Maybe (OnChainTx Tx, ClosedState)
observeContest st tx = do
  let utxo = getKnownUTxO st
  observation <- observeContestTx utxo tx
  let ContestObservation{contestedThreadOutput, headId = contestObservationHeadId, snapshotNumber, contesters} = observation
  guard (closedStateHeadId == contestObservationHeadId)
  let event = OnContestTx{snapshotNumber}
  let st' = st{closedThreadOutput = closedThreadOutput{closedThreadUTxO = contestedThreadOutput, closedContesters = contesters}}
  pure (event, st')
 where
  ClosedState
    { headId = closedStateHeadId
    , closedThreadOutput
    } = st

-- | Observe a fanout transition using a 'ClosedState' and 'observeFanoutTx'.
observeFanout ::
  ClosedState ->
  Tx ->
  Maybe (OnChainTx Tx)
observeFanout st tx = do
  let utxo = getKnownUTxO st
  FanoutObservation{} <- observeFanoutTx utxo tx
  pure OnFanoutTx

-- * Generators

-- | Maximum number of parties used in the generators.
maxGenParties :: Int
maxGenParties = 3

-- | Maximum number of assets (ADA or other tokens) used in the generators.
maxGenAssets :: Int
maxGenAssets = 70

-- | Generate a 'ChainState' within known limits above.
genChainState :: Gen ChainState
genChainState =
  oneof
    [ pure Idle
    , Initial <$> arbitrary
    , Open <$> arbitrary
    , Closed <$> arbitrary
    ]

-- | Generate a 'ChainContext' and 'ChainState' within the known limits above, along with a
-- transaction that results in a transition away from it.
genChainStateWithTx :: Gen (ChainContext, ChainState, Tx, ChainTransition)
genChainStateWithTx =
  oneof
    [ genInitWithState
    , genAbortWithState
    , genCommitWithState
    , genCollectWithState
    , genCloseWithState
    , genContestWithState
    , genFanoutWithState
    ]
 where
  genInitWithState :: Gen (ChainContext, ChainState, Tx, ChainTransition)
  genInitWithState = do
    ctx <- genHydraContext maxGenParties
    cctx <- pickChainContext ctx
    seedInput <- genTxIn
    let tx = initialize cctx (ctxHeadParameters ctx) seedInput
    pure (cctx, Idle, tx, Init)

  genAbortWithState :: Gen (ChainContext, ChainState, Tx, ChainTransition)
  genAbortWithState = do
    ctx <- genHydraContext maxGenParties
    (cctx, stInitial) <- genStInitial ctx
    -- TODO: also generate sometimes aborts with utxo
    let utxo = getKnownUTxO stInitial
        InitialState{seedTxIn} = stInitial
        tx = unsafeAbort cctx seedTxIn utxo mempty
    pure (cctx, Initial stInitial, tx, Abort)

  genCommitWithState :: Gen (ChainContext, ChainState, Tx, ChainTransition)
  genCommitWithState = do
    ctx <- genHydraContext maxGenParties
    (cctx, stInitial) <- genStInitial ctx
    utxo <- genCommit
    let InitialState{headId} = stInitial
    let tx = unsafeCommit cctx headId (getKnownUTxO stInitial) utxo
    pure (cctx, Initial stInitial, tx, Commit)

  genCollectWithState :: Gen (ChainContext, ChainState, Tx, ChainTransition)
  genCollectWithState = do
    (ctx, _, st, tx) <- genCollectComTx
    pure (ctx, Initial st, tx, Collect)

  genCloseWithState :: Gen (ChainContext, ChainState, Tx, ChainTransition)
  genCloseWithState = do
    (ctx, st, tx, _) <- genCloseTx maxGenParties
    pure (ctx, Open st, tx, Close)

  genContestWithState :: Gen (ChainContext, ChainState, Tx, ChainTransition)
  genContestWithState = do
    (hctx, _, st, tx) <- genContestTx
    ctx <- pickChainContext hctx
    pure (ctx, Closed st, tx, Contest)

  genFanoutWithState :: Gen (ChainContext, ChainState, Tx, ChainTransition)
  genFanoutWithState = do
    Positive numParties <- arbitrary
    Positive numOutputs <- arbitrary
    (hctx, st, tx) <- genFanoutTx numParties numOutputs
    ctx <- pickChainContext hctx
    pure (ctx, Closed st, tx, Fanout)

-- ** Warning zone

-- | Define some 'global' context from which generators can pick
-- values for generation. This allows to write fairly independent generators
-- which however still make sense with one another within the context of a head.
--
-- For example, one can generate a head's _party_ from that global list, whereas
-- other functions may rely on all parties and thus, we need both generation to
-- be coherent.
--
-- Do not use this in production code, but only for generating test data.
data HydraContext = HydraContext
  { ctxVerificationKeys :: [VerificationKey PaymentKey]
  , ctxHydraSigningKeys :: [SigningKey HydraKey]
  , ctxNetworkId :: NetworkId
  , ctxContestationPeriod :: ContestationPeriod
  , ctxScriptRegistry :: ScriptRegistry
  }
  deriving stock (Show)

ctxParties :: HydraContext -> [Party]
ctxParties = fmap deriveParty . ctxHydraSigningKeys

ctxHeadParameters ::
  HydraContext ->
  HeadParameters
ctxHeadParameters ctx@HydraContext{ctxContestationPeriod} =
  HeadParameters ctxContestationPeriod (ctxParties ctx)

-- | Generate a `HydraContext` for a arbitrary number of parties, bounded by
-- given maximum.
genHydraContext :: Int -> Gen HydraContext
genHydraContext maxParties = choose (1, maxParties) >>= genHydraContextFor

-- | Generate a 'HydraContext' for a given number of parties.
genHydraContextFor :: Int -> Gen HydraContext
genHydraContextFor n = do
  ctxVerificationKeys <- replicateM n genVerificationKey
  ctxHydraSigningKeys <- vector n
  ctxNetworkId <- Testnet . NetworkMagic <$> arbitrary
  ctxContestationPeriod <- arbitrary
  ctxScriptRegistry <- genScriptRegistry
  pure $
    HydraContext
      { ctxVerificationKeys
      , ctxHydraSigningKeys
      , ctxNetworkId
      , ctxContestationPeriod
      , ctxScriptRegistry
      }

-- | Get all peer-specific 'ChainContext's from a 'HydraContext'. NOTE: This
-- assumes that 'HydraContext' has same length 'ctxVerificationKeys' and
-- 'ctxHydraSigningKeys'.
-- XXX: This is actually a non-monadic function.
deriveChainContexts :: HydraContext -> Gen [ChainContext]
deriveChainContexts ctx = do
  pure $
    flip map (zip ctxVerificationKeys allParties) $ \(vk, p) ->
      ChainContext
        { networkId = ctxNetworkId
        , peerVerificationKeys = ctxVerificationKeys \\ [vk]
        , ownVerificationKey = vk
        , ownParty = p
        , otherParties = allParties \\ [p]
        , scriptRegistry = ctxScriptRegistry
        , contestationPeriod = ctxContestationPeriod ctx
        }
 where
  allParties = ctxParties ctx

  HydraContext
    { ctxVerificationKeys
    , ctxNetworkId
    , ctxScriptRegistry
    } = ctx

-- | Pick one of the participants and derive the peer-specific 'ChainContext'
-- from a 'HydraContext'. NOTE: This assumes that 'HydraContext' has same length
-- 'ctxVerificationKeys' and 'ctxHydraSigningKeys'.
pickChainContext :: HydraContext -> Gen ChainContext
pickChainContext ctx =
  deriveChainContexts ctx >>= elements

genStInitial ::
  HydraContext ->
  Gen (ChainContext, InitialState)
genStInitial ctx = do
  seedInput <- genTxIn
  cctx <- pickChainContext ctx
  let txInit = initialize cctx (ctxHeadParameters ctx) seedInput
  let initState = unsafeObserveInit cctx txInit
  pure (cctx, initState)

genInitTx ::
  HydraContext ->
  Gen Tx
genInitTx ctx = do
  cctx <- pickChainContext ctx
  initialize cctx (ctxHeadParameters ctx) <$> genTxIn

genCommits ::
  HydraContext ->
  Tx ->
  Gen [Tx]
genCommits =
  genCommits' genCommit

genCommits' ::
  Gen UTxO ->
  HydraContext ->
  Tx ->
  Gen [Tx]
genCommits' genUTxO ctx txInit = do
  -- Prepare UTxO to commit. We need to scale down the quantities by number of
  -- committed UTxOs to ensure we are not as easily hitting overflows of the max
  -- bound (Word64) when collecting all the commits together later.
  commitUTxOs <- forM (ctxParties ctx) $ const genUTxO
  let scaledCommitUTxOs = scaleCommitUTxOs commitUTxOs

  allChainContexts <- deriveChainContexts ctx
  forM (zip allChainContexts scaledCommitUTxOs) $ \(cctx, toCommit) -> do
    let stInitial@InitialState{headId} = unsafeObserveInit cctx txInit
    pure $ unsafeCommit cctx headId (getKnownUTxO stInitial) toCommit
 where
  scaleCommitUTxOs commitUTxOs =
    let numberOfUTxOs = length $ fold commitUTxOs
     in map (fmap (modifyTxOutValue (scaleQuantitiesDownBy numberOfUTxOs))) commitUTxOs

  scaleQuantitiesDownBy x =
    valueFromList . map (\(an, Quantity q) -> (an, Quantity $ q `div` fromIntegral x)) . valueToList

genCommit :: Gen UTxO
genCommit =
  frequency
    [ (1, pure mempty)
    , (10, genVerificationKey >>= genOneUTxOFor)
    ]

genCollectComTx :: Gen (ChainContext, [UTxO], InitialState, Tx)
genCollectComTx = do
  ctx <- genHydraContextFor maximumNumberOfParties
  txInit <- genInitTx ctx
  commits <- genCommits ctx txInit
  cctx <- pickChainContext ctx
  let (committedUTxO, stInitialized) = unsafeObserveInitAndCommits cctx txInit commits
  let InitialState{headId} = stInitialized
  let utxo = getKnownUTxO stInitialized <> foldMap (<> mempty) committedUTxO
  pure (cctx, committedUTxO, stInitialized, unsafeCollect cctx headId utxo)

genCloseTx :: Int -> Gen (ChainContext, OpenState, Tx, ConfirmedSnapshot Tx)
genCloseTx numParties = do
  ctx <- genHydraContextFor numParties
  (u0, stOpen@OpenState{headId}) <- genStOpen ctx
  snapshot <- genConfirmedSnapshot headId 0 u0 (ctxHydraSigningKeys ctx)
  cctx <- pickChainContext ctx
  let params = ctxHeadParameters ctx
      cp = ctxContestationPeriod ctx
  (startSlot, pointInTime) <- genValidityBoundsFromContestationPeriod cp
  pure (cctx, stOpen, unsafeClose cctx u0 headId params snapshot startSlot pointInTime, snapshot)

genContestTx :: Gen (HydraContext, PointInTime, ClosedState, Tx)
genContestTx = do
  ctx <- genHydraContextFor maximumNumberOfParties
  (u0, stOpen@OpenState{headId}) <- genStOpen ctx
  confirmed <- genConfirmedSnapshot headId 0 u0 []
  cctx <- pickChainContext ctx
  let params = ctxHeadParameters ctx
      cp = Hydra.Chain.Direct.State.contestationPeriod cctx
  (startSlot, closePointInTime) <- genValidityBoundsFromContestationPeriod cp
  let txClose = unsafeClose cctx u0 headId params confirmed startSlot closePointInTime
  let stClosed = snd $ fromJust $ observeClose stOpen txClose
  utxo <- arbitrary
  contestSnapshot <- genConfirmedSnapshot headId (succ $ number $ getSnapshot confirmed) utxo (ctxHydraSigningKeys ctx)
  contestPointInTime <- genPointInTimeBefore (getContestationDeadline stClosed)
  pure (ctx, closePointInTime, stClosed, unsafeContest cctx utxo headId contestSnapshot contestPointInTime)

genFanoutTx :: Int -> Int -> Gen (HydraContext, ClosedState, Tx)
genFanoutTx numParties numOutputs = do
  ctx <- genHydraContext numParties
  utxo <- genUTxOAdaOnlyOfSize numOutputs
  (_, toFanout, stClosed) <- genStClosed ctx utxo
  cctx <- pickChainContext ctx
  let deadlineSlotNo = slotNoFromUTCTime (getContestationDeadline stClosed)
  pure (ctx, stClosed, fanout cctx stClosed toFanout deadlineSlotNo)

getContestationDeadline :: ClosedState -> UTCTime
getContestationDeadline
  ClosedState{closedThreadOutput = ClosedThreadOutput{closedContestationDeadline}} =
    posixToUTCTime closedContestationDeadline

genStOpen ::
  HydraContext ->
  Gen (UTxO, OpenState)
genStOpen ctx = do
  txInit <- genInitTx ctx
  commits <- genCommits ctx txInit
  cctx <- pickChainContext ctx
  let (committed, stInitial) = unsafeObserveInitAndCommits cctx txInit commits
  let InitialState{headId} = stInitial
  let utxo = getKnownUTxO stInitial <> foldMap (<> mempty) committed
  let txCollect = unsafeCollect cctx headId utxo
  pure (fold committed, snd . fromJust $ observeCollect stInitial txCollect)

genStClosed ::
  HydraContext ->
  UTxO ->
  Gen (SnapshotNumber, UTxO, ClosedState)
genStClosed ctx utxo = do
  (u0, stOpen@OpenState{headId}) <- genStOpen ctx
  confirmed <- arbitrary
  let (sn, snapshot, toFanout) = case confirmed of
        InitialSnapshot{} ->
          ( 0
          , InitialSnapshot{headId, initialUTxO = u0}
          , u0
          )
        ConfirmedSnapshot{snapshot = snap, signatures} ->
          ( number snap
          , ConfirmedSnapshot
              { snapshot = snap{utxo = utxo}
              , signatures
              }
          , utxo
          )
  cctx <- pickChainContext ctx
  let params = ctxHeadParameters ctx
      cp = Hydra.Chain.Direct.State.contestationPeriod cctx
  (startSlot, pointInTime) <- genValidityBoundsFromContestationPeriod cp
  let txClose = unsafeClose cctx u0 headId params snapshot startSlot pointInTime
  pure (sn, toFanout, snd . fromJust $ observeClose stOpen txClose)

-- ** Danger zone

unsafeCommit ::
  HasCallStack =>
  ChainContext ->
  HeadId ->
  -- | Spendable 'UTxO'
  UTxO ->
  -- | 'UTxO' to commit. All outputs are assumed to be owned by public keys.
  UTxO ->
  Tx
unsafeCommit ctx headId spendableUTxO utxoToCommit =
  either (error . show) id $ commit ctx headId spendableUTxO utxoToCommit

unsafeAbort ::
  HasCallStack =>
  ChainContext ->
  -- | Seed TxIn
  TxIn ->
  -- | Spendable UTxO containing head, initial and commit outputs
  UTxO ->
  -- | Committed UTxOs to reimburse.
  UTxO ->
  Tx
unsafeAbort ctx seedTxIn spendableUTxO committedUTxO =
  either (error . show) id $ abort ctx seedTxIn spendableUTxO committedUTxO

unsafeClose ::
  HasCallStack =>
  ChainContext ->
  -- | Spendable UTxO containing head, initial and commit outputs
  UTxO ->
  HeadId ->
  HeadParameters ->
  ConfirmedSnapshot Tx ->
  -- | 'Tx' validity lower bound
  SlotNo ->
  -- | 'Tx' validity upper bound
  PointInTime ->
  Tx
unsafeClose ctx spendableUTxO headId parameters confirmedSnapshot startSlotNo pointInTime =
  either (error . show) id $ close ctx spendableUTxO headId parameters confirmedSnapshot startSlotNo pointInTime

unsafeCollect ::
  ChainContext ->
  HeadId ->
  -- | Spendable UTxO containing head, initial and commit outputs
  UTxO ->
  Tx
unsafeCollect ctx headId spendableUTxO =
  either (error . show) id $ collect ctx headId spendableUTxO

unsafeContest ::
  HasCallStack =>
  ChainContext ->
  -- | Spendable UTxO containing head, initial and commit outputs
  UTxO ->
  HeadId ->
  ConfirmedSnapshot Tx ->
  PointInTime ->
  Tx
unsafeContest ctx spendableUTxO headId confirmedSnapshot pointInTime =
  either (error . show) id $ contest ctx spendableUTxO headId confirmedSnapshot pointInTime

unsafeObserveInit ::
  HasCallStack =>
  ChainContext ->
  Tx ->
  InitialState
unsafeObserveInit cctx txInit =
  case observeInit cctx txInit of
    Left err -> error $ "Did not observe an init tx: " <> show err
    Right st -> snd st

-- REVIEW: Maybe it would be more convenient if 'unsafeObserveInitAndCommits'
-- returns just 'UTXO' instead of [UTxO]
unsafeObserveInitAndCommits ::
  HasCallStack =>
  ChainContext ->
  Tx ->
  [Tx] ->
  ([UTxO], InitialState)
unsafeObserveInitAndCommits ctx txInit commits =
  (utxo, stInitial')
 where
  stInitial = unsafeObserveInit ctx txInit

  (utxo, stInitial') = flip runState stInitial $ do
    forM commits $ \txCommit -> do
      st <- get
      let (event, st') = fromJust $ observeCommit ctx st txCommit
      put st'
      pure $ case event of
        OnCommitTx{committed} -> committed
        _ -> mempty
