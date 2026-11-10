# omnishell-agent-usage

An [OmniWM](https://github.com/OmniNull/OmniWM) bar widget that shows how much of your AI coding
subscriptions you have used. The bar shows the provider closest to its limit; clicking it opens a
panel with every rate window, its reset countdown, and spend against your budget.

It works with Codex, Cursor and GitHub Copilot out of the box, and with any other provider that
[CodexBar](https://github.com/steipete/CodexBar) can read (OpenRouter, Claude, Gemini and so on).

## Requirements

- macOS on Apple silicon or Intel
- OmniWM 0.8 or later (the version that ships OmniShell widgets)

## Install

```sh
git clone https://github.com/voydz/omnishell-agent-usage.git
cd omnishell-agent-usage
./install.sh
```

Then:

1. Add `agent-usage` to a bar lane, either in Settings > Styles & Widgets > Bar > Add Widget or by
   adding it to a lane list such as `trailing` in `~/.config/omniwm/shell/shell.toml`:

   ```toml
   trailing = ["agent-usage", "volume", "wifi"]
   ```

2. Allow the widget to reach `127.0.0.1` when OmniWM asks.
3. Set up the providers you want (next section).

Keep the checkout. To update, run `git pull && ./install.sh`.

## Providers

The installer puts the CodexBar CLI here. An alias saves typing:

```sh
alias codexbar=~/.local/share/omnishell-agent-usage/codexbar/current/codexbar
```

| Provider | ID | Setup |
| --- | --- | --- |
| Codex | `codex` | Sign in to the Codex CLI (`codex login`). |
| Cursor | `cursor` | Be signed in to the Cursor app, or to cursor.com in a browser CodexBar can read. |
| GitHub Copilot | `copilot` | `codexbar config login --provider copilot` (GitHub device login). |
| OpenRouter | `openrouter` | `printf '%s' "$OPENROUTER_API_KEY" \| codexbar config set-api-key --provider openrouter --stdin` |

`codexbar config providers` lists every provider ID. `codexbar usage --provider <id>` reads one
provider in the terminal, which is the quickest way to find out why it shows an error in the widget.
The [CodexBar docs](https://github.com/steipete/CodexBar/tree/main/docs) describe where each
provider's data comes from.

The widget shows Codex, Cursor and Copilot unless you change its `providers` option.

## Options

Change these in OmniWM's widget settings, or under your profile's `widgets` table in `shell.toml`:

```toml
[profiles.default.widgets.agent-usage]
providers = ["codex", "cursor", "copilot", "openrouter"]
refresh = 300
```

| Option | Default | Meaning |
| --- | --- | --- |
| `providers` | `["codex", "cursor", "copilot"]` | CodexBar provider IDs, in the order they appear. Up to 12. |
| `percent` | `true` | Show the percentage next to the icon. |
| `refresh` | `120` | Seconds between refreshes, from 60 to 3600. |
| `port` | `18487` | Port of the CodexBar server. Match it to `./install.sh --port`. |

## What it shows

**On the bar:** an icon and the highest usage among your providers. It turns to the warning colour
at 80 % and to the error colour at 100 %. The tooltip lists each provider's figure.

A provider's figure is the highest of its main rate windows, such as the Codex session and weekly
windows or Cursor's total. Two kinds of window appear in the panel without driving the bar: lanes
that split a main window (Cursor's "Third Party" share resets together with its total) and extra
windows a provider reports on the side. A provider with no rate windows, such as Copilot Business,
shows its detail rows in the panel and leaves the bar figure alone.

**In the panel:** one card per provider with its plan, a meter and reset countdown per window, spend
against the limit where the provider reports one, and the figures a provider charts (OpenRouter's
spend today, this week and this month). Everything else a provider reports sits behind "Details",
so a card stays short; a provider with no meters shows its first three rows directly.

The button in the header fetches fresh numbers. A card is marked "Stale" when its last refresh
failed and it is showing older numbers, and the error is shown with it.

## How it works

OmniShell bar widgets cannot run programs, but they can make HTTP requests to hosts they declare.
So the installer sets up three things:

- The CodexBar CLI, at the release pinned in `codexbar.lock`. It is downloaded from the upstream
  GitHub release and its SHA-256 is checked against the lock file before it is unpacked.
- A LaunchAgent, `io.github.voydz.omnishell-agent-usage`, that runs
  `codexbar serve --host 127.0.0.1 --port 18487` at login and restarts it if it crashes.
- The widget, which asks that server for `GET /usage?provider=<id>` once per provider.

| What | Where |
| --- | --- |
| CodexBar CLI | `~/.local/share/omnishell-agent-usage/codexbar/` |
| LaunchAgent | `~/Library/LaunchAgents/io.github.voydz.omnishell-agent-usage.plist` |
| Server log | `~/Library/Logs/omnishell-agent-usage/serve.log` |
| Widget | `~/.config/omniwm/shell/widgets/agent-usage/` |
| CodexBar config (yours, shared with the CodexBar app) | `~/.config/codexbar/config.json` |

Things worth knowing before you install:

- The server listens on loopback only and has no authentication. Any program running on your Mac
  can read your usage figures and account e-mail addresses from it.
- CodexBar's CLI releases are ad-hoc signed, not notarized by Apple. The installer downloads the
  tarball with `curl`, so Gatekeeper does not check it; the checksum in `codexbar.lock` is what ties
  the download to a known release.
- The LaunchAgent gets the `PATH` of your login shell as it was at install time, because the server
  runs provider CLIs such as `codex`. Run `./install.sh` again after installing one in a new place.

## Status, update, uninstall

```sh
./install.sh status       # pinned and installed version, LaunchAgent, server, widget
./install.sh              # install or update to the pinned version
./install.sh --port 18500 # use another port (set the widget's port option to match)
./install.sh uninstall
```

Uninstalling removes the LaunchAgent, the CLI, the log and the widget. It leaves three things for
you: `agent-usage` in your bar lanes, the widget's entry under Settings > Network & Permissions, and
the CodexBar config in `~/.config/codexbar`.

## Troubleshooting

- **"The CodexBar server is not answering"**: run `./install.sh status`, read the server log, and
  run `./install.sh` again to restart it.
- **"Allow this widget to reach 127.0.0.1"**: approve the prompt, or change the widget's entry
  under Settings > Network & Permissions.
- **A provider shows an error**: the text comes from CodexBar. Run
  `codexbar usage --provider <id>` to see it in full.
- **The widget does not appear**: OmniShell logs load errors to the unified log.

  ```sh
  log show --last 5m --style compact --predicate 'process == "OmniWM" AND category == "shell"'
  ```

## Limits

- One account per provider: the first one CodexBar reports.
- No token counts or cost history, only the usage and spend the provider reports for the current
  period.
- macOS only, like OmniWM.

## Development

```sh
./install.sh --link               # symlink the widget to this checkout; OmniWM reloads it on save
luau tests/model_test.luau        # tests for the parsing in widget/agent-usage/model.luau
shellcheck install.sh scripts/*.sh
```

- `widget/agent-usage/init.luau` holds the polling loop, the bar slot and the panel.
- `widget/agent-usage/model.luau` turns a CodexBar payload into what the widget draws. It has no
  OmniShell dependencies, which is why it can be tested with the plain
  [Luau](https://luau.org) CLI.
- `widget/agent-usage/settings.toml` declares the options and the network permission.

### Bumping CodexBar

A scheduled workflow checks for a new CodexBar release every Monday and opens a pull request that
updates `codexbar.lock`. To do it by hand:

```sh
./scripts/bump-codexbar.sh          # latest release
./scripts/bump-codexbar.sh 0.84.0   # a specific one
```

The workflow needs "Allow GitHub Actions to create and approve pull requests" enabled under the
repository's Settings > Actions > General. GitHub pauses scheduled workflows in repositories with
no activity for 60 days.

## Credits and licence

MIT, see [LICENSE](LICENSE).

The usage data comes from [CodexBar](https://github.com/steipete/CodexBar) by Peter Steinberger,
also MIT. This repository does not bundle it; the installer downloads the official release. The
idea follows the agent usage indicator in [Omarchy](https://omarchy.org).
