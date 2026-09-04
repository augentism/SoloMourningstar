# Solo Mourningstar

Loads the Mourningstar as a private, locally hosted instance instead of joining
a public hub server.

## Requirements

DMF only. Every `require` in the mod is a game script and it calls `get_mod` on
nothing but itself.

In particular it does **not** need SoloPlay: that mod drives
`HOST_TYPES.singleplay` for *mission* sessions, while this one hosts the *hub*.
`boot_singleplayer_session` is vanilla API — the Psykhanium uses it unmodded —
and missions launched from the private hub go through `party_immaterium` as
normal. (Testing has all been done with SoloPlay present, so that is reasoning
from the code rather than an observation.)

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

## Pacing (the specials_pacing crash)

Hosting the hub creates server-only managers a hub client never has:
`gameplay_init_step_managers.lua` builds `Managers.state.pacing` only
`if is_server`. `SpecialsPacing` is the one sub-pacer whose template does not
come from `PacingManager.init` (which falls back to a default) but from
`on_spawn_points_generated` — which a level with no spawn points never
triggers. So in a hosted hub `SpecialsPacing._template` is permanently nil.

Vanilla never dereferences it, because `GameplayInitStepPacing` does run in the
hub and `PacingManager.on_gameplay_post_init` sets
`_disabled = not main_path_available` — verified live: `is_main_path_available()`
returns false in a hosted hub, so pacing starts out correctly disabled.

Something then switches it back on. **Will of the Emperor** does, writing the
field directly rather than through `set_enabled`:

```lua
elseif not (is_shooting_range or is_prologue) then
	Managers.state.pacing._disabled = false
```

