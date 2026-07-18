module Hwfl.Runtime.HostOpsSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Driver
  ( DriverRunRequest (..),
    defaultDriverRunRequest,
    driverApprove,
    driverRun,
  )
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Obs.Observer (noopObserver)
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Project (ExecPolicy (..))
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Machine (MachineStatus (..), PauseReason (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    runLoadedModule,
    emptySkillRuntime)
import Hwfl.Runtime.Workspace
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

echoSrc :: Text
echoSrc =
  T.unlines
    [ "---",
      "name: workflows/echo",
      "inputs: {}",
      "outputs:",
      "  code: Int",
      "  out: String",
      "effects: [Exec]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { code: Int, out: String } =",
      "  let r = exec.run(program = \"echo\", args = [\"hi\"], stdin = \"\")",
      "  { code = r.exit_code, out = r.stdout }",
      "```"
    ]

fsSrc :: Text
fsSrc =
  T.unlines
    [ "---",
      "name: workflows/fsops",
      "inputs: {}",
      "outputs:",
      "  listed: Int",
      "  hits: Int",
      "  ok: Bool",
      "effects: [Read, Write]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { listed: Int, hits: Int, ok: Bool } =",
      "  let entries = fs.list(\"src\")",
      "  let hits = fs.grep(pattern = \"alpha\", glob = \"**/*.txt\")",
      "  let edited = fs.edit(path = \"src/a.txt\", old = \"alpha\", new = \"beta\")",
      "  { listed = list.length(entries), hits = list.length(hits), ok = edited.ok }",
      "```"
    ]

denySrc :: Text
denySrc =
  T.unlines
    [ "---",
      "name: workflows/deny",
      "inputs: {}",
      "outputs:",
      "  code: Int",
      "effects: [Exec]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { code: Int } =",
      "  let r = exec.run(program = \"rm\", args = [\"-rf\", \"/\"], stdin = \"\")",
      "  { code = r.exit_code }",
      "```"
    ]

allowEcho :: Maybe ExecPolicy
allowEcho =
  Just
    ExecPolicy
      { execAllow = ["echo"],
        execEnv = ["PATH"],
        execTimeoutMs = Just 5000,
        execMaxOutputBytes = Just 65536,
        execConfirm = False
      }

fsSliceRemoveSrc :: Text
fsSliceRemoveSrc =
  T.unlines
    [ "---",
      "name: workflows/fs-slice-remove",
      "inputs: {}",
      "outputs:",
      "  slice: String",
      "  removed: Bool",
      "effects: [Read, Write]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { slice: String, removed: Bool } =",
      "  let part = fs.read_slice(path = \"src/a.txt\", start_line = 2, end_line = 3)",
      "  let _ = fs.remove(\"src/tmp.txt\")",
      "  { slice = part.text, removed = true }",
      "```"
    ]

fsPatchSrc :: Text
fsPatchSrc =
  T.unlines
    [ "---",
      "name: workflows/fs-patch",
      "inputs: {}",
      "outputs:",
      "  ok: Bool",
      "  applied: Int",
      "  error: String",
      "effects: [Read, Write]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { ok: Bool, applied: Int, error: String } =",
      "  let r = fs.patch(",
      "    path = \"src/a.txt\",",
      "    hunks = [",
      "      { old = \"alpha\", new = \"ALPHA\" },",
      "      { old = \"gamma\", new = \"GAMMA\" }",
      "    ]",
      "  )",
      "  { ok = r.ok, applied = r.applied, error = r.error }",
      "```"
    ]

spec :: Spec
spec = describe "host ops P0 (exec + fs)" $ do
  describe "workspace helpers" $ do
    it "lists dirs with kind tags" $
      withSystemTempDirectory "hwfl-list" $ \dir -> do
        ws <- newWorkspace dir
        createDirectoryIfMissing True (dir </> "sub")
        _ <- writeTextFile ws "a.txt" "x"
        r <- listDir ws "."
        case r of
          Left e -> expectationFailure (show e)
          Right entries -> do
            entries `shouldContain` [("a.txt", "file")]
            entries `shouldContain` [("sub", "dir")]

    it "edits and greps text files" $
      withSystemTempDirectory "hwfl-grep" $ \dir -> do
        ws <- newWorkspace dir
        _ <- writeTextFile ws "src/a.txt" "alpha\nbeta\nalpha"
        edit <- editFile ws "src/a.txt" "alpha" "gamma"
        edit `shouldBe` Right (True, 2)
        grep <- grepFiles ws "gamma" "**/*.txt"
        case grep of
          Left e -> expectationFailure (show e)
          Right hits -> length hits `shouldBe` 2

    it "patches unique multi-hunk edits atomically" $
      withSystemTempDirectory "hwfl-patch" $ \dir -> do
        ws <- newWorkspace dir
        _ <- writeTextFile ws "src/a.txt" "alpha\nbeta\ngamma\n"
        ok <-
          patchFile
            ws
            "src/a.txt"
            [("alpha", "ALPHA"), ("gamma", "GAMMA")]
        ok `shouldBe` Right (True, 2, "")
        readTextFile ws "src/a.txt" >>= \case
          Left e -> expectationFailure (show e)
          Right t -> t `shouldBe` "ALPHA\nbeta\nGAMMA\n"

    it "rejects ambiguous patch hunks without writing" $
      withSystemTempDirectory "hwfl-patch-ambig" $ \dir -> do
        ws <- newWorkspace dir
        _ <- writeTextFile ws "src/a.txt" "aa\naa\n"
        bad <- patchFile ws "src/a.txt" [("aa", "bb")]
        case bad of
          Right (False, 0, err) ->
            err `shouldSatisfy` T.isInfixOf "matches 2 times"
          other -> expectationFailure (show other)
        readTextFile ws "src/a.txt" >>= \case
          Left e -> expectationFailure (show e)
          Right t -> t `shouldBe` "aa\naa\n"

    it "rejects a later missing hunk without writing earlier ones" $
      withSystemTempDirectory "hwfl-patch-miss" $ \dir -> do
        ws <- newWorkspace dir
        _ <- writeTextFile ws "src/a.txt" "keep\n"
        bad <-
          patchFile
            ws
            "src/a.txt"
            [("keep", "KEEP"), ("missing", "x")]
        case bad of
          Right (False, 0, err) ->
            err `shouldSatisfy` T.isInfixOf "hunk 2"
          other -> expectationFailure (show other)
        readTextFile ws "src/a.txt" >>= \case
          Left e -> expectationFailure (show e)
          Right t -> t `shouldBe` "keep\n"

    it "reads an inclusive line slice" $
      withSystemTempDirectory "hwfl-slice" $ \dir -> do
        ws <- newWorkspace dir
        _ <- writeTextFile ws "lines.txt" "one\ntwo\nthree\nfour\n"
        slice <- readTextSlice ws "lines.txt" 2 3
        slice `shouldBe` Right "two\nthree\n"

    it "rejects invalid line ranges" $
      withSystemTempDirectory "hwfl-slice-bad" $ \dir -> do
        ws <- newWorkspace dir
        _ <- writeTextFile ws "x.txt" "a\n"
        r <- readTextSlice ws "x.txt" 2 1
        r `shouldSatisfy` isLeft

    it "removes files and directories" $
      withSystemTempDirectory "hwfl-remove" $ \dir -> do
        ws <- newWorkspace dir
        _ <- writeTextFile ws "gone.txt" "bye"
        createDirectoryIfMissing True (dir </> "sub")
        writeFile (dir </> "sub" </> "inner.txt") "x"
        rmFile <- removePath ws "gone.txt"
        rmFile `shouldBe` Right ()
        exists <- doesFileExist (dir </> "gone.txt")
        exists `shouldBe` False
        rmDir <- removePath ws "sub"
        rmDir `shouldBe` Right ()
        subExists <- doesDirectoryExist (dir </> "sub")
        subExists `shouldBe` False

  describe "exec.run" $ do
    it "runs an allowlisted program and captures stdout" $
      withSystemTempDirectory "hwfl-exec" $ \dir -> do
        case loadModuleText "echo.md" echoSrc of
          Left diags -> expectationFailure (show diags)
          Right loaded -> do
            checkLoadedModule loaded `shouldSatisfy` isRight
            let opts =
                  RunOptions
                    { roWorkspace = dir,
                      roProvider = mockProvider,
                      roInputs = [],
                      roRunId = Just "exec-ok",
                      roEntry = "echo.md",
                      roMode = StepRun,
                      roProjectHash = Nothing,
                      roExec = allowEcho,
                    roObserver = noopObserver,
                    roCost = False,
                    roModelCatalog = "model-catalog.json",
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime
                    }
            outcome <- runLoadedModule opts loaded
            case outcome of
              OutcomeCompleted val _ _ ->
                case val of
                  VRecord fs -> do
                    lookup (Ident "code") fs `shouldBe` Just (VInt 0)
                    case lookup (Ident "out") fs of
                      Just (VString s) -> T.strip s `shouldBe` "hi"
                      other -> expectationFailure (show other)
                  other -> expectationFailure (show other)
              other -> expectationFailure (show other)

    it "rejects programs outside the allowlist" $
      withSystemTempDirectory "hwfl-exec-deny" $ \dir -> do
        case loadModuleText "deny.md" denySrc of
          Left diags -> expectationFailure (show diags)
          Right loaded -> do
            let opts =
                  RunOptions
                    { roWorkspace = dir,
                      roProvider = mockProvider,
                      roInputs = [],
                      roRunId = Just "exec-deny",
                      roEntry = "deny.md",
                      roMode = StepRun,
                      roProjectHash = Nothing,
                      roExec = allowEcho,
                    roObserver = noopObserver,
                    roCost = False,
                    roModelCatalog = "model-catalog.json",
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime
                    }
            outcome <- runLoadedModule opts loaded
            outcome `shouldSatisfy` isFailed

    it "pauses when exec.confirm is true; approve runs the command" $
      withSystemTempDirectory "hwfl-exec-confirm" $ \dir -> do
        writeFile
          (dir </> "project.json")
          ( T.unpack $
              T.unlines
                [ "{",
                  "  \"name\": \"t\",",
                  "  \"version\": \"0.1.0\",",
                  "  \"entrypoint\": \"workflows/echo\",",
                  "  \"exec\": {",
                  "    \"allow\": [\"echo\"],",
                  "    \"env\": [\"PATH\"],",
                  "    \"confirm\": true",
                  "  }",
                  "}"
                ]
          )
        createDirectoryIfMissing True (dir </> "workflows")
        writeFile (dir </> "workflows" </> "echo.md") (T.unpack echoSrc)
        -- Must start as a project run (projectHashForModules); approve
        -- re-resolves the project root from the entry path.
        let req =
              (defaultDriverRunRequest dir dir mockProvider)
                { drrRunId = Just "exec-confirm",
                  drrModelCatalog = "model-catalog.json"
                }
        result <- driverRun req
        case result of
          Right (OutcomePaused (MsPaused (PauseAwaitingConfirm _)) _ _ _) -> do
            approved <-
              driverApprove dir "exec-confirm" True mockProvider "model-catalog.json" noopObserver
            case approved of
              OutcomeCompleted val _ _ ->
                case val of
                  VRecord fs -> lookup (Ident "code") fs `shouldBe` Just (VInt 0)
                  other -> expectationFailure (show other)
              other -> expectationFailure (show other)
          other -> expectationFailure (show other)

  describe "fs.list / fs.edit / fs.grep" $ do
    it "runs through the machine" $
      withSystemTempDirectory "hwfl-fsops" $ \dir -> do
        createDirectoryIfMissing True (dir </> "src")
        writeFile (dir </> "src" </> "a.txt") "alpha\n"
        case loadModuleText "fsops.md" fsSrc of
          Left diags -> expectationFailure (show diags)
          Right loaded -> do
            checkLoadedModule loaded `shouldSatisfy` isRight
            let opts =
                  RunOptions
                    { roWorkspace = dir,
                      roProvider = mockProvider,
                      roInputs = [],
                      roRunId = Just "fsops",
                      roEntry = "fsops.md",
                      roMode = StepRun,
                      roProjectHash = Nothing,
                      roExec = Nothing,
                    roObserver = noopObserver,
                    roCost = False,
                    roModelCatalog = "model-catalog.json",
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime
                    }
            outcome <- runLoadedModule opts loaded
            case outcome of
              OutcomeCompleted val _ _ ->
                case val of
                  VRecord fs -> do
                    lookup (Ident "listed") fs `shouldBe` Just (VInt 1)
                    lookup (Ident "hits") fs `shouldBe` Just (VInt 1)
                    lookup (Ident "ok") fs `shouldBe` Just (VBool True)
                  other -> expectationFailure (show other)
              other -> expectationFailure (show other)

  describe "fs.read_slice / fs.remove" $ do
    it "runs through the machine" $
      withSystemTempDirectory "hwfl-slice-remove" $ \dir -> do
        createDirectoryIfMissing True (dir </> "src")
        writeFile (dir </> "src" </> "a.txt") "one\ntwo\nthree\n"
        writeFile (dir </> "src" </> "tmp.txt") "delete me\n"
        case loadModuleText "slice-remove.md" fsSliceRemoveSrc of
          Left diags -> expectationFailure (show diags)
          Right loaded -> do
            checkLoadedModule loaded `shouldSatisfy` isRight
            let opts =
                  RunOptions
                    { roWorkspace = dir,
                      roProvider = mockProvider,
                      roInputs = [],
                      roRunId = Just "slice-remove",
                      roEntry = "slice-remove.md",
                      roMode = StepRun,
                      roProjectHash = Nothing,
                      roExec = Nothing,
                      roObserver = noopObserver,
                      roCost = False,
                      roModelCatalog = "model-catalog.json",
                      roSkillCatalog = fst emptySkillRuntime,
                      roSkillModules = snd emptySkillRuntime
                    }
            outcome <- runLoadedModule opts loaded
            case outcome of
              OutcomeCompleted val _ _ -> do
                case val of
                  VRecord fs -> do
                    lookup (Ident "removed") fs `shouldBe` Just (VBool True)
                    case lookup (Ident "slice") fs of
                      Just (VString s) -> T.stripEnd s `shouldBe` "two\nthree"
                      other -> expectationFailure (show other)
                  other -> expectationFailure (show other)
                tmpExists <- doesFileExist (dir </> "src" </> "tmp.txt")
                tmpExists `shouldBe` False
              other -> expectationFailure (show other)

  describe "fs.patch" $ do
    it "runs through the machine" $
      withSystemTempDirectory "hwfl-fs-patch" $ \dir -> do
        createDirectoryIfMissing True (dir </> "src")
        writeFile (dir </> "src" </> "a.txt") "alpha\nbeta\ngamma\n"
        case loadModuleText "fs-patch.md" fsPatchSrc of
          Left diags -> expectationFailure (show diags)
          Right loaded -> do
            checkLoadedModule loaded `shouldSatisfy` isRight
            let opts =
                  RunOptions
                    { roWorkspace = dir,
                      roProvider = mockProvider,
                      roInputs = [],
                      roRunId = Just "fs-patch",
                      roEntry = "fs-patch.md",
                      roMode = StepRun,
                      roProjectHash = Nothing,
                      roExec = Nothing,
                      roObserver = noopObserver,
                      roCost = False,
                      roModelCatalog = "model-catalog.json",
                      roSkillCatalog = fst emptySkillRuntime,
                      roSkillModules = snd emptySkillRuntime
                    }
            outcome <- runLoadedModule opts loaded
            case outcome of
              OutcomeCompleted val _ _ -> do
                case val of
                  VRecord fs -> do
                    lookup (Ident "ok") fs `shouldBe` Just (VBool True)
                    lookup (Ident "applied") fs `shouldBe` Just (VInt 2)
                    lookup (Ident "error") fs `shouldBe` Just (VString "")
                  other -> expectationFailure (show other)
                contents <- readFile (dir </> "src" </> "a.txt")
                contents `shouldBe` "ALPHA\nbeta\nGAMMA\n"
              other -> expectationFailure (show other)

isRight :: Either a b -> Bool
isRight = \case
  Right _ -> True
  Left _ -> False

isLeft :: Either a b -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False

isFailed :: RunOutcome -> Bool
isFailed = \case
  OutcomeFailed {} -> True
  _ -> False
