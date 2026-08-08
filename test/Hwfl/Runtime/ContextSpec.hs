module Hwfl.Runtime.ContextSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Either (isRight)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Provider (LlmProvider (..))
import Hwfl.Llm.Types
  ( ChatRequest (..),
    FinishReason (..),
    ProviderResult (..),
    TokenUsage (..),
    ToolCall (..),
    ToolResult (..),
    ToolSpec (..),
    Turn (..),
  )
import Hwfl.Obs.Observer (noopObserver)
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Runtime.Agent (initAgentState, parseAgentArgs)
import Hwfl.Runtime.Context
  ( capToolResult,
    defaultMaxToolResultChars,
    getHistoryChunk,
    historyToolName,
    windowOffset,
    wireTurns,
  )
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Machine (AgentState (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    emptySkillRuntime,
    runLoadedModule,
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "Context L1" $ do
  describe "windowOffset" $ do
    it "returns 0 when no context window is configured" $
      windowOffset Nothing sampleConversation `shouldBe` 0

    it "hides all but the last N user messages" $
      windowOffset (Just 1) sampleConversation `shouldBe` 4

    it "returns 0 when the conversation has fewer user messages than N" $
      windowOffset (Just 5) [TurnUser "only"] `shouldBe` 0

  describe "getHistoryChunk" $ do
    it "reports no earlier history when nothing is hidden" $
      getHistoryChunk Nothing sampleConversation 0 `shouldBe` "(no earlier history)"

    it "returns the most recent hidden chunk at chunk 0" $ do
      let result = getHistoryChunk (Just 1) sampleConversation 0
      T.unpack result `shouldContain` "[User] second question"
      T.unpack result `shouldNotContain` "first question"

    it "returns older hidden chunks at higher indices" $ do
      let result = getHistoryChunk (Just 1) sampleConversation 1
      T.unpack result `shouldContain` "[User] first question"
      T.unpack result `shouldNotContain` "second question"

    it "reports no more history for out-of-range chunk indices" $
      getHistoryChunk (Just 1) sampleConversation 9 `shouldBe` "(no more history)"

  describe "wireTurns / tool result cap" $ do
    it "caps tool results on the wire view" $ do
      let big = T.replicate 100 "x"
          hist =
            [ TurnUser "q",
              TurnAssistant "a" [],
              TurnTool [ToolResult "c1" "fs_read" big]
            ]
          wired = wireTurns Nothing (Just 10) hist
      case wired of
        [TurnUser "q", TurnAssistant "a" [], TurnTool [r]] -> do
          T.length r.trContent `shouldSatisfy` (< T.length big)
          T.unpack r.trContent `shouldContain` "truncated"
        other -> expectationFailure ("unexpected wire turns: " <> show other)

    it "capToolResult leaves short text alone" $
      capToolResult 100 "hello" `shouldBe` "hello"

  describe "parseAgentArgs context knobs" $ do
    it "defaults max_tool_result_chars when context_window is set" $ do
      let args =
            [ (Just (Ident "system"), VString "s"),
              (Just (Ident "prompt"), VString "p"),
              (Just (Ident "tools"), VList []),
              (Just (Ident "model"), VString "m"),
              (Just (Ident "context_window"), VInt 2)
            ]
      case parseAgentArgs args of
        Right (_, _, _, _, _, _, Just 2, Nothing) -> do
          let ag = initAgentState "s" "p" [] "m" 4 "span" Nothing [] (Just 2) Nothing
          ag.agMaxToolResultChars `shouldBe` Just defaultMaxToolResultChars
        other -> expectationFailure ("unexpected parse: " <> show other)

  describe "llm.agent context_window integration" $ do
    it "sends only the windowed suffix and injects get_history" $
      withSystemTempDirectory "hwfl-context-window" $ \dir -> do
        let path = dir </> "agent.md"
            src = chainedAgentSrc False
        ref <- newIORef ([] :: [ChatRequest])
        writeFile path (T.unpack src)
        case loadModuleText path src of
          Left diags -> expectationFailure (show diags)
          Right loaded -> do
            checkLoadedModule loaded `shouldSatisfy` isRight
            outcome <-
              runLoadedModule
                (baseOpts dir path (recordingMock ref) "ctx-win")
                loaded
            case outcome of
              OutcomeCompleted {} -> do
                reqs <- reverse <$> readIORef ref
                -- Third agent call is the windowed one (first request of that call).
                case drop 2 reqs of
                  req : _ -> do
                    let users = [t | TurnUser t <- req.chatTurns]
                    users `shouldBe` ["third question"]
                    map (.tsName) req.chatTools `shouldContain` [historyToolName]
                    concatMap userText req.chatTurns `shouldNotContain` "first question"
                  [] -> expectationFailure "expected a third provider request"
              other -> expectationFailure (show other)

    it "serves get_history for hidden chunks" $
      withSystemTempDirectory "hwfl-get-history" $ \dir -> do
        let path = dir </> "agent.md"
            src = chainedAgentSrc True
        writeFile path (T.unpack src)
        case loadModuleText path src of
          Left diags -> expectationFailure (show diags)
          Right loaded -> do
            checkLoadedModule loaded `shouldSatisfy` isRight
            outcome <-
              runLoadedModule
                (baseOpts dir path getHistoryMock "get-hist")
                loaded
            case outcome of
              OutcomeCompleted v _ _ ->
                case v of
                  VRecord fs ->
                    case lookup (Ident "text") fs of
                      Just (VString t) ->
                        T.unpack t `shouldContain` "first question"
                      _ -> expectationFailure "expected text field"
                  _ -> expectationFailure ("expected record, got " <> show v)
              other -> expectationFailure (show other)

-------------------------------------------------------------------------------
-- Fixtures

sampleConversation :: [Turn]
sampleConversation =
  [ TurnUser "first question",
    TurnAssistant "first answer" [],
    TurnUser "second question",
    TurnAssistant "second answer" [],
    TurnUser "third question",
    TurnAssistant "third answer" []
  ]

userText :: Turn -> String
userText = \case
  TurnUser t -> T.unpack t
  _ -> ""

-- | Three chained agent calls; the last uses @context_window = 1@.
-- When @callHistory@ is True, the last call's mock will invoke get_history
-- (configured via provider, not the source).
chainedAgentSrc :: Bool -> Text
chainedAgentSrc _callHistory =
  T.unlines
    [ "---",
      "name: workflows/ctx-window",
      "inputs: {}",
      "outputs:",
      "  text: String",
      "  rounds: Int",
      "  history: List<Turn>",
      "effects: [Net]",
      "---",
      "",
      "## system",
      "",
      "You are helpful.",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { text: String, rounds: Int, history: List<Turn> } =",
      "  let r1 = llm.agent(",
      "    system = @system,",
      "    prompt = \"first question\",",
      "    tools = [],",
      "    model = \"gpt-5\",",
      "    max_rounds = 2",
      "  )",
      "  let r2 = llm.agent(",
      "    system = @system,",
      "    prompt = \"second question\",",
      "    tools = [],",
      "    model = \"gpt-5\",",
      "    max_rounds = 2,",
      "    history = r1.history",
      "  )",
      "  let r3 = llm.agent(",
      "    system = @system,",
      "    prompt = \"third question\",",
      "    tools = [],",
      "    model = \"gpt-5\",",
      "    max_rounds = 4,",
      "    history = r2.history,",
      "    context_window = 1",
      "  )",
      "  { text = r3.text, rounds = r3.rounds, history = r3.history }",
      "```"
    ]

baseOpts :: FilePath -> FilePath -> LlmProvider -> Text -> RunOptions
baseOpts dir path provider runId =
  RunOptions
    { roWorkspace = dir,
      roProvider = provider,
      roInputs = [],
      roRunId = Just runId,
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

recordingMock :: IORef [ChatRequest] -> LlmProvider
recordingMock ref =
  LlmProvider
    { llmChat = \req -> do
        modifyIORef' ref (req :)
        pure $
          Right
            ProviderResult
              { prContent = "ok",
                prToolCalls = [],
                prUsage = Just (TokenUsage 1 1),
                prFinishReason = FinishStop
              },
      llmProviderName = "mock-record"
    }

-- | First two agent calls finish immediately. On the windowed third call,
-- request @get_history@ once, then echo its result as the final text.
getHistoryMock :: LlmProvider
getHistoryMock =
  LlmProvider
    { llmChat = \req ->
        pure $
          if any isToolTurn req.chatTurns
            then
              let hidden =
                    case [ r.trContent
                           | TurnTool rs <- req.chatTurns,
                             r <- rs,
                             r.trName == historyToolName
                         ] of
                      (c : _) -> c
                      [] -> "missing"
               in Right
                    ProviderResult
                      { prContent = hidden,
                        prToolCalls = [],
                        prUsage = Just (TokenUsage 1 1),
                        prFinishReason = FinishStop
                      }
            else
              if historyToolName `elem` map (.tsName) req.chatTools
                then
                  Right
                    ProviderResult
                      { prContent = "need history",
                        prToolCalls =
                          [ ToolCall
                              "h1"
                              historyToolName
                              (object ["chunk" .= (1 :: Int)])
                          ],
                        prUsage = Just (TokenUsage 1 1),
                        prFinishReason = FinishToolCalls
                      }
                else
                  Right
                    ProviderResult
                      { prContent = "ok",
                        prToolCalls = [],
                        prUsage = Just (TokenUsage 1 1),
                        prFinishReason = FinishStop
                      },
      llmProviderName = "mock-get-history"
    }

isToolTurn :: Turn -> Bool
isToolTurn = \case
  TurnTool _ -> True
  _ -> False
