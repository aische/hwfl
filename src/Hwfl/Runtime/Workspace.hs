-- | Workspace sandbox: canonical root + two-stage path containment
-- (lexical resolve, then canonicalize + prefix check). Symlink escape fails hard.
module Hwfl.Runtime.Workspace
  ( Workspace,
    workspaceRoot,
    newWorkspace,
    resolvePath,
    resolveContainedPath,
    readTextFile,
    readTextSlice,
    writeTextFile,
    findFiles,
    listDir,
    editFile,
    grepFiles,
    removePath,
  )
where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Hwfl.Runtime.Error (RuntimeError (..))
import System.Directory
  ( canonicalizePath,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    getFileSize,
    listDirectory,
    removeDirectoryRecursive,
    removeFile,
  )
import System.FilePath
  ( isAbsolute,
    joinPath,
    makeRelative,
    splitDirectories,
    takeDirectory,
    takeExtension,
    takeFileName,
    (</>),
  )
import Text.Regex.TDFA (Regex, defaultCompOpt, defaultExecOpt, matchTest)
import Text.Regex.TDFA.String (compile)

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

-- | Read a 1-based inclusive line range from a UTF-8 text file.
readTextSlice :: Workspace -> Text -> Int -> Int -> IO (Either RuntimeError Text)
readTextSlice ws rel startLine endLine
  | startLine < 1 =
      pure (Left (HostErr "fs.read_slice start_line must be >= 1"))
  | endLine < startLine =
      pure (Left (HostErr "fs.read_slice end_line must be >= start_line"))
  | otherwise = do
      r <- readTextFile ws rel
      pure $ case r of
        Left e -> Left e
        Right txt ->
          let fileLines = T.lines txt
              slice = drop (startLine - 1) (take endLine fileLines)
           in Right (T.unlines slice)

-- | Write UTF-8 text, creating parent dirs inside the sandbox as needed.
writeTextFile :: Workspace -> Text -> Text -> IO (Either RuntimeError ())
writeTextFile ws rel content = do
  -- For writes to new paths, canonicalize the parent then append the basename.
  case resolvePath ws rel of
    Left e -> pure (Left e)
    Right path -> do
      let parent = takeDirectory path
      parentCanon <-
        try
          ( do
              createDirectoryIfMissing True parent
              canonicalizePath parent
          ) ::
          IO (Either IOException FilePath)
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

-- | Find workspace-relative files matching a simple glob.
-- Supported: @**/*.ext@ (recursive) and @*.ext@ (workspace root only).
findFiles :: Workspace -> Text -> IO (Either RuntimeError [Text])
findFiles ws glob = case parseGlob glob of
  Left e -> pure (Left e)
  Right pat -> do
    let root = workspaceRoot ws
    paths <- try (walk root "" pat) :: IO (Either IOException [FilePath])
    pure $ case paths of
      Left ex -> Left (HostErr ("fs.find failed: " <> T.pack (show ex)))
      Right ps -> Right (map T.pack ps)

data GlobPat
  = GlobRecursiveExt String
  | GlobRootExt String

parseGlob :: Text -> Either RuntimeError GlobPat
parseGlob g = case T.stripPrefix "**/*" g of
  Just ext | not (T.null ext) && T.head ext == '.' -> Right (GlobRecursiveExt (T.unpack ext))
  _ -> case T.stripPrefix "*" g of
    Just ext | not (T.null ext) && T.head ext == '.' -> Right (GlobRootExt (T.unpack ext))
    _ -> Left (HostErr ("fs.find: unsupported glob (use **/*.md or *.md): " <> g))

walk :: FilePath -> FilePath -> GlobPat -> IO [FilePath]
walk absRoot relDir pat = do
  let absDir = if null relDir then absRoot else absRoot </> relDir
  names <- listDirectory absDir
  fmap concat $ traverse (one absRoot relDir pat) names

one :: FilePath -> FilePath -> GlobPat -> FilePath -> IO [FilePath]
one absRoot relDir pat name = do
  let rel = if null relDir then name else relDir </> name
      absPath = absRoot </> rel
  isDir <- doesDirectoryExist absPath
  if isDir
    then case pat of
      GlobRecursiveExt _ -> walk absRoot rel pat
      GlobRootExt _ -> pure []
    else
      pure $
        if matchPat pat name
          then [rel]
          else []

matchPat :: GlobPat -> FilePath -> Bool
matchPat pat name = case pat of
  GlobRecursiveExt ext -> takeExtension name == ext
  GlobRootExt ext -> takeExtension name == ext

-- | List a workspace directory as @{ name, kind }@ entries (@file@ / @dir@).
listDir :: Workspace -> Text -> IO (Either RuntimeError [(Text, Text)])
listDir ws rel = do
  resolved <- resolveContainedPath ws rel
  case resolved of
    Left e -> pure (Left e)
    Right path -> do
      exists <- doesDirectoryExist path
      if not exists
        then pure (Left (HostErr ("not a directory: '" <> rel <> "'")))
        else do
          result <- try (listDirectory path) :: IO (Either IOException [FilePath])
          case result of
            Left ex ->
              pure (Left (HostErr ("list failed for '" <> rel <> "': " <> T.pack (show ex))))
            Right entries -> do
              kinds <- traverse (classify path) (sort entries)
              pure (Right kinds)
  where
    classify parent name = do
      isDir <- doesDirectoryExist (parent </> name)
      pure (T.pack name, if isDir then "dir" else "file")

