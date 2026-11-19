extends RefCounted
## Everything the company can do with its compute, as data. Servers make TOKENS PER SECOND (TPS):
## a live stream that cannot be saved. Each tick it is handed out: serving live products first,
## then the jobs being worked on, then whatever is left is rented out at the spot price. Compute
## nobody uses is wasted (it still burns the watts). What you can make depends on the MODEL in use,
## and good models cost.
##
## The ladder: every step up needs far more compute than the last, and pays more per token.
## Starter machine: ~3.5 tok/s. Pre-seed rack: 10-30. Seed: 30-100. Series A: 100-300.
## Series B: 300-1000. Unicorn: thousands (AI pods). Slop works from a single server; products
## need real infrastructure, both to build and then to keep serving. Money stays tight: rent,
## model fees and taxes never stop.
##
## Numbers: `tokens` is the WORK in tokens a small one takes to build (it progresses by the tokens
## routed to it, so the time is work / tok/s), `serve` the tok/s a live product needs at full hype
## to serve its users, `income` the $/min at launch before multipliers, `half_life` the seconds
## until hype (and with it income) has halved, `smart` the model smartness needed, `level` the
## funding stage needed.

## Funding stages. `at` = lifetime earnings needed. Each level adds a live slot and sweetens the
## rental rate (enterprise contracts: see rent_bonus).
const STAGES: Array[Dictionary] = [
	{"name": "Garage startup", "at": 0},
	{"name": "Pre-seed", "at": 3000},
	{"name": "Seed round", "at": 25000},
	{"name": "Series A", "at": 250000},
	{"name": "Series B", "at": 2000000},
	{"name": "Unicorn", "at": 20000000},
	{"name": "Too big to fail", "at": 200000000},
]
const BASE_SLOTS := 3            # things you can have live or in the works at once, plus one per level
const SPOT_MIN := 0.01           # rented-out compute sells for this much per token, swinging between these.
const SPOT_MAX := 0.03           # A starter machine (3.5 tok/s) earns $2 to $6 a minute that way: pennies.
const RENT_BONUS := 0.25         # each funding stage adds this much to the rental price (x1.25, x1.5 ...)
const RUSH_PRICE := 0.35         # $ per token of work still to do, to finish a job right now (crunch time)
const STARVE_AFTER := 30.0       # seconds below 80% served before users notice and the hype starts to rot
const STARVE_DECAY := 3.0        # then a product ages this much faster per missing share of service

## Running costs, $ per minute. They are why money stays tight.
const GARAGE_RENT := 8.0         # to the landlady, until her house is ours
const PROPERTY_TAX := 15.0       # per house we own
const INCOME_TAX := 0.12         # share of all income that never reaches the account

