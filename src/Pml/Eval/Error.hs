-- | Pure-evaluator traps and rejects (spec §02 §8).
module Pml.Eval.Error
  ( EvalError (..),
  )
where

import Data.Text (Text)

data EvalError
  = -- | Panic / invariant / missing case / type mismatch at runtime.
    Trap Text
  | -- | Pure subset reached a non-pure construct (par/join/confirm/try/section/host).
    Unsupported Text
  deriving stock (Eq, Show)
