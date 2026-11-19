extends RefCounted
## Models have four stats: smart(ness) 1-5 decides what they can make and
## how good the code they write is; productivity is how much each token earns; speed is how fast
## things get built; reliability is how often the result is not hallucinated nonsense.
## Host-only: the company. The servers make TOKENS PER SECOND, a live stream that cannot be saved;
## this decides what it turns into. Every tick the stream is handed out in this order:
##   1. serving what is live (products and the API platform), in proportion to what they need
##   2. the jobs (slop, products, updates, writing training code, training): split equally,
##      except one job the players marked as priority, which takes what it can use first
##   3. renting out whatever is left on the spot market (if the switch is on)
## Anything not used, rented or served is WASTED. `state()` is what every peer sees (replicated
## twice a second as world.co); the action methods are what players can ask for. Each returns ""
## on success, a reason it refused, or "$123" / "$-123" when the caller has to pay that amount in
## or out of the bank account.

const Data = preload("res://scripts/company_data.gd")

var earned := 0.0           # lifetime $ made (before costs), decides the funding stage
var spot := 0.02            # $ per token of rented compute right now (before the funding bonus)
var spot_trend := 0
var rent_on := true         # rent out the compute nobody else wants
var priority := 0           # id of the one job that is fed first (0 = nobody)
var jobs: Array = []        # being made: {id, kind, what, name, size, risk, left, total, tokens, rate, eta, ...}; left/total are tokens of WORK
var live: Array = []        # earning: {id, kind, what, name, size, peak, hype, age, earned, tokens, half_life, serve, demand, fed, starved}
var owned: Array = ["autocomplete"]   # model keys that are ours for good (bought or trained)
var active := "autocomplete"          # the model in use; if not owned, it is rented by the minute
var own: Dictionary = {}    # models we trained: key ("own1"...) -> the same fields a licensed model has
var stack: Dictionary = {"data": 0, "arch": 0, "optim": 0, "evals": 0, "infra": 0}   # training code, level per component
var coding: Dictionary = {}     # a component being written: {id, part, level, left, total, fail, rate, eta}
var training: Dictionary = {}   # a model being trained: {id, plan, left, total, rate, eta}
var users := 0.0            # platform
var campaign: Dictionary = {}   # {kind, left, total, gain}
var served := 0.0           # tok/s going to platform users right now
var served_frac := 1.0      # share of what the platform users want that they get
var income := 0.0           # $ per second coming in, before costs
var costs: Dictionary = {}  # $ per minute going out, by reason
var rate := 0.0             # tokens/s the servers make
var flow := {"serving": 0.0, "jobs": 0.0, "rented": 0.0, "wasted": 0.0}   # where this second's tokens went, tok/s
var rent_income := 0.0      # $ per second from rented compute
var overdue := false        # the account is below zero
var test_tps := -1.0        # test aid: >= 0 replaces what the servers make

var _next_id := 1
var _spot_left := 0.0
var _event_left := 150.0


func level() -> int:
	return Data.level_for(earned)


## The price one rented token fetches right now.
func rent_price() -> float:
	return spot * Data.rent_bonus(level())


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
	var f := flow.duplicate()
	f["total"] = rate
	return {
		"rate": rate, "flow": f, "priority": priority,
		"rental": {"on": rent_on, "price": rent_price(), "tps": flow["rented"], "income": rent_income * 60.0},
		"spot": spot, "spot_trend": spot_trend,
		"level": lv, "stage": Data.STAGES[lv]["name"], "earned": earned, "next_at": next_at,
		"slots": Data.slots(lv),
		"models": models, "active": active, "owned": owned,
		"stack": stack, "coding": coding, "plan": Data.planned_model(stack),
		"model": {"key": active, "name": m["name"], "smart": m["smart"], "productivity": m["productivity"], "speed": m["speed"],
			"reliability": m["reliability"], "only": m.get("only", ""), "rented": active not in owned, "rent": m["rent"]},
		"training": training, "jobs": jobs, "live": live,
		"platform": {"open": m["smart"] >= Data.PLATFORM_TIER, "users": int(users), "served": served, "fed": served_frac,
			"want": users * Data.USER_APPETITE, "price": Data.PLATFORM_PRICE * m["productivity"], "campaign": campaign},
		"income": income * 60.0, "costs": costs, "upkeep": total_costs, "net": income * 60.0 - total_costs,
		"overdue": overdue,
	}


