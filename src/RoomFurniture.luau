--[[
	RoomFurniture: rooms you have arranged yourself.

	Every room of a house plant grows its own furniture (Shared.Plants.Furniture
	lays it out for the room's purpose). The owner can rearrange it: pick a
	piece up and put it down somewhere else, turn it, dig it up into a
	furniture seed, or plant a furniture seed (bought in the Seed & Plant
	Market's 🌱 Seeds tab, or dug up) to grow a new piece.

	The first change to a room turns it from grown into arranged: the whole
	layout it grew is written down as a list of pieces, and from then on the
	room grows exactly that list. Changing an arranged room's purpose (My
	Home) keeps its furniture.

	Stored on the home's plant object (WorldStore), one field per room:
	  fu<n> = "<piece>;<piece>;..."  (absent: the room grows its own layout)
	and mirrored onto the anchor as attribute RoomFurniture<n> for clients.
	A piece is "id:x:z:a:s:seed:key":
	  id    the piece kind (Furniture.PIECES)
	  x, z  where it stands on the room floor, tenths of a normal stud (+x out
	        through the door, the stem at 0,0; see RoomPlanner)
	  a     which way its front faces, whole degrees (0 = +x)
	  s     its size, hundredths (100 = as grown)
	  seed  (base 36) rolls its sizes and details (Furniture.wantFor), so a piece looks
	        the same wherever it goes
	  key   its name in the building (FurnitureUse keys "<room>/<key>"): a
	        grown piece keeps its layout number, new ones are "c1", "c2"...

	A usual room is a few hundred bytes, so a change fits one
	MessagingService message between servers (Config.MESSAGE_BYTES); a very
	full room may not, and then other servers read it from the DataStore
	instead (WorldSync). MAX_BYTES is a hard cap.

	Furniture seeds you hold are counts by kind in your inventory
	(inv.furniture), outside the seed bag.

	Plain Lua with light types, shared by server and client.
]]

local RoomFurniture = {}

RoomFurniture.FIELD_PREFIX = "fu"
RoomFurniture.ATTRIBUTE_PREFIX = "RoomFurniture"
RoomFurniture.MAX_ROOMS = 5 -- Homes.MAX_ROOMS
RoomFurniture.MAX_PIECES = 30
RoomFurniture.MAX_BYTES = 1200
RoomFurniture.MAX_HELD = 99 -- furniture seeds of one kind you can hold
RoomFurniture.BOUND = 40 -- no piece further than this (normal studs) from the stem
RoomFurniture.SCALE_MIN = 0.5
RoomFurniture.SCALE_MAX = 1.3
RoomFurniture.SEED_MAX = 9999999
RoomFurniture.TURN = 45 -- degrees per turn in the decorate tools

export type Piece = { id: string, x: number, z: number, a: number, s: number, seed: number, key: string }

-- Every piece kind: its name and icon (for the bag, the market and the
-- decorate tools), and its price in tokens if the market sells its seed.
-- Pieces that hold finds (chests, cupboards, sideboards, parcels, honey,
-- baskets, barrels) and water tanks aren't sold: you only get those by
-- moving what your home grew.
RoomFurniture.KINDS = {
	bed = { name = "Seed-pod Bed", icon = "🛏️", price = 30 },
	bunk = { name = "Bunk Bed", icon = "🛏️", price = 40 },
	stool = { name = "Mushroom Stool", icon = "🍄", price = 8 },
	table = { name = "Lily-pad Table", icon = "🍽️", price = 20 },
	roundTable = { name = "Round Table", icon = "🍽️", price = 30 },
	shelf = { name = "Bookcase", icon = "📚", price = 25 },
	chest = { name = "Acorn Chest", icon = "🌰" },
	cupboard = { name = "Leaf Cupboard", icon = "🚪" },
	sideboard = { name = "Sideboard", icon = "🗄️" },
	rug = { name = "Petal Rug", icon = "🌸", price = 10 },
	beanbag = { name = "Fluff Beanbag", icon = "☁️", price = 15 },
	armchair = { name = "Petal Armchair", icon = "🪑", price = 20 },
	jars = { name = "Glow Jars", icon = "🫙", price = 12 },
	planter = { name = "Pot Plant", icon = "🪴", price = 8 },
	windowBox = { name = "Window Box", icon = "🌼", price = 12 },
	lantern = { name = "Firefly Lantern", icon = "🏮", price = 10 },
	hammock = { name = "Leaf Hammock", icon = "🍃", price = 30 },
	parcels = { name = "Leaf Parcels", icon = "📦" },
	honeycomb = { name = "Honey Dresser", icon = "🍯" },
	stove = { name = "Pebble Hearth", icon = "🍲", price = 40 },
	teacup = { name = "Teacup Table", icon = "☕", price = 20 },
	mossbed = { name = "Moss Bed", icon = "🌿", price = 15 },
	trough = { name = "Nectar Trough", icon = "🪵", price = 15 },
	telescope = { name = "Telescope", icon = "🔭", price = 40 },
	desk = { name = "Writing Desk", icon = "✏️", price = 25 },
	board = { name = "Notice Board", icon = "📋", price = 15 },
	tank = { name = "Water Tank", icon = "🚰" },
	barrel = { name = "Seed Barrel", icon = "🛢️" },
	basket = { name = "Fruit Basket", icon = "🧺" },
	compost = { name = "Compost Crate", icon = "🪱", price = 10 },
	vat = { name = "Dye Vat", icon = "🎨", price = 20 },
	stage = { name = "Little Stage", icon = "🎭", price = 50 },
	bench = { name = "Log Bench", icon = "🪵", price = 15 },
	plinth = { name = "Trophy Plinth", icon = "🏆", price = 20 },
	gameTable = { name = "Game Table", icon = "♟️", price = 40 },
	fireplace = { name = "Pebble Fireplace", icon = "🔥", price = 45 },
}

-- What the market sells, cheapest first.
RoomFurniture.SHOP = {} :: { string }
for id, k in RoomFurniture.KINDS do
	if k.price then
		table.insert(RoomFurniture.SHOP, id)
	end
end
table.sort(RoomFurniture.SHOP, function(a, b)
	local pa, pb = RoomFurniture.KINDS[a].price, RoomFurniture.KINDS[b].price
	if pa ~= pb then
		return pa < pb
	end
	return a < b
end)

function RoomFurniture.isKind(id: any): boolean
	return type(id) == "string" and RoomFurniture.KINDS[id] ~= nil
end

function RoomFurniture.name(id: string): string
	local k = RoomFurniture.KINDS[id]
	return if k then k.name else id
end

function RoomFurniture.icon(id: string): string
	local k = RoomFurniture.KINDS[id]
	return if k then k.icon else "🪑"
end

function RoomFurniture.field(room: number): string
	return RoomFurniture.FIELD_PREFIX .. tostring(room)
end

function RoomFurniture.attribute(room: number): string
	return RoomFurniture.ATTRIBUTE_PREFIX .. tostring(room)
end

---------------------------------------------------------------- encoding

local function round(x: number): number
	return math.floor(x + 0.5)
end

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local function base36(n: number): string
	local out = ""
	repeat
		local d = n % 36
		out = string.sub(DIGITS, d + 1, d + 1) .. out
		n = (n - d) // 36
	until n == 0
	return out
end

local function validKey(key: any): boolean
	return type(key) == "string" and #key >= 1 and #key <= 6 and string.match(key, "^[%w]+$") ~= nil
end
RoomFurniture.validKey = validKey

-- Snaps a piece to what its encoding keeps, and clamps it in range.
function RoomFurniture.clean(p: Piece): Piece
	local b = RoomFurniture.BOUND
	return {
		id = p.id,
		x = math.clamp(round(p.x * 10), -b * 10, b * 10) / 10,
		z = math.clamp(round(p.z * 10), -b * 10, b * 10) / 10,
		a = round(p.a) % 360,
		s = math.clamp(round(p.s * 100), round(RoomFurniture.SCALE_MIN * 100), round(RoomFurniture.SCALE_MAX * 100)) / 100,
		seed = math.clamp(round(p.seed), 1, RoomFurniture.SEED_MAX),
		key = p.key,
	}
end

function RoomFurniture.encode(pieces: { Piece }): string
	local out = table.create(#pieces)
	for i, p in pieces do
		local c = RoomFurniture.clean(p)
		out[i] = string.format("%s:%d:%d:%d:%d:%s:%s", c.id, round(c.x * 10), round(c.z * 10), c.a, round(c.s * 100), base36(c.seed), c.key)
	end
	return table.concat(out, ";")
end

-- Reads a stored room. Bad entries are dropped; nil if `s` isn't a room
-- that was arranged (so the room grows its own layout).
function RoomFurniture.decode(s: any): { Piece }?
	if type(s) ~= "string" then
		return nil
	end
	local out = {}
	local seen = {}
	for entry in string.gmatch(s, "[^;]+") do
		local id, x, z, a, sc, seed, key = string.match(entry, "^(%w+):(%-?%d+):(%-?%d+):(%d+):(%d+):(%w+):(%w+)$")
		if id and RoomFurniture.isKind(id) and validKey(key) and not seen[key] and #out < RoomFurniture.MAX_PIECES then
			seen[key] = true
			table.insert(out, RoomFurniture.clean({
				id = id,
				x = (tonumber(x) :: number) / 10,
				z = (tonumber(z) :: number) / 10,
				a = tonumber(a) :: number,
				s = (tonumber(sc) :: number) / 100,
				seed = tonumber(seed, 36) or 1,
				key = key,
			}))
		end
	end
	-- Old generated layouts saved the drafts stools as separate numbered
	-- pieces immediately after their table, with a seed derived from it.
	local stoolSeedsByTable = {}
	for _, p in out do
		local index = tonumber(p.key)
		if p.id == "gameTable" and index then
			stoolSeedsByTable[index] = Random.new(p.seed):NextInteger(1, RoomFurniture.SEED_MAX)
		end
	end
	for i = #out, 1, -1 do
		local p = out[i]
		local index = tonumber(p.key)
		if p.id == "stool" and index and (stoolSeedsByTable[index - 1] == p.seed or stoolSeedsByTable[index - 2] == p.seed) then
			table.remove(out, i)
		end
	end
	return out
end

-- The arranged rooms of a building, from its anchor's attributes (or any
-- getter): { [room] = pieces }, or nil when none were arranged.
function RoomFurniture.fromAttributes(get: (string) -> any): { [number]: { Piece } }?
	local out: { [number]: { Piece } }? = nil
	for n = 0, RoomFurniture.MAX_ROOMS - 1 do
		local pieces = RoomFurniture.decode(get(RoomFurniture.attribute(n)))
		if pieces then
			out = out or {}
			;(out :: any)[n] = pieces
		end
	end
	return out
end

-- One string for every arranged room (PlantRenderer's rebuild key).
function RoomFurniture.signature(get: (string) -> any): string
	local parts = {}
	for n = 0, RoomFurniture.MAX_ROOMS - 1 do
		local v = get(RoomFurniture.attribute(n))
		if type(v) == "string" then
			table.insert(parts, tostring(n) .. "#" .. v)
		end
	end
	return table.concat(parts, "/")
end

-- The next free "c<n>" key in a room.
function RoomFurniture.newKey(pieces: { Piece }): string
	local top = 0
	for _, p in pieces do
		local n = tonumber(string.match(p.key, "^c(%d+)$"))
		if n and n > top then
			top = n
		end
	end
	return "c" .. tostring(top + 1)
end

function RoomFurniture.find(pieces: { Piece }, key: string): (Piece?, number?)
	for i, p in pieces do
		if p.key == key then
			return p, i
		end
	end
	return nil, nil
end

-- A piece's facing as a unit floor vector.
function RoomFurniture.look(a: number): (number, number)
	local r = math.rad(a)
	return math.cos(r), math.sin(r)
end

function RoomFurniture.angleOf(lx: number, lz: number): number
	return round(math.deg(math.atan2(lz, lx))) % 360
end

---------------------------------------------------------------- held seeds

-- inv.furniture: kind -> how many furniture seeds you hold.
function RoomFurniture.held(inv: any, id: string): number
	local f = type(inv) == "table" and inv.furniture
	local n = type(f) == "table" and f[id]
	return if type(n) == "number" then n else 0
end

function RoomFurniture.give(inv: any, id: string, n: number?): boolean
	if not RoomFurniture.isKind(id) then
		return false
	end
	inv.furniture = inv.furniture or {}
	local have = RoomFurniture.held(inv, id)
	local add = n or 1
	if have + add > RoomFurniture.MAX_HELD then
		return false
	end
	inv.furniture[id] = have + add
	return true
end

function RoomFurniture.take(inv: any, id: string): boolean
	local have = RoomFurniture.held(inv, id)
	if have < 1 then
		return false
	end
	inv.furniture[id] = if have > 1 then have - 1 else nil
	return true
end

-- Saved inventories: keep known kinds with sensible counts.
function RoomFurniture.readHeld(data: any): { [string]: number }
	local out = {}
	if type(data) == "table" then
		for id, n in data do
			if RoomFurniture.isKind(id) and type(n) == "number" and n >= 1 then
				out[id] = math.min(math.floor(n), RoomFurniture.MAX_HELD)
			end
		end
	end
	return out
end

return RoomFurniture
