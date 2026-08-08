-- | Workspace sandbox: canonical root + two-stage path containment
-- (lexical resolve, then canonicalize + prefix check). Symlink escape fails hard.
--
-- Mutating operations additionally hold to three rules:
--
-- * Directory chains are created one component at a time from the canonical
--   root outwards, so a symlink in the middle of a path can never cause a
--   directory to be created outside the workspace.
-- * A leaf symlink is followed only when it resolves inside the workspace;
--   otherwise the operation fails with 'SandboxErr'.
-- * The resolved destination is opened with @O_NOFOLLOW@ (writes) or reached
--   by @rename@ (copies), neither of which can be redirected by a symlink
--   swapped in after the containment check.
--
-- This module is POSIX-only: it uses @openat@-style flags and @lstat@ from
-- the @unix@ package.
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
    patchFile,
    grepFiles,
    removePath,
    mkdirPath,
    copyPath,
    movePath,
    pathExists,
    statPath,
  )
where

import Control.Exception (IOException, bracketOnError, finally, onException, try)
import Control.Monad (foldM)
import Data.Bits ((.&.))
import Data.ByteString qualified as BS
import Data.Char (toLower)
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Foreign.C.Error (Errno (..), eLOOP, eMLINK)
import GHC.IO.Exception (IOException (ioe_errno))
import Hwfl.Runtime.Error (RuntimeError (..))
import Hwfl.Runtime.Ignore (IgnoreSet, isIgnored, loadIgnoreSet)
import System.Directory
  ( canonicalizePath,
    createDirectory,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    doesPathExist,
    getFileSize,
    listDirectory,
    pathIsSymbolicLink,
    removeDirectoryRecursive,
    removeFile,
    renamePath,
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
import System.IO
  ( IOMode (ReadMode),
    hClose,
    hSetBinaryMode,
    openBinaryTempFile,
    withBinaryFile,
  )
import System.Posix.Files (fileMode, getFileStatus, setFileMode)
import System.Posix.IO
  ( OpenFileFlags (..),
    OpenMode (WriteOnly),
    closeFd,
    defaultFileFlags,
    fdToHandle,
    openFd,
  )
import System.Posix.Types (FileMode)
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
resolvePath ws rel = (\segs -> workspaceRoot ws </> joinPath segs) <$> resolveRelSegments rel

-- | Lexical resolve to normalised path segments relative to the root.
-- @[]@ denotes the workspace root itself.
resolveRelSegments :: Text -> Either RuntimeError [FilePath]
resolveRelSegments rel
  | isAbsolute relStr =
      Left (SandboxErr ("absolute paths are not allowed: " <> rel))
  | otherwise = case resolveSegments (splitDirectories relStr) of
      Nothing -> Left (SandboxErr ("path escapes the workspace root: " <> rel))
      Just segs -> Right segs
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

-- | @True@ when @path@ is a symbolic link (including dangling). Uses @lstat@,
-- so unlike 'doesPathExist' it sees the link rather than its target.
leafIsSymlink :: FilePath -> IO Bool
leafIsSymlink path = do
  result <- try (pathIsSymbolicLink path) :: IO (Either IOException Bool)
  pure $ case result of
    Right True -> True
    _ -> False

-- | Containment for a leaf symlink: the link's own directory entry must sit
-- inside the workspace. The target is deliberately not resolved — the entry
-- is workspace-local even when it points elsewhere. Returns the link path
-- under the canonical parent.
containedLinkPath :: Workspace -> Text -> FilePath -> IO (Either RuntimeError FilePath)
containedLinkPath ws rel path = do
  parentCanon <- try (canonicalizePath (takeDirectory path)) :: IO (Either IOException FilePath)
  pure $ case parentCanon of
    Left ex ->
      Left (HostErr ("cannot resolve path '" <> rel <> "': " <> T.pack (show ex)))
    Right pCanon
      | not (isPathUnderRoot (workspaceRoot ws) pCanon) ->
          Left (SandboxErr ("path escapes the workspace root: " <> rel))
      | otherwise -> Right (pCanon </> takeFileName path)

-- | Create the directory chain @segs@ below the root, verifying containment
-- before each component is created and returning the canonical directory.
--
-- Descending one component at a time keeps the invariant that the cursor is
-- always a canonical path under the root, so 'createDirectory' can never
-- create anything outside the workspace. Creating the whole chain first and
-- checking afterwards (as @createDirectoryIfMissing@ would) leaks directories
-- through an in-workspace symlink that points out of the sandbox.
ensureDirUnderRoot :: Workspace -> Text -> [FilePath] -> IO (Either RuntimeError FilePath)
ensureDirUnderRoot ws rel = go (workspaceRoot ws)
  where
    go cur [] = pure (Right cur)
    go cur (seg : rest) = do
      let candidate = cur </> seg
      isLink <- leafIsSymlink candidate
      if isLink
        then do
          resolved <- try (canonicalizePath candidate) :: IO (Either IOException FilePath)
          case resolved of
            Left ex ->
              pure (Left (HostErr ("cannot resolve path '" <> rel <> "': " <> T.pack (show ex))))
            Right canon
              | not (isPathUnderRoot (workspaceRoot ws) canon) ->
                  pure (Left (SandboxErr ("path escapes the workspace root: " <> rel)))
              | otherwise -> do
                  isDir <- doesDirectoryExist canon
                  if isDir
                    then go canon rest
                    else pure (Left (notADirectory rel))
        else do
          isDir <- doesDirectoryExist candidate
          if isDir
            then go candidate rest
            else do
              made <- try (createDirectory candidate) :: IO (Either IOException ())
              case made of
                Right () -> go candidate rest
                Left ex -> do
                  -- Lost a race, or the component exists as a non-directory.
                  raced <- doesDirectoryExist candidate
                  if raced
                    then go candidate rest
                    else
                      pure
                        ( Left
                            ( HostErr
                                ("cannot prepare path '" <> rel <> "': " <> T.pack (show ex))
                            )
                        )

    notADirectory r = HostErr ("not a directory on the path to '" <> r <> "'")

-- | Resolve a destination for a mutating operation: create the parent chain
-- inside the sandbox, then resolve the leaf.
--
-- A leaf symlink is followed only when it resolves inside the workspace, so
-- workspace-internal aliases stay writable (symmetric with 'readTextFile')
-- while any link that resolves outside is a hard 'SandboxErr'. The returned
-- path is canonical and therefore has no symlink at its own leaf.
resolveWriteTarget :: Workspace -> Text -> IO (Either RuntimeError FilePath)
resolveWriteTarget ws rel = case resolveRelSegments rel of
  Left e -> pure (Left e)
  Right [] -> pure (Left (SandboxErr ("cannot write to the workspace root: " <> rel)))
  Right segs -> do
    parent <- ensureDirUnderRoot ws rel (init segs)
    case parent of
      Left e -> pure (Left e)
      Right pCanon -> do
        let target = pCanon </> last segs
        isLink <- leafIsSymlink target
        if not isLink
          then pure (Right target)
          else do
            resolved <- try (canonicalizePath target) :: IO (Either IOException FilePath)
            pure $ case resolved of
              Left ex ->
                Left (HostErr ("cannot resolve path '" <> rel <> "': " <> T.pack (show ex)))
              Right canon
                | not (isPathUnderRoot (workspaceRoot ws) canon) ->
                    Left (SandboxErr ("path escapes the workspace root: " <> rel))
                | otherwise -> Right canon

-- | @O_NOFOLLOW@ rejects a symlink with @ELOOP@ on Linux and macOS, and with
-- @EMLINK@ on the BSDs.
isSymlinkOpenError :: IOException -> Bool
isSymlinkOpenError ex = case ioe_errno ex of
  Nothing -> False
  Just n -> Errno n == eLOOP || Errno n == eMLINK

-- | Reaching a leaf symlink here means one was swapped in after
-- 'resolveWriteTarget' checked; treat it as an escape attempt.
mapWriteError :: Text -> IOException -> RuntimeError
mapWriteError rel ex
  | isSymlinkOpenError ex =
      SandboxErr ("refusing to write through symlink: " <> rel)
  | otherwise = HostErr ("write failed for '" <> rel <> "': " <> T.pack (show ex))

mapCopyError :: Text -> IOException -> RuntimeError
mapCopyError rel ex
  | isSymlinkOpenError ex =
      SandboxErr ("refusing to write through symlink: " <> rel)
  | otherwise = HostErr ("copy failed for '" <> rel <> "': " <> T.pack (show ex))

noFollowWriteFlags :: OpenFileFlags
noFollowWriteFlags =
  defaultFileFlags
    { trunc = True,
      creat = Just 0o666,
      nofollow = True,
      cloexec = True
    }

-- | Create or truncate @path@ without following a leaf symlink (@O_NOFOLLOW@).
writeBytesNoFollow :: FilePath -> BS.ByteString -> IO ()
writeBytesNoFollow path content = do
  fd <- openFd path WriteOnly noFollowWriteFlags
  -- The Handle owns the Fd once fdToHandle succeeds; only close the raw Fd
  -- if the conversion itself fails.
  handle <- fdToHandle fd `onException` closeFd fd
  ( do
      hSetBinaryMode handle True
      BS.hPut handle content
    )
    `finally` hClose handle

copyChunkSize :: Int
copyChunkSize = 128 * 1024

-- | Copy @src@ onto @dst@ atomically, preserving the source's access mode.
--
-- Contents go to a fresh @O_EXCL@ temporary next to @dst@ and are renamed into
-- place. @rename@ never follows a symlink at the destination, so this cannot be
-- redirected outside the workspace; a failure part-way leaves @dst@ untouched
-- rather than truncated. Set-user-ID / set-group-ID / sticky bits are dropped
-- deliberately — the sandbox has no business propagating them.
copyFileAtomic :: FilePath -> FilePath -> IO ()
copyFileAtomic src dst = do
  srcMode <- fileMode <$> getFileStatus src
  bracketOnError
    (openBinaryTempFile (takeDirectory dst) ".hwfl-copy.tmp")
    (\(tmp, h) -> hClose h `finally` ignoringIOErrors (removeFile tmp))
    ( \(tmp, hout) -> do
        withBinaryFile src ReadMode (`copyChunks` hout)
        hClose hout
        setFileMode tmp (srcMode .&. accessModeMask)
        renamePath tmp dst
    )
  where
    copyChunks hin hout = do
      chunk <- BS.hGetSome hin copyChunkSize
      if BS.null chunk
        then pure ()
        else BS.hPut hout chunk >> copyChunks hin hout

accessModeMask :: FileMode
accessModeMask = 0o777

ignoringIOErrors :: IO () -> IO ()
ignoringIOErrors act = do
  _ <- try act :: IO (Either IOException ())
  pure ()

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
-- A leaf symlink is followed only when it resolves inside the workspace; the
-- resolved destination is opened with @O_NOFOLLOW@.
writeTextFile :: Workspace -> Text -> Text -> IO (Either RuntimeError ())
writeTextFile ws rel content = do
  target <- resolveWriteTarget ws rel
  case target of
    Left e -> pure (Left e)
    Right path -> do
      result <- try (writeBytesNoFollow path (encodeUtf8 content)) :: IO (Either IOException ())
      pure $ case result of
        Left ex -> Left (mapWriteError rel ex)
        Right () -> Right ()

-- | Find workspace-relative files matching a simple glob.
-- Supported: @**/*.ext@ (recursive) and @*.ext@ (workspace root only).
-- Skips hidden paths and respects root @.gitignore@ / @.ignore@ (or a
-- built-in baseline when neither is present). See 'Hwfl.Runtime.Ignore'.
findFiles :: Workspace -> Text -> IO (Either RuntimeError [Text])
findFiles ws glob = case parseGlob glob of
  Left e -> pure (Left e)
  Right pat -> do
    ign <- loadIgnoreSet (workspaceRoot ws)
    paths <-
      walkFiles
        ws
        ign
        (\_ -> case pat of
            GlobRecursiveExt _ -> True
            GlobRootExt _ -> False
        )
        (\name -> pure (matchPat pat name))
    pure (map T.pack <$> paths)

data GlobPat
  = GlobRecursiveExt String
  | GlobRootExt String

parseGlob :: Text -> Either RuntimeError GlobPat
parseGlob g = case T.stripPrefix "**/*" g of
  Just ext | not (T.null ext) && T.head ext == '.' -> Right (GlobRecursiveExt (T.unpack ext))
  _ -> case T.stripPrefix "*" g of
    Just ext | not (T.null ext) && T.head ext == '.' -> Right (GlobRootExt (T.unpack ext))
    _ -> Left (HostErr ("fs.find: unsupported glob (use **/*.md or *.md): " <> g))

-- | Enumerate files below the workspace without following directory symlinks.
-- Each directory is canonicalised and checked before listing; the visited set
-- makes an alias cycle harmless even if a future traversal mechanism admits
-- one. Symlinked files remain leaves so their contents still go through the
-- normal per-file containment check in 'grepOne'.
walkFiles :: Workspace -> IgnoreSet -> (FilePath -> Bool) -> (FilePath -> IO Bool) -> IO (Either RuntimeError [FilePath])
walkFiles ws ign descend includeLeaf = go Set.empty ""
  where
    root = workspaceRoot ws

    go seen relDir = do
      let absDir = if null relDir then root else root </> relDir
      canonE <- try (canonicalizePath absDir) :: IO (Either IOException FilePath)
      case canonE of
        Left ex -> pure (Left (HostErr ("workspace walk failed: " <> T.pack (show ex))))
        Right canon
          | not (isPathUnderRoot root canon) ->
              pure (Left (SandboxErr ("workspace walk escapes root: " <> T.pack relDir)))
          | Set.member canon seen -> pure (Right [])
          | otherwise -> do
              namesE <- try (listDirectory canon) :: IO (Either IOException [FilePath])
              case namesE of
                Left ex -> pure (Left (HostErr ("workspace walk failed: " <> T.pack (show ex))))
                Right names -> foldM (visit (Set.insert canon seen) relDir) (Right []) names

    visit _ _ (Left e) _ = pure (Left e)
    visit seen relDir (Right acc) name = do
      let rel = if null relDir then name else relDir </> name
          absPath = root </> rel
      linkE <- try (pathIsSymbolicLink absPath) :: IO (Either IOException Bool)
      case linkE of
        Left ex -> pure (Left (HostErr ("workspace walk failed: " <> T.pack (show ex))))
        Right True -> do
          isFileE <- try (doesFileExist absPath) :: IO (Either IOException Bool)
          case isFileE of
            Left ex -> pure (Left (HostErr ("workspace walk failed: " <> T.pack (show ex))))
            Right isFile
              | isFile -> addLeaf acc rel name
              | otherwise -> pure (Right acc)
        Right False -> do
          isDirE <- try (doesDirectoryExist absPath) :: IO (Either IOException Bool)
          case isDirE of
            Left ex -> pure (Left (HostErr ("workspace walk failed: " <> T.pack (show ex))))
            Right True
              | isIgnored ign rel True -> pure (Right acc)
              | not (descend rel) -> pure (Right acc)
              | otherwise -> do
                  children <- go seen rel
                  pure ((acc <>) <$> children)
            Right False -> addLeaf acc rel name

    addLeaf acc rel name
      | isIgnored ign rel False = pure (Right acc)
      | otherwise = do
          include <- includeLeaf name
          pure (Right (if include then acc <> [rel] else acc))

-- | Extension globs are ASCII case-insensitive so @**\/*.md@ matches
-- @Foo.MD@ on case-preserving hosts (L-22).
matchPat :: GlobPat -> FilePath -> Bool
matchPat pat name = case pat of
  GlobRecursiveExt ext -> eqExt (takeExtension name) ext
  GlobRootExt ext -> eqExt (takeExtension name) ext
  where
    eqExt a b = map toLower a == map toLower b

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
--
-- A leaf symlink is unlinked rather than followed, so @fs.remove@ on a link to
-- a directory removes the link and leaves the target's contents alone.
removePath :: Workspace -> Text -> IO (Either RuntimeError ())
removePath ws rel = case resolvePath ws rel of
  Left e -> pure (Left e)
  Right path -> do
    isLink <- leafIsSymlink path
    if isLink
      then removeLeafSymlink ws rel path
      else do
        resolved <- resolveContainedPath ws rel
        case resolved of
          Left e -> pure (Left e)
          Right canon ->
            if canon == workspaceRoot ws
              then pure (Left (SandboxErr ("cannot remove workspace root: " <> rel)))
              else do
                isFile <- doesFileExist canon
                isDir <- doesDirectoryExist canon
                if not isFile && not isDir
                  then pure (Left (HostErr ("path not found: '" <> rel <> "'")))
                  else do
                    result <-
                      try
                        ( if isDir
                            then removeDirectoryRecursive canon
                            else removeFile canon
                        ) ::
                        IO (Either IOException ())
                    pure $ case result of
                      Left ex ->
                        Left (HostErr ("remove failed for '" <> rel <> "': " <> T.pack (show ex)))
                      Right () -> Right ()

removeLeafSymlink :: Workspace -> Text -> FilePath -> IO (Either RuntimeError ())
removeLeafSymlink ws rel path = do
  linkPath <- containedLinkPath ws rel path
  case linkPath of
    Left e -> pure (Left e)
    Right target -> do
      result <- try (removeFile target) :: IO (Either IOException ())
      pure $ case result of
        Left ex ->
          Left (HostErr ("remove failed for '" <> rel <> "': " <> T.pack (show ex)))
        Right () -> Right ()

-- | Create a directory (and parents) inside the sandbox.
mkdirPath :: Workspace -> Text -> IO (Either RuntimeError ())
mkdirPath ws rel = case resolveRelSegments rel of
  Left e -> pure (Left e)
  Right segs -> fmap (fmap (const ())) (ensureDirUnderRoot ws rel segs)

-- | Whether a workspace path exists. Missing ⇒ @False@.
--
-- A leaf symlink is an existing directory entry whenever its own parent is
-- inside the sandbox, even if it dangles or points out of the workspace —
-- 'statPath' reports it as @"symlink"@ and operations that follow the link
-- still fail hard on escape. Reporting it as absent would let @fs.copy@ and
-- @fs.move@ clobber a directory entry they were asked not to touch.
pathExists :: Workspace -> Text -> IO (Either RuntimeError Bool)
pathExists ws rel = case resolvePath ws rel of
  Left e -> pure (Left e)
  Right path -> do
    isLink <- leafIsSymlink path
    if isLink
      then fmap (True <$) (containedLinkPath ws rel path)
      else do
        exists <- doesPathExist path
        if not exists
          then pure (Right False)
          else do
            contained <- resolveContainedPath ws rel
            pure $ case contained of
              Left e -> Left e
              Right _ -> Right True

-- | Stat a workspace path. @kind@ is @"file"@ / @"dir"@ / @"symlink"@, or
-- @""@ when missing; @size@ is bytes for files and @0@ otherwise.
statPath :: Workspace -> Text -> IO (Either RuntimeError (Bool, Text, Integer))
statPath ws rel = case resolvePath ws rel of
  Left e -> pure (Left e)
  Right path -> do
    isLink <- leafIsSymlink path
    if isLink
      then fmap ((True, "symlink", 0) <$) (containedLinkPath ws rel path)
      else do
        ex <- pathExists ws rel
        case ex of
          Left e -> pure (Left e)
          Right False -> pure (Right (False, "", 0))
          Right True -> do
            resolved <- resolveContainedPath ws rel
            case resolved of
              Left e -> pure (Left e)
              Right canon -> do
                isDir <- doesDirectoryExist canon
                if isDir
                  then pure (Right (True, "dir", 0))
                  else do
                    sizeResult <- try (getFileSize canon) :: IO (Either IOException Integer)
                    pure $ case sizeResult of
                      Left ex' ->
                        Left (HostErr ("stat failed for '" <> rel <> "': " <> T.pack (show ex')))
                      Right n -> Right (True, "file", n)

-- | Copy a file or directory tree (@src@ → @dst@) within the sandbox.
-- When @overwrite@ is false, @dst@ must not exist. @exclude@ is a list of
-- path prefixes relative to the copied tree root (e.g. @.hwfl/runs@).
copyPath :: Workspace -> Text -> Text -> Bool -> [Text] -> IO (Either RuntimeError ())
copyPath ws srcRel dstRel overwrite exclude = do
  srcResolved <- resolveContainedPath ws srcRel
  case srcResolved of
    Left e -> pure (Left e)
    Right srcPath ->
      if srcPath == workspaceRoot ws
        then pure (Left (SandboxErr ("cannot copy workspace root: " <> srcRel)))
        else case (resolvePath ws srcRel, resolvePath ws dstRel) of
          (Left e, _) -> pure (Left e)
          (_, Left e) -> pure (Left e)
          (Right srcLex, Right dstLex) -> do
            srcIsDir <- doesDirectoryExist srcPath
            let nested =
                  srcIsDir
                    && ( dstLex == srcLex
                           || isPathUnderRoot srcLex dstLex
                       )
            if nested
              then
                pure
                  ( Left
                      ( HostErr
                          ( "cannot copy '"
                              <> srcRel
                              <> "' into itself or a descendant"
                          )
                      )
                  )
              else do
                dstExists <- pathExists ws dstRel
                case dstExists of
                  Left e -> pure (Left e)
                  Right True
                    | not overwrite ->
                        pure (Left (HostErr ("destination already exists: '" <> dstRel <> "'")))
                    | otherwise -> do
                        dstStat <- statPath ws dstRel
                        case dstStat of
                          Left e -> pure (Left e)
                          -- A file-onto-file overwrite is replaced atomically by
                          -- the copy itself, so the destination survives a failure
                          -- part-way through. Directories and symlinks have to go
                          -- first: rename cannot replace them in place.
                          Right (_, "file", _)
                            | not srcIsDir -> copyInto ws srcRel srcPath dstRel exclude
                          Right _ -> do
                            rm <- removePath ws dstRel
                            case rm of
                              Left e -> pure (Left e)
                              Right () -> copyInto ws srcRel srcPath dstRel exclude
                  Right False -> copyInto ws srcRel srcPath dstRel exclude

copyInto :: Workspace -> Text -> FilePath -> Text -> [Text] -> IO (Either RuntimeError ())
copyInto ws srcRel srcPath dstRel exclude = do
  isDir <- doesDirectoryExist srcPath
  isFile <- doesFileExist srcPath
  if isDir
    then copyTree ws srcPath dstRel "" exclude
    else
      if isFile
        then copyOneFile ws srcPath dstRel
        else pure (Left (HostErr ("path not found: '" <> srcRel <> "'")))

copyOneFile :: Workspace -> FilePath -> Text -> IO (Either RuntimeError ())
copyOneFile ws srcAbs dstRel = do
  target <- resolveWriteTarget ws dstRel
  case target of
    Left e -> pure (Left e)
    Right dstPath -> do
      result <- try (copyFileAtomic srcAbs dstPath) :: IO (Either IOException ())
      pure $ case result of
        Left ex -> Left (mapCopyError dstRel ex)
        Right () -> Right ()

copyTree :: Workspace -> FilePath -> Text -> Text -> [Text] -> IO (Either RuntimeError ())
copyTree ws srcRoot dstRel relInTree exclude
  | isExcluded exclude relInTree = pure (Right ())
  | otherwise = do
      mk <- mkdirPath ws dstRel
      case mk of
        Left e -> pure (Left e)
        Right () -> do
          namesResult <- try (listDirectory srcRoot) :: IO (Either IOException [FilePath])
          case namesResult of
            Left ex ->
              pure (Left (HostErr ("copy walk failed: " <> T.pack (show ex))))
            Right names -> go (sort names)
  where
    go [] = pure (Right ())
    go (name : rest) = do
      let childRel =
            if T.null relInTree
              then T.pack name
              else relInTree <> "/" <> T.pack name
          childSrc = srcRoot </> name
          childDst = dstRel <> "/" <> T.pack name
      if isExcluded exclude childRel
        then go rest
        else do
          srcCanon <- try (canonicalizePath childSrc) :: IO (Either IOException FilePath)
          case srcCanon of
            Left ex ->
              pure (Left (HostErr ("cannot resolve copy source: " <> T.pack (show ex))))
            Right c
              | not (isPathUnderRoot (workspaceRoot ws) c) ->
                  pure (Left (SandboxErr "path escapes the workspace root during copy"))
              | otherwise -> do
                  isDir <- doesDirectoryExist childSrc
                  step <-
                    if isDir
                      then copyTree ws childSrc childDst childRel exclude
                      else copyOneFile ws childSrc childDst
                  case step of
                    Left e -> pure (Left e)
                    Right () -> go rest

isExcluded :: [Text] -> Text -> Bool
isExcluded patterns rel =
  let norm = T.replace "\\" "/" (T.dropWhile (== '/') rel)
      pats = filter (not . T.null) (map (T.replace "\\" "/" . T.dropWhile (== '/')) patterns)
   in any (\p -> norm == p || (p <> "/") `T.isPrefixOf` norm) pats

-- | Rename / relocate a file or directory within the sandbox.
-- Fails if @dst@ already exists. Cannot move the workspace root.
movePath :: Workspace -> Text -> Text -> IO (Either RuntimeError ())
movePath ws srcRel dstRel = do
  srcResolved <- resolveContainedPath ws srcRel
  case srcResolved of
    Left e -> pure (Left e)
    Right srcPath
      | srcPath == workspaceRoot ws ->
          pure (Left (SandboxErr ("cannot move workspace root: " <> srcRel)))
      | otherwise -> case (resolvePath ws srcRel, resolveRelSegments dstRel) of
          (Left e, _) -> pure (Left e)
          (_, Left e) -> pure (Left e)
          (_, Right []) ->
            pure (Left (SandboxErr ("cannot move onto the workspace root: " <> dstRel)))
          (Right srcLex, Right dstSegs) -> do
            dstEx <- pathExists ws dstRel
            case dstEx of
              Left e -> pure (Left e)
              Right True ->
                pure (Left (HostErr ("destination already exists: '" <> dstRel <> "'")))
              Right False -> moveInto ws srcRel dstRel srcPath srcLex dstSegs

-- | Rename step of 'movePath': @src@ is contained and @dst@ is known absent.
-- Because the destination has no directory entry and @rename@ never follows a
-- symlink at the leaf, the raw name under the vetted parent is safe to use.
moveInto ::
  Workspace ->
  Text ->
  Text ->
  FilePath ->
  FilePath ->
  [FilePath] ->
  IO (Either RuntimeError ())
moveInto ws srcRel dstRel srcPath srcLex dstSegs = do
  parentCanon <- ensureDirUnderRoot ws dstRel (init dstSegs)
  case parentCanon of
    Left e -> pure (Left e)
    Right pCanon -> do
      let dstLex = workspaceRoot ws </> joinPath dstSegs
          target = pCanon </> last dstSegs
      srcIsDir <- doesDirectoryExist srcPath
      if srcIsDir && (dstLex == srcLex || isPathUnderRoot srcLex dstLex)
        then
          pure
            (Left (HostErr ("cannot move '" <> srcRel <> "' into itself or a descendant")))
        else do
          result <- try (renamePath srcPath target) :: IO (Either IOException ())
          case result of
            Right () -> pure (Right ())
            Left ex -> do
              -- Cross-device rename: copy then remove.
              copied <- copyPath ws srcRel dstRel False []
              case copied of
                Left _ ->
                  pure
                    ( Left
                        (HostErr ("move failed for '" <> srcRel <> "': " <> T.pack (show ex)))
                    )
                Right () -> removePath ws srcRel

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

-- | Apply ordered unique search/replace hunks atomically.
-- Each @old@ must occur exactly once in the buffer after previous hunks;
-- on any failure the file is left unchanged. Returns @(ok, applied, error)@.
patchFile ::
  Workspace ->
  Text ->
  [(Text, Text)] ->
  IO (Either RuntimeError (Bool, Int, Text))
patchFile ws rel hunks
  | null hunks = pure (Left (HostErr "fs.patch 'hunks' must be a non-empty list"))
  | otherwise = do
      r <- readTextFile ws rel
      case r of
        Left e -> pure (Left e)
        Right text0 -> case applyPatchHunks hunks text0 of
          Left err -> pure (Right (False, 0, err))
          Right text' -> do
            w <- writeTextFile ws rel text'
            pure $ case w of
              Left e -> Left e
              Right () -> Right (True, length hunks, "")

-- | Pure sequential unique replace. Hunk indices in errors are 1-based.
applyPatchHunks :: [(Text, Text)] -> Text -> Either Text Text
applyPatchHunks hunks text0 = go (1 :: Int) text0 hunks
  where
    go _ text [] = Right text
    go i _ ((old, _) : _)
      | T.null old =
          Left ("hunk " <> T.pack (show i) <> ": old must be a non-empty string")
    go i text ((old, new) : rest) =
      let n = T.count old text
       in if n == 0
            then Left ("hunk " <> T.pack (show i) <> ": old text not found")
            else
              if n > 1
                then
                  Left
                    ( "hunk "
                        <> T.pack (show i)
                        <> ": old text matches "
                        <> T.pack (show n)
                        <> " times (must be unique)"
                    )
                else go (i + 1) (T.replace old new text) rest

maxGrepFileBytes :: Integer
maxGrepFileBytes = 1024 * 1024

binarySniffBytes :: Int
binarySniffBytes = 8000

-- | Regex-search workspace files. @glob@ empty ⇒ all text files under the
-- workspace root; otherwise the same globs as 'findFiles' (@**\/*.ext@ / @*.ext@).
-- Uses the same ignore policy as 'findFiles'. Hits are @(file, 1-based line, line text)@.
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
  let root = workspaceRoot ws
  ign <- loadIgnoreSet root
  paths <- walkFiles ws ign (const True) (\_ -> pure True)
  pure (map T.pack . sort <$> paths)
