module Hwfl.Check.SchemaSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Vector qualified as V
import Hwfl.Ast.Expr (Expr (..))
import Hwfl.Ast.Module (SchemaDoc (..))
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Ast.Type (TypeExpr (..))
import Hwfl.Check.Env (TypeEnv (..), emptyTypeEnv)
import Hwfl.Check.Infer (infer)
import Hwfl.Check.Prelude (preludeTypeEnv)
import Hwfl.Check.Schema (schemaType, typeToSchema, typeToSchemaWithDocs)
import Hwfl.Parse.Expr (parseExprText)
import Hwfl.Parse.Type (parseTypeText)
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

  it "adds field descriptions from schema docs for named aliases" $ do
    let env =
          emptyTypeEnv
            { teAliases =
                Map.fromList
                  [ ( TypeName "Out",
                      TRecord
                        [ (Ident "summary", TName (TypeName "String")),
                          (Ident "score", TName (TypeName "Int"))
                        ]
                    )
                  ]
            }
        docs =
          [ SchemaDoc
              (TypeName "Out")
              [ (Ident "summary", "One line summary"),
                (Ident "score", "Confidence score")
              ]
          ]
    typeToSchemaWithDocs env docs (TName (TypeName "Out"))
      `shouldBe` Right
        ( object
            [ "type" .= String "object",
              "properties"
                .= object
                  [ "summary"
                      .= object
                        [ "type" .= String "string",
                          "description" .= String "One line summary"
                        ],
                    "score"
                      .= object
                        [ "type" .= String "integer",
                          "description" .= String "Confidence score"
                        ]
                  ],
              "required" .= Array (V.fromList [String "summary", String "score"]),
              "additionalProperties" .= False
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
