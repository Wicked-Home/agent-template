# Agent Workflow Template

A reusable multi-agent system with a coordinator, specialized code agents, test agents, an auditor, and bd (Beads) task tracking.

## Quick Start

1. Copy the `agents/` folder into your project's `.claude/agents/` directory
2. Copy `workflow.md` to your project root (or wherever your team docs live)
3. Run the **initiator** agent to validate your setup and catch missing pieces
4. Customize each agent file — replace the placeholder sections marked with `{{...}}`

```bash
# Example setup
cp -r agents/ /path/to/your-project/.claude/agents/
cp workflow.md /path/to/your-project/

# Then in Claude Code:
@"initiator (agent)" validate this project's setup
```

## What's Included

```
agent-template/
├── README.md                  ← You are here
├── workflow.md                ← Full workflow doc (bd + GitHub + coordinator cycle)
└── agents/
    ├── initiator.md           ← Bootstraps + validates project setup (run first)
    ├── coordinator.md         ← Orchestrates build → test → fix loop
    ├── code-agent.md          ← Template for domain-specific code agents
    ├── test-writer.md         ← Reviews coverage, writes edge case tests
    ├── test-runner.md         ← Executes test suite, reports results (read-only)
    └── agent-auditor.md       ← Audits agents for accuracy, proposes new agents
```

## How to Customize

### 1. Create your code agents

`code-agent.md` is a template — copy it once per domain in your project. For example:

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
    ┌──────────────┐
    │  initiator   │  ← run once at project setup
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
