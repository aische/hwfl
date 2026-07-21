module Hwfl.Runtime.MetaInvokeSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Obs.Observer (noopObserver)
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Runtime.Error (RuntimeError (..))
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    emptySkillRuntime,
    runLoadedModule,
  )
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

parentSrc :: Text
parentSrc =
  T.unlines
    [ "---",
      "name: workflows/parent",
      "inputs: {}",
      "outputs:",
      "  ok: Bool",
      "  status: String",
      "  run_id: String",
      "effects: [Meta, Read]",
      "---",
      "",
      "```hwfl",
      "fun main(_): { ok: Bool, status: String, run_id: String } =",
      "  let r = meta.invoke(",
      "    project = \"candidates/child.md\",",
      "    workspace = \"trials/child\",",
      "    inputs = { n = 7 }",
      "  )",
      "  { ok = r.ok, status = r.status, run_id = r.run_id }",
      "```"
    ]

childSrc :: Text
childSrc =
  T.unlines
    [ "---",
      "name: workflows/child",
      "inputs:",
      "  n: Int",
      "outputs:",
      "  n: Int",
      "effects: [Write]",
      "---",
      "",
      "```hwfl",
      "fun main(inputs): { n: Int } =",
      "  let _ = fs.write(path = \"out.txt\", text = \"n=7\")",
      "  { n = inputs.n }",
      "```"
    ]

badParentSrc :: Text
badParentSrc =
  T.unlines
    [ "---",
      "name: workflows/bad_parent",
      "inputs: {}",
      "outputs:",
      "  ok: Bool",
      "  status: String",
      "effects: [Meta, Read]",
      "---",
      "",
      "```hwfl",
      "fun main(_): { ok: Bool, status: String } =",
      "  let r = meta.invoke(",
      "    project = \"missing.md\",",
      "    workspace = \"trials/x\",",
      "    inputs = {}",
      "  )",
      "  { ok = r.ok, status = r.status }",
      "```"
    ]

escapeParentSrc :: Text -> Text -> Text
escapeParentSrc project workspace =
  T.unlines
    [ "---",
      "name: workflows/escape_parent",
      "inputs: {}",
      "outputs:",
      "  ok: Bool",
      "effects: [Meta, Read]",
      "---",
      "",
      "```hwfl",
      "fun main(_): { ok: Bool } =",
      "  let r = meta.invoke(",
      "    project = \"" <> project <> "\",",
      "    workspace = \"" <> workspace <> "\",",
      "    inputs = {}",
      "  )",
      "  { ok = r.ok }",
      "```"
    ]

runParent :: FilePath -> Text -> Text -> IO RunOutcome
runParent dir src runId =
  case loadModuleText "parent.md" src of
    Left diags -> expectationFailure (show diags) >> error "unreachable"
    Right loaded -> case checkLoadedModule loaded of
      Left err -> expectationFailure (show err) >> error "unreachable"
      Right _ -> do
        let (catalog, skillMods) = emptySkillRuntime
            opts =
              RunOptions
                { roWorkspace = dir,
                  roProvider = mockProvider,
                  roInputs = [],
                  roRunId = Just runId,
                  roEntry = "parent.md",
                  roMode = StepRun,
                  roProjectHash = Nothing,
                  roExec = Nothing,
                  roObserver = noopObserver,
                  roCost = False,
                  roModelCatalog = "model-catalog.json",
                  roSkillCatalog = catalog,
                  roSkillModules = skillMods,
                  roEntryModules = mempty
                }
        runLoadedModule opts loaded

spec :: Spec
spec = describe "meta.invoke" $ do
  it "runs a nested module under workspace-relative project/workspace paths" $
    withSystemTempDirectory "hwfl-meta-invoke" $ \dir -> do
      createDirectoryIfMissing True (dir </> "candidates")
      createDirectoryIfMissing True (dir </> "trials" </> "child")
      writeFile (dir </> "candidates" </> "child.md") (T.unpack childSrc)
      outcome <- runParent dir parentSrc "parent-run"
      case outcome of
        OutcomeCompleted val _ _ -> case val of
          VRecord fs -> do
            lookup (Ident "ok") fs `shouldBe` Just (VBool True)
            lookup (Ident "status") fs `shouldBe` Just (VString "completed")
            case lookup (Ident "run_id") fs of
              Just (VString rid) -> T.isPrefixOf "run-" rid `shouldBe` True
              other -> expectationFailure ("expected run_id, got: " <> show other)
            doesFileExist (dir </> "trials" </> "child" </> "out.txt")
              >>= (`shouldBe` True)
          other -> expectationFailure (show other)
        other -> expectationFailure (show other)

  it "returns ok=false when the nested project path is missing" $
    withSystemTempDirectory "hwfl-meta-invoke-miss" $ \dir -> do
      createDirectoryIfMissing True (dir </> "trials" </> "x")
      outcome <- runParent dir badParentSrc "parent-miss"
      case outcome of
        OutcomeCompleted val _ _ -> case val of
          VRecord fs -> do
            lookup (Ident "ok") fs `shouldBe` Just (VBool False)
            lookup (Ident "status") fs `shouldBe` Just (VString "error")
          other -> expectationFailure (show other)
        other -> expectationFailure (show other)

  it "rejects an absolute project path" $
    withSystemTempDirectory "hwfl-meta-invoke-abs" $ \dir -> do
      outcome <-
        runParent dir (escapeParentSrc "/etc/passwd" "trials/x") "parent-abs"
      case outcome of
        OutcomeFailed (SandboxErr msg) _ _ ->
          T.isInfixOf "absolute paths are not allowed" msg `shouldBe` True
        other -> expectationFailure ("expected SandboxErr, got: " <> show other)

  it "rejects a project path that escapes via .." $
    withSystemTempDirectory "hwfl-meta-invoke-dotdot" $ \dir -> do
      outcome <-
        runParent dir (escapeParentSrc "../outside.md" "trials/x") "parent-dotdot"
      case outcome of
        OutcomeFailed (SandboxErr msg) _ _ ->
          T.isInfixOf "path escapes the workspace root" msg `shouldBe` True
        other -> expectationFailure ("expected SandboxErr, got: " <> show other)

  it "rejects a workspace path that escapes via .." $
    withSystemTempDirectory "hwfl-meta-invoke-ws-escape" $ \dir -> do
      createDirectoryIfMissing True (dir </> "candidates")
      writeFile (dir </> "candidates" </> "child.md") (T.unpack childSrc)
      outcome <-
        runParent
          dir
          (escapeParentSrc "candidates/child.md" "../outside-ws")
          "parent-ws-escape"
      case outcome of
        OutcomeFailed (SandboxErr msg) _ _ ->
          T.isInfixOf "path escapes the workspace root" msg `shouldBe` True
        other -> expectationFailure ("expected SandboxErr, got: " <> show other)
