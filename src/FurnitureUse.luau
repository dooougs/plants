--!strict
--[[
	FurnitureUse: what you can do with the grown furniture (Shared.Plants.Furniture).

	  open  - acorn chests and leaf parcels hold treasure. What is inside is
	          procedural: it comes from the chest's key and the time it was
	          last emptied, so every server rolls the same treasure without
	          sending it anywhere. Once someone takes it the chest's lid swings
	          shut again a moment later and it stays empty until it refills
	          (REGEN seconds). The only thing kept
	          in the world store is when each chest was last emptied.
	          Honey pots, fruit baskets and seed barrels work the same way
	          (smaller finds, quicker refills).
	          Cupboards and sideboards swing their doors open on their side
	          hinges instead of a lid. They don't always hold something: each
	          refill period rolls whether there is a find inside (lootChance),
	          and when there isn't you just see the cups and plates.
	  light - lanterns, glow jars, wall lamps, fireplaces, hearths and stage
	          footlights switch on and off. Shared by everyone on the server,
	          not saved.
	  sit   - stools, armchairs, beanbags, benches, hammocks, desks (their
	          stool), rugs and moss beds.
	  look  - telescopes: look out of the window through one.
	  read  - bookcases and notice boards: read a line of garden lore or a tip.
	          A bookcase's books sometimes teach you (server: a lesson's class
	          for free, or a push on your homework), once every READ_COOLDOWN.
	  water - water tanks: fill your watering can from the tap.
	  tend  - pot plants and window boxes take a splash from your can (1
	          water); nectar troughs are topped up. Wet soil and perky leaves
	          for WET_SECONDS, shared by everyone on the server, not saved.
	  game  - game tables: a real drafts board (Shared.Plants.Drafts); the
	          prompt starts a new game, moves are made from the stools.
	  fx    - little things to do that only you see: stir the dye vat, sip
	          tea, turn the compost, admire a trophy.

	Each interactive piece gets an invisible FurnitureHandle part (tag
	HANDLE_TAG) when its room is grown, with attributes FurnitureKind,
	FurnitureRoom and FurnitureIndex; the plant model carries PlantId. A
	piece is named by its key "<room>/<index>" within its building (wall lamps
	use index "L1"/"L2"). The building's anchor carries what the server
	shares about its pieces:
	  FurnitureTaken  "<key>=<unix time>;..."  chests/parcels emptied lately
	  FurnitureOff    "<key>;<key>;..."        lights switched off
	  FurnitureWet    "<key>=<unix time>;..."  plants watered lately (tend)
]]

local FurnitureUse = {}

FurnitureUse.HANDLE_TAG = "FurnitureHandle"
FurnitureUse.HANDLE_NAME = "FurnitureHandle"
-- An invisible part standing in for a building's anchor, for furniture that
-- isn't in a plant (a town's benches and lanterns): PlantId, FurnitureReach.
FurnitureUse.ANCHOR_TAG = "FurnitureAnchor"
FurnitureUse.TAKEN_ATTRIBUTE = "FurnitureTaken"
FurnitureUse.OFF_ATTRIBUTE = "FurnitureOff"
FurnitureUse.WET_ATTRIBUTE = "FurnitureWet"

-- tend: how long a watered pot plant stays wet and perky (seconds).
FurnitureUse.WET_SECONDS = 30 * 60
-- read: how often a bookcase can teach you something (seconds, per player).
FurnitureUse.READ_COOLDOWN = 5 * 60
-- read: the chance that a book teaches you something, when it can.
FurnitureUse.READ_CHANCE = 0.35

-- How close (real studs) you must be to use a piece.
FurnitureUse.REACH = 7

