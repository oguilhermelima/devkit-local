# megabrain

megabrain is one command surface for keeping Orca and Superset.sh aligned around Git worktrees and coding agents.
Both tools create worktrees but do not share bookkeeping: a worktree made in one is invisible to the other until it is imported by hand.
Devkit owns agent launch and uses either tmux or one host terminal primitive for the child process.

## Before and after

| Without megabrain | With megabrain |
| --- | --- |
| Run `git worktree add`, register the project and workspace with Superset, then import or launch through the other tool. | `megabrain worktree create --repo "$PWD" --branch docs/readme` |
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
megabrain doctor --json
megabrain worktree create --repo "$PWD" --branch feature/example --json
megabrain orchestrate spawn --repo "$PWD" --branch feature/agent-task --agent codex --model gpt-5 --effort medium --prompt "Inspect the repository and report findings." --json
```

The command is now megabrain. mb is a short alias, and devkit remains a deprecated compatibility
alias for at least two release cycles so existing scripts can migrate without interruption. The
old DEVKIT_STATE_DIR variable remains accepted with a deprecation notice; use MEGABRAIN_STATE_DIR
for new installations.

Migrate an existing live state directory after installing the new command:

```sh
megabrain migrate
```

The migration copies ~/.devkit to ~/.megabrain, verifies the complete copy, and removes the old
directory only after verification. It is safe to run again.

The GitHub repository remains oguilhermelima/devkit-local for this transition. The repository must
be renamed by the user in GitHub when they are ready; the command and runtime do not depend on the
remote repository name.

Their trimmed output shapes are:

```text
[{"module":"orchestration","status":"ok","reason":"..."}, ...]
{"worktree":"...","branch":"feature/example","workspace":"...","reused":false}
{"worktree":"...","branch":"feature/agent-task","workspace":"...","dispatch":"...","reused":false,"runtime":"tmux"}
```

`orchestrate spawn` must run inside a managed Orca or Superset terminal. It creates the worktree,
registers it, starts the child agent, and sends the prompt in one operation. The child first
publishes a durable received message; spawn marks the prompt delivered only after that message is
delivered and acknowledged.

### Model registry

The supported model registry is versioned in `.megabrain/models.json` and copied to the active
state directory on first use. Every entry records its agent, exact model identifier, supported
reasoning levels, and provenance. A live entry records the command that produced it; curated
codex and claude entries record manual curation and their observation date.

Inspect and maintain the registry with:

```sh
megabrain model list [--json]
megabrain model refresh agy
megabrain model add <agent> <model> --reasoning low,medium,high
```

Only agy has a live listing command, so `model refresh agy` runs `agy models` and replaces the agy
entries with a new timestamp. Codex and claude remain visibly curated because neither provider
offers a model-listing command. For agy, reasoning is encoded in the model identifier; the
registry therefore records that it is not a separate axis.

### Agent chains

`megabrain chain` stores ordered fallback agents in `$MEGABRAIN_STATE_DIR/chains.json` (by default
`~/.megabrain/chains.json`). A chain name is the parent agent it applies to; it is not the child
agent that the chain launches. The first use seeds exactly the `claude`, `codex`, and `agy`
parent-agent chains. Their selectors contain only `parentAgent`; selectors may also use
`parentModel` and `parentEffort` in user-created chains.

List and manage chains with JSON definitions:

```sh
megabrain chain list [--json]
megabrain chain add <name> --when '{"parentAgent":"codex"}' \
  --steps '[{"agent":"agy","model":"gemini-3.1-pro-high","effort":"high"}]' [--json]
