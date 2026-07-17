module Hwfl.Llm.PricingSpec (spec) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Hwfl.Llm.Pricing
  ( formatCostDollars,
    loadModelPricing,
    providerCloseAttrs,
  )
import Hwfl.Llm.Types (ProviderResult (..), TokenUsage (..), FinishReason (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "LLM pricing" $ do
  it "computes per-million token cost rounded to cents" $ do
    withSystemTempDirectory "hwfl-pricing" $ \dir -> do
      let path = dir </> "catalog.json"
      LBS8.writeFile path $
        encode
          [ object
              [ "modelConfigName" .= ("demo" :: String),
                "pricing"
                  .= object
                    [ "pricePerMillionInput" .= (1.0 :: Double),
                      "pricePerMillionOutput" .= (2.0 :: Double)
                    ]
              ]
          ]
      pricing <- loadModelPricing path
      let pr =
            ProviderResult
              { prContent = "x",
                prToolCalls = [],
                prUsage = Just (TokenUsage 1_000_000 500_000),
                prFinishReason = FinishStop
              }
          attrs = providerCloseAttrs pricing "demo" pr
      LBS8.unpack (encode attrs) `shouldContain` "cost_usd"
      formatCostDollars 2.0 `shouldBe` "$2.00"

  it "adds cost_usd to llm span close attrs when priced" $ do
    withSystemTempDirectory "hwfl-pricing2" $ \dir -> do
      createDirectoryIfMissing True dir
      let path = dir </> "catalog.json"
      LBS8.writeFile path $
        encode
          [ object
              [ "modelConfigName" .= ("gpt-5" :: String),
                "pricing"
                  .= object
                    [ "pricePerMillionInput" .= (0.0 :: Double),
                      "pricePerMillionOutput" .= (1.0 :: Double)
                    ]
              ]
          ]
      pricing <- loadModelPricing path
      let pr =
            ProviderResult
              { prContent = "hi",
                prToolCalls = [],
                prUsage = Just (TokenUsage 0 1_000_000),
                prFinishReason = FinishStop
              }
          attrs = providerCloseAttrs pricing "gpt-5" pr
      LBS8.unpack (encode attrs) `shouldContain` "cost_usd"
