--!strict
--[[
	Corpus: the example plants the shape grammar learns from.

	Each example is a hand-drawn skeleton in a small axis language:

	  S[ L | L S[L | F] | F ]

	  An axis is a letter and its nodes in brackets, nodes split by "|".
	  Each node lists what grows there; "-" is a bare node.
	    Axes:   S shoot, Z rosette (compressed shoot), I inflorescence
	            (raceme or umbel), R compound leaf (rachis), V trailing shoot
	    Organs: L leaf, F flower, T leaflet

	The grammar (Rules) never copies an example whole. It learns which node
	may follow which, and the plant is grown from those local rules, so new
	plants look like the examples close up without being any one of them.

	Corpus.forGenome picks the examples for a genome: the one for its body
	plan (PlantIndex.bodyOf), plus a donor example when the donor gene is
	away from the middle, which makes hybrid body plans.
]]

local Corpus = {}

export type Axis = { type: string, nodes: { { any } } }
export type Example = { id: string, name: string, src: string, tree: Axis }
export type Entry = { ex: Example, weight: number }

Corpus.EXAMPLES = {
	{ id = "daisy", name = "Daisy stalk", src = "S[ L | L | L | L | L S[L | L | F] | L S[L | F] | F ]" },
	{ id = "tulip", name = "Tulip", src = "S[ L | L | - | - | F ]" },
	{ id = "rosette", name = "Rosette umbel", src = "Z[ L | L | L | L | L | L | L | L S[ - | - | - | I[ F F F F F ] ] ]" },
	{ id = "shrub", name = "Shrub fork", src = "S[ L L | L L S[L | L S[L | F] | F] | L L | L L S[L | L S[L | F] | L | F] | L L S[L | L | F] | L L | F ]" },
	{ id = "sunflower", name = "Sunflower column", src = "S[ L L | L L | L | L | L | L | L | F ]" },
	{ id = "bell", name = "Bell raceme", src = "S[ L | L | L | L | I[ F | F | F | F | F | F ] ]" },
	{ id = "fern", name = "Fern frond", src = "S[ R[T T | T T | T T | T] | R[T T | T T | T T | T T | T] | R[T T | T T | T] | F ]" },
	{ id = "candelabra", name = "Candelabra fork", src = "S[ L L | L L | L L | L L | L L | S[L | L | L S[L | L | F] S[L | L | F]] S[L | L | L S[L | L | F] S[L | L | F]] ]" },
	{ id = "hogweed", name = "Umbel shrub", src = "S[ L | L | L S[L | L | I[F F F F F]] | L S[L | I[F F F F F]] | L | I[F F F F F F] ]" },
	{ id = "vine", name = "Trailing vine", src = "S[ L | L V[L | L F | L | L F | L | F] | L | L V[L | L F | L | L F | F] | F ]" },
	{ id = "spike", name = "Flower spike", src = "S[ L | L | L | I[F F | F F | F F | F F | F F | F F | F F | F] ]" },
	{ id = "lily", name = "Whorled lily", src = "S[ L L L | L L L | L L L | L L L | I[ F | F | F ] ]" },
} :: { any }

-- The example each body plan (PlantIndex.BODIES key) grows from.
Corpus.BODY_EXAMPLE = {
	daisy = "daisy",
	tulip = "tulip",
	rosette = "rosette",
	shrub = "shrub",
	sunflower = "sunflower",
	bellflower = "bell",
} :: { [string]: string }

-- Bumped by Corpus.add, so rules and skeletons learned before it are not reused.
Corpus.revision = 0

-- How much a donor example counts against the plant's own (1).
Corpus.DONOR_WEIGHT = 0.6

local AXES = { S = true, Z = true, R = true, I = true, V = true }
local ORGANS = { L = true, F = true, T = true }

