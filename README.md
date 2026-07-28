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
different path — or under a slightly different directory name — on another
machine gets a **separate** path-keyed dir. Both sync via git, but each machine
only reads the one matching its own layout, so memory silently forks per machine.

`claude-memory-init.sh` fixes this with a **name-keyed** store. It derives a
stable name from the repo's git remote URL (host + path, sanitized — so it
survives differing local dir names and even repos that share a basename), keeps
the real memory under `shared_memory/<name>/memory/` in the config repo, and
replaces this machine's path-keyed `memory/` dir with a **relative symlink** into
it. Run it once in each checkout on each machine; every path-key then points at
the one shared, git-tracked store.

```bash
cd ~/path/to/your/repo               # run from inside the repo checkout
claude-memory-init.sh --dry-run      # preview name + actions
claude-memory-init.sh                # create/link the shared store (merges any
                                     # existing path-keyed memory into it first)
claude-memory-init.sh --name foo     # override the derived name (disambiguate)
claude-sync                          # commit + push the result
```

On a **new machine**: clone the config, checkout the repo, run
`claude-memory-init.sh` in it — the symlink is recreated pointing at the
already-synced `shared_memory/<name>`. No manual pairing.

**Merge review (hybrid).** The file union is safe but mechanical — it never
overwrites and cannot judge meaning. When a merge is non-trivial (a divergent
same-name file, or both sides already held memory), the script still unions
everything, preserves any dropped incoming copy as `<file>.incoming`, and writes
a `MERGE-REQUEST.md` into the shared `memory/`. Because it lives in the memory
dir, the next Claude Code session in that repo loads it; say **"resolve the
pending memory merge"** and Claude reconciles contradictions/duplicates, resolves
the `.incoming` pairs, then deletes `MERGE-REQUEST.md`. Clean merges skip all of
this.

Only `memory/` is touched — session `.jsonl` transcripts stay per-machine. The
private config repo's `.gitignore` must un-ignore both `projects/*/memory` and
`shared_memory/*/memory` **without** a trailing slash, or the symlink itself is
dropped (a trailing-slash rule matches directories only).

## Notes

- `~/.claude/.credentials.json` is excluded — authenticate per machine via `claude login`.
- Project memory paths encode the absolute project path (e.g. `-home-you-git-myproject`). They load only on machines with matching directory layout — run `claude-memory-init.sh` (above) to share one store across differing layouts.
- Reference plugin scripts via `~/.claude/plugins/marketplaces/<plugin>/src/...`, never the cache path (hash varies per machine).
