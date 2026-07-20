module Hwfl.Runtime.AgentSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Either (isRight)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Eval.Value (HostOpId (..), ToolSpecValue (..), Value (..))
import Hwfl.Llm.Mock (mockProviderWith)
import Hwfl.Obs.Observer (noopObserver)
import Hwfl.Llm.Provider (LlmProvider (..))
import Hwfl.Llm.Types
  ( ChatRequest (..),
    FinishReason (..),
    ProviderResult (..),
    TokenUsage (..),
    ToolCall (..),
    Turn (..),
  )
import Hwfl.Obs.Show (ShowMode (..), ShowOptions (..), showRun)
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Runtime.Agent (buildToolSpec)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Machine (ChoiceRequest (..), MachineStatus (..), PauseReason (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    chooseRun,
    resumeRun,
    runLoadedModule,
    emptySkillRuntime)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

agentSrc :: Text
agentSrc =
  T.unlines
    [ "---",
      "name: workflows/e15-agent",
      "inputs: {}",
      "outputs:",
      "  text: String",
      "  rounds: Int",
      "  history: List<Turn>",
      "effects: [Read, Net]",
      "---",
      "",
      "## system",
      "",
      "You use tools when needed.",
      "",
      "## body",
      "",
      "```hwfl",
      "fun search(q: String): String =",
      "  $\"hit:{q}\"",
      "",
      "fun main(_): { text: String, rounds: Int, history: List<Turn> } =",
      "  let result = llm.agent(",
      "    system = @system,",
      "    prompt = \"find note\",",
      "    tools = [tool(fs.read), tool(search)],",
      "    model = \"gpt-5\",",
      "    max_rounds = 4",
      "  )",
      "  { text = result.text, rounds = result.rounds, history = result.history }",
      "```"
    ]

-- | Scripted mock: first round calls fs_read + search; second round finishes.
agentMock :: LlmProvider
agentMock = mockProviderWith agentMockReply

agentMockReply :: ChatRequest -> Either a ProviderResult
agentMockReply req
  | any isToolTurn req.chatTurns =
      Right
        ProviderResult
          { prContent = "done with tools",
            prToolCalls = [],
            prUsage = Just (TokenUsage 1 1),
            prFinishReason = FinishStop
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
  where
    isToolTurn = \case
      TurnTool _ -> True
      _ -> False

userTurns :: ChatRequest -> [Text]
userTurns req = [t | TurnUser t <- req.chatTurns]

isVTurn :: Value -> Bool
isVTurn VTurn {} = True
isVTurn _ = False

spec :: Spec
spec = describe "runtime agent (M7)" $ do
  it "builtin tool schemas include parameter descriptions" $ do
    buildToolSpec mempty (VHostOp HostFsRead)
      `shouldBe` Right
        ( VToolSpec
            ToolSpecValue
              { tvsName = "fs_read",
                tvsDescription = "Read a UTF-8 text file from the workspace",
                tvsParameters =
                  object
                    [ "type" .= ("object" :: Text),
                      "properties"
                        .= object
                          [ "path"
                              .= object
                                [ "type" .= ("string" :: Text),
                                  "description" .= ("Workspace-relative file path to read" :: Text)
                                ]
                          ],
                      "required" .= ["path" :: Text],
                      "additionalProperties" .= False
                    ],
                tvsCallee = VHostOp HostFsRead
              }
        )
    buildToolSpec mempty (VHostOp HostFsWrite)
      `shouldBe` Right
        ( VToolSpec
            ToolSpecValue
              { tvsName = "fs_write",
                tvsDescription = "Write a UTF-8 text file in the workspace",
                tvsParameters =
                  object
                    [ "type" .= ("object" :: Text),
                      "properties"
                        .= object
                          [ "path"
                              .= object
                                [ "type" .= ("string" :: Text),
                                  "description" .= ("Workspace-relative file path to write" :: Text)
                                ],
                            "text"
                              .= object
                                [ "type" .= ("string" :: Text),
                                  "description" .= ("UTF-8 text content to write to the file" :: Text)
                                ]
                          ],
                      "required" .= ["path" :: Text, "text" :: Text],
                      "additionalProperties" .= False
                    ],
                tvsCallee = VHostOp HostFsWrite
              }
        )

  it "E15 agent calls fs.read + user search then finishes" $
    withSystemTempDirectory "hwfl-agent" $ \dir -> do
      writeFile (dir </> "note.txt") "hello from note"
      let path = dir </> "agent.md"
      writeFile path (T.unpack agentSrc)
      case loadModuleText path agentSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRight
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = agentMock,
                  roInputs = [],
                  roRunId = Just "e15",
                  roEntry = path,
                  roMode = StepRun,
                  roProjectHash = Nothing,
                    roExec = Nothing,
                    roObserver = noopObserver,
                    roCost = False,
                    roModelCatalog = "model-catalog.json",
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime
                }
              loaded
          case outcome of
            OutcomeCompleted (VRecord fs) _store _ -> do
              lookup (Ident "text") fs `shouldBe` Just (VString "done with tools")
              lookup (Ident "rounds") fs `shouldBe` Just (VInt 2)
              shown <-
                showRun
                  ShowOptions
                    { soWorkspace = dir,
                      soRunId = "e15",
                      soMode = ShowTree,
                      soFilter = Nothing
                    }
              case shown of
                Left err -> expectationFailure (T.unpack err)
                Right tree -> do
                  tree `shouldSatisfy` T.isInfixOf "llm.agent"
                  tree `shouldSatisfy` T.isInfixOf "agent_round"
                  tree `shouldSatisfy` T.isInfixOf "tool:fs_read"
                  tree `shouldSatisfy` T.isInfixOf "tool:search"
                  tree `shouldSatisfy` T.isInfixOf "fs.read"
                  tree `shouldSatisfy` T.isInfixOf "path=note.txt"
            other -> expectationFailure (show other)

  it "E15 mid-tool step/resume continues agent loop" $
    withSystemTempDirectory "hwfl-agent-step" $ \dir -> do
      writeFile (dir </> "note.txt") "resume me"
      let path = dir </> "agent.md"
      writeFile path (T.unpack agentSrc)
      case loadModuleText path agentSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRight
          outcome0 <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = agentMock,
                  roInputs = [],
                  roRunId = Just "e15-step",
                  roEntry = path,
                  roMode = StepOnce,
                  roProjectHash = Nothing,
                    roExec = Nothing,
                    roObserver = noopObserver,
                    roCost = False,
                    roModelCatalog = "model-catalog.json",
                    roSkillCatalog = fst emptySkillRuntime,
                    roSkillModules = snd emptySkillRuntime
                }
              loaded
          case outcome0 of
            OutcomePaused (MsPaused PauseExplicit) _ _ _ -> pure ()
            other -> expectationFailure ("expected first pause, got " <> show other)
          let go n
                | n > 40 = expectationFailure "too many steps"
                | otherwise = do
                    out <- resumeRun dir "e15-step" agentMock "model-catalog.json" noopObserver
                    case out of
                      OutcomeCompleted (VRecord fs) _ _ ->
                        lookup (Ident "text") fs `shouldBe` Just (VString "done with tools")
                      OutcomePaused {} -> go (n + 1)
                      other -> expectationFailure (show other)
          go (0 :: Int)

  it "finish returns full history including tool turns" $
    withSystemTempDirectory "hwfl-agent-hist-tools" $ \dir -> do
      writeFile (dir </> "note.txt") "tool hist"
      let path = dir </> "agent.md"
      writeFile path (T.unpack agentSrc)
      case loadModuleText path agentSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRight
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = agentMock,
                  roInputs = [],
                  roRunId = Just "hist-tools",
                  roEntry = path,
                  roMode = StepRun,
                  roProjectHash = Nothing,
                  roExec = Nothing,
                  roObserver = noopObserver,
                  roCost = False,
                  roModelCatalog = "model-catalog.json",
                  roSkillCatalog = fst emptySkillRuntime,
                  roSkillModules = snd emptySkillRuntime
                }
              loaded
          case outcome of
            OutcomeCompleted (VRecord fs) _ _ -> do
              case lookup (Ident "history") fs of
                Just (VList hist) -> do
                  length hist `shouldSatisfy` (>= 4)
                  any isVTurn hist `shouldBe` True
                other -> expectationFailure ("expected history list, got " <> show other)
            other -> expectationFailure (show other)

  it "agent with prior history resumes transcript" $
    withSystemTempDirectory "hwfl-agent-hist-resume" $ \dir -> do
      writeFile (dir </> "note.txt") "resume hist"
      let path = dir </> "agent-hist.md"
          src =
            T.unlines
              [ "---",
                "name: workflows/agent-hist",
                "inputs: {}",
                "outputs:",
                "  text: String",
                "  hist_len: Int",
                "effects: [Read, Net]",
                "---",
                "",
                "## system",
                "",
                "You use tools when needed.",
                "",
                "## body",
                "",
                "```hwfl",
                "fun search(q: String): String =",
                "  $\"hit:{q}\"",
                "",
                "fun main(_): { text: String, hist_len: Int } =",
                "  let r1 = llm.agent(",
                "    system = @system,",
                "    prompt = \"first\",",
                "    tools = [tool(fs.read), tool(search)],",
                "    model = \"gpt-5\",",
                "    max_rounds = 4",
                "  )",
                "  let r2 = llm.agent(",
                "    system = @system,",
                "    prompt = \"second\",",
                "    tools = [tool(fs.read), tool(search)],",
                "    model = \"gpt-5\",",
                "    history = r1.history,",
                "    max_rounds = 4",
                "  )",
                "  { text = r2.text, hist_len = list.length(r2.history) }",
                "```"
              ]
          mock =
            mockProviderWith $ \req ->
              if length (userTurns req) >= 2
                then
                  Right
                    ProviderResult
                      { prContent = "continued",
                        prToolCalls = [],
                        prUsage = Just (TokenUsage 1 1),
                        prFinishReason = FinishStop
                      }
                else agentMockReply req
      writeFile path (T.unpack src)
      case loadModuleText path src of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRight
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = mock,
                  roInputs = [],
                  roRunId = Just "hist-resume",
                  roEntry = path,
                  roMode = StepRun,
                  roProjectHash = Nothing,
                  roExec = Nothing,
                  roObserver = noopObserver,
                  roCost = False,
                  roModelCatalog = "model-catalog.json",
                  roSkillCatalog = fst emptySkillRuntime,
                  roSkillModules = snd emptySkillRuntime
                }
              loaded
          case outcome of
            OutcomeCompleted (VRecord fs) _ _ -> do
              lookup (Ident "text") fs `shouldBe` Just (VString "continued")
              lookup (Ident "hist_len") fs `shouldSatisfy` (\case Just (VInt n) -> n > 4; _ -> False)
            other -> expectationFailure (show other)

  it "agent tool ask_user pauses for choice; choose continues" $
    withSystemTempDirectory "hwfl-agent-choice" $ \dir -> do
      let path = dir </> "agent-choice.md"
          src =
            T.unlines
              [ "---",
                "name: workflows/agent-choice",
                "inputs: {}",
                "outputs:",
                "  text: String",
                "  rounds: Int",
                "effects: [Human, Net]",
                "---",
                "",
                "## system",
                "",
                "Ask the user when needed.",
                "",
                "## body",
                "",
                "```hwfl",
                "fun ask_user(question: String, options: List<String>): String =",
                "  human.choice({",
                "    title = question,",
                "    detail = \"agent\",",
                "    options = options",
                "  })",
                "",
                "fun main(_): { text: String, rounds: Int } =",
                "  let result = llm.agent(",
                "    system = @system,",
                "    prompt = \"pick env\",",
                "    tools = [tool(ask_user)],",
                "    model = \"gpt-5\",",
                "    max_rounds = 4",
                "  )",
                "  { text = result.text, rounds = result.rounds }",
                "```"
              ]
          mock =
            mockProviderWith $ \req ->
              if any (\case TurnTool _ -> True; _ -> False) req.chatTurns
                then
                  Right
                    ProviderResult
                      { prContent = "selected via tool",
                        prToolCalls = [],
                        prUsage = Just (TokenUsage 1 1),
                        prFinishReason = FinishStop
                      }
                else
                  Right
                    ProviderResult
                      { prContent = "need human",
                        prToolCalls =
                          [ ToolCall
                              "c1"
                              "ask_user"
                              ( object
                                  [ "question" .= ("Deploy where?" :: Text),
                                    "options" .= (["staging", "prod"] :: [Text])
                                  ]
                              )
                          ],
                        prUsage = Just (TokenUsage 1 1),
                        prFinishReason = FinishToolCalls
                      }
      writeFile path (T.unpack src)
      case loadModuleText path src of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRight
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = mock,
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
                  roSkillModules = snd emptySkillRuntime
                }
              loaded
          case outcome of
            OutcomePaused (MsPaused (PauseAwaitingChoice c)) _ _ _ ->
              chOptions c `shouldBe` ["staging", "prod"]
            other -> expectationFailure ("expected awaiting choice, got " <> show other)
          chosen <- chooseRun dir "ac1" "prod" mock "model-catalog.json" noopObserver
          case chosen of
            OutcomeCompleted (VRecord fs) _ _ ->
              lookup (Ident "text") fs `shouldBe` Just (VString "selected via tool")
            other -> expectationFailure (show other)
