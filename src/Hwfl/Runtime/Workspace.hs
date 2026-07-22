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

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Hwfl.Runtime.Error (RuntimeError (..))
import Hwfl.Runtime.Ignore (IgnoreSet, isIgnored, loadIgnoreSet)
import System.Directory
  ( canonicalizePath,
    copyFile,
    createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    doesPathExist,
    getFileSize,
    listDirectory,
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
-- Skips hidden paths and respects root @.gitignore@ / @.ignore@ (or a
-- built-in baseline when neither is present). See 'Hwfl.Runtime.Ignore'.
findFiles :: Workspace -> Text -> IO (Either RuntimeError [Text])
findFiles ws glob = case parseGlob glob of
  Left e -> pure (Left e)
  Right pat -> do
    let root = workspaceRoot ws
    ign <- loadIgnoreSet root
    paths <- try (walk ign root "" pat) :: IO (Either IOException [FilePath])
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

walk :: IgnoreSet -> FilePath -> FilePath -> GlobPat -> IO [FilePath]
walk ign absRoot relDir pat = do
  let absDir = if null relDir then absRoot else absRoot </> relDir
  names <- listDirectory absDir
  concat <$> traverse (one ign absRoot relDir pat) names

one :: IgnoreSet -> FilePath -> FilePath -> GlobPat -> FilePath -> IO [FilePath]
one ign absRoot relDir pat name = do
  let rel = if null relDir then name else relDir </> name
      absPath = absRoot </> rel
  isDir <- doesDirectoryExist absPath
  if isDir
    then
      if isIgnored ign rel True
        then pure []
        else case pat of
          GlobRecursiveExt _ -> walk ign absRoot rel pat
          GlobRootExt _ -> pure []
    else
      pure
        ( [ rel
            | not (isIgnored ign rel False),
              matchPat pat name
          ]
        )

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

-- | Create a directory (and parents) inside the sandbox.
mkdirPath :: Workspace -> Text -> IO (Either RuntimeError ())
mkdirPath ws rel = case resolvePath ws rel of
  Left e -> pure (Left e)
  Right path -> do
    parentCanon <-
      try
        ( do
            createDirectoryIfMissing True path
            canonicalizePath path
        ) ::
        IO (Either IOException FilePath)
    pure $ case parentCanon of
      Left ex ->
        Left (HostErr ("mkdir failed for '" <> rel <> "': " <> T.pack (show ex)))
      Right canon
        | not (isPathUnderRoot (workspaceRoot ws) canon) ->
            Left (SandboxErr ("path escapes the workspace root: " <> rel))
        | otherwise -> Right ()

-- | Whether a workspace path exists (file or directory). Missing ⇒ @False@;
-- symlink escape is still a hard sandbox failure.
pathExists :: Workspace -> Text -> IO (Either RuntimeError Bool)
pathExists ws rel = case resolvePath ws rel of
  Left e -> pure (Left e)
  Right path -> do
    exists <- doesPathExist path
    if not exists
      then pure (Right False)
      else do
        contained <- resolveContainedPath ws rel
        pure $ case contained of
          Left e -> Left e
          Right _ -> Right True

-- | Stat a workspace path. @kind@ is @"file"@ / @"dir"@ / @""@ when missing;
-- @size@ is bytes for files, @0@ for directories and missing paths.
statPath :: Workspace -> Text -> IO (Either RuntimeError (Bool, Text, Integer))
statPath ws rel = do
  ex <- pathExists ws rel
  case ex of
    Left e -> pure (Left e)
    Right False -> pure (Right (False, "", 0))
    Right True -> do
      resolved <- resolveContainedPath ws rel
      case resolved of
        Left e -> pure (Left e)
        Right path -> do
          isDir <- doesDirectoryExist path
          if isDir
            then pure (Right (True, "dir", 0))
            else do
              sizeResult <- try (getFileSize path) :: IO (Either IOException Integer)
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
copyOneFile ws srcAbs dstRel = case resolvePath ws dstRel of
  Left e -> pure (Left e)
  Right dstPath -> do
    let parent = takeDirectory dstPath
    parentCanon <-
      try
        ( do
            createDirectoryIfMissing True parent
            canonicalizePath parent
        ) ::
        IO (Either IOException FilePath)
    case parentCanon of
      Left ex ->
        pure (Left (HostErr ("cannot prepare copy destination '" <> dstRel <> "': " <> T.pack (show ex))))
      Right pCanon
        | not (isPathUnderRoot (workspaceRoot ws) pCanon) ->
            pure (Left (SandboxErr ("path escapes the workspace root: " <> dstRel)))
        | otherwise -> do
            let target = pCanon </> takeFileName dstPath
            result <- try (copyFile srcAbs target) :: IO (Either IOException ())
            pure $ case result of
              Left ex ->
                Left (HostErr ("copy failed for '" <> dstRel <> "': " <> T.pack (show ex)))
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
    Right srcPath ->
      if srcPath == workspaceRoot ws
        then pure (Left (SandboxErr ("cannot move workspace root: " <> srcRel)))
        else do
          dstEx <- pathExists ws dstRel
          case dstEx of
            Left e -> pure (Left e)
            Right True ->
              pure (Left (HostErr ("destination already exists: '" <> dstRel <> "'")))
            Right False -> case (resolvePath ws srcRel, resolvePath ws dstRel) of
              (Left e, _) -> pure (Left e)
              (_, Left e) -> pure (Left e)
              (Right srcLex, Right dstPath) -> do
                let parent = takeDirectory dstPath
                parentCanon <-
                  try
                    ( do
                        createDirectoryIfMissing True parent
                        canonicalizePath parent
                    ) ::
                    IO (Either IOException FilePath)
                case parentCanon of
                  Left ex ->
                    pure
                      ( Left
                          ( HostErr
                              ( "cannot prepare move destination '"
                                  <> dstRel
                                  <> "': "
                                  <> T.pack (show ex)
                              )
                          )
                      )
                  Right pCanon
                    | not (isPathUnderRoot (workspaceRoot ws) pCanon) ->
                        pure (Left (SandboxErr ("path escapes the workspace root: " <> dstRel)))
                    | otherwise -> do
                        let target = pCanon </> takeFileName dstPath
                        srcIsDir <- doesDirectoryExist srcPath
                        let nested =
                              srcIsDir
                                && ( dstPath == srcLex
                                       || isPathUnderRoot srcLex dstPath
                                   )
                        if nested
                          then
                            pure
                              ( Left
                                  ( HostErr
                                      ( "cannot move '"
                                          <> srcRel
                                          <> "' into itself or a descendant"
                                      )
                                  )
                              )
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
                                          ( HostErr
                                              ( "move failed for '"
                                                  <> srcRel
                                                  <> "': "
                                                  <> T.pack (show ex)
                                              )
                                          )
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
  paths <- try (walkAll ign root "") :: IO (Either IOException [FilePath])
  pure $ case paths of
    Left ex -> Left (HostErr ("fs.grep walk failed: " <> T.pack (show ex)))
    Right ps -> Right (map T.pack (sort ps))

walkAll :: IgnoreSet -> FilePath -> FilePath -> IO [FilePath]
walkAll ign absRoot relDir = do
  let absDir = if null relDir then absRoot else absRoot </> relDir
  names <- listDirectory absDir
  concat <$> traverse (oneFile ign absRoot relDir) names

oneFile :: IgnoreSet -> FilePath -> FilePath -> FilePath -> IO [FilePath]
oneFile ign absRoot relDir name = do
  let rel = if null relDir then name else relDir </> name
      absPath = absRoot </> rel
  isDir <- doesDirectoryExist absPath
  if isDir
    then
      if isIgnored ign rel True
        then pure []
        else walkAll ign absRoot rel
    else do
      isFile <- doesFileExist absPath
      pure ([rel | isFile && not (isIgnored ign rel False)])
