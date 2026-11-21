--[[
	FurnitureRules: the rules that designed furniture grows from, and decor
	styles (sets of rules that make pieces match).

	Designed pieces (a chair, stool, table, bench, bed, floor lamp, bookcase)
	are grown from a small shape grammar (Shared.Plants.FurnitureGrammar): each
	kind is the same few parts put together its own way.

	  Chair   -> Legs + Seat(shape) + Back + Trim
	  Stool   -> Legs + Seat(shape) + Trim
	  Table   -> Legs + Apron + Top(shape) + Trim
	  Bench   -> Legs + Seat(shape) + Back + Trim
	  Bed     -> Legs + Frame(shape) + Mattress + Headboard(back) + Trim
	  Lamp    -> Base + Stem(legs) + Shade(shape) + Bulb + Trim
	  Bookcase-> Sides(legs) + Shelves + Books + Crest(back) + Trim

	Each part has a rule with a few choices (a gene). A piece's recipe is one
	short string that names every choice, so the same recipe always grows the
	same piece, exactly, wherever it goes:

	  "a" .. style .. legs .. shape .. back .. trim .. weight .. size .. colour

	one base-36 digit each ("a" is the grammar's version: a later grammar adds
	a new letter, and old recipes keep growing the old way).

	Decor styles. Liu, Hertzmann, Li and Funkhouser (Style Compatibility for
	3D Furniture Models, SIGGRAPH 2015) found that people judge whether two
	pieces of different kinds belong together mostly by their parts: the
	profile of the legs, how curved or square the shapes are, how heavy and
	how ornamented they are. A heavy, ornate table wants heavy, ornate chairs.
	So a decor style here is a set of allowed choices for those shared parts
	(and its own colours): every piece made in one style shares its legs,
	outlines, ornament and weight, whatever kind it is, so a table and its
	chairs match. RoomFurniture.match scores any two pieces the same way
	(their paper's per-kind-pair distance, with hand-set weights in place of
	learned ones).

	Plain Lua (no Roblox types), shared by server and client and testable
	outside Roblox. Colours are { r, g, b } (0..255); FurnitureGrammar makes
	them Color3s.
]]

local FurnitureRules = {}

FurnitureRules.VERSION = "a"

-- The rules, in recipe order. Each choice: id, name.
FurnitureRules.GENES = {
	{ id = "legs", name = "Legs", icon = "🦵", choices = { "Post", "Turned", "Stalk", "Twig", "Reed", "Pedestal" } },
	{ id = "shape", name = "Shape", icon = "🔷", choices = { "Square", "Soft", "Round", "Leaf", "Petal", "Hex" } },
	{ id = "back", name = "Back", icon = "🪑", choices = { "None", "Ladder", "Spindle", "Fan", "Leaf", "Arch" } },
	{ id = "trim", name = "Trim", icon = "🌼", choices = { "Plain", "Petals", "Dots", "Vine", "Drips", "Beads" } },
	{ id = "weight", name = "Weight", icon = "⚖️", choices = { "Slender", "Classic", "Chunky" } },
	{ id = "size", name = "Size", icon = "📏", choices = { "Small", "Medium", "Large" } },
	{ id = "colour", name = "Colour", icon = "🎨", choices = { "Home", "A", "B" } },
}
local GENE_INDEX = {}
for i, g in FurnitureRules.GENES do
	GENE_INDEX[g.id] = i
end
FurnitureRules.GENE_INDEX = GENE_INDEX

-- Designed kinds: their name, which rules they use, how they stand in a room
-- (RoomPlanner hints), and their market price in tokens.
FurnitureRules.KINDS = {
	dchair = { name = "Chair", icon = "🪑", uses = { legs = true, shape = true, back = true, trim = true, weight = true, size = true, colour = true }, price = 18 },
	dstool = { name = "Stool", icon = "🍄", uses = { legs = true, shape = true, trim = true, weight = true, size = true, colour = true }, price = 10 },
	dtable = { name = "Table", icon = "🍽️", uses = { legs = true, shape = true, trim = true, weight = true, size = true, colour = true }, price = 24 },
	dbench = { name = "Bench", icon = "🛋️", uses = { legs = true, shape = true, back = true, trim = true, weight = true, size = true, colour = true }, price = 18 },
	dbed = { name = "Bed", icon = "🛏️", uses = { legs = true, shape = true, back = true, trim = true, weight = true, size = true, colour = true }, price = 34 },
	dlamp = { name = "Floor Lamp", icon = "🏮", uses = { legs = true, shape = true, trim = true, weight = true, size = true, colour = true }, price = 14 },
	dshelf = { name = "Bookcase", icon = "📚", uses = { legs = true, shape = true, back = true, trim = true, weight = true, size = true, colour = true }, price = 28 },
}
FurnitureRules.ORDER = { "dchair", "dtable", "dstool", "dbench", "dbed", "dlamp", "dshelf" }

