# devkit

devkit is one command surface for keeping Orca and Superset.sh aligned around Git worktrees and coding agents.
Both tools create worktrees but do not share bookkeeping: a worktree made in one is invisible to the other until it is imported by hand.
Devkit owns agent launch and uses either tmux or one host terminal primitive for the child process.

## Before and after

| Without devkit | With devkit |
| --- | --- |
| Run `git worktree add`, register the project and workspace with Superset, then import or launch through the other tool. | `devkit worktree create --repo "$PWD" --branch docs/readme` |
| `git worktree add ../docs-readme -b docs/readme` and `superset projects create --local --import "$PWD" --name "$(basename "$PWD")"` are separate bookkeeping steps. | The same command creates the Git worktree and registers the project and workspace in Superset. |

## Requirements

| Dependency | Needed for |
| --- | --- |
| Orca with `orca` on PATH | Orca status, repository discovery, and Orca terminals. |
| Superset.sh with `superset` on PATH, or `$HOME/.superset/bin/superset` | Shared worktrees, Superset workspaces, and Superset terminals. |
| Git | Creating and inspecting worktrees and branches. |
| `jq` | JSON state, metadata, and CLI responses. |
| `curl` | The installer when run from the public URL. A checkout install does not need curl. |
| `npx` | The `simulator-web` module and Playwright MCP. |
| `adb` | The `tv-adb` module and Android TV commands. |
| macOS with the Xcode Simulator, Appium, and its XCUITest driver | `simulator-native` and `simulator-tv`; these two modules are macOS-only. |

The orchestration, worktree, Android TV, and web modules are portable; their dependencies still
need to be installed where those modules are used.

## Quick start

Install from the public repository:

```sh
curl -fsSL https://raw.githubusercontent.com/oguilhermelima/devkit-local/main/install.sh | bash
```

From an Orca or Superset terminal, the first useful checks and actions are:

```sh
devkit doctor --json
devkit worktree create --repo "$PWD" --branch feature/example --json
devkit orchestrate spawn --repo "$PWD" --branch feature/agent-task --agent codex --model gpt-5 --effort medium --prompt "Inspect the repository and report findings." --json
```

Their trimmed output shapes are:

```text
[{"module":"orchestration","status":"ok","reason":"..."}, ...]
{"worktree":"...","branch":"feature/example","workspace":"...","reused":false}
{"worktree":"...","branch":"feature/agent-task","workspace":"...","dispatch":"...","reused":false,"runtime":"tmux"}
```

`orchestrate spawn` must run inside a managed Orca or Superset terminal. It creates the worktree,
registers it, starts the child agent, waits for readiness, and sends the prompt in one operation.

### Spawn runtimes

The runtime is resolved once before the worktree or terminal is created:

- `--tmux true` always selects tmux and fails if tmux is unavailable.
- `--tmux false` always selects the IDE terminal primitive.
- Without `--tmux`, an installed tmux-runtime module selects tmux; otherwise the IDE terminal primitive is selected.

IDE mode uses the issuing terminal identity: `SUPERSET_TERMINAL_ID` selects Superset and
`ORCA_TERMINAL_HANDLE` selects Orca. An unmanaged shell fails before creating anything. In IDE
mode the only host operation that starts the child is `terminals create` in Superset or
`terminal create` in Orca, with the worktree and complete devkit-built command. In tmux mode the
same host operation opens a shell in the worktree; devkit then launches the child in that pane.

The prompt is never part of the agent command line. Tmux readiness means a non-shell pane
command with rendered output. Orca uses `terminal wait --for tui-idle`; Superset polls
`terminals read` until two consecutive pane reads settle. Only a confirmed send marks
`promptDelivered` true. A readiness or send timeout leaves the dispatch failed with
`promptDelivery: "not-delivered"`.

Use repeatable `--agent-arg <value>` to append arbitrary agent flags after devkit's generated
launch, model, and effort flags. Values are passed as separate shell arguments and retain their
quoting.

### Dispatch state axes

`meta.json` keeps `state` as the coarse dispatch status and adds two independent lifecycle axes:

| Field | Values and meaning |
| --- | --- |
| `state` | `spawning`, `running`, `waiting_for_reply`, `done`, `closed`, `failed`, `orphaned`, `stalled`, `timeout`, or `circuit_broken`; the existing dispatch status. |
| `processState` | `starting`, `start-unproven`, `running`, `stopping`, `stop-unproven`, `stopped`, `succeeded`, `failed`, or `abandoned`; the child process outcome. `abandoned` ends devkit's logical authority without asserting that the process died. |
| `terminalState` | `owned`, `retained`, `missing`, or `released`; the terminal resource state. `retained` blocks release and reuse when terminal identity is unproven or the parent is gone. |

`orchestrate list` reconciles open dispatches before showing these fields. Use
`orchestrate reconcile <dispatch-id>` to reconcile one explicitly; it never respawns a child.
`orchestrate close` refuses a retained terminal unless the explicit `--force-release` flag is
provided after manual verification. `doctor` is read-only and reports uncertain dispatch and
retained terminal counts.

## How it works

