#!/usr/bin/env bash
# Parses every workflow file under .github/workflows/ and fails if any of them
# is not valid YAML.
#
# Usage:
#   bash scripts/vip-validate-workflows.sh [directory]
#
# Why this exists:
#   A workflow file that does not parse does not fail loudly. GitHub cannot
#   schedule a job it could not read, so the run ends in seconds with no jobs
#   and no log — which reads as a broken command rather than a broken file.
#
#   The usual cause is an unquoted ": " inside a run: line, because a plain YAML
#   scalar containing a colon followed by a space is a mapping, not a string:
#
#     run: echo $(( x > 0 ? 1 : 0 ))      # breaks
#     run: git commit -m "fix: thing"     # breaks too — quotes do not help,
#                                         # the outer scalar is still plain
#
#   Both are lines an agent could reasonably write. A block scalar makes the
#   colon just a character:
#
#     run: |
#       git commit -m "fix: thing"
#
# Exits 0 when every file parses, 1 otherwise.

set -euo pipefail

WORKFLOW_DIR="${1:-.github/workflows}"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

if [[ ! -d "$WORKFLOW_DIR" ]]; then
  dim "No $WORKFLOW_DIR directory — nothing to validate."
  exit 0
fi

# Pick a YAML parser. Both are stdlib-or-common: PyYAML on the GitHub runners,
# Psych with every Ruby. Checked by actually importing, because "python3 exists"
# and "python3 can parse YAML" are different claims.
PARSER=""
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  PARSER="python"
elif command -v ruby >/dev/null 2>&1 && ruby -ryaml -e '' >/dev/null 2>&1; then
  PARSER="ruby"
else
  red "Error: no YAML parser available."
  red "       Install PyYAML (pip install pyyaml) or make ruby available."
  exit 1
fi

parse_file() {
  local file="$1"
  if [[ "$PARSER" == "python" ]]; then
    python3 -c '
import sys, yaml
try:
    with open(sys.argv[1]) as handle:
        yaml.safe_load(handle)
except Exception as err:
    print(err, file=sys.stderr)
    sys.exit(1)
' "$file"
  else
    # Psych 4 refuses aliases unless asked; Psych 3 does not know the keyword.
    # Workflows may legitimately use anchors, so try the permissive call first.
    ruby -ryaml -e '
begin
  begin
    YAML.load_file(ARGV[0], aliases: true)
  rescue ArgumentError
    YAML.load_file(ARGV[0])
  end
rescue => err
  warn err.message
  exit 1
end
' "$file"
  fi
}

# The same document as JSON, for checks that need structure rather than lines.
# jq does the selecting, so neither parser needs its own copy of the logic.
to_json() {
  local file="$1"
  if [[ "$PARSER" == "python" ]]; then
    python3 -c '
import sys, json, yaml
with open(sys.argv[1]) as handle:
    json.dump(yaml.safe_load(handle), sys.stdout, default=str)
' "$file"
  else
    ruby -ryaml -rjson -e '
doc = begin
  YAML.load_file(ARGV[0], aliases: true)
rescue ArgumentError
  YAML.load_file(ARGV[0])
end
print JSON.generate(doc)
' "$file"
  fi
}

# Every workflow and every composite action: the allow lists and guards live in both.
all_yaml() {
  { find "$WORKFLOW_DIR" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null
    find .github/actions -mindepth 2 -maxdepth 2 -type f -name 'action.yml' 2>/dev/null; } | sort
}

failed=0
checked=0

while IFS= read -r file; do
  checked=$((checked + 1))
  if error="$(parse_file "$file" 2>&1)"; then
    green "  ok: $file"
  else
    failed=$((failed + 1))
    red   "  FAILED TO PARSE: $file"
    printf '%s\n' "$error" | sed 's/^/      /'
  fi
done < <(all_yaml)

echo ""

if [[ "$checked" -eq 0 ]]; then
  dim "No workflow files found in $WORKFLOW_DIR."
  exit 0
