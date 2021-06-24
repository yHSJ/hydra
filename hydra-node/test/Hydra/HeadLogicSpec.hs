{-# LANGUAGE TypeApplications #-}

module Hydra.HeadLogicSpec where

import Hydra.Prelude

import qualified Data.Set as Set
import Hydra.HeadLogic (
  ClientResponse (PeerConnected),
  Effect (ClientEffect, NetworkEffect),
  Environment (..),
  Event (..),
  HeadParameters (..),
  HeadState (..),
  HeadStatus (..),
  HydraMessage (..),
  LogicError (..),
  OnChainTx (..),
  Outcome (..),
  SimpleHeadState (..),
  Snapshot (..),
  SnapshotStrategy (..),
  update,
 )
import Hydra.Ledger (Ledger (..), Party, Tx, sign)
import Hydra.Ledger.Builder (utxoRef)
import Hydra.Ledger.Simple (SimpleTx (..), TxIn (..), simpleLedger)
import Hydra.Network (Host (Host, hostName, portNumber))
import Test.Hspec (
  Spec,
  describe,
  expectationFailure,
  it,
  shouldBe,
 )
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, Property, elements, forAll)
import Test.QuickCheck.Instances.Time ()
import Test.QuickCheck.Property (collect)

spec :: Spec
spec = describe "Hydra Head Logic" $ do
  let threeParties = Set.fromList [1, 2, 3]
      ledger = simpleLedger
      env =
        Environment
          { party = 2
          , signingKey = 2
          , allParties = threeParties
          , snapshotStrategy = NoSnapshots
          }
      -- NOTE: This unrealistic Tx is just there to be always valid as
      -- it does not require any input
      simpleTx = SimpleTx 1 mempty (Set.fromList [TxIn 3, TxIn 4])

  it "confirms tx given it receives AckTx from all parties" $ do
    let reqTx = NetworkEvent $ ReqTx simpleTx
        ackFrom p = NetworkEvent $ AckTx p simpleTx
        s0 = initialState threeParties ledger

    s1 <- assertNewState $ update env ledger s0 reqTx
    s2 <- assertNewState $ update env ledger s1 (ackFrom 3)
    s3 <- assertNewState $ update env ledger s2 (ackFrom 1)
    getConfirmedTransactions s3 `shouldBe` []

    s4 <- assertNewState $ update env ledger s3 (ackFrom 2)
    getConfirmedTransactions s4 `shouldBe` [simpleTx]

  it "waits if a requested tx is not (yet) applicable" $ do
    let reqTx = NetworkEvent $ ReqTx $ SimpleTx 2 inputs mempty
        inputs = utxoRef 1
        s0 = initialState threeParties ledger

    update env ledger s0 reqTx `shouldBe` Wait

  it "notifies client when it receives a ping" $ do
    let host = Host{hostName = "0.0.0.0", portNumber = 4000}
    update env ledger (initialState threeParties ledger) (NetworkEvent $ Ping host)
      `hasEffect` ClientEffect (PeerConnected host)

  it "confirms snapshot given it receives AckSn from all parties" $ do
    let s0 = initialState threeParties ledger
        reqSn = NetworkEvent $ ReqSn 1 1 []
        snapshot1 = Snapshot 1 mempty []
        ackFrom sk vk = NetworkEvent $ AckSn vk (sign sk snapshot1) 1
    s1 <- assertNewState $ update env ledger s0 reqSn
    s2 <- assertNewState $ update env ledger s1 (ackFrom 3 3)
    s3 <- assertNewState $ update env ledger s2 (ackFrom 1 1)

    getConfirmedSnapshot s3 `shouldBe` Just (Snapshot 0 mempty [])

    s4 <- assertNewState $ update env ledger s3 (ackFrom 2 2)
    getConfirmedSnapshot s4 `shouldBe` Just snapshot1

  it "does not confirm snapshot when given a non-matching signature produced from a different message" $ do
    let s0 = initialState threeParties ledger
        reqSn = NetworkEvent $ ReqSn 1 1 []
        snapshot = Snapshot 1 mempty []
        snapshot' = Snapshot 2 mempty []
        ackFrom sk vk = NetworkEvent $ AckSn vk (sign sk snapshot) 1
        invalidAckFrom sk vk = NetworkEvent $ AckSn vk (sign sk snapshot') 1
    s1 <- assertNewState $ update env ledger s0 reqSn
    s2 <- assertNewState $ update env ledger s1 (ackFrom 3 3)
    s3 <- assertNewState $ update env ledger s2 (ackFrom 1 1)
    s4 <- assertNewState $ update env ledger s3 (invalidAckFrom 2 2)

    getConfirmedSnapshot s4 `shouldBe` getConfirmedSnapshot s3

  it "does not confirm snapshot when given a non-matching signature produced from a different key" $ do
    let s0 = initialState threeParties ledger
        reqSn = NetworkEvent $ ReqSn 1 1 []
        snapshot = Snapshot 1 mempty []
        ackFrom sk vk = NetworkEvent $ AckSn vk (sign sk snapshot) 1
    s1 <- assertNewState $ update env ledger s0 reqSn
    s2 <- assertNewState $ update env ledger s1 (ackFrom 3 3)
    s3 <- assertNewState $ update env ledger s2 (ackFrom 1 1)
    s4 <- assertNewState $ update env ledger s3 (ackFrom 42 2)

    getConfirmedSnapshot s4 `shouldBe` getConfirmedSnapshot s3

  it "waits if we receive a snapshot with not-yet-seen transactions" $ do
    let event = NetworkEvent $ ReqSn 1 1 [SimpleTx 1 (utxoRef 1) (utxoRef 2)]
    update env ledger (initialState threeParties ledger) event `shouldBe` Wait

  it "returns logic error if we receive a far-away snapshot (not the direct successor)" $ do
    let event = NetworkEvent $ ReqSn 1 2 []
        st = initialState threeParties ledger
    update env ledger st event `shouldBe` Error (InvalidEvent event st)

  it "acks signed snapshot from the constant leader" $ do
    let leader = 1
        snapshot = Snapshot 1 mempty []
        event = NetworkEvent $ ReqSn leader (number snapshot) []
        sig = sign 2 snapshot
        st = initialState threeParties ledger
        ack = AckSn (party env) sig (number snapshot)
    update env ledger st event `hasEffect` NetworkEffect ack

  it "does not ack snapshots from non-leaders" $ do
    let event = NetworkEvent $ ReqSn notTheLeader 1 []
        notTheLeader = 2
        st = initialState threeParties ledger
    update env ledger st event `shouldBe` Error (InvalidEvent event st)

  it "does not ack too new snapshots" $ do
    let event = NetworkEvent $ ReqSn theLeader 3 []
        theLeader = 1
        st = initialState threeParties ledger
    update env ledger st event `shouldBe` Error (InvalidEvent event st)

  prop "can handle OnChainEvent in any state" prop_handleOnChainEventInAnyState

genOnChainTx :: Gen (OnChainTx SimpleTx)
genOnChainTx =
  elements
    [ InitTx mempty
    , CommitTx 1 (Set.fromList [TxIn 1, TxIn 2])
    , CollectComTx mempty
    , CloseTx (Snapshot 0 mempty mempty) mempty
    , ContestTx (Snapshot 0 mempty mempty) mempty
    , FanoutTx (Set.fromList [TxIn 1, TxIn 2])
    ]

genHeadStatus :: Gen (HeadStatus SimpleTx)
genHeadStatus =
  elements
    [ InitState
    , FinalState
    , CollectingState mempty mempty
    , OpenState (SimpleHeadState mempty mempty mempty (Snapshot 0 mempty mempty) Nothing)
    ]

defaultHeadParameters :: HeadParameters
defaultHeadParameters =
  HeadParameters 3600 (Set.singleton 1)

prop_handleOnChainEventInAnyState :: Property
prop_handleOnChainEventInAnyState =
  forAll genHeadStatus $ \st ->
    forAll genOnChainTx $ \tx ->
      collect (tx, st) $
        case update env ledger (HeadState defaultHeadParameters st) (OnChainEvent tx) of
          NewState _ _ -> True
          Wait -> True
          Error _ -> False
 where
  env =
    Environment
      { party = 1
      , signingKey = 1
      , allParties = mempty -- TODO(SN): This is a big smell, make this impossible!
      , snapshotStrategy = NoSnapshots
      }
  ledger = simpleLedger

hasEffect :: Tx tx => Outcome tx -> Effect tx -> IO ()
hasEffect (NewState _ effects) effect
  | effect `elem` effects = pure ()
  | otherwise = expectationFailure $ "Missing effect " <> show effect <> " in produced effects:  " <> show effects
hasEffect _ _ = expectationFailure "Unexpected outcome"

initialState ::
  Ord tx =>
  Set Party ->
  Ledger tx ->
  HeadState tx
initialState parties Ledger{initUTxO} =
  let u0 = initUTxO
      snapshot0 = Snapshot 0 u0 mempty
   in HeadState
        { headStatus = OpenState $ SimpleHeadState u0 mempty mempty snapshot0 Nothing
        , headParameters =
            HeadParameters
              { contestationPeriod = 42
              , parties
              }
        }

getConfirmedTransactions :: HeadState tx -> [tx]
getConfirmedTransactions HeadState{headStatus} = case headStatus of
  OpenState SimpleHeadState{confirmedTxs} -> confirmedTxs
  _ -> []

getConfirmedSnapshot :: HeadState tx -> Maybe (Snapshot tx)
getConfirmedSnapshot HeadState{headStatus} = case headStatus of
  OpenState SimpleHeadState{confirmedSnapshot} -> Just confirmedSnapshot
  _ -> Nothing

assertNewState :: Outcome SimpleTx -> IO (HeadState SimpleTx)
assertNewState = \case
  NewState st _ -> pure st
  Error e -> fail (show e)
  Wait -> fail "Found 'Wait'"
