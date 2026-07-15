-- | Surface type expressions and effect labels (spec §02, §04, grammar).
module Pml.Ast.Type
  ( Effect (..),
    TypeExpr (..),
    effectName,
    parseEffectName,
  )
where

import Data.Text (Text)
import Pml.Ast.Name (Ident, TypeName)

data Effect
  = EffRead
  | EffWrite
  | EffNet
  | EffExec
  | EffParallel
  | EffHuman
  | EffMeta
  deriving stock (Eq, Ord, Show, Read, Enum, Bounded)

effectName :: Effect -> Text
effectName = \case
  EffRead -> "Read"
  EffWrite -> "Write"
  EffNet -> "Net"
  EffExec -> "Exec"
  EffParallel -> "Parallel"
  EffHuman -> "Human"
  EffMeta -> "Meta"

parseEffectName :: Text -> Maybe Effect
parseEffectName = \case
  "Read" -> Just EffRead
  "Write" -> Just EffWrite
  "Net" -> Just EffNet
  "Exec" -> Just EffExec
  "Parallel" -> Just EffParallel
  "Human" -> Just EffHuman
  "Meta" -> Just EffMeta
  _ -> Nothing

data TypeExpr
  = TName TypeName
  | TList TypeExpr
  | TOption TypeExpr
  | TResult TypeExpr TypeExpr
  | TSecret TypeExpr
  | TRecord [(Ident, TypeExpr)]
  | TFun TypeExpr TypeExpr
  | TEffFun TypeExpr [Effect] TypeExpr
  deriving stock (Eq, Show, Read)
