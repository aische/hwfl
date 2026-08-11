-- | Encode runtime 'Value's as JSON text (for reports, tool args, etc.).
module Hwfl.Json.Encode
  ( valueToJsonText,
    valueToAeson,
    jsonToValue,
    jsonToValueWithSchema,
    schemaForProvider,
  )
where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Map.Strict qualified as Map
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Hwfl.Ast.Name (Ident (..), TypeName (..), qnameToText)
import Hwfl.Eval.Value (ToolSpecValue (..), Value (..), hostOpName)
import Hwfl.Json.Validate (validateAgainstSchema)
import Hwfl.Runtime.Turn (turnToJson)

valueToJsonText :: Value -> Either Text Text
valueToJsonText v = do
  json <- valueToAeson v
  pure (TE.decodeUtf8 (BL.toStrict (Aeson.encode json)))

-- | Decode JSON numbers without losing integral precision. JSON numbers may
-- exceed the finite range of hwfl's 'Double'-backed 'Float'; reject those
-- non-integral values rather than constructing an invalid runtime value.
jsonToValue :: Aeson.Value -> Either Text Value
jsonToValue = \case
  Aeson.Null -> Right VUnit
  Aeson.Bool b -> Right (VBool b)
  Aeson.Number n -> case floatingOrInteger n :: Either Double Integer of
    Right i -> Right (VInt i)
    Left d ->
      if isNaN d || isInfinite d
        then Left ("JSON number is outside the supported Float range: " <> T.pack (show n))
        else Right (VFloat d)
  Aeson.String s -> Right (VString s)
  Aeson.Array xs -> VList <$> traverse jsonToValue (V.toList xs)
  Aeson.Object o ->
    VRecord <$> traverse decodeField (KM.toList o)
  where
    decodeField (k, v) = (Ident (Key.toText k),) <$> jsonToValue v

-- | Decode JSON while restoring @Secret@ / @Option@ structure carried by
-- internal schema annotations. Annotations are stripped before a schema crosses
-- a provider boundary; they exist only within the runtime and its snapshots.
jsonToValueWithSchema :: Aeson.Value -> Aeson.Value -> Either Text Value
jsonToValueWithSchema = go
  where
    go schema value = case schema of
      Aeson.Object o
        | KM.lookup "x-hwfl-secret" o == Just (Aeson.Bool True) ->
            VSecret <$> go (Aeson.Object (KM.delete "x-hwfl-secret" o)) value
        | KM.lookup "x-hwfl-option" o == Just (Aeson.Bool True) ->
            decodeOption (Aeson.Object (KM.delete "x-hwfl-option" o)) value
        | Just (Aeson.Array alternatives) <- KM.lookup "anyOf" o ->
            decodeAlternative alternatives value
        | Just (Aeson.Array alternatives) <- KM.lookup "oneOf" o ->
            decodeAlternative alternatives value
        | Just (Aeson.String "array") <- KM.lookup "type" o ->
            case (KM.lookup "items" o, value) of
              (Just items, Aeson.Array xs) -> VList <$> traverse (go items) (V.toList xs)
              _ -> jsonToValue value
        | Just (Aeson.String "object") <- KM.lookup "type" o ->
            case (KM.lookup "properties" o, value) of
              (Just (Aeson.Object properties), Aeson.Object fields) ->
                decodeObject properties fields
              _ -> jsonToValue value
      _ -> jsonToValue value

    decodeOption schemaWithoutMark value = case value of
      Aeson.Null -> Right vNone
      _ -> do
        inner <- optionInnerSchema schemaWithoutMark
        vSome <$> go inner value

    decodeObject properties fields = do
      fromSchema <-
        traverse
          ( \(k, propSchema) ->
              let name = Ident (Key.toText k)
               in case KM.lookup k fields of
                    Just v -> (name,) <$> go propSchema v
                    Nothing
                      | isOptionSchema propSchema ->
                          Right (name, vNone)
                      | otherwise ->
                          Left ("missing required field " <> Key.toText k)
          )
          (KM.toList properties)
      -- Validation rejects additionalProperties:false extras; keep any leftover
      -- keys so free-form / partially schema'd objects still round-trip.
      extras <-
        traverse
          ( \(k, v) ->
              (Ident (Key.toText k),) <$> jsonToValue v
          )
          [ (k, v)
            | (k, v) <- KM.toList fields,
              not (KM.member k properties)
          ]
      pure (VRecord (fromSchema <> extras))

    decodeAlternative alternatives value =
      case [schema | schema <- V.toList alternatives, Right () <- [validateAgainstSchema schema value]] of
        [schema] -> go schema value
        -- 'anyOf' permits more than one matching alternative; all emitted
        -- alternatives have equivalent JSON representation here, so select
        -- the first valid branch.
        schema : _ -> go schema value
        [] -> jsonToValue value

