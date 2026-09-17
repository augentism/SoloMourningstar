local mod = get_mod("SoloMourningstar")

-- Single source of truth for the version: release_mod.py reads it from here to
-- name the zip, and /solohub reports it so a user's screenshot says which build
-- they are on.
mod.version = "0.3.7"

-- Entering the Mourningstar normally means queueing for a public hub server:
-- fetch a hub queue ticket, gRPC hot-join, fetch server details, DTLS handshake,
-- browse and join the lobby, then sync profiles and load the item packages of up
-- to 31 other occupants (GameParameters.max_players_hub) before you can spawn.
--
-- None of that is needed to walk around the ship. hub_ship is local content --
-- the onboarding missions om_hub_01/om_hub_02 already load that level in a
-- client-hosted singleplayer session -- and MechanismHub explicitly supports
-- running without a server channel:
--
--   self._is_owner = server_channel == nil        (mechanism_hub.lua)
--
-- which is the same shape the game itself uses in mechanism_manager.lua
-- (`self:change_mechanism("hub", {})` when a hosted mechanism finishes).
--
-- So the whole mod is: boot a singleplayer session where the game would have
-- booted a hub-server client, then hand the hub mechanism to it once the
-- session is live. Everything downstream is stock -- MechanismHub loads the
-- level itself and StateLoading drives it from there.

local DangerSettings = require("scripts/settings/difficulty/danger_settings")
local GameModeSettings = require("scripts/settings/game_mode/game_mode_settings")
local MatchmakingConstants = require("scripts/settings/network/matchmaking_constants")
local Missions = require("scripts/settings/mission/mission_templates")
local PacingManager = require("scripts/managers/pacing/pacing_manager")
local PartyConstants = require("scripts/settings/network/party_constants")
local PlayerUnitSpawnManager = require("scripts/managers/player/player_unit_spawn_manager")
local PresenceSettings = require("scripts/settings/presence/presence_settings")
local SpecialsPacing = require("scripts/managers/pacing/specials_pacing/specials_pacing")
local TrainingGroundsSoundEvents = require("scripts/settings/training_grounds/training_grounds_sound_events")

local HOST_TYPES = MatchmakingConstants.HOST_TYPES
local PartyState = PartyConstants.State

local HUB_MECHANISM = "hub"

-- Set while a solo hub session has been booted but the hub mechanism has not
-- been handed to it yet. Also the re-entrancy guard: find_available_session is
-- polled every frame from MechanismLeftSession, so without this a second call
-- would tear down the session boot we are waiting on and start over.
local _pending_session = nil

local function _log(message)
	if mod:get("debug_logging") then
		mod:info(message)
	end
end

-- mod:info re-runs its message through string.format, so a literal % in
-- anything we did not write ourselves -- an engine error string, a path --
-- throws "invalid option '%'". Escape before logging foreign text.
local function _escaped(value)
	return (tostring(value):gsub("%%", "%%%%"))
end

-- Unconditional, unlike _log. Every line this writes is one we need to be able
-- to read in a bug reporter's console log, and debug_logging is off for
-- everyone but us -- which is exactly why the first round of reports could not
-- be told apart by build or by which entry path the player took.
local function _trace(message)
	mod:info("[trace] " .. message)
end

local function _solo_enabled()
	return mod:is_enabled() and mod:get("solo_hub_on_enter")
end

-- Published for other mods. True when a mission ending now will be followed by
-- us hosting the hub, rather than the game joining a public one.
--
-- It exists because `party_immaterium_hot_join_hub_server` is NOT a safe probe
-- once this mod is loaded: calling it boots a session. InstantHub 3.x calls it
-- speculatively to pre-reserve a hub server, gets our locally hosted session
-- back, decides it is not the hub-server boot it wanted, and calls
-- `clear_session_boot()` on it -- destroying the session we are waiting on. The
-- player then gets the mission drop-in loading screen for a hub load, a stall,
-- and a bounce to operative select.
--
-- So anything that wants to know "will Solo Mourningstar take the hub after this
-- mission?" should ask here rather than calling that method to find out:
--
--   local solo = get_mod("SoloMourningstar")
--   if solo and type(solo.will_host_hub_after_mission) == "function"
--       and solo.will_host_hub_after_mission() then
--       return -- leave the post-mission hub to it
--   end
--
-- The hot-join hook below is the only other reader, so this answer cannot drift
-- from the behaviour it describes. Keep it that way: if the gate changes, change
-- it here.
function mod.will_host_hub_after_mission()
	if not _solo_enabled() then
		return false
	end

	return mod:get("solo_hub_after_mission") == true
end

-- True once we are actually in a locally hosted hub, loading included. Reads
-- live game state rather than a flag of our own, so it stays correct however
-- the player got here.
local function _in_solo_hub()
	local session_manager = Managers.multiplayer_session

	if not session_manager or session_manager:host_type() ~= HOST_TYPES.singleplay then
		return false
	end

	local mechanism_manager = Managers.mechanism

	return mechanism_manager ~= nil and mechanism_manager:mechanism_name() == HUB_MECHANISM
end

-- Pacing must stay off in the solo hub -- see the PacingManager hook below for
-- why. Re-asserted every frame rather than set once, because a mod can switch
-- it back on after our init hook has run: Will of the Emperor writes
-- `Managers.state.pacing._disabled = false` directly for anything that is not
-- the shooting range or the prologue, and a hosted hub is neither. That is not
-- a bug on its side -- nothing could host the hub before this mod existed.
local _reasserted_pacing_disabled = false

