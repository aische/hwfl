-- | Runtime glue for the MCP client (spec [13-mcp.md](../../../docs/spec/13-mcp.md)):
-- per-run connection registry, config → 'Hwfl.Mcp.Client.McpSpawnSpec'
-- resolution, and the @bind@ merge / schema-stripping used by @mcp.tools@.
-- "Hwfl.Mcp.Client" stays protocol-only; this module is the only place that
-- knows about 'Hwfl.Project.McpServerConfig' and 'Hwfl.Runtime.Host.HostEnv'.
module Hwfl.Runtime.Mcp
  ( McpEnv,
    newMcpEnv,
    emptyMcpEnv,
    closeMcpEnv,
    getMcpConnection,
    mergeMcpBindArgs,
    stripBindFromSchema,
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Hwfl.Mcp.Client
  ( McpConnection,
    McpSpawnSpec (..),
    closeMcpConnection,
    connectMcp,
  )
import Hwfl.Project (McpCwd (..), McpServerConfig (..))
import Hwfl.Runtime.Error (RuntimeError (..))
import System.Environment (getEnvironment)

-- | Per-run cache: servers are spawned lazily on first use and never
-- outlive one @hwfl run/step/resume/...@ driver call, which already gives
-- us "reconnect lazily on resume" (spec §13 §5) for free — a fresh
-- 'McpEnv' is built per driver invocation (see 'Hwfl.Runtime.Run.mkHostEnv').
data McpEnv = McpEnv
  { meServers :: Map Text McpServerConfig,
    meConnections :: MVar (Map Text McpConnection),
    meProjectRoot :: FilePath,
    meWorkspaceRoot :: FilePath,
    meLog :: Text -> IO ()
  }

-- | Per-request timeout fallback when a server has no @timeout_ms@.
defaultMcpTimeoutMs :: Int
defaultMcpTimeoutMs = 30_000

newMcpEnv :: Map Text McpServerConfig -> FilePath -> FilePath -> (Text -> IO ()) -> IO McpEnv
newMcpEnv servers projectRoot workspaceRoot logFn = do
  conns <- newMVar Map.empty
  pure
    McpEnv
      { meServers = servers,
        meConnections = conns,
        meProjectRoot = projectRoot,
        meWorkspaceRoot = workspaceRoot,
        meLog = logFn
      }

-- | No configured servers; every @mcp.*@ call fails closed (spec §13 §3).
emptyMcpEnv :: IO McpEnv
emptyMcpEnv = newMcpEnv Map.empty "" "" (const (pure ()))

-- | Kill every cached connection (spec §13 §5: "kill process group when the
-- run completes or the runtime shuts down"). Safe to call more than once.
closeMcpEnv :: McpEnv -> IO ()
closeMcpEnv env = do
  conns <- modifyMVar env.meConnections (\m -> pure (Map.empty, m))
  mapM_ closeMcpConnection (Map.elems conns)

-- | Return the cached connection for @serverId@, spawning + handshaking one
-- on first use. A dead cached connection is not currently detected here —
-- the next @tools/call@ surfaces the transport error and the caller can
-- retry, at which point a fresh driver invocation reconnects (spec §13 §5:
-- "next MCP call fails clearly if reconnect fails").
getMcpConnection :: McpEnv -> Text -> IO (Either RuntimeError McpConnection)
getMcpConnection env serverId = modifyMVar env.meConnections $ \conns ->
  case Map.lookup serverId conns of
    Just conn -> pure (conns, Right conn)
    Nothing -> case Map.lookup serverId env.meServers of
      Nothing ->
        pure
          ( conns,
            Left
              ( HostErr
                  ( "mcp: unknown server '"
                      <> serverId
                      <> "' (add it under mcp.servers in project.json)"
                  )
              )
          )
      Just cfg -> do
        spawnSpec <- resolveSpawnSpec env serverId cfg
        r <- connectMcp spawnSpec
        pure $ case r of
          Left err -> (conns, Left (HostErr err))
          Right conn -> (Map.insert serverId conn conns, Right conn)

resolveSpawnSpec :: McpEnv -> Text -> McpServerConfig -> IO McpSpawnSpec
resolveSpawnSpec env serverId cfg = do
  childEnv <- currentEnvFor cfg.mcpEnv
  pure
    McpSpawnSpec
      { mssServerId = serverId,
        mssCommand = cfg.mcpCommand,
        mssArgs = cfg.mcpArgs,
        mssEnv = childEnv,
        mssCwd = resolveCwd env cfg.mcpCwd,
        mssTimeoutMs = fromMaybe defaultMcpTimeoutMs cfg.mcpTimeoutMs,
        mssLog = env.meLog
      }

resolveCwd :: McpEnv -> McpCwd -> FilePath
resolveCwd env = \case
  McpCwdWorkspace -> env.meWorkspaceRoot
  McpCwdProject -> env.meProjectRoot
  McpCwdAbsolute p -> T.unpack p

currentEnvFor :: [Text] -> IO [(Text, Text)]
currentEnvFor names = do
  full <- getEnvironment
  let m = Map.fromList [(T.pack k, T.pack v) | (k, v) <- full]
  pure [(n, v) | n <- names, Just v <- [Map.lookup n m]]

-- | Merge a @bind@ record's fields into a @tools/call@ arguments object
-- (spec §13 §4.2). @bind@ wins on key collision — it is app-trusted state,
-- not model input.
mergeMcpBindArgs :: Aeson.Value -> Aeson.Value -> Either Text Aeson.Value
mergeMcpBindArgs bind args = case (bind, args) of
  (Aeson.Null, a) -> Right a
  (Aeson.Object b, Aeson.Null) -> Right (Aeson.Object b)
  (Aeson.Object b, Aeson.Object a) -> Right (Aeson.Object (KM.union b a))
  (Aeson.Object _, _) -> Left "mcp tool arguments must be an object"
  _ -> Left "mcp.tools bind must be a Json object"

-- | Remove @bind@'s top-level keys from an advertised @inputSchema@'s
-- @properties@ / @required@ so the model cannot invent or forget bound
-- handles (spec §13 §4.2).
stripBindFromSchema :: Aeson.Value -> Aeson.Value -> Aeson.Value
stripBindFromSchema bind schema = case (bind, schema) of
  (Aeson.Object b, Aeson.Object s) | not (KM.null b) ->
    let boundKeys = KM.keys b
        boundTexts = map Key.toText boundKeys
        s1 = case KM.lookup "properties" s of
          Just (Aeson.Object ps) ->
            KM.insert "properties" (Aeson.Object (foldr KM.delete ps boundKeys)) s
          _ -> s
        s2 = case KM.lookup "required" s1 of
          Just (Aeson.Array rs) ->
            KM.insert "required" (Aeson.Array (V.filter (notBound boundTexts) rs)) s1
          _ -> s1
     in Aeson.Object s2
  _ -> schema
  where
    notBound bs = \case
      Aeson.String t -> t `notElem` bs
      _ -> True
