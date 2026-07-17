-- | Host op values and dispatch. Surface names match Check.Prelude stubs
-- (@fs.read@, @fs.write@, @llm.chat@, @exec.run@, …) — one API surface,
-- check-time types + runtime implementations.
module Hwfl.Runtime.Host
  ( HostEnv (..),
    HostResult (..),
    hostOpsEnv,
    runHostOp,
    execNeedsConfirm,
  )
where

import Data.Aeson (object, (.=))
import Data.Aeson qualified as Aeson
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hwfl.Ast.Module (Frontmatter (..), LoadedModule (..))
import Hwfl.Ast.Name (Ident (..), qnameToText)
import Hwfl.Check.Error (renderCheckError)
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Check.Project (checkProject, renderProjectCheckError)
import Hwfl.Eval.Value
import Hwfl.Json.Encode (jsonToValue)
import Hwfl.Llm.Pricing (ModelPricing, providerCloseAttrs)
import Hwfl.Llm.Provider (LlmProvider (..))
import Hwfl.Llm.Types
  ( ChatRequest (..),
    Message (..),
    ProviderResult (..),
    Role (..),
    emptyChatRequest,
    renderProviderError,
  )
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Project (ExecPolicy (..))
import Hwfl.Runtime.Error (RuntimeError (..))
import Hwfl.Runtime.Exec (ExecArgs (..), ExecOutcome (..), runExec)
import Hwfl.Runtime.Skills (discoverSkillsResult, loadSkillScripted)
import Hwfl.Runtime.Workspace
  ( Workspace,
    editFile,
    findFiles,
    grepFiles,
    listDir,
    readTextFile,
    readTextSlice,
    removePath,
    workspaceRoot,
    writeTextFile,
  )
import Hwfl.SkillCatalog (SkillCatalog)
import Hwfl.Source (renderDiagnostics)
import System.FilePath ((</>))

-- | Effectful dependencies for host ops (workspace + provider + exec policy).
data HostEnv = HostEnv
  { heWorkspace :: Workspace,
    heProvider :: LlmProvider,
    -- | 'Nothing' when no project @exec@ policy is configured.
    heExec :: Maybe ExecPolicy,
    heSkillCatalog :: SkillCatalog,
    hePricing :: ModelPricing,
    heLog :: Text -> IO ()
  }

-- | Host outcome with redacted close-attrs for the span.
data HostResult = HostResult
  { hrValue :: Value,
    hrCloseAttrs :: Aeson.Value
  }

-- | Whether @exec.run@ should pause for human confirm before spawn.
execNeedsConfirm :: HostEnv -> Bool
execNeedsConfirm env = case env.heExec of
  Just pol -> pol.execConfirm
  Nothing -> False

-- | Eval bindings for host modules — mirrors Check.Prelude record shapes.
hostOpsEnv :: Env
hostOpsEnv =
  Map.fromList
    [ ( Ident "fs",
        VRecord
          [ (Ident "read", VHostOp HostFsRead),
            (Ident "write", VHostOp HostFsWrite),
            (Ident "find", VHostOp HostFsFind),
            (Ident "list", VHostOp HostFsList),
            (Ident "edit", VHostOp HostFsEdit),
            (Ident "grep", VHostOp HostFsGrep),
            (Ident "read_slice", VHostOp HostFsReadSlice),
            (Ident "remove", VHostOp HostFsRemove)
          ]
      ),
      ( Ident "exec",
        VRecord
          [ (Ident "run", VHostOp HostExecRun)
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
      ),
      ( Ident "skill",
        VRecord
          [ (Ident "discover", VHostOp HostSkillDiscover),
            (Ident "load", VHostOp HostSkillLoad)
          ]
      )
    ]

-- | Execute one host op (one transition / snapshot boundary).
-- @human.confirm@ / @obs.span@ / @obs.log@ / @llm.agent@ / @llm.agent_object@
-- / confirm-gated @exec.run@ are handled by the machine driver.
runHostOp ::
  HostEnv ->
  HostOpId ->
  [(Maybe Ident, Value)] ->
  IO (Either RuntimeError HostResult)
runHostOp env op args = case op of
  HostFsRead -> doFsRead env args
  HostFsWrite -> doFsWrite env args
  HostFsFind -> doFsFind env args
  HostFsList -> doFsList env args
  HostFsEdit -> doFsEdit env args
  HostFsGrep -> doFsGrep env args
  HostFsReadSlice -> doFsReadSlice env args
  HostFsRemove -> doFsRemove env args
  HostExecRun -> doExecRun env args
  HostLlmChat -> doLlmChat env args
  HostLlmObject -> doLlmObject env args
  HostMetaCheckModule -> doMetaCheckModule env args
  HostMetaCheckProject -> doMetaCheckProject env args
  HostSkillDiscover -> doSkillDiscover env args
  HostSkillLoad -> doSkillLoad env args
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

doSkillDiscover :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError HostResult)
doSkillDiscover env args = pure $ case skillDiscoverArgs args of
  Left e -> Left e
  Right (query, kinds, limit) ->
    let v = discoverSkillsResult env.heSkillCatalog query kinds limit
     in Right (HostResult v (object ["hits" .= skillHitCount v]))

