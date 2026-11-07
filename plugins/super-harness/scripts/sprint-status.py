#!/usr/bin/env python3
"""sprint-status helper — 给主 agent 调用，读写 sprint-status.yaml。

用法:
    python3 .claude/harness/scripts/sprint-status.py next
        → stdout 输出下一条 backlog story 的 key（如 "1-2-foo"），找不到时退出码 1。
          跳过声明了依赖但依赖没满足的 story（deps_overrides → 顶层 story_dependencies
          → 块写法 depends_on，和 superh.py 同源；`ext-*` 外部条件一直算没满足）。
          因此而找不到时 stderr 打 `waiting=<key>(<deps>);...`。没声明依赖的按文件顺序。

    python3 .claude/harness/scripts/sprint-status.py count
        → stdout 输出 "<backlog_count>/<total_story_count>"。

    python3 .claude/harness/scripts/sprint-status.py set <story_key> <new_status>
        → 把指定 story 的 status 写为 new_status，并刷新 last_updated。

    python3 .claude/harness/scripts/sprint-status.py status <story_key>
        → 输出该 story 当前 status，找不到时退出码 1。
          也接受 epic-* key（如 epic-4-retrospective / epic-4）—— review
          2026-06-10 finding #77 之前 epic-* 被过滤恒 rc=1，迫使
          harness-commit.py 的 stage 6 双 key 翻转跳过读取、无条件 set
          （丢幂等 + 半套状态风险）。读写两侧现在对称（set 一直含 epic key）。

    python3 .claude/harness/scripts/sprint-status.py epic-of <story_key>
        → 输出该 story 所属 epic 编号（key 第一段）。

    python3 .claude/harness/scripts/sprint-status.py epic-all-done <epic_num>
        → 退出码 0 表示该 epic 所有 story 均已终态，1 表示还有未完成。
          harness-project-config.yaml 的 parked_statuses（挂起状态）不算未完成，
          stderr 另打一行 `parked=<key>(<status>),...`；但一条 done 都没有时退出码 1。
          未完成时 stderr 打印清单，并按状态分两行：
            active=<key>(<status>),...        BMad 标准的进行中状态（backlog /
                                              ready-for-dev / in-progress / review）
            unrecognized=<key>(<status>),...  既不是 BMad 标准状态，也不是终态
          只有 unrecognized 时，story 多半是被作废了但状态写法 harness 不认，
          再打印一行改法提示（run-inline.md §2 据此决定 halt 文案）。

    python3 .claude/harness/scripts/sprint-status.py epic-retro-status <epic_num>
        → 输出 epic-N-retrospective 当前状态（找不到则退出码 1）。

    python3 .claude/harness/scripts/sprint-status.py find-by-status <state>
        → 输出文件中最后一条匹配 <state>（按 yaml 出现顺序，即"最近推进"
          到该状态的 story）的 story key；找不到时退出码 1。
          run-sprint --continue / §0.A dirty-worktree 自决用它定位续作 story。

    python3 .claude/harness/scripts/sprint-status.py next-in-epic <epic_num>
        → 输出该 epic 内的下一条 backlog story key（yaml 出现顺序最早的一条），
          找不到时退出码 1。run-sprint --epic 模式的循环退出条件用它。依赖规则同 next。

    python3 .claude/harness/scripts/sprint-status.py open-epics
        → 每行 `<epic_num>\t<retro_status>\t<all-done|active|parked>`，按 yaml 顺序列出
          epic-N-retrospective 不是 done 的 epic（没有 retrospective 行的记 `missing`）。
          第三列：该 epic 的 story 是否已全终态（同 epic-all-done，挂起算终态）；
          parked = 没有 done 的 story、其余全是挂起或放弃。没有 story 的
          epic 不列。run-inline `all` 模式收尾时用它找卡住的 story / 漏跑的 retro。

    python3 .claude/harness/scripts/sprint-status.py epic-stories <epic_num>
        → 每行 `<key>\t<status>`，列出该 epic 的全部 story（harness-commit stage 6
          用它算 EPIC_WONT_DO）。

    python3 .claude/harness/scripts/sprint-status.py action-status <id> [<new_status>]
        → 读 / 写 BMad 6.12 原生 `action_items:` 列表里 `id: <id>` 那一项的 status
          （open / in-progress / done）。找不到 id 时退出码 1。retro-fulfill 翻
          harness `retro_action_items` 的同时用它同步原生账（id 约定
          `epic-<N>-retro-<CODE>`，见 bmad-retrospective-suffix.md）。

    python3 .claude/harness/scripts/sprint-status.py retro-item-done <EPIC> <CODE>
        → 兑现一条 retro 行动项，两本账一起翻（issue #23）：先翻原生 `action_items` 里
          `epic-<EPIC>-retro-<CODE>`（有 uv 和上游 bmad-retrospective 的 sprint_status.py
          时走上游 `update --set-action-status`，BMad 规定的改法；没有就只改那一行
          status），再把 `retro_action_items.epic-<EPIC>-retro.<CODE>` 翻成 done。
          输出 `NATIVE=done|already-done|missing|failed`、`NATIVE_VIA=upstream|fallback`、
          `HARNESS=<旧值>->done`。上游脚本返回失败时 harness 账不动，退出码 1。
          兑现循环、手工兑现、harness 类行动项（提 issue、升级 plugin）都用它。

    python3 .claude/harness/scripts/sprint-status.py action-sync [--fix]
        → 对账：列出 `retro_action_items` 已 done、原生 `action_items` 还没 done 的条目，
          每条一行 `MISMATCH=<id> harness=done native=<status>`，末尾 `MISMATCH_COUNT=<n>`；
          原生先 done 而 harness 没 done 的只报 `NATIVE_AHEAD=<id>`，不改。
          无 `--fix`：0 = 一致，3 = 有不一致。`--fix`：按 epic 一次调用上游脚本翻成 done
          （同 retro-item-done 的退路），全部成功退出码 0，有失败 1。retro 之前跑一次
          （pipeline.md ⑥），follow-through 段就不用手工数。

    python3 .claude/harness/scripts/sprint-status.py flatten-deps [--check]
        → 把 development_status 里的多行块（key + 嵌套 status / depends_on）改写成单行
          `key: status`，depends_on 挪到顶层 story_dependencies（已有的条目不覆盖）。
          BMad 6.12.4 的 sprint_plan.py / retrospective 脚本只认单行写法（issue #14）。
          stdout 打印改写条数。`--check` 只报告：0 = 无需改写，3 = 需要改写。
          块里有 status / depends_on 以外的字段时什么都不写，stderr 打 PROBLEM= 行，退出码 4。

    python3 .claude/harness/scripts/sprint-status.py migrate-retro-items [--check]
        → 把 retro_action_items 里 ≤ 0.1.39 的标量写法（`A1: pending` + 过缩进子键，
          不是合法 YAML）改写为嵌套映射（`A1:` + `status: pending`）。`--check` 只报告：
          退出码 0 = 无需迁移，3 = 需要迁移（stdout 打印条目数）。BMad 6.12 的原生脚本
          整文件按 YAML 解析，旧写法会让它们直接失败。

终态：epic-all-done 把 `done` 与放弃态 `wont-do` / `cancelled`（`canceled` 也认）
都视为完成，清单见 harness_spec.TERMINAL_STORY_STATUSES（issue #13）。

故意手写 yaml 解析（避免引入 PyYAML 依赖）。兼容 development_status 下两种布局：
  - 单行：`  <key>: <status>`（含行尾 inline 注释）
  - 多行块（带 depends_on；BMad 6.12.4 自己的 sprint_plan.py / retrospective 脚本读不了
    这种写法，issue #14，用 6.12 的项目改用单行 + 顶层 story_dependencies）：
        <key>:
          status: backlog
          depends_on: [...]
见 _iter_dev_status（读）/ cmd_set（写）。issue Niutie/my-cc-plugin#4。
"""

