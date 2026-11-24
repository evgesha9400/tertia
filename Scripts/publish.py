#!/usr/bin/env python3
"""Serialized, zero-gap app bundle publication and build helpers shared by the Scripts/*.sh files and `make install`.

  publish.py lock [--timeout SECONDS] <lockfile> <command> [args...]
      Holds an exclusive fcntl.flock on <lockfile> for the whole run of <command> (the lock descriptor is inherited
      across exec), so concurrent packaging or installs run one at a time.

  publish.py lock-fd [--timeout SECONDS] <fd>
      Locks the open file description behind descriptor <fd>, inherited from the calling shell (`exec 9>file`), and
      exits; the shell holds the lock until it closes that descriptor or exits. No environment flag can skip it.

      Both lock forms try once at once, then poll a non-blocking lock against time.monotonic(), checking the deadline
      before and after every sleep, and fail after SECONDS (default 90), so a stuck holder never hangs the caller and a
      lock released after the deadline is never taken. SECONDS must be a finite number >= 0 (else exit 1).

  publish.py swap <stage> <destination>
      Publishes <stage> at <destination> with no moment where <destination> is missing: an existing destination is
      exchanged with renamex_np(RENAME_SWAP), a missing one is created with rename(2). The swapped-out bundle (now at
      <stage>) is deleted afterwards. <destination> must name a `.app`; an existing one must be a real directory whose
      Contents/Info.plist has CFBundleIdentifier club.tertia.macos, else nothing is touched and the exit status is 1.

  publish.py remove-dead <path>...
      Removes each <path> whose numeric suffix (after the last '.') names a process that no longer exists: staging
      bundles and per-run build directories left by a run killed with SIGKILL. Live owners and other names are kept.

  publish.py clean [--timeout SECONDS] <build_dir> <dist_dir> <dist_app>
      `make clean`: takes <build_dir>/.build.lock, <dist_dir>/.Tertia.app.lock, and (for a <dist_app> other than
      <dist_dir>/Tertia.app whose folder exists) <folder>/.<name>.lock, all before touching anything; refuses (exit 1,
      nothing removed) when an existing <dist_app> fails the `swap` destination check; then empties both directories at
      every depth except lock files (names ending in '.lock'), live runs' directories (`pkg.<pid>` and `*.stage.<pid>`
      whose process still exists), and the folders holding them, and removes <dist_app> with its dead staging bundles.

  publish.py print-test-python
      Prints the python3 for the local HTTPS/HTTP2 wire-profile test (TERTIA_TEST_PYTHON, else the first of
      /opt/homebrew/bin/python3, /usr/local/bin/python3, /usr/bin/python3 that qualifies) once it is verified to support
      TLSv1.3 and ALPN; otherwise names the missing capability on stderr and exits 1.

  publish.py run-watched --timeout SECONDS -- <command> [args...]
      Runs <command> in its own process group and returns its exit status. After SECONDS (time.monotonic()), or when
      run-watched itself gets SIGTERM or SIGINT, the whole group gets SIGTERM, then SIGKILL 1 second later; the
      command is reaped and the group waited out (bounded) before run-watched exits non-zero, so a caller's cleanup
      never races a surviving compiler, packager, or test process. Group members still alive after the command exits
      are stopped the same way before run-watched returns its status. A group that survives SIGKILL is reported on
      stderr and run-watched exits 125.
"""
import ctypes
import errno
import fcntl
import glob
import os
import math
import plistlib
import shutil
import signal
import subprocess
import sys
import time

RENAME_SWAP = 0x00000002
BUNDLE_ID = "club.tertia.macos"
DEFAULT_TIMEOUT = 90.0
TEST_PYTHONS = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]


def acquire(fd, timeout, name):
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return
        except BlockingIOError:
            pass
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(0.05, remaining))
        if time.monotonic() >= deadline:
            sys.exit(f"error: timed out after {timeout:g}s waiting for {name}")


