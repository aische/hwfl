{-# LANGUAGE OverloadedStrings #-}

module Hwfl.Text.CorpusSpec (spec) where

import Hwfl.Text.Corpus
  ( textIsQname,
    textNormalizeToken,
    textStartsWith,
    textTrim,
  )
import Test.Hspec

spec :: Spec
spec = describe "text corpus helpers" $ do
  it "trims and normalizes wrapping punct / backticks" $ do
    textTrim "  x  " `shouldBe` "x"
    textNormalizeToken "`skills/python-pytest`" `shouldBe` "skills/python-pytest"
    textNormalizeToken "tools/helper," `shouldBe` "tools/helper"
    textNormalizeToken "language/toolchain." `shouldBe` "language/toolchain"

  it "starts_with matches prefixes" $ do
    textStartsWith "workflows/main.md" "workflows/" `shouldBe` True
    textStartsWith "README.md" "workflows/" `shouldBe` False

  it "is_qname accepts module roots and rejects noise" $ do
    textIsQname "workflows/missing" `shouldBe` True
    textIsQname "lib/search" `shouldBe` True
    textIsQname "`tools/helper`" `shouldBe` True
    textIsQname "skills/python-pytest" `shouldBe` True
    textIsQname "/" `shouldBe` False
    textIsQname "stdout/stderr" `shouldBe` False
    textIsQname "language/toolchain" `shouldBe` False
    textIsQname "/tmp/hwfl-build" `shouldBe` False
    textIsQname "examples/coding-agent" `shouldBe` False
    textIsQname "discover/load" `shouldBe` False
    textIsQname "http://example.com/a" `shouldBe` False