megabrain chain edit <name> [--json]
megabrain chain delete <name> [--json]
megabrain chain repair <name> --step <number> --model <id> --effort <level>
```

`add` and `edit` validate the complete configuration before replacing the file. Steps require a
known agent (`codex`, `claude`, or `agy`), a registered model for that agent, and a reasoning level
that model supports. When present, an `until` object must contain `usedPercent` and `window` (`5h`
or `weekly`). `edit` opens a temporary copy with `$EDITOR` and leaves the real file untouched when
validation fails or the editor makes no change.

To use a provider model before the registry has been refreshed, pass
`--allow-unknown-model`. The resulting step is marked `unvalidated: true` so the exception remains
visible. Existing configuration is never rewritten automatically. Loading an old configuration
reports each chain, step, and unknown value; repair each step explicitly with `chain repair`.

Run a chain with the same launch options as `orchestrate spawn`:

```sh
megabrain chain run [name] --parent-agent codex --repo "$PWD" --branch feature/child \
  --prompt "Inspect the task" [--json]
```

An explicit name wins. Without one, the most-specific matching selector wins; an equally specific
tie is an error. Missing parent model or effort values do not satisfy a requirement. If no chain
matches, `defaultSteps` is selected and the report says so. Every report identifies the selected
chain, step position, and reasons earlier steps were skipped; the same decision is saved in the
dispatch `chain` object in `meta.json`.

Limits are checked before launch. The codex provider reads the newest rollout snapshot under
`~/.codex/sessions` and supports the 5-hour and weekly windows. A snapshot whose reset has passed
is stale and becomes unknown. Claude and agy can read live usage only when explicitly enabled in
`usageLimits.liveProviders`; the seeded configuration leaves this list empty. Use
`megabrain chain limits --enable claude,agy` to opt in, or `--disable claude,agy` to turn it back off.
Unknown is usable and never counts as exhausted. A launch failure is always a valid reason to
advance to the next step.

`megabrain chain limits [--json]` prints both windows for every provider with status, source, fetched
time, reset time, and reason. Codex uses source `disk`; successful live reads use `live`, and a
successful read within the 30-second cache TTL uses `cache`. The normalized in-memory shape is an
object with `provider`, `fetchedAt`, and `windows`; each window has `name`, `bucket`,
`usedPercent`, `remainingPercent`, and `resetsAt`. The short TTL keeps a chain run responsive while
ensuring old numbers are refreshed.

The live readers are unsupported integrations. Claude uses the OAuth usage endpoint and the agy
reader uses an internal client quota endpoint; either provider may change or disappear without
notice. Tokens are read from the macOS Keychain only for an enabled live read, held in memory for
the request, and never cached. An expired Claude credential is reported as unknown; refreshing it
would require a separate OAuth flow, which this feature deliberately does not attempt.

When `usageLimits.notice.enabled` is true, `chain run` periodically appends a short usage report
to the newly created dispatch and asks the existing parent notification contract to deliver it.
Set `usageLimits.notice.intervalSeconds` to choose the cadence and use
`megabrain chain limits --notice-off` to disable it. This is driven by chain runs rather than a daemon,
so it has no background process and naturally follows existing activity. Notice delivery failures
leave the durable message queued and do not fail the chain caller.

### Environment facts

Environment measurements that are expensive to rediscover live in the versioned
`.megabrain/facts.json` file. JSON keeps the store machine-readable and reviewable in a normal
diff. A fact has an `id`, the measured `measurement`, a `scope`, and `provenance` containing
`who`, `when`, and the exact `command` that can measure it again. Provenance is required so a
reader can verify a measurement instead of treating an unverified statement as truth.

Facts are either global or repository-scoped. Global facts apply to every repository using that
store. Repository-scoped facts carry the repository's `remote.origin.url`; a child receives them
only when its repository identity matches. When no remote exists, the Git common directory is the
identity fallback. This lets linked worktrees share facts without passing facts for another
repository to a child.

Manage facts with:

    megabrain fact list [--json]
    megabrain fact add <id> --measurement <text> --who <name> --when <timestamp> --command <command> [--scope global|repository] [--repository <id>]
    megabrain fact edit <id> [--json]
    megabrain fact remove <id> [--json]

The add command rejects missing provenance fields before writing. Edit also validates the complete
store before replacing it. Fact preambles are limited to 20 in-scope facts and 6000 bytes; a
dispatch fails with a clear error if either limit is exceeded. Every injected fact is described as
a starting point with provenance, not truth. If a worker's own measurement disagrees, its
measurement wins and the disagreement must be reported.

The store is for environment measurements that cannot be deduced from repository source and cost
real time to rediscover, such as installed tool behavior, third-party file layout, or CI gates.
Architecture rules belong in `AGENTS.md`, and code structure belongs in the code itself.

### Spawn runtimes

The runtime is resolved once before the worktree or terminal is created:

- `--tmux true` always selects tmux and fails if tmux is unavailable.
- `--tmux false` always selects the IDE terminal primitive.
- Without `--tmux`, an installed tmux-runtime module selects tmux; otherwise the IDE terminal primitive is selected.

IDE mode uses the issuing terminal identity: `SUPERSET_TERMINAL_ID` selects Superset and
`ORCA_TERMINAL_HANDLE` selects Orca. An unmanaged shell fails before creating anything. In IDE
mode the only host operation that starts the child is `terminals create` in Superset or
`terminal create` in Orca, with the worktree and complete megabrain-built command. In tmux mode the
same host operation opens a shell in the worktree; megabrain then launches the child in that pane.

The prompt is never part of the agent command line. Tmux and host readiness checks are only cheap
launch preflights: they establish that an agent process exists, not that it accepts input. The
dispatch preamble tells the child to run `./megabrain received` before starting work. Spawn waits for
that durable queue message and its Delivery acknowledgement; only that receiver signal marks
`promptDelivered` true. A send or receipt timeout leaves the dispatch failed with
`promptDelivery: "not-delivered"` and a reason naming the missing confirmation.

Use repeatable `--agent-arg <value>` to append arbitrary agent flags after megabrain's generated
launch, model, and effort flags. Values are passed as separate shell arguments and retain their
quoting.

### Dispatch state axes

`meta.json` keeps `state` as the coarse dispatch status and adds two independent lifecycle axes:

| Field | Values and meaning |
| --- | --- |
| `state` | `spawning`, `running`, `waiting_for_reply`, `done`, `closed`, `failed`, `orphaned`, `stalled`, `timeout`, or `circuit_broken`; the existing dispatch status. |
| `processState` | `starting`, `start-unproven`, `running`, `stopping`, `stop-unproven`, `stopped`, `succeeded`, `failed`, or `abandoned`; the child process outcome. `abandoned` ends megabrain's logical authority without asserting that the process died. |
| `terminalState` | `owned`, `retained`, `missing`, or `released`; the terminal resource state. `retained` blocks release and reuse when terminal identity is unproven or the parent is gone. |

`orchestrate list` reads the durable dispatch inventory without querying live terminal state. Use
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
               | megabrain orchestrate spawn
               v
+-----------------------------+
| Child agent in a worktree   |
+--------------+--------------+
               |
               v
~/.megabrain/dispatches/<id>/
  meta.json  cursor.json  messages/*.json
  deliveries/*.json
```

