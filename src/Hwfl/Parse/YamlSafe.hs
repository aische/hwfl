-- | Bounded YAML decode for module frontmatter.
--
-- 'Data.Yaml.decodeEither'' expands aliases eagerly into an unshared tree, so a
-- tiny anchor/alias DAG can OOM the loader. This module streams libyaml events
-- first, rejects aliases, and caps nesting / node count before the ordinary
-- aeson decode runs.
module Hwfl.Parse.YamlSafe
  ( decodeYamlValue,
  )
where

import Control.Exception (SomeException, displayException, try)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Resource (ResourceT)
import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Data.Conduit (ConduitT, await, runConduitRes, (.|))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import Hwfl.Limits (maxYamlDepth, maxYamlNodes)
import System.IO.Unsafe (unsafePerformIO)
import Text.Libyaml (Event (..), decode)

-- | Decode a YAML document under frontmatter resource limits.
decodeYamlValue :: ByteString -> Either Text Value
decodeYamlValue bs = do
  validateYamlEvents bs
  case Yaml.decodeEither' bs of
    Left err -> Left (T.pack (Yaml.prettyPrintParseException err))
    Right v -> Right v

-- | Stream events; reject aliases and oversized documents.
validateYamlEvents :: ByteString -> Either Text ()
validateYamlEvents bs = unsafePerformIO $ do
  depthRef <- newIORef (0 :: Int)
  nodesRef <- newIORef (0 :: Int)
  r <-
    try $
      runConduitRes $
        decode bs .| sinkCheck depthRef nodesRef
  pure $ case r of
    Left (e :: SomeException) -> Left (T.pack (displayException e))
    Right (Left msg) -> Left msg
    Right (Right ()) -> Right ()
{-# NOINLINE validateYamlEvents #-}

sinkCheck :: IORef Int -> IORef Int -> ConduitT Event o (ResourceT IO) (Either Text ())
sinkCheck depthRef nodesRef = go
  where
    go = do
      me <- await
      case me of
        Nothing -> pure (Right ())
        Just ev -> case ev of
          EventAlias _ ->
            pure (Left "YAML aliases are not allowed in frontmatter")
          EventSequenceStart {} -> bumpCollection >> continueOrStop
          EventMappingStart {} -> bumpCollection >> continueOrStop
          EventSequenceEnd -> decDepth >> go
          EventMappingEnd -> decDepth >> go
          EventScalar {} -> bumpNode >> continueOrStop
          _ -> go

    continueOrStop = do
      depth <- liftIO (readIORef depthRef)
      nodes <- liftIO (readIORef nodesRef)
      if depth > maxYamlDepth
        then pure (Left ("YAML nesting exceeds " <> T.pack (show maxYamlDepth)))
        else
          if nodes > maxYamlNodes
            then pure (Left ("YAML node count exceeds " <> T.pack (show maxYamlNodes)))
            else go

    bumpCollection = do
      liftIO $ do
        d <- readIORef depthRef
        writeIORef depthRef (d + 1)
      bumpNode

    decDepth = liftIO $ do
      d <- readIORef depthRef
      when (d > 0) (writeIORef depthRef (d - 1))

    bumpNode = liftIO $ do
      n <- readIORef nodesRef
      writeIORef nodesRef (n + 1)
