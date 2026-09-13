#!/usr/bin/env bash
# The full route a player takes, run once per setting combination:
#
#   character select -> hub -> Psykhanium -> hub -> mission -> win -> hub -> mission
#
# across every combination of first_person_hub and solo_hub_after_mission.
#
# WHY THE WHOLE ROUTE RATHER THAN FOUR SEPARATE TESTS
# ---------------------------------------------------
# Every defect this mod has shipped was a state left behind by the PREVIOUS leg:
# a mission channel still installed when the hub mechanism arrived, a hub
# mechanism still installed when a dead channel was reaped, a left_session
# reason nobody read. A test that enters the hub from a clean boot passes with
# all of them present. The route is the test.
#
# WHY BOTH END-SCREEN EXITS
# -------------------------
# They do not meet, and the one nobody tested is the one that broke:
#
#   timer expiry     StateGameScore.update -> trigger_event("game_score_done")
#   Continue / Space EndView -> multiplayer_session:leave("skip_end_of_round")
#
# solo_hub_after_mission gated only the first path until 0.3.4. Players who
# switched it off still got the solo hub every time they pressed Continue,
# because that exit returns through MechanismLeftSession -> find_available_session,
# which was gated on solo_hub_on_enter instead.
#
# THIS DRIVES THE GAME. It forces wins and abandons sessions. Missions are
# launched through SoloPlay so nothing here can land in a stranger's run, but do
# not fire it at a session you care about.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

MOD="SoloMourningstar"
MISSION="km_enforcer"

# A NUMBER, 1-5, not a difficulty name. SoloPlay reads it as
# `DangerSettings[mod:get("choose_difficulty")]` and DangerSettings is keyed by
# integer danger level (soloplay_mod_view defaults it to 3). Handing it a string
# makes gen_normal_mission_context index DangerSettings with a key that is not
# there and throw on the nil -- inside start_game, before it touches the session,
# so the only symptom is a mission that never launches.
DIFFICULTY=3

printf 'paths\n'

if ! game_is_up; then
	printf '  SKIP game is not reachable\n'
	exit 111
fi

if [ "$(dt 'return get_mod("SoloPlay") and "yes" or "no"')" != "yes" ]; then
	printf '  SKIP SoloPlay is not installed; missions would have to be real ones\n'
	exit 111
fi

VERSION=$(dt 'return tostring(get_mod("SoloMourningstar").version)')
printf '  --   SoloMourningstar %s\n' "$VERSION"

# --- settings, saved and restored -----------------------------------------

ORIG_FP=$(get_setting "$MOD" first_person_hub)
ORIG_AFTER=$(get_setting "$MOD" solo_hub_after_mission)
ORIG_ENTER=$(get_setting "$MOD" solo_hub_on_enter)
ORIG_MISSION=$(get_setting SoloPlay choose_mission)
ORIG_DIFF=$(get_setting SoloPlay choose_difficulty)

restore() {
	[ "$ORIG_FP" != "nil" ] && set_setting "$MOD" first_person_hub "$ORIG_FP"
	[ "$ORIG_AFTER" != "nil" ] && set_setting "$MOD" solo_hub_after_mission "$ORIG_AFTER"
	[ "$ORIG_ENTER" != "nil" ] && set_setting "$MOD" solo_hub_on_enter "$ORIG_ENTER"
	# choose_mission is a string and choose_difficulty is a number, so they
	# restore differently. Quoting the number puts the STRING "3" back, which
	# fails exactly like the bogus value it replaced -- a restore that corrupts
	# the setting it is restoring is worse than not restoring it.
	[ "$ORIG_MISSION" != "nil" ] && dt 'get_mod("SoloPlay"):set("choose_mission", "'"$ORIG_MISSION"'", false) return "ok"' >/dev/null
	[ "$ORIG_DIFF" != "nil" ] && dt 'get_mod("SoloPlay"):set("choose_difficulty", '"$ORIG_DIFF"', false) return "ok"' >/dev/null
	printf '  --   settings restored\n'
}
trap restore EXIT

