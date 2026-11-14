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
    lanes/<KEY>.reopen.json  worker 写（经 `reopen`）：本 story 自己重开 spec 的次数
    lanes/<KEY>.notes.json   reopen / resume / override 写：还没有 spec 时的答复，下一次 worker prompt 带上
    decisions.json           决策收件箱（worker 的 reopen、调度者的 decide / resume、launch /
                             integrate 导入的漏后缀记录和 spec 待确认项、用户的 confirm /
                             override 都会写，经 flock 串行）
    resources.json           已执行 resource_acquire、还没 release 的资源（经 flock）
    post_epic.json           post_epic_command 推迟中 / 已执行的 epic
    dispatcher.lock          start-run 写：持有调度权的会话（pid + 启动时间）

子命令（都在项目根目录或任一 worktree 内运行）：

    env                     打印路径与生效配置（JSON）
    doctor                  只读检查：copy_paths / link_paths 补进 lane 后 lane 是否干净
    plan [--json]           列出每条未完成 story 的就绪情况与等待原因
    tick                    调度者每轮循环读的结构化快照（JSON），含 next_action
    board [--json] [--full] 看板：先列需要人处理的 lane；--full 待确认项不截断
    start-run               取调度锁，固定本次运行的 sprint 分支
    end-run [--finished]    释放调度锁（--finished：再执行 env_down_command）
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
    resume <KEY> --note N   把用户的决定写进 spec、提交、挪 followup-start，重新排队
    reopen <KEY> --why W    worker 用：intent gap 按推荐项代答（--decisions-file）或瞬态失败后重开 spec
    decide <KEY|-> ...      调度者记一条自己按推荐项做的决定
    decisions [--all]       列出决策收件箱
    confirm <ID...>|--all   确认决定
    override <ID> --answer  推翻一条决定：没合入的 lane 回退到决定之前，按新答复重跑
    spec-decisions <KEY>    把 spec `### 待用户确认` 段（及旧写法）的条目导入收件箱
    post-epic <N>           epic retro 之后执行 post_epic_command（有 lane 在跑时推迟）
    cleanup <KEY>           done 之后删 worktree 与分支（先跑 lane_cleanup_command）
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
import fnmatch  # noqa: E402
import hashlib  # noqa: E402
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
PERSON_STAGES = ("conflict", "held", "blocked", "failed", "quota", "crashed", "disk_full")
# An integrate / prepare that was killed from outside (the session's Bash call hit
# its time limit, the session ended) is resumed this many times; one more kill
# holds the lane instead of looping tick → integrate → kill forever.
MAX_INTERRUPTS = 2
# integrate failures that are not caused by the lane (the sprint branch moved under
# it) are retried this many times in a row before the lane is held.
MAX_TRANSIENT = 3
EXIT_BUSY = 4   # STATUS=busy (this lane's prepare/integrate is already running) or STATUS=locked
EXIT_DISK = 5   # STATUS=disk-low (free space under disk_min_free_gb) or STATUS=disk-full (verify hit ENOSPC)
# hold_kind values integrate sets; a lane held with one of these is accepted by a
# manual `integrate` re-run once the person has fixed the cause.
INTEGRATE_HOLD_KINDS = ("verify", "verify-env", "build-verify", "lane-dirty", "rebase", "branch-missing",
                        "worktree-missing", "interrupted", "ff", "retry-limit", "git-error", "error",
                        "ledger", "disk")
# Lane stages a person (or `resume`) has to act on before the lane moves again.
# With blocked_policy=continue they stop holding back the serial order and the
# epic / retro barriers; explicit depends_on still waits for them.
STUCK_STAGES = ("blocked", "failed", "held", "conflict")
# How many times a worker may reopen its own spec (pipeline.md §3.3) per story.
REOPEN_LIMITS = {"decision": 2, "transient": 1}
SPEC_STATUSES = ("draft", "ready-for-dev", "in-progress", "in-review")
LOCK_FILE = "dispatcher.lock"
# issue #31: what a full disk prints. cargo: "No space left on device (os error 28)";
# Python: "[Errno 28] No space left on device"; node / libuv: "ENOSPC".
ENOSPC_RE = re.compile(r"No space left on device|os error 28\b|\bENOSPC\b|\[Errno 28\]")
# A lane that failed on a full disk is retried automatically this many times once
# space is back; a story whose own tests print ENOSPC can't loop forever.
MAX_DISK_RETRIES = 2
DISK_FILE = "disk.json"
# A spec shorter than this share of its backup (and the backup at least
# SPEC_SHRINK_MIN bytes) is treated as truncated, like a 0-byte one.
SPEC_SHRINK_RATIO = 0.5
SPEC_SHRINK_MIN = 1024

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
    "verify_timeout_retries": 1,         # verify_command 超时后自动重跑的次数（失败不重跑）
    "env_check_command": "",             # 前置环境是否就绪（exit 0 = 就绪）
    "env_up_command": "",                # 环境没就绪时执行一次，起好后再检查
    "env_down_command": "",              # end-run --finished 时执行
    "env_timeout_sec": 600,
    "decision_mode": "proceed",          # proceed = 有推荐项就按推荐项续跑、记进收件箱；ask = 停下等人
    "blocked_policy": "wait",            # wait | continue（受阻的 lane 不再挡串行顺序、epic 屏障、retro 屏障）
    "worker_permission_mode": "bypassPermissions",
    "worker_model": "",
    "claude_bin": "claude",
    "keep_worktrees": False,
    "deps_overrides": {},
    "resources": {},                     # story key / glob → [资源名]：同一资源同一时间只给一路（issue #22）
    "resource_acquire": {},              # 资源名 → 第一条要用它的 story 启动前执行的命令
    "resource_release": {},              # 资源名 → 最后一条要用它的 story 完成后执行的命令
    "lane_cleanup_command": "",          # cleanup / abandon 删 worktree 之前执行（issue #26）
    "post_epic_command": "",             # epic retro 之后、没有 lane 在跑时执行（post-epic）
    "hook_timeout_sec": 1800,            # 上面两个钩子和 resource_* 命令的超时
    # issue #31：磁盘余量。低于 disk_min_free_gb 时不派发新 lane、暂缓合流；0 = 不检查
    "disk_check_paths": [],              # 空 = worktree_root 和主 worktree 所在的分区
    "disk_min_free_gb": "auto",          # auto = 10G，但不超过该分区容量的 10%；0 = 不检查
    "disk_cleanup_command": "",          # 余量不足、没有 lane 在跑时执行一次（disk-cleanup）
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


def write_atomic(path: Path, data) -> None:
    """Write text or bytes through a temp file in the same directory + rename.
    A full disk (ENOSPC) or a kill mid-write leaves the old file as it was and
    no temp file behind (issue #31: a spec truncated to 0 bytes)."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        mode = path.stat().st_mode & 0o777
    except OSError:
        mode = None
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data if isinstance(data, bytes) else str(data).encode("utf-8"))
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def write_json(path: Path, data) -> None:
    write_atomic(path, json.dumps(data, ensure_ascii=False, indent=2) + "\n")


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
def _guard(ctx, name: str):
    """Exclusive flock on state/<name>: serialises read-modify-write of a shared
    state file between superh processes (dispatcher, workers, the user's shell)."""
    ctx.state.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(ctx.state / name), os.O_RDWR | os.O_CREAT, 0o644)
    try:
        if fcntl is not None:
            fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def _lock_guard(ctx):
    """Serialises read-check-write of the lock file between superh processes."""
    return _guard(ctx, ".lock.guard")


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
    if cfg.get("decision_mode") not in ("proceed", "ask"):
        cfg["decision_mode"] = "proceed"
    if cfg.get("blocked_policy") not in ("wait", "continue"):
        cfg["blocked_policy"] = "wait"
    for k, dflt in (("verify_timeout_retries", 1), ("env_timeout_sec", 600)):
        try:
            cfg[k] = max(0, int(cfg.get(k) if cfg.get(k) is not None else dflt))
        except (TypeError, ValueError):
            cfg[k] = dflt
    for k in ("copy_paths", "link_paths"):
        if not isinstance(cfg.get(k), list):
            cfg[k] = []
    if not isinstance(cfg.get("deps_overrides"), dict):
        cfg["deps_overrides"] = {}
    for k in ("resources", "resource_acquire", "resource_release"):
        v = cfg.get(k)
        cfg[k] = {str(kk).strip().strip("'\""): vv for kk, vv in v.items()} if isinstance(v, dict) else {}
    try:
        cfg["hook_timeout_sec"] = max(1, int(cfg.get("hook_timeout_sec") or 1800))
    except (TypeError, ValueError):
        cfg["hook_timeout_sec"] = 1800
    v = cfg.get("disk_check_paths")
    cfg["disk_check_paths"] = [str(x) for x in v if str(x).strip()] if isinstance(v, list) else \
        ([str(v)] if isinstance(v, str) and v.strip() else [])
    v = cfg.get("disk_min_free_gb")
    if str(v).strip().lower() in ("auto", "", "none"):
        cfg["disk_min_free_gb"] = "auto"
    else:
        try:
            cfg["disk_min_free_gb"] = max(0.0, float(v))
        except (TypeError, ValueError):
            cfg["disk_min_free_gb"] = "auto"
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


# --------------------------------------------------------------------- resources
#
# issue #22: some stories need a machine-wide singleton (an integration
# environment, pinned benchmark cores). `deps_overrides` could only serialize
# them in a fixed order; `resources` says what each story occupies and tick never
# hands the same resource to two lanes at once. A lane holds its resources from
# prepare until it is merged (or abandoned); one that stopped and waits for a
# person keeps them, so a retry can't end up next to another user.
# `resource_acquire` runs before the first worker that needs the resource
# starts, `resource_release` once no unfinished story needs it any more.

RESOURCES_FILE = "resources.json"


def story_resources(cfg, key: str) -> set:
    out = set()
    for pat, names in (cfg.get("resources") or {}).items():
        if key == pat or fnmatch.fnmatchcase(key, str(pat)):
            if isinstance(names, str):
                names = [names]
            out |= {str(n).strip() for n in (names or []) if str(n).strip()}
    return out


def resource_holders(ctx, lanes) -> dict:
    """{resource: lane key} for lanes that still hold what they declared."""
    out = {}
    for k, l in sorted(lanes.items()):
        if l.get("phase") in ("done", "abandoned", "merged"):
            continue
        for r in story_resources(ctx.config, k):
            out.setdefault(r, k)
    return out


def _acquired(ctx) -> dict:
    d = read_json(ctx.state / RESOURCES_FILE)
    return d if isinstance(d, dict) else {}


def _acquire_resources(ctx, lane) -> dict:
    """Run resource_acquire for the lane's resources that are not up yet.
    {"ok": bool, "detail": str, "output": str}."""
    cmds = ctx.config.get("resource_acquire") or {}
    need = [r for r in sorted(story_resources(ctx.config, lane["key"])) if str(cmds.get(r) or "").strip()]
    if not need:
        return {"ok": True, "detail": "", "output": ""}
    timeout = int(ctx.config.get("hook_timeout_sec") or 1800)
    with _guard(ctx, ".resources.guard"):
        held = _acquired(ctx)
        for r in need:
            if r in held:
                continue
            res = _env_run(ctx, str(cmds[r]), lane, timeout)
            if res["timed_out"] or res["rc"] != 0:
                return {"ok": False, "output": (res["out"] + res["err"])[-3000:],
                        "detail": f"资源 {r} 的 resource_acquire 失败（{'超时' if res['timed_out'] else 'exit=' + str(res['rc'])}）"}
            held[r] = {"since": now_iso(), "by": lane["key"]}
            write_json(ctx.state / RESOURCES_FILE, held)
            print(f"RESOURCE_ACQUIRED={r}")
            lane.setdefault("notes", []).append(f"resource acquired: {r}")
    return {"ok": True, "detail": "", "output": ""}


def _release_resources(ctx, all_of_them: bool = False):
    """Release acquired resources nothing unfinished needs any more (or all of
    them at the end of the run)."""
    cmds = ctx.config.get("resource_release") or {}
    with _guard(ctx, ".resources.guard"):
        held = _acquired(ctx)
        if not held:
            return
        busy = set()
        if not all_of_them:
            stories, _ = parse_sprint(ctx.sprint_file())
            settled = set(ctx.terminal()) | set(ctx.parked())
            for st in stories:
                if st["status"] not in settled:
                    busy |= story_resources(ctx.config, st["key"])
            busy |= set(resource_holders(ctx, ctx.all_lanes()))
        for r in sorted(held):
            if r in busy:
                continue
            cmd = str(cmds.get(r) or "").strip()
            if cmd:
                res = _env_run(ctx, cmd, None, int(ctx.config.get("hook_timeout_sec") or 1800))
                if res["timed_out"] or res["rc"] != 0:
                    print(f"RESOURCE_RELEASE_FAILED={r}")
                    print(f"WARN=资源 {r} 的 resource_release 没有成功，它可能还占着："
                          f"{(res['out'] + res['err']).strip()[-300:]}")
                    continue
            held.pop(r, None)
            write_json(ctx.state / RESOURCES_FILE, held)
            print(f"RESOURCE_RELEASED={r}")


# ------------------------------------------------------------------ hooks (#26)

def _run_hook(ctx, name: str, cmd: str, lane=None, extra_env=None) -> bool:
    env = dict(os.environ, SUPERH_MAIN_ROOT=str(ctx.root), **(extra_env or {}))
    if lane:
        env.update(SUPERH_KEY=lane["key"], SUPERH_WORKTREE=str(lane.get("worktree", "")),
                   SUPERH_BRANCH=str(lane.get("branch", "")))
    timeout = int(ctx.config.get("hook_timeout_sec") or 1800)
    r = run_group(["sh", "-c", cmd], cwd=ctx.root, env=env, timeout=timeout,
                  on_start=_record_child(ctx, lane) if lane else None)
    if r["timed_out"] or r["rc"] != 0:
        print(f"HOOK={name} failed（{'超时 ' + str(timeout) + 's' if r['timed_out'] else 'exit=' + str(r['rc'])}）")
        print(f"WARN={name} 没有成功：{(r['out'] + r['err']).strip()[-300:]}")
        return False
    print(f"HOOK={name} ok")
    return True


def _lane_cleanup_hook(ctx, lane):
    cmd = str(ctx.config.get("lane_cleanup_command") or "").strip()
    if cmd and lane.get("worktree") and not lane.get("foreign"):
        _run_hook(ctx, "lane_cleanup_command", cmd, lane)


POST_EPIC_FILE = "post_epic.json"


def _post_epic_state(ctx) -> dict:
    d = read_json(ctx.state / POST_EPIC_FILE)
    if not isinstance(d, dict):
        d = {}
    d.setdefault("pending", [])
    d.setdefault("done", [])
    return d


