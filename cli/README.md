# omaclean

面向 Omarchy / Arch Linux 的安全清理工具：流式清理系统缓存、日志、临时文件与项目构建产物。


## 为什么做这个

Arch 上不缺清理脚本，缺的是敢放心跑的。常见脚本上来就是 `rm -rf ~/.cache/*` 或 `sudo rm -rf /tmp/*`：正在运行的软件还持有缓存数据库，删完可能出问题；一条命令下去，删的也未必只是缓存。

omaclean 坚持的安全原则：

- 整个程序以普通用户运行，先完成只读扫描与选择，只有最终选中的 `paccache`、`journalctl`、`systemd-tmpfiles` 系统项才请求 sudo；跳过提权后仍可清理用户项；
- 严密的路径安全边界：所有删除目标必须落在允许的根目录内，且不在系统目录与 `/tmp` 之下，符号链接一律跳过；
- 不整体清空 `~/.cache` 和 `/tmp`：临时文件交给 systemd 的过期策略，用户缓存按已知清单逐项处理；
- 每次操作写入状态目录的 `omaclean/operations.log`（遵循 `XDG_STATE_HOME`，默认 `~/.local/state`），用 `omaclean history` 查看。

## 安装

CLI 随 [omaclean 插件仓库](https://github.com/tenngoxars/omarchy-omaclean) 一起发布：

```bash
omarchy plugin add https://github.com/tenngoxars/omarchy-omaclean.git --enable
ln -s ~/.config/omarchy/plugins/zykyaka.omaclean/cli/omaclean ~/.local/bin/omaclean
```

依赖：`gum`、`fzf`、`pacman-contrib`（`paccache`），Omarchy 已预装；其他 Arch 发行版执行 `sudo pacman -S gum fzf pacman-contrib`。

## 使用

```bash
omaclean                  # 交互主菜单（↑↓/1-4 移动，→ 进入，← 退出；子功能结束后 ← 回主菜单，→ 退出）
omaclean clean            # Scan → Review → Clean → Summary
omaclean analyze          # clean 的兼容别名，参数与行为相同
omaclean clean --dry-run  # 只读扫描，到汇总即止，不进入评审或删除
omaclean clean --select   # 扫描后直接打开行内复选评审
omaclean clean --trash    # 将回收站纳入可选项（默认保护）
omaclean clean --json     # 以 JSON 输出扫描结果（只读；供状态栏插件等消费方）
omaclean clean --exec a,b # 非交互清理指定 id（系统项经 polkit 图形认证提权）
omaclean purge            # 行内交互清理项目构建产物（node_modules、target 等）
omaclean purge --json     # 以 JSON 输出构建产物候选（含默认预选）
omaclean purge --exec p…  # 非交互清理给定候选路径（仅接受本轮扫描到的候选）
omaclean purge --dry-run  # 列出全部候选与默认选择
omaclean purge --age 0    # 将全部候选设为默认选中
omaclean remove           # 卸载软件（Omarchy 包选择器或 pacman 原生确认）
omaclean history          # 查看清理操作审计日志
```

### Analyze & Clean

主菜单只保留一个「Analyze & Clean」入口；`omaclean clean` 与 `omaclean analyze` 进入同一条流程。扫描报告只在分类下列出本轮可选项，运行中的浏览器缓存和默认保护的回收站单独放在「Not selectable this run」，不会混入可清理合计。

扫描后：用 `↑↓` 在「逐项挑选 / 全部清理 / 取消」间移动，`Enter` 确认（默认高亮「逐项挑选」，`←` 可直接取消）。进入逐项列表后同样用 `↑↓` 移动，`Space` 切换勾选，`a` 全选/全不选，`Enter` 确认（无整屏刷新、无闪烁光标）。列表默认勾选可安全重建的缓存，systemd journal 默认不选。系统项需 sudo 时：`←` 跳过、`→` 继续。只有最终选择包含系统项时才请求 sudo。

1. **Package Management**：Pacman 缓存（`paccache -rk2`，保留 2 个版本）、AUR 构建缓存（yay / paru）
2. **System**：systemd journal（压缩至 100MiB）、经 `systemd-tmpfiles --clean --dry-run` 确认并计量的过期文件
3. **User Caches**：缩略图缓存、回收站、浏览器缓存
4. **Developer Caches**：npm、Cargo 注册表、uv、pip、Go 构建缓存、Bun 缓存

确认前不删除任何内容；管道或非交互运行只输出报告。

### Purge 行内复选

`omaclean purge` 扫描 `~/Projects`、`~/dev`、`~/GitHub`、`~/src`：
- 识别 `node_modules`、`target`、`dist`、`build`、`.next`、`.venv`、`__pycache__`、`.turbo`
- 所有候选都会显示；默认预选（`●`）7 天前改动的老旧产物，近期产物保持未选（`○`），`--age N` 只改变预选阈值
- 自动跳过含 `.git` 的嵌套目录；使用 `↑↓` 移动、`Space` 切换、`a` 全选/全不选、`Enter` 确认

## 配置

```bash
# ~/.config/omaclean/purge_paths：每行一个扫描根目录，# 开头为注释；存在此文件时忽略默认目录
~/Projects
~/dev
```

扫描根必须是绝对路径（`~` 会被展开）；`/`、`/home` 这类过宽目录会被自动过滤。

## 刻意不做的事

- 不做「一键优化」：Linux 不需要靠重建缓存「提速」，那是给用户看的表演；
- 不自动删除软件残留：包名和配置目录没有可靠的一一映射，错删的后果比留下的垃圾严重；
- 不内置系统监控面板：直接调用 `btop`；
- 不往 `/usr/share/omarchy` 里塞命令：那是系统包目录，更新会被覆盖。

## 验证

```bash
bash -n omaclean lib/*.sh tests/*.sh
bash tests/safety.sh
bash tests/keys.sh
bash tests/clean_flow.sh
```

## 许可

MIT。
