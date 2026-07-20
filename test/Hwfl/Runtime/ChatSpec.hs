module Hwfl.Runtime.ChatSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider, mockProviderWith)
import Hwfl.Llm.Types (ChatRequest (..), FinishReason (..), ProviderResult (..), TokenUsage (..), Turn (..))
import Hwfl.Llm.Provider (LlmProvider (..))
import Hwfl.Obs.Observer (noopObserver)
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Machine (AskRequest (..), MachineStatus (..), PauseReason (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    emptySkillRuntime,
    replyRun,
    runLoadedModule,
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

isRight :: Either a b -> Bool
isRight = \case
  Right _ -> True
  Left _ -> False

chatMessagesSrc :: Text
chatMessagesSrc =
  T.unlines
    [ "---",
      "name: workflows/chat-messages",
      "inputs: {}",
      "outputs:",
      "  reply: String",
      "effects: [Net]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { reply: String } =",
      "  let reply = llm.chat_messages(",
      "    system = \"Be brief.\",",
      "    messages = [",
      "      { role = \"user\", content = \"Say hi\" }",
      "    ],",
      "    model = \"gpt-5\"",
      "  )",
      "  { reply }",
      "```"
    ]

chatLoopSrc :: Text
chatLoopSrc =
  T.unlines
    [ "---",
      "name: workflows/chat",
      "inputs: {}",
      "outputs:",
      "  done: Bool",
      "  turns: Int",
      "  last: String",
      "effects: [Human, Net]",
      "---",
      "",
      "## system",
      "",
      "Be brief.",
      "",
      "## body",
      "",
      "```hwfl",
      "type Msg = { role: String, content: String }",
      "",
      "fun turn(",
      "  history: List<Msg>,",
      "  last: String",
      "): { done: Bool, history: List<Msg>, last: String } =",
      "  let detail =",
      "    if last == \"\" then",
      "      \"Type a message, or /quit to end.\"",
      "    else",
      "      $\"Assistant: {last}\\n\\nType a message, or /quit to end.\"",
      "  let user = human.ask({",
      "    prompt = \"You>\",",
      "    detail = detail",
      "  })",
      "  if user == \"/quit\" then",
      "    { done = true, history = history, last = last }",
      "  else",
      "    let history_u = list.concat(history, [{ role = \"user\", content = user }])",
      "    let reply = llm.chat_messages(",
      "      system = @system,",
      "      messages = history_u,",
      "      model = \"gpt-5\"",
      "    )",
      "    let history_a = list.concat(history_u, [{ role = \"assistant\", content = reply }])",
      "    turn(history_a, reply)",
      "",
      "fun main(_): { done: Bool, turns: Int, last: String } =",
      "  let r = turn([], \"\")",
      "  { done = r.done, turns = list.length(r.history), last = r.last }",
      "```"
    ]

spec :: Spec
spec =
  sequence_
    [ describe "workflow chat (ask + chat_messages)" $ do
        it "llm.chat_messages returns assistant text" $
          withSystemTempDirectory "hwfl-chat-messages" $ \dir -> do
            let path = dir </> "cm.md"
            writeFile path (T.unpack chatMessagesSrc)
            case loadModuleText path chatMessagesSrc of
              Left diags -> expectationFailure (show diags)
              Right loaded -> do
                checkLoadedModule loaded `shouldSatisfy` isRight
                outcome <-
                  runLoadedModule
                    RunOptions
                      { roWorkspace = dir,
                        roProvider = mockProvider,
                        roInputs = [],
                        roRunId = Just "cm1",
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
                  OutcomeCompleted (VRecord fs) _ _ ->
                    case lookup (Ident "reply") fs of
                      Just (VString t) -> t `shouldSatisfy` T.isInfixOf "SUMMARY:"
                      other -> expectationFailure (show other)
                  other -> expectationFailure (show other)
        it "chat loop: reply then /quit" $
          withSystemTempDirectory "hwfl-chat-loop" $ \dir -> do
            let path = dir </> "chat.md"
            writeFile path (T.unpack chatLoopSrc)
            case loadModuleText path chatLoopSrc of
              Left diags -> expectationFailure (show diags)
              Right loaded -> do
                checkLoadedModule loaded `shouldSatisfy` isRight
                o0 <-
                  runLoadedModule
                    RunOptions
                      { roWorkspace = dir,
                        roProvider = mockProvider,
                        roInputs = [],
                        roRunId = Just "chat1",
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
                case o0 of
                  OutcomePaused (MsPaused (PauseAwaitingAsk a)) _ _ _ -> do
                    askPrompt a `shouldBe` "You>"
                    askDetail a `shouldBe` "Type a message, or /quit to end."
                  other -> expectationFailure ("expected ask, got " <> show other)
                o1 <- replyRun dir "chat1" "hello" mockProvider "model-catalog.json" noopObserver
                case o1 of
                  OutcomePaused (MsPaused (PauseAwaitingAsk a)) _ _ _ -> do
                    askDetail a `shouldSatisfy` T.isPrefixOf "Assistant: "
                    askDetail a `shouldSatisfy` T.isInfixOf "SUMMARY:"
                    askDetail a `shouldSatisfy` T.isInfixOf "Type a message"
                  other -> expectationFailure ("expected second ask, got " <> show other)
                o2 <- replyRun dir "chat1" "/quit" mockProvider "model-catalog.json" noopObserver
                case o2 of
                  OutcomeCompleted (VRecord fs) _ _ -> do
                    lookup (Ident "done") fs `shouldBe` Just (VBool True)
                    lookup (Ident "turns") fs `shouldBe` Just (VInt 2)
                    case lookup (Ident "last") fs of
                      Just (VString t) -> t `shouldSatisfy` T.isInfixOf "SUMMARY:"
                      other -> expectationFailure (show other)
                  other -> expectationFailure (show other)
    , describe "coding-agent chat (ask + agent history)" $ do
        it "agent ask loop threads history then /quit" $
          withSystemTempDirectory "hwfl-agent-chat" $ \dir -> do
            writeFile (dir </> "note.txt") "hello note"
            let path = dir </> "agent-chat.md"
                src =
                  T.unlines
                    [ "---",
                      "name: workflows/agent-chat",
                      "inputs: {}",
                      "outputs:",
                      "  done: Bool",
                      "  turns: Int",
                      "  last: String",
                      "effects: [Human, Net, Read]",
                      "---",
                      "",
                      "## system",
                      "",
                      "Be brief.",
                      "",
                      "## body",
                      "",
                      "```hwfl",
                      "fun turn(",
                      "  history: List<Turn>,",
                      "  last: String",
                      "): { done: Bool, history: List<Turn>, last: String } =",
                      "  let detail =",
                      "    if last == \"\" then",
                      "      \"Type a message, or /quit to end.\"",
                      "    else",
                      "      $\"Assistant: {last}\\n\\nType a message, or /quit to end.\"",
                      "  let user = human.ask({ prompt = \"You>\", detail = detail })",
                      "  if user == \"/quit\" then",
                      "    { done = true, history = history, last = last }",
                      "  else",
                      "    let result = llm.agent(",
                      "      system = @system,",
                      "      prompt = user,",
                      "      tools = [tool(fs.read)],",
                      "      model = \"gpt-5\",",
                      "      history = history,",
                      "      max_rounds = 2",
                      "    )",
                      "    turn(result.history, result.text)",
                      "",
                      "fun main(_): { done: Bool, turns: Int, last: String } =",
                      "  let r = turn([], \"\")",
                      "  { done = r.done, turns = list.length(r.history), last = r.last }",
                      "```"
                    ]
                agentChatMock :: LlmProvider
                agentChatMock =
                  mockProviderWith $ \req ->
                    Right
                      ProviderResult
                        { prContent = "SUMMARY: ok " <> T.pack (show (length req.chatTurns)),
                          prToolCalls = [],
                          prUsage = Just (TokenUsage 1 1),
                          prFinishReason = FinishStop
                        }
            writeFile path (T.unpack src)
            case loadModuleText path src of
              Left diags -> expectationFailure (show diags)
              Right loaded -> do
                checkLoadedModule loaded `shouldSatisfy` isRight
                o0 <-
                  runLoadedModule
                    RunOptions
                      { roWorkspace = dir,
                        roProvider = agentChatMock,
                        roInputs = [],
                        roRunId = Just "ac1",
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
                case o0 of
                  OutcomePaused (MsPaused (PauseAwaitingAsk _)) _ _ _ -> pure ()
                  other -> expectationFailure ("expected ask, got " <> show other)
                o1 <- replyRun dir "ac1" "hi" agentChatMock "model-catalog.json" noopObserver
                case o1 of
                  OutcomePaused (MsPaused (PauseAwaitingAsk a)) _ _ _ ->
                    askDetail a `shouldSatisfy` T.isInfixOf "SUMMARY:"
                  other -> expectationFailure ("expected second ask, got " <> show other)
                o2 <- replyRun dir "ac1" "/quit" agentChatMock "model-catalog.json" noopObserver
                case o2 of
                  OutcomeCompleted (VRecord fs) _ _ -> do
                    lookup (Ident "done") fs `shouldBe` Just (VBool True)
                    lookup (Ident "turns") fs `shouldSatisfy` (\case Just (VInt n) -> n >= 2; _ -> False)
                  other -> expectationFailure (show other)
    ]
