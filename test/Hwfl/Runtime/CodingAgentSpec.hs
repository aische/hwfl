module Hwfl.Runtime.CodingAgentSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Either (isRight)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Check.Project (checkProject)
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
import Hwfl.Parse.Load (loadModule)
import Hwfl.Project (ProjectConfig (..), loadProjectConfig)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    runLoadedModule,
  )
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

projectRoot :: FilePath
projectRoot = "examples/coding-agent"

modulePath :: FilePath
modulePath = projectRoot </> "workflows" </> "main.md"

-- | Scripted agent: inspect empty tree → write python + test → run → submit.
codingAgentMock :: LlmProvider
codingAgentMock = mockProviderWith reply
  where
    reply :: ChatRequest -> Either a ProviderResult
    reply req =
      let n = length (filter isToolTurn req.chatTurns)
       in Right $ case n of
            0 ->
              needTools
                [ ToolCall "c1" "fs_list" (object ["path" .= ("." :: Text)])
                ]
            1 ->
              needTools
                [ ToolCall
                    "c2"
                    "fs_write"
                    ( object
                        [ "path" .= ("add.py" :: Text),
                          "text" .= ("def add(a, b):\n    return a + b\n" :: Text)
                        ]
                    ),
                  ToolCall
                    "c3"
                    "fs_write"
                    ( object
                        [ "path" .= ("test_add.py" :: Text),
                          "text"
                            .= ( "from add import add\n\ndef test_add():\n    assert add(2, 3) == 5\n"
                                   :: Text
                               )
                        ]
                    )
                ]
            2 ->
              needTools
                [ ToolCall
                    "c4"
                    "exec_run"
                    ( object
                        [ "program" .= ("python3" :: Text),
                          "args" .= (["-c", "from add import add; assert add(2,3)==5"] :: [Text]),
                          "stdin" .= ("" :: Text)
                        ]
                    )
                ]
            _ ->
              ProviderResult
                { prContent = "done",
                  prToolCalls =
                    [ ToolCall
                        "c5"
                        "submit"
                        ( object
                            [ "summary" .= ("Created add.py and test_add.py" :: Text),
                              "ok" .= True,
                              "stack" .= ("python" :: Text),
                              "files_written" .= (["add.py", "test_add.py"] :: [Text]),
                              "verify_exit" .= (0 :: Int)
                            ]
                        )
                    ],
                  prUsage = Just (TokenUsage 1 1),
                  prFinishReason = FinishToolCalls
                }

    needTools calls =
      ProviderResult
        { prContent = "working",
          prToolCalls = calls,
          prUsage = Just (TokenUsage 1 1),
          prFinishReason = FinishToolCalls
        }

    isToolTurn = \case
      TurnTool _ -> True
      _ -> False

spec :: Spec
spec = describe "coding-agent example" $ do
  it "type-checks as a project" $ do
    result <- checkProject projectRoot
    case result of
      Left err -> expectationFailure (show err)
      Right _ -> pure ()

  it "type-checks the entry module" $ do
    loaded <- loadModule modulePath
    case loaded of
      Left diags -> expectationFailure (show diags)
      Right m -> checkLoadedModule m `shouldSatisfy` isRight

  it "builds a tiny Python project in an empty workspace (mock LLM)" $
    withSystemTempDirectory "hwfl-coding-agent" $ \tmp -> do
      cfgE <- loadProjectConfig projectRoot
      execPol <- case cfgE of
        Left err -> expectationFailure (T.unpack err) >> pure Nothing
        Right cfg -> pure cfg.pcExec
      loaded <- loadModule modulePath
      case loaded of
        Left diags -> expectationFailure (show diags)
        Right m -> do
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = tmp,
                  roProvider = codingAgentMock,
                  roInputs =
                    [ (Ident "prompt", VString "Create add(a,b) with a test"),
                      (Ident "model", VString "gpt-5")
                    ],
                  roRunId = Just "coding-agent",
                  roEntry = modulePath,
                  roMode = StepRun,
                  roProjectHash = Nothing,
                  roExec = execPol,
                    roDebug = False
                }
              m
          case outcome of
            OutcomeCompleted (VRecord fs) _store _n -> do
              lookup (Ident "ok") fs `shouldBe` Just (VBool True)
              lookup (Ident "stack") fs `shouldBe` Just (VString "python")
              lookup (Ident "verify_exit") fs `shouldBe` Just (VInt 0)
              case lookup (Ident "files_written") fs of
                Just (VList xs) -> length xs `shouldBe` 2
                other -> expectationFailure ("files_written: " <> show other)
              doesFileExist (tmp </> "add.py") `shouldReturn` True
              doesFileExist (tmp </> "test_add.py") `shouldReturn` True
              src <- TIO.readFile (tmp </> "add.py")
              src `shouldSatisfy` T.isInfixOf "return a + b"
            other -> expectationFailure ("expected completed run, got: " <> show other)
