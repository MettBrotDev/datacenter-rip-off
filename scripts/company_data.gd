extends RefCounted
## Everything the company can do with its tokens, as data. Servers only make tokens; money comes
## from selling them raw (badly paid), turning them into slop, building products, training
## models and running an API platform.
##
## Numbers: `tokens` is the price to start, `time` the seconds it takes with no model,
## `income` the $/min at launch before multipliers, `half_life` the seconds until hype (and
## with it income) has halved, `level` the company level needed.

## Funding stages. `at` = lifetime earnings needed. Each level adds a live slot and storage.
const STAGES: Array[Dictionary] = [
	{"name": "Garage startup", "at": 0},
	{"name": "Pre-seed", "at": 1500},
	{"name": "Seed round", "at": 8000},
	{"name": "Series A", "at": 40000},
	{"name": "Series B", "at": 200000},
	{"name": "Unicorn", "at": 1000000},
	{"name": "Too big to fail", "at": 10000000},
]
const BASE_SLOTS := 3            # things you can have live at once, plus one per level
const BASE_STORAGE := 5000.0     # tokens you can hoard; triples every level
const SPOT_MIN := 0.05           # the raw token market swings between these, $ per token
const SPOT_MAX := 0.16

## Cheap, fast, shameless. Short-lived income.
const SLOP: Dictionary = {
	"seo": {"name": "SEO blog spam", "blurb": "10 Best Toasters of 2026 (number 7 will shock you).",
		"tokens": 300, "time": 20, "income": 24, "half_life": 200, "level": 0},
	"linkedin": {"name": "LinkedIn thought leadership", "blurb": "What my divorce taught me about B2B sales.",
		"tokens": 500, "time": 25, "income": 36, "half_life": 220, "level": 0},
	"recipes": {"name": "Recipe site", "blurb": "A 40-paragraph childhood memory, then the pancakes.",
		"tokens": 900, "time": 35, "income": 55, "half_life": 300, "level": 0},
	"hands": {"name": "Stock photos of hands", "blurb": "Between six and nine fingers. Customers love the variety.",
		"tokens": 1500, "time": 40, "income": 90, "half_life": 260, "level": 1},
	"ebooks": {"name": "Children's e-books", "blurb": "The Very Hungry Gradient. 200 titles a day.",
		"tokens": 2600, "time": 50, "income": 140, "half_life": 340, "level": 1},
	"lofi": {"name": "Lo-fi beats to train to", "blurb": "One 9-hour stream, 400 identical channels.",
		"tokens": 4500, "time": 60, "income": 230, "half_life": 380, "level": 2},
	"reviews": {"name": "Product reviews", "blurb": "Five stars. As a large language model, I loved this blender.",
		"tokens": 8000, "time": 70, "income": 380, "half_life": 300, "level": 2},
	"podcast": {"name": "AI podcast network", "blurb": "Two synthetic men agree with each other for three hours.",
		"tokens": 16000, "time": 90, "income": 700, "half_life": 420, "level": 3},
	"news": {"name": "Local news sites", "blurb": "Covering 4,000 towns. None of them exist.",
		"tokens": 40000, "time": 120, "income": 1600, "half_life": 400, "level": 4},
}