# --------------------------------------------------------------------- disk space
#
# issue #31: three lanes sharing one build cache filled the root partition three
# times in one epic. Below disk_min_free_gb tick hands out no new lane and no
# integrate; disk_cleanup_command (if set) runs once per low-space episode while
# no lane is working; a lane that died on ENOSPC gets its own stage (disk_full)
# and is retried once space is back.

def _disk_paths(ctx) -> list:
    raw = ctx.config.get("disk_check_paths") or []
    out = []
    for r in raw:
        p = Path(str(r)).expanduser()
        out.append(p if p.is_absolute() else ctx.root / p)
    return out or [ctx.wt_root, ctx.root]


def _existing(p: Path) -> Path:
    while not p.exists() and p != p.parent:
        p = p.parent
    return p


# disk_min_free_gb: auto — 10G, but never more than this share of the partition:
# an empty 9.8G tmpfs must not read as "low" forever.
DISK_AUTO_GB = 10.0
DISK_AUTO_SHARE = 0.10


def _free_gb(p: Path) -> tuple[float, float]:
    """(free, size) in GB."""
    st = os.statvfs(str(p))
    size = st.f_blocks * st.f_frsize / 1024 ** 3
    fake = os.environ.get("SUPERH_TEST_DISK_FREE_GB")  # tests only
    if fake:
        return float(fake), size
    return st.f_bavail * st.f_frsize / 1024 ** 3, size


def disk_state(ctx, update: bool = False) -> dict:
    """Free space on every checked filesystem (one entry per device).
    update=True (tick): space back above the threshold ends the low-space
    episode, so disk_cleanup_command may run again the next time it runs low."""
    conf = ctx.config.get("disk_min_free_gb")
    auto = conf == "auto"
    try:
        fixed = 0.0 if auto else float(conf or 0)
    except (TypeError, ValueError):
        fixed = 0.0
    if not auto and fixed <= 0:
        return {"enabled": False, "ok": True, "min_free_gb": 0, "paths": [], "low": []}
    seen, entries = set(), []
    for p in _disk_paths(ctx):
        e = _existing(p)
        try:
            dev = os.stat(str(e)).st_dev
            free, size = _free_gb(e)
        except (OSError, ValueError):
            continue
        if dev in seen:
            continue
        seen.add(dev)
        need = round(min(DISK_AUTO_GB, size * DISK_AUTO_SHARE), 1) if auto else fixed
        entries.append({"path": str(p), "free_gb": round(free, 1), "min_free_gb": need, "low": free < need})
    low = [x for x in entries if x["low"]]
    ds = {"enabled": True, "ok": not low, "min_free_gb": conf if auto else fixed, "paths": entries, "low": low}
    if update and ds["ok"]:
        st = read_json(ctx.state / DISK_FILE) or {}
        if st.get("cleanup_ran"):
            st.pop("cleanup_ran", None)
            st["recovered_at"] = now_iso()
            try:
                write_json(ctx.state / DISK_FILE, st)
            except OSError:
                pass
    return ds


def _gb(x) -> str:
    return f"{x:g}G" if isinstance(x, (int, float)) else str(x)


def disk_text(ds) -> str:
    rows = ds["low"] or ds["paths"]
    return "、".join(f"{x['path']} 剩 {_gb(x['free_gb'])}（阈值 {_gb(x['min_free_gb'])}）" for x in rows) + \
        f"，disk_min_free_gb={_gb(ds['min_free_gb'])}"


def _disk_gate(ctx, what: str):
    """None when there is room; otherwise print STATUS=disk-low and return EXIT_DISK.
    Nothing about the lane is changed: tick hands the step out again once space is back."""
    ds = disk_state(ctx)
    if ds["ok"]:
        return None
    print("STATUS=disk-low")
    print(f"REASON=磁盘余量低于阈值：{disk_text(ds)}，{what}")
    for x in ds["low"]:
        print(f"DISK_FREE={x['path']} {_gb(x['free_gb'])}")
    return EXIT_DISK


def _tail(path, n: int = 65536) -> str:
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - n))
            return f.read().decode("utf-8", "replace")
    except (OSError, TypeError):
        return ""


def _disk_evidence(ctx, proc, res, logs: bool) -> str:
    """Why a failed / lost worker looks like a full disk, or "".
    logs=False (the worker reported blocked / failed itself): only its own words
    count, not its build output, which may legitimately print ENOSPC."""
    texts = [(proc or {}).get("result_text") or "", (proc or {}).get("log_write_error") or ""]
    if res:
        texts += [res.get("summary") or "", res.get("halt") or ""]
    if logs and proc and proc.get("log"):
        log = str(proc["log"])
        texts += [_tail(log), _tail(log.replace(".stream.jsonl", ".stderr.log"))]
    m = ENOSPC_RE.search("\n".join(texts))
    if m:
        return f"输出里有「{m.group(0)}」"
    if (proc or {}).get("disk_low_at_exit"):
        return f"worker 退出时磁盘余量不足：{proc['disk_low_at_exit']}"
    if logs:
        ds = disk_state(ctx)
        if not ds["ok"]:
            return f"磁盘余量现在低于阈值：{disk_text(ds)}"
    return ""


def _try_write_json(path: Path, data) -> bool:
    """write_json that survives a full disk: the caller keeps running and tries again later."""
    try:
        write_json(path, data)
        return True
    except OSError:
        return False


def cmd_disk(ctx, a):
    ds = disk_state(ctx)
    if a.json:
        print(json.dumps(ds, ensure_ascii=False, indent=2))
        return 0
    if not ds["enabled"]:
        print("DISK=off（disk_min_free_gb=0，不检查）")
        return 0
    print(f"DISK={'ok' if ds['ok'] else 'low'}")
    for x in ds["paths"]:
        print(f"DISK_FREE={x['path']} {_gb(x['free_gb'])} 阈值 {_gb(x['min_free_gb'])}{' (低于阈值)' if x['low'] else ''}")
    print(f"MIN_FREE={_gb(ds['min_free_gb'])}")
    return 0


def cmd_disk_cleanup(ctx, _a):
    """Run disk_cleanup_command once while space is low and no lane is working
    (a cleanup that deletes a shared build cache under a compiling lane breaks it;
    issue #31). After one run it waits for space to come back above the threshold
    before it can run again, so a cleanup that frees too little doesn't loop."""
    cmd = str(ctx.config.get("disk_cleanup_command") or "").strip()
    if not cmd:
        print("STATUS=skip")
        print("REASON=parallel.yaml 没有配 disk_cleanup_command")
        return 0
    ds = disk_state(ctx)
    if ds["ok"]:
        print("STATUS=skip")
        print(f"REASON=磁盘余量够用：{disk_text(ds)}")
        return 0
    st = read_json(ctx.state / DISK_FILE) or {}
    if st.get("cleanup_ran"):
        print("STATUS=skip")
        print(f"REASON=这次余量不足已经执行过一次 disk_cleanup_command（{st['cleanup_ran'].get('at', '')}），"
              "余量仍不够；需要人工腾出空间")
        return 0
    lanes = ctx.all_lanes()
    busy = sorted(k for k, l in lanes.items() if lane_stage(ctx, l)[0] == "working" or op_live(l.get("op")))
    if busy:
        print("STATUS=deferred")
        print(f"REASON=还有 {len(busy)} 路在跑（{', '.join(busy)}），等它们结束再清理")
        return 0
    before = disk_text(ds)
    ok = _run_hook(ctx, "disk_cleanup_command", cmd, None,
                   {"SUPERH_DISK_PATHS": os.pathsep.join(x["path"] for x in ds["low"]),
                    "SUPERH_DISK_MIN_FREE_GB": _gb(ds["low"][0]["min_free_gb"]).rstrip("G")})
    after = disk_state(ctx)
    st = read_json(ctx.state / DISK_FILE) or {}
    st["cleanup_ran"] = {"at": now_iso(), "ok": ok, "before": before, "after": disk_text(after)}
    _try_write_json(ctx.state / DISK_FILE, st)
    if after["ok"]:
        st.pop("cleanup_ran", None)
        st["recovered_at"] = now_iso()
        _try_write_json(ctx.state / DISK_FILE, st)
    print("STATUS=ok")
    print(f"DISK_CLEANUP={'ok' if ok else 'failed'}")
    print(f"DISK={'ok' if after['ok'] else 'low'}")
    for x in after["paths"]:
        print(f"DISK_FREE={x['path']} {_gb(x['free_gb'])}")
    return 0


# ------------------------------------------------------------------ spec backup
#
# issue #31: a worker's spec was cut to 0 bytes when the disk filled up. The spec
# is written by the agent's edit tool, out of the plugin's reach, so launch and
# retry keep a copy; before a new attempt, a 0-byte or much shorter spec is put
# back from it (the short one is kept next to the backup).

def _spec_backup_path(ctx, key) -> Path:
    return ctx.lanes / f"{key}.spec-backup.md"


def _spec_guard(ctx, lane, restore: bool) -> list:
    """Back the lane's spec up, or (restore=True) put a truncated one back.
    Returns output lines. Updates lane in memory; the caller saves it."""
    key = lane["key"]
    wt = Path(lane.get("worktree") or "")
    if not wt.is_dir():
        return []
    rel = _lane_spec(ctx, key, wt)
    if not rel:
        return []
    cur = wt / rel
    try:
        size = cur.stat().st_size
    except OSError:
        return []
    bk = _spec_backup_path(ctx, key)
    meta = lane.get("spec_backup") or {}
    bsize = None
    if meta.get("rel") == rel:
        try:
            bsize = bk.stat().st_size
        except OSError:
            bsize = None
    short = bool(bsize) and (size == 0 or (bsize >= SPEC_SHRINK_MIN and size < bsize * SPEC_SHRINK_RATIO))
    if short and not restore:
        return [f"WARN=spec {rel} 只剩 {size} 字节（上次备份 {bsize} 字节），可能是磁盘写满时被截断；"
                f"下次 retry 或 launch 前会从备份恢复"]
    if short:
        aside = ctx.lanes / f"{key}.spec-short-{time.strftime('%Y%m%d-%H%M%S')}.md"
        try:
            write_atomic(aside, cur.read_bytes())
            write_atomic(cur, bk.read_bytes())
        except OSError as e:
            return [f"WARN=spec {rel} 只剩 {size} 字节，从备份恢复失败：{e}"]
        lane["spec_restored"] = {"rel": rel, "at": now_iso(), "size": size, "backup_size": bsize,
                                 "short_copy": str(aside)}
        lane.setdefault("notes", []).append(f"spec restored from backup ({size} -> {bsize} bytes)")
        return [f"SPEC_RESTORED={rel}（{size} 字节 → 备份的 {bsize} 字节；原来的短版本存到 {aside}）"]
    if size == 0:
        return [f"WARN=spec {rel} 是 0 字节，没有可用的备份"]
    try:
        write_atomic(bk, cur.read_bytes())
    except OSError as e:
        return [f"WARN=spec 备份没写成（{e}），沿用上一份备份"]
    lane["spec_backup"] = {"rel": rel, "size": size, "at": now_iso()}
    return []


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
        if op.get("name") == "launch":
            return "preparing", f"launch 正在检查环境（pid {op.get('pid')}，{op.get('started_at', '')} 起）"
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
        model = f"，模型 {proc['model']}" if proc.get("model") else ""
        if proc_matches(proc.get("pid"), proc.get("pid_start"), ("superh",)):
            return "working", f"worker 运行中（第 {proc.get('attempt')} 次{model}）"
        if _worker_child_alive(ctx, proc):
            # the launcher died but claude is still working in the worktree:
            # reporting `crashed` here would get a second worker started next to it
            return "working", (f"worker 运行中（第 {proc.get('attempt')} 次{model}；launch 进程已退出，"
                               f"claude 进程 {proc.get('child_pid')} 仍在运行）")
        if not res or res.get("attempt") != proc.get("attempt"):
            ev = _disk_evidence(ctx, proc, None, logs=True)
            if ev:
                return "disk_full", f"worker 进程已消失但没有落盘退出码，像是磁盘写满：{ev}"
            return "crashed", "worker 进程已消失但没有落盘退出码（宿主会话结束或被杀）"
        # the worker reported before it went away: its report stands
    if not res or res.get("attempt") != proc.get("attempt"):
        ev = _disk_evidence(ctx, proc, None, logs=True)
        if ev:
            return "disk_full", f"worker 退出（exit={proc.get('exit_code')}）但没有回报，像是磁盘写满：{ev}"
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
    if st == "disk_full":
        return "disk_full", res.get("summary", "") or "worker 回报磁盘写满"
    if st in ("blocked", "failed"):
        ev = _disk_evidence(ctx, proc, res, logs=False)
        if ev:
            return "disk_full", f"worker 回报 {st}，像是磁盘写满（{ev}）：{res.get('summary', '')}"
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
    "ledger": ("cd {wt}，打开 hold_reason 里的 deferred-work.md，对照 lane 原来的版本把列出的 FU 的状态和历史行"
               "挪回各自名下并 commit" + _REINTEGRATE + "（lane 有了新提交就不再比对）"),
    "ff": "ff 合并失败，按 hold_reason 处理" + _REINTEGRATE,
    "disk": ("合流验证连续几次因为磁盘写满失败，先腾出空间（" + SH_CMD + " disk 看余量）" + _REINTEGRATE),
    "retry-limit": "合流连续重试仍不成功，按 hold_reason 核对 sprint 分支和 lane 分支" + _REINTEGRATE,
    "git-error": "合流时 git 命令出错，按 hold_reason 处理" + _REINTEGRATE,
    "error": "合流时脚本出错，按 hold_reason 处理" + _REINTEGRATE,
    "env": ("worker 启动前环境没就绪（env_check_command / env_up_command），按 hold_reason 把环境起好，"
            "然后执行 " + SH_CMD + " retry {key}"),
    "resource": ("worker 启动前 resource_acquire 失败，按 hold_reason 把资源准备好，然后执行 " + SH_CMD + " retry {key}"),
    "verify-env": ("合流验证前环境没就绪（env_check_command / env_up_command），按 hold_reason 把环境起好"
                   + _REINTEGRATE),
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
    if lane.get("phase") not in ("held", "conflict", "done", "abandoned") and lane_stage(ctx, lane)[0] == "disk_full":
        n = int(lane.get("disk_retries") or 0)
        auto = (f"余量回到阈值以上后调度者会自动 retry（还剩 {MAX_DISK_RETRIES - n} 次）"
                if n < MAX_DISK_RETRIES else f"已自动重试 {n} 次")
        return (f"腾出磁盘空间（{SH_CMD} disk 看余量），{auto}；手工重排：{SH_CMD} retry {lane['key']}，"
                f"或 {SH_CMD} retry --disk-full 一次重排所有磁盘写满的 lane")
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
    # blocked_policy=continue: a lane waiting for a person no longer holds back the
    # implicit orders (serial, epic barrier, retro barrier). Explicit deps still wait.
    stuck = set()
    if cfg.get("blocked_policy") == "continue":
        stuck = {k for k in active_lane if lane_stage(ctx, lanes[k])[0] in STUCK_STAGES}

    def _order_ok(t):
        return t["status"] in settled or t["key"] in stuck

    holders = resource_holders(ctx, lanes)

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
                               and not _order_ok(t)})
                for pe in pend:
                    reasons.append(f"epic {pe} 还有未完成的 story")
                if cfg.get("retro_barrier"):
                    # an epic whose only unfinished stories are stuck cannot have its
                    # retro yet; with blocked_policy=continue it doesn't hold the next epic
                    stuck_epics = {epic_of(k) for k in stuck if status.get(k) not in settled}
                    for pe in sorted({epic_of(t["key"]) for t in stories
                                      if epic_of(t["key"]) is not None and epic_of(t["key"]) < e}):
                        rs = epics.get(f"epic-{pe}-retrospective")
                        if rs is not None and rs != "done" and pe not in pend and pe not in stuck_epics:
                            reasons.append(f"epic {pe} 的 retro 还没 done")
            deps = row["deps"]
            if deps is None:
                if cfg.get("no_deps_policy") == "serial":
                    earlier = [t["key"] for t in stories[:idx] if not _order_ok(t)]
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
            for res in sorted(story_resources(cfg, k)):
                if holders.get(res) not in (None, k):
                    reasons.append(f"等待资源 {res}（{holders[res]} 正在用）")
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
          f"epic_barrier={ctx.config.get('epic_barrier', True)} retro_barrier={ctx.config['retro_barrier']} "
          f"blocked_policy={ctx.config.get('blocked_policy')}")
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
    # issue #31: below disk_min_free_gb no new lane starts and no integrate runs
    # (verify_command compiles); lanes already working are left alone.
    disk = disk_state(ctx, update=True)
    disk_low = not disk["ok"]
    deferred_integrate = integrate if disk_low else []
    if disk_low:
        integrate = []
    disk_full = sorted(k for k, (s, _) in stages.items() if s == "disk_full")
    disk_retry = [] if disk_low else [k for k in disk_full
                                      if int(lanes[k].get("disk_retries") or 0) < MAX_DISK_RETRIES]
    cleanup_cmd = str(ctx.config.get("disk_cleanup_command") or "").strip()
    cleanup_due = bool(disk_low and cleanup_cmd and not (read_json(ctx.state / DISK_FILE) or {}).get("cleanup_ran"))
    busy = len(running) + len(queued) + len(reprepare) + len(live_prepare)
    free = max(0, ctx.config["max_slots"] - busy)
    ready = [r["key"] for r in rows if r["state"] == "ready"]
    # two ready stories that declare the same resource never start together
    taken = set().union(*(story_resources(ctx.config, k) for k in reprepare)) if reprepare else set()
    picked = []
    for k in ready:
        if len(picked) >= free:
            break
        rs = story_resources(ctx.config, k)
        if rs & taken:
            continue
        picked.append(k)
        taken |= rs
    # post_epic_command must not run under a working lane: no new workers until it ran
    post_epic = [] if not str(ctx.config.get("post_epic_command") or "").strip() else _post_epic_state(ctx)["pending"]
    # an interrupted prepare already holds its slot; prepare rolls it back and redoes it
    launch = [] if quota_hold or post_epic or disk_low else reprepare + picked
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
    elif post_epic and not (running or live_prepare or live_integrate):
        nxt = "post-epic"
    elif disk_low and not (running or live_prepare or live_integrate) and (
            deferred_integrate or queued or ready or reprepare or pending):
        # nothing is compiling: the one moment a cleanup can't pull a cache from under a lane
        nxt = "disk-cleanup" if cleanup_due else "disk-low"
    elif disk_retry and not quota_hold:
        nxt = "disk-retry"
    elif (launch or queued) and not quota_hold and not post_epic and not disk_low:
        nxt = "launch"
    elif running or live_prepare or live_integrate or merged or integrate or retro_due or post_epic:
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
        "queued": queued if not quota_hold and not post_epic and not disk_low else [],
        "post_epic": post_epic,
        "epic_start": epic_start,
        "retro_due": retro_due,
        "running": running,
        "preparing": live_prepare,
        "integrating": live_integrate,
        "orphaned": orphaned,
        "attention": attention,
        "quota_hold": quota_hold,
        "disk": {**disk, "cleanup_due": cleanup_due, "deferred_integrate": deferred_integrate},
        "disk_full": disk_full,
        "disk_retry": disk_retry,
        "pending_count": len(pending),
        "waiting": [{"key": r["key"], "reasons": r["reasons"]} for r in rows if r["state"] == "waiting"][:20],
        "external": [{"key": r["key"], "conditions": r["external"]} for r in rows if r["external"]],
        "parked": [r["key"] for r in rows if r["state"] == "parked"],
        # lanes that no longer hold back the serial order / barriers (blocked_policy=continue)
        "stuck_released": sorted(k for k, (s, _) in stages.items() if s in STUCK_STAGES)
        if ctx.config.get("blocked_policy") == "continue" else [],
        "decisions_pending": [r["id"] for r in _pending(ctx)],
        "problems": problems,
    }, ensure_ascii=False, indent=2))
    return 0


