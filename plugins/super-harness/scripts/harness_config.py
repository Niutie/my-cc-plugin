#!/usr/bin/env python3
"""harness_config — read harness-project-config.yaml without yaml lib dep.

Hand-rolled minimal YAML parser (与 sprint-status.py 同手法)
supporting the subset our config uses:
- top-level scalar:           `artifacts_root: '_bmad-output/...'`
- extra: map with nested:     `extra:\n  frontend_dir: 'console-web'`
- list of dict (path_classifiers):
      extra:
        path_classifiers:
          - label: 'backend Go source'
            regex: '^console-api/(?!.*_test\\.go$)'
- multi-line `|` block (verification_commands):
      extra:
        verification_commands: |
          go vet ...
          pnpm --filter ...

Fallback policy: missing field / missing file / parse error → return a
project-neutral default + stderr WARN. Never raise. An explicitly empty value
(`key: []`, `key: ''`) is legal and does NOT warn; only an absent key does.
`python3 harness_config.py check` validates structure (exit 3 + ERROR lines).

Usage:
    from harness_config import (
        get_artifacts_root,
        get_sprint_status_path,
        get_deferred_work_path,
        get_path_classifiers,
        get_verification_commands,
    )
"""
from __future__ import annotations

import re
import sys
# Never drop __pycache__/ next to the deployed scripts: an untracked dir there
# makes the worktree dirty, and bmad-build-auto refuses to start on a dirty tree.
sys.dont_write_bytecode = True
from pathlib import Path

# Default config path: relative to this script's location (deployed under
# .claude/harness/scripts/). Override priority (high → low):
#   1. _OVERRIDE_CONFIG_PATH (set by --config-path CLI flag)
#   2. HARNESS_CONFIG_PATH env var (set by callers that need to override
#      against a tmp dir, e.g. test fixtures or AEGIS_ENV_PROBE_REPO)
#   3. <this_file>/../harness-project-config.yaml (default, deployed layout)
import os as _os

_DEFAULT_CONFIG_PATH = Path(__file__).resolve().parents[1] / "harness-project-config.yaml"
_OVERRIDE_CONFIG_PATH: Path | None = None


def _resolve_config_path() -> Path:
    if _OVERRIDE_CONFIG_PATH is not None:
        return _OVERRIDE_CONFIG_PATH
    env_override = _os.environ.get("HARNESS_CONFIG_PATH")
    if env_override:
        return Path(env_override)
    return _DEFAULT_CONFIG_PATH


# Back-compat: existing callers reference CONFIG_PATH directly. Keep it as a
# property-like dynamic lookup by re-resolving on attribute access. This works
# because all internal readers go through _resolve_config_path(); we expose
# CONFIG_PATH only for legacy module-level inspection.
class _ConfigPathProxy:
    def __fspath__(self) -> str:
        return str(_resolve_config_path())

    def __str__(self) -> str:
        return str(_resolve_config_path())

    def exists(self) -> bool:
        return _resolve_config_path().exists()


CONFIG_PATH = _ConfigPathProxy()

# Hardcoded defaults — used when harness-project-config.yaml does not set the
# corresponding field. They are deliberately project-neutral: an unconfigured
# project gets "no classification" and "use your own test/lint commands", never
# another project's directory layout.
_DEFAULT_ARTIFACTS_ROOT = "_bmad-output/implementation-artifacts"
# Empty = every changed path lands in the catch-all 'other' bucket.
_DEFAULT_PATH_CLASSIFIERS: list[tuple[str, str]] = []
# One line on purpose: consumers render it inline / as a single bullet.
_DEFAULT_VERIFICATION_COMMANDS = (
    "（未配置 extra.verification_commands）按项目自己的文档"
    "（README / CONTRIBUTING / Makefile / justfile / package.json scripts 等）"
    "找到并运行该项目的 test、lint、build 命令"
)
_DEFAULT_PROJECT_CONTEXT = (
    "项目语境未配置：此 harness clone 后请在 .claude/harness/harness-project-config.yaml\n"
    "的 extra.project_context: 多行块字段写入项目特定决策语境（产品定位 / 目标客户 /\n"
    "交付形态 / 关键决策原则）。subagent 在按 answer-policy.md 自决时缺少这段语境会\n"
    "降级为通用决策原则。"
)
# fullstack_review_steps fallback：空 list（对应 dev-story Q6 的"项目无新审计字段
# 全栈追溯链"语义；新项目按本表 yaml 字段填即可）。
_DEFAULT_FULLSTACK_REVIEW_STEPS: list[dict[str, str]] = []

