---
name: megabrain
description: >-
  Use megabrain to delegate work to other coding agents and supervise them, to create Git
  worktrees that Orca and Superset.sh both see, to open agent terminals, to read agent usage
  limits and pick a provider, and to drive iOS and tvOS simulators, Android TV over adb, and
  Playwright MCP browser testing. Use when the user asks to hand work to another agent,
  parallelize across agents, spawn or supervise a worker, check on a dispatch, create or finish
  a shared worktree, choose between Codex, Claude and agy, or set up simulator or browser
  testing. Also use when a chat needs to answer a question from an agent it started.
---

# megabrain

One command surface for delegating to other coding agents and for the worktrees, terminals and
device setups that work needs. Run `megabrain <command> --help` for the exact flags of any
command; the help output is the authority, and the lines below are shortened for reading.

## Delegating work to another agent

**Start here: `megabrain orchestrate spawn --prompt <brief> [--worktree <path>]`.** When no
`--agent` is supplied, spawn asks the chain module to choose the agent, model and effort. Chains
start empty, so add one with `megabrain chain add <name> ...` first. Use `chain run` as the
explicit chain runner when you want its ordered fallback across steps and usage-window checks.

```
megabrain orchestrate spawn --repo <name|path> --branch <branch> [--agent <id>] [--chain <name>] [--model <id>] [--base <ref>] [--name <slug>] [--effort <level>] [--prompt <text>] [--label <text>] [--worktree <path>] [--tmux true|false] [--agent-arg <flag>] [--json]
```

`--chain <name>` bypasses selector matching on both commands. An explicit `--agent` wins over
chain selection and works with no chain configured. Explicit `--model` and `--effort` override
those fields when the chain supplies the agent:

```
megabrain chain run [name] [--chain <name>] [--parent-agent <agent>] [--parent-model <model>] [--parent-effort <effort>] [--repo <name|path>] [--branch <branch>] [--base <ref>] [--name <slug>] [--worktree <path>] [--prompt <text>] [--label <text>] [--tmux true|false] [--agent-arg <flag>] [--json]
```

Either way: pass `--worktree <path>` to reuse a checkout that already exists, or `--repo` plus
`--branch` to have one created.

A dispatch runs either as a tmux split or as a tab in the orchestrator that owns the session.
**tmux needs neither Orca nor Superset**: inside tmux a session identifies itself by its own
session and pane, so the whole loop works on any machine that has tmux, and the child pane is
removed outright when you close it. The orchestrators are what an IDE-tab dispatch needs, and
what shared worktrees need. `megabrain context` reports which of the three a session is in. Prompt budgets are 262144 bytes through argv and 12000 bytes
through tmux; over the limit is refused before anything is created, never truncated.

## Supervising what you started

```
megabrain orchestrate list [--all|--orphans|--uncertain] [--json]
megabrain orchestrate watch <dispatch-id> [--timeout <seconds>] [--poll-interval <seconds>] [--wait-mode nudge|poll] [--json]
megabrain orchestrate ack <dispatch-id> <delivery-id> [--json]
megabrain orchestrate reply <dispatch-id> --text <answer> [--json]
megabrain orchestrate read <dispatch-id> [--lines <count>] [--json]
megabrain orchestrate reconcile <dispatch-id> [--all] [--json]
megabrain orchestrate close <dispatch-id> [--force-release] [--json]
megabrain orchestrate prune [--older-than <days>] [--state <list>] [--archive|--delete] [--dry-run] [--json]
```

`watch` returns a delivery that **replays until acked**, so nothing is lost if you read it and
do not act. Ack it once you have acted; acking twice is safe and reports `duplicate`.

**Do not assume you will be told.** When a child runs `ask` or `done`, megabrain tries to type a
one-line pointer into the parent's terminal, but that nudge is best effort and the transport can
still fail. **The queue is the truth; the pointer is only a nudge.** If you are waiting on a
worker, run `watch` yourself rather than waiting for the pointer to arrive.

