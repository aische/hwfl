-- | Unification variables and substitution for polymorphic checking.
module Hwfl.Check.Unify
  ( UState (..),
    emptyUState,
    Tc,
    runTc,
    tcError,
    tcEither,
    freshMeta,
    zonk,
    unifyTypes,
    instantiate,
    generalize,
  )
where

import Control.Monad (when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State.Strict (StateT, evalStateT, get, modify, put)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Ast.Type (TypeExpr (..))
import Hwfl.Check.Env (TypeEnv, freeEnvTVars)
import Hwfl.Check.Error (CheckError (..))
import Hwfl.Check.Overload (pathCompatible)
import Hwfl.Check.Scheme (Scheme (..), freeTVars, substTVars)

data UState = UState
  { usNext :: Int,
    usSubst :: Map Int TypeExpr
  }
  deriving stock (Eq, Show)

emptyUState :: UState
emptyUState = UState 0 Map.empty

type Tc a = StateT UState (Either CheckError) a

runTc :: Tc a -> Either CheckError a
runTc m = evalStateT m emptyUState

tcError :: CheckError -> Tc a
tcError e = lift (Left e)

tcEither :: Either CheckError a -> Tc a
tcEither = lift

freshMeta :: Tc TypeExpr
freshMeta = do
  st <- get
  put st {usNext = st.usNext + 1}
  pure (TMeta st.usNext)

zonk :: TypeExpr -> Tc TypeExpr
zonk = \case
  TMeta i -> do
    st <- get
    case Map.lookup i st.usSubst of
      Nothing -> pure (TMeta i)
      Just t -> do
        t' <- zonk t
        -- path compression
        modify $ \s -> s {usSubst = Map.insert i t' s.usSubst}
        pure t'
  TList t -> TList <$> zonk t
  TOption t -> TOption <$> zonk t
  TResult a b -> TResult <$> zonk a <*> zonk b
  TSecret t -> TSecret <$> zonk t
  TRecord fs -> TRecord <$> traverse (\(f, t) -> (f,) <$> zonk t) fs
  TFun a b -> TFun <$> zonk a <*> zonk b
  TEffFun a es b -> TEffFun <$> zonk a <*> pure es <*> zonk b
  t -> pure t

instantiate :: Scheme -> Tc TypeExpr
instantiate (Scheme [] ty) = pure ty
instantiate (Scheme qs ty) = do
  sub <- traverse (\q -> (q,) <$> freshMeta) qs
  pure (substTVars sub ty)

-- | Generalize free type vars not free in the environment (value restriction
-- caller decides whether to call this).
generalize :: TypeEnv -> TypeExpr -> Tc Scheme
generalize env ty = do
  ty' <- zonk ty
  let envFree = freeEnvTVars env
      qs = Set.toList (freeTVars ty' Set.\\ envFree)
  pure (Scheme qs ty')

unifyTypes :: TypeExpr -> TypeExpr -> Tc ()
unifyTypes a0 b0 = do
  a <- zonk a0
  b <- zonk b0
  unify' a b

unify' :: TypeExpr -> TypeExpr -> Tc ()
unify' a b
  | pathCompatible a b = pure ()
  | otherwise = case (a, b) of
      (TMeta i, t) -> bindMeta i t
      (t, TMeta i) -> bindMeta i t
      (TVar x, TVar y) | x == y -> pure ()
      (TName x, TName y) | x == y -> pure ()
      (TList x, TList y) -> unify' x y
      (TOption x, TOption y) -> unify' x y
      (TResult x1 y1, TResult x2 y2) -> unify' x1 x2 >> unify' y1 y2
      (TSecret x, TSecret y) -> unify' x y
      (TFun x1 y1, TFun x2 y2) -> unify' x1 x2 >> unify' y1 y2
      (TEffFun x1 _ y1, TFun x2 y2) -> unify' x1 x2 >> unify' y1 y2
      (TFun x1 y1, TEffFun x2 _ y2) -> unify' x1 x2 >> unify' y1 y2
      (TEffFun x1 _ y1, TEffFun x2 _ y2) -> unify' x1 x2 >> unify' y1 y2
      (TRecord fs, TRecord gs) -> unifyRecords fs gs
      _ -> tcError (TypeMismatch a b)

unifyRecords :: [(Ident, TypeExpr)] -> [(Ident, TypeExpr)] -> Tc ()
unifyRecords fs gs
  | Map.keysSet fm /= Map.keysSet gm =
      tcError (TypeMismatch (TRecord fs) (TRecord gs))
  | length fs /= Map.size fm || length gs /= Map.size gm =
      tcError (TypeMismatch (TRecord fs) (TRecord gs))
  | otherwise =
      mapM_
        ( \(n, t) -> case Map.lookup n gm of
            Nothing -> tcError (MissingField n (TRecord gs))
            Just u -> unify' t u
        )
        fs
  where
    fm = Map.fromList fs
    gm = Map.fromList gs

bindMeta :: Int -> TypeExpr -> Tc ()
bindMeta i t = do
  t' <- zonk t
  case t' of
    TMeta j | i == j -> pure ()
    _ -> do
      when (occurs i t') $
        tcError (TypeMismatch (TMeta i) t')
      modify $ \s -> s {usSubst = Map.insert i t' s.usSubst}

occurs :: Int -> TypeExpr -> Bool
occurs i = \case
  TMeta j -> i == j
  TList t -> occurs i t
  TOption t -> occurs i t
  TResult a b -> occurs i a || occurs i b
  TSecret t -> occurs i t
  TRecord fs -> any (occurs i . snd) fs
  TFun a b -> occurs i a || occurs i b
  TEffFun a _ b -> occurs i a || occurs i b
  _ -> False
