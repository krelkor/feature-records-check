#!/usr/bin/env bash
# test.sh - portable tests for feature-records-check
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/feature-records-check.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/feature-records-test.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

passed=0
failed=0

pass() {
  echo "ok - $1"
  passed=$((passed + 1))
}

fail() {
  echo "not ok - $1: $2" >&2
  failed=$((failed + 1))
}

assert_equals() {
  local expected=$1 actual=$2 msg=$3
  if [ "$expected" = "$actual" ]; then
    return 0
  fi
  fail "$msg" "expected '$expected' but got '$actual'"
  return 1
}

assert_contains() {
  local haystack=$1 needle=$2 msg=$3
  if [[ "$haystack" == *"$needle"* ]]; then
    return 0
  fi
  fail "$msg" "expected output to contain '$needle'"
  return 1
}

assert_not_contains() {
  local haystack=$1 needle=$2 msg=$3
  if [[ "$haystack" != *"$needle"* ]]; then
    return 0
  fi
  fail "$msg" "expected output not to contain '$needle'"
  return 1
}

RECORD_BODY='## Sub-features

- view

## How to get to it (user POV)

Navigate to /

## Driving it with test-harness

Drive it.

## Gotchas

None.'

test_next_page_project() {
  local dir="$TMP_DIR/next_project" out rc=0
  mkdir -p "$dir/.agents" "$dir/src/app/(app)" "$dir/docs/feature-map" "$dir/src/components"
  git init -q -b main "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "tester"

  cat > "$dir/.agents/pipeline.yaml" <<'EOF'
feature_map: docs/feature-map
feature_records:
  mode: blocking
  surfaces:
    - glob: "src/app/**/page.tsx"
      kind: next-page
EOF

  printf 'export default function Page() { return null; }\n' > "$dir/src/app/(app)/page.tsx"
  printf 'export const Nav = () => null;\n' > "$dir/src/components/nav.tsx"

  cat > "$dir/docs/feature-map/home.md" <<EOF
---
type: Feature
title: Home
description: Home page
resource: /
tags: [home]
sources:
  - { id: page, resource: src/app/(app)/page.tsx, title: "code: page" }
  - { id: nav, resource: src/components/nav.tsx, title: "code: nav" }
generated: { by: "test", at: "2026-11-06T12:00:00Z" }
status: draft
automation: mapped
number_changing: false
---

$RECORD_BODY
EOF

  cat > "$dir/docs/feature-map/README.md" <<'EOF'
# Feature Map

| Feature | Trigger keywords | Route | Automation | Record |
|---|---|---|---|---|
| Home | home | `/` | mapped | [home.md](home.md) |
EOF

  git -C "$dir" add -A
  git -C "$dir" commit -qm "main base"

  # Base check passes
  out=$(bash "$CHECK_SCRIPT" "$dir" 2>&1) || rc=$?
  assert_equals 0 "$rc" "base next-page project passes"

  # Missing record on new page fails in blocking mode
  git -C "$dir" checkout -qb pr
  mkdir -p "$dir/src/app/(app)/settings"
  printf 'export default () => null;\n' > "$dir/src/app/(app)/settings/page.tsx"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "add settings page without record"

  rc=0
  out=$(bash "$CHECK_SCRIPT" "$dir" 2>&1) || rc=$?
  assert_equals 1 "$rc" "missing record on new page fails"
  assert_contains "$out" "page route /settings" "failure names missing route"
  assert_contains "$out" "has no index row in docs/feature-map/README.md and no record" "failure explains lack of record"

  # Editing watched source without record update fails
  git -C "$dir" checkout -qb pr-source main
  printf 'export const Nav = () => "changed";\n' > "$dir/src/components/nav.tsx"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "change watched source"

  rc=0
  out=$(bash "$CHECK_SCRIPT" "$dir" --pr-body "" 2>&1) || rc=$?
  assert_equals 1 "$rc" "editing source without record update fails"
  assert_contains "$out" "docs/feature-map/home.md" "error names record"
  assert_contains "$out" "src/components/nav.tsx" "error names modified source"

  # Same change with opt-out passes
  rc=0
  out=$(bash "$CHECK_SCRIPT" "$dir" --pr-body "Opt-out: record - internal refactoring" 2>&1) || rc=$?
  assert_equals 0 "$rc" "editing source with Opt-out in PR description passes"
  assert_contains "$out" "Opt-out: record - internal refactoring" "opt-out reported"

  pass "next-page project: coverage, blocking failures, and PR opt-outs work"
}

