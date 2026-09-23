#!/bin/bash

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
