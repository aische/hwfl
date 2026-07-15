-- | @llm.agent@ tool-loop helpers: tool specs from functions, arg coercion,
-- provider ToolSpec projection. Stepping lives in 'Pml.Runtime.Eval'.
module Pml.Runtime.Agent
  ( buildToolSpec,
    parseAgentArgs,
    initAgentState,
    providerToolSpecs,
    coerceToolArgs,
    valueToJsonText,
    sanitizeToolName,
    lookupTool,
    defaultMaxRounds,
  )
where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Vector qualified as V
import Pml.Ast.Expr (Param (..))
import Pml.Ast.Name (Ident (..), TypeName (..))
import Pml.Ast.Type (TypeExpr (..))
import Pml.Check.Prelude (preludeTypeEnv)
import Pml.Check.Schema (typeToSchema)
import Pml.Eval.Value
import Pml.Llm.Types qualified as Llm
import Pml.Runtime.Error (RuntimeError (..))
import Pml.Runtime.Machine (AgentState (..), FunTable)

defaultMaxRounds :: Int
defaultMaxRounds = 8

-- | Build a 'VToolSpec' from a host op, top-level fun, or annotated closure.
buildToolSpec :: FunTable -> Value -> Either RuntimeError Value
buildToolSpec funs callee = case callee of
  VHostOp op -> do
    (name, desc, params) <- hostToolMeta op
    pure $
      VToolSpec
        ToolSpecValue
          { tvsName = name,
            tvsDescription = desc,
            tvsParameters = params,
            tvsCallee = callee
          }
  VTopFun n -> case Map.lookup n funs of
    Nothing -> Left (HostErr ("tool: unknown function " <> unIdent n))
    Just (ps, _) -> do
      schema <- paramsSchema ps
      pure $
        VToolSpec
          ToolSpecValue
            { tvsName = sanitizeToolName (unIdent n),
              tvsDescription = "module function " <> unIdent n,
              tvsParameters = schema,
              tvsCallee = callee
            }
  VClosure ps _ _ -> do
    schema <- paramsSchema ps
    pure $
      VToolSpec
        ToolSpecValue
          { tvsName = "closure",
            tvsDescription = "closure tool",
            tvsParameters = schema,
            tvsCallee = callee
          }
  _ -> Left (HostErr "tool() expects a function or host op")

hostToolMeta :: HostOpId -> Either RuntimeError (Text, Text, Aeson.Value)
hostToolMeta = \case
  HostFsRead ->
    Right
      ( "fs_read",
        "Read a UTF-8 text file from the workspace",
        objectSchema [("path", t "FileRef")]
      )
  HostFsWrite ->
    Right
      ( "fs_write",
        "Write a UTF-8 text file in the workspace",
        objectSchema [("path", t "FileRef"), ("text", t "String")]
      )
  other ->
    Left (HostErr ("host op not agent-eligible as tool: " <> hostOpName other))

paramsSchema :: [Param] -> Either RuntimeError Aeson.Value
paramsSchema ps = case traverse namedParam ps of
  Left e -> Left e
  Right [] ->
    Right
      ( object
          [ "type" .= Aeson.String "object",
            "properties" .= object [],
            "additionalProperties" .= False
          ]
      )
  Right fields -> Right (objectSchema fields)
  where
    namedParam (Param n mty) = case mty of
      Just ty -> Right (unIdent n, ty)
      Nothing ->
        Left (HostErr ("tool: parameter " <> unIdent n <> " needs a type annotation"))

objectSchema :: [(Text, TypeExpr)] -> Aeson.Value
objectSchema fields =
  case typeToSchema preludeTypeEnv (TRecord [(Ident k, ty) | (k, ty) <- fields]) of
    Right v -> v
    Left _ ->
      object
        [ "type" .= Aeson.String "object",
          "properties" .= object [],
          "additionalProperties" .= True
        ]

t :: Text -> TypeExpr
t = TName . TypeName

sanitizeToolName :: Text -> Text
sanitizeToolName = T.map safe
  where
    safe c
      | c == '.' || c == '/' || c == '-' = '_'
      | otherwise = c

providerToolSpecs :: [ToolSpecValue] -> [Llm.ToolSpec]
providerToolSpecs =
  map
    ( \ts ->
        Llm.ToolSpec
          { Llm.tsName = ts.tvsName,
            Llm.tsDescription = ts.tvsDescription,
            Llm.tsParameters = ts.tvsParameters
          }
    )