-- Which rule each kind's parts read, for the designer's labels.
FurnitureRules.PART_NAMES = {
	dlamp = { legs = "Stem", shape = "Shade" },
	dshelf = { legs = "Sides", shape = "Shelves", back = "Crest" },
	dbed = { back = "Headboard", shape = "Frame" },
	dtable = { shape = "Top" },
	dchair = { shape = "Seat" },
	dstool = { shape = "Seat" },
	dbench = { shape = "Seat" },
}

-- Decor styles. Each lists the choices it allows for each rule (by number,
-- the first is its default) and two colourways (A and B). Colour "Home"
-- takes the colours of the plant the piece grows in, like grown furniture.
-- `frame` (legs, posts, sides), `top` (seats, tops, boards), `cloth`
-- (cushions, bedding, books), `trim` (ornament), `leaf` (vines, leaves),
-- `glow` (bulbs, beads), and the materials of frames and tops.
FurnitureRules.STYLES = {
	{
		id = "cottage", name = "Mushroom Cottage", icon = "🍄",
		blurb = "Stalk legs, round red caps, white dots",
		allow = { legs = { 3, 6 }, shape = { 3, 2 }, back = { 6, 2, 1 }, trim = { 3, 1 }, weight = { 3, 2 }, size = { 2, 1, 3 }, colour = { 2, 3, 1 } },
		palettes = {
			{ name = "Red cap", frame = { 240, 228, 205 }, top = { 222, 62, 55 }, cloth = { 250, 238, 218 }, trim = { 255, 250, 240 }, leaf = { 90, 160, 80 }, glow = { 255, 230, 160 }, frameMat = "smooth", topMat = "smooth" },
			{ name = "Brown cap", frame = { 236, 222, 196 }, top = { 150, 96, 62 }, cloth = { 232, 204, 156 }, trim = { 255, 242, 220 }, leaf = { 100, 150, 80 }, glow = { 255, 220, 150 }, frameMat = "smooth", topMat = "smooth" },
		},
	},
	{
		id = "lily", name = "Lily Pond", icon = "🐸",
		blurb = "Reed legs, leaf and pad shapes, buds",
		allow = { legs = { 5, 3 }, shape = { 4, 3 }, back = { 5, 4, 1 }, trim = { 2, 1 }, weight = { 1, 2 }, size = { 2, 1, 3 }, colour = { 2, 3, 1 } },
		palettes = {
			{ name = "Pond green", frame = { 108, 158, 92 }, top = { 92, 172, 98 }, cloth = { 255, 196, 218 }, trim = { 255, 150, 196 }, leaf = { 80, 170, 92 }, glow = { 230, 255, 200 }, frameMat = "smooth", topMat = "smooth" },
			{ name = "Water lily", frame = { 92, 140, 128 }, top = { 124, 192, 170 }, cloth = { 246, 246, 252 }, trim = { 255, 222, 92 }, leaf = { 70, 160, 120 }, glow = { 255, 245, 200 }, frameMat = "smooth", topMat = "smooth" },
		},
	},
	{
		id = "parlour", name = "Petal Parlour", icon = "🌸",
		blurb = "Turned legs, scalloped petals, fan backs",
		allow = { legs = { 2, 6 }, shape = { 5, 2, 3 }, back = { 4, 6, 3 }, trim = { 2, 6, 1 }, weight = { 2, 1 }, size = { 2, 1, 3 }, colour = { 2, 3, 1 } },
		palettes = {
			{ name = "Rose", frame = { 150, 82, 72 }, top = { 240, 162, 182 }, cloth = { 252, 218, 228 }, trim = { 255, 120, 160 }, leaf = { 110, 170, 100 }, glow = { 255, 220, 200 }, frameMat = "wood", topMat = "smooth" },
			{ name = "Lilac", frame = { 118, 90, 132 }, top = { 202, 172, 232 }, cloth = { 242, 228, 252 }, trim = { 255, 216, 120 }, leaf = { 120, 170, 120 }, glow = { 240, 225, 255 }, frameMat = "wood", topMat = "smooth" },
		},
	},
	{
		id = "rustic", name = "Twig Rustic", icon = "🌳",
		blurb = "Twig legs, soft planks, ladder backs, vines",
		allow = { legs = { 4, 1 }, shape = { 2, 1 }, back = { 2, 3, 1 }, trim = { 4, 1 }, weight = { 2, 3 }, size = { 2, 1, 3 }, colour = { 2, 3, 1 } },
		palettes = {
			{ name = "Oak", frame = { 128, 88, 54 }, top = { 172, 122, 76 }, cloth = { 212, 186, 140 }, trim = { 92, 150, 70 }, leaf = { 86, 150, 66 }, glow = { 255, 220, 150 }, frameMat = "wood", topMat = "planks" },
			{ name = "Birch", frame = { 226, 220, 206 }, top = { 202, 186, 160 }, cloth = { 162, 192, 142 }, trim = { 112, 92, 72 }, leaf = { 100, 160, 90 }, glow = { 255, 236, 180 }, frameMat = "wood", topMat = "planks" },
		},
	},
	{
		id = "honey", name = "Honeycomb", icon = "🍯",
		blurb = "Square posts, hex shapes, spindles, honey drips",
		allow = { legs = { 1, 6 }, shape = { 6, 1 }, back = { 3, 2 }, trim = { 5, 6, 1 }, weight = { 3, 2 }, size = { 2, 1, 3 }, colour = { 2, 3, 1 } },
		palettes = {
			{ name = "Golden", frame = { 204, 148, 58 }, top = { 255, 192, 62 }, cloth = { 255, 232, 162 }, trim = { 255, 172, 30 }, leaf = { 120, 160, 70 }, glow = { 255, 210, 110 }, frameMat = "wood", topMat = "smooth" },
			{ name = "Beeswax", frame = { 110, 74, 40 }, top = { 242, 216, 152 }, cloth = { 255, 240, 202 }, trim = { 232, 160, 40 }, leaf = { 110, 150, 70 }, glow = { 255, 220, 140 }, frameMat = "wood", topMat = "smooth" },
		},
	},
	{
		id = "moon", name = "Moonglow", icon = "🌙",
		blurb = "Slender reeds and pedestals, round arches, glow beads",
		allow = { legs = { 6, 5 }, shape = { 3, 2 }, back = { 6, 3 }, trim = { 6, 1 }, weight = { 1, 2 }, size = { 2, 1, 3 }, colour = { 2, 3, 1 } },
		palettes = {
			{ name = "Moonlight", frame = { 200, 210, 232 }, top = { 150, 170, 222 }, cloth = { 226, 230, 252 }, trim = { 190, 222, 255 }, leaf = { 140, 190, 170 }, glow = { 200, 228, 255 }, frameMat = "smooth", topMat = "smooth" },
			{ name = "Night", frame = { 72, 72, 112 }, top = { 112, 100, 172 }, cloth = { 182, 176, 232 }, trim = { 255, 236, 150 }, leaf = { 110, 150, 150 }, glow = { 255, 236, 150 }, frameMat = "smooth", topMat = "smooth" },
		},
	},
	{
		id = "mix", name = "Mix & Match", icon = "🎲",
		blurb = "Any rule, any choice",
		allow = { legs = { 1, 2, 3, 4, 5, 6 }, shape = { 1, 2, 3, 4, 5, 6 }, back = { 2, 1, 3, 4, 5, 6 }, trim = { 1, 2, 3, 4, 5, 6 }, weight = { 2, 1, 3 }, size = { 2, 1, 3 }, colour = { 1, 2, 3 } },
		palettes = {
			{ name = "Meadow", frame = { 150, 108, 70 }, top = { 122, 182, 92 }, cloth = { 250, 230, 150 }, trim = { 240, 120, 140 }, leaf = { 90, 160, 80 }, glow = { 255, 230, 160 }, frameMat = "wood", topMat = "smooth" },
			{ name = "Berry", frame = { 120, 60, 80 }, top = { 200, 72, 102 }, cloth = { 250, 202, 212 }, trim = { 122, 62, 162 }, leaf = { 90, 150, 90 }, glow = { 255, 210, 230 }, frameMat = "wood", topMat = "smooth" },
		},
	},
}
FurnitureRules.MIX = #FurnitureRules.STYLES

