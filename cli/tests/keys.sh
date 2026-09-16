#!/bin/bash
# 回归 read_key 的按键映射与主菜单回车路由（pty 下真实输入）。
# 背景：read -n 会自动吃掉作为分隔符的换行，回车必须映射为 ENTER，否则菜单卡死。

set -euo pipefail

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REAL_HOME=$HOME
SANDBOX=$(mktemp -d "$REAL_HOME/.omaclean-keys.XXXXXX")
trap 'tmux kill-session -t omaclean-keys 2> /dev/null || true; rm -rf -- "$SANDBOX"' EXIT

export HOME="$SANDBOX/home"
export XDG_STATE_HOME="$SANDBOX/state"
export TERM=xterm
export NO_COLOR=1
STUBS="$SANDBOX/bin"
mkdir -p "$HOME/.cache/yay" "$STUBS"
dd if=/dev/zero of="$HOME/.cache/yay/payload" bs=1M count=2 status=none

for stub in journalctl paccache sudo systemd-tmpfiles; do
    printf '#!/bin/bash\nexit 0\n' > "$STUBS/$stub"
done
printf '#!/bin/bash\nexit 1\n' > "$STUBS/pgrep"
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

fail() {
    printf 'FAIL %s\n' "$1"
    exit 1
}

# ── 按键映射 ──────────────────────────────────────────────────
DRIVER="$SANDBOX/key-driver"
cat > "$DRIVER" << EOF
#!/bin/bash
source "$ROOT/lib/common.sh"
printf 'MAP:%s\n' "\$(read_key)"
EOF
chmod +x "$DRIVER"

key_map() { # key_map <raw-bytes> <expected>
    local raw=$1 want=$2 got
    got=$(printf '%b' "$raw" | script -qefc "$DRIVER" /dev/null | tr -d '\r' | sed -n 's/.*MAP:\(.*\)/\1/p')
    [[ $got == "$want" ]] || fail "key $raw mapped to '$got', expected '$want'"
}

key_map '\r' ENTER
key_map '\n' ENTER
key_map ' ' SPACE
key_map 'x' OTHER
key_map 'a' ALL
key_map 'A' ALL
key_map 'q' QUIT
key_map '\x1b[A' UP
key_map '\x1b[B' DOWN
key_map '\x1b[C' RIGHT
key_map '\x1b[D' LEFT
key_map 'h' LEFT
key_map 'l' RIGHT
key_map '1' CHAR:1
printf 'ok   read_key maps keys correctly\n'

# 上下移动不应每次整屏清屏重绘（banner 只出现一次）。
nav_output=$(printf '\x1b[A\x1b[A\x1b[B\x1b[D' | script -qefc "$ROOT/omaclean" /dev/null | tr -d '\r')
banner_count=$(grep -c 'omaclean v0.1.0' <<< "$nav_output")
((banner_count == 1)) || fail "arrow navigation redrew banner ${banner_count} times (expected 1)"
printf 'ok   arrow navigation avoids full-screen redraw\n'

# ── 子流程结束后返回主菜单 ───────────────────────────────────
# 输入：→ 进入清理，← 取消，← 返回主菜单，← 退出。
menu_output=$(printf '\x1b[C\x1b[D\x1b[D\x1b[D' | script -qefc "$ROOT/omaclean" /dev/null | tr -d '\r')
grep -q 'Scan Your System' <<< "$menu_output" || fail '→ did not start the Analyze & Clean flow'
grep -q 'Cleanup cancelled' <<< "$menu_output" || fail 'cleanup confirmation prompt did not accept ←'
grep -q 'main menu' <<< "$menu_output" || fail 'completed action did not offer return to main menu'
menu_count=$(grep -c 'Analyze & Clean' <<< "$menu_output")
((menu_count >= 2)) || fail 'cleanup flow exited instead of returning to main menu'
[[ -f $HOME/.cache/yay/payload ]] || fail 'menu flow deleted data without confirmation'
printf 'ok   cleanup flow returns to the main menu\n'

# History 也必须使用同一返回流程。
history_output=$(printf '4\x1b[D\x1b[D' | script -qefc "$ROOT/omaclean" /dev/null | tr -d '\r')
grep -q 'Cleanup History' <<< "$history_output" || fail '4 did not open History'
history_menu_count=$(grep -c 'Analyze & Clean' <<< "$history_output")
((history_menu_count >= 2)) || fail 'History exited instead of returning to main menu'
printf 'ok   History returns to the main menu\n'

# 复选列表重画必须就地更新：相对位移算错会让旧行残留并向下漂移。
# 因此按方向键前后，屏幕上的条目行数必须一致。
if command -v tmux > /dev/null 2>&1; then
    mkdir -p "$HOME/.cache/thumbnails"
    dd if=/dev/zero of="$HOME/.cache/thumbnails/payload" bs=1M count=2 status=none
    tmux kill-session -t omaclean-keys 2> /dev/null || true
    tmux new-session -d -s omaclean-keys -x 100 -y 30 \
        "env HOME=$HOME XDG_STATE_HOME=$XDG_STATE_HOME TERM=xterm-256color NO_COLOR=1 PATH=$PATH $ROOT/omaclean clean --select"
    sleep 2
    count_rows() { tmux capture-pane -p -t omaclean-keys | grep -cE '^ +(➤ |  )[●○] ' || true; }
    rows_before=$(count_rows)
    tmux send-keys -t omaclean-keys Down
    sleep 0.4
    tmux send-keys -t omaclean-keys Space
    sleep 0.4
    rows_after=$(count_rows)
    pane=$(tmux capture-pane -p -t omaclean-keys)
    tmux kill-session -t omaclean-keys 2> /dev/null || true

    ((rows_before > 0)) || fail 'checklist items never appeared on screen'
    [[ $rows_before == "$rows_after" ]] || fail "repaint left stale rows (${rows_before} -> ${rows_after})"
    (( $(grep -c 'Review cleanup items' <<< "$pane") == 1 )) || fail 'checklist header was redrawn instead of updated'
    printf 'ok   checklist repaint updates rows in place\n'
fi

printf '\nkey mapping regression passed\n'
