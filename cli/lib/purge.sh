#!/bin/bash
# omaclean purge: 深度清理项目构建产物（node_modules, target, dist 等）。
# 行内紧凑复选列表、预选老旧产物、实时删除与汇总。

if [[ ${OMACLEAN_PURGE_LOADED:-} ]]; then
    return 0
fi
OMACLEAN_PURGE_LOADED=1

OMACLEAN_PURGE_CONFIG="$HOME/.config/omaclean/purge_paths"
OMACLEAN_PURGE_ARTIFACTS=(node_modules target dist build .next .venv __pycache__ .turbo)

# 扫描根目录解析：优先从配置文件读取，否则使用默认目录
purge_roots() {
    if [[ -f $OMACLEAN_PURGE_CONFIG ]]; then
        local line real
        while IFS= read -r line; do
            line=${line%%#*}
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            line=${line/#\~/$HOME}
            [[ -n $line ]] || continue
            if [[ $line != /* ]]; then
                warn "skipping non-absolute purge root: $line"
                continue
            fi
            [[ -d $line ]] || continue
            real=$(realpath -e -- "$line" 2> /dev/null) || continue
            if [[ $real != /*/* ]]; then
                warn "skipping too broad purge root: $line"
                continue
            fi
            printf '%s\n' "$real"
        done < "$OMACLEAN_PURGE_CONFIG"
    else
        local root
        for root in "$HOME/Projects" "$HOME/dev" "$HOME/GitHub" "$HOME/src"; do
            [[ -d $root ]] && printf '%s\n' "$root"
        done
    fi
    return 0
}

# 扫描候选，收集并排序
purge_scan_candidates() {
    local min_age=$1
    local now root path mtime age size a
    local -a find_expr=()

    for a in "${OMACLEAN_PURGE_ARTIFACTS[@]}"; do
        if ((${#find_expr[@]} > 0)); then
            find_expr+=(-o)
        fi
        find_expr+=(-name "$a")
    done

    now=$(date +%s)
    declare -A seen=()
    PURGE_RECENT_COUNT=0
    PURGE_GIT_COUNT=0
    PURGE_SCAN_RESULTS=()

    while IFS= read -r root; do
        [[ -n $root ]] || continue
        while IFS= read -r path; do
            [[ -n $path ]] || continue
            [[ -z ${seen[$path]:-} ]] || continue
            seen[$path]=1

            if [[ -e $path/.git ]]; then
                PURGE_GIT_COUNT=$((PURGE_GIT_COUNT + 1))
                continue
            fi

            mtime=$(stat -c %Y -- "$path" 2> /dev/null) || continue
            age=$(((now - mtime) / 86400))
            if ((age < min_age)); then
                PURGE_RECENT_COUNT=$((PURGE_RECENT_COUNT + 1))
            fi

            size=$(dir_size_bytes "$path")
            size=${size:-0}
            PURGE_SCAN_RESULTS+=("$(printf '%s\t%s\t%sd\t%s\t%s' "$size" "$(human_size "$size")" "$age" "$path" "$root")")
        done < <(find "$root" -maxdepth 6 \
            -path '*/.git' -prune -o \
            \( "${find_expr[@]}" \) -type d -prune -print 2> /dev/null)
    done < <(purge_roots)

    return 0
}

# 扫描并按大小降序排序，结果放入 PURGE_SORTED（TSV：size / human / age / path / root）
PURGE_SORTED=()
purge_scan_sorted() {
    local min_age=$1 line
    PURGE_SCAN_RESULTS=()
    PURGE_RECENT_COUNT=0
    PURGE_GIT_COUNT=0
    purge_scan_candidates "$min_age"
    PURGE_SORTED=()
    ((${#PURGE_SCAN_RESULTS[@]} > 0)) || return 0
    while IFS= read -r line; do
        [[ -n $line ]] && PURGE_SORTED+=("$line")
    done < <(printf '%s\n' "${PURGE_SCAN_RESULTS[@]}" | sort -t$'\t' -k1,1nr)
    return 0
}

# ── 机器可读输出与非交互执行（供状态栏插件等消费方）──────────

# 扫描结果序列化为 JSON；参数为 min_age 与已排序行数组名（nameref）
render_purge_json() {
    local min_age=$1
    local -n _sorted=$2
    local line raw_sz h_sz age_str path_val r_val display_path age_days rec
    local first=1 total=0 count=0

    for line in "${_sorted[@]}"; do
        IFS=$'\t' read -r raw_sz h_sz age_str path_val r_val <<< "$line"
        age_days=${age_str%d}
        if ((age_days >= min_age)); then
            total=$((total + raw_sz))
            count=$((count + 1))
        fi
    done

    printf '{\n'
    printf '  "schema": 1,\n'
    printf '  "min_age": %d,\n' "$min_age"
    printf '  "candidates": %d,\n' "${#_sorted[@]}"
    printf '  "default_count": %d,\n' "$count"
    printf '  "default_bytes": %d,\n' "$total"
    printf '  "default_display": "%s",\n' "$(json_escape "$(human_size "$total")")"
    printf '  "items": [\n'
    for line in "${_sorted[@]}"; do
        IFS=$'\t' read -r raw_sz h_sz age_str path_val r_val <<< "$line"
        age_days=${age_str%d}
        display_path=$(format_home_path "$path_val")
        rec=false
        ((age_days >= min_age)) && rec=true
        ((first == 1)) || printf ',\n'
        first=0
        printf '    {"path": "%s", "display": "%s", "bytes": %d, "display_bytes": "%s", "age_days": %d, "recommended": %s}' \
            "$(json_escape "$path_val")" \
            "$(json_escape "$display_path")" \
            "$raw_sz" \
            "$(json_escape "$h_sz")" \
            "$age_days" \
            "$rec"
    done
    printf '\n  ]\n}\n'
}

# 单个删除结果序列化为 JSON 对象
purge_exec_line() { # path status bytes text
    printf '    {"path": "%s", "display": "%s", "status": "%s", "freed_bytes": %d, "freed": "%s", "text": "%s"}' \
        "$(json_escape "$1")" \
        "$(json_escape "$(format_home_path "$1")")" \
        "$2" "${3:-0}" \
        "$(json_escape "$(human_size "${3:-0}")")" \
        "$(json_escape "${4:-}")"
}

# 按路径列表执行清理：重新扫描并只接受仍是候选的路径（复用扫描阶段的
# 安全上下文与 .git 跳过规则），随后逐个安全删除。
cmd_purge_exec() {
    local -a exec_paths=("$@")
    require_cmds du numfmt df realpath find stat

    local roots
    roots=$(purge_roots)
    [[ -n $roots ]] || die "No scan roots found. Create ~/Projects or configure ~/.config/omaclean/purge_paths."

    purge_scan_sorted 7

    local -A known=()
    local line raw_sz h_sz age_str p r
    for line in "${PURGE_SCAN_RESULTS[@]}"; do
        IFS=$'\t' read -r raw_sz h_sz age_str p r <<< "$line"
        known[$p]=$r
    done

    local first=1 total=0 purged=0 failed=0 skipped=0 any_failed=0
    local path root st fro text freed
    printf '{\n  "schema": 1,\n  "items": [\n'
    for path in "${exec_paths[@]}"; do
        [[ -n $path ]] || continue
        root=${known[$path]:-}
        st=ok
        fro=0
        text=""
        if [[ -z $root ]]; then
            st=skipped
            text="not a current scan candidate"
        elif [[ ! -d $path ]]; then
            st=skipped
            text="no longer present"
        else
            if freed=$(delete_tree "$path" "$root"); then
                fro=${freed:-0}
                log_op purge REMOVED "$path" "$fro"
            else
                st=failed
                text="deletion failed"
            fi
        fi
        ((first == 1)) || printf ',\n'
        first=0
        purge_exec_line "$path" "$st" "$fro" "$text"
        case "$st" in
            ok)
                purged=$((purged + 1))
                total=$((total + fro))
                ;;
            skipped) skipped=$((skipped + 1)) ;;
            failed)
                failed=$((failed + 1))
                any_failed=1
                ;;
        esac
    done
    printf '\n  ],\n'
    printf '  "freed_bytes": %d,\n  "freed": "%s",\n  "purged": %d,\n  "skipped": %d,\n  "failed": %d\n' \
        "$total" "$(human_size "$total")" "$purged" "$skipped" "$failed"
    printf '}\n'
    ((any_failed == 0))
}

cmd_purge() {
    local dry_run=false
    local min_age=7
    local json=false
    local -a exec_paths=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run | -n)
                dry_run=true
                ;;
            --age)
                shift
                if [[ ! ${1:-} =~ ^[0-9]+$ ]]; then
                    die "--age expects a number of days"
                fi
                min_age=$1
                ;;
            --json)
                json=true
                ;;
            --exec)
                # 其后所有参数都按候选路径处理（argv 形式，避免路径分隔歧义）
                shift
                while (($# > 0)); do
                    exec_paths+=("$1")
                    shift
                done
                break
                ;;
            -h | --help)
                cat << EOF
omaclean purge — Clean heavy project build artifacts

Usage: omaclean purge [options]

Options:
  --dry-run, -n      Preview all candidates and the default selection
  --age N            Preselect items at least N days old (default: 7)
  --json             Print scan results as JSON (read-only, for status bar plugins)
  --exec <paths...>  Purge the listed paths non-interactively and print a JSON
                     result; only paths that are still scan candidates are accepted
  --help, -h         Show this help
EOF
                return 0
                ;;
            *)
                die "Unknown option for purge: $1"
                ;;
        esac
        shift
    done

    if ((${#exec_paths[@]} > 0)); then
        cmd_purge_exec "${exec_paths[@]}"
        return $?
    fi
    if [[ $json == true ]]; then
        require_cmds du numfmt df realpath find stat
        local json_roots
        json_roots=$(purge_roots)
        [[ -n $json_roots ]] || die "No scan roots found. Create ~/Projects or configure ~/.config/omaclean/purge_paths."
        purge_scan_sorted "$min_age"
        render_purge_json "$min_age" PURGE_SORTED
        return 0
    fi

    require_cmds du numfmt df realpath find stat

    # 1. 标题横幅
    echo ""
    if [[ "$dry_run" == "true" ]]; then
        echo -e "${BLUE}${BOLD}Purge Project Artifacts (Dry Run)${NC}"
    else
        echo -e "${BLUE}${BOLD}Purge Project Artifacts${NC}"
    fi
    echo ""
    local initial_free_kb
    initial_free_kb=$(free_space_bytes "$HOME")
    initial_free_kb=${initial_free_kb:-0}
    echo -e "  ${GRAY}${ICON_GEAR} Arch Linux (Omarchy) · Free space: $(human_size "$initial_free_kb")${NC}"

    local roots
    roots=$(purge_roots)
    if [[ -z $roots ]]; then
        echo ""
        warn "No scan roots found. Create ~/Projects or configure ~/.config/omaclean/purge_paths."
        return 0
    fi

    start_section "Project Artifacts"

    purge_scan_sorted "$min_age"

    if ((${#PURGE_SCAN_RESULTS[@]} == 0)); then
        echo ""
        ok "No project artifacts found"
        echo ""
        return 0
    fi

    # 大小降序（与扫描输出保持一致）
    local -a sorted_lines=("${PURGE_SORTED[@]}")

    # ── Dry Run 模式 ──────────────────────────────────────────
    if [[ "$dry_run" == "true" ]]; then
        local total_dry_bytes=0 default_count=0
        local raw_sz h_sz age_str age_days path_val r_val display_path
        for line in "${sorted_lines[@]}"; do
            IFS=$'\t' read -r raw_sz h_sz age_str path_val r_val <<< "$line"
            display_path=$(format_home_path "$path_val")
            age_days=${age_str%d}
            if ((age_days >= min_age)); then
                echo -e "  ${GREEN}${ICON_SOLID}${NC} ${display_path} · ${GREEN}${h_sz}${NC} ${GRAY}| ${age_str}${NC}"
                total_dry_bytes=$((total_dry_bytes + raw_sz))
                default_count=$((default_count + 1))
            else
                echo -e "  ${GRAY}${ICON_EMPTY}${NC} ${display_path} · ${h_sz} ${GRAY}| ${age_str}${NC}"
            fi
        done

        if ((PURGE_RECENT_COUNT > 0)); then
            skip "${PURGE_RECENT_COUNT} recent artifact(s) shown unselected (<${min_age}d)"
        fi
        if ((PURGE_GIT_COUNT > 0)); then
            skip "${PURGE_GIT_COUNT} artifact(s) with nested .git skipped"
        fi

        local details=(
            "Default selection: ${GREEN}$(human_size "$total_dry_bytes")${NC} | Items: ${default_count}"
            "Candidates: ${#sorted_lines[@]} | Free space: $(human_size "$initial_free_kb")"
        )
        print_summary_block "Dry run complete - no changes made" "${details[@]}"
        echo ""
        return 0
    fi

    # ── 交互式选择 ────────────────────────────────────────────
    if [[ ! -t 0 || ! -t 1 ]]; then
        die "Interactive selection requires a terminal. Use --dry-run for non-interactive preview."
    fi

    local -a choose_options=()
    local -a opt_to_path=()
    local -a opt_to_root=()
    local -A checked=()

    local raw_sz h_sz age_str age_days path_val r_val display_path opt_label i
    for line in "${sorted_lines[@]}"; do
        IFS=$'\t' read -r raw_sz h_sz age_str path_val r_val <<< "$line"
        display_path=$(format_home_path "$path_val")
        opt_label="${display_path}    ${h_sz} | ${age_str}"
        i=${#choose_options[@]}
        choose_options+=("$opt_label")
        age_days=${age_str%d}
        if ((age_days >= min_age)); then
            checked[$i]=1
        else
            checked[$i]=0
        fi
        opt_to_path+=("$path_val")
        opt_to_root+=("$r_val")
    done

    local pick_status=0
    prompt_inline_checkbox "Select artifacts (${min_age}d+ preselected):" checked choose_options || pick_status=$?
    if ((pick_status == 2)); then
        echo ""
        skip "Purge cancelled"
        echo ""
        return 0
    fi
    if ((pick_status != 0)); then
        echo ""
        skip "No artifacts selected"
        echo ""
        return 0
    fi

    local -a chosen_paths=()
    local -a chosen_roots=()
    for i in "${!choose_options[@]}"; do
        [[ ${checked[$i]:-0} == 1 ]] || continue
        chosen_paths+=("${opt_to_path[$i]}")
        chosen_roots+=("${opt_to_root[$i]}")
    done

    if ((${#chosen_paths[@]} == 0)); then
        echo ""
        skip "No artifacts selected"
        echo ""
        return 0
    fi

    echo ""
    start_section "Purging Artifacts"

    local total_freed=0
    local success_count=0
    local failed_count=0

    for i in "${!chosen_paths[@]}"; do
        local target_path="${chosen_paths[$i]}"
        local target_root="${chosen_roots[$i]}"
        local display_p
        display_p=$(format_home_path "$target_path")

        local freed
        if freed=$(delete_tree "$target_path" "$target_root"); then
            freed=${freed:-0}
            total_freed=$((total_freed + freed))
            ok "${display_p} · freed ${GREEN}$(human_size "$freed")${NC}"
            success_count=$((success_count + 1))
            log_op purge REMOVED "$target_path" "$freed"
        else
            warn "${display_p} · deletion failed"
            failed_count=$((failed_count + 1))
        fi
    done

    local final_free_kb
    final_free_kb=$(free_space_bytes "$HOME")
    final_free_kb=${final_free_kb:-0}
    local delta_kb=$((final_free_kb - initial_free_kb))
    ((delta_kb < 0)) && delta_kb=0

    local summary_title="Purge complete"
    if ((failed_count > 0 && success_count == 0)); then
        summary_title="Purge failed"
    elif ((failed_count > 0)); then
        summary_title="Purge partially completed"
    fi

    local free_line
    free_line="Free space: $(human_size "$final_free_kb")"
    if ((delta_kb >= 1048576)); then
        free_line+=" (+$(human_size "$delta_kb"))"
    fi

    local details=(
        "Estimated space freed: ${GREEN}$(human_size "$total_freed")${NC} | Items: ${success_count}"
        "$free_line"
    )
    print_summary_block "$summary_title" "${details[@]}"
    echo ""
    return 0
}
