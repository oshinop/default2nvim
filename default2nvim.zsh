#!/bin/zsh

emulate -L zsh
setopt no_aliases pipe_fail
if [[ "$OSTYPE" != darwin* ]]; then
    print -u2 -r -- "default2nvim: macOS is required"
    exit 1
fi

readonly REPOSITORY_URL="https://github.com/oshinop/default2nvim"
readonly GIT="${commands[git]:-}"
typeset PROJECT_ROOT="${0:A:h}"
typeset RUNTIME_ROOT=""
if [[ ! -f "$PROJECT_ROOT/resources/groups.tsv" ]]; then
    [[ -n "$GIT" && -x "$GIT" ]] || {
        print -u2 -r -- "default2nvim: git is required"
        exit 1
    }
    RUNTIME_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/default2nvim-runtime.XXXXXX")" || {
        print -u2 -r -- "default2nvim: could not create a temporary runtime directory"
        exit 1
    }
    trap '/bin/rm -rf -- "$RUNTIME_ROOT"' EXIT
    "$GIT" clone --depth 1 --quiet "$REPOSITORY_URL" "$RUNTIME_ROOT/default2nvim" || {
        print -u2 -r -- "default2nvim: could not clone $REPOSITORY_URL"
        exit 1
    }
    PROJECT_ROOT="$RUNTIME_ROOT/default2nvim"
fi

readonly PROJECT_ROOT
readonly GROUPS_FILE="$PROJECT_ROOT/resources/groups.tsv"
readonly EXTENSIONS_FILE="$PROJECT_ROOT/resources/extensions.tsv"
readonly TERMINALS_FILE="$PROJECT_ROOT/resources/terminals.tsv"
readonly APP_BUNDLE_NAME="Neovim.app"
readonly BUNDLE_IDENTIFIER="moe.oshino.nvimbridge"
readonly APP_PATH="$HOME/Applications/$APP_BUNDLE_NAME"
readonly APPLICATION_SUPPORT_DIR="$HOME/Library/Application Support/default2nvim"
readonly SNAPSHOT_FILE="$APPLICATION_SUPPORT_DIR/original-handlers.tsv"
readonly LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
readonly TERMINAL_PREFERENCE_KEY="terminalBackend"

typeset -A GROUP_LABEL EXTENSION_GROUP
typeset -A TERMINAL_NAME TERMINAL_BUNDLE TERMINAL_PATHS
typeset -a GROUP_ORDER EXTENSIONS TERMINAL_ORDER
DUTI=""
typeset -a SELECTED_INDICES SELECTED_EXTENSIONS
SELECTED_TERMINAL=""

fail() {
    print -u2 -r -- "default2nvim: $*"
    return 1
}

usage() {
    /bin/cat <<'USAGE'
Usage: default2nvim.zsh [COMMAND] [ARGUMENTS...]

Commands:
  (no command)                 Open the interactive manager.
  install [TERMINAL]           Build, install, and register Neovim.app.
  set-term [TERMINAL]          Select the terminal used by Neovim.app.
  uninstall                    Restore associations and remove Neovim.app.
  set EXTENSION...             Set Neovim.app as the default handler.
  restore EXTENSION...         Restore captured handlers.
  restore --all                Restore all captured handlers.
  status [EXTENSION...]        Show current handlers.
  list                         List supported extensions.
  help, -h, --help             Show this help.

TERMINAL: ghostty | wezterm | kitty | alacritty | iterm2 | terminal
USAGE
}