export type Kind = {
	action: string, -- "open" | "light" | "sit" | "look" | "read" | "water" | "tend" | "fx"
	object: string, -- the prompt's object text
	text: string?, -- the prompt's action text
	textOff: string?, -- a light's action text while it is off
	regen: number?, -- open: seconds until an emptied chest refills
	glow: { string }?, -- light: glowing parts (dimmed when off)
	flame: { string }?, -- light: flames (hidden when off, their lights too)
	closed: { string }?, -- open: parts shown only while closed
	opened: { string }?, -- open: parts shown only while open
	treasure: { string }?, -- open: parts shown while open with treasure inside
	textEmpty: string?, -- open: the action text while it's empty
	found: string?, -- open: how a find is announced ("🍯 Honey")
	wet: { string }?, -- tend: soil that darkens while wet
	fresh: { string }?, -- tend: leaves and petals that brighten while wet
	fx: string?, -- fx: which little effect (FurnitureClient)
	reach: number?, -- prompt reach in real studs (default REACH)
	hold: number?, -- prompt hold duration (default 0)
	swing: string?, -- open: "lid" (a chest's hinged lid) or "doors" (side-hinged doors); shuts again once emptied
	lootChance: number?, -- open: the chance there's a find inside after each refill (default: always)
}

-- How far a cupboard or sideboard door swings open (about its side hinge).
-- Furniture grows the open doors at this angle; FurnitureClient swings
-- stand-ins between shut and this.
FurnitureUse.DOOR_OPEN_ANGLE = math.rad(100)

FurnitureUse.KINDS = {
	chest = {
		action = "open", object = "Acorn chest", text = "Open", regen = 30 * 60, swing = "lid",
		closed = { "ChestLid", "ChestLatch", "ChestKeyhole" },
		opened = { "ChestLidOpen" },
		treasure = { "ChestGold" },
	},
	-- Doors are named DoorA, DoorB, DoorC (closed) and DoorAOpen... (open);
	-- each door's panel is its first part, hinged on its outer edge (see
	-- Furniture's door builder and its DoorHinge attribute).
	cupboard = {
		action = "open", object = "Cupboard", text = "Open", textEmpty = "Look inside", regen = 20 * 60, swing = "doors", lootChance = 0.5,
		closed = { "DoorA", "DoorB" },
		opened = { "DoorAOpen", "DoorBOpen" },
		treasure = { "CupboardGold" },
	},
	sideboard = {
		action = "open", object = "Sideboard", text = "Open", textEmpty = "Look inside", regen = 20 * 60, swing = "doors", lootChance = 0.5,
		closed = { "DoorA", "DoorB", "DoorC" },
		opened = { "DoorAOpen", "DoorBOpen", "DoorCOpen" },
		treasure = { "CupboardGold" },
	},
	parcels = {
		action = "open", object = "Parcels", text = "Unwrap", regen = 20 * 60,
		closed = { "ParcelTie", "ParcelBow", "ParcelKnot" },
		opened = {},
		treasure = { "ParcelGift" },
	},
	honeycomb = {
		action = "open", object = "Honey pot", text = "Scoop honey", textEmpty = "Empty pot", regen = 15 * 60, found = "🍯 Honey",
		closed = { "CombPotHoney" }, opened = {}, treasure = {},
	},
	basket = {
		action = "open", object = "Fruit basket", text = "Take a snack", textEmpty = "Empty basket", regen = 10 * 60, found = "🍓 Snack",
		closed = { "BasketFruit" }, opened = {}, treasure = {},
	},
	barrel = {
		action = "open", object = "Seed barrel", text = "Rummage", textEmpty = "Rummaged", regen = 20 * 60, found = "🛢️ Rummaged",
		closed = { "BarrelSeed" }, opened = {}, treasure = {},
	},
	lantern = { action = "light", object = "Lantern", text = "Turn off", textOff = "Turn on", glow = { "LanternBulb" } },
	jars = { action = "light", object = "Glow jars", text = "Turn off", textOff = "Turn on", glow = { "JarGlow" } },
	wallLamp = { action = "light", object = "Lamp", text = "Turn off", textOff = "Turn on", glow = { "HabitatLamp" }, reach = 11 },
	fireplace = { action = "light", object = "Fireplace", text = "Put out", textOff = "Light the fire", glow = { "FireJarGlow" }, flame = { "FireFlame" } },
	stove = { action = "light", object = "Hearth", text = "Put out", textOff = "Light the embers", glow = { "StoveEmbers" }, flame = { "StoveFlame" } },
	stage = { action = "light", object = "Footlights", text = "Turn off", textOff = "Turn on", glow = { "StageLight" } },
	stool = { action = "sit", object = "Stool", text = "Sit" },
	armchair = { action = "sit", object = "Armchair", text = "Sit" },
	beanbag = { action = "sit", object = "Beanbag", text = "Flop down" },
	bench = { action = "sit", object = "Bench", text = "Sit" },
	hammock = { action = "sit", object = "Hammock", text = "Climb in" },
	desk = { action = "sit", object = "Desk", text = "Sit" },
	-- only when you're on it, so it doesn't steal the armchair's prompt
	rug = { action = "sit", object = "Rug", text = "Sit down", reach = 5 },
	mossbed = { action = "sit", object = "Moss bed", text = "Curl up" },
	planter = {
		action = "tend", object = "Pot plant", text = "Water",
		wet = { "PlanterSoil" }, fresh = { "PlanterLeaf", "PlanterVein", "PlanterBud", "PlanterShoot" },
	},
	windowBox = {
		action = "tend", object = "Window box", text = "Water",
		wet = { "WindowBoxSoil" }, fresh = { "WindowBoxLeaf", "WindowBoxPetal", "WindowBoxHeart", "WindowBoxStalk" },
	},
	trough = { action = "tend", object = "Nectar trough", text = "Top up", fresh = { "TroughNectar" } },
	gameTable = { action = "game", object = "Drafts", text = "New game", hold = 1 },
	vat = { action = "fx", object = "Dye vat", text = "Stir", fx = "vat" },
	teacup = { action = "fx", object = "Teacup", text = "Sip tea", fx = "tea" },
	compost = { action = "fx", object = "Compost heap", text = "Turn the heap", fx = "compost" },
	plinth = { action = "fx", object = "Trophy", text = "Admire", fx = "admire" },
	telescope = { action = "look", object = "Telescope", text = "Look through" },
	shelf = { action = "read", object = "Bookcase", text = "Read a book" },
	board = { action = "read", object = "Notice board", text = "Read the notes" },
	tank = { action = "water", object = "Water tank", text = "Fill watering can" },
	-- designed pieces (Shared.Plants.FurnitureGrammar)
	dchair = { action = "sit", object = "Chair", text = "Sit" },
	dstool = { action = "sit", object = "Stool", text = "Sit" },
	dbench = { action = "sit", object = "Bench", text = "Sit" },
	dlamp = { action = "light", object = "Lamp", text = "Turn off", textOff = "Turn on", glow = { "LampBulb" } },
	dshelf = { action = "read", object = "Bookcase", text = "Read a book" },
} :: { [string]: Kind }

-- Where you sit on a piece, in its own frame (normal studs, front -Z),
-- from its procedural sizes p (see Furniture.PIECES[kind].params).
FurnitureUse.SEATS = {
	stool = function(p) return Vector3.new(0, p.H + 0.45, 0) end,
	armchair = function(p) return Vector3.new(0, 1.62, -0.2) end,
	beanbag = function(p) return Vector3.new(0, p.D * 0.56, -p.D * 0.1) end,
	bench = function(p) return Vector3.new(0, 1.35, -0.05) end,
	hammock = function(p) return Vector3.new(0, 2.9 - p.sag + 0.15, 0) end,
	-- the desk's own stool, out front, facing the desk (+Z)
	desk = function(p) return CFrame.new(0, p.H - 0.48, -3.4 / 2 + 0.75) * CFrame.Angles(0, math.pi, 0) end,
	rug = function(p) return Vector3.new(0, 0.3, 0) end,
	mossbed = function(p) return Vector3.new(0, 0.75, 0) end,
	-- designed seats: p.seatY is the top of the seat (FurnitureGrammar.params)
	dchair = function(p) return Vector3.new(0, p.seatY + 0.15, -0.1) end,
	dstool = function(p) return Vector3.new(0, p.seatY + 0.2, 0) end,
	dbench = function(p) return Vector3.new(0, p.seatY + 0.15, -0.05) end,
} :: { [string]: (any) -> Vector3 | CFrame }

-- Where a telescope's lens is and which way it looks, in its own frame.
function FurnitureUse.telescopeEye(p: any): CFrame
	local head = Vector3.new(0, 2.7, -0.2)
	local aim = CFrame.new(head) * CFrame.Angles(-p.tilt, 0, 0)
	local from = (aim * CFrame.new(0, 0.25, 1.8)).Position
	local to = (aim * CFrame.new(0, 0.25, 10)).Position
	return CFrame.lookAt(from, to)
end

function FurnitureUse.key(room: number, index: string | number): string
	return `{room}/{index}`
end

-- A stable whole number for a string (djb2).
function FurnitureUse.hash(s: string): number
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 2147483647
	end
	return h
end

-- The world-store entity that remembers a building's emptied chests: an
-- object-less id in the chunk the building stands in, "<cx>,<cz>%f<hash of
-- its PlantId>" (plant ids hold markers like "@" and "#" that other systems
-- look for, so they are hashed). One field per chest.
function FurnitureUse.storeId(cx: number, cz: number, plantId: string): string
	return `{cx},{cz}%f{FurnitureUse.hash(plantId)}`
