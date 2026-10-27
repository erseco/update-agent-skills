#!/usr/bin/env bash
# Offline test suite for scripts/update-skills.sh. Uses tests/mock-gh instead of the real GitHub CLI.
# Usage: tests/run.sh [test-name-filter]
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
script="$here/../scripts/update-skills.sh"
bash_bin=$(command -v bash)
filter=${1:-}
passed=0 failed=0 failures=()

# ── Helpers ──

# A fresh workspace per test; the script runs from inside it.
setup() {
  ws=$(mktemp -d)
  ws=$(cd "$ws" && pwd -P)
  upstream=$(mktemp -d)
  out_file="$ws/.github-output" log="$ws/.gh-log"
  : >"$out_file"
  : >"$log"
  path="$here/mock-gh:$PATH"
}
teardown() { rm -rf "$ws" "$upstream"; }

# skill <dir> [frontmatter-extra]: an installed skill with GitHub metadata
skill() {
  mkdir -p "$1"
  printf -- '---\nname: %s\ndescription: test\nmetadata:\n    github-repo: https://github.com/owner/repo\n%s---\nBody\n' \
    "$(basename "$1")" "${2:-}" >"$1/SKILL.md"
}
# upstream_copy <skill-dir>: start the upstream version of a skill from its installed copy
upstream_copy() { cp -RPp "$1" "$upstream/$(basename "$1")"; echo "$upstream/$(basename "$1")"; }

run() { # [VAR=value...]: run the action script in $ws
  (cd "$ws" && env -i HOME="$HOME" PATH="$path" GITHUB_WORKSPACE="$ws" GITHUB_OUTPUT="$out_file" \
    MOCK_GH_LOG="$log" MOCK_UPSTREAM="$upstream" RETRY_DELAY=0 "$@" \
    "$bash_bin" "$script") >"$ws/.stdout" 2>&1
  status=$?
  stdout=$(cat "$ws/.stdout")
}

# output <name>: parse a value from $GITHUB_OUTPUT (supports the name<<DELIM multiline form)
output() {
  awk -v name="$1" '
    !delim && index($0, name "<<") == 1 { delim = substr($0, length(name) + 3); next }
    delim && $0 == delim { delim = ""; exit }
    delim { print }
    !delim && index($0, name "=") == 1 { print substr($0, length(name) + 2) }
  ' "$out_file"
}

fail() { echo "    ✗ $*"; ok=false; }
assert_status() { [[ "$status" -eq "$1" ]] || fail "exit status $status, expected $1"; }
assert_output() { [[ "$(output "$1")" == "$2" ]] || fail "output $1='$(output "$1")', expected '$2'"; }
assert_contains() { [[ "$1" == *"$2"* ]] || fail "expected to contain: $2"; }
assert_not_contains() { [[ "$1" != *"$2"* ]] || fail "expected not to contain: $2"; }
assert_calls() { local n; n=$(grep -c '^update ' "$log"); [[ "$n" -eq "$1" ]] || fail "$n gh skill update call(s), expected $1"; }

test_case() { # <name> <function>
  [[ -z "$filter" || "$1" == *"$filter"* ]] || return 0
  ok=true
  setup
  "$2"
  if [[ "$ok" == true ]]; then
    passed=$((passed + 1)); echo "  ✓ $1"
  else
    failed=$((failed + 1)); failures+=("$1"); echo "  ✗ $1"; sed 's/^/      | /' "$ws/.stdout" 2>/dev/null
  fi
  teardown
}

# ── Input validation ──

t_missing_dir() {
  run INPUT_DIR=does-not-exist
  assert_status 1
  assert_contains "$stdout" "::error::Directory not found: 'does-not-exist'"
}
t_empty_dir_input() {
  run INPUT_DIR=
  assert_status 0 # empty falls back to the default "."
  assert_output changed false
}
t_dir_is_file() {
  touch "$ws/file"
  run INPUT_DIR=file
  assert_status 1
  assert_contains "$stdout" "Directory not found"
}
t_dir_outside_workspace() {
  run INPUT_DIR=..
  assert_status 1
  assert_contains "$stdout" "outside the workspace"
}
t_dir_symlink_escape() {
  ln -s "$upstream" "$ws/escape"
  run INPUT_DIR=escape
  assert_status 1
  assert_contains "$stdout" "outside the workspace"
}
t_invalid_boolean() {
  run INPUT_DRY_RUN=yes
  assert_status 1
  assert_contains "$stdout" "Input 'dry-run' must be 'true' or 'false', got 'yes'."
  run INPUT_UNPIN=TRUE
  assert_status 1
  assert_contains "$stdout" "Input 'unpin'"
}
t_invalid_gh_version() {
  run 'INPUT_GH_VERSION=2.90; rm -rf /'
  assert_status 1
  assert_contains "$stdout" "Input 'gh-version' must be a version"
}

