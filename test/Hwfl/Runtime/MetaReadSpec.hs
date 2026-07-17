module Hwfl.Runtime.MetaReadSpec (spec) where

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
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

childSrc :: Text
childSrc =
  T.unlines
    [ "---",
      "name: workflows/child",
      "inputs: {}",
      "outputs:",
      "  n: Int",
      "effects: []",
      "---",
      "",
      "```hwfl",
      "fun main(_): { n: Int } =",
      "  let _ = obs.span(\"score_me\")(fun () => 1)",
      "  { n = 1 }",
      "```"
    ]

parentSrc :: Text
parentSrc =
  T.unlines
    [ "---",
      "name: workflows/parent",
      "inputs: {}",
      "outputs:",
      "  invoke_ok: Bool",
      "  list_ok: Bool",
      "  run_count: Int",
      "  spans_ok: Bool",
      "  span_count: Int",
      "  filtered: Int",
      "  missing_ok: Bool",
      "effects: [Meta, Read]",
      "---",
      "",
      "```hwfl",
      "fun main(_): {",
      "  invoke_ok: Bool,",
      "  list_ok: Bool,",
      "  run_count: Int,",
      "  spans_ok: Bool,",
      "  span_count: Int,",
      "  filtered: Int,",
      "  missing_ok: Bool",
      "} =",
      "  let inv = meta.invoke(",
      "    project = \"candidates/child.md\",",
      "    workspace = \"trials/child\",",
      "    inputs = {}",
      "  )",
      "  let listed = meta.list_runs(workspace = \"trials/child\")",
      "  let spans = meta.read_spans(",
      "    run_id = inv.run_id,",
      "    workspace = \"trials/child\"",
      "  )",
      "  let filt = meta.read_spans(",
      "    run_id = inv.run_id,",
      "    workspace = \"trials/child\",",
      "    name_prefix = \"score_me\",",
      "    limit = 10",
      "  )",
      "  let miss = meta.read_spans(",
      "    run_id = \"no-such-run\",",
      "    workspace = \"trials/child\"",
      "  )",
      "  {",
      "    invoke_ok = inv.ok,",
      "    list_ok = listed.ok,",
      "    run_count = list.length(listed.runs),",
      "    spans_ok = spans.ok,",
      "    span_count = list.length(spans.spans),",
      "    filtered = list.length(filt.spans),",
      "    missing_ok = miss.ok",
      "  }",
      "```"
    ]

emptyListSrc :: Text
emptyListSrc =
  T.unlines
    [ "---",
      "name: workflows/empty_list",
      "inputs: {}",
      "outputs:",
      "  ok: Bool",
      "  n: Int",
      "effects: [Meta, Read]",
      "---",
      "",
      "```hwfl",
      "fun main(_): { ok: Bool, n: Int } =",
      "  let r = meta.list_runs(workspace = \"empty_ws\")",
      "  { ok = r.ok, n = list.length(r.runs) }",
      "```"
    ]

spec :: Spec
spec = describe "meta.list_runs / meta.read_spans" $ do
  it "lists nested runs and reads / filters spans" $
    withSystemTempDirectory "hwfl-meta-read" $ \dir -> do
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
                      roRunId = Just "parent-read",
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
                  lookup (Ident "invoke_ok") fs `shouldBe` Just (VBool True)
                  lookup (Ident "list_ok") fs `shouldBe` Just (VBool True)
                  lookup (Ident "run_count") fs `shouldBe` Just (VInt 1)
                  lookup (Ident "spans_ok") fs `shouldBe` Just (VBool True)
                  case lookup (Ident "span_count") fs of
                    Just (VInt n) -> n `shouldSatisfy` (>= 2)
                    other -> expectationFailure ("span_count: " <> show other)
                  case lookup (Ident "filtered") fs of
                    Just (VInt n) -> n `shouldSatisfy` (>= 1)
                    other -> expectationFailure ("filtered: " <> show other)
                  lookup (Ident "missing_ok") fs `shouldBe` Just (VBool False)
                other -> expectationFailure (show other)
              other -> expectationFailure (show other)

  it "returns ok=true with empty runs when workspace has no .hwfl/runs" $
    withSystemTempDirectory "hwfl-meta-list-empty" $ \dir -> do
      createDirectoryIfMissing True (dir </> "empty_ws")
      case loadModuleText "empty.md" emptyListSrc of
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
                      roRunId = Just "empty-list",
                      roEntry = "empty.md",
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
                  lookup (Ident "n") fs `shouldBe` Just (VInt 0)
                other -> expectationFailure (show other)
              other -> expectationFailure (show other)