from __future__ import annotations

import datetime
import os
import re
import sys
# Never drop __pycache__/ next to the deployed scripts: an untracked dir there
# makes the worktree dirty, and bmad-build-auto refuses to start on a dirty tree.
sys.dont_write_bytecode = True
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from harness_config import get_artifacts_root, get_sprint_status_path  # noqa: E402
try:
    from harness_config import get_parked_statuses  # noqa: E402
except ImportError:  # pragma: no cover — older deployed harness_config
    def get_parked_statuses():
        return ()
from harness_spec import (  # noqa: E402
    ACTIVE_STORY_STATUSES,
    DROPPED_STORY_STATUSES,
    TERMINAL_STORY_STATUSES,
)

PROJECT_ROOT = Path(__file__).resolve().parents[3]
SPRINT_FILE = get_sprint_status_path()

# Tolerates trailing inline comments (`  story-key: status  # explanation`) per
# YAML spec; harness-changelog 2026-05-03 (post-epic-2 retro) — without this
# tolerance, a single inline comment on a backlog line silently drops the story
# from `next` / `count` / `epic-all-done` evaluations. Documented in
# run-sprint.md §0.A. Standalone comments above the line remain the preferred
# convention for readability.
# Story key 用 [^\s:#] 而非 [A-Za-z0-9_\-]，让 BMad 中文模式产出的 CJK
# story key（如 `1-1-后端工程脚手架`）能被解析。yaml 语法约束：unquoted
# mapping key 不能含 whitespace 或 `:`；`#` 是行内注释起点 — 三者都可作
# delimiter，把它们排除即可。整个 regex 只在 development_status 块内匹配
# （见 _iter_dev_status 的 in_block 状态机），不会误吃其他 yaml 段。
# 单行 entry：`  story-key: status  # comment`（value 与 key 同行）
STORY_KEY_RE = re.compile(r"^\s+([^\s:#]+):\s*(\S+)\s*(?:#.*)?$")
# 多行块 entry 的 key 行：`  story-key:`（冒号后无 value，value 在缩进更深的子键）
BLOCK_KEY_RE = re.compile(r"^(\s+)([^\s:#]+):\s*(?:#.*)?$")
# 多行块内的 status 子键：`    status: backlog  # comment`
NESTED_STATUS_RE = re.compile(r"^\s+status:\s*(\S+)\s*(?:#.*)?$")


