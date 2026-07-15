-- | Host op values and dispatch. Surface names match Check.Prelude stubs
-- (@fs.read@, @fs.write@, @llm.chat@) — one API surface, check-time types +
-- runtime implementations.
module Pml.Runtime.Host
  ( HostEnv (..),
    hostOpsEnv,
    runHostOp,
  )
where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Pml.Ast.Name (Ident (..))
import Pml.Eval.Value
import Pml.Llm.Provider (LlmProvider (..))
import Pml.Llm.Types
import Pml.Runtime.Error (RuntimeError (..))
import Pml.Runtime.Workspace (Workspace, readTextFile, writeTextFile)

-- | Effectful dependencies for host ops (workspace + provider).
data HostEnv = HostEnv
  { heWorkspace :: Workspace,
    heProvider :: LlmProvider,
    heLog :: Text -> IO ()
  }

-- | Eval bindings for host modules — mirrors Check.Prelude record shapes.
hostOpsEnv :: Env
hostOpsEnv =
  Map.fromList
    [ ( Ident "fs",
        VRecord
          [ (Ident "read", VHostOp HostFsRead),
            (Ident "write", VHostOp HostFsWrite)
          ]
      ),
      ( Ident "llm",
        VRecord
          [ (Ident "chat", VHostOp HostLlmChat)
          ]
      )
    ]

-- | Execute one host op (one transition / snapshot boundary).
runHostOp ::
  HostEnv ->
  HostOpId ->
  [(Maybe Ident, Value)] ->
  IO (Either RuntimeError Value)
runHostOp env op args = case op of
  HostFsRead -> doFsRead env args
  HostFsWrite -> doFsWrite env args
  HostLlmChat -> doLlmChat env args

doFsRead :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError Value)
doFsRead env args = case fileRefArg args of
  Left e -> pure (Left e)
  Right path -> do
    env.heLog ("fs.read " <> path)
    result <- readTextFile env.heWorkspace path
    pure $ case result of
      Left e -> Left e
      Right txt -> Right (VRecord [(Ident "text", VString txt)])

doFsWrite :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError Value)
doFsWrite env args =
  case (pathArg, textArg) of
    (Right path, Just (VString txt)) -> do
      env.heLog ("fs.write " <> path)
      result <- writeTextFile env.heWorkspace path txt
      pure $ case result of
        Left e -> Left e
        Right () -> Right VUnit
    (Left e, _) -> pure (Left e)
    (_, _) -> pure (Left (HostErr "fs.write expects path: FileRef and text: String"))
  where
    pathArg = case lookupNamed (Ident "path") args of
      Just v -> fileRefValue v
      Nothing -> fileRefArg args
    textArg = lookupNamed (Ident "text") args

doLlmChat :: HostEnv -> [(Maybe Ident, Value)] -> IO (Either RuntimeError Value)
doLlmChat env args = case parseChatArgs args of
  Left e -> pure (Left e)
  Right (system, prompt, model) -> do
    env.heLog ("llm.chat model=" <> model)
    let req =
          ChatRequest
            { chatMessages =
                [ Message RoleSystem system,
                  Message RoleUser prompt
                ],
              chatModel = model,
              chatResponseFormat = Nothing
            }
    result <- env.heProvider.llmChat req
    pure $ case result of
      Left pe -> Left (ProviderErr (renderProviderError pe))
      Right pr -> Right (VString pr.prContent)

parseChatArgs :: [(Maybe Ident, Value)] -> Either RuntimeError (Text, Text, Text)
parseChatArgs args = do
  system <- expectString (Ident "system") args
  prompt <- expectString (Ident "prompt") args
  model <- expectString (Ident "model") args
  pure (system, prompt, model)

expectString :: Ident -> [(Maybe Ident, Value)] -> Either RuntimeError Text
expectString n args = case lookupNamed n args of
  Just (VString t) -> Right t
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
  _ -> Left (HostErr "FileRef must be a path string at runtime")

lookupNamed :: Ident -> [(Maybe Ident, Value)] -> Maybe Value
lookupNamed n args = lookup (Just n) args

lookupPositional :: Int -> [(Maybe Ident, Value)] -> Maybe Value
lookupPositional i args =
  let positionals = [v | (Nothing, v) <- args]
   in if i >= 0 && i < length positionals
        then Just (positionals !! i)
        else Nothing
