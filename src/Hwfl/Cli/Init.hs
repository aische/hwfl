-- | @hwfl init@ — scaffold a minimal project for the hello path.
module Hwfl.Cli.Init
  ( InitError (..),
    InitResult (..),
    renderInitError,
    scaffoldProject,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    getCurrentDirectory,
  )
import System.FilePath (takeBaseName, takeFileName, (</>))

newtype InitError
  = InitAlreadyExists FilePath
  deriving stock (Eq, Show)

data InitResult = InitResult
  { irRoot :: FilePath,
    irProjectName :: Text,
    irCreated :: [FilePath]
  }
  deriving stock (Eq, Show)

renderInitError :: InitError -> Text
renderInitError = \case
  InitAlreadyExists path ->
    "hwfl init: refusing to overwrite existing " <> T.pack path

-- | Create @project.json@ and @workflows/main.md@ under @root@.
-- @root@ may be @\".\"@ / empty (current directory) or a new/existing directory.
scaffoldProject :: FilePath -> IO (Either InitError InitResult)
scaffoldProject rawRoot = do
  root <- resolveRoot rawRoot
  let projectJson = root </> "project.json"
      workflowDir = root </> "workflows"
      mainMd = workflowDir </> "main.md"
  exists <- doesFileExist projectJson
  if exists
    then pure (Left (InitAlreadyExists projectJson))
    else do
      mainExists <- doesFileExist mainMd
      if mainExists
        then pure (Left (InitAlreadyExists mainMd))
        else do
          let name = projectNameFor root
          createDirectoryIfMissing True workflowDir
          TIO.writeFile projectJson (projectJsonText name)
          TIO.writeFile mainMd mainModuleText
          pure $
            Right
              InitResult
                { irRoot = root,
                  irProjectName = name,
                  irCreated = [projectJson, mainMd]
                }

resolveRoot :: FilePath -> IO FilePath
resolveRoot raw =
  case raw of
    "" -> getCurrentDirectory
    "." -> getCurrentDirectory
    path -> do
      createDirectoryIfMissing True path
      -- Prefer the path the user asked for in messages; resolve "." only.
      pure path

projectNameFor :: FilePath -> Text
projectNameFor root =
  let base = takeBaseName (dropTrailingSeps root)
      fallback = takeFileName (dropTrailingSeps root)
      chosen = if null base then fallback else base
   in if null chosen then "hello" else T.pack chosen
  where
    dropTrailingSeps = reverse . dropWhile (== '/') . reverse

projectJsonText :: Text -> Text
projectJsonText name =
  T.unlines
    [ "{",
      "  \"name\": " <> jsonString name <> ",",
      "  \"version\": \"0.1.0\",",
      "  \"entrypoint\": \"workflows/main\",",
      "  \"env\": [],",
      "  \"effects\": {",
      "    \"default\": [\"Human\", \"Net\"],",
      "    \"deny\": []",
      "  }",
      "}"
    ]

-- | Escape a project name for JSON (names are path basenames; keep simple).
jsonString :: Text -> Text
jsonString t =
  "\""
    <> T.concatMap
      ( \c -> case c of
          '"' -> "\\\""
          '\\' -> "\\\\"
          _ -> T.singleton c
      )
      t
    <> "\""

-- | Hello module: mock LLM + confirm pause (tutorial lifecycle).
mainModuleText :: Text
mainModuleText =
  T.unlines
    [ "---",
      "name: workflows/main",
      "inputs: {}",
      "outputs:",
      "  greeting: String",
      "  ok: Bool",
      "effects: [Human, Net]",
      "---",
      "",
      "## system",
      "",
      "You are brief. Reply in one short sentence.",
      "",
      "## body",
      "",
      "```hwfl",
      "fun main(_): { greeting: String, ok: Bool } =",
      "  let greeting = llm.chat(",
      "    system = @system,",
      "    prompt = \"Say hello to a new hwfl author.\",",
      "    model = \"deepseek4flash\"",
      "  )",
      "  let ok = confirm {",
      "    title = \"Accept this greeting?\",",
      "    detail = greeting",
      "  }",
      "  { greeting, ok }",
      "```"
    ]
