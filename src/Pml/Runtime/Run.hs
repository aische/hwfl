-- | Execute a loaded module's @main@ under a host environment with snapshots.
module Pml.Runtime.Run
  ( RunOptions (..),
    RunResult (..),
    runLoadedModule,
    loadRunEnv,
    parseCliInputs,
    projectHashOf,
    newRunId,
  )
where

import Data.IORef (newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (defaultTimeLocale, formatTime, getCurrentTime)
import Pml.Ast.Decl (Decl (..), ModuleBody (..))
import Pml.Ast.Module (LoadedModule (..), Section (..))
import Pml.Ast.Name (Ident (..), Slug)
import Pml.Eval.Error (EvalError (..))
import Pml.Eval.Prelude (preludeEnv)
import Pml.Eval.Value
import Pml.Llm.Provider (LlmProvider)
import Pml.Runtime.Error (RuntimeError (..), renderRuntimeError)
import Pml.Runtime.Eval (RunCtx (..), applyIO)
import Pml.Runtime.Host (HostEnv (..), hostOpsEnv)
import Pml.Runtime.Snapshot
  ( RunStatus (..),
    RunStore,
    mkBoundary,
    openRunStore,
    writeBoundarySnapshot,
  )
import Pml.Runtime.Workspace (newWorkspace, workspaceRoot)
import System.IO (hPutStrLn, stderr)

data RunOptions = RunOptions
  { roWorkspace :: FilePath,
    roProvider :: LlmProvider,
    roInputs :: [(Ident, Value)],
    roRunId :: Maybe Text
  }

data RunResult = RunResult
  { rrValue :: Value,
    rrStore :: RunStore,
    rrSeq :: Int
  }
  deriving stock (Show)

-- | Bind prelude ∪ host ops ∪ top-level funs (knot-tied).
loadRunEnv :: ModuleBody -> Either RuntimeError Env
loadRunEnv (ModuleBody decls _) =
  let funs = [(n, ps, body) | DFun n ps _ body <- decls]
      env =
        Map.union
          ( Map.fromList
              [ (n, VClosure ps body env)
                | (n, ps, body) <- funs
              ]
          )
          (Map.union hostOpsEnv preludeEnv)
   in Right env

sectionMap :: LoadedModule -> Map Slug Text
sectionMap loaded =
  Map.fromList
    [(secSlug s, secBody s) | s <- lmSections loaded]

-- | Check is caller's responsibility (CLI checks unless @--no-check@).
runLoadedModule :: RunOptions -> LoadedModule -> IO (Either RuntimeError RunResult)
runLoadedModule opts loaded = do
  ws <- newWorkspace opts.roWorkspace
  runId <- maybe newRunId pure opts.roRunId
  let hash = projectHashOf loaded
  store <- openRunStore (workspaceRoot ws) runId
  seqRef <- newIORef (0 :: Int)
  let host =
        HostEnv
          { heWorkspace = ws,
            heProvider = opts.roProvider,
            heLog = \msg -> hPutStrLn stderr (T.unpack msg)
          }
      ctx =
        RunCtx
          { rcHost = host,
            rcSections = sectionMap loaded,
            rcStore = store,
            rcProjectHash = hash,
            rcSeq = seqRef
          }
  case loadRunEnv (lmBody loaded) of
    Left e -> pure (Left e)
    Right env -> do
      hPutStrLn stderr ("pml run: run_id=" <> T.unpack runId)
      result <- callMain ctx env opts.roInputs
      seqNo <- readIORef seqRef
      case result of
        Left err -> do
          snap <- mkBoundary runId seqNo StatusFailed hash Nothing Nothing
          writeBoundarySnapshot store snap
          hPutStrLn stderr (T.unpack (renderRuntimeError err))
          pure (Left err)
        Right val -> do
          snap <- mkBoundary runId seqNo StatusCompleted hash Nothing (Just val)
          writeBoundarySnapshot store snap
          pure (Right (RunResult val store seqNo))

callMain :: RunCtx -> Env -> [(Ident, Value)] -> IO (Either RuntimeError Value)
callMain ctx env inputs = case lookupEnv (Ident "main") env of
  Nothing -> pure (Left (EvalErr (Trap "unknown function: main")))
  Just f -> do
    let arg = case inputs of
          [] -> VUnit
          _ -> VRecord inputs
    applyIO ctx f [(Nothing, arg)]

-- | Parse @k=v@ CLI inputs as strings (FileRef/String at runtime are 'VString').
parseCliInputs :: [String] -> Either RuntimeError [(Ident, Value)]
parseCliInputs = traverse parseOne
  where
    parseOne s = case break (== '=') s of
      (k, '=' : v)
        | not (null k) -> Right (Ident (T.pack k), coerceInput v)
      _ -> Left (ConfigErr ("invalid --input (expected k=v): " <> T.pack s))

coerceInput :: String -> Value
coerceInput s = case s of
  "true" -> VBool True
  "false" -> VBool False
  _
    | all (`elem` ('-' : ['0' .. '9'])) s,
      not (null s),
      s /= "-",
      Just _ <- readMaybeInt s ->
        VInt (read s)
    | otherwise -> VString (T.pack s)

readMaybeInt :: String -> Maybe Integer
readMaybeInt s = case reads s of
  [(n, "")] -> Just n
  _ -> Nothing

-- | Cheap content hash for resume staleness (M5). Not cryptographic.
projectHashOf :: LoadedModule -> Text
projectHashOf loaded =
  let payload =
        T.pack (lmPath loaded)
          <> "\n"
          <> T.pack (show (lmFrontmatter loaded))
          <> "\n"
          <> T.pack (show (lmBody loaded))
   in T.pack (show (T.foldl' (\h c -> h * 33 + fromEnum c) (0 :: Int) payload))

newRunId :: IO Text
newRunId = do
  now <- getCurrentTime
  pure ("run-" <> T.pack (formatTime defaultTimeLocale "%Y%m%d-%H%M%S" now))
