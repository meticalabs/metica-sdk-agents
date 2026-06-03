# Semantic-adjudication calibration corpus

These fixtures back the validator's **Phase 2 semantic adjudication** (`engine:
"llm-adjudicator"`, `validator/1.2.0` — see `agents/unity-validator.md` and
`agents/contracts.md`). They exist because the deterministic grep floor gets
behavioral rules wrong on real codebases, in **both** directions:

- **False positive** — `dead-reload-bad/`: `OnAdHidden` is subscribed and a
  `LoadRewarded` call is present, so grep's reload rule PASSes — but the reload
  is dead code behind a const-`false` flag, so the loop never closes at runtime.
- **(Grounded) true positive** — `indirect-reload-good/`: the reload happens
  through a helper (`OnAdHidden → RestartRewardedCycle() → LoadRewarded`). The
  semantic pass PASSes *with a cited 3-hop evidence chain*, so the green result
  is proven rather than assumed.
- **Floor-clean but experiment-unsafe** — `mediation-bypass-bad/`: every floor
  rule PASSes, but a direct `MaxSdk.ShowInterstitial` on a shared path bypasses
  Metica's SmartFloor, biasing Trial/Holdout. Only the semantic
  `trial_holdout_integrity` check catches it (target verdict `FAIL`).

## How this corpus is used

Two layers, by design:

1. **Deterministic, in CI (`tests/run-semantic-tests.sh`):**
   - asserts the **grep shadow verdict** (`grep_shadow` column of
     `expected-verdicts.tsv`) is stable for each fixture — this documents the
     divergence the semantic layer is there to fix, and fails loudly if the
     floor's behavior drifts;
   - runs `scripts/check-citation.sh` over each fixture's
     `expected-evidence.tsv` and asserts every cited line still resolves — this
     guards the goldens against bit-rot when the fixture source is edited.

2. **Out-of-band agreement eval (not in CI):** the `semantic_expected` column is
   the target verdict for the LLM adjudicator. During the **shadow phase**, run
   the validator agent over these fixtures (and real integrations like
   `metica-unity-sdk-demo`, the HM-Ad sample, and historical PRs), log where the
   `llm-adjudicator` verdict disagrees with `grep_shadow`, and grow the corpus
   from those disagreements. Promote a rule to canonical (`validator/2.0.0`) only
   once the LLM is right on disagreements above the agreed bar.

## Files

- `<fixture>/Assets/...`, `<fixture>/ProjectSettings/...` — a minimal Unity
  project the deterministic floor and the agent can both run against.
- `<fixture>/expected-evidence.tsv` — `<file>\t<line>\t<snippet>`, the evidence
  chain the adjudicator should be able to cite; verified by `check-citation.sh`.
- `expected-verdicts.tsv` — `fixture, rule, grep_shadow, semantic_expected, note`.
  `grep_shadow` is the deterministic floor's verdict for that rule, or **`n/a`**
  for a semantic-only rule that has no floor counterpart (e.g.
  `trial_holdout_integrity`); `n/a` rows skip the floor-stability assertion but
  still have their evidence resolved.

When you add a fixture, add its row(s) to `expected-verdicts.tsv` and (for rows
whose `semantic_expected` is a confident verdict) an `expected-evidence.tsv`.