# ── GitHub CLI checks ──

t_gh_missing() {
  # A PATH with every tool the script needs except gh.
  local bin="$ws/.bin" tool
  mkdir "$bin"
  for tool in find sort dirname sed tr grep cmp mktemp rm cat od awk cut readlink sleep sha256sum shasum perl; do
    if command -v "$tool" >/dev/null; then ln -s "$(command -v "$tool")" "$bin/$tool"; fi
  done
  path=$bin
  run
  assert_status 1
  assert_contains "$stdout" "GitHub CLI 'gh' was not found on PATH"
}
t_gh_too_old() {
  run MOCK_GH_VERSION=2.89.9
  assert_status 1
  assert_contains "$stdout" "GitHub CLI 2.89.9 is older than the required 2.90.0"
}
t_gh_version_compare_numeric() {
  run MOCK_GH_VERSION=2.100.0 # 2.100 > 2.90 numerically, not lexically
  assert_status 0
  run MOCK_GH_VERSION=3.0.0 INPUT_GH_VERSION=2.95
  assert_status 0
}
t_gh_without_skill() {
  run MOCK_GH_NO_SKILL=1
  assert_status 1
  assert_contains "$stdout" "does not provide 'gh skill'"
}

# ── Discovery ──

t_no_skills() {
  mkdir -p "$ws/.agents/skills"
  run INPUT_DIR=.agents/skills
  assert_status 0
  assert_output changed false
  assert_output updated-skills "No installed skills found."
  assert_output updated-files ""
  assert_calls 0
}
t_root_skill_md_ignored() {
  # A SKILL.md directly in dir would make gh scan dir's parent, outside the configured directory.
  skill "$ws/skills"
  run INPUT_DIR=skills
  assert_status 0
  assert_output updated-skills "No installed skills found."
  assert_calls 0
}
t_one_skill_up_to_date() {
  skill "$ws/.agents/skills/a"
  run INPUT_DIR=.agents/skills
  assert_status 0
  assert_output changed false
  assert_output updated-skills "All skills are up to date."
  grep -q "^update dir=$ws/.agents/skills dry-run=false unpin=false$" "$log" || fail "unexpected gh call: $(cat "$log")"
}
t_upstream_identical() {
  # gh re-downloads, but nothing actually differs: not a change.
  skill "$ws/s/a"
  upstream_copy "$ws/s/a" >/dev/null
  run INPUT_DIR=s
  assert_status 0
  assert_output changed false
  assert_contains "$(output updated-skills)" "Updated a"
}
t_one_skill_updated() {
  skill "$ws/s/a"
  echo "New body" >>"$(upstream_copy "$ws/s/a")/SKILL.md"
  run INPUT_DIR=s
  assert_status 0
  assert_output changed true
  assert_contains "$(output updated-skills)" "Updated a"
  grep -q "New body" "$ws/s/a/SKILL.md" || fail "skill not updated"
}
t_multiple_skills() {
  skill "$ws/s/a"
  skill "$ws/s/b"
  skill "$ws/s/c"
  echo "x" >>"$(upstream_copy "$ws/s/b")/SKILL.md"
  run INPUT_DIR=s
  assert_status 0
  assert_output changed true
  assert_calls 1
  assert_contains "$(output updated-skills)" "Updated b"
  assert_not_contains "$(output updated-skills)" "Updated a"
  assert_output updated-files "s/b/SKILL.md"
}
t_nested_layout() {
  skill "$ws/plugins/go/skills/golang"
  skill "$ws/plugins/gh/skills/issues"
  echo "x" >>"$(upstream_copy "$ws/plugins/gh/skills/issues")/SKILL.md"
  run INPUT_DIR=plugins
  assert_status 0
  assert_output changed true
  assert_calls 2
  grep -q "dir=$ws/plugins/go/skills " "$log" || fail "plugins/go/skills not scanned"
  grep -q "dir=$ws/plugins/gh/skills " "$log" || fail "plugins/gh/skills not scanned"
}
t_default_dir() {
  skill "$ws/.agents/skills/a"
  echo "x" >>"$(upstream_copy "$ws/.agents/skills/a")/SKILL.md"
  run
  assert_status 0
  assert_output changed true
}

# ── Change detection ──

