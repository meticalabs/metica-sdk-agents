#!/bin/bash
# run-codegen-validator-tests.sh — validate the canonical agent-generated outputs.
#
# Phase 3 deleted codegen-fresh.sh and codegen-sidebyside.sh; codegen now lives
# in the integrator agent's prose. This test suite cannot drive the agent from
# bash, so it instead pre-populates synthetic projects with the *expected* agent
# output (a reference impl that mirrors integrator.md Step 5 verbatim) and runs
# the unchanged validator over them. If a documented template is invalid, this
# test catches it.
#
# Coverage (post-v0.5.0 — router stack retired):
#   1. fresh / interstitial / no namespace          → PASS
#   2. fresh / rewarded / namespace MyGame.Services → PASS  (validates wrap + reward callback)
#   3. fresh / privacy AFTER init                   → FAIL  (negative golden)
#   3b. straight-swap / no router artifacts         → PASS  (validates no IAdService/router leaked)

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

make_fresh_project() {
    local dir; dir="$(mktemp -d -t metica-fresh-XXXXXX)"
    mkdir -p "$dir/Assets/Scripts" "$dir/ProjectSettings"
    printf 'm_EditorVersion: 2022.3.62f2\n' > "$dir/ProjectSettings/ProjectVersion.txt"
    echo "$dir"
}

