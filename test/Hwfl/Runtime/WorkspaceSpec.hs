module Hwfl.Runtime.WorkspaceSpec (spec) where

import Data.Either (isLeft, isRight)
import Hwfl.Runtime.Workspace
import System.Directory (createFileLink)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "Workspace sandbox" $ do
  it "resolves an in-workspace relative path" $
    withSystemTempDirectory "hwfl-ws" $ \dir -> do
      ws <- newWorkspace dir
      resolvePath ws "sub/file.txt" `shouldSatisfy` isRight

  it "rejects an absolute path" $
    withSystemTempDirectory "hwfl-ws" $ \dir -> do
      ws <- newWorkspace dir
      resolvePath ws "/etc/passwd" `shouldSatisfy` isLeft

  it "rejects a traversal that escapes the root" $
    withSystemTempDirectory "hwfl-ws" $ \dir -> do
      ws <- newWorkspace dir
      resolvePath ws "../outside.txt" `shouldSatisfy` isLeft
      resolvePath ws "a/../../outside.txt" `shouldSatisfy` isLeft

  it "allows internal .. that stays within the root" $
    withSystemTempDirectory "hwfl-ws" $ \dir -> do
      ws <- newWorkspace dir
      resolvePath ws "a/b/../c.txt" `shouldSatisfy` isRight

  describe "symlink containment" $ do
    it "rejects read through a symlink that escapes the workspace" $
      withSystemTempDirectory "hwfl-ws" $ \dir -> do
        ws <- newWorkspace dir
        createFileLink "/etc/passwd" (dir </> "escape")
        r <- readTextFile ws "escape"
        r `shouldSatisfy` isLeft

    it "rejects write through a symlink that escapes the workspace" $
      withSystemTempDirectory "hwfl-ws" $ \dir -> do
        ws <- newWorkspace dir
        createFileLink "/etc/passwd" (dir </> "escape")
        w <- writeTextFile ws "escape" "nope"
        w `shouldSatisfy` isLeft

    it "allows read through an in-workspace symlink" $
      withSystemTempDirectory "hwfl-ws" $ \dir -> do
        ws <- newWorkspace dir
        _ <- writeTextFile ws "real.txt" "secret"
        createFileLink (dir </> "real.txt") (dir </> "link.txt")
        r <- readTextFile ws "link.txt"
        r `shouldBe` Right "secret"

  it "round-trips write then read" $
    withSystemTempDirectory "hwfl-ws" $ \dir -> do
      ws <- newWorkspace dir
      w <- writeTextFile ws "out/hello.txt" "hi"
      w `shouldBe` Right ()
      r <- readTextFile ws "out/hello.txt"
      r `shouldBe` Right "hi"

  it "refuses to write outside the workspace" $
    withSystemTempDirectory "hwfl-ws" $ \dir -> do
      ws <- newWorkspace dir
      w <- writeTextFile ws "../escape.txt" "nope"
      w `shouldSatisfy` isLeft
