-- | Big-step pure evaluator (runtime §2–3: no snapshot mid-reduction).
--
-- Non-pure constructs ('EPar', 'EJoin', 'EConfirm', 'ETry', 'ESection') and
-- unresolved qnames trap as 'Unsupported'. Host paths are ordinary projection
-- and fail like any other unbound lookup.
module Pml.Eval.Pure
  ( eval,
    evalArgs,
    applyValue,
    matchPat,
  )
where

import Data.Text qualified as T
import Pml.Ast.Expr
import Pml.Ast.Name (Ident (..), qnameToText, slugToText)
import Pml.Ast.Pat (Literal (..), Pattern (..))
import Pml.Eval.Error (EvalError (..))
import Pml.Eval.Prelude (applyBuiltin)
import Pml.Eval.Value

eval :: Env -> Expr -> Either EvalError Value
eval env = \case
  ELit lit -> Right (literalValue lit)
  EVar n ->
    maybe (Left (Trap ("unbound variable: " <> unIdent n))) Right (lookupEnv n env)
  EQName q ->
    Left (Unsupported ("qname not elaborated: " <> qnameToText q))
  ESection s ->
    Left (Unsupported ("section ref in pure eval: @" <> slugToText s))
  EList es -> VList <$> traverse (eval env) es
  ERecord fs -> VRecord <$> evalFields env fs
  EInterp parts -> evalInterp env parts
  EApp f args -> do
    fv <- eval env f
    vs <- evalArgs env args
    applyValue fv vs
  EProj e f -> do
    v <- eval env e
    project v f
  EIndex e ix -> do
    v <- eval env e
    i <- eval env ix
    indexList v i
  ELet n _ e1 e2 -> do
    v1 <- eval env e1
    eval (extendEnv n v1 env) e2
  EFun ps _ body -> Right (VClosure ps body env)
  EIf c t e -> do
    cv <- eval env c
    case cv of
      VBool True -> eval env t
      VBool False -> eval env e
      _ -> Left (Trap "if condition is not Bool")
  EMatch scrut arms -> do
    v <- eval env scrut
    matchArms env v arms
  EPar {} -> Left (Unsupported "par is not pure")
  EJoin {} -> Left (Unsupported "join is not pure")
  EConfirm {} -> Left (Unsupported "confirm is not pure")
  ETry {} -> Left (Unsupported "try/catch is not pure")

literalValue :: Literal -> Value
literalValue = \case
  LUnit -> VUnit
  LBool b -> VBool b
  LInt n -> VInt n
  LFloat d -> VFloat d
  LString t -> VString t

evalFields :: Env -> [Field] -> Either EvalError [(Ident, Value)]
evalFields env = traverse $ \case
  Field n e -> (n,) <$> eval env e
  FieldShorthand n ->
    maybe
      (Left (Trap ("unbound shorthand field: " <> unIdent n)))
      (\v -> Right (n, v))
      (lookupEnv n env)

evalInterp :: Env -> [StringPart] -> Either EvalError Value
evalInterp env parts = VString . T.concat <$> traverse part parts
  where
    part = \case
      SLit t -> Right t
      SInterp e -> do
        v <- eval env e
        either (Left . Trap) Right (renderValue v)

evalArgs :: Env -> [Arg] -> Either EvalError [(Maybe Ident, Value)]
evalArgs env = traverse $ \case
  ArgPos e -> (Nothing,) <$> eval env e
  ArgNamed n e -> (Just n,) <$> eval env e

applyValue :: Value -> [(Maybe Ident, Value)] -> Either EvalError Value
applyValue f args = case f of
  VBuiltin b -> applyBuiltin b (map snd args)
  VClosure params body cloEnv -> do
    binds <- bindParams params args
    eval (extendEnvMany binds cloEnv) body
  _ -> Left (Trap "applied a non-function value")

bindParams :: [Param] -> [(Maybe Ident, Value)] -> Either EvalError [(Ident, Value)]
bindParams params args
  | any (isJust . fst) args && any (isNothing . fst) args =
      Left (Trap "cannot mix positional and named arguments")
  | all (isNothing . fst) args =
      if length params /= length args
        then
          Left
            ( Trap
                ( "arity mismatch: expected "
                    <> T.pack (show (length params))
                    <> ", got "
                    <> T.pack (show (length args))
                )
            )
        else Right (zipWith (\p (_, v) -> (paramName p, v)) params args)
  | length params /= length args =
      Left (Trap "arity mismatch for named arguments")
  | otherwise = traverse bindNamed params
  where
    named = [(n, v) | (Just n, v) <- args]
    bindNamed p = case lookup (paramName p) named of
      Just v -> Right (paramName p, v)
      Nothing ->
        Left (Trap ("missing named argument: " <> unIdent (paramName p)))

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

matchArms :: Env -> Value -> [MatchArm] -> Either EvalError Value
matchArms env v = \case
  [] -> Left (Trap "non-exhaustive match")
  MatchArm p body : rest -> case matchPat p v of
    Nothing -> matchArms env v rest
    Just binds -> eval (extendEnvMany binds env) body

-- | Try to match a pattern; 'Nothing' means no match (try next arm).
matchPat :: Pattern -> Value -> Maybe [(Ident, Value)]
matchPat p v = case (p, v) of
  (PWild, _) -> Just []
  (PVar n, _) -> Just [(n, v)]
  (PLit lit, _) ->
    if literalValue lit `valueStructEq` v then Just [] else Nothing
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
