-- | Host op values and dispatch. Surface names match Check.Prelude stubs
-- (@fs.read@, @fs.write@, @llm.chat@) — one API surface, check-time types +
-- runtime implementations.
module Pml.Runtime.Host
  ( HostEnv (..),
    HostResult (..),
    hostOpsEnv,
    runHostOp,
  )
where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Pml.Ast.Module (Frontmatter (..), LoadedModule (..))
import Pml.Ast.Name (Ident (..), qnameToText)
import Pml.Check.Error (renderCheckError)
import Pml.Check.Module (checkLoadedModule)
import Pml.Check.Project (checkProject, renderProjectCheckError)
import Pml.Eval.Value
import Pml.Json.Encode (jsonToValue)
import Pml.Llm.Provider (LlmProvider (..))
import Pml.Llm.Types
  ( ChatRequest (..),
    Message (..),
    ProviderResult (..),
    Role (..),
    TokenUsage (..),
    emptyChatRequest,
    renderProviderError,
  )
import Pml.Parse.Load (loadModuleText)
import Pml.Runtime.Error (RuntimeError (..))
import System.FilePath ((</>))
import Pml.Runtime.Workspace (Workspace, findFiles, readTextFile, writeTextFile, workspaceRoot)
import Pml.Source (renderDiagnostics)

-- | Effectful dependencies for host ops (workspace + provider).
data HostEnv = HostEnv
  { heWorkspace :: Workspace,
    heProvider :: LlmProvider,
    heLog :: Text -> IO ()
  }

-- | Host outcome with redacted close-attrs for the span.
data HostResult = HostResult
  { hrValue :: Value,
    hrCloseAttrs :: Aeson.Value
  }

-- | Eval bindings for host modules — mirrors Check.Prelude record shapes.
hostOpsEnv :: Env
hostOpsEnv =
  Map.fromList
    [ ( Ident "fs",
        VRecord
          [ (Ident "read", VHostOp HostFsRead),
            (Ident "write", VHostOp HostFsWrite),
            (Ident "find", VHostOp HostFsFind)
          ]
      ),
      ( Ident "llm",
        VRecord
          [ (Ident "chat", VHostOp HostLlmChat),
            (Ident "object", VHostOp HostLlmObject),
            (Ident "agent", VHostOp HostLlmAgent),
            (Ident "agent_object", VHostOp HostLlmAgentObject)
          ]
      ),
      ( Ident "human",
        VRecord
          [ (Ident "confirm", VHostOp HostHumanConfirm)
          ]
      ),
      ( Ident "obs",
        VRecord
          [ (Ident "log", VHostOp HostObsLog),
            (Ident "span", VHostOp HostObsSpan)
          ]
      ),
      ( Ident "meta",
        VRecord
          [ (Ident "check_module", VHostOp HostMetaCheckModule),
            (Ident "check_project", VHostOp HostMetaCheckProject)
          ]
      )
    ]

-- | Execute one host op (one transition / snapshot boundary).
-- @human.confirm@ / @obs.span@ / @obs.log@ / @llm.agent@ / @llm.agent_object@
-- are handled by the machine driver.
runHostOp ::
  HostEnv ->
  HostOpId ->
  [(Maybe Ident, Value)] ->
  IO (Either RuntimeError HostResult)
runHostOp env op args = case op of
  HostFsRead -> doFsRead env args
  HostFsWrite -> doFsWrite env args
  HostFsFind -> doFsFind env args
  HostMetaCheckModule -> doMetaCheckModule env args
  HostMetaCheckProject -> doMetaCheckProject env args
  HostLlmChat -> doLlmChat env args
  HostLlmObject -> doLlmObject env args
  HostLlmAgent ->
    pure (Left (HostErr "llm.agent must be driven by the machine (agent loop)"))
  HostLlmAgentObject ->
    pure (Left (HostErr "llm.agent_object must be driven by the machine (agent loop)"))
  HostObsLog ->
    pure (Left (HostErr "obs.log must be driven by the machine (span state)"))
  HostHumanConfirm ->
    pure (Left (HostErr "human.confirm must be driven by the machine (approve gate)"))
  HostObsSpan ->
    pure (Left (HostErr "obs.span must be driven by the machine (region frame)"))

