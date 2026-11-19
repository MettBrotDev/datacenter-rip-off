extends RefCounted
## Host only: the second-hand market. A rotating set of offers from dubious sellers, each hiding a
## condition that only shows when the parcel is unpacked, plus the four staples that are always in stock.
## `state()` is what every peer sees (it never contains a condition); the action methods return ""
## or a reason they refused, like company.gd.

const Catalog = preload("res://scripts/catalog.gd")

const STAPLES: Array[String] = ["pc_office", "server", "gpu_1080", "ram_8"]
const STAPLE_SELLER := "Honest Gary's Used Stuff"
const COUNT := 9                       # offers on the board
const LIFETIME := Vector2(150.0, 420.0)   # seconds an offer stays
const START_LIFETIME := Vector2(150.0, 420.0)
const HAGGLE_OFF := 0.8                # price multiplier when the seller gives in
# Most expensive item (new price) that is "near what the crew can use", by funding level.
const CAP := [450.0, 1600.0, 4500.0, 13000.0, 30000.0, 60000.0, 100000.0]
const TEMPT := 0.14                    # share of offers that ignore the cap
const RIGS := 0.3                      # share of offers that are a whole machine with parts in it
const RIG_PRICE := 0.85                # a rig is cheaper than its parts bought one by one, second-hand
const SKIP := ["crate", "fuel", "screwdriver", "bucket", "extinguisher", "suit", "lamp", "outlet"]

## Seller grade: price share of the new price, and odds of each hidden condition (weights).
const GRADES := [
	{"name": "shady", "price": Vector2(0.30, 0.44), "haggle": 0.7,
		"odds": {"fine": 25, "dead": 25, "sketchy": 12, "soaked": 12, "brick": 10, "swapped": 10, "bonus": 6, "gutted": 22, "dud": 20}},
	{"name": "plain", "price": Vector2(0.44, 0.57), "haggle": 0.55,
		"odds": {"fine": 55, "dead": 12, "sketchy": 6, "soaked": 8, "brick": 4, "swapped": 7, "bonus": 8, "gutted": 9, "dud": 12}},
	{"name": "nice", "price": Vector2(0.57, 0.70), "haggle": 0.4,
		"odds": {"fine": 75, "dead": 6, "sketchy": 3, "soaked": 4, "brick": 2, "swapped": 4, "bonus": 6, "gutted": 4, "dud": 6}},
]

const SELLERS := ["xX_GpuGuy_Xx", "Dave (not that Dave)", "My Ex's Garage", "Definitely Legit Ltd", "Brenda from IT",
	"Sven's Surplus", "Cheap Chips Chuck", "Dr. Solder", "RamRaider99", "Uncle Bob's Basement", "TotallyNewStuff",
	"Pawel & Sons", "Mining Mike (retired)", "Bargain Barbara", "Server Steve", "The Man With The Van",
	"Kevin, 14", "Patricia Overclock", "Liquidation Larry", "Gran's Attic"]

const TONE := {
	0: ["Sold as seen. No returns, no questions.", "Cash only. Meet at the van.", "Price is firm. Do not ask where it came from.",
		"Must go today, landlord is coming."],
	1: ["Used, works, collect it from the driveway.", "Selling because I upgraded.", "Normal condition for its age.",
		"Photos available on request. Requests ignored."],
	2: ["Lovingly kept. Smoke-free home. Original box (the box is a lie).", "Barely used, my grandmother's.",
		"Cleaned with a tiny brush. Serious buyers only.", "Premium seller, five stars (I rated myself)."],
}
const HINT := {
	"fine": ["Works great, trust me.", "Never had a problem with it.", "My uncle was careful with it."],
	"dead": ["Sold for parts or repair.", "Worked last Tuesday.", "Smells a bit funny, probably normal.", "Fell off a shelf once. Maybe twice."],
	"sketchy": ["Runs warm, but it has never once complained.", "I removed the annoying thermal stuff. You are welcome.",
		"Never shuts down, whatever you throw at it.", "Fireproof, I assume."],
	"soaked": ["Rescued from a flood. The photos are blurry on purpose.", "Slightly moist. Dries in no time.", "Found it in the garden."],
	"brick": ["Sealed box, as seen.", "Heavy. Very heavy. Trust me.", "Photo is a stock photo of the real thing."],
	"swapped": ["Similar to the picture.", "Original box lost, so I used another box.", "Close enough."],
	"gutted": ["Lighter than you would expect.", "Complete, in spirit.", "I kept one small thing as a souvenir.",
		"Everything is in there, surely."],
	"dud": ["Mostly works.", "Tested 90% of it.", "One of the parts made a noise once. Just once.", "Ran fine until the thunderstorm."],
	"bonus": ["Contents may include extras, I was too lazy to check.", "Comes with some bits I could not get out.",
		"Do not open the lid without a plan."],
}
# What the pick-up point pays, as a share of the new price. Ruined things are scrap.
const SELL_WORKING := 0.35
const SELL_USED := 0.15
const SELL_PARCEL := 0.25
const SCRAP := 0.03
# Things that have no catalog price: what a courier gives for them, and for the scrap.
const FURNITURE := {"sofa": 40, "tv": 30, "table": 10, "bed": 50, "fridge": 35, "plant": 3}

