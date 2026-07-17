module Hwfl.Runtime.SkillSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Module (LoadedModule)
import Hwfl.Ast.Name (Ident (..), QName (..))
import Hwfl.Ast.Skill (SkillKind (..), SkillMeta (..))
import Hwfl.Check.Project (CheckProjectResult (..), checkProject)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider, mockProviderWith)
import Hwfl.Obs.Observer (noopObserver)
import Hwfl.Llm.Provider (LlmProvider (..))
import Hwfl.Llm.Types
  ( ChatRequest (..),
    FinishReason (..),
    ProviderResult (..),
    TokenUsage (..),
    ToolCall (..),
    ToolSpec (..),
    Turn (..),
  )
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Project (LoadedProject (..), loadProject)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    runLoadedModule,
  )
import Hwfl.Runtime.Skills (AgentSkillLoad (..), agentLoadSkill)
import Hwfl.SkillCatalog
  ( SkillCatalog (..),
    SkillPolicy (..),
    isSkillQName,
    skillMetaForModule,
  )
import System.Directory (copyFile, createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

fixtureRoot :: FilePath
fixtureRoot = "test/fixtures" </> "skills-project"

spec :: Spec
spec = describe "skills runtime (phases B–C)" $ do
  it "skill.discover / skill.load work outside an agent" $
    withSystemTempDirectory "hwfl-skills-scripted" $ \dir -> do
      copyProject fixtureRoot dir
      result <- checkProject dir
      case result of
        Left err -> expectationFailure (show err)
        Right cpr -> do
          lp <- loadProjectOrFail dir
          case loadModuleText "workflows/main.md" scriptedSrc of
            Left diags -> expectationFailure (show diags)
            Right loaded -> do
              let skillMods = callableSkills lp
                  opts =
                    RunOptions
                      { roWorkspace = dir,
                        roProvider = mockProvider,
                        roInputs = [],
                        roRunId = Just "skills-scripted",
                        roEntry = dir </> "workflows" </> "main.md",
                        roMode = StepRun,
                        roProjectHash = Nothing,
                        roExec = Nothing,
                        roObserver = noopObserver,
                        roCost = False,
                    roModelCatalog = "model-catalog.json",
                        roSkillCatalog = cpr.cprSkillCatalog,
                        roSkillModules = skillMods
                      }
              outcome <- runLoadedModule opts loaded
              case outcome of
                OutcomeCompleted (VRecord fs) _ _ -> do
                  lookup (Ident "ok") fs `shouldBe` Just (VBool True)
                  case lookup (Ident "content") fs of
                    Just (VString t) -> t `shouldSatisfy` T.isInfixOf "sh -n"
                    other -> expectationFailure ("bad content: " <> show other)
                other -> expectationFailure (show other)

  it "agent loads instruction + callable; double-load is idempotent" $
    withSystemTempDirectory "hwfl-skills-agent" $ \dir -> do
      copyProject fixtureRoot dir
      result <- checkProject dir
      case result of
        Left err -> expectationFailure (show err)
        Right cpr -> do
          lp <- loadProjectOrFail dir
          case loadModuleText "workflows/agent.md" agentSrc of
            Left diags -> expectationFailure (show diags)
            Right loaded -> do
              let opts =
                    RunOptions
                      { roWorkspace = dir,
                        roProvider = agentSkillsMock,
                        roInputs = [],
                        roRunId = Just "skills-agent",
                        roEntry = dir </> "workflows" </> "agent.md",
                        roMode = StepRun,
                        roProjectHash = Nothing,
                        roExec = Nothing,
                        roObserver = noopObserver,
                        roCost = False,
                    roModelCatalog = "model-catalog.json",
                        roSkillCatalog = cpr.cprSkillCatalog,
                        roSkillModules = callableSkills lp
                      }
              outcome <- runLoadedModule opts loaded
              case outcome of
                OutcomeCompleted (VRecord fs) _ _ -> do
                  lookup (Ident "text") fs `shouldBe` Just (VString "used skills")
                other -> expectationFailure (show other)

  it "ineligible callable and instruction budget overflow are recoverable" $ do
    result <- checkProject fixtureRoot
    case result of
      Left err -> expectationFailure (show err)
      Right cpr -> do
        let cat =
              cpr.cprSkillCatalog
                { scPolicy =
                    SkillPolicy
                      { spMaxCallableLoads = 20,
                        spMaxInstructionLoads = 0,
                        spMaxInstructionChars = 12000
                      }
                }
            loadMeta = agentLoadSkill cat [] [] 0 "skills/meta-peek"
            loadBudget = agentLoadSkill cat [] [] 0 "skills/shell-repair-guide"
        case loadMeta.aslResult of
          VRecord fs -> do
            lookup (Ident "ok") fs `shouldBe` Just (VBool False)
            case lookup (Ident "error") fs of
              Just (VString e) -> e `shouldSatisfy` T.isInfixOf "agent-eligible"
              _ -> expectationFailure "missing error"
          _ -> expectationFailure "bad result"
        case loadBudget.aslResult of
          VRecord fs -> lookup (Ident "ok") fs `shouldBe` Just (VBool False)
          _ -> expectationFailure "bad budget result"

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

copyProject :: FilePath -> FilePath -> IO ()
copyProject src dst = do
  createDirectoryIfMissing True (dst </> "workflows")
  createDirectoryIfMissing True (dst </> "skills")
  copyFile (src </> "project.json") (dst </> "project.json")
  copyFile (src </> "workflows" </> "main.md") (dst </> "workflows" </> "main.md")
  mapM_
    ( \name ->
        copyFile (src </> "skills" </> name) (dst </> "skills" </> name)
    )
    ["shell-repair-guide.md", "echo-tool.md", "meta-peek.md"]

scriptedSrc :: Text
scriptedSrc =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs: {}",
      "outputs:",
      "  ok: Bool",
      "  content: String",
      "effects: [Meta, Read]",
      "---",
      "",
      "```hwfl",
      "fun main(_): { ok: Bool, content: String } =",
      "  let found = skill.discover(query = \"shell\", kinds = [\"instruction\"], limit = 5)",
      "  let loaded = skill.load(id = \"skills/shell-repair-guide\")",
      "  { ok = found.ok && loaded.ok, content = loaded.content }",
      "```"
    ]

