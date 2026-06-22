# claude-settings

Shared Claude Code configuration, synced across machines via git.

## What's tracked

| Path | Purpose |
|------|---------|
| `CLAUDE.md` | Global instructions applied to all projects |
| `settings.json` | Claude Code UI/behaviour settings |
| `projects/*/memory/` | Per-project auto-memory files |

Everything else (credentials, sessions, cache, history, shell snapshots) is excluded via `.gitignore`.

## Setup on a new machine

```bash
# 1. Clone this repo
git clone git@github.com:steppicrew/claude-settings.git ~/git/claude-settings

# 2. Back up any existing ~/.claude (if present)
mv ~/.claude ~/.claude.bak   # skip if not present

# 3. Symlink ~/.claude to the repo
ln -s ~/git/claude-settings ~/.claude
```

Claude Code will now pick up `CLAUDE.md`, `settings.json`, and all project memories automatically.

## Keeping in sync

```bash
# Pull latest settings on any machine
cd ~/git/claude-settings && git pull

# After Claude Code updates settings or memory files, commit and push
cd ~/git/claude-settings
git add -A
git commit -m "chore: sync claude settings"
git push
```

## Notes

- `~/.claude/.credentials.json` is intentionally excluded — authenticate on each machine separately via `claude login`.
- Project memory paths are named after the absolute path of the project on the machine (e.g. `-home-stephan-git-atb-X-Radar-Framework`). These will only load on machines with the same directory layout, but they sync harmlessly otherwise.
