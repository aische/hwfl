module Hwfl.Json.EncodeSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Either (isLeft)
import Data.Scientific (scientific)
import Data.Vector qualified as V
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Eval.Value (Value (..), renderValue)
import Hwfl.Json.Encode (jsonToValue, valueToAeson, valueToJsonText)
import Test.Hspec

spec :: Spec
spec = describe "jsonToValue" $ do
  it "preserves integers beyond Double precision" $
    jsonToValue (Aeson.Number (scientific 9007199254740993 0))
      `shouldBe` Right (VInt 9007199254740993)

  it "preserves large integers recursively" $
    jsonToValue
      ( Aeson.Array
          ( V.fromList
              [ Aeson.Number (scientific 9007199254740993 0),
                Aeson.Object
                  ( KM.fromList
                      [ ("nested", Aeson.Number (scientific 9007199254740993 0))
                      ]
                  )
              ]
          )
      )
      `shouldBe` Right
        ( VList
            [ VInt 9007199254740993,
              VRecord [(Ident "nested", VInt 9007199254740993)]
            ]
        )

  it "rejects fractional values that overflow Float" $
    jsonToValue (Aeson.Number (scientific (10 ^ (1000 :: Int) + 1) (-1)))
      `shouldSatisfy` isLeft

  it "rejects non-finite floats during JSON encoding" $
    valueToJsonText (VRecord [(Ident "nested", VFloat (1 / 0))])
      `shouldSatisfy` isLeft

  it "rejects non-finite floats during rendering" $
    renderValue (VFloat (1 / 0))
      `shouldSatisfy` isLeft

  it "encodes Option Some/None as unwrapped JSON / null" $ do
    valueToAeson (VVariant (TypeName "None") Nothing) `shouldBe` Right Aeson.Null
    valueToAeson (VVariant (TypeName "Some") (Just (VInt 3)))
      `shouldBe` Right (Aeson.Number 3)

  it "encodes nullary variants as tagged objects, not bare strings" $ do
    let tagged =
          Aeson.Object (KM.fromList [("tag", Aeson.String "Ok")])
    valueToAeson (VVariant (TypeName "Ok") Nothing) `shouldBe` Right tagged
    -- Schema-free decode stays a record (same as payload variants), never VString.
    jsonToValue tagged
      `shouldBe` Right (VRecord [(Ident "tag", VString "Ok")])

  it "encodes payload variants as tagged objects with value" $
    valueToAeson (VVariant (TypeName "Ok") (Just (VInt 1)))
      `shouldBe` Right
        ( Aeson.Object
            ( KM.fromList
                [ ("tag", Aeson.String "Ok"),
                  ("value", Aeson.Number 1)
                ]
            )
        )
