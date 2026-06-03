# Security policy

## Reporting a vulnerability

If you believe you have found a security vulnerability in `metica-sdk-agents`,
**please do not open a public GitHub issue.**

Instead, email **dev@metica.com** with:

- A description of the issue
- Steps to reproduce (or a proof-of-concept if you have one)
- The affected version (see `.claude-plugin/plugin.json`)
- Any suggested fix or mitigation

We will acknowledge your report within **5 business days** and aim to provide
a remediation timeline within **10 business days** of acknowledgement.

## Scope

This repository ships agent definitions and shell scripts that run on a
developer's machine as part of Claude Code. Reports of interest include, but
are not limited to:

- Command injection or arbitrary code execution in the shell scripts under
  `scripts/`
- Path-traversal or unsafe file writes in the integrator's codegen pipeline
- Leakage of credentials, API keys, or user-supplied input through agent
  prompts or generated artifacts
- Tampering with the marketplace install flow (`install.sh`) or
  `resolve-plugin-dir.sh`

Bugs that require an attacker to already have control of the developer's
machine, or that only affect the generated game-side code in ways the
host project would already need to validate, are out of scope.

## Supported versions

We support the latest minor release line (see `.claude-plugin/plugin.json`).
Older releases will not receive backported fixes.