-- Disabling SpecialsPacing itself is the load-bearing part, and it is deliberately
-- a write to *game state* rather than another hook: SpecialsPacing.update checks
-- its own `_disabled` before it ever reads `_template`, so once this is set the
-- engine protects itself even in a frame where our hooks are absent. That frame
-- is real -- reloading mods tears every hook down and re-applies it, and with
-- pacing being force-enabled every frame the raw update ran in the gap and
-- crashed the game.
--
-- Nothing else writes this flag (WotE writes the *manager's* `_disabled`), so
-- unlike the manager-level disable below it is uncontested.
local function _keep_pacing_disabled()
	if not _in_solo_hub() then
		return
	end

	local pacing_manager = Managers.state and Managers.state.pacing

	if not pacing_manager then
		return
	end

	local specials_pacing = pacing_manager._specials_pacing

	if specials_pacing and not specials_pacing._disabled then
		specials_pacing._disabled = true
	end

	if not pacing_manager:is_enabled() then
		return
	end

	pacing_manager:set_enabled(false)

	if not _reasserted_pacing_disabled then
		_reasserted_pacing_disabled = true

		mod:info("Something re-enabled pacing in the solo hub; disabling it again")
	end
end

-- Your own player must not be flagged remote in a hub we host.
--
-- ArtificialLatency fakes latency by setting `player.remote = true` on the
-- local player so the server lag-compensates you, gated on nothing but
-- `game_session:is_server()`. In vanilla that means the Psykhanium or a solo
-- mission -- combat sandboxes. A hosted hub satisfies it too, and hub UI
-- identifies your player by checking `remote`, so flagging yourself remote
-- makes that code conclude there is no local player and the menu buttons stop
-- drawing.
--
-- Cleared rather than prevented, for the same reason as the pacing re-assert:
-- the write lands from another mod's own state-change callback, after ours.
-- Lag compensation only affects hit registration, and the hub has no combat,
-- so nothing of value is lost by pinning this in the hub alone -- missions and
-- the Psykhanium are untouched.
-- Shared by the frame-level clear and the owner() hook further down, so the
-- explanation is logged once however it first fires.
local _warned_cleared_remote = false

-- Realms replaces our singleplayer boot with a player-hosted session. Its
-- clients report the same host type, so also require local ownership. Loading
-- ownership is available before gameplay creates the hub UI.
local function _in_latency_suppressed_hub()
	if _in_solo_hub() then
		return true
	end

	local session_manager = Managers.multiplayer_session
	local mechanism_manager = Managers.mechanism
	local loading_manager = Managers.loading

	return session_manager ~= nil and session_manager:host_type() == HOST_TYPES.player
		and mechanism_manager ~= nil and mechanism_manager:mechanism_name() == HUB_MECHANISM
		and loading_manager ~= nil and loading_manager:is_host()
end

local function _keep_local_player_local()
	if not _in_latency_suppressed_hub() then
		return
	end

	local player = Managers.player:local_player_safe(1)

	if not player or not player.remote then
		return
	end

	player.remote = nil

	if not _warned_cleared_remote then
		_warned_cleared_remote = true

		mod:info("Cleared a 'remote' flag on the local player in the solo hub (it hides the hub UI)")
	end
end

-- Better than clearing: stop ArtificialLatency and Realms Latency writing the
-- flag at all. The fork uses different names for its cache and saved setting.
--
-- Both of its write paths early-out on its own cached setting being zero --
-- set_player_props then takes the branch that actively clears the flag, and the
-- owner() hook passes straight through. Holding that cache at zero while we are
-- in the hub means nothing is ever written.
--
-- Worth doing rather than relying on the clears alone, because the clears are
-- always one step behind at the worst moment: set_player_props fires from that
-- mod's on_game_state_changed as gameplay is entered, which is when the hub
-- builds its UI, so the button code can read the flag before our next frame.
-- `_in_latency_suppressed_hub()` is already true during loading, so the cache is zero before
-- that callback runs.
--
-- The restore reads their own setting rather than a value we remembered, so a
-- latency change made while in the hub is not clobbered on the way out. This is
-- the one place the mod reaches into another mod's internals; the generic
-- clears stay as the mod-agnostic net, and cover anything else that flags the
-- local player remote.
local _latency_suppressed = {}

local function _hold_latency_mod_off(mod_name, cache_key, setting_id)
	local latency_mod = get_mod(mod_name)
	local settings = latency_mod and latency_mod.settings

	if type(settings) ~= "table" then
		return
	end

	if _in_latency_suppressed_hub() then
		if settings[cache_key] ~= 0 then
			settings[cache_key] = 0

			if not _latency_suppressed[mod_name] then
				_latency_suppressed[mod_name] = true

				mod:info("Holding %s at 0 ms while in the solo hub (its remote flag hides the hub UI)", mod_name)
			end
		end
	elseif _latency_suppressed[mod_name] then
		_latency_suppressed[mod_name] = nil

		local ok, value = pcall(function ()
			return latency_mod:get(setting_id)
		end)

		if ok and value then
			settings[cache_key] = value
		end
	end
end

-- First person Mourningstar (off by default): make the hub a place you can fight in.
--
-- The hub player is not a stripped-down version of the mission player by
-- accident -- it uses a different unit template, and the two differ by exactly
-- the 13 extensions that make combat work: SlotExtension (which minion target
-- selection crashes without), health, toughness, aim, attack intensity, mood,
-- music and smart tag, plus their husk counterparts. Patching each crash site
-- as it appears would be a long road; swapping the template restores all of
-- them at once.
--
-- Nearly all of this is *removing* the hub's overrides rather than inventing
-- values: the mission game mode sets no unit template override (so it gets
-- `player_character`), no default inventory, no wielded-slot override, and
-- allows vaulting. The mission template's third-person lock and its
-- unkillable/invulnerable modifiers come off too.
--
-- Death has no respawn here -- the hub game mode has no `respawn` block, same
-- as the Psykhanium -- so dying means returning to character select and coming
-- back in. That is the accepted behaviour, not an oversight.
local _first_person_hub_applied = nil

local _hub_defaults = {
	player_unit_template_name_override = GameModeSettings.hub.player_unit_template_name_override,
	default_wielded_slot_name = GameModeSettings.hub.default_wielded_slot_name,
	default_inventory = GameModeSettings.hub.default_inventory,
	use_third_person_hub_camera = GameModeSettings.hub.use_third_person_hub_camera,
	starting_character_state_name = GameModeSettings.hub.starting_character_state_name,
	default_player_orientation = GameModeSettings.hub.default_player_orientation,
	vaulting_allowed = GameModeSettings.hub.vaulting_allowed,
}

local _mission_defaults = {
	force_third_person_mode = Missions.hub_ship.force_third_person_mode,
	gameplay_modifiers = Missions.hub_ship.gameplay_modifiers,
	hud_elements = Missions.hub_ship.hud_elements,
}

-- Written before the session boots, because the game mode and mission template
-- are read during the load that follows. Changing the setting therefore takes
-- effect on the next hub load, not immediately.
local function _set_first_person_hub(enabled)
	if _first_person_hub_applied == enabled then
		return
	end

	_first_person_hub_applied = enabled

	local hub = GameModeSettings.hub
	local mission = Missions.hub_ship

	if enabled then
		hub.player_unit_template_name_override = nil
		hub.default_wielded_slot_name = nil
		hub.default_inventory = nil
		hub.use_third_person_hub_camera = nil
		hub.starting_character_state_name = nil
		hub.default_player_orientation = nil
		hub.vaulting_allowed = true
		mission.force_third_person_mode = nil
		mission.gameplay_modifiers = nil

		-- The hub HUD has no health bar, buffs, stamina, ammo or damage
		-- indicator. hud_loader falls back to hud_elements_player when the
		-- mission template does not name a list, so clearing it gives the full
		-- combat HUD -- same shape as every other field here.
		mission.hud_elements = nil

		mod:info("First person Mourningstar ON: full player unit template, real loadout, no invulnerability")
	else
		for key, value in pairs(_hub_defaults) do
			hub[key] = value
		end

		for key, value in pairs(_mission_defaults) do
			mission[key] = value
		end

		_log("First person Mourningstar OFF: stock hub settings restored")
	end
end

-- Replaces the hub-server client boot with a local one. Returns the session
-- object, matching what party_immaterium_hot_join_hub_server returns.
local function _boot_solo_hub(session_manager, entry)
	if _pending_session and not _pending_session:is_dead() then
		_trace("Solo hub boot already in flight, reusing it (entry: " .. tostring(entry) .. ")")

		return _pending_session
	end

	session_manager:clear_session_boot()

	_set_first_person_hub(mod:get("first_person_hub") == true)

	_pending_session = session_manager:boot_singleplayer_session()

	local mechanism_manager = Managers.mechanism

	_trace("Booting private Mourningstar (singleplayer session)"
		.. " -- entry: " .. tostring(entry)
		.. ", mechanism: " .. tostring(mechanism_manager and mechanism_manager:mechanism_name())
		.. ", host channel: " .. tostring(mechanism_manager and mechanism_manager._mechanism_host_channel))

	return _pending_session
end

-- The reasons MechanismLeftSession enumerates (mechanism_left_session.lua:23-38)
-- that mean a mission just ended or was abandoned. Everything else arriving
-- through left_session is not a mission -- notably "leave_to_hub", the
-- Psykhanium exit -- and stays under solo_hub_on_enter, as does character
-- select, which passes no reason at all. An unrecognised reason falls the same
-- way, so a reason Fatshark adds later behaves like the general case.
local MISSION_EXIT_REASONS = {
	failed_fetching_session_report = true,
	leave_mission = true,
	leave_mission_stay_in_party = true,
	session_completed = true,
	skip_end_of_round = true,
}

-- Read the reason rather than hooking the exit paths.
--
-- find_available_session is called from inside MechanismLeftSession:wanted_transition,
-- so by the time we get here the left-session mechanism is installed and its
-- init has already stored self._context.left_session_reason. One read covers
-- every route into the hub at once -- which matters, because enumerating exit
-- paths and missing one is the exact bug this is fixing.
local function _left_session_reason()
	local mechanism_manager = Managers.mechanism
	local mechanism = mechanism_manager and mechanism_manager._mechanism
	local context = mechanism and mechanism._context

	return context and context.left_session_reason
end

-- Character select "Enter Mourningstar", and every return-to-hub that goes
-- through MechanismLeftSession (leaving a mission, leaving the Psykhanium).
-- Vanilla routes both to _find_available_immaterium_session.
--
-- solo_hub_after_mission used to gate only the party_immaterium_hot_join_hub_server
-- hook below, which is one of *two* ways out of the end screen. The timer and
-- the player-summary continue fire game_score_done and land there; the main
-- Continue button instead calls multiplayer_session:leave("skip_end_of_round")
-- (end_view.lua:561-571), tearing the session down and returning to the hub
-- through MechanismLeftSession -- i.e. through here, which was gated only on
-- solo_hub_on_enter. So players who switched "after mission" off still got the
-- solo hub every time they clicked Continue.
mod:hook(CLASS.MultiplayerSessionManager, "find_available_session", function (func, self)
	local reason = _left_session_reason()
	local is_mission_exit = reason ~= nil and MISSION_EXIT_REASONS[reason] == true

	-- The mission-exit branch mirrors the hot-join hook's gate exactly
	-- (_solo_enabled() *and* solo_hub_after_mission) rather than treating the
	-- two settings as independent, so this changes nothing except closing the
	-- ungated path.
	if not _solo_enabled() or (is_mission_exit and not mod:get("solo_hub_after_mission")) then
		_trace("Passing find_available_session through to a public hub"
			.. " (left_session reason: " .. tostring(reason)
			.. ", mission exit: " .. tostring(is_mission_exit) .. ")")

		-- Heading for a public hub: it must never be loaded with the combat
		-- settings patched in.
		_set_first_person_hub(false)

		return func(self)
	end

	-- A party mission already in progress still wins: rejoining it is what the
	-- player asked for, and it has nothing to do with the hub.
	local party_immaterium = Managers.party_immaterium

	if party_immaterium and party_immaterium:game_session_in_progress() then
		return func(self)
	end

	_boot_solo_hub(self, "find_available_session (left_session reason: " .. tostring(reason) .. ")")

	return CLASS.StateLoading, {}
end)

-- StateMissionServerExit pre-boots a hub connection while the end-of-round
-- screen is up. Left alone it would drop the player into a public hub after
-- every mission, so it gets the same substitution -- but behind its own setting,
-- since it is the riskier of the two paths (a mission-server session is still
-- alive at this point).
mod:hook(CLASS.MultiplayerSessionManager, "party_immaterium_hot_join_hub_server", function (func, self)
	-- Same predicate other mods read, deliberately: one definition, so the
	-- published answer and the actual behaviour cannot disagree.
	if not mod.will_host_hub_after_mission() then
		-- Heading for a public hub, so the combat settings must come back off
		-- first -- the same reason the branch below and find_available_session
		-- both do it. This branch did not, and it is the one reached whenever
		-- solo_hub_after_mission is off.
		--
		-- The cost of missing it is not cosmetic. _set_first_person_hub(true)
		-- clears player_unit_template_name_override on the SHARED
		-- GameModeSettings.hub, so it applies to every player unit in the hub,
		-- remote ones included. Left patched in a public Mourningstar, the next
		-- stranger to hot-join has their husk built from the combat template,
		-- whose animation state machine carries no hub aim constraint target:
		--
		--   spawn_husk_unit -> wield_slot -> set_anim_state_machine
		--     -> PlayerUnitHubAimExtension.state_machine_changed
		--     -> HubAimConstraints.init -> animation_find_constraint_target
		--   "State machine has no constraint target named ... in unit ..."
		--
		-- A hard crash inside somebody else's husk spawn, seconds to minutes
		-- after arriving, with nothing on screen connecting it to a first-person
		-- setting. Found by tests/ingame/paths.sh row 6, not by a player.
		_set_first_person_hub(false)

		return func(self)
	end

	-- Already standing in a solo hub: this is the group-up vote, whose
	-- on_completed calls us once presence reads "hub" (it did nothing before
	-- the presence hook below made that true). Pass it through -- joining the
	-- party's hub server is the entire point of the vote, and re-booting here
	-- would swap the live session out from under a hub we are already in.
	if _in_solo_hub() then
		_log("Group-up vote or equivalent: joining the party's hub server")

		-- Same reason as above: a real hub server must load stock.
		_set_first_person_hub(false)

		return func(self)
	end

	return _boot_solo_hub(self, "party_immaterium_hot_join_hub_server (after mission)")
end)

-- The mechanism switch is deferred to here rather than done inside the hooks
-- above, for two reasons: find_available_session is called from inside
-- MechanismLeftSession:wanted_transition (changing the mechanism there deletes
-- the object mid-call), and vanilla likewise only sets the mechanism once the
-- session is established -- via rpc_set_mechanism from the hub server.
mod:hook_safe(CLASS.MultiplayerSessionManager, "update", function (self, dt)
	_keep_pacing_disabled()
	_hold_latency_mod_off("ArtificialLatency", "al_ms", "al_ms")
	_hold_latency_mod_off("Realms Latency", "latency_ms", "rl_latency_ms")
	_keep_local_player_local()

	if not _pending_session then
		return
	end

	if _pending_session:is_dead() then
		_log("Solo hub session died before it could take the hub mechanism")

		_pending_session = nil

		return
	end

	if not self:is_ready() then
		return
	end

	_pending_session = nil

	local mechanism_manager = Managers.mechanism

	if not mechanism_manager then
		return
	end

	-- Deliberately unconditional, including when the mechanism is already "hub".
	-- The name cannot tell a healthy hub mechanism from a stale one parked in
	-- MechanismHub's terminal `client_wait_for_server` state, which is where
	-- leaving the hub for a mission puts it (`client_exit_gameplay` fires from
	-- MultiplayerSessionManager.update). If that join then fails, the mechanism
	-- it was waiting for never arrives and its wanted_transition returns false
	-- forever -- StateLoading spins on "Communicating with Fatshark backend".
	-- Skipping the change there left the dead mechanism in charge of a session
	-- we had just booted. A fresh session always gets a fresh mechanism;
	-- change_mechanism deletes the old one first, so this is safe to repeat.
	-- PART 1 of the mission-channel teardown. Parts 2 and 3 are the two
	-- MechanismManager hooks further down; all three exist for one reason:
	--
	--   Taking the hub mechanism after a mission does not close the mission
	--   server's channel. change_mechanism clears neither
	--   `_mechanism_host_channel` nor the events registered on that channel
	--   (mechanism_manager.lua:238-272) -- only MechanismManager.disconnect
	--   does, and nothing was calling it. So a dedicated server we have walked
	--   away from stays wired to this client until it times out a minute later.
	--
	-- This part closes it at the source, which is the only one of the three that
	-- removes the condition rather than surviving it.
	--
	-- The confirmed consequence of leaving it open is a hard crash: with the
	-- channel live, rpc_mechanism_event still fires for this client, so the
	-- server's end-of-round game_score_done is dispatched into MechanismHub,
	-- which has no such handler -- a nil call inside the RPC dispatcher with no
	-- pcall above it, ~45s after a mission the player already left. Reproduced
	-- twice with full dumps (2026-09-08).
	--
	-- A latent second consequence, never observed but cheap to close here:
	-- wanted_transition branches on the same field (mechanism_manager.lua:277-290)
	-- and with it set calls leave_mechanism() instead of change_mechanism("hub").
	--
	-- pcall'd because unregister_channel_events indexes
	-- _registered_channel_objects with no nil check
	-- (network_event_delegate.lua), so disconnecting a channel something else
	-- already tore down would throw. disconnect() nils _mechanism_host_channel
	-- first -- the part that actually matters -- and the change_mechanism below
	-- repeats the leave_mechanism it might have skipped, so a partial failure
	-- still lands somewhere valid.
	local previous_mechanism = mechanism_manager:mechanism_name()
	local host_channel = mechanism_manager._mechanism_host_channel

	if host_channel then
		_trace("Dropping stale mechanism host channel " .. tostring(host_channel)
			.. " (mechanism " .. tostring(previous_mechanism) .. ") before taking the hub")

		local ok, err = pcall(mechanism_manager.disconnect, mechanism_manager, host_channel)

		if not ok then
			_trace("Disconnect from channel " .. tostring(host_channel)
				.. " failed, continuing anyway: " .. _escaped(err))
		end

		-- Belt and braces: disconnect nils this itself, but if it threw before
		-- getting there, the wanted_transition branch above is still armed.
		mechanism_manager._mechanism_host_channel = nil
	end

	_trace("Solo hub session ready, changing to the hub mechanism as owner"
		.. " (previous mechanism: " .. tostring(previous_mechanism)
		.. ", had host channel: " .. tostring(host_channel) .. ")")
	mechanism_manager:change_mechanism(HUB_MECHANISM, {})
end)

-- PART 2 of the mission-channel teardown. See PART 1 above the swap.
--
-- The backstop for the crash PART 1 is meant to prevent, for the frames where
-- the channel is still open: between the mission ending and the swap, and after
-- a PART 1 disconnect that threw inside its pcall.
--
-- rpc_mechanism_event does `mechanism[event_name](mechanism)` with no lookup
-- check, and MechanismHub implements neither game_score_done nor
-- victory_defeat_done (mechanism_hub.lua has client_exit_gameplay,
-- all_players_ready and failed_fetching_session_report, and that is all). So an
-- event arriving from the mission server while the hub mechanism is installed is
-- a nil call in the RPC dispatcher with no pcall above it. Three quarters of a
-- minute after a mission the player has already walked away from, which is why
-- it survived testing: nothing on screen connects the crash to its cause.
--
-- Expect this to be silent in a healthy session -- PART 1 unregisters the
-- channel first, so there is nothing left to drop, and the 2026-09-13 logs show
-- zero firings. A `[trace] Dropping mechanism event` line in a report means a
-- channel got past PART 1 and is worth reading closely.
--
-- Deliberately not gated on _solo_enabled() or solo_hub_after_mission. The
-- window this covers is precisely the one where the mod's own state says it is
-- finished, and dropping an event the installed mechanism cannot handle beats
-- crashing in every case, ours or not. A nil event_name (an id this build does
-- not know) falls into the same branch rather than reaching a table index, which
-- is a second thing vanilla does not check.
mod:hook(CLASS.MechanismManager, "rpc_mechanism_event", function (func, self, channel_id, event_id)
	local event_name = self.EVENT_LOOKUP[event_id]
	local mechanism = self._mechanism

	if not mechanism or type(mechanism[event_name]) ~= "function" then
		-- _trace, not _log: if this ever fires after 0.3.2 it means a channel
		-- got past the disconnect above, and that is the first thing we would
		-- want to see in the reporter's log rather than a silent swallow.
		_trace("Dropping mechanism event " .. tostring(event_name) .. " from channel "
			.. tostring(channel_id) .. " -- mechanism " .. tostring(self._mechanism_name)
			.. " has no handler for it")

		return
	end

	return func(self, channel_id, event_id)
end)

-- PART 3 of the mission-channel teardown. See PART 1 above the swap.
--
-- LocalDisconnectedState.init (local_disconnected_state.lua:15) calls
-- Managers.mechanism:disconnect for any channel that finishes dying, gated only
-- on started_state_sync and never on whether that channel is still the
-- mechanism host -- and disconnect ends in an unconditional leave_mechanism()
-- with no comparison against _mechanism_host_channel. So when the abandoned
-- mission connection reaps itself, 50 to 80 seconds later, it destroys whatever
-- mechanism is installed at that moment: the hub the player is standing in.
--
-- Vanilla is safe only because it never holds a mechanism a dead channel does
-- not own. We do, from the moment we take the hub while a mission server is
-- still connected.
--
-- Comparing the channel also makes PART 2's proactive disconnect safe: that one
-- runs while the channel still matches, so it passes through, and the later reap
-- then stops here on nil ~= 3. Without this guard the second call would reach
-- unregister_channel_events, which indexes _registered_channel_objects[name] and
-- reads .__size off it with no nil check -- a throw inside the connection state
-- machine. The two are a pair; removing either one re-arms the other.
--
-- Scope, honestly: this does NOT fix the "straight to operative select" reports.
-- Those came through MultiplayerSessionManager._handle_session_error, and their
-- cause was a conflict with InstantHub 3.x "Reserve Mourningstar Server", not
-- this. Confirmed firing and holding in the 2026-09-13 logs, but what it buys is
-- the hub surviving the reap -- not the bounce.
mod:hook(CLASS.MechanismManager, "disconnect", function (func, self, channel_id)
	local host_channel = self._mechanism_host_channel

	if host_channel ~= channel_id then
		_trace("Ignoring disconnect for channel " .. tostring(channel_id)
			.. " -- not our mechanism host (" .. tostring(host_channel) .. "), mechanism "
			.. tostring(self._mechanism_name) .. " stays")

		return
	end

	return func(self, channel_id)
end)

-- Presence is derived from the session's host type, so a locally hosted hub
-- reports "training_grounds" -- PresenceSettings.evaluate_presence maps
-- HOST_TYPES.singleplay to onboarding/training_grounds with no notion of which
-- level is loaded. That breaks starting a mission: MissionBoardView gates the
-- play button on PartyImmateriumManager.are_all_members_in_hub, whose first
-- line is `self:get_myself():presence_name() ~= "hub"`, so in a party of one
-- the "team mate not available" is you.
--
-- Fixing it here rather than at presence_name (which is what psych_ward does
-- for the Psykhanium) means the correction reaches everything downstream at
-- once: the mission board gate, the HUD and social presence text, and the
-- activity id the presence manager syncs to the backend.
--
-- Note this also makes the group-up vote's on_completed fire (it is gated on
-- `Managers.presence:presence() == "hub"`), which is why the hot-join hook
-- above passes through when we are already in a solo hub.
mod:hook(PresenceSettings, "evaluate_presence", function (func, game_state)
	local activity_id = func(game_state)

	if activity_id ~= "training_grounds" and activity_id ~= "onboarding" then
		return activity_id
	end

	if not _in_solo_hub() then
		return activity_id
	end

	-- Mirrors the hub_server branch of evaluate_presence, so the sub-states it
	-- reports (loading, matchmaking, cinematic) still happen in the solo hub.
	local player = Managers.player:local_player_safe(1)

	if not player or not player:unit_is_alive() then
		return "loading"
	end

	local party_immaterium = Managers.party_immaterium

	if party_immaterium then
		local matchmaking_state = party_immaterium:current_state()

		if matchmaking_state == PartyState.matchmaking or matchmaking_state == PartyState.matchmaking_acceptance_vote then
			return "matchmaking"
		end
	end

	if Managers.multiplayer_session:is_booting_session() then
		return "matchmaking"
	end

	local cinematic_manager = Managers.state and Managers.state.cinematic

	if cinematic_manager and (cinematic_manager:waiting_for_player_input() or cinematic_manager:is_playing()) then
		return "cinematic"
	end

	return "hub"
end)

