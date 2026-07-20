module Hwfl.Runtime.EvolveAgentSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Either (isRight)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfl.Ast.Name (Ident (..), QName (..))
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
import Hwfl.Obs.Observer (noopObserver)
import Hwfl.Project (LoadedProject (..), loadProject)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    emptySkillRuntime,
    runLoadedModule,
  )
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

projectRoot :: FilePath
projectRoot = "examples/evolve-agent"

modulePath :: FilePath
modulePath = projectRoot </> "workflows" </> "main.md"

-- | Nested coding-agent tool loop + default structured replies for mutate.
evolveMock :: LlmProvider
evolveMock = mockProviderWith reply
  where
    reply :: ChatRequest -> Either a ProviderResult
    reply req
      | not (null req.chatTools) = codingAgentReply req
      | otherwise =
          -- llm.object / llm.chat: fillSchema path via a tiny local echo.
          -- Deliberately weak patch proposals so structural fallback runs.
          case req.chatResponseFormat of
            Just _ ->
              Right
                ProviderResult
                  { prContent =
                      "{\"rationale\":\"mock\",\"hunks\":[{\"old\":\"___no_match___\",\"new\":\"x\"}]}",
                    prToolCalls = [],
                    prUsage = Just (TokenUsage 1 1),
                    prFinishReason = FinishStop
                  }
            Nothing ->
              Right
                ProviderResult
                  { prContent = "SUMMARY: ack",
                    prToolCalls = [],
                    prUsage = Just (TokenUsage 1 1),
                    prFinishReason = FinishStop
                  }

    codingAgentReply req =
      let n = length (filter isToolTurn req.chatTurns)
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
            1 ->
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
spec = describe "evolve-agent lab" $ do
  it "checks the parent project" $ do
    result <- checkProject projectRoot
    result `shouldSatisfy` isRight

  it "checks the tight and wasteful genomes" $ do
    tight <- checkProject (projectRoot </> "genomes" </> "tight")
    wasteful <- checkProject (projectRoot </> "genomes" </> "wasteful")
    tight `shouldSatisfy` isRight
    wasteful `shouldSatisfy` isRight

  it "evolves 3 gens under mock; tight wins; fallback mutates wasteful" $
    withSystemTempDirectory "hwfl-evolve-agent" $ \tmp -> do
      seedWorkspace tmp
      lp <- loadProjectOrFail projectRoot
      case Map.lookup (qname "workflows/main") lp.lpModules of
        Nothing -> expectationFailure "missing entry module"
        Just m -> do
          checkLoadedModule m `shouldSatisfy` isRight
          let (catalog, skillMods) = emptySkillRuntime
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = tmp,
                  roProvider = evolveMock,
                  roInputs =
                    [ (Ident "generations", VInt 3),
                      (Ident "model", VString "mock")
                    ],
                  roRunId = Just "evolve-parent",
                  roEntry = modulePath,
                  roMode = StepRun,
                  roProjectHash = Nothing,
                  roExec = Nothing,
                  roObserver = noopObserver,
                  roCost = False,
                  roModelCatalog = "model-catalog.json",
                  roSkillCatalog = catalog,
                  roSkillModules = skillMods,
                  roEntryModules = mempty
                }
              m
          case outcome of
            OutcomeCompleted (VRecord fs) _store _n -> do
              lookup (Ident "winner") fs `shouldBe` Just (VString "tight")
              lookup (Ident "trial_count") fs `shouldBe` Just (VInt 6)
              lookup (Ident "generations") fs `shouldBe` Just (VInt 3)
              doesFileExist (tmp </> "results.json") `shouldReturn` True
              doesFileExist
                (tmp </> "genomes" </> "mut-g0" </> "workflows" </> "main.md")
                `shouldReturn` True
              doesFileExist
                (tmp </> "trials" </> "g0" </> "tight" </> "add.py")
                `shouldReturn` True
              mut0 <-
                TIO.readFile
                  (tmp </> "genomes" </> "mut-g0" </> "workflows" </> "main.md")
              T.isInfixOf "llm.chat" mut0 `shouldBe` False
              T.isInfixOf "llm.agent_object" mut0 `shouldBe` True
            other -> expectationFailure ("expected completed run, got: " <> show other)

qname :: Text -> QName
qname = QName . map Ident . T.splitOn "/"

seedWorkspace :: FilePath -> IO ()
seedWorkspace ws = do
  copyFileRel
    (projectRoot </> "fixture" </> "prompt.txt")
    (ws </> "fixture" </> "prompt.txt")
  mapM_ (copyGenome ws) ["tight", "wasteful"]

copyGenome :: FilePath -> FilePath -> IO ()
copyGenome ws name = do
  copyFileRel
    (projectRoot </> "genomes" </> name </> "project.json")
    (ws </> "genomes" </> name </> "project.json")
  copyFileRel
    (projectRoot </> "genomes" </> name </> "workflows" </> "main.md")
    (ws </> "genomes" </> name </> "workflows" </> "main.md")
  copyFileRel
    (projectRoot </> "genomes" </> name </> "skills" </> "python-pytest.md")
    (ws </> "genomes" </> name </> "skills" </> "python-pytest.md")

copyFileRel :: FilePath -> FilePath -> IO ()
copyFileRel src dst = do
  createDirectoryIfMissing True (takeDirectory dst)
  TIO.writeFile dst =<< TIO.readFile src

loadProjectOrFail :: FilePath -> IO LoadedProject
loadProjectOrFail path = do
  result <- loadProject path
  case result of
    Left err -> fail (T.unpack err)
    Right lp -> pure lp
