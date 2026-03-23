# Agent Workflow

## Task Tracking: Hybrid Beads + GitHub Issues

You use **two issue systems** with distinct roles:

| System | Role | Lifetime |
|---|---|---|
| `bd` (Beads) | Your local scratchpad — sub-tasks, discovered work, in-progress notes, dependency tracking | Short-lived; clean up when done |
| GitHub Issues (`gh`) | Source of truth for the team — progress, decisions, completion | Persists; updated at key milestones |

### bd quick reference

```bash
# View
bd list                          # All issues
bd list --status open            # Open issues only
bd ready                         # What's unblocked and ready to work on
bd show <id>                     # Full details on one bead
bd dep tree <id>                 # Visualize dependency tree

# Create
bd create "Title" -t task -p 1                         # Simple task (priority 0-4, 0=highest)
bd create "Title" -t epic -p 1 --external-ref "gh-16"  # Epic linked to GitHub Issue
bd create "Title" -t task --parent <epic-id>            # Sub-task under an epic
bd create "Title" --deps "blocks:<id>"                  # Task with dependency

# Dependencies
bd dep <blocker-id> --blocks <blocked-id>              # A blocks B
bd dep add <blocked-id> <blocker-id>                   # Same thing, reversed syntax
bd dep relate <id-1> <id-2>                            # Soft relation (non-blocking)

# Update
bd update <id> --claim                                 # Claim a task
bd close <id> "Reason"                                 # Close with reason
bd close <id-1> <id-2> --reason "Done"                 # Close multiple

# Types: bug | feature | task | epic | chore | decision
# Priorities: 0 (critical) → 4 (low), default 2
```

---

## Session Start

1. Get your assigned GitHub Issue:
   ```bash
   gh issue view <number>
   ```
2. Create a parent bead to anchor your work, linked to the GitHub Issue:
   ```bash
   bd create "GH#<number>: <issue title>" -t epic -p 1 --external-ref "gh-<number>"
   # Note the returned bead ID
   ```
3. Break the work down into sub-tasks with dependencies:
   ```bash
   bd create "Investigate X" -t task -p 1 --parent <epic-id>
   # Returns e.g. <prefix>-d4e5f6
   bd create "Fix Y" -t task -p 1 --parent <epic-id> --deps "blocks:<prefix>-d4e5f6"
   ```

---

## During Work

- **Always check what's next:**
  ```bash
  bd ready
  ```
- **When you discover new work**, file it immediately — don't lose it:
  ```bash
  bd create "Found: Z needs fixing" -t task -p 2 --parent <epic-id>
  ```
- **Claim a task before starting it:**
  ```bash
  bd update <task-id> --claim
  ```
- **Close sub-tasks as you finish them:**
  ```bash
  bd close <task-id> "Done"
  ```
- **Check the dependency tree** to understand what's unblocked:
  ```bash
  bd dep tree <epic-id>
  ```

### When to update GitHub Issues

Update the GitHub Issue (not bd) when something is **meaningful to the team**:

| Situation | GitHub action |
|---|---|
| Meaningful progress or decision made | `gh issue comment <number> --body "..."` |
| Discovered a blocker or related issue | `gh issue comment` or `gh issue create` |
| Work is complete | `gh issue close <number> --comment "..."` or update the PR |
| Something changes scope/approach | Edit the issue body: `gh issue edit <number>` |

Keep GitHub comments **concise and human-readable** — no internal bead IDs or low-level noise.

---

## Session End ("Land the plane")

1. Close all finished sub-tasks:
   ```bash
   bd close <task-id> "Done"
   ```
2. File any remaining discovered work as new beads (or decide to drop them):
   ```bash
   bd create "Follow-up: ..." -t task -p 3 --parent <epic-id>
   ```
3. If the GitHub Issue is fully resolved, close it with a summary:
   ```bash
   gh issue close <number> --comment "Completed. <brief summary of what was done>"
   ```
