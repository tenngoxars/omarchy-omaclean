#!/bin/bash
# omaclean clean：先只读扫描，再评审选择，最后执行清理。

if [[ ${OMACLEAN_CLEAN_LOADED:-} ]]; then
    return 0
fi
OMACLEAN_CLEAN_LOADED=1

readonly CLEAN_THRESHOLD=$((1024 * 1024))
readonly CLEAN_JOURNAL_LIMIT=$((100 * 1024 * 1024))

declare -ga CLEAN_IDS=()
declare -gA CLEAN_CATEGORY=()
declare -gA CLEAN_LABEL=()
declare -gA CLEAN_BYTES=()
declare -gA CLEAN_DISPLAY=()
declare -gA CLEAN_NOTE=()
declare -gA CLEAN_STATUS=()
declare -gA CLEAN_SYSTEM=()
declare -gA CLEAN_DEFAULT=()
declare -gA CLEAN_SELECTED=()

journal_disk_bytes() {
    local raw token number suffix scale=1
    raw=$(LC_ALL=C journalctl --disk-usage 2> /dev/null) || return 0
    token=$(printf '%s\n' "$raw" | awk 'match($0, /take up [0-9.]+[KMGTP]?/) { print substr($0, RSTART + 8, RLENGTH - 8); exit }')
    [[ -n $token ]] || return 0
    number=$token
    suffix=${token: -1}
    case "$suffix" in
        K | M | G | T | P) number=${token%?} ;;
        *) suffix="" ;;
    esac
    case "$suffix" in
        K) scale=1024 ;;
        M) scale=$((1024 ** 2)) ;;
        G) scale=$((1024 ** 3)) ;;
        T) scale=$((1024 ** 4)) ;;
        P) scale=$((1024 ** 5)) ;;
    esac
    awk -v n="$number" -v s="$scale" 'BEGIN { printf "%d", n * s }'
}

pacman_reclaim_bytes() {
    local raw token number unit scale=1
    has_cmd paccache || return 0
    raw=$(paccache -d -k 2 2> /dev/null) || return 0
    token=$(printf '%s\n' "$raw" | awk 'match($0, /disk space saved: [0-9.]+ [KMG]i?B/) { print substr($0, RSTART + 18, RLENGTH - 18); exit }')
    [[ -n $token ]] || return 0
    number=${token% *}
    unit=${token##* }
    case "$unit" in
        KiB) scale=1024 ;;
        MiB) scale=$((1024 ** 2)) ;;
        GiB) scale=$((1024 ** 3)) ;;
    esac
    awk -v n="$number" -v s="$scale" 'BEGIN { printf "%d", n * s }'
}

