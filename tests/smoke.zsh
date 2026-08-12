#!/bin/zsh

emulate -L zsh
setopt err_exit no_unset pipe_fail

readonly PROJECT_ROOT="${0:A:h:h}"
temp_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/default2nvim-smoke.XXXXXX")"
temp_root="${temp_root:A}"
cleanup() {
    [[ -d "$temp_root" ]] && /bin/rm -rf -- "$temp_root"
}
trap cleanup EXIT

fail() {
    print -u2 -r -- "smoke: $*"
    exit 1
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [[ "$actual" == "$expected" ]] || \
        fail "$message (expected '$expected', got '$actual')"
}
assert_rejects_non_macos() {
    local script="$1"
    local expected="$2"
    local output
    if output="$(/bin/zsh -c 'OSTYPE=linux; source "$1"' _ "$script" 2>&1)"; then
        fail "${script:t} accepted a non-macOS environment"
    fi
    assert_equal "$expected" "$output" "${script:t} reported the wrong platform error"
}

assert_rejects_non_macos "$PROJECT_ROOT/default2nvim.zsh" \
    "default2nvim: macOS is required"
assert_rejects_non_macos "$PROJECT_ROOT/scripts/build-app.zsh" \
    "build-app: macOS is required"
assert_rejects_non_macos "$PROJECT_ROOT/app/launch-nvim.zsh" \
    "NvimBridge: macOS is required"

# Build into the fixed project output and validate the app identity.
app_path="$PROJECT_ROOT/build/Neovim.app"
if "$PROJECT_ROOT/scripts/build-app.zsh" --output "$temp_root/ignored.app" >/dev/null 2>&1; then
    fail "build script still accepts installation or output arguments"
fi
build_output="$("$PROJECT_ROOT/scripts/build-app.zsh")"
assert_equal "$app_path" "$build_output" "build script reported the wrong output path"
[[ -x "$app_path/Contents/MacOS/NvimBridge" ]] || fail "internal wrapper executable was not built"
[[ -x "$app_path/Contents/Resources/launch-nvim.zsh" ]] || fail "launcher resource was not installed"
[[ -f "$app_path/Contents/Resources/TerminalBackends.plist" ]] || fail "terminal backend catalog was not embedded"
[[ ! -e "$app_path/Contents/Resources/TerminalBackend.plist" ]] || fail "mutable terminal choice is still embedded in the app"
[[ ! -e "$app_path/Contents/Resources/THIRD_PARTY_LICENSES" ]] || fail "app still bundles project self-attribution"
[[ -f "$app_path/Contents/Resources/python.icns" ]] || fail "Python document icon was not generated"
[[ -f "$app_path/Contents/Resources/AppIcon.icns" ]] || fail "application icon was not generated"
/usr/bin/plutil -lint "$app_path/Contents/Info.plist" >/dev/null
/usr/bin/plutil -lint "$app_path/Contents/Resources/TerminalBackends.plist" >/dev/null
/usr/bin/codesign --verify --deep --strict "$app_path"

bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")"
assert_equal "moe.oshino.nvimbridge" "$bundle_identifier" "wrong bundle identifier"
bundle_name="$(/usr/bin/plutil -extract CFBundleDisplayName raw "$app_path/Contents/Info.plist")"
assert_equal "Neovim" "$bundle_name" "wrong user-visible app name"
executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw "$app_path/Contents/Info.plist")"
assert_equal "NvimBridge" "$executable_name" "wrong internal wrapper name"
first_backend="$(/usr/libexec/PlistBuddy -c 'Print :0:id' "$app_path/Contents/Resources/TerminalBackends.plist")"
last_backend="$(/usr/libexec/PlistBuddy -c 'Print :5:id' "$app_path/Contents/Resources/TerminalBackends.plist")"
assert_equal "ghostty" "$first_backend" "terminal catalog starts with the wrong backend"
assert_equal "terminal" "$last_backend" "terminal catalog is incomplete"

# NVIMBRIDGE_NVIM remains the sole explicit Neovim path override.
launcher_capture="$temp_root/launcher-arguments.txt"
fake_nvim="$temp_root/fake-nvim"
/bin/cat > "$fake_nvim" <<FAKE_NVIM
#!/bin/zsh
for argument in "\$@"; do
    print -r -- "\$argument"
done > "$launcher_capture"
FAKE_NVIM
/bin/chmod 755 "$fake_nvim"
NVIMBRIDGE_NVIM="$fake_nvim" /bin/zsh "$PROJECT_ROOT/app/launch-nvim.zsh" \
    "$temp_root/file with spaces.py" "-leading-dash"
