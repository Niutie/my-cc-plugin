#!/usr/bin/env python3
"""superh — super-harness 并行调度 CLI（/super-harness:run 用）。

单条 story 的流水线写在 .claude/harness/pipeline.md：B0-B3 由 worker 在独立
worktree 里按 lane 模式执行，B4 及之后（build-sync / retro）由主 worktree
的调度者串行执行。本脚本负责调度层所有确定性的部分：就绪判定、worktree 准备、
worker 进程启动、合流（rebase + 账本冲突自动消解 + tag 搬迁 + 合流验证 + ff 合并）、看板。

状态存放在 `$(git rev-parse --git-common-dir)/super-harness/`，不进 git，所有
worktree 看到的是同一份。每个文件只有一个写入者：

    lanes/<KEY>.json         调度者（主 agent 经本脚本）写：phase / onto / notes /
                             op（正在运行的 prepare / integrate：pid + 启动时间 + 子进程组）
    lanes/<KEY>.proc.json    launch 进程写：pid / child_pid（各带启动时间）/ session_id / exit_code
    lanes/<KEY>.result.json  worker 写（经 `superh.py report`）：status / summary
    lanes/<KEY>.watch.json   watch 进程写：pid
    dispatcher.lock          start-run 写：持有调度权的会话（pid + 启动时间）

子命令（都在项目根目录或任一 worktree 内运行）：

    env                     打印路径与生效配置（JSON）
    doctor                  只读检查：copy_paths / link_paths 补进 lane 后 lane 是否干净
    plan [--json]           列出每条未完成 story 的就绪情况与等待原因
    tick                    调度者每轮循环读的结构化快照（JSON），含 next_action
    board [--json]          看板：先列需要人处理的 lane
    start-run               取调度锁，固定本次运行的 sprint 分支
    end-run                 释放调度锁
    prepare <KEY>           开 worktree + 分支，补齐未入库的基建文件，跑 prepare_command
    launch <KEY>            前台运行 worker（headless claude -p），退出时落盘；
                            调度者用 Bash run_in_background 调它
    watch <KEY>             launch 进程没了但 claude 还在跑时，阻塞到 claude 退出（后台运行）
    report <KEY> --status S worker 回报结果（ready / blocked / failed / quota）
    integrate <KEY>         rebase 到 sprint 分支 → 账本冲突自动消解 → 搬 tag →
                            worktree 内 build-verify → verify_command（rebase 过才跑）→
                            ff 合并进主 worktree
    postmerge <KEY>         只读：已合入的 lane 收口还差哪一步（NEXT=sync / tag / finish）
    mark <KEY> --phase P    调度者推进 phase（done / held）
    retry <KEY>             worker 失败后重新排队（保留 worktree，续作）
    cleanup <KEY>           done 之后删 worktree 与分支
    abandon <KEY> --yes     放弃本路：删 worktree / 分支 / 未 done 的 harness tag

退出码：0 成功；1 halt / 参数错误；3 integrate 遇到需要处理的代码冲突；
4 STATUS=busy（这一路的 prepare / integrate 还在运行）或 STATUS=locked（另一个
会话持有调度锁）；128+N 被信号 N 中断。

prepare / integrate 可能要跑很久（prepare_command、verify_command），调度者用
Bash 的后台模式运行它们。被外部杀掉也不会死循环：运行中的标记留在 lane 上，
下一次运行发现标记的进程已不在，就先结束它留下的子进程组，再续跑；连续被打断
超过 MAX_INTERRUPTS 次就把这一路挂起（held）。
"""

from __future__ import annotations

import sys

sys.dont_write_bytecode = True

import argparse  # noqa: E402
import datetime  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import re  # noqa: E402
import shutil  # noqa: E402
import signal  # noqa: E402
import subprocess  # noqa: E402
import tempfile  # noqa: E402
import time  # noqa: E402
from contextlib import contextmanager  # noqa: E402
from pathlib import Path  # noqa: E402

try:  # noqa: E402
    import fcntl
except ImportError:  # not on POSIX: the guard degrades to the O_EXCL-free check
    fcntl = None

TERMINAL_FALLBACK = ("done", "wont-do", "cancelled", "canceled")
CARRY_TAGS = ("built", "followup-start", "followup")
LEDGER_TAKE_OURS_RE = re.compile(r"^(sprint-status\.yaml|epic-\d+-context\.md)$")
LEDGER_UNION = ("deferred-work.md",)
PERSON_STAGES = ("conflict", "held", "blocked", "failed", "quota", "crashed")
# An integrate / prepare that was killed from outside (the session's Bash call hit
# its time limit, the session ended) is resumed this many times; one more kill
# holds the lane instead of looping tick → integrate → kill forever.
MAX_INTERRUPTS = 2
# integrate failures that are not caused by the lane (the sprint branch moved under
# it) are retried this many times in a row before the lane is held.
MAX_TRANSIENT = 3
EXIT_BUSY = 4   # STATUS=busy (this lane's prepare/integrate is already running) or STATUS=locked
# hold_kind values integrate sets; a lane held with one of these is accepted by a
# manual `integrate` re-run once the person has fixed the cause.
INTEGRATE_HOLD_KINDS = ("verify", "build-verify", "lane-dirty", "rebase", "branch-missing",
                        "worktree-missing", "interrupted", "ff", "retry-limit", "git-error", "error")
LOCK_FILE = "dispatcher.lock"

DEFAULT_CONFIG = {
    "max_slots": 2,
    "no_deps_policy": "serial",          # serial | epic-parallel
    "epic_barrier": True,                # false = 只按依赖调度，允许跨 epic 并行
    "retro_barrier": True,
    "worktree_root": "",                 # 空 = <repo 上级目录>/<repo 名>.worktrees
    "branch_prefix": "story/",
    "copy_paths": [".claude/harness", ".claude/skills", "_bmad",
                   ".claude/settings.local.json"],
    "link_paths": [],
    "prepare_command": "",
    "prepare_timeout_sec": 600,
    "verify_command": "",
    "verify_timeout_sec": 1800,
    "worker_permission_mode": "bypassPermissions",
    "worker_model": "",
    "claude_bin": "claude",
    "keep_worktrees": False,
    "deps_overrides": {},
}

# Env vars a parent Claude Code session leaks into child processes. A worker is
# an independent session; inheriting these would tie it to the dispatcher's
# session (messaging socket, session id) instead of starting a fresh one.
SCRUB_ENV_PREFIXES = ("CLAUDECODE", "CLAUDE_CODE_SESSION", "CLAUDE_CODE_MESSAGING",
                      "CLAUDE_CODE_CHILD", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_PID",
                      "CLAUDE_PLUGIN_")


# --------------------------------------------------------------------------- utils

def now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def git(args, cwd=None, env=None, check=False):
    r = subprocess.run(["git", *args], cwd=cwd, env=env, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f"STATUS=halt\nREASON=git {' '.join(args)} failed: {r.stderr.strip()}")
    return r


def die(reason: str, *extra: str, code: int = 1):
    print("STATUS=halt")
    print(f"REASON={reason}")
    for ln in extra:
        print(ln)
    sys.exit(code)