-- Hosting the hub creates server-only managers a hub client never has:
-- gameplay_init_step_managers.lua builds Managers.state.pacing only `if
-- is_server`. The hub's init chain then skips GameplayInitStepPacing entirely
-- (the log goes FinalizeNavigation -> PlayerEnterGame), so
-- PacingManager.on_gameplay_post_init never runs -- and that is the call that
-- would have set `_disabled = not main_path_available`. Without it the manager
-- keeps the `false` from its own init and starts ticking sub-pacers in a level
-- with no main path and no spawn points.
--
-- SpecialsPacing then reads self._template, which is only ever assigned by
-- on_spawn_points_generated, and dies on nil about 40 seconds into standing in
-- the hub. Disabling pacing here is what vanilla would have done anyway, and
-- closer still to a real hub, which has no pacing manager at all.
mod:hook_safe(PacingManager, "init", function (self, ...)
	if not _in_solo_hub() then
		return
	end

	_log("Disabling pacing in the solo hub (no main path, no spawn points)")
	self:set_enabled(false)

	if self._specials_pacing then
		self._specials_pacing._disabled = true
	end
end)

-- The order-independent half of the fix, and the one that actually caught the
-- reported crash: it does not matter who enables pacing or when, because a nil
-- template means this update has nothing it could meaningfully do. Only
-- SpecialsPacing needs this -- the other sub-pacers take their template from
-- PacingManager.init, which falls back to a default; specials is the one that
-- gets its own later, from on_spawn_points_generated, which a level with no
-- spawn points never triggers. One log line, not one per frame.
local _warned_missing_template = false