# solo_hub_on_enter stays ON for the whole matrix: it is the base gate, and with
# it off the mod does nothing at all and every assertion below would pass
# vacuously. The matrix varies the two settings that have independent effects.
set_setting "$MOD" solo_hub_on_enter true
dt 'get_mod("SoloPlay"):set("choose_mission", "'"$MISSION"'", false) return "ok"' >/dev/null
dt 'get_mod("SoloPlay"):set("choose_difficulty", '"$DIFFICULTY"', false) return "ok"' >/dev/null

# Fail loudly rather than fifteen rows later. start_game swallows a bad mission
# or difficulty into a mission that simply never appears, and every downstream
# assertion then fails for a reason that has nothing to do with the mod.
PRECHECK=$(dt '
local sp = get_mod("SoloPlay")
local ok, ctx = pcall(sp.gen_normal_mission_context)
if not ok then return "context-error: " .. tostring(ctx) end
local MissionTemplates = require("scripts/settings/mission/mission_templates")
if not MissionTemplates[ctx.mission_name] then return "no-template: " .. tostring(ctx.mission_name) end
return "ok " .. tostring(ctx.mission_name) .. " challenge=" .. tostring(ctx.challenge)
')
case "$PRECHECK" in
	ok\ *) printf '  --   SoloPlay will launch %s\n' "${PRECHECK#ok }" ;;
	*) printf '  FAIL SoloPlay cannot build a mission context: %s\n' "$PRECHECK"; exit 1 ;;
esac

# --- drivers ---------------------------------------------------------------

# Character select -> hub. This is the event the Enter Mourningstar button
# fires; SoloPlay uses the same one, which is a reasonable second opinion that
# it is the right seam.
#
# Retried until the game actually leaves StateMainMenu. The event is consumed by
# the state, so one fired a frame early is silently dropped -- there is no error
# and no return value to check, and the only symptom is sitting on character
# select forever.
enter_hub_from_character_select() {
	local i
	for ((i = 1; i <= 20; i++)); do
		dt 'Managers.event:trigger("event_state_main_menu_continue") return "continued"' >/dev/null
		sleep 3
		case "$(state)" in
			*gs=StateMainMenu*) ;;
			*) return 0 ;;
		esac
	done
	return 1
}

# Back to character select, so each combination starts where a player does
# rather than inheriting the previous row's hub.
to_character_select() {
	dt 'Managers.multiplayer_session:leave("leave_to_character_select") return "left"' >/dev/null
}

start_mission() {
	dt 'get_mod("SoloPlay").start_game("normal") return "started"' >/dev/null
}

# Force the win. Straight off the game mode manager rather than through CWaH, so
# this suite does not need CWaH installed; end_conditions_met guards the repeat
# that the outro makes easy to fire twice.
force_win() {
	dt '
local gmm = Managers.state and Managers.state.game_mode
if not gmm then return "no-game-mode" end
if gmm:end_conditions_met() then return "already-ending" end
local ok, err = pcall(gmm.complete_game_mode, gmm, "solomourningstar_test")
return ok and "won" or ("failed: " .. tostring(err))
'
}

# The Psykhanium, by the mechanism the Start button reaches. Not
# TrainingGroundsOptionsView._start_training_grounds, which needs the view open;
# the leg under test is the RETURN from here, not the way in.
to_psykhanium() {
	dt '
local Missions = require("scripts/settings/mission/mission_templates")
local mission = Missions.tg_shooting_range
Managers.mechanism:change_mechanism(mission.mechanism_name, {
  mission_name = "tg_shooting_range",
  circumstance_name = "default",
  side_mission = "default",
})
Managers.mechanism:trigger_event("all_players_ready")
return "requested"
' >/dev/null 2>&1
}

# Leave whatever we are in and let the mod decide where the hub comes from.
# "leave_to_hub" is the Psykhanium reason, and as of 0.3.4 it is deliberately
# governed by solo_hub_on_enter rather than solo_hub_after_mission -- the Meat
# Grinder is not a mission.
leave_to_hub() {
	dt 'Managers.multiplayer_session:leave("leave_to_hub") return "left"' >/dev/null
}

# --- one row of the matrix -------------------------------------------------

