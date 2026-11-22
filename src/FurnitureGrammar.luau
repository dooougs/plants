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
local function edgePointsAt(shape: number, w: number, d: number, y: number, spacing: number): { Vector3 }
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
-- `oz` moves the outline back (+Z) for a top that isn't centred; `ring`
-- keeps Dots to a ring round the edge (a top with things standing on it).
local function trim(B, P, g: number, shape: number, w: number, d: number, y: number, spots: { Vector3 }?, legG: number?, y0: number?, y1: number?, oz: number?, ring: boolean?)
	if g == 1 then
		return
	end
	local function edgePoints(sh: number, ww: number, dd: number, yy: number, spacing: number): { Vector3 }
		local pts = edgePointsAt(sh, ww, dd, yy, spacing)
		if oz and oz ~= 0 then
			for i, q in pts do
				pts[i] = q + Vector3.new(0, 0, oz)
			end
		end
		return pts
	end
	if g == 2 then
		-- a skirt of little petals under the edge
		for _, p in edgePoints(shape, w * 0.98, d * 0.98, y - 0.12, 0.55) do
			local a = math.atan2(p.Z, p.X)
			B.egg("TrimPetal", 0.5, 0.32, 0.36, p.X, p.Y, p.Z, if (math.floor(a * 4) % 2) == 0 then P.trim else shade(P.trim, 0.2), M.petal, CFrame.Angles(0, -a, 0) * CFrame.Angles(0, 0, -0.5))
		end
	elseif g == 3 then
		-- dots on the top, just inside its edge (a mushroom cap's spots)
		if ring then
			for _, p in edgePoints(shape, w * 0.98, d * 0.98, y, 0.7) do
				B.ball("TrimDot", 0.22, p.X, p.Y, p.Z, P.trim, SMOOTH)
			end
			return
		end
		local pts = edgePoints(shape, w * 0.62, d * 0.62, y + 0.02, 0.9)
		for i, p in pts do
			if i % 2 == 1 or #pts <= 6 then
				B.egg("TrimDot", 0.34, 0.08, 0.34, p.X, p.Y, p.Z, P.trim, SMOOTH)
			end
		end
		B.egg("TrimDot", 0.42, 0.08, 0.42, 0, y + 0.02, oz or 0, P.trim, SMOOTH)
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
	dstall = { place = "wall", corner = 0.2, access = 2.5 },
	dcounter = { place = "wall", corner = 0.3, access = 2 },
	dsign = { place = "free", access = 1.5 },
	dsofa = { place = "wall", access = 1.4, corner = 0.3 },
	dnightstand = { place = "wall", corner = 0.6, access = 0.3 },
	dscreen = { place = "wall", corner = 0.9, access = 0.3 },
	dpole = { place = "free", access = 0 },
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
			-- a square shade: four panels leaning in to a narrow top, open
			-- below so the bulb glows out of it, a band round its hem and a
			-- knob on top (not a solid box, which read as a sign on a post)
			local a, b, ht = sw / 2, sw * 0.3, 0.95
			local y0 = H - 0.25
			local lean = math.atan((a - b) / ht)
			local slant = math.sqrt(ht * ht + (a - b) ^ 2)
			for i = 0, 3 do
				local yaw = i * TAU / 4
				local r = (a + b) / 2
				B.box("LampShade", 0.08, slant, a + b + 0.06, math.cos(yaw) * r, y0 + ht / 2, -math.sin(yaw) * r, if i % 2 == 0 then col else shade(col, 0.08), mat, false, CFrame.Angles(0, yaw, 0) * CFrame.Angles(0, 0, lean))
			end
			B.box("LampShadeTop", b * 2 + 0.06, 0.08, b * 2 + 0.06, 0, y0 + ht, 0, shade(col, -0.1), mat)
			B.ball("LampFinial", 0.24, 0, y0 + ht + 0.14, 0, shade(P.frame, 0.1), P.frameMat)
			for i = 0, 3 do
				local yaw = i * TAU / 4
				B.box("LampShadeRim", 0.1, 0.1, a * 2 + 0.12, math.cos(yaw) * (a + 0.02), y0 + 0.05, -math.sin(yaw) * (a + 0.02), shade(col, -0.2), mat, false, CFrame.Angles(0, yaw, 0))
			end
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

-- A sofa: Feet(legs) + Base + Cushions(shape) + Arms + Back(back rule) + Trim.
-- Soft and deep, for lounges and fires; it seats one at its middle.
KINDS.dsofa = {
	params = function(d, s, k)
		local W, D = 4.8 * s, 2.5
		local seatY = 1.5
		local backH = if d.back == 1 then 1 else 1.9 * s
		return { w = W, d = D, h = seatY + backH + 0.2, W = W, D = D, seatY = seatY, backH = backH }
	end,
	build = function(B, P, d, p, k)
		local W, D, seatY = p.W, p.D, p.seatY
		local dia = 0.3 * k
		local footH = 0.4
		local spots = legSpots(1, W, D, dia * 0.7 + 0.25, if d.size == 3 then 6 else 4)
		if d.legs == 6 then
			B.box("SofaPlinth", W * 0.9, footH, D * 0.85, 0, footH / 2, 0, shade(P.frame, -0.2), P.frameMat, true)
		else
			legs(B, P, d.legs, spots, 0, footH, dia * 1.2, D)
		end
		local round = if d.shape == 1 or d.shape == 6 then 0.1 elseif d.shape == 2 then 0.3 else 0.5
		local baseH = seatY - footH - 0.4
		B.slab("SofaBase", W, baseH, D, 0, footH + baseH / 2, 0, P.top, P.topMat, true, round)
		-- the cushions: two or three across, in the shape rule's outline
		local n = if d.size == 3 then 3 else 2
		local arm = 0.5 + (k - 1) * 0.15
		local cw = (W - 2 * arm) / n
		local up = CFrame.Angles(math.pi / 2, 0, 0)
		for i = 0, n - 1 do
			local x = -W / 2 + arm + cw * (i + 0.5)
			if d.shape == 4 then
				B.egg("SofaCushion", cw * 1.02, 0.46, D * 0.82, x, seatY - 0.2, -0.12, P.cloth, FABRIC)
			elseif d.shape == 5 then
				B.slab("SofaCushion", cw - 0.06, 0.42, D * 0.78, x, seatY - 0.2, -0.12, if i % 2 == 0 then P.cloth else shade(P.cloth, 0.12), FABRIC, true, math.min(cw, D) * 0.4)
			else
				B.slab("SofaCushion", cw - 0.06, 0.42, D * 0.78, x, seatY - 0.2, -0.12, P.cloth, FABRIC, true, round * 0.7)
			end
			B.slab("SofaBackCushion", cw - 0.1, 0.5, p.backH * 0.8, x, seatY + p.backH * 0.4, D / 2 - 0.45, shade(P.cloth, -0.06), FABRIC, false, 0.25, up)
		end
		-- the arms
		local armH = 0.85
		for _, sx in { -1, 1 } do
			B.slab("SofaArm", arm, armH, D, sx * (W / 2 - arm / 2), seatY - 0.4 + armH / 2, 0, P.top, P.topMat, true, math.min(arm, armH) * 0.45)
		end
		-- the frame behind, in the back rule (none: a plain low back)
		if d.back == 1 then
			B.slab("SofaBack", W, p.backH, 0.4, 0, seatY - 0.4 + p.backH / 2 + 0.2, D / 2 - 0.2, P.top, P.topMat, true, 0.15)
		else
			B.slab("SofaBack", W, p.backH * 0.7, 0.35, 0, seatY - 0.4 + p.backH * 0.35 + 0.2, D / 2 - 0.18, P.top, P.topMat, true, 0.12)
			back(B, P, d.back, W * 0.96, p.backH, seatY, D / 2 - 0.05, dia)
		end
		trim(B, P, d.trim, 1, W, D, footH + baseH, spots, d.legs, 0, footH, nil, true)
	end,
}

-- A bedside table: Legs + Body(drawer) + Top(shape) + Trim. Small, by a bed.
KINDS.dnightstand = {
	params = function(d, s, k)
		local W, D, H = 1.8 * s, 1.6, 2.3
		return { w = W + 0.2, d = D + 0.2, h = H + 0.2, W = W, D = D, H = H }
	end,
	build = function(B, P, d, p, k)
		local W, D, H = p.W, p.D, p.H
		local t = 0.14 * k + 0.06
		local dia = 0.22 * k
		local legH = 0.7
		local spots = legSpots(1, W, D, dia * 0.6 + 0.12, 4)
		if d.legs == 6 then
			legs(B, P, 6, {}, 0, legH, dia, math.min(W, D) * 0.8)
		else
			legs(B, P, d.legs, spots, 0, legH, dia, D)
		end
		local bodyH = H - t - legH
		B.box("StandBody", W - 0.1, bodyH, D - 0.1, 0, legH + bodyH / 2, 0, P.frame, P.frameMat, true)
		B.box("StandDrawer", W - 0.4, bodyH * 0.55, 0.06, 0, legH + bodyH * 0.6, -D / 2 + 0.02, shade(P.top, -0.06), P.topMat)
		B.ball("StandKnob", 0.18, 0, legH + bodyH * 0.6, -D / 2 - 0.06, P.trim, SMOOTH)
		top(B, "StandTop", d.shape, W + 0.2, D + 0.2, t, H - t / 2, P.top, P.topMat)
		trim(B, P, d.trim, d.shape, W + 0.2, D + 0.2, H - t / 2, spots, d.legs, 0, legH, nil, true)
	end,
}

-- A folding screen: Frame(legs rule posts) + Panels(cloth) + Tops(shape) + Trim.
-- Three or four panels folded in a zigzag; it shares off a corner of a room.
KINDS.dscreen = {
	params = function(d, s, k)
		local n = if d.size == 3 then 4 else 3
		local pw = 1.5 * (if d.size == 1 then 0.9 else 1)
		local H = 4.8
		return { w = n * pw * 0.95, d = 1.3, h = H + 0.6, n = n, pw = pw, H = H }
	end,
	build = function(B, P, d, p, k)
		local n, pw, H = p.n, p.pw, p.H
		local dia = 0.2 * k
		local fold = 0.42
		local step = pw * math.cos(fold)
		local x0 = -step * n / 2
		local edges = {}
		for i = 0, n - 1 do
			local yaw = if i % 2 == 0 then fold else -fold
			local cx = x0 + step * (i + 0.5)
			local rot = CFrame.Angles(0, yaw, 0)
			B.box("ScreenPanel", pw - dia, H - 0.7, 0.08, cx, 0.35 + (H - 0.7) / 2, 0, if i % 2 == 0 then P.cloth else shade(P.cloth, 0.1), FABRIC, true, rot)
			local cf = CFrame.new(cx, 0, 0) * rot
			local a = cf * Vector3.new(-pw / 2, 0, 0)
			local b = cf * Vector3.new(pw / 2, 0, 0)
			if i == 0 then
				table.insert(edges, Vector3.new(a.X, 0, a.Z))
			end
			table.insert(edges, Vector3.new(b.X, 0, b.Z))
			-- each panel's top, in the shape rule
			local ty = H - 0.25
			local col, mat = P.top, P.topMat
			if d.shape == 1 or d.shape == 6 then
				B.box("ScreenTop", pw, 0.22, 0.16, cx, ty, 0, col, mat, false, rot)
			elseif d.shape == 2 or d.shape == 3 then
				B.egg("ScreenTop", pw * 0.95, 0.7, 0.14, cx, ty + 0.1, 0, col, mat, rot)
			elseif d.shape == 4 then
				B.egg("ScreenTop", pw * 0.7, 1, 0.1, cx, ty + 0.3, 0, P.leaf, M.leaf, rot * CFrame.Angles(0, 0, 0.3))
			else
				for j = -1, 1 do
					B.egg("ScreenTop", 0.5, 0.7, 0.1, cx + j * pw * 0.28 * math.cos(yaw), ty + 0.2, -j * pw * 0.28 * math.sin(yaw), if j == 0 then P.trim else col, M.petal, rot)
				end
			end
			B.box("ScreenRail", pw, 0.12, 0.12, cx, 0.32, 0, col, mat, false, rot)
		end
		-- the frame: a post at every fold, in the legs rule
		legs(B, P, if d.legs == 6 then 2 else d.legs, edges, 0, H, dia, 1)
		trim(B, P, d.trim, 1, step * n, 0.3, H - 0.1, nil, nil, nil, nil, nil, true)
	end,
}

-- A market stall: Legs + Table(top) + Backboard(back) + Posts + Awning(shape) + Trim.
-- The stall's front (-Z) is where you shop; the awning leans out over it.
KINDS.dstall = {
	params = function(d, s, k)
		local W = if d.size == 1 then 4.4 elseif d.size == 2 then 5 else 5.6
		local D, topY = 2.6, 2.6
		return { w = W + 0.4, d = D + 0.8, h = 7.6, W = W, D = D, topY = topY, awningY = 6.6 }
	end,
	build = function(B, P, d, p, k, n)
		local W, D, topY = p.W, p.D, p.topY
		local t = 0.22 * k + 0.2
		local dia = 0.32 * k
		local spots = legSpots(1, W, D, dia * 0.7 + 0.2, 4)
		legs(B, P, if d.legs == 6 then 1 else d.legs, spots, 0, topY - t, dia, D)
		top(B, "StallTable", d.shape, W, D, t, topY - t / 2, P.top, P.topMat)
		-- two posts at the back hold the awning
		local postZ = D / 2 - 0.15
		local ay = p.awningY
		for _, sx in { -1, 1 } do
			B.cyl("StallPost", dia * 0.9, sx * (W / 2 - 0.15), topY, ay + 0.2, postZ, P.frame, P.frameMat)
		end
		-- a backboard between them, in the back rule (none: open)
		back(B, P, d.back, W - 0.4, math.min(2.4, ay - topY - 1.2), topY + 0.2, postZ + 0.05, dia * 0.8, true)
		-- the awning: striped slats leaning out, edged in the shape rule
		local slats = 6
		local sw = (W + 0.4) / slats
		local tilt = CFrame.Angles(math.rad(-18), 0, 0)
		local lean = 3.2
		local fz = postZ - lean * math.cos(math.rad(18)) + 0.15
		local fy = ay - lean * math.sin(math.rad(18))
		for i = 0, slats - 1 do
			local x = -(W + 0.4) / 2 + sw * (i + 0.5)
			local col = if i % 2 == 0 then P.cloth else P.trim
			B.box("StallAwning", sw, 0.22, lean, x, ay - lean / 2 * math.sin(math.rad(18)), postZ - lean / 2 * math.cos(math.rad(18)) + 0.15, col, FABRIC, false, tilt)
			-- the valance hanging off the front edge
			local vx, vy, vz = x, fy - 0.2, fz
			if d.shape == 1 then
				B.box("StallValance", sw, 0.5, 0.1, vx, vy, vz, col, FABRIC)
			elseif d.shape == 2 then
				B.slab("StallValance", sw - 0.04, 0.1, 0.6, vx, vy, vz, col, FABRIC, false, 0.25, CFrame.Angles(math.pi / 2, 0, 0))
			elseif d.shape == 3 then
				B.logZ("StallValance", 0.1, sw * 0.98, vx, vy, vz, col, FABRIC)
			elseif d.shape == 4 then
				B.egg("StallValance", sw * 0.9, 0.9, 0.08, vx, vy - 0.1, vz, P.leaf, M.leaf)
			elseif d.shape == 5 then
				B.egg("StallValance", sw * 0.95, 0.75, 0.1, vx, vy - 0.05, vz, if i % 2 == 0 then P.trim else P.cloth, M.petal)
			else
				B.box("StallValance", sw * 0.6, 0.55, 0.1, vx, vy, vz, col, FABRIC, false, CFrame.Angles(0, 0, math.pi / 4))
			end
		end
		B.logX("StallRail", W + 0.4, 0.14, 0, fy, fz, P.frame, P.frameMat)
		trim(B, P, d.trim, d.shape, W, D, topY - t / 2, spots, d.legs, 0, topY - t, nil, true)
		return { topY = topY }
	end,
}

-- A counter: Feet(legs) + Carcass + Front(back rule, facing you) + Top(shape) + Trim.
-- The customer's side is the front (-Z). Small, medium or large by its size.
KINDS.dcounter = {
	params = function(d, s, k)
		local W = if d.size == 1 then 5.6 elseif d.size == 2 then 8 else 9.6
		local D, topY = 2.5, 3.2
		return { w = W + 0.6, d = D + 0.6, h = topY + 0.3, W = W, D = D, topY = topY }
	end,
	build = function(B, P, d, p, k, n)
		local W, D, topY = p.W, p.D, p.topY
		local t = 0.2 * k + 0.2
		local foot = if d.legs == 1 then 0.25 else 0.45
		-- feet: a plinth for posts and pedestals, little legs of the rule otherwise
		if d.legs == 1 or d.legs == 6 then
			B.box("CounterPlinth", W - 0.3, foot, D - 0.3, 0, foot / 2, 0, shade(P.frame, -0.25), P.frameMat, true)
		else
			legs(B, P, d.legs, legSpots(1, W, D, 0.35, if W > 7 then 6 else 4), 0, foot, 0.4 * k, D)
		end
		local bodyH = topY - t - foot
		B.box("CounterBody", W, bodyH, D, 0, foot + bodyH / 2, 0, P.frame, P.frameMat, true)
		B.box("CounterKick", W - 0.2, 0.2, 0.08, 0, foot + 0.12, -D / 2 - 0.03, shade(P.frame, -0.2), P.frameMat)
		-- the front panels, one per bay, and the front's ornament in the back rule
		local bays = math.max(2, math.floor(W / 2.6 + 0.5))
		local bw = W / bays
		for i = 0, bays - 1 do
			local x = -W / 2 + bw * (i + 0.5)
			B.box("CounterPanel", bw - 0.35, bodyH - 0.5, 0.06, x, foot + bodyH / 2, -D / 2 - 0.02, shade(P.top, -0.08), P.topMat)
		end
		back(B, P, d.back, W - 0.6, bodyH - 0.9, foot + 0.3, -D / 2 - 0.12, 0.18 * k, true)
		local from = #B.parts
		top(B, "CounterTop", d.shape, W + 0.6, D + 0.5, t, topY - t / 2, P.top, P.topMat)
		local topPart = B.parts[from + 1]
		trim(B, P, d.trim, d.shape, W + 0.6, D + 0.5, topY - t / 2, nil, nil, nil, nil, nil, true)
		return { topY = topY, top = topPart }
	end,
}

-- A sign board's outline in its own plane (x across, dy up from its middle),
-- by the shape rule: how far up and down it reaches (H) and how wide it is
-- at each height (half). The sign's other rules read it so that nothing
-- they add sticks out past the board or crosses the panel written on.
local function signOutline(shape: number, W: number, bh: number): (number, (number) -> number)
	local function ellipse(a: number, b: number, dy: number): number
		local q = dy / b
		return if math.abs(q) >= 1 then 0 else a * math.sqrt(1 - q * q)
	end
	local function rounded(w: number, h: number, r: number, dy: number): number
		local rr = math.min(r, w / 2 - 0.01, h / 2 - 0.01)
		local e = math.abs(dy) - (h / 2 - rr)
		if math.abs(dy) > h / 2 then
			return 0
		end
		return if e <= 0 then w / 2 else w / 2 - rr + math.sqrt(math.max(rr * rr - e * e, 0))
	end
	if shape == 1 then
		return bh / 2 + 0.1, function(dy)
			return if math.abs(dy) <= bh / 2 + 0.1 then W / 2 else 0
		end
	elseif shape == 2 then
		return bh / 2, function(dy)
			return rounded(W, bh, math.min(W, bh) * 0.3, dy)
		end
	elseif shape == 3 or shape == 4 then
		local a, b = if shape == 3 then W * 0.54 else W * 0.56, if shape == 3 then bh * 0.575 else bh * 0.55
		return b, function(dy)
			local box = if math.abs(dy) <= bh * 0.35 then W * 0.35 else 0
			return math.max(box, ellipse(a, b, dy))
		end
	elseif shape == 5 then
		return bh * 0.45, function(dy)
			return rounded(W * 0.92, bh * 0.9, math.min(W, bh) * 0.35, dy)
		end
	end
	local R = bh / SQRT3
	local tip = 0.72 * R / math.sqrt(2) -- the corner squares' half diagonal
	return bh / 2, function(dy)
		if math.abs(dy) > bh / 2 then
			return 0
		end
		return math.max((W - R) / 2, W / 2 - R / 2 + tip - math.abs(dy))
	end
end

-- Points every `spacing` round a sign's outline (see signOutline), each with
-- its outward normal, starting at the bottom middle.
local function signRim(H: number, half: (number) -> number, cy: number, spacing: number): { { p: Vector2, n: Vector2 } }
	local loop = {}
	local STEPS = 48
	for i = 0, STEPS do -- up the right side
		local dy = H * math.sin(-math.pi / 2 + math.pi * i / STEPS)
		table.insert(loop, Vector2.new(half(dy * 0.999), dy))
	end
	for i = STEPS, 0, -1 do -- down the left side
		local dy = H * math.sin(-math.pi / 2 + math.pi * i / STEPS)
		table.insert(loop, Vector2.new(-half(dy * 0.999), dy))
	end
	table.insert(loop, loop[1])
	local per = 0
	for i = 2, #loop do
		per += (loop[i] - loop[i - 1]).Magnitude
	end
	local n = math.max(6, math.floor(per / spacing))
	local step = per / n
	local out = {}
	local walked, want = 0, step / 2
	for i = 2, #loop do
		local a, b = loop[i - 1], loop[i]
		local len = (b - a).Magnitude
		while len > 1e-6 and want <= walked + len and #out < n do
			local q = a:Lerp(b, (want - walked) / len)
			local dir = (b - a) / len
			-- anticlockwise round the loop, so outward is the tangent turned right
			local nrm = Vector2.new(dir.Y, -dir.X)
			table.insert(out, { p = Vector2.new(q.X, q.Y + cy), n = nrm })
			want += step
		end
		walked += len
	end
	return out
end

-- A sign's ornament (the trim rule) round its board's rim, standing just
-- outside the outline so it shows from both sides, and kept off the face
-- (fx, fy, fw, fh: the panel written on, with a margin) and the topper.
local function signTrim(B, P, g: number, rim: { { p: Vector2, n: Vector2 } }, t: number, keep: (Vector2, number) -> boolean)
	if g == 1 then
		return
	end
	local prev: Vector3? = nil
	for i, q in rim do
		local p, nrm = q.p, q.n
		local a = math.atan2(nrm.Y, nrm.X)
		local function at(out: number): Vector2
			return p + nrm * out
		end
		if g == 2 then
			-- a ring of little petals, each pointing out from the rim
			local c = at(0.16)
			if keep(c, 0.3) then
				B.egg("SignTrimPetal", 0.5, 0.3, t + 0.08, c.X, c.Y, 0, if i % 2 == 0 then P.trim else shade(P.trim, 0.2), M.petal, CFrame.Angles(0, 0, a))
			end
		elseif g == 3 then
			-- dots along the edge
			local c = at(0.1)
			if i % 2 == 0 and keep(c, 0.2) then
				B.ball("SignTrimDot", math.min(t + 0.06, 0.4), c.X, c.Y, 0, P.trim, SMOOTH)
			end
		elseif g == 4 then
			-- a vine round the edge, with a leaf every third step
			local c = at(0.05)
			local here = Vector3.new(c.X, c.Y, 0)
			if keep(c, 0.12) then
				if prev and (here - prev).Magnitude < 1.5 then
					B.rod("SignTrimVine", prev, here, 0.1, P.leaf, M.stem)
				end
				if i % 3 == 0 then
					local l = at(0.2)
					B.egg("SignTrimLeaf", 0.44, 0.24, t * 0.6, l.X, l.Y, 0, P.leaf, M.leaf, CFrame.Angles(0, 0, a + 0.4))
				end
				prev = here
			else
				prev = nil
			end
		elseif g == 5 then
			-- honey dripping off the underside only, so it never runs over the writing
			if nrm.Y < -0.5 then
				local len = 0.18 + ((i * 37) % 5) * 0.07
				local c = at(0)
				if keep(Vector2.new(c.X, c.Y - len / 2), 0.15) then
					B.cyl("SignTrimDrip", 0.14, c.X, c.Y - len, c.Y + 0.05, 0, P.trim, SMOOTH)
					B.ball("SignTrimDrip", 0.2, c.X, c.Y - len, 0, P.trim, SMOOTH)
				end
			end
		else
			-- little glowing beads along the edge
			local c = at(0.08)
			if i % 2 == 0 and keep(c, 0.15) then
				B.ball("SignTrimBead", math.min(t, 0.3), c.X, c.Y, 0, P.glow, M.habitatGlow)
			end
		end
	end
end

-- A sign: Posts(legs) + Board(shape) + Topper(back rule) + Trim.
-- Town notice boards, the Town Bed's sign, building signposts. The board
-- faces the front (-Z); `face` is a flat panel on it for writing on, and
-- `back` the same panel on the far side. Every rule reads the board's
-- outline (signOutline): the face fits inside it, the posts stop where they
-- meet it, the topper stands on its top and the trim runs round its rim,
-- clear of the face, so nothing covers the writing or sticks out oddly.
KINDS.dsign = {
	params = function(d, s, k)
		local W = 6 * s
		local boardH = W * 0.55
		local postH = 3.6
		local crest = if d.back == 1 then 0 else 1.3
		local H = signOutline(d.shape, W, boardH)
		return { w = W + 1, d = 1.2, h = postH + boardH / 2 + H + crest + 0.5, W = W, boardH = boardH, postH = postH, crest = crest }
	end,
	build = function(B, P, d, p, k, n)
		local W, bh, ph = p.W, p.boardH, p.postH
		local t = 0.3 + 0.08 * k
		-- posts no thicker than the board, so they run hidden inside it
		local dia = math.min(0.34 * k, t - 0.04)
		local cy = ph + bh / 2
		local topY = ph + bh
		local H, half = signOutline(d.shape, W, bh)
		local postX = W / 2 - 0.45
		-- posts: two up the board's sides, or one pedestal under it
		if d.legs == 6 then
			legs(B, P, 6, {}, 0, cy - H + 0.15, dia, 1.8)
		else
			-- each post stops where it has gone well into the board
			local reach = 0
			for i = 0, 40 do
				local dy = (bh / 2 - 0.2) * i / 40
				if half(dy) >= postX + dia / 2 + 0.1 then
					reach = dy
				end
			end
			B.cyl("SignFoot", dia * 2.2, -postX, 0, 0.16, 0, shade(P.frame, -0.15), P.frameMat, true)
			B.cyl("SignFoot", dia * 2.2, postX, 0, 0.16, 0, shade(P.frame, -0.15), P.frameMat, true)
			legs(B, P, d.legs, { Vector3.new(-postX, 0, 0), Vector3.new(postX, 0, 0) }, 0, cy + reach, dia, 1)
		end
		-- the board, in the shape rule's outline
		local col, mat = P.top, P.topMat
		local edge = shade(col, -0.18)
		local up = CFrame.Angles(math.pi / 2, 0, 0)
		if d.shape == 1 then
			B.box("SignBoard", W, bh, t, 0, cy, 0, col, mat, true)
			B.box("SignBoardEdge", W + 0.2, 0.2, t + 0.06, 0, topY, 0, edge, mat)
			B.box("SignBoardEdge", W + 0.2, 0.2, t + 0.06, 0, ph, 0, edge, mat)
		elseif d.shape == 2 then
			B.slab("SignBoard", W, t, bh, 0, cy, 0, col, mat, true, math.min(W, bh) * 0.3, up)
		elseif d.shape == 3 then
			B.box("SignBoard", W * 0.7, bh * 0.7, t * 0.9, 0, cy, 0, col, mat, true)
			B.egg("SignBoard", W * 1.08, bh * 1.15, t, 0, cy, 0, col, mat)
		elseif d.shape == 4 then
			-- a leaf, with a midrib and veins kept inside its outline
			B.box("SignBoard", W * 0.7, bh * 0.7, t * 0.9, 0, cy, 0, col, mat, true)
			B.egg("SignBoard", W * 1.12, bh * 1.1, t, 0, cy, 0, col, mat)
			local rib = shade(col, 0.3)
			local ry = -bh * 0.4
			local rw = 2 * half(ry) - 0.5
			if rw > 0.5 then
				B.box("SignBoardRib", rw, 0.1, t + 0.04, 0, cy + ry, 0, rib, mat)
			end
			for i = -1, 1 do
				local vx = i * W * 0.22
				if math.abs(vx) + 0.6 < half(-bh * 0.32) then
					B.box("SignBoardVein", bh * 0.24, 0.08, t + 0.04, vx, cy - bh * 0.32, 0, rib, mat, false, CFrame.Angles(0, 0, 0.7))
				end
			end
		elseif d.shape == 5 then
			-- a scalloped flower edge round a soft board
			B.slab("SignBoard", W * 0.92, t, bh * 0.9, 0, cy, 0, col, mat, true, math.min(W, bh) * 0.35, up)
			local count = math.clamp(math.floor((W + bh) * 1.4), 10, 22)
			for i = 0, count - 1 do
				local a = i / count * TAU
				local px, py = math.cos(a) * W * 0.47, math.sin(a) * bh * 0.47
				B.egg("SignBoardPetal", 0.9, 0.7, t * 0.8, px, cy + py, 0, if i % 2 == 0 then col else shade(col, 0.15), mat, CFrame.Angles(0, 0, a))
			end
		else
			-- a hexagonal board: pointed at both ends
			local R = bh / SQRT3
			B.box("SignBoard", W - R, bh, t, 0, cy, 0, col, mat, true)
			for _, sx in { -1, 1 } do
				local x = sx * (W / 2 - R / 2)
				B.box("SignBoard", R * 0.72, R * 0.72, t * 0.98, x, cy, 0, col, mat, false, CFrame.Angles(0, 0, math.pi / 4))
			end
		end
		-- the panel written on: as big as fits inside the outline with a
		-- margin, a little in front of the board, and its twin on the back
		local margin = 0.25
		local fw, fh = W * 0.8, bh * 0.68
		-- (and clear of the posts' bulbs and rings where they cross the board)
		local clear = if d.legs == 6 then math.huge else postX - dia * 0.8 - 0.1
		for _ = 1, 24 do
			if fw / 2 <= half(fh / 2) - margin and fw / 2 <= half(-fh / 2) - margin and fw / 2 <= clear then
				break
			end
			fw *= 0.96
			fh *= 0.985
		end
		local faceCol = shade(col, 0.32)
		local fz = t / 2 + 0.06
		local from = #B.parts
		B.box("SignFace", fw, fh, 0.06, 0, cy, -fz, faceCol, SMOOTH)
		local face = B.parts[from + 1]
		B.box("SignFaceBack", fw, fh, 0.06, 0, cy, fz, faceCol, SMOOTH, false, CFrame.Angles(0, math.pi, 0))
		local backFace = B.parts[from + 2]
		-- the topper: the back rule standing on the board's top
		local boardTop = cy + H
		local tw = W * 0.7
		if p.crest > 0 then
			-- a narrow top (an oval's) carries a narrower topper
			tw = math.min(tw, math.max(2 * half(H - 0.25) + 0.6, W * 0.4))
			back(B, P, d.back, tw, p.crest, boardTop - 0.12, 0, dia * 0.7, true)
		end
		-- the trim round the rim, off the face and out from under the topper
		local fx0, fx1 = -fw / 2 - 0.15, fw / 2 + 0.15
		local fy0, fy1 = cy - fh / 2 - 0.15, cy + fh / 2 + 0.15
		local function keep(c: Vector2, r: number): boolean
			if c.X + r > fx0 and c.X - r < fx1 and c.Y + r > fy0 and c.Y - r < fy1 then
				return false
			end
			if p.crest > 0 and math.abs(c.X) < tw / 2 + r and c.Y > boardTop - 0.6 then
				return false
			end
			if d.legs ~= 6 and math.abs(math.abs(c.X) - postX) < dia / 2 + r and c.Y < cy then
				return false
			end
			return true
		end
		signTrim(B, P, d.trim, signRim(H, half, cy, 0.6), t, keep)
		return { face = face, back = backFace, faceW = fw, faceH = fh, topY = boardTop }
	end,
}

-- A pole: Foot + Pole(legs) + Arm(back rule) + Finial(shape) + Trim.
-- Washing-line posts and the like. `top` is where a line ties on.
KINDS.dpole = {
	params = function(d, s, k)
		local H = 8.8
		return { w = 1.6 * s + 0.6, d = 1.4, h = H + 1.2, H = H, arm = 1.6 * s }
	end,
	build = function(B, P, d, p, k, n)
		local H = p.H
		local dia = 0.36 * k
		local base = 1.2 + (k - 1) * 0.4
		B.cyl("PoleFoot", base, 0, 0, 0.2, 0, shade(P.frame, -0.15), P.frameMat, true)
		if d.legs == 6 then
			legs(B, P, 6, {}, 0, H, dia, base)
		else
			legs(B, P, d.legs, { Vector3.zero }, 0.2, H, dia, base)
		end
		local tie = Vector3.new(0, H - 0.5, 0)
		-- the arm: a crossbar with a peg at each end (none: the line ties to the pole)
		if d.back ~= 1 then
			local a = p.arm
			B.logX("PoleArm", a, dia * 0.8, 0, H - 0.5, 0, P.top, P.topMat)
			for _, sx in { -1, 1 } do
				B.cyl("PolePeg", dia * 0.6, sx * a / 2, H - 0.5, H - 0.1, 0, shade(P.frame, -0.1), P.frameMat)
			end
			if d.back == 4 or d.back == 5 then
				B.egg("PoleArmLeaf", a * 0.6, 0.14, 0.5, 0, H - 0.3, 0, P.leaf, M.leaf)
			end
		end
		-- the finial, in the shape rule
		local fy = H + 0.1
		local col, mat = P.top, P.topMat
		if d.shape == 1 then
			B.box("PoleFinial", 0.7, 0.7, 0.7, 0, fy + 0.25, 0, col, mat)
		elseif d.shape == 2 then
			B.ball("PoleFinial", 0.9, 0, fy + 0.35, 0, col, mat)
		elseif d.shape == 3 then
			B.egg("PoleFinial", 1.4, 0.7, 1.4, 0, fy + 0.3, 0, col, mat)
			B.cyl("PoleFinial", 0.4, 0, fy - 0.1, fy + 0.15, 0, shade(col, -0.2), mat)
		elseif d.shape == 4 then
			B.egg("PoleFinial", 0.5, 1.4, 0.18, 0, fy + 0.6, 0, P.leaf, M.leaf, CFrame.Angles(0, 0, 0.3))
		elseif d.shape == 5 then
			for i = 0, 4 do
				local a = i / 5 * TAU
				B.egg("PoleFinial", 0.6, 0.18, 0.36, math.cos(a) * 0.3, fy + 0.25, math.sin(a) * 0.3, if i % 2 == 0 then P.trim else col, M.petal, CFrame.Angles(0, -a, 0.3))
			end
			B.ball("PoleFinial", 0.36, 0, fy + 0.3, 0, P.glow, M.center)
		else
			hex(B, "PoleFinial", 0.45, 0.5, 0, fy + 0.25, 0, col, mat)
		end
		trim(B, P, d.trim, 3, dia * 2.2, dia * 2.2, H * 0.62, nil, nil, nil, nil, nil, true)
		return { top = tie, arm = if d.back ~= 1 then p.arm else 0 }
	end,
}

---------------------------------------------------------------- dressing grown pieces

--[[
	Every other grown piece (a chest, a cupboard, a barrel, a rug...) keeps
	its own body, which is what makes it work (a chest's hinged lid, a
	cupboard's doors, a tank's tap), and is dressed by the same grammar in a
	style:

	  Piece -> Body(kind, in the style's colours) + Trim(round its rim) + Crest(back rule)

	The body's wood, wicker and clay take the style's frame and top colours
	(lighter woods the top colour, darker the frame), its cloth and petals the
	style's cloth and trim, its glow the style's glow; flames, water, soil,
	honey and the like keep their own colours. The trim runs round the
	piece's rim, the crest (back rule) stands on top of tall wall pieces, and
	weight and size thicken and raise them. So a Mushroom Cottage chest, its
	cupboard and its barrels go with its chairs and tables.

	DRESS[kind](p) -> { rim = { y, w, d, round?, z? }?, crest = { y, w, z }? }
	in the piece's own frame, from its procedural sizes p.
]]

local DRESS = {}
FurnitureGrammar.DRESS = DRESS
DRESS.bunk = function(p) return { rim = { p.top + 0.3, p.W, p.L } } end
DRESS.chest = function(p) return { rim = { p.H, p.W, p.D } } end
DRESS.cupboard = function(p) return { rim = { p.H, p.W, p.D }, crest = { p.H + 0.25, p.W * 0.8, p.D / 2 - 0.2 } } end
DRESS.sideboard = function(p) return { rim = { p.H, p.W, p.D } } end
DRESS.rug = function(p) return { rim = { 0.12, 2 * p.R, 2 * p.R * p.k, true } } end
DRESS.planter = function(p) return { rim = { p.H, p.D, p.D, true } } end
DRESS.windowBox = function(p) return { rim = { 1.66, p.W + 0.1, 1.3 } } end
DRESS.honeycomb = function(p) return { rim = { 2.11, p.W + 0.2, 1.9 }, crest = { 5.3, p.W * 0.7, 0.7 } } end
DRESS.stove = function(p) return { rim = { 0.45, p.W, p.W, true } } end
DRESS.trough = function(p) return { rim = { 1.56, p.L, 1.4 } } end
DRESS.desk = function(p) return { rim = { p.H, p.W, 1.7, false, 0.85 } } end
DRESS.board = function(p) return { crest = { 4.4, p.W * 0.8, 0.1 } } end
DRESS.tank = function(p) return { rim = { p.H + 0.12, p.D, p.D, true, 0.4 } } end
DRESS.barrel = function(p) return { rim = { p.H, p.D * 0.88, p.D * 0.88, true } } end
DRESS.basket = function(p) return { rim = { p.H, p.D, p.D, true } } end
DRESS.compost = function(p) return { rim = { 2.2, p.W, p.W } } end
DRESS.vat = function(p) return { rim = { 1.68, p.D + 0.06, p.D + 0.06, true } } end
DRESS.stage = function(p) return { rim = { 0.8, p.W, p.D } } end
DRESS.plinth = function(p) return { rim = { p.H, 1.5, 1.5 } } end
DRESS.gameTable = function(p) return { rim = { 2.3, p.w, p.w } } end
DRESS.fireplace = function(p) return { crest = { p.H, p.W * 0.7, 0.75 } } end
DRESS.shelf = function(p) return { crest = { p.H, p.W * 0.8, 0.55 } } end

-- Parts whose colour is what they are, not what they're made of.
local KEEP = { "Flame", "Ember", "Fire", "Soil", "Water", "Dye", "Nectar", "Honey", "Gold", "Seed", "Fruit", "Glass", "Chalk", "Note", "Worm", "Square", "Paper", "Ink", "Key", "Knob", "Hoop", "Coal", "Soup" }
local GLOWS = { "Glow", "Bulb", "Light", "Lamp" }
-- Parts that take a style colour whatever colour they grew in.
local ROLES = { StoolCap = "top", StoolDome = "top", StoolStalk = "frame", StoolFoot = "frame", StoolRing = "frame", StoolSpot = "trim" }

local function named(n: string, words: { string }): boolean
	for _, w in words do
		if string.find(n, w, 1, true) then
			return true
		end
	end
	return false
end

-- Wood, wicker and clay: warm browns and oranges, not too pale or dark.
local function woody(c: Color3): boolean
	local h, s, v = c:ToHSV()
	local deg = h * 360
	return deg >= 8 and deg <= 50 and s >= 0.2 and s <= 0.92 and v >= 0.18 and v <= 0.92
end

-- The style's colour for one of the body's colours.
local function tint(P, n: string, col: Color3, mat: Enum.Material?): (Color3, Enum.Material?)
	if mat == M.habitatGlow then
		if named(n, GLOWS) then
			return col:Lerp(P.glow, 0.6), mat
		end
		return col, mat
	end
	-- a mushroom stool: its cap takes the top colour, its stalk the frame's
	local role = ROLES[n]
	if role then
		local base = P[role]
		local _, _, v = col:ToHSV()
		return shade(base, math.clamp((v - 0.8) * 0.8, -0.3, 0.3)), if role == "top" then P.topMat else P.frameMat
	end
	if named(n, KEEP) or not woody(col) then
		return col, mat
	end
	local _, _, v = col:ToHSV()
	local light = v >= 0.66
	local base = if light then P.top else P.frame
	-- keep the body's own light and dark (a darker lid edge, a paler top)
	local out = shade(base, math.clamp((v - (if light then 0.76 else 0.52)) * 1.3, -0.45, 0.45))
	local m = mat
	if mat == Enum.Material.Wood or mat == Enum.Material.WoodPlanks then
		m = if light then P.topMat else P.frameMat
	end
	return out, m
end

-- A builder that grows everything in the style's colours.
local function tinted(B, P)
	local T = setmetatable({}, { __index = B })
	for _, name in { "box", "wedge", "cyl", "logX", "logZ", "rod", "ball", "egg", "slab", "arch" } do
		local f = B[name]
		if f then
			T[name] = function(n: string, ...)
				local args = table.pack(...)
				for i = 1, args.n do
					if typeof(args[i]) == "Color3" then
						local col, mat = tint(P, n, args[i], args[i + 1])
						args[i] = col
						if i + 1 <= args.n and typeof(args[i + 1]) == "EnumItem" then
							args[i + 1] = mat
						end
						break
					end
				end
				return f(n, table.unpack(args, 1, args.n))
			end
		end
	end
	T.light = function(part, color: Color3, ...)
		local nm = part and part.Name or ""
		if not named(nm, { "Flame", "Ember", "Fire" }) then
			color = color:Lerp(P.glow, 0.5)
		end
		return B.light(part, color, ...)
	end
	return T
end
FurnitureGrammar.tinted = tinted

-- The plant colours a dressed body grows in (its cloth, petals and leaves).
local function styleColours(P, c: any)
	return setmetatable({
		stem = P.frame, leaf = P.leaf, petalBase = P.cloth, petalTip = P.trim, center = P.trim:Lerp(P.glow, 0.5),
	}, { __index = c })
end

-- A builder that grows everything `lift` studs higher (a body on feet).
local function lifted(B, lift: number)
	local L = setmetatable({}, { __index = B })
	local up = Vector3.new(0, lift, 0)
	-- which argument (after the name) is a height, for each part
	local Y = { box = { 5 }, wedge = { 5 }, egg = { 5 }, slab = { 5 }, arch = { 5 }, cyl = { 3, 4 }, logX = { 4 }, logZ = { 4 }, ball = { 3 } }
	for name, slots in Y do
		local f = B[name]
		L[name] = function(n: string, ...)
			local args = table.pack(...)
			for _, i in slots do
				if type(args[i]) == "number" then
					args[i] += lift
				end
			end
			return f(n, table.unpack(args, 1, args.n))
		end
	end
	L.rod = function(n: string, a: Vector3, b: Vector3, ...)
		return B.rod(n, a + up, b + up, ...)
	end
	return L
end

-- How high a dressed piece of kind `id` stands on its feet (0: none).
function FurnitureGrammar.liftOf(id: string, d: FurnitureRules.Design?): number
	local spec = FurnitureRules.DRESSED[id]
	if not d or not spec or not spec.uses.legs then
		return 0
	end
	return (if d.legs == 1 or d.legs == 6 then 0.25 else 0.4) * SIZE[d.size]
end

-- Grows grown piece `id` (its own `base` build) dressed in design `p.styled`
-- (on feet `p.lift` high, see FurnitureGrammar.liftOf).
function FurnitureGrammar.dress(id: string, B, c: any, p: any, base: (...any) -> any, rng: any, ...): any
	local d = p.styled
	local P = FurnitureGrammar.palette(d, c)
	local lift = p.lift or 0
	local spec = DRESS[id]
	local o = if spec then spec(p) else nil
	local body = if lift > 0 then lifted(B, lift) else B
	local made = base(tinted(body, P), styleColours(P, c), p, rng, ...)
	if o then
		local k = WEIGHT[d.weight]
		local s = SIZE[d.size]
		local rim = o.rim
		if rim and lift > 0 then
			-- feet: a plinth for posts and pedestals, little legs of the rule otherwise
			local w, dd = rim[2], rim[3]
			if d.legs == 1 or d.legs == 6 then
				B.box("DressPlinth", w - 0.2, lift, dd - 0.2, 0, lift / 2, rim[5] or 0, shade(P.frame, -0.2), P.frameMat, true)
			else
				local spots = legSpots(1, w, dd, 0.3, 4)
				if rim[5] then
					for i, q in spots do
						spots[i] = q + Vector3.new(0, 0, rim[5])
					end
				end
				legs(B, P, d.legs, spots, 0, lift + 0.05, 0.32 * k, 0.6)
			end
		end
		if rim then
			local shape = if rim[4] then 3 else 1
			trim(B, P, d.trim, shape, rim[2], rim[3], rim[1] + lift, nil, nil, nil, nil, rim[5], true)
		end
		local crest = o.crest
		if crest and d.back ~= 1 then
			back(B, P, d.back, crest[2], 0.7 * s, crest[1] + lift, crest[3], 0.2 * k, true)
		end
	end
	return made
end

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
