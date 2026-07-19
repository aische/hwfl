-- | Static check errors (types §3 / language §8).
module Hwfl.Check.Error
  ( CheckError (..),
    attachPos,
    errorPos,
    errorRoot,
    renderCheckError,
    renderCheckErrorRoot,
    renderLocatedCheckError,
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
import Hwfl.Source (Pos, renderPos)

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
  | -- | Source location wrapper. Innermost location wins under 'attachPos'.
    ErrAt Pos CheckError
  deriving stock (Eq, Show)

-- | Attach a position only when the error is not already located.
attachPos :: Pos -> CheckError -> CheckError
attachPos _ e@(ErrAt _ _) = e
attachPos p e = ErrAt p e

errorPos :: CheckError -> Maybe Pos
errorPos = \case
  ErrAt p _ -> Just p
  _ -> Nothing

errorRoot :: CheckError -> CheckError
errorRoot = \case
  ErrAt _ e -> errorRoot e
  e -> e

-- | Root message only (no @line:col@ prefix). Stable for JSON @message@.
renderCheckErrorRoot :: CheckError -> Text
renderCheckErrorRoot = renderCheckErrorRoot' . errorRoot

renderCheckErrorRoot' :: CheckError -> Text
renderCheckErrorRoot' = \case
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
  ErrAt _ e -> renderCheckErrorRoot' e

-- | Human-facing message with optional @line:col:@ prefix (no file path).
renderCheckError :: CheckError -> Text
renderCheckError err = case errorPos err of
  Just p -> renderPos p <> ": " <> renderCheckErrorRoot err
  Nothing -> renderCheckErrorRoot err

-- | @path:line:col: msg@ when located; @path: msg@ otherwise.
renderLocatedCheckError :: FilePath -> CheckError -> Text
renderLocatedCheckError path err = case errorPos err of
  Just p ->
    T.pack path <> ":" <> renderPos p <> ": " <> renderCheckErrorRoot err
  Nothing ->
    T.pack path <> ": " <> renderCheckErrorRoot err

renderEffSet :: Set Effect -> Text
renderEffSet es
  | Set.null es = "[]"
  | otherwise =
      "["
        <> T.intercalate ", " (map effectName (Set.toAscList es))
        <> "]"