def cmd_board(ctx, a):
    rows, lanes, retro_due, _ = analyze(ctx)
    stages = {k: lane_stage(ctx, l) for k, l in lanes.items()}
    order = {s: i for i, s in enumerate(PERSON_STAGES + ("ready", "integrating", "working", "preparing", "queued", "done", "abandoned"))}
    items = sorted(stages.items(), key=lambda kv: (order.get(kv[1][0], 99), kv[0]))
    pending = _pending(ctx)
    if a.json:
        print(json.dumps([{"key": k, "stage": s, "detail": d, "takeover": resume_hint(ctx, lanes[k])}
                          for k, (s, d) in items], ensure_ascii=False, indent=2))
        return 0
    zh = {"conflict": "合流冲突", "held": "已挂起", "blocked": "受阻", "failed": "失败", "quota": "配额耗尽",
          "crashed": "进程丢失", "disk_full": "磁盘写满", "ready": "待合流", "integrating": "合流中", "working": "执行中",
          "preparing": "准备中", "queued": "排队", "done": "完成", "abandoned": "已放弃"}
    ds = disk_state(ctx)
    if not ds["ok"]:
        st = read_json(ctx.state / DISK_FILE) or {}
        print(f"磁盘余量不足：{disk_text(ds)}。不派发新 lane，合流暂缓，在跑的 lane 不受影响；余量回来后自动恢复。")
        if st.get("cleanup_ran"):
            print(f"  disk_cleanup_command 已在 {st['cleanup_ran'].get('at', '')} 执行过一次，余量仍不够，需要人工腾出空间")
        elif str(ctx.config.get("disk_cleanup_command") or "").strip():
            print("  在跑的 lane 都结束后会执行一次 disk_cleanup_command")
    person = [(k, s, d) for k, (s, d) in items if s in PERSON_STAGES]
    if person:
        print("需要你处理：")
        for k, s, d in person:
            print(f"  [{zh.get(s, s)}] {k}  {d}")
            print(f"      接手：{resume_hint(ctx, lanes[k])}")
        if any(s == "disk_full" for _k, s, _d in person):
            print(f"  磁盘写满的几路一次重排：{SH_CMD} retry --disk-full")
        if ctx.config.get("blocked_policy") == "continue" and any(s in STUCK_STAGES for _k, s, _d in person):
            print("  （blocked_policy=continue：受阻、失败、挂起、冲突的这几路不挡串行顺序和 epic 屏障，依赖它们的 story 仍在等）")
    else:
        print("没有需要你处理的 lane。")
    if pending:
        print(f"待你确认（已按推荐项继续，{len(pending)} 条）：")
        def cut(t):
            return t if a.full or len(t) <= 80 else t[:78] + "…"
        for r in pending:
            where = "调度" if r["key"] == "-" else f"{r['key']} {r.get('stage', '')}".strip()
            print(f"  {r['id']} [{where}] {cut(r['question'])}")
            print(f"      采用：{cut(r['chosen'])}")
            if r.get("options"):
                print(f"      {_options_label(r)}：{cut(' / '.join(r['options']))}")
            if a.full and r.get("why"):
                print(f"      理由：{r['why']}")
        print(f"  全部确认：{SH_CMD} confirm --all；看全文：{SH_CMD} board --full 或 {SH_CMD} decisions；"
              f"推翻一条：{SH_CMD} override <ID> --answer \"<新决定>\"")
    live = [(k, s, d) for k, (s, d) in items if s in ("ready", "integrating", "working", "preparing", "queued")]
    if live:
        print("进行中：")
        for k, s, d in live:
            print(f"  [{zh.get(s, s)}] {k}  {d}")
    restored = [(k, lanes[k]["spec_restored"]) for k, (s, _d) in items
                if lanes[k].get("spec_restored") and s not in ("done", "abandoned")]
    if restored:
        print("spec 从备份恢复过（发现时只剩很少的字节，可能是磁盘写满时被截断）：")
        for k, r in restored:
            print(f"  {k}  {r.get('rel')}：{r.get('size')} → {r.get('backup_size')} 字节（{r.get('at', '')}），"
                  f"短版本留在 {r.get('short_copy')}")
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
    gate = _disk_gate(ctx, "这一路先不开 worktree")
    if gate is not None:
        return gate
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
    notes = (read_json(_notes_path(ctx, lane["key"])) or {}).get("entries") or []
    subs = {
        "KEY": lane["key"], "WORKTREE": lane["worktree"], "BRANCH": lane["branch"],
        "SPRINT_BRANCH": lane["sprint_branch"], "ATTEMPT": str(attempt),
        "SUPERH": f"python3 {ctx.harness_scripts / 'superh.py'}", "MAIN_ROOT": str(ctx.root),
        "DECISION_MODE": str(ctx.config.get("decision_mode") or "proceed"),
        "CLARIFICATIONS": _clarifications_text(notes) or "（没有）",
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


# issue #21: the worker appends `harness-prompt-suffix.py <stage> --file` output
# (a short reference ending in `[harness-suffix <stage> <sha8>]`) to every
# dispatch that runs bmad-build-auto or the codex fix round. Pasting the full
# suffix by hand went wrong three times: the subagent got a placeholder instead
# of the answer policy and the project context, and nothing noticed. launch now
# reads the worker's own Agent calls from the stream and reports a dispatch that
# carries neither the reference (with its file present) nor the inline suffix.
SUFFIX_MARKER_RE = re.compile(r"\[harness-suffix ([\w-]+) ([0-9a-f]{8})\]")
SUFFIX_NEEDED_HINTS = ("bmad-build-auto", "## Build intent", "codex-review.md", "Codex Review Handling")


def _suffix_audit(ctx, evt):
    """[{description, stage, length, tail}] for the worker's own Agent / Task calls
    in this stream event whose prompt should carry the harness suffix but doesn't."""
    if evt.get("type") != "assistant" or evt.get("parent_tool_use_id"):
        return []
    content = (evt.get("message") or {}).get("content")
    if not isinstance(content, list):
        return []
    out = []
    for block in content:
        if not isinstance(block, dict) or block.get("type") != "tool_use" or block.get("name") not in ("Agent", "Task"):
            continue
        inp = block.get("input") or {}
        prompt = str(inp.get("prompt") or "")
        if not any(h in prompt for h in SUFFIX_NEEDED_HINTS):
            continue
        ok = any((ctx.state / "suffix" / f"{m.group(1)}-{m.group(2)}.md").is_file()
                 for m in SUFFIX_MARKER_RE.finditer(prompt))
        ok = ok or ("代答政策" in prompt and "项目语境" in prompt)
        if ok:
            continue
        if "follow-up review" in prompt or "follow-up" in str(inp.get("description") or "").lower():
            stage = "B3"
        elif "Codex Review Handling" in prompt or "codex-review.md" in prompt:
            stage = "B2.3"
        else:
            stage = "B1"
        out.append({"description": str(inp.get("description") or "")[:120], "stage": stage,
                    "length": len(prompt), "tail": prompt.strip()[-60:].replace("\n", " ")})
    return out


_MODEL_ALIASES = ("opus", "sonnet", "haiku", "fable")


def _model_mismatch(configured: str, actual: str) -> bool:
    """worker_model set but the worker's init event names another model (issue #18)."""
    c = re.sub(r"\[.*?\]$", "", (configured or "").strip().lower())
    a = (actual or "").strip().lower()
    if not c or not a or c in ("default", "opusplan"):
        return False
    if c in _MODEL_ALIASES:
        return c not in a
    return not (a.startswith(c) or c.startswith(a))


def _orphan_containers(wt: Path) -> list:
    """Running docker containers with a mount at or under the lane worktree. Once
    the worker has exited nothing in that lane should still be running: a build
    container a sub-agent started is left behind when `claude -p` exits under it
    (issue #16). Reported, never stopped. No docker, or docker failing, → []."""
    docker = shutil.which("docker")
    if not docker:
        return []
    try:
        ids = subprocess.run([docker, "ps", "-q", "--no-trunc"], capture_output=True, text=True,
                             timeout=15).stdout.split()
        if not ids:
            return []
        info = json.loads(subprocess.run([docker, "inspect", *ids], capture_output=True, text=True,
                                         timeout=15).stdout or "[]")
    except (OSError, subprocess.SubprocessError, ValueError):
        return []
    root = os.path.realpath(wt)
    out = []
    for c in info if isinstance(info, list) else []:
        for m in (c.get("Mounts") or []) if isinstance(c, dict) else []:
            src = os.path.realpath(str(m.get("Source") or "")) if m.get("Source") else ""
            if src and (src == root or src.startswith(root + os.sep)):
                out.append(f"{str(c.get('Id', ''))[:12]} {str(c.get('Name', '')).lstrip('/')}".strip())
                break
    return out


def _print_orphans(wt: Path):
    orphans = _orphan_containers(wt)
    for c in orphans:
        print(f"ORPHAN_CONTAINER={c}")
    if orphans:
        print(f"WARN=还有 {len(orphans)} 个容器挂载着这一路的 worktree，worker 已经退出，它们多半是子 agent 起的、"
              "没人管了。确认后用 docker stop <id> 停掉")


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
    gate = _disk_gate(ctx, "worker 先不启动")
    if gate is not None:
        return gate
    # The env check can take minutes while the lane still reads as `queued`; a
    # launch marker (shown as `preparing`) keeps tick from handing it out again,
    # and a second launch of the same key backs off.
    with _guard(ctx, ".launch.guard"):
        cur = ctx.lane(key) or lane
        if op_live(cur.get("op")):
            print("STATUS=busy")
            print(f"REASON=lane {key} 的 {cur['op'].get('name')} 正在运行（pid {cur['op'].get('pid')}），不要重复启动")
            return EXIT_BUSY
        if cur.get("phase") != lane.get("phase") or cur.get("attempts") != lane.get("attempts"):
            die(f"lane {key} 在这次 launch 开始后被改动过（phase={cur.get('phase')}），不启动")
        if cur.get("op"):
            _reap_dead_op(cur)
        lane = cur
        lane["op"] = op_record("launch")
        ctx.save_lane(lane)
    try:
        env_state = _ensure_env(ctx, lane)
        res_state = _acquire_resources(ctx, lane) if env_state["ok"] else {"ok": True}
    finally:
        lane.pop("op", None)
    if not env_state["ok"]:
        _hold(ctx, lane, "env", f"worker 没有启动：{env_state['detail']}", f"WORKTREE={wt}",
              "ENV_OUTPUT<<", env_state["output"], ">>")
    if env_state["healed"]:
        print(f"SELF_HEAL=env-up {env_state['detail']}")
        lane.setdefault("notes", []).append(f"self-heal before launch: {env_state['detail']}")
    if not res_state["ok"]:
        _hold(ctx, lane, "resource", f"worker 没有启动：{res_state['detail']}", f"WORKTREE={wt}",
              "RESOURCE_OUTPUT<<", res_state["output"], ">>")
    for ln in _spec_guard(ctx, lane, restore=True):
        print(ln)
    attempt = int(lane.get("attempts") or 0) + 1
    prompt = render_worker_prompt(ctx, lane, attempt)
    ctx.logs.mkdir(parents=True, exist_ok=True)
    stem = ctx.logs / f"{key}.attempt-{attempt}"
    write_atomic(Path(f"{stem}.prompt.md"), prompt)
    lane["attempts"] = attempt
    lane["phase"] = "launched"
    ctx.save_lane(lane)
    configured = str(ctx.config.get("worker_model") or "")
    proc_rec = {"key": key, "attempt": attempt, "pid": os.getpid(), "pid_start": proc_start_time(os.getpid()),
                "started_at": now_iso(), "session_id": None, "exit_code": None, "log": f"{stem}.stream.jsonl",
                "model_config": configured or f"(跟随 settings：{_settings_model() or '默认'})"}
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
        log_ok = True
        for line in p.stdout:
            if log_ok:
                try:
                    flog.write(line)
                    flog.flush()
                except OSError as e:
                    # disk full (issue #31): keep draining the worker's output so it isn't
                    # blocked on a full pipe; the error itself is the evidence for disk_full
                    log_ok = False
                    proc_rec["log_write_error"] = str(e)
                    _try_write_json(ctx.lane_path(key, "proc"), proc_rec)
            try:
                evt = json.loads(line)
            except ValueError:
                continue
            if not isinstance(evt, dict):
                continue
            if evt.get("session_id") and not proc_rec.get("session_id"):
                proc_rec["session_id"] = evt["session_id"]
                _try_write_json(ctx.lane_path(key, "proc"), proc_rec)
            if evt.get("type") == "system" and evt.get("subtype") == "init" and evt.get("model") \
                    and not proc_rec.get("model"):
                # the model the worker really runs on (issue #17: an empty worker_model
                # follows ~/.claude/settings.json, which any other session's /model changes)
                proc_rec["model"] = str(evt["model"])
                _try_write_json(ctx.lane_path(key, "proc"), proc_rec)
            if evt.get("type") == "result":
                result_evt = evt
            miss = _suffix_audit(ctx, evt)
            if miss:
                proc_rec.setdefault("suffix_missing", []).extend(miss)
                _try_write_json(ctx.lane_path(key, "proc"), proc_rec)
            kind = _bg_launch_kind(evt)
            if kind:
                bg = proc_rec.setdefault("bg_launches", {})
                bg[kind] = bg.get(kind, 0) + 1
                _try_write_json(ctx.lane_path(key, "proc"), proc_rec)
        rc = p.wait()
    proc_rec["exit_code"] = rc
    proc_rec["ended_at"] = now_iso()
    if result_evt:
        proc_rec["result_text"] = str(result_evt.get("result") or "")[-3000:]
        proc_rec["is_error"] = bool(result_evt.get("is_error"))
        proc_rec["cost_usd"] = result_evt.get("total_cost_usd")
        proc_rec["num_turns"] = result_evt.get("num_turns")
    ds = disk_state(ctx)
    if not ds["ok"]:
        proc_rec["disk_low_at_exit"] = disk_text(ds)
    if not _try_write_json(ctx.lane_path(key, "proc"), proc_rec):
        # nothing left to record it with: lane_stage reads the missing exit code as
        # a lost worker and, with the disk still low, as disk_full
        print("WARN=退出记录没写成（磁盘满？），这一路会显示为进程丢失或磁盘写满")
    cur = ctx.lane(key) or lane
    before = cur.get("spec_backup")
    guard = _spec_guard(ctx, cur, restore=False)
    if cur.get("spec_backup") != before:
        cur["updated_at"] = now_iso()
        _try_write_json(ctx.lane_path(key), cur)
    stage, detail = lane_stage(ctx, ctx.lane(key))
    print(f"LANE={key}")
    print(f"EXIT_CODE={rc}")
    print(f"STAGE={stage}")
    print(f"DETAIL={detail}")
    print(f"SESSION={proc_rec.get('session_id')}")
    print(f"WORKER_MODEL={proc_rec.get('model') or '?'}（配置：{proc_rec['model_config']}）")
    if _model_mismatch(configured, proc_rec.get("model") or ""):
        print(f"WARN=worker 实际用的模型 {proc_rec.get('model')} 和 parallel.yaml 的 worker_model {configured} 对不上，"
              "检查 claude 版本是否认得这个模型名，或者 ANTHROPIC_MODEL 之类的环境变量是否改掉了它")
    for ln in guard:
        print(ln)
    if stage == "disk_full":
        print(f"DISK=low（{disk_text(ds)}）" if not ds["ok"] else "DISK=ok")
    for m in proc_rec.get("suffix_missing") or []:
        print(f"PROMPT_SUFFIX_MISSING={m['stage']} {m['description']}（prompt {m['length']} 字，结尾：{m['tail']}）")
    if proc_rec.get("suffix_missing"):
        _audit_suffix_decisions(ctx, key, proc_rec["suffix_missing"], attempt)
    _import_spec_decisions_lane(ctx, ctx.lane(key) or lane)
    _print_orphans(wt)
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


# issue #30: deferred-work.md is append-only per FU, not per file. A lane that adds
# a history line to the ledger's last FU and a sprint branch that appended a new
# section both insert at the end of the file; a line-level union then puts the
# lane's history line under the sprint branch's last FU. The ledger is therefore
# merged FU by FU: the union keeps the layout and every non-FU line, then each FU
# block is replaced by the 3-way merge of that one block. After the rebase the
# same per-FU rule checks the result (it also catches a clean git merge that
# placed a line wrongly) and holds the lane on any mismatch.
_FU_HEAD_RE = re.compile(r"^- \*\*(FU-[^*\s]+)\*\*")


def _fu_segments(text: str) -> list:
    """Split a ledger into ['text', None, lines] / ['fu', id, lines] segments. A FU
    block is its head line plus the indented and blank lines after it; trailing
    blank lines belong to the text that follows, not to the block."""
    segs, cur = [], None
    for ln in text.splitlines(keepends=True):
        m = _FU_HEAD_RE.match(ln)
        if m:
            cur = ["fu", m.group(1), [ln]]
            segs.append(cur)
        elif cur is not None and (not ln.strip() or ln[:1] in (" ", "\t")):
            cur[2].append(ln)
        else:
            cur = None
            if segs and segs[-1][0] == "text":
                segs[-1][2].append(ln)
            else:
                segs.append(["text", None, [ln]])
    out = []
    for kind, fid, lines in segs:
        if kind == "fu":
            k = len(lines)
            while k > 1 and not lines[k - 1].strip():
                k -= 1
            out.append(["fu", fid, lines[:k]])
            if lines[k:]:
                out.append(["text", None, lines[k:]])
        else:
            out.append([kind, fid, lines])
    return out


def _fu_blocks(text: str) -> tuple[dict, set]:
    """FU id → block lines (without line endings), and the ids that occur twice."""
    blocks, dups = {}, set()
    for kind, fid, lines in _fu_segments(text):
        if kind != "fu":
            continue
        if fid in blocks:
            dups.add(fid)
        blocks[fid] = tuple(ln.rstrip("\r\n") for ln in lines)
    return blocks, dups


def _merge_file(base: bytes, ours: bytes, theirs: bytes, union: bool = False) -> tuple[bytes, int]:
    with tempfile.TemporaryDirectory() as td:
        paths = []
        for nm, data in (("ours", ours), ("base", base), ("theirs", theirs)):
            p = Path(td) / nm
            p.write_bytes(data)
            paths.append(str(p))
        mr = subprocess.run(["git", "merge-file", "-p", *(["--union"] if union else []), *paths],
                            capture_output=True)
    if mr.returncode < 0 or mr.returncode > 127:
        # an error, not a conflict count: its stdout may be empty or cut short
        # (e.g. the temp dir hit a full disk) and must never become the ledger
        raise RuntimeError(f"git merge-file 出错（exit={mr.returncode}）：{mr.stderr.decode('utf-8', 'replace').strip()[:300]}")
    return mr.stdout, mr.returncode


def _merge_fu_block(b, o, t):
    """3-way merge of one FU block (tuples of lines, None = absent).
    Returns (merged lines or None, clean)."""
    if o == t:
        return o, True
    if b == o:
        return t, True
    if b == t:
        return o, True
    if o is None or t is None:  # one side dropped it, the other changed it
        return (t if o is None else o), False

    def enc(x):
        return "".join(ln + "\n" for ln in (x or ())).encode()
    out, rc = _merge_file(enc(b), enc(o), enc(t))
    if rc != 0:
        out, _ = _merge_file(enc(b), enc(o), enc(t), union=True)
    return tuple(out.decode().splitlines()), rc == 0


def _merge_ledger(base: bytes, ours: bytes, theirs: bytes) -> tuple[bytes, str]:
    """Merge deferred-work.md FU by FU (see the comment above _FU_HEAD_RE).
    Returns (content, how) — how is 'per-FU' or, when the ledger cannot be keyed
    by FU id (not UTF-8, an id that occurs twice), 'union' (plain line union)."""
    union, _ = _merge_file(base, ours, theirs, union=True)
    try:
        bt, ot, tt, ut = (x.decode() for x in (base, ours, theirs, union))
    except UnicodeDecodeError:
        return union, "union"
    (bb, d1), (ob, d2), (tb, d3) = _fu_blocks(bt), _fu_blocks(ot), _fu_blocks(tt)
    if d1 or d2 or d3:
        return union, "union"
    out, seen = [], set()
    for kind, fid, lines in _fu_segments(ut):
        if kind != "fu":
            out.extend(lines)
            continue
        if fid in seen:  # both sides changed the head line: the union wrote it twice
            continue
        seen.add(fid)
        merged, _clean = _merge_fu_block(bb.get(fid), ob.get(fid), tb.get(fid))
        if merged is not None:
            out.extend(ln + "\n" for ln in merged)
    return "".join(out).encode(), "per-FU"


def _ledger_mismatches(base: bytes, lane: bytes, sprint: bytes, result: bytes) -> list:
    """FU ids whose block in `result` (the rebased lane) is not what the lane and
    the sprint branch each made of it: a FU only the lane changed must equal the
    lane's version, a FU the lane did not change must equal the sprint branch's.
    A FU both changed must equal their clean 3-way merge; when that conflicts,
    every line either side added must be there and nothing from elsewhere."""
    try:
        (bb, d1), (lb, d2), (sb, d3), (rb, d4) = (_fu_blocks(x.decode()) for x in (base, lane, sprint, result))
    except UnicodeDecodeError:
        return []
    bad = sorted(d4 - d1 - d2 - d3)
    skip = d1 | d2 | d3 | d4
    for fid in sorted(set(bb) | set(lb) | set(sb) | set(rb)):
        if fid in skip:
            continue
        b, l, s, r = bb.get(fid), lb.get(fid), sb.get(fid), rb.get(fid)
        if b == l or l == s:
            exp = s
        elif b == s:
            exp = l
        else:
            exp, clean = _merge_fu_block(b, s, l)
            if not clean:
                have, was = set(r or ()), set(b or ())
                added = (set(l or ()) - was) | (set(s or ()) - was)
                if r is None or not added <= have or not have <= was | set(l or ()) | set(s or ()):
                    bad.append(fid)
                continue
        if r != exp:
            bad.append(fid)
    return bad


def _blob_at(ctx, rev: str, path: str) -> bytes:
    r = subprocess.run(["git", "show", f"{rev}:{path}"], cwd=ctx.root, capture_output=True)
    return r.stdout if r.returncode == 0 else b""


def _check_ledger(ctx, lane, wt: Path):
    """After a rebase: every FU in deferred-work.md still carries what the lane and
    the sprint branch wrote under it (issue #30); otherwise hold the lane."""
    src, onto = lane.get("rebase_from"), lane.get("onto")
    if not (lane.get("rebased") and src and onto):
        return
    head = git(["rev-parse", lane["branch"]], cwd=ctx.root).stdout.strip()
    if lane.get("ledger_hold_head") and lane["ledger_hold_head"] != head:
        # the person committed a fix after the hold: their ledger is the answer
        lane.setdefault("notes", []).append(f"ledger check skipped: lane changed after the hold ({head[:12]})")
        lane.pop("ledger_hold_head", None)
        ctx.save_lane(lane)
        return
    base = git(["merge-base", src, onto], cwd=ctx.root).stdout.strip()
    if not base:
        return
    path = ctx.artifacts_rel().rstrip("/") + "/" + LEDGER_UNION[0]
    bad = _ledger_mismatches(*(_blob_at(ctx, rev, path) for rev in (base, src, onto, head)))
    if not bad:
        lane.pop("ledger_hold_head", None)
        return
    lane["ledger_hold_head"] = head
    shown = "、".join(bad[:10]) + (f" 等 {len(bad)} 条" if len(bad) > 10 else "")
    _hold(ctx, lane, "ledger",
          f"合流 rebase 后 {path} 里这些 FU 的内容和 lane、sprint 分支各自写的对不上：{shown}；sprint 分支未改动",
          f"WORKTREE={wt}", f"LEDGER={path}", *[f"LEDGER_FU={f}" for f in bad],
          f"LANE_VERSION={src}", f"SPRINT_VERSION={onto}")


def _auto_resolve(ctx, wt: Path, artifacts_rel: str):
    """Resolve conflicts in the shared ledgers. During a rebase, stage 2 ('ours') is
    the sprint branch being rebased onto, stage 3 ('theirs') the story's commit.
      sprint-status.yaml / epic-N-context.md → sprint 分支版本（build-sync 会把本 story 的状态写回）
      deferred-work.md                        → 按 FU 三方合并（追加型账本，issue #30）
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
            merged, how = _merge_ledger(_stage_blob(wt, 1, f) or b"", _stage_blob(wt, 2, f) or b"",
                                        _stage_blob(wt, 3, f) or b"")
            write_atomic(wt / f, merged)
            git(["add", "--", f], cwd=wt)
            resolved.append(f"{f} (按 FU 合并)" if how == "per-FU" else f"{f} (union 合并，账本里有重复的 FU id)")
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


# issue #25: integrate rebases a lane whose base fell behind the sprint branch,
# and every lane commit gets a new hash. The spec (follow-up / codex handling
# notes) and the codex report frontmatter (`head:`) still cite the lane-side
# hashes, which end up on no branch. The commits are matched by author, author
# date and subject (a rebase keeps all three; patch-id does not survive a replay
# onto a moved base), the pairs are kept on the lane, appended to the spec as a
# table and added to the codex report as `head_rebased:`. The original text is
# not rewritten.

def _commit_keys(ctx, rng: str) -> list:
    r = git(["log", "--reverse", "--format=%H%x1f%an%x1f%ae%x1f%at%x1f%s", rng], cwd=ctx.root)
    out = []
    for ln in r.stdout.splitlines():
        parts = ln.split("\x1f")
        if len(parts) == 5:
            out.append((parts[0], tuple(parts[1:]), parts[4]))
    return out


def _rewritten(lane, sha: str):
    sha = (sha or "").strip().lower()
    if len(sha) < 7:
        return None
    for p in lane.get("rewrites") or []:
        if p["old"].startswith(sha) or sha.startswith(p["old"]):
            return p["new"]
    return None


def _record_rewrites(ctx, lane, wt: Path):
    key, branch = lane["key"], lane["branch"]
    old = _commit_keys(ctx, f"{lane['base']}..{lane['orig_head']}")
    new = {k: sha for sha, k, _ in _commit_keys(ctx, f"{lane['onto']}..{branch}")}
    pairs = [{"old": sha, "new": new[k], "subject": subj} for sha, k, subj in old if k in new and new[k] != sha]
    lane["rewrites"] = pairs
    ctx.save_lane(lane)
    if not pairs:
        return
    onto12 = lane["onto"][:12]
    title = f"合流 rebase 后的提交对应（sprint 分支 {onto12}）"
    rel = _lane_spec(ctx, key, wt)
    touched = []
    if rel and (wt / rel).is_file():
        text = (wt / rel).read_text(encoding="utf-8")
        # a table for an earlier onto (sprint branch moved, rebased again) is stale
        text_wo = re.sub(r"(?ms)^### 合流 rebase 后的提交对应（(?!sprint 分支 " + re.escape(onto12) + r"）).*?(?=^#{1,3} |\Z)",
                         "", text).rstrip("\n") + "\n"
        if title not in text:
            text = text_wo
            rows = [f"### {title}", "",
                    f"合流时这一路被 rebase 到 sprint 分支的 {onto12} 上，下面这些提交换了 hash。"
                    "本文和 codex 报告里引用的旧 hash 按这张表找 sprint 分支上的提交（原文不改）。", "",
                    "| lane 内的旧 hash | sprint 分支上的新 hash | 提交说明 |", "|---|---|---|"]
            for p in pairs:
                rows.append(f"| {p['old'][:12]} | {p['new'][:12]} | {p['subject'].replace('|', '/')[:120]} |")
            write_atomic(wt / rel, _with_block(text, "\n".join(rows), inside_contract=False))
            touched.append(rel)
    rep = f"{ctx.artifacts_rel().rstrip('/')}/{key}.codex-review.md"
    if (wt / rep).is_file():
        text = (wt / rep).read_text(encoding="utf-8")
        fm = re.match(r"^---\r?\n(.*?\r?\n)---\r?\n", text, re.S)
        hm = re.search(r"(?m)^head:[ \t]*['\"]?([0-9a-fA-F]{7,40})['\"]?[ \t]*(\r?)$", fm.group(1)) if fm else None
        moved = _rewritten(lane, hm.group(1)) if hm else None
        if moved and not re.search(r"(?m)^head_rebased:", fm.group(1)):
            at = fm.start(1) + hm.end()
            text = text[:at] + f"\nhead_rebased: {moved}" + (hm.group(2) or "") + text[at:]
            write_atomic(wt / rep, text)
            touched.append(rep)
    for p in pairs:
        print(f"REWRITTEN={p['old'][:12]} → {p['new'][:12]} {p['subject'][:80]}")
    if touched:
        r = git(["add", "--", *touched], cwd=wt)
        if r.returncode == 0:
            r = git(["commit", "-q", "-m", f"docs({key}): record commit hashes rewritten by the integrate rebase"], cwd=wt)
        if r.returncode != 0:
            # a record of the rewrite is not worth holding the merge for
            git(["reset", "-q", "--", *touched], cwd=wt)
            git(["checkout", "-q", "--", *touched], cwd=wt)
            print(f"WARN=没能把提交对应表写进 {', '.join(touched)}（{(r.stderr or r.stdout).strip()[-200:]}），"
                  "对应关系只记在 lane 状态的 rewrites 里")
            return
        head = git(["rev-parse", "HEAD"], cwd=wt).stdout.strip()
        if head:
            lane.setdefault("notes", []).append(f"rewrites recorded in {', '.join(touched)} ({head[:12]})")
            ctx.save_lane(lane)
            print(f"REWRITE_RECORDED={head[:12]} {' '.join(touched)}")


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
    env_state = _ensure_env(ctx, lane)
    if not env_state["ok"]:
        return {"status": "env-failed", "detail": f"合流验证没有运行：{env_state['detail']}", "output": env_state["output"]}
    if env_state["healed"]:
        print(f"SELF_HEAL=env-up {env_state['detail']}")
        lane.setdefault("notes", []).append(f"self-heal before verify: {env_state['detail']}")
    env = dict(os.environ, SUPERH_KEY=lane["key"], SUPERH_WORKTREE=str(wt), SUPERH_MAIN_ROOT=str(ctx.root))
    timeout = int(ctx.config.get("verify_timeout_sec") or 1800)
    retries = int(ctx.config.get("verify_timeout_retries") or 0)
    for n in range(retries + 1):
        pr = run_group(["sh", "-c", cmd], cwd=wt, env=env, timeout=timeout, on_start=_record_child(ctx, lane))
        out = (pr["out"] + pr["err"])[-4000:]
        if pr["timed_out"] and n < retries:
            # a hung test is usually a one-off; a real failure (exit != 0) is never re-run
            print(f"SELF_HEAL=verify-timeout-retry verify_command 第 {n + 1} 次超时（{timeout}s），重跑一次")
            lane.setdefault("notes", []).append(f"self-heal: verify_command timed out, re-run #{n + 1}")
            continue
        if pr["timed_out"]:
            return {"status": "failed", "output": out,
                    "detail": f"verify_command 超时（{timeout}s，跑了 {n + 1} 次，它的整个进程组已结束）"}
        if pr["rc"] != 0:
            return {"status": "failed", "detail": f"verify_command exit={pr['rc']}", "output": out}
        return {"status": "passed"}
    return {"status": "failed", "detail": "verify_command 没有运行", "output": ""}


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
    m = re.search(r"(?m)^BASELINE_REVISION=(\S+)", bv_out or "")
    if m:
        moved = _rewritten(lane, m.group(1))
        if moved:
            # B4's codex-skipped marker records the review base: the old hash is off-branch
            print(f"BASELINE_REVISION_REBASED={moved}")
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
    gate = _disk_gate(ctx, "合流先不做（verify_command 要编译）")
    if gate is not None:
        return gate
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


def _verify_disk_full(ctx, lane, wt: Path, what: str, output: str, block: str):
    """build-verify / verify_command failed: if it was the disk, don't hold the
    lane as a code failure (issue #31). It stays `integrating` and is merged
    again once there is room; after MAX_DISK_RETRIES such failures it is held
    with hold_kind=disk. Returns None when the failure doesn't look like ENOSPC."""
    m = ENOSPC_RE.search(output or "")
    ds = disk_state(ctx)
    if not m and ds["ok"]:
        return None
    why = f"输出里有「{m.group(0)}」" if m else f"磁盘余量低于阈值：{disk_text(ds)}"
    n = int(lane.get("disk_verify_failures") or 0) + 1
    lane["disk_verify_failures"] = n
    lane.setdefault("notes", []).append(f"{what} failed on a full disk ({n})")
    if n > MAX_DISK_RETRIES:
        lane.pop("disk_verify_failures", None)
        _hold(ctx, lane, "disk", f"{what}连续 {n} 次因磁盘写满失败（{why}）；sprint 分支未改动",
              f"WORKTREE={wt}", f"{block}<<", output, ">>")
    lane["phase"] = "integrating"
    ctx.save_lane(lane)
    print("STATUS=disk-full")
    print(f"REASON={what}因磁盘写满失败（{why}），不算代码问题；sprint 分支未改动，余量回来后重新合流")
    print(f"WORKTREE={wt}")
    print(f"{block}<<")
    print(output)
    print(">>")
    return EXIT_DISK


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
            # the lane's own commits as the worker left them: spec / codex report
            # cite these hashes, _record_rewrites maps them after the rebase (issue #25)
            lane.setdefault("orig_head", lane_head)
            # the lane as this rebase found it: _check_ledger compares per FU against it
            lane["rebase_from"] = lane_head
            # a new rebase is checked again, even after a person fixed an earlier one
            lane.pop("ledger_hold_head", None)
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
    _check_ledger(ctx, lane, wt)

    rc, bv_out = _build_verify(ctx, lane, wt)
    if rc != 0:
        r = _verify_disk_full(ctx, lane, wt, "rebase 后的 build-verify ", bv_out, "BUILD_VERIFY")
        if r is not None:
            return r
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
    _import_spec_decisions_lane(ctx, lane)
    verify = _run_verify(ctx, lane, wt)
    if verify["status"] == "env-failed":
        _hold(ctx, lane, "verify-env", verify["detail"] + "；sprint 分支未改动", f"WORKTREE={wt}",
              "ENV_OUTPUT<<", verify["output"], ">>")
    if verify["status"] == "failed":
        r = _verify_disk_full(ctx, lane, wt, "合流验证（verify_command）", verify["output"], "VERIFY_OUTPUT")
        if r is not None:
            return r
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
    lane.pop("disk_verify_failures", None)
    if lane.get("rebased") and lane.get("orig_head"):
        # last step before the ff: a held / retried integrate never leaves a
        # table behind that a later rebase would make stale
        _record_rewrites(ctx, lane, wt)
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


# -------------------------------------------------------------- decisions inbox
#
# issue #17: a lane that hits an intent gap no longer stops and waits for the
# user. The worker picks the recommended reading (answer-policy.md), writes it
# into the spec, and the decision lands here as `pending`. The user confirms in
# bulk or overrides one; an override resets that lane to the commit before the
# decision and re-runs it with the new answer. decisions.json is shared by the
# workers (`reopen`), the dispatcher (`decide`, `resume`) and the user
# (`confirm`, `override`); every write goes through one flock.

DECISIONS_FILE = "decisions.json"


def load_decisions(ctx) -> dict:
    d = read_json(ctx.state / DECISIONS_FILE)
    if not isinstance(d, dict) or not isinstance(d.get("items"), list):
        d = {"next_id": 1, "items": []}
    d.setdefault("next_id", len(d["items"]) + 1)
    return d


@contextmanager
def _decisions_txn(ctx):
    """Read-modify-write decisions.json under its flock. An exception inside the
    block leaves the file untouched."""
    with _guard(ctx, ".decisions.guard"):
        d = load_decisions(ctx)
        yield d
        write_json(ctx.state / DECISIONS_FILE, d)


def _new_decisions(ctx, key, items, kind, **extra) -> list:
    out = []
    with _decisions_txn(ctx) as d:
        for it in items:
            rec = {"id": f"D{d['next_id']}", "key": key, "kind": kind, "status": "pending",
                   "question": str(it.get("question") or "").strip(),
                   "options": [str(o) for o in (it.get("options") or [])],
                   "chosen": str(it.get("chosen") or "").strip(),
                   "why": str(it.get("why") or "").strip(),
                   "created_at": now_iso()}
            rec.update(extra)
            d["next_id"] += 1
            d["items"].append(rec)
            out.append(rec)
    return out


def _update_decisions(ctx, ids, **fields):
    with _decisions_txn(ctx) as d:
        for rec in d["items"]:
            if rec["id"] in ids:
                rec.update(fields)


def _drop_decisions(ctx, ids):
    with _decisions_txn(ctx) as d:
        d["items"] = [r for r in d["items"] if r["id"] not in ids]


def _read_decision_items(path: str) -> list:
    """`--decisions-file`: a JSON list of {question, chosen, options?, why?}."""
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as e:
        die(f"读不了 decisions 文件 {path}：{e}")
    if isinstance(data, dict):
        data = data.get("items") or data.get("decisions") or [data]
    if not isinstance(data, list) or not data:
        die("decisions 文件要是一个非空的 JSON 列表，每项至少有 question 和 chosen")
    for i, it in enumerate(data, 1):
        if not isinstance(it, dict) or not str(it.get("question") or "").strip() or not str(it.get("chosen") or "").strip():
            die(f"decisions 文件第 {i} 项缺 question 或 chosen")
        if it.get("options") is not None and not isinstance(it["options"], list):
            die(f"decisions 文件第 {i} 项的 options 要是列表")
    return data


def _audit_suffix_decisions(ctx, key, misses, attempt):
    """issue #21: a dispatch without the harness suffix goes to the inbox instead of
    holding the lane. Its result passed build-verify; what can be wrong is a choice
    the subagent made (or a question it stopped on) without the answer policy."""
    have = {(r.get("attempt"), r.get("question")) for r in load_decisions(ctx)["items"]
            if r["key"] == key and r.get("kind") == "audit"}
    items = []
    for m in misses:
        q = (f"{m['stage']} 的子 agent（{m['description'] or '无描述'}）派发时没带 harness 后缀，拿不到代答政策和项目语境"
             f"（prompt {m['length']} 字，结尾「{m['tail']}」）。它遇到拍板题可能停下，也可能自己定了却没记下来。要不要补跑这一步？")
        if (attempt, q) in have:
            continue
        where = {"B3": "spec 的 follow-up review 记录", "B2.3": "spec 的 Codex Review Handling 段"}.get(m["stage"], "spec 的 Auto Run Result")
        items.append({"question": q, "options": ["不补跑，照常合入", "补跑这一步"],
                      "chosen": f"不补跑，照常合入。请看{where}，有没有该问没问、或者自己定了没写理由的地方",
                      "why": "build-verify 只核对产物，查不出子 agent 有没有拿到代答政策"})
    recs = _new_decisions(ctx, key, items, "audit", stage=misses[0]["stage"], attempt=attempt) if items else []
    if recs:
        print(f"DECISION_IDS={','.join(r['id'] for r in recs)}")
    return recs


def _confirm_ref(it) -> str:
    if it.get("ref"):
        return it["ref"]
    norm = re.sub(r"\s+", " ", it.get("text") or "").strip()
    return "h:" + hashlib.sha1(norm.encode("utf-8")).hexdigest()[:10]


def _import_spec_decisions(ctx, key, spec_path: Path, spec_rel: str = "") -> tuple[list, int]:
    """issue #24: trade-offs the worker settled itself and listed in the spec for
    the user to confirm go into the inbox (kind `spec`). Idempotent: an item is
    recognized by its `[C-n]` id, or by its text when it has none. Returns
    (new records, number of items in the spec)."""
    try:
        items = _harness_spec_mod().spec_confirm_items(str(spec_path))
    except (ImportError, AttributeError):
        return [], 0
    if not items:
        return [], 0
    new = []
    with _decisions_txn(ctx) as d:
        recs = {r.get("spec_ref"): r for r in d["items"] if r["key"] == key and r.get("kind") == "spec"}
        known = {ref: r["id"] for ref, r in recs.items()}
        for it in items:
            ref = _confirm_ref(it)
            if ref in known:
                # issue #27: a row imported before it listed 备选 gets them now
                old = recs.get(ref)
                if old is not None and not old.get("options") and it.get("options"):
                    old["options"] = list(it["options"])
                continue
            merged = it.get("merged_into")
            if merged and merged.startswith("C-"):
                merged = known.get(merged, merged)
            rec = {"id": f"D{d['next_id']}", "key": key, "kind": "spec", "status": "pending",
                   "question": it["question"] or it["text"],
                   "options": list(it.get("options") or []),
                   "chosen": it["chosen"] or "按 spec 里写的做法（worker 已按它实现）",
                   "why": it["why"], "spec_ref": ref, "spec": spec_rel or str(spec_path),
                   "section": it.get("section", ""), "stage": "spec", "created_at": now_iso()}
            if merged:
                rec["merged_into"] = merged
            d["next_id"] += 1
            d["items"].append(rec)
            known[ref] = rec["id"]
            new.append(rec)
    return new, len(items)


def _import_spec_decisions_lane(ctx, lane):
    if not lane or not lane.get("worktree"):
        return []
    wt = Path(lane["worktree"])
    rel = _lane_spec(ctx, lane["key"], wt) if wt.is_dir() else None
    if not rel:
        return []
    new, n = _import_spec_decisions(ctx, lane["key"], wt / rel, rel)
    if new:
        print(f"SPEC_DECISIONS_IMPORTED={','.join(r['id'] for r in new)}")
    if n:
        print(f"SPEC_DECISIONS={n}")
    return new


def cmd_spec_decisions(ctx, a):
    """Import a spec's 待用户确认 items into the inbox (inline mode B4, or by hand)."""
    if a.spec:
        path = Path(a.spec).resolve()
    else:
        top = git(["rev-parse", "--show-toplevel"]).stdout.strip() or str(ctx.root)
        art = Path(top) / ctx.artifacts_rel()
        try:
            name = _harness_spec_mod().resolve_story_md(a.key, str(art))
        except (ImportError, AttributeError):
            name = None
        if not name:
            die(f"没找到 {a.key} 的 spec（{art}），用 --spec 指定")
        path = art / name
    if not path.is_file():
        die(f"spec 不存在：{path}")
    try:
        rel = str(path.relative_to(ctx.root))
    except ValueError:
        rel = str(path)
    new, n = _import_spec_decisions(ctx, a.key, path, rel)
    total = [r for r in load_decisions(ctx)["items"] if r["key"] == a.key and r.get("kind") == "spec"]
    print("STATUS=ok")
    print(f"IMPORTED={','.join(r['id'] for r in new)}")
    print(f"SPEC_ITEMS={n}")
    print(f"INBOX_ITEMS={len(total)}")
    if n != len(total):
        print(f"WARN=spec 里列了 {n} 条待确认，收件箱里这条 story 有 {len(total)} 条：spec 改过条目文字，"
              "或者删掉了条目；用 superh.py decisions --all 核对")
    return 0


# ---------------------------------------------------------------- spec reopen
#
# `reopen` (worker), `resume` (dispatcher) and `override` (user) all end the same
# way: write the answers into the halted spec, flip its status back to where
# bmad-build-auto resumes, commit, and keep harness-state's view consistent
# (followup-start moves onto the new commit, so "HEAD moved past followup-start"
# still means "B3 ran"). A spec that was still uncommitted when bmad-build-auto
# halted is committed as-is first: that commit is the point an override resets to.

def _today() -> str:
    return datetime.date.today().isoformat()


def _wt_dirty(wt: Path) -> list:
    return [ln for ln in git(["status", "--porcelain", "-uall"], cwd=wt).stdout.splitlines() if ln.strip()]


def _porcelain_path(ln: str) -> str:
    p = ln[3:]
    if " -> " in p:
        p = p.split(" -> ", 1)[1]
    return p.strip().strip('"')


def _lane_spec(ctx, key, wt: Path):
    art = ctx.artifacts_rel().rstrip("/")
    try:
        name = _harness_spec_mod().resolve_story_md(key, str(wt / art))
    except (ImportError, AttributeError):
        name = None
    return f"{art}/{name}" if name and name.startswith("spec-") else None


def _lane_results(ctx, wt: Path) -> list:
    art = ctx.artifacts_rel().rstrip("/")
    try:
        return sorted(f"{art}/{f}" for f in os.listdir(wt / art)
                      if f.startswith("bmad-build-auto-result-") and f.endswith(".md"))
    except OSError:
        return []


def _spec_status_of(path: Path):
    try:
        return _harness_spec_mod().spec_status(str(path))
    except (ImportError, AttributeError):
        return None


_FM_STATUS_RE = re.compile(r"(?m)^(status:[ \t]*)(['\"]?)([^'\"\r\n#]*?)\2([ \t]*(?:#[^\r\n]*)?)(\r?)$")


def _with_status(text: str, status: str) -> str:
    m = re.match(r"^---\r?\n(.*?\r?\n)---\r?\n", text, re.S)
    if not m:
        die("spec 没有 frontmatter，改不了 status")
    fm = m.group(1)
    new_fm, n = _FM_STATUS_RE.subn(
        lambda mm: f"{mm.group(1)}{mm.group(2)}{status}{mm.group(2)}{mm.group(4)}{mm.group(5)}", fm, count=1)
    if n == 0:
        new_fm = fm + f"status: {status}" + ("\r\n" if fm.endswith("\r\n") else "\n")
    return text[:m.start(1)] + new_fm + text[m.end(1):]


def _with_block(text: str, block: str, inside_contract: bool) -> str:
    """Clarifications go at the end of <intent-contract>: bmad-build-auto keeps that
    block verbatim when it re-plans a draft. Notes that are not answers go at the
    end of the file."""
    i = text.rfind("</intent-contract>") if inside_contract else -1
    if i < 0:
        return text.rstrip("\n") + "\n\n" + block.rstrip("\n") + "\n"
    return text[:i].rstrip("\n") + "\n\n" + block.rstrip("\n") + "\n\n" + text[i:]


def _clar_block(title: str, entries) -> str:
    lines = [f"### {title}", ""]
    for e in entries:
        if e.get("question"):
            lines.append(f"- Q: {e['question']}")
            lines.append(f"  A: {e['answer']}" + (f"（{e['tag']}）" if e.get("tag") else ""))
        else:
            lines.append(f"- {e['answer']}" + (f"（{e['tag']}）" if e.get("tag") else ""))
    return "\n".join(lines)


def _default_reopen_status(ctx, key) -> str:
    # B1 halted → re-plan from the clarified contract; B3 (review pass on a built
    # story) halted → back into review, the code is already there
    return "in-review" if "built" in harness_tags(ctx).get(key, set()) else "draft"


def _commit(wt: Path, paths_add, paths_rm, subject: str):
    if paths_add:
        r = git(["add", "--", *paths_add], cwd=wt)
        if r.returncode != 0:
            die(f"git add 失败：{r.stderr.strip()}", f"WORKTREE={wt}")
    if paths_rm:
        r = git(["rm", "-q", "--", *paths_rm], cwd=wt)
        if r.returncode != 0:
            die(f"git rm 失败：{r.stderr.strip()}", f"WORKTREE={wt}")
    if git(["diff", "--cached", "--quiet"], cwd=wt).returncode == 0:
        return None
    r = git(["commit", "-q", "-m", subject], cwd=wt)
    if r.returncode != 0:
        die(f"git commit 失败（pre-commit hook？）：{(r.stderr or r.stdout).strip()[:600]}", f"WORKTREE={wt}")
    return git(["rev-parse", "HEAD"], cwd=wt).stdout.strip()


def _notes_path(ctx, key) -> Path:
    return ctx.lane_path(key, "notes")


def _reopen(ctx, lane, *, title: str, entries, status, subject: str, log_line: str = "",
            keep_status_unless_blocked: bool = False) -> dict:
    """Write `entries` (dicts: question?, answer, tag?, id?) into the lane's spec and
    reopen it. Without a spec (bmad-build-auto halted before creating one) the
    answers go to lanes/<KEY>.notes.json, which the next worker prompt carries
    into the B1 intent, and the halt result file is removed.
    Returns {base, head, spec, status, appendix}."""
    key, wt = lane["key"], Path(lane["worktree"])
    if not wt.is_dir():
        die(f"lane worktree {wt} 不存在")
    if _rebase_in_progress(wt):
        die("lane worktree 正处在 rebase 中（合流冲突），先解决或放弃合流", f"WORKTREE={wt}")
    spec = _lane_spec(ctx, key, wt)
    results = _lane_results(ctx, wt)
    dirty = _wt_dirty(wt)
    # bmad-build-auto's step-04 intent-gap branch saves the reverted attempt as an
    # untracked .patch under the artifacts dir. Left there it dirties the tree
    # (bmad-build-auto refuses to start); committed it fails build-verify. Keep it
    # outside the worktree instead of deleting it.
    art = ctx.artifacts_rel().rstrip("/") + "/"
    moved = []
    for ln in list(dirty):
        p = _porcelain_path(ln)
        if ln.startswith("?? ") and p.startswith(art) and p.endswith((".patch", ".diff")):
            dst = ctx.state / "patches" / key / os.path.basename(p)
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(wt / p), str(dst))
            moved.append(str(dst))
            dirty.remove(ln)
    allowed = set(results) | ({spec} if spec else set())
    others = [ln for ln in dirty if _porcelain_path(ln) not in allowed]
    if others:
        die("lane worktree 里除了本 story 的 spec 还有没提交的改动，先处理这些文件（看是不是上次 worker 的半成品）",
            *[f"DIRTY={d}" for d in others[:30]], f"WORKTREE={wt}")
    if not spec and not results:
        die("这一路既没有 spec，也没有 bmad-build-auto-result 文件，没有可以写答复的地方；"
            "worker 还没开始 build 的话直接 retry")
    out = {"spec": spec, "appendix": "", "moved": moved}
    if spec:
        sp = wt / spec
        if any(_porcelain_path(ln) == spec for ln in dirty):
            # keep the halted spec as its own commit: an override resets to it
            _commit(wt, [spec], [], f"docs({key}): record bmad-build-auto halt")
        out["base"] = git(["rev-parse", "HEAD"], cwd=wt).stdout.strip()
        cur = _spec_status_of(sp)
        if keep_status_unless_blocked and cur != "blocked" and not status:
            target = cur
        else:
            target = status or _default_reopen_status(ctx, key)
        text = sp.read_text(encoding="utf-8")
        if entries:
            text = _with_block(text, _clar_block(title, entries), inside_contract=True)
        if log_line:
            text = _with_block(text, f"### Harness resume（{_today()}）\n\n- {log_line}", inside_contract=False)
        if target and target != cur:
            text = _with_status(text, target)
        write_atomic(sp, text)
        tracked_results = [r for r in results if git(["ls-files", "--error-unmatch", "--", r], cwd=wt).returncode == 0]
        for r in results:
            if r not in tracked_results:
                (wt / r).unlink(missing_ok=True)
        head = _commit(wt, [spec], tracked_results, subject)
        out["status"] = target
    else:
        out["base"] = git(["rev-parse", "HEAD"], cwd=wt).stdout.strip()
        notes = read_json(_notes_path(ctx, key)) or {"entries": []}
        drop = {e.get("id") for e in entries if e.get("id")} | {e.get("replaces") for e in entries if e.get("replaces")}
        notes["entries"] = [e for e in notes.get("entries", []) if e.get("id") not in drop] + list(entries)
        write_json(_notes_path(ctx, key), notes)
        tracked_results = [r for r in results if git(["ls-files", "--error-unmatch", "--", r], cwd=wt).returncode == 0]
        for r in results:
            if r not in tracked_results:
                (wt / r).unlink(missing_ok=True)
        head = _commit(wt, [], tracked_results, f"chore({key}): clear bmad-build-auto halt result for resume")
        out["status"] = None
        out["appendix"] = _clarifications_text(notes["entries"])
    out["head"] = head or git(["rev-parse", "HEAD"], cwd=wt).stdout.strip()
    tags = harness_tags(ctx).get(key, set())
    # only while B3 still has to run: a spec left `done` means B3 already ran, and
    # moving the tag onto HEAD would make harness-state dispatch it again
    if "followup-start" in tags and "followup" not in tags and head and out.get("status") not in ("done", None):
        git(["tag", "-f", f"harness/{key}/followup-start", head], cwd=wt)
        out["moved_tag"] = f"harness/{key}/followup-start"
    return out


def _clarifications_text(entries) -> str:
    if not entries:
        return ""
    lines = ["## 已确认的答复", ""]
    for e in entries:
        if e.get("question"):
            lines.append(f"- Q: {e['question']}")
            lines.append(f"  A: {e['answer']}" + (f"（{e['tag']}）" if e.get("tag") else ""))
        else:
            lines.append(f"- {e['answer']}")
    return "\n".join(lines)


def _print_reopened(info):
    print("STATUS=ok")
    if info.get("spec"):
        print(f"SPEC={info['spec']}")
        print(f"SPEC_STATUS={info.get('status')}")
    print(f"BASE={info.get('base', '')}")
    print(f"HEAD={info.get('head', '')}")
    if info.get("moved_tag"):
        print(f"MOVED_TAG={info['moved_tag']}")
    for m in info.get("moved") or []:
        print(f"MOVED_PATCH={m}（bmad-build-auto 停下时保存的尝试改动，挪出 worktree 保存）")
    if info.get("appendix"):
        print("INTENT_APPENDIX<<")
        print(info["appendix"])
        print(">>")


def _in_lane_worktree(lane) -> bool:
    top = git(["rev-parse", "--show-toplevel"]).stdout.strip()
    try:
        return bool(top) and Path(top).resolve() == Path(lane["worktree"]).resolve()
    except OSError:
        return False


def cmd_reopen(ctx, a):
    """Worker-side (pipeline.md §3.3): bmad-build-auto halted on something the
    worker may settle by itself — an intent gap with a recommended reading
    (--decisions-file), or a transient verification failure (--kind transient).
    Writes it into the spec, commits, records the decisions as pending."""
    key = a.key
    lane = ctx.lane(key)
    if not lane:
        die(f"lane {key} 不存在")
    if lane.get("phase") != "launched":
        die(f"lane {key} phase={lane.get('phase')}：reopen 只给正在运行的 worker 用；调度者和用户用 resume")
    if not _in_lane_worktree(lane):
        die(f"reopen 要在这一路的 worktree（{lane['worktree']}）里执行")
    kind = a.kind or ("decision" if a.decisions_file else "transient")
    items = _read_decision_items(a.decisions_file) if a.decisions_file else []
    if kind == "decision":
        if not items:
            die("--kind decision 需要 --decisions-file")
        if ctx.config.get("decision_mode") != "proceed":
            die("parallel.yaml 的 decision_mode 是 ask：不按推荐项续跑，按 pipeline.md §3 回报 blocked")
    counts_path = ctx.lane_path(key, "reopen")
    counts = read_json(counts_path) or {}
    used = int(counts.get(kind, 0))
    if used >= REOPEN_LIMITS[kind]:
        die(f"本 story 已经 reopen（{kind}）{used} 次，到上限了，按 pipeline.md §3 回报 blocked")
    stage = "B3" if "built" in harness_tags(ctx).get(key, set()) else "B1"
    recs = _new_decisions(ctx, key, items, "intent-gap", stage=stage, attempt=lane.get("attempts"),
                          why_reopen=a.why) if items else []
    ids = [r["id"] for r in recs]
    entries = [{"id": r["id"], "question": r["question"], "answer": r["chosen"],
                "tag": f"{r['id']}，按推荐项代答，待确认"} for r in recs]
    try:
        info = _reopen(ctx, lane, title=f"Clarifications（{_today()}，按推荐项代答，待确认）", entries=entries,
                       status=a.status, subject=f"docs({key}): " + (f"按推荐项代答 {', '.join(ids)}（待确认）" if ids
                                                                     else f"reopen spec: {a.why[:60]}"),
                       log_line="" if ids else a.why)
    except SystemExit:
        if ids:
            _drop_decisions(ctx, ids)
        raise
    if ids:
        _update_decisions(ctx, ids, base=info["base"], commit=info["head"], reopen_status=info.get("status"),
                          no_spec=not info.get("spec"), spec=info.get("spec"))
    counts[kind] = used + 1
    write_json(counts_path, counts)
    _print_reopened(info)
    if ids:
        print(f"DECISION_IDS={','.join(ids)}")
    print(f"REOPEN_LEFT={REOPEN_LIMITS[kind] - used - 1}")
    print("NEXT=重新调 harness-state.py，按 pipeline.md §0.B 切入")
    return 0


def cmd_resume(ctx, a):
    """Dispatcher / user: a lane stopped for a person, the person decided. Write the
    decision into the spec, commit, move followup-start, requeue (issue #17 ③)."""
    key = a.key
    lane = ctx.lane(key)
    if not lane:
        die(f"lane {key} 不存在")
    stage, _ = lane_stage(ctx, lane)
    if stage not in ("blocked", "failed", "quota", "crashed") or lane.get("phase") in ("merged", "conflict", "integrating", "held"):
        die(f"lane {key} 阶段 {stage}（phase={lane.get('phase')}）：resume 只用于 worker 停下的 lane"
            + ("；held 的按看板「接手」一行处理" if lane.get("phase") == "held" else ""))
    notes = [n.strip() for n in (a.note or []) if n and n.strip()]
    if not notes:
        die("resume 需要 --note \"<决定>\"（可以写多条）")
    info = _reopen(ctx, lane, title=f"Clarifications（{_today()}，用户决定）",
                   entries=[{"answer": n} for n in notes], status=a.status,
                   subject=f"docs({key}): 记录用户决定，续跑", keep_status_unless_blocked=True)
    _print_orphans(Path(lane["worktree"]))
    lane["phase"] = "prepared"
    lane.pop("hold_reason", None)
    lane.pop("hold_kind", None)
    lane.setdefault("notes", []).append(f"resume after {stage}: " + " / ".join(notes)[:300])
    ctx.save_lane(lane)
    _print_reopened(info)
    return 0


def cmd_decide(ctx, a):
    """Dispatcher-side record-only entry: a choice the dispatcher made itself
    (answer-policy recommended option) instead of asking the user."""
    if a.key != "-" and not any(s["key"] == a.key for s in parse_sprint(ctx.sprint_file())[0]):
        die(f"{a.key} 不是 sprint-status.yaml 里的 story（调度层面的决定用 -）")
    recs = _new_decisions(ctx, a.key, [{"question": a.question, "chosen": a.chosen, "options": a.option or [],
                                        "why": a.why}], "dispatcher")
    print("STATUS=ok")
    print(f"DECISION_ID={recs[0]['id']}")
    return 0


def _options_label(r) -> str:
    """spec rows list only the readings the worker did not take (备选); the other
    kinds list every option, the chosen one included."""
    return "备选" if r.get("kind") == "spec" else "选项"


def _pending(ctx):
    return [r for r in load_decisions(ctx)["items"] if r.get("status") == "pending"]


def cmd_decisions(ctx, a):
    items = load_decisions(ctx)["items"]
    if not a.all:
        items = [r for r in items if r.get("status") == "pending"]
    if a.json:
        print(json.dumps(items, ensure_ascii=False, indent=2))
        return 0
    if not items:
        print("收件箱是空的。" if a.all else "没有待确认的决定。")
        return 0
    for r in items:
        where = "调度" if r["key"] == "-" else f"{r['key']} {r.get('stage', '')}".strip()
        print(f"{r['id']} [{r['status']}] {where}")
        print(f"    问题：{r['question']}")
        if r.get("options"):
            print(f"    {_options_label(r)}：{' / '.join(r['options'])}")
        print(f"    采用：{r['chosen']}" + (f"（{r['why']}）" if r.get("why") else ""))
        if r.get("kind") == "spec":
            print(f"    来源：spec {r.get('spec', '')}「{r.get('section', '')}」"
                  + (f" {r['spec_ref']}" if str(r.get("spec_ref", "")).startswith("C-") else ""))
        if r.get("merged_into"):
            print(f"    并入：{r['merged_into']}（同一件事，确认 / 推翻时一起看）")
        if r.get("commit"):
            print(f"    提交：{r['commit'][:12]}")
        if r.get("answer"):
            print(f"    改判：{r['answer']}")
    return 0


def cmd_confirm(ctx, a):
    with _decisions_txn(ctx) as d:
        pend = [r for r in d["items"] if r.get("status") == "pending"]
        if a.all:
            hit = [r for r in pend if not a.key or r["key"] == a.key]
        else:
            want = set(a.ids or [])
            if not want:
                die("confirm 需要决定编号（D3 D4）或 --all")
            known = {r["id"]: r for r in d["items"]}
            missing = sorted(want - set(known))
            if missing:
                die(f"没有这些决定：{', '.join(missing)}")
            hit = [known[i] for i in sorted(want) if known[i].get("status") == "pending"]
        for r in hit:
            r["status"] = "confirmed"
            r["resolved_at"] = now_iso()
    print("STATUS=ok")
    print(f"CONFIRMED={','.join(r['id'] for r in hit)}")
    return 0


def cmd_override(ctx, a):
    """The user disagrees with decision <ID>. Dispatcher decisions and merged lanes
    are only marked (the fix is a new change); a lane that is not merged yet is
    reset to the commit before the decision and re-run with the new answer."""
    recs = {r["id"]: r for r in load_decisions(ctx)["items"]}
    d = recs.get(a.id)
    if not d:
        die(f"没有决定 {a.id}")
    if d.get("status") not in ("pending", "confirmed"):
        die(f"{a.id} 已经是 {d.get('status')}")
    answer = (a.answer or "").strip()
    if not answer:
        die("override 需要 --answer \"<新决定>\"")
    mark = dict(status="overridden", answer=answer, resolved_at=now_iso())
    key = d["key"]
    lane = ctx.lane(key) if key != "-" else None
    if key == "-" or d.get("kind") == "dispatcher":
        _update_decisions(ctx, {a.id}, **mark)
        print("STATUS=ok")
        print("NEXT=dispatcher")
        print("REASON=这是调度者自己做的决定，没有对应的 lane 提交；调度者下一轮读 decisions 按新决定处理")
        return 0
    if d.get("kind") in ("audit", "spec"):
        # nothing to reset to: the worker made this choice (or skipped the suffix)
        # without stopping, the code that follows from it is already in the lane
        _update_decisions(ctx, {a.id}, needs_followup=True, **mark)
        print("STATUS=ok")
        print("NEXT=manual")
        if d.get("kind") == "spec":
            print(f"REASON={a.id} 是 worker 自己定下、写在 spec 里的取舍，没有可回退的提交；"
                  "按新决定开一条修正 chore 或 story（这一路还没合入时也可以 abandon 后让它重跑）")
        else:
            print(f"REASON={a.id} 记的是 {d.get('stage', '')} 派发时漏了 harness 后缀；要补跑就在这一路合入后"
                  "按 spec 手工复核，或开一条复审 chore")
        if d.get("spec"):
            print(f"SPEC={d['spec']}")
        return 0
    if not lane or lane.get("phase") in ("merged", "done", "abandoned"):
        _update_decisions(ctx, {a.id}, needs_followup=True, **mark)
        print("STATUS=ok")
        print("NEXT=manual")
        print(f"REASON={key} 已经合入 sprint 分支（或这一路已不在），不能再回退这一路；"
              "按新决定开一条修正 story，或者手工改")
        if d.get("commit"):
            print(f"DECISION_COMMIT={d['commit']}")
        return 0
    stage, _ = lane_stage(ctx, lane)
    if stage in ("working", "preparing", "integrating") or op_live(lane.get("op")):
        print("STATUS=busy")
        print(f"REASON={key} 正在{stage}，等这一路停下（看板上变成待合流、受阻或失败）再 override")
        return EXIT_BUSY
    if lane.get("phase") == "conflict" or _rebase_in_progress(Path(lane["worktree"])):
        die(f"{key} 处在合流冲突中，先解决冲突或 abandon 再 override")
    if lane.get("rebased"):
        # integrate rebased the lane and moved its tags onto the rewritten commits:
        # the recorded base is no longer on this branch's history
        die(f"{key} 已经在合流时 rebase 过，{a.id} 记录的回退点不在现在的分支上；"
            f"按看板「接手」一行处理，或 abandon 后让这条 story 重跑")
    wt = Path(lane["worktree"])
    base = d.get("base")
    if not base or git(["cat-file", "-e", f"{base}^{{commit}}"], cwd=wt).returncode != 0:
        die(f"{a.id} 没有记录可回退的提交（base），只能手工处理")
    if not _is_ancestor(ctx, base, git(["rev-parse", "HEAD"], cwd=wt).stdout.strip()):
        die(f"{a.id} 的回退点 {base[:12]} 不在 {key} 现在的分支上，只能手工处理")
    spec_at_base = None
    if not d.get("no_spec"):
        spec_at_base = d.get("spec") or _lane_spec(ctx, key, wt)
        if not spec_at_base or git(["cat-file", "-e", f"{base}:{spec_at_base}"], cwd=wt).returncode != 0:
            die(f"{a.id} 的回退点上没有 spec（{spec_at_base or '?'}），回退后没法写答复，只能手工处理")
    ahead = git(["rev-list", "--count", f"{base}..HEAD"], cwd=wt).stdout.strip() or "?"
    tags = harness_tags(ctx).get(key, set())
    drop, repoint = [], []
    for t in ("built", "followup-start", "followup"):
        if t in tags:
            sha = git(["rev-parse", f"refs/tags/harness/{key}/{t}^{{commit}}"], cwd=ctx.root).stdout.strip()
            if not _is_ancestor(ctx, sha, base):
                # a B3 decision (built survives the reset): followup-start still means
                # "B3 has started", keep it at the reset point. A B1 decision drops it.
                b3 = t == "followup-start" and "built" in tags and "built" not in drop
                (repoint if b3 else drop).append(t)
    # decisions made after this one were answered on commits the reset throws away
    later = [r for r in recs.values() if r["key"] == key and r["id"] != a.id
             and r.get("status") in ("pending", "confirmed", "overridden")
             and r.get("base") and r["base"] != base and _is_ancestor(ctx, base, r["base"])]
    # decisions from the same reopen batch survive the reset with their current answer
    same = [r for r in recs.values() if r["key"] == key and r["id"] != a.id and r.get("base") == base
            and r.get("status") in ("pending", "confirmed", "overridden")]
    if not a.yes:
        print("STATUS=confirm")
        print(f"REASON=override 会把 {key} 的 worktree 恢复到 {a.id} 之前的提交 {base[:12]}，"
              f"丢掉之后的 {ahead} 个提交，再按新决定重跑这一路；确认后加 --yes")
        for t in drop:
            print(f"DROP_TAG=harness/{key}/{t}")
        for t in repoint:
            print(f"MOVE_TAG=harness/{key}/{t} → {base[:12]}")
        for r in later:
            print(f"SUPERSEDE={r['id']}（在 {a.id} 之后做的决定，回退后作废）")
        dirty = _wt_dirty(wt)
        for ln in dirty[:20]:
            print(f"DISCARD={ln}")
        return 1
    r1 = git(["reset", "-q", "--hard", base], cwd=wt)
    r2 = git(["clean", "-fdq"], cwd=wt)
    if r1.returncode != 0 or r2.returncode != 0:
        die(f"恢复 worktree 失败：{(r1.stderr + r2.stderr).strip()}", f"WORKTREE={wt}")
    for t in drop:
        git(["tag", "-d", f"harness/{key}/{t}"], cwd=ctx.root)
    for t in repoint:
        git(["tag", "-f", f"harness/{key}/{t}", base], cwd=ctx.root)

    def _label(r):
        return {"confirmed": "已确认", "overridden": "用户改判"}.get(r.get("status"), "按推荐项代答，待确认")

    entries = [{"id": r["id"], "question": r["question"], "answer": r.get("answer") or r["chosen"],
                "tag": f"{r['id']}，{_label(r)}"} for r in same]
    entries.append({"id": a.id, "question": d["question"], "answer": answer, "tag": f"{a.id}，用户改判"})
    if d.get("no_spec"):
        # no spec to write into: the answers live in notes.json and reach the next
        # worker prompt; the reset already removed whatever that build produced
        notes = read_json(_notes_path(ctx, key)) or {"entries": []}
        gone = {r["id"] for r in later} | {e["id"] for e in entries}
        notes["entries"] = [e for e in notes.get("entries", []) if e.get("id") not in gone] + entries
        write_json(_notes_path(ctx, key), notes)
        info = {"base": base, "head": base, "spec": None, "appendix": _clarifications_text(notes["entries"])}
    else:
        info = _reopen(ctx, lane, title=f"Clarifications（{_today()}，用户改判 {a.id}）", entries=entries,
                       status=d.get("reopen_status"), subject=f"docs({key}): 按用户改判 {a.id} 更新答复")
    _update_decisions(ctx, {a.id}, base=info["base"], commit=info["head"], **mark)
    if later:
        _update_decisions(ctx, {r["id"] for r in later}, status="superseded", resolved_at=now_iso())
    if same:
        _update_decisions(ctx, {r["id"] for r in same}, base=info["base"], commit=info["head"])
    lane["phase"] = "prepared"
    lane.pop("hold_reason", None)
    lane.pop("hold_kind", None)
    lane.setdefault("notes", []).append(f"override {a.id}: {answer[:200]}")
    ctx.save_lane(lane)
    print(f"RESET={base}")
    for t in drop:
        print(f"DELETED_TAG=harness/{key}/{t}")
    for r in later:
        print(f"SUPERSEDED={r['id']}")
    _print_reopened(info)
    return 0


# ------------------------------------------------------------------ environment
#
# A story that needs a running service (database, integration env) used to have
# its worker halt on the first verification. `env_check_command` says whether the
# environment is up; `env_up_command` brings it up. launch runs them before it
# starts a worker, integrate before verify_command. Every self-heal is printed as
# a SELF_HEAL= line and noted on the lane.

def _env_run(ctx, cmd: str, lane, timeout: int):
    env = dict(os.environ, SUPERH_MAIN_ROOT=str(ctx.root))
    if lane:
        env.update(SUPERH_KEY=lane["key"], SUPERH_WORKTREE=str(lane.get("worktree", "")))
    return run_group(["sh", "-c", cmd], cwd=ctx.root, env=env, timeout=timeout,
                     on_start=_record_child(ctx, lane) if lane else None)


def _ensure_env(ctx, lane) -> dict:
    """{"ok": bool, "detail": str, "output": str, "healed": bool}."""
    check = str(ctx.config.get("env_check_command") or "").strip()
    up = str(ctx.config.get("env_up_command") or "").strip()
    if not check and not up:
        return {"ok": True, "detail": "", "output": "", "healed": False}
    timeout = int(ctx.config.get("env_timeout_sec") or 600)

    def ok_of(r):
        return not r["timed_out"] and r["rc"] == 0

    with _guard(ctx, ".env.guard"):
        if check:
            r = _env_run(ctx, check, lane, min(timeout, 300))
            if ok_of(r):
                return {"ok": True, "detail": "", "output": "", "healed": False}
            if not up:
                return {"ok": False, "detail": f"env_check_command 不通过（{'超时' if r['timed_out'] else 'exit=' + str(r['rc'])}），"
                        "没有配 env_up_command", "output": (r["out"] + r["err"])[-3000:], "healed": False}
        r = _env_run(ctx, up, lane, timeout)
        if not ok_of(r):
            return {"ok": False, "detail": f"env_up_command 失败（{'超时 ' + str(timeout) + 's' if r['timed_out'] else 'exit=' + str(r['rc'])}）",
                    "output": (r["out"] + r["err"])[-3000:], "healed": False}
        if check:
            r = _env_run(ctx, check, lane, min(timeout, 300))
            if not ok_of(r):
                return {"ok": False, "detail": "env_up_command 跑完了，env_check_command 仍不通过",
                        "output": (r["out"] + r["err"])[-3000:], "healed": False}
    if check:
        return {"ok": True, "detail": "env_check_command 不通过，已执行 env_up_command 起好", "output": "", "healed": True}
    return {"ok": True, "detail": "", "output": "", "healed": False}


def _settings_model() -> str:
    if os.environ.get("ANTHROPIC_MODEL"):
        return os.environ["ANTHROPIC_MODEL"] + "（ANTHROPIC_MODEL）"
    d = read_json(Path.home() / ".claude" / "settings.json") or {}
    return str(d.get("model") or "")


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
    if a.phase == "done":
        _release_resources(ctx)
    return 0


def cmd_retry(ctx, a):
    if a.disk_full:
        # board's batch command for every lane that died on a full disk (issue #31)
        if a.key:
            die("retry --disk-full 不带 KEY")
        keys = sorted(k for k, l in ctx.all_lanes().items()
                      if l.get("phase") not in ("done", "abandoned") and lane_stage(ctx, l)[0] == "disk_full")
        if not keys:
            print("STATUS=skip")
            print("REASON=没有磁盘写满的 lane")
            return 0
        gate = _disk_gate(ctx, "先腾出空间再重排")
        if gate is not None:
            return gate
        rc = 0
        for k in keys:
            print(f"LANE={k}")
            try:
                r = _retry_one(ctx, k, a.reset)
            except SystemExit as e:  # die() for this lane: report it and go on with the rest
                r = e.code if isinstance(e.code, int) else 1
            rc = rc or r
        return rc
    if not a.key:
        die("retry 需要 KEY（或 --disk-full）")
    return _retry_one(ctx, a.key, a.reset)


def _retry_one(ctx, key, reset: bool) -> int:
    lane = ctx.lane(key)
    if not lane:
        die(f"lane {key} 不存在")
    stage, _ = lane_stage(ctx, lane)
    if stage not in ("blocked", "failed", "quota", "crashed", "held", "disk_full") or \
            lane.get("phase") in ("merged", "conflict", "integrating"):
        die(f"lane {key} 阶段 {stage}（phase={lane.get('phase')}），不能 retry worker")
    if not Path(lane["worktree"]).is_dir():
        die("worktree 已不存在，无法续作；用 abandon 后重新 prepare")
    if lane.get("hold_kind") in ("prepare", "foreign") or str(lane.get("hold_reason", "")).startswith("prepare 失败"):
        die("这一路卡在 prepare 阶段，retry 不会重跑 prepare；修好原因后 abandon --yes 再重新 prepare")
    if lane.get("phase") != "held":
        # a spec cut short by a full disk would otherwise send the worker off on half a spec
        guard = _spec_guard(ctx, lane, restore=True)
        for ln in guard:
            print(ln)
        if guard or lane.get("spec_backup"):
            ctx.save_lane(lane)
        _retry_check_worktree(ctx, lane, reset)
    elif reset:
        die("held 的 lane 已经有 commit 等着合流，--reset 不适用；按看板「接手」一行处理")
    _print_orphans(Path(lane["worktree"]))
    lane["phase"] = "prepared"
    lane.pop("hold_reason", None)
    lane.pop("hold_kind", None)
    if stage == "disk_full":
        lane["disk_retries"] = int(lane.get("disk_retries") or 0) + 1
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
    _lane_cleanup_hook(ctx, lane)
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
    if wt.exists():
        _lane_cleanup_hook(ctx, lane)
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
    _release_resources(ctx)
    return 0


def cmd_post_epic(ctx, a):
    """Run parallel.yaml `post_epic_command` once for epic N, after its retro and
    while no lane is working (issue #26: e.g. clearing a shared build cache that
    a running lane would still be using). With lanes still running it is queued:
    tick stops handing out new workers and returns next_action=post-epic once
    they are gone."""
    cmd = str(ctx.config.get("post_epic_command") or "").strip()
    epic = str(a.epic)
    st = _post_epic_state(ctx)
    if not cmd:
        print("STATUS=skip")
        print("REASON=parallel.yaml 没有配 post_epic_command")
        return 0
    if epic in st["done"]:
        print("STATUS=skip")
        print(f"REASON=epic {epic} 的 post_epic_command 已经执行过")
        return 0
    lanes = ctx.all_lanes()
    busy = sorted(k for k, l in lanes.items() if lane_stage(ctx, l)[0] == "working" or op_live(l.get("op")))
    if busy:
        if epic not in st["pending"]:
            st["pending"].append(epic)
            write_json(ctx.state / POST_EPIC_FILE, st)
        print("STATUS=deferred")
        print(f"REASON=还有 {len(busy)} 路在跑（{', '.join(busy)}），等它们结束再执行；在这之前不再启动新的 worker")
        return 0
    ok = _run_hook(ctx, "post_epic_command", cmd, None, {"SUPERH_EPIC": epic})
    st = _post_epic_state(ctx)
    st["pending"] = [e for e in st["pending"] if e != epic]
    st["done"].append(epic)
    st.setdefault("results", {})[epic] = {"ok": ok, "at": now_iso()}
    write_json(ctx.state / POST_EPIC_FILE, st)
    print("STATUS=ok")
    print(f"POST_EPIC={'ok' if ok else 'failed'}")
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
    down = str(ctx.config.get("env_down_command") or "").strip()
    if getattr(_a, "finished", False) and down:
        r = _env_run(ctx, down, None, int(ctx.config.get("env_timeout_sec") or 600))
        if r["timed_out"] or r["rc"] != 0:
            print(f"ENV_DOWN=failed（{'超时' if r['timed_out'] else 'exit=' + str(r['rc'])}）")
            print(f"WARN=env_down_command 没有成功，环境可能还开着：{(r['out'] + r['err']).strip()[-300:]}")
        else:
            print("ENV_DOWN=ok")
    if getattr(_a, "finished", False):
        _release_resources(ctx, all_of_them=True)
    n = len(_pending(ctx))
    if n:
        print(f"DECISIONS_PENDING={n}")
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
    wm = str(ctx.config.get("worker_model") or "")
    if wm:
        print(f"WORKER_MODEL={wm}")
    else:
        cur = _settings_model() or "默认"
        print(f"WORKER_MODEL=(跟随 settings：{cur})")
        print("WARN=parallel.yaml 的 worker_model 留空，worker 跟随 ~/.claude/settings.json 的 model"
              f"（现在是 {cur}）。别的仓库的会话执行一次 /model 就会改掉它，建议在 parallel.yaml 里写死，例如 worker_model: opus")
    print(f"DECISION_MODE={ctx.config.get('decision_mode')}")
    print(f"BLOCKED_POLICY={ctx.config.get('blocked_policy')}")
    n = len(_pending(ctx))
    if n:
        print(f"DECISIONS_PENDING={n}")
    return 0


# ------------------------------------------------------------------------- main

# subcommands that change lanes / git state: refused while another live session
# holds the dispatcher lock (`report` is the worker's and stays open)
# (`report` and `reopen` are the worker's and stay open; `decide` / `confirm` only
# touch the decisions inbox, which has its own flock)
MUTATING = ("prepare", "launch", "integrate", "retry", "resume", "override", "mark", "cleanup", "abandon",
            "post-epic", "disk-cleanup")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="superh.py", description="super-harness 调度层 CLI")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("env")
    p = sub.add_parser("plan"); p.add_argument("--json", action="store_true")
    sub.add_parser("tick")
    sub.add_parser("doctor")
    p = sub.add_parser("board"); p.add_argument("--json", action="store_true")
    p.add_argument("--full", action="store_true", help="待你确认栏显示问题、采用、备选、理由全文，不截断")
    p = sub.add_parser("start-run")
    p.add_argument("--force", action="store_true")
    p.add_argument("--slots", type=int, default=None, help="本次运行的并发数（覆盖 config.max_slots，写进 run.json）")
    p.add_argument("--reset-slots", action="store_true", help="清除上次 --slots 覆盖，回到 config.max_slots")
    p.add_argument("--take-over", action="store_true", help="接管另一个仍然活着的会话持有的调度锁（先征得用户同意）")
    p = sub.add_parser("end-run")
    p.add_argument("--finished", action="store_true", help="sprint 跑完了：释放锁后执行 env_down_command")
    for name in ("prepare", "launch", "integrate", "postmerge", "cleanup"):
        p = sub.add_parser(name); p.add_argument("key")
    p = sub.add_parser("retry"); p.add_argument("key", nargs="?", default="")
    p.add_argument("--reset", action="store_true",
                   help="lane 没有 commit 也没有 spec 时，丢掉 worktree 里没提交的半成品再重排")
    p.add_argument("--disk-full", action="store_true", help="重排所有磁盘写满的 lane")
    p = sub.add_parser("disk", help="各分区的余量和 disk_min_free_gb"); p.add_argument("--json", action="store_true")
    sub.add_parser("disk-cleanup", help="余量不足、没有 lane 在跑时执行一次 disk_cleanup_command")
    p = sub.add_parser("watch"); p.add_argument("key"); p.add_argument("--interval", default="5")
    p = sub.add_parser("report")
    p.add_argument("key")
    p.add_argument("--status", required=True, choices=["ready", "blocked", "failed", "quota", "disk_full"])
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
    p = sub.add_parser("reopen", help="worker：按推荐项代答 / 瞬态失败后重开 spec（pipeline.md §3.3）")
    p.add_argument("key")
    p.add_argument("--why", required=True)
    p.add_argument("--decisions-file", default="")
    p.add_argument("--kind", choices=["decision", "transient"], default=None)
    p.add_argument("--status", choices=list(SPEC_STATUSES), default=None)
    p = sub.add_parser("resume", help="把用户的决定写进 spec、提交、挪 tag，重新排队")
    p.add_argument("key")
    p.add_argument("--note", action="append", default=[])
    p.add_argument("--status", choices=list(SPEC_STATUSES), default=None)
    p = sub.add_parser("decide", help="调度者记一条自己按推荐项做的决定")
    p.add_argument("key", help="story key，调度层面的决定写 -")
    p.add_argument("--question", required=True)
    p.add_argument("--chosen", required=True)
    p.add_argument("--option", action="append", default=[])
    p.add_argument("--why", default="")
    p = sub.add_parser("decisions"); p.add_argument("--json", action="store_true"); p.add_argument("--all", action="store_true")
    p = sub.add_parser("post-epic", help="epic retro 之后执行 parallel.yaml 的 post_epic_command")
    p.add_argument("epic")
    p = sub.add_parser("spec-decisions", help="把 spec 里列为待用户确认的取舍导入收件箱")
    p.add_argument("key")
    p.add_argument("--spec", default="")
    p = sub.add_parser("confirm")
    p.add_argument("ids", nargs="*")
    p.add_argument("--all", action="store_true")
    p.add_argument("--key", default="")
    p = sub.add_parser("override")
    p.add_argument("id")
    p.add_argument("--answer", required=True)
    p.add_argument("--yes", action="store_true")
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
        "end-run": cmd_end_run, "watch": cmd_watch, "reopen": cmd_reopen, "resume": cmd_resume,
        "decide": cmd_decide, "decisions": cmd_decisions, "confirm": cmd_confirm, "override": cmd_override,
        "spec-decisions": cmd_spec_decisions, "post-epic": cmd_post_epic,
        "disk": cmd_disk, "disk-cleanup": cmd_disk_cleanup,
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