launcher_arguments=("${(@f)$(<"$launcher_capture")}")
assert_equal "3" "${#launcher_arguments}" "launcher changed the argument count"
assert_equal "--" "${launcher_arguments[1]}" "launcher omitted the option terminator"
assert_equal "$temp_root/file with spaces.py" "${launcher_arguments[2]}" "launcher damaged a spaced path"
assert_equal "-leading-dash" "${launcher_arguments[3]}" "launcher damaged an option-looking path"

# Isolate installation, UserDefaults, git, and temporary checkout paths.
fake_home="$temp_root/home"
preferences_home="$temp_root/preferences-home"
fake_bin="$temp_root/bin"
failing_bin="$temp_root/failing-bin"
install_tmp_root="$temp_root/install-tmp"
/bin/mkdir -p \
    "$fake_home/Applications" \
    "$preferences_home/Library/Preferences" \
    "$fake_home/.cargo" \
    "$fake_bin" \
    "$failing_bin" \
    "$install_tmp_root"
/usr/bin/touch "$fake_home/.cargo/env"
application_support_dir="$fake_home/Library/Application Support/default2nvim"
snapshot_file="$application_support_dir/original-handlers.tsv"
for terminal_app in Ghostty WezTerm kitty Alacritty iTerm; do
    /bin/mkdir -p "$fake_home/Applications/$terminal_app.app"
done

git_log="$temp_root/git.log"
/bin/cat > "$fake_bin/git" <<FAKE_GIT
#!/bin/zsh
for argument in "\$@"; do
    print -r -- "\$argument" >> "$git_log"
done
[[ "\$1" == clone && "\$2" == --depth && "\$3" == 1 && "\$4" == --quiet ]] || exit 64
[[ "\$5" == "https://github.com/oshinop/default2nvim" && \$# == 6 ]] || exit 64
/bin/mkdir -p "\$6" || exit 1
/bin/cp -R "$PROJECT_ROOT/." "\$6" || exit 1
FAKE_GIT
/bin/chmod 755 "$fake_bin/git"
/bin/cat > "$failing_bin/git" <<'FAILING_GIT'
#!/bin/zsh
exit 42
FAILING_GIT
/bin/chmod 755 "$failing_bin/git"

manager_base_environment=(
    "HOME=$fake_home"
    "CFFIXED_USER_HOME=$preferences_home"
    "PATH=$fake_bin:$PATH"
    "TMPDIR=$install_tmp_root"
)

# Every backend can be selected through the promoted command without rebuilding.
terminal_ids=(ghostty wezterm kitty alacritty iterm2 terminal)
for terminal_id in "${terminal_ids[@]}"; do
    /usr/bin/env "${manager_base_environment[@]}" \
        "$PROJECT_ROOT/default2nvim.zsh" set-term "$terminal_id" >/dev/null
    saved_terminal="$(/usr/bin/env "CFFIXED_USER_HOME=$preferences_home" \
        /usr/bin/defaults read moe.oshino.nvimbridge terminalBackend)"
    assert_equal "$terminal_id" "$saved_terminal" "set-term saved the wrong backend"
done

# Association behavior uses a deterministic duti substitute.
duti_log="$temp_root/duti.log"
duti_state="$temp_root/duti-state"
/bin/mkdir -p "$duti_state"
fake_duti="$temp_root/duti"
/bin/cat > "$fake_duti" <<FAKE_DUTI
#!/bin/zsh
case "\$1" in
    -x)
        extension="\${2#.}"
        state_file="$duti_state/\$extension"
        if [[ -f "\$state_file" ]]; then
            bundle="\$(<"\$state_file")"
        else
            bundle='com.apple.TextEdit'
        fi
        print -r -- 'Handler'
        print -r -- '/Applications/Handler.app'
        print -r -- "\$bundle"
        ;;
    -s)
        extension="\${3#.}"
        printf 'set\t%s\t%s\t%s\n' "\$2" "\$3" "\$4" >> "$duti_log"
        print -r -- "\$2" > "$duti_state/\$extension"
        ;;
    *)
        exit 64
        ;;
esac
FAKE_DUTI
/bin/chmod 755 "$fake_duti"
manager_environment=(
    "${manager_base_environment[@]}"
    "DEFAULT2NVIM_DUTI=$fake_duti"
)

