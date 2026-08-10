local mod = get_mod("SoloMourningstar")

-- Single source of truth for the version: release_mod.py reads it from here to
-- name the zip, and /solohub reports it so a user's screenshot says which build
-- they are on.
mod.version = "0.2.2"

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

local GameModeSettings = require("scripts/settings/game_mode/game_mode_settings")
local MatchmakingConstants = require("scripts/settings/network/matchmaking_constants")
local Missions = require("scripts/settings/mission/mission_templates")
local PacingManager = require("scripts/managers/pacing/pacing_manager")
local PartyConstants = require("scripts/settings/network/party_constants")
local PlayerUnitSpawnManager = require("scripts/managers/player/player_unit_spawn_manager")
local PresenceSettings = require("scripts/settings/presence/presence_settings")
local SpecialsPacing = require("scripts/managers/pacing/specials_pacing/specials_pacing")

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

local function _solo_enabled()
	return mod:is_enabled() and mod:get("solo_hub_on_enter")
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

local function _keep_local_player_local()
	if not _in_solo_hub() then
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

-- Better than clearing: stop ArtificialLatency writing the flag at all.
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
-- `_in_solo_hub()` is already true during loading, so the cache is zero before
-- that callback runs.
--
-- The restore reads their own setting rather than a value we remembered, so a
-- latency change made while in the hub is not clobbered on the way out. This is
-- the one place the mod reaches into another mod's internals; the generic
-- clears stay as the mod-agnostic net, and cover anything else that flags the
-- local player remote.
local _al_suppressed = false

local function _hold_artificial_latency_off()
	local artificial_latency = get_mod("ArtificialLatency")
	local settings = artificial_latency and artificial_latency.settings

	if type(settings) ~= "table" then
		return
	end

	if _in_solo_hub() then
		if settings.al_ms ~= 0 then
			settings.al_ms = 0

			if not _al_suppressed then
				_al_suppressed = true

				mod:info("Holding ArtificialLatency at 0 ms while in the solo hub (its remote flag hides the hub UI)")
			end
		end
	elseif _al_suppressed then
		_al_suppressed = false

		local ok, value = pcall(function ()
			return artificial_latency:get("al_ms")
		end)

		if ok and value then
			settings.al_ms = value
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
local function _boot_solo_hub(session_manager)
	if _pending_session and not _pending_session:is_dead() then
		return _pending_session
	end

	session_manager:clear_session_boot()

	_set_first_person_hub(mod:get("first_person_hub") == true)

	_pending_session = session_manager:boot_singleplayer_session()

	_log("Booting private Mourningstar (singleplayer session)")

	return _pending_session
end

-- Character select "Enter Mourningstar", and every return-to-hub that goes
-- through MechanismLeftSession (leaving a mission, leaving the Psykhanium).
-- Vanilla routes both to _find_available_immaterium_session.
mod:hook(CLASS.MultiplayerSessionManager, "find_available_session", function (func, self)
	if not _solo_enabled() then
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

	_boot_solo_hub(self)

	return CLASS.StateLoading, {}
end)

-- StateMissionServerExit pre-boots a hub connection while the end-of-round
-- screen is up. Left alone it would drop the player into a public hub after
-- every mission, so it gets the same substitution -- but behind its own setting,
-- since it is the riskier of the two paths (a mission-server session is still
-- alive at this point).
mod:hook(CLASS.MultiplayerSessionManager, "party_immaterium_hot_join_hub_server", function (func, self)
	if not (_solo_enabled() and mod:get("solo_hub_after_mission")) then
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

	return _boot_solo_hub(self)
end)

-- The mechanism switch is deferred to here rather than done inside the hooks
-- above, for two reasons: find_available_session is called from inside
-- MechanismLeftSession:wanted_transition (changing the mechanism there deletes
-- the object mid-call), and vanilla likewise only sets the mechanism once the
-- session is established -- via rpc_set_mechanism from the hub server.
mod:hook_safe(CLASS.MultiplayerSessionManager, "update", function (self, dt)
	_keep_pacing_disabled()
	_hold_artificial_latency_off()
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

	if mechanism_manager:mechanism_name() == HUB_MECHANISM then
		return
	end

	_log("Solo hub session ready, changing to the hub mechanism as owner")
	mechanism_manager:change_mechanism(HUB_MECHANISM, {})
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

	if not _in_solo_hub() then
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
end)
