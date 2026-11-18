--!strict
-- The Plant Index: every kind of plant in the garden, and how rare it is.
--
-- A kind is a body plan (one of Genome.ARCHETYPES: daisy, tulip...) in a
-- flower colour (one of the seven pure colours of Palette.FLOWER_RING), so
-- there are 6 x 7 = 42 kinds, e.g. "Blue Sunflower". Any genome, wild,
-- bred or spliced, belongs to exactly one kind (PlantIndex.kindOf).
--
-- Rarity is the body plan's rank plus the colour's rank (each 0..2), so a
-- kind is Common (0) up to Legendary (4). It is real: wild plants are drawn
-- with the same odds (PlantIndex.wild), so a Legendary Blue Sunflower is
-- about 1 wild plant in 200. Splicing can make any kind.
--
-- Each player's index is saved as inv.plantIndex = { [kind id] = flags }
-- (FOUND: had its seed in your bag; GROWN: one you planted came into
-- flower). Server.Gameplay.IndexService fills it in; the client PlantIndexUI
-- shows it at the Plant Index stand in Bloom School.

local Genome = require(script.Parent.Genome)

local PlantIndex = {}

PlantIndex.FOUND = 1
PlantIndex.GROWN = 2

export type Tier = { key: string, name: string, icon: string, tokens: number }

-- Rarity tiers, by rank. Colours are UI.Theme.rarity[key].
PlantIndex.TIERS = {
	{ key = "common", name = "Common", icon = "●", tokens = 3 },
	{ key = "uncommon", name = "Uncommon", icon = "◆", tokens = 6 },
	{ key = "rare", name = "Rare", icon = "★", tokens = 12 },
	{ key = "epic", name = "Epic", icon = "✦", tokens = 25 },
	{ key = "legendary", name = "Legendary", icon = "👑", tokens = 50 },
} :: { Tier }

export type Body = { key: string, name: string, icon: string, rank: number, weight: number, text: string }
export type Colour = { index: number, name: string, rank: number, weight: number }

-- Body plans, in index order. weight: share of wild plants.
PlantIndex.BODIES = {
	{ key = "daisy", name = "Daisy", icon = "🌼", rank = 0, weight = 30, text = "A ring of thin petals round a sunny middle. Found almost everywhere." },
	{ key = "tulip", name = "Tulip", icon = "🌷", rank = 0, weight = 30, text = "One big cup of a flower on a straight, leafy stem." },
	{ key = "rosette", name = "Rosette", icon = "🍀", rank = 1, weight = 13, text = "A low swirl of leaves with little flowers at every tip." },
	{ key = "bellflower", name = "Bellflower", icon = "🔔", rank = 1, weight = 12, text = "Nodding bells that ring (very quietly) in the wind." },
	{ key = "shrub", name = "Shrub", icon = "🌳", rank = 1, weight = 11, text = "A bushy, branching plant covered in small flowers." },
	{ key = "sunflower", name = "Sunflower", icon = "🌻", rank = 2, weight = 4, text = "A tall, stout giant with one huge flower that watches the sky." },
} :: { Body }

-- Flower colours, in Palette.FLOWER_RING order (index 1..7).
PlantIndex.COLOURS = {
	{ index = 1, name = "Red", rank = 0, weight = 20 },
	{ index = 2, name = "Orange", rank = 1, weight = 13 },
	{ index = 3, name = "Yellow", rank = 0, weight = 20 },
	{ index = 4, name = "White", rank = 0, weight = 20 },
	{ index = 5, name = "Blue", rank = 2, weight = 6 },
	{ index = 6, name = "Violet", rank = 2, weight = 6 },
	{ index = 7, name = "Pink", rank = 1, weight = 13 },
} :: { Colour }

export type Entry = {
	id: string, -- "sunflower:5"
	number: number, -- 1..42, the page in the index
	name: string, -- "Blue Sunflower"
	body: Body,
	colour: Colour,
	rank: number, -- 1..5 into TIERS
	tier: Tier,
	hue: number, -- flowerHue of the pure colour (for drawing)
}

PlantIndex.ENTRIES = {} :: { Entry }
PlantIndex.byId = {} :: { [string]: Entry }