# Explicit-empty spellings. `key: []`, `key: ''`, `key: ""` and a bare `key:`
# (YAML null) all mean "set, deliberately empty": legal, no WARN. Only a key
# that does not appear at all counts as "not set" and WARNs.
_EMPTY_SCALARS = ("", "''", '""', "~", "null")
_BLOCK_MARKERS = ("|", "|-", "|+", ">", ">-", ">+")


def _warn(msg: str) -> None:
    print(f"WARN [harness_config]: {msg}", file=sys.stderr)


def _strip_yaml_scalar(val: str) -> str:
    val = val.strip()
    # 去 inline 注释 (# ...) — 三种情况：
    #   (1) 非引号 scalar：foo # comment → foo
    #   (2) 引号 scalar：'foo' # comment → 'foo'  (匹配 closing 引号后可有空格 + #)
    #   (3) 引号内 #：'foo # bar' → 保留（跳过本步）
    if val and val[0] in ("'", '"'):
        q = val[0]
        # find matching closing quote (first one on the line — yaml flow scalar
        # 不支持 escape，所以第一个 q 就是 closing)
        end = val.find(q, 1)
        if end > 0 and end + 1 < len(val):
            tail = val[end + 1:].lstrip()
            if tail.startswith("#"):
                val = val[:end + 1]
    elif val:
        idx = val.find("#")
        if idx >= 0:
            val = val[:idx].rstrip()
    # 去外层引号
    if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
        val = val[1:-1]
    return val


def _strip_inline_comment(val: str) -> str:
    """Drop a trailing `# comment` from an unquoted value (`[]  # e.g. ...`).
    Quoted values are returned verbatim (minus surrounding whitespace)."""
    val = val.strip()
    if val and val[0] in ("'", '"'):
        end = val.find(val[0], 1)
        if end > 0 and val[end + 1:].lstrip().startswith("#"):
            return val[:end + 1]
        return val
    idx = val.find("#")
    return val[:idx].rstrip() if idx >= 0 else val


def _read_lines() -> list[str] | None:
    cfg = _resolve_config_path()
    if not cfg.exists():
        return None
    try:
        return cfg.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None


def _read_top_level_scalar(key: str) -> str | None:
    lines = _read_lines()
    if lines is None:
        return None
    pat = re.compile(rf"^{re.escape(key)}:\s*(.*)$")
    for line in lines:
        m = pat.match(line)
        if m:
            return _strip_yaml_scalar(m.group(1))
    return None


def _find_extra_key(lines: list[str], key: str) -> tuple[int, int, str] | None:
    """Locate `extra:\\n  <key>: <raw>` → (line index, key indent, raw value).

    Only direct children of `extra:` match (indent == indent of the first child
    line), so a nested `label:` / `regex:` or a line inside a `|` block is never
    mistaken for an extra key."""
    in_extra = False
    child_indent: int | None = None
    pat = re.compile(rf"^(\s+){re.escape(key)}:(?:\s+(.*))?$")
    for i, line in enumerate(lines):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not line[0].isspace():
            in_extra = line.startswith("extra:")
            child_indent = None
            continue
        if not in_extra:
            continue
        leading = len(line) - len(line.lstrip())
        if child_indent is None:
            child_indent = leading
        if leading != child_indent:
            continue
        m = pat.match(line)
        if m:
            return i, leading, (m.group(2) or "")
    return None


def _block_body(lines: list[str], idx: int, key_indent: int) -> list[str]:
    """Lines after `idx` that belong to the key (deeper indent, or blank)."""
    body: list[str] = []
    for line in lines[idx + 1:]:
        if line.strip() == "":
            body.append("")
            continue
        if len(line) - len(line.lstrip()) <= key_indent:
            break
        body.append(line)
    while body and body[-1] == "":
        body.pop()
    return body


