-- | Pretty-print kernel AST (for golden round-trips and diagnostics).
module Hwfl.Ast.Pretty
  ( prettyExpr,
    prettyType,
    prettyPat,
    prettyDecl,
    prettyModuleBody,
    prettyLiteral,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Decl (Decl (..), ModuleBody (..))
import Hwfl.Ast.Expr
import Hwfl.Ast.Name
import Hwfl.Ast.Pat
import Hwfl.Ast.Type

prettyModuleBody :: ModuleBody -> Text
prettyModuleBody (ModuleBody ds me) =
  T.intercalate "\n" (map prettyDecl ds ++ maybe [] (pure . prettyExpr) me)

prettyDecl :: Decl -> Text
prettyDecl = \case
  DType _ n t -> "type " <> unTypeName n <> " = " <> prettyType t
  DFun _ n ps mt e ->
    "fun "
      <> unIdent n
      <> prettyParams ps
      <> prettyAnn mt
      <> " =\n  "
      <> indentRest (prettyExpr e)

prettyParams :: [Param] -> Text
prettyParams ps =
  "(" <> T.intercalate ", " (map prettyParam ps) <> ")"

prettyParam :: Param -> Text
prettyParam (Param n mt) = unIdent n <> prettyAnn mt

prettyAnn :: Maybe TypeExpr -> Text
prettyAnn = maybe "" (\t -> ": " <> prettyType t)

prettyType :: TypeExpr -> Text
prettyType = \case
  TName n -> unTypeName n
  TList t -> "List<" <> prettyType t <> ">"
  TOption t -> "Option<" <> prettyType t <> ">"
  TResult a b -> "Result<" <> prettyType a <> ", " <> prettyType b <> ">"
  TSecret t -> "Secret<" <> prettyType t <> ">"
  TRecord fs ->
    "{ "
      <> T.intercalate ", " [unIdent n <> ": " <> prettyType t | (n, t) <- fs]
      <> " }"
  TFun a b -> prettyTypeAtom a <> " -> " <> prettyType b
  TEffFun a es b ->
    prettyTypeAtom a
      <> "-["
      <> T.intercalate ", " (map effectName es)
      <> "]->"
      <> prettyType b

prettyTypeAtom :: TypeExpr -> Text
prettyTypeAtom t = case t of
  TFun {} -> "(" <> prettyType t <> ")"
  TEffFun {} -> "(" <> prettyType t <> ")"
  _ -> prettyType t

prettyPat :: Pattern -> Text
prettyPat = \case
  PWild -> "_"
  PVar n -> unIdent n
  PLit l -> prettyLiteral l
  PTag n Nothing -> unTypeName n
  PTag n (Just p) -> unTypeName n <> "(" <> prettyPat p <> ")"
  PRecord fs ->
    "{ " <> T.intercalate ", " [unIdent n <> " = " <> prettyPat p | (n, p) <- fs] <> " }"
  PList ps -> "[" <> T.intercalate ", " (map prettyPat ps) <> "]"

prettyLiteral :: Literal -> Text
prettyLiteral = \case
  LUnit -> "()"
  LBool True -> "true"
  LBool False -> "false"
  LInt n -> T.pack (show n)
  LFloat d -> T.pack (show d)
  LString s -> "\"" <> escapeString s <> "\""

prettyExpr :: Expr -> Text
prettyExpr = prettyExprPrec 0

prettyExprPrec :: Int -> Expr -> Text
prettyExprPrec prec = \case
  ELit l -> prettyLiteral l
  EVar n -> unIdent n
  EQName q -> qnameToText q
  ESection s -> "@" <> unSlug s
  EList es -> "[" <> T.intercalate ", " (map prettyExpr es) <> "]"
  ERecord fs -> "{ " <> T.intercalate ", " (map prettyField fs) <> " }"
  EInterp parts -> "$\"" <> T.concat (map prettyPart parts) <> "\""
  e@EApp {} -> parenIf (prec > 10) (prettyApp e)
  e@EProj {} -> parenIf (prec > 10) (prettyApp e)
  e@EIndex {} -> parenIf (prec > 10) (prettyApp e)
  ELet n mt e1 e2 ->
    parenIf (prec > 0) $
      "let " <> unIdent n <> prettyAnn mt <> " = " <> prettyExpr e1 <> " in " <> prettyExpr e2
  EFun ps mt body ->
    parenIf (prec > 0) $
      "fun " <> prettyParams ps <> prettyAnn mt <> " => " <> prettyExpr body
  EIf c t e ->
    parenIf (prec > 0) $
      "if " <> prettyExpr c <> " then " <> prettyExpr t <> " else " <> prettyExpr e
  EMatch s arms ->
    parenIf (prec > 0) $
      "match " <> prettyExpr s <> " with" <> T.concat (map prettyArm arms)
  EPar opts n xs body ->
    parenIf (prec > 0) $
      "par"
        <> prettyParOpts opts
        <> " for "
        <> unIdent n
        <> " in "
        <> prettyExpr xs
        <> " { "
        <> prettyExpr body
        <> " }"
  EJoin tasks ->
    parenIf (prec > 0) $
      "join { " <> T.intercalate " " ["task { " <> prettyExpr t <> " }" | t <- tasks] <> " }"
  EConfirm e -> parenIf (prec > 0) ("confirm " <> prettyExprPrec 10 e)
  EChoice e -> parenIf (prec > 0) ("choice " <> prettyExprPrec 10 e)
  ETry e n h ->
    parenIf (prec > 0) $
      "try " <> prettyExpr e <> " catch (" <> unIdent n <> ") => " <> prettyExpr h
  ESchema t -> "schema(" <> prettyType t <> ")"

prettyField :: Field -> Text
prettyField = \case
  Field n e -> unIdent n <> " = " <> prettyExpr e
  FieldShorthand n -> unIdent n

prettyPart :: StringPart -> Text
prettyPart = \case
  SLit t -> escapeInterp t
  SInterp e -> "{" <> prettyExpr e <> "}"

prettyArm :: MatchArm -> Text
prettyArm (MatchArm p e) = " | " <> prettyPat p <> " => " <> prettyExpr e

prettyParOpts :: [ParOpt] -> Text
prettyParOpts [] = ""
prettyParOpts opts =
  "(" <> T.intercalate ", " (map prettyOpt opts) <> ")"
  where
    prettyOpt = \case
      ParMax n -> "max = " <> T.pack (show n)
      ParOnError s -> "on_error = \"" <> escapeString s <> "\""

prettyApp :: Expr -> Text
prettyApp = go
  where
    go (EApp f args) = go f <> "(" <> T.intercalate ", " (map prettyArg args) <> ")"
    go (EProj e n) = go e <> "." <> unIdent n
    go (EIndex e i) = go e <> "[" <> prettyExpr i <> "]"
    go e = prettyExprPrec 10 e

prettyArg :: Arg -> Text
prettyArg = \case
  ArgPos e -> prettyExpr e
  ArgNamed n e -> unIdent n <> " = " <> prettyExpr e

parenIf :: Bool -> Text -> Text
parenIf True t = "(" <> t <> ")"
parenIf False t = t

indentRest :: Text -> Text
indentRest = T.replace "\n" "\n  "

escapeString :: Text -> Text
escapeString = T.concatMap $ \case
  '"' -> "\\\""
  '\\' -> "\\\\"
  '\n' -> "\\n"
  '\t' -> "\\t"
  c -> T.singleton c

escapeInterp :: Text -> Text
escapeInterp = T.concatMap $ \case
  '"' -> "\\\""
  '\\' -> "\\\\"
  '\n' -> "\\n"
  '{' -> "\\{"
  c -> T.singleton c
