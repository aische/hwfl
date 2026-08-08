-- | Big-step pure evaluator (runtime §2–3: no snapshot mid-reduction).
--
-- Non-pure constructs ('EPar', 'EJoin', 'EConfirm', 'ETry', 'ESection') and
-- unresolved qnames trap as 'Unsupported'. Host paths are ordinary projection
-- and fail like any other unbound lookup.
--
-- Recursion is fuel-bounded (M-8): 'fun f() -> f()' returns a trap instead of
-- overflowing the Haskell stack.
module Hwfl.Eval.Pure
  ( eval,
    evalArgs,
    applyValue,
    bindParams,
    matchPat,
  )
where

import Data.Text qualified as T
import Hwfl.Ast.Expr
import Hwfl.Ast.Name (Ident (..), TypeName (..), qnameToText, slugToText)
import Hwfl.Ast.Pat (Literal (..), Pattern (..))
import Hwfl.Ast.Type (TypeExpr (..))
import Hwfl.Eval.Error (EvalError (..))
import Hwfl.Eval.Prelude (applyBuiltin)
import Hwfl.Eval.Value
import Hwfl.Limits (maxPureEvalSteps)

eval :: Env -> Expr -> Either EvalError Value
eval = evalFuel maxPureEvalSteps

evalFuel :: Int -> Env -> Expr -> Either EvalError Value
evalFuel 0 _ _ = Left (Trap "evaluation budget exceeded")
evalFuel fuel env e = case e of
  ELit lit -> literalValue lit
  EVar n ->
    maybe (Left (Trap ("unbound variable: " <> unIdent n))) Right (lookupEnv n env)
  EQName q ->
    Left (Unsupported ("qname not elaborated: " <> qnameToText q))
  ESection s ->
    Left (Unsupported ("section ref in pure eval: @" <> slugToText s))
  EList es -> VList <$> traverse (evalFuel (fuel - 1) env) es
  ERecord fs -> VRecord <$> evalFields (fuel - 1) env fs
  EInterp parts -> evalInterp (fuel - 1) env parts
  EApp f args -> do
    fv <- evalFuel (fuel - 1) env f
    vs <- evalArgsFuel (fuel - 1) env args
    applyValueFuel (fuel - 1) fv vs
  EProj e0 f -> do
    v <- evalFuel (fuel - 1) env e0
    project v f
  EIndex e0 ix -> do
    v <- evalFuel (fuel - 1) env e0
    i <- evalFuel (fuel - 1) env ix
    indexList v i
  ELet n _ e1 e2 -> do
    v1 <- evalFuel (fuel - 1) env e1
    evalFuel (fuel - 1) (extendEnv n v1 env) e2
  EFun ps _ body -> Right (VClosure ps body env)
  EIf c t el -> do
    cv <- evalFuel (fuel - 1) env c
    case cv of
      VBool True -> evalFuel (fuel - 1) env t
      VBool False -> evalFuel (fuel - 1) env el
      _ -> Left (Trap "if condition is not Bool")
  EMatch scrut arms -> do
    v <- evalFuel (fuel - 1) env scrut
    matchArms (fuel - 1) env v arms
  EPar {} -> Left (Unsupported "par is not pure")
  EJoin {} -> Left (Unsupported "join is not pure")
  EConfirm {} -> Left (Unsupported "confirm is not pure")
  EChoice {} -> Left (Unsupported "choice is not pure")
  ETry {} -> Left (Unsupported "try/catch is not pure")
  ESchema {} -> Left (Unsupported "schema(T) is check-time only")
  ETag n Nothing -> Right (VVariant n Nothing)
  ETag n (Just payload) -> do
    v <- evalFuel (fuel - 1) env payload
    Right (VVariant n (Just v))

literalValue :: Literal -> Either EvalError Value
literalValue = \case
  LUnit -> Right VUnit
  LBool b -> Right (VBool b)
  LInt n -> Right (VInt n)
  LFloat d -> either (Left . Trap) Right (finiteFloat "float literal" d)
  LString t -> Right (VString t)

evalFields :: Int -> Env -> [Field] -> Either EvalError [(Ident, Value)]
evalFields fuel env = traverse $ \case
  Field n e -> (n,) <$> evalFuel fuel env e
  FieldShorthand n ->
    maybe
      (Left (Trap ("unbound shorthand field: " <> unIdent n)))
      (\v -> Right (n, v))
      (lookupEnv n env)

evalInterp :: Int -> Env -> [StringPart] -> Either EvalError Value
evalInterp fuel env parts = VString . T.concat <$> traverse part parts
  where
    part = \case
      SLit t -> Right t
      SInterp e -> do
        v <- evalFuel fuel env e
        either (Left . Trap) Right (renderValue v)

evalArgs :: Env -> [Arg] -> Either EvalError [(Maybe Ident, Value)]
evalArgs = evalArgsFuel maxPureEvalSteps

evalArgsFuel :: Int -> Env -> [Arg] -> Either EvalError [(Maybe Ident, Value)]
evalArgsFuel fuel env = traverse $ \case
  ArgPos e -> (Nothing,) <$> evalFuel fuel env e
  ArgNamed n e -> (Just n,) <$> evalFuel fuel env e

applyValue :: Value -> [(Maybe Ident, Value)] -> Either EvalError Value
applyValue = applyValueFuel maxPureEvalSteps

applyValueFuel :: Int -> Value -> [(Maybe Ident, Value)] -> Either EvalError Value
applyValueFuel fuel f args = case f of
  VBuiltin b -> applyBuiltin b (map snd args)
  VClosure params body cloEnv -> do
    binds <- bindParams params args
    evalFuel fuel (extendEnvMany binds cloEnv) body
  VHostOp op ->
    Left (Trap ("host op outside runtime driver: " <> hostOpName op))
  _ -> Left (Trap "applied a non-function value")

