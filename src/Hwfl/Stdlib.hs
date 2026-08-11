-- | Shipped @hwfl/*@ stdlib pack: resolve root and load markdown modules.
--
-- Pack root (see docs/stdlib.md):
--
-- 1. @HWFL_STDLIB@ when set (must be an existing directory)
-- 2. Else Cabal data-files @stdlib/@ when present
-- 3. Else walk parents of the current working directory for @stdlib/@
--
-- Flat layout: @list.md@ → qname @hwfl/list@ (frontmatter @name@ must match).
module Hwfl.Stdlib
  ( isHwflQName,
    resolveStdlibRoot,
    discoverStdlib,
    loadStdlibModules,
    loadStdlibAt,
    stdlibQnameForFile,
  )
where

import Control.Exception (IOException, try)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Module (Frontmatter (..), LoadedModule (..))
import Hwfl.Ast.Name (Ident (..), QName (..), qnameFromParts, qnameToText)
import Hwfl.Parse.Load (loadModule)
import Hwfl.Source (renderDiagnostics)
import Paths_hwfl (getDataDir)
import System.Directory
  ( doesDirectoryExist,
    doesFileExist,
    getCurrentDirectory,
    listDirectory,
  )
import System.Environment (lookupEnv)
import System.FilePath
  ( dropExtension,
    isExtensionOf,
    takeDirectory,
    takeFileName,
    (</>),
  )

-- | Reserved prefix for the shipped stdlib pack.
isHwflQName :: QName -> Bool
isHwflQName (QName (Ident "hwfl" : _)) = True
isHwflQName _ = False

-- | Resolve the stdlib pack root, or @Nothing@ when no pack is available.
-- Fails when @HWFL_STDLIB@ is set but does not name an existing directory.
resolveStdlibRoot :: IO (Either Text (Maybe FilePath))
resolveStdlibRoot = do
  mEnv <- lookupEnv "HWFL_STDLIB"
  case mEnv of
    Just raw -> do
      let root = T.unpack (T.strip (T.pack raw))
      if null root
        then pure (Left "HWFL_STDLIB is empty")
        else do
          ok <- safeDoesDirectoryExist root
          if ok
            then pure (Right (Just root))
            else
              pure
                ( Left
                    ( "HWFL_STDLIB is not a directory: " <> T.pack root
                    )
                )
    Nothing -> Right <$> findDefaultStdlibRoot

findDefaultStdlibRoot :: IO (Maybe FilePath)
findDefaultStdlibRoot = do
  dataRoot <- try getDataDir :: IO (Either IOException FilePath)
  case dataRoot of
    Right dir -> do
      let cand = dir </> "stdlib"
      ok <- safeDoesDirectoryExist cand
      if ok then pure (Just cand) else walkFromCwd
    Left _ -> walkFromCwd
  where
    walkFromCwd = do
      cwd <- getCurrentDirectory
      walkUp cwd
    walkUp dir = do
      let cand = dir </> "stdlib"
      ok <- safeDoesDirectoryExist cand
      if ok
        then pure (Just cand)
        else
          let parent = takeDirectory dir
           in if parent == dir
                then pure Nothing
                else walkUp parent

-- | Map a pack-relative @*.md@ basename to @hwfl/<stem>@.
stdlibQnameForFile :: FilePath -> Maybe QName
stdlibQnameForFile path =
  let stem = dropExtension (takeFileName path)
   in if null stem || '/' `elem` stem || '\\' `elem` stem
        then Nothing
        else Just (qnameFromParts ["hwfl", T.pack stem])

-- | Discover @*.md@ files directly under the pack root (non-recursive).
discoverStdlib :: FilePath -> IO (Either Text (Map QName FilePath))
discoverStdlib root = do
  entriesE <- try (listDirectory root) :: IO (Either IOException [FilePath])
  case entriesE of
    Left err ->
      pure (Left ("cannot list stdlib pack: " <> T.pack (show err)))
    Right entries -> do
      let mdFiles =
            [ root </> name
              | name <- entries,
                isExtensionOf "md" name,
                not ("." `T.isPrefixOf` T.pack name)
            ]
      pairs <- traverse pairFor mdFiles
      let okPairs = mapMaybe id pairs
          qs = map fst okPairs
          dupes = [q | q <- qs, length (filter (== q) qs) > 1]
      pure $
        if not (null dupes)
          then Left ("duplicate stdlib qname: " <> qnameToText (head dupes))
          else Right (Map.fromList okPairs)
  where
    pairFor path = case stdlibQnameForFile path of
      Nothing -> pure Nothing
      Just q -> do
        isFile <- safeDoesFileExist path
        pure $ if isFile then Just (q, path) else Nothing

-- | Load every module in the resolved pack (empty map when no pack).
loadStdlibModules :: IO (Either Text (Map QName LoadedModule))
loadStdlibModules = do
  rootE <- resolveStdlibRoot
  case rootE of
    Left err -> pure (Left err)
    Right Nothing -> pure (Right Map.empty)
    Right (Just root) -> loadStdlibAt root

-- | Load the pack at an explicit root (for tests / drivers).
loadStdlibAt :: FilePath -> IO (Either Text (Map QName LoadedModule))
loadStdlibAt root = do
  idxE <- discoverStdlib root
  case idxE of
    Left err -> pure (Left err)
    Right idx -> do
      results <- traverse loadOne (Map.toList idx)
      pure (sequenceMap results)
  where
    loadOne (q, path) = do
      loadedE <- loadModule path
      case loadedE of
        Left diags ->
          pure (Left (T.pack path <> ":\n" <> renderDiagnostics diags))
        Right m ->
          let fmName = m.lmFrontmatter.fmName
           in pure $
                if not (isHwflQName fmName)
                  then
                    Left
                      ( T.pack path
                          <> ": stdlib frontmatter name must be under hwfl/, got "
                          <> qnameToText fmName
                      )
                  else
                    if fmName /= q
                      then
                        Left
                          ( T.pack path
                              <> ": frontmatter name "
                              <> qnameToText fmName
                              <> " does not match pack file qname "
                              <> qnameToText q
                          )
                      else Right (q, m)

sequenceMap :: [Either Text (QName, LoadedModule)] -> Either Text (Map QName LoadedModule)
sequenceMap = go Map.empty
  where
    go acc [] = Right acc
    go _ (Left err : _) = Left err
    go acc (Right (q, m) : rest) = go (Map.insert q m acc) rest

safeDoesFileExist :: FilePath -> IO Bool
safeDoesFileExist path = do
  result <- try (doesFileExist path) :: IO (Either IOException Bool)
  pure (either (const False) id result)

safeDoesDirectoryExist :: FilePath -> IO Bool
safeDoesDirectoryExist path = do
  result <- try (doesDirectoryExist path) :: IO (Either IOException Bool)
  pure (either (const False) id result)