4. Close the parent epic:
   ```bash
   bd close <epic-id> "GH#<number> resolved"
   ```
5. Clean up orphans — check for stale in-progress tasks from interrupted work:
   ```bash
   bd list --status=in_progress
   bd list --status=open
   ```

---

## Design Session (Multi-Agent)

The design session turns a rough idea into a well-rounded design document through structured debate between specialist agents.

```
@"design-facilitator (agent)" I want to build <idea>
```

Or with existing notes:
```
@"design-facilitator (agent)" read my-notes.md and design this
```

### How it works

```
Facilitator creates initial draft (design.md)
         │
         ▼ Round 1
  ┌──────┴───────────────────────────────────┐
  │  design-product   → .claude/design-feedback-product.md   │
  │  design-architect → .claude/design-feedback-architect.md │
  │  design-critic    → .claude/design-feedback-critic.md    │
  └──────────────────────────────────────────┘
         │
         ▼
  Facilitator reads all feedback, synthesizes into updated design.md
  Decisions logged. Open questions captured.
         │
         ├── Substantive changes made? → Round 2 (max 3 rounds)
         │
         └── Stable or round 3 reached → Final design.md produced
```

### What each specialist focuses on

| Specialist | Focus |
|---|---|
| `design-product` | User needs, measurable goals, scope, user stories, success metrics |
| `design-architect` | System design, data model, component boundaries, tech stack, scalability |
| `design-critic` | Hidden assumptions, contradictions, missing requirements, risks |

### Output

A `design.md` in the project root, ready to hand to `design-planner` to create GitHub issues.

Intermediate feedback files (`.claude/design-feedback-*.md`) are cleaned up automatically.

---

## Manager Workflow (Hands-off Loop)

The manager is the entry point for fully autonomous operation. Invoke it once and it will triage the backlog, set priorities, and drive the coordinator through issues one at a time until the backlog is empty or it hits something that needs a human decision.

```
@"manager (agent)" triage the backlog and start working through it
```

### What the manager does

```
Phase 1 — Triage
  │  Pull all open issues
  │  Flag incomplete issues (needs-detail label + comment)
  │  Close stale issues (>30 days, no activity)
  │  Close duplicates
  │  File missing issues discovered in comments/references
  │
  ▼
Phase 2 — Prioritize
  │  Assign P0/P1/P2/P3 label to every actionable issue
  │  Adjust mis-prioritized issues, leave comment explaining change
  │
  ▼
Phase 3 — Dependencies
  │  Identify blocked issues
  │  Comment on blocked issues so state is visible
  │
  ▼
Phase 4 — Delegate
  │  Pick highest-priority unblocked issue
  │  Spawn coordinator for that issue
  │  Wait for coordinator to finish and report back
  │
  ▼
Phase 5 — Re-evaluate
  │  Confirm issue closed
  │  Note any new issues filed by coordinator
  │  Loop back to Phase 1
  │
  └── Until: backlog empty | all remaining blocked | escalation needed
```

### Priority labels

| Label | When |
|---|---|
| `P0-critical` | Production broken, security issue, blocks everything |
| `P1-high` | Core feature for next milestone, unblocks other issues |
| `P2-medium` | Valuable but not blocking |
| `P3-low` | Nice to have, polish |

### Stop conditions

The manager stops and reports when:
- Backlog is empty
- All remaining issues are blocked or need detail
- The coordinator escalated (hit its 3-cycle fix limit)
- A priority decision has real architectural implications

When stopped, the manager produces a session summary: what was completed, what remains, why it stopped, and what the user should do next.

### When to use manager vs. coordinator directly

| Situation | Use |
|---|---|
| You want to hand off the whole backlog and check back later | `manager` |
| You want to implement one specific issue now | `coordinator` |
| You want to prioritize/triage without implementing anything | `manager` — it will stop after triage if you tell it to |

---

## Coordinator Workflow (Multi-Agent)

