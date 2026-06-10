---
name: ad-log-monitor
description: Verify a Metica + AppLovin MAX integration's runtime ad lifecycle on a connected device (Android logcat / iOS idevicesyslog), and compare a holdout-user route against a trial-user route. Captures the log, then extracts ad unit IDs, network attribution, revenue per impression, lifecycle events, load strategy (timestamps), Metica→MAX floor handoff, and errors — and writes a per-route Markdown analysis. A trial-vs-holdout comparison produces a side-by-side verdict with the mandatory n=5 caveat. Optionally also capture a **baseline** route — the live App Store / Play Store build — as a fidelity anchor that confirms the holdout dev-build reproduces production. Use when the user wants to QA an ad integration, smoke-test trial vs holdout, capture logcat/syslog for ad events, analyse an existing ad log, or investigate Metica/AppLovin runtime errors. Trigger phrases include "start ad-log monitoring", "monitor logcat for ads", "capture ad events", "capture the baseline", "analyse this logcat", "stop and analyse the capture", "compare trial vs holdout", "ad lifecycle check".
---

# Metica Ad-Log Monitor

> Was an `@agent-metica-sdk-agents:ad-log-monitor` sub-agent through v1.4.0. Converted to a skill in v1.5.0 because the workflow is interactive (start → user plays → stop → analyse → repeat → compare) and benefits from staying in the main conversation, where the user can ask follow-up questions on the analysis without context-switching to a sub-agent.

This skill verifies a Metica + AppLovin MAX integration from live device logs. Three phases:

1. **Phase 1 — capture.** Kick off a background log capture on a connected device. *Scripted.*
2. **Phase 2 — analyse one route.** Stop the capture, then read the log and produce a structured Markdown analysis for one route (trial or holdout). *Stop is scripted; the analysis itself is your job.*
3. **Phase 3 — compare trial vs holdout.** Once both per-route analyses exist, write a comparison report. If an optional `baseline` route (the live store build) was also captured, fold it in as a fidelity anchor. *Entirely prose.*

## Why Phase 2 is prose, not a deterministic script

Log shape varies between games and SDK versions: class names, prefixes, log levels, custom wrappers, log volume, even AppLovin's internal state-machine strings drift across MAX releases. A grep-counting script written against one game's log produces false PASS/FAIL on another game. Instead, you **run targeted greps, read the actual lines, and interpret them**.

Counts on their own are evidence, not verdict. Always quote actual lines / timestamps in the report so the human can verify your reading.

## Resolve the plugin root

Defensive — `$CLAUDE_PLUGIN_ROOT` is sometimes unset in plugin bash environments, so locate the resolver across known install locations and self-verify the root.

```bash
PLUGIN_DIR=""
for cand in "${CLAUDE_PLUGIN_ROOT:-}" "${METICA_SDK_AGENTS_DIR:-}" \
            "$(ls -d "$HOME"/.claude/plugins/cache/*/metica-sdk-agents/* 2>/dev/null | sort -V 2>/dev/null | tail -1)" \
            "$HOME"/.claude/plugins/cache/*/metica-sdk-agents/* \
            "$HOME/.claude/plugins/marketplaces/metica-sdk-agents" \
            "$HOME/.claude/plugins/metica-sdk-agents" \
            "$HOME/.metica-sdk-agents" "$HOME/dev/metica-sdk-agents"; do
    [ -n "$cand" ] && [ -f "$cand/scripts/resolve-plugin-dir.sh" ] || continue
    PLUGIN_DIR="$(bash "$cand/scripts/resolve-plugin-dir.sh" 2>/dev/null)" && [ -n "$PLUGIN_DIR" ] && break
done
[ -n "$PLUGIN_DIR" ] || { echo "Could not locate metica-sdk-agents plugin root. Set METICA_SDK_AGENTS_DIR to the plugin path and retry." >&2; exit 1; }
```

## Phase decision

**The user's prompt is the routing signal — read what they actually wrote and pick the phase to match.** Do not let directory state override an explicit instruction.

