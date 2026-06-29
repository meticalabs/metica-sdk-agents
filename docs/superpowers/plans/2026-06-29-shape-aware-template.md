# Shape-Aware MeticaAdService Template — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the generated `MeticaAdService.cs` adapt to the host project's code shape (MonoBehaviour / static class / plain class) instead of being hard-coded as a MonoBehaviour. Delete the integrator rule that strips init-area calls from wrapper files. Warn users in the Step 7 report when wrapper files leave `MaxSdkCallbacks` subscriptions live. Closes MET-11820.

**Architecture:** The single template at `scripts/templates/standalone/MeticaAdService.cs.tmpl` gets four substitution tokens (`__CLASS_HEADER__`, `__START_HOOK__`, `__FOCUS_HOOK__`, `__STATIC__`) whose values are picked per shape. The integrator's Step 3 (plan mode) asks the user to confirm the shape — defaulting to a heuristic-suggested shape based on the host's observed ad code. Step 5 (codegen) substitutes the tokens. Step 7 (final report) adapts its attach/init walkthrough per shape and lists any wrapper `MaxSdkCallbacks` subscription sites with a double-firing warning. The "Exception inside wrappers" rule at `agents/unity-integrator.md:453` is deleted — wrapper-scoping becomes absolute (no per-call rewrites inside wrapper files).

**Tech Stack:** Markdown agent prompts, C# template file, JSON plugin manifests.

## Global Constraints

- **Plugin version bumped exactly once per PR**, lockstep across `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` (per CLAUDE.md). SemVer **minor**: new agent behavior, backward-compatible (default shape stays MonoBehaviour for existing hosts).
- **Never edit files under `Assets/MaxSdk/`** (per CLAUDE.md). Reinforced by the absolute wrapper-scoping rule established in Task 2.
- **Keep agent instructions positive** — describe current behavior, don't narrate removed behavior. After deleting the "Exception inside wrappers" paragraph in Task 2, the surrounding prose must read as "rewrite only scene/game-logic files; never modify wrapper-file contents" without any reference to a prior exception.
- **No new test infrastructure** — verification is manual per task (render the template by substituting each shape; read surrounding agent prose for context coherence). Adding a new `tests/run-*.sh` suite is out of scope.
- **Default shape stays MonoBehaviour** — projects that don't observe a different host shape (the docs.metica.com demo case) continue to receive today's output verbatim.

---

## File Structure

Files modified by this PR:

- **`scripts/templates/standalone/MeticaAdService.cs.tmpl`** — add the four substitution tokens; mark state fields and methods with `__STATIC__` so they become `static` under the `static class` shape.
- **`agents/unity-integrator.md`** — four prose edits:
  - **Step 3 (plan mode)**: add the shape question with heuristic-defaulted suggestion.
  - **Step 5 (codegen)**: extend the existing template-substitution prose to cover the new tokens and shape-driven values.
  - **Step 5 (wrapper-scoping rule)**: delete the "Exception inside wrappers" paragraph at line 453; tighten the surrounding rule to "never modify wrapper-file contents."
  - **Step 7 (final report)**: add a shape-tailored attach/init walkthrough block; add a wrapper-`MaxSdkCallbacks` listing block with double-firing warning.
- **`.claude-plugin/plugin.json`** — bump `version` (minor).
- **`.claude-plugin/marketplace.json`** — bump `metadata.version` (lockstep).

No new files. No new tests. No new scripts.

---

## Task 1: Parameterize `MeticaAdService.cs.tmpl` for three shapes

**Files:**
- Modify: `scripts/templates/standalone/MeticaAdService.cs.tmpl`

**Interfaces:**
- Produces: four new template tokens (`__CLASS_HEADER__`, `__START_HOOK__`, `__FOCUS_HOOK__`, `__STATIC__`) consumed by Task 4's codegen substitution.

**Token substitution values:**

