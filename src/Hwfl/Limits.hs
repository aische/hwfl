-- | Hard resource ceilings for untrusted module input (bug M-8).
--
-- These are fixed v0 policy constants, not author-facing config. Violations
-- become ordinary diagnostics / traps rather than process crashes or OOM.
module Hwfl.Limits
  ( maxYamlDepth,
    maxYamlNodes,
    maxParseDepth,
    maxLiteralDigits,
    maxPureEvalSteps,
    maxPureCrunchSteps,
    maxMachineFrames,
  )
where

-- | Max YAML collection / mapping nesting in frontmatter.
maxYamlDepth :: Int
maxYamlDepth = 64

-- | Max YAML nodes (scalars + collection starts) in frontmatter.
maxYamlNodes :: Int
maxYamlNodes = 10_000

-- | Max recursive-descent nesting in expression / type / pattern parsers.
maxParseDepth :: Int
maxParseDepth = 256

-- | Max decimal digits in an Int or Float literal (linear parse; rejects DoS).
maxLiteralDigits :: Int
maxLiteralDigits = 4_096

-- | Max big-step reductions in the pure evaluator.
maxPureEvalSteps :: Int
maxPureEvalSteps = 500_000

-- | Max pure CEK crunch steps per machine step (existing runtime budget).
maxPureCrunchSteps :: Int
maxPureCrunchSteps = 500_000

-- | Max CEK frame stack depth.
maxMachineFrames :: Int
maxMachineFrames = 10_000
