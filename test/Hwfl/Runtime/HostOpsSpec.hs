module Hwfl.Runtime.HostOpsSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Project (ExecPolicy (..))
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Machine (MachineStatus (..), PauseReason (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    approveRun,
    runLoadedModule,
    emptySkillRuntime)
import Hwfl.Runtime.Workspace
import System.Directory (createDirectoryIfMissing)
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

confirmEcho :: Maybe ExecPolicy
confirmEcho =
  Just
    ExecPolicy
      { execAllow = ["echo"],
        execEnv = ["PATH"],
        execTimeoutMs = Just 5000,
        execMaxOutputBytes = Just 65536,
        execConfirm = True
      }

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
                    roDebug = False,
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
                    roDebug = False,
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
        case loadModuleText (dir </> "workflows" </> "echo.md") echoSrc of
          Left diags -> expectationFailure (show diags)
          Right loaded -> do
            let opts =
                  RunOptions
                    { roWorkspace = dir,
                      roProvider = mockProvider,
                      roInputs = [],
                      roRunId = Just "exec-confirm",
                      roEntry = dir </> "workflows" </> "echo.md",
                      roMode = StepRun,
                      roProjectHash = Nothing,
                      roExec = confirmEcho,
                    roDebug = False,
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime
                    }
            outcome <- runLoadedModule opts loaded
            case outcome of
              OutcomePaused (MsPaused (PauseAwaitingConfirm _)) _ _ _ -> do
                approved <- approveRun dir "exec-confirm" True mockProvider
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
                    roDebug = False,
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

isRight :: Either a b -> Bool
isRight = \case
  Right _ -> True
  Left _ -> False

isFailed :: RunOutcome -> Bool
isFailed = \case
  OutcomeFailed {} -> True
  _ -> False
