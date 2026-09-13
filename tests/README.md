# SoloMourningstar tests

One tier: **in-game, through dt-cli, with the game running.**

There is no offline tier and there should not be one. This mod is hooks over
`MultiplayerSessionManager` and `MechanismManager`, and every bug it has shipped
was about which session and which mechanism were installed at a particular
moment. A harness that faked those would only test the fake.

```
python3 run_tests.py              # everything
python3 run_tests.py -k paths     # filter by script name
python3 run_tests.py --list
python3 run_tests.py --keep-open  # never close, even a game this run launched
python3 run_tests.py --no-start   # never launch; SKIP if the game is down
```

Run it from inside the flake (`nix develop ./nix --command ...`) so `python3` is
on PATH, the same as CWaH's suite.

### The game is launched and closed for you

If the game is down, the runner starts it (`restart-game.sh`, which skips
Fatshark's launcher — that sits on a Play button no unattended run can click)
and closes it again when the suite finishes.

**It only closes a game it started.** One that was already up is left running,
because the runner cannot tell a spare session from the one you are in the
middle of, and throwing that away to tidy up is the wrong trade. `--keep-open`
suppresses the close entirely; `--no-start` refuses to launch and SKIPs instead.

The close runs in a `finally`, so a failed row or a Ctrl+C does not strand a
game nobody asked for. It stops the `darktide-test` systemd unit before
`pkill`, since that is how `restart-game.sh` launches it and pkill alone leaves
the unit failed for the next run, then waits for wine to release the prefix —
returning early is how you end up with two wineservers and a pipe nobody owns.

## These drive the game

`paths.sh` forces wins, abandons sessions and moves you between the hub, the
Psykhanium and missions about thirty times. **Missions are launched through
SoloPlay**, so every one of them is a local singleplayer session with nobody
else in it — this suite cannot land in a stranger's run. It still should not be
pointed at a session you care about.

It reports SKIPPED, not failed, when the game is not running or SoloPlay is not
installed.

## ingame/paths.sh

The route a player actually takes, run once per setting combination:

```
character select -> hub -> Psykhanium -> hub -> mission -> win -> hub -> mission
```

across all four combinations of `first_person_hub` × `solo_hub_after_mission`,
each one twice — once leaving the end screen by **score-done**, once by
**Continue**. Eight rows, 100 assertions.

`solo_hub_on_enter` is forced ON for the whole matrix. It is the base gate: with
it off the mod does nothing and every assertion would pass vacuously.

### Why the whole route instead of four separate tests

Every defect this mod has shipped was state left behind by the *previous* leg —
a mission channel still installed when the hub mechanism arrived, a hub
mechanism still installed when a dead channel was reaped, a `left_session`
reason nobody read. A test that enters the hub from a clean boot passes with all
of them present. The route is the test.

### Why both end-screen exits

They do not meet:

| exit | path |
| --- | --- |
| timer expiry | `StateGameScore.update` → `trigger_event("game_score_done")` |
| Continue / Space | `EndView` → `multiplayer_session:leave("skip_end_of_round")` |

`solo_hub_after_mission` gated only the first until 0.3.4. Players who switched
it off still got the solo hub every time they pressed Continue, because that
exit returns through `MechanismLeftSession` → `find_available_session`, which
was gated on `solo_hub_on_enter` instead. Testing only the timer is how that
shipped.

**The suite fires `game_score_done` itself rather than waiting for the timer**,
and the row is named `score-done` to say so. With Realms hosting, the timer can
never fire at all: Realms hooks `ProgressionManager.game_score_end_time`
(`views/end_view.lua:22`) and returns `UNLIMITED_END_TIME` while its session is
active — read live, it is `inf` — so `StateGameScore.update`'s
`end_time < server_time` is never true. A row that waits for it waits forever,
measured rather than guessed. What is lost is coverage of the timer, which is
Realms' behaviour; `state_game_score.lua:95` shows the timer's whole effect is
that same `trigger_event` call, so from the mechanism onward the path is
identical.

### What each row asserts

- the hub came up from character select, and `_mechanism_host_channel` is `nil`
- the applied first-person state matches the setting — read off
  `GameModeSettings.hub` and `Missions.hub_ship`, not off `mod:get`, because the
  gap between what was asked for and what was applied is the thing worth testing
- the Psykhanium is reachable, and returning from it lands in the solo hub
  **regardless of `solo_hub_after_mission`** — the Meat Grinder is not a mission,
  so it is governed by `solo_hub_on_enter` (0.3.4)
- a mission launches from the hub
- with `solo_hub_after_mission` **on**: a hub comes back and it is **ours** (not
  `host=hub_server`), the mission channel did not outlive the swap, first-person
  survived, and the returned-to hub can launch another mission — a hub that loads
  but cannot be left was a real report
- with it **off**: a **public** hub is reached (`host=hub_server`) and it loaded
  with **stock settings** (`fp=false`), whatever `first_person_hub` asked for

That last assertion is not decoration. Until 0.3.5 the hot-join pass-through did
not restore the stock hub settings, so `first_person_hub` + a public Mourningstar
left `player_unit_template_name_override` cleared on the *shared*
`GameModeSettings.hub`. The next stranger to hot-join had their husk built from
the combat template, whose animation state machine has no hub aim constraint
target, and the client hard-crashed inside somebody else's husk spawn:

```
spawn_husk_unit → wield_slot → set_anim_state_machine
  → PlayerUnitHubAimExtension.state_machine_changed
  → HubAimConstraints.init → animation_find_constraint_target
"State machine has no constraint target named ... in unit ..."
```

The suite found it, but only because the game died — there was no assertion for
it. Now there is, so the regression fails a row instead of taking the process
down.

### Smoke mode

`SM_SMOKE=1 bash ingame/paths.sh` runs two rows instead of eight —
`after=true` and `after=false`, both on the score-done exit. Use it after any
change to `paths.sh`, then run the matrix.

Both values, deliberately: they assert opposite outcomes after the mission (our
hub versus the public one), and a smoke run covering only one leaves the other
unexercised. That is exactly how the `after=false` branch once reached the full
matrix asserting "no hub at all", which is not what vanilla does.

### The `after=false` rows touch a real hub server

With the setting off the hook passes through to vanilla, and vanilla joins a
**public Mourningstar**. So four of the eight rows connect to a live
Fatshark hub server. That is harmless — the social hub, no mission, no other
player's run affected — but it means the suite is not fully offline the way the
mission legs are, and those rows will fail if the backend is down.

It is also the stronger assertion. Checking for `host=hub_server` rather than
merely "not our hub" is what distinguishes a working pass-through from a mod
that has broken the return entirely and left the player nowhere — a bug that has
shipped here before.

## Known gap: the hot-join path is not covered

A SoloPlay mission returns to the hub through `MechanismLeftSession` →
`find_available_session`. It never calls
`party_immaterium_hot_join_hub_server`, which is the *other* after-mission seam
and the one `StateMissionServerExit` uses — that needs a real dedicated mission
server, which means a real lobby, which means griefing strangers.

So the matrix covers the path that produced the 0.3.4 bug and does **not** cover
the path that produced the original crash. If you change the hot-join hook,
this suite will not tell you about it. That leg still has to be tested by hand,
or by reading a reporter's log for the `[trace] Booting private Mourningstar
-- entry: party_immaterium_hot_join_hub_server` line.

## Reading a failure

The state line is `host|mech|mstate|gm|chan|fp|gs`, and every field is one that
engine code branches on:

| field | who reads it |
| --- | --- |
| `host` | `mission_intro_view`'s validation (`constant_element_loading.lua:16-62`) — a hub load that validates here ends up on the mission drop-in screen and blocks in `HostWaitForMissionBriefingDoneState`. Also the only field separating our hub from a public one |
| `mech` | `rpc_mechanism_event` dispatches into whatever this is |
| `chan` | `wanted_transition` and `MechanismManager.disconnect` both branch on it |
| `fp` | the *applied* first-person state, off `GameModeSettings.hub` and `Missions.hub_ship` — not what `mod:get` was asked for |
| `gs` | the game state name. **Not** derivable from `mech`: the mechanism reads `left_session` during teardown, seconds before `StateMainMenu` exists. Waiting on the mechanism and then firing `event_state_main_menu_continue` puts the event into a state machine that has not arrived, where it is dropped with no error — the row then sits on character select until its timeout, looking exactly like a mod defect |

`host` is deliberately **not** asserted as `singleplay`. With Realms installed
the solo hub is a listen host and reports `HOST_TYPES.player`. Gating on the type
would make the suite pass only on a machine without Realms — which is the exact
mistake that nearly shipped as a fix for the operative-select bounce.

## Mod interactions worth knowing before believing a failure

- **InstantHub 3.x "Reserve Mourningstar Server"** conflicts with this mod: both
  substitute the post-mission hub session, at different seams. Symptoms are the
  wrong loading screen, a ~60s stall, then operative select. Turn it off before
  debugging anything else.
- **Realms** changes what the solo hub *is* (listen host, not singleplayer
  session), so it changes `host`. Not a failure.
- **psych_ward** also hooks `find_available_session`, and DMF runs hook chains
  newest-first.
