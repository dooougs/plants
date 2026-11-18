--!strict
--[[
	Genome: the DNA of a plant.

	A genome is a plain table: { v = version, gen = generation, genes = { [name] = 0..1 } }.
	Every gene is a number from 0 to 1, stored at byte precision so a genome
	round-trips exactly through Genome.encode / Genome.decode (a ~70 character
	string that is safe for DataStore and MessagingService).

	Genes are grouped into linkage groups ("chromosomes"). When two plants are
	spliced, each group is inherited as a block from one parent or blended from
	both, the way linked genes travel together in real plants. That keeps
	hybrids coherent: a hybrid gets a whole flower from one side, or a blend of
	both, rather than a random jumble of petal traits.
]]

local Genome = {}

Genome.VERSION = 1

export type Genes = { [string]: number }
export type Genome = { v: number, gen: number, genes: Genes }

-- Ordered gene list. The order defines the encoding: only ever append.
Genome.GENES = {
	-- Body plan
	"form", -- < 0.3 rosette (leaves at ground, flower on a bare stalk); otherwise upright stem
	"height",
	"stemThickness",
	"stemCurve",
	"nodes", -- number of leaf nodes on the main stem
	"branching",
	"branchAngle",
	"phyllotaxis", -- leaf arrangement: alternate, opposite, or golden-angle spiral
	-- Leaves
	"leafSize",
	"leafLength", -- length to width ratio
	"leafShape", -- where the blade is widest: near the tip (lanceolate) to the base (heart shaped)
	"leafDroop",
	"leafPerNode",
	"leafHue",
	"stemHue",
	-- Buds and flowers
	"budSize",
	"flowerSize",
	"petalCount",
	"petalLength",
	"petalWidth",
	"petalCurl",
	"petalLayers",
	"flowerHue", -- petal base colour
	"flowerHue2", -- petal tip colour (petals are shaded from one to the other)
	"centerHue",
	"flowersPerTip",
	-- Environment preferences (compared with biome parameters)
	"prefTemp",
	"prefMoist",
	"prefLight",
	"tolerance",
	"growthRate",
	-- Rare traits
	"habitat", -- >= HABITAT_THRESHOLD grows a hollow biological chamber players can walk into
	-- Appended later (older genome strings decode these as 0.5)
	"stiffness", -- how much the stem resists wind: 0 floppy and swaying, 1 stiff and quick
	"fire", -- element: 0 a water plant, 1 a fire plant (fed lava), 0.5 a steam plant (both); see Shared.Plants.Element
	"glow", -- >= GLOW_THRESHOLD: a light plant, its flowers are little lamps (brighter the higher it is)
}

-- What a gene is when a genome string is too old to have it (0.5 otherwise).
Genome.DEFAULTS = { fire = 0, glow = 0 } :: { [string]: number }

-- Genes kept at a few fixed values instead of drifting (see finish).
local function snapGene(name: string, value: number): number
	if name == "fire" then
		return if value >= 0.66 then 1 elseif value >= 0.34 then 0.5 else 0
	end
	return value
end

Genome.HABITAT_THRESHOLD = 0.9
-- Light plants: glow at or over this. Rare in the wild (about 1 in 28,
-- see fromSeed); a hybrid takes its glow whole from one parent or the other.
Genome.GLOW_THRESHOLD = 0.8

-- Genes that live on a colour ring and must be blended around the circle.
Genome.HUE_GENES = { flowerHue = true, flowerHue2 = true, centerHue = true }

