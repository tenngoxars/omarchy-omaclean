# omaclean

**Safe cleanup for the Omarchy bar** — see what's reclaimable, pick what to clean, and run it without leaving the panel.

## What it does

- **Bar chip** — trash icon + reclaimable size; left-click opens the panel, right-click rescans.
- **Panel**
  - `Caches` view: system caches, journals and developer caches with checkboxes and safe defaults preselected (the journal stays unchecked).
  - `Artifacts` view: project build directories (`node_modules`, `target`, `dist`, `.turbo`, …) with `Size` / `Age` sorting and 7-day+ preselection.
  - `Clean` / `Purge` runs the current selection in place; admin items (pacman cache, journal, tmpfiles) go through the standard polkit password prompt — the terminal is never involved.
- **Keyboard** — `a` select all / none, `r` refresh, `Esc` close.
- **IPC** for shortcuts: `omarchy-shell zykyaka.omaclean toggle|refresh|clean <ids>|purge`.

## Install

```bash
omarchy plugin add https://github.com/tenngoxars/omarchy-omaclean.git --enable
ln -s ~/.config/omarchy/plugins/zykyaka.omaclean/cli/omaclean ~/.local/bin/omaclean
```

The second line links the bundled `omaclean` CLI (the `cli/` directory) onto your PATH.
The plugin drives it through its JSON scan and `--exec` interfaces; every path-safety
rule lives in the CLI. Full CLI reference: [`cli/README.md`](cli/README.md).

## Requirements

- The bundled `omaclean` CLI, linked as shown above. It needs `gum`, `fzf` and
  `pacman-contrib` — all preinstalled on Omarchy (`sudo pacman -S gum fzf pacman-contrib`
  elsewhere).
- `polkit` / `pkexec` (part of the base system) for admin items.

## External dependencies and system-level modifications

- No system-level changes beyond the symlink above.
- State is limited to `~/.local/state/omaclean/operations.log` (the CLI's audit log).

## Uninstall

```bash
omarchy plugin remove zykyaka.omaclean
rm -f ~/.local/bin/omaclean
```

## License

MIT
