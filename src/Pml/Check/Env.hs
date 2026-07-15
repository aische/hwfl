-- | Resolved type environments for checking.
module Pml.Check.Env
  ( TypeEnv (..),
    emptyTypeEnv,
    lookupVar,
    extendVar,
    extendVars,
    lookupAlias,
    insertAlias,
    resolveType,
    stripEffects,
    typeEq,
    primitiveNames,
    isPrimitive,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Pml.Ast.Name (Ident (..), TypeName (..))
import Pml.Ast.Type (TypeExpr (..))
import Pml.Check.Error (CheckError (..))

data TypeEnv = TypeEnv
  { teVars :: Map Ident TypeExpr,
    teAliases :: Map TypeName TypeExpr
  }
  deriving stock (Eq, Show)

emptyTypeEnv :: TypeEnv
emptyTypeEnv = TypeEnv Map.empty Map.empty

lookupVar :: Ident -> TypeEnv -> Maybe TypeExpr
lookupVar n env = Map.lookup n env.teVars

extendVar :: Ident -> TypeExpr -> TypeEnv -> TypeEnv
extendVar n t env = env {teVars = Map.insert n t env.teVars}

extendVars :: [(Ident, TypeExpr)] -> TypeEnv -> TypeEnv
extendVars bs env = foldr (uncurry extendVar) env bs

lookupAlias :: TypeName -> TypeEnv -> Maybe TypeExpr
lookupAlias n env = Map.lookup n env.teAliases

insertAlias :: TypeName -> TypeExpr -> TypeEnv -> Either CheckError TypeEnv
insertAlias n t env =
  if Map.member n env.teAliases
    then Left (DuplicateType n)
    else Right env {teAliases = Map.insert n t env.teAliases}

primitiveNames :: Set.Set Text
primitiveNames =
  Set.fromList
    [ "Unit",
      "Bool",
      "Int",
      "Float",
      "String",
      "Bytes",
      "Json",
      "FileRef",
      "Schema",
      "Error"
    ]

isPrimitive :: TypeName -> Bool
isPrimitive (TypeName n) = Set.member n primitiveNames

-- | Expand aliases (cycle-checked) and drop effect annotations on arrows.
resolveType :: TypeEnv -> TypeExpr -> Either CheckError TypeExpr
resolveType env = go []
  where
    go stack = \case
      TName n
        | isPrimitive n -> Right (TName n)
        | n `elem` stack -> Left (AliasCycle (reverse (n : stack)))
        | otherwise -> case lookupAlias n env of
            Nothing -> Left (UnboundType n)
            Just t -> go (n : stack) t
      TList t -> TList <$> go stack t
      TOption t -> TOption <$> go stack t
      TResult a b -> TResult <$> go stack a <*> go stack b
      TSecret t -> TSecret <$> go stack t
      TRecord fs -> TRecord <$> traverse (\(f, t) -> (f,) <$> go stack t) fs
      TFun a b -> TFun <$> go stack a <*> go stack b
      TEffFun a _ b -> TFun <$> go stack a <*> go stack b

-- | Erase effect annotations (effects are enforced in M3).
stripEffects :: TypeExpr -> TypeExpr
stripEffects = \case
  TList t -> TList (stripEffects t)
  TOption t -> TOption (stripEffects t)
  TResult a b -> TResult (stripEffects a) (stripEffects b)
  TSecret t -> TSecret (stripEffects t)
  TRecord fs -> TRecord [(f, stripEffects t) | (f, t) <- fs]
  TFun a b -> TFun (stripEffects a) (stripEffects b)
  TEffFun a _ b -> TFun (stripEffects a) (stripEffects b)
  t -> t

-- | Structural equality after stripping effects (records compared by field name).
typeEq :: TypeExpr -> TypeExpr -> Bool
typeEq a b = eq (stripEffects a) (stripEffects b)
  where
    eq (TList x) (TList y) = eq x y
    eq (TOption x) (TOption y) = eq x y
    eq (TResult x1 y1) (TResult x2 y2) = eq x1 x2 && eq y1 y2
    eq (TSecret x) (TSecret y) = eq x y
    eq (TRecord fs) (TRecord gs) =
      Map.keysSet (Map.fromList fs) == Map.keysSet (Map.fromList gs)
        && and
          [ eq t u
            | (n, t) <- fs,
              Just u <- [lookup n gs]
          ]
        && length fs == length (Map.fromList fs) -- reject dup keys asymmetrically
        && length gs == length (Map.fromList gs)
    eq (TFun x1 y1) (TFun x2 y2) = eq x1 x2 && eq y1 y2
    eq (TEffFun x1 _ y1) (TEffFun x2 _ y2) = eq x1 x2 && eq y1 y2
    eq (TEffFun x1 _ y1) (TFun x2 y2) = eq x1 x2 && eq y1 y2
    eq (TFun x1 y1) (TEffFun x2 _ y2) = eq x1 x2 && eq y1 y2
    eq x y = x == y