The parent session identity creates a dispatch for one child agent and worktree. Parent and child
exchange JSON messages as append-only files in the dispatch directory. Ownership is direct-parent-only:
a parent can inspect, reply to, or close its own dispatch, but ownership does not pass to a grandparent.

Messages are delivered in FIFO batches of up to 50 through a Delivery record. An outstanding Delivery is replayed with the same delivery id until it is acknowledged; there is one outstanding Delivery per mailbox. A different consumer identity or generation fences the old Delivery and receives the same unread messages under a new id. Acknowledgement is idempotent, and cursor.json is retained for compatibility but is not the source of read state.

The child reads queued parent replies with `megabrain check [--timeout 0] --json`. It receives a
Delivery with the same replay behavior as the parent watch path; until it acknowledges that
Delivery, another check returns the same delivery id and messages. A child acknowledges with
`megabrain ack <delivery-id> --json`; acknowledgement is idempotent.

Child ask, done, and stalled messages also make a best-effort parent nudge. The durable message
queue and Delivery record remain the source of truth: the nudge contains only a short pointer
with the dispatch id, never the message body. A failed, skipped, or lost nudge cannot fail the
child message or remove it from the queue. A parent with an active watch waiter is not typed at;
the waiter reads the queued Delivery normally.

The parent nudge contract has two operations, parent_is_idle and parent_notify. Both must prove
idle before sending input; unknown liveness is treated as not idle. In tmux-runtime, metadata
records the parent pane. Devkit compares two tmux capture-pane snapshots and accepts an explicit
stable shell or agent prompt marker; an active marker such as Working, Thinking, Running, or an
interrupt hint is busy, while missing or changing evidence is unknown. Input is sent with two
separate tmux send-keys calls so text and Enter cannot be coalesced.

