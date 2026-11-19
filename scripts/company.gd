extends RefCounted
## Models have four stats: smart(ness) 1-5 decides what they can make and
## how good the code they write is; productivity is how much each token earns; speed is how fast
## things get built; reliability is how often the result is not hallucinated nonsense.
## Host-only: the company. Tokens come in from the servers; this decides what they turn into.
## `state()` is what every peer sees (replicated twice a second as world.co); the action
## methods are what players can ask for. Each returns "" on success, a reason it refused, or
## "$123" / "$-123" when the caller has to pay that amount in or out of the bank account.

const Data = preload("res://scripts/company_data.gd")

var tokens := 0.0           # stored, spendable
var earned := 0.0           # lifetime $ made (before costs), decides the funding stage
var spot := 0.1             # $ per raw token right now
var spot_trend := 0
var jobs: Array = []        # being made: {id, kind, what, name, size, risk, left, total, tokens, quality}
var live: Array = []        # earning: {id, kind, what, name, size, peak, hype, age, earned, tokens, half_life}
var owned: Array = ["autocomplete"]   # model keys that are ours for good (bought or trained)
var active := "autocomplete"          # the model in use; if not owned, it is rented by the minute
var own: Dictionary = {}    # models we trained: key ("own1"...) -> the same fields a licensed model has
var stack: Dictionary = {"data": 0, "arch": 0, "optim": 0, "evals": 0, "infra": 0}   # training code, level per component
var coding: Dictionary = {}     # a component being written: {part, level, left, total, fail}
var training: Dictionary = {}   # a model being trained: {plan, left, total}
var users := 0.0            # platform
var share := 0.0            # share of token production reserved for the platform, 0..1
var campaign: Dictionary = {}   # {kind, left, total, gain}
var served := 0.0           # tokens/s going to platform users right now
var income := 0.0           # $ per second coming in, before costs
var costs: Dictionary = {}  # $ per minute going out, by reason
var rate := 0.0             # tokens/s the servers make
var overdue := false        # the account is below zero

var _next_id := 1
var _spot_left := 0.0
var _event_left := 150.0


func level() -> int:
	return Data.level_for(earned)


func state() -> Dictionary:
	var lv := level()
	var next_at: float = Data.STAGES[mini(lv + 1, Data.STAGES.size() - 1)]["at"]
	var m := info(active)
	var total_costs := 0.0
	for reason: String in costs:
		total_costs += costs[reason]
	var models := {}
	for key: String in Data.MODELS:
		models[key] = info(key)
	for key: String in own:
		models[key] = info(key)
	for key: String in models:
		models[key]["owned"] = key in owned
	return {
		"tokens": tokens, "storage": Data.storage(lv), "rate": rate,
		"spot": spot, "spot_trend": spot_trend,
		"level": lv, "stage": Data.STAGES[lv]["name"], "earned": earned, "next_at": next_at,
		"slots": Data.slots(lv),
		"models": models, "active": active, "owned": owned,
		"stack": stack, "coding": coding, "plan": Data.planned_model(stack),
		"model": {"key": active, "name": m["name"], "smart": m["smart"], "productivity": m["productivity"], "speed": m["speed"],
			"reliability": m["reliability"], "only": m.get("only", ""), "rented": active not in owned, "rent": m["rent"]},
		"training": training, "jobs": jobs, "live": live,
		"platform": {"open": m["smart"] >= Data.PLATFORM_TIER, "users": int(users), "share": share, "served": served,
			"want": users * Data.USER_APPETITE, "price": Data.PLATFORM_PRICE * m["productivity"], "campaign": campaign},
		"income": income * 60.0, "costs": costs, "upkeep": total_costs, "net": income * 60.0 - total_costs,
		"overdue": overdue,
	}