make_sbs_project() {
    local dir; dir="$(mktemp -d -t metica-sbs-XXXXXX)"
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

# Reference impl of the agent's standalone codegen (fresh + straight-swap,
# integrator.md Step 5): the orchestrator MeticaAdService.cs + per-format files
# (copied from templates) + (fresh only) a thin MeticaBootstrap MonoBehaviour.
# Args: project ns formats(csv) api app mode(fresh|straight-swap) [userid]
emit_standalone() {
    local project="$1" ns="$2" formats="$3" api="$4" app="$5" mode="$6"
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

    # Mediation: fresh = none; straight-swap = MAX (Metica mediates via AppLovin).
    local mediation='null'
    [ "$mode" = "straight-swap" ] && mediation='new MeticaMediationInfo(MeticaMediationType.MAX, "MAXKEY99")'

    # Orchestrator: privacy precedes Initialize in this same file; constructs the
    # per-format objects in the init callback; exposes Show* delegators.
    {
        echo 'using UnityEngine;'
        echo 'using Metica;'
        echo 'using Metica.Ads;'
        echo ''
        echo "namespace $ns {"
        echo 'public class MeticaAdService'
        echo '{'
        [ "$has_banner" = 1 ] && echo '    private MeticaBannerAd _banner;'
        [ "$has_inter"  = 1 ] && echo '    private MeticaInterstitialAd _interstitial;'
        [ "$has_rew"    = 1 ] && echo '    private MeticaRewardedAd _rewarded;'
        [ "$has_mrec"   = 1 ] && echo '    private MeticaMRecAd _mrec;'
        echo '    private MonoBehaviour _runner;'
        echo '    public MeticaAdService(MonoBehaviour runner) { _runner = runner; }'
        echo '    public void Initialize()'
        echo '    {'
        echo '        MeticaSdk.Ads.SetHasUserConsent(true);'
        echo '        MeticaSdk.Ads.SetDoNotSell(false);'
        printf '        var config = new MeticaInitConfig("%s", "%s", %s);\n' "$api" "$app" "$userid"
        printf '        MeticaSdk.Initialize(config, %s, response =>\n' "$mediation"
        echo '        {'
        # Per-format adapters are MonoBehaviours so they can host the docs.metica.com
        # Invoke-based retry for interstitial/rewarded. Orchestrator AddComponent's
        # each onto the runner's GameObject and calls Initialize(adUnitId).
        [ "$has_banner" = 1 ] && echo '            _banner = _runner.gameObject.AddComponent<MeticaBannerAd>(); _banner.Initialize("banner_main"); _banner.Create(); _banner.Load(); _banner.Show();'
        [ "$has_inter"  = 1 ] && echo '            _interstitial = _runner.gameObject.AddComponent<MeticaInterstitialAd>(); _interstitial.Initialize("interstitial_main");'
        [ "$has_rew"    = 1 ] && echo '            _rewarded = _runner.gameObject.AddComponent<MeticaRewardedAd>(); _rewarded.Initialize("rewarded_main");'
        [ "$has_mrec"   = 1 ] && echo '            _mrec = _runner.gameObject.AddComponent<MeticaMRecAd>(); _mrec.Initialize("mrec_main"); _mrec.Create(); _mrec.Load(); _mrec.Show();'
        echo '        });'
        echo '    }'
        [ "$has_inter" = 1 ] && echo '    public void ShowInterstitial() { _interstitial?.Show(); }'
        [ "$has_rew"   = 1 ] && echo '    public void ShowRewarded() { _rewarded?.Show(); }'
        echo '}'
        echo '}'
    } > "$dir/MeticaAdService.cs"

    if [ "$mode" = "fresh" ]; then
        # Thin entry-point MonoBehaviour.
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
    local name="$1" expected="$2" project="$3" mode="$4"
    local json status
    json="$(bash "$VALIDATE" --project="$project" --mode="$mode" 2>&1 || true)"
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

# 1. fresh / interstitial (orchestrator + per-format + bootstrap)
p="$(make_fresh_project)"
emit_standalone "$p" "Metica.AbTest" "interstitial" "ABC123" "XYZ987" "fresh"
run_case "fresh interstitial" "PASS" "$p" "fresh"

# 2. fresh / interstitial + rewarded / namespace MyGame.Services.Metica
p="$(make_fresh_project)"
emit_standalone "$p" "MyGame.Services.Metica" "interstitial,rewarded" "ABC123" "XYZ987" "fresh"
# Assert the namespace wrap and the reward callback land in the per-format file.
if grep -q "namespace MyGame.Services.Metica" "$p/Assets/Scripts/Metica/MeticaRewardedAd.cs" \
    && grep -q "Rewarded.OnAdRewarded" "$p/Assets/Scripts/Metica/MeticaRewardedAd.cs"; then
    run_case "fresh rewarded ns=MyGame.Services.Metica" "PASS" "$p" "fresh"
else
    echo "  FAIL  fresh rewarded ns=MyGame.Services.Metica  (template missing expected lines)"
    fail=$((fail+1))
    rm -rf "$p"
fi

# 3. fresh / privacy AFTER init → validator FAIL (negative golden). Privacy +
# Initialize now live in the orchestrator MeticaAdService.cs.
p="$(make_fresh_project)"
emit_standalone "$p" "Metica.AbTest" "interstitial" "ABC123" "XYZ987" "fresh"
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
run_case "fresh privacy-after-init (negative)" "FAIL" "$p" "fresh"

# 3b. straight-swap (Max present, no remote config): standalone adapter, no
# router / Max adapter / binding. Validated with explicit --mode=straight-swap.
p="$(make_sbs_project)"
emit_standalone "$p" "Metica.AbTest" "interstitial" "ABC123" "XYZ987" "straight-swap"
if [ ! -f "$p/Assets/Scripts/Metica/AdServiceRouter.cs" ] \
   && [ ! -f "$p/Assets/Scripts/Metica/MaxAdService.cs" ] \
   && [ ! -f "$p/Assets/Scripts/Metica/IAdService.cs" ] \
   && [ ! -f "$p/Assets/Scripts/Metica/MeticaRolloutBinding.cs" ]; then
    run_case "straight-swap interstitial (no router/Max adapter/binding/iadservice)" "PASS" "$p" "straight-swap"
else
    echo "  FAIL  straight-swap interstitial  (unexpected router/Max-adapter/binding file generated)"
    fail=$((fail+1))
    rm -rf "$p"
fi

# 4. MRec template — generated file uses the right Metica casing (Mrec, not MRec).
p="$(make_fresh_project)"
emit_standalone "$p" "Metica.AbTest" "interstitial,mrec" "ABC123" "XYZ987" "fresh"
if grep -q "MeticaSdk.Ads.LoadMrec(" "$p/Assets/Scripts/Metica/MeticaMRecAd.cs" \
    && grep -q "MeticaAdsCallbacks.Mrec.OnAdLoadSuccess" "$p/Assets/Scripts/Metica/MeticaMRecAd.cs" \
    && ! grep -q "MeticaSdk.Ads.LoadMRec(" "$p/Assets/Scripts/Metica/MeticaMRecAd.cs"; then
    run_case "fresh mrec (correct Mrec casing)" "PASS" "$p" "fresh"
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

echo
echo "Pass: $pass   Fail: $fail"
[ "$fail" = "0" ] || exit 1
