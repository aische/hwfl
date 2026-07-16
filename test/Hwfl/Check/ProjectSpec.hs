module Hwfl.Check.ProjectSpec (spec) where

import Data.Set qualified as Set
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..), QName (..))
import Hwfl.Check.Project (ProjectCheckError (PceImportCycle), buildImportGraph, checkProject)
import Hwfl.Project (LoadedProject (..), loadProject)
import System.FilePath ((</>))
import Test.Hspec

fixtureRoot :: FilePath -> FilePath
fixtureRoot name = "test/fixtures" </> name

spec :: Spec
spec = describe "project check (M9)" $ do
  it "accepts multi-module project with imports" $ do
    result <- checkProject (fixtureRoot "check-project")
    result `shouldSatisfy` isRight

  it "rejects cyclic imports" $ do
    result <- checkProject (fixtureRoot "check-project-cycle")
    case result of
      Left (PceImportCycle _) -> pure ()
      other -> expectationFailure ("expected import cycle, got: " <> show other)

  it "buildImportGraph collects reachable modules" $ do
    lp <- loadProjectOrFail (fixtureRoot "check-project")
    case buildImportGraph lp (QName [Ident "workflows", Ident "main"]) of
      Right reachable ->
        Set.fromList [QName [Ident "workflows", Ident "main"], QName [Ident "lib", Ident "list"]]
          `shouldBe` reachable
      Left err -> expectationFailure (show err)

loadProjectOrFail :: FilePath -> IO LoadedProject
loadProjectOrFail path = do
  result <- loadProject path
  case result of
    Left err -> fail (T.unpack err)
    Right lp -> pure lp

isRight :: Either a b -> Bool
isRight = \case
  Right _ -> True
  Left _ -> False
