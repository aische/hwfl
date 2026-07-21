-- | Validate JSON values against the JSON Schema subset emitted by
-- 'Hwfl.Check.Schema.typeToSchema' (objects, arrays, scalars, anyOf/oneOf,
-- enum, additionalProperties).
module Hwfl.Json.Validate
  ( validateAgainstSchema,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Scientific (isInteger)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V

-- | Validate @value@ against @schema@. On failure, returns a short path-prefixed
-- reason (e.g. @score: expected integer@).
validateAgainstSchema :: Value -> Value -> Either Text ()
validateAgainstSchema schema value = go "$" schema value

go :: Text -> Value -> Value -> Either Text ()
go path schema value = case schema of
  -- Bare @{}@ means Json: accept any value (see typeToSchema "Json").
  Object o
    | KM.null o -> Right ()
    | Just alts <- KM.lookup "anyOf" o -> validateAnyOf path alts value
    | Just alts <- KM.lookup "oneOf" o -> validateOneOf path alts value
    | Just (Array opts) <- KM.lookup "enum" o ->
        if value `elem` V.toList opts
          then Right ()
          else Left (path <> ": value not in enum")
    | Just ty <- KM.lookup "type" o -> validateTyped path o ty value
    | otherwise -> Left (path <> ": unsupported schema")
  _ -> Left (path <> ": schema must be an object")

validateAnyOf :: Text -> Value -> Value -> Either Text ()
validateAnyOf path alts value = case alts of
  Array xs ->
    case [ () | Right () <- map (\s -> go path s value) (V.toList xs) ] of
      [] -> Left (path <> ": matched no anyOf alternative")
      _ -> Right ()
  _ -> Left (path <> ": anyOf must be an array")

validateOneOf :: Text -> Value -> Value -> Either Text ()
validateOneOf path alts value = case alts of
  Array xs ->
    case [ () | Right () <- map (\s -> go path s value) (V.toList xs) ] of
      [_] -> Right ()
      [] -> Left (path <> ": matched no oneOf alternative")
      _ -> Left (path <> ": matched multiple oneOf alternatives")
  _ -> Left (path <> ": oneOf must be an array")

validateTyped :: Text -> KM.KeyMap Value -> Value -> Value -> Either Text ()
validateTyped path o tyVal value = case tyVal of
  String "null" -> case value of
    Null -> Right ()
    _ -> Left (path <> ": expected null")
  String "boolean" -> case value of
    Bool _ -> Right ()
    _ -> Left (path <> ": expected boolean")
  String "string" -> case value of
    String _ -> Right ()
    _ -> Left (path <> ": expected string")
  String "integer" -> case value of
    Number n | isInteger n -> Right ()
    Number _ -> Left (path <> ": expected integer")
    _ -> Left (path <> ": expected integer")
  String "number" -> case value of
    Number _ -> Right ()
    _ -> Left (path <> ": expected number")
  String "array" -> validateArray path o value
  String "object" -> validateObject path o value
  String other -> Left (path <> ": unsupported type " <> other)
  Array tys ->
    -- JSON Schema multi-type (rare in our emitter); accept if any type matches.
    case [ () | String t <- V.toList tys, Right () <- [validateTyped path o (String t) value] ] of
      [] -> Left (path <> ": matched no type alternative")
      _ -> Right ()
  _ -> Left (path <> ": type must be a string")

validateArray :: Text -> KM.KeyMap Value -> Value -> Either Text ()
validateArray path o = \case
  Array xs -> case KM.lookup "items" o of
    Nothing -> Right ()
    Just items ->
      mapM_
        (\(i, v) -> go (path <> "[" <> T.pack (show i) <> "]") items v)
        (zip [0 :: Int ..] (V.toList xs))
  _ -> Left (path <> ": expected array")

validateObject :: Text -> KM.KeyMap Value -> Value -> Either Text ()
validateObject path o = \case
  Object obj -> do
    mapM_ (checkRequired obj) required
    mapM_ (checkProp obj) (KM.toList props)
    checkAdditional obj
  _ -> Left (path <> ": expected object")
  where
    props = case KM.lookup "properties" o of
      Just (Object ps) -> ps
      _ -> KM.empty

    required = case KM.lookup "required" o of
      Just (Array a) -> [t | String t <- V.toList a]
      _ -> []

    checkRequired obj name =
      if KM.member (Key.fromText name) obj
        then Right ()
        else Left (path <> ": missing required field " <> name)

    checkProp obj (k, fieldSchema) = case KM.lookup k obj of
      Nothing -> Right ()
      Just v -> go (fieldPath path (Key.toText k)) fieldSchema v

    checkAdditional obj = case KM.lookup "additionalProperties" o of
      Just (Bool False) ->
        let unknown =
              [ Key.toText k
                | k <- KM.keys obj,
                  not (KM.member k props)
              ]
         in case unknown of
              [] -> Right ()
              us ->
                Left
                  ( path
                      <> ": unexpected field(s): "
                      <> T.intercalate ", " us
                  )
      Just (Bool True) -> Right ()
      Just addSchema ->
        mapM_
          ( \(k, v) ->
              if KM.member k props
                then Right ()
                else go (fieldPath path (Key.toText k)) addSchema v
          )
          (KM.toList obj)
      Nothing -> Right ()

fieldPath :: Text -> Text -> Text
fieldPath "$" name = name
fieldPath parent name = parent <> "." <> name
