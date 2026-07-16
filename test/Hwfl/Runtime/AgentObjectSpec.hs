module Hwfl.Runtime.AgentObjectSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Either (isRight)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProviderWith)
import Hwfl.Llm.Provider (LlmProvider (..))
import Hwfl.Llm.Types
  ( ChatRequest (..),
    FinishReason (..),
    ProviderResult (..),
    TokenUsage (..),
    ToolCall (..),
    Turn (..),
  )
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    runLoadedModule,
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

agentObjectSrc :: Text
agentObjectSrc =
  T.unlines
    [ "---",
      "name: workflows/e16-agent-object",
      "inputs: {}",
      "outputs:",
      "  summary: String",
      "  score: Int",
      "  rounds: Int",
      "effects: [Read, Net]",
      "---",
      "",
      "## system",
      "",
      "Use tools then call submit alone with the structured result.",
      "",
      "## body",
      "",
      "```hwfl",
      "type Out = { summary: String, score: Int }",
      "",
      "fun search(q: String): String =",
      "  $\"hit:{q}\"",
      "",
      "fun main(_): { summary: String, score: Int, rounds: Int } =",
      "  let result = llm.agent_object(",
      "    system = @system,",
      "    prompt = \"score the note\",",
      "    tools = [tool(fs.read), tool(search)],",
      "    schema = schema(Out),",
      "    model = \"gpt-5\",",
      "    max_rounds = 4",
      "  )",
      "  { summary = result.value.summary, score = result.value.score, rounds = result.rounds }",
      "```"
    ]

-- | Round 0: fs_read + search; round 1: submit alone.
agentObjectMock :: LlmProvider
agentObjectMock = mockProviderWith reply
  where
    reply :: ChatRequest -> Either a ProviderResult
    reply req
      | any isToolTurn req.chatTurns =
          Right
            ProviderResult
              { prContent = "done",
                prToolCalls =
                  [ ToolCall
                      "c3"
                      "submit"
                      ( object
                          [ "summary" .= ("SUMMARY: scored" :: Text),
                            "score" .= (7 :: Int)
                          ]
                      )
                  ],
                prUsage = Just (TokenUsage 1 1),
                prFinishReason = FinishToolCalls
              }
      | otherwise =
          Right
            ProviderResult
              { prContent = "need tools",
                prToolCalls =
                  [ ToolCall
                      "c1"
                      "fs_read"
                      (object ["path" .= ("note.txt" :: Text)]),
                    ToolCall
                      "c2"
                      "search"
                      (object ["q" .= ("note" :: Text)])
                  ],
                prUsage = Just (TokenUsage 1 1),
                prFinishReason = FinishToolCalls
              }
    isToolTurn = \case
      TurnTool _ -> True
      _ -> False

plainTextMock :: LlmProvider
plainTextMock = mockProviderWith $ \_ ->
  Right
    ProviderResult
      { prContent = "I forgot to submit",
        prToolCalls = [],
        prUsage = Just (TokenUsage 1 1),
        prFinishReason = FinishStop
      }

spec :: Spec
spec = describe "runtime llm.agent_object" $ do
  it "checks schema(Out) as { value: Out, rounds: Int }" $
    case loadModuleText "agent-object.md" agentObjectSrc of
      Left diags -> expectationFailure (show diags)
      Right loaded -> checkLoadedModule loaded `shouldSatisfy` isRight

  it "tools then submit return typed value + rounds" $
    withSystemTempDirectory "hwfl-agent-object" $ \dir -> do
      writeFile (dir </> "note.txt") "hello note"
      let path = dir </> "agent-object.md"
      writeFile path (T.unpack agentObjectSrc)
      case loadModuleText path agentObjectSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = agentObjectMock,
                  roInputs = [],
                  roRunId = Just "ao1",
                  roEntry = path,
                  roMode = StepRun,
                  roProjectHash = Nothing,
                    roExec = Nothing
                }
              loaded
          case outcome of
            OutcomeCompleted (VRecord fs) _store _ -> do
              lookup (Ident "summary") fs `shouldBe` Just (VString "SUMMARY: scored")
              lookup (Ident "score") fs `shouldBe` Just (VInt 7)
              lookup (Ident "rounds") fs `shouldBe` Just (VInt 2)
            other -> expectationFailure (show other)

  it "plain-text finish without submit is fatal" $
    withSystemTempDirectory "hwfl-agent-object-plain" $ \dir -> do
      writeFile (dir </> "note.txt") "x"
      let path = dir </> "agent-object.md"
      writeFile path (T.unpack agentObjectSrc)
      case loadModuleText path agentObjectSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = plainTextMock,
                  roInputs = [],
                  roRunId = Just "ao-plain",
                  roEntry = path,
                  roMode = StepRun,
                  roProjectHash = Nothing,
                    roExec = Nothing
                }
              loaded
          case outcome of
            OutcomeFailed {} -> pure ()
            other -> expectationFailure ("expected failure, got " <> show other)