def read_json(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-", suffix=".json")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)


def pid_alive(pid) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


# ------------------------------------------------------------------ process identity
#
# A bare pid is not an identity: after a reboot or a long run the number can belong
# to an unrelated process. Every pid super-harness records is paired with the
# process start time, and "alive" means "alive AND started at the recorded time".

def proc_start_time(pid):
    """Opaque start-time token for pid, or None when it can't be determined."""
    if not isinstance(pid, int) or pid <= 0:
        return None
    try:
        with open(f"/proc/{pid}/stat", "rb") as f:
            data = f.read().decode("utf-8", "replace")
        # field 22 (starttime); fields after the ')' of comm start at field 3
        return "linux:" + data[data.rindex(")") + 2:].split()[19]
    except (OSError, ValueError, IndexError):
        pass
    try:
        r = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    s = " ".join(r.stdout.split())
    return f"ps:{s}" if r.returncode == 0 and s else None


def proc_cmdline(pid):
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
        if raw:
            return raw.replace(b"\0", b" ").decode("utf-8", "replace")
    except OSError:
        pass
    try:
        r = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None


def proc_matches(pid, start, hints=()) -> bool:
    """pid is alive and is the process that was recorded. Start time decides when
    both sides have one; otherwise (records from older versions, no ps) fall back
    to the command line containing one of `hints`."""
    if not pid_alive(pid):
        return False
    cur = proc_start_time(pid)
    if start and cur:
        return start == cur
    if not hints:
        return True
    cmd = proc_cmdline(pid)
    if cmd is None:
        return True
    return any(h and h in cmd for h in hints)


def op_record(name: str) -> dict:
    pid = os.getpid()
    return {"name": name, "pid": pid, "pid_start": proc_start_time(pid), "started_at": now_iso()}


def op_live(op) -> bool:
    return bool(op) and proc_matches(op.get("pid"), op.get("pid_start"), ("superh",))


class Interrupted(BaseException):
    """SIGTERM / SIGHUP / SIGINT while a child process group is running."""

    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


def _raise_interrupted(signum, _frame):
    raise Interrupted(signum)


def kill_group(pgid, leader_start=None, grace: float = 3.0) -> bool:
    """SIGTERM a process group, SIGKILL whatever is left after `grace` seconds.
    A live leader with a different start time means the number was reused: skip.
    (A pgid can't be handed out again while any member of the old group lives.)"""
    if not isinstance(pgid, int) or pgid <= 1:
        return False
    if leader_start and pid_alive(pgid):
        cur = proc_start_time(pgid)
        if cur and cur != leader_start:
            return False
    try:
        os.killpg(pgid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return False
    deadline = time.monotonic() + grace
    while time.monotonic() < deadline:
        try:
            os.killpg(pgid, 0)
        except (ProcessLookupError, PermissionError):
            return True
        time.sleep(0.1)
    try:
        os.killpg(pgid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    return True


def _terminate_group(p, grace: float = 3.0):
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        pass
    out = err = None
    try:
        out, err = p.communicate(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    if out is None:
        try:
            out, err = p.communicate(timeout=grace)
        except subprocess.TimeoutExpired:
            # something left the group and still holds the pipes: give up on output
            for s in (p.stdout, p.stderr):
                try:
                    s.close()
                except OSError:
                    pass
            p.wait()
    return out or "", err or ""


def run_group(argv, cwd, env=None, timeout=None, on_start=None) -> dict:
    """Run argv in its own session / process group. On timeout, or when this
    process is told to stop (SIGTERM/SIGHUP/SIGINT), the whole group is killed —
    subprocess.run(timeout=) would only kill `sh` and leave its children running.
    on_start(pid, start_time) runs right after spawn (to persist the pgid)."""
    old = {}
    for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        try:
            old[s] = signal.signal(s, _raise_interrupted)
        except (ValueError, OSError):
            pass
    p = None
    try:
        p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, errors="replace", start_new_session=True)
        if on_start:
            on_start(p.pid, proc_start_time(p.pid))
        try:
            out, err = p.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            out, err = _terminate_group(p)
            return {"rc": None, "out": out, "err": err, "timed_out": True}
        return {"rc": p.returncode, "out": out or "", "err": err or "", "timed_out": False}
    except BaseException:
        if p is not None:
            _terminate_group(p)
        raise
    finally:
        for s, h in old.items():
            signal.signal(s, h)


# ----------------------------------------------------------------------- locations

class Ctx:
    """Resolved paths + config. Works from the main worktree or any lane worktree."""

    def __init__(self):
        r = git(["rev-parse", "--path-format=absolute", "--git-common-dir"])
        if r.returncode != 0:
            die("不在 git 仓库内")
        self.common = Path(r.stdout.strip())
        if self.common.name != ".git":
            die(f"不支持的仓库布局（common dir = {self.common}，需要非 bare 仓库）")
        self.root = self.common.parent
        self.state = self.common / "super-harness"
        self.lanes = self.state / "lanes"
        self.logs = self.state / "logs"
        self.harness_dir = self.root / ".claude" / "harness"
        self.harness_scripts = self.harness_dir / "scripts"
        self.config_path = self.harness_dir / "parallel.yaml"
        # super-harness 0.1.0 kept its config at .claude/super-harness/config.yaml.
        # Falling back to defaults would silently drop deps_overrides and let
        # stories that must be serial run in parallel, so refuse instead.
        self.legacy_config = self.root / ".claude" / "super-harness" / "config.yaml"
        if not self.config_path.exists() and self.legacy_config.exists():
            die("发现 0.1.0 的并行配置 .claude/super-harness/config.yaml，但没有 .claude/harness/parallel.yaml",
                "先跑 /super-harness:update（会把旧配置原样搬到新位置），或手工把旧文件复制成 .claude/harness/parallel.yaml")
        self.config = load_config(self.config_path)
        slots = (read_json(self.state / "run.json") or {}).get("max_slots")
        if isinstance(slots, int) and slots > 0:
            self.config["max_slots"] = slots
        wt_root = str(self.config.get("worktree_root") or "").strip()
        if wt_root:
            p = Path(wt_root).expanduser()
            self.wt_root = p if p.is_absolute() else (self.root / p).resolve()
        else:
            self.wt_root = self.root.parent / f"{self.root.name}.worktrees"
        self._harness = None

    # harness libs (deployed copy in the main worktree)
    def harness(self):
        if self._harness is None:
            if not (self.harness_scripts / "harness_spec.py").exists():
                die("没找到 .claude/harness/scripts/harness_spec.py：请先跑 /super-harness:init")
            sys.path.insert(0, str(self.harness_scripts))
            import harness_config  # noqa: E402
            import harness_spec  # noqa: E402
            self._harness = (harness_config, harness_spec)
        return self._harness

    def artifacts_rel(self) -> str:
        hc, _ = self.harness()
        p = Path(hc.get_artifacts_root())
        try:
            return str(p.resolve().relative_to(self.root.resolve()))
        except ValueError:
            return "_bmad-output/implementation-artifacts"

    def sprint_file(self) -> Path:
        return self.root / self.artifacts_rel() / "sprint-status.yaml"

    def terminal(self):
        try:
            _, hs = self.harness()
            return tuple(hs.TERMINAL_STORY_STATUSES)
        except SystemExit:
            raise
        except Exception:
            return TERMINAL_FALLBACK

    def parked(self):
        """harness-project-config.yaml parked_statuses (issue #15)."""
        try:
            hc, _ = self.harness()
            return tuple(hc.get_parked_statuses())
        except SystemExit:
            raise
        except Exception:
            return ()

    def run_info(self) -> dict:
        return read_json(self.state / "run.json") or {}

    def sprint_branch(self) -> str:
        b = self.run_info().get("sprint_branch")
        if b:
            return b
        r = git(["symbolic-ref", "--short", "HEAD"], cwd=self.root)
        return r.stdout.strip()

    def lane_path(self, key, kind="") -> Path:
        return self.lanes / f"{key}{'.' + kind if kind else ''}.json"

    def lane(self, key):
        return read_json(self.lane_path(key))

    def save_lane(self, lane):
        lane["updated_at"] = now_iso()
        write_json(self.lane_path(lane["key"]), lane)

    def all_lanes(self):
        out = {}
        if self.lanes.is_dir():
            for p in sorted(self.lanes.glob("*.json")):
                if p.name.count(".") != 1:  # skip .proc.json / .result.json
                    continue
                d = read_json(p)
                if d and d.get("key"):
                    out[d["key"]] = d
        return out


# ------------------------------------------------------------------ dispatcher lock
#
# One dispatcher per repository. `start-run` takes the lock for the long-lived
# process driving the run: the Claude Code session (CLAUDE_PID, exported into its
# Bash tool), or outside Claude Code the terminal session leader. Mutating
# subcommands refuse to run while another live owner holds it; a lock whose owner
# is gone (or whose pid now belongs to another process) is stale and reclaimed.

def lock_owner() -> dict:
    pid = None
    try:
        pid = int(os.environ.get("CLAUDE_PID") or 0) or None
    except ValueError:
        pid = None
    kind = "claude"
    if not pid or not pid_alive(pid):
        pid, kind = os.getsid(0), "session"
    return {"pid": pid, "start": proc_start_time(pid), "kind": kind}


@contextmanager
def _lock_guard(ctx):
    """Serialises read-check-write of the lock file between superh processes."""
    ctx.state.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(ctx.state / ".lock.guard"), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        if fcntl is not None:
            fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def _lock_live(lk) -> bool:
    if not lk:
        return False
    return proc_matches(lk.get("pid"), lk.get("start"), ("claude",) if lk.get("kind") == "claude" else ())


def _same_owner(lk, me) -> bool:
    if not lk or lk.get("pid") != me["pid"]:
        return False
    return not (lk.get("start") and me["start"]) or lk["start"] == me["start"]


def _print_locked(lk, what: str):
    print("STATUS=locked")
    print(f"REASON=另一个调度会话正在驱动这个仓库（{lk.get('kind')} pid {lk.get('pid')}，"
          f"{lk.get('acquired_at', '?')} 起），{what}")
    print(f"LOCK_PID={lk.get('pid')}")
    print(f"LOCK_SINCE={lk.get('acquired_at', '')}")
    print("HINT=在那个会话里继续；确认它已经不再调度（例如卡住、要换会话接手）后，"
          "征得用户同意再执行 superh.py start-run --take-over")


def check_lock(ctx, what: str):
    lk = read_json(ctx.state / LOCK_FILE)
    if not lk or _same_owner(lk, lock_owner()) or not _lock_live(lk):
        return
    _print_locked(lk, what)
    sys.exit(EXIT_BUSY)


# -------------------------------------------------------------------------- config

_DQ_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "/": "/", " ": " ",
               "a": "\a", "b": "\b", "e": "\x1b", "f": "\f", "v": "\v"}


def _strip_comment(v: str) -> str:
    """Drop a trailing `# comment` (a `#` at the start or after whitespace),
    ignoring `#` inside quoted scalars. Quotes only open at the start of a token,
    so the apostrophe in a plain `it's` is just a character."""
    q = None
    i = 0
    while i < len(v):
        c = v[i]
        if q == "'":
            if c == "'":
                if v[i + 1:i + 2] == "'":
                    i += 2
                    continue
                q = None
        elif q == '"':
            if c == "\\":
                i += 2
                continue
            if c == '"':
                q = None
        elif c in ("'", '"') and (i == 0 or v[i - 1] in " \t[,"):
            q = c
        elif c == "#" and (i == 0 or v[i - 1] in " \t"):
            return v[:i].rstrip()
        i += 1
    return v.rstrip()


def _parse_quoted(v: str):
    """v starts with ' or ". Returns (value, rest-after-closing-quote), or None if
    the quote is never closed. Single quotes: '' is a literal '. Double quotes:
    the usual backslash escapes (\\n \\t \\" \\\\ \\xNN \\uNNNN ...)."""
    q = v[0]
    out = []
    i = 1
    while i < len(v):
        c = v[i]
        if q == "'":
            if c == "'":
                if v[i + 1:i + 2] == "'":
                    out.append("'")
                    i += 2
                    continue
                return "".join(out), v[i + 1:]
        else:
            if c == "\\" and i + 1 < len(v):
                n = v[i + 1]
                width = {"x": 2, "u": 4, "U": 8}.get(n)
                if width and re.fullmatch(r"[0-9A-Fa-f]{%d}" % width, v[i + 2:i + 2 + width]):
                    out.append(chr(int(v[i + 2:i + 2 + width], 16)))
                    i += 2 + width
                    continue
                out.append(_DQ_ESCAPES.get(n, "\\" + n))
                i += 2
                continue
            if c == '"':
                return "".join(out), v[i + 1:]
        out.append(c)
        i += 1
    return None


def _split_flow(inner: str) -> list:
    """Split a flow sequence body on commas that are not inside quotes."""
    parts, cur, q, i = [], [], None, 0
    while i < len(inner):
        c = inner[i]
        if q:
            cur.append(c)
            if q == "'" and c == "'" and inner[i + 1:i + 2] == "'":
                cur.append("'")
                i += 2
                continue
            if q == '"' and c == "\\" and i + 1 < len(inner):
                cur.append(inner[i + 1])
                i += 2
                continue
            if c == q:
                q = None
        elif c in ("'", '"') and not "".join(cur).strip():
            q = c
            cur.append(c)
        elif c == ",":
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(c)
        i += 1
    parts.append("".join(cur))
    return parts


def _cfg_scalar(v: str):
    v = _strip_comment(v.strip())
    if v[:1] in ("'", '"'):
        parsed = _parse_quoted(v)
        if parsed is not None and not parsed[1].strip():
            return parsed[0]
        # malformed quoting: keep it literal rather than guess, minus a comment
        m = re.search(r"\s+#", v)
        return v[: m.start()].rstrip() if m else v
    low = v.lower()
    if low in ("true", "yes"):
        return True
    if low in ("false", "no"):
        return False
    if low in ("", "~", "null"):
        return None
    if v.startswith("[") and v.endswith("]"):
        inner = v[1:-1].strip()
        return [] if not inner else [_cfg_scalar(x) for x in _split_flow(inner)]
    if v == "{}":
        return {}
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    return v


def parse_simple_yaml(text: str) -> dict:
    """Two levels: top-level scalars / lists / maps; map values may be scalars or lists.
    Keys may start with digits or CJK (story keys)."""
    out: dict = {}
    lines = text.splitlines()
    i = 0
    key_re = re.compile(r"^(\s*)([^\s:#][^:#]*?):(?:\s+(.*))?$")
    while i < len(lines):
        ln = lines[i]
        if not ln.strip() or ln.lstrip().startswith("#") or ln.startswith((" ", "\t")):
            i += 1
            continue
        m = key_re.match(ln)
        if not m:
            i += 1
            continue
        k, v = m.group(2).strip(), (m.group(3) or "").strip()
        if v and not v.startswith("#"):
            out[k] = _cfg_scalar(v)
            i += 1
            continue
        # nested block
        j = i + 1
        items: list = []
        sub: dict = {}
        cur_sub = None
        while j < len(lines):
            s = lines[j]
            if not s.strip() or s.lstrip().startswith("#"):
                j += 1
                continue
            if not s.startswith((" ", "\t")):
                break
            st = s.strip()
            if st.startswith("- "):
                val = _cfg_scalar(st[2:])
                if cur_sub is not None:
                    if not isinstance(sub.get(cur_sub), list):
                        sub[cur_sub] = []
                    sub[cur_sub].append(val)
                else:
                    items.append(val)
            else:
                mm = key_re.match(s)
                if mm:
                    sk, sv = mm.group(2).strip(), (mm.group(3) or "").strip()
                    if sv and not sv.startswith("#"):
                        sub[sk] = _cfg_scalar(sv)
                        cur_sub = None
                    else:
                        sub[sk] = []
                        cur_sub = sk
            j += 1
        out[k] = sub if sub else (items if items else None)
        i = j
    return out


def load_config(path: Path) -> dict:
    cfg = dict(DEFAULT_CONFIG)
    if path.exists():
        user = parse_simple_yaml(path.read_text(encoding="utf-8"))
        for k, v in user.items():
            if v is None:
                continue
            cfg[k] = v
    try:
        cfg["max_slots"] = max(1, int(cfg.get("max_slots") or 1))
    except (TypeError, ValueError):
        cfg["max_slots"] = 1
    if cfg.get("no_deps_policy") not in ("serial", "epic-parallel"):
        cfg["no_deps_policy"] = "serial"
    for k in ("copy_paths", "link_paths"):
        if not isinstance(cfg.get(k), list):
            cfg[k] = []
    if not isinstance(cfg.get("deps_overrides"), dict):
        cfg["deps_overrides"] = {}
    return cfg


# -------------------------------------------------------------------- sprint-status

ENTRY_FULL_RE = re.compile(r"^\s+([^\s:#]+):\s*(\S+)\s*(?:#.*)?$")
ENTRY_BLOCK_RE = re.compile(r"^(\s+)([^\s:#]+):\s*(?:#.*)?$")
NESTED_RE = re.compile(r"^\s+([A-Za-z_]+):\s*(.*?)\s*$")


def _clean_token(t: str) -> str:
    t = t.strip()
    m = re.search(r"\s+#", t)
    if m:
        t = t[: m.start()].strip()
    return t.strip("'\"")


def parse_sprint(path: Path):
    """Return (stories, epic_keys).

    stories: list of {key, status, deps} in file order; deps is None when the entry
    has no depends_on field (unknown), a list otherwise ([] = explicitly independent).
    epic_keys: {"epic-N": status, "epic-N-retrospective": status}.
    Mirrors sprint-status.py layout handling (single-line + block entries)."""
    if not path.exists():
        die(f"没找到 {path}：请先跑 bmad-sprint-planning")
    lines = path.read_text(encoding="utf-8").splitlines()
    entries = []
    in_block = False
    base = None
    cur = None
    dep_list_open = False
    for line in lines:
        s = line.rstrip()
        if s.startswith("development_status:"):
            in_block = True
            continue
        if not in_block:
            continue
        if s and not s.startswith((" ", "\t", "#")):
            break
        if not s or s.lstrip().startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if base is None:
            base = indent
        if indent <= base:
            dep_list_open = False
            cur = None
            m = ENTRY_FULL_RE.match(s)
            if m:
                entries.append({"key": m.group(1), "status": _clean_token(m.group(2)), "deps": None})
                continue
            m = ENTRY_BLOCK_RE.match(s)
            if m:
                cur = {"key": m.group(2), "status": None, "deps": None}
                entries.append(cur)
            continue
        if cur is None:
            continue
        st = s.strip()
        if dep_list_open and st.startswith("- "):
            cur["deps"].append(_clean_token(st[2:]))
            continue
        dep_list_open = False
        m = NESTED_RE.match(s)
        if not m:
            continue
        name, val = m.group(1), m.group(2)
        if name == "status":
            cur["status"] = _clean_token(val)
        elif name == "depends_on":
            v = _clean_token(val) if not val.strip().startswith("[") else val.strip()
            m2 = re.search(r"\s+#", v)
            if m2 and not v.startswith("["):
                v = v[: m2.start()]
            if v.startswith("["):
                inner = v[1:v.rfind("]")] if "]" in v else v[1:]
                cur["deps"] = [_clean_token(x) for x in inner.split(",") if _clean_token(x)]
            elif v in ("", None):
                cur["deps"] = []
                dep_list_open = True
            else:
                cur["deps"] = [_clean_token(v)]
    stories, epics = [], {}
    for e in entries:
        if e["status"] is None:
            continue
        if e["key"].startswith("epic-"):
            epics[e["key"]] = e["status"]
        else:
            stories.append(e)
    # Top-level story_dependencies (issue #14) wins over a block's depends_on:
    # BMad 6.12.4's own scripts cannot read the block layout, so projects on it keep
    # development_status single-line and put the dependencies there instead.
    for k, deps in _story_dependencies("\n".join(lines)).items():
        hit = [s for s in stories if s["key"] == k] or (
            [s for s in stories if s["key"] in resolve_dep(k, stories)] if not k.startswith("epic-") else [])
        if len(hit) == 1:
            hit[0]["deps"] = list(deps)
    return stories, epics


def _harness_spec_mod():
    here = str(Path(__file__).resolve().parent)
    if here not in sys.path:
        sys.path.insert(0, here)
    import harness_spec  # noqa: E402
    return harness_spec


def _story_dependencies(text: str) -> dict:
    try:
        return _harness_spec_mod().parse_story_dependencies(text)
    except (ImportError, AttributeError):
        return {}


def _is_external_dep(token) -> bool:
    try:
        return _harness_spec_mod().is_external_dep(token)
    except (ImportError, AttributeError):
        return str(token).startswith("ext-")


def epic_of(key: str):
    m = re.match(r"^(\d+)-", key)
    return int(m.group(1)) if m else None


def resolve_dep(token: str, stories) -> list:
    keys = [s["key"] for s in stories]
    if token in keys:
        return [token]
    m = re.fullmatch(r"epic-(\d+)", token)
    if m:
        n = int(m.group(1))
        return [k for k in keys if epic_of(k) == n]
    m = re.fullmatch(r"(\d+)[.\-](\d+[a-z]?)", token)
    if m:
        pre = f"{m.group(1)}-{m.group(2)}"
        return [k for k in keys if k == pre or k.startswith(pre + "-")]
    return []


# --------------------------------------------------------------------------- tags

def harness_tags(ctx) -> dict:
    """{key: set(tag suffixes)} for refs/tags/harness/<key>/<suffix>."""
    r = git(["tag", "-l", "harness/*"], cwd=ctx.root)
    out: dict = {}
    for t in r.stdout.splitlines():
        parts = t.strip().split("/")
        if len(parts) >= 3:
            out.setdefault("/".join(parts[1:-1]), set()).add(parts[-1])
    return out


# ----------------------------------------------------------------------- analysis

def lane_stage(ctx, lane) -> tuple[str, str]:
    """Derived stage of a lane — first matching rule wins (cf. superagent 003 stage table)."""
    key = lane["key"]
    phase = lane.get("phase")
    if phase in ("done", "abandoned"):
        return phase, ""
    op = lane.get("op")
    if op and op_live(op):
        if op.get("name") == "prepare":
            return "preparing", f"prepare 进行中（pid {op.get('pid')}，{op.get('started_at', '')} 起）"
        return "integrating", f"合流进行中（pid {op.get('pid')}，{op.get('started_at', '')} 起）"
    if phase == "conflict":
        wt = Path(lane.get("worktree", ""))
        if wt.is_dir() and not _conflicted(wt):
            # resolved by hand (with or without `rebase --continue`): integrate resumes it
            return "ready", "冲突已解决，待继续合流"
        files = ", ".join(lane.get("conflict_files", [])[:6])
        return "conflict", f"合流冲突：{files}"
    if phase == "held":
        return "held", lane.get("hold_reason", "")
    if phase in ("integrating", "merged"):
        return "integrating", "合流中" if phase == "integrating" else "已合入 sprint 分支，待 build-sync"
    if phase == "preparing":
        return "queued", "prepare 中断，待重做（prepare 会先清理现场）"
    proc = read_json(ctx.lane_path(key, "proc"))
    if phase == "prepared" or not proc or proc.get("attempt") != lane.get("attempts"):
        return "queued", "等待启动 worker"
    res = read_json(ctx.lane_path(key, "result"))
    if proc.get("exit_code") is None:
        if proc_matches(proc.get("pid"), proc.get("pid_start"), ("superh",)):
            return "working", f"worker 运行中（第 {proc.get('attempt')} 次）"
        if _worker_child_alive(ctx, proc):
            # the launcher died but claude is still working in the worktree:
            # reporting `crashed` here would get a second worker started next to it
            return "working", (f"worker 运行中（第 {proc.get('attempt')} 次；launch 进程已退出，"
                               f"claude 进程 {proc.get('child_pid')} 仍在运行）")
        if not res or res.get("attempt") != proc.get("attempt"):
            return "crashed", "worker 进程已消失但没有落盘退出码（宿主会话结束或被杀）"
        # the worker reported before it went away: its report stands
    if not res or res.get("attempt") != proc.get("attempt"):
        tail = (proc.get("result_text") or "").strip().splitlines()[-1:] or [""]
        bg = proc.get("bg_launches") or {}
        if bg:
            what = "、".join(w for k, w in (("agent", "子 agent"), ("bash", "命令")) if bg.get(k))
            return "failed", (f"worker 启动了后台{what}，没有回报就结束了本轮，claude -p 退出时后台任务被一起结束"
                              f"（exit={proc.get('exit_code')}）。worktree 里可能留有没提交的半成品，"
                              f"retry 会检查：{tail[0][:120]}")
        return "failed", f"worker 退出（exit={proc.get('exit_code')}）但没有回报：{tail[0][:160]}"
    st = res.get("status")
    if st == "ready":
        return "ready", res.get("summary", "")
    if st in ("blocked", "failed", "quota"):
        return st, res.get("summary", "")
    return "failed", f"未知回报状态 {st!r}"


def _worker_child_alive(ctx, proc) -> bool:
    hints = ("claude", Path(str(ctx.config.get("claude_bin") or "claude")).name)
    return proc_matches(proc.get("child_pid"), proc.get("child_start"), hints)


SH_CMD = "python3 .claude/harness/scripts/superh.py"
_REINTEGRATE = "，然后回主 worktree 跑 " + SH_CMD + " integrate {key}"
HOLD_HINTS = {
    "verify": "cd {wt}，修好 verify_command 报的问题并 commit" + _REINTEGRATE,
    "build-verify": ("cd {wt} && python3 .claude/harness/scripts/harness-commit.py build-verify {key}，"
                     "按输出修好并 commit" + _REINTEGRATE),
    "lane-dirty": "cd {wt} && git status，把多出来的文件提交、删掉或加进 .gitignore" + _REINTEGRATE,
    "rebase": ("cd {wt} && git status，rebase 卡住了：手工处理（解决后 git add，"
               "再 GIT_EDITOR=true git rebase --continue）" + _REINTEGRATE),
    "branch-missing": "lane 分支已不存在；确认这一路不要了就 " + SH_CMD + " abandon {key} --yes，story 会重新排队",
    "worktree-missing": "lane worktree 已不存在；确认这一路不要了就 " + SH_CMD + " abandon {key} --yes，story 会重新排队",
    "interrupted": ("integrate 运行中被打断了多次（会话结束或命令被杀）。确认 verify_command 能在 "
                    "verify_timeout_sec 内跑完" + _REINTEGRATE + "，会从断点继续"),
    "ff": "ff 合并失败，按 hold_reason 处理" + _REINTEGRATE,
    "retry-limit": "合流连续重试仍不成功，按 hold_reason 核对 sprint 分支和 lane 分支" + _REINTEGRATE,
    "git-error": "合流时 git 命令出错，按 hold_reason 处理" + _REINTEGRATE,
    "error": "合流时脚本出错，按 hold_reason 处理" + _REINTEGRATE,
    "prepare": ("prepare 没完成，按 hold_reason 修好原因后执行 " + SH_CMD +
                " abandon {key} --yes（会删这一路的 worktree 和分支），再重新执行 /super-harness:run"),
    "foreign": ("分支或目录不是这次 prepare 建的，super-harness 不会删它；确认无用后手工删掉，再执行 " + SH_CMD +
                " abandon {key} --yes（只改记录，不动分支和目录）"),
}


def resume_hint(ctx, lane) -> str:
    proc = read_json(ctx.lane_path(lane["key"], "proc")) or {}
    sid = proc.get("session_id")
    wt = lane.get("worktree", "")
    if lane.get("phase") == "held" and lane.get("hold_kind") in HOLD_HINTS:
        return HOLD_HINTS[lane["hold_kind"]].format(wt=wt, key=lane["key"])
    if sid:
        return f"cd {wt} && claude --resume {sid}"
    return f"cd {wt} && claude"


def analyze(ctx):
    stories, epics = parse_sprint(ctx.sprint_file())
    terminal = set(ctx.terminal())
    parked = set(ctx.parked())
    settled = terminal | parked     # not holding back the epic barrier / serial order / retro
    status = {s["key"]: s["status"] for s in stories}
    tags = harness_tags(ctx)
    lanes = ctx.all_lanes()
    cfg = ctx.config
    overrides = cfg.get("deps_overrides") or {}

    active_lane = {k for k, l in lanes.items() if l.get("phase") not in ("done", "abandoned")}
    inflight = set(active_lane)
    for k, t in tags.items():
        if "start" in t and "done" not in t and status.get(k) not in terminal:
            inflight.add(k)

    rows = []
    for idx, s in enumerate(stories):
        k, st = s["key"], s["status"]
        e = epic_of(k)
        row = {"key": k, "epic": e, "status": st, "deps": overrides.get(k, s["deps"]), "reasons": [],
               "external": []}
        if st in terminal:
            row["state"] = "done"
        elif k in inflight:
            row["state"] = "inflight"
            if k not in active_lane:
                row["reasons"].append("有 harness/<KEY>/start tag 但没有 lane（用 run-inline 跑过、未完成；用 /super-harness:run-inline --continue 收尾）")
        elif st in parked:
            row["state"] = "parked"
            row["reasons"].append(f"status={st}，挂起（parked_statuses），不派发，也不挡 epic 屏障和 retro")
        elif st != "backlog":
            row["state"] = "waiting"
            row["reasons"].append(f"status={st}，不是 backlog，super-harness 不接手")
        else:
            reasons = row["reasons"]
            if e is not None and cfg.get("epic_barrier", True):
                pend = sorted({epic_of(t["key"]) for t in stories
                               if epic_of(t["key"]) is not None and epic_of(t["key"]) < e
                               and t["status"] not in settled})
                for pe in pend:
                    reasons.append(f"epic {pe} 还有未完成的 story")
                if cfg.get("retro_barrier"):
                    for pe in sorted({epic_of(t["key"]) for t in stories
                                      if epic_of(t["key"]) is not None and epic_of(t["key"]) < e}):
                        rs = epics.get(f"epic-{pe}-retrospective")
                        if rs is not None and rs != "done" and pe not in pend:
                            reasons.append(f"epic {pe} 的 retro 还没 done")
            deps = row["deps"]
            if deps is None:
                if cfg.get("no_deps_policy") == "serial":
                    earlier = [t["key"] for t in stories[:idx] if t["status"] not in settled]
                    if earlier:
                        reasons.append(f"未声明 depends_on，按串行等待 {earlier[0]}")
            else:
                if isinstance(deps, str):
                    deps = [deps]
                for d in deps:
                    if _is_external_dep(d):
                        row["external"].append(str(d))
                        reasons.append(f"等待外部条件 {d}（满足后从依赖里删掉这一项）")
                        continue
                    ks = resolve_dep(str(d), stories)
                    if not ks:
                        reasons.append(f"depends_on 无法解析：{d}")
                    for dk in ks:
                        if dk != k and status.get(dk) not in terminal:
                            reasons.append(f"等待依赖 {dk}")
            row["state"] = "waiting" if reasons else "ready"
        rows.append(row)

    retro_due = []
    for e in sorted({r["epic"] for r in rows if r["epic"] is not None}):
        es = [r for r in rows if r["epic"] == e]
        # parked stories don't hold the retro back, but an epic with nothing
        # delivered (all parked / dropped) has nothing to look back on
        if all(r["state"] in ("done", "parked") for r in es) and any(r["status"] == "done" for r in es):
            rs = epics.get(f"epic-{e}-retrospective")
            if rs is not None and rs != "done":
                retro_due.append(e)
    return rows, lanes, retro_due, epics


# ---------------------------------------------------------------------- commands

def cmd_env(ctx, _a):
    print(json.dumps({
        "main_root": str(ctx.root), "state_dir": str(ctx.state), "worktree_root": str(ctx.wt_root),
        "sprint_branch": ctx.sprint_branch(), "config_file": str(ctx.config_path), "config": ctx.config,
    }, ensure_ascii=False, indent=2))
    return 0


def cmd_plan(ctx, a):
    rows, lanes, retro_due, _ = analyze(ctx)
    if a.json:
        print(json.dumps({"stories": rows, "retro_due": retro_due}, ensure_ascii=False, indent=2))
        return 0
    label = {"done": "完成", "inflight": "在飞", "ready": "就绪", "waiting": "等待", "parked": "挂起"}
    print(f"策略：max_slots={ctx.config['max_slots']} no_deps_policy={ctx.config['no_deps_policy']} "
          f"epic_barrier={ctx.config.get('epic_barrier', True)} retro_barrier={ctx.config['retro_barrier']}")
    for r in rows:
        if r["state"] == "done":
            continue
        deps = "-" if r["deps"] is None else (",".join(map(str, r["deps"])) or "[]")
        why = "；".join(r["reasons"])
        print(f"  {label[r['state']]:<3} {r['key']:<40} deps={deps}  {why}")
    if retro_due:
        print(f"  待跑 retro 的 epic：{', '.join(map(str, retro_due))}")
    return 0


def main_status(ctx):
    r = git(["status", "--porcelain", "-uall"], cwd=ctx.root)
    head = git(["symbolic-ref", "--short", "HEAD"], cwd=ctx.root).stdout.strip()
    return head, [ln for ln in r.stdout.splitlines() if ln.strip()]


def cmd_tick(ctx, _a):
    rows, lanes, retro_due, _ = analyze(ctx)
    sb = ctx.sprint_branch()
    head, dirty = main_status(ctx)
    stages = {k: lane_stage(ctx, l) for k, l in lanes.items()}
    running = [k for k, (s, _) in stages.items() if s == "working"]
    # a prepare / integrate process that is still alive (started in the background
    # by this or an earlier call) is never handed out again
    live_prepare = sorted(k for k, (s, _) in stages.items() if s == "preparing")
    live_integrate = sorted(k for k, l in lanes.items()
                            if (l.get("op") or {}).get("name") == "integrate" and op_live(l["op"]))
    reprepare = sorted(k for k, l in lanes.items() if l.get("phase") == "preparing" and k not in live_prepare)
    queued = [k for k, (s, _) in stages.items() if s == "queued" and k not in reprepare]
    # phase=integrating without a live integrate = the dispatcher stopped mid-merge;
    # route it back to integrate (the command is resumable) instead of losing it.
    integrate = sorted(
        [k for k, (s, _) in stages.items() if k not in live_integrate and k not in live_prepare
         and (s == "ready" or lanes[k].get("phase") == "integrating")],
        key=lambda k: (read_json(ctx.lane_path(k, "result")) or {}).get("reported_at", ""))
    orphaned = []
    for k in running:
        proc = read_json(ctx.lane_path(k, "proc")) or {}
        if proc.get("exit_code") is None and not proc_matches(proc.get("pid"), proc.get("pid_start"), ("superh",)):
            w = read_json(ctx.lane_path(k, "watch")) or {}
            if not (w.get("attempt") == proc.get("attempt") and proc_matches(w.get("pid"), w.get("pid_start"), ("superh",))):
                orphaned.append(k)
    merged = [k for k, l in lanes.items() if l.get("phase") == "merged"]
    attention = []
    for k, (s, d) in stages.items():
        if s in PERSON_STAGES:
            attention.append({"key": k, "stage": s, "detail": d, "worktree": lanes[k].get("worktree"),
                              "takeover": resume_hint(ctx, lanes[k])})
    quota_hold = any(a["stage"] == "quota" for a in attention)
    busy = len(running) + len(queued) + len(reprepare) + len(live_prepare)
    free = max(0, ctx.config["max_slots"] - busy)
    ready = [r["key"] for r in rows if r["state"] == "ready"]
    # an interrupted prepare already holds its slot; prepare rolls it back and redoes it
    launch = [] if quota_hold else reprepare + ready[:free]
    # a live integrate owns the main worktree until it exits: nothing else that
    # writes there (another integrate, close-out, retro) is handed out meanwhile
    main_busy = bool(live_integrate)
    started_epics = {epic_of(k) for k, t in harness_tags(ctx).items() if "start" in t}
    started_epics |= {r["epic"] for r in rows if r["state"] in ("done", "inflight")}
    epic_start = sorted({epic_of(k) for k in launch if epic_of(k) not in started_epics})
    pending = [r["key"] for r in rows if r["state"] not in ("done", "parked")]
    problems = []
    if head != sb:
        problems.append(f"主 worktree 当前分支是 {head!r}，不是 sprint 分支 {sb!r}")
    if merged and not main_busy:
        nxt = "post-merge"
    elif integrate and not main_busy:
        nxt = "integrate"
    elif retro_due and not main_busy:
        nxt = "retro"
    elif (launch or queued) and not quota_hold:
        nxt = "launch"
    elif running or live_prepare or live_integrate or merged or integrate or retro_due:
        nxt = "wait"
    elif not pending and not retro_due:
        nxt = "finished"
    else:
        nxt = "stalled"
    print(json.dumps({
        "next_action": nxt,
        "sprint_branch": sb,
        "main": {"branch": head, "clean": not dirty, "dirty": dirty[:20]},
        "slots": {"max": ctx.config["max_slots"], "busy": busy, "free": free},
        "post_merge": merged,
        "integrate": integrate,
        "launch": launch,
        "queued": queued if not quota_hold else [],
        "epic_start": epic_start,
        "retro_due": retro_due,
        "running": running,
        "preparing": live_prepare,
        "integrating": live_integrate,
        "orphaned": orphaned,
        "attention": attention,
        "quota_hold": quota_hold,
        "pending_count": len(pending),
        "waiting": [{"key": r["key"], "reasons": r["reasons"]} for r in rows if r["state"] == "waiting"][:20],
        "external": [{"key": r["key"], "conditions": r["external"]} for r in rows if r["external"]],
        "parked": [r["key"] for r in rows if r["state"] == "parked"],
        "problems": problems,
    }, ensure_ascii=False, indent=2))
    return 0


def cmd_board(ctx, a):
    rows, lanes, retro_due, _ = analyze(ctx)
    stages = {k: lane_stage(ctx, l) for k, l in lanes.items()}
    order = {s: i for i, s in enumerate(PERSON_STAGES + ("ready", "integrating", "working", "preparing", "queued", "done", "abandoned"))}
    items = sorted(stages.items(), key=lambda kv: (order.get(kv[1][0], 99), kv[0]))
    if a.json:
        print(json.dumps([{"key": k, "stage": s, "detail": d, "takeover": resume_hint(ctx, lanes[k])}
                          for k, (s, d) in items], ensure_ascii=False, indent=2))
        return 0
    zh = {"conflict": "合流冲突", "held": "已挂起", "blocked": "受阻", "failed": "失败", "quota": "配额耗尽",
          "crashed": "进程丢失", "ready": "待合流", "integrating": "合流中", "working": "执行中",
          "preparing": "准备中", "queued": "排队", "done": "完成", "abandoned": "已放弃"}
    person = [(k, s, d) for k, (s, d) in items if s in PERSON_STAGES]
    if person:
        print("需要你处理：")
        for k, s, d in person:
            print(f"  [{zh.get(s, s)}] {k}  {d}")
            print(f"      接手：{resume_hint(ctx, lanes[k])}")
    else:
        print("没有需要你处理的 lane。")
    live = [(k, s, d) for k, (s, d) in items if s in ("ready", "integrating", "working", "preparing", "queued")]
    if live:
        print("进行中：")
        for k, s, d in live:
            print(f"  [{zh.get(s, s)}] {k}  {d}")
    n_ready = sum(1 for r in rows if r["state"] == "ready")
    n_wait = sum(1 for r in rows if r["state"] == "waiting")
    n_done = sum(1 for r in rows if r["state"] == "done")
    n_parked = sum(1 for r in rows if r["state"] == "parked")
    print(f"story：完成 {n_done} / 就绪未启动 {n_ready} / 等待依赖 {n_wait} / 挂起 {n_parked}；slot {ctx.config['max_slots']}")
    ext = [r for r in rows if r["external"] and r["state"] == "waiting"]
    if ext:
        print("等待外部条件（满足后从依赖里删掉对应的 ext- 项）：")
        for r in ext:
            print(f"  {r['key']}  {', '.join(r['external'])}")
    if retro_due:
        print(f"待跑 retro：epic {', '.join(map(str, retro_due))}")
    return 0


# ----------------------------------------------------------------------- prepare

# Never copied into a lane: caches, and deploy/update backups under .claude/harness/.backup/.
def _skip_placed(rel: str) -> bool:
    name = rel.rsplit("/", 1)[-1]
    return name in ("__pycache__", ".DS_Store") or rel == ".claude/harness/.backup"


def _place(src: Path, dst: Path, link: bool, placed: list, rel: str):
    if _skip_placed(rel):
        return
    if link:
        if not os.path.lexists(dst):
            dst.parent.mkdir(parents=True, exist_ok=True)
            os.symlink(src, dst)
            placed.append(rel)
        return
    if src.is_dir() and not src.is_symlink():
        if not dst.exists():
            def _ignore(d, names, _base=src, _rel=rel):
                sub = os.path.relpath(d, _base)
                prefix = _rel if sub == "." else f"{_rel}/{sub}"
                return {n for n in names if _skip_placed(f"{prefix}/{n}")}
            shutil.copytree(src, dst, symlinks=True, ignore=_ignore)
            placed.append(rel)
            return
        for child in src.iterdir():
            _place(child, dst / child.name, False, placed, f"{rel}/{child.name}")
        return
    if not os.path.lexists(dst):
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst, follow_symlinks=False)
        placed.append(rel)


def _unignored_placed(wt: Path, placed: list) -> list:
    """Placed (untracked) paths that would dirty the lane worktree. bmad-build-auto
    refuses to start on a dirty tree, so these must be ignored by the project's
    .gitignore. super-harness never edits .git/info/exclude itself: it is shared by
    every worktree, so a rule added for a lane would also hide the user's files in
    the main worktree."""
    r = git(["status", "--porcelain", "-uall"], cwd=wt)
    untracked = [ln[3:] for ln in r.stdout.splitlines() if ln.startswith("?? ")]
    return sorted({p for p in placed if any(u == p or u.startswith(p + "/") for u in untracked)})


# Git tracking policy for .claude/harness/ (0.3.1+, written by
# scripts/ensure_gitignore.sh during init / update): deployed assets are ignored,
# the two user-edited configs are tracked.
HARNESS_DIR = ".claude/harness"
HARNESS_TRACKED_CONFIGS = (".claude/harness/harness-project-config.yaml", ".claude/harness/parallel.yaml")
HARNESS_GITIGNORE = ("/.claude/harness/*",) + tuple(f"!/{c}" for c in HARNESS_TRACKED_CONFIGS)


def _gitignore_hint(paths) -> list:
    # `/path` without a trailing slash matches files, directories and symlinks;
    # `path/` does not match a symlink (link_paths).
    # Under .claude/harness/ the policy applies instead of `/path`: the two configs
    # must be committed (COMMIT=), everything else is covered by the policy block.
    # A bare `/.claude/harness` would ignore the directory itself, and git cannot
    # re-include the configs inside an ignored directory.
    out = []
    for p in paths:
        p = p.rstrip("/")
        if p in HARNESS_TRACKED_CONFIGS:
            lines = [f"COMMIT={p}"]
        elif p == HARNESS_DIR or p.startswith(HARNESS_DIR + "/"):
            lines = [f"GITIGNORE={g}" for g in HARNESS_GITIGNORE]
        else:
            lines = [f"GITIGNORE=/{p}"]
        out += [ln for ln in lines if ln not in out]
    return out


def _hold(ctx, lane, kind: str, reason: str, *extra, code: int = 1):
    """Park a lane for a person: phase=held + hold_reason + hold_kind, then exit.
    tick shows held lanes under `attention` and never routes them anywhere, so a
    failure that a re-run can't fix doesn't turn into an endless retry loop."""
    lane["phase"] = "held"
    lane["hold_kind"] = kind
    lane["hold_reason"] = reason
    lane.pop("op", None)
    ctx.save_lane(lane)
    die(reason, f"HOLD_KIND={kind}", *extra, code=code)


def _record_child(ctx, lane):
    """on_start hook for run_group: persist the child's process group so a later
    run can kill it if this process is killed without cleaning up."""
    def rec(pid, start):
        op = lane.get("op")
        if op is not None:
            op["pgid"] = pid
            op["pgid_start"] = start
            ctx.save_lane(lane)
    return rec


def _run_op(ctx, lane, name: str, body):
    """Run body() with an in-progress marker (lane["op"]: pid + start time) on disk.
    The marker is cleared when body returns or exits through die()/sys.exit. If this
    process is killed (SIGKILL, or a signal that interrupted a child group) the
    marker stays, and the next run of the same command sees a dead marker: an
    unclean exit, which it counts (see MAX_INTERRUPTS)."""
    lane["op"] = op_record(name)
    ctx.save_lane(lane)
    clean = False
    try:
        rc = body()
        clean = True
        return rc
    except SystemExit:
        clean = True
        raise
    finally:
        if clean:
            cur = ctx.lane(lane["key"]) or lane
            if (cur.get("op") or {}).get("pid") == os.getpid():
                cur.pop("op", None)
            # an attempt that ended on its own resets the kill counter
            (cur.get("interrupted") or {}).pop(name, None)
            ctx.save_lane(cur)


def _reap_dead_op(lane):
    """Kill whatever the dead run's child process group left behind."""
    op = lane.pop("op", None) or {}
    if op.get("pgid"):
        kill_group(op["pgid"], op.get("pgid_start"))
    return op


def _rollback_interrupted_prepare(ctx, lane):
    """Undo a prepare that died mid-way (phase=preparing). No worker ever ran in it,
    so it is safe to drop — but only after proving that: the branch carries no
    commits beyond the recorded base and the story has no harness tags."""
    key, branch, wt = lane["key"], lane["branch"], Path(lane["worktree"])
    head = git(["rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"], cwd=ctx.root).stdout.strip()
    unsafe = []
    if head and head != lane.get("base"):
        unsafe.append(f"分支 {branch} 上有 base 之后的提交（{head[:12]}）")
    if harness_tags(ctx).get(key):
        unsafe.append(f"已有 harness/{key}/* tag")
    if unsafe:
        _hold(ctx, lane, "prepare", "prepare 中断，但现场不像未启动的 lane：" + "；".join(unsafe), f"WORKTREE={wt}")
    if wt.exists():
        r = git(["worktree", "remove", "--force", str(wt)], cwd=ctx.root)
        if r.returncode != 0 and wt.exists():
            # `git worktree add` itself may have been cut off: the directory is not
            # (fully) registered. Only ever delete the exact path this lane created.
            if wt.parent.resolve() == ctx.wt_root.resolve() and wt.name == key:
                shutil.rmtree(wt)
            else:
                _hold(ctx, lane, "prepare", f"无法清理中断的 prepare 目录 {wt}：{r.stderr.strip()}", f"WORKTREE={wt}")
    git(["worktree", "prune"], cwd=ctx.root)
    if head:
        git(["branch", "-D", branch], cwd=ctx.root)
    print(f"ROLLED_BACK=上次 prepare 中断（{lane.get('updated_at', '')}），已清理后重做")


def cmd_prepare(ctx, a):
    key = a.key
    lane = ctx.lane(key)
    interrupts = 0
    if lane and lane.get("phase") == "preparing":
        if op_live(lane.get("op")):
            # a prepare started earlier (e.g. in the background) is still running:
            # rolling it back would delete the worktree under its feet
            print("STATUS=busy")
            print(f"REASON=lane {key} 的 prepare 正在运行（pid {lane['op'].get('pid')}），不要重复启动，等它结束")
            return EXIT_BUSY
        _reap_dead_op(lane)
        interrupts = int((lane.get("interrupted") or {}).get("prepare", 0)) + 1
        if interrupts > MAX_INTERRUPTS:
            lane.setdefault("interrupted", {})["prepare"] = interrupts
            _hold(ctx, lane, "prepare",
                  f"prepare 连续 {interrupts} 次在运行中被打断（会话结束或命令被杀；prepare_command 太慢？），"
                  "不再自动重做", f"WORKTREE={lane.get('worktree')}")
        _rollback_interrupted_prepare(ctx, lane)
        lane = None
    if lane and lane.get("phase") not in ("abandoned", "done"):
        die(f"lane {key} 已存在（phase={lane.get('phase')}）", f"WORKTREE={lane.get('worktree')}")
    sb = ctx.sprint_branch()
    base = git(["rev-parse", "--verify", "--quiet", f"refs/heads/{sb}"], cwd=ctx.root).stdout.strip()
    if not base:
        die(f"sprint 分支 {sb!r} 不存在")
    branch = f"{ctx.config.get('branch_prefix') or 'story/'}{key}"
    wt = ctx.wt_root / key
    lane = {"key": key, "epic": epic_of(key), "branch": branch, "worktree": str(wt), "sprint_branch": sb,
            "base": base, "created_at": now_iso(), "phase": "preparing", "attempts": 0, "placed": [], "notes": []}
    if interrupts:
        lane["interrupted"] = {"prepare": interrupts}
    # Leftovers this prepare didn't create: hold the lane (so tick stops offering
    # the story every round) but mark it foreign, so abandon never deletes them.
    leftovers = []
    if git(["rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"], cwd=ctx.root).returncode == 0:
        leftovers.append(f"分支 {branch} 已存在")
    if os.path.lexists(wt):
        leftovers.append(f"目录 {wt} 已存在")
    if leftovers:
        lane["foreign"] = True
        _hold(ctx, lane, "foreign", "；".join(leftovers) + "：上一次的残留？确认无用后手工删掉，再 abandon --yes 重新排队",
              f"WORKTREE={wt}")
    return _run_op(ctx, lane, "prepare", lambda: _prepare_body(ctx, lane))


def _prepare_body(ctx, lane):
    key, branch, wt, base = lane["key"], lane["branch"], Path(lane["worktree"]), lane["base"]

    def fail(reason, *extra):
        _hold(ctx, lane, "prepare", f"prepare 失败：{reason}", *extra)

    # the lane (with its base) is on disk before `worktree add`, so an interruption
    # anywhere from here on is rolled back by the next prepare
    ctx.wt_root.mkdir(parents=True, exist_ok=True)
    r = git(["worktree", "add", "-b", branch, str(wt), base], cwd=ctx.root)
    if r.returncode != 0:
        fail(f"git worktree add 失败：{r.stderr.strip()}")
    placed: list = []
    for rel in ctx.config.get("copy_paths") or []:
        src = ctx.root / rel
        if src.exists():
            _place(src, wt / rel, False, placed, rel.rstrip("/"))
    for rel in ctx.config.get("link_paths") or []:
        src = ctx.root / rel
        if src.exists():
            _place(src, wt / rel, True, placed, rel.rstrip("/"))
    unignored = _unignored_placed(wt, placed)
    if unignored:
        fail("补进 lane 的未入库路径没有被 .gitignore 忽略，lane 会是脏的（bmad-build-auto 会拒绝启动）。"
             "把下面几行加进项目 .gitignore 并提交，然后 abandon --yes 再重新 prepare",
             *_gitignore_hint(unignored), f"WORKTREE={wt}")
    cmd = str(ctx.config.get("prepare_command") or "").strip()
    if cmd:
        env = dict(os.environ, SUPERH_KEY=key, SUPERH_WORKTREE=str(wt), SUPERH_MAIN_ROOT=str(ctx.root))
        timeout = int(ctx.config.get("prepare_timeout_sec") or 600)
        pr = run_group(["sh", "-c", cmd], cwd=wt, env=env, timeout=timeout, on_start=_record_child(ctx, lane))
        prep_out = (pr["out"] + pr["err"])[-4000:]
        if pr["timed_out"]:
            fail(f"prepare_command 超时（{timeout}s，它的整个进程组已结束）", f"WORKTREE={wt}", "OUTPUT<<", prep_out, ">>")
        if pr["rc"] != 0:
            fail(f"prepare_command 失败（exit={pr['rc']}）", f"WORKTREE={wt}", "OUTPUT<<", prep_out, ">>")
    dirty = [ln for ln in git(["status", "--porcelain", "-uall"], cwd=wt).stdout.splitlines() if ln.strip()]
    if dirty:
        fail("lane worktree 准备后不干净（bmad-build-auto 会拒绝启动）。把这些路径加进 .gitignore 或 prepare_command 里清掉",
             *[f"DIRTY={d}" for d in dirty[:30]], f"WORKTREE={wt}")
    lane["phase"] = "prepared"
    lane["placed"] = placed
    ctx.save_lane(lane)
    print("STATUS=ok")
    print(f"WORKTREE={wt}")
    print(f"BRANCH={branch}")
    print(f"BASE={base}")
    for p in placed:
        print(f"PLACED={p}")
    return 0


# ------------------------------------------------------------------------ launch

def render_worker_prompt(ctx, lane, attempt) -> str:
    tpl_path = ctx.harness_dir / "prompts" / "worker.md"
    if not tpl_path.exists():
        die(f"没找到 {tpl_path}：先跑 /super-harness:init")
    text = tpl_path.read_text(encoding="utf-8")
    subs = {
        "KEY": lane["key"], "WORKTREE": lane["worktree"], "BRANCH": lane["branch"],
        "SPRINT_BRANCH": lane["sprint_branch"], "ATTEMPT": str(attempt),
        "SUPERH": f"python3 {ctx.harness_scripts / 'superh.py'}", "MAIN_ROOT": str(ctx.root),
    }
    for k, v in subs.items():
        text = text.replace("{{" + k + "}}", v)
    return text


# Tool-result texts Claude Code returns when a call was started in the background
# instead of being waited on (issue #16). A headless `claude -p` exits as soon as
# the worker ends its turn, and takes those background tasks with it.
BG_LAUNCH_MARKERS = (("agent", "Async agent launched"), ("bash", "running in background with ID"))


def _bg_launch_kind(evt):
    """`agent` / `bash` when a stream event is the worker's own tool result for a
    call that went to the background, else None. Events from nested sub-agents
    carry a parent_tool_use_id and are ignored: only the worker's own turn ending
    kills the process."""
    if evt.get("type") != "user" or evt.get("parent_tool_use_id"):
        return None
    content = (evt.get("message") or {}).get("content")
    if not isinstance(content, list):
        return None
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "tool_result":
            continue
        body = block.get("content")
        if isinstance(body, list):
            body = " ".join(str(b.get("text", "")) for b in body if isinstance(b, dict))
        body = str(body or "")
        for kind, marker in BG_LAUNCH_MARKERS:
            if marker in body:
                return kind
    return None


def cmd_launch(ctx, a):
    key = a.key
    lane = ctx.lane(key)
    if not lane:
        die(f"lane {key} 不存在，先 prepare")
    if lane.get("phase") != "prepared":
        prev = read_json(ctx.lane_path(key, "proc"))
        # proc.json is written before the claude process is spawned, so a launched
        # lane without a proc record for its current attempt never started a worker.
        never_started = lane.get("phase") == "launched" and (
            not prev or prev.get("attempt") != lane.get("attempts"))
        if not never_started:
            die(f"lane {key} phase={lane.get('phase')}，只有 prepared 能 launch（失败重跑先 retry）")
        print("NOTE=上次 launch 在启动 worker 之前中断，重新启动")
    wt = Path(lane["worktree"])
    if not wt.is_dir():
        die(f"worktree {wt} 不存在")
    claude = shutil.which(str(ctx.config.get("claude_bin") or "claude"))
    if not claude:
        die("找不到 claude CLI（config.claude_bin）")
    attempt = int(lane.get("attempts") or 0) + 1
    prompt = render_worker_prompt(ctx, lane, attempt)
    ctx.logs.mkdir(parents=True, exist_ok=True)
    stem = ctx.logs / f"{key}.attempt-{attempt}"
    Path(f"{stem}.prompt.md").write_text(prompt, encoding="utf-8")
    lane["attempts"] = attempt
    lane["phase"] = "launched"
    ctx.save_lane(lane)
    proc_rec = {"key": key, "attempt": attempt, "pid": os.getpid(), "pid_start": proc_start_time(os.getpid()),
                "started_at": now_iso(), "session_id": None, "exit_code": None, "log": f"{stem}.stream.jsonl"}
    write_json(ctx.lane_path(key, "proc"), proc_rec)

    env = {k: v for k, v in os.environ.items() if not k.startswith(SCRUB_ENV_PREFIXES)}
    env.update(SUPERH_KEY=key, SUPERH_ATTEMPT=str(attempt), SUPERH_WORKTREE=str(wt),
               SUPERH_MAIN_ROOT=str(ctx.root))
    cmd = [claude, "-p", "--output-format", "stream-json", "--verbose",
           "--permission-mode", str(ctx.config.get("worker_permission_mode") or "default")]
    if ctx.config.get("worker_model"):
        cmd += ["--model", str(ctx.config["worker_model"])]
    result_evt = None
    with open(f"{stem}.prompt.md", "rb") as fin, open(f"{stem}.stream.jsonl", "w", encoding="utf-8") as flog, \
            open(f"{stem}.stderr.log", "w", encoding="utf-8") as ferr:
        p = subprocess.Popen(cmd, cwd=wt, env=env, stdin=fin, stdout=subprocess.PIPE, stderr=ferr, text=True)
        proc_rec["child_pid"] = p.pid
        proc_rec["child_start"] = proc_start_time(p.pid)
        write_json(ctx.lane_path(key, "proc"), proc_rec)
        for line in p.stdout:
            flog.write(line)
            flog.flush()
            try:
                evt = json.loads(line)
            except ValueError:
                continue
            if not isinstance(evt, dict):
                continue
            if evt.get("session_id") and not proc_rec.get("session_id"):
                proc_rec["session_id"] = evt["session_id"]
                write_json(ctx.lane_path(key, "proc"), proc_rec)
            if evt.get("type") == "result":
                result_evt = evt
            kind = _bg_launch_kind(evt)
            if kind:
                bg = proc_rec.setdefault("bg_launches", {})
                bg[kind] = bg.get(kind, 0) + 1
                write_json(ctx.lane_path(key, "proc"), proc_rec)
        rc = p.wait()
    proc_rec["exit_code"] = rc
    proc_rec["ended_at"] = now_iso()
    if result_evt:
        proc_rec["result_text"] = str(result_evt.get("result") or "")[-3000:]
        proc_rec["is_error"] = bool(result_evt.get("is_error"))
        proc_rec["cost_usd"] = result_evt.get("total_cost_usd")
        proc_rec["num_turns"] = result_evt.get("num_turns")
    write_json(ctx.lane_path(key, "proc"), proc_rec)
    stage, detail = lane_stage(ctx, ctx.lane(key))
    print(f"LANE={key}")
    print(f"EXIT_CODE={rc}")
    print(f"STAGE={stage}")
    print(f"DETAIL={detail}")
    print(f"SESSION={proc_rec.get('session_id')}")
    return 0


def cmd_watch(ctx, a):
    """Block until an orphaned worker (launch process gone, claude still running)
    exits, so the dispatcher, which runs this in the background, gets woken up.
    Returns at once when there is nothing to watch."""
    key = a.key
    proc = read_json(ctx.lane_path(key, "proc")) or {}
    if not proc or proc.get("exit_code") is not None:
        print("STATUS=ok")
        print("REASON=没有在跑的 worker")
        return 0
    write_json(ctx.lane_path(key, "watch"), {"key": key, "attempt": proc.get("attempt"), "pid": os.getpid(),
                                             "pid_start": proc_start_time(os.getpid()), "started_at": now_iso()})
    interval = max(0.2, float(a.interval))
    while (proc_matches(proc.get("pid"), proc.get("pid_start"), ("superh",))
           or _worker_child_alive(ctx, proc)):
        time.sleep(interval)
        cur = read_json(ctx.lane_path(key, "proc")) or {}
        if cur.get("attempt") != proc.get("attempt") or cur.get("exit_code") is not None:
            break
    stage, detail = lane_stage(ctx, ctx.lane(key) or {"key": key})
    print("STATUS=ok")
    print(f"LANE={key}")
    print(f"STAGE={stage}")
    print(f"DETAIL={detail}")
    return 0


def cmd_report(ctx, a):
    key = a.key
    lane = ctx.lane(key)
    if not lane:
        die(f"lane {key} 不存在")
    attempt = int(os.environ.get("SUPERH_ATTEMPT") or lane.get("attempts") or 0)
    halt = a.halt or ""
    if a.halt_file:
        try:
            halt = Path(a.halt_file).read_text(encoding="utf-8")
        except OSError as e:
            halt = f"(读 halt 文件失败：{e})"
    wt = Path(lane["worktree"])
    head = git(["rev-parse", "HEAD"], cwd=wt).stdout.strip() if wt.is_dir() else ""
    res = {"key": key, "attempt": attempt, "status": a.status, "summary": a.summary or "",
           "codex_skip_reason": a.codex_skip_reason or "", "followup_note": a.followup_note or "",
           "halt": halt[-8000:], "head": head, "reported_at": now_iso()}
    write_json(ctx.lane_path(key, "result"), res)
    print("STATUS=ok")
    return 0


# --------------------------------------------------------------------- integrate

def _rebase_in_progress(wt: Path) -> bool:
    for name in ("rebase-merge", "rebase-apply"):
        p = git(["rev-parse", "--git-path", name], cwd=wt).stdout.strip()
        if p and (wt / p if not os.path.isabs(p) else Path(p)).exists():
            return True
    return False


def _conflicted(wt: Path) -> list:
    r = git(["diff", "--name-only", "--diff-filter=U", "-z"], cwd=wt)
    return [p for p in r.stdout.split("\0") if p]


def _stage_blob(wt: Path, n: int, path: str):
    r = subprocess.run(["git", "show", f":{n}:{path}"], cwd=wt, capture_output=True)
    return r.stdout if r.returncode == 0 else None


def _auto_resolve(ctx, wt: Path, artifacts_rel: str):
    """Resolve conflicts in the shared ledgers. During a rebase, stage 2 ('ours') is
    the sprint branch being rebased onto, stage 3 ('theirs') the story's commit.
      sprint-status.yaml / epic-N-context.md → sprint 分支版本（build-sync 会把本 story 的状态写回）
      deferred-work.md                        → 三方 union 合并（追加型账本）
    Returns (resolved, remaining)."""
    resolved, remaining = [], []
    prefix = artifacts_rel.rstrip("/") + "/"
    for f in _conflicted(wt):
        inside = f.startswith(prefix) and "/" not in f[len(prefix):]
        name = os.path.basename(f)
        if inside and LEDGER_TAKE_OURS_RE.match(name):
            if _stage_blob(wt, 2, f) is not None:
                git(["checkout", "--ours", "--", f], cwd=wt)
                git(["add", "--", f], cwd=wt)
            else:
                git(["rm", "-q", "-f", "--", f], cwd=wt)
            resolved.append(f"{f} (取 sprint 分支版本)")
        elif inside and name in LEDGER_UNION:
            base = _stage_blob(wt, 1, f) or b""
            ours = _stage_blob(wt, 2, f) or b""
            theirs = _stage_blob(wt, 3, f) or b""
            with tempfile.TemporaryDirectory() as td:
                paths = []
                for nm, data in (("ours", ours), ("base", base), ("theirs", theirs)):
                    p = Path(td) / nm
                    p.write_bytes(data)
                    paths.append(str(p))
                mr = subprocess.run(["git", "merge-file", "-p", "--union", *paths], capture_output=True)
            (wt / f).write_bytes(mr.stdout)
            git(["add", "--", f], cwd=wt)
            resolved.append(f"{f} (union 合并)")
        else:
            remaining.append(f)
    return resolved, remaining


def _git_env():
    env = dict(os.environ, GIT_EDITOR="true", GIT_SEQUENCE_EDITOR="true")
    return env


def _drive_rebase(ctx, wt: Path, lane) -> list:
    """Advance an in-progress rebase as far as ledger auto-resolution allows.
    Returns the remaining (code) conflict files; [] means the rebase finished."""
    artifacts_rel = ctx.artifacts_rel()
    for _ in range(500):
        if not _rebase_in_progress(wt):
            return []
        resolved, remaining = _auto_resolve(ctx, wt, artifacts_rel)
        if resolved:
            lane.setdefault("notes", []).extend(f"auto-resolved: {r}" for r in resolved)
        if remaining:
            return remaining
        r = git(["-c", "core.hooksPath=/dev/null", "rebase", "--continue"], cwd=wt, env=_git_env())
        if r.returncode != 0 and not _conflicted(wt) and _rebase_in_progress(wt):
            # nothing left to commit for this pick (the ledger resolution emptied it)
            if git(["diff", "--cached", "--quiet"], cwd=wt).returncode == 0:
                git(["-c", "core.hooksPath=/dev/null", "rebase", "--skip"], cwd=wt, env=_git_env())
            else:
                _hold(ctx, lane, "rebase", f"rebase --continue 失败：{r.stderr.strip()[:300]}",
                      f"WORKTREE={wt}", f"STDERR={r.stderr.strip()[:500]}")
    _hold(ctx, lane, "rebase", "rebase 推进次数超限（500 步仍未结束）", f"WORKTREE={wt}")
    return []


def _is_ancestor(ctx, a, b) -> bool:
    return git(["merge-base", "--is-ancestor", a, b], cwd=ctx.root).returncode == 0


def _emit_conflict(ctx, lane, wt, remaining) -> int:
    lane["phase"] = "conflict"
    lane["conflict_files"] = remaining
    ctx.save_lane(lane)
    print("STATUS=conflict")
    print(f"WORKTREE={wt}")
    for f in remaining:
        print(f"CONFLICT_FILE={f}")
    return 3


def _build_verify(ctx, lane, wt: Path):
    bv = run_group(["python3", ".claude/harness/scripts/harness-commit.py", "build-verify", lane["key"]],
                   cwd=wt, on_start=_record_child(ctx, lane))
    return bv["rc"], (bv["out"] + bv["err"]).strip()


def _run_verify(ctx, lane, wt: Path) -> dict:
    """Run parallel.yaml `verify_command` in the lane worktree, whose tree now
    equals the sprint branch after the ff. Lanes that were not rebased keep the
    tree B1 already verified, so they are skipped."""
    cmd = str(ctx.config.get("verify_command") or "").strip()
    if not cmd:
        return {"status": "skipped-unset"}
    if not lane.get("rebased"):
        return {"status": "skipped-not-rebased"}
    env = dict(os.environ, SUPERH_KEY=lane["key"], SUPERH_WORKTREE=str(wt), SUPERH_MAIN_ROOT=str(ctx.root))
    timeout = int(ctx.config.get("verify_timeout_sec") or 1800)
    pr = run_group(["sh", "-c", cmd], cwd=wt, env=env, timeout=timeout, on_start=_record_child(ctx, lane))
    out = (pr["out"] + pr["err"])[-4000:]
    if pr["timed_out"]:
        return {"status": "failed", "detail": f"verify_command 超时（{timeout}s，它的整个进程组已结束）", "output": out}
    if pr["rc"] != 0:
        return {"status": "failed", "detail": f"verify_command exit={pr['rc']}", "output": out}
    return {"status": "passed"}


def _print_merged(ctx, lane, bv_out, recovered=False, verify=""):
    key = lane["key"]
    res = read_json(ctx.lane_path(key, "result")) or {}
    start = git(["rev-parse", "--verify", "--quiet", f"refs/tags/harness/{key}/start^{{commit}}"],
                cwd=ctx.root).stdout.strip()
    print("STATUS=ok")
    if recovered:
        print("RECOVERED=already-merged（上次合流已 ff 进 sprint 分支，但没来得及记录；本次只补记状态，不动 tag）")
    if verify:
        print(f"VERIFY={verify}")
    print(f"MERGED_HEAD={lane['merged_head']}")
    print(f"START={start}")
    print(f"CODEX_SKIP_REASON={res.get('codex_skip_reason', '')}")
    print(f"FOLLOWUP_NOTE={res.get('followup_note', '')}")
    for n in lane.get("notes", []):
        if n.startswith("auto-resolved"):
            print(f"NOTE={n}")
    print("BUILD_VERIFY<<")
    print(bv_out)
    print(">>")


def cmd_integrate(ctx, a):
    """Rebase the lane onto the sprint branch, carry the harness tags, re-verify, ff-merge.

    Every step is resumable, and everything a later step depends on is persisted
    before the step that could be interrupted:
      - `onto` (the story's new base) and phase=integrating are saved before any tag
        moves or the ff, so a re-run never has to guess the base from the current
        sprint HEAD (which, after a completed ff, is the story's own last commit);
      - `harness/<KEY>/start` only moves when a rebase actually rewrote the lane;
      - a lane whose head is already contained in the sprint branch was ff-merged by
        an earlier run that died before recording it: only the state is recorded.

    A lane that integrate itself held (hold_kind in INTEGRATE_HOLD_KINDS) is
    accepted again: the person fixes the cause and re-runs integrate by hand.

    Failure handling: a problem with the main worktree (wrong branch, dirty) halts
    the whole run and leaves the lane as it is. Every other failure either holds
    the lane (HOLD_KIND=...) or, when the sprint branch moved underneath, is
    retryable (RETRYABLE=yes) at most MAX_TRANSIENT times in a row. The run is
    wrapped in an in-progress marker so a run killed from outside is detected and
    resumed at most MAX_INTERRUPTS times."""
    key = a.key
    lane = ctx.lane(key)
    if not lane:
        die(f"lane {key} 不存在")
    op = lane.get("op") or {}
    if op_live(op):
        print("STATUS=busy")
        print(f"REASON=lane {key} 的 {op.get('name')} 正在运行（pid {op.get('pid')}），不要重复启动，等它结束")
        return EXIT_BUSY
    held_by_integrate = lane.get("phase") == "held" and lane.get("hold_kind") in INTEGRATE_HOLD_KINDS
    if op:
        _reap_dead_op(lane)
        if held_by_integrate:
            ctx.save_lane(lane)
        else:
            n = int((lane.get("interrupted") or {}).get("integrate", 0)) + 1
            lane.setdefault("interrupted", {})["integrate"] = n
            if n > MAX_INTERRUPTS:
                _hold(ctx, lane, "interrupted",
                      f"integrate 连续 {n} 次在运行中被打断（会话结束，或命令在前台跑超过了 Bash 的时限；"
                      f"verify_command 太慢？），不再自动重跑；sprint 分支未改动",
                      f"WORKTREE={lane.get('worktree')}")
            ctx.save_lane(lane)
            print(f"NOTE=上次 integrate 在运行中被打断（第 {n} 次），从断点继续")
    stage, _ = lane_stage(ctx, lane)
    if lane.get("phase") not in ("integrating", "conflict") and stage != "ready" and not held_by_integrate:
        die(f"lane {key} 当前阶段 {stage}，只有 worker 回报 ready 的 lane 能合流")
    sb = lane["sprint_branch"]
    head, dirty = main_status(ctx)
    if head != sb:
        die(f"主 worktree 不在 sprint 分支（当前 {head!r}，应为 {sb!r}）")
    if dirty:
        die("主 worktree 不干净，合流前先处理", *[f"DIRTY={d}" for d in dirty[:20]])
    if held_by_integrate:
        # a person re-runs it after fixing the cause: start counting afresh
        lane.pop("interrupted", None)
        lane.pop("retries", None)

    def body():
        try:
            return _integrate(ctx, lane)
        except SystemExit as e:
            if isinstance(e.code, str):  # git(check=True) failed: its text never reached stdout
                _hold(ctx, lane, "git-error", e.code.replace("STATUS=halt\nREASON=", "").strip()[:500],
                      f"WORKTREE={lane.get('worktree')}")
            raise
        except Exception as e:  # noqa: BLE001 — anything unexpected parks the lane, never loops
            _hold(ctx, lane, "error", f"integrate 内部错误：{e!r}"[:500], f"WORKTREE={lane.get('worktree')}")

    return _run_op(ctx, lane, "integrate", body)


def _transient(ctx, lane, reason: str):
    """A failure caused by the sprint branch moving under the merge: a re-run
    re-bases and normally succeeds. Repeated in a row, it is not transient."""
    n = int(lane.get("retries") or 0) + 1
    lane["retries"] = n
    if n >= MAX_TRANSIENT:
        lane.pop("retries", None)
        _hold(ctx, lane, "retry-limit", f"{reason}（连续 {n} 次）", f"WORKTREE={lane.get('worktree')}")
    lane["phase"] = "integrating"
    ctx.save_lane(lane)
    die(reason, "RETRYABLE=yes")


def _integrate(ctx, lane):
    key = lane["key"]
    sb = lane["sprint_branch"]
    wt = Path(lane["worktree"])
    branch = lane["branch"]
    if not git(["rev-parse", "--verify", "--quiet", f"refs/heads/{branch}"], cwd=ctx.root).stdout.strip():
        _hold(ctx, lane, "branch-missing", f"lane 分支 {branch} 不存在", f"WORKTREE={wt}")
    if not wt.is_dir():
        _hold(ctx, lane, "worktree-missing", f"lane worktree {wt} 不存在")
    lane_head = git(["rev-parse", branch], cwd=ctx.root, check=True).stdout.strip()
    sprint_head = git(["rev-parse", sb], cwd=ctx.root, check=True).stdout.strip()

    # Recovery: already fast-forwarded by an earlier run. The lane must carry its
    # own commits; an empty lane falls through and build-verify rejects it.
    own_commits = lane_head not in (lane.get("base"), lane.get("onto"))
    if own_commits and not _rebase_in_progress(wt) and _is_ancestor(ctx, lane_head, sprint_head):
        rc, bv_out = _build_verify(ctx, lane, wt)
        lane["phase"] = "merged"
        lane["merged_head"] = lane_head
        lane["merged_at"] = now_iso()
        lane["conflict_files"] = []
        lane.setdefault("notes", []).append("integrate recovered an already-merged lane")
        lane.pop("retries", None)
        lane.pop("hold_kind", None)
        lane.pop("hold_reason", None)
        ctx.save_lane(lane)
        if rc != 0:
            print("WARN=补记时 build-verify 未通过；代码已在 sprint 分支上，请人工核对 BUILD_VERIFY 段")
        _print_merged(ctx, lane, bv_out, recovered=True)
        return 0

    if _rebase_in_progress(wt):
        remaining = _drive_rebase(ctx, wt, lane)
        if remaining:
            return _emit_conflict(ctx, lane, wt, remaining)
    else:
        wd = [ln for ln in git(["status", "--porcelain", "-uall"], cwd=wt).stdout.splitlines() if ln.strip()]
        if wd:
            _hold(ctx, lane, "lane-dirty", "lane worktree 不干净（有未提交或未跟踪的文件），sprint 分支未改动",
                  f"WORKTREE={wt}", *[f"DIRTY={d}" for d in wd[:20]])
        if not _is_ancestor(ctx, sprint_head, branch):
            lane["phase"] = "integrating"
            lane["onto"] = sprint_head
            lane["rebased"] = True
            tags = harness_tags(ctx).get(key, set())
            temps = []
            for t in CARRY_TAGS:
                if t not in tags:
                    continue
                sha = git(["rev-parse", f"refs/tags/harness/{key}/{t}^{{commit}}"], cwd=ctx.root).stdout.strip()
                if _is_ancestor(ctx, sha, sprint_head):
                    continue  # already on the sprint branch, nothing to carry
                tb = f"super-harness-tmp/{key}/{t}"
                git(["branch", "-f", tb, sha], cwd=ctx.root, check=True)
                temps.append([t, tb])
            lane["carry"] = temps
            ctx.save_lane(lane)
            rb = git(["-c", "core.hooksPath=/dev/null", "rebase", "--update-refs", sprint_head],
                     cwd=wt, env=_git_env())
            if rb.returncode != 0 and not _rebase_in_progress(wt):
                for _t, tb in temps:
                    git(["branch", "-D", tb], cwd=ctx.root)
                lane["carry"] = []
                _hold(ctx, lane, "rebase", f"git rebase 没能启动：{(rb.stderr or rb.stdout).strip()[:300]}",
                      f"WORKTREE={wt}")
            remaining = _drive_rebase(ctx, wt, lane)
            if remaining:
                return _emit_conflict(ctx, lane, wt, remaining)
        else:
            # Already based on the sprint head: no rewrite, so the base is the
            # merge-base — recorded once and never recomputed on a re-run.
            if not lane.get("onto"):
                lane["onto"] = git(["merge-base", sprint_head, branch], cwd=ctx.root, check=True).stdout.strip()
                lane["rebased"] = False
            lane["phase"] = "integrating"
            ctx.save_lane(lane)

    # finalize
    sprint_head = git(["rev-parse", sb], cwd=ctx.root, check=True).stdout.strip()
    if not _is_ancestor(ctx, sprint_head, branch):
        _transient(ctx, lane, "rebase 结束后分支仍未基于 sprint 分支最新提交（sprint 分支在合流期间被改动？）重跑 integrate")
    onto = lane["onto"]
    for t, tb in lane.get("carry", []):
        sha = git(["rev-parse", "--verify", "--quiet", f"refs/heads/{tb}"], cwd=ctx.root).stdout.strip()
        if sha:
            git(["tag", "-f", f"harness/{key}/{t}", sha], cwd=ctx.root, check=True)
            git(["branch", "-D", tb], cwd=ctx.root)
    lane["carry"] = []
    if lane.get("rebased") and _is_ancestor(ctx, onto, branch) and \
            git(["rev-parse", branch], cwd=ctx.root).stdout.strip() != onto:
        git(["tag", "-f", f"harness/{key}/start", onto], cwd=ctx.root, check=True)
    lane["conflict_files"] = []
    lane["phase"] = "integrating"
    ctx.save_lane(lane)

    rc, bv_out = _build_verify(ctx, lane, wt)
    if rc != 0:
        lane["phase"] = "held"
        lane["hold_reason"] = "合流 rebase 后 build-verify 不通过"
        lane["hold_kind"] = "build-verify"
        ctx.save_lane(lane)
        print("STATUS=halt")
        print("REASON=rebase 后在 lane worktree 内重跑 build-verify 不通过；sprint 分支未改动")
        print("HOLD_KIND=build-verify")
        print(f"WORKTREE={wt}")
        print("BUILD_VERIFY<<")
        print(bv_out)
        print(">>")
        return 1
    verify = _run_verify(ctx, lane, wt)
    if verify["status"] == "failed":
        lane["phase"] = "held"
        lane["hold_kind"] = "verify"
        lane["hold_reason"] = f"合流后验证不通过（{verify['detail']}）"
        ctx.save_lane(lane)
        print("STATUS=halt")
        print(f"REASON={lane['hold_reason']}；sprint 分支未改动")
        print("HOLD_KIND=verify")
        print("VERIFY=failed")
        print(f"WORKTREE={wt}")
        print(f"HINT=在 lane worktree 里修好并 commit，然后重跑 superh.py integrate {key}")
        print("VERIFY_OUTPUT<<")
        print(verify["output"])
        print(">>")
        return 1
    lane.pop("hold_kind", None)
    lane.pop("hold_reason", None)
    mr = git(["merge", "--ff-only", branch], cwd=ctx.root)
    if mr.returncode != 0:
        # integrating stays routable: the next tick sends it back here and the
        # rebase step re-bases onto whatever moved the sprint branch.
        _transient(ctx, lane, f"ff 合并失败（重跑 integrate 会重新 rebase）：{mr.stderr.strip()[:300]}")
    lane["phase"] = "merged"
    lane.pop("retries", None)
    lane["merged_head"] = git(["rev-parse", "HEAD"], cwd=ctx.root).stdout.strip()
    lane["merged_at"] = now_iso()
    ctx.save_lane(lane)
    _print_merged(ctx, lane, bv_out, verify=verify["status"])
    return 0


# ------------------------------------------------------------- lifecycle helpers

def _artifact_rel(ctx, name: str) -> str:
    return f"{ctx.artifacts_rel().rstrip('/')}/{name}"


def cmd_postmerge(ctx, a):
    """Read-only: which close-out step (run.md §4) a merged lane still needs.
    Every answer is derived from facts on disk, so an interrupted close-out
    resumes at the first unfinished step instead of redoing finished ones."""
    key = a.key
    lane = ctx.lane(key)
    if not lane:
        die(f"lane {key} 不存在")
    if lane.get("phase") not in ("merged", "done"):
        die(f"lane {key} phase={lane.get('phase')}，还没合入 sprint 分支")
    res = read_json(ctx.lane_path(key, "result")) or {}
    reason = res.get("codex_skip_reason") or ""
    marker = ctx.root / _artifact_rel(ctx, f"{key}.codex-skipped.json")
    resolved = ctx.root / _artifact_rel(ctx, f"{key}.codex-skipped.resolved.json")
    if not reason:
        marker_state = "none"
    elif marker.exists() or resolved.exists():
        marker_state = "present"
    else:
        marker_state = "write"
    done_sha = git(["rev-parse", "--verify", "--quiet", f"refs/tags/harness/{key}/done^{{commit}}"],
                   cwd=ctx.root).stdout.strip()
    if done_sha and not _is_ancestor(ctx, done_sha, "HEAD"):
        die(f"harness/{key}/done 指向的提交不在 sprint 分支上（{done_sha[:12]}），需要人工核对")
    hs = subprocess.run(["python3", ".claude/harness/scripts/harness-state.py", key, "--json"],
                        cwd=ctx.root, capture_output=True, text=True)
    try:
        code = json.loads(hs.stdout).get("next_action_code")
    except ValueError:
        code = None
    if done_sha:
        nxt = "finish"
    elif code == "tag-only":
        nxt = "tag"
    elif code == "sync" or (code == "codex" and marker_state == "write"):
        # `codex` before the marker exists is expected: the worker skipped B2 and
        # the marker is written by the dispatcher (HZ B4 step 0), which re-routes to sync.
        nxt = "sync"
    else:
        nxt = "halt"
    print(f"NEXT={nxt}")
    print(f"MARKER={marker_state}")
    print(f"CODEX_SKIP_REASON={reason}")
    print(f"DONE_TAG={done_sha or 'none'}")
    print(f"HARNESS_STATE={code}")
    print(f"FOLLOWUP_NOTE={res.get('followup_note', '')}")
    if nxt == "halt":
        print(f"REASON=harness-state 给出 {code!r}，不是收口阶段该有的状态，需要人工核对")
        print(f"HARNESS_STATE_RAW={(hs.stdout or hs.stderr).strip()[:600]}")
    return 0


def cmd_mark(ctx, a):
    lane = ctx.lane(a.key)
    if not lane:
        die(f"lane {a.key} 不存在")
    if not a.phase:
        die("mark 需要 --phase")
    if a.phase == "done":
        if "done" not in harness_tags(ctx).get(a.key, set()):
            die(f"harness/{a.key}/done tag 不存在，不能标 done")
    lane["phase"] = a.phase
    if a.phase == "held":
        lane["hold_reason"] = a.reason or "调度者挂起"
        lane.pop("hold_kind", None)
    if a.reason:
        lane.setdefault("notes", []).append(f"{a.phase}: {a.reason}")
    ctx.save_lane(lane)
    print("STATUS=ok")
    return 0


def cmd_retry(ctx, a):
    lane = ctx.lane(a.key)
    if not lane:
        die(f"lane {a.key} 不存在")
    stage, _ = lane_stage(ctx, lane)
    if stage not in ("blocked", "failed", "quota", "crashed", "held") or lane.get("phase") in ("merged", "conflict", "integrating"):
        die(f"lane {a.key} 阶段 {stage}（phase={lane.get('phase')}），不能 retry worker")
    if not Path(lane["worktree"]).is_dir():
        die("worktree 已不存在，无法续作；用 abandon 后重新 prepare")
    if lane.get("hold_kind") in ("prepare", "foreign") or str(lane.get("hold_reason", "")).startswith("prepare 失败"):
        die("这一路卡在 prepare 阶段，retry 不会重跑 prepare；修好原因后 abandon --yes 再重新 prepare")
    if lane.get("phase") != "held":
        _retry_check_worktree(ctx, lane, a.reset)
    elif a.reset:
        die("held 的 lane 已经有 commit 等着合流，--reset 不适用；按看板「接手」一行处理")
    lane["phase"] = "prepared"
    lane.pop("hold_reason", None)
    lane.pop("hold_kind", None)
    lane.setdefault("notes", []).append(f"retry after {stage}")
    ctx.save_lane(lane)
    print("STATUS=ok")
    return 0


def _retry_check_worktree(ctx, lane, reset: bool):
    """A worker that died mid-build leaves uncommitted changes behind. When the lane
    has no commit since its start point and no spec for the story, nothing can pick
    those changes up again: B0 halts on the dirty tree, bmad-build-auto refuses to
    start. retry says so instead of queueing a worker that is bound to fail, and
    `--reset` throws the leftovers away (issue #16). With commits or a spec the
    worker continues from harness-state, so the tree is left as it is."""
    key, wt = lane["key"], Path(lane["worktree"])
    dirty = [ln for ln in git(["status", "--porcelain"], cwd=wt).stdout.splitlines() if ln.strip()]
    if not dirty:
        if reset:
            print("NOTE=worktree 是干净的，不需要 --reset")
        return
    start = git(["rev-parse", "--verify", "--quiet", f"refs/tags/harness/{key}/start^{{commit}}"],
                cwd=ctx.root).stdout.strip() or lane.get("base", "")
    ahead = git(["rev-list", "--count", f"{start}..HEAD"], cwd=wt).stdout.strip() if start else ""
    try:
        spec = _harness_spec_mod().resolve_story_md(key, str(wt / ctx.artifacts_rel()))
    except (ImportError, AttributeError):
        spec = "?"
    if ahead != "0" or spec:
        why = f"已有 {ahead} 个 commit" if ahead != "0" else f"已有 spec {spec}"
        print(f"WARN=worktree 有未提交的改动，这一路{why}，worker 会按 harness-state 续作；"
              f"续作失败时 cd {wt} 手工处理")
        if reset:
            die(f"这一路{why}，--reset 只用于没有 commit、也没有 spec 的半成品，不会替你丢掉已有进度",
                f"WORKTREE={wt}")
        return
    if not reset:
        die("lane worktree 里有没提交的半成品（没有 commit，也没有 spec），worker 重跑时 B0 和 bmad-build-auto "
            f"都会因为工作区不干净而停下。确认不要这些改动后执行 {SH_CMD} retry {key} --reset，"
            f"会恢复到 {start[:12]} 并删掉未跟踪文件（被 .gitignore 忽略的不动）",
            *[f"DIRTY={d}" for d in dirty[:30]], f"WORKTREE={wt}")
    r1 = git(["reset", "--hard", start], cwd=wt)
    r2 = git(["clean", "-fd"], cwd=wt)
    if r1.returncode != 0 or r2.returncode != 0:
        die(f"恢复 worktree 失败：{(r1.stderr + r2.stderr).strip()}", f"WORKTREE={wt}")
    for d in dirty[:30]:
        print(f"DISCARDED={d}")
    print(f"RESET={start}")


def _remove_worktree(ctx, lane, force_branch: bool):
    wt = Path(lane["worktree"])
    if wt.exists():
        r = git(["worktree", "remove", "--force", str(wt)], cwd=ctx.root)
        if r.returncode != 0:
            print(f"WARN=worktree remove 失败：{r.stderr.strip()}")
    git(["worktree", "prune"], cwd=ctx.root)
    r = git(["branch", "-D" if force_branch else "-d", lane["branch"]], cwd=ctx.root)
    if r.returncode != 0 and "not found" not in r.stderr:
        print(f"WARN=删除分支 {lane['branch']} 失败：{r.stderr.strip()}")


def cmd_cleanup(ctx, a):
    lane = ctx.lane(a.key)
    if not lane:
        die(f"lane {a.key} 不存在")
    if lane.get("phase") != "done":
        die(f"lane {a.key} phase={lane.get('phase')}，只有 done 能 cleanup")
    if ctx.config.get("keep_worktrees"):
        print("STATUS=skip")
        print("REASON=keep_worktrees=true")
        return 0
    _remove_worktree(ctx, lane, force_branch=False)
    lane["cleaned_at"] = now_iso()
    ctx.save_lane(lane)
    print("STATUS=ok")
    return 0


def cmd_abandon(ctx, a):
    if not a.yes:
        die("abandon 会删除 worktree、分支和本 story 未 done 的 harness tag，需要 --yes（先征得用户同意）")
    lane = ctx.lane(a.key)
    if not lane:
        die(f"lane {a.key} 不存在")
    if lane.get("phase") in ("merged", "done"):
        die(f"lane {a.key} 已合入 sprint 分支（phase={lane.get('phase')}），不能 abandon")
    if op_live(lane.get("op")):
        print("STATUS=busy")
        print(f"REASON=lane {a.key} 的 {lane['op'].get('name')} 正在运行（pid {lane['op'].get('pid')}），等它结束再 abandon")
        return EXIT_BUSY
    _reap_dead_op(lane)
    if lane.get("foreign"):
        # the branch / directory existed before this lane: not ours to delete
        lane["phase"] = "abandoned"
        lane["abandoned_at"] = now_iso()
        ctx.save_lane(lane)
        print("STATUS=ok")
        print("NOTE=这一路的分支 / 目录不是 super-harness 建的，没有删除")
        return 0
    wt = Path(lane["worktree"])
    if wt.exists() and _rebase_in_progress(wt):
        git(["rebase", "--abort"], cwd=wt)
    for _t, tb in lane.get("carry", []):
        git(["branch", "-D", tb], cwd=ctx.root)
    _remove_worktree(ctx, lane, force_branch=True)
    tags = harness_tags(ctx).get(a.key, set())
    if "done" not in tags:
        for t in sorted(tags):
            git(["tag", "-d", f"harness/{a.key}/{t}"], cwd=ctx.root)
            print(f"DELETED_TAG=harness/{a.key}/{t}")
    lane["phase"] = "abandoned"
    lane["abandoned_at"] = now_iso()
    ctx.save_lane(lane)
    print("STATUS=ok")
    return 0


def cmd_doctor(ctx, _a):
    """Read-only: will copy_paths / link_paths leave a fresh lane worktree clean?"""
    problems = []
    for rel in ctx.config.get("copy_paths") or []:
        rel = rel.rstrip("/")
        if not (ctx.root / rel).exists():
            print(f"SKIP={rel}（主 worktree 里不存在）")
            continue
        r = git(["status", "--porcelain", "-uall", "--", rel], cwd=ctx.root)
        loose = [ln[3:] for ln in r.stdout.splitlines() if ln.startswith("?? ")]
        tracked = bool(git(["ls-files", "--", rel], cwd=ctx.root).stdout.strip())
        if loose:
            # the tracked configs need a commit, not an ignore rule
            for c in [p for p in loose if p in HARNESS_TRACKED_CONFIGS]:
                problems.append(c)
                print(f"PROBLEM={c}：配置文件还没提交，复制进 lane 后 lane 会是脏的；git add 后提交")
            loose = [p for p in loose if p not in HARNESS_TRACKED_CONFIGS]
        if loose:
            problems.append(rel)
            print(f"PROBLEM={rel}：有未跟踪且未被忽略的文件（{', '.join(loose[:3])}），复制进 lane 后 lane 会是脏的")
        elif rel not in problems and not any(p.startswith(rel + "/") for p in problems):
            print(f"OK={rel}（{'已入库' if tracked else '被 .gitignore 忽略，开 lane 时复制'}）")
    gi = ctx.root / ".gitignore"
    gi_lines = {ln.strip() for ln in gi.read_text(encoding="utf-8").splitlines()} if gi.exists() else set()
    for rel in ctx.config.get("link_paths") or []:
        rel = rel.rstrip("/")
        if not (ctx.root / rel).exists():
            print(f"SKIP={rel}（主 worktree 里不存在）")
            continue
        if git(["ls-files", "--", rel], cwd=ctx.root).stdout.strip():
            print(f"OK={rel}（已入库，lane 里自带，不会软链）")
        elif {rel, f"/{rel}"} & gi_lines:
            print(f"OK={rel}（.gitignore 有不带斜杠的规则，软链会被忽略）")
        else:
            problems.append(rel)
            print(f"PROBLEM={rel}：软链需要 .gitignore 里有不带结尾斜杠的规则（`{rel}/` 匹配不到软链）")
    for ln in _gitignore_hint(problems):
        print(ln)
    if ctx.legacy_config.parent.exists():
        print("WARN=.claude/super-harness/ 是 super-harness 0.1.0 的旧目录，0.2.0 起不再读取"
              "（配置已改用 .claude/harness/parallel.yaml），确认新配置无误后可以删除")
    print("STATUS=" + ("attention" if problems else "ok"))
    return 0


def _closeout_leftovers(ctx, dirty_lines):
    """Dirty paths an interrupted close-out sync step (run.md §4, NEXT=sync) leaves
    behind: the marker written before build-sync, and what build-sync stages before
    the commit. Returns (keys, ok) — ok only if EVERY dirty path is one of those
    files for a merged lane that has no done tag yet."""
    art = ctx.artifacts_rel().rstrip("/")
    allowed = {}
    for key, lane in ctx.all_lanes().items():
        if lane.get("phase") != "merged":
            continue
        if "done" in harness_tags(ctx).get(key, set()):
            continue
        for name in ("sprint-status.yaml", "deferred-work.md", f"{key}.codex-skipped.json"):
            allowed.setdefault(f"{art}/{name}", set()).add(key)
    keys = set()
    for ln in dirty_lines:
        path = ln[3:].strip().strip('"')
        if path not in allowed:
            return sorted(keys), False
        keys |= allowed[path]
    return sorted(keys), bool(dirty_lines)


def cmd_end_run(ctx, _a):
    """Release the dispatcher lock (run.md §7 / §8 / §9)."""
    with _lock_guard(ctx):
        lk = read_json(ctx.state / LOCK_FILE)
        if lk and not _same_owner(lk, lock_owner()) and _lock_live(lk):
            _print_locked(lk, "锁不属于本会话，没有释放")
            return EXIT_BUSY
        try:
            (ctx.state / LOCK_FILE).unlink()
        except FileNotFoundError:
            pass
    print("STATUS=ok")
    return 0


def cmd_start_run(ctx, a):
    """Take the dispatcher lock, pin the sprint branch for this run (the branch the
    main worktree is on)."""
    me = lock_owner()
    with _lock_guard(ctx):
        lk = read_json(ctx.state / LOCK_FILE)
        if lk and not _same_owner(lk, me) and _lock_live(lk) and not a.take_over:
            _print_locked(lk, "本会话不能同时调度")
            return EXIT_BUSY
        if lk and not _same_owner(lk, me):
            print(f"LOCK_RECLAIMED={'taken-over' if _lock_live(lk) else 'stale'} pid={lk.get('pid')}")
        if not _same_owner(lk, me):
            write_json(ctx.state / LOCK_FILE, dict(me, acquired_at=now_iso()))
    head, dirty = main_status(ctx)
    if not head:
        die("主 worktree 处于 detached HEAD，先切到 sprint 分支")
    info = ctx.run_info()
    if info.get("sprint_branch") and info["sprint_branch"] != head and not a.force:
        die(f"上次运行固定的 sprint 分支是 {info['sprint_branch']!r}，当前在 {head!r}。"
            f"切回去，或确认无在飞 lane 后加 --force 改用当前分支")
    if info.get("sprint_branch") != head:
        info = {"sprint_branch": head, "started_at": now_iso()}
    if a.slots is not None:
        if a.slots < 1:
            die("--slots 至少为 1")
        info["max_slots"] = a.slots
    elif a.reset_slots:
        info.pop("max_slots", None)
    info["last_tick_at"] = now_iso()
    write_json(ctx.state / "run.json", info)
    print("STATUS=ok")
    print(f"SPRINT_BRANCH={head}")
    if not dirty:
        print("MAIN_CLEAN=true")
    else:
        keys, resumable = _closeout_leftovers(ctx, dirty)
        if resumable:
            # interrupted close-out: tick routes post-merge first and postmerge
            # resumes at NEXT=sync, whose build-sync commit absorbs these files
            print("MAIN_CLEAN=resumable")
            print(f"RESUMABLE_LANES={','.join(keys)}")
        else:
            print("MAIN_CLEAN=false")
        for d in dirty[:20]:
            print(f"DIRTY={d}")
    print(f"WORKTREE_ROOT={ctx.wt_root}")
    print(f"MAX_SLOTS={info.get('max_slots') or load_config(ctx.config_path)['max_slots']}")
    return 0


# ------------------------------------------------------------------------- main

# subcommands that change lanes / git state: refused while another live session
# holds the dispatcher lock (`report` is the worker's and stays open)
MUTATING = ("prepare", "launch", "integrate", "retry", "mark", "cleanup", "abandon")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="superh.py", description="super-harness 调度层 CLI")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("env")
    p = sub.add_parser("plan"); p.add_argument("--json", action="store_true")
    sub.add_parser("tick")
    sub.add_parser("doctor")
    p = sub.add_parser("board"); p.add_argument("--json", action="store_true")
    p = sub.add_parser("start-run")
    p.add_argument("--force", action="store_true")
    p.add_argument("--slots", type=int, default=None, help="本次运行的并发数（覆盖 config.max_slots，写进 run.json）")
    p.add_argument("--reset-slots", action="store_true", help="清除上次 --slots 覆盖，回到 config.max_slots")
    p.add_argument("--take-over", action="store_true", help="接管另一个仍然活着的会话持有的调度锁（先征得用户同意）")
    sub.add_parser("end-run")
    for name in ("prepare", "launch", "integrate", "postmerge", "retry", "cleanup"):
        p = sub.add_parser(name); p.add_argument("key")
        if name == "retry":
            p.add_argument("--reset", action="store_true",
                           help="lane 没有 commit 也没有 spec 时，丢掉 worktree 里没提交的半成品再重排")
    p = sub.add_parser("watch"); p.add_argument("key"); p.add_argument("--interval", default="5")
    p = sub.add_parser("report")
    p.add_argument("key")
    p.add_argument("--status", required=True, choices=["ready", "blocked", "failed", "quota"])
    p.add_argument("--summary", default="")
    p.add_argument("--codex-skip-reason", default="")
    p.add_argument("--followup-note", default="")
    p.add_argument("--halt", default="")
    p.add_argument("--halt-file", default="")
    p = sub.add_parser("mark")
    p.add_argument("key")
    p.add_argument("--phase", choices=["done", "held"])
    p.add_argument("--reason", default="")
    p = sub.add_parser("abandon"); p.add_argument("key"); p.add_argument("--yes", action="store_true")
    a = ap.parse_args(argv)
    # line-buffered: prepare / integrate run in the background and may be killed;
    # whatever they printed up to that point should be in the output file
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except (AttributeError, ValueError):
        pass
    ctx = Ctx()
    if a.cmd in MUTATING:
        check_lock(ctx, f"不能在这里执行 {a.cmd}")
    fn = {
        "env": cmd_env, "doctor": cmd_doctor, "plan": cmd_plan, "tick": cmd_tick, "board": cmd_board, "start-run": cmd_start_run,
        "prepare": cmd_prepare, "launch": cmd_launch, "report": cmd_report, "integrate": cmd_integrate, "postmerge": cmd_postmerge,
        "mark": cmd_mark, "retry": cmd_retry, "cleanup": cmd_cleanup, "abandon": cmd_abandon,
        "end-run": cmd_end_run, "watch": cmd_watch,
    }[a.cmd]
    try:
        return fn(ctx, a)
    except Interrupted as e:
        # a child process group was running; run_group already killed it
        print("STATUS=halt")
        print(f"REASON=被信号 {e.signum} 中断（子进程组已结束）")
        return 128 + e.signum


if __name__ == "__main__":
    sys.exit(main())
