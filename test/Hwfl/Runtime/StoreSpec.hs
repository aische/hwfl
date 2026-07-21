module Hwfl.Runtime.StoreSpec (spec) where

import Data.Maybe (isJust, isNothing)
import Data.Set qualified as Set
import Data.Text qualified as T
import Hwfl.Driver
  ( DriverRunRequest (..),
    RunOutcome (..),
    defaultDriverRunRequest,
    driverListRuns,
    driverReadMeta,
    driverReadSnapshot,
    driverReadSpans,
    driverRun,
    emptySpanFilter,
    runRef,
  )
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Obs.Span (SpanRecord (..))
import Hwfl.Runtime.Machine (MachineStatus (..))
import Hwfl.Runtime.Run (newRunId)
import Hwfl.Runtime.Snapshot (RunMeta (..), RunSnapshot (..))
import Hwfl.Runtime.Store
  ( SpanFilter (..),
    createRun,
    listRuns,
    openRun,
    openRunDir,
    readMeta,
    readSnapshot,
    readSpans,
    writeMeta,
    writeSnapshot,
  )
import System.Directory (doesFileExist, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "run-store interface (FS)" $ do
  describe "list / open / read" $ do
    it "lists runs and reads meta, spans, snapshot after a driver run" $
      withSystemTempDirectory "hwfl-store" $ \dir -> do
        let path = dir </> "pure.md"
        writeFile
          path
          ( T.unpack $
              T.unlines
                [ "---",
                  "name: workflows/store",
                  "inputs: {}",
                  "outputs:",
                  "  n: Int",
                  "effects: []",
                  "---",
                  "",
                  "```hwfl",
                  "fun main(_): { n: Int } = { n = 1 }",
                  "```"
                ]
          )
        let req =
              (defaultDriverRunRequest path dir mockProvider)
                { drrRunId = Just "store-a"
                }
        result <- driverRun req
        case result of
          Left err -> expectationFailure (show err)
          Right (OutcomeCompleted {}) -> pure ()
          other -> expectationFailure ("expected completed, got: " <> show other)

        metas <- driverListRuns dir
        map (.rmRunId) metas `shouldBe` ["store-a"]

        let ref = runRef dir "store-a"
        mMeta <- driverReadMeta ref
        case mMeta of
          Just meta -> do
            meta.rmRunId `shouldBe` "store-a"
            meta.rmEntry `shouldBe` path
          Nothing -> expectationFailure "expected meta"

        mSnap <- driverReadSnapshot ref
        case mSnap of
          Just snap -> snap.rsStatus `shouldBe` MsCompleted
          Nothing -> expectationFailure "expected snapshot"

        spans <- driverReadSpans ref emptySpanFilter
        length spans `shouldSatisfy` (>= 2)
        any (\r -> r.srOp == "open") spans `shouldBe` True

        mOpen <- openRun ref
        mOpen `shouldSatisfy` isJust

    it "returns Nothing for missing runs without creating dirs" $
      withSystemTempDirectory "hwfl-store-missing" $ \dir -> do
        mMissing <- openRun (runRef dir "nope")
        mMissing `shouldSatisfy` isNothing
        driverListRuns dir `shouldReturn` []
        driverReadMeta (runRef dir "nope") `shouldReturn` Nothing
        driverReadSnapshot (runRef dir "nope") `shouldReturn` Nothing
        driverReadSpans (runRef dir "nope") emptySpanFilter `shouldReturn` []

    it "createRun writes meta and listRuns finds it" $
      withSystemTempDirectory "hwfl-store-create" $ \dir -> do
        let meta =
              RunMeta
                { rmRunId = "c1",
                  rmProjectHash = "h",
                  rmEntry = "entry.md",
                  rmStartedAt = "2026-07-17T00:00:00Z",
                  rmStatus = "running"
                }
        _ <- createRun (runRef dir "c1") meta
        listed <- listRuns dir
        map (.rmRunId) listed `shouldBe` ["c1"]
        mStore <- openRun (runRef dir "c1")
        case mStore of
          Nothing -> expectationFailure "expected open"
          Just store -> do
            mMeta <- readMeta store
            mMeta `shouldBe` Just meta

    it "filters spans by name prefix and limit" $
      withSystemTempDirectory "hwfl-store-filt" $ \dir -> do
        let path = dir </> "filt.md"
        writeFile
          path
          ( T.unpack $
              T.unlines
                [ "---",
                  "name: workflows/filt",
                  "inputs: {}",
                  "outputs:",
                  "  n: Int",
                  "effects: []",
                  "---",
                  "",
                  "```hwfl",
                  "fun main(_): { n: Int } =",
                  "  let _ = obs.span(\"alpha\")(fun () =>",
                  "    obs.span(\"beta\")(fun () => 0)",
                  "  )",
                  "  { n = 0 }",
                  "```"
                ]
          )
        let req =
              (defaultDriverRunRequest path dir mockProvider)
                { drrRunId = Just "filt-1"
                }
        result <- driverRun req
        case result of
          Left err -> expectationFailure (show err)
          Right (OutcomeCompleted {}) -> pure ()
          other -> expectationFailure ("expected completed, got: " <> show other)
        let ref = runRef dir "filt-1"
        mStore <- openRun ref
        case mStore of
          Nothing -> expectationFailure "expected open"
          Just store -> do
            allSpans <- readSpans store emptySpanFilter
            length allSpans `shouldSatisfy` (>= 4)
            alpha <-
              readSpans
                store
                SpanFilter
                  { sfNamePrefix = Just "alpha",
                    sfKind = Nothing,
                    sfLimit = Nothing
                  }
            null alpha `shouldBe` False
            limited <-
              readSpans
                store
                emptySpanFilter {sfLimit = Just 1}
            length limited `shouldBe` 1

  describe "crash-safe writes + run ids" $ do
    it "replaces meta and snapshot atomically without leaving .tmp files" $
      withSystemTempDirectory "hwfl-store-atomic" $ \dir -> do
        store <- openRunDir (dir </> "run-x") "run-x"
        let meta0 =
              RunMeta
                { rmRunId = "run-x",
                  rmProjectHash = "h0",
                  rmEntry = "a.md",
                  rmStartedAt = "2026-07-21T00:00:00Z",
                  rmStatus = "running"
                }
            meta1 = meta0 {rmProjectHash = "h1", rmStatus = "completed"}
            snap0 =
              RunSnapshot
                { rsFormat = 1,
                  rsRunId = "run-x",
                  rsSeq = 1,
                  rsStatus = MsRunning,
                  rsProjectHash = "h0",
                  rsLastHost = Nothing,
                  rsLastResult = Nothing,
                  rsAt = "2026-07-21T00:00:00Z",
                  rsMachine = Nothing,
                  rsSpanStack = [],
                  rsSpanCounter = 0
                }
            snap1 = snap0 {rsSeq = 2, rsStatus = MsCompleted, rsProjectHash = "h1"}
        writeMeta store meta0
        writeSnapshot store snap0
        -- Leftover / corrupt temps must not become the durable files.
        writeFile (dir </> "run-x" </> "meta.json.tmp") "{not-json"
        writeFile (dir </> "run-x" </> "snapshot.json.tmp") "{not-json"
        writeMeta store meta1
        writeSnapshot store snap1
        readMeta store `shouldReturn` Just meta1
        readSnapshot store `shouldReturn` Just snap1
        doesFileExist (dir </> "run-x" </> "meta.json.tmp") `shouldReturn` False
        doesFileExist (dir </> "run-x" </> "snapshot.json.tmp") `shouldReturn` False
        names <- listDirectory (dir </> "run-x")
        any (".tmp" `T.isSuffixOf`) (map T.pack names) `shouldBe` False

    it "generates unique collision-resistant run ids within the same second" $ do
      ids <- mapM (const newRunId) [1 .. 40 :: Int]
      length (Set.fromList ids) `shouldBe` 40
      all
        (\i -> T.isPrefixOf "run-" i && T.length i > length ("run-YYYYMMDD-HHMMSS" :: String))
        ids
        `shouldBe` True
      all hasEntropySuffix ids `shouldBe` True
  where
    hasEntropySuffix rid =
      case T.splitOn "-" rid of
        ["run", ymd, hms, nonce] ->
          T.length ymd == 8
            && T.length hms == 6
            && T.length nonce == 16
            && T.all (\c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) nonce
        _ -> False
