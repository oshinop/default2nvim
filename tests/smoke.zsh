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
[[ ! -e "$PROJECT_ROOT/assets/document-base.svg" ]] || fail "custom document base is still present"
system_document_icon="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns"
[[ -f "$system_document_icon" ]] || fail "macOS GenericDocumentIcon.icns is unavailable"
python_preview="$temp_root/python-icon.png"
/usr/bin/sips -s format png "$app_path/Contents/Resources/python.icns" --out "$python_preview" >/dev/null
python_alpha="$(/usr/bin/sips -g hasAlpha "$python_preview" | /usr/bin/sed -n 's/.*hasAlpha: //p')"
assert_equal "yes" "$python_alpha" "document icon lost its transparent canvas"
if /usr/bin/grep -q 'M59.2 7H19' "$PROJECT_ROOT/assets/icons/python.svg"; then
    fail "source filetype glyph still contains the old document silhouette"
fi
system_iconset="$temp_root/system-document.iconset"
python_iconset="$temp_root/python-document.iconset"
/usr/bin/iconutil -c iconset "$system_document_icon" -o "$system_iconset"
/usr/bin/iconutil -c iconset "$app_path/Contents/Resources/python.icns" -o "$python_iconset"
pixel_comparator="$temp_root/compare-icon-region"
/usr/bin/swiftc -O -framework AppKit -o "$pixel_comparator" - <<'SWIFT'
import AppKit
import ImageIO

func normalizedPixels(at path: String) throws -> [UInt8] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          let region = image.cropping(to: CGRect(x: 768, y: 64, width: 128, height: 128)) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    var pixels = [UInt8](repeating: 0, count: 128 * 128 * 4)
    guard let context = CGContext(
        data: &pixels,
        width: 128,
        height: 128,
        bitsPerComponent: 8,
        bytesPerRow: 128 * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw CocoaError(.coderInvalidValue)
    }
    context.interpolationQuality = .none
    context.draw(region, in: CGRect(x: 0, y: 0, width: 128, height: 128))
    return pixels
}

guard CommandLine.arguments.count == 3,
      try normalizedPixels(at: CommandLine.arguments[1]) == normalizedPixels(at: CommandLine.arguments[2]) else {
    exit(1)
}
SWIFT
if ! "$pixel_comparator" "$system_iconset/icon_512x512@2x.png" \
    "$python_iconset/icon_512x512@2x.png"; then
    fail "document icon does not preserve Apple's extracted generic icon"
fi
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

# Both Ghostty paths must preserve argv: a first instance receives one config
# argument, while an existing instance receives an AppleScript window request.
ghostty_plan_source="$temp_root/GhosttyLaunchPlanTests.swift"
ghostty_plan_test="$temp_root/ghostty-launch-plan-test"
/bin/cat > "$ghostty_plan_source" <<'SWIFT'
import Darwin
import Foundation

@main
struct GhosttyLaunchPlanTests {
    static func main() {
        let workingDirectory = "/tmp/work dir"
        let command = [
            "/usr/bin/env",
            "NVIMBRIDGE_NVIM=/tmp/fake nvim",
            "/bin/zsh",
            "-l",
            "/tmp/launcher's script.zsh",
            "/tmp/file with spaces.swift",
        ]
        let encodedCommand = command
            .map(GhosttyLaunchPlan.shellQuote)
            .joined(separator: " ")

        let cold = GhosttyLaunchPlan.coldArguments(
            workingDirectory: workingDirectory,
            command: command
        )
        guard cold == [
            "--working-directory=\(workingDirectory)",
            "--quit-after-last-window-closed=true",
            "--initial-command=shell:\(encodedCommand)",
        ], cold.allSatisfy({ $0.hasPrefix("--") }) else {
            exit(1)
        }

        let running = GhosttyLaunchPlan.running(
            bundleIdentifier: "com.mitchellh.ghostty",
            workingDirectory: workingDirectory,
            command: command
        )
        guard running.arguments == [workingDirectory, encodedCommand],
              running.lines.contains("tell application id \"com.mitchellh.ghostty\""),
              running.lines.contains("new window with configuration config") else {
            exit(1)
        }
    }
}
SWIFT
/usr/bin/swiftc -parse-as-library -D NVIMBRIDGE_TESTING -O -framework AppKit \
    -o "$ghostty_plan_test" "$PROJECT_ROOT/app/NvimBridge.swift" "$ghostty_plan_source"
"$ghostty_plan_test" || fail "Ghostty warm/cold launch plans are invalid"

