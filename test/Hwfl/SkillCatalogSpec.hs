module Hwfl.SkillCatalogSpec (spec) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Module (Frontmatter (..), LoadedModule (..))
import Hwfl.Ast.Name (Ident (..), QName (..), qnameToText)
import Hwfl.Ast.Skill (SkillKind (..), SkillMeta (..))
import Hwfl.Check.Project (CheckProjectResult (..), checkProject)
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Project (LoadedProject (..), loadProject)
import Hwfl.SkillCatalog
  ( SkillCatalog (..),
    SkillEntry (..),
    discoverSkills,
    isSkillQName,
  )
import Hwfl.Source (renderDiagnostics)
import System.FilePath ((</>))
import Test.Hspec

fixtureRoot :: FilePath
fixtureRoot = "test/fixtures" </> "skills-project"

spec :: Spec
spec = describe "skill catalog (phase A)" $ do
  it "discovers skills/ modules in the project index" $ do
    lp <- loadProjectOrFail fixtureRoot
    let qs = Map.keys lp.lpModules
    any isSkillQName qs `shouldBe` True
    map qnameToText (filter isSkillQName qs)
      `shouldMatchList` [ "skills/echo-tool",
                          "skills/meta-peek",
                          "skills/shell-repair-guide"
                        ]

  it "parses instruction vs callable kinds and rejects instruction fences" $ do
    case loadModuleText "skills/guide.md" instructionSrc of
      Left diags -> expectationFailure (T.unpack (renderDiagnostics diags))
      Right m -> do
        case m.lmFrontmatter.fmSkill of
          Just meta -> smKind meta `shouldBe` SkillInstruction
          Nothing -> expectationFailure "expected skill meta"
        T.isInfixOf "sh -n" m.lmProseBody `shouldBe` True
    case loadModuleText "skills/bad.md" instructionWithFence of
      Left diags ->
        renderDiagnostics diags `shouldSatisfy` ("must not contain" `T.isInfixOf`)
      Right _ -> expectationFailure "expected fence rejection"

  it "buildSkillCatalog marks checked / agent_eligible flags" $ do
    result <- checkProject fixtureRoot
    case result of
      Left err -> expectationFailure (show err)
      Right cpr -> do
        let cat = cpr.cprSkillCatalog
            entries = Map.elems cat.scEntries
        length entries `shouldBe` 3
        let byId i = Map.lookup (qname i) cat.scEntries
        case byId "skills/shell-repair-guide" of
          Just e -> do
            seKind e `shouldBe` SkillInstruction
            seChecked e `shouldBe` True
            seAgentEligible e `shouldBe` False
            seSummary e `shouldSatisfy` (not . T.null)
            seBody e `shouldSatisfy` maybe False (T.isInfixOf "sh -n")
          Nothing -> expectationFailure "missing instruction"
        case byId "skills/echo-tool" of
          Just e -> do
            seKind e `shouldBe` SkillCallable
            seChecked e `shouldBe` True
            seAgentEligible e `shouldBe` True
            seBody e `shouldBe` Nothing
          Nothing -> expectationFailure "missing callable"
        case byId "skills/meta-peek" of
          Just e -> do
            seKind e `shouldBe` SkillCallable
            seChecked e `shouldBe` True
            seAgentEligible e `shouldBe` False
          Nothing -> expectationFailure "missing meta skill"

  it "discoverSkills filters by query, kinds, and limit (metadata only)" $ do
    result <- checkProject fixtureRoot
    case result of
      Left err -> expectationFailure (show err)
      Right cpr -> do
        let cat = cpr.cprSkillCatalog
            hits = discoverSkills cat "shell" [] 10
        map (qnameToText . seId) hits
          `shouldMatchList` ["skills/shell-repair-guide"]
        let kindsOnly = discoverSkills cat "" ["callable"] 10
        all ((== SkillCallable) . seKind) kindsOnly `shouldBe` True
        length kindsOnly `shouldBe` 2
        let limited = discoverSkills cat "" [] 1
        length limited `shouldBe` 1
        -- Catalog stores instruction bodies for load; discover API omits them.
        case Map.lookup (qname "skills/shell-repair-guide") cat.scEntries of
          Just e -> seBody e `shouldSatisfy` maybe False (not . T.null)
          Nothing -> expectationFailure "missing guide"

qname :: Text -> QName
qname = QName . map Ident . T.splitOn "/"

loadProjectOrFail :: FilePath -> IO LoadedProject
loadProjectOrFail path = do
  result <- loadProject path
  case result of
    Left err -> fail (T.unpack err)
    Right lp -> pure lp

instructionSrc :: Text
instructionSrc =
  T.unlines
    [ "---",
      "name: skills/guide",
      "skill:",
      "  kind: instruction",
      "  summary: guide",
      "  tags: [shell]",
      "---",
      "",
      "Always run `sh -n` first."
    ]

instructionWithFence :: Text
instructionWithFence =
  T.unlines
    [ "---",
      "name: skills/bad",
      "skill:",
      "  kind: instruction",
      "---",
      "",
      "```hwfl",
      "fun main(_) = {}",
      "```"
    ]
