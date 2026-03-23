# Agent Workflow Template

A reusable multi-agent system with a coordinator, specialized code agents, test agents, an auditor, and bd (Beads) task tracking.

## Quick Start

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

After install:

1. Customize `.claude/agents/code-agent.md` — use `example-backend-api.md` as a reference
2. Update the routing table in `.claude/agents/coordinator.md`
3. Start a new Claude Code session (agents load at session start), then run:
   ```
   @"initiator (agent)" validate this project's setup
   ```

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
    ├── initiator.md                ← Bootstraps + validates project setup (run first)
    ├── coordinator.md              ← Orchestrates build → test → fix loop
    ├── code-agent.md               ← Template for domain-specific code agents
    ├── example-backend-api.md      ← Filled-in example of code-agent.md (Python/FastAPI)
    ├── test-writer.md              ← Reviews coverage, writes edge case tests
    ├── test-runner.md              ← Executes test suite, reports results (read-only)
    ├── agent-auditor.md            ← Audits agents for accuracy, proposes new agents
    └── design-planner.md           ← Reads a design doc and creates GitHub issue backlog
```

## How to Customize

### 1. Create your code agents

`code-agent.md` is a template — copy it once per domain in your project. See `example-backend-api.md` for a fully filled-in reference. For example:

```bash
cp agents/code-agent.md agents/backend-api.md
cp agents/code-agent.md agents/frontend-ui.md
cp agents/code-agent.md agents/data-pipeline.md
```

Then edit each copy:
- Set the `name` and `description` in frontmatter
- Fill in the domain context, responsibilities, and design constraints
- Map it to the relevant GitHub Issues

### 2. Update the coordinator

Edit `coordinator.md`:
- Update the agent table to list your actual code agents
- Adjust the issue mappings
- Set the model (`opus` / `sonnet` / `haiku`) based on task complexity needs

### 3. Update the test agents

Edit `test-writer.md`:
- Replace the example edge cases with ones relevant to your project
- Update the test conventions if you use something other than pytest

Edit `test-runner.md`:
- Update the test command if not using `python -m pytest`
- Add any project-specific validation scenarios

### 4. Run the initiator

After copying the files, run the initiator to validate your project setup:
```
@"initiator (agent)" validate this project's setup
```

It checks project structure, git, GitHub access, bd, test framework, agent configuration, dependencies, and gitignore. It fixes what it can and reports what needs manual attention.

### 5. Configure the auditor

Edit `agent-auditor.md`:
- Update the GitHub issue command if you use a PAT or different auth
- Adjust source directories to match your project layout

### 6. Set up bd

```bash
cd /path/to/your-project
bd init --stealth
```

The workflow doc and all agents reference bd commands. If your project has a different bd prefix, the commands will work automatically — bd uses whatever prefix was configured at init.

## Architecture

```
    ┌─────────────────┐
    │ design-planner  │  ← run at project start: spec → GitHub issues
    └────────┬────────┘
             │ creates epics + tasks in GitHub
             ▼
    ┌──────────────┐
    │  initiator   │  ← run once to validate tooling setup
    └──────┬───────┘
           │ validates project, then hands off to:
           ▼
    ┌──────────────┐
    │ coordinator  │  ← orchestrates each issue
    └──────┬───────┘
           │
  ┌────────┼──────────────┐
  │        │              │
  Build    Harden    Validate
  │        │              │
┌─┴──────┐ ┌┴───────────┐ ┌┴───────────┐
│ code   │ │ test-writer │ │ test-runner │
│ agent  │ │             │ │ (read-only) │
└─┬──────┘ └┬───────────┘ └┬───────────┘
  │        │              │
  └────────┼──────────────┘
           │
    Fails? ─┤── Yes → fix loop (max 3×)
           │
    No → report & close

    ┌────────────────┐
    │ agent-auditor  │  ← called when no agent fits,
    │ (periodic)     │    or periodically to keep agents current
    └────────────────┘
```

## Invoking

```
# Turn a design doc into a GitHub issue backlog
@"design-planner (agent)" read docs/design.md and create issues

# First-time setup
@"initiator (agent)" validate this project's setup

# Full cycle via coordinator
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
