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
    runLoadedModule,
    emptySkillRuntime)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

checkerPath :: FilePath
checkerPath = "examples/semantic-check/workflows/main.md"

fixtureRoot :: FilePath
fixtureRoot = "test/fixtures/semantic-target"

spec :: Spec
spec = describe "semantic-check dogfood (M8 / E20)" $ do
  it "type-checks as a single module" $ do
    loaded <- loadModule checkerPath
    case loaded of
      Left diags -> expectationFailure (show diags)
      Right m -> checkLoadedModule m `shouldSatisfy` isRight

  it "reviews fixture workspace: structural + prose findings, writes report" $
    withSystemTempDirectory "hwfl-semcheck" $ \tmp -> do
      copyTree fixtureRoot tmp
      loaded <- loadModule checkerPath
      case loaded of
        Left diags -> expectationFailure (show diags)
        Right m -> do
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = tmp,
                  roProvider = mockProvider,
                  roInputs = [(Ident "entry", VString "workflows/ok")],
                  roRunId = Just "e20",
                  roEntry = checkerPath,
                  roMode = StepRun,
                  roProjectHash = Nothing,
                    roExec = Nothing,
                    roDebug = False,
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime
                }
              m
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
