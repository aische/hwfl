module Pml.Runtime.AgentSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Either (isRight)
import Data.Text (Text)
import Data.Text qualified as T
import Pml.Ast.Name (Ident (..))
import Pml.Check.Module (checkLoadedModule)
import Pml.Eval.Value (HostOpId (..), ToolSpecValue (..), Value (..))
import Pml.Llm.Mock (mockProviderWith)
import Pml.Llm.Provider (LlmProvider (..))
import Pml.Llm.Types
  ( ChatRequest (..),
    FinishReason (..),
    ProviderResult (..),
    TokenUsage (..),
    ToolCall (..),
    Turn (..),
  )
import Pml.Obs.Show (ShowMode (..), ShowOptions (..), showRun)
import Pml.Parse.Load (loadModuleText)
import Pml.Runtime.Agent (buildToolSpec)
import Pml.Runtime.Eval (StepMode (..))
import Pml.Runtime.Machine (MachineStatus (..), PauseReason (..))
import Pml.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    resumeRun,
    runLoadedModule,
  )
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
      "effects: [Read, Net]",
      "---",
      "",
      "## system",
      "",
      "You use tools when needed.",
      "",
      "## body",
      "",
      "```pml",
      "fun search(q: String): String =",
      "  $\"hit:{q}\"",
      "",
      "fun main(_): { text: String, rounds: Int } =",
      "  let result = llm.agent(",
      "    system = @system,",
      "    prompt = \"find note\",",
      "    tools = [tool(fs.read), tool(search)],",
      "    model = \"gpt-5\",",
      "    max_rounds = 4",
      "  )",
      "  { text = result.text, rounds = result.rounds }",
      "```"
    ]

-- | Scripted mock: first round calls fs_read + search; second round finishes.
agentMock :: LlmProvider
agentMock = mockProviderWith reply
  where
    reply :: ChatRequest -> Either a ProviderResult
    reply req
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
    isToolTurn = \case
      TurnTool _ -> True
      _ -> False

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
    withSystemTempDirectory "pml-agent" $ \dir -> do
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
                  roProjectHash = Nothing
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
                  tree `shouldSatisfy` T.isInfixOf "fs.read"
            other -> expectationFailure (show other)

  it "E15 mid-tool step/resume continues agent loop" $
    withSystemTempDirectory "pml-agent-step" $ \dir -> do
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
                  roProjectHash = Nothing
                }
              loaded
          case outcome0 of
            OutcomePaused (MsPaused PauseExplicit) _ _ _ -> pure ()
            other -> expectationFailure ("expected first pause, got " <> show other)
          let go n
                | n > 40 = expectationFailure "too many steps"
                | otherwise = do
                    out <- resumeRun dir "e15-step" agentMock
                    case out of
                      OutcomeCompleted (VRecord fs) _ _ ->
                        lookup (Ident "text") fs `shouldBe` Just (VString "done with tools")
                      OutcomePaused {} -> go (n + 1)
                      other -> expectationFailure (show other)
          go (0 :: Int)
