-- | Bidirectional local type inference / checking for kernel expressions.
module Hwfl.Check.Infer
  ( infer,
    check,
    inferModuleEnv,
  )
where

import Control.Monad (foldM, unless, when)
import Hwfl.Ast.Decl (Decl (..), ModuleBody (..))
import Hwfl.Ast.Expr
import Hwfl.Ast.Name (Ident (..), TypeName (..), qnameToText)
import Hwfl.Ast.Pat (Literal (..), Pattern (..))
import Hwfl.Ast.Type (TypeExpr (..))
import Hwfl.Check.Env
import Hwfl.Check.Error (CheckError (..))
import Hwfl.Check.Overload
  ( classifyOp,
    inferOverloadedApp,
    typesCompatible,
  )
import Hwfl.Check.Prelude (preludeTypeEnv)
import Hwfl.Check.Schema (schemaType, typeToSchema)

-- | Collect aliases + function types from decls (bodies checked separately).
inferModuleEnv :: ModuleBody -> Either CheckError TypeEnv
inferModuleEnv (ModuleBody decls _) = do
  checkDuplicateFuns decls
  env0 <- foldM addAlias preludeTypeEnv [(n, ty) | DType n ty <- decls]
  mapM_ (uncurry (resolveAliasDef env0)) [(n, ty) | DType n ty <- decls]
  foldM addFun env0 [(n, ps, mt) | DFun n ps mt _ <- decls]
  where
    addAlias env (n, ty) = insertAlias n ty env
    addFun env (n, ps, mt) = do
      funTy <- synthFunType env ps mt
      pure (extendVar n funTy env)

-- | Expand an alias RHS with the alias name already on the cycle stack.
resolveAliasDef :: TypeEnv -> TypeName -> TypeExpr -> Either CheckError TypeExpr
resolveAliasDef env root = resolveTypeFrom env [root]

resolveTypeFrom :: TypeEnv -> [TypeName] -> TypeExpr -> Either CheckError TypeExpr
resolveTypeFrom env = go
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
      TEffFun a es b -> TEffFun <$> go stack a <*> pure es <*> go stack b

checkDuplicateFuns :: [Decl] -> Either CheckError ()
checkDuplicateFuns decls = mapM_ one names
  where
    names = [n | DFun n _ _ _ <- decls]
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
  -- Bare @_@ defaults to Unit (E01-style entry stub).
  [Param (Ident "_") Nothing] -> Right tUnit
  [Param _ Nothing] -> Left (CannotInfer "parameter type")
  ps -> do
    fs <- traverse paramField ps
    pure (TRecord fs)
  where
    paramField (Param n mty) = case mty of
      Just ty -> (n,) <$> resolveType env ty
      Nothing -> Left (CannotInfer ("parameter " <> unIdent n))

