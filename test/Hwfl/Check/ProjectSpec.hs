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

  -- L-8: first import of a is already-sorted lib/base; the cycle is a↔b.
  -- The old first-edge walker reported a non-cycle including lib/base.
  it "reports the real cycle when the first import is already sorted (L-8)" $ do
    result <- checkProject (fixtureRoot "check-project-cycle-misleading")
    case result of
      Left (PceImportCycle qs) -> do
        qs `shouldContain` ["workflows/a"]
        qs `shouldContain` ["workflows/b"]
        qs `shouldSatisfy` (notElem "lib/base")
        case qs of
          (x : _) -> last qs `shouldBe` x
          [] -> expectationFailure "empty cycle path"
      other -> expectationFailure ("expected import cycle, got: " <> show other)

  it "reports a self-import as a cycle" $ do
    result <- checkProject (fixtureRoot "check-project-cycle-self")
    case result of
      Left (PceImportCycle qs) -> qs `shouldBe` ["workflows/a", "workflows/a"]
      other -> expectationFailure ("expected self-import cycle, got: " <> show other)

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
