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
# Coverage:
#   1. fresh / interstitial / no namespace          → PASS
#   2. fresh / rewarded / namespace MyGame.Services → PASS  (validates wrap + reward callback)
#   3. fresh / privacy AFTER init                   → FAIL  (negative golden)
#   4. side-by-side / firebase binding              → PASS  (validates 4 adapter files + 5th binding)
#   5. side-by-side / none binding                  → PASS  (validates TODO-stub variant)
#   6. side-by-side / Metica-prefixed names         → PASS  (validates collision-prefix path)

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE="$PLUGIN_DIR/scripts/validate-integration.sh"
TEMPLATE_DIR="$PLUGIN_DIR/scripts/templates/sidebyside"
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
# Args: project ns formats(csv) api app mode(fresh|straight-swap)
emit_standalone() {
    local project="$1" ns="$2" formats="$3" api="$4" app="$5" mode="$6"
    local dir="$project/Assets/Scripts/Metica"
    mkdir -p "$dir"

    local has_banner=0 has_inter=0 has_rew=0
    case ",$formats," in *,banner,*) has_banner=1 ;; esac
    case ",$formats," in *,interstitial,*) has_inter=1 ;; esac
    case ",$formats," in *,rewarded,*) has_rew=1 ;; esac

    # Per-format objects (from templates).
    [ "$has_banner" = 1 ] && emit_standalone_perfile MeticaBannerAd       "$dir" "$ns"
    [ "$has_inter"  = 1 ] && emit_standalone_perfile MeticaInterstitialAd "$dir" "$ns"
    [ "$has_rew"    = 1 ] && emit_standalone_perfile MeticaRewardedAd     "$dir" "$ns"

    # Mediation: fresh = none; straight-swap = MAX (Metica mediates via AppLovin).
    local mediation='null'
    [ "$mode" = "straight-swap" ] && mediation='new MeticaMediationInfo(MeticaMediationInfo.MeticaMediationType.MAX, "MAXKEY99")'

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
        echo '    public void Initialize()'
        echo '    {'
        echo '        MeticaSdk.Ads.SetHasUserConsent(true);'
        echo '        MeticaSdk.Ads.SetDoNotSell(false);'
        printf '        var config = new MeticaInitConfig("%s", "%s", null);\n' "$api" "$app"
        printf '        MeticaSdk.Initialize(config, %s, response =>\n' "$mediation"
        echo '        {'
        [ "$has_banner" = 1 ] && echo '            _banner = new MeticaBannerAd("banner_main"); _banner.Create(); _banner.Load(); _banner.Show();'
        [ "$has_inter"  = 1 ] && echo '            _interstitial = new MeticaInterstitialAd("interstitial_main"); _interstitial.Load();'
        [ "$has_rew"    = 1 ] && echo '            _rewarded = new MeticaRewardedAd("rewarded_main"); _rewarded.Load();'
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
            echo '    void Start() { _ads = new MeticaAdService(); _ads.Initialize(); }'
            [ "$has_inter" = 1 ] && echo '    public void ShowInterstitial() { _ads.ShowInterstitial(); }'
            [ "$has_rew"   = 1 ] && echo '    public void ShowRewarded() { _ads.ShowRewarded(); }'
            echo '}'
        } > "$project/Assets/Scripts/MeticaBootstrap.cs"
    fi
}

