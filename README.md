# devkit

devkit is a shared command-line entrypoint for coding-agent tooling: it keeps Orca and
Superset.sh pointed at the same Git worktrees and registers those worktrees in both tools,
while providing one command surface for agent terminals, Appium-based iOS and tvOS simulator
control, Android TV connections through adb, and Playwright MCP browser testing. It exists so
the same checkout, prerequisites, and orchestration state remain visible wherever an agent is
working.

## Prerequisites

devkit requires both of these applications to be installed and usable:

- Orca, with its `orca` CLI available.
- Superset.sh, with its `superset` CLI available (or its `$HOME/.superset/bin/superset` shim).

Some modules have additional prerequisites documented below. The native simulator modules are
available only on macOS.

## Install

From a checkout, run:

```sh
./install.sh
```

The installer links `devkit` into `$HOME/.local/bin`, detects the installed agent CLIs
(`claude`, `codex`, and `agy`), and offers keyboard selectors for the agents and optional
devkit modules to configure. Claude's global mode registers the install root as the
`devkit-local` marketplace and installs `devkit@devkit-local`; Claude's project mode keeps a
project-local bare skill copy because Claude marketplace plugins are user-scoped. The AGENTS.md
snippet is independent and can still be installed globally or in the current project.

Use flags for an unattended install:

```sh
./install.sh --agents claude,codex,agy --skill global --agents-md global --modules none --yes
```

Pass `--agents none` to install only the CLI symlink and optional AGENTS.md snippet. The
multi-agent package keeps one shared skill at `skills/devkit/SKILL.md`, with Claude and Codex
manifests at `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json`. Claude discovers its
marketplace manifest at `.claude-plugin/marketplace.json`; Codex uses the companion
`.agents/plugins/marketplace.json` manifest, and both point to this repository as the local
plugin source.

The same installer can be run directly from the repository with curl; it downloads the GitHub
source tarball, strips its top-level directory, and installs it at `$HOME/.devkit-local` without
requiring Git:

```sh
curl -fsSL https://raw.githubusercontent.com/oguilhermelima/devkit-local/main/install.sh | bash
```

The installer records its version, source ref, install date, selected agents, and selected
modules in `$HOME/.devkit-local/install-manifest.json`. On a later run it shows the existing
installation and offers update, reconfigure, or abort. Existing Claude and Codex marketplaces
are compared by path; a different path is kept unless the user explicitly chooses replace.
Already-installed plugins are treated as successful and already-current.

For unattended installs, use `--agents`, `--skill`, `--agents-md`, and `--modules` explicitly.
A non-interactive invocation without the required choices exits with an explanatory error rather
than waiting for input. Interactive selectors support arrows, number keys, Space for multi-select,
and Enter to confirm.

## Commands

### Installation and diagnostics

`devkit install` opens an interactive module selector. Select one or more module numbers, or
choose `all`. To install one module without prompting, pass its id, such as
`devkit install orchestration`. Installation performs the module's setup and then verifies it;
results are recorded in `$HOME/.devkit/state.json`.

`devkit doctor` checks every module and returns a status for each one. Pass a module id, for
example `devkit doctor simulator-web`, to check only that module. A check is reported as
`ok`, `missing`, or `misconfigured` with a reason, and doctor does not change configuration.

The available modules are:

- `orchestration` checks that `orca status --json` and `superset workspaces list --json` work.
- `orchestration-hooks` installs and checks the turn-end safety hook for each installed Claude,
  Codex, agy, and Cursor CLI, preserving the other hooks in their configuration files and
  replacing stale devkit entries by script identity.
- `worktree` checks Orca, Superset.sh, and the configured Superset `worktreeBaseDir`.
- `simulator-web` checks that `npx -y @playwright/mcp@latest --version` runs and that the
  Playwright MCP server is registered with installed Claude Code, Codex, and agy CLIs.
  Installation registers it with each installed agent CLI.