## Advances the company. `produced` = tokens/s from the servers, `houses` = how many houses we
## own, `rent_due` = whether we still rent the garage. Returns the change to the bank account.
func tick(dt: float, produced: float, money: float, houses: int, rent_due: bool, events: Array) -> float:
	rate = produced
	var m := info(active)
	var gross := 0.0

	# out of money: the card for the rented model bounces
	if money < 0.0 and not overdue:
		overdue = true
		events.append("The account is below zero. Your landlady has unplugged the internet until you pay up.")
	elif money >= 0.0 and overdue:
		overdue = false
		events.append("Debts paid. The internet is back.")
	if overdue and active not in owned:
		events.append("The payment for %s bounced. Back to %s." % [m["name"], info(_best_owned())["name"]])
		active = _best_owned()
		m = info(active)

	# the platform takes its share of fresh tokens first; the rest goes into storage
	served = 0.0
	if m["smart"] >= Data.PLATFORM_TIER and users > 0.0:
		var wanted: float = users * Data.USER_APPETITE
		served = minf(wanted, produced * share)
		gross += served * Data.PLATFORM_PRICE * m["productivity"] * dt
		if served < wanted * 0.8 and dt > 0.0:   # users who get error pages leave
			users = maxf(0.0, users - users * 0.01 * dt)
	tokens = minf(Data.storage(level()), tokens + (produced - served) * dt)

	# things being built
	for job: Dictionary in jobs.duplicate():
		job["left"] -= dt
		if job["left"] <= 0.0:
			jobs.erase(job)
			_launch(job, events)
	if not coding.is_empty():
		coding["left"] -= dt
		if coding["left"] <= 0.0:
			var part: String = coding["part"]
			var label: String = Data.COMPONENTS[part]["name"].to_lower()
			if randf() < coding["fail"]:
				events.append("The new %s does not run: it imports a library that does not exist. Tokens wasted." % label)
			else:
				stack[part] = coding["level"]
				events.append("The %s is now level %d code." % [label, coding["level"]])
			coding = {}
	if not training.is_empty():
		training["left"] -= dt
		if training["left"] <= 0.0:
			var plan: Dictionary = training["plan"]
			training = {}
			if randf() < plan["fail"]:
				tokens = minf(Data.storage(level()), tokens + plan["tokens"] * 0.5)
				events.append("The training run failed: the loss went to NaN. Half the tokens were salvaged.")
			else:
				var key := "%s%d" % [Data.OWN_PREFIX, own.size() + 1]
				own[key] = {"name": "RipOffLM v%d" % (own.size() + 1), "blurb": "Ours. Trained on everything, licensed from nobody.",
					"smart": plan["smart"], "productivity": plan["productivity"], "speed": plan["speed"], "reliability": plan["reliability"],
					"rent": 0, "price": 0, "own": true}
				owned.append(key)
				active = key
				events.append("%s is trained and in use: smartness %d, productivity x%.2f. No licence fees, ever." % [
					own[key]["name"], plan["smart"], plan["productivity"]])

	# things that are live: income follows hype, hype fades
	for item: Dictionary in live:
		item["age"] += dt
		item["hype"] = pow(0.5, item["age"] / item["half_life"])
		var per_second: float = item["peak"] * item["hype"] / 60.0
		item["earned"] += per_second * dt
		gross += per_second * dt

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
	earned += gross
	if dt > 0.0:
		income = gross / dt
	if level() > before:
		events.append("Funding secured: you are now a %s company. More slots, more storage, new things to build." % Data.STAGES[level()]["name"])

	# what it all costs, $ per minute
	costs = {}
	if rent_due:
		costs["Garage rent"] = Data.GARAGE_RENT
	if houses > 0:
		costs["Property tax"] = Data.PROPERTY_TAX * houses
	if active not in owned:
		costs["%s licence" % m["name"]] = float(m["rent"])
	if income > 0.0:
		costs["Taxes and lawyers"] = income * 60.0 * Data.INCOME_TAX
	var out := 0.0
	for reason: String in costs:
		out += costs[reason]
	return gross - out / 60.0 * dt


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
	return "$%d" % got


