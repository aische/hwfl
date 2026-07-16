-- | Serializable execution machine (frames + current) for durable resume.
-- Shape follows [spec/06-runtime.md](spec/06-runtime.md) / hwfi Machine ideas.
module Hwfl.Runtime.Machine
  ( MachineStatus (..),
    PauseReason (..),
    ConfirmRequest (..),
    Current (..),
    Frame (..),
    ParJoinState (..),
    ParSlot (..),
    ParPoolPhase (..),
    ParOnError (..),
    AgentState (..),
    ToolRound (..),
    Machine (..),
    BranchMachine (..),
    unBranch,
    mkBranch,
    FunTable,
    initialMachine,
    machineResult,
  )
where

import Data.Aeson qualified as Aeson
import Data.Map.Strict (Map)
import Data.Text (Text)
import Hwfl.Ast.Expr (Arg, Expr, Field, MatchArm, Param, StringPart)
import Hwfl.Ast.Name (Ident)
import Hwfl.Eval.Value (Env, HostOpId, ToolSpecValue, Value (..))
import Hwfl.Llm.Types (ToolCall, ToolResult, Turn)
import Hwfl.Runtime.Error (RuntimeError)

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
  | -- | Close an @obs.span@ region then return @Value@ into the kont.
    CurCloseRegion Text Value
  | -- | @llm.agent@ multi-transition loop (model / tool rounds).
    CurAgent AgentState
  deriving stock (Eq, Show)

-- | Serializable agent loop state (spec §06 §6 / hwfi MachineAgent).
data AgentState = AgentState
  { agSystem :: Text,
    agPrompt :: Text,
    agModel :: Text,
    agMaxRounds :: Int,
    agTools :: [ToolSpecValue],
    -- | When 'Just', this is @llm.agent_object@: submit tool + typed finish.
    agSubmitSchema :: Maybe Aeson.Value,
    agHistory :: [Turn],
    agRound :: Int,
    agToolRound :: Maybe ToolRound,
    -- | Open @llm.agent@ / @llm.agent_object@ host span id (closed on finish).
    agSpanId :: Text,
    -- | Open @agent_round@ span for the current model/tool round, if any.
    agRoundSpanId :: Maybe Text
  }
  deriving stock (Eq, Show)

-- | In-progress tool round: pending calls + optional nested tool machine.
data ToolRound = ToolRound
  { trPending :: [ToolCall],
    trCompleted :: [ToolResult],
    trActiveCall :: Maybe ToolCall,
    trActiveMachine :: Maybe BranchMachine
  }
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
  | -- | After approve of @exec.run@ confirm gate: resume the stored 'Current'
    -- (usually 'CurHost' 'HostExecRun') or fail if denied.
    FrAfterConfirm Current
  | -- | One-shot: next @exec.run@ may spawn without re-confirming.
    FrExecApproved
  | -- | Open @obs.span@ region; close when value returns.
    FrRegion Text
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
