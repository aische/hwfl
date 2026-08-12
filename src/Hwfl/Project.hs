-- | Project layout: @project.json@, module discovery, qname resolution.
module Hwfl.Project
  ( ProjectConfig (..),
    ExecPolicy (..),
    EffectsPolicy (..),
    McpPolicy (..),
    McpServerConfig (..),
    McpCwd (..),
    ProjectIndex (..),
    LoadedProject (..),
    loadProjectConfig,
    loadProject,
    loadProjectWithStdlib,
    discoverModules,
    qnameFromRelPath,
    modulePathForQname,
    moduleRelPath,
    projectHashForModules,
    isProjectDir,
    findProjectRoot,
    validateMcpPolicy,
    isBareBasename,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (filterM)
import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types ((.!=), typeMismatch)
import Data.Foldable (for_)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Hwfl.Ast.Module (Frontmatter (..), LoadedModule (..))
import Hwfl.Ast.Name (Ident (..), QName (..), qnameFromParts, qnameToText)
import Hwfl.Ast.Type (Effect (..), parseEffectName)
import Hwfl.Parse.Load (loadModule)
import Hwfl.SafeIO (ReadError (..), listDirectorySafe, readBytesFile, renderReadError)
import Hwfl.SkillCatalog (SkillPolicy (..), defaultSkillPolicy)
import Hwfl.Source (Diagnostic (..), renderDiagnostics)
import Hwfl.Stdlib (isHwflQName, loadStdlibAt, loadStdlibModules)
import System.Directory
  ( doesDirectoryExist,
    doesFileExist,
  )
import System.FilePath
  ( dropExtension,
    isExtensionOf,
    makeRelative,
    normalise,
    splitDirectories,
    takeDirectory,
    (</>),
  )

data EffectsPolicy = EffectsPolicy
  { epDefault :: [Effect],
    epDeny :: [Effect]
  }
  deriving stock (Eq, Show)

data ExecPolicy = ExecPolicy
  { execAllow :: [Text],
    execEnv :: [Text],
    execTimeoutMs :: Maybe Int,
    execMaxOutputBytes :: Maybe Int,
    -- | When 'True' (default), @exec.run@ pauses for human confirm before spawn.
    execConfirm :: Bool
  }
  deriving stock (Eq, Show)

-- | @mcp.servers.<id>.cwd@ (spec §13 §3): the child's working directory.
-- @McpCwdAbsolute@ is only honoured when @mcp.allow_absolute_cwd@ is true
-- (fail closed otherwise — see H-8 / spec §13 §3). MCP children remain
-- outside the @fs.*@ sandbox; command allowlist + cwd policy are the boundary.
data McpCwd
  = McpCwdWorkspace
  | McpCwdProject
  | McpCwdAbsolute Text
  deriving stock (Eq, Show)

data McpServerConfig = McpServerConfig
  { mcpCommand :: Text,
    mcpArgs :: [Text],
    -- | Allowlisted env var names forwarded to the child (mirrors 'execEnv').
    mcpEnv :: [Text],
    mcpCwd :: McpCwd,
    -- | Per-request wall-clock timeout; falls back to a runtime default.
    mcpTimeoutMs :: Maybe Int
  }
  deriving stock (Eq, Show)

-- | MCP spawn policy (spec §13 §3). @mpAllow@ is the command basename
-- allowlist (same trust model as @exec.allow@). Absolute @cwd@ requires
-- @mpAllowAbsoluteCwd@.
data McpPolicy = McpPolicy
  { mpAllow :: [Text],
    mpAllowAbsoluteCwd :: Bool,
    mpServers :: Map Text McpServerConfig
  }
  deriving stock (Eq, Show)

instance Semigroup McpPolicy where
  a <> b =
    McpPolicy
      { mpAllow = a.mpAllow <> b.mpAllow,
        mpAllowAbsoluteCwd = a.mpAllowAbsoluteCwd || b.mpAllowAbsoluteCwd,
        mpServers = Map.union a.mpServers b.mpServers
      }

instance Monoid McpPolicy where
  mempty =
    McpPolicy
      { mpAllow = [],
        mpAllowAbsoluteCwd = False,
        mpServers = Map.empty
      }

instance FromJSON McpCwd where
  parseJSON = \case
    Aeson.String "workspace" -> pure McpCwdWorkspace
    Aeson.String "project" -> pure McpCwdProject
    Aeson.String other -> pure (McpCwdAbsolute other)
    other -> typeMismatch "mcp server cwd" other

instance FromJSON McpServerConfig where
  parseJSON = withObject "mcp server" $ \o -> do
    command <- o .: "command"
    args <- o .:? "args" .!= ([] :: [Text])
    env <- o .:? "env" .!= ([] :: [Text])
    cwd <- o .:? "cwd" .!= McpCwdWorkspace
    timeout <- o .:? "timeout_ms"
    for_ timeout validateMcpTimeoutMs
    pure
      McpServerConfig
        { mcpCommand = command,
          mcpArgs = args,
          mcpEnv = env,
          mcpCwd = cwd,
          mcpTimeoutMs = timeout
        }
    where
      validateMcpTimeoutMs n
        | n <= 0 = fail "mcp server timeout_ms must be positive"
        | n > maxBound `div` 1000 = fail "mcp server timeout_ms is too large"
        | otherwise = pure ()

instance FromJSON McpPolicy where
  parseJSON = withObject "mcp" $ \o -> do
    allow <- o .:? "allow" .!= ([] :: [Text])
    allowAbsCwd <- o .:? "allow_absolute_cwd" .!= False
    servers <- o .:? "servers" .!= Map.empty
    let pol =
          McpPolicy
            { mpAllow = allow,
              mpAllowAbsoluteCwd = allowAbsCwd,
              mpServers = servers
            }
    case validateMcpPolicy pol of
      Left err -> fail (T.unpack err)
      Right () -> pure pol

-- | Fail-closed MCP spawn policy (basename-only command ∈ @mcp.allow@;
-- absolute @cwd@ only when @mcp.allow_absolute_cwd@). Used at
-- @project.json@ load and again at spawn.
validateMcpPolicy :: McpPolicy -> Either Text ()
validateMcpPolicy pol = do
  for_ pol.mpAllow $ \prog ->
    if isBareBasename prog
      then Right ()
      else
        Left
          ( "mcp.allow entry must be a bare basename, not a path: '"
              <> prog
              <> "'"
          )
  for_ (Map.toList pol.mpServers) $ \(sid, cfg) -> do
    let cmd = cfg.mcpCommand
    if not (isBareBasename cmd)
      then
        Left
          ( "mcp.servers."
              <> sid
              <> ".command must be a bare basename, not a path: '"
              <> cmd
              <> "'"
          )
      else
        if cmd `notElem` pol.mpAllow
          then
            Left
              ( "mcp.servers."
                  <> sid
                  <> ".command '"
                  <> cmd
                  <> "' is not allowed by project.json mcp.allow"
              )
          else case cfg.mcpCwd of
            McpCwdAbsolute _
              | not pol.mpAllowAbsoluteCwd ->
                  Left
                    ( "mcp.servers."
                        <> sid
                        <> ".cwd is absolute, but mcp.allow_absolute_cwd is false"
                    )
            _ -> Right ()

-- | Same rule as @exec.run@: no path separators (POSIX @/@ or Windows @\\@).
isBareBasename :: Text -> Bool
isBareBasename t = not (T.null t) && not (T.any (\c -> c == '/' || c == '\\') t)

data ProjectConfig = ProjectConfig
  { pcRoot :: FilePath,
    pcName :: Text,
    pcVersion :: Text,
    pcEntrypoint :: QName,
    pcEnv :: [Text],
    pcEffects :: EffectsPolicy,
    pcExec :: Maybe ExecPolicy,
    pcMcp :: Maybe McpPolicy,
    pcSkills :: SkillPolicy
  }
  deriving stock (Eq, Show)

data ProjectIndex = ProjectIndex
  { piRoot :: FilePath,
    piModules :: Map QName FilePath
  }
  deriving stock (Eq, Show)

data LoadedProject = LoadedProject
  { lpConfig :: ProjectConfig,
    lpIndex :: ProjectIndex,
    lpModules :: Map QName LoadedModule
  }
  deriving stock (Show)

instance FromJSON EffectsPolicy where
  parseJSON = withObject "effects" $ \o -> do
    def <- o .:? "default" .!= ([] :: [Text])
    deny <- o .:? "deny" .!= ([] :: [Text])
    defE <- parseEffectList def
    denyE <- parseEffectList deny
    pure EffectsPolicy {epDefault = defE, epDeny = denyE}
    where
      parseEffectList = traverse
          ( \s -> case parseEffectName s of
              Just e -> pure e
              Nothing -> fail ("unknown effect: " <> T.unpack s)
          )

instance FromJSON ExecPolicy where
  parseJSON =
    withObject "exec" $ \o -> do
      allow <- o .:? "allow" .!= ([] :: [Text])
      env <- o .:? "env" .!= ([] :: [Text])
      timeout <- o .:? "timeout_ms"
      maxOut <- o .:? "max_output_bytes"
      confirm <- o .:? "confirm" .!= True
      for_ timeout validateTimeoutMs
      for_ maxOut validateMaxOutputBytes
      pure
        ExecPolicy
          { execAllow = allow,
            execEnv = env,
            execTimeoutMs = timeout,
            execMaxOutputBytes = maxOut,
            execConfirm = confirm
          }
    where
      -- Must stay positive and small enough that @timeout_ms * 1000@ fits in 'Int'.
      validateTimeoutMs n
        | n <= 0 = fail "exec.timeout_ms must be positive"
        | n > maxBound `div` 1000 = fail "exec.timeout_ms is too large"
        | otherwise = pure ()
      validateMaxOutputBytes n
        | n < 0 = fail "exec.max_output_bytes must be non-negative"
        | otherwise = pure ()

instance FromJSON ProjectConfig where
  parseJSON = withObject "project.json" $ \o -> do
    name <- o .: "name"
    version <- o .: "version"
    entry <- o .: "entrypoint"
    env <- o .:? "env" .!= ([] :: [Text])
    effects <- o .:? "effects" .!= EffectsPolicy [] []
    exec <- o .:? "exec"
    mcp <- o .:? "mcp"
    skills <- o .:? "skills" .!= defaultSkillPolicy
    pure
      ProjectConfig
        { pcRoot = "",
          pcName = name,
          pcVersion = version,
          pcEntrypoint = qnameFromText entry,
          pcEnv = env,
          pcEffects = effects,
          pcExec = exec,
          pcMcp = mcp,
          pcSkills = skills
        }

loadProjectConfig :: FilePath -> IO (Either Text ProjectConfig)
loadProjectConfig root = do
  let path = root </> "project.json"
  bsE <- readBytesFile path
  pure $ case bsE of
    Left (ReadNotFound _) -> Left "project.json not found"
    Left err -> Left ("cannot read project.json: " <> renderReadError err)
    Right bs -> case Aeson.eitherDecodeStrict bs of
      Left err -> Left ("invalid project.json: " <> T.pack err)
      Right cfg -> Right cfg {pcRoot = normalise root}

isProjectDir :: FilePath -> IO Bool
isProjectDir path = safeDoesFileExist (path </> "project.json")

-- | Walk parents of @start@ looking for @project.json@ (inclusive).
findProjectRoot :: FilePath -> IO (Maybe FilePath)
findProjectRoot start = go (normalise start) (32 :: Int)
  where
    go _ 0 = pure Nothing
    go path n = do
      -- If @start@ is a file, begin at its directory.
      isFile <- safeDoesFileExist path
      let dir = if isFile then takeDirectory path else path
      isProj <- isProjectDir dir
      if isProj
        then pure (Just dir)
        else
          let parent = takeDirectory dir
           in if parent == dir
                then pure Nothing
                else go parent (n - 1)

qnameFromText :: Text -> QName
qnameFromText t = qnameFromParts (T.splitOn "/" t)

qnameFromRelPath :: FilePath -> Maybe QName
qnameFromRelPath rel =
  let rel' = normalise rel
   in if null rel' || ".." `elem` splitDirectories rel'
        then Nothing
        else
          Just
            ( qnameFromParts
                ( map T.pack (splitDirectories (dropExtension rel'))
                )
            )

moduleRelPath :: QName -> FilePath
moduleRelPath q =
  T.unpack (T.intercalate "/" (map unIdent (qnParts q))) <> ".md"
  where
    unIdent (Ident t) = t

modulePathForQname :: FilePath -> QName -> FilePath
modulePathForQname root q = root </> moduleRelPath q

discoverModules :: FilePath -> IO (Either Text ProjectIndex)
discoverModules root = do
  pathsE <- findMarkdownModules root
  pure $ do
    paths <- pathsE
    let pairs =
          [ (q, p)
            | p <- paths,
              Just q <- [qnameFromRelPath (makeRelative root p)]
          ]
        dupes =
          [ q
            | q <- map fst pairs,
              length (filter ((== q) . fst) pairs) > 1
          ]
    if not (null dupes)
      then Left ("duplicate module qname: " <> qnameToText (head dupes))
      else Right ProjectIndex {piRoot = normalise root, piModules = Map.fromList pairs}
  where
    -- Spec layout: only these trees contain modules (skip README.md etc.).
    moduleRoots = ["workflows", "lib", "tools", "types", "skills"]
    findMarkdownModules dir = do
      existing <-
        filterM
          (\name -> safeDoesDirectoryExist (dir </> name))
          moduleRoots
      results <- mapM (\name -> go (dir </> name)) existing
      pure (concat <$> sequence results)
      where
        go d = do
          entriesE <- listDirectorySafe d
          case entriesE of
            Left err -> pure (Left (renderReadError err))
            Right entries -> do
              let visible = filter (not . isHiddenDir) entries
              results <- mapM (classify d) visible
              pure (concat <$> sequence results)
        isHiddenDir x = "." `T.isPrefixOf` T.pack x && x /= "."
        classify d name = do
          let path = d </> name
          isDir <- safeDoesDirectoryExist path
          if isDir
            then
              if name == ".hwfl"
                then pure (Right [])
                else go path
            else
              if isExtensionOf "md" path
                then pure (Right [normalise path])
                else pure (Right [])

safeDoesFileExist :: FilePath -> IO Bool
safeDoesFileExist path = do
  result <- try (doesFileExist path) :: IO (Either IOException Bool)
  pure (either (const False) id result)

safeDoesDirectoryExist :: FilePath -> IO Bool
safeDoesDirectoryExist path = do
  result <- try (doesDirectoryExist path) :: IO (Either IOException Bool)
  pure (either (const False) id result)

loadProject :: FilePath -> IO (Either Text LoadedProject)
loadProject root = loadProjectWithStdlib root Nothing

-- | Like 'loadProject', but @Just packRoot@ forces that stdlib pack
-- (bypassing @HWFL_STDLIB@ / defaults). @Nothing@ uses normal resolution.
loadProjectWithStdlib :: FilePath -> Maybe FilePath -> IO (Either Text LoadedProject)
loadProjectWithStdlib root mPack = do
  cfgE <- loadProjectConfig root
  case cfgE of
    Left err -> pure (Left err)
    Right cfg -> do
      idxE <- discoverModules root
      case idxE of
        Left err -> pure (Left err)
        Right idx -> do
          case Map.lookup cfg.pcEntrypoint idx.piModules of
            Nothing ->
              pure
                ( Left
                    ( "entrypoint not found: "
                        <> qnameToText cfg.pcEntrypoint
                    )
                )
            _ -> do
              stdlibE <- case mPack of
                Just pack -> loadStdlibAt pack
                Nothing -> loadStdlibModules
              case stdlibE of
                Left err -> pure (Left err)
                Right stdlib -> loadAll idx cfg stdlib
  where
    loadAll idx cfg stdlib = do
      let reserved =
            [ q
              | q <- Map.keys idx.piModules,
                isHwflQName q
            ]
      if not (null reserved)
        then
          pure
            ( Left
                ( "project modules must not claim hwfl/ qnames: "
                    <> qnameToText (head reserved)
                )
            )
        else do
          results <- traverse (loadModule . snd) (Map.toList idx.piModules)
          case partitionResults results (Map.elems idx.piModules) of
            Left err -> pure (Left err)
            Right loadedList -> do
              let projectMods = Map.fromList (zip (Map.keys idx.piModules) loadedList)
                  loaded = Map.union projectMods stdlib
                  idx' =
                    idx
                      { piModules =
                          Map.union
                            idx.piModules
                            (Map.map lmPath stdlib)
                      }
              pure
                ( Right
                    LoadedProject
                      { lpConfig = cfg,
                        lpIndex = idx',
                        lpModules = loaded
                      }
                )

partitionResults :: [Either [Diagnostic] LoadedModule] -> [FilePath] -> Either Text [LoadedModule]
partitionResults [] [] = Right []
partitionResults (Right m : rest) (_ : paths) =
  (m :) <$> partitionResults rest paths
partitionResults (Left diags : _) (path : _) =
  Left (T.pack path <> ":\n" <> renderDiagnostics diags)
partitionResults _ _ = Left "internal: module load count mismatch"

-- | Stable structural fingerprint for a set of loaded modules.
--
-- Only frontmatter and the code-fence body AST contribute to the hash;
-- prose bodies (@lmProseBody@), raw sections (@lmSections@), and schema
-- docs (@lmSchemaDocs@) are excluded so that comment or prose edits do not
-- brick an otherwise-valid resume.  SHA-256 is used as the digest to avoid
-- the wrap/collision risk of the previous DJB2 @Int@ fold.
projectHashForModules :: Map QName LoadedModule -> Text
projectHashForModules mods =
  let structural m =
        qnameToText (fmName (lmFrontmatter m))
          <> "\n"
          <> T.pack (show (lmFrontmatter m))
          <> "\n"
          <> T.pack (show (lmBody m))
      payload :: ByteString
      payload =
        TE.encodeUtf8 $
          T.intercalate "\n---\n" $
            [structural m | m <- Map.elems mods]
      digest = SHA256.hash payload
   in T.take 16 (bsToHex digest)

-- | Encode a 'ByteString' as lowercase hex text.
bsToHex :: ByteString -> Text
bsToHex bs = T.pack [hexNibble (fromIntegral b `shiftR` n .&. 0xF) | b <- BS.unpack bs, n <- [4, 0]]
  where
    hexNibble :: Int -> Char
    hexNibble i
      | i < 10 = toEnum (fromEnum '0' + i)
      | otherwise = toEnum (fromEnum 'a' + i - 10)
