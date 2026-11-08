#!/usr/bin/env bash
# feature-records-check.sh - enforce feature record completeness, coverage,
# and source tracking for opted-in repositories.
#
# Part of feature-records enforcement. Projects opt in by declaring
# `feature_records` or `feature_map` in `.agents/pipeline.yaml` on their default branch.
#
# Mode:
#   report-only   Prints findings labelled as warnings and exits 0. Default during initial rollout.
#   blocking      Prints findings labelled as errors and exits non-zero (1) on any error.
#   A project transitions from report-only to blocking by setting `mode: blocking`
#   or `blocking_after: <YYYY-MM-DD>` in `.agents/pipeline.yaml`.
#
# The seven checks:
#   1 Frontmatter valid (type: Feature, required fields, enums, stable/deprecated/automated rules)
#   2 Every `sources` path exists; every record's `resource` route or file exists
#   3 Every feature surface has a record (and index row for pages); every index row has a record file
#   4 Each index row matches its record (route/resource, automation)
#   5 `stale_after` in the past warns (not an error)
#   6 A changed `sources` file requires an updated record or PR line `Opt-out: record - <reason>`
#   7 Each record body has exactly the four level-two section headings
#
# Usage:
#   feature-records-check.sh [<project-dir>] [<base-ref>] [options]
# Options:
#   --project <dir>          Target project directory (default: current directory)
#   --base-ref <ref>         Base git ref for main-side comparison
#   --head-ref <ref>         Head git ref for comparison (default: HEAD)
#   --pr-body <text>         PR description text to search for opt-outs
#   --pr-body-file <path>    File containing PR description text
#   --evidence-file <path>   Write extracted opt-outs to pr-evidence.json for the PR card
#   --findings-file <path>   Write findings JSON to file
#   --mode <mode>            Force mode: report-only or blocking
#   --blocking               Shortcut for --mode blocking
#   --report-only            Shortcut for --mode report-only
#   --json                   Output JSON verdict to stdout
#   --sources-of <feature>   Print the `sources` paths of the named feature's record, one per
#                            line, read from the index and record on the base ref, then exit.
#                            Names match the index Feature column like intake (case-insensitive,
#                            & equals and). Exit 1 when no index row or record carries it.
#                            fm-intake-check.sh uses this to expand a feature-named fence.
#   --help, -h               Show this help
set -eu

usage() {
  sed -n '2,/^set -eu$/s/^# \{0,1\}//p' "$0"
}

project=''
base_ref=''
head_ref=''
pr_body=''
pr_body_set=0
pr_body_file=''
evidence_file=''
findings_file=''
json_out=0
mode_override=''
sources_of=''

while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --project|--base-ref|--head-ref|--pr-body|--pr-body-file|--evidence-file|--findings-file|--mode|--sources-of)
      [ "$#" -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
      case "$1" in
        --project) project=$2 ;;
        --base-ref) base_ref=$2 ;;
        --head-ref) head_ref=$2 ;;
        --pr-body) pr_body=$2; pr_body_set=1 ;;
        --pr-body-file) pr_body_file=$2 ;;
        --evidence-file) evidence_file=$2 ;;
        --findings-file) findings_file=$2 ;;
        --mode) mode_override=$2 ;;
        --sources-of) sources_of=$2 ;;
      esac
      shift 2
      ;;
    --blocking)
      mode_override="blocking"
      shift
      ;;
    --report-only)
      mode_override="report-only"
      shift
      ;;
    --json)
      json_out=1
      shift
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown argument $1" >&2
      exit 2
      ;;
    *)
      if [ -z "$project" ]; then
        project=$1
      elif [ -z "$base_ref" ]; then
        base_ref=$1
      else
        echo "error: unexpected argument $1" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

project=${project:-.}
project=$(cd "$project" 2>/dev/null && pwd) || { echo "error: project directory not found: $project" >&2; exit 2; }

if [ -z "$base_ref" ]; then
  base_ref=${FEATURE_RECORDS_BASE_REF:-}
fi

if [ "$pr_body_set" -eq 0 ] && [ -n "$pr_body_file" ] && [ -f "$pr_body_file" ]; then
  pr_body=$(cat "$pr_body_file")
  pr_body_set=1
fi

