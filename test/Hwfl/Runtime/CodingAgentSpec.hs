module Hwfl.Runtime.CodingAgentSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfl.Ast.Module (LoadedModule)
import Hwfl.Ast.Name (Ident (..), QName (..))
import Hwfl.Ast.Skill (SkillKind (..), SkillMeta (..))
import Hwfl.Check.Project (CheckProjectResult (..), checkProject)
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
import Hwfl.Obs.Observer (noopObserver)
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

codingPath :: FilePath
codingPath = projectRoot </> "workflows" </> "coding.md"

-- | Distinguishes planner vs coder by system prompt; scripts both to submit.
codingSessionMock :: LlmProvider
codingSessionMock = mockProviderWith reply
  where
    reply :: ChatRequest -> Either a ProviderResult
    reply req =
      let sys = fromMaybe "" req.chatSystem
          n = length (filter isToolTurn req.chatTurns)
          planning = T.isInfixOf "planner for a coding session" sys
       in Right $
            if planning
              then planReply n
              else doReply n sys

    planReply n = case n of
      0 ->
        needTools
          [ ToolCall
              "p0"
              "skill_discover"
              ( object
                  [ "query" .= ("python" :: Text),
                    "kinds" .= (["instruction"] :: [Text]),
                    "limit" .= (5 :: Int)
                  ]
              ),
            ToolCall
              "p1"
              "skill_load"
              (object ["id" .= ("skills/python-pytest" :: Text)])
          ]
      _ ->
        submit
          [ ToolCall
              "p2"
              "submit"
              ( object
                  [ "stack" .= ("python" :: Text),
                    "summary" .= ("One-task python add helper" :: Text),
                    "tasks"
                      .= [ object
                             [ "id" .= ("t1" :: Text),
                               "title" .= ("add helper" :: Text),
                               "detail" .= ("Write add.py and a tiny check" :: Text),
                               "verify_program" .= ("python3" :: Text),
                               "verify_args"
                                 .= (["-c", "from add import add; assert add(2,3)==5"] :: [Text])
                             ]
                         ]
                  ]
              )
          ]

    doReply n sys = case n of
      0 ->
        needTools
          [ ToolCall
              "d0"
              "skill_discover"
              ( object
                  [ "query" .= ("python" :: Text),
                    "kinds" .= (["instruction"] :: [Text]),
                    "limit" .= (3 :: Int)
                  ]
              ),
            ToolCall
              "d1"
              "skill_load"
              (object ["id" .= ("skills/python-pytest" :: Text)])
          ]
      1
        | T.isInfixOf "Loaded skill: skills/python-pytest" sys ->
            needTools
              [ ToolCall
                  "d2"
                  "fs_write"
                  ( object
                      [ "path" .= ("add.py" :: Text),
                        "text" .= ("def add(a, b):\n    return a + b\n" :: Text)
                      ]
                  )
              ]
        | otherwise ->
            needTools
              [ ToolCall
                  "d2"
                  "fs_write"
                  ( object
                      [ "path" .= ("add.py" :: Text),
                        "text" .= ("def add(a, b):\n    return a + b\n" :: Text)
                      ]
                  )
              ]
      _ ->
        submit
          [ ToolCall
              "d3"
              "submit"
              ( object
                  [ "summary" .= ("Wrote add.py" :: Text),
                    "files_written" .= (["add.py"] :: [Text])
                  ]
              )
          ]

    needTools calls =
      ProviderResult
        { prContent = "working",
          prToolCalls = calls,
          prUsage = Just (TokenUsage 1 1),
          prFinishReason = FinishToolCalls
        }

    submit calls =
      ProviderResult
        { prContent = "done",
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

  it "type-checks chat and coding entry modules via project check" $ do
    result <- checkProject projectRoot
    case result of
      Left err -> expectationFailure (show err)
      Right cpr -> do
        Set.member (qname "workflows/main") cpr.cprChecked `shouldBe` True
        Set.member (qname "workflows/coding") cpr.cprChecked `shouldBe` True
        Set.member (qname "workflows/gather_context") cpr.cprChecked `shouldBe` True
        Set.member (qname "workflows/verify") cpr.cprChecked `shouldBe` True

  it "runs workflows/coding: plan → do_task → verify (mock LLM)" $
    withSystemTempDirectory "hwfl-coding-agent" $ \tmp -> do
      result <- checkProject projectRoot
      case result of
        Left err -> expectationFailure (show err)
        Right cpr -> do
          lp <- loadProjectOrFail projectRoot
          case Map.lookup (qname "workflows/coding") lp.lpModules of
            Nothing -> expectationFailure "missing workflows/coding"
            Just m -> do
              outcome <-
                runLoadedModule
                  RunOptions
                    { roWorkspace = tmp,
                      roProvider = codingSessionMock,
                      roInputs =
                        [ (Ident "prompt", VString "Create add(a,b) with a test"),
                          (Ident "model", VString "gpt-5")
                        ],
                      roRunId = Just "coding-session",
                      roEntry = codingPath,
                      roMode = StepRun,
                      roProjectHash = Nothing,
                      roExec = lp.lpConfig.pcExec,
                      roObserver = noopObserver,
                      roCost = False,
                      roModelCatalog = "model-catalog.json",
                      roSkillCatalog = cpr.cprSkillCatalog,
                      roSkillModules = callableSkills lp,
                      roEntryModules = lp.lpModules
                    }
                  m
              case outcome of
                OutcomeCompleted (VRecord fs) _store _n -> do
                  lookup (Ident "ok") fs `shouldBe` Just (VBool True)
                  lookup (Ident "stack") fs `shouldBe` Just (VString "python")
                  lookup (Ident "verify_exit") fs `shouldBe` Just (VInt 0)
                  lookup (Ident "tasks_done") fs `shouldBe` Just (VInt 1)
                  lookup (Ident "tasks_total") fs `shouldBe` Just (VInt 1)
                  doesFileExist (tmp </> "add.py") `shouldReturn` True
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
