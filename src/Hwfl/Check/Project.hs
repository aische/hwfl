-- | Project-wide static checking: import graph, qname validation, multi-module.
module Hwfl.Check.Project
  ( CheckProjectResult (..),
    checkProject,
    checkProjectLoaded,
    reachableModules,
    buildImportGraph,
    renderProjectCheckError,
    ProjectCheckError (..),
  )
where

import Control.Monad (foldM, forM_)
import Data.List (find)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Decl (Decl (..), ModuleBody (..))
import Hwfl.Ast.Module (Frontmatter (..), LoadedModule (..))
import Hwfl.Ast.Name (QName (..), qnameToText)
import Hwfl.Ast.Skill (SkillKind (..), SkillMeta (..))
import Hwfl.Check.Env (ModuleExport (..), TypeEnv (..))
import Hwfl.Check.Error (CheckError (..), renderCheckError)
import Hwfl.Check.Module (CheckResult (..), checkLoadedModuleInContext)
import Hwfl.Project
  ( ExecPolicy (..),
    LoadedProject (..),
    ProjectConfig (..),
    ProjectIndex (..),
    loadProject,
    modulePathForQname,
    qnameFromRelPath,
  )
import Hwfl.SkillCatalog
  ( SkillCatalog,
    buildSkillCatalog,
    isSkillQName,
    skillMetaForModule,
  )
import Hwfl.Source (Diagnostic (..), renderDiagnostics)
import System.FilePath (makeRelative, normalise)

data CheckProjectResult = CheckProjectResult
  { cprExports :: Map QName ModuleExport,
    cprChecked :: Set QName,
    cprSkillCatalog :: SkillCatalog
  }
  deriving stock (Eq, Show)

data ProjectCheckError
  = PceLoad Text
  | PceParse FilePath [Diagnostic]
  | PceModule FilePath CheckError
  | PceImportCycle [Text]
  | PceImportNotFound FilePath Text
  | PceQNameMismatch FilePath Text Text
  | PceEntryNotFound Text
  | PceSkill FilePath Text
  deriving stock (Eq, Show)

renderProjectCheckError :: ProjectCheckError -> Text
renderProjectCheckError = \case
  PceLoad msg -> msg
  PceParse path diags -> T.pack path <> ":\n" <> renderDiagnostics diags
  PceModule path err -> T.pack path <> ": " <> renderCheckError err
  PceImportCycle qs -> "cyclic import: " <> T.intercalate " -> " qs
  PceImportNotFound path q -> T.pack path <> ": import not found: " <> q
  PceQNameMismatch path fm pathQ ->
    T.pack path <> ": frontmatter name " <> fm <> " does not match file qname " <> pathQ
  PceEntryNotFound q -> "entrypoint not found: " <> q
  PceSkill path msg -> T.pack path <> ": " <> msg

checkProject :: FilePath -> IO (Either ProjectCheckError CheckProjectResult)
checkProject root = do
  result <- loadProject root
  pure $ case result of
    Left err -> Left (PceLoad err)
    Right lp -> checkProjectLoaded lp

checkProjectLoaded :: LoadedProject -> Either ProjectCheckError CheckProjectResult
checkProjectLoaded lp = do
  let cfg = lp.lpConfig
      execOk = execAllowed cfg
  forM_ (Map.toList lp.lpModules) (validateQname lp)
  reachable <- buildImportGraph lp cfg.pcEntrypoint
  order <- topoSort reachable lp
  (exports, checked0) <- foldM (checkOne cfg execOk lp) (Map.empty, Set.empty) order
  checkedSkills <- checkSkillModules cfg execOk lp exports checked0
  let checked = checked0 <> checkedSkills
      catalog = buildSkillCatalog cfg.pcSkills lp.lpModules checked
  Right
    CheckProjectResult
      { cprExports = exports,
        cprChecked = checked,
        cprSkillCatalog = catalog
      }

