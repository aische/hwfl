module Pml.Runtime.SemanticCheckSpec (spec) where

import Data.Either (isRight)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Pml.Ast.Name (Ident (..))
import Pml.Check.Module (checkLoadedModule)
import Pml.Eval.Value (Value (..))
import Pml.Llm.Mock (mockProvider)
import Pml.Parse.Load (loadModule)
import Pml.Runtime.Eval (StepMode (..))
import Pml.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
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

spec :: Spec
spec = describe "semantic-check dogfood (M8 / E20)" $ do
  it "type-checks as a single module" $ do
    loaded <- loadModule checkerPath
    case loaded of
      Left diags -> expectationFailure (show diags)
      Right m -> checkLoadedModule m `shouldSatisfy` isRight

  it "reviews fixture workspace: structural + prose findings, writes report" $
    withSystemTempDirectory "pml-semcheck" $ \tmp -> do
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
                  roMode = StepRun
                }
              m
          case outcome of
            OutcomeCompleted (VRecord fs) _store _n -> do
              lookup (Ident "ok") fs `shouldBe` Just (VBool False)
              case lookup (Ident "finding_count") fs of
                Just (VInt n) -> n `shouldSatisfy` (> 0)
                other -> expectationFailure ("finding_count: " <> show other)
              doesFileExist (tmp </> "semantic-report.json") `shouldReturn` True
              report <- TIO.readFile (tmp </> "semantic-report.json")
              report `shouldSatisfy` T.isInfixOf "structural"
              report `shouldSatisfy` T.isInfixOf "workflows/missing"
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
