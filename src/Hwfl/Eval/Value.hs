-- | Runtime values for the pure evaluator (spec §02 §3).
module Hwfl.Eval.Value
  ( Value (..),
    ToolSpecValue (..),
    Env,
    emptyEnv,
    lookupEnv,
    extendEnv,
    extendEnvMany,
    Builtin (..),
    HostOpId (..),
    hostOpName,
    finiteFloat,
    renderValue,
  )
where

import Data.Aeson qualified as Aeson
import Data.Foldable (foldl')
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Expr (Expr, Param)
import Hwfl.Ast.Name (Ident (..), QName (..), TypeName (..), qnameToText)
import Hwfl.Llm.Types (Turn)

-- | Environment: identifier → value.
type Env = Map Ident Value

emptyEnv :: Env
emptyEnv = Map.empty

lookupEnv :: Ident -> Env -> Maybe Value
lookupEnv = Map.lookup

extendEnv :: Ident -> Value -> Env -> Env
extendEnv = Map.insert

extendEnvMany :: [(Ident, Value)] -> Env -> Env
extendEnvMany bs e = foldl' (\acc (k, v) -> Map.insert k v acc) e bs

-- | Construct a Float runtime value only when it has a representation in the
-- language's JSON and snapshot formats.
finiteFloat :: Text -> Double -> Either Text Value
finiteFloat context d
  | isNaN d || isInfinite d = Left (context <> " produced a non-finite Float")
  | otherwise = Right (VFloat d)

data Builtin
  = BAdd
  | BSub
  | BMul
  | BDiv
  | BEq
  | BNeq
  | BLt
  | BLe
  | BGt
  | BGe
  | BAnd
  | BOr
  | BNot
  | -- | Wrap a typed callable as an agent 'ToolSpecValue'.
    BTool
  | BListLength
  | BListConcat
  | BTextMetrics
  | BTextSimilarity
  | BTextContains
  | BTextSplitSentences
  | BTextWords
  | BTextStripSuffix
  | BTextTrim
  | BTextStartsWith
  | BTextNormalizeToken
  | BTextIsQname
  | BMdSections
  | BJsonEncode
  | BIntToFloat
  | BFloatTrunc
  | BFloatFloor
  | BFloatCeil
  | BFloatRound
  deriving stock (Eq, Show, Read)

-- | Host operation identity (runtime only). Typed stubs stay in Check.Prelude;
-- this is the eval/runtime mirror, not a second API surface.
data HostOpId
  = HostFsRead
  | HostFsWrite
  | HostFsFind
  | HostFsList
  | HostFsEdit
  | HostFsPatch
  | HostFsGrep
  | HostFsReadSlice
  | HostFsRemove
  | HostFsMkdir
  | HostFsCopy
  | HostFsMove
  | HostFsExists
  | HostFsStat
  | HostExecRun
  | HostLlmChat
  | HostLlmChatMessages
  | HostLlmObject
  | HostLlmAgent
  | HostLlmAgentObject
  | HostHumanConfirm
  | HostHumanChoice
  | HostHumanAsk
  | HostObsLog
  | HostObsSpan
  | HostMetaCheckModule
  | HostMetaCheckProject
  | HostMetaInvoke
  | HostMetaListRuns
  | HostMetaReadSpans
  | HostMetaReadSnapshot
  | HostSkillDiscover
  | HostSkillLoad
  | HostMcpCall
  | HostMcpTools
  deriving stock (Eq, Ord, Show)

-- | Runtime tool advertisement: schema + callable (host op / fun / closure).
data ToolSpecValue = ToolSpecValue
  { tvsName :: Text,
    tvsDescription :: Text,
    tvsParameters :: Aeson.Value,
    tvsCallee :: Value
  }
  deriving stock (Eq, Show)

data Value
  = VUnit
  | VBool Bool
  | VInt Integer
  | VFloat Double
  | VString Text
  | VList [Value]
  | -- | Field order preserved for display; equality is by name.
    VRecord [(Ident, Value)]
  | VVariant TypeName (Maybe Value)
  | -- | Opaque secret payload; redacted in spans / snapshots / show.
    VSecret Value
  | -- | Closure over parameter names and body (local @fun@ / lambdas).
    VClosure [Param] Expr Env
  | -- | Top-level module function by name (avoids cyclic env in snapshots).
    VTopFun Ident
  | -- | Library export (@lib/foo.bar@ / @hwfl/list.map@): module qname + fun
    -- name. Resolved via 'RunCtx' library fun tables (no knot-tied closure env).
    VLibFun QName Ident
  | VBuiltin Builtin
  | -- | Host op callable (fs.read, llm.chat, …). Only the runtime driver applies these.
    VHostOp HostOpId
  | -- | Agent tool spec from @tool(f)@.
    VToolSpec ToolSpecValue
  | -- | Skill module @main@ resolved via 'RunCtx' skill tables.
    VSkillMain QName
  | -- | Imported entry module callable as @qname(inputs)@ → callee @main@.
    VEntryMain QName
  | -- | Reflected JSON Schema from @schema(T)@ (check-time type @Schema@).
    VSchema Aeson.Value
  | -- | Agent transcript turn (@TurnUser@ / @TurnAssistant@ / @TurnTool@).
    VTurn Turn
  | -- | One MCP tool bound via @mcp.tools@: server id, tool name, and the
    -- @bind@ record captured as JSON for merging into @tools/call@
    -- arguments. Only meaningful as a 'ToolSpecValue' callee in an agent's
    -- tool list — the agent loop dispatches it directly (spec §13 §6), it
    -- is never applied like a 'VHostOp' / 'VClosure'.
    VMcpTool Text Text Aeson.Value
  deriving stock (Eq, Show)

-- | Text rendering for string interpolation (hwfi §3.2.1 / types §3.1 subset).
-- Closures and builtins are not renderable (trap at eval).
renderValue :: Value -> Either Text Text
renderValue = \case
  VUnit -> Right "()"
  VBool True -> Right "true"
  VBool False -> Right "false"
  VInt n -> Right (T.pack (show n))
  VFloat d -> renderFloat d
  VString t -> Right t
  VList xs -> do
    parts <- traverse renderJsonish xs
    pure ("[" <> T.intercalate "," parts <> "]")
  VRecord fs -> do
    parts <- traverse (\(Ident k, v) -> ((k <> ":") <>) <$> renderJsonish v) (sortFields fs)
    pure ("{" <> T.intercalate "," parts <> "}")
  VVariant (TypeName t) Nothing -> Right t
  VVariant (TypeName t) (Just v) -> do
    inner <- renderJsonish v
    pure (t <> "(" <> inner <> ")")
  VSecret {} -> Left "cannot render a Secret as text"
  VClosure {} -> Left "cannot render a closure as text"
  VTopFun (Ident n) -> Left ("cannot render top-level fun as text: " <> n)
  VLibFun q (Ident n) ->
    Left ("cannot render library fun as text: " <> qnameToText q <> "." <> n)
  VBuiltin {} -> Left "cannot render a builtin as text"
  VHostOp op -> Left ("cannot render host op as text: " <> hostOpName op)
  VToolSpec ts -> Left ("cannot render tool spec as text: " <> ts.tvsName)
  VSkillMain q -> Left ("cannot render skill main as text: " <> T.intercalate "/" (map unIdent (qnParts q)))
  VEntryMain q -> Left ("cannot render entry main as text: " <> T.intercalate "/" (map unIdent (qnParts q)))
  VSchema {} -> Left "cannot render a Schema as text"
  VTurn {} -> Left "cannot render a Turn as text"
  VMcpTool server name _ -> Left ("cannot render mcp tool as text: " <> server <> "/" <> name)

-- | Stable dotted name for spans / snapshots.
hostOpName :: HostOpId -> Text
hostOpName = \case
  HostFsRead -> "fs.read"
  HostFsWrite -> "fs.write"
  HostFsFind -> "fs.find"
  HostFsList -> "fs.list"
  HostFsEdit -> "fs.edit"
  HostFsPatch -> "fs.patch"
  HostFsGrep -> "fs.grep"
  HostFsReadSlice -> "fs.read_slice"
  HostFsRemove -> "fs.remove"
  HostFsMkdir -> "fs.mkdir"
  HostFsCopy -> "fs.copy"
  HostFsMove -> "fs.move"
  HostFsExists -> "fs.exists"
  HostFsStat -> "fs.stat"
  HostExecRun -> "exec.run"
  HostLlmChat -> "llm.chat"
  HostLlmChatMessages -> "llm.chat_messages"
  HostLlmObject -> "llm.object"
  HostLlmAgent -> "llm.agent"
  HostLlmAgentObject -> "llm.agent_object"
  HostHumanConfirm -> "human.confirm"
  HostHumanChoice -> "human.choice"
  HostHumanAsk -> "human.ask"
  HostObsLog -> "obs.log"
  HostObsSpan -> "obs.span"
  HostMetaCheckModule -> "meta.check_module"
  HostMetaCheckProject -> "meta.check_project"
  HostMetaInvoke -> "meta.invoke"
  HostMetaListRuns -> "meta.list_runs"
  HostMetaReadSpans -> "meta.read_spans"
  HostMetaReadSnapshot -> "meta.read_snapshot"
  HostSkillDiscover -> "skill.discover"
  HostSkillLoad -> "skill.load"
  HostMcpCall -> "mcp.call"
  HostMcpTools -> "mcp.tools"

renderJsonish :: Value -> Either Text Text
renderJsonish = \case
  VString t -> Right (T.pack (show t)) -- quoted
  v -> renderValue v

renderFloat :: Double -> Either Text Text
renderFloat d
  | isNaN d || isInfinite d = Left "cannot render a non-finite Float"
  | d == fromIntegral r = Right (T.pack (show r))
  | otherwise = Right (T.pack (show d))
  where
    r = round d :: Integer

sortFields :: [(Ident, Value)] -> [(Ident, Value)]
sortFields = Map.toList . Map.fromList
