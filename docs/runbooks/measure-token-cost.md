# Measure token cost

Check how many tokens a Claude Code session uses and whether a change to b-agentic
(a skill, an agent's tools, an MCP server) made it cheaper. Estimates of savings are
not measurements: use this routine before keeping a change that was justified by one.

## Prerequisites

- b-agentic installed, so the status line is active (`./install.sh`, or
  `./install.sh --statusline-only`).
- A task you can repeat: the same prompt in the same repository.
- Optional: [`rtk`](install-prerequisites.md) for shell-output savings.

## Steps

1. Read the status line during the task. It shows context used (percent and
   tokens over the window), session cost, the prompt cache hit ratio, and the 5-hour
   and weekly limits. Cost and cache come from Claude Code's own numbers; the cache
   ratio needs Claude Code 2.1.251 or later and is missing on older versions.
2. Run `/context` for what fills the window (system prompt, tools, skills, memory,
   messages). Use it right after a fresh start: that is the fixed cost every session
   pays before your first message, and it is what a shorter skill description or a
   smaller MCP tool list reduces.
3. Run `/usage` for totals. Its Session block shows token use and a dollar figure that
   Claude Code computes locally at list price, plus a `Prompt cache (main)` line after
   the first reply. On a Pro, Max, Ultra, Team, or Enterprise plan the dollar figure is
   not your bill: read the plan usage bars and the breakdown on the same screen.
4. To judge a change, repeat the same task before and after it, each in a fresh session
   (`/clear`), and compare the fixed cost from step 2, the context tokens at the end
   of the task, and the cache hit ratio. One run is noisy: treat a gap of a few
   percent as no difference.
5. For shell output, run `rtk gain` for what `rtk` has saved so far, and
   `rtk discover -p b-agentic --since 7` for commands that ran without it.
6. Watch for the compaction hint on the status line. It appears only where a
   b-flow run is recorded (`.b-agentic/active`): at 200k tokens when a run is done or
   just approved, or from 80% of the window in any phase. Run `/compact` or `/clear`
   when it shows; the model cannot do that for you.
7. Know when Claude Code compacts by itself. A model with a native 1M window compacts
   at about 967k tokens by default, so on 1M nothing compacts for you until the window
   is nearly full. To compact sooner as a safety net, run `/autocompact 400k` (saved per model), set
   `autoCompactWindow` in settings, or set `CLAUDE_CODE_AUTO_COMPACT_WINDOW`, which
   overrides the other two; the accepted range is 100k to 1m. Claude Code's docs name
   no best size: compact at a break between tasks while the prompt cache is warm,
   because `/compact` reads the whole conversation and costs more once the cache has
   expired, and use `/clear` when the next task is unrelated.

## Verify

After step 4 you have two numbers for the same task, before and after: the context
tokens right after a fresh start (`/context`) and at the end of the task (status line).
A change saved tokens only when the fresh-start figure or the end figure is lower and
the cache hit ratio did not fall.

## Troubleshooting

- No `cache` field on the status line: Claude Code is older than 2.1.251, or no reply
  has arrived yet. Use the `Prompt cache (main)` line in `/usage` instead.
- A low cache ratio right after editing a skill, an agent, or MCP settings: that
  prefix changed, so the first request is not cached. Compare from the second task on.
- The dollar figure looks too high on a subscription: it is a list-price figure from
  local token counts, not a charge.
- No compaction hint: the repository has no `.b-agentic/active`, or the context is
  below 200k tokens and 80%.
- The status line percent does not match when compaction runs: with
  `CLAUDE_CODE_AUTO_COMPACT_WINDOW` set, `used_percentage` is still measured against the
  full window. Read the token count, not the percent, to see the distance to your limit.
