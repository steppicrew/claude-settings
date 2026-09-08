# claude-settings

This is the public sync tooling repo. Personal Claude Code configuration lives in a separate private config repo under `config/`.

## Scripts

- `sync.sh` (alias `claude-sync`) — pull/push the active config repo, restore plugins.
- `install-alias.sh` — install both aliases into shell rc files; idempotent, appends only missing ones.
- `claude-memory-init.sh` (alias `claude-memory-init`) — share a repo's Claude auto-memory across machines whose checkout paths/dir-names differ. Derives a stable store name from the repo's sanitized full git remote URL, keeps the real memory in `config/current/shared_memory/<name>/memory/`, and points each machine's path-keyed `memory/` at it via a relative symlink. Merges existing memory on first run; on a non-trivial merge it preserves dropped copies as `<file>.incoming` and writes `MERGE-REQUEST.md` for a Claude-driven semantic reconcile. Run once per machine per scope. See README for details.
  - **Subdirectory scopes:** Claude keys memory by its launch CWD, not the repo root, so `<repo>/backend/` is its own scope. Run the script there to get a `<remote-name>--backend` store (subpath is repo-relative → stable across machines). Root and subdirs are separate stores; they do not share memory.
- `claude-memory-scan.sh` (alias `claude-memory-scan`) — sweep `~/.claude/projects/` for scopes whose `memory/` is still a real dir (never shared) and classify them: **shareable** (path exists here and is in a git repo), **not a git repo** (reported with a `--name` command; no derivable name would be stable across machines), **skipped** (path absent — another machine's scope, arrived via config sync; counted only, never deleted). Report-only by default; `--link` shares the shareable ones, `--ask` prompts. `sync.sh` runs it with `--ask --quiet` before committing. See README.

## Memory-sharing invariants (do not break)

- The config repo's `.gitignore` must un-ignore `projects/*/memory`, `shared_memory/*/memory`, and their `**` **without** a trailing slash — a trailing-slash rule matches directories only and silently drops the tracked symlinks.
- Empty shared stores carry a `.gitkeep` so they survive clone and the symlink never dangles.
- Symlinks are relative and point within the config repo; never rewrite them as absolute paths.
- Store dirs stay **flat** under `shared_memory/` (depth 1). Subdirectory scopes encode the subpath in the *name* (`<remote>--services-api`), never as nested dirs — nesting would break the un-ignore rules above and the relative-symlink fallback.
- The `--` subpath separator survives only because the suffix is appended *after* `derive_name`'s `tr -s '-'` squeeze. Reordering those collapses it to `-` and lets subdir stores collide.
- Path-key → path is **ambiguous and must stay search-based**. Claude folds both `/` and `.` to `-`, and one directory name can span several key segments (`claude-settings` is two), so a greedy left-to-right walk cannot invert it. `claude-memory-scan.sh` backtracks over the filesystem, longest match first; every split is confirmed by a directory that exists. Never "simplify" this to a plain `tr '-' '/'`.
- A scope whose path is **missing** is not stale — it is another machine's, synced in. Never offer to delete it; that would drop the other machine's memory.
- The path-key must come from the **physical** (symlink-resolved) path. Claude keys projects by the real path, not the shell's logical `$PWD` — with `~/git` → `~/workspace/git`, a session started via `~/git/foo` is keyed `-home-user-workspace-git-foo`. Using the logical path writes a symlink at a key Claude never reads.

## Config-sync invariants (do not break)

The config repo's `.gitignore` is **deny-by-default** (`*`), so anything without an
explicit `!` rule silently never syncs. The breakage never shows up on the machine
that made the change — only on the *other* machine, as a hook pointing at a missing
file or a skill that never loads.

- **Every new root-level script needs its own `!name.sh` line.** This bit twice:
  `block-remote-shell.sh` (a live `PreToolUse` hook named in `settings.json`) was
  untracked, so the ssh-permission policy silently did not apply on the other machine.
- **Skills are tracked whole, via `!skills/**`** — not just `SKILL.md`. Skills ship
  helper scripts next to it (`browser.mjs`, `game.mjs`, `engines.md`); an allowlist
  naming only `SKILL.md` drops those and the skill breaks with no error.
- **A skill must be a real directory, never a symlink to one outside the config repo.**
  Git stores only the link text, which dangles wherever the target is absent. Two
  skills were symlinks into `~/.codegpt/skills/`; they are now real dirs. Note this is
  the opposite rule from memory dirs, whose symlinks point *within* the repo and are
  tracked deliberately.
- **`!skills/*/` matches directories only**, so it excludes a symlinked skill before
  any deeper rule is considered — the same trailing-slash trap as the memory rules.
- `sync.sh`'s `check_untracked_config` enforces all of this before each commit: it
  cross-checks scripts named in `settings.json` hook/`statusLine` commands, plus every
  file under `skills/`, against `git ls-files`, and warns about any that are untracked.
  It is report-only and never blocks a sync.

## Git

- All commit messages must use conventional prefixes: `feat`, `fix`, `chore`, `fixup`, `refactor`, `docs`, `test`, etc.
- Format: `<prefix>: <short description>` (lowercase prefix)
- Do NOT add `Co-Authored-By` trailers to commit messages