doSkillLoad :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError HostResult)
doSkillLoad env args = pure $ case skillIdArg args of
  Left e -> Left e
  Right skillId ->
    let v = loadSkillScripted env.heSkillCatalog skillId
     in Right (HostResult v (object ["id" .= skillId]))

skillDiscoverArgs :: [(Maybe Ident, Value)] -> Either RuntimeError (Text, [Text], Int)
skillDiscoverArgs args = do
  query <- case lookupNamed (Ident "query") args of
    Just (VString q) -> Right q
    Just _ -> Left (HostErr "skill.discover.query must be a String")
    Nothing -> Right ""
  kinds <- case lookupNamed (Ident "kinds") args of
    Just (VList xs) -> traverse expectStringVal xs
    Just _ -> Left (HostErr "skill.discover.kinds must be a List<String>")
    Nothing -> Right []
  let limit = case lookupNamed (Ident "limit") args of
        Just (VInt n) | n > 0 -> fromIntegral n
        _ -> 20
  pure (query, kinds, limit)
  where
    expectStringVal = \case
      VString s -> Right s
      _ -> Left (HostErr "skill.discover.kinds elements must be strings")

skillIdArg :: [(Maybe Ident, Value)] -> Either RuntimeError Text
skillIdArg args = case lookupNamed (Ident "id") args of
  Just (VString s) -> Right s
  Just _ -> Left (HostErr "skill.load.id must be a String")
  Nothing -> Left (HostErr "skill.load missing id")

skillHitCount :: Value -> Int
skillHitCount = \case
  VRecord fs -> case lookup (Ident "skills") fs of
    Just (VList xs) -> length xs
    _ -> 0
  _ -> 0

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

doFsList :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError HostResult)
doFsList env args = case fileRefArg args of
  Left e -> pure (Left e)
  Right path -> do
    env.heLog ("fs.list " <> path)
    result <- listDir env.heWorkspace path
    pure $ case result of
      Left e -> Left e
      Right entries ->
        Right
          ( HostResult
              ( VList
                  [ VRecord
                      [ (Ident "name", VString name),
                        (Ident "kind", VString kind)
                      ]
                    | (name, kind) <- entries
                  ]
              )
              (object ["count" .= length entries])
          )

doFsEdit :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError HostResult)
doFsEdit env args = case parseEditArgs args of
  Left e -> pure (Left e)
  Right (path, old, new) -> do
    env.heLog ("fs.edit " <> path)
    result <- editFile env.heWorkspace path old new
    pure $ case result of
      Left e -> Left e
      Right (ok, n) ->
        Right
          ( HostResult
              (VRecord [(Ident "ok", VBool ok)])
              (object ["replacements" .= n, "ok" .= ok])
          )

doFsGrep :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError HostResult)
doFsGrep env args = case parseGrepArgs args of
  Left e -> pure (Left e)
  Right (pattern, glob) -> do
    env.heLog ("fs.grep " <> pattern)
    result <- grepFiles env.heWorkspace pattern glob
    pure $ case result of
      Left e -> Left e
      Right hits ->
        Right
          ( HostResult
              ( VList
                  [ VRecord
                      [ (Ident "file", VString file),
                        (Ident "line", VInt (fromIntegral line)),
                        (Ident "text", VString text)
                      ]
                    | (file, line, text) <- hits
                  ]
              )
              (object ["count" .= length hits])
          )

doFsReadSlice :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError HostResult)
doFsReadSlice env args = case parseReadSliceArgs args of
  Left e -> pure (Left e)
  Right (path, startLine, endLine) -> do
    env.heLog ("fs.read_slice " <> path)
    result <- readTextSlice env.heWorkspace path startLine endLine
    pure $ case result of
      Left e -> Left e
      Right txt ->
        Right
          ( HostResult
              (VRecord [(Ident "text", VString txt)])
              ( object
                  [ "bytes" .= T.length txt,
                    "start_line" .= startLine,
                    "end_line" .= endLine
                  ]
              )
          )

doFsRemove :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError HostResult)
doFsRemove env args =
  case lookupNamed (Ident "path") args `orElsePos` lookupPositional 0 args of
    Nothing -> pure (Left (HostErr "fs.remove expects a FileRef path"))
    Just v ->
      case fileRefValue v of
        Left e -> pure (Left e)
        Right path -> do
          env.heLog ("fs.remove " <> path)
          result <- removePath env.heWorkspace path
          pure $ case result of
            Left e -> Left e
            Right () -> Right (HostResult VUnit (object ["path" .= path]))
  where
    orElsePos (Just x) _ = Just x
    orElsePos Nothing y = y