def _iter_dev_status(include_epic_keys: bool = False) -> list[tuple[int, str, str]]:
    """返回 [(line_index, key, status), ...]。默认仅 story；include_epic_keys=True 时含 epic-* 行。

    兼容单行与多行块两种布局（issue #4）。line_index 指向**承载 status 值的那一行**：
    单行 entry = key 行；多行块 = nested `status:` 行 —— 使 cmd_set 能就地改写正确的行。
    """
    if not SPRINT_FILE.exists():
        sys.exit(f"missing {SPRINT_FILE} — 请先运行 /bmad-sprint-planning")
    lines = SPRINT_FILE.read_text(encoding="utf-8").splitlines()
    out: list[tuple[int, str, str]] = []
    in_block = False
    base_indent: int | None = None
    pending_key: str | None = None  # 多行块 entry key，等待其 nested status:
    for i, line in enumerate(lines):
        stripped = line.rstrip()
        if stripped.startswith("development_status:"):
            in_block = True
            continue
        if not in_block:
            continue
        if stripped and not stripped.startswith((" ", "\t", "#")):
            break
        if not stripped or stripped.lstrip().startswith("#"):
            continue  # 空行 / 整行注释
        indent = len(line) - len(line.lstrip())
        if base_indent is None:
            base_indent = indent
        if indent <= base_indent:
            # entry 级别行：单行 `key: value` 或 多行块 `key:`
            pending_key = None
            m_full = STORY_KEY_RE.match(stripped)
            if m_full:
                key = m_full.group(1)
                status = m_full.group(2).strip().strip('"').strip("'")
                if key.startswith("epic-") and not include_epic_keys:
                    continue
                out.append((i, key, status))
                continue
            m_block = BLOCK_KEY_RE.match(stripped)
            if m_block:
                pending_key = m_block.group(2)  # 等 nested status:
            continue
        # indent > base_indent：多行块的 nested 子键
        if pending_key is not None:
            m_status = NESTED_STATUS_RE.match(stripped)
            if m_status:
                status = m_status.group(1).strip().strip('"').strip("'")
                if not (pending_key.startswith("epic-") and not include_epic_keys):
                    out.append((i, pending_key, status))
                pending_key = None  # 已取到 status；块内 depends_on 等忽略
    return out


def _find_action_item_status_line(lines: list[str], item_id: str) -> int | None:
    """Line index of the `status:` key of the `action_items:` entry whose id
    equals item_id (quoted or bare). None when absent."""
    in_block = False
    in_item = False
    item_matches = False
    item_indent = None
    status_idx = None
    for i, line in enumerate(lines):
        stripped = line.rstrip("\n")
        if not in_block:
            if stripped.startswith("action_items:"):
                in_block = True
            continue
        if stripped and not stripped.startswith((" ", "\t", "-", "#")):
            break  # next top-level key
        m_item = re.match(r"^(\s*)-\s+(.*)$", stripped)
        if m_item and (item_indent is None or len(m_item.group(1)) == item_indent):
            if in_item and item_matches and status_idx is not None:
                return status_idx
            item_indent = len(m_item.group(1))
            in_item = True
            item_matches = False
            status_idx = None
            first = m_item.group(2)
            fields = [(i, first)]
        elif in_item:
            fields = [(i, stripped.strip())]
        else:
            continue
        for idx, text in fields:
            m_kv = re.match(r"^([A-Za-z_][\w-]*):\s*(.*?)\s*(?:#.*)?$", text)
            if not m_kv:
                continue
            k, v = m_kv.group(1), m_kv.group(2).strip().strip('"').strip("'")
            if k == "id" and v == item_id:
                item_matches = True
            elif k == "status":
                status_idx = idx
    if in_item and item_matches and status_idx is not None:
        return status_idx
    return None


def cmd_action_status(item_id: str, new_status: str | None) -> int:
    if not SPRINT_FILE.exists():
        sys.exit(f"missing {SPRINT_FILE}")
    text_lines = SPRINT_FILE.read_text(encoding="utf-8").splitlines(keepends=True)
    idx = _find_action_item_status_line(text_lines, item_id)
    if idx is None:
        return 1
    line = text_lines[idx]
    m = re.match(r"^(\s*(?:-\s+)?status:\s*)([\"']?)([^\"'#\s]*)([\"']?)(\s*#.*)?(\r?\n)?$", line)
    if not m:
        sys.exit(f"failed to parse action item status line {idx}: {line!r}")
    if new_status is None:
        print(m.group(3))
        return 0
    if new_status not in ("open", "in-progress", "done"):
        sys.exit(f"invalid action item status {new_status!r} (open / in-progress / done)")
    text_lines[idx] = f"{m.group(1)}{m.group(2)}{new_status}{m.group(4)}{m.group(5) or ''}{m.group(6) or ''}"
    _atomic_write(SPRINT_FILE, "".join(text_lines))
    return 0


