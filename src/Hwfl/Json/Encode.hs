-- | Encode runtime 'Value's as JSON text (for reports, tool args, etc.).
module Hwfl.Json.Encode
  ( valueToJsonText,
    valueToAeson,
    jsonToValue,
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
import Hwfl.Runtime.Turn (turnToJson)

valueToJsonText :: Value -> Text
valueToJsonText v =
  TE.decodeUtf8 (BL.toStrict (Aeson.encode (valueToAeson v)))

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

valueToAeson :: Value -> Aeson.Value
valueToAeson = \case
  VUnit -> Aeson.Null
  VBool b -> Aeson.Bool b
  VInt n -> Aeson.Number (fromIntegral n)
  VFloat d -> Aeson.Number (realToFrac d)
  VString s -> Aeson.String s
  VList xs -> Aeson.Array (V.fromList (map valueToAeson xs))
  VRecord fs -> object [Key.fromText (unIdent k) .= valueToAeson v | (k, v) <- fs]
  VVariant (TypeName tag) Nothing -> Aeson.String tag
  VVariant (TypeName tag) (Just p) ->
    object ["tag" .= Aeson.String tag, "value" .= valueToAeson p]
  VSecret _ -> Aeson.String "[REDACTED]"
  VClosure {} -> Aeson.String "<closure>"
  VTopFun (Ident n) -> Aeson.String ("<fun:" <> n <> ">")
  VBuiltin {} -> Aeson.String "<builtin>"
  VHostOp op -> Aeson.String ("<" <> hostOpName op <> ">")
  VToolSpec ts -> Aeson.String ("<tool:" <> ts.tvsName <> ">")
  VSkillMain q -> Aeson.String ("<skill:" <> qnameToText q <> ">")
  VEntryMain q -> Aeson.String ("<entry:" <> qnameToText q <> ">")
  VSchema schema -> schema
  VTurn t -> turnToJson t