vNone :: Value
vNone = VVariant (TypeName "None") Nothing

vSome :: Value -> Value
vSome v = VVariant (TypeName "Some") (Just v)

isOptionSchema :: Aeson.Value -> Bool
isOptionSchema = \case
  Aeson.Object o -> KM.lookup "x-hwfl-option" o == Just (Aeson.Bool True)
  _ -> False

optionInnerSchema :: Aeson.Value -> Either Text Aeson.Value
optionInnerSchema = \case
  Aeson.Object o
    | Just (Aeson.Array alts) <- KM.lookup "anyOf" o ->
        case [s | s <- V.toList alts, not (isNullTypeSchema s)] of
          s : _ -> Right s
          [] -> Left "Option schema is missing an inner type"
  _ -> Left "malformed Option schema"

isNullTypeSchema :: Aeson.Value -> Bool
isNullTypeSchema = \case
  Aeson.Object o -> KM.lookup "type" o == Just (Aeson.String "null")
  _ -> False

-- | Remove hwfl-only schema annotations before serializing a request to an
-- external JSON Schema consumer.
schemaForProvider :: Aeson.Value -> Aeson.Value
schemaForProvider = \case
  Aeson.Object o ->
    Aeson.Object
      ( KM.fromList
          [ (k, schemaForProvider v)
            | (k, v) <- KM.toList o,
              k /= "x-hwfl-secret",
              k /= "x-hwfl-option"
          ]
      )
  Aeson.Array xs -> Aeson.Array (fmap schemaForProvider xs)
  value -> value

-- | Encode a runtime value as JSON. Non-finite IEEE floats have no JSON
-- representation, so reject them instead of letting Aeson throw later.
-- @None@/@Some@ use JSON null / unwrapped payload (types §6); other variants
-- keep the tagged object encoding.
valueToAeson :: Value -> Either Text Aeson.Value
valueToAeson = \case
  VUnit -> Right Aeson.Null
  VBool b -> Right (Aeson.Bool b)
  VInt n -> Right (Aeson.Number (fromIntegral n))
  VFloat d
    | isNaN d || isInfinite d -> Left "cannot encode a non-finite Float as JSON"
    | otherwise -> Right (Aeson.Number (realToFrac d))
  VString s -> Right (Aeson.String s)
  VList xs -> Aeson.Array . V.fromList <$> traverse valueToAeson xs
  VRecord fs
    | length fs /= Map.size (Map.fromList fs) ->
        Left "duplicate record field in JSON encode"
    | otherwise -> Aeson.Object . KM.fromList <$> traverse encodeField fs
  VVariant (TypeName "None") Nothing -> Right Aeson.Null
  VVariant (TypeName "Some") (Just p) -> valueToAeson p
  VVariant (TypeName "Some") Nothing -> Left "Some requires a payload"
  -- Nullary and payload variants both use tagged objects so a schema-free
  -- encode→decode never collapses a unit tag into VString.
  VVariant (TypeName tag) Nothing ->
    Right (object ["tag" .= Aeson.String tag])
  VVariant (TypeName tag) (Just p) -> do
    payload <- valueToAeson p
    pure (object ["tag" .= Aeson.String tag, "value" .= payload])
  VSecret _ -> Right (Aeson.String "[REDACTED]")
  VClosure {} -> Right (Aeson.String "<closure>")
  VTopFun (Ident n) -> Right (Aeson.String ("<fun:" <> n <> ">"))
  VLibFun q (Ident n) ->
    Right (Aeson.String ("<libfun:" <> qnameToText q <> "." <> n <> ">"))
  VBuiltin {} -> Right (Aeson.String "<builtin>")
  VHostOp op -> Right (Aeson.String ("<" <> hostOpName op <> ">"))
  VToolSpec ts -> Right (Aeson.String ("<tool:" <> ts.tvsName <> ">"))
  VSkillMain q -> Right (Aeson.String ("<skill:" <> qnameToText q <> ">"))
  VEntryMain q -> Right (Aeson.String ("<entry:" <> qnameToText q <> ">"))
  VSchema schema -> Right schema
  VTurn t -> Right (turnToJson t)
  VMcpTool server name _ -> Right (Aeson.String ("<mcp_tool:" <> server <> "/" <> name <> ">"))
  where
    encodeField (Ident name, value) =
      (Key.fromText name,) <$> valueToAeson value
