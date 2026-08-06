local mod = get_mod("SoloMourningstar")

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

local MatchmakingConstants = require("scripts/settings/network/matchmaking_constants")
local PartyConstants = require("scripts/settings/network/party_constants")
local PresenceSettings = require("scripts/settings/presence/presence_settings")

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

-- Replaces the hub-server client boot with a local one. Returns the session
-- object, matching what party_immaterium_hot_join_hub_server returns.
local function _boot_solo_hub(session_manager)
	if _pending_session and not _pending_session:is_dead() then
		return _pending_session
	end

	session_manager:clear_session_boot()

	_pending_session = session_manager:boot_singleplayer_session()

	_log("Booting private Mourningstar (singleplayer session)")

	return _pending_session
end

-- Character select "Enter Mourningstar", and every return-to-hub that goes
-- through MechanismLeftSession (leaving a mission, leaving the Psykhanium).
-- Vanilla routes both to _find_available_immaterium_session.
mod:hook(CLASS.MultiplayerSessionManager, "find_available_session", function (func, self)
	if not _solo_enabled() then
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

mod:command("solohub", mod:localize("command_description"), function ()
	local session_manager = Managers.multiplayer_session
	local host_type = session_manager and session_manager:host_type() or "none"
	local mechanism_manager = Managers.mechanism
	local mechanism_name = mechanism_manager and mechanism_manager:mechanism_name() or "none"
	local game_mode_manager = Managers.state and Managers.state.game_mode
	local game_mode_name = game_mode_manager and game_mode_manager:game_mode_name() or "none"

	mod:echo("Solo Mourningstar: " .. (_solo_enabled() and "on" or "off"))
	mod:echo("  host type: " .. tostring(host_type))
	mod:echo("  mechanism: " .. tostring(mechanism_name))
	mod:echo("  game mode: " .. tostring(game_mode_name))

	local party_immaterium = Managers.party_immaterium
	local myself = party_immaterium and party_immaterium:get_myself()

	mod:echo("  presence: " .. tostring(myself and myself:presence_name() or "none")
		.. " (must be 'hub' to start a mission)")

	if _pending_session then
		mod:echo("  waiting on a booting solo hub session")
	end
end)
