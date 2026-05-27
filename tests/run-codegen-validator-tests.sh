#!/bin/bash
# run-codegen-validator-tests.sh — validate the canonical agent-generated outputs.
#
# Codegen lives in the integrator agent's prose (no shell codegen scripts). This
# suite cannot drive the agent from bash, so it pre-populates synthetic projects
# with the *expected* agent output — a reference impl that mirrors integrator.md
# Step 5 verbatim (template Read + format-block stripping + namespace/prefix/key
# substitution) — and runs the unchanged validator over them. If a documented
# template or transform is invalid, this test catches it.
#
# Coverage:
#   1. fresh / interstitial / no namespace            → PASS
#   2. fresh / banner+rewarded / ns MyGame.Services   → PASS  (wrap + reward callback + per-format files)
#   3. fresh / privacy AFTER init                     → FAIL  (negative golden)
#   4. side-by-side / all formats / firebase binding  → PASS  (MeticaAdProvider + 3 providers + binding)
#   5. side-by-side / interstitial only / none        → PASS  (per-format omission + NO-OP stubs)
#   6. side-by-side / Metica-prefixed names           → PASS  (collision-prefix path)
#   7. side-by-side / gameanalytics binding           → PASS  (variant-ID comparison)
#   8. prefix property: no unprefixed base name leaks

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATE="$PLUGIN_DIR/scripts/validate-integration.sh"
SBS_TMPL_DIR="$PLUGIN_DIR/scripts/templates/sidebyside"
FRESH_TMPL_DIR="$PLUGIN_DIR/scripts/templates/fresh"

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

# Uppercase, space-separated format list from a csv (banner,rewarded → "BANNER REWARDED").
formats_upper() {
    printf '%s\n' "$1" | tr ',' '\n' | tr '[:lower:]' '[:upper:]' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
}

# Side-by-side format-block stripping — mirrors integrator.md strip_format_blocks().
strip_sbs_blocks() {
    local infile="$1" outfile="$2" used="$3" f script=""
    for f in BANNER INTERSTITIAL REWARDED; do
        if printf '%s\n' $used | grep -qx "$f"; then
            script="$script
/__FMT_${f}_STUB_BEGIN__/,/__FMT_${f}_STUB_END__/d
/__FMT_${f}_BEGIN__[[:space:]]*\$/d
/__FMT_${f}_END__[[:space:]]*\$/d
/__FMT_${f}_BODY_BEGIN__[[:space:]]*\$/d
/__FMT_${f}_BODY_END__[[:space:]]*\$/d"
        else
            script="$script
/__FMT_${f}_BEGIN__/,/__FMT_${f}_END__/d
/__FMT_${f}_BODY_BEGIN__/,/__FMT_${f}_BODY_END__/d
/__FMT_${f}_STUB_BEGIN__[[:space:]]*\$/d
/__FMT_${f}_STUB_END__[[:space:]]*\$/d"
        fi
    done
    sed "$script" "$infile" > "$outfile"
}

# Fresh format-block stripping — mirrors integrator.md strip_fresh_blocks().
strip_fresh_blocks() {
    local infile="$1" outfile="$2" used="$3" f script=""
    for f in BANNER INTERSTITIAL REWARDED; do
        if printf '%s\n' $used | grep -qx "$f"; then
            script="$script
/__FMT_${f}_BEGIN__[[:space:]]*\$/d
/__FMT_${f}_END__[[:space:]]*\$/d"
        else
            script="$script
/__FMT_${f}_BEGIN__/,/__FMT_${f}_END__/d"
        fi
    done
    sed "$script" "$infile" > "$outfile"
}

# Wrap a whole file's content in `namespace <ns> { ... }` when ns is non-empty.
# (using directives inside a namespace body are valid C#.)
ns_wrap() {
    local file="$1" ns="$2"
    [ -z "$ns" ] && return 0
    local tmp; tmp="$(mktemp)"
    { printf 'namespace %s\n{\n' "$ns"; cat "$file"; printf '}\n'; } > "$tmp"
    mv "$tmp" "$file"
}