# --- retro action items: harness ledger + BMad native ledger (issue #23) ------

_RAI_EPIC_RE = re.compile(r"^(\s+)epic-(\d+)-retro:\s*(#.*)?$")
_RAI_CODE_NESTED_RE = re.compile(r"^(\s+)([A-Z][A-Za-z0-9-]*):\s*(#.*)?$")
_RAI_CODE_SCALAR_RE = re.compile(r"^(\s+)([A-Z][A-Za-z0-9-]*):[ \t]+['\"]?([A-Za-z-]+)['\"]?[ \t]*(#.*)?$")
_RAI_STATUS_RE = re.compile(r"^(\s+status:[ \t]*)(['\"]?)([A-Za-z-]*)(['\"]?)([ \t]*#.*)?$")


def _retro_items(lines: list[str]) -> list[dict]:
    """[{epic, code, status, idx, scalar}] for every item under retro_action_items.
    idx is the line holding the status (the `status:` child, or the scalar line)."""
    out = []
    in_rai, epic, epic_indent, cur = False, None, None, None
    for i, raw in enumerate(lines):
        line = raw.rstrip("\r\n")
        if not in_rai:
            if re.match(r"^retro_action_items:\s*(#.*)?$", line):
                in_rai = True
            continue
        if line and not line[0].isspace() and not line.lstrip().startswith("#"):
            break
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = _RAI_EPIC_RE.match(line)
        if m:
            epic, epic_indent, cur = m.group(2), len(m.group(1)), None
            continue
        if epic is None or len(line) - len(line.lstrip()) <= epic_indent:
            continue
        m = _RAI_CODE_SCALAR_RE.match(line)
        if m and m.group(2) != "status" and (cur is None or len(m.group(1)) <= cur["indent"]):
            cur = {"epic": epic, "code": m.group(2), "status": m.group(3), "idx": i, "scalar": True,
                   "indent": len(m.group(1))}
            out.append(cur)
            continue
        m = _RAI_CODE_NESTED_RE.match(line)
        if m and (cur is None or len(m.group(1)) <= cur["indent"]):
            cur = {"epic": epic, "code": m.group(2), "status": None, "idx": None, "scalar": False,
                   "indent": len(m.group(1))}
            out.append(cur)
            continue
        if cur is not None and not cur["scalar"] and cur["idx"] is None:
            m = _RAI_STATUS_RE.match(line)
            if m and len(line) - len(line.lstrip()) > cur["indent"]:
                cur["status"], cur["idx"] = m.group(3), i
    return out


def _upstream_set_action_status(epic: str, ids: list[str]):
    """Flip native action items via BMad's own script. None = unavailable (no uv
    or no script); otherwise (ok, detail)."""
    import json
    import shutil
    import subprocess
    script = PROJECT_ROOT / ".claude" / "skills" / "bmad-retrospective" / "scripts" / "sprint_status.py"
    uv = shutil.which("uv")
    if os.environ.get("HARNESS_NO_UPSTREAM") or not uv or not script.is_file():
        return None
    payload = json.dumps([{"id": i, "status": "done"} for i in ids])
    try:
        r = subprocess.run([uv, "run", "--no-cache", str(script), "update", "--file", str(SPRINT_FILE),
                            "--epic", str(epic), "--set-action-status", payload],
                           capture_output=True, text=True, timeout=300)
    except (OSError, subprocess.SubprocessError) as e:
        return (False, str(e))
    try:
        ok = bool(json.loads(r.stdout or "{}").get("ok")) and r.returncode == 0
    except ValueError:
        ok = False
    return (ok, (r.stdout + r.stderr).strip()[-600:])


def _native_status(item_id: str) -> str | None:
    lines = SPRINT_FILE.read_text(encoding="utf-8").splitlines(keepends=True)
    idx = _find_action_item_status_line(lines, item_id)
    if idx is None:
        return None
    m = re.match(r"^\s*(?:-\s+)?status:\s*[\"']?([^\"'#\s]*)", lines[idx])
    return m.group(1) if m else None


def _flip_native(epic: str, ids: list[str]) -> tuple[bool, str, str]:
    """(ok, via, detail) — upstream when available, else one-line fallback."""
    up = _upstream_set_action_status(epic, ids)
    if up is not None:
        return (up[0], "upstream", up[1])
    for i in ids:
        cmd_action_status(i, "done")
    return (True, "fallback", "")