| Token | `monobehaviour` | `static_class` | `plain_class` |
|---|---|---|---|
| `__CLASS_HEADER__` | `class MeticaAdService : MonoBehaviour` | `static class MeticaAdService` | `class MeticaAdService` |
| `__START_HOOK__` | `void Start() => Initialize();` | (empty line) | (empty line) |
| `__FOCUS_HOOK__` | the current `private void OnApplicationFocus(...)` block (lines 59-68 of today's template) | (empty) | (empty) |
| `__STATIC__` | (empty) | `static ` | (empty) |

- [ ] **Step 1.1: Replace the class declaration line**

Current (line 18):
```csharp
public class MeticaAdService : MonoBehaviour
```

After:
```csharp
public __CLASS_HEADER__
```

- [ ] **Step 1.2: Replace the `Start()` line with the token**

Current (line 22):
```csharp
    void Start() => Initialize();
```

After:
```csharp
    __START_HOOK__
```

- [ ] **Step 1.3: Wrap the `OnApplicationFocus` block in the token**

Current (lines 59-68):
```csharp
    // Pause/resume the persistent formats with app focus (no-op for the others).
    private void OnApplicationFocus(bool hasFocus)
    {
        // @fmt-begin:banner
        BannerOnFocus(hasFocus);
        // @fmt-end:banner
        // @fmt-begin:mrec
        MrecOnFocus(hasFocus);
        // @fmt-end:mrec
    }
```

After:
```csharp
    __FOCUS_HOOK__
```

(Codegen will substitute the entire current block under MonoBehaviour shape, or an empty string under the other shapes.)

- [ ] **Step 1.4: Prefix every state field and method with `__STATIC__`**

Apply `__STATIC__` before each field and method declaration in the template so they conditionally become `static` under the static-class shape. Examples:

```csharp
private bool _initialized = false;
```
→
```csharp
private __STATIC__bool _initialized = false;
```

```csharp
public void Initialize()
```
→
```csharp
public __STATIC__void Initialize()
```

Apply uniformly to every `private`, `public`, `protected` field and method declaration inside the class body. Do NOT apply to the class header itself (that's `__CLASS_HEADER__`'s job). Do NOT apply to local variables (`var config = …;`).

Use a Read pass over the template to enumerate every field/method declaration, then apply the `__STATIC__` prefix with `Edit` per declaration. Expect roughly 30-40 declarations to touch (one per format region × 4 formats + the common init/callback declarations).

- [ ] **Step 1.5: Manually render and inspect each shape**

For each of the three shapes, mentally (or via a one-off `sed`) substitute the four tokens and read the result. Sanity check:

```bash
# MonoBehaviour shape — verify it matches today's output verbatim (modulo the new __MEDIATION__/__USER_ID__ tokens that already existed)
sed \
  -e 's/__CLASS_HEADER__/class MeticaAdService : MonoBehaviour/' \
  -e 's|__START_HOOK__|void Start() => Initialize();|' \
  -e 's|__STATIC__||g' \
  scripts/templates/standalone/MeticaAdService.cs.tmpl | head -25
```

Expected MonoBehaviour render: identical to today's template (the `__FOCUS_HOOK__` substitution carries the existing block verbatim under MonoBehaviour).

```bash
# Static class shape — verify the class is `static`, no Start(), no OnApplicationFocus, all members `static`
sed \
  -e 's/__CLASS_HEADER__/static class MeticaAdService/' \
  -e 's|__START_HOOK__||' \
  -e 's|__FOCUS_HOOK__||' \
  -e 's|__STATIC__|static |g' \
  scripts/templates/standalone/MeticaAdService.cs.tmpl | head -25
```

Expected static render: `public static class MeticaAdService { private static bool _initialized = false; public static void Initialize() { … } }` — no MonoBehaviour-specific hooks.

Both renders should have balanced braces (`grep -c '^{' = grep -c '^}'`) and zero leftover `__` placeholder tokens.

- [ ] **Step 1.6: Commit the template changes**

```bash
git add scripts/templates/standalone/MeticaAdService.cs.tmpl
git commit -m "$(cat <<'EOF'
template: parameterize MeticaAdService for three host shapes

Add __CLASS_HEADER__ / __START_HOOK__ / __FOCUS_HOOK__ / __STATIC__ tokens
so codegen can render the template as a MonoBehaviour, a static class, or
a plain class. Default substitution preserves today's MonoBehaviour shape
verbatim. Used by integrator Step 5 (Task 4 in this PR).

Refs MET-11820 (#1).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Delete the "Exception inside wrappers" rule

**Files:**
- Modify: `agents/unity-integrator.md`

**Interfaces:**
- Produces: the wrapper-scoping rule becomes absolute — no per-call rewrites inside wrapper files. This invariant is relied on by Task 5's Step 7 listing (wrapper subscriptions are guaranteed untouched, so the listing has stable content to enumerate).

- [ ] **Step 2.1: Read the current paragraph and its neighbors**

```bash
sed -n '447,460p' agents/unity-integrator.md
```

Expected: lines 449-451 are the wrapper-scoping rule, line 453 is the "Exception inside wrappers" paragraph, line 455 is the MaxSdkUtils-exempt rule.

- [ ] **Step 2.2: Delete the "Exception inside wrappers" paragraph**

The paragraph to delete starts with `**Exception inside wrappers: per-call-site rewrites still apply.**` and is one paragraph long. Use Edit with the exact paragraph as `old_string` and an empty string as `new_string`. Verify only that paragraph is deleted — the surrounding wrapper-scoping rule (line 451) and `MaxSdkUtils` exempt rule (line 455) remain.

- [ ] **Step 2.3: Tighten the wrapper-scoping rule's prose**

The rule at line 451 today reads:

> If a wrapper exists and the game routes through it, leave the wrapper's *shape* intact and rewrite the game's call sites to **bypass** it and call `MeticaAdService` directly. The orphaned wrapper is the game owner's to delete later — the integrator does not own that decision.

Update the prose to make absolute: replace "leave the wrapper's *shape* intact" with "leave the wrapper file untouched". Use Edit on the exact substring.

Before:
```
leave the wrapper's *shape* intact and rewrite the game's call sites to **bypass** it
```

After:
```
leave the wrapper file untouched and rewrite the game's call sites to **bypass** it
```

- [ ] **Step 2.4: Read 30 lines of surrounding context to confirm coherence**

```bash
sed -n '440,470p' agents/unity-integrator.md
```

Expected: no dangling references to "the exception inside wrappers" / "per-call-site rewrites still apply" / "Set*ExtraParameter rewrites" anywhere downstream. If a reference exists elsewhere in the file (search with `grep -n 'Exception inside wrappers\|per-call-site rewrites still' agents/unity-integrator.md`), remove or rephrase it.

- [ ] **Step 2.5: Verify no other file references the deleted rule**

```bash
grep -rn 'Exception inside wrappers\|per-call-site rewrites still apply' .
```

Expected: no matches. If matches exist in `agents/contracts.md`, `agents/unity-validator.md`, or `references/`, update them to reflect the absolute scoping rule (no per-call exceptions inside wrappers).

- [ ] **Step 2.6: Commit**

```bash
git add agents/unity-integrator.md
git commit -m "$(cat <<'EOF'
integrator: make wrapper-scoping absolute — no per-call rewrites in wrappers

Delete the "Exception inside wrappers" paragraph at integrator.md:453.
Wrapper files are now never modified by the integrator. The exception
stripped MaxSdk.InitializeSdk() from wrapper-file Initialize methods
without replacing it, breaking the parent ad framework's init chain
(MET-11820 issue #4).

Tighten the surrounding wrapper-scoping rule prose to "leave the wrapper
file untouched" — previously "leave the wrapper's shape intact" was
ambiguous about whether per-call rewrites were allowed inside.

Refs MET-11820 (#4).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Add shape question to Step 3 (plan mode)

**Files:**
- Modify: `agents/unity-integrator.md`

**Interfaces:**
- Consumes: nothing from earlier tasks (this is the user-facing decision point).
- Produces: a `SHAPE` value (one of `monobehaviour`, `static_class`, `plain_class`) consumed by Task 4's codegen substitution.

- [ ] **Step 3.1: Read the current Step 3 structure**

```bash
sed -n '350,400p' agents/unity-integrator.md
```

Identify where the Tier 2 "Confirm these inferences" block ends and where to insert the shape question. The shape question goes inside Tier 2 because it's an inferred default the user must confirm — same character as the `wrapper`, `namespace`, `userId` lines already there.

- [ ] **Step 3.2: Add shape-suggestion heuristic prose to Step 2.5 (Discovery)**

The shape suggestion is computed during discovery, then surfaced in Step 3. Add a new sub-section to Step 2.5 of `agents/unity-integrator.md` after the namespace_dominant signal (around line 312):

```markdown
#### Signal 4 — `host_ad_shape` (suggested template shape)

Look at the host's ad-related `.cs` files (any file in 1a's Max-touching
inventory, or — when Max is absent — files matching `*Ad*.cs` / `*Ads*.cs` /
`*Mediation*.cs` in `Assets/Scripts/`). For each, classify by class shape:
- `MonoBehaviour` — declares `: MonoBehaviour` (directly or transitively).
- `static class` — declared `static class`.
- `plain class` — instantiable class, no MonoBehaviour, no `static`.

Count by shape; the **majority shape** becomes the suggested default for
`MeticaAdService`. If there's a tie or no ad files exist, default to
`MonoBehaviour` (matches docs.metica.com demo and is reachable from any
scene).

Record under `Host ad shape` in the discovery block:

    Host ad shape (majority): static class (4 of 5 ad files static, 1 MonoBehaviour)
    Suggested MeticaAdService shape: static_class

The user confirms or overrides this suggestion in the Step 3 plan.
```

- [ ] **Step 3.3: Add the shape line to Step 3's Tier 2 inferences block**

In Step 3's Tier 2 "Confirm these inferences" prose, add a `shape` line after `userId`. Find the current block (around line 366):

```markdown
Confirm these inferences:
  - wrapper        = Assets/Scripts/Ads/AdManager.cs   (public API: ShowInterstitial(string), ShowRewarded(string, Action))
  - namespace      = Game.Ads.Metica                   (AdManager.cs's namespace + .Metica)
  - adapter folder = Assets/Scripts/Ads/Metica/        (next to the wrapper)
  - userId         = <ASK NOW — see below>
```

Append:

```markdown
  - shape          = <static_class | monobehaviour | plain_class>   (suggested from host's ad code; see Step 2.5 Signal 4)
```

- [ ] **Step 3.4: Add the shape-collection prompt below the userId prompt**

After the `userId is currently unset (defaults to null)…` prompt block (around line 386), add a parallel prompt for shape:

```markdown
**Confirm `SHAPE`.** The integrator suggests `<suggested_shape>` based on
the host's ad code (Step 2.5 Signal 4). Override if the suggestion doesn't
fit how your project drives ads:

  [a] monobehaviour  — attach to a GameObject; Start() auto-initializes
  [b] static_class   — host calls MeticaAdService.Initialize() explicitly
  [c] plain_class    — host constructs `new MeticaAdService()` and calls Initialize()

Choose [a/b/c] or accept the suggestion:
```

Bake the chosen value into `SHAPE` (an env-var-like variable) before codegen, the way `USER_ID_EXPR` is collected today.

- [ ] **Step 3.5: Re-read the modified Step 3 to confirm flow**

```bash
sed -n '350,410p' agents/unity-integrator.md
```

Expected: the `shape` line sits alongside the other inferences; the shape-collection prompt parallels the `userId` prompt; nothing else in Step 3 was disturbed.

- [ ] **Step 3.6: Commit**

```bash
git add agents/unity-integrator.md
git commit -m "$(cat <<'EOF'
integrator: ask for MeticaAdService shape in Step 3 plan mode

Add a Step 2.5 'host_ad_shape' signal that counts MonoBehaviour vs
static class vs plain class across the host's ad-related .cs files,
and a Step 3 prompt that surfaces the suggested shape and lets the
user override.

Default behavior preserved: when the host has no observable ad code
or a MonoBehaviour majority, MonoBehaviour stays the default. The
SHAPE value is consumed by Step 5 codegen (next task).

Refs MET-11820 (#1).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Step 5 codegen — substitute the shape tokens

**Files:**
- Modify: `agents/unity-integrator.md`

**Interfaces:**
- Consumes: `SHAPE` from Task 3; the four shape tokens defined in Task 1's template.
- Produces: nothing new for later tasks; this completes the codegen path.

- [ ] **Step 4.1: Locate the current template-substitution prose**

```bash
sed -n '560,595p' agents/unity-integrator.md
```

Today Step 5 substitutes `__METICA_API_KEY__` / `__METICA_APP_ID__` / `__USER_ID__` / `__MEDIATION__` and drops `@fmt-begin/@fmt-end` regions per `$FORMATS`. The new substitution adds four more tokens.

- [ ] **Step 4.2: Add the SHAPE input to Step 5's input block**

In the input-resolution bash block (around line 550), add `SHAPE`:

```bash
SHAPE="${SHAPE:?required from Step 3}"          # monobehaviour | static_class | plain_class
```

(`:?required from Step 3` causes the script to fail loudly if Task 3's prompt was skipped — a forcing function so codegen can't accidentally fall through with no shape selected.)

- [ ] **Step 4.3: Extend the substitution prose**

Find the prose that lists the template's substitution tokens (around line 565). Today it reads:

```markdown
**`MeticaAdService.cs`** — render `$PLUGIN_DIR/scripts/templates/standalone/MeticaAdService.cs.tmpl`: apply the namespace transform (below), **drop the `// @fmt-begin:<fmt>`…`// @fmt-end:<fmt>` region for every format NOT in `$FORMATS`**, and substitute `__METICA_API_KEY__` / `__METICA_APP_ID__` (escaped as above), `__USER_ID__` (verbatim), and `__MEDIATION__` → ...
```

Add the four new tokens to the substitution list with a small table of their per-shape values:

```markdown
Also substitute the four shape tokens based on `$SHAPE` (collected in Step 3):

| Token | `monobehaviour` | `static_class` | `plain_class` |
|---|---|---|---|
| `__CLASS_HEADER__` | `class MeticaAdService : MonoBehaviour` | `static class MeticaAdService` | `class MeticaAdService` |
| `__START_HOOK__` | `void Start() => Initialize();` | (empty) | (empty) |
| `__FOCUS_HOOK__` | the canonical `private void OnApplicationFocus(...)` block with banner/mrec focus dispatch | (empty) | (empty) |
| `__STATIC__` | (empty) | `static ` | (empty) |

For `__FOCUS_HOOK__` under `monobehaviour`, emit the block verbatim:

    private void OnApplicationFocus(bool hasFocus)
    {
        // @fmt-begin:banner
        BannerOnFocus(hasFocus);
        // @fmt-end:banner
        // @fmt-begin:mrec
        MrecOnFocus(hasFocus);
        // @fmt-end:mrec
    }

Under `static_class` / `plain_class`, substitute an empty string — the host
wires its own focus handling and calls `MeticaAdService.BannerOnFocus(...)`
/ `MrecOnFocus(...)` from there.
```

- [ ] **Step 4.4: Verify the substitution preserves @fmt-region dropping**

The existing `@fmt-begin:<fmt>` / `@fmt-end:<fmt>` region drop logic must still apply *after* the shape substitutions, since `__FOCUS_HOOK__`'s MonoBehaviour value contains its own `@fmt-begin/@fmt-end` markers (banner, mrec). Add a one-line note in the substitution prose:

```markdown
Apply the shape-token substitution **before** the @fmt-region drop pass —
the MonoBehaviour `__FOCUS_HOOK__` value carries its own @fmt-begin/@fmt-end
markers that must be evaluated against `$FORMATS` in the existing drop pass.
```

- [ ] **Step 4.5: Commit**

```bash
git add agents/unity-integrator.md
git commit -m "$(cat <<'EOF'
integrator: substitute shape tokens during Step 5 codegen

Extend the template-substitution prose so codegen renders the four shape
tokens (__CLASS_HEADER__, __START_HOOK__, __FOCUS_HOOK__, __STATIC__) per
the SHAPE value collected in Step 3. Order-dependent: shape substitution
runs before the existing @fmt-region drop pass (MonoBehaviour's focus hook
carries its own @fmt markers).

Refs MET-11820 (#1).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Step 7 — shape-tailored attach/init walkthrough

**Files:**
- Modify: `agents/unity-integrator.md`

**Interfaces:**
- Consumes: `SHAPE` from Task 3.
- Produces: nothing for later tasks.

- [ ] **Step 5.1: Locate Step 7's current attach/init prose**

```bash
grep -n '^### Step 7\|attach\|first scene\|gameObject.AddComponent' agents/unity-integrator.md | head -20
```

Step 7 is the final report assembled after codegen + validation. Today the attach guidance is implicit (the user is expected to know to attach the MonoBehaviour). Make it explicit and shape-tailored.

- [ ] **Step 5.2: Add the shape-tailored walkthrough block**

Insert a new sub-section in Step 7 (the final report) titled `Wiring MeticaAdService into your project`. Render different content per `$SHAPE`:

```markdown
#### Wiring MeticaAdService into your project

Show the user the exact attach/init steps for their chosen shape:

**`SHAPE=monobehaviour`** (the default):
```
Open your bootstrap scene (first scene loaded; check Project Settings →
Player → Default Scene).
  1. Create an empty GameObject named `MeticaAds`.
  2. Add the MeticaAdService component to it.
  3. (Optional) Mark DontDestroyOnLoad if you reload scenes — Initialize()
     is idempotent so re-Start() in a new scene also works.

That's the entire wiring. Start() calls Initialize() automatically.
```

**`SHAPE=static_class`:**
```
MeticaAdService is a static class — call Initialize() once from your
bootstrap. For example, from your existing static ad-manager:

  public static class AdsManager
  {
      public static void Init()
      {
          // ... your existing setup ...
          MeticaAdService.Initialize();
      }
  }

For banner/mrec focus pause/resume (only relevant if you use those
formats), call MeticaAdService.BannerOnFocus(hasFocus) and
MeticaAdService.MrecOnFocus(hasFocus) from your own
OnApplicationFocus handler somewhere in your game (typically a
persistent MonoBehaviour or Unity application-focus event hook).
```

**`SHAPE=plain_class`:**
```
Construct one MeticaAdService instance in your bootstrap, store it
(singleton / DI container / static field), and call Initialize():

  public class AdsManager
  {
      private MeticaAdService _metica;
      public void Init()
      {
          _metica = new MeticaAdService();
          _metica.Initialize();
      }
      public void Show() => _metica.ShowInterstitial("level_end");
  }

For banner/mrec focus pause/resume (only if you use those formats), call
_metica.BannerOnFocus(hasFocus) / _metica.MrecOnFocus(hasFocus) from your
own OnApplicationFocus handler.
```

Pick the block matching `$SHAPE` and emit only that one in the final report.
```

- [ ] **Step 5.3: Verify Step 7's overall flow still reads coherently**

```bash
sed -n '720,800p' agents/unity-integrator.md
```

Confirm the new sub-section sits naturally alongside the existing Step 7 content (orphaned-Max note, 3PA forwarder advisory, cohort-gating recipe). The new sub-section should appear early in Step 7 — first thing the user needs after codegen is "how to actually wire this in."

- [ ] **Step 5.4: Commit**

```bash
git add agents/unity-integrator.md
git commit -m "$(cat <<'EOF'
integrator: shape-tailored attach/init walkthrough in Step 7 report

Add a "Wiring MeticaAdService into your project" sub-section to Step 7
that renders one of three concrete attach/init walkthroughs based on
SHAPE: MonoBehaviour attach-to-scene, static-class call-Initialize-from-
bootstrap, or plain-class construct-and-store. Includes focus-handler
guidance for banner/mrec under non-MonoBehaviour shapes.

Refs MET-11820 (#1).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Step 7 — wrapper `MaxSdkCallbacks` listing + double-firing warning

**Files:**
- Modify: `agents/unity-integrator.md`

**Interfaces:**
- Consumes: the Step 2 discovery's `Max-touching file inventory` (the integrator already lists wrapper files; this task just enumerates their callback subscription lines).

- [ ] **Step 6.1: Identify where to insert the warning**

The warning belongs in Step 7's final report, immediately after the "orphaned Max" note (today around line 791 of integrator.md). It's the inverse direction: the orphaned-Max note tells the user the wrapper is unused; the new warning tells them which parts of the wrapper *might still be active* if their routing leaves the Max chain reachable.

- [ ] **Step 6.2: Add the listing block**

Insert in Step 7's final report:

```markdown
#### Wrapper `MaxSdkCallbacks` subscription sites (verify your routing gates them)

When a wrapper was left untouched (per the absolute wrapper-scoping rule),
its `MaxSdkCallbacks.<Format>.On*Event +=` subscriptions stay live. When
MeticaSDK runs MAX under the hood (`MeticaMediationInfo(MAX, ...)`), the
underlying `AppLovinSdk` instance fires events for *every* loaded ad —
including Metica-driven loads under a trial-routed user — so these
subscriptions fire on every ad event.

Effect if your routing doesn't gate the wrapper off:
  • Analytics in the wrapper's handlers run TWICE (once via the wrapper,
    once via Metica's handlers).
  • Custom retry loops in the wrapper compete with MeticaSDK's built-in
    exp-backoff retry.
  • State flags (`_isLoading` / `_lastShownAt`) become stale relative to
    MeticaSDK's actual ad lifecycle.

List the subscription sites the user should be aware of (one bullet per
match found in Step 2 discovery's Max-touching inventory):

  • <wrapper-file>:<line>  MaxSdkCallbacks.<Format>.<OnXxxEvent> += <Handler>

Then add this guidance:

  Either:
  (a) Ensure your routing layer keeps the wrapper unreachable when running
      the Metica chain (the recommended path — your cohort-gate decides
      which AdNetwork to construct; only one chain is alive per user); or
  (b) Manually unsubscribe these handlers when switching to the Metica
      chain (only if both chains can be live simultaneously, which is
      uncommon).
```

- [ ] **Step 6.3: Ensure the listing block is only emitted when a wrapper exists**

Add a one-line conditional at the start of the sub-section:

```markdown
This block applies only when Step 2 discovery found a Max wrapper. If
discovery returned `Max wrapper: none`, skip this section.
```

- [ ] **Step 6.4: Cross-check related references**

```bash
grep -n 'MaxSdkCallbacks\|wrapper.*untouched\|orphaned' agents/unity-integrator.md
```

Confirm the new sub-section reads consistently with existing prose (no contradiction with the orphaned-Max note).

- [ ] **Step 6.5: Commit**

```bash
git add agents/unity-integrator.md
git commit -m "$(cat <<'EOF'
integrator: Step 7 warns about live MaxSdkCallbacks in untouched wrappers

When a wrapper is left untouched per the absolute wrapper-scoping rule,
its MaxSdkCallbacks.*.On*Event subscriptions stay live. MeticaSDK's MAX
mediation makes them fire on every ad event — including Metica-driven
loads under trial-routed users.

Add a Step 7 final-report sub-section that lists each wrapper subscription
site (from Step 2 discovery inventory), explains the double-firing risk,
and points the user at routing-layer gating or manual unsubscription.

Catches MET-11820 issue #2 at report time. Only emitted when a wrapper
was detected — projects without a wrapper skip the section.

Refs MET-11820 (#2).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Version bump + final smoke

**Files:**
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 7.1: Read both manifests to confirm current version**

```bash
grep '"version"' .claude-plugin/plugin.json
grep '"version"' .claude-plugin/marketplace.json
```

Expected: both show the same version (e.g., `2.6.0`).

- [ ] **Step 7.2: Bump both to the next minor**

If current is `2.6.0`, bump to `2.7.0`. Apply lockstep.

```bash
# plugin.json — only line touching is the top-level "version"
sed -i.bak 's/"version": *"2\.6\.0"/"version": "2.7.0"/' .claude-plugin/plugin.json && rm .claude-plugin/plugin.json.bak
# marketplace.json — the version lives under metadata.version
sed -i.bak 's/"version": *"2\.6\.0"/"version": "2.7.0"/' .claude-plugin/marketplace.json && rm .claude-plugin/marketplace.json.bak
```

(Adjust the version strings if current is not `2.6.0` — read first, then bump.)

- [ ] **Step 7.3: Verify both files updated, identical version**

```bash
grep '"version"' .claude-plugin/plugin.json .claude-plugin/marketplace.json
```

Expected: both show the new version. CLAUDE.md mandates they stay lockstep.

- [ ] **Step 7.4: Run the existing test suite to confirm nothing regressed**

```bash
bash tests/run-all.sh
```

Expected: `ALL GREEN`. The existing five suites cover scripts (resolver, download, compile, update-check, log-monitor) — none of them touch the template or agent prose, so they should pass unchanged. If anything fails, debug before continuing.

- [ ] **Step 7.5: Commit**

```bash
git add .claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "$(cat <<'EOF'
release: bump plugin to 2.7.0 — shape-aware MeticaAdService template

Closes MET-11820:
  #1 MonoBehaviour unreachable — template now adapts per host shape
  #2 Live MaxSdkCallbacks — Step 7 warns about subscription sites
  #4 Init chain broken — "Exception inside wrappers" rule deleted

(#3 nullable double was fixed separately in 2.6.x.)

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 7.6: Push the branch and open the PR**

```bash
git push -u origin HEAD
gh pr create --title "Shape-aware MeticaAdService template (closes MET-11820)" --body "$(cat <<'EOF'
## Summary

Closes MET-11820 (minus the already-fixed nullable bug):

- **#1 MonoBehaviour unreachable** — `scripts/templates/standalone/MeticaAdService.cs.tmpl` is now parameterized on shape (MonoBehaviour / static class / plain class). The integrator asks the user in Step 3 plan mode; the default is suggested from the majority shape of the host's ad code.
- **#2 Live MaxSdkCallbacks** — Step 7 final report now lists every wrapper `MaxSdkCallbacks.*Event +=` subscription site with a double-firing warning, so the user knows what stays live if their routing leaves the wrapper reachable.
- **#4 Init chain broken** — The "Exception inside wrappers" paragraph at `agents/unity-integrator.md:453` is deleted. Wrapper-scoping is now absolute: the integrator never modifies wrapper-file contents, so init-area calls can't be stripped without replacement.

## Files changed

- `scripts/templates/standalone/MeticaAdService.cs.tmpl` — four new shape tokens
- `agents/unity-integrator.md` — Step 2.5 shape signal, Step 3 shape question, Step 5 token substitution, Step 7 walkthrough + callbacks listing, Exception-paragraph deletion
- `.claude-plugin/plugin.json` + `.claude-plugin/marketplace.json` — version bump (lockstep)

## Test plan

- [ ] `bash tests/run-all.sh` passes (existing five script suites are unaffected — verified during commit 7)
- [ ] Manually render the template with each shape (Task 1 Step 1.5) — outputs are syntactically valid C# with balanced braces and no leftover `__` tokens
- [ ] Run the integrator agent against a MonoBehaviour-shaped fixture project — output unchanged from current behavior (regression check)
- [ ] Run the integrator agent against a static-class-shaped fixture project (or the MET-11820 game) — output is a static class with explicit Initialize() and no MonoBehaviour hooks

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-review summary

After writing this plan, sanity-checked against the spec scope (template adaptation + wrapper-exception deletion + Step 7 callbacks warning):

- **Spec coverage**: Bug #1 → Tasks 1, 3, 4, 5. Bug #2 → Task 6. Bug #4 → Task 2. Version bump → Task 7. ✓
- **Placeholder scan**: No "TBD", "TODO", or "fill in later" markers. All code blocks contain runnable content. ✓
- **Type consistency**: The four shape tokens (`__CLASS_HEADER__`, `__START_HOOK__`, `__FOCUS_HOOK__`, `__STATIC__`) are named identically across Tasks 1, 3, 4, 5. The `SHAPE` variable is named identically across Tasks 3 and 4. ✓
- **Constraint adherence**: Version bumped once (Task 7); lockstep across both manifest files; no new test infrastructure. ✓
