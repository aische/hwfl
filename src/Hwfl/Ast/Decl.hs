-- | Top-level declarations and module bodies inside @```hwfl@ fences.
module Hwfl.Ast.Decl
  ( Decl (..),
    ModuleBody (..),
  )
where

import Hwfl.Ast.Expr (Expr, Param)
import Hwfl.Ast.Name (Ident, TypeName)
import Hwfl.Ast.Type (TypeExpr)

data Decl
  = DType TypeName TypeExpr
  | DFun Ident [Param] (Maybe TypeExpr) Expr
  deriving stock (Eq, Show)

-- | Fence contents: zero or more decls, optional trailing expression.
data ModuleBody = ModuleBody
  { mbDecls :: [Decl],
    mbExpr :: Maybe Expr
  }
  deriving stock (Eq, Show)
