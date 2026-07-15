-- | Top-level declarations and module bodies inside @```pml@ fences.
module Pml.Ast.Decl
  ( Decl (..),
    ModuleBody (..),
  )
where

import Pml.Ast.Expr (Expr, Param)
import Pml.Ast.Name (Ident, TypeName)
import Pml.Ast.Type (TypeExpr)

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
