# ANON · Garden Tower Defense — Macro Recorder & Replay

Roblox macro recorder/trainer for **Garden Tower Defense** (`place 108533757090220`, `universe 7703614594`).
Built for **Android / Delta**, runs on any executor with `HttpGet` + `loadstring` + `VirtualInputManager`.

What makes it different from the macro hubs out there: **every recording is stamped with the run it was
made in** — mode, difficulty, map, map fingerprint, game speed, total waves, loadout units, place id, job id —
and **playback is anchored to the round** (`wave N + dt since that wave started`), not to a wall clock.
Change the mode or the speed and it tells you before it wastes your seeds.

---

## 1. Files

| File | What it is |
|---|---|
| `Loader.lua` | the one-line entry point you paste in Delta. Fetches + caches + runs Main. |
| `Main.lua` | the whole script (~2900 lines): probe, recorder, player, UI, store. |
| `tools/mock_harness.lua` | offline test harness — mocked Roblox surface, runs the full boot→record→save→play chain. |
| `tools/dist_check.lua` | proves the loadstring path: fetches the live raw + jsDelivr payloads, diffs them byte for byte against local, compiles them like the loader does. |
| `README.md` | this. |

## 2. Hosting on GitHub raw (yes, it works — these are the rules)

1. Create a **public** repo, push `Main.lua` and `Loader.lua` to the **`main`** branch.
2. The URL must be the raw host with an explicit branch:
   `https://raw.githubusercontent.com/<user>/<repo>/refs/heads/main/Loader.lua`
   — **not** `github.com/<user>/<repo>/raw/...` (that is an HTML redirect and `loadstring` chokes on it).
3. Edit `Loader.lua`: set `REPO` and `MIRROR` to your repo, bump `VERSION` on every push.
4. In Delta, run:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/<user>/<repo>/refs/heads/main/Loader.lua"))()
```

This repo is already hosted and verified:

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Azkaahps/gtd-macro/refs/heads/main/Loader.lua"))()
```

Repo: <https://github.com/Azkaahps/gtd-macro> · the loader's fallback mirror is
`https://cdn.jsdelivr.net/gh/Azkaahps/gtd-macro@main/Main.lua`.

The repo must stay **public**: `raw.githubusercontent.com` serves private files only with a token, and an
executor's `game:HttpGet` has none — a private repo cannot be loaded by a loadstring at all.

Why the loader indirection: raw.githubusercontent caches for ~5 min, so the loader adds `?v=<unixtime>`,
falls back to **jsDelivr** (`https://cdn.jsdelivr.net/gh/<user>/<repo>@main/Main.lua`) when raw is blocked or
rate limited, and keeps a copy in `ANON_GTD/Main.lua` so a GitHub outage still boots.

Requires `game:HttpGet` + `loadstring` on the executor — if either is missing, web loading is impossible by
definition (then just paste `Main.lua` straight into the executor box).

## 3. First run checklist (Android / Delta)

1. Executor → inject → run the loadstring. The panel appears top-left, draggable by its header.
2. **SETUP → RUN DISCOVERY.** It prints what it found:
   - `mode / difficulty / map / speed / waves / countdown / seeds` from the game's own GUI text,
   - `map_sig` — a hash of the workspace layout, the fingerprint that survives a renamed map,
   - `loadout` — units it can see (or set them manually),
   - `wave anchor` — the label it will read the round number from,
   - `remote candidates` — scored RemoteEvents (wave/round/start names first),
   - capability report: hook, touch sim, `firesignal`/`getconnections`, file API.
3. If the auto-picked values are wrong → **overrides box** (`mode=Impossible, speed=3, map=Dojo`) and re-probe.
   Overrides are stored in the profile and beat detection on every later run.
4. **PIN ANCHOR** locks the wave label. **MARK WAVE NOW** sets T0 manually (escape hatch on patch day).
5. **CALIBRATE TAP** only if clicks land a few pixels off on your device (measured, not guessed — stored in
   `ANON_GTD/profile.json`).
