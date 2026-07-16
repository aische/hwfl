-- | Project layout: @project.json@, module discovery, qname resolution.
module Hwfl.Project
  ( ProjectConfig (..),
    ExecPolicy (..),
    EffectsPolicy (..),
    ProjectIndex (..),
    LoadedProject (..),
    loadProjectConfig,
    loadProject,
    discoverModules,
    qnameFromRelPath,
    modulePathForQname,
    moduleRelPath,
    projectHashForModules,
    isProjectDir,
  )
where

import Control.Monad (filterM)
import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types ((.!=))
import Data.ByteString qualified as BS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Module (LoadedModule (..))
import Hwfl.Ast.Name (Ident (..), QName (..), qnameFromParts, qnameToText)
import Hwfl.Ast.Type (Effect (..), parseEffectName)
import Hwfl.Parse.Load (loadModule)
import Hwfl.Source (Diagnostic (..), renderDiagnostics)
import System.Directory
  ( doesDirectoryExist,
    doesFileExist,
    listDirectory,
  )
import System.FilePath
  ( dropExtension,
    isExtensionOf,
    makeRelative,
    normalise,
    splitDirectories,
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
    execMaxOutputBytes :: Maybe Int
  }
  deriving stock (Eq, Show)

data ProjectConfig = ProjectConfig
  { pcRoot :: FilePath,
    pcName :: Text,
    pcVersion :: Text,
    pcEntrypoint :: QName,
    pcEnv :: [Text],
    pcEffects :: EffectsPolicy,
    pcExec :: Maybe ExecPolicy
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
      parseEffectList xs =
        traverse
          ( \s -> case parseEffectName s of
              Just e -> pure e
              Nothing -> fail ("unknown effect: " <> T.unpack s)
          )
          xs

instance FromJSON ExecPolicy where
  parseJSON = withObject "exec" $ \o -> do
    allow <- o .:? "allow" .!= ([] :: [Text])
    env <- o .:? "env" .!= ([] :: [Text])
    timeout <- o .:? "timeout_ms"
    maxOut <- o .:? "max_output_bytes"
    pure
      ExecPolicy
        { execAllow = allow,
          execEnv = env,
          execTimeoutMs = timeout,
          execMaxOutputBytes = maxOut
        }

instance FromJSON ProjectConfig where
  parseJSON = withObject "project.json" $ \o -> do
    name <- o .: "name"
    version <- o .: "version"
    entry <- o .: "entrypoint"
    env <- o .:? "env" .!= ([] :: [Text])
    effects <- o .:? "effects" .!= EffectsPolicy [] []
    exec <- o .:? "exec"
    pure
      ProjectConfig
        { pcRoot = "",
          pcName = name,
          pcVersion = version,
          pcEntrypoint = qnameFromText entry,
          pcEnv = env,
          pcEffects = effects,
          pcExec = exec
        }

loadProjectConfig :: FilePath -> IO (Either Text ProjectConfig)
loadProjectConfig root = do
  let path = root </> "project.json"
  exists <- doesFileExist path
  if not exists
    then pure (Left "project.json not found")
    else do
      bs <- BS.readFile path
      pure $ case Aeson.eitherDecodeStrict bs of
        Left err -> Left ("invalid project.json: " <> T.pack err)
        Right cfg -> Right cfg {pcRoot = normalise root}

isProjectDir :: FilePath -> IO Bool
isProjectDir path = doesFileExist (path </> "project.json")

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
  paths <- findMarkdownModules root
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
    then pure (Left ("duplicate module qname: " <> qnameToText (head dupes)))
    else pure (Right ProjectIndex {piRoot = normalise root, piModules = Map.fromList pairs})
  where
    -- Spec layout: only these trees contain modules (skip README.md etc.).
    moduleRoots = ["workflows", "lib", "tools", "types"]
    findMarkdownModules dir = do
      existing <-
        filterM
          (\name -> doesDirectoryExist (dir </> name))
          moduleRoots
      concat <$> mapM (\name -> go (dir </> name)) existing
      where
        go d = do
          entries <- listDirectory d
          let visible = filter (not . isHiddenDir) entries
          concat <$> mapM (classify d) visible
        isHiddenDir x = "." `T.isPrefixOf` T.pack x && x /= "."
        classify d name = do
          let path = d </> name
          isDir <- doesDirectoryExist path
          if isDir
            then
              if name == ".hwfl"
                then pure []
                else go path
            else
              if isExtensionOf "md" path
                then pure [normalise path]
                else pure []

loadProject :: FilePath -> IO (Either Text LoadedProject)
loadProject root = do
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
            _ -> loadAll idx cfg
  where
    loadAll idx cfg = do
      results <- traverse (loadModule . snd) (Map.toList idx.piModules)
      case partitionResults results (Map.elems idx.piModules) of
        Left err -> pure (Left err)
        Right loadedList -> do
          let loaded = Map.fromList (zip (Map.keys idx.piModules) loadedList)
          pure
            ( Right
                LoadedProject
                  { lpConfig = cfg,
                    lpIndex = idx,
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

projectHashForModules :: Map QName LoadedModule -> Text
projectHashForModules mods =
  let payload =
        T.intercalate
          "\n---\n"
          [ qnameToText q <> "\n" <> T.pack (show m)
            | q <- Map.keys mods,
              Just m <- [Map.lookup q mods]
          ]
   in T.pack (show (T.foldl' (\h c -> h * 33 + fromEnum c) (0 :: Int) payload))
