#!/bin/bash
# run-codegen-sbs-tests.sh — golden eval for codegen-sidebyside.sh.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CODEGEN="$PLUGIN_DIR/scripts/codegen-sidebyside.sh"
VALIDATE="$PLUGIN_DIR/scripts/validate-integration.sh"
DETECT="$PLUGIN_DIR/scripts/detect-mode.sh"

pass=0
fail=0

# Make a Unity project that already "has" MaxSdk so mode is side-by-side.
make_project() {
    local dir; dir="$(mktemp -d -t metica-sbs-XXXXXX)"
    mkdir -p "$dir/Assets/MaxSdk/AppLovin/Editor" "$dir/Assets/Scripts" "$dir/ProjectSettings"
    printf 'm_EditorVersion: 2022.3.62f2\n' > "$dir/ProjectSettings/ProjectVersion.txt"
    printf '<?xml version="1.0"?><dependencies/>\n' > "$dir/Assets/MaxSdk/AppLovin/Editor/Dependencies.xml"
    # A stub Max-using game script so the symbol signal trips.
    cat > "$dir/Assets/Scripts/GameAd.cs" <<'EOF'
public class GameAd { void Init() { MaxSdk.Initialize(); } }
EOF
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

mode_of() {
    printf '%s\n' "$1" | awk '
        /"mode":[[:space:]]*"/ {
            n=index($0, "\"mode\":")
            s=substr($0, n+7); sub(/^[^"]*"/, "", s); sub(/".*$/, "", s)
            print s; exit
        }'
}

# Get level for a rule.
level_of_rule() {
    printf '%s\n' "$1" | awk -v want="$2" '
        /"rule":[[:space:]]*"/ {
            n = index($0, "\"rule\":")
            s = substr($0, n + 7); sub(/^[^"]*"/, "", s); sub(/".*$/, "", s)
            if (s == want) {
                m = index($0, "\"level\":")
                if (m > 0) {
                    t = substr($0, m + 8); sub(/^[^"]*"/, "", t); sub(/".*$/, "", t)
                    print t; exit
                }
            }
        }'
}

assert_fail_cmd() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf "  FAIL  %s: expected non-zero exit\n" "$name"; fail=$((fail+1))
    else
        printf "  ok    %s\n" "$name"; pass=$((pass+1))
    fi
}

echo "== codegen-sidebyside golden eval =="

# 1. All four templates land
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --api-key=K --app-id=A --max-sdk-key=M >/dev/null 2>&1
err=0
for f in IAdService.cs MaxAdService.cs MeticaAdService.cs AdServiceRouter.cs; do
    [ -f "$proj/Assets/Scripts/Metica/$f" ] || { err=1; printf "  MISSING: %s\n" "$f"; }
done
if [ "$err" = "0" ]; then
    printf "  ok    all 4 adapter files generated\n"; pass=$((pass+1))
else
    fail=$((fail+1))
fi
rm -rf "$proj"

# 2. Keys substituted into AdServiceRouter
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --api-key=APIKEY9 --app-id=com.x --max-sdk-key=MAXKEY7 >/dev/null 2>&1
f="$proj/Assets/Scripts/Metica/AdServiceRouter.cs"
if grep -q '= "APIKEY9";'  "$f" && grep -q '= "com.x";'  "$f" && grep -q '= "MAXKEY7";' "$f"; then
    printf "  ok    keys substituted into AdServiceRouter\n"; pass=$((pass+1))
else
    printf "  FAIL  key substitution missing\n"; fail=$((fail+1))
    grep '__' "$f" | sed 's/^/    /'
fi
rm -rf "$proj"

# 3. End-to-end: validator PASS, mode side-by-side, privacy=ADVISORY, router=PASS
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --api-key=K --app-id=A --max-sdk-key=M >/dev/null 2>&1
out=$(bash "$VALIDATE" --project="$proj" 2>&1) || true
got_status=$(status_of "$out")
got_mode=$(mode_of "$out")
got_priv=$(level_of_rule "$out" "privacy_before_init")
got_router=$(level_of_rule "$out" "ad_service_router_present")
got_init=$(level_of_rule "$out" "init_count")
if [ "$got_status" = "PASS" ] && [ "$got_mode" = "side-by-side" ] \
   && [ "$got_priv" = "ADVISORY" ] && [ "$got_router" = "PASS" ] \
   && [ "$got_init" = "PASS" ]; then
    printf "  ok    validator: PASS / mode=side-by-side / privacy=ADVISORY / router=PASS\n"; pass=$((pass+1))
else
    printf "  FAIL  validator: status=%s mode=%s priv=%s router=%s init=%s\n" \
        "$got_status" "$got_mode" "$got_priv" "$got_router" "$got_init"
    printf '%s\n' "$out" | sed 's/^/    /'
    fail=$((fail+1))
fi
rm -rf "$proj"

# 4. Refuse to clobber without --force
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --api-key=K --app-id=A --max-sdk-key=M >/dev/null 2>&1
assert_fail_cmd "refuse overwrite without --force" \
    bash "$CODEGEN" --project="$proj" --api-key=K --app-id=A --max-sdk-key=M
# --force overwrites
if bash "$CODEGEN" --project="$proj" --api-key=K --app-id=A --max-sdk-key=M --force >/dev/null 2>&1; then
    printf "  ok    --force overwrites existing files\n"; pass=$((pass+1))
else
    printf "  FAIL  --force should succeed\n"; fail=$((fail+1))
fi
rm -rf "$proj"

# 5. Missing required args
proj=$(make_project)
assert_fail_cmd "missing --api-key rejected" \
    bash "$CODEGEN" --project="$proj" --app-id=A --max-sdk-key=M
assert_fail_cmd "missing --app-id rejected" \
    bash "$CODEGEN" --project="$proj" --api-key=K --max-sdk-key=M
assert_fail_cmd "missing --max-sdk-key rejected" \
    bash "$CODEGEN" --project="$proj" --api-key=K --app-id=A
rm -rf "$proj"

# 6. Control chars in keys rejected
proj=$(make_project)
nl_key="$(printf 'a\nb')"
assert_fail_cmd "newline in api-key rejected" \
    bash "$CODEGEN" --project="$proj" --api-key="$nl_key" --app-id=A --max-sdk-key=M
rm -rf "$proj"

# 7. Validator: rewarded_reward_callback PASS (templates subscribe OnAdRewarded)
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --api-key=K --app-id=A --max-sdk-key=M >/dev/null 2>&1
out=$(bash "$VALIDATE" --project="$proj" 2>&1) || true
if [ "$(level_of_rule "$out" "rewarded_reward_callback")" = "PASS" ]; then
    printf "  ok    rewarded_reward_callback PASS in generated code\n"; pass=$((pass+1))
else
    printf "  FAIL  rewarded_reward_callback expected PASS\n"; fail=$((fail+1))
fi
rm -rf "$proj"

# 7b. Sed metacharacters in keys are preserved (not interpreted by sed)
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --api-key='a&b/c' --app-id='d&e/f' --max-sdk-key='g&h/i' >/dev/null 2>&1
f="$proj/Assets/Scripts/Metica/AdServiceRouter.cs"
if grep -qF '= "a&b/c";' "$f" && grep -qF '= "d&e/f";' "$f" && grep -qF '= "g&h/i";' "$f"; then
    printf "  ok    sed metacharacters in keys preserved verbatim\n"; pass=$((pass+1))
else
    printf "  FAIL  sed metacharacters mangled\n"
    grep -E '__|= "' "$f" | sed 's/^/    /'
    fail=$((fail+1))
fi
rm -rf "$proj"

# 7c. Backslash in key produces exactly one backslash at runtime (C# decodes \\ → \)
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --api-key='x\y' --app-id=A --max-sdk-key=M >/dev/null 2>&1
f="$proj/Assets/Scripts/Metica/AdServiceRouter.cs"
# In C# source, runtime "x\y" requires literal "x\\y"; two literal backslashes only.
if grep -qF '= "x\\y";' "$f" && ! grep -qF '= "x\\\\y";' "$f"; then
    printf "  ok    single backslash key produces one C# escape (not double-escape)\n"; pass=$((pass+1))
else
    printf "  FAIL  backslash escaping wrong:\n"
    grep '"x' "$f" | sed 's/^/    /'
    fail=$((fail+1))
fi
rm -rf "$proj"

# 7d. No residual __PLACEHOLDER__ tokens leak through
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --api-key=K --app-id=A --max-sdk-key=M >/dev/null 2>&1
if grep -REn '__METICA|__MAX_SDK' "$proj/Assets/Scripts/Metica/" >/dev/null 2>&1; then
    printf "  FAIL  residual placeholders found in generated code\n"
    grep -REn '__METICA|__MAX_SDK' "$proj/Assets/Scripts/Metica/" | sed 's/^/    /'
    fail=$((fail+1))
else
    printf "  ok    no residual __PLACEHOLDER__ tokens in generated code\n"; pass=$((pass+1))
fi
rm -rf "$proj"

# 7e. Templates wrap symbols in namespace Metica.AbTest (collision avoidance)
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --api-key=K --app-id=A --max-sdk-key=M >/dev/null 2>&1
err=0
for f in IAdService.cs MaxAdService.cs MeticaAdService.cs AdServiceRouter.cs; do
    grep -q "^namespace Metica.AbTest$" "$proj/Assets/Scripts/Metica/$f" || { err=1; printf "  MISSING namespace in %s\n" "$f"; }
done
if [ "$err" = "0" ]; then
    printf "  ok    all templates wrap in namespace Metica.AbTest\n"; pass=$((pass+1))
else
    fail=$((fail+1))
fi
rm -rf "$proj"

# 7f. Misordered bootstrap is caught (validator FAIL on privacy_before_init)
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --api-key=K --app-id=A --max-sdk-key=M >/dev/null 2>&1
# Write a bootstrap with privacy AFTER Initialize → should FAIL.
cat > "$proj/Assets/Scripts/BadBootstrap.cs" <<'EOF'
using UnityEngine;
public class BadBootstrap : MonoBehaviour {
    void Start() {
        var ads = AdServiceRouter.Instance.AdService;
        ads.Initialize(() => {});
        ads.SetHasUserConsent(true);
        ads.SetDoNotSell(false);
    }
}
EOF
out=$(bash "$VALIDATE" --project="$proj" 2>&1) || true
if [ "$(level_of_rule "$out" "privacy_before_init")" = "FAIL" ]; then
    printf "  ok    misordered bootstrap caught: privacy_before_init FAIL\n"; pass=$((pass+1))
else
    printf "  FAIL  misordered bootstrap should be FAIL, got %s\n" "$(level_of_rule "$out" "privacy_before_init")"
    fail=$((fail+1))
fi
rm -rf "$proj"

# 7g. Correctly-ordered bootstrap → privacy_before_init PASS
proj=$(make_project)
bash "$CODEGEN" --project="$proj" --api-key=K --app-id=A --max-sdk-key=M >/dev/null 2>&1
cat > "$proj/Assets/Scripts/GoodBootstrap.cs" <<'EOF'
using UnityEngine;
public class GoodBootstrap : MonoBehaviour {
    void Start() {
        var ads = AdServiceRouter.Instance.AdService;
        ads.SetHasUserConsent(true);
        ads.SetDoNotSell(false);
        ads.Initialize(() => {});
    }
}
EOF
out=$(bash "$VALIDATE" --project="$proj" 2>&1) || true
if [ "$(level_of_rule "$out" "privacy_before_init")" = "PASS" ]; then
    printf "  ok    correctly-ordered bootstrap: privacy_before_init PASS\n"; pass=$((pass+1))
else
    printf "  FAIL  correctly-ordered bootstrap should be PASS, got %s\n" "$(level_of_rule "$out" "privacy_before_init")"
    fail=$((fail+1))
fi
rm -rf "$proj"

# 8. No file under Assets/MaxSdk/ was modified by the codegen
proj=$(make_project)
before=$(find "$proj/Assets/MaxSdk" -type f -exec shasum -a 256 {} \; | sort)
bash "$CODEGEN" --project="$proj" --api-key=K --app-id=A --max-sdk-key=M >/dev/null 2>&1
after=$(find "$proj/Assets/MaxSdk" -type f -exec shasum -a 256 {} \; | sort)
if [ "$before" = "$after" ]; then
    printf "  ok    Assets/MaxSdk/ untouched by codegen\n"; pass=$((pass+1))
else
    printf "  FAIL  Assets/MaxSdk/ was modified\n"; fail=$((fail+1))
    diff <(printf '%s' "$before") <(printf '%s' "$after") | sed 's/^/    /'
fi
rm -rf "$proj"

echo "----"
printf "passed: %d   failed: %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
