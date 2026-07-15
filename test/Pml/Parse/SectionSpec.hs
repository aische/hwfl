module Pml.Parse.SectionSpec (spec) where

import Pml.Ast.Name (slugToText)
import Pml.Parse.Section (computeSlug)
import Test.Hspec

spec :: Spec
spec = describe "computeSlug" $ do
  it "lowercases and dashes spaces" $
    slugToText (computeSlug "Hello World") `shouldBe` "hello-world"

  it "strips punctuation outside [a-z0-9-]" $
    slugToText (computeSlug "A_B/C!") `shouldBe` "abc"

  it "collapses repeated hyphens" $
    slugToText (computeSlug "foo   bar") `shouldBe` "foo-bar"
