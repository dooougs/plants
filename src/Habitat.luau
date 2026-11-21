--[[
	Habitat: the rare "living building" trait.

	Plants whose habitat gene is at or above Genome.HABITAT_THRESHOLD grow
	rooms in their main stem. A few of the stem's segments swell into hollow
	rooms: rounded boxes (flat walls, floor and roof, every edge and corner
	rounded off) that are part of the stem itself. Between rooms there can be
	ordinary stem segments, and leaves and side branches sprout from a room's
	roof just as they would from any other node. The rooms are the stem's own
	colour and material, and where the stem goes in and comes out they flare
	into it in a collar whose profile is a quadratic Bezier curve.

	  - Some plants start with a ground hall: the first segment is a room
	    standing on the soil, with a doorway and a ramp up to its floor. The
	    Market Bloom always has one.
	  - Higher rooms are reached by climbing the stem (Climb): it runs up
	    through a hole in each room's floor and roof, so you climb in from
	    below, step off onto the floor, and climb on out through the roof.
	    Each room has windows and a door onto a leaf balcony.

	Every room measurement is written in normal Roblox studs times UNIT, so
	rooms come out the right size for the players (see UNIT). Parts are all
	named "Habitat..." and the stem below the highest room doesn't sway.

	Inside a room the stem slims to about a player's width (INNER_STEM), so
	there's floor space round it: it narrows in a smooth flare just above the
	floor (most of it hidden in the room's belly) and swells back out to full
	thickness in a flare into the ceiling. Habitat.stemRadius and stemProfile
	give that shape; PlantBuilder draws the stem and its climbable pieces from
	them, and the floor's climbing hole fits the slim stem.

	PlantBuilder calls:
	  Habitat.plan(genes, segments, rng) -> { [segment index] = room number }
	  Habitat.room(genes, number, swell, stemRadius, size?) -> Room (its size)
	  Habitat.build(ctx, bottomCFrame, room, stemRadiusBelow, stemRadiusAbove)
	Habitat.size(genes, swell) -> (hall half-width, hall height)   (used by the Market)
]]

local CollectionService = game:GetService("CollectionService")

local Palette = require(script.Parent.Palette)
local Climb = require(script.Parent.Climb)
local Furniture = require(script.Parent.Furniture)
local Smooth = require(script.Parent.Smooth)
local RoomLamps = require(script.Parent.RoomLamps)
local Host = require(script.Parent.Host)
local Scale = { PLAYER = Host.playerScale() }

local Habitat = {}

-- Rooms are sized for the players who live in them. Players are Scale.PLAYER
-- of normal size, so every room measurement below is written in normal
-- Roblox studs (a door 7.5 tall, a hall 20 to 32 wide) and multiplied by
-- UNIT: a doorway is 0.75 studs tall, a tenth of the usual.
Habitat.UNIT = Scale.PLAYER

Habitat.FLOOR_TAG = "PlantHabitat"
Habitat.ROOM_TAG = "PlantHabitatRoom"
Habitat.SHELL_NAME = "HabitatShell" -- the smooth solid-geometry shell (see smoothen)
Habitat.PANE_NAME = "HabitatPane" -- invisible, in each doorway and window, for RoomFade
Habitat.VOLUME_NAME = "HabitatVolume" -- invisible box filling each room, for RoomFade
Habitat.ROOM_TAG = "HabitatRoom" -- CollectionService tag on each room's volume
Habitat.DOOR_HEIGHT = 7.5 * Habitat.UNIT -- ground hall doorway, at most
Habitat.FLOOR_TOP = 0.6 * Habitat.UNIT -- top of the ground hall floor
Habitat.DOOR_RAMP_SLOPE = math.rad(14) -- up from the soil to the hall floor
Habitat.GROUND_HALL_CHANCE = 0.3 -- share of building plants with a ground hall
Habitat.MAX_GAP = 2 -- at most this many ordinary segments between rooms

-- Inside a room the stem slims to about a player's width, so the floor is
-- free for furniture, and flares back out to full thickness under the floor
-- and into the ceiling. All in normal studs (times UNIT, like the rooms).
Habitat.INNER_STEM = 1.1 -- radius of the stem inside a room
Habitat.FLARE = 2.5 -- height of the flare above the floor and below the ceiling
Habitat.HOLE_CLEAR = 3 -- room round the slim stem in a floor's climbing hole

-- Rebuild each room as one smooth solid-geometry shell on the client. The original blocks
-- stay as invisible colliders. Turned off automatically if this Roblox build
-- can't do it.
Habitat.UNION = true
Habitat.SMOOTHING_ANGLE = 45 -- degrees: facets closer than this shade as one smooth surface

local TAU = math.pi * 2
local HALF_PI = math.pi / 2
local M = Palette.MATERIAL

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Ground hall size in studs (half-width, height). The Market fits its
-- furniture to it.
function Habitat.size(g, swell: number): (number, number)
	local R = lerp(10, 16, g.stemThickness) * Habitat.UNIT * swell
	local Hc = R * lerp(1.1, 1.5, g.height)
	return R, Hc
end

-- Which of the main stem's segments are rooms. Room 0 is a ground hall
-- (segment 0); rooms 1, 2, 3 sit higher up with 0 to MAX_GAP ordinary
-- segments between them. The last segment is always ordinary stem, so the
-- flower has something to grow on.
--
-- maxRooms (homes, Shared.Housing.Homes) sets the number of rooms instead,
-- ground hall included, packed closer so up to five fit. A home that grows
-- a room keeps its other rooms where they were.
function Habitat.plan(g, segments: number, rng: Random, maxRooms: number?): { [number]: number }
	local plan = {}
	local i
	if maxRooms or g.habitat >= 0.99 or rng:NextNumber() < Habitat.GROUND_HALL_CHANCE then
		plan[0] = 0
		i = 1 + rng:NextInteger(0, 1)
	else
		i = rng:NextInteger(1, 2)
	end
	local count = if maxRooms then math.max(0, maxRooms - 1) else 1 + math.floor(g.nodes * 2.99) -- 1 to 3 rooms above the ground
	local maxGap = if maxRooms then 1 else Habitat.MAX_GAP
	local number = 1
	while count > 0 and i <= segments - 2 do
		plan[i] = number
		number += 1
		count -= 1
		i += 1 + rng:NextInteger(0, maxGap)
	end
	return plan
end

export type Room = {
	number: number, -- 0 is the ground hall
	ground: boolean, -- stands on the soil, with an open bottom
	floorY: number, -- top of the floor you stand on (all heights from the segment's bottom)
	height: number, -- floor to ceiling
	total: number, -- length of the stem segment the room fills
	doorAz: number, -- the room is turned so its door wall faces this way
	halfX: number, -- outer half-size along the door direction
	halfZ: number, -- outer half-size across it
	radius: number, -- the larger of the two
	round: number, -- radius of the rounded edges and corners
	coreLo: number, -- the flat walls run from coreLo to coreHi
	coreHi: number,
	topY: number, -- roof
	wall: number,
	hole: number, -- radius of the round hole the full stem (and a climber) goes through: roof and underside
	stemR: number, -- radius of the stem where it comes in at the bottom
	slim: number, -- radius of the slim stem inside the room
	flare: number, -- height of the flares above the floor and below the ceiling
	floorHole: number, -- radius of the round hole in the floor round the slim stem
	keepClear: number, -- furniture stays this far from the stem's axis (before its own margin)
	unit: number, -- one normal stud, at this growth
	doorHeight: number,
	doorHalf: number,
	windowHalf: number,
	windowLo: number,
	windowHi: number,
}

-- The size of room `number` at growth `swell`, round a stem of radius stemR.
-- size (default 1) scales the room's floor and height, not its walls, doors
-- or windows: a bigger plant can carry a bigger room (PlantSynth.Layout).
function Habitat.room(g, number: number, swell: number, stemR: number, size: number?): Room
	local k = size or 1
	local s = math.max(swell, 0.05)
	local u = s * Habitat.UNIT
	local wall = 0.6 * u
	local hole = stemR + Climb.CLEAR * s -- the full stem, plus room for someone climbing it (roof and underside)
	local minHalf = (hole + 3 * u) / 0.7 -- keeps the hole inside the flat roof
	local doorAz = -math.pi / 2 + number * 2.1 -- room 0's door faces the base's look direction
	local ground = number == 0
	local slim = math.min(stemR, Habitat.INNER_STEM * u)
	local halfX, halfZ, round, floorY, coreLo, top, h, doorHeight, doorHalf, windowHalf
	if ground then
		local R, Hc = Habitat.size(g, s)
		R *= k
		Hc *= k
		halfX = math.max(R, minHalf)
		halfZ = halfX
		top = math.max(Hc * 0.8, 12 * u)
		round = math.min(halfX * 0.3, top * 0.35)
		floorY = Habitat.FLOOR_TOP
		coreLo = 0
		h = top - wall - floorY
		doorHeight = math.min(Habitat.DOOR_HEIGHT, top * 0.6)
		doorHalf = halfX * math.sin(math.min(0.45, 4.5 * u / halfX))
		windowHalf = halfX * 0.18
	else
		local f = math.max(0.7, 1 - 0.06 * (number - 1))
		h = lerp(11, 15, g.height) * u * f * k
		halfX = math.max(lerp(12, 16, g.stemThickness) * u * f * k, minHalf)
		halfZ = math.max(halfX * lerp(0.85, 1, g.leafLength), minHalf)
		round = math.min(halfX, halfZ) * 0.3
		-- The floor sits where the walls stop curving in, over a rounded belly.
		floorY = round
		coreLo = round
		top = floorY + h + wall
		doorHeight = h * 0.6
		doorHalf = 2 * u
		windowHalf = 2.2 * u
	end
	local room = {
		number = number,
		ground = ground,
		floorY = floorY,
		height = h,
		total = top,
		doorAz = doorAz,
		halfX = halfX,
		halfZ = halfZ,
		radius = math.max(halfX, halfZ),
		round = round,
		coreLo = coreLo,
		coreHi = top - round,
		topY = top,
		wall = wall,
		hole = hole,
		stemR = stemR,
		slim = slim,
		flare = math.min(Habitat.FLARE * u, h * 0.25),
		floorHole = 0,
		keepClear = 0,
		unit = u,
		doorHeight = doorHeight,
		doorHalf = math.min(doorHalf, halfZ - round - u),
		windowHalf = math.min(windowHalf, math.min(halfX, halfZ) - round - u),
		windowLo = floorY + h * 0.3,
		windowHi = floorY + h * 0.72,
	}
	-- The floor's hole fits the stem where it passes through the floor slab
	-- (just above the slab it is already nearly slim), plus, above the ground,
	-- room for a climber.
	local floorT = if ground then Habitat.FLOOR_TOP else 0.6 * u
	local through = Habitat.stemRadius(room, math.max(floorY - floorT, 0), stemR)
	room.floorHole = if ground then through else math.min(through + Habitat.HOLE_CLEAR * u, hole)
	-- In the ground hall there's no hole to climb through, just the foot of the
	-- flare on the floor: furniture may stand over its lowest, widest edge.
	room.keepClear = if ground then Habitat.stemRadius(room, floorY + room.flare * 0.4, stemR) else room.floorHole
	return room
end

local function smooth01(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Radius of the stem inside a room at height y (from the segment's bottom):
-- full (stemR) at the bottom, easing down to slim by `flare` above the floor,
-- slim up to `flare` under the ceiling, then easing out to stemR1 (the stem's
-- radius above the room) at the roof.
function Habitat.stemRadius(room: Room, y: number, stemR1: number): number
	local lowEnd = room.floorY + room.flare
	if y <= lowEnd then
		return lerp(room.stemR, room.slim, smooth01(y / lowEnd))
	end
	local hiStart = room.topY - room.wall - room.flare
	if y >= hiStart then
		return lerp(room.slim, math.max(stemR1, room.slim), smooth01((y - hiStart) / (room.topY - hiStart)))
	end
	return room.slim
end

-- Heights (from the segment's bottom) where the stem through a room changes
-- shape, `steps` per flare: drawn as pieces between them (each the radius at
-- its middle) it follows the flares.
function Habitat.stemProfile(room: Room, steps: number): { number }
	local ys = {}
	local lowEnd = room.floorY + room.flare
	for k = 0, steps do
		table.insert(ys, lowEnd * k / steps)
	end
	local hiStart = room.topY - room.wall - room.flare
	for k = 0, steps do
		local y = lerp(hiStart, room.topY, k / steps)
		if y > ys[#ys] + 1e-4 then
			table.insert(ys, y)
		end
	end
	return ys
end

---------------------------------------------------------------- room shape

-- Distance from a room-local point (x along the door direction, z across)
-- to the rectangle the room's walls are rounded around.
local function coreDistance(room: Room, lx: number, lz: number): number
	local dx = math.max(math.abs(lx) - (room.halfX - room.round), 0)
	local dz = math.max(math.abs(lz) - (room.halfZ - room.round), 0)
	return math.sqrt(dx * dx + dz * dz)
end

-- Height of a room's roof (or underside) over a room-local point. Off the
-- rounded edge it returns the height where the edge ends.
local function roofHeight(room: Room, lx: number, lz: number, under: boolean): number
	local rr = room.round
	local d = math.min(coreDistance(room, lx, lz), rr)
	local rise = math.sqrt(rr * rr - d * d)
	return if under then room.coreLo - rise else room.coreHi + rise
end

-- The room's frame: its bottom, turned so the door wall faces +X.
function Habitat.frameOf(bottomCF: CFrame, room: Room): CFrame
	return bottomCF * CFrame.fromMatrix(Vector3.zero, Vector3.new(math.cos(room.doorAz), 0, math.sin(room.doorAz)), Vector3.yAxis)
end

---------------------------------------------------------------- the ground

-- Rooms never dip into the land. PlantBuilder lifts a building plant on a
-- slope until every room clears the ground under it (see PlantBuilder
-- liftFor), and a lifted ground hall stands on a foundation down into the
-- soil, with its door ramp reaching down to the land.
Habitat.GROUND_GAP = 0.12 -- design studs of air kept under a raised room's belly (terrain voxels are only so exact)
-- A ground hall's floor top stays at least this far (design studs) above the
-- highest land under it. FLOOR_TOP alone is under one world stud, and smooth
-- terrain (4-stud voxels, read from the smooth Ground.heightAt) bulges past
-- that, so snow and grass showed through home floors on level land.
Habitat.HALL_CLEAR = 0.25
Habitat.FOUNDATION_SINK = 0.3 -- design studs a foundation reaches below the lowest land under it
Habitat.RAMP_MAX_RUN = 2.5 -- a door ramp is at most this many hall half-widths long (it steepens instead)

-- Points (room-local x, z) that sample the ground under a room's footprint:
-- the middle, a ring half-way out, the wall midpoints and the rounded
-- corners. withApron adds the land just outside the door (a ground hall's
-- threshold, an upper room's leaf balcony), which must be clear too.
function Habitat.footprint(room: Room, withApron: boolean?): { Vector2 }
	local hx, hz = room.halfX, room.halfZ
	local cx, cz = hx - room.round * 0.3, hz - room.round * 0.3
	local pts = {
		Vector2.zero,
		Vector2.new(hx, 0), Vector2.new(-hx, 0), Vector2.new(0, hz), Vector2.new(0, -hz),
		Vector2.new(cx, cz), Vector2.new(cx, -cz), Vector2.new(-cx, cz), Vector2.new(-cx, -cz),
		Vector2.new(hx * 0.5, hz * 0.5), Vector2.new(hx * 0.5, -hz * 0.5), Vector2.new(-hx * 0.5, hz * 0.5), Vector2.new(-hx * 0.5, -hz * 0.5),
	}
	if withApron then
		local u = room.unit
		table.insert(pts, Vector2.new(hx + (if room.ground then 2 else 7.5) * u, 0))
	end
	return pts
end

-- How far the room at bottomCF must rise to clear the land (0 if it already
-- does). landAt(p) is the land height under design point p.
function Habitat.groundNeed(room: Room, bottomCF: CFrame, landAt: (Vector3) -> number): number
	local frame = Habitat.frameOf(bottomCF, room)
	local rise = -math.huge
	for _, q in Habitat.footprint(room, true) do
		local p = frame:PointToWorldSpace(Vector3.new(q.X, 0, q.Y))
		rise = math.max(rise, landAt(p) - frame.Position.Y)
	end
	if room.ground then
		-- The hall floor sits FLOOR_TOP above its soil; lift it until its top
		-- clears the highest land under it by HALL_CLEAR, even on level land
		-- (town buildings that lay out furniture from the base add the same
		-- lift, PlantBuilder.groundLift). The foundation fills the gap below.
		return math.max(rise + Habitat.HALL_CLEAR - Habitat.FLOOR_TOP, 0)
	end
	return math.max(rise + Habitat.GROUND_GAP, 0)
end

-- How far a room's outer walls reach from the stem, in room-local direction
-- (dx, dz): leaves and branches below a room sprout from beyond this, so
-- nothing grows inside it.
function Habitat.wallReach(room: Room, dx: number, dz: number): number
	local tx = if math.abs(dx) > 1e-6 then room.halfX / math.abs(dx) else math.huge
	local tz = if math.abs(dz) > 1e-6 then room.halfZ / math.abs(dz) else math.huge
	return math.min(tx, tz)
end

-- How far a room's outer surface is from the stem, in room-local direction
-- (dx, dz) at height y (from the segment's bottom): out to the flat walls
-- between coreLo and coreHi, and round the curved edges above and below.
-- Leaves under a room sprout from here, so their stalks sit on the shell.
function Habitat.surfaceReach(room: Room, dx: number, dz: number, y: number): number
	local rr = room.round
	local off = if y > room.coreHi then y - room.coreHi elseif y < room.coreLo then room.coreLo - y else 0
	local grow = math.sqrt(math.max(rr * rr - off * off, 0))
	local a, c = room.halfX - rr, room.halfZ - rr
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 1e-6 then
		return 0
	end
	dx, dz = dx / len, dz / len
	-- Out along the direction until the point leaves the core rectangle grown by `grow`.
	local lo, hi = 0, room.radius + rr
	for _ = 1, 24 do
		local mid = (lo + hi) / 2
		local ex = math.max(math.abs(dx * mid) - a, 0)
		local ez = math.max(math.abs(dz * mid) - c, 0)
		if ex * ex + ez * ez <= grow * grow then
			lo = mid
		else
			hi = mid
		end
	end
	return lo
end

-- How far a room's flat roof reaches from the stem, in room-local direction
-- (dx, dz): where leaves and branches sprout from.
function Habitat.roofReach(room: Room, dx: number, dz: number): number
	local a, c = room.halfX - room.round, room.halfZ - room.round
	local tx = if math.abs(dx) > 1e-6 then a / math.abs(dx) else math.huge
	local tz = if math.abs(dz) > 1e-6 then c / math.abs(dz) else math.huge
	return math.min(tx, tz)
end

---------------------------------------------------------------- building blocks

-- Shell parts are collected into groups (one per room) so each group can be unioned into one smooth shape (smoothen).
local function keep(ctx, p: BasePart?): BasePart?
	if p and ctx.habitatGroup then
		table.insert(ctx.habitatGroup, p)
	end
	return p
end

-- A block fitted to a small four-cornered patch of a curved surface (all in
-- the frame's space): a0 -> b0 along the bottom edge, a1 -> b1 along the top.
-- It is `thick` deep, on the side away from `out`.
local function quad(ctx, frame: CFrame, name: string, a0: Vector3, b0: Vector3, a1: Vector3, b1: Vector3, out: Vector3, thick: number, color: Color3, material: Enum.Material, collide: boolean): BasePart?
	local m0, m1 = (a0 + b0) / 2, (a1 + b1) / 2
	local up = m1 - m0
	local across = ((b0 - a0) + (b1 - a1)) / 2
	local h = up.Magnitude
	local w = math.max((b0 - a0).Magnitude, (b1 - a1).Magnitude)
	if h < 1e-3 or w < 1e-3 then
		return nil
	end
	local Y = up / h
	local N = Y:Cross(across)
	if N.Magnitude < 1e-6 then
		return nil
	end
	N = N.Unit
	if N:Dot(out) < 0 then
		N = -N
	end
	local X = Y:Cross(N)
	local pos = (m0 + m1) / 2 - N * (thick / 2)
	local cf = frame * CFrame.fromMatrix(pos, X, Y)
	return keep(ctx, ctx.make.part(ctx, name, Enum.PartType.Block, Vector3.new(w * 1.04 + 0.01, h * 1.04 + 0.01, thick), cf, color, material, collide))
end

-- A grid of quads over a surface. fn(u, v) gives a point (u, v in 0..1) and
-- a centre of curvature: the surface faces away from it, or towards it if
-- `concave`.
local function patch(ctx, frame: CFrame, name: string, fn: (number, number) -> (Vector3, Vector3), nu: number, nv: number, thick: number, color: Color3, collide: boolean, concave: boolean?)
	local pts, ctr = {}, {}
	local pause = ctx.breathe
	for i = 0, nu do
		if pause then
			pause()
		end
		pts[i], ctr[i] = {}, {}
		for j = 0, nv do
			pts[i][j], ctr[i][j] = fn(i / nu, j / nv)
		end
	end
	for i = 0, nu - 1 do
		if pause then
			pause()
		end
		for j = 0, nv - 1 do
			local a0, b0, a1, b1 = pts[i][j], pts[i + 1][j], pts[i][j + 1], pts[i + 1][j + 1]
			local mid = (a0 + b0 + a1 + b1) / 4
			local c = (ctr[i][j] + ctr[i + 1][j + 1]) / 2
			local out = if concave then c - mid else mid - c
			quad(ctx, frame, name, a0, b0, a1, b1, out, thick, color, ctx.habitatMaterial or M.habitatWall, collide)
		end
	end
end

-- One flat wall of a room, `thick` deep behind its outer plane, with an
-- optional rectangular opening. n is the outward normal, off the distance of
-- the outer plane from the frame's origin along n, e1 and e2 the in-plane axes.
local function flatWall(ctx, frame: CFrame, n: Vector3, off: number, e1: Vector3, e2: Vector3, p0: number, p1: number, q0: number, q1: number, hole: { number }?, thick: number, color: Color3)
	-- Each piece is padded a hair past the wall's outer edges, to close the
	-- seam with the rounded edges, but never past an edge it shares with
	-- another piece of the same wall: the pieces lie in one plane, so any
	-- overlap between them would flicker.
	local PAD = 0.006
	local function rect(a0: number, a1: number, b0: number, b1: number)
		if a1 - a0 < 0.02 or b1 - b0 < 0.02 then
			return
		end
		local x0 = if a0 <= p0 then a0 - PAD else a0
		local x1 = if a1 >= p1 then a1 + PAD else a1
		local y0 = if b0 <= q0 then b0 - PAD else b0
		local y1 = if b1 >= q1 then b1 + PAD else b1
		local centre = n * (off - thick / 2) + e1 * ((x0 + x1) / 2) + e2 * ((y0 + y1) / 2)
		keep(ctx, ctx.make.part(ctx, "HabitatWall", Enum.PartType.Block, Vector3.new(x1 - x0, y1 - y0, thick), frame * CFrame.fromMatrix(centre, e1, e2), color, ctx.habitatMaterial or M.habitatWall, true))
	end
	if not hole then
		rect(p0, p1, q0, q1)
		return
	end
	local h0, h1 = math.max(hole[1], p0), math.min(hole[2], p1)
	local v0, v1 = math.max(hole[3], q0), math.min(hole[4], q1)
	rect(p0, h0, q0, q1)
	rect(h1, p1, q0, q1)
	rect(h0, h1, q0, v0)
	rect(h0, h1, v1, q1)
end

-- Rounds off a square hole of half-size r in a level slab (the frame's Y
-- axis through its middle, the slab from y0 to y1): a ring of blocks whose
-- inner faces make a ROUND_HOLE_SIDES-sided polygon round the axis, filling
-- the square's corners so the opening (and what you can fall through) is
-- round. Each block is a hair thinner than the slab, alternate ones a hair
-- more, so none shares a face with the slab or its neighbours (that would
-- flicker). Blocks go in the room's shell group when `inShell`.
local ROUND_HOLE_SIDES = 16
local ROUND_INSET = 0.004
local function roundHole(ctx, frame: CFrame, name: string, r: number, y0: number, y1: number, color: Color3, material: Enum.Material, collide: boolean, inShell: boolean)
	if r < 0.02 then
		return
	end
	local n = ROUND_HOLE_SIDES
	local mid = (y0 + y1) / 2
	for k = 0, n - 1 do
		-- Out just past the square's edge in this direction (furthest at its
		-- corners), and wide enough to close the gaps out there.
		local th = k / n * TAU
		local edge = r / math.max(math.abs(math.cos(th)), math.abs(math.sin(th)))
		local depth = edge - r + r * 0.08 + 0.01
		local width = 2 * (r + depth) * math.tan(math.pi / n)
		local inset = ROUND_INSET * (if k % 2 == 0 then 1 else 2)
		local h = (y1 - y0) - 2 * inset
		if h > 0.005 then
			local cf = frame * CFrame.new(0, mid, 0) * CFrame.Angles(0, th, 0) * CFrame.new(r + depth / 2, 0, 0)
			local p = ctx.make.part(ctx, name, Enum.PartType.Block, Vector3.new(depth, h, width), cf, color, material, collide)
			if inShell then
				keep(ctx, p)
			end
		end
	end
end

-- A flat slab with rounded corners and an optional round hole in the
-- middle (where the stem passes through), its top at yTop. Returns its first part.
-- The blocks tile the slab without overlapping (their tops share one plane,
-- so overlaps would flicker); the corner discs, which have to overlap them,
-- sit a hair lower.
local CORNER_DROP = 0.004
local function roundedSlab(ctx, frame: CFrame, name: string, fx: number, fz: number, cr: number, hole: number?, yTop: number, t: number, color: Color3, material: Enum.Material): BasePart?
	cr = math.max(0.05, math.min(cr, math.min(fx, fz) - (hole or 0) - 0.05))
	local first: BasePart? = nil
	local function slab(x0: number, x1: number, z0: number, z1: number)
		if x1 - x0 < 0.02 or z1 - z0 < 0.02 then
			return
		end
		local p = ctx.make.part(ctx, name, Enum.PartType.Block, Vector3.new(x1 - x0, t, z1 - z0), frame * CFrame.new((x0 + x1) / 2, yTop - t / 2, (z0 + z1) / 2), color, material, true)
		first = first or p
	end
	if hole then
		-- Left and right of the hole, then the strips in front of and behind it.
		slab(hole, fx, -(fz - cr), fz - cr)
		slab(-fx, -hole, -(fz - cr), fz - cr)
		slab(-hole, hole, hole, fz - cr)
		slab(-hole, hole, -(fz - cr), -hole)
		roundHole(ctx, frame, name, hole, yTop - t, yTop, color, material, true, false)
	else
		slab(-fx, fx, -(fz - cr), fz - cr)
	end
	slab(-(fx - cr), fx - cr, -fz, -(fz - cr))
	slab(-(fx - cr), fx - cr, fz - cr, fz)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			local cf = frame * CFrame.new(sx * (fx - cr), yTop - t / 2 - CORNER_DROP, sz * (fz - cr)) * CFrame.Angles(0, 0, HALF_PI)
			ctx.make.part(ctx, name, Enum.PartType.Cylinder, Vector3.new(t, cr * 2, cr * 2), cf, color, material, true)
		end
	end
	return first
end

---------------------------------------------------------------- smooth shells

-- Each room's look is rebuilt on the client as one solid-geometry shell,
-- made from true round shapes rather than the faceted blocks:
--
--   outside = three crossed boxes (the flat walls, roof and underside),
--             twelve cylinders along the edges and eight spheres at the
--             corners, all unioned into one rounded box
--   inside  = the same rounded box, one wall thickness smaller
--   shell   = outside minus inside, minus the doorway, windows and stem
--             holes (and, for the ground hall, everything below the soil),
--             then unioned with the collars where the stem meets it
--
-- Taking the smaller rounded box out of the bigger one hollows every edge
-- cylinder into a quarter pipe and every corner sphere into a carved-out
-- eighth of a ball, joined seamlessly to the flat walls. The shell is only
-- for looks: the blocks stay as invisible colliders (unions collide less
-- predictably, and the rooms must stay hollow and walkable). Runs in the
-- background, one room at a time, and leaves the blocks showing if the
-- model is rebuilt meanwhile or solid geometry isn't available here.
type ShellJob = {
	model: Model,
	group: { BasePart }, -- the shell's blocks (and collars)
	ref: BasePart, -- a block that stays, to follow the room as it sways
	refRest: CFrame, -- ref where it was built, before the model was scaled
	frame: CFrame, -- the room's frame then
	room: Room,
	color: Color3,
	material: Enum.Material,
}
local queue: { ShellJob } = {}
local running = false

-- Shells still to come on a model, in the attribute PlantRenderer watches
-- (the same one Smooth counts its unions in), so a building is only shown
-- once its rooms are done.
local PENDING_ATTRIBUTE = "SmoothPending"
local function pendingCount(model: Model, by: number)
	local n = (model:GetAttribute(PENDING_ATTRIBUTE) or 0) + by
	model:SetAttribute(PENDING_ATTRIBUTE, math.max(n, 0))
end

local function csg(op: string, first: BasePart, rest: { BasePart }): BasePart?
	local ok, result = pcall(function()
		local GeometryService = game:GetService("GeometryService")
		return (GeometryService :: any)[op](GeometryService, first, rest, {
			CollisionFidelity = Enum.CollisionFidelity.Box,
			RenderFidelity = Enum.RenderFidelity.Automatic,
			SplitApart = false,
		})
	end)
	if ok and type(result) == "table" and result[1] and result[1]:IsA("BasePart") then
		return result[1]
	end
	warn("[Habitat] couldn't build a building plant's smooth shell, keeping the blocks:", op, result)
	Habitat.UNION = false
	return nil
end

-- A loose part for solid geometry (never parented: GeometryService doesn't need it).
local function solid(shape: Enum.PartType, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material): BasePart
	local p = Instance.new("Part")
	p.Shape = shape
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	return p
end

-- The parts of a solid rounded box in `frame`: a core box from (-a, lo, -c)
-- to (a, hi, c), grown outward by r on every side with round edges and corners.
local function roundedBox(frame: CFrame, a: number, c: number, lo: number, hi: number, r: number, color: Color3, material: Enum.Material): { BasePart }
	local out = {}
	local h = hi - lo
	local my = (lo + hi) / 2
	local function add(shape, size, cf)
		table.insert(out, solid(shape, size, frame * cf, color, material))
	end
	add(Enum.PartType.Block, Vector3.new(2 * (a + r), h, 2 * c), CFrame.new(0, my, 0))
	add(Enum.PartType.Block, Vector3.new(2 * a, h, 2 * (c + r)), CFrame.new(0, my, 0))
	add(Enum.PartType.Block, Vector3.new(2 * a, h + 2 * r, 2 * c), CFrame.new(0, my, 0))
	if r < 0.01 then
		return out
	end
	local d = 2 * r
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			-- Upright edges (a cylinder's length runs along its X axis).
			add(Enum.PartType.Cylinder, Vector3.new(h, d, d), CFrame.new(sx * a, my, sz * c) * CFrame.Angles(0, 0, HALF_PI))
		end
	end
	for _, y in { lo, hi } do
		for _, s in { -1, 1 } do
			add(Enum.PartType.Cylinder, Vector3.new(2 * a, d, d), CFrame.new(0, y, s * c))
			add(Enum.PartType.Cylinder, Vector3.new(2 * c, d, d), CFrame.new(s * a, y, 0) * CFrame.Angles(0, HALF_PI, 0))
			for _, sx in { -1, 1 } do
				add(Enum.PartType.Ball, Vector3.new(d, d, d), CFrame.new(sx * a, y, s * c))
			end
		end
	end
	return out
end

local function destroyAll(list: { Instance })
	for _, p in list do
		p:Destroy()
	end
end

-- Builds one room's smooth shell. Returns it, unparented, or nil.
local function shellOf(job: ShellJob): BasePart?
	local model, ref, room = job.model, job.ref, job.room
	-- Everything was built at the plant's design size and then scaled up
	-- about the plant's pivot; the room's frame keeps its place relative to
	-- ref, at k times the distance.
	local k = model:GetScale()
	local inRef = job.refRest:ToObjectSpace(job.frame)
	local mark = ref.CFrame -- where ref is while the shapes are placed
	local frame = mark * CFrame.new(inRef.Position * k) * inRef.Rotation
	local rr, t = room.round * k, room.wall * k
	local a, c = (room.halfX - room.round) * k, (room.halfZ - room.round) * k
	local lo, hi = room.coreLo * k, room.coreHi * k
	local color, material = job.color, job.material

	local outside = roundedBox(frame, a, c, lo, hi, rr, color, material)
	local cut = roundedBox(frame, a, c, lo, hi, math.max(rr - t, 0), color, material)
	local function hole(size: Vector3, cf: CFrame, shape: Enum.PartType?)
		table.insert(cut, solid(shape or Enum.PartType.Block, size, frame * cf, color, material))
	end
	local hx, hz = room.halfX * k, room.halfZ * k
	local depth = t * 4
	local doorBottom = (if room.ground then room.coreLo else room.floorY) * k
	local doorTop = doorBottom + room.doorHeight * k
	local doorLow = if room.ground then doorBottom - t else doorBottom
	hole(Vector3.new(depth, doorTop - doorLow, room.doorHalf * 2 * k), CFrame.new(hx - t / 2, (doorLow + doorTop) / 2, 0))
	local wy = (room.windowLo + room.windowHi) / 2 * k
	local wh = (room.windowHi - room.windowLo) * k
	local ww = room.windowHalf * 2 * k
	hole(Vector3.new(depth, wh, ww), CFrame.new(-(hx - t / 2), wy, 0))
	hole(Vector3.new(ww, wh, depth), CFrame.new(0, wy, hz - t / 2))
	hole(Vector3.new(ww, wh, depth), CFrame.new(0, wy, -(hz - t / 2)))
	-- Round holes for the stem: an upright cylinder (its length runs along X).
	local stem = room.hole * 2 * k
	local UPRIGHT = CFrame.Angles(0, 0, HALF_PI)
	hole(Vector3.new(depth, stem, stem), CFrame.new(0, room.topY * k - t / 2, 0) * UPRIGHT, Enum.PartType.Cylinder)
	if room.ground then
		-- The hall stands on the soil: no rounded belly, open underneath.
		hole(Vector3.new(2 * hx + depth, rr + depth, 2 * hz + depth), CFrame.new(0, lo - (rr + depth) / 2, 0))
	else
		hole(Vector3.new(depth, stem, stem), CFrame.new(0, t / 2, 0) * UPRIGHT, Enum.PartType.Cylinder)
	end

	local outer = csg("UnionAsync", outside[1], table.move(outside, 2, #outside, 1, {}))
	destroyAll(outside)
	if not outer or not model.Parent then
		destroyAll(cut)
		if outer then
			outer:Destroy()
		end
		return nil
	end
	local shell = csg("SubtractAsync", outer, cut)
	destroyAll(cut)
	outer:Destroy()
	if not shell or not model.Parent or not ref.Parent then
		if shell then
			shell:Destroy()
		end
		return nil
	end
	-- The plant may have swayed meanwhile: follow ref.
	shell.CFrame = ref.CFrame * mark:ToObjectSpace(shell.CFrame)
	mark = ref.CFrame

	-- Blend in the collars where the stem meets the room.
	local collars = {}
	for _, p in job.group do
		if p.Parent and p.Name == "HabitatCollar" then
			table.insert(collars, p)
		end
	end
	if #collars > 0 then
		local joined = csg("UnionAsync", shell, collars)
		shell:Destroy()
		if not joined or not model.Parent or not ref.Parent then
			if joined then
				joined:Destroy()
			end
			return nil
		end
		shell = joined
		shell.CFrame = ref.CFrame * mark:ToObjectSpace(shell.CFrame)
	end
	return shell
end

local function drain()
	while #queue > 0 do
		local job = table.remove(queue, 1)
		local model, ref = job.model, job.ref
		if Habitat.UNION and Smooth.isHeld(model) then
			-- Still being built over several frames (Smooth.hold): come back to it.
			table.insert(queue, job)
			task.wait()
			continue
		end
		if model.Parent and ref.Parent and Habitat.UNION then
			local okShell, built = pcall(shellOf, job)
			local shell = if okShell then built else nil
			if shell and model.Parent then
				shell.Name = Habitat.SHELL_NAME
				shell.Anchored = true
				shell.CanCollide = false
				shell.CanQuery = false -- rays hit the exact blocks underneath instead (RoomFade)
				shell.CanTouch = false
				shell.CastShadow = true
				shell.Transparency = 0
				local op = shell :: any
				pcall(function()
					op.UsePartColor = true
					op.SmoothingAngle = Habitat.SMOOTHING_ANGLE
				end)
				shell.Color = job.color
				local link = Instance.new("ObjectValue")
				link.Name = "SwayRef" -- PlantRenderer sways the shell with this block
				link.Value = ref
				link.Parent = shell
				shell.Parent = model
				for _, p in job.group do
					if p.Parent then
						if p.CanCollide then
							p.Transparency = 1
							p.CastShadow = false
						else
							p:Destroy()
						end
					end
				end
			elseif shell then
				shell:Destroy()
			end
		end
		pendingCount(model, -1) -- see Smooth.PENDING_ATTRIBUTE
		task.wait() -- spread the work over frames
	end
	running = false
end

local function smoothen(job: ShellJob)
	table.insert(queue, job)
	pendingCount(job.model, 1)
	if not running then
		running = true
		task.defer(drain) -- after the renderer has parented the model
	end
end

---------------------------------------------------------------- rooms

-- A room's shell in its own frame (origin at the bottom of the segment, +X
-- out through the door): six flat walls with the door, windows and stem
-- holes cut out, twelve rounded edges and eight rounded corners.
local function buildShell(ctx, frame: CFrame, room: Room, res, color: Color3)
	local t = room.wall
	local rr = room.round
	local a, c = room.halfX - rr, room.halfZ - rr
	local lo, hi = room.coreLo, room.coreHi
	local X, Y, Z = Vector3.xAxis, Vector3.yAxis, Vector3.zAxis

	-- Walls. The door wall faces +X.
	-- The ground hall's doorway starts at the soil, where the door ramp comes in.
	local doorBottom = if room.ground then lo else room.floorY
	local door = { -room.doorHalf, room.doorHalf, doorBottom, doorBottom + room.doorHeight }
	local window = { -room.windowHalf, room.windowHalf, room.windowLo, room.windowHi }
	flatWall(ctx, frame, X, room.halfX, Z, Y, -c, c, lo, hi, door, t, color)
	flatWall(ctx, frame, -X, room.halfX, Z, Y, -c, c, lo, hi, window, t, color)
	flatWall(ctx, frame, Z, room.halfZ, X, Y, -a, a, lo, hi, window, t, color)
	flatWall(ctx, frame, -Z, room.halfZ, X, Y, -a, a, lo, hi, window, t, color)
	-- Roof and underside, with a hole for the stem.
	local hole = { -room.hole, room.hole, -room.hole, room.hole }
	flatWall(ctx, frame, Y, hi + rr, X, Z, -a, a, -c, c, hole, t, Palette.shade(color, 0.08))
	roundHole(ctx, frame, "HabitatWall", room.hole, hi + rr - t, hi + rr, Palette.shade(color, 0.08), ctx.habitatMaterial or M.habitatWall, true, true)
	if not room.ground then
		flatWall(ctx, frame, -Y, rr - lo, X, Z, -a, a, -c, c, hole, t, Palette.shade(color, -0.08))
		roundHole(ctx, frame, "HabitatWall", room.hole, lo - rr, lo - rr + t, Palette.shade(color, -0.08), ctx.habitatMaterial or M.habitatWall, true, true)
	end

	-- Rounded edges.
	local m = res.edge
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			patch(ctx, frame, "HabitatWall", function(u, v)
				local al = u * HALF_PI
				local centre = Vector3.new(sx * a, lerp(lo, hi, v), sz * c)
				return centre + Vector3.new(sx * math.cos(al), 0, sz * math.sin(al)) * rr, centre
			end, m, 1, t, color, true)
		end
	end
	local ends = if room.ground then { 1 } else { -1, 1 }
	local corner = if rr > 1.5 then math.max(res.corner, 2) else res.corner -- big corners need more facets or they gape
	for _, sy in ends do
		local ey = if sy > 0 then hi else lo
		local shade = Palette.shade(color, sy * 0.04)
		for _, sz in { -1, 1 } do
			patch(ctx, frame, "HabitatWall", function(u, v)
				local al = u * HALF_PI
				local centre = Vector3.new(lerp(-a, a, v), ey, sz * c)
				return centre + Vector3.new(0, sy * math.cos(al), sz * math.sin(al)) * rr, centre
			end, m, 1, t, shade, true)
		end
		for _, sx in { -1, 1 } do
			patch(ctx, frame, "HabitatWall", function(u, v)
				local al = u * HALF_PI
				local centre = Vector3.new(sx * a, ey, lerp(-c, c, v))
				return centre + Vector3.new(sx * math.sin(al), sy * math.cos(al), 0) * rr, centre
			end, m, 1, t, shade, true)
		end
		-- Corners: an eighth of a sphere each.
		for _, sx in { -1, 1 } do
			for _, sz in { -1, 1 } do
				local centre = Vector3.new(sx * a, ey, sz * c)
				patch(ctx, frame, "HabitatWall", function(u, v)
					local lam, phi = u * HALF_PI, v * HALF_PI
					local dir = Vector3.new(sx * math.cos(phi) * math.cos(lam), sy * math.sin(phi), sz * math.cos(phi) * math.sin(lam))
					return centre + dir * rr, centre
				end, corner, corner, t, shade, true)
			end
		end
	end

	-- Close up: raised veins up the walls, like the ribs on a stem.
	if ctx.ultra then
		local vein = Palette.shade(color, -0.18)
		local w = t * 0.5
		for _, face in { { X, Z, room.halfX, c }, { -X, Z, room.halfX, c }, { Z, X, room.halfZ, a }, { -Z, X, room.halfZ, a } } do
			local n, e, off, half = face[1], face[2], face[3], face[4]
			for _, f in { -0.7, 0.7 } do
				local pos = n * (off + w * 0.2) + e * (half * f) + Y * ((lo + hi) / 2)
				ctx.make.part(ctx, "HabitatRib", Enum.PartType.Block, Vector3.new(w, hi - lo, w), frame * CFrame.fromMatrix(pos, e, Y), vein, ctx.habitatMaterial or M.habitatWall, false)
			end
		end
	end
end

-- Where the stem goes into the room's underside (or out of its roof) it
-- flares in a collar: a quadratic Bezier from a foot on the room out at
-- stemR + k, through the corner where stem meets room, along the stem by k.
-- Just for looks: climbers pass through it to the hole in the room.
local function collar(ctx, frame: CFrame, room: Room, stemR: number, under: boolean, res, color: Color3)
	local u = room.unit
	local k = (if room.ground then 5 else 3) * u + stemR * 0.6
	local reach = math.min(stemR + k, math.min(room.halfX, room.halfZ) - room.round * 0.3)
	if reach <= stemR + 0.2 * u then
		return
	end
	local sign = if under then -1 else 1
	local edge = if under then 0 else room.topY
	patch(ctx, frame, "HabitatCollar", function(uu, v)
		local th = uu * TAU
		local dx, dz = math.cos(th), math.sin(th)
		local footY = roofHeight(room, dx * reach, dz * reach, under)
		local q = v
		local r = (1 - q) * (1 - q) * reach + 2 * q * (1 - q) * stemR + q * q * stemR
		local y = (1 - q) * (1 - q) * footY + 2 * q * (1 - q) * footY + q * q * (edge + sign * k)
		return Vector3.new(dx * r, y, dz * r), Vector3.new(dx * reach, edge + sign * k, dz * reach)
	end, res.ring, res.collar, room.wall, color, false, true)
end

Habitat.DOOR_FRAME_NAME = "HabitatDoorFrame" -- RoomFade keeps these solid
Habitat.DOOR_FRAME_WIDTH = 0.7 -- jamb and lintel width, in normal studs (times UNIT)
Habitat.DOOR_FRAME_LIP = 0.15 -- how far the frame reaches over the opening's edge (normal studs)
local FRAME_DARK = Color3.fromRGB(104, 62, 34) -- bark brown, for pale walls
local FRAME_LIGHT = Color3.fromRGB(232, 196, 138) -- honey birch, for dark walls

-- The frame's wood: dark on pale walls, pale on dark walls.
function Habitat.doorFrameColor(wallColor: Color3): Color3
	local lum = 0.299 * wallColor.R + 0.587 * wallColor.G + 0.114 * wallColor.B
	return if lum > 0.42 then FRAME_DARK else FRAME_LIGHT
end

-- Two jambs and a lintel round a room's doorway (the door wall faces +X in
-- `frame`), a little deeper than the wall so it shows on both sides.
function Habitat.buildDoorFrame(ctx, frame: CFrame, room: Room, wallColor: Color3)
	if not ctx.model then
		return
	end
	local u = room.unit
	local t = room.wall
	local w = Habitat.DOOR_FRAME_WIDTH * u
	local lip = Habitat.DOOR_FRAME_LIP * u
	local depth = t * 1.5
	local x = room.halfX - t / 2 -- middle of the door wall
	local doorBottom = if room.ground then room.coreLo else room.floorY
	local doorTop = doorBottom + room.doorHeight
	-- Keep it on the flat part of the wall: the walls curve in past coreHi
	-- and past halfZ - round.
	local outerZ = math.min(room.doorHalf - lip + w, room.halfZ - room.round)
	local jambW = outerZ - (room.doorHalf - lip)
	local lintelTop = math.min(doorTop - lip + w, room.coreHi)
	local lintelH = lintelTop - (doorTop - lip)
	if jambW < 0.1 * u or lintelH < 0.1 * u then
		return
	end
	local color = Habitat.doorFrameColor(wallColor)
	local function piece(size: Vector3, centre: Vector3)
		local p = ctx.make.part(ctx, Habitat.DOOR_FRAME_NAME, Enum.PartType.Block, size, frame * CFrame.new(centre), color, Enum.Material.Wood, false)
		if p then
			p.CanQuery = false -- camera rays, clicks and prompts pass through
			p.CastShadow = false
		end
	end
	local jambH = lintelTop - doorBottom
	for _, side in { -1, 1 } do
		piece(Vector3.new(depth, jambH, jambW), Vector3.new(x, doorBottom + jambH / 2, side * (outerZ - jambW / 2)))
	end
	-- The lintel runs between the jambs (not over them), so no faces are shared.
	local innerZ = room.doorHalf - lip
	piece(Vector3.new(depth * 0.98, lintelH, innerZ * 2), Vector3.new(x, lintelTop - lintelH / 2, 0))
end

-- Builds a room into the stem segment that starts at bottomCF (upright, at
-- the top of the stem below). stemR0 and stemR1 are the stem's radius where
-- it enters the room and where it leaves the roof. Nothing is built on dry
-- runs; the room's size comes from Habitat.room either way.
function Habitat.build(ctx, bottomCF: CFrame, room: Room, stemR0: number, stemR1: number, stemColor: Color3)
	if not ctx.model then
		return
	end
	local mk = ctx.make
	local u = room.unit
	local t = room.wall
	local frame = Habitat.frameOf(bottomCF, room)
	local pause = ctx.breathe
	local mark = ctx.geometryMark
	local previous = if mark then mark("PlantHabitatShell") else nil
	local hd = ctx.habitatDetail
	local res = if ctx.ultra
		then { edge = 4, corner = 3, ring = 16, collar = 3 }
		elseif hd then { edge = 3, corner = 2, ring = 12, collar = 2 }
		else { edge = 2, corner = 1, ring = 8, collar = 1 }

	-- The shell is part of the stem: same colour, same material.
	local group: { BasePart } = {}
	ctx.habitatGroup = group
	ctx.habitatMaterial = M.stem
	local wallColor = Palette.shade(stemColor, 0.08)
	buildShell(ctx, frame, room, res, wallColor)
	if not room.ground then
		collar(ctx, frame, room, stemR0, true, res, Palette.shade(stemColor, -0.05))
	end
	collar(ctx, frame, room, stemR1, false, res, Palette.shade(stemColor, 0.05))
	ctx.habitatGroup = nil
	ctx.habitatMaterial = nil

	-- Invisible panes filling the doorway and windows. They don't block
	-- anyone, but rays hit them, so RoomFade fades the room when the camera
	-- looks in through an opening, not just through a wall. Each pane knows
	-- where its room's middle is (in its own space) and how big the room is.
	do
		local X, Y, Z = Vector3.xAxis, Vector3.yAxis, Vector3.zAxis
		local roomCentre = frame * Vector3.new(0, (room.coreLo + room.coreHi) / 2, 0)
		local function pane(centre: Vector3, across: Vector3, w: number, h: number)
			if w <= 0 or h <= 0 then
				return
			end
			local p = mk.part(ctx, Habitat.PANE_NAME, Enum.PartType.Block, Vector3.new(w, h, t), frame * CFrame.fromMatrix(centre, across, Y), wallColor, M.habitatWall, false)
			if p then
				p.Transparency = 1
				p.CanQuery = true
				p.CastShadow = false
				p:SetAttribute("RoomCentre", p.CFrame:PointToObjectSpace(roomCentre))
				p:SetAttribute("RoomRadius", room.radius + room.round)
			end
		end
		local doorBottom = if room.ground then room.coreLo else room.floorY
		pane(X * (room.halfX - t / 2) + Y * (doorBottom + room.doorHeight / 2), Z, room.doorHalf * 2, room.doorHeight)
		local wy = (room.windowLo + room.windowHi) / 2
		local wh = room.windowHi - room.windowLo
		pane(-X * (room.halfX - t / 2) + Y * wy, Z, room.windowHalf * 2, wh)
		pane(Z * (room.halfZ - t / 2) + Y * wy, X, room.windowHalf * 2, wh)
		pane(-Z * (room.halfZ - t / 2) + Y * wy, X, room.windowHalf * 2, wh)
	end

	-- A solid wooden door frame (two jambs and a lintel) round the doorway,
	-- in a wood that stands out from the walls. RoomFade never fades it
	-- (HabitatDoorFrame is on its KEEP list), so the way in and out stays
	-- easy to see when the walls go see-through. It sits in the wall round
	-- the opening, overlapping the opening's edges only a little so their
	-- faces don't flicker, and doesn't collide: the walls are the colliders,
	-- so it never narrows the doorway, the ramp or a climb.
	Habitat.buildDoorFrame(ctx, frame, room, wallColor)

	-- An invisible box the size of the whole room. RoomFade finds these by
	-- tag and fades a room while you're inside it or it sits between the
	-- camera and you, whatever way the camera faces.
	do
		local box = mk.part(ctx, Habitat.VOLUME_NAME, Enum.PartType.Block, Vector3.new(room.halfX * 2, room.topY, room.halfZ * 2), frame * CFrame.new(0, room.topY / 2, 0), wallColor, M.habitatWall, false)
		if box then
			box.Transparency = 1
			box.CanQuery = false
			box.CanTouch = false
			box.CastShadow = false
			-- Ground-floor rooms keep grass and fallen litter off their
			-- footprint (client KeepOut). Set before the tag, which KeepOut watches.
			box:SetAttribute("GroundRoom", room.ground == true)
			CollectionService:AddTag(box, Habitat.ROOM_TAG)
		end
	end

	-- Floor, round the stem (and, above the ground, round the climbing hole).
	local floorColor = Palette.shade(stemColor, -0.3)
	local floorT = if room.ground then Habitat.FLOOR_TOP else 0.6 * u
	local floor = roundedSlab(ctx, frame, "HabitatFloor", room.halfX - t * 0.5, room.halfZ - t * 0.5, room.round - t * 0.5, room.floorHole, room.floorY, floorT, floorColor, M.habitatFloor)
	if floor then
		floor:SetAttribute("Room", room.number)
		CollectionService:AddTag(floor, if room.ground then Habitat.FLOOR_TAG else Habitat.ROOM_TAG)
	end

	if room.ground then
		-- On a slope the hall is lifted clear of the land (PlantBuilder), so it
		-- stands on a foundation reaching down into the soil, the plant's own
		-- woody base, a little wider than the walls.
		local landAt = ctx.landAt
		local function landY(x: number): number
			-- land height in the hall's frame, x out through the door
			return if landAt then landAt(frame:PointToWorldSpace(Vector3.new(x, 0, 0))) - frame.Position.Y else 0
		end
		if landAt then
			local lowest = math.huge
			for _, q in Habitat.footprint(room) do
				lowest = math.min(lowest, landAt(frame:PointToWorldSpace(Vector3.new(q.X, 0, q.Y))))
			end
			local gap = frame.Position.Y - lowest
			if gap > 0.02 then
				local grow = t * 0.3
				roundedSlab(ctx, frame, "HabitatFoundation", room.halfX + grow, room.halfZ + grow, room.round + grow, nil, 0, gap + Habitat.FOUNDATION_SINK, Palette.shade(stemColor, -0.4), M.stem)
			end
		end
		-- The hall floor stands FLOOR_TOP above the soil (more if the hall was
		-- lifted), too tall a step for a shrunken player, so a gentle ramp
		-- leads up through the doorway, down to wherever the land is. On a
		-- steep slope it would run on and on, so past RAMP_MAX_RUN it steepens.
		local width = 2 * room.doorHalf * 0.9
		local tanSlope = math.tan(Habitat.DOOR_RAMP_SLOPE)
		local maxRun = room.halfX * Habitat.RAMP_MAX_RUN
		local drop = room.floorY
		local run = drop / tanSlope
		if landAt then
			for _ = 1, 4 do
				drop = math.max(room.floorY - landY(room.halfX + run), room.floorY)
				run = math.min(drop / tanSlope, maxRun)
			end
			-- sink the foot a little into the land
			drop = math.max(room.floorY - landY(room.halfX + run), room.floorY) + 0.3 * u
		end
		local inner = Vector3.new(room.halfX - t, room.floorY, 0)
		local outer = Vector3.new(room.halfX + run, room.floorY - drop, 0)
		local rt = 0.8 * u
		local cf = frame * CFrame.lookAt((inner + outer) / 2, inner) * CFrame.new(0, -rt / 2, 0)
		mk.part(ctx, "HabitatDoorRamp", Enum.PartType.Block, Vector3.new(width, rt, (inner - outer).Magnitude), cf, floorColor, M.habitatFloor, true)
	else
		-- A leaf balcony outside the door. Its inner edge reaches under the
		-- floor's, so it sits a hair lower than the floor rather than sharing
		-- its top and bottom faces (which would flicker in the doorway).
		local cf = frame * CFrame.new(room.halfX + 3 * u, room.floorY - floorT / 2 - 0.04 * u, 0) * CFrame.Angles(0, 0, HALF_PI)
		mk.part(ctx, "HabitatBalcony", Enum.PartType.Cylinder, Vector3.new(floorT, 9 * u, 9 * u), cf, Palette.shade(ctx.colors.leaf, 0.1), M.leaf, true)
	end

	-- Wall lamps on the back wall: a curled stalk bracket from a leaf plate on
	-- the wall, a petal shade over the top, and a warm glowing bulb under it,
	-- so they read as lamps (not floating balls) even when the walls fade.
	if hd then
		local glow = ctx.colors.petalTip:Lerp(Color3.fromRGB(255, 236, 170), 0.35)
		local shadeColor = Palette.shade(ctx.colors.petalBase, -0.05)
		local armColor = Palette.shade(stemColor, -0.25)
		local ly = room.floorY + room.height * (if room.ground then 0.4 else 0.55)
		local wallX = -(room.halfX - t) -- inner face of the back wall
		local lx = wallX + 1.6 * u -- bulb centre, out from the wall
		local bulbD = 1.1 * u
		local topY = ly + 1.5 * u -- height of the bracket arm
		for _, side in { -1, 1 } do
			local lz = side * (room.halfZ - room.round) * 0.6
			local function at(x: number, y: number): Vector3
				return (frame * CFrame.new(x, y, lz)).Position
			end
			-- Leaf-shaped plate on the wall, then the arm out and down.
			mk.ellipsoid(ctx, "HabitatLampMount", Vector3.new(0.25 * u, 1.6 * u, 0.9 * u), frame * CFrame.new(wallX + 0.05 * u, topY - 0.3 * u, lz), Palette.shade(ctx.colors.leaf, -0.1), M.leaf)
			mk.cylinderBetween(ctx, "HabitatLampArm", at(wallX, topY - 0.2 * u), at(lx - 0.3 * u, topY), 0.22 * u, armColor, M.stem)
			mk.cylinderBetween(ctx, "HabitatLampArm", at(lx - 0.3 * u, topY), at(lx, ly + bulbD * 0.55), 0.18 * u, armColor, M.stem)
			-- Petal shade: five petals cupped down over the bulb, with a sepal cap.
			local capCF = frame * CFrame.new(lx, ly + bulbD * 0.5, lz)
			mk.ellipsoid(ctx, "HabitatLampCap", Vector3.new(0.6, 0.35, 0.6) * u, capCF, Palette.shade(Palette.SEPAL, -0.15), M.sepal)
			for i = 1, 5 do
				local pcf = capCF * CFrame.Angles(0, i / 5 * math.pi * 2, 0) * CFrame.Angles(-0.85, 0, 0)
				mk.ellipsoid(ctx, "HabitatLampShade", Vector3.new(0.75 * u, 0.08 * u, 1.2 * u), pcf * CFrame.new(0, 0, -0.5 * u), shadeColor, M.petal)
			end
			local lamp = mk.ball(ctx, "HabitatLamp", bulbD, at(lx, ly), glow, M.habitatGlow)
			if lamp then
				local light = Instance.new("PointLight")
				light.Color = glow
				light.Range = math.max(2, room.radius * 1.5)
				light.Brightness = 1.1
				-- Client.RoomLamps pools it on the floor and walls (nearest few only).
				RoomLamps.mark(light, lamp, room.radius * 1.6, 1.3)
				light.Parent = lamp
				-- A switch for it (Shared.Plants.FurnitureUse).
				Furniture.addHandle(ctx, "wallLamp", room.number, if side < 0 then "L1" else "L2", CFrame.new(at(lx, ly)), Vector3.one * bulbD * 2, { lamp })
			end
		end
	end

	-- Grown furniture: every room has a purpose, even if only a homely one
	-- (see Furniture). Its pieces ride with the room and never fade.
	if hd then
		if pause then
			pause()
		end
		if mark then
			mark("PlantFurnitureBuild")
		end
		if Host.features.furniture then
			Furniture.furnish(ctx, frame, room, room.keepClear)
		end
	end

	if mark then
		mark(previous)
	end

	if hd and Habitat.UNION then
		-- One wall block that stays (as a collider), to place the shell by.
		local ref: BasePart? = nil
		for _, p in group do
			if p.CanCollide and p.Name == "HabitatWall" then
				ref = p
				break
			end
		end
		if ref then
			smoothen({
				model = ctx.model,
				group = group,
				ref = ref,
				refRest = ref.CFrame,
				frame = frame,
				room = room,
				color = wallColor,
				material = M.stem,
			})
		end
	end
end

return Habitat
