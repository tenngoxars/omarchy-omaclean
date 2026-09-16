#!/bin/bash
# omaclean 公共函数：输出、视觉体系、尺寸换算、安全路径校验与操作日志。
# shellcheck disable=SC2034
if [[ ${OMACLEAN_COMMON_LOADED:-} ]]; then
    return 0
fi
OMACLEAN_COMMON_LOADED=1

# ── 颜色定义（尊重 NO_COLOR 与 dumb 终端）──────────────────────
omaclean_color=0
if [[ -n "${NO_COLOR:-}" ]]; then
    omaclean_color=0
elif [[ "${TERM:-}" != "dumb" && -t 1 ]]; then
    omaclean_color=1
fi

# shellcheck disable=SC2034
if [[ "$omaclean_color" == "0" ]]; then
    ESC="" GREEN="" BLUE="" CYAN="" YELLOW="" RED="" GRAY="" BOLD="" NC=""
else
    ESC=$'\033'
    GREEN="${ESC}[0;32m"
    BLUE="${ESC}[1;34m"
    CYAN="${ESC}[0;36m"
    YELLOW="${ESC}[0;33m"
    RED="${ESC}[0;31m"
    GRAY="${ESC}[0;38;5;244m"
    BOLD="${ESC}[1m"
    NC="${ESC}[0m"
fi
unset omaclean_color

# shellcheck disable=SC2034
# ── 视觉符号 ──────────────────────────────────────────────────
readonly ICON_ARROW="➤"
readonly ICON_SUCCESS="✓"
readonly ICON_SKIP="◎"
readonly ICON_WARN="!"
readonly ICON_DRY_RUN="→"
readonly ICON_SOLID="●"
readonly ICON_EMPTY="○"
readonly ICON_GEAR="⚙"

say()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "${BLUE}$*${NC}"; }
ok()   { printf '%s\n' "  ${GREEN}${ICON_SUCCESS}${NC} $*"; }
warn() { printf '%s\n' "  ${YELLOW}${ICON_WARN}${NC} $*" >&2; }
skip() { printf '%s\n' "  ${GRAY}${ICON_SKIP}${NC} ${GRAY}$*${NC}"; }

die() {
    printf '%s\n' "${RED}✗ $*${NC}" >&2
    exit 1
}

has_cmd() {
    command -v -- "$1" > /dev/null 2>&1
}