- **Phase 1 (new capture)** — the default. Triggers: a bare `/metica-sdk-agents:ad-log-monitor` invocation, "begin / start / start monitoring / new capture / about to play / connect device", or any prompt that doesn't clearly point at an existing artifact.
- **Phase 2 (analyse one route)** — when the user has finished playing and wants the per-route report. Triggers: "done / stop / analyse / finished playing". Also when the user explicitly points you at an existing captured log (e.g. *"analyse `./trial-user-android-20260604T123045Z.log`"*) — in that case **skip Phase 2a** (the stop script) and go directly to Phase 2b against the file the user named.
- **Phase 3 (compare trial vs holdout)** — triggers: "compare / verdict / trial vs holdout / which is better". Also when the user hands you two existing logs to compare (e.g. *"analyse the 2 existing logs for holdout and trial"*) — run Phase 2b for each first if no per-route `<label>-analysis.md` exists yet, then Phase 3.

**Default to Phase 1, not Phase 2.** Do **not** silently route to Phase 2 just because a `.session` file is sitting in the working directory — that's almost always residue from a prior run the user has forgotten about. Stale sessions are caught by the start script's no-clobber check; relay the BLOCK message and let the user choose (stop the old session, or pick a different `--label`).

The session file's role is a safety interlock against concurrent captures with the same label, **not** a phase-routing signal.

---

## Analysing existing logs (skip Phase 1 and 2a)

If the user gives you an existing log file (or two), skip both scripts. Set:

```bash
LABEL="<from the file name, or whatever the user prefers>"
LOG="<the existing path the user gave you>"
```

and proceed directly to Phase 2b. The session file is not needed — it only hands state from start to stop, both of which you're skipping.

**Label hygiene.** If the filename follows the canonical pattern `<label>-<platform>-<YYYYMMDDThhmmssZ>.log` you can pull the label off the front. If it doesn't (e.g. `crash-repro.log`, `client-build-2.txt`), **ask the user** what kebab-case label to use — `$LABEL` becomes the stem of `./<label>-analysis.md` and (via Phase 3) of `./compare-<trial-label>-vs-<holdout-label>.md`, so it has to be a clean slug or those output filenames break.

If two logs are given (a holdout route and a trial route), run Phase 2b for each in sequence, then Phase 3. Be explicit in your replies about which file you're analysing in which step. If a third `baseline` log (the store build) is also provided, analyse it too and fold it into Phase 3 as the fidelity anchor.

---

## Phase 1 — start a capture

Tell the user the **two-route protocol up front** so they understand what they're committing to:

> "We'll run two captures so we can compare. First with the **holdout user** (control), then with the **trial user** (Metica active). On each run, please play until you've seen roughly **5 interstitials and 5 rewarded ads**. Don't change device, network, or app version between the two runs."

