-- | Reflect a type expression as JSON Schema (types §4).
module Hwfl.Check.Schema
  ( typeToSchema,
    typeToSchemaWithDocs,
    schemaType,
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Vector qualified as V
import Hwfl.Ast.Module (SchemaDoc (..))
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Ast.Type (TypeExpr (..))
import Hwfl.Check.Env (TypeEnv, isPrimitive, lookupAlias)
import Hwfl.Check.Error (CheckError (..))

-- | Type of @schema(T)@ expressions.
schemaType :: TypeExpr
schemaType = TName (TypeName "Schema")

-- | Compile-time JSON Schema for records, lists, and base types.
typeToSchema :: TypeEnv -> TypeExpr -> Either CheckError Value
typeToSchema env = typeToSchemaWithDocs env []

typeToSchemaWithDocs :: TypeEnv -> [SchemaDoc] -> TypeExpr -> Either CheckError Value
typeToSchemaWithDocs env docs te = go [] te
  where
    fieldDocMap =
      Map.fromList
        [ (tyName, Map.fromList fieldDocs)
          | SchemaDoc tyName fieldDocs <- docs
        ]

    go stack = \case
      TName tyName
        | isPrimitive tyName -> baseSchema (unTypeName tyName)
        | tyName `elem` stack -> Left (AliasCycle (reverse (tyName : stack)))
        | otherwise -> case lookupAlias tyName env of
            Nothing -> Left (UnboundType tyName)
            Just t -> do
              schema <- go (tyName : stack) t
              pure (annotateFields tyName schema)
      TList e -> do
        items <- go stack e
        pure $ object ["type" .= String "array", "items" .= items]
      TOption e -> do
        inner <- go stack e
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
        ok <- go stack a
        err <- go stack b
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
      TSecret e -> go stack e
      TRecord fs -> do
        propPairs <- traverse (\(Ident k, ty) -> (k,) <$> go stack ty) fs
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

    annotateFields tyName schema = case Map.lookup tyName fieldDocMap of
      Just docsForType -> applyFieldDocs docsForType schema
      Nothing -> schema

arrStr :: [Text] -> Value
arrStr xs = Array (V.fromList (map String xs))

applyFieldDocs :: Map Ident Text -> Value -> Value
applyFieldDocs docs = \case
  Object o -> case KM.lookup "properties" o of
    Just (Object props) ->
      Object (KM.insert "properties" (Object (foldr annotateOne props (Map.toList docs))) o)
    _ -> Object o
  other -> other
  where
    annotateOne (Ident field, desc) props = case KM.lookup (Key.fromText field) props of
      Just (Object fieldSchema) ->
        KM.insert
          (Key.fromText field)
          (Object (KM.insert "description" (String desc) fieldSchema))
          props
      _ -> props

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
