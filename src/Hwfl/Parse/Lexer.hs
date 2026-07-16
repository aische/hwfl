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
    runP,
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
import Hwfl.Source (Diagnostic (..), Pos (..), mkDiagnostic)
import Text.Megaparsec
import Text.Megaparsec.Char (space1, string)
import Text.Megaparsec.Char.Lexer qualified as L

type Parser = Parsec Void Text

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
runP p path = parse (scn *> p <* eof) path

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
