--[[
	Growth: how fast a plant grows where it is planted.

	A biome is { temperature, moisture, light, fertility }, each 0..1 (the same
	table the world generator produces per area). A plant has preferred
	temperature, moisture and light plus a tolerance; the closer the biome is to
	what it likes, the faster it grows. Watering adds bonus growth time.

	Progress runs 0..1 through stages:
	  0.00 Seed       a seed on the soil
	  0.04 Seedling   two seed leaves (cotyledons), a tiny shoot
	  0.15 Growing    stem extends node by node, leaves unfurl, expand and droop
	  0.55 Budding    buds form at each tip and swell
	  0.78 Flowering  buds open into flowers
	  1.00 Mature     full bloom
]]

local Element = require(script.Parent.Element)

local Growth = {}

Growth.STAGES = {
	{ name = "Seed", at = 0 },
	{ name = "Seedling", at = 0.04 },
	{ name = "Growing", at = 0.15 },
	{ name = "Budding", at = 0.55 },
	{ name = "Flowering", at = 0.78 },
	{ name = "Mature", at = 1 },
}

-- Progress windows used by the builder.
Growth.VEGETATIVE = { 0.04, 0.58 } -- stem and leaves
Growth.BUD = { 0.55, 0.78 }
Growth.BLOOM = { 0.78, 1.0 }
Growth.HABITAT = { 0.2, 0.7 } -- hollow chamber swells

-- Each watering adds this share of the plant's growing time (before biome
-- fit), so every plant flowers after about the same number of waterings,
-- however rare and slow it is.
Growth.WATER_SHARE = 0.09

-- Ideal growing time to maturity by Plant Index rarity rank (Common ..
-- Legendary), in seconds. Rarer kinds take a little longer, not a slog.
Growth.TIER_SECONDS = { 240, 300, 360, 450, 540 }

export type Biome = { temperature: number, moisture: number, light: number, fertility: number? }

Growth.DEFAULT_BIOME = { temperature = 0.5, moisture = 0.5, light = 0.6, fertility = 0.5 } :: Biome

-- 0..1: how well this genome suits the biome.
function Growth.biomeFit(genome, biome: Biome?): number
	local b = biome or Growth.DEFAULT_BIOME
	local g = genome.genes
	local tol = 0.12 + g.tolerance * 0.33
	local dt = (b.temperature or 0.5) - g.prefTemp
	local dm = (b.moisture or 0.5) - g.prefMoist
	local dl = (b.light or 0.5) - g.prefLight
	local d2 = dt * dt + dm * dm + dl * dl
	local fit = math.exp(-d2 / (2 * tol * tol))
	-- Steam plants (fire spliced with water) are hardy anywhere.
	if Element.of(g) == Element.STEAM then
		fit = math.max(fit, Element.STEAM_FIT)
	end
	return fit
end

-- Rarity lookups are cached per genome table (renderers ask every frame).
local matureCache: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any

-- Seconds of ideal growth to reach maturity. Ordinary plants: 4 to 9
-- minutes by Plant Index rarity, give or take 15% for the growthRate gene.
-- Building plants (habitat) keep 5 to 30 minutes by growthRate.
function Growth.matureSeconds(genome): number
	local g = genome.genes
	if (g.habitat or 0) >= 0.9 then
		return 1800 - g.growthRate * 1500
	end
	local cached = matureCache[genome]
	if cached then
		return cached
	end
	local PlantIndex = require(script.Parent.PlantIndex) :: any
	local base = Growth.TIER_SECONDS[PlantIndex.kindOf(genome).rank] or Growth.TIER_SECONDS[1]
	local seconds = base * (1.15 - 0.3 * (g.growthRate or 0.5))
	matureCache[genome] = seconds
	return seconds
end

-- Growth time one watering adds (stored on the plant as Water seconds).
function Growth.waterSeconds(genome): number
	return Growth.matureSeconds(genome) * Growth.WATER_SHARE
end

-- Growth speed multiplier: 0.4x in a hostile biome up to ~1.8x in a perfect,
-- fertile one (never so slow that a plant seems stuck).
function Growth.speed(genome, biome: Biome?): number
	local b = biome or Growth.DEFAULT_BIOME
	local fit = Growth.biomeFit(genome, b)
	local fertility = b.fertility or 0.5
	return (0.4 + 1.1 * fit) * (0.8 + 0.4 * fertility)
end

