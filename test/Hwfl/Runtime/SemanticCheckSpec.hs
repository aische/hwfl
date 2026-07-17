module Hwfl.Runtime.SemanticCheckSpec (spec) where

import Data.Either (isRight)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Parse.Load (loadModule)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    emptySkillRuntime,
    runLoadedModule,
  )
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

checkerPath :: FilePath
checkerPath = "examples/semantic-check/workflows/main.md"

fixtureRoot :: FilePath
fixtureRoot = "test/fixtures/semantic-target"

baseInputs :: [(Ident, Value)]
baseInputs =
  [ (Ident "entry", VString "workflows/ok"),
    (Ident "mode", VString "deterministic"),
    (Ident "model", VString "mock")
  ]

runChecker :: FilePath -> [(Ident, Value)] -> T.Text -> IO RunOutcome
runChecker tmp inputs runId = do
  loaded <- loadModule checkerPath
  case loaded of
    Left diags -> expectationFailure (show diags) >> error "unreachable"
    Right m ->
      runLoadedModule
        RunOptions
          { roWorkspace = tmp,
            roProvider = mockProvider,
            roInputs = inputs,
            roRunId = Just runId,
            roEntry = checkerPath,
            roMode = StepRun,
            roProjectHash = Nothing,
            roExec = Nothing,
            roDebug = False,
            roModelCatalog = "model-catalog.json",
            roSkillCatalog = fst emptySkillRuntime,
            roSkillModules = snd emptySkillRuntime
          }
        m

spec :: Spec
spec = describe "semantic-check dogfood (M8 / E20 deepen)" $ do
  it "type-checks as a single module" $ do
    loaded <- loadModule checkerPath
    case loaded of
      Left diags -> expectationFailure (show diags)
      Right m -> checkLoadedModule m `shouldSatisfy` isRight

  it "reviews fixture workspace: structural + prose findings, body-bearing gate" $
    withSystemTempDirectory "hwfl-semcheck" $ \tmp -> do
      copyTree fixtureRoot tmp
      outcome <- runChecker tmp baseInputs "e20"
      case outcome of
        OutcomeCompleted (VRecord fs) _store _n -> do
          lookup (Ident "ok") fs `shouldBe` Just (VBool False)
          case lookup (Ident "finding_count") fs of
            Just (VInt n) -> n `shouldSatisfy` (> 0)
            other -> expectationFailure ("finding_count: " <> show other)
          doesFileExist (tmp </> ".hwfl/runs/e20/semantic-report.json") `shouldReturn` True
          report <- TIO.readFile (tmp </> ".hwfl/runs/e20/semantic-report.json")
          report `shouldSatisfy` T.isInfixOf "\"schema\""
          report `shouldSatisfy` T.isInfixOf "workflows/missing"
          report `shouldSatisfy` T.isInfixOf "\"review_gate\""
          report `shouldSatisfy` T.isInfixOf "\"slice_id\""
          report `shouldSatisfy` T.isInfixOf "check_dead_reference"
          report `shouldSatisfy` T.isInfixOf "\"mode\":\"deterministic\""
          report `shouldSatisfy` T.isInfixOf "\"pragmatic_findings\":[]"
        other -> expectationFailure ("expected completed run, got: " <> show other)

  it "pragmatic mode runs gated llm.object and records pragmatic_findings" $
    withSystemTempDirectory "hwfl-semcheck-prag" $ \tmp -> do
      copyTree fixtureRoot tmp
      let inputs =
            [ (Ident "entry", VString "workflows/ok"),
              (Ident "mode", VString "pragmatic"),
              (Ident "model", VString "mock")
            ]
      outcome <- runChecker tmp inputs "e20p"
      case outcome of
        OutcomeCompleted (VRecord fs) _store _n -> do
          lookup (Ident "ok") fs `shouldBe` Just (VBool False)
          report <- TIO.readFile (tmp </> ".hwfl/runs/e20p/semantic-report.json")
          report `shouldSatisfy` T.isInfixOf "\"mode\":\"pragmatic\""
          report `shouldSatisfy` T.isInfixOf "\"pragmatic_findings\""
          report `shouldSatisfy` T.isInfixOf "\"review_gate\""
          -- Mock fills schema strings from the prompt; felicity rows appear unless bled.
          report `shouldSatisfy` (not . T.isInfixOf "\"pragmatic_findings\":[]")
        other -> expectationFailure ("expected completed run, got: " <> show other)

copyTree :: FilePath -> FilePath -> IO ()
copyTree src dst = do
  createDirectoryIfMissing True (dst </> "workflows")
  createDirectoryIfMissing True (dst </> "lib")
  mapM_
    ( \rel -> copyFile (src </> rel) (dst </> rel)
    )
    [ "workflows/ok.md",
      "workflows/bad.md",
      "lib/search.md"
    ]