func start(kind: String, what: String, size: int, risk: int) -> String:
	var def: Dictionary = Data.thing(kind, what)
	if def.is_empty() or size < 0 or size >= Data.SIZES.size() or risk < 0 or risk >= Data.RISKS.size():
		return "No such thing"
	if kind == "slop":
		risk = 0
	var refusal := Data.can_make(info(active), kind, what)
	if refusal != "":
		return refusal
	if def["level"] > level():
		return "Needs %s" % Data.STAGES[def["level"]]["name"]
	if live.size() + jobs.size() >= Data.slots(level()):
		return "All %d slots are in use" % Data.slots(level())
	var cost: float = def["tokens"] * Data.SIZES[size]["cost"]
	if cost > tokens:
		return "Needs %d tokens" % cost
	tokens -= cost
	var m := info(active)
	var seconds: float = def["time"] * Data.SIZES[size]["time"] * Data.RISKS[risk]["time"] / m["speed"]
	jobs.append({"id": _id(), "kind": kind, "what": what, "name": _name(kind, def), "size": size, "risk": risk,
		"left": seconds, "total": seconds, "tokens": cost, "productivity": m["productivity"], "reliability": m["reliability"]})
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


## Everything about one model, licensed or our own. {} if there is no such model.
func info(key: String) -> Dictionary:
	if own.has(key):
		return own[key].duplicate()
	return Data.licensed(key) if Data.MODELS.has(key) else {}


## Switch to another model. One you do not own is rented by the minute from now on.
func use_model(key: String, money: float) -> String:
	if info(key).is_empty():
		return "No such model"
	if key not in owned and money <= 0.0:
		return "No money, no licence"
	active = key
	return ""


## Buy a model's weights outright. It becomes the model in use.
func buy_model(key: String, money: float) -> String:
	if not Data.MODELS.has(key):
		return "No such model"
	if key in owned:
		return "Already ours"
	var price: float = Data.MODELS[key]["price"]
	if price > money:
		return "Needs $%d" % price
	owned.append(key)
	active = key
	return "$-%d" % price


## Have the model in use write the next level of one training-stack component.
func code(part: String) -> String:
	if not Data.COMPONENTS.has(part):
		return "No such component"
	if not coding.is_empty():
		return "The model is already writing something"
	var m := info(active)
	var next: int = stack[part] + 1
	if next > Data.MAX_CODE:
		return "That is as good as code gets"
	if next > Data.code_cap(m):
		return "%s is not smart enough to write level %d code" % [m["name"], next]
	if Data.code_cost(next) > tokens:
		return "Needs %d tokens" % Data.code_cost(next)
	tokens -= Data.code_cost(next)
	var seconds: float = Data.code_time(next) / m["speed"]
	coding = {"part": part, "level": next, "left": seconds, "total": seconds, "fail": Data.code_fail(m)}
	return ""


## Train a model with the stack as it is now.
func train() -> String:
	var plan := Data.planned_model(stack)
	if not plan["ready"]:
		return "Every part of the training stack has to exist first"
	if not training.is_empty():
		return "Already training"
	if plan["tokens"] > Data.storage(level()):
		return "Needs more token storage than a %s company has" % Data.STAGES[level()]["name"]
	if plan["tokens"] > tokens:
		return "Needs %d tokens" % plan["tokens"]
	tokens -= plan["tokens"]
	training = {"plan": plan, "left": plan["time"], "total": plan["time"]}
	return ""


