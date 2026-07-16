-- | Opt-in process spawn for @exec.run@ (spec §05 §3).
--
-- Only a bare basename in @project.json@ @exec.allow@ may run. The child
-- receives only env keys listed in @exec.env@. Wall-clock timeout and stream
-- caps come from the policy (with defaults). Non-zero exit is a value, not a
-- host error — agents can react to failing builds.
module Hwfl.Runtime.Exec
  ( ExecArgs (..),
    ExecOutcome (..),
    defaultExecTimeoutMs,
    defaultExecMaxOutputBytes,
    runExec,
  )
where

import Control.Concurrent.STM (atomically)
import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Data.Text.Encoding.Error (lenientDecode)
import Hwfl.Project (ExecPolicy (..))
import Hwfl.Runtime.Error (RuntimeError (..))
import Hwfl.Runtime.Workspace (Workspace, workspaceRoot)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.Process.Typed
  ( byteStringInput,
    byteStringOutput,
    getStderr,
    getStdout,
    proc,
    setEnv,
    setStderr,
    setStdin,
    setStdout,
    setWorkingDir,
    waitExitCode,
    withProcessTerm,
  )
import System.Timeout (timeout)

defaultExecTimeoutMs :: Int
defaultExecTimeoutMs = 120_000

defaultExecMaxOutputBytes :: Int
defaultExecMaxOutputBytes = 1_048_576

data ExecArgs = ExecArgs
  { eaProgram :: Text,
    eaArgs :: [Text],
    eaStdin :: Text
  }
  deriving stock (Eq, Show)

data ExecOutcome = ExecOutcome
  { eoExitCode :: Int,
    eoStdout :: Text,
    eoStderr :: Text,
    eoTimedOut :: Bool,
    eoStdoutBytes :: Int,
    eoStderrBytes :: Int
  }
  deriving stock (Eq, Show)

-- | Run an allowlisted command. 'Left' only for policy / spawn failures;
-- timed-out and non-zero exits are 'Right' outcomes.
runExec :: Workspace -> ExecPolicy -> ExecArgs -> IO (Either RuntimeError ExecOutcome)
runExec ws policy args
  | T.any (== '/') program =
      pure
        ( Left
            ( SandboxErr
                ("exec 'program' must be a bare basename, not a path: '" <> program <> "'")
            )
        )
  | program `notElem` policy.execAllow =
      pure
        ( Left
            ( SandboxErr
                ( "program '"
                    <> program
                    <> "' is not allowed by project.json exec.allow"
                )
            )
        )
  | otherwise = do
      childEnv <- currentEnvFor policy.execEnv
      let micros = max 1 (effectiveTimeout * 1000)
          cfg =
            setStdin (byteStringInput (BSL.fromStrict (encodeUtf8 args.eaStdin)))
              . setStdout byteStringOutput
              . setStderr byteStringOutput
              . setWorkingDir (workspaceRoot ws)
              . setEnv [(T.unpack k, T.unpack v) | (k, v) <- childEnv]
              $ proc (T.unpack program) (map T.unpack args.eaArgs)
      result <-
        try (timeout micros (runIt cfg)) ::
          IO (Either IOException (Maybe (ExitCode, BSL.ByteString, BSL.ByteString)))
      pure $ case result of
        Left ex ->
          Left (HostErr ("exec spawn failed for '" <> program <> "': " <> T.pack (show ex)))
        Right Nothing -> Right timedOutcome
        Right (Just (ec, out, err)) -> Right (mkOutcome ec out err)
  where
    program = args.eaProgram
    cap = maybe defaultExecMaxOutputBytes id policy.execMaxOutputBytes
    effectiveTimeout = maybe defaultExecTimeoutMs id policy.execTimeoutMs

    runIt cfg = withProcessTerm cfg $ \p -> do
      ec <- waitExitCode p
      out <- atomically (getStdout p)
      err <- atomically (getStderr p)
      pure (ec, out, err)

    mkOutcome ec out err =
      let (outText, outBytes) = truncateStream cap out
          (errText, errBytes) = truncateStream cap err
       in ExecOutcome
            { eoExitCode = case ec of
                ExitSuccess -> 0
                ExitFailure n -> n,
              eoStdout = outText,
              eoStderr = errText,
              eoTimedOut = False,
              eoStdoutBytes = outBytes,
              eoStderrBytes = errBytes
            }

    timedOutcome =
      ExecOutcome
        { eoExitCode = 124,
          eoStdout = "",
          eoStderr = "",
          eoTimedOut = True,
          eoStdoutBytes = 0,
          eoStderrBytes = 0
        }

truncateStream :: Int -> BSL.ByteString -> (Text, Int)
truncateStream cap lbs =
  let bs = BS.take (max 0 cap) (BSL.toStrict lbs)
   in (decodeUtf8With lenientDecode bs, BS.length bs)

currentEnvFor :: [Text] -> IO [(Text, Text)]
currentEnvFor names = do
  full <- getEnvironment
  let m = Map.fromList [(T.pack k, T.pack v) | (k, v) <- full]
  pure [(n, v) | n <- names, Just v <- [Map.lookup n m]]
