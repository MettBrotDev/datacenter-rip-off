# Roadmap

Ideas the owner has asked for that are not built yet. Nothing here is designed in detail;
each needs a short design discussion before building.

## Power ladder
Built: exercise bike (300 W) -> lawnmower generator (1.2 kW) -> solar panel (400 W, weather dependent)
-> diesel generator (5 kW).

Wanted next, in this order. These are big structures, not carryable items, so they need a way to be
built on a plot (how exactly is still open):
1. **Coal power plant** — a full-size one.
2. **Nuclear fission reactor.**
3. **Fusion reactor.**

Open questions for the reactors:
- How they get into the world: delivered as a kit and assembled piece by piece on a demolished lot?
  Several neighbouring lots merged into one site?
- What they consume (coal deliveries, fuel rods, startup power for fusion) and who has to carry it.
- What goes wrong (smoke and neighbours, overheating, meltdown, containment loss) and how recoverable it is.
- How power leaves them: sockets like a generator, or a plot-wide grid of their own.
- Scale: today's whole garage runs on 3.6 kW. Reactors only make sense once there is hardware that
  can use megawatts (bigger racks, AI pods, more plots).

## Weather
Built: sunny / cloudy / rain, changing every 1.5-4 minutes, scaling solar output (100% / 40% / 0%).
Also built: rain falls only where there is no roof, and ruins unpacked electronics left outside.
Ideas: day and night, wind (and wind turbines), storms, tarps or carports to shelter a pad, drying or repairing wet hardware.

## Chaos layer (milestone 3)
Built: room and chip temperatures, liquid cooling with hoses that leak and spray, fire and
extinguishers, power strips that melt, tripping over cables, dud used parts, a heat suit, a dumpster.
Next: network loops, generator fumes and noise, a mop, throwing buckets of water, taps on every house,
immersion cooling in a paddling pool.

## Company layer (milestone 4)
Built: tokens per second as live compute (served, worked on, rented out or wasted: it cannot be stored), the rental
market, slop, products that need serving, model training, the API platform, funding stages, random company events.
Needs: balancing (nothing has been played), staff or automation, more events, a way to lose
(debt? investors?), research that unlocks hardware, the reactors' reason to exist (megawatt compute).

## Town and neighbours
Built: 38 buyable houses (including the landlady's, next to the garage), haggling, demolition into a building pad.

Asked for by the owner, not built yet:
- **House demolition as an event**: a funny animation, something exciting to watch, instead of the
  house just vanishing.
- **Neighbour complaints**: about generator noise, smoke, power cuts, cables across their lawn...
- **Demonstrations**: neighbours protesting outside the datacenter when things get bad enough.

Other ideas: neighbours with routines, merging adjacent pads, vehicles for the
bigger map, a hardware store you walk to.

## Lighting
Built: one dim always-on bulb per room; floor lamps you buy and have to power.
Open (owner undecided): whether room lights should need power at all. Going dark when the power
fails is funny, but being unable to see is annoying.

## Beyond real hardware (the invented tiers)
Everything in the shop today is a parody of something that exists. The late game should leave reality behind:
- Tier 6 and up: made-up GPUs (wafer-scale cards, photonic cards, a card that needs its own substation), CPUs with
  absurd core counts, DDR6/DDR7 and stranger memory (holographic sticks, RAM that must be kept frozen).
- Machines to hold them: immersion tanks you lower servers into, a cryo rack, a containerised datacenter delivered by
  truck, eventually an orbital rack where cooling is free and cables are not.
- Power and cooling to match: the planned coal, fission and fusion reactors, then invented ones (a pocket tokamak,
  something the neighbours really should not know about); cooling with liquid nitrogen, a pond, the town's river.
- Each invented step should bring one new way to fail, in the spirit of the rest: funny and recoverable.
