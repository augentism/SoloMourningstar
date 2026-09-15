# A note for mod authors

Solo Mourningstar loads the Mourningstar as a private, locally hosted instance
instead of connecting you to a public hub server. Everything else about the hub
works as normal — but there is one side effect worth knowing about.

Normally, when a player is in the Mourningstar, their game is a **client** of
Fatshark's hub server. With this mod, their game is the **server**. That has
never been possible before, and it quietly changes the meaning of a few common
checks:

- `Managers.multiplayer_session:host_type() == "singleplay"`
- `Managers.state.game_session:is_server()`
- `Managers.profile_synchronization:synchronizer_host() ~= nil`

Until now, all three effectively meant "the player is in the Psykhanium, the
prologue, or a solo mission" — a combat sandbox. With this mod they are also
true while the player is standing in the Mourningstar browsing menus.

So if your mod uses one of those checks to decide when to change enemy
spawning, swap the player's profile, alter the player's network role, or
anything else that assumes gameplay, it will now do that in the hub too.
Symptoms already seen in the wild: a crash roughly a minute after entering the
hub, the hub's menu buttons disappearing, and a hard crash when changing
character.

None of this is a bug in those mods. The assumption was correct until this mod
existed.

## The fix is one extra line

Check the game mode as well as the host:

```lua
local hosted_hub = Managers.multiplayer_session:host_type() == "singleplay"
	and Managers.state.game_mode
	and Managers.state.game_mode:game_mode_name() == "hub"

if hosted_hub then
	-- skip, or take whatever path is right for a hub
end
```

This needs no dependency on my mod and is correct whether or not the player has
it installed.

If you would rather not change anything, that is fine — let me know and I will
add a compatibility guard on my end instead.

**Players:** if something misbehaves only in the private Mourningstar and works
normally in a public hub, please post a log. It is almost always this.

## Owning the post-mission hub session

There is a second, narrower way to conflict with this mod, and one mod already
does.

When a mission ends, `StateMissionServerExit` asks for a hub session:

```lua
-- state_mission_server_exit.lua:41-42
if not DEDICATED_SERVER and GameParameters.prod_like_backend and not self._multiplayer_session then
    self._multiplayer_session = Managers.multiplayer_session:party_immaterium_hot_join_hub_server()
end
```

Solo Mourningstar hooks that `party_immaterium_hot_join_hub_server` call and
substitutes a locally hosted session.

**So that method is not a safe probe once this mod is loaded — calling it boots a
session.** That is the thing to know, and it is what broke InstantHub 3.x's
"Reserve Mourningstar Server": it calls the method speculatively to set up its
reservation, gets our locally hosted session back, correctly decides it is not the
hub-server boot it wanted, and calls `clear_session_boot()` on it — destroying the
session we are waiting on. The player gets the mission drop-in loading screen for a
hub load, a minute-long stall, and a bounce to operative select.

Neither mod is unreasonable in isolation. The probe simply is not read-only.

### Ask instead of probing

Solo Mourningstar 0.3.6 publishes a predicate for exactly this:

```lua
local solo = get_mod("SoloMourningstar")

if solo and type(solo.will_host_hub_after_mission) == "function"
    and solo.will_host_hub_after_mission() then
    return -- leave the post-mission hub session to it
end
```

It returns `true` only when a mission ending now will be followed by us hosting
the hub, accounting for the mod being toggled off and for both settings. It is
backed by the same expression our own hook reads, so it cannot drift from the
behaviour it describes, and the `type(...) == "function"` test degrades cleanly
against older versions or no Solo Mourningstar at all.

There is a fuller write-up of the InstantHub case, with the exact code and a
suggested patch, in `INSTANTHUB-REPORT.md`.

**If your mod also substitutes or pre-reserves the post-mission hub session**,
please get in touch — this needs a convention rather than each of us hooking a
different seam and hoping.
