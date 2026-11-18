--[[
	PlantBuilder: turns a genome and a growth progress (0..1) into a Model.

	The body plan follows real plant structure:
	  - a stem of nodes and internodes that grows node by node and thickens
	  - leaves at each node, arranged by phyllotaxis (alternate, opposite
	    decussate, or golden-angle spiral), each with a petiole and a blade
	    whose outline (lanceolate to heart shaped) comes from the genes;
	    young leaves point up and droop as they mature
	  - axillary side branches growing from the leaf axils
	  - rosette plants keep their leaves at the ground and send up a bare
	    flower stalk (scape)
	  - buds with green sepals that swell, colour up and open into flowers
	    with 3 to 8 petals in 1 to 3 whorls, a pollen centre and anthers

	Shapes are overlapping smooth ellipsoids, so leaves and petals read as soft
	blended forms, and every piece is colour graded base to tip (see Palette).

	Everything is deterministic: the same genome, progress and seed build the
	same plant on every client. Random variation is drawn per node, so a plant
	keeps its shape as it grows instead of reshuffling.

	PlantBuilder.build(genome, progress, baseCFrame, options?) -> Model, flowers
	PlantBuilder.flowerPoints(genome, progress, baseCFrame) -> flowers (no parts built)
	PlantBuilder.joints(model) -> { joints = { Joint }, jointOf = { [BasePart]: Joint } }?
	  where each leaf, petal and flower head meets its stem, so the renderer
	  can swing them there in the wind. Joint = { cframe: CFrame (world, rest
	  pose), kind: "leaf" | "head" | "petal", amount: number, parent: Joint? }.
	  Joints are listed parents first; a petal's parent is its flower head.
	  flowers = { { cframe = CFrame, nectar = 0..1 } }
	options = { seed: number?, detail: number? (3 close-up, 1 full, 0.5 low), plantId: string?, name: string?,
	  breathe: (() -> ())? (called every few parts; it may yield, to spread a big build over frames.
	    The model then comes back held: call Smooth.release(model) once it is parented, or its
	    unions and room shells never start) }
]]

local CollectionService = game:GetService("CollectionService")

local Genome = require(script.Parent.Genome)
local Growth = require(script.Parent.Growth)
local Palette = require(script.Parent.Palette)
local Habitat = require(script.Parent.Habitat)
local Furniture = require(script.Parent.Furniture)
local Climb = require(script.Parent.Climb)
local Wind = require(script.Parent.Wind)
local Smooth = require(script.Parent.Smooth)
local Element = require(script.Parent.Element)
local Host = require(script.Parent.Host)
local Ground = {
	heightAt = function(x: number, z: number): number
		return Host.groundHeight(x, z)
	end,
}
local Perf = Host.perf

-- Plants are laid out in the original design studs (players were 1/10 size
-- then; Habitat.UNIT is still in those units) and the finished model is
-- scaled up by WORLD_SCALE around its base, so it comes out at world size.
local WORLD = Host.worldScale()

local PlantBuilder = {}

-- Joint data per built model (see PlantBuilder.joints); weak, so it goes
-- when the model does.
local jointsOf = setmetatable({}, { __mode = "k" })

PlantBuilder.MODEL_TAG = "Plant"
PlantBuilder.FLOWER_TAG = "PlantFlower"

local TAU = math.pi * 2
local GOLDEN = math.rad(137.508)
local MIN = 0.05
local STEM_SEGMENTS = 4
local BREATHE_EVERY = 16 -- parts made between calls to options.breathe

local function finishGeometry(mark, previous: string, ...)
	mark(previous)
	return ...
end

