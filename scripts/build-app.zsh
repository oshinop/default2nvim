#!/bin/zsh

emulate -L zsh
setopt err_exit no_unset pipe_fail
if [[ "$OSTYPE" != darwin* ]]; then
    print -u2 -r -- "build-app: macOS is required"
    exit 1
fi

readonly SCRIPT_DIR="${0:A:h}"
readonly PROJECT_ROOT="${SCRIPT_DIR:h}"
readonly APP_DISPLAY_NAME="Neovim"
readonly APP_BUNDLE_NAME="${APP_DISPLAY_NAME}.app"
readonly BUNDLE_IDENTIFIER="moe.oshino.nvimbridge"
readonly EXECUTABLE_NAME="NvimBridge"
readonly APP_VERSION="3.0.0"
readonly OUTPUT_PATH="$PROJECT_ROOT/build/$APP_BUNDLE_NAME"

fail() {
    print -u2 -r -- "build-app: $*"
    exit 1
}
(( $# == 0 )) || fail "takes no arguments"

readonly GROUPS_FILE="$PROJECT_ROOT/resources/groups.tsv"
readonly EXTENSIONS_FILE="$PROJECT_ROOT/resources/extensions.tsv"
readonly TERMINALS_FILE="$PROJECT_ROOT/resources/terminals.tsv"
readonly ICONS_DIR="$PROJECT_ROOT/assets/icons"
readonly APP_ICON="$PROJECT_ROOT/assets/app-icon.svg"
readonly GENERIC_DOCUMENT_ICON="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns"
readonly SWIFT_SOURCE="$PROJECT_ROOT/app/NvimBridge.swift"
readonly COMPOSITOR_SOURCE="$PROJECT_ROOT/scripts/compose-document-icon.swift"
readonly LAUNCHER_SOURCE="$PROJECT_ROOT/app/launch-nvim.zsh"

for required_file in \
    "$GROUPS_FILE" \
    "$EXTENSIONS_FILE" \
    "$TERMINALS_FILE" \
    "$APP_ICON" \
    "$GENERIC_DOCUMENT_ICON" \
    "$SWIFT_SOURCE" \
    "$COMPOSITOR_SOURCE" \
    "$LAUNCHER_SOURCE"; do
    [[ -f "$required_file" ]] || fail "missing required file: $required_file"
done


readonly SWIFTC="${commands[swiftc]:-}"
[[ -n "$SWIFTC" ]] || fail "swiftc is required (install Xcode Command Line Tools)"
[[ -x /usr/bin/sips ]] || fail "sips is required"
[[ -x /usr/bin/iconutil ]] || fail "iconutil is required"
[[ -x /usr/bin/codesign ]] || fail "codesign is required"

work_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/nvimbridge.XXXXXX")"
work_root="${work_root:A}"
cleanup() {
    [[ -d "$work_root" ]] && /bin/rm -rf -- "$work_root"
}
trap cleanup EXIT

bundle="$work_root/$APP_BUNDLE_NAME"
contents="$bundle/Contents"
macos_dir="$contents/MacOS"
resources_dir="$contents/Resources"
/bin/mkdir -p "$macos_dir" "$resources_dir"

# Preserve every size-specific representation Apple ships for the generic
# document instead of redrawing or downsampling its silhouette.
generic_document_iconset="$work_root/GenericDocumentIcon.iconset"
/usr/bin/iconutil -c iconset "$GENERIC_DOCUMENT_ICON" -o "$generic_document_iconset" || \
    fail "could not extract macOS GenericDocumentIcon.icns"
[[ -f "$generic_document_iconset/icon_512x512@2x.png" ]] || \
    fail "macOS generic document icon is missing its 1024-pixel representation"

# Load and validate the shared association catalog.
typeset -A group_labels group_icons group_extensions seen_extensions required_icons
typeset -a group_order
while IFS=$'\t' read -r group label icon; do
    [[ -z "$group" || "$group" == \#* ]] && continue
    (( ${+group_labels[$group]} == 0 )) || fail "duplicate group: $group"
    [[ "$label" != *'&'* && "$label" != *'<'* && "$label" != *'>'* ]] || \
        fail "group label contains an XML-reserved character: $label"
    group_order+=("$group")
    group_labels[$group]="$label"
    group_icons[$group]="$icon"
    required_icons[$icon]=1
done < "$GROUPS_FILE"

while IFS=$'\t' read -r extension group; do
    [[ -z "$extension" || "$extension" == \#* ]] && continue
    (( ${+group_labels[$group]} )) || fail "unknown group '$group' for .$extension"
    (( ${+seen_extensions[$extension]} == 0 )) || fail "duplicate extension: .$extension"
    [[ "$extension" != *'&'* && "$extension" != *'<'* && "$extension" != *'>'* ]] || \
        fail "extension contains an XML-reserved character: .$extension"
    seen_extensions[$extension]=1
    group_extensions[$group]+="$extension"$'\n'
done < "$EXTENSIONS_FILE"

(( ${#seen_extensions} > 0 )) || fail "association catalog is empty"
for icon in ${(k)required_icons}; do
    [[ -f "$ICONS_DIR/$icon" ]] || fail "missing file icon: assets/icons/$icon"
done

# Compile the event-aware app and the build-time document icon compositor.
"$SWIFTC" \
    -O \
    -whole-module-optimization \
    -framework AppKit \
    -o "$macos_dir/$EXECUTABLE_NAME" \
    "$SWIFT_SOURCE"
"$SWIFTC" \
    -O \
    -whole-module-optimization \
    -framework AppKit \
    -o "$work_root/compose-document-icon" \
    "$COMPOSITOR_SOURCE"
/bin/chmod 755 "$macos_dir/$EXECUTABLE_NAME"
/bin/cp "$LAUNCHER_SOURCE" "$resources_dir/launch-nvim.zsh"
/bin/chmod 755 "$resources_dir/launch-nvim.zsh"

# Embed the immutable backend catalog. The selected backend lives in the
# bundle's UserDefaults domain, so changing it never mutates or re-signs the app.
terminal_plist="$resources_dir/TerminalBackends.plist"
{
    /bin/cat <<'TERMINAL_HEADER'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
TERMINAL_HEADER
    terminal_count=0
    while IFS=$'\t' read -r terminal_id terminal_name terminal_bundle terminal_fallbacks; do
        [[ -z "$terminal_id" || "$terminal_id" == \#* ]] && continue
        for value in "$terminal_id" "$terminal_name" "$terminal_bundle" "$terminal_fallbacks"; do
            [[ "$value" != *'&'* && "$value" != *'<'* && "$value" != *'>'* ]] || \
                fail "terminal metadata contains an XML-reserved character: $value"
        done
        print -r -- '    <dict>'
        print -r -- '        <key>id</key>'
        print -r -- "        <string>$terminal_id</string>"
        print -r -- '        <key>displayName</key>'
        print -r -- "        <string>$terminal_name</string>"
        print -r -- '        <key>bundleIdentifier</key>'
        print -r -- "        <string>$terminal_bundle</string>"
        print -r -- '        <key>fallbackPaths</key>'
        print -r -- '        <array>'
        fallback_paths=("${(@s:|:)terminal_fallbacks}")
        for fallback_path in "${fallback_paths[@]}"; do
            print -r -- "            <string>$fallback_path</string>"
        done
        print -r -- '        </array>'
        print -r -- '    </dict>'
        (( terminal_count += 1 ))
    done < "$TERMINALS_FILE"
    (( terminal_count > 0 )) || fail "terminal catalog is empty"
    /bin/cat <<'TERMINAL_FOOTER'
</array>
</plist>
TERMINAL_FOOTER
} > "$terminal_plist"
/usr/bin/plutil -lint "$terminal_plist" >/dev/null

make_icns_from_png() {
    local master="$1"
    local destination="$2"
    local stem="${destination:t:r}"
    local icon_workspace="$work_root/icon-work-$stem"
    local iconset="$icon_workspace/$stem.iconset"
    local specification size filename
    local -a specifications=(
        '16:icon_16x16.png'
        '32:icon_16x16@2x.png'
        '32:icon_32x32.png'
        '64:icon_32x32@2x.png'
        '128:icon_128x128.png'
        '256:icon_128x128@2x.png'
        '256:icon_256x256.png'
        '512:icon_256x256@2x.png'
        '512:icon_512x512.png'
        '1024:icon_512x512@2x.png'
    )

    /bin/mkdir -p "$iconset"
    for specification in "${specifications[@]}"; do
        size="${specification%%:*}"
        filename="${specification#*:}"
        /usr/bin/sips -z "$size" "$size" "$master" --out "$iconset/$filename" >/dev/null
    done
    /usr/bin/iconutil -c icns "$iconset" -o "$destination"
}

make_icns() {
    local source_svg="$1"
    local destination="$2"
    local master="$work_root/${destination:t:r}-master.png"
    /usr/bin/sips -s format png -z 1024 1024 "$source_svg" --out "$master" >/dev/null
    make_icns_from_png "$master" "$destination"
}

make_document_icns() {
    local glyph_svg="$1"
    local destination="$2"
    local stem="${destination:t:r}"
    local icon_workspace="$work_root/document-icon-$stem"
    local iconset="$icon_workspace/$stem.iconset"
    local base_png filename size glyph_size glyph_png

    /bin/mkdir -p "$iconset"
    for base_png in "$generic_document_iconset"/*.png; do
        filename="${base_png:t}"
        size="$(/usr/bin/sips -g pixelWidth "$base_png" | /usr/bin/sed -n 's/.*pixelWidth: //p')"
        [[ "$size" == <-> ]] || fail "could not read generic document icon size: $filename"
        glyph_size=$(( (size * 9 + 10) / 20 ))
        glyph_png="$icon_workspace/${filename%.png}-glyph.png"

        /usr/bin/sips -s format png -z "$glyph_size" "$glyph_size" \
            "$glyph_svg" --out "$glyph_png" >/dev/null
        "$work_root/compose-document-icon" "$base_png" "$glyph_png" \
            "$iconset/$filename" || fail "could not compose document icon: ${glyph_svg:t}"
    done
    /usr/bin/iconutil -c icns "$iconset" -o "$destination" || \
        fail "could not compile document icon: ${glyph_svg:t}"
}

# Overlay each colored glyph on Apple's extracted macOS generic document icon.
for icon in ${(ok)required_icons}; do
    icon_stem="${icon%.svg}"
    make_document_icns "$ICONS_DIR/$icon" "$resources_dir/$icon_stem.icns"
done
make_icns "$APP_ICON" "$resources_dir/AppIcon.icns"

# Generate one document declaration per visual group. CFBundleTypeExtensions is
# intentionally used because duti also resolves the selected handler by suffix.
plist="$contents/Info.plist"
{
    /bin/cat <<PLIST_HEADER
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundleDocumentTypes</key>
    <array>
PLIST_HEADER

    for group in "${group_order[@]}"; do
        extensions_for_group="${group_extensions[$group]-}"
        [[ -n "$extensions_for_group" ]] || continue
        icon_file="${group_icons[$group]%.svg}.icns"
        print -r -- '        <dict>'
        print -r -- '            <key>CFBundleTypeExtensions</key>'
        print -r -- '            <array>'
        for extension in ${(f)extensions_for_group}; do
            print -r -- "                <string>$extension</string>"
        done
        print -r -- '            </array>'
        print -r -- '            <key>CFBundleTypeIconFile</key>'
        print -r -- "            <string>$icon_file</string>"
        print -r -- '            <key>CFBundleTypeName</key>'
        print -r -- "            <string>${group_labels[$group]}</string>"
        print -r -- '            <key>CFBundleTypeRole</key>'
        print -r -- '            <string>Editor</string>'
        print -r -- '            <key>LSHandlerRank</key>'
        print -r -- '            <string>Alternate</string>'
        print -r -- '        </dict>'
    done

    /bin/cat <<PLIST_FOOTER
    </array>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>
    <string>300</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>NvimBridge uses Apple Events only when launching Neovim in iTerm2 or Terminal.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST_FOOTER
} > "$plist"

/usr/bin/plutil -lint "$plist" >/dev/null
/usr/bin/codesign --force --sign - --timestamp=none "$bundle" >/dev/null

/bin/mkdir -p "${OUTPUT_PATH:h}"
if [[ -e "$OUTPUT_PATH" ]]; then
    existing_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "$OUTPUT_PATH/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$existing_identifier" == "$BUNDLE_IDENTIFIER" ]] || \
        fail "refusing to replace an unrelated app at $OUTPUT_PATH"
    /bin/rm -rf -- "$OUTPUT_PATH"
fi
/bin/mv "$bundle" "$OUTPUT_PATH"

print -r -- "$OUTPUT_PATH"
