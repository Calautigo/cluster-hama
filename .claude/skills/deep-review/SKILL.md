---
name: deep-review
description: This skill should be used when the user asks to "run a deep review", "comprehensive code review", "parallel review", "4-way review", "review with multiple perspectives", "thorough review", or wants a code review covering security, correctness, performance, and maintainability simultaneously.
version: 0.1.0
---

# Deep Review Skill

Run a comprehensive code review by spawning 4 parallel subagents, each with a distinct focus area. After all agents complete, synthesize their findings into a single structured report.

## Workflow

### Step 1 — Determine what to review

Use the `AskUserQuestion` tool to ask:

> "What should I review? Options:
> - Leave blank → all current git changes (`git diff HEAD`)
> - File or path → e.g. `kubernetes/apps/services/nextcloud/ks.yaml`
> - Glob pattern → e.g. `kubernetes/apps/services/**/*.yaml`
> - Specific commit or branch → e.g. `main..HEAD`"

### Step 2 — Collect the source material

Based on the answer, gather the content to review:

- **Blank / git diff**: Run `git diff HEAD` (include staged and unstaged)
- **File/path**: Read the file(s) using Read/Glob tools
- **Glob**: Expand with Glob, then Read each file
- **Commit/branch**: Run `git diff <ref>`

Store the collected content as the **review payload** — pass it verbatim to all 4 agents.

### Step 3 — Spawn 4 parallel agents

Launch all four agents **in a single message** (parallel tool calls). Each agent receives the full review payload embedded in its prompt.

#### Agent 1 — Security & Secrets
```
Focus: Security vulnerabilities only.

Review the following code/config for:
- Hardcoded secrets, tokens, passwords, API keys
- Overly permissive RBAC, permissions, or policies (e.g. wildcard ClusterRoles)
- Exposed sensitive data in logs, env vars, or config maps
- Injection risks (command injection, path traversal, template injection)
- Unsafe external references or image sources without digest pinning
- TLS/cert misconfigurations or disabled verification
- Network policies that are too permissive

For each finding provide: severity (critical/high/medium/low), file:line if available, description, and recommended fix.
Format findings as a markdown list. If nothing found, say "No security issues found."

--- CONTENT TO REVIEW ---
<review payload>
```

#### Agent 2 — Correctness & Logic
```
Focus: Bugs, logic errors, and correctness only.

Review the following code/config for:
- Logic errors or conditions that will never be true/false
- Off-by-one errors, wrong operators, inverted conditions
- Missing error handling or unhandled edge cases
- Incorrect resource references (wrong name, namespace, kind)
- Dependency ordering issues (dependsOn missing or wrong)
- Incorrect field values, types, or units
- Race conditions or ordering assumptions that may break

For each finding provide: severity (critical/high/medium/low), file:line if available, description, and recommended fix.
Format findings as a markdown list. If nothing found, say "No correctness issues found."

--- CONTENT TO REVIEW ---
<review payload>
```

#### Agent 3 — Performance & Best Practices
```
Focus: Performance, efficiency, and best practices only.

Review the following code/config for:
- Inefficient resource requests/limits (too high, too low, missing)
- Missing health checks, readiness/liveness probes
- Suboptimal sync intervals, timeouts, or retry settings
- Anti-patterns for the technology in use (Flux, Helm, Kubernetes, etc.)
- Unnecessary duplication that could use shared components
- Missing resource constraints that could cause noisy-neighbour issues
- Helm values that deviate from upstream best practices without reason

For each finding provide: severity (high/medium/low), file:line if available, description, and recommended fix.
Format findings as a markdown list. If nothing found, say "No performance/best-practice issues found."

--- CONTENT TO REVIEW ---
<review payload>
```

#### Agent 4 — Maintainability & Clarity
```
Focus: Maintainability, readability, and long-term health only.

Review the following code/config for:
- Unclear naming (resources, variables, labels) that will confuse future maintainers
- Missing or outdated comments where non-obvious decisions were made
- Inconsistency with patterns used elsewhere in the codebase
- Overly complex configurations that could be simplified
- Magic values that should be variables or substitutions
- Dead code, commented-out blocks, or leftover debug config
- Missing labels, annotations, or metadata that are expected by convention

For each finding provide: severity (high/medium/low), file:line if available, description, and recommended fix.
Format findings as a markdown list. If nothing found, say "No maintainability issues found."

--- CONTENT TO REVIEW ---
<review payload>
```

### Step 4 — Synthesize results

After all 4 agents return, produce a single consolidated report:

```markdown
# Deep Review Report

## What was reviewed
<one line: files/diff/scope>

---

## 🔐 Security & Secrets
<agent 1 output>

---

## 🐛 Correctness & Logic
<agent 2 output>

---

## ⚡ Performance & Best Practices
<agent 3 output>

---

## 🔧 Maintainability & Clarity
<agent 4 output>

---

## Summary

| Area | Critical | High | Medium | Low |
|------|----------|------|--------|-----|
| Security | n | n | n | n |
| Correctness | n | n | n | n |
| Performance | n | n | n | n |
| Maintainability | n | n | n | n |

**Top priority fixes:**
1. <most critical issue across all areas>
2. <second most critical>
3. <third most critical>
```

## Important Notes

- Always spawn all 4 agents in **one parallel call** — do not wait for one before starting the next.
- Pass the **complete review payload** to every agent — do not truncate or summarize it.
- Each agent must stay strictly within its own focus area — cross-cutting concerns will be caught by the appropriate agent.
- The synthesis step is critical: de-duplicate findings that appear in multiple agents and present one clean report.
- Use `subagent_type: general-purpose` for all 4 agents.
