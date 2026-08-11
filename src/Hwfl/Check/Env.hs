-- | Resolved type environments for checking.
module Hwfl.Check.Env
  ( TypeEnv (..),
    ModuleExport (..),
    emptyTypeEnv,
    lookupScheme,
    lookupVar,
    extendScheme,
    extendVar,
    extendVars,
    extendSchemes,
    lookupAlias,
    insertAlias,
    lookupImport,
    setImports,
    moduleExportRecord,
    resolveType,
    resolveTypeFrom,
    checkUniqueRecordFields,
    stripEffects,
    typeEq,
    freeEnvTVars,
    primitiveNames,
    isPrimitive,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Ast.Type (Effect, TypeExpr (..))
import Hwfl.Check.Error (CheckError (..))
import Hwfl.Check.Scheme (Scheme (..), freeTVarsInScheme, mono, schemeType)

data TypeEnv = TypeEnv
  { teVars :: Map Ident Scheme,
    teAliases :: Map TypeName TypeExpr,
    teImports :: Map Text ModuleExport
  }
  deriving stock (Eq, Show)

-- | Exported bindings from an imported module (qname key is slash text).
data ModuleExport = ModuleExport
  { meValues :: Map Ident Scheme,
    meEffects :: Map Ident (Set Effect),
    -- | Top-level @type@ aliases defined in this module (not re-exports).
    meTypes :: Map TypeName TypeExpr,
    -- | When the module is an entry module (has @inputs@/@outputs@), the
    -- resolved @(inputs, outputs)@ types enabling @qname(inputs)@ call syntax.
    meEntryIO :: Maybe (TypeExpr, TypeExpr)
  }
  deriving stock (Eq, Show)

emptyTypeEnv :: TypeEnv
emptyTypeEnv = TypeEnv Map.empty Map.empty Map.empty

lookupScheme :: Ident -> TypeEnv -> Maybe Scheme
lookupScheme n env = Map.lookup n env.teVars

-- | Binding type without instantiation (rigid / alias use). Prefer
-- 'Hwfl.Check.Unify.instantiate' at expression use sites.
lookupVar :: Ident -> TypeEnv -> Maybe TypeExpr
lookupVar n env = schemeType <$> lookupScheme n env

extendScheme :: Ident -> Scheme -> TypeEnv -> TypeEnv
extendScheme n sch env = env {teVars = Map.insert n sch env.teVars}

extendVar :: Ident -> TypeExpr -> TypeEnv -> TypeEnv
extendVar n t = extendScheme n (mono t)

extendVars :: [(Ident, TypeExpr)] -> TypeEnv -> TypeEnv
extendVars bs env = foldr (uncurry extendVar) env bs

extendSchemes :: [(Ident, Scheme)] -> TypeEnv -> TypeEnv
extendSchemes bs env = foldr (uncurry extendScheme) env bs

lookupAlias :: TypeName -> TypeEnv -> Maybe TypeExpr
lookupAlias n env = Map.lookup n env.teAliases

lookupImport :: Text -> TypeEnv -> Maybe ModuleExport
lookupImport q env = Map.lookup q env.teImports

setImports :: Map Text ModuleExport -> TypeEnv -> TypeEnv
setImports im env = env {teImports = im}

moduleExportRecord :: ModuleExport -> TypeExpr
moduleExportRecord ex =
  TRecord [(n, schemeType s) | (n, s) <- Map.toList ex.meValues]

-- | Free type variables in the monomorphic / skolem parts of the env
-- (excluding quantified vars of schemes).
freeEnvTVars :: TypeEnv -> Set Ident
freeEnvTVars env =
  foldMap freeTVarsInScheme (Map.elems env.teVars)

insertAlias :: TypeName -> TypeExpr -> TypeEnv -> Either CheckError TypeEnv
insertAlias n t env =
  if Map.member n env.teAliases
    then Left (DuplicateType n)
    else Right env {teAliases = Map.insert n t env.teAliases}

primitiveNames :: Set Text
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
      "ToolSpec",
      "Turn",
      "Error"
    ]

