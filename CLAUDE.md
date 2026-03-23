# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a **multi-agent system template** for Claude Code. It provides reusable agent definitions and workflow documentation meant to be copied into other projects.

## Setup

**One command** from inside any project folder:

```bash
curl -fsSL https://raw.githubusercontent.com/Wicked-Home/agent-template/main/install.sh | bash
```

Or from a Claude Code session, add the `/add-agents` slash command once globally:

```bash
curl -fsSL https://raw.githubusercontent.com/Wicked-Home/agent-template/main/.claude/commands/add-agents.md \
  >> ~/.claude/commands/add-agents.md
```

Then type `/add-agents` in any session to install into that project.

After install, start a new session (agents load at startup), then validate:

```
@"initiator (agent)" validate this project's setup
```

## Agent Architecture

Twelve specialized agents cover the full development lifecycle, from idea to shipped:

### Design phase
| Agent | Role | Model |
|---|---|---|
| **design-facilitator** | Runs a multi-agent design session; synthesizes specialist debate into a design doc | opus |
| **design-product** | Product specialist — user needs, scope, success metrics (spawned by facilitator) | sonnet |
| **design-architect** | Architecture specialist — system design, data model, interfaces (spawned by facilitator) | sonnet |
| **design-critic** | Devil's advocate — assumptions, contradictions, risks, missing requirements (spawned by facilitator) | sonnet |

### Planning phase
| Agent | Role | Model |
|---|---|---|
| **design-planner** | Reads a finished design doc and creates structured GitHub issue backlog | opus |
| **initiator** | One-time project setup validation and bootstrapping | sonnet |

### Execution phase
| Agent | Role | Model |
|---|---|---|
| **manager** | Triages backlog, sets priorities, delegates to coordinator in a hands-off loop | opus |
| **coordinator** | Orchestrates build-test-fix cycle for a single epic | sonnet |
| **code-agent** | Template for domain-specific implementation agents | sonnet |
| **test-writer** | Hardens coverage with edge cases and integration tests | sonnet |
| **test-runner** | Executes test suite (read-only, no code changes) | sonnet |

### Maintenance
| Agent | Role | Model |
|---|---|---|
| **agent-auditor** | Audits agent definitions for drift and proposes new agents | sonnet |

### Workflow Cycle (via Coordinator)

```
Epic created in bd → Code-Agent implements → Test-Writer hardens →
Test-Runner validates → PASS: close epic | FAIL: fix loop (max 3 cycles)
```

Invoke with: `@"coordinator (agent)" implement issue #<number>`

### Task Tracking: bd (Beads) + GitHub

- **GitHub Issues**: source of truth for team communication
- **bd (Beads)**: local ephemeral scratchpad for sub-tasks and dependencies
- One GitHub issue maps to one bd epic maximum
- Clean up bd entries aggressively after task completion

Key bd commands:

```bash
bd init --stealth      # initialize in project
bd create "GH#42: …"  # create task linked to issue
bd dep <id> --blocks <id>  # set dependency chain
bd ready <id>          # mark ready to work
bd close <id>          # close when done
```

## Agent Definition Format

Agents use YAML frontmatter + Markdown:

```yaml
---
name: my-agent
description: What this agent does and which issues it handles
tools: Read, Edit, Write, Bash, Grep, Glob, Agent
model: sonnet   # haiku | sonnet | opus
maxTurns: 30
---
```

## Customizing code-agent.md

`agents/code-agent.md` is a template with these placeholders to fill in per project:

- `{{PROJECT_NAME}}` — project description
- `{{DESCRIPTION}}` — agent scope and issue numbers
- `{{CONTEXT}}` — architecture and tech stack
- `{{RESPONSIBILITIES}}` — what this agent builds
- `{{TEST_FRAMEWORK}}` — e.g., pytest, jest, go test
- `{{TEST_COMMAND}}` — command to run tests
- `{{CONSTRAINTS}}` — design rules and conventions
- `{{REFERENCES}}` — key docs, ADRs, design files

## Key Operational Notes

- The agent list is loaded at session start — newly added agents require starting a new session. Use Claude Code's built-in `general-purpose` agent as a fallback mid-session if needed.
- Coordinator delegates all implementation; it never writes code directly.
- Never put implementation details in GitHub issues; use bd for that.
- Run `@"agent-auditor (agent)"` periodically to catch agent drift as the codebase evolves.
- Mark completed issue references with `(done: #X)` pattern in agent descriptions.
- When customizing agents, also check for `<!-- UPDATE THIS SECTION -->` HTML comments in `coordinator.md` and `test-writer.md` — the initiator only flags `{{...}}` placeholders, not these.

## Dependencies: Dolt + bd (Beads)

`bd` uses [Dolt](https://github.com/dolthub/dolt) as its storage backend. Install Dolt first, then bd.

### 1. Install Dolt

**macOS:**
```bash
brew install dolt
```

**Linux:**
```bash
curl -L https://github.com/dolthub/dolt/releases/latest/download/install.sh | bash
```

**Windows:** Download the installer from the [Dolt releases page](https://github.com/dolthub/dolt/releases/latest).

Verify: `dolt version`

### 2. Install bd (Beads)

```bash
pip install beads-cli
```

Verify: `bd --version`

### 3. Initialize bd in your project

```bash
cd /path/to/your-project
bd init --stealth
```

`--stealth` keeps the `.beads/` directory out of `git status` noise (the initiator will add it to `.gitignore` automatically).
