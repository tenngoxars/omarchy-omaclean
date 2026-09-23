# omaclean

**Safe cleanup for the Omarchy bar** — see what's reclaimable, pick what to clean, and run it without leaving the panel.

## What it does

- **Bar chip** — trash icon + reclaimable size; left-click opens the panel, right-click rescans.
- **Panel**
  - `Caches` view: system caches, journals and developer caches with checkboxes and safe defaults preselected (the journal stays unchecked).
  - `Artifacts` view: project build directories (`node_modules`, `target`, `dist`, `.turbo`, …) with `Size` / `Age` sorting and 7-day+ preselection.
  - `Clean` / `Purge` runs the current selection in place; admin items pass only an item id to a root-owned admin component (`omaclean-priv`) through polkit — the fixed commands are chosen by that component, never by user-writable plugin code.
- **Keyboard** — `a` select all / none, `r` refresh, `Esc` close.
- **IPC** for shortcuts: `omarchy-shell zykyaka.omaclean toggle|refresh|clean <ids>|purge`.

## Install

```bash
omarchy plugin add https://github.com/tenngoxars/omarchy-omaclean.git --enable
ln -s ~/.config/omarchy/plugins/zykyaka.omaclean/cli/omaclean ~/.local/bin/omaclean
omaclean install-privileges   # admin items only; sudo once
```

The second line links the bundled `omaclean` CLI (the `cli/` directory) onto your PATH.
The plugin drives it through its JSON scan and `--exec` interfaces; every path-safety
rule lives in the CLI. Full CLI reference: [`cli/README.md`](cli/README.md).

The third line installs the root-owned admin component that admin items (pacman cache,
journal, expired tmpfiles) run through. Skip it and only those items fail, with the
command to install it in the message; user-level cleanup works without it.

## Requirements

- The bundled `omaclean` CLI, linked as shown above. It needs `gum`, `fzf` and
  `pacman-contrib` — all preinstalled on Omarchy (`sudo pacman -S gum fzf pacman-contrib`
  elsewhere).
- `polkit` / `pkexec` (part of the base system) for admin items.
- The admin component from `omaclean install-privileges` (admin items only).

## External dependencies and system-level modifications

- `omaclean install-privileges` writes exactly two root-owned files, once, through sudo:
  - `/usr/local/lib/omaclean/omaclean-priv` — maps the ids `pacman`, `journal`, `tmp` to fixed commands
  - `/usr/share/polkit-1/actions/com.omaclean.clean.policy` — binds the polkit action `com.omaclean.clean` to that file
- Everything else stays user-level: the CLI symlink above, and state in
  `~/.local/state/omaclean/operations.log` (the CLI's audit log).

## Uninstall

```bash
omarchy plugin remove zykyaka.omaclean
rm -f ~/.local/bin/omaclean
sudo rm -f /usr/local/lib/omaclean/omaclean-priv /usr/share/polkit-1/actions/com.omaclean.clean.policy
```

## License

MIT
