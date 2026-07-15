-- | Static check errors (types §3 / language §8).
module Pml.Check.Error
  ( CheckError (..),
    renderCheckError,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Pml.Ast.Name (Ident (..), TypeName (..))
import Pml.Ast.Pretty (prettyType)
import Pml.Ast.Type (TypeExpr)

data CheckError
  = UnboundVar Ident
  | UnboundType TypeName
  | TypeMismatch TypeExpr TypeExpr
  | TypeMismatchMsg Text TypeExpr TypeExpr
  | ExpectedFunction TypeExpr
  | ExpectedRecord TypeExpr
  | ExpectedList TypeExpr
  | MissingField Ident TypeExpr
  | UnknownField Ident TypeExpr
  | ArityMismatch Int Int
  | MissingNamedArg Ident
  | MixedArgs
  | CannotInfer Text
  | NotRenderable TypeExpr
  | AliasCycle [TypeName]
  | DuplicateType TypeName
  | DuplicateFun Ident
  | MissingMain
  | MainParamMismatch TypeExpr TypeExpr
  | MainReturnMismatch TypeExpr TypeExpr
  | SchemaUnsupported TypeExpr
  | Unsupported Text
  deriving stock (Eq, Show)

renderCheckError :: CheckError -> Text
renderCheckError = \case
  UnboundVar n -> "unbound variable: " <> unIdent n
  UnboundType n -> "unbound type: " <> unTypeName n
  TypeMismatch a b ->
    "type mismatch: expected " <> prettyType a <> ", got " <> prettyType b
  TypeMismatchMsg msg a b ->
    msg <> ": expected " <> prettyType a <> ", got " <> prettyType b
  ExpectedFunction t -> "expected a function, got " <> prettyType t
  ExpectedRecord t -> "expected a record, got " <> prettyType t
  ExpectedList t -> "expected a list, got " <> prettyType t
  MissingField n t -> "missing field " <> unIdent n <> " in " <> prettyType t
  UnknownField n t -> "unknown field " <> unIdent n <> " in " <> prettyType t
  ArityMismatch e g ->
    "arity mismatch: expected " <> T.pack (show e) <> ", got " <> T.pack (show g)
  MissingNamedArg n -> "missing named argument: " <> unIdent n
  MixedArgs -> "cannot mix positional and named arguments"
  CannotInfer msg -> "cannot infer type: " <> msg
  NotRenderable t -> "value of type " <> prettyType t <> " is not renderable in interpolation"
  AliasCycle ns ->
    "cyclic type alias: " <> T.intercalate " -> " (map unTypeName ns)
  DuplicateType n -> "duplicate type declaration: " <> unTypeName n
  DuplicateFun n -> "duplicate function declaration: " <> unIdent n
  MissingMain -> "module has inputs/outputs but no fun main"
  MainParamMismatch want got ->
    "main parameter does not match frontmatter inputs: expected "
      <> prettyType want
      <> ", got "
      <> prettyType got
  MainReturnMismatch want got ->
    "main return type does not match frontmatter outputs: expected "
      <> prettyType want
      <> ", got "
      <> prettyType got
  SchemaUnsupported t -> "schema(" <> prettyType t <> ") is not supported"
  Unsupported msg -> "unsupported in type checker: " <> msg
