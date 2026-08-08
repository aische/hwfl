-- | Bounded YAML decode for module frontmatter.
--
-- 'Data.Yaml.decodeEither'' expands aliases eagerly into an unshared tree, so a
-- tiny anchor/alias DAG can OOM the loader. This module streams libyaml events
-- first, rejects aliases and duplicate mapping keys, and caps nesting / node
-- count before the ordinary aeson decode runs.
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
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8')
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

-- | Stream events; reject aliases, duplicate keys, and oversized documents.
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

-- | Mapping / sequence frame while walking events.
data Frame
  = -- | Keys seen so far, and whether the next node is a key.
    FMap !(Set Text) !Bool
  | FSeq

sinkCheck :: IORef Int -> IORef Int -> ConduitT Event o (ResourceT IO) (Either Text ())
sinkCheck depthRef nodesRef = go []
  where
    go stack = do
      me <- await
      case me of
        Nothing -> pure (Right ())
        Just ev -> case ev of
          EventAlias _ ->
            pure (Left "YAML aliases are not allowed in frontmatter")
          EventSequenceStart {} ->
            afterBump (FSeq : stack) =<< bumpCollection
          EventMappingStart {} ->
            afterBump (FMap Set.empty True : stack) =<< bumpCollection
          EventSequenceEnd -> endCollection stack
          EventMappingEnd -> endCollection stack
          EventScalar bs _ _ _ -> handleScalar stack bs
          _ -> go stack

    afterBump stack = \case
      Left err -> pure (Left err)
      Right () -> go stack

    endCollection stack = case stack of
      [] -> go []
      (_ : parent) -> do
        decDepth
        go (afterNode parent)

    handleScalar stack bs = case stack of
      (FMap seen True : rest) ->
        let key = scalarKey bs
         in if Set.member key seen
              then
                pure
                  ( Left
                      ( "YAML duplicate key: "
                          <> key
                      )
                  )
              else
                afterBump (FMap (Set.insert key seen) False : rest)
                  =<< bumpNode
      (FMap seen False : rest) ->
        afterBump (FMap seen True : rest) =<< bumpNode
      _ -> afterBump stack =<< bumpNode

    -- | A nested collection just finished; advance the parent map key/value phase.
    afterNode [] = []
    afterNode (FMap seen True : rest) = FMap seen False : rest
    afterNode (FMap seen False : rest) = FMap seen True : rest
    afterNode (FSeq : rest) = FSeq : rest

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
      let n' = n + 1
      writeIORef nodesRef n'
      depth <- readIORef depthRef
      pure $
        if depth > maxYamlDepth
          then Left ("YAML nesting exceeds " <> T.pack (show maxYamlDepth))
          else
            if n' > maxYamlNodes
              then Left ("YAML node count exceeds " <> T.pack (show maxYamlNodes))
              else Right ()

scalarKey :: ByteString -> Text
scalarKey bs = case decodeUtf8' bs of
  Right t -> t
  Left _ -> T.pack (show bs)