end

-- "0/3=1731450000;1/2=1731450100" <-> { ["0/3"] = 1731450000, ... }
function FurnitureUse.parseTaken(s: any): { [string]: number }
	local out = {}
	if type(s) == "string" then
		for key, t in string.gmatch(s, "([^=;]+)=(%d+)") do
			out[key] = tonumber(t) :: number
		end
	end
	return out
end

function FurnitureUse.encodeTaken(map: { [string]: number }): string
	local parts = {}
	for key, t in map do
		table.insert(parts, `{key}={math.floor(t)}`)
	end
	table.sort(parts)
	return table.concat(parts, ";")
end

function FurnitureUse.parseOff(s: any): { [string]: boolean }
	local out = {}
	if type(s) == "string" then
		for key in string.gmatch(s, "[^;]+") do
			out[key] = true
		end
	end
	return out
end

function FurnitureUse.encodeOff(set: { [string]: boolean }): string
	local parts = {}
	for key in set do
		table.insert(parts, key)
	end
	table.sort(parts)
	return table.concat(parts, ";")
end

-- Is a chest emptied at `takenAt` still empty at `now` (unix seconds)?
function FurnitureUse.isEmpty(kind: string, takenAt: number?, now: number): boolean
	local spec = FurnitureUse.KINDS[kind]
	local regen = spec and spec.regen or 0
	return takenAt ~= nil and now - takenAt < regen