# Keep Ghostty's command inside one option. Bare `-e` operands are also treated
# as files by AppKit and make Ghostty ask to execute /bin/zsh a second time.
ghostty_test_app="$temp_root/Neovim Prompt Test.app"
fake_ghostty_app="$temp_root/FakeGhostty.app"
fake_ghostty_contents="$fake_ghostty_app/Contents"
fake_ghostty_capture="$temp_root/ghostty-launch-arguments.txt"
fake_nvim_capture="$temp_root/ghostty-nvim-arguments.txt"
fake_nvim="$temp_root/fake nvim"
fake_ghostty_identifier="moe.oshino.nvimbridge.tests.fakeghostty"
/bin/cp -R "$app_path" "$ghostty_test_app"
/bin/mkdir -p "$fake_ghostty_contents/MacOS"
/bin/cat > "$fake_ghostty_contents/Info.plist" <<FAKE_GHOSTTY_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>FakeGhostty</string>
    <key>CFBundleIdentifier</key>
    <string>$fake_ghostty_identifier</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSBackgroundOnly</key>
    <true/>
</dict>
</plist>
FAKE_GHOSTTY_PLIST
/usr/bin/swiftc -O -o "$fake_ghostty_contents/MacOS/FakeGhostty" - <<FAKE_GHOSTTY_SWIFT
import Darwin
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst()).filter {
    !\$0.hasPrefix("-psn_")
}
try (arguments.joined(separator: "\\n") + "\\n").write(
    toFile: "$fake_ghostty_capture",
    atomically: true,
    encoding: .utf8
)

let commandPrefix = "--initial-command=shell:"
guard let command = arguments.first(where: { \$0.hasPrefix(commandPrefix) }) else {
    exit(64)
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/bash")
let shellCommand = String(command.dropFirst(commandPrefix.count))
process.arguments = ["--noprofile", "--norc", "-c", "exec -l \(shellCommand)"]
do {
    try process.run()
} catch {
    exit(71)
}
process.waitUntilExit()
exit(process.terminationStatus)
FAKE_GHOSTTY_SWIFT
/bin/cat > "$fake_nvim" <<FAKE_NVIM_GHOSTTY
#!/bin/zsh
for argument in "\$@"; do
    print -r -- "\$argument"
done > "$fake_nvim_capture"
FAKE_NVIM_GHOSTTY
/bin/chmod 755 "$fake_nvim"
/usr/bin/plutil -lint "$fake_ghostty_contents/Info.plist" >/dev/null
/usr/bin/codesign --force --sign - "$fake_ghostty_app" >/dev/null 2>&1

ghostty_test_catalog="$ghostty_test_app/Contents/Resources/TerminalBackends.plist"
/usr/libexec/PlistBuddy -c "Set :0:bundleIdentifier $fake_ghostty_identifier" \
    "$ghostty_test_catalog"
/usr/libexec/PlistBuddy -c "Set :0:fallbackPaths:0 $fake_ghostty_app" \
    "$ghostty_test_catalog"
/usr/bin/codesign --force --deep --sign - "$ghostty_test_app" >/dev/null 2>&1

prompt_document_dir="$temp_root/prompt files"
prompt_document="$prompt_document_dir/it's spaced.swift"
/bin/mkdir -p "$prompt_document_dir"
: > "$prompt_document"
NVIMBRIDGE_TERMINAL=ghostty NVIMBRIDGE_NVIM="$fake_nvim" \
    "$ghostty_test_app/Contents/MacOS/NvimBridge" "$prompt_document"
for attempt in {1..100}; do
    [[ -f "$fake_ghostty_capture" && -f "$fake_nvim_capture" ]] && break
    /bin/sleep 0.05
done
[[ -f "$fake_ghostty_capture" ]] || fail "Ghostty test app was not launched"
[[ -f "$fake_nvim_capture" ]] || fail "Ghostty initial command was not executed"

typeset -a ghostty_arguments
ghostty_arguments=()
while IFS= read -r argument; do
    [[ "$argument" == -psn_* ]] || ghostty_arguments+=("$argument")
done < "$fake_ghostty_capture"
assert_equal "3" "${#ghostty_arguments}" "Ghostty received unexpected launch operands"
[[ "${ghostty_arguments[1]}" == --working-directory=* ]] || \
    fail "Ghostty did not receive a working directory option"
ghostty_working_directory="${ghostty_arguments[1]#--working-directory=}"
[[ "$ghostty_working_directory" -ef "$prompt_document_dir" ]] || \
    fail "Ghostty received the wrong working directory: $ghostty_working_directory"
assert_equal "--quit-after-last-window-closed=true" "${ghostty_arguments[2]}" \
    "Ghostty did not retain -e lifecycle behavior"
[[ "${ghostty_arguments[3]}" == --initial-command=shell:* ]] || \
    fail "Ghostty did not receive one encoded initial command"
for argument in "${ghostty_arguments[@]}"; do
    [[ "$argument" == --* ]] || fail "Ghostty received bare command operand: $argument"
done

ghostty_nvim_arguments=("${(@f)$(<"$fake_nvim_capture")}")
assert_equal "2" "${#ghostty_nvim_arguments}" "Ghostty changed the Neovim argument count"
assert_equal "--" "${ghostty_nvim_arguments[1]}" "Ghostty launch omitted the option terminator"
[[ "${ghostty_nvim_arguments[2]}" -ef "$prompt_document" ]] || \
    fail "Ghostty launch damaged a spaced or quoted path: ${ghostty_nvim_arguments[2]}"

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