## Advances the company. `produced` = tokens/s from the servers, `houses` = how many houses we
## own, `rent_due` = whether we still rent the garage. Returns the change to the bank account.
var water := 0.0   # $ per minute for tap water running through coolant loops; set by the world before tick()

## dt = 0 only refreshes the numbers (who gets how much) without moving time.
func tick(dt: float, produced: float, money: float, houses: int, rent_due: bool, events: Array) -> float:
	rate = produced if test_tps < 0.0 else test_tps
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

	# 1. serving: everything live wants a steady stream; if it is not there, everybody gets the same share
	var want_platform := 0.0
	if m["smart"] >= Data.PLATFORM_TIER and users > 0.0:
		want_platform = users * Data.USER_APPETITE
	var demand := want_platform
	for item: Dictionary in live:
		item["demand"] = float(item["serve"]) * lerpf(Data.SERVE_FLOOR, 1.0, item["hype"]) if float(item["serve"]) > 0.0 else 0.0
		demand += item["demand"]
	var fed := 1.0 if demand <= 0.0 else minf(1.0, rate / demand)
	served = want_platform * fed
	served_frac = fed if want_platform > 0.0 else 1.0
	var avail := rate - demand * fed
	flow["serving"] = demand * fed
	if want_platform > 0.0:
		gross += served * Data.PLATFORM_PRICE * m["productivity"] * dt
		if fed < 0.8 and dt > 0.0:   # users who get error pages leave
			users = maxf(0.0, users - users * 0.01 * dt)

	# 2. the jobs share what is left
	var speed: float = m["speed"]
	var work: Array = jobs.duplicate()
	if not coding.is_empty():
		work.append(coding)
	if not training.is_empty():
		work.append(training)
	var seen := false
	for w: Dictionary in work:
		seen = seen or w["id"] == priority
	if not seen:
		priority = 0
	avail = _route(avail, work, speed, dt if dt > 0.0 else 0.5)
	var routed := 0.0
	for w: Dictionary in work:
		routed += w["route"]
		w["rate"] = w["route"] * speed
		w["eta"] = w["left"] / w["rate"] if w["rate"] > 0.0 else -1.0
		w["left"] -= w["rate"] * dt
	flow["jobs"] = routed

	# 3. rent out the rest, or waste it
	if rent_on:
		flow["rented"] = avail
		flow["wasted"] = 0.0
		rent_income = avail * rent_price()
		gross += rent_income * dt
	else:
		flow["rented"] = 0.0
		flow["wasted"] = avail
		rent_income = 0.0

	# things being built
	for job: Dictionary in jobs.duplicate():
		if job["left"] <= 0.0:
			jobs.erase(job)
			if job["kind"] == "update":
				_refresh(job, events)
			else:
				_launch(job, events)
	if not coding.is_empty() and coding["left"] <= 0.0:
		var part: String = coding["part"]
		var label: String = Data.COMPONENTS[part]["name"].to_lower()
		if randf() < coding["fail"]:
			events.append("The new %s does not run: it imports a library that does not exist. The compute is gone." % label)
		else:
			stack[part] = coding["level"]
			events.append("The %s is now level %d code." % [label, coding["level"]])
		coding = {}
	if not training.is_empty() and training["left"] <= 0.0:
		var plan: Dictionary = training["plan"]
		var run_id: int = training["id"]
		training = {}
		if randf() < plan["fail"]:
			training = {"id": run_id, "plan": plan, "left": plan["tokens"] * 0.5, "total": plan["tokens"], "rate": 0.0, "eta": -1.0}
			events.append("The training run failed: the loss went to NaN. A checkpoint from halfway survived, so it restarts from there.")
		else:
			var key := "%s%d" % [Data.OWN_PREFIX, own.size() + 1]
			own[key] = {"name": "RipOffLM v%d" % (own.size() + 1), "blurb": "Ours. Trained on everything, licensed from nobody.",
				"smart": plan["smart"], "productivity": plan["productivity"], "speed": plan["speed"], "reliability": plan["reliability"],
				"rent": 0, "price": 0, "own": true}
			owned.append(key)
			active = key
			events.append("%s is trained and in use: smartness %d, productivity x%.2f. No licence fees, ever." % [
				own[key]["name"], plan["smart"], plan["productivity"]])

	# things that are live: income follows hype and how well the users are served; hype fades
	for item: Dictionary in live:
		var f := fed if float(item["serve"]) > 0.0 else 1.0
		item["fed"] = f
		if f < 0.8:
			item["starved"] += dt
			if item["starved"] >= Data.STARVE_AFTER and not item["warned"]:
				item["warned"] = true
				events.append("%s keeps showing error pages. Users are posting about it, and the posts are not kind." % item["name"])
		else:
			item["starved"] = maxf(0.0, item["starved"] - dt)
			if item["starved"] <= 0.0:
				item["warned"] = false
		var ageing := 1.0
		if item["starved"] >= Data.STARVE_AFTER:
			ageing += Data.STARVE_DECAY * (1.0 - f)
		item["age"] += dt * ageing
		item["hype"] = pow(0.5, item["age"] / item["half_life"])
		var per_second: float = item["peak"] * item["hype"] / 60.0 * f
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
		events.append("Funding secured: you are now a %s company. More slots, better rental rates, new things to build." % Data.STAGES[level()]["name"])

	# what it all costs, $ per minute
	costs = {}
	if rent_due:
		costs["Garage rent"] = Data.GARAGE_RENT
	if houses > 0:
		costs["Property tax"] = Data.PROPERTY_TAX * houses
	if water > 0.0:
		costs["Water bill"] = water
	if active not in owned:
		costs["%s licence" % m["name"]] = float(m["rent"])
	if income > 0.0:
		costs["Taxes and lawyers"] = income * 60.0 * Data.INCOME_TAX
	var out := 0.0
	for reason: String in costs:
		out += costs[reason]
	return gross - out / 60.0 * dt