mod:hook(SpecialsPacing, "update", function (func, self, ...)
	if self._template == nil then
		if not _warned_missing_template then
			_warned_missing_template = true

			mod:info("Skipping specials pacing update: no pacing template for this level")
		end

		return
	end

	return func(self, ...)
end)

-- The frame-level clear above is not enough on its own: ArtificialLatency also
-- re-applies the flag from its own hook on PlayerUnitSpawnManager.owner, which
-- the game calls many times a frame (HUD, UI, teleports, damage code), so a
-- once-per-frame clear loses the race.
--
-- DMF runs hook chains newest-first and mods hook in load order, so this hook --
-- registered by the last mod in the load order -- wraps theirs: call through,
-- let them write the flag, then clear it before the caller sees the result.
-- Ordered cheaply because owner() is a hot path: the flag test rejects almost
-- every call, and the peer test rejects genuine remote players in missions
-- before the more expensive solo-hub check runs.
mod:hook(PlayerUnitSpawnManager, "owner", function (func, self, unit)
	local owner = func(self, unit)

	if not owner or not owner.remote then
		return owner
	end

	if not owner.peer_id or owner:peer_id() ~= Network.peer_id() then
		return owner
	end

	if not _in_latency_suppressed_hub() then
		return owner
	end

	owner.remote = nil

	if not _warned_cleared_remote then
		_warned_cleared_remote = true

		mod:info("Cleared a 'remote' flag on the local player in the solo hub (it hides the hub UI)")
	end

	return owner
end)

