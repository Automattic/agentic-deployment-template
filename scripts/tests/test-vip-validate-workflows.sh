#!/usr/bin/env bash
# Mutation tests for scripts/vip-validate-workflows.sh.
#
# Each case copies the repository, weakens one guardrail, and requires the
# validator to fail. A check that never fails is indistinguishable from a check
# that works, so every check here was watched failing at least once.
#
# Repository-only: setup.sh does not install this file.
#
# Usage: bash scripts/tests/test-vip-validate-workflows.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

fresh() {
  local d="$WORK/$1" f
  mkdir -p "$d"
  while IFS= read -r f; do
    mkdir -p "$d/$(dirname "$f")"
    cp "$ROOT/$f" "$d/$f"
  done < <(cd "$ROOT" && git ls-files -co --exclude-standard .github .claude scripts AGENTS.md README.md)
  printf '%s' "$d"
}

# expect <name> <0|1> <mutation command run inside the copy>
expect() {
  local name="$1" want="$2" mutate="$3" d out got
  d="$(fresh "$name")"
  if ! (cd "$d" && eval "$mutate"); then
    fail=$((fail + 1)); printf 'FAIL %-38s the mutation itself failed\n' "$name"; return
  fi
  out="$(cd "$d" && bash scripts/vip-validate-workflows.sh 2>&1)"; got=$?
  [[ "$got" -ne 0 ]] && got=1
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1)); printf 'PASS %-38s exit %s\n' "$name" "$got"
    # Name what fired, so a case that fails for the wrong reason is visible.
    [[ "$want" == 1 ]] && printf '%s\n' "$out" | grep -m1 $'\033\[0;31m' | perl -pe 's/\e\[[0-9;]*m//g; s/^ */      -> /' || true
  else
    fail=$((fail + 1)); printf 'FAIL %-38s expected exit %s, got %s\n' "$name" "$want" "$got"
    printf '%s\n' "$out" | tail -5 | sed 's/^/      /'
  fi
}

# In-place edit that must change the file, so a mutation cannot silently miss.
edit() {
  local file="$1" expr="$2" before
  before="$(cksum < "$file")"
  perl -0pi -e "$expr" "$file"
  [[ "$(cksum < "$file")" != "$before" ]]
}

# A minimal Codex job written into each copy, so the Codex cases do not depend
# on which workflows wire Codex in. It passes the validator as written.
FIXTURE=.github/workflows/vip-z-codex.yml
fixture() {
  cat > "$FIXTURE" <<'YAML'
name: fixture
on: workflow_dispatch
jobs:
  codex-agent:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - id: setup
        uses: ./.github/actions/vip-codex-run
        with:
          mode: implement
          tail: none
      - uses: openai/codex-action@bdf19a4a223ec2549a3e2274a0cf61556bc07675
        with:
          permission-profile: ':workspace'
          safety-strategy: drop-sudo
YAML
}
# The same for Gemini: settings taken from vip-gemini-run in the same job.
gemini_fixture() {
  cat > .github/workflows/vip-z-gemini.yml <<'YAML'
name: fixture
on: workflow_dispatch
jobs:
  gemini-agent:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      - id: setup
        uses: ./.github/actions/vip-gemini-run
        with:
          mode: implement
          tail: none
      - uses: google-github-actions/run-gemini-cli@f77273f4c914e4bf38440cf36a0369cb64a37489
        with:
          settings: ${{ steps.setup.outputs.settings }}
YAML
}
PUBLISH=.github/workflows/vip-agent-publish.yml
CLAUDE=.github/actions/vip-claude-run/action.yml
CODEX=.github/actions/vip-codex-run/action.yml
GEMINI=.github/actions/vip-gemini-run/action.yml

expect unmodified 0 'true'
expect codex-fixture-alone 0 'fixture'
expect gemini-fixture-alone 0 'gemini_fixture'

