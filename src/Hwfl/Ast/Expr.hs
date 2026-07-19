{-# LANGUAGE PatternSynonyms #-}

-- | Kernel expressions (spec §02, grammar Expr).
--
-- Each 'Expr' carries a source 'Pos' (file-absolute when loaded from a markdown
-- fence). 'Eq' ignores positions so pretty round-trips and closure equality stay
-- stable. Bidirectional pattern synonyms keep the historical @ELit@ / @EVar@
-- surface; parsers should stamp positions via 'atPos' / 'located'.
module Hwfl.Ast.Expr
  ( Expr (.., ELit, EVar, EQName, ESection, EList, ERecord, EInterp, EApp, EProj, EIndex, ELet, EFun, EIf, EMatch, EPar, EJoin, EConfirm, ETry, ESchema),
    ExprF (..),
    Arg (..),
    MatchArm (..),
    ParOpt (..),
    StringPart (..),
    Field (..),
    Param (..),
    noPos,
    atPos,
    exprPos,
  )
where

import Data.Text (Text)
import Hwfl.Ast.Name (Ident, QName, Slug)
import Hwfl.Ast.Pat (Literal, Pattern)
import Hwfl.Ast.Type (TypeExpr)
import Hwfl.Source (Pos (..))

data Param = Param
  { paramName :: Ident,
    paramType :: Maybe TypeExpr
  }
  deriving stock (Eq, Show, Read)

data StringPart
  = SLit Text
  | SInterp Expr
  deriving stock (Eq, Show, Read)

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

-- | Position-free expression node.
data ExprF
  = FLit Literal
  | FVar Ident
  | FQName QName
  | FSection Slug
  | FList [Expr]
  | FRecord [Field]
  | FInterp [StringPart]
  | FApp Expr [Arg]
  | FProj Expr Ident
  | FIndex Expr Expr
  | FLet Ident (Maybe TypeExpr) Expr Expr
  | FFun [Param] (Maybe TypeExpr) Expr
  | FIf Expr Expr Expr
  | FMatch Expr [MatchArm]
  | FPar [ParOpt] Ident Expr Expr
  | FJoin [Expr]
  | FConfirm Expr
  | FTry Expr Ident Expr
  | -- | Check-time schema reflection: @schema(T)@ (types §4).
    FSchema TypeExpr
  deriving stock (Eq, Show, Read)

-- | Located expression. Equality ignores 'ePos'.
data Expr = Expr
  { ePos :: !Pos,
    eKind :: !ExprF
  }
  deriving stock (Show, Read)

instance Eq Expr where
  a == b = a.eKind == b.eKind

-- | Placeholder position for synthetic nodes and test fixtures.
noPos :: Pos
noPos = Pos 1 1

atPos :: Pos -> Expr -> Expr
atPos p e = e {ePos = p}

exprPos :: Expr -> Pos
exprPos = ePos

pattern ELit :: Literal -> Expr
pattern ELit l <- Expr _ (FLit l)
  where
    ELit l = Expr noPos (FLit l)

pattern EVar :: Ident -> Expr
pattern EVar n <- Expr _ (FVar n)
  where
    EVar n = Expr noPos (FVar n)

pattern EQName :: QName -> Expr
pattern EQName q <- Expr _ (FQName q)
  where
    EQName q = Expr noPos (FQName q)

pattern ESection :: Slug -> Expr
pattern ESection s <- Expr _ (FSection s)
  where
    ESection s = Expr noPos (FSection s)

pattern EList :: [Expr] -> Expr
pattern EList es <- Expr _ (FList es)
  where
    EList es = Expr noPos (FList es)

pattern ERecord :: [Field] -> Expr
pattern ERecord fs <- Expr _ (FRecord fs)
  where
    ERecord fs = Expr noPos (FRecord fs)

pattern EInterp :: [StringPart] -> Expr
pattern EInterp ps <- Expr _ (FInterp ps)
  where
    EInterp ps = Expr noPos (FInterp ps)

pattern EApp :: Expr -> [Arg] -> Expr
pattern EApp f args <- Expr _ (FApp f args)
  where
    EApp f args = Expr noPos (FApp f args)

pattern EProj :: Expr -> Ident -> Expr
pattern EProj e n <- Expr _ (FProj e n)
  where
    EProj e n = Expr noPos (FProj e n)

pattern EIndex :: Expr -> Expr -> Expr
pattern EIndex e i <- Expr _ (FIndex e i)
  where
    EIndex e i = Expr noPos (FIndex e i)

pattern ELet :: Ident -> Maybe TypeExpr -> Expr -> Expr -> Expr
pattern ELet n mt e1 e2 <- Expr _ (FLet n mt e1 e2)
  where
    ELet n mt e1 e2 = Expr noPos (FLet n mt e1 e2)

pattern EFun :: [Param] -> Maybe TypeExpr -> Expr -> Expr
pattern EFun ps mt body <- Expr _ (FFun ps mt body)
  where
    EFun ps mt body = Expr noPos (FFun ps mt body)

pattern EIf :: Expr -> Expr -> Expr -> Expr
pattern EIf c t e <- Expr _ (FIf c t e)
  where
    EIf c t e = Expr noPos (FIf c t e)

pattern EMatch :: Expr -> [MatchArm] -> Expr
pattern EMatch s arms <- Expr _ (FMatch s arms)
  where
    EMatch s arms = Expr noPos (FMatch s arms)

pattern EPar :: [ParOpt] -> Ident -> Expr -> Expr -> Expr
pattern EPar opts n xs body <- Expr _ (FPar opts n xs body)
  where
    EPar opts n xs body = Expr noPos (FPar opts n xs body)

pattern EJoin :: [Expr] -> Expr
pattern EJoin es <- Expr _ (FJoin es)
  where
    EJoin es = Expr noPos (FJoin es)

pattern EConfirm :: Expr -> Expr
pattern EConfirm e <- Expr _ (FConfirm e)
  where
    EConfirm e = Expr noPos (FConfirm e)

pattern ETry :: Expr -> Ident -> Expr -> Expr
pattern ETry e n h <- Expr _ (FTry e n h)
  where
    ETry e n h = Expr noPos (FTry e n h)

pattern ESchema :: TypeExpr -> Expr
pattern ESchema t <- Expr _ (FSchema t)
  where
    ESchema t = Expr noPos (FSchema t)

{-# COMPLETE
  ELit,
  EVar,
  EQName,
  ESection,
  EList,
  ERecord,
  EInterp,
  EApp,
  EProj,
  EIndex,
  ELet,
  EFun,
  EIf,
  EMatch,
  EPar,
  EJoin,
  EConfirm,
  ETry,
  ESchema
  #-}
