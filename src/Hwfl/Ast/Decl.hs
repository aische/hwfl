-- | Top-level declarations and module bodies inside @```hwfl@ fences.
module Hwfl.Ast.Decl
  ( Decl (..),
    ModuleBody (..),
    declPos,
  )
where

import Hwfl.Ast.Expr (Expr, Param)
import Hwfl.Ast.Name (Ident, TypeName)
import Hwfl.Ast.Type (TypeExpr)
import Hwfl.Source (Pos)

data Decl
  = DType !Pos TypeName TypeExpr
  | DFun !Pos Ident [Param] (Maybe TypeExpr) Expr
  deriving stock (Show)

instance Eq Decl where
  DType _ n t == DType _ n' t' = n == n' && t == t'
  DFun _ n ps mt b == DFun _ n' ps' mt' b' =
    n == n' && ps == ps' && mt == mt' && b == b'
  _ == _ = False

declPos :: Decl -> Pos
declPos = \case
  DType p _ _ -> p
  DFun p _ _ _ _ -> p

-- | Fence contents: zero or more decls, optional trailing expression.
data ModuleBody = ModuleBody
  { mbDecls :: [Decl],
    mbExpr :: Maybe Expr
  }
  deriving stock (Eq, Show)
