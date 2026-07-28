# claude-settings

Public sync tooling for Claude Code configuration. Personal settings live in a separate private config repo.

## How it works

```
~/git/claude-settings/       ← this repo (public): sync tooling only
  sync.sh
  install-alias.sh
  claude-memory-init.sh
  config/
    personal/                ← private config repo (cloned via add-config)
      CLAUDE.md
      settings.json
      statusline.sh
      plugins/               ← manifests only (marketplaces/cache re-fetched)
      projects/
        <path-key>/memory/    ← real dir, or symlink into shared_memory/
      shared_memory/
        <remote-name>/memory/ ← name-keyed store shared across machines
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

# 4. Add the shell aliases (claude-sync, claude-memory-init)
~/git/claude-settings/install-alias.sh
source ~/.bash_aliases   # bash
# source ~/.zshrc        # zsh
```

`install-alias.sh` is idempotent and adds both `claude-sync` and
`claude-memory-init`. Re-run it after pulling an update that introduces a new
alias — it appends only what's missing. Or add them by hand:

```bash
alias claude-sync='~/git/claude-settings/sync.sh'
alias claude-memory-init='~/git/claude-settings/claude-memory-init.sh'
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
| `statusline.sh` | Custom status line script |
| `plugins/installed_plugins.json` | Which plugins are installed |
| `plugins/known_marketplaces.json` | Registered plugin marketplaces |
| `plugins/blocklist.json` | Blocked plugins |
| `projects/*/memory/` | Per-project auto-memory — real dir, or symlink into `shared_memory/` |
| `shared_memory/*/memory/` | Name-keyed memory stores shared across machines (see below) |

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
claude-memory-init --dry-run         # preview name + actions
claude-memory-init                   # create/link the shared store (merges any
                                     # existing path-keyed memory into it first)
claude-memory-init --name foo        # override the derived name (disambiguate)
claude-sync                          # commit + push the result
```

(Use `~/git/claude-settings/claude-memory-init.sh` directly if you haven't
installed the alias.) On a **new machine**: clone the config, checkout the repo,
run `claude-memory-init` in it — the symlink is recreated pointing at the
already-synced `shared_memory/<name>`. No manual pairing.

### Subdirectory scopes (monorepos)

Claude keys memory by the directory it was **launched in**, not by the repo root.
Open it in `<repo>/backend/` and that subdirectory gets its own path-key and its
own memory — so a repo can have several independent memory scopes.

Run the script from the subdirectory (or pass `--repo <repo>/backend`) to give
such a scope a shared store. The name gains a `--<subpath>` suffix:

```bash
cd ~/path/to/monorepo/backend
claude-memory-init                   # → <remote-name>--backend

cd ~/path/to/monorepo/services/api
claude-memory-init                   # → <remote-name>--services-api
```

The subpath is **repo-relative**, so it is identical on machines whose checkouts
live at different absolute paths or under different directory names — the same
property that makes the repo-root case work. Store dirs stay flat under
`shared_memory/`, so the `.gitignore` rules are unaffected.

Run it once per machine **per subdirectory you actually open Claude in**. A repo
root and its subdirectories are **separate stores** and do not share memory with
each other — pick the scope you want memory to live at. `--name` overrides the
whole name, suffix included.

Nested repos are not subdirectories: if the target dir has its own `.git`, its
own remote decides the name and no suffix is added.

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
