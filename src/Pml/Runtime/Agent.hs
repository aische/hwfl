-- | @llm.agent@ / @llm.agent_object@ tool-loop helpers: tool specs from
-- functions, arg coercion, provider ToolSpec projection, synthetic @submit@.
-- Stepping lives in 'Pml.Runtime.Eval'.
module Pml.Runtime.Agent
  ( buildToolSpec,
    parseAgentArgs,
    parseAgentObjectArgs,
    initAgentState,
    providerToolSpecs,
    coerceToolArgs,
    valueToJsonText,
    sanitizeToolName,
    lookupTool,
    defaultMaxRounds,
    submitToolName,
    isSubmitCall,
    submitToolSpec,
    validateSubmit,
    mixesSubmit,
  )
where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Pml.Ast.Expr (Param (..))
import Pml.Ast.Name (Ident (..), TypeName (..))
import Pml.Ast.Type (TypeExpr (..))
import Pml.Check.Prelude (preludeTypeEnv)
import Pml.Check.Schema (typeToSchema)
import Pml.Eval.Value
import Pml.Json.Encode (jsonToValue, valueToJsonText)
import Pml.Llm.Types qualified as Llm
import Pml.Runtime.Error (RuntimeError (..))
import Pml.Runtime.Machine (AgentState (..), FunTable)

defaultMaxRounds :: Int
defaultMaxRounds = 8

submitToolName :: Text
submitToolName = "submit"

isSubmitCall :: Llm.ToolCall -> Bool
isSubmitCall tc = tc.tcName == submitToolName

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
        describedObjectSchema
          [("path", t "FileRef", "Workspace-relative file path to read")]
      )
  HostFsWrite ->
    Right
      ( "fs_write",
        "Write a UTF-8 text file in the workspace",
        describedObjectSchema
          [ ("path", t "FileRef", "Workspace-relative file path to write"),
            ("text", t "String", "UTF-8 text content to write to the file")
          ]
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

describedObjectSchema :: [(Text, TypeExpr, Text)] -> Aeson.Value
describedObjectSchema fields =
  annotateProperties
    [(name, desc) | (name, _, desc) <- fields]
    (objectSchema [(name, ty) | (name, ty, _) <- fields])

annotateProperties :: [(Text, Text)] -> Aeson.Value -> Aeson.Value
annotateProperties descs = \case
  Aeson.Object o ->
    let props = case KM.lookup "properties" o of
          Just (Aeson.Object ps) -> Aeson.Object (foldr addDescription ps descs)
          other -> fromMaybe (object []) other
     in Aeson.Object (KM.insert "properties" props o)
  other -> other
  where
    addDescription (name, desc) props =
      case KM.lookup (Key.fromText name) props of
        Just v -> KM.insert (Key.fromText name) (annotateDescription desc v) props
        Nothing -> props
    annotateDescription desc = \case
      Aeson.Object p -> Aeson.Object (KM.insert "description" (Aeson.String desc) p)
      other -> other

t :: Text -> TypeExpr
t = TName . TypeName

sanitizeToolName :: Text -> Text
sanitizeToolName = T.map safe
  where
    safe c
      | c == '.' || c == '/' || c == '-' = '_'
      | otherwise = c

-- | Synthetic terminating @submit@ tool (hwfi §6.1.3).
submitToolSpec :: Aeson.Value -> ToolSpecValue
submitToolSpec schema =
  ToolSpecValue
    { tvsName = submitToolName,
      tvsDescription =
        "Submit the final structured result. Call this ONLY when you have "
          <> "everything you need, and NEVER in the same response as any other "
          <> "tool call. Its arguments are the final result.",
      tvsParameters = schema,
      -- Sentinel: Eval handles submit specially before openApply.
      tvsCallee = VUnit
    }

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

-- | True when this round mixes @submit@ with other tool calls (reject wholesale).
mixesSubmit :: AgentState -> [Llm.ToolCall] -> Bool
mixesSubmit ag calls =
  case ag.agSubmitSchema of
    Nothing -> False
    Just _ -> any isSubmitCall calls && length calls > 1

-- | Validate submit arguments against the schema's required fields.
-- Success returns the decoded runtime value of the arguments object.
validateSubmit :: Aeson.Value -> Aeson.Value -> Either Text Value
validateSubmit schema args = case args of
  Aeson.Object o -> case missing o of
    [] -> Right (jsonToValue args)
    ms -> Left ("missing required field(s): " <> T.intercalate ", " ms)
  _ -> Left "arguments must be a JSON object"
  where
    required = case schema of
      Aeson.Object so -> case KM.lookup "required" so of
        Just (Aeson.Array a) -> [t' | Aeson.String t' <- V.toList a]
        _ -> []
      _ -> []
    missing o = [r | r <- required, not (KM.member (Key.fromText r) o)]

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

parseAgentObjectArgs ::
  [(Maybe Ident, Value)] ->
  Either RuntimeError (Text, Text, [ToolSpecValue], Aeson.Value, Text, Int)
parseAgentObjectArgs args = do
  (system, prompt, tools, model, maxR) <- parseAgentArgs args
  schema <- expectSchema (Ident "schema") args
  pure (system, prompt, tools, schema, model, maxR)

initAgentState ::
  Text ->
  Text ->
  [ToolSpecValue] ->
  Text ->
  Int ->
  Text ->
  Maybe Aeson.Value ->
  AgentState
initAgentState system prompt tools model maxRounds spanId submitSchema =
  let tools' = case submitSchema of
        Just schema -> tools ++ [submitToolSpec schema]
        Nothing -> tools
   in AgentState
        { agSystem = system,
          agPrompt = prompt,
          agModel = model,
          agMaxRounds = maxRounds,
          agTools = tools',
          agSubmitSchema = submitSchema,
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

expectSchema :: Ident -> [(Maybe Ident, Value)] -> Either RuntimeError Aeson.Value
expectSchema n args = case lookupNamed n args of
  Just (VSchema s) -> Right s
  Just _ -> Left (HostErr ("expected Schema for " <> unIdent n <> " (use schema(T))"))
  Nothing -> Left (HostErr ("missing named argument: " <> unIdent n))

expectString :: Ident -> [(Maybe Ident, Value)] -> Either RuntimeError Text
expectString n args = case lookupNamed n args of
  Just (VString s) -> Right s
  Just (VSecret _) -> Left (HostErr ("secret not allowed for " <> unIdent n))
  Just _ -> Left (HostErr ("expected String for " <> unIdent n))
  Nothing -> Left (HostErr ("missing named argument: " <> unIdent n))

lookupNamed :: Ident -> [(Maybe Ident, Value)] -> Maybe Value
lookupNamed n = lookup (Just n)

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