tmpfiles_reclaim_bytes() {
    local line path size total=0
    declare -A seen=()
    has_cmd systemd-tmpfiles || return 0

    while IFS= read -r line; do
        [[ $line =~ ^Would\ remove\ \"(.*)\"$ ]] || continue
        path=${BASH_REMATCH[1]}
        [[ -e $path && ! -L $path && -z ${seen[$path]:-} ]] || continue
        seen["$path"]=1
        size=$(dir_size_bytes "$path")
        total=$((total + ${size:-0}))
    done < <(LC_ALL=C systemd-tmpfiles --clean --dry-run 2>&1)

    printf '%s' "$total"
}

browsers_running() {
    local name
    for name in chromium chrome google-chrome google-chrome-stable firefox firefox-esr brave; do
        pgrep -x "$name" > /dev/null 2>&1 && return 0
    done
    return 1
}

scan_paths_bytes() {
    local total=0 path size
    for path in "$@"; do
        [[ -d $path && ! -L $path ]] || continue
        size=$(dir_size_bytes "$path")
        total=$((total + ${size:-0}))
    done
    printf '%s' "$total"
}

scan_add() {
    local id=$1 category=$2 label=$3 bytes=$4 display=$5 note=$6 status=$7 system=$8 recommended=$9
    CLEAN_IDS+=("$id")
    CLEAN_CATEGORY["$id"]=$category
    CLEAN_LABEL["$id"]=$label
    CLEAN_BYTES["$id"]=$bytes
    CLEAN_DISPLAY["$id"]=$display
    CLEAN_NOTE["$id"]=$note
    CLEAN_STATUS["$id"]=$status
    CLEAN_SYSTEM["$id"]=$system
    CLEAN_DEFAULT["$id"]=$recommended
}

scan_clean_targets() {
    local allow_trash=$1 bytes status note journal_size reclaim
    CLEAN_IDS=()
    CLEAN_CATEGORY=()
    CLEAN_LABEL=()
    CLEAN_BYTES=()
    CLEAN_DISPLAY=()
    CLEAN_NOTE=()
    CLEAN_STATUS=()
    CLEAN_SYSTEM=()
    CLEAN_DEFAULT=()
    CLEAN_SELECTED=()

    reclaim=$(pacman_reclaim_bytes)
    reclaim=${reclaim:-0}
    status=tidy
    ((reclaim > 0)) && status=ready
    scan_add pacman "Package Management" "Pacman package cache" "$reclaim" "$(human_size "$reclaim")" "keeps 2 versions" "$status" 1 1

    bytes=$(scan_paths_bytes "$HOME/.cache/yay" "$HOME/.cache/paru")
    status=tidy
    ((bytes > CLEAN_THRESHOLD)) && status=ready
    scan_add aur "Package Management" "AUR build cache" "$bytes" "$(human_size "$bytes")" "yay / paru" "$status" 0 1

    journal_size=$(journal_disk_bytes)
    journal_size=${journal_size:-0}
    reclaim=$((journal_size - CLEAN_JOURNAL_LIMIT))
    ((reclaim < 0)) && reclaim=0
    status=tidy
    ((reclaim > 0)) && status=ready
    scan_add journal "System" "systemd journal" "$reclaim" "$(human_size "$reclaim")" "keeps 100MiB; current $(human_size "$journal_size")" "$status" 1 0

    reclaim=$(tmpfiles_reclaim_bytes)
    reclaim=${reclaim:-0}
    status=tidy
    ((reclaim > CLEAN_THRESHOLD)) && status=ready
    scan_add tmp "System" "Expired temporary files" "$reclaim" "$(human_size "$reclaim")" "systemd expiration rules" "$status" 1 1

    bytes=$(scan_paths_bytes "$HOME/.cache/thumbnails")
    status=tidy
    ((bytes > CLEAN_THRESHOLD)) && status=ready
    scan_add thumbnails "User Caches" "Thumbnail cache" "$bytes" "$(human_size "$bytes")" "" "$status" 0 1

    bytes=$(scan_paths_bytes "$HOME/.cache/chromium" "$HOME/.cache/google-chrome" "$HOME/.cache/mozilla")
    if browsers_running; then
        status=skipped
    elif ((bytes > CLEAN_THRESHOLD)); then
        status=ready
    else
        status=tidy
    fi
    note=""
    [[ $status == skipped ]] && note="close browsers to include"
    scan_add browsers "User Caches" "Browser caches" "$bytes" "$(human_size "$bytes")" "$note" "$status" 0 1

    bytes=$(scan_paths_bytes "$HOME/.local/share/Trash/files" "$HOME/.local/share/Trash/info")
    if ((bytes == 0)); then
        status=tidy
    elif [[ $allow_trash == true ]]; then
        status=ready
    else
        status=protected
    fi
    note=""
    [[ $status == protected ]] && note="run with --trash to include"
    scan_add trash "User Caches" "Trash" "$bytes" "$(human_size "$bytes")" "$note" "$status" 0 1

    bytes=$(scan_paths_bytes "$HOME/.npm/_cacache")
    status=tidy
    ((bytes > CLEAN_THRESHOLD)) && status=ready
    scan_add npm "Developer Caches" "npm cache" "$bytes" "$(human_size "$bytes")" "" "$status" 0 1


    local id label path
    while IFS='|' read -r id label path; do
        bytes=$(scan_paths_bytes "$path")
        status=tidy
        ((bytes > CLEAN_THRESHOLD)) && status=ready
        scan_add "$id" "Developer Caches" "$label" "$bytes" "$(human_size "$bytes")" "" "$status" 0 1
    done << EOF
cargo|Cargo registry cache|$HOME/.cargo/registry/cache
uv|uv cache|$HOME/.cache/uv
pip|pip cache|$HOME/.cache/pip
go|Go build cache|$HOME/.cache/go-build
bun|Bun cache|$HOME/.bun/install/cache
EOF
}

# 类别只列本轮可选择项；运行中浏览器与受保护回收站另行说明。
render_clean_scan() {
    local dry_run=$1 category id status note line known_total=0 ready=0
    local cat_bytes=0 category_title=""
    local -a section_ids=() unavailable_ids=()
    local title_suffix="" summary_heading="Scan complete"
    if [[ $dry_run == true ]]; then
        title_suffix=" (Dry Run)"
        summary_heading="Scan complete - no changes made"
    fi

    echo ""
    echo -e "${BLUE}${BOLD}Scan Your System${title_suffix}${NC}"
    echo ""
    echo -e "  ${GRAY}${ICON_GEAR} Arch Linux (Omarchy) · Free space: $(get_free_space)${NC}"

    for category in "Package Management" "System" "User Caches" "Developer Caches"; do
        section_ids=()
        cat_bytes=0
        for id in "${CLEAN_IDS[@]}"; do
            [[ ${CLEAN_CATEGORY[$id]} == "$category" && ${CLEAN_STATUS[$id]} == ready ]] || continue
            section_ids+=("$id")
            cat_bytes=$((cat_bytes + CLEAN_BYTES[$id]))
        done
        ((${#section_ids[@]} > 0)) || continue

        category_title="$category · $(human_size "$cat_bytes")"
        start_section "$category_title"
        for id in "${section_ids[@]}"; do
            note=${CLEAN_NOTE[$id]}
            line="${CLEAN_LABEL[$id]} · ${CLEAN_DISPLAY[$id]}"
            [[ -n $note ]] && line+=" ${GRAY}(${note})${NC}"
            echo -e "  ${CYAN}${ICON_SOLID}${NC} ${line}"
            ready=$((ready + 1))
            known_total=$((known_total + CLEAN_BYTES[$id]))
        done
    done

    for id in "${CLEAN_IDS[@]}"; do
        status=${CLEAN_STATUS[$id]}
        if [[ $status == protected ]] || [[ $status == skipped && ${CLEAN_BYTES[$id]} -gt 0 ]]; then
            unavailable_ids+=("$id")
        fi
    done
    if ((${#unavailable_ids[@]} > 0)); then
        start_section "Not selectable this run"
        for id in "${unavailable_ids[@]}"; do
            status=${CLEAN_STATUS[$id]}
            note=${CLEAN_NOTE[$id]}
            line="${CLEAN_LABEL[$id]} · ${CLEAN_DISPLAY[$id]}"
            [[ -n $note ]] && line+=" ${GRAY}(${note})${NC}"
            if [[ $status == skipped ]]; then
                skip "$line"
            else
                echo -e "  ${GRAY}${ICON_EMPTY} ${line}${NC}"
            fi
        done
    fi

    print_summary_block "$summary_heading" \
        "Selectable: ${ready} | Reclaimable: ${GREEN}$(human_size "$known_total")${NC}"
    echo ""
}

# 机器可读扫描输出（供状态栏插件等消费方）：只读，不改变任何状态。
render_clean_json() {
    local id bytes system_flag recommended_flag selectable=0 reclaimable=0 first=1
    printf '{\n'
    printf '  "schema": 1,\n'
    printf '  "free_space": "%s",\n' "$(json_escape "$(get_free_space)")"
    printf '  "items": [\n'
    for id in "${CLEAN_IDS[@]}"; do
        bytes=${CLEAN_BYTES[$id]}
        system_flag=false
        [[ ${CLEAN_SYSTEM[$id]} -eq 1 ]] && system_flag=true
        recommended_flag=false
        [[ ${CLEAN_DEFAULT[$id]} -eq 1 ]] && recommended_flag=true
        if [[ ${CLEAN_STATUS[$id]} == ready ]]; then
            selectable=$((selectable + 1))
            reclaimable=$((reclaimable + bytes))
        fi
        ((first == 1)) || printf ',\n'
        first=0
        printf '    {"id": "%s", "category": "%s", "label": "%s", "bytes": %d, "display": "%s", "note": "%s", "status": "%s", "system": %s, "recommended": %s}' \
            "$(json_escape "$id")" \
            "$(json_escape "${CLEAN_CATEGORY[$id]}")" \
            "$(json_escape "${CLEAN_LABEL[$id]}")" \
            "$bytes" \
            "$(json_escape "${CLEAN_DISPLAY[$id]}")" \
            "$(json_escape "${CLEAN_NOTE[$id]}")" \
            "${CLEAN_STATUS[$id]}" \
            "$system_flag" \
            "$recommended_flag"
    done
    printf '\n  ],\n'
    printf '  "selectable": %d,\n' "$selectable"
    printf '  "reclaimable_bytes": %d,\n' "$reclaimable"
    printf '  "reclaimable": "%s"\n' "$(json_escape "$(human_size "$reclaimable")")"
    printf '}\n'
}

# A = 全部清理：选中本轮所有可选择项
select_all_clean_items() {
    local id
    CLEAN_SELECTED=()
    for id in "${CLEAN_IDS[@]}"; do
        if [[ ${CLEAN_STATUS[$id]} == ready ]]; then
            CLEAN_SELECTED["$id"]=1
        fi
    done
}

review_clean_selection() {
    local -a labels=() option_ids=()
    local -A checked=()
    local id option i

    [[ ${GUM_EMPTY:-} == 1 || ${OMACLEAN_FORCE_EMPTY_SELECTION:-} == 1 ]] && return 1

    for id in "${CLEAN_IDS[@]}"; do
        [[ ${CLEAN_STATUS[$id]} == ready ]] || continue
        option="${CLEAN_LABEL[$id]}    ${CLEAN_DISPLAY[$id]}"
        i=${#labels[@]}
        labels+=("$option")
        option_ids+=("$id")
        checked[$i]=${CLEAN_DEFAULT[$id]:-0}
    done
    ((${#labels[@]} > 0)) || return 1

    prompt_inline_checkbox "Review cleanup items (safe defaults selected):" checked labels || return $?

    CLEAN_SELECTED=()
    for i in "${!labels[@]}"; do
        [[ ${checked[$i]:-0} == 1 ]] && CLEAN_SELECTED["${option_ids[$i]}"]=1
    done
    ((${#CLEAN_SELECTED[@]} > 0))
}


# ── 扫描后操作菜单（纵向选择，避免单行多键误触）──────────────
readonly CLEAN_ACTION_COUNT=3

clean_action_label() {
    local num=$1 all_label=$2
    case "$num" in
        1) printf '%s' "Pick items" ;;
        2) printf 'Clean all (%s)' "$all_label" ;;
        3) printf '%s' "Cancel" ;;
    esac
}

paint_clean_action_line() {
    local num=$1 highlight=$2 all_label=$3 text
    text=$(clean_action_label "$num" "$all_label")
    if [[ $highlight == 1 ]]; then
        echo -e "  ${CYAN}${ICON_ARROW} ${num}. ${text}${NC}"
    else
        echo -e "    ${num}. ${text}"
    fi
}

draw_clean_action_menu() {
    local sel=$1 all_label=$2 num
    echo ""
    echo -e "  ${GRAY}Choose next step:${NC}"
    echo ""
    for num in $(seq 1 "$CLEAN_ACTION_COUNT"); do
        if [[ $num -eq $sel ]]; then
            paint_clean_action_line "$num" 1 "$all_label"
        else
            paint_clean_action_line "$num" 0 "$all_label"
        fi
    done
    echo ""
    echo -e "  ${GRAY}↑↓ move  |  Enter confirm  |  ← cancel${NC}"
    echo ""
    inline_menu_anchor
}

update_clean_action_highlight() {
    local from=$1 to=$2 all_label=$3

    inline_menu_goto_item "$CLEAN_ACTION_COUNT" "$((from - 1))"
    paint_clean_action_line "$from" 0 "$all_label"
    inline_menu_return
    inline_menu_goto_item "$CLEAN_ACTION_COUNT" "$((to - 1))"
    paint_clean_action_line "$to" 1 "$all_label"
    inline_menu_return
}

# 结果写入第二个参数（nameref）：pick | all | cancel
prompt_clean_action() {
    local all_label=$1
    local -n _result=$2
    local current=1 key prev

    printf '\033[?25l'
    draw_clean_action_menu "$current" "$all_label"
    while true; do
        key=$(read_key)
        case "$key" in
            UP)
                prev=$current
                ((current > 1)) && ((current--)) || current=$CLEAN_ACTION_COUNT
                [[ $prev -eq $current ]] && continue
                update_clean_action_highlight "$prev" "$current" "$all_label"
                ;;
            DOWN)
                prev=$current
                ((current < CLEAN_ACTION_COUNT)) && ((current++)) || current=1
                [[ $prev -eq $current ]] && continue
                update_clean_action_highlight "$prev" "$current" "$all_label"
                ;;
            CHAR:1)
                [[ $current -eq 1 ]] || update_clean_action_highlight "$current" 1 "$all_label"
                current=1
                ;;
            CHAR:2)
                [[ $current -eq 2 ]] || update_clean_action_highlight "$current" 2 "$all_label"
                current=2
                ;;
            CHAR:3)
                [[ $current -eq 3 ]] || update_clean_action_highlight "$current" 3 "$all_label"
                current=3
                ;;
            ALL)
                [[ $current -eq 2 ]] || update_clean_action_highlight "$current" 2 "$all_label"
                current=2
                ;;
            LEFT | QUIT)
                printf '\033[?25h'
                _result=cancel
                return 0
                ;;
            RIGHT | ENTER | SPACE)
                printf '\033[?25h'
                case "$current" in
                    1) _result=pick; return 0 ;;
                    2) _result=all; return 0 ;;
                    3) _result=cancel; return 0 ;;
                esac
                ;;
        esac
    done
}

selection_has_system_items() {
    local id
    for id in "${CLEAN_IDS[@]}"; do
        [[ ${CLEAN_SELECTED[$id]:-0} == 1 && ${CLEAN_SYSTEM[$id]} == 1 ]] && return 0
    done
    return 1
}

prompt_sudo_system_clean() {
    [[ ${EUID:-0} -eq 0 ]] && return 0
    sudo -n true 2> /dev/null && return 0
    [[ -t 0 && -t 1 ]] || return 1

    echo -ne "  ${CYAN}${ICON_ARROW}${NC} System items need sudo. ${GRAY}←${NC} skip  |  ${GREEN}→${NC} continue: "
    local choice
    choice=$(read_key)
    printf '\r\033[K'
    if [[ $choice == RIGHT || $choice == ENTER ]] && sudo -v 2> /dev/null; then
        ok "Admin access granted"
        return 0
    fi
    skip "Skipped system cleanup"
    return 1
}

clean_paths() {
    local total=0 path freed
    for path in "$@"; do
        [[ -d $path && ! -L $path ]] || continue
        freed=$(clear_dir_contents "$path") || return 1
        total=$((total + ${freed:-0}))
    done
    CLEAN_RESULT_BYTES=$total
}

CLEAN_RESULT_BYTES=0
CLEAN_RESULT_TEXT=""

execute_clean_item() {
    local id=$1
    CLEAN_RESULT_BYTES=0
    CLEAN_RESULT_TEXT=""
    case "$id" in
        pacman)
            has_cmd paccache || return 1
            CLEAN_RESULT_BYTES=${CLEAN_BYTES[pacman]:-0}
            as_root paccache -rk2 > /dev/null 2>&1 || return 1
            log_op clean PRUNED pacman-package-cache "$CLEAN_RESULT_BYTES"
            return 0
            ;;
        aur)
            clean_paths "$HOME/.cache/yay" "$HOME/.cache/paru" || return 1
            log_op clean CLEARED aur-build-cache "$CLEAN_RESULT_BYTES"
            return 0
            ;;
        journal)
            has_cmd journalctl || return 1
            CLEAN_RESULT_BYTES=${CLEAN_BYTES[journal]:-0}
            as_root journalctl --vacuum-size="${CLEAN_JOURNAL_LIMIT}B" > /dev/null 2>&1 || return 1
            CLEAN_RESULT_TEXT="kept $(human_size "$CLEAN_JOURNAL_LIMIT")"
            log_op clean VACUUMED systemd-journal "$CLEAN_RESULT_BYTES"
            return 0
            ;;
        tmp)
            has_cmd systemd-tmpfiles || return 1
            CLEAN_RESULT_BYTES=${CLEAN_BYTES[tmp]:-0}
            as_root systemd-tmpfiles --clean > /dev/null 2>&1 || return 1
            log_op clean REMOVED expired-tmpfiles "$CLEAN_RESULT_BYTES"
            return 0
            ;;
        thumbnails)
            clean_paths "$HOME/.cache/thumbnails" || return 1
            log_op clean CLEARED thumbnail-cache "$CLEAN_RESULT_BYTES"
            return 0
            ;;
        browsers)
            if browsers_running; then
                CLEAN_RESULT_TEXT="close browsers to include"
                return 2
            fi
            clean_paths "$HOME/.cache/chromium" "$HOME/.cache/google-chrome" "$HOME/.cache/mozilla" || return 1
            log_op clean CLEARED browser-caches "$CLEAN_RESULT_BYTES"
            return 0
            ;;
        trash)
            clean_paths "$HOME/.local/share/Trash/files" "$HOME/.local/share/Trash/info" || return 1
            log_op clean CLEARED trash "$CLEAN_RESULT_BYTES"
            return 0
            ;;
        npm)
            if has_cmd npm; then
                npm cache clean --force > /dev/null 2>&1 || return 1
                CLEAN_RESULT_BYTES=${CLEAN_BYTES[npm]:-0}
            else
                clean_paths "$HOME/.npm/_cacache" || return 1
            fi
            log_op clean CLEARED npm-cache "$CLEAN_RESULT_BYTES"
            return 0
            ;;
        cargo)
            clean_paths "$HOME/.cargo/registry/cache" || return 1
            log_op clean CLEARED cargo-registry-cache "$CLEAN_RESULT_BYTES"
            return 0
            ;;
        uv)
            if has_cmd uv; then
                uv cache clean > /dev/null 2>&1 || return 1
                CLEAN_RESULT_BYTES=${CLEAN_BYTES[uv]:-0}
            else
                clean_paths "$HOME/.cache/uv" || return 1
            fi
            log_op clean CLEARED uv-cache "$CLEAN_RESULT_BYTES"
            return 0
            ;;
        pip)
            if has_cmd pip; then
                pip cache purge > /dev/null 2>&1 || return 1
                CLEAN_RESULT_BYTES=${CLEAN_BYTES[pip]:-0}
            else
                clean_paths "$HOME/.cache/pip" || return 1
            fi
            log_op clean CLEARED pip-cache "$CLEAN_RESULT_BYTES"
            return 0
            ;;
        go)
            if has_cmd go; then
                go clean -cache -modcache -testcache > /dev/null 2>&1 || return 1
                CLEAN_RESULT_BYTES=${CLEAN_BYTES[go]:-0}
            else
                clean_paths "$HOME/.cache/go-build" || return 1
            fi
            log_op clean CLEARED go-build-cache "$CLEAN_RESULT_BYTES"
            return 0
            ;;
        bun)
            clean_paths "$HOME/.bun/install/cache" || return 1
            log_op clean CLEARED bun-cache "$CLEAN_RESULT_BYTES"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ── 非交互执行（供状态栏插件等消费方）─────────────────────────

