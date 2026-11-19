extends RefCounted
## Host-only: the company. Tokens come in from the servers; this decides what they turn into.
## `state()` is what every peer sees (replicated twice a second as world.co); the action
## methods are what players can ask for. Each returns "" on success or a reason it refused.

const Data = preload("res://scripts/company_data.gd")

var tokens := 0.0           # stored, spendable
var earned := 0.0           # lifetime $ made, decides the funding stage
var spot := 0.1             # $ per raw token right now
var spot_trend := 0
var jobs: Array = []        # being made: {id, kind, what, name, size, risk, left, total, tokens}
var live: Array = []        # earning: {id, kind, what, name, size, peak, hype, age, earned, tokens, half_life}
var model_gen := 0
var training: Dictionary = {}   # {gen, left, total}
var users := 0.0            # platform
var share := 0.0            # share of token production reserved for the platform, 0..1
var campaign: Dictionary = {}   # {kind, left, total, gain}
var served := 0.0           # tokens/s going to platform users right now
var income := 0.0           # $ per second from everything, right now
var rate := 0.0             # tokens/s the servers make

var _next_id := 1
var _spot_left := 0.0
var _event_left := 150.0


func level() -> int:
	return Data.level_for(earned)


func state() -> Dictionary:
	var lv := level()
	var next_at: float = Data.STAGES[mini(lv + 1, Data.STAGES.size() - 1)]["at"]
	return {
		"tokens": tokens, "storage": Data.storage(lv), "rate": rate,
		"spot": spot, "spot_trend": spot_trend,
		"level": lv, "stage": Data.STAGES[lv]["name"], "earned": earned, "next_at": next_at,
		"slots": Data.slots(lv),
		"model": {"gen": model_gen, "name": _model_name(model_gen),
			"quality": Data.model_quality(model_gen), "speed": Data.model_speed(model_gen)},
		"training": training, "jobs": jobs, "live": live,
		"platform": {"open": model_gen > 0, "users": int(users), "share": share, "served": served,
			"want": users * Data.USER_APPETITE, "price": Data.PLATFORM_PRICE * Data.model_quality(model_gen),
			"campaign": campaign},
		"income": income * 60.0,
	}


## Advances the company. `produced` = tokens/s from the servers. Returns the $ earned in `dt`.
func tick(dt: float, produced: float, events: Array) -> float:
	rate = produced
	var money := 0.0

	# the platform takes its share of fresh tokens first; the rest goes into storage
	served = 0.0
	if model_gen > 0 and users > 0.0:
		var wanted: float = users * Data.USER_APPETITE
		served = minf(wanted, produced * share)
		money += served * Data.PLATFORM_PRICE * Data.model_quality(model_gen) * dt
		if served < wanted * 0.8 and dt > 0.0:   # users who get error pages leave
			users = maxf(0.0, users - users * 0.01 * dt)
	tokens = minf(Data.storage(level()), tokens + (produced - served) * dt)

	# things being built
	for job: Dictionary in jobs.duplicate():
		job["left"] -= dt
		if job["left"] <= 0.0:
			jobs.erase(job)
			_launch(job, events)
	if not training.is_empty():
		training["left"] -= dt
		if training["left"] <= 0.0:
			var gen: int = training["gen"]
			training = {}
			if randf() < 0.15:
				tokens = minf(Data.storage(level()), tokens + Data.model_cost(gen) * 0.5)
				events.append("Training %s failed: the loss went to NaN. Half the tokens were salvaged." % _model_name(gen))
			else:
				model_gen = gen
				events.append("%s is trained! Everything you launch now earns x%.2f." % [_model_name(gen), Data.model_quality(gen)])

	# things that are live: income follows hype, hype fades
	for item: Dictionary in live:
		item["age"] += dt
		item["hype"] = pow(0.5, item["age"] / item["half_life"])
		var per_second: float = item["peak"] * item["hype"] / 60.0
		item["earned"] += per_second * dt
		money += per_second * dt

	# marketing
	if not campaign.is_empty():
		campaign["left"] -= dt
		users += campaign["gain"] * dt / campaign["total"]
		if campaign["left"] <= 0.0:
			events.append("The %s campaign is over. %d people use the platform now." % [
				Data.CAMPAIGNS[campaign["kind"]]["name"].to_lower(), users])
			campaign = {}

	_market(dt)
	_random_event(dt, events)
	var before := level()
	earned += money
	income = money / dt if dt > 0.0 else income
	if level() > before:
		events.append("Funding secured: you are now a %s company. More slots, more storage, new things to build." % Data.STAGES[level()]["name"])
	return money


# --- what players can ask for -------------------------------------------------------