# $1 first_person_hub, $2 solo_hub_after_mission, $3 how to leave the end screen
run_row() {
	local fp="$1" after="$2" exit_label="$3" exit_lua="$4"
	local tag="fp=$fp after=$after exit=$exit_label"
	local s

	printf '\n  row: %s\n' "$tag"

	set_setting "$MOD" first_person_hub "$fp"
	set_setting "$MOD" solo_hub_after_mission "$after"

	# --- character select -> hub ---
	#
	# Wait for the GAME STATE, not the mechanism: mech=left_session shows up
	# during teardown, well before StateMainMenu exists to receive the continue
	# event. See wait_for_main_menu in lib.sh.
	to_character_select
	s=$(wait_for_main_menu 90) \
		|| bad "$tag: reached character select" "state: $s"

	enter_hub_from_character_select \
		|| bad "$tag: character select accepted continue" "still on StateMainMenu"

	s=$(wait_for_hub) || bad "$tag: reached the hub from character select" "state: $s"
	case "$s" in *mech=hub*gm=hub*) ok "$tag: reached the hub from character select" ;; esac

	assert_eq "$(field "$s" chan)" "nil" "$tag: hub has no mechanism host channel"
	assert_eq "$(field "$s" fp)" "$fp" "$tag: first-person state matches the setting"

	# --- hub -> Psykhanium ---
	to_psykhanium
	s=$(wait_for_state '*gm=shooting_range*' 90) \
		&& ok "$tag: reached the Psykhanium" \
		|| bad "$tag: reached the Psykhanium" "state: $s"

	# --- Psykhanium -> hub ---
	#
	# The Meat Grinder is not a mission, so this leg must land in the solo hub
	# whatever solo_hub_after_mission says. A regression here means the 0.3.4
	# reason table started treating leave_to_hub as a mission exit.
	leave_to_hub
	s=$(wait_for_hub)
	case "$s" in
		*mech=hub*gm=hub*) ok "$tag: Psykhanium returned to the hub" ;;
		*) bad "$tag: Psykhanium returned to the hub" "state: $s" ;;
	esac
	assert_eq "$(field "$s" chan)" "nil" "$tag: hub still has no mechanism host channel"

	# --- hub -> mission ---
	start_mission
	s=$(wait_for_mission) \
		&& ok "$tag: mission launched from the hub" \
		|| bad "$tag: mission launched from the hub" "state: $s"

	# --- mission win -> hub (or not) ---
	local won
	won=$(force_win)
	assert_contains "$won" "won" "$tag: the mission was completed"

	# Fire the chosen end-screen exit once the score screen is up.
	#
	# Re-fired, up to a cap, until the state actually leaves score. Both exits
	# are events consumed by a state, so one delivered a frame early is dropped
	# with no error and no return value to check -- the same trap that made the
	# character-select continue look like a stuck game rather than a lost event.
	local i fired=0
	for ((i = 1; i <= 60; i++)); do
		case "$(state)" in
			*mstate=score*)
				if [ "$fired" -lt 3 ]; then
					dt "$exit_lua" >/dev/null
					fired=$((fired + 1))
				fi
				;;
			*)
				[ "$fired" -gt 0 ] && break
				;;
		esac
		sleep 2
	done

	if [ "$fired" -eq 0 ]; then
		bad "$tag: the end screen came up" "never saw mstate=score"
	else
		ok "$tag: the $exit_label exit fired"
	fi

	if [ "$after" = "true" ]; then
		s=$(wait_for_hub 120)
		case "$s" in
			*mech=hub*gm=hub*) ok "$tag: returned to a hub after the mission" ;;
			*) bad "$tag: returned to a hub after the mission" "state: $s" ;;
		esac

		# OURS, not a public one. host_type is the only thing that tells them
		# apart -- mech and gm read "hub" either way -- and "we booted the solo
		# hub" is the entire claim of the setting being on.
		assert_not_contains "$s" "host=hub_server" \
			"$tag: the hub is ours, not a public server"

		# The invariant behind the crash: the mission channel must not outlive
		# the swap. A number here is the condition that produced the
		# game_score_done nil call, whether or not it crashed this time.
		assert_eq "$(field "$s" chan)" "nil" "$tag: mission channel did not outlive the swap"
		assert_eq "$(field "$s" fp)" "$fp" "$tag: first-person state survived the mission"

		# --- hub -> mission, again ---
		#
		# The hub being reachable is not the same as the hub being usable: the
		# reported failure was a hub that loaded and then could not be left.
		start_mission
		s=$(wait_for_mission) \
			&& ok "$tag: the returned-to hub can launch another mission" \
			|| bad "$tag: the returned-to hub can launch another mission" "state: $s"
	else
		# With the setting off the hook passes straight through to vanilla, and
		# what vanilla does after a mission is join a PUBLIC hub server. So the
		# pass-through is not "no hub" -- it is a hub whose host_type is
		# hub_server, reached over a real mechanism channel.
		#
		# Asserting the public hub rather than merely the absence of ours is the
		# stronger test: "we did not boot the solo hub" also passes when the mod
		# has broken the return entirely and left the player nowhere, which is a
		# bug that has actually shipped here.
		s=$(wait_for_hub 180)
		case "$s" in
			*host=hub_server*)
				ok "$tag: passed through to a public hub"

				# A public hub must be STOCK, whatever first_person_hub asked
				# for. The overrides live on the shared GameModeSettings.hub, so
				# leaving them patched here builds every remote player's husk
				# from the combat template and crashes on the first hot-join
				# (hub_aim_constraints.lua:37). Asserted regardless of $fp,
				# because the failing case is precisely fp=true.
				assert_eq "$(field "$s" fp)" "false" \
					"$tag: public hub loaded with stock settings"
				;;
			*mech=hub*)
				bad "$tag: passed through to a public hub" \
					"booted a local hub with solo_hub_after_mission off: $s"
				;;
			*)
				bad "$tag: passed through to a public hub" "never reached a hub: $s"
				;;
		esac
	fi
}