t_bundled_script_only() {
  skill "$ws/s/a"
  mkdir -p "$ws/s/a/scripts" "$ws/s/a/references"
  echo "echo v1" >"$ws/s/a/scripts/run.sh"
  echo "ref v1" >"$ws/s/a/references/guide.md"
  echo "echo v2" >"$(upstream_copy "$ws/s/a")/scripts/run.sh"
  run INPUT_DIR=s
  assert_output changed true
}
t_reference_only() {
  skill "$ws/s/a"
  mkdir -p "$ws/s/a/references"
  echo "ref v1" >"$ws/s/a/references/guide.md"
  echo "ref v2" >"$(upstream_copy "$ws/s/a")/references/guide.md"
  run INPUT_DIR=s
  assert_output changed true
}
t_added_file() {
  skill "$ws/s/a"
  echo new >"$(upstream_copy "$ws/s/a")/NEW.md"
  run INPUT_DIR=s
  assert_output changed true
}
t_deleted_file() {
  skill "$ws/s/a"
  echo old >"$ws/s/a/OLD.md"
  rm "$(upstream_copy "$ws/s/a")/OLD.md"
  run INPUT_DIR=s
  assert_output changed true
  [[ ! -e "$ws/s/a/OLD.md" ]] || fail "OLD.md still present"
}
t_executable_bit() {
  skill "$ws/s/a"
  echo "echo hi" >"$ws/s/a/run.sh"
  chmod +x "$(upstream_copy "$ws/s/a")/run.sh"
  run INPUT_DIR=s
  assert_output changed true
}
t_symlink_target() {
  skill "$ws/s/a"
  echo 1 >"$ws/s/a/one.md"
  echo 2 >"$ws/s/a/two.md"
  ln -s one.md "$ws/s/a/link.md"
  local up
  up=$(upstream_copy "$ws/s/a")
  rm "$up/link.md"
  ln -s two.md "$up/link.md"
  run INPUT_DIR=s
  assert_output changed true
}
t_updated_files_lists_changes() {
  skill "$ws/s/a"
  skill "$ws/s/b"
  echo old >"$ws/s/a/OLD.md"
  echo same >"$ws/s/a/same.md"
  local up
  up=$(upstream_copy "$ws/s/a")
  rm "$up/OLD.md"
  echo new >"$up/NEW.md"
  echo "x" >>"$up/SKILL.md"
  run INPUT_DIR=s
  assert_output changed true
  assert_output updated-files $'s/a/NEW.md\ns/a/OLD.md\ns/a/SKILL.md'
}
t_git_metadata_ignored() {
  skill "$ws/s/a"
  mkdir -p "$ws/s/a/.git"
  echo "ref: refs/heads/main" >"$ws/s/a/.git/HEAD"
  echo "ref: refs/heads/other" >"$(upstream_copy "$ws/s/a")/.git/HEAD"
  run INPUT_DIR=s
  assert_output changed false
}
# ── Modes ──

t_dry_run() {
  skill "$ws/s/a"
  echo "x" >>"$(upstream_copy "$ws/s/a")/SKILL.md"
  local before
  before=$(cat "$ws/s/a/SKILL.md")
  run INPUT_DIR=s INPUT_DRY_RUN=true
  assert_status 0
  assert_output changed false
  assert_output updated-files ""
  assert_contains "$(output updated-skills)" "1 update(s) available"
  grep -q "dry-run=true" "$log" || fail "--dry-run not passed"
  [[ "$(cat "$ws/s/a/SKILL.md")" == "$before" ]] || fail "dry-run modified files"
}
t_pinned_preserved() {
  skill "$ws/s/a" "    github-pinned: 0123456789abcdef0123456789abcdef01234567
"
  echo "x" >>"$(upstream_copy "$ws/s/a")/SKILL.md"
  run INPUT_DIR=s
  assert_status 0
  assert_output changed false
  assert_contains "$(output updated-skills)" "a is pinned"
  grep -q "unpin=false" "$log" || fail "--unpin passed unexpectedly"
}
t_unpin() {
  skill "$ws/s/a" "    github-pinned: 0123456789abcdef0123456789abcdef01234567
"
  echo "x" >>"$(upstream_copy "$ws/s/a")/SKILL.md"
  run INPUT_DIR=s INPUT_UNPIN=true
  assert_status 0
  assert_output changed true
  grep -q "unpin=true" "$log" || fail "--unpin not passed"
}
t_no_metadata_warns() {
  mkdir -p "$ws/s/manual"
  printf -- '---\nname: manual\ndescription: x\n---\n' >"$ws/s/manual/SKILL.md"
  run INPUT_DIR=s
  assert_status 0
  assert_contains "$stdout" "::warning::manual has no GitHub metadata"
}

# ── Failures and retries ──

