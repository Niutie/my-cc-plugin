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
    )
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

CONFIG_PATH = Path(__file__).resolve().parents[1] / "harness-project-config.yaml"

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


def _warn(msg: str) -> None:
    print(f"WARN [harness_config]: {msg}", file=sys.stderr)


def _strip_yaml_scalar(val: str) -> str:
    val = val.strip()
    # 去 inline 注释 (# ...) — 但保留引号内的 #
    if val and val[0] not in ("'", '"'):
        # 只在非引号 scalar 里 strip 注释
        idx = val.find("#")
        if idx >= 0:
            val = val[:idx].rstrip()
    # 去外层引号
    if len(val) >= 2 and val[0] == val[-1] and val[0] in ("'", '"'):
        val = val[1:-1]
    return val


def _read_lines() -> list[str] | None:
    if not CONFIG_PATH.exists():
        return None
    try:
        return CONFIG_PATH.read_text(encoding="utf-8").splitlines()
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
    """
    val = _read_top_level_scalar("artifacts_root")
    if val is None or val == "":
        _warn(f"artifacts_root not set, using default '{_DEFAULT_ARTIFACTS_ROOT}'")
        val = _DEFAULT_ARTIFACTS_ROOT
    repo_root = Path(__file__).resolve().parents[3]
    return repo_root / val


def get_sprint_status_path() -> Path:
    return get_artifacts_root() / "sprint-status.yaml"


def get_deferred_work_path() -> Path:
    return get_artifacts_root() / "deferred-work.md"


def get_path_classifiers() -> list[tuple[str, "re.Pattern[str]"]]:
    """Return [(label, compiled_regex), ...]. Falls back to hardcoded defaults on miss."""
    raw = _read_extra_list_of_dict("path_classifiers", ("label", "regex"))
    if not raw:
        if raw is None:
            _warn("path_classifiers not set, using hardcoded defaults (8 entries)")
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


if __name__ == "__main__":
    # CLI smoke test for sanity
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
