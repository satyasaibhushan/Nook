"""Coordination and preflight shared by the desktop performance entry points."""

from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

GIB = 1024**3
CAPTURE_FREE_GIB = 3
BUILD_FREE_GIB = 10
MAX_LOAD1 = 4.0
LOCK_WAIT = 300
ROOT = Path(__file__).resolve().parents[2]
LOCK_PATH = Path("/tmp") / f"nook-perf-{os.getuid()}.lock"
APPLICATIONS = Path("/Applications")


class Invalid(RuntimeError):
    pass


class Interrupted(BaseException):
    def __init__(self, signum):
        self.signum = signum
        super().__init__(f"interrupted by {signal.Signals(signum).name}")


_interrupt_depth = 0
_pending_signal = None


@contextmanager
def cooperative_signals():
    def handle(signum, _frame):
        global _pending_signal
        if _interrupt_depth:
            _pending_signal = _pending_signal or signum
        else:
            raise Interrupted(signum)

    handlers = {sig: signal.signal(sig, handle) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        yield
    finally:
        for sig, handler in handlers.items():
            signal.signal(sig, handler)


@contextmanager
def finish_on_interrupt():
    """Finish acquiring ownership, or releasing it, before raising a pending signal."""
    global _interrupt_depth, _pending_signal
    _interrupt_depth += 1
    try:
        yield
    finally:
        _interrupt_depth -= 1
        if _interrupt_depth == 0 and _pending_signal is not None:
            signum, _pending_signal = _pending_signal, None
            raise Interrupted(signum)


def existing_parent(path):
    path = Path(path).expanduser().resolve()
    while not path.exists():
        path = path.parent
    return path


def worktree_caches(root, device):
    """Report registered caches with no observed cwd or open file, on this volume."""
    try:
        trees = subprocess.check_output(
            ["git", "-C", str(root), "worktree", "list", "--porcelain", "-z"],
            text=True, timeout=5,
        ).split("\0")
        # lsof can return 1 when individual processes exit during enumeration.
        files = subprocess.run(
            ["/usr/sbin/lsof", "-nP", "-F", "n"], capture_output=True, text=True, timeout=8,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    opened = {os.path.realpath(line[1:]) for line in files.stdout.splitlines() if line.startswith("n/")}
    if not opened:
        return []
    candidates = []
    for entry in trees:
        if not entry.startswith("worktree "):
            continue
        tree = Path(entry.removeprefix("worktree ")).resolve()
        if tree == Path(root).resolve():
            continue
        cache = tree / "build"
        if (cache.is_symlink() or not cache.is_dir() or cache.stat().st_dev != device
                or any(p == str(tree) or p.startswith(f"{tree}/") for p in opened)):
            continue
        candidates.append(str(cache))
    return candidates


def disk_headroom(paths, minimum_gib, root=ROOT):
    volumes = {}
    for path in paths:
        directory = existing_parent(path)
        device = directory.stat().st_dev
        if device in volumes:
            continue
        free = shutil.disk_usage(directory).free / GIB
        volumes[device] = {"path": str(directory), "free_gib": round(free, 2)}
        if free < minimum_gib:
            candidates = worktree_caches(root, device)
            listing = ", ".join(candidates) or "none observed"
            raise Invalid(
                f"disk headroom at {directory} is {free:.2f} GiB; need {minimum_gib:g} GiB. "
                f"Other worktree build caches with no observed open files: {listing}"
            )
    return list(volumes.values())


def check_evidence(paths):
    for target in map(Path, paths):
        if target.exists() and not target.is_file():
            raise Invalid(f"evidence target {target} is not a regular file")
    for path in dict.fromkeys(Path(p).parent for p in paths):
        try:
            path.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(dir=path, prefix=".uibench-preflight-") as probe:
                probe.write(b"evidence readiness\n")
                probe.flush()
                os.fsync(probe.fileno())
        except OSError as error:
            raise Invalid(f"evidence directory {path} is not writable: {error.strerror}") from error


@contextmanager
def exclusive(wait=LOCK_WAIT, announce=lambda message: print(message, file=sys.stderr)):
    # A single inode per desktop user across checkouts and custom TMPDIRs.
    # Keep the inode after close so already queued processes use the same lock.
    path = LOCK_PATH
    try:
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    except OSError as error:
        raise Invalid(f"cannot open experiment lock {path}: {error.strerror}") from error
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise Invalid(f"experiment lock {path} must be a private file owned by the desktop user")
        deadline = time.monotonic() + wait
        queued = False
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise Invalid(f"desktop experiment busy: timed out waiting for {path}")
                if not queued:
                    announce(f"desktop experiment busy; waiting up to {wait:g}s for {path}")
                    queued = True
                time.sleep(min(.25, remaining))
            except OSError as error:
                raise Invalid(f"cannot acquire experiment lock {path}: {error.strerror}") from error
        yield fd
    finally:
        os.close(fd)


def check_load(limit=MAX_LOAD1):
    load = os.getloadavg()[0]
    if load > limit:
        raise Invalid(f"desktop load1 is {load:.2f}; limit is {limit:g}. Wait for the machine to idle and retry.")
    return load


def build_output(output):
    output_path = Path(output).expanduser().absolute()
    protected = (APPLICATIONS, APPLICATIONS / "Nook.app")
    protected_paths = {str(path).casefold() for item in protected for path in (item, item.resolve())}
    protected_ids = set()
    for path in protected:
        try:
            info = path.stat()
        except FileNotFoundError:
            continue
        protected_ids.add((info.st_dev, info.st_ino))
    # Check existing ancestors too, so a new destination under a firmlink is rejected.
    bundle = output_path / "Nook.app"
    candidates = set()
    for path in (output_path, bundle, output_path.resolve(), bundle.resolve()):
        candidates.update((path, *path.parents))
    for path in candidates:
        if str(path).casefold() in protected_paths:
            raise Invalid("choose a build output directory outside /Applications")
        try:
            info = path.stat()
        except FileNotFoundError:
            continue
        if (info.st_dev, info.st_ino) in protected_ids:
            raise Invalid("choose a build output directory outside /Applications")
    return output_path.resolve()


def build(output):
    output_path = build_output(output)
    paths = (ROOT / "build", tempfile.gettempdir(), output_path)
    disk_headroom(paths, BUILD_FREE_GIB)
    with exclusive() as lock:
        disk_headroom(paths, BUILD_FREE_GIB)
        check_load()
        return subprocess.call(
            ["/bin/bash", str(ROOT / "scripts/perf/build.sh"), str(output_path), "--coordinated"],
            pass_fds=(lock,),
        )


if __name__ == "__main__":
    try:
        if len(sys.argv) == 3 and sys.argv[1] == "--check-build-output":
            build_output(sys.argv[2])
        else:
            sys.exit(build(sys.argv[1]))
    except (Invalid, OSError, RuntimeError) as error:
        sys.exit(str(error))