test_file_surface_project() {
  local dir="$TMP_DIR/file_project" out rc=0
  mkdir -p "$dir/.agents" "$dir/handlers" "$dir/docs/features"
  git init -q -b main "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "tester"

  cat > "$dir/.agents/pipeline.yaml" <<'EOF'
feature_map: docs/features
feature_records:
  mode: blocking
  surfaces:
    - glob: "handlers/*.py"
      kind: file
EOF

  printf 'def handle_auth(): return True\n' > "$dir/handlers/auth.py"

  cat > "$dir/docs/features/auth.md" <<EOF
---
type: Feature
title: Authentication
description: User authentication handler
resource: handlers/auth.py
tags: [auth]
sources:
  - { id: handler, resource: handlers/auth.py, title: "Auth handler" }
generated: { by: "test", at: "2026-11-06T12:00:00Z" }
status: draft
automation: mapped
number_changing: false
---

$RECORD_BODY
EOF

  cat > "$dir/docs/features/README.md" <<'EOF'
# Features

| Feature | Trigger keywords | Resource | Automation | Record |
|---|---|---|---|---|
| Authentication | auth | `handlers/auth.py` | mapped | [auth.md](auth.md) |
EOF

  git -C "$dir" add -A
  git -C "$dir" commit -qm "main base"

  # Base passes
  out=$(bash "$CHECK_SCRIPT" "$dir" 2>&1) || rc=$?
  assert_equals 0 "$rc" "base file project passes"

  # Adding new file surface without record fails
  git -C "$dir" checkout -qb pr
  printf 'def handle_orders(): return True\n' > "$dir/handlers/orders.py"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "add orders handler without record"

  rc=0
  out=$(bash "$CHECK_SCRIPT" "$dir" 2>&1) || rc=$?
  assert_equals 1 "$rc" "adding file surface without record fails in blocking mode"
  assert_contains "$out" "handlers/orders.py" "failure names uncovered file"
  assert_contains "$out" "has no feature record covering it" "failure explains lack of covering record"

  # Adding covering record passes
  cat > "$dir/docs/features/orders.md" <<EOF
---
type: Feature
title: Orders
description: Order processing handler
resource: handlers/orders.py
tags: [orders]
sources:
  - { id: handler, resource: handlers/orders.py, title: "Orders handler" }
generated: { by: "test", at: "2026-11-06T12:00:00Z" }
status: draft
automation: mapped
number_changing: false
---

$RECORD_BODY
EOF

  cat > "$dir/docs/features/README.md" <<'EOF'
# Features

| Feature | Trigger keywords | Resource | Automation | Record |
|---|---|---|---|---|
| Authentication | auth | `handlers/auth.py` | mapped | [auth.md](auth.md) |
| Orders | orders | `handlers/orders.py` | mapped | [orders.md](orders.md) |
EOF

  git -C "$dir" add -A
  git -C "$dir" commit -qm "add orders record"

  rc=0
  out=$(bash "$CHECK_SCRIPT" "$dir" 2>&1) || rc=$?
  assert_equals 0 "$rc" "file project with covering record passes"

  pass "file-surface project: detects uncovered surfaces and passes with covering record"
}