local function profileGeometry(ctx, label: string, fn, ...)
	local mark = ctx.geometryMark
	if not mark then
		return fn(...)
	end
	local previous = mark(label)
	return finishGeometry(mark, previous, fn(...))
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- A CFrame at pos looking toward target, safe when the direction is vertical.
local function look(pos: Vector3, target: Vector3): CFrame
	local d = target - pos
	local ref = if d.Magnitude > 0 and math.abs(d.Unit.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
	return CFrame.lookAt(pos, target, ref)
end

-- A CFrame at pos whose UpVector is dir.
local UP_ROTATION = CFrame.Angles(-math.pi / 2, 0, 0)
local ROD_ROTATION = CFrame.Angles(0, math.pi / 2, 0)
local flutterBound = { value = nil, cos = 0, sin = 0 }
local function upFrame(pos: Vector3, dir: Vector3): CFrame
	return look(pos, pos + dir) * UP_ROTATION
end

-- Part helpers. When ctx.model is nil (a dry run for flowerPoints) nothing is built.
local function part(ctx, name: string, shape: Enum.PartType, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, collide: boolean?): BasePart?
	if not ctx.model then
		return nil
	end
	-- A caller that can wait (PlantRenderer) passes options.breathe: it is
	-- called every few parts and may yield, so a big plant is built over
	-- several frames instead of holding one up.
	local breathe = ctx.breathe
	if breathe then
		ctx.made += 1
		if ctx.made % BREATHE_EVERY == 0 then
			breathe()
		end
	end
	local started = if ctx.measureParts then os.clock() else nil
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = shape
	p.Anchored = true
	p.CanCollide = collide == true
	p.CanQuery = collide == true
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Size = Vector3.new(math.max(size.X, MIN), math.max(size.Y, MIN), math.max(size.Z, MIN))
	p.CFrame = cf
	p.Color = color
	p.Material = material
	local reflect = ctx.reflect
	if reflect and reflect[material] then
		p.Reflectance = reflect[material] -- a fire plant's metal shines
	end
	p.Parent = ctx.model
	if ctx.joint then
		ctx.jointOf[p] = ctx.joint
	end
	-- Pieces of one organ (or one stretch of stem) are unioned into one
	-- smooth surface later (see Smooth).
	local group = ctx.joint or ctx.stemGroup
	if group then
		ctx.groupOf[p] = group
	end
	if started then
		Perf.measure("PlantParts", started)
	end
	return p
end

-- Start an organ that swings at its own joint (see PlantBuilder.joints):
-- every part made until the returned previous joint is restored belongs to
-- it. Joints nest, so petals swing on a flower head that nods on its stalk.
local function openJoint(ctx, kind: string, cf: CFrame, amount: number?)
	local prev = ctx.joint
	if ctx.model then
		local j = { cframe = cf, kind = kind, amount = amount or 1, parent = prev }
		table.insert(ctx.joints, j)
		ctx.joint = j
	end
	return prev
end

local function ellipsoid(ctx, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): BasePart?
	local p = part(ctx, name, Enum.PartType.Block, size, cf, color, material, false)
	if p then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = p
		ctx.groupOf[p] = nil -- unions ignore special meshes (it would turn into a box)
	end
	return p
end

-- A thin raised line on a leaf or petal (veins, nectar guides, frilled rims).
-- A flat block, not an ellipsoid: a sphere mesh costs about 100 triangles
-- and a close-up plant has hundreds of these, so they were most of the
-- triangles on screen. Kept out of the organ's union for the same reason.
local function vein(ctx, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): BasePart?
	local p = part(ctx, name, Enum.PartType.Block, size, cf, color, material, false)
	if p then
		ctx.groupOf[p] = nil
	end
	return p
end

-- Balls stay plain parts, outside the organ's union: Roblox draws a ball part
-- cheaply (it thins it out with distance), but a ball inside a union becomes
-- a dense mesh of about a thousand triangles, so a flower head full of
-- florets and anthers turned into a 10,000+ triangle union.
local function ball(ctx, name: string, diameter: number, pos: Vector3, color: Color3, material: Enum.Material): BasePart?
	local p = part(ctx, name, Enum.PartType.Ball, Vector3.one * diameter, CFrame.new(pos), color, material, false)
	if p then
		ctx.groupOf[p] = nil
	end
	return p
end

local function cylinderBetween(ctx, name: string, a: Vector3, b: Vector3, diameter: number, color: Color3, material: Enum.Material, collide: boolean?): BasePart?
	local len = (b - a).Magnitude
	if len < 0.02 then
		return nil
	end
	-- Cylinder length runs along X; turn X onto the a->b direction.
	local cf = look((a + b) / 2, b) * ROD_ROTATION
	return part(ctx, name, Enum.PartType.Cylinder, Vector3.new(len, diameter, diameter), cf, color, material, collide)
end

-- A flat blade (leaf, petal, sepal) built as one continuous surface instead
-- of overlapping blobs: each segment is a centre strip plus two side wedges
-- that taper the outline smoothly from one width to the next, and a disc
-- rounds off the tip. Every piece is plain part geometry, so the pieces of
-- one blade union into a single smooth shape (see Smooth).
--   cf: base of the blade, LookVector pointing along it, UpVector its face
--   widthAt(t): full width at t (0 base .. 1 tip); colorAt(t)
--   bendAt(j): extra pitch (radians) before segment j (negative droops)
--   adjust(cf, segLen, width) -> cf: optional, e.g. to keep clear of the ground
--   each(centre, width, segLen, t): optional, called per segment
-- Returns the CFrame at the tip.
local function blade(ctx, name: string, cf: CFrame, len: number, segs: number, thick: number, widthAt: (number) -> number, colorAt: (number) -> Color3, material: Enum.Material, bendAt: ((number) -> number)?, adjust: ((CFrame, number, number) -> CFrame)?, each: ((CFrame, number, number, number) -> ())?, roundTip: boolean?): CFrame
	local segLen = len / segs
	local w0 = math.max(MIN, widthAt(0))
	for j = 1, segs do
		if bendAt then
			cf = cf * CFrame.Angles(bendAt(j), 0, 0)
		end
		local t0, t1 = (j - 1) / segs, j / segs
		local w1 = math.max(MIN, widthAt(t1))
		if adjust then
			cf = adjust(cf, segLen, math.max(w0, w1))
		end
		local centre = cf * CFrame.new(0, 0, -segLen * 0.5)
		local color = colorAt((t0 + t1) / 2)
		local wmin = math.min(w0, w1)
		local overlap = segLen * 1.04
		-- Neighbouring segments overlap a little to close the seam, so every
		-- other one is a touch thicker: where the blade runs straight their
		-- faces would otherwise share a plane and flicker.
		local th = if j % 2 == 0 then thick * 1.04 else thick
		part(ctx, name, Enum.PartType.Block, Vector3.new(wmin, th, overlap), centre, color, material, false)
		local dW = math.abs(w0 - w1) / 2
		if dW > 0.01 then
			-- A wedge's full faces are its bottom (-Y) and back (+Z): bottom
			-- against the centre strip, back at the wider end of the segment.
			local Z = if w0 > w1 then -centre.LookVector else centre.LookVector
			for _, side in { -1, 1 } do
				local Y = centre.RightVector * side
				local X = Y:Cross(Z)
				local pos = centre.Position + centre.RightVector * side * (wmin / 2 + dW / 2)
				part(ctx, name, Enum.PartType.Wedge, Vector3.new(th, dW, overlap), CFrame.fromMatrix(pos, X, Y, Z), color, material, false)
			end
		end
		if each then
			each(centre, math.max(w0, w1), segLen, (t0 + t1) / 2)
		end
		cf = cf * CFrame.new(0, 0, -segLen)
		w0 = w1
	end
	if roundTip ~= false and w0 > MIN * 1.5 then
		-- A disc lying in the blade's face, half past the tip, rounds it off
		-- (between the two segment thicknesses, so it shares no face with the last one).
		part(ctx, name, Enum.PartType.Cylinder, Vector3.new(thick * 1.02, w0, w0), CFrame.fromMatrix(cf.Position, cf.UpVector, cf.LookVector), colorAt(1), material, false)
	end
	return cf
end

PlantBuilder.make = {
	part = part,
	ellipsoid = ellipsoid,
	ball = ball,
	cylinderBetween = cylinderBetween,
	upFrame = upFrame,
	look = look,
}

----------------------------------------------------------------------------
-- The ground under the plant

-- Leaves near the ground lie along it instead of poking into it (low leaves
-- are ramps for climbing on, so they stay low). The land around the plant is
-- sampled once per build and fitted with a smooth bowl/slope, in design studs.
local GROUND_REACH = 3 -- design studs from the base to the ground samples
local GROUND_GAP = 0.08 -- design studs of air left under a leaf (terrain voxels are only so exact)
local OFF_GROUND = 1.5 -- base this far (design studs) above the land: on a pad, pot or water

type Floor = (Vector3) -> number

local function makeFloor(base: CFrame): Floor
	local bp = base.Position
	local flat = function(_p: Vector3): number
		return bp.Y
	end
	local ok, h0 = pcall(Ground.heightAt, bp.X, bp.Z)
	if not ok or (bp.Y - h0) / WORLD > OFF_GROUND then
		-- Not on the land (a tree pad, a pot, the water): its own level is the floor.
		return flat
	end
	local R = GROUND_REACH * WORLD
	local function h(dx: number, dz: number): number
		return (Ground.heightAt(bp.X + dx, bp.Z + dz) - h0) / WORLD
	end
	local px, nx, pz, nz = h(R, 0), h(-R, 0), h(0, R), h(0, -R)
	local r = GROUND_REACH
	local sx, sz = (px - nx) / (2 * r), (pz - nz) / (2 * r)
	local bowl = (px + nx + pz + nz) / 4 / (r * r)
	return function(p: Vector3): number
		local dx, dz = p.X - bp.X, p.Z - bp.Z
		return bp.Y + sx * dx + sz * dz + bowl * (dx * dx + dz * dz)
	end
end

-- How far below its centre an ellipsoid of this size reaches, at this angle,
-- allowing for the leaf flutter tipping it about its X axis.
local function reachBelow(cf: CFrame, size: Vector3): number
	local a, b, c = size.X / 2, size.Y / 2, size.Z / 2
	local function down(up: Vector3, look: Vector3): number
		local x, y, z = cf.RightVector.Y * a, up.Y * b, look.Y * c
		return math.sqrt(x * x + y * y + z * z)
	end
	local f = Wind.FLUTTER_MAX
	if flutterBound.value ~= f then
		flutterBound.value, flutterBound.cos, flutterBound.sin = f, math.cos(f), math.sin(f)
	end
	local cs, sn = flutterBound.cos, flutterBound.sin
	local up, look = cf.UpVector, cf.LookVector
	return math.max(down(up * cs + look * sn, look * cs - up * sn), down(up * cs - look * sn, look * cs + up * sn))
end

-- Pitch a piece of leaf up about its base until it clears the ground.
-- piece(cf) -> (centre CFrame, size) of the piece if it started at cf.
-- Pitching keeps the leaf in one piece (each piece starts where the last one
-- ended), so it tips up as steep as it must, curling up off the ground. Only
-- a piece that starts underground and can't clear even nearly upright is
-- lifted, which would open a gap, so that is the very last resort.
local function clearGround(ctx, cf: CFrame, piece: (CFrame) -> (CFrame, Vector3)): CFrame
	local floor = ctx.floor
	if not floor then
		return cf
	end
	local function under(c: CFrame): number
		local centre, size = piece(c)
		return floor(centre.Position) + GROUND_GAP - (centre.Position.Y - reachBelow(centre, size))
	end
	local deficit = under(cf)
	if deficit <= 0 then
		return cf
	end
	for _ = 1, 40 do
		if cf.LookVector.Y > 0.95 then
			break
		end
		cf = cf * CFrame.Angles(0.06, 0, 0)
		deficit = under(cf)
		if deficit <= 0 then
			return cf
		end
	end
	return cf + Vector3.yAxis * deficit
end

----------------------------------------------------------------------------
-- Leaves

-- sessile: the leaf grows straight out of a building's shell, with no
-- stalk, so its blade starts right at the wall (baseCF sits a little inside it).
local function buildLeaf(ctx, baseCF: CFrame, length: number, maturity: number, nodeT: number, sessile: boolean?)
	local g = ctx.g
	local L = length * (0.25 + 0.75 * maturity)
	if L < 0.08 then
		return
	end
	local ratio = lerp(1.3, 5, g.leafLength) -- length : width
	local maxW = L / ratio
	-- Blade outline: sin(pi * t^k) peaks near the tip for small leafShape and near the base for large.
	local k = lerp(1.4, 0.5, g.leafShape)
	local segs = ctx.leafSegments
	local petiole = if sessile then 0 else L * 0.18
	local bladeLen = L - petiole
	-- Leaves unfold flat and droop more as they mature.
	local bend = -(0.04 + g.leafDroop * 0.4) * maturity
	local base = ctx.colors.leaf
	local tip = Palette.shade(base, 0.3)
	local depth = 0.25 + 0.25 * (1 - nodeT) -- lower leaves sit in more shade

	local petioleW = math.max(0.07, maxW * 0.14)
	local cf = profileGeometry(ctx, "PlantLeafClearance", clearGround, ctx, baseCF, function(c: CFrame)
		return c * CFrame.new(0, 0, -petiole * 0.5), Vector3.new(petioleW, petioleW, petiole)
	end)
	-- The whole leaf swings where its petiole meets the stem.
	local outerJoint = openJoint(ctx, "leaf", cf)
	if petiole > 0 then
		cylinderBetween(ctx, "Petiole", cf.Position, (cf * CFrame.new(0, 0, -petiole)).Position, petioleW, Palette.shade(ctx.colors.stem, 0.05), ctx.M.stem)
		cf = cf * CFrame.new(0, 0, -petiole)
	end
	local thick = 0.07 + L * 0.015
	if ctx.ultra and petiole > 0 then
		-- The petiole swells where it meets the blade (pulvinus).
		ellipsoid(ctx, "Petiole", Vector3.new(petioleW * 1.6, petioleW * 1.3, petioleW * 2.2), cf, Palette.shade(ctx.colors.stem, 0.12), ctx.M.stem)
	end
	-- The blade is one continuous tapered surface (see blade), widest where
	-- the gene puts it and pointed at the tip; close up it also shows a pale
	-- midrib with paired side veins running toward the tip.
	local function widthAt(t: number): number
		-- Never narrower than the stalk at the base, so the blade grows
		-- straight out of it instead of starting as a sliver.
		-- A leaf set straight into a wall starts broad, clasping it.
		local floor = if t < 0.5 then math.max(0.1, petioleW * 1.2, if sessile then maxW * 0.45 * (1 - t * 2) else 0) else 0.05
		return math.max(floor, maxW * math.sin(math.pi * math.clamp(t, 0, 1) ^ k))
	end
	blade(ctx, "Leaf", cf, bladeLen, segs, thick, widthAt, function(t: number): Color3
		return Palette.gradient(base, tip, t, depth)
	end, ctx.M.leaf, function(): number
		return bend
	end, function(c: CFrame, segLen2: number, width: number): CFrame
		-- Near the ground the blade levels off and lies along it instead.
		return profileGeometry(ctx, "PlantLeafClearance", clearGround, ctx, c, function(c2: CFrame)
			return c2 * CFrame.new(0, 0, -segLen2 * 0.5), Vector3.new(width, thick, segLen2 * 1.65)
		end)
	end, function(centre: CFrame, width: number, segLen2: number, t: number)
		if ctx.ultra then
			local veinColor = Palette.shade(base:Lerp(tip, t), 0.45)
			vein(ctx, "LeafVein", Vector3.new(math.max(0.05, width * 0.07), thick * 1.5, segLen2 * 1.15), centre * CFrame.new(0, thick * 0.4, 0), veinColor, ctx.M.joint)
			if width > 0.25 then
				for _, side in { -1, 1 } do
					vein(ctx, "LeafVein", Vector3.new(width * 0.4, thick * 1.25, 0.04 + width * 0.04), centre * CFrame.new(side * width * 0.2, thick * 0.4, 0) * CFrame.Angles(0, side * 0.6, 0), veinColor, ctx.M.joint)
				end
			end
		end
		-- Something to stand on, where the leaf is wide and flat enough.
		profileGeometry(ctx, "PlantClimb", Climb.leafFoothold, ctx, centre, width, segLen2 * 1.1, thick)
	end, false)
	ctx.joint = outerJoint
end

----------------------------------------------------------------------------
-- Flowers

local function buildFlower(ctx, cf: CFrame, scale: number)
	local g = ctx.g
	local b = Growth.phase(ctx.p, Growth.BUD)
	if b <= 0 then
		return
	end
	local o = Growth.phase(ctx.p, Growth.BLOOM)
	-- The head nods where it meets its stem (a cluster's pedicel already
	-- opened its joint); tight buds are stiffer than open flowers.
	local outerJoint = ctx.joint
	if not (outerJoint and outerJoint.kind == "head") then
		openJoint(ctx, "head", cf, lerp(0.5, 1, o))
	end
	if o > 0 then
		-- Turn at the base of the bloom, including on clusters whose wind
		-- joint is farther down at the base of the pedicel.
		openJoint(ctx, "bloom", cf, o)
		if ctx.joint and ctx.climbTop and o > 0.6 then
			ctx.joint.sunTiltLimit = math.rad(30)
		end
	end
	local F = lerp(0.6, 2.8, g.flowerSize) * scale
	-- Buds are budSize-dependent and swell to full size as they open.
	local grow = lerp(0.3, 1, b) * lerp(lerp(0.5, 0.9, g.budSize), 1, o)
	local col = ctx.colors

	if o > 0 then
		table.insert(ctx.flowers, { cframe = cf * CFrame.new(0, 0.15 * F * grow, 0), nectar = o })
	end

	-- Receptacle and sepals cup the bud and fold back as it opens.
	local SEPAL = ctx.sepal
	ball(ctx, "Receptacle", 0.42 * F * grow, cf.Position, Palette.shade(SEPAL, -0.2), ctx.M.sepal)
	local sepalLen = 0.5 * F * grow
	local sepalAngle = lerp(0.25, 1.5, o)
	local sepalColor = Palette.gradient(SEPAL, Palette.shade(SEPAL, 0.2), 0.5, 0.3)
	if ctx.ultra then
		-- Eight sepals, each in two pieces that curl back at the tip, on a ribbed receptacle.
		for i = 1, 8 do
			local scf = cf * CFrame.Angles(0, i / 8 * TAU + 0.3, 0) * CFrame.Angles(math.pi / 2 - sepalAngle, 0, 0)
			blade(ctx, "Sepal", scf, sepalLen, 2, 0.06, function(t: number): number
				return sepalLen * 0.36 * (1 - 0.75 * t)
			end, function(t: number): Color3
				return Palette.shade(sepalColor, 0.2 * t)
			end, ctx.M.sepal, function(j: number): number
				return if j > 1 then -0.35 * o else 0
			end)
			local rib = cf * CFrame.Angles(0, (i + 0.5) / 8 * TAU + 0.3, 0) * CFrame.new(0, 0, -0.2 * F * grow)
			ellipsoid(ctx, "Receptacle", Vector3.new(0.08, 0.3, 0.1) * F * grow, rib, Palette.shade(SEPAL, -0.35), ctx.M.sepal)
		end
	else
		for i = 1, 5 do
			local scf = cf * CFrame.Angles(0, i / 5 * TAU + 0.3, 0) * CFrame.Angles(math.pi / 2 - sepalAngle, 0, 0)
			blade(ctx, "Sepal", scf, sepalLen, 1, 0.06, function(t: number): number
				return sepalLen * 0.4 * (1 - 0.7 * t)
			end, function(): Color3
				return sepalColor
			end, ctx.M.sepal)
		end
	end

	-- Petals: whorls of n, inner whorls smaller, more upright and offset half a step.
	local n = 3 + math.floor(g.petalCount * 5.99)
	local layers = 1 + math.floor(g.petalLayers * 2.99)
	local openMax = lerp(1.0, 1.75, g.petalCurl)
	local curl = g.petalCurl * o * 0.9
	-- A fire plant's petals are flames: they lean out less and lick upward
	-- instead of curling back (see the petal loop below).
	local flame = ctx.flame
	if flame then
		openMax = lerp(0.9, 1.25, g.petalCurl)
		curl = -(0.45 + 0.35 * g.petalCurl) * o -- negative: bends up
	end
	local segs = ctx.petalSegments
	-- Buds carry a green tint that fades as they colour up and open.
	local budTint = (1 - 0.5 * b - 0.5 * o) * 0.7
	-- The top flower of a climbable stem is a platform: climbers come up onto
	-- it and can walk about on it (invisible, so the flower looks the same;
	-- built in the head's joint, so it nods with the head).
	local platform = false
	if ctx.climbTop and o > 0.6 then
		local len1 = F * lerp(0.6, 1.25, g.petalLength) * grow
		local reach = len1 * math.sin(lerp(0.12, openMax, o))
		local centreD = F * 0.38 * lerp(0.4, 1, o)
		profileGeometry(ctx, "PlantClimb", Climb.flowerTop, ctx, cf, 0.1 * F * grow + (0.05 + 0.03 * F) * 0.5, math.max(reach * 0.9, centreD * 0.8), cf * CFrame.new(0, 0.15 * F * grow, 0), centreD)
		platform = true
	elseif ctx.climbTop then
		-- A bud (or a flower still opening): climbers come out on top of
		-- it, a small round seat across the tips of its closed petals.
		local len1 = F * lerp(0.6, 1.25, g.petalLength) * grow
		local angle = lerp(0.12, openMax, o)
		local top = 0.1 * F * grow + len1 * math.cos(angle) * 0.9
		local seat = math.max(len1 * math.sin(angle) * 1.2, 0.3)
		local knob = math.max(0.12 * F * grow, 0.08)
		profileGeometry(ctx, "PlantClimb", Climb.flowerTop, ctx, cf, top, seat, cf * CFrame.new(0, top, 0), knob)
	end
	for layer = 1, layers do
		local ls = 1 - 0.2 * (layer - 1)
		local len = F * lerp(0.6, 1.25, g.petalLength) * ls * grow
		local width = len * lerp(0.25, 0.75, g.petalWidth)
		local a = lerp(0.12, openMax * (1 - 0.22 * (layer - 1)), o)
		local baseColor = col.petalBase:Lerp(ctx.sepal, budTint)
		local tipColor = col.petalBase:Lerp(col.petalTip, 1 - 0.35 * (layer - 1)):Lerp(ctx.sepal, budTint * 0.6)
		if flame then
			-- Deep orange at the base licking up to yellow; inner whorls burn
			-- hotter (yellower). A bud is still mostly its metal cup.
			local hot = 0.25 * (layer - 1)
			baseColor = Palette.flame(col.petalBase, hot):Lerp(ctx.sepal, budTint)
			tipColor = Palette.flame(col.petalBase, 1):Lerp(ctx.sepal, budTint * 0.6)
		end
		local offset = (layer - 1) * math.pi / n
		for i = 1, n do
			local pcf = cf
				* CFrame.new(0, 0.1 * F * grow, 0)
				* CFrame.Angles(0, i / n * TAU + offset, 0)
				* CFrame.Angles(math.pi / 2 - a, 0, 0)
			local headJoint = openJoint(ctx, "petal", pcf)
			if layer == 1 and o > 0.6 and not platform then
				-- Open outer petals are wide enough to stand on.
				profileGeometry(ctx, "PlantClimb", Climb.leafFoothold, ctx, pcf * CFrame.new(0, 0, -len * 0.45), width * 0.85, len * 0.85, 0.05 + 0.03 * F)
			end
			-- One continuous petal: a narrow claw at the base, widest past the
			-- middle, a rounded tip, curling back along its length.
			local pthick = 0.05 + 0.03 * F
			if flame then
				-- A tongue of flame: broad low down, drawn to a point, every
				-- other one a little taller so the fire looks uneven and alive.
				local tongue = if i % 2 == 0 then 0.82 else 1.12
				local fw = width * 0.85
				blade(ctx, "Petal", pcf, len * tongue, segs, pthick, function(t: number): number
					return fw * math.max(0.1, (1 - t) ^ 0.7 * (0.6 + 0.8 * t))
				end, function(t: number): Color3
					return baseColor:Lerp(tipColor, t)
				end, ctx.M.petal, function(j: number): number
					return if j > 1 then -curl / (segs - 1) else 0
				end, nil, function(seg: CFrame, w: number, sl: number, t: number)
					if ctx.ultra and t < 0.75 then
						-- A hot pale core up the middle of the flame.
						vein(ctx, "PetalVein", Vector3.new(math.max(0.05, w * 0.35), pthick * 1.3, sl * 1.2), seg * CFrame.new(0, pthick * 0.35, 0), tipColor:Lerp(Color3.new(1, 1, 0.85), 0.5), ctx.M.petal)
					end
				end, false)
				ctx.joint = headJoint
				continue
			end
			blade(ctx, "Petal", pcf, len, segs, pthick, function(t: number): number
				return width * (0.35 + 0.65 * math.sin(math.pi * (0.15 + 0.7 * t)))
			end, function(t: number): Color3
				return Palette.gradient(baseColor, tipColor, t, 0.4)
			end, ctx.M.petal, function(j: number): number
				return if j > 1 then -curl / (segs - 1) else 0
			end, nil, function(seg: CFrame, w: number, sl: number, t: number)
				if ctx.ultra then
					-- Nectar guide down the middle (dark at the base, fading out),
					-- and a pale frilled rim on the outer half.
					if t < 0.7 then
						vein(ctx, "PetalVein", Vector3.new(math.max(0.05, w * 0.18), pthick * 1.3, sl * 1.4), seg * CFrame.new(0, pthick * 0.35, 0), Palette.shade(baseColor:Lerp(col.center, 0.5), -0.35 + t * 0.5), ctx.M.petal)
					end
					if t > 0.45 then
						for _, side in { -1, 1 } do
							vein(ctx, "PetalVein", Vector3.new(w * 0.3, pthick * 1.1, sl * 1.2), seg * CFrame.new(side * w * 0.36, pthick * 0.25, 0) * CFrame.Angles(0, 0, side * 0.25), Palette.shade(Palette.gradient(baseColor, tipColor, t, 0.4), 0.3), ctx.M.petal)
						end
					end
				end
			end)
			ctx.joint = headJoint
		end
	end

	-- Pollen centre and anthers appear as the flower opens.
	if o > 0.05 then
		local centrePos = (cf * CFrame.new(0, 0.15 * F * grow, 0)).Position
		local centre = ball(ctx, "FlowerCentre", F * 0.38 * lerp(0.4, 1, o), centrePos, Palette.shade(col.center, -0.1), ctx.M.center)
		if centre then
			if ctx.glow > 0 then
				-- A light plant's flower is a little lamp: a glowing bulb in
				-- its own petal colour (LightPlants adds the real light).
				centre.Material = Enum.Material.Neon
				centre.Color = Palette.shade(col.petalBase, 0.25):Lerp(Color3.new(1, 1, 0.9), 0.25)
				centre:SetAttribute("Lamp", true)
			elseif ctx.heat >= 1 then
				centre.Material = Enum.Material.Neon -- a fire plant's flower glows like a coal
			end
			centre.CanQuery = true
			centre:SetAttribute("NectarAmount", o)
			if ctx.plantId then
				centre:SetAttribute("PlantId", ctx.plantId)
			end
			if not ctx.visualOnly then
				CollectionService:AddTag(centre, PlantBuilder.FLOWER_TAG)
			end
		end
		local centreD = F * 0.38 * lerp(0.4, 1, o)
		if ctx.ultra and ctx.glow == 0 then -- (a light plant's bulb stays bare so it shines)
			-- Disc florets packed in a golden-angle spiral over the centre dome,
			-- like a sunflower head: darker in the middle, lighter at the rim.
			local florets = 18 + math.floor(F * 8)
			local R = centreD * 0.5
			for i = 1, florets do
				local f = math.sqrt((i - 0.5) / florets)
				local az = i * GOLDEN
				local lift = math.sqrt(math.max(0, 1 - f * f * 0.8))
				local fpos = (cf * CFrame.new(math.cos(az) * f * R * 0.95, 0.15 * F * grow + lift * R * 0.85, math.sin(az) * f * R * 0.95)).Position
				ball(ctx, "Floret", math.max(MIN, centreD * lerp(0.16, 0.24, f)), fpos, Palette.shade(col.center, -0.35 + 0.6 * f), ctx.M.center)
			end
		end
		if ctx.showAnthers and o > 0.5 then
			local count = if ctx.ultra then 12 else 6
			local anther = Palette.shade(col.center, 0.35)
			for i = 1, count do
				local acf = cf * CFrame.Angles(0, i / count * TAU, 0) * CFrame.new(0, 0.32 * F * grow, -0.2 * F)
				if ctx.ultra then
					-- Each anther sits on a thin filament rising from the centre.
					local root = (cf * CFrame.Angles(0, i / count * TAU, 0) * CFrame.new(0, 0.15 * F * grow, -0.06 * F)).Position
					local filament = cylinderBetween(ctx, "Filament", root, acf.Position, math.max(MIN, F * 0.025), if ctx.flame then Palette.FLAME_TIP else Palette.shade(col.petalBase, 0.5), ctx.M.anther)
					if filament then
						ctx.groupOf[filament] = nil -- hair-thin: cheap as a part, thousands of triangles in a union
					end
					ellipsoid(ctx, "Anther", Vector3.new(F * 0.07, F * 0.06, F * 0.13), look(acf.Position, root) * CFrame.Angles(0, math.pi / 2, 0), anther, ctx.M.anther)
				else
					ball(ctx, "Anther", F * 0.09, acf.Position, anther, ctx.M.anther)
				end
			end
		end
	end
	ctx.joint = outerJoint
end

local function buildFlowerCluster(ctx, tipCF: CFrame, scale: number)
	local g = ctx.g
	local count = 1 + math.floor(g.flowersPerTip * 2.99)
	if count == 1 then
		buildFlower(ctx, tipCF, scale)
		return
	end
	-- Not one flower to stand on, so the cluster gets a platform of its
	-- own across the heads' tops (below), not each small head.
	local platformTop = ctx.climbTop
	ctx.climbTop = nil
	local b = Growth.phase(ctx.p, Growth.BUD)
	if b <= 0 then
		return
	end
	-- Several flowers on short stalks (pedicels) fanning out from the tip, like an umbel.
	local pedLen = lerp(0.6, 1.4, g.flowerSize) * scale * lerp(0.4, 1, b)
	for i = 1, count do
		local dcf = tipCF * CFrame.Angles(0, i / count * TAU, 0) * CFrame.Angles(math.pi / 2 - 0.6, 0, 0)
		local endPos = dcf.Position + dcf.LookVector * pedLen
		-- Stalk and flower swing together from where the stalk leaves the tip.
		local outerJoint = openJoint(ctx, "head", dcf, lerp(0.5, 1, Growth.phase(ctx.p, Growth.BLOOM)))
		cylinderBetween(ctx, "Pedicel", dcf.Position, endPos, 0.1 * scale + 0.04, ctx.colors.stem, ctx.M.stem)
		buildFlower(ctx, upFrame(endPos, (dcf.LookVector + tipCF.UpVector).Unit), scale * 0.7)
		ctx.joint = outerJoint
	end
	if platformTop then
		-- Climbers come out on top of the cluster: a disc over the heads.
		local headF = lerp(0.6, 2.8, g.flowerSize) * scale * 0.7
		local top = pedLen * math.cos(0.6) + 0.25 * headF * lerp(0.5, 1, b)
		local across = pedLen * math.sin(0.6) + 0.5 * headF
		profileGeometry(ctx, "PlantClimb", Climb.flowerTop, ctx, tipCF, top, across, tipCF * CFrame.new(0, top, 0), math.max(0.25 * headF, 0.1))
	end
end

----------------------------------------------------------------------------
-- Stems

type AxisOptions = {
	nodes: number,
	internode: number,
	thick: number,
	visible: number, -- nodes grown so far (fractional)
	salt: number,
	depth: number, -- 0 main stem (may branch), 1 branch or scape
	leafScale: number,
	leafLift: number?, -- multiplier on leaf elevation (rosettes lie flat)
	flowerScale: number,
	noLeaves: boolean?,
	noFlower: boolean?,
	climb: boolean?, -- the stem players climb like a ladder (see Climb)
	climbBranch: boolean?, -- a side branch of that stem, climbable too (its own chain, see Climb.stemPiece)
	rooms: { [number]: number }?, -- segment index -> room number (see Habitat.plan)
}

-- Radians a leaf can lift in the strongest gust (Wind.jointSway), kept as
-- headroom under a flower.
local LEAF_SWAY_ROOM = Wind.LEAF_LIFT * 1.4 * Wind.EFFECT

local function stemStep(ctx, pos: Vector3, dir: Vector3, r: Random, length: number, diameter: number, roomNumber: number?, grow: number)
	local tilt = ctx.g.stemCurve * 0.35
	dir = (dir + Vector3.new(r:NextNumber(-tilt, tilt), 0, r:NextNumber(-tilt, tilt)) + Vector3.yAxis * 0.15).Unit
	local room = nil
	if roomNumber and ctx.habitatSwell then
		room = Habitat.room(ctx.g, roomNumber, ctx.habitatSwell * grow, diameter / 2)
		dir = ctx.upright.UpVector
		length = room.total
	end
	return pos + dir * length, dir, room
end

local function growAxis(ctx, startCF: CFrame, opts: AxisOptions)
	local g = ctx.g
	local pos = startCF.Position
	local dir = startCF.UpVector
	local az0 = ctx.rng(opts.salt, 0):NextNumber() * TAU
	local divergence, perNode
	if g.phyllotaxis < 0.33 then
		divergence, perNode = math.pi, 1 -- alternate
	elseif g.phyllotaxis < 0.66 then
		divergence, perNode = math.pi / 2, 2 -- opposite, decussate
	else
		divergence, perNode = GOLDEN, 1 + math.floor(g.leafPerNode * 2.99) -- spiral / whorled
	end
	local stemColor = ctx.colors.stem
	local branches = 0
	-- How far the flower head at the top of this axis spreads (see buildFlower
	-- and buildFlowerCluster), so the leaves below can keep out of it.
	local flowerReach = 0
	if not opts.noFlower then
		local F = lerp(0.6, 2.8, g.flowerSize) * opts.flowerScale
		flowerReach = F * (lerp(0.6, 1.25, g.petalLength) + 0.4)
		if 1 + math.floor(g.flowersPerTip * 2.99) > 1 then
			flowerReach = flowerReach * 0.7 + lerp(0.6, 1.4, g.flowerSize) * opts.flowerScale
		end
	end
	local path = if opts.climb or opts.climbBranch then { { pos = pos, d = opts.thick * ctx.thickScale } } else nil

	for i = 0, opts.nodes - 1 do
		if ctx.breathe then
			ctx.breathe()
		end
		local grow = math.clamp(opts.visible - i, 0, 1)
		if grow <= 0 then
			break
		end
		local r = ctx.rng(opts.salt, i + 1)
		local prevDir = dir
		local t = i / opts.nodes
		local thick = lerp(opts.thick, opts.thick * 0.45, t) * ctx.thickScale
		-- A room segment: the stem swells into a room (Habitat). It grows
		-- straight up, as long as the room is tall, and stays level.
		local nextPos, nextDir, room = stemStep(ctx, pos, dir, r, opts.internode * grow, thick, opts.rooms and opts.rooms[i], grow)
		dir = nextDir
		if room then
			prevDir = dir
		end
		local color = Palette.shade(stemColor, -0.3 + 0.45 * t)
		-- Stems aren't solid themselves: the climbed stem gets invisible
		-- climbable pieces, and side branches a walkway along their top (see Climb).
		local collide = false
		local thickNext = lerp(opts.thick, opts.thick * 0.45, (i + 1) / opts.nodes) * ctx.thickScale
		local ctrl = pos + prevDir * (nextPos - pos).Magnitude * 0.45
		if room then
			local bottom = CFrame.new(pos) * ctx.upright.Rotation
			profileGeometry(ctx, "PlantHabitat", Habitat.build, ctx, bottom, room, thick / 2, thickNext / 2, color)
		end
		-- Is the next segment a room? Then this node is under its floor, and
		-- whatever grows here must sprout outside the room's walls instead.
		local below = nil
		local nextNumber = opts.rooms and opts.rooms[i + 1]
		local growNext = math.clamp(opts.visible - i - 1, 0, 1)
		if nextNumber and ctx.habitatSwell and growNext > 0 then
			below = Habitat.room(g, nextNumber, ctx.habitatSwell * growNext, thickNext / 2)
		end
		local roomAbove = not below and opts.rooms ~= nil and opts.rooms[i + 2] ~= nil and ctx.habitatSwell ~= nil and opts.visible > i + 2
		-- How far out from the stem a leaf or branch starts, in direction
		-- outDir: from a room's roof, round its edge; under a room, just
		-- outside its walls (past the walls of this room too, if this node is
		-- also this room's roof); otherwise at the stem's surface.
		local function sproutOffset(outDir: Vector3): number
			local d = ctx.upright.Rotation:VectorToObjectSpace(outDir)
			local flat = Vector2.new(d.X, d.Z)
			if not (room or below) or flat.Magnitude < 1e-3 then
				return thick * 0.4
			end
			flat = flat.Unit
			local function toLocal(rm): (number, number)
				local ca, sa = math.cos(rm.doorAz), math.sin(rm.doorAz)
				return flat.X * ca + flat.Y * sa, -flat.X * sa + flat.Y * ca
			end
			if below then
				local reach = Habitat.wallReach(below, toLocal(below))
				if room then
					reach = math.max(reach, Habitat.wallReach(room, toLocal(room)))
				end
				return reach + below.wall + thick * 0.2
			end
			return Habitat.roofReach(room, toLocal(room)) * 0.9
		end
		-- How far out the room above's surface is, in direction outDir, at
		-- height y over this node.
		local function bellyReach(outDir: Vector3, y: number): number
			if not below then
				return thick * 0.4
			end
			local d = ctx.upright.Rotation:VectorToObjectSpace(outDir)
			local ca, sa = math.cos(below.doorAz), math.sin(below.doorAz)
			return Habitat.surfaceReach(below, d.X * ca + d.Z * sa, -d.X * sa + d.Z * ca, y)
		end
		-- Through a room the stem runs straight up, slim inside the room and
		-- flaring out to full thickness at the floor and the ceiling
		-- (Habitat.stemRadius): pieces between these heights follow that shape.
		local function roomPieces(steps: number): { { a: Vector3, b: Vector3, d: number } }
			local list = {}
			local ys = Habitat.stemProfile(room, steps)
			for k = 1, #ys - 1 do
				local y0, y1 = ys[k], ys[k + 1]
				local d = 2 * Habitat.stemRadius(room, (y0 + y1) / 2, thickNext / 2)
				table.insert(list, { a = pos + dir * y0, b = pos + dir * y1, d = d })
			end
			return list
		end
		if path and room then
			-- The climbable stem slims with the visible one, so climbers hug it
			-- inside the room and go up through the floor's hole round it.
			for _, piece in roomPieces(3) do
				profileGeometry(ctx, "PlantClimb", Climb.stemPiece, ctx, piece.a, piece.b, piece.d)
				table.insert(path, { pos = piece.b, d = piece.d })
			end
			profileGeometry(ctx, "PlantClimb", Climb.setLine, ctx, nextPos, dir, thickNext)
		elseif path then
			-- Follow the same curve the close-up stem draws, at every detail level,
			-- so climbers hold the stem in the same place for everyone.
			local prevPoint = pos
			for _, u in { 0.5, 1 } do
				local q = pos * (1 - u) ^ 2 + ctrl * 2 * u * (1 - u) + nextPos * u * u
				local d = lerp(thick, thickNext, u)
				profileGeometry(ctx, "PlantClimb", Climb.stemPiece, ctx, prevPoint, q, d)
				table.insert(path, { pos = q, d = d })
				prevPoint = q
			end
			if opts.climb then
				profileGeometry(ctx, "PlantClimb", Climb.setLine, ctx, nextPos, dir, thick)
			end
		end
		if opts.depth > 0 and not opts.climb then
			profileGeometry(ctx, "PlantClimb", Climb.branchFoothold, ctx, pos, nextPos, thick)
		end
		-- This stretch of stem (and the node ball on top) unions into one piece.
		ctx.stemGroup = {}
		if room then
			local pieces = roomPieces(if ctx.ultra then 4 else 2)
			for k, piece in pieces do
				local shade = Palette.shade(color, 0.08 * (k / #pieces - 0.5))
				cylinderBetween(ctx, "Stem", piece.a, piece.b, piece.d, shade, ctx.M.stem, collide)
				if k < #pieces then
					-- round off the joint, as wide as the narrower of the two pieces
					ball(ctx, "Stem", math.min(piece.d, pieces[k + 1].d), piece.b, shade, ctx.M.stem)
				end
			end
		elseif ctx.ultra then
			-- A smooth curve through the same two nodes (so flowers and leaves
			-- land in the same place at every detail level), tapering as it goes.
			local n = ctx.stemSegments
			local last = pos
			for sIdx = 1, n do
				local u = sIdx / n
				local q = pos * (1 - u) ^ 2 + ctrl * 2 * u * (1 - u) + nextPos * u * u
				local d = lerp(thick, thickNext, (sIdx - 0.5) / n)
				cylinderBetween(ctx, "Stem", last, q, d, Palette.shade(color, 0.08 * (u - 0.5)), ctx.M.stem, collide)
				if sIdx < n then
					ball(ctx, "Stem", d, q, Palette.shade(color, 0.08 * (u - 0.5)), ctx.M.stem)
				end
				last = q
			end
		else
			local d = lerp(thick, thickNext, 0.5 / ctx.stemSegments)
			cylinderBetween(ctx, "Stem", pos, nextPos, d, color, ctx.M.stem, collide)
		end
		-- Close up: a node collar and a pair of stipules at the leaf base (not
		-- under a room: they'd poke up into it).
		if ctx.ultra and not below and not room then
			ellipsoid(ctx, "Node", Vector3.new(thick * 1.3, thick * 0.45, thick * 1.3), upFrame(nextPos, dir), Palette.shade(color, -0.15), ctx.M.joint)
			local sr = ctx.rng(opts.salt + 977, i)
			local saz = az0 + i * divergence + math.pi / 2
			for _, side in { -1, 1 } do
				local scf = upFrame(nextPos, dir) * CFrame.Angles(0, saz + side * 0.5, 0) * CFrame.Angles(0.9, 0, 0)
				local sl = math.max(0.12, thick * sr:NextNumber(0.7, 1.1))
				ellipsoid(ctx, "Sepal", Vector3.new(sl * 0.5, 0.05, sl), scf * CFrame.new(0, 0, -thick * 0.5 - sl * 0.4), Palette.shade(ctx.colors.leaf, 0.1), ctx.M.leaf)
			end
		end
		-- (Not on a room's roof either: it would bulge down into the room.)
		if not below and not room then
			ball(ctx, "Node", thick * 1.12, nextPos, Palette.shade(color, 0.05), ctx.M.joint)
		end
		ctx.stemGroup = nil

		if not opts.noLeaves then
			local maturity = math.clamp((opts.visible - i - 0.2) / 1.5, 0, 1)
			if maturity > 0 then
				local L = ctx.leafLen * opts.leafScale * lerp(1.15, 0.6, t)
				local nodeCF = upFrame(nextPos, dir)
				local elev = lerp(1.0, 0.25, g.leafDroop) * lerp(1.4, 1, maturity) * (opts.leafLift or 1)
				-- A room just above (one short segment up): lean the leaves down
				-- and out so they don't reach up into it.
				if roomAbove then
					elev = -0.2
				end
				-- Close under the flower head, leaves angle out and down so that
				-- even at the top of their sway they stay below its petals.
				local skip = false
				if flowerReach > 0 then
					local d = (opts.nodes - 1 - i) * opts.internode
					if i >= opts.nodes - 1 then
						skip = true -- the flower sits right on this node
					else
						-- The leaf's tip may rise no higher than a little under the
						-- head (it spreads about a third of its reach below the tip).
						local headroom = math.clamp((d - flowerReach * 0.35) / L, -0.45, 1)
						elev = math.min(elev, math.asin(headroom) - LEAF_SWAY_ROOM)
					end
				end
				for k = 0, if skip then -1 else perNode - 1 do
					local az = az0 + i * divergence + k * TAU / perNode
					local lcf
					local sessile = false
					if below then
						-- From the room's rounded belly, just above this node, its
						-- stalk set into the shell, leaning a little down.
						local around = CFrame.new(nextPos) * ctx.upright.Rotation * CFrame.Angles(0, az, 0)
						local y = below.round * 0.6
						local reach = bellyReach(around.LookVector, y) - below.wall * 0.5
						lcf = around * CFrame.new(0, y, -reach) * CFrame.Angles(-0.2, 0, 0)
						sessile = true
					elseif room then
						-- From the room's rounded shoulder, just under the roof's
						-- edge, set into the shell so the blade starts at its surface.
						local around = CFrame.new(nextPos) * ctx.upright.Rotation * CFrame.Angles(0, az, 0)
						local d = ctx.upright.Rotation:VectorToObjectSpace(around.LookVector)
						local ca, sa = math.cos(room.doorAz), math.sin(room.doorAz)
						local y = room.coreHi + room.round * 0.45
						local reach = Habitat.surfaceReach(room, d.X * ca + d.Z * sa, -d.X * sa + d.Z * ca, y) - room.wall * 0.5
						lcf = around * CFrame.new(0, y - room.total, -reach) * CFrame.Angles(math.min(elev, 0.5), 0, 0)
						sessile = true
					else
						lcf = nodeCF * CFrame.Angles(0, az, 0) * CFrame.Angles(elev, 0, 0) * CFrame.new(0, 0, -thick * 0.4)
					end
					buildLeaf(ctx, lcf, L, maturity, t, sessile)
				end
			end
		end

		-- Side branch from the leaf axil.
		-- (None under a room: it would grow up the room's walls.)
		if opts.depth == 0 and not below and not roomAbove and i >= 1 and i < opts.nodes - 1 and branches < ctx.maxBranches and r:NextNumber() < g.branching * 0.7 then
			branches += 1
			local bAngle = lerp(0.35, 1.2, g.branchAngle)
			local baz = az0 + i * divergence
			local bcf = upFrame(nextPos, dir) * CFrame.Angles(0, baz, 0) * CFrame.Angles(math.pi / 2 - bAngle, 0, 0)
			if room then
				local around = upFrame(nextPos, dir) * CFrame.Angles(0, baz, 0)
				bcf = bcf + around.LookVector * sproutOffset(around.LookVector)
			end
			local bNodes = math.max(2, math.floor(opts.nodes * 0.5))
			local bVisible = math.clamp((opts.visible - i - 1) / (opts.nodes - i - 1), 0, 1) * bNodes
			-- A branch off the climbed stem is climbable too, as its own chain.
			local climbBranch = path ~= nil
			local prevChain, prevFrom
			if climbBranch then
				prevChain, prevFrom = Climb.beginBranch(ctx)
			end
			growAxis(ctx, upFrame(bcf.Position, bcf.LookVector), {
				nodes = bNodes,
				internode = opts.internode * 0.7,
				thick = opts.thick * 0.55,
				visible = bVisible,
				salt = opts.salt * 31 + i + 7,
				depth = 1,
				leafScale = opts.leafScale * 0.75,
				flowerScale = opts.flowerScale * 0.8,
				climbBranch = climbBranch,
			})
			if climbBranch then
				profileGeometry(ctx, "PlantClimb", Climb.endBranch, ctx, prevChain, prevFrom)
			end
		end
		pos = nextPos
	end

	if path then
		-- Nothing above the top of the stem gets in a climber's way, so the top
		-- flower's petals can all be stood on, and an open top flower becomes a
		-- platform climbers step up onto. (A climbable side branch's flower is
		-- a platform too; the main stem's line stays, as the main stem goes on
		-- above the branch.)
		if opts.climb then
			ctx.climbLine = nil
		end
		ctx.climbTop = true
		ctx.topPlatform = nil
	end
	if opts.climb and not ctx.crown then
		-- The top of the main climbable stem (see PlantBuilder.crown).
		ctx.crown = upFrame(pos, dir)
	end

	if not opts.noFlower and opts.visible >= opts.nodes - 0.001 then
		buildFlowerCluster(ctx, upFrame(pos, dir), opts.flowerScale)
	end

	if path then
		if opts.climb and not ctx.topPlatform then
			profileGeometry(ctx, "PlantClimb", Climb.landing, ctx, path) -- no open flower to stand on yet
		end
		ctx.climbTop = nil
		ctx.topPlatform = nil
	end
end

----------------------------------------------------------------------------

local function leafLength(genes): number
	return lerp(0.9, 3.6, genes.leafSize)
end

-- Ground hall leaves start at the wall. Allow for their maximum node length
-- (1.15 times the base length), blade width and movement.
function PlantBuilder.groundHallLeafReach(genes): number
	return 1.35 * leafLength(genes)
end

local function plantRng(seed: number)
	return function(salt: number, i: number): Random
		return Random.new((seed + salt * 104729 + i * 7919) % 2147483647)
	end
end

local function makeContext(genome, progress: number, options, model: Model?)
	local g = genome.genes
	local p = math.clamp(progress, 0, 1)
	local seed = options.seed or Genome.hash(genome)
	local detail = options.detail or 1
	local v = Growth.phase(p, Growth.VEGETATIVE)
	local _, tint, tintAmount = Palette.biomeTint(g)
	local function leafy(c: Color3): Color3
		return Palette.tint(c, tint.leaf, tintAmount)
	end
	local function flowery(c: Color3): Color3
		return Palette.tint(c, tint.flower, tintAmount * 0.5) -- flowers keep most of their own colour
	end
	local heat = Element.heat(g) -- 0 water, 0.5 steam, 1 fire
	-- A fire plant (born in the Ember biome) is metal with flames for petals
	-- (Palette.MATERIAL_FIRE); steam plants are only charred.
	local fire = heat >= 1
	local leafColor = Palette.scorch(leafy(Palette.leaf(g.leafHue)), Palette.CHAR_LEAF, heat, 0.8)
	local stemColor = Palette.scorch(leafy(Palette.stem(g.leafHue, g.stemHue)), Palette.CHAR_STEM, heat, 0.85)
	if fire then
		leafColor = Palette.metalLeaf(leafy(Palette.leaf(g.leafHue)))
		stemColor = Palette.metalStem(leafy(Palette.stem(g.leafHue, g.stemHue)))
	end
	return {
		model = model,
		measureParts = model ~= nil and Perf.isObserving(),
		breathe = if model and type(options.breathe) == "function" then options.breathe else nil, -- see part()
		made = 0, -- parts made so far
		genome = genome,
		g = g,
		p = p,
		v = v,
		plantId = options.plantId,
		visualOnly = options.visualOnly == true,
		building = options.building, -- the anchor's Building kind, if any (Furniture picks room purposes by it)
		roomUses = Furniture.parseUses(options.roomUses), -- "0=bedroom,1=kitchen": rooms whose owner picked a purpose
		maxRooms = if type(options.maxRooms) == "number" then math.clamp(math.floor(options.maxRooms), 1, 5) else nil, -- a home's room count (Shared.Housing.Homes)
		roomFurniture = if type(options.roomFurniture) == "table" then options.roomFurniture else nil, -- rooms their owner arranged: room -> pieces (Shared.Housing.RoomFurniture)
		flowers = {},
		joints = {},
		jointOf = {},
		groupOf = {}, -- part -> its union group (a joint, or a stretch of stem); see Smooth
		stemGroup = nil,
		-- Detail 3 (close up) is the high-fidelity build, 1 the normal one,
		-- 0.5 the cheap far one. See Shared.Fidelity for the distances.
		ultra = detail >= 2,
		climb = detail >= 1 and not options.visualOnly and Host.features.climb, -- skip climbing parts for distant scenery
		leafSegments = if detail >= 2 then 9 elseif detail >= 1 then 4 else 2,
		petalSegments = if detail >= 2 then 5 elseif detail >= 1 then 2 else 1,
		stemSegments = STEM_SEGMENTS,
		showAnthers = detail >= 1,
		habitatDetail = detail >= 1,
		maxBranches = if detail >= 1 then 4 else 2,
		thickScale = lerp(0.3, 1, v),
		leafLen = leafLength(g),
		heat = heat,
		flame = fire, -- petals are flames, leaves and stalks metal
		M = if fire then Palette.MATERIAL_FIRE else Palette.MATERIAL,
		reflect = if fire then Palette.REFLECT_FIRE else nil, -- material -> Reflectance
		sepal = if fire then Palette.metalStem(Palette.SEPAL) else Palette.SEPAL, -- the green cup under a flower
		glow = Genome.glow(genome), -- 0, or 0.35..1 for a light plant (Genome.glow)
		colors = {
			leaf = leafColor,
			stem = stemColor,
			petalBase = flowery(Palette.flower(g.flowerHue)),
			petalTip = Palette.scorch(flowery(Palette.flower(g.flowerHue2)), Palette.FLAME_TIP, heat, 0.7),
			center = Palette.scorch(flowery(Palette.flower(g.centerHue)), Palette.FLAME_CORE, heat, 0.9),
		},
		rng = plantRng(seed),
		make = PlantBuilder.make,
	}
end

-- Building plants on a slope: how far (design studs) to lift the whole plant
-- so that none of its rooms dips into the land. Walks the main stem the way
-- growAxis does (same per-node random tilts, rooms straight up), without
-- building anything, and checks the land under each room's footprint
-- (Habitat.groundNeed). Off the land (a pad, a pot, the water) nothing is
-- lifted. Sets ctx.landAt for Habitat (foundation and door ramp). Returns
-- the lift, and whether the plant has a ground hall.
local MAX_LIFT = 4 -- design studs; plantable land is never this steep under a room

local function liftFor(ctx, baseCF: CFrame, rooms: { [number]: number }?, N: number, internode: number, thick: number): (number, boolean)
	if not (rooms and ctx.habitatSwell) then
		return 0, false
	end
	local bp = baseCF.Position
	local ok, h0 = pcall(Ground.heightAt, bp.X, bp.Z)
	if not ok or (bp.Y - h0) / WORLD > OFF_GROUND then
		return 0, false
	end
	-- The land under a design-stud point of the plant (laid out round the
	-- base, scaled up by WORLD about it at the end), in design studs.
	local function landAt(p: Vector3): number
		if ctx.breathe then
			ctx.breathe()
		end
		local h = profileGeometry(ctx, "PlantTerrain", Ground.heightAt, bp.X + (p.X - bp.X) * WORLD, bp.Z + (p.Z - bp.Z) * WORLD)
		return bp.Y + (h - bp.Y) / WORLD
	end
	ctx.landAt = landAt
	local pos, dir = bp, baseCF.UpVector
	local visible = ctx.v * N
	local need, hall = 0, false
	for i = 0, N - 1 do
		local grow = math.clamp(visible - i, 0, 1)
		if grow <= 0 then
			break
		end
		local r = ctx.rng(1, i + 1) -- growAxis's salt 1, node i
		local th = lerp(thick, thick * 0.45, i / N) * ctx.thickScale
		local nextPos, nextDir, room = stemStep(ctx, pos, dir, r, internode * grow, th, rooms[i], grow)
		if room then
			need = math.max(need, Habitat.groundNeed(room, CFrame.new(pos) * ctx.upright.Rotation, landAt))
			hall = hall or room.ground
		end
		pos, dir = nextPos, nextDir
	end
	return math.min(need, MAX_LIFT), hall
end

local function mainStemThickness(g): number
	return lerp(0.2, 0.9, g.stemThickness) * lerp(0.7, 1.2, g.height)
end

local function mainStem(g, building: boolean)
	if g.form < 0.3 and not building then
		return 3, lerp(1.5, 6, g.height) / 3, lerp(0.15, 0.4, g.stemThickness), 2
	end
	local nodes = 3 + math.floor(g.nodes * 9)
	return nodes, lerp(3, 16, g.height) / nodes, mainStemThickness(g), 1
end

-- A conservative upper bound for the circular footprint of the main stem.
PlantBuilder.MAX_STEM_BASE_RADIUS = 0.9 * 1.2 * WORLD / 2

function PlantBuilder.stemBaseRadius(genome: Genome.Genome, progress: number): number
	if progress < Growth.STAGES[2].at then
		return 0
	end
	local genes = genome.genes
	local building = Genome.hasHabitat(genome)
	local _, _, diameter = mainStem(genes, building)
	if genes.form < 0.3 and not building then
		-- The rosette's short leaf-bearing stem is wider than its flower stalk.
		diameter = lerp(0.25, 0.6, genes.stemThickness)
	end
	local scale = lerp(0.3, 1, Growth.phase(progress, Growth.VEGETATIVE))
	return math.max(MIN, diameter * scale) * WORLD / 2
end

-- The mature main stem's tip and base diameter in world studs, without
-- creating parts. A rosette's visible stem is its flower stalk.
function PlantBuilder.matureStem(genome, baseCF: CFrame): (Vector3, number)
	local building = Genome.hasHabitat(genome)
	local ctx = {
		g = genome.genes,
		upright = baseCF,
		habitatSwell = if building then 1 else nil,
		thickScale = 1,
		v = 1,
		rng = plantRng(Genome.hash(genome)),
	}
	local nodes, internode, thick, salt = mainStem(ctx.g, building)
	local rooms = if building then Habitat.plan(ctx.g, nodes, ctx.rng(5153, 0)) else nil
	local lift = liftFor(ctx, baseCF, rooms, nodes, internode, thick)
	local pos, dir = baseCF.Position + Vector3.yAxis * lift, baseCF.UpVector
	for i = 0, nodes - 1 do
		local d = lerp(thick, thick * 0.45, i / nodes)
		pos, dir = stemStep(ctx, pos, dir, ctx.rng(salt, i + 1), internode, d, rooms and rooms[i], 1)
	end
	local diameter = lerp(thick, thick * 0.45, 0.5 / (nodes * STEM_SEGMENTS))
	return baseCF.Position + (pos - baseCF.Position) * WORLD, math.max(MIN, diameter) * WORLD
end

-- The ground hall of a fully grown building plant, in design studs.
function PlantBuilder.groundHall(genes): Habitat.Room
	return Habitat.room(genes, 0, 1, mainStemThickness(genes) / 2)
end

local function run(ctx, baseCF: CFrame)
	local g, p = ctx.g, ctx.p

	if p < Growth.STAGES[2].at then
		ellipsoid(ctx, "Seed", Vector3.new(0.5, 0.35, 0.7), baseCF * CFrame.new(0, 0.15, 0), Palette.SEED, ctx.M.seed)
		return
	end

	local start = baseCF
	ctx.upright = baseCF
	-- Only real builds need the ground (flowerPoints doesn't place leaves).
	if ctx.model then
		ctx.floor = profileGeometry(ctx, "PlantTerrain", makeFloor, baseCF)
	end
	-- Building plants swell some main-stem segments into rooms (Habitat).
	-- The whole plant bends in the wind from the ground; the renderer sways a
	-- building plant more gently and moves each room as one piece.
	ctx.flexBase = 0
	local building = Genome.hasHabitat(ctx.genome)
	if building then
		local hs = Growth.phase(p, Growth.HABITAT)
		if hs > 0 then
			ctx.habitatSwell = hs
		end
	end

	-- The main stem (building plants are never rosettes).
	local N, internode, thick, salt = mainStem(g, building)
	local rooms = if building then Habitat.plan(g, N, ctx.rng(5153, 0), ctx.maxRooms) else nil

	-- On a slope, a building plant is lifted until all its rooms clear the
	-- land. The lifted stretch doesn't sway (FlexBase): a ground hall stands
	-- on a foundation (Habitat.build); otherwise the stem simply carries on
	-- down into the soil, and can be climbed from the ground.
	local lift, hall = profileGeometry(ctx, "PlantTerrain", liftFor, ctx, baseCF, rooms, N, internode, thick)
	ctx.groundLift = lift
	if ctx.liftOnly then
		return
	end
	if lift > 0 then
		start = baseCF + Vector3.new(0, lift, 0)
		ctx.flexBase = lift
		if not hall and ctx.model then
			local d = thick * ctx.thickScale
			local foot = baseCF.Position - Vector3.new(0, Habitat.FOUNDATION_SINK, 0)
			cylinderBetween(ctx, "Stem", foot, start.Position, d, Palette.shade(ctx.colors.stem, -0.35), ctx.M.stem)
			if ctx.climb then
				profileGeometry(ctx, "PlantClimb", Climb.stemPiece, ctx, baseCF.Position, start.Position, d)
			end
		end
	end

	-- Close up, upright plants flare into a few surface roots where they meet the soil.
	if ctx.ultra and g.form >= 0.3 and ctx.v > 0.2 and not Genome.hasHabitat(ctx.genome) then
		local rootD = thick * ctx.thickScale * 0.5
		local rr = ctx.rng(4049, 0)
		local count = 5
		for i = 1, count do
			local az = i / count * TAU + rr:NextNumber(-0.3, 0.3)
			local outDir = Vector3.new(math.cos(az), 0, math.sin(az))
			local top = (start * CFrame.new(outDir * rootD * 0.3 + Vector3.new(0, rootD * 1.2, 0))).Position
			local foot = (start * CFrame.new(outDir * rootD * rr:NextNumber(2.2, 3.4) + Vector3.new(0, -rootD * 0.3, 0))).Position
			cylinderBetween(ctx, "Root", top, foot, rootD * 0.7, Palette.shade(ctx.colors.stem, -0.4), ctx.M.stem)
			ball(ctx, "Root", rootD * 0.55, foot, Palette.shade(ctx.colors.stem, -0.45), ctx.M.stem)
		end
	end

	-- Seed leaves (cotyledons) on a short shoot; they wither as true leaves take over.
	local c = 1 - Growth.phase(p, { 0.3, 0.5 })
	if c > 0 then
		local sprout = Growth.phase(p, { 0.04, 0.12 })
		local top = start * CFrame.new(0, 0.1 + 0.3 * sprout, 0)
		cylinderBetween(ctx, "Shoot", start.Position, top.Position, 0.14, ctx.colors.stem, ctx.M.stem)
		for k = 0, 1 do
			local lcf = top * CFrame.Angles(0, k * math.pi + 0.7, 0) * CFrame.Angles(0.35, 0, 0)
			local size = (0.25 + 0.75 * sprout) * c
			ellipsoid(ctx, "Cotyledon", Vector3.new(0.5, 0.07, 0.65) * size, lcf * CFrame.new(0, 0, -0.32 * size), Palette.shade(ctx.colors.leaf, 0.15), ctx.M.leaf)
		end
	end

	if g.form < 0.3 and not building then
		-- Rosette: a ground-hugging spiral of leaves, then a bare flower stalk.
		profileGeometry(ctx, "PlantClimb", Climb.setLine, ctx, start.Position, start.UpVector, thick * ctx.thickScale)
		local leafNodes = 6 + math.floor(g.nodes * 14)
		growAxis(ctx, start, {
			nodes = leafNodes,
			internode = 0.06,
			thick = lerp(0.25, 0.6, g.stemThickness),
			visible = ctx.v * leafNodes,
			salt = 1,
			depth = 1,
			leafScale = 1.35,
			leafLift = 0.45,
			flowerScale = 1,
			noFlower = true,
		})
		growAxis(ctx, start, {
			nodes = N,
			internode = internode,
			thick = thick,
			visible = Growth.phase(p, { 0.4, 0.6 }) * N,
			salt = salt,
			depth = 1,
			leafScale = 0,
			flowerScale = 1,
			noLeaves = true,
			climb = true,
		})
	else
		profileGeometry(ctx, "PlantClimb", Climb.setLine, ctx, start.Position, start.UpVector, thick * ctx.thickScale)
		growAxis(ctx, start, {
			rooms = rooms,
			nodes = N,
			internode = internode,
			thick = thick,
			visible = ctx.v * N,
			salt = salt,
			depth = 0,
			leafScale = 1,
			flowerScale = 1,
			climb = true,
		})
	end
end

-- Flower frames are built in design studs around the base; stretch their
-- offsets from the base by WORLD to match the scaled-up model.
local function toWorld(flowers: { any }, base: CFrame)
	if WORLD == 1 then
		return
	end
	for _, f in flowers do
		local rel = base:ToObjectSpace(f.cframe)
		f.cframe = base * CFrame.new(rel.Position * WORLD) * rel.Rotation
	end
end

function PlantBuilder.build(genome, progress: number, baseCFrame: CFrame, options: { [string]: any }?): (Model, { any })
	local opts = options or {}
	local model = Instance.new("Model")
	model.Name = opts.name or "Plant"
	local ctx = makeContext(genome, progress, opts, model)
	local breathe = ctx.breathe
	if breathe then
		-- Built over several frames: unions and room shells queued along the
		-- way must not start on the half-built model (Smooth.hold). The
		-- caller releases it once the model is where it belongs.
		Smooth.hold(model)
		local started = os.clock()
		local mark: ((string, boolean?) -> string)? = nil
		local other = "PlantGeometryOther"
		if Perf.isObserving() then
			local current = other
			local phaseStarted = started
			local suffix = ("[detail=%s,habitat=%s]"):format(tostring(opts.detail or 1), tostring(Genome.hasHabitat(genome)))
			local labels: { [string]: string } = {}
			mark = function(nextLabel: string, skipElapsed: boolean?): string
				local label = labels[current]
				if not label then
					label = current .. suffix
					labels[current] = label
				end
				if not skipElapsed then
					Perf.measure(label, phaseStarted)
				end
				local previous = current
				current = nextLabel
				phaseStarted = os.clock()
				return previous
			end
			ctx.geometryMark = mark
		end
		ctx.breathe = function()
			local phase = if mark then mark(other) else other
			Perf.measure("PlantGeometry", started)
			breathe()
			if mark then
				-- Reset the phase clock after the wait without charging the gap.
				mark(phase, true)
			end
			started = os.clock()
		end
		local ok, err = pcall(run, ctx, baseCFrame)
		if mark then
			mark(other)
		end
		Perf.measure("PlantGeometry", started)
		ctx.geometryMark = nil
		ctx.breathe = breathe
		if not ok then
			Smooth.release(model)
			model:Destroy()
			error(err, 0)
		end
		breathe()
	else
		run(ctx, baseCFrame)
	end
	model.WorldPivot = baseCFrame
	if WORLD ~= 1 and #model:GetChildren() > 0 then
		local started = os.clock()
		model:ScaleTo(WORLD)
		Perf.measure("PlantScale", started)
	end
	if breathe then
		breathe()
	end
	local finalizeStarted = os.clock()
	toWorld(ctx.flowers, baseCFrame)
	-- Joints were laid out in design studs too.
	for _, j in ctx.joints do
		local rel = baseCFrame:ToObjectSpace(j.cframe)
		j.cframe = baseCFrame * CFrame.new(rel.Position * WORLD) * rel.Rotation
	end
	jointsOf[model] = { joints = ctx.joints, jointOf = ctx.jointOf }
	model:SetAttribute("Genome", Genome.encode(genome))
	model:SetAttribute("Progress", ctx.p)
	model:SetAttribute("Stage", Growth.stage(ctx.p))
	model:SetAttribute("HasHabitat", Genome.hasHabitat(genome))
	if ctx.heat > 0 then
		model:SetAttribute("Element", Element.of(genome)) -- "fire" or "steam": the client adds flames or steam (PlantFire)
	end
	if ctx.glow > 0 then
		model:SetAttribute("Glow", ctx.glow) -- a light plant: the client lights its flowers (LightPlants)
	end
	model:SetAttribute("FlexBase", (ctx.flexBase or 0) * WORLD)
	if opts.plantId then
		model:SetAttribute("PlantId", opts.plantId)
	end
	if not opts.visualOnly then
		CollectionService:AddTag(model, PlantBuilder.MODEL_TAG)
	end
	Perf.measure("PlantFinalize", finalizeStarted)
	if opts.smooth then
		if breathe then
			breathe()
		end
		local started = os.clock()
		local checkpoint = if breathe then function()
			Perf.measure("PlantSmoothPrep", started)
			breathe()
			started = os.clock()
		end else nil
		local groups = PlantBuilder.smoothGroups(ctx, checkpoint)
		Perf.measure("PlantSmoothPrep", started)
		if breathe then
			breathe()
		end
		started = os.clock()
		Smooth.queue(model, groups)
		Perf.measure("PlantSmoothQueue", started)
	end
	return model, ctx.flowers
end

-- The groups of pieces that can union into one smooth surface: the plain
-- geometry of each organ that swings at its own joint, and of each stretch
-- of stem. Left out: sphere-meshed overlays (veins, collars; a union would
-- turn them into boxes), invisible or solid pieces (Climb footholds), the
-- flower centre (insects find it by its tag) and building rooms (Habitat
-- smooths those itself).
function PlantBuilder.smoothGroups(ctx, checkpoint: (() -> ())?): { { BasePart } }
	local byGroup = {}
	local order = {}
	local checked = 0
	for p, group in ctx.groupOf do
		if checkpoint then
			checked += 1
			if checked % 32 == 0 then
				checkpoint()
			end
		end
		if p.Parent and p.Transparency == 0 and not p.CanCollide and not p.CanQuery
			and not p:FindFirstChildWhichIsA("DataModelMesh")
			and not CollectionService:HasTag(p, PlantBuilder.FLOWER_TAG)
			and string.sub(p.Name, 1, 7) ~= "Habitat"
		then
			local list = byGroup[group]
			if not list then
				list = {}
				byGroup[group] = list
				table.insert(order, list)
			end
			table.insert(list, p)
		end
	end
	local groups = {}
	for _, list in order do
		if #list >= 2 then
			table.insert(groups, list)
		end
	end
	return groups
end

function PlantBuilder.joints(model: Model)
	return jointsOf[model]
end

-- How far (world studs) a building plant is lifted to keep its rooms out of
-- the land on a slope (0 for other plants, or on flat land). The server uses
-- it to place people on a lifted ground hall's floor.
function PlantBuilder.groundLift(genome, progress: number, baseCFrame: CFrame, options: { [string]: any }?): number
	local ctx = makeContext(genome, progress, options or {}, nil)
	ctx.liftOnly = true
	run(ctx, baseCFrame)
	return (ctx.groundLift or 0) * WORLD
end

-- Where the open flowers are, without building any parts (for server-side insects etc.).
function PlantBuilder.flowerPoints(genome, progress: number, baseCFrame: CFrame): { any }
	local ctx = makeContext(genome, progress, {}, nil)
	run(ctx, baseCFrame)
	toWorld(ctx.flowers, baseCFrame)
	return ctx.flowers
end

-- The top of the plant's main stem in world studs, where a climber comes out
-- (on its open flower, if it has one), and the open flowers, without building
-- any parts. The crown is nil for a plant too young to have a stem yet.
function PlantBuilder.crown(genome, progress: number, baseCFrame: CFrame): (Vector3?, { any })
	local ctx = makeContext(genome, progress, {}, nil)
	run(ctx, baseCFrame)
	toWorld(ctx.flowers, baseCFrame)
	local crown: Vector3? = nil
	if ctx.crown then
		local rel = baseCFrame:PointToObjectSpace(ctx.crown.Position)
		crown = baseCFrame:PointToWorldSpace(rel * WORLD)
	end
	return crown, ctx.flowers
end

--[[
	A kit of the builder's own organs, for building something plant-like
	that isn't a grown plant (the walking plant avatar, Client/PlantAvatar):
	stems, leaves, flowers and blades drawn exactly as a plant's are, at the
	given detail (3 is the close-up, high-fidelity build), wherever the caller
	puts them. Everything is in design studs and anchored in kit.model; no
	climbing pieces, no ground clearance, no tags.

	  local kit = PlantBuilder.kit(genome, { detail = 3 })
	  kit.stem(a, ctrl, b, thickA, thickB, { node = true })
	  kit.leaf(cf, length)        -- cf: base, LookVector along the leaf, UpVector its face
	  kit.flower(cf, scale)       -- cf: UpVector is the way the flower faces
	  kit.blade(name, cf, len, segs, thick, widthAt, colorAt, material, bendAt)
	  kit.ball / kit.ellipsoid / kit.cylinder(a, b, d, color, material)
	  kit.mark(tag)               -- parts made from now on get kit.tagOf[part] = tag
]]
function PlantBuilder.kit(genome, options: { [string]: any }?)
	local opts = table.clone(options or {})
	opts.visualOnly = true
	local model = Instance.new("Model")
	model.Name = opts.name or "PlantKit"
	local ctx = makeContext(genome, 1, opts, model)
	ctx.climb = false
	ctx.floor = nil
	local kit = { model = model, ctx = ctx, colors = ctx.colors, M = ctx.M, sepal = ctx.sepal, tagOf = {} }
	local tag: any = nil
	local before: { [Instance]: boolean } = {}
	-- Tag every part made since the last mark with the tag then current.
	local function sweep()
		for _, p in model:GetChildren() do
			if not before[p] then
				before[p] = true
				if tag ~= nil then
					kit.tagOf[p] = tag
				end
			end
		end
	end
	function kit.mark(newTag: any)
		sweep()
		tag = newTag
	end
	function kit.done(): Model
		sweep()
		return model
	end
	function kit.stem(a: Vector3, ctrl: Vector3, b: Vector3, thickA: number, thickB: number, o: { [string]: any }?)
		local so = o or {}
		local color = so.color or Palette.shade(ctx.colors.stem, so.shade or 0)
		local n = so.segments or ctx.stemSegments
		local last = a
		for sIdx = 1, n do
			local u = sIdx / n
			local q = a * (1 - u) ^ 2 + ctrl * 2 * u * (1 - u) + b * u * u
			local d = lerp(thickA, thickB, (sIdx - 0.5) / n)
			cylinderBetween(ctx, "Stem", last, q, d, Palette.shade(color, 0.08 * (u - 0.5)), ctx.M.stem, false)
			if sIdx < n or so.roundEnd then
				ball(ctx, "Stem", d, q, Palette.shade(color, 0.08 * (u - 0.5)), ctx.M.stem)
			end
			last = q
		end
		if so.node then
			local dir = (b - ctrl).Unit
			local thick = thickB
			if ctx.ultra then
				ellipsoid(ctx, "Node", Vector3.new(thick * 1.3, thick * 0.45, thick * 1.3), upFrame(b, dir), Palette.shade(color, -0.15), ctx.M.joint)
				for _, side in { -1, 1 } do
					local scf = upFrame(b, dir) * CFrame.Angles(0, (so.az or 0) + math.pi / 2 + side * 0.5, 0) * CFrame.Angles(0.9, 0, 0)
					local sl = math.max(0.12, thick * 0.9)
					ellipsoid(ctx, "Sepal", Vector3.new(sl * 0.5, 0.05, sl), scf * CFrame.new(0, 0, -thick * 0.5 - sl * 0.4), Palette.shade(ctx.colors.leaf, 0.1), ctx.M.leaf)
				end
			end
			ball(ctx, "Node", thick * 1.12, b, Palette.shade(color, 0.05), ctx.M.joint)
		end
	end
	function kit.leaf(cf: CFrame, length: number, maturity: number?, nodeT: number?)
		buildLeaf(ctx, cf, length, maturity or 1, nodeT or 0.5)
	end
	-- A leaf at a stem node, set the way growAxis sets one: round the stem
	-- by az, lifted by elev, starting at the stem's surface.
	function kit.nodeLeaf(nodePos: Vector3, dir: Vector3, az: number, elev: number, thick: number, length: number)
		local lcf = upFrame(nodePos, dir) * CFrame.Angles(0, az, 0) * CFrame.Angles(elev, 0, 0) * CFrame.new(0, 0, -thick * 0.4)
		buildLeaf(ctx, lcf, length, 1, 0.5)
	end
	function kit.flower(cf: CFrame, scale: number?)
		buildFlower(ctx, cf, scale or 1)
	end
	function kit.blade(name: string, cf: CFrame, len: number, segs: number, thick: number, widthAt, colorAt, material, bendAt)
		return blade(ctx, name, cf, len, segs, thick, widthAt, colorAt, material or ctx.M.leaf, bendAt)
	end
	function kit.ball(name: string, d: number, pos: Vector3, color: Color3, material: Enum.Material?)
		return ball(ctx, name, d, pos, color, material or ctx.M.joint)
	end
	function kit.ellipsoid(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?)
		return ellipsoid(ctx, name, size, cf, color, material or ctx.M.joint)
	end
	function kit.cylinder(name: string, a: Vector3, b: Vector3, d: number, color: Color3, material: Enum.Material?)
		return cylinderBetween(ctx, name, a, b, d, color, material or ctx.M.stem, false)
	end
	function kit.part(name: string, shape: Enum.PartType, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?)
		return part(ctx, name, shape, size, cf, color, material or ctx.M.joint, false)
	end
	kit.upFrame = upFrame
	kit.look = look
	kit.flowerSize = function(scale: number?): number
		return lerp(0.6, 2.8, ctx.g.flowerSize) * (scale or 1)
	end
	return kit
end

return PlantBuilder