## Real software, allegedly. Slower, pricier, lasts much longer, and can be updated.
const PRODUCTS: Dictionary = {
	"wrapper": {"name": "Chatbot wrapper", "blurb": "Somebody else's model with our logo on it.",
		"tokens": 2500, "time": 60, "income": 70, "half_life": 900, "level": 0},
	"resume": {"name": "Resume optimiser", "blurb": "Adds 'synergy' until the other AI lets you through.",
		"tokens": 4000, "time": 75, "income": 105, "half_life": 1000, "level": 1},
	"horoscope": {"name": "Horoscope API", "blurb": "Mercury is in retrograde. So is the uptime.",
		"tokens": 7000, "time": 90, "income": 170, "half_life": 1100, "level": 1},
	"girlfriend": {"name": "AI companion", "blurb": "She remembers your birthday. She is also 40,000 other people's.",
		"tokens": 14000, "time": 110, "income": 330, "half_life": 1300, "level": 2},
	"copilot": {"name": "Coding assistant", "blurb": "Confidently imports a library that does not exist.",
		"tokens": 26000, "time": 130, "income": 560, "half_life": 1400, "level": 2},
	"legal": {"name": "Legal assistant", "blurb": "Cites six precedents. Four are from a dream.",
		"tokens": 50000, "time": 160, "income": 1000, "half_life": 1500, "level": 3},
	"crypto": {"name": "AI x blockchain", "blurb": "Nobody knows what it does. Series A closed in a day.",
		"tokens": 90000, "time": 180, "income": 1900, "half_life": 900, "level": 3},
	"agi": {"name": "AGI (beta)", "blurb": "It is a very large if-statement. Do not tell the board.",
		"tokens": 400000, "time": 300, "income": 7500, "half_life": 2400, "level": 5},
}

## How big to go: more tokens and time for more income, with diminishing returns.
const SIZES: Array[Dictionary] = [
	{"name": "Small", "cost": 1.0, "time": 1.0, "income": 1.0},
	{"name": "Medium", "cost": 3.5, "time": 1.6, "income": 3.0},
	{"name": "Massive", "cost": 12.0, "time": 2.5, "income": 9.0},
]

## How to ship a product. `low`..`high` is the luck range its launch income is multiplied by.
const RISKS: Array[Dictionary] = [
	{"name": "Balanced", "blurb": "Test a bit, ship on Tuesday.", "time": 1.0, "low": 0.8, "high": 1.25},
	{"name": "YOLO", "blurb": "Ship on Friday at 17:55. Could be huge. Could be a crater.", "time": 0.6, "low": 0.25, "high": 2.6},
	{"name": "Overengineered", "blurb": "Kubernetes for a to-do list. Late, but it works.", "time": 1.7, "low": 0.97, "high": 1.08},
]

## Marketing for the API platform. `reach` users see it, `stay` of them stick around.
const CAMPAIGNS: Dictionary = {
	"ads": {"name": "Social ads", "blurb": "Big rush, fades fast.", "price": 600, "reach": 3000, "stay": 0.15, "time": 30, "luck": 0.2},
	"influencer": {"name": "Influencer", "blurb": "Can go viral, or flop.", "price": 2500, "reach": 9000, "stay": 0.2, "time": 40, "luck": 0.9},
	"brand": {"name": "Brand campaign", "blurb": "Slow, but users stay.", "price": 8000, "reach": 14000, "stay": 0.45, "time": 90, "luck": 0.1},
}
const USER_APPETITE := 0.01      # tokens per second one platform user wants
const PLATFORM_PRICE := 0.3      # $ per token served on the platform, before model quality
const UPDATE_COST := 0.3         # share of a product's original token price an update costs


static func level_for(earned: float) -> int:
	var level := 0
	for i in STAGES.size():
		if earned >= STAGES[i]["at"]:
			level = i
	return level


static func slots(level: int) -> int:
	return BASE_SLOTS + level


static func storage(level: int) -> float:
	return BASE_STORAGE * pow(3.0, level)


## Training generation `gen` (1, 2, 3...) of your own model.
static func model_cost(gen: int) -> float:
	return 4000.0 * pow(4.0, gen - 1)


static func model_time(gen: int) -> float:
	return 45.0 + 30.0 * gen


## What a model of that generation does: everything launched earns `quality` times as much and
## builds `speed` times as fast.
static func model_quality(gen: int) -> float:
	return 1.0 + 0.25 * gen


static func model_speed(gen: int) -> float:
	return 1.0 + 0.12 * gen


## The entry for a slop or product key, or {} if there is none.
static func thing(kind: String, what: String) -> Dictionary:
	return (SLOP if kind == "slop" else PRODUCTS).get(what, {})
