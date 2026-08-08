-- | M-6: @exec.run@ stream caps, process-group timeout kill, and policy numerics.
module Hwfl.Runtime.ExecSpec (spec) where

import Control.Exception (IOException, try)
import Data.Text qualified as T
import Hwfl.Project (ExecPolicy (..), loadProjectConfig)
import Hwfl.Runtime.Error (RuntimeError (..))
import Hwfl.Runtime.Exec
  ( ExecArgs (..),
    ExecOutcome (..),
    runExec,
  )
import Hwfl.Runtime.Workspace (newWorkspace)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (nullSignal, signalProcess)
import System.Posix.Types (CPid (..))
import Test.Hspec

spec :: Spec
spec = describe "Hwfl.Runtime.Exec (M-6)" $ do
  describe "stream cap" $ do
    it "never returns more than max_output_bytes of stdout" $
      withSystemTempDirectory "hwfl-exec-cap" $ \dir -> do
        ws <- newWorkspace dir
        let policy = allowSh (Just 5_000) (Just 64)
            args =
              ExecArgs
                { eaProgram = "sh",
                  eaArgs =
                    [ "-c",
                      "dd if=/dev/zero bs=1024 count=50 2>/dev/null"
                    ],
                  eaStdin = ""
                }
        result <- runExec ws policy args
        case result of
          Left err -> expectationFailure (show err)
          Right out -> do
            out.eoTimedOut `shouldBe` False
            out.eoStdoutBytes `shouldSatisfy` (<= 64)
            T.length out.eoStdout `shouldSatisfy` (<= 64)

  describe "timeout + process group" $ do
    it "times out and kills grandchildren" $
      withSystemTempDirectory "hwfl-exec-timeout" $ \dir -> do
        ws <- newWorkspace dir
        let pidFile = dir </> "orphan.pid"
            policy = allowSh (Just 300) (Just 65_536)
            -- Background sleep keeps running unless the whole group is killed.
            script =
              T.concat
                [ "sleep 60 & echo $! > orphan.pid; ",
                  "sleep 60"
                ]
            args =
              ExecArgs
                { eaProgram = "sh",
                  eaArgs = ["-c", script],
                  eaStdin = ""
                }
        result <- runExec ws policy args
        case result of
          Left err -> expectationFailure (show err)
          Right out -> do
            out.eoTimedOut `shouldBe` True
            out.eoExitCode `shouldBe` 124
            doesFileExist pidFile `shouldReturn` True
            pidText <- readFile pidFile
            let pid = read (filter (/= '\n') pidText) :: Integer
            alive <- processAlive (CPid (fromIntegral pid))
            alive `shouldBe` False

    it "returns partial stdout captured before timeout" $
      withSystemTempDirectory "hwfl-exec-partial" $ \dir -> do
        ws <- newWorkspace dir
        let policy = allowSh (Just 400) (Just 65_536)
            args =
              ExecArgs
                { eaProgram = "sh",
                  eaArgs =
                    [ "-c",
                      "printf 'hello-before-sleep'; sleep 60"
                    ],
                  eaStdin = ""
                }
        result <- runExec ws policy args
        case result of
          Left err -> expectationFailure (show err)
          Right out -> do
            out.eoTimedOut `shouldBe` True
            out.eoStdout `shouldBe` "hello-before-sleep"

  describe "policy numerics" $ do
    it "rejects negative timeout_ms in project.json" $
      withSystemTempDirectory "hwfl-exec-bad-timeout" $ \dir -> do
        writeFile
          (dir </> "project.json")
          ( projectJson
              [ "\"allow\": [\"echo\"]",
                "\"timeout_ms\": -1",
                "\"max_output_bytes\": 1024"
              ]
          )
        loadProjectConfig dir
          >>= ( `shouldSatisfy`
                  \case
                    Left msg -> "timeout_ms" `T.isInfixOf` msg
                    Right _ -> False
              )

    it "rejects negative max_output_bytes in project.json" $
      withSystemTempDirectory "hwfl-exec-bad-max" $ \dir -> do
        writeFile
          (dir </> "project.json")
          ( projectJson
              [ "\"allow\": [\"echo\"]",
                "\"timeout_ms\": 1000",
                "\"max_output_bytes\": -5"
              ]
          )
        loadProjectConfig dir
          >>= ( `shouldSatisfy`
                  \case
                    Left msg -> "max_output_bytes" `T.isInfixOf` msg
                    Right _ -> False
              )

    it "rejects negative limits at runExec" $
      withSystemTempDirectory "hwfl-exec-runtime-limits" $ \dir -> do
        ws <- newWorkspace dir
        let policy =
              ExecPolicy
                { execAllow = ["echo"],
                  execEnv = ["PATH"],
                  execTimeoutMs = Just (-1),
                  execMaxOutputBytes = Just 100,
                  execConfirm = False
                }
            args =
              ExecArgs
                { eaProgram = "echo",
                  eaArgs = ["hi"],
                  eaStdin = ""
                }
        result <- runExec ws policy args
        result
          `shouldBe` Left (ConfigErr "exec.timeout_ms must be positive")

allowSh :: Maybe Int -> Maybe Int -> ExecPolicy
allowSh timeoutMs maxOut =
  ExecPolicy
    { execAllow = ["sh"],
      execEnv = ["PATH"],
      execTimeoutMs = timeoutMs,
      execMaxOutputBytes = maxOut,
      execConfirm = False
    }

projectJson :: [String] -> String
projectJson execFields =
  unlines
    [ "{",
      "  \"name\": \"exec-m6\",",
      "  \"version\": \"0.1.0\",",
      "  \"entrypoint\": \"workflows/main\",",
      "  \"exec\": {",
      "    " <> intercalateCsv execFields,
      "  }",
      "}"
    ]
  where
    intercalateCsv [] = ""
    intercalateCsv [x] = x
    intercalateCsv (x : xs) = x <> ",\n    " <> intercalateCsv xs

processAlive :: CPid -> IO Bool
processAlive pid = do
  r <- try (signalProcess nullSignal pid) :: IO (Either IOException ())
  pure (either (const False) (const True) r)
