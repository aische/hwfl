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
import Pml.Ast.Name (Ident (..))
import Pml.Eval.Value
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
import Pml.Runtime.Error (RuntimeError (..))
import Pml.Runtime.Workspace (Workspace, readTextFile, writeTextFile)

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
            (Ident "write", VHostOp HostFsWrite)
          ]
      ),
      ( Ident "llm",
        VRecord
          [ (Ident "chat", VHostOp HostLlmChat),
            (Ident "agent", VHostOp HostLlmAgent)
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
      )
    ]

-- | Execute one host op (one transition / snapshot boundary).
-- @human.confirm@ / @obs.span@ / @obs.log@ / @llm.agent@ are handled by the machine driver.
runHostOp ::
  HostEnv ->
  HostOpId ->
  [(Maybe Ident, Value)] ->
  IO (Either RuntimeError HostResult)
runHostOp env op args = case op of
  HostFsRead -> doFsRead env args
  HostFsWrite -> doFsWrite env args
  HostLlmChat -> doLlmChat env args
  HostLlmAgent ->
    pure (Left (HostErr "llm.agent must be driven by the machine (agent loop)"))
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