-- | Remove a workspace file or directory tree. Cannot delete the workspace root.
removePath :: Workspace -> Text -> IO (Either RuntimeError ())
removePath ws rel = do
  resolved <- resolveContainedPath ws rel
  case resolved of
    Left e -> pure (Left e)
    Right path ->
      if path == workspaceRoot ws
        then pure (Left (SandboxErr ("cannot remove workspace root: " <> rel)))
        else do
          isFile <- doesFileExist path
          isDir <- doesDirectoryExist path
          if not isFile && not isDir
            then pure (Left (HostErr ("path not found: '" <> rel <> "'")))
            else do
              result <-
                try
                  ( if isDir
                      then removeDirectoryRecursive path
                      else removeFile path
                  ) ::
                  IO (Either IOException ())
              pure $ case result of
                Left ex ->
                  Left (HostErr ("remove failed for '" <> rel <> "': " <> T.pack (show ex)))
                Right () -> Right ()

-- | Literal whole-string replacement. Returns @(ok, replacements)@ where
-- @ok@ is true iff at least one occurrence was replaced. Empty @old@ is an error.
editFile :: Workspace -> Text -> Text -> Text -> IO (Either RuntimeError (Bool, Int))
editFile ws rel old new
  | T.null old = pure (Left (HostErr "fs.edit 'old' must be a non-empty string"))
  | otherwise = do
      r <- readTextFile ws rel
      case r of
        Left e -> pure (Left e)
        Right text -> do
          let n = T.count old text
          if n == 0
            then pure (Right (False, 0))
            else do
              w <- writeTextFile ws rel (T.replace old new text)
              pure $ case w of
                Left e -> Left e
                Right () -> Right (True, n)

maxGrepFileBytes :: Integer
maxGrepFileBytes = 1024 * 1024

binarySniffBytes :: Int
binarySniffBytes = 8000

-- | Regex-search workspace files. @glob@ empty ⇒ all text files under the
-- workspace root; otherwise the same globs as 'findFiles' (@**\/*.ext@ / @*.ext@).
-- Hits are @(file, 1-based line, line text)@.
grepFiles :: Workspace -> Text -> Text -> IO (Either RuntimeError [(Text, Int, Text)])
grepFiles ws pattern glob = case compileRegex pattern of
  Left e -> pure (Left e)
  Right regex -> do
    filesE <-
      if T.null (T.strip glob)
        then listAllTextFiles ws
        else findFiles ws glob
    case filesE of
      Left e -> pure (Left e)
      Right files -> do
        hits <- concat <$> traverse (grepOne ws regex) files
        pure (Right hits)

compileRegex :: Text -> Either RuntimeError Regex
compileRegex pattern = case compile defaultCompOpt defaultExecOpt (T.unpack pattern) of
  Left err -> Left (HostErr ("invalid grep pattern: " <> T.pack err))
  Right r -> Right r

grepOne :: Workspace -> Regex -> Text -> IO [(Text, Int, Text)]
grepOne ws regex rel = do
  resolved <- resolveContainedPath ws rel
  case resolved of
    Left _ -> pure []
    Right path -> do
      skip <- isBinaryOrBig path
      if skip
        then pure []
        else do
          result <- try (BS.readFile path) :: IO (Either IOException BS.ByteString)
          pure $ case result of
            Left _ -> []
            Right bytes -> case decodeUtf8' bytes of
              Left _ -> []
              Right content ->
                [ (rel, n, line)
                  | (n, line) <- zip [1 ..] (T.lines content),
                    matchTest regex (T.unpack line)
                ]

isBinaryOrBig :: FilePath -> IO Bool
isBinaryOrBig path = do
  sizeE <- try (getFileSize path) :: IO (Either IOException Integer)
  case sizeE of
    Left _ -> pure True
    Right sz
      | sz > maxGrepFileBytes -> pure True
      | otherwise -> do
          sniffE <- try (BS.readFile path) :: IO (Either IOException BS.ByteString)
          pure $ case sniffE of
            Left _ -> True
            Right bs -> 0 `BS.elem` BS.take binarySniffBytes bs

listAllTextFiles :: Workspace -> IO (Either RuntimeError [Text])
listAllTextFiles ws = do
  paths <- try (walkAll (workspaceRoot ws) "") :: IO (Either IOException [FilePath])
  pure $ case paths of
    Left ex -> Left (HostErr ("fs.grep walk failed: " <> T.pack (show ex)))
    Right ps -> Right (map T.pack (sort ps))

walkAll :: FilePath -> FilePath -> IO [FilePath]
walkAll absRoot relDir = do
  let absDir = if null relDir then absRoot else absRoot </> relDir
  names <- listDirectory absDir
  fmap concat $ traverse (oneFile absRoot relDir) names

oneFile :: FilePath -> FilePath -> FilePath -> IO [FilePath]
oneFile absRoot relDir name
  | "." `T.isPrefixOf` T.pack name && name /= "." && name /= ".." = pure []
  | otherwise = do
      let rel = if null relDir then name else relDir </> name
          absPath = absRoot </> rel
      isDir <- doesDirectoryExist absPath
      if isDir
        then
          if name == ".hwfl"
            then pure []
            else walkAll absRoot rel
        else do
          isFile <- doesFileExist absPath
          pure (if isFile then [rel] else [])
