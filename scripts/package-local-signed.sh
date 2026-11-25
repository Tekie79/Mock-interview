#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C
cd "$(dirname "$0")/.."

fail() { printf '%s\n' "$*" >&2; exit 1; }

if [[ "${1:-}" == --help ]]; then
    printf 'Usage: %s [new-output-directory] [optional-dotted-build-number]\n' "$0"
    exit 0
fi
[[ $# -le 2 ]] || fail "Pass a new output directory and, optionally, a build number."
[[ "$(uname -s)" == Darwin ]] || fail "The local signing workflow requires macOS."
artifact_dir="${1:-$PWD/.build/macos-local-signed}"
case "$artifact_dir" in /*) ;; *) artifact_dir="$PWD/$artifact_dir" ;; esac
[[ ! -e "$artifact_dir" && ! -L "$artifact_dir" ]] || fail "Choose a new output directory. Existing artifacts are retained."
build_number="${2:-}"
[[ -z "$build_number" || "$build_number" =~ ^[0-9]+([.][0-9]+){0,2}$ ]] || fail "Use a dotted numeric build number."

bundle_id=com.mockinterview.desktop
identity_name='Mock Interview Local Signing'
login_keychain="$(security login-keychain | awk -F '"' 'NF >= 3 { print $2; exit }')"
[[ -f "$login_keychain" ]] || fail "The login Keychain is unavailable."
signers="$(security find-identity -p codesigning "$login_keychain" | awk -v name="$identity_name" '
    /Matching identities/ { matching = 1 }
    /Valid identities only/ { matching = 0 }
    matching && index($0, "\"" name "\"") && length($2) == 40 && $2 !~ /[^[:xdigit:]]/ { print toupper($2) }
')"
[[ "$signers" =~ ^[A-F0-9]{40}$ ]] || fail "Create exactly one '$identity_name' Code Signing identity in your login Keychain, with its private key."
identity_sha1="$signers"
identity_sha256="$(security find-certificate -a -c "$identity_name" -Z "$login_keychain" | awk -v sha1="$identity_sha1" '
    $1 == "SHA-256" { sha256 = toupper($NF) }
    $1 == "SHA-1" && toupper($NF) == sha1 { print sha256; exit }
')"
[[ "$identity_sha256" =~ ^[A-F0-9]{64}$ ]] || fail "Could not read the public fingerprint for the selected signing identity."

pin_dir="$HOME/Library/Application Support/MockInterview Local Signing"
pin="$pin_dir/certificate.sha256"
if [[ -e "$pin" ]]; then
    [[ "$(cat "$pin")" == "$identity_sha256" ]] || fail "The login Keychain identity differs from the certificate pinned for local releases."
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/mockinterview-signing.XXXXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
source_revision="$(git rev-parse HEAD)"
tracked_changes="$(if git diff --quiet HEAD; then printf none; else printf present; fi)"
entitlements="$PWD/AppShell/LocalSigning.entitlements"
requirement="identifier \"$bundle_id\" and certificate leaf = H\"$identity_sha1\""
package_build="$scratch/build"
# Isolate the Release build from developer build-setting overrides and fixture configurations.
env -u XCODE_XCCONFIG_FILE ./scripts/package-macos.sh "$package_build"
app="$package_build/Build/Products/Release/MockInterview.app"
plist="$app/Contents/Info.plist"
binary="$app/Contents/MacOS/MockInterview"
[[ "$(plutil -extract CFBundleIdentifier raw "$plist")" == "$bundle_id" ]] || fail "Unexpected bundle identifier."
[[ "$(plutil -extract CFBundleExecutable raw "$plist")" == MockInterview ]] || fail "Unexpected application executable."
if [[ -n "$build_number" ]]; then plutil -replace CFBundleVersion -string "$build_number" "$plist"; fi
LC_ALL=C strings -a "$binary" > "$scratch/executable-strings"
if grep -F -e 'Load 200 Chat Entries' -e 'Platform reliability rehearsal' -e 'Jordan Ellis' "$scratch/executable-strings" >/dev/null; then
    fail "Synthetic UI verification fixtures were compiled into the Release executable."
fi

codesign --force --sign "$identity_sha1" --keychain "$login_keychain" --options runtime --timestamp=none \
    --entitlements "$entitlements" --requirements "=designated => $requirement" "$app"

verify_app() {
    local bundle="$1" arch details minos found_sha256
    codesign --verify --deep --strict --all-architectures --test-requirement "=$requirement" "$bundle"
    xcrun lipo "$bundle/Contents/MacOS/MockInterview" -verify_arch arm64 x86_64
    for arch in arm64 x86_64; do
        details="$(codesign --display --verbose=4 --architecture "$arch" "$bundle" 2>&1)"
        grep -E '^CodeDirectory .*\(runtime\)' <<< "$details" >/dev/null || fail "Missing Hardened Runtime on $arch."
        grep -Fx "Authority=$identity_name" <<< "$details" >/dev/null || fail "Unexpected signing authority on $arch."
        codesign --display --architecture "$arch" --entitlements - --xml "$bundle" > "$scratch/entitlements" 2>/dev/null
        plutil -convert xml1 -o "$scratch/expected-entitlements" "$entitlements"
        plutil -convert xml1 "$scratch/entitlements"
        cmp -s "$scratch/expected-entitlements" "$scratch/entitlements" || fail "Unexpected signing entitlements on $arch."
        minos="$(xcrun vtool -arch "$arch" -show-build "$bundle/Contents/MacOS/MockInterview" | awk '$1 == "minos" { print $2 }')"
        [[ "$minos" == 14.2 ]] || fail "Unexpected macOS deployment target on $arch."
        codesign --display --architecture "$arch" --extract-certificates "$scratch/leaf-" "$bundle" 2>/dev/null
        found_sha256="$(/usr/bin/shasum -a 256 "$scratch/leaf-0" | awk '{ print toupper($1) }')"
        [[ "$found_sha256" == "$identity_sha256" ]] || fail "Unexpected embedded signer on $arch."
    done
    cmp -s "$plist" "$bundle/Contents/Info.plist" || fail "The archive changed the app metadata."
}

verify_app "$app"
/usr/bin/openssl x509 -inform DER -in "$scratch/leaf-0" -out "$scratch/leaf.pem"
subject="$(/usr/bin/openssl x509 -in "$scratch/leaf.pem" -noout -subject -nameopt RFC2253)"
issuer="$(/usr/bin/openssl x509 -in "$scratch/leaf.pem" -noout -issuer -nameopt RFC2253)"
[[ "${subject#subject=}" == "${issuer#issuer=}" ]] || fail "The selected identity must be self-signed."
# An explicit anchor applies only to this offline certificate check.
security verify-cert -q -L -p codeSign -c "$scratch/leaf-0" -r "$scratch/leaf-0"
version="$(plutil -extract CFBundleShortVersionString raw "$plist")"
zip="MockInterview-$version-local-signed.zip"
ditto -c -k --keepParent "$app" "$scratch/$zip"
ditto -x -k "$scratch/$zip" "$scratch/extracted"
verify_app "$scratch/extracted/MockInterview.app"
(
    cd "$scratch"
    /usr/bin/shasum -a 256 "$zip" > "$zip.sha256"
)
/usr/bin/codesign --display -r- "$app" > "$scratch/requirement" 2>/dev/null
[[ -s "$scratch/requirement" ]] || fail "Could not record the embedded designated requirement."
{
    printf 'Git revision: %s\n' "$source_revision"
    printf 'Tracked source changes: %s\n' "$tracked_changes"
    printf 'Bundle: %s %s (%s)\n' "$bundle_id" "$version" "$(plutil -extract CFBundleVersion raw "$plist")"
    printf 'Certificate: %s\nSHA-256: %s\nSHA-1: %s\n' "$identity_name" "$identity_sha256" "$identity_sha1"
    cat "$scratch/requirement"
    printf 'Verified: strict application signatures and extracted ZIP; arm64 and x86_64; macOS 14.2; Hardened Runtime; Audio Input.\n'
    cat "$scratch/$zip.sha256"
} > "$scratch/signing-verification.txt"

mkdir -p "$pin_dir"
if [[ ! -e "$pin" ]]; then
    (set -o noclobber; printf '%s\n' "$identity_sha256" > "$pin") || fail "Could not write the local certificate pin."
fi
[[ "$(cat "$pin")" == "$identity_sha256" ]] || fail "The certificate pin changed during packaging."
mkdir -p "$(dirname "$artifact_dir")"
mkdir "$artifact_dir" || fail "Choose a new output directory."
mv "$app" "$scratch/$zip" "$scratch/$zip.sha256" "$scratch/signing-verification.txt" "$artifact_dir/"
printf '%s\n' "$artifact_dir/$zip"