# Reference impl of the agent's fresh-mode codegen (integrator.md Step 5).
# Args: project, namespace_or_empty, formats (csv), api_key, app_id
emit_fresh_files() {
    local project="$1" ns="$2" formats="$3" api="$4" app="$5"
    local out_dir="$project/Assets/Scripts/Metica"
    mkdir -p "$out_dir"
    local used; used="$(formats_upper "$formats")"

    # MeticaAdProvider.cs (always): key sub → format strip → ns wrap.
    local tmp; tmp="$(mktemp)"
    sed -e "s|__METICA_API_KEY__|$api|g" -e "s|__METICA_APP_ID__|$app|g" \
        "$FRESH_TMPL_DIR/MeticaAdProvider.cs.tmpl" > "$tmp"
    strip_fresh_blocks "$tmp" "$out_dir/MeticaAdProvider.cs" "$used"
    rm -f "$tmp"
    ns_wrap "$out_dir/MeticaAdProvider.cs" "$ns"

    # Per-format provider files (only for used formats): ns wrap.
    printf '%s\n' $used | grep -qx BANNER && {
        cp "$FRESH_TMPL_DIR/MeticaBannerProvider.cs.tmpl" "$out_dir/MeticaBannerProvider.cs"
        ns_wrap "$out_dir/MeticaBannerProvider.cs" "$ns"; }
    printf '%s\n' $used | grep -qx INTERSTITIAL && {
        cp "$FRESH_TMPL_DIR/MeticaInterstitialProvider.cs.tmpl" "$out_dir/MeticaInterstitialProvider.cs"
        ns_wrap "$out_dir/MeticaInterstitialProvider.cs" "$ns"; }
    printf '%s\n' $used | grep -qx REWARDED && {
        cp "$FRESH_TMPL_DIR/MeticaRewardedProvider.cs.tmpl" "$out_dir/MeticaRewardedProvider.cs"
        ns_wrap "$out_dir/MeticaRewardedProvider.cs" "$ns"; }
}

# Reference impl of the agent's side-by-side codegen.
# Args: project, namespace, prefix (may be empty), formats (csv), api, app, max_key
emit_sbs_files() {
    local project="$1" ns="$2" prefix="$3" formats="$4" api="$5" app="$6" maxk="$7"
    local out_dir="$project/Assets/Scripts/Metica"
    mkdir -p "$out_dir"
    local used; used="$(formats_upper "$formats")"

    # 4 unconditional adapter files.
    local stem out
    for stem in IAdService MaxAdService MeticaAdProvider AdServiceRouter; do
        out="$out_dir/${prefix}${stem}.cs"
        sed \
            -e "s|namespace Metica\\.AbTest|namespace $ns|g" \
            -e "s|} // namespace Metica\\.AbTest|} // namespace $ns|g" \
            -e "s|__METICA_API_KEY__|$api|g" \
            -e "s|__METICA_APP_ID__|$app|g" \
            -e "s|__MAX_SDK_KEY__|$maxk|g" \
            "$SBS_TMPL_DIR/$stem.cs.tmpl" > "$out"
        if [ "$stem" = "MeticaAdProvider" ]; then
            strip_sbs_blocks "$out" "$out.stripped" "$used"
            mv "$out.stripped" "$out"
        fi
        if [ -n "$prefix" ]; then
            # Order matters: rename longer/original names before shorter so a
            # prefixed form isn't re-matched. Do NOT prefix the per-format
            # provider class names (already Metica-prefixed).
            sed -i.bak \
                -e "s|MeticaAdProvider|${prefix}MeticaAdProvider|g" \
                -e "s|MaxAdService|${prefix}MaxAdService|g" \
                -e "s|IAdService|${prefix}IAdService|g" \
                -e "s|AdServiceRouter|${prefix}AdServiceRouter|g" \
                "$out"
            rm -f "$out.bak"
        fi
    done

    # Per-format provider files (only for used formats); namespace replace only.
    local pf
    for pf in Banner:BANNER Interstitial:INTERSTITIAL Rewarded:REWARDED; do
        local cls="${pf%%:*}" key="${pf##*:}"
        printf '%s\n' $used | grep -qx "$key" || continue
        out="$out_dir/Metica${cls}Provider.cs"
        sed \
            -e "s|namespace Metica\\.AbTest|namespace $ns|g" \
            -e "s|} // namespace Metica\\.AbTest|} // namespace $ns|g" \
            "$SBS_TMPL_DIR/Metica${cls}Provider.cs.tmpl" > "$out"
        if [ -n "$prefix" ]; then
            sed -i.bak \
                -e "s|MeticaAdProvider|${prefix}MeticaAdProvider|g" \
                -e "s|MaxAdService|${prefix}MaxAdService|g" \
                -e "s|IAdService|${prefix}IAdService|g" \
                -e "s|AdServiceRouter|${prefix}AdServiceRouter|g" \
                "$out"
            rm -f "$out.bak"
        fi
    done
}

