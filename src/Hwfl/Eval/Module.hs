-- | Bind top-level @fun@ decls from a 'ModuleBody' and invoke them.
module Hwfl.Eval.Module
  ( loadModuleBody,
    callFun,
    evalExpr,
  )
where

import Data.Map.Strict qualified as Map
import Hwfl.Ast.Decl (Decl (..), ModuleBody (..))
import Hwfl.Ast.Expr (Expr)
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Eval.Error (EvalError (..))
import Hwfl.Eval.Prelude (preludeEnv)
import Hwfl.Eval.Pure (applyValue, eval)
import Hwfl.Eval.Value

-- | Prelude ∪ top-level functions. Closures share one recursive env so
-- functions may call each other (v0 mutual recursion via knot-tying).
loadModuleBody :: ModuleBody -> Either EvalError Env
loadModuleBody (ModuleBody decls _) =
  let funs = [(n, ps, body) | DFun _ n ps _ body <- decls]
      env =
        Map.union
          ( Map.fromList
              [ (n, VClosure ps body env)
                | (n, ps, body) <- funs
              ]
          )
          preludeEnv
   in Right env

callFun :: Env -> Ident -> [Value] -> Either EvalError Value
callFun env name args = case lookupEnv name env of
  Nothing -> Left (Trap ("unknown function: " <> unIdent name))
  Just f -> applyValue f [(Nothing, a) | a <- args]

evalExpr :: Env -> Expr -> Either EvalError Value
evalExpr = eval
