--[[
	Palette: the art style in one place.

	Bright, basic primary colours, given depth by shading rather than by muddy
	colours: every part is coloured along a gradient (darker and richer at the
	base, lighter at the tip), shadows are pushed toward a deeper saturated
	version of the colour instead of grey, and materials carry the surface
	texture. Tweak this file to restyle every plant at once.
]]

local Palette = {}

-- Colour ring for petals. Gene values snap toward these pure colours; hybrids
-- that blend two parents land on the in-between colours.
Palette.FLOWER_RING = {
	Color3.fromRGB(235, 35, 45), -- red
	Color3.fromRGB(255, 135, 0), -- orange
	Color3.fromRGB(255, 215, 0), -- yellow
	Color3.fromRGB(250, 250, 245), -- white
	Color3.fromRGB(25, 95, 235), -- blue
	Color3.fromRGB(125, 50, 215), -- violet
	Color3.fromRGB(240, 60, 165), -- magenta
}

-- Foliage runs along a line (not a ring), mostly greens with rare blue and purple leaves.
Palette.LEAF_LINE = {
	Color3.fromRGB(155, 215, 30), -- yellow green
	Color3.fromRGB(50, 185, 60), -- green
	Color3.fromRGB(30, 150, 75), -- deep green
	Color3.fromRGB(20, 140, 140), -- teal
	Color3.fromRGB(40, 90, 190), -- blue
	Color3.fromRGB(120, 45, 140), -- purple
}

Palette.STEM_RED = Color3.fromRGB(160, 35, 55)
Palette.SEPAL = Color3.fromRGB(45, 150, 55)
Palette.SEED = Color3.fromRGB(120, 75, 35)

-- Materials give the surface texture. Swap any of these for a MaterialVariant
-- name later (MaterialService) to get custom painted textures.
Palette.MATERIAL = {
	stem = Enum.Material.Wood, -- fibrous grain along the stem
	joint = Enum.Material.SmoothPlastic,
	leaf = Enum.Material.Plastic,
	petal = Enum.Material.SmoothPlastic,
	sepal = Enum.Material.Fabric,
	center = Enum.Material.Sand, -- pollen grain
	anther = Enum.Material.SmoothPlastic,
	seed = Enum.Material.Wood,
	habitatWall = Enum.Material.Marble, -- veined, organic looking shell
	habitatFloor = Enum.Material.Grass,
	habitatGlow = Enum.Material.Neon,
}

local function smooth(f: number): number
	return f * f * (3 - 2 * f)
end

local function sampleRing(list: { Color3 }, x: number): Color3
	local n = #list
	local pos = (x - math.floor(x)) * n
	local i = math.floor(pos)
	local f = smooth(smooth(pos - i)) -- snaps toward pure colours
	local a = list[(i % n) + 1]
	local b = list[((i + 1) % n) + 1]
	return a:Lerp(b, f)
end