-- Out-of-bounds despawns are terminal in the hub. `_on_player_soft_oob` calls
-- despawn_player_safe, and nothing puts the player back: respawn is gated on
-- `self._settings.respawn` in game_mode_coop_complete_objective, and the hub
-- game mode settings have no respawn block at all. So once your unit is gone
-- you stay unitless until you leave, and every hub view that assumes a live
-- player unit crashes on open -- HavocPlayView dies dereferencing
-- `player_unit_spawn:owner(nil)`.
--
-- Hosting is why this reaches us at all: the OOB check runs on the server, and
-- in a public hub that is not this machine. So suppress the despawn, but only
-- in a hub we host -- missions keep vanilla behaviour, where the despawn is
-- load-bearing and respawning does work.
--
-- The trade-off: nothing rescues a player who is genuinely below the map. If
-- that turns out to matter more than the crash, the other option is respawning
-- at a hub spawn point instead of suppressing.
local _warned_suppressed_oob = false

mod:hook(PlayerUnitSpawnManager, "_on_player_soft_oob", function (func, self, unit)
	if not _in_solo_hub() then
		return func(self, unit)
	end

	if not _warned_suppressed_oob then
		_warned_suppressed_oob = true

		mod:info("Suppressed an out-of-bounds player despawn in the solo hub (nothing would respawn you)")
	end
end)