When working on an issue that involves implementation, testing, and iteration, use the **coordinator agent** to orchestrate the full cycle. The coordinator delegates to specialized agents and manages the feedback loop between them.

### Invoking the coordinator
```
@"coordinator (agent)" implement issue #<number> — <description>
```

### What the coordinator does

```
Step 0 — Set up tracking
  │  Create bd epic (--external-ref "gh-<number>")
  │  Create sub-tasks: implement, harden, validate
  │  Wire dependencies: harden depends-on implement, validate depends-on harden
  │
  ▼
Step 1 — Understand
  │  Read the GitHub Issue + existing code
  │  Claim the implement task
  │
  ▼
Step 2 — Implement
  │  Spawn the appropriate code agent
  │  Code agent builds feature + writes basic tests
  │  Close implement task
  │
  ▼
Step 3 — Harden tests
  │  Claim harden task
  │  Spawn test-writer
  │  Reviews coverage, adds edge cases and integration tests
  │  Close harden task
  │
  ▼
Step 4 — Validate
  │  Claim validate task
  │  Spawn test-runner (read-only)
  │  Runs full test suite
  │
  ├── All green → Step 5
  │
  └── Failures → Step 4a (fix loop)
        │  Create fix task: bd create "Fix: <failure>" -t task -p 1 --parent <epic>
        │  Analyze failure:
        │    Test wrong? → spawn test-writer to fix
        │    Code bug?   → spawn code agent with failure output
        │  Close fix task
        │  Re-run test-runner
        │  Max 3 fix cycles, then escalate to user
        │
        └── Green → Step 5
  │
  ▼
Step 5 — Report
  │  Close validate task
  │  Update GitHub Issue with results (gh issue comment)
  │  File any discovered follow-up work
  │  Close bd epic
```

### Agent routing fallback

If the coordinator can't find a suitable code agent for a task, it spawns the **agent-auditor** to:
1. Audit all agent definitions against current issues and codebase
2. Either expand an existing agent's scope or create a new agent
3. Return the updated routing so the coordinator can proceed

### Beads tracking during the cycle

The coordinator creates beads with dependencies to enforce ordering:
```bash
# Epic anchored to GitHub Issue
bd create "GH#<number>: <title>" -t epic -p 1 --external-ref "gh-<number>"
# Returns: <prefix>-a1b2c3

# Sub-tasks with dependency chain
bd create "Implement <feature>" -t task -p 1 --parent <prefix>-a1b2c3
# Returns: <prefix>-impl01

bd create "Harden test coverage" -t task -p 2 --parent <prefix>-a1b2c3
# Returns: <prefix>-hard01
bd dep <prefix>-impl01 --blocks <prefix>-hard01

bd create "Validate full suite" -t task -p 2 --parent <prefix>-a1b2c3
# Returns: <prefix>-val01
bd dep <prefix>-hard01 --blocks <prefix>-val01
```

`bd ready` will only show `<prefix>-impl01` initially. After it's closed, `<prefix>-hard01` becomes ready, and so on.

Discovered work during fix cycles gets its own task:
```bash
bd create "Fix: <failure description>" -t task -p 1 --parent <prefix>-a1b2c3
```

### When to use the coordinator vs. individual agents

| Situation | Use |
|---|---|
| Full feature implementation (build + test + iterate) | `coordinator` |
| Quick code exploration or one-off question | Individual agent directly |
| Only need tests reviewed | `test-writer` directly |
| Only need tests run | `test-runner` directly |
| Agents seem outdated or a task doesn't fit any agent | `agent-auditor` directly |
| New project setup or onboarding | `initiator` directly |
| Manual, step-by-step control over the process | Individual agents in sequence |

---

## Project Setup (Initiator)

When setting up a new project or onboarding an existing one, run the **initiator** agent:

```
@"initiator (agent)" validate this project's setup
```

The initiator runs 10 checks and produces a health report:

