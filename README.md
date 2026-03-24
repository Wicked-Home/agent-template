# Agent Workflow Template

A reusable multi-agent system with a coordinator, specialized code agents, test agents, an auditor, and bd (Beads) task tracking.

## Quick Start

### Step 0 — Design (optional but recommended)

If you're starting from an idea rather than an existing codebase, run the design phase first. This produces a `design.md` and a GitHub issue backlog, and writes a `.claude/project-context.md` file that the initiator uses to configure your agents automatically.

```
@"design-facilitator (agent)" I want to build <your idea>
```

The facilitator runs three specialist agents (product, architect, critic) in debate, then synthesizes their output into `design.md`. Once the design is done:

```
@"design-planner (agent)" read design.md and create issues
```

The planner creates your GitHub issue backlog and writes `.claude/project-context.md`.

---

### Step 1 — Install

**From a terminal** — run this in your project folder:

```bash
curl -fsSL https://raw.githubusercontent.com/Wicked-Home/agent-template/main/install.sh | bash
```

**From inside a Claude Code session** — add the `/add-agents` command once to your global commands:

```bash
curl -fsSL https://raw.githubusercontent.com/Wicked-Home/agent-template/main/.claude/commands/add-agents.md \
  >> ~/.claude/commands/add-agents.md
```

Then in any project session:

```
/add-agents
```

Both do the same thing: copy agents, copy `workflow.md`, update `.gitignore`, check for dolt/bd, and print next steps.

### Step 2 — Bootstrap

Start a new Claude Code session (agents load at session start), then run:

```
@"initiator (agent)" validate this project's setup
```

If you ran the design phase, the initiator reads `.claude/project-context.md` and creates your domain agents automatically. Otherwise it will guide you through setup interactively.

## What's Included

```
agent-template/
├── README.md                       ← You are here
├── install.sh                      ← One-command installer (curl | bash)
├── workflow.md                     ← Full workflow doc (bd + GitHub + coordinator cycle)
├── .claude/
│   └── commands/
│       └── add-agents.md           ← Claude Code slash command: /add-agents
└── agents/
    ├── design-facilitator.md       ← Runs multi-agent design session, synthesizes into design.md
    ├── design-product.md           ← Product specialist (spawned by facilitator)
    ├── design-architect.md         ← Architecture specialist (spawned by facilitator)
    ├── design-critic.md            ← Devil's advocate (spawned by facilitator)
    ├── design-planner.md           ← Reads finished design.md, creates GitHub issue backlog
    ├── initiator.md                ← Bootstraps + validates project setup (run first)
    ├── manager.md                  ← Triages backlog, sets priorities, drives hands-off loop
    ├── coordinator.md              ← Orchestrates build → test → fix loop (one epic)
    ├── code-agent.md               ← Template for domain-specific code agents
    ├── example-backend-api.md      ← Filled-in example of code-agent.md (Python/FastAPI)
    ├── test-writer.md              ← Reviews coverage, writes edge case tests
    ├── test-runner.md              ← Executes test suite, reports results (read-only)
    └── agent-auditor.md            ← Audits agents for accuracy, proposes new agents
```

## How to Customize

### 1. Run the initiator

The initiator handles initial project setup interactively — it will ask you what domain agents your project needs, create copies of `code-agent.md` for each, fill in the placeholders, and update the coordinator routing table automatically.

See `example-backend-api.md` for a reference of what a fully filled-in code agent looks like.

### 2. Update the test agents

Edit `test-writer.md`:
- Replace the example edge cases with ones relevant to your project
- Update the test conventions if you use something other than pytest

Edit `test-runner.md`:
- Update the test command if not using `python -m pytest`
- Add any project-specific validation scenarios

### 3. Configure the auditor

Edit `agent-auditor.md`:
- Update the GitHub issue command if you use a PAT or different auth
- Adjust source directories to match your project layout

### 4. Set up bd

```bash
cd /path/to/your-project
bd init --stealth
```

The workflow doc and all agents reference bd commands. If your project has a different bd prefix, the commands will work automatically — bd uses whatever prefix was configured at init.

## Architecture

```
              ┌──────────────────────┐
              │  design-facilitator  │  ← turn an idea into a design doc
              └──────────┬───────────┘
    spawns in sequence   │
  ┌──────────────────────┼───────────────────────┐
  ▼                      ▼                        ▼
┌────────────────┐  ┌──────────────────┐  ┌────────────────┐
│ design-product │  │ design-architect │  │ design-critic  │
└───────┬────────┘  └────────┬─────────┘  └───────┬────────┘
        └──── feedback ──────┴──── feedback ────────┘
                             │ synthesize (up to 3 rounds)
                             ▼
                        design.md
                             │
                             ▼
                   ┌─────────────────┐
                   │  design-planner │  ← design.md → GitHub issues
                   └────────┬────────┘
                            │
                            ▼
                   ┌──────────────┐
                   │  initiator   │  ← validate tooling (run once)
                   └──────┬───────┘
                          │
                          ▼
                   ┌──────────────┐
                   │   manager    │  ← triage → prioritize → delegate → repeat
                   └──────┬───────┘
                          │ one issue at a time
                          ▼
                   ┌──────────────┐
                   │ coordinator  │  ← orchestrates one epic end-to-end
                   └──────┬───────┘
                          │
            ┌─────────────┼──────────────┐
          Build        Harden        Validate
            │             │              │
       ┌────┴───┐  ┌──────┴──────┐  ┌───┴────────┐
       │ code   │  │ test-writer │  │ test-runner │
       │ agent  │  │             │  │ (read-only) │
       └────────┘  └─────────────┘  └────────────┘
                          │
                  Fails? ─┤── fix loop (max 3×)
                  No → PR + report back to manager

    ┌────────────────┐
    │ agent-auditor  │  ← periodic: keeps agent definitions current
    └────────────────┘
```

## Invoking

```
# Turn an idea into a design document (collaborative multi-agent session)
@"design-facilitator (agent)" I want to build a task management app for small teams

# Turn a finished design doc into a GitHub issue backlog
@"design-planner (agent)" read design.md and create issues

# First-time setup
@"initiator (agent)" validate this project's setup

# Hands-off: triage backlog, set priorities, and drive all implementation
@"manager (agent)" triage the backlog and start working through it

# Full cycle for one issue via coordinator (without manager)
@"coordinator (agent)" implement issue #42

# Individual agents directly
@"backend-api (agent)" add pagination to the /users endpoint
@"test-writer (agent)" review coverage for src/auth/
@"test-runner (agent)" run the test suite

# Periodic maintenance
@"agent-auditor (agent)" audit all agents
```

## Lessons from Production Use

These patterns emerged from real multi-agent projects:

- **Agent list is loaded at session start.** New agents created mid-session won't appear until the next session. Use `general-purpose` as a fallback.
- **Coordinator interruptions leave orphans.** If you interrupt the coordinator, its child agents may still complete in the background. Check `bd list --status=in_progress` and clean up stale beads.
- **Share issue ownership sparingly.** When two agents must share an issue (e.g., boot integration touching both state machine and config), note it explicitly in both agents and the coordinator table.
- **Mark completed issues in descriptions.** Use a pattern like `(done: #1, #3, #5)` in agent descriptions so it's clear what's active vs. historical context.
- **Run the auditor periodically.** After every few issues, run `agent-auditor` to catch stale references, unassigned issues, and drift between agents and the coordinator's routing table.