doExecRun :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError HostResult)
doExecRun env args = case env.heExec of
  Nothing ->
    pure
      ( Left
          ( HostErr
              "exec.run requires project.json exec.allow (Exec effect not configured)"
          )
      )
  Just policy -> case parseExecArgs args of
    Left e -> pure (Left e)
    Right ea -> do
      env.heLog ("exec.run " <> ea.eaProgram)
      result <- runExec env.heWorkspace policy ea
      pure $ case result of
        Left e -> Left e
        Right eo ->
          Right
            ( HostResult
                ( VRecord
                    [ (Ident "exit_code", VInt (fromIntegral eo.eoExitCode)),
                      (Ident "stdout", VString eo.eoStdout),
                      (Ident "stderr", VString eo.eoStderr),
                      (Ident "timed_out", VBool eo.eoTimedOut)
                    ]
                )
                ( object
                    [ "exit_code" .= eo.eoExitCode,
                      "stdout_bytes" .= eo.eoStdoutBytes,
                      "stderr_bytes" .= eo.eoStderrBytes,
                      "timed_out" .= eo.eoTimedOut
                    ]
                )
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

parseEditArgs :: [(Maybe Ident, Value)] -> Either RuntimeError (Text, Text, Text)
parseEditArgs args = do
  path <- case lookupNamed (Ident "path") args of
    Just v -> fileRefValue v
    Nothing -> case lookupPositional 0 args of
      Just v -> fileRefValue v
      Nothing -> Left (HostErr "fs.edit expects path: FileRef")
  old <- expectStringOrPos (Ident "old") 1 args
  new <- expectStringOrPos (Ident "new") 2 args
  pure (path, old, new)

parseGrepArgs :: [(Maybe Ident, Value)] -> Either RuntimeError (Text, Text)
parseGrepArgs args = do
  pattern <- expectStringOrPos (Ident "pattern") 0 args
  let glob = case lookupNamed (Ident "glob") args of
        Just (VString t) -> t
        Just _ -> ""
        Nothing -> case lookupPositional 1 args of
          Just (VString t) -> t
          _ -> ""
  pure (pattern, glob)

parseReadSliceArgs :: [(Maybe Ident, Value)] -> Either RuntimeError (Text, Int, Int)
parseReadSliceArgs args = do
  path <- case lookupNamed (Ident "path") args of
    Just v -> fileRefValue v
    Nothing -> case lookupPositional 0 args of
      Just v -> fileRefValue v
      Nothing -> Left (HostErr "fs.read_slice expects path: FileRef")
  startLine <- expectIntOrPos (Ident "start_line") 1 args
  endLine <- expectIntOrPos (Ident "end_line") 2 args
  pure (path, startLine, endLine)

parseExecArgs :: [(Maybe Ident, Value)] -> Either RuntimeError ExecArgs
parseExecArgs args = do
  program <- expectString (Ident "program") args
  argv <- expectStringList (Ident "args") args
  stdin <- case lookupNamed (Ident "stdin") args of
    Just (VString t) -> Right t
    Just _ -> Left (HostErr "expected String for stdin")
    Nothing -> Right ""
  pure ExecArgs {eaProgram = program, eaArgs = argv, eaStdin = stdin}

expectStringList :: Ident -> [(Maybe Ident, Value)] -> Either RuntimeError [Text]
expectStringList n args = case lookupNamed n args of
  Just (VList xs) -> traverse asString xs
  Just _ -> Left (HostErr ("expected List<String> for " <> unIdent n))
  Nothing -> Left (HostErr ("missing named argument: " <> unIdent n))
  where
    asString = \case
      VString t -> Right t
      _ -> Left (HostErr ("expected String elements in " <> unIdent n))

expectStringOrPos :: Ident -> Int -> [(Maybe Ident, Value)] -> Either RuntimeError Text
expectStringOrPos n i args = case lookupNamed n args of
  Just (VString t) -> Right t
  Just (VSecret _) -> Left (HostErr ("secret not allowed for " <> unIdent n))
  Just _ -> Left (HostErr ("expected String for " <> unIdent n))
  Nothing -> case lookupPositional i args of
    Just (VString t) -> Right t
    _ -> Left (HostErr ("missing argument: " <> unIdent n))

expectIntOrPos :: Ident -> Int -> [(Maybe Ident, Value)] -> Either RuntimeError Int
expectIntOrPos n i args = case lookupNamed n args of
  Just (VInt v) -> Right (fromIntegral v)
  Just _ -> Left (HostErr ("expected Int for " <> unIdent n))
  Nothing -> case lookupPositional i args of
    Just (VInt v) -> Right (fromIntegral v)
    _ -> Left (HostErr ("missing argument: " <> unIdent n))

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
              (providerCloseAttrs env.hePricing model pr)
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
                (providerCloseAttrs env.hePricing model pr)
            )

decodeJsonObject :: Text -> Either Text Value
decodeJsonObject txt =
  case Aeson.eitherDecodeStrict' (TE.encodeUtf8 txt) of
    Left err -> Left ("llm.object: invalid JSON response: " <> T.pack err)
    Right (v :: Aeson.Value) -> Right (jsonToValue v)

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
lookupNamed n = lookup (Just n)

lookupPositional :: Int -> [(Maybe Ident, Value)] -> Maybe Value
lookupPositional i args =
  let positionals = [v | (Nothing, v) <- args]
   in if i >= 0 && i < length positionals
        then Just (positionals !! i)
        else Nothing
