-- | Opt-in process spawn for @exec.run@ (spec §05 §3).
--
-- Only a bare basename in @project.json@ @exec.allow@ may run. The child
-- receives only env keys listed in @exec.env@. Wall-clock timeout and stream
-- caps come from the policy (with defaults). Non-zero exit is a value, not a
-- host error — agents can react to failing builds.
--
-- Output is capped while reading (never fully buffered then truncated). On
-- timeout the whole process group is signalled so grandchildren do not linger.
module Hwfl.Runtime.Exec
  ( ExecArgs (..),
    ExecOutcome (..),
    defaultExecTimeoutMs,
    defaultExecMaxOutputBytes,
    runExec,
  )
where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (IOException, SomeException, try)
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
import System.IO (Handle, hSetBinaryMode)
import System.Posix.Process (getProcessGroupIDOf)
import System.Posix.Signals (sigKILL, sigTERM, signalProcessGroup)
import System.Posix.Types (ProcessGroupID)
import System.Process (ProcessHandle, getPid)
import System.Process.Typed
  ( ProcessConfig,
    byteStringInput,
    createPipe,
    getStderr,
    getStdout,
    proc,
    setCreateGroup,
    setEnv,
    setStderr,
    setStdin,
    setStdout,
    setWorkingDir,
    unsafeProcessHandle,
    waitExitCode,
    withProcessTerm,
  )
import System.Timeout (timeout)

defaultExecTimeoutMs :: Int
defaultExecTimeoutMs = 120_000

defaultExecMaxOutputBytes :: Int
defaultExecMaxOutputBytes = 1_048_576

-- | Grace window between SIGTERM and SIGKILL of the process group.
groupKillGraceUs :: Int
groupKillGraceUs = 100_000

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
  | otherwise = case resolveLimits policy of
      Left err -> pure (Left err)
      Right (timeoutMs, cap) -> do
        childEnv <- currentEnvFor policy.execEnv
        let micros = timeoutMs * 1000
            cfg =
              setCreateGroup True
                . setStdin (byteStringInput (BSL.fromStrict (encodeUtf8 args.eaStdin)))
                . setStdout createPipe
                . setStderr createPipe
                . setWorkingDir (workspaceRoot ws)
                . setEnv [(T.unpack k, T.unpack v) | (k, v) <- childEnv]
                $ proc (T.unpack program) (map T.unpack args.eaArgs)
        result <-
          try (runCapped micros cap cfg) ::
            IO (Either IOException (Bool, ExitCode, BS.ByteString, BS.ByteString))
        pure $ case result of
          Left ex ->
            Left (HostErr ("exec spawn failed for '" <> program <> "': " <> T.pack (show ex)))
          Right (timedOut, ec, out, err) ->
            Right (mkOutcome timedOut ec out err)
  where
    program = args.eaProgram

    mkOutcome timedOut ec out err =
      ExecOutcome
        { eoExitCode = case ec of
            ExitSuccess -> 0
            ExitFailure n -> n,
          eoStdout = decodeUtf8With lenientDecode out,
          eoStderr = decodeUtf8With lenientDecode err,
          eoTimedOut = timedOut,
          eoStdoutBytes = BS.length out,
          eoStderrBytes = BS.length err
        }

resolveLimits :: ExecPolicy -> Either RuntimeError (Int, Int)
resolveLimits policy = do
  timeoutMs <- case policy.execTimeoutMs of
    Nothing -> Right defaultExecTimeoutMs
    Just n
      | n <= 0 -> Left (ConfigErr "exec.timeout_ms must be positive")
      | n > maxBound `div` 1000 -> Left (ConfigErr "exec.timeout_ms is too large")
      | otherwise -> Right n
  cap <- case policy.execMaxOutputBytes of
    Nothing -> Right defaultExecMaxOutputBytes
    Just n
      | n < 0 -> Left (ConfigErr "exec.max_output_bytes must be non-negative")
      | otherwise -> Right n
  pure (timeoutMs, cap)

-- | Spawn, stream-cap stdout/stderr, and on wall-clock timeout kill the process group.
-- Returns @(timedOut, exit, stdout, stderr)@.
runCapped ::
  Int ->
  Int ->
  ProcessConfig () Handle Handle ->
  IO (Bool, ExitCode, BS.ByteString, BS.ByteString)
runCapped micros cap cfg = withProcessTerm cfg $ \p -> do
  outVar <- newEmptyMVar
  errVar <- newEmptyMVar
  _ <- forkIO $ putMVar outVar =<< readCapped cap (getStdout p)
  _ <- forkIO $ putMVar errVar =<< readCapped cap (getStderr p)
  mEc <- timeout micros (waitExitCode p)
  case mEc of
    Just ec -> do
      out <- takeMVar outVar
      err <- takeMVar errVar
      pure (False, ec, out, err)
    Nothing -> do
      killProcessGroup (unsafeProcessHandle p)
      -- Reap after group kill so pipes close and readers finish.
      _ <-
        timeout groupKillGraceUs (waitExitCode p) >>= \case
          Just e -> pure e
          Nothing -> do
            killProcessGroup (unsafeProcessHandle p)
            timeout (groupKillGraceUs * 10) (waitExitCode p) >>= \case
              Just e -> pure e
              Nothing -> pure (ExitFailure 124)
      out <- takeMVar outVar
      err <- takeMVar errVar
      pure (True, ExitFailure 124, out, err)

-- | Read at most @cap@ bytes, then drain the remainder so the child is not
-- blocked on a full pipe. Never retains more than @cap@ bytes.
readCapped :: Int -> Handle -> IO BS.ByteString
readCapped cap h = do
  hSetBinaryMode h True
  if cap <= 0
    then drain h >> pure BS.empty
    else go 0 []
  where
    go n acc = do
      chunk <- BS.hGetSome h 8192
      if BS.null chunk
        then pure (BS.concat (reverse acc))
        else
          let need = cap - n
              (keep, _rest) = BS.splitAt need chunk
              n' = n + BS.length keep
              acc' = keep : acc
           in if n' >= cap
                then do
                  drain h
                  pure (BS.concat (reverse acc'))
                else go n' acc'

    drain handle = do
      r <- try (BS.hGetSome handle 8192) :: IO (Either IOException BS.ByteString)
      case r of
        Left _ -> pure ()
        Right chunk
          | BS.null chunk -> pure ()
          | otherwise -> drain handle

-- | SIGTERM the process group, then SIGKILL after a short grace. Best-effort:
-- missing pid / already-reaped groups are ignored.
killProcessGroup :: ProcessHandle -> IO ()
killProcessGroup ph = do
  mpid <- getPid ph
  case mpid of
    Nothing -> pure ()
    Just pid -> do
      mpgid <-
        try (getProcessGroupIDOf pid) :: IO (Either IOException ProcessGroupID)
      case mpgid of
        Left _ -> pure ()
        Right pgid -> do
          _ <- try (signalProcessGroup sigTERM pgid) :: IO (Either SomeException ())
          threadDelay groupKillGraceUs
          _ <- try (signalProcessGroup sigKILL pgid) :: IO (Either SomeException ())
          pure ()

currentEnvFor :: [Text] -> IO [(Text, Text)]
currentEnvFor names = do
  full <- getEnvironment
  let m = Map.fromList [(T.pack k, T.pack v) | (k, v) <- full]
  pure [(n, v) | n <- names, Just v <- [Map.lookup n m]]
