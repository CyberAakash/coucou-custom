# coucou-custom — guide for this fork

This repo is CyberAakash's fork of [Louis-CFM/coucou](https://github.com/Louis-CFM/coucou). It carries a few
personal customizations on top of the official app and stays in sync with it. Everything in `CLAUDE.md`
still applies; this file adds the fork's own rules and wins where the two disagree.

## Remotes and branches
- `origin` = `CyberAakash/coucou-custom` (this fork). `upstream` = `Louis-CFM/coucou` (official, read-only for us).
- `main` = official `main` + every customization merged in. It is what gets built and installed.
- One branch per feature, `feature/<short-name>`, opened as a PR into `main` of **this fork** (never into upstream
  unless the user asks). A feature that needs another one branches from it (stacked) and says so in the PR.
- Tooling and docs for the fork go in `chore/<name>` branches.

## Customizations
| Branch | What it does |
|---|---|
| `feature/claude-code-login` | Settings → Chat → Anthropic → "Use my Claude Code login instead of a key": notch chat and search run through the installed `claude` CLI on the user's subscription (`ClaudeCodeCLI.swift`). |
| `feature/flow-cleanup-claude-code` | Flow → Styles clean-up uses the same login. Stacked on `feature/claude-code-login`. |
| `chore/fork-workflow` | This file, `scripts/custom-install.sh`, `scripts/custom-sync-upstream.sh`. |
| `feature/voice-claude-code` | "OK Coucou" brain and voice web answers use the same login. The brain's tools are served to `claude -p` by a loopback MCP server for the turn (`Voice/ClaudeCodeVoice.swift`). |
| `feature/custom-wake-phrase` | Settings → Voice → "Wake phrase": say your own phrase instead of "OK Coucou". Tests: `scripts/test-custom-wake-phrase.sh`. |
| `feature/voice-music-weather` | Voice fixes: music goes to the player in use (Spotify no longer opens Apple Music), Spotify found by bundle id (also `~/Applications`), songs on Spotify play through an open.spotify.com link Claude finds by web search; Settings → Voice → "Your city" gives the CLI brain Open-Meteo weather and a location. |
| `feature/run-in-background` | Flow → Settings → App → "Run in background" (the upstream "Show in Dock" setting, inverted): no Dock icon or ⌘-Tab, and ⌘Q / Dock Quit / closing only hide. "Quit Coucou completely", the menu-bar Quit, Restart and logout still stop it (`BackgroundMode.swift`). `custom-install.sh` stops Coucou with SIGTERM for that reason. |
| `feature/sessions-view` | Per-session tracking (`SessionTracker.swift`, fed from one call in `HookServer.processEvent`) and a tall Sessions view (`SessionsView.swift`, header tab ▤): a tab per session, then what it needs / is doing / answered (subagents, tasks, full answer, prompt, activity). Home card: "‹ 2/3 ›" switcher + expand button, ⌘⇧←/→. Tests: `scripts/test-session-tracker.sh`. |
| `feature/sessions-attention` | Sessions view lists only what needs attention: running/waiting sessions, and finished/failed ones until seen (opening the tab, Open terminal, Details/OK); a session that only opened gets no tab. Fixes sessions stuck in "background". Tapping the home card's step row opens the Sessions view. |
| `feature/quiet-notch` | The notch opens by itself only when a session's work is done (no background agent left, once per prompt, even while a sibling session works) or for permissions and questions. Session start, agents starting/finishing and a turn that left agents running are an ambient pulse: sound, wiggle and a light around the notch (`NotchPulse.swift`, rules in `NotchAlertRules.swift`). Settings → General: open on finish / on error / ambient pulse. Upstream rule kept: no open while the session's terminal is the front app (light only). Tests: `scripts/test-notch-alerts.sh`. |
| `feature/terminal-tab-focus` | "Open terminal" (cards, Sessions view, ↗, ⌃⌥T, Change plan) goes to the session's own tab (`TerminalFocus.swift`); the relay records per-tab handles (`add_terminal_ids` in the GitHub `nb-hook.py`). Settings → Agents → "Default terminal" replaces the hard-coded Terminal.app fallback. Tests: `scripts/test-terminal-focus.sh`. |
| `feature/session-agent-grouping` | Subagents grouped under their session: the home ticker shows the session's own steps plus "▸ 2 agents running"; the Sessions view shows one collapsible "Agents · 2 running" row (each agent and its last steps inside) and keeps their steps out of Activity. The home card's expand button is gone: its title and step row open the Sessions view. |
| `feature/question-fit` | The notch fits each AskUserQuestion page: the card measures itself (`QuestionFit.swift`) and the island animates to it, instead of one estimated height for the tallest question (gaps on short pages, Send clipped on long ones). |
| `chore/no-upstream-updater` | Turns off upstream's self-updater (`MacUpdater.disabledInFork`): it would replace Coucou Custom with the official release. Settings → Updates explains how the fork updates instead. |
| `chore/stable-signing` | `scripts/custom-signing-cert.sh` and a stable signature in `custom-install.sh`, so permissions survive rebuilds. |