---------------------------------------------------------------- recipes

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local NGENES = #FurnitureRules.GENES
FurnitureRules.LENGTH = 2 + NGENES

export type Design = { style: number, legs: number, shape: number, back: number, trim: number, weight: number, size: number, colour: number }

local function digit(n: number): string
	return string.sub(DIGITS, n + 1, n + 1)
end

local function undigit(ch: string): number?
	local i = string.find(DIGITS, ch, 1, true)
	return if i then i - 1 else nil
end

-- A design -> its recipe string. Choices are 1-based.
function FurnitureRules.encode(d: Design): string
	local out = { FurnitureRules.VERSION, digit(d.style - 1) }
	for _, g in FurnitureRules.GENES do
		table.insert(out, digit(((d :: any)[g.id] or 1) - 1))
	end
	return table.concat(out)
end

-- A recipe -> its design, or nil if it isn't one.
function FurnitureRules.decode(r: any): Design?
	if type(r) ~= "string" or #r ~= FurnitureRules.LENGTH or string.sub(r, 1, 1) ~= FurnitureRules.VERSION then
		return nil
	end
	local style = undigit(string.sub(r, 2, 2))
	if not style or style + 1 > #FurnitureRules.STYLES then
		return nil
	end
	local d: any = { style = style + 1 }
	for i, g in FurnitureRules.GENES do
		local v = undigit(string.sub(r, 2 + i, 2 + i))
		if not v or v + 1 > #g.choices then
			return nil
		end
		d[g.id] = v + 1
	end
	return d :: Design
