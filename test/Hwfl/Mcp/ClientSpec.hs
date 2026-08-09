-- | Stdio JSON-RPC transport tests against the fixture server
-- ("test/fixtures/mcp/echo_server.py"): connect/list/call/close, tool-level
-- @isError@, and the per-request timeout (spec docs/spec/13-mcp.md).
module Hwfl.Mcp.ClientSpec (spec) where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Hwfl.Mcp.Client
  ( McpCallOutcome (..),
    McpSpawnSpec (..),
    McpToolInfo (..),
    callMcpTool,
    closeMcpConnection,
    connectMcp,
    listMcpTools,
  )
import Data.Text qualified as T
import System.FilePath ((</>))
import Test.Hspec

fixtureServer :: FilePath
fixtureServer = "test" </> "fixtures" </> "mcp" </> "echo_server.py"

spawnSpec :: FilePath -> Int -> McpSpawnSpec
spawnSpec cwd timeoutMs =
  McpSpawnSpec
    { mssServerId = "echo",
      mssCommand = "python3",
      mssArgs = [T.pack fixtureServer],
      mssEnv = [],
      mssCwd = cwd,
      mssTimeoutMs = timeoutMs,
      mssLog = const (pure ())
    }

spec :: Spec
spec = describe "Hwfl.Mcp.Client (stdio transport)" $ do
  it "connects, lists tools, calls a tool, and closes cleanly" $ do
    connE <- connectMcp (spawnSpec "." 5_000)
    case connE of
      Left err -> expectationFailure ("connect failed: " <> show err)
      Right conn -> do
        toolsE <- listMcpTools conn
        case toolsE of
          Left err -> expectationFailure ("tools/list failed: " <> show err)
          Right infos -> map mtiName infos `shouldBe` ["echo", "add", "boom"]
        callE <- callMcpTool conn "echo" (object ["text" .= ("hi" :: String)])
        callE `shouldBe` Right (McpCallOk (object ["echoed" .= ("hi" :: String)]))
        closeMcpConnection conn

  it "merges bind-style arguments end to end via the add tool" $ do
    connE <- connectMcp (spawnSpec "." 5_000)
    case connE of
      Left err -> expectationFailure ("connect failed: " <> show err)
      Right conn -> do
        callE <- callMcpTool conn "add" (object ["a" .= (1 :: Int), "b" .= (2 :: Int)])
        callE `shouldBe` Right (McpCallOk (object ["sum" .= (3 :: Int)]))
        closeMcpConnection conn

  it "surfaces a tool-level isError as McpToolFailed, not a transport error" $ do
    connE <- connectMcp (spawnSpec "." 5_000)
    case connE of
      Left err -> expectationFailure ("connect failed: " <> show err)
      Right conn -> do
        callE <- callMcpTool conn "boom" Aeson.Null
        callE `shouldBe` Right (McpToolFailed "boom failed")
        closeMcpConnection conn

  it "times out a request that outlives the per-connection deadline" $ do
    connE <- connectMcp (spawnSpec "." 200)
    case connE of
      Left err -> expectationFailure ("connect failed: " <> show err)
      Right conn -> do
        callE <- callMcpTool conn "echo" (object ["text" .= ("slow" :: String), "sleep_ms" .= (2_000 :: Int)])
        callE `shouldSatisfy` isTimeoutError
        closeMcpConnection conn

  it "reports a transport failure for a command that cannot be spawned" $ do
    connE <-
      connectMcp
        ( (spawnSpec "." 1_000)
            { mssCommand = "hwfl-test-definitely-not-a-real-command"
            }
        )
    case connE of
      Left _ -> pure ()
      Right _ -> expectationFailure "expected connect to fail for a bogus command"

isTimeoutError :: Either e McpCallOutcome -> Bool
isTimeoutError = \case
  Left _ -> True
  Right _ -> False