def _set_harness_done(epic: str, code: str) -> str | None:
    lines = SPRINT_FILE.read_text(encoding="utf-8").splitlines(keepends=True)
    item = next((it for it in _retro_items(lines) if it["epic"] == epic and it["code"] == code), None)
    if item is None or item["idx"] is None:
        return None
    old = item["status"]
    if old == "done":
        return old
    line = lines[item["idx"]]
    if item["scalar"]:
        lines[item["idx"]] = re.sub(r"^(\s+[A-Z][A-Za-z0-9-]*:[ \t]+['\"]?)[A-Za-z-]+", r"\g<1>done", line, count=1)
    else:
        lines[item["idx"]] = re.sub(r"^(\s+status:[ \t]*['\"]?)[A-Za-z-]*", r"\g<1>done", line, count=1)
    _atomic_write(SPRINT_FILE, "".join(lines))
    return old


def cmd_retro_item_done(epic: str, code: str) -> int:
    if not SPRINT_FILE.exists():
        sys.exit(f"missing {SPRINT_FILE}")
    epic = epic.strip()
    lines = SPRINT_FILE.read_text(encoding="utf-8").splitlines(keepends=True)
    if not any(it["epic"] == epic and it["code"] == code for it in _retro_items(lines)):
        print(f"REASON=retro_action_items 里没有 epic-{epic}-retro.{code}", file=sys.stderr)
        return 1
    item_id = f"epic-{epic}-retro-{code}"
    native = _native_status(item_id)
    if native is None:
        print("NATIVE=missing")
    elif native == "done":
        print("NATIVE=already-done")
    else:
        ok, via, detail = _flip_native(epic, [item_id])
        print(f"NATIVE_VIA={via}")
        if not ok:
            print("NATIVE=failed")
            print(f"UPSTREAM_OUTPUT={detail}")
            print("REASON=上游 sprint_status.py 没能翻原生条目；harness 账没有动，把输出交给用户", file=sys.stderr)
            return 1
        print("NATIVE=done")
    old = _set_harness_done(epic, code)
    print(f"HARNESS={old}->done")
    return 0


def cmd_action_sync(fix: bool) -> int:
    if not SPRINT_FILE.exists():
        sys.exit(f"missing {SPRINT_FILE}")
    lines = SPRINT_FILE.read_text(encoding="utf-8").splitlines(keepends=True)
    mism, ahead = [], []
    for it in _retro_items(lines):
        item_id = f"epic-{it['epic']}-retro-{it['code']}"
        idx = _find_action_item_status_line(lines, item_id)
        if idx is None:
            continue
        m = re.match(r"^\s*(?:-\s+)?status:\s*[\"']?([^\"'#\s]*)", lines[idx])
        native = m.group(1) if m else ""
        if it["status"] == "done" and native != "done":
            mism.append((it["epic"], item_id, native))
        elif native == "done" and it["status"] not in ("done", "wont-do", "cancelled"):
            ahead.append(item_id)
    for _e, i, n in mism:
        print(f"MISMATCH={i} harness=done native={n}")
    for i in ahead:
        print(f"NATIVE_AHEAD={i}")
    print(f"MISMATCH_COUNT={len(mism)}")
    if not mism:
        return 0
    if not fix:
        return 3
    failed = 0
    for epic in sorted({e for e, _i, _n in mism}, key=lambda x: int(x)):
        ids = [i for e, i, _n in mism if e == epic]
        ok, via, detail = _flip_native(epic, ids)
        if ok:
            print(f"FIXED={','.join(ids)} via={via}")
        else:
            failed += len(ids)
            print(f"FIX_FAILED={','.join(ids)}")
            print(f"UPSTREAM_OUTPUT={detail}")
    return 1 if failed else 0


def _unmet_deps() -> dict[str, list[str]]:
    """{backlog story key: [unmet dependency tokens]} from the same sources
    /super-harness:run uses — parallel.yaml deps_overrides, then sprint-status
    top-level story_dependencies, then a block entry's depends_on. `ext-*` tokens
    (outside conditions) are always unmet; so is a token that names no story.
    A story with no declared dependencies is never listed here: run-inline goes
    in file order anyway."""
    try:
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "superh_for_sprint_status", str(Path(__file__).resolve().parent / "superh.py"))
        sh = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sh)
        stories, _ = sh.parse_sprint(SPRINT_FILE)
        cfg_path = PROJECT_ROOT / ".claude" / "harness" / "parallel.yaml"
        overrides = sh.load_config(cfg_path).get("deps_overrides") or {} if cfg_path.exists() else {}
    except (Exception, SystemExit):
        return {}
    status = {st["key"]: st["status"] for st in stories}
    out: dict[str, list[str]] = {}
    for st in stories:
        if st["status"] != "backlog":
            continue
        deps = overrides.get(st["key"], st["deps"])
        if deps is None:
            continue
        if isinstance(deps, str):
            deps = [deps]
        unmet = []
        for d in deps:
            d = str(d)
            if d.startswith("ext-"):
                unmet.append(d)
                continue
            ks = sh.resolve_dep(d, stories)
            if not ks:
                unmet.append(f"{d}(无法解析)")
            unmet += [k for k in ks if k != st["key"] and status.get(k) not in TERMINAL_STORY_STATUSES]
        if unmet:
            out[st["key"]] = unmet
    return out


