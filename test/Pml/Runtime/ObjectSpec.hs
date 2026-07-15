module Pml.Runtime.ObjectSpec (spec) where

import Data.Either (isRight)
import Data.Text (Text)
import Data.Text qualified as T
import Pml.Ast.Name (Ident (..))
import Pml.Check.Module (checkLoadedModule)
import Pml.Eval.Value (Value (..))
import Pml.Llm.Mock (mockProvider)
import Pml.Parse.Load (loadModuleText)
import Pml.Runtime.Eval (StepMode (..))
import Pml.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    runLoadedModule,
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

objectSrc :: Text
objectSrc =
  T.unlines
    [ "---",
      "name: workflows/e14-object",
      "inputs: {}",
      "outputs:",
      "  summary: String",
      "  score: Int",
      "effects: [Net]",
      "---",
      "",
      "## body",
      "",
      "```pml",
      "type Out = { summary: String, score: Int }",
      "",
      "fun main(_): Out =",
      "  llm.object(",
      "    prompt = \"score this note\",",
      "    schema = schema(Out),",
      "    model = \"gpt-5\"",
      "  )",
      "```"
    ]

spec :: Spec
spec = describe "runtime llm.object (E14)" $ do
  it "checks schema(Out) result type as Out" $
    case loadModuleText "object.md" objectSrc of
      Left diags -> expectationFailure (show diags)
      Right loaded -> checkLoadedModule loaded `shouldSatisfy` isRight

  it "E14 mock llm.object returns structured Out" $
    withSystemTempDirectory "pml-object" $ \dir -> do
      let path = dir </> "object.md"
      writeFile path (T.unpack objectSrc)
      case loadModuleText path objectSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = mockProvider,
                  roInputs = [],
                  roRunId = Just "e14",
                  roEntry = path,
                  roMode = StepRun,
                  roProjectHash = Nothing
                }
              loaded
          case outcome of
            OutcomeCompleted (VRecord fs) _store _ -> do
              case lookup (Ident "summary") fs of
                Just (VString s) -> s `shouldSatisfy` T.isPrefixOf "SUMMARY:"
                other -> expectationFailure ("bad summary: " <> show other)
              lookup (Ident "score") fs `shouldBe` Just (VInt 1)
            other -> expectationFailure (show other)
