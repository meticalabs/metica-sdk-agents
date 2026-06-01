#!/bin/bash
# run-codegen-validator-tests.sh — validate the canonical agent-generated output.
#
# Codegen lives in the integrator agent's prose (there are no codegen-*.sh
# scripts). This suite cannot drive the agent from bash, so it instead renders
# the single MeticaAdService.cs.tmpl the same way the integrator does — sed for
# the scalar placeholders, awk to drop the `// @fmt-begin:<fmt>`…`// @fmt-end:<fmt>`
# regions for formats a project doesn't use — and runs the unchanged validator
# over the result. If a documented template is invalid, this test catches it.
#
# Coverage:
#   1. no-Max / interstitial / no namespace            → PASS
#   2. no-Max / interstitial + rewarded / namespace    → PASS  (ns wrap + reward callback)
#   3. no-Max / privacy AFTER init                     → FAIL  (negative golden)
#   3b. MaxSDK present / MAX mediation                  → PASS
#   4. interstitial + mrec / correct Mrec casing        → PASS
#   5. single-format render drops other formats' regions cleanly

set -u

# Synthetic rendered projects — never launch Unity (see run-validator-tests.sh).
export METICA_SKIP_COMPILE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE="$PLUGIN_DIR/scripts/validate-integration.sh"
STANDALONE_DIR="$PLUGIN_DIR/scripts/templates/standalone"
TMPL="$STANDALONE_DIR/MeticaAdService.cs.tmpl"

pass=0
fail=0

