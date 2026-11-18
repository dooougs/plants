--[[
	Climb: makes ordinary plants climbable for the shrunken (1/10 size) players.

	  * Every upright stem (and every rosette's flower stalk) climbs like a
	    ladder: walk into it and you grab on, then forward/back climbs up and
	    down, left/right goes round, and jump lets go. At the top you pull
	    yourself up onto the open flower, which is a platform you can walk
	    about on; "Climb down" there puts you back on the stem. (A stem with
	    no open flower yet ends in a small landing instead.) PlantClimb (client) does the
	    climbing; this module builds the invisible "ClimbStem" pieces it holds.
	  * Leaves, open petals and sturdy side branches become things you can
	    stand on, so from the stem you can step out onto a leaf or into a flower.
	  * Close round a stem nothing but the stem itself is solid, so climbers
	    don't snag on leaves or branches.

	What you stand on or hold is a separate invisible part laid along the
	visible stem, leaf or petal. That keeps collisions simple and flat, and
	keeps the camera from popping in every time a leaf passes behind you (the
	default camera ignores invisible parts).

	These parts are built inside the plant model, so they sway with the plant;
	climbers ride the sway, PlantRenderer carries a player along with the
	foothold they stand on, and a plant sways more gently while someone is on it.

	Everything is sized for players at Scale.PLAYER.
]]

local Climb = {}

Climb.FOOTHOLD = "Foothold"
Climb.STEM = "ClimbStem"
Climb.FLOWER_TOP = "FlowerTop"
Climb.CLEAR = 0.45 -- room kept free round a climbable stem's surface
Climb.MIN_FOOT_WIDTH = 0.3 -- narrower leaves and petals aren't solid
Climb.MAX_SLOPE_COS = math.cos(math.rad(50)) -- steeper than this isn't solid
Climb.CALM = 0.3 -- sway multiplier while someone is climbing the plant

-- Climbing (PlantClimb, client)
Climb.SPEED = 2.4 -- studs per second up and down a stem
Climb.AROUND_SPEED = 2.5 -- radians per second round a stem
Climb.GRAB_REACH = 0.3 -- how close to the stem's surface you grab it
Climb.HOLD_OFFSET = 0.12 -- climber's centre, out from the stem's surface
Climb.MANTLE_TIME = 0.4 -- seconds to pull up onto (or lower off) a flower top

-- An invisible flat part you can stand on. Returns nil on dry runs and at
-- low detail (far away plants nobody here is standing on).
function Climb.foothold(ctx, size: Vector3, cf: CFrame): BasePart?
	if not ctx.model or not ctx.climb then
		return nil
	end
	local p = ctx.make.part(ctx, Climb.FOOTHOLD, Enum.PartType.Block, size, cf, Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, true)
	if p then
		p.Transparency = 1
		p.CastShadow = false
	end
	return p
end

-- Same, for a round part (the stem and the top landing).
local function solidCylinder(ctx, name: string, a: Vector3, b: Vector3, diameter: number): BasePart?
	if not ctx.model or not ctx.climb then
		return nil
	end
	local p = ctx.make.cylinderBetween(ctx, name, a, b, diameter, Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, true)
	if p then
		p.Transparency = 1
		p.CastShadow = false
	end
	return p
end

-- One piece of a climbable stem, from a (lower) to b (higher). Its +X axis
-- points up the stem. Pieces are numbered from the soil up (ClimbIndex) so
-- the climbing controller can move from one to the next.
--
-- The main stem is chain 0 (no ClimbChain attribute). Each side branch off
-- it is its own chain (ClimbChain 1, 2, ...), numbered from where it leaves
-- the main stem out to its tip, and remembers the main stem piece it leaves
-- from (ClimbFrom). Climbing up past a branch on its side moves you onto it.
function Climb.stemPiece(ctx, a: Vector3, b: Vector3, diameter: number)
	local p = solidCylinder(ctx, Climb.STEM, a, b, math.max(diameter, 0.1))
	if p then
		local chain = ctx.climbChain or 0
		ctx.climbCounts = ctx.climbCounts or {}
		local index = (ctx.climbCounts[chain] or 0) + 1
		ctx.climbCounts[chain] = index
		p:SetAttribute("ClimbIndex", index)
		if chain ~= 0 then
			p:SetAttribute("ClimbChain", chain)
			p:SetAttribute("ClimbFrom", ctx.climbFrom or 0)
		end
	end
end

-- Start a side branch's climbing chain (call before building the branch,
-- then Climb.endBranch with what this returns).
function Climb.beginBranch(ctx): (number?, number?)
	local chain, from = ctx.climbChain, ctx.climbFrom
	ctx.climbChains = (ctx.climbChains or 0) + 1
	ctx.climbChain = ctx.climbChains
	ctx.climbFrom = ctx.climbCounts and ctx.climbCounts[0] or 0
	return chain, from