load_catalogs() {
    local required_file
    for required_file in "$GROUPS_FILE" "$EXTENSIONS_FILE" "$TERMINALS_FILE"; do
        [[ -f "$required_file" ]] || {
            fail "missing catalog: $required_file"
            return 1
        }
    done

    local group label icon extension
    while IFS=$'\t' read -r group label icon; do
        [[ -z "$group" || "$group" == \#* ]] && continue
        (( ${+GROUP_LABEL[$group]} == 0 )) || {
            fail "duplicate group in catalog: $group"
            return 1
        }
        GROUP_ORDER+=("$group")
        GROUP_LABEL[$group]="$label"
    done < "$GROUPS_FILE"

    while IFS=$'\t' read -r extension group; do
        [[ -z "$extension" || "$extension" == \#* ]] && continue
        (( ${+GROUP_LABEL[$group]} )) || {
            fail "unknown group '$group' for .$extension"
            return 1
        }
        (( ${+EXTENSION_GROUP[$extension]} == 0 )) || {
            fail "duplicate extension in catalog: .$extension"
            return 1
        }
        EXTENSIONS+=("$extension")
        EXTENSION_GROUP[$extension]="$group"
    done < "$EXTENSIONS_FILE"

    local terminal_id terminal_name terminal_bundle terminal_paths
    while IFS=$'\t' read -r terminal_id terminal_name terminal_bundle terminal_paths; do
        [[ -z "$terminal_id" || "$terminal_id" == \#* ]] && continue
        (( ${+TERMINAL_NAME[$terminal_id]} == 0 )) || {
            fail "duplicate terminal in catalog: $terminal_id"
            return 1
        }
        TERMINAL_ORDER+=("$terminal_id")
        TERMINAL_NAME[$terminal_id]="$terminal_name"
        TERMINAL_BUNDLE[$terminal_id]="$terminal_bundle"
        TERMINAL_PATHS[$terminal_id]="$terminal_paths"
    done < "$TERMINALS_FILE"

    (( ${#EXTENSIONS} > 0 )) || {
        fail "extension catalog is empty"
        return 1
    }
    (( ${#TERMINAL_ORDER} > 0 )) || {
        fail "terminal catalog is empty"
        return 1
    }
}

resolve_duti() {
    if [[ -n "${DEFAULT2NVIM_DUTI:-}" ]]; then
        [[ -x "$DEFAULT2NVIM_DUTI" ]] || {
            fail "DEFAULT2NVIM_DUTI is not executable: $DEFAULT2NVIM_DUTI"
            return 1
        }
        DUTI="$DEFAULT2NVIM_DUTI"
    elif (( ${+commands[duti]} )); then
        DUTI="${commands[duti]}"
    else
        fail "duti is required; install it with 'brew install duti'"
        return 1
    fi
}


normalize_extension() {
    local extension="${1#.}"
    print -r -- "${extension:l}"
}

is_supported_extension() {
    (( ${+EXTENSION_GROUP[$1]} ))
}

is_supported_terminal() {
    (( ${+TERMINAL_NAME[$1]} ))
}

terminal_app_path() {
    local terminal_id="$1"
    local path expanded_path
    local -a paths
    paths=("${(@s:|:)TERMINAL_PATHS[$terminal_id]}")

    for path in "${paths[@]}"; do
        expanded_path="${path/#\~/$HOME}"
        if [[ -d "$expanded_path" ]]; then
            print -r -- "$expanded_path"
            return 0
        fi
    done

    if [[ -x /usr/bin/mdfind ]]; then
        local discovered
        discovered="$(/usr/bin/mdfind "kMDItemCFBundleIdentifier == '${TERMINAL_BUNDLE[$terminal_id]}'" | {
            while IFS= read -r path; do
                if [[ -d "$path" ]]; then
                    print -r -- "$path"
                    break
                fi
            done
        })"
        if [[ -n "$discovered" ]]; then
            print -r -- "$discovered"
            return 0
        fi
    fi

    return 1
}

current_terminal_id() {
    /usr/bin/defaults read "$BUNDLE_IDENTIFIER" "$TERMINAL_PREFERENCE_KEY" 2>/dev/null
}

validate_terminal() {
    local terminal_id="$1"
    is_supported_terminal "$terminal_id" || {
        fail "unsupported terminal: $terminal_id"
        return 1
    }
    if ! terminal_app_path "$terminal_id" >/dev/null; then
        fail "${TERMINAL_NAME[$terminal_id]} is not installed"
        return 1
    fi
}

set_terminal_preference() {
    local terminal_id="$1"
    validate_terminal "$terminal_id" || return 1
    /usr/bin/defaults write "$BUNDLE_IDENTIFIER" "$TERMINAL_PREFERENCE_KEY" -string "$terminal_id" >/dev/null || {
        fail "could not save the terminal preference"
        return 1
    }
    print -r -- "Neovim.app terminal -> ${TERMINAL_NAME[$terminal_id]}"
}

app_defaults_exist() {
    /usr/bin/defaults read "$BUNDLE_IDENTIFIER" >/dev/null 2>&1
}

clear_app_defaults() {
    app_defaults_exist || return 0
    /usr/bin/defaults delete "$BUNDLE_IDENTIFIER" >/dev/null || {
        fail "could not remove the Neovim.app preferences"
        return 1
    }
}

ensure_app() {
    [[ -d "$APP_PATH" ]] || {
        fail "Neovim.app is not installed at $APP_PATH; run install first"
        return 1
    }

    local identifier
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$APP_PATH/Contents/Info.plist" 2>/dev/null)" || {
        fail "cannot read Neovim.app's bundle identifier"
        return 1
    }
    [[ "$identifier" == "$BUNDLE_IDENTIFIER" ]] || {
        fail "unexpected bundle identifier at $APP_PATH: $identifier"
        return 1
    }

    [[ -x "$LSREGISTER" ]] || {
        fail "LaunchServices registrar not found: $LSREGISTER"
        return 1
    }
    "$LSREGISTER" -f "$APP_PATH" >/dev/null || {
        fail "could not register $APP_PATH with LaunchServices"
        return 1
    }
}

handler_details() {
    "$DUTI" -x "$1" 2>/dev/null
}

handler_bundle() {
    local output
    output="$(handler_details "$1")" || return 0
    local -a lines
    lines=("${(@f)output}")
    print -r -- "${lines[3]:-}"
}

snapshot_extension() {
    local extension="$1"
    /bin/mkdir -p "$APPLICATION_SUPPORT_DIR" || return 1
    /bin/chmod 700 "$APPLICATION_SUPPORT_DIR"

    if [[ -f "$SNAPSHOT_FILE" ]]; then
        local saved_extension saved_bundle
        while IFS=$'\t' read -r saved_extension saved_bundle; do
            [[ "$saved_extension" == "$extension" ]] && return 0
        done < "$SNAPSHOT_FILE"
    fi

    local current_bundle
    current_bundle="$(handler_bundle "$extension")"
    [[ -n "$current_bundle" ]] || current_bundle="-"
    print -r -- "$extension"$'\t'"$current_bundle" >> "$SNAPSHOT_FILE"
    /bin/chmod 600 "$SNAPSHOT_FILE"
}

set_defaults() {
    (( $# > 0 )) || {
        fail "set requires at least one extension"
        return 1
    }
    resolve_duti || return 1
    ensure_app || return 1

    local raw extension
    local applied=0 failures=0
    for raw in "$@"; do
        extension="$(normalize_extension "$raw")"
        if ! is_supported_extension "$extension"; then
            print -u2 -r -- "Unsupported extension: .$extension"
            (( failures += 1 ))
            continue
        fi

        if ! snapshot_extension "$extension"; then
            print -u2 -r -- "Could not snapshot the current handler for .$extension"
            (( failures += 1 ))
            continue
        fi

        if "$DUTI" -s "$BUNDLE_IDENTIFIER" ".$extension" all >/dev/null; then
            print -r -- "Set .$extension -> $BUNDLE_IDENTIFIER"
            (( applied += 1 ))
        else
            print -u2 -r -- "duti failed for .$extension"
            (( failures += 1 ))
        fi
    done

    print -r -- "Applied: $applied; failed: $failures"
    (( failures == 0 ))
}

restore_defaults() {
    (( $# > 0 )) || {
        fail "restore requires extensions or --all"
        return 1
    }
    resolve_duti || return 1
    [[ -f "$SNAPSHOT_FILE" ]] || {
        fail "no captured handlers exist at $SNAPSHOT_FILE"
        return 1
    }

    typeset -A originals
    local saved_extension saved_bundle
    while IFS=$'\t' read -r saved_extension saved_bundle; do
        [[ -n "$saved_extension" ]] && originals[$saved_extension]="$saved_bundle"
    done < "$SNAPSHOT_FILE"

    local -a targets
    if [[ "$1" == "--all" ]]; then
        local catalog_extension
        for catalog_extension in "${EXTENSIONS[@]}"; do
            (( ${+originals[$catalog_extension]} )) && targets+=("$catalog_extension")
        done
    else
        local raw extension
        for raw in "$@"; do
            extension="$(normalize_extension "$raw")"
            if (( ${+originals[$extension]} )); then
                targets+=("$extension")
            else
                print -u2 -r -- "No captured handler for .$extension"
            fi
        done
    fi

    (( ${#targets} > 0 )) || {
        fail "none of the requested extensions has a captured handler"
        return 1
    }

    local target original
    local restored=0 skipped=0 failures=0
    for target in "${targets[@]}"; do
        original="${originals[$target]}"
        if [[ "$original" == "-" || "$original" == "$BUNDLE_IDENTIFIER" ]]; then
            print -u2 -r -- "Skipped .$target: it had no restorable previous handler"
            (( skipped += 1 ))
            continue
        fi

        if "$DUTI" -s "$original" ".$target" all >/dev/null; then
            print -r -- "Restored .$target -> $original"
            (( restored += 1 ))
        else
            print -u2 -r -- "duti failed while restoring .$target -> $original"
            (( failures += 1 ))
        fi
    done

    print -r -- "Restored: $restored; skipped: $skipped; failed: $failures"
    (( failures == 0 ))
}

status_table() {
    resolve_duti || return 1

    local -a targets
    if (( $# == 0 )); then
        targets=("${EXTENSIONS[@]}")
    else
        local raw extension
        for raw in "$@"; do
            extension="$(normalize_extension "$raw")"
            if is_supported_extension "$extension"; then
                targets+=("$extension")
            else
                print -u2 -r -- "Unsupported extension: .$extension"
            fi
        done
    fi

    printf '%-18s  %-24s  %s\n' 'EXTENSION' 'GROUP' 'HANDLER BUNDLE ID'
    local target bundle group
    for target in "${targets[@]}"; do
        bundle="$(handler_bundle "$target")"
        [[ -n "$bundle" ]] || bundle="(none reported)"
        group="${EXTENSION_GROUP[$target]}"
        printf '%-18s  %-24s  %s\n' ".$target" "${GROUP_LABEL[$group]}" "$bundle"
    done
}

list_catalog() {
    local extension group
    for extension in "${EXTENSIONS[@]}"; do
        group="${EXTENSION_GROUP[$extension]}"
        printf '%-18s  %s\n' ".$extension" "${GROUP_LABEL[$group]}"
    done
}

install_app() {
    local terminal_id="$1"
    validate_terminal "$terminal_id" || return 1
    [[ -n "$GIT" && -x "$GIT" ]] || {
        fail "git is required to install Neovim.app"
        return 1
    }
    [[ -x "$LSREGISTER" ]] || {
        fail "LaunchServices registrar not found: $LSREGISTER"
        return 1
    }

    if [[ -e "$APP_PATH" ]]; then
        local existing_identifier
        existing_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
        [[ "$existing_identifier" == "$BUNDLE_IDENTIFIER" ]] || {
            fail "refusing to replace an unrelated app at $APP_PATH"
            return 1
        }
    fi

    local work_root
    work_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/default2nvim-install.XXXXXX")" || {
        fail "could not create a temporary build directory"
        return 1
    }
    work_root="${work_root:A}"

    {
        local checkout="$work_root/default2nvim"
        "$GIT" clone --depth 1 --quiet "$REPOSITORY_URL" "$checkout" || {
            fail "could not clone $REPOSITORY_URL"
            return 1
        }

        local build_script="$checkout/scripts/build-app.zsh"
        [[ -x "$build_script" ]] || {
            fail "cloned repository is missing scripts/build-app.zsh"
            return 1
        }
        "$build_script" >/dev/null || {
            fail "could not build Neovim.app"
            return 1
        }

        local built_app="$checkout/build/$APP_BUNDLE_NAME"
        [[ -d "$built_app" ]] || {
            fail "build did not produce $built_app"
            return 1
        }

        local install_parent="${APP_PATH:h}"
        local staging_path="$install_parent/.${APP_BUNDLE_NAME}.install.$$"
        /bin/mkdir -p "$install_parent" || return 1
        /bin/rm -rf -- "$staging_path"
        /bin/cp -R "$built_app" "$staging_path" || {
            /bin/rm -rf -- "$staging_path"
            fail "could not copy Neovim.app into $install_parent"
            return 1
        }
        if [[ -e "$APP_PATH" ]]; then
            /bin/rm -rf -- "$APP_PATH" || {
                /bin/rm -rf -- "$staging_path"
                fail "could not replace $APP_PATH"
                return 1
            }
        fi
        /bin/mv "$staging_path" "$APP_PATH" || {
            /bin/rm -rf -- "$staging_path"
            fail "could not install $APP_PATH"
            return 1
        }

        "$LSREGISTER" -f "$APP_PATH" >/dev/null || {
            /bin/rm -rf -- "$APP_PATH"
            fail "could not register $APP_PATH with LaunchServices"
            return 1
        }
        set_terminal_preference "$terminal_id" || return 1
        print -r -- "Installed $APP_PATH"
    } always {
        /bin/rm -rf -- "$work_root" || true
    }
}

uninstall_app() {
    local has_defaults=0
    app_defaults_exist && has_defaults=1
    if [[ ! -d "$APP_PATH" && ! -d "$APPLICATION_SUPPORT_DIR" ]] && (( ! has_defaults )); then
        print -r -- "default2nvim is already completely uninstalled."
        return 0
    fi

    local restored=0 failures=0
    if [[ -d "$APP_PATH" || -f "$SNAPSHOT_FILE" ]]; then
        resolve_duti || return 1

        typeset -A originals queued_extensions
        local -a managed_extensions=("${EXTENSIONS[@]}")
        local extension
        for extension in "${managed_extensions[@]}"; do
            queued_extensions[$extension]=1
        done

        if [[ -f "$SNAPSHOT_FILE" ]]; then
            local saved_extension saved_bundle
            while IFS=$'\t' read -r saved_extension saved_bundle; do
                [[ -n "$saved_extension" ]] || continue
                originals[$saved_extension]="$saved_bundle"
                if [[ -z "${queued_extensions[$saved_extension]:-}" ]]; then
                    managed_extensions+=("$saved_extension")
                    queued_extensions[$saved_extension]=1
                fi
            done < "$SNAPSHOT_FILE"
        fi

        local current original
        for extension in "${managed_extensions[@]}"; do
            current="$(handler_bundle "$extension")"
            [[ "$current" == "$BUNDLE_IDENTIFIER" ]] || continue

            original="${originals[$extension]:-com.apple.TextEdit}"
            if [[ "$original" == "-" || "$original" == "$BUNDLE_IDENTIFIER" ]]; then
                original="com.apple.TextEdit"
            fi

            if "$DUTI" -s "$original" ".$extension" all >/dev/null; then
                print -r -- "Restored .$extension -> $original"
                (( restored += 1 ))
            else
                print -u2 -r -- "Could not detach .$extension from Neovim.app"
                (( failures += 1 ))
            fi
        done

        if (( failures > 0 )); then
            fail "uninstall stopped because $failures association(s) still point to Neovim.app"
            return 1
        fi
    fi

    if [[ -d "$APP_PATH" ]]; then
        local identifier
        identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
            "$APP_PATH/Contents/Info.plist" 2>/dev/null)" || {
            fail "cannot verify the app at $APP_PATH"
            return 1
        }
        [[ "$identifier" == "$BUNDLE_IDENTIFIER" ]] || {
            fail "refusing to remove an unrelated app at $APP_PATH"
            return 1
        }
    fi

    clear_app_defaults || return 1

    if [[ -d "$APP_PATH" ]]; then
        [[ -x "$LSREGISTER" ]] || {
            fail "LaunchServices registrar not found: $LSREGISTER"
            return 1
        }
        "$LSREGISTER" -u "$APP_PATH" >/dev/null || {
            fail "could not unregister $APP_PATH"
            return 1
        }
        /bin/rm -rf -- "$APP_PATH" || {
            fail "could not remove $APP_PATH"
            return 1
        }
    fi

    if [[ -d "$APPLICATION_SUPPORT_DIR" ]]; then
        /bin/rm -rf -- "$APPLICATION_SUPPORT_DIR" || {
            fail "could not remove $APPLICATION_SUPPORT_DIR"
            return 1
        }
    fi

    print -r -- "Completely uninstalled default2nvim; restored $restored managed association(s)."
}

select_indices() {
    local title="$1"
    shift
    local -a rows=("$@")
    (( ${#rows} > 0 )) || {
        fail "nothing is available to select"
        return 1
    }

    while true; do
        print
        print -r -- "$title"
        local index
        for (( index = 1; index <= ${#rows}; index += 1 )); do
            printf '  %3d) %s\n' "$index" "${rows[$index]}"
        done
        print -r -- "Enter numbers or ranges (for example: 1 3-5), 'all', or 'q'."

        local selection
        read -r "selection?Selection: " || return 1
        selection="${selection:l}"
        [[ "$selection" == q || "$selection" == quit ]] && return 1

        if [[ "$selection" == all ]]; then
            SELECTED_INDICES=()
            for (( index = 1; index <= ${#rows}; index += 1 )); do
                SELECTED_INDICES+=("$index")
            done
            return 0
        fi

        local normalized="${selection//,/ }"
        local -a tokens
        tokens=("${(@s: :)normalized}")
        typeset -A seen
        SELECTED_INDICES=()
        local token start end valid=1
        for token in "${tokens[@]}"; do
            [[ -z "$token" ]] && continue
            if [[ "$token" == <-> ]]; then
                start=$(( 10#$token ))
                end=$start
            elif [[ "$token" == <->-<-> ]]; then
                start=$(( 10#${token%%-*} ))
                end=$(( 10#${token##*-} ))
            else
                print -u2 -r -- "Invalid selection: $token"
                valid=0
                break
            fi

            if (( start < 1 || end < start || end > ${#rows} )); then
                print -u2 -r -- "Selection is outside 1-${#rows}: $token"
                valid=0
                break
            fi

            for (( index = start; index <= end; index += 1 )); do
                if (( ${+seen[$index]} == 0 )); then
                    seen[$index]=1
                    SELECTED_INDICES+=("$index")
                fi
            done
        done

        (( valid )) || continue
        (( ${#SELECTED_INDICES} > 0 )) || {
            print -u2 -r -- "Select at least one item."
            continue
        }
        return 0
    done
}

choose_terminal() {
    local current="$(current_terminal_id 2>/dev/null || true)"
    local -a rows
    local terminal_id availability current_marker
    for terminal_id in "${TERMINAL_ORDER[@]}"; do
        if terminal_app_path "$terminal_id" >/dev/null 2>&1; then
            availability="installed"
        else
            availability="not found"
        fi
        [[ "$terminal_id" == "$current" ]] && current_marker="; current" || current_marker=""
        rows+=("${TERMINAL_NAME[$terminal_id]} [$availability$current_marker]")
    done

    while select_indices "Choose the terminal Neovim.app will use" "${rows[@]}"; do
        if (( ${#SELECTED_INDICES} == 1 )); then
            SELECTED_TERMINAL="${TERMINAL_ORDER[${SELECTED_INDICES[1]}]}"
            return 0
        fi
        print -u2 -r -- "Choose exactly one terminal."
    done
    return 1
}

choose_extensions() {
    local -a group_rows
    local group
    for group in "${GROUP_ORDER[@]}"; do
        group_rows+=("${GROUP_LABEL[$group]} ($group)")
    done
    select_indices "Choose one or more extension groups" "${group_rows[@]}" || return 1

    typeset -A chosen_groups
    local index
    for index in "${SELECTED_INDICES[@]}"; do
        chosen_groups[${GROUP_ORDER[$index]}]=1
    done

    local -a extension_ids extension_rows
    local extension
    for extension in "${EXTENSIONS[@]}"; do
        group="${EXTENSION_GROUP[$extension]}"
        (( ${+chosen_groups[$group]} )) || continue
        extension_ids+=("$extension")
        extension_rows+=("${GROUP_LABEL[$group]} — .$extension")
    done
    select_indices "Choose one or more extensions" "${extension_rows[@]}" || return 1

    SELECTED_EXTENSIONS=()
    for index in "${SELECTED_INDICES[@]}"; do
        SELECTED_EXTENSIONS+=("${extension_ids[$index]}")
    done
}

choose_snapshots() {
    [[ -f "$SNAPSHOT_FILE" ]] || {
        fail "no captured handlers exist yet"
        return 1
    }

    local -a snapshot_extensions rows
    local extension bundle group
    while IFS=$'\t' read -r extension bundle; do
        (( ${+EXTENSION_GROUP[$extension]} )) || continue
        group="${EXTENSION_GROUP[$extension]}"
        snapshot_extensions+=("$extension")
        rows+=("${GROUP_LABEL[$group]} — .$extension — $bundle")
    done < "$SNAPSHOT_FILE"
    select_indices "Choose handlers to restore" "${rows[@]}" || return 1

    SELECTED_EXTENSIONS=()
    local index
    for index in "${SELECTED_INDICES[@]}"; do
        SELECTED_EXTENSIONS+=("${snapshot_extensions[$index]}")
    done
}

inspect_handlers_tui() {
    choose_extensions || return 1
    local extension
    for extension in "${SELECTED_EXTENSIONS[@]}"; do
        print
        print -r -- ".$extension"
        handler_details "$extension" || print -r -- "No handler reported."
    done
}

confirm_action() {
    local answer
    read -r "answer?$1 [y/N] " || return 1
    [[ "$answer" == [yY] ]]
}

pause_tui() {
    print
    local ignored
    read -r "ignored?Press Enter to return to the menu."
}

run_tui() {
    while true; do
        print
        print -r -- "default2nvim — $APP_PATH"
        print -r -- "  1) Install Neovim.app"
        print -r -- "  2) Change Neovim.app terminal"
        print -r -- "  3) Choose extensions and set defaults"
        print -r -- "  4) Restore captured previous defaults"
        print -r -- "  5) Inspect current handlers"
        print -r -- "  6) Cleanly uninstall Neovim.app"
        print -r -- "  7) Quit"

        local action
        read -r "action?Action: " || return 0
        case "$action" in
            1)
                choose_terminal || continue
                install_app "$SELECTED_TERMINAL"
                pause_tui
                ;;
            2)
                choose_terminal || continue
                set_terminal_preference "$SELECTED_TERMINAL"
                pause_tui
                ;;
            3)
                resolve_duti || {
                    pause_tui
                    continue
                }
                choose_extensions || continue
                if confirm_action "Set Neovim for ${#SELECTED_EXTENSIONS} extension(s)?"; then
                    set_defaults "${SELECTED_EXTENSIONS[@]}"
                    pause_tui
                fi
                ;;
            4)
                choose_snapshots || {
                    pause_tui
                    continue
                }
                if confirm_action "Restore ${#SELECTED_EXTENSIONS} captured handler(s)?"; then
                    restore_defaults "${SELECTED_EXTENSIONS[@]}"
                    pause_tui
                fi
                ;;
            5)
                resolve_duti || {
                    pause_tui
                    continue
                }
                inspect_handlers_tui
                pause_tui
                ;;
            6)
                if confirm_action "Restore managed defaults and remove Neovim.app?"; then
                    uninstall_app
                    pause_tui
                fi
                ;;
            7|q|quit)
                return 0
                ;;
            *)
                print -u2 -r -- "Choose an action from 1 to 7."
                ;;
        esac
    done
}

load_catalogs || exit 1

if (( $# == 0 )); then
    run_tui
    exit $?
fi

command_name="$1"
shift
case "$command_name" in
    install)
        if (( $# == 0 )); then
            choose_terminal || exit 0
            install_app "$SELECTED_TERMINAL"
        elif (( $# == 1 )); then
            install_app "$1"
        else
            fail "install accepts at most one terminal id"
            exit 1
        fi
        ;;
    set-term)
        if (( $# == 0 )); then
            choose_terminal || exit 0
            set_terminal_preference "$SELECTED_TERMINAL"
        elif (( $# == 1 )); then
            set_terminal_preference "$1"
        else
            fail "set-term accepts at most one terminal id"
            exit 1
        fi
        ;;
    uninstall)
        (( $# == 0 )) || {
            fail "uninstall takes no arguments"
            exit 1
        }
        uninstall_app
        ;;
    set)
        set_defaults "$@"
        ;;
    restore)
        restore_defaults "$@"
        ;;
    status)
        status_table "$@"
        ;;
    list)
        (( $# == 0 )) || {
            fail "list takes no arguments"
            exit 1
        }
        list_catalog
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage >&2
        fail "unknown command: $command_name"
        exit 1
        ;;
esac
