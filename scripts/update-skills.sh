#!/usr/bin/env bash
# Update installed agent skills with `gh skill update` and report whether any skill file changed.
#
# Configuration comes from the environment (set by action.yml):
#   INPUT_DIR, INPUT_DRY_RUN, INPUT_UNPIN, INPUT_GH_VERSION, GH_TOKEN
#   RETRY_ATTEMPTS (default 3) and RETRY_DELAY (seconds, default 5) tune the network retry.
#
# The script never commits, pushes or touches files outside the skill directories under INPUT_DIR.
set -euo pipefail
unset CDPATH

dir=${INPUT_DIR:-.}
dry_run=${INPUT_DRY_RUN:-false}
unpin=${INPUT_UNPIN:-false}
min_gh=${INPUT_GH_VERSION:-2.90.0}
attempts=${RETRY_ATTEMPTS:-3}
delay=${RETRY_DELAY:-5}
output=${GITHUB_OUTPUT:-/dev/null}

# Workflow commands treat %, CR and LF specially; escape them so a message stays one annotation.
escape() { local s=${1//%/%25}; s=${s//$'\r'/%0D}; printf '%s' "${s//$'\n'/%0A}"; }
error() { echo "::error::$(escape "$*")"; }
die() { error "$@"; exit 1; }

random_token() { od -An -N16 -tx1 /dev/urandom | tr -d ' \n'; }

# Print untrusted text (gh output quotes upstream skill names and errors) with workflow commands
# disabled, so a line such as `::add-mask::` coming from upstream cannot drive the runner.
print_untrusted() {
  local token
  token=$(random_token)
  echo "::stop-commands::$token"
  printf '%s\n' "$1"
  echo "::$token::"
}

set_output() { # <name> <value>
  local delim
  delim="EOF_$(random_token)"
  printf '%s<<%s\n%s\n%s\n' "$1" "$delim" "$2" "$delim" >>"$output"
}

version_ge() { # <have> <want>: true when have >= want
  local i h w
  local -a have want
  IFS=. read -r -a have <<<"$1"
  IFS=. read -r -a want <<<"$2"
  for i in 0 1 2; do
    h=$((10#${have[i]:-0})) w=$((10#${want[i]:-0}))
    if ((h > w)); then return 0; fi
    if ((h < w)); then return 1; fi
  done
}

# ── Validate inputs ──
for pair in "dry-run=$dry_run" "unpin=$unpin"; do
  case "${pair#*=}" in
    true | false) ;;
    *) die "Input '${pair%%=*}' must be 'true' or 'false', got '${pair#*=}'." ;;
  esac
done
[[ "$min_gh" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || die "Input 'gh-version' must be a version such as 2.90.0, got '$min_gh'."
[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || die "RETRY_ATTEMPTS must be a positive integer, got '$attempts'."
[[ "$delay" =~ ^[0-9]+$ ]] || die "RETRY_DELAY must be a non-negative integer, got '$delay'."

[[ -n "$dir" ]] || die "Input 'dir' must not be empty."
[[ -d "$dir" ]] || die "Directory not found: '$dir' (relative paths resolve against '$PWD')."
workspace=$(cd -- "${GITHUB_WORKSPACE:-$PWD}" && pwd -P)
root_dir=$(cd -- "$dir" && pwd -P)
if [[ "$root_dir" != "$workspace" && "$root_dir" != "$workspace/"* ]]; then
  die "Directory '$dir' resolves to '$root_dir', which is outside the workspace '$workspace'."
fi
rel() { local p=${1#"$workspace"}; p=${p#/}; printf '%s' "${p:-.}"; }

if command -v sha256sum >/dev/null 2>&1; then
  hasher=(sha256sum)
elif command -v shasum >/dev/null 2>&1; then
  hasher=(shasum -a 256)
else
  die "Neither 'sha256sum' nor 'shasum' is available; one is required to detect skill changes."
fi

# ── Check the GitHub CLI ──
command -v gh >/dev/null 2>&1 ||
  die "GitHub CLI 'gh' was not found on PATH. Install gh >= $min_gh before this step (https://cli.github.com)."
gh_version=$(gh --version 2>/dev/null | awk '/^gh version / { print $3; exit }') || true
gh_version=${gh_version%%[^0-9.]*}
[[ -n "$gh_version" ]] || die "Could not determine the GitHub CLI version from 'gh --version'."
version_ge "$gh_version" "$min_gh" ||
  die "GitHub CLI $gh_version is older than the required $min_gh. Install a newer gh before this step (https://cli.github.com)."
gh skill --help >/dev/null 2>&1 ||
  die "GitHub CLI $gh_version does not provide 'gh skill'. Install gh >= $min_gh before this step."
echo "Using GitHub CLI $gh_version (required >= $min_gh)."

# Keep gh non-interactive and its output free of colours and spinners.
export GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 GH_SPINNER_DISABLED=1 NO_COLOR=1
# CI runs should not report usage data.
export GH_TELEMETRY=false DO_NOT_TRACK=1

# ── Discover installed skills ──
# One skill directory per line: every directory below INPUT_DIR holding a SKILL.md. A SKILL.md
# directly in INPUT_DIR is ignored, because updating it would mean scanning INPUT_DIR's parent.
# ponytail: newline- and tab-separated paths, so a name containing either is not supported.
list_skills() {
  find "$root_dir" -name .git -prune -o -type f -name SKILL.md -print0 |
    while IFS= read -r -d '' md; do
      if [[ "$md" != "$root_dir/SKILL.md" ]]; then dirname "$md"; fi
    done | sort -u
}

# One line per file in the skill directories read from stdin: the path, a tab, then the content
# hash and executable bit of a regular file or the target of a symlink. Added or removed files
# change the listing.
# `.git` inside a skill directory is repository state, not skill content.
snapshot() {
  local d f
  while IFS= read -r d; do
    if [[ -n "$d" && -d "$d" ]]; then
      find "$d" -name .git -prune -o \( -type f -o -type l \) -print0
    fi
  done | sort -zu | while IFS= read -r -d '' f; do
    if [[ -L "$f" ]]; then
      printf '%s\tlink -> %s\n' "$f" "$(readlink "$f")"
    else
      local mode=-
      if [[ -x "$f" ]]; then mode=x; fi
      printf '%s\tfile %s %s\n' "$f" "$mode" "$("${hasher[@]}" <"$f" | cut -d' ' -f1)"
    fi
  done
}

skills=$(list_skills)
if [[ -z "$skills" ]]; then
  echo "No installed skills found in '$(rel "$root_dir")'."
  set_output changed false
  set_output updated-skills "No installed skills found."
  set_output updated-files ""
  exit 0
fi

echo "Installed skills:"
while IFS= read -r s; do echo "  - $(rel "$s")"; done <<<"$skills"

# `gh skill update --dir X` only scans X/*/SKILL.md, so run it once per parent of a skill directory.
# That covers both `.agents/skills/<skill>` and nested `plugins/<plugin>/skills/<skill>` layouts.
roots=$(while IFS= read -r s; do dirname "$s"; done <<<"$skills" | sort -u)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
before=$work/before after=$work/after summary=$work/summary
: >"$summary"
printf '%s\n' "$skills" | snapshot >"$before"

flags=(--all)
if [[ "$dry_run" == true ]]; then flags+=(--dry-run); fi
if [[ "$unpin" == true ]]; then flags+=(--unpin); fi

# gh exits 0 even when it cannot reach a skill's upstream (bad token, missing repository, network
# error); it reports those as `! Skipping <skill>: ...`. Treat them as failures and retry them.
# `no skills found in <repo>` is the exception: the upstream publishes the skill outside the paths
# gh discovers, so a retry cannot help and the skill is reported as skipped instead.
failures() { grep '^! Skipping ' | grep -v '^! Skipping [^:]*: no skills found in ' || true; }

update_root() { # <root>
  local n out rc line
  for ((n = 1; ; n++)); do
    rc=0
    out=$(gh skill update "${flags[@]}" --dir "$1" </dev/null 2>&1) || rc=$?
    # Strip carriage returns and ANSI escapes in case gh ever draws progress output.
    out=$(printf '%s\n' "$out" | tr '\r' '\n' | sed -e $'s/\x1B\\[[0-9;]*[A-Za-z]//g' -e '/^[[:space:]]*$/d')
    print_untrusted "$out"
    printf '%s\n' "$out" >>"$summary"
    if ((rc == 0)) && [[ -z "$(failures <<<"$out")" ]]; then break; fi
    if ((n >= attempts)); then
      if ((rc != 0)); then error "'gh skill update' exited with status $rc for '$(rel "$1")'."; fi
      while IFS= read -r line; do error "${line#! }"; done < <(failures <<<"$out")
      return 1
    fi
    echo "::warning::'gh skill update' failed for '$(rel "$1")' (attempt $n/$attempts); retrying in $((delay * n))s."
    sleep $((delay * n))
  done
  # Remaining `!` notices are skills gh deliberately skipped: no GitHub metadata, or an upstream
  # that no longer publishes them where gh looks. They are never updated, so make them visible.
  while IFS= read -r line; do
    echo "::warning::$(escape "${line#! }")"
  done < <(grep '^! ' <<<"$out" || true)
}

status=0
while IFS= read -r root; do
  echo "::group::gh skill update ${flags[*]} --dir $(rel "$root")"
  if ! update_root "$root"; then status=1; fi
  echo "::endgroup::"
done <<<"$roots"

# Re-discover: a skill that appeared adds files to the snapshot and one that vanished removes them.
list_skills | snapshot >"$after"
# A path whose line differs between the snapshots was added, removed or modified.
updated_files=$(comm -3 <(sort "$before") <(sort "$after") | sed $'s/^\t//' | cut -f1 | sort -u |
  while IFS= read -r f; do rel "$f"; echo; done)
changed=false
if [[ -n "$updated_files" ]]; then changed=true; fi

set_output changed "$changed"
set_output updated-skills "$(cat "$summary")"
set_output updated-files "$updated_files"
echo "changed=$changed"

if ((status != 0)); then
  die "One or more skill updates failed; see the errors above. Files that were already updated are kept."
fi
