module Hwfl.Runtime.ObjectSpec (spec) where

import Data.Either (isRight)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider, mockProviderWith)
import Hwfl.Llm.Provider (LlmProvider)
import Hwfl.Llm.Types
  ( FinishReason (..),
    ProviderResult (..),
    TokenUsage (..),
  )
import Hwfl.Obs.Observer (noopObserver)
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Error (RuntimeError (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    runLoadedModule,
    emptySkillRuntime)
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
      "```hwfl",
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

  it "rejects a provider JSON response that violates schema(Out)" $
    withSystemTempDirectory "hwfl-object-invalid" $ \dir -> do
      let path = dir </> "object.md"
      writeFile path (T.unpack objectSrc)
      case loadModuleText path objectSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = invalidObjectMock,
                  roInputs = [],
                  roRunId = Just "e14-invalid",
                  roEntry = path,
                  roMode = StepRun,
                  roProjectHash = Nothing,
                  roExec = Nothing,
                  roObserver = noopObserver,
                  roCost = False,
                  roModelCatalog = "model-catalog.json",
                  roSkillCatalog = fst emptySkillRuntime,
                  roSkillModules = snd emptySkillRuntime,
                  roEntryModules = mempty
                }
              loaded
          case outcome of
            OutcomeFailed (HostErr err) _ _ ->
              err `shouldSatisfy` T.isInfixOf "score: expected integer"
            other -> expectationFailure ("expected schema validation failure, got " <> show other)

  it "E14 mock llm.object returns structured Out" $
    withSystemTempDirectory "hwfl-object" $ \dir -> do
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
                  roProjectHash = Nothing,
                    roExec = Nothing,
                    roObserver = noopObserver,
                    roCost = False,
                    roModelCatalog = "model-catalog.json",
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime, roEntryModules = mempty
                }
              loaded
          case outcome of
            OutcomeCompleted (VRecord fs) _store _ -> do
              case lookup (Ident "summary") fs of
                Just (VString s) -> s `shouldSatisfy` T.isPrefixOf "SUMMARY:"
                other -> expectationFailure ("bad summary: " <> show other)
              lookup (Ident "score") fs `shouldBe` Just (VInt 1)
            other -> expectationFailure (show other)

invalidObjectMock :: LlmProvider
invalidObjectMock =
  mockProviderWith $ \_ ->
    Right
      ProviderResult
        { prContent = "{\"summary\":\"scored\",\"score\":\"high\"}",
          prToolCalls = [],
          prUsage = Just (TokenUsage 1 1),
          prFinishReason = FinishStop
        }
