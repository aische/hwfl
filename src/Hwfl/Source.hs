-- | Source positions and diagnostics for parse/load errors.
module Hwfl.Source
  ( Pos (..),
    Diagnostic (..),
    mkDiagnostic,
    renderDiagnostic,
    renderDiagnostics,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

-- | 1-based line/column within a file.
data Pos = Pos
  { posLine :: !Int,
    posCol :: !Int
  }
  deriving stock (Eq, Ord, Show)

data Diagnostic = Diagnostic
  { diagPath :: FilePath,
    diagPos :: !Pos,
    diagMessage :: Text
  }
  deriving stock (Eq, Show)

mkDiagnostic :: FilePath -> Pos -> Text -> Diagnostic
mkDiagnostic path pos msg = Diagnostic path pos msg

renderDiagnostic :: Diagnostic -> Text
renderDiagnostic d =
  T.pack d.diagPath
    <> ":"
    <> T.pack (show d.diagPos.posLine)
    <> ":"
    <> T.pack (show d.diagPos.posCol)
    <> ": "
    <> d.diagMessage

renderDiagnostics :: [Diagnostic] -> Text
renderDiagnostics = T.intercalate "\n" . map renderDiagnostic
