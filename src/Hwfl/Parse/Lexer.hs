-- | Megaparsec lexer for the kernel language (spec §02 lexical).
module Hwfl.Parse.Lexer
  ( Parser,
    scn,
    lexeme,
    symbol,
    reservedWords,
    isReserved,
    pIdent,
    pTypeName,
    pKeyword,
    getPos,
    runP,
    runPFromLine,
    bundleToDiagnostics,
  )
where

import Control.Monad (when)
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Source (Diagnostic (..), Pos (Pos), mkDiagnostic)
import Hwfl.Source qualified as Src
import Text.Megaparsec hiding (Pos)
import Text.Megaparsec.Char (space1, string)
import Text.Megaparsec.Char.Lexer qualified as L
import Text.Megaparsec.Pos (SourcePos (..), mkPos, sourceColumn, sourceLine, sourceName, unPos)

type Parser = Parsec Void Text

-- | Current megaparsec source position as a 1-based 'Hwfl.Source.Pos'.
getPos :: Parser Src.Pos
getPos = do
  sp <- getSourcePos
  pure (Pos (unPos (sourceLine sp)) (unPos (sourceColumn sp)))

scn :: Parser ()
scn = L.space space1 lineComment empty

lineComment :: Parser ()
lineComment = L.skipLineComment "--"

lexeme :: Parser a -> Parser a
lexeme = L.lexeme scn

symbol :: Text -> Parser Text
symbol = L.symbol scn

reservedWords :: Set.Set Text
reservedWords =
  Set.fromList
    [ "let",
      "in",
      "fun",
      "type",
      "match",
      "with",
      "if",
      "then",
      "else",
      "par",
      "for",
      "join",
      "task",
      "try",
      "catch",
      "confirm",
      "true",
      "false"
    ]

isReserved :: Text -> Bool
isReserved = (`Set.member` reservedWords)

pKeyword :: Text -> Parser ()
pKeyword w = lexeme $ try $ do
  _ <- string w
  notFollowedBy identCont
  pure ()

pIdent :: Parser Ident
pIdent = lexeme $ try $ do
  c <- satisfy isIdentStart <?> "identifier"
  cs <- takeWhileP (Just "ident char") isIdentCont
  let name = T.cons c cs
  when (isReserved name) $
    fail ("reserved keyword: " <> T.unpack name)
  pure (Ident name)

pTypeName :: Parser TypeName
pTypeName = lexeme $ do
  c <- satisfy isAsciiUpper <?> "type name"
  cs <- takeWhileP (Just "type name char") isIdentCont
  pure (TypeName (T.cons c cs))

isIdentStart :: Char -> Bool
isIdentStart c = isAsciiLower c || c == '_'

isIdentCont :: Char -> Bool
isIdentCont c = isAsciiLower c || isAsciiUpper c || isDigit c || c == '_'

identCont :: Parser Char
identCont = satisfy isIdentCont

runP :: Parser a -> FilePath -> Text -> Either (ParseErrorBundle Text Void) a
runP = runPFromLine 1

-- | Like 'runP', but start numbering at @startLine@ (file-absolute fence content).
runPFromLine :: Int -> Parser a -> FilePath -> Text -> Either (ParseErrorBundle Text Void) a
runPFromLine startLine p path input =
  snd $ runParser' (scn *> p <* eof) initialState
  where
    initialState =
      State
        { stateInput = input,
          stateOffset = 0,
          statePosState =
            PosState
              { pstateInput = input,
                pstateOffset = 0,
                pstateSourcePos =
                  SourcePos path (mkPos (max 1 startLine)) (mkPos 1),
                pstateTabWidth = defaultTabWidth,
                pstateLinePrefix = ""
              },
          stateParseErrors = []
        }

bundleToDiagnostics :: FilePath -> ParseErrorBundle Text Void -> [Diagnostic]
bundleToDiagnostics path bundle =
  [toDiag e sp | (e, sp) <- NE.toList errsWithPos]
  where
    (errsWithPos, _) =
      attachSourcePos errorOffset (bundleErrors bundle) (bundlePosState bundle)
    toDiag e sp =
      mkDiagnostic
        (if null (sourceName sp) then path else sourceName sp)
        (Pos (unPos (sourceLine sp)) (unPos (sourceColumn sp)))
        (T.strip (T.pack (parseErrorTextPretty e)))