## Dump raw tokens on the spot market. amount <= 0 sells everything.
func sell(amount: float, events: Array) -> String:
	if amount <= 0.0 or amount > tokens:
		amount = tokens
	if amount < 1.0:
		return "No tokens to sell"
	tokens -= amount
	var got := amount * spot
	earned += got
	events.append("Sold %d raw tokens for $%d. The market thanks you for your desperation." % [amount, got])
	return "$%d" % got   # special: the caller pays this out


func start(kind: String, what: String, size: int, risk: int) -> String:
	var def: Dictionary = Data.thing(kind, what)
	if def.is_empty() or size < 0 or size >= Data.SIZES.size() or risk < 0 or risk >= Data.RISKS.size():
		return "No such thing"
	if kind == "slop":
		risk = 0
	if def["level"] > level():
		return "Needs %s" % Data.STAGES[def["level"]]["name"]
	if live.size() + jobs.size() >= Data.slots(level()):
		return "All %d slots are in use" % Data.slots(level())
	var cost: float = def["tokens"] * Data.SIZES[size]["cost"]
	if cost > tokens:
		return "Needs %d tokens" % cost
	tokens -= cost
	var seconds: float = def["time"] * Data.SIZES[size]["time"] * Data.RISKS[risk]["time"] / Data.model_speed(model_gen)
	jobs.append({"id": _id(), "kind": kind, "what": what, "name": _name(kind, def), "size": size, "risk": risk,
		"left": seconds, "total": seconds, "tokens": cost})
	return ""


## Refresh a live product: hype back to full for a share of its original price.
func update(id: int, events: Array) -> String:
	for item: Dictionary in live:
		if item["id"] == id:
			if item["kind"] != "product":
				return "Slop cannot be updated, only replaced"
			var cost: float = item["tokens"] * Data.UPDATE_COST
			if cost > tokens:
				return "Needs %d tokens" % cost
			tokens -= cost
			item["age"] = 0.0
			item["hype"] = 1.0
			item["peak"] *= 0.92   # every update excites people a little less
			events.append("%s 2.0 is out. Same thing, new gradient on the logo." % item["name"])
			return ""
	return "No such product"


## Abandon something still being built. Tokens for the part not yet done come back, minus 10%.
func cancel(id: int) -> String:
	for job: Dictionary in jobs:
		if job["id"] == id:
			jobs.erase(job)
			tokens = minf(Data.storage(level()), tokens + cancel_refund(job))
			return ""
	return "No such project"


static func cancel_refund(job: Dictionary) -> float:
	return job["tokens"] * job["left"] / job["total"] * 0.9


## Pay cash to finish a build right now: crunch time, pizza, regret.
func rush(id: int, money: float) -> String:
	for job: Dictionary in jobs:
		if job["id"] == id:
			var price := rush_price(job)
			if price > money:
				return "Needs $%d" % price
			job["left"] = 0.0
			return "$-%d" % price
	return "No such project"


## $ to rush a build: twice what its unfinished tokens would fetch on a good day.
static func rush_price(job: Dictionary) -> float:
	return ceilf(job["tokens"] * job["left"] / job["total"] * Data.SPOT_MAX * 2.0 / 10.0) * 10.0


func retire(id: int) -> String:
	for item: Dictionary in live:
		if item["id"] == id:
			live.erase(item)
			return ""
	return "No such product"


func train() -> String:
	var gen := model_gen + 1
	if not training.is_empty():
		return "Already training"
	if Data.model_cost(gen) > tokens:
		return "Needs %d tokens" % Data.model_cost(gen)
	if Data.model_cost(gen) > Data.storage(level()):
		return "Needs more storage than a %s company has" % Data.STAGES[level()]["name"]
	tokens -= Data.model_cost(gen)
	var seconds := Data.model_time(gen)
	training = {"gen": gen, "left": seconds, "total": seconds}
	return ""


## Marketing costs money, not tokens: returns "$-600" style for the caller to charge.
func advertise(kind: String, money: float) -> String:
	if not Data.CAMPAIGNS.has(kind):
		return "No such campaign"
	if model_gen == 0:
		return "Train a model first: there is nothing to sell yet"
	if not campaign.is_empty():
		return "A campaign is already running"
	var def: Dictionary = Data.CAMPAIGNS[kind]
	if def["price"] > money:
		return "Needs $%d" % def["price"]
	var luck := randf_range(1.0 - def["luck"], 1.0 + def["luck"] * 2.0)
	campaign = {"kind": kind, "left": float(def["time"]), "total": float(def["time"]), "gain": def["reach"] * def["stay"] * luck}
	return "$-%d" % def["price"]