if [ "$pr_body_set" -eq 0 ] && [ -n "${FEATURE_RECORDS_PR_BODY+x}" ]; then
  pr_body="$FEATURE_RECORDS_PR_BODY"
  pr_body_set=1
fi

command -v python3 >/dev/null || { echo "error: feature-records-check requires python3" >&2; exit 1; }

exec python3 - "$project" "$base_ref" "$mode_override" "$pr_body_set" "$pr_body" "$evidence_file" "$findings_file" "$json_out" "$sources_of" "$head_ref" <<'PY'
import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("error: feature-records-check requires PyYAML (python3 -m pip install pyyaml)", file=sys.stderr)
    sys.exit(1)

project_dir = Path(sys.argv[1]).resolve()
base_ref_arg = sys.argv[2]
mode_override_arg = sys.argv[3]
pr_body_set = (sys.argv[4] == "1")
pr_body_arg = sys.argv[5] if pr_body_set else None
evidence_file_arg = sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] else None
findings_file_arg = sys.argv[7] if len(sys.argv) > 7 and sys.argv[7] else None
json_out_arg = (sys.argv[8] == "1") if len(sys.argv) > 8 else False
sources_of_arg = sys.argv[9] if len(sys.argv) > 9 else ""
head_ref_arg = sys.argv[10] if len(sys.argv) > 10 and sys.argv[10] else "HEAD"

MAIN_REFS = ("origin/main", "main", "origin/master", "master", "origin/HEAD")

now = datetime.datetime.now(datetime.timezone.utc)


