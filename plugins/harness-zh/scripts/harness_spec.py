"""harness_spec — story spec resolution + frontmatter helpers (BMad 6.11+ build pipeline).

BMad 6.11 merged create-story / dev-story into `bmad-build` / `bmad-build-auto`.
The build skills write the story spec as `spec-<slug>.md` (slug leads with the
story key) with the status in YAML frontmatter, instead of the legacy
`<KEY>.md` + `Status:` body line. Every harness script that used to hardcode
`f"{ARTIFACTS_DIR}{key}.md"` resolves the story file through this module, so
both layouts keep working side by side (legacy stories from plugin ≤ 0.1.39
stay readable).

Importable (sourceable lib, never executed directly). No third-party
dependency is required: PyYAML is used when present, otherwise a small
fallback parser handles the frontmatter shapes bmad-build-auto writes
(top-level scalars + the `deferred:` list of maps with block scalars).
"""

from __future__ import annotations

import os
import re
from pathlib import Path

try:  # optional — harness scripts must run without it
    import yaml as _yaml  # type: ignore
except Exception:  # pragma: no cover - environment dependent
    _yaml = None

try:
    import tomllib as _tomllib  # py3.11+
except Exception:  # pragma: no cover
    _tomllib = None


# bmad-build-auto spec-template.md frontmatter `status` vocabulary.
SPEC_STATUSES = ("draft", "ready-for-dev", "in-progress", "in-review", "done", "blocked")

# sprint-status.yaml story statuses.
# BMad template vocabulary for a story still on its way to `done`.
ACTIVE_STORY_STATUSES = ("backlog", "ready-for-dev", "in-progress", "review")
# Closed without delivery. Not in the BMad template, but real projects use
# `wont-do` for stories dropped mid-sprint and `cancelled` for stories voided at
# planning time (superseded / merged elsewhere, key kept for traceability —
# issue #13). Upstream bmad-retrospective still counts them as pending and
# forces verdict `rejected`; harness reports them as EPIC_WONT_DO=.
DROPPED_STORY_STATUSES = ("wont-do", "cancelled", "canceled")
TERMINAL_STORY_STATUSES = ("done",) + DROPPED_STORY_STATUSES


def epic_of_key(key: str) -> str | None:
    """`3-2-digest-delivery` → `3`. None when the key has no numeric epic segment."""
    m = re.match(r"^(\d+)-", key or "")
    return m.group(1) if m else None


# Story number may carry a letter suffix (`124-4b-…`); BMad's sprint planner
# accepts `\d+[a-z]?` there.
_EPIC_STORY_RE = re.compile(r"^(\d+)-(\d+[a-z]?)(?:-|$)")


def short_id(key: str) -> str | None:
    """`3-2-digest-delivery` → `3.2` (schema v1 `Story X.Y` short form)."""
    m = _EPIC_STORY_RE.match(key or "")
    return f"{m.group(1)}.{m.group(2)}" if m else None


def _epic_story_prefix(key: str) -> str | None:
    """`124-1-测试环境基线` → `124-1`. bmad-build-auto derives its own kebab slug
    (CJK keys come out transliterated: `spec-124-1-test-env-baseline-….md`),
    so the only stable part of the spec name is the epic/story number pair —
    the same "exact equality on the first two segments" rule bmad-build uses
    for its own story-key resolution (so `1-1` never collides with `1-10`)."""
    m = _EPIC_STORY_RE.match(key or "")
    return f"{m.group(1)}-{m.group(2)}" if m else None


def is_story_spec_name(fname: str, key: str) -> bool:
    """True when `fname` is a bmad-build(-auto) spec for story `key`:
    `spec-<key>[-n].md`, or `spec-<N>-<M>.md` / `spec-<N>-<M>-<any slug>.md`."""
    if _spec_variant_re(key).match(fname):
        return True
    pre = _epic_story_prefix(key)
    if not pre or not fname.startswith(f"spec-{pre}") or not fname.endswith(".md"):
        return False
    rest = fname[len(f"spec-{pre}"):]
    return rest == ".md" or rest.startswith("-")


def _spec_variant_re(key: str) -> re.Pattern:
    # spec-<key>.md, or spec-<key>-<n>.md (build-auto suffixes -2/-3 when a
    # non-draft spec with the same slug already exists).
    return re.compile(rf"^spec-{re.escape(key)}(?:-(\d+))?\.md$")


