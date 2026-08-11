-- | Bidirectional local type inference / checking for kernel expressions.
module Hwfl.Check.Infer
  ( infer,
    check,
    inferModuleEnv,
    inferModuleEnvFrom,
  )
where

import Control.Monad (foldM, unless, when)
import Data.Bifunctor (first)
import Data.Foldable (for_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Hwfl.Ast.Decl (Decl (..), ModuleBody (..))
import Hwfl.Ast.Expr
import Hwfl.Ast.Name (Ident (..), TypeName (..), qnameToText)
import Hwfl.Ast.Pat (Literal (..), Pattern (..))
import Hwfl.Ast.Type (TypeExpr (..))
import Hwfl.Check.Env
import Hwfl.Check.Error (CheckError (..), attachPos)
import Hwfl.Check.Overload (classifyOp, inferOverloadedApp)
import Hwfl.Check.Prelude (preludeTypeEnv)
import Hwfl.Check.Scheme (quantify)
import Hwfl.Check.Schema (schemaType, typeToSchema)
import Hwfl.Check.Unify
  ( Tc,
    freshMeta,
    runTc,
    tcError,
    tcEither,
    zonk,
    unifyTypes,
    instantiate,
    generalize,
  )

-- | Collect aliases + function types from decls (bodies checked separately).
inferModuleEnv :: ModuleBody -> Either CheckError TypeEnv
inferModuleEnv = inferModuleEnvFrom Map.empty

-- | Like 'inferModuleEnv', but seed aliases from imports first so local
-- decls / signatures may mention shared @types/*@ names.
inferModuleEnvFrom :: Map TypeName TypeExpr -> ModuleBody -> Either CheckError TypeEnv
inferModuleEnvFrom imported (ModuleBody decls _) = do
  checkDuplicateFuns decls
  envBase <- foldM addAlias preludeTypeEnv (Map.toList imported)
  env0 <- foldM addAlias envBase [(n, ty) | DType _ n ty <- decls]
  mapM_ (uncurry (resolveAliasDef env0)) [(n, ty) | DType _ n ty <- decls]
  foldM addFun env0 [(n, ps, mt) | DFun _ n ps mt _ <- decls]
  where
    addAlias env (n, ty) = insertAlias n ty env
    addFun env (n, ps, mt) = do
      funTy <- synthFunType env ps mt
      pure (extendScheme n (quantify funTy) env)

-- | Expand an alias RHS with the alias name already on the cycle stack.
resolveAliasDef :: TypeEnv -> TypeName -> TypeExpr -> Either CheckError TypeExpr
resolveAliasDef env root = resolveTypeFrom env [root]

checkDuplicateFuns :: [Decl] -> Either CheckError ()
checkDuplicateFuns decls = mapM_ one names
  where
    names = [n | DFun _ n _ _ _ <- decls]
    one n =
      when (length (filter (== n) names) > 1) $
        Left (DuplicateFun n)

synthFunType :: TypeEnv -> [Param] -> Maybe TypeExpr -> Either CheckError TypeExpr
synthFunType env ps mt = do
  ret <- case mt of
    Just ty -> resolveType env ty
    Nothing -> Left (CannotInfer "function return type")
  domain <- paramsDomain env ps
  pure (TFun domain ret)

paramsDomain :: TypeEnv -> [Param] -> Either CheckError TypeExpr
paramsDomain env = \case
  [] -> Right tUnit
  [Param _ (Just ty)] -> resolveType env ty
  -- A lone bare parameter is a Unit thunk. Runtime binds it to VUnit for f().
  [Param _ Nothing] -> Right tUnit
  ps -> do
    fs <- traverse paramField ps
    checkUniqueRecordFields (map fst fs)
    pure (TRecord fs)
  where
    paramField (Param n mty) = case mty of
      Just ty -> (n,) <$> resolveType env ty
      Nothing -> Left (CannotInfer ("parameter " <> unIdent n))

infer :: TypeEnv -> Expr -> Either CheckError TypeExpr
infer env e =
  first (attachPos (exprPos e)) $
    runTc $ do
      t <- inferTc env e
      zonk t

inferTc :: TypeEnv -> Expr -> Tc TypeExpr
inferTc env = \case
  ELit lit -> pure (literalType lit)
  EVar n@(Ident name)
    | Just _ <- classifyOp name ->
        tcError (CannotInfer ("overloaded operator " <> name <> " must be applied"))
    | otherwise -> case lookupScheme n env of
        Nothing -> tcError (UnboundVar n)
        Just sch -> do
          ty <- instantiate sch
          tcEither (resolveType env ty)
  -- An imported entry module is callable as @qname(inputs)@; bare reference
  -- resolves to the callable type @TFun inputs outputs@.  Non-entry imports
  -- resolve to their record of exported values (library / type-module access).
  EQName q -> case lookupImport (qnameToText q) env of
    Nothing -> tcError (UnboundModule (qnameToText q))
    Just ex -> case ex.meEntryIO of
      Just (inputsTy, outputsTy) -> tcEither (resolveType env (TFun inputsTy outputsTy))
      Nothing -> tcEither (resolveType env (moduleExportRecord ex))
  ESection _ -> pure tString
  EList [] -> tcError (CannotInfer "empty list; add a type annotation")
  EList (e : es) -> do
    te <- inferTc env e
    mapM_ (\x -> checkTc env x te) es
    pure (TList te)
  ERecord fs -> do
    tcEither (checkUniqueRecordFields (map fieldName fs))
    typed <- traverse (inferField env) fs
    pure (TRecord typed)
  EInterp parts -> do
    mapM_ (checkInterpPart env) parts
    pure tString
  EApp f args
    | isToolBuiltin f -> tcEither (inferToolApp env args)
    | isListLength f -> tcEither (inferListLengthApp env args)
    | isListConcat f -> tcEither (inferListConcatApp env args)
    | isJsonEncode f -> tcEither (inferJsonEncodeApp env args)
    | isLlmObject f -> tcEither (inferLlmObjectApp env args)
    | isLlmAgent f -> tcEither (inferLlmAgentApp env args)
    | isLlmAgentObject f -> tcEither (inferLlmAgentObjectApp env args)
    | isObsSpan f -> tcEither (inferObsSpanApp env args)
    | isObsSpanPartial f -> tcEither (inferObsSpanThunkApp env args)
    | isObsLog f -> tcEither (inferObsLogApp env args)
    | isMetaInvoke f -> tcEither (inferMetaInvokeApp env args)
    | isMetaReadSpans f -> tcEither (inferMetaReadSpansApp env args)
    | isFsCopy f -> tcEither (inferFsCopyApp env args)
    | isMcpCall f -> tcEither (inferMcpCallApp env args)
    | isMcpTools f -> tcEither (inferMcpToolsApp env args)
    | isHumanConfirm f -> tcEither (inferHumanConfirmApp env args)
    | isHumanChoice f -> tcEither (inferHumanChoiceApp env args)
    | isHumanAsk f -> tcEither (inferHumanAskApp env args)
    | EVar (Ident n) <- f,
      Just cls <- classifyOp n ->
        tcEither (inferOverloadedApp env cls infer args)
    | otherwise -> do
        ft <- inferTc env f
        applyType env ft args
  EProj e f -> do
    te <- inferTc env e
    te' <- tcEither (resolveType env te)
    case te' of
      TRecord fs ->
        case lookup f fs of
          Nothing -> tcError (MissingField f te')
          Just ty -> instantiate (quantify ty) >>= \t -> tcEither (resolveType env t)
      _ -> tcError (ExpectedRecord te')
  EIndex e ix -> do
    te <- inferTc env e
    checkTc env ix tInt
    te' <- tcEither (resolveType env te)
    case te' of
      TList el -> pure el
      _ -> tcError (ExpectedList te')
  ELet n mt e1 e2 -> do
    case (mt, e1) of
      (_, EVar v) | Nothing <- mt ->
        case lookupScheme v env of
          Just sch -> inferTc (extendScheme n sch env) e2
          Nothing -> tcError (UnboundVar v)
      (Just ann, _) -> do
        want <- tcEither (resolveType env ann)
        checkTc env e1 want
        let sch = quantify want
        inferTc (extendScheme n sch env) e2
      (Nothing, EFun {}) -> do
        t1 <- inferTc env e1
        sch <- generalize env t1
        inferTc (extendScheme n sch env) e2
      (Nothing, _) -> do
        t1 <- inferTc env e1
        t1' <- zonk t1
        inferTc (extendVar n t1' env) e2
  EFun ps mt body -> do
    domain <- tcEither (paramsDomain env ps)
    binds <- paramBindings env ps domain
    ret <- case mt of
      Just ann -> do
        want <- tcEither (resolveType env ann)
        checkTc (extendVars binds env) body want
        pure want
      Nothing -> inferTc (extendVars binds env) body
    pure (TFun domain ret)
  EIf c t e -> do
    checkTc env c tBool
    tt <- inferTc env t
    checkTc env e tt
    pure tt
  EMatch scrut arms -> inferMatch env scrut arms
  EPar _opts n xs body -> do
    te <- inferTc env xs
    te' <- tcEither (resolveType env te)
    case te' of
      TList el -> do
        bt <- inferTc (extendVar n el env) body
        pure (TList bt)
      _ -> tcError (ExpectedList te')
  EJoin es -> case es of
    [] -> tcError (CannotInfer "empty join")
    (e : rest) -> do
      t0 <- inferTc env e
      mapM_ (\x -> checkTc env x t0) rest
      pure (TList t0)
  EConfirm e -> do
    tcEither (checkConfirmArg env e)
    pure tBool
  EChoice e -> do
    tcEither (checkChoiceArg env e)
    pure tString
  ETry body errVar handler -> do
    tBody <- inferTc env body
    checkTc (extendVar errVar tString env) handler tBody
    pure tBody
  ESchema te -> do
    _ <- tcEither (typeToSchema env te)
    pure schemaType
  ETag (TypeName "None") Nothing ->
    tcError (CannotInfer "None (annotate as Option<_>)")
  ETag (TypeName "None") (Just _) ->
    tcError (TypeMismatchMsg "None takes no payload" (TOption tUnit) tUnit)
  ETag (TypeName "Some") (Just payload) ->
    TOption <$> inferTc env payload
  ETag (TypeName "Some") Nothing ->
    tcError (CannotInfer "Some requires a payload")
  ETag (TypeName "Ok") (Just payload) -> do
    a <- inferTc env payload
    TResult a <$> freshMeta
  ETag (TypeName "Ok") Nothing ->
    tcError (CannotInfer "Ok requires a payload")
  ETag (TypeName "Err") (Just payload) -> do
    e <- inferTc env payload
    a <- freshMeta
    pure (TResult a e)
  ETag (TypeName "Err") Nothing ->
    tcError (CannotInfer "Err requires a payload")
  ETag (TypeName n) _ ->
    tcError (CannotInfer ("unknown tag constructor: " <> n))

check :: TypeEnv -> Expr -> TypeExpr -> Either CheckError ()
check env e want = first (attachPos (exprPos e)) (runTc (checkTc env e want))

checkTc :: TypeEnv -> Expr -> TypeExpr -> Tc ()
checkTc env e want = do
  want' <- tcEither (resolveType env want)
  case e of
    EList [] -> case want' of
      TList _ -> pure ()
      _ -> tcError (TypeMismatch want' (TList tUnit))
    EList es -> case want' of
      TList el -> mapM_ (\x -> checkTc env x el) es
      _ -> do
        got <- inferTc env e
        unifyTypes want' got
    ETag (TypeName "None") Nothing -> case want' of
      TOption _ -> pure ()
      _ -> tcError (TypeMismatch want' (TOption tUnit))
    ETag (TypeName "None") (Just _) ->
      tcError (TypeMismatchMsg "None takes no payload" want' tUnit)
    ETag (TypeName "Some") (Just payload) -> case want' of
      TOption inner -> checkTc env payload inner
      _ -> tcError (TypeMismatch want' (TOption tUnit))
    ETag (TypeName "Some") Nothing ->
      tcError (TypeMismatchMsg "Some requires a payload" want' tUnit)
    ETag (TypeName "Ok") (Just payload) -> case want' of
      TResult a _ -> checkTc env payload a
      _ -> tcError (TypeMismatch want' (TResult tUnit tUnit))
    ETag (TypeName "Ok") Nothing ->
      tcError (TypeMismatchMsg "Ok requires a payload" want' tUnit)
    ETag (TypeName "Err") (Just payload) -> case want' of
      TResult _ _e -> checkTc env payload _e
      _ -> tcError (TypeMismatch want' (TResult tUnit tUnit))
    ETag (TypeName "Err") Nothing ->
      tcError (TypeMismatchMsg "Err requires a payload" want' tUnit)
    ETag (TypeName n) _ ->
      tcError (CannotInfer ("unknown tag constructor: " <> n))
    EFun ps mt body -> case want' of
      TFun domain ret -> do
        binds <- paramBindings env ps domain
        case mt of
          Just ann -> unifyAnn env ret ann
          Nothing -> pure ()
        checkTc (extendVars binds env) body ret
      _ -> do
        got <- inferTc env e
        unifyTypes want' got
    EIf c t f -> do
      checkTc env c tBool
      checkTc env t want'
      checkTc env f want'
    ELet n mt e1 e2 -> do
      env' <- case (mt, e1) of
        (_, EVar v) | Nothing <- mt ->
          case lookupScheme v env of
            Just sch -> pure (extendScheme n sch env)
            Nothing -> tcError (UnboundVar v)
        (Just ann, _) -> do
          a <- tcEither (resolveType env ann)
          checkTc env e1 a
          pure (extendScheme n (quantify a) env)
        (Nothing, EFun _ _ _) -> do
          t1 <- inferTc env e1
          sch <- generalize env t1
          pure (extendScheme n sch env)
        (Nothing, _) -> do
          t1 <- inferTc env e1
          t1' <- zonk t1
          pure (extendVar n t1' env)
      checkTc env' e2 want'
    EMatch scrut arms -> checkMatch env scrut arms want'
    EPar _opts n xs body -> case want' of
      TList el -> do
        te <- inferTc env xs
        te' <- tcEither (resolveType env te)
        case te' of
          TList elemTy -> checkTc (extendVar n elemTy env) body el
          _ -> tcError (ExpectedList te')
      _ -> do
        got <- inferTc env e
        unifyTypes want' got
    EConfirm arg -> do
      unifyTypes want' tBool
      tcEither (checkConfirmArg env arg)
    EChoice arg -> do
      unifyTypes want' tString
      tcEither (checkChoiceArg env arg)
    EJoin es -> case want' of
      TList el -> mapM_ (\x -> checkTc env x el) es
      _ -> do
        got <- inferTc env e
        unifyTypes want' got
    ETry body errVar handler -> do
      tBody <- inferTc env body
      checkTc (extendVar errVar tString env) handler tBody
      unifyTypes want' tBody
    _ -> do
      got <- inferTc env e
      unifyTypes want' got

inferMatch :: TypeEnv -> Expr -> [MatchArm] -> Tc TypeExpr
inferMatch env scrut arms = case arms of
  [] -> tcError (CannotInfer "empty match")
  MatchArm p body : rest -> do
    st <- inferTc env scrut
    binds <- patternBindings env p st
    t0 <- inferTc (extendVars binds env) body
    mapM_
      ( \(MatchArm p' b') -> do
          bs <- patternBindings env p' st
          checkTc (extendVars bs env) b' t0
      )
      rest
    pure t0

checkMatch :: TypeEnv -> Expr -> [MatchArm] -> TypeExpr -> Tc ()
checkMatch env scrut arms want = case arms of
  [] -> tcError (CannotInfer "empty match")
  _ -> do
    st <- inferTc env scrut
    mapM_
      ( \(MatchArm p body) -> do
          binds <- patternBindings env p st
          checkTc (extendVars binds env) body want
      )
      arms

patternBindings :: TypeEnv -> Pattern -> TypeExpr -> Tc [(Ident, TypeExpr)]
patternBindings env p ty = do
  ty' <- tcEither (resolveType env ty)
  go p ty'
  where
    go pat expected = case pat of
      PWild -> pure []
      PVar n -> pure [(n, expected)]
      PLit lit -> do
        unifyTypes expected (literalType lit)
        pure []
      PList ps -> case expected of
        TList el -> concat <$> traverse (`go` el) ps
        _ -> tcError (ExpectedList expected)
      PRecord pfs -> do
        tcEither (checkUniqueRecordFields (map fst pfs))
        case expected of
          TRecord fs -> concat <$> traverse (fieldBind fs) pfs
          _ -> tcError (ExpectedRecord expected)
      PTag (TypeName "None") Nothing -> case expected of
        TOption _ -> pure []
        _ -> tcError (TypeMismatchMsg "None pattern" (TOption tUnit) expected)
      PTag (TypeName "None") (Just _) ->
        tcError (TypeMismatchMsg "None pattern takes no payload" (TOption tUnit) expected)
      PTag (TypeName "Some") (Just p') -> case expected of
        TOption inner -> go p' inner
        _ -> tcError (TypeMismatchMsg "Some pattern" (TOption tUnit) expected)
      PTag (TypeName "Some") Nothing -> case expected of
        TOption _ -> pure []
        _ -> tcError (TypeMismatchMsg "Some pattern" (TOption tUnit) expected)
      PTag (TypeName "Ok") (Just p') -> case expected of
        TResult a _ -> go p' a
        _ -> tcError (TypeMismatchMsg "Ok pattern" (TResult tUnit tUnit) expected)
      PTag (TypeName "Ok") Nothing -> case expected of
        TResult _ _ -> pure []
        _ -> tcError (TypeMismatchMsg "Ok pattern" (TResult tUnit tUnit) expected)
      PTag (TypeName "Err") (Just p') -> case expected of
        TResult _ e -> go p' e
        _ -> tcError (TypeMismatchMsg "Err pattern" (TResult tUnit tUnit) expected)
      PTag (TypeName "Err") Nothing -> case expected of
        TResult _ _ -> pure []
        _ -> tcError (TypeMismatchMsg "Err pattern" (TResult tUnit tUnit) expected)
      PTag _ mp -> case mp of
        Nothing -> pure []
        Just p' -> go p' expected
    fieldBind fs (n, p') = case lookup n fs of
      Nothing -> tcError (MissingField n (TRecord fs))
      Just ft -> go p' ft

inferField :: TypeEnv -> Field -> Tc (Ident, TypeExpr)
inferField env = \case
  Field n e -> (n,) <$> inferTc env e
  FieldShorthand n ->
    case lookupScheme n env of
      Nothing -> tcError (UnboundVar n)
      Just sch -> do
        ty <- instantiate sch
        t <- tcEither (resolveType env ty)
        pure (n, t)

fieldName :: Field -> Ident
fieldName = \case
  Field n _ -> n
  FieldShorthand n -> n

checkInterpPart :: TypeEnv -> StringPart -> Tc ()
checkInterpPart env = \case
  SLit _ -> pure ()
  SInterp e -> do
    ty <- inferTc env e
    ty' <- tcEither (resolveType env ty)
    unless (isRenderable ty') $ tcError (NotRenderable ty')

isRenderable :: TypeExpr -> Bool
isRenderable = \case
  TName (TypeName n) ->
    n `elem` ["Unit", "Bool", "Int", "Float", "String", "FileRef", "Json"]
  TList ty -> isRenderable ty
  TOption ty -> isRenderable ty
  TResult a b -> isRenderable a && isRenderable b
  TRecord fs -> all (isRenderable . snd) fs
  TSecret {} -> False
  TFun {} -> False
  TEffFun {} -> False
  TVar {} -> False
  TMeta {} -> False

applyType :: TypeEnv -> TypeExpr -> [Arg] -> Tc TypeExpr
applyType env fty args = do
  fty' <- tcEither (resolveType env fty)
  case classifyArgs args of
    Left err -> tcError err
    Right (Positional es) -> applyPositional env fty' es
    Right (Named nes) -> applyNamed env fty' nes

data ArgClass
  = Positional [Expr]
  | Named [(Ident, Expr)]

classifyArgs :: [Arg] -> Either CheckError ArgClass
classifyArgs args
  | null args = Right (Positional [])
  | all isPos args = Right (Positional [e | ArgPos e <- args])
  | all isNamed args = Right (Named [(n, e) | ArgNamed n e <- args])
  | otherwise = Left MixedArgs
  where
    isPos = \case
      ArgPos _ -> True
      _ -> False
    isNamed = \case
      ArgNamed _ _ -> True
      _ -> False

applyPositional :: TypeEnv -> TypeExpr -> [Expr] -> Tc TypeExpr
applyPositional env initialTy [] = case funArrow initialTy of
  -- @f()@ on @Unit -> T@ is a full call (empty arg list means unit).
  Just (domain, ret) -> do
    domain' <- tcEither (resolveType env domain)
    unifyTypes domain' tUnit
    pure ret
  Nothing -> tcError (ExpectedFunction initialTy)
applyPositional env initialTy providedArgs = go initialTy providedArgs
  where
    go currentTy remainingArgs = case funArrow currentTy of
      Just (TRecord fields, ret)
        | length remainingArgs == length fields && not (null remainingArgs) -> do
            mapM_
              ( \(arg, (_, domain)) -> checkTc env arg domain
              )
              (zip remainingArgs fields)
            pure ret
      Just (domain, ret)
        | (arg : rest) <- remainingArgs -> do
            checkTc env arg domain
            case rest of
              [] -> pure ret
              _ -> go ret rest
      _ -> tcError (ExpectedFunction currentTy)

applyNamed :: TypeEnv -> TypeExpr -> [(Ident, Expr)] -> Tc TypeExpr
applyNamed env fty nes = case funArrow fty of
  Just (TRecord fields, ret) -> do
    mapM_ (checkNamed fields) nes
    let given = map fst nes
        expected = map fst fields
    when (length given /= length expected) $
      tcError (ArityMismatch (length expected) (length given))
    mapM_ (\n -> unless (n `elem` given) $ tcError (MissingNamedArg n)) expected
    pure ret
  Just (domain, _) ->
    tcError (TypeMismatchMsg "named arguments require a record parameter" (TRecord []) domain)
  Nothing -> tcError (ExpectedFunction fty)
  where
    checkNamed fields (n, e) = case lookup n fields of
      Nothing -> tcError (UnknownField n (TRecord fields))
      Just ty -> checkTc env e ty

-- | View @TFun@ / @TEffFun@ as a single arrow (effects ignored for typing).
funArrow :: TypeExpr -> Maybe (TypeExpr, TypeExpr)
funArrow = \case
  TFun a b -> Just (a, b)
  TEffFun a _ b -> Just (a, b)
  _ -> Nothing

paramBindings :: TypeEnv -> [Param] -> TypeExpr -> Tc [(Ident, TypeExpr)]
paramBindings env ps domain = do
  domain' <- tcEither (resolveType env domain)
  case ps of
    [] -> do
      unifyTypes domain' tUnit
      pure []
    [Param n mty] -> do
      case mty of
        Just ann -> unifyAnn env domain' ann
        Nothing -> pure ()
      domainZ <- zonk domain'
      pure [(n, domainZ)]
    _ -> case domain' of
      TRecord fs ->
        if length ps /= length fs
          then tcError (ArityMismatch (length fs) (length ps))
          else do
            let positional =
                  zipWith
                    (\(Param n _) (_, ty) -> (n, ty))
                    ps
                    fs
            namedResults <- traverse (bindNamedOptional fs) ps
            case sequence namedResults of
              Just bs -> traverse zonkBind bs
              Nothing -> traverse zonkBind positional
      _ -> tcError (ExpectedRecord domain')
  where
    zonkBind (n, ty) = (n,) <$> zonk ty
    bindNamedOptional fs (Param n mty) = case lookup n fs of
      Just ty -> do
        case mty of
          Just ann -> unifyAnn env ty ann
          Nothing -> pure ()
        pure (Just (n, ty))
      Nothing -> pure Nothing

-- | Match a parameter/return annotation against an expected type. Free type
-- variables in the annotation are instantiated so @fun (x: a): a => x@ can
-- check against @Int -> Int@.
unifyAnn :: TypeEnv -> TypeExpr -> TypeExpr -> Tc ()
unifyAnn env expected ann = do
  ann' <- tcEither (resolveType env ann)
  annFlex <- instantiate (quantify ann')
  unifyTypes expected annFlex

literalType :: Literal -> TypeExpr
literalType = \case
  LUnit -> tUnit
  LBool _ -> tBool
  LInt _ -> tInt
  LFloat _ -> tFloat
  LString _ -> tString

-- | @tool(f)@: accept any function / effectful function, produce ToolSpec.
isToolBuiltin :: Expr -> Bool
isToolBuiltin = \case
  EVar (Ident "tool") -> True
  _ -> False

inferToolApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferToolApp env args = case args of
  [ArgPos e] -> do
    te <- infer env e
    te' <- resolveType env te
    case te' of
      TFun {} -> Right tToolSpec
      TEffFun {} -> Right tToolSpec
      _ -> Left (ExpectedFunction te')
  _ -> Left (ArityMismatch 1 (length args))

isListLength :: Expr -> Bool
isListLength = \case
  EProj (EVar (Ident "list")) (Ident "length") -> True
  _ -> False

isListConcat :: Expr -> Bool
isListConcat = \case
  EProj (EVar (Ident "list")) (Ident "concat") -> True
  _ -> False

inferListLengthApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferListLengthApp env args = case classifyArgs args of
  Left err -> Left err
  Right (Positional [e]) -> do
    te <- infer env e
    te' <- resolveType env te
    case te' of
      TList _ -> Right tInt
      _ -> Left (ExpectedList te')
  Right (Named [(Ident "xs", e)]) -> do
    te <- infer env e
    te' <- resolveType env te
    case te' of
      TList _ -> Right tInt
      _ -> Left (ExpectedList te')
  _ -> Left (ArityMismatch 1 (length args))

inferListConcatApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferListConcatApp env args = case classifyArgs args of
  Left err -> Left err
  Right (Positional [a, b]) -> do
    ta <- infer env a
    ta' <- resolveType env ta
    case ta' of
      TList _ -> do
        check env b ta'
        pure ta'
      _ -> Left (ExpectedList ta')
  Right (Named nes) -> do
    a <- maybe (Left (MissingNamedArg (Ident "left"))) pure (lookup (Ident "left") nes)
    b <- maybe (Left (MissingNamedArg (Ident "right"))) pure (lookup (Ident "right") nes)
    inferListConcatApp env [ArgPos a, ArgPos b]
  _ -> Left (ArityMismatch 2 (length args))

isJsonEncode :: Expr -> Bool
isJsonEncode = \case
  EProj (EVar (Ident "json")) (Ident "encode") -> True
  _ -> False

inferJsonEncodeApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferJsonEncodeApp env args = case classifyArgs args of
  Left err -> Left err
  Right (Positional [e]) -> do
    ty <- infer env e
    ty' <- resolveType env ty
    unless (isRenderable ty') $
      Left (TypeMismatchMsg "json.encode requires a JSON-encodable value" ty' tString)
    pure tString
  _ -> Left (ArityMismatch 1 (length args))

-- | @llm.object(..., schema = schema(T), ...)@ returns @T@ (E14); otherwise Json.
isLlmObject :: Expr -> Bool
isLlmObject = \case
  EProj (EVar (Ident "llm")) (Ident "object") -> True
  _ -> False

inferLlmObjectApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferLlmObjectApp env args = do
  ft <- infer env (EProj (EVar (Ident "llm")) (Ident "object"))
  ret <- runTc (applyType env ft args)
  case schemaArgExpr args of
    Just (ESchema te) -> resolveType env te
    _ -> pure ret

-- | @llm.agent({ …, history?: List<Turn>, … })@ ⇒ @{ text, rounds, history }@.
isLlmAgent :: Expr -> Bool
isLlmAgent = \case
  EProj (EVar (Ident "llm")) (Ident "agent") -> True
  _ -> False

agentResultType :: TypeExpr
agentResultType =
  TRecord
    [ (Ident "text", tString),
      (Ident "rounds", tInt),
      (Ident "history", TList tTurn)
    ]

agentObjectResultType :: TypeExpr -> TypeExpr
agentObjectResultType out =
  TRecord
    [ (Ident "value", out),
      (Ident "rounds", tInt),
      (Ident "history", TList tTurn)
    ]

inferLlmAgentApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferLlmAgentApp env args = case classifyArgs args of
  Left err -> Left err
  Right (Named nes) -> do
    systemE <- maybe (Left (MissingNamedArg (Ident "system"))) pure (lookup (Ident "system") nes)
    promptE <- maybe (Left (MissingNamedArg (Ident "prompt"))) pure (lookup (Ident "prompt") nes)
    toolsE <- maybe (Left (MissingNamedArg (Ident "tools"))) pure (lookup (Ident "tools") nes)
    modelE <- maybe (Left (MissingNamedArg (Ident "model"))) pure (lookup (Ident "model") nes)
    check env systemE tString
    check env promptE tString
    check env toolsE (TList tToolSpec)
    check env modelE tString
    case lookup (Ident "max_rounds") nes of
      Nothing -> pure ()
      Just e -> check env e tInt
    case lookup (Ident "history") nes of
      Nothing -> pure ()
      Just e -> check env e (TList tTurn)
    case lookup (Ident "context_window") nes of
      Nothing -> pure ()
      Just e -> check env e tInt
    case lookup (Ident "max_tool_result_chars") nes of
      Nothing -> pure ()
      Just e -> check env e tInt
    case lookup (Ident "consolidate") nes of
      Nothing -> pure ()
      Just e -> check env e tString
    case lookup (Ident "max_pins") nes of
      Nothing -> pure ()
      Just e -> check env e tInt
    case lookup (Ident "max_summary_chars") nes of
      Nothing -> pure ()
      Just e -> check env e tInt
    let known =
          [ Ident "system",
            Ident "prompt",
            Ident "tools",
            Ident "model",
            Ident "max_rounds",
            Ident "history",
            Ident "context_window",
            Ident "max_tool_result_chars",
            Ident "consolidate",
            Ident "max_pins",
            Ident "max_summary_chars"
          ]
    mapM_
      ( \(n, _) ->
          unless (n `elem` known) $
            Left (UnknownField n (TRecord [(Ident "system", tString)]))
      )
      nes
    pure agentResultType
  Right (Positional _) ->
    Left (TypeMismatchMsg "llm.agent requires named arguments" (TRecord []) (TRecord []))

-- | @llm.agent_object(..., schema = schema(T), ...)@ ⇒ @{ value: T, rounds: Int, history }@.
isLlmAgentObject :: Expr -> Bool
isLlmAgentObject = \case
  EProj (EVar (Ident "llm")) (Ident "agent_object") -> True
  _ -> False

inferLlmAgentObjectApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferLlmAgentObjectApp env args = do
  case classifyArgs args of
    Left err -> Left err
    Right (Named nes) -> do
      systemE <- maybe (Left (MissingNamedArg (Ident "system"))) pure (lookup (Ident "system") nes)
      promptE <- maybe (Left (MissingNamedArg (Ident "prompt"))) pure (lookup (Ident "prompt") nes)
      toolsE <- maybe (Left (MissingNamedArg (Ident "tools"))) pure (lookup (Ident "tools") nes)
      schemaE <- maybe (Left (MissingNamedArg (Ident "schema"))) pure (lookup (Ident "schema") nes)
      modelE <- maybe (Left (MissingNamedArg (Ident "model"))) pure (lookup (Ident "model") nes)
      check env systemE tString
      check env promptE tString
      check env toolsE (TList tToolSpec)
      check env schemaE tSchema
      check env modelE tString
      case lookup (Ident "max_rounds") nes of
        Nothing -> pure ()
        Just e -> check env e tInt
      case lookup (Ident "history") nes of
        Nothing -> pure ()
        Just e -> check env e (TList tTurn)
      case lookup (Ident "context_window") nes of
        Nothing -> pure ()
        Just e -> check env e tInt
      case lookup (Ident "max_tool_result_chars") nes of
        Nothing -> pure ()
        Just e -> check env e tInt
      case lookup (Ident "consolidate") nes of
        Nothing -> pure ()
        Just e -> check env e tString
      case lookup (Ident "max_pins") nes of
        Nothing -> pure ()
        Just e -> check env e tInt
      case lookup (Ident "max_summary_chars") nes of
        Nothing -> pure ()
        Just e -> check env e tInt
      let known =
            [ Ident "system",
              Ident "prompt",
              Ident "tools",
              Ident "schema",
              Ident "model",
              Ident "max_rounds",
              Ident "history",
              Ident "context_window",
              Ident "max_tool_result_chars",
              Ident "consolidate",
              Ident "max_pins",
              Ident "max_summary_chars"
            ]
      mapM_
        ( \(n, _) ->
            unless (n `elem` known) $
              Left (UnknownField n (TRecord [(Ident "system", tString)]))
        )
        nes
      case schemaArgExpr args of
        Just (ESchema te) -> do
          out <- resolveType env te
          pure (agentObjectResultType out)
        _ -> pure (agentObjectResultType tJson)
    Right (Positional _) ->
      Left (TypeMismatchMsg "llm.agent_object requires named arguments" (TRecord []) (TRecord []))

schemaArgExpr :: [Arg] -> Maybe Expr
schemaArgExpr as = case classifyArgs as of
  Right (Named nes) -> lookup (Ident "schema") nes
  _ -> Nothing

-- | @obs.span@: @(name, fun () -> a) -> a@ (E16). Prelude stub is Unit→Unit;
-- Infer peels the thunk result (effects of @a@ still flow via Effects on the body).
isObsSpan :: Expr -> Bool
isObsSpan = \case
  EProj (EVar (Ident "obs")) (Ident "span") -> True
  _ -> False

-- | Curried second application: @obs.span(name)(thunk)@.
isObsSpanPartial :: Expr -> Bool
isObsSpanPartial = \case
  EApp f _ -> isObsSpan f
  _ -> False

inferObsSpanApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferObsSpanApp env args = case classifyArgs args of
  Left err -> Left err
  Right (Positional [nameE, bodyE]) -> do
    check env nameE tString
    inferObsSpanThunk env bodyE
  Right (Positional [nameE]) -> do
    -- Partial application keeps the prelude stub until the thunk is applied.
    check env nameE tString
    ft <- infer env (EProj (EVar (Ident "obs")) (Ident "span"))
    runTc (applyType env ft [ArgPos nameE])
  Right (Named nes) -> do
    nameE <- maybe (Left (MissingNamedArg (Ident "name"))) pure (lookup (Ident "name") nes)
    bodyE <- maybe (Left (MissingNamedArg (Ident "body"))) pure (lookup (Ident "body") nes)
    check env nameE tString
    inferObsSpanThunk env bodyE
  _ -> Left (ArityMismatch 2 (length args))

inferObsSpanThunkApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferObsSpanThunkApp env args = case classifyArgs args of
  Left err -> Left err
  Right (Positional [bodyE]) -> inferObsSpanThunk env bodyE
  Right (Named [(Ident "body", bodyE)]) -> inferObsSpanThunk env bodyE
  _ -> Left (ArityMismatch 1 (length args))

inferObsSpanThunk :: TypeEnv -> Expr -> Either CheckError TypeExpr
inferObsSpanThunk env bodyE = do
  te <- infer env bodyE
  te' <- resolveType env te
  case funArrow te' of
    Just (domain, ret) -> do
      runTc (unifyTypes domain tUnit)
      pure ret
    Nothing -> Left (ExpectedFunction te')

-- | @obs.log(level, message, fields?)@ — @fields@ may be any record or Json.
isObsLog :: Expr -> Bool
isObsLog = \case
  EProj (EVar (Ident "obs")) (Ident "log") -> True
  _ -> False

checkJsonish :: TypeEnv -> Expr -> Either CheckError ()
checkJsonish env e = do
  te <- infer env e
  te' <- resolveType env te
  case te' of
    TRecord _ -> pure ()
    TName (TypeName "Json") -> pure ()
    _ ->
      Left
        ( TypeMismatchMsg
            "obs.log fields must be a record or Json"
            tJson
            te'
        )

inferObsLogApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferObsLogApp env args = case classifyArgs args of
  Left err -> Left err
  Right (Positional [levelE, messageE]) -> do
    check env levelE tString
    check env messageE tString
    pure tUnit
  Right (Positional [levelE, messageE, fieldsE]) -> do
    check env levelE tString
    check env messageE tString
    checkJsonish env fieldsE
    pure tUnit
  Right (Named nes) -> do
    levelE <- maybe (Left (MissingNamedArg (Ident "level"))) pure (lookup (Ident "level") nes)
    messageE <- maybe (Left (MissingNamedArg (Ident "message"))) pure (lookup (Ident "message") nes)
    check env levelE tString
    check env messageE tString
    for_ (lookup (Ident "fields") nes) (checkJsonish env)
    let known = [Ident "level", Ident "message", Ident "fields"]
    mapM_
      ( \(n, _) ->
          unless (n `elem` known) $
            Left (UnknownField n (TRecord [(Ident "level", tString), (Ident "message", tString)]))
      )
      nes
    pure tUnit
  _ -> Left (ArityMismatch 2 (length args))

-- | @meta.invoke({ project, workspace, inputs? })@ — @inputs@ may be any record
-- (prelude stub uses Json which would reject concrete records).
isMetaInvoke :: Expr -> Bool
isMetaInvoke = \case
  EProj (EVar (Ident "meta")) (Ident "invoke") -> True
  _ -> False

metaInvokeResultType :: TypeExpr
metaInvokeResultType =
  TRecord
    [ (Ident "ok", tBool),
      (Ident "run_id", tString),
      (Ident "status", tString),
      (Ident "outcome", tJson),
      (Ident "error", tString)
    ]

inferMetaInvokeApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferMetaInvokeApp env args = case classifyArgs args of
  Left err -> Left err
  Right (Named nes) -> do
    projectE <-
      maybe (Left (MissingNamedArg (Ident "project"))) pure (lookup (Ident "project") nes)
    workspaceE <-
      maybe (Left (MissingNamedArg (Ident "workspace"))) pure (lookup (Ident "workspace") nes)
    check env projectE tFileRef
    check env workspaceE tFileRef
    case lookup (Ident "inputs") nes of
      Nothing -> pure ()
      Just inputsE -> do
        te <- infer env inputsE
        te' <- resolveType env te
        case te' of
          TRecord _ -> pure ()
          TName (TypeName "Json") -> pure ()
          _ ->
            Left
              ( TypeMismatchMsg
                  "meta.invoke inputs must be a record or Json"
                  (TRecord [])
                  te'
              )
    let known = [Ident "project", Ident "workspace", Ident "inputs"]
    mapM_
      ( \(n, _) ->
          unless (n `elem` known) $
            Left (UnknownField n (TRecord [(Ident "project", tFileRef)]))
      )
      nes
    pure metaInvokeResultType
  Right (Positional _) ->
    Left (TypeMismatchMsg "meta.invoke requires named arguments" (TRecord []) (TRecord []))

-- | @meta.read_spans({ run_id, workspace, name_prefix?, kind?, limit? })@.
isMetaReadSpans :: Expr -> Bool
isMetaReadSpans = \case
  EProj (EVar (Ident "meta")) (Ident "read_spans") -> True
  _ -> False

metaReadSpansResultType :: TypeExpr
metaReadSpansResultType =
  TRecord
    [ (Ident "ok", tBool),
      ( Ident "spans",
        TList
          ( TRecord
              [ (Ident "op", tString),
                (Ident "id", tString),
                (Ident "parent_id", tString),
                (Ident "name", tString),
                (Ident "kind", tString),
                (Ident "t_start", tString),
                (Ident "t_end", tString),
                (Ident "status", tString),
                (Ident "attrs", tJson),
                (Ident "snapshot_seq", tInt)
              ]
          )
      ),
      (Ident "error", tString)
    ]

inferMetaReadSpansApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferMetaReadSpansApp env args = case classifyArgs args of
  Left err -> Left err
  Right (Named nes) -> do
    runIdE <-
      maybe (Left (MissingNamedArg (Ident "run_id"))) pure (lookup (Ident "run_id") nes)
    workspaceE <-
      maybe (Left (MissingNamedArg (Ident "workspace"))) pure (lookup (Ident "workspace") nes)
    check env runIdE tString
    check env workspaceE tFileRef
    case lookup (Ident "name_prefix") nes of
      Nothing -> pure ()
      Just e -> check env e tString
    case lookup (Ident "kind") nes of
      Nothing -> pure ()
      Just e -> check env e tString
    case lookup (Ident "limit") nes of
      Nothing -> pure ()
      Just e -> check env e tInt
    let known =
          [ Ident "run_id",
            Ident "workspace",
            Ident "name_prefix",
            Ident "kind",
            Ident "limit"
          ]
    mapM_
      ( \(n, _) ->
          unless (n `elem` known) $
            Left (UnknownField n (TRecord [(Ident "run_id", tString)]))
      )
      nes
    pure metaReadSpansResultType
  Right (Positional _) ->
    Left (TypeMismatchMsg "meta.read_spans requires named arguments" (TRecord []) (TRecord []))

-- | @fs.copy({ src, dst, overwrite?, exclude? })@.
isFsCopy :: Expr -> Bool
isFsCopy = \case
  EProj (EVar (Ident "fs")) (Ident "copy") -> True
  _ -> False

inferFsCopyApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferFsCopyApp env args = case classifyArgs args of
  Left err -> Left err
  Right (Named nes) -> do
    srcE <- maybe (Left (MissingNamedArg (Ident "src"))) pure (lookup (Ident "src") nes)
    dstE <- maybe (Left (MissingNamedArg (Ident "dst"))) pure (lookup (Ident "dst") nes)
    check env srcE tFileRef
    check env dstE tFileRef
    case lookup (Ident "overwrite") nes of
      Nothing -> pure ()
      Just e -> check env e tBool
    case lookup (Ident "exclude") nes of
      Nothing -> pure ()
      Just e -> check env e (TList tString)
    let known = [Ident "src", Ident "dst", Ident "overwrite", Ident "exclude"]
    mapM_
      ( \(n, _) ->
          unless (n `elem` known) $
            Left (UnknownField n (TRecord [(Ident "src", tFileRef)]))
      )
      nes
    pure tUnit
  Right (Positional _) ->
    Left (TypeMismatchMsg "fs.copy requires named arguments" (TRecord []) (TRecord []))

-- | @mcp.call({ server, name, arguments, schema? })@ — @schema = schema(T)@
-- returns @T@ (E14 pattern, spec §13 §4.1); otherwise @Json@.
isMcpCall :: Expr -> Bool
isMcpCall = \case
  EProj (EVar (Ident "mcp")) (Ident "call") -> True
  _ -> False

inferMcpCallApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferMcpCallApp env args = case classifyArgs args of
  Left err -> Left err
  Right (Named nes) -> do
    serverE <- maybe (Left (MissingNamedArg (Ident "server"))) pure (lookup (Ident "server") nes)
    nameE <- maybe (Left (MissingNamedArg (Ident "name"))) pure (lookup (Ident "name") nes)
    argsE <- maybe (Left (MissingNamedArg (Ident "arguments"))) pure (lookup (Ident "arguments") nes)
    check env serverE tString
    check env nameE tString
    checkJsonish env argsE
    let known = [Ident "server", Ident "name", Ident "arguments", Ident "schema"]
    mapM_
      ( \(n, _) ->
          unless (n `elem` known) $
            Left (UnknownField n (TRecord [(Ident "server", tString)]))
      )
      nes
    case schemaArgExpr args of
      Just (ESchema te) -> resolveType env te
      _ -> pure tJson
  Right (Positional xs) -> Left (ArityMismatch 1 (length xs))

-- | @mcp.tools({ server, names?, bind? })@ ⇒ @List<ToolSpec>@ (spec §13 §4.2).
isMcpTools :: Expr -> Bool
isMcpTools = \case
  EProj (EVar (Ident "mcp")) (Ident "tools") -> True
  _ -> False

inferMcpToolsApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferMcpToolsApp env args = case classifyArgs args of
  Left err -> Left err
  Right (Named nes) -> do
    serverE <- maybe (Left (MissingNamedArg (Ident "server"))) pure (lookup (Ident "server") nes)
    check env serverE tString
    case lookup (Ident "names") nes of
      Nothing -> pure ()
      Just e -> check env e (TList tString)
    case lookup (Ident "bind") nes of
      Nothing -> pure ()
      Just e -> checkJsonish env e
    let known = [Ident "server", Ident "names", Ident "bind"]
    mapM_
      ( \(n, _) ->
          unless (n `elem` known) $
            Left (UnknownField n (TRecord [(Ident "server", tString)]))
      )
      nes
    pure (TList tToolSpec)
  Right (Positional xs) -> Left (ArityMismatch 1 (length xs))

-- | @human.confirm({ title, detail? })@ or positional record; sugar @confirm@.
isHumanConfirm :: Expr -> Bool
isHumanConfirm = \case
  EProj (EVar (Ident "human")) (Ident "confirm") -> True
  _ -> False

inferHumanConfirmApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferHumanConfirmApp env args = case classifyArgs args of
  Left err -> Left err
  Right (Named nes) -> checkConfirmFields env nes
  Right (Positional [recordExpr]) -> do
    checkConfirmArg env recordExpr
    pure tBool
  Right (Positional xs) -> Left (ArityMismatch 1 (length xs))

checkConfirmArg :: TypeEnv -> Expr -> Either CheckError ()
checkConfirmArg env e = do
  ty <- infer env e >>= resolveType env
  case ty of
    TRecord fields -> do
      _ <- checkConfirmFieldTypes fields
      pure ()
    _ -> Left (ExpectedRecord ty)

checkConfirmFields :: TypeEnv -> [(Ident, Expr)] -> Either CheckError TypeExpr
checkConfirmFields env fields = do
  titleE <- maybe (Left (MissingNamedArg (Ident "title"))) pure (lookup (Ident "title") fields)
  check env titleE tString
  case lookup (Ident "detail") fields of
    Nothing -> pure ()
    Just detailE -> check env detailE tString
  rejectUnknownConfirm (map fst fields)
  pure tBool

checkConfirmFieldTypes :: [(Ident, TypeExpr)] -> Either CheckError TypeExpr
checkConfirmFieldTypes fields = do
  titleTy <-
    maybe (Left (MissingField (Ident "title") (TRecord fields))) pure (lookup (Ident "title") fields)
  runTc (unifyTypes tString titleTy)
  for_ (lookup (Ident "detail") fields) (runTc . unifyTypes tString)
  rejectUnknownConfirm (map fst fields)
  pure tBool

rejectUnknownConfirm :: [Ident] -> Either CheckError ()
rejectUnknownConfirm =
  mapM_
    ( \n ->
        unless (n `elem` [Ident "title", Ident "detail"]) $
          Left (UnknownField n (TRecord [(Ident "title", tString)]))
    )

-- | @human.choice({ title, options, detail? })@ or positional record; sugar @choice@.
isHumanChoice :: Expr -> Bool
isHumanChoice = \case
  EProj (EVar (Ident "human")) (Ident "choice") -> True
  _ -> False

inferHumanChoiceApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferHumanChoiceApp env args = case classifyArgs args of
  Left err -> Left err
  Right (Named nes) -> checkChoiceFields env nes
  Right (Positional [recordExpr]) -> do
    checkChoiceArg env recordExpr
    pure tString
  Right (Positional xs) -> Left (ArityMismatch 1 (length xs))

checkChoiceArg :: TypeEnv -> Expr -> Either CheckError ()
checkChoiceArg env e = do
  ty <- infer env e >>= resolveType env
  case ty of
    TRecord fields -> do
      _ <- checkChoiceFieldTypes fields
      pure ()
    _ -> Left (ExpectedRecord ty)

checkChoiceFields :: TypeEnv -> [(Ident, Expr)] -> Either CheckError TypeExpr
checkChoiceFields env fields = do
  titleE <- maybe (Left (MissingNamedArg (Ident "title"))) pure (lookup (Ident "title") fields)
  optionsE <- maybe (Left (MissingNamedArg (Ident "options"))) pure (lookup (Ident "options") fields)
  check env titleE tString
  check env optionsE (TList tString)
  case lookup (Ident "detail") fields of
    Nothing -> pure ()
    Just detailE -> check env detailE tString
  rejectUnknownChoice (map fst fields)
  pure tString

checkChoiceFieldTypes :: [(Ident, TypeExpr)] -> Either CheckError TypeExpr
checkChoiceFieldTypes fields = do
  titleTy <-
    maybe (Left (MissingField (Ident "title") (TRecord fields))) pure (lookup (Ident "title") fields)
  optionsTy <-
    maybe (Left (MissingField (Ident "options") (TRecord fields))) pure (lookup (Ident "options") fields)
  runTc (unifyTypes tString titleTy)
  runTc (unifyTypes (TList tString) optionsTy)
  for_ (lookup (Ident "detail") fields) (runTc . unifyTypes tString)
  rejectUnknownChoice (map fst fields)
  pure tString

rejectUnknownChoice :: [Ident] -> Either CheckError ()
rejectUnknownChoice =
  mapM_
    ( \n ->
        unless (n `elem` [Ident "title", Ident "detail", Ident "options"]) $
          Left (UnknownField n (TRecord [(Ident "title", tString), (Ident "options", TList tString)]))
    )

-- | @human.ask({ prompt, detail? })@ or named equivalent.
isHumanAsk :: Expr -> Bool
isHumanAsk = \case
  EProj (EVar (Ident "human")) (Ident "ask") -> True
  _ -> False

inferHumanAskApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferHumanAskApp env args = case classifyArgs args of
  Left err -> Left err
  Right (Named nes) -> checkAskFields env nes
  Right (Positional [recordExpr]) -> do
    ty <- infer env recordExpr >>= resolveType env
    case ty of
      TRecord fields -> checkAskFieldTypes fields
      _ -> Left (ExpectedRecord ty)
  Right (Positional xs) -> Left (ArityMismatch 1 (length xs))
  where
    checkAskFields checkEnv fields = do
      promptE <- maybe (Left (MissingNamedArg (Ident "prompt"))) pure (lookup (Ident "prompt") fields)
      check checkEnv promptE tString
      case lookup (Ident "detail") fields of
        Nothing -> pure ()
        Just detailE -> check checkEnv detailE tString
      rejectUnknown (map fst fields)
      pure tString

    checkAskFieldTypes fields = do
      promptTy <- maybe (Left (MissingField (Ident "prompt") (TRecord fields))) pure (lookup (Ident "prompt") fields)
      runTc (unifyTypes tString promptTy)
      for_ (lookup (Ident "detail") fields) (runTc . unifyTypes tString)
      rejectUnknown (map fst fields)
      pure tString

    rejectUnknown = mapM_
        ( \n ->
            unless (n `elem` [Ident "prompt", Ident "detail"]) $
              Left (UnknownField n (TRecord [(Ident "prompt", tString)]))
        )

tUnit, tBool, tInt, tFloat, tString, tToolSpec, tFileRef, tJson, tSchema, tTurn :: TypeExpr
tUnit = TName (TypeName "Unit")
tBool = TName (TypeName "Bool")
tInt = TName (TypeName "Int")
tFloat = TName (TypeName "Float")
tString = TName (TypeName "String")
tToolSpec = TName (TypeName "ToolSpec")
tFileRef = TName (TypeName "FileRef")
tJson = TName (TypeName "Json")
tSchema = TName (TypeName "Schema")
tTurn = TName (TypeName "Turn")
