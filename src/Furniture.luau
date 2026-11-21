--[[
	Furniture: grown furniture for the rooms of building plants.

	Nothing in Plant World is built, it is grown, and that goes for the
	furniture too: seed-pod beds with leaf headboards, mushroom stools,
	lily-pad tables, bookcases of leaf books, acorn chests, cupboards and
	sideboards of cups and plates, petal rugs,
	dandelion-fluff beanbags, pebble hearths, honeycomb dressers... Each piece
	takes its colours from the plant it grows in (petals, leaves, stem), so a
	room always matches its building.

	Every piece is procedural: its sizes, proportions and details (how many
	shelves and which books, how many jars, which way a pot plant's leaves
	grow) come from the room's seed, so no two rooms are quite alike, but the
	same room always grows the same way. Pieces are built from crisp shapes
	(rounded slabs, cylinders, rods and a few soft ellipsoids) with contrasting
	rims and trims so each one reads clearly, even small and far away.

	Every room of every building plant has a purpose, even if that purpose is
	only to look lived in. A purpose lists the pieces it wants and how they
	like to stand (a chest by the bed, armchairs facing the fire, desks facing
	the board) plus fillers for the gaps; RoomPlanner lays them out round the
	stem, its climbing hole, the doorway, the windows and the lamps.

	Which purpose a room has:
	  - options.roomUses on PlantBuilder.build (from the anchor's RoomUses
	    attribute, "0=bedroom,1=kitchen"), for homes whose owner picks;
	  - otherwise by the plant's Building kind (anchor attribute Building), see
	    MIXES. The Market, Bloom School and Town Hall halls keep their own server
	    furniture; wild building plants get a mix of homely rooms.

	A home's owner can rearrange its rooms (Shared.Housing.RoomFurniture,
	Client.DecorateClient): a room they arranged grows their list of pieces
	(options.roomFurniture) instead of a layout. Each piece rolls its sizes
	from a seed of its own, so it looks the same wherever it is moved.

	Habitat.build calls Furniture.furnish for each room it builds (close-up
	and normal detail only). The pieces are ordinary plant parts named
	"Furniture...", so they ride with their room when it sways and never fade
	with the walls (RoomFade fades only Habitat* shell parts).

	Pieces are laid out in normal Roblox studs times the room's unit (like the
	rooms themselves), on the floor of the room's frame: +X out through the
	door, Y up, Z across. In its own frame a piece stands on y = 0, centred on
	its footprint, with its front facing -Z and its back (+Z) to the wall.
]]

local CollectionService = game:GetService("CollectionService")

local Palette = require(script.Parent.Palette)
local RoomPlanner = require(script.Parent.RoomPlanner)
local Host = require(script.Parent.Host)
local FurnitureUse = require(script.Parent.FurnitureUse)
local RoomFurniture = require(script.Parent.RoomFurniture)
local Drafts = require(script.Parent.Drafts)
local RoomLamps = require(script.Parent.RoomLamps)
local FurnitureGrammar = require(script.Parent.FurnitureGrammar)

local Furniture = {}

Furniture.PREFIX = "Furniture"

-- Every bed you can sleep in (a bed, or either bunk of a bunk) is tagged
-- SLEEP_TAG on its mattress, with attributes SleepRoom (the room's number,
-- 0 = ground hall) and SleepBed (1, 2, ... in that room, in layout order; a
-- bunk counts its bottom bunk then its top one). Client.BedPrompts puts the
-- Sleep / Claim prompts on them.
Furniture.SLEEP_TAG = "SleepSpot"

-- Parts thinner than this (in design studs, before the plant is scaled up)
-- are clamped. Much finer than PlantBuilder's own minimum, which would turn
-- a room's trims, rungs and book spines into fat cubes.
local FMIN = 0.002

local M = Palette.MATERIAL
local HALF_PI = math.pi / 2
local TAU = math.pi * 2
local WOOD = Enum.Material.Wood
local PLANKS = Enum.Material.WoodPlanks
local SMOOTH = Enum.Material.SmoothPlastic
local FABRIC = Enum.Material.Fabric

-- Fixed colours that read as "grown things" next to the plant's own.
local CAP_RED = Color3.fromRGB(235, 60, 60)
local CREAM = Color3.fromRGB(255, 248, 228)
local BARK = Color3.fromRGB(150, 92, 52)
local HONEY = Color3.fromRGB(255, 190, 40)
local GLOW = Color3.fromRGB(255, 236, 150)
local MOSS = Color3.fromRGB(70, 160, 70)
local GLASS = Color3.fromRGB(200, 240, 255)
local CLAY = Color3.fromRGB(215, 110, 70)
local SOIL = Color3.fromRGB(90, 60, 40)
local STONE = Color3.fromRGB(176, 168, 156)
local EMBER = Color3.fromRGB(255, 120, 40)
local FLAME = Color3.fromRGB(255, 205, 60)
local WATER = Color3.fromRGB(110, 195, 255)
local CHALK = Color3.fromRGB(46, 84, 64)
local WEAVE = Color3.fromRGB(205, 155, 85)
local WORM = Color3.fromRGB(240, 150, 160)
local INK = Color3.fromRGB(55, 45, 75)

local shade = Palette.shade

---------------------------------------------------------------- the builder