def resolve_story_md(key: str, artifacts_dir: str) -> str | None:
    """Return the basename of the story file for `key`, or None.

    Order:
      1. exact-slug specs `spec-<key>.md` / `spec-<key>-<n>.md` — the highest
         `-n` wins (build-auto only suffixes when the earlier one is non-draft,
         so the numbered file is always the newer run);
      2. any `spec-<N>-<M>[-slug].md` (build-auto picked its own slug); when
         several exist, prefer the ones not yet `done`, then the newest mtime;
      3. legacy `<key>.md` (plugin ≤ 0.1.39 create-story layout).
    """
    d = artifacts_dir.rstrip("/") or "."
    try:
        listing = sorted(os.listdir(d))
    except OSError:
        listing = []
    rx = _spec_variant_re(key)
    exact = []
    for fname in listing:
        m = rx.match(fname)
        if m:
            exact.append((int(m.group(1) or 0), fname))
    if exact:
        return max(exact)[1]
    loose = [f for f in listing if is_story_spec_name(f, key)]
    if len(loose) == 1:
        return loose[0]
    if loose:
        def rank(fname):
            path = os.path.join(d, fname)
            active = spec_status(path) not in ("done", None)
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                mtime = 0
            return (active, mtime, fname)
        return max(loose, key=rank)
    if os.path.isfile(os.path.join(d, f"{key}.md")):
        return f"{key}.md"
    return None


def story_md_path(key: str, artifacts_dir: str) -> str:
    """Repo-relative path of the story file. When nothing exists yet, returns the
    path the build pipeline will create (`spec-<key>.md`)."""
    name = resolve_story_md(key, artifacts_dir) or f"spec-{key}.md"
    return f"{artifacts_dir}{name}"


def is_story_owned_artifact(fname: str, key: str) -> bool:
    """True when an implementation-artifacts basename belongs to story `key`:
    `<key>.md` / `<key>.*` (legacy + harness sidecars), `spec-<key>[-n].md`,
    or the epic context cache `epic-<N>-context.md` bmad-build compiles for
    the story's epic."""
    if fname == f"{key}.md" or fname.startswith(f"{key}."):
        return True
    if is_story_spec_name(fname, key):
        return True
    epic = epic_of_key(key)
    if epic and fname == f"epic-{epic}-context.md":
        return True
    return False


# ---------------------------------------------------------------------------
# Frontmatter
# ---------------------------------------------------------------------------

def read_frontmatter_text(path: str) -> str | None:
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    if not text.startswith("---"):
        return None
    lines = text.splitlines()
    if lines[0].strip() != "---":
        return None
    for i in range(1, len(lines)):
        if lines[i].strip() == "---":
            return "\n".join(lines[1:i])
    return None


def parse_frontmatter(path: str) -> dict:
    """Parse YAML frontmatter → dict ({} when absent / unparsable)."""
    fm = read_frontmatter_text(path)
    if fm is None:
        return {}
    if _yaml is not None:
        try:
            data = _yaml.safe_load(fm)
            return data if isinstance(data, dict) else {}
        except Exception:
            pass  # fall through to the mini parser — better partial than nothing
    try:
        return _mini_yaml(fm)
    except Exception:
        return {}


def _strip_comment(v: str) -> str:
    # Drop ` # comment` outside quotes (good enough for frontmatter scalars).
    if v[:1] in ("'", '"'):
        q = v[0]
        end = v.find(q, 1)
        if end != -1:
            return v[: end + 1]
        return v
    m = re.search(r"\s+#", v)
    return v[: m.start()] if m else v


def _scalar(v: str):
    v = _strip_comment(v.strip()).strip()
    if v[:1] in ("'", '"') and v[-1:] == v[:1] and len(v) >= 2:
        return v[1:-1]
    low = v.lower()
    if low in ("true", "yes"):
        return True
    if low in ("false", "no"):
        return False
    if low in ("null", "~", ""):
        return None
    if v == "[]":
        return []
    if v == "{}":
        return {}
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    return v


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _block_scalar(lines, start, parent_indent, style):
    """Collect a `>-` / `|-` / `>` / `|` block scalar body."""
    body = []
    i = start
    while i < len(lines):
        ln = lines[i]
        if ln.strip() and _indent(ln) <= parent_indent:
            break
        body.append(ln)
        i += 1
    nonblank = [b for b in body if b.strip()]
    base = min((_indent(b) for b in nonblank), default=0)
    stripped = [b[base:] if b.strip() else "" for b in body]
    while stripped and not stripped[-1]:
        stripped.pop()
    if style.startswith(">"):
        text = " ".join(s for s in stripped if s)
    else:
        text = "\n".join(stripped)
    return text, i