def _next_backlog(prefix: str = "") -> int:
    unmet = _unmet_deps()
    waiting = []
    for _, key, status in _iter_dev_status():
        if status == "backlog" and key.startswith(prefix):
            if key in unmet:
                waiting.append(f"{key}({','.join(unmet[key])})")
                continue
            print(key)
            return 0
    if waiting:
        print("waiting=" + ";".join(waiting), file=sys.stderr)
    return 1


def cmd_next() -> int:
    return _next_backlog()


def cmd_count() -> int:
    items = _iter_dev_status()
    backlog = sum(1 for _, _, s in items if s == "backlog")
    print(f"{backlog}/{len(items)}")
    return 0


def cmd_status(key: str) -> int:
    # include_epic_keys=True（finding #77）：epic-N-retrospective / epic-N 与
    # story key 同住 development_status 块，set 一直可写它们，status 却读不到
    # —— 读写不对称迫使 harness-commit.py 对 epic-* 跳过幂等检查。story key
    # 查询行为不变（epic-* 只是不再被过滤）。
    for _, k, s in _iter_dev_status(include_epic_keys=True):
        if k == key:
            print(s)
            return 0
    return 1


def cmd_set(key: str, new_status: str) -> int:
    # include_epic_keys=True 因为 playbook 阶段 ⑥ 要 set epic-N-retrospective
    items = _iter_dev_status(include_epic_keys=True)
    target_lines = [i for i, k, _ in items if k == key]
    if not target_lines:
        sys.exit(f"key not found: {key}")
    text_lines = SPRINT_FILE.read_text(encoding="utf-8").splitlines(keepends=True)
    idx = target_lines[0]
    line = text_lines[idx]
    # idx 指向承载 status 值的行：单行 entry 的 `key: value`，或多行块的 `  status: value`。
    # field 名既可能是 story key 也可能是字面量 'status' —— 用通用 field 匹配，并保留行尾 inline 注释。
    # 注意 [ \t] 而不是 \s — \s 会吃掉行末 \n 导致下一行粘连。
    m = re.match(r"^([ \t]+)([^\s:#]+):[ \t]*\S+([ \t]*#.*)?(\r?\n)?$", line)
    if not m:
        sys.exit(f"failed to rewrite line {idx}: {line!r}")
    trailing = m.group(3) or ""  # 保留行尾 inline 注释（如有）
    text_lines[idx] = f"{m.group(1)}{m.group(2)}: {new_status}{trailing}{m.group(4) or ''}"
    today = datetime.date.today().isoformat()
    for j, l in enumerate(text_lines):
        if l.startswith("last_updated:"):
            text_lines[j] = f"last_updated: {today}\n"
            break
    _atomic_write(SPRINT_FILE, "".join(text_lines))
    return 0


def _atomic_write(path, content: str) -> None:
    """temp + fsync + os.replace。中途中断不会留下截断文件。保留原文件权限。"""
    parent = path.parent
    try:
        src_mode = os.stat(path).st_mode & 0o777
    except FileNotFoundError:
        src_mode = 0o644
    fd, tmp_path = tempfile.mkstemp(
        dir=str(parent), prefix=f".{path.name}.", suffix=".tmp"
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp_path, src_mode)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def cmd_epic_of(key: str) -> int:
    head = key.split("-", 1)[0]
    if not head.isdigit():
        sys.exit(f"key {key} 不是合法的 story key（首段不是数字）")
    print(head)
    return 0


def cmd_epic_all_done(epic_num: str) -> int:
    items = _iter_dev_status()
    prefix = f"{epic_num}-"
    matched = [(k, s) for _, k, s in items if k.startswith(prefix)]
    if not matched:
        sys.exit(f"epic {epic_num} 在 sprint-status 中没有 story")
    parked_set = set(get_parked_statuses())
    parked = [(k, s) for k, s in matched if s in parked_set]
    pending = [(k, s) for k, s in matched if s not in TERMINAL_STORY_STATUSES and s not in parked_set]
    if not pending:
        if parked and not any(s == "done" for _, s in matched):
            print(f"epic {epic_num}: 没有 done 的 story，其余都挂起或放弃，没有可回顾的内容；"
                  f"parked={','.join(f'{k}({s})' for k, s in parked)}", file=sys.stderr)
            return 1
        if parked:
            print(f"parked={','.join(f'{k}({s})' for k, s in parked)}", file=sys.stderr)
        return 0

    def fmt(pairs):
        return ",".join(f"{k}({s})" for k, s in pairs)

    active = [(k, s) for k, s in pending if s in ACTIVE_STORY_STATUSES]
    unknown = [(k, s) for k, s in pending if s not in ACTIVE_STORY_STATUSES]
    lines = [
        f"epic {epic_num}: {len(matched) - len(pending)}/{len(matched)} done; pending={fmt(pending)}",
        f"active={fmt(active) or 'none'}",
        f"unrecognized={fmt(unknown) or 'none'}",
    ]
    if unknown and not active:
        lines.append(
            "hint: 剩下的 story 状态既不是 BMad 标准状态也不是终态，--continue 续不了。"
            "若它们已作废，把状态改成 " + " / ".join(DROPPED_STORY_STATUSES[:2]) +
            "；若已交付，改成 done；改完重跑。"
        )
    print("\n".join(lines), file=sys.stderr)
    return 1


