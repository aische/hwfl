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

-- | Decode JSON while restoring @Secret@ taint carried by an internal schema
-- annotation. The annotation is deliberately removed before a schema crosses
-- a provider boundary; it exists only within the runtime and its snapshots.
jsonToValueWithSchema :: Aeson.Value -> Aeson.Value -> Either Text Value
jsonToValueWithSchema = go
  where
    go schema value = case schema of
      Aeson.Object o
        | KM.lookup "x-hwfl-secret" o == Just (Aeson.Bool True) ->
            VSecret <$> go (Aeson.Object (KM.delete "x-hwfl-secret" o)) value
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
                VRecord
                  <$> traverse
                    (\(k, v) -> (Ident (Key.toText k),) <$> maybe (jsonToValue v) (`go` v) (KM.lookup k properties))
                    (KM.toList fields)
              _ -> jsonToValue value
      _ -> jsonToValue value

    decodeAlternative alternatives value =
      case [schema | schema <- V.toList alternatives, Right () <- [validateAgainstSchema schema value]] of
        [schema] -> go schema value
        -- 'anyOf' permits more than one matching alternative; all emitted
        -- alternatives have equivalent JSON representation here, so select
        -- the first valid branch.
        schema : _ -> go schema value
        [] -> jsonToValue value

-- | Remove hwfl-only schema annotations before serializing a request to an
-- external JSON Schema consumer.
schemaForProvider :: Aeson.Value -> Aeson.Value
schemaForProvider = \case
  Aeson.Object o ->
    Aeson.Object
      ( KM.fromList
          [ (k, schemaForProvider v)
            | (k, v) <- KM.toList o,
              k /= "x-hwfl-secret"
          ]
      )
  Aeson.Array xs -> Aeson.Array (fmap schemaForProvider xs)
  value -> value

-- | Encode a runtime value as JSON. Non-finite IEEE floats have no JSON
-- representation, so reject them instead of letting Aeson throw later.
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
  VRecord fs -> Aeson.Object . KM.fromList <$> traverse encodeField fs
  VVariant (TypeName tag) Nothing -> Right (Aeson.String tag)
  VVariant (TypeName tag) (Just p) -> do
    payload <- valueToAeson p
    pure (object ["tag" .= Aeson.String tag, "value" .= payload])
  VSecret _ -> Right (Aeson.String "[REDACTED]")
  VClosure {} -> Right (Aeson.String "<closure>")
  VTopFun (Ident n) -> Right (Aeson.String ("<fun:" <> n <> ">"))
  VBuiltin {} -> Right (Aeson.String "<builtin>")
  VHostOp op -> Right (Aeson.String ("<" <> hostOpName op <> ">"))
  VToolSpec ts -> Right (Aeson.String ("<tool:" <> ts.tvsName <> ">"))
  VSkillMain q -> Right (Aeson.String ("<skill:" <> qnameToText q <> ">"))
  VEntryMain q -> Right (Aeson.String ("<entry:" <> qnameToText q <> ">"))
  VSchema schema -> Right schema
  VTurn t -> Right (turnToJson t)
  where
    encodeField (Ident name, value) =
      (Key.fromText name,) <$> valueToAeson value
