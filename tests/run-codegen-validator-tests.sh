#!/bin/bash
# run-codegen-validator-tests.sh — validate the canonical agent-generated outputs.
#
# Codegen lives in the integrator agent's prose (there are no codegen-*.sh
# scripts). This suite cannot drive the agent from bash, so it instead
# pre-populates synthetic projects with the *expected* agent output — a
# reference impl that renders the same templates the integrator does (Step 5) —
# and runs the unchanged validator over them. If a documented template is
# invalid, this test catches it.
#
# Coverage:
#   1. no-Max / interstitial / no namespace           → PASS
#   2. no-Max / rewarded / namespace MyGame.Services  → PASS  (validates wrap + reward callback)
#   3. no-Max / privacy AFTER init                    → FAIL  (negative golden)
#   3b. MaxSDK present / standalone adapter set        → PASS

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE="$PLUGIN_DIR/scripts/validate-integration.sh"
STANDALONE_DIR="$PLUGIN_DIR/scripts/templates/standalone"

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

# A plain Unity project (no MaxSDK present).
make_nomax_project() {
    local dir; dir="$(mktemp -d -t metica-nomax-XXXXXX)"
    mkdir -p "$dir/Assets/Scripts" "$dir/ProjectSettings"
    printf 'm_EditorVersion: 2022.3.62f2\n' > "$dir/ProjectSettings/ProjectVersion.txt"
    echo "$dir"
}

# A project with MaxSDK present (MaxSdk dir + a MaxSdk.* call site).
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

# Copy a standalone per-format template, substituting the namespace.
# Args: stem out_dir ns
emit_standalone_perfile() {
    local stem="$1" dir="$2" ns="$3"
    sed "s|namespace Metica\\.AbTest|namespace $ns|g" "$STANDALONE_DIR/$stem.cs.tmpl" > "$dir/$stem.cs"
}

# Reference impl of the agent's standalone codegen (integrator.md Step 5): the
# orchestrator MeticaAdService.cs + per-format files (copied from templates) +
# (only when MaxSDK is absent) a thin MeticaBootstrap MonoBehaviour.
# Args: project ns formats(csv) api app has_max(0|1) [userid]
emit_standalone() {
    local project="$1" ns="$2" formats="$3" api="$4" app="$5" has_max="$6"
    local userid="${7:-\"u-abc-123\"}"
    local dir="$project/Assets/Scripts/Metica"
    mkdir -p "$dir"

    local has_banner=0 has_inter=0 has_rew=0 has_mrec=0
    case ",$formats," in *,banner,*) has_banner=1 ;; esac
    case ",$formats," in *,interstitial,*) has_inter=1 ;; esac
    case ",$formats," in *,rewarded,*) has_rew=1 ;; esac
    case ",$formats," in *,mrec,*) has_mrec=1 ;; esac

    # Per-format objects (from templates).
    [ "$has_banner" = 1 ] && emit_standalone_perfile MeticaBannerAd       "$dir" "$ns"
    [ "$has_inter"  = 1 ] && emit_standalone_perfile MeticaInterstitialAd "$dir" "$ns"
    [ "$has_rew"    = 1 ] && emit_standalone_perfile MeticaRewardedAd     "$dir" "$ns"
    [ "$has_mrec"   = 1 ] && emit_standalone_perfile MeticaMRecAd         "$dir" "$ns"

    # Mediation: no Max = none; Max present = MAX (Metica mediates via AppLovin).
    local mediation='null'
    [ "$has_max" = "1" ] && mediation='new MeticaMediationInfo(MeticaMediationType.MAX, "MAXKEY99")'

    # Orchestrator: rendered from MeticaAdService.cs.tmpl (privacy precedes
    # Initialize in this same file; constructs the per-format objects in the init
    # callback; exposes Show* delegators). sed fills the scalar placeholders; awk
    # drops `// @fmt:<format>` lines for formats not in use and strips the marker
    # from the lines it keeps (mirrors the integrator's per-project conform step).
    sed \
        -e "s|namespace Metica\\.AbTest|namespace $ns|g" \
        -e "s|__METICA_API_KEY__|$api|g" \
        -e "s|__METICA_APP_ID__|$app|g" \
        -e "s|__USER_ID__|$userid|g" \
        -e "s|__MEDIATION__|$mediation|g" \
        "$STANDALONE_DIR/MeticaAdService.cs.tmpl" \
    | awk -v fmts=",$formats," '
        {
            line = $0
            if (match(line, /\/\/ @fmt:[ \t]*[a-z]+[ \t]*$/)) {
                tag = substr(line, RSTART)
                sub(/.*@fmt:[ \t]*/, "", tag)   # drop up to and incl "@fmt:" + any spaces
                sub(/[ \t]*$/, "", tag)
                if (index(fmts, "," tag ",") == 0) next               # format unused → drop line
                sub(/[ \t]*\/\/ @fmt:[ \t]*[a-z]+[ \t]*$/, "", line)  # strip marker from kept line
            }
            print line
        }' > "$dir/MeticaAdService.cs"

    if [ "$has_max" != "1" ]; then
        # No existing game code to rewrite — add a thin entry-point MonoBehaviour.
        {
            echo 'using UnityEngine;'
            echo "using $ns;"
            echo 'public class MeticaBootstrap : MonoBehaviour'
            echo '{'
            echo '    private MeticaAdService _ads;'
            echo '    void Start() { _ads = new MeticaAdService(this); _ads.Initialize(); }'
            [ "$has_inter" = 1 ] && echo '    public void ShowInterstitial() { _ads.ShowInterstitial(); }'
            [ "$has_rew"   = 1 ] && echo '    public void ShowRewarded() { _ads.ShowRewarded(); }'
            echo '}'
        } > "$project/Assets/Scripts/MeticaBootstrap.cs"
    fi
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

