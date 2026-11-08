# Feature Records Check

`feature-records-check` is a generic, portable checker that verifies feature record completeness, coverage, and source tracking in git repositories.

This package is a generic checker and carries no project-specific rules.
Each project defines its own rules, surface patterns, and records folder in its own `.agents/pipeline.yaml` on its default branch.

## What It Checks

The checker evaluates seven consistency checks across feature surfaces, records, and the index:

1. **Frontmatter valid**: Type must be `Feature`, required fields (`title`, `description`, `resource`, `tags`, `sources`, `generated`, `status`, `automation`, `number_changing`) must be present and well-formed.
2. **Sources and resource exist**: Every path listed in `sources` must exist in the repository; every route or file specified in `resource` must exist.
3. **Feature surface coverage**: Every discovered feature surface must be covered by a feature record; every index row must point to an existing record file.
4. **Index table agreement**: Each index row must match its record's resource and automation level.
5. **Stale date warnings**: Records with `stale_after` dates in the past emit warnings to prompt re-verification.
6. **Changed source tracking**: When files tracked by a record's `sources` are modified in a PR, either the record must be updated or the PR description must carry an `Opt-out: record - <reason>` declaration.
7. **Section headings**: Each record body must contain exactly the four required level-two section headings in order (`Sub-features`, `How to get to it (user POV)`, `Driving it with <harness>`, `Gotchas`).

## Configuration

Projects configure the check in `.agents/pipeline.yaml` on their default branch.

### Configuration Keys

- `feature_map` *(string, default: `docs/feature-map`)*: The repository-relative path to the feature records directory containing markdown records and `README.md`.
- `feature_records.mode` *(string, default: `report-only`)*: Execution mode. `report-only` prints findings as warnings and exits 0; `blocking` prints findings as errors and exits 1 if any error findings are present.
- `feature_records.blocking_after` *(string, optional)*: Date (`YYYY-MM-DD` or ISO 8601) after which `report-only` mode automatically transitions to `blocking`.
- `feature_records.surfaces` *(list, optional)*: List of feature surface definitions. Each entry requires `glob` and `kind`. When omitted, defaults to Next.js App Router behaviour (`src/app/**/page.tsx`).

### Surface Kinds

- `next-page`: App Router pages where routes are derived from `page.tsx` (e.g. `src/app/(app)/settings/page.tsx` maps to route `/settings`).
- `file`: General file surfaces (e.g. command handlers, bot modules, skills). The surface id is the repository-relative file path, covered when a record lists the file in its `sources` or names it as its `resource`.

### Configuration Examples

#### Example 1: Next.js Web Application (`next-page`)

```yaml
feature_map: docs/feature-map
feature_records:
  mode: blocking
  surfaces:
    - glob: "src/app/**/page.tsx"
      kind: next-page
```

#### Example 2: Python Bot, CLI, or Backend Service (`file`)

```yaml
feature_map: docs/features
feature_records:
  mode: blocking
  surfaces:
    - glob: "handlers/*.py"
      kind: file
    - glob: "skills/*/SKILL.md"
      kind: file
```

## Running Locally

Run directly against the current repository:

```bash
# Report-only or project-configured mode
./feature-records-check.sh

# Force blocking mode (exits non-zero on error)
./feature-records-check.sh --blocking

# Target another project directory and base ref
./feature-records-check.sh --project /path/to/project --base-ref main

# Provide PR body text to evaluate source change opt-outs
./feature-records-check.sh --pr-body "Opt-out: record - refactoring internal helpers"

# Output structured JSON
./feature-records-check.sh --json
```

## Running It in GitHub Actions

Fetch this repository at a pinned tag so every project runs the same version, and upgrade by changing the tag.
Put this in `.github/workflows/feature-records.yml` in the project.

```yaml
name: feature-records
on: pull_request_target
jobs:
  feature-records:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
          ref: ${{ github.event.pull_request.head.sha }}
      - uses: actions/checkout@v4
        with:
          repository: krelkor/feature-records-check
          ref: v0.1.1
          path: .feature-records-check
      - run: pip install pyyaml
      - name: Check feature records
        env:
          PR_BODY: ${{ github.event.pull_request.body }}
        run: |
          .feature-records-check/feature-records-check.sh \
            --base-ref "origin/${{ github.base_ref }}" \
            --pr-body "$PR_BODY"
```

The workflow triggers on `pull_request_target`, so its definition comes from the default branch, while the first checkout fetches the pull request head so the checker can read the changed files; nothing from the pull request is executed.

The checker reads the project's rules from the default branch, never from the pull request, so a pull request cannot loosen its own check.
This workflow is an example and has not yet been run on a hosted runner; confirm it on the first pull request.

## Opting Out of Record Updates in PRs

When modifying files listed in an existing feature record's `sources` without changing feature behavior, add an opt-out line to the PR description:

```markdown
Opt-out: record - refactored database queries without changing user-visible behavior
```

The checker recognizes this declaration, reports it, and passes check 6.