agentSrc :: Text
agentSrc =
  T.unlines
    [ "---",
      "name: workflows/agent",
      "inputs: {}",
      "outputs:",
      "  text: String",
      "  rounds: Int",
      "effects: [Meta, Read, Net]",
      "---",
      "",
      "## system",
      "",
      "Use skills when helpful.",
      "",
      "```hwfl",
      "fun main(_): { text: String, rounds: Int } =",
      "  let result = llm.agent(",
      "    system = @system,",
      "    prompt = \"fix shell\",",
      "    tools = [tool(skill.discover), tool(skill.load)],",
      "    model = \"gpt-5\",",
      "    max_rounds = 8",
      "  )",
      "  { text = result.text, rounds = result.rounds }",
      "```"
    ]

agentSkillsMock :: LlmProvider
agentSkillsMock = mockProviderWith reply
  where
    reply :: ChatRequest -> Either a ProviderResult
    reply req =
      let assistants = length (filter isAssistant req.chatTurns)
       in case assistants of
            0 ->
              Right
                ProviderResult
                  { prContent = "",
                    prToolCalls =
                      [ ToolCall
                          "c0"
                          "skill_discover"
                          ( object
                              [ "query" .= ("shell" :: Text),
                                "kinds" .= ([] :: [Text]),
                                "limit" .= (5 :: Int)
                              ]
                          ),
                        ToolCall "c1" "skill_load" (object ["id" .= ("skills/shell-repair-guide" :: Text)])
                      ],
                    prUsage = Just (TokenUsage 1 1),
                    prFinishReason = FinishToolCalls
                  }
            1 ->
              Right
                ProviderResult
                  { prContent = "",
                    prToolCalls =
                      [ ToolCall "c2" "skill_load" (object ["id" .= ("skills/echo-tool" :: Text)])
                      ],
                    prUsage = Just (TokenUsage 1 1),
                    prFinishReason = FinishToolCalls
                  }
            2 ->
              Right
                ProviderResult
                  { prContent = "",
                    prToolCalls =
                      [ ToolCall "c3" "skill_load" (object ["id" .= ("skills/echo-tool" :: Text)])
                      ],
                    prUsage = Just (TokenUsage 1 1),
                    prFinishReason = FinishToolCalls
                  }
            _ ->
              Right
                ProviderResult
                  { prContent =
                      if maybe False (T.isInfixOf "Loaded skill: skills/shell-repair-guide") req.chatSystem
                        && any (\t -> t.tsName == "skills_echo_tool") req.chatTools
                        then "used skills"
                        else "missing skill effects",
                    prToolCalls = [],
                    prUsage = Just (TokenUsage 1 1),
                    prFinishReason = FinishStop
                  }

    isAssistant = \case
      TurnAssistant {} -> True
      _ -> False