| Check | What it verifies |
|---|---|
| Project structure | `.git/`, `.claude/agents/`, source and test dirs exist |
| Git configuration | Remote configured, on a branch, clean working tree |
| GitHub access | `gh` installed, authenticated, can access repo and issues |
| bd setup | `bd` installed and initialized (`bd init --stealth` if missing) |
| Test framework | Detected (pytest/jest/go test/cargo test), can collect tests |
| Agent files | Valid frontmatter, no `{{...}}` placeholders remaining |
| Coordinator routing | All agents listed, no orphan references |
| Project config | `CLAUDE.md` or settings files present |
| Dependencies | Installed and matching dependency files |
| Gitignore | Covers `__pycache__/`, `node_modules/`, `.env`, `.beads/` |

It fixes what it can (creates dirs, inits bd, updates gitignore) and reports what needs manual attention.

**When to re-run the initiator:**
- After cloning to a new machine
- After major structural changes (new test framework, new source layout)
- When onboarding a teammate who hasn't used the agent system before

---

## Agent Maintenance

### Periodic audits

Run the **agent-auditor** periodically (every few issues or at the start of a new session) to keep agents current:
```
@"agent-auditor (agent)" audit all agents
```

The auditor checks:
- Issue coverage — every open issue assigned to an agent
- Stale references — closed issues, deleted files, outdated architecture descriptions
- Coordinator routing — table matches individual agent descriptions
- Gaps — whether a new agent is needed

### Handling interruptions

If the coordinator is interrupted mid-cycle (e.g., user cancels the tool call), child agents may still complete in the background. After an interruption:

```bash
# Check for orphaned work
bd list --status=in_progress
bd list --status=open

# Clean up stale beads
bd close <orphan-id> --reason "Coordinator interrupted, work completed manually"
```

The coordinator's child agents write code but don't commit — so interrupted work will show up in `git status` and can be reviewed manually.

---

## Example: Full Coordinator Cycle

A concrete walkthrough showing every step and bd command.

### Step 0 — Set up tracking
```bash
bd create "GH#42: Add user authentication" -t epic -p 1 --external-ref "gh-42"
# → <prefix>-a1b2c3

bd create "Implement auth module" -t task -p 1 --parent <prefix>-a1b2c3
# → <prefix>-impl01

bd create "Harden test coverage" -t task -p 2 --parent <prefix>-a1b2c3
# → <prefix>-hard01
bd dep <prefix>-impl01 --blocks <prefix>-hard01

bd create "Validate full suite" -t task -p 2 --parent <prefix>-a1b2c3
# → <prefix>-val01
bd dep <prefix>-hard01 --blocks <prefix>-val01
```

### Step 1 — Understand
```bash
bd ready
# Shows: <prefix>-impl01 "Implement auth module" (ready)

bd update <prefix>-impl01 --claim
```
Coordinator reads GH#42 and existing code.

### Step 2 — Implement
Coordinator spawns the code agent with specific instructions. Agent builds the feature and writes basic tests.
```bash
bd close <prefix>-impl01 "auth module + basic tests created"
```

### Step 3 — Harden tests
```bash
bd ready
# Shows: <prefix>-hard01 "Harden test coverage" (ready)

bd update <prefix>-hard01 --claim
```
Coordinator spawns `test-writer`. Agent adds edge case tests.
```bash
bd close <prefix>-hard01 "Edge case tests added"
```

### Step 4 — Validate
```bash
bd ready
# Shows: <prefix>-val01 "Validate full suite" (ready)

bd update <prefix>-val01 --claim
```
Coordinator spawns `test-runner`.

**Scenario A — All green:**
```bash
bd close <prefix>-val01 "All tests passing"
```

**Scenario B — Failure detected:**
```bash
bd create "Fix: token expiry not checked" -t task -p 1 --parent <prefix>-a1b2c3
# → <prefix>-fix01
bd update <prefix>-fix01 --claim
```
Coordinator spawns code agent with failure output. Agent fixes. Test-runner re-run. All green.
```bash
bd close <prefix>-fix01 "Added token expiry check"
bd close <prefix>-val01 "All tests passing after fix"
```

