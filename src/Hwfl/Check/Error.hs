-- | Static check errors (types §3 / language §8).
module Hwfl.Check.Error
  ( CheckError (..),
    renderCheckError,
  )
where

import Data.Maybe (catMaybes)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Ast.Pretty (prettyType)
import Hwfl.Ast.Type (Effect, TypeExpr, effectName)

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
  | -- | Inferred effect set is not a subset of the declared ceiling.
    EffectsNotAllowed (Set Effect) (Set Effect)
  | UnboundModule Text
  | ImportCycle [Text]
  | ImportNotFound Text
  | QNameMismatch Text Text
  | ExecNotConfigured
  | -- | Frontmatter @examples@ entry keys do not match @inputs@ (missing / unknown).
    ExampleInputsMismatch (Maybe Text) [Ident] [Ident]
  | ExampleDuplicateName Text
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
  EffectsNotAllowed inferred declared ->
    "effects not allowed: inferred "
      <> renderEffSet inferred
      <> ", declared "
      <> renderEffSet declared
  UnboundModule q -> "unbound module import: " <> q
  ImportCycle qs ->
    "cyclic import: " <> T.intercalate " -> " qs
  ImportNotFound q -> "import not found: " <> q
  QNameMismatch path q ->
    "frontmatter name "
      <> q
      <> " does not match file qname "
      <> path
  ExecNotConfigured ->
    "Exec effect used but project.json exec.allow is absent or empty"
  ExampleInputsMismatch mName missing unknown ->
    let label = maybe "examples[]" (\n -> "examples[" <> n <> "]") mName
        parts =
          catMaybes
            [ if null missing
                then Nothing
                else Just ("missing keys: " <> T.intercalate ", " (map unIdent missing)),
              if null unknown
                then Nothing
                else Just ("unknown keys: " <> T.intercalate ", " (map unIdent unknown))
            ]
     in label
          <> " inputs do not match frontmatter inputs ("
          <> T.intercalate "; " parts
          <> ")"
  ExampleDuplicateName n ->
    "duplicate examples name: " <> n
  Unsupported msg -> "unsupported in type checker: " <> msg

renderEffSet :: Set Effect -> Text
renderEffSet es
  | Set.null es = "[]"
  | otherwise =
      "["
        <> T.intercalate ", " (map effectName (Set.toAscList es))
        <> "]"