def git_cmd(args, cwd=project_dir):
    try:
        res = subprocess.run(
            ["git"] + args,
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        return res.returncode == 0, res.stdout
    except Exception:
        return False, ""


def resolve_base_ref(specified):
    if specified:
        ok, _ = git_cmd(["rev-parse", "--verify", "--quiet", specified])
        if ok:
            return specified
    for candidate in MAIN_REFS:
        ok, _ = git_cmd(["rev-parse", "--verify", "--quiet", candidate])
        if ok:
            return candidate
    ok, out = git_cmd(["rev-parse", head_ref_arg])
    return out.strip() if ok else head_ref_arg


base_ref = resolve_base_ref(base_ref_arg)


def load_pipeline_yaml():
    ok, content = git_cmd(["show", f"{base_ref}:.agents/pipeline.yaml"])
    if not ok:
        local_yaml = project_dir / ".agents/pipeline.yaml"
        if local_yaml.exists():
            try:
                content = local_yaml.read_text(encoding="utf-8")
                ok = True
            except OSError:
                ok = False
    if not ok:
        return None
    try:
        parsed = yaml.safe_load(content)
        return parsed if isinstance(parsed, dict) else {}
    except Exception:
        return {}


pipeline_config = load_pipeline_yaml() or {}


def get_records_dir():
    fr_conf = pipeline_config.get("feature_records")
    configured = pipeline_config.get("feature_map")
    if not configured and isinstance(fr_conf, dict):
        configured = fr_conf.get("feature_map") or fr_conf.get("records_dir")
    raw = str(configured or "docs/feature-map").strip().rstrip("/")
    return raw or "docs/feature-map"


records_dir = get_records_dir()
index_file = f"{records_dir}/README.md"


def determine_mode():
    if mode_override_arg in ("report-only", "blocking"):
        return mode_override_arg, True
    fr_conf = pipeline_config.get("feature_records")
    has_feature_map = "feature_map" in pipeline_config
    if fr_conf is None and not has_feature_map:
        return "not-opted-in", False
    if isinstance(fr_conf, bool):
        return ("blocking" if fr_conf else "not-opted-in"), True
    if not isinstance(fr_conf, dict):
        return "report-only", True
    mode = fr_conf.get("mode") or fr_conf.get("enforce") or "report-only"
    blocking_after = fr_conf.get("blocking_after")
    if blocking_after:
        try:
            if isinstance(blocking_after, datetime.date):
                dt_cutoff = datetime.datetime.combine(
                    blocking_after, datetime.time.min, tzinfo=datetime.timezone.utc
                )
            else:
                raw_str = str(blocking_after).strip()
                if "T" in raw_str:
                    dt_cutoff = datetime.datetime.fromisoformat(raw_str.replace("Z", "+00:00"))
                else:
                    d_parsed = datetime.date.fromisoformat(raw_str)
                    dt_cutoff = datetime.datetime.combine(
                        d_parsed, datetime.time.min, tzinfo=datetime.timezone.utc
                    )
            if now >= dt_cutoff:
                mode = "blocking"
        except Exception:
            pass
    return mode, True


mode, opted_in = determine_mode()


def get_surfaces_config():
    fr_conf = pipeline_config.get("feature_records")
    surfaces = None
    if isinstance(fr_conf, dict):
        surfaces = fr_conf.get("surfaces")
    if surfaces is None:
        return [{"glob": "src/app/**/page.{tsx,ts,jsx,js}", "kind": "next-page"}]
    res = []
    if isinstance(surfaces, list):
        for entry in surfaces:
            if isinstance(entry, dict):
                g = entry.get("glob") or entry.get("pattern") or ""
                k = entry.get("kind") or entry.get("type") or "file"
                if g:
                    res.append({"glob": str(g).strip(), "kind": str(k).strip()})
            elif isinstance(entry, str) and entry.strip():
                res.append({"glob": entry.strip(), "kind": "file"})
    return res


surfaces_config = get_surfaces_config()
has_next_page = any(s["kind"] == "next-page" for s in surfaces_config)
has_file = any(s["kind"] == "file" for s in surfaces_config)


def glob_to_regex(pat):
    pat = pat.strip()
    i = 0
    n = len(pat)
    res = ["^"]
    while i < n:
        c = pat[i]
        if c == "*":
            if i + 1 < n and pat[i + 1] == "*":
                if i + 2 < n and pat[i + 2] == "/":
                    res.append(r"(?:[^/]+/)*")
                    i += 3
                    continue
                elif i > 0 and pat[i - 1] == "/":
                    res.append(r".*")
                    i += 2
                    continue
                else:
                    res.append(r".*")
                    i += 2
                    continue
            else:
                res.append(r"[^/]*")
                i += 1
                continue
        elif c == "?":
            res.append(r"[^/]")
            i += 1
            continue
        elif c == "{":
            j = pat.find("}", i)
            if j != -1:
                parts = pat[i + 1 : j].split(",")
                res.append(r"(?:" + "|".join(re.escape(p.strip()) for p in parts) + ")")
                i = j + 1
                continue
            else:
                res.append(re.escape(c))
                i += 1
                continue
        else:
            res.append(re.escape(c))
            i += 1
    res.append("$")
    return re.compile("".join(res))


compiled_surfaces = []
for sc in surfaces_config:
    compiled_surfaces.append(
        {
            "glob": sc["glob"],
            "kind": sc["kind"],
            "regex": glob_to_regex(sc["glob"]),
        }
    )


def match_surface(file_path):
    for cs in compiled_surfaces:
        if cs["regex"].match(file_path):
            return cs["kind"]
    return None


def derive_next_page_route(file_path):
    m = re.search(r"(?:^|/)(?:src/)?app/(?:(.*)/)?page\.(?:tsx|ts|jsx|js)$", file_path)
    if m:
        raw_segs = (m.group(1) or "").split("/")
        segs = [s for s in raw_segs if s and not (s.startswith("(") and s.endswith(")"))]
        return "/" + "/".join(segs)
    m_gen = re.match(r"^(?:(.*)/)?page\.(?:tsx|ts|jsx|js)$", file_path)
    if m_gen:
        raw_segs = (m_gen.group(1) or "").split("/")
        segs = [s for s in raw_segs if s and not (s.startswith("(") and s.endswith(")"))]
        return "/" + "/".join(segs)
    return None


def ticks(s):
    return re.findall(r"`([^`]+)`", s)


def split_route_cell(cell):
    red = re.search(r"redirects?", cell, flags=re.I)
    if not red:
        t = ticks(cell)
        if not t and cell.strip() and cell.strip() not in ("-", "none", "(none)"):
            t = [c.strip() for c in re.split(r"[,;]", cell) if c.strip() and c.strip() not in ("-", "none", "(none)")]
        return t, []
    before = cell[: red.start()]
    after = cell[red.end() :]
    t_before = ticks(before)
    if not t_before and before.strip() and before.strip() not in ("-", "none", "(none)"):
        t_before = [c.strip() for c in re.split(r"[,;]", before) if c.strip() and c.strip() not in ("-", "none", "(none)")]
    t_after = ticks(after)
    if not t_after and after.strip() and after.strip() not in ("-", "none", "(none)"):
        t_after = [c.strip() for c in re.split(r"[,;]", after) if c.strip() and c.strip() not in ("-", "none", "(none)")]
    return t_before, t_after


def parse_index(text):
    rows = []
    excluded = None
    for line in text.split("\n"):
        if re.match(r"^excluded (?:routes?|surfaces?|paths?|files?):", line, flags=re.I):
            found = ticks(line)
            if not found:
                colon = line.find(":")
                if colon != -1:
                    found = [c.strip() for c in line[colon + 1 :].split(",") if c.strip()]
            excluded = (excluded or []) + found
            continue
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in re.sub(r"^\||\|\s*$", "", line).split("|")]
        if len(cells) < 5 or cells[0] == "Feature" or re.match(r"^-+$", re.sub(r"[:\s]", "", cells[0])):
            continue
        link_match = re.search(r"\]\(([^)]+)\)", cells[4])
        target_record = (
            Path(os.path.normpath(os.path.join(records_dir, link_match.group(1)))).as_posix()
            if link_match
            else ""
        )
        routes, redirects = split_route_cell(cells[2])
        rows.append(
            {
                "feature": cells[0],
                "routes": routes,
                "redirects": redirects,
                "automation": cells[3],
                "record": target_record,
            }
        )
    if excluded is None:
        for l in text.split("\n"):
            if not l.startswith("|") and "are excluded" in l:
                pos = l.index("are excluded")
                found = ticks(l[:pos])
                if not found:
                    found = [c.strip() for c in l[:pos].split(",") if c.strip()]
                if found:
                    excluded = found
                break
    return rows, excluded or []