func set_share(value: float) -> String:
	share = clampf(snappedf(value, 0.05), 0.0, 1.0)
	return ""


## Test aid: a company a few hours in, so every part of the menu has something to show.
func demo() -> void:
	earned = 60000.0
	tokens = 90000.0
	model_gen = 2
	users = 5200.0
	share = 0.3
	live = [
		{"id": _id(), "kind": "slop", "what": "recipes", "name": "Recipe site", "size": 0, "peak": 80.0, "hype": 0.5, "age": 300.0,
			"earned": 310.0, "tokens": 900.0, "half_life": 300.0},
		{"id": _id(), "kind": "product", "what": "wrapper", "name": "ChatRipOff", "size": 1, "peak": 320.0, "hype": 0.3, "age": 1560.0,
			"earned": 5200.0, "tokens": 8750.0, "half_life": 900.0},
		{"id": _id(), "kind": "product", "what": "copilot", "name": "CodeSlopper", "size": 0, "peak": 840.0, "hype": 0.9, "age": 200.0,
			"earned": 2600.0, "tokens": 26000.0, "half_life": 1400.0},
	]
	jobs = [{"id": _id(), "kind": "product", "what": "girlfriend", "name": "Waifu Enterprise", "size": 2, "risk": 1,
		"left": 70.0, "total": 165.0, "tokens": 168000.0}]
	training = {"gen": 3, "left": 80.0, "total": 135.0}
	campaign = {"kind": "influencer", "left": 25.0, "total": 40.0, "gain": 2400.0}


# --- internals -----------------------------------------------------------------------------

func _launch(job: Dictionary, events: Array) -> void:
	var def: Dictionary = Data.thing(job["kind"], job["what"])
	var risk: Dictionary = Data.RISKS[job["risk"]]
	var luck := randf_range(risk["low"], risk["high"])
	var peak: float = def["income"] * Data.SIZES[job["size"]]["income"] * Data.model_quality(model_gen) * luck
	live.append({"id": job["id"], "kind": job["kind"], "what": job["what"], "name": job["name"], "size": job["size"],
		"peak": peak, "hype": 1.0, "age": 0.0, "earned": 0.0, "tokens": job["tokens"], "half_life": float(def["half_life"])})
	var verdict := "a hit" if luck > 1.4 else ("a flop" if luck < 0.6 else "live")
	events.append("%s is %s: $%d a minute, for now." % [job["name"], verdict, peak])


func _market(dt: float) -> void:
	_spot_left -= dt
	if _spot_left > 0.0:
		return
	_spot_left = 10.0
	var before := spot
	spot = clampf(spot + randf_range(-0.02, 0.02), Data.SPOT_MIN, Data.SPOT_MAX)
	spot_trend = signi(int(round((spot - before) * 1000.0)))


## Every few minutes something happens to one of the live things.
func _random_event(dt: float, events: Array) -> void:
	_event_left -= dt
	if _event_left > 0.0 or live.is_empty():
		return
	_event_left = randf_range(120.0, 300.0)
	var item: Dictionary = live[randi() % live.size()]
	match randi() % 5:
		0:
			item["peak"] *= 2.5
			events.append("%s went viral for reasons nobody can explain. Income x2.5." % item["name"])
		1:
			item["peak"] *= 0.5
			events.append("A search engine flagged %s as 'unhelpful content'. Income halved." % item["name"])
		2:
			item["age"] = 0.0
			events.append("%s hit the front page of a nerd forum. The hype is back." % item["name"])
		3:
			item["age"] += item["half_life"]
			events.append("A competitor cloned %s over the weekend. Half its hype is gone." % item["name"])
		4:
			var fine: float = minf(item["earned"] * 0.3, 20000.0)
			item["earned"] -= fine
			earned -= fine
			events.append("Lawyers found %s. The settlement cost $%d." % [item["name"], fine])
			events.append("$-%d" % fine)   # special: the caller charges this


func _id() -> int:
	_next_id += 1
	return _next_id - 1


func _model_name(gen: int) -> String:
	return "no model of your own" if gen == 0 else "RipOffLM Gen %d" % gen


## Products get a startup name; slop is just called what it is.
func _name(kind: String, def: Dictionary) -> String:
	if kind == "slop":
		return def["name"]
	var first := ["Rip", "Slop", "Chat", "Hyper", "Deep", "Open", "Meta", "Quantum", "Turbo", "Synergy", "Neuro", "Giga"]
	var second := ["Off", "ify", "ly", "GPT", "Mind", "Forge", "Base", "Flow", "Stack", "Pilot", "Sense", "Labs"]
	return "%s%s (%s)" % [first[randi() % first.size()], second[randi() % second.size()], def["name"].to_lower()]