## Models. Four stats:
##   smart         1-5: what it can make (see the `smart` each slop and product needs) and how good
##                 the training code it writes is
##   productivity  how much each token earns: multiplies the income of everything it launches
##   reliability   0-1: how often a launch or a piece of code is NOT hallucinated nonsense
##   speed         how fast it builds (1 if not given)
## `only: "slop"` means it cannot build products and can barely code.
## `rent` is $ per minute while it is the model in use; `price` buys it for good.
## rent -1 = cannot be rented (open weights: you buy the download or you do not get it).
## price -1 = not for sale at any price (subscription only).
## You always have the first one. Models you train yourself come on top (see COMPONENTS).
const MODELS: Dictionary = {
	# --- smartness 1: slop for beginners ---
	"autocomplete": {"name": "Pie-3 Mini", "blurb": "Fits on a calculator. Thinks like one.",
		"smart": 1, "productivity": 0.7, "reliability": 0.5, "rent": 0, "price": 0},
	"tinystories": {"name": "TinyStoriez 33M", "blurb": "Only writes bedtime stories, but writes them instantly.",
		"smart": 1, "productivity": 0.5, "reliability": 0.9, "speed": 2.0, "rent": -1, "price": 300},
	"bardish": {"name": "Bard-ish (discontinued)", "blurb": "Was confidently wrong on stage once. Never recovered. Still online, somehow.",
		"smart": 1, "productivity": 1.3, "reliability": 0.3, "rent": 2, "price": -1},
	"llama": {"name": "Lama 2 (one L)", "blurb": "Legally distinct. Spits when prompted.",
		"smart": 1, "productivity": 1.0, "reliability": 0.6, "rent": 6, "price": 900},
	# --- smartness 2: industrial slop ---
	"qwerty": {"name": "Qwerty 14B", "blurb": "Open weights from a company you cannot pronounce. Solid. Can actually code a bit.",
		"smart": 2, "productivity": 0.9, "reliability": 0.8, "rent": -1, "price": 12000},
	"mistrial": {"name": "Mistrial 7B", "blurb": "Fluent, confident, wrong in four languages.",
		"smart": 2, "productivity": 1.0, "reliability": 0.7, "rent": 150, "price": 20000, "only": "slop"},
	"slopmaster": {"name": "Grak", "blurb": "Trained on nothing but posts. Has opinions about everything. A slop specialist.",
		"smart": 2, "productivity": 1.5, "reliability": 0.65, "rent": 400, "price": 60000, "only": "slop"},
	"confusion": {"name": "Stable Confusion XL", "blurb": "The slop firehose. Subscription only; they count every finger you generate.",
		"smart": 2, "productivity": 1.9, "reliability": 0.5, "speed": 1.3, "rent": 700, "price": -1, "only": "slop"},
	# --- smartness 3: the first real products ---
	"lama3": {"name": "Lama 3 (two Ls, finally)", "blurb": "Open weights. Capable, a bit dim, and nobody can take it away from you.",
		"smart": 3, "productivity": 0.9, "reliability": 0.7, "rent": -1, "price": 250000},
	"gptish": {"name": "ChadGPT 3.5", "blurb": "The first one that ships something a customer would pay for twice.",
		"smart": 3, "productivity": 1.0, "reliability": 0.8, "rent": 2500, "price": 400000},
	"copirate": {"name": "Copirate", "blurb": "Autocompletes your entire company, quickly. Billed monthly, forever.",
		"smart": 3, "productivity": 0.8, "reliability": 0.9, "speed": 1.6, "rent": 3000, "price": -1},
	# --- smartness 4: serious money ---
	"deepsleep": {"name": "DeepSleep R1", "blurb": "Suspiciously cheap. Thinks out loud for nine minutes, then guesses.",
		"smart": 4, "productivity": 0.9, "reliability": 0.6, "speed": 0.7, "rent": 9000, "price": 1800000},
	"claudette": {"name": "Clod 3 Sonata", "blurb": "Apologises beautifully, then does the job properly.",
		"smart": 4, "productivity": 1.2, "reliability": 0.95, "rent": 25000, "price": 5000000},
	"chad4": {"name": "ChadGPT 4 Turbo", "blurb": "Fast, good, and priced by someone who knows it.",
		"smart": 4, "productivity": 1.1, "reliability": 0.85, "speed": 1.4, "rent": 30000, "price": -1},
	# --- smartness 5: the frontier ---
	"chad5": {"name": "ChadGPT 5 (leaked)", "blurb": "Fell off the back of a datacenter. Brilliant when it is not making things up.",
		"smart": 5, "productivity": 1.3, "reliability": 0.7, "speed": 1.2, "rent": -1, "price": 40000000},
	"geminus": {"name": "Gemineye Ultra", "blurb": "Nobody has read the whole licence. It is 400 pages.",
		"smart": 5, "productivity": 1.4, "reliability": 0.85, "rent": 250000, "price": 60000000},
	"opus": {"name": "Clod 4 Opus Magnum", "blurb": "The best there is. They will never, ever sell you the weights.",
		"smart": 5, "productivity": 1.7, "reliability": 0.97, "rent": 600000, "price": -1},
}

