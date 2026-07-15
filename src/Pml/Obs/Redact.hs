-- | Redaction for spans, events, and show output (spec §07 §4).
module Pml.Obs.Redact
  ( redactMarker,
    redactValue,
    redactJson,
    hostOpenAttrs,
    sensitiveKey,
  )
where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Text (Text)
import Data.Text qualified as T
import Pml.Ast.Name (Ident (..))
import Pml.Eval.Value (HostOpId (..), ToolSpecValue (..), Value (..), hostOpName)

redactMarker :: Text
redactMarker = "[REDACTED]"

-- | Runtime values: secrets never leave cleartext.
redactValue :: Value -> Value
redactValue = \case
  VSecret _ -> VSecret (VString redactMarker)
  VList xs -> VList (map redactValue xs)
  VRecord fs -> VRecord [(k, redactValue v) | (k, v) <- fs]
  VVariant n (Just v) -> VVariant n (Just (redactValue v))
  VToolSpec ts ->
    VToolSpec ts {tvsCallee = redactValue ts.tvsCallee}
  v -> v

-- | JSON tree redaction: secret tags + sensitive object keys.
redactJson :: Aeson.Value -> Aeson.Value
redactJson = \case
  Aeson.Object km ->
    case KM.lookup "tag" km of
      Just (Aeson.String "secret") ->
        object ["tag" .= Aeson.String "secret", "v" .= Aeson.String redactMarker]
      _ ->
        Aeson.Object $
          KM.fromList
            [ (k, if sensitiveKey (Key.toText k) then Aeson.String redactMarker else redactJson v)
              | (k, v) <- KM.toList km
            ]
  Aeson.Array xs -> Aeson.Array (fmap redactJson xs)
  Aeson.String t
    | looksLikeSecret t -> Aeson.String redactMarker
    | otherwise -> Aeson.String t
  other -> other

sensitiveKey :: Text -> Bool
sensitiveKey k =
  let n = T.toLower k
   in -- Allow observability counters (token_in / token_out) while scrubbing
      -- credential-shaped keys.
      n `notElem` ["token_in", "token_out", "tokens"]
        && ( n
               `elem` [ "secret",
                        "password",
                        "passwd",
                        "api_key",
                        "apikey",
                        "authorization",
                        "token",
                        "credential",
                        "access_token",
                        "refresh_token"
                      ]
               || any
                 (`T.isInfixOf` n)
                 ["password", "passwd", "secret", "api_key", "apikey", "credential"]
           )

looksLikeSecret :: Text -> Bool
looksLikeSecret t =
  T.isPrefixOf "sk-" t
    || T.isPrefixOf "rk-" t
    || (T.length t >= 40 && T.all isSecretChar t && T.any (\c -> c >= 'A' && c <= 'Z') t)
  where
    isSecretChar c =
      (c >= 'a' && c <= 'z')
        || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9')
        || c == '_'
        || c == '-'

-- | Redacted open-attrs for a host op (never full prompt/body text).
hostOpenAttrs :: HostOpId -> [(Maybe Ident, Value)] -> Aeson.Value
hostOpenAttrs op args = case op of
  HostFsRead ->
    object
      [ "op" .= hostOpName op,
        "path" .= pathAttr args
      ]
  HostFsWrite ->
    object
      [ "op" .= hostOpName op,
        "path" .= pathAttr args,
        "text_len" .= textLenAttr (Ident "text") args
      ]
  HostFsFind ->
    object
      [ "op" .= hostOpName op,
        "glob" .= stringAttr (Ident "glob") args
      ]
  HostMetaCheckModule ->
    object
      [ "op" .= hostOpName op,
        "path" .= pathAttr args
      ]
  HostMetaCheckProject ->
    object
      [ "op" .= hostOpName op,
        "path" .= pathAttr args
      ]
  HostLlmChat ->
    object
      [ "op" .= hostOpName op,
        "model" .= stringAttr (Ident "model") args,
        "system_len" .= textLenAttr (Ident "system") args,
        "prompt_len" .= textLenAttr (Ident "prompt") args
      ]
  HostLlmObject ->
    object
      [ "op" .= hostOpName op,
        "model" .= stringAttr (Ident "model") args,
        "prompt_len" .= textLenAttr (Ident "prompt") args,
        "has_schema" .= True
      ]
  HostLlmAgent ->
    object
      [ "op" .= hostOpName op,
        "model" .= stringAttr (Ident "model") args,
        "system_len" .= textLenAttr (Ident "system") args,
        "prompt_len" .= textLenAttr (Ident "prompt") args,
        "tools" .= toolsLenAttr args
      ]
  HostLlmAgentObject ->
    object
      [ "op" .= hostOpName op,
        "model" .= stringAttr (Ident "model") args,
        "system_len" .= textLenAttr (Ident "system") args,
        "prompt_len" .= textLenAttr (Ident "prompt") args,
        "tools" .= toolsLenAttr args,
        "has_schema" .= True
      ]
  HostHumanConfirm ->
    object
      [ "op" .= hostOpName op,
        "title" .= stringAttr (Ident "title") args
      ]
  HostObsLog ->
    object
      [ "op" .= hostOpName op,
        "level" .= stringAttr (Ident "level") args,
        "message" .= stringAttr (Ident "message") args
      ]
  HostObsSpan ->
    object
      [ "op" .= hostOpName op,
        "name" .= regionNameAttr args
      ]

pathAttr :: [(Maybe Ident, Value)] -> Aeson.Value
pathAttr args = case lookupNamed (Ident "path") args `orElse` lookupPos 0 args of
  Just (VString t) -> Aeson.String t
  Just (VSecret _) -> Aeson.String redactMarker
  _ -> Aeson.Null

stringAttr :: Ident -> [(Maybe Ident, Value)] -> Aeson.Value
stringAttr n args = case lookupNamed n args of
  Just (VString t) -> Aeson.String t
  Just (VSecret _) -> Aeson.String redactMarker
  Just _ -> Aeson.String redactMarker
  Nothing -> Aeson.Null

textLenAttr :: Ident -> [(Maybe Ident, Value)] -> Aeson.Value
textLenAttr n args = case lookupNamed n args of
  Just (VString t) -> Aeson.Number (fromIntegral (T.length t))
  Just (VSecret (VString t)) -> Aeson.Number (fromIntegral (T.length t))
  Just (VSecret _) -> Aeson.Number 0
  _ -> Aeson.Null

regionNameAttr :: [(Maybe Ident, Value)] -> Aeson.Value
regionNameAttr args = case lookupNamed (Ident "name") args `orElse` lookupPos 0 args of
  Just (VString t) -> Aeson.String t
  _ -> Aeson.Null

toolsLenAttr :: [(Maybe Ident, Value)] -> Aeson.Value
toolsLenAttr args = case lookupNamed (Ident "tools") args of
  Just (VList xs) -> Aeson.Number (fromIntegral (length xs))
  _ -> Aeson.Null

lookupNamed :: Ident -> [(Maybe Ident, Value)] -> Maybe Value
lookupNamed n args = lookup (Just n) args

lookupPos :: Int -> [(Maybe Ident, Value)] -> Maybe Value
lookupPos i args =
  let ps = [v | (Nothing, v) <- args]
   in if i >= 0 && i < length ps then Just (ps !! i) else Nothing

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just x) _ = Just x
orElse Nothing y = y
