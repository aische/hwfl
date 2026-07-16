-- | Patterns for @match@ (grammar Pattern).
module Hwfl.Ast.Pat
  ( Pattern (..),
    Literal (..),
  )
where

import Data.Text (Text)
import Hwfl.Ast.Name (Ident, TypeName)

-- | Shared literals used in expressions and patterns.
data Literal
  = LUnit
  | LBool Bool
  | LInt Integer
  | LFloat Double
  | LString Text
  deriving stock (Eq, Show, Read)

data Pattern
  = PWild
  | PVar Ident
  | PLit Literal
  | PTag TypeName (Maybe Pattern)
  | PRecord [(Ident, Pattern)]
  | PList [Pattern]
  deriving stock (Eq, Show, Read)
