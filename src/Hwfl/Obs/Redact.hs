-- | Redaction for spans, events, and show output (spec §07 §4).
module Hwfl.Obs.Redact
  ( redactMarker,
    redactValue,
    redactJson,
    redactText,
    summarizeJson,
    toolCallOpenAttrs,
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
import Data.Vector qualified as V
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Eval.Value (HostOpId (..), ToolSpecValue (..), Value (..), hostOpName)
import Hwfl.Llm.Types (ToolCall (..))
import Data.ByteString.Lazy qualified as BL
import Data.Char (isAlphaNum, isAsciiLower, isAsciiUpper, isDigit, isHexDigit, isSpace)
import Data.Text.Encoding qualified as TE

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
    | otherwise -> Aeson.String (redactText t)
  other -> other

sensitiveKey :: Text -> Bool
sensitiveKey k =
  let n = T.filter isAlphaNum (T.toLower k)
   in -- Allow observability counters (token_in / token_out) while scrubbing
      -- credential-shaped keys.
      n `notElem` ["tokenin", "tokenout", "tokens", "costusd", "costmicros"]
        && ( n
               `elem` [ "secret",
                        "password",
                        "passwd",
                        "passphrase",
                        "pwd",
                        "apikey",
                        "privatekey",
                        "pem",
                        "authorization",
                        "token",
                        "credential",
                        "accesstoken",
                        "refreshtoken"
                      ]
               || any
                 (`T.isInfixOf` n)
                 ["password", "passwd", "passphrase", "privatekey", "apikey", "secret", "credential"]
           )

-- | Best-effort protection for untyped text channels. Typed @VSecret@ values
-- are the confidentiality boundary; this additionally catches common
-- credential forms and JSON embedded in a text field.
redactText :: Text -> Text
redactText = redactEmbeddedJson . redactTokens . redactPem
  where
    redactEmbeddedJson t
      | T.isPrefixOf "{" stripped || T.isPrefixOf "[" stripped =
          case Aeson.eitherDecodeStrict' (TE.encodeUtf8 stripped) of
            Right (v :: Aeson.Value) ->
              T.takeWhile isSpace t <> TE.decodeUtf8 (BL.toStrict (Aeson.encode (redactJson v)))
            Left _ -> t
      | otherwise = t
      where
        stripped = T.stripStart t

    redactPem t =
      case T.breakOn "-----BEGIN " t of
        (before, rest)
          | T.null rest -> t
          | otherwise ->
              case T.breakOn "-----END " rest of
                (_, endStart)
                  | T.null endStart -> before <> redactMarker
                  | otherwise ->
                      let (_, afterEnd) = T.breakOn "-----" (T.drop (T.length "-----END ") endStart)
                       in before <> redactMarker <> T.drop (T.length "-----") afterEnd

    redactTokens = go
      where
        go text =
          if T.null text
            then ""
            else
              let (plain, rest) = T.span (not . tokenChar) text
                  (token, remaining) = T.span tokenChar rest
               in plain
                    <> if T.null token then "" else scrub token
                    <> go remaining

    tokenChar c = isAsciiLower c || isAsciiUpper c || isDigit c || c == '_' || c == '-' || c == '.'
    scrub token
      | looksLikeSecret token || looksLikeJwt token = redactMarker
      | otherwise = token

    looksLikeJwt token =
      case T.splitOn "." token of
        [a, b, c] -> all (not . T.null) [a, b, c] && all (T.all base64UrlChar) [a, b, c]
        _ -> False
    base64UrlChar c = isAsciiLower c || isAsciiUpper c || isDigit c || c == '_' || c == '-'

looksLikeSecret :: Text -> Bool
looksLikeSecret t =
  T.isPrefixOf "sk-" t
    || T.isPrefixOf "rk-" t
    || (T.length t >= 40 && T.all isHexDigit t && T.any isDigit t)

-- | Compact JSON for span attrs: redact secrets, truncate long strings.
summarizeJson :: Aeson.Value -> Aeson.Value
summarizeJson = go . redactJson
  where
    go = \case
      Aeson.Object km ->
        Aeson.Object $ KM.fromList [(k, go v) | (k, v) <- KM.toList km]
      Aeson.Array xs ->
        Aeson.Array (V.fromList (map go (V.toList xs)))
      Aeson.String t
        | T.length t > 120 ->
            Aeson.String ("<" <> T.pack (show (T.length t)) <> " chars>")
        | otherwise -> Aeson.String t
      other -> other

-- | Open-attrs for an agent tool call span.
toolCallOpenAttrs :: ToolCall -> Aeson.Value
toolCallOpenAttrs tc =
  object
    [ "tool" .= tc.tcName,
      "call_id" .= tc.tcId,
      "arguments" .= summarizeJson tc.tcArguments
    ]

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
  HostFsList ->
    object
      [ "op" .= hostOpName op,
        "path" .= pathAttr args
      ]
  HostFsEdit ->
    object
      [ "op" .= hostOpName op,
        "path" .= pathAttr args,
        "old_len" .= textLenAttr (Ident "old") args,
        "new_len" .= textLenAttr (Ident "new") args
      ]
  HostFsPatch ->
    object
      [ "op" .= hostOpName op,
        "path" .= pathAttr args,
        "hunks" .= listLenAttr (Ident "hunks") args
      ]
  HostFsGrep ->
    object
      [ "op" .= hostOpName op,
        "pattern" .= stringAttr (Ident "pattern") args,
        "glob" .= stringAttr (Ident "glob") args
      ]
  HostFsReadSlice ->
    object
      [ "op" .= hostOpName op,
        "path" .= pathAttr args,
        "start_line" .= intAttr (Ident "start_line") 1 args,
        "end_line" .= intAttr (Ident "end_line") 2 args
      ]
  HostFsRemove ->
    object
      [ "op" .= hostOpName op,
        "path" .= pathAttr args
      ]
  HostFsMkdir ->
    object
      [ "op" .= hostOpName op,
        "path" .= pathAttr args
      ]
  HostFsCopy ->
    object
      [ "op" .= hostOpName op,
        "src" .= stringAttr (Ident "src") args,
        "dst" .= stringAttr (Ident "dst") args,
        "overwrite" .= boolAttr (Ident "overwrite") args,
        "exclude_count" .= listLenAttr (Ident "exclude") args
      ]
  HostFsMove ->
    object
      [ "op" .= hostOpName op,
        "src" .= stringAttr (Ident "src") args,
        "dst" .= stringAttr (Ident "dst") args
      ]
  HostFsExists ->
    object
      [ "op" .= hostOpName op,
        "path" .= pathAttr args
      ]
  HostFsStat ->
    object
      [ "op" .= hostOpName op,
        "path" .= pathAttr args
      ]
  HostExecRun ->
    object
      [ "op" .= hostOpName op,
        "program" .= stringAttr (Ident "program") args,
        "args_len" .= listLenAttr (Ident "args") args
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
  HostMetaInvoke ->
    object
      [ "op" .= hostOpName op,
        "project" .= stringAttr (Ident "project") args,
        "workspace" .= stringAttr (Ident "workspace") args
      ]
  HostMetaListRuns ->
    object
      [ "op" .= hostOpName op,
        "workspace" .= stringAttr (Ident "workspace") args
      ]
  HostMetaReadSpans ->
    object
      [ "op" .= hostOpName op,
        "run_id" .= stringAttr (Ident "run_id") args,
        "workspace" .= stringAttr (Ident "workspace") args,
        "name_prefix" .= stringAttr (Ident "name_prefix") args,
        "kind" .= stringAttr (Ident "kind") args
      ]
  HostMetaReadSnapshot ->
    object
      [ "op" .= hostOpName op,
        "run_id" .= stringAttr (Ident "run_id") args,
        "workspace" .= stringAttr (Ident "workspace") args
      ]
  HostSkillDiscover ->
    object
      [ "op" .= hostOpName op,
        "query" .= stringAttr (Ident "query") args
      ]
  HostSkillLoad ->
    object
      [ "op" .= hostOpName op,
        "id" .= stringAttr (Ident "id") args
      ]
  HostMcpCall ->
    object
      [ "op" .= hostOpName op,
        "server" .= stringAttr (Ident "server") args,
        "name" .= stringAttr (Ident "name") args
      ]
  HostMcpTools ->
    object
      [ "op" .= hostOpName op,
        "server" .= stringAttr (Ident "server") args
      ]
  HostLlmChat ->
    object
      [ "op" .= hostOpName op,
        "model" .= stringAttr (Ident "model") args,
        "system_len" .= textLenAttr (Ident "system") args,
        "prompt_len" .= textLenAttr (Ident "prompt") args
      ]
  HostLlmChatMessages ->
    object
      [ "op" .= hostOpName op,
        "model" .= stringAttr (Ident "model") args,
        "system_len" .= textLenAttr (Ident "system") args,
        "messages" .= listLenAttr (Ident "messages") args
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
  HostHumanChoice ->
    object
      [ "op" .= hostOpName op,
        "title" .= stringAttr (Ident "title") args,
        "options" .= listLenAttr (Ident "options") args
      ]
  HostHumanAsk ->
    object
      [ "op" .= hostOpName op,
        "prompt" .= stringAttr (Ident "prompt") args
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

listLenAttr :: Ident -> [(Maybe Ident, Value)] -> Aeson.Value
listLenAttr n args = case lookupNamed n args of
  Just (VList xs) -> Aeson.Number (fromIntegral (length xs))
  _ -> Aeson.Null

boolAttr :: Ident -> [(Maybe Ident, Value)] -> Aeson.Value
boolAttr n args = case lookupNamed n args of
  Just (VBool b) -> Aeson.Bool b
  _ -> Aeson.Bool False

intAttr :: Ident -> Int -> [(Maybe Ident, Value)] -> Aeson.Value
intAttr n pos args = case lookupNamed n args `orElse` lookupPos pos args of
  Just (VInt v) -> Aeson.Number (fromIntegral v)
  _ -> Aeson.Null

lookupNamed :: Ident -> [(Maybe Ident, Value)] -> Maybe Value
lookupNamed n = lookup (Just n)

lookupPos :: Int -> [(Maybe Ident, Value)] -> Maybe Value
lookupPos i args =
  let ps = [v | (Nothing, v) <- args]
   in if i >= 0 && i < length ps then Just (ps !! i) else Nothing

orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just x) _ = Just x
orElse Nothing y = y