# 1. no-Max / interstitial (orchestrator + per-format + bootstrap)
p="$(make_nomax_project)"
emit_standalone "$p" "Metica.AbTest" "interstitial" "ABC123" "XYZ987" 0
run_case "no-Max interstitial" "PASS" "$p"

# 2. no-Max / interstitial + rewarded / namespace MyGame.Services.Metica
p="$(make_nomax_project)"
emit_standalone "$p" "MyGame.Services.Metica" "interstitial,rewarded" "ABC123" "XYZ987" 0
# Assert the namespace wrap and the reward callback land in the per-format file.
if grep -q "namespace MyGame.Services.Metica" "$p/Assets/Scripts/Metica/MeticaRewardedAd.cs" \
    && grep -q "Rewarded.OnAdRewarded" "$p/Assets/Scripts/Metica/MeticaRewardedAd.cs"; then
    run_case "rewarded ns=MyGame.Services.Metica" "PASS" "$p"
else
    echo "  FAIL  rewarded ns=MyGame.Services.Metica  (template missing expected lines)"
    fail=$((fail+1))
    rm -rf "$p"
fi

# 3. privacy AFTER init → validator FAIL (negative golden). Privacy +
# Initialize live in the orchestrator MeticaAdService.cs.
p="$(make_nomax_project)"
emit_standalone "$p" "Metica.AbTest" "interstitial" "ABC123" "XYZ987" 0
orch="$p/Assets/Scripts/Metica/MeticaAdService.cs"
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
' "$orch" > "$orch.new"
mv "$orch.new" "$orch"
run_case "privacy-after-init (negative)" "FAIL" "$p"

# 3b. MaxSDK present (no remote config): the standalone adapter set validates.
p="$(make_max_project)"
emit_standalone "$p" "Metica.AbTest" "interstitial" "ABC123" "XYZ987" 1
run_case "max-present interstitial" "PASS" "$p"

# 4. MRec template — generated file uses the right Metica casing (Mrec, not MRec).
p="$(make_nomax_project)"
emit_standalone "$p" "Metica.AbTest" "interstitial,mrec" "ABC123" "XYZ987" 0
if grep -q "MeticaSdk.Ads.LoadMrec(" "$p/Assets/Scripts/Metica/MeticaMRecAd.cs" \
    && grep -q "MeticaAdsCallbacks.Mrec.OnAdLoadSuccess" "$p/Assets/Scripts/Metica/MeticaMRecAd.cs" \
    && ! grep -q "MeticaSdk.Ads.LoadMRec(" "$p/Assets/Scripts/Metica/MeticaMRecAd.cs"; then
    run_case "mrec (correct Mrec casing)" "PASS" "$p"
else
    echo "  FAIL  fresh mrec template casing"
    grep -nE 'M[Rr]ec' "$p/Assets/Scripts/Metica/MeticaMRecAd.cs" | sed 's/^/        /'
    fail=$((fail+1))
    rm -rf "$p"
fi

