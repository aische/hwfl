-- | Source positions and diagnostics for parse/load errors.
module Hwfl.Source
  ( Pos (..),
    Diagnostic (..),
    mkDiagnostic,
    renderPos,
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
  deriving stock (Eq, Ord, Show, Read)

data Diagnostic = Diagnostic
  { diagPath :: FilePath,
    diagPos :: !Pos,
    diagMessage :: Text
  }
  deriving stock (Eq, Show)

mkDiagnostic :: FilePath -> Pos -> Text -> Diagnostic
mkDiagnostic = Diagnostic

-- | @line:col@ (no path).
renderPos :: Pos -> Text
renderPos p =
  T.pack (show p.posLine) <> ":" <> T.pack (show p.posCol)

renderDiagnostic :: Diagnostic -> Text
renderDiagnostic d =
  T.pack d.diagPath
    <> ":"
    <> renderPos d.diagPos
    <> ": "
    <> d.diagMessage

renderDiagnostics :: [Diagnostic] -> Text
renderDiagnostics = T.intercalate "\n" . map renderDiagnostic