end

function FurnitureRules.valid(r: any): boolean
	return FurnitureRules.decode(r) ~= nil
end

-- A style's own default design.
function FurnitureRules.default(style: number): Design
	local s = FurnitureRules.STYLES[style] or FurnitureRules.STYLES[1]
	local d: any = { style = style }
	for _, g in FurnitureRules.GENES do
		d[g.id] = s.allow[g.id][1]
	end
	return d :: Design
end

function FurnitureRules.allows(style: number, gene: string, choice: number): boolean
	local s = FurnitureRules.STYLES[style]
	if not s then
		return false
	end
	return table.find(s.allow[gene], choice) ~= nil
end

-- Does every choice of `d` fit its style's rules?
function FurnitureRules.inStyle(d: Design): boolean
	for _, g in FurnitureRules.GENES do
		if not FurnitureRules.allows(d.style, g.id, (d :: any)[g.id]) then
			return false
		end
	end
	return true
end

-- The next allowed choice of one rule (step +1 or -1), within the style.
function FurnitureRules.step(d: Design, gene: string, by: number): Design
	local allow = FurnitureRules.STYLES[d.style].allow[gene]
	local list = table.clone(allow)
	table.sort(list)
	local at = table.find(list, (d :: any)[gene]) or 1
	local out = table.clone(d) :: any
	out[gene] = list[((at - 1 + by) % #list) + 1]
	return out :: Design
end

-- A design rolled from a number generator `next(lo, hi)` (an integer in
-- lo..hi), keeping to one style: for pieces with no recipe of their own.
function FurnitureRules.roll(next: (number, number) -> number): Design
	local style = next(1, FurnitureRules.MIX - 1)
	local s = FurnitureRules.STYLES[style]
	local d: any = { style = style }
	for _, g in FurnitureRules.GENES do
		local allow = s.allow[g.id]
		d[g.id] = allow[next(1, #allow)]
	end
	return d :: Design
end

-- A small stable hash of a recipe (seeds a design's little details, like
-- which books stand on a shelf, so the same recipe is always the same piece).
function FurnitureRules.hash(r: string): number
	local h = 5381
	for i = 1, #r do
		h = (h * 33 + string.byte(r, i)) % 2147483647
	end
	return h % 9999999 + 1
end

---------------------------------------------------------------- group styles

-- A town (or any group of buildings) picks one decor style from its seed,
-- and its own signature within it: the legs, outline and colourway every
-- piece shares (the parts people match by, Liu et al.). Each piece then
-- grows its own back, trim, weight and size from its own seed, within the
-- style, so no two are alike but they all belong together.
export type Group = { style: number, legs: number, shape: number, colour: number }

local function lcg(seed: number): (number, number) -> number
	local s = math.floor(math.abs(seed)) % 2147483646 + 1
	return function(lo: number, hi: number): number
		s = (s * 16807) % 2147483647
		return lo + s % (hi - lo + 1)
	end
end

function FurnitureRules.groupStyle(seed: number): Group
	local next = lcg(seed * 7 + 13)
	next(1, 2) -- stir
	local style = next(1, FurnitureRules.MIX - 1)
	local s = FurnitureRules.STYLES[style]
	return {
		style = style,
		legs = s.allow.legs[next(1, #s.allow.legs)],
		shape = s.allow.shape[next(1, #s.allow.shape)],
		colour = next(2, 3), -- one of the style's own colourways
	}
end

-- The recipe of one piece of kind `id` in group style `g`, from its seed.
function FurnitureRules.groupRecipe(g: Group, id: string, seed: number): string
	local s = FurnitureRules.STYLES[g.style]
	local next = lcg(seed * 31 + 7)
	next(1, 2)
	local d: any = { style = g.style, legs = g.legs, shape = g.shape, colour = g.colour }
	for _, gene in { "back", "trim", "weight", "size" } do
		local allow = s.allow[gene]
		d[gene] = allow[next(1, #allow)]
	end
	return FurnitureRules.encode(d :: Design)
end

-- The grown pieces a styled room swaps for designed ones.
FurnitureRules.STYLED = {
	stool = "dstool", bench = "dbench", armchair = "dchair", table = "dtable", roundTable = "dtable",
	shelf = "dshelf", lantern = "dlamp", bed = "dbed",
}
-- What sits round a styled table.
FurnitureRules.STYLED_SEAT = "dchair"

---------------------------------------------------------------- names

function FurnitureRules.isKind(id: any): boolean
	return type(id) == "string" and FurnitureRules.KINDS[id] ~= nil
end

function FurnitureRules.styleOf(r: any): any?
	local d = FurnitureRules.decode(r)
	return if d then FurnitureRules.STYLES[d.style] else nil
end

-- "Mushroom Cottage Chair" (or "Chair" with no recipe).
function FurnitureRules.name(id: string, r: string?): string
	local k = FurnitureRules.KINDS[id]
	local base = if k then k.name else id
	local style = FurnitureRules.styleOf(r)
	if style and style.id ~= "mix" then
		return style.name .. " " .. base
	end
	return base
end

-- The label of one rule on one kind ("Shade" for a lamp's shape).
function FurnitureRules.partName(id: string, gene: string): string
	local names = FurnitureRules.PART_NAMES[id]
	if names and names[gene] then
		return names[gene]
	end
	return FurnitureRules.GENES[GENE_INDEX[gene]].name
end

-- The name of one choice ("Red cap" for a style's colour A).
function FurnitureRules.choiceName(d: Design, gene: string): string
	local v = (d :: any)[gene]
	if gene == "colour" then
		if v == 1 then
			return "Home"
		end
		local s = FurnitureRules.STYLES[d.style]
		return s.palettes[v - 1].name
	end
	return FurnitureRules.GENES[GENE_INDEX[gene]].choices[v]
end

---------------------------------------------------------------- matching

-- What people notice when judging if two pieces belong together (Liu et al.
-- 2015): curvature, weight and ornament of the parts. 0..1 each.
local CURVE_LEGS = { 0, 0.6, 0.8, 0.5, 0.35, 0.7 }
local CURVE_SHAPE = { 0, 0.5, 1, 0.9, 1, 0.2 }
local ORNATE_TRIM = { 0, 0.8, 0.6, 0.7, 0.7, 0.8 }
local ORNATE_BACK = { 0, 0.3, 0.5, 0.9, 0.7, 0.4 }
local HEAVY_LEGS = { 0.1, 0, 0.3, 0, -0.2, 0.2 }

local function features(id: string, d: Design)
	local uses = FurnitureRules.KINDS[id] and FurnitureRules.KINDS[id].uses or {}
	return {
		curve = (CURVE_LEGS[d.legs] + CURVE_SHAPE[d.shape]) / 2,
		ornate = if uses.back then (ORNATE_TRIM[d.trim] * 0.7 + ORNATE_BACK[d.back] * 0.3) else ORNATE_TRIM[d.trim],
		heavy = math.clamp((d.weight - 1) / 2 + HEAVY_LEGS[d.legs], 0, 1),
	}
end

-- How much each part counts between two kinds (a chair and its table are
-- judged mostly by legs and shape; a lamp by colour and ornament).
local DEFAULT_W = { legs = 1.5, shape = 1.2, back = 0.4, trim = 1, palette = 1.6, curve = 1.2, ornate = 1, heavy = 1 }
local PAIR_W = {
	["dchair|dtable"] = { legs = 2, shape = 1.5, back = 0.3, trim = 1, palette = 2, curve = 1.5, ornate = 1.2, heavy = 1.5 },
	["dstool|dtable"] = { legs = 2, shape = 1.6, back = 0, trim = 1, palette = 2, curve = 1.5, ornate = 1, heavy = 1.5 },
	["dchair|dchair"] = { legs = 2, shape = 2, back = 2, trim = 1.5, palette = 2, curve = 1, ornate = 1, heavy = 1 },
	["dbed|dlamp"] = { legs = 0.6, shape = 0.8, back = 0, trim = 1.5, palette = 2.5, curve = 1, ornate = 1.5, heavy = 0.5 },
	["dlamp|dtable"] = { legs = 0.6, shape = 1, back = 0, trim = 1.5, palette = 2.5, curve = 1, ornate = 1.5, heavy = 0.5 },
	["dbed|dshelf"] = { legs = 1, shape = 0.8, back = 1, trim = 1.2, palette = 2.2, curve = 1, ornate = 1.2, heavy = 1 },
}

local function weightsFor(a: string, b: string)
	local key = if a < b then a .. "|" .. b else b .. "|" .. a
	return PAIR_W[key] or DEFAULT_W
end

-- How well two designed pieces go together, 0 (clash) .. 1 (a set).
function FurnitureRules.match(idA: string, rA: string, idB: string, rB: string): number
	local a, b = FurnitureRules.decode(rA), FurnitureRules.decode(rB)
	if not a or not b then
		return 0
	end
	local w = weightsFor(idA, idB)
	local ua = FurnitureRules.KINDS[idA] and FurnitureRules.KINDS[idA].uses or {}
	local ub = FurnitureRules.KINDS[idB] and FurnitureRules.KINDS[idB].uses or {}
	local dist, total = 0, 0
	local function part(g: string, differs: boolean)
		if not (ua[g] and ub[g]) then
			return
		end
		total += w[g]
		if differs then
			dist += w[g]
		end
	end
	part("legs", a.legs ~= b.legs)
	part("shape", a.shape ~= b.shape)
	part("back", a.back ~= b.back)
	part("trim", a.trim ~= b.trim)
	-- colours: the same colourway matches; both "Home" match; else a clash
	local samePalette = (a.colour == 1 and b.colour == 1) or (a.colour ~= 1 and a.colour == b.colour and a.style == b.style)
	total += w.palette
	if not samePalette then
		dist += w.palette * (if a.style == b.style then 0.5 else 1)
	end
	local fa, fb = features(idA, a), features(idB, b)
	total += w.curve + w.ornate + w.heavy
	dist += w.curve * math.abs(fa.curve - fb.curve) + w.ornate * math.abs(fa.ornate - fb.ornate) + w.heavy * math.abs(fa.heavy - fb.heavy)
	if total <= 0 then
		return 1
	end
	return math.clamp(1 - dist / total, 0, 1)
end

return FurnitureRules
