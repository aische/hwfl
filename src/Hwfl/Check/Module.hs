-- | Module-level checking: decls, @main@ vs frontmatter I/O, effects ceiling.
module Hwfl.Check.Module
  ( checkModuleBody,
    checkLoadedModule,
    checkLoadedModuleInContext,
    CheckResult (..),
    ModuleCheckContext (..),
    emptyModuleCheckContext,
    elaborateMainIO,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.List (nub, (\\))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Hwfl.Ast.Decl (Decl (..), ModuleBody (..))
import Hwfl.Ast.Expr (Param (..))
import Hwfl.Ast.Module (ExampleInputs (..), Frontmatter (..), LoadedModule (..))
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Ast.Type (Effect (..), TypeExpr (..))
import Hwfl.Check.Effects (EffSet, analyzeModuleEffects, checkEffectsCeiling)
import Hwfl.Check.Env
  ( ModuleExport (..),
    TypeEnv,
    extendVars,
    lookupVar,
    resolveType,
    setImports,
    typeEq,
  )
import Hwfl.Check.Error (CheckError (..))
import Hwfl.Check.Infer (check, infer, inferModuleEnv)
import Hwfl.Project (EffectsPolicy (..), ProjectConfig (..))

data CheckResult = CheckResult
  { crEnv :: TypeEnv,
    crEffects :: Map Ident EffSet
  }
  deriving stock (Eq, Show)

newtype ModuleCheckContext = ModuleCheckContext
  { mccImports :: Map Text ModuleExport
  }
  deriving stock (Eq, Show)

emptyModuleCheckContext :: ModuleCheckContext
emptyModuleCheckContext = ModuleCheckContext Map.empty

-- | Type-check a kernel module body (no frontmatter I/O or effects ceiling).
checkModuleBody :: ModuleBody -> Either CheckError CheckResult
checkModuleBody = checkModuleBodyInContext emptyModuleCheckContext

checkModuleBodyInContext :: ModuleCheckContext -> ModuleBody -> Either CheckError CheckResult
checkModuleBodyInContext ctx body@(ModuleBody decls mexpr) = do
  env0 <- inferModuleEnv body
  let env = setImports ctx.mccImports env0
  mapM_ (checkDecl env) decls
  env' <- case mexpr of
    Nothing -> pure env
    Just e -> do
      _ <- infer env e
      pure env
  effEnv <- analyzeModuleEffects env' body
  pure CheckResult {crEnv = env', crEffects = effEnv}

checkDecl :: TypeEnv -> Decl -> Either CheckError ()
checkDecl env = \case
  DType {} -> pure ()
  DFun _ n ps _mt body -> case lookupVar n env of
    Nothing -> Left (UnboundVar n)
    Just (TFun domain ret) -> do
      binds <- bindParams ps domain
      check (extendVars binds env) body ret
    Just (TEffFun domain _ ret) -> do
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

-- | Check a loaded markdown module: types, I/O vs @main@, effects ceiling.
checkLoadedModule :: LoadedModule -> Either CheckError CheckResult
checkLoadedModule loaded = do
  let fm = lmFrontmatter loaded
      body0 = lmBody loaded
      ctx = ModuleCheckContext {mccImports = Map.empty}
  body <- elaborateMainIO fm body0
  result <- checkModuleBodyInContext ctx body
  checkMainIO fm body result.crEnv
  checkExamples fm
  let ceiling_ = Set.fromList (fromMaybe [] fm.fmEffects)
  checkEffectsCeiling ceiling_ True result.crEffects
  pure result

checkLoadedModuleInContext ::
  ProjectConfig ->
  Bool ->
  Map Text ModuleExport ->
  LoadedModule ->
  Either CheckError CheckResult
checkLoadedModuleInContext cfg execAllowed importExports loaded = do
  let fm = lmFrontmatter loaded
      body0 = lmBody loaded
      ctx = ModuleCheckContext {mccImports = importExports}
  body <- elaborateMainIO fm body0
  result <- checkModuleBodyInContext ctx body
  checkMainIO fm body result.crEnv
  checkExamples fm
  let ceiling_ = effectiveEffects cfg fm
  checkEffectsCeiling ceiling_ execAllowed result.crEffects
  pure result

-- | When @examples@ is present, each entry's input keys must match frontmatter
-- @inputs@ exactly (values remain untyped for now).
checkExamples :: Frontmatter -> Either CheckError ()
checkExamples fm = do
  checkDuplicateExampleNames fm.fmExamples
  mapM_ (checkExampleKeys (map fst fm.fmInputs)) fm.fmExamples

checkDuplicateExampleNames :: [ExampleInputs] -> Either CheckError ()
checkDuplicateExampleNames exs =
  case names \\ nub names of
    n : _ -> Left (ExampleDuplicateName n)
    [] -> pure ()
  where
    names = mapMaybe eiName exs

checkExampleKeys :: [Ident] -> ExampleInputs -> Either CheckError ()
checkExampleKeys declared ex =
  let declaredSet = Set.fromList declared
      exampleSet =
        Set.fromList
          [ Ident (K.toText k)
            | k <- KM.keys ex.eiInputs
          ]
      missing = Set.toAscList (declaredSet Set.\\ exampleSet)
      unknown = Set.toAscList (exampleSet Set.\\ declaredSet)
   in if null missing && null unknown
        then pure ()
        else Left (ExampleInputsMismatch ex.eiName missing unknown)

effectiveEffects :: ProjectConfig -> Frontmatter -> Set Effect
effectiveEffects cfg fm =
  let base = fromMaybe cfg.pcEffects.epDefault fm.fmEffects
      deny = Set.fromList cfg.pcEffects.epDeny
   in Set.fromList base Set.\\ deny

-- | Fill missing @main@ param/return types from frontmatter I/O records.
elaborateMainIO :: Frontmatter -> ModuleBody -> Either CheckError ModuleBody
elaborateMainIO fm body@(ModuleBody decls mexpr)
  | null fm.fmInputs && null fm.fmOutputs = Right body
  | otherwise = case break isMain decls of
      (_, []) -> Left MissingMain
      (before, DFun p n ps mt b : after) -> do
        ps' <- fillParams ps
        let mt' = mt <|> Just (TRecord fm.fmOutputs)
        pure $ ModuleBody (before ++ DFun p n ps' mt' b : after) mexpr
      _ -> Left MissingMain
  where
    isMain = \case
      DFun _ (Ident "main") _ _ _ -> True
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
        Just (TEffFun domain _ ret) -> do
          unlessEq' MainParamMismatch inputsTy domain
          unlessEq' MainReturnMismatch outputsTy ret
        Just ty -> Left (ExpectedFunction ty)

unlessEq' :: (TypeExpr -> TypeExpr -> CheckError) -> TypeExpr -> TypeExpr -> Either CheckError ()
unlessEq' mk want got =
  if typeEq want got
    then Right ()
    else Left (mk want got)
