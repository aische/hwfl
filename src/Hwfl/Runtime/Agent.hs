-- | @llm.agent@ / @llm.agent_object@ tool-loop helpers: tool specs from
-- functions, arg coercion, provider ToolSpec projection, synthetic @submit@.
-- Stepping lives in 'Hwfl.Runtime.Eval'.
module Hwfl.Runtime.Agent
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
import Hwfl.Ast.Expr (Param (..))
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Ast.Type (TypeExpr (..))
import Hwfl.Check.Prelude (preludeTypeEnv)
import Hwfl.Check.Schema (typeToSchema)
import Hwfl.Eval.Value
import Hwfl.Json.Encode (jsonToValue, valueToJsonText)
import Hwfl.Llm.Types qualified as Llm
import Hwfl.Runtime.Error (RuntimeError (..))
import Hwfl.Runtime.Machine (AgentState (..), FunTable)

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
  HostFsList ->
    Right
      ( "fs_list",
        "List files and directories in a workspace path",
        describedObjectSchema
          [("path", t "FileRef", "Workspace-relative directory to list")]
      )
  HostFsFind ->
    Right
      ( "fs_find",
        "Find workspace files matching a glob pattern",
        describedObjectSchema
          [("glob", t "String", "File glob (**/*.ext or *.ext)")]
      )
  HostFsEdit ->
    Right
      ( "fs_edit",
        "Replace occurrences of a literal string in a workspace file",
        describedObjectSchema
          [ ("path", t "FileRef", "Workspace-relative file path to edit"),
            ("old", t "String", "Literal substring to find"),
            ("new", t "String", "Replacement text")
          ]
      )
  HostFsGrep ->
    Right
      ( "fs_grep",
        "Regex-search workspace files; empty glob searches the whole workspace",
        describedObjectSchema
          [ ("pattern", t "String", "Regular expression to match against each line"),
            ("glob", t "String", "Optional file glob (**/*.ext or *.ext); empty = all files")
          ]
      )
  HostExecRun ->
    Right
      ( "exec_run",
        "Run an allowlisted program in the workspace (see project.json exec.allow)",
        describedObjectSchema
          [ ("program", t "String", "Bare program basename (must be allowlisted)"),
            ("args", TList (t "String"), "Command-line arguments"),
            ("stdin", t "String", "Standard input text")
          ]
      )
  HostSkillDiscover ->
    Right
      ( "skill_discover",
        "Discover project skills by query / kinds / limit (metadata only)",
        describedObjectSchema
          [ ("query", t "String", "Substring match on id, summary, and tags"),
            ("kinds", TList (t "String"), "Filter: callable and/or instruction; empty = all"),
            ("limit", t "Int", "Max results (default 20)")
          ]
      )
  HostSkillLoad ->
    Right
      ( "skill_load",
        "Load a skill by id: instruction injects context; callable expands tools",
        describedObjectSchema
          [("id", t "String", "Skill qname such as skills/shell-repair-guide")]
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
          agRoundSpanId = Nothing,
          agBaselineTools = tools',
          agActiveToolIds = [],
          agLoadedInstructionIds = [],
          agInstructionChars = 0,
          agRoundCloseAttrs = Nothing
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
  VHostOp HostFsList -> case json of
    Aeson.Object o -> case KM.lookup "path" o of
      Just (Aeson.String p) -> Right [(Just (Ident "path"), VString p)]
      Just _ -> Left "fs_list.path must be a string"
      Nothing -> Left "fs_list missing path"
    Aeson.String p -> Right [(Nothing, VString p)]
    _ -> Left "fs_list arguments must be an object or string path"
  VHostOp HostFsFind -> case json of
    Aeson.Object o -> case KM.lookup "glob" o of
      Just (Aeson.String g) -> Right [(Just (Ident "glob"), VString g)]
      Just _ -> Left "fs_find.glob must be a string"
      Nothing -> Left "fs_find missing glob"
    Aeson.String g -> Right [(Just (Ident "glob"), VString g)]
    _ -> Left "fs_find arguments must be an object or string glob"
  VHostOp HostFsEdit -> case json of
    Aeson.Object o -> do
      path <- stringField o "path"
      old <- stringField o "old"
      new <- stringField o "new"
      Right
        [ (Just (Ident "path"), VString path),
          (Just (Ident "old"), VString old),
          (Just (Ident "new"), VString new)
        ]
    _ -> Left "fs_edit arguments must be an object"
  VHostOp HostFsGrep -> case json of
    Aeson.Object o -> do
      pattern <- stringField o "pattern"
      let glob = case KM.lookup "glob" o of
            Just (Aeson.String g) -> g
            _ -> ""
      Right
        [ (Just (Ident "pattern"), VString pattern),
          (Just (Ident "glob"), VString glob)
        ]
    _ -> Left "fs_grep arguments must be an object"
  VHostOp HostExecRun -> case json of
    Aeson.Object o -> do
      program <- stringField o "program"
      argv <- stringListField o "args"
      let stdin = case KM.lookup "stdin" o of
            Just (Aeson.String s) -> s
            _ -> ""
      Right
        [ (Just (Ident "program"), VString program),
          (Just (Ident "args"), VList (map VString argv)),
          (Just (Ident "stdin"), VString stdin)
        ]
    _ -> Left "exec_run arguments must be an object"
  VHostOp HostSkillDiscover -> case json of
    Aeson.Object o -> do
      let query = case KM.lookup "query" o of
            Just (Aeson.String q) -> q
            _ -> ""
          kinds = case KM.lookup "kinds" o of
            Just (Aeson.Array arr) -> [s | Aeson.String s <- V.toList arr]
            _ -> []
          limit = case KM.lookup "limit" o of
            Just (Aeson.Number n) -> round n
            _ -> (20 :: Integer)
      Right
        [ (Just (Ident "query"), VString query),
          (Just (Ident "kinds"), VList (map VString kinds)),
          (Just (Ident "limit"), VInt limit)
        ]
    _ -> Left "skill_discover arguments must be an object"
  VHostOp HostSkillLoad -> case json of
    Aeson.Object o -> case KM.lookup "id" o of
      Just (Aeson.String sid) -> Right [(Just (Ident "id"), VString sid)]
      Just _ -> Left "skill_load.id must be a string"
      Nothing -> Left "skill_load missing id"
    Aeson.String sid -> Right [(Just (Ident "id"), VString sid)]
    _ -> Left "skill_load arguments must be an object or string id"
  VTopFun {} -> namedObjectArgs json
  VClosure {} -> namedObjectArgs json
  VSkillMain {} -> namedObjectArgs json
  _ -> Left "unsupported tool callee"
  where
    stringField o k = case KM.lookup (Key.fromText k) o of
      Just (Aeson.String s) -> Right s
      Just _ -> Left (k <> " must be a string")
      Nothing -> Left ("missing " <> k)
    stringListField o k = case KM.lookup (Key.fromText k) o of
      Just (Aeson.Array arr) ->
        traverse
          ( \case
              Aeson.String s -> Right s
              _ -> Left (k <> " elements must be strings")
          )
          (V.toList arr)
      Just _ -> Left (k <> " must be an array of strings")
      Nothing -> Right []
    namedObjectArgs = \case
      Aeson.Object o ->
        Right
          [ (Just (Ident (Key.toText k)), jsonToValue v)
            | (k, v) <- KM.toList o
          ]
      _ -> Left "tool arguments must be a JSON object"
