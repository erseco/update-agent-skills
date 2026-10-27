# Update Agent Skills

Update installed AI agent skills from their upstream GitHub repositories with the official
GitHub CLI ([`gh skill update`](https://cli.github.com/manual/gh_skill_update)), and report
whether anything changed.

The action only updates files and exposes the result. It does **not** commit, push, open pull
requests, manage branches, or copy skills into agent-specific directories such as
`.claude/skills`. Those steps belong to your workflow.

## How it works

1. Validates the inputs. `dir` must be an existing directory inside the workspace.
2. Checks that `gh` is installed, is at least `gh-version`, and provides `gh skill`.
3. Finds every installed skill: each directory under `dir` that holds a `SKILL.md`. `.git`
   directories are skipped.
4. Hashes every file in those skill directories, recording content, the executable bit and
   symlink targets.
5. Runs `gh skill update --all --dir <parent>` once for each directory that contains skills.
   `gh` only looks one level deep, so this is what supports both layouts:

   ```text
   .agents/skills/<skill>/SKILL.md            # conventional
   plugins/<plugin>/skills/<skill>/SKILL.md   # nested
   ```

6. Hashes the skill directories again and sets `changed` if anything differs. That includes a
   change to a bundled script or reference file while `SKILL.md` stays byte-identical.

## Requirements

- **GitHub CLI >= 2.90.0** (or the configured `gh-version`) on `PATH`. GitHub-hosted runners
  ship a recent `gh`. The action does **not** download `gh` itself. If your runner's copy is too
  old, the action fails with a clear message and you need to install a newer one first.
- Bash, plus `find`, `sed`, `awk`, `comm`, `od`, and `sha256sum` or `shasum`. All of these are
  present on GitHub-hosted runners.
- A repository checkout done by the calling workflow.

| Runner | Status |
|---|---|
| `ubuntu-*` (GitHub-hosted) | Supported, tested in CI |
| `macos-*` (GitHub-hosted) | Supported, unit tests in CI (works with the system Bash 3.2) |
| `windows-*` | Not supported |
| Self-hosted Linux/macOS | Should work if the requirements above are met |

## Inputs

| Input | Default | Description |
|---|---|---|
| `dir` | `.` | Root directory containing installed skills. It must resolve, after following symlinks, to a path inside `$GITHUB_WORKSPACE`. A `SKILL.md` directly in `dir` is ignored, because updating it would mean scanning outside `dir`. |
| `dry-run` | `false` | `true` reports available updates without modifying files (`gh skill update --dry-run`). |
| `unpin` | `false` | `true` clears pins and updates pinned skills too (`gh skill update --unpin`). |
| `gh-version` | `2.90.0` | Minimum required GitHub CLI version. |
| `github-token` | `${{ github.token }}` | Token exposed to `gh` as `GH_TOKEN`. It needs read access to the upstream skill repositories. |

Boolean inputs accept exactly `true` or `false`. Any other value fails the run.

## Outputs

| Output | Description |
|---|---|
| `changed` | `true` when any file in an installed skill directory was added, removed or modified (content, executable bit or symlink target). Otherwise `false`. Always `false` with `dry-run`. |
| `updated-skills` | Readable summary of the `gh skill update` output: available updates, `Updated <skill>` lines and skip notices. `No installed skills found.` when there is nothing to update. |
| `updated-files` | Newline-separated paths, relative to the workspace, of every skill file that was added, removed or modified. Empty when `changed` is `false`. Useful to point reviewers at changed scripts. |

Both outputs are also set when a skill update fails, so later steps with `if: always()` can
still read them. Input or `gh` validation errors fail before any output is set.

## Usage

```yaml
- name: Update agent skills
  id: update
  uses: erseco/update-agent-skills@v1
  with:
    dir: .agents/skills
```

Use `steps.update.outputs.changed` to decide whether later steps need to run:

```yaml
- if: steps.update.outputs.changed == 'true'
  run: echo "Skills changed:" && echo "$SUMMARY"
  env:
    SUMMARY: ${{ steps.update.outputs.updated-skills }}
```

Pass outputs to `run:` scripts through `env:` as shown above, never by inlining
`${{ ... }}` into the script. Their content comes from upstream repositories.

### Scheduled update pull request

```yaml
name: Update agent skills

on:
  schedule:
    - cron: "0 6 * * 1" # Mondays at 06:00 UTC
  workflow_dispatch:

permissions: {}

jobs:
  update:
    runs-on: ubuntu-latest
    permissions:
      contents: write       # push the update branch
      pull-requests: write  # open the pull request
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false

      - name: Update agent skills
        id: update
        uses: erseco/update-agent-skills@v1
        with:
          dir: .agents/skills

      - name: Open pull request
        if: steps.update.outputs.changed == 'true'
        uses: peter-evans/create-pull-request@5f6978faf089d4d20b00c7766989d076bb2fc7f1 # v8.1.1
        with:
          token: ${{ github.token }}
          branch: deps/agent-skills
          add-paths: .agents/skills
          commit-message: "chore(deps): update agent skills"
          title: "chore(deps): update agent skills"
          labels: dependencies
          body: |
            Upstream agent skills changed. Review every file before merging:
            skills are instructions and scripts that your agents will follow and may run.

            ```
            ${{ steps.update.outputs.updated-skills }}
            ```

            Changed files:

            ```
            ${{ steps.update.outputs.updated-files }}
            ```
```

With `GITHUB_TOKEN`, the pull request step fails unless **Settings → Actions → General →
Workflow permissions → Allow GitHub Actions to create and approve pull requests** is enabled
(at organization level too, if the organization restricts it).

`add-paths` keeps the pull request limited to the skill directory. Pull requests created with
`GITHUB_TOKEN` do not trigger other workflows. If you need CI to run on them, use a GitHub App
token or a fine-grained PAT instead.

### Nested layout

```yaml
- id: update
  uses: erseco/update-agent-skills@v1
  with:
    dir: plugins # updates plugins/*/skills/* and any other directory holding skills
```

## GitHub provenance metadata

`gh skill install` writes the skill's origin into the `SKILL.md` frontmatter, and
`gh skill update` uses it to find the upstream:

```yaml
---
name: documentation-writer
metadata:
    github-repo: https://github.com/github/awesome-copilot
    github-path: skills/documentation-writer
    github-ref: refs/heads/main
    github-tree-sha: 016d8040a3f91c8360b1003e74fbf29f34c283f5
---
```

- A skill **without** this metadata, for example one copied by hand, is skipped. The action
  logs a warning but the run does not fail. Reinstall the skill with `gh skill install` to make
  it updatable.
- A skill whose upstream **cannot be resolved** fails the run. That covers a bad token, a
  deleted repository, a network error and invalid frontmatter. `gh` itself exits successfully
  in these cases, so this action reads its `! Skipping …` notices to avoid reporting a broken
  update as "up to date".
- A skill whose upstream repository **no longer publishes it where `gh` looks** is skipped with a
  warning. `gh` reports this as `no skills found in <repo>`. It only discovers
  `skills/*/SKILL.md`, `skills/{scope}/*/SKILL.md`, `*/SKILL.md` and
  `plugins/*/skills/*/SKILL.md`, so a skill installed from a path such as `.agents/skills/<skill>`
  can never be updated. Retrying cannot fix that, so the run does not fail, but the skill stays
  at its installed version until the upstream publishes it in a discoverable path.
- Skills installed with the Vercel CLI (`npx skills add`, tracked in `skills-lock.json`) do not
  carry this metadata, so every one of them is skipped. Reinstall them with `gh skill install`,
  or use an action built on that CLI such as
  [`iyaki/skills-update`](https://github.com/iyaki/skills-update).
- An update replaces the whole skill directory with the upstream content. Files you added
  locally inside a skill directory are removed.

## Pinned skills

A skill installed with `gh skill install --pin <ref>` carries `metadata.github-pinned`.

- By default pinned skills are **left untouched**, and the summary lists them as skipped.
- With `unpin: true`, `gh` clears the pin and updates the skill to the latest upstream version.
  This applies to every pinned skill under `dir`.

To pin a skill, run `gh skill install --pin` locally and commit the result. This action does not
manage pins (see [Differences from the reference action](#differences-from-the-reference-action)).

## Security

- **Review upstream changes before merging.** Skills are instructions, and often scripts, that
  AI agents follow with your permissions. Treat a skill update like a dependency update from a
  third party.
- The action never executes skill content. It only hashes the files.
- `gh` output quotes upstream text such as skill names and error messages. The action prints it
  between `::stop-commands::` markers, so a crafted line cannot run workflow commands. Pass
  `updated-skills` to scripts through `env:`, never by inlining it with `${{ }}`.
- Inputs reach the script only through environment variables and are validated. Paths are
  quoted, and `dir` must stay inside the workspace even through symlinks.
- `gh` telemetry is disabled (`GH_TELEMETRY=false`, `DO_NOT_TRACK=1`).
- The token reaches `gh` as `GH_TOKEN` and is never printed. The action needs only read access.
  Give the job the least permissions it needs, and use `persist-credentials: false` on
  checkout.
- Files are only changed inside skill directories under `dir`. `gh` also records installs in
  `~/.agents/.skill-lock.json` in the runner's home directory, which is outside the workspace.
- Transient failures are retried up to 3 times with increasing delays (5 s, then 10 s). Two
  environment variables tune this: `RETRY_ATTEMPTS` (default `3`) and `RETRY_DELAY` (seconds,
  default `5`).
- No commits, pushes or pull requests are made by the action.
- Pin the action to a full commit SHA for the strongest guarantee:

  ```yaml
  uses: erseco/update-agent-skills@<full-40-character-sha> # v1.0.0
  ```

## Versioning and releases

This action follows [Semantic Versioning](https://semver.org/):

- `v1.0.0`, `v1.0.1`, … are immutable release tags.
- `v1` is a movable major tag that always points at the latest `v1.x.y`.
- Breaking changes to inputs, outputs or behaviour are released as `v2`.

Choose how to reference it:

| Reference | Trade-off |
|---|---|
| `@v1` | Receives compatible fixes automatically |
| `@v1.0.0` | Fixed release |
| `@<commit-sha>` | Fully immutable; recommended for security-sensitive repositories (Dependabot can keep it updated) |

### Release procedure (maintainers)

1. Make sure the [Test workflow](.github/workflows/test.yml) is green on `main`.
2. Tag the release and push the tag. The workflow runs again on the tag.

   ```bash
   git tag -a v1.0.0 -m "v1.0.0"
   git push origin v1.0.0
   ```

3. Once the tag's run is green, create the GitHub release from `v1.0.0`. Tick
   **Publish this Action to the GitHub Marketplace** if you want a listing; this requires
   accepting the Marketplace agreement and 2FA.
4. Move the major tag:

   ```bash
   git tag -fa v1 -m "v1" "v1.0.0^{}"
   git push origin v1 --force
   ```

   Never create a GitHub *release* for `v1`. With
   [immutable releases](https://docs.github.com/en/code-security/supply-chain-security/understanding-your-software-supply-chain/immutable-releases)
   enabled, a tag attached to a release cannot be moved or deleted. `v1` must stay a plain tag.

## Differences from the reference action

This action is an independent, simpler reimplementation inspired by
[`devantler-tech/.github/actions/update-agent-skills`](https://github.com/devantler-tech/.github/tree/main/actions/update-agent-skills)
(Apache-2.0). No code was copied. Its inputs and outputs are a compatible subset, so
`uses: erseco/update-agent-skills@v1` with `dir`, `dry-run`, `unpin`, `gh-version` and
`github-token` works as a drop-in replacement.

| Feature | Here |
|---|---|
| `dir`, `dry-run`, `unpin`, `gh-version`, `github-token` inputs | Retained |
| `changed` and `updated-skills` outputs | Retained |
| `updated-files` output | Added |
| Whole-directory change detection (content, exec bit, symlinks, `.git` excluded) | Retained |
| Per-parent `--dir` discovery for nested layouts | Retained |
| Bounded retries | Simplified: retries inline instead of a separate process-group-managed helper |
| Boolean inputs | Simplified: only `true`/`false`, not `1`/`yes` |
| Unresolvable upstreams (`! Skipping …`, which `gh` reports with exit 0) | Added: fails the run instead of reporting "up to date" |
| Workspace containment check for `dir` | Added |
| Workflow-command injection guard for `gh` output | Added |
| Automatic download of a newer `gh` (attestation-verified) | Omitted: the action fails with instructions instead. Hosted runners already ship a new enough `gh`, and not downloading binaries removes a supply-chain surface |
| `pins` input (hold a skill at a reviewed commit) | Omitted: use `gh skill install --pin` locally and commit |
| `mark-internal` input (set `metadata.internal: true`, needs `yq`) | Omitted: add a step after this action if you need it |

## Development

```bash
bash tests/run.sh            # offline tests using tests/mock-gh
bash tests/run.sh symlink    # run only tests whose name contains "symlink"
shellcheck -x scripts/*.sh tests/run.sh tests/mock-gh/gh
actionlint
```

## License

[MIT](LICENSE)