# 内部提权执行器：只经 pkexec 以 root 运行，仅接受系统项白名单。
# 每个 id 输出一行 TSV：id <TAB> status <TAB> freed_bytes <TAB> text
cmd_sys_exec() {
    local ids=${1:-} id
    [[ ${EUID:-0} -eq 0 ]] || die "_sys is an internal command (run via pkexec)"
    [[ -n $ids ]] || die "_sys requires a comma-separated item list"

    # 日志写回调用者（pkexec 提供 PKEXEC_UID）的 state 目录
    if [[ -n ${PKEXEC_UID:-} ]]; then
        local caller_home
        caller_home=$(getent passwd "$PKEXEC_UID" 2> /dev/null | cut -d: -f6) || caller_home=""
        if [[ -n $caller_home && -d $caller_home ]]; then
            OMACLEAN_STATE_DIR="$caller_home/.local/state/omaclean"
            OMACLEAN_LOG_FILE="$OMACLEAN_STATE_DIR/operations.log"
            mkdir -p -- "$OMACLEAN_STATE_DIR" 2> /dev/null || true
            chown -- "$PKEXEC_UID" "$OMACLEAN_STATE_DIR" 2> /dev/null || true
            if [[ ! -e $OMACLEAN_LOG_FILE ]]; then
                : >> "$OMACLEAN_LOG_FILE" 2> /dev/null || true
                chown -- "$PKEXEC_UID" "$OMACLEAN_LOG_FILE" 2> /dev/null || true
            fi
        fi
    fi

    local -a want=()
    IFS=',' read -r -a want <<< "$ids"
    for id in "${want[@]}"; do
        [[ -n $id ]] || continue
        local rc=0 text=""
        case "$id" in
            pacman) CLEAN_BYTES[pacman]=$(pacman_reclaim_bytes) ;;
            journal) CLEAN_BYTES[journal]=$(journal_disk_bytes) ;;
            tmp) CLEAN_BYTES[tmp]=$(tmpfiles_reclaim_bytes) ;;
            *)
                printf '%s\tfailed\t0\t%s\n' "$id" "unknown system item"
                continue
                ;;
        esac
        CLEAN_BYTES[$id]=${CLEAN_BYTES[$id]:-0}

        execute_clean_item "$id" || rc=$?
        text=${CLEAN_RESULT_TEXT:-}
        case "$rc" in
            0) printf '%s\tok\t%s\t%s\n' "$id" "${CLEAN_RESULT_BYTES:-0}" "$text" ;;
            2) printf '%s\tskipped\t0\t%s\n' "$id" "${text:-not available}" ;;
            *) printf '%s\tfailed\t0\t%s\n' "$id" "${text:-cleanup failed}" ;;
        esac
    done
}