end

function Climb.endBranch(ctx, chain: number?, from: number?)
	ctx.climbChain, ctx.climbFrom = chain, from
end

-- Room kept free around a climbable stem (from its axis), so a climber
-- doesn't get snagged on solid leaves or branches.
function Climb.clearRadius(stemDiameter: number): number
	return stemDiameter / 2 + Climb.CLEAR
end

-- The stem being climbed, near the part being built: its axis line and the
-- radius around it that must stay free.
function Climb.setLine(ctx, pos: Vector3, dir: Vector3, stemDiameter: number)
	ctx.climbLine = { pos = pos, dir = dir, clear = Climb.clearRadius(stemDiameter) }
end

-- True if a part centred here, reaching `extent` studs from its centre, may be
-- solid: clear of the climbed stem and flat enough to stand on.
function Climb.canStand(ctx, cf: CFrame, extent: number): boolean
	if not ctx.climb or cf.UpVector.Y < Climb.MAX_SLOPE_COS then
		return false
	end
	local line = ctx.climbLine
	if not line then
		return true
	end
	local rel = cf.Position - line.pos
	local along = rel:Dot(line.dir)
	local perp = (rel - line.dir * along).Magnitude
	return perp - extent >= line.clear
end

-- A foothold under a leaf or petal segment, if it's wide, flat and clear enough.
-- `cf` is the segment's centre, `width`/`length`/`thick` its visible size.
function Climb.leafFoothold(ctx, cf: CFrame, width: number, length: number, thick: number)
	if width < Climb.MIN_FOOT_WIDTH then
		return
	end
	local size = Vector3.new(width * 0.75, 0.05, length)
	if Climb.canStand(ctx, cf, math.max(size.X, size.Z) / 2) then
		Climb.foothold(ctx, size, cf * CFrame.new(0, thick * 0.5 - 0.025, 0))
	end
end

-- A walkway along the top of a side branch running from a to b.
function Climb.branchFoothold(ctx, a: Vector3, b: Vector3, diameter: number)
	local len = (b - a).Magnitude
	if diameter < 0.2 or len < 0.1 then
		return
	end
	-- In short pieces, so the part of a branch clear of the stem is solid even
	-- where its base (next to the stem) isn't.
	local pieces = math.max(1, math.ceil(len / 0.6))
	local piece = len / pieces
	for k = 1, pieces do
		local p0, p1 = a:Lerp(b, (k - 1) / pieces), a:Lerp(b, k / pieces)
		local cf = CFrame.lookAt((p0 + p1) / 2, p1, Vector3.yAxis)
		if Climb.canStand(ctx, cf, piece / 2) then
			Climb.foothold(ctx, Vector3.new(math.max(diameter * 0.8, 0.22), 0.05, piece + 0.05), cf * CFrame.new(0, diameter * 0.5 - 0.025, 0))
		end
	end
end

-- A small invisible landing on top of the stem, under the top flower, for
-- climbers to step off onto. `path` is the stem's centreline as { pos, d }.
function Climb.landing(ctx, path)
	if #path < 2 then
		return
	end
	local tip = path[#path]
	local dir = tip.pos - path[#path - 1].pos
	dir = if dir.Magnitude > 1e-4 then dir.Unit else Vector3.yAxis
	solidCylinder(ctx, Climb.FOOTHOLD, tip.pos - dir * 0.08, tip.pos, tip.d + 0.8)
end

-- The top flower as a platform: an invisible flat disc across the open
-- petals (`height` up the head's frame `cf`, `radius` wide) and an invisible
-- dome matching the pollen centre, so you can walk about on the flower and
-- climb onto its centre. Both are named FLOWER_TOP; PlantClimb puts climbers
-- onto the disc at the top of the stem and offers "Climb down" on it.
function Climb.flowerTop(ctx, cf: CFrame, height: number, radius: number, centreCF: CFrame, centreD: number)
	if not ctx.model or not ctx.climb then
		return
	end
	local disc = solidCylinder(ctx, Climb.FLOWER_TOP, (cf * CFrame.new(0, height - 0.06, 0)).Position, (cf * CFrame.new(0, height, 0)).Position, radius * 2)
	if disc then
		ctx.topPlatform = true
		if ctx.climbChain and ctx.climbChain ~= 0 then
			disc:SetAttribute("ClimbChain", ctx.climbChain) -- the flower at a side branch's tip
		end
	end
	local dome = ctx.make.part(ctx, Climb.FLOWER_TOP, Enum.PartType.Ball, Vector3.one * centreD, centreCF, Color3.new(1, 1, 1), Enum.Material.SmoothPlastic, true)
	if dome then
		dome.Transparency = 1
		dome.CastShadow = false
		if ctx.climbChain and ctx.climbChain ~= 0 then
			dome:SetAttribute("ClimbChain", ctx.climbChain)
		end
	end
end

return Climb
