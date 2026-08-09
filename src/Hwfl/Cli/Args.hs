-- | CLI argv helpers: @--json@ detection, @--@ end-of-options, flag parsers.
module Hwfl.Cli.Args
  ( RunFlags (..),
    wantsJson,
    flagProviderSet,
    parseCheckFlags,
    parseRunFlags,
    parseWsRun,
    parseApprove,
    parseChoose,
    parseReply,
    parseExtend,
    parseShow,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Obs.Show (ShowMode (..), ShowOptions (..))

-- | True only when @--json@ appears as a flag token, not as a value of a
-- preceding option (e.g. @--workspace --json@).
wantsJson :: [String] -> Bool
wantsJson = scanFlags False
  where
    scanFlags found [] = found
    scanFlags True _ = True
    scanFlags False ("--" : _) = False
    scanFlags False ("--json" : rest) = scanFlags True rest
    scanFlags False (x : rest)
      | x `elem` valueTakingFlags =
          case rest of
            (_ : xs) -> scanFlags False xs
            [] -> False
      | otherwise = scanFlags False rest

-- | True when @--llm-provider@ was given as a flag (not as another flag's value).
flagProviderSet :: [String] -> Bool
flagProviderSet = scan False
  where
    scan found [] = found
    scan True _ = True
    scan False ("--" : _) = False
    scan False ("--llm-provider" : rest) = case rest of
      (_ : xs) -> scan True xs
      [] -> True
    scan False (x : rest)
      | x `elem` valueTakingFlags =
          case rest of
            (_ : xs) -> scan False xs
            [] -> False
      | otherwise = scan False rest

valueTakingFlags :: [String]
valueTakingFlags =
  [ "--workspace",
    "--input",
    "--example",
    "--llm-provider",
    "--model-catalog",
    "--filter",
    "--select",
    "--text",
    "--rounds"
  ]

data RunFlags = RunFlags
  { rfModule :: FilePath,
    rfWorkspace :: Maybe FilePath,
    rfInputs :: [String],
    -- | Named frontmatter @examples@ entry (CLI @--example@).
    rfExample :: Maybe String,
    rfProvider :: String,
    rfNoCheck :: Bool,
    rfCatalog :: FilePath,
    rfStep :: Bool,
    -- | Print span tree after the run.
    rfVerbose :: Bool,
    -- | Live span open/close on stderr (implies verbose tree dump).
    rfDebug :: Bool,
    -- | Prefix host progress lines with running LLM cost.
    rfCost :: Bool,
    -- | Dump llm-simple request/response JSON under ./dumps.
    rfDump :: Bool,
    -- | Machine-readable diagnostics on stderr for failures.
    rfJson :: Bool,
    -- | Prompt on stdin for human gates (TTY only; incompatible with --json).
    rfInteractive :: Bool
  }

parseCheckFlags :: [String] -> Either String (FilePath, Bool)
parseCheckFlags = go False Nothing False
  where
    go json mPath endOpts = \case
      [] -> case mPath of
        Just path -> Right (path, json)
        Nothing -> Left "hwfl check: missing <project|module.md>"
      ("--" : rest)
        | not endOpts -> go json mPath True rest
      ("--json" : rest)
        | not endOpts -> go True mPath False rest
      (x : rest)
        | not endOpts && looksLikeFlag x -> Left ("unknown flag: " <> x)
        | otherwise -> case mPath of
            Nothing -> go json (Just x) endOpts rest
            Just _ -> Left ("unexpected argument: " <> x)

parseRunFlags :: [String] -> Either String RunFlags
parseRunFlags args = do
  (modPath, flags) <- takeModule args emptyFlags False
  pure flags {rfModule = modPath}
  where
    emptyFlags =
      RunFlags
        { rfModule = "",
          rfWorkspace = Nothing,
          rfInputs = [],
          rfExample = Nothing,
          rfProvider = "simple",
          rfNoCheck = False,
          rfCatalog = "model-catalog.json",
          rfStep = False,
          rfVerbose = False,
          rfDebug = False,
          rfCost = False,
          rfDump = False,
          rfJson = False,
          rfInteractive = False
        }
    takeModule [] _ _ = Left "hwfl run: missing <module.md>"
    takeModule ("--" : xs) f False = takeModule xs f True
    takeModule (x : xs) f endOpts
      | not endOpts,
        Just cont <- runFlag x xs f takeModule =
          cont
      | not endOpts && looksLikeFlag x = Left ("unknown flag: " <> x)
      | otherwise = consumeOpts xs f {rfModule = x} False
    consumeOpts [] f _ = Right (f.rfModule, f)
    consumeOpts ("--" : xs) f False = consumeOpts xs f True
    consumeOpts (x : xs) f endOpts
      | not endOpts,
        Just cont <- runFlag x xs f consumeOpts =
          cont
      | otherwise = Left ("unexpected argument: " <> x)

-- | Shared @run@ option table used before and after the module path.
runFlag ::
  String ->
  [String] ->
  RunFlags ->
  ([String] -> RunFlags -> Bool -> Either String a) ->
  Maybe (Either String a)
runFlag x xs f cont = case x of
  "--workspace" -> Just $ case xs of
    (d : rest) -> cont rest f {rfWorkspace = Just d} False
    [] -> Left "--workspace needs a directory"
  "--input" -> Just $ case xs of
    (kv : rest) -> cont rest f {rfInputs = f.rfInputs ++ [kv]} False
    [] -> Left "--input needs k=v"
  "--example" -> Just $ case xs of
    (name : rest) -> cont rest f {rfExample = Just name} False
    [] -> Left "--example needs a name"
  "--llm-provider" -> Just $ case xs of
    (p : rest) -> cont rest f {rfProvider = p} False
    [] -> Left "--llm-provider needs a name"
  "--model-catalog" -> Just $ case xs of
    (c : rest) -> cont rest f {rfCatalog = c} False
    [] -> Left "--model-catalog needs a path"
  "--no-check" -> Just (cont xs f {rfNoCheck = True} False)
  "--step" -> Just (cont xs f {rfStep = True} False)
  "-v" -> Just (cont xs f {rfVerbose = True} False)
  "--verbose" -> Just (cont xs f {rfVerbose = True} False)
  "--debug" -> Just (cont xs f {rfDebug = True, rfVerbose = True} False)
  "--cost" -> Just (cont xs f {rfCost = True} False)
  "--dump" -> Just (cont xs f {rfDump = True} False)
  "--json" -> Just (cont xs f {rfJson = True} False)
  "--interactive" -> Just (cont xs f {rfInteractive = True} False)
  _ -> Nothing

parseWsRun :: [String] -> Either String (FilePath, Text, String, FilePath, Bool)
parseWsRun = go Nothing Nothing "simple" "model-catalog.json" False False
  where
    go mWs mId prov catalog dump endOpts = \case
      [] -> case (mWs, mId) of
        (Just ws, Just rid) -> Right (ws, rid, prov, catalog, dump)
        _ -> Left "usage: hwfl step|resume <workspace> <run-id> [options]"
      ("--" : rest)
        | not endOpts -> go mWs mId prov catalog dump True rest
      ("--llm-provider" : p : rest)
        | not endOpts -> go mWs mId p catalog dump False rest
      ("--model-catalog" : c : rest)
        | not endOpts -> go mWs mId prov c dump False rest
      ("--dump" : rest)
        | not endOpts -> go mWs mId prov catalog True False rest
      (x : rest)
        | not endOpts && looksLikeFlag x -> Left ("unknown flag: " <> x)
        | otherwise -> case (mWs, mId) of
            (Nothing, _) -> go (Just x) mId prov catalog dump endOpts rest
            (Just _, Nothing) -> go mWs (Just (T.pack x)) prov catalog dump endOpts rest
            _ -> Left ("unexpected argument: " <> x)

parseApprove :: [String] -> Either String (FilePath, Text, Bool, String, FilePath, Bool)
parseApprove = go Nothing Nothing Nothing "simple" "model-catalog.json" False False
  where
    go mWs mId mYes prov catalog dump endOpts = \case
      [] -> case (mWs, mId, mYes) of
        (Just ws, Just rid, Just yes) -> Right (ws, rid, yes, prov, catalog, dump)
        (_, _, Nothing) -> Left "hwfl approve needs --yes or --no"
        _ -> Left "usage: hwfl approve <workspace> <run-id> --yes|--no"
      ("--" : rest)
        | not endOpts -> go mWs mId mYes prov catalog dump True rest
      ("--yes" : rest)
        | not endOpts -> go mWs mId (Just True) prov catalog dump False rest
      ("--no" : rest)
        | not endOpts -> go mWs mId (Just False) prov catalog dump False rest
      ("--llm-provider" : p : rest)
        | not endOpts -> go mWs mId mYes p catalog dump False rest
      ("--model-catalog" : c : rest)
        | not endOpts -> go mWs mId mYes prov c dump False rest
      ("--dump" : rest)
        | not endOpts -> go mWs mId mYes prov catalog True False rest
      (x : rest)
        | not endOpts && looksLikeFlag x -> Left ("unknown flag: " <> x)
        | otherwise -> case (mWs, mId) of
            (Nothing, _) -> go (Just x) mId mYes prov catalog dump endOpts rest
            (Just _, Nothing) -> go mWs (Just (T.pack x)) mYes prov catalog dump endOpts rest
            _ -> Left ("unexpected argument: " <> x)

parseChoose :: [String] -> Either String (FilePath, Text, Text, String, FilePath, Bool)
parseChoose = go Nothing Nothing Nothing "simple" "model-catalog.json" False False
  where
    go mWs mId mSel prov catalog dump endOpts = \case
      [] -> case (mWs, mId, mSel) of
        (Just ws, Just rid, Just sel) -> Right (ws, rid, sel, prov, catalog, dump)
        (_, _, Nothing) -> Left "hwfl choose needs --select <option>"
        _ -> Left "usage: hwfl choose <workspace> <run-id> --select <option>"
      ("--" : rest)
        | not endOpts -> go mWs mId mSel prov catalog dump True rest
      ("--select" : s : rest)
        | not endOpts -> go mWs mId (Just (T.pack s)) prov catalog dump False rest
      ("--llm-provider" : p : rest)
        | not endOpts -> go mWs mId mSel p catalog dump False rest
      ("--model-catalog" : c : rest)
        | not endOpts -> go mWs mId mSel prov c dump False rest
      ("--dump" : rest)
        | not endOpts -> go mWs mId mSel prov catalog True False rest
      (x : rest)
        | not endOpts && looksLikeFlag x -> Left ("unknown flag: " <> x)
        | otherwise -> case (mWs, mId) of
            (Nothing, _) -> go (Just x) mId mSel prov catalog dump endOpts rest
            (Just _, Nothing) -> go mWs (Just (T.pack x)) mSel prov catalog dump endOpts rest
            _ -> Left ("unexpected argument: " <> x)

parseReply :: [String] -> Either String (FilePath, Text, Text, String, FilePath, Bool)
parseReply = go Nothing Nothing Nothing "simple" "model-catalog.json" False False
  where
    go mWs mId mText prov catalog dump endOpts = \case
      [] -> case (mWs, mId, mText) of
        (Just ws, Just rid, Just text) -> Right (ws, rid, text, prov, catalog, dump)
        (_, _, Nothing) -> Left "hwfl reply needs --text <string>"
        _ -> Left "usage: hwfl reply <workspace> <run-id> --text <string>"
      ("--" : rest)
        | not endOpts -> go mWs mId mText prov catalog dump True rest
      ("--text" : text : rest)
        | not endOpts -> go mWs mId (Just (T.pack text)) prov catalog dump False rest
      ("--llm-provider" : p : rest)
        | not endOpts -> go mWs mId mText p catalog dump False rest
      ("--model-catalog" : c : rest)
        | not endOpts -> go mWs mId mText prov c dump False rest
      ("--dump" : rest)
        | not endOpts -> go mWs mId mText prov catalog True False rest
      (x : rest)
        | not endOpts && looksLikeFlag x -> Left ("unknown flag: " <> x)
        | otherwise -> case (mWs, mId) of
            (Nothing, _) -> go (Just x) mId mText prov catalog dump endOpts rest
            (Just _, Nothing) -> go mWs (Just (T.pack x)) mText prov catalog dump endOpts rest
            _ -> Left ("unexpected argument: " <> x)

parseExtend :: [String] -> Either String (FilePath, Text, Int, String, FilePath, Bool)
parseExtend = go Nothing Nothing Nothing "simple" "model-catalog.json" False False
  where
    go mWs mId mRounds prov catalog dump endOpts = \case
      [] -> case (mWs, mId, mRounds) of
        (Just ws, Just rid, Just n) -> Right (ws, rid, n, prov, catalog, dump)
        (_, _, Nothing) -> Left "hwfl extend needs --rounds N"
        _ -> Left "usage: hwfl extend <workspace> <run-id> --rounds N"
      ("--" : rest)
        | not endOpts -> go mWs mId mRounds prov catalog dump True rest
      ("--rounds" : n : rest)
        | not endOpts -> case reads n of
            [(i, "")] | i > 0 -> go mWs mId (Just i) prov catalog dump False rest
            _ -> Left ("--rounds must be a positive integer, got: " <> n)
      ("--llm-provider" : p : rest)
        | not endOpts -> go mWs mId mRounds p catalog dump False rest
      ("--model-catalog" : c : rest)
        | not endOpts -> go mWs mId mRounds prov c dump False rest
      ("--dump" : rest)
        | not endOpts -> go mWs mId mRounds prov catalog True False rest
      (x : rest)
        | not endOpts && looksLikeFlag x -> Left ("unknown flag: " <> x)
        | otherwise -> case (mWs, mId) of
            (Nothing, _) -> go (Just x) mId mRounds prov catalog dump endOpts rest
            (Just _, Nothing) -> go mWs (Just (T.pack x)) mRounds prov catalog dump endOpts rest
            _ -> Left ("unexpected argument: " <> x)

parseShow :: [String] -> Either String ShowOptions
parseShow = go Nothing Nothing ShowSummary Nothing False
  where
    go mWs mId mode filt endOpts = \case
      [] -> case (mWs, mId) of
        (Just ws, Just rid) ->
          Right
            ShowOptions
              { soWorkspace = ws,
                soRunId = rid,
                soMode = mode,
                soFilter = filt
              }
        _ -> Left "usage: hwfl show <workspace> <run-id> [--tree|--spans|--snapshot] [--filter PREFIX]"
      ("--" : rest)
        | not endOpts -> go mWs mId mode filt True rest
      ("--tree" : rest)
        | not endOpts -> go mWs mId ShowTree filt False rest
      ("--spans" : rest)
        | not endOpts -> go mWs mId ShowSpans filt False rest
      ("--snapshot" : rest)
        | not endOpts -> go mWs mId ShowSnapshot filt False rest
      ("--filter" : p : rest)
        | not endOpts -> go mWs mId mode (Just (T.pack p)) False rest
      (x : rest)
        | not endOpts && looksLikeFlag x -> Left ("unknown flag: " <> x)
        | otherwise -> case (mWs, mId) of
            (Nothing, _) -> go (Just x) mId mode filt endOpts rest
            (Just _, Nothing) -> go mWs (Just (T.pack x)) mode filt endOpts rest
            _ -> Left ("unexpected argument: " <> x)

looksLikeFlag :: String -> Bool
looksLikeFlag x = "-" `T.isPrefixOf` T.pack x