lookupTool :: [ToolSpecValue] -> Text -> Maybe ToolSpecValue
lookupTool tools name =
  lookup name [(ts.tvsName, ts) | ts <- tools]

parseAgentArgs ::
  [(Maybe Ident, Value)] ->
  Either RuntimeError (Text, Text, [ToolSpecValue], Text, Int)
parseAgentArgs args = do
  system <- expectString (Ident "system") args
  prompt <- expectString (Ident "prompt") args
  model <- expectString (Ident "model") args
  tools <- expectTools args
  let maxR = case lookupNamed (Ident "max_rounds") args of
        Just (VInt n) | n > 0 -> fromIntegral n
        _ -> defaultMaxRounds
  pure (system, prompt, tools, model, maxR)

initAgentState ::
  Text ->
  Text ->
  [ToolSpecValue] ->
  Text ->
  Int ->
  Text ->
  AgentState
initAgentState system prompt tools model maxRounds spanId =
  AgentState
    { agSystem = system,
      agPrompt = prompt,
      agModel = model,
      agMaxRounds = maxRounds,
      agTools = tools,
      agHistory = [Llm.TurnUser prompt],
      agRound = 0,
      agToolRound = Nothing,
      agSpanId = spanId,
      agRoundSpanId = Nothing
    }

expectTools :: [(Maybe Ident, Value)] -> Either RuntimeError [ToolSpecValue]
expectTools args = case lookupNamed (Ident "tools") args of
  Just (VList xs) -> traverse expectTool xs
  Just _ -> Left (HostErr "llm.agent tools must be a List<ToolSpec>")
  Nothing -> Left (HostErr "llm.agent missing tools")
  where
    expectTool = \case
      VToolSpec ts -> Right ts
      _ -> Left (HostErr "llm.agent tools element is not a ToolSpec (use tool(f))")

expectString :: Ident -> [(Maybe Ident, Value)] -> Either RuntimeError Text
expectString n args = case lookupNamed n args of
  Just (VString s) -> Right s
  Just (VSecret _) -> Left (HostErr ("secret not allowed for " <> unIdent n))
  Just _ -> Left (HostErr ("expected String for " <> unIdent n))
  Nothing -> Left (HostErr ("missing named argument: " <> unIdent n))

lookupNamed :: Ident -> [(Maybe Ident, Value)] -> Maybe Value
lookupNamed n args = lookup (Just n) args

-- | Coerce model JSON arguments into runtime call args for a tool callee.
coerceToolArgs :: ToolSpecValue -> Aeson.Value -> Either Text [(Maybe Ident, Value)]
coerceToolArgs ts json = case ts.tvsCallee of
  VHostOp HostFsRead -> case json of
    Aeson.Object o -> case KM.lookup "path" o of
      Just (Aeson.String p) -> Right [(Just (Ident "path"), VString p)]
      Just _ -> Left "fs_read.path must be a string"
      Nothing -> Left "fs_read missing path"
    Aeson.String p -> Right [(Nothing, VString p)]
    _ -> Left "fs_read arguments must be an object or string path"
  VHostOp HostFsWrite -> case json of
    Aeson.Object o -> do
      path <- stringField o "path"
      text <- stringField o "text"
      Right
        [ (Just (Ident "path"), VString path),
          (Just (Ident "text"), VString text)
        ]
    _ -> Left "fs_write arguments must be an object"
  VTopFun {} -> namedObjectArgs json
  VClosure {} -> namedObjectArgs json
  _ -> Left "unsupported tool callee"
  where
    stringField o k = case KM.lookup (Key.fromText k) o of
      Just (Aeson.String s) -> Right s
      Just _ -> Left (k <> " must be a string")
      Nothing -> Left ("missing " <> k)
    namedObjectArgs = \case
      Aeson.Object o ->
        Right
          [ (Just (Ident (Key.toText k)), jsonToValue v)
            | (k, v) <- KM.toList o
          ]
      _ -> Left "tool arguments must be a JSON object"

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

valueToJsonText :: Value -> Text
valueToJsonText v =
  TE.decodeUtf8 (BL.toStrict (Aeson.encode (valueToAeson v)))

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