infer :: TypeEnv -> Expr -> Either CheckError TypeExpr
infer env = \case
  ELit lit -> Right (literalType lit)
  EVar n@(Ident name)
    | Just _ <- classifyOp name ->
        Left (CannotInfer ("overloaded operator " <> name <> " must be applied"))
    | otherwise ->
        maybe (Left (UnboundVar n)) (resolveType env) (lookupVar n env)
  EQName q -> case lookupImport (qnameToText q) env of
    Nothing -> Left (UnboundModule (qnameToText q))
    Just ex -> resolveType env (moduleExportRecord ex)
  ESection _ -> Right tString
  EList [] -> Left (CannotInfer "empty list; add a type annotation")
  EList (e : es) -> do
    te <- infer env e
    mapM_ (\x -> check env x te) es
    pure (TList te)
  ERecord fs -> do
    typed <- traverse (inferField env) fs
    pure (TRecord typed)
  EInterp parts -> do
    mapM_ (checkInterpPart env) parts
    pure tString
  EApp f args
    | isToolBuiltin f -> inferToolApp env args
    | isListLength f -> inferListLengthApp env args
    | isListConcat f -> inferListConcatApp env args
    | isJsonEncode f -> inferJsonEncodeApp env args
    | isLlmObject f -> inferLlmObjectApp env args
    | isLlmAgentObject f -> inferLlmAgentObjectApp env args
    | isObsSpan f -> inferObsSpanApp env args
    | isObsSpanPartial f -> inferObsSpanThunkApp env args
    | isMetaInvoke f -> inferMetaInvokeApp env args
    | isMetaReadSpans f -> inferMetaReadSpansApp env args
    | EVar (Ident n) <- f,
      Just cls <- classifyOp n ->
        inferOverloadedApp env cls infer args
    | otherwise -> do
        ft <- infer env f
        applyType env ft args
  EProj e f -> do
    te <- infer env e
    te' <- resolveType env te
    case te' of
      TRecord fs ->
        maybe (Left (MissingField f te')) Right (lookup f fs)
      _ -> Left (ExpectedRecord te')
  EIndex e ix -> do
    te <- infer env e
    check env ix tInt
    te' <- resolveType env te
    case te' of
      TList el -> Right el
      _ -> Left (ExpectedList te')
  ELet n mt e1 e2 -> do
    t1 <- case mt of
      Just ann -> do
        want <- resolveType env ann
        check env e1 want
        pure want
      Nothing -> infer env e1
    infer (extendVar n t1 env) e2
  EFun ps mt body -> do
    domain <- paramsDomain env ps
    binds <- paramBindings env ps domain
    ret <- case mt of
      Just ann -> do
        want <- resolveType env ann
        check (extendVars binds env) body want
        pure want
      Nothing -> infer (extendVars binds env) body
    pure (TFun domain ret)
  EIf c t e -> do
    check env c tBool
    tt <- infer env t
    check env e tt
    pure tt
  EMatch scrut arms -> inferMatch env scrut arms
  EPar _opts n xs body -> do
    te <- infer env xs
    te' <- resolveType env te
    case te' of
      TList el -> do
        bt <- infer (extendVar n el env) body
        pure (TList bt)
      _ -> Left (ExpectedList te')
  EJoin es -> case es of
    [] -> Left (CannotInfer "empty join")
    (e : rest) -> do
      t0 <- infer env e
      mapM_ (\x -> check env x t0) rest
      pure (TList t0)
  EConfirm e -> do
    _ <- infer env e
    pure tBool
  ETry body errVar handler -> do
    tBody <- infer env body
    check (extendVar errVar tString env) handler tBody
    pure tBody
  ESchema te -> do
    _ <- typeToSchema env te
    pure schemaType

check :: TypeEnv -> Expr -> TypeExpr -> Either CheckError ()
check env e want = do
  want' <- resolveType env want
  case e of
    EList [] -> case want' of
      TList _ -> pure ()
      _ -> Left (TypeMismatch want' (TList tUnit))
    EList es -> case want' of
      TList el -> mapM_ (\x -> check env x el) es
      _ -> do
        got <- infer env e
        unify want' got
    EFun ps mt body -> case want' of
      TFun domain ret -> do
        binds <- paramBindings env ps domain
        case mt of
          Just ann -> do
            ann' <- resolveType env ann
            unify ret ann'
          Nothing -> pure ()
        check (extendVars binds env) body ret
      _ -> do
        got <- infer env e
        unify want' got
    EIf c t f -> do
      check env c tBool
      check env t want'
      check env f want'
    ELet n mt e1 e2 -> do
      t1 <- case mt of
        Just ann -> do
          a <- resolveType env ann
          check env e1 a
          pure a
        Nothing -> infer env e1
      check (extendVar n t1 env) e2 want'
    EMatch scrut arms -> checkMatch env scrut arms want'
    EPar _opts n xs body -> case want' of
      TList el -> do
        te <- infer env xs
        te' <- resolveType env te
        case te' of
          TList elemTy -> do
            check (extendVar n elemTy env) body el
          _ -> Left (ExpectedList te')
      _ -> do
        got <- infer env e
        unify want' got
    EConfirm arg -> do
      unify want' tBool
      _ <- infer env arg
      pure ()
    EJoin es -> case want' of
      TList el -> mapM_ (\x -> check env x el) es
      _ -> do
        got <- infer env e
        unify want' got
    ETry body errVar handler -> do
      tBody <- infer env body
      check (extendVar errVar tString env) handler tBody
      unify want' tBody
    _ -> do
      got <- infer env e
      unify want' got

inferMatch :: TypeEnv -> Expr -> [MatchArm] -> Either CheckError TypeExpr
inferMatch env scrut arms = case arms of
  [] -> Left (CannotInfer "empty match")
  MatchArm p body : rest -> do
    st <- infer env scrut
    binds <- patternBindings env p st
    t0 <- infer (extendVars binds env) body
    mapM_
      ( \(MatchArm p' b') -> do
          bs <- patternBindings env p' st
          check (extendVars bs env) b' t0
      )
      rest
    pure t0

checkMatch :: TypeEnv -> Expr -> [MatchArm] -> TypeExpr -> Either CheckError ()
checkMatch env scrut arms want = do
  st <- infer env scrut
  mapM_
    ( \(MatchArm p body) -> do
        binds <- patternBindings env p st
        check (extendVars binds env) body want
    )
    arms

patternBindings :: TypeEnv -> Pattern -> TypeExpr -> Either CheckError [(Ident, TypeExpr)]
patternBindings env p ty = do
  ty' <- resolveType env ty
  go p ty'
  where
    go pat expected = case pat of
      PWild -> Right []
      PVar n -> Right [(n, expected)]
      PLit lit -> do
        unify expected (literalType lit)
        pure []
      PList ps -> case expected of
        TList el -> concat <$> traverse (`go` el) ps
        _ -> Left (ExpectedList expected)
      PRecord pfs -> case expected of
        TRecord fs -> concat <$> traverse (fieldBind fs) pfs
        _ -> Left (ExpectedRecord expected)
      PTag _ mp -> case mp of
        Nothing -> Right []
        Just p' -> go p' expected
    fieldBind fs (n, p') = case lookup n fs of
      Nothing -> Left (MissingField n (TRecord fs))
      Just ft -> go p' ft

inferField :: TypeEnv -> Field -> Either CheckError (Ident, TypeExpr)
inferField env = \case
  Field n e -> (n,) <$> infer env e
  FieldShorthand n ->
    maybe (Left (UnboundVar n)) (\ty -> Right (n, ty)) (lookupVar n env)

checkInterpPart :: TypeEnv -> StringPart -> Either CheckError ()
checkInterpPart env = \case
  SLit _ -> pure ()
  SInterp e -> do
    ty <- infer env e
    ty' <- resolveType env ty
    unless (isRenderable ty') $ Left (NotRenderable ty')

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

applyType :: TypeEnv -> TypeExpr -> [Arg] -> Either CheckError TypeExpr
applyType env fty args = do
  fty' <- resolveType env fty
  case classifyArgs args of
    Left err -> Left err
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

applyPositional :: TypeEnv -> TypeExpr -> [Expr] -> Either CheckError TypeExpr
applyPositional env = go
  where
    go ty [] = Right ty
    go ty args = case funArrow ty of
      Just (TRecord fields, ret)
        | length args == length fields && not (null args) -> do
            mapM_
              ( \(arg, (_, domain)) -> check env arg domain
              )
              (zip args fields)
            pure ret
      Just (domain, ret)
        | (arg : rest) <- args -> do
            check env arg domain
            go ret rest
      _ -> Left (ExpectedFunction ty)

applyNamed :: TypeEnv -> TypeExpr -> [(Ident, Expr)] -> Either CheckError TypeExpr
applyNamed env fty nes = case funArrow fty of
  Just (TRecord fields, ret) -> do
    mapM_ (checkNamed fields) nes
    let given = map fst nes
        expected = map fst fields
    when (length given /= length expected) $
      Left (ArityMismatch (length expected) (length given))
    mapM_ (\n -> unless (n `elem` given) $ Left (MissingNamedArg n)) expected
    pure ret
  Just (domain, _) ->
    Left (TypeMismatchMsg "named arguments require a record parameter" (TRecord []) domain)
  Nothing -> Left (ExpectedFunction fty)
  where
    checkNamed fields (n, e) = case lookup n fields of
      Nothing -> Left (UnknownField n (TRecord fields))
      Just ty -> check env e ty

-- | View @TFun@ / @TEffFun@ as a single arrow (effects ignored for typing).
funArrow :: TypeExpr -> Maybe (TypeExpr, TypeExpr)
funArrow = \case
  TFun a b -> Just (a, b)
  TEffFun a _ b -> Just (a, b)
  _ -> Nothing

paramBindings :: TypeEnv -> [Param] -> TypeExpr -> Either CheckError [(Ident, TypeExpr)]
paramBindings env ps domain = do
  domain' <- resolveType env domain
  case ps of
    [] -> do
      unify domain' tUnit
      pure []
    [Param n mty] -> do
      case mty of
        Just ann -> do
          ann' <- resolveType env ann
          unify domain' ann'
        Nothing -> pure ()
      pure [(n, domain')]
    _ -> case domain' of
      TRecord fs ->
        if length ps /= length fs
          then Left (ArityMismatch (length fs) (length ps))
          else case traverse (bindNamed fs) ps of
            Right bs -> Right bs
            Left _ ->
              Right $
                zipWith
                  (\(Param n _) (_, ty) -> (n, ty))
                  ps
                  fs
      _ -> Left (ExpectedRecord domain')
  where
    bindNamed fs (Param n mty) = case lookup n fs of
      Just ty -> do
        case mty of
          Just ann -> do
            ann' <- resolveType env ann
            unify ty ann'
          Nothing -> pure ()
        pure (n, ty)
      Nothing -> Left (MissingField n (TRecord fs))

unify :: TypeExpr -> TypeExpr -> Either CheckError ()
unify want got =
  if typesCompatible want got
    then Right ()
    else Left (TypeMismatch want got)

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
  ret <- applyType env ft args
  case schemaArgExpr args of
    Just (ESchema te) -> resolveType env te
    _ -> pure ret

-- | @llm.agent_object(..., schema = schema(T), ...)@ ⇒ @{ value: T, rounds: Int }@.
isLlmAgentObject :: Expr -> Bool
isLlmAgentObject = \case
  EProj (EVar (Ident "llm")) (Ident "agent_object") -> True
  _ -> False

inferLlmAgentObjectApp :: TypeEnv -> [Arg] -> Either CheckError TypeExpr
inferLlmAgentObjectApp env args = do
  ft <- infer env (EProj (EVar (Ident "llm")) (Ident "agent_object"))
  ret <- applyType env ft args
  case schemaArgExpr args of
    Just (ESchema te) -> do
      out <- resolveType env te
      pure
        ( TRecord
            [ (Ident "value", out),
              (Ident "rounds", tInt)
            ]
        )
    _ -> pure ret

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
    applyType env ft [ArgPos nameE]
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
      unify domain tUnit
      pure ret
    Nothing -> Left (ExpectedFunction te')

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

tUnit, tBool, tInt, tFloat, tString, tToolSpec, tFileRef, tJson :: TypeExpr
tUnit = TName (TypeName "Unit")
tBool = TName (TypeName "Bool")
tInt = TName (TypeName "Int")
tFloat = TName (TypeName "Float")
tString = TName (TypeName "String")
tToolSpec = TName (TypeName "ToolSpec")
tFileRef = TName (TypeName "FileRef")
tJson = TName (TypeName "Json")
