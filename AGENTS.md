For worktree/orchestration/native-sim/browser tooling shared across repos, read https://github.com/oguilhermelima/devkit-local/blob/main/AGENTS.md and use its megabrain commands instead of raw orca/superset calls where one exists.

- If you need to install or inspect megabrain modules, run: megabrain install
- If you need to install one megabrain module, run: megabrain install <module-id>
- If you need to check all module prerequisites, run: megabrain doctor
- If you need to check one module prerequisite, run: megabrain doctor <module-id>
- If you need to install the child turn-end safety hooks, run: megabrain install orchestration-hooks
- If you need to check the child turn-end safety hooks, run: megabrain doctor orchestration-hooks
- If you need to identify the current orchestration host, run: megabrain context --json
- If you need to create a shared worktree, run: megabrain worktree create --repo <name-or-path> --branch <branch> [--base <ref>] [--name <slug>] [--agent <id>] [--model <id>] [--effort <level>] [--prompt <text>]
- If you need to finish a shared worktree, run: megabrain worktree finish <branch-or-path-or-slug> [--delete-branch] [--force]
- If you need to list shared-root worktrees, run: megabrain worktree list [--repo <name|path>]
- If you need to adopt an existing physical worktree, run: megabrain worktree adopt <path|branch>
- If you need to spawn an agent in a shared worktree, run: megabrain orchestrate spawn --repo <name> --branch <branch> --agent <agent> --model <model> --effort <level> --prompt <text> [--label <text>] [--base <ref>] [--name <slug>]
- If you need to list active Orca and Superset terminals, run: megabrain orchestrate list [--json]
- If you need to watch a Superset dispatch, run: megabrain orchestrate watch <dispatch-id> [--timeout <seconds>] [--poll-interval <seconds>] [--json]
- If you need to acknowledge a delivery, run: megabrain orchestrate ack <dispatch-id> <delivery-id> [--json]
- Spawn prompt budgets are 262144 bytes on argv paths and 12000 bytes on tmux paths.
- If you need to reply to a Superset dispatch, run: megabrain orchestrate reply <dispatch-id> --text <answer> [--json]
- If you need to close a Superset dispatch, run: megabrain orchestrate close <dispatch-id> [--json]
- If you need to reconcile a dispatch without respawning it, run: megabrain orchestrate reconcile <dispatch-id> [--json]
- If you need to override retained-terminal protection, run: megabrain orchestrate close <dispatch-id> --force-release [--json]
- Known limitation: Superset agy and gemini presets reject prompt launches; megabrain reports the preset error instead of creating a stuck dispatch.
- If you need to open a titled terminal tab in the right orchestrator, run: megabrain terminal create [--command <cmd>] [--title <text>] [--worktree <path>] (omitting --command uses the worktree's .superset/config.json run script)
- If you need to start the shared Appium server, run: megabrain native appium start
- If you need to stop the shared Appium server, run: megabrain native appium stop
- If you need to check the shared Appium server, run: megabrain native appium status
- If you need to use native iOS or tvOS simulator support, run: megabrain doctor simulator-native (macOS only)
- If you need to use Apple TV simulator support, run: megabrain doctor simulator-tv (macOS only)
- If you need to connect an Android TV, run: megabrain tv connect <ip> [--port 5555]
- If you need to disconnect an Android TV, run: megabrain tv disconnect [<ip>]
- If you need to configure web browser testing through Playwright MCP, run: megabrain install simulator-web

Superset tabs are not titled; only Orca tabs are.

Managed dispatches use the append-only channel under $MEGABRAIN_STATE_DIR/dispatches/ and direct
parent ownership. On Superset, megabrain orchestrate close disposes the session but leaves the pane
visible as Desconectado until the human dismisses it with the pane X; the CLI cannot remove it.

## megabrain plugin distribution

This repository ships one shared skill at `skills/megabrain/SKILL.md`. Claude Code uses
`.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`, while Codex uses
`.codex-plugin/plugin.json` and `.agents/plugins/marketplace.json`; both marketplace manifests
point at this repository and both agent manifests load the shared `skills/` directory. Use
`install.sh --agents claude,codex,agy --skill global` to register the installed agent CLIs, or
`--skill project` for Claude's project-local bare skill fallback.

To fix tmux colours and match the default terminal, run `megabrain tmux tune`.
To install the hand-typed agent tmux wrapper, run `megabrain tmux wrapper`.

## Migration

The deprecated devkit command remains available as a compatibility alias while existing scripts migrate to megabrain. The old DEVKIT_STATE_DIR variable is accepted with a deprecation notice; use MEGABRAIN_STATE_DIR for new integrations. The GitHub repository URL above remains unchanged until the user renames it.