-- | Typecheck / validate every @skills/*@ module (even if not import-reachable).
checkSkillModules ::
  ProjectConfig ->
  Bool ->
  LoadedProject ->
  Map QName ModuleExport ->
  Set QName ->
  Either ProjectCheckError (Set QName)
checkSkillModules cfg execOk lp exports already = do
  let skills = [q | q <- Map.keys lp.lpModules, isSkillQName q, not (Set.member q already)]
  foldM go Set.empty skills
  where
    go acc q = do
      m <- maybe (Left (PceEntryNotFound (qnameToText q))) Right (Map.lookup q lp.lpModules)
      case skillKind m of
        SkillInstruction -> do
          validateInstructionSkill m
          pure (Set.insert q acc)
        SkillCallable -> do
          let importExports =
                Map.fromList
                  [ (qnameToText imp, ex)
                    | imp <- fmImports m.lmFrontmatter,
                      Just ex <- [Map.lookup imp exports]
                  ]
          _ <-
            firstModuleErr m.lmPath $
              checkLoadedModuleInContext cfg execOk importExports m
          pure (Set.insert q acc)

skillKind :: LoadedModule -> SkillKind
skillKind m = smKind (skillMetaForModule m)

validateInstructionSkill :: LoadedModule -> Either ProjectCheckError ()
validateInstructionSkill m
  | T.null (T.strip m.lmProseBody) =
      Left (PceSkill m.lmPath "instruction skill body must be non-empty")
  | not (null m.lmFrontmatter.fmInputs) || not (null m.lmFrontmatter.fmOutputs) =
      Left (PceSkill m.lmPath "instruction skill must not declare inputs/outputs")
  | otherwise = Right ()

validateQname :: LoadedProject -> (QName, LoadedModule) -> Either ProjectCheckError ()
validateQname lp (q, m) = do
  let rel = makeRelative lp.lpIndex.piRoot (normalise m.lmPath)
  case qnameFromRelPath rel of
    Nothing -> Left (PceLoad ("invalid module path: " <> T.pack m.lmPath))
    Just pathQ
      | pathQ == q && q == m.lmFrontmatter.fmName -> pure ()
      | pathQ /= q ->
          Left (PceQNameMismatch m.lmPath (qnameToText m.lmFrontmatter.fmName) (qnameToText pathQ))
      | otherwise ->
          Left
            ( PceQNameMismatch
                m.lmPath
                (qnameToText m.lmFrontmatter.fmName)
                (qnameToText q)
            )

execAllowed :: ProjectConfig -> Bool
execAllowed cfg = case cfg.pcExec of
  Nothing -> False
  Just pol -> not (null pol.execAllow)

reachableModules :: LoadedProject -> QName -> Either ProjectCheckError (Set QName)
reachableModules = buildImportGraph

buildImportGraph :: LoadedProject -> QName -> Either ProjectCheckError (Set QName)
buildImportGraph lp entry =
  if Map.member entry lp.lpModules
    then go Set.empty [entry]
    else Left (PceEntryNotFound (qnameToText entry))
  where
    go seen [] = Right seen
    go seen (q : qs)
      | Set.member q seen = go seen qs
      | otherwise = case Map.lookup q lp.lpModules of
          Nothing ->
            Left
              ( PceImportNotFound
                  (modulePathForQname lp.lpIndex.piRoot q)
                  (qnameToText q)
              )
          Just m -> go (Set.insert q seen) (fmImports m.lmFrontmatter ++ qs)

topoSort :: Set QName -> LoadedProject -> Either ProjectCheckError [QName]
topoSort nodes lp = go [] (Set.toList nodes)
  where
    go sorted [] = Right (reverse sorted)
    go sorted remaining =
      let sortedSet = Set.fromList sorted
       in case pick sortedSet remaining of
            Nothing ->
              Left (PceImportCycle (map qnameToText (findCycle remaining)))
            Just q -> go (q : sorted) (filter (/= q) remaining)
    pick sortedSet qs = find (\q -> all (`Set.member` sortedSet) (deps q)) qs
    deps q =
      [ i
        | Just m <- [Map.lookup q lp.lpModules],
          i <- fmImports m.lmFrontmatter,
          Set.member i nodes
      ]
    findCycle qs = case qs of
      q : _ -> cycleFrom q []
      [] -> []
    cycleFrom start path =
      if start `elem` path
        then reverse path ++ [start]
        else
          let nexts = deps start
           in case nexts of
                n : _ -> cycleFrom n (start : path)
                [] -> reverse (start : path)

checkOne ::
  ProjectConfig ->
  Bool ->
  LoadedProject ->
  (Map QName ModuleExport, Set QName) ->
  QName ->
  Either ProjectCheckError (Map QName ModuleExport, Set QName)
checkOne cfg execOk lp (exports, checked) q
  | Set.member q checked = Right (exports, checked)
  | otherwise = do
      m <- maybe (Left (PceEntryNotFound (qnameToText q))) Right (Map.lookup q lp.lpModules)
      -- Instruction skills have no executable body; skip typecheck if reached via imports.
      case skillKind m of
        SkillInstruction -> do
          validateInstructionSkill m
          Right (exports, Set.insert q checked)
        SkillCallable -> do
          let importExports =
                Map.fromList
                  [ (qnameToText imp, ex)
                    | imp <- fmImports m.lmFrontmatter,
                      Just ex <- [Map.lookup imp exports]
                  ]
          result <-
            firstModuleErr m.lmPath $
              checkLoadedModuleInContext cfg execOk importExports m
          let ex = moduleExportFrom (lmBody m) result
          Right (Map.insert q ex exports, Set.insert q checked)

firstModuleErr :: FilePath -> Either CheckError a -> Either ProjectCheckError a
firstModuleErr path = \case
  Left err -> Left (PceModule path err)
  Right x -> Right x

moduleExportFrom :: ModuleBody -> CheckResult -> ModuleExport
moduleExportFrom (ModuleBody decls _) result =
  ModuleExport
    { meValues =
        Map.fromList
          [ (n, ty)
            | DFun n _ _ _ <- decls,
              Just ty <- [Map.lookup n result.crEnv.teVars]
          ],
      meEffects = result.crEffects
    }
