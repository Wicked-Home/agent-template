Run the agent-template installer in the current project directory.

Execute the following bash command and report the output to the user:

```bash
curl -fsSL https://raw.githubusercontent.com/Wicked-Home/agent-template/main/install.sh | bash
```

After it completes:
- If there were errors or warnings, explain what the user needs to do to resolve them.
- Remind the user that newly installed agents won't be available until the next Claude Code session.
- If the install succeeded cleanly, suggest they start by customizing `.claude/agents/code-agent.md` using `.claude/agents/example-backend-api.md` as a reference.
