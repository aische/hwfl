module Hwfl.Parse.TypeSpec (spec) where

import Data.Text (Text)
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Ast.Type
import Hwfl.Parse.Type (parseTypeText)
import Test.Hspec
import Text.Megaparsec (errorBundlePretty)

parseT :: Text -> Either String TypeExpr
parseT t = either (Left . errorBundlePretty) Right (parseTypeText "t" t)

spec :: Spec
spec = describe "type parser" $ do
  it "parses type names" $
    parseT "String" `shouldBe` Right (TName (TypeName "String"))

  it "parses List and Option" $ do
    parseT "List<Int>" `shouldBe` Right (TList (TName (TypeName "Int")))
    parseT "Option<String>" `shouldBe` Right (TOption (TName (TypeName "String")))

  it "parses Result and Secret" $ do
    parseT "Result<String, Error>"
      `shouldBe` Right (TResult (TName (TypeName "String")) (TName (TypeName "Error")))
    parseT "Secret<String>" `shouldBe` Right (TSecret (TName (TypeName "String")))

  it "parses records" $
    parseT "{ summary: String, score: Int }"
      `shouldBe` Right
        ( TRecord
            [ (Ident "summary", TName (TypeName "String")),
              (Ident "score", TName (TypeName "Int"))
            ]
        )

  it "parses pure and effectful arrows" $ do
    parseT "Int -> String"
      `shouldBe` Right (TFun (TName (TypeName "Int")) (TName (TypeName "String")))
    parseT "FileRef -[Read, Net]-> String"
      `shouldBe` Right
        ( TEffFun
            (TName (TypeName "FileRef"))
            [EffRead, EffNet]
            (TName (TypeName "String"))
        )
