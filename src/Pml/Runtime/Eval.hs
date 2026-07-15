-- | Host-capable evaluator: big-step pure reduction with host/section support.
-- Snapshots fire only after completed host ops (no mid-pure).
module Pml.Runtime.Eval
  ( RunCtx (..),
    evalIO,
    evalArgsIO,
    applyIO,
  )
where

import Data.IORef (IORef, modifyIORef', readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Pml.Ast.Expr
import Pml.Ast.Name (Ident (..), Slug, qnameToText, slugToText)
import Pml.Ast.Pat (Literal (..))
import Pml.Eval.Error (EvalError (..))
import Pml.Eval.Prelude (applyBuiltin)
import Pml.Eval.Pure (bindParams, matchPat)
import Pml.Eval.Value
import Pml.Runtime.Error (RuntimeError (..))
import Pml.Runtime.Host (HostEnv (..), runHostOp)
import Pml.Runtime.Snapshot
  ( RunStatus (..),
    RunStore (..),
    mkBoundary,
    writeBoundarySnapshot,
  )

-- | Runtime context for one @pml run@.
data RunCtx = RunCtx
  { rcHost :: HostEnv,
    rcSections :: Map Slug Text,
    rcStore :: RunStore,
    rcProjectHash :: Text,
    rcSeq :: IORef Int
  }

evalIO :: RunCtx -> Env -> Expr -> IO (Either RuntimeError Value)
evalIO ctx env = \case
  ELit lit -> pure (Right (literalValue lit))
  EVar n ->
    pure $
      maybe
        (Left (EvalErr (Trap ("unbound variable: " <> unIdent n))))
        Right
        (lookupEnv n env)
  EQName q ->
    pure (Left (EvalErr (Unsupported ("qname not elaborated: " <> qnameToText q))))
  ESection s ->
    pure $ case Map.lookup s ctx.rcSections of
      Just t -> Right (VString t)
      Nothing ->
        Left (EvalErr (Trap ("unknown section: @" <> slugToText s)))
  EList es -> do
    rs <- traverse (evalIO ctx env) es
    pure (VList <$> sequence rs)
  ERecord fs -> do
    rs <- evalFieldsIO ctx env fs
    pure (VRecord <$> rs)
  EInterp parts -> evalInterpIO ctx env parts
  EApp f args -> do
    fv <- evalIO ctx env f
    case fv of
      Left e -> pure (Left e)
      Right fval -> do
        vs <- evalArgsIO ctx env args
        case vs of
          Left e -> pure (Left e)
          Right argv -> applyIO ctx fval argv
  EProj e f -> do
    v <- evalIO ctx env e
    pure (v >>= \x -> mapEval (project x f))
  EIndex e ix -> do
    v <- evalIO ctx env e
    case v of
      Left err -> pure (Left err)
      Right vv -> do
        i <- evalIO ctx env ix
        pure (i >>= \ii -> mapEval (indexList vv ii))
  ELet n _ e1 e2 -> do
    v1 <- evalIO ctx env e1
    case v1 of
      Left e -> pure (Left e)
      Right val -> evalIO ctx (extendEnv n val env) e2
  EFun ps _ body -> pure (Right (VClosure ps body env))
  EIf c t e -> do
    cv <- evalIO ctx env c
    case cv of
      Left err -> pure (Left err)
      Right (VBool True) -> evalIO ctx env t
      Right (VBool False) -> evalIO ctx env e
      Right _ -> pure (Left (EvalErr (Trap "if condition is not Bool")))
  EMatch scrut arms -> do
    v <- evalIO ctx env scrut
    case v of
      Left err -> pure (Left err)
      Right val -> matchArmsIO ctx env val arms
  EPar {} -> pure (Left (EvalErr (Unsupported "par is not available until M5")))
  EJoin {} -> pure (Left (EvalErr (Unsupported "join is not available until M5")))
  EConfirm {} -> pure (Left (EvalErr (Unsupported "confirm is not available until M5")))
  ETry {} -> pure (Left (EvalErr (Unsupported "try/catch is not available until M5")))
  ESchema {} -> pure (Left (EvalErr (Unsupported "schema(T) is check-time only")))

mapEval :: Either EvalError a -> Either RuntimeError a
mapEval = either (Left . EvalErr) Right

literalValue :: Literal -> Value
literalValue = \case
  LUnit -> VUnit
  LBool b -> VBool b
  LInt n -> VInt n
  LFloat d -> VFloat d
  LString t -> VString t

evalFieldsIO :: RunCtx -> Env -> [Field] -> IO (Either RuntimeError [(Ident, Value)])
evalFieldsIO ctx env = go []
  where
    go acc [] = pure (Right (reverse acc))
    go acc (Field n e : rest) = do
      r <- evalIO ctx env e
      case r of
        Left err -> pure (Left err)
        Right v -> go ((n, v) : acc) rest
    go acc (FieldShorthand n : rest) =
      case lookupEnv n env of
        Nothing ->
          pure (Left (EvalErr (Trap ("unbound shorthand field: " <> unIdent n))))
        Just v -> go ((n, v) : acc) rest

evalInterpIO :: RunCtx -> Env -> [StringPart] -> IO (Either RuntimeError Value)
evalInterpIO ctx env parts = go [] parts
  where
    go acc [] = pure (Right (VString (T.concat (reverse acc))))
    go acc (SLit t : rest) = go (t : acc) rest
    go acc (SInterp e : rest) = do
      r <- evalIO ctx env e
      case r of
        Left err -> pure (Left err)
        Right v -> case renderValue v of
          Left msg -> pure (Left (EvalErr (Trap msg)))
          Right t -> go (t : acc) rest

evalArgsIO :: RunCtx -> Env -> [Arg] -> IO (Either RuntimeError [(Maybe Ident, Value)])
evalArgsIO ctx env = go []
  where
    go acc [] = pure (Right (reverse acc))
    go acc (ArgPos e : rest) = do
      r <- evalIO ctx env e
      case r of
        Left err -> pure (Left err)
        Right v -> go ((Nothing, v) : acc) rest
    go acc (ArgNamed n e : rest) = do
      r <- evalIO ctx env e
      case r of
        Left err -> pure (Left err)
        Right v -> go ((Just n, v) : acc) rest

-- | Apply a value; host ops are one transition (snapshot afterwards).
applyIO ::
  RunCtx ->
  Value ->
  [(Maybe Ident, Value)] ->
  IO (Either RuntimeError Value)
applyIO ctx f args = case f of
  VBuiltin b -> pure (mapEval (applyBuiltin b (map snd args)))
  VClosure params body cloEnv -> case bindParams params args of
    Left e -> pure (Left (EvalErr e))
    Right binds -> evalIO ctx (extendEnvMany binds cloEnv) body
  VHostOp op -> do
    result <- runHostOp ctx.rcHost op args
    case result of
      Left e -> do
        _ <- recordBoundary ctx op Nothing StatusFailed
        pure (Left e)
      Right v -> do
        _ <- recordBoundary ctx op (Just v) StatusRunning
        pure (Right v)
  _ -> pure (Left (EvalErr (Trap "applied a non-function value")))

recordBoundary :: RunCtx -> HostOpId -> Maybe Value -> RunStatus -> IO ()
recordBoundary ctx op mVal status = do
  modifyIORef' ctx.rcSeq (+ 1)
  seqNo <- readIORef ctx.rcSeq
  snap <-
    mkBoundary
      ctx.rcStore.rsRunId
      seqNo
      status
      ctx.rcProjectHash
      (Just op)
      mVal
  writeBoundarySnapshot ctx.rcStore snap

matchArmsIO :: RunCtx -> Env -> Value -> [MatchArm] -> IO (Either RuntimeError Value)
matchArmsIO ctx env v = \case
  [] -> pure (Left (EvalErr (Trap "non-exhaustive match")))
  MatchArm p body : rest -> case matchPat p v of
    Nothing -> matchArmsIO ctx env v rest
    Just binds -> evalIO ctx (extendEnvMany binds env) body

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