# Reference impl of the agent's side-by-side codegen.
# Reads templates verbatim and applies the documented transforms.
# Args: project, namespace, prefix (may be empty), api_key, app_id, max_key
emit_sbs_files() {
    local project="$1" ns="$2" prefix="$3" api="$4" app="$5" maxk="$6"
    local out_dir="$project/Assets/Scripts/Metica"
    mkdir -p "$out_dir"

    # Collision-prefixed stems: filename + identifier references get the prefix.
    local files=(IAdService MaxAdService MeticaAdService AdServiceRouter)
    for stem in "${files[@]}"; do
        local tmpl="$TEMPLATE_DIR/$stem.cs.tmpl"
        local out="$out_dir/${prefix}${stem}.cs"
        # Apply transforms via sed: namespace + identifier prefix + key substitution.
        sed \
            -e "s|namespace Metica\\.AbTest|namespace $ns|g" \
            -e "s|} // namespace Metica\\.AbTest|} // namespace $ns|g" \
            -e "s|__METICA_API_KEY__|$api|g" \
            -e "s|__METICA_APP_ID__|$app|g" \
            -e "s|__MAX_SDK_KEY__|$maxk|g" \
            "$tmpl" > "$out"
        if [ -n "$prefix" ]; then
            # Replace identifier references in this order (no word-boundary regex,
            # which BSD sed lacks). Order matters: rename the original class names
            # FIRST so later renames don't accidentally match inside earlier
            # prefixed forms (e.g. MeticaAdService → MeticaMeticaAdService must
            # happen before AdServiceRouter → MeticaAdServiceRouter, otherwise
            # MeticaAdServiceRouter would re-match as a prefix and become
            # MeticaMeticaAdServiceRouter).
            sed -i.bak \
                -e "s|MeticaAdService|${prefix}MeticaAdService|g" \
                -e "s|MaxAdService|${prefix}MaxAdService|g" \
                -e "s|IAdService|${prefix}IAdService|g" \
                -e "s|AdServiceRouter|${prefix}AdServiceRouter|g" \
                "$out"
            rm -f "$out.bak"
            # Adjust the output filename: emit_sbs_files already wrote to ${prefix}${stem}.cs
            # so no rename needed.
        fi
    done

    # Per-format handler objects (split out of MeticaAdService). Their own class
    # names don't collide with user types, so the FILENAME is never prefixed — but
    # in prefix mode the shared identifier rename still runs over their content so
    # any reference (and orchestrator mention in comments) stays consistent with
    # the prefixed orchestrator/interface.
    for stem in MeticaInterstitialAd MeticaRewardedAd MeticaBannerAd; do
        local out="$out_dir/$stem.cs"
        sed \
            -e "s|namespace Metica\\.AbTest|namespace $ns|g" \
            -e "s|} // namespace Metica\\.AbTest|} // namespace $ns|g" \
            "$TEMPLATE_DIR/$stem.cs.tmpl" > "$out"
        if [ -n "$prefix" ]; then
            sed -i.bak \
                -e "s|MeticaAdService|${prefix}MeticaAdService|g" \
                -e "s|MaxAdService|${prefix}MaxAdService|g" \
                -e "s|IAdService|${prefix}IAdService|g" \
                -e "s|AdServiceRouter|${prefix}AdServiceRouter|g" \
                "$out"
            rm -f "$out.bak"
        fi
    done
}

# Args: project, namespace, prefix, variant (firebase|none), key
emit_rollout_binding() {
    local project="$1" ns="$2" prefix="$3" variant="$4" key="$5"
    local out="$project/Assets/Scripts/Metica/${prefix}MeticaRolloutBinding.cs"
    local router="${prefix}AdServiceRouter"

    case "$variant" in
        firebase)
            cat > "$out" <<EOF
using Firebase.RemoteConfig;
using UnityEngine;

namespace $ns
{
    static class MeticaRolloutBinding
    {
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        static void Bind()
        {
            $router.RolloutDecisionFunc = () =>
                FirebaseRemoteConfig.DefaultInstance.GetValue("$key").BooleanValue;
        }
    }
}
EOF
            ;;
        none)
            cat > "$out" <<EOF
using UnityEngine;

namespace $ns
{
    static class MeticaRolloutBinding
    {
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        static void Bind()
        {
            // CHOOSE ONE AND UNCOMMENT — DO NOT SHIP THIS STUB
            //
            // Firebase Remote Config:
            // $router.RolloutDecisionFunc = () =>
            //     Firebase.RemoteConfig.FirebaseRemoteConfig.DefaultInstance.GetValue("$key").BooleanValue;
            //
            // AppMetrica:
            // $router.RolloutDecisionFunc = () =>
            //     Io.AppMetrica.AppMetrica.GetFeatureFlag("$key");
            //
            // Unity Remote Config:
            // $router.RolloutDecisionFunc = () =>
            //     Unity.Services.RemoteConfig.RemoteConfigService.Instance.appConfig.GetBool("$key");
        }
    }
}
EOF
            ;;
    esac
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
   && [ ! -f "$p/Assets/Scripts/Metica/MeticaRolloutBinding.cs" ]; then
    run_case "straight-swap interstitial (no router/Max adapter/binding)" "PASS" "$p" "straight-swap"
else
    echo "  FAIL  straight-swap interstitial  (unexpected router/Max-adapter/binding file generated)"
    fail=$((fail+1))
    rm -rf "$p"
fi