# --- what players can ask for -------------------------------------------------------

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
	if slots_used() >= Data.slots(level()):
		return "All %d slots are in use" % Data.slots(level())
	var work: float = Data.work(kind, what, size, risk)
	var m := info(active)
	jobs.append({"id": _id(), "kind": kind, "what": what, "name": _name(kind, def), "size": size, "risk": risk,
		"left": work, "total": work, "tokens": work, "rate": 0.0, "eta": -1.0,
		"productivity": m["productivity"], "reliability": m["reliability"]})
	return ""


## Things that hold a slot: everything live and every job except updates (they are chores on a live thing).
func slots_used() -> int:
	var n := live.size()
	for job: Dictionary in jobs:
		if job["kind"] != "update":
			n += 1
	return n


## Refresh a live product: a job like any other (UPDATE_COST of its original work); when it is done hype is back to full.
func update(id: int, events: Array) -> String:
	for item: Dictionary in live:
		if item["id"] == id:
			if item["kind"] != "product":
				return "Slop cannot be updated, only replaced"
			for job: Dictionary in jobs:
				if job["kind"] == "update" and job["target"] == id:
					return "Already being updated"
			var work: float = item["tokens"] * Data.UPDATE_COST
			jobs.append({"id": _id(), "kind": "update", "what": item["what"], "name": "Update: %s" % item["name"], "size": item["size"], "risk": 0,
				"target": id, "left": work, "total": work, "tokens": work, "rate": 0.0, "eta": -1.0})
			events.append("%s: someone has opened a ticket called 'new gradient on the logo'." % item["name"])
			return ""
	return "No such product"