local function sampleLine(list: { Color3 }, x: number): Color3
	local pos = math.clamp(x, 0, 1) * (#list - 1)
	local i = math.min(math.floor(pos), #list - 2)
	local f = smooth(pos - i)
	return list[i + 1]:Lerp(list[i + 2], f)
end

function Palette.flower(hue: number): Color3
	return sampleRing(Palette.FLOWER_RING, hue)
end

function Palette.leaf(hue: number): Color3
	-- Squash the gene so most plants are green and coloured foliage is rarer.
	return sampleLine(Palette.LEAF_LINE, hue ^ 1.8)
end

function Palette.stem(leafHue: number, stemHue: number): Color3
	local green = Palette.shade(Palette.leaf(leafHue), -0.25)
	return green:Lerp(Palette.STEM_RED, stemHue ^ 2.5)
end

--[[
	Shade a colour for depth. k from -1 (deep shadow) to 1 (highlight).
	Shadows darken and get more saturated (painterly, never grey);
	highlights lift toward white and desaturate slightly.
]]
function Palette.shade(c: Color3, k: number): Color3
	local h, s, v = c:ToHSV()
	if k < 0 then
		v = v * (1 + k * 0.55)
		s = math.min(1, s * (1 - k * 0.25) + (-k) * 0.05)
	else
		v = v + (1 - v) * k * 0.6
		s = s * (1 - k * 0.35)
	end
	return Color3.fromHSV(h, math.clamp(s, 0, 1), math.clamp(v, 0, 1))
end

-- Gradient helper: colour at position t (0 base, 1 tip) between two colours,
-- with base shadow and tip highlight.
function Palette.gradient(base: Color3, tip: Color3, t: number, depth: number?): Color3
	local d = depth or 0.35
	return Palette.shade(base:Lerp(tip, t), -d + t * d * 1.4)
end

--[[
	Biome tint: plants lean a little toward the colours of the biome they are
	suited to, so a desert plant reads sandy-sage with warm flowers and a
	wetland plant teal with blue flowers, while staying bright. The "home"
	biome comes from the plant's own preferences (genes prefTemp/prefMoist),
	not from where it is planted, so a plant keeps its colours wherever it
	grows and a matching plant blends into its biome. Specialists (low
	tolerance) are tinted more than generalists.
]]
Palette.BIOME_TINT = {
	Desert = { leaf = Color3.fromRGB(175, 190, 95), flower = Color3.fromRGB(255, 150, 40) },
	Meadow = { leaf = Color3.fromRGB(95, 205, 60), flower = Color3.fromRGB(255, 220, 60) },
	Forest = { leaf = Color3.fromRGB(30, 125, 60), flower = Color3.fromRGB(205, 60, 175) },
	Wetland = { leaf = Color3.fromRGB(35, 150, 135), flower = Color3.fromRGB(80, 135, 255) },
	Tundra = { leaf = Color3.fromRGB(120, 175, 175), flower = Color3.fromRGB(215, 235, 255) },
	Jungle = { leaf = Color3.fromRGB(20, 165, 70), flower = Color3.fromRGB(255, 50, 95) },
	Ember = { leaf = Color3.fromRGB(120, 60, 50), flower = Color3.fromRGB(255, 110, 20) },
}

-- Fire and steam plants (Shared.Plants.Element; heat 1 and 0.5): leaves and
-- stems char toward dark ember red, petal tips and the flower's middle
-- burn toward flame yellow. The petals keep their own colour underneath, so
-- a Blue Tulip is still blue when it is a Fire Blue Tulip.
Palette.CHAR_LEAF = Color3.fromRGB(88, 38, 44)
Palette.CHAR_STEM = Color3.fromRGB(52, 44, 50)
Palette.FLAME_TIP = Color3.fromRGB(255, 225, 90)
Palette.FLAME_CORE = Color3.fromRGB(255, 170, 40)

function Palette.scorch(c: Color3, toward: Color3, heat: number, amount: number): Color3
	if heat <= 0 then
		return c
	end
	return c:Lerp(toward, math.clamp(heat * amount, 0, 1))
end

-- Fire plants proper (heat 1, born in the Ember biome) go further: their
-- petals are FLAMES (glowing tongues, deep orange at the base licking up to
-- yellow, with a touch of the flower's own colour so they still differ) and
-- their leaves and stalks are shiny METAL: copper leaves on steel stalks.
-- Steam plants (heat 0.5) keep the charred look above.
Palette.METAL_LEAF = Color3.fromRGB(222, 132, 74) -- bright copper
Palette.METAL_STEM = Color3.fromRGB(176, 170, 190) -- polished steel
Palette.FLAME_BASE = Color3.fromRGB(255, 78, 22)

Palette.MATERIAL_FIRE = {
	stem = Enum.Material.DiamondPlate,
	joint = Enum.Material.Metal,
	leaf = Enum.Material.Metal,
	petal = Enum.Material.Neon, -- flames glow
	sepal = Enum.Material.Metal,
	center = Enum.Material.Neon,
	anther = Enum.Material.Neon, -- sparks
	seed = Enum.Material.Metal,
	habitatWall = Palette.MATERIAL.habitatWall,
	habitatFloor = Palette.MATERIAL.habitatFloor,
	habitatGlow = Palette.MATERIAL.habitatGlow,
}

-- How shiny each fire-plant material is (Part.Reflectance).
Palette.REFLECT_FIRE = {
	[Enum.Material.Metal] = 0.22,
	[Enum.Material.DiamondPlate] = 0.15,
}

-- Is this a fire plant (gene fire >= 0.66, Shared.Plants.Element)? Takes genes.
function Palette.isFire(genes: any): boolean
	return type(genes) == "table" and type(genes.fire) == "number" and genes.fire >= 0.66
end

-- A fire plant's leaf / stalk colour from its ordinary one.
function Palette.metalLeaf(c: Color3): Color3
	return c:Lerp(Palette.METAL_LEAF, 0.75)
end
function Palette.metalStem(c: Color3): Color3
	return c:Lerp(Palette.METAL_STEM, 0.8)
end

-- A flame's colour: t 0 at its base .. 1 at its tip; c is the flower's own
-- colour, a hint of which stays in the base.
function Palette.flame(c: Color3, t: number): Color3
	local base = Palette.FLAME_BASE:Lerp(c, 0.22)
	return base:Lerp(Palette.FLAME_TIP, math.clamp(t, 0, 1))
end

local Biomes = nil
local function classify(temperature: number, moisture: number): string
	if Biomes == nil then
		Biomes = require(script.Parent.Host).biomes() or false
	end
	if Biomes then
		-- frozen Tundra edge, so no grown plant changes colour
		return Biomes.classify(temperature, moisture, Biomes.LAYOUT_TUNDRA_TEMPERATURE)
	end
	return "Meadow"
end

-- Home biome name, its tint, and how strongly (0..1) to apply it.
function Palette.biomeTint(genes): (string, { leaf: Color3, flower: Color3 }, number)
	local home = classify(genes.prefTemp, genes.prefMoist)
	local tint = Palette.BIOME_TINT[home] or Palette.BIOME_TINT.Meadow
	local amount = 0.32 - 0.17 * (genes.tolerance or 0.5) -- 0.15 .. 0.32
	return home, tint, amount
end

-- Blend toward a tint without losing brightness or saturation.
function Palette.tint(c: Color3, toward: Color3, amount: number): Color3
	local mixed = c:Lerp(toward, amount)
	local h, s, v = mixed:ToHSV()
	local _, s0, v0 = c:ToHSV()
	return Color3.fromHSV(h, math.max(s, s0 * 0.9), math.max(v, v0 * 0.95))
end

return Palette
