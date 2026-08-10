-- | @mcp.call@ / @mcp.tools@ host op wiring end to end against the fixture
-- server ("test/fixtures/mcp/echo_server.py"): @project.json@ config,
-- @schema(T)@ result typing, unknown-server fail-closed, and @llm.agent@
-- dispatch of an MCP tool with @bind@ merge + schema stripping
-- (spec docs/spec/13-mcp.md).
module Hwfl.Runtime.McpSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider, mockProviderWith)
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
import Hwfl.Project (McpCwd (..), McpPolicy (..), McpServerConfig (..), loadProjectConfig)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    emptySkillRuntime,
    runLoadedModule,
  )
import System.Directory (makeAbsolute)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

fixtureServer :: FilePath
fixtureServer = "test" </> "fixtures" </> "mcp" </> "echo_server.py"

-- | @mcp.servers.echo@ pointed at the fixture; the absolute script path
-- means @cwd@ (workspace vs. project) doesn't matter for spawning it.
echoServerConfig :: FilePath -> McpServerConfig
echoServerConfig absScript =
  McpServerConfig
    { mcpCommand = "python3",
      mcpArgs = [T.pack absScript],
      mcpEnv = ["PATH"],
      mcpCwd = McpCwdWorkspace,
      mcpTimeoutMs = Just 5_000
    }

echoMcpPolicy :: FilePath -> McpPolicy
echoMcpPolicy absScript =
  McpPolicy
    { mpAllow = ["python3"],
      mpAllowAbsoluteCwd = False,
      mpServers = Map.fromList [("echo", echoServerConfig absScript)]
    }

mcpCallSrc :: Text
mcpCallSrc =
  T.unlines
    [ "---",
      "name: workflows/mcp-call",
      "inputs: {}",
      "outputs:",
      "  out: String",
      "effects: [Exec]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { out: String } =",
      "  let result = mcp.call(",
      "    server = \"echo\",",
      "    name = \"echo\",",
      "    arguments = { text = \"hi\" }",
      "  )",
      "  { out = json.encode(result) }",
      "```"
    ]

mcpCallSchemaSrc :: Text
mcpCallSchemaSrc =
  T.unlines
    [ "---",
      "name: workflows/mcp-call-schema",
      "inputs: {}",
      "outputs:",
      "  echoed: String",
      "effects: [Exec]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "type EchoOut = { echoed: String }",
      "fun main(_): { echoed: String } =",
      "  let result: EchoOut = mcp.call(",
      "    server = \"echo\",",
      "    name = \"echo\",",
      "    arguments = { text = \"hi\" },",
      "    schema = schema(EchoOut)",
      "  )",
      "  { echoed = result.echoed }",
      "```"
    ]

mcpCallUnknownServerSrc :: Text
mcpCallUnknownServerSrc =
  T.unlines
    [ "---",
      "name: workflows/mcp-call-unknown",
      "inputs: {}",
      "outputs:",
      "  out: String",
      "effects: [Exec]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { out: String } =",
      "  let result = mcp.call(",
      "    server = \"nope\",",
      "    name = \"echo\",",
      "    arguments = { text = \"hi\" }",
      "  )",
      "  { out = json.encode(result) }",
      "```"
    ]

mcpAgentSrc :: Text
mcpAgentSrc =
  T.unlines
    [ "---",
      "name: workflows/mcp-agent",
      "inputs: {}",
      "outputs:",
      "  text: String",
      "effects: [Net, Exec]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { text: String } =",
      "  let result = llm.agent(",
      "    system = \"sys\",",
      "    prompt = \"go\",",
      "    tools = mcp.tools(server = \"echo\", names = [\"add\"], bind = { a = 10 }),",
      "    model = \"gpt-5\"",
      "  )",
      "  { text = result.text }",
      "```"
    ]

baseOpts :: FilePath -> McpPolicy -> String -> RunOptions
baseOpts dir mcp entry =
  RunOptions
    { roWorkspace = dir,
      roProvider = mockProvider,
      roInputs = [],
      roRunId = Just (T.pack entry),
      roEntry = entry,
      roMode = StepRun,
      roProjectHash = Nothing,
      roExec = Nothing,
      roMcp = mcp,
      roProjectRoot = dir,
      roObserver = noopObserver,
      roCost = False,
      roModelCatalog = "model-catalog.json",
      roSkillCatalog = fst emptySkillRuntime,
      roSkillModules = snd emptySkillRuntime,
      roEntryModules = mempty
    }