def _read_extra_scalar(key: str) -> str | None:
    """读 `extra:\\n  <key>: <value>` 形式的二级 scalar（list / 块标量起始返回 None）。"""
    lines = _read_lines()
    if lines is None:
        return None
    hit = _find_extra_key(lines, key)
    if hit is None:
        return None
    head = _strip_inline_comment(hit[2])
    # 排除嵌套结构起始（list / multi-line block 起始 — 留给专用 reader）
    if head == "" or head in _BLOCK_MARKERS:
        return None
    return _strip_yaml_scalar(hit[2])


def _parse_extra_text(key: str) -> tuple[str | None, str | None]:
    """Text field: `|` block, or a one-line scalar. Returns (value, error);
    value None = key absent (or unparseable), "" = explicitly empty."""
    lines = _read_lines()
    if lines is None:
        return None, None
    hit = _find_extra_key(lines, key)
    if hit is None:
        return None, None
    idx, indent, raw = hit
    head = _strip_inline_comment(raw)
    if head in _BLOCK_MARKERS:
        body = _block_body(lines, idx, indent)
        nonblank = [ln for ln in body if ln.strip()]
        if not nonblank:
            return "", None
        cut = min(len(ln) - len(ln.lstrip()) for ln in nonblank)
        text_lines = [ln[cut:] if ln.strip() else "" for ln in body]
        if head.startswith(">"):
            return " ".join(ln.strip() for ln in text_lines if ln.strip()), None
        return "\n".join(text_lines), None
    if head in _EMPTY_SCALARS:
        if head == "" and _block_body(lines, idx, indent):
            return None, (f"extra.{key}: 值写在下一行但缺少 `|` 块标记"
                          f"（应写成 `{key}: |`）")
        return "", None
    return _strip_yaml_scalar(raw), None


def _read_extra_multiline_block(key: str) -> str | None:
    """读 `extra:\\n  <key>: |\\n    line1\\n    line2`（也接受单行 scalar）。
    None = key 缺失；"" = 显式空值。"""
    return _parse_extra_text(key)[0]


def _parse_extra_list_of_dict(
    key: str, sub_keys: tuple[str, ...]
) -> tuple[list[dict[str, str]] | None, str | None]:
    """List-of-dict field. Returns (value, error): value None = key absent (or
    unparseable, see error); [] = explicitly empty (`key: []`, `key: ''`, or a
    bare `key:` with no items).

    Items use the block form only:
        <key>:
          - sk1: v1
            sk2: v2
    """
    lines = _read_lines()
    if lines is None:
        return None, None
    hit = _find_extra_key(lines, key)
    if hit is None:
        return None, None
    idx, indent, raw = hit
    head = _strip_inline_comment(raw)
    if re.fullmatch(r"\[\s*\]", head) or (head != "" and head in _EMPTY_SCALARS):
        return [], None
    if head != "":
        return None, (f"extra.{key}: 无法解析的值 {head!r}（写成 `{key}: []`，"
                      f"或在下一行起用 `- {sub_keys[0]}: ...` 块列表）")
    item_start_pat = re.compile(r"^(\s*)-\s+([^:]+):\s*(.*)$")
    item_cont_pat = re.compile(r"^(\s*)([^:\-#][^:]*?):\s*(.*)$")
    out: list[dict[str, str]] = []
    cur: dict[str, str] | None = None
    for line in _block_body(lines, idx, indent):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        m_item = item_start_pat.match(line)
        if m_item:
            if cur is not None:
                out.append(cur)
            cur = {}
            sk = m_item.group(2).strip()
            if sk in sub_keys:
                cur[sk] = _strip_yaml_scalar(m_item.group(3))
            continue
        m_cont = item_cont_pat.match(line)
        if m_cont and cur is not None:
            sk = m_cont.group(2).strip()
            if sk in sub_keys:
                cur[sk] = _strip_yaml_scalar(m_cont.group(3))
            continue
        return None, f"extra.{key}: 无法解析的行 {s!r}"
    if cur is not None:
        out.append(cur)
    return out, None


def _read_extra_list_of_dict(key: str, sub_keys: tuple[str, ...]) -> list[dict[str, str]] | None:
    """读 `extra:\\n  <key>:\\n    - sk1: v1\\n      sk2: v2`。None = 缺失或无法解析；[] = 显式空。"""
    return _parse_extra_list_of_dict(key, sub_keys)[0]