local bodyByKey: { [string]: Body } = {}
for _, body in PlantIndex.BODIES do
	bodyByKey[body.key] = body
	for _, colour in PlantIndex.COLOURS do
		local rank = math.clamp(body.rank + colour.rank, 0, #PlantIndex.TIERS - 1) + 1
		local entry: Entry = {
			id = body.key .. ":" .. colour.index,
			number = #PlantIndex.ENTRIES + 1,
			name = colour.name .. " " .. body.name,
			body = body,
			colour = colour,
			rank = rank,
			tier = PlantIndex.TIERS[rank],
			hue = (colour.index - 1) / #PlantIndex.COLOURS,
		}
		table.insert(PlantIndex.ENTRIES, entry)
		PlantIndex.byId[entry.id] = entry
	end
end

---------------------------------------------------------------------------
-- Which kind a genome is
---------------------------------------------------------------------------

-- The flower colour: the nearest pure colour on the ring (Palette.flower).
function PlantIndex.colourOf(flowerHue: number): Colour
	local n = #PlantIndex.COLOURS
	local i = math.floor((flowerHue - math.floor(flowerHue)) * n + 0.5) % n
	return PlantIndex.COLOURS[i + 1]
end

-- The body plan: the archetype whose centre the genes sit closest to
-- (mean squared distance over the genes that archetype sets).
function PlantIndex.bodyOf(genes: { [string]: number }): Body
	local best, bestD = PlantIndex.BODIES[1], math.huge
	for _, body in PlantIndex.BODIES do
		local centre = Genome.ARCHETYPES[body.key]
		if centre then
			local sum, n = 0, 0
			for gene, c in centre do
				local v = genes[gene]
				if type(v) == "number" then
					sum += (v - c) ^ 2
					n += 1
				end
			end
			local d = if n > 0 then sum / n else math.huge
			if d < bestD then
				best, bestD = body, d
			end
		end
	end
	return best
end

function PlantIndex.kindOf(g: Genome.Genome): Entry
	local body = PlantIndex.bodyOf(g.genes)
	local colour = PlantIndex.colourOf(g.genes.flowerHue or 0)
	return PlantIndex.byId[body.key .. ":" .. colour.index]
end

-- The kind of an encoded genome string, or nil if it doesn't decode.
function PlantIndex.kindOfEncoded(encoded: string?): Entry?
	if type(encoded) ~= "string" then
		return nil
	end
	local ok, g = pcall(Genome.decode, encoded)
	if ok and g then
		return PlantIndex.kindOf(g)
	end
	return nil
end

---------------------------------------------------------------------------
-- Wild plants
---------------------------------------------------------------------------

local function weighted<T>(rng: Random, list: { T }): T
	local total = 0
	for _, item in list do
		total += (item :: any).weight
	end
	local roll = rng:NextNumber() * total
	for _, item in list do
		roll -= (item :: any).weight
		if roll <= 0 then
			return item
		end
	end
	return list[#list]
end

-- The genome of the wild plant grown from `seed`: its body plan and flower
-- colour are drawn with the index odds, so rare kinds are rare. Everything
-- that regrows wild plants from their seed (Server ChunkStreamer, client
-- FarGround stand-ins) uses this, so they agree.
--
-- `biome` is the biome the plant grows wild in: in "Ember" it is a fire
-- plant (Genome.ignite), anywhere else an ordinary water plant.
function PlantIndex.wild(seed: number, biome: string?): Genome.Genome
	local rng = Random.new((seed * 7 + 1013) % 2147483647)
	local body = weighted(rng, PlantIndex.BODIES)
	local colour = weighted(rng, PlantIndex.COLOURS)
	local g = Genome.fromSeed(seed, body.key)
	local n = #PlantIndex.COLOURS
	local hue = ((colour.index - 1) + rng:NextNumber(-0.3, 0.3)) / n
	hue -= math.floor(hue)
	g.genes.flowerHue = math.floor(hue * 255 + 0.5) / 255
	if biome == "Ember" then
		Genome.ignite(g, (seed * 13 + 4177) % 2147483647)
	end
	return g
end

---------------------------------------------------------------------------
-- A player's index (inv.plantIndex)
---------------------------------------------------------------------------

export type Saved = { [string]: number }

function PlantIndex.has(index: Saved?, id: string, flag: number): boolean
	local v = index and index[id]
	return type(v) == "number" and bit32.band(v, flag) ~= 0
end

-- Sets a flag; returns true if it wasn't set before.
function PlantIndex.mark(index: Saved, id: string, flag: number): boolean
	if not PlantIndex.byId[id] or PlantIndex.has(index, id, flag) then
		return false
	end
	index[id] = bit32.bor(index[id] or 0, flag)
	return true
end

-- How many kinds have a flag: total, and per tier rank.
function PlantIndex.count(index: Saved?, flag: number): (number, { number })
	local total, perTier = 0, table.create(#PlantIndex.TIERS, 0)
	for _, entry in PlantIndex.ENTRIES do
		if PlantIndex.has(index, entry.id, flag) then
			total += 1
			perTier[entry.rank] += 1
		end
	end
	return total, perTier
end

function PlantIndex.fromSaved(data: any): Saved
	local out: Saved = {}
	if type(data) == "table" then
		for id, v in data do
			if type(id) == "string" and PlantIndex.byId[id] and type(v) == "number" then
				out[id] = bit32.band(math.floor(v), PlantIndex.FOUND + PlantIndex.GROWN)
			end
		end
	end
	return out
end

return PlantIndex
