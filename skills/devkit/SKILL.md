---
name: devkit
description: >-
  Use devkit to create and synchronize Git worktrees across Orca and Superset.sh, register
  repositories and workspaces in both orchestrators, spawn coding agents and manage agent
  terminals, control native iOS and tvOS simulators through Appium, connect Android TV devices
  through adb, and install or use Playwright MCP for web browser testing. Use when the user asks
  about shared worktrees, Orca/Superset orchestration, agent spawning, iOS or tvOS simulator
  control, Android TV testing, adb, Appium, Playwright MCP, or browser testing.
---

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
- If you need to spawn an agent in a shared worktree, run: devkit orchestrate spawn --repo <name> --branch <branch> --agent <id> --model <model> --effort <level> --prompt <text> [--label <text>] [--base <ref>] [--name <slug>], or target an existing checkout with --worktree <path|branch>.
- If you need to list managed dispatches, run: devkit orchestrate list [--all|--orphans] [--json]
- If you need to watch a Superset dispatch, run: devkit orchestrate watch <dispatch-id> [--timeout <seconds>] [--poll-interval <seconds>] [--json]
- If you need to acknowledge a delivery, run: devkit orchestrate ack <dispatch-id> <delivery-id> [--json]
- Spawn prompt budgets are 262144 bytes on argv paths and 12000 bytes on tmux paths.
- If you need to reply to a Superset dispatch, run: devkit orchestrate reply <dispatch-id> --text <answer> [--json]
- If you need to close a Superset dispatch, run: devkit orchestrate close <dispatch-id> [--json]
- If you need to reconcile a dispatch without respawning it, run: devkit orchestrate reconcile <dispatch-id> [--json]
- If you need to override retained-terminal protection, run: devkit orchestrate close <dispatch-id> --force-release [--json]
- If you are a child session, send a question with devkit ask "question" or completion with devkit done "summary".
- Parent ask, done, and stalled messages send a best-effort pointer nudge after queue persistence. The pointer never contains the message body; active watch waiters suppress terminal typing, and any failed or unsupported nudge leaves the queue available.
- `devkit orchestrate watch` waits on the nudge marker by default. Use `--wait-mode poll` or `--poll` for the explicit polling fallback.
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

Dispatch messages are append-only under $DEVKIT_STATE_DIR/dispatches/; direct-parent ownership is
required for reply and close. Closing a Superset dispatch leaves its pane visible as Desconectado
until the human dismisses it with the pane X because no CLI verb removes that pane.

To fix tmux colours and match the default terminal, run `devkit tmux tune`.
To install the hand-typed agent tmux wrapper, run `devkit tmux wrapper`.