### Step 5 — Report
```bash
# Update GitHub
gh issue comment 42 --body "Implemented user authentication.
- src/auth.py: JWT-based auth with token refresh
- 18 tests covering happy path, expiry, and malformed tokens
- Fixed: missing token expiry validation (caught by test-writer)"

# Close epic
bd close <prefix>-a1b2c3 "GH#42 resolved"

# Verify clean state
bd ready
# (no orphaned tasks)
```

---

## Git Workflow

### Branches

One branch per epic, named after the GitHub Issue it implements:

```
epic/<issue-number>-<kebab-slug>

# Examples
epic/42-user-authentication
epic/57-csv-export
epic/103-rate-limiting
```

Always branch from an up-to-date `main`:
```bash
git checkout main && git pull
git checkout -b epic/<number>-<slug>
```

Never reuse a branch across multiple epics. When an epic is done and the PR is merged, the branch is retired.

### Commits

Commit frequently — after each logical unit of work, not in one lump at the end. Use conventional commit format:

```
<type>(<scope>): <short description>

<optional body explaining why, not what>

Refs #<issue-number>
```

| Type | When to use |
|---|---|
| `feat` | New behaviour visible to users or callers |
| `fix` | Bug correction |
| `test` | Adding or fixing tests only |
| `refactor` | Code restructuring with no behaviour change |
| `chore` | Build, config, dependency updates |
| `docs` | Documentation only |

Rules:
- One concern per commit — don't mix a feature with an unrelated fix
- Never commit broken code; tests must pass before committing
- Never commit to `main` directly
- Never commit secrets, `.env` files, or build artefacts

### When to open a PR

Open a PR when **any** of these are true:

| Trigger | Check |
|---|---|
| Epic complete | All tasks done, all tests green |
| Branch size | 5+ commits on the branch (`git log --oneline main..HEAD \| wc -l`) |
| Topic drift | The next issue is a different feature area — ship before switching |

When in doubt, PR sooner. Small, focused PRs are easier to review than large ones.

### PR format

```
Title: <Epic title — matches the GitHub Issue title>

## Summary
- <What was built>
- <Key design decision, if any>

## Issues closed
- Closes #<number>
- Closes #<number>  (if multiple issues were resolved)

## Test results
All <N> tests passing.

## Notes
<Known limitations, follow-up issues filed, anything a reviewer should know>
```

Rules:
- **One topic per PR.** Never mix changes from different epics. If unrelated commits crept onto the branch, move them out before opening.
- **Link every issue** with `Closes #N` so GitHub auto-closes on merge.
- **PR title = epic/issue title.** Consistent naming makes history readable.
- Open ready-to-review PRs, not drafts, when the work is complete.

### After merge

Delete the branch after merge to keep the remote clean:
```bash
git branch -d epic/<number>-<slug>
git push origin --delete epic/<number>-<slug>
```

Then start the next epic from a fresh `git pull` on `main`.

---

## Rules

- **Never put implementation details in GitHub comments** — keep them in bd.
- **Never put team-relevant decisions only in bd** — they'll be lost when you clean up.
- **bd is ephemeral by design.** Don't be precious about beads — close and clean aggressively.
- **One GitHub Issue = one bd epic** (at most). Don't create multiple epics per issue.
- **Use `--external-ref "gh-<number>"`** when creating epics to link them to GitHub Issues.
- **Use dependencies** (`bd dep`) to enforce task ordering — let `bd ready` drive what to work on next.
- **New agents created mid-session won't be available until the next session.** The agent list is loaded at startup. Use `general-purpose` as a fallback if needed.
- If a discovered bead turns out to be a separate user-facing bug or feature, graduate it to a GitHub Issue:
  ```bash
  gh issue create --title "..." --body "..."
  bd close <task-id> "Graduated to GH#<new number>"
  ```
