#!/usr/bin/env python3
"""Run the SoloMourningstar test suite.

One tier, because everything this mod does is session and mechanism state and
none of it exists outside a running game. There is no offline tier to add: the
mod is hooks over engine managers, and a harness that faked those would only
test the fake.

Usage:
    python3 run_tests.py                # run everything
    python3 run_tests.py -k paths       # filter by script name
    python3 run_tests.py --list         # show what would run

The game is launched if it is not already up, and closed again afterwards --
but only if this run is what started it. A game you already had open is left
open, because closing it would throw away whatever you were doing; the runner
has no way to tell a spare session from the one you are mid-something in.

    --keep-open   never close, even a game this run launched
    --no-start    never launch; SKIP instead if the game is down

The suite reports SKIPPED rather than failed when the game is not running (with
--no-start) or when SoloPlay is missing, so neither turns the run red.

NOTE: these DRIVE the game. paths.sh forces wins and abandons sessions. Missions
go through SoloPlay so nothing lands in a stranger's run, but do not fire this
at a session you care about.
"""

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

TESTS = Path(__file__).resolve().parent
WORKSPACE = TESTS.parent.parent

CLI = WORKSPACE / ".claude/skills/darktide-dt-cli/scripts/dt-cli.sh"
RESTART = WORKSPACE / ".claude/skills/darktide-dt-cli/scripts/restart-game.sh"

# paths.sh is currently the whole suite. New scripts go here in the order they
# should run; anything that leaves the game somewhere other than the hub should
# go last, the way CWaH's vox_map_vote.sh does.
INGAME = [
    "paths.sh",
]

SKIP_EXIT = 111


def run_script(name: str) -> str:
    script = TESTS / "ingame" / name
    if not script.exists():
        print(f"  MISSING {name}")
        return "fail"

    print(f"\n=== {name} ===")
    result = subprocess.run(
        ["bash", str(script)], cwd=str(TESTS / "ingame"), env=_env())
    if result.returncode == SKIP_EXIT:
        return "skip"
    return "pass" if result.returncode == 0 else "fail"


def _path() -> str:
    return os.environ.get("PATH", "/usr/bin:/bin")


def _env() -> dict:
    """The caller's environment, plus where the workspace is.

    Inherit it whole. restart-game.sh launches the game through
    `systemd-run --user`, which needs XDG_RUNTIME_DIR and
    DBUS_SESSION_BUS_ADDRESS to reach the session bus at all, and the game
    itself needs DISPLAY/WAYLAND_DISPLAY and Steam's own variables once it
    starts. Handing down a minimal dict instead makes systemd-run fail to
    register the unit -- and the only visible symptom is restart-game.sh
    waiting for LuaExec forever while nothing is starting.
    """
    env = dict(os.environ)
    env["SOLOMOURNINGSTAR_TEST_ROOT"] = str(WORKSPACE)
    env["SOLOMOURNINGSTAR_TEST_DIR"] = str(TESTS)
    return env


def game_is_reachable() -> bool:
    """True when dt-cli can talk to a running game."""
    if not CLI.exists():
        return False

    try:
        result = subprocess.run(
            [str(CLI), "exec", 'return "up"'],
            capture_output=True, text=True, timeout=40, env=_env())
    except subprocess.TimeoutExpired:
        return False

    return '"ok":true' in result.stdout


def start_game() -> bool:
    """Launch the game and wait for LuaExec. True if it came up.

    restart-game.sh skips Fatshark's launcher and starts Darktide.exe through
    Steam's own runtime chain, because the launcher sits on a Play button that
    an unattended run cannot click. It also does the waiting -- returning
    before LuaExec answers would just move the wait into the first dt call.
    """
    if not RESTART.exists():
        print("could not start the game: %s is missing" % RESTART)
        return False

    print("starting Darktide for the suite...", flush=True)

    return subprocess.run(["bash", str(RESTART)], env=_env()).returncode == 0


def stop_game() -> bool:
    """Close the game and wait for wine to let go of it.

    Stop the systemd unit first: that is how restart-game.sh launches it, and
    pkill alone leaves the unit failed, so the next launch has to reset-failed
    before it can reuse the name. pkill is the fallback for a game somebody
    started from Steam.
    """
    print("\nclosing Darktide...", flush=True)

    subprocess.run(["systemctl", "--user", "stop", "darktide-test"],
                   capture_output=True)

    for pattern in (r"Darktide\.exe", r"Launcher\.exe"):
        subprocess.run(["pkill", "-f", pattern], capture_output=True)

    # Wine needs a moment to release the prefix. Returning before it has is how
    # the next launch ends up with two wineservers and a pipe nobody owns.
    for _ in range(30):
        if subprocess.run(["pgrep", "-f", r"Darktide\.exe"],
                          capture_output=True).returncode != 0:
            return True
        time.sleep(1)

    print("  warning: Darktide is still running after 30s")

    return False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-k", "--filter", nargs="*", default=None,
                        help="only run scripts whose name contains one of these")
    parser.add_argument("--list", action="store_true", help="list scripts and exit")
    parser.add_argument("--keep-open", action="store_true",
                        help="never close the game, even one this run launched")
    parser.add_argument("--no-start", action="store_true",
                        help="never launch the game; SKIP instead if it is down")
    args = parser.parse_args()

    scripts = INGAME
    if args.filter:
        scripts = [s for s in scripts if any(f in s for f in args.filter)]

    if args.list:
        for s in scripts:
            print(s)
        return 0

    if not scripts:
        print("nothing matched")
        return 1

    # Only ever close what this run opened. A game that was already up belongs
    # to whoever is sitting in front of it.
    we_launched = False
    closed = None

    if not game_is_reachable():
        if args.no_start:
            print("game is not reachable and --no-start was given")
            for name in scripts:
                print(f"  SKIP    {name}")
            return 0

        if not start_game():
            print("could not start the game")
            return 1

        we_launched = True
    else:
        print("game is already up; it will be left running")

    try:
        results = {name: run_script(name) for name in scripts}
    finally:
        # finally, not a tidy exit path: a failed row or a Ctrl+C would
        # otherwise leave a game running that nobody asked for.
        if we_launched and not args.keep_open:
            closed = stop_game()

    print("\n--- summary ---")
    for name, outcome in results.items():
        print(f"  {outcome.upper():7} {name}")
    if closed is False:
        print("  WARNING the game did not shut down cleanly")

    return 1 if any(o == "fail" for o in results.values()) else 0


if __name__ == "__main__":
    sys.exit(main())
