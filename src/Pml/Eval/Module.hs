-- | Bind top-level @fun@ decls from a 'ModuleBody' and invoke them.
module Pml.Eval.Module
  ( loadModuleBody,
    callFun,
    evalExpr,
  )
where

import Data.Map.Strict qualified as Map
import Pml.Ast.Decl (Decl (..), ModuleBody (..))
import Pml.Ast.Expr (Expr)
import Pml.Ast.Name (Ident (..))
import Pml.Eval.Error (EvalError (..))
import Pml.Eval.Prelude (preludeEnv)
import Pml.Eval.Pure (applyValue, eval)
import Pml.Eval.Value

-- | Prelude ∪ top-level functions. Closures share one recursive env so
-- functions may call each other (v0 mutual recursion via knot-tying).
loadModuleBody :: ModuleBody -> Either EvalError Env
loadModuleBody (ModuleBody decls _) =
  let funs = [(n, ps, body) | DFun n ps _ body <- decls]
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