## host: {id, kind, seller, text, price, was, left, haggled, cond, actual, grade, new,
##   parts: [kind] the advert promises inside (a rig; [] for a single item), inside: [[kind, dead]] what is really in there}
var listings: Array = []
var test_force := ""        # test hook: every new random listing gets this condition (when it applies)

var _next := 1
var _refill := 0.0
var _level := 0


## Dollars the pick-up point pays for one thing. `contains` is the kind inside, for a parcel.
static func sale_value(kind: String, ruined: bool, contains := "") -> int:
	if kind == "parcel":
		return maxi(1, int(Catalog.ITEMS[contains]["price"] * SELL_PARCEL))
	var def: Dictionary = Catalog.ITEMS[kind]
	if FURNITURE.has(kind):
		return maxi(1, int(FURNITURE[kind] * (SCRAP if ruined else 1.0)))
	var price: float = def.get("price", 1)
	if ruined:
		return maxi(1, int(price * SCRAP))
	return maxi(1, int(price * (SELL_USED if def.get("used", false) else SELL_WORKING)))


func state() -> Dictionary:
	var out := []
	for l: Dictionary in listings:
		out.append({"id": l["id"], "kind": l["kind"], "seller": l["seller"], "text": l["text"], "price": l["price"],
			"was": l["was"], "left": l["left"], "haggled": l["haggled"], "parts": l["parts"], "new": l["new"]})
	return {"staples": STAPLES, "seller": STAPLE_SELLER, "listings": out}


## Compact one-line form for debug dumps (no conditions, no timers).
func summary() -> String:
	var bits: Array[String] = []
	for l: Dictionary in listings:
		bits.append("%d:%s:%d" % [l["id"], l["kind"], l["price"]])
	return ",".join(bits)


func fill(level: int) -> void:
	_level = level
	while listings.size() < COUNT:
		listings.append(_make(START_LIFETIME))


func tick(dt: float, level: int) -> bool:
	_level = level
	var changed := false
	for l: Dictionary in listings.duplicate():
		l["left"] -= dt
		if l["left"] <= 0.0:
			listings.erase(l)
			changed = true
	if listings.size() < COUNT:
		_refill -= dt
		if _refill <= 0.0:
			listings.append(_make(LIFETIME))
			_refill = randf_range(4.0, 25.0)
			changed = true
	return changed


func find(id: int) -> Dictionary:
	for l: Dictionary in listings:
		if l["id"] == id:
			return l
	return {}


## Pays are done by the world. Returns "" and the listing when it can be bought.
func can_buy(id: int, money: float) -> String:
	var l := find(id)
	if l.is_empty():
		return "Somebody else got there first."
	if l["price"] > money:
		return "You are %d short." % ceili(l["price"] - money)
	return ""


func take(id: int) -> Dictionary:
	var l := find(id)
	listings.erase(l)
	return l


## "Offer less". Returns {"text": what the seller says, "gone": the listing vanished}.
func haggle(id: int) -> Dictionary:
	var l := find(id)
	if l.is_empty() or l["haggled"]:
		return {}
	l["haggled"] = true
	var roll := randf()
	var yes: float = GRADES[l["grade"]]["haggle"]
	if roll < yes:
		l["was"] = l["price"]
		l["price"] = maxi(1, int(round(l["price"] * HAGGLE_OFF)))
		return {"text": "%s accepted your offer: now %s" % [l["seller"], "$%d" % l["price"]], "gone": false}
	if roll < yes + (1.0 - yes) * 0.5:
		return {"text": "%s: \"Price is firm. Do not ask again.\"" % l["seller"], "gone": false}
	listings.erase(l)
	return {"text": "%s blocked you. The offer is gone." % l["seller"], "gone": true}