-- Changing archetype in a hub we host has to go through the synchronizer host.
--
-- A mod that swaps characters in the hub (InstantCharacterChange) calls
-- player:set_profile() directly. Against a real hub server that is harmless --
-- local data, and the server owns spawning. Here we ARE the server, so
-- PackageSynchronizerHost reacts to the profile change and starts loading and
-- unloading item packages that nothing sequenced, which is a good candidate for
-- the engine crash seen after an in-hub character switch (no Lua error, no
-- frame to catch -- ICC's own notes describe a native refcount assertion from
-- set_profile racing package loads).
--
-- The game has a supported path for exactly this, and ICC already uses it in
-- the Psykhanium: ProfileSynchronizerHost:override_singleplay_profile ->
-- set_profile -> PackageSynchronizerHost despawns the unit, loads the new
-- class' packages and respawns on the spot. It is gated there on a game-mode
-- allowlist (training_grounds / shooting_range) that predates hosted hubs, so
-- our hub misses it despite passing the check that actually matters -- being
-- the host.
--
-- So route it: an archetype-changing set_profile on the local player becomes an
-- override_singleplay_profile call with the same profile. Same destination, no
-- loading screen, and it is mod-agnostic -- nothing here reads ICC's state.
-- Same-archetype set_profile calls (every loadout and talent edit) pass
-- through untouched.
local _routing_character_id = nil