fi

if [[ "$failed" -gt 0 ]]; then
  red "$failed of $checked workflow file(s) do not parse."
  red "A workflow that does not parse produces a run with no jobs and no log."
  red "If the problem is a colon in a run: line, use a block scalar:"
  red ""
  red "    run: |"
  red "      your command here"
  exit 1
fi

green "All $checked workflow file(s) parse."

# ── Permission guard ──────────────────────────────────────────────────────────
# Every allow list in this repo is hand-maintained, duplicated across four
# call sites, and security-relevant: the issue body is untrusted input that
# reaches the model as instructions, so anything allowed is reachable by
# whoever can get an issue labelled.
#
# Nothing else catches a widened list. A green build looks identical either
# way, and the comment above each list is advisory text a hurried editor
# reads past. This is the check that makes the boundary hold.
#
# git and gh are deliberately absent from the denylist: the agent cannot
# commit or open a pull request without them. That is a known, documented
# exception, not an oversight — see docs/AGENTIC_DEVELOPMENT.md.

DENIED_PATTERN='(find|xargs|curl|wget|nc|ssh|eval|sh|bash|zsh|python|python3|node|perl|ruby|php|env|chmod)'

check_permissions() {
  local found=0

  # Bash(<cmd> ...) entries inside any "allow" array, from the workflows and
  # from .claude/settings.json, which ships with the template and is read by
  # the agent at runtime.
  # Follow the allow list wherever it lives. It moved out of the workflows and
  # into .github/actions/vip-claude-run/action.yml when the block was extracted, and
  # a check that only scanned .github/workflows/ passed vacuously the moment it
  # moved — verified by injecting Bash(curl *) into the composite action and
  # watching this script report clean.
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(all_yaml)
  [[ -f ".claude/settings.json" ]] && files+=(".claude/settings.json")

  for f in "${files[@]}"; do
    # Only look inside allow arrays; deny arrays legitimately name these.
    local offenders
    # Only a wildcard or bare invocation is dangerous. A pinned command with
    # its own arguments — "Bash(bash scripts/vip-validate-workflows.sh)" — grants
    # exactly one thing and is fine; flagging it would make this check fail on
    # its own repository.
    offenders="$(awk '
      /"allow"[[:space:]]*:/ { inallow=1; next }
      /"deny"[[:space:]]*:/  { inallow=0 }
      /\]/                   { inallow=0 }
      inallow && /"Bash\(/    { print }
    ' "$f" | grep -oE '"Bash\('"$DENIED_PATTERN"'( \*)?\)' || true)"

    if [[ -n "$offenders" ]]; then
      found=1
      red "  DENIED PATTERN in $f:"
      printf '%s\n' "$offenders" | sed 's/^/      /'
    fi
  done

  if [[ "$found" -gt 0 ]]; then
    echo ""
    red "An allow list grants arbitrary execution or network egress."
    red "The issue body is untrusted input; anything allowed is reachable by"
    red "whoever can get an issue labelled. Use the narrowest pattern that"
    red "works — \"Bash(npm test)\" beats \"Bash(npm *)\"."
    return 1
  fi

  green "No arbitrary-execution or egress patterns in any allow list."
  return 0
}

check_permissions || exit 1

# ── Timeout parity ────────────────────────────────────────────────────────────
# The 30-minute cap could not move into the composite action: GitHub Actions
# ignores timeout-minutes on a step inside one. So it stays duplicated per job,
# and duplication is what this file exists to police. A job that quietly drops
# back to the 15-minute default kills real work mid-verification and reports a
# cancellation, not a failure.