def split_record(text):
    m = re.match(r"^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$", text)
    if not m:
        return None, text, "no YAML frontmatter"
    try:
        y = yaml.safe_load(m.group(1))
        if not isinstance(y, dict):
            return None, m.group(2), "frontmatter is not a mapping"
        return y, m.group(2), None
    except Exception as e:
        return None, m.group(2), f"unparseable frontmatter: {str(e).splitlines()[0]}"


ISO_OFFSET_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:\d{2})$"
)


def is_iso(v):
    if not isinstance(v, str) or not ISO_OFFSET_RE.match(v):
        return False
    try:
        datetime.datetime.fromisoformat(v.replace("Z", "+00:00"))
        return True
    except Exception:
        return False


def non_empty_str(v):
    return isinstance(v, str) and v.strip() != ""


def is_event(v):
    return (
        isinstance(v, dict)
        and non_empty_str(v.get("by"))
        and is_iso(str(v.get("at", "")))
    )


STATUSES = ("draft", "stable", "deprecated")
AUTOMATIONS = ("mapped", "automated")


def source_paths(front):
    s = front.get("sources")
    if not isinstance(s, list):
        return []
    res = []
    for e in s:
        if isinstance(e, dict) and non_empty_str(e.get("resource")):
            res.append(Path(os.path.normpath(str(e["resource"]))).as_posix())
    return res


