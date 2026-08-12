#!/bin/zsh

emulate -L zsh
setopt no_aliases
if [[ "$OSTYPE" != darwin* ]]; then
    print -u2 -r -- "NvimBridge: macOS is required"
    exit 1
fi

resolve_nvim() {
    local configured="${NVIMBRIDGE_NVIM:-}"

    if [[ -n "$configured" ]]; then
        if [[ "$configured" == /* && -x "$configured" ]]; then
            print -r -- "$configured"
            return 0
        fi
        if (( ${+commands[$configured]} )); then
            print -r -- "${commands[$configured]}"
            return 0
        fi
    fi

    if (( ${+commands[nvim]} )); then
        print -r -- "${commands[nvim]}"
        return 0
    fi

    local candidate
    for candidate in /opt/homebrew/bin/nvim /usr/local/bin/nvim /usr/bin/nvim; do
        if [[ -x "$candidate" ]]; then
            print -r -- "$candidate"
            return 0
        fi
    done

    return 1
}
nvim_path="$(resolve_nvim)" || {
    print -u2 -- "NvimBridge: nvim was not found."
    print -u2 -- "Put nvim on PATH in ~/.zprofile or set NVIMBRIDGE_NVIM to its absolute path."
    if [[ -t 0 ]]; then
        read -rk 1 "?Press any key to close."
        print
    fi
    exit 127
}

exec "$nvim_path" -- "$@"
