#!/usr/bin/env python3
"""sprint-status helper — 给主 agent 调用，读写 sprint-status.yaml。

用法:
    python3 .claude/harness/scripts/sprint-status.py next
        → stdout 输出下一条 backlog story 的 key（如 "1-2-foo"），找不到时退出码 1。

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
        → 退出码 0 表示该 epic 所有 story 均 done，1 表示还有未完成；
          stderr 同时打印简要清单。

    python3 .claude/harness/scripts/sprint-status.py epic-retro-status <epic_num>
        → 输出 epic-N-retrospective 当前状态（找不到则退出码 1）。

    python3 .claude/harness/scripts/sprint-status.py find-by-status <state>
        → 输出文件中最后一条匹配 <state>（按 yaml 出现顺序，即"最近推进"
          到该状态的 story）的 story key；找不到时退出码 1。
          run-sprint --continue / §0.A dirty-worktree 自决用它定位续作 story。

    python3 .claude/harness/scripts/sprint-status.py next-in-epic <epic_num>
        → 输出该 epic 内的下一条 backlog story key（yaml 出现顺序最早的一条），
          找不到时退出码 1。run-sprint --epic 模式的循环退出条件用它。

    python3 .claude/harness/scripts/sprint-status.py epic-stories <epic_num>
        → 每行 `<key>\t<status>`，列出该 epic 的全部 story（harness-commit stage 6
          用它算 EPIC_WONT_DO）。

    python3 .claude/harness/scripts/sprint-status.py action-status <id> [<new_status>]
        → 读 / 写 BMad 6.12 原生 `action_items:` 列表里 `id: <id>` 那一项的 status
          （open / in-progress / done）。找不到 id 时退出码 1。retro-fulfill 翻
          harness `retro_action_items` 的同时用它同步原生账（id 约定
          `epic-<N>-retro-<CODE>`，见 bmad-retrospective-suffix.md）。

    python3 .claude/harness/scripts/sprint-status.py migrate-retro-items [--check]
        → 把 retro_action_items 里 ≤ 0.1.39 的标量写法（`A1: pending` + 过缩进子键，
          不是合法 YAML）改写为嵌套映射（`A1:` + `status: pending`）。`--check` 只报告：
          退出码 0 = 无需迁移，3 = 需要迁移（stdout 打印条目数）。BMad 6.12 的原生脚本
          整文件按 YAML 解析，旧写法会让它们直接失败。

终态：epic-all-done 把 `done` 与 `wont-do`（项目自定义的放弃态）都视为完成。

故意手写 yaml 解析（避免引入 PyYAML 依赖）。兼容 development_status 下两种布局：
  - 单行：`  <key>: <status>`（含行尾 inline 注释）
  - 多行块（BMad v6.7.1+ bmad-sprint-planning 默认，带 depends_on）：
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


# `wont-do` is not in the BMad template vocabulary but real projects use it for
# stories deliberately dropped; without it an epic carrying one never reads as
# all-done and its retrospective is never triggered.
TERMINAL_STORY_STATUSES = ("done", "wont-do")


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


def cmd_next() -> int:
    for _, key, status in _iter_dev_status():
        if status == "backlog":
            print(key)
            return 0
    return 1


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
    pending = [(k, s) for k, s in matched if s not in TERMINAL_STORY_STATUSES]
    if not pending:
        return 0
    print(
        f"epic {epic_num}: {len(matched) - len(pending)}/{len(matched)} done; pending=" +
        ",".join(f"{k}({s})" for k, s in pending),
        file=sys.stderr,
    )
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


def cmd_epic_stories(epic_num: str) -> int:
    """每行 `<key>\t<status>`，该 epic 的全部 story（yaml 顺序）。"""
    prefix = f"{epic_num}-"
    for _, k, st in _iter_dev_status():
        if k.startswith(prefix):
            print(f"{k}\t{st}")
    return 0


def cmd_next_in_epic(epic_num: str) -> int:
    prefix = f"{epic_num}-"
    for _, key, status in _iter_dev_status():
        if key.startswith(prefix) and status == "backlog":
            print(key)
            return 0
    return 1


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
    if cmd == "epic-stories" and len(argv) == 3:
        return cmd_epic_stories(argv[2])
    if cmd == "action-status" and len(argv) in (3, 4):
        return cmd_action_status(argv[2], argv[3] if len(argv) == 4 else None)
    sys.exit(__doc__)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