def frontmatter_problems(front, exists_fn):
    p = []
    if front.get("type") != "Feature":
        p.append(f"type must be Feature (got {json.dumps(front.get('type'))})")
    for k in ("title", "description"):
        if not non_empty_str(front.get(k)):
            p.append(f"{k} must be a non-empty string")
    res_val = str(front.get("resource") or "")
    if not non_empty_str(front.get("resource")):
        p.append("resource must be a non-empty string")
    elif not has_file and not res_val.startswith("/"):
        p.append('resource must be an app route starting with "/"')
    tags = front.get("tags")
    if not isinstance(tags, list) or not all(non_empty_str(t) for t in tags):
        p.append("tags must be a list of strings")
    sources = front.get("sources")
    if not isinstance(sources, list) or len(sources) == 0:
        p.append("sources must be a non-empty list")
    else:
        for idx, e in enumerate(sources):
            r = e if isinstance(e, dict) else {}
            if not non_empty_str(r.get("id")) or not non_empty_str(r.get("resource")) or not non_empty_str(r.get("title")):
                p.append(f"sources[{idx}] needs id, resource and title")
            else:
                raw_path = str(r["resource"])
                norm = Path(os.path.normpath(raw_path)).as_posix()
                if norm != raw_path or raw_path.startswith("/") or raw_path.startswith("../") or raw_path.startswith("./"):
                    p.append(f"sources[{idx}] path {raw_path} must be a canonical repository-relative path")
    gen = front.get("generated")
    if not is_event(gen):
        p.append("generated must be { by, at } with an ISO 8601 datetime and offset")
    st = str(front.get("status") or "")
    if st not in STATUSES:
        p.append(f"status must be one of {', '.join(STATUSES)} (got {json.dumps(front.get('status'))})")
    auto = str(front.get("automation") or "")
    if auto not in AUTOMATIONS:
        p.append(f"automation must be one of {', '.join(AUTOMATIONS)} (got {json.dumps(front.get('automation'))})")
    if not isinstance(front.get("number_changing"), bool):
        p.append("number_changing must be a boolean")

    verified = front.get("verified")
    if verified is not None:
        events = verified if isinstance(verified, list) else [verified]
        if len(events) == 0 or not all(is_event(ev) for ev in events):
            p.append("verified must be { by, at } or a list of them, with ISO 8601 datetimes")
        if not non_empty_str(front.get("verified_commit")):
            p.append("verified needs verified_commit")
    elif front.get("verified_commit") is not None:
        p.append("verified_commit is only allowed with verified")

    if front.get("status") == "stable" and verified is None:
        p.append("status stable needs verified")
    if front.get("status") == "deprecated":
        sup = front.get("superseded_by")
        if not non_empty_str(sup):
            p.append("status deprecated needs superseded_by")
        elif not exists_fn(str(sup)):
            p.append(f"superseded_by {sup} does not exist")
    if front.get("automation") == "automated" and not non_empty_str(front.get("runner")):
        p.append("automation automated needs a runner")
    if front.get("stale_after") is not None and not is_iso(str(front["stale_after"])):
        p.append("stale_after must be an ISO 8601 datetime with offset")
    return p


SECTIONS = [
    ("Sub-features", lambda h: h == "Sub-features"),
    ("How to get to it (user POV)", lambda h: h == "How to get to it (user POV)"),
    ("Driving it with <harness>", lambda h: bool(re.match(r"^Driving it with \S", h))),
    ("Gotchas", lambda h: h == "Gotchas"),
]


def level_two_headings(body):
    headings = []
    fence = None
    for line in body.splitlines():
        f = re.match(r"^\s{0,3}(```+|~~~+)", line)
        if f:
            marker = f.group(1)[0]
            if not fence:
                fence = marker
            elif fence == marker:
                fence = None
            continue
        if fence:
            continue
        h = re.match(r"^##\s+(.+?)\s*$", line)
        if h:
            headings.append(h.group(1))
    return headings


def find_opt_outs(text):
    if not text:
        return []
    pattern = re.compile(
        r"^[ \t>*_-]*Opt-out:[ \t]*record[ \t]+[-–—][ \t]+(\S.*?)[ \t]*$",
        flags=re.IGNORECASE | re.MULTILINE,
    )
    return [m.group(1).strip() for m in pattern.finditer(text)]


def feature_name_key(value):
    value = re.sub(r"\[([^]]+)\]\([^)]+\)", r"\1", value)
    return " ".join(re.sub(r"[*`]", "", value).replace("&", " and ").casefold().strip(" .").split())


if sources_of_arg:
    ok_idx, idx_content = git_cmd(["show", f"{base_ref}:{index_file}"])
    wanted = feature_name_key(sources_of_arg)
    for row in parse_index(idx_content)[0] if ok_idx else []:
        if feature_name_key(row["feature"]) != wanted or not row["record"]:
            continue
        ok_rec, rec_content = git_cmd(["show", f"{base_ref}:{row['record']}"])
        front = split_record(rec_content)[0] if ok_rec else None
        if front:
            print("\n".join(source_paths(front)))
            sys.exit(0)
    print(f"error: no feature record for {sources_of_arg!r} on {base_ref}", file=sys.stderr)
    sys.exit(1)


findings = []


def add_finding(id_suffix, severity, description):
    findings.append(
        {
            "id": f"feature-records-{id_suffix}",
            "severity": severity,
            "description": description,
        }
    )