-- progress 0..1 from age in seconds and watering bonus seconds.
function Growth.progress(genome, biome: Biome?, ageSeconds: number, waterSeconds: number?): number
	local effective = math.max(0, ageSeconds) * Growth.speed(genome, biome)
		+ (waterSeconds or 0) * (0.75 + 0.25 * Growth.biomeFit(genome, biome))
	return math.clamp(effective / Growth.matureSeconds(genome), 0, 1)
end

---------------------------------------------------------------------------
-- Favourite biome, in words for labels and the planting preview
---------------------------------------------------------------------------

Growth.BIOME_ICONS = {
	Desert = "🏜️",
	Meadow = "🌼",
	Forest = "🌲",
	Wetland = "🐸",
	Tundra = "❄️",
	Jungle = "🌴",
	Ember = "🌋",
}

-- A typical spot in each biome (the middle of its Biomes.classify range);
-- light and fertility come from Biomes.defs.
local BIOME_CLIMATE = {
	{ name = "Meadow", temperature = 0.49, moisture = 0.25 },
	{ name = "Forest", temperature = 0.49, moisture = 0.6 },
	{ name = "Wetland", temperature = 0.49, moisture = 0.85 },
	{ name = "Desert", temperature = 0.74, moisture = 0.28 },
	{ name = "Ember", temperature = 0.9, moisture = 0.17 },
	{ name = "Jungle", temperature = 0.84, moisture = 0.78 },
	{ name = "Tundra", temperature = 0.07, moisture = 0.5 },
}

local Biomes: any = nil
local function biomes(): any
	if Biomes == nil then
		Biomes = require(script.Parent.Host).biomes() or false
	end
	return Biomes
end

-- The biome name of a growing spot (a Biome table), or nil if unknown.
function Growth.biomeName(biome: Biome?): string?
	local B = biomes()
	if not B or not biome then
		return nil
	end
	return B.classify(biome.temperature or 0.5, biome.moisture or 0.5)
end

local favouriteCache: { [any]: string } = setmetatable({}, { __mode = "k" }) :: any

-- The biome this plant grows best in (highest biomeFit at a typical spot).
function Growth.favouriteBiome(genome): string
	local cached = favouriteCache[genome]
	if cached then
		return cached
	end
	local B = biomes()
	local best, bestFit = "Meadow", -1
	for _, c in BIOME_CLIMATE do
		local def = B and B.defs[c.name]
		local fit = Growth.biomeFit(genome, {
			temperature = c.temperature,
			moisture = c.moisture,
			light = if def then def.light else 0.6,
			fertility = if def then def.fertility else 0.5,
		})
		if fit > bestFit then
			best, bestFit = c.name, fit
		end
	end
	favouriteCache[genome] = best
	return best
end

-- "🏜️ Desert"
function Growth.biomeLabel(name: string): string
	return (Growth.BIOME_ICONS[name] or "🌍") .. " " .. name
end

-- "Likes 🏜️ Desert"
function Growth.likesText(genome): string
	return "Likes " .. Growth.biomeLabel(Growth.favouriteBiome(genome))
end

-- How a plant feels about a spot. When it isn't happy it names its
-- favourite biome, unless it is already in it (then it just says so).
function Growth.fitText(genome, biome: Biome?): string
	local fit = Growth.biomeFit(genome, biome)
	if fit > 0.75 then
		return "💚 Loves it here"
	end
	local favourite = Growth.favouriteBiome(genome)
	if fit > 0.4 then
		local here = Growth.biomeName(biome)
		return if here and here ~= favourite then "🙂 Happy here · likes " .. Growth.biomeLabel(favourite) else "🙂 Happy here"
	end
	local inFavourite = Growth.biomeName(biome) == favourite
	if fit > 0.15 then
		return if inFavourite then "🐢 Slow here" else "🐢 Slow here · likes " .. Growth.biomeLabel(favourite)
	end
	return if inFavourite then "🥀 Struggling here" else "🥀 Wants " .. Growth.biomeLabel(favourite)
end

function Growth.stage(progress: number): string
	local name = Growth.STAGES[1].name
	for _, s in Growth.STAGES do
		if progress >= s.at then
			name = s.name
		end
	end
	return name
end

-- Maps progress into a sub-window, returning 0..1.
function Growth.phase(progress: number, window: { number }): number
	return math.clamp((progress - window[1]) / (window[2] - window[1]), 0, 1)
end

return Growth
