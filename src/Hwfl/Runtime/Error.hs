-- | Runtime / host errors distinct from pure 'EvalError'.
module Hwfl.Runtime.Error
  ( RuntimeError (..),
    renderRuntimeError,
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
  deriving stock (Eq, Show)

renderRuntimeError :: RuntimeError -> Text
renderRuntimeError = \case
  EvalErr (Trap t) -> "trap: " <> t
  EvalErr (Unsupported t) -> "unsupported: " <> t
  SandboxErr t -> "sandbox: " <> t
  HostErr t -> "host: " <> t
  ProviderErr t -> "provider: " <> t
  ConfigErr t -> "config: " <> t

-- | Host / provider / sandbox failures recoverable with @try@/@catch@ (spec §02 §8).
isCatchable :: RuntimeError -> Bool
isCatchable = \case
  HostErr _ -> True
  ProviderErr _ -> True
  SandboxErr _ -> True
  _ -> False