spec :: Spec
spec = describe "mcp.call / mcp.tools" $ do
  it "calls a tool directly and decodes the default Json result" $
    withSystemTempDirectory "hwfl-mcp-call" $ \dir -> do
      absScript <- makeAbsolute fixtureServer
      case loadModuleText "mcp-call.md" mcpCallSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRightC
          let opts = baseOpts dir (echoMcpPolicy absScript) "mcp-call.md"
          outcome <- runLoadedModule opts loaded
          case outcome of
            OutcomeCompleted (VRecord fs) _ _ ->
              case lookup (Ident "out") fs of
                Just (VString s) -> s `shouldBe` "{\"echoed\":\"hi\"}"
                other -> expectationFailure (show other)
            other -> expectationFailure ("expected completed, got: " <> show other)

  it "checks and decodes schema(T) results (E14)" $
    withSystemTempDirectory "hwfl-mcp-call-schema" $ \dir -> do
      absScript <- makeAbsolute fixtureServer
      case loadModuleText "mcp-call-schema.md" mcpCallSchemaSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRightC
          let opts = baseOpts dir (echoMcpPolicy absScript) "mcp-call-schema.md"
          outcome <- runLoadedModule opts loaded
          case outcome of
            OutcomeCompleted (VRecord fs) _ _ ->
              lookup (Ident "echoed") fs `shouldBe` Just (VString "hi")
            other -> expectationFailure ("expected completed, got: " <> show other)

  it "fails closed on a server id absent from mcp.servers" $
    withSystemTempDirectory "hwfl-mcp-call-unknown" $ \dir -> do
      absScript <- makeAbsolute fixtureServer
      case loadModuleText "mcp-call-unknown.md" mcpCallUnknownServerSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRightC
          let opts = baseOpts dir (echoMcpPolicy absScript) "mcp-call-unknown.md"
          outcome <- runLoadedModule opts loaded
          outcome `shouldSatisfy` isFailedC

  it "rejects a command not on mcp.allow at spawn (H-8)" $
    withSystemTempDirectory "hwfl-mcp-allow" $ \dir -> do
      absScript <- makeAbsolute fixtureServer
      case loadModuleText "mcp-call.md" mcpCallSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          let denied =
                McpPolicy
                  { mpAllow = ["node"],
                    mpAllowAbsoluteCwd = False,
                    mpServers = Map.fromList [("echo", echoServerConfig absScript)]
                  }
              opts = baseOpts dir denied "mcp-call.md"
          outcome <- runLoadedModule opts loaded
          outcome `shouldSatisfy` isFailedC

  it "dispatches an mcp.tools tool from llm.agent, merging bind and stripping it from the schema" $
    withSystemTempDirectory "hwfl-mcp-agent" $ \dir -> do
      absScript <- makeAbsolute fixtureServer
      case loadModuleText "mcp-agent.md" mcpAgentSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          checkLoadedModule loaded `shouldSatisfy` isRightC
          let opts =
                (baseOpts dir (echoMcpPolicy absScript) "mcp-agent.md")
                  { roProvider = mcpAgentMock
                  }
          outcome <- runLoadedModule opts loaded
          case outcome of
            OutcomeCompleted (VRecord fs) _ _ ->
              lookup (Ident "text") fs `shouldBe` Just (VString "{\"sum\":15}")
            other -> expectationFailure ("expected completed, got: " <> show other)

  describe "mcp.allow / cwd policy (H-8)" $ do
    it "rejects a path-shaped command in project.json" $
      withSystemTempDirectory "hwfl-mcp-path-cmd" $ \dir -> do
        writeFile
          (dir </> "project.json")
          ( mcpProjectJson
              [ "\"allow\": [\"/bin/bash\"]",
                "\"servers\": { \"kb\": { \"command\": \"/bin/bash\", \"args\": [] } }"
              ]
          )
        loadProjectConfig dir
          >>= ( `shouldSatisfy`
                  \case
                    Left msg -> "bare basename" `T.isInfixOf` msg
                    Right _ -> False
              )

    it "rejects a server command missing from mcp.allow" $
      withSystemTempDirectory "hwfl-mcp-missing-allow" $ \dir -> do
        writeFile
          (dir </> "project.json")
          ( mcpProjectJson
              [ "\"allow\": [\"node\"]",
                "\"servers\": { \"kb\": { \"command\": \"bash\", \"args\": [] } }"
              ]
          )
        loadProjectConfig dir
          >>= ( `shouldSatisfy`
                  \case
                    Left msg -> "mcp.allow" `T.isInfixOf` msg
                    Right _ -> False
              )

    it "rejects absolute cwd unless allow_absolute_cwd is true" $
      withSystemTempDirectory "hwfl-mcp-abs-cwd" $ \dir -> do
        writeFile
          (dir </> "project.json")
          ( mcpProjectJson
              [ "\"allow\": [\"bash\"]",
                "\"servers\": { \"kb\": { \"command\": \"bash\", \"cwd\": \"/tmp\", \"args\": [] } }"
              ]
          )
        loadProjectConfig dir
          >>= ( `shouldSatisfy`
                  \case
                    Left msg -> "allow_absolute_cwd" `T.isInfixOf` msg
                    Right _ -> False
              )

    it "accepts absolute cwd when allow_absolute_cwd is true" $
      withSystemTempDirectory "hwfl-mcp-abs-cwd-ok" $ \dir -> do
        writeFile
          (dir </> "project.json")
          ( mcpProjectJson
              [ "\"allow\": [\"bash\"]",
                "\"allow_absolute_cwd\": true",
                "\"servers\": { \"kb\": { \"command\": \"bash\", \"cwd\": \"/tmp\", \"args\": [] } }"
              ]
          )
        loadProjectConfig dir >>= (`shouldSatisfy` isRightC)