## Test hook: adds a listing with a chosen hidden condition. `actual` = the kind that is really in the box.
## With `parts` it is a rig: that machine with those parts in it.
func test_listing(kind: String, cond: String, actual := "", parts: Array = []) -> int:
	var l := _make(START_LIFETIME, kind, cond, parts)
	if actual != "":
		l["actual"] = actual
	listings.append(l)
	return l["id"]


# --- making an offer --------------------------------------------------------------------------

func _pool() -> Array:
	var cap: float = CAP[clampi(_level, 0, CAP.size() - 1)]
	var near := []
	var far := []
	var have := {}
	for l: Dictionary in listings:
		have[l["kind"]] = true
	for kind: String in Catalog.SHOP:
		if kind in STAPLES or kind in SKIP or have.has(kind):
			continue
		var price: float = Catalog.ITEMS[kind]["price"]
		if price <= cap and price >= cap * 0.02:
			near.append(kind)
		elif price > cap:
			far.append(kind)
	if randf() < TEMPT and not far.is_empty():
		var tempt: Array = far.filter(func(k: String) -> bool: return Catalog.ITEMS[k]["price"] <= cap * 12.0)
		if not tempt.is_empty():
			return tempt
	return near if not near.is_empty() else far


func _make(life: Vector2, kind := "", cond := "", parts: Array = []) -> Dictionary:
	if kind == "" and randf() < RIGS:
		var rig := _rig()
		if not rig.is_empty():
			kind = rig[0]
			parts = rig[1]
	if kind == "":
		var pool := _pool()
		kind = pool[randi() % pool.size()]
	var def: Dictionary = Catalog.ITEMS[kind]
	var is_rig := not parts.is_empty()
	var roll := randf()
	var grade := 0 if roll < 0.3 else (1 if roll < 0.75 else 2)
	if cond == "":
		cond = test_force if test_force != "" and _applies(test_force, kind, is_rig) else _roll_cond(kind, grade, is_rig)
	var share := randf_range(GRADES[grade]["price"].x, GRADES[grade]["price"].y)
	var new_price := float(def["price"])
	for part: String in parts:
		new_price += float(Catalog.ITEMS[part]["price"])
	var price := new_price * share * (RIG_PRICE if is_rig else 1.0)
	# what is really inside: the advert minus whatever the seller forgot to mention
	var inside: Array = []
	for part: String in parts:
		inside.append([part, false])
	if cond == "gutted" and not inside.is_empty():   # the most expensive part stayed with the seller
		var best := 0
		for i in inside.size():
			if Catalog.ITEMS[inside[i][0]]["price"] > Catalog.ITEMS[inside[best][0]]["price"]:
				best = i
		inside.remove_at(best)
	elif cond == "dud" and not inside.is_empty():
		inside[randi() % inside.size()][1] = true
	elif cond == "brick":
		inside = []
	price = round(price / 5.0) * 5.0 if price >= 100.0 else round(price)
	var hint_cond: String = cond if randf() < 0.65 else "fine"
	var tone: Array = TONE[grade]
	var hints: Array = HINT[hint_cond]
	var text := "%s %s" % [tone[randi() % tone.size()], hints[randi() % hints.size()]]
	var actual := kind
	if cond == "brick":
		actual = "crate"
	elif cond == "swapped":
		actual = _cheaper(kind)
	var l := {"id": _next, "kind": kind, "seller": SELLERS[randi() % SELLERS.size()], "text": text,
		"price": maxi(1, int(price)), "was": 0, "left": randf_range(life.x, life.y), "haggled": false,
		"cond": cond, "actual": actual, "grade": grade, "parts": parts, "inside": inside, "new": int(new_price)}
	_next += 1
	return l


