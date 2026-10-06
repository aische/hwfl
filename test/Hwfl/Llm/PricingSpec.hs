module Hwfl.Llm.PricingSpec (spec) where

import Data.Aeson (encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Hwfl.Llm.Pricing
  ( ModelPricing (..),
    ModelRates (..),
    attrsCostMicros,
    formatCostDollars,
    formatCostUsd,
    loadModelPricing,
    providerCloseAttrs,
  )
import Hwfl.Llm.Types (
    FinishReason (..),
    TokenUsage (..),
    mkTokenUsage,
    providerResultText,
  )
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
      pricing <- loadPricing path
      let pr =
            providerResultText ("x") (Just (mkTokenUsage 1_000_000 500_000)) FinishStop
          attrs = providerCloseAttrs pricing "demo" pr
      LBS8.unpack (encode attrs) `shouldContain` "cost_micros"
      LBS8.unpack (encode attrs) `shouldContain` "cost_usd"
      LBS8.unpack (encode attrs) `shouldContain` "finish_reason"
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
      pricing <- loadPricing path
      let pr =
            providerResultText ("hi") (Just (mkTokenUsage 0 1_000_000)) FinishStop
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
      pricing <- loadPricing path
      -- 14 rounds × ~3.5k in / ~186 out ≈ 49k / 2.6k; each round is under half a cent.
      let tinPer = 3_500
          toutPer = 186
          rounds = 14 :: Int
          mkPr =
            providerResultText ("ok") (Just (mkTokenUsage tinPer toutPer)) FinishStop
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

  it "prices no-cache usage at ordinary input/output rates" $ do
    let pricing =
          ModelPricing
            ( Map.singleton
                "m"
                ( ModelRates
                    { mrInputPerM = 1.0,
                      mrOutputPerM = 5.0,
                      mrCacheReadPerM = Nothing,
                      mrCacheWritePerM = Nothing
                    }
                )
            )
        usage = mkTokenUsage 1_000_000 1_000_000
        attrs =
          providerCloseAttrs
            pricing
            "m"
            (providerResultText "x" (Just usage) FinishStop)
    attrsCostMicros attrs `shouldBe` Just 6_000_000
    attrInt attrs "token_in" `shouldBe` Just 1_000_000
    attrInt attrs "token_out" `shouldBe` Just 1_000_000
    attrInt attrs "token_cache_read" `shouldBe` Just 0
    attrInt attrs "token_cache_creation" `shouldBe` Just 0

  it "prices mixed cache read/write with distinct rates" $ do
    let pricing =
          ModelPricing
            ( Map.singleton
                "m"
                ( ModelRates
                    { mrInputPerM = 3.0,
                      mrOutputPerM = 15.0,
                      mrCacheReadPerM = Just 0.3,
                      mrCacheWritePerM = Just 3.75
                    }
                )
            )
        usage =
          TokenUsage
            { usageInputTokens = 1_000_000,
              usageOutputTokens = 0,
              usageCacheReadTokens = 400_000,
              usageCacheCreationTokens = 100_000
            }
        -- ordinary 500k * 3 + read 400k * 0.3 + write 100k * 3.75 = 1.995
        attrs =
          providerCloseAttrs
            pricing
            "m"
            (providerResultText "x" (Just usage) FinishStop)
    attrsCostMicros attrs `shouldBe` Just 1_995_000
    attrInt attrs "token_in" `shouldBe` Just 1_000_000
    attrInt attrs "token_cache_read" `shouldBe` Just 400_000
    attrInt attrs "token_cache_creation" `shouldBe` Just 100_000

  it "falls back to input rate when cache rates are absent" $ do
    let pricing =
          ModelPricing
            ( Map.singleton
                "m"
                ( ModelRates
                    { mrInputPerM = 2.0,
                      mrOutputPerM = 0.0,
                      mrCacheReadPerM = Nothing,
                      mrCacheWritePerM = Nothing
                    }
                )
            )
        usage =
          TokenUsage
            { usageInputTokens = 1_000_000,
              usageOutputTokens = 0,
              usageCacheReadTokens = 250_000,
              usageCacheCreationTokens = 250_000
            }
        attrs =
          providerCloseAttrs
            pricing
            "m"
            (providerResultText "x" (Just usage) FinishStop)
    -- All 1M tokens priced at input rate → $2.00
    attrsCostMicros attrs `shouldBe` Just 2_000_000

  it "parses optional cache rates from the model catalog" $ do
    withSystemTempDirectory "hwfl-pricing-cache-rates" $ \dir -> do
      let path = dir </> "catalog.json"
      LBS8.writeFile path $
        encode
          [ object
              [ "modelConfigName" .= ("claude" :: String),
                "pricing"
                  .= object
                    [ "pricePerMillionInput" .= (3.0 :: Double),
                      "pricePerMillionOutput" .= (15.0 :: Double),
                      "pricePerMillionCacheRead" .= (0.3 :: Double),
                      "pricePerMillionCacheWrite" .= (3.75 :: Double)
                    ]
              ]
          ]
      pricing <- loadPricing path
      case Map.lookup "claude" pricing.mpRates of
        Nothing -> expectationFailure "missing catalog entry"
        Just rates -> do
          rates.mrInputPerM `shouldBe` 3.0
          rates.mrOutputPerM `shouldBe` 15.0
          rates.mrCacheReadPerM `shouldBe` Just 0.3
          rates.mrCacheWritePerM `shouldBe` Just 3.75

  it "reports malformed catalogs instead of silently using zero pricing" $
    withSystemTempDirectory "hwfl-pricing-invalid" $ \dir -> do
      let path = dir </> "catalog.json"
      LBS8.writeFile path "not json"
      result <- loadModelPricing path
      result `shouldSatisfy` isLeft

  it "rejects catalog entries with incomplete pricing objects" $
    withSystemTempDirectory "hwfl-pricing-incomplete" $ \dir -> do
      let path = dir </> "catalog.json"
      LBS8.writeFile path $
        encode
          [ object
              [ "modelConfigName" .= ("broken" :: String),
                "pricing"
                  .= object
                    [ "pricePerMillionInput" .= (1.0 :: Double)
                      -- missing pricePerMillionOutput
                    ]
              ]
          ]
      result <- loadModelPricing path
      result `shouldSatisfy` isLeft

loadPricing :: FilePath -> IO ModelPricing
loadPricing path = do
  result <- loadModelPricing path
  case result of
    Left err -> expectationFailure ("expected valid catalog: " <> show err) >> error "unreachable"
    Right pricing -> pure pricing

attrInt :: Aeson.Value -> Text -> Maybe Int
attrInt (Aeson.Object km) key = case KM.lookup (Key.fromText key) km of
  Just (Aeson.Number n) -> Just (round n)
  _ -> Nothing
attrInt _ _ = Nothing

isLeft :: Either a b -> Bool
isLeft = \case
  Left _ -> True
  Right _ -> False