test_default_surfaces_fallback() {
  local dir="$TMP_DIR/default_project" out rc=0
  mkdir -p "$dir/.agents" "$dir/src/app" "$dir/docs/feature-map" "$dir/scripts"
  git init -q -b main "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "tester"

  cat > "$dir/.agents/pipeline.yaml" <<'EOF'
feature_records:
  mode: blocking
EOF

  printf 'export default () => null;\n' > "$dir/src/app/page.tsx"

  cat > "$dir/docs/feature-map/home.md" <<EOF
---
type: Feature
title: Home
description: Home page
resource: /
tags: [home]
sources:
  - { id: page, resource: src/app/page.tsx, title: "code: page" }
generated: { by: "test", at: "2026-11-06T12:00:00Z" }
status: draft
automation: mapped
number_changing: false
---

$RECORD_BODY
EOF

  cat > "$dir/docs/feature-map/README.md" <<'EOF'
# Feature Map

| Feature | Trigger keywords | Route | Automation | Record |
|---|---|---|---|---|
| Home | home | `/` | mapped | [home.md](home.md) |
EOF

  git -C "$dir" add -A
  git -C "$dir" commit -qm "main base"

  git -C "$dir" checkout -qb pr

  # Non-page file does not require record
  printf 'echo hello\n' > "$dir/scripts/hello.sh"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "add script"

  out=$(bash "$CHECK_SCRIPT" "$dir" 2>&1) || rc=$?
  assert_equals 0 "$rc" "non-page file does not fail under default surfaces"

  # Adding Next.js page without record fails
  mkdir -p "$dir/src/app/dashboard"
  printf 'export default () => null;\n' > "$dir/src/app/dashboard/page.tsx"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "add dashboard page without record"

  rc=0
  out=$(bash "$CHECK_SCRIPT" "$dir" 2>&1) || rc=$?
  assert_equals 1 "$rc" "adding page.tsx without record fails under default surfaces"
  assert_contains "$out" "page route /dashboard" "failure names route"

  pass "default surfaces fallback: defaults to Next.js page.tsx behaviour"
}

test_report_only_mode() {
  local dir="$TMP_DIR/report_only_project" out rc=0
  mkdir -p "$dir/.agents" "$dir/src/app" "$dir/docs/feature-map"
  git init -q -b main "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "tester"

  cat > "$dir/.agents/pipeline.yaml" <<'EOF'
feature_records:
  mode: report-only
EOF

  printf 'export default () => null;\n' > "$dir/src/app/page.tsx"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "main base without record"

  local missing_record='feature-records-page: page route / (src/app/page.tsx) has no index row in docs/feature-map/README.md and no record'

  out=$(bash "$CHECK_SCRIPT" "$dir" 2>&1) || rc=$?
  assert_equals 0 "$rc" "report-only mode exits 0 despite findings"
  assert_equals "[WARNING] $missing_record" "$out" "report-only mode labels findings as warnings"

  rc=0
  out=$(bash "$CHECK_SCRIPT" "$dir" --blocking 2>&1) || rc=$?
  assert_equals 1 "$rc" "--blocking flag forces non-zero exit on findings"
  assert_equals "[ERROR] $missing_record" "$out" "blocking mode labels findings as errors"

  pass "report-only mode prints warnings and exits 0; --blocking prints errors and exits 1"
}

test_readme_workflow_example() {
  local readme="$SCRIPT_DIR/README.md" block

  block=$(awk '/^## Running It in GitHub Actions$/ { found=1 } found && /^```yaml$/ { inside=1; next } inside && /^```$/ { exit } inside { print }' "$readme")
  if [ -z "$block" ]; then
    fail "README documents a GitHub Actions workflow example" "no yaml block found under the GitHub Actions heading"
    return 1
  fi
  assert_contains "$block" "on: pull_request_target" "workflow example triggers on pull_request_target"
  if printf '%s\n' "$block" | grep -qx 'on: pull_request'; then
    fail "workflow example does not use the pull_request trigger" "found a bare 'on: pull_request' line"
    return 1
  fi
  assert_contains "$block" "ref: v0.1.1" "workflow example pins the current version"
  assert_not_contains "$block" "ref: v0.1.0" "workflow example does not pin the previous version"

  pass "README workflow example triggers on pull_request_target and pins v0.1.1"
}

