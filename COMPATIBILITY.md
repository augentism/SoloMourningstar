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