mcpProjectJson :: [String] -> String
mcpProjectJson mcpFields =
  unlines
    [ "{",
      "  \"name\": \"mcp-h8\",",
      "  \"version\": \"0.1.0\",",
      "  \"entrypoint\": \"workflows/main\",",
      "  \"mcp\": {",
      "    " <> intercalateCsv mcpFields,
      "  }",
      "}"
    ]
  where
    intercalateCsv [] = ""
    intercalateCsv [x] = x
    intercalateCsv (x : xs) = x <> ",\n    " <> intercalateCsv xs

-- | First round: assert the advertised @echo__add@ schema has @bind@'s @a@
-- stripped, then call it with only @b@. Second round: read back the tool
-- result content (the merged @add(a=10, b=5)@ call) and echo it as the
-- final answer so the test can assert on it without extra plumbing.
mcpAgentMock :: LlmProvider
mcpAgentMock = mockProviderWith mcpAgentMockReply

mcpAgentMockReply :: ChatRequest -> Either a ProviderResult
mcpAgentMockReply req
  | any isToolTurn req.chatTurns =
      Right
        ProviderResult
          { prContent = toolResultContent req,
            prToolCalls = [],
            prUsage = Just (TokenUsage 1 1),
            prFinishReason = FinishStop
          }
  | otherwise =
      case advertisedAddProps req of
        props
          | KM.member "a" props ->
              error "mcp.tools bind field 'a' must be stripped from the advertised schema"
          | not (KM.member "b" props) ->
              error "mcp.tools schema is missing the unbound field 'b'"
          | otherwise ->
              Right
                ProviderResult
                  { prContent = "calling add",
                    prToolCalls = [ToolCall "c1" "echo__add" (object ["b" .= (5 :: Int)])],
                    prUsage = Just (TokenUsage 1 1),
                    prFinishReason = FinishToolCalls
                  }
  where
    isToolTurn = \case
      TurnTool _ -> True
      _ -> False

advertisedAddProps :: ChatRequest -> Aeson.Object
advertisedAddProps req = case [t | t <- req.chatTools, t.tsName == "echo__add"] of
  (tool : _) -> case tool.tsParameters of
    Aeson.Object o -> case KM.lookup "properties" o of
      Just (Aeson.Object ps) -> ps
      _ -> mempty
    _ -> mempty
  [] -> error "expected an advertised echo__add tool"

toolResultContent :: ChatRequest -> Text
toolResultContent req =
  case [trContent r | TurnTool rs <- req.chatTurns, r <- rs, r.trName == "echo__add"] of
    (c : _) -> c
    [] -> "missing echo__add tool result"

isRightC :: Either a b -> Bool
isRightC = \case
  Right _ -> True
  Left _ -> False

isFailedC :: RunOutcome -> Bool
isFailedC = \case
  OutcomeFailed {} -> True
  _ -> False