def hold(path, timeout):
    """Opens (creating its folder) and locks `path`; the descriptor stays open, so the lock lasts until exit or exec."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    acquire(fd, timeout, path)
    return fd


def lock(path, command, timeout):
    os.set_inheritable(hold(path, timeout), True)
    os.execvp(command[0], command)


def verify_bundle_destination(path):
    """Exits 1, touching nothing, unless `path` names a `.app` that is missing or is a real Tertia bundle directory."""
    def refuse(reason):
        sys.exit(f"error: refusing to replace or remove {path}: {reason}")
    if not path.rstrip("/").endswith(".app"):
        refuse("the destination must be a .app bundle path")
    if not os.path.lexists(path):
        return
    if os.path.islink(path) or not os.path.isdir(path):
        refuse("it is not a real directory")
    try:
        with open(os.path.join(path, "Contents", "Info.plist"), "rb") as f:
            plist = plistlib.load(f)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        refuse(f"its Contents/Info.plist is unreadable ({error})")
    if not isinstance(plist, dict) or plist.get("CFBundleIdentifier") != BUNDLE_ID:
        refuse(f"it is not a {BUNDLE_ID} bundle")


def swap(stage, destination):
    verify_bundle_destination(destination)
    if os.path.lexists(destination):
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.renamex_np(os.fsencode(stage), os.fsencode(destination), RENAME_SWAP) == 0:
            shutil.rmtree(stage, ignore_errors=True)  # published already; a leftover old bundle is not a failure
            return
        code = ctypes.get_errno()
        if code != errno.ENOENT:
            raise OSError(code, os.strerror(code), destination)
    os.rename(stage, destination)


def pid_alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def remove_dead(paths):
    for path in paths:
        suffix = path.rsplit(".", 1)[-1]
        if suffix.isdigit() and os.path.lexists(path) and not pid_alive(int(suffix)):
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path, ignore_errors=True)
            else:
                os.remove(path)


def live_run(name):
    """Whether `name` is a per-run build directory or staging bundle whose owning process (numeric suffix) is alive."""
    stem, _, suffix = name.rpartition(".")
    return suffix.isdigit() and (stem == "pkg" or stem.endswith(".stage")) and pid_alive(int(suffix))


def clean_tree(directory):
    """Removes every entry under `directory` except lock files, live runs, and the folders holding them; returns whether
    anything was kept."""
    kept = False
    for name in os.listdir(directory):
        path = os.path.join(directory, name)
        if name.endswith(".lock") or live_run(name):
            kept = True
        elif os.path.isdir(path) and not os.path.islink(path):
            if clean_tree(path):
                kept = True
            else:
                os.rmdir(path)
        else:
            os.remove(path)
    return kept


def clean(timeout, build_dir, dist_dir, dist_app):
    hold(os.path.join(build_dir, ".build.lock"), timeout)
    hold(os.path.join(dist_dir, ".Tertia.app.lock"), timeout)
    folder, name = os.path.split(os.path.abspath(dist_app))
    custom = os.path.realpath(dist_app) != os.path.realpath(os.path.join(dist_dir, "Tertia.app")) and os.path.isdir(folder)
    if custom:
        hold(os.path.join(folder, f".{name}.lock"), timeout)
    verify_bundle_destination(dist_app)
    for directory in (build_dir, dist_dir):
        if os.path.isdir(directory):
            clean_tree(directory)
    if custom:
        if os.path.lexists(dist_app):
            shutil.rmtree(dist_app)
        remove_dead(glob.glob(os.path.join(glob.escape(folder), f".{glob.escape(name)}.stage.*")))


def python_capabilities(path):
    """Missing capabilities of the interpreter at `path` (None when it cannot run)."""
    probe = "import ssl; print(' '.join(n for n, ok in (('TLSv1.3', ssl.HAS_TLSv1_3), ('ALPN', ssl.HAS_ALPN)) if not ok))"
    try:
        result = subprocess.run([path, "-I", "-c", probe], capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout.split() if result.returncode == 0 else None


def print_test_python():
    override = os.environ.get("TERTIA_TEST_PYTHON")
    candidates = [override] if override else [p for p in TEST_PYTHONS if os.access(p, os.X_OK)]
    first_missing = None
    for path in candidates:
        missing = python_capabilities(path)
        if missing == []:
            print(path)
            return 0
        if first_missing is None:
            first_missing = (path, missing)
    if first_missing is None:
        print("error: make test needs python3 with TLSv1.3 and ALPN support; no python3 interpreter was found", file=sys.stderr)
    elif first_missing[1] is None:
        print(f"error: make test needs python3 with TLSv1.3 and ALPN support; {first_missing[0]} could not run", file=sys.stderr)
    else:
        print(f"error: make test needs python3 with TLSv1.3 and ALPN support; {first_missing[0]} lacks {' and '.join(first_missing[1])}", file=sys.stderr)
    return 1


def group_alive(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def stop_group(child):
    """SIGTERM to the group, then SIGKILL to anything still alive after up to 1 s, reaping the leader. Each grace ends as
    soon as the whole group is gone; the leader's own exit proves nothing (it may have exited before its workers).
    Returns whether the group is gone."""
    for sig, grace in ((signal.SIGTERM, 1.0), (signal.SIGKILL, 2.0)):
        try:
            os.killpg(child.pid, sig)
        except (ProcessLookupError, PermissionError):
            pass
        deadline = time.monotonic() + grace
        while True:
            child.poll()  # reaps an exited leader so it no longer counts as a group member
            if not group_alive(child.pid) or time.monotonic() >= deadline:
                break
            time.sleep(0.01)
        if not group_alive(child.pid):
            return True
    return not group_alive(child.pid)


def group_survived(child):
    print(f"error: process group {child.pid} survived SIGKILL", file=sys.stderr)
    return 125


def run_watched(timeout, command):
    received = []
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda signum, _frame: received.append(signum))
    # Own process group in this session (a new session would make killpg on its exiting members fail with EPERM).
    child = subprocess.Popen(command, preexec_fn=os.setpgrp)
    deadline = time.monotonic() + timeout
    while child.poll() is None:
        if received or time.monotonic() >= deadline:
            reason = f"received signal {received[0]}" if received else f"timed out after {timeout:g}s"
            print(f"error: {reason}; stopping the process group of {command[0]}", file=sys.stderr)
            if not stop_group(child):
                return group_survived(child)
            return 128 + received[0] if received else 124
        time.sleep(0.05)
    # A backgrounded worker of the finished command never outlives run-watched.
    if group_alive(child.pid) and not stop_group(child):
        return group_survived(child)
    return child.returncode if child.returncode >= 0 else 128 - child.returncode


def parse_timeout(args):
    if len(args) >= 2 and args[0] == "--timeout":
        try:
            timeout = float(args[1])
        except ValueError:
            timeout = math.nan
        if not (math.isfinite(timeout) and timeout >= 0):
            sys.exit(f"error: --timeout must be a finite number of seconds >= 0, got {args[1]!r}")
        return timeout, args[2:]
    return DEFAULT_TIMEOUT, args


if __name__ == "__main__":
    cmd, rest = (sys.argv[1], sys.argv[2:]) if len(sys.argv) >= 2 else ("", [])
    if cmd == "lock":
        timeout, rest = parse_timeout(rest)
        if len(rest) < 2:
            sys.exit(__doc__)
        lock(rest[0], rest[1:], timeout)
    elif cmd == "lock-fd":
        timeout, rest = parse_timeout(rest)
        if len(rest) != 1:
            sys.exit(__doc__)
        acquire(int(rest[0]), timeout, f"descriptor {rest[0]}")
    elif cmd == "swap" and len(rest) == 2:
        swap(rest[0], rest[1])
    elif cmd == "remove-dead":
        remove_dead(rest)
    elif cmd == "clean":
        timeout, rest = parse_timeout(rest)
        if len(rest) != 3:
            sys.exit(__doc__)
        clean(timeout, *rest)
    elif cmd == "print-test-python" and not rest:
        sys.exit(print_test_python())
    elif cmd == "run-watched" and rest[:1] == ["--timeout"]:
        timeout, rest = parse_timeout(rest)
        if len(rest) < 2 or rest[0] != "--":
            sys.exit(__doc__)
        sys.exit(run_watched(timeout, rest[1:]))
    else:
        sys.exit(__doc__)
