# megabrain

megabrain is a local coordination layer for coding agents working across Orca and Superset.sh. It keeps the worktree, terminal, agent, and conversation state connected so an operator can run several pieces of work without manually copying messages between tools.

It is for developers and agent operators who need parallel work to remain trackable, recoverable, and understandable after a terminal disappears or a provider changes.

## Why it exists

The project started with a concrete problem: different coding-agent orchestrators could create worktrees and terminals, but they did not share bookkeeping or a reliable conversation channel. The operator became the bottleneck, relaying prompts, checking pixels for replies, and repairing state when one tool knew about a child that the other could not see.

megabrain puts that coordination behind one command surface. It creates the shared resources, starts the child, records the dispatch, and keeps the parent and child connected through durable state.

## The capabilities

### Orchestration

Orchestration tracks a child agent from launch through completion. A parent can ask a child a question, receive a reply, answer it, and close the dispatch while ownership remains limited to the direct parent.

The durable message queue is the truth. A terminal keystroke is only a notification that may wake a participant; the recipient confirms receipt by publishing a message into the queue. Delivery records replay until they are acknowledged, so a missed terminal nudge does not erase a message and the sender never infers delivery from terminal pixels.

### Chains

Chains let a parent choose an ordered list of child agents. A step is skipped when its usage limit is exhausted, and the next step is tried when launching it fails. The final dispatch records which chain and step won, along with the reasons earlier steps were skipped.

This turns provider fallback into a visible decision instead of a manual retry loop. A chain does not hide an exhausted or failed step, and it does not silently rewrite its configuration.

### Model registry

The registry describes which model identifiers and reasoning levels each supported agent accepts. Its entries identify whether the knowledge came from a live agent listing, a published provider reference, or local observation. It keeps model provenance separate from reasoning provenance, so a sourced model name is not mistaken for a verified spelling of every reasoning option. Chains validate against this registry before launch and keep unknown exceptions visible when explicitly allowed.

### Usage limits

Usage-limit reading gives chains enough information to avoid launching a provider whose window is already exhausted. Codex usage comes from the newest local rollout snapshot; other providers are opt-in and may be unknown, which remains usable rather than being treated as exhausted.

### Shared worktrees

A shared worktree is one physical Git checkout registered with both Orca and Superset. The same identity can therefore be discovered from either orchestrator, while the worktree and dispatch metadata stay together. Existing physical worktrees can also be adopted into the shared registry.

### Runtimes

Children can run in an IDE terminal or inside tmux. IDE mode keeps the child in the host orchestrator; tmux mode gives megabrain direct pane ownership, which makes sibling splits and pane-scoped identity possible. The runtime is chosen for a launch and is recorded with the dispatch.

### Tmux tuning and shell wrapper

The tmux integration can tune colours to match the default terminal and install a shell wrapper for hand-typed agent launches. Managed children and manually started agents can share a predictable session layout, while a direct command remains available when tmux is unavailable or intentionally bypassed.

### Emulators and devices

The native modules connect iOS and tvOS simulator work to Appium and its XCUITest driver. The Android TV module uses adb to connect and disconnect a device. These capabilities keep device setup and health checks in the same module and diagnostic model as orchestration.

### Web browser testing

The browser module installs and registers Playwright MCP with the agent CLIs that are present. It gives an agent a consistent path to browser inspection and interaction without making browser state part of the dispatch protocol.

### Environment facts

Environment facts capture measurements that are expensive to rediscover, such as installed-tool behaviour or third-party file layout. Facts carry scope and provenance, and only facts applicable to the child repository are injected into a dispatch. They are evidence to check, not authority: if a worker measures something different, its measurement wins and the disagreement is reported.

## Honest limits

megabrain coordinates local tools; it is not a hosted agent service, a provider billing system, or a replacement for the agent CLIs and orchestrators it connects.

- The live usage reader uses an unsupported, undocumented endpoint and may break without notice. Credentials are read only for an enabled live read; megabrain does not refresh an expired OAuth credential.
- Codex reasoning spellings are inferred from available configuration and only xhigh has been verified. The remaining spellings in the registry are not guarantees.
- The agy provider is not implemented.
- A main-type Superset workspace cannot be pruned from the CLI. Closing a Superset dispatch can also leave a Desconectado pane visible until a human dismisses it.
- Installing the turn-end hook changes agent hook configuration and can require a human to trust the next Codex launch once. Superset cannot assign a custom terminal title; its pane title follows the running command.

## Quick start

From a checkout, inspect the installer options and install the modules you need with install.sh. In a managed Orca or Superset terminal, verify the detected host and available model registry:

```sh
./install.sh --help
./megabrain context --json
./megabrain model list --json
```

Use AGENTS.md for the complete command recipes and flags. The command is now megabrain; devkit remains a deprecated compatibility alias while existing installations migrate. The old DEVKIT_STATE_DIR variable remains accepted with a deprecation notice; new integrations should use MEGABRAIN_STATE_DIR.

## Requirements

- Orca with its CLI available for Orca status, discovery, and terminals.
- Superset.sh with its CLI available for shared worktrees, workspaces, and terminals.
- Git and jq.
- curl for a public-URL installer, npx for browser testing, and adb for Android TV.
- macOS with the Xcode Simulator, Appium, and the XCUITest driver for iOS and tvOS modules.

The orchestration, worktree, Android TV, and browser modules are portable, but each module still needs its own prerequisites.

## Troubleshooting

If a module is missing, use the installation recipe in AGENTS.md for that module and rerun the corresponding diagnostic recipe. If a dispatch does not report, use the orchestration watch recipe and inspect whether it is stalled or timed out. If a worktree exists in one orchestrator but not the other, use the adoption recipe for its path or branch.

If Codex stops at a hook-trust prompt, launch Codex once in a plain terminal, trust the hook interactively, and then rerun the orchestration-hooks diagnostic recipe.

## Exit codes

0 means the command completed successfully, 1 means an operational check or action failed, and 2 means an invalid command, module, option, or required argument was provided.

## Contributing

Contributions are welcome. Keep changes focused and run the relevant checks before opening a change.

## License

MIT. See [LICENSE](LICENSE).
