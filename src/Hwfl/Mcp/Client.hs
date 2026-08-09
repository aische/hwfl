-- | Minimal stdio MCP client (spec [13-mcp.md](../../../docs/spec/13-mcp.md)):
-- spawn a server subprocess, speak newline-delimited JSON-RPC 2.0 on
-- stdin/stdout, and expose @tools/list@ / @tools/call@. This module is the
-- vendor-facing transport only — runtime lifecycle (per-run registry,
-- 'HostEnv' wiring, config) lives in "Hwfl.Runtime.Mcp".
--
-- Calls on one connection are serialized by an internal lock: v1 issues at
-- most one in-flight @tools/call@ per server (the machine's @par@ pool is
-- cooperative, not OS-thread-concurrent — see [architecture.md](../../../docs/architecture.md)
-- — but a future concurrent @par@ must not desync request/response matching
-- on a single pipe).
module Hwfl.Mcp.Client
  ( McpConnection,
    McpSpawnSpec (..),
    McpToolInfo (..),
    McpCallOutcome (..),
    connectMcp,
    listMcpTools,
    callMcpTool,
    closeMcpConnection,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Exception (IOException, SomeException, try)
import Data.Aeson (object, (.:), (.:?), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap (KeyMap)
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseMaybe, (.!=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Vector qualified as V
import Hwfl.Runtime.ProcGroup (killProcessGroup)
import System.IO (Handle, hFlush, hSetBinaryMode)
import System.Process.Typed
  ( Process,
    getStderr,
    getStdin,
    getStdout,
    proc,
    setCreateGroup,
    setEnv,
    setStderr,
    setStdin,
    setStdout,
    setWorkingDir,
    startProcess,
    stopProcess,
    unsafeProcessHandle,
  )
import System.Process.Typed qualified as PT
import System.Timeout (timeout)

-- | Everything needed to spawn one server. Command/args/env/cwd are the
-- project's trust boundary (spec §13 §3) — this module trusts its caller to
-- have already resolved them from an allowlisted @project.json@ entry.
data McpSpawnSpec = McpSpawnSpec
  { mssServerId :: Text,
    mssCommand :: Text,
    mssArgs :: [Text],
    mssEnv :: [(Text, Text)],
    mssCwd :: FilePath,
    mssTimeoutMs :: Int,
    -- | Progress / stderr sink (redacted upstream like other host logs).
    mssLog :: Text -> IO ()
  }

data McpToolInfo = McpToolInfo
  { mtiName :: Text,
    mtiDescription :: Text,
    mtiInputSchema :: Aeson.Value
  }
  deriving stock (Eq, Show)

-- | Result of one @tools/call@. 'McpToolFailed' is the tool-level @isError@
-- case (spec §5: recoverable, agent soft-land); transport/protocol failures
-- surface as 'Left' from 'callMcpTool' instead (hard host error).
data McpCallOutcome
  = McpCallOk Aeson.Value
  | McpToolFailed Text
  deriving stock (Eq, Show)

data McpConnection = McpConnection
  { mcServerId :: Text,
    mcProcess :: Process Handle Handle Handle,
    mcNextId :: IORef Int,
    mcLock :: MVar (),
    mcTimeoutMicros :: Int,
    mcLog :: Text -> IO ()
  }

-- | Spawn the server, then attempt the @initialize@ / @initialized@
-- handshake. A JSON-RPC error response to @initialize@ (older or newer
-- servers may not implement it) is logged and treated as an
-- already-stateless server, per spec §2; only a transport-level failure
-- (spawn error, dead pipe, timeout) fails the connection.
connectMcp :: McpSpawnSpec -> IO (Either Text McpConnection)
connectMcp spec = do
  let cfg =
        setCreateGroup True
          . setStdin PT.createPipe
          . setStdout PT.createPipe
          . setStderr PT.createPipe
          . setWorkingDir spec.mssCwd
          . setEnv [(T.unpack k, T.unpack v) | (k, v) <- spec.mssEnv]
          $ proc (T.unpack spec.mssCommand) (map T.unpack spec.mssArgs)
  spawned <- try (startProcess cfg) :: IO (Either IOException (Process Handle Handle Handle))
  case spawned of
    Left ex ->
      pure (Left ("mcp[" <> spec.mssServerId <> "]: spawn failed: " <> T.pack (show ex)))
    Right p -> do
      hSetBinaryMode (getStdin p) True
      hSetBinaryMode (getStdout p) True
      hSetBinaryMode (getStderr p) True
      _ <- forkIO (drainStderr spec.mssServerId (getStderr p) spec.mssLog)
      nextId <- newIORef 1
      lock <- newMVar ()
      let conn =
            McpConnection
              { mcServerId = spec.mssServerId,
                mcProcess = p,
                mcNextId = nextId,
                mcLock = lock,
                mcTimeoutMicros = max 1 spec.mssTimeoutMs * 1000,
                mcLog = spec.mssLog
              }
      initResult <- sendRequest conn "initialize" initializeParams
      case initResult of
        Left transportErr -> do
          closeMcpConnection conn
          pure (Left transportErr)
        Right (Left rpcErr) -> do
          spec.mssLog
            ( "mcp["
                <> spec.mssServerId
                <> "] initialize: "
                <> rpcErr
                <> " (continuing; server may not implement sessions)"
            )
          pure (Right conn)
        Right (Right _result) -> do
          sendNotification conn "notifications/initialized" (object [])
          pure (Right conn)

initializeParams :: Aeson.Value
initializeParams =
  object
    [ "protocolVersion" .= ("2025-06-18" :: Text),
      "capabilities" .= object [],
      "clientInfo" .= object ["name" .= ("hwfl" :: Text), "version" .= ("0.1.0" :: Text)]
    ]

closeMcpConnection :: McpConnection -> IO ()
closeMcpConnection conn = do
  killProcessGroup (unsafeProcessHandle conn.mcProcess)
  _ <- (try (stopProcess conn.mcProcess) :: IO (Either SomeException ()))
  pure ()

listMcpTools :: McpConnection -> IO (Either Text [McpToolInfo])
listMcpTools conn = do
  r <- sendRequest conn "tools/list" (object [])
  pure $ case r of
    Left err -> Left err
    Right (Left rpcErr) -> Left ("mcp[" <> conn.mcServerId <> "] tools/list: " <> rpcErr)
    Right (Right result) -> parseToolsList result

callMcpTool :: McpConnection -> Text -> Aeson.Value -> IO (Either Text McpCallOutcome)
callMcpTool conn toolName arguments = do
  r <- sendRequest conn "tools/call" (object ["name" .= toolName, "arguments" .= arguments])
  pure $ case r of
    Left err -> Left err
    Right (Left rpcErr) -> Left ("mcp[" <> conn.mcServerId <> "] tools/call " <> toolName <> ": " <> rpcErr)
    Right (Right result) -> Right (normalizeCallResult result)

-- | Fold MCP content blocks (spec §4.1: "normalized to JSON / text then
-- parsed when possible") into a single hwfl-facing JSON value.
normalizeCallResult :: Aeson.Value -> McpCallOutcome
normalizeCallResult raw =
  let isError = case raw of
        Aeson.Object o -> KM.lookup "isError" o == Just (Aeson.Bool True)
        _ -> False
      content = contentText raw
   in if isError
        then McpToolFailed (if T.null content then "mcp tool reported an error" else content)
        else McpCallOk (parseJsonish content raw)
  where
    contentText = \case
      Aeson.Object o -> case KM.lookup "content" o of
        Just (Aeson.Array blocks) -> T.intercalate "\n" (concatMap textBlock (V.toList blocks))
        _ -> ""
      _ -> ""
    textBlock = \case
      Aeson.Object b
        | KM.lookup "type" b == Just (Aeson.String "text"),
          Just (Aeson.String t) <- KM.lookup "text" b ->
            [t]
      _ -> []
    -- Prefer the decoded content text as JSON; fall back to the raw string,
    -- then to the whole untouched response if there was no content at all.
    parseJsonish text whole
      | T.null text = whole
      | otherwise = case Aeson.decodeStrict (encodeUtf8 text) of
          Just v -> v
          Nothing -> Aeson.String text

parseToolsList :: Aeson.Value -> Either Text [McpToolInfo]
parseToolsList = \case
  Aeson.Object o -> case KM.lookup "tools" o of
    Just (Aeson.Array xs) -> traverse parseToolInfo (V.toList xs)
    _ -> Left "mcp tools/list: missing tools array"
  _ -> Left "mcp tools/list: expected an object result"

parseToolInfo :: Aeson.Value -> Either Text McpToolInfo
parseToolInfo v = case parseMaybe parser v of
  Just info -> Right info
  Nothing -> Left "mcp tools/list: malformed tool entry"
  where
    parser = Aeson.withObject "tool" $ \o -> do
      name <- o .: "name"
      desc <- o .:? "description" .!= ""
      schema <- o .:? "inputSchema" .!= object ["type" .= ("object" :: Text)]
      pure McpToolInfo {mtiName = name, mtiDescription = desc, mtiInputSchema = schema}

-- | Send one JSON-RPC request and await the matching response (or timeout).
-- Outer 'Left' is a transport failure (dead connection); inner 'Left' is a
-- JSON-RPC error object from an alive server.
sendRequest ::
  McpConnection ->
  Text ->
  Aeson.Value ->
  IO (Either Text (Either Text Aeson.Value))
sendRequest conn method params = withMVar conn.mcLock $ \_ -> do
  reqId <- atomicModifyIORef' conn.mcNextId (\n -> (n + 1, n))
  let msg =
        object
          [ "jsonrpc" .= ("2.0" :: Text),
            "id" .= reqId,
            "method" .= method,
            "params" .= params
          ]
  sent <- try (sendLine (getStdin conn.mcProcess) msg) :: IO (Either IOException ())
  case sent of
    Left ex -> pure (Left (connErr conn ("write failed: " <> T.pack (show ex))))
    Right () -> do
      r <- timeout conn.mcTimeoutMicros (awaitResponse conn reqId)
      pure $ case r of
        Nothing -> Left (connErr conn "request timed out")
        Just outcome -> outcome

-- | Fire-and-forget JSON-RPC notification (no @id@, no response expected).
sendNotification :: McpConnection -> Text -> Aeson.Value -> IO ()
sendNotification conn method params = withMVar conn.mcLock $ \_ -> do
  let msg = object ["jsonrpc" .= ("2.0" :: Text), "method" .= method, "params" .= params]
  r <- try (sendLine (getStdin conn.mcProcess) msg) :: IO (Either IOException ())
  case r of
    Left ex -> conn.mcLog (connErr conn ("notification write failed: " <> T.pack (show ex)))
    Right () -> pure ()

-- | Read lines until one carries our request id. Server-to-client
-- notifications (no @id@) are logged and skipped — v1 has no sampling /
-- elicitation to answer. A stray mismatched id is logged and skipped too
-- (defensive; single in-flight request per lock should make this rare).
awaitResponse :: McpConnection -> Int -> IO (Either Text (Either Text Aeson.Value))
awaitResponse conn reqId = do
  lineE <- try (BS.hGetLine (getStdout conn.mcProcess)) :: IO (Either IOException BS.ByteString)
  case lineE of
    Left ex -> pure (Left (connErr conn ("connection closed: " <> T.pack (show ex))))
    Right line
      | BS.null (BS.filter (/= 0x20) line) -> awaitResponse conn reqId
      | otherwise -> case Aeson.decodeStrict line :: Maybe Aeson.Value of
          Nothing -> pure (Left (connErr conn "invalid JSON-RPC message"))
          Just (Aeson.Object o) -> case KM.lookup "id" o of
            Just (Aeson.Number n) | round n == reqId -> pure (Right (classifyResponse o))
            Nothing -> do
              conn.mcLog (connErr conn "ignoring server notification while awaiting a response")
              awaitResponse conn reqId
            Just _ -> do
              conn.mcLog (connErr conn "ignoring response with mismatched id")
              awaitResponse conn reqId
          Just _ -> pure (Left (connErr conn "invalid JSON-RPC message shape"))

classifyResponse :: KeyMap Aeson.Value -> Either Text Aeson.Value
classifyResponse o = case KM.lookup "error" o of
  Just (Aeson.Object errObj) ->
    let msg = case KM.lookup "message" errObj of
          Just (Aeson.String t) -> t
          _ -> "unknown error"
        code = case KM.lookup "code" errObj of
          Just (Aeson.Number n) -> T.pack (show (round n :: Integer))
          _ -> "?"
     in Left ("[" <> code <> "] " <> msg)
  Just other -> Left (T.pack (show other))
  Nothing -> Right (fromMaybe Aeson.Null (KM.lookup "result" o))

connErr :: McpConnection -> Text -> Text
connErr conn msg = "mcp[" <> conn.mcServerId <> "]: " <> msg

-- | Pipes default to block buffering; without an explicit flush a request
-- can sit in our write buffer forever and the server-side read times out
-- with no bytes ever having crossed the pipe.
sendLine :: Handle -> Aeson.Value -> IO ()
sendLine h v = do
  BSL.hPut h (Aeson.encode v <> "\n")
  hFlush h

-- | Drain server stderr forever (best-effort logging); exits quietly on EOF
-- or a dead pipe once the process is torn down.
drainStderr :: Text -> Handle -> (Text -> IO ()) -> IO ()
drainStderr serverId h logFn = go
  where
    go = do
      r <- try (BS.hGetLine h) :: IO (Either IOException BS.ByteString)
      case r of
        Left _ -> pure ()
        Right line -> do
          logFn ("mcp[" <> serverId <> "] stderr: " <> decodeUtf8With lenientDecode line)
          go
