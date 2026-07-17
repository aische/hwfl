-- | Shared skill discover/load result construction (skills-plan §5).
module Hwfl.Runtime.Skills
  ( discoverSkillsResult,
    loadSkillScripted,
    skillEntryDiscoverValue,
    loadSkillResultRecord,
    instructionInjectionText,
    agentLoadSkill,
    AgentSkillLoad (..),
  )
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Hwfl.Ast.Name (Ident (..), QName (..), qnameFromParts, qnameToText)
import Hwfl.Ast.Skill (SkillKind (..), skillKindText)
import Hwfl.Eval.Value (Value (..))
import Hwfl.SkillCatalog
  ( SkillCatalog (..),
    SkillEntry (..),
    SkillPolicy (..),
    discoverSkills,
    lookupSkillEntry,
  )

-- | Mutation produced by an in-agent @skill.load@ (applied by the agent loop).
data AgentSkillLoad = AgentSkillLoad
  { aslResult :: Value,
    -- | Newly loaded callable skill id (to advertise), if any.
    aslNewCallable :: Maybe QName,
    -- | Newly loaded instruction injection text, if any.
    aslNewInjection :: Maybe Text,
    aslLoadedInstructionIds :: [Text],
    aslLoadedCallableIds :: [Text],
    aslInstructionChars :: Int
  }
  deriving stock (Eq, Show)

discoverSkillsResult :: SkillCatalog -> Text -> [Text] -> Int -> Value
discoverSkillsResult cat query kinds limit =
  let entries = discoverSkills cat query kinds limit
   in record
        [ ("ok", VBool True),
          ("skills", VList (map skillEntryDiscoverValue entries)),
          ("error", VString "")
        ]

skillEntryDiscoverValue :: SkillEntry -> Value
skillEntryDiscoverValue e =
  record
    [ ("id", VString (qnameToText (seId e))),
      ("kind", VString (skillKindText (seKind e))),
      ("summary", VString (seSummary e)),
      ("tags", VList (map VString (seTags e))),
      ("checked", VBool (seChecked e)),
      ("agent_eligible", VBool (seAgentEligible e))
    ]

-- | Outside-agent @skill.load@: instruction returns body; callable is metadata-only.
loadSkillScripted :: SkillCatalog -> Text -> Value
loadSkillScripted cat skillId =
  case lookupSkillById cat skillId of
    Nothing ->
      loadSkillResultRecord False "" False "" ("unknown skill id '" <> skillId <> "'")
    Just e ->
      case seKind e of
        SkillInstruction ->
          loadSkillResultRecord
            True
            (skillKindText SkillInstruction)
            True
            (fromMaybe "" (seBody e))
            ""
        SkillCallable ->
          -- Interim shape (skills-plan §13): ok + empty content; no global tool install.
          loadSkillResultRecord True (skillKindText SkillCallable) False "" ""

loadSkillResultRecord :: Bool -> Text -> Bool -> Text -> Text -> Value
loadSkillResultRecord ok kind isLoaded content err =
  record
    [ ("ok", VBool ok),
      ("kind", VString kind),
      ("loaded", VBool isLoaded),
      ("content", VString content),
      ("error", VString err)
    ]

lookupSkillById :: SkillCatalog -> Text -> Maybe SkillEntry
lookupSkillById cat skillId = lookupSkillEntry (qnameFromText skillId) cat

qnameFromText :: Text -> QName
qnameFromText t = qnameFromParts (T.splitOn "/" t)

instructionInjectionText :: Text -> Text -> Text
instructionInjectionText skillId body =
  "## Loaded skill: " <> skillId <> "\n\n" <> body

-- | In-agent load: may expand tool set / instruction context; recoverable on failure.
agentLoadSkill ::
  SkillCatalog ->
  [Text] ->
  [Text] ->
  Int ->
  Text ->
  AgentSkillLoad
agentLoadSkill cat loadedInstr loadedCall instrChars skillId =
  case lookupSkillById cat skillId of
    Nothing ->
      noMut (loadSkillResultRecord False "" False "" ("unknown skill id '" <> skillId <> "'"))
    Just e ->
      case seKind e of
        SkillInstruction -> loadInstruction cat loadedInstr loadedCall instrChars e skillId
        SkillCallable -> loadCallable cat loadedInstr loadedCall instrChars e skillId
  where
    noMut v =
      AgentSkillLoad
        { aslResult = v,
          aslNewCallable = Nothing,
          aslNewInjection = Nothing,
          aslLoadedInstructionIds = loadedInstr,
          aslLoadedCallableIds = loadedCall,
          aslInstructionChars = instrChars
        }