# 5. Named handlers + docs-aligned retry shape — every per-format template uses
# named handler methods (OnLoadSuccess, OnLoadFailed, etc.). Interstitial and
# Rewarded carry the docs.metica.com retry pattern (int _retryAttempt counter,
# Math.Pow(2, Math.Min(6, attempt)) backoff, Invoke(nameof(Load), …)) and so are
# MonoBehaviours (Invoke is MonoBehaviour-only). Banner and MRec do NOT carry
# retry — per the docs example, those rely on the SDK's internal refresh and
# only log on OnLoadFailed.
shape_ok=1
for stem in MeticaInterstitialAd MeticaRewardedAd MeticaBannerAd MeticaMRecAd; do
    tmpl="$STANDALONE_DIR/$stem.cs.tmpl"
    # Named handler — at least OnLoadSuccess and OnLoadFailed as separate method declarations.
    if ! grep -qE 'private[[:space:]]+void[[:space:]]+OnLoadSuccess' "$tmpl"; then
        echo "  shape FAIL: $stem missing named OnLoadSuccess handler"; shape_ok=0
    fi
    if ! grep -qE 'private[[:space:]]+void[[:space:]]+OnLoadFailed' "$tmpl"; then
        echo "  shape FAIL: $stem missing named OnLoadFailed handler"; shape_ok=0
    fi
    # All four templates are now MonoBehaviours (so the orchestrator can
    # AddComponent uniformly and interstitial/rewarded can host Invoke-based retry).
    if ! grep -qE 'class[[:space:]]+'"$stem"'[[:space:]]*:[[:space:]]*MonoBehaviour' "$tmpl"; then
        echo "  shape FAIL: $stem must be a MonoBehaviour"; shape_ok=0
    fi
done
# Retry scaffold lives only in interstitial + rewarded (matches the docs example).
for stem in MeticaInterstitialAd MeticaRewardedAd; do
    tmpl="$STANDALONE_DIR/$stem.cs.tmpl"
    if ! grep -q '_retryAttempt' "$tmpl"; then
        echo "  shape FAIL: $stem missing _retryAttempt counter (docs retry pattern)"; shape_ok=0
    fi
    if ! grep -qE 'System\.Math\.Pow\(2,[[:space:]]*System\.Math\.Min\(6' "$tmpl"; then
        echo "  shape FAIL: $stem missing Math.Pow(2, Math.Min(6, …)) backoff formula"; shape_ok=0
    fi
    if ! grep -qE 'Invoke\(nameof\(Load\)' "$tmpl"; then
        echo "  shape FAIL: $stem missing Invoke(nameof(Load), …) retry call"; shape_ok=0
    fi
done
# Banner/MRec must NOT carry retry (matches the docs: SDK handles refresh).
# Banner/MRec must ALSO carry the canonical HomeScreen.cs behaviors:
#   - optional placementTag arg on Create() + SetXPlacement call
#   - _isShowing state flag
#   - OnApplicationFocus pause/resume gated on _isShowing
for stem in MeticaBannerAd MeticaMRecAd; do
    tmpl="$STANDALONE_DIR/$stem.cs.tmpl"
    if grep -q '_retryAttempt' "$tmpl"; then
        echo "  shape FAIL: $stem must NOT carry retry — docs example doesn't retry banner/MRec"; shape_ok=0
    fi
    if grep -qE 'Invoke\(nameof\(Load\)' "$tmpl"; then
        echo "  shape FAIL: $stem must NOT call Invoke(nameof(Load), …)"; shape_ok=0
    fi
    # Create() signature may span multiple lines; check the body contains a
    # placementTag parameter ahead of the SetXPlacement call.
    if ! awk '/public[[:space:]]+void[[:space:]]+Create\(/,/\)/' "$tmpl" | grep -q 'placementTag'; then
        echo "  shape FAIL: $stem.Create must accept an optional placementTag parameter"; shape_ok=0
    fi
    if ! grep -qE 'Set(Banner|Mrec)Placement\(' "$tmpl"; then
        echo "  shape FAIL: $stem must call SetBannerPlacement/SetMrecPlacement when placementTag provided"; shape_ok=0
    fi
    if ! grep -q '_isShowing' "$tmpl"; then
        echo "  shape FAIL: $stem missing _isShowing state flag"; shape_ok=0
    fi
    if ! grep -qE 'OnApplicationFocus\(bool' "$tmpl"; then
        echo "  shape FAIL: $stem missing OnApplicationFocus(bool) handler"; shape_ok=0
    fi
    if ! grep -qE 'Start(Banner|Mrec)AutoRefresh\(' "$tmpl"; then
        echo "  shape FAIL: $stem missing StartBannerAutoRefresh/StartMrecAutoRefresh call (in OnApplicationFocus)"; shape_ok=0
    fi
    if ! grep -qE 'Stop(Banner|Mrec)AutoRefresh\(' "$tmpl"; then
        echo "  shape FAIL: $stem missing StopBannerAutoRefresh/StopMrecAutoRefresh call (in OnApplicationFocus)"; shape_ok=0
    fi
