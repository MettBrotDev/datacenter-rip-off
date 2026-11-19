extends RefCounted
## The town's layout, shared by the scenery (outside.gd) and the gameplay (houses).
## Metres, Y up. The garage sits at the origin with its door facing +Z.

const BOUNDS := Rect2(-150, -115, 300, 275)      # playable area: x -150..150, z -115..160
const STREETS_EW: Array[float] = [-66.5, 23.5, 113.5]   # centre z of streets running along X
const STREETS_NS: Array[float] = [-64.0, 62.0]          # centre x of streets running along Z
const STREET_WIDTH := 7.0
const SIDEWALK_WIDTH := 2.0
const HOME := Rect2(-34, -27, 48, 45)            # our own lot: x -34..14, z -27..18 (garage, house, garden)
const PARK := Rect2(-36, 30, 84, 32)             # x -36..48, z 30..62
const LOT_SIZE := Vector2(24, 34)                # a house lot: 24 m along the street, 34 m deep
const CLEAR_SIZE := Vector2(20, 24)              # centred on the house: nothing solid here but the house
const SETBACK := 22.0                            # street centre to house centre
const LOT_PITCH := 28.0

# Our own house, next to the garage. Same building as the neighbours', but already ours.
const HOME_HOUSE := {"id": 0, "pos": Vector3(-14, 0, 1.5), "yaw": 0.0, "size": 1, "name": "Home", "value": 0}

# House footprints (x along the street, z deep) and what the wiring can take, per size class.
const FOOTPRINTS: Array[Vector2] = [Vector2(9, 8), Vector2(11, 9), Vector2(14, 10)]
const CIRCUIT_WATTS: Array[float] = [3600.0, 5000.0, 7500.0]
const BASE_VALUES: Array[int] = [6000, 14000, 30000]
const NAMES: Array[String] = [
	"the Hendersons", "old Gregor", "Mrs. Pataki", "the Okafors", "Dr. Lindqvist", "the Nakamuras", "Uncle Bob",
	"the Petrovs", "Mr. Abernathy", "the Castillos", "Granny Weber", "the O'Briens", "Professor Kim", "the Duboises",
	"Captain Ferro", "the Malhotras", "Mr. Pfeiffer", "the Johanssons", "Aunt Rosalind", "the Kowalskis",
	"Mr. Tanaka", "the Bergstroms", "Sister Agnes", "the Mbekis", "Old Man Jenkins", "the Rossis", "Ms. Vandermeer",
	"the Haddads", "Mr. Zielinski", "the Fitzgeralds", "Madame Leclerc", "the Andersons", "Mr. Oyelaran",
	"the Schmidts", "Mrs. Featherstone", "the Novaks", "Dr. Achterberg", "the Yamamotos", "Mr. Quigley", "the Silvas",
]

static var _lots: Array[Dictionary] = []


## Every neighbour's lot: {"id", "pos" (house centre), "yaw" (0 = front faces +Z, 180 = faces -Z),
## "size" (0 small, 1 medium, 2 large), "name", "value" ($ estimate)}. Ids start at 1; 0 is our own house.
static func lots() -> Array[Dictionary]:
	if not _lots.is_empty():
		return _lots
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261119
	var id := 1
	for street_z: float in STREETS_EW:
		for side: float in [-1.0, 1.0]:   # -1: north of the street, facing south (+Z)
			var x := BOUNDS.position.x + 16.0
			while x <= BOUNDS.end.x - 16.0:
				var pos := Vector3(x, 0, street_z + side * SETBACK)
				x += LOT_PITCH
				if _blocked(pos):
					continue
				var size := rng.randi_range(0, 2)
				var value := int(round(BASE_VALUES[size] * rng.randf_range(0.85, 1.3) / 500.0)) * 500
				_lots.append({"id": id, "pos": pos, "yaw": 0.0 if side < 0.0 else 180.0, "size": size,
					"name": NAMES[(id - 1) % NAMES.size()], "value": value})
				id += 1
	return _lots


## The ground rectangle of a lot (x, z), centred on the house.
static func lot_rect(lot: Dictionary) -> Rect2:
	var p: Vector3 = lot["pos"]
	return Rect2(p.x - LOT_SIZE.x * 0.5, p.z - LOT_SIZE.y * 0.5, LOT_SIZE.x, LOT_SIZE.y)


static func _blocked(pos: Vector3) -> bool:
	for street_x: float in STREETS_NS:
		if absf(pos.x - street_x) < 17.0:
			return true
	var rect := Rect2(pos.x - LOT_SIZE.x * 0.5, pos.z - LOT_SIZE.y * 0.5, LOT_SIZE.x, LOT_SIZE.y)
	return rect.intersects(HOME) or rect.intersects(PARK)
