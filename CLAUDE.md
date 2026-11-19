# Rack & Ruin

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
- `scripts/item.gd` — carryable physics objects (data table `KINDS`)
- `scripts/garage.gd` — first location; `scripts/hud.gd`, `menu.gd`, `ui.gd` — UI

## Testing (always do this after changes)
Flags go after `--`: `--host`, `--join[=ip]`, `--name=X`, `--bot`, `--yaw=DEG`, `--probe=SECONDS`, `--shot=PATH`.
- Script errors + logic: `godot_console --headless --path . -- --host --bot --probe=4`
- Sync: run a headless `--host --probe=9` in the background, then a `--join --bot --probe=7`; the two dumps must match.
- Visuals: headless host + windowed `--join --shot=file.png`, then look at the image.

## Milestones
1. DONE — walk around together, carry and throw objects
2. Core loop: racks, hardware, hand-wired power/cooling/network, money
3. Chaos: heat, breakers, leaks, network loops, trip-over cables, sketchy used hardware
4. Company layer: products, AI models, shop, progression, bigger locations
5. Polish: glow, sound, UI, balance

## Working style
Main session stays on the top model. Delegate well-specified low-level work to cheaper subagents
(Sonnet for implementation from a clear spec, Haiku for data tables and boilerplate).