isPrimitive :: TypeName -> Bool
isPrimitive (TypeName n) = Set.member n primitiveNames

-- | Expand aliases (cycle-checked, memoized). Effect annotations on arrows are kept.
--
-- Memoization is required for DAG-shaped alias nests such as
-- @type A1 = {l: A0, r: A0}@ … @type A50 = {l: A49, r: A49}@, which otherwise
-- expand to an exponential number of nodes (M-8).
resolveType :: TypeEnv -> TypeExpr -> Either CheckError TypeExpr
resolveType env = resolveTypeFrom env []

-- | Like 'resolveType', but with an initial cycle-detection stack (used when
-- validating an alias definition so the defined name is already on the path).
resolveTypeFrom :: TypeEnv -> [TypeName] -> TypeExpr -> Either CheckError TypeExpr
resolveTypeFrom env stack0 ty0 = fst <$> go stack0 Map.empty ty0
  where
    go ::
      [TypeName] ->
      Map TypeName TypeExpr ->
      TypeExpr ->
      Either CheckError (TypeExpr, Map TypeName TypeExpr)
    go stack memo = \case
      TName n
        | isPrimitive n -> Right (TName n, memo)
        | Just cached <- Map.lookup n memo -> Right (cached, memo)
        | n `elem` stack -> Left (AliasCycle (reverse (n : stack)))
        | otherwise -> case lookupAlias n env of
            Nothing -> Left (UnboundType n)
            Just body -> do
              (resolved, memo') <- go (n : stack) memo body
              Right (resolved, Map.insert n resolved memo')
      TVar n -> Right (TVar n, memo)
      TMeta i -> Right (TMeta i, memo)
      TList t -> do
        (t', memo') <- go stack memo t
        Right (TList t', memo')
      TOption t -> do
        (t', memo') <- go stack memo t
        Right (TOption t', memo')
      TResult a b -> do
        (a', memo1) <- go stack memo a
        (b', memo2) <- go stack memo1 b
        Right (TResult a' b', memo2)
      TSecret t -> do
        (t', memo') <- go stack memo t
        Right (TSecret t', memo')
      TRecord fs -> do
        checkUniqueRecordFields (map fst fs)
        (fs', memo') <- goFields stack memo fs
        Right (TRecord fs', memo')
      TFun a b -> do
        (a', memo1) <- go stack memo a
        (b', memo2) <- go stack memo1 b
        Right (TFun a' b', memo2)
      TEffFun a es b -> do
        (a', memo1) <- go stack memo a
        (b', memo2) <- go stack memo1 b
        Right (TEffFun a' es b', memo2)

    goFields stack memo = \case
      [] -> Right ([], memo)
      (f, t) : rest -> do
        (t', memo1) <- go stack memo t
        (rest', memo2) <- goFields stack memo1 rest
        Right ((f, t') : rest', memo2)

-- | Reject duplicate field names in record types / literals (L-16).
checkUniqueRecordFields :: [Ident] -> Either CheckError ()
checkUniqueRecordFields = go Set.empty
  where
    go _ [] = Right ()
    go seen (n : rest)
      | n `Set.member` seen = Left (DuplicateField n)
      | otherwise = go (Set.insert n seen) rest

-- | Erase effect annotations (type equality ignores the lattice).
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
        && length fs == length (Map.fromList fs)
        && length gs == length (Map.fromList gs)
    eq (TFun x1 y1) (TFun x2 y2) = eq x1 x2 && eq y1 y2
    eq (TEffFun x1 _ y1) (TEffFun x2 _ y2) = eq x1 x2 && eq y1 y2
    eq (TEffFun x1 _ y1) (TFun x2 y2) = eq x1 x2 && eq y1 y2
    eq (TFun x1 y1) (TEffFun x2 _ y2) = eq x1 x2 && eq y1 y2
    eq (TVar x) (TVar y) = x == y
    eq (TMeta x) (TMeta y) = x == y
    eq x y = x == y
