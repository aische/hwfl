module Pml.Check.SchemaSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Text (Text)
import Data.Vector qualified as V
import Pml.Ast.Expr (Expr (..))
import Pml.Ast.Name (Ident (..), TypeName (..))
import Pml.Ast.Type (TypeExpr (..))
import Pml.Check.Env (emptyTypeEnv)
import Pml.Check.Infer (infer)
import Pml.Check.Prelude (preludeTypeEnv)
import Pml.Check.Schema (schemaType, typeToSchema)
import Pml.Parse.Expr (parseExprText)
import Pml.Parse.Type (parseTypeText)
import Test.Hspec
import Text.Megaparsec (errorBundlePretty)

parseT :: Text -> Either String TypeExpr
parseT t = either (Left . errorBundlePretty) Right (parseTypeText "t" t)

parseE :: Text -> Either String Expr
parseE t = either (Left . errorBundlePretty) Right (parseExprText "e" t)

spec :: Spec
spec = describe "schema(T)" $ do
  it "parses schema(Out) as ESchema" $
    parseE "schema({ summary: String })"
      `shouldBe` Right
        ( ESchema
            ( TRecord
                [(Ident "summary", TName (TypeName "String"))]
            )
        )

  it "infers Schema type" $
    case parseE "schema(List<Int>)" of
      Left err -> expectationFailure err
      Right e -> infer preludeTypeEnv e `shouldBe` Right schemaType

  it "reflects records and lists" $ do
    case parseT "{ summary: String, score: Int }" of
      Left err -> expectationFailure err
      Right ty ->
        typeToSchema emptyTypeEnv ty
          `shouldBe` Right
            ( object
                [ "type" .= String "object",
                  "properties"
                    .= object
                      [ "summary" .= object ["type" .= String "string"],
                        "score" .= object ["type" .= String "integer"]
                      ],
                  "required" .= Array (V.fromList [String "summary", String "score"]),
                  "additionalProperties" .= False
                ]
            )
    case parseT "List<String>" of
      Left err -> expectationFailure err
      Right listTy ->
        typeToSchema emptyTypeEnv listTy
          `shouldBe` Right
            ( object
                [ "type" .= String "array",
                  "items" .= object ["type" .= String "string"]
                ]
            )

  it "rejects schema of functions" $
    case parseT "Int -> String" of
      Left err -> expectationFailure err
      Right ty ->
        typeToSchema emptyTypeEnv ty
          `shouldSatisfy` ( \case
                              Left _ -> True
                              Right _ -> False
                          )
