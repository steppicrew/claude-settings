# claude-settings

This is the public sync tooling repo. Personal Claude Code configuration lives in a separate private config repo under `config/`.

## Scripts

- `sync.sh` (alias `claude-sync`) — pull/push the active config repo, restore plugins.
- `install-alias.sh` — install both aliases into shell rc files; idempotent, appends only missing ones.
- `claude-memory-init.sh` (alias `claude-memory-init`) — share a repo's Claude auto-memory across machines whose checkout paths/dir-names differ. Derives a stable store name from the repo's sanitized full git remote URL, keeps the real memory in `config/current/shared_memory/<name>/memory/`, and points each machine's path-keyed `memory/` at it via a relative symlink. Merges existing memory on first run; on a non-trivial merge it preserves dropped copies as `<file>.incoming` and writes `MERGE-REQUEST.md` for a Claude-driven semantic reconcile. Run once per machine per scope. See README for details.
  - **Subdirectory scopes:** Claude keys memory by its launch CWD, not the repo root, so `<repo>/backend/` is its own scope. Run the script there to get a `<remote-name>--backend` store (subpath is repo-relative → stable across machines). Root and subdirs are separate stores; they do not share memory.

## Memory-sharing invariants (do not break)

- The config repo's `.gitignore` must un-ignore `projects/*/memory`, `shared_memory/*/memory`, and their `**` **without** a trailing slash — a trailing-slash rule matches directories only and silently drops the tracked symlinks.
- Empty shared stores carry a `.gitkeep` so they survive clone and the symlink never dangles.
- Symlinks are relative and point within the config repo; never rewrite them as absolute paths.
- Store dirs stay **flat** under `shared_memory/` (depth 1). Subdirectory scopes encode the subpath in the *name* (`<remote>--services-api`), never as nested dirs — nesting would break the un-ignore rules above and the relative-symlink fallback.
- The `--` subpath separator survives only because the suffix is appended *after* `derive_name`'s `tr -s '-'` squeeze. Reordering those collapses it to `-` and lets subdir stores collide.
- The path-key must come from the **physical** (symlink-resolved) path. Claude keys projects by the real path, not the shell's logical `$PWD` — with `~/git` → `~/workspace/git`, a session started via `~/git/foo` is keyed `-home-user-workspace-git-foo`. Using the logical path writes a symlink at a key Claude never reads.

## Git

- All commit messages must use conventional prefixes: `feat`, `fix`, `chore`, `fixup`, `refactor`, `docs`, `test`, etc.
- Format: `<prefix>: <short description>` (lowercase prefix)
- Do NOT add `Co-Authored-By` trailers to commit messages
