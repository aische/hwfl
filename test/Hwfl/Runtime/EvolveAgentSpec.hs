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

fixedStatsPy :: Text
fixedStatsPy =
  T.unlines
    [ "def mean(nums):",
      "    \"\"\"Arithmetic mean. Empty list -> 0.0.\"\"\"",
      "    if not nums:",
      "        return 0.0",
      "    return sum(nums) / len(nums)",
      "",
      "",
      "def percentile(nums, p):",
      "    \"\"\"Nearest-rank percentile for p in [0, 100]. Empty -> 0.0.\"\"\"",
      "    if not nums:",
      "        return 0.0",
      "    s = sorted(nums)",
      "    if p <= 0:",
      "        return s[0]",
      "    if p >= 100:",
      "        return s[-1]",
      "    idx = int(round((p / 100.0) * (len(s) - 1)))",
      "    return s[idx]",
      ""
    ]

verifyArgs :: [Text]
verifyArgs =
  [ "-c",
    "from test_stats import test_mean, test_mean_empty, test_percentile; test_mean(); test_mean_empty(); test_percentile(); print('ok')"
  ]

-- | Nested coding-agent tool loop + weak mutate proposals (force fallback).
evolveMock :: LlmProvider
evolveMock = mockProviderWith reply
  where
    reply :: ChatRequest -> Either a ProviderResult
    reply req
      | not (null req.chatTools) = codingAgentReply req
      | otherwise =
          case req.chatResponseFormat of
            Just _ ->
              Right
                ProviderResult
                  { prContent =
                      "{\"operator\":\"strip_warmup\",\"rationale\":\"mock\",\"hunks\":[{\"old\":\"___no_match___\",\"new\":\"x\"}]}",
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
                [ ToolCall "c3" "fs_read" (object ["path" .= ("stats.py" :: Text)])
                ]
            3 ->
              needTools
                [ ToolCall
                    "c4"
                    "fs_write"
                    ( object
                        [ "path" .= ("stats.py" :: Text),
                          "text" .= fixedStatsPy
                        ]
                    )
                ]
            4 ->
              needTools
                [ ToolCall
                    "c5"
                    "exec_run"
                    ( object
                        [ "program" .= ("python3" :: Text),
                          "args" .= verifyArgs,
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
                            [ "summary" .= ("Fixed mean and percentile in stats.py" :: Text),
                              "ok" .= True,
                              "stack" .= ("python" :: Text),
                              "files_written" .= (["stats.py"] :: [Text]),
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

  it "evolves 3 gens; distinct fallback operators; tight wins under mock" $
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
              doesFileExist (tmp </> "trials" </> "g0" </> "tight" </> "stats.py")
                `shouldReturn` True
              doesFileExist (tmp </> "trials" </> "g0" </> "tight" </> "test_stats.py")
                `shouldReturn` True
              doesFileExist
                (tmp </> "genomes" </> "mut-g0" </> "workflows" </> "main.md")
                `shouldReturn` True
              doesFileExist
                (tmp </> "genomes" </> "mut-g1" </> "workflows" </> "main.md")
                `shouldReturn` True
              mut0 <-
                TIO.readFile
                  (tmp </> "genomes" </> "mut-g0" </> "workflows" </> "main.md")
              mut1 <-
                TIO.readFile
                  (tmp </> "genomes" </> "mut-g1" </> "workflows" </> "main.md")
              T.isInfixOf "llm.chat" mut0 `shouldBe` False
              T.isInfixOf "llm.agent_object" mut0 `shouldBe` True
              mut0 `shouldNotBe` mut1
              -- gen0 fallback strip_warmup; gen1 starts at shrink_rounds
              T.isInfixOf "max_rounds = 8" mut1
                || T.isInfixOf "max_rounds = 4" mut1
                || not (T.isInfixOf "tool(fs.list)" mut1)
                `shouldBe` True
            other -> expectationFailure ("expected completed run, got: " <> show other)

qname :: Text -> QName
qname = QName . map Ident . T.splitOn "/"

seedWorkspace :: FilePath -> IO ()
seedWorkspace ws = do
  copyFileRel
    (projectRoot </> "fixture" </> "prompt.txt")
    (ws </> "fixture" </> "prompt.txt")
  copyFileRel
    (projectRoot </> "fixture" </> "project" </> "stats.py")
    (ws </> "fixture" </> "project" </> "stats.py")
  copyFileRel
    (projectRoot </> "fixture" </> "project" </> "test_stats.py")
    (ws </> "fixture" </> "project" </> "test_stats.py")
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
