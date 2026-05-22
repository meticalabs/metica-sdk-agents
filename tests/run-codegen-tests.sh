#!/bin/bash
# run-codegen-tests.sh — golden eval for codegen-fresh.sh.
# Each fixture: generate, then run the validator. Validator must return PASS.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CODEGEN="$PLUGIN_DIR/scripts/codegen-fresh.sh"
VALIDATE="$PLUGIN_DIR/scripts/validate-integration.sh"

pass=0
fail=0

make_project() {
    local dir; dir="$(mktemp -d -t metica-codegen-XXXXXX)"
    mkdir -p "$dir/Assets" "$dir/ProjectSettings"
    printf 'm_EditorVersion: 2022.3.62f2\n' > "$dir/ProjectSettings/ProjectVersion.txt"
    echo "$dir"
}

status_of() {
    printf '%s\n' "$1" | awk '
        /"status":[[:space:]]*"/ {
            n=index($0, "\"status\":")
            s=substr($0, n+9); sub(/^[^"]*"/, "", s); sub(/".*$/, "", s)
            print s; exit
        }'
}

# Generate + validate, assert PASS.
assert_generate_valid() {
    local name="$1" formats="$2"
    local proj; proj=$(make_project)
    if ! bash "$CODEGEN" --project="$proj" --formats="$formats" >/dev/null 2>&1; then
        printf "  FAIL  %s: codegen failed\n" "$name"
        rm -rf "$proj"; fail=$((fail+1)); return
    fi
    out=$(bash "$VALIDATE" --project="$proj" 2>&1) || true
    if [ "$(status_of "$out")" = "PASS" ]; then
        printf "  ok    %s\n" "$name"; pass=$((pass+1))
    else
        printf "  FAIL  %s: validator did not PASS\n" "$name"
        printf '%s\n' "$out" | sed 's/^/    /'
        fail=$((fail+1))
    fi
    rm -rf "$proj"
}

assert_codegen_fail() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf "  FAIL  %s: expected non-zero exit\n" "$name"
        fail=$((fail+1))
    else
        printf "  ok    %s\n" "$name"; pass=$((pass+1))
    fi
}

echo "== codegen-fresh golden eval =="

assert_generate_valid "interstitial only"       "interstitial"
assert_generate_valid "banner only"             "banner"
assert_generate_valid "rewarded only"           "rewarded"
assert_generate_valid "banner+interstitial"     "banner,interstitial"
assert_generate_valid "interstitial+rewarded"   "interstitial,rewarded"
assert_generate_valid "all three"               "banner,interstitial,rewarded"

# Refuse to overwrite without --force
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --formats=interstitial >/dev/null 2>&1
assert_codegen_fail "refuse overwrite without --force" \
    bash "$CODEGEN" --project="$proj" --formats=interstitial
# --force overwrites
if bash "$CODEGEN" --project="$proj" --formats=interstitial --force >/dev/null 2>&1; then
    printf "  ok    --force overwrites existing file\n"; pass=$((pass+1))
else
    printf "  FAIL  --force should overwrite\n"; fail=$((fail+1))
fi
rm -rf "$proj"

# Invalid format
proj=$(make_project)
assert_codegen_fail "invalid format rejected" \
    bash "$CODEGEN" --project="$proj" --formats=video
rm -rf "$proj"

# Missing project / not Unity
assert_codegen_fail "missing project rejected" \
    bash "$CODEGEN" --project=/no/such/path --formats=interstitial
nonunity=$(mktemp -d)
mkdir -p "$nonunity/ProjectSettings"
assert_codegen_fail "non-Unity project rejected" \
    bash "$CODEGEN" --project="$nonunity" --formats=interstitial
rm -rf "$nonunity"

# API key + App ID positional embedding (tightened — full constructor signature)
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --formats=interstitial --api-key=ABC123 --app-id=XYZ987 >/dev/null 2>&1
if grep -q 'new MeticaInitConfig("ABC123", "XYZ987", null)' "$proj/Assets/Scripts/MeticaBootstrap.cs"; then
    printf "  ok    api-key + app-id embedded positionally\n"; pass=$((pass+1))
else
    printf "  FAIL  api-key / app-id not embedded positionally\n"; fail=$((fail+1))
fi
rm -rf "$proj"

# Generated file contains both namespace usings
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --formats=interstitial >/dev/null 2>&1
if grep -q '^using Metica;$' "$proj/Assets/Scripts/MeticaBootstrap.cs" \
   && grep -q '^using Metica.Ads;$' "$proj/Assets/Scripts/MeticaBootstrap.cs"; then
    printf "  ok    Metica + Metica.Ads usings emitted\n"; pass=$((pass+1))
