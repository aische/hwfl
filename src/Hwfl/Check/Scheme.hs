-- | Type schemes for value / let-polymorphism (spec §03 §7).
module Hwfl.Check.Scheme
  ( Scheme (..),
    mono,
    quantify,
    schemeType,
    freeTVars,
    freeTVarsInScheme,
    substTVars,
    renameTVars,
  )
where

import Data.Set (Set)
import Data.Set qualified as Set
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Ast.Type (TypeExpr (..))
import Data.Maybe (fromMaybe)

-- | @∀ α…. τ@. Empty quantifier list is a monotype.
data Scheme = Scheme
  { schVars :: [Ident],
    schType :: TypeExpr
  }
  deriving stock (Eq, Show)

mono :: TypeExpr -> Scheme
mono = Scheme []

-- | Quantify the free type variables of a type (annotation-driven schemes).
quantify :: TypeExpr -> Scheme
quantify ty =
  let vs = Set.toList (freeTVars ty)
   in Scheme vs ty

schemeType :: Scheme -> TypeExpr
schemeType (Scheme _ t) = t

freeTVars :: TypeExpr -> Set Ident
freeTVars = \case
  TName {} -> Set.empty
  TVar n -> Set.singleton n
  TMeta {} -> Set.empty
  TList t -> freeTVars t
  TOption t -> freeTVars t
  TResult a b -> freeTVars a <> freeTVars b
  TSecret t -> freeTVars t
  TRecord fs -> foldMap (freeTVars . snd) fs
  TFun a b -> freeTVars a <> freeTVars b
  TEffFun a _ b -> freeTVars a <> freeTVars b

freeTVarsInScheme :: Scheme -> Set Ident
freeTVarsInScheme (Scheme qs ty) =
  freeTVars ty Set.\\ Set.fromList qs

-- | Replace type variables by name (used for instantiation renaming).
substTVars :: [(Ident, TypeExpr)] -> TypeExpr -> TypeExpr
substTVars sub = go
  where
    go = \case
      TVar n -> fromMaybe (TVar n) (lookup n sub)
      TList t -> TList (go t)
      TOption t -> TOption (go t)
      TResult a b -> TResult (go a) (go b)
      TSecret t -> TSecret (go t)
      TRecord fs -> TRecord [(f, go t) | (f, t) <- fs]
      TFun a b -> TFun (go a) (go b)
      TEffFun a es b -> TEffFun (go a) es (go b)
      t -> t

renameTVars :: [(Ident, Ident)] -> TypeExpr -> TypeExpr
renameTVars ren =
  substTVars [(a, TVar b) | (a, b) <- ren]