# Args: project, namespace, prefix, variant (firebase|none|gameanalytics), key
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
        gameanalytics)
            cat > "$out" <<EOF
using GameAnalyticsSDK;
using UnityEngine;

namespace $ns
{
    static class MeticaRolloutBinding
    {
        [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
        static void Bind()
        {
            $router.RolloutDecisionFunc = () =>
                GameAnalytics.GetABTestingId() == "$key";
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
            //
            // GameAnalytics A/B (compare against the variant ID for the Metica cohort):
            // $router.RolloutDecisionFunc = () =>
            //     GameAnalyticsSDK.GameAnalytics.GetABTestingId() == "$key";
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

# 1. fresh / interstitial / no namespace
p="$(make_fresh_project)"
emit_fresh_files "$p" "" "interstitial" "ABC123" "XYZ987"
if grep -qF '__FMT_' "$p/Assets/Scripts/Metica/MeticaAdProvider.cs"; then
    echo "  FAIL  fresh interstitial no-ns  (marker leak)"; fail=$((fail+1)); rm -rf "$p"
else
    run_case "fresh interstitial no-ns" "PASS" "$p" "fresh"
fi

# 2. fresh / banner+rewarded / namespace MyGame.Services
p="$(make_fresh_project)"
emit_fresh_files "$p" "MyGame.Services" "banner,rewarded" "ABC123" "XYZ987"
d="$p/Assets/Scripts/Metica"
if grep -q "namespace MyGame.Services" "$d/MeticaAdProvider.cs" \
    && [ -f "$d/MeticaBannerProvider.cs" ] && [ -f "$d/MeticaRewardedProvider.cs" ] \
    && [ ! -f "$d/MeticaInterstitialProvider.cs" ] \
    && grep -q "Rewarded.OnAdRewarded" "$d/MeticaRewardedProvider.cs"; then
    run_case "fresh banner+rewarded ns=MyGame.Services" "PASS" "$p" "fresh"
else
    echo "  FAIL  fresh banner+rewarded ns=MyGame.Services  (layout/wrap/reward-callback)"
    ls "$d" | sed 's/^/        /'
    fail=$((fail+1)); rm -rf "$p"
fi

# 3. fresh / privacy AFTER init → validator FAIL (negative golden)
p="$(make_fresh_project)"
emit_fresh_files "$p" "" "interstitial" "ABC123" "XYZ987"
f="$p/Assets/Scripts/Metica/MeticaAdProvider.cs"
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
' "$f" > "$f.new"
mv "$f.new" "$f"
run_case "fresh privacy-after-init (negative)" "FAIL" "$p" "fresh"

# 4. side-by-side / all formats / firebase binding
p="$(make_sbs_project)"
emit_sbs_files "$p" "Metica.AbTest" "" "banner,interstitial,rewarded" "ABC123" "XYZ987" "MAXKEY99"
emit_rollout_binding "$p" "Metica.AbTest" "" "firebase" "metica_rollout"
d="$p/Assets/Scripts/Metica"
if grep -q "FirebaseRemoteConfig.DefaultInstance.GetValue" "$d/MeticaRolloutBinding.cs" \
    && [ -f "$d/MeticaAdProvider.cs" ] && [ -f "$d/MeticaBannerProvider.cs" ] \
    && [ -f "$d/MeticaInterstitialProvider.cs" ] && [ -f "$d/MeticaRewardedProvider.cs" ] \
    && ! grep -qF '__FMT_' "$d/MeticaAdProvider.cs"; then
    run_case "sbs all-formats firebase binding" "PASS" "$p" "side-by-side"
else
    echo "  FAIL  sbs all-formats firebase binding  (missing file / marker leak / binding)"
    ls "$d" | sed 's/^/        /'
    fail=$((fail+1)); rm -rf "$p"
fi

# 5. side-by-side / interstitial only / none binding → per-format omission + NO-OP stubs
p="$(make_sbs_project)"
emit_sbs_files "$p" "Metica.AbTest" "" "interstitial" "ABC123" "XYZ987" "MAXKEY99"
emit_rollout_binding "$p" "Metica.AbTest" "" "none" "metica_rollout"
d="$p/Assets/Scripts/Metica"
ok=1
[ -f "$d/MeticaInterstitialProvider.cs" ] || ok=0
[ ! -f "$d/MeticaBannerProvider.cs" ]     || ok=0
[ ! -f "$d/MeticaRewardedProvider.cs" ]   || ok=0
grep -q "NO-OP: banner format not used"   "$d/MeticaAdProvider.cs" || ok=0
grep -q "NO-OP: rewarded format not used" "$d/MeticaAdProvider.cs" || ok=0
grep -qF '__FMT_' "$d/MeticaAdProvider.cs" && ok=0
if [ "$ok" = 1 ]; then
    run_case "sbs interstitial-only + NO-OP stubs" "PASS" "$p" "side-by-side"
else
    echo "  FAIL  sbs interstitial-only + NO-OP stubs  (omission/stub/marker)"
    ls "$d" | sed 's/^/        /'
    fail=$((fail+1)); rm -rf "$p"
fi

# 6. side-by-side / Metica-prefixed names (collision-prefix path)
p="$(make_sbs_project)"
mkdir -p "$p/Assets/Scripts/Existing"
cat > "$p/Assets/Scripts/Existing/IAdService.cs" <<'EOF'
namespace Existing { public interface IAdService { } }
EOF
emit_sbs_files "$p" "MyGame.Services.Metica" "Metica" "banner,interstitial,rewarded" "ABC123" "XYZ987" "MAXKEY99"
emit_rollout_binding "$p" "MyGame.Services.Metica" "Metica" "firebase" "metica_rollout"
d="$p/Assets/Scripts/Metica"
if grep -q "MeticaAdServiceRouter" "$d/MeticaAdServiceRouter.cs" \
    && grep -q "namespace MyGame.Services.Metica" "$d/MeticaAdServiceRouter.cs" \
    && grep -q "new MeticaMeticaAdProvider(" "$d/MeticaAdServiceRouter.cs"; then
    run_case "sbs Metica-prefixed names" "PASS" "$p" "side-by-side"
else
    echo "  FAIL  sbs Metica-prefixed names  (prefix or namespace not applied)"
    fail=$((fail+1)); rm -rf "$p"
fi

# 7. side-by-side / gameanalytics binding
p="$(make_sbs_project)"
emit_sbs_files "$p" "Metica.AbTest" "" "interstitial,rewarded" "ABC123" "XYZ987" "MAXKEY99"
emit_rollout_binding "$p" "Metica.AbTest" "" "gameanalytics" "metica_variant"
d="$p/Assets/Scripts/Metica"
if grep -q 'GameAnalytics.GetABTestingId() == "metica_variant"' "$d/MeticaRolloutBinding.cs"; then
    run_case "sbs gameanalytics binding" "PASS" "$p" "side-by-side"
else
    echo "  FAIL  sbs gameanalytics binding  (variant-ID comparison missing)"
    fail=$((fail+1)); rm -rf "$p"
fi

# 8. Property: after prefix mode, NO unprefixed base name leaks into any
# generated file. Guards against a rename-order regression.
p="$(make_sbs_project)"
emit_sbs_files "$p" "MyGame.Services.Metica" "Metica" "banner,interstitial,rewarded" "ABC123" "XYZ987" "MAXKEY99"
emit_rollout_binding "$p" "MyGame.Services.Metica" "Metica" "firebase" "metica_rollout"
unprefixed_leaks=0
# Extract every maximal identifier token from the generated files, then check
# whether any UNPREFIXED base name survives as a standalone token. Maximal munch
# means MeticaIAdService / MeticaMeticaAdProvider / MeticaAdServiceRouter come out
# whole and never reduce to a bare IAdService / MeticaAdProvider / AdServiceRouter.
# Uses only -rhoE / -qx (portable to BSD/macOS); avoids grep -P (PCRE lookbehind),
# which BSD grep lacks and would make this guard silently no-op.
tokens="$(grep -rhoE '[A-Za-z_][A-Za-z0-9_]*' "$p/Assets/Scripts/Metica/" 2>/dev/null)"
for stem in IAdService MaxAdService MeticaAdProvider AdServiceRouter; do
    if printf '%s\n' "$tokens" | grep -qx "$stem"; then
        echo "        leak: unprefixed '$stem' found in generated files"
        grep -rn "$stem" "$p/Assets/Scripts/Metica/" | sed 's/^/          /'
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
