--!strict
--[[
	PlantSynth: plants grown from a shape grammar learned from example
	skeletons (after Merrell, "Example-Based Procedural Modeling Using Graph
	Grammars", 2023), as an alternative to PlantBuilder's fixed body plan.

	The classic builder grows one main stem with leaves at each node and
	one level of side branches. The grammar can also grow compound fronds,
	whorls, racemes and spikes, umbels on side shoots, forks that fork again,
	trailing vines, and hybrids of any two of those (the donor gene).

	  Corpus   the example skeletons, and which ones a genome grows from
	  Rules    the grammar learned from them (vertex stars in context)
	  Derive   the adult skeleton, derived once per genome
	  Layout   where everything is at a growth progress (no parts)
	  Organs   leaf and petal outlines for the close-up build

	PlantBuilder uses it when configured:

	  Plants.configure({ features = { generator = "synth", organs = true } })

	generator = "synth" grows plants from the grammar (building plants with
	rooms keep the classic stem); organs = true gives every leaf and petal
	its own outline at detail 3, with either generator. Both are off by
	default, so plants look exactly as before until a game turns them on.

	Per build, options.synth = true / false overrides the generator, and
	options.examples = { "fern", "lily" } grows a plant from those examples
	instead of its body plan's (see Corpus.EXAMPLES for the ids).
]]

local Genome = require(script.Parent.Genome)
local PlantIndex = require(script.Parent.PlantIndex)
local Corpus = require(script.Corpus)
local Rules = require(script.Rules)
local Derive = require(script.Derive)
local Layout = require(script.Layout)
local Organs = require(script.Organs)

local PlantSynth = {}

PlantSynth.Corpus = Corpus
PlantSynth.Rules = Rules
PlantSynth.Derive = Derive
PlantSynth.Layout = Layout
PlantSynth.Organs = Organs

-- Derived skeletons, kept per genome (and example choice). A plant is
-- derived once and rebuilt from the same skeleton at every growth stage
-- and detail level.
local graphs: { [string]: Derive.Graph } = {}
local order: { string } = {}
local KEEP = 128

--[[
	The adult skeleton of a genome. seed defaults to Genome.hash, as
	PlantBuilder's does. examples: optional example ids to grow from instead
	of the body plan's. Returns the graph and the examples' key.
]]
function PlantSynth.graph(genome: Genome.Genome, seed: number?, examples: { string }?): (Derive.Graph, string)
	local g = genome.genes
	local s = seed or Genome.hash(genome)
	local list, corpusKey = Corpus.forGenome(g, PlantIndex.bodyOf(g).key, examples)
	local key = Genome.encode(genome) .. "|" .. s .. "|" .. corpusKey
	local G = graphs[key]
	if not G then
		G = Derive.derive(g, s, Rules.forCorpus(list, corpusKey))
		graphs[key] = G
		table.insert(order, key)
		if #order > KEEP then
			graphs[table.remove(order, 1) :: string] = nil
		end
	end
	return G, corpusKey
end

-- Where every stem piece, leaf and flower is at this progress (see Layout).
function PlantSynth.layout(genome: Genome.Genome, progress: number, seed: number?, examples: { string }?): Layout.Result
	local G = PlantSynth.graph(genome, seed, examples)
	return Layout.layout(G, genome.genes, progress)
end

--[[
	Plants the classic builder can't make, to show what the grammar adds:
	each a genome (a wild one of an archetype, with some genes set) and the
	examples it grows from. Build them with options.synth = true and
	options.examples = item.examples.
]]
PlantSynth.SHOWCASE = {
	{ id = "fern", name = "Frond plant", examples = { "fern" }, archetype = "shrub", seed = 11, genes = { height = 0.45, nodes = 0.35, leafSize = 0.75, leafLength = 0.55, leafDroop = 0.6, leafHue = 0.45, stemHue = 0.1, flowerSize = 0.3, branching = 0.3, flowerHue = 0.5, stemCurve = 0.3 } },
	{ id = "lily", name = "Whorl lily", examples = { "lily" }, archetype = "tulip", seed = 21, genes = { height = 0.6, nodes = 0.45, phyllotaxis = 0.95, leafPerNode = 0.9, leafSize = 0.45, leafLength = 0.85, petalCount = 0.5, flowerHue = 0.0, flowerHue2 = 0.1, flowersPerTip = 0.6, petalCurl = 0.4 } },
	{ id = "candelabra", name = "Candelabra", examples = { "candelabra" }, archetype = "shrub", seed = 31, genes = { height = 0.55, nodes = 0.35, branching = 0.8, branchAngle = 0.6, phyllotaxis = 0.5, leafSize = 0.35, flowerSize = 0.45, flowerHue = 0.62, flowerHue2 = 0.72, stemHue = 0.85, stemCurve = 0.2 } },
	{ id = "hogweed", name = "Umbel shrub", examples = { "hogweed" }, archetype = "bellflower", seed = 41, genes = { height = 0.7, nodes = 0.45, branching = 0.7, flowerSize = 0.3, flowersPerTip = 0.9, flowerHue = 0.43, flowerHue2 = 0.45, centerHue = 0.3, petalCount = 0.4, petalCurl = 0.2, leafSize = 0.6 } },
	{ id = "vine", name = "Trailing vine", examples = { "vine" }, archetype = "bellflower", seed = 51, genes = { height = 0.6, nodes = 0.6, branching = 0.75, leafSize = 0.35, flowerSize = 0.35, petalCurl = 0.85, flowerHue = 0.8, flowerHue2 = 0.88, stemCurve = 0.5 } },
	{ id = "spike", name = "Flower spike", examples = { "spike" }, archetype = "bellflower", seed = 61, genes = { height = 0.65, nodes = 0.2, leafSize = 0.7, leafLength = 0.8, flowerSize = 0.3, flowersPerTip = 0.6, petalCurl = 0.3, flowerHue = 0.95, flowerHue2 = 0.0, petalCount = 0.6 } },
	{ id = "fernLily", name = "Fern × lily", examples = { "fern", "lily" }, archetype = "tulip", seed = 71, genes = { height = 0.6, nodes = 0.5, phyllotaxis = 0.95, leafPerNode = 0.9, leafSize = 0.6, leafLength = 0.6, flowerHue = 0.06, flowersPerTip = 0.6, stemHue = 0.1 } },
	{ id = "candelabraUmbel", name = "Candelabra × umbel", examples = { "candelabra", "hogweed" }, archetype = "shrub", seed = 101, genes = { height = 0.6, nodes = 0.45, branching = 0.8, branchAngle = 0.6, phyllotaxis = 0.5, leafSize = 0.45, flowerSize = 0.3, flowersPerTip = 0.9, flowerHue = 0.47, flowerHue2 = 0.5, centerHue = 0.25, petalCount = 0.4, petalCurl = 0.2, stemHue = 0.6 } },
}

-- The showcase plants as { id, name, genome, examples }.
function PlantSynth.showcase(): { { id: string, name: string, genome: Genome.Genome, examples: { string } } }
	local out = {}
	for _, item in PlantSynth.SHOWCASE do
		local g = Genome.fromSeed(item.seed * 7919 + 3, item.archetype)
		for name, v in item.genes do
			g.genes[name] = v
		end
		g.genes.donor = 0.5
		-- Round the set genes the way a saved genome stores them.
		g = Genome.decode(Genome.encode(g)) :: Genome.Genome
		table.insert(out, { id = item.id, name = item.name, genome = g, examples = item.examples })
	end
	return out
end

-- A short description of what a plant grows from, for debugging and UI.
function PlantSynth.describe(genome: Genome.Genome, examples: { string }?): string
	local g = genome.genes
	local list = Corpus.forGenome(g, PlantIndex.bodyOf(g).key, examples)
	local names = {}
	for _, e in list do
		table.insert(names, e.ex.name)
	end
	return table.concat(names, " × ")
end

return PlantSynth
