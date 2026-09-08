<div align="center">

# megabrain

**Hand work to another coding agent, and get it back.**

A local orchestrator that spawns agents, keeps the conversation with them durable, and tears them
down when the work is done.

[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
![Shell](https://img.shields.io/badge/shell-bash%203.2%2B-lightgrey.svg)
![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue.svg)
![Agents](https://img.shields.io/badge/agents-codex%20%7C%20claude%20%7C%20agy-orange.svg)

[Why](#why) · [Install](#install) · [Delegate](#delegate) · [Supervise](#supervise) ·
[Examples](#examples) · [Testing](#testing) · [Limits](#limits)

</div>

## Why

Running a second agent is easy. Knowing what it did, answering its question, and cleaning it up
afterwards is where the work leaks. megabrain keeps that loop in one place, on a queue that
outlives the terminal it was typed in.

## Features

- 🧠 **Picks the provider for you.** A chain reads real usage windows and takes the first step
  with room left, reporting which it chose and why it skipped the others.
- 📬 **A queue, not a keystroke.** Every message is written before anything is typed. A lost
  pointer costs a notification, never a message.
- 🪟 **tmux on its own.** No Orca, no Superset, no IDE: inside tmux a session identifies itself by
  its own pane, and closing a child removes that pane outright.
- 🌱 **Worktrees both orchestrators can see.** One `git worktree add` registered on both sides, so
  a card and a checkout never disagree.
- 🔁 **Recoverable by design.** Deliveries replay until acknowledged, a stalled child is reported
  at its own turn end, and `reconcile` settles a dispatch against reality.
- 🧹 **Nothing accumulates.** `prune` archives finished dispatches and refuses to touch a live one.

## Install

```sh
git clone https://github.com/oguilhermelima/megabrain && cd megabrain
./install.sh --agents claude,codex,agy --skill global --agents-md global --yes
```

Absent `--modules`, the installer takes the core set: orchestration, orchestration-hooks,
worktree, and tmux-runtime when tmux is already on PATH.

```sh
megabrain doctor          # what is installed and what is missing
megabrain context --json  # tmux, orca, or superset
```

## Delegate

Start here and let megabrain choose the agent, the model and the effort.

```sh
megabrain chain run --worktree ~/code/myrepo --prompt "$(cat brief.md)" --json
```

```json
{"ok":true,"chain":"claude","step":1,"totalSteps":2,"agent":"codex",
 "reason":"no earlier steps skipped; selector match with 1 field(s)",
 "dispatch":{"dispatch":"dispatch-20260908-…","runtime":"tmux"}}
```

> [!TIP]
> Reach for `orchestrate spawn` only to name an agent and model deliberately. `chain run` is the
> one that knows which provider still has room.

## Supervise

```sh
megabrain orchestrate watch <id> --json         # blocks until there is mail
megabrain orchestrate reply <id> --text "..."   # answer a question
megabrain orchestrate ack <id> <delivery-id>    # mark it consumed
megabrain orchestrate read <id>                 # what the agent actually did
megabrain orchestrate close <id>                # take the pane back
```

> [!IMPORTANT]
> Closing a finished child is the coordinator's job. Nothing does it for you, and the child cannot:
> it would be killing the pane it runs in. Read the pane first — closing destroys the scrollback,
> and a `done` is a claim the transcript is where you check.

From inside a child, the same queue from the other side:

```sh
megabrain received              # confirm the prompt landed
megabrain ask "question"        # ask, then poll
megabrain check --timeout 120
megabrain done "what I verified"
```

## Examples

```sh
# Delegate and wait, without the pointer ever touching your composer
id=$(megabrain chain run --worktree ~/code/api --prompt "$(cat brief.md)" --json | jq -r .dispatch.dispatch)
megabrain orchestrate watch "$id" --timeout 1800 --json
```

```sh
# Two workers on disjoint checkouts
megabrain worktree create --repo api --branch feat/rate-limit --json
megabrain worktree create --repo web --branch feat/rate-limit-ui --json
megabrain chain run --worktree ~/Worktrees/feat-rate-limit --prompt "$(cat api.md)"
megabrain chain run --worktree ~/Worktrees/feat-rate-limit-ui --prompt "$(cat web.md)"
```

```sh
# Which provider still has room, before committing to one
megabrain chain limits --json | jq -r '.[] | "\(.provider) \(.window): \(.status)"'
```

```sh
# Settle everything after a machine restart, then take the space back
megabrain orchestrate reconcile --all --json
megabrain orchestrate prune --dry-run --json
megabrain orchestrate prune --older-than 7
```

```sh
# Record a measurement so the next session does not re-derive it
megabrain fact add bash-version --measurement 'macOS ships bash 3.2.57' \
  --who tester --when 2026-09-08T12:00:00Z --command 'bash --version'
```

## How it works

The queue is the product. Panes and tabs are launch and notification surfaces around it.

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

A child confirms receipt by writing to the queue. A keystroke typed into a terminal is only a
nudge that may wake a participant; the message it points at is already durable.

## Testing

```sh
for t in tests/*.sh; do bash "$t"; done   # the authority: macOS, bash 3.2
bash tests/container/run.sh               # the safety net: nothing of yours to damage
```

The container mounts the checkout read-only and copies it in, so a test cannot reach the host
tree, your tmux server or your agent configuration. It runs bash 5 on Linux, which catches
portability bugs macOS hides, but it is not the target platform, so the local run stays the
authority.

> [!WARNING]
> A run is only fully isolated with all three of `HOME`, `MEGABRAIN_STATE_DIR` and
> `MEGABRAIN_FACTS_FILE`. The state directory alone does not cover the fact store, which lives in
> the installation root. `tests/test-sandbox-isolation.sh` proves the three are enough.

## Limits

megabrain coordinates local tools. It is not a hosted service, a billing system, or a replacement
for the agent CLIs it drives.

- The live usage reader uses an undocumented endpoint and may break without notice. It reads a
  credential only for an enabled live read and never refreshes an expired one.
- Codex reasoning spellings are inferred; only `xhigh` is verified.
- The agy usage provider is not implemented and always reports its window as unknown.
- Superset leaves a closed pane visible as `Desconectado` until a human dismisses it, and a
  main-type workspace cannot be pruned from the CLI. tmux has neither limitation.
- Installing the turn-end hook changes agent hook configuration and can require trusting the next
  Codex launch once, interactively.

## Troubleshooting

`megabrain doctor <module>` names the missing prerequisite. If a dispatch goes quiet,
`megabrain orchestrate watch` reads its queue and `megabrain orchestrate reconcile` settles its
state against reality.

> [!NOTE]
> A dispatch record's `reason` is the symptom. The child's own message in the queue is usually the
> cause, so read the messages before concluding anything about a failure.

Exit codes: `0` succeeded · `1` an operational check or action failed · `2` an invalid command,
module, option or argument.

`AGENTS.md` carries every command with its full flags, and `megabrain <command> --help` is the
authority on any single one.
