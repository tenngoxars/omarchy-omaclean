#!/bin/bash

set -euo pipefail

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
REAL_HOME=$HOME
SANDBOX=$(mktemp -d "$REAL_HOME/.omaclean-clean-flow.XXXXXX")
trap 'rm -rf -- "$SANDBOX"' EXIT

export HOME="$SANDBOX/home"
export XDG_STATE_HOME="$SANDBOX/state"
export TERM=xterm
export NO_COLOR=1
export SUDO_LOG="$SANDBOX/sudo.log"
STUBS="$SANDBOX/bin"
mkdir -p "$HOME/.cache/yay" "$HOME/.cache/chromium" \
    "$HOME/.local/share/Trash/files" "$STUBS"
dd if=/dev/zero of="$HOME/.cache/yay/payload" bs=1M count=2 status=none
dd if=/dev/zero of="$HOME/.cache/chromium/payload" bs=1M count=2 status=none
printf 'trash' > "$HOME/.local/share/Trash/files/item"

cat > "$STUBS/journalctl" <<'EOF'
#!/bin/bash
[[ ${1:-} == --disk-usage ]] && printf 'Archived and active journals take up 150.0M in the file system.\n'
EOF
cat > "$STUBS/paccache" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$STUBS/pgrep" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$STUBS/systemd-tmpfiles" <<'EOF'
#!/bin/bash
if [[ " $* " == *" --dry-run "* && -n ${TMPFILES_TARGET:-} ]]; then
    printf 'Would remove "%s"\n' "$TMPFILES_TARGET" >&2
fi
EOF
cat > "$STUBS/sudo" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SUDO_LOG"
exit 1
EOF
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

fail() {
    printf 'FAIL %s\n' "$1"
    exit 1
}

dry_output=$("$ROOT/omaclean" clean --dry-run)
grep -q 'Scan Your System' <<< "$dry_output" || fail 'dry-run did not scan'
grep -q 'Scan complete - no changes made' <<< "$dry_output" || fail 'dry-run summary missing'
[[ -f $HOME/.cache/yay/payload ]] || fail 'dry-run deleted cache data'
grep -q 'Review cleanup items' <<< "$dry_output" && fail 'dry-run opened review'
[[ ! -e $SUDO_LOG ]] || fail 'dry-run requested sudo'
if grep -q 'pip cache' <<< "$dry_output"; then
    fail 'scan listed a tidy target with nothing to reclaim'
fi
grep -q 'Not selectable this run' <<< "$dry_output" || fail 'blocked and protected junk was not separated'
grep -q 'Selectable: 2' <<< "$dry_output" || fail 'blocked or protected junk counted as selectable'
grep -q 'variable' <<< "$dry_output" && fail 'scan still reports unknown variable savings'
grep -q 'pnpm store' <<< "$dry_output" && fail 'scan reports the whole pnpm store as junk'
printf 'ok   dry-run is scan-only\n'

mkdir -p "$HOME/expired"
dd if=/dev/zero of="$HOME/expired/payload" bs=1M count=2 status=none
tmp_output=$(TMPFILES_TARGET="$HOME/expired" "$ROOT/omaclean" clean --dry-run)
grep -q 'Expired temporary files · 2.0MiB' <<< "$tmp_output" || fail 'confirmed tmpfiles target was not measured'
printf 'ok   tmpfiles only reports confirmed reclaimable data\n'

empty_output=$(OMACLEAN_FORCE_EMPTY_SELECTION=1 script -qefc "$ROOT/omaclean clean --select" /dev/null)
grep -q 'No cleanup items selected' <<< "$empty_output" || fail 'empty selection was not reported'
grep -q 'Cleanup cancelled' <<< "$empty_output" && fail 'empty selection was misreported as cancellation'
printf 'ok   empty review selection is reported accurately\n'

