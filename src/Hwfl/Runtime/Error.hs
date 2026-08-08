-- | Runtime / host errors distinct from pure 'EvalError'.
module Hwfl.Runtime.Error
  ( RuntimeError (..),
    renderRuntimeError,
    runtimeExitCode,
    isCatchable,
  )
where

import Data.Text (Text)
import Hwfl.Eval.Error (EvalError (..))

data RuntimeError
  = -- | Pure evaluator trap or unsupported construct reached at runtime.
    EvalErr EvalError
  | -- | Workspace sandbox rejection (absolute path, @..@ escape, symlink escape).
    SandboxErr Text
  | -- | Catchable host I/O failure (missing file, decode, write, …).
    HostErr Text
  | -- | LLM provider failure (auth, rate limit, timeout, …).
    ProviderErr Text
  | -- | CLI / configuration problem.
    ConfigErr Text
  | -- | Resume/approve refused because the project hash no longer matches
    -- the snapshot (CLI exit code 4 per spec §09).
    StaleProjectErr
  | -- | A synchronous exception escaped a runtime boundary (host op, provider,
    -- encoder, store). The step aborted at an unknown point.
    InternalErr Text
  deriving stock (Eq, Show)

renderRuntimeError :: RuntimeError -> Text
renderRuntimeError = \case
  EvalErr (Trap t) -> "trap: " <> t
  EvalErr (Unsupported t) -> "unsupported: " <> t
  SandboxErr t -> "sandbox: " <> t
  HostErr t -> "host: " <> t
  ProviderErr t -> "provider: " <> t
  ConfigErr t -> "config: " <> t
  StaleProjectErr -> "config: stale project: hash mismatch"
  InternalErr t -> "internal: " <> t

-- | Process exit code for a failed run (spec §09).
runtimeExitCode :: RuntimeError -> Int
runtimeExitCode = \case
  StaleProjectErr -> 4
  _ -> 1

-- | Host / provider / sandbox failures recoverable with @try@/@catch@ (spec §02 §8).
--
-- 'InternalErr' is not catchable: the transition it aborted may have applied
-- part of its effect, so author code must not resume on top of it.
isCatchable :: RuntimeError -> Bool
isCatchable = \case
  HostErr _ -> True
  ProviderErr _ -> True
  SandboxErr _ -> True
  _ -> False
