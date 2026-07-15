-- | Reflect a type expression as JSON Schema (types §4).
module Pml.Check.Schema
  ( typeToSchema,
    schemaType,
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Text (Text)
import Data.Vector qualified as V
import Pml.Ast.Name (Ident (..), TypeName (..))
import Pml.Ast.Type (TypeExpr (..))
import Pml.Check.Env (TypeEnv, resolveType)
import Pml.Check.Error (CheckError (..))

-- | Type of @schema(T)@ expressions.
schemaType :: TypeExpr
schemaType = TName (TypeName "Schema")

-- | Compile-time JSON Schema for records, lists, and base types.
typeToSchema :: TypeEnv -> TypeExpr -> Either CheckError Value
typeToSchema env te = do
  t <- resolveType env te
  go t
  where
    go = \case
      TName (TypeName n) -> baseSchema n
      TList e -> do
        items <- go e
        pure $ object ["type" .= String "array", "items" .= items]
      TOption e -> do
        inner <- go e
        pure $
          object
            [ "anyOf"
                .= Array
                  ( V.fromList
                      [ inner,
                        object ["type" .= String "null"]
                      ]
                  )
            ]
      TResult a b -> do
        ok <- go a
        err <- go b
        pure $
          object
            [ "oneOf"
                .= Array
                  ( V.fromList
                      [ object
                          [ "type" .= String "object",
                            "required" .= arrStr ["ok"],
                            "properties" .= object ["ok" .= ok]
                          ],
                        object
                          [ "type" .= String "object",
                            "required" .= arrStr ["err"],
                            "properties" .= object ["err" .= err]
                          ]
                      ]
                  )
            ]
      TSecret e -> go e
      TRecord fs -> do
        propPairs <- traverse (\(Ident k, ty) -> (k,) <$> go ty) fs
        let required = arrStr [k | (Ident k, _) <- fs]
            props = object [Key.fromText k .= v | (k, v) <- propPairs]
        pure $
          object
            [ "type" .= String "object",
              "properties" .= props,
              "required" .= required,
              "additionalProperties" .= False
            ]
      TFun {} -> Left (SchemaUnsupported te)
      TEffFun {} -> Left (SchemaUnsupported te)

arrStr :: [Text] -> Value
arrStr xs = Array (V.fromList (map String xs))

baseSchema :: Text -> Either CheckError Value
baseSchema = \case
  "Unit" -> Right $ object ["type" .= String "null"]
  "Bool" -> Right $ object ["type" .= String "boolean"]
  "Int" -> Right $ object ["type" .= String "integer"]
  "Float" -> Right $ object ["type" .= String "number"]
  "String" -> Right $ object ["type" .= String "string"]
  "Bytes" ->
    Right $
      object
        [ "type" .= String "string",
          "contentEncoding" .= String "base64"
        ]
  "Json" -> Right $ Object mempty
  "FileRef" -> Right $ object ["type" .= String "string"]
  "Schema" -> Right $ object ["type" .= String "object"]
  "ToolSpec" -> Right $ object ["type" .= String "object"]
  "Error" -> Right $ object ["type" .= String "string"]
  other -> Left (SchemaUnsupported (TName (TypeName other)))
