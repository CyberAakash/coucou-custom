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
| `chore/stable-signing` | `scripts/custom-signing-cert.sh` and a stable signature in `custom-install.sh`, so permissions survive rebuilds. |

Add a row here in the same PR as every new feature.

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