# 单个执行结果序列化为 JSON 对象（无换行、无前缀）
exec_result_line() { # id status bytes text
    printf '    {"id": "%s", "status": "%s", "freed_bytes": %d, "freed": "%s", "text": "%s"}' \
        "$(json_escape "$1")" "$2" "${3:-0}" "$(json_escape "$(human_size "${3:-0}")")" "$(json_escape "${4:-}")"
}

# 按 id 列表执行清理：用户项就地执行；系统项经 pkexec 一次性提权。
# 只输出 JSON 结果；存在失败项时退出码非零。
cmd_clean_exec() {
    local exec_ids=$1 allow_trash=$2
    require_cmds du numfmt df realpath
    scan_clean_targets "$allow_trash"

    local -a raw_ids=() want=() user_ids=() sys_ids=()
    local -A want_seen=()
    local id
    IFS=',' read -r -a raw_ids <<< "$exec_ids"
    for id in "${raw_ids[@]}"; do
        [[ -n $id ]] || continue
        [[ -z ${want_seen[$id]:-} ]] || continue
        want_seen[$id]=1
        want+=("$id")
    done

    local -A R_STATUS=() R_BYTES=() R_TEXT=()
    for id in "${want[@]}"; do
        if [[ -z ${CLEAN_STATUS[$id]+x} ]]; then
            R_STATUS[$id]=failed
            R_BYTES[$id]=0
            R_TEXT[$id]="unknown item"
        elif [[ ${CLEAN_STATUS[$id]} != ready ]]; then
            R_STATUS[$id]=skipped
            R_BYTES[$id]=0
            R_TEXT[$id]="not selectable this run"
        elif [[ ${CLEAN_SYSTEM[$id]} -eq 1 ]]; then
            sys_ids+=("$id")
        else
            user_ids+=("$id")
        fi
    done

    local rc=0
    for id in "${user_ids[@]}"; do
        rc=0
        execute_clean_item "$id" || rc=$?
        case "$rc" in
            0)
                R_STATUS[$id]=ok
                R_BYTES[$id]=${CLEAN_RESULT_BYTES:-0}
                R_TEXT[$id]=${CLEAN_RESULT_TEXT:-}
                ;;
            2)
                R_STATUS[$id]=skipped
                R_BYTES[$id]=0
                R_TEXT[$id]=${CLEAN_RESULT_TEXT:-not available}
                ;;
            *)
                R_STATUS[$id]=failed
                R_BYTES[$id]=0
                R_TEXT[$id]="cleanup failed"
                ;;
        esac
    done

    if ((${#sys_ids[@]} > 0)); then
        local joined sys_out="" pk_rc=0
        joined=$(IFS=','; printf '%s' "${sys_ids[*]}")
        if has_cmd pkexec; then
            # 120s 未完成认证则放弃，避免面板无限等待挂起
            sys_out=$(timeout 120 pkexec "$OMACLEAN_ROOT/omaclean" _sys "$joined" 2> /dev/null) || pk_rc=$?
        else
            pk_rc=127
        fi
        if ((pk_rc == 0)); then
            local r_id r_status r_bytes r_text
            while IFS=$'\t' read -r r_id r_status r_bytes r_text; do
                [[ -n $r_id ]] || continue
                R_STATUS[$r_id]=$r_status
                R_BYTES[$r_id]=${r_bytes:-0}
                R_TEXT[$r_id]=$r_text
            done <<< "$sys_out"
            for id in "${sys_ids[@]}"; do
                if [[ -z ${R_STATUS[$id]:-} ]]; then
                    R_STATUS[$id]=failed
                    R_BYTES[$id]=0
                    R_TEXT[$id]="no result from admin helper"
                fi
            done
        else
            for id in "${sys_ids[@]}"; do
                R_STATUS[$id]=failed
                R_BYTES[$id]=0
                if ((pk_rc == 126)); then
                    R_TEXT[$id]="admin authorization failed"
                elif ((pk_rc == 124)); then
                    R_TEXT[$id]="admin authorization timed out"
                elif ((pk_rc == 127)); then
                    R_TEXT[$id]="pkexec unavailable"
                else
                    R_TEXT[$id]="admin helper failed"
                fi
            done
        fi
    fi

    local first=1 total=0 cleaned=0 skipped=0 failed=0 any_failed=0 by st
    printf '{\n  "schema": 1,\n  "items": [\n'
    for id in "${want[@]}"; do
        st=${R_STATUS[$id]}
        by=${R_BYTES[$id]:-0}
        ((first == 1)) || printf ',\n'
        first=0
        exec_result_line "$id" "$st" "$by" "${R_TEXT[$id]:-}"
        case "$st" in
            ok)
                cleaned=$((cleaned + 1))
                total=$((total + by))
                ;;
            skipped) skipped=$((skipped + 1)) ;;
            failed)
                failed=$((failed + 1))
                any_failed=1
                ;;
        esac
    done
    printf '\n  ],\n'
    printf '  "freed_bytes": %d,\n  "freed": "%s",\n  "cleaned": %d,\n  "skipped": %d,\n  "failed": %d\n' \
        "$total" "$(human_size "$total")" "$cleaned" "$skipped" "$failed"
    printf '}\n'
    ((any_failed == 0))
}