if not opted_in:
    add_finding("skipped", "info", "feature records check not opted into via .agents/pipeline.yaml; skipped")
else:
    records = {}
    r_dir = project_dir / records_dir
    if r_dir.exists() and r_dir.is_dir():
        for f in sorted(r_dir.glob("*.md")):
            if f.name != "README.md":
                rel = Path(os.path.normpath(f.relative_to(project_dir))).as_posix()
                try:
                    records[rel] = f.read_text(encoding="utf-8")
                except Exception:
                    records[rel] = ""

    index_text = ""
    idx_p = project_dir / index_file
    if idx_p.exists():
        try:
            index_text = idx_p.read_text(encoding="utf-8")
        except Exception:
            index_text = ""

    candidates = set()
    ok_ls, ls_out = git_cmd(["ls-files", "-z"])
    if ok_ls and ls_out:
        candidates.update(f for f in ls_out.split("\0") if f.strip())
    if head_ref_arg == "HEAD":
        ok_u, untracked_out = git_cmd(["ls-files", "--others", "--exclude-standard", "-z"])
        if ok_u and untracked_out:
            candidates.update(f for f in untracked_out.split("\0") if f.strip())
    if not candidates and project_dir.exists():
        for root_p, dirs, files in os.walk(project_dir):
            dirs[:] = [d for d in dirs if d not in (".git", "node_modules", ".next", "__pycache__", ".venv")]
            for fn in files:
                rel = Path(os.path.normpath(os.path.join(root_p, fn))).relative_to(project_dir).as_posix()
                candidates.add(rel)

    page_paths = []
    file_surface_paths = []
    for c in sorted(candidates):
        kind = match_surface(c)
        if kind == "next-page":
            page_paths.append(c)
        elif kind == "file":
            file_surface_paths.append(c)

    def exists_in_tree(rel_path):
        return (project_dir / rel_path).exists()

    main_rows = []
    main_excluded = []
    main_sources = {}
    ok_ls, ls_out = git_cmd(["ls-tree", "--name-only", "-z", base_ref, f"{records_dir}/"])
    if ok_ls and ls_out:
        for f in ls_out.split("\0"):
            if f.endswith(".md") and not f.endswith("/README.md") and f.strip():
                ok_show, rec_content = git_cmd(["show", f"{base_ref}:{f}"])
                if ok_show:
                    front, _, _ = split_record(rec_content)
                    if front:
                        s_paths = list(source_paths(front))
                        r_val = front.get("resource")
                        if non_empty_str(r_val) and not str(r_val).startswith("/"):
                            norm_r = Path(os.path.normpath(str(r_val))).as_posix()
                            if norm_r not in s_paths:
                                s_paths.append(norm_r)
                        main_sources[f] = s_paths
    ok_idx, idx_content = git_cmd(["show", f"{base_ref}:{index_file}"])
    if ok_idx:
        m_rows, m_ex = parse_index(idx_content)
        main_rows = m_rows
        main_excluded = m_ex

    ok_mb, mb_out = git_cmd(["merge-base", base_ref, head_ref_arg])
    mb = mb_out.strip() if ok_mb else base_ref
    diff_args = ["diff", "--name-only", "-z", mb]
    if head_ref_arg != "HEAD":
        diff_args.append(head_ref_arg)
    ok_diff, diff_out = git_cmd(diff_args)
    changed_files = [f for f in diff_out.split("\0") if f.strip()] if ok_diff else []
    if head_ref_arg == "HEAD":
        ok_untracked, untracked_out = git_cmd(["ls-files", "--others", "--exclude-standard", "-z"])
        if ok_untracked and untracked_out:
            changed_files.extend([f for f in untracked_out.split("\0") if f.strip()])
    changed_files = sorted(set(changed_files))

    watched = set(src for s_list in main_sources.values() for src in s_list)
    relevant = any(
        f.startswith(f"{records_dir}/") or match_surface(f) is not None or f in watched
        for f in changed_files
    )

    if changed_files and not relevant:
        add_finding("skipped", "info", "no feature code and no feature records changed; nothing to check")
    else:
        page_routes = {}
        for p in page_paths:
            r = derive_next_page_route(p)
            if r:
                page_routes[r] = p

        primary_by_record = {}
        pr_rows, pr_excluded = parse_index(index_text)

        for rp in sorted(records.keys()):
            front, body, error = split_record(records[rp])
            if not front:
                add_finding("frontmatter", "error", f"{rp}: {error}")
                continue
            r_resource = str(front.get("resource") or "")
            primary_by_record[rp] = r_resource if non_empty_str(front.get("resource")) else ""

            for problem in frontmatter_problems(front, exists_in_tree):
                add_finding("frontmatter", "error", f"{rp}: {problem}")

            for s in source_paths(front):
                if not exists_in_tree(s):
                    add_finding("source", "error", f"{rp}: sources path {s} does not exist")

            if non_empty_str(front.get("resource")):
                if r_resource.startswith("/"):
                    if page_routes and r_resource not in page_routes:
                        add_finding("resource", "error", f"{rp}: resource route {r_resource} has no page file")
                elif has_file:
                    if any(cs["regex"].match(r_resource) for cs in compiled_surfaces if cs["kind"] == "file") or "/" in r_resource or "." in r_resource:
                        if not exists_in_tree(r_resource):
                            add_finding("resource", "error", f"{rp}: resource file {r_resource} does not exist")

            record_rows = [r for r in pr_rows if r["record"] == rp]
            if not record_rows:
                add_finding("index-row", "error", f"{rp}: no index row in {index_file} points at this record")
            for row in record_rows:
                if non_empty_str(front.get("resource")):
                    if row["routes"]:
                        if row["routes"][0] != r_resource:
                            r_first = row["routes"][0]
                            add_finding(
                                "index-match",
                                "error",
                                f'{rp}: index row "{row["feature"]}" lists route {r_first} but the record\'s resource is {r_resource}',
                            )
                    elif not has_file or r_resource.startswith("/"):
                        add_finding(
                            "index-match",
                            "error",
                            f'{rp}: index row "{row["feature"]}" lists route (none) but the record\'s resource is {r_resource}',
                        )
                if row["automation"] != front.get("automation"):
                    add_finding(
                        "index-match",
                        "error",
                        f'{rp}: index row "{row["feature"]}" lists automation {row["automation"]} but the record says {front.get("automation")}',
                    )

            stale_val = front.get("stale_after")
            if is_iso(stale_val):
                try:
                    dt_stale = datetime.datetime.fromisoformat(str(stale_val).replace("Z", "+00:00"))
                    if dt_stale < now:
                        add_finding("stale", "warning", f"{rp}: stale_after {stale_val} is in the past; re-verify and bump it")
                except Exception:
                    pass

            headings = level_two_headings(body)
            headings_ok = len(headings) == len(SECTIONS) and all(
                sec[1](headings[idx]) for idx, sec in enumerate(SECTIONS)
            )
            if not headings_ok:
                expected_str = ", ".join(f'"{s[0]}"' for s in SECTIONS)
                found_str = ", ".join(f'"{h}"' for h in headings) if headings else "none"
                add_finding(
                    "headings",
                    "error",
                    f"{rp}: body must have exactly these level-two headings in order: {expected_str}; found {found_str}",
                )

        if page_routes:
            covered_routes = set(main_excluded + pr_excluded)
            main_authorized = set()
            for r in main_rows:
                for rt in r["routes"] + r["redirects"]:
                    main_authorized.add(rt)
            for r in pr_rows:
                if r["record"] not in records:
                    continue
                prim = primary_by_record.get(r["record"])
                if prim:
                    covered_routes.add(prim)
                for rt in r["routes"] + r["redirects"]:
                    if rt in main_authorized:
                        covered_routes.add(rt)

            for route, file_path in sorted(page_routes.items()):
                if route not in covered_routes:
                    add_finding("page", "error", f"page route {route} ({file_path}) has no index row in {index_file} and no record")

        if file_surface_paths:
            covered_files = set(main_excluded + pr_excluded)
            for rp, content in records.items():
                front, _, _ = split_record(content)
                if not front:
                    continue
                r_val = front.get("resource")
                if non_empty_str(r_val):
                    covered_files.add(Path(os.path.normpath(str(r_val))).as_posix())
                for s in source_paths(front):
                    covered_files.add(s)

            for f_path in sorted(file_surface_paths):
                if f_path not in covered_files:
                    add_finding(
                        "surface",
                        "error",
                        f"surface file {f_path} has no feature record covering it (not listed in sources and not named as resource)",
                    )

        for r in pr_rows:
            if r["record"] not in records:
                add_finding(
                    "index-record",
                    "error",
                    f'index row "{r["feature"]}" ({r["routes"][0] if r["routes"] else "no route"}) has no feature record at {r["record"] or "(none)"}',
                )

        if changed_files:
            c_set = set(changed_files)
            opt_outs = find_opt_outs(pr_body_arg) if pr_body_arg is not None else []
            for rp in sorted(main_sources.keys()):
                if rp in c_set:
                    continue
                hit = [s for s in main_sources[rp] if s in c_set]
                if not hit:
                    continue
                hit_str = ", ".join(hit)
                if pr_body_arg is None:
                    add_finding(
                        "changed-source-ci",
                        "info",
                        f'{rp} lists changed source file(s) {hit_str}; check 6 (record updated or "Opt-out: record - <reason>" in the PR description) runs in CI, where the description exists',
                    )
                elif opt_outs:
                    add_finding(
                        "opt-out",
                        "info",
                        f"Opt-out: record - {' / '.join(opt_outs)} (covers {rp}; changed sources: {hit_str})",
                    )
                else:
                    add_finding(
                        "changed-source",
                        "error",
                        f'{rp} lists changed source file(s) {hit_str} but the PR does not change the record; update it or add a PR line "Opt-out: record - <reason>"',
                    )