When your own turn ends, megabrain checks the dispatches you own and points at any that
have unread child mail, once per message. That is what makes a missed pointer recover
instead of being lost, and it is why a notice can appear immediately after you finish
speaking. It stays quiet for a dispatch you already have a `watch` open on.

Nothing removes a finished dispatch on its own. `prune` archives terminal ones past an
age threshold, and archives rather than deletes by default because a dispatch's message
queue is the record of what actually happened. It never touches a dispatch that is still
open, and a state it does not recognise counts as open.

Reading the dispatch record is not reading the message. A failure's `reason` field is the
symptom; the child's own message in the queue is usually the cause. Look at the messages before
concluding anything about a failed dispatch.

**Closing a finished dispatch is your job, not the child's.** When a child reports `done`, read
what it says, verify what you can, and then close it. Nothing closes it for you: the child cannot,
because it would be killing the pane it is running in, and `close` refuses that unconditionally.
A dispatch left open holds a pane and keeps appearing in `orchestrate list`.

Close after you have read the pane, not before. `orchestrate read` reads the terminal's own
scrollback, and closing destroys it: the queue keeps every message, but the transcript that shows
what the agent actually did is gone. A `done` is a claim, and the pane is where you check it.

```sh
megabrain orchestrate read <dispatch-id>    # what the agent really did
megabrain orchestrate close <dispatch-id>   # then take the pane back
```

`close` refuses to close the pane it is running in, and `--force-release` does not override that.
Close only dispatches you started, one at a time. In tmux the pane is removed outright; Superset
leaves it visible as `Desconectado` until the human dismisses it with the pane X, because no CLI
verb removes it.

## If you are the child

```
megabrain received                 optionally record that the prompt was seen
megabrain ask "question"           ask the coordinator and keep working only if told to
megabrain check [--timeout <seconds>] [--poll-interval <seconds>] [--json]
megabrain ack <delivery-id> [--json]
megabrain done "summary"           report the outcome and what you verified
```

`received` is optional and only records a durable status message; prompt delivery is already
known from the transport observation and does not depend on that command. A reply reaches you
only if you look for it. `ask` queues the question and returns; it does not block. Poll with
`check` and do not proceed on a default when the answer would change the work.
`done` is not optional: the task is not finished until the signal is sent. Sending it does not
close your pane and is not meant to: the coordinator closes you once it has read what you left
behind.

## Chains, limits and models

```
megabrain chain list [--json]
megabrain chain limits [--json] [--enable <providers>] [--disable <providers>] [--notice-on|--notice-off] [--notice-interval <seconds>]
megabrain chain add <name> --when <json> --steps <json> [--step <json>] [--allow-unknown-model] [--json]
megabrain chain edit <name> [--allow-unknown-model] [--json]
megabrain chain delete <name> [--json]
megabrain chain repair <name> --step <number> --model <id> [--effort <level>] [--json]
megabrain model list|add|refresh ...
```

A chain name is chosen by the operator. Fresh state has no chains. `orchestrate spawn` and `run`
prefer an explicit `--chain`, then the most specific matching `parentAgent`, `parentModel` and
`parentEffort` selectors, then `defaultSteps`. Equal-specificity matches fail rather than choose
arbitrarily, and an unknown parent value satisfies no selector.

`run` delegates every launch to `orchestrate spawn`; it does not duplicate runtime or terminal
creation. A limit condition may skip a step; a launch failure always advances to the next one.
An unknown limit counts as usable. Codex limits come from the newest rollout on disk; Claude and
agy are unknown stubs, so a chain that depends on their windows will always see them as usable.
New providers belong in `lib/module-chain.sh` under `megabrain_chain_limit_read`.

## Worktrees and terminals