doFsRead :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError HostResult)
doFsRead env args = case fileRefArg args of
  Left e -> pure (Left e)
  Right path -> do
    env.heLog ("fs.read " <> path)
    result <- readTextFile env.heWorkspace path
    pure $ case result of
      Left e -> Left e
      Right txt ->
        Right
          ( HostResult
              (VRecord [(Ident "text", VString txt)])
              (object ["bytes" .= T.length txt])
          )

doFsWrite :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError HostResult)
doFsWrite env args =
  case (pathArg, textArg) of
    (Right path, Just (VString txt)) -> do
      env.heLog ("fs.write " <> path)
      result <- writeTextFile env.heWorkspace path txt
      pure $ case result of
        Left e -> Left e
        Right () ->
          Right (HostResult VUnit (object ["bytes" .= T.length txt]))
    (Left e, _) -> pure (Left e)
    (_, _) -> pure (Left (HostErr "fs.write expects path: FileRef and text: String"))
  where
    pathArg = case lookupNamed (Ident "path") args of
      Just v -> fileRefValue v
      Nothing -> fileRefArg args
    textArg = lookupNamed (Ident "text") args

doFsFind :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError HostResult)
doFsFind env args = case globArg args of
  Left e -> pure (Left e)
  Right glob -> do
    env.heLog ("fs.find " <> glob)
    result <- findFiles env.heWorkspace glob
    pure $ case result of
      Left e -> Left e
      Right paths ->
        Right
          ( HostResult
              (VList (map VString paths))
              (object ["count" .= length paths])
          )

doMetaCheckProject :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError HostResult)
doMetaCheckProject env args = case fileRefArg args of
  Left e -> pure (Left e)
  Right rel -> do
    let root = workspaceRoot env.heWorkspace </> T.unpack rel
    env.heLog ("meta.check_project " <> rel)
    result <- checkProject root
    pure $
      Right
        ( HostResult
            ( case result of
                Left err ->
                  VRecord
                    [ (Ident "ok", VBool False),
                      (Ident "error", VString (renderProjectCheckError err))
                    ]
                Right _ ->
                  VRecord
                    [ (Ident "ok", VBool True),
                      (Ident "error", VString "")
                    ]
            )
            (object ["root" .= rel])
        )

doMetaCheckModule :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError HostResult)
doMetaCheckModule env args = case fileRefArg args of
  Left e -> pure (Left e)
  Right path -> do
    env.heLog ("meta.check_module " <> path)
    readResult <- readTextFile env.heWorkspace path
    pure $ case readResult of
      Left e -> Left e
      Right txt ->
        Right (HostResult (checkModuleValue path txt) (object ["path" .= path]))

checkModuleValue :: Text -> Text -> Value
checkModuleValue path txt = case loadModuleText (T.unpack path) txt of
  Left diags ->
    failCheck (renderDiagnostics diags) ""
  Right loaded -> case checkLoadedModule loaded of
    Left err ->
      failCheck (renderCheckError err) (qnameToText loaded.lmFrontmatter.fmName)
    Right _ ->
      VRecord
        [ (Ident "ok", VBool True),
          (Ident "error", VString ""),
          (Ident "name", VString (qnameToText loaded.lmFrontmatter.fmName))
        ]
  where
    failCheck err name =
      VRecord
        [ (Ident "ok", VBool False),
          (Ident "error", VString err),
          (Ident "name", VString name)
        ]

globArg :: [(Maybe Ident, Value)] -> Either RuntimeError Text
globArg args = case lookupNamed (Ident "glob") args of
  Just (VString t) -> Right t
  Just _ -> Left (HostErr "fs.find expects glob: String")
  Nothing -> case lookupPositional 0 args of
    Just (VString t) -> Right t
    _ -> Left (HostErr "fs.find expects glob: String")

