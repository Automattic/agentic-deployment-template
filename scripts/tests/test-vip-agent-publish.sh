#!/usr/bin/env bash
# Tests the snapshot validation in .github/workflows/vip-agent-publish.yml (R11).
#
# The Python is read out of the workflow itself, so this tests the code that
# ships. Each case builds a workspace from a fixture repository, makes the
# snapshot exactly as an agent job does, and checks the verdict. Attacks come
# first: each must be rejected before anything is staged.
#
# Needs GNU tar (gtar on macOS): the agent jobs run on Linux, and BSD tar adds
# AppleDouble files and drops nested .git directories, which changes the result.
#
# Repository-only: setup.sh does not install this file.
#
# Usage: bash scripts/tests/test-vip-agent-publish.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TAR=tar
command -v gtar >/dev/null 2>&1 && TAR=gtar
if ! "$TAR" --version 2>/dev/null | grep -q 'GNU tar'; then
  echo "GNU tar is required (brew install gnu-tar on macOS)." >&2
  exit 1
fi

# Extract the validator from the workflow with whichever YAML parser exists.
if python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$ROOT/.github/workflows/vip-agent-publish.yml" > "$WORK/validate.py" <<'PY'
import re, sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
step = next(s for s in doc["jobs"]["publish"]["steps"] if s.get("name") == "Validate the snapshot")
print(re.search(r"<<'PY'\n(.*?)\nPY", step["run"], re.S).group(1))
PY
else
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
step = doc["jobs"]["publish"]["steps"].find { |s| s["name"] == "Validate the snapshot" }
puts step["run"][/<<.PY.\n(.*?)\nPY/m, 1]
' "$ROOT/.github/workflows/vip-agent-publish.yml" > "$WORK/validate.py"
fi
[[ -s "$WORK/validate.py" ]] || { echo "Could not extract the validator." >&2; exit 1; }

# The repository the agent started from.
git init -q "$WORK/base"
(
  cd "$WORK/base"
  git config user.email test@example.com; git config user.name test
  mkdir -p src vendor .github/workflows
  echo a > src/a.js; echo b > src/b.js; echo keep > README.md
  echo wf > .github/workflows/ci.yml
  echo 'EXAMPLE=1' > .env.example
  ln -s README.md CLAUDE.md
  head -c 2000000 /dev/urandom > vendor/big.bin
  printf 'docs/plans/\nnode_modules/\nignored/\n' > .gitignore
  # Tracked although .gitignore matches it: edits must still publish.
  mkdir -p ignored && echo tracked > ignored/tracked.txt
  git add -A; git add -f ignored/tracked.txt
  # A submodule: a gitlink and, as in an uncloned checkout, an empty directory.
  git update-index --add --cacheinfo "160000,$(git hash-object -t blob /dev/null),vendor/lib"
  mkdir -p vendor/lib
  git commit -qm base
)

pass=0; fail=0

# check <name> <expected verdict> <mode> <workspace changes> [plan path]
check() {
  local name="$1" expect="$2" mode="$3" setup="$4" plan="${5:-}"
  local d="$WORK/cases/$name" got
  mkdir -p "$d/out" "$d/staging"
  cp -a "$WORK/base" "$d/ws"
  # What the agent job does before the agent runs.
  (cd "$d/ws" && find . -path ./.git -prune -o \( -name '.env*' -o -name .codex -o -name .agents -o -name .gemini \) -prune -print0 | xargs -0 -r rm -rf --)
  (cd "$d/ws" && eval "$setup") >/dev/null 2>&1
  "$TAR" --anchored --exclude=./.git -C "$d/ws" -czf "$d/snapshot.tgz" .
  MODE="$mode" PLAN_PATH="$plan" KEY_SCAN="${KEY_SCAN:-n/a}" PROVIDER="${PROVIDER:-openai-codex}" \
    python3 -I "$WORK/validate.py" "$d/snapshot.tgz" "$WORK/base" "$d/staging" "$d/out" > "$d/log" 2>&1
  got="$(cat "$d/out/verdict" 2>/dev/null || echo ERROR)"
  if [[ "$got" == "$expect" ]]; then
    pass=$((pass + 1)); printf 'PASS %-24s %-8s %s\n' "$name" "$got" "$(cat "$d/out/reason" 2>/dev/null)"
  else
    fail=$((fail + 1)); printf 'FAIL %-24s expected %s, got %s\n' "$name" "$expect" "$got"; sed 's/^/      /' "$d/log"
  fi
  # A rejected snapshot stages nothing.
  if [[ "$expect" == reject && -n "$(ls -A "$d/staging")" ]]; then
    fail=$((fail + 1)); printf 'FAIL %-24s rejected, but files were staged\n' "$name"
  fi
}