def _parse_map(lines, start, indent):
    """Parse `key: value` lines at exactly `indent` columns."""
    out = {}
    i = start
    while i < len(lines):
        ln = lines[i]
        if not ln.strip() or ln.lstrip().startswith("#"):
            i += 1
            continue
        ind = _indent(ln)
        if ind < indent:
            break
        if ind > indent:
            i += 1
            continue
        m = re.match(r"^\s*([A-Za-z_][\w-]*):(?:\s+(.*))?$", ln)
        if not m:
            break
        k, v = m.group(1), (m.group(2) or "")
        v_clean = _strip_comment(v).strip()
        if v_clean in (">-", "|-", ">", "|", ">+", "|+"):
            text, i = _block_scalar(lines, i + 1, ind, v_clean)
            out[k] = text
            continue
        if v_clean == "":
            # nested list or map
            j = i + 1
            while j < len(lines) and not lines[j].strip():
                j += 1
            if j < len(lines) and lines[j].lstrip().startswith("- ") and _indent(lines[j]) >= ind:
                out[k], i = _parse_list(lines, j, _indent(lines[j]))
                continue
            if j < len(lines) and _indent(lines[j]) > ind:
                out[k], i = _parse_map(lines, j, _indent(lines[j]))
                continue
            out[k] = None
            i += 1
            continue
        out[k] = _scalar(v_clean)
        i += 1
    return out, i


def _parse_list(lines, start, indent):
    items = []
    i = start
    while i < len(lines):
        ln = lines[i]
        if not ln.strip():
            i += 1
            continue
        if _indent(ln) != indent or not ln.lstrip().startswith("- "):
            break
        rest = ln.lstrip()[2:]
        item_indent = indent + 2
        if re.match(r"^[A-Za-z_][\w-]*:(\s|$)", rest):
            # map item: re-feed the first key at item_indent
            synthetic = " " * item_indent + rest
            sub_lines = [synthetic]
            j = i + 1
            while j < len(lines):
                nxt = lines[j]
                if nxt.strip() and _indent(nxt) <= indent:
                    break
                sub_lines.append(nxt)
                j += 1
            m, _ = _parse_map(sub_lines, 0, item_indent)
            items.append(m)
            i = j
        else:
            items.append(_scalar(rest))
            i += 1
    return items, i


def _mini_yaml(text: str) -> dict:
    out, _ = _parse_map(text.splitlines(), 0, 0)
    return out


def spec_status(path: str) -> str | None:
    """Frontmatter `status` of a build spec (lowercased), or None."""
    v = parse_frontmatter(path).get("status")
    return str(v).strip().lower() if v is not None else None


