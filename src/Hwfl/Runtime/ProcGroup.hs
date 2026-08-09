-- | Shared process-group teardown for spawned children (@exec.run@, MCP
-- stdio servers). SIGTERM then SIGKILL the whole group so grandchildren
-- (e.g. @npx@ spawning @node@) do not linger past the parent's exit.
module Hwfl.Runtime.ProcGroup
  ( killProcessGroup,
    groupKillGraceUs,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, SomeException, try)
import System.Posix.Process (getProcessGroupIDOf)
import System.Posix.Signals (sigKILL, sigTERM, signalProcessGroup)
import System.Posix.Types (ProcessGroupID)
import System.Process (ProcessHandle, getPid)

-- | Grace window between SIGTERM and SIGKILL of the process group.
groupKillGraceUs :: Int
groupKillGraceUs = 100_000

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
