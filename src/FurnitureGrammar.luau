--[[
	FurnitureGrammar: grows designed furniture from its recipe
	(Shared.Plants.FurnitureRules has the rules, the styles and the recipes).

	A small shape grammar. Every designed kind is put together from the same
	parts, and each part reads one rule:

	  legs(...)  - Post | Turned | Stalk | Twig | Reed | Pedestal
	  top(...)   - Square | Soft | Round | Leaf | Petal | Hex   (seats, tops, frames, shades)
	  back(...)  - None | Ladder | Spindle | Fan | Leaf | Arch  (chair backs, headboards, crests)
	  trim(...)  - Plain | Petals | Dots | Vine | Drips | Beads (round the top's edge, on the legs)

	with Weight (how thick everything is), Size and Colour (the plant's own
	colours, or one of the style's two colourways). Because a style fixes the
	same choices for every kind, its chairs, tables and beds share their legs,
	outlines and ornament and look like one set.

	Pieces are built with Furniture's builder `B` in the piece's own frame:
	normal studs, standing on y = 0, front facing -Z, back (+Z) to the wall.
	FurnitureGrammar.params(id, recipe) gives the sizes RoomPlanner and
	FurnitureUse read (w, d, h, and seatY for seats); FurnitureGrammar.build
	grows it. Everything comes from the recipe (little details from its
	hash), so a recipe is one exact piece.
]]

local Palette = require(script.Parent.Palette)
local FurnitureRules = require(script.Parent.FurnitureRules)

local FurnitureGrammar = {}

local shade = Palette.shade
local M = Palette.MATERIAL
local TAU = math.pi * 2
local SQRT3 = math.sqrt(3)
local SMOOTH = Enum.Material.SmoothPlastic
local FABRIC = Enum.Material.Fabric
local MATS = { smooth = SMOOTH, wood = Enum.Material.Wood, planks = Enum.Material.WoodPlanks }
local BARK = Color3.fromRGB(150, 92, 52)
local GLOW = Color3.fromRGB(255, 236, 150)
local CREAM = Color3.fromRGB(255, 248, 228)

local SIZE = { 0.85, 1, 1.18 }
local WEIGHT = { 0.7, 1, 1.4 }

local function rgb(t: { number }): Color3
	return Color3.fromRGB(t[1], t[2], t[3])
end

-- The colours a design grows in: the plant's own (Home) or a style colourway.
function FurnitureGrammar.palette(d: FurnitureRules.Design, c: any)
	if d.colour > 1 then
		local s = FurnitureRules.STYLES[d.style]
		local p = s.palettes[d.colour - 1]
		return {
			frame = rgb(p.frame), top = rgb(p.top), cloth = rgb(p.cloth), trim = rgb(p.trim),
			leaf = rgb(p.leaf), glow = rgb(p.glow), frameMat = MATS[p.frameMat] or SMOOTH, topMat = MATS[p.topMat] or SMOOTH,
		}
	end
	local wood = shade(c.stem:Lerp(BARK, 0.55), -0.1)
	return {
		frame = wood, top = shade(wood, 0.18), cloth = c.petalBase, trim = c.petalTip,
		leaf = c.leaf, glow = c.center:Lerp(GLOW, 0.5), frameMat = Enum.Material.Wood, topMat = Enum.Material.Wood,
	}
end

---------------------------------------------------------------- parts

-- Points round the edge of an outline (for trims), at height y.
local function edgePoints(shape: number, w: number, d: number, y: number, spacing: number): { Vector3 }
	local out = {}
	if shape == 1 or shape == 6 then -- square, hex: round the rectangle
		local per = 2 * (w + d)
		local n = math.max(4, math.floor(per / spacing))
		for i = 0, n - 1 do
			local t = (i + 0.5) / n * per
			local x, z
			if t < w then
				x, z = -w / 2 + t, -d / 2
			elseif t < w + d then
				x, z = w / 2, -d / 2 + (t - w)
			elseif t < 2 * w + d then
				x, z = w / 2 - (t - w - d), d / 2
			else
				x, z = -w / 2, d / 2 - (t - 2 * w - d)
			end
			table.insert(out, Vector3.new(x, y, z))
		end
	else
		local per = math.pi * (w + d) / 2
		local n = math.max(6, math.floor(per / spacing))
		for i = 0, n - 1 do
			local a = i / n * TAU
			table.insert(out, Vector3.new(math.cos(a) * w / 2, y, math.sin(a) * d / 2))
		end
	end
	return out
end

-- A regular hexagon with its points at +-X (three crossed boxes), centred at
-- (x, y, z), circumradius R, thickness t.
local function hex(B, n: string, R: number, t: number, x: number, y: number, z: number, color: Color3, mat: Enum.Material, collide: boolean?)
	local e = math.max(t * 0.04, 0.02)
	for i = 0, 2 do
		B.box(n, R, t - i * e, R * SQRT3, x, y, z, color, mat, collide, CFrame.Angles(0, i * math.pi / 3, 0))
	end
end

-- A seat, table top, frame or board: outline `shape`, w x d, t thick, its
-- middle at height y.
local function top(B, n: string, shape: number, w: number, d: number, t: number, y: number, color: Color3, mat: Enum.Material, z: number?)
	z = z or 0
	if shape == 1 then
		B.slab(n, w, t, d, 0, y, z, color, mat, true, 0.08)
	elseif shape == 2 then
		B.slab(n, w, t, d, 0, y, z, color, mat, true, math.min(w, d) * 0.3)
	elseif shape == 3 then
		if math.abs(w - d) < 0.05 then
			B.cyl(n, w, 0, y - t / 2, y + t / 2, z, color, mat, true)
		else
			B.slab(n, w, t, d, 0, y, z, color, mat, true, math.min(w, d) / 2 - 0.02)
		end
	elseif shape == 4 then
		-- a leaf: a flat oval with a pale midrib and veins, its tip out front
		B.box(n, w * 0.7, t * 0.8, d * 0.7, 0, y, z, color, mat, true)
		B.egg(n, w, t, d, 0, y, z, color, mat)
		local along = w >= d
		local len = if along then w else d
		local rib = shade(color, 0.3)
		if along then
			B.box(n .. "Rib", len * 0.86, t * 0.2, 0.08, 0, y + t * 0.42, z, rib, mat)
		else
			B.box(n .. "Rib", 0.08, t * 0.2, len * 0.86, 0, y + t * 0.42, z, rib, mat)
		end
		for i = -1, 1 do
			local off = i * len * 0.22
			for _, side in { -1, 1 } do
				local yaw = if along then side * 0.7 else math.pi / 2 + side * 0.7
				local px = if along then off + side * 0 else side * w * 0.17
				local pz = if along then side * d * 0.17 else off
				B.box(n .. "Vein", math.min(w, d) * 0.36, t * 0.16, 0.06, px, y + t * 0.4, z + pz, rib, mat, false, CFrame.Angles(0, yaw, 0))
			end
		end
	elseif shape == 5 then
		-- a scalloped flower: a soft core and a ring of petals round its edge
		B.slab(n, w * 0.82, t, d * 0.82, 0, y, z, color, mat, true, math.min(w, d) * 0.38)
		local count = math.clamp(math.floor((w + d) * 1.3), 8, 18)
		for i = 0, count - 1 do
			local a = i / count * TAU
			local px, pz = math.cos(a) * w * 0.4, math.sin(a) * d * 0.4
			B.egg(n .. "Petal", math.min(w, d) * 0.36, t * 0.9, math.min(w, d) * 0.26, px, y - t * 0.05, z + pz, if i % 2 == 0 then color else shade(color, 0.15), mat, CFrame.Angles(0, -math.atan2(pz, px), 0))
		end
	else
		-- hex: one hexagon, or one at each end and a bar between for long pieces
		local R = math.min(w / 2, d / SQRT3)
		local reach = w / 2 - R
		if reach < 0.05 then
			hex(B, n, R, t, 0, y, z, color, mat, true)
		else
			hex(B, n, R, t, -reach, y, z, color, mat, true)
			hex(B, n, R, t, reach, y, z, color, mat, true)
			B.box(n, 2 * reach, t * 0.97, R * SQRT3, 0, y, z, color, mat, true)
		end
	end
end

-- Where the legs of a w x d piece stand (corners, or round an oval outline),
-- `inset` in from the edge, `count` of them (3, 4 or 6).
local function legSpots(shape: number, w: number, d: number, inset: number, count: number): { Vector3 }
	local out = {}
	if count == 3 then
		for i = 0, 2 do
			local a = math.pi / 2 + i / 3 * TAU
			table.insert(out, Vector3.new(math.cos(a) * (w / 2 - inset), 0, math.sin(a) * (d / 2 - inset)))
		end
		return out
	end
	local round = shape >= 3 and shape <= 5
	local kx = if round then w / 2 * 0.72 - inset * 0.4 else w / 2 - inset
	local kz = if round then d / 2 * 0.72 - inset * 0.4 else d / 2 - inset
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			table.insert(out, Vector3.new(sx * kx, 0, sz * kz))
		end
	end
	if count >= 6 then
		for _, sz in { -1, 1 } do
			table.insert(out, Vector3.new(0, 0, sz * kz))
		end
	end
	return out
end

-- Legs from y0 to y1, `dia` thick, standing at `spots` (x, z). Pedestal
-- ignores the spots: one column in the middle on a spreading foot.
local function legs(B, P, g: number, spots: { Vector3 }, y0: number, y1: number, dia: number, foot: number)
	local col, mat = P.frame, P.frameMat
	local h = y1 - y0
	if h <= 0.02 then
		return
	end
	if g == 6 then
		local cd = dia * 2.4
		B.cyl("Pedestal", foot, 0, y0, y0 + 0.16, 0, shade(col, -0.15), mat, true)
		B.cyl("Pedestal", foot * 0.6, 0, y0 + 0.16, y0 + 0.3, 0, shade(col, -0.05), mat)
		B.cyl("Pedestal", cd, 0, y0 + 0.3, y1, 0, col, mat)
		B.ball("Pedestal", cd * 1.25, 0, y0 + 0.3 + (h - 0.3) * 0.5, 0, shade(col, 0.1), mat)
		B.cyl("Pedestal", cd * 1.5, 0, y1 - 0.12, y1, 0, shade(col, -0.1), mat)
		return
	end
	for i, s in spots do
		local x, z = s.X, s.Z
		if g == 1 then
			B.box("Leg", dia, h, dia, x, y0 + h / 2, z, col, mat)
		elseif g == 2 then
			B.cyl("Leg", dia * 0.8, x, y0, y1, z, col, mat)
			B.ball("LegBulb", dia * 1.45, x, y0 + h * 0.62, z, shade(col, 0.1), mat)
			B.cyl("LegRing", dia * 1.2, x, y0 + h * 0.3, y0 + h * 0.3 + 0.1, z, shade(col, -0.15), mat)
			B.cyl("LegFoot", dia * 1.1, x, y0, y0 + 0.12, z, shade(col, -0.2), mat)
		elseif g == 3 then
			B.cyl("Stalk", dia * 1.3, x, y0 + 0.16, y1, z, col, mat)
			B.cyl("StalkFoot", dia * 1.8, x, y0, y0 + 0.18, z, shade(col, -0.08), mat)
			B.cyl("StalkRing", dia * 1.55, x, y0 + h * 0.66, y0 + h * 0.66 + 0.1, z, shade(col, -0.12), mat)
		elseif g == 4 then
			-- a twig with a kink and a knot, bent outward
			local len = math.max(math.sqrt(x * x + z * z), 1e-3)
			local ox, oz = x / len * 0.14, z / len * 0.14
			local turn = if i % 2 == 0 then 1 else -1
			local mid = Vector3.new(x + ox + oz * 0.5 * turn, y0 + h * 0.48, z + oz - ox * 0.5 * turn)
			B.rod("Twig", Vector3.new(x, y0, z), mid, dia * 0.85, col, mat)
			B.rod("Twig", mid, Vector3.new(x, y1, z), dia * 0.8, col, mat)
			B.ball("TwigKnot", dia * 1.15, mid.X, mid.Y, mid.Z, shade(col, -0.15), mat)
			B.rod("TwigSprig", mid, mid + Vector3.new(ox * 2.4, h * 0.14, oz * 2.4), dia * 0.35, shade(col, 0.1), mat)
		elseif g == 5 then
			-- a reed, splayed out at the foot, with nodes
			local foot2 = Vector3.new(x * 1.12, y0, z * 1.12)
			B.rod("Reed", foot2, Vector3.new(x, y1, z), dia * 0.7, col, mat)
			for k = 1, 2 do
				local t = k / 3
				local p = foot2:Lerp(Vector3.new(x, y1, z), t)
				B.cyl("ReedNode", dia * 0.95, p.X, p.Y - 0.04, p.Y + 0.04, p.Z, shade(col, -0.15), mat)
			end
		end
	end
end

-- A back, headboard or crest: w wide, h tall, rising from y0 at depth z.
local function back(B, P, g: number, w: number, h: number, y0: number, z: number, dia: number, low: boolean?)
	if g == 1 or h <= 0.05 then
		return
	end
	local col, mat = P.frame, P.frameMat
	local panel, pmat = P.top, P.topMat
	local postD = dia * 0.85
	local function posts()
		for _, sx in { -1, 1 } do
			B.cyl("BackPost", postD, sx * (w / 2 - postD / 2), y0, y0 + h, z, col, mat)
		end
	end
	if g == 2 then
		posts()
		local rails = if low then 2 else 3
		for i = 1, rails do
			local y = y0 + h * (0.35 + 0.6 * (i - 1) / math.max(rails - 1, 1))
			B.logX("BackRail", w - postD, postD * 0.9, 0, math.min(y, y0 + h - postD / 2), z, panel, pmat)
		end
	elseif g == 3 then
		posts()
		B.logX("BackRail", w, postD * 1.2, 0, y0 + h - postD * 0.6, z, panel, pmat)
		B.logX("BackRail", w - postD, postD * 0.7, 0, y0 + h * 0.18, z, shade(col, -0.1), mat)
		local n = math.clamp(math.floor(w / 0.55), 3, 9)
		for i = 1, n do
			local x = -w / 2 + postD + (i - 0.5) * (w - 2 * postD) / n
			B.cyl("BackSpindle", postD * 0.45, x, y0 + h * 0.18, y0 + h - postD * 0.6, z, col, mat)
		end
	elseif g == 4 then
		-- a fan of petals from a seed at the bottom middle
		local n = math.clamp(math.floor(w / 0.5), 5, 9)
		local r = math.min(h * 0.5, w * 0.45)
		for i = 1, n do
			local a = math.rad(-70 + 140 * (i - 1) / (n - 1))
			local px, py = math.sin(a) * r, math.cos(a) * r
			B.egg("BackPetal", w / n * 1.6, h * 0.62, 0.2, px * 1.05, y0 + h * 0.18 + py * 0.95, z, if i % 2 == 0 then panel else shade(panel, 0.18), pmat, CFrame.Angles(0, 0, -a))
		end
		B.ball("BackSeed", math.min(w * 0.22, 0.8), 0, y0 + h * 0.2, z - 0.05, P.trim, M.center)
		posts()
	elseif g == 5 then
		-- one big leaf with a midrib and veins
		B.egg("BackLeaf", w * 0.95, h, 0.2, 0, y0 + h / 2, z, panel, pmat)
		local rib = shade(panel, 0.3)
		B.box("BackRib", 0.08, h * 0.85, 0.24, 0, y0 + h / 2, z - 0.01, rib, pmat)
		for k = 1, 3 do
			local y = y0 + h * (0.25 + k * 0.17)
			for _, sx in { -1, 1 } do
				B.box("BackVein", w * 0.3, 0.06, 0.24, sx * w * 0.14, y, z - 0.01, rib, pmat, false, CFrame.Angles(0, 0, sx * 0.55))
			end
		end
		B.cyl("BackPost", postD, 0, y0, y0 + h * 0.15, z, col, mat)
	else
		-- an arched panel with an inset
		B.arch("BackArch", w, h, 0.26, 0, y0, z, panel, pmat, true)
		if w > 0.9 and h > 0.9 then
			B.arch("BackArchInset", w - 0.5, h - 0.45, 0.1, 0, y0 + 0.2, z - 0.15, shade(panel, 0.2), pmat)
		end
	end
end

-- Ornament: round the edge of a top (outline shape, w x d at height y) and
-- on the legs (spots, from y0 to y1). `glowOk` lets Beads glow.
local function trim(B, P, g: number, shape: number, w: number, d: number, y: number, spots: { Vector3 }?, legG: number?, y0: number?, y1: number?)
	if g == 1 then
		return
	end
	if g == 2 then
		-- a skirt of little petals under the edge
		for _, p in edgePoints(shape, w * 0.98, d * 0.98, y - 0.12, 0.55) do
			local a = math.atan2(p.Z, p.X)
			B.egg("TrimPetal", 0.5, 0.32, 0.36, p.X, p.Y, p.Z, if (math.floor(a * 4) % 2) == 0 then P.trim else shade(P.trim, 0.2), M.petal, CFrame.Angles(0, -a, 0) * CFrame.Angles(0, 0, -0.5))
		end
	elseif g == 3 then
		-- dots on the top, just inside its edge (a mushroom cap's spots)
		local pts = edgePoints(shape, w * 0.62, d * 0.62, y + 0.02, 0.9)
		for i, p in pts do
			if i % 2 == 1 or #pts <= 6 then
				B.egg("TrimDot", 0.34, 0.08, 0.34, p.X, p.Y, p.Z, P.trim, SMOOTH)
			end
		end
		B.egg("TrimDot", 0.42, 0.08, 0.42, 0, y + 0.02, 0, P.trim, SMOOTH)
	elseif g == 4 then
		-- a vine wound round the legs, with leaves
		if spots and y0 and y1 and legG ~= 6 then
			for _, s in spots do
				local h = y1 - y0
				local prev = Vector3.new(s.X + 0.2, y0 + 0.1, s.Z)
				for k = 1, 4 do
					local a = k * 1.9
					local p = Vector3.new(s.X + math.cos(a) * 0.22, y0 + 0.1 + h * k / 4.4, s.Z + math.sin(a) * 0.22)
					B.rod("TrimVine", prev, p, 0.07, P.leaf, M.stem)
					if k % 2 == 0 then
						B.egg("TrimLeaf", 0.36, 0.05, 0.2, p.X + math.cos(a) * 0.15, p.Y, p.Z + math.sin(a) * 0.15, P.leaf, M.leaf, CFrame.Angles(0, -a, 0.3))
					end
					prev = p
				end
			end
		end
		for i, p in edgePoints(shape, w, d, y, 1.2) do
			if i % 3 == 0 then
				B.egg("TrimLeaf", 0.42, 0.05, 0.24, p.X, p.Y + 0.04, p.Z, P.leaf, M.leaf, CFrame.Angles(0, -math.atan2(p.Z, p.X), 0.2))
			end
		end
	elseif g == 5 then
		-- honey dripping off the edge
		for i, p in edgePoints(shape, w, d, y, 0.8) do
			local len = 0.18 + ((i * 37) % 5) * 0.07
			B.cyl("TrimDrip", 0.14, p.X, p.Y - len, p.Y, p.Z, P.trim, SMOOTH)
			B.ball("TrimDrip", 0.2, p.X, p.Y - len, p.Z, P.trim, SMOOTH)
		end
	else
		-- little glowing beads round the edge and on the leg tops
		for i, p in edgePoints(shape, w, d, y, 1) do
			if i % 2 == 0 then
				B.ball("TrimBead", 0.18, p.X, p.Y, p.Z, P.glow, M.habitatGlow)
			end
		end
		if spots and y1 and legG ~= 6 then
			for _, s in spots do
				B.ball("TrimBead", 0.24, s.X, y1 - 0.18, s.Z, P.glow, M.habitatGlow)
			end
		end
	end
end

---------------------------------------------------------------- kinds

local KINDS = {}

-- Planner hints (RoomPlanner) for each kind.
FurnitureGrammar.PLACE = {
	dchair = { place = "free", access = 1 },
	dstool = { place = "free", access = 0 },
	dtable = { place = "free", access = 0 },
	dbench = { place = "wall", access = 1.2, corner = 0.4 },
	dbed = { place = "wall", walls = { back = 1, left = 1, right = 1, front = 0.3 }, corner = 0.9, along = true, access = 1.6, sleeps = true },
	dlamp = { place = "wall", corner = 1, access = 0 },
	dshelf = { place = "wall", corner = 0.3, access = 1.6 },
}

KINDS.dchair = {
	params = function(d, s, k)
		local W, D = 2.4 * s + (k - 1) * 0.3, 2.3 * s
		local seatY = 1.55 + (s - 1) * 0.6
		local backH = if d.back == 1 then 0 else 2.2 * s
		return { w = W, d = D, h = seatY + backH + 0.2, W = W, D = D, seatY = seatY, backH = backH }
	end,
	build = function(B, P, d, p, k)
		local W, D, seatY = p.W, p.D, p.seatY
		local t = 0.22 * k + 0.08
		local dia = 0.3 * k
		local spots = legSpots(d.shape, W, D, dia * 0.7 + 0.12, 4)
		legs(B, P, d.legs, spots, 0, seatY - t, dia, math.min(W, D) * 0.7)
		top(B, "ChairSeat", d.shape, W, D, t, seatY - t / 2, P.top, P.topMat)
		if k >= 1 then
			B.slab("ChairCushion", W * 0.72, 0.16, D * 0.68, 0, seatY + 0.08, -0.05, P.cloth, FABRIC, false, math.min(W, D) * 0.2)
		end
		back(B, P, d.back, W * 0.92, p.backH, seatY, D / 2 - 0.2, dia)
		trim(B, P, d.trim, d.shape, W, D, seatY - t / 2, spots, d.legs, 0, seatY - t)
	end,
}

KINDS.dstool = {
	params = function(d, s, k)
		local W = 1.7 * s + (k - 1) * 0.25
		local seatY = 1.5 + (s - 1) * 0.5
		return { w = W, d = W, h = seatY + 0.2, W = W, D = W, seatY = seatY }
	end,
	build = function(B, P, d, p, k)
		local W, seatY = p.W, p.seatY
		local t = 0.24 * k + 0.1
		local dia = 0.28 * k
		local three = d.legs == 4 or d.legs == 5 or d.shape == 3
		local spots = legSpots(d.shape, W, W, dia * 0.7 + 0.1, if three then 3 else 4)
		if d.legs == 3 then
			-- a stalk stool stands on one stalk, like a mushroom
			legs(B, P, 3, { Vector3.zero }, 0, seatY - t, dia * 1.6, W)
		else
			legs(B, P, d.legs, spots, 0, seatY - t, dia, W * 0.8)
		end
		top(B, "StoolSeat", d.shape, W, W, t, seatY - t / 2, P.top, P.topMat)
		if d.shape == 3 then
			B.egg("StoolDome", W, 0.3 * k, W, 0, seatY, 0, P.top, P.topMat)
		end
		trim(B, P, d.trim, d.shape, W, W, seatY - t / 2 + (if d.shape == 3 then 0.12 else 0), spots, d.legs, 0, seatY - t)
	end,
}

KINDS.dtable = {
	params = function(d, s, k)
		local W, D
		if d.size == 1 then
			W, D = 3.4, 3.4
		elseif d.size == 2 then
			W, D = 4.6, 3.4
		else
			W, D = 6, 3.8
		end
		if d.shape == 3 and d.size == 1 then
			D = W
		end
		local topY = 2.6
		return { w = W, d = D, h = topY + 0.2, W = W, D = D, topY = topY }
	end,
	build = function(B, P, d, p, k)
		local W, D, topY = p.W, p.D, p.topY
		local t = 0.2 * k + 0.1
		local dia = 0.34 * k
		local spots = legSpots(d.shape, W, D, dia * 0.7 + 0.3, if d.size == 3 and d.legs ~= 6 then 6 else 4)
		legs(B, P, d.legs, spots, 0, topY - t, dia, math.min(W, D) * 0.55)
		-- an apron under the top, between square-set legs
		if d.legs ~= 6 and (d.shape == 1 or d.shape == 2 or d.shape == 6) then
			local ay = topY - t - 0.18
			local ax, az = math.abs(spots[1].X), math.abs(spots[1].Z)
			for _, sz in { -1, 1 } do
				B.box("TableApron", 2 * ax, 0.3, 0.12, 0, ay, sz * az, shade(P.frame, -0.08), P.frameMat)
			end
			for _, sx in { -1, 1 } do
				B.box("TableApron", 0.12, 0.3, 2 * az, sx * ax, ay, 0, shade(P.frame, -0.08), P.frameMat)
			end
		end
		top(B, "TableTop", d.shape, W, D, t, topY - t / 2, P.top, P.topMat)
		trim(B, P, d.trim, d.shape, W, D, topY - t / 2, spots, d.legs, 0, topY - t)
	end,
}

KINDS.dbench = {
	params = function(d, s, k)
		local W, D = 5 * s, 1.9 + (k - 1) * 0.2
		local seatY = 1.45
		local backH = if d.back == 1 then 0 else 1.8 * s
		return { w = W, d = D, h = seatY + backH + 0.2, W = W, D = D, seatY = seatY, backH = backH }
	end,
	build = function(B, P, d, p, k)
		local W, D, seatY = p.W, p.D, p.seatY
		local t = 0.24 * k + 0.08
		local dia = 0.3 * k
		local spots = legSpots(1, W, D, dia * 0.7 + 0.25, if d.size == 3 then 6 else 4)
		if d.legs == 6 then
			-- two pedestals, one under each end
			for _, sx in { -1, 1 } do
				local o = Vector3.new(sx * W * 0.3, 0, 0)
				B.cyl("Pedestal", D * 0.8, o.X, 0, 0.15, 0, shade(P.frame, -0.15), P.frameMat, true)
				B.cyl("Pedestal", dia * 2.2, o.X, 0.15, seatY - t, 0, P.frame, P.frameMat)
			end
		else
			legs(B, P, d.legs, spots, 0, seatY - t, dia, D)
		end
		top(B, "BenchSeat", d.shape, W, D, t, seatY - t / 2, P.top, P.topMat)
		if k >= 1 then
			B.slab("BenchCushion", W * 0.85, 0.14, D * 0.62, 0, seatY + 0.07, -0.05, P.cloth, FABRIC, false, 0.3)
		end
		back(B, P, d.back, W * 0.95, p.backH, seatY, D / 2 - 0.18, dia)
		trim(B, P, d.trim, d.shape, W, D, seatY - t / 2, spots, d.legs, 0, seatY - t)
	end,
}

KINDS.dbed = {
	params = function(d, s, k)
		local W, L = 4 * s, 7.2 * s
		local H = if d.back == 1 then 1.2 else 3.4 * s
		return { w = W + 0.1, d = L + 0.2, h = 1.2 + H, W = W, L = L, H = H }
	end,
	build = function(B, P, d, p, k)
		local W, L = p.W, p.L
		local legH = 0.55
		local t = 0.35 * k + 0.2
		local dia = 0.42 * k
		local spots = legSpots(1, W, L, dia * 0.6 + 0.3, if d.size == 3 then 6 else 4)
		if d.legs == 6 then
			B.box("BedPlinth", W * 0.8, legH, L * 0.8, 0, legH / 2, 0, shade(P.frame, -0.2), P.frameMat)
		else
			legs(B, P, d.legs, spots, 0, legH, dia, W * 0.6)
		end
		top(B, "BedFrame", d.shape, W, L - 0.3, t, legH + t / 2, P.frame, P.frameMat, -0.1)
		local my = legH + t + 0.28
		local mattress = B.slab("BedMattress", W - 0.4, 0.55, L - 0.8, 0, my, -0.15, CREAM:Lerp(P.cloth, 0.2), FABRIC, true, 0.35)
		local bl = (L - 0.8) * 0.6
		local bz = -0.15 - (L - 0.8) / 2 + bl / 2
		B.slab("BedBlanket", W - 0.15, 0.22, bl, 0, my + 0.34, bz - 0.05, P.cloth, FABRIC, false, 0.3)
		B.box("BedHem", W - 0.1, 0.3, 0.5, 0, my + 0.38, bz + bl / 2 - 0.25, P.trim, FABRIC)
		B.egg("BedPillow", W * 0.6, 0.7, 1.3, 0, my + 0.5, L / 2 - 1.25, CREAM, FABRIC)
		local headY = legH
		if d.back == 1 then
			B.slab("BedHead", W, 0.3, 1.2, 0, headY + 0.6, L / 2 - 0.15, P.top, P.topMat, true, 0.12, CFrame.Angles(math.pi / 2, 0, 0))
		else
			back(B, P, d.back, W + 0.1, p.H, headY, L / 2 - 0.2, dia)
		end
		-- a low footboard on heavier beds
		if k >= 1 and d.back ~= 1 then
			back(B, P, d.back, W, 1.3, headY, -L / 2 + 0.1, dia * 0.8, true)
		end
		trim(B, P, d.trim, d.shape, W, L - 0.3, legH + t / 2, spots, d.legs, 0, legH)
		return { mattress }
	end,
}

KINDS.dlamp = {
	params = function(d, s, k)
		local H = 4.6 * s
		return { w = 1.8, d = 1.8, h = H + 0.8, H = H }
	end,
	build = function(B, P, d, p, k, n)
		local H = p.H
		local dia = 0.26 * k
		local base = 1.1 + (k - 1) * 0.4
		-- the stem: the legs rule makes it a post, turned, stalk, twig, reed or pedestal
		B.cyl("LampBase", base, 0, 0, 0.18, 0, shade(P.frame, -0.15), P.frameMat, true)
		if d.legs == 6 then
			legs(B, P, 6, {}, 0, H - 0.4, dia, base)
		else
			legs(B, P, d.legs, { Vector3.zero }, 0.18, H - 0.4, dia, base)
		end
		-- the shade over a glowing bulb
		local bulb = B.ball("LampBulb", 0.6, 0, H - 0.35, 0, P.glow, M.habitatGlow)
		B.light(bulb, P.glow, 0.9, 12)
		local sy = H - 0.2
		local sw = 1.6 + (k - 1) * 0.3
		local col, mat = P.top, P.topMat
		if d.shape == 1 then
			B.box("LampShade", sw, 0.9, sw, 0, sy + 0.2, 0, col, mat)
		elseif d.shape == 2 then
			B.cyl("LampShade", sw, 0, sy - 0.2, sy + 0.4, 0, col, mat)
			B.egg("LampShade", sw, 0.5, sw, 0, sy + 0.4, 0, shade(col, 0.1), mat)
		elseif d.shape == 3 then
			B.egg("LampShade", sw * 1.1, 1.1, sw * 1.1, 0, sy + 0.25, 0, col, mat)
			B.cyl("LampShadeRim", sw * 1.05, 0, sy - 0.05, sy + 0.05, 0, shade(col, -0.15), mat)
		elseif d.shape == 4 then
			-- a leaf bowed over the bulb
			B.egg("LampShade", sw * 1.3, 0.2, sw * 0.9, 0, sy + 0.35, 0, col, mat, CFrame.Angles(0, 0, 0.25))
			B.rod("LampStalk", Vector3.new(0, H - 0.4, 0), Vector3.new(-sw * 0.4, sy + 0.4, 0), dia * 0.5, P.leaf, M.stem)
		elseif d.shape == 5 then
			-- a cup of petals
			for i = 0, 5 do
				local a = i / 6 * TAU
				B.egg("LampShade", 0.75, 1, 0.3, math.cos(a) * 0.5, sy + 0.25, math.sin(a) * 0.5, if i % 2 == 0 then col else shade(col, 0.18), mat, CFrame.Angles(0, -a, 0) * CFrame.Angles(0, 0, -0.45))
			end
		else
			hex(B, "LampShade", sw / 2, 0.9, 0, sy + 0.2, 0, col, mat)
		end
		trim(B, P, d.trim, if d.shape == 6 then 6 else 3, sw, sw, sy - 0.15)
	end,
}

KINDS.dshelf = {
	params = function(d, s, k)
		local W, H, D = 3.6 * s, 5.2 * s, 1.4
		local crest = if d.back == 1 then 0 else 0.9
		return { w = W + 0.3, d = D + 0.2, h = H + crest + 0.3, W = W, H = H, D = D, rows = if H > 5 then 4 else 3, crest = crest }
	end,
	build = function(B, P, d, p, k, n)
		local W, H, D = p.W, p.H, p.D
		local T = 0.16 * k + 0.06
		local col, mat = P.frame, P.frameMat
		local rng = Random.new(n)
		-- the sides: panels for posts, or four poles of the legs rule
		if d.legs == 1 then
			for _, sx in { -1, 1 } do
				B.box("ShelfSide", T, H, D, sx * (W / 2 - T / 2), H / 2, 0, col, mat, true)
			end
		else
			local poles = { Vector3.new(-W / 2 + 0.15, 0, -D / 2 + 0.15), Vector3.new(W / 2 - 0.15, 0, -D / 2 + 0.15), Vector3.new(-W / 2 + 0.15, 0, D / 2 - 0.15), Vector3.new(W / 2 - 0.15, 0, D / 2 - 0.15) }
			legs(B, P, if d.legs == 6 then 2 else d.legs, poles, 0, H, 0.28 * k, 1)
		end
		B.box("ShelfBack", W - 0.1, H - 0.2, 0.1, 0, H / 2, D / 2 - 0.08, shade(col, -0.3), mat, true)
		-- the boards: the top board takes the shape rule
		local gap = (H - 0.3) / p.rows
		for i = 0, p.rows - 1 do
			local y = 0.25 + i * gap
			B.box("ShelfBoard", W - 0.1, T, D - 0.1, 0, y, 0, P.top, P.topMat, true)
			-- books
			if i > 0 or d.legs ~= 1 then
				local x = -W / 2 + 0.3
				while x < W / 2 - 0.5 do
					local bw = rng:NextNumber(0.18, 0.34)
					local bh = math.min(gap - 0.25, rng:NextNumber(0.75, 1.15))
					local pick = rng:NextInteger(1, 4)
					local bc = if pick == 1 then P.cloth elseif pick == 2 then P.trim elseif pick == 3 then shade(P.cloth, -0.3) else shade(P.top, -0.25)
					if rng:NextNumber() < 0.85 then
						B.box("ShelfBook", bw, bh, D * 0.6, x + bw / 2, y + T / 2 + bh / 2, 0.05, bc, FABRIC)
					end
					x += bw + 0.03
				end
			end
		end
		top(B, "ShelfTop", d.shape, W + 0.3, D + 0.2, T + 0.06, H + T / 2, P.top, P.topMat)
		if p.crest > 0 then
			back(B, P, d.back, W * 0.8, p.crest, H + T, D / 2 - 0.2, 0.22 * k, true)
		end
		trim(B, P, d.trim, d.shape, W + 0.3, D + 0.2, H + T / 2)
	end,
}

FurnitureGrammar.KINDS = KINDS

---------------------------------------------------------------- the grammar's entry points

-- A design and its recipe for `recipe`, or rolled from `rng` when there is none.
function FurnitureGrammar.design(recipe: string?, rng: Random?): (FurnitureRules.Design, string)
	local d = if recipe then FurnitureRules.decode(recipe) else nil
	if not d then
		local r = rng or Random.new(1)
		d = FurnitureRules.roll(function(lo, hi)
			return r:NextInteger(lo, hi)
		end)
	end
	local dd = d :: FurnitureRules.Design
	return dd, FurnitureRules.encode(dd)
end

-- The procedural sizes of a designed piece (RoomPlanner reads w, d, h).
function FurnitureGrammar.params(id: string, recipe: string?, rng: Random?): any
	local kind = KINDS[id]
	local d, r = FurnitureGrammar.design(recipe, rng)
	local p = kind.params(d, SIZE[d.size], WEIGHT[d.weight])
	p.design = d
	p.recipe = r
	return p
end

-- Grows a designed piece with builder B in colours c (the plant's).
function FurnitureGrammar.build(id: string, B, c: any, p: any): any
	local kind = KINDS[id]
	local d = p.design
	local P = FurnitureGrammar.palette(d, c)
	return kind.build(B, P, d, p, WEIGHT[d.weight], FurnitureRules.hash(p.recipe))
end

return FurnitureGrammar