6. Start the round normally, then **RECORD**. The REC header shows the live context stamp and the wave it is
   anchored to. Tap/place/upgrade like a human; the recorder stores taps, drags and key presses.
7. **STOP & SAVE** → name it (optional) → it lands in **MACROS** with its full stamp.

## 4. Playing a macro

- **MACROS → GO.** Before anything moves, the script compares the stored stamp with the live run and shows
  the mismatches (`mode Classic -> Survival`, `speed x3 -> x1`, `map X -> Y`, `loadout differs (...)`).
  You get **PLAY ANYWAY** or **CANCEL** — nothing fires silently on the wrong map.
- Timing: each step is `(wave index, dt from that wave's start)`. Playback waits for the right round, then
  sleeps `dt × (recorded speed ÷ current speed)`. Lag or a long intermission cannot drift the schedule:
  the step stays glued to its round.
- Placement verification: after a placement tap the script watches the unit container. If nothing lands it
  retries (default 2×) and counts the failure in the status bar. A wave that never arrives → the step is
  **skipped**, never tapped at the wrong moment.
- While playing, the panel hides itself (only a **STOP** pill stays) so replayed taps never hit our own UI.
- History: **PIN** (sorted to the top), **NM** rename, **EXP** export as a base64 string, **DEL** delete,
  filter box + pinned-only toggle. Loops: 1 / 5 / 25 / ∞.

## 5. How it reads the game (and why there is a discovery pass)

GDT ships updates **every Saturday**, and every public macro script for it is obfuscated (MoonSec V3 / encrypted
loaders — verified: five of them downloaded, only the loader headers readable). So guessing internal names
would produce a script that dies on the next patch. Instead:

| Signal | Source (in preference order) |
|---|---|
| wave index / total | pinned GUI label → label scan by pattern → `Wave n/m` shapes |
| wave start (T0) | counter change → countdown reset → (optional) hooked remote → `ChildAdded` in the enemy folder |
| mode / difficulty | short GUI label match + Workspace/RS attributes + manual override |
| speed | `x1/x2/x3` label or a `speed` attribute → used for the dt scale |
| map | attribute → `Map:` label → map-folder heuristic → `map_sig` hash fallback |
| loadout | player/RS attributes → GUI slot labels → manually entered |
| unit identity | `DescendantAdded` diff inside the unit container right after a placement click |
| container | discovered from the first fresh unit model's parent, then pinned in the profile |

The profile (`ANON_GTD/profile.json`) keeps the pins, so once discovery is done it is instant on every later run.

## 6. Stored macro format

```
ANON_GTD/
  index.json                 list for the history table (name, pin, mode, diff, map, speed, waves, units)
  profile.json               pins: wave label path, container path, tap offset, overrides
  macros/<id>.json           the recording itself
```

```lua
{
  id = "20261112-181530-317", name = "impossible bloodvine", pinned = true,
  created = 1762901730, duration = 412.7,
  ctx = { place_id = 108533757090220, job_id = "...", mode = "Classic", difficulty = "Impossible",
          map = "Dojo", map_sig = 567738033, speed = 3, wave_total = 25, start_wave = 1,
          loadout = {"Bloodvine","Lucky Clover"}, unit_names = {"Bloodvine"}, step_count = 143 },
  anchors = { wave_path = "Players.X.PlayerGui...WaveCounter", container_path = "Workspace.Units.X" },
  steps = {
    { kind = "down", wave = 3, dt = 12.41, t_abs = 45.2, x = 512, y = 733, itype = "Touch",
      ui = "...", world = { x = 12.5, y = 0, z = -40.2, part = "Workspace.Map.Ground" } },
    { kind = "up",   wave = 3, dt = 12.62, t_abs = 45.4, x = 512, y = 733, itype = "Touch",
      world = {...}, tower = "Bloodvine" },
    { kind = "move", ... }, { kind = "key", code = "Space", pressed = true, ... },
  }
}
```

`dt` anchors to the wave, `t_abs` is the absolute fallback used only when the wave counter is unreadable.

## 7. What has been verified

