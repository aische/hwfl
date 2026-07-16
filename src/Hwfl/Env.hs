-- | Optional host environment loading for the CLI.
module Hwfl.Env (loadDotenv) where

import Configuration.Dotenv (defaultConfig, loadFile, onMissingFile)
import Control.Exception (SomeException, catch)

-- | Load @.env@ from the current working directory when present.
--
-- Missing files are ignored. Other load errors are also ignored so a
-- local @.env@ never prevents the CLI from starting.
loadDotenv :: IO ()
loadDotenv =
  (loadFile defaultConfig `onMissingFile` pure ())
    `catch` \(_ :: SomeException) -> pure ()
