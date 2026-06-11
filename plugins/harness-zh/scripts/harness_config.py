#!/usr/bin/env python3
"""harness_config — read harness-project-config.yaml without yaml lib dep.

Hand-rolled minimal YAML parser (与 sprint-status.py / eval_test_stage_triggers.sh 同手法)
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

Fallback policy: missing field / missing file / parse error → return hardcoded
default + stderr WARN. Never raise. Aligned with eval_test_stage_triggers.sh
fail_open_default precedent.

Usage:
    from harness_config import (
        get_artifacts_root,
        get_sprint_status_path,
        get_deferred_work_path,
        get_path_classifiers,
        get_verification_commands,
        get_frontend_dir,
        get_e2e_test_subdir,
    )
"""
from __future__ import annotations

import re
import sys
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

# Hardcoded defaults — used when harness-project-config.yaml is missing
# the corresponding field. Project owners should override via yaml; the
# fallback values below reflect the original project's layout for zero-config
# operation.
_DEFAULT_ARTIFACTS_ROOT = "_bmad-output/implementation-artifacts"
_DEFAULT_PATH_CLASSIFIERS = [
    ("backend Go source",      r"^console-api/(?!.*_test\.go$)"),
    ("backend Go tests",       r"^console-api/.*_test\.go$|^tests/integration/"),
    ("backend SQL/migrations", r"^console-api/.*\.sql$|^console-api/internal/migrations/"),
    ("backend i18n",           r"^console-api/locales/"),
    ("frontend TS source",     r"^console-web/src/(?!.*\.test\.)"),
    ("frontend TS tests",      r"^console-web/(tests|e2e)/"),
    ("frontend i18n",          r"^console-web/locales/"),
    ("frontend config",        r"^console-web/(eslint|vitest|next|package|pnpm|tsconfig)"),
    ("proxy/Go",               r"^proxy/"),
    ("infra/deploy",           r"^(deploy|docker-compose|Justfile|scripts/)"),
    ("docs/spec",              r"^docs/"),
]
_DEFAULT_VERIFICATION_COMMANDS = (
    "go vet/build/test ./console-api/...\n"
    "pnpm --filter console-web typecheck/test/lint --max-warnings=0/build"
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
# frontend_dir / e2e_test_subdir fallback（review 2026-06-10 finding #9）：
# 与 check_test_harness_env.sh（v0.1.18 起读 frontend_dir，缺省 'console-web'）
# 和 eval_test_stage_triggers.sh（read_project_field e2e_test_subdir 'tests/e2e'）
# 的既有缺省值逐字一致。bash 侧缺省时静默 fallback（不 WARN）——多数项目就用
# 默认布局，每次 commit 都 WARN 只会制造噪音；这里保持同一语义。
_DEFAULT_FRONTEND_DIR = "console-web"
_DEFAULT_E2E_TEST_SUBDIR = "tests/e2e"


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


def _read_extra_scalar(key: str) -> str | None:
    """读 `extra:\n  <key>: <value>` 形式的二级 scalar。"""
    lines = _read_lines()
    if lines is None:
        return None
    in_extra = False
    pat = re.compile(rf"^\s+{re.escape(key)}:\s*(.*)$")
    top_pat = re.compile(r"^[^\s#]")
    for line in lines:
        if line.startswith("extra:"):
            in_extra = True
            continue
        if not in_extra:
            continue
        if top_pat.match(line):
            in_extra = False
            continue
        m = pat.match(line)
        if m:
            val = m.group(1)
            # 排除嵌套结构起始（list / multi-line block 起始 — 留给专用 reader）
            if val.strip() in ("|", ">", "|-", ">-"):
                return None  # 走 multiline reader
            if val.strip() == "":
                return None  # 嵌套结构（list 起始） — 走 list reader
            return _strip_yaml_scalar(val)
    return None


def _read_extra_multiline_block(key: str) -> str | None:
    """读 `extra:\n  <key>: |\n    line1\n    line2`。返回不含末尾 \\n 的 str。"""
    lines = _read_lines()
    if lines is None:
        return None
    in_extra = False
    target_indent: int | None = None
    block_lines: list[str] = []
    block_active = False
    pat = re.compile(rf"^(\s+){re.escape(key)}:\s*\|\s*$")
    top_pat = re.compile(r"^[^\s#]")
    for line in lines:
        if line.startswith("extra:"):
            in_extra = True
            continue
        if not in_extra:
            continue
        if not block_active:
            if top_pat.match(line):
                in_extra = False
                continue
            m = pat.match(line)
            if m:
                target_indent = len(m.group(1))
                block_active = True
            continue
        # 块体：缩进必须深于 target_indent；遇浅缩进或顶级行结束块
        if line.strip() == "":
            block_lines.append("")
            continue
        leading = len(line) - len(line.lstrip())
        if leading <= target_indent:
            break
        # 剥离 target_indent + 2 空格（YAML `|` 块标准）
        strip_n = target_indent + 2
        block_lines.append(line[strip_n:] if len(line) >= strip_n else line.lstrip())
    if not block_active:
        return None
    # 去末尾空行
    while block_lines and block_lines[-1] == "":
        block_lines.pop()
    return "\n".join(block_lines)


def _read_extra_list_of_dict(key: str, sub_keys: tuple[str, ...]) -> list[dict[str, str]] | None:
    """读 `extra:\n  <key>:\n    - sk1: v1\n      sk2: v2\n    - sk1: v3\n...`。"""
    lines = _read_lines()
    if lines is None:
        return None
    in_extra = False
    in_list = False
    list_indent: int | None = None
    out: list[dict[str, str]] = []
    cur: dict[str, str] = {}
    list_start_pat = re.compile(rf"^(\s+){re.escape(key)}:\s*$")
    item_start_pat = re.compile(r"^(\s+)-\s+([^:]+):\s*(.*)$")
    item_cont_pat = re.compile(r"^(\s+)([^:\-][^:]*?):\s*(.*)$")
    top_pat = re.compile(r"^[^\s#]")
    for line in lines:
        if line.startswith("extra:"):
            in_extra = True
            continue
        if not in_extra:
            continue
        if not in_list:
            if top_pat.match(line):
                in_extra = False
                continue
            m = list_start_pat.match(line)
            if m:
                list_indent = len(m.group(1))
                in_list = True
            continue
        # in_list：项要么以 `- ` 开头（缩进 > list_indent），要么是续行
        if line.strip() == "":
            continue
        leading = len(line) - len(line.lstrip())
        if leading <= list_indent:
            break  # 结束 list
        m_item = item_start_pat.match(line)
        if m_item:
            if cur:
                out.append(cur)
            cur = {}
            sk = m_item.group(2).strip()
            sv = _strip_yaml_scalar(m_item.group(3))
            if sk in sub_keys:
                cur[sk] = sv
            continue
        m_cont = item_cont_pat.match(line)
        if m_cont:
            sk = m_cont.group(2).strip()
            sv = _strip_yaml_scalar(m_cont.group(3))
            if sk in sub_keys:
                cur[sk] = sv
    if cur:
        out.append(cur)
    if not in_list:
        return None
    return out


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
    """Return [(label, compiled_regex), ...]. Falls back to hardcoded defaults on miss."""
    raw = _read_extra_list_of_dict("path_classifiers", ("label", "regex"))
    if not raw:
        if raw is None:
            _warn(
                "path_classifiers not set, using hardcoded defaults "
                f"({len(_DEFAULT_PATH_CLASSIFIERS)} entries)"
            )
        # raw == [] 是合法（"全归 other"）— 不 warn
        if raw is None:
            return [(label, re.compile(rgx)) for label, rgx in _DEFAULT_PATH_CLASSIFIERS]
        return []
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
    val = _read_extra_multiline_block("verification_commands")
    if val is None:
        _warn("verification_commands not set, using hardcoded default")
        return _DEFAULT_VERIFICATION_COMMANDS
    return val


def get_project_context() -> str:
    """Return extra.project_context multiline block. Used by harness-prompt-suffix.py
    to inline project-specific decision context into ANSWER_POLICY_BLOCK."""
    val = _read_extra_multiline_block("project_context")
    if val is None or val.strip() == "":
        _warn("extra.project_context not set, using fallback notice")
        return _DEFAULT_PROJECT_CONTEXT
    return val


def get_fullstack_review_steps() -> list[dict[str, str]]:
    """Return extra.fullstack_review_steps as list of {label, file_path} dicts.
    Used by harness-prompt-suffix.py stage 2 to render dev-story Q6 (a)-(z)
    bullets dynamically from project config rather than hardcoded paths."""
    raw = _read_extra_list_of_dict("fullstack_review_steps", ("label", "file_path"))
    if raw is None:
        _warn("extra.fullstack_review_steps not set, using empty list (dev-story Q6 disabled)")
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


def get_frontend_dir() -> str:
    """Return the project's frontend package dir (repo-root relative, outer
    slashes stripped). Lookup order matches the bash readers
    (check_test_harness_env.sh / eval_test_stage_triggers.sh): top-level
    `frontend_dir`, then `extra.frontend_dir`, else 'console-web'. Quiet
    fallback — no WARN (most projects legitimately use the default layout).

    Review 2026-06-10 finding #9: harness-commit.py's E2E_SPEC_PREFIX is
    derived from this + get_e2e_test_subdir() so the commit-time F2 whitelist
    finally agrees with the env probe / trigger eval config source."""
    val, _source = _cli_get("frontend_dir", _DEFAULT_FRONTEND_DIR)
    val = val.strip().strip("/")
    return val or _DEFAULT_FRONTEND_DIR


def get_e2e_test_subdir() -> str:
    """Return the e2e spec subdir under frontend_dir (outer slashes stripped).
    Lookup order matches eval_test_stage_triggers.sh: top-level
    `e2e_test_subdir`, then `extra.e2e_test_subdir`, else 'tests/e2e'.
    Quiet fallback — see get_frontend_dir()."""
    val, _source = _cli_get("e2e_test_subdir", _DEFAULT_E2E_TEST_SUBDIR)
    val = val.strip().strip("/")
    return val or _DEFAULT_E2E_TEST_SUBDIR


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
        print(f"frontend_dir: {get_frontend_dir()}")
        print(f"e2e_test_subdir: {get_e2e_test_subdir()}")
        return 0

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(_cli_main(sys.argv[1:]))
