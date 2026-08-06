# Solo Mourningstar

Loads the Mourningstar as a private, locally hosted instance instead of joining
a public hub server.

## Why it works

The hub level is local content and the hub mechanism already supports running
without a server. Three facts from the decompiled source:

- `om_hub_01` / `om_hub_02` (onboarding) load `content/levels/hub/hub_ship/...`
  in a client-hosted singleplayer session — `game_mode_name = "prologue_hub"`,
  which is `host_singleplay = true`.
- `MechanismHub.init` sets `self._is_owner = server_channel == nil` and only
  enters sync mode when a server channel exists. Its `init_hub` state performs
  the `StateLoading → StateGameplay` transition itself; its one backend call
  (`get_hub_config`) has a `:catch` fallback.
- `MechanismManager.wanted_transition` already does
  `self:change_mechanism("hub", {})` — hub-mechanism-as-owner is a path the game
  takes itself when a hosted mechanism finishes.

Fatshark also left `game_mode_settings.hub_singleplay` in the retail build (a
clone of `hub` with `host_singleplay = true`). This mod does **not** use it: the
game mode name is compared against the string `"hub"` in a lot of vanilla and
mod UI code, so the mod keeps the stock `hub` game mode and changes only which
connection backs the session.

## What it does

Two hooks on `MultiplayerSessionManager`, plus a deferred mechanism switch:

| Hook | Covers |
| --- | --- |
| `find_available_session` | "Enter Mourningstar" from character select, and every return-to-hub routed through `MechanismLeftSession` (leaving a mission or the Psykhanium) |
| `party_immaterium_hot_join_hub_server` | the hub connection `StateMissionServerExit` pre-boots behind the end-of-round screen |
| `update` (hook_safe) | hands the hub mechanism to the session once it is live |

Plus one hook on `PresenceSettings.evaluate_presence` — see below.

Both hooks call `boot_singleplayer_session()` where the game would have booted a
`PartyImmateriumHubSessionBoot`. The mechanism switch is deferred to `update`
rather than done inline because `find_available_session` is called from inside
`MechanismLeftSession:wanted_transition` — changing the mechanism there would
delete the object mid-call — and because vanilla likewise only sets the
mechanism once the session is established (via `rpc_set_mechanism`).

`_pending_session` doubles as a re-entrancy guard: `find_available_session` is
polled every frame while `MechanismLeftSession` waits, and without it each poll
would tear down the boot in progress and start over.

An in-progress party game session still takes priority — that branch is passed
through to vanilla so rejoining a mission works unchanged.

## Presence

`PresenceSettings.evaluate_presence` derives presence from the session's host
type alone, so a locally hosted hub reports `training_grounds` — it maps
`HOST_TYPES.singleplay` to onboarding/training_grounds with no notion of which
level is loaded.

That breaks starting a mission. `MissionBoardView._update_info_state` gates the
play button on `PartyImmateriumManager.are_all_members_in_hub`, whose first line
is `self:get_myself():presence_name() ~= "hub"` — so in a party of one, the
"team mate not available" message is about you.

The mod hooks `evaluate_presence` and returns `"hub"` when the vanilla answer is
`training_grounds`/`onboarding` but we are actually in a solo hub
(host type `singleplay` + mechanism `hub`), mirroring the `hub_server` branch so
the `loading` / `matchmaking` / `cinematic` sub-states still report correctly.

Fixing it there rather than at `presence_name` — which is what psych_ward does
for the Psykhanium — means the correction reaches the mission board gate, the
HUD and social presence text, and the activity id the presence manager syncs to
the backend, all at once.

`require` returns the same cached table the presence manager holds, and retail's
`settings()` is just `return data_table` (no read-only proxy), so the table field
is directly hookable.

### Knock-on effects of reporting "hub"

Presence is synced outward, so party members see you "In the Mourningstar" and
`presence_settings.settings.hub` advertises you as joinable
(`advertise_playing` / `can_be_invited` / `can_be_joined` all true, no
`fail_reason`). Nothing force-joins a party member into another member's hub —
`consume_matched_hub_server_session_id` is only reachable through
`party_immaterium_hot_join_hub_server`, whose three callers are
`_find_available_immaterium_session`, `StateMissionServerExit`, and the group-up
vote — so someone joining your party stays in their own hub. The mismatch is
cosmetic: they see you in the Mourningstar and never find you there.

Their ability to start a mission is unaffected either way:
`are_all_members_in_hub` permits *other* members to be in `training_grounds`,
and only requires `hub` of yourself.

The one real change is the group-up vote. Its `on_completed` is gated on
`Managers.presence:presence() == "hub"`, so before the presence hook it did
nothing on this client; now it fires and calls
`party_immaterium_hot_join_hub_server`. The hot-join hook therefore passes
through when `_in_solo_hub()` is already true — joining the party's hub server is
the point of the vote, and re-booting there would swap the live session out from
under a hub you are standing in.

## Settings

- **Private Mourningstar** (default on) — the main toggle.
- **Also after missions** (default on) — covers `StateMissionServerExit`. This is
  the riskier path (a mission-server session is still alive when it fires); turn
  it off if returning from a mission misbehaves, and entering from character
  select still works.
- **Debug logging** — session boot and mechanism changes to the console log.

`/solohub` in chat reports the mod version, host type, mechanism, game mode and
presence.

## Releasing

```
python .claude/skills/darktide-mod/scripts/release_mod.py SoloMourningstar
```

Writes `releases/SoloMourningstar-<version>.zip`. The version is `mod.version`
at the top of the main Lua file — bump it there, since the script refuses to
overwrite an existing zip.

## What this gives up

- No other players in your Mourningstar, party members included. The party
  itself is a backend construct and survives; missions still launch through
  `party_immaterium`.
- Hub voice chat — the vivox token comes from the hub session's `serverDetails`
  (`party_immaterium_hub_session_boot.lua`). Party voice
  (`request_vivox_party_token`) is separate and should survive.
- Menus (mission board, vendors, crafting, penances, inventory) are backend HTTP
  and unaffected by who hosts the level.

## Status

Confirmed working in-game (2026-08-06): entering the private Mourningstar from
character select, starting missions from it, and party invites.

The "team mate not available" bug on the mission board was found here — see the
Presence section; it needed the `evaluate_presence` hook to fix.

## Still to test

1. **Group-up vote** — accept one from the solo hub and confirm you land in the
   party's hub server rather than reloading your own. With debug logging on this
   prints "Group-up vote or equivalent: joining the party's hub server".
2. **Psykhanium in and out** — `TrainingGroundsOptionsView._start_training_grounds`
   already boots its own singleplayer session; make sure coming back does not
   double-boot.
3. **Hub odds and ends** — cutscene and interaction flow, contracts, the AFK
   check (`afk_check.location = "hub"`), anything gating on `is_social_hub`.

Likely failure mode if the mechanism switch is mistimed: stuck on the loading
screen with `is_stranded` in the log, dropping back to character select.
