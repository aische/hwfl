module Hwfl.Parse.SectionSpec (spec) where

import Data.Text (Text)
import Hwfl.Ast.Name (Slug (..), slugToText)
import Hwfl.Parse.Markdown (MdHeading (..))
import Hwfl.Parse.Section
  ( SlugIssue (..),
    computeSlug,
    formatSlugIssue,
    headingSlugIssues,
  )
import Test.Hspec

spec :: Spec
spec = do
  describe "computeSlug" $ do
    it "lowercases and dashes spaces" $
      slugToText (computeSlug "Hello World") `shouldBe` "hello-world"

    it "strips punctuation outside [a-z0-9-]" $
      slugToText (computeSlug "A_B/C!") `shouldBe` "abc"

    it "collapses repeated hyphens" $
      slugToText (computeSlug "foo   bar") `shouldBe` "foo-bar"

    it "strips non-ASCII (L-7)" $ do
      slugToText (computeSlug "Über") `shouldBe` "ber"
      slugToText (computeSlug "Café") `shouldBe` "caf"
      slugToText (computeSlug "你好") `shouldBe` ""

  describe "headingSlugIssues (L-7)" $ do
    it "rejects empty slug after strip" $
      headingSlugIssues [h2 3 "你好"]
        `shouldBe` [EmptySlug "你好" 3]

    it "rejects ASCII collision from non-ASCII strip" $
      headingSlugIssues [h2 3 "Über", h2 7 "ber"]
        `shouldBe` [DuplicateSlug (Slug "ber") [("Über", 3), ("ber", 7)]]

    it "rejects space/hyphen collapse" $
      headingSlugIssues [h2 2 "a b", h2 5 "a-b"]
        `shouldBe` [DuplicateSlug (Slug "a-b") [("a b", 2), ("a-b", 5)]]

    it "formats duplicate messages with both titles" $
      formatSlugIssue (DuplicateSlug (Slug "ber") [("Über", 3), ("ber", 7)])
        `shouldBe` "duplicate section slug \"ber\": headings \"Über\" and \"ber\""

h2 :: Int -> Text -> MdHeading
h2 line title = MdHeading 2 title line line
