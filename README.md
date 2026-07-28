# claude-settings

Public sync tooling for Claude Code configuration. Personal settings live in a separate private config repo.

## How it works

```
~/git/claude-settings/       ← this repo (public): sync tooling only
  sync.sh
  install-alias.sh
  config/
    personal/                ← private config repo (cloned via add-config)
      CLAUDE.md
      settings.json
      plugins/
      projects/
    current -> personal/     ← symlink to active config
~/.claude -> config/current  ← Claude Code reads config from here
```

## Setup on a new machine

```bash
# 1. Clone this repo
git clone git@github.com:steppicrew/claude-settings.git ~/git/claude-settings

# 2. Clone your private config repo
~/git/claude-settings/sync.sh add-config personal git@github.com:you/claude-settings-personal.git

# 3. Point ~/.claude at the active config (config/current already points to personal/)
ln -sfn ~/git/claude-settings/config/current ~/.claude

# 4. Add the claude-sync shell alias
~/git/claude-settings/install-alias.sh
source ~/.bash_aliases   # bash
# source ~/.zshrc        # zsh
```

## Syncing

```bash
claude-sync           # pull + push active config (default)
claude-sync pull      # fetch remote, merge, restore plugins
claude-sync push      # commit local changes and push
claude-sync -v        # verbose output
```

## Multiple configs

```bash
claude-sync add-config work git@github.com:you/claude-settings-work.git
claude-sync switch-config work    # re-points config/current (~/.claude follows automatically)
claude-sync list-configs          # show all configs, mark active
```

## What's in a private config repo

| Path | Purpose |
|------|---------|
| `CLAUDE.md` | Global instructions applied to all projects |
| `settings.json` | Claude Code UI/behaviour settings |
| `plugins/installed_plugins.json` | Which plugins are installed |
| `plugins/known_marketplaces.json` | Registered plugin marketplaces |
| `plugins/blocklist.json` | Blocked plugins |
| `projects/*/memory/` | Per-project auto-memory files |

Plugin marketplace dirs and cache are excluded — they are re-fetched on pull.

## Sharing project memory across machines with different paths

Claude keys each project's auto-memory dir by the project's **absolute path**
(`projects/-home-you-git-myproject/memory/`). The same repo checked out at a
different path on another machine (e.g. `…-workspace-git-myproject…`) gets a
**separate** path-keyed dir. Both sync via git, but each machine only reads the
one matching its own layout — so memory silently forks per machine.

`link-memory.sh` fixes this: it picks the de-workspaced path-key as the
canonical real `memory/` dir, merges the `-workspace-` twin's memory into it
(union, never overwrites divergent files), then replaces the twin's `memory/`
with a **relative symlink** → canonical. Git stores the symlink and recreates
it on pull, so both path-keys resolve to one shared store on every machine.

```bash
./link-memory.sh --dry-run          # preview; auto-discovers all "-workspace-" pairs
./link-memory.sh                    # apply to every pair
./link-memory.sh <canon> <twin>     # link one explicit pair (dir names, no slashes)
claude-sync                         # commit + push the result
```

Only `memory/` is touched — session `.jsonl` transcripts stay per-machine. The
private config repo's `.gitignore` must un-ignore `projects/*/memory` **without**
a trailing slash, or the symlink itself is dropped (a trailing-slash rule
matches directories only).

## Notes

- `~/.claude/.credentials.json` is excluded — authenticate per machine via `claude login`.
- Project memory paths encode the absolute project path (e.g. `-home-you-git-myproject`). They load only on machines with matching directory layout — run `link-memory.sh` (above) to share one store across differing layouts.
- Reference plugin scripts via `~/.claude/plugins/marketplaces/<plugin>/src/...`, never the cache path (hash varies per machine).
