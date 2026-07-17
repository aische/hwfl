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
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Hwfl.Ast.Name (Ident (..), TypeName (..), qnameToText)
import Hwfl.Eval.Value (ToolSpecValue (..), Value (..), hostOpName)

valueToJsonText :: Value -> Text
valueToJsonText v =
  TE.decodeUtf8 (BL.toStrict (Aeson.encode (valueToAeson v)))

jsonToValue :: Aeson.Value -> Value
jsonToValue = \case
  Aeson.Null -> VUnit
  Aeson.Bool b -> VBool b
  Aeson.Number n ->
    let d = realToFrac n :: Double
        i = round d :: Integer
     in if fromIntegral i == d then VInt i else VFloat d
  Aeson.String s -> VString s
  Aeson.Array xs -> VList (map jsonToValue (V.toList xs))
  Aeson.Object o ->
    VRecord [(Ident (Key.toText k), jsonToValue v) | (k, v) <- KM.toList o]

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
  VSchema schema -> schema
