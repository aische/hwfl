module Hwfl.Runtime.SnapshotSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Types (Pair, parseEither)
import Data.Either (isLeft)
import Hwfl.Runtime.Machine
  ( ConfirmRequest (..),
    MachineStatus (..),
    PauseReason (..),
  )
import Hwfl.Runtime.Snapshot
  ( RunSnapshot (..),
    currentSnapshotFormat,
    parseSnapshotValue,
    snapshotToJson,
  )
import Test.Hspec

baseFields :: [Pair]
baseFields =
  [ "snapshot_format" .= currentSnapshotFormat,
    "run_id" .= String "r1",
    "seq" .= (1 :: Int),
    "project_hash" .= String "h",
    "at" .= String "2026-08-08T00:00:00Z"
  ]

spec :: Spec
spec = describe "snapshot parse (L-3)" $ do
  it "accepts current snapshot_format and round-trips a completed snapshot" $ do
    let snap =
          RunSnapshot
            { rsFormat = currentSnapshotFormat,
              rsRunId = "r1",
              rsSeq = 1,
              rsStatus = MsCompleted,
              rsProjectHash = "h",
              rsLastHost = Nothing,
              rsLastResult = Nothing,
              rsAt = "2026-08-08T00:00:00Z",
              rsMachine = Nothing,
              rsSpanStack = [],
              rsSpanCounter = 0
            }
    parseEither parseSnapshotValue (snapshotToJson snap)
      `shouldBe` Right snap

  it "rejects unsupported snapshot_format" $ do
    let v =
          object
            [ "snapshot_format" .= (99 :: Int),
              "run_id" .= String "r1",
              "seq" .= (1 :: Int),
              "status" .= String "completed",
              "project_hash" .= String "h",
              "at" .= String "2026-08-08T00:00:00Z",
              "machine_json" .= object ["kind" .= String "none"]
            ]
    case parseEither parseSnapshotValue v of
      Left err -> err `shouldContain` "unsupported snapshot_format"
      Right _ -> expectationFailure "expected format rejection"

  it "does not downgrade a malformed pause payload to PauseExplicit" $ do
    let v =
          object $
            baseFields
              ++ [ "status" .= String "awaiting_confirm",
                   "machine_json"
                     .= object
                       [ "kind" .= String "none",
                         "pause" .= object ["reason" .= String "awaiting_confirm"]
                       ]
                 ]
    parseEither parseSnapshotValue v `shouldSatisfy` isLeft

  it "rejects unknown pause reason strings" $ do
    let v =
          object $
            baseFields
              ++ [ "status" .= String "paused",
                   "machine_json"
                     .= object
                       [ "kind" .= String "none",
                         "pause" .= object ["reason" .= String "bogus"]
                       ]
                 ]
    case parseEither parseSnapshotValue v of
      Left err -> err `shouldContain` "unknown pause reason"
      Right snap ->
        expectationFailure $
          "expected rejection, got status: " <> show snap.rsStatus

  it "parses a well-formed awaiting_confirm pause" $ do
    let v =
          object $
            baseFields
              ++ [ "status" .= String "awaiting_confirm",
                   "machine_json"
                     .= object
                       [ "kind" .= String "none",
                         "pause"
                           .= object
                             [ "reason" .= String "awaiting_confirm",
                               "title" .= String "ok?",
                               "detail" .= String "please"
                             ]
                       ]
                 ]
    case parseEither parseSnapshotValue v of
      Left err -> expectationFailure err
      Right snap ->
        snap.rsStatus
          `shouldBe` MsPaused
            ( PauseAwaitingConfirm
                (ConfirmRequest "ok?" "please" Nothing)
            )

  it "treats paused with no pause object as explicit" $ do
    let v =
          object $
            baseFields
              ++ [ "status" .= String "paused",
                   "machine_json" .= object ["kind" .= String "none"]
                 ]
    parseEither parseSnapshotValue v
      `shouldBe` Right
        ( RunSnapshot
            { rsFormat = currentSnapshotFormat,
              rsRunId = "r1",
              rsSeq = 1,
              rsStatus = MsPaused PauseExplicit,
              rsProjectHash = "h",
              rsLastHost = Nothing,
              rsLastResult = Nothing,
              rsAt = "2026-08-08T00:00:00Z",
              rsMachine = Nothing,
              rsSpanStack = [],
              rsSpanCounter = 0
            }
        )
