#!/bin/sh
# Fast checks run by the global Stop hook (~/.agents/hooks/verify-stop.sh) when an agent finishes: compile or typecheck
# only for the kinds of files that changed. Tests stay with the agent (CLAUDE.md "Verification") and CI.
CHANGED=$( (git diff HEAD --name-only; git ls-files -o --exclude-standard) 2>/dev/null)
has() { printf "%s\n" "$CHANGED" | grep -E -q "$1"; }
run() { OUT=$("$@" 2>&1) || { printf "%s\n" "$OUT" | grep -v "^Note:" | tail -30; exit 1; }; }
changed() { printf "%s\n" "$CHANGED" | grep -E "$1" | while IFS= read -r f; do [ -f "$f" ] && printf "%s\n" "$f"; done; }
has '\.py$' && run python3 -B -c 'import ast, sys; [ast.parse(open(f, encoding="utf-8").read(), f) for f in sys.argv[1:]]' $(changed '\.py$')
if has '^shaders/'; then run python3 tools/validate_shaderpack.py; fi
exit 0
