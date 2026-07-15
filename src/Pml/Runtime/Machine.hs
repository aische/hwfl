-- | Serializable execution machine (frames + current) for durable resume.
-- Shape follows [spec/06-runtime.md](spec/06-runtime.md) / hwfi Machine ideas.
module Pml.Runtime.Machine
  ( MachineStatus (..),
    PauseReason (..),
    ConfirmRequest (..),
    Current (..),
    Frame (..),
    ParJoinState (..),
    ParSlot (..),
    ParPoolPhase (..),
    ParOnError (..),
    Machine (..),
    BranchMachine (..),
    unBranch,
    mkBranch,
    FunTable,
    initialMachine,
    machineResult,
  )
where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Pml.Ast.Expr (Arg, Expr, Field, MatchArm, Param, StringPart)
import Pml.Ast.Name (Ident)
import Pml.Eval.Value (Env, HostOpId, Value (..))
import Pml.Runtime.Error (RuntimeError)

-- | Top-level module functions (params + body), reloaded on resume.
type FunTable = Map Ident ([Param], Expr)

data MachineStatus
  = MsRunning
  | MsDraining
  | MsPaused PauseReason
  | MsCompleted
  | MsFailed
  deriving stock (Eq, Show)

data PauseReason
  = PauseExplicit
  | PauseAwaitingConfirm ConfirmRequest
  | PauseCrashRecovery
  deriving stock (Eq, Show)

data ConfirmRequest = ConfirmRequest
  { crTitle :: Text,
    crDetail :: Text,
    crBranchIndex :: Maybe Int
  }
  deriving stock (Eq, Show)

-- | What the machine is reducing right now.
data Current
  = -- | Evaluate expression under env.
    CurEval Expr Env
  | -- | Return value into the kont stack.
    CurReturn Value
  | -- | About to execute a host op (args already evaluated).
    CurHost HostOpId [(Maybe Ident, Value)]
  | -- | Blocked on human confirmation.
    CurAwaitConfirm ConfirmRequest
  | -- | Driving an active @par@ pool ('FrPar' on the frame stack).
    CurParPool
  deriving stock (Eq, Show)

data Frame
  = FrLet Ident Env Expr
  | FrAppFun Env [Arg]
  | FrAppArgs Value [(Maybe Ident, Value)] Env [Arg]
  | FrList [Value] Env [Expr]
  | FrRecord [(Ident, Value)] Env [Field]
  | FrInterp [Text] Env [StringPart]
  | FrProj Ident
  | FrIndexE Env Expr
  | FrIndexV Value
  | FrIf Env Expr Expr
  | FrMatch Env [MatchArm]
  | FrPar ParJoinState
  | -- | After approve, continue with Bool into prior kont.
    FrConfirm ConfirmRequest
  | FrJoin [Value] Env [Expr]
  deriving stock (Eq, Show)

data ParOnError
  = ParFail
  | ParCollect
  deriving stock (Eq, Show)

data ParJoinState = ParJoinState
  { pjsVar :: Ident,
    pjsBody :: Expr,
    pjsMax :: Int,
    pjsOnError :: ParOnError,
    pjsItems :: [Value],
    pjsSlots :: [ParSlot],
    pjsActive :: Map Int BranchMachine,
    pjsNextIndex :: Int,
    pjsPhase :: ParPoolPhase,
    pjsConfirmQueue :: [ConfirmRequest],
    pjsParentEnv :: Env
  }
  deriving stock (Eq, Show)

data ParSlot
  = ParSlotPending
  | ParSlotRunning
  | ParSlotDone Value
  | ParSlotFailed Text
  | ParSlotAwaitingConfirm ConfirmRequest
  deriving stock (Eq, Show)

data ParPoolPhase
  = ParScheduling
  | ParDraining
  | ParPausedConfirm
  deriving stock (Eq, Show)

data Machine = Machine
  { mStatus :: MachineStatus,
    mProjectHash :: Text,
    mCurrent :: Current,
    mFrames :: [Frame],
    mLastResult :: Maybe Value,
    mError :: Maybe RuntimeError
  }
  deriving stock (Eq, Show)

newtype BranchMachine = BranchMachine {bmMachine :: Machine}
  deriving stock (Eq, Show)

unBranch :: BranchMachine -> Machine
unBranch = (.bmMachine)

mkBranch :: Machine -> BranchMachine
mkBranch = BranchMachine

-- | Start evaluating @main@'s body after args are bound into @env@.
initialMachine :: Text -> Current -> Machine
initialMachine projectHash current =
  Machine
    { mStatus = MsRunning,
      mProjectHash = projectHash,
      mCurrent = current,
      mFrames = [],
      mLastResult = Nothing,
      mError = Nothing
    }

machineResult :: Machine -> Maybe Value
machineResult m = case m.mStatus of
  MsCompleted -> m.mLastResult
  _ -> Nothing
