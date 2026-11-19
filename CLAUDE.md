# Datacenter Rip Off

First-person co-op (2–4 players) datacenter tycoon in the spirit of "DataCenter Tycoon" (Steam),
but janky and chaotic: the game never blocks a stupid setup, it simulates the consequences.
Private project for the owner and friends (comp-sci students — nerdy in-jokes welcome).
Rule of thumb for chaos: funny and recoverable, never tedious.

## Stack
- Godot 4.7.2, GDScript. Console exe: `F:\Programs\Godot\Godot_v4.7.2-stable_win64_console.exe`
- Blender 5.3 at `F:\Programs\Blender\blender.exe` (scripted models, not used yet)
- Everything is built from code: no hand-edited scenes, no imported assets so far.
- No `class_name` — scripts reference each other with `const X = preload(...)` so the project
  runs headless without an editor import step.

## Layout
- `scripts/net.gd` — autoload `Net`: ENet host/join (UDP 24565), player list, player transform sync
- `scripts/main.gd` — root; menu <-> world; test flags
- `scripts/world.gd` — level, players, items; all item state is host-authoritative
  (`request_*` local call, `_h_*` host handler, `_r_*` replicated result)
- `scripts/player.gd`, `blob.gd` — first-person controller and the blob body
- `scripts/catalog.gd` — ALL game data: item kinds, shop list, prices, economy constants
- `scripts/item.gd` — physical objects: loose / held / attached-in-a-slot, plus power and net cable links
- `scripts/fixture.gd` — wall outlets, internet uplink, breaker box, shop laptop (negative ids)
- `scripts/sim.gd` — host-only power/network/money simulation, 2 steps per second
- `scripts/cables.gd` — draws cables (visual only)
- `scripts/garage.gd` — first location; `hud.gd`, `shop.gd`, `menu.gd`, `ui.gd` — UI
- `scripts/settings.gd` (autoload `Settings`, saved to user://options.cfg), `settings_menu.gd`

## Core rules of the simulation
- THERE IS NO ELECTRICITY GRID. All power comes from generators (`gen` in the catalog: pedal / fuel / solar).
  Plug devices or strips straight into a generator, or wire a building: a power INLET item inside it,
  cabled to a generator, energises the building; every wall SOCKET item inside then delivers power.
  A building's load is shared between the generators feeding it, in proportion to their size.
- Each owned building has a breaker with a wiring limit (garage 3600 W, houses 3600-7500 W by size).
- Power and network are chains of cables: item -> provider -> ... Loops are allowed and simply dead.
- Nothing is validated at build time except socket counts and cable length (7 m, then it gets yanked out).
- Overloading a generator stalls it (or throws the rider off the bike); its share then lands on the others.
- Internet comes from the garage's wall box and from the router in every house we own.
- Servers earn while powered AND online; GPUs mounted on them add tokens/s and watts.
- Lighting: every room has one dim bulb that needs no power; floor lamps are bought and powered.
- Purchases arrive outside on the driveway as `parcel` items (`Item.contains` = what is inside) and are
  unpacked with Q. Parcels are rainproof.
- Rain ruins `fragile` items (electronics) that are outdoors for 5 s in total: status bit 2, permanent.
  Outdoors = not under the garage or a standing house (`world.is_outdoors`).
- The rain you see is GPU particles colliding with a top-down height field around the camera (`weather.gd`),
  so it falls outside windows and doors but not under roofs.
- Items placed with E on a surface are pinned (no physics) until grabbed or their support disappears.
- The town: `scripts/town.gd` is the layout (streets, 37 lots, park, bounds) shared by scenery and gameplay.
  `scripts/outside.gd` is pure scenery built on it (one subagent-written file, heavily MultiMesh-batched).
  `scripts/shapes.gd` makes the soft-edged meshes everything uses.
- Houses (`scripts/house.gd`): one per lot plus our own (id 0). States NEIGHBOUR / OURS / GONE (demolished).
  Bought by haggling with the neighbour (`offer.gd`, host logic in `world._h_offer`). Each has its own
  breaker circuit (circuit id = house id, garage = 1000), a router and furniture items. We start with
  the garage only; house 0 next door belongs to "your landlady".
- Weather (`Catalog.WEATHER`, decided in `sim.gd`, drawn by `weather.gd`) scales solar output.
- Planned features and open design questions live in `ROADMAP.md`; known problems in `KNOWN_ISSUES.md`.
- Collision layers: 1 world, 2 loose items, 4 mounted items (ray only), 8 players, 16 big items.

## Testing (always do this after changes)
The owner works on this PC while tests run: use `--headless` for everything except screenshots.
Any test flag puts the game in test mode: the mouse is never captured, real mouse and keyboard input is
ignored (only events tagged with meta "test" count) and a test window never takes focus.
Flags go after `--`: `--host`, `--join[=ip]`, `--name=X`, `--bot`, `--yaw=DEG`, `--pos=X,Y,Z`, `--open`,
`--money=N`, `--selftest`, `--probe=SECONDS`, `--shot=PATH`.
- Everything at once: `godot_console --headless --path . -- --host --selftest --money=90000 --weather=0 --probe=18`
  prints one CHECK line per stage (pedal power, shelf placement by key press, wiring the garage via inlet
  and sockets, a lamp, buying and demolishing houses, solar, a wall-mounted socket). Read the CHECK lines.
- Sync: headless host with `--probe` in the background, then a headless `--join --probe=N`; the two dumps must match.
- Visuals (rare): `godot_console --position 6000,6000 --path . -- --host --open --pos=.. --yaw=.. --shot=file.png`,
  then look at the image. This opens a real (off-screen) window.

## Milestones
1. DONE — walk around together, carry and throw objects
2. MOSTLY DONE — shop, racks, servers, GPUs, cables, breakers, money, generators, weather, town, buyable houses. Missing: cooling
3. Chaos: heat, breakers, leaks, network loops, trip-over cables, sketchy used hardware
4. Company layer: products, AI models, shop, progression, bigger locations
5. Polish: glow, sound, UI, balance

## Working style
Main session stays on the top model. Delegate well-specified low-level work to cheaper subagents
(Sonnet for implementation from a clear spec, Haiku for data tables and boilerplate).
