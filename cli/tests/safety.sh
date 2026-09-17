#!/bin/bash
# omaclean 安全语义自检：删除校验、符号链接跳过、越界拒绝、purge 根过滤与操作日志。
# 用法：bash tests/safety.sh

set -euo pipefail

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# 沙箱建在真实家目录下（/tmp 属于删除禁区），并在其中运行，避免触碰真实环境
REAL_HOME=$HOME
SANDBOX=$(mktemp -d "$REAL_HOME/.omaclean-safety.XXXXXX")
trap 'rm -rf -- "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
export XDG_STATE_HOME="$SANDBOX/state"
mkdir -p "$HOME" "$SANDBOX/other"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
# shellcheck source=lib/clean.sh
source "$ROOT/lib/clean.sh"
# shellcheck source=lib/purge.sh
source "$ROOT/lib/purge.sh"
# shellcheck source=lib/tools.sh
source "$ROOT/lib/tools.sh"

FAILED=0
case "$OMACLEAN_LOG_FILE" in
    "$SANDBOX"/*) ;;
    *)
        printf 'FAIL OMACLEAN_LOG_FILE escaped the sandbox: %s\n' "$OMACLEAN_LOG_FILE"
        FAILED=1
        ;;
esac

check() { # check <desc> <expected-rc> <cmd...>
    local desc=$1 expected_rc=$2
    shift 2
    local rc=0
    "$@" > /dev/null 2>&1 || rc=$?
    if [[ $rc -eq $expected_rc ]]; then
        printf 'ok   %s\n' "$desc"
    else
        printf 'FAIL %s (rc=%s, expected %s)\n' "$desc" "$rc" "$expected_rc"
        FAILED=1
    fi
}

# ── 特权边界：只接受固定 root-owned 程序，不保留脚本提权入口 ──────
FAKE_ADMIN="$SANDBOX/fake-admin"
printf '#!/bin/bash\nexit 0\n' > "$FAKE_ADMIN"
chmod +x "$FAKE_ADMIN"
check 'accept root-owned system executable' 0 trusted_root_executable /usr/bin/journalctl
check 'refuse user-owned executable' 1 trusted_root_executable "$FAKE_ADMIN"
check 'refuse unknown system cleanup item' 2 execute_pkexec_system_item unknown
check 'remove elevated script entry point' 1 "$ROOT/omaclean" _sys journal

ROOT_GUARD_DIR="$SANDBOX/root-guard"
ROOT_SOURCE_MARKER="$SANDBOX/root-sourced"
mkdir -p "$ROOT_GUARD_DIR/lib"
cp "$ROOT/omaclean" "$ROOT_GUARD_DIR/omaclean"
printf 'touch -- "%s"\n' "$ROOT_SOURCE_MARKER" > "$ROOT_GUARD_DIR/lib/common.sh"
root_rc=0
unshare --user --map-root-user "$ROOT_GUARD_DIR/omaclean" --version > /dev/null 2>&1 || root_rc=$?
if [[ $root_rc -eq 1 && ! -e $ROOT_SOURCE_MARKER ]]; then
    printf 'ok   reject root before sourcing user-writable code\n'
else
    printf 'FAIL root guard ran after user-writable code (rc=%s)\n' "$root_rc"
    FAILED=1
fi

# ── 目标校验 ──────────────────────────────────────────────────
mkdir -p "$HOME/cache/sub"
printf 'data' > "$HOME/cache/file"
ln -s /etc "$HOME/cache/link-out"
ln -s "$HOME/cache/file" "$HOME/cache/link-in"

check 'refuse /'             1 assert_deletable / "$HOME/cache"
check 'refuse home dir'      1 assert_deletable "$HOME" "$HOME"
check 'refuse symlink'       1 assert_deletable "$HOME/cache/link-out" "$HOME/cache"
check 'refuse outside root'  1 assert_deletable "$HOME/cache/sub" "$SANDBOX/other"
check 'refuse root itself'   1 assert_deletable "$HOME/cache/sub" "$HOME/cache/sub"
check 'refuse /usr prefix'   1 assert_deletable /usr/bin/ls /usr
check 'refuse /etc prefix'   1 assert_deletable /etc/hostname /etc
check 'allow nested entry'   0 assert_deletable "$HOME/cache/sub" "$HOME/cache"
check 'allow file entry'     0 assert_deletable "$HOME/cache/file" "$HOME/cache"

# ── 清空目录内容：跳过符号链接，保留目录本身 ──────────────────
freed=$(clear_dir_contents "$HOME/cache")
if [[ -d "$HOME/cache" && -L "$HOME/cache/link-out" && -L "$HOME/cache/link-in" &&
    ! -e "$HOME/cache/file" && ! -e "$HOME/cache/sub" ]]; then
    printf 'ok   clear_dir_contents keeps dir, skips symlinks\n'
else
    printf 'FAIL clear_dir_contents semantics\n'
    FAILED=1
fi
if [[ $freed =~ ^[0-9]+$ && $freed -gt 0 ]]; then
    printf 'ok   clear_dir_contents reports freed bytes (%s)\n' "$freed"
else
    printf 'FAIL clear_dir_contents freed bytes not reported\n'
    FAILED=1
fi

# ── delete_tree：越界拒绝、正常删除 ───────────────────────────
mkdir -p "$SANDBOX/other/artifact/data"
printf 'x' > "$SANDBOX/other/artifact/data/f"
check 'delete_tree refuses outside root' 1 delete_tree "$SANDBOX/other/artifact" "$HOME/cache"
if out=$(delete_tree "$SANDBOX/other/artifact" "$SANDBOX/other"); then
    if [[ ! -e "$SANDBOX/other/artifact" ]]; then
        printf 'ok   delete_tree removes validated tree (freed=%s)\n' "$out"
    else
        printf 'FAIL delete_tree left path behind\n'
        FAILED=1
    fi
else
    printf 'FAIL delete_tree refused a valid target\n'
    FAILED=1
fi

# ── purge 根过滤：只保留安全的绝对根 ──────────────────────────
mkdir -p "$SANDBOX/good" "$HOME/.config/omaclean"
printf '%s\n' "/" "relative/path" "/nonexistent-omaclean-root" "$SANDBOX/good" > "$HOME/.config/omaclean/purge_paths"
roots=$(purge_roots 2> /dev/null)
if [[ $roots == "$SANDBOX/good" ]]; then
    printf 'ok   purge_roots keeps only the safe absolute root\n'
else
    printf 'FAIL purge_roots output: %s\n' "$roots"
    FAILED=1
fi

# ── purge 近期产物：显示但默认未选 ─────────────────────────────
mkdir -p "$SANDBOX/good/old/node_modules" "$SANDBOX/good/recent/dist"
printf 'old' > "$SANDBOX/good/old/node_modules/file"
printf 'recent' > "$SANDBOX/good/recent/dist/file"
touch -d '10 days ago' "$SANDBOX/good/old/node_modules"
purge_output=$(cmd_purge --dry-run --age 7)
if grep -q 'old/node_modules' <<< "$purge_output" &&
    grep -q 'recent/dist' <<< "$purge_output" &&
    grep -q 'recent artifact(s) shown unselected' <<< "$purge_output" &&
    grep -q 'Candidates: 2' <<< "$purge_output"; then
    printf 'ok   purge shows recent artifacts without preselecting them\n'
else
    printf 'FAIL purge recent-artifact selection flow\n'
    FAILED=1
fi

# ── 操作日志 ──────────────────────────────────────────────────
log_op test REMOVED /var/log/omaclean-example 123
if grep -q 'REMOVED /var/log/omaclean-example (123 bytes)' "$OMACLEAN_LOG_FILE"; then
    printf 'ok   log_op writes the operation log\n'
else
    printf 'FAIL log_op log line missing\n'
    FAILED=1
fi

# ── remove 回退：交给 pacman 原生事务确认 ─────────────────────
REMOVE_STUBS="$SANDBOX/remove-bin"
REMOVE_LOG="$SANDBOX/remove.log"
export REMOVE_LOG
mkdir -p "$REMOVE_STUBS"
cat > "$REMOVE_STUBS/pacman" <<'EOF'
#!/bin/bash
[[ ${1:-} == -Qqe ]] && printf 'example-package\n'
EOF
cat > "$REMOVE_STUBS/fzf" <<'EOF'
#!/bin/bash
printf 'example-package\n'
EOF
cat > "$REMOVE_STUBS/omarchy" <<'EOF'
#!/bin/bash
[[ $* == 'pkg remove' ]]
EOF
cat > "$REMOVE_STUBS/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" > "$REMOVE_LOG"
EOF
chmod +x "$REMOVE_STUBS"/*
PATH="$REMOVE_STUBS:$PATH"

if [[ $(cmd_remove; printf 'returned') == returned ]]; then
    printf 'ok   remove returns after the Omarchy picker closes\n'
else
    printf 'FAIL remove replaced the parent menu process\n'
    FAILED=1
fi
has_cmd() {
    [[ $1 == omarchy ]] && return 1
    command -v "$1" > /dev/null 2>&1
}
if cmd_remove && [[ $(cat "$REMOVE_LOG") == 'pacman -Rns -- example-package' ]]; then
    printf 'ok   remove fallback keeps pacman transaction confirmation\n'
else
    printf 'FAIL remove fallback bypassed pacman confirmation\n'
    FAILED=1
fi

printf '\n'
if ((FAILED)); then
    printf 'safety self-check FAILED\n'
    exit 1
fi
printf 'safety self-check passed\n'