# A raw.githubusercontent-style temporary script clones runtime assets and cleans them.
raw_script="$temp_root/default2nvim-raw.zsh"
/bin/cp "$PROJECT_ROOT/default2nvim.zsh" "$raw_script"
raw_help="$(/usr/bin/env "${manager_environment[@]}" /bin/zsh "$raw_script" --help)"
[[ "$raw_help" == 'Usage: default2nvim.zsh '* ]] || fail "raw script did not execute after cloning assets"
raw_git_arguments=("${(@f)$(<"$git_log")}")
assert_equal "6" "${#raw_git_arguments}" "raw script invoked git with the wrong argument count"
assert_equal "clone" "${raw_git_arguments[1]}" "raw script did not clone runtime assets"
assert_equal "https://github.com/oshinop/default2nvim" "${raw_git_arguments[5]}" "raw script cloned the wrong repository"
[[ "${raw_git_arguments[6]}" == "$install_tmp_root"/default2nvim-runtime.*/default2nvim ]] || \
    fail "raw script cloned outside its temporary runtime directory"
[[ ! -e "${raw_git_arguments[6]}" ]] || fail "raw script left its runtime checkout behind"
: > "$git_log"

# Failed and successful installs both remove their temporary clones.
failing_environment=(
    "HOME=$fake_home"
    "CFFIXED_USER_HOME=$preferences_home"
    "PATH=$failing_bin:$PATH"
    "TMPDIR=$install_tmp_root"
    "DEFAULT2NVIM_DUTI=$fake_duti"
)
if /usr/bin/env "${failing_environment[@]}" \
    "$PROJECT_ROOT/default2nvim.zsh" install kitty >/dev/null 2>&1; then
    fail "install succeeded after git clone failed"
fi
temporary_checkouts=("$install_tmp_root"/default2nvim-install.*(N))
assert_equal "0" "${#temporary_checkouts}" "failed install left a temporary checkout"

/usr/bin/env "${manager_environment[@]}" \
    "$PROJECT_ROOT/default2nvim.zsh" install kitty >/dev/null
installed_app="$fake_home/Applications/Neovim.app"
[[ -d "$installed_app" ]] || fail "install did not create the fixed Neovim.app path"
installed_terminal="$(/usr/bin/env "CFFIXED_USER_HOME=$preferences_home" \
    /usr/bin/defaults read moe.oshino.nvimbridge terminalBackend)"
assert_equal "kitty" "$installed_terminal" "install ignored its terminal argument"
[[ -d "$app_path" ]] || fail "remote install removed the project build output"
installed_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$installed_app/Contents/Info.plist")"
assert_equal "moe.oshino.nvimbridge" "$installed_identifier" "install copied the wrong app"
git_arguments=("${(@f)$(<"$git_log")}")
assert_equal "6" "${#git_arguments}" "install invoked git with the wrong argument count"
assert_equal "clone" "${git_arguments[1]}" "install did not clone the repository"
assert_equal "--depth" "${git_arguments[2]}" "install did not request a shallow clone"
assert_equal "1" "${git_arguments[3]}" "install used the wrong clone depth"
assert_equal "--quiet" "${git_arguments[4]}" "install did not suppress git progress"
assert_equal "https://github.com/oshinop/default2nvim" "${git_arguments[5]}" "install cloned the wrong repository"
[[ "${git_arguments[6]}" == "$install_tmp_root"/default2nvim-install.*/default2nvim ]] || \
    fail "install cloned outside its temporary directory"
[[ ! -e "${git_arguments[6]}" ]] || fail "successful install left its cloned checkout behind"
temporary_checkouts=("$install_tmp_root"/default2nvim-install.*(N))
assert_equal "0" "${#temporary_checkouts}" "successful install left a temporary checkout"

# The pure-Zsh single-selection menu changes the terminal without rebuilding.
app_checksum_before="$(/usr/bin/shasum -a 256 "$installed_app/Contents/MacOS/NvimBridge")"
print -r -- 2 | /usr/bin/env "${manager_environment[@]}" \
    "$PROJECT_ROOT/default2nvim.zsh" set-term >/dev/null
app_checksum_after="$(/usr/bin/shasum -a 256 "$installed_app/Contents/MacOS/NvimBridge")"
assert_equal "$app_checksum_before" "$app_checksum_after" "terminal selection rebuilt Neovim.app"
menu_terminal="$(/usr/bin/env "CFFIXED_USER_HOME=$preferences_home" \
    /usr/bin/defaults read moe.oshino.nvimbridge terminalBackend)"
assert_equal "wezterm" "$menu_terminal" "pure-Zsh terminal menu chose the wrong backend"

