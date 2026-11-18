--!strict
--[[
	Element: is a plant a water plant, a fire plant or a steam plant?

	Every genome carries a `fire` gene (Shared.Plants.Genome), kept at one of
	three values:

	  0    WATER  ordinary plants. They drink water from the watering can.
	  1    FIRE   plants of the Ember biome. They are fed lava from the stone
	              bowl; water just hisses off them.
	  0.5  STEAM  a fire plant spliced with a water plant (when the splice
	              blends the two instead of taking one side). Steam plants
	              need BOTH, in turns: water, then lava, then water... The
	              same thing twice in a row does nothing. In return they are
	              hardy: happy in hot and cool, wet and dry places alike
	              (Growth.biomeFit), and they puff steam.

	The gene sits in its own linkage group, so a splice or a pollination of
	fire x water gives a fire seed, a water seed or a steam seed, about a
	third each (Genome.splice). Steam x fire or steam x water gives back one
	parent or the other; steam x steam stays steam.

	Feeding is stored per plant in the shared world store: "w" (bonus growth
	seconds, the same field for water and lava) and "fd" (what a steam plant
	was fed last: "w" or "l"), so every server agrees what it wants next.
]]

local Element = {}

Element.WATER = "water"
Element.FIRE = "fire"
Element.STEAM = "steam"

-- Values the gene is kept at (Genome snaps it to the nearest).
Element.GENE = { water = 0, steam = 0.5, fire = 1 }
local STEAM_FROM = 0.34
local FIRE_FROM = 0.66

-- What a plant was fed last, as stored in the world ("fd") and on its
-- anchor (attribute "Fed").
Element.FED_WATER = "w"
Element.FED_LAVA = "l"

-- Steam plants are never less happy than this, wherever they grow.
Element.STEAM_FIT = 0.6

Element.ICON = { water = "💧", fire = "🔥", steam = "♨️" }

-- The gene snapped to its three values.
function Element.snap(fire: number?): number
	local f = fire or 0
	if f >= FIRE_FROM then
		return 1
	elseif f >= STEAM_FROM then
		return 0.5
	end
	return 0
end

-- "water", "fire" or "steam", from a genome or its genes.
function Element.of(genome: any): string
	local genes = if type(genome) == "table" and type(genome.genes) == "table" then genome.genes else genome
	local f = if type(genes) == "table" and type(genes.fire) == "number" then genes.fire else 0
	if f >= FIRE_FROM then
		return Element.FIRE
	elseif f >= STEAM_FROM then
		return Element.STEAM
	end
	return Element.WATER
end

-- 0 (water) .. 1 (fire): how fiery a plant looks.
function Element.heat(genome: any): number
	local kind = Element.of(genome)
	return if kind == Element.FIRE then 1 elseif kind == Element.STEAM then 0.5 else 0
end

-- What the plant takes next: "water", "lava", or "either" (a steam plant
-- that has not been fed yet takes whichever you have).
function Element.wants(genome: any, lastFed: any): string
	local kind = Element.of(genome)
	if kind == Element.FIRE then
		return "lava"
	elseif kind == Element.STEAM then
		if lastFed == Element.FED_WATER then
			return "lava"
		elseif lastFed == Element.FED_LAVA then
			return "water"
		end
		return "either"
	end
	return "water"
end

-- The words on the plant's E prompt.
function Element.actionText(wants: string): string
	if wants == "lava" then
		return "Feed lava"
	elseif wants == "either" then
		return "Water or feed lava"
	end
	return "Water"
end

-- A few words for the plant's label, or nil for an ordinary water plant.
function Element.labelText(genome: any, lastFed: any): string?
	local kind = Element.of(genome)
	if kind == Element.FIRE then
		return "🔥 feed lava"
	elseif kind == Element.STEAM then
		local wants = Element.wants(genome, lastFed)
		if wants == "lava" then
			return "♨️ wants lava next"
		elseif wants == "water" then
			return "♨️ wants water next"
		end
		return "♨️ water and lava in turns"
	end
	return nil
end

-- A word in front of a plant's name: "Fire Red Tulip", "Steam Blue Daisy".
function Element.namePrefix(genome: any): string
	local kind = Element.of(genome)
	return if kind == Element.FIRE then "Fire " elseif kind == Element.STEAM then "Steam " else ""
end

return Element