expect claude-allow-curl         1 "edit $CLAUDE 's/\"Bash\\(jq \\*\\)\",/\"Bash(jq *)\",\n                \"Bash(curl *)\",/'"
expect composite-reads-vars      1 "edit $CLAUDE 's/show_full_output: \\\$\\{\\{ inputs.debug == .true. \\}\\}/show_full_output: \\\${{ vars.AGENT_DEBUG == \"true\" }}/'"
expect agent-timeout-15          1 "fixture && edit $FIXTURE 's/timeout-minutes: 30/timeout-minutes: 15/'"
expect codex-danger-full-access  1 "fixture && edit $FIXTURE \"s/permission-profile: ':workspace'/permission-profile: ':danger-full-access'/\""
expect codex-safety-unsafe       1 "fixture && edit $FIXTURE 's/safety-strategy: drop-sudo/safety-strategy: unsafe/'"
expect codex-allow-rule          1 "edit $CODEX 's/decision=\"forbidden\", justification=\"A separate trusted step publishes changes.\"\\)\n        RULES/decision=\"allow\", justification=\"x\")\n        RULES/'"
expect gemini-shell-tool         1 "edit $GEMINI 's/\"core\":\\[\"read_file\"/\"core\":[\"run_shell_command\",\"read_file\"/'"
expect gemini-no-core            1 "edit $GEMINI 's/\"tools\":\\{\"core\":\\[[^\\]]*\\]\\},//'"
expect gemini-settings-moved     1 "gemini_fixture && edit $GEMINI \"s/settings='\\{/settings=\\\"\\{/; s/\\}'\\n/}\\\"\\n/\""
expect publish-no-timeout        1 "edit $PUBLISH 's/\n    timeout-minutes: 10\n/\n/'"
expect publish-interpolates      1 "edit $PUBLISH 's/(      - name: Prepare\n        run: )echo/\${1}echo \"\\\${{ inputs.head_ref }}\" \\&\\& echo/'"
expect local-action-missing      1 "fixture && edit $FIXTURE 's|uses: ./.github/actions/vip-codex-run|uses: ./.github/actions/vip-nope|'"
expect local-action-not-installed 1 "fixture && mkdir -p .github/actions/vip-extra && cp $CODEX .github/actions/vip-extra/action.yml && edit $FIXTURE 's|uses: ./.github/actions/vip-codex-run|uses: ./.github/actions/vip-extra|'"
expect gemini-web-fetch          1 "edit $GEMINI 's/\"core\":\\[\"read_file\"/\"core\":[\"web_fetch\",\"read_file\"/'"
expect gemini-step-no-settings   1 "printf 'name: y\non: push\njobs:\n  g:\n    runs-on: ubuntu-latest\n    timeout-minutes: 30\n    steps:\n      - uses: google-github-actions/run-gemini-cli@v0\n        with:\n          prompt: hi\n' > .github/workflows/vip-y.yml"
expect gemini-settings-elsewhere 1 "printf 'name: y\non: push\njobs:\n  g:\n    runs-on: ubuntu-latest\n    timeout-minutes: 30\n    steps:\n      - id: mine\n        run: echo settings={} >> \$GITHUB_OUTPUT\n      - uses: google-github-actions/run-gemini-cli@v0\n        with:\n          settings: \${{ steps.mine.outputs.settings }}\n' > .github/workflows/vip-y.yml"
expect codex-legacy-sandbox      1 "fixture && edit $FIXTURE 's/( +)safety-strategy: drop-sudo/\${1}sandbox: workspace-write\n\${1}safety-strategy: drop-sudo/'"
expect codex-network-access      1 "edit $CODEX 's/(        mkdir -p \"\\\$dir\\/home\\/rules\" \"\\\$out\"\n)/\${1}        echo \"network_access = true\" >> \"\\\$dir\\/home\\/config.toml\"\n/'"
expect publish-env-interpolation 1 "edit $PUBLISH 's/(      - name: Prepare\n        run: )echo/\${1}echo \"\\\${{ env.HEAD_REF }}\" \\&\\& echo/'"
expect workflow-approves-pr      1 "printf 'name: x\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |\n          gh pr review 1 --approve\n' > .github/workflows/vip-x.yml"

echo ""
echo "passed: $pass  failed: $fail"
[[ "$fail" -eq 0 ]]