# --- cli-command surfaces -------------------------------------------------

sha256_of_file() {
  python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"
}

# setup_cli_project <dir> - CLI-only project with captured evidence, no record yet.
setup_cli_project() {
  local dir=$1
  mkdir -p "$dir/.agents" "$dir/src/cli" "$dir/docs/feature-map/evidence"
  git init -q -b main "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "tester"

  cat > "$dir/.agents/pipeline.yaml" <<'EOF'
feature_map: docs/feature-map
feature_records:
  mode: blocking
  surfaces:
    - kind: cli-command
      commands:
        - vocaas ingest
EOF

  printf 'export const ingest = () => 0;\n' > "$dir/src/cli/ingest.ts"
  printf '{"items":2,"ok":true}\n' > "$dir/docs/feature-map/evidence/ingest-output.json"
  printf '{"tables":{"items":2}}\n' > "$dir/docs/feature-map/evidence/ingest-db-view.json"
  printf '{"schema_version":1,"items":2}\n' > "$dir/docs/feature-map/evidence/vocaas-db.snapshot.json"
  cat > "$dir/docs/feature-map/README.md" <<'EOF'
# Feature Map

| Feature | Trigger keywords | Command | Automation | Record |
|---|---|---|---|---|
EOF

  git -C "$dir" add -A
  git -C "$dir" commit -qm "captured evidence without a record"
}

# write_cli_record <dir> <command_evidence yaml block>
write_cli_record() {
  local dir=$1 evidence=$2
  cat > "$dir/docs/feature-map/ingest.md" <<EOF
---
type: Feature
title: Ingest
description: Ingest source records into the SQLite database
resource: vocaas ingest
tags: [cli, ingest]
sources:
  - { id: cli, resource: src/cli/ingest.ts, title: "code: ingest command" }
generated: { by: "machine:verify-ingest", at: "2026-11-06T12:00:00Z" }
status: draft
automation: automated
runner: scripts/verify-ingest.sh
number_changing: true
${evidence}
---

$RECORD_BODY
EOF
  cat > "$dir/docs/feature-map/README.md" <<'EOF'
# Feature Map

| Feature | Trigger keywords | Command | Automation | Record |
|---|---|---|---|---|
| Ingest | ingest | `vocaas ingest` | automated | [ingest.md](ingest.md) |
EOF
  git -C "$dir" add -A
  git -C "$dir" commit -qm "add ingest record"
}

test_cli_command_project() {
  local dir="$TMP_DIR/cli_project" out rc=0 sha hash evidence
  setup_cli_project "$dir"
  sha=$(git -C "$dir" rev-parse HEAD)
  hash=$(sha256_of_file "$dir/docs/feature-map/evidence/ingest-output.json")
  evidence=$(cat <<EOF
command_evidence:
  command: "vocaas ingest --db data/vocaas.db"
  exit_code: 0
  git_sha: "$sha"
  database: data/vocaas.db
  snapshot: docs/feature-map/evidence/vocaas-db.snapshot.json
  database_view: docs/feature-map/evidence/ingest-db-view.json
  output_file: docs/feature-map/evidence/ingest-output.json
  output_hash: "sha256:$hash"
EOF
)
  write_cli_record "$dir" "$evidence"

  out=$(bash "$CHECK_SCRIPT" "$dir" 2>&1) || rc=$?
  assert_equals 0 "$rc" "cli-command project with captured evidence passes"
  assert_contains "$out" "feature records consistent" "passing cli-command project reports consistency"
  assert_not_contains "$out" "[ERROR]" "passing cli-command project has no error findings"

  # A declared command with no covering record fails in blocking mode.
  cat > "$dir/.agents/pipeline.yaml" <<'EOF'
feature_map: docs/feature-map
feature_records:
  mode: blocking
  surfaces:
    - kind: cli-command
      commands:
        - vocaas ingest
        - vocaas export
EOF
  git -C "$dir" add -A
  git -C "$dir" commit -qm "declare an uncovered command"

  rc=0
  out=$(bash "$CHECK_SCRIPT" "$dir" 2>&1) || rc=$?
  assert_equals 1 "$rc" "declared command without a record fails in blocking mode"
  assert_contains "$out" 'cli command `vocaas export` has no feature record covering it' "failure names the uncovered command"

  pass "cli-command project: evidence passes, uncovered command fails"
}