status_of() {
    printf '%s\n' "$1" | awk '
        /"status":[[:space:]]*"/ {
            n=index($0, "\"status\":")
            s=substr($0, n+9); sub(/^[^"]*"/, "", s); sub(/".*$/, "", s)
            print s; exit
        }'
}

make_nomax_project() {
    local dir; dir="$(mktemp -d -t metica-nomax-XXXXXX)"
    mkdir -p "$dir/Assets/Scripts" "$dir/ProjectSettings"
    printf 'm_EditorVersion: 2022.3.62f2\n' > "$dir/ProjectSettings/ProjectVersion.txt"
    echo "$dir"
}

make_max_project() {
    local dir; dir="$(mktemp -d -t metica-max-XXXXXX)"
    mkdir -p "$dir/Assets/MaxSdk/AppLovin/Editor" "$dir/Assets/Scripts" "$dir/ProjectSettings"
    printf 'm_EditorVersion: 2022.3.62f2\n' > "$dir/ProjectSettings/ProjectVersion.txt"
    printf '<?xml version="1.0"?><dependencies/>\n' > "$dir/Assets/MaxSdk/AppLovin/Editor/Dependencies.xml"
    cat > "$dir/Assets/Scripts/GameAd.cs" <<'EOF'
public class GameAd { void Init() { MaxSdk.Initialize(); } }
EOF
    echo "$dir"
}

# Render MeticaAdService.cs from the single template, exactly as the integrator does:
# sed fills the scalar placeholders; awk drops the `// @fmt-begin:<fmt>`…`@fmt-end`
# regions for formats not in $formats (and the marker lines themselves).
# Args: project ns formats(csv) api app has_max(0|1) [userid]
emit_standalone() {
    local project="$1" ns="$2" formats="$3" api="$4" app="$5" has_max="$6"
    local userid="${7:-\"u-abc-123\"}"
    local dir="$project/Assets/Scripts/Metica"
    mkdir -p "$dir"

    local mediation='null'
    # Nested enum MUST be qualified: MeticaMediationInfo.MeticaMediationType.MAX
    # (bare MeticaMediationType.MAX does not compile — see issue #8).
    [ "$has_max" = "1" ] && mediation='new MeticaMediationInfo(MeticaMediationInfo.MeticaMediationType.MAX, "MAXKEY99")'

    sed \
        -e "s|namespace Metica\\.AbTest|namespace $ns|g" \
        -e "s|__METICA_API_KEY__|$api|g" \
        -e "s|__METICA_APP_ID__|$app|g" \
        -e "s|__USER_ID__|$userid|g" \
        -e "s|__MEDIATION__|$mediation|g" \
        "$TMPL" \
    | awk -v fmts=",$formats," '
        /\/\/ @fmt-begin:[a-z]+/ {
            tag = $0; sub(/.*@fmt-begin:/, "", tag); sub(/[^a-z].*/, "", tag)
            drop = (index(fmts, "," tag ",") == 0)   # 1 = format unused → drop region
            next                                     # always drop the begin-marker line
        }
        /\/\/ @fmt-end:[a-z]+/ { drop = 0; next }     # always drop the end-marker line
        drop { next }
        { print }
    ' > "$dir/MeticaAdService.cs"
}

run_case() {
    local name="$1" expected="$2" project="$3"
    local json status
    json="$(bash "$VALIDATE" --project="$project" 2>&1 || true)"
    status="$(status_of "$json")"
    if [ "$status" = "$expected" ]; then
        echo "  PASS  $name"
        pass=$((pass+1))
    else
        echo "  FAIL  $name  (expected $expected, got $status)"
        echo "$json" | head -40 | sed 's/^/        /'
        fail=$((fail+1))
    fi
    rm -rf "$project"
}

echo "=== run-codegen-validator-tests.sh ==="

# 1. no-Max / interstitial
p="$(make_nomax_project)"
emit_standalone "$p" "Metica.AbTest" "interstitial" "ABC123" "XYZ987" 0
run_case "no-Max interstitial" "PASS" "$p"

# 2. no-Max / interstitial + rewarded / namespace MyGame.Services.Metica
p="$(make_nomax_project)"
emit_standalone "$p" "MyGame.Services.Metica" "interstitial,rewarded" "ABC123" "XYZ987" 0
svc="$p/Assets/Scripts/Metica/MeticaAdService.cs"
if grep -q "namespace MyGame.Services.Metica" "$svc" \
    && grep -q "MeticaAdsCallbacks.Rewarded.OnAdRewarded" "$svc"; then
    run_case "rewarded ns=MyGame.Services.Metica" "PASS" "$p"
else
    echo "  FAIL  rewarded ns=MyGame.Services.Metica  (namespace wrap or reward callback missing)"
    fail=$((fail+1)); rm -rf "$p"
fi

# 3. privacy AFTER init → validator FAIL (negative golden).
p="$(make_nomax_project)"
emit_standalone "$p" "Metica.AbTest" "interstitial" "ABC123" "XYZ987" 0
svc="$p/Assets/Scripts/Metica/MeticaAdService.cs"
awk '
    /MeticaSdk.Ads.SetHasUserConsent\(true\);/ { consent=$0; next }
    /MeticaSdk.Ads.SetDoNotSell\(false\);/      { dns=$0; next }
    /MeticaSdk.Initialize\(/ {
        print
        print "        " consent
        print "        " dns
        next
    }
    { print }
' "$svc" > "$svc.new"
mv "$svc.new" "$svc"
run_case "privacy-after-init (negative)" "FAIL" "$p"

# 3b. MaxSDK present (MAX mediation): the standalone adapter validates.
p="$(make_max_project)"
emit_standalone "$p" "Metica.AbTest" "interstitial" "ABC123" "XYZ987" 1
svc="$p/Assets/Scripts/Metica/MeticaAdService.cs"
# The nested enum MUST be qualified; the bare form does not compile (issue #8).
if grep -q "MeticaMediationInfo.MeticaMediationType.MAX" "$svc" \
    && ! grep -qE '(^|[^.])MeticaMediationType\.MAX' "$svc"; then
    run_case "max-present interstitial (qualified MAX mediation)" "PASS" "$p"
else
    echo "  FAIL  max-present interstitial  (qualified MAX mediation arg missing or bare enum present)"
    grep -n "MeticaMediationType" "$svc" | sed 's/^/        /'
    fail=$((fail+1)); rm -rf "$p"
fi

# 4. MRec template — generated file uses the right Metica casing (Mrec, not MRec).
p="$(make_nomax_project)"
emit_standalone "$p" "Metica.AbTest" "interstitial,mrec" "ABC123" "XYZ987" 0
svc="$p/Assets/Scripts/Metica/MeticaAdService.cs"
if grep -q "MeticaSdk.Ads.LoadMrec(" "$svc" \
    && grep -q "MeticaAdsCallbacks.Mrec.OnAdLoadSuccess" "$svc" \
    && ! grep -q "MeticaSdk.Ads.LoadMRec(" "$svc"; then
    run_case "mrec (correct Mrec casing)" "PASS" "$p"
else
    echo "  FAIL  mrec casing"
    grep -nE 'M[Rr]ec' "$svc" | sed 's/^/        /'
    fail=$((fail+1)); rm -rf "$p"
fi

# 5. Single-format render drops the other formats' regions cleanly (no leak).
p="$(make_nomax_project)"
emit_standalone "$p" "Metica.AbTest" "interstitial" "ABC123" "XYZ987" 0
svc="$p/Assets/Scripts/Metica/MeticaAdService.cs"
leak=0
for absent in Rewarded Banner Mrec; do
    grep -q "MeticaAdsCallbacks.$absent\." "$svc" && { echo "  leak: $absent callbacks present in interstitial-only render"; leak=1; }
done
grep -qE "@fmt-(begin|end):[a-z]" "$svc" && { echo "  leak: @fmt region marker survived into output"; leak=1; }
if [ "$leak" = "0" ]; then
    echo "  PASS  single-format render drops other formats' regions"
    pass=$((pass+1))
else
    fail=$((fail+1))
fi
rm -rf "$p"

# 6. Template shape — the consolidated orchestrator must carry the canonical shape.
shape_ok=1
sh_fail() { echo "  shape FAIL: $1"; shape_ok=0; }

grep -qE 'class[[:space:]]+MeticaAdService[[:space:]]*:[[:space:]]*MonoBehaviour' "$TMPL" || sh_fail "MeticaAdService must be a MonoBehaviour"
grep -q 'MeticaSdk.Ads.SetHasUserConsent' "$TMPL" || sh_fail "missing SetHasUserConsent"
grep -q 'MeticaSdk.Ads.SetDoNotSell'      "$TMPL" || sh_fail "missing SetDoNotSell"
grep -q 'MeticaSdk.SetLogEnabled('        "$TMPL" || sh_fail "missing SetLogEnabled"
grep -q 'MeticaSdk.Initialize('           "$TMPL" || sh_fail "missing MeticaSdk.Initialize"
grep -q 'new MeticaInitConfig('           "$TMPL" || sh_fail "missing MeticaInitConfig"
# Named init callback (not an inline lambda) + SmartFloors logging.
grep -qE 'private[[:space:]]+void[[:space:]]+OnInitialized\(MeticaInitResponse' "$TMPL" || sh_fail "missing named OnInitialized(MeticaInitResponse) callback"
grep -q 'MeticaSdk.Initialize(config, __MEDIATION__, OnInitialized)' "$TMPL" || sh_fail "Initialize must pass the named OnInitialized callback (not a lambda)"
grep -q 'response.SmartFloors.UserGroup'  "$TMPL" || sh_fail "OnInitialized must log SmartFloors.UserGroup"
grep -q 'response.UserId'                 "$TMPL" || sh_fail "OnInitialized must log UserId"
# Reference-form correctness (issue #8): the SmartFloors property is PascalCase
# (IsForcedHoldout); the camelCase docs form does not compile (CS1061).
grep -q 'response.SmartFloors.IsForcedHoldout' "$TMPL" || sh_fail "OnInitialized must use PascalCase SmartFloors.IsForcedHoldout"
grep -q 'SmartFloors.isForcedHoldout'          "$TMPL" && sh_fail "camelCase SmartFloors.isForcedHoldout does not compile (CS1061)"
# Privacy precedes Initialize in the template.
cons_line="$(grep -n 'SetHasUserConsent' "$TMPL" | head -1 | cut -d: -f1)"
init_line="$(grep -n 'MeticaSdk.Initialize(' "$TMPL" | head -1 | cut -d: -f1)"
[ -n "$cons_line" ] && [ -n "$init_line" ] && [ "$cons_line" -lt "$init_line" ] || sh_fail "privacy must precede Initialize"
# Each format has a begin/end region.
for f in banner interstitial rewarded mrec; do
    grep -q "@fmt-begin:$f" "$TMPL" || sh_fail "missing @fmt-begin:$f region"
    grep -q "@fmt-end:$f"   "$TMPL" || sh_fail "missing @fmt-end:$f region"
done
# Interstitial + Rewarded carry the docs exponential-backoff retry; Banner/MRec do not.
for f in Interstitial Rewarded; do
    grep -qE "System\.Math\.Pow\(2,[[:space:]]*System\.Math\.Min\(6" "$TMPL" || sh_fail "$f missing Math.Pow(2,Math.Min(6,…)) backoff"
    grep -q "Invoke(nameof(Load$f)" "$TMPL" || sh_fail "$f missing Invoke(nameof(Load$f), …) retry"
done
grep -q "Invoke(nameof(LoadBanner)" "$TMPL" && sh_fail "Banner must NOT carry Invoke-based retry"
grep -q "Invoke(nameof(LoadMrec)"   "$TMPL" && sh_fail "MRec must NOT carry Invoke-based retry"
# Banner + MRec carry focus pause/resume + placement + showing-state.
for f in Banner Mrec; do
    grep -q "${f}OnFocus(bool" "$TMPL"               || sh_fail "$f missing OnFocus pause/resume helper"
    grep -qE "Start${f}AutoRefresh\(" "$TMPL"          || sh_fail "$f missing Start${f}AutoRefresh"
    grep -qE "Stop${f}AutoRefresh\(" "$TMPL"           || sh_fail "$f missing Stop${f}AutoRefresh"
    grep -qE "Set${f}Placement\(" "$TMPL"              || sh_fail "$f missing Set${f}Placement"
done
grep -qE 'OnApplicationFocus\(bool' "$TMPL" || sh_fail "missing OnApplicationFocus(bool)"
# Game-facing API exposed for every format.
for sig in 'LoadInterstitial()' 'ShowInterstitial(string placement' 'LoadRewarded()' 'ShowRewarded(string placement' 'ShowBanner()' 'HideBanner()' 'ShowMrec()' 'HideMrec()'; do
    grep -q "public void $sig" "$TMPL" || sh_fail "missing public API: $sig"
done
# Reward callback + revenue diagnostics present.
grep -q 'MeticaAdsCallbacks.Rewarded.OnAdRewarded' "$TMPL" || sh_fail "missing rewarded OnAdRewarded subscription"
for field in 'ad\.adUnitId' 'ad\.revenue' 'ad\.networkName' 'ad\.placementTag'; do
    grep -qE "$field" "$TMPL" || sh_fail "revenue log missing ${field//\\/} field"
done

if [ "$shape_ok" = "1" ]; then
    echo "  PASS  orchestrator template shape (MonoBehaviour + named OnInitialized + per-format regions + retry/focus)"
    pass=$((pass+1))
else
    fail=$((fail+1))
fi

echo
echo "Pass: $pass   Fail: $fail"
[ "$fail" = "0" ] || exit 1
