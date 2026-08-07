-- | Synchronous-exception containment for the run loop and its boundaries.
--
-- hwfl is a library: a throw from a host op, a provider adapter or the store
-- must become a run failure, not a dead process. Everything that crosses such
-- a boundary goes through 'trySync' so the machine can be persisted as failed
-- and the caller gets a value back.
module Hwfl.Exception
  ( trySync,
    describeException,
  )
where

import Control.Exception
  ( AsyncException (..),
    SomeAsyncException,
    SomeException,
    displayException,
    evaluate,
    fromException,
    throwIO,
    try,
  )
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode)

-- | Run an action, returning synchronous exceptions as a value.
--
-- The result is forced to WHNF inside the barrier so a bottom in the returned
-- constructor is caught here rather than at the next pattern match. Thunks
-- nested inside the value still escape — call sites that persist or encode a
-- 'Hwfl.Eval.Value.Value' do that work inside their own barrier.
trySync :: IO a -> IO (Either SomeException a)
trySync act = do
  r <- try (act >>= evaluate)
  case r of
    Right a -> pure (Right a)
    Left e
      | isStopRequest e -> throwIO e
      | otherwise -> pure (Left e)

-- | Exceptions that must never become a run failure: something outside this
-- thread is asking it to stop, so containing them would ignore a Ctrl-C, a
-- cancelled worker, or 'System.Exit.exitWith'.
--
-- 'StackOverflow' is deliberately absent: deep author recursion is a program
-- error the run should report, and GHC has already unwound the stack by the
-- time the handler runs.
isStopRequest :: SomeException -> Bool
isStopRequest e =
  isJust (fromException e :: Maybe SomeAsyncException)
    || isJust (fromException e :: Maybe ExitCode)
    || case fromException e of
      Just ThreadKilled -> True
      Just UserInterrupt -> True
      Just HeapOverflow -> True
      Just StackOverflow -> False
      Nothing -> False

-- | One-line rendering for error messages and span attributes.
describeException :: SomeException -> Text
describeException e =
  let t = T.strip (T.unwords (map T.strip (T.lines (T.pack (displayException e)))))
   in if T.null t then T.pack (show e) else t
