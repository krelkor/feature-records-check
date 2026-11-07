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

  out=$(bash "$CHECK_SCRIPT" "$dir" 2>&1) || rc=$?
  assert_equals 0 "$rc" "report-only mode exits 0 despite errors"
  assert_contains "$out" "[ERROR]" "findings are printed in report-only mode"

  rc=0
  out=$(bash "$CHECK_SCRIPT" "$dir" --blocking 2>&1) || rc=$?
  assert_equals 1 "$rc" "--blocking flag forces non-zero exit on errors"

  pass "report-only mode exits 0 with findings; --blocking forces exit 1"
}

test_next_page_project
test_file_surface_project
test_default_surfaces_fallback
test_report_only_mode

echo "All $passed tests passed!"
exit 0
