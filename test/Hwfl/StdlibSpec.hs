module Hwfl.StdlibSpec (spec) where

import Control.Exception (finally)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..), QName (..))
import Hwfl.Check.Project (checkProject)
import Hwfl.Stdlib
  ( isHwflQName,
    loadStdlibAt,
    loadStdlibModules,
    resolveStdlibRoot,
    stdlibQnameForFile,
  )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "stdlib pack" $ do
  it "maps flat pack files to hwfl/* qnames" $ do
    stdlibQnameForFile "list.md"
      `shouldBe` Just (QName [Ident "hwfl", Ident "list"])
    isHwflQName (QName [Ident "hwfl", Ident "list"]) `shouldBe` True
    isHwflQName (QName [Ident "lib", Ident "list"]) `shouldBe` False

  it "loads the default repo pack" $ do
    result <- loadStdlibModules
    case result of
      Left err -> expectationFailure (T.unpack err)
      Right mods -> do
        Map.member (QName [Ident "hwfl", Ident "list"]) mods `shouldBe` True
        Map.member (QName [Ident "hwfl", Ident "option"]) mods `shouldBe` True
        Map.member (QName [Ident "hwfl", Ident "result"]) mods `shouldBe` True
        Map.member (QName [Ident "hwfl", Ident "string"]) mods `shouldBe` True

  it "loadStdlibAt rejects non-hwfl frontmatter names" $ do
    withSystemTempDirectory "hwfl-stdlib-bad" $ \dir -> do
      writeFile
        (dir </> "list.md")
        "---\nname: lib/list\neffects: []\n---\n\n```hwfl\nfun id(x: Int): Int = x\n```\n"
      result <- loadStdlibAt dir
      result `shouldSatisfy` isLeft

  it "resolveStdlibRoot fails closed when HWFL_STDLIB is bogus" $ do
    withEnv "HWFL_STDLIB" "/no/such/hwfl-stdlib-pack" $ do
      result <- resolveStdlibRoot
      case result of
        Left err -> err `shouldSatisfy` T.isInfixOf "HWFL_STDLIB"
        Right _ -> expectationFailure "expected Left"

  it "checks examples/stdlib-list against the shipped pack" $ do
    result <- checkProject "examples/stdlib-list"
    result `shouldSatisfy` isRight

withEnv :: String -> String -> IO a -> IO a
withEnv key val action = do
  before <- lookupEnv key
  setEnv key val
  action `finally` case before of
    Nothing -> unsetEnv key
    Just old -> setEnv key old

isRight :: Either a b -> Bool
isRight = \case
  Right _ -> True
  Left _ -> False

isLeft :: Either a b -> Bool
isLeft = not . isRight
