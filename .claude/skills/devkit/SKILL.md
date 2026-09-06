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
- If you need to identify the current orchestration host, run: devkit context --json
- If you need to create a shared worktree, run: devkit worktree create --repo <name-or-path> --branch <branch> [--base <ref>] [--name <slug>] [--agent <id>] [--model <id>] [--effort <level>] [--prompt <text>]
- If you need to finish a shared worktree, run: devkit worktree finish <branch-or-path-or-slug> [--delete-branch] [--force]
- If you need to list shared-root worktrees, run: devkit worktree list [--repo <name|path>]
- If you need to adopt an existing physical worktree, run: devkit worktree adopt <path|branch>
- If you need to spawn an agent in a shared worktree, run: devkit orchestrate spawn --repo <name> --branch <branch> --agent <id> --model <model> --effort <level> --prompt <text> [--base <ref>] [--name <slug>]
- If you need to list active Orca and Superset terminals, run: devkit orchestrate list [--json]
- If you need to start the shared Appium server, run: devkit native appium start
- If you need to stop the shared Appium server, run: devkit native appium stop
- If you need to check the shared Appium server, run: devkit native appium status
- If you need to use native iOS or tvOS simulator support, run: devkit doctor simulator-native (macOS only)
- If you need to use Apple TV simulator support, run: devkit doctor simulator-tv (macOS only)
- If you need to connect an Android TV, run: devkit tv connect <ip> [--port 5555]
- If you need to disconnect an Android TV, run: devkit tv disconnect [<ip>]
- If you need to configure web browser testing through Playwright MCP, run: devkit install simulator-web
