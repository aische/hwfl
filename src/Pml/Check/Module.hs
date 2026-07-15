-- | Module-level checking: decls, @main@ vs frontmatter I/O.
module Pml.Check.Module
  ( checkModuleBody,
    checkLoadedModule,
    CheckResult (..),
  )
where

import Pml.Ast.Decl (Decl (..), ModuleBody (..))
import Pml.Ast.Expr (Param (..))
import Pml.Ast.Module (Frontmatter (..), LoadedModule (..))
import Pml.Ast.Name (Ident (..))
import Pml.Ast.Type (TypeExpr (..))
import Pml.Check.Env (TypeEnv, extendVars, lookupVar, resolveType, typeEq)
import Pml.Check.Error (CheckError (..))
import Pml.Check.Infer (check, infer, inferModuleEnv)

data CheckResult = CheckResult
  { crEnv :: TypeEnv
  }
  deriving stock (Eq, Show)

-- | Type-check a kernel module body (no frontmatter I/O rules).
checkModuleBody :: ModuleBody -> Either CheckError CheckResult
checkModuleBody body@(ModuleBody decls mexpr) = do
  env <- inferModuleEnv body
  mapM_ (checkDecl env) decls
  case mexpr of
    Nothing -> pure (CheckResult env)
    Just e -> do
      _ <- infer env e
      pure (CheckResult env)

checkDecl :: TypeEnv -> Decl -> Either CheckError ()
checkDecl env = \case
  DType {} -> pure ()
  DFun n ps _mt body -> case lookupVar n env of
    Nothing -> Left (UnboundVar n)
    Just (TFun domain ret) -> do
      binds <- bindParams ps domain
      check (extendVars binds env) body ret
    Just ty -> Left (ExpectedFunction ty)

bindParams :: [Param] -> TypeExpr -> Either CheckError [(Ident, TypeExpr)]
bindParams ps domain = case ps of
  [Param n _] -> Right [(n, domain)]
  _ -> case domain of
    TRecord fs
      | length ps == length fs ->
          Right $ zipWith (\(Param n _) (_, ty) -> (n, ty)) ps fs
    _ -> Left (ExpectedRecord domain)

-- | Check a loaded markdown module, including inputs/outputs vs @main@.
checkLoadedModule :: LoadedModule -> Either CheckError CheckResult
checkLoadedModule loaded = do
  let fm = lmFrontmatter loaded
      body0 = lmBody loaded
  body <- elaborateMainIO fm body0
  result <- checkModuleBody body
  checkMainIO fm body result.crEnv
  pure result

-- | Fill missing @main@ param/return types from frontmatter I/O records.
elaborateMainIO :: Frontmatter -> ModuleBody -> Either CheckError ModuleBody
elaborateMainIO fm body@(ModuleBody decls mexpr)
  | null fm.fmInputs && null fm.fmOutputs = Right body
  | otherwise = case break isMain decls of
      (_, []) -> Left MissingMain
      (before, DFun n ps mt b : after) -> do
        ps' <- fillParams ps
        let mt' = maybe (Just (TRecord fm.fmOutputs)) Just mt
        pure $ ModuleBody (before ++ DFun n ps' mt' b : after) mexpr
      _ -> Left MissingMain
  where
    isMain = \case
      DFun (Ident "main") _ _ _ -> True
      _ -> False
    fillParams = \case
      [Param n Nothing] ->
        Right [Param n (Just (TRecord fm.fmInputs))]
      [Param n (Just t)] -> Right [Param n (Just t)]
      [] ->
        if null fm.fmInputs
          then Right []
          else Left (ArityMismatch 1 0)
      ps -> Left (ArityMismatch 1 (length ps))

checkMainIO :: Frontmatter -> ModuleBody -> TypeEnv -> Either CheckError ()
checkMainIO fm (ModuleBody _decls _) env
  | null fm.fmInputs && null fm.fmOutputs = pure ()
  | otherwise = do
      inputsTy <- resolveType env (TRecord fm.fmInputs)
      outputsTy <- resolveType env (TRecord fm.fmOutputs)
      case lookupVar (Ident "main") env of
        Nothing -> Left MissingMain
        Just (TFun domain ret) -> do
          unlessEq' MainParamMismatch inputsTy domain
          unlessEq' MainReturnMismatch outputsTy ret
        Just ty -> Left (ExpectedFunction ty)

unlessEq' :: (TypeExpr -> TypeExpr -> CheckError) -> TypeExpr -> TypeExpr -> Either CheckError ()
unlessEq' mk want got =
  if typeEq want got
    then Right ()
    else Left (mk want got)
