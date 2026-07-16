-- | Pattern parser (grammar Pattern).
module Hwfl.Parse.Pat
  ( pattern_,
    literal,
    stringLit,
  )
where

import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..))
import Hwfl.Ast.Pat
import Hwfl.Parse.Lexer
import Text.Megaparsec
import Text.Megaparsec.Char (char, string)

pattern_ :: Parser Pattern
pattern_ =
  choice
    [ PWild <$ symbol "_",
      try tagPat,
      try recordPat,
      try listPat,
      PLit <$> try literal,
      PVar <$> pIdent
    ]

tagPat :: Parser Pattern
tagPat = do
  n <- pTypeName
  payload <- optional (between (symbol "(") (symbol ")") pattern_)
  pure (PTag n payload)

recordPat :: Parser Pattern
recordPat = do
  _ <- symbol "{"
  fs <- fieldPat `sepBy` symbol ","
  _ <- symbol "}"
  pure (PRecord fs)

fieldPat :: Parser (Ident, Pattern)
fieldPat = do
  n <- pIdent
  _ <- symbol "="
  p <- pattern_
  pure (n, p)

listPat :: Parser Pattern
listPat = do
  _ <- symbol "["
  ps <- pattern_ `sepBy` symbol ","
  _ <- symbol "]"
  pure (PList ps)

literal :: Parser Literal
literal =
  choice
    [ LUnit <$ symbol "()",
      LBool True <$ pKeyword "true",
      LBool False <$ pKeyword "false",
      try floatLit,
      intLit,
      LString <$> stringLit
    ]

intLit :: Parser Literal
intLit = lexeme $ do
  sign <- option 1 ((-1) <$ char '-')
  ds <- takeWhile1P (Just "digit") isDigit
  pure (LInt (sign * read (T.unpack ds)))

floatLit :: Parser Literal
floatLit = lexeme $ do
  sign <- option id ((negate) <$ char '-')
  a <- takeWhile1P (Just "digit") isDigit
  _ <- char '.'
  b <- takeWhile1P (Just "digit") isDigit
  pure (LFloat (sign (read (T.unpack (a <> "." <> b)))))

stringLit :: Parser Text
stringLit =
  lexeme $
    choice
      [ try tripleString,
        doubleString
      ]

tripleString :: Parser Text
tripleString = do
  _ <- string "\"\"\""
  chars <- manyTill charLiteral (string "\"\"\"")
  pure (T.pack chars)
  where
    charLiteral = satisfy (/= '"') <|> (char '"' <* notFollowedBy (string "\"\""))

doubleString :: Parser Text
doubleString = do
  _ <- char '"'
  chars <- manyTill stringChar (char '"')
  pure (T.pack chars)

stringChar :: Parser Char
stringChar =
  (char '\\' *> escape)
    <|> satisfy (\c -> c /= '"' && c /= '\\')

escape :: Parser Char
escape =
  choice
    [ '"' <$ char '"',
      '\\' <$ char '\\',
      '\n' <$ char 'n',
      '\t' <$ char 't',
      '\r' <$ char 'r'
    ]
