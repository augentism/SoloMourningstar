#!/usr/bin/env bash
# Shared plumbing for the SoloMourningstar in-game tests. Sourced, not executed.
#
# Modelled on ChaosWastesAtHome/tests/ingame/lib.sh, which is the reference for
# the dt-cli plumbing here (JSON parsing, retry policy, assertions). The game
# state this one reads is different, so the readers below are its own.
#
# ---------------------------------------------------------------------------
# WHAT THESE TESTS EXIST TO CATCH
# ---------------------------------------------------------------------------
# Every bug this mod has shipped came from the same place: which SESSION and
# which MECHANISM are installed at a moment when something else reads them.
# None of it is visible offline, because all of it is "what does
# Managers.multiplayer_session think it is hosting right now".
#
# So the state reader below is deliberately about exactly that, and every
# assertion is against a field some piece of engine code branches on:
#
#   host_type()               what mission_intro_view validates on
#   mechanism_name()          what rpc_mechanism_event dispatches into
#   _mechanism_host_channel   what wanted_transition and disconnect branch on
#
# ---------------------------------------------------------------------------
# MISSIONS GO THROUGH SOLOPLAY
# ---------------------------------------------------------------------------
# Never launch a real mission from this suite. It forces wins and abandons
# sessions; pointed at matchmaking that is three strangers whose run you just
# ended. SoloPlay boots a local singleplayer session with no other players in
# it, so the whole matrix runs without touching anyone else's game.
#
# The cost is stated plainly in the README: a SoloPlay mission returns to the
# hub through MechanismLeftSession -> find_available_session, so the matrix
# exercises that path and NOT party_immaterium_hot_join_hub_server, which needs
# a real dedicated mission server.
# ---------------------------------------------------------------------------

set -uo pipefail

WORKSPACE="${SOLOMOURNINGSTAR_TEST_ROOT:-/mnt/storage/workspace/modding/Darktide}"
CLI="$WORKSPACE/.claude/skills/darktide-dt-cli/scripts/dt-cli.sh"

PASS=0
FAIL=0
FAILURES=()

# --- dt-cli --------------------------------------------------------------

# dt-cli's JSON key order is NOT stable -- the same build emits both
# {"id",...,"output","ok"} and {"result",...,"ok","output","id"}. A sed pattern
# that assumes one order silently yields an EMPTY string against the other,
# which is worse than an error: every assertion downstream compares against ""
# and every wait loop spins to its timeout while the game does exactly what it
# was told. Parse it instead. The sed fallback handles either ordering, for
# running a script directly outside the flake.
PY="$(command -v python3 || true)"

_json_field() {
	local field="$1"
	if [ -n "$PY" ]; then
		"$PY" -c '
import json, sys
raw = sys.stdin.read()
try:
    doc = json.loads(raw)
except Exception:
    sys.stdout.write("")
    sys.exit(0)
value = doc.get(sys.argv[1])
sys.stdout.write("" if value is None else str(value))
' "$field"
	else
		sed -n "s/.*\"$field\":\"\([^\"]*\)\".*/\1/p" \
			| sed 's/\\n/\n/g; s/\\"/"/g; s|\\/|/|g'
	fi
}

# A call can come back "i/o timeout" while the game is loading or mid-frame --
# the pipe connected and LuaExec did not answer in time. That is a busy signal,
# not an unreachable game, so it is retried. This suite spends most of its time
# on loading screens, so it hits that case far more than CWaH's does.
dt() {
	local lua="$1" out attempt
	for attempt in 1 2 3 4 5 6 7 8; do
		out=$(timeout 60 "$CLI" exec --stdin <<<"$lua" 2>&1)
		case "$out" in
			*'"ok":true'*)
				printf '%s' "$out" | _json_field output
				return 0
				;;
			*'i/o timeout'*)
				sleep 2
				;;
			*)
				printf 'LUA-ERROR: %s' "$(printf '%s' "$out" | _json_field error)"
				return 1
				;;
		esac
	done
	printf 'CLI-UNREACHABLE: %s' "$out"
	return 1
}

game_is_up() {
	timeout 60 "$CLI" exec 'return "up"' 2>&1 | grep -q '"ok":true'
}

# --- assertions ----------------------------------------------------------

ok() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}

bad() {
	FAIL=$((FAIL + 1))
	FAILURES+=("$1")
	printf '  FAIL %s\n' "$1"
	[ -n "${2:-}" ] && printf '         %s\n' "$2"
	return 0
}

assert_eq() {
	local got="$1" want="$2" what="$3"
	if [ "$got" = "$want" ]; then
		ok "$what"
	else
		bad "$what" "expected '$want', got '$got'"
	fi
}

assert_contains() {
	local haystack="$1" needle="$2" what="$3"
	case "$haystack" in
		*"$needle"*) ok "$what" ;;
		*) bad "$what" "expected to find '$needle' in: $haystack" ;;
	esac
}

assert_not_contains() {
	local haystack="$1" needle="$2" what="$3"
	case "$haystack" in
		*"$needle"*) bad "$what" "did not expect '$needle' in: $haystack" ;;
		*) ok "$what" ;;
	esac
}

summary() {
	printf '\n%s: %d passed, %d failed\n' "${1:-ingame}" "$PASS" "$FAIL"
	if [ "$FAIL" -gt 0 ]; then
		printf 'failures:\n'
		for f in "${FAILURES[@]}"; do printf '  - %s\n' "$f"; done
		return 1
	fi
	return 0
}

# --- state ---------------------------------------------------------------

