# Known issues

Things that are wrong or missing on purpose-for-now. Fix when their milestone comes up.

## Gameplay
- Players walk through all small items (GPUs, servers, strips, boxes). Deliberate for now: colliding with them made everything twitch. Only racks block you.
- Cables are straight sagging lines: they pass through walls, racks and other objects.
- A placed (pinned) item ignores physics: thrown objects bounce off it and cannot knock it over.
- Two players can stand inside each other.
- Neighbours just stand by their door; they do not react to anything except offers.
- A neighbour who sold their house simply vanishes.
- Demolition is instant: no animation, no rubble, no cost.
- Furniture cannot be sold or thrown away for money.
- Houses have no back door and no upstairs.
- A demolished house leaves an open pad: with rain ruining electronics, a pad is only usable for
  generators until there is something to build a roof with.
- Rain also ruins a neighbour's left-behind TV once their house is demolished around it.
- Trees stop the rain you see, but not the rain damage: only real roofs protect hardware.
- Parcels pile up on the driveway in a 5 x 3 grid; the 16th delivery lands on top of the 1st if it is still there.
- A building cannot be powered from another building's wall socket; an inlet must lead to a generator.
- Fuel is so cheap compared with what hardware earns that running out is the only real cost. Needs balancing.
- Playing alone, the opening is awkward: the only free power is the bike, and you cannot pedal and work at once.
- Generators have no downsides yet (no noise, fumes or fire). There is weather but no day/night.
- A pedalling player is glued to the bike but has no sitting pose.

- Liquid cooling is one manifold-and-pump tree, not a true loop: there is no return hose.
- Only the garage has a garden tap. Elsewhere reservoirs are filled by bucket.
- Buckets only fill reservoirs; you cannot throw water on a fire or on a friend.
- Puddles are flat discs that ignore walls, and nothing mops them up: they dry by themselves.
- The ops screen text is small from across the garage; it reads well from a few steps away.
- Flow rate is a fixed 20 l/min per running pump; "back" temperature is shown but does not affect anything.
- The HUD shows only weather and temperature now; money, tokens and watts are on the ops screen, in the company menu and (balance) in the shop.
- Without a thermometer the HUD shows "? °C" indoors even while you are overheating; the red screen tint is the only warning.
- Passing out from heat just moves you to the driveway. Nobody has to rescue you.
- A server with one liquid-cooled card and one ordinary card is treated as fully liquid-cooled.
- A machine can only be opened while it stands loose, and you have to look into it from above:
  take it out of the rack first.
- Power supplies are part of the chassis and cannot be swapped. Machines have no storage drives.
- Hardware models are still plain boxes; a remodel is planned once the rendering pass is in.
- Fire does not hurt players, walls or houses, only items. Extinguishers never run out.
- Ruined hardware cannot be repaired or sold, only thrown in the dumpster.
- Only sprinting trips over cables; there is no falling animation, just a stumble.

- The economy is unbalanced: every number in `company_data.gd` is a first guess that nobody has played.
- At the start there is no income until you have tokens to sell: the first minutes are pedalling for $0.10 a token.
- Fuel no longer competes with income the way it did; generator running costs need another look.

## Untested
- Building a machine by hand: unscrewing the lid with the screwdriver, the ghost snapping to slots,
  pulling parts back out (the test drives the same requests directly, not the crosshair).
- Hot-swapping a part with the power on (25% chance to kill it) has never been triggered in a test.
- The new shop has been looked at but not clicked: category buttons, selecting a part, the quantity
  buttons and Buy (the purchase itself is tested).
- The company menu has only been looked at, never clicked: every button, the platform share control,
  Rent / Buy / Write code / Train from the menu itself. The actions behind them are tested.
- The lower half of the Model Lab tab (training stack, plan, Train) and the restyled shop, haggling
  screen and pause menu have not been seen on screen.
- Breaker trip and reset, and one generator stalling so its share lands on another (written, never triggered in a test).
- Fuel running out, and wiring a bought house (written, never triggered in a test; only the garage was wired).
- Fire spreading, a power strip melting at over 2000 W, and a used server with broken protection igniting.
- Fans and the air conditioner actually cooling a room; a radiator placed indoors heating it.
- The coolant, bucket, suit and drain controls as key presses (the test calls the requests directly).
- Tripping by actually running over a cable (the test calls the request directly).
- What flames look like on screen.
- Unpacking by pressing Q (the test calls the request directly).
- Mounting things on walls by looking at them (the test places the socket by coordinates, not by crosshair).
- The offer screen, front doors and walking around the town have never been tried by hand.
- Performance of the big town on a weaker PC than the owner's RTX 5090.
- Cable yanked out at 7 m (written, never triggered in a test).
- A real connection over Tailscale (only same-PC connections were tested).
- Settings menu has never been looked at on screen.

## Presentation
- No sound at all; the volume slider does nothing audible.
- The rack is dark and hard to read from behind.
- Blob animation is basic (no carrying pose, no idle variety).
