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

The installer links `devkit` into `$HOME/.local/bin`, then asks whether to install the Claude
Code skill and the AGENTS.md snippet globally or in the project where the installer was run.
Use flags for an unattended install:

```sh
./install.sh --skill global --agents-md global --yes
```

The same installer can be run directly from the repository with curl; it clones the repository
to `$HOME/.devkit-local` before continuing:

```sh
curl -fsSL https://raw.githubusercontent.com/oguilhermelima/devkit-local/main/install.sh | bash
```

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
--effort <level> --prompt <text>` is the convenience form of worktree creation with a required
agent launch configuration. The host is inferred from the current terminal. Use `--base` and
`--name` as with worktree creation. `devkit orchestrate list` combines live Orca and Superset
terminals into one table; `--json` emits an array suitable for scripts.

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