extracted_opt_outs = []
for f in findings:
    if f["id"] == "feature-records-opt-out":
        m = re.search(r"Opt-out:\s*record\s*[-–—]\s*([^(\n]+)", f["description"])
        if m:
            extracted_opt_outs.append(m.group(1).strip())

if evidence_file_arg and extracted_opt_outs:
    ev_path = Path(evidence_file_arg).resolve()
    ev_data = {}
    if ev_path.exists():
        try:
            ev_data = json.loads(ev_path.read_text(encoding="utf-8"))
        except Exception:
            ev_data = {}
    existing_opts = ev_data.get("opt_outs")
    if not isinstance(existing_opts, list):
        existing_opts = []
    for opt_reason in extracted_opt_outs:
        for sub_reason in opt_reason.split(" / "):
            sub_reason = sub_reason.strip()
            if not any(
                isinstance(e, dict) and e.get("step") == "record" and e.get("reason") == sub_reason
                for e in existing_opts
            ):
                existing_opts.append({"step": "record", "reason": sub_reason})
    ev_data["opt_outs"] = existing_opts
    try:
        ev_path.parent.mkdir(parents=True, exist_ok=True)
        ev_path.write_text(json.dumps(ev_data, indent=2) + "\n", encoding="utf-8")
    except Exception as e:
        print(f"warning: could not write to evidence file {ev_path}: {e}", file=sys.stderr)