## Your own model starts as code. A model writes it for you, one component at a time, and can
## only write code as good as it is itself (see code_cap). Each component goes from 0 to MAX_CODE.
##   data + arch  decide the SMARTNESS of the model you train     optim + evals  its PRODUCTIVITY
##   evals        also its RELIABILITY     infra  its SPEED, and with evals how often training fails
const COMPONENTS: Dictionary = {
	"data": {"name": "Data pipeline", "blurb": "A scraper that has never heard of robots.txt.", "gives": "smart"},
	"arch": {"name": "Architecture", "blurb": "Attention, mostly. Plus one layer nobody dares to remove.", "gives": "smart"},
	"optim": {"name": "Training loop", "blurb": "The learning rate was found by vibes.", "gives": "productivity"},
	"evals": {"name": "Evals", "blurb": "It answered something. Ship it.", "gives": "productivity, reliability, fewer failed runs"},
	"infra": {"name": "Cluster tooling", "blurb": "A bash script called run_final_v2_REAL.sh.", "gives": "speed, fewer failed runs"},
}
const MAX_CODE := 5
## Work in tokens. Level 1 is two minutes on the starter machine (the first five parts are a
## coffee break); level 2 takes four minutes at 30 tok/s; 3 about ten minutes at 150; 4 twenty
## at 800; 5 half an hour at 4000. Training a model: 15k to 9M, same ladder.
const CODE_COSTS: Array[float] = [0.0, 400.0, 8000.0, 100000.0, 1000000.0, 8000000.0]    # work, by level written
const TRAIN_COSTS: Array[float] = [0.0, 0.0, 15000.0, 100000.0, 1000000.0, 9000000.0]    # work, by tier trained

## Cheap, fast, shameless. Short-lived income.
## `tokens` = work: on the starter machine (3.5 tok/s) the small ones take 35 s to two minutes.
## Slop needs no serving. Incomes are 0.3x the old stockpile numbers: the same $ per token of work.
const SLOP: Dictionary = {
	"seo": {"name": "SEO blog spam", "blurb": "10 Best Toasters of 2026 (number 7 will shock you).",
		"tokens": 120, "income": 6, "half_life": 200, "smart": 1, "level": 0},
	"linkedin": {"name": "LinkedIn thought leadership", "blurb": "What my divorce taught me about B2B sales.",
		"tokens": 210, "income": 11, "half_life": 220, "smart": 1, "level": 0},
	"recipes": {"name": "Recipe site", "blurb": "A 40-paragraph childhood memory, then the pancakes.",
		"tokens": 400, "income": 24, "half_life": 300, "smart": 1, "level": 0},
	"hands": {"name": "Stock photos of hands", "blurb": "Between six and nine fingers. Customers love the variety.",
		"tokens": 1800, "income": 120, "half_life": 260, "smart": 2, "level": 1},
	"ebooks": {"name": "Children's e-books", "blurb": "The Very Hungry Gradient. 200 titles a day.",
		"tokens": 3600, "income": 255, "half_life": 340, "smart": 2, "level": 1},
	"lofi": {"name": "Lo-fi beats to train to", "blurb": "One 9-hour stream, 400 identical channels.",
		"tokens": 9000, "income": 660, "half_life": 380, "smart": 2, "level": 1},
	"reviews": {"name": "Product reviews", "blurb": "Five stars. As a large language model, I loved this blender.",
		"tokens": 18000, "income": 1650, "half_life": 300, "smart": 2, "level": 2},
	"podcast": {"name": "AI podcast network", "blurb": "Two synthetic men agree with each other for three hours.",
		"tokens": 45000, "income": 3600, "half_life": 420, "smart": 2, "level": 2},
}

