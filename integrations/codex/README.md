# Codex Integration

Codex native subagents are TOML files stored in `.codex/agents/`. Codex
skills are `SKILL.md` files stored in `.codex/skills/`.

The Agency converter generates one Codex agent and one matching skill wrapper
per Agency Markdown file. Names use the `agency-` prefix, such as
`agency-frontend-developer`, to avoid overwriting existing Codex or oh-my-codex
role agents.

## Install

On Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\install-codex.ps1
```

On macOS, Linux, WSL, or Git Bash:

```bash
./scripts/install.sh --tool codex
```

Both commands install generated agents to:

```text
~/.codex/agents/
```

They also install skills to:

```text
~/.codex/skills/
```

The `$agency` router skill helps pick a specialist. Individual wrappers such as
`$agency-frontend-developer` are also installed and can delegate to the matching
native subagent when Codex exposes it.

## Project-Scoped Install

To install into the current project's `.codex/agents/` directory instead of the
user-wide Codex directory:

```powershell
powershell -ExecutionPolicy Bypass -File /path/to/agency-agents/scripts/install-codex.ps1 -Scope project
```

## Generate Only

To generate Codex TOML files without installing them:

```bash
./scripts/convert.sh --tool codex
```

This writes generated files to:

```text
integrations/codex/agents/
integrations/codex/skills/
```

Generated integration files are ignored by git and can be regenerated.

## Refresh in Codex

Start a new Codex session after installation so the native agent and skill lists
are reloaded.