t_gh_failure() {
  skill "$ws/s/a"
  run INPUT_DIR=s MOCK_GH_FAIL=99
  assert_status 1
  assert_calls 3
  assert_contains "$stdout" "::error::'gh skill update' exited with status 1 for 's'."
  assert_contains "$stdout" "One or more skill updates failed"
  assert_output changed false # outputs are still written on failure
}
t_transient_failure_retried() {
  skill "$ws/s/a"
  echo "x" >>"$(upstream_copy "$ws/s/a")/SKILL.md"
  run INPUT_DIR=s MOCK_GH_FAIL=1
  assert_status 0
  assert_calls 2
  assert_contains "$stdout" "::warning::'gh skill update' failed for 's' (attempt 1/3)"
  assert_output changed true
}
t_unresolved_upstream_fails() {
  # gh exits 0 here; the action must not report it as "up to date".
  skill "$ws/s/a"
  run INPUT_DIR=s MOCK_GH_FAIL=99 MOCK_GH_FAIL_MODE=skip RETRY_ATTEMPTS=2
  assert_status 1
  assert_calls 2
  assert_contains "$stdout" "::error::Skipping demo: could not resolve owner/repo: HTTP 401: Bad credentials"
}
t_upstream_without_discoverable_skills_warns() {
  # The upstream repository no longer publishes the skill where gh looks; retrying cannot help.
  skill "$ws/s/a"
  run INPUT_DIR=s MOCK_GH_FAIL=99 MOCK_GH_FAIL_MODE=layout
  assert_status 0
  assert_calls 1
  assert_contains "$stdout" "::warning::Skipping demo: no skills found in owner/repo"
  assert_not_contains "$stdout" "::error::"
}
t_one_root_fails_others_continue() {
  skill "$ws/p/x/skills/a"
  skill "$ws/p/y/skills/b"
  echo "x" >>"$(upstream_copy "$ws/p/y/skills/b")/SKILL.md"
  run INPUT_DIR=p MOCK_GH_FAIL=1 RETRY_ATTEMPTS=1
  assert_status 1
  assert_calls 2
  assert_output changed true
}

# ── Outputs and safety ──

t_multiline_output_format() {
  skill "$ws/s/a"
  skill "$ws/s/b"
  echo "x" >>"$(upstream_copy "$ws/s/a")/SKILL.md"
  echo "x" >>"$(upstream_copy "$ws/s/b")/SKILL.md"
  run INPUT_DIR=s
  grep -Eq '^changed<<EOF_[0-9a-f]{32}$' "$out_file" || fail "changed not written with a random delimiter"
  grep -Eq '^updated-skills<<EOF_[0-9a-f]{32}$' "$out_file" || fail "updated-skills not written with a random delimiter"
  [[ "$(output updated-skills)" == $'2 update(s) available:\n  • a (owner/repo)  > 1234abcd [main]\n  • b (owner/repo)  > 1234abcd [main]\nUpdated a\nUpdated b' ]] ||
    fail "unexpected updated-skills: $(output updated-skills)"
}
t_untrusted_output_cannot_run_commands() {
  skill "$ws/s/a"
  run INPUT_DIR=s 'MOCK_GH_ECHO=::add-mask::oops'
  assert_status 0
  # The upstream line must sit between ::stop-commands::<token> and ::<token>::.
  printf '%s\n' "$stdout" | awk '
    /^::stop-commands::/ { token = substr($0, 18); next }
    $0 == "::" token "::" { token = ""; next }
    /^::add-mask::oops$/ { exit token == "" ? 1 : 0 }
  ' || fail "gh output was not wrapped in stop-commands"
}
t_token_not_logged() {
  skill "$ws/s/a"
  run INPUT_DIR=s GH_TOKEN=ghs_supersecret
  assert_not_contains "$stdout" "ghs_supersecret"
  assert_not_contains "$(cat "$out_file")" "ghs_supersecret"
}
t_unrelated_files_untouched() {
  skill "$ws/.agents/skills/a"
  echo "keep" >"$ws/README.md"
  mkdir -p "$ws/.claude/skills/a" && echo "copy" >"$ws/.claude/skills/a/SKILL.md"
  echo "x" >>"$(upstream_copy "$ws/.agents/skills/a")/SKILL.md"
  run INPUT_DIR=.agents/skills
  assert_status 0
  [[ "$(cat "$ws/README.md")" == keep && "$(cat "$ws/.claude/skills/a/SKILL.md")" == copy ]] || fail "unrelated file changed"
  assert_calls 1
}
t_dir_with_spaces_and_dash() {
  skill "$ws/-my skills/a b"
  echo "x" >>"$(upstream_copy "$ws/-my skills/a b")/SKILL.md"
  run "INPUT_DIR=-my skills"
  assert_status 0
  assert_output changed true
}

echo "update-skills.sh tests"
for t in $(declare -F | awk '{ print $3 }' | grep '^t_'); do
  test_case "${t#t_}" "$t"
done
echo
echo "$passed passed, $failed failed"
if ((failed)); then printf '  - %s\n' "${failures[@]}"; exit 1; fi
