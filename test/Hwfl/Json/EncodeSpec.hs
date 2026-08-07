module Hwfl.Json.EncodeSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Either (isLeft)
import Data.Scientific (scientific)
import Data.Vector qualified as V
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Eval.Value (Value (..))
import Hwfl.Json.Encode (jsonToValue)
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