def section_text(path: str, title: str) -> str | None:
    """Body of the first `## <title>` H2 section (case-insensitive substring
    match), up to the next H2. None when the section is absent."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    out = None
    for line in text.splitlines():
        m = re.match(r"^##\s+(.+?)\s*$", line)
        if m:
            if out is not None:
                break
            if title.lower() in m.group(1).lower():
                out = []
            continue
        if out is not None:
            out.append(line)
    return None if out is None else "\n".join(out)


def latest_review_pass(path: str) -> str | None:
    """Last `### ... Review pass` entry inside `## Review Triage Log`."""
    body = section_text(path, "Review Triage Log")
    if body is None:
        return None
    entries = re.split(r"(?m)^###\s+", body)
    entries = [e for e in entries if e.strip()]
    return entries[-1] if entries else None


def codex_layer_skipped(path: str) -> bool:
    """True when the latest review pass logged the codex cross-model layer as
    skipped (the project-side layer convention writes
    `- codex-cross-model: SKIPPED — <reason>`)."""
    entry = latest_review_pass(path)
    if not entry:
        return False
    for line in entry.splitlines():
        # Canonical: `codex-cross-model: SKIPPED — …` (also `：` and `**SKIPPED**`).
        if re.search(r"codex-cross-model\s*[:：]\s*\**\s*SKIPPED", line):
            return True
        # Free-form variants seen in real logs (`codex-cross-model 层 SKIPPED`,
        # `…层未运行（SKIPPED…`), but not negations (`…无 SKIPPED`, `no SKIPPED`).
        m = re.search(r"codex-cross-model(.{0,16}?)SKIPPED", line)
        if m and not re.search(r"无|没有|\bno\b|\bnot\b|未\s*skip", m.group(1), re.IGNORECASE):
            return True
    return False


def build_auto_result_files(artifacts_dir: str) -> list[str]:
    """`bmad-build-auto-result-*.md` files — what build-auto writes when it
    HALTs before a spec path is known (dirty tree, branch mismatch, unclear
    intent, missing continuity decision, uv failure…)."""
    d = artifacts_dir.rstrip("/") or "."
    try:
        return sorted(f"{artifacts_dir}{f}" for f in os.listdir(d)
                      if f.startswith("bmad-build-auto-result-") and f.endswith(".md"))
    except OSError:
        return []


# ---------------------------------------------------------------------------
# BMad customization probes
# ---------------------------------------------------------------------------

def build_auto_codex_layer_ids(repo_root: str | Path) -> list[str]:
    """Review-layer ids mentioning codex in `_bmad/custom/bmad-build-auto[.user].toml`.

    Non-empty means codex already runs INSIDE bmad-build-auto's review step,
    so the harness must not run its own external codex stage on top (that
    would bill codex twice per story)."""
    root = Path(repo_root)
    ids: list[str] = []
    for name in ("bmad-build-auto.toml", "bmad-build-auto.user.toml"):
        p = root / "_bmad" / "custom" / name
        if not p.is_file():
            continue
        raw = p.read_text(encoding="utf-8", errors="replace")
        layers = None
        if _tomllib is not None:
            try:
                data = _tomllib.loads(raw)
                layers = (data.get("workflow") or {}).get("review_layers") or []
            except Exception:
                layers = None
        if layers is not None:
            for layer in layers:
                if not isinstance(layer, dict):
                    continue
                lid = str(layer.get("id", ""))
                instr = str(layer.get("instruction", ""))
                if "codex" in lid.lower() and instr.strip():
                    ids.append(lid)
        else:
            for m in re.finditer(r'(?m)^\s*id\s*=\s*"([^"]*codex[^"]*)"', raw, re.IGNORECASE):
                ids.append(m.group(1))
    return ids


# ---------------------------------------------------------------------------
# deferred ledger bridge: spec frontmatter `deferred:` → deferred-work.md FU
# ---------------------------------------------------------------------------
#
# bmad-build-auto never writes deferred-work.md — its step-04 records every
# `defer` triage entry in the spec frontmatter `deferred:` list
# ({summary, evidence, location?, severity?}). Left there, those items are
# invisible to the harness ledger tooling (grep_pending_deferred_for_story.sh
# C11 injection, grep_deferred_buckets.sh, lint). build-sync imports them as
# schema v1 FU bullets. Ids are positional (`FU-<X.Y>.B<n>`, n = 1-based index
# in the append-only list), so re-running is idempotent and a later follow-up
# pass that appends more items only imports the new tail.

def _one_line(text, limit):
    t = re.sub(r"\s+", " ", str(text or "")).strip()
    return t if len(t) <= limit else t[: limit - 1].rstrip() + "…"


def build_deferred_fu_entries(key: str, spec_path: str) -> list[tuple[str, str]]:
    """Return [(fu_id, markdown_bullet)] for every spec `deferred:` item."""
    items = parse_frontmatter(spec_path).get("deferred") or []
    if not isinstance(items, list):
        return []
    sid = short_id(key) or key
    epic = epic_of_key(key)
    target = f"Epic {epic}" if epic else "N/A"
    spec_name = os.path.basename(spec_path)
    out = []
    for n, item in enumerate(items, start=1):
        if not isinstance(item, dict):
            item = {"summary": item}
        summary = _one_line(item.get("summary"), 120) or "(no summary)"
        # `evidence` explains why the finding is real, not what to do — it has
        # no schema v1 field of its own (修复方向 means "fix direction"), so it
        # stays in the spec and the bullet points there via 关联.
        refs = [spec_name]
        if item.get("location"):
            refs.append(_one_line(item.get("location"), 80))
        if item.get("severity"):
            refs.append("severity:" + _one_line(item.get("severity"), 30).replace(" ", ""))
        fu_id = f"FU-{sid}.B{n}"
        lines = [f"- **{fu_id}** `[status:pending]` `[bucket:other]` `[target:{target}]` `[source:build-auto-of-{sid}]` — {summary}"]
        lines.append(f"  - **关联**：{' / '.join(refs)}")
        out.append((fu_id, "\n".join(lines)))
    return out


def import_spec_deferred(key: str, spec_path: str, deferred_work_path: str, today: str,
                         dry_run: bool = False) -> list[str]:
    """Append not-yet-imported spec deferred items to deferred-work.md.

    Returns the FU ids appended (empty when nothing new). Never rewrites
    existing content. Raises RuntimeError when the ledger file is missing
    (the harness-owned ledger is created by /harness-zh:init)."""
    entries = build_deferred_fu_entries(key, spec_path)
    if not entries:
        return []
    if not os.path.isfile(deferred_work_path):
        raise RuntimeError(f"deferred ledger not found: {deferred_work_path} (run /harness-zh:init)")
    with open(deferred_work_path, "r", encoding="utf-8") as f:
        ledger = f.read()
    new = [(fid, md) for fid, md in entries if f"**{fid}**" not in ledger]
    if not new:
        return []
    block = [f"## Deferred from: build-auto of {key} ({today})", ""]
    for _fid, md in new:
        block.append(md)
        block.append("")
    sep = "" if ledger.endswith("\n\n") else ("\n" if ledger.endswith("\n") else "\n\n")
    addition = sep + "---\n\n" + "\n".join(block)
    if not dry_run:
        with open(deferred_work_path, "a", encoding="utf-8") as f:
            f.write(addition)
    return [fid for fid, _ in new]


# ---------------------------------------------------------------------------
# retro_action_items shape migration (v0.2.0)
# ---------------------------------------------------------------------------
#
# ≤ 0.1.39 wrote items as a scalar with over-indented children:
#
#     retro_action_items:
#       epic-9-retro:
#         I1: pending      # title
#           category: dev          ← not valid YAML once a child exists
#
# Harness's own awk/regex readers tolerated it, but BMad 6.12's native
# scripts (bmad-retrospective sprint_status.py, bmad-sprint-planning
# sprint_plan.py) load the whole sprint-status.yaml with a real YAML parser
# and fail on it. The valid nested form keeps every child where it was and
# moves the status into its own key:
#
#         I1:
#           status: pending      # title
#           category: dev
#
# Readers accept both forms; writers emit only the nested one.

_RAI_EPIC_BLOCK_RE = re.compile(r"^(\s+)[a-z0-9-]+-retro:\s*(#.*)?$")
_RAI_SCALAR_ITEM_RE = re.compile(r"^(\s+)([A-Z][A-Za-z0-9-]*):[ \t]+(['\"]?[A-Za-z-]+['\"]?)([ \t]*#.*)?$")


def migrate_retro_items_text(text: str) -> tuple[str, int]:
    """Rewrite scalar-form retro items to nested mappings. Returns
    (new_text, converted_count); text is returned unchanged when count is 0."""
    lines = text.splitlines(keepends=True)
    out = []
    in_rai = False
    epic_indent = None
    converted = 0
    for line in lines:
        body = line.rstrip("\r\n")
        eol = line[len(body):]
        if not in_rai:
            out.append(line)
            if body == "retro_action_items:" or body.startswith("retro_action_items: ") \
                    or body.startswith("retro_action_items:#"):
                in_rai = True
            continue
        if body and not body[0].isspace() and not body.lstrip().startswith("#"):
            in_rai = False
            epic_indent = None
            out.append(line)
            continue
        m = _RAI_EPIC_BLOCK_RE.match(body)
        if m:
            epic_indent = len(m.group(1))
            out.append(line)
            continue
        m = _RAI_SCALAR_ITEM_RE.match(body)
        if m and epic_indent is not None and len(m.group(1)) > epic_indent:
            ind, code, status, comment = m.group(1), m.group(2), m.group(3), m.group(4) or ""
            nl = eol or "\n"
            out.append(f"{ind}{code}:{nl}")
            out.append(f"{ind}  status: {status}{comment}{eol}")
            converted += 1
            continue
        out.append(line)
    return ("".join(out), converted) if converted else (text, 0)