# --- the matrix ------------------------------------------------------------
#
# Four setting combinations by two end-screen exits. The exit only changes the
# after-mission leg, but it changes the leg the whole mod exists for, and the
# 0.3.4 bug lived in exactly one of the two.

# The score-done exit fires game_score_done DIRECTLY rather than waiting for the
# end-screen timer to do it. That is not laziness: with Realms hosting, the timer
# never expires at all.
#
# Realms hooks ProgressionManager.game_score_end_time (views/end_view.lua:22) and
# returns UNLIMITED_END_TIME whenever its session is active -- reading it live
# gives `inf`. StateGameScore.update fires the event on
# `game_score_end_time < server_time`, which infinity never satisfies, so a row
# that waits for the timer waits forever on the end screen. Measured, not
# guessed: the first full run sat there until it was killed.
#
# What is lost is coverage of the timer itself, which belongs to Realms. What is
# kept is the thing this suite is for: game_score_done and skip_end_of_round are
# two different routes off the end screen, they land in different places, and
# solo_hub_after_mission has to gate both. state_game_score.lua:95 shows the
# timer's whole effect is this same trigger_event call, so from the mechanism
# onward the path exercised is identical.
SCORE_DONE='Managers.mechanism:trigger_event("game_score_done") return "fired"'
CONTINUE='Managers.multiplayer_session:leave("skip_end_of_round") return "left"'

# SM_SMOKE=1 runs a single row instead of the matrix.
#
# The full matrix is sixteen rows of loading screens, so a harness bug in a late
# leg costs an hour to find. This row is the one that touches every leg
# including the ones only after=true reaches -- the return to the solo hub, the
# channel invariant, and relaunching from the hub we came back to. Use it after
# any change to this file, then run the matrix.
if [ "${SM_SMOKE:-0}" = "1" ]; then
	# Both values of solo_hub_after_mission, because they assert opposite things
	# after the mission -- our hub versus the public one -- and a smoke run that
	# covers only one leaves the other's assertion unexercised. That is how the
	# after=false branch reached the matrix asserting "no hub at all", which
	# vanilla never does.
	printf '  --   SM_SMOKE=1: two rows only\n'
	run_row "false" "true" "score-done" "$SCORE_DONE"
	run_row "false" "false" "score-done" "$SCORE_DONE"
else
	for fp in false true; do
		for after in false true; do
			run_row "$fp" "$after" "score-done" "$SCORE_DONE"
			run_row "$fp" "$after" "continue" "$CONTINUE"
		done
	done
fi

# Leave the game somewhere a person can use.
to_character_select
wait_for_main_menu 90 >/dev/null
enter_hub_from_character_select
wait_for_hub 120 >/dev/null

summary "paths"
