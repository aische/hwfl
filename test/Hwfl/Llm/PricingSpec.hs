module Hwfl.Llm.PricingSpec (spec) where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Maybe (fromMaybe, mapMaybe)
import Hwfl.Llm.Pricing
  ( attrsCostMicros,
    formatCostDollars,
    formatCostUsd,
    loadModelPricing,
    providerCloseAttrs,
  )
import Hwfl.Llm.Types (FinishReason (..), ProviderResult (..), TokenUsage (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "LLM pricing" $ do
  it "stores cost_micros and formats display dollars to cents" $ do
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
      LBS8.unpack (encode attrs) `shouldContain` "cost_micros"
      LBS8.unpack (encode attrs) `shouldContain` "cost_usd"
      attrsCostMicros attrs `shouldBe` Just 2_000_000
      formatCostUsd 2_000_000 `shouldBe` "$2.00"
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
      attrsCostMicros attrs `shouldBe` Just 1_000_000

  it "aggregates sub-cent DeepSeek rounds without zeroing the forest total" $ do
    withSystemTempDirectory "hwfl-pricing-deepseek" $ \dir -> do
      let path = dir </> "catalog.json"
      LBS8.writeFile path $
        encode
          [ object
              [ "modelConfigName" .= ("deepseek4flash" :: String),
                "pricing"
                  .= object
                    [ "pricePerMillionInput" .= (0.14 :: Double),
                      "pricePerMillionOutput" .= (0.28 :: Double)
                    ]
              ]
          ]
      pricing <- loadModelPricing path
      -- 14 rounds × ~3.5k in / ~186 out ≈ 49k / 2.6k; each round is under half a cent.
      let tinPer = 3_500
          toutPer = 186
          rounds = 14 :: Int
          mkPr =
            ProviderResult
              { prContent = "ok",
                prToolCalls = [],
                prUsage = Just (TokenUsage tinPer toutPer),
                prFinishReason = FinishStop
              }
          closes = replicate rounds (providerCloseAttrs pricing "deepseek4flash" mkPr)
          perMicros = fromMaybe 0 (attrsCostMicros (head closes))
          totalMicros = sum (mapMaybe attrsCostMicros closes)
          expectedMicros =
            round
              ( ( fromIntegral (rounds * tinPer) * 0.14
                    + fromIntegral (rounds * toutPer) * 0.28
                )
                  :: Double
              )
      perMicros `shouldSatisfy` (> 0)
      perMicros `shouldSatisfy` (< 5_000) -- under half a cent
      -- Old bug: cent-round each span → 0, forest total $0.00
      totalMicros `shouldSatisfy` (> 0)
      abs (totalMicros - expectedMicros) `shouldSatisfy` (<= 1)
      formatCostUsd totalMicros `shouldNotBe` "$0.00"
      -- Full-precision cost_usd present (not pre-rounded away)
      LBS8.unpack (encode (head closes)) `shouldContain` "cost_usd"
      LBS8.unpack (encode (head closes)) `shouldContain` "cost_micros"