mod:hook(CLASS.HumanPlayer, "set_profile", function (func, self, profile)
	if not profile or not _in_solo_hub() then
		return func(self, profile)
	end

	-- The synchronizer host applying what we routed: this is the call we asked
	-- for, so let it through.
	if _routing_character_id and profile.character_id == _routing_character_id then
		_routing_character_id = nil

		return func(self, profile)
	end

	local ok_local, is_local = pcall(function ()
		return self:peer_id() == Network.peer_id()
	end)

	if not ok_local or not is_local then
		return func(self, profile)
	end

	local current = self:profile()
	local current_archetype = current and current.archetype and current.archetype.name
	local new_archetype = profile.archetype and profile.archetype.name

	if not current_archetype or not new_archetype or current_archetype == new_archetype then
		return func(self, profile)
	end

	local ok_host, host = pcall(function ()
		return Managers.profile_synchronization:synchronizer_host()
	end)

	if not ok_host or not host then
		mod:info("Archetype change in the solo hub but no synchronizer host; skipping the in-place swap")

		return
	end

	_routing_character_id = profile.character_id

	local ok_route = pcall(function ()
		host:override_singleplay_profile(self:peer_id(), self:local_player_id(), profile)
	end)

	if ok_route then
		mod:info("Routed an archetype change (" .. current_archetype .. " -> " .. new_archetype
			.. ") through override_singleplay_profile; respawn incoming")

		return
	end

	_routing_character_id = nil

	mod:info("override_singleplay_profile failed; skipping the in-place swap so it cannot crash"
		.. " (the switch stays armed for your next travel)")
end)

-- Block creature_spawner (and anything routed through it) from spawning a mob
-- in the solo hub while the player is not in first-person combat mode.
--
-- The social-hub player unit has no slot_system extension. When a spawned
-- minion picks the player as a new target, MinionTargetSelection.occupied_slots_weight
-- indexes that missing extension and hard-crashes the game
-- (scripts/utilities/minion_target_selection.lua). Players kept triggering the
-- spawn keybind with chat open -- creature_spawner's own guard only blocks when
-- chat has input FOCUS, not merely when the chat box is visible -- and crashing.
--
-- First-person Mourningstar swaps in the full mission template, which has
-- slot_system (and the other 12 combat extensions), so spawning is safe there.
-- Gating on the extension actually being present, rather than on our setting,
-- is correct regardless of how the player got here (the setting only applies on
-- the next hub load).
local function _player_can_be_targeted_safely()
	local player = Managers.player and Managers.player:local_player_safe(1)
	local unit = player and player.player_unit

	if not unit or not Unit.alive(unit) then
		return false
	end

	return ScriptUnit.has_extension(unit, "slot_system") ~= nil
end

local _warned_blocked_spawn = false

mod.on_all_mods_loaded = function ()
	local creature_spawner = get_mod("creature_spawner")

	if not creature_spawner or type(creature_spawner.spawn_breed_at_cursor) ~= "function" then
		return
	end

	mod:hook(creature_spawner, "spawn_breed_at_cursor", function (func, self, breed_name)
		if _in_solo_hub() and not _player_can_be_targeted_safely() then
			if not _warned_blocked_spawn then
				_warned_blocked_spawn = true

				mod:info("Blocked a creature_spawner spawn in the solo hub: the hub character has no slot_system extension and a targeting minion would crash the game. Turn on First person Mourningstar to fight.")
			end

			mod:echo("[Solo Mourningstar] Enable First person Mourningstar to spawn enemies here.")

			return
		end

		return func(self, breed_name)
	end)

	mod:info("Guarding creature_spawner spawns in the non-combat solo hub")
end