# expect_list <name> <list> <exact space-separated contents>
expect_list() {
  local got; got="$(tr '\n' ' ' < "$WORK/cases/$1/out/$2.txt" 2>/dev/null | sed 's/ $//')"
  if [[ "$got" == "$3" ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL %-24s %s: expected [%s], got [%s]\n' "$1" "$2" "$3" "$got"; fi
}

# Attacks: each must be rejected.
check symlink-new        reject implement 'mkdir -p docs/plans && ln -s /home/runner/.credentials docs/plans/x-plan.md'
check symlink-retarget   reject implement 'rm CLAUDE.md && ln -s /proc/self/environ CLAUDE.md'
check nested-git         reject implement 'mkdir -p sub/.git && printf "[core]\n\tfsmonitor = touch /tmp/pwned\n" > sub/.git/config'
check hardlink           reject implement 'echo x > src/c.js && ln src/c.js src/d.js'
check fifo               reject implement 'mkfifo src/pipe'
check gitmodules         reject implement 'printf "[submodule \"x\"]\n\tpath = x\n\turl = https://example.com/x\n" > .gitmodules'
check file-over-50mb     reject implement 'head -c 52428801 /dev/zero > src/huge.bin'
KEY_SCAN=fail check key-scan-failed reject implement 'echo y >> src/a.js'
PROVIDER=gemini KEY_SCAN=n/a check gemini-unscanned reject implement 'echo y >> src/a.js'
PROVIDER=gemini KEY_SCAN=failure check gemini-scan-crashed reject implement 'echo y >> src/a.js'
check name-backtick      reject implement 'echo x > "src/a\`b.js"'
check name-newline       reject implement 'echo x > "src/a
b.js"'
check name-leading-quote reject implement 'echo x > "\"quoted.js"'

# Refused and flagged paths.
check refused-paths      ok implement 'echo y >> src/a.js; echo x > .github/workflows/x.yml; echo "* @me" > CODEOWNERS; mkdir -p .claude && echo "{}" > .claude/settings.json; echo S=1 > .env.local'
expect_list refused-paths changed "src/a.js"
expect_list refused-paths refused ".claude/settings.json .github/workflows/x.yml CODEOWNERS"
check flagged-agents     ok implement 'echo guidance > AGENTS.md; echo y >> src/a.js'
expect_list flagged-agents flagged "AGENTS.md"
check delete-workflow    ok implement 'rm .github/workflows/ci.yml; echo y >> src/b.js'
expect_list delete-workflow deleted ""
expect_list delete-workflow refused ".github/workflows/ci.yml"

# Ordinary work.
check edits-and-delete   ok implement 'echo y >> src/a.js; echo z > src/new.js; rm src/b.js'
expect_list edits-and-delete changed "src/a.js src/new.js"
expect_list edits-and-delete deleted "src/b.js"
check scrub-is-silent    ok implement 'echo y >> src/a.js'
expect_list scrub-is-silent deleted ""
expect_list scrub-is-silent refused ""
check nothing            nothing implement ':'
expect_list nothing deleted ""
PROVIDER=gemini KEY_SCAN=pass check gemini-scanned ok implement 'echo y >> src/a.js'
check tracked-ignored    ok implement 'echo more >> ignored/tracked.txt'
expect_list tracked-ignored changed "ignored/tracked.txt"
check ignored-only       nothing implement 'mkdir -p node_modules && head -c 1000 /dev/zero > node_modules/x'
check ignored-big        ok implement 'mkdir -p node_modules && head -c 62914560 /dev/zero > node_modules/big; echo y >> src/a.js'
check plan-written       ok plan 'mkdir -p docs/plans && echo "# plan" > docs/plans/2026-01-01-001-plan.md; echo stray >> src/a.js'
expect_list plan-written changed "docs/plans/2026-01-01-001-plan.md"
check plan-missing       nothing plan 'echo stray >> src/a.js'
check approved-plan-only nothing implement 'mkdir -p docs/plans && echo "# plan" > docs/plans/p.md' docs/plans/p.md
check approved-plan-code ok implement 'mkdir -p docs/plans && echo "# plan" > docs/plans/p.md; echo y >> src/a.js' docs/plans/p.md

echo ""
echo "passed: $pass  failed: $fail"
[[ "$fail" -eq 0 ]]
