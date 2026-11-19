# Known issues

Things that are wrong or missing on purpose-for-now. Fix when their milestone comes up.

## Gameplay
- Walking through cables does nothing. Tripping over them (and yanking the plug) is planned for the chaos milestone.
- Players walk through all small items (GPUs, servers, strips, boxes). Deliberate for now: colliding with them made everything twitch. Only racks block you.
- Cables are straight sagging lines: they pass through walls, racks and other objects.
- A placed (pinned) item ignores physics: thrown objects bounce off it and cannot knock it over.
- No cooling, heat or fire yet.
- Two players can stand inside each other.
- You can build on a plot you do not own; only its fibre pole is locked.
- Generators have no downsides yet (no noise, fumes or fire), and there is no day/night for solar.
- A pedalling player is glued to the bike but has no sitting pose.

## Untested
- Breaker trip and reset (written, never triggered in a test).
- Fuel running out, solar panels, and the fibre pole on a bought plot (written, never triggered in a test).
- Cable yanked out at 7 m (written, never triggered in a test).
- A real connection over Tailscale (only same-PC connections were tested).
- Settings menu has never been looked at on screen.

## Presentation
- No sound at all; the volume slider does nothing audible.
- The rack is dark and hard to read from behind.
- Blob animation is basic (no carrying pose, no idle variety).
