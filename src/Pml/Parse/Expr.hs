-- | Expression parser (grammar Expr / AppExpr / Primary).
module Pml.Parse.Expr
  ( expr,
    parseExprText,
  )
where

import Control.Monad (void)
import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Pml.Ast.Expr
import Pml.Ast.Name
import Pml.Parse.Lexer
import Pml.Parse.Pat (literal, pattern_, stringLit)
import Pml.Parse.Type (typeExpr)
import Text.Megaparsec
import Text.Megaparsec.Char (char)

parseExprText :: FilePath -> Text -> Either (ParseErrorBundle Text Void) Expr
parseExprText = runP expr

expr :: Parser Expr
expr =
  choice
    [ try letExpr,
      try funExpr,
      try ifExpr,
      try matchExpr,
      try parExpr,
      try joinExpr,
      try tryExpr,
      try confirmExpr,
      appExpr
    ]

letExpr :: Parser Expr
letExpr = do
  pKeyword "let"
  n <- pIdent
  mt <- optional (symbol ":" *> typeExpr)
  _ <- symbol "="
  e1 <- expr
  choice
    [ do
        pKeyword "in"
        ELet n mt e1 <$> expr,
      -- sequential `let` block (grammar sketch + summarise sugar)
      try (ELet n mt e1 <$> letExpr),
      ELet n mt e1 <$> expr
    ]

funExpr :: Parser Expr
funExpr = do
  pKeyword "fun"
  ps <- paramList
  mt <- optional (symbol ":" *> typeExpr)
  _ <- (void (symbol "=>") <|> void (symbol "="))
  EFun ps mt <$> expr

ifExpr :: Parser Expr
ifExpr = do
  pKeyword "if"
  c <- expr
  pKeyword "then"
  t <- expr
  pKeyword "else"
  EIf c t <$> expr

matchExpr :: Parser Expr
matchExpr = do
  pKeyword "match"
  s <- expr
  pKeyword "with"
  arms <- some matchArm
  pure (EMatch s arms)

matchArm :: Parser MatchArm
matchArm = do
  _ <- symbol "|"
  p <- pattern_
  _ <- symbol "=>"
  MatchArm p <$> expr

parExpr :: Parser Expr
parExpr = do
  pKeyword "par"
  opts <- option [] $ between (symbol "(") (symbol ")") (parOpt `sepBy` symbol ",")
  pKeyword "for"
  n <- pIdent
  pKeyword "in"
  xs <- expr
  body <- between (symbol "{") (symbol "}") expr
  pure (EPar opts n xs body)

parOpt :: Parser ParOpt
parOpt =
  choice
    [ do
        void (symbol "max")
        _ <- symbol "="
        ParMax <$> nat,
      do
        void (symbol "on_error")
        _ <- symbol "="
        ParOnError <$> stringLit
    ]

joinExpr :: Parser Expr
joinExpr = do
  pKeyword "join"
  _ <- symbol "{"
  tasks <- some task
  _ <- symbol "}"
  pure (EJoin tasks)

task :: Parser Expr
task = do
  pKeyword "task"
  between (symbol "{") (symbol "}") expr

confirmExpr :: Parser Expr
confirmExpr = do
  pKeyword "confirm"
  EConfirm <$> appExpr

tryExpr :: Parser Expr
tryExpr = do
  pKeyword "try"
  e <- expr
  pKeyword "catch"
  _ <- symbol "("
  n <- pIdent
  _ <- symbol ")"
  _ <- symbol "=>"
  ETry e n <$> expr

appExpr :: Parser Expr
appExpr = do
  base <- primary
  tails <- many appTail
  pure (foldl applyTail base tails)

data AppTail
  = TApp [Arg]
  | TProj Ident
  | TIndex Expr

appTail :: Parser AppTail
appTail =
  choice
    [ TApp <$> between (symbol "(") (symbol ")") (arg `sepBy` symbol ","),
      TProj <$> (symbol "." *> pIdent),
      TIndex <$> between (symbol "[") (symbol "]") expr
    ]

applyTail :: Expr -> AppTail -> Expr
applyTail e = \case
  TApp args -> EApp e args
  TProj n -> EProj e n
  TIndex i -> EIndex e i

arg :: Parser Arg
arg =
  choice
    [ try $ do
        n <- pIdent
        _ <- symbol "="
        ArgNamed n <$> expr,
      ArgPos <$> expr
    ]

primary :: Parser Expr
primary =
  choice
    [ EInterp <$> try interpString,
      ESection <$> try sectionRef,
      try qnameExpr,
      EVar <$> try pIdent,
      ELit <$> try literal,
      EList <$> listLit,
      ERecord <$> recordLit,
      between (symbol "(") (symbol ")") expr
    ]

sectionRef :: Parser Slug
sectionRef = lexeme $ do
  _ <- char '@'
  c <- satisfy (\x -> isIdentStart x || x == '-')
  cs <- takeWhileP (Just "slug") (\x -> isIdentCont x || x == '-')
  pure (Slug (T.cons c cs))
  where
    isIdentStart x = x >= 'a' && x <= 'z' || x == '_'
    isIdentCont x = isIdentStart x || x >= 'A' && x <= 'Z' || isDigit x

qnameExpr :: Parser Expr
qnameExpr = do
  first <- pIdent
  rest <- some (symbol "/" *> pIdent)
  pure (EQName (QName (first : rest)))

listLit :: Parser [Expr]
listLit = between (symbol "[") (symbol "]") (expr `sepBy` symbol ",")

recordLit :: Parser [Field]
recordLit = between (symbol "{") (symbol "}") (field `sepBy` symbol ",")

field :: Parser Field
field = do
  n <- pIdent
  choice
    [ do
        _ <- symbol "="
        Field n <$> expr,
      pure (FieldShorthand n)
    ]

paramList :: Parser [Param]
paramList = between (symbol "(") (symbol ")") (param `sepBy` symbol ",")

param :: Parser Param
param = do
  n <- pIdent
  mt <- optional (symbol ":" *> typeExpr)
  pure (Param n mt)

nat :: Parser Integer
nat = lexeme $ do
  ds <- takeWhile1P (Just "digit") isDigit
  pure (read (T.unpack ds))

interpString :: Parser [StringPart]
interpString = lexeme $ do
  _ <- char '$'
  _ <- char '"'
  parts <- manyTill interpPart (char '"')
  pure (mergeLits parts)

interpPart :: Parser StringPart
interpPart =
  choice
    [ do
        _ <- char '{'
        e <- expr
        _ <- char '}'
        pure (SInterp e),
      SLit . T.singleton <$> (char '\\' *> interpEscape),
      SLit . T.pack <$> some (satisfy (\c -> c /= '"' && c /= '\\' && c /= '{'))
    ]

interpEscape :: Parser Char
interpEscape =
  choice
    [ '"' <$ char '"',
      '\\' <$ char '\\',
      '{' <$ char '{',
      '\n' <$ char 'n',
      '\t' <$ char 't'
    ]

mergeLits :: [StringPart] -> [StringPart]
mergeLits = go
  where
    go (SLit a : SLit b : rest) = go (SLit (a <> b) : rest)
    go (x : xs) = x : go xs
    go [] = []