```
megabrain worktree create --repo <name|path> --branch <branch> [--base <ref>] [--parent <branch:branch|path:path>] [--no-parent] [--name <slug>] [--json]
megabrain worktree finish <branch|path|slug> [--delete-branch] [--force] [--json]
megabrain worktree list [--repo <name|path>] [--json]
megabrain worktree adopt <path|branch> [--json]
megabrain terminal create [--worktree <path>] [--command <cmd>] [--title <text>] [--json]
megabrain terminal list [--worktree <path>] [--json]
megabrain terminal restart <selector> [--command <cmd>] [--wait-port <port>] [--timeout <seconds>] [--json]
```

`worktree create` does the git worktree add and registers the workspace so Orca and Superset both
see it from the start. `--parent` accepts the documented Orca selector subset `branch:<branch>` or
`path:<path>` and explicitly stacks the new worktree under that existing worktree; without it,
megabrain does not infer a parent. `adopt` registers the missing side of a worktree that exists on only one.
The direct parent branch becomes the Superset sidebar tag after replacing `/` with `-`, so equivalent
branch and path selectors share one folder. Orca preserves the full nested lineage; Superset has
flat folders, so siblings share their parent's folder while a grandchild is grouped by its direct
parent rather than its ancestor. JSON reports the selector, canonical parent branch and whether Orca
lineage and Superset grouping were each set; a decoration failure does not undo the checkout.
`finish` refuses an unmerged branch unless `--force` is given. `terminal create` with no
`--command` runs the worktree's `.superset/config.json` run script. Superset tabs come back
untitled; only Orca tabs carry a title. Terminal identities, commands and creation times are
recorded under `$MEGABRAIN_STATE_DIR/terminals/`, so `terminal list` can retain a host-gone
terminal as `stale`. `terminal restart` accepts `id:`, `title:`, `port:` or `worktree:` selectors,
kills only the recorded process tree after proving a port listener belongs to it, waits for the
old port to be free, and optionally waits for it to listen again with `--wait-port`.

## Setup and diagnosis

```
megabrain context [--json]           which orchestration host this session is in
megabrain doctor [module-id] [--json]
megabrain install [module-id] [--yes] [--revert]
megabrain fact list|add|edit|remove ...
```

`doctor --json` is machine readable for every module; operator advice goes to stderr so it stays
out of the JSON. Install `orchestration-hooks` to get the child turn-end safety hook, which
reports a child whose turn ended without `ask` or `done`.

## Devices and browsers

```
megabrain native appium start|stop|status
megabrain tv connect <ip> [--port <port>]
megabrain tv disconnect [<ip>]
megabrain doctor simulator-native      iOS and tvOS simulators, macOS only
megabrain doctor simulator-tv          Apple TV simulator
megabrain install simulator-web        Playwright MCP browser testing
megabrain install simulator-web --browser chromium|firefox|both
megabrain web userscript install <file.user.js>
megabrain web userscript list
megabrain web userscript remove <file.user.js>
```

`simulator-web` uses pinned Playwright 1.62.1 and keeps separate persistent Chromium and Firefox profiles under
`~/.megabrain/playwright`, with a fixed Chromium viewport and extension versions pinned at
install time. Chromium is the userscript profile. To install or refresh a script, place it in
`~/.megabrain/userscripts/` and run `megabrain web userscript install <file.user.js>`; the tool
enables Chrome's one-time userScripts permission and sends the script through Violentmonkey.
`list` reports scripts installed in the Chromium profile, and `remove` removes one from that
profile while leaving the source file available for editing. Firefox has no userscript command.

## tmux

```
megabrain tmux tune [--yes] [--dry-run] [--revert] [--json]
megabrain tmux wrapper [--yes] [--dry-run] [--revert] [--json]
```

`tune` fixes tmux colours to match the default terminal. `wrapper` installs the zsh wrapper for
hand-typed agent commands. When the `tmux-runtime` module is installed a child opens as a split
pane; otherwise it opens as a tab in the IDE that launched the session. Override per call with
`--tmux true|false`.

## Where state lives

Dispatch messages are append-only under `$MEGABRAIN_STATE_DIR/dispatches/`, which defaults to
`~/.megabrain`. Direct-parent ownership is required for `reply` and `close`.