# ---- public API ----

def get_artifacts_root() -> Path:
    """Return artifacts_root (relative to repo root, as Path).

    Repo root is computed as 3 levels up from this file (`.claude/harness/scripts/`).

    Review 2026-06-10 finding #80: the returned Path is guaranteed to satisfy
    `.relative_to(repo_root)` — three consumers (harness-commit.py /
    harness-state.py / harness-prompt-suffix.py) call that at module import
    time, and an out-of-repo value used to crash them with a bare ValueError
    traceback (no STATUS= output) before any stage could run. Normalization
    policy (auto-degrade, never raise — per this module's fallback contract):
      - absolute path that resolves *inside* repo root → normalized to the
        repo-relative form + WARN
      - absolute path outside repo root, or relative path escaping via `..`
        → fall back to the hardcoded default + WARN
    """
    val = _read_top_level_scalar("artifacts_root")
    if val is None or val == "":
        # explicit `artifacts_root: ''` (template default) is legal → silent
        if val is None:
            _warn(f"artifacts_root not set, using default '{_DEFAULT_ARTIFACTS_ROOT}'")
        val = _DEFAULT_ARTIFACTS_ROOT
    repo_root = Path(__file__).resolve().parents[3]
    candidate = repo_root / val  # pathlib: absolute val replaces the left side
    try:
        rel = candidate.relative_to(repo_root)
    except ValueError:
        rel = None
    if rel is None or ".." in rel.parts:
        # Absolute value, or relative value escaping the repo via `..`:
        # try resolve()-based normalization (covers '/abs/path/to/repo/sub'
        # style configs that point back inside the repo); resolve() does not
        # require the path to exist (strict=False default).
        norm = None
        try:
            norm = candidate.resolve().relative_to(repo_root)
        except (ValueError, OSError):
            norm = None
        if norm is not None and ".." not in norm.parts:
            _warn(f"artifacts_root '{val}' normalized to repo-relative '{norm}'")
            rel = norm
        else:
            _warn(
                f"artifacts_root '{val}' is not under repo root '{repo_root}'; "
                f"falling back to default '{_DEFAULT_ARTIFACTS_ROOT}'"
            )
            rel = Path(_DEFAULT_ARTIFACTS_ROOT)
    return repo_root / rel


def get_sprint_status_path() -> Path:
    return get_artifacts_root() / "sprint-status.yaml"


def get_deferred_work_path() -> Path:
    return get_artifacts_root() / "deferred-work.md"


def get_path_classifiers() -> list[tuple[str, "re.Pattern[str]"]]:
    """Return [(label, compiled_regex), ...]. Unset → empty list (every path
    goes to 'other'); `path_classifiers: []` is legal and silent."""
    raw, err = _parse_extra_list_of_dict("path_classifiers", ("label", "regex"))
    if err:
        _warn(err + "；按未配置处理（全部归 'other'）")
    elif raw is None:
        _warn("path_classifiers not set, every path goes to 'other'")
    if raw is None:
        return [(label, re.compile(rgx)) for label, rgx in _DEFAULT_PATH_CLASSIFIERS]
    out: list[tuple[str, re.Pattern[str]]] = []
    for d in raw:
        label = d.get("label", "")
        rgx = d.get("regex", "")
        if not label or not rgx:
            _warn(f"path_classifiers entry skipped (missing label/regex): {d}")
            continue
        try:
            out.append((label, re.compile(rgx)))
        except re.error as e:
            _warn(f"path_classifiers regex compile error for '{label}': {e}")
    return out


def get_verification_commands() -> str:
    """Newline-separated commands. Unset or explicitly empty → a neutral one-line
    notice telling the agent to use the project's own commands (never empty, so
    every consumer has something to show)."""
    val, err = _parse_extra_text("verification_commands")
    if err:
        _warn(err)
    elif val is None:
        _warn("verification_commands not set, using neutral notice")
    if val is None or val.strip() == "":
        return _DEFAULT_VERIFICATION_COMMANDS
    return val


def get_project_context() -> str:
    """Return extra.project_context multiline block. Used by harness-prompt-suffix.py
    to inline project-specific decision context into ANSWER_POLICY_BLOCK."""
    val, err = _parse_extra_text("project_context")
    if err:
        _warn(err)
    elif val is None:
        _warn("extra.project_context not set, using fallback notice")
    if val is None or val.strip() == "":
        return _DEFAULT_PROJECT_CONTEXT
    return val