In IDE mode, Orca provides terminal wait --for tui-idle and terminal send --enter. Superset has
no terminal idle verb, so megabrain polls terminals read until two snapshots settle within the
timeout, then uses terminals send, whose default submits the text. If an adapter is unavailable
or liveness cannot be established, megabrain skips the nudge and leaves polling and the queue
available.

watch defaults to wait-mode nudge. It blocks on a disposable wake marker and rechecks the durable
queue after waking. Use wait-mode poll, or poll, to retain the original polling loop explicitly.

With the optional `tmux-runtime` module enabled, megabrain launches each child inside a tmux session
hosted in the IDE tab instead of the host's own agent primitive. That gives full control of the
agent command line, real splits for siblings in one tab, per-pane reads, and a close that removes
the pane. The host app then no longer treats the child as one of its agents, so features tied to
that (Superset resume/fork/handoff and its agent-attention badge) do not apply.

Child identity is pane-scoped inside tmux. When `TMUX` and `TMUX_PANE` are set, `megabrain ask` and
`megabrain done` match the current tmux session and pane, together with the child host; the shared
host terminal id is not used to select a child. Outside tmux, lookup remains terminal-id based.
A missing pane or an ambiguous identity is refused, and parent reads, acknowledgements, and replies
remain restricted to the dispatch's direct `parentSessionId` and `parentHost`. When a managed child
reuses an existing wrapper session, its metadata records the host terminal identity; if prior
session metadata cannot provide one, the current managed parent identity is used, with an explicit
unknown-host-terminal marker as the final fallback.

### Tmux tuning

To fix tmux colours and match the default terminal, run `megabrain tmux tune`.

### Tmux agent wrapper

The tmux runtime has two fronts: megabrain launches managed agents inside tmux, while the shell
wrapper opens hand-typed `claude`, `codex`, and `agy` commands there too. Install it with
`megabrain tmux wrapper`; this defines shell functions with those names in every new interactive
zsh, so `DEVKIT_NO_TMUX=1` or `command claude` bypasses the wrapper when a bare command is needed.

The wrapper records its main session in `~/.megabrain/sessions/<session>.json` (or the directory
selected by `MEGABRAIN_STATE_DIR`). The record includes the tmux session, agent, starting directory,
main pane, host, and creation time. Registration is best effort; if tmux or state storage is
unavailable, the agent runs directly. When megabrain searches for a session, records for sessions
that no longer exist are ignored and pruned automatically.

When a wrapper session is reused for a managed child, the registered main pane stays on the left
half of the window. The first child opens on the right; later children are stacked vertically in
that right column, and the main pane is resized back to half after every split. Sessions without
a registered main pane keep the existing tmux split behavior.

Agents launched by megabrain run without approval prompts because they are isolated in a worktree; launch the agent manually if you want approval prompts.

## Command reference

### Install and diagnostics