function Corpus.parse(src: string): Axis
	local i = 1
	local function peek(): string
		return string.sub(src, i, i)
	end
	local function ws()
		while peek() == " " do
			i += 1
		end
	end
	local function bracketNext(): boolean
		local j = i + 1
		while string.sub(src, j, j) == " " do
			j += 1
		end
		return string.sub(src, j, j) == "["
	end
	local function axis(): Axis
		ws()
		local kind = peek()
		i += 1
		ws()
		assert(peek() == "[", `Corpus: expected [ at {i} in {src}`)
		i += 1
		local nodes: { { any } } = { {} }
		while true do
			ws()
			local c = peek()
			assert(c ~= "", `Corpus: unclosed axis in {src}`)
			if c == "]" then
				i += 1
				break
			elseif c == "|" then
				i += 1
				table.insert(nodes, {})
			elseif c == "-" then
				i += 1
			elseif AXES[c] and bracketNext() then
				table.insert(nodes[#nodes], axis())
			elseif ORGANS[c] then
				i += 1
				table.insert(nodes[#nodes], c)
			else
				error(`Corpus: unexpected "{c}" at {i} in {src}`)
			end
		end
		return { type = kind, nodes = nodes }
	end
	return axis()
end

Corpus.byId = {} :: { [string]: Example }
for _, ex in Corpus.EXAMPLES do
	ex.tree = Corpus.parse(ex.src)
	Corpus.byId[ex.id] = ex
end

-- Add an example at runtime (a new body plan for a game mode, an event...).
-- Its id can then be used in Corpus.forGenome's override list.
function Corpus.add(id: string, name: string, src: string): Example
	local ex = { id = id, name = name, src = src, tree = Corpus.parse(src) }
	local old = Corpus.byId[id]
	if old then
		local at = table.find(Corpus.EXAMPLES, old)
		if at then
			Corpus.EXAMPLES[at] = ex
		end
	else
		table.insert(Corpus.EXAMPLES, ex)
	end
	Corpus.byId[id] = ex
	Corpus.revision += 1
	return ex
end

-- The donor example for a donor gene value: none from 0.4 to 0.6 (so every
-- genome saved before the gene existed, which reads it as 0.5, has none);
-- below and above, the plant's other examples in turn.
function Corpus.donorFor(primary: string, donor: number): string?
	if donor >= 0.4 and donor <= 0.6 then
		return nil
	end
	local others = {}
	for _, ex in Corpus.EXAMPLES do
		if ex.id ~= primary then
			table.insert(others, ex.id)
		end
	end
	if #others == 0 then
		return nil
	end
	local u = if donor < 0.4 then donor / 0.4 * 0.5 else 0.5 + (donor - 0.6) / 0.4 * 0.5
	return others[math.clamp(math.floor(u * #others) + 1, 1, #others)]
end

--[[
	The examples a genome grows from, and a key naming that choice (for
	caching). override: a list of example ids to use instead (each weight 1),
	for plants a game hands out with a fixed body plan.
]]
function Corpus.forGenome(genes: { [string]: number }, bodyKey: string, override: { string }?): ({ Entry }, string)
	local list: { Entry } = {}
	if override and #override > 0 then
		for _, id in override do
			local ex = Corpus.byId[id]
			assert(ex, `Corpus: no example "{id}"`)
			table.insert(list, { ex = ex, weight = 1 })
		end
	else
		local primary = Corpus.BODY_EXAMPLE[bodyKey] or "daisy"
		table.insert(list, { ex = Corpus.byId[primary], weight = 1 })
		local donor = Corpus.donorFor(primary, genes.donor or 0.5)
		if donor then
			table.insert(list, { ex = Corpus.byId[donor], weight = Corpus.DONOR_WEIGHT })
		end
	end
	local parts = { tostring(Corpus.revision) }
	for _, e in list do
		table.insert(parts, e.ex.id .. "*" .. e.weight)
	end
	return list, table.concat(parts, ",")
end

return Corpus