-- Petting the companion dog crashes in first-person Mourningstar.
--
-- The dog's hub interaction plays an animation on the PLAYER unit
-- (CompanionInteractionsManager.start_interaction_animation ->
-- AnimationSystem.play_companion_interaction_anim_event ->
-- Unit.animation_find_variable). The social-hub player template carries that
-- companion-interaction animation variable; the full combat template that
-- first-person mode swaps in does not, so the variable lookup hard-crashes.
--
-- This is the exact mirror of the spawn guard above. The combat template HAS
-- slot_system (so it can be targeted and fought); the social template does not.
-- So one signal gates both: block spawning when there is no slot_system (social
-- template can't be targeted), block dog-petting when there IS (combat template
-- can't play the companion animation).
--
-- Blocked at the host-side "is the dog in position to start" gate, before any
-- animation is attempted, so nothing half-starts. In solo we are always host and
-- the only player, so this is the only path that reaches the crash; the remote
-- client rpc paths never fire.
local _warned_blocked_companion = false

mod:hook(CLASS.CompanionInteractionsManager, "companion_is_in_position_for_interaction",
	function (func, self, companion_owner_unit, companion_unit)
		if _in_solo_hub()
			and companion_owner_unit
			and ScriptUnit.has_extension(companion_owner_unit, "slot_system") then
			if not _warned_blocked_companion then
				_warned_blocked_companion = true

				mod:info("Blocked a companion (dog) hub interaction in the first-person solo hub: the combat player template has no companion-interaction animation and the petting animation would crash. Petting works in the normal third-person Mourningstar.")
			end

			return
		end

		return func(self, companion_owner_unit, companion_unit)
	end)

-- Entering the Psykhanium from a solo hub dies on vanilla's `reset_seed`.
--
-- TrainingGroundsOptionsView._start_training_grounds boots a singleplayer
-- session and then calls `Managers.connection:reset_seed()` on the connection it
-- assumes that boot just rebuilt. Hosting the hub means Realms already has a
-- live listen host, so its `replace_singleplayer_boot` takes the reuse branch
-- and hands the running session straight back -- deliberately, because a shared
-- Psykhanium is a Realms feature, not an accident -- and the connection is never
-- rebuilt. `reset_seed` is not on it, so the Start button dies with "attempt to
-- call method 'reset_seed' (a nil value)".
--
-- Realms already supports the move we actually want: `queue_mission_transition`
-- swaps the map on the session that is already running, so anyone in the hub
-- comes along and no vanilla code gets to assume a fresh connection. Take that
-- route only when every part of it is true and leave vanilla alone otherwise --
-- without a Realms host the stock path is correct and must not be touched.
-- Returns the Realms mod when it is hosting, or nil plus the reason it is not.
-- The reason is only for the log, but this hook is silent when it declines and
-- a wrong guard here looks exactly like the hook never running at all.
local function _realms_host()
	local realms = get_mod("Realms")

	if not realms then
		return nil, "Realms not installed"
	end
	if not realms:is_enabled() then
		return nil, "Realms disabled"
	end
	if type(realms.queue_mission_transition) ~= "function" then
		return nil, "Realms has no queue_mission_transition"
	end

	local session = realms._session

	if type(session) ~= "table" or type(session.is_active_host) ~= "function" then
		return nil, "Realms session API missing"
	end

	-- `is_active_host` is the same test Realms uses to decide whether to reuse
	-- the host, so it is exactly the test for whether vanilla's assumption
	-- breaks. Deliberately the ONLY condition: `_in_solo_hub()` looks like the
	-- obvious extra guard and is wrong here, because once Realms installs its
	-- listen host the session reports host_type "player" rather than
	-- "singleplay", so that helper is false throughout the hub we are hosting.
	if not session.is_active_host() then
		return nil, "Realms is not hosting"
	end

	return realms
end

-- String form, not CLASS: the view does not exist until it is first opened, and
-- DMF holds the hook until it does.
mod:hook("TrainingGroundsOptionsView", "_start_training_grounds", function (func, self, mechanism_context)
	local realms, why = _realms_host()

	if not realms then
		_log("Psykhanium: leaving the vanilla path alone (" .. tostring(why) .. ")")

		return func(self, mechanism_context)
	end

	-- We are replacing the tail of the vanilla function, so the work it does
	-- first has to happen here too. The challenge level is the part that
	-- matters: drop it and the difficulty stepper silently stops doing anything.
	local difficulty_stepper = self:_element("difficulty_selector")
	local danger_level = difficulty_stepper and difficulty_stepper:get_current_selected_difficulty() or 1
	local difficulty_setting = DangerSettings[danger_level]

	mechanism_context.challenge_level = difficulty_setting and difficulty_setting.challenge or 1

	-- Read the level before queueing: the transition begins by taking the
	-- mechanism out of gameplay.
	local mission_manager = Managers.state and Managers.state.mission
	local level = mission_manager and mission_manager:mission_level()
	local ok, queued, queue_error = pcall(realms.queue_mission_transition, mod, mechanism_context)

	if not ok or not queued then
		_log("Realms would not take the Psykhanium transition ("
			.. tostring(ok and queue_error or queued) .. "), using the vanilla path")

		return func(self, mechanism_context)
	end

	-- Only once the transition is accepted, so falling back cannot fire these
	-- twice.
	Managers.ui:play_2d_sound(TrainingGroundsSoundEvents.tg_hub_button)

	if level then
		Level.trigger_event(level, "training_grounds_started")
	end
end)

mod:command("solohub", mod:localize("command_description"), function ()
	local session_manager = Managers.multiplayer_session
	local host_type = session_manager and session_manager:host_type() or "none"
	local mechanism_manager = Managers.mechanism
	local mechanism_name = mechanism_manager and mechanism_manager:mechanism_name() or "none"
	local game_mode_manager = Managers.state and Managers.state.game_mode
	local game_mode_name = game_mode_manager and game_mode_manager:game_mode_name() or "none"

	mod:echo("Solo Mourningstar " .. mod.version .. ": " .. (_solo_enabled() and "on" or "off"))
	mod:echo("  host type: " .. tostring(host_type))
	mod:echo("  mechanism: " .. tostring(mechanism_name))
	mod:echo("  game mode: " .. tostring(game_mode_name))

	local party_immaterium = Managers.party_immaterium
	local myself = party_immaterium and party_immaterium:get_myself()

	mod:echo("  presence: " .. tostring(myself and myself:presence_name() or "none")
		.. " (must be 'hub' to start a mission)")

	local player = Managers.player:local_player_safe(1)

	mod:echo("  player unit: " .. (player and player.player_unit and "alive" or "MISSING")
		.. " (missing crashes hub terminals on open)")

	if _pending_session then
		mod:echo("  waiting on a booting solo hub session")
	end

	local mechanism_host_channel = mechanism_manager and mechanism_manager._mechanism_host_channel

	-- The field behind both 0.3.x bugs. In a solo hub it must be nil; a number
	-- here means a mission server still owns this client's mechanism events and
	-- the next transition will bounce to operative select.
	mod:echo("  mechanism host channel: " .. tostring(mechanism_host_channel)
		.. (mechanism_host_channel and " (STALE -- report this)" or " (clear)"))
end)

-- Load banner, deliberately last and deliberately unconditional.
--
-- Three reporter logs came in against 0.3.0/0.3.1 and none of them could be
-- told apart by build: nothing this mod writes at load carried a version, and
-- the lines that did appear were unconditional mod:info calls that have looked
-- the same since 0.2.x. That made "are they even running the fixed build"
-- unanswerable, and it was the slowest part of the whole investigation. One
-- line at load fixes that permanently.
_trace("SoloMourningstar " .. mod.version .. " loaded"
	.. " (solo_hub_on_enter: " .. tostring(mod:get("solo_hub_on_enter"))
	.. ", solo_hub_after_mission: " .. tostring(mod:get("solo_hub_after_mission"))
	.. ", first_person_hub: " .. tostring(mod:get("first_person_hub"))
	.. ", debug_logging: " .. tostring(mod:get("debug_logging")) .. ")")