| Command | What it does | Notable flags |
| --- | --- | --- |
| `megabrain install` | Interactively installs selected modules. | Select module numbers or `all`. |
| `megabrain install orchestration` | Installs and verifies one module. | Replace the module id with any supported module. |
| `megabrain doctor` | Checks every module without changing configuration. | `--json` |
| `megabrain doctor simulator-web` | Checks one module. | `--json` |
| `megabrain context --json` | Reports the detected host and available workspace, terminal, and agent ids. | `--json` |

Supported module ids are `orchestration`, `orchestration-hooks`, `worktree`, `simulator-web`,
`simulator-native`, `simulator-tv`, and `tv-adb`. Doctor reports `ok`, `missing`,
`misconfigured`, or `unsupported` with a reason.

### Shared worktrees

| Command | What it does | Notable flags |
| --- | --- | --- |
| `megabrain worktree create --repo "$PWD" --branch feature/example` | Creates a Git worktree and its Superset project and workspace. | `--base`, `--name`, `--json` |
| `megabrain worktree finish feature/example` | Removes a shared worktree and registered workspace. | `--delete-branch`, `--force`, `--json` |
| `megabrain worktree list` | Lists worktrees under Superset's shared root and whether each is registered. | `--repo`, `--json` |
| `megabrain worktree adopt feature/example` | Registers an existing physical worktree in Superset. | `--json` |
| `megabrain terminal create --worktree "$PWD" --command "./megabrain --version" --title "megabrain version" --json` | Opens a terminal in the current orchestrator. | `--worktree`, `--command`, `--title`, `--json` |

`worktree create` defaults the base to the origin default branch, then Git's configured default,
then `main`. `terminal create` uses `.superset/config.json` only when `--command` is omitted.

### Orchestration

| Command | What it does | Notable flags |
| --- | --- | --- |
| `megabrain orchestrate spawn --repo "$PWD" --branch feature/agent-task --agent codex --model gpt-5 --effort medium --prompt "Inspect the repository."` | Creates or reuses a worktree and launches a managed child agent. | `--base`, `--name`, `--label`, `--worktree`, `--tmux`, `--agent-arg`, `--json` |
| `megabrain orchestrate list --json` | Lists dispatches owned by the current parent. | `--all`, `--orphans`, `--json` |
| `megabrain orchestrate reconcile <dispatch-id> --json` | Reconciles one open dispatch without respawning it. | `--all`, `--json` |
| `megabrain orchestrate watch <dispatch-id> --json` | Waits for the next child Delivery batch, waking from the parent nudge marker by default. | `--timeout`, `--poll-interval`, `--wait-mode nudge\|poll`, `--poll`, `--consumer`, `--generation`, `--json` |
| `megabrain orchestrate ack <dispatch-id> <delivery-id> --json` | Acknowledges a Delivery batch. | `--consumer`, `--generation`, `--json` |
| `megabrain orchestrate reply <dispatch-id> --text "Continue." --json` | Queues a reply for a child that is running or waiting for the parent. | `--json` |
| `megabrain orchestrate close <dispatch-id> --json` | Closes the child terminal and records the dispatch as closed. | `--force-release`, `--json` |
| `megabrain ask "question"` | Sends a question from a child to its direct parent. | One question argument. |
| `megabrain done "summary"` | Sends completion from a child to its direct parent. | One summary argument. |
| `megabrain check --timeout 0 --json` | Reads queued replies addressed to the current child. | `--timeout`, `--poll-interval`, `--consumer`, `--generation`, `--json` |
| `megabrain ack <delivery-id> --json` | Acknowledges a child reply Delivery. | `--consumer`, `--generation`, `--json` |

`watch` reports the Delivery id, replayed flag, covered message sequences, and messages alongside
`received`, `waiting_for_reply`, `done`, `stalled`, or `timeout`. A child should use `ask` or `done` instead
of printing protocol markers.

