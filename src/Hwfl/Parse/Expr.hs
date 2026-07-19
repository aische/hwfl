-- | Expression parser (grammar Expr / AppExpr / Primary).
module Hwfl.Parse.Expr
  ( expr,
    parseExprText,
  )
where

import Control.Monad (void)
import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Void (Void)
import Hwfl.Ast.Expr
import Hwfl.Ast.Name
import Hwfl.Parse.Lexer
import Hwfl.Parse.Pat (literal, pattern_, stringLit)
import Hwfl.Parse.Type (typeExpr)
import Hwfl.Source (Pos)
import Text.Megaparsec hiding (Pos)
import Text.Megaparsec.Char (char)

parseExprText :: FilePath -> Text -> Either (ParseErrorBundle Text Void) Expr
parseExprText = runP expr

-- | Stamp the current source position onto an expression.
located :: Pos -> ExprF -> Expr
located p k = Expr p k

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
      try choiceExpr,
      orExpr
    ]

-- | Infix ops elaborate to @EApp (EVar op) [lhs, rhs]@ for prelude builtins.
orExpr :: Parser Expr
orExpr = infixl1 andExpr (binApp "||" <$ symbol "||")

andExpr :: Parser Expr
andExpr = infixl1 cmpExpr (binApp "&&" <$ symbol "&&")

cmpExpr :: Parser Expr
cmpExpr = do
  l <- addExpr
  option l $ do
    op <- cmpOp
    r <- addExpr
    pure (binApp op l r)

cmpOp :: Parser Text
cmpOp =
  choice
    [ "==" <$ symbol "==",
      "!=" <$ symbol "!=",
      "<=" <$ symbol "<=",
      ">=" <$ symbol ">=",
      "<" <$ symbol "<",
      ">" <$ symbol ">"
    ]

addExpr :: Parser Expr
addExpr = infixl1 mulExpr addOp
  where
    addOp =
      choice
        [ binApp "+" <$ symbol "+",
          binApp "-" <$ symbol "-"
        ]

mulExpr :: Parser Expr
mulExpr = infixl1 appExpr mulOp
  where
    mulOp =
      choice
        [ binApp "*" <$ symbol "*",
          binApp "/" <$ symbol "/"
        ]

binApp :: Text -> Expr -> Expr -> Expr
binApp op l r =
  let opE = located l.ePos (FVar (Ident op))
   in located l.ePos (FApp opE [ArgPos l, ArgPos r])

infixl1 :: Parser Expr -> Parser (Expr -> Expr -> Expr) -> Parser Expr
infixl1 p op = do
  x <- p
  rest x
  where
    rest x =
      option x $ do
        f <- op
        y <- p
        rest (f x y)

letExpr :: Parser Expr
letExpr = do
  pos <- getPos
  pKeyword "let"
  n <- pIdent
  mt <- optional (symbol ":" *> typeExpr)
  _ <- symbol "="
  e1 <- expr
  e2 <-
    choice
      [ do
          pKeyword "in"
          expr,
        -- sequential `let` block (grammar sketch + summarise sugar)
        try letExpr,
        expr
      ]
  pure (located pos (FLet n mt e1 e2))

funExpr :: Parser Expr
funExpr = do
  pos <- getPos
  pKeyword "fun"
  ps <- paramList
  mt <- optional (symbol ":" *> typeExpr)
  _ <- (void (symbol "=>") <|> void (symbol "="))
  body <- expr
  pure (located pos (FFun ps mt body))

ifExpr :: Parser Expr
ifExpr = do
  pos <- getPos
  pKeyword "if"
  c <- expr
  pKeyword "then"
  t <- expr
  pKeyword "else"
  e <- expr
  pure (located pos (FIf c t e))

matchExpr :: Parser Expr
matchExpr = do
  pos <- getPos
  pKeyword "match"
  s <- expr
  pKeyword "with"
  arms <- some matchArm
  pure (located pos (FMatch s arms))

matchArm :: Parser MatchArm
matchArm = do
  _ <- symbol "|"
  p <- pattern_
  _ <- symbol "=>"
  MatchArm p <$> expr

parExpr :: Parser Expr
parExpr = do
  pos <- getPos
  pKeyword "par"
  opts <- option [] $ between (symbol "(") (symbol ")") (parOpt `sepBy` symbol ",")
  pKeyword "for"
  n <- pIdent
  pKeyword "in"
  xs <- expr
  body <- between (symbol "{") (symbol "}") expr
  pure (located pos (FPar opts n xs body))

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
  pos <- getPos
  pKeyword "join"
  _ <- symbol "{"
  tasks <- some task
  _ <- symbol "}"
  pure (located pos (FJoin tasks))

task :: Parser Expr
task = do
  pKeyword "task"
  between (symbol "{") (symbol "}") expr

confirmExpr :: Parser Expr
confirmExpr = do
  pos <- getPos
  pKeyword "confirm"
  e <- appExpr
  pure (located pos (FConfirm e))

choiceExpr :: Parser Expr
choiceExpr = do
  pos <- getPos
  pKeyword "choice"
  e <- appExpr
  pure (located pos (FChoice e))

tryExpr :: Parser Expr
tryExpr = do
  pos <- getPos
  pKeyword "try"
  e <- expr
  pKeyword "catch"
  _ <- symbol "("
  n <- pIdent
  _ <- symbol ")"
  _ <- symbol "=>"
  h <- expr
  pure (located pos (FTry e n h))

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
      TProj <$> (symbol "." *> pFieldIdent),
      TIndex <$> between (symbol "[") (symbol "]") expr
    ]

applyTail :: Expr -> AppTail -> Expr
applyTail e = \case
  TApp args -> located e.ePos (FApp e args)
  TProj n -> located e.ePos (FProj e n)
  TIndex i -> located e.ePos (FIndex e i)

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
    [ do
        pos <- getPos
        parts <- try interpString
        pure (located pos (FInterp parts)),
      do
        pos <- getPos
        s <- try sectionRef
        pure (located pos (FSection s)),
      try schemaExpr,
      try qnameExpr,
      do
        pos <- getPos
        n <- try pIdent
        pure (located pos (FVar n)),
      do
        pos <- getPos
        lit <- try literal
        pure (located pos (FLit lit)),
      do
        pos <- getPos
        es <- listLit
        pure (located pos (FList es)),
      do
        pos <- getPos
        fs <- recordLit
        pure (located pos (FRecord fs)),
      between (symbol "(") (symbol ")") expr
    ]

-- | @schema(T)@ — type argument, not a value application.
schemaExpr :: Parser Expr
schemaExpr = do
  pos <- getPos
  _ <- symbol "schema"
  t <- between (symbol "(") (symbol ")") typeExpr
  pure (located pos (FSchema t))

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
  pos <- getPos
  first <- pIdent
  rest <- some (symbol "/" *> pIdent)
  pure (located pos (FQName (QName (first : rest))))

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
