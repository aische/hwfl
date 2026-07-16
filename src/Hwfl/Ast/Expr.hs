-- | Kernel expressions (spec §02, grammar Expr).
module Hwfl.Ast.Expr
  ( Expr (..),
    Arg (..),
    MatchArm (..),
    ParOpt (..),
    StringPart (..),
    Field (..),
    Param (..),
  )
where

import Data.Text (Text)
import Hwfl.Ast.Name (Ident, QName, Slug)
import Hwfl.Ast.Pat (Literal, Pattern)
import Hwfl.Ast.Type (TypeExpr)

data Param = Param
  { paramName :: Ident,
    paramType :: Maybe TypeExpr
  }
  deriving stock (Eq, Show, Read)

data StringPart
  = SLit Text
  | SInterp Expr
  deriving stock (Eq, Show, Read)

-- | Record field in a literal: @name = e@ or shorthand @name@.
data Field
  = Field Ident Expr
  | FieldShorthand Ident
  deriving stock (Eq, Show, Read)

data Arg
  = ArgPos Expr
  | ArgNamed Ident Expr
  deriving stock (Eq, Show, Read)

data MatchArm = MatchArm
  { armPat :: Pattern,
    armBody :: Expr
  }
  deriving stock (Eq, Show, Read)

data ParOpt
  = ParMax Integer
  | ParOnError Text
  deriving stock (Eq, Show, Read)

data Expr
  = ELit Literal
  | EVar Ident
  | EQName QName
  | ESection Slug
  | EList [Expr]
  | ERecord [Field]
  | EInterp [StringPart]
  | EApp Expr [Arg]
  | EProj Expr Ident
  | EIndex Expr Expr
  | ELet Ident (Maybe TypeExpr) Expr Expr
  | EFun [Param] (Maybe TypeExpr) Expr
  | EIf Expr Expr Expr
  | EMatch Expr [MatchArm]
  | EPar [ParOpt] Ident Expr Expr
  | EJoin [Expr]
  | EConfirm Expr
  | ETry Expr Ident Expr
  | -- | Check-time schema reflection: @schema(T)@ (types §4).
    ESchema TypeExpr
  deriving stock (Eq, Show, Read)
