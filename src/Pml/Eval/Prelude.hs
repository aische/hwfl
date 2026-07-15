-- | Pure prelude builtins (arithmetic, comparisons, bool) — not host ops.
module Pml.Eval.Prelude
  ( preludeEnv,
    applyBuiltin,
  )
where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Pml.Ast.Name (Ident (..))
import Pml.Eval.Error (EvalError (..))
import Pml.Eval.Value
  ( Builtin (..),
    Env,
    Value (..),
  )

preludeEnv :: Env
preludeEnv =
  Map.fromList
    [ (Ident "+", VBuiltin BAdd),
      (Ident "-", VBuiltin BSub),
      (Ident "*", VBuiltin BMul),
      (Ident "/", VBuiltin BDiv),
      (Ident "==", VBuiltin BEq),
      (Ident "!=", VBuiltin BNeq),
      (Ident "<", VBuiltin BLt),
      (Ident "<=", VBuiltin BLe),
      (Ident ">", VBuiltin BGt),
      (Ident ">=", VBuiltin BGe),
      (Ident "&&", VBuiltin BAnd),
      (Ident "||", VBuiltin BOr),
      (Ident "not", VBuiltin BNot)
    ]

applyBuiltin :: Builtin -> [Value] -> Either EvalError Value
applyBuiltin b args = case (b, args) of
  (BAdd, [a, c]) -> num2 (+) (+) a c
  (BSub, [a, c]) -> num2 (-) (-) a c
  (BMul, [a, c]) -> num2 (*) (*) a c
  (BDiv, [a, c]) -> div2 a c
  (BEq, [a, c]) -> VBool <$> valueEq a c
  (BNeq, [a, c]) -> VBool . not <$> valueEq a c
  (BLt, [a, c]) -> ord2 (<) (<) (<) a c
  (BLe, [a, c]) -> ord2 (<=) (<=) (<=) a c
  (BGt, [a, c]) -> ord2 (>) (>) (>) a c
  (BGe, [a, c]) -> ord2 (>=) (>=) (>=) a c
  (BAnd, [VBool x, VBool y]) -> Right (VBool (x && y))
  (BOr, [VBool x, VBool y]) -> Right (VBool (x || y))
  (BNot, [VBool x]) -> Right (VBool (not x))
  (BAnd, _) -> arityOrType "&&" 2 args
  (BOr, _) -> arityOrType "||" 2 args
  (BNot, _) -> arityOrType "not" 1 args
  (_, _) -> Left (Trap ("wrong arity for builtin: " <> T.pack (show b)))

num2 ::
  (Integer -> Integer -> Integer) ->
  (Double -> Double -> Double) ->
  Value ->
  Value ->
  Either EvalError Value
num2 fi ff a b = case (a, b) of
  (VInt x, VInt y) -> Right (VInt (fi x y))
  (VFloat x, VFloat y) -> Right (VFloat (ff x y))
  _ -> Left (Trap "arithmetic expects Int+Int or Float+Float")

div2 :: Value -> Value -> Either EvalError Value
div2 a b = case (a, b) of
  (VInt _, VInt 0) -> Left (Trap "division by zero")
  (VInt x, VInt y) -> Right (VInt (x `div` y))
  (VFloat _, VFloat 0) -> Left (Trap "division by zero")
  (VFloat x, VFloat y) -> Right (VFloat (x / y))
  _ -> Left (Trap "division expects Int+Int or Float+Float")

ord2 ::
  (Integer -> Integer -> Bool) ->
  (Double -> Double -> Bool) ->
  (Text -> Text -> Bool) ->
  Value ->
  Value ->
  Either EvalError Value
ord2 fi ff fs a b = case (a, b) of
  (VInt x, VInt y) -> Right (VBool (fi x y))
  (VFloat x, VFloat y) -> Right (VBool (ff x y))
  (VString x, VString y) -> Right (VBool (fs x y))
  _ -> Left (Trap "ordered comparison expects matching Int, Float, or String")

valueEq :: Value -> Value -> Either EvalError Bool
valueEq a b = case (a, b) of
  (VClosure {}, _) -> Left (Trap "cannot compare closures")
  (_, VClosure {}) -> Left (Trap "cannot compare closures")
  (VTopFun {}, _) -> Left (Trap "cannot compare top-level funs")
  (_, VTopFun {}) -> Left (Trap "cannot compare top-level funs")
  (VBuiltin {}, _) -> Left (Trap "cannot compare builtins")
  (_, VBuiltin {}) -> Left (Trap "cannot compare builtins")
  (VHostOp {}, _) -> Left (Trap "cannot compare host ops")
  (_, VHostOp {}) -> Left (Trap "cannot compare host ops")
  (VRecord fs, VRecord gs) ->
    let fs' = Map.toList (Map.fromList fs)
        gs' = Map.toList (Map.fromList gs)
     in if map fst fs' /= map fst gs'
          then Right False
          else and <$> traverse (uncurry valueEq) (zip (map snd fs') (map snd gs'))
  (VList xs, VList ys)
    | length xs /= length ys -> Right False
    | otherwise -> and <$> traverse (uncurry valueEq) (zip xs ys)
  (VVariant t1 m1, VVariant t2 m2)
    | t1 /= t2 -> Right False
    | otherwise -> case (m1, m2) of
        (Nothing, Nothing) -> Right True
        (Just x, Just y) -> valueEq x y
        _ -> Right False
  _ -> Right (a == b)

arityOrType :: Text -> Int -> [Value] -> Either EvalError Value
arityOrType name n args
  | length args /= n =
      Left (Trap ("wrong arity for " <> name <> ": expected " <> T.pack (show n)))
  | otherwise = Left (Trap ("type mismatch for " <> name))