test_cli_command_missing_provenance() {
  local dir="$TMP_DIR/cli_missing_evidence" out rc=0 sha hash evidence
  setup_cli_project "$dir"
  sha=$(git -C "$dir" rev-parse HEAD)
  hash=$(sha256_of_file "$dir/docs/feature-map/evidence/ingest-output.json")

  # Partial provenance: no database_view, no output_hash.
  evidence=$(cat <<EOF
command_evidence:
  command: "vocaas ingest --db data/vocaas.db"
  exit_code: 0
  git_sha: "$sha"
  database: data/vocaas.db
  output_file: docs/feature-map/evidence/ingest-output.json
EOF
)
  write_cli_record "$dir" "$evidence"

  rc=0
  out=$(bash "$CHECK_SCRIPT" "$dir" 2>&1) || rc=$?
  assert_equals 1 "$rc" "record with partial provenance fails"
  assert_contains "$out" "command_evidence.database_view must name the captured read-only database view" "missing database view is reported"
  assert_contains "$out" "command_evidence.output_hash must be the sha256 of the captured output" "missing output hash is reported"

  # No provenance at all.
  write_cli_record "$dir" ""
  rc=0
  out=$(bash "$CHECK_SCRIPT" "$dir" 2>&1) || rc=$?
  assert_equals 1 "$rc" "record without provenance fails"
  assert_contains "$out" "command_evidence is required for a cli-command record" "absent evidence block is reported"

  pass "cli-command provenance: missing fields and absent block fail"
}

test_cli_command_output_hash_mismatch() {
  local dir="$TMP_DIR/cli_hash_mismatch" out rc=0 sha evidence
  local wrong_hash='0000000000000000000000000000000000000000000000000000000000000000'
  setup_cli_project "$dir"
  sha=$(git -C "$dir" rev-parse HEAD)
  evidence=$(cat <<EOF
command_evidence:
  command: "vocaas ingest --db data/vocaas.db"
  exit_code: 0
  git_sha: "$sha"
  database: data/vocaas.db
  snapshot: docs/feature-map/evidence/vocaas-db.snapshot.json
  database_view: docs/feature-map/evidence/ingest-db-view.json
  output_file: docs/feature-map/evidence/ingest-output.json
  output_hash: "sha256:$wrong_hash"
EOF
)
  write_cli_record "$dir" "$evidence"

  rc=0
  out=$(bash "$CHECK_SCRIPT" "$dir" 2>&1) || rc=$?
  assert_equals 1 "$rc" "record whose output hash does not match its evidence file fails"
  assert_contains "$out" "command_evidence.output_hash $wrong_hash does not match the sha256 of docs/feature-map/evidence/ingest-output.json" "hash mismatch names the evidence file"

  # Same finding is a warning in report-only mode, as for every other kind.
  rc=0
  out=$(bash "$CHECK_SCRIPT" "$dir" --report-only 2>&1) || rc=$?
  assert_equals 0 "$rc" "report-only mode does not block on a command evidence finding"
  assert_contains "$out" "[WARNING] feature-records-command-evidence:" "report-only mode labels the finding as a warning"

  pass "cli-command evidence: output hash is verified and report-only stays non-blocking"
}