# 需要管理员权限的命令：已经在 root（如 pkexec 内部模式）就直接执行，否则走 sudo
as_root() {
    if [[ ${EUID:-0} -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

require_cmds() {
    local missing=() c
    for c in "$@"; do
        has_cmd "$c" || missing+=("$c")
    done
    ((${#missing[@]} == 0)) || die "Missing required command(s): ${missing[*]}"
}

# ── 品牌 Banner 与系统状态 ────────────────────────────────────
show_brand_banner() {
    echo ""
    echo -e "${BLUE}  ___  _ __ ___   ___  | | ___ ${NC}"
    echo -e "${BLUE} / _ \| '_ \` _ \ / _ \ | |/ _ \\${NC}"
    echo -e "${BLUE}| (_) | | | | | | (_) || |  __/${NC}  ${GRAY}omaclean v0.1.0${NC}"
    echo -e "${BLUE} \___/|_| |_| |_|\___/ |_|\___|${NC}  ${GREEN}Deep clean and maintain your Arch.${NC}"
    echo ""
    local free_sp
    free_sp=$(get_free_space)
    echo -e "  ${GRAY}${ICON_GEAR} Arch Linux (Omarchy) · Free space: ${free_sp}${NC}"
    echo ""
}

# ── 汇总横幅（70 宽实线汇总块）──────────────────
print_summary_block() {
    local heading="$1"
    shift
    local -a details=("$@")

    local _tw
    _tw=$(tput cols 2> /dev/null || echo 70)
    [[ "$_tw" =~ ^[0-9]+$ ]] || _tw=70
    ((_tw > 70)) && _tw=70
    local divider
    divider=$(printf '%*s' "$_tw" '' | tr ' ' '=')

    echo ""
    echo "$divider"
    if [[ -n "$heading" ]]; then
        echo -e "${BLUE}${heading}${NC}"
    fi
    for detail in "${details[@]}"; do
        [[ -z "$detail" ]] && continue
        echo -e "$detail"
    done
    echo "$divider"
}

# ── 尺寸换算 ──────────────────────────────────────────────────
# 字节转人类可读（IEC，例如 1.2GiB）
human_size() {
    local bytes=${1:-0}
    [[ $bytes =~ ^[0-9]+$ ]] || bytes=0
    numfmt --to=iec-i --suffix=B "$bytes" 2> /dev/null || printf '%sB' "$bytes"
}

dir_size_bytes() {
    local path=$1
    if [[ ! -e $path ]]; then
        printf '0'
        return 0
    fi
    du -sB1 -- "$path" 2> /dev/null | awk 'NR == 1 { print $1; exit }' || true
    return 0
}

free_space_bytes() {
    df -B1 --output=avail -- "$1" 2> /dev/null | awk 'NR == 2 { print $1; exit }' || true
    return 0
}

get_free_space() {
    local b
    b=$(free_space_bytes "$HOME")
    b=${b:-0}
    human_size "$b"
}

format_home_path() {
    local p="$1"
    if [[ "$p" == "$HOME"* ]]; then
        printf '~%s\n' "${p#"$HOME"}"
    else
        printf '%s\n' "$p"
    fi
}

# ── JSON 输出 ─────────────────────────────────────────────────
# 转义为 JSON 字符串字面量内容（不含外围引号）
json_escape() {
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

# ── 分段渲染（Section）────────────────────────────────────────
start_section() {
    local title="$1"
    echo ""
    echo -e "${BLUE}${ICON_ARROW} ${title}${NC}"
}

begin_step() {
    [[ -t 1 ]] && printf "  ${GRAY}… %s${NC}" "$1"
}

end_step() {
    [[ -t 1 ]] && printf '\r\033[K'
}

# ── 终端键盘输入（用于极速主菜单交互）────────────────────────
read_key() {
    local key rest
    IFS= read -r -s -n 1 key || { echo "QUIT"; return; }
    if [[ "$key" == $'\x1b' ]]; then
        if ! IFS= read -r -s -n 1 -t 0.1 rest 2> /dev/null; then
            echo "QUIT"
            return
        elif [[ "$rest" == "[" || "$rest" == "O" ]]; then
            IFS= read -r -s -n 1 -t 0.1 seq 2> /dev/null || { echo "OTHER"; return; }
            case "$seq" in
                A) echo "UP" ;;
                B) echo "DOWN" ;;
                C) echo "RIGHT" ;;
                D) echo "LEFT" ;;
                *) echo "OTHER" ;;
            esac
        else
            echo "QUIT"
        fi
        return
    fi
    case "$key" in
        # read -n 会把换行当分隔符吃掉，回车到来时 key 为空串
        "" | $'\n' | $'\r') echo "ENTER" ;;
        ' ') echo "SPACE" ;;
        'a' | 'A') echo "ALL" ;;
        'q' | 'Q' | $'\x03') echo "QUIT" ;;
        'j' | 'J') echo "DOWN" ;;
        'k' | 'K') echo "UP" ;;
        'h' | 'H') echo "LEFT" ;;
        'l' | 'L') echo "RIGHT" ;;
        $'\x01') echo "SELECT_ALL" ;;
        1 | 2 | 3 | 4 | 5) echo "CHAR:$key" ;;
        *) echo "OTHER" ;;
    esac
}

# ── 行内菜单（复选列表，仅更新变化行，隐藏光标）────────────────
# 菜单块固定 6+N 行：空行、标题、空行、N 条条目、空行、提示、空行。
# 画完后光标停在块末空行，先把它存成锚点（DECSC），重画时一律从锚点定位，
# 不做累计相对位移，避免一行误差把菜单推出屏幕。
inline_menu_anchor() { printf '\0337'; }
inline_menu_return() { printf '\0338'; }

