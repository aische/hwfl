-- | Model-catalog pricing for LLM span cost attribution.
module Hwfl.Llm.Pricing
  ( ModelPricing (..),
    ModelRates (..),
    emptyModelPricing,
    loadModelPricing,
    providerCloseAttrs,
    providerRoundCloseAttrs,
    attrsCostUsd,
    attrsCostMicros,
    formatCostUsd,
    formatCostDollars,
  )
where

import Data.Aeson (FromJSON, Value (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Scientific (toBoundedInteger, toRealFloat)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Hwfl.Llm.Types (ProviderResult (..), TokenUsage (..))
import System.Directory (doesFileExist)
import Text.Printf (printf)

data ModelRates = ModelRates
  { mrInputPerM :: Double,
    mrOutputPerM :: Double
  }
  deriving stock (Eq, Show, Generic)

instance FromJSON ModelRates where
  parseJSON = withObject "pricing" $ \o ->
    ModelRates
      <$> o .: "pricePerMillionInput"
      <*> o .: "pricePerMillionOutput"

data CatalogEntry = CatalogEntry
  { ceName :: Text,
    cePricing :: ModelRates
  }
  deriving stock (Generic)

instance FromJSON CatalogEntry where
  parseJSON = withObject "catalogEntry" $ \o ->
    CatalogEntry <$> o .: "modelConfigName" <*> o .: "pricing"

newtype ModelPricing = ModelPricing {mpRates :: Map Text ModelRates}
  deriving stock (Eq, Show)

emptyModelPricing :: ModelPricing
emptyModelPricing = ModelPricing Map.empty

loadModelPricing :: FilePath -> IO ModelPricing
loadModelPricing path = do
  exists <- doesFileExist path
  if not exists
    then pure emptyModelPricing
    else do
      bs <- LBS.readFile path
      pure $
        case Aeson.eitherDecode bs of
          Left _ -> emptyModelPricing
          Right (entries :: [CatalogEntry]) ->
            ModelPricing
              (Map.fromList [(e.ceName, e.cePricing) | e <- entries])

tokenCostMicros :: ModelPricing -> Text -> Int -> Int -> Maybe Int
tokenCostMicros (ModelPricing rates) model tin tout =
  case Map.lookup model rates of
    Nothing -> Nothing
    Just r ->
      let cost =
            (fromIntegral tin * mrInputPerM r + fromIntegral tout * mrOutputPerM r)
              / 1_000_000
       in Just (round (cost * 1_000_000 :: Double))

-- | Exact dollars from microdollars (no cent rounding). Round only in
-- 'formatCostUsd' / 'formatCostDollars' for display.
microsToDollars :: Int -> Double
microsToDollars micros = fromIntegral micros / 1_000_000

dollarsToMicros :: Double -> Int
dollarsToMicros dollars = round (dollars * 1_000_000 :: Double)

formatCostUsd :: Int -> Text
formatCostUsd micros = formatCostDollars (microsToDollars micros)

formatCostDollars :: Double -> Text
formatCostDollars dollars = T.pack (printf "$%0.2f" dollars)

usageCostAttrs :: ModelPricing -> Text -> Maybe TokenUsage -> [(Key.Key, Aeson.Value)]
usageCostAttrs pricing model mUsage = case mUsage of
  Nothing -> []
  Just u ->
    let tin = u.usageInputTokens
        tout = u.usageOutputTokens
        base =
          [ Key.fromText "token_in" .= tin,
            Key.fromText "token_out" .= tout
          ]
     in base <> costPair pricing model tin tout

costPair :: ModelPricing -> Text -> Int -> Int -> [(Key.Key, Aeson.Value)]
costPair pricing model tin tout =
  case tokenCostMicros pricing model tin tout of
    Nothing -> []
    Just micros ->
      -- Integer micros are the source of truth for aggregation; full-precision
      -- cost_usd is kept for older readers / human JSON inspection.
      [ Key.fromText "cost_micros" .= micros,
        Key.fromText "cost_usd" .= microsToDollars micros
      ]

providerCloseAttrs :: ModelPricing -> Text -> ProviderResult -> Aeson.Value
providerCloseAttrs pricing model pr =
  object $
    (Key.fromText "reply_len" .= T.length pr.prContent) : usageCostAttrs pricing model pr.prUsage

providerRoundCloseAttrs :: ModelPricing -> Text -> ProviderResult -> Aeson.Value
providerRoundCloseAttrs pricing model pr =
  object $
    [ Key.fromText "reply_len" .= T.length pr.prContent,
      Key.fromText "tool_calls" .= length pr.prToolCalls
    ]
      ++ usageCostAttrs pricing model pr.prUsage

-- | Prefer integer @cost_micros@; fall back to @cost_usd@ (legacy rounded
-- or full-precision dollars).
attrsCostMicros :: Value -> Maybe Int
attrsCostMicros = \case
  Object km ->
    case KM.lookup "cost_micros" km of
      Just (Aeson.Number n)
        | Just m <- toBoundedInteger n -> Just m
      _ -> case KM.lookup "cost_usd" km of
        Just (Aeson.Number n) -> Just (dollarsToMicros (toRealFloat n :: Double))
        _ -> Nothing
  _ -> Nothing

attrsCostUsd :: Value -> Maybe Double
attrsCostUsd attrs = microsToDollars <$> attrsCostMicros attrs