# 4. side-by-side / firebase binding
p="$(make_sbs_project)"
emit_sbs_files "$p" "Metica.AbTest" "" "ABC123" "XYZ987" "MAXKEY99"
emit_rollout_binding "$p" "Metica.AbTest" "" "firebase" "metica_rollout"
if grep -q "FirebaseRemoteConfig.DefaultInstance.GetValue" "$p/Assets/Scripts/Metica/MeticaRolloutBinding.cs"; then
    run_case "sbs firebase binding" "PASS" "$p" "side-by-side"
else
    echo "  FAIL  sbs firebase binding  (binding template missing FirebaseRemoteConfig call)"
    fail=$((fail+1))
    rm -rf "$p"
fi

# 5. side-by-side / none binding (TODO-stub)
p="$(make_sbs_project)"
emit_sbs_files "$p" "Metica.AbTest" "" "ABC123" "XYZ987" "MAXKEY99"
emit_rollout_binding "$p" "Metica.AbTest" "" "none" "metica_rollout"
all_three=1
grep -q "Firebase Remote Config:"     "$p/Assets/Scripts/Metica/MeticaRolloutBinding.cs" || all_three=0
grep -q "AppMetrica:"                  "$p/Assets/Scripts/Metica/MeticaRolloutBinding.cs" || all_three=0
grep -q "Unity Remote Config:"         "$p/Assets/Scripts/Metica/MeticaRolloutBinding.cs" || all_three=0
if [ "$all_three" = 1 ]; then
    run_case "sbs none binding (TODO stub)" "PASS" "$p" "side-by-side"
else
    echo "  FAIL  sbs none binding (TODO stub)  (missing one of the three commented examples)"
    fail=$((fail+1))
    rm -rf "$p"
fi

# 6. side-by-side / Metica-prefixed names (collision-prefix path)
p="$(make_sbs_project)"
# Pre-existing IAdService in the project triggers prefix mode.
mkdir -p "$p/Assets/Scripts/Existing"
cat > "$p/Assets/Scripts/Existing/IAdService.cs" <<'EOF'
namespace Existing { public interface IAdService { } }
EOF
emit_sbs_files "$p" "MyGame.Services.Metica" "Metica" "ABC123" "XYZ987" "MAXKEY99"
emit_rollout_binding "$p" "MyGame.Services.Metica" "Metica" "firebase" "metica_rollout"
if grep -q "MeticaAdServiceRouter" "$p/Assets/Scripts/Metica/MeticaAdServiceRouter.cs" \
    && grep -q "namespace MyGame.Services.Metica" "$p/Assets/Scripts/Metica/MeticaAdServiceRouter.cs"; then
    run_case "sbs Metica-prefixed names" "PASS" "$p" "side-by-side"
else
    echo "  FAIL  sbs Metica-prefixed names  (prefix or namespace not applied)"
    fail=$((fail+1))
    rm -rf "$p"
fi

# 7. Property: after prefix mode, NO unprefixed base name leaks into any
# generated file. This guards against a future rename-order regression
# (adding a 6th class without thinking through substring overlap).
p="$(make_sbs_project)"
emit_sbs_files "$p" "MyGame.Services.Metica" "Metica" "ABC123" "XYZ987" "MAXKEY99"
emit_rollout_binding "$p" "MyGame.Services.Metica" "Metica" "firebase" "metica_rollout"
unprefixed_leaks=0
for stem in IAdService MaxAdService MeticaAdService AdServiceRouter; do
    # An unprefixed name is one that doesn't have an alphanumeric or '_' char
    # immediately before it. Use grep -P for negative lookbehind.
    if grep -rPq "(?<![A-Za-z0-9_])${stem}(?![A-Za-z0-9_])" "$p/Assets/Scripts/Metica/" 2>/dev/null; then
        echo "        leak: unprefixed '$stem' found in generated files"
        grep -rnP "(?<![A-Za-z0-9_])${stem}(?![A-Za-z0-9_])" "$p/Assets/Scripts/Metica/" | sed 's/^/          /'
        unprefixed_leaks=1
    fi
done
if [ "$unprefixed_leaks" = "0" ]; then
    echo "  PASS  sbs prefix property (no unprefixed leaks)"
    pass=$((pass+1))
else
    echo "  FAIL  sbs prefix property (unprefixed names leaked)"
    fail=$((fail+1))
fi
rm -rf "$p"

echo
echo "Pass: $pass   Fail: $fail"
[ "$fail" = "0" ] || exit 1
