module Hwfl.Runtime.StoreSpec (spec) where

import Data.Either (isRight)
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
    driverResume,
    driverRun,
    emptySpanFilter,
    noopObserver,
    runRef,
  )
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Obs.Span (SpanRecord (..))
import Hwfl.Runtime.Error (renderRuntimeError)
import Hwfl.Runtime.Machine (MachineStatus (..))
import Hwfl.Runtime.Run (newRunId)
import Hwfl.Runtime.Snapshot (RunMeta (..), RunSnapshot (..))
import Hwfl.Runtime.Store
  ( RunIdError (..),
    RunStoreError (..),
    SpanFilter (..),
    createRun,
    latestRunAlias,
    listRuns,
    openRun,
    openRunDir,
    readMeta,
    readSnapshot,
    readSpans,
    resolveRunId,
    validateRunId,
    writeMeta,
    writeSnapshot,
  )
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec
import Data.Char (isDigit)

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
        createRun (runRef dir "c1") meta >>= \case
          Left err -> expectationFailure ("expected create, got: " <> show err)
          Right _ -> pure ()
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
        any ((".tmp" `T.isSuffixOf`) . T.pack) names `shouldBe` False

    it "rejects run ids that are not a single path component" $ do
      validateRunId "run-1" `shouldBe` Right "run-1"
      validateRunId "" `shouldBe` Left RunIdEmpty
      validateRunId "." `shouldBe` Left RunIdLeadingDot
      validateRunId ".." `shouldBe` Left RunIdLeadingDot
      validateRunId ".hidden" `shouldBe` Left RunIdLeadingDot
      validateRunId "../../x" `shouldBe` Left RunIdLeadingDot
      validateRunId "a/b" `shouldBe` Left (RunIdBadChar '/')
      validateRunId "a\\b" `shouldBe` Left (RunIdBadChar '\\')
      validateRunId "a b" `shouldBe` Left (RunIdBadChar ' ')
      validateRunId (T.pack (replicate 129 'a'))
        `shouldBe` Left (RunIdTooLong 129)

    it "createRun refuses a traversal run id and writes nothing outside runs" $
      withSystemTempDirectory "hwfl-store-escape" $ \dir -> do
        let workspace = dir </> "ws"
            meta =
              RunMeta
                { rmRunId = "../../escape",
                  rmProjectHash = "h",
                  rmEntry = "entry.md",
                  rmStartedAt = "2026-08-07T00:00:00Z",
                  rmStatus = "running"
                }
        createDirectoryIfMissing True workspace
        created <- createRun (runRef workspace "../../escape") meta
        case created of
          Left err -> err `shouldBe` RseRunId RunIdLeadingDot
          Right _ -> expectationFailure "expected the run id to be rejected"
        openRun (runRef workspace "../../escape") >>= (`shouldSatisfy` isNothing)
        doesDirectoryExist (workspace </> ".hwfl") `shouldReturn` False
        listDirectory dir `shouldReturn` ["ws"]

    it "createRun refuses to reuse an existing run id" $
      withSystemTempDirectory "hwfl-store-reuse" $ \dir -> do
        let meta =
              RunMeta
                { rmRunId = "dup",
                  rmProjectHash = "h",
                  rmEntry = "entry.md",
                  rmStartedAt = "2026-08-07T00:00:00Z",
                  rmStatus = "running"
                }
        first <- createRun (runRef dir "dup") meta
        first `shouldSatisfy` isRight
        second <- createRun (runRef dir "dup") meta {rmProjectHash = "other"}
        case second of
          Left err -> err `shouldBe` RseAlreadyExists "dup"
          Right _ -> expectationFailure "expected the reused run id to be rejected"
        -- The first run's meta must survive the rejected second create.
        mMeta <- driverReadMeta (runRef dir "dup")
        fmap (.rmProjectHash) mMeta `shouldBe` Just "h"

    it "createRun refuses the reserved latest alias" $
      withSystemTempDirectory "hwfl-store-latest" $ \dir -> do
        let meta =
              RunMeta
                { rmRunId = latestRunAlias,
                  rmProjectHash = "h",
                  rmEntry = "entry.md",
                  rmStartedAt = "2026-08-17T00:00:00Z",
                  rmStatus = "running"
                }
        created <- createRun (runRef dir latestRunAlias) meta
        case created of
          Left err -> err `shouldBe` RseReserved latestRunAlias
          Right _ -> expectationFailure "expected latest to be reserved"
        doesDirectoryExist (dir </> ".hwfl") `shouldReturn` False

    it "resolveRunId picks the newest started_at" $
      withSystemTempDirectory "hwfl-store-resolve" $ \dir -> do
        let older =
              RunMeta
                { rmRunId = "old",
                  rmProjectHash = "h",
                  rmEntry = "entry.md",
                  rmStartedAt = "2026-08-17T10:00:00Z",
                  rmStatus = "completed"
                }
            newer =
              RunMeta
                { rmRunId = "new",
                  rmProjectHash = "h",
                  rmEntry = "entry.md",
                  rmStartedAt = "2026-08-17T11:00:00Z",
                  rmStatus = "paused"
                }
        createRun (runRef dir "old") older >>= (`shouldSatisfy` isRight)
        createRun (runRef dir "new") newer >>= (`shouldSatisfy` isRight)
        resolveRunId dir Nothing `shouldReturn` Right "new"
        resolveRunId dir (Just latestRunAlias) `shouldReturn` Right "new"
        resolveRunId dir (Just "old") `shouldReturn` Right "old"

    it "resolveRunId fails when the workspace has no runs" $
      withSystemTempDirectory "hwfl-store-empty" $ \dir -> do
        resolveRunId dir Nothing
          `shouldReturn` Left ("no runs in workspace: " <> T.pack dir)

    it "generates unique collision-resistant run ids within the same second" $ do
      ids <- mapM (const newRunId) [1 .. 40 :: Int]
      length (Set.fromList ids) `shouldBe` 40
      all
        (\i -> T.isPrefixOf "run-" i && T.length i > length ("run-YYYYMMDD-HHMMSS" :: String))
        ids
        `shouldBe` True
      all hasEntropySuffix ids `shouldBe` True

  describe "run-id sanitization at the runtime boundary" $ do
    it "driverRun rejects a traversal run id before touching the filesystem" $
      withSystemTempDirectory "hwfl-run-escape" $ \dir -> do
        let workspace = dir </> "ws"
            path = dir </> "pure.md"
        createDirectoryIfMissing True workspace
        writeFile path (T.unpack pureModule)
        let req =
              (defaultDriverRunRequest path workspace mockProvider)
                { drrRunId = Just "../../escape"
                }
        result <- driverRun req
        case result of
          Right (OutcomeFailed err _ _) ->
            renderRuntimeError err `shouldSatisfy` T.isInfixOf "run id"
          other -> expectationFailure ("expected failure, got: " <> show other)
        doesDirectoryExist (dir </> "escape") `shouldReturn` False
        doesDirectoryExist (workspace </> ".hwfl") `shouldReturn` False

    it "driverRun refuses to create a run named latest" $
      withSystemTempDirectory "hwfl-run-latest" $ \dir -> do
        let path = dir </> "pure.md"
        writeFile path (T.unpack pureModule)
        let req =
              (defaultDriverRunRequest path dir mockProvider)
                { drrRunId = Just latestRunAlias
                }
        result <- driverRun req
        case result of
          Right (OutcomeFailed err _ _) ->
            renderRuntimeError err `shouldSatisfy` T.isInfixOf "reserved"
          other -> expectationFailure ("expected failure, got: " <> show other)
        doesDirectoryExist (dir </> ".hwfl") `shouldReturn` False

    it "driverRun refuses to start a second run under the same id" $
      withSystemTempDirectory "hwfl-run-reuse" $ \dir -> do
        let path = dir </> "pure.md"
        writeFile path (T.unpack pureModule)
        let req =
              (defaultDriverRunRequest path dir mockProvider)
                { drrRunId = Just "same"
                }
        first <- driverRun req
        case first of
          Right (OutcomeCompleted {}) -> pure ()
          other -> expectationFailure ("expected completed, got: " <> show other)
        second <- driverRun req
        case second of
          Right (OutcomeFailed err _ _) ->
            renderRuntimeError err `shouldSatisfy` T.isInfixOf "already exists"
          other -> expectationFailure ("expected failure, got: " <> show other)
        -- One run directory, still holding the first run's completed snapshot.
        metas <- driverListRuns dir
        map (.rmRunId) metas `shouldBe` ["same"]
        mSnap <- driverReadSnapshot (runRef dir "same")
        fmap (.rsStatus) mSnap `shouldBe` Just MsCompleted

    it "driverResume rejects an invalid run id and creates no run dir" $
      withSystemTempDirectory "hwfl-resume-escape" $ \dir -> do
        outcome <- driverResume dir "../../escape" mockProvider "model-catalog.json" noopObserver
        case outcome of
          OutcomeFailed err _ _ ->
            renderRuntimeError err `shouldSatisfy` T.isInfixOf "run id"
          other -> expectationFailure ("expected failure, got: " <> show other)
        doesDirectoryExist (dir </> ".hwfl") `shouldReturn` False
        listDirectory dir `shouldReturn` []
  where
    pureModule =
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
    hasEntropySuffix rid =
      case T.splitOn "-" rid of
        ["run", ymd, hms, nonce] ->
          T.length ymd == 8
            && T.length hms == 6
            && T.length nonce == 16
            && T.all (\c -> isDigit c || (c >= 'a' && c <= 'f')) nonce
        _ -> False