# One line describing where the session is. Every field here is one that engine
# code branches on -- see the header.
#
# No apostrophes anywhere in this Lua: it lives inside a single-quoted bash
# string, so one would end the string and hand the rest to the shell.
#
# host_type is the field that decides whether mission_intro_view validates
# (constant_element_loading.lua:16-62), which is how a hub load ends up on the
# mission drop-in screen and then blocks in HostWaitForMissionBriefingDoneState.
# It is a METHOD on the manager and returns nil when no session is installed.
#
# fp reads the first-person state off the shared settings tables rather than the
# mod setting, because the setting is what was asked for and these are what
# actually got applied -- the gap between the two is the thing worth testing.
STATE_LUA='
local ms = Managers.multiplayer_session
local mm = Managers.mechanism
local gm = Managers.state and Managers.state.game_mode

local ok_gms, GameModeSettings = pcall(require, "scripts/settings/game_mode/game_mode_settings")
local ok_mis, Missions = pcall(require, "scripts/settings/mission/mission_templates")

local fp = "unknown"
if ok_gms and ok_mis and GameModeSettings.hub and Missions.hub_ship then
  fp = tostring(GameModeSettings.hub.player_unit_template_name_override == nil
    and Missions.hub_ship.force_third_person_mode == nil)
end

-- The game state name, which is NOT derivable from the mechanism. The
-- mechanism goes left_session during teardown, seconds before StateMainMenu is
-- actually entered -- so anything that waits on the mechanism to decide the
-- character select screen is up fires into a state machine that has not got
-- there yet, and the event is simply lost.
local gs = Managers.ui and Managers.ui._current_state_name

return string.format("host=%s|mech=%s|mstate=%s|gm=%s|chan=%s|fp=%s|gs=%s",
  tostring(ms and ms:host_type()),
  tostring(mm and mm:mechanism_name()),
  tostring(mm and mm:mechanism_state()),
  tostring(gm and gm:game_mode_name()),
  tostring(mm and mm._mechanism_host_channel),
  fp,
  tostring(gs))
'

state() {
	dt "$STATE_LUA"
}

field() {
	printf '%s' "$1" | tr '|' '\n' | sed -n "s/^$2=//p"
}

# --- settings, saved and restored ----------------------------------------
#
# Every script that changes a setting restores it in a trap. A crashed run that
# leaves solo_hub_after_mission off makes the next run's assertions pass for the
# wrong reason, and a test that cannot fail is worse than no test.

get_setting() {
	dt 'return tostring(get_mod("'"$1"'"):get("'"$2"'"))'
}

set_setting() {
	dt 'get_mod("'"$1"'"):set("'"$2"'", '"$3"', false) return "ok"' >/dev/null
}

# --- waiting -------------------------------------------------------------

# Wait until the state line matches a pattern. Everything in this suite is a
# loading screen away from everything else, so the default is generous.
wait_for_state() {
	local pattern="$1" tries="${2:-90}" i s
	for ((i = 1; i <= tries; i++)); do
		s=$(state)
		case "$s" in
			$pattern) printf '%s' "$s"; return 0 ;;
		esac
		sleep 2
	done
	printf '%s' "$s"
	return 1
}

# The hub, whoever is hosting it. Deliberately NOT asserted as singleplay:
# with Realms installed the solo hub is a listen host and reports
# HOST_TYPES.player instead. Gating on the type would make this suite pass only
# on a machine without Realms -- the same mistake that nearly shipped as a fix.
wait_for_hub() {
	wait_for_state '*mech=hub*gm=hub*' "${1:-90}"
}

# Press Ready in the Realms preparation lobby.
#
# Ported from ChaosWastesAtHome/tests/ingame/lib.sh, which needs it for the same
# reason: with Realms hosting, a mission launch does not go straight to the
# level. It parks in RealmsPreparationState (gs=RealmsPreparationState,
# mstate=adventure_selected) waiting for the host to ready up, and without this
# the suite sits there until its timeout while somebody presses a button by hand.
#
# ONE path rather than a Realms branch and a non-Realms branch: this reports and
# does nothing when Realms is absent, disabled, or the lobby is not waiting, so
# every caller can just call it on each poll. Two branches would mean the
# non-Realms one is never exercised on a machine that has Realms -- which is
# every machine this mod is developed on.
#
# The local_ready() guard is not optional: perform_action is "ready or cancel
# ready", so calling it twice un-readies you and the lobby waits forever.
ready_up() {
	dt '
local realms = get_mod("Realms")
local prep = realms and realms._preparation

if not prep or type(prep.perform_action) ~= "function" then
  return "no-preparation"
end

if not prep.is_waiting() then return "not-waiting" end
if prep.local_ready() then return "already-ready" end

return prep.perform_action() and "readied" or "refused"
'
}

# A mission is live. Readies up on each poll, because the Realms lobby is a stop
# on the way rather than a destination, and EVERY launch goes back through it.
wait_for_mission() {
	local tries="${1:-90}" i s r
	for ((i = 1; i <= tries; i++)); do
		s=$(state)
		case "$s" in
			*gm=coop_complete_objective*) printf '%s' "$s"; return 0 ;;
		esac

		r=$(ready_up)
		[ "$r" = "readied" ] && printf '  --   readied up in the Realms lobby\n' >&2

		sleep 2
	done
	printf '%s' "$s"
	return 1
}

# Character select, by GAME STATE rather than by mechanism.
#
# `mech=left_session` appears during teardown and is NOT the same thing as being
# on the character select screen -- StateMainMenu arrives seconds later. Waiting
# on the mechanism and then firing event_state_main_menu_continue puts the event
# into a state machine that has not arrived, where nothing consumes it and
# nothing reports that it was dropped. The row then sits on character select
# until its timeout looking exactly like a mod defect. That happened.
wait_for_main_menu() {
	wait_for_state '*gs=StateMainMenu*' "${1:-90}"
}
