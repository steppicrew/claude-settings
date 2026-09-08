#!/bin/bash
#
# test-config-sync.sh — assert every file the active config REFERENCES is
# actually tracked by git, and so will exist on the other machine.
#
# This is the on-demand counterpart to the two automatic guards:
#   - sync.sh's check_untracked_config runs before each sync (warns)
#   - the pre-commit hook runs before each commit (blocks)
# Both are triggered by an action. This one can be run any time, and asserts
# the whole current state rather than what a given commit happens to touch.
#
# Exit 0 = every reference resolves to a tracked file. Exit 1 = at least one
# would be missing on another machine.
#
# Usage: ./test-config-sync.sh [config_repo_dir]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${1:-$SCRIPT_DIR/config/current}"

if [ ! -d "$REPO/.git" ] && [ ! -f "$REPO/.git" ]; then
    echo "not a git repo: $REPO" >&2
    exit 2
fi
REPO="$(cd "$REPO" && pwd -P)"

pass=0 fail=0

ok()   { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL  %s\n' "$1" >&2; }

tracked() { git -C "$REPO" ls-files --error-unmatch "$1" >/dev/null 2>&1; }

echo "test-config-sync: $REPO"
echo

# ---------------------------------------------------------------- references
# Scripts named in settings.json hook / statusLine "command" strings.
echo "settings.json references:"
if [ -f "$REPO/settings.json" ] && command -v python3 >/dev/null 2>&1; then
    refs="$(python3 - "$REPO/settings.json" <<'PYEOF'
import json, re, sys
try:
    with open(sys.argv[1]) as fh: data = json.load(fh)
except Exception: sys.exit(0)
found = []
def walk(n):
    if isinstance(n, dict):
        for k, v in n.items():
            found.append(v) if k == "command" and isinstance(v, str) else walk(v)
    elif isinstance(n, list):
        for i in n: walk(i)
walk(data)
for cmd in found:
    for tok in re.findall(r'[\w$~/.-]+\.(?:sh|mjs|js|py)', cmd):
        tok = re.sub(r'^\$HOME/\.claude/|^~/\.claude/', '', tok.strip('"\''))
        if not tok.startswith(('/', '$', '~')): print(tok)
PYEOF
    )"
    if [ -z "$refs" ]; then
        echo "  (no script references found)"
    else
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if [ ! -e "$REPO/$f" ]; then
                bad "$f — referenced but does not exist on disk"
            elif tracked "$f"; then
                ok "$f"
            else
                bad "$f — exists but is NOT tracked (missing on other machines)"
            fi
        done <<< "$refs"
    fi
else
    echo "  (skipped: no settings.json or no python3)"
fi
echo

# ------------------------------------------------------------------- skills
# Every file inside a skill must travel, helper scripts included.
echo "skills/:"
if [ -d "$REPO/skills" ]; then
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        tracked "$f" && ok "$f" || bad "$f — not tracked"
    done < <(cd "$REPO" && find skills -type f | sort)

    # A skill that is a symlink out of the repo dangles on the other machine.
    while IFS= read -r l; do
        [ -n "$l" ] || continue
        bad "$l — symlinked skill; target will not exist on other machines"
    done < <(cd "$REPO" && find skills -maxdepth 1 -type l | sort)
else
    echo "  (no skills/ dir)"
fi
echo

# ------------------------------------------------------------------ summary
echo "-----------------------------------------"
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || {
    echo
    echo "Fix: add a matching '!' rule to $REPO/.gitignore and git add the file."
    exit 1
}
echo "All referenced files are tracked."