## A machine and a sensible set of parts for it, as [chassis kind, [part kinds]], or [] if nothing fits the budget.
## Sellers build what boots: a CPU that suits the cards, enough RAM for them, no more watts than the supply has.
func _rig() -> Array:
	var cap: float = CAP[clampi(_level, 0, CAP.size() - 1)] * 2.5
	var have := {}
	for l: Dictionary in listings:
		if not l["parts"].is_empty():
			have[l["kind"]] = true
	var machines: Array = []
	for kind: String in Catalog.ITEMS:
		var d: Dictionary = Catalog.ITEMS[kind]
		if d.has("psu") and d.has("slots") and d["price"] <= cap and not have.has(kind):
			machines.append(kind)
	if machines.is_empty():
		return []
	var chassis: String = machines[randi() % machines.size()]
	var def: Dictionary = Catalog.ITEMS[chassis]
	var room := {"cpu": 0, "ram": 0, "gpu": 0}
	for slot: Dictionary in def["slots"]:
		if room.has(slot["accepts"]):
			room[slot["accepts"]] += 1
	var cpus: Array = []
	var gpus: Array = []
	var rams: Array = []
	for kind: String in Catalog.ITEMS:
		var d: Dictionary = Catalog.ITEMS[kind]
		match d.get("group", ""):
			"cpu":
				if d["tier"] <= def["max_tier"]:
					cpus.append(kind)
			"gpu":
				if d["tier"] <= def["max_tier"] and (not d.get("liquid", false) or def.get("coolant_port", false)):
					gpus.append(kind)
			"ram":
				if d.get("ram", "") == def.get("ram", ""):
					rams.append(kind)
	if cpus.is_empty() or rams.is_empty() or room["cpu"] == 0 or room["ram"] == 0:
		return []
	var parts: Array = []
	var watts: float = def.get("watts", 0.0)
	var gpu: String = gpus[randi() % gpus.size()] if not gpus.is_empty() and room["gpu"] > 0 else ""
	var cards := 0
	if gpu != "":
		cards = randi_range(1, room["gpu"])
		while cards > 0 and watts + cards * float(Catalog.ITEMS[gpu]["watts"]) > float(def["psu"]) * 0.85:
			cards -= 1
	# a CPU within one tier of the cards, so it does not hold them back
	var want: int = Catalog.ITEMS[gpu]["tier"] - 1 if cards > 0 else 1
	cpus.sort_custom(func(a: String, b: String) -> bool: return Catalog.ITEMS[a]["tier"] < Catalog.ITEMS[b]["tier"])
	var cpu: String = cpus[-1]
	for kind: String in cpus:
		if Catalog.ITEMS[kind]["tier"] >= want:
			cpu = kind
			break
	parts.append(cpu)
	# the smallest sticks that cover what the cards need
	var need: int = cards * int(Catalog.ITEMS[gpu]["needs_ram"]) if cards > 0 else 8
	rams.sort_custom(func(a: String, b: String) -> bool: return Catalog.ITEMS[a]["gb"] < Catalog.ITEMS[b]["gb"])
	var stick: String = rams[-1]
	for kind: String in rams:
		if int(Catalog.ITEMS[kind]["gb"]) * room["ram"] >= need:
			stick = kind
			break
	for i in clampi(ceili(float(need) / Catalog.ITEMS[stick]["gb"]), 1, room["ram"]):
		parts.append(stick)
	for i in cards:
		parts.append(gpu)
	return [chassis, parts]


func _applies(cond: String, kind: String, is_rig := false) -> bool:
	var def: Dictionary = Catalog.ITEMS[kind]
	match cond:
		"gutted", "dud":
			return is_rig
		"swapped", "bonus":
			if is_rig:
				return false
	match cond:
		"dead", "soaked":
			return def.get("fragile", false) or def.has("psu")
		"sketchy", "bonus":
			return def.has("psu")
		"swapped":
			return _cheaper(kind) != kind
	return true


func _roll_cond(kind: String, grade: int, is_rig := false) -> String:
	var odds: Dictionary = GRADES[grade]["odds"]
	var total := 0.0
	for cond: String in odds:
		if _applies(cond, kind, is_rig):
			total += odds[cond]
	var pick := randf() * total
	for cond: String in odds:
		if not _applies(cond, kind, is_rig):
			continue
		pick -= odds[cond]
		if pick <= 0.0:
			return cond
	return "fine"


## A cheaper item of the same group that the seller can pass off as the real thing.
func _cheaper(kind: String) -> String:
	var def: Dictionary = Catalog.ITEMS[kind]
	var group: String = def.get("group", "")
	if group == "" or group == "pc":
		group = "server" if def.has("psu") else ""
	if group == "":
		return kind
	var best := kind
	var best_price := 0.0
	for other: String in Catalog.ITEMS:
		var o: Dictionary = Catalog.ITEMS[other]
		var same: bool = (o.get("group", "") == group) or (group == "server" and o.has("psu") and o.get("group", "") != "pc")
		if other != kind and same and o["price"] < def["price"] * 0.8 and o["price"] > best_price:
			best = other
			best_price = o["price"]
	return best