**Optional but highly recommended — a third `baseline` capture.** Suggest (don't require) that the user also capture the **live store build** as a baseline:

> "Optionally — and I'd recommend it — also run a third capture on the **production build installed from the App Store / Play Store**, labelled `baseline`. The holdout and trial are dev builds you provide; the baseline is what real users actually run. Capturing it lets me check that your holdout build faithfully reproduces production before we trust any trial-vs-holdout numbers. Same device, same network, ~5 of each format."

Why it's worth it: holdout and trial share build provenance (both are dev builds), so they compare cleanly — but that says nothing about whether the *holdout itself* matches what ships. The baseline is the production anchor. It is **not** a third A/B arm: it's a different build (store signing, possibly a different app version, likely no Metica), so Phase 3 uses it only as a **fidelity/context check**, never as the pass/fail gate. If the user declines, proceed with the two-route flow unchanged.

If the user hasn't yet picked which route they're starting with, ask. Convention: label = `holdout-user`, `trial-user`, or `baseline` (kebab-case). If they want different labels (e.g. `cohort-a` / `cohort-b`), accept them — only the comparison phase cares about the names matching.

For iOS, ask whether they want to filter by app process name (`--app="App Name"`). Default to **no filter** — `idevicesyslog -p` is case-sensitive on the exact process name and losing logs to a name mismatch is worse than carrying extra lines and filtering at analysis time.

**Android side-effect to flag to the user:** start.sh runs `adb logcat -c` to clear the device's main log buffer before capture, which gives a clean capture but **wipes existing log history for every app on the device**, not just the target. If QA is running other debugging workflows concurrently and might want their existing logs, warn them before you run the script.

Then run the start script:

```bash
bash "$PLUGIN_DIR/scripts/log-monitor-start.sh" --label=<slug> [--platform=auto|android|ios] [--app="App Name"]
```

The script handles: kebab-case validation, platform auto-detection (`adb devices` / `idevice_id -l`), the toolchain gate (hard BLOCK with install hint if `adb` / `idevicesyslog` are missing), session-file no-clobber check (interlock against concurrent captures with the same label), and post-launch health checks (PID alive + non-empty file + first line isn't a tool error). On any failure it cleans up and exits non-zero with an actionable message — relay the message and stop.

On success, relay the script's confirmation block verbatim. Then hand off: "Play the game on the device. When you've seen ~5 interstitials and ~5 rewarded ads, tell me you're done."

---

## Phase 2 — stop a capture and analyse the route

Two beats. First **2a** (script): stop the capture. Then **2b** (you): read the log and write the analysis.

### Phase 2a — stop the capture

```bash
bash "$PLUGIN_DIR/scripts/log-monitor-stop.sh" --label=<slug>
```

The script kills the background capture, prints the log path + total line count + platform + app filter + start time, removes the session file, and exits 0. Relay that block verbatim — it tells the user the capture survived and what file you're about to read.

### Phase 2b — analyse the route (this is *your* job)

Read `<log_file>` from the script's output and write a Markdown analysis to `./<label>-analysis.md`. The shape of the report is the **template at the bottom of this section**; the substeps below are how you fill each table.

All greps below assume `LABEL="<label>"` and `LOG="<log_file>"` from the stop script's summary (both are needed: `$LABEL` names `./${LABEL}-filtered.txt` and `./${LABEL}-analysis.md`; `$LOG` is the raw capture). Always run greps against the **raw** log, not a paraphrase.

#### Step 1. Filter ad-relevant lines (orient yourself)

```bash
grep -iE "(interstitial|rewarded|banner|mrec|applovin|MaxSdk|AppLovinSdk|ironsource|LevelPlaySDK|admob|metica|unity.?ads|loadAd|ad.load|Transitioning from|ad loaded|ad failed|Displayed|Hidden|Clicked|revenue|ReceivedReward|waterfall|mediation|floor_price|bidFloor|dynamicBidFloor|cpmFloor)" "$LOG" \
  > "./${LABEL}-filtered.txt"
wc -l "./${LABEL}-filtered.txt"
```

This is a hint file for your own use — the rest of Step-by-Step works against `$LOG`, not the filtered subset, because some signals (timestamps for inter-format parallelism) live in lines a narrow filter would drop.

#### Step 2. Stack inventory

```bash
# Primary mediation SDK & version
grep -iE "AppLovinSdk|MaxSdk\s+version|LevelPlaySDK\s+version|IronSourceSDK\s+version|UnityAds.*version" "$LOG" | head -10
# Installed adapter list (MAX prints this on init)
grep -iE "installed_mediation_adapters|adapter_name|Auto-initing adapter" "$LOG" | head -20
# Metica init line
grep -iE "MeticaSdk\.Initialize|\[Metica\].*[Ii]nitializ|Metica.*initialized" "$LOG" | head -5
# Metica config callback (group / userId / forced-holdout)
grep -iE "OnInitialized|SmartFloors|user.?group|forced.?holdout" "$LOG" | head -10
```

Read the output: confirm what mediation SDK is in use, the adapter set, and that Metica initialised cleanly with a config response. If `OnInitialized` / `SmartFloors` is missing, the user group is unknown — flag this in the report (the rest of the run is meaningful only if you know which side of the experiment the user landed on).

#### Step 3. Per-format extraction

For each format that appears in the log (interstitial, rewarded, banner, mrec — skip the ones that don't appear). The substeps below show interstitial; substitute `MaxRewardedAd` / `MaxBannerAd` / `MaxMRecAd` for the other formats.

##### 3.1. Ad unit IDs

```bash
grep -iE "MaxInterstitialAd.*Created|adUnitId.*[a-f0-9]{16,}" "$LOG" \
  | grep -v "isReady\|Listener\|setRevenue\|add_On" \
  | head -10
```

Some games use **two ad unit IDs per format** as a fallback / parallel-load pattern. List every unique ID, mark which ones see traffic.

##### 3.2. Lifecycle (load → ready/no-fill → show → hide → fail)

```bash
grep "MaxInterstitialAd" "$LOG" \
  | grep -iE "(loadAd|Transitioning|Handle ad loaded|ad loaded|ad failed)" \
  | grep -v "isReady\|setListener\|setRevenue\|add_On" \
  | head -40
```

Read the actual lines (don't just count). Tally:

- Load requests (`loadAd()`)
- Loaded / READY (`Transitioning from LOADING to READY`)
- No-fill / IDLE (`Transitioning from LOADING to IDLE`)
- Shows (`Transitioning from READY to SHOWING`)
- Hides (varies — `OnInterstitialHiddenEvent` or `Transitioning from SHOWING to IDLE`)
- Show failures (varies — `OnInterstitialAdFailedToDisplayEvent` or `OnAdShowFailed.*[Ii]nterstitial`)

Report the counts in the per-format Stats table. **Quote the lines as evidence** when something looks wrong (e.g. SHOWING that doesn't come from READY — IsReady wasn't checked).

##### 3.3. Display events — revenue + network per impression

```bash
grep -E "OnInterstitialDisplayedEvent|OnInterstitialHiddenEvent" "$LOG" | head -20
```

For each impression, MAX prints a `MaxAdInfo` blob with `networkName='…'`, `revenue=…`, `revenuePrecision='…'`. Extract those tuples (you may need a separate grep with `-oE` on the inner tokens). If revenue isn't logged at all, say so in the report — **don't fabricate values**.

##### 3.4. Reward sequencing (rewarded only)

```bash
grep -E "OnRewardedAdDisplayedEvent|OnRewardedAdHiddenEvent|OnRewardedAdReceivedRewardEvent|OnUserReceivedReward" "$LOG"
```

Confirm that for every Displayed → Hidden pair, a `ReceivedReward` fires **between** them. If a `Hidden` lands without a preceding `ReceivedReward`, the user got no reward — flag it in the report (this is a common Unity-side listener bug).

#### Step 4. Network attribution (which network wins each auction)

```bash
grep "Handle ad loaded" "$LOG" | grep -oE "networkName='[^']+'" | sort | uniq -c | sort -rn
```

Read the output: rank the networks by wins. A network that's installed (Step 2) but never wins is worth noting — it's adding init weight and bidding latency for no return.

#### Step 5. Metica → MAX floor handoff

```bash
grep -E "setLocalExtraParameter|setExtraParameter|dynamicBidFloor|dynamicKeyName|overrideBidFloor|cpmFloorAdUnitId" "$LOG" | head -30
```

For each format, find the **first** Metica floor-param call and the **first** `loadAd()` of that format. The floor must be set **before** the loadAd — otherwise the auction ran without it.

Also sanity-check the values: `dynamicBidFloor` should be a positive eCPM (typically `> 0` and `≤ ~100`). An out-of-range value (negative, zero, multi-thousand) means a unit-conversion bug somewhere.

#### Step 5.5. MAX → 3PA analytics forward rate (per provider)

Games forward each MAX ad-revenue event to one or more third-party analytics (3PA) providers. They all dispatch from the same Unity main-thread `OnAdRevenuePaid` handler, so they share one loss profile — measure each provider that appears in the log.

Detect which providers are present, then grep each one's forwarded-event signal:

| Provider | Forwarded-event signal to grep |
|---|---|
| Adjust | `Adjust  : Path:      /ad_revenue` (POST), then `Response message: Ad revenue tracked` |
| Firebase Analytics | `FirebaseAnalytics .* Logging event .* ad_impression` (game-fired `LogEvent`) |
| AppsFlyer | `AppsFlyer .* af_ad_revenue` or `af_inapp_ad_view` (depends on the game's chosen event name) |
| AppMetrica | `AppMetrica .* reportAdRevenue` or `Reporting ad revenue` (depends on integration) |

The MAX-side denominator is unchanged: `Invoking event: On(Interstitial|Banner|Rewarded|AppOpen)AdRevenuePaidEvent` (pure MAX), or `MaxAdRevenueListener.onAdRevenuePaid` on the Metica path.

For each detected provider, report **by format**:

- **MAX revenue events observed** (the denominator).
- **Forwarded events** that reached the provider's outbound SDK call.
- **Forward rate** = forwarded / MAX events (give the ratio **and** the lost count).
- **Dispatch latency** — median and max ms between the MAX event firing and the provider's forward call (same timestamp-diff technique as Step 6).
- **Lost / stalled at end of window** — MAX events with no matching forward by the end of the capture; pair by network + revenue value where possible.

A forward rate below 100% — especially clustered at the end of the window or around a click-through-no-return — points at the Unity main-thread dispatch dependency (`SynchronizationContext.Post`); quote the unmatched MAX events as evidence. If no 3PA provider appears, say so and skip this section.

#### Step 6. Load timing & strategy (timestamps)

Use the lifecycle lines from Step 3.2 (across all formats). Read the **timestamps** (Android threadtime: `MM-DD HH:MM:SS.sss`; iOS syslog: `Mon DD HH:MM:SS`).

**Timing metrics (per format, and per ad-unit when a format has two):**

- **Load count** — number of `loadAd()` requests; carry the Step 3.2 tallies into the Load Timing table.
- **Load response time** — for each `loadAd()`, find the next terminal transition for the same format/unit and diff the timestamps: `LOADING → READY` is a **fill** latency, `LOADING → IDLE` a **no-fill** latency. Report median + max ms for fills, and the no-fill latencies separately. Quote the slowest fill as evidence.
- **Time to first ad ready** — per format, the first `READY` timestamp minus a baseline: the Metica `OnInitialized` / config callback (Step 2) if present, else that format's first `loadAd()`. This is cold-start readiness; quote both timestamps.

**Strategy questions:**

- **Inter-format parallelism.** Do interstitial and rewarded `loadAd()` fire within a few hundred ms of each other at startup, or sequentially? Quote the two `loadAd()` lines as evidence.
- **Intra-format parallelism (dual unit).** If a format has two ad unit IDs, do both enter LOADING before either reaches READY? Quote the two LOADING transitions.
- **Post-dismiss reload latency.** For each `OnInterstitialHiddenEvent` (or equivalent), find the next `loadAd()` for the same format and diff the timestamps. Median <1 s → immediate reload; >5 s → either deferred or broken.

Cite actual timestamps in the report — don't just write "parallel". The number is the evidence.

#### Step 7. Errors & warnings

```bash
ERR='metica.*(error|exception|fail)|applovin.*error|MAX.*error|MaxSdk.*error|loadAd.*fail|sdk.*not initialized|invalid.*(api.?key|app.?id)|HTTP [45][0-9][0-9]|FATAL EXCEPTION'
grep -iE "$ERR" "$LOG" \
  | sed -E 's/^[A-Za-z]{3}[[:space:]]+[0-9]+[[:space:]]+[0-9:]+[[:space:]]+[^[:space:]]+[[:space:]]+//' \
  | sed -E 's/^[0-9-]+[[:space:]]+[0-9:.]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+[A-Z][[:space:]]+//' \
  | sort | uniq -c | sort -rn | head -30
```

Group by unique signature. For each, give the count, one example line, and your best read of the cause. Examples:

- `E/Metica: api_key invalid (401)` — bad/expired Metica key; all Metica behaviour downstream is meaningless
- `MAX: no fill` — environmental, usually fine
- `FATAL EXCEPTION` — crash; quote the stack and flag

#### Step 8. Write the report

Use the Write tool to create `./<label>-analysis.md` with the structure below. Substitute real values; **omit sections** (don't show "N/A") for any format that didn't appear at all in the log.

````markdown
# Ad Monetization Analysis — <label> (<platform>)

**Session:** <started_at>
**Source log:** `<log_file>` (<lines> lines)
**Filter file:** `./<label>-filtered.txt`

---

## Stack Overview

| Component | Details |
|---|---|
| Primary Mediation SDK | e.g. AppLovin MAX 12.6.0 |
| Metica SDK | e.g. 2.4.0, initialized cleanly |
| User group (from OnInitialized) | e.g. SmartFloors / forced-holdout / unknown |
| Active adapters (N total) | comma-separated list |

---

## Interstitial Ad Cycle

### Ad Unit IDs
- `<id1>` (saw traffic)
- `<id2>` (fallback, no traffic this session)

### Stats
| Metric | Value |
|---|---|
| Load requests | N |
| Successful loads (READY) | N |
| No-fill (IDLE) | N |
| Shows (impressions) | N |
| Show failures | N |
| Hidden | N |
| Fill rate (Loaded / Loads) | …% |
| Errors (this format) | N → see Errors & Warnings |

### Load Timing
| Metric | Value |
|---|---|
| Load response time — fill (median / max) | … ms / … ms |
| Load response time — no-fill (median / max) | … ms / … ms |
| Time to first ad ready (from init) | … ms |

### Load & Show Timeline
A short prose paragraph or bullet list with timestamped key events (first loadAd, first READY, first SHOWING, etc.) — your evidence trail for the strategy section below.

### Networks
| Network | Wins |
|---|---|
| ... | ... |

### Revenue per Impression
| Show # | Network | Revenue | Precision |
|---|---|---|---|
| 1 | ... | $0.0123 | publisher_defined |
| ... |

If revenue isn't logged in this build, say so explicitly here.

---

## Rewarded Ad Cycle

(same structure as Interstitial, plus:)

### Reward Sequencing
Confirm that every Displayed → Hidden pair carries a `ReceivedReward` between them. Quote the offending pair if not.

---

## Banner / MRec
(only if observed)

---

## Metica → MAX Floor Handoff

| Format | First floor-param set | First loadAd | Order |
|---|---|---|---|
| Interstitial | HH:MM:SS.sss `setLocalExtraParameter(...)` | HH:MM:SS.sss `loadAd()` | OK / FLAG |
| Rewarded | ... | ... | ... |

**Floor values observed:** range $X.XX – $Y.YY eCPM (or "out of range: …", or "no floors set this session").

---

## 3PA Analytics Forwarding
(only if a 3PA provider appears in the log)

| Provider | Format | MAX events | Forwarded | Forward rate | Lost | Dispatch latency (med / max) |
|---|---|---|---|---|---|---|
| Adjust | Interstitial | N | N | …% | N | … / … ms |
| … | … | … | … | … | … | … |

Note any events lost or stalled at the end of the capture window, and whether the loss pattern points at the Unity main-thread dispatch dependency.

---

## Ad Load Strategy

### Inter-format
**Parallel** or **Sequential** — evidence (timestamps of first interstitial loadAd vs first rewarded loadAd)

### Intra-format (dual ad units)
**Parallel** or **Single unit** — evidence

### Post-dismiss reload
**Immediate** (median Nms) or **Delayed** (median Nms) — evidence

### Summary
| Dimension | Strategy |
|---|---|
| Interstitial vs Rewarded | ... |
| Dual ad units (same format) | ... |
| Post-dismiss reload | ... |

---

## Errors & Warnings

| Count | Signature | Interpretation |
|---|---|---|
| N | (one-line) | (one-line) |

---

## Key Observations

Numbered list. Surface anything worth a human's attention — broken reward sequencing, networks that never win, suspicious reload latency, missing floor params, trial-only crashes. Be specific; cite line numbers or timestamps.
````

Once the file is written, summarise to the user: which formats appeared, headline findings, and whether they should run the second route now (if this was the first capture) or proceed to Phase 3 (if both routes are present).

---

## Phase 3 — compare trial vs holdout

**Entirely prose. No script.** You read both per-route analyses + both raw logs and reason.

### 1. Read both per-route analyses

`./holdout-user-analysis.md` and `./trial-user-analysis.md` (or whatever labels the user picked). These contain the per-format stats, networks, revenue, floor handoff, load strategy, and errors that Phase 2b produced. **If a `./baseline-analysis.md` (or the user's baseline label) also exists, read it too** — it feeds the fidelity check in Step 3a, not the trial-vs-holdout verdict.

### 2. Build the side-by-side delta table (per format observed in either run)

| Metric | Holdout | Trial | Δ | Baseline |
|---|---|---|---|---|
| Load requests | … | … | … | … |
| Fill rate (Loaded / Loads) | …% | …% | … | …% |
| Show rate (Shows / Loaded) | …% | …% | … | …% |
| Avg revenue per impression | $… | $… | … | $… |
| Reload latency (median Hidden→next loadAd) | …ms | …ms | … | …ms |
| Load response time (median fill) | …ms | …ms | … | …ms |
| Time to first ad ready | …ms | …ms | … | …ms |
| Errors (count) | … | … | … | … |
| 3PA forward rate — `<provider>` | …% | …% | … | …% |
| 3PA dispatch latency — `<provider>` (median) | …ms | …ms | … | …ms |
| Top winning network | … | … | … | … |

The `Δ` column is **trial vs holdout** — that is the comparison. *Include the `Baseline` column only when a baseline route was captured; otherwise drop it.* If a metric isn't available for one of the routes (e.g. revenue wasn't logged in this build), say so — don't fabricate.

### 2a. Baseline fidelity check (only when a baseline route exists)

The baseline is the **production store build** — a different build from the dev holdout/trial (store signing, possibly a different app version, likely no Metica). It is a context anchor, **not** a control arm. Use it to answer one question: *does the holdout dev-build reproduce production?*

- If holdout's fill rate / top networks / revenue-per-impression **track** the baseline → the harness is faithful; trust the trial-vs-holdout verdict.
- If holdout **diverges sharply** from baseline → **FLAG it as a build/harness concern, not a Metica effect**: the holdout dev-build isn't reproducing production, so the A/B comparison rests on a shaky control. Recommend reconciling the holdout build with production before believing the numbers.
- Always caveat that baseline gaps can be **build/version differences** (different app version, store vs sideloaded, no Metica) rather than real behavioral deltas. Never let a baseline number flip the trial-vs-holdout verdict.

### 3. Apply verdict rules (prose)

- `trial revenue/impression < holdout revenue/impression` per format → **FLAG**. Hypothesis: Metica's floor is suppressing fills holdout would have won.
- `trial fill rate < holdout fill rate` materially → **FLAG**. Floor priced too high.
- `trial fill rate < holdout` AND `trial revenue/impression > holdout` → *expected Metica tradeoff* (fewer fills, higher prices). **Note, don't flag.**
- Trial-only lifecycle anomalies (show without ready, reload latency >5s, missing reward callback) → **FLAG**. A regression in the runtime ad logic itself, independent of bid economics.
- `trial load response time` or `time to first ad ready` materially worse than holdout, or `trial fill rate < holdout` → **FLAG**. A loading regression, not bid economics.
- `trial 3PA forward rate < holdout` for any provider → **FLAG**. All forwarders share the Unity main-thread dispatch surface, so a trial-only drop signals the wrapper-architecture asymmetry — analytics under-reporting independent of revenue.
- Trial-only errors (next section) → **FLAG**.

### 4. Error diff (cross-route)

Grep both raw logs for Metica / AppLovin error signatures (same regex as Phase 2b Step 7). Group by signature and split into three buckets:

- **Trial-only errors** — most actionable. Surface signature + one example line + your best read of the cause. Example: *"`E/Metica: api_key invalid (401)` × 12 in trial, 0 in holdout — the trial build's Metica API key is bad. All trial metrics are effectively a second holdout run; rerun with a working key before drawing conclusions."*
- **Both-route errors** — usually environmental (no fill, transient network). Note, don't flag.
- **Holdout-only errors** — rare. Flag because it means the non-Metica codepath has a regression independent of Metica.

### 5. The n=5 caveat (mandatory in the verdict prose)

Five ads per format is enough to catch *directional* problems — no fill, broken init, trial-only errors, broken reload loops — but is **below the noise floor for revenue claims**. Always include in the verdict:

> "At n=5 per format, a 20% revenue gap is inside variance. Treat this as a smoke test; escalate to a longer run before declaring an A/B winner."

Without this caveat, QA will quote the numbers as if they were a real A/B result.

### 6. Write the comparison report

Write a single Markdown file `./compare-<trial-label>-vs-<holdout-label>.md` (default: `./compare-trial-vs-holdout.md`) using the Write tool. Structure:

- **Headline verdict** — one paragraph: PASS / FLAGGED + the n=5 caveat. The verdict is trial vs holdout; if a baseline was captured, state in one line whether the holdout looked faithful to production.
- **Side-by-side delta table** (Step 2 above) — include the `Baseline` column only if that route was captured.
- **Baseline fidelity** (only when baseline captured) — the Step 2a finding: does holdout track production, or is the control suspect? With the build-difference caveat.
- **Section-by-section diff** — call out which Phase 2b sections differ between routes that matter (load strategy changes, reload latency regression, floor handoff misalignment, etc.).
- **Cross-route errors** — trial-only / both / holdout-only with one-line interpretation per signature.
- **Recommended follow-up** — concrete next steps (e.g. "rerun with a working API key", "extend the run to 30 impressions per format", "investigate Metica.OnAdShowFailed handler in trial build").

---

## What you do NOT do

- **Do not** invent metrics that aren't in the log (revenue values, network names, floor prices) — say "not observed in this session" and move on.
- **Do not** declare a revenue winner on n=5. Always include the caveat.
- **Do not** edit any game code. This skill is read-only against the device log + working directory. Code changes are the integrator's / developer's job after the human reads your verdict.
- **Do not** delete the raw log files or per-route reports as part of Phase 3 — the human may want to keep them as evidence.
- **Do not** turn the analysis into a deterministic grep-and-count script. Log shape varies between games / SDK versions; counts on their own are evidence, not verdict. Always quote actual lines / timestamps.

## Conventions

- All output files (logs, session, filter file, per-route reports, comparison report) live in the **current working directory** — never in `/tmp`. Multiple captures coexist in the same folder by label and timestamp.
- File names: `./<label>-<platform>-<YYYYMMDDThhmmssZ>.log` (capture; timestamp is UTC, embedded by start.sh so re-running with the same label doesn't clobber a previous log), `./<label>.session` (one in flight per label at a time), `./<label>-filtered.txt`, `./<label>-analysis.md`, `./compare-<trial-label>-vs-<holdout-label>.md`. The session file always carries the exact `log_file` path, so the skill reads the real path from there — never reconstructs it from `<label>-<platform>.log`.
- All output is human-readable Markdown. This skill does **not** emit JSON to an orchestrator.