A hosted hub is neither of those, so pacing runs and specials pacing dies on the
nil template roughly 40 seconds in. Not a bug on its side — nothing could host
the hub before this mod existed. (It leaves no DMF hook log line either, since
it is a direct field write, which makes it invisible in a crash log's hook list.)

That write lives in WotE's `mod.update`, and it fires **even when the mod is
switched off**: DMF's `mods_update_event` iterates every loaded mod and calls
`update` with no `is_enabled()` check (`dmf/modules/core/events.lua`), and WotE
does not check for itself. Its `is_client_map()` is true for
`host_type() == "singleplay"`, which a hosted hub is. So in the solo hub the
flag is being set back to `false` *every frame*, whether or not the mod appears
enabled — which is why pacing reads as enabled in sessions where WotE was never
turned on.

This is also what made **reloading mods crash the game**: reload tears every
hook down and re-applies it, and with pacing force-enabled every frame, the raw
`SpecialsPacing.update` ran in the gap and hit the nil template.

Three guards, in order of how much weight they carry:

- **`specials_pacing._disabled = true`** — the load-bearing one, and deliberately
  a write to *game state* rather than another hook. `SpecialsPacing.update`
  checks its own `_disabled` before it ever reads `_template`, so once set, the
  engine protects itself even in a frame where our hooks are absent. Nothing
  else writes this flag (WotE writes the *manager's*), so it is uncontested and
  survives a mod reload.
- `set_enabled(false)` on the manager, at `PacingManager.init` and re-asserted
  each frame. Clean when uncontested; a per-frame ping-pong when WotE is loaded.
  Harmless either way now that specials is disabled independently.
- A nil-template early-out on `SpecialsPacing.update`. Verified live catching the
  real crash configuration, but it only holds while our hooks are installed —
  hence the state write above.

## Out-of-bounds despawns

An out-of-bounds despawn is terminal in the hub.
`PlayerUnitSpawnManager._on_player_soft_oob` calls `despawn_player_safe`, and
nothing puts the player back: respawn is gated on `self._settings.respawn` in
`game_mode_coop_complete_objective`, and the hub game mode settings have no
respawn block. You stay unitless until you leave the hub — and every hub view
that assumes a live player unit then crashes on open. `HavocPlayView` dies
dereferencing `player_unit_spawn:owner(nil)`, which reads as a random crash when
opening a terminal but is in fact deterministic once the unit is gone.

Hosting is why this reaches us at all — the OOB check runs on the server, which
in a public hub is not this machine. So the despawn is suppressed, but **only in
a hub we host**; missions keep vanilla behaviour, where the despawn matters and
respawning actually works.

Trade-off: nothing rescues a player who is genuinely below the map. If that ever
matters more than the crash, the alternative is respawning at a hub spawn point
instead of suppressing.

`/solohub` reports whether the player unit is present, which is the fast way to
tell this state apart from an unrelated crash.

## Character switching (archetype changes)

A mod that swaps characters in the hub — InstantCharacterChange — calls
`player:set_profile()` directly. Against a real hub server that is harmless:
local data, and the server owns spawning. In a hub we host, we *are* the server,
so `PackageSynchronizerHost` reacts and starts loading/unloading item packages
that nothing sequenced. That is the best candidate for the engine crash seen
after an in-hub character switch — no Lua error, no frame to catch; ICC's own
notes describe a native refcount assertion from `set_profile` racing package
loads.

The game has a supported path, and ICC already uses it in the Psykhanium:

```
ProfileSynchronizerHost:override_singleplay_profile
  -> set_profile
  -> PackageSynchronizerHost despawns the unit, loads the new class' packages,
     respawns on the spot
```

No level reload, no loading screen. ICC gates it on a game-mode allowlist
(`training_grounds` / `shooting_range`) that predates hosted hubs existing, so
our hub misses it despite passing the check that actually matters — a non-nil
`synchronizer_host`, i.e. being the host. Widening that gate would be a small
upstream fix.

Rather than wait for it, an archetype-changing `set_profile` on the local player
in our hub is routed into `override_singleplay_profile` with the same profile.
Same destination, no loading screen, and you visibly become the new class —
which ICC cannot achieve in a public hub at all. Nothing here reads ICC's
internals, so any mod doing the same thing gets the same routing.
Same-archetype `set_profile` calls — every loadout and talent edit — pass
through untouched.

Verified working (0.1.5): four consecutive archetype swaps in the hub, each
completing in 175–850 ms of package sync with no Lua error and no engine crash.
The hub's own unit template and third-person camera turned out not to be a
problem. The visible "load screen" is the package sync window, not a reload.

If it ever does misbehave, the fallback is forcing a hub reload on an armed
switch — ICC's `boot_singleplayer_session` hook then applies the swap in its own
documented safe window.

## Artificial latency (hub UI disappearing)

ArtificialLatency does not delay packets — it fakes latency by setting
`player.remote = true` on your own player so the server lag-compensates you.
Its gate is only `game_session:is_server()`, which in vanilla means the
Psykhanium or a solo mission. A hosted hub satisfies it too, and hub UI
identifies your player by checking `remote`, so flagging yourself remote makes
that code conclude there is no local player and the menu buttons stop drawing.

Handled in three layers, because clearing alone is always one step behind at the
worst moment — `set_player_props` fires from that mod's `on_game_state_changed`
as gameplay is entered, which is exactly when the hub builds its UI:

- **Prevention.** Both of its write paths early-out when its own cached
  `al_ms` is zero (`set_player_props` then takes the branch that actively clears
  the flag). That cache is held at zero while in the solo hub, so nothing is
  ever written. `_in_solo_hub()` is true during loading, before the state-change
  callback runs. The restore on leaving reads their setting rather than a
  remembered value, so a latency change made in the hub is not clobbered.
- **An outer `owner()` hook.** DMF chains hooks newest-first and mods hook in
  load order, so ours (last in the load order) wraps theirs: call through, then
  clear before the caller sees the result. Covers the case where the cache is
  non-zero for a frame.
- **A frame-level clear**, for anything reading `player.remote` without going
  through `owner()`.

The prevention layer is the one place this mod reaches into another mod's
internals. The other two are mod-agnostic and cover anything else that flags the
local player as remote.

Lag compensation only affects hit registration and the hub has no combat, so
suppressing it there costs nothing; missions and the Psykhanium are untouched.

Upstream, the fix is a game-mode check alongside the `is_server()` gate.

## First person Mourningstar (experimental, off by default)

The hub player is not a stripped-down mission player by accident — it uses a
different unit template. `player_character_social_hub` and `player_character`
differ by exactly 13 extensions, all combat: `SlotExtension` (which minion
target selection crashes without), health, toughness, aim, attack intensity,
mood, music, smart tag, and their husk counterparts. Patching each crash site as
it surfaced would have been a long road — swapping the template restores all of
them at once.

Almost all of it is *removing* the hub's overrides, since the mission game mode
sets none of them:

| Field | Hub | Mission |
| --- | --- | --- |
| `player_unit_template_name_override` | `player_character_social_hub` | unset → `player_character` |
| `default_inventory` / `default_wielded_slot_name` | unarmed only | unset → real loadout |
| `use_third_person_hub_camera` | true | unset |
| `vaulting_allowed` | false | true |
| `force_third_person_mode` (mission template) | true | — |
| `gameplay_modifiers` (mission template) | `unkillable`, `invulnerable` | — |

Written before the session boots, because the game mode and mission template are
read during the load that follows — so toggling the setting takes effect on the
next hub load. The stock values are restored whenever we are heading for a
public hub, so a real hub server is never loaded with combat settings patched in.

There is no respawn in the hub (no `respawn` block in the game mode, same as the
Psykhanium), so dying means going back to character select and loading in again.
That is accepted behaviour rather than an oversight.

`hud_elements` is cleared too, so the hub gets the full combat HUD — health,
toughness, buffs, stamina, ammo, damage indicator — instead of the hub's
cut-down set.

**Known issue: do not spawn a Beast of Nurgle.** Being eaten crashes the game
(engine crash, no Lua error, so nothing to catch). The same enemy consuming you
in the Psykhanium is fine, which rules out the enemy itself and points at a
remaining hub/Psykhanium difference. Restoring the full combat HUD, the first
suspect, did not fix it. Unexamined deltas: the level's own spawn and respawn
infrastructure, and `is_social_hub`.

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

```bash
nix develop ./nix --command python3 \
    .claude/skills/darktide-mod/scripts/release_mod.py SoloMourningstar
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

Tested in-game as of 0.1.3 (2026-08-07), all working:

- Entering the private Mourningstar from character select
- Starting missions from it, and party invites
- Returning after a mission (the "Also after missions" path)
- Psykhanium in and out — no double-boot despite
  `TrainingGroundsOptionsView._start_training_grounds` booting its own
  singleplayer session
- Group-up vote — lands in the party's hub server rather than reloading our own
- The `specials_pacing` crash, including a mod reload while standing in the hub,
  which is what it took to catch the difference between a hook guard and a game
  state write
- Character switching in the hub via InstantCharacterChange (0.1.5) — four
  archetype swaps, each a sub-second package sync, no crash

Not yet exercised: the out-of-bounds despawn suppression (0.1.4), which needs
someone to deliberately go out of bounds in the hub.

Two bugs were found by testing rather than by reading the source, and both are
worth knowing about before changing anything here: the mission board's "team
mate not available" (see Presence) and the pacing crash (see Pacing). Neither
was predictable from the session/mechanism code alone.

Not specifically exercised: the AFK check (`afk_check.location = "hub"`) and
anything else gating on `is_social_hub`.

Likely failure mode if the mechanism switch is ever mistimed: stuck on the
loading screen with `is_stranded` in the log, dropping back to character select.