doLlmChat :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError HostResult)
doLlmChat env args = case parseChatArgs args of
  Left e -> pure (Left e)
  Right (system, prompt, model) -> do
    env.heLog ("llm.chat model=" <> model)
    let req =
          (emptyChatRequest model)
            { chatMessages =
                [ Message RoleSystem system,
                  Message RoleUser prompt
                ],
              chatSystem = Just system
            }
    result <- env.heProvider.llmChat req
    pure $ case result of
      Left pe -> Left (ProviderErr (renderProviderError pe))
      Right pr ->
        Right
          ( HostResult
              (VString pr.prContent)
              (llmCloseAttrs pr)
          )

doLlmObject :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError HostResult)
doLlmObject env args = case parseObjectArgs args of
  Left e -> pure (Left e)
  Right (prompt, schema, model) -> do
    env.heLog ("llm.object model=" <> model)
    let req =
          (emptyChatRequest model)
            { chatMessages = [Message RoleUser prompt],
              chatResponseFormat = Just schema
            }
    result <- env.heProvider.llmChat req
    pure $ case result of
      Left pe -> Left (ProviderErr (renderProviderError pe))
      Right pr -> case decodeJsonObject pr.prContent of
        Left err -> Left (HostErr err)
        Right val ->
          Right
            ( HostResult
                val
                (llmCloseAttrs pr)
            )

decodeJsonObject :: Text -> Either Text Value
decodeJsonObject txt =
  case Aeson.eitherDecodeStrict' (TE.encodeUtf8 txt) of
    Left err -> Left ("llm.object: invalid JSON response: " <> T.pack err)
    Right (v :: Aeson.Value) -> Right (jsonToValue v)

llmCloseAttrs :: ProviderResult -> Aeson.Value
llmCloseAttrs pr =
  object $
    ["reply_len" .= T.length pr.prContent]
      ++ case pr.prUsage of
        Nothing -> []
        Just u ->
          [ "token_in" .= u.usageInputTokens,
            "token_out" .= u.usageOutputTokens
          ]

parseChatArgs :: [(Maybe Ident, Value)] -> Either RuntimeError (Text, Text, Text)
parseChatArgs args = do
  system <- expectString (Ident "system") args
  prompt <- expectString (Ident "prompt") args
  model <- expectString (Ident "model") args
  pure (system, prompt, model)

parseObjectArgs :: [(Maybe Ident, Value)] -> Either RuntimeError (Text, Aeson.Value, Text)
parseObjectArgs args = do
  prompt <- expectString (Ident "prompt") args
  schema <- expectSchema (Ident "schema") args
  model <- expectString (Ident "model") args
  pure (prompt, schema, model)

expectSchema :: Ident -> [(Maybe Ident, Value)] -> Either RuntimeError Aeson.Value
expectSchema n args = case lookupNamed n args of
  Just (VSchema v) -> Right v
  Just _ -> Left (HostErr ("expected Schema for " <> unIdent n <> " (use schema(T))"))
  Nothing -> Left (HostErr ("missing named argument: " <> unIdent n))

expectString :: Ident -> [(Maybe Ident, Value)] -> Either RuntimeError Text
expectString n args = case lookupNamed n args of
  Just (VString t) -> Right t
  Just (VSecret _) -> Left (HostErr ("secret not allowed for " <> unIdent n))
  Just _ -> Left (HostErr ("expected String for " <> unIdent n))
  Nothing -> Left (HostErr ("missing named argument: " <> unIdent n))

fileRefArg :: [(Maybe Ident, Value)] -> Either RuntimeError Text
fileRefArg args = case lookupNamed (Ident "path") args of
  Just v -> fileRefValue v
  Nothing -> case lookupPositional 0 args of
    Just v -> fileRefValue v
    Nothing -> Left (HostErr "fs.read expects a FileRef path")

fileRefValue :: Value -> Either RuntimeError Text
fileRefValue = \case
  VString t -> Right t
  VSecret _ -> Left (HostErr "FileRef must not be Secret at runtime")
  _ -> Left (HostErr "FileRef must be a path string at runtime")

lookupNamed :: Ident -> [(Maybe Ident, Value)] -> Maybe Value
lookupNamed n args = lookup (Just n) args

lookupPositional :: Int -> [(Maybe Ident, Value)] -> Maybe Value
lookupPositional i args =
  let positionals = [v | (Nothing, v) <- args]
   in if i >= 0 && i < length positionals
        then Just (positionals !! i)
        else Nothing