The dispatch preamble requires the child to run `./megabrain received` before work begins. The parent
waits for that child-authored queue message and acknowledges its Delivery before recording
`promptDelivered: true`; pane output, composer changes, context percentages, and terminal idle
states are not delivery evidence.

`orchestrate spawn` selects its prompt budget from the delivery path before creating a worktree,
workspace, terminal, agent, or dispatch record. The prompt is rejected rather than truncated and
is delivered only after the child-authored receipt is confirmed.

| Delivery path | Measured capacity | Chosen prompt budget |
| --- | ---: | ---: |
| argv, including Superset terminals create and equivalent host calls | ARG_MAX 1048576 bytes; 262144-byte prompt survived intact | 262144 bytes |
| tmux send-keys | 12000 bytes executed intact; 16384 bytes hit command too long | 12000 bytes |

The tmux path is intentionally limited below 16000 bytes; write shorter briefs when tmux-runtime
is enabled.

### Native simulators

| Command | What it does | Notable flags |
| --- | --- | --- |
| `megabrain native appium start` | Starts the shared Appium server on port 4723. | No flags. |
| `megabrain native appium status` | Reports whether Appium is up, down, or occupying the port. | No flags. |
| `megabrain native appium stop` | Stops the Appium process managed by megabrain. | No flags. |

Install the prerequisites first with `megabrain install simulator-native`. Apple TV uses the same
Appium/XCUITest toolchain through `simulator-tv`.

### Android TV

| Command | What it does | Notable flags |
| --- | --- | --- |
| `megabrain tv connect <ip>` | Connects to an Android TV and requires adb to report it as `device`. | `--port` (default `5555`) |
| `megabrain tv disconnect` | Disconnects all adb devices. | An IP argument disconnects one device. |

Check adb with `megabrain doctor tv-adb`; when it is missing, `megabrain install tv-adb` prints the
platform-tools command for the detected package manager.

### Web browser testing

| Command | What it does | Notable flags |
| --- | --- | --- |
| `megabrain install simulator-web` | Verifies npx and registers Playwright MCP with installed agent CLIs. | No flags. |
| `megabrain doctor simulator-web` | Checks npx, Playwright MCP, and agent registrations. | `--json` |

The module runs `@playwright/mcp@latest` through npx.

## Known limitations

- Closing a Superset dispatch disposes the session, but the pane remains visible as `Desconectado` until a human dismisses it with the pane X. There is no CLI verb to remove a pane; this was verified against the terminal and browser command surfaces, the local database, and app state files.
- Installing megabrain's turn-end hook changes the agent hook configuration and invalidates Codex's per-entry trust. The next Codex launch shows `Hooks need review` until a human trusts it once. Opening Codex through Superset does not clear it because Superset passes `--dangerously-bypass-hook-trust`.
- Superset terminals cannot be given a title by any flag. Their pane title follows the running command; `--title` affects Orca terminals only.

## Troubleshooting

| Symptom | Cause | What to run |
| --- | --- | --- |
| `megabrain doctor` says a module is `missing` | A module prerequisite is absent. | `megabrain install <module-id>` |
| Codex hangs on `Hooks need review` | The hook changed Codex's trusted configuration. | Run `codex` in a plain terminal and choose `Trust all and continue`; then `megabrain doctor orchestration-hooks`. |
| A dispatch never reports | The child may be stalled or has not sent a recognized message. | `megabrain orchestrate watch <dispatch-id> --json` and inspect the `stalled` or `timeout` status. |
| A worktree exists in one tool but not the other | Its physical checkout is not registered in Superset. | `megabrain worktree adopt <path-or-branch>` |

## Exit codes

`0` means the command completed successfully, `1` means an operational check or action failed,
and `2` means an invalid command, module id, option, or required argument was provided.

## Contributing

Contributions are welcome; keep changes focused and run the relevant checks before opening a change.

## License

MIT. See [LICENSE](LICENSE).