-- A tiny builder bound to one piece's floor frame `o` and its unit `u`:
-- every size and offset is in normal studs, in the piece's own frame.
local function builder(ctx, o: CFrame, u: number, inRoom: boolean?)
	local B = {}
	B.parts = {} :: { BasePart } -- every part grown, for the piece's handle (FurnitureUse)

	local function make(n: string, shape: Enum.PartType, size: Vector3, lcf: CFrame, color: Color3, material: Enum.Material, collide: boolean?): BasePart
		-- (may yield every few parts, to spread a big build over frames: PlantBuilder options.breathe)
		local breathe = ctx.breathe
		if breathe then
			ctx.made += 1
			if ctx.made % 16 == 0 then
				breathe()
			end
		end
		local p = Instance.new("Part")
		p.Name = Furniture.PREFIX .. n
		p.Shape = shape
		p.Anchored = true
		p.CanCollide = collide == true
		p.CanQuery = collide == true
		p.CanTouch = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		local s = size * u
		p.Size = Vector3.new(math.max(s.X, FMIN), math.max(s.Y, FMIN), math.max(s.Z, FMIN))
		p.CFrame = o * CFrame.new(lcf.Position * u) * lcf.Rotation
		p.Color = color
		p.Material = material
		if material == Enum.Material.Glass then
			p.Transparency = 0.45
		end
		p.Parent = ctx.model
		table.insert(B.parts, p)
		return p
	end

	-- Grown but hidden until the piece is used (an open chest's lid, its
	-- gold): hides every part grown since #B.parts was `from`.
	function B.hideSince(from: number)
		for i = from + 1, #B.parts do
			B.parts[i].Transparency = 1
		end
	end

	-- A box centred at (x, y, z).
	function B.box(n: string, sx: number, sy: number, sz: number, x: number, y: number, z: number, color: Color3, material: Enum.Material?, collide: boolean?, rot: CFrame?)
		return make(n, Enum.PartType.Block, Vector3.new(sx, sy, sz), CFrame.new(x, y, z) * (rot or CFrame.identity), color, material or SMOOTH, collide)
	end

	-- A wedge centred at (x, y, z): its slope rises toward -Z.
	function B.wedge(n: string, sx: number, sy: number, sz: number, x: number, y: number, z: number, color: Color3, material: Enum.Material?, rot: CFrame?)
		return make(n, Enum.PartType.Wedge, Vector3.new(sx, sy, sz), CFrame.new(x, y, z) * (rot or CFrame.identity), color, material or SMOOTH, false)
	end

	-- An upright cylinder of diameter d from y0 to y1.
	function B.cyl(n: string, d: number, x: number, y0: number, y1: number, z: number, color: Color3, material: Enum.Material?, collide: boolean?)
		return make(n, Enum.PartType.Cylinder, Vector3.new(math.max(y1 - y0, 0.01), d, d), CFrame.new(x, (y0 + y1) / 2, z) * CFrame.Angles(0, 0, HALF_PI), color, material or SMOOTH, collide)
	end

	-- A lying cylinder along X (logX) or Z (logZ), centred at (x, y, z).
	function B.logX(n: string, len: number, d: number, x: number, y: number, z: number, color: Color3, material: Enum.Material?, collide: boolean?)
		return make(n, Enum.PartType.Cylinder, Vector3.new(len, d, d), CFrame.new(x, y, z), color, material or SMOOTH, collide)
	end
	function B.logZ(n: string, len: number, d: number, x: number, y: number, z: number, color: Color3, material: Enum.Material?, collide: boolean?)
		return make(n, Enum.PartType.Cylinder, Vector3.new(len, d, d), CFrame.new(x, y, z) * CFrame.Angles(0, HALF_PI, 0), color, material or SMOOTH, collide)
	end

	-- A rod of diameter d from a to b.
	function B.rod(n: string, a: Vector3, b: Vector3, d: number, color: Color3, material: Enum.Material?)
		local len = (b - a).Magnitude
		if len < 1e-3 then
			return nil
		end
		local dir = (b - a) / len
		local up = if math.abs(dir.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
		local lcf = CFrame.lookAt((a + b) / 2, b, up) * CFrame.Angles(0, HALF_PI, 0)
		return make(n, Enum.PartType.Cylinder, Vector3.new(len, d, d), lcf, color, material or SMOOTH, false)
	end

	function B.ball(n: string, d: number, x: number, y: number, z: number, color: Color3, material: Enum.Material?)
		return make(n, Enum.PartType.Ball, Vector3.one * d, CFrame.new(x, y, z), color, material or SMOOTH, false)
	end

	-- A warm light on a glowing part, `brightness` as a wall lamp's 1.1; its
	-- reach grows with the piece. FurnitureClient switches it with the part.
	-- In a room it is a room lamp (Shared.Plants.RoomLamps) reaching `reach`
	-- normal studs, which Client.RoomLamps lights as a warm pool.
	function B.light(part: BasePart, color: Color3, brightness: number, reach: number?)
		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = math.max(2, 12 * u)
		light.Brightness = brightness
		light.Shadows = false
		if inRoom then
			RoomLamps.mark(light, part, (reach or 12) * u, brightness)
		end
		light.Parent = part
		return light
	end

	-- A soft ellipsoid (cushions, caps, pillows).
	function B.egg(n: string, sx: number, sy: number, sz: number, x: number, y: number, z: number, color: Color3, material: Enum.Material?, rot: CFrame?)
		local p = make(n, Enum.PartType.Block, Vector3.new(sx, sy, sz), CFrame.new(x, y, z) * (rot or CFrame.identity), color, material or SMOOTH, false)
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = p
		return p
	end

	-- A slab w x t x d centred at (x, y, z) with its corners rounded (radius r)
	-- round its thickness axis: two crossed boxes and four corner cylinders.
	-- `rot` turns it about its centre (a headboard is a slab stood on edge).
	function B.slab(n: string, w: number, t: number, d: number, x: number, y: number, z: number, color: Color3, material: Enum.Material?, collide: boolean?, r: number?, rot: CFrame?)
		local mat = material or SMOOTH
		local c = CFrame.new(x, y, z) * (rot or CFrame.identity)
		local rr = math.min(r or 0.3, w / 2 - 0.01, d / 2 - 0.01)
		if rr < 0.04 then
			return make(n, Enum.PartType.Block, Vector3.new(w, t, d), c, color, mat, collide)
		end
		-- Each layer a touch thinner than the last, so no two share a top or
		-- bottom face (coplanar faces flicker).
		local e = math.max(t * 0.04, 0.03)
		local main = make(n, Enum.PartType.Block, Vector3.new(w - 2 * rr, t, d), c, color, mat, collide)
		make(n, Enum.PartType.Block, Vector3.new(w, math.max(t - e, t * 0.5), d - 2 * rr), c, color, mat, collide)
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				make(n, Enum.PartType.Cylinder, Vector3.new(math.max(t - 2 * e, t * 0.4), 2 * rr, 2 * rr), c * CFrame.new(sx * (w / 2 - rr), 0, sz * (d / 2 - rr)) * CFrame.Angles(0, 0, HALF_PI), color, mat, false)
			end
		end
		return main
	end

	-- An upright panel (w wide, h tall, t thick, facing -Z) from y0, with an
	-- arched top: a box and a half disc. Headboards, backs, boards.
	function B.arch(n: string, w: number, h: number, t: number, x: number, y0: number, z: number, color: Color3, material: Enum.Material?, collide: boolean?)
		local r = w / 2
		local body = math.max(h - r, 0.05)
		B.box(n, w, body, t, x, y0 + body / 2, z, color, material, collide)
		-- the half disc a little thinner than the panel, so their faces don't flicker
		make(n, Enum.PartType.Cylinder, Vector3.new(t - math.max(t * 0.06, 0.03), w, w), CFrame.new(x, y0 + body, z) * CFrame.Angles(0, HALF_PI, 0), color, material or SMOOTH, false)
	end

	return B
end

---------------------------------------------------------------- pieces

-- Each piece:
--   place  - "wall", "window" or "free" (see RoomPlanner)
--   walls, corner, access, along, flat, scales - RoomPlanner hints
--   seats  - { id, n = { min, max } }: pieces ringed round it afterwards
--   params(rng) -> p: its procedural sizes; p.w, p.d, p.h its footprint and height
--   build(B, c, p, rng): grows it. c holds the plant's colours
--     (leaf, stem, petalBase, petalTip, center).
local PIECES = {}

local function pick(rng: Random, list: { any }): any
	return list[rng:NextInteger(1, #list)]
end

local function frameWood(c): Color3
	return shade(c.stem:Lerp(BARK, 0.55), -0.1)
end

-- A seed-pod bed: a stalk-wood frame on stubby legs, a petal mattress and
-- blanket with a turned-down hem, a fluff pillow, and an arched leaf headboard.
PIECES.bed = {
	sleeps = true, -- build returns its mattress (see Furniture.SLEEP_TAG)
	place = "wall", walls = { back = 1, left = 1, right = 1, front = 0.3 }, corner = 0.9, along = true, access = 1.6,
	params = function(rng)
		local W, L = rng:NextNumber(3.6, 4.4), rng:NextNumber(6.6, 7.6)
		local H = rng:NextNumber(3.2, 4)
		return { w = W + 0.1, d = L + 0.2, h = H, W = W, L = L, H = H, foot = rng:NextNumber() < 0.6 }
	end,
	build = function(B, c, p)
		local W, L, H = p.W, p.L, p.H
		local wood = frameWood(c)
		local back = L / 2
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				B.cyl("BedLeg", 0.55, sx * (W / 2 - 0.45), 0, 0.5, sz * (L / 2 - 0.5), shade(wood, -0.25), WOOD)
			end
		end
		B.slab("BedFrame", W, 0.6, L - 0.3, 0, 0.8, -0.1, wood, WOOD, true, 0.4)
		local mattress = B.slab("BedMattress", W - 0.35, 0.55, L - 0.7, 0, 1.35, -0.15, CREAM:Lerp(c.petalBase, 0.15), FABRIC, true, 0.35)
		local bl = (L - 0.7) * 0.6
		local bz = -0.15 - (L - 0.7) / 2 + bl / 2
		B.slab("BedBlanket", W - 0.1, 0.22, bl, 0, 1.7, bz - 0.05, c.petalBase, FABRIC, false, 0.3)
		for _, sx in { -1, 1 } do
			B.box("BedDrape", 0.14, 0.7, bl - 0.2, sx * (W / 2 - 0.02), 1.42, bz - 0.05, shade(c.petalBase, -0.15), FABRIC)
		end
		B.box("BedHem", W - 0.05, 0.3, 0.55, 0, 1.75, bz + bl / 2 - 0.25, c.petalTip, FABRIC)
		B.egg("BedPillow", W * 0.62, 0.7, 1.3, 0, 1.85, back - 1.25, CREAM, FABRIC)
		B.arch("BedHead", W + 0.2, H, 0.4, 0, 0.4, back - 0.2, c.leaf, M.leaf, true)
		B.arch("BedHeadInset", W - 0.7, H - 0.75, 0.1, 0, 1.2, back - 0.42, shade(c.leaf, 0.2), M.leaf)
		B.ball("BedKnob", 0.45, -(W / 2 + 0.05), H - W / 2 + 0.55, back - 0.2, c.petalTip)
		B.ball("BedKnob", 0.45, W / 2 + 0.05, H - W / 2 + 0.55, back - 0.2, c.petalTip)
		if p.foot then
			B.box("BedFoot", W + 0.18, 1.2, 0.35, 0, 1.05, -L / 2 + 0.2, wood, WOOD)
			B.logX("BedFootRail", W + 0.3, 0.42, 0, 1.7, -L / 2 + 0.2, shade(wood, 0.15), WOOD)
		end
		return { mattress }
	end,
}

-- A bunk: two pod beds on four stalk posts, guard rails and a ladder.
PIECES.bunk = {
	sleeps = true, -- build returns its mattresses, bottom then top (see Furniture.SLEEP_TAG)
	place = "wall", walls = { back = 1, left = 1, right = 1, front = 0.2 }, corner = 1, along = true, access = 1.8,
	params = function(rng)
		local W, L = rng:NextNumber(3.6, 4.1), rng:NextNumber(6.6, 7.2)
		return { w = W + 0.5, d = L + 0.3, h = 7.4, W = W, L = L, top = 4.1 }
	end,
	build = function(B, c, p)
		local W, L, top = p.W, p.L, p.top
		local wood = frameWood(c)
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				B.cyl("BunkPost", 0.5, sx * (W / 2), 0, top + 3.2, sz * (L / 2), wood, WOOD, true)
				B.ball("BunkKnob", 0.62, sx * (W / 2), top + 3.25, sz * (L / 2), shade(c.petalTip, -0.05))
			end
		end
		local mattresses = {}
		for i, y in { 0.5, top } do
			local col = if i == 1 then c.petalBase else c.petalTip
			B.slab("BunkFrame", W, 0.45, L, 0, y + 0.3, 0, shade(wood, 0.08), WOOD, true, 0.3)
			mattresses[i] = B.slab("BunkMattress", W - 0.35, 0.5, L - 0.4, 0, y + 0.78, 0, CREAM:Lerp(col, 0.12), FABRIC, true, 0.3)
			B.slab("BunkBlanket", W - 0.15, 0.2, L * 0.55, 0, y + 1.1, -L * 0.2, col, FABRIC, false, 0.25)
			B.box("BunkHem", W - 0.1, 0.26, 0.45, 0, y + 1.14, -L * 0.2 + L * 0.275 - 0.2, shade(col, 0.3), FABRIC)
			B.egg("BunkPillow", W * 0.6, 0.6, 1.2, 0, y + 1.2, L / 2 - 1.1, CREAM, FABRIC)
			B.box("BunkHead", W, 1.6, 0.3, 0, y + 1.05, L / 2, c.leaf, M.leaf)
		end
		-- top bunk guard rails, open at the ladder end
		for _, sx in { -1, 1 } do
			B.logZ("BunkRail", L * 0.7, 0.3, sx * (W / 2), top + 2, L * 0.15, shade(wood, 0.15), WOOD)
		end
		-- ladder at the foot end, on the right
		local lx0, lx1 = W / 2 - 1.5, W / 2 - 0.2
		local lz = -L / 2 - 0.15
		B.cyl("BunkLadder", 0.25, lx0, 0, top + 1.6, lz, c.stem, M.stem)
		B.cyl("BunkLadder", 0.25, lx1, 0, top + 1.6, lz, c.stem, M.stem)
		for k = 1, 4 do
			B.logX("BunkRung", lx1 - lx0, 0.2, (lx0 + lx1) / 2, k * (top + 0.8) / 5, lz, c.leaf, M.leaf)
		end
		return mattresses
	end,
}

-- A mushroom stool: a stalk with a ring, a flat-topped cap with gills under it and spots.
PIECES.stool = {
	place = "free", access = 0,
	params = function(rng)
		local D, H = rng:NextNumber(1.5, 2), rng:NextNumber(1.2, 1.6)
		return { w = D, d = D, h = H + 0.6, D = D, H = H, red = rng:NextNumber() < 0.6, spots = rng:NextInteger(3, 5), turn = rng:NextNumber() * TAU }
	end,
	build = function(B, c, p, _rng, z)
		z = z or 0
		local D, H = p.D, p.H
		local cap = if p.red then CAP_RED else c.petalTip
		B.cyl("StoolStalk", 0.7, 0, 0, H, z, CREAM)
		B.cyl("StoolFoot", 0.95, 0, 0, 0.18, z, shade(CREAM, -0.08))
		B.cyl("StoolRing", 0.9, 0, H * 0.6, H * 0.6 + 0.12, z, shade(CREAM, -0.1))
		B.cyl("StoolGills", D * 0.9, 0, H - 0.06, H + 0.06, z, shade(CREAM, -0.18))
		B.cyl("StoolCap", D, 0, H + 0.06, H + 0.36, z, cap, SMOOTH, true)
		B.egg("StoolDome", D, 0.5, D, 0, H + 0.36, z, cap)
		for i = 1, p.spots do
			local a = p.turn + i / p.spots * TAU
			local rr = D * 0.28
			local dome = 0.25 * math.sqrt(math.max(0, 1 - (2 * rr / D) ^ 2))
			B.ball("StoolSpot", 0.28, math.cos(a) * rr, H + 0.33 + dome, z + math.sin(a) * rr, CREAM)
		end
	end,
}

-- A table: a lily pad on a stalk (rim, veins and its notch), or a little
-- plank table on four legs. Stools ring it.
PIECES.table = {
	place = "free", access = 0, seats = { id = "stool", n = { 2, 4 } },
	params = function(rng)
		local pad = rng:NextNumber() < 0.6
		local R = rng:NextNumber(1.7, 2.3)
		local H = rng:NextNumber(2.3, 2.7)
		if pad then
			return { w = 2 * R, d = 2 * R, h = H + 0.8, pad = true, R = R, H = H, veins = rng:NextInteger(5, 7), notch = rng:NextNumber() * TAU }
		end
		local W, D = rng:NextNumber(3.4, 4.2), rng:NextNumber(2.4, 3)
		return { w = W, d = D, h = H + 0.8, pad = false, W = W, D = D, H = H }
	end,
	build = function(B, c, p, rng)
		local H = p.H
		if p.pad then
			local R = p.R
			B.cyl("TableFoot", 1.5, 0, 0, 0.2, 0, shade(c.stem, -0.2), M.stem)
			B.cyl("TableStalk", 0.55, 0, 0.2, H - 0.25, 0, c.stem, M.stem)
			for i = 0, 2 do
				local a = i / 3 * TAU + 0.4
				B.rod("TableRoot", Vector3.new(0, 0.9, 0), Vector3.new(math.cos(a) * 0.75, 0.05, math.sin(a) * 0.75), 0.24, c.stem, M.stem)
			end
			B.cyl("TableRim", 2 * R, 0, H - 0.3, H - 0.1, 0, shade(c.leaf, -0.22), M.leaf)
			B.cyl("TableTop", 2 * R - 0.2, 0, H - 0.1, H, 0, shade(c.leaf, 0.12), M.leaf, true)
			local vein = shade(c.leaf, 0.4)
			for i = 0, p.veins - 1 do
				local a = p.notch + (i + 0.5) / p.veins * TAU
				B.box("TableVein", R * 0.85, 0.03, 0.08, math.cos(a) * R * 0.45, H + 0.01, math.sin(a) * R * 0.45, vein, M.leaf, false, CFrame.Angles(0, -a, 0))
			end
			B.box("TableNotch", R * 0.9, 0.05, 0.16, math.cos(p.notch) * R * 0.55, H + 0.015, math.sin(p.notch) * R * 0.55, shade(c.leaf, -0.4), M.leaf, false, CFrame.Angles(0, -p.notch, 0))
			-- a bud vase in the middle
			B.cyl("TableVase", 0.4, 0.3, H, H + 0.55, -0.2, GLASS, Enum.Material.Glass)
			B.rod("TableBudStalk", Vector3.new(0.3, H + 0.2, -0.2), Vector3.new(0.35, H + 0.85, -0.2), 0.06, c.stem, M.stem)
			B.ball("TableBud", 0.35, 0.35, H + 0.9, -0.2, c.petalBase, M.petal)
		else
			local W, D = p.W, p.D
			local wood = frameWood(c)
			B.slab("TableTop", W, 0.25, D, 0, H - 0.12, 0, shade(wood, 0.25), PLANKS, true, 0.3)
			B.slab("TableApron", W - 0.5, 0.35, D - 0.5, 0, H - 0.42, 0, shade(wood, -0.1), WOOD, false, 0.2)
			for _, sx in { -1, 1 } do
				for _, sz in { -1, 1 } do
					B.cyl("TableLeg", 0.38, sx * (W / 2 - 0.45), 0, H - 0.25, sz * (D / 2 - 0.45), wood, WOOD)
				end
			end
			B.box("TableRunner", W * 0.75, 0.04, 0.8, 0, H + 0.02, 0, c.petalBase, FABRIC)
			-- a glazed clay fruit bowl heaped with berries, a seed and a leaf
			local bx = rng:NextNumber(-0.6, 0.6)
			B.cyl("TableBowlFoot", 0.55, bx, H, H + 0.1, 0, shade(CLAY, -0.2))
			B.cyl("TableBowlBase", 0.78, bx, H + 0.1, H + 0.2, 0, shade(CLAY, -0.08))
			B.cyl("TableBowl", 1.0, bx, H + 0.2, H + 0.38, 0, CLAY)
			B.cyl("TableBowlGlaze", 1.03, bx, H + 0.26, H + 0.31, 0, CREAM)
			B.cyl("TableBowlRim", 1.12, bx, H + 0.36, H + 0.42, 0, shade(CLAY, 0.22))
			B.cyl("TableBowlHollow", 0.88, bx, H + 0.4, H + 0.43, 0, shade(CLAY, -0.45))
			local fruit = { CAP_RED, c.petalBase, c.petalTip, HONEY, c.center }
			local spin = rng:NextNumber(0, TAU)
			for i = 0, 4 do
				local a = spin + i / 5 * TAU
				B.ball("TableBerry", rng:NextNumber(0.3, 0.38), bx + math.cos(a) * 0.24, H + 0.5, math.sin(a) * 0.24, fruit[i + 1], M.petal)
			end
			B.ball("TableBerry", 0.4, bx, H + 0.68, 0, CAP_RED, M.petal)
			B.rod("TableBerryStalk", Vector3.new(bx, H + 0.84, 0), Vector3.new(bx + 0.06, H + 0.98, 0.03), 0.05, c.stem, M.stem)
			B.egg("TableBowlLeaf", 0.55, 0.05, 0.24, bx + 0.42, H + 0.52, 0.12, c.leaf, M.leaf, CFrame.Angles(0, -spin, 0.35))
			B.egg("TableBowlSeed", 0.22, 0.34, 0.22, bx - 0.12, H + 0.66, 0.2, shade(c.center, -0.25), M.center, CFrame.Angles(0.4, 0, 0.3))
		end
	end,
}

-- A big round council table: a thick pedestal, a wood top with a petal inlay.
PIECES.roundTable = {
	place = "free", access = 0, seats = { id = "stool", n = { 4, 6 } },
	params = function(rng)
		local R = rng:NextNumber(2.5, 3.1)
		return { w = 2 * R, d = 2 * R, h = 2.6, R = R, petals = rng:NextInteger(5, 7) }
	end,
	build = function(B, c, p)
		local R, H = p.R, 2.5
		local wood = frameWood(c)
		B.cyl("RoundFoot", 2.2, 0, 0, 0.3, 0, shade(wood, -0.2), WOOD)
		B.cyl("RoundPedestal", 1.1, 0, 0.3, H - 0.3, 0, wood, WOOD)
		B.cyl("RoundRim", 2 * R, 0, H - 0.35, H - 0.1, 0, shade(wood, -0.15), WOOD)
		B.cyl("RoundTop", 2 * R - 0.2, 0, H - 0.1, H, 0, shade(wood, 0.25), PLANKS, true)
		B.cyl("RoundInlay", R * 0.9, 0, H, H + 0.02, 0, c.center, M.center)
		for i = 1, p.petals do
			local a = i / p.petals * TAU
			B.egg("RoundPetal", R * 0.5, 0.04, R * 0.22, math.cos(a) * R * 0.55, H + 0.01, math.sin(a) * R * 0.55, if i % 2 == 0 then c.petalBase else c.petalTip, M.petal, CFrame.Angles(0, -a, 0))
		end
	end,
}

-- A bookcase: sides, cap, plinth and back, with shelves of leaf books (some
-- leaning), seed jars and pods.
PIECES.shelf = {
	place = "wall", corner = 0.2, access = 1.4,
	params = function(rng)
		local W, H = rng:NextNumber(3.6, 4.6), rng:NextNumber(5.4, 6.6)
		return { w = W + 0.2, d = 1.5, h = H, W = W, H = H, rows = if H > 6 then 4 else 3 }
	end,
	build = function(B, c, p, rng)
		local W, H, D = p.W, p.H, 1.4
		local wood = frameWood(c)
		local inner = W - 0.6
		for _, sx in { -1, 1 } do
			B.box("ShelfSide", 0.3, H - 0.3, D, sx * (W / 2 - 0.15), (H - 0.3) / 2, 0, wood, WOOD, true)
		end
		B.slab("ShelfCap", W + 0.2, 0.3, D + 0.12, 0, H - 0.15, -0.02, shade(wood, 0.2), WOOD, false, 0.12)
		B.box("ShelfPlinth", W - 0.1, 0.4, D - 0.1, 0, 0.2, -0.02, shade(wood, -0.25), WOOD)
		B.box("ShelfBack", inner, H - 0.6, 0.1, 0, H / 2, D / 2 - 0.05, shade(wood, -0.35), WOOD)
		local gap = (H - 0.7) / p.rows
		local spines = { c.petalBase, c.petalTip, c.leaf, c.center, CREAM, shade(c.leaf, -0.3), shade(c.petalBase, -0.3) }
		for i = 0, p.rows - 1 do
			local y = 0.4 + i * gap
			if i > 0 then
				B.box("ShelfBoard", inner, 0.16, D - 0.15, 0, y, -0.05, shade(wood, 0.1), WOOD)
			end
			local x = -inner / 2 + 0.1
			local stop = inner / 2 - 0.1
			while x < stop - 0.25 do
				local roll = rng:NextNumber()
				if roll < 0.62 then
					-- a run of books
					local n = rng:NextInteger(2, 5)
					for _ = 1, n do
						local bw = rng:NextNumber(0.2, 0.34)
						if x + bw > stop then
							break
						end
						local bh = gap * rng:NextNumber(0.55, 0.78)
						local col = spines[rng:NextInteger(1, #spines)]
						-- spines stand a little in or out, so none share a face with a neighbour
						local bd = D - rng:NextNumber(0.4, 0.55)
						B.box("ShelfBook", bw, bh, bd, x + bw / 2, y + 0.08 + bh / 2, D / 2 - 0.1 - bd / 2, col, SMOOTH)
						B.box("ShelfBand", bw + 0.02, 0.07, bd + 0.02, x + bw / 2, y + 0.08 + bh * 0.78, D / 2 - 0.1 - bd / 2, shade(col, 0.45), SMOOTH)
						x += bw + 0.02
					end
					if rng:NextNumber() < 0.3 and x + 0.5 < stop then
						-- one leaning on the run
						local bh = gap * 0.6
						B.box("ShelfBook", 0.26, bh, D - 0.62, x + 0.3, y + 0.08 + bh / 2 - 0.04, -0.13, pick(rng, spines), SMOOTH, false, CFrame.Angles(0, 0, 0.32))
						x += 0.55
					end
				elseif roll < 0.82 then
					-- a seed jar
					local h = math.min(gap * 0.6, 1.1)
					B.cyl("ShelfJar", 0.6, x + 0.32, y + 0.08, y + 0.08 + h, -0.05, GLASS, Enum.Material.Glass)
					B.ball("ShelfSeed", 0.36, x + 0.32, y + 0.08 + h * 0.4, -0.05, c.center, M.seed)
					B.cyl("ShelfLid", 0.66, x + 0.32, y + 0.08 + h, y + 0.2 + h, -0.05, BARK, WOOD)
					x += 0.7
				elseif roll < 0.93 then
					-- a seed pod
					B.egg("ShelfPod", 0.55, math.min(gap * 0.55, 0.95), 0.5, x + 0.3, y + 0.08 + math.min(gap * 0.55, 0.95) / 2, -0.05, shade(c.petalTip, -0.15), M.seed)
					x += 0.65
				else
					x += 0.4 -- a gap
				end
			end
		end
	end,
}

-- An acorn chest: a hollow rounded wood box (four walls, corner posts and a
-- raised floor you can see into when it's open) with a cap-coloured barrel
-- lid hinged along the top back edge, brass bands and a latch.
PIECES.chest = {
	place = "wall", corner = 0.3, access = 1.2,
	params = function(rng)
		local W, D, H = rng:NextNumber(2.3, 3), rng:NextNumber(1.5, 1.8), rng:NextNumber(1.3, 1.6)
		return { w = W + 0.1, d = D + 0.1, h = H + D / 2, W = W, D = D, H = H }
	end,
	build = function(B, c, p)
		local W, D, H = p.W, p.D, p.H
		local body = shade(BARK, 0.1)
		local inside = shade(BARK, -0.25)
		local cap = shade(BARK, -0.3)
		local brass = shade(HONEY, -0.15)
		local T = 0.18 -- wall thickness
		local R = 0.2 -- corner post radius
		local y0, wallH = 0.15, H - 0.15
		local wy = y0 + wallH / 2
		-- The back wall is "ChestBody": FurnitureClient hinges the lid on its
		-- top back edge (+Z face), which is the chest's top back edge.
		B.box("ChestBody", W - 2 * R, wallH, T, 0, wy, D / 2 - T / 2, body, WOOD, true)
		B.box("ChestWall", W - 2 * R, wallH, T, 0, wy, -D / 2 + T / 2, body, WOOD, true)
		for _, sx in { -1, 1 } do
			B.box("ChestWall", T, wallH, D - 2 * R, sx * (W / 2 - T / 2), wy, 0, body, WOOD, true)
			for _, sz in { -1, 1 } do
				B.cyl("ChestWall", 2 * R, sx * (W / 2 - R), y0, H, sz * (D / 2 - R), body, WOOD)
			end
		end
		B.slab("ChestFoot", W - 0.2, 0.15, D - 0.2, 0, 0.075, 0, cap, WOOD, true, 0.15)
		-- Inside: a raised floor so what's in the chest shows over the walls.
		local floorY = math.max(H * 0.42, 0.45)
		B.box("ChestHollow", W - 2 * T - 0.02, 0.08, D - 2 * T - 0.02, 0, floorY, 0, inside, WOOD)
		B.box("ChestHollow", W - 2 * T - 0.02, floorY - y0, D - 2 * T - 0.02, 0, (floorY + y0) / 2 - 0.04, 0, shade(inside, -0.3), WOOD)
		-- The rim: a frame round the open top, overhanging a little outside.
		local rimT = T + 0.1
		for _, sz in { -1, 1 } do
			B.box("ChestRim", W + 0.06, 0.14, rimT, 0, H - 0.05, sz * (D / 2 + 0.05 - rimT / 2), shade(cap, 0.25), WOOD)
		end
		for _, sx in { -1, 1 } do
			B.box("ChestRim", rimT - 0.04, 0.13, D + 0.1 - 2 * rimT + 0.02, sx * (W / 2 + 0.03 - (rimT - 0.04) / 2), H - 0.05, 0, shade(cap, 0.25), WOOD)
		end
		-- Brass bands down the front and back faces.
		for _, sx in { -1, 1 } do
			local x = sx * W * 0.3
			for _, sz in { -1, 1 } do
				B.box("ChestBand", 0.22, H - 0.16, 0.1, x, (H - 0.16) / 2 + 0.1, sz * D / 2, brass)
			end
		end
		-- The lid: a hollow half barrel (curved staves and stepped end caps)
		-- over the open top, axis along X at the rim. `at` places it: shut it
		-- sits on the rim; open it's tipped back 105 degrees about the top
		-- back edge, the same hinge FurnitureClient swings it on, so the
		-- lid keeps one shape shut, swinging and open.
		local r = D / 2
		local STAVES, STEPS = 5, 3
		local function halfBarrel(n: string, at: CFrame, x: number, len: number, rad: number, thick: number, color: Color3, material: Enum.Material, caps: boolean)
			local chord = 2 * rad * math.sin(math.pi / (2 * STAVES)) * 1.08
			for i = 1, STAVES do
				local phi = (i - 0.5) * math.pi / STAVES
				local rr = rad - thick / 2
				local cf = at * CFrame.new(x, rr * math.sin(phi), -rr * math.cos(phi)) * CFrame.Angles(phi - math.pi / 2, 0, 0)
				B.box(n, len, thick, chord, cf.X, cf.Y, cf.Z, color, material, false, cf.Rotation)
			end
			if caps then
				for _, sx in { -1, 1 } do
					for j = 1, STEPS do
						local yMid = rad * (j - 0.5) / STEPS
						local half = math.sqrt(rad * rad - yMid * yMid) - thick * 0.3
						local cf = at * CFrame.new(x + sx * (len / 2 - 0.05), yMid, 0)
						B.box(n, 0.1, rad / STEPS, 2 * half, cf.X, cf.Y, cf.Z, shade(color, -0.12), material, false, cf.Rotation)
					end
				end
			end
		end
		local function lid(n: string, at: CFrame)
			halfBarrel(n, at, 0, W - 0.06, r, 0.16, cap, FABRIC, true)
			for _, sx in { -1, 1 } do
				halfBarrel(n, at, sx * W * 0.3, 0.26, r + 0.04, 0.08, brass, SMOOTH, false)
			end
			local top = at * CFrame.new(0, r + 0.05, 0)
			B.ball(n, 0.3, top.X, top.Y, top.Z, shade(cap, -0.2), WOOD)
		end
		lid("ChestLid", CFrame.new(0, H + 0.02, 0))
		B.box("ChestLatch", 0.42, 0.55, 0.12, 0, H - 0.15, -D / 2 - 0.05, HONEY)
		B.ball("ChestKeyhole", 0.14, 0, H - 0.2, -D / 2 - 0.12, INK)
		-- Opened (FurnitureUse): the lid tipped back on its hinge, and the treasure.
		local from = #B.parts
		lid("ChestLidOpen", CFrame.new(0, H, D / 2) * CFrame.Angles(math.rad(105), 0, 0) * CFrame.new(0, 0.02, -D / 2))
		-- the treasure: a little heap of glowing honey drops on the floor
		for i = 1, 7 do
			local a = i * 2.4
			local ring = if i <= 5 then 1 else 0.3
			local y = floorY + 0.04 + 0.19 + (if i <= 5 then 0 else 0.2)
			B.ball("ChestGold", 0.38, math.cos(a) * W * 0.22 * ring, y, math.sin(a) * D * 0.14 * ring, HONEY, M.habitatGlow)
		end
		B.hideSince(from)
	end,
}

-- Cupboards and sideboards (FurnitureUse "doors"): a hollow wood carcass
-- with shelves of cups and plates, behind doors hung on side hinges. Each
-- door is grown twice: shut (DoorA, DoorB...) and swung open on its hinge
-- (DoorAOpen...), so it keeps one shape shut, swinging and open. A door's
-- panel is its first part, with attribute DoorHinge = the side its hinge is
-- on (-1 left, 1 right, in the piece's frame); FurnitureClient swings the
-- door about that panel's outer front edge.
local DOOR_T = 0.16 -- door thickness

-- One door: hinge at x = hx on the doors' front face (z = zf), the door
-- hanging off it toward -sx, w wide and h tall from y0, turned `angle` open.
local function growDoor(B, n: string, sx: number, hx: number, y0: number, w: number, h: number, zf: number, angle: number, wood: Color3, knob: Color3)
	local at = CFrame.new(hx, y0 + h / 2, zf) * CFrame.Angles(0, -sx * angle, 0)
	local function put(sxx: number, syy: number, szz: number, lx: number, ly: number, lz: number, color: Color3)
		local cf = at * CFrame.new(lx, ly, lz)
		return B.box(n, sxx, syy, szz, cf.X, cf.Y, cf.Z, color, WOOD, false, cf.Rotation)
	end
	local panel = put(w, h, DOOR_T, -sx * w / 2, 0, DOOR_T / 2, wood)
	panel:SetAttribute("DoorHinge", sx)
	-- a raised inner panel, a little proud of the door
	put(math.max(w - 0.42, 0.1), math.max(h - 0.42, 0.1), 0.08, -sx * w / 2, 0, -0.025, shade(wood, 0.18))
	-- the knob, by the free edge, a bud of the plant's centre colour
	local k = at * CFrame.new(-sx * (w - 0.24), 0, -0.13)
	B.ball(n, 0.24, k.X, k.Y, k.Z, knob)
end

-- Cups, bowls, jars and plates along a shelf from x0 to x1 at height y,
-- against the back at zb, under a shelf gap of `gap`.
local function crockery(B, c, rng: Random, x0: number, x1: number, y: number, zb: number, gap: number)
	local glazes = { CREAM, c.petalBase, c.petalTip, CLAY:Lerp(CREAM, 0.35), shade(c.leaf, 0.25) }
	local x = x0 + 0.08
	while x < x1 - 0.3 do
		local roll = rng:NextNumber()
		local col = pick(rng, glazes)
		if roll < 0.3 then
			-- a plate stood on edge against the back
			local d = math.min(rng:NextNumber(0.55, 0.75), gap * 0.85)
			if x + 0.2 > x1 then
				break
			end
			B.logZ("CupboardPlate", 0.07, d, x + 0.1, y + d / 2, zb - 0.12, col)
			B.logZ("CupboardPlate", 0.075, d * 0.55, x + 0.1, y + d / 2, zb - 0.12, shade(col, -0.12))
			x += 0.24
		elseif roll < 0.55 then
			-- a cup, with its handle
			if x + 0.45 > x1 then
				break
			end
			local hgt = math.min(0.3, gap * 0.5)
			B.cyl("CupboardCup", 0.32, x + 0.2, y, y + hgt, zb - 0.45, col)
			B.ball("CupboardCup", 0.13, x + 0.38, y + hgt * 0.55, zb - 0.45, shade(col, -0.1))
			x += 0.5
		elseif roll < 0.75 then
			-- a stack of bowls
			if x + 0.6 > x1 then
				break
			end
			local n = rng:NextInteger(2, 3)
			for i = 0, n - 1 do
				local by = y + i * 0.13
				if by + 0.15 > y + gap * 0.8 then
					break
				end
				B.cyl("CupboardBowl", 0.42 + i * 0.05, x + 0.28, by, by + 0.12, zb - 0.4, if i % 2 == 0 then col else shade(col, -0.15))
			end
			x += 0.62
		elseif roll < 0.9 then
			-- a jar of seeds or jam
			if x + 0.5 > x1 then
				break
			end
			local hgt = math.min(0.62, gap * 0.7)
			B.cyl("CupboardJar", 0.4, x + 0.24, y, y + hgt, zb - 0.35, GLASS, Enum.Material.Glass)
			B.cyl("CupboardJar", 0.3, x + 0.24, y + 0.02, y + hgt * 0.6, zb - 0.35, if rng:NextNumber() < 0.5 then c.center else HONEY)
			B.cyl("CupboardJar", 0.44, x + 0.24, y + hgt, y + hgt + 0.08, zb - 0.35, BARK, WOOD)
			x += 0.52
		else
			x += 0.3 -- a gap
		end
	end
end

-- What a cupboard or sideboard holds when there's a find inside: a little
-- leaf pouch and glowing honey drops (FurnitureUse treasure; hidden until
-- it's opened with something in it).
local function cupboardGold(B, c, x: number, y: number, z: number, span: number)
	B.egg("CupboardGold", 0.5, 0.42, 0.42, x - span * 0.2, y + 0.21, z, c.leaf, M.leaf)
	B.ball("CupboardGold", 0.16, x - span * 0.2, y + 0.45, z, shade(c.leaf, -0.25))
	for i = 1, 5 do
		local a = i * 2.4
		B.ball("CupboardGold", 0.28, x + span * 0.12 + math.cos(a) * span * 0.14, y + 0.14, z + math.sin(a) * 0.18, HONEY, M.habitatGlow)
	end
end

-- A tall cupboard: a plinth, a cornice, two doors over shelves of crockery,
-- and a bottom shelf kept clear for finds.
PIECES.cupboard = {
	place = "wall", corner = 0.3, access = 1.6,
	params = function(rng)
		local W, H, D = rng:NextNumber(2.8, 3.4), rng:NextNumber(4.6, 5.6), rng:NextNumber(1.5, 1.7)
		return { w = W + 0.3, d = D + 0.15, h = H + 0.3, W = W, H = H, D = D, rows = if H > 5.1 then 3 else 2 }
	end,
	build = function(B, c, p, rng)
		local W, H, D = p.W, p.H, p.D
		local wood = frameWood(c)
		local inside = shade(wood, -0.35)
		local T = 0.2
		local z0 = -D / 2 + DOOR_T -- the carcass's front, behind the doors
		local zb = D / 2 - T -- the inside of the back
		local iz, idp = (z0 + zb) / 2, zb - z0
		local base = 0.35
		B.box("Cupboard", W - 0.12, base, D - DOOR_T - 0.06, 0, base / 2, (z0 + D / 2) / 2, shade(wood, -0.25), WOOD, true)
		for _, sx in { -1, 1 } do
			B.box("Cupboard", T, H, D - DOOR_T, sx * (W / 2 - T / 2), H / 2, (z0 + D / 2) / 2, wood, WOOD, true)
		end
		B.box("CupboardBack", W - 2 * T + 0.02, H - base, T, 0, base + (H - base) / 2, D / 2 - T / 2, inside, WOOD, true)
		local fy = base + 0.06
		B.box("CupboardShelf", W - 2 * T + 0.02, 0.12, idp, 0, base, iz, shade(inside, 0.1), WOOD)
		B.slab("CupboardTop", W + 0.3, 0.3, D + 0.12, 0, H + 0.15, -0.04, shade(wood, 0.2), WOOD, true, 0.12)
		B.box("CupboardTrim", W + 0.16, 0.12, 0.1, 0, H, -D / 2 - 0.02, c.petalBase, SMOOTH)
		-- shelves: the bottom one for finds, the rest for crockery
		local gap = (H - 0.1 - fy) / p.rows
		for i = 1, p.rows - 1 do
			B.box("CupboardShelf", W - 2 * T + 0.02, 0.1, idp, 0, fy + i * gap - 0.05, iz, shade(inside, 0.1), WOOD)
			crockery(B, c, rng, -W / 2 + T, W / 2 - T, fy + i * gap, zb, gap - 0.15)
		end
		-- a folded cloth at the side of the bottom shelf, so it never looks bare
		B.box("CupboardCloth", 0.7, 0.18, idp * 0.6, W / 2 - T - 0.45, fy + 0.09, iz, c.petalTip, FABRIC)
		B.box("CupboardCloth", 0.72, 0.06, idp * 0.62, W / 2 - T - 0.45, fy + 0.12, iz, shade(c.petalTip, 0.25), FABRIC)
		local dy, dh = base + 0.04, H - base - 0.1
		local dw = W / 2 - 0.04
		local knob = c.center
		growDoor(B, "DoorA", -1, -W / 2 + 0.02, dy, dw, dh, -D / 2, 0, wood, knob)
		growDoor(B, "DoorB", 1, W / 2 - 0.02, dy, dw, dh, -D / 2, 0, wood, knob)
		-- Opened (FurnitureUse): the doors swung open, and the find.
		local from = #B.parts
		local open = FurnitureUse.DOOR_OPEN_ANGLE
		growDoor(B, "DoorAOpen", -1, -W / 2 + 0.02, dy, dw, dh, -D / 2, open, wood, knob)
		growDoor(B, "DoorBOpen", 1, W / 2 - 0.02, dy, dw, dh, -D / 2, open, wood, knob)
		B.hideSince(from)
		from = #B.parts
		cupboardGold(B, c, -0.35, fy, iz, W - 2 * T)
		B.hideSince(from)
	end,
}

-- A low sideboard on stubby legs: two or three doors over a shelf of
-- crockery, a find (sometimes) on the bottom, and a jar or bowl on top.
PIECES.sideboard = {
	place = "wall", corner = 0.3, access = 1.4,
	params = function(rng)
		local W, H, D = rng:NextNumber(4, 5.2), rng:NextNumber(2.4, 2.9), rng:NextNumber(1.5, 1.7)
		return { w = W + 0.3, d = D + 0.15, h = H + 1, W = W, H = H, D = D, doors = if W > 4.6 then 3 else 2, top = rng:NextInteger(1, 3) }
	end,
	build = function(B, c, p, rng)
		local W, H, D = p.W, p.H, p.D
		local wood = frameWood(c)
		local inside = shade(wood, -0.35)
		local T = 0.2
		local z0 = -D / 2 + DOOR_T
		local zb = D / 2 - T
		local iz, idp = (z0 + zb) / 2, zb - z0
		local base = 0.4
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				B.cyl("Sideboard", 0.32, sx * (W / 2 - 0.3), 0, base, sz * (D / 2 - 0.35), shade(wood, -0.25), WOOD)
			end
			B.box("Sideboard", T, H - base, D - DOOR_T, sx * (W / 2 - T / 2), base + (H - base) / 2, (z0 + D / 2) / 2, wood, WOOD, true)
		end
		B.box("SideboardBack", W - 2 * T + 0.02, H - base, T, 0, base + (H - base) / 2, D / 2 - T / 2, inside, WOOD, true)
		B.box("SideboardFloor", W - 0.1, 0.14, D - DOOR_T - 0.04, 0, base + 0.07, (z0 + D / 2) / 2, shade(wood, -0.15), WOOD, true)
		B.slab("SideboardTop", W + 0.3, 0.24, D + 0.14, 0, H + 0.12, -0.05, shade(wood, 0.2), WOOD, true, 0.15)
		B.box("SideboardTrim", W + 0.16, 0.1, 0.1, 0, H + 0.01, -D / 2 - 0.02, c.petalBase, SMOOTH)
		local fy = base + 0.14
		local mid = fy + (H - fy) * 0.5
		B.box("CupboardShelf", W - 2 * T + 0.02, 0.1, idp, 0, mid - 0.05, iz, shade(inside, 0.1), WOOD)
		crockery(B, c, rng, -W / 2 + T, W / 2 - T, mid, zb, H - mid - 0.15)
		-- on top: a jar of flowers, a bowl of fruit or a teapot-ish pot
		local ty = H + 0.24
		if p.top == 1 then
			B.cyl("SideboardVase", 0.5, W * 0.28, ty, ty + 0.7, 0, CLAY)
			for i = 1, 3 do
				local a = i * 2.1
				B.ball("SideboardBloom", 0.32, W * 0.28 + math.cos(a) * 0.18, ty + 0.85 + i * 0.04, math.sin(a) * 0.18, if i == 2 then c.petalTip else c.petalBase)
			end
		elseif p.top == 2 then
			B.cyl("SideboardBowl", 0.9, -W * 0.26, ty, ty + 0.22, 0, CLAY:Lerp(CREAM, 0.3))
			for i = 1, 4 do
				local a = i * 2.4
				B.ball("SideboardFruit", 0.3, -W * 0.26 + math.cos(a) * 0.2, ty + 0.3, math.sin(a) * 0.2, if i % 2 == 0 then c.petalTip else c.center)
			end
		else
			B.egg("SideboardPot", 0.7, 0.6, 0.7, W * 0.25, ty + 0.3, 0.05, c.petalBase)
			B.cyl("SideboardPot", 0.22, W * 0.25, ty + 0.55, ty + 0.68, 0.05, shade(c.petalBase, -0.2))
			B.rod("SideboardPot", Vector3.new(W * 0.25 - 0.3, ty + 0.35, 0.05), Vector3.new(W * 0.25 - 0.55, ty + 0.55, 0.05), 0.1, shade(c.petalBase, -0.2))
		end
		-- the doors: the first hinged on the left, the last on the right, any
		-- middle one on its left
		local n = p.doors
		local slot = (W - 0.06) / n
		local dy, dh = base + 0.03, H - base - 0.08
		local names = { "DoorA", "DoorB", "DoorC" }
		local function doors(suffix: string, angle: number)
			for i = 1, n do
				local left = -W / 2 + 0.03 + (i - 1) * slot
				local sx = if i == n then 1 else -1
				local hx = if sx < 0 then left + 0.01 else left + slot - 0.01
				growDoor(B, names[i] .. suffix, sx, hx, dy, slot - 0.04, dh, -D / 2, angle, wood, c.center)
			end
		end
		doors("", 0)
		local from = #B.parts
		doors("Open", FurnitureUse.DOOR_OPEN_ANGLE)
		B.hideSince(from)
		from = #B.parts
		cupboardGold(B, c, -0.3, fy, iz, W - 2 * T)
		B.hideSince(from)
	end,
}

-- A petal rug: layered ovals (rim, field, centre) with a scalloped petal edge.
PIECES.rug = {
	place = "free", flat = true, access = 0,
	params = function(rng)
		local R = rng:NextNumber(2.4, 3.4)
		local k = rng:NextNumber(0.7, 1)
		return { w = 2 * R + 0.6, d = 2 * R * k + 0.6, h = 0.12, R = R, k = k, petals = rng:NextInteger(10, 16), swap = rng:NextNumber() < 0.5 }
	end,
	build = function(B, c, p)
		local R, k = p.R, p.k
		local outer, field = c.petalTip, c.petalBase
		if p.swap then
			outer, field = field, outer
		end
		for i = 0, p.petals - 1 do
			local a = i / p.petals * TAU
			local x, z = math.cos(a) * R, math.sin(a) * R * k
			B.egg("RugPetal", 1.1, 0.06, 0.75, x, 0.03, z, shade(outer, -0.12), M.petal, CFrame.Angles(0, -math.atan2(z, x), 0))
		end
		B.egg("RugRim", 2 * R, 0.08, 2 * R * k, 0, 0.04, 0, outer, FABRIC)
		B.egg("RugField", 2 * R * 0.78, 0.1, 2 * R * k * 0.78, 0, 0.05, 0, field, FABRIC)
		B.egg("RugStripe", 2 * R * 0.55, 0.11, 2 * R * k * 0.55, 0, 0.055, 0, shade(field, 0.35), FABRIC)
		B.egg("RugCentre", 2 * R * 0.3, 0.12, 2 * R * k * 0.3, 0, 0.06, 0, c.center, M.center)
	end,
}

-- A dandelion-fluff beanbag with a backrest bulge, a seat dent and fluff tufts.
PIECES.beanbag = {
	place = "free", access = 1,
	params = function(rng)
		local D = rng:NextNumber(2.5, 3.1)
		return { w = D, d = D, h = D * 0.75, D = D, tufts = rng:NextInteger(5, 7) }
	end,
	build = function(B, c, p)
		local D = p.D
		B.egg("Beanbag", D, D * 0.55, D, 0, D * 0.27, 0, CREAM, FABRIC)
		B.egg("BeanbagBack", D * 0.85, D * 0.6, D * 0.45, 0, D * 0.48, D * 0.26, shade(CREAM, -0.04), FABRIC)
		B.egg("BeanbagSeat", D * 0.6, 0.25, D * 0.5, 0, D * 0.52, -D * 0.08, shade(CREAM, -0.14), FABRIC)
		for i = 1, p.tufts do
			local a = i / p.tufts * TAU
			B.ball("BeanbagTuft", 0.45, math.cos(a) * D * 0.42, D * 0.42, math.sin(a) * D * 0.42, shade(CREAM, 0.3), FABRIC)
		end
		B.egg("BeanbagSeed", 0.35, 0.25, 0.7, 0, 0.12, -D * 0.5, shade(c.center, -0.3), M.seed)
	end,
}

-- A petal armchair: a padded base on short legs, a seat cushion, rolled arms
-- and a back crowned with petals.
PIECES.armchair = {
	place = "free", access = 1.2,
	params = function(rng)
		local W = rng:NextNumber(2.7, 3.2)
		return { w = W, d = W * 0.9, h = 3.6, W = W, petals = rng:NextInteger(3, 5) }
	end,
	build = function(B, c, p)
		local W, D = p.W, p.W * 0.9
		local cloth = c.petalBase
		local wood = frameWood(c)
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				B.cyl("ChairLeg", 0.32, sx * (W / 2 - 0.35), 0, 0.35, sz * (D / 2 - 0.35), wood, WOOD)
			end
		end
		B.slab("ChairBase", W, 0.85, D, 0, 0.78, 0, cloth, FABRIC, true, 0.3)
		B.slab("ChairCushion", W - 0.9, 0.4, D - 0.5, 0, 1.4, -0.2, CREAM:Lerp(cloth, 0.3), FABRIC, false, 0.25)
		B.box("ChairBack", W - 0.1, 1.9, 0.55, 0, 2.12, D / 2 - 0.3, cloth, FABRIC)
		B.logX("ChairBackRoll", W, 0.6, 0, 3.05, D / 2 - 0.3, shade(cloth, -0.1), FABRIC)
		for i = 1, p.petals do
			local x = (i - (p.petals + 1) / 2) * (W / p.petals)
			B.egg("ChairPetal", W / p.petals * 1.1, 1.1, 0.35, x, 3.25, D / 2 - 0.35, if i % 2 == 0 then c.petalTip else shade(cloth, 0.1), M.petal)
		end
		for _, sx in { -1, 1 } do
			B.box("ChairArm", 0.5, 0.75, D - 0.4, sx * (W / 2 - 0.28), 1.57, -0.02, shade(cloth, -0.05), FABRIC)
			B.logZ("ChairArmRoll", D - 0.3, 0.62, sx * (W / 2 - 0.28), 1.97, -0.05, shade(cloth, 0.12), FABRIC)
		end
		B.box("ChairPiping", W + 0.03, 0.1, D + 0.03, 0, 1.0, 0, c.petalTip, FABRIC)
	end,
}

-- Glowing seed jars on a tree-stump stand.
PIECES.jars = {
	place = "wall", corner = 0.5, access = 0.8,
	params = function(rng)
		local n = rng:NextInteger(2, 4)
		local jars = {}
		for i = 1, n do
			local a = i / n * TAU + rng:NextNumber(-0.3, 0.3)
			local r = if n <= 2 then 0.45 else 0.58
			table.insert(jars, { x = math.cos(a) * r, z = math.sin(a) * r, h = rng:NextNumber(0.8, 1.6) + i * 0.04, d = rng:NextNumber(0.5, 0.68) })
		end
		return { w = 2.2, d = 2.2, h = 2.4, jars = jars }
	end,
	build = function(B, c, p)
		B.cyl("JarStump", 2, 0, 0, 0.6, 0, BARK, WOOD, true)
		B.cyl("JarStumpRing", 1.85, 0, 0.6, 0.66, 0, shade(BARK, 0.35), WOOD)
		B.cyl("JarStumpCore", 0.6, 0, 0.66, 0.68, 0, shade(BARK, 0.1), WOOD)
		local glows = { c.petalBase:Lerp(GLOW, 0.5), c.petalTip:Lerp(GLOW, 0.5), GLOW, c.center:Lerp(GLOW, 0.4) }
		for i, j in p.jars do
			local y0 = 0.68
			B.cyl("Jar", j.d, j.x, y0, y0 + j.h, j.z, GLASS, Enum.Material.Glass)
			local jarGlow = B.ball("JarGlow", j.d * 0.6, j.x, y0 + j.h * 0.42, j.z, glows[(i - 1) % #glows + 1], M.habitatGlow)
			if i == 1 then
				B.light(jarGlow, GLOW, 0.9, 11)
			end
			B.cyl("JarBand", j.d + 0.04, j.x, y0 + j.h - 0.28, y0 + j.h - 0.2, j.z, HONEY)
			B.cyl("JarLid", j.d + 0.08, j.x, y0 + j.h, y0 + j.h + 0.14, j.z, BARK, WOOD)
			B.ball("JarKnob", 0.2, j.x, y0 + j.h + 0.2, j.z, shade(BARK, -0.2), WOOD)
		end
	end,
}

-- A pot plant: a rimmed clay pot with a painted band, soil, and a seeded plant
-- of stalks with leaves, a bud or two.
PIECES.planter = {
	place = "wall", corner = 0.7, access = 0.6,
	params = function(rng)
		local D, H = rng:NextNumber(1.2, 1.7), rng:NextNumber(0.9, 1.3)
		local shoots = {}
		for i = 1, rng:NextInteger(3, 5) do
			local a = i * 2.4 + rng:NextNumber(-0.4, 0.4)
			table.insert(shoots, { a = a, lean = rng:NextNumber(0.15, 0.45), len = rng:NextNumber(1, 2), bud = rng:NextNumber() < 0.35 })
		end
		return { w = D + 0.6, d = D + 0.6, h = H + 2.2, D = D, H = H, shoots = shoots }
	end,
	build = function(B, c, p)
		local D, H = p.D, p.H
		B.cyl("PlanterPot", D * 0.82, 0, 0, H * 0.8, 0, CLAY, Enum.Material.Slate, true)
		B.cyl("PlanterBand", D * 0.84, 0, H * 0.32, H * 0.42, 0, c.petalTip)
		B.cyl("PlanterRim", D, 0, H * 0.75, H, 0, shade(CLAY, 0.12), Enum.Material.Slate)
		B.cyl("PlanterSoil", D * 0.86, 0, H - 0.06, H + 0.01, 0, SOIL, Enum.Material.Ground)
		for _, s in p.shoots do
			local dir = Vector3.new(math.cos(s.a) * s.lean, 1, math.sin(s.a) * s.lean).Unit
			local base = Vector3.new(0, H, 0)
			local tip = base + dir * s.len
			B.rod("PlanterShoot", base, tip, 0.1, c.stem, M.stem)
			if s.bud then
				B.ball("PlanterBud", 0.38, tip.X, tip.Y + 0.1, tip.Z, c.petalBase, M.petal)
			else
				local out = Vector3.new(dir.X, 0, dir.Z)
				local yaw = math.atan2(-out.Z, out.X)
				B.box("PlanterLeaf", 0.95, 0.05, 0.42, tip.X + out.X * 0.35, tip.Y, tip.Z + out.Z * 0.35, c.leaf, M.leaf, false, CFrame.Angles(0, yaw, 0) * CFrame.Angles(0.25, 0, 0))
				B.box("PlanterVein", 0.85, 0.06, 0.05, tip.X + out.X * 0.35, tip.Y + 0.01, tip.Z + out.Z * 0.35, shade(c.leaf, 0.35), M.leaf, false, CFrame.Angles(0, yaw, 0) * CFrame.Angles(0.25, 0, 0))
			end
		end
	end,
}

-- A window box of little flowers, under a window.
PIECES.windowBox = {
	place = "window", walls = { back = 1, left = 1, right = 1 }, access = 0.8,
	params = function(rng)
		local W = rng:NextNumber(3.6, 4.4)
		local flowers = {}
		local n = rng:NextInteger(4, 6)
		for i = 1, n do
			-- spread evenly with a little wobble, so neighbours don't overlap
			local t = -0.42 + (i - 0.5) / n * 0.84 + rng:NextNumber(-0.03, 0.03)
			table.insert(flowers, { t = t, h = rng:NextNumber(0.5, 1), tip = rng:NextNumber() < 0.5 })
		end
		return { w = W, d = 1.3, h = 2.3, W = W, flowers = flowers }
	end,
	build = function(B, c, p)
		local W = p.W
		local wood = frameWood(c)
		for _, sx in { -1, 1 } do
			B.box("WindowBoxLeg", 0.3, 0.9, 0.3, sx * (W / 2 - 0.45), 0.45, 0.1, shade(wood, -0.2), WOOD)
		end
		B.slab("WindowBox", W, 0.75, 1.2, 0, 1.25, 0, wood, PLANKS, true, 0.15)
		B.box("WindowBoxRim", W + 0.1, 0.16, 1.3, 0, 1.66, 0, shade(wood, 0.25), WOOD)
		B.box("WindowBoxSoil", W - 0.25, 0.06, 0.95, 0, 1.66, 0, SOIL, Enum.Material.Ground)
		for _, f in p.flowers do
			local x = f.t * W
			B.rod("WindowBoxStalk", Vector3.new(x, 1.66, 0), Vector3.new(x, 1.7 + f.h, 0), 0.08, c.stem, M.stem)
			B.box("WindowBoxLeaf", 0.5, 0.04, 0.22, x + 0.22, 1.85 + f.h * 0.3, 0, c.leaf, M.leaf, false, CFrame.Angles(0, 0, 0.4))
			local col = if f.tip then c.petalTip else c.petalBase
			for k = 0, 4 do
				local a = k / 5 * TAU
				B.ball("WindowBoxPetal", 0.26, x + math.cos(a) * 0.16, 1.72 + f.h, math.sin(a) * 0.16, col, M.petal)
			end
			B.ball("WindowBoxHeart", 0.18, x, 1.75 + f.h, 0, c.center, M.center)
		end
	end,
}

-- A firefly floor lantern: a footed stalk that curls over, a glowing bulb
-- hanging from it under a cup of petals.
PIECES.lantern = {
	place = "wall", corner = 1, access = 0,
	walls = { back = 0.8, left = 0.9, right = 0.9, front = 0.8 },
	params = function(rng)
		local H = rng:NextNumber(4, 5)
		return { w = 1.3, d = 2.2, h = H + 0.3, H = H, petals = rng:NextInteger(4, 6) }
	end,
	build = function(B, c, p)
		local H = p.H
		local z0 = 0.45 -- the stalk stands toward the back; the bulb hangs out front
		B.cyl("LanternFoot", 1.2, 0, 0, 0.16, z0, shade(c.leaf, -0.15), M.leaf)
		B.cyl("LanternFootTop", 0.75, 0, 0.16, 0.32, z0, c.leaf, M.leaf)
		local pts = {
			Vector3.new(0, 0.3, z0),
			Vector3.new(0, H - 0.7, z0),
			Vector3.new(0, H - 0.1, z0 - 0.3),
			Vector3.new(0, H + 0.1, z0 - 0.9),
			Vector3.new(0, H - 0.2, z0 - 1.35),
		}
		for i = 1, #pts - 1 do
			B.rod("LanternStalk", pts[i], pts[i + 1], 0.2, c.stem, M.stem)
			B.ball("LanternJoint", 0.2, pts[i + 1].X, pts[i + 1].Y, pts[i + 1].Z, c.stem, M.stem)
		end
		local bx, by, bz = 0, H - 0.75, z0 - 1.35
		local bulb = B.ball("LanternBulb", 0.62, bx, by, bz, GLOW, M.habitatGlow)
		B.light(bulb, GLOW, 1.4, 18)
		B.ball("LanternCap", 0.32, bx, by + 0.42, bz, shade(Palette.SEPAL, -0.15), M.sepal)
		for i = 1, p.petals do
			local a = i / p.petals * TAU
			B.egg("LanternShade", 0.4, 0.06, 0.62, bx + math.cos(a) * 0.26, by + 0.3, bz + math.sin(a) * 0.26, c.petalBase, M.petal, CFrame.Angles(0, -a + HALF_PI, 0) * CFrame.Angles(0.75, 0, 0))
		end
	end,
}

-- A leaf hammock slung between two posts: a sagging striped sling, ropes, a pillow.
PIECES.hammock = {
	place = "wall", corner = 0, access = 1.4,
	params = function(rng)
		local L = rng:NextNumber(5.8, 7)
		return { w = L + 0.6, d = 2.3, h = 3.9, L = L, sag = rng:NextNumber(1, 1.4) }
	end,
	build = function(B, c, p)
		local L = p.L
		local wood = frameWood(c)
		for _, sx in { -1, 1 } do
			B.cyl("HammockPost", 0.45, sx * L / 2, 0, 3.6, 0, wood, WOOD, true)
			B.ball("HammockKnob", 0.55, sx * L / 2, 3.65, 0, c.petalTip)
		end
		local seg = 8
		local half = L / 2 - 0.6
		local hi = 2.9
		local function at(t: number): Vector3
			local x = -half + t * 2 * half
			return Vector3.new(x, hi - p.sag * (1 - (2 * t - 1) ^ 2), 0)
		end
		for i = 0, seg - 1 do
			local a, b = at(i / seg), at((i + 1) / seg)
			local mid = (a + b) / 2
			local slope = math.atan2(b.Y - a.Y, b.X - a.X)
			B.box("HammockSling", (b - a).Magnitude + 0.04, if i % 2 == 0 then 0.12 else 0.15, if i % 2 == 0 then 1.9 else 1.86, mid.X, mid.Y, 0, if i % 2 == 0 then c.leaf else shade(c.leaf, 0.18), M.leaf, i == seg // 2, CFrame.Angles(0, 0, slope))
		end
		for _, t in { 0, 1 } do
			local e = at(t)
			local post = Vector3.new(if t == 0 then -L / 2 else L / 2, 3.2, 0)
			for _, sz in { -0.85, 0.85 } do
				B.rod("HammockRope", post, Vector3.new(e.X, e.Y, sz), 0.08, CREAM)
			end
		end
		local head = at(0.18)
		B.egg("HammockPillow", 1.1, 0.5, 1.2, head.X, head.Y + 0.3, 0, CREAM, FABRIC)
	end,
}

-- Leaf-wrapped parcels, stacked, each tied with a cross of ribbon and a bow.
PIECES.parcels = {
	place = "wall", corner = 0.6, access = 0.8,
	params = function(rng)
		local s = rng:NextNumber(1.4, 1.8)
		local wide = rng:NextNumber() < 0.5
		local stack = {}
		if wide then
			table.insert(stack, { x = -s * 0.52, y = 0, s = s, turn = rng:NextNumber(-0.15, 0.15) })
			table.insert(stack, { x = s * 0.52, y = 0, s = s * 0.92, turn = rng:NextNumber(-0.15, 0.15) })
			table.insert(stack, { x = rng:NextNumber(-0.3, 0.3), y = s * 0.8, s = s * 0.8, turn = rng:NextNumber(-0.4, 0.4) })
		else
			local y = 0
			for i = 0, rng:NextInteger(1, 2) do
				local si = s * (1 - i * 0.18)
				table.insert(stack, { x = rng:NextNumber(-0.2, 0.2), y = y, s = si, turn = rng:NextNumber(-0.4, 0.4) })
				y += si * 0.8
			end
		end
		local top = 0
		for _, b in stack do
			top = math.max(top, b.y + b.s * 0.8)
		end
		return { w = if wide then 2.1 * s else s * 1.3, d = s * 1.3, h = top + 0.4, stack = stack }
	end,
	build = function(B, c, p)
		for i, b in p.stack do
			local s, h = b.s, b.s * 0.8
			local rot = CFrame.Angles(0, b.turn, 0)
			local col = if i % 2 == 1 then c.leaf else shade(c.leaf, -0.22)
			local tie = if i % 2 == 1 then c.petalTip else HONEY
			local cy = b.y + h / 2
			B.box("Parcel", s, h, s, b.x, cy, 0, col, M.leaf, i == 1, rot)
			B.box("ParcelTie", s + 0.04, h + 0.04, 0.16, b.x, cy, 0, tie, FABRIC, false, rot)
			B.box("ParcelTie", 0.16, h + 0.07, s + 0.07, b.x, cy, 0, tie, FABRIC, false, rot)
			local top = b.y + h + 0.06
			B.egg("ParcelBow", 0.5, 0.22, 0.3, b.x - 0.2 * math.cos(b.turn), top, 0.2 * math.sin(b.turn), tie, FABRIC, rot * CFrame.Angles(0, 0, 0.4))
			B.egg("ParcelBow", 0.5, 0.22, 0.3, b.x + 0.2 * math.cos(b.turn), top, -0.2 * math.sin(b.turn), tie, FABRIC, rot * CFrame.Angles(0, 0, -0.4))
			B.ball("ParcelKnot", 0.18, b.x, top, 0, shade(tie, -0.2), FABRIC)
			if i == #p.stack then
				-- Unwrapped (FurnitureUse): a glowing seed pod on the top parcel.
				local from = #B.parts
				B.egg("ParcelGift", 0.45, 0.6, 0.45, b.x, top + 0.25, 0, HONEY, M.habitatGlow)
				B.hideSince(from)
			end
		end
	end,
}

-- A honey dresser: a cupboard with panel doors under a counter top, and a
-- back board of honey cells (some brimming, some capped with wax).
PIECES.honeycomb = {
	place = "wall", walls = { back = 1, left = 0.9, right = 0.9, front = 0.3 }, corner = 0.1, access = 1.6,
	params = function(rng)
		local W = rng:NextNumber(3.8, 4.8)
		local cells = {}
		for k = 1, 40 do
			cells[k] = rng:NextNumber()
		end
		return { w = W + 0.2, d = 1.9, h = 5.3, W = W, cells = cells }
	end,
	build = function(B, c, p)
		local W, D = p.W, 1.8
		local wood = shade(BARK, 0.05)
		B.slab("CombBody", W, 1.9, D - 0.1, 0, 0.95, 0.05, wood, WOOD, true, 0.15)
		B.slab("CombTop", W + 0.2, 0.22, D + 0.1, 0, 2.0, 0, shade(wood, 0.3), WOOD, false, 0.1)
		B.box("CombKick", W - 0.2, 0.3, 0.1, 0, 0.15, -D / 2 + 0.02, shade(wood, -0.3), WOOD)
		for _, sx in { -1, 1 } do
			local x = sx * W / 4
			B.box("CombDoor", W / 2 - 0.45, 1.3, 0.08, x, 1.05, -D / 2 + 0.06, shade(wood, -0.15), WOOD)
			B.box("CombPanel", W / 2 - 0.9, 0.85, 0.06, x, 1.05, -D / 2 + 0.02, shade(wood, 0.1), WOOD)
			B.ball("CombKnob", 0.2, x - sx * (W / 4 - 0.45), 1.15, -D / 2 - 0.02, HONEY)
		end
		B.box("CombBoard", W, 3.2, 0.25, 0, 2.11 + 1.6, D / 2 - 0.13, shade(wood, -0.1), WOOD)
		B.box("CombBoardCap", W + 0.15, 0.2, 0.45, 0, 5.2, D / 2 - 0.2, shade(wood, 0.25), WOOD)
		local cell = 0.62
		local cols = math.floor((W - 0.5) / (cell + 0.06))
		local k = 0
		for row = 0, 3 do
			local off = if row % 2 == 1 then (cell + 0.06) / 2 else 0
			for col = 0, cols - 1 do
				local x = -(cols - 1) * (cell + 0.06) / 2 + col * (cell + 0.06) + off
				if math.abs(x) < W / 2 - 0.35 then
					k += 1
					local v = p.cells[(k - 1) % #p.cells + 1]
					local colr = if v < 0.25 then shade(HONEY, 0.45) elseif v < 0.7 then HONEY else shade(HONEY, -0.2)
					B.logZ("CombCell", 0.16, cell, x, 2.6 + row * 0.62, D / 2 - 0.3, colr, if v < 0.25 then FABRIC else SMOOTH)
				end
			end
		end
		B.cyl("CombPot", 0.8, -W / 2 + 0.7, 2.1, 2.8, -0.2, CLAY, Enum.Material.Slate)
		B.cyl("CombPotHoney", 0.7, -W / 2 + 0.7, 2.8, 2.85, -0.2, HONEY)
		B.rod("CombDipper", Vector3.new(-W / 2 + 0.75, 2.6, -0.2), Vector3.new(-W / 2 + 1, 3.3, -0.35), 0.1, BARK, WOOD)
	end,
}

-- A pebble hearth with an acorn pot over the embers and a ladle.
PIECES.stove = {
	place = "wall", walls = { back = 1, left = 0.8, right = 0.8 }, corner = 0.2, access = 1.6,
	params = function(rng)
		local W = rng:NextNumber(2.8, 3.3)
		return { w = W + 0.4, d = W + 0.4, h = 2.6, W = W, soup = rng:NextNumber() < 0.5 }
	end,
	build = function(B, c, p)
		local W = p.W
		B.cyl("StoveHearth", W, 0, 0, 0.45, 0, STONE, Enum.Material.Slate, true)
		for i = 0, 11 do
			local a = i / 12 * TAU
			B.ball("StovePebble", 0.55, math.cos(a) * W * 0.48, 0.45, math.sin(a) * W * 0.48, shade(STONE, if i % 2 == 0 then -0.1 else 0.12), Enum.Material.Slate)
		end
		-- Embers wider than the pot so they show round it, and flame tongues
		-- licking up its sides: lit or put out (FurnitureUse) is plain to see.
		local embers = B.cyl("StoveEmbers", W * 0.86, 0, 0.45, 0.62, 0, EMBER, M.habitatGlow)
		B.light(embers, EMBER, 1.6, 14)
		for i = 0, 5 do
			local a = i / 6 * TAU + 0.25
			local r = W * 0.37
			local big = i % 2 == 0
			B.egg("StoveFlame", if big then 0.45 else 0.35, if big then 1.0 else 0.75, if big then 0.45 else 0.35, math.cos(a) * r, if big then 1.05 else 0.95, math.sin(a) * r, if big then EMBER else FLAME, M.habitatGlow)
		end
		for i = 0, 2 do
			local a = i / 3 * TAU + 0.5
			B.rod("StoveLeg", Vector3.new(math.cos(a) * W * 0.3, 0.45, math.sin(a) * W * 0.3), Vector3.new(math.cos(a) * W * 0.28, 1.0, math.sin(a) * W * 0.28), 0.2, INK)
		end
		local pot = shade(BARK, -0.35)
		B.cyl("StovePotBase", W * 0.5, 0, 0.75, 1.0, 0, pot, WOOD)
		B.cyl("StovePot", W * 0.66, 0, 1.0, 1.95, 0, pot, WOOD)
		B.cyl("StovePotRim", W * 0.72, 0, 1.85, 2.05, 0, shade(pot, 0.3), WOOD)
		local soup = if p.soup then c.petalTip:Lerp(EMBER, 0.4) else Color3.fromRGB(150, 190, 80)
		B.cyl("StoveSoup", W * 0.6, 0, 2.0, 2.06, 0, soup)
		B.rod("StoveLadle", Vector3.new(0.2, 1.9, 0.1), Vector3.new(0.7, 2.9, 0.4), 0.12, BARK, WOOD)
		B.ball("StoveLadleCup", 0.4, 0.15, 2.0, 0.05, shade(BARK, -0.2), WOOD)
	end,
}

-- A teacup table: a cup on its saucer, tapered, banded, polka-dotted, with tea.
PIECES.teacup = {
	place = "free", access = 0, seats = { id = "stool", n = { 2, 3 } },
	params = function(rng)
		local D = rng:NextNumber(2, 2.5)
		return { w = D + 1.6, d = D + 1.6, h = 2.2, D = D, dots = rng:NextInteger(4, 7), turn = rng:NextNumber() * TAU }
	end,
	build = function(B, c, p)
		local D = p.D
		B.cyl("Saucer", D + 1.4, 0, 0, 0.16, 0, CREAM, SMOOTH, true)
		B.cyl("SaucerLip", D + 1.6, 0, 0.12, 0.24, 0, shade(CREAM, -0.06))
		B.cyl("SaucerWell", D * 0.85, 0, 0.2, 0.27, 0, c.petalBase)
		B.cyl("TeacupFoot", D * 0.62, 0, 0.24, 0.5, 0, CREAM)
		B.cyl("TeacupLow", D * 0.82, 0, 0.5, 1, 0, CREAM, SMOOTH, true)
		B.cyl("Teacup", D, 0, 1, 2.05, 0, CREAM, SMOOTH, true)
		B.cyl("TeacupBand", D + 0.03, 0, 1.75, 1.92, 0, c.petalBase)
		B.cyl("TeacupLipLine", D + 0.03, 0, 1.98, 2.03, 0, HONEY)
		B.cyl("Tea", D - 0.16, 0, 1.96, 2.06, 0, Color3.fromRGB(170, 100, 50))
		local h0 = Vector3.new(D / 2 - 0.05, 1.8, 0)
		local pts = { h0, Vector3.new(D / 2 + 0.55, 1.65, 0), Vector3.new(D / 2 + 0.55, 1.15, 0), Vector3.new(D / 2 - 0.05, 1.0, 0) }
		for i = 1, 3 do
			B.rod("TeacupHandle", pts[i], pts[i + 1], 0.22, CREAM)
		end
		for i = 1, p.dots do
			local a = p.turn + i / p.dots * TAU
			local y = if i % 2 == 0 then 1.25 else 1.5
			B.ball("TeacupDot", 0.24, math.cos(a) * D / 2, y, math.sin(a) * D / 2, c.petalTip)
		end
	end,
}

-- A moss bed for a ride bug: a log-ring rim round a moss cushion, with tufts.
PIECES.mossbed = {
	place = "wall", corner = 0.4, along = true, access = 1.2,
	params = function(rng)
		local A, C = rng:NextNumber(2.6, 3.1), rng:NextNumber(1.8, 2.1)
		return { w = 2 * A + 0.6, d = 2 * C + 0.6, h = 1, A = A, C = C, tufts = rng:NextInteger(3, 5) }
	end,
	build = function(B, c, p)
		local A, C = p.A, p.C
		local rim = shade(c.stem:Lerp(BARK, 0.5), -0.15)
		local n = 12
		local function at(i: number): Vector3
			local a = i / n * TAU
			return Vector3.new(math.cos(a) * A, 0.35, math.sin(a) * C)
		end
		for i = 0, n - 1 do
			B.rod("MossRim", at(i), at(i + 1), 0.6, if i % 2 == 0 then rim else shade(rim, 0.15), WOOD)
			local q = at(i)
			B.ball("MossRimJoint", 0.6, q.X, q.Y, q.Z, rim, WOOD)
		end
		B.egg("MossBed", 2 * A - 0.5, 0.8, 2 * C - 0.5, 0, 0.3, 0, MOSS, Enum.Material.Grass)
		for i = 1, p.tufts do
			local a = i * 2.3
			B.ball("MossTuft", 0.5, math.cos(a) * A * 0.45, 0.6, math.sin(a) * C * 0.45, shade(MOSS, 0.25), Enum.Material.Grass)
		end
	end,
}

-- A nectar trough: a hollowed log on two cradles, cut-ring ends, nectar inside.
PIECES.trough = {
	place = "wall", corner = 0.2, access = 1.2,
	params = function(rng)
		local L = rng:NextNumber(3.6, 4.4)
		return { w = L + 0.2, d = 1.6, h = 1.7, L = L }
	end,
	build = function(B, c, p)
		local L = p.L
		for _, sx in { -1, 1 } do
			B.box("TroughCradle", 0.4, 0.5, 1.5, sx * L / 3, 0.25, 0, shade(BARK, -0.3), WOOD)
		end
		B.logX("TroughLog", L, 1.4, 0, 0.85, 0, BARK, WOOD, true)
		for _, sx in { -1, 1 } do
			B.logX("TroughEnd", 0.06, 1.3, sx * (L / 2 + 0.01), 0.85, 0, shade(BARK, 0.4), WOOD)
			B.logX("TroughEndRing", 0.07, 0.7, sx * (L / 2 + 0.02), 0.85, 0, shade(BARK, 0.15), WOOD)
		end
		B.box("TroughNectar", L - 0.5, 0.06, 0.8, 0, 1.56, 0, HONEY, SMOOTH)
		B.box("TroughLip", L - 0.4, 0.05, 0.12, 0, 1.56, -0.46, shade(BARK, 0.25), WOOD)
		B.box("TroughLip", L - 0.4, 0.05, 0.12, 0, 1.56, 0.46, shade(BARK, 0.25), WOOD)
	end,
}

-- A telescope on a tripod, pointing up and out of the window behind it.
PIECES.telescope = {
	place = "window", walls = { back = 1, left = 1, right = 1 }, access = 1.2,
	params = function(rng)
		return { w = 2, d = 2.4, h = 3.8, tilt = rng:NextNumber(0.25, 0.45) }
	end,
	build = function(B, c, p)
		local head = Vector3.new(0, 2.7, -0.2)
		for i = 0, 2 do
			local a = i / 3 * TAU + HALF_PI
			B.rod("TelescopeLeg", head, Vector3.new(math.cos(a) * 0.85, 0, -0.2 + math.sin(a) * 0.85), 0.16, c.stem, M.stem)
		end
		B.ball("TelescopeHead", 0.4, head.X, head.Y, head.Z, HONEY)
		local aim = CFrame.new(head) * CFrame.Angles(-p.tilt, 0, 0) -- +Z (out of the window behind) tilted up
		local function along(t: number): Vector3
			return (aim * CFrame.new(0, 0.25, t)).Position
		end
		B.rod("TelescopeTube", along(-0.9), along(1.2), 0.62, c.petalBase)
		B.rod("TelescopeHood", along(1.1), along(1.7), 0.8, shade(c.petalBase, -0.2))
		B.rod("TelescopeBand", along(0.2), along(0.32), 0.68, HONEY)
		B.rod("TelescopeBand", along(1.05), along(1.15), 0.86, HONEY)
		B.rod("TelescopeLens", along(1.68), along(1.72), 0.7, GLASS, Enum.Material.Glass)
		B.rod("TelescopeEyepiece", along(-1.3), along(-0.88), 0.3, INK)
	end,
}

-- A writing desk with side panels, a drawer, leaf papers, an ink pot and quill,
-- and a mushroom stool tucked in front.
PIECES.desk = {
	place = "wall", corner = 0.1, access = 0,
	params = function(rng)
		local W, H = rng:NextNumber(3.2, 3.9), rng:NextNumber(2.2, 2.5)
		return { w = W, d = 3.4, h = H + 1, W = W, H = H, left = rng:NextNumber() < 0.5 }
	end,
	build = function(B, c, p, rng)
		local W, H, D = p.W, p.H, 1.7
		local z0 = 3.4 / 2 - D / 2 -- the desk stands at the back, its stool out front
		local wood = frameWood(c)
		B.slab("DeskTop", W, 0.22, D, 0, H - 0.11, z0, shade(wood, 0.25), WOOD, true, 0.15)
		for _, sx in { -1, 1 } do
			B.box("DeskSide", 0.25, H - 0.22, D - 0.2, sx * (W / 2 - 0.2), (H - 0.22) / 2, z0, wood, WOOD, true)
		end
		B.box("DeskBack", W - 0.5, 0.8, 0.12, 0, H - 0.6, z0 + D / 2 - 0.15, shade(wood, -0.2), WOOD)
		local dx = (if p.left then -1 else 1) * W * 0.24
		B.box("DeskDrawer", W * 0.36, 0.5, 0.1, dx, H - 0.5, z0 - D / 2 + 0.12, shade(wood, 0.1), WOOD)
		B.ball("DeskKnob", 0.16, dx, H - 0.5, z0 - D / 2 + 0.04, HONEY)
		-- papers, ink and quill on top
		for k = 0, 2 do
			B.box("DeskPaper", 0.9, 0.04, 1.1, -dx * 0.6 + k * 0.05, H + 0.02 + k * 0.04, z0 - 0.05, if k == 2 then CREAM else shade(c.leaf, 0.3), M.leaf, false, CFrame.Angles(0, (k - 1) * 0.15, 0))
		end
		B.cyl("DeskInk", 0.35, dx * 0.5, H, H + 0.35, z0 + 0.3, INK)
		B.rod("DeskQuill", Vector3.new(dx * 0.5, H + 0.3, z0 + 0.3), Vector3.new(dx * 0.5 + 0.2, H + 1.2, z0 + 0.55), 0.04, CREAM)
		B.egg("DeskFeather", 0.12, 0.7, 0.25, dx * 0.5 + 0.17, H + 1.0, z0 + 0.5, c.petalTip, M.petal, CFrame.Angles(0.3, 0, -0.2))
		-- the stool
		local sz = -3.4 / 2 + 0.75
		B.cyl("DeskStoolStalk", 0.55, 0, 0, H - 0.75, sz, CREAM)
		B.cyl("DeskStoolCap", 1.3, 0, H - 0.75, H - 0.5, sz, if rng:NextNumber() < 0.5 then CAP_RED else c.petalTip)
		B.egg("DeskStoolDome", 1.3, 0.35, 1.3, 0, H - 0.5, sz, if rng:NextNumber() < 0.5 then CAP_RED else c.petalTip)
	end,
}

-- A board on a stand (chalkboard or project board) with pinned notes and a chalk tray.
PIECES.board = {
	place = "wall", walls = { back = 1, left = 0.8, right = 0.8, front = 0.2 }, corner = -0.6, access = 2.4,
	params = function(rng)
		local W = rng:NextNumber(3.6, 4.4)
		local notes = {}
		for i = 1, rng:NextInteger(3, 5) do
			table.insert(notes, { x = rng:NextNumber(-0.38, 0.38), y = rng:NextNumber(0.2, 0.8), r = rng:NextNumber(-0.2, 0.2), k = i })
		end
		return { w = W + 0.4, d = 0.8, h = 4.6, W = W, notes = notes }
	end,
	build = function(B, c, p)
		local W = p.W
		local wood = frameWood(c)
		local y0, h = 1.6, 2.6
		for _, sx in { -1, 1 } do
			B.box("BoardPost", 0.3, 4.4, 0.3, sx * (W / 2 + 0.05), 2.2, 0.1, wood, WOOD, true)
			B.box("BoardFoot", 0.4, 0.2, 0.8, sx * (W / 2 + 0.05), 0.1, 0.1, shade(wood, -0.2), WOOD)
		end
		B.box("Board", W, h, 0.15, 0, y0 + h / 2, 0.1, CHALK, Enum.Material.Slate)
		B.logX("BoardFrame", W + 0.1, 0.22, 0, y0 + h, 0.05, shade(wood, 0.2), WOOD)
		B.logX("BoardFrame", W + 0.1, 0.22, 0, y0, 0.05, shade(wood, 0.2), WOOD)
		B.box("BoardTray", W * 0.8, 0.1, 0.35, 0, y0 - 0.05, -0.12, shade(wood, 0.1), WOOD)
		B.box("BoardChalk", 0.4, 0.1, 0.1, W * 0.2, y0 + 0.04, -0.1, CREAM)
		local noteCols = { CREAM, c.petalBase, shade(c.leaf, 0.35), c.petalTip }
		for _, n in p.notes do
			local x, y = n.x * W, y0 + n.y * h
			B.box("BoardNote", 0.7, 0.7, 0.04, x, y, -0.03 - n.k * 0.015, noteCols[(n.k - 1) % #noteCols + 1], M.leaf, false, CFrame.Angles(0, 0, n.r))
			B.ball("BoardPin", 0.14, x, y + 0.25, -0.08 - n.k * 0.015, CAP_RED)
		end
		B.box("BoardScribble", W * 0.3, 0.06, 0.02, -W * 0.25, y0 + h * 0.55, 0.01, shade(CREAM, -0.1))
		B.box("BoardScribble", W * 0.2, 0.06, 0.02, -W * 0.3, y0 + h * 0.45, 0.01, shade(CREAM, -0.1))
	end,
}

-- A stave water tank on a stone base, with brass hoops, a tap and a bucket.
PIECES.tank = {
	place = "wall", corner = 0.5, access = 1.4,
	params = function(rng)
		local D, H = rng:NextNumber(2.6, 3.2), rng:NextNumber(4, 5)
		return { w = D + 0.2, d = D + 1, h = H + 0.2, D = D, H = H }
	end,
	build = function(B, c, p)
		local D, H = p.D, p.H
		local z0 = 0.4
		B.cyl("TankBase", D * 0.92, 0, 0, 0.35, z0, STONE, Enum.Material.Slate, true)
		B.cyl("Tank", D, 0, 0.35, H, z0, BARK, PLANKS, true)
		for _, y in { 0.8, H * 0.5, H - 0.4 } do
			B.cyl("TankHoop", D + 0.08, 0, y - 0.08, y + 0.08, z0, shade(HONEY, -0.3))
		end
		B.cyl("TankWater", D - 0.25, 0, H + 0.12, H + 0.15, z0, WATER) -- just over the rim disc, so it shows
		B.cyl("TankRim", D + 0.04, 0, H - 0.02, H + 0.12, z0, shade(BARK, 0.3), WOOD)
		local tapZ = z0 - D / 2
		B.rod("TankPipe", Vector3.new(0, 1.2, tapZ + 0.1), Vector3.new(0, 1.2, tapZ - 0.5), 0.3, shade(HONEY, -0.25))
		B.rod("TankSpout", Vector3.new(0, 1.2, tapZ - 0.5), Vector3.new(0, 0.85, tapZ - 0.55), 0.26, shade(HONEY, -0.25))
		B.logX("TankTap", 0.5, 0.14, 0, 1.45, tapZ - 0.45, CAP_RED)
		B.cyl("TankBucket", 0.6, 0, 0, 0.5, tapZ - 0.55, shade(BARK, 0.15), WOOD)
		B.cyl("TankBucketWater", 0.5, 0, 0.45, 0.48, tapZ - 0.55, WATER)
	end,
}

-- A seed barrel: bulging staves, two hoops, a lid, seeds heaped on top.
PIECES.barrel = {
	place = "wall", corner = 0.9, access = 0.6,
	params = function(rng)
		local D, H = rng:NextNumber(1.4, 1.8), rng:NextNumber(1.8, 2.3)
		return { w = D + 0.1, d = D + 0.1, h = H + 0.4, D = D, H = H, seeds = rng:NextInteger(3, 6), open = rng:NextNumber() < 0.6 }
	end,
	build = function(B, c, p, rng)
		local D, H = p.D, p.H
		B.cyl("Barrel", D * 0.88, 0, 0, H * 0.22, 0, BARK, PLANKS, true)
		B.cyl("Barrel", D, 0, H * 0.22, H * 0.78, 0, shade(BARK, 0.05), PLANKS, true)
		B.cyl("Barrel", D * 0.88, 0, H * 0.78, H, 0, BARK, PLANKS)
		for _, y in { H * 0.2, H * 0.8 } do
			B.cyl("BarrelHoop", (if y < H / 2 then D * 0.92 else D * 0.92) + 0.06, 0, y - 0.07, y + 0.07, 0, INK)
		end
		B.cyl("BarrelLid", D * 0.82, 0, H, H + 0.05, 0, shade(BARK, 0.35), WOOD)
		if p.open then
			for _ = 1, p.seeds do
				local a, r = rng:NextNumber() * TAU, rng:NextNumber(0, D * 0.25)
				B.egg("BarrelSeed", 0.32, 0.24, 0.45, math.cos(a) * r, H + 0.15, math.sin(a) * r, shade(c.center, rng:NextNumber(-0.3, 0.1)), M.seed, CFrame.Angles(0, a, 0))
			end
		end
	end,
}

-- A woven basket with a handle, full of seeds and berries.
PIECES.basket = {
	place = "wall", corner = 0.8, access = 0.6,
	params = function(rng)
		local D, H = rng:NextNumber(1.3, 1.7), rng:NextNumber(0.8, 1.1)
		return { w = D + 0.2, d = D + 0.2, h = H + D * 0.6, D = D, H = H, fruit = rng:NextInteger(4, 6), handle = rng:NextNumber() < 0.6 }
	end,
	build = function(B, c, p, rng)
		local D, H = p.D, p.H
		B.cyl("Basket", D * 0.86, 0, 0, H * 0.4, 0, WEAVE, FABRIC, true)
		B.cyl("Basket", D, 0, H * 0.4, H, 0, WEAVE, FABRIC)
		for _, y in { H * 0.4, H * 0.7 } do
			B.cyl("BasketWeave", (if y < H * 0.45 then D * 0.9 else D) + 0.04, 0, y - 0.05, y + 0.05, 0, shade(WEAVE, -0.25), FABRIC)
		end
		B.cyl("BasketRim", D + 0.12, 0, H - 0.08, H + 0.08, 0, shade(WEAVE, 0.25), FABRIC)
		for i = 1, p.fruit do
			local a, r = i * 2.4, rng:NextNumber(0, D * 0.28)
			B.ball("BasketFruit", rng:NextNumber(0.35, 0.5), math.cos(a) * r, H + 0.02, math.sin(a) * r, if i % 2 == 0 then c.petalTip else c.center)
		end
		if p.handle then
			local prev = nil
			for k = 0, 6 do
				local a = k / 6 * math.pi
				local q = Vector3.new(math.cos(a) * D * 0.48, H + math.sin(a) * D * 0.55, 0)
				if prev then
					B.rod("BasketHandle", prev, q, 0.12, shade(WEAVE, -0.1), FABRIC)
				end
				prev = q
			end
		end
	end,
}

-- A compost crate: slatted sides on corner posts, a soil heap and a worm.
PIECES.compost = {
	place = "wall", corner = 0.6, access = 1.2,
	params = function(rng)
		local W = rng:NextNumber(2.6, 3.2)
		return { w = W + 0.2, d = W + 0.2, h = 2.4, W = W, worm = rng:NextNumber() * TAU }
	end,
	build = function(B, c, p)
		local W, H = p.W, 2
		local wood = shade(BARK, -0.05)
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				B.box("CompostPost", 0.3, H + 0.2, 0.3, sx * (W / 2 - 0.15), (H + 0.2) / 2, sz * (W / 2 - 0.15), shade(wood, -0.2), WOOD, true)
			end
		end
		for k = 0, 2 do
			local y = 0.4 + k * 0.65
			for _, sx in { -1, 1 } do
				B.box("CompostSlat", 0.12, 0.42, W - 0.3, sx * (W / 2 - 0.1), y, 0, shade(wood, (k % 2) * 0.12), PLANKS)
				B.box("CompostSlat", W - 0.3, 0.42, 0.12, 0, y, sx * (W / 2 - 0.1), shade(wood, (k % 2) * 0.12), PLANKS)
			end
		end
		B.egg("CompostHeap", W - 0.4, 1.2, W - 0.4, 0, H - 0.3, 0, SOIL, Enum.Material.Ground)
		B.egg("CompostPeel", 0.5, 0.15, 0.3, 0.3, H + 0.25, -0.2, c.petalTip, M.petal, CFrame.Angles(0, 0.6, 0))
		B.egg("CompostLeaf", 0.7, 0.08, 0.4, -0.4, H + 0.2, 0.3, shade(c.leaf, -0.2), M.leaf, CFrame.Angles(0, -0.4, 0.2))
		for k = 0, 4 do
			local a = p.worm + k * 0.45
			B.ball("CompostWorm", 0.28, math.cos(a) * 0.55, H + 0.22 + math.sin(k) * 0.05, math.sin(a) * 0.55, if k == 4 then shade(WORM, -0.15) else WORM)
		end
	end,
}

-- A dye vat: a hooped tub of bright dye, a paddle, drips down the side.
PIECES.vat = {
	place = "free", access = 1.2,
	params = function(rng)
		local D = rng:NextNumber(2.4, 3)
		return { w = D + 0.2, d = D + 0.2, h = 2.6, D = D, dye = rng:NextInteger(1, 4), paddle = rng:NextNumber() * TAU }
	end,
	build = function(B, c, p)
		local D, H = p.D, 1.6
		local dyes = { c.petalBase, c.petalTip, c.center, c.leaf }
		local dye = dyes[p.dye]
		B.cyl("Vat", D, 0, 0, H, 0, shade(BARK, 0.05), PLANKS, true)
		for _, y in { 0.35, H - 0.3 } do
			B.cyl("VatHoop", D + 0.08, 0, y - 0.07, y + 0.07, 0, INK)
		end
		B.cyl("VatRim", D + 0.06, 0, H - 0.05, H + 0.08, 0, shade(BARK, 0.3), WOOD)
		B.cyl("VatDye", D - 0.25, 0, H + 0.08, H + 0.11, 0, dye) -- just over the rim disc, so it shows
		for k = 0, 2 do
			local a = p.paddle + 1.2 + k * 0.5
			B.box("VatDrip", 0.18, 0.5 + k * 0.15, 0.06, math.cos(a) * (D / 2 + 0.01), H - 0.3 - k * 0.07, math.sin(a) * (D / 2 + 0.01), dye, SMOOTH, false, CFrame.Angles(0, -a + HALF_PI, 0))
		end
		local a = p.paddle
		B.rod("VatPaddle", Vector3.new(math.cos(a) * 0.3, H - 0.2, math.sin(a) * 0.3), Vector3.new(math.cos(a) * 0.8, H + 1, math.sin(a) * 0.8), 0.14, shade(BARK, 0.2), WOOD)
	end,
}

-- A little stage: a plank platform with a petal skirt, a step, footlights,
-- and curtain posts at its ends.
PIECES.stage = {
	place = "wall", walls = { back = 1, left = 0.6, right = 0.6 }, corner = -1, access = 3,
	params = function(rng)
		local W, D = rng:NextNumber(6.5, 8.5), rng:NextNumber(3.2, 4.2)
		return { w = W, d = D, h = 1.2, W = W, D = D, lights = rng:NextInteger(3, 5) }
	end,
	build = function(B, c, p)
		local W, D = p.W, p.D
		local wood = frameWood(c)
		B.slab("StageFloor", W, 0.8, D, 0, 0.4, 0, shade(wood, 0.2), PLANKS, true, 0.35)
		B.box("StageEdge", W - 0.6, 0.12, 0.1, 0, 0.7, -D / 2 - 0.01, shade(wood, -0.25), WOOD)
		local n = math.floor(W / 0.9)
		for i = 0, n - 1 do
			local x = -W / 2 + 0.45 + i * (W - 0.9) / math.max(n - 1, 1)
			B.egg("StagePetal", 0.95, 0.8, 0.3, x, 0.35, -D / 2 - 0.05, if i % 2 == 0 then c.petalBase else c.petalTip, M.petal)
		end
		B.slab("StageStep", 2.2, 0.4, 0.8, 0, 0.2, -D / 2 - 0.5, shade(wood, 0.05), PLANKS, true, 0.2)
		for i = 1, p.lights do
			local x = (i - (p.lights + 1) / 2) * (W - 1.5) / p.lights
			B.ball("StageLight", 0.35, x, 0.95, -D / 2 + 0.3, GLOW, M.habitatGlow)
			B.cyl("StageLightCup", 0.45, x, 0.8, 0.92, -D / 2 + 0.3, HONEY)
		end
		for _, sx in { -1, 1 } do
			local x = sx * (W / 2 - 0.3)
			B.cyl("StagePost", 0.35, x, 0.8, 5.2, D / 2 - 0.3, wood, WOOD)
			B.ball("StagePostKnob", 0.5, x, 5.25, D / 2 - 0.3, HONEY)
			for k = 0, 2 do
				B.box("StageCurtain", 0.35, 4.1 - k * 0.25, 0.25, x - sx * (0.3 + k * 0.32), 2.85 + k * 0.12, D / 2 - 0.3 - k * 0.04, shade(c.petalTip, -0.1 * k), FABRIC)
			end
		end
	end,
}

-- A log bench, with a backrest on some.
PIECES.bench = {
	place = "free", access = 1,
	params = function(rng)
		local L = rng:NextNumber(3.4, 4.4)
		return { w = L, d = 1.4, h = 2.6, L = L, back = rng:NextNumber() < 0.6 }
	end,
	build = function(B, c, p)
		local L = p.L
		local wood = frameWood(c)
		for _, sx in { -1, 1 } do
			B.cyl("BenchStump", 0.75, sx * (L / 2 - 0.55), 0, 1.0, 0, shade(wood, -0.15), WOOD)
			B.cyl("BenchStumpRing", 0.7, sx * (L / 2 - 0.55), 1.0, 1.04, 0, shade(wood, 0.3), WOOD)
		end
		B.slab("BenchSeat", L, 0.3, 1.2, 0, 1.18, 0, shade(wood, 0.15), WOOD, true, 0.2)
		B.logX("BenchEdge", L - 0.1, 0.32, 0, 1.18, -0.6, shade(wood, 0.25), WOOD)
		if p.back then
			for _, sx in { -1, 1 } do
				B.cyl("BenchBackPost", 0.22, sx * (L / 2 - 0.4), 1.3, 2.5, 0.5, wood, WOOD)
			end
			B.logX("BenchBackRail", L - 0.4, 0.34, 0, 2.4, 0.5, shade(wood, 0.2), WOOD)
			B.box("BenchBackLeaf", L - 0.9, 0.5, 0.1, 0, 1.9, 0.52, c.leaf, M.leaf)
		end
	end,
}

-- A display plinth: a column with base and cap, crowned with a golden cup,
-- a bloom under a glass dome, or a prize seed.
PIECES.plinth = {
	place = "wall", corner = -0.2, access = 1.2,
	params = function(rng)
		return { w = 1.7, d = 1.7, h = 4, kind = rng:NextInteger(1, 3), H = rng:NextNumber(2.2, 2.6) }
	end,
	build = function(B, c, p)
		local H = p.H
		B.slab("PlinthBase", 1.6, 0.3, 1.6, 0, 0.15, 0, shade(CREAM, -0.1), Enum.Material.Marble, true, 0.15)
		B.cyl("PlinthColumn", 1.1, 0, 0.3, H - 0.25, 0, CREAM, Enum.Material.Marble, true)
		for _, y in { 0.5, H - 0.45 } do
			B.cyl("PlinthRing", 1.2, 0, y - 0.06, y + 0.06, 0, shade(CREAM, -0.15), Enum.Material.Marble)
		end
		B.slab("PlinthCap", 1.5, 0.25, 1.5, 0, H - 0.125, 0, shade(CREAM, -0.05), Enum.Material.Marble, false, 0.15)
		if p.kind == 1 then
			local gold = HONEY
			B.cyl("PlinthCupFoot", 0.6, 0, H, H + 0.12, 0, shade(gold, -0.2))
			B.cyl("PlinthCupStem", 0.2, 0, H + 0.12, H + 0.5, 0, gold)
			B.cyl("PlinthCupLow", 0.55, 0, H + 0.5, H + 0.7, 0, gold)
			B.cyl("PlinthCup", 0.8, 0, H + 0.7, H + 1.2, 0, gold)
			B.cyl("PlinthCupBand", 0.82, 0, H + 0.9, H + 1, 0, c.petalTip)
			for _, sx in { -1, 1 } do
				B.rod("PlinthCupHandle", Vector3.new(sx * 0.38, H + 1.1, 0), Vector3.new(sx * 0.62, H + 0.95, 0), 0.08, gold)
				B.rod("PlinthCupHandle", Vector3.new(sx * 0.62, H + 0.95, 0), Vector3.new(sx * 0.38, H + 0.72, 0), 0.08, gold)
			end
		elseif p.kind == 2 then
			B.cyl("PlinthDomeBase", 1.1, 0, H, H + 0.1, 0, shade(BARK, 0.1), WOOD)
			B.rod("PlinthBloomStalk", Vector3.new(0, H + 0.1, 0), Vector3.new(0, H + 0.75, 0), 0.08, c.stem, M.stem)
			for k = 0, 4 do
				local a = k / 5 * TAU
				B.ball("PlinthBloomPetal", 0.32, math.cos(a) * 0.2, H + 0.8, math.sin(a) * 0.2, c.petalBase, M.petal)
			end
			B.ball("PlinthBloomHeart", 0.22, 0, H + 0.84, 0, c.center, M.center)
			B.egg("PlinthDome", 1, 1.6, 1, 0, H + 0.1, 0, GLASS, Enum.Material.Glass)
		else
			B.egg("PlinthSeed", 0.75, 1.1, 0.75, 0, H + 0.55, 0, c.center, M.seed)
			B.egg("PlinthSeedStripe", 0.78, 0.25, 0.78, 0, H + 0.6, 0, shade(c.center, -0.35), M.seed)
			B.cyl("PlinthCushion", 0.9, 0, H, H + 0.15, 0, CAP_RED, FABRIC)
		end
	end,
}

-- The drafts table and its two stools share one footprint and placement.
PIECES.gameTable = {
	place = "free", access = 0, sideways = true,
	params = function(rng)
		local stool = PIECES.stool.params(Random.new(rng:NextInteger(1, RoomFurniture.SEED_MAX)))
		local seatZ = (Drafts.TOP + stool.d) / 2 + 0.35
		return { w = Drafts.TOP, d = 2 * seatZ + stool.d, h = 2.8, stool = stool, seatZ = seatZ }
	end,
	build = function(B, c, p)
		-- an 8x8 drafts board; the pieces are drawn by Client.DraftsClient
		-- from the game's saved state (Shared.Plants.Drafts)
		local H = 2.3
		local wood = frameWood(c)
		local top = Drafts.TOP
		B.cyl("GameStalk", 0.8, 0, 0, H - 0.2, 0, wood, WOOD)
		B.cyl("GameFoot", 1.8, 0, 0, 0.2, 0, shade(wood, -0.2), WOOD)
		B.slab("GameTop", top, 0.22, top, 0, H - 0.11, 0, shade(wood, 0.2), WOOD, true, 0.3)
		local sq = Drafts.SQ
		for i = 0, 7 do
			for j = 0, 7 do
				if Drafts.dark(i, j) then
					B.box("GameSquare", sq, 0.035, sq, (i - 3.5) * sq, H + 0.01, (j - 3.5) * sq, shade(c.leaf, -0.35), SMOOTH)
				end
			end
		end
		B.box("GameBoard", Drafts.BOARD, 0.02, Drafts.BOARD, 0, H - 0.002, 0, CREAM, SMOOTH)
		-- each player's waiting tray, a shallow leaf at their end
		for _, sz in { -1, 1 } do
			B.box("GameTray", top * 0.7, 0.02, 0.42, 0, H + 0.002, sz * (Drafts.BOARD / 2 + 0.3), shade(c.leaf, 0.15), M.leaf)
		end
		local stools = {}
		for _, sign in { -1, 1 } do
			local z = sign * p.seatZ
			local first = #B.parts + 1
			PIECES.stool.build(B, c, p.stool, nil, z)
			local parts = table.move(B.parts, first, #B.parts, 1, {})
			table.insert(stools, { z = z, parts = parts })
		end
		return stools
	end,
}

-- A pebble fireplace: stone jambs, a log lintel, a chimney breast, a wood
-- mantel with trinkets, and a crackling fire of crossed logs.
PIECES.fireplace = {
	place = "wall", walls = { back = 1, left = 0.7, right = 0.7 }, corner = -1, access = 2.6,
	params = function(rng)
		local W, H = rng:NextNumber(4, 4.8), rng:NextNumber(4.4, 5.2)
		local stones = {}
		for k = 1, 30 do
			stones[k] = rng:NextNumber()
		end
		return { w = W + 0.6, d = 1.9, h = H, W = W, H = H, stones = stones }
	end,
	build = function(B, c, p)
		local W, H, D = p.W, p.H, 1.6
		local z0 = 0.15
		B.slab("FireHearth", W + 0.6, 0.3, D + 0.3, 0, 0.15, z0 - 0.15, shade(STONE, -0.1), Enum.Material.Slate, true, 0.2)
		local k = 0
		local function stone(): number
			k += 1
			return p.stones[(k - 1) % #p.stones + 1]
		end
		local open = H * 0.5
		for _, sx in { -1, 1 } do
			local y = 0.3
			while y < open do
				local h = 0.45 + stone() * 0.25
				h = math.min(h, open - y)
				B.box("FireStone", 0.9 + stone() * 0.2, h - 0.04, D, sx * (W / 2 - 0.5), y + h / 2, z0, shade(STONE, stone() * 0.3 - 0.15), Enum.Material.Slate, true)
				y += h
			end
		end
		B.logX("FireLintel", W, 0.6, 0, open + 0.3, z0 - 0.1, BARK, WOOD)
		B.slab("FireMantel", W + 0.5, 0.25, D + 0.4, 0, open + 0.72, z0 - 0.1, shade(BARK, 0.2), WOOD, false, 0.12)
		B.box("FireBreast", W - 0.8, H - open - 0.8, D - 0.3, 0, (open + 0.8 + H) / 2, z0 + 0.15, STONE, Enum.Material.Slate)
		for row = 0, 2 do
			B.box("FireCourse", W - 0.78, 0.06, D - 0.28, 0, open + 1.3 + row * ((H - open - 1.3) / 3), z0 + 0.15, shade(STONE, -0.2), Enum.Material.Slate)
		end
		B.box("FireSoot", W - 1.9, open - 0.3, 0.2, 0, 0.3 + (open - 0.3) / 2, z0 + D / 2 - 0.15, INK, SMOOTH)
		-- fire
		B.rod("FireLog", Vector3.new(-0.9, 0.45, z0 - 0.3), Vector3.new(0.8, 0.5, z0 + 0.3), 0.4, BARK, WOOD)
		B.rod("FireLog", Vector3.new(0.9, 0.45, z0 - 0.25), Vector3.new(-0.8, 0.55, z0 + 0.35), 0.4, shade(BARK, -0.15), WOOD)
		local flame = B.egg("FireFlame", 0.9, 1.4, 0.6, 0, 1.15, z0, EMBER, M.habitatGlow)
		B.light(flame, FLAME, 1.8, 18)
		B.egg("FireFlame", 0.55, 1, 0.4, -0.35, 1.05, z0 - 0.1, FLAME, M.habitatGlow)
		B.egg("FireFlame", 0.5, 0.9, 0.4, 0.38, 1.0, z0 + 0.05, FLAME, M.habitatGlow)
		-- trinkets
		local mt = open + 0.85
		B.cyl("FireJar", 0.4, -W / 2 + 0.6, mt, mt + 0.6, z0 - 0.2, GLASS, Enum.Material.Glass)
		B.ball("FireJarGlow", 0.25, -W / 2 + 0.6, mt + 0.25, z0 - 0.2, c.petalTip:Lerp(GLOW, 0.5), M.habitatGlow)
		B.cyl("FirePot", 0.5, W / 2 - 0.6, mt, mt + 0.4, z0 - 0.2, CLAY, Enum.Material.Slate)
		B.ball("FirePotBloom", 0.45, W / 2 - 0.6, mt + 0.6, z0 - 0.2, c.petalBase, M.petal)
		B.egg("FireSeed", 0.35, 0.5, 0.35, 0, mt + 0.25, z0 - 0.2, c.center, M.seed)
	end,
}

-- Designed pieces (Shared.Plants.FurnitureRules / FurnitureGrammar): grown
-- from a recipe of rule choices instead of rolled from a seed. With no
-- recipe (an admin's gift) one is rolled from the seed, within one style.
for id, place in FurnitureGrammar.PLACE do
	PIECES[id] = {
		design = true,
		place = place.place, walls = place.walls, corner = place.corner, along = place.along, access = place.access, sleeps = place.sleeps,
		params = function(rng, recipe)
			return FurnitureGrammar.params(id, recipe, rng)
		end,
		build = function(B, c, p)
			return FurnitureGrammar.build(id, B, c, p)
		end,
	}
end

Furniture.PIECES = PIECES
Furniture.builder = builder

---------------------------------------------------------------- purposes

-- Each purpose lists what it wants, in order (each entry a piece id and,
-- optionally, RoomPlanner hints: near, facing, flip, faceDist, chance,
-- n = { min, max }) and fillers for the gaps.
local function W(id: string, opts: { [string]: any }?)
	local w = { id = id }
	for k, v in opts or {} do
		w[k] = v
	end
	return w
end

Furniture.PURPOSES = {
	bedroom = {
		label = "Bedroom",
		wants = { W("rug"), W("bed"), W("chest", { near = "bed", nearWeight = 1.2 }), W("shelf", { chance = 0.8 }), W("lantern"), W("desk", { chance = 0.5 }), W("cupboard", { chance = 0.35 }), W("beanbag", { chance = 0.5, near = "rug" }), W("windowBox", { chance = 0.5 }) },
		fill = { "planter", "jars", "basket", "lantern" },
	},
	kitchen = {
		label = "Kitchen",
		wants = { W("stove"), W("honeycomb"), W("rug", { chance = 0.6 }), W("table", { near = "rug", nearWeight = 1.5 }), W("barrel", { chance = 0.7 }), W("cupboard", { chance = 0.8 }), W("sideboard", { chance = 0.5 }), W("jars"), W("windowBox", { chance = 0.6 }) },
		fill = { "jars", "basket", "barrel", "planter" },
	},
	library = {
		label = "Library",
		wants = { W("shelf"), W("shelf", { near = "shelf", nearWeight = 0.4 }), W("shelf", { chance = 0.7 }), W("rug"), W("armchair", { near = "rug", nearWeight = 1 }), W("desk"), W("lantern"), W("beanbag", { chance = 0.5 }) },
		fill = { "planter", "lantern", "jars", "basket" },
	},
	lounge = {
		label = "Lounge",
		wants = { W("fireplace"), W("rug", { near = "fireplace", nearWeight = 1 }), W("armchair", { facing = "fireplace", faceDist = 4.5 }), W("armchair", { facing = "fireplace", faceDist = 4.5 }), W("gameTable", { chance = 0.8 }), W("sideboard", { chance = 0.6 }), W("beanbag", { chance = 0.7 }), W("lantern") },
		fill = { "planter", "lantern", "jars", "basket" },
	},
	gardenRoom = {
		label = "Garden Room",
		wants = { W("windowBox"), W("windowBox", { chance = 0.7 }), W("rug", { chance = 0.5 }), W("table", { near = "rug", nearWeight = 1.5 }), W("planter", { n = { 2, 4 } }), W("basket") },
		fill = { "planter", "planter", "basket", "jars" },
	},
	attic = {
		label = "Attic",
		wants = { W("hammock"), W("parcels"), W("chest"), W("barrel"), W("lantern"), W("telescope", { chance = 0.4 }) },
		fill = { "parcels", "barrel", "basket", "jars" },
	},
	stockroom = {
		label = "Stockroom",
		wants = { W("shelf"), W("parcels", { n = { 2, 3 } }), W("barrel", { n = { 1, 2 } }), W("chest"), W("cupboard", { chance = 0.6 }), W("basket") },
		fill = { "parcels", "barrel", "basket", "jars" },
	},
	cafe = {
		label = "Café",
		wants = { W("honeycomb"), W("teacup"), W("teacup", { chance = 0.8 }), W("stove", { chance = 0.5 }), W("sideboard"), W("cupboard", { chance = 0.5 }), W("lantern"), W("windowBox", { chance = 0.6 }) },
		fill = { "planter", "jars", "lantern", "basket" },
	},
	classroom = {
		label = "Classroom",
		wants = { W("board", { walls = { back = 1 } }), W("desk", { place = "free", facing = "board", flip = true, faceDist = 6, n = { 2, 4 } }), W("shelf"), W("lantern") },
		fill = { "planter", "basket", "jars" },
	},
	stable = {
		label = "Bug Stall",
		wants = { W("mossbed"), W("mossbed", { chance = 0.6 }), W("trough"), W("barrel"), W("basket"), W("lantern") },
		fill = { "basket", "barrel", "planter" },
	},
	council = {
		label = "Council Room",
		wants = { W("rug"), W("roundTable", { near = "rug", nearWeight = 2 }), W("board"), W("shelf"), W("sideboard", { chance = 0.5 }), W("lantern") },
		fill = { "planter", "jars", "lantern" },
	},
	sorting = {
		label = "Sorting Room",
		wants = { W("shelf"), W("shelf", { chance = 0.7 }), W("desk"), W("parcels", { n = { 2, 3 } }), W("basket"), W("chest") },
		fill = { "parcels", "basket", "barrel" },
	},
	bunkroom = {
		-- The Sprout Lodge's shared rooms: four roommates, each with a bunk and
		-- a chest of their own, round a shared middle.
		label = "Bunk Room",
		wants = { W("bunk"), W("bunk"), W("chest", { near = "bunk", nearWeight = 1.2, n = { 4, 4 } }), W("rug"), W("table", { near = "rug", nearWeight = 1.5 }), W("windowBox"), W("lantern") },
		fill = { "planter", "lantern" },
	},
	potting = {
		label = "Potting Room",
		wants = { W("table"), W("planter", { n = { 3, 4 } }), W("windowBox"), W("jars"), W("barrel"), W("basket") },
		fill = { "planter", "basket" },
	},
	trophy = {
		label = "Trophy Room",
		wants = { W("rug"), W("plinth", { n = { 2, 3 } }), W("shelf"), W("armchair", { near = "rug", nearWeight = 1 }), W("lantern") },
		fill = { "plinth", "planter", "lantern" },
	},
	lookout = {
		label = "Lookout",
		wants = { W("telescope"), W("rug"), W("beanbag", { near = "rug", nearWeight = 1 }), W("armchair", { chance = 0.5 }), W("jars"), W("lantern") },
		fill = { "planter", "jars", "basket" },
	},
	pumpRoom = {
		label = "Pump Room",
		wants = { W("tank"), W("tank"), W("trough"), W("barrel"), W("lantern") },
		fill = { "barrel", "basket" },
	},
	compost = {
		label = "Compost Room",
		wants = { W("compost"), W("compost"), W("barrel"), W("basket"), W("planter") },
		fill = { "compost", "barrel", "basket" },
	},
	dyeVats = {
		label = "Dye Room",
		wants = { W("vat", { n = { 2, 3 } }), W("shelf"), W("parcels"), W("rug"), W("jars") },
		fill = { "jars", "basket", "barrel" },
	},
	stage = {
		label = "Stage",
		wants = { W("stage", { walls = { back = 1, left = 0.5, right = 0.5 } }), W("bench", { facing = "stage", faceDist = 6, n = { 2, 3 } }), W("lantern", { n = { 2, 3 } }) },
		fill = { "lantern", "planter" },
	},
	gallery = {
		label = "Gallery",
		wants = { W("rug"), W("plinth", { n = { 3, 4 } }), W("bench", { near = "rug", nearWeight = 1 }), W("lantern") },
		fill = { "plinth", "planter" },
	},
}

-- Room mixes by building kind. `hall` is the ground hall (nil = keep it
-- empty, the server furnishes it; a list = pick one), `rooms` the upper
-- rooms in turn.
local MIXES = {
	Market = { hall = nil, rooms = { "stockroom", "lounge", "attic" } },
	School = { hall = nil, rooms = { "library", "classroom", "attic" } },
	Lodge = { hall = "lounge", rooms = { "bunkroom" } },
	Town = { hall = { "cafe", "lounge", "kitchen" }, rooms = { "bedroom", "kitchen", "library", "lounge", "gardenRoom", "attic", "stockroom" } },
	House = { hall = "bedroom", rooms = { "kitchen", "potting", "trophy", "library", "lookout" } },
	TownHall = { hall = nil, rooms = { "council", "sorting", "attic" } }, -- hall: Server.Town.TownHallClerk
	WaterWorks = { hall = "pumpRoom", rooms = { "pumpRoom", "stockroom" } },
	PostOffice = { hall = "sorting", rooms = { "sorting", "stockroom", "attic" } },
	SeedLibrary = { hall = "library", rooms = { "library", "lounge" } },
	NectarCafe = { hall = "cafe", rooms = { "kitchen", "cafe", "stockroom" } },
	Greenhouse = { hall = "gardenRoom", rooms = { "gardenRoom", "potting" } },
	WormWorks = { hall = "compost", rooms = { "compost", "stockroom" } },
	LanternHall = { hall = "stage", rooms = { "lounge", "stage" } },
	HallOfBlooms = { hall = "gallery", rooms = { "gallery", "trophy" } },
	WeatherVane = { hall = "lookout", rooms = { "lookout", "attic" } },
	DyeWorks = { hall = "dyeVats", rooms = { "dyeVats", "stockroom" } },
}
MIXES.Wild = MIXES.Town
Furniture.MIXES = MIXES

---------------------------------------------------------------- choosing

-- "0=bedroom,1=kitchen" -> { [0] = "bedroom", [1] = "kitchen" }
function Furniture.parseUses(s: any): { [number]: string }?
	if typeof(s) ~= "string" or s == "" then
		return nil
	end
	local out = {}
	for n, use in string.gmatch(s, "(%d+)%s*=%s*([%a]+)") do
		out[tonumber(n) :: number] = use
	end
	return out
end

function Furniture.encodeUses(uses: { [number]: string }): string
	local parts = {}
	for n, use in uses do
		table.insert(parts, `{n}={use}`)
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

-- The purpose of room `number` in a plant, or nil to leave it empty.
function Furniture.purposeFor(ctx, number: number): string?
	local uses = ctx.roomUses
	if uses and uses[number] and Furniture.PURPOSES[uses[number]] then
		return uses[number]
	end
	local mix = MIXES[ctx.building or "Wild"] or MIXES.Wild
	local rng = ctx.rng(6007, number)
	if number == 0 then
		local hall = mix.hall
		if typeof(hall) == "table" then
			return hall[rng:NextInteger(1, #hall)]
		end
		return hall
	end
	local rooms = mix.rooms
	-- start somewhere seeded, then walk the list so neighbouring rooms differ
	local start = ctx.rng(6011, 0):NextInteger(0, #rooms - 1)
	return rooms[((start + number - 1) % #rooms) + 1]
end

---------------------------------------------------------------- planning

-- Every piece rolls its sizes and details from a seed of its own, so a
-- piece looks the same wherever it is moved to (RoomFurniture keeps it).
local SEED_MAX = RoomFurniture.SEED_MAX

-- One planner want for piece `id`, with its procedural sizes rolled
-- (designed pieces: grown from `recipe`).
local function wantFor(id: string, opts: { [string]: any }?, rng: Random, recipe: string?): any?
	local piece = PIECES[id]
	if not piece then
		return nil
	end
	local p = piece.params(rng, recipe)
	local w = {
		id = id,
		r = if piece.design then p.recipe else nil,
		p = p,
		w = p.w,
		d = p.d,
		h = p.h,
		place = piece.place,
		walls = piece.walls,
		corner = piece.corner,
		access = piece.access,
		along = piece.along,
		flat = piece.flat,
		scales = piece.scales,
		sideways = piece.sideways,
	}
	if piece.seats then
		-- the seats have a seed of their own, so each can be moved on its own
		-- and still look the same (Shared.Housing.RoomFurniture)
		local seatSeed = rng:NextInteger(1, SEED_MAX)
		local seat = wantFor(piece.seats.id, nil, Random.new(seatSeed))
		if seat then
			seat.seed = seatSeed
			seat.n = piece.seats.n
			w.seats = seat
		end
	end
	for k, v in opts or {} do
		if k ~= "id" and k ~= "chance" and k ~= "n" then
			w[k] = v
		end
	end
	return w
end
Furniture.wantFor = wantFor

-- The room as RoomPlanner sees it, in normal studs (see RoomPlanner.plan).
function Furniture.plannerRoom(room: any, keepClear: number, publicRoom: boolean?): any
	local u = room.unit
	local floorY = room.floorY
	local sill = (room.windowLo - floorY) / u
	local winHalf = room.windowHalf / u + 0.3
	local lampLow = room.height * (if room.ground then 0.4 else 0.55) / u - 0.8
	local lampZ = (room.halfZ - room.round) * 0.6 / u
	return {
		ax = (room.halfX - room.wall) / u - 0.05,
		az = (room.halfZ - room.wall) / u - 0.05,
		rc = math.max(room.round - room.wall, 0) / u,
		stemKeep = keepClear / u,
		walk = if publicRoom then 2.8 else nil,
		doorLane = if publicRoom then 2 else nil,
		spacing = if publicRoom then 1.8 else nil,
		skipFill = publicRoom,
		doorHalf = room.doorHalf / u,
		ceiling = room.height / u - 0.6,
		windows = {
			{ wall = "back", half = winHalf, sill = sill },
			{ wall = "left", half = winHalf, sill = sill },
			{ wall = "right", half = winHalf, sill = sill },
		},
		lamps = { { z = -lampZ, low = lampLow }, { z = lampZ, low = lampLow } },
	}
end

-- The layout for one room: purpose -> wants -> RoomPlanner.
function Furniture.layout(purpose: string, planRoom: any, rng: Random, pause: (() -> ())?): { any }
	local spec = Furniture.PURPOSES[purpose]
	if not spec then
		return {}
	end
	local wants = {}
	for _, entry in spec.wants do
		if not entry.chance or rng:NextNumber() < entry.chance then
			local n = if entry.n then rng:NextInteger(entry.n[1], entry.n[2]) else 1
			for _ = 1, n do
				local seed = rng:NextInteger(1, SEED_MAX)
				local w = wantFor(entry.id, entry, Random.new(seed))
				if w then
					w.seed = seed
					table.insert(wants, w)
				end
			end
		end
	end
	local fill = {}
	for _, id in (if planRoom.skipFill then {} else spec.fill or {}) do
		table.insert(fill, function()
			local seed = rng:NextInteger(1, SEED_MAX)
			local w = wantFor(id, nil, Random.new(seed))
			if w then
				w.seed = seed
			end
			return w
		end)
	end
	return RoomPlanner.plan(planRoom, wants, fill, rng, pause)
end

---------------------------------------------------------------- handles

-- Interactive pieces (Shared.Plants.FurnitureUse) each get an invisible
-- handle part, tagged FurnitureUse.HANDLE_TAG, that rides with the piece and
-- carries its prompt. Furniture.handles[handle] lists the piece's parts, so
-- the client can open a chest's lid or dim a lamp (pieces are built on the
-- client, in the same Lua state as the scripts that use them).
--
-- Not a weak table: a part used only as a weak key can lose its entry while
-- the part still exists (Roblox may collect the part's Lua object when no
-- script holds it, and hand out a new one later). A new build waits out of
-- the world for its unions with nothing else holding its handles, so on a
-- busy arrival the collector cleared them, FurnitureClient found no entry
-- and gave those pieces no prompt (only the bed, which needs no entry,
-- worked) until the house was rebuilt. Entries go when the handle is
-- destroyed instead (every build is destroyed when it's swapped out).
Furniture.handles = {} :: { [BasePart]: { kind: string, parts: { BasePart } } }

-- `cf` is the handle's centre, `size` its box (both already in model studs,
-- before the plant is scaled to the world). `points` are named attachments
-- (a seat, a telescope's eye) as world CFrames in the same space.
function Furniture.addHandle(ctx, kind: string, room: number, index: string | number, cf: CFrame, size: Vector3, parts: { BasePart }, points: { [string]: CFrame }?): BasePart?
	if not ctx.model or not FurnitureUse.KINDS[kind] then
		return nil
	end
	local h = Instance.new("Part")
	h.Name = FurnitureUse.HANDLE_NAME
	h.Anchored = true
	h.CanCollide = false
	h.CanQuery = false
	h.CanTouch = false
	h.Transparency = 1
	h.Size = Vector3.new(math.max(size.X, FMIN), math.max(size.Y, FMIN), math.max(size.Z, FMIN))
	h.CFrame = cf
	h:SetAttribute("FurnitureKind", kind)
	h:SetAttribute("FurnitureRoom", room)
	h:SetAttribute("FurnitureIndex", tostring(index))
	for name, at in points or {} do
		local a = Instance.new("Attachment")
		a.Name = name
		a.CFrame = cf:ToObjectSpace(at)
		a.Parent = h
	end
	h.Parent = ctx.model
	CollectionService:AddTag(h, FurnitureUse.HANDLE_TAG)
	Furniture.handles[h] = { kind = kind, parts = parts }
	h.Destroying:Connect(function()
		Furniture.handles[h] = nil
	end)
	return h
end

---------------------------------------------------------------- furnishing

-- Grows the furniture for one room. `frame` is the room's frame (origin at
-- the bottom of its segment on the stem axis, +X out through the door), and
-- keepClear how far from the stem's axis the floor must stay bare (the stem
-- and its climbing hole).
-- Pieces a round seat turns to face, and the seats with no front of their own.
local FOCUS = { fireplace = true, stove = true }
local ROUND_SEATS = { rug = true, mossbed = true }

-- Rooms of homes grown on this client, for the decorate tools
-- (Client.DecorateClient): model -> room number -> Grown. Weak, so a model
-- that is thrown away takes its rooms with it.
export type GrownPiece = {
	id: string,
	x: number,
	z: number,
	a: number,
	s: number,
	seed: number,
	key: string,
	w: number,
	d: number,
	h: number,
	flat: boolean,
	r: string?, -- a designed piece's recipe (FurnitureRules)
	parts: { BasePart },
}
export type Grown = {
	floor: BasePart, -- invisible, on the room's floor: its CFrame is the room's floor frame
	plan: any, -- the room as RoomPlanner sees it (Furniture.plannerRoom), normal studs
	colors: any, -- the building's colours, to grow a piece the same way
	arranged: boolean, -- laid out by its owner (RoomFurniture), not grown by itself
	pieces: { GrownPiece },
}
Furniture.grown = setmetatable({}, { __mode = "k" }) :: { [Instance]: { [number]: Grown } }
Furniture.FLOOR_NAME = "RoomFloor"

-- Grows one piece by itself (the decorate tools' see-through piece you
-- carry, the market's preview), standing on CFrame `o`, at `unit` studs per
-- normal stud. `id` may be an item, "kind.recipe" (RoomFurniture.item).
function Furniture.growPiece(colors: any, id: string, seed: number, o: CFrame, unit: number, parent: Instance): (Model?, any?)
	local recipe
	id, recipe = RoomFurniture.splitItem(id)
	local piece = PIECES[id]
	if not piece then
		return nil, nil
	end
	local w = wantFor(id, nil, Random.new(seed), recipe)
	local model = Instance.new("Model")
	model.Name = "Furniture" .. id
	local B = builder({ model = model, colors = colors }, o, unit)
	piece.build(B, colors, w.p, Random.new(seed * 7 + 3))
	model.Parent = parent
	return model, w
end

-- A piece's planner want (sizes) from its seed (and recipe, for a
-- designed piece: pass it, or an item "kind.recipe" as `id`).
function Furniture.wantOf(id: string, seed: number, recipe: string?): any?
	local kind, r = RoomFurniture.splitItem(id)
	return wantFor(kind, nil, Random.new(seed), recipe or r)
end

function Furniture.furnish(ctx, frame: CFrame, room: any, keepClear: number)
	if not ctx.model then
		return
	end
	local arranged = ctx.roomFurniture and ctx.roomFurniture[room.number]
	local purpose = Furniture.purposeFor(ctx, room.number)
	if not arranged and (not purpose or not Furniture.PURPOSES[purpose]) then
		return
	end
	-- Pieces are their own things: not part of an organ or a stem union.
	local savedJoint, savedStem = ctx.joint, ctx.stemGroup
	ctx.joint, ctx.stemGroup = nil, nil

	local u = room.unit
	local building = ctx.building
	local publicRoom = building ~= nil and building ~= "House" and building ~= "Wild"
	local planRoom = Furniture.plannerRoom(room, keepClear, publicRoom)
	local CivicServices = Host.civic()
	if room.ground and CivicServices and CivicServices.byBuilding[ctx.building or ""] then
		-- Planner +X points out the door. Reserve the station and its approach.
		planRoom.reserved = { RoomPlanner.box(-CivicServices.BACK + 0.5, 0, 1, 0, 3.5, 5.5) }
	end
	local layout
	local pause = ctx.breathe
	local mark = ctx.geometryMark
	local construction = if mark then mark("PlantFurnitureLayout") else nil
	if arranged then
		-- its owner's own arrangement (Shared.Housing.RoomFurniture)
		layout = {}
		for _, piece in arranged do
			if pause then
				pause()
			end
			local w = wantFor(piece.id, nil, Random.new(piece.seed), piece.r)
			if w then
				w.seed = piece.seed
				local lx, lz = RoomFurniture.look(piece.a)
				table.insert(layout, { want = w, x = piece.x, z = piece.z, lx = lx, lz = lz, s = piece.s, key = piece.key })
			end
		end
	else
		layout = Furniture.layout(purpose :: string, planRoom, ctx.rng(6029, room.number), pause)
	end
	if mark then
		mark(construction)
	end

	-- Homes keep a record of their rooms for the decorate tools.
	local grown: Grown? = nil
	if ctx.building == "House" then
		local floor = Instance.new("Part")
		floor.Name = Furniture.FLOOR_NAME
		floor.Anchored = true
		floor.CanCollide = false
		floor.CanQuery = false
		floor.CanTouch = false
		floor.CastShadow = false
		floor.Transparency = 1
		floor.Size = Vector3.new(math.max(2 * planRoom.ax * u, FMIN), FMIN, math.max(2 * planRoom.az * u, FMIN))
		floor.CFrame = frame * CFrame.new(0, room.floorY, 0)
		floor:SetAttribute("FurnitureRoom", room.number)
		floor.Parent = ctx.model
		grown = { floor = floor, plan = planRoom, colors = ctx.colors, arranged = arranged ~= nil, pieces = {} }
		local rooms = Furniture.grown[ctx.model] or {}
		rooms[room.number] = grown :: Grown
		Furniture.grown[ctx.model] = rooms
	end

	local beds = 0
	-- Where a round seat (a rug, a moss bed) has you look: the room's fire
	-- if it has one, otherwise the way the piece was laid.
	local focus: Vector3? = nil
	for _, item in layout do
		if FOCUS[item.want.id] then
			focus = (frame * CFrame.new(item.x * u, room.floorY, item.z * u)).Position
			break
		end
	end
	for k, item in layout do
		if pause then
			pause()
		end
		local piece = PIECES[item.want.id]
		local pos = Vector3.new(item.x * u, room.floorY, item.z * u)
		local o = frame * CFrame.lookAt(pos, pos + Vector3.new(item.lx, 0, item.lz))
		local uu = u * item.s
		local B = builder(ctx, o, uu, true)
		local p = item.want.p
		local seed = item.want.seed or k
		local made = piece.build(B, ctx.colors, p, Random.new(seed * 7 + 3))
		local key = item.key or tostring(k)
		if grown then
			table.insert(grown.pieces, {
				id = item.want.id,
				x = item.x,
				z = item.z,
				a = RoomFurniture.angleOf(item.lx, item.lz),
				s = item.s,
				seed = seed,
				key = key,
				w = item.want.w,
				d = item.want.d,
				h = item.want.h,
				flat = item.want.flat == true,
				r = item.want.r,
				parts = B.parts,
			})
		end
		if piece.sleeps and type(made) == "table" then
			for _, mattress in made do
				beds += 1
				mattress:SetAttribute("SleepRoom", room.number)
				mattress:SetAttribute("SleepBed", beds)
				CollectionService:AddTag(mattress, Furniture.SLEEP_TAG)
			end
		end
		local kind = item.want.id
		if kind == "gameTable" then
			local stool = p.stool
			for _, inSet in made do
				local z = inSet.z
				local at = (FurnitureUse.SEATS.stool(stool) + Vector3.new(0, 0, z)) * uu
				local seat = o * CFrame.lookAt(at, at + Vector3.new(0, 0, -math.sign(z)))
				local center = o * CFrame.new(0, stool.h / 2 * uu, z * uu)
				Furniture.addHandle(ctx, "stool", room.number, key, center, Vector3.new(stool.w, stool.h, stool.d) * uu, inSet.parts, { Seat = seat })
			end
		end
		if FurnitureUse.KINDS[kind] then
			local points = {}
			local seat = FurnitureUse.SEATS[kind]
			if seat then
				local at = seat(p)
				points.Seat = if typeof(at) == "CFrame" then o * CFrame.new(at.Position * uu) * at.Rotation else o * CFrame.new((at :: Vector3) * uu)
				if ROUND_SEATS[kind] and focus then
					local sp = points.Seat.Position
					local flat = Vector3.new(focus.X, sp.Y, focus.Z)
					if (flat - sp).Magnitude > 1e-3 then
						points.Seat = CFrame.lookAt(sp, flat, o.UpVector)
					end
				end
			end
			if kind == "telescope" then
				local eye = FurnitureUse.telescopeEye(p)
				points.Eye = o * CFrame.new(eye.Position * uu) * eye.Rotation
			end
			Furniture.addHandle(ctx, kind, room.number, key, o * CFrame.new(0, p.h / 2 * uu, 0), Vector3.new(p.w, p.h, p.d) * uu, B.parts, points)
		end
	end

	ctx.joint, ctx.stemGroup = savedJoint, savedStem
end

return Furniture