Add a row here in the same PR as every new feature.

### What the Sessions view knows per agent
Every agent's hooks reach `SessionTracker` through `HookServer.processEvent`; how much it can show depends on what
each agent sends (checked in the generated plugins in `HookServer.swift`):

| Agent | Prompt | Tool steps | Subagents / todos | Final answer | Ends with |
|---|---|---|---|---|---|
| Claude Code, Claude Desktop, Cursor | ✓ | ✓ | ✓ | ✓ | Stop / SessionEnd |
| Codex | ✓ | ✓ | subagents | if Codex sends it | Stop / Interrupt / SessionEnd |
| Gemini CLI | ✓ | ✓ | – | – | AfterAgent → Stop |
| Copilot CLI, Muse | as sent | ✓ | – | – | Stop / SessionEnd |
| Antigravity | – | ✓ | – | – | Stop |
| OpenCode | – | tool names | – | – | session.idle → Stop |
| Amp, Hermes | – | ✓ | – | Hermes only | Stop (no SessionEnd: the 30-min silence rule ends them) |

PermissionRequest never reaches the tracker (HookServer answers it on its own path); "waiting" comes from
Notification and AskUserQuestion.

### How "Open terminal" finds a session's tab
| Terminal | Handle recorded by the relay | How the tab is focused |
|---|---|---|
| Warp | `WARP_FOCUS_URL` (undocumented, `warp://session/<uuid>`) | open the URL, then activate Warp |
| Terminal.app | tty of the session (first ancestor with one) | AppleScript: tab whose `tty` matches |
| iTerm2 | `ITERM_SESSION_ID` | AppleScript: session whose `unique id` matches |
| Ghostty 1.3+ | session cwd | AppleScript `focus` the terminal with that working directory |
| kitty | `KITTY_WINDOW_ID`, `KITTY_LISTEN_ON` | `kitten @ focus-window` (remote control must be on) |
| WezTerm | `WEZTERM_PANE` | `wezterm cli activate-pane` |
| tmux (inside any) | `TMUX`, `TMUX_PANE` | `select-window` + `select-pane`, then the host tab |
| others / unknown | – | app only (upstream behaviour) |

## Rules for customizations
- **Stay mergeable with upstream.** Put new code in new files (e.g. `ClaudeCodeCLI.swift`) and keep edits to
  upstream files small and local, so upstream syncs rarely conflict. Don't reformat or reorganize upstream code.
- **Never commit `NotchBuddy/NotchBuddy.xcodeproj/project.pbxproj`.** It is generated; a different xcodegen
  version rewrites hundreds of lines and conflicts on every sync. `custom-install.sh` regenerates it and restores it.
- Mac-only features that run local binaries go behind `#if !APPSTORE`; the `CoucouAppStore` scheme must still build.
- Subscription access to Claude only goes through the official `claude` CLI (or Agent SDK). Never read Claude
  Code's OAuth token to call the API directly: Anthropic's terms forbid it.
- `ClaudeCodeCLI` runs `claude` only if it is signed by Anthropic PBC (team `Q6L2SF6YDW`). Keep that check.
- The model list in `ClaudeCodeCLI.models` is fixed (a subscription cannot call `/v1/models`). To refresh it, take
  the `claude-*` IDs from the installed binary (`strings`), send each a one-word prompt with
  `claude -p --model <id>`, and keep the ones whose `modelUsage` reports that same model.
- Keep the bundle ID `fr.louisraille.NotchBuddy` (settings and Keychain items depend on it).

## Build and install
`scripts/custom-install.sh` builds the GitHub variant from the current checkout, signs it, quits the running
copy and installs it as `/Applications/Coucou Custom.app`.

It signs with the local identity "Coucou Custom Local Signing" (self-signed, in the login keychain), created once
per Mac by `scripts/custom-signing-cert.sh`. Keep it: macOS ties Accessibility, microphone and screen-recording
grants to the signature, and an ad-hoc signature changes every build, so those grants would drop after each
install. If the identity is ever recreated, the grants must be given once more. Before handing a change over, also build
`CoucouAppStore` (the script's `--check-appstore` flag does it).

## Staying in sync with upstream
Before starting a new feature, and after any major upstream release, run `scripts/custom-sync-upstream.sh`:
it fetches `upstream`, merges `upstream/main` into `main` (a merge, never a rebase or force push), merges `main`
into every open `feature/*` and `chore/*` branch, and pushes. On a conflict it stops and leaves the merge in
progress: resolve it keeping both upstream's change and ours, build both schemes, then commit and re-run.
Then rebuild with `custom-install.sh`.
