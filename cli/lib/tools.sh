#!/bin/bash
# remove / history / install-privileges 子命令（analyze 与 clean 共用扫描引擎，实现见 clean.sh）。

if [[ ${OMACLEAN_TOOLS_LOADED:-} ]]; then
    return 0
fi
OMACLEAN_TOOLS_LOADED=1

cmd_remove() {
    require_cmds fzf
    if has_cmd omarchy; then
        omarchy pkg remove
        return
    fi
    # 独立回退：没有 Omarchy 时使用 pacman 自带的事务确认。
    has_cmd pacman || die "pacman not found"
    local pkgs
    pkgs=$(pacman -Qqe | fzf --multi \
        --prompt='❯ ' --pointer='▶' --marker='✓' \
        --preview 'pacman -Qi {1}' \
        --preview-label='alt-p: toggle description' \
        --bind 'alt-p:toggle-preview') || true
    [[ -n $pkgs ]] || return 0

    local -a selected=()
    mapfile -t selected <<< "$pkgs"
    sudo pacman -Rns -- "${selected[@]}" || return 1
    return 0
}

cmd_install_privileges() {
    require_cmds sudo install pkaction
    local helper_src="$OMACLEAN_ROOT/libexec/omaclean-priv"
    local policy_src="$OMACLEAN_ROOT/polkit/com.omaclean.clean.policy"
    local policy_dir
    policy_dir=$(dirname -- "$OMACLEAN_PRIV_POLICY")
    [[ -f $helper_src && -f $policy_src ]] || die "privileged component sources not found under $OMACLEAN_ROOT"
    [[ -d $policy_dir ]] || die "polkit policy directory not found: $policy_dir"

    info "Installing the privileged component (sudo password required)"
    sudo install -Dm755 -- "$helper_src" "$OMACLEAN_PRIV_HELPER" || return 1
    sudo install -Dm644 -- "$policy_src" "$OMACLEAN_PRIV_POLICY" || return 1

    if ! trusted_root_executable "$OMACLEAN_PRIV_HELPER"; then
        warn "installed helper is not a root-owned, non-writable file: $OMACLEAN_PRIV_HELPER"
        return 1
    fi
    # polkitd 对 actions 目录的监控有延迟，重试几秒再判定注册结果。
    local waited=0
    while ! pkaction --action-id "$OMACLEAN_PRIV_ACTION" > /dev/null 2>&1; do
        if ((waited >= 8)); then
            warn "polkit has not registered $OMACLEAN_PRIV_ACTION; check $OMACLEAN_PRIV_POLICY"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    ok "Admin component installed — system items now run through $OMACLEAN_PRIV_ACTION"
    return 0
}

cmd_history() {
    local lines=${1:-50}
    [[ $lines =~ ^[0-9]+$ ]] || lines=50

    echo ""
    echo -e "${BLUE}${BOLD}Cleanup History${NC}"
    echo ""
    local display_log
    display_log=$(format_home_path "$OMACLEAN_LOG_FILE")
    echo -e "  ${GRAY}Log file: ${display_log}${NC}"
    echo ""

    if [[ ! -f $OMACLEAN_LOG_FILE || ! -s $OMACLEAN_LOG_FILE ]]; then
        ok "No operations recorded yet"
        echo ""
        return 0
    fi

    tail -n "$lines" -- "$OMACLEAN_LOG_FILE"
    echo ""
    return 0
}