else
    printf "  FAIL  required namespace usings missing\n"; fail=$((fail+1))
fi
rm -rf "$proj"

# Privacy-before-init ordering enforced
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --formats=interstitial >/dev/null 2>&1
priv_line=$(grep -n 'SetHasUserConsent' "$proj/Assets/Scripts/MeticaBootstrap.cs" | head -1 | awk -F: '{ print $1 }')
init_line=$(grep -n 'MeticaSdk.Initialize(' "$proj/Assets/Scripts/MeticaBootstrap.cs" | head -1 | awk -F: '{ print $1 }')
if [ -n "$priv_line" ] && [ -n "$init_line" ] && [ "$priv_line" -lt "$init_line" ]; then
    printf "  ok    privacy precedes Initialize (line %d < %d)\n" "$priv_line" "$init_line"; pass=$((pass+1))
else
    printf "  FAIL  privacy/init ordering: priv=%s init=%s\n" "$priv_line" "$init_line"; fail=$((fail+1))
fi
rm -rf "$proj"

# Injection attempts: api-key containing " and ; must be escaped, NOT executed
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --formats=interstitial \
    --api-key='abc"; System.IO.File.Delete("/etc/passwd"); //' --app-id=XYZ >/dev/null 2>&1
# After escaping, the generated file should contain the escaped literal sequence
# and no real C# code injection: a properly escaped \" inside the string literal.
if grep -F 'abc\"; System.IO.File.Delete(\"/etc/passwd\"); //' "$proj/Assets/Scripts/MeticaBootstrap.cs" >/dev/null \
   && ! grep -F 'System.IO.File.Delete("/etc/passwd")' "$proj/Assets/Scripts/MeticaBootstrap.cs" >/dev/null; then
    printf "  ok    api-key shell/C# injection escaped\n"; pass=$((pass+1))
else
    printf "  FAIL  injection not escaped:\n"
    grep 'MeticaInitConfig' "$proj/Assets/Scripts/MeticaBootstrap.cs" | sed 's/^/    /'
    fail=$((fail+1))
fi
rm -rf "$proj"

# Newline in api-key rejected. The $'..' must be wrapped in "" or the unquoted
# arg gets word-split on the newline before bash invokes the script.
nl_key="$(printf 'a\nb')"
assert_codegen_fail "newline in api-key rejected" \
    bash "$CODEGEN" --project="$(make_project)" --formats=interstitial --api-key="$nl_key"

# Empty --formats rejected
proj=$(make_project)
assert_codegen_fail "empty --formats rejected" \
    bash "$CODEGEN" --project="$proj" --formats=
rm -rf "$proj"

# Whitespace-padded format names tolerated
proj=$(make_project)
if bash "$CODEGEN" --project="$proj" --formats=' banner , interstitial ' >/dev/null 2>&1; then
    printf "  ok    whitespace-padded formats accepted\n"; pass=$((pass+1))
else
    printf "  FAIL  whitespace-padded formats should be accepted\n"; fail=$((fail+1))
fi
rm -rf "$proj"

# Negative golden: artificially flip privacy after init, validator must FAIL
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --formats=interstitial >/dev/null 2>&1
f="$proj/Assets/Scripts/MeticaBootstrap.cs"
# Move the privacy block to AFTER Initialize via a destructive sed.
# We'll just write a known-bad file by hand into the same path.
cat > "$f" <<'BAD'
using UnityEngine;
using Metica;
using Metica.Ads;

public class MeticaBootstrap : MonoBehaviour
{
    void Start()
    {
        MeticaAdsCallbacks.Interstitial.OnAdLoadSuccess += ad => Debug.Log("loaded");
        MeticaAdsCallbacks.Interstitial.OnAdLoadFailed += err => Debug.LogWarning("failed");
        var config = new MeticaInitConfig("K", "A", null);
        MeticaSdk.Initialize(config, null, response => {});
        MeticaSdk.Ads.SetHasUserConsent(true);
        MeticaSdk.Ads.SetDoNotSell(false);
        MeticaSdk.Ads.LoadInterstitial("i");
    }
    public void ShowInterstitial() { MeticaSdk.Ads.ShowInterstitial("i"); }
}
BAD
out=$(bash "$PLUGIN_DIR/scripts/validate-integration.sh" --project="$proj" 2>&1) || true
if [ "$(status_of "$out")" = "FAIL" ]; then
    printf "  ok    negative golden: privacy-after-init caught by validator\n"; pass=$((pass+1))
else
    printf "  FAIL  negative golden: validator did not FAIL on privacy-after-init\n"
    printf '%s\n' "$out" | sed 's/^/    /'
    fail=$((fail+1))
fi
rm -rf "$proj"

echo "----"
printf "passed: %d   failed: %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