`tools/mock_harness.lua` mocks the Roblox surface (services, `Instance`, `Enum`, file API,
`VirtualInputManager`, virtual clock + scheduler) and drives the real `Main.lua`:

```
luajit tools/mock_harness.lua        # bare executor  — 65 checks, 0 failures
luajit tools/mock_harness.lua spy    # with hookmetamethod — +4 spy checks, 0 failures
luajit tools/dist_check.lua          # live github raw + jsDelivr — 17 checks, 0 failures
```

Covered: context detection (mode/difficulty/speed/waves/countdown/seeds/map_sig/loadout), remote scan,
record → 9 steps with world points and per-step wave+dt, save → load → pin → rename round trip,
mismatch detection, playback dispatch (touch / mouse / key routing), **dt accuracy asserted at the 0.3 s /
1.0 s / 2.1 s marks (no early fire, no late fire)**, speed scale = rec÷now, round alignment when the counter
is behind the macro's start wave, skip-on-missing-wave, placement verified / failed+retried, remote spy
logging fired remotes with arg previews, and the store surviving a simulated rejoin.
Raw run log is in `harness_out.txt`.

## 8. Honest limits

- **Discovery once per patch.** If GDT renames its wave label or unit container, re-run discovery (or drop in
  overrides). The engine degrades to absolute-time playback instead of pretending to be precise.
- **Speed must match or be scaled.** Recorded at x3, played at x1 → delays are multiplied by 3. `speed_mode = block`
  refuses outright instead (CONFIG tab).
- **Mode + difficulty + map + loadout are part of the macro.** Placement positions and unit costs are meaningless
  outside the run they were recorded in; that is why the stamp exists.
- **Android has no Hyperion, desktop does.** On PC you need an executor that survives the anti-tamper; on Android
  it is a non-issue. Use an alt for farming either way — `BanAsync` is per-game and real.
- **Raw recorded coordinates are still coordinates.** `follow_ui` re-resolves UI elements and `follow_world`
  re-projects world points through the live camera, which absorbs resolution and camera differences — but a
  rotated map or a moved base still invalidates a macro. That is physics, not a bug.

## 9. Trouble

| Symptom | Fix |
|---|---|
| GUI does not appear | executor lacked `loadstring`/`HttpGet`, or another instance of the UI is already loaded (`ANON_GTD` in CoreGui — rejoin). |
| `no wave anchor` / recording hint stays up | SETUP → RUN DISCOVERY → PIN ANCHOR; or MARK WAVE NOW at the start of a wave. |
| Everything fires at once | wave counter unreadable → it fell back to absolute time. Pin the anchor; keep speed identical. |
| Placements miss by a few px | SETUP → CALIBRATE TAP. |
| `no file api` toast | executor without `writefile`: macros live only for the session. |
| Game patched, nothing detected | overrides box for mode/difficulty/map/speed, then re-run discovery on the new wave label. |
| Raw GitHub 404 / blocked | check branch name in the URL, or switch the loader to the jsDelivr `MIRROR`. |

Console access: `getgenv().ANON_GTD` exposes `config`, `state`, `store`, `probe`, `recorder`, `player`, `ui`
(e.g. `getgenv().ANON_GTD.player.stop()`, or drive a recording from another script).

Useful one-liners (paste them in the executor box when the GUI is in the way):

```lua
print(getgenv().ANON_GTD.probe.report.text)        -- the whole discovery report, as text
local c = getgenv().ANON_GTD.probe.detect_context()  -- raw context right now
print(c.mode, c.difficulty, c.map_label, c.speed, c.wave_cur, c.wave_total)
print(getgenv().ANON_GTD.probe.wave_state())        -- what the anchor reader sees this second
getgenv().ANON_GTD.player.mark_wave(1)              -- force T0 = now for wave 1
getgenv().ANON_GTD.player.stop()                    -- stop playback now
getgenv().ANON_GTD.store.sorted_entries()           -- history list incl. every stamp
```

---

## 10. Runbook: the one verification pass (do this before trusting anything)

