module Hwfl.Json.ValidateSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Ast.Type (TypeExpr (..))
import Hwfl.Check.Env (emptyTypeEnv)
import Hwfl.Check.Schema (typeToSchema)
import Hwfl.Json.Validate (validateAgainstSchema)
import Hwfl.Runtime.Agent (validateSubmit)
import Test.Hspec

outSchema :: Value
outSchema =
  case typeToSchema
    emptyTypeEnv
    ( TRecord
        [ (Ident "summary", TName (TypeName "String")),
          (Ident "score", TName (TypeName "Int"))
        ]
    ) of
    Right s -> s
    Left err -> error (show err)

listSchema :: Value
listSchema =
  case typeToSchema emptyTypeEnv (TList (TName (TypeName "String"))) of
    Right s -> s
    Left err -> error (show err)

optionSchema :: Value
optionSchema =
  case typeToSchema emptyTypeEnv (TOption (TName (TypeName "Int"))) of
    Right s -> s
    Left err -> error (show err)

spec :: Spec
spec = describe "JSON schema validation" $ do
  describe "validateAgainstSchema" $ do
    it "accepts a matching record" $
      validateAgainstSchema
        outSchema
        (object ["summary" .= ("ok" :: Text), "score" .= (3 :: Int)])
        `shouldBe` Right ()

    it "rejects missing required fields" $
      validateAgainstSchema outSchema (object ["summary" .= ("ok" :: Text)])
        `shouldSatisfy` isLeftContaining "missing required field score"

    it "rejects wrong field types" $
      validateAgainstSchema
        outSchema
        (object ["summary" .= ("ok" :: Text), "score" .= ("seven" :: Text)])
        `shouldSatisfy` isLeftContaining "expected integer"

    it "rejects additional properties" $
      validateAgainstSchema
        outSchema
        ( object
            [ "summary" .= ("ok" :: Text),
              "score" .= (1 :: Int),
              "extra" .= True
            ]
        )
        `shouldSatisfy` isLeftContaining "unexpected field"

    it "validates arrays" $ do
      validateAgainstSchema listSchema (Array mempty) `shouldBe` Right ()
      validateAgainstSchema
        listSchema
        (Array (V.fromList [String "a", Number 1]))
        `shouldSatisfy` isLeftContaining "expected string"

    it "validates Option as anyOf" $ do
      validateAgainstSchema optionSchema (Number 1) `shouldBe` Right ()
      validateAgainstSchema optionSchema Null `shouldBe` Right ()
      validateAgainstSchema optionSchema (String "x")
        `shouldSatisfy` isLeftContaining "anyOf"

    it "accepts any value for empty Json schema" $
      validateAgainstSchema (Object mempty) (String "anything") `shouldBe` Right ()

  describe "validateSubmit" $ do
    it "decodes a valid submit payload" $
      case validateSubmit
        outSchema
        (object ["summary" .= ("done" :: Text), "score" .= (9 :: Int)]) of
        Right _ -> pure ()
        Left err -> expectationFailure (show err)

    it "rejects a mistyped submit payload" $
      validateSubmit
        outSchema
        (object ["summary" .= ("done" :: Text), "score" .= True])
        `shouldSatisfy` isLeftContaining "expected integer"

isLeftContaining :: Text -> Either Text a -> Bool
isLeftContaining needle = \case
  Left msg -> needle `T.isInfixOf` msg
  Right _ -> False