done

# All four templates: diagnostic revenue log carries adUnitId / revenue /
# networkName / placementTag (matches the canonical HomeScreen.cs revenue log).
for stem in MeticaInterstitialAd MeticaRewardedAd MeticaBannerAd MeticaMRecAd; do
    tmpl="$STANDALONE_DIR/$stem.cs.tmpl"
    # The revenue handler body must reference all four diagnostic fields.
    for field in 'ad\.adUnitId' 'ad\.revenue' 'ad\.networkName' 'ad\.placementTag'; do
        if ! grep -qE "$field" "$tmpl"; then
            echo "  shape FAIL: $stem revenue log missing ${field//\\/} field"; shape_ok=0
        fi
    done
done

# All four templates: init-ordering comment on Initialize() so users don't
# call it before MeticaSdk.Initialize fires its callback.
for stem in MeticaInterstitialAd MeticaRewardedAd MeticaBannerAd MeticaMRecAd; do
    tmpl="$STANDALONE_DIR/$stem.cs.tmpl"
    if ! grep -qE 'OnInitialized callback|MeticaAdService' "$tmpl"; then
        echo "  shape FAIL: $stem missing the init-ordering comment on Initialize()"; shape_ok=0
    fi
done

if [ "$shape_ok" = "1" ]; then
    echo "  PASS  per-format templates: named handlers + docs-aligned retry shape + canonical lifecycle"
    pass=$((pass+1))
else
    fail=$((fail+1))
fi

# 6. Orchestrator template shape — the promoted MeticaAdService.cs.tmpl must
# carry the canonical init structure (privacy precedes Initialize), the config
# constructor, and a `// @fmt:<format>` marker for each per-format adapter so
# codegen can drop the formats a project doesn't use.
orch_tmpl="$STANDALONE_DIR/MeticaAdService.cs.tmpl"
orch_ok=1
if [ ! -f "$orch_tmpl" ]; then
    echo "  shape FAIL: MeticaAdService.cs.tmpl missing"; orch_ok=0
else
    grep -q 'class MeticaAdService'           "$orch_tmpl" || { echo "  shape FAIL: orchestrator missing class MeticaAdService"; orch_ok=0; }
    grep -q 'MeticaSdk.Ads.SetHasUserConsent' "$orch_tmpl" || { echo "  shape FAIL: orchestrator missing SetHasUserConsent"; orch_ok=0; }
    grep -q 'MeticaSdk.Ads.SetDoNotSell'      "$orch_tmpl" || { echo "  shape FAIL: orchestrator missing SetDoNotSell"; orch_ok=0; }
    grep -q 'MeticaSdk.Initialize('           "$orch_tmpl" || { echo "  shape FAIL: orchestrator missing MeticaSdk.Initialize"; orch_ok=0; }
    grep -q 'new MeticaInitConfig('           "$orch_tmpl" || { echo "  shape FAIL: orchestrator missing MeticaInitConfig constructor"; orch_ok=0; }
    for f in banner interstitial rewarded mrec; do
        grep -q "@fmt:$f" "$orch_tmpl" || { echo "  shape FAIL: orchestrator missing @fmt:$f marker"; orch_ok=0; }
    done
    # Privacy must precede Initialize in the template (same-file ordering rule).
    cons_line="$(grep -n 'SetHasUserConsent' "$orch_tmpl" | head -1 | cut -d: -f1)"
    init_line="$(grep -n 'MeticaSdk.Initialize(' "$orch_tmpl" | head -1 | cut -d: -f1)"
    if [ -n "$cons_line" ] && [ -n "$init_line" ] && [ "$cons_line" -ge "$init_line" ]; then
        echo "  shape FAIL: orchestrator privacy call must precede Initialize"; orch_ok=0
    fi
fi
if [ "$orch_ok" = "1" ]; then
    echo "  PASS  orchestrator template shape (privacy-before-init + @fmt markers)"
    pass=$((pass+1))
else
    fail=$((fail+1))
fi

echo
echo "Pass: $pass   Fail: $fail"
[ "$fail" = "0" ] || exit 1