- `simulator-native` checks Appium and its XCUITest driver. Installation installs Appium with
  npm when needed and installs the XCUITest driver.
- `simulator-tv` uses the same Appium and XCUITest setup as `simulator-native` for Apple TV
  simulator control.
- `tv-adb` checks that adb is available and working. Installation prints the platform-tools
  command to use when adb is missing.
- `tmux-runtime` checks tmux, reports its version and whether the runtime is enabled. On macOS
  it installs missing tmux with Homebrew; on Linux it prints an explicit package-manager command
  for the user to run. The runtime applies mouse support, hidden status, an active-pane border,
  and zero escape delay only to devkit-owned tmux sessions.

`simulator-native` and `simulator-tv` are macOS-only because XCUITest and Apple's simulators
are provided by Xcode. On other systems their doctor status is `unsupported`.

### Orchestration context

`devkit context` reports the current host as `superset`, `orca`, or `unknown`. Superset is
detected from its terminal environment; otherwise devkit checks whether the current directory
resolves to an Orca worktree. Add `--json` for automation, including workspace, terminal, and
agent identifiers when Superset provides them.

### Shared worktrees

`devkit worktree create --repo <name-or-path> --branch <branch>` creates a Git worktree under
Superset's configured shared root, registers the repository and workspace in Superset, and
prints the resulting paths and ids. The base defaults to the repository's origin default
branch, then Git's configured default branch, then `main`; use `--base <ref>` to override it.
Use `--name <slug>` to choose the directory name. `--agent <id>` starts an agent terminal in
the new worktree; combine it with `--model`, `--effort`, and `--prompt` to forward agent options.
The model and effort options use each agent CLI's native syntax: Codex receives
`-c model="<model>"` and `-c model_reasoning_effort="<level>"`, while Claude and agy receive
`--model <model>` and `--effort <level>`. Unknown agents retain the generic `--model` and
`--effort` flags.

`devkit worktree list` lists Git worktrees under the shared root and shows whether each has a
Superset workspace. Add `--repo <name-or-path>` to filter the list. `devkit worktree adopt
<path|branch>` registers an existing physical worktree in Superset without creating another
checkout.

`devkit worktree finish <branch|path|slug>` removes the registered Superset workspace, or
falls back to Orca when no Superset workspace exists. Add `--delete-branch` to delete its
branch after removal; branch deletion requires proof that the branch is merged into the default
base. `--force` permits removal and deletion when that safety check must be overridden.

### Agent orchestration

`devkit orchestrate spawn --repo <name> --branch <branch> --agent <id> --model <model>
--effort <level> --prompt <text> [--label <text>]` is the convenience form of worktree creation with a required
agent launch configuration. The host is inferred from the current terminal. Use `--base` and
`--name` as with worktree creation. To launch into an existing checkout, pass
`--worktree <path|branch>`; it must already have a Superset workspace, so run `devkit worktree adopt`
first when needed. `devkit orchestrate list` shows managed dispatches owned by the current parent;
`--all` includes other owners and marks them as not-owned, while `--orphans` filters dead parents.

Managed dispatches use the caller's native terminal identity and an append-only file channel at
`$DEVKIT_STATE_DIR/dispatches/<dispatch-id>/`. Each directory contains immutable `messages/` audit
records, `meta.json` lifecycle and ownership metadata, and a separate `cursor.json` read position.
Only the direct parent may reply or close; a grandparent cannot mutate a grandchild. Child agents
must run `devkit ask "question"` and `devkit done "summary"`, rather than printing protocol markers.
The parent can run `devkit orchestrate watch <dispatch-id>`, then reply with
`devkit orchestrate reply <dispatch-id> --text <answer>` and finish with `devkit orchestrate close`.
Superset `agents create` has no `--model` option. When a requested model matches the model string
in a configured instance's args or environment, devkit passes that instance id as `--agent` and
records the match in dispatch metadata. If no configured instance pins the requested model, devkit
uses the selected preset and reports that the model was not forwarded; `--model` remains required
so every dispatch records an unambiguous request.
The agy and gemini Superset presets currently reject prompt launches with unexpected argument;
devkit reports this known preset limitation clearly and does not create a dispatch that can hang.