-- Linkage groups. Every gene must appear in exactly one group. Each group
-- has a stable name (used by Genome.splice's lockGroup option) and a
-- player-facing label.
Genome.LINKAGE = {
	{ name = "body", label = "Body shape", genes = { "form", "height", "stemThickness", "stemCurve", "nodes", "branching", "branchAngle", "stiffness" } },
	{ name = "leafShape", label = "Leaf shape", genes = { "phyllotaxis", "leafSize", "leafLength", "leafShape", "leafDroop", "leafPerNode" } },
	{ name = "leafColour", label = "Leaf colour", genes = { "leafHue", "stemHue" } },
	{ name = "flower", label = "Flower shape", genes = { "budSize", "flowerSize", "petalCount", "petalLength", "petalWidth", "petalCurl", "petalLayers", "flowersPerTip" } },
	{ name = "flowerColour", label = "Flower colour", genes = { "flowerHue", "flowerHue2", "centerHue" } },
	{ name = "climate", label = "Favourite climate", genes = { "prefTemp", "prefMoist", "prefLight", "tolerance", "growthRate" } },
	{ name = "habitat", label = "Habitat", genes = { "habitat" } },
	{ name = "element", label = "Water or fire", genes = { "fire" } },
	{ name = "glow", label = "Glowing flowers", genes = { "glow" } },
}

--[[
	Archetypes give wild plants recognisable body plans. A wild genome is an
	archetype centre plus random variation; genes an archetype leaves out are
	fully random.
]]
Genome.ARCHETYPES = {
	daisy = { form = 0.55, height = 0.3, nodes = 0.35, branching = 0.35, petalCount = 0.95, petalLength = 0.6, petalWidth = 0.15, petalLayers = 0.4, leafShape = 0.3, leafLength = 0.6, stiffness = 0.3 },
	tulip = { form = 0.45, height = 0.35, nodes = 0.05, branching = 0.0, petalCount = 0.45, petalLength = 0.9, petalWidth = 0.9, petalCurl = 0.05, flowerSize = 0.7, leafLength = 0.9, leafShape = 0.2, leafPerNode = 0.0, flowersPerTip = 0.0, stiffness = 0.35 },
	rosette = { form = 0.1, height = 0.45, nodes = 0.9, leafPerNode = 0.0, phyllotaxis = 0.95, leafSize = 0.7, leafDroop = 0.7, flowersPerTip = 0.8, flowerSize = 0.25, stiffness = 0.4 },
	shrub = { form = 0.85, height = 0.55, nodes = 0.75, branching = 0.85, branchAngle = 0.6, leafSize = 0.3, flowerSize = 0.35, flowersPerTip = 0.6, stemThickness = 0.7, stiffness = 0.8 },
	sunflower = { form = 0.7, height = 0.95, nodes = 0.7, branching = 0.05, stemThickness = 0.85, leafSize = 0.85, leafShape = 0.85, flowerSize = 1.0, petalCount = 0.95, petalLayers = 0.8, petalWidth = 0.3, flowersPerTip = 0.0, stiffness = 0.75 },
	bellflower = { form = 0.6, height = 0.5, nodes = 0.55, branching = 0.5, petalCount = 0.35, petalCurl = 0.9, petalLength = 0.7, petalWidth = 0.75, flowersPerTip = 0.9, leafShape = 0.5, stiffness = 0.25 },
}
Genome.ARCHETYPE_ORDER = { "daisy", "tulip", "rosette", "shrub", "sunflower", "bellflower" }

local function quantize(x: number): number
	return math.floor(math.clamp(x, 0, 1) * 255 + 0.5) / 255
end

local function wrap01(x: number): number
	return x - math.floor(x)
end

local function rngFrom(seed: number?): Random
	if seed then
		return Random.new(seed)
	end
	return Random.new()
end

local function blendHue(a: number, b: number, t: number): number
	local d = b - a
	if d > 0.5 then
		d -= 1
	elseif d < -0.5 then
		d += 1
	end
	return wrap01(a + d * t)
end

local function finish(genes: Genes): Genes
	for _, name in Genome.GENES do
		local value = genes[name] or Genome.DEFAULTS[name] or 0.5
		if Genome.HUE_GENES[name] then
			value = wrap01(value)
		end
		genes[name] = quantize(snapGene(name, value))
	end
	return genes
end

-- A deterministic wild genome. Same seed, same plant, on every server.
function Genome.fromSeed(seed: number, archetype: string?): Genome
	local rng = Random.new(seed)
	local kind = archetype or Genome.ARCHETYPE_ORDER[rng:NextInteger(1, #Genome.ARCHETYPE_ORDER)]
	local centre = Genome.ARCHETYPES[kind] or {}
	local genes: Genes = {}
	for _, name in Genome.GENES do
		local roll = rng:NextNumber()
		local c = centre[name]
		if c then
			genes[name] = math.clamp(c + (roll - 0.5) * 0.3, 0, 1)
		else
			genes[name] = roll
		end
	end
	-- Habitat plants are rare in the wild (about 1 in 30); breeding can concentrate the trait.
	genes.habitat = genes.habitat ^ 3
	-- Petals in wild plants mostly sit near one primary colour with a related tip colour.
	genes.flowerHue2 = wrap01(genes.flowerHue + (genes.flowerHue2 - 0.5) * 0.35)
	-- Light plants are rare in the wild: roll^6 is over 0.8 about 1 time in 28.
	genes.glow = genes.glow ^ 6
	-- Wild plants are water plants, except in the Ember biome (Genome.ignite).
	genes.fire = 0
	return { v = Genome.VERSION, gen = 0, genes = finish(genes) }
end

-- Turns a genome into a fire plant, in place: the fire gene on, and a taste
-- for the heat, dry air and glare of the Ember biome (with a little seeded
-- variety). Used for Ember's wild plants and fire seed packets.
function Genome.ignite(g: Genome, seed: number?): Genome
	local rng = rngFrom(seed)
	g.genes.fire = 1
	g.genes.prefTemp = quantize(rng:NextNumber(0.86, 0.96))
	g.genes.prefMoist = quantize(rng:NextNumber(0.08, 0.24))
	g.genes.prefLight = quantize(rng:NextNumber(0.8, 1))
	return g
end

-- Turns a genome into a light plant, in place (glow seed packets and
-- rewards). A little seeded variety in how bright it is.
function Genome.illuminate(g: Genome, seed: number?): Genome
	local rng = rngFrom(seed)
	g.genes.glow = quantize(rng:NextNumber(0.85, 1))
	return g
end

function Genome.random(): Genome
	return Genome.fromSeed(Random.new():NextInteger(1, 2 ^ 30))
end

function Genome.clone(g: Genome): Genome
	return { v = g.v, gen = g.gen, genes = table.clone(g.genes) }
end

local function mutateInPlace(genes: Genes, rng: Random, rate: number, amount: number)
	for _, name in Genome.GENES do
		if rng:NextNumber() < rate then
			genes[name] += rng:NextNumber(-amount, amount)
		end
	end
end

-- Small random mutation, for seeds taken from a single parent.
function Genome.mutate(g: Genome, seed: number?, rate: number?, amount: number?): Genome
	local rng = rngFrom(seed)
	local child = Genome.clone(g)
	mutateInPlace(child.genes, rng, rate or 0.12, amount or 0.08)
	child.genes = finish(child.genes)
	return child
end

-- A seed from one parent: same generation lineage plus a little mutation.
function Genome.fromParent(g: Genome, seed: number?): Genome
	local child = Genome.mutate(g, seed)
	child.gen = g.gen + 1
	return child
end

export type SpliceOptions = {
	-- 0..1 cross quality (e.g. pollination timing). Higher means a lighter
	-- mutation. Leave nil for the default mutation.
	quality: number?,
	-- Inherit this linkage group whole from one parent ("a" or "b").
	lockGroup: { group: string, from: string }?,
}

Genome.DEFAULT_MUTATION_RATE = 0.08
Genome.DEFAULT_MUTATION_AMOUNT = 0.1

-- Mutation rate and amount for a cross of the given quality.
function Genome.mutationFor(quality: number?): (number, number)
	if quality == nil then
		return Genome.DEFAULT_MUTATION_RATE, Genome.DEFAULT_MUTATION_AMOUNT
	end
	local q = math.clamp(quality, 0, 1)
	return Genome.DEFAULT_MUTATION_RATE * (1 - q * 0.8), Genome.DEFAULT_MUTATION_AMOUNT * (1 - q * 0.6)
end

function Genome.findGroup(name: string)
	for _, group in Genome.LINKAGE do
		if group.name == name then
			return group
		end
	end
	return nil
end

--[[
	Splice two plants into a hybrid.
	For each linkage group: 40% inherit from A, 40% from B, 20% blend both
	(the element group: a third each; the glow group never blends, so a
	light plant's glow is passed on whole or not at all).
	A blended group mixes each gene at its own ratio (colours blend around the
	colour ring), so hybrids can land on in-between shapes and colours.
	Then a light mutation pass.

	options.lockGroup takes one group whole from the chosen parent instead of
	rolling; options.quality scales the mutation (see Genome.mutationFor).
	The same seed and options always give the same hybrid.
]]
function Genome.splice(a: Genome, b: Genome, seed: number?, options: SpliceOptions?): Genome
	local rng = rngFrom(seed)
	local lock = options and options.lockGroup
	local genes: Genes = {}
	for _, group in Genome.LINKAGE do
		-- Always draw the roll so a lock does not shift the other groups' rolls.
		local roll = rng:NextNumber()
		if lock and lock.group == group.name then
			roll = if lock.from == "b" then 0.5 else 0
		end
		-- The element group (water or fire) blends more often, a third of the
		-- time, and lands exactly half way: fire x water makes a steam plant.
		local element = group.name == "element"
		local whole = group.name == "glow"
		local fromA = if element then 1 / 3 elseif whole then 0.5 else 0.4
		local fromB = if element then 2 / 3 elseif whole then 1 else 0.8
		for _, name in group.genes do
			local ga, gb = a.genes[name], b.genes[name]
			if roll < fromA then
				genes[name] = ga
			elseif roll < fromB then
				genes[name] = gb
			else
				local t = rng:NextNumber(0.3, 0.7)
				if Genome.HUE_GENES[name] then
					genes[name] = blendHue(ga, gb, t)
				elseif element then
					genes[name] = (ga + gb) / 2
				else
					genes[name] = ga + (gb - ga) * t
				end
			end
		end
	end
	local rate, amount = Genome.mutationFor(options and options.quality)
	mutateInPlace(genes, rng, rate, amount)
	if lock then
		-- A locked group comes through exactly as the parent had it.
		local group = Genome.findGroup(lock.group)
		local source = if lock.from == "b" then b else a
		if group then
			for _, name in group.genes do
				genes[name] = source.genes[name]
			end
		end
	end
	return { v = Genome.VERSION, gen = math.max(a.gen, b.gen) + 1, genes = finish(genes) }
end

local Host = require(script.Parent.Host)

-- Plants.configure({ features = { rooms = false } }) turns every room off.
function Genome.hasHabitat(g: Genome): boolean
	return Host.features.rooms ~= false and g.genes.habitat >= Genome.HABITAT_THRESHOLD
end

-- How brightly a plant's flowers glow: 0 for an ordinary plant, else from
-- 0.35 (just over the threshold) up to 1.
function Genome.glow(g: Genome): number
	local v = g.genes.glow or 0
	if v < Genome.GLOW_THRESHOLD then
		return 0
	end
	return 0.35 + 0.65 * (v - Genome.GLOW_THRESHOLD) / (1 - Genome.GLOW_THRESHOLD)
end

-- Encoding: "<version>.<generation>.<hex bytes>"
function Genome.encode(g: Genome): string
	local parts = table.create(#Genome.GENES)
	for i, name in Genome.GENES do
		parts[i] = string.format("%02x", math.floor(g.genes[name] * 255 + 0.5))
	end
	return string.format("%d.%d.%s", g.v, g.gen, table.concat(parts))
end

function Genome.decode(s: string): Genome?
	local v, gen, hex = string.match(s, "^(%d+)%.(%d+)%.(%x+)$")
	if not v or not gen or not hex then
		return nil
	end
	local genes: Genes = {}
	for i, name in Genome.GENES do
		local byte = string.sub(hex, i * 2 - 1, i * 2)
		-- Genes appended in later versions default to 0.5 when reading older strings.
		genes[name] = if #byte == 2 then (tonumber(byte, 16) :: number) / 255 else (Genome.DEFAULTS[name] or 0.5)
	end
	return { v = Genome.VERSION, gen = tonumber(gen) :: number, genes = genes }
end

-- Stable 31-bit hash of a genome, used to seed per-plant shape variation.
function Genome.hash(g: Genome): number
	local s = Genome.encode(g)
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + string.byte(s, i)) % 2147483647
	end
	return h
end

-- A plant's name is three words: its Plant Index kind (colour and body plan,
-- Shared.Plants.PlantIndex) and a variety name from its other genes, e.g.
-- "Blue Sunflower Amara". Plants of the same kind share the first two words.
-- Fire and steam plants (Shared.Plants.Element) say so first: "Fire Red Tulip Vela",
-- and light plants before that: "Glow Blue Bellflower Lunra".
local ROOTS = { "Ama", "Bel", "Cor", "Dra", "Eli", "Flo", "Gal", "Hel", "Iri", "Lun", "Mira", "Nym", "Ori", "Pet", "Sol", "Vel" }
local ENDS = { "ra", "lia", "nia", "thus", "phila", "sia", "mum", "dra" }

local function pick(list: { string }, x: number): string
	return list[math.clamp(math.floor(x * #list) + 1, 1, #list)]
end

function Genome.describe(g: Genome): { name: string, color: Color3, habitat: boolean, generation: number }
	local Palette = require(script.Parent.Palette)
	local PlantIndex = require(script.Parent.PlantIndex) :: any
	local G = g.genes
	local variety = pick(ROOTS, (G.petalLength or 0.5) * 0.5 + (G.leafSize or 0.5) * 0.5)
		.. pick(ENDS, G.flowerHue2 or 0.5)
	local Element = require(script.Parent.Element) :: any
	local glowWord = if Genome.glow(g) > 0 then "Glow " else ""
	local name = glowWord .. Element.namePrefix(g) .. PlantIndex.kindOf(g).name .. " " .. variety
	return {
		name = name,
		color = Palette.flower(G.flowerHue),
		habitat = Genome.hasHabitat(g),
		generation = g.gen,
	}
end

return Genome
