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

## 安装

插件与普通用户权限的 CLI：

```bash
omarchy plugin add https://github.com/tenngoxars/omarchy-omaclean.git --enable
ln -s ~/.config/omarchy/plugins/zykyaka.omaclean/cli/omaclean ~/.local/bin/omaclean
```

系统清理项（pacman 缓存、journal、过期 tmpfiles）需另行安装特权组件。**从审查记录独立取得并核对完整 40 位提交 SHA**，不要从本机插件目录或它打印的命令取值。以下命令只从该提交检出到 root 控制的目录；安装器再次核对提交、两个文件的 SHA-256，并先安装版本化 helper、最后原子发布 policy：

```bash
read -r -p '受审查的 40 位提交 SHA：' REVIEWED_SHA
sudo env -i HOME=/root PATH=/usr/bin:/bin git clone --no-checkout https://github.com/tenngoxars/omarchy-omaclean.git "/root/omaclean-install-$REVIEWED_SHA"
sudo env -i HOME=/root PATH=/usr/bin:/bin git -C "/root/omaclean-install-$REVIEWED_SHA" checkout --detach "$REVIEWED_SHA"
sudo env -i HOME=/root PATH=/usr/bin:/bin bash "/root/omaclean-install-$REVIEWED_SHA/cli/install-privileges" "$REVIEWED_SHA"
```

首次安装时，没有经过核验的特权组件则系统项不可用；用户缓存和构建产物清理不受影响。CLI 参考见 [`cli/README.md`](cli/README.md)。

旧版 `omaclean install-privileges` 从可变 checkout 安装的组件不满足此边界；升级后必须按上述步骤重新安装。新安装器切换 policy 后会移除旧的固定路径 helper。

## 依赖

- CLI 依赖 `gum`、`fzf` 和 `pacman-contrib`；Omarchy 默认提供。
- 系统项另需 `polkit` / `pkexec` 和上述特权组件。

## 系统级改动

- `/usr/local/lib/omaclean/omaclean-priv-<SHA-256>`：root 属主的固定命令映射器；旧版本在 policy 切换后仍保留，供失败回滚。
- `/usr/share/polkit-1/actions/com.omaclean.clean.policy`：最后原子替换，绑定到已安装的版本化 helper。
- 插件检出和用户目录不参与提权安装。其他状态文件仅写入用户的 `~/.local/state/omaclean/`。

## 卸载

先撤销 policy，再删除已安装的 helper；卸载插件不会自动清理 root 文件：

```bash
sudo rm -f -- /usr/share/polkit-1/actions/com.omaclean.clean.policy
sudo rm -f -- /usr/local/lib/omaclean/omaclean-priv-*
rm -f -- ~/.local/bin/omaclean
omarchy plugin remove zykyaka.omaclean
```

## License

MIT