-- | Bind positional or named args to parameters (shared with the host runtime).
bindParams :: [Param] -> [(Maybe Ident, Value)] -> Either EvalError [(Ident, Value)]
bindParams params args
  | any (isJust . fst) args && any (isNothing . fst) args =
      Left (Trap "cannot mix positional and named arguments")
  | all (isNothing . fst) args =
      bindPositional (map snd args)
  | otherwise = bindNamedArgs
  where
    named = [(n, v) | (Just n, v) <- args]
    bindNamed p = case lookup (paramName p) named of
      Just v -> Right (paramName p, v)
      Nothing ->
        Left (Trap ("missing named argument: " <> unIdent (paramName p)))

    bindPositional values
      | null values,
        [p] <- params,
        isUnitParam p =
          Right [(paramName p, VUnit)]
      | [VRecord fields] <- values,
        length params > 1 =
          traverse (bindRecordParam fields) params
      | [p] <- params,
        Just fields <- recordParamFields p,
        length values == length fields =
          Right [(paramName p, VRecord (zip (map fst fields) values))]
      | length params == length values =
          Right (zipWith (\p v -> (paramName p, v)) params values)
      | otherwise = Left (arityMismatch (length params) (length values))

    bindNamedArgs
      | [p] <- params,
        Just fields <- recordParamFields p,
        length named == length fields =
          VRecord <$> traverse (bindRecordField named) fields >>= \record ->
            Right [(paramName p, record)]
      | [p] <- params,
        Just fields <- recordParamFields p =
          Left (arityMismatch (length fields) (length named))
      | length params /= length named =
          Left (Trap "arity mismatch for named arguments")
      | otherwise = traverse bindNamed params

    bindRecordField supplied (name, _) = case lookup name supplied of
      Just value -> Right (name, value)
      Nothing -> Left (Trap ("missing named argument: " <> unIdent name))

    bindRecordParam fields p = case lookup (paramName p) fields of
      Just value -> Right (paramName p, value)
      Nothing -> Left (Trap ("missing record argument: " <> unIdent (paramName p)))

arityMismatch :: Int -> Int -> EvalError
arityMismatch expected given =
  Trap
    ( "arity mismatch: expected "
        <> T.pack (show expected)
        <> ", got "
        <> T.pack (show given)
    )

isUnitParam :: Param -> Bool
isUnitParam (Param (Ident "_") Nothing) = True
isUnitParam (Param _ Nothing) = True
isUnitParam (Param _ (Just (TName (TypeName "Unit")))) = True
isUnitParam _ = False

recordParamFields :: Param -> Maybe [(Ident, TypeExpr)]
recordParamFields (Param _ (Just (TRecord fields))) = Just fields
recordParamFields _ = Nothing

isJust :: Maybe a -> Bool
isJust = \case
  Just _ -> True
  Nothing -> False

isNothing :: Maybe a -> Bool
isNothing = not . isJust

project :: Value -> Ident -> Either EvalError Value
project v f = case v of
  VRecord fs ->
    maybe
      (Left (Trap ("missing field: " <> unIdent f)))
      Right
      (lookup f fs)
  _ -> Left (Trap ("projection on non-record: " <> unIdent f))

indexList :: Value -> Value -> Either EvalError Value
indexList v ix = case (v, ix) of
  (VList xs, VInt i)
    | i < 0 || i >= fromIntegral (length xs) ->
        Left (Trap "list index out of bounds")
    | otherwise -> Right (xs !! fromIntegral i)
  (VList _, _) -> Left (Trap "list index is not Int")
  _ -> Left (Trap "index on non-list")

matchArms :: Int -> Env -> Value -> [MatchArm] -> Either EvalError Value
matchArms fuel env v = \case
  [] -> Left (Trap "non-exhaustive match")
  MatchArm p body : rest -> case matchPat p v of
    Nothing -> matchArms fuel env v rest
    Just binds -> evalFuel fuel (extendEnvMany binds env) body

-- | Try to match a pattern; 'Nothing' means no match (try next arm).
matchPat :: Pattern -> Value -> Maybe [(Ident, Value)]
matchPat p v = case (p, v) of
  (PWild, _) -> Just []
  (PVar n, _) -> Just [(n, v)]
  (PLit lit, _) -> case literalValue lit of
    Right expected | expected `valueStructEq` v -> Just []
    _ -> Nothing
  (PList ps, VList xs)
    | length ps /= length xs -> Nothing
    | otherwise -> concat <$> traverse (uncurry matchPat) (zip ps xs)
  (PRecord pfs, VRecord vfs) -> matchRecord pfs vfs
  (PTag t mp, VVariant t' mv)
    | t /= t' -> Nothing
    | otherwise -> case (mp, mv) of
        (Nothing, Nothing) -> Just []
        (Just p', Just v') -> matchPat p' v'
        (Nothing, Just _) -> Just [] -- tag-only pattern ignores payload
        (Just _, Nothing) -> Nothing
  _ -> Nothing

matchRecord :: [(Ident, Pattern)] -> [(Ident, Value)] -> Maybe [(Ident, Value)]
matchRecord pfs vfs = concat <$> traverse one pfs
  where
    one (n, p) = case lookup n vfs of
      Nothing -> Nothing
      Just v -> matchPat p v

-- | Structural equality for literals vs values (no closure compare).
valueStructEq :: Value -> Value -> Bool
valueStructEq a b = case (a, b) of
  (VUnit, VUnit) -> True
  (VBool x, VBool y) -> x == y
  (VInt x, VInt y) -> x == y
  (VFloat x, VFloat y) -> x == y
  (VString x, VString y) -> x == y
  _ -> False