def get_fullstack_review_steps() -> list[dict[str, str]]:
    """Return extra.fullstack_review_steps as list of {label, file_path} dicts.
    Used by harness-prompt-suffix.py `implement` (and legacy stage 2) to render Q6 (a)-(z)
    bullets dynamically from project config rather than hardcoded paths."""
    raw, err = _parse_extra_list_of_dict("fullstack_review_steps", ("label", "file_path"))
    if err:
        _warn(err + "；按空 list 处理（Q6 disabled）")
    elif raw is None:
        _warn("extra.fullstack_review_steps not set, using empty list (Q6 disabled)")
    if raw is None:
        return list(_DEFAULT_FULLSTACK_REVIEW_STEPS)
    out: list[dict[str, str]] = []
    for d in raw:
        label = d.get("label", "").strip()
        file_path = d.get("file_path", "").strip()
        if not label or not file_path:
            _warn(f"fullstack_review_steps entry skipped (missing label/file_path): {d}")
            continue
        out.append({"label": label, "file_path": file_path})
    return out


def get_parked_statuses() -> tuple[str, ...]:
    """Top-level `parked_statuses:` — sprint-status story statuses that mean
    "kept on the board, not to be developed for now" (placeholders waiting for
    outside input, stories waiting for a spec). Such stories are never dispatched,
    do not hold back the epic barrier or the epic retro, and are reported as
    EPIC_PARKED= next to EPIC_WONT_DO= (issue #15). Inline `[a, b]` or a block
    list; absent / empty → ()."""
    lines = _read_lines()
    if lines is None:
        return ()
    out: list[str] = []
    in_list = False
    for line in lines:
        if not in_list:
            m = re.match(r"^parked_statuses:\s*(.*)$", line)
            if not m:
                continue
            raw = _strip_yaml_scalar(m.group(1))
            if raw.startswith("["):
                inner = raw[1:raw.rfind("]")] if "]" in raw else raw[1:]
                out = [x.strip().strip("'\"") for x in inner.split(",")]
                break
            if raw:
                out = [raw.strip("'\"")]
                break
            in_list = True
            continue
        st = line.strip()
        if not st or st.startswith("#"):
            continue
        if not line[0].isspace() or not st.startswith("- "):
            break
        out.append(_strip_yaml_scalar(st[2:]).strip("'\""))
    reserved = {"backlog", "ready-for-dev", "in-progress", "review", "done",
                "wont-do", "cancelled", "canceled"}
    return tuple(x for x in out if x and x not in reserved)


def check_config() -> list[str]:
    """Structural validation behind `harness_config.py check` (init §4.5 gate).

    Returns error strings; empty list = usable config. Explicit empty values
    (`[]`, `''`) are fine and absent keys are not errors (their getters WARN
    and fall back). Errors are what a getter would otherwise drop silently:
    unreadable file, unparseable list or block, list items missing a sub-key,
    regexes that do not compile."""
    if _read_lines() is None:
        return [f"config file missing or unreadable: {_resolve_config_path()}"]
    errors: list[str] = []
    for key, sub_keys in (("path_classifiers", ("label", "regex")),
                          ("fullstack_review_steps", ("label", "file_path"))):
        raw, err = _parse_extra_list_of_dict(key, sub_keys)
        if err:
            errors.append(err)
            continue
        for n, d in enumerate(raw or [], 1):
            missing = [k for k in sub_keys if not d.get(k, "").strip()]
            if missing:
                errors.append(f"extra.{key} 第 {n} 项缺 {'/'.join(missing)}: {d}")
            elif key == "path_classifiers":
                try:
                    re.compile(d["regex"])
                except re.error as e:
                    errors.append(f"extra.path_classifiers 第 {n} 项 regex 编译失败（{d['label']}）: {e}")
    for key in ("verification_commands", "project_context"):
        _, err = _parse_extra_text(key)
        if err:
            errors.append(err)
    return errors