Kill two birds: prove the anchors on **your** device and hand back a report that lets the pins be set once
and for all. Takes ~5 minutes, one or two rounds. Do it on an **alt**, on the easiest difficulty you have,
so a misplaced tap costs nothing.

**Preconditions** — joined GTD, executor injected, `Main.lua` loaded, panel visible top-left with
`idle · ? · x? · no context scanned yet`.

**Step 1 — get into the run you actually farm.** Discovery inside the lobby tells you nothing: mode,
difficulty, map and speed only exist once you are in a match. Sit in the map, wave counter visible.

**Step 2 — SETUP → RUN DISCOVERY.** Read every line and compare with the table:

| Report line | Good | If it is wrong |
|---|---|---|
| `mode` | `Classic` / `Survival` / `Dojo` … | overrides box: `mode=Dojo` |
| `difficulty` | `Easy`/`Normal`/`Hard`/`Impossible` | `difficulty=Impossible` |
| `map` | a name, or `map#123456789` | `map=<what you see in game>` |
| `map_sig` | any number | leave it, it is the fingerprint |
| `speed` | `1` / `2` / `3` | `speed=3` |
| `waves` | `3 / 25` (real numbers) | wave label not found → continues in step 3b |
| `countdown` | a number near the wave | not fatal |
| `loadout` | your equipped units, or `none detected` | cosmetic, only used for the warning |
| `wave label` (ANCHORS) | a full path | step 3 |
| `remote spy` | `available` / `NOT available` | not fatal, anchor layer 1 is optional |
| `touch sim` | `available` | `unavailable` → clicks go as mouse; usually still fine |

**Step 3 — lock the anchor.** If `waves` showed real numbers: **PIN ANCHOR**, then run discovery again and
confirm the path now sits in `ANCHORS > wave label`. If it showed `nil / nil`, tap **MARK WAVE NOW** at the
moment a new round starts, and send the report anyway — the anchor then needs a manual pin from my side.

**Step 4 — record one round.** Rewind to the same mode/difficulty/map/speed. Press **RECORD**, then do exactly
three things: place one unit (tap the ground), upgrade it once, and do one drag. Then **STOP & SAVE** as
`test1`. Check the MACROS row: it must show the full stamp and `steps` above 5. Zero steps means input never
reached the recorder — tell me and I will switch strategy (it means this game feeds input through a path the
listener is not seeing).

**Step 5 — play it back.** Get back to a fresh round, same setup, counter at the same starting wave (if the
counter is already past it, the script waits for the round to restart — that is intentional). MACROS → **GO**.
Watch the status bar: `PLAY ▶ step n/N wave W late L missed M ok V fail F`.

**Step 6 — grade it, and attach the report.** Success = the unit lands on the same tile, the upgrade lands
on the same unit, and the actions happen at the same offset from wave start (not earlier, not later),
with `fail 0` and `late 0`.

| Symptom | Read | Do |
|---|---|---|
| taps land a few px off, everything else fine | input space vs gui space offset on your device | SETUP → **CALIBRATE TAP**, replay |
| unit lands on the wrong tile | camera/world projection, or map layout differs | send the report; also try CFG → `follow world point: OFF` |
| actions all fire at once, in a burst | wave counter unreadable, absolute-time fallback kicked in | step 3, then send the report |
| nothing fires at all | wrong round in the counter, or `holding` forever | check `wave W` in the status line matches the macro's start wave |
| UI button tap does nothing | the game answers `Activated` only | CFG → `click method: ui` and replay |
| `fail` climbing | placement never lands (seeds short / wrong slot) | check seeds; send report + which unit |
| drops / kick after a while | nothing to do with the macro | use alt; keep loops sane |

**Step 7 — send back.** SETUP → **COPY REPORT** (or, without clipboard: the report prints to the executor
console, or `print(getgenv().ANON_GTD.probe.report.text)`), plus: the name of `test1` and one sentence on
what differed. With that I pin the real wave label / unit container into the config instead of relying on
detection, and hand you back a build where step 2 is unnecessary.