def cmd_epic_retro_status(epic_num: str) -> int:
    target = f"epic-{epic_num}-retrospective"
    for _, k, s in _iter_dev_status(include_epic_keys=True):
        if k == target:
            print(s)
            return 0
    return 1


def cmd_migrate_retro_items(check_only: bool) -> int:
    import harness_spec  # sourceable lib next to this script
    if not SPRINT_FILE.exists():
        sys.exit(f"missing {SPRINT_FILE}")
    text = SPRINT_FILE.read_text(encoding="utf-8")
    new_text, n = harness_spec.migrate_retro_items_text(text)
    print(n)
    if check_only:
        return 3 if n else 0
    if n:
        _atomic_write(SPRINT_FILE, new_text)
    return 0


_FLAT_KEY_RE = re.compile(r"^(\s+)([^\s:#][^\s:]*):\s*(#.*)?$")
_FLAT_NESTED_RE = re.compile(r"^\s+([A-Za-z_]+):\s*(.*?)\s*$")


def flatten_dev_status_text(text: str) -> tuple[str, int, list[str]]:
    """Rewrite block entries under development_status (`key:` + nested `status:` /
    `depends_on:`) as single-line `key: status`, moving depends_on into the
    top-level `story_dependencies` map (issue #14: BMad 6.12.4's sprint_plan.py and
    retrospective sprint_status.py only read the single-line layout).

    Returns (new_text, converted_count, problems). Entries already present in
    story_dependencies keep their existing value. A block with any nested field
    other than status / depends_on is reported in problems and nothing is written
    (the caller refuses), so no information is dropped silently."""
    lines = text.splitlines(keepends=True)
    out: list[str] = []
    deps: dict[str, list[str]] = {}
    problems: list[str] = []
    converted = 0
    i, n = 0, len(lines)
    in_dev = False
    base = None
    while i < n:
        line = lines[i]
        raw = line.rstrip("\r\n")
        if raw.startswith("development_status:"):
            in_dev = True
            out.append(line)
            i += 1
            continue
        if in_dev and raw and not raw[0].isspace() and not raw.startswith("#"):
            in_dev = False
        if not in_dev or not raw.strip() or raw.lstrip().startswith("#"):
            out.append(line)
            i += 1
            continue
        indent = len(raw) - len(raw.lstrip())
        if base is None:
            base = indent
        m = _FLAT_KEY_RE.match(raw) if indent == base else None
        if not m:
            out.append(line)
            i += 1
            continue
        key, comment = m.group(2), m.group(3)
        j = i + 1
        status, dlist, extra = None, None, []
        while j < n:
            r = lines[j].rstrip("\r\n")
            if r.strip() and (len(r) - len(r.lstrip())) <= base:
                break
            st = r.strip()
            if not st or st.startswith("#"):
                j += 1
                continue
            if st.startswith("- ") and dlist is not None:
                dlist.append(st[2:].split(" #")[0].strip().strip("'\""))
                j += 1
                continue
            mm = _FLAT_NESTED_RE.match(r)
            if mm and mm.group(1) == "status":
                status = mm.group(2).split(" #")[0].strip().strip("'\"")
            elif mm and mm.group(1) == "depends_on":
                v = mm.group(2).split(" #")[0].strip()
                if v.startswith("["):
                    inner = v[1:v.rfind("]")] if "]" in v else v[1:]
                    dlist = [x.strip().strip("'\"") for x in inner.split(",") if x.strip()]
                elif v:
                    dlist = [v.strip("'\"")]
                else:
                    dlist = []
            else:
                extra.append(st)
            j += 1
        if status is None:
            out.extend(lines[i:j])
            i = j
            continue
        if extra:
            problems.append(f"{key}: 除 status / depends_on 外还有字段 {extra[:3]}")
        eol = "\r\n" if line.endswith("\r\n") else "\n"
        out.append(f"{' ' * base}{key}: {status}" + (f"  {comment}" if comment else "") + eol)
        if dlist is not None:
            deps[key] = dlist
        converted += 1
        i = j
    new_text = "".join(out)
    if deps:
        harness_spec = __import__("harness_spec")
        existing = harness_spec.parse_story_dependencies(new_text)
        add = {k: v for k, v in deps.items() if k not in existing}
        if add:
            def fmt(v):
                return "[" + ", ".join(v) + "]"
            body = "".join(f"  {k}: {fmt(v)}\n" for k, v in add.items())
            if re.search(r"(?m)^story_dependencies:\s*(#.*)?$", new_text):
                # insert right after the existing header line
                new_text = re.sub(r"(?m)^(story_dependencies:[^\n]*\n)", lambda mo: mo.group(1) + body,
                                  new_text, count=1)
            else:
                if not new_text.endswith("\n"):
                    new_text += "\n"
                new_text += ("\n# 依赖（issue #14：BMad 6.12.4 只认单行 development_status；"
                             "super-harness 从这里读依赖）\nstory_dependencies:\n" + body)
    return new_text, converted, problems


