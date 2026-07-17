module Hwfl.Runtime.MetaInvokeSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Parse.Load (loadModuleText)
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

spec :: Spec
spec = describe "meta.invoke" $ do
  it "runs a nested module under workspace-relative project/workspace paths" $
    withSystemTempDirectory "hwfl-meta-invoke" $ \dir -> do
      createDirectoryIfMissing True (dir </> "candidates")
      createDirectoryIfMissing True (dir </> "trials" </> "child")
      writeFile (dir </> "candidates" </> "child.md") (T.unpack childSrc)
      case loadModuleText "parent.md" parentSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> case checkLoadedModule loaded of
          Left err -> expectationFailure (show err)
          Right _ -> do
            let (catalog, skillMods) = emptySkillRuntime
                opts =
                  RunOptions
                    { roWorkspace = dir,
                      roProvider = mockProvider,
                      roInputs = [],
                      roRunId = Just "parent-run",
                      roEntry = "parent.md",
                      roMode = StepRun,
                      roProjectHash = Nothing,
                      roExec = Nothing,
                      roDebug = False,
                      roCost = False,
                      roModelCatalog = "model-catalog.json",
                      roSkillCatalog = catalog,
                      roSkillModules = skillMods
                    }
            outcome <- runLoadedModule opts loaded
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
      case loadModuleText "bad.md" badParentSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> case checkLoadedModule loaded of
          Left err -> expectationFailure (show err)
          Right _ -> do
            let (catalog, skillMods) = emptySkillRuntime
                opts =
                  RunOptions
                    { roWorkspace = dir,
                      roProvider = mockProvider,
                      roInputs = [],
                      roRunId = Just "parent-miss",
                      roEntry = "bad.md",
                      roMode = StepRun,
                      roProjectHash = Nothing,
                      roExec = Nothing,
                      roDebug = False,
                      roCost = False,
                      roModelCatalog = "model-catalog.json",
                      roSkillCatalog = catalog,
                      roSkillModules = skillMods
                    }
            outcome <- runLoadedModule opts loaded
            case outcome of
              OutcomeCompleted val _ _ -> case val of
                VRecord fs -> do
                  lookup (Ident "ok") fs `shouldBe` Just (VBool False)
                  lookup (Ident "status") fs `shouldBe` Just (VString "error")
                other -> expectationFailure (show other)
              other -> expectationFailure (show other)
