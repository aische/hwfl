-- | Machine-readable CLI error envelopes for @--json@ (spec §09).
module Hwfl.Cli.Json
  ( renderCliError,
    jsonCheckError,
    jsonCheckErrorAtPath,
    jsonProjectCheckError,
    jsonRuntimeError,
    jsonDiagnostics,
    jsonUsageError,
    jsonPlainError,
  )
where

import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hwfl.Check.Error qualified as CE
import Hwfl.Check.Project (ProjectCheckError (..))
import Hwfl.Eval.Error qualified as EE
import Hwfl.Runtime.Error (RuntimeError (..), renderRuntimeError)
import Hwfl.Source (Diagnostic (..), Pos (..))

renderCliError :: Value -> Text
renderCliError v =
  TE.decodeUtf8 (LBS.toStrict (Aeson.encode v))

jsonUsageError :: Text -> Value
jsonUsageError = jsonPlainError 2 "usage" "UsageError"

jsonPlainError :: Int -> Text -> Text -> Text -> Value
jsonPlainError exitCode category kind msg =
  errorEnvelope exitCode category kind msg []

jsonCheckError :: CE.CheckError -> Value
jsonCheckError = jsonCheckErrorAtPath Nothing

jsonCheckErrorAtPath :: Maybe FilePath -> CE.CheckError -> Value
jsonCheckErrorAtPath mPath err =
  errorEnvelope
    1
    "check"
    (checkErrorKind err)
    (CE.renderCheckError err)
    (maybe [] (\p -> [pathField p]) mPath)

jsonProjectCheckError :: ProjectCheckError -> Value
jsonProjectCheckError = \case
  PceLoad msg ->
    errorEnvelope 1 "project" "LoadError" msg []
  PceParse path diags ->
    object
      [ "status" .= ("error" :: Text),
        "exit_code" .= (1 :: Int),
        "category" .= ("parse" :: Text),
        "path" .= T.pack path,
        "diagnostics" .= map diagnosticJson diags
      ]
  PceModule path err ->
    errorEnvelope
      1
      "check"
      (checkErrorKind err)
      (CE.renderCheckError err)
      [pathField path]
  PceImportCycle qs ->
    errorEnvelope
      1
      "project"
      "ImportCycle"
      ("cyclic import: " <> T.intercalate " -> " qs)
      [(Key.fromText "cycle", toJSON qs)]
  PceImportNotFound path q ->
    errorEnvelope
      1
      "project"
      "ImportNotFound"
      (T.pack path <> ": import not found: " <> q)
      [pathField path, textField "module" q]
  PceQNameMismatch path fm pathQ ->
    errorEnvelope
      1
      "project"
      "QNameMismatch"
      ( T.pack path
          <> ": frontmatter name "
          <> fm
          <> " does not match file qname "
          <> pathQ
      )
      [pathField path, textField "frontmatter" fm, textField "qname" pathQ]
  PceEntryNotFound q ->
    errorEnvelope 1 "project" "EntryNotFound" ("entrypoint not found: " <> q) []
  PceSkill path msg ->
    errorEnvelope
      1
      "project"
      "SkillError"
      (T.pack path <> ": " <> msg)
      [pathField path]

jsonRuntimeError :: Int -> RuntimeError -> Value
jsonRuntimeError exitCode err =
  errorEnvelope
    exitCode
    "runtime"
    (runtimeErrorKind err)
    (renderRuntimeError err)
    []

jsonDiagnostics :: FilePath -> [Diagnostic] -> Value
jsonDiagnostics path diags =
  object
    [ "status" .= ("error" :: Text),
      "exit_code" .= (1 :: Int),
      "category" .= ("parse" :: Text),
      "path" .= T.pack path,
      "diagnostics" .= map diagnosticJson diags
    ]

errorEnvelope ::
  Int ->
  Text ->
  Text ->
  Text ->
  [(Key.Key, Value)] ->
  Value
errorEnvelope exitCode category kind msg extra =
  object
    ( [ Key.fromText "status" .= ("error" :: Text),
        Key.fromText "exit_code" .= exitCode,
        Key.fromText "category" .= category,
        Key.fromText "kind" .= kind,
        Key.fromText "message" .= msg
      ]
        ++ extra
    )

pathField :: FilePath -> (Key.Key, Value)
pathField p = (Key.fromText "path", toJSON (T.pack p))

textField :: Text -> Text -> (Key.Key, Value)
textField k v = (Key.fromText k, toJSON v)

diagnosticJson :: Diagnostic -> Value
diagnosticJson d =
  object
    [ "path" .= T.pack d.diagPath,
      "line" .= posLine d.diagPos,
      "column" .= posCol d.diagPos,
      "message" .= d.diagMessage
    ]

checkErrorKind :: CE.CheckError -> Text
checkErrorKind = \case
  CE.UnboundVar {} -> "UnboundVar"
  CE.UnboundType {} -> "UnboundType"
  CE.TypeMismatch {} -> "TypeMismatch"
  CE.TypeMismatchMsg {} -> "TypeMismatchMsg"
  CE.ExpectedFunction {} -> "ExpectedFunction"
  CE.ExpectedRecord {} -> "ExpectedRecord"
  CE.ExpectedList {} -> "ExpectedList"
  CE.MissingField {} -> "MissingField"
  CE.UnknownField {} -> "UnknownField"
  CE.ArityMismatch {} -> "ArityMismatch"
  CE.MissingNamedArg {} -> "MissingNamedArg"
  CE.MixedArgs -> "MixedArgs"
  CE.CannotInfer {} -> "CannotInfer"
  CE.NotRenderable {} -> "NotRenderable"
  CE.AliasCycle {} -> "AliasCycle"
  CE.DuplicateType {} -> "DuplicateType"
  CE.DuplicateFun {} -> "DuplicateFun"
  CE.MissingMain -> "MissingMain"
  CE.MainParamMismatch {} -> "MainParamMismatch"
  CE.MainReturnMismatch {} -> "MainReturnMismatch"
  CE.SchemaUnsupported {} -> "SchemaUnsupported"
  CE.EffectsNotAllowed {} -> "EffectsNotAllowed"
  CE.UnboundModule {} -> "UnboundModule"
  CE.ImportCycle {} -> "ImportCycle"
  CE.ImportNotFound {} -> "ImportNotFound"
  CE.QNameMismatch {} -> "QNameMismatch"
  CE.ExecNotConfigured -> "ExecNotConfigured"
  CE.Unsupported {} -> "Unsupported"

runtimeErrorKind :: RuntimeError -> Text
runtimeErrorKind = \case
  EvalErr (EE.Trap _) -> "EvalTrap"
  EvalErr (EE.Unsupported _) -> "EvalUnsupported"
  SandboxErr {} -> "SandboxErr"
  HostErr {} -> "HostErr"
  ProviderErr {} -> "ProviderErr"
  ConfigErr {} -> "ConfigErr"