flow_output=$(printf '\r' | script -qefc "$ROOT/omaclean clean --select" /dev/null)
scan_line=$(grep -n -m1 'Scan complete' <<< "$flow_output" | cut -d: -f1)
review_line=$(grep -n -m1 'Review cleanup items' <<< "$flow_output" | cut -d: -f1)
[[ -n $scan_line && -n $review_line && $scan_line -lt $review_line ]] || fail 'review opened before scan completed'
[[ ! -e $SUDO_LOG ]] || fail 'user-only selection requested sudo'
grep -q 'systemd journal · freed' <<< "$flow_output" && fail 'irreversible journal cleanup ran by default' 
[[ -d $HOME/.cache/yay && ! -e $HOME/.cache/yay/payload ]] || fail 'selected cache was not cleaned safely'
grep -q 'Cleanup complete' <<< "$flow_output" || fail 'cleanup summary missing'
printf 'ok   scan precedes review and selected cleanup\n'

dd if=/dev/zero of="$HOME/.cache/yay/payload" bs=1M count=2 status=none
rm -f "$SUDO_LOG"
pick_output=$(printf '\r\r' | script -qefc "$ROOT/omaclean analyze" /dev/null)
grep -qi 'pick items' <<< "$pick_output" || fail 'analyze prompt does not offer picking'
scan_p=$(grep -n -m1 'Scan complete' <<< "$pick_output" | cut -d: -f1)
review_p=$(grep -n -m1 'Review cleanup items' <<< "$pick_output" | cut -d: -f1)
[[ -n $scan_p && -n $review_p && $scan_p -lt $review_p ]] || fail 'review opened before the report'
[[ ! -e $SUDO_LOG ]] || fail 'user-only pick requested sudo'
[[ -d $HOME/.cache/yay && ! -e $HOME/.cache/yay/payload ]] || fail 'picked item was not cleaned'
printf 'ok   analyze reports, then cleans only the picked items\n'

dd if=/dev/zero of="$HOME/.cache/yay/payload" bs=1M count=2 status=none
rm -f "$SUDO_LOG"
all_output=$(printf '2\r' | script -qefc "$ROOT/omaclean analyze" /dev/null)
grep -q 'Clean all' <<< "$all_output" || fail 'analyze prompt does not offer clean all'
grep -q 'Skipped system cleanup' <<< "$all_output" || fail 'system items were cleaned without asking'
[[ -d $HOME/.cache/yay && ! -e $HOME/.cache/yay/payload ]] || fail 'clean all did not clean the junk'
grep -q 'Cleanup complete' <<< "$all_output" || fail 'analyze summary missing'
printf 'ok   analyze cleans everything on A and skips sudo on request\n'

dd if=/dev/zero of="$HOME/.cache/yay/payload" bs=1M count=2 status=none
rm -f "$SUDO_LOG"
export OMACLEAN_TEST_ROOT="$ROOT"
export KEY_FILE="$SANDBOX/key-count"
DRIVER="$SANDBOX/skip-sudo"
cat > "$DRIVER" <<'EOF'
#!/bin/bash
set -euo pipefail
source "$OMACLEAN_TEST_ROOT/lib/common.sh"
source "$OMACLEAN_TEST_ROOT/lib/clean.sh"
read_key() {
    local count=0
    [[ -f $KEY_FILE ]] && IFS= read -r count < "$KEY_FILE"
    printf '%s\n' "$((count + 1))" > "$KEY_FILE"
    case "$count" in
        0) printf 'CHAR:2\n' ;;
        1) printf 'ENTER\n' ;;
        *) printf 'LEFT\n' ;;
    esac
}
cmd_clean
EOF
chmod +x "$DRIVER"
skip_output=$(script -qefc "$DRIVER" /dev/null < /dev/null)
[[ -d $HOME/.cache/yay && ! -e $HOME/.cache/yay/payload ]] || fail 'skipping sudo also skipped user cleanup'
grep -q 'Skipped system cleanup' <<< "$skip_output" || fail 'sudo skip was not reported'
[[ $(cat "$SUDO_LOG") == '-n true' ]] || fail 'system cleanup ran after sudo was skipped'
printf 'ok   skipping sudo keeps user cleanup running\n'

printf '\nclean flow regression passed\n'
