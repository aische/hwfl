-- | Effect lattice inference and module-ceiling enforcement (spec §04).
module Hwfl.Check.Effects
  ( EffSet,
    emptyEffs,
    inferExprEffects,
    analyzeModuleEffects,
    checkEffectsCeiling,
  )
where

import Control.Monad (foldM, unless, when)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Hwfl.Ast.Decl (Decl (..), ModuleBody (..))
import Hwfl.Ast.Expr
import Hwfl.Ast.Name (Ident (..), qnameToText)
import Hwfl.Ast.Type (Effect (..), TypeExpr (..))
import Hwfl.Check.Env (ModuleExport (..), TypeEnv, lookupImport, resolveType)
import Hwfl.Check.Error (CheckError (..))
import Hwfl.Check.Infer (infer)
import Hwfl.Check.Overload (classifyOp)

type EffSet = Set Effect

type EffEnv = Map Ident EffSet

emptyEffs :: EffSet
emptyEffs = Set.empty

-- | Union of residual effects for each top-level @fun@ (fixpoint for mutual calls).
analyzeModuleEffects :: TypeEnv -> ModuleBody -> Either CheckError EffEnv
analyzeModuleEffects env (ModuleBody decls _) = go Map.empty
  where
    funs = [(n, body) | DFun _ n _ _ body <- decls]
    go effEnv = do
      effEnv' <-
        foldM
          ( \ee (n, body) -> do
              es <- inferExprEffects env ee body
              pure (Map.insert n es ee)
          )
          effEnv
          funs
      if effEnv' == effEnv
        then pure effEnv
        else go effEnv'

-- | Module effects ceiling (from frontmatter or project default) for every top-level fun.
checkEffectsCeiling :: Set Effect -> Bool -> EffEnv -> Either CheckError ()
checkEffectsCeiling ceilingSet execAllowed effEnv = do
  mapM_ checkOne (Map.toList effEnv)
  when (EffExec `Set.member` ceilingSet && not execAllowed) $
    Left ExecNotConfigured
  when (any (EffExec `Set.member`) (Map.elems effEnv) && not execAllowed) $
    Left ExecNotConfigured
  where
    checkOne (_n, inferred) =
      unless (inferred `Set.isSubsetOf` ceilingSet) $
        Left (EffectsNotAllowed inferred ceilingSet)

inferExprEffects :: TypeEnv -> EffEnv -> Expr -> Either CheckError EffSet
inferExprEffects env effEnv = go
  where
    go = \case
      ELit _ -> pure emptyEffs
      EVar _ -> pure emptyEffs
      EQName _ -> pure emptyEffs
      ESection _ -> pure emptyEffs
      EList es -> unions <$> traverse go es
      ERecord fs -> unions <$> traverse fieldEff fs
      EInterp parts -> unions <$> traverse partEff parts
      EApp f args -> do
        fEff <- go f
        aEff <- unions <$> traverse argEff args
        released <- effectsReleasedByApp env f args
        callees <- calleeResidual f
        pure (unions [fEff, aEff, released, callees])
      EProj e _ -> go e
      EIndex e ix -> unions <$> traverse go [e, ix]
      ELet n _ e1 e2 -> do
        e1e <- go e1
        e2e <- inferExprEffects env (Map.delete n effEnv) e2
        pure (e1e <> e2e)
      EFun ps _ body -> do
        let ns = [n | Param n _ <- ps]
            env' = foldr Map.delete effEnv ns
        inferExprEffects env env' body
      EIf c t e -> unions <$> traverse go [c, t, e]
      EMatch scrut arms -> do
        sEff <- go scrut
        aEff <- unions <$> traverse (\(MatchArm _ b) -> go b) arms
        pure (sEff <> aEff)
      EPar _opts n xs body -> do
        xsE <- go xs
        bodyE <- inferExprEffects env (Map.delete n effEnv) body
        pure (xsE <> bodyE <> Set.singleton EffParallel)
      EJoin es -> do
        esE <- unions <$> traverse go es
        pure (esE <> Set.singleton EffParallel)
      EConfirm e -> do
        eEff <- go e
        pure (eEff <> Set.singleton EffHuman)
      EChoice e -> do
        eEff <- go e
        pure (eEff <> Set.singleton EffHuman)
      ETry e1 _ e2 -> unions <$> traverse go [e1, e2]
      ESchema _ -> pure emptyEffs

    fieldEff = \case
      Field _ e -> go e
      FieldShorthand _ -> pure emptyEffs

    partEff = \case
      SLit _ -> pure emptyEffs
      SInterp e -> go e

    argEff = \case
      ArgPos e -> go e
      ArgNamed _ e -> go e

    calleeResidual = \case
      EVar n -> pure (Map.findWithDefault emptyEffs n effEnv)
      -- Entry module call: @qname(inputs)@ — union all effects of callee @main@.
      EQName q ->
        pure $
          maybe
            emptyEffs
            (\ex -> Map.findWithDefault emptyEffs (Ident "main") ex.meEffects)
            (lookupImport (qnameToText q) env)
      EProj (EQName q) n ->
        pure $
          maybe
            emptyEffs
            (\ex -> Map.findWithDefault emptyEffs n ex.meEffects)
            (lookupImport (qnameToText q) env)
      EProj e _ -> calleeResidual e
      _ -> pure emptyEffs

unions :: [EffSet] -> EffSet
unions = Set.unions

-- | Effects declared on arrows consumed by this application (host ops).
-- Overloaded pure operators have no principal type when bare; they release
-- no effects (same as any Pure prelude builtin).
effectsReleasedByApp :: TypeEnv -> Expr -> [Arg] -> Either CheckError EffSet
effectsReleasedByApp env f args = case f of
  EVar (Ident n)
    | Just _ <- classifyOp n -> pure emptyEffs
  _ -> do
    ft <- infer env f
    ft' <- resolveType env ft
    pure (peelEffects ft' (appCount args))

appCount :: [Arg] -> Int
appCount args
  | null args = 0
  | otherwise = 1

-- | Peel @n@ arrows, collecting effects from @TEffFun@.
peelEffects :: TypeExpr -> Int -> EffSet
peelEffects ty n
  | n <= 0 = emptyEffs
  | otherwise = case ty of
      TEffFun _ es ret -> Set.fromList es <> peelEffects ret (n - 1)
      TFun _ ret -> peelEffects ret (n - 1)
      _ -> emptyEffs