test_existing_kinds_with_cli_command() {
  local dir="$TMP_DIR/mixed_kinds" out rc=0 sha hash evidence
  mkdir -p "$dir/.agents" "$dir/handlers" "$dir/src/cli" "$dir/docs/features/evidence"
  git init -q -b main "$dir"
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "tester"

  cat > "$dir/.agents/pipeline.yaml" <<'EOF'
feature_map: docs/features
feature_records:
  mode: blocking
  surfaces:
    - glob: "handlers/*.py"
      kind: file
    - kind: cli-command
      commands:
        - vocaas ingest
EOF

  printf 'def handle_auth(): return True\n' > "$dir/handlers/auth.py"
  printf 'export const ingest = () => 0;\n' > "$dir/src/cli/ingest.ts"
  printf '{"items":2}\n' > "$dir/docs/features/evidence/ingest-output.json"
  printf '{"tables":{"items":2}}\n' > "$dir/docs/features/evidence/ingest-db-view.json"

  cat > "$dir/docs/features/auth.md" <<EOF
---
type: Feature
title: Authentication
description: User authentication handler
resource: handlers/auth.py
tags: [auth]
sources:
  - { id: handler, resource: handlers/auth.py, title: "Auth handler" }
generated: { by: "test", at: "2026-11-06T12:00:00Z" }
status: draft
automation: mapped
number_changing: false
---

$RECORD_BODY
EOF

  cat > "$dir/docs/features/README.md" <<'EOF'
# Features

| Feature | Trigger keywords | Resource | Automation | Record |
|---|---|---|---|---|
| Authentication | auth | `handlers/auth.py` | mapped | [auth.md](auth.md) |
EOF

  git -C "$dir" add -A
  git -C "$dir" commit -qm "file surface and cli evidence without a command record"
  sha=$(git -C "$dir" rev-parse HEAD)
  hash=$(sha256_of_file "$dir/docs/features/evidence/ingest-output.json")
  evidence=$(cat <<EOF
command_evidence:
  command: "vocaas ingest --db data/vocaas.db"
  exit_code: 0
  git_sha: "$sha"
  database: data/vocaas.db
  database_view: docs/features/evidence/ingest-db-view.json
  output_file: docs/features/evidence/ingest-output.json
  output_hash: "sha256:$hash"
EOF
)
  cat > "$dir/docs/features/ingest.md" <<EOF
---
type: Feature
title: Ingest
description: Ingest source records into the SQLite database
resource: vocaas ingest
tags: [cli, ingest]
sources:
  - { id: cli, resource: src/cli/ingest.ts, title: "code: ingest command" }
generated: { by: "machine:verify-ingest", at: "2026-11-06T12:00:00Z" }
status: draft
automation: mapped
number_changing: false
${evidence}
---

$RECORD_BODY
EOF

  cat > "$dir/docs/features/README.md" <<'EOF'
# Features

| Feature | Trigger keywords | Resource | Automation | Record |
|---|---|---|---|---|
| Authentication | auth | `handlers/auth.py` | mapped | [auth.md](auth.md) |
| Ingest | ingest | `vocaas ingest` | mapped | [ingest.md](ingest.md) |
EOF

  git -C "$dir" add -A
  git -C "$dir" commit -qm "add ingest record beside the file surface"

  out=$(bash "$CHECK_SCRIPT" "$dir" 2>&1) || rc=$?
  assert_equals 0 "$rc" "file and cli-command surfaces coexist and pass"

  # The file kind still enforces coverage when a cli-command surface is configured.
  printf 'def handle_orders(): return True\n' > "$dir/handlers/orders.py"
  git -C "$dir" add -A
  git -C "$dir" commit -qm "add an uncovered file surface"

  rc=0
  out=$(bash "$CHECK_SCRIPT" "$dir" 2>&1) || rc=$?
  assert_equals 1 "$rc" "file surface coverage still fails when cli-command is configured"
  assert_contains "$out" "handlers/orders.py" "failure names the uncovered file"

  pass "existing file kind keeps its behaviour beside the new cli-command kind"
}

# Existing kinds' test functions above are unchanged; they run verbatim here.
test_next_page_project
test_file_surface_project
test_default_surfaces_fallback
test_report_only_mode
test_readme_workflow_example
test_cli_command_project
test_cli_command_missing_provenance
test_cli_command_output_hash_mismatch
test_existing_kinds_with_cli_command

echo "All $passed tests passed!"
exit 0