## Marketing costs money, not tokens.
func advertise(kind: String, money: float) -> String:
	if not Data.CAMPAIGNS.has(kind):
		return "No such campaign"
	if info(active)["smart"] < Data.PLATFORM_TIER:
		return "The platform needs a tier %d model: nobody pays for what you have now" % Data.PLATFORM_TIER
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
	earned = 600000.0
	tokens = 700000.0
	owned = ["autocomplete", "llama", "mistrial"]
	active = "gptish"
	users = 5200.0
	share = 0.3
	live = [
		{"id": _id(), "kind": "slop", "what": "recipes", "name": "Recipe site", "size": 0, "peak": 80.0, "hype": 0.5, "age": 300.0,
			"earned": 310.0, "tokens": 1500.0, "half_life": 300.0},
		{"id": _id(), "kind": "slop", "what": "lofi", "name": "Lo-fi beats to train to", "size": 1, "peak": 6600.0, "hype": 0.8, "age": 120.0,
			"earned": 12400.0, "tokens": 105000.0, "half_life": 380.0},
		{"id": _id(), "kind": "product", "what": "wrapper", "name": "ChatRipOff (chatbot wrapper)", "size": 0, "peak": 7400.0, "hype": 0.3, "age": 1560.0,
			"earned": 152000.0, "tokens": 120000.0, "half_life": 900.0},
	]
	jobs = [{"id": _id(), "kind": "product", "what": "resume", "name": "SynergyPilot (resume optimiser)", "size": 0, "risk": 1,
		"left": 50.0, "total": 84.0, "tokens": 250000.0, "productivity": 1.0, "reliability": 0.8}]
	stack = {"data": 2, "arch": 2, "optim": 1, "evals": 2, "infra": 1}
	coding = {"part": "optim", "level": 2, "left": 35.0, "total": 60.0, "fail": 0.2}
	training = {"plan": Data.planned_model(stack), "left": 130.0, "total": 260.0}
	campaign = {"kind": "influencer", "left": 25.0, "total": 40.0, "gain": 2400.0}


# --- internals -----------------------------------------------------------------------------

func _launch(job: Dictionary, events: Array) -> void:
	var def: Dictionary = Data.thing(job["kind"], job["what"])
	var risk: Dictionary = Data.RISKS[job["risk"]]
	var luck := randf_range(risk["low"], risk["high"])
	var botched: bool = randf() > job["reliability"]
	if botched:
		luck *= 0.5
	var peak: float = def["income"] * Data.SIZES[job["size"]]["income"] * job["productivity"] * luck
	live.append({"id": job["id"], "kind": job["kind"], "what": job["what"], "name": job["name"], "size": job["size"],
		"peak": peak, "hype": 1.0, "age": 0.0, "earned": 0.0, "tokens": job["tokens"], "half_life": float(def["half_life"])})
	var verdict := "a hit" if luck > 1.4 else ("a flop" if luck < 0.6 else "live")
	events.append("%s is %s: $%d a minute, for now.%s" % [job["name"], verdict, peak,
		" Half of it is hallucinated; the model is not reliable enough." if botched else ""])


## The best model we actually own: highest tier, then highest quality.
func _best_owned() -> String:
	var best := "autocomplete"
	for key: String in owned:
		var a := info(key)
		var b := info(best)
		if a["smart"] > b["smart"] or (a["smart"] == b["smart"] and a["productivity"] > b["productivity"]):
			best = key
	return best


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
			var fine: float = minf(item["earned"] * 0.3, item["peak"] * 5.0)
			events.append("Lawyers found %s. The settlement cost $%d." % [item["name"], fine])
			events.append("$-%d" % fine)   # special: the caller charges this


func _id() -> int:
	_next_id += 1
	return _next_id - 1


## Products get a startup name; slop is just called what it is.
func _name(kind: String, def: Dictionary) -> String:
	if kind == "slop":
		return def["name"]
	var first := ["Rip", "Slop", "Chat", "Hyper", "Deep", "Open", "Meta", "Quantum", "Turbo", "Synergy", "Neuro", "Giga"]
	var second := ["Off", "ify", "ly", "GPT", "Mind", "Forge", "Base", "Flow", "Stack", "Pilot", "Sense", "Labs"]
	return "%s%s (%s)" % [first[randi() % first.size()], second[randi() % second.size()], def["name"].to_lower()]
