# megabrain

megabrain is a local coordination layer for coding agents. It hands work to another agent, keeps
the conversation with it durable, and keeps the worktree, terminal and dispatch state connected,
so several pieces of work stay trackable after a terminal disappears or a provider runs out.

It is for developers who run more than one agent at a time and need the work to remain
recoverable rather than remembered.

## Core flow

The queue is the product. Terminals and panes are launch and notification surfaces around it.

```text
Parent --spawn--> tmux split or IDE tab --starts--> Child
  |                                                   |
  | parent messages                                   | receipt + child messages
  v                                                   v
  +------------------------> DURABLE QUEUE <----------+
                                  |              |
                                  | child reads  | parent reads
                                  v              v
                                Child          Parent

terminal keystroke ---------------------> nudge only
```

A child confirms receipt by writing to the queue. Messages travel both ways through it, and a
keystroke typed into a terminal is only a nudge that may wake a participant.

> [!IMPORTANT]
> The queue is the truth and the pointer is only a nudge. A notice can be lost to a closed pane
> or a busy composer; the message it points at cannot. When you are waiting on a worker, run
> `megabrain orchestrate watch` rather than waiting to be told.

## Quick start

```sh
./install.sh --agents claude,codex,agy --skill global --agents-md global --yes
megabrain doctor
megabrain context --json
```

Absent `--modules`, the installer selects the core set: orchestration, orchestration-hooks,
worktree, and tmux-runtime when tmux is already on PATH.

## Delegating work

Start with `chain run` and let megabrain choose. A chain is an ordered list of steps, and it picks
the first whose usage window still has room, reporting which step it chose and why the earlier
ones were skipped.

```sh
megabrain chain run --worktree /path/to/checkout --prompt "$(cat brief.txt)" --json
```

Reach for `orchestrate spawn` only to name a specific agent and model deliberately. Then supervise
what you started:

```sh
megabrain orchestrate watch <dispatch-id> --json   # blocks until there is mail
megabrain orchestrate reply <dispatch-id> --text "answer"
megabrain orchestrate ack <dispatch-id> <delivery-id>
megabrain orchestrate close <dispatch-id>
```

From inside a child, `megabrain ask`, `megabrain check` and `megabrain done` are the other half of
the same queue.

> [!NOTE]
> A delivery replays until it is acknowledged, so reading one and not acting on it loses nothing.
> When your own turn ends, megabrain also points at any dispatch of yours holding unread mail,
> once per message, which is what makes a missed nudge recover instead of disappear.

## Capabilities

| Capability | What it solves | Commands |
| --- | --- | --- |
| Delegation | Pick a provider from real usage windows | `megabrain chain run` |
| Orchestration | Durable parent and child delivery | `megabrain orchestrate ...`, `ask`, `check`, `done` |
| Housekeeping | Archive finished dispatches | `megabrain orchestrate prune` |
| Model registry | Valid model and reasoning choices | `megabrain model ...` |
| Usage limits | Skip an exhausted provider window | `megabrain chain limits` |
| Shared worktrees | One checkout both orchestrators can see | `megabrain worktree ...` |
| Runtimes | A tmux split or an IDE tab | `megabrain orchestrate spawn --tmux` |
| Tmux setup | Predictable colours and a shell wrapper | `megabrain tmux tune`, `megabrain tmux wrapper` |
| Devices | Appium and Android TV | `megabrain native appium ...`, `megabrain tv ...` |
| Browser testing | Playwright MCP prerequisites | `megabrain install simulator-web` |
| Environment facts | Dated, scoped measurements | `megabrain fact ...` |

`AGENTS.md` carries every command with its full flags. `megabrain <command> --help` is the
authority on any single one.

## Requirements

- Git, jq and bash.
- tmux for the tmux runtime.
- Orca or Superset.sh, with its CLI, for shared worktrees and IDE-tab dispatches.
- npx for browser testing, adb for Android TV.
- macOS with the Xcode Simulator, Appium and the XCUITest driver for the iOS and tvOS modules.

Each module checks its own prerequisites; `megabrain doctor` reports what is missing and why.

## Testing

```sh
for t in tests/*.sh; do bash "$t"; done   # the authority: macOS bash 3.2
bash tests/container/run.sh               # the safety net: no host state to damage
```

The container mounts the checkout read-only and copies it in, so a test cannot reach the host
tree, the operator's tmux server or their agent configuration. It runs bash 5 on Linux, which is
useful for portability but is not the target platform, so the local run stays the authority.

> [!WARNING]
> A megabrain run is only fully isolated with all three of `HOME`, `MEGABRAIN_STATE_DIR` and
> `MEGABRAIN_FACTS_FILE`. The state directory alone does not cover the fact store, which lives in
> the installation root. `tests/test-sandbox-isolation.sh` proves the three are enough.

## Honest limits

megabrain coordinates local tools. It is not a hosted agent service, a billing system, or a
replacement for the agent CLIs and orchestrators it connects.

- The live usage reader uses an undocumented endpoint and may break without notice. It reads a
  credential only for an enabled live read and never refreshes an expired one.
- Codex reasoning spellings are inferred from available configuration; only `xhigh` is verified.
- The agy usage provider is not implemented and always reports its window as unknown.
- Closing a Superset dispatch leaves a `Desconectado` pane visible until a human dismisses it, and
  a main-type Superset workspace cannot be pruned from the CLI.
- Installing the turn-end hook changes agent hook configuration and can require trusting the next
  Codex launch once, interactively, in a plain terminal.

## Troubleshooting

Start with `megabrain doctor <module>`; it names the missing prerequisite. If a dispatch goes
quiet, `megabrain orchestrate watch` reads its queue and `megabrain orchestrate reconcile` settles
its state against reality.

> [!NOTE]
> A dispatch record's `reason` field is the symptom. The child's own message in the queue is
> usually the cause, so read the messages before concluding anything about a failed dispatch.

Exit codes: `0` succeeded, `1` an operational check or action failed, `2` an invalid command,
module, option or argument.
