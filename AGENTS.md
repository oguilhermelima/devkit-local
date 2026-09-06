For worktree/orchestration/native-sim/browser tooling shared across repos, read https://github.com/oguilhermelima/devkit-local/blob/main/AGENTS.md and use its devkit commands instead of raw orca/superset calls where one exists.

- If you need to install or inspect devkit modules, run: devkit install
- If you need to install one devkit module, run: devkit install <module-id>
- If you need to check all module prerequisites, run: devkit doctor
- If you need to check one module prerequisite, run: devkit doctor <module-id>
- If you need to install the child turn-end safety hooks, run: devkit install orchestration-hooks
- If you need to check the child turn-end safety hooks, run: devkit doctor orchestration-hooks
- If you need to identify the current orchestration host, run: devkit context --json
- If you need to create a shared worktree, run: devkit worktree create --repo <name-or-path> --branch <branch> [--base <ref>] [--name <slug>] [--agent <id>] [--model <id>] [--effort <level>] [--prompt <text>]
- If you need to finish a shared worktree, run: devkit worktree finish <branch-or-path-or-slug> [--delete-branch] [--force]
- If you need to list shared-root worktrees, run: devkit worktree list [--repo <name|path>]
- If you need to adopt an existing physical worktree, run: devkit worktree adopt <path|branch>
- If you need to spawn an agent in a shared worktree, run: devkit orchestrate spawn --repo <name> --branch <branch> --agent <id> --model <model> --effort <level> --prompt <text> [--label <text>] [--base <ref>] [--name <slug>]
- If you need to list active Orca and Superset terminals, run: devkit orchestrate list [--json]
- If you need to watch a Superset dispatch, run: devkit orchestrate watch <dispatch-id> [--timeout <seconds>] [--poll-interval <seconds>] [--json]
- If you need to reply to a Superset dispatch, run: devkit orchestrate reply <dispatch-id> --text <answer> [--json]
- If you need to close a Superset dispatch, run: devkit orchestrate close <dispatch-id> [--json]
- Known limitation: Superset agy and gemini presets reject prompt launches; devkit reports the preset error instead of creating a stuck dispatch.
- If you need to open a titled terminal tab in the right orchestrator, run: devkit terminal create [--command <cmd>] [--title <text>] [--worktree <path>] (omitting --command uses the worktree's .superset/config.json run script)
- If you need to start the shared Appium server, run: devkit native appium start
- If you need to stop the shared Appium server, run: devkit native appium stop
- If you need to check the shared Appium server, run: devkit native appium status
- If you need to use native iOS or tvOS simulator support, run: devkit doctor simulator-native (macOS only)
- If you need to use Apple TV simulator support, run: devkit doctor simulator-tv (macOS only)
- If you need to connect an Android TV, run: devkit tv connect <ip> [--port 5555]
- If you need to disconnect an Android TV, run: devkit tv disconnect [<ip>]
- If you need to configure web browser testing through Playwright MCP, run: devkit install simulator-web

Superset tabs are not titled; only Orca tabs are.

Managed dispatches use the append-only channel under $DEVKIT_STATE_DIR/dispatches/ and direct
parent ownership. On Superset, devkit orchestrate close disposes the session but leaves the pane
visible as Desconectado until the human dismisses it with the pane X; the CLI cannot remove it.

## devkit plugin distribution

This repository ships one shared skill at `skills/devkit/SKILL.md`. Claude Code uses
`.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`, while Codex uses
`.codex-plugin/plugin.json` and `.agents/plugins/marketplace.json`; both marketplace manifests
point at this repository and both agent manifests load the shared `skills/` directory. Use
`install.sh --agents claude,codex,agy --skill global` to register the installed agent CLIs, or
`--skill project` for Claude's project-local bare skill fallback.
