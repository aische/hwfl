-- | Gitignore-style path filtering for workspace walks (@fs.find@ / @fs.grep@).
--
-- Respects workspace-root @.gitignore@ and @.ignore@ even when @.git@ is
-- absent. When neither file exists (or both are empty), applies a small
-- baseline of dependency / build directory names. Hidden names (@.*@) are
-- always skipped. Nested ignore files are not loaded (v1).
module Hwfl.Runtime.Ignore
  ( IgnoreSet,
    loadIgnoreSet,
    isIgnored,
    baselineIgnoreText,
  )
where

import Control.Exception (IOException, try)
import Data.Char (isSpace)
import Data.List (foldl', isPrefixOf, isSuffixOf)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import System.FilePath
  ( normalise,
    splitDirectories,
    takeFileName,
    (</>),
  )

-- | Compiled ignore rules for one workspace root.
data IgnoreSet = IgnoreSet
  { igRules :: [Rule]
  }
  deriving stock (Eq, Show)

data Rule = Rule
  { rNegate :: Bool,
    rDirOnly :: Bool,
    -- | Pattern is matched only from the workspace root (contains @\/@ or
    -- started with @\/@).
    rAnchored :: Bool,
    rPattern :: String
  }
  deriving stock (Eq, Show)

-- | Built-in patterns used when the workspace has no usable ignore file.
-- Slash-terminated entries match directories only.
baselineIgnoreText :: Text
baselineIgnoreText =
  T.unlines
    [ "# hwfl baseline (no .gitignore / .ignore in workspace)",
      "node_modules/",
      "dist/",
      "dist-newstyle/",
      "target/",
      "__pycache__/",
      ".venv/",
      "venv/",
      ".stack-work/",
      "bower_components/",
      "vendor/",
      "*.pyc",
      "*.pyo",
      ".DS_Store"
    ]

-- | Load root @.gitignore@ + @.ignore@. Falls back to 'baselineIgnoreText'
-- when both are missing or yield no rules.
loadIgnoreSet :: FilePath -> IO IgnoreSet
loadIgnoreSet root = do
  gi <- readMaybe (root </> ".gitignore")
  ig <- readMaybe (root </> ".ignore")
  let combined = T.intercalate "\n" (mapMaybe id [gi, ig])
      parsed = parseIgnoreText combined
  pure $
    IgnoreSet
      { igRules =
          if null parsed
            then parseIgnoreText baselineIgnoreText
            else parsed
      }
  where
    readMaybe path = do
      r <- try (TIO.readFile path) :: IO (Either IOException Text)
      pure $ case r of
        Left _ -> Nothing
        Right t -> Just t

parseIgnoreText :: Text -> [Rule]
parseIgnoreText = mapMaybe parseLine . T.lines

parseLine :: Text -> Maybe Rule
parseLine raw0 =
  let raw1 = T.dropWhileEnd isSpace raw0
      raw = T.unpack raw1
   in if null raw || "#" `isPrefixOf` raw
        then Nothing
        else
          let (neg, rest0) = case raw of
                ('!' : xs) -> (True, xs)
                xs -> (False, xs)
              (dirOnly, rest1) =
                if "/" `isSuffixOf` rest0 && rest0 /= "/"
                  then (True, init rest0)
                  else (False, rest0)
              (anchored, pat) = case rest1 of
                ('/' : xs) -> (True, xs)
                xs
                  | '/' `elem` xs -> (True, xs)
                  | otherwise -> (False, xs)
           in if null pat
                then Nothing
                else
                  Just
                    Rule
                      { rNegate = neg,
                        rDirOnly = dirOnly,
                        rAnchored = anchored,
                        rPattern = pat
                      }

-- | @True@ when @rel@ (workspace-relative, @\/@-separated or native) should be
-- omitted from find/grep. @isDir@ distinguishes directory-only rules.
isIgnored :: IgnoreSet -> FilePath -> Bool -> Bool
isIgnored _ig rel _isDir
  | isHiddenSegment rel = True
isIgnored ig rel isDir =
  let path = normaliseRel rel
      decision =
        foldl'
          ( \acc rule ->
              if ruleMatches rule path isDir
                then Just (not (rNegate rule)) -- negate ⇒ keep (not ignored)
                else acc
          )
          Nothing
          (igRules ig)
   in case decision of
        Just ignored -> ignored
        Nothing -> False

isHiddenSegment :: FilePath -> Bool
isHiddenSegment rel =
  let segs = filter (not . null) (splitDirectories (normaliseRel rel))
   in any isHiddenName segs

isHiddenName :: FilePath -> Bool
isHiddenName name =
  case name of
    ('.' : rest) | not (null rest) -> True
    _ -> False

normaliseRel :: FilePath -> FilePath
normaliseRel = dropWhile (== '/') . map slash . normalise
  where
    slash '\\' = '/'
    slash c = c

ruleMatches :: Rule -> FilePath -> Bool -> Bool
ruleMatches rule path isDir
  | rDirOnly rule && not isDir = False
  | rAnchored rule = anchoredMatch (rPattern rule) path
  | otherwise = unanchoredMatch (rPattern rule) path

-- | Pattern relative to workspace root (@src\/*.ts@, @dist@, @foo\/bar@).
anchoredMatch :: String -> FilePath -> Bool
anchoredMatch pat path =
  let patN = normaliseRel pat
      pathN = normaliseRel path
   in pathN == patN
        || (patN ++ "/") `isPrefixOf` (pathN ++ "/")
        || globMatch patN pathN

-- | Pattern without @\/@ matches any path segment or basename glob.
unanchoredMatch :: String -> FilePath -> Bool
unanchoredMatch pat path
  | '*' `elem` pat || '?' `elem` pat =
      globMatch pat (takeFileName path)
  | otherwise =
      let segs = splitDirectories (normaliseRel path)
       in pat `elem` segs

-- | Minimal glob: @*@ (any run), @?@ (one char); no character classes.
globMatch :: String -> String -> Bool
globMatch = go
  where
    go [] [] = True
    go ('*' : ps) xs = any (go ps) (tails xs)
    go ('?' : ps) (_ : xs) = go ps xs
    go (p : ps) (x : xs) | p == x = go ps xs
    go _ _ = False
    tails [] = [[]]
    tails ys@(_ : zs) = ys : tails zs