cmd_clean() {
    local dry_run=false force_select=false allow_trash=false json=false exec_ids=""
    while (($# > 0)); do
        case "$1" in
            --dry-run | -n) dry_run=true ;;
            --select | -s) force_select=true ;;
            --trash) allow_trash=true ;;
            --json) json=true ;;
            --exec)
                shift
                [[ -n ${1:-} ]] || die "--exec requires a comma-separated list of item ids"
                exec_ids=$1
                ;;
            -h | --help)
                cat << EOF
omaclean clean — Scan, review, and clean caches and logs

Usage: omaclean clean [options]

Options:
  --dry-run, -n    Scan only; never open review or delete
  --select, -s     Open item review immediately after scanning
  --trash          Include user trash in selectable items
  --json           Print scan results as JSON (read-only, for status bar plugins)
  --exec <ids>     Clean the listed item ids non-interactively and print a JSON
                   result; admin items are elevated via the graphical polkit agent
  --help, -h       Show this help
EOF
                return 0
                ;;
            *) die "Unknown option for clean: $1 (see omaclean clean --help)" ;;
        esac
        shift
    done

    if [[ -n $exec_ids ]]; then
        cmd_clean_exec "$exec_ids" "$allow_trash"
        return $?
    fi

    require_cmds du numfmt df realpath
    scan_clean_targets "$allow_trash"
    if [[ $json == true ]]; then
        render_clean_json
        return 0
    fi
    render_clean_scan "$dry_run"
    [[ $dry_run == true ]] && return 0

    clean_apply_selection "$force_select"
}

