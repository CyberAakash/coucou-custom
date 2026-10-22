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
| `feature/run-in-background` | Superseded by `feature/cmdw-soft-close`: **⌘W** closes Coucou's window and Coucou keeps running in the notch and menu bar without a Dock icon (.accessory while no window is open); **⌘Q** quits for real (so do the menu-bar Quit, Restart and logout). Coucou is a regular Dock app while its window is open (`BackgroundMode.swift`; `FlowHubController.show` rejoins the Dock). The "Run in background" switch and "Quit Coucou completely" button are gone. |
| `feature/sessions-view` | Per-session tracking (`SessionTracker.swift`, fed from one call in `HookServer.processEvent`) and a tall Sessions view (`SessionsView.swift`, header tab ▤): a tab per session, then what it needs / is doing / answered (subagents, tasks, full answer, prompt, activity). Home card: "‹ 2/3 ›" switcher + expand button, ⌘⇧←/→. Tests: `scripts/test-session-tracker.sh`. |
| `feature/sessions-attention` | Sessions view lists only what needs attention: running/waiting sessions, and finished/failed ones until seen (opening the tab, Open terminal, Details/OK); a session that only opened gets no tab. Fixes sessions stuck in "background". Tapping the home card's step row opens the Sessions view. |
| `feature/session-chat-input` | Sessions view: a message box per session (`TerminalInput.swift`). Never switches app or tab. First choice (`feature/session-message-socket`): the session's cross-session inbox socket (`CLAUDE_CODE_MESSAGING_SOCKET`/`_TOKEN`, recorded by the relay; token kept in memory only) - Claude reads the message between tool calls when busy, starts a turn when idle; it arrives as "Message from …" (can't approve permissions). Fallback: iTerm2 `write text`, Terminal.app `do script`, tmux, kitty, WezTerm. Disabled while a question/permission dialog is up. |
| `feature/question-queue` | Several sessions asking at once: a question that arrives while another is on the card waits in line (`QuestionQueue.swift`, cap 5) instead of displacing it; it comes up when the shown one ends; answered in its own terminal meanwhile, it leaves the line. The card says which session asks and "+N waiting". The home card never shows bare "…": a session with no step yet shows "You asked · …" and its state. Tests: `scripts/test-question-queue.sh`. |
| `feature/question-both-ways` | Questions (AskUserQuestion) are answerable in the notch **and** the terminal at once: the blocking `--ask` PreToolUse hook passes straight through and the card rides on the PermissionRequest (which leaves the terminal dialog on screen); a notch answer becomes allow + `updatedInput {questions, answers}`, a terminal answer dismisses the card on the session's next event (Claude Code leaves the hook running). Settings → Agents toggle. A pending question also holds the notch open (typing "Other…"). |
| `feature/session-message-socket` | Message box via the session's inbox socket (see above); every ambient pulse makes Mochi react (start: surprised, agent start: wink, agents running: proud, done: happy, error: annoyed) with a stronger halo; the finish opens the notch even when the session's terminal is in front (Settings toggle). |
| `feature/quiet-notch` | The notch opens by itself only when a session's work is done (no background agent left, once per prompt, even while a sibling session works) or for permissions and questions. Session start, agents starting/finishing and a turn that left agents running are an ambient pulse: sound, wiggle, Mochi's reaction and a filled spotlight semicircle under the notch (Siri-aura style, mirrored colour blobs) with its own motion per event; a prompt typed in the terminal is a pulse too, not a reveal (`NotchPulse.swift`, rules in `NotchAlertRules.swift`). Settings → General: open on finish / on error / ambient pulse. Upstream rule kept: no open while the session's terminal is the front app (light only). Tests: `scripts/test-notch-alerts.sh`. |
| `feature/terminal-tab-focus` | "Open terminal" (cards, Sessions view, ↗, ⌃⌥T, Change plan) goes to the session's own tab (`TerminalFocus.swift`); the relay records per-tab handles (`add_terminal_ids` in the GitHub `nb-hook.py`). Settings → Agents → "Default terminal" replaces the hard-coded Terminal.app fallback. Tests: `scripts/test-terminal-focus.sh`. |
| `feature/session-agent-grouping` | Subagents grouped under their session: the home ticker shows the session's own steps plus "▸ 2 agents running"; the Sessions view shows one collapsible "Agents · 2 running" row (each agent and its last steps inside) and keeps their steps out of Activity. The home card's expand button is gone: its title and step row open the Sessions view. |
| `feature/question-fit` | The notch fits each AskUserQuestion page: the card measures itself (`QuestionFit.swift`) and the island animates to it, instead of one estimated height for the tallest question (gaps on short pages, Send clipped on long ones). |
| `feature/buddy` | The Buddy: a Mochi of its own on the desktop, in its own window (`BuddyController.swift`), apart from the notch's (the notch keeps its Mochi, outfit and gaze; upstream's drag-Mochi-to-the-desktop and `DesktopMochi.swift` are untouched). Above everything, menu bar included (`.statusBar`, as OpenPets' native panels), on every Space; clicks through except on its body and companions; transparent room around it so hats, emotes and hover are never cut off (`BuddyInsets`). Drag it anywhere, to every edge and up to half off it (its centre stays on a display, as OpenPets' roaming pets; spot kept per display); click to say hi; right-click: Size, Outfit, Companions, React to my agents, Speech bubbles, Buddy Settings…, Hide. Up to 6 companions, the Coucou window banner's mini Mochis, walking on its floor on both sides (`BuddyCompanions.swift`): they nap and cheer with it, blush when clicked. Coucou window → Buddy (`HubBuddyPage`, in the window's own style): live stage, on/off, size (OpenPets' XS–XL), its own outfit, any colour (picker or hex), companions and their colour, react to agents, speech bubbles (OpenPets' cooldowns), eyes follow the cursor, nap when idle. Custom OpenPets pets: removed for now (in 0e3c95a). Tests: `scripts/test-buddy.sh`. |
| `feature/chat-roomy` | The notch chat gets room: 700 pt wide, and as tall as the conversation up to 520 pt (`ChatFit.swift` measures the messages and the composer; one value replaces the five copies of upstream's `min(300, 240 + 40 × messages)`). Mochi is a small avatar at the top-left. One composer holds a multi-line input (Return sends, ⇧Return adds a line), the context chip (✕ drops it), the model chip (friendly name, opens the model picker), mic and send. Replies are full-width text; a "Sources:" list collapses to "Sources · N"; a ↓ button returns to the newest message, and streaming no longer scrolls you down while you read. |
| `feature/spotlight-soft` | The notch spotlight is brightest just under the notch and fades out gradually with no visible edge (an elliptical gradient with a steep falloff, faint colour blobs near the core, a feathered rim); default brightness 55 %. Settings → Behavior → Spotlight: brightness, size, softness, colours (by event / one colour / white), moving colours, breathe while agents run, Preview of each event, Reset (`SpotlightSettings.swift`). |
| `feature/general-page` | Coucou window → General is a page in the window's own style (`FlowHubGeneral.swift`: HubPageScaffold, HubGlowCard, HubCard, HubRow), like Settings and Buddy: a demo hero card; Notch, When it opens by itself, Spotlight, Sound, This Mac, Weekly recap, iPhone and Updates cards with switches on the right. The Spotlight card has a live preview (a notch on a wallpaper, lit by the chosen event on a loop, following the sliders), colour swatches, Reset and Try on the notch. The App Store build keeps SettingsView's generalSection: **a setting upstream adds there must be added to HubGeneralPage too.** |
| `feature/hub-settings-style` | The Settings sections the Coucou window embeds (Agents, Chat, Integrations, Voice, Shortcuts, Active pills) take the window's style through `HubGroupBoxStyle` (small-caps label over a dark card) and `HubSwitchRowStyle` (label left, switch right), applied where FlowHub embeds `SettingsView`; their code is unchanged, and the App Store Settings window keeps the system look. |
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