def _cli_get(key: str, default: str | None = None) -> tuple[str, str]:
    """CLI --get <key> implementation. Returns (value, source) where source is
    one of 'top', 'extra', 'default', 'missing'. Looks up:
      1. top-level scalar (artifacts_root etc.)
      2. extra.<key> scalar (frontend_dir etc.)
    If both miss, falls back to default arg (if provided) or empty string.
    """
    val = _read_top_level_scalar(key)
    if val is not None and val != "":
        return val, "top"
    val = _read_extra_scalar(key)
    if val is not None and val != "":
        return val, "extra"
    if default is not None:
        return default, "default"
    return "", "missing"


def _cli_main(argv: list[str]) -> int:
    import argparse
    parser = argparse.ArgumentParser(
        prog="harness_config.py",
        description=(
            "Read fields from harness-project-config.yaml. Used by Python "
            "callers via import; bash callers via `python3 harness_config.py "
            "--get <field>` to avoid duplicated yaml parsers."
        ),
    )
    parser.add_argument(
        "--config-path",
        help="override harness-project-config.yaml location (test/AEGIS_ENV_PROBE_REPO)",
    )
    sub = parser.add_subparsers(dest="cmd")

    p_get = sub.add_parser("get", help="print one field value to stdout")
    p_get.add_argument("key", help="field name (looked up at top-level then extra.)")
    p_get.add_argument("--default", default=None, help="fallback if key missing")
    p_get.add_argument(
        "--quiet",
        action="store_true",
        help="suppress 'WARN: missing' on stderr (default off — silent stdout but warn on stderr)",
    )

    sub.add_parser("smoke", help="smoke-print all known fields (legacy __main__ behavior)")
    sub.add_parser(
        "check",
        help=("validate structure (init §4.5 gate): exit 0 + 'CONFIG_OK' on stdout, or "
              "exit 3 + one 'ERROR [harness_config]:' line per problem on stderr"),
    )

    # bash convenience: `--get` as top-level flag (no subcommand). We handle
    # this by detecting `--get` before parse and rewriting to the subcommand
    # form. Keeps backward-compat with simple shell wrappers.
    if "--get" in argv and "get" not in argv:
        # Rewrite "[--config-path X] --get KEY [--default D]" → "[opts] get KEY [--default D]"
        new_argv = []
        skip_next = False
        for i, a in enumerate(argv):
            if skip_next:
                skip_next = False
                continue
            if a == "--get":
                # the next token is the key
                if i + 1 >= len(argv):
                    print("ERROR: --get requires a key argument", file=sys.stderr)
                    return 2
                new_argv.append("get")
                new_argv.append(argv[i + 1])
                skip_next = True
            else:
                new_argv.append(a)
        argv = new_argv

    args = parser.parse_args(argv)

    if args.config_path:
        global _OVERRIDE_CONFIG_PATH
        _OVERRIDE_CONFIG_PATH = Path(args.config_path)

    if args.cmd == "get":
        value, source = _cli_get(args.key, args.default)
        if source == "missing" and not args.quiet:
            print(
                f"WARN [harness_config]: '{args.key}' not set in "
                f"{_resolve_config_path()} (no --default provided)",
                file=sys.stderr,
            )
        print(value)
        return 0

    if args.cmd == "check":
        errors = check_config()
        for e in errors:
            print(f"ERROR [harness_config]: {e}", file=sys.stderr)
        if errors:
            return 3
        print("CONFIG_OK")
        return 0

    if args.cmd == "smoke" or args.cmd is None:
        print(f"config_path: {_resolve_config_path()}")
        print(f"artifacts_root: {get_artifacts_root()}")
        print(f"sprint_status_path: {get_sprint_status_path()}")
        print(f"deferred_work_path: {get_deferred_work_path()}")
        print(f"path_classifiers: {len(get_path_classifiers())} entries")
        for label, rgx in get_path_classifiers()[:3]:
            print(f"  - {label}: {rgx.pattern}")
        print(f"verification_commands:")
        for line in get_verification_commands().splitlines():
            print(f"  {line}")
        print(f"project_context:")
        for line in get_project_context().splitlines():
            print(f"  {line}")
        print(f"fullstack_review_steps: {len(get_fullstack_review_steps())} entries")
        for step in get_fullstack_review_steps()[:3]:
            print(f"  - ({step['label']}) {step['file_path']}")
        return 0

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(_cli_main(sys.argv[1:]))
