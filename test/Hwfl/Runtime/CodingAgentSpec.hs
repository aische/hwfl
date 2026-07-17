module Hwfl.Runtime.CodingAgentSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Either (isRight)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfl.Ast.Module (LoadedModule)
import Hwfl.Ast.Name (Ident (..), QName (..))
import Hwfl.Ast.Skill (SkillKind (..), SkillMeta (..))
import Hwfl.Check.Project (CheckProjectResult (..), checkProject)
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Eval.Value (Value (..))
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
import Hwfl.Parse.Load (loadModule)
import Hwfl.Project (LoadedProject (..), ProjectConfig (..), loadProject)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    runLoadedModule,
  )
import Hwfl.SkillCatalog (SkillCatalog (..), isSkillQName, skillMetaForModule)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

projectRoot :: FilePath
projectRoot = "examples/coding-agent"

modulePath :: FilePath
modulePath = projectRoot </> "workflows" </> "main.md"

-- | Scripted agent: discover+load python skill → list → write → exec → submit.
codingAgentMock :: LlmProvider
codingAgentMock = mockProviderWith reply
  where
    reply :: ChatRequest -> Either a ProviderResult
    reply req =
      let n = length (filter isToolTurn req.chatTurns)
          hasPythonSkill =
            maybe False (T.isInfixOf "Loaded skill: skills/python-pytest") req.chatSystem
       in Right $ case n of
            0 ->
              needTools
                [ ToolCall
                    "c0"
                    "skill_discover"
                    ( object
                        [ "query" .= ("python" :: Text),
                          "kinds" .= (["instruction"] :: [Text]),
                          "limit" .= (5 :: Int)
                        ]
                    ),
                  ToolCall
                    "c1"
                    "skill_load"
                    (object ["id" .= ("skills/python-pytest" :: Text)])
                ]
            1
              | hasPythonSkill ->
                  needTools
                    [ ToolCall "c2" "fs_list" (object ["path" .= ("." :: Text)])
                    ]
              | otherwise ->
                  needTools
                    [ ToolCall "c2" "fs_list" (object ["path" .= ("." :: Text)])
                    ]
            2 ->
              needTools
                [ ToolCall
                    "c3"
                    "fs_write"
                    ( object
                        [ "path" .= ("add.py" :: Text),
                          "text" .= ("def add(a, b):\n    return a + b\n" :: Text)
                        ]
                    ),
                  ToolCall
                    "c4"
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
            3 ->
              needTools
                [ ToolCall
                    "c5"
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
                        "c6"
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
  it "type-checks as a project (including skills catalog)" $ do
    result <- checkProject projectRoot
    case result of
      Left err -> expectationFailure (show err)
      Right cpr -> do
        Map.size cpr.cprSkillCatalog.scEntries `shouldBe` 4
        Map.member (qname "skills/python-pytest") cpr.cprSkillCatalog.scEntries
          `shouldBe` True

  it "type-checks the entry module" $ do
    loaded <- loadModule modulePath
    case loaded of
      Left diags -> expectationFailure (show diags)
      Right m -> checkLoadedModule m `shouldSatisfy` isRight

  it "builds a tiny Python project after loading the python skill (mock LLM)" $
    withSystemTempDirectory "hwfl-coding-agent" $ \tmp -> do
      result <- checkProject projectRoot
      case result of
        Left err -> expectationFailure (show err)
        Right cpr -> do
          lp <- loadProjectOrFail projectRoot
          case Map.lookup (qname "workflows/main") lp.lpModules of
            Nothing -> expectationFailure "missing entry module"
            Just m -> do
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
                      roExec = lp.lpConfig.pcExec,
                      roObserver = noopObserver,
                      roCost = False,
                    roModelCatalog = "model-catalog.json",
                      roSkillCatalog = cpr.cprSkillCatalog,
                      roSkillModules = callableSkills lp
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

qname :: Text -> QName
qname = QName . map Ident . T.splitOn "/"

callableSkills :: LoadedProject -> Map.Map QName LoadedModule
callableSkills lp =
  Map.filterWithKey
    ( \q m ->
        isSkillQName q && smKind (skillMetaForModule m) == SkillCallable
    )
    lp.lpModules

loadProjectOrFail :: FilePath -> IO LoadedProject
loadProjectOrFail path = do
  result <- loadProject path
  case result of
    Left err -> fail (T.unpack err)
    Right lp -> pure lp
