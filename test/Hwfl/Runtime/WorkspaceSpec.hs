module Hwfl.Runtime.WorkspaceSpec (spec) where

import Data.Bits ((.&.))
import Data.Either (isLeft, isRight)
import Hwfl.Runtime.Error (RuntimeError (..))
import Hwfl.Runtime.Workspace
import System.Directory
  ( createDirectoryIfMissing,
    createDirectoryLink,
    createFileLink,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (fileMode, getFileStatus, setFileMode)
import System.Posix.User (getRealUserID)
import Test.Hspec

-- | Two temp trees: a workspace and an unrelated directory outside it.
withWorkspaceAndOutside :: (FilePath -> FilePath -> IO a) -> IO a
withWorkspaceAndOutside act =
  withSystemTempDirectory "hwfl-ws" $ \dir ->
    withSystemTempDirectory "hwfl-outside" (act dir)

expectSandboxErr :: Show a => Either RuntimeError a -> Expectation
expectSandboxErr r = case r of
  Left (SandboxErr _) -> pure ()
  other -> expectationFailure ("expected SandboxErr, got: " <> show other)

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

    it "rejects write through a live symlink that escapes the workspace" $
      withWorkspaceAndOutside $ \dir outside -> do
        ws <- newWorkspace dir
        let target = outside </> "live.txt"
        writeFile target "original"
        createFileLink target (dir </> "escape")
        w <- writeTextFile ws "escape" "nope"
        expectSandboxErr w
        readFile target `shouldReturn` "original"

    it "rejects write through a dangling symlink that escapes the workspace" $
      withWorkspaceAndOutside $ \dir outside -> do
        ws <- newWorkspace dir
        let target = outside </> "pwned.txt"
        createFileLink target (dir </> "dangling")
        w <- writeTextFile ws "dangling" "escaped"
        expectSandboxErr w
        doesFileExist target `shouldReturn` False

    it "allows write through an in-workspace symlink alias" $
      withSystemTempDirectory "hwfl-ws" $ \dir -> do
        ws <- newWorkspace dir
        _ <- writeTextFile ws "real.txt" "before"
        createFileLink (dir </> "real.txt") (dir </> "alias.txt")
        w <- writeTextFile ws "alias.txt" "after"
        w `shouldBe` Right ()
        r <- readTextFile ws "real.txt"
        r `shouldBe` Right "after"
        -- The alias is followed, not replaced.
        st <- statPath ws "alias.txt"
        st `shouldBe` Right (True, "symlink", 0)

    it "rejects copy onto a dangling symlink without overwrite" $
      withWorkspaceAndOutside $ \dir outside -> do
        ws <- newWorkspace dir
        _ <- writeTextFile ws "src.txt" "payload"
        let target = outside </> "pwned.txt"
        createFileLink target (dir </> "dangling")
        cp <- copyPath ws "src.txt" "dangling" False []
        cp `shouldSatisfy` isLeft
        doesFileExist target `shouldReturn` False
        -- Destination is still the dangling link (not followed).
        ex <- pathExists ws "dangling"
        ex `shouldBe` Right True

    it "overwrite copy replaces a dangling symlink inside the workspace" $
      withWorkspaceAndOutside $ \dir outside -> do
        ws <- newWorkspace dir
        _ <- writeTextFile ws "src.txt" "payload"
        let target = outside </> "pwned.txt"
        createFileLink target (dir </> "dangling")
        cp <- copyPath ws "src.txt" "dangling" True []
        cp `shouldBe` Right ()
        r <- readTextFile ws "dangling"
        r `shouldBe` Right "payload"
        doesFileExist target `shouldReturn` False

    it "removes a dangling symlink" $
      withSystemTempDirectory "hwfl-ws" $ \dir -> do
        ws <- newWorkspace dir
        createDirectoryIfMissing True (dir </> "sub")
        createFileLink "/nonexistent-hwfl-target" (dir </> "sub" </> "link")
        rm <- removePath ws "sub/link"
        rm `shouldBe` Right ()
        ex <- pathExists ws "sub/link"
        ex `shouldBe` Right False

    it "unlinks a directory symlink instead of deleting the target's contents" $
      withWorkspaceAndOutside $ \dir outside -> do
        ws <- newWorkspace dir
        writeFile (outside </> "keep.txt") "keep"
        createDirectoryLink outside (dir </> "dirlink")
        rm <- removePath ws "dirlink"
        rm `shouldBe` Right ()
        doesDirectoryExist outside `shouldReturn` True
        listDirectory outside `shouldReturn` ["keep.txt"]

    it "never creates directories outside the root through a directory symlink" $
      withWorkspaceAndOutside $ \dir outside -> do
        ws <- newWorkspace dir
        createDirectoryLink outside (dir </> "dirlink")
        mk <- mkdirPath ws "dirlink/escaped"
        expectSandboxErr mk
        w <- writeTextFile ws "dirlink/deep/file.txt" "nope"
        expectSandboxErr w
        listDirectory outside `shouldReturn` []

    it "reports a leaf symlink as an existing 'symlink' entry" $
      withWorkspaceAndOutside $ \dir outside -> do
        ws <- newWorkspace dir
        createFileLink (outside </> "gone.txt") (dir </> "dangling")
        ex <- pathExists ws "dangling"
        ex `shouldBe` Right True
        st <- statPath ws "dangling"
        st `shouldBe` Right (True, "symlink", 0)

    it "allows read through an in-workspace symlink" $
      withSystemTempDirectory "hwfl-ws" $ \dir -> do
        ws <- newWorkspace dir
        _ <- writeTextFile ws "real.txt" "secret"
        createFileLink (dir </> "real.txt") (dir </> "link.txt")
        r <- readTextFile ws "link.txt"
        r `shouldBe` Right "secret"

  describe "copy fidelity" $ do
    it "preserves the executable bit" $
      withSystemTempDirectory "hwfl-ws" $ \dir -> do
        ws <- newWorkspace dir
        _ <- writeTextFile ws "run.sh" "#!/bin/sh\n"
        setFileMode (dir </> "run.sh") 0o755
        cp <- copyPath ws "run.sh" "copy.sh" False []
        cp `shouldBe` Right ()
        mode <- fileMode <$> getFileStatus (dir </> "copy.sh")
        (mode .&. 0o777) `shouldBe` 0o755

    it "leaves the destination untouched when the source cannot be read" $
      withSystemTempDirectory "hwfl-ws" $ \dir -> do
        uid <- getRealUserID
        if uid == 0
          then pendingWith "running as root: mode 0o000 does not deny access"
          else do
            ws <- newWorkspace dir
            _ <- writeTextFile ws "dst.txt" "original"
            _ <- writeTextFile ws "src.txt" "payload"
            setFileMode (dir </> "src.txt") 0o000
            cp <- copyPath ws "src.txt" "dst.txt" True []
            cp `shouldSatisfy` isLeft
            r <- readTextFile ws "dst.txt"
            r `shouldBe` Right "original"

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