## Abandon something still being built. Whatever it has been fed is lost: compute does not come back.
func cancel(id: int) -> String:
	for job: Dictionary in jobs:
		if job["id"] == id:
			jobs.erase(job)
			return ""
	return "No such project"


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


## $ to rush a build: what the work still to do costs at crunch-time rates.
static func rush_price(job: Dictionary) -> float:
	return maxf(10.0, ceilf(float(job["left"]) * Data.RUSH_PRICE / 10.0) * 10.0)


## Mark one job (or the code being written, or the training run) as the one that gets fed first. Again to undo.
func prioritize(id: int) -> String:
	if id == priority:
		priority = 0
		return ""
	var found: bool = (not coding.is_empty() and coding["id"] == id) or (not training.is_empty() and training["id"] == id)
	for job: Dictionary in jobs:
		found = found or job["id"] == id
	if not found:
		return "No such project"
	priority = id
	return ""


func set_renting(on: bool) -> String:
	rent_on = on
	return ""


func retire(id: int) -> String:
	for item: Dictionary in live:
		if item["id"] == id:
			live.erase(item)
			for job: Dictionary in jobs.duplicate():
				if job["kind"] == "update" and job["target"] == id:
					jobs.erase(job)
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
	if key not in owned and info(key)["rent"] < 0:
		return "%s cannot be rented: buy the weights or do without" % info(key)["name"]
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
	if price < 0.0:
		return "%s is not for sale: subscription only" % Data.MODELS[key]["name"]
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
	var work := Data.code_cost(next)
	coding = {"id": _id(), "part": part, "level": next, "left": work, "total": work, "fail": Data.code_fail(m), "rate": 0.0, "eta": -1.0}
	return ""


## Train a model with the stack as it is now.
func train() -> String:
	var plan := Data.planned_model(stack)
	if not plan["ready"]:
		return "Every part of the training stack has to exist first"
	if not training.is_empty():
		return "Already training"
	training = {"id": _id(), "plan": plan, "left": plan["tokens"], "total": plan["tokens"], "rate": 0.0, "eta": -1.0}
	return ""


## Marketing costs money, not compute.
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


## Test aid: a company a few hours in, so every part of the menu has something to show.
## `starved` adds a product too big for the servers (the warning states in the menu).
func demo(starved := false) -> void:
	earned = 600000.0
	owned = ["autocomplete", "llama", "mistrial"]
	active = "gptish"
	users = 5200.0
	test_tps = 300.0
	live = [
		_live("slop", "recipes", "Recipe site", 0, 24.0, 0.5, 300.0, 310.0),
		_live("slop", "lofi", "Lo-fi beats to train to", 1, 1980.0, 0.8, 120.0, 12400.0),
		_live("product", "wrapper", "ChatRipOff (chatbot wrapper)", 0, 2200.0, 0.3, 1560.0, 152000.0),
		_live("product", "horoscope", "Astro-Ly (horoscope api)", 0, 9600.0, 0.7, 330.0, 41000.0),
	]
	if starved:
		live.append(_live("product", "copilot", "TurboPilot (coding assistant)", 1, 99000.0, 0.9, 140.0, 80000.0))
	jobs = [{"id": _id(), "kind": "product", "what": "resume", "name": "SynergyPilot (resume optimiser)", "size": 0, "risk": 1,
		"left": 30000.0, "total": 45000.0, "tokens": 45000.0, "rate": 0.0, "eta": -1.0, "productivity": 1.0, "reliability": 0.8}]
	stack = {"data": 2, "arch": 2, "optim": 1, "evals": 2, "infra": 1}
	coding = {"id": _id(), "part": "optim", "level": 2, "left": 5000.0, "total": 8000.0, "fail": 0.2, "rate": 0.0, "eta": -1.0}
	var plan := Data.planned_model(stack)
	training = {"id": _id(), "plan": plan, "left": plan["tokens"] * 0.55, "total": plan["tokens"], "rate": 0.0, "eta": -1.0}
	priority = training["id"] if starved else 0
	campaign = {"kind": "influencer", "left": 25.0, "total": 40.0, "gain": 2400.0}