When `tmux-runtime` is enabled, devkit opens a host terminal containing a tmux session and sends
the agent command after the shell settles. Dispatches in the same worktree split that session,
and their metadata records the tmux session and pane. Pane reads use `capture-pane`, replies use
targeted `send-keys`, and close removes the pane (or the session when it is the last pane).
`devkit orchestrate read <dispatch-id>` reads tmux scrollback without compositing sibling panes.
The launch sequence sends Enter separately and verifies submission with bounded retries because
some terminal layers lose Enter when it is sent with the command text. Starting with a shell also
prevents terminal-identification replies from leaking into the agent composer.

The trade-off is intentional: the host application no longer recognises a tmux child as one of
its native agents. Host-native features tied to `agents create`, including Superset resume, fork,
and handoff, do not apply, and Superset's agent-attention badge does not represent tmux children.

The `orchestration-hooks` module is a safety net for silent child death: when an installed agent
turn ends without `devkit ask` or `devkit done`, its final text is recorded as a stalled dispatch
message. Installation edits hook configuration files also managed by Orca and Superset, while
preserving their existing entries and replacing stale devkit entries by script identity. Run
`devkit doctor orchestration-hooks` because those apps may rewrite the files during updates and
drop the devkit entry.

When the Codex hook is installed or present, Codex requires a one-time trust action after a path
change. Open a plain terminal, run `codex`, and choose `Trust all and continue`. Opening Codex
through Superset does not complete this action because Superset passes
`--dangerously-bypass-hook-trust`; the same reminder is printed by `devkit doctor`.

`devkit orchestrate watch <dispatch-id> [--timeout <seconds>] [--poll-interval <seconds>]`
polls the file channel for the next child message and returns `waiting_for_reply`, `done`, `stalled`,
or `timeout`; add `--json` for structured output. `reply` records and delivers the coordinator's
answer, while `close` disposes the native terminal and leaves all messages on disk. On Superset,
closing disposes the session but the pane remains visible as `Desconectado` until the human
dismisses it with the pane's X; there is no CLI verb to remove that pane.

`devkit terminal create [--command <cmd>] [--title <text>] [--worktree <path>]` opens a terminal
tab in the orchestrator where the caller is running, using the worktree's `.superset/config.json`
`run` script when `--command` is omitted. The worktree defaults to the current Git checkout, and
`--json` emits the selected host, resolved worktree, and title. Superset tabs are not titled; only
Orca tabs are. When running under Superset, the worktree must already be registered; run `devkit
worktree adopt <path>` first when needed.

### Native simulators

`devkit native appium start` starts the shared Appium server on port 4723 after verifying the
native simulator prerequisites. Starting an already-running server is a no-op. Use
`devkit native appium status` to inspect it and `devkit native appium stop` to stop it. The
server pidfile and log are stored in `$HOME/.devkit/`.

### Android TV

`devkit tv connect <ip>` connects to an Android TV at port 5555 through adb and succeeds only
when adb reports the serial as `device`. Pass `--port <port>` for another port; offline and
unauthorized devices are reported as failures. `devkit tv disconnect [<ip>]` disconnects one
device or asks adb to disconnect all devices.

### Web browser testing

Install and verify the web testing integration with `devkit install simulator-web` and
`devkit doctor simulator-web`. devkit runs `@playwright/mcp@latest` through npx and uses the
native MCP registration commands for each installed Claude Code, Codex, and agy CLI.

## Exit codes

- `0` means the command completed successfully and requested checks passed.
- `1` means an operational check or action failed.
- `2` means an invalid command, module id, option, or required argument was provided.

## License

devkit is available under the MIT License. See [LICENSE](LICENSE).
