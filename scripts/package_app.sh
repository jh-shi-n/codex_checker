#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
package_root="${script_dir:h}"
configuration="release"
output_path=""
stage_dir=""
stage_owned=0
backup_app=""
backup_owned=0

usage() {
    print "Usage: $0 --output DESTINATION [--configuration release|debug]"
}

while (( $# > 0 )); do
    case "$1" in
        --output)
            (( $# >= 2 )) || { print -u2 "--output requires a path"; exit 2; }
            output_path="$2"
            shift 2
            ;;
        --configuration)
            (( $# >= 2 )) || { print -u2 "--configuration requires a value"; exit 2; }
            configuration="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print -u2 "Unknown argument: $1"
            usage >&2
            exit 2
            ;;
    esac
done

[[ -n "$output_path" ]] || { print -u2 "--output is required"; usage >&2; exit 2; }
[[ "$configuration" == "release" || "$configuration" == "debug" ]] || {
    print -u2 "Unsupported configuration: $configuration"
    exit 2
}

if [[ "$output_path" == *.app ]]; then
    target_app="${output_path:A}"
    destination_dir="${target_app:h}"
    explicit_app_target=1
else
    destination_dir="${output_path:A}"
    target_app="$destination_dir/CodexQuotaMonitor.app"
    explicit_app_target=0
fi

[[ "${target_app:t}" == "CodexQuotaMonitor.app" ]] || {
    print -u2 "Destination must be named CodexQuotaMonitor.app: $target_app"
    exit 2
}

mkdir -p "$destination_dir"
if [[ -e "$target_app" ]]; then
    [[ -d "$target_app" && -d "$target_app/Contents" ]] || {
        print -u2 "Existing destination is not an app bundle directory: $target_app"
        exit 2
    }
    if [[ "$explicit_app_target" != 1 ]]; then
        print -u2 "Refusing to replace an existing app unless --output names that exact .app bundle: $target_app"
        exit 2
    fi
fi

(cd "$package_root" && swift build -c "$configuration" --product CodexQuotaMonitor)
build_bin_path="$(cd "$package_root" && swift build -c "$configuration" --show-bin-path)"
binary="$build_bin_path/CodexQuotaMonitor"
info_plist="$package_root/resource/Info.plist"
[[ -x "$binary" ]] || { print -u2 "Built executable not found: $binary"; exit 1; }
[[ -f "$info_plist" ]] || { print -u2 "Info.plist not found: $info_plist"; exit 1; }

stage_dir="$(mktemp -d "$destination_dir/.CodexQuotaMonitor.stage.XXXXXX")"
stage_owned=1
stage_app="$stage_dir/CodexQuotaMonitor.app"
restore_backup() {
    (( backup_owned )) || return 0
    if [[ -z "$backup_app" || ! -d "$backup_app" ]]; then
        print -u2 "Rollback cannot find preserved app bundle: ${backup_app:-<unset>}"
        return 1
    fi
    if [[ -e "$target_app" ]]; then
        print -u2 "Rollback will not overwrite an existing target: $target_app"
        return 1
    fi
    if mv -- "$backup_app" "$target_app"; then
        backup_owned=0
        return 0
    fi
    print -u2 "Rollback failed; preserved old app bundle at: $backup_app"
    return 1
}

cleanup() {
    if (( stage_owned )) && [[ -n "$stage_dir" && -d "$stage_dir" ]]; then
        rm -rf -- "$stage_dir"
    fi
    if (( backup_owned )); then
        restore_backup || print -u2 "Old app bundle remains preserved at: $backup_app"
    fi
}
trap cleanup EXIT INT TERM

mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
cp -- "$binary" "$stage_app/Contents/MacOS/CodexQuotaMonitor"
cp -- "$info_plist" "$stage_app/Contents/Info.plist"
chmod 755 "$stage_app/Contents/MacOS/CodexQuotaMonitor"

[[ -x "$stage_app/Contents/MacOS/CodexQuotaMonitor" ]] || {
    print -u2 "Staged executable is not runnable: $stage_app"
    exit 1
}
[[ -f "$stage_app/Contents/Info.plist" && -d "$stage_app/Contents/Resources" ]] || {
    print -u2 "Staged app bundle is incomplete: $stage_app"
    exit 1
}
/usr/bin/plutil -lint "$stage_app/Contents/Info.plist" >/dev/null

# ServiceManagement identifies the main app from its signed bundle. An
# unsigned SwiftPM executable may expose the executable name as its code-sign
# identifier and leaves Info.plist/resources unbound, which makes mainApp
# appear as notFound. Ad-hoc signing is sufficient for local packaging and
# deliberately does not claim distribution signing or notarization.
/usr/bin/codesign --force --deep --sign - --timestamp=none "$stage_app"
/usr/bin/codesign --verify --deep --strict "$stage_app"
bundle_identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$stage_app/Contents/Info.plist")"
signed_identifier="$(/usr/bin/codesign -dv --verbose=4 "$stage_app" 2>&1 | /usr/bin/awk -F= '$1 == "Identifier" { print $2; exit }')"
[[ -n "$bundle_identifier" && "$signed_identifier" == "$bundle_identifier" ]] || {
    print -u2 "Signed identifier does not match CFBundleIdentifier: $signed_identifier != $bundle_identifier"
    exit 1
}

if [[ -e "$target_app" ]]; then
    backup_app="$target_app.backup.$$.$RANDOM"
    [[ ! -e "$backup_app" ]] || {
        print -u2 "Refusing to overwrite an existing backup path: $backup_app"
        exit 1
    }
    mv -- "$target_app" "$backup_app"
    backup_owned=1
fi

# The sibling backup makes this two-rename replacement recoverable; it is not
# a single filesystem operation and is deliberately validated before commit.
if ! mv -- "$stage_app" "$target_app"; then
    restore_backup || true
    print -u2 "Unable to install staged app bundle: $target_app"
    exit 1
fi

stage_owned=0
if [[ -d "$stage_dir" ]]; then
    rmdir "$stage_dir" 2>/dev/null || true
fi
if (( backup_owned )); then
    rm -rf -- "$backup_app"
    backup_owned=0
fi
print "Packaged ad-hoc signed app: $target_app"
