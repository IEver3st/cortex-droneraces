# Cortex Drone Races

[![Cortex Drone Races](https://raw.githubusercontent.com/IEver3st/gsd-tebex-media/main/heroes/droneraces.jpg)](https://gsdmods.com/scripts/cortex-drone-races?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces)

**[Product page](https://gsdmods.com/scripts/cortex-drone-races?utm_source=github&utm_medium=social&utm_campaign=cortex-droneraces-launch)** · [All GSD scripts](https://gsdmods.com/scripts?utm_source=github&utm_medium=social&utm_campaign=cortex-droneraces-launch) · [Docs](https://gsdmods.com/docs?utm_source=github&utm_medium=social&utm_campaign=cortex-droneraces-launch) · [Discord](https://discord.com/invite/gsdmods) · [Download](https://github.com/IEver3st/cortex-droneraces/releases/latest)

Free, by [GSD Modifications](https://gsdmods.com/?utm_source=github&utm_medium=social&utm_campaign=cortex-droneraces-launch). This repository is the public release build: the files a server runs, nothing else.

FPV drone racing for Cortex Drone. Neon gates, rings, tunnels and start arches, flame burners and fire curtains, coloured smoke trails, start lights and finish fireworks. Players host lobbies with an entry fee, race laps against each other or the clock, and get a results screen with the line every pilot flew, a speed heatmap, an altitude trace and an in-world replay. Tracks are built in game with the creator. A demo track, LSIA Neon Circuit, ships at Los Santos International.

## Requirements

- `cortex-lib`, `cortex-drone` (with its race hooks), `oxmysql`, OneSync
- Qbox or QBCore for entry fees and prizes (without a framework races are free)
- No drone item: every racer gets a loaner FPV racer for the race. To make players own one, set `Config.requireItem` to an item name or a list, for example `{ 'drone', 'drone_fpv' }` (any one of them counts)

## Install

1. Put `cortex-droneraces` in your resources and `ensure` it after `cortex-lib`, `cortex-drone` and `oxmysql`.
2. Database tables (`cortex_droneraces_tracks`, `_times`, `_ledger`) are created on first start.
3. If you set `Config.requireItem` and run cortex-inventory, `cortex-droneraces` must be in `cortex-inventory/config/suite-trust.lua` so it can read items; otherwise every race start says the inventory isn't ready.
4. Give track builders the ACE:

```cfg
add_ace group.admin cortex.droneraces.admin allow
add_ace group.admin cortex.droneraces.create allow
```

`create` lets a player build tracks and edit their own; `admin` edits or removes any track, cancels races and sees unresolved money entries. Set `Config.editor.access = 'everyone'` to let anyone build.

### Convars

```cfg
set cortex_droneraces_locale "en"
set cortex_droneraces_webhook "https://discord.com/api/webhooks/..."
```

## Playing

- Walk to a track start (map blip, prompt) and press **K** (`/droneraces`, remappable): host, join, start, time trial, leaderboard, edit.
- Hosting asks for laps and an entry fee. Joiners see the fee and pot before they pay.
- On start every racer's FPV drone appears on a start pad. The gantry counts down and the race starts on green.
- Fly through the gates in order. The next two gates are marked. Crash and you're straight back at the last gate you passed (servers can add a time penalty with `Config.race.respawnPenalty`).
- Leaving the drone controls or pressing **K** and confirming forfeits the race.
- Results: arrows pick a pilot, drag the altitude trace to scrub, **Enter** watches the replay in world (Left/Right switch pilot, Space switches chase and overhead, Shift changes speed, Backspace exits), **Esc** closes.
- Time trials race your personal best ghost.

## Money

| Case | What happens |
| --- | --- |
| Leave, disconnect or switch character before the green light, lobby expires, race cancelled, your drone never reaches the pad | Fee refunded |
| Nobody finishes | Every fee refunded |
| Race finishes | Pot minus `houseCut` split among finishers by `Config.economy.payouts`, remainder to 1st. The house cut leaves the economy (a money sink) |
| Forfeit or DNF | Fee stays in the pot, no prize |

Every movement is written to `cortex_droneraces_ledger` with a unique operation id. Fees held by a race that a restart killed are refunded at the next start, and a running server retries any refund it could not record every 5 minutes; refunds and prizes are paid to online players and held for offline ones until they next load in; an entry interrupted mid-payment is flagged for staff (`droneraces_list`) instead of being guessed. Qbox saves player money in the background; the resource saves the player right after every payment, but a whole-server crash in that instant can still lose the last movement, as with any Qbox money script.

## Track creator

Press K anywhere and pick **Create a track** (or **Edit track** at a start). Freecam: WASD fly, Space/Ctrl up and down, Shift fast, Alt slow, mouse look.

| Key | Action |
| --- | --- |
| LMB | Place the piece in front of the camera |
| RMB | Pick up the piece you look at to move it |
| Delete | Remove the piece you look at |
| Tab | Next piece |
| Wheel | Placement distance |
| Q / E | Turn |
| R / F | Tilt (gates and rings, up to 90° for vertical dives) |
| PageUp / PageDown | Move the gate you look at earlier or later in the order |
| G | Ground lock for this piece |
| Enter | Menu: save, test run, settings (name, loop or sprint, laps), clear, exit |
| Backspace | Drop the piece you hold, or leave |

Gates are numbered in the world with a ribbon to the next one and an arrow showing which way to fly through. Unsaved work survives a crash and comes back with **Continue unsaved track**. A test run flies the draft once and returns you to the creator.

Pieces: neon gate, ring, start arch and tunnel count as gates; start pads set the grid (one racer per pad); start lights run the countdown; pylons glow; flame burners fire when a racer passes; fire curtains burn across the track during a race.

## Configuration

See `config.lua`: drone type, laps, countdown, lobby time, respawn penalty, DNF timer, race time limit, `topSpeed` (gate plausibility check), fees and payouts, creator limits, blips, the menu key, creator controls, and every effect (draw distance, light count, smoke, flames, fireworks).

## Staff commands

| Command | Does |
| --- | --- |
| `droneraces_list` | Running races and unresolved money entries |
| `droneraces_cancel <n>` | Cancel race `n`, refunding fees |
| `droneraces_deletetrack <id>` | Remove a track (a builtin returns to its original layout) |

## cortex-drone hooks

Races use cortex-drone's race profile (`SetRaceProfile`, `DeployRace`, `RaceHold`, `RaceRespawn`, `cortex-drone:raceCrashed`), documented in cortex-drone's README. Outside a race cortex-drone behaves exactly as before.

## Restart order

`refresh`, then `ensure cortex-droneraces`. Restart cortex-drone only when no drone is out: restarting it with a drone deployed can crash clients.

## Download and support

It needs [Cortex Drone](https://github.com/IEver3st/cortex-drone) 1.0.0 or later.

Grab the latest zip from [Releases](https://github.com/IEver3st/cortex-droneraces/releases/latest) and keep the folder named `cortex-droneraces`. The same script is also free on the [GSD store](https://gsdmods.com/scripts/cortex-drone-races?utm_source=github&utm_medium=social&utm_campaign=cortex-droneraces-launch), delivered through your Cfx.re portal. Questions and bug reports go to the [GSD Discord](https://discord.com/invite/gsdmods).

## More from Cortex

[![Cortex PolCam following a car from the police helicopter camera](https://raw.githubusercontent.com/IEver3st/gsd-tebex-media/main/forum/polcam/tracking-v2.webp)](https://gsdmods.com/scripts/cortex-polcam?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces)

Cortex Drone Races is free and stays free. The paid Cortex scripts run on the same Cortex Library and pay for the free ones.

| Police | Interface | Driving and freeroam |
| --- | --- | --- |
| [PolCam](https://gsdmods.com/scripts/cortex-polcam?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces): FLIR helicopter camera with target tracking | [HUD](https://gsdmods.com/scripts/cortex-hud?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces): vitals, vehicle, aircraft, weapon and radar | [Handling](https://gsdmods.com/scripts/cortex-handling?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces): tune handling from the driver's seat |
| [Arges](https://gsdmods.com/scripts/cortex-arges?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces): remote spotlight for patrol cars | [Chat](https://gsdmods.com/scripts/cortex-chat?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces): chat replacement with roleplay actions | [Rewind](https://gsdmods.com/scripts/cortex-rewind?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces): rewind a missed corner or a bad landing |
| [Radio](https://gsdmods.com/scripts/cortex-radio?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces): handheld radio for pma-voice | [Spawn](https://gsdmods.com/scripts/cortex-spawn?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces): pick your spawn from a live view of the city | [Emote Studio](https://gsdmods.com/scripts/cortex-emote-studio?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces): preview, fit and pair emotes |
| [Flashlight](https://gsdmods.com/scripts/cortex-flashlight?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces): weapon, vest and UV forensic torches | [Multicharacter](https://gsdmods.com/scripts/cortex-multicharacter?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces): character selection and creation for Qbox | |
| [Binoculars](https://gsdmods.com/scripts/cortex-binoculars?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces): zoom, rangefinder, night and thermal vision | [Loading Screen](https://gsdmods.com/scripts/cortex-loading-screen?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces): cinematic arrival screen | |

**[Browse every Cortex script](https://gsdmods.com/scripts?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces)** · [LEO Kit](https://gsdmods.com/scripts/cortex-leo-kit?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces): PolCam, Arges, Binoculars and Flashlight in one purchase · [All-Access](https://gsdmods.com/scripts/cortex-all-access?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces): every paid script for one monthly price

Also free: [Admin](https://gsdmods.com/scripts/cortex-admin?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces) · [Drone](https://gsdmods.com/scripts/cortex-drone?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces) · [Gunsmith](https://gsdmods.com/scripts/cortex-gunsmith?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces) · [Megaphone](https://gsdmods.com/scripts/cortex-megaphone?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces) · [Minigames](https://gsdmods.com/scripts/cortex-minigames?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces) · [Thrusters](https://gsdmods.com/scripts/cortex-thrusters?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces) · [Library](https://gsdmods.com/scripts/cortex-library?utm_source=github&utm_medium=readme&utm_campaign=cortex-droneraces)

## License

Free to use and modify on your own servers under the [Cortex Drone Races Free Use License](LICENSE). Readable source does not make it open source: do not redistribute or resell it; share the link instead.
