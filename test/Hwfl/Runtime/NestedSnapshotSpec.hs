-- | Nested machines must never overwrite root snapshot.json (High #1).
module Hwfl.Runtime.NestedSnapshotSpec (spec) where

import Data.Aeson (Value (Null, Object, String), eitherDecodeStrict')
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Char8 qualified as BS8
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..), QName (..))
import Hwfl.Check.Project (checkProject)
import Hwfl.Eval.Value (Value (..))
import Hwfl.Llm.Mock (mockProvider)
import Hwfl.Obs.Observer (noopObserver)
import Hwfl.Parse.Load (loadModuleText)
import Hwfl.Project (LoadedProject (..), loadProject)
import Hwfl.Runtime.Eval (StepMode (..))
import Hwfl.Runtime.Run
  ( RunOptions (..),
    RunOutcome (..),
    emptySkillRuntime,
    runLoadedModule,
  )
import Hwfl.Runtime.Store (storeRunId)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

parSrc :: Text
parSrc =
  T.unlines
    [ "---",
      "name: workflows/par_nested_snap",
      "inputs: {}",
      "outputs:",
      "  texts: \"List<{ text: String }>\"",
      "effects: [Read, Parallel]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { texts: List<{ text: String }> } =",
      "  let texts =",
      "    par(max = 2) for p in [\"a.txt\", \"b.txt\"] {",
      "      fs.read(p)",
      "    }",
      "  { texts }",
      "```"
    ]

callerSrc :: Text
callerSrc =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs: {}",
      "outputs:",
      "  text: String",
      "effects: [Read]",
      "imports:",
      "  - workflows/inner",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { text: String } =",
      "  let r = workflows/inner({ path = \"note.txt\", tag = \"t\" })",
      "  { text = r.text }",
      "```"
    ]

innerSrc :: Text
innerSrc =
  T.unlines
    [ "---",
      "name: workflows/inner",
      "inputs:",
      "  path: String",
      "  tag: String",
      "outputs:",
      "  text: String",
      "effects: [Read]",
      "---",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(inputs): { text: String } =",
      "  let r = fs.read(inputs.path)",
      "  { text = r.text }",
      "```"
    ]

projectJson :: String
projectJson =
  unlines
    [ "{",
      "  \"name\": \"nested-snap\",",
      "  \"version\": \"0.1.0\",",
      "  \"entrypoint\": \"workflows/main\",",
      "  \"effects\": { \"default\": [\"Read\"], \"deny\": [] }",
      "}"
    ]

transitionHosts :: FilePath -> IO [Maybe Text]
transitionHosts path = do
  raw <- readFile path
  pure $ mapMaybe parseHost (lines raw)
  where
    parseHost line =
      case eitherDecodeStrict' (BS8.pack line) of
        Right (Object o) ->
          case KM.lookup "host" o of
            Just Null -> Just Nothing
            Just (String h) -> Just (Just h)
            Just _ -> Just Nothing
            Nothing -> Just Nothing
        _ -> Nothing

spec :: Spec
spec = describe "nested snapshot persist (outer only)" $ do
  it "par branch host ops do not appear as root snapshot hosts" $
    withSystemTempDirectory "hwfl-nested-par" $ \dir -> do
      writeFile (dir </> "a.txt") "A"
      writeFile (dir </> "b.txt") "B"
      let path = dir </> "mod.md"
      writeFile path (T.unpack parSrc)
      case loadModuleText path parSrc of
        Left diags -> expectationFailure (show diags)
        Right loaded -> do
          outcome <-
            runLoadedModule
              RunOptions
                { roWorkspace = dir,
                  roProvider = mockProvider,
                  roInputs = [],
                  roRunId = Just "nested-par",
                  roEntry = path,
                  roMode = StepRun,
                  roProjectHash = Nothing,
                  roExec = Nothing,
                  roObserver = noopObserver,
                  roCost = False,
                  roModelCatalog = "model-catalog.json",
                  roSkillCatalog = fst emptySkillRuntime,
                  roSkillModules = snd emptySkillRuntime,
                  roEntryModules = mempty
                }
              loaded
          case outcome of
            OutcomeCompleted _ store _ -> do
              let transitions =
                    dir
                      </> ".hwfl"
                      </> "runs"
                      </> T.unpack (storeRunId store)
                      </> "transitions.jsonl"
              hosts <- transitionHosts transitions
              -- Nested fs.read must not write a bare branch as root (host=fs.read).
              [h | Just h <- hosts, h == "fs.read"] `shouldBe` []
            other -> expectationFailure (show other)

  it "FrInvoke callee host ops do not appear as root snapshot hosts" $
    withSystemTempDirectory "hwfl-nested-invoke" $ \dir -> do
      createDirectoryIfMissing True (dir </> "workflows")
      writeFile (dir </> "project.json") projectJson
      writeFile (dir </> "workflows" </> "main.md") (T.unpack callerSrc)
      writeFile (dir </> "workflows" </> "inner.md") (T.unpack innerSrc)
      writeFile (dir </> "note.txt") "hello"
      checked <- checkProject dir
      case checked of
        Left err -> expectationFailure (show err)
        Right _ -> do
          lp <- loadProjectOrFail dir
          case Map.lookup (qname "workflows/main") lp.lpModules of
            Nothing -> expectationFailure "missing workflows/main"
            Just m -> do
              outcome <-
                runLoadedModule
                  RunOptions
                    { roWorkspace = dir,
                      roProvider = mockProvider,
                      roInputs = [],
                      roRunId = Just "nested-invoke",
                      roEntry = dir </> "workflows" </> "main.md",
                      roMode = StepRun,
                      roProjectHash = Nothing,
                      roExec = Nothing,
                      roObserver = noopObserver,
                      roCost = False,
                      roModelCatalog = "model-catalog.json",
                      roSkillCatalog = fst emptySkillRuntime,
                      roSkillModules = snd emptySkillRuntime,
                      roEntryModules = lp.lpModules
                    }
                  m
              case outcome of
                OutcomeCompleted (VRecord fs) store _ -> do
                  lookup (Ident "text") fs `shouldBe` Just (VString "hello")
                  let transitions =
                        dir
                          </> ".hwfl"
                          </> "runs"
                          </> T.unpack (storeRunId store)
                          </> "transitions.jsonl"
                  hosts <- transitionHosts transitions
                  [h | Just h <- hosts, h == "fs.read"] `shouldBe` []
                other -> expectationFailure (show other)

qname :: Text -> QName
qname = QName . map Ident . T.splitOn "/"

loadProjectOrFail :: FilePath -> IO LoadedProject
loadProjectOrFail path = do
  result <- loadProject path
  case result of
    Left err -> fail (T.unpack err)
    Right lp -> pure lp