## Real software, allegedly. Needs a proper model and real infrastructure, and then keeps eating
## compute to serve its users (`serve`, tok/s at full hype, falling as the hype does). Lasts much
## longer than slop. Work is 0.3x and income 0.3x of the old stockpile numbers.
## What a player feels (small, balanced): the wrapper takes 10 minutes at 60 tok/s and needs 12
## tok/s of that fleet kept free afterwards; AGI needs a 10,000 tok/s cluster for an hour.
const PRODUCTS: Dictionary = {
	"wrapper": {"name": "Chatbot wrapper", "blurb": "Somebody else's model with our logo on it.",
		"tokens": 36000, "serve": 12, "income": 2100, "half_life": 900, "smart": 3, "level": 2},
	"resume": {"name": "Resume optimiser", "blurb": "Adds 'synergy' until the other AI lets you through.",
		"tokens": 75000, "serve": 25, "income": 4500, "half_life": 1000, "smart": 3, "level": 3},
	"horoscope": {"name": "Horoscope API", "blurb": "Mercury is in retrograde. So is the uptime.",
		"tokens": 150000, "serve": 50, "income": 9600, "half_life": 1100, "smart": 3, "level": 3},
	"girlfriend": {"name": "AI companion", "blurb": "She remembers your birthday. She is also 40,000 other people's.",
		"tokens": 450000, "serve": 120, "income": 33000, "half_life": 1300, "smart": 4, "level": 4},
	"copilot": {"name": "Coding assistant", "blurb": "Confidently imports a library that does not exist.",
		"tokens": 1200000, "serve": 250, "income": 99000, "half_life": 1400, "smart": 4, "level": 4},
	"legal": {"name": "Legal assistant", "blurb": "Cites six precedents. Four are from a dream.",
		"tokens": 3000000, "serve": 600, "income": 270000, "half_life": 1500, "smart": 4, "level": 5},
	"crypto": {"name": "AI x blockchain", "blurb": "Nobody knows what it does. Series C closed in a day.",
		"tokens": 9000000, "serve": 1500, "income": 1350000, "half_life": 900, "smart": 5, "level": 5},
	"agi": {"name": "AGI (beta)", "blurb": "It is a very large if-statement. Do not tell the board.",
		"tokens": 30000000, "serve": 3000, "income": 3600000, "half_life": 2400, "smart": 5, "level": 6},
}

## How big to go: more work, more serving and more income, with diminishing returns.
const SIZES: Array[Dictionary] = [
	{"name": "Small", "cost": 1.0, "serve": 1.0, "income": 1.0},
	{"name": "Medium", "cost": 3.5, "serve": 2.2, "income": 3.0},
	{"name": "Massive", "cost": 12.0, "serve": 5.0, "income": 9.0},
]

## How to ship a product. `low`..`high` is the luck range its launch income is multiplied by,
## `time` how much of the work it takes (testing is work).
const RISKS: Array[Dictionary] = [
	{"name": "Balanced", "blurb": "Test a bit, ship on Tuesday.", "time": 1.0, "low": 0.8, "high": 1.25},
	{"name": "YOLO", "blurb": "Ship on Friday at 17:55. Could be huge. Could be a crater.", "time": 0.6, "low": 0.25, "high": 2.6},
	{"name": "Overengineered", "blurb": "Kubernetes for a to-do list. Late, but it works.", "time": 1.7, "low": 0.97, "high": 1.08},
]

## Marketing for the API platform. `reach` users see it, `stay` of them stick around.
const CAMPAIGNS: Dictionary = {
	"ads": {"name": "Social ads", "blurb": "Big rush, fades fast.", "price": 6000, "reach": 3000, "stay": 0.15, "time": 30, "luck": 0.2},
	"influencer": {"name": "Influencer", "blurb": "Can go viral, or flop.", "price": 25000, "reach": 9000, "stay": 0.2, "time": 40, "luck": 0.9},
	"brand": {"name": "Brand campaign", "blurb": "Slow, but users stay.", "price": 80000, "reach": 14000, "stay": 0.45, "time": 90, "luck": 0.1},
}
const PLATFORM_TIER := 3         # the model in use must be at least this good to open the platform
const USER_APPETITE := 0.01      # tokens per second one platform user wants. The platform is served first, like any live product
const PLATFORM_PRICE := 0.9      # $ per token served on the platform, before model quality
const UPDATE_COST := 0.3         # share of a product's original work an update takes (a job like any other)
const SERVE_FLOOR := 0.3         # a product's serving demand never falls below this share of its full demand
const OWN_PREFIX := "own"        # model keys "own1", "own2"... are the generations you trained