# --- internals -----------------------------------------------------------------------------

## Hand `avail` tok/s to the jobs in `work`: the priority job first (as much as it can use), the
## rest equally, nobody gets more than it can use in one tick. Sets w["route"]. Returns what is left.
func _route(avail: float, work: Array, speed: float, dt: float) -> float:
	var open: Array = []
	for w: Dictionary in work:
		w["route"] = 0.0
		w["cap"] = maxf(w["left"], 0.0) / (speed * dt)    # tok/s it can still use
		if w["id"] == priority:
			w["route"] = minf(avail, w["cap"])
			avail -= w["route"]
		else:
			open.append(w)
	open.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["cap"] < b["cap"])
	var n := open.size()
	for w: Dictionary in open:
		var give := minf(avail / n, w["cap"])
		w["route"] = give
		avail -= give
		n -= 1
	for w: Dictionary in work:
		w.erase("cap")
	return avail


func _live(kind: String, what: String, name: String, size: int, peak: float, hype: float, age: float, made: float) -> Dictionary:
	var def: Dictionary = Data.thing(kind, what)
	var half: float = def["half_life"]
	return {"id": _id(), "kind": kind, "what": what, "name": name, "size": size, "peak": peak, "hype": hype, "age": half * log(1.0 / hype) / log(2.0),
		"earned": made, "tokens": Data.work(kind, what, size, 0), "half_life": float(half),
		"serve": Data.serve_for(what, size) if kind == "product" else 0.0, "demand": 0.0, "fed": 1.0, "starved": 0.0, "warned": false}


func _launch(job: Dictionary, events: Array) -> void:
	var def: Dictionary = Data.thing(job["kind"], job["what"])
	var risk: Dictionary = Data.RISKS[job["risk"]]
	var luck := randf_range(risk["low"], risk["high"])
	var botched: bool = randf() > job["reliability"]
	if botched:
		luck *= 0.5
	var peak: float = def["income"] * Data.SIZES[job["size"]]["income"] * job["productivity"] * luck
	live.append({"id": job["id"], "kind": job["kind"], "what": job["what"], "name": job["name"], "size": job["size"],
		"peak": peak, "hype": 1.0, "age": 0.0, "earned": 0.0, "tokens": job["tokens"], "half_life": float(def["half_life"]),
		"serve": Data.serve_for(job["what"], job["size"]) if job["kind"] == "product" else 0.0,
		"demand": 0.0, "fed": 1.0, "starved": 0.0, "warned": false})
	var verdict := "a hit" if luck > 1.4 else ("a flop" if luck < 0.6 else "live")
	var need := ""
	if job["kind"] == "product":
		need = " It needs about %.0f tok/s to serve its users." % Data.serve_for(job["what"], job["size"])
	events.append("%s is %s: $%d a minute, for now.%s%s" % [job["name"], verdict, peak, need,
		" Half of it is hallucinated; the model is not reliable enough." if botched else ""])


## An update job is done: the product is as exciting as the day it launched, minus a little.
func _refresh(job: Dictionary, events: Array) -> void:
	for item: Dictionary in live:
		if item["id"] == job["target"]:
			item["age"] = 0.0
			item["hype"] = 1.0
			item["starved"] = 0.0
			item["peak"] *= 0.92   # every update excites people a little less
			events.append("%s 2.0 is out. Same thing, new gradient on the logo." % item["name"])


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
	spot = clampf(spot + randf_range(-0.004, 0.004), Data.SPOT_MIN, Data.SPOT_MAX)
	spot_trend = signi(int(round((spot - before) * 10000.0)))


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
