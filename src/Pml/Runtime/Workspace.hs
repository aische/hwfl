-- | Workspace sandbox: canonical root + two-stage path containment
-- (lexical resolve, then canonicalize + prefix check). Symlink escape fails hard.
module Pml.Runtime.Workspace
  ( Workspace,
    workspaceRoot,
    newWorkspace,
    resolvePath,
    resolveContainedPath,
    readTextFile,
    writeTextFile,
  )
where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Pml.Runtime.Error (RuntimeError (..))
import System.Directory
  ( canonicalizePath,
    createDirectoryIfMissing,
  )
import System.FilePath
  ( isAbsolute,
    joinPath,
    makeRelative,
    splitDirectories,
    takeDirectory,
    takeFileName,
    (</>),
  )

-- | Canonicalised workspace root.
newtype Workspace = Workspace {workspaceRoot :: FilePath}
  deriving stock (Eq, Show)

-- | Create (if needed) and canonicalise the workspace root.
newWorkspace :: FilePath -> IO Workspace
newWorkspace dir = do
  createDirectoryIfMissing True dir
  Workspace <$> canonicalizePath dir

-- | Lexical resolve of a workspace-relative path. Rejects absolute paths and
-- @..@ escape above the root.
resolvePath :: Workspace -> Text -> Either RuntimeError FilePath
resolvePath ws rel
  | isAbsolute relStr =
      Left (SandboxErr ("absolute paths are not allowed: " <> rel))
  | otherwise = case resolveSegments (splitDirectories relStr) of
      Nothing -> Left (SandboxErr ("path escapes the workspace root: " <> rel))
      Just segs -> Right (workspaceRoot ws </> joinPath segs)
  where
    relStr = T.unpack rel

resolveSegments :: [FilePath] -> Maybe [FilePath]
resolveSegments = go []
  where
    go acc [] = Just (reverse acc)
    go acc ("." : rest) = go acc rest
    go acc (".." : rest) = case acc of
      [] -> Nothing
      (_ : t) -> go t rest
    go acc (s : rest) = go (s : acc) rest

-- | Lexical resolve + canonicalize + root-prefix check (symlink containment).
resolveContainedPath :: Workspace -> Text -> IO (Either RuntimeError FilePath)
resolveContainedPath ws rel = case resolvePath ws rel of
  Left e -> pure (Left e)
  Right path -> do
    -- canonicalizePath creates nothing; for a missing file it still resolves
    -- the existing parents. Use try so IO errors become HostErr.
    result <- try (canonicalizePath path) :: IO (Either IOException FilePath)
    pure $ case result of
      Left ex -> Left (HostErr ("cannot resolve path '" <> rel <> "': " <> T.pack (show ex)))
      Right canon ->
        if isPathUnderRoot (workspaceRoot ws) canon
          then Right canon
          else Left (SandboxErr ("path escapes the workspace root: " <> rel))

isPathUnderRoot :: FilePath -> FilePath -> Bool
isPathUnderRoot root child =
  child == root
    || case makeRelative root child of
      rel | isAbsolute rel -> False
      rel -> case splitDirectories rel of
        (".." : _) -> False
        _ -> True

-- | Read a workspace file as UTF-8 text.
readTextFile :: Workspace -> Text -> IO (Either RuntimeError Text)
readTextFile ws rel = do
  resolved <- resolveContainedPath ws rel
  case resolved of
    Left e -> pure (Left e)
    Right path -> do
      result <- try (BS.readFile path) :: IO (Either IOException BS.ByteString)
      pure $ case result of
        Left ex -> Left (HostErr ("read failed for '" <> rel <> "': " <> T.pack (show ex)))
        Right bytes -> case decodeUtf8' bytes of
          Left _ -> Left (HostErr ("file '" <> rel <> "' is not valid UTF-8"))
          Right txt -> Right txt

-- | Write UTF-8 text, creating parent dirs inside the sandbox as needed.
writeTextFile :: Workspace -> Text -> Text -> IO (Either RuntimeError ())
writeTextFile ws rel content = do
  -- For writes to new paths, canonicalize the parent then append the basename.
  case resolvePath ws rel of
    Left e -> pure (Left e)
    Right path -> do
      let parent = takeDirectory path
      parentCanon <- try (do
        createDirectoryIfMissing True parent
        canonicalizePath parent) :: IO (Either IOException FilePath)
      case parentCanon of
        Left ex ->
          pure (Left (HostErr ("cannot prepare write path '" <> rel <> "': " <> T.pack (show ex))))
        Right pCanon ->
          if not (isPathUnderRoot (workspaceRoot ws) pCanon)
            then pure (Left (SandboxErr ("path escapes the workspace root: " <> rel)))
            else do
              -- Final path under canonical parent; still reject if basename is funny.
              let target = pCanon </> takeFileName path
              -- Containment of the logical target (symlink at leaf checked if exists).
              leafCheck <- try (canonicalizePath target) :: IO (Either IOException FilePath)
              case leafCheck of
                Right leafCanon
                  | not (isPathUnderRoot (workspaceRoot ws) leafCanon) ->
                      pure (Left (SandboxErr ("path escapes the workspace root: " <> rel)))
                _ -> do
                  result <- try (BS.writeFile target (encodeUtf8 content)) :: IO (Either IOException ())
                  pure $ case result of
                    Left ex ->
                      Left (HostErr ("write failed for '" <> rel <> "': " <> T.pack (show ex)))
                    Right () -> Right ()