```text
+-----------------------------+
| Parent terminal             |
| SUPERSET_TERMINAL_ID or    |
| ORCA_TERMINAL_HANDLE        |
+--------------+--------------+
               | devkit orchestrate spawn
               v
+-----------------------------+
| Child agent in a worktree   |
+--------------+--------------+
               |
               v
~/.devkit/dispatches/<id>/
  meta.json  cursor.json  messages/*.json
  deliveries/*.json
```

The parent session identity creates a dispatch for one child agent and worktree. Parent and child
exchange JSON messages as append-only files in the dispatch directory. Ownership is direct-parent-only:
a parent can inspect, reply to, or close its own dispatch, but ownership does not pass to a grandparent.

Messages are delivered in FIFO batches of up to 50 through a Delivery record. An outstanding Delivery is replayed with the same delivery id until it is acknowledged; there is one outstanding Delivery per mailbox. A different consumer identity or generation fences the old Delivery and receives the same unread messages under a new id. Acknowledgement is idempotent, and cursor.json is retained for compatibility but is not the source of read state.

With the optional `tmux-runtime` module enabled, devkit launches each child inside a tmux session
hosted in the IDE tab instead of the host's own agent primitive. That gives full control of the
agent command line, real splits for siblings in one tab, per-pane reads, and a close that removes
the pane. The host app then no longer treats the child as one of its agents, so features tied to
that (Superset resume/fork/handoff and its agent-attention badge) do not apply.

Child identity is pane-scoped inside tmux. When `TMUX` and `TMUX_PANE` are set, `devkit ask` and
`devkit done` match the current tmux session and pane, together with the child host; the shared
host terminal id is not used to select a child. Outside tmux, lookup remains terminal-id based.
A missing pane or an ambiguous identity is refused, and parent reads, acknowledgements, and replies
remain restricted to the dispatch's direct `parentSessionId` and `parentHost`. When a managed child
reuses an existing wrapper session, its metadata records the host terminal identity; if prior
session metadata cannot provide one, the current managed parent identity is used, with an explicit
unknown-host-terminal marker as the final fallback.

### Tmux tuning

To fix tmux colours and match the default terminal, run `devkit tmux tune`.

### Tmux agent wrapper

The tmux runtime has two fronts: devkit launches managed agents inside tmux, while the shell
wrapper opens hand-typed `claude`, `codex`, and `agy` commands there too. Install it with
`devkit tmux wrapper`; this defines shell functions with those names in every new interactive
zsh, so `DEVKIT_NO_TMUX=1` or `command claude` bypasses the wrapper when a bare command is needed.

The wrapper records its main session in `~/.devkit/sessions/<session>.json` (or the directory
selected by `DEVKIT_STATE_DIR`). The record includes the tmux session, agent, starting directory,
main pane, host, and creation time. Registration is best effort; if tmux or state storage is
unavailable, the agent runs directly. When devkit searches for a session, records for sessions
that no longer exist are ignored and pruned automatically.

When a wrapper session is reused for a managed child, the registered main pane stays on the left
half of the window. The first child opens on the right; later children are stacked vertically in
that right column, and the main pane is resized back to half after every split. Sessions without
a registered main pane keep the existing tmux split behavior.

Agents launched by devkit run without approval prompts because they are isolated in a worktree; launch the agent manually if you want approval prompts.

## Command reference

### Install and diagnostics

| Command | What it does | Notable flags |
| --- | --- | --- |
| `devkit install` | Interactively installs selected modules. | Select module numbers or `all`. |
| `devkit install orchestration` | Installs and verifies one module. | Replace the module id with any supported module. |
| `devkit doctor` | Checks every module without changing configuration. | `--json` |
| `devkit doctor simulator-web` | Checks one module. | `--json` |
| `devkit context --json` | Reports the detected host and available workspace, terminal, and agent ids. | `--json` |

Supported module ids are `orchestration`, `orchestration-hooks`, `worktree`, `simulator-web`,
`simulator-native`, `simulator-tv`, and `tv-adb`. Doctor reports `ok`, `missing`,
`misconfigured`, or `unsupported` with a reason.

### Shared worktrees

| Command | What it does | Notable flags |
| --- | --- | --- |
| `devkit worktree create --repo "$PWD" --branch feature/example` | Creates a Git worktree and its Superset project and workspace. | `--base`, `--name`, `--json` |
| `devkit worktree finish feature/example` | Removes a shared worktree and registered workspace. | `--delete-branch`, `--force`, `--json` |
| `devkit worktree list` | Lists worktrees under Superset's shared root and whether each is registered. | `--repo`, `--json` |
| `devkit worktree adopt feature/example` | Registers an existing physical worktree in Superset. | `--json` |
| `devkit terminal create --worktree "$PWD" --command "./devkit --version" --title "devkit version" --json` | Opens a terminal in the current orchestrator. | `--worktree`, `--command`, `--title`, `--json` |

`worktree create` defaults the base to the origin default branch, then Git's configured default,
then `main`. `terminal create` uses `.superset/config.json` only when `--command` is omitted.

### Orchestration