def cmd_flatten_deps(check_only: bool) -> int:
    if not SPRINT_FILE.exists():
        sys.exit(f"missing {SPRINT_FILE}")
    text = SPRINT_FILE.read_text(encoding="utf-8")
    new_text, n, problems = flatten_dev_status_text(text)
    print(n)
    if problems:
        for pr in problems:
            print(f"PROBLEM={pr}", file=sys.stderr)
        return 4
    if check_only:
        return 3 if n else 0
    if n:
        _atomic_write(SPRINT_FILE, new_text)
    return 0


def cmd_epic_stories(epic_num: str) -> int:
    """每行 `<key>\t<status>`，该 epic 的全部 story（yaml 顺序）。"""
    prefix = f"{epic_num}-"
    for _, k, st in _iter_dev_status():
        if k.startswith(prefix):
            print(f"{k}\t{st}")
    return 0


def cmd_open_epics() -> int:
    """每行 `<epic>\t<retro_status>\t<all-done|active>`：retro 不是 done 的 epic。"""
    items = _iter_dev_status(include_epic_keys=True)
    retro: dict[str, str] = {}
    stories: dict[str, list[str]] = {}
    order: list[str] = []
    for _, k, st in items:
        m = re.match(r"^epic-(\d+)-retrospective$", k)
        if m:
            retro[m.group(1)] = st
            continue
        if k.startswith("epic-"):
            continue
        head = k.split("-", 1)[0]
        if not head.isdigit():
            continue
        if head not in stories:
            stories[head] = []
            order.append(head)
        stories[head].append(st)
    for epic in order:
        rs = retro.get(epic, "missing")
        if rs == "done":
            continue
        parked_set = set(get_parked_statuses())
        settled = all(st in TERMINAL_STORY_STATUSES or st in parked_set for st in stories[epic])
        if not settled:
            col = "active"
        elif any(st in parked_set for st in stories[epic]) and "done" not in stories[epic]:
            col = "parked"      # nothing delivered yet: no retro to run
        else:
            col = "all-done"
        print(f"{epic}\t{rs}\t{col}")
    return 0


def cmd_next_in_epic(epic_num: str) -> int:
    return _next_backlog(f"{epic_num}-")


def cmd_find_by_status(state: str) -> int:
    # 文件出现顺序的最后一条 = 最近推进到该状态的 story（单 track sprint
    # 一般同时只有一条 review；多条时取最近的）。
    last_key = None
    for _, k, s in _iter_dev_status():
        if s == state:
            last_key = k
    if last_key is None:
        return 1
    print(last_key)
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd = argv[1]
    if cmd == "next":
        return cmd_next()
    if cmd == "count":
        return cmd_count()
    if cmd == "status" and len(argv) == 3:
        return cmd_status(argv[2])
    if cmd == "set" and len(argv) == 4:
        return cmd_set(argv[2], argv[3])
    if cmd == "epic-of" and len(argv) == 3:
        return cmd_epic_of(argv[2])
    if cmd == "epic-all-done" and len(argv) == 3:
        return cmd_epic_all_done(argv[2])
    if cmd == "epic-retro-status" and len(argv) == 3:
        return cmd_epic_retro_status(argv[2])
    if cmd == "find-by-status" and len(argv) == 3:
        return cmd_find_by_status(argv[2])
    if cmd == "next-in-epic" and len(argv) == 3:
        return cmd_next_in_epic(argv[2])
    if cmd == "migrate-retro-items" and len(argv) in (2, 3):
        if len(argv) == 3 and argv[2] != "--check":
            sys.exit(__doc__)
        return cmd_migrate_retro_items(len(argv) == 3)
    if cmd == "flatten-deps" and len(argv) in (2, 3):
        if len(argv) == 3 and argv[2] != "--check":
            sys.exit(__doc__)
        return cmd_flatten_deps(len(argv) == 3)
    if cmd == "open-epics" and len(argv) == 2:
        return cmd_open_epics()
    if cmd == "epic-stories" and len(argv) == 3:
        return cmd_epic_stories(argv[2])
    if cmd == "retro-item-done" and len(argv) == 4:
        return cmd_retro_item_done(argv[2], argv[3])
    if cmd == "action-sync" and len(argv) in (2, 3):
        if len(argv) == 3 and argv[2] != "--fix":
            sys.exit("usage: sprint-status.py action-sync [--fix]")
        return cmd_action_sync(len(argv) == 3)
    if cmd == "action-status" and len(argv) in (3, 4):
        return cmd_action_status(argv[2], argv[3] if len(argv) == 4 else None)
    sys.exit(__doc__)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
