#!/bin/bash
#
# pre-commit hook for the CONFIG repo (~/.claude), installed by sync.sh.
#
# Why this exists: the config repo's .gitignore is deny-by-default ("*"), so a
# new script that nobody adds a "!name.sh" rule for is silently never committed.
# Nothing fails here — it fails on the OTHER machine, where a hook in
# settings.json points at a file that does not exist. That happened to
# block-remote-shell.sh (the ssh-permission hook, so the policy quietly did not
# apply) and to two skills that shipped .mjs helpers.
#
# sync.sh's check_untracked_config catches files already known to be needed
# (named in settings.json, or under skills/). This hook covers the rest: a
# script whose fate has never been DECIDED either way. Every script must be
# either accepted (tracked, or matched by a specific "!" rule) or explicitly
# denied (matched by a rule naming it, not the blanket "*").
#
# Not a nag: to deny a script, add a rule that names it, e.g.
#     scratch-*.sh          # local-only experiments
# The hook then stays quiet, because the decision is now recorded in-repo and
# travels to the other machine.
#
# SCOPE: only where config actually lives. ~/.claude is Claude Code's live
# working directory — jobs/, debug/, file-history/ and friends churn with
# throwaway scripts every session, and the blanket "*" denies them correctly.
# Demanding a decision about those would be noise that trains you to ignore the
# hook. Root-level scripts plus the four dirs that hold tracked config are the
# only places the invariant means anything.
#
# Bypass for a one-off with --no-verify, or set CLAUDE_SYNC_SKIP_SCRIPT_CHECK=1.

set -uo pipefail

[ "${CLAUDE_SYNC_SKIP_SCRIPT_CHECK:-0}" = "1" ] && exit 0

repo_root="$(git rev-parse --show-toplevel)" || exit 0
cd "$repo_root" || exit 0

undecided=()

# Every script-like file in the working tree that git is not tracking.
while IFS= read -r f; do
    [ -n "$f" ] || continue
    git ls-files --error-unmatch "$f" >/dev/null 2>&1 && continue

    # Which .gitignore rule claims it? A specific rule (e.g. "!foo.sh" or
    # "scratch-*.sh") is a decision. The catch-all "*" is not.
    rule="$(git check-ignore -v --no-index "$f" 2>/dev/null | awk -F'\t' '{print $1}')"
    pattern="${rule##*:}"

    if [ -z "$rule" ]; then
        # Not ignored and not tracked: it would be committed by `git add .`,
        # but nobody has staged it. Undecided.
        undecided+=("$f  (untracked, not ignored)")
    elif [ "$pattern" = "*" ]; then
        undecided+=("$f  (swallowed by the catch-all '*')")
    fi
done < <({
            # Root-level scripts (hooks, statusline, helpers).
            find . -maxdepth 1 -type f \
                \( -name '*.sh' -o -name '*.mjs' -o -name '*.js' -o -name '*.py' \) \
                -print 2>/dev/null
            # Dirs that hold tracked config. NOT the runtime scratch dirs.
            for d in skills plugins projects shared_memory; do
                [ -d "$d" ] || continue
                find "$d" -type f \
                    \( -name '*.sh' -o -name '*.mjs' -o -name '*.js' -o -name '*.py' \) \
                    -print 2>/dev/null
            done
        } | sed 's|^\./||' | sort -u)

[ ${#undecided[@]} -eq 0 ] && exit 0

echo "" >&2
echo "pre-commit: these scripts have no explicit fate in .gitignore:" >&2
echo "" >&2
for f in "${undecided[@]}"; do
    echo "    $f" >&2
done
echo "" >&2
echo "Each will be MISSING on your other machines. Decide, then re-commit:" >&2
echo "  keep  ->  add  '!<name>'  to .gitignore  (and git add it)" >&2
echo "  drop  ->  add  a rule naming it, e.g. 'scratch-*.sh'" >&2
echo "" >&2
echo "Bypass once: git commit --no-verify" >&2
echo "" >&2
exit 1