# 定位到锚点上方第 idx 条（0 基）条目所在行并清除该行
inline_menu_goto_item() {
    local item_count=$1 idx=$2
    printf '\0338'
    printf '\033[%dA' $((item_count + 3 - idx))
    printf '\033[K'
}

inline_checkbox_repaint_line() {
    local highlight=$1 checked=$2 label=$3
    local mark
    if [[ $checked == 1 ]]; then
        mark=$ICON_SOLID
    else
        mark=$ICON_EMPTY
    fi
    if [[ $highlight == 1 ]]; then
        printf '  %b %s %s%b\n' "${CYAN}${ICON_ARROW}${NC}" "$mark" "$label" "$NC"
    else
        printf '    %s %s\n' "$mark" "$label"
    fi
}

inline_menu_repaint_item() { # count idx highlight checked label
    inline_menu_goto_item "$1" "$2"
    inline_checkbox_repaint_line "$3" "$4" "$5"
    inline_menu_return
}

inline_menu_swap_cursor() { # count from to checked_name labels_name
    local -n _checked=$4
    local -n _labels=$5

    inline_menu_repaint_item "$1" "$2" 0 "${_checked[$2]:-0}" "${_labels[$2]}"
    inline_menu_repaint_item "$1" "$3" 1 "${_checked[$3]:-0}" "${_labels[$3]}"
}

# 返回 0=已确认且至少一项，1=未选任何项，2=用户取消
prompt_inline_checkbox() {
    local header=$1
    local -n _checked=$2
    local -n _labels=$3
    local item_count=${#_labels[@]}
    local current=0 key prev i any all_selected=1

    [[ ${OMACLEAN_FORCE_EMPTY_SELECTION:-} == 1 ]] && return 1

    printf '\033[?25l'

    echo ""
    echo -e "  ${GRAY}${header}${NC}"
    echo ""
    for i in "${!_labels[@]}"; do
        local hl=0
        [[ $i -eq $current ]] && hl=1
        inline_checkbox_repaint_line "$hl" "${_checked[$i]:-0}" "${_labels[$i]}"
    done
    echo ""
    echo -e "  ${GRAY}↑↓ move  |  Space toggle  |  a all  |  Enter confirm  |  ← cancel${NC}"
    echo ""
    inline_menu_anchor

    while true; do
        key=$(read_key)
        case "$key" in
            UP)
                prev=$current
                if ((current > 0)); then
                    current=$((current - 1))
                else
                    current=$((item_count - 1))
                fi
                [[ $prev -eq $current ]] && continue
                inline_menu_swap_cursor "$item_count" "$prev" "$current" "$2" "$3"
                ;;
            DOWN)
                prev=$current
                if ((current < item_count - 1)); then
                    current=$((current + 1))
                else
                    current=0
                fi
                [[ $prev -eq $current ]] && continue
                inline_menu_swap_cursor "$item_count" "$prev" "$current" "$2" "$3"
                ;;
            SPACE)
                _checked[$current]=$((1 - ${_checked[$current]:-0}))
                inline_menu_repaint_item "$item_count" "$current" 1 "${_checked[$current]:-0}" "${_labels[$current]}"
                ;;
            ALL | SELECT_ALL)
                all_selected=1
                for i in "${!_labels[@]}"; do
                    [[ ${_checked[$i]:-0} == 0 ]] && all_selected=0
                done
                if [[ $all_selected == 1 ]]; then
                    for i in "${!_labels[@]}"; do
                        _checked[$i]=0
                    done
                else
                    for i in "${!_labels[@]}"; do
                        _checked[$i]=1
                    done
                fi
                for i in "${!_labels[@]}"; do
                    local hl=0
                    [[ $i -eq $current ]] && hl=1
                    inline_menu_repaint_item "$item_count" "$i" "$hl" "${_checked[$i]:-0}" "${_labels[$i]}"
                done
                ;;
            LEFT | QUIT)
                printf '\033[?25h'
                return 2
                ;;
            ENTER)
                any=0
                for i in "${!_labels[@]}"; do
                    [[ ${_checked[$i]:-0} == 1 ]] && any=1
                done
                printf '\033[?25h'
                ((any == 1)) && return 0 || return 1
                ;;
        esac
    done
}

