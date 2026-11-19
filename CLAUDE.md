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
- Machines (`psu` in the catalog: office PC, tower server, workstation, GPU server, AI pod) are
  empty chassis with slots for CPUs, RAM sticks and GPUs (`slots` = [{accepts, xf}]). The lid is
  screwed on (`Item.opened`, needs the screwdriver tool); parts go in and out only while it is off,
  and snap to the nearest free slot under the crosshair (`player._mount_spot`, `world.free_slot`).
  `Sim.machine_report()` (static, used by host and prompts) decides what a build does: no CPU or no
  RAM or more watts than the power supply = no boot; each GPU needs free RAM; a CPU more than one
  tier below a GPU halves it; each chassis has a `max_tier`. Swapping parts with the power on can
  kill them. Machines make tokens while powered AND online.
- Lighting: every room has one dim bulb that needs no power; floor lamps are bought and powered.
- Heat uses believable numbers. Rooms: every watt used in a building warms its air (`sim._room_step`);
  doors, fans, air conditioners cool it. Chips (`Item.heat` on servers): about 48 C above the room when
  busy and air-cooled; throttle at 85, shut down at 100, resume at 80. Consumer GPUs never need more.
- Liquid cooling (`sim._coolant_step`): `liquid` GPUs have no fans; their server needs a coolant hose
  (third link type "coolant", key H) to a manifold -> pump -> reservoir (-> garden tap for auto-refill),
  with a radiator on the same pump, outdoors. Hoses have a fill level (`Item.hose`). Unplugging a full
  hose makes a puddle; with the pump running it sprays and ruins electronics nearby (`world._unplug`).
  Pumps can drain their hoses first. Puddles (`world.puddles`) ruin electronics standing in them.
- People: above 50 C (deliberately generous) the local player's `exposure` builds up; at 100% they pass out and wake on the
  driveway. A worn heat suit (`Item.worn`) prevents it and slows walking.
- Money: servers only make TOKENS. `company.gd` (host only, rules) and `company_data.gd` (all content
  and numbers) turn them into money. Design intent from the owner: money is ALWAYS TIGHT, and there is
  a steep ladder where every step needs far more tokens and pays more per token.
  - Raw tokens sell on a swinging spot market (worst deal). Slop: cheap, short-lived. Products: need a
    smart model and hundreds of thousands to millions of tokens, i.e. real infrastructure.
  - Models have four stats: `smart` 1-5 (what it can make, how good its code is), `productivity`
    (income per token), `reliability` (not hallucinating), `speed`. Licensed models (parody names) are
    rented per minute or bought; some are slop-only.
  - Own models: the model in use writes a five-part training stack (`COMPONENTS`, levels 0-5, capped by
    its smartness); a stack at level N trains a model of smartness N + 1. No licence fees afterwards.
  - Running costs never stop: garage rent (until the landlady's house is ours), property tax per
    house, model licence, 12% taxes. Below zero the landlady cuts the garage's internet.
  - Lifetime earnings set the funding stage: unlocks content, +1 slot, token storage x6.
  Every peer sees `world.co` (= `Company.state()`); actions go through `world.request_company()`.
- UI: `ui.gd` is the design system (Inter + Material Icons from `fonts/`, loaded at runtime by
  `UI.setup()`; colours, text styles, cards, buttons by kind, chips, pills, bars, tiles). Every screen
  uses it. `company_menu.gd` is the company menu (Tab): tabs built once and updated in place.
- Ops screen: `ops_board.gd` is one SubViewport dashboard shown by every `ops_screen.gd` (a fixed one on
  the garage's back wall, plus the buyable `screen` item). Headline numbers are always on it; details
  need sensors (`sensor` in the catalog: thermometer, power meter, coolant sensor). The same gating
  applies to the HUD's "HERE" temperature and the pump's prompt.
- Fire comes from causes that make sense: power strips over 2000 W, and used servers whose thermal
  protection is broken (`Item.sketchy`). It ruins items after 6 s, spreads to flammable neighbours,
  and is put out with an extinguisher or by rain.
- Sprinting across a cable or hose pulls it out. Used parts may be dead on arrival.
- The dumpster beside the driveway (`dumpster.gd`) deletes whatever is inside when its button is pressed.
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
`--money=N`, `--port=N`, `--bench`, `--pitch=DEG`, `--pose=N`, `--shop`, `--company[=TAB]`, `--demo`, `--selftest`,
`--probe=SECONDS`, `--shot=PATH` (full list at the top of `scripts/main.gd`).
- Everything at once: `godot_console --headless --path . -- --host --port=24570 --selftest --money=250000 --weather=0 --probe=82`
  (takes about 90 s; give every parallel run its own `--port`)
  prints one CHECK line per stage (pedal power, shelf placement by key press, wiring the garage via inlet
  and sockets, a lamp, buying and demolishing houses, solar, a wall-mounted socket). Read the CHECK lines.
- Sync: headless host with `--probe` in the background, then a headless `--join --probe=N`; the two dumps must match.
- Visuals (rare): `godot_console --position 6000,6000 --path . -- --host --open --pos=.. --yaw=.. --shot=file.png`,
  then look at the image. This opens a real (off-screen) window.

## Milestones
1. DONE — walk around together, carry and throw objects
2. MOSTLY DONE — shop, racks, servers, GPUs, cables, breakers, money, generators, weather, town, buyable houses. Missing: cooling
3. MOSTLY DONE — heat, liquid cooling, leaks, fire, extinguisher, strip overload, tripping, dud parts, heat suit. Missing: network loops, generator fumes and noise
4. MOSTLY DONE — company layer: tokens, slop, products, model market, training stack, platform, funding stages, company menu. Needs balancing
5. Polish: glow, sound, UI, balance

## Working style
Main session stays on the top model. Delegate well-specified low-level work to cheaper subagents
(Sonnet for implementation from a clear spec, Haiku for data tables and boilerplate).