sources_hit = sorted(list(set(f for f in changed_files if f in watched))) if 'watched' in locals() else []
opt_outs_found = find_opt_outs(pr_body_arg) if pr_body_arg is not None else []

verdict_dict = {
    "check": "feature-records",
    "mode": mode,
    "rulesRef": base_ref,
    "findings": findings,
    "sourcesHit": sources_hit,
    "optOuts": opt_outs_found,
}

if findings_file_arg:
    f_path = Path(findings_file_arg).resolve()
    try:
        f_path.parent.mkdir(parents=True, exist_ok=True)
        f_path.write_text(json.dumps(verdict_dict, indent=2) + "\n", encoding="utf-8")
    except Exception as e:
        print(f"warning: could not write to findings file {f_path}: {e}", file=sys.stderr)

if json_out_arg:
    print(json.dumps(verdict_dict, indent=2))
else:
    if not findings:
        print(f"feature-records [{mode}]: feature records consistent with pages, index and sources")
    for f in findings:
        sev = f["severity"]
        # In report-only mode an error cannot fail the build, so it is reported as a
        # warning; the JSON verdict keeps the machine-readable severity.
        if mode == "report-only" and sev == "error":
            sev = "warning"
        print(f"[{sev.upper()}] {f['id']}: {f['description']}")

has_errors = any(f["severity"] == "error" for f in findings)
if mode == "blocking" and has_errors:
    sys.exit(1)
sys.exit(0)
PY
