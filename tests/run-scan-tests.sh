#!/bin/bash
# run-scan-tests.sh — golden eval for scan-max-callsites.sh.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$SCRIPT_DIR/../scripts/scan-max-callsites.sh"

pass=0
fail=0

make_project() {
    local dir; dir="$(mktemp -d -t metica-scan-XXXXXX)"
    mkdir -p "$dir/Assets/Scripts" "$dir/ProjectSettings"
    printf 'm_EditorVersion: 2022.3\n' > "$dir/ProjectSettings/ProjectVersion.txt"
    echo "$dir"
}

count_category() {
    # count_category <json_string> <category>
    printf '%s' "$1" | awk -v cat="$2" '
        BEGIN { n=0 }
        /"category":[[:space:]]*"/ {
            m = index($0, "\"category\":")
            s = substr($0, m + 11); sub(/^[^"]*"/, "", s); sub(/".*$/, "", s)
            if (s == cat) n++
        }
        END { print n }'
}

assert_count() {
    local name="$1" json="$2" cat="$3" expected="$4"
    local got; got=$(count_category "$json" "$cat")
    if [ "$got" = "$expected" ]; then
        printf "  ok    %s (%s = %s)\n" "$name" "$cat" "$got"
        pass=$((pass+1))
    else
        printf "  FAIL  %s: %s expected=%s got=%s\n" "$name" "$cat" "$expected" "$got"
        fail=$((fail+1))
    fi
}

echo "== scan-max-callsites golden eval =="

# 1. Empty project — no callsites
proj=$(make_project)
out=$(bash "$SCAN" --project="$proj")
if echo "$out" | python3 -c 'import sys,json; sys.exit(0 if json.load(sys.stdin)["callsites"]==[] else 1)' 2>/dev/null; then
    printf "  ok    empty project: callsites=[]\n"; pass=$((pass+1))
else
    printf "  FAIL  empty project should yield no callsites\n"
    echo "$out" | sed 's/^/    /'
    fail=$((fail+1))
fi
rm -rf "$proj"

# 2. Synthetic project with one of each category
proj=$(make_project)
cat > "$proj/Assets/Scripts/Game.cs" <<'EOF'
using UnityEngine;
public class Game : MonoBehaviour {
    void Start() {
        MaxSdk.SetSdkKey("KEY");
        MaxSdk.InitializeSdk();
        MaxSdk.SetHasUserConsent(true);
        MaxSdk.SetDoNotSell(false);
        MaxSdk.LoadInterstitial("inter");
        MaxSdk.ShowInterstitial("inter");
        MaxSdk.LoadRewardedAd("rew");
        MaxSdkCallbacks.Interstitial.OnAdLoadedEvent += (id, info) => Debug.Log(id);
        string cc = MaxSdk.GetSdkConfiguration().CountryCode;
    }
}
EOF
out=$(bash "$SCAN" --project="$proj")
assert_count "synthetic: bootstrap"             "$out" "bootstrap"             4
assert_count "synthetic: method_call"           "$out" "method_call"           3
assert_count "synthetic: callback_subscription" "$out" "callback_subscription" 1
assert_count "synthetic: other"                 "$out" "other"                 1
rm -rf "$proj"

# 3. Exclusions: Assets/MaxSdk/, Assets/MeticaSdk/, Assets/Scripts/Metica/
proj=$(make_project)
mkdir -p "$proj/Assets/MaxSdk/Scripts" \
         "$proj/Assets/MeticaSdk/Runtime" \
         "$proj/Assets/Scripts/Metica"
cat > "$proj/Assets/MaxSdk/Scripts/MaxSdk.cs" <<'EOF'
public class MaxSdk { public static void InitializeSdk() {} }
EOF
cat > "$proj/Assets/MeticaSdk/Runtime/Foo.cs" <<'EOF'
public class Foo { void X() { MaxSdk.LoadBanner("x"); } }
EOF
cat > "$proj/Assets/Scripts/Metica/MaxAdService.cs" <<'EOF'
public class MaxAdService { void Y() { MaxSdk.LoadBanner("y"); } }
EOF
out=$(bash "$SCAN" --project="$proj")
total=$(printf '%s' "$out" | grep -c '"category":')
if [ "$total" = "0" ]; then
    printf "  ok    excluded paths: no callsites surfaced from MaxSdk/ MeticaSdk/ Scripts/Metica/\n"
    pass=$((pass+1))
else
    printf "  FAIL  excluded paths leaked %s callsites\n" "$total"
    echo "$out" | sed 's/^/    /'
    fail=$((fail+1))
fi
rm -rf "$proj"

# 4. Comment and string immunity (clean-cs.awk in scan)
proj=$(make_project)
cat > "$proj/Assets/Scripts/Game.cs" <<'EOF'
public class Game {
    // Don't call MaxSdk.InitializeSdk() from comments
    string note = "MaxSdk.LoadInterstitial in a string";
    /* MaxSdkCallbacks.Banner.OnAdLoadedEvent commented out */
    void X() { MaxSdk.LoadBanner("real"); }
}
EOF
out=$(bash "$SCAN" --project="$proj")
total=$(printf '%s' "$out" | grep -c '"category":')
if [ "$total" = "1" ]; then
    printf "  ok    comment/string immunity: only the real callsite surfaced\n"
    pass=$((pass+1))
else
    printf "  FAIL  comment/string immunity broken: %s callsites (expected 1)\n" "$total"
    echo "$out" | sed 's/^/    /'
    fail=$((fail+1))
fi
rm -rf "$proj"

# 5. JSON parses
proj=$(make_project)
echo 'public class G { void X() { MaxSdk.LoadInterstitial("x"); } }' > "$proj/Assets/Scripts/G.cs"
out=$(bash "$SCAN" --project="$proj")
if printf '%s' "$out" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; then
    printf "  ok    output parses as JSON\n"; pass=$((pass+1))
else
    printf "  FAIL  scan output is not valid JSON\n"; echo "$out" | sed 's/^/    /'; fail=$((fail+1))
fi
rm -rf "$proj"

# 6. Real DemoApp: known counts
REAL="$(cd "$SCRIPT_DIR/../../max-agent-test/DemoApp" 2>/dev/null && pwd)"
if [ -d "$REAL" ]; then
    out=$(bash "$SCAN" --project="$REAL")
    boot=$(count_category "$out" "bootstrap")
    if [ "$boot" -ge "2" ]; then
        printf "  ok    real DemoApp: %d bootstrap callsites found (>=2 expected)\n" "$boot"
        pass=$((pass+1))
    else
        printf "  FAIL  real DemoApp: %d bootstrap callsites (expected >=2 for SetSdkKey+InitializeSdk)\n" "$boot"
        fail=$((fail+1))
    fi
fi

echo "----"
printf "passed: %d   failed: %d\n" "$pass" "$fail"
[ "$fail" -eq 0 ]