# Drive the main TUI: action 3, Python group, .py and .pyi via a numeric range,
# confirm, press Enter, then quit.
tui_output="$(
    printf '3\n32\n1-2\ny\n\n7\n' | \
        /usr/bin/env "${manager_environment[@]}" "$PROJECT_ROOT/default2nvim.zsh"
)"
[[ "$tui_output" == *'Choose one or more extension groups'* ]] || fail "TUI did not show group selection"
[[ "$tui_output" == *'Choose one or more extensions'* ]] || fail "TUI did not show extension selection"
[[ "$tui_output" == *'Applied: 2; failed: 0'* ]] || fail "TUI did not apply the selected range"

# Repeating one association must preserve its original handler.
/usr/bin/env "${manager_environment[@]}" "$PROJECT_ROOT/default2nvim.zsh" set py >/dev/null
[[ -f "$snapshot_file" ]] || fail "association snapshot is missing from Application Support"
snapshot_lines=("${(@f)$(<"$snapshot_file")}")
assert_equal "2" "${#snapshot_lines}" "snapshot did not deduplicate repeated associations"
assert_equal $'py\tcom.apple.TextEdit' "${snapshot_lines[1]}" "wrong .py original handler"
assert_equal $'pyi\tcom.apple.TextEdit' "${snapshot_lines[2]}" "wrong .pyi original handler"

print -r -- $'orphaned\tcom.apple.TextEdit' >> "$snapshot_file"
print -r -- "moe.oshino.nvimbridge" > "$duti_state/orphaned"

# A complete uninstall deletes the whole defaults domain, not only terminalBackend.
/usr/bin/env "CFFIXED_USER_HOME=$preferences_home" \
    /usr/bin/defaults write moe.oshino.nvimbridge leftoverSetting -string remove-me
/usr/bin/env "${manager_environment[@]}" \
    "$PROJECT_ROOT/default2nvim.zsh" uninstall >/dev/null
[[ ! -e "$installed_app" ]] || fail "top-level uninstall left Neovim.app behind"
[[ ! -e "$application_support_dir" ]] || fail "top-level uninstall left Application Support data behind"
assert_equal "com.apple.TextEdit" "$(<"$duti_state/py")" "uninstall did not restore .py"
assert_equal "com.apple.TextEdit" "$(<"$duti_state/pyi")" "uninstall did not restore .pyi"
assert_equal "com.apple.TextEdit" "$(<"$duti_state/orphaned")" "uninstall did not restore snapshot-only extension"
if /usr/bin/env "CFFIXED_USER_HOME=$preferences_home" \
    /usr/bin/defaults read moe.oshino.nvimbridge >/dev/null 2>&1; then
    fail "top-level uninstall left the wrapper defaults domain behind"
fi

duti_lines=("${(@f)$(<"$duti_log")}")
assert_equal "6" "${#duti_lines}" "manager made the wrong number of duti changes"
assert_equal $'set\tmoe.oshino.nvimbridge\t.py\tall' "${duti_lines[1]}" "manager set the wrong .py bundle"
assert_equal $'set\tmoe.oshino.nvimbridge\t.pyi\tall' "${duti_lines[2]}" "manager set the wrong .pyi bundle"
assert_equal $'set\tcom.apple.TextEdit\t.py\tall' "${duti_lines[4]}" "uninstall restored the wrong .py bundle"
assert_equal $'set\tcom.apple.TextEdit\t.pyi\tall' "${duti_lines[5]}" "uninstall restored the wrong .pyi bundle"
assert_equal $'set\tcom.apple.TextEdit\t.orphaned\tall' "${duti_lines[6]}" "uninstall missed a snapshot-only extension"

# A single numeric choice exits the dependency-free main TUI.
quit_output="$(print -r -- 7 | /usr/bin/env "${manager_environment[@]}" "$PROJECT_ROOT/default2nvim.zsh")"
[[ "$quit_output" == *'default2nvim —'* ]] || fail "running without arguments did not enter the Zsh TUI"
for obsolete_command in tui wrapper; do
    if /usr/bin/env "${manager_environment[@]}" \
        "$PROJECT_ROOT/default2nvim.zsh" "$obsolete_command" >/dev/null 2>&1; then
        fail "obsolete top-level command is still accepted: $obsolete_command"
    fi
done
/usr/bin/env "${manager_base_environment[@]}" \
    "$PROJECT_ROOT/default2nvim.zsh" uninstall >/dev/null

print -r -- "smoke: all checks passed"