end

-- Pieces with a lootChance (cupboards, sideboards) don't always hold a
-- find. Whether one is inside is rolled once per refill period, so it is the
-- same on every server and can change after the piece has had time to refill.
function FurnitureUse.hasLoot(kind: string, plantId: string, key: string, now: number, worldSeed: number): boolean
	local spec = FurnitureUse.KINDS[kind]
	local chance = spec and spec.lootChance
	if chance == nil then
		return true
	end
	local period = math.floor(now / math.max(spec.regen or 0, 60))
	local rng = Random.new(FurnitureUse.hash(`{worldSeed}|{plantId}|{key}|p{period}`))
	return rng:NextNumber() < chance
end

export type Treasure = {
	tokens: number,
	water: number,
	seed: number?, -- a wild genome seed (Genome.fromSeed)
}

-- What is in a chest right now: rolled from the building, the chest's key
-- and when it was last emptied (0 if never), so it is the same everywhere
-- and different after every refill.
function FurnitureUse.treasure(kind: string, plantId: string, key: string, takenAt: number, worldSeed: number): Treasure
	local rng = Random.new(FurnitureUse.hash(`{worldSeed}|{plantId}|{key}|{math.floor(takenAt)}`))
	if kind == "honeycomb" then
		return { tokens = rng:NextInteger(1, 4), water = rng:NextInteger(3, 6), seed = nil }
	elseif kind == "basket" then
		return { tokens = rng:NextInteger(1, 3), water = rng:NextInteger(1, 3), seed = nil }
	elseif kind == "barrel" then
		return {
			tokens = rng:NextInteger(1, 3),
			water = 0,
			seed = if rng:NextNumber() < 0.7 then rng:NextInteger(1, 2147483646) else nil,
		}
	end
	if kind == "cupboard" or kind == "sideboard" then
		return {
			tokens = rng:NextInteger(2, 6),
			water = if rng:NextNumber() < 0.25 then rng:NextInteger(2, 5) else 0,
			seed = if rng:NextNumber() < 0.35 then rng:NextInteger(1, 2147483646) else nil,
		}
	end
	if kind == "parcels" then
		return {
			tokens = rng:NextInteger(2, 6),
			water = 0,
			seed = if rng:NextNumber() < 0.5 then rng:NextInteger(1, 2147483646) else nil,
		}
	end
	local tokens = rng:NextInteger(5, 15)
	if rng:NextNumber() < 0.08 then
		tokens += 20 -- a lucky hoard
	end
	return {
		tokens = tokens,
		water = if rng:NextNumber() < 0.3 then rng:NextInteger(5, 10) else 0,
		seed = if rng:NextNumber() < 0.4 then rng:NextInteger(1, 2147483646) else nil,
	}
end

-- Lines found in bookcases and on notice boards.
FurnitureUse.READING = {
	"📖 \"Some say a giant Gardener planted this whole world long ago.\"",
	"📖 \"Plants grow best in the biome they were born for. Check a plant's label for its fit.\"",
	"📖 \"Hand-pollinate two flowers ({pollinate}) and the seed you get is a little of each.\"",
	"📖 \"A watered plant grows faster. Fill your can at any pond, or a water tank's tap.\"",
	"📖 \"Bees are busy, beetles are stubborn, butterflies are dreamers.\"",
	"📖 \"Chests refill on their own. Come back later and there may be more inside.\"",
	"📖 \"Cupboards are mostly cups and plates. Mostly.\"",
	"📖 \"Every room of every building has a purpose, even if that purpose is to look cosy.\"",
	"📖 \"The wind blows the same in every garden at once. Watch the grass to see it.\"",
	"📖 \"The Seed & Plant Market is the place to trade seeds and plants.\"",
	"📖 \"Ladders? Who needs them. Walk into a stem and climb it.\"",
	"📖 \"A garden can grow bigger. Spend tokens: 🌸 Menu → Garden → Grow.\"",
	"📖 \"Bloom School teaches skills: Seed Sense, Watering Wisdom, Gene Splicing and more.\"",
	"📖 \"Furniture grows from seeds too. This bookcase was a sapling once.\"",
	"📖 \"Snails are slow, but they never rush.\"",
	"📖 \"Dragonflies see in every direction at once. Rude, if you ask the beetles.\"",
	"📖 \"If you get lost, every path between plots leads somewhere.\"",
}

return FurnitureUse