static func level_for(earned: float) -> int:
	var level := 0
	for i in STAGES.size():
		if earned >= STAGES[i]["at"]:
			level = i
	return level


static func slots(level: int) -> int:
	return BASE_SLOTS + level


## The price of rented-out compute per token: the market price, better every funding stage.
static func rent_bonus(level: int) -> float:
	return 1.0 + RENT_BONUS * level


## Tokens of work a job takes: base size x how big x how carefully it is shipped.
static func work(kind: String, what: String, size: int, risk: int) -> float:
	var def := thing(kind, what)
	return float(def["tokens"]) * SIZES[size]["cost"] * (RISKS[risk]["time"] if kind == "product" else 1.0)


## tok/s a live product wants at full hype (size matters).
static func serve_for(what: String, size: int) -> float:
	return float(PRODUCTS[what]["serve"]) * SIZES[size]["serve"]


## What a model you can license looks like to the rest of the code (own models add to these).
static func licensed(key: String) -> Dictionary:
	var entry: Dictionary = MODELS[key].duplicate()
	entry["speed"] = entry.get("speed", 1.0)
	entry["own"] = false
	return entry


## The highest level of training code this model can write. Slop models can barely code.
static func code_cap(m: Dictionary) -> int:
	return 1 if m.get("only", "") == "slop" else int(m["smart"])


## Odds that what it wrote does not even run. Better models waste fewer tokens.
static func code_fail(m: Dictionary) -> float:
	return clampf((1.0 - m["reliability"]) * 0.6, 0.03, 0.4)


## Tokens of work to write a component up to `level`.
static func code_cost(level: int) -> float:
	return CODE_COSTS[clampi(level, 0, MAX_CODE)]


## The model your training stack would produce right now, and what training it takes.
## `tokens` is the work of the training run. `ready` is false until every component exists. A stack written at level N trains a model
## one step smarter than the code (N + 1), so your own models can write the code for their own successors.
static func planned_model(stack: Dictionary) -> Dictionary:
	var lowest := MAX_CODE
	for part: String in COMPONENTS:
		lowest = mini(lowest, stack.get(part, 0))
	var tier := clampi(1 + mini(stack.get("data", 0), stack.get("arch", 0)), 1, 5)
	var infra: int = stack.get("infra", 0)
	return {
		"ready": lowest >= 1,
		"smart": tier,
		"productivity": 0.8 + 0.12 * (stack.get("optim", 0) + stack.get("evals", 0)),
		"speed": 1.0 + 0.15 * infra,
		"reliability": minf(0.6 + 0.07 * stack.get("evals", 0), 0.97),
		"fail": clampf(0.4 - 0.07 * (stack.get("evals", 0) + infra), 0.03, 0.4),
		"tokens": TRAIN_COSTS[tier] / (1.0 + 0.2 * infra),   # work: good cluster tooling wastes less of it
	}


## Can this model (an entry as in co.models) make this thing? "" if yes, otherwise the reason.
static func can_make(m: Dictionary, kind: String, what: String) -> String:
	var def := thing(kind, what)
	if m.is_empty() or def.is_empty():
		return "No such thing"
	if kind == "product" and m.get("only", "") == "slop":
		return "%s can only make slop" % m["name"]
	if m["smart"] < def["smart"]:
		return "Needs a model of smartness %d (%s is %d)" % [def["smart"], m["name"], m["smart"]]
	return ""


## The entry for a slop or product key, or {} if there is none.
static func thing(kind: String, what: String) -> Dictionary:
	return (SLOP if kind == "slop" else PRODUCTS).get(what, {})