check_timeouts() {
  local expected="30" bad=0 f
  if ! command -v jq >/dev/null 2>&1; then
    red "  jq is required for the timeout check."
    return 1
  fi
  # An agent job is any job with a step that runs an agent: one of the
  # vip-*-run actions or a provider action used directly. Matching jobs, not
  # files, so a short preflight job in the same file is not held to 30.
  local agent_re='vip-[a-z]+-run|claude-code-action|openai/codex-action|run-gemini-cli'
  while IFS= read -r f; do
    while IFS=$'\t' read -r job val; do
      [[ -z "$job" ]] && continue
      if [[ "$val" != "$expected" ]]; then
        red "  timeout-minutes: ${val:-unset} on job $job in $f (expected $expected)"
        bad=1
      fi
    done < <(to_json "$f" | jq -r --arg re "$agent_re" '
      (.jobs // {}) | to_entries[]
      | select([.value.steps[]?.uses // "" | test($re)] | any)
      | "\(.key)\t\(.value["timeout-minutes"] // "")"')
  done < <(find "$WORKFLOW_DIR" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)

  if [[ "$bad" -gt 0 ]]; then
    echo ""
    red "Agent jobs disagree on timeout-minutes."
    red "A real feature took 20m25s against a 15-minute cap and was killed"
    red "mid-verification. Keep every agent job at $expected."
    return 1
  fi
  green "Agent job timeouts agree ($expected minutes)."
  return 0
}

check_timeouts || exit 1

# ── Composite action contexts ─────────────────────────────────────────────────
# A composite action cannot read the `vars` or `secrets` contexts. Unlike most
# mistakes, this one is not a runtime warning: GitHub refuses to load the whole
# action ("Unrecognized named-value: 'vars'"), so every agent run fails before
# the agent starts. It shipped once — `show_full_output: ${{ vars.AGENT_DEBUG }}`
# in vip-claude-run — and broke every Claude run. Pass these in as inputs.

check_action_contexts() {
  local bad=0 f hits
  while IFS= read -r f; do
    hits="$(grep -nE '\$\{\{[^}]*\b(vars|secrets)\.' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
    if [[ -n "$hits" ]]; then
      red "  vars/secrets context in composite action $f:"
      printf '%s\n' "$hits" | sed 's/^/      /'
      bad=1
    fi
  done < <(find .github/actions -mindepth 2 -maxdepth 2 -type f -name 'action.yml' 2>/dev/null | sort)

  if [[ "$bad" -gt 0 ]]; then
    echo ""
    red "Composite actions cannot read vars or secrets; GitHub fails to load the"
    red "action at all. Add an input and have each caller pass the value."
    return 1
  fi
  green "No composite action reads the vars or secrets context."
  return 0
}

check_action_contexts || exit 1

# ── Provider guardrails ───────────────────────────────────────────────────────
# Codex and Gemini are bounded by how they are invoked, not by an allow list,
# so the invocation is what has to hold. A widened sandbox or a shell tool looks
# exactly like a working setup until an issue body asks the agent to use it.

# Every step in a workflow (jobs.*.steps) or composite action (runs.steps).
steps_json() {
  to_json "$1" | jq -c '[(.jobs // {} | .[]? | .steps[]?), (.runs.steps[]?)] | .[]'
}

check_codex_guard() {
  local bad=0 f
  while IFS= read -r f; do
    while IFS= read -r line; do
      [[ -n "$line" ]] && { red "  $f: $line"; bad=1; }
    done < <(steps_json "$f" | jq -r '
      select((.uses // "") | test("openai/codex-action"))
      | .with // {}
      | (if (."permission-profile" // "") != ":workspace" then "codex-action without permission-profile: \":workspace\"" else empty end),
        (if has("sandbox") then "codex-action sets the legacy sandbox input" else empty end),
        (if ((."safety-strategy" // "drop-sudo") | IN("drop-sudo", "unprivileged-user") | not) then "codex-action safety-strategy: \(."safety-strategy")" else empty end),
        (if ((."codex-args" // "") | test("danger|bypass|sandbox")) then "codex-action codex-args widens the sandbox" else empty end)')
    # Text checks catch the same widening written into a config or rules file.
    while IFS= read -r hit; do
      [[ -n "$hit" ]] && { red "  $f: $hit"; bad=1; }
    done < <(grep -nE 'danger-full-access|network_access[[:space:]]*=[[:space:]]*true|decision[[:space:]]*=[[:space:]]*"allow"' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  done < <(all_yaml)

  if [[ "$bad" -gt 0 ]]; then
    echo ""
    red "Codex must run with permission-profile \":workspace\" and drop-sudo, and"
    red "never with an \`allow\` rule: an allowed command runs outside the sandbox."
    return 1
  fi
  green "Codex runs sandboxed (:workspace, no allow rules)."
  return 0
}

check_gemini_guard() {
  local bad=0 f s line kind rest refs=0 found_action=0
  local banned='["run_shell_command", "web_fetch", "google_web_search"]'
  local settings=()
  # Each run-gemini-cli step is judged on its own settings: a literal that passes,
  # or `steps.<id>.outputs.settings` from a vip-gemini-run step in the same job.
  # A step with neither fails, whatever other steps or files carry.
  while IFS= read -r f; do
    while IFS=$'\t' read -r kind rest; do
      case "$kind" in
        literal) settings+=("$f"$'\t'"$rest") ;;
        ref)     refs=$((refs + 1)) ;;
        bad)     red "  $f: $rest"; bad=1 ;;
      esac
    done < <(to_json "$f" | jq -r '
      (.jobs // {}) | to_entries[] | .key as $job | (.value.steps // []) as $steps
      | $steps[] | select((.uses // "") | test("run-gemini-cli"))
      | (.with.settings // "") as $s
      | if $s == "" then "bad\tjob \($job): run-gemini-cli has no settings"
        elif ($s | startswith("${{")) then
          (try ($s | capture("^\\$\\{\\{\\s*steps\\.(?<id>[A-Za-z0-9_-]+)\\.outputs\\.settings\\s*\\}\\}$").id) catch null) as $id
          | if $id != null and ([$steps[] | select(.id == $id and ((.uses // "") == "./.github/actions/vip-gemini-run"))] | length) > 0
            then "ref\t\($job)"
            else "bad\tjob \($job): run-gemini-cli settings do not come from a vip-gemini-run step in the same job" end
        else "literal\t\($s | gsub("\n"; " "))" end')
    # Settings assembled in the setup action: settings='{...}'.
    while IFS= read -r s; do
      if [[ -n "$s" ]]; then
        settings+=("$f"$'\t'"$s")
        [[ "$f" == *vip-gemini-run/action.yml ]] && found_action=1
      fi
    done < <(grep -oE "settings='\{.*\}'" "$f" | sed -E "s/^settings='(.*)'$/\1/" || true)
  done < <(all_yaml)

  for entry in "${settings[@]+"${settings[@]}"}"; do
    f="${entry%%$'\t'*}"; s="${entry#*$'\t'}"
    if ! line="$(printf '%s' "$s" | jq -r --argjson banned "$banned" '
        if (.tools.core | type) != "array" then "no tools.core allowlist"
        elif ([.tools.core[] | split("(")[0]] | any(IN($banned[]))) then "tools.core admits a shell or web tool"
        else "ok" end' 2>/dev/null)"; then
      line="settings are not valid JSON"
    fi
    if [[ "$line" != "ok" ]]; then red "  $f: Gemini $line"; bad=1; fi
  done

  # Steps that take their settings from vip-gemini-run are only as safe as the
  # settings it writes. If those cannot be found, fail rather than pass quietly.
  if [[ "$refs" -gt 0 && "$found_action" -eq 0 ]]; then
    red "  run-gemini-cli takes settings from vip-gemini-run, but its settings='{...}' could not be found."
    bad=1
  fi

  if [[ "$bad" -gt 0 ]]; then
    echo ""
    red "Gemini keeps its API key in its own environment and cannot be kept off the"
    red "network, so it may only have file tools. tools.core must exclude"
    red "run_shell_command, web_fetch and google_web_search."
    return 1
  fi
  green "Gemini has file tools only."
  return 0
}

# ── Publish and local references ──────────────────────────────────────────────

check_publish() {
  local f="$WORKFLOW_DIR/vip-agent-publish.yml" bad=0 line
  [[ -f "$f" ]] || { dim "No vip-agent-publish.yml — skipping the publish checks."; return 0; }

  # Every job needs a cap: the default is six hours.
  while IFS= read -r line; do
    [[ -n "$line" ]] && { red "  $f: job $line has no timeout-minutes"; bad=1; }
  done < <(to_json "$f" | jq -r '.jobs | to_entries[] | select(.value["timeout-minutes"] == null) | .key')

  # Agent-derived values reach code only through env:. An expression inside
  # run: or script: is pasted into the source before it runs, so a crafted
  # branch name or final message becomes code. Every expression is banned, not
  # a list of contexts: ${{ env.X }} or ${{ format(...) }} paste the same values.
  while IFS= read -r line; do
    [[ -n "$line" ]] && { red "  $f: $line"; bad=1; }
  done < <(to_json "$f" | jq -r '
    .jobs[].steps[]? | {name: (.name // .uses // "step"), code: ((.run // "") + (.with.script // ""))}
    | select(.code | test("\\$\\{\\{"))
    | "step \"\(.name)\" interpolates an expression into code; pass it through env:"')

  if [[ "$bad" -gt 0 ]]; then return 1; fi
  green "vip-agent-publish.yml: every job capped, no expressions in code."
  return 0
}

check_local_refs() {
  local bad=0 f ref target
  while IFS= read -r f; do
    while IFS= read -r ref; do
      [[ -z "$ref" ]] && continue
      target="${ref#./}"
      if [[ "$target" == .github/actions/* ]]; then
        [[ -f "$target/action.yml" ]] || { red "  $f uses $ref, which does not exist"; bad=1; continue; }
        if [[ -f scripts/setup.sh ]] && ! grep -qE "^for action in .*\\b$(basename "$target")\\b" scripts/setup.sh; then
          red "  $f uses $ref, which scripts/setup.sh does not install"; bad=1
        fi
      elif [[ "$target" == .github/workflows/* ]]; then
        [[ -f "$target" ]] || { red "  $f uses $ref, which does not exist"; bad=1; continue; }
        if [[ -f scripts/setup.sh ]] && ! grep -qF "\"$target\"" scripts/setup.sh; then
          red "  $f uses $ref, which scripts/setup.sh does not install"; bad=1
        fi
      fi
    done < <(to_json "$f" | jq -r '[(.jobs // {} | .[]? | .uses?), (.jobs // {} | .[]? | .steps[]?.uses?), (.runs.steps[]?.uses?)] | .[] | select(. != null and startswith("./"))')
  done < <(all_yaml)

  if [[ "$bad" -gt 0 ]]; then
    echo ""
    red "A workflow that uses a local action or workflow the install does not ship"
    red "fails at startup in every customer repository."
    return 1
  fi
  green "Every local action and workflow reference resolves and is installed."
  return 0
}

# A workflow that approves pull requests turns an agent's PR into a reviewed one.
# The repository setting the publish job needs also permits this, so the only
# guard is here.
check_no_approve() {
  local hits
  hits="$(grep -nE "event:[[:space:]]*['\"]?APPROVE|--approve\\b|createReview[^;]*APPROVE" "$WORKFLOW_DIR"/*.yml .github/actions/*/action.yml 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
  if [[ -n "$hits" ]]; then
    red "  A workflow submits an APPROVE review:"
    printf '%s\n' "$hits" | sed 's/^/      /'
    return 1
  fi
  green "No workflow approves pull requests."
  return 0
}

check_codex_guard || exit 1
check_gemini_guard || exit 1
check_publish || exit 1
check_local_refs || exit 1
check_no_approve || exit 1
