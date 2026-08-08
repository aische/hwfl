-- | Megaparsec lexer for the kernel language (spec §02 lexical).
module Hwfl.Parse.Lexer
  ( Parser,
    scn,
    lexeme,
    symbol,
    reservedWords,
    isReserved,
    pIdent,
    pFieldIdent,
    pTypeName,
    pKeyword,
    getPos,
    nest,
    parseDecimalInteger,
    parseFloatLiteral,
    runP,
    runPFromLine,
    bundleToDiagnostics,
  )
where

import Control.Monad (when)
import Control.Monad.Trans.State.Strict (StateT, evalStateT, get, put)
import Data.Char (digitToInt, isAsciiLower, isAsciiUpper, isDigit)
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Read qualified as TR
import Data.Void (Void)
import Hwfl.Ast.Name (Ident (..), TypeName (..))
import Hwfl.Limits (maxLiteralDigits, maxParseDepth)
import Hwfl.Source (Diagnostic (..), Pos (Pos), mkDiagnostic)
import Hwfl.Source qualified as Src
import Text.Megaparsec hiding (Pos)
import Text.Megaparsec.Char (space1, string)
import Text.Megaparsec.Char.Lexer qualified as L

-- | Parser with a nesting-depth counter for M-8 recursion caps.
type Parser = StateT Int (Parsec Void Text)

-- | Current megaparsec source position as a 1-based 'Hwfl.Source.Pos'.
getPos :: Parser Src.Pos
getPos = do
  sp <- getSourcePos
  pure (Pos (unPos (sourceLine sp)) (unPos (sourceColumn sp)))

-- | Run a nested parser under the parse-depth ceiling.
nest :: Parser a -> Parser a
nest p = do
  d <- get
  when (d >= maxParseDepth) $
    fail ("nesting exceeds " <> show maxParseDepth)
  put (d + 1)
  r <- p
  put d
  pure r

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
      "choice",
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

-- | Field / projection name: same shape as 'pIdent' but allows reserved words
-- so @human.confirm@ / @human.choice@ parse.
pFieldIdent :: Parser Ident
pFieldIdent = lexeme $ try $ do
  c <- satisfy isIdentStart <?> "field name"
  cs <- takeWhileP (Just "ident char") isIdentCont
  pure (Ident (T.cons c cs))

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

-- | Linear decimal 'Integer' parse with a digit-length ceiling.
parseDecimalInteger :: Text -> Parser Integer
parseDecimalInteger ds
  | T.length ds > maxLiteralDigits =
      fail ("integer literal exceeds " <> show maxLiteralDigits <> " digits")
  | otherwise = pure (T.foldl' (\n c -> n * 10 + toInteger (digitToInt c)) 0 ds)

-- | Linear 'Double' parse; rejects oversized digit runs and non-finite values.
parseFloatLiteral :: Text -> Text -> Parser Double
parseFloatLiteral a b
  | T.length a + T.length b > maxLiteralDigits =
      fail ("float literal exceeds " <> show maxLiteralDigits <> " digits")
  | otherwise = case TR.double (a <> "." <> b) of
      Right (d, leftover)
        | not (T.null leftover) -> fail "invalid float literal"
        | isInfinite d || isNaN d ->
            fail "float literal is not a finite Float"
        | otherwise -> pure d
      Left _ -> fail "invalid float literal"

runP :: Parser a -> FilePath -> Text -> Either (ParseErrorBundle Text Void) a
runP = runPFromLine 1

-- | Like 'runP', but start numbering at @startLine@ (file-absolute fence content).
runPFromLine :: Int -> Parser a -> FilePath -> Text -> Either (ParseErrorBundle Text Void) a
runPFromLine startLine p path input =
  snd $ runParser' (evalStateT (scn *> p <* eof) 0) initialState
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