# force_select=true 时扫描后直接打开逐项评审。
clean_apply_selection() {
    local force_select=$1
    local ready=0 id all_bytes=0
    local open_review=false review_status=0
    for id in "${CLEAN_IDS[@]}"; do
        [[ ${CLEAN_STATUS[$id]} == ready ]] || continue
        ready=$((ready + 1))
        all_bytes=$((all_bytes + CLEAN_BYTES[$id]))
    done
    if ((ready == 0)); then
        ok "No selectable junk found"
        echo ""
        return 0
    fi
    [[ -t 0 && -t 1 ]] || die "Cleaning requires a terminal. Use --dry-run for non-interactive preview."

    local all_label
    all_label="${ready} items · $(human_size "$all_bytes")"

    if [[ $force_select == true ]]; then
        open_review=true
    else
        local choice
        prompt_clean_action "$all_label" choice
        case "$choice" in
            pick) open_review=true ;;
            all) select_all_clean_items ;;
            cancel | *)
                skip "Cleanup cancelled"
                echo ""
                return 0
                ;;
        esac
    fi

    if [[ $open_review == true ]]; then
        review_clean_selection || review_status=$?
        if ((review_status != 0)); then
            if ((review_status == 1)); then
                skip "No cleanup items selected"
            else
                skip "Cleanup cancelled"
            fi
            echo ""
            return 0
        fi
    fi

    if selection_has_system_items && ! prompt_sudo_system_clean; then
        for id in "${CLEAN_IDS[@]}"; do
            [[ ${CLEAN_SYSTEM[$id]} == 1 ]] && unset "CLEAN_SELECTED[$id]"
        done
    fi
    if ((${#CLEAN_SELECTED[@]} == 0)); then
        skip "No cleanup items selected"
        echo ""
        return 0
    fi

    local initial_free final_free delta total_freed=0 succeeded=0 skipped=0 failed=0 rc
    initial_free=$(free_space_bytes "$HOME")
    initial_free=${initial_free:-0}
    start_section "Clean"
    for id in "${CLEAN_IDS[@]}"; do
        [[ ${CLEAN_SELECTED[$id]:-0} == 1 ]] || continue
        begin_step "${CLEAN_LABEL[$id]}"
        if execute_clean_item "$id"; then
            rc=0
        else
            rc=$?
        fi
        end_step
        case "$rc" in
            0)
                total_freed=$((total_freed + CLEAN_RESULT_BYTES))
                succeeded=$((succeeded + 1))
                if [[ -n $CLEAN_RESULT_TEXT ]]; then
                    ok "${CLEAN_LABEL[$id]} · ${CLEAN_RESULT_TEXT}"
                elif ((CLEAN_RESULT_BYTES > 0)); then
                    ok "${CLEAN_LABEL[$id]} · freed ${GREEN}$(human_size "$CLEAN_RESULT_BYTES")${NC}"
                else
                    ok "${CLEAN_LABEL[$id]} · already optimal"
                fi
                ;;
            2)
                skipped=$((skipped + 1))
                skip "${CLEAN_LABEL[$id]} · ${CLEAN_RESULT_TEXT:-no longer available}"
                ;;
            *)
                failed=$((failed + 1))
                warn "${CLEAN_LABEL[$id]} · cleanup failed"
                ;;
        esac
    done

    final_free=$(free_space_bytes "$HOME")
    final_free=${final_free:-0}
    delta=$((final_free - initial_free))
    ((delta < 0)) && delta=0
    print_summary_block "Cleanup complete" \
        "Freed: ${GREEN}$(human_size "$total_freed")${NC} | Cleaned: ${succeeded} | Skipped: ${skipped} | Failed: ${failed}" \
        "Free space: $(human_size "$final_free") (+$(human_size "$delta"))"
    echo ""
    ((failed == 0))
}

# analyze：保留 CLI 别名，交互行为与 clean 完全一致
cmd_analyze() {
    case "${1:-}" in
        -h | --help)
            cat << EOF
omaclean analyze — Alias of omaclean clean

Usage: omaclean analyze [options]

Uses the same targets, options, report, and selection flow as 'omaclean clean'.
In a terminal: use ↑↓ to choose pick items / clean all / cancel, then Enter to confirm.
Piped or non-interactive runs stop after the report.
EOF
            return 0
            ;;
    esac
    if [[ -t 0 && -t 1 ]]; then
        cmd_clean "$@"
    else
        cmd_clean --dry-run "$@"
    fi
}