# ── 安全删除 ──────────────────────────────────────────────────
assert_deletable() {
    local path=$1 root=$2
    [[ -n $path && -n $root ]] || return 1
    [[ $path == /* ]] || return 1
    case "$path" in
        / | /tmp | /var | /usr | /etc | /home | /boot | /root | /proc | /sys) return 1 ;;
    esac
    if [[ $path == "$HOME" || $path == "$HOME/" ]]; then
        return 1
    fi
    [[ -L $path ]] && return 1
    [[ -e $path ]] || return 1
    local rp rr
    rp=$(realpath -e -- "$path" 2> /dev/null) || return 1
    rr=$(realpath -e -- "$root" 2> /dev/null) || return 1
    case "$rp" in
        / | /usr | /usr/* | /bin | /bin/* | /sbin | /sbin/* | /lib | /lib/* | /lib64 | /lib64/* | \
            /etc | /etc/* | /boot | /boot/* | /var | /var/* | /opt | /opt/* | /srv | /srv/* | \
            /run | /run/* | /root | /root/* | /proc | /proc/* | /sys | /sys/* | /dev | /dev/* | \
            /tmp | /tmp/*) return 1 ;;
    esac
    [[ $rp == "$rr"/* ]] || return 1
    return 0
}

delete_tree() {
    local path=$1 root=$2 size
    if ! assert_deletable "$path" "$root"; then
        warn "Refusing unsafe path: $path"
        return 1
    fi
    size=$(dir_size_bytes "$path")
    size=${size:-0}
    rm -rf --one-file-system -- "$path" || return 1
    printf '%s' "$size"
    return 0
}

clear_dir_contents() {
    local dir=$1 root=${2:-$1}
    [[ -d $dir && ! -L $dir ]] || return 1
    local total=0 skipped=0 entry size
    local had_nullglob=0 had_dotglob=0
    shopt -q nullglob && had_nullglob=1
    shopt -q dotglob && had_dotglob=1
    shopt -s nullglob dotglob
    for entry in "$dir"/*; do
        if [[ -L $entry ]]; then
            skipped=$((skipped + 1))
            continue
        fi
        if ! assert_deletable "$entry" "$root"; then
            skipped=$((skipped + 1))
            continue
        fi
        size=$(dir_size_bytes "$entry")
        size=${size:-0}
        if rm -rf --one-file-system -- "$entry"; then
            total=$((total + size))
        else
            skipped=$((skipped + 1))
        fi
    done
    ((had_nullglob)) || shopt -u nullglob
    ((had_dotglob)) || shopt -u dotglob
    if ((skipped > 0)); then
        warn "skipped $skipped entries under $dir"
    fi
    printf '%s' "$total"
    return 0
}

# ── 操作日志 ──────────────────────────────────────────────────
OMACLEAN_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omaclean"
OMACLEAN_LOG_FILE="$OMACLEAN_STATE_DIR/operations.log"

log_op() {
    local cmd=$1 action=$2 target=$3 bytes=${4:-}
    mkdir -p -- "$OMACLEAN_STATE_DIR" 2> /dev/null || return 0
    local line
    line="[$(date '+%Y-%m-%dT%H:%M:%S%z')] [$cmd] $action $target"
    if [[ -n $bytes ]]; then
        line="$line ($bytes bytes)"
    fi
    printf '%s\n' "$line" >> "$OMACLEAN_LOG_FILE"
    return 0
}

run_and_measure() {
    local path=$1
    shift
    [[ ${1:-} == "--" ]] && shift
    local before after
    before=$(dir_size_bytes "$path")
    before=${before:-0}
    "$@" || return 1
    after=$(dir_size_bytes "$path")
    after=${after:-0}
    local freed=$((before - after))
    ((freed < 0)) && freed=0
    printf '%s' "$freed"
    return 0
}

