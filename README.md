# Process-tinted WezTerm

A [WezTerm](https://wezterm.org) config that brings Ptyxis-style "danger tinting" to tabs, plus saner keys.

| Running in the tab | Tab + header color |
|---|---|
| `sudo`, `su`, `doas`, `run0`, `pkexec` | red `#c01c28` |
| `ssh`, `mosh`, `et`, `telnet`, `scp`, `sftp` | purple `#613583` |
| `claude` (Claude Code) | orange `#d97757` |

- Each tab is colored by its own foreground process. The header (title bar) follows the active tab.
- **Ctrl+C** copies if text is selected, otherwise sends ^C (interrupt). **Ctrl+V** pastes. Ctrl+Shift+C/V still work.
- **Ctrl+Shift+E** (Cmd+Shift+E on macOS) sets the *entire* tab title, which won't get overwritten by programs. Enter an empty title to go back to the automatic one.

## Install

Linux (Fedora: `sudo dnf install wezterm` from the WezTerm COPR / Flatpak; Ubuntu: WezTerm apt repo) or macOS (`brew install --cask wezterm`), then:

```sh
mkdir -p ~/.config/wezterm
ln -sf "$PWD/wezterm.lua" ~/.config/wezterm/wezterm.lua
```

WezTerm reloads the config automatically when the file changes.

If you use the **Flatpak** build on Linux, the terminal runs inside a sandbox and process detection may not see host processes. Prefer the native package.

## Customize

Colors, process lists and keys live at the top of `wezterm.lua` (`KIND_COLORS`, `SUPERUSER`, `REMOTE`, `config.keys`).

## Limitations

- Claude running *on a remote machine* over ssh shows as remote (purple), because only local processes are visible.
- Colors update by polling (every 0.5 s while the window is focused), so expect a short lag.
- `sudo` detection relies on WezTerm reading process info for a root-owned `sudo` process. This works on Linux (`/proc/<pid>/comm` is world-readable) but is untested on macOS.