loadInstruction ::
  SkillCatalog ->
  [Text] ->
  [Text] ->
  Int ->
  SkillEntry ->
  Text ->
  AgentSkillLoad
loadInstruction cat loadedInstr loadedCall instrChars e skillId =
  let policy = scPolicy cat
      body = fromMaybe "" (seBody e)
   in if skillId `elem` loadedInstr
        then
          AgentSkillLoad
            { aslResult =
                loadSkillResultRecord True (skillKindText SkillInstruction) False body "",
              aslNewCallable = Nothing,
              aslNewInjection = Nothing,
              aslLoadedInstructionIds = loadedInstr,
              aslLoadedCallableIds = loadedCall,
              aslInstructionChars = instrChars
            }
        else
          if length loadedInstr >= spMaxInstructionLoads policy
            then
              noMut loadedInstr loadedCall instrChars $
                loadSkillResultRecord False (skillKindText SkillInstruction) False "" "instruction load cap exceeded"
            else
              let newChars = instrChars + T.length body
               in if newChars > spMaxInstructionChars policy
                    then
                      noMut loadedInstr loadedCall instrChars $
                        loadSkillResultRecord
                          False
                          (skillKindText SkillInstruction)
                          False
                          ""
                          "instruction body exceeds max_instruction_chars"
                    else
                      let injection = instructionInjectionText skillId body
                       in AgentSkillLoad
                            { aslResult =
                                loadSkillResultRecord True (skillKindText SkillInstruction) True body "",
                              aslNewCallable = Nothing,
                              aslNewInjection = Just injection,
                              aslLoadedInstructionIds = loadedInstr ++ [skillId],
                              aslLoadedCallableIds = loadedCall,
                              aslInstructionChars = newChars
                            }
  where
    noMut li lc ic v =
      AgentSkillLoad
        { aslResult = v,
          aslNewCallable = Nothing,
          aslNewInjection = Nothing,
          aslLoadedInstructionIds = li,
          aslLoadedCallableIds = lc,
          aslInstructionChars = ic
        }

loadCallable ::
  SkillCatalog ->
  [Text] ->
  [Text] ->
  Int ->
  SkillEntry ->
  Text ->
  AgentSkillLoad
loadCallable cat loadedInstr loadedCall instrChars e skillId =
  let policy = scPolicy cat
      q = seId e
   in if skillId `elem` loadedCall
        then
          AgentSkillLoad
            { aslResult = loadSkillResultRecord True (skillKindText SkillCallable) False "" "",
              aslNewCallable = Nothing,
              aslNewInjection = Nothing,
              aslLoadedInstructionIds = loadedInstr,
              aslLoadedCallableIds = loadedCall,
              aslInstructionChars = instrChars
            }
        else
          if not (seChecked e)
            then
              failLoad "callable skill failed hwfl check"
            else
              if not (seAgentEligible e)
                then
                  failLoad "callable skill is not agent-eligible"
                else
                  if length loadedCall >= spMaxCallableLoads policy
                    then
                      failLoad "callable load cap exceeded"
                    else
                      AgentSkillLoad
                        { aslResult =
                            loadSkillResultRecord True (skillKindText SkillCallable) True "" "",
                          aslNewCallable = Just q,
                          aslNewInjection = Nothing,
                          aslLoadedInstructionIds = loadedInstr,
                          aslLoadedCallableIds = loadedCall ++ [skillId],
                          aslInstructionChars = instrChars
                        }
  where
    failLoad err =
      AgentSkillLoad
        { aslResult = loadSkillResultRecord False (skillKindText SkillCallable) False "" err,
          aslNewCallable = Nothing,
          aslNewInjection = Nothing,
          aslLoadedInstructionIds = loadedInstr,
          aslLoadedCallableIds = loadedCall,
          aslInstructionChars = instrChars
        }

record :: [(Text, Value)] -> Value
record pairs = VRecord [(Ident k, v) | (k, v) <- pairs]
