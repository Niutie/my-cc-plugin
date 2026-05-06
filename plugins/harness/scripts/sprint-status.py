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

故意手写 yaml 解析（避免引入 PyYAML 依赖）。development_status 块下的所有
story 行格式都是 `  <key>: <value>`，结构稳定。
"""

from __future__ import annotations

import datetime
import os
import re
import sys
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
STORY_KEY_RE = re.compile(r"^\s+([A-Za-z0-9_\-]+):\s*(\S+)\s*(?:#.*)?$")


def _iter_dev_status(include_epic_keys: bool = False) -> list[tuple[int, str, str]]:
    """返回 [(line_index, key, status), ...]。默认仅 story；include_epic_keys=True 时含 epic-* 行。"""
    if not SPRINT_FILE.exists():
        sys.exit(f"missing {SPRINT_FILE} — 请先运行 /bmad-sprint-planning")
    lines = SPRINT_FILE.read_text(encoding="utf-8").splitlines()
    out: list[tuple[int, str, str]] = []
    in_block = False
    for i, line in enumerate(lines):
        stripped = line.rstrip()
        if stripped.startswith("development_status:"):
            in_block = True
            continue
        if not in_block:
            continue
        if stripped and not stripped.startswith((" ", "\t", "#")):
            break
        m = STORY_KEY_RE.match(stripped)
        if not m:
            continue
        key, status = m.group(1), m.group(2).strip().strip('"').strip("'")
        if key.startswith("epic-") and not include_epic_keys:
            continue
        out.append((i, key, status))
    return out


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
    for _, k, s in _iter_dev_status():
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
    # 注意 [ \t] 而不是 \s — \s 会吃掉行末 \n 导致下一行粘连
    m = re.match(r"^([ \t]+)(" + re.escape(key) + r"):[ \t]*\S+[ \t]*(\r?\n)?$", line)
    if not m:
        sys.exit(f"failed to rewrite line {idx}: {line!r}")
    text_lines[idx] = f"{m.group(1)}{m.group(2)}: {new_status}{m.group(3) or ''}"
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
    pending = [(k, s) for k, s in matched if s != "done"]
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
    sys.exit(__doc__)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