| Command | What it does | Notable flags |
| --- | --- | --- |
| `devkit orchestrate spawn --repo "$PWD" --branch feature/agent-task --agent codex --model gpt-5 --effort medium --prompt "Inspect the repository."` | Creates or reuses a worktree and launches a managed child agent. | `--base`, `--name`, `--label`, `--worktree`, `--tmux`, `--agent-arg`, `--json` |
| `devkit orchestrate list --json` | Lists dispatches owned by the current parent. | `--all`, `--orphans`, `--json` |
| `devkit orchestrate reconcile <dispatch-id> --json` | Reconciles one open dispatch without respawning it. | `--all`, `--json` |
| `devkit orchestrate watch <dispatch-id> --json` | Waits for the next child Delivery batch. | `--timeout`, `--poll-interval`, `--consumer`, `--generation`, `--json` |
| `devkit orchestrate ack <dispatch-id> <delivery-id> --json` | Acknowledges a Delivery batch. | `--consumer`, `--generation`, `--json` |
| `devkit orchestrate reply <dispatch-id> --text "Continue." --json` | Replies to a child waiting for the parent. | `--json` |
| `devkit orchestrate close <dispatch-id> --json` | Closes the child terminal and records the dispatch as closed. | `--force-release`, `--json` |
| `devkit ask "question"` | Sends a question from a child to its direct parent. | One question argument. |
| `devkit done "summary"` | Sends completion from a child to its direct parent. | One summary argument. |

`watch` reports the Delivery id, replayed flag, covered message sequences, and messages alongside
`waiting_for_reply`, `done`, `stalled`, or `timeout`. A child should use `ask` or `done` instead
of printing protocol markers.

`orchestrate spawn` selects its prompt budget from the delivery path before creating a worktree,
workspace, terminal, agent, or dispatch record. The prompt is rejected rather than truncated and
is delivered only after the child is ready.

| Delivery path | Measured capacity | Chosen prompt budget |
| --- | ---: | ---: |
| argv, including Superset terminals create and equivalent host calls | ARG_MAX 1048576 bytes; 262144-byte prompt survived intact | 262144 bytes |
| tmux send-keys | 12000 bytes executed intact; 16384 bytes hit command too long | 12000 bytes |

The tmux path is intentionally limited below 16000 bytes; write shorter briefs when tmux-runtime
is enabled.

### Native simulators

| Command | What it does | Notable flags |
| --- | --- | --- |
| `devkit native appium start` | Starts the shared Appium server on port 4723. | No flags. |
| `devkit native appium status` | Reports whether Appium is up, down, or occupying the port. | No flags. |
| `devkit native appium stop` | Stops the Appium process managed by devkit. | No flags. |

Install the prerequisites first with `devkit install simulator-native`. Apple TV uses the same
Appium/XCUITest toolchain through `simulator-tv`.

### Android TV

| Command | What it does | Notable flags |
| --- | --- | --- |
| `devkit tv connect <ip>` | Connects to an Android TV and requires adb to report it as `device`. | `--port` (default `5555`) |
| `devkit tv disconnect` | Disconnects all adb devices. | An IP argument disconnects one device. |

Check adb with `devkit doctor tv-adb`; when it is missing, `devkit install tv-adb` prints the
platform-tools command for the detected package manager.

### Web browser testing

| Command | What it does | Notable flags |
| --- | --- | --- |
| `devkit install simulator-web` | Verifies npx and registers Playwright MCP with installed agent CLIs. | No flags. |
| `devkit doctor simulator-web` | Checks npx, Playwright MCP, and agent registrations. | `--json` |

The module runs `@playwright/mcp@latest` through npx.

## Known limitations

- Closing a Superset dispatch disposes the session, but the pane remains visible as `Desconectado` until a human dismisses it with the pane X. There is no CLI verb to remove a pane; this was verified against the terminal and browser command surfaces, the local database, and app state files.
- Installing devkit's turn-end hook changes the agent hook configuration and invalidates Codex's per-entry trust. The next Codex launch shows `Hooks need review` until a human trusts it once. Opening Codex through Superset does not clear it because Superset passes `--dangerously-bypass-hook-trust`.
- Superset terminals cannot be given a title by any flag. Their pane title follows the running command; `--title` affects Orca terminals only.

## Troubleshooting

| Symptom | Cause | What to run |
| --- | --- | --- |
| `devkit doctor` says a module is `missing` | A module prerequisite is absent. | `devkit install <module-id>` |
| Codex hangs on `Hooks need review` | The hook changed Codex's trusted configuration. | Run `codex` in a plain terminal and choose `Trust all and continue`; then `devkit doctor orchestration-hooks`. |
| A dispatch never reports | The child may be stalled or has not sent a recognized message. | `devkit orchestrate watch <dispatch-id> --json` and inspect the `stalled` or `timeout` status. |
| A worktree exists in one tool but not the other | Its physical checkout is not registered in Superset. | `devkit worktree adopt <path-or-branch>` |

## Exit codes

`0` means the command completed successfully, `1` means an operational check or action failed,
and `2` means an invalid command, module id, option, or required argument was provided.

## Contributing

Contributions are welcome; keep changes focused and run the relevant checks before opening a change.

## License

MIT. See [LICENSE](LICENSE).
