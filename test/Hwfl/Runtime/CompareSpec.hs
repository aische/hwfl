module Hwfl.Runtime.CompareSpec (spec) where

import Data.Either (isRight)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Hwfl.Ast.Name (Ident (..), QName (..))
import Hwfl.Check.Module (checkLoadedModule)
import Hwfl.Check.Project (checkProject)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Obs.Observer (noopObserver)
import Hwfl.Project (LoadedProject (..), loadProject)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    emptySkillRuntime,
    runLoadedModule,
  )
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

projectRoot :: FilePath
projectRoot = "examples/compare"

modulePath :: FilePath
modulePath = projectRoot </> "workflows" </> "main.md"

spec :: Spec
spec = describe "compare lab (local genetic prototype)" $ do
  it "checks the compare project" $ do
    result <- checkProject projectRoot
    result `shouldSatisfy` isRight

  it "checks the lean and rich genomes" $ do
    lean <- checkProject (projectRoot </> "genomes" </> "lean")
    rich <- checkProject (projectRoot </> "genomes" </> "rich")
    lean `shouldSatisfy` isRight
    rich `shouldSatisfy` isRight

  it "materializes candidates, prefers lean (fewer llm spans) under mock" $
    withSystemTempDirectory "hwfl-compare" $ \tmp -> do
      seedWorkspace tmp
      lp <- loadProjectOrFail projectRoot
      case Map.lookup (qname "workflows/main") lp.lpModules of
        Nothing -> expectationFailure "missing entry module"
        Just m -> do
          checkLoadedModule m `shouldSatisfy` isRight
          let (catalog, skillMods) = emptySkillRuntime
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = tmp,
                  roProvider = mockProvider,
                  roInputs = [],
                  roRunId = Just "compare-parent",
                  roEntry = modulePath,
                  roMode = StepRun,
                  roProjectHash = Nothing,
                  roExec = Nothing,
                  roObserver = noopObserver,
                  roCost = False,
                  roModelCatalog = "model-catalog.json",
                  roSkillCatalog = catalog,
                  roSkillModules = skillMods, roEntryModules = mempty
                }
              m
          case outcome of
            OutcomeCompleted (VRecord fs) _store _n -> do
              lookup (Ident "winner") fs `shouldBe` Just (VString "lean")
              lookup (Ident "trial_count") fs `shouldBe` Just (VInt 2)
              lookup (Ident "results_path") fs
                `shouldBe` Just (VString "results.json")
              doesFileExist (tmp </> "results.json") `shouldReturn` True
              doesFileExist (tmp </> "candidates" </> "lean" </> "project.json")
                `shouldReturn` True
              doesFileExist
                (tmp </> "candidates" </> "rich" </> "workflows" </> "main.md")
                `shouldReturn` True
              doesFileExist (tmp </> "trials" </> "lean" </> "article.txt")
                `shouldReturn` True
            other -> expectationFailure ("expected completed run, got: " <> show other)

qname :: Text -> QName
qname = QName . map Ident . T.splitOn "/"

seedWorkspace :: FilePath -> IO ()
seedWorkspace ws = do
  copyFileRel
    (projectRoot </> "fixture" </> "article.txt")
    (ws </> "fixture" </> "article.txt")
  copyFileRel
    (projectRoot </> "genomes" </> "lean" </> "project.json")
    (ws </> "genomes" </> "lean" </> "project.json")
  copyFileRel
    (projectRoot </> "genomes" </> "lean" </> "workflows" </> "main.md")
    (ws </> "genomes" </> "lean" </> "workflows" </> "main.md")
  copyFileRel
    (projectRoot </> "genomes" </> "rich" </> "project.json")
    (ws </> "genomes" </> "rich" </> "project.json")
  copyFileRel
    (projectRoot </> "genomes" </> "rich" </> "workflows" </> "main.md")
    (ws </> "genomes" </> "rich" </> "workflows" </> "main.md")

copyFileRel :: FilePath -> FilePath -> IO ()
copyFileRel src dst = do
  createDirectoryIfMissing True (takeDirectory dst)
  TIO.writeFile dst =<< TIO.readFile src

loadProjectOrFail :: FilePath -> IO LoadedProject
loadProjectOrFail path = do
  result <- loadProject path
  case result of
    Left err -> fail (T.unpack err)
    Right lp -> pure lp
