--!strict
--[[
	Layout: where every stem piece, leaf and flower of a derived skeleton is
	at a growth progress, without making any parts.

	Positions are in design studs relative to the plant's base (origin, up is
	+Y); PlantBuilder turns them into parts. Sizes use the same formulas as
	PlantBuilder (mainStemThickness, leafLength, mainStem), so a grammar plant
	is the same scale as a classic one.

	Growth coherence: node k is born at plastochron t, so the stem reaches it
	at VEGETATIVE start + t * plast. A node, once born, only lengthens to its
	full internode; it never moves sideways or vanishes. Bud and bloom follow
	Growth.BUD and Growth.BLOOM, staggered by each flower's rank (Derive's
	frank), so a raceme opens from the bottom up and everything is open at
	progress 1.

	LOD coherence: nothing here depends on detail, so every detail level puts
	every node, leaf and flower in the same place.

	Height: the main stem is lerp(3, 16, height) tall, as PlantBuilder's,
	times the plant's own stature (Derive), so plants of one kind finish at
	different heights.

	Rooms (building plants, see Rooms): a node in plan.rooms swells into a
	room, exactly as a room segment of PlantBuilder's classic stem does. Its
	internode grows straight up, as tall as the room; leaves sprout from the
	room's shoulder, shoots and flowers from the edge of its roof, and leaves
	on the node under it from its belly. A side shoot's room turns its door
	away from the main stem.

	Salts used: 1 node bend, 2 axis start angle.
]]

local Growth = require(script.Parent.Parent.Growth)
local Habitat = require(script.Parent.Parent.Habitat)
local Derive = require(script.Parent.Derive)

local Layout = {}

local TAU = math.pi * 2
local GOLDEN = math.rad(137.508)
local UP = Vector3.yAxis

export type Stem = {
	vid: number,
	a: Vector3,
	b: Vector3,
	ctrl: Vector3,
	d0: number,
	d1: number,
	t: number,
	kind: string,
	main: boolean,
	order: number,
	axis: number, -- the axis's id (Derive)
	room: Habitat.Room?, -- this internode is a room (from a, its bottom, up)
	under: boolean?, -- a room sits on the node at b
}
export type RoomAt = {
	number: number,
	vid: number, -- the room's node
	bottom: Vector3, -- the middle of its floor's underside, where its stem comes in
	room: Habitat.Room,
	stemR1: number, -- the stem's radius above it
	main: boolean,
	axis: number,
}
-- Which nodes are rooms (node vid -> room number), how far the rooms have
-- swollen (Growth.HABITAT phase; nil or 0: none yet), and the side shoots
-- that don't grow because a room took their place (axis vid -> anything).
-- avoid: rooms to grow round (see steerOut), in the plant's own frame; this
-- plant's own rooms are added to them. nil: grow as always.
export type Box = { cf: CFrame, halfX: number, halfZ: number, top: number, own: boolean? }
-- yield: older plants' rooms this plant gives way to (see Layout.YIELD_PASSES):
-- its main stem and room shoots lean out of their way, rooms riding along.
export type Plan = { rooms: { [number]: number }, swell: number?, pruned: { [number]: any }?, avoid: { Box }?, yield: { Box }? }
export type Leaf = { vid: number, kind: string, pos: Vector3, dir: Vector3, len: number, maturity: number, nodeT: number, stemD: number, sessile: boolean }
export type Flower = { vid: number, pos: Vector3, dir: Vector3, scale: number, bud: number, bloom: number, pedicel: { a: Vector3, b: Vector3, d: number }?, az: number, top: boolean }
export type Result = {
	stems: { Stem },
	leaves: { Leaf },
	flowers: { Flower },
	main: { Vector3 }, -- the main axis's node positions, base first (the climbing line)
	rooms: { RoomAt },
	climbAxes: { [number]: boolean }, -- side shoots climbed to reach a room on them
	mainDiameter: number,
	upright: boolean,
	veg: number,
}

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function phase(p: number, a: number, b: number): number
	return math.clamp((p - a) / (b - a), 0, 1)
end

local function ease(t: number): number
	return t * t * (3 - 2 * t)
end

local function perp(d: Vector3): Vector3
	local a = if math.abs(d.Y) < 0.9 then UP else Vector3.xAxis
	return d:Cross(a).Unit
end

-- d tilted toward o (perpendicular to d) by ang radians.
local function toward(d: Vector3, o: Vector3, ang: number): Vector3
	return (d * math.cos(ang) + o * math.sin(ang)).Unit
end

-- u made perpendicular to d (parallel transport of an axis's frame).
local function transport(u: Vector3, d: Vector3): Vector3
	local v = u - d * u:Dot(d)
	return if v.Magnitude < 1e-4 then perp(d) else v.Unit
end

-- The flat (horizontal) part of v, or nil if it has almost none.
local function flat(v: Vector3): Vector3?
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else nil
end

-- (dx, dz) in a room's own frame (door wall on +X, Habitat.frameOf) for a plant-frame direction.
local function roomLocal(room: Habitat.Room, o: Vector3): (number, number)
	local ca, sa = math.cos(room.doorAz), math.sin(room.doorAz)
	return o.X * ca + o.Z * sa, -o.X * sa + o.Z * ca
end

Layout.ROOM_GAP = 0.15 -- design studs of air kept round a room

--[[
	Growing round rooms (plan.avoid): a side shoot whose next stretch would
	pass into a room (another plant's, or one of this plant's own) turns
	away from it, out from the room's middle and down under it or up over
	it, a little at a time, the way a real shoot grows round an obstacle,
	and grows on from there in its new direction. If no turn clears it, the
	shoot stops there. A flower on a stalk that would sit in a room isn't
	grown. Main stems never turn (they carry the rooms and the top flower,
	which the server knows the place of), nor do side shoots carrying a room.
]]
Layout.AVOID_PAD = 0.35 -- design studs of air kept between a shoot and a room
Layout.AVOID_STEP = 0.25 -- radians per turn
Layout.AVOID_TRIES = 10

-- Is room-local (q.X, q.Z) inside the room's rounded-rectangle footprint
-- (corners rounded as Habitat rounds them), grown by pad?
function Layout.inFootprint(b: Box, q: Vector3, pad: number): boolean
	local hx, hz = b.halfX + pad, b.halfZ + pad
	local ax, az = math.abs(q.X), math.abs(q.Z)
	if ax >= hx or az >= hz then
		return false
	end
	local r = math.min(b.halfX, b.halfZ) * 0.3 + pad
	local dx, dz = math.max(ax - (hx - r), 0), math.max(az - (hz - r), 0)
	return dx * dx + dz * dz < r * r
end

-- The way out of the first room p is in (padded), or nil.
local function inBox(boxes: { Box }, p: Vector3, pad: number): Vector3?
	for _, b in boxes do
		local q = b.cf:PointToObjectSpace(p)
		if q.Y > -pad and q.Y < b.top + pad and Layout.inFootprint(b, q, pad) then
			local nx, nz = q.X / (b.halfX + pad), q.Z / (b.halfZ + pad)
			do
				local out = b.cf:VectorToWorldSpace(Vector3.new(nx, 0, nz))
				out = if out.Magnitude > 1e-3 then out.Unit else b.cf.LookVector
				-- under its lower half, duck beneath it; else rise over it
				local vy = if q.Y < b.top * 0.4 then -0.45 else 0.45
				return (out + b.cf.UpVector * vy).Unit
			end
		end
	end
	return nil
end
Layout.inBox = inBox

-- Turn d (from pos, a stretch len long) until neither its middle nor its end
-- is in a room. Returns the new direction, or nil if it can't be cleared.
local function steerOut(boxes: { Box }, pos: Vector3, d: Vector3, len: number): Vector3?
	local pad = Layout.AVOID_PAD
	local away = inBox(boxes, pos + d * len, pad) or inBox(boxes, pos + d * len * 0.5, pad)
	if not away then
		return d
	end
	for _ = 1, Layout.AVOID_TRIES do
		local axis = d:Cross(away)
		if axis.Magnitude < 1e-4 then
			axis = perp(d)
		end
		d = CFrame.fromAxisAngle(axis.Unit, Layout.AVOID_STEP):VectorToWorldSpace(d).Unit
		away = inBox(boxes, pos + d * len, pad) or inBox(boxes, pos + d * len * 0.5, pad)
		if not away then
			return d
		end
	end
	return nil
end

-- The circle round a room's walls, plus ROOM_GAP.
-- How big a plant's rooms are next to a plant of ordinary height (1):
-- rooms grow with the plant's stature, from 0.85 on the smallest plants up
-- to 1.8 on the giants.
Layout.ROOM_SIZE_MIN = 0.85
Layout.ROOM_SIZE_MAX = 1.8
function Layout.roomSize(stature: number): number
	return math.clamp(stature ^ 0.7, Layout.ROOM_SIZE_MIN, Layout.ROOM_SIZE_MAX)
end

function Layout.roomReach(room: Habitat.Room): number
	local a, c = room.halfX - room.round, room.halfZ - room.round
	return math.sqrt(a * a + c * c) + room.round + Layout.ROOM_GAP
end

local function newResult(): Result
	return { stems = {}, leaves = {}, flowers = {}, main = {}, rooms = {}, climbAxes = {}, mainDiameter = 0, upright = true, veg = 0 }
end

-- Per plant and room plan: how much each side shoot carrying a room
-- stretches below it (see Layout.layout).
local stretches: { [Derive.Graph]: { [string]: { [number]: number } } } = setmetatable({}, { __mode = "k" }) :: any
-- The leans worked out for a plant giving way to older rooms (Layout.yield):
-- graph -> plan and boxes key -> axis id -> node index -> offset.
local leans: { [Derive.Graph]: { [string]: { [number]: { [number]: Vector3 } } } } = setmetatable({}, { __mode = "k" }) :: any

--[[
	Giving way (plan.yield): a newer plant grows round older plants' rooms,
	main stem and all. Worked out on the grown plant, a few passes over:
	each pass finds where its main stem or a shoot carrying a room would
	run into an older room, or one of its own rooms would overlap one, and
	how far sideways that spot must move to clear it; the few stretches of
	stem below the spot lean that far between them, carrying everything
	above along (rooms, side shoots, the top flower). That can push some
	other part into a room, so the next pass looks again. While the plant
	is still growing each stretch leans in step with its growth. All of it
	is a pure function of the genome and the boxes, so everyone agrees.
]]
Layout.YIELD_PASSES = 12
Layout.YIELD_WINDOW = 4 -- stretches of stem below a spot that lean to clear it
Layout.YIELD_PAD = 0.3 -- design studs of air kept between a stem or room and an older room

local function boxKey(boxes: { Box }): string
	local parts = {}
	for _, b in boxes do
		local x, y, z = b.cf.Position.X, b.cf.Position.Y, b.cf.Position.Z
		local l = b.cf.LookVector
		table.insert(parts, string.format("%.2f,%.2f,%.2f,%.3f,%.3f,%.2f,%.2f,%.2f", x, y, z, l.X, l.Z, b.halfX, b.halfZ, b.top))
	end
	return table.concat(parts, ";")
end

-- How far (plant frame) a circle of radius rr at p, spanning heights y0..y1,
-- must move sideways to clear every box; zero if it already does.
local function clearOf(boxes: { Box }, p: Vector3, rr: number, y0: number, y1: number): Vector3
	local total = Vector3.zero
	local pad = Layout.YIELD_PAD
	for _, b in boxes do
		local q = b.cf:PointToObjectSpace(p)
		local lo, hi = q.Y + (y0 - p.Y), q.Y + (y1 - p.Y)
		if hi > -pad and lo < b.top + pad and Layout.inFootprint(b, Vector3.new(q.X, 0, q.Z), rr + pad) then
			local hx, hz = b.halfX + rr + pad, b.halfZ + rr + pad
			local ux, uz = q.X, q.Z
			local m = math.sqrt(ux * ux + uz * uz)
			if m < 1e-3 then
				ux, uz, m = 0, -1, 1
			end
			ux, uz = ux / m, uz / m
			local tx = if ux > 1e-6 then (hx - q.X) / ux elseif ux < -1e-6 then (-hx - q.X) / ux else math.huge
			local tz = if uz > 1e-6 then (hz - q.Z) / uz elseif uz < -1e-6 then (-hz - q.Z) / uz else math.huge
			local t = math.min(tx, tz) + 0.05
			local w = b.cf:VectorToWorldSpace(Vector3.new(ux, 0, uz) * t)
			total += Vector3.new(w.X, 0, w.Z)
		end
	end
	return total
end

function Layout.layout(G: Derive.Graph, g: { [string]: number }, p: number, plan: Plan?): Result
	local out: Result = newResult()
	local swell = if plan and plan.swell and plan.swell > 0 then plan.swell else nil
	local roomOf = if plan and swell then plan.rooms else nil
	local pruned = if plan then plan.pruned else nil
	local main = G.axes[1]
	-- Side shoots carrying a room reach out from their stem before it, far
	-- enough that the room clears the stem: they leave at a wide angle, and
	-- their internodes up to the room stretch (by a factor worked out on the
	-- grown plant, so the shoot only ever lengthens as it grows).
	local avoidBoxes: { Box }? = nil -- set below, once the plant's own rooms are known
	local lean: { [number]: { [number]: Vector3 } } = {} -- axis id -> node index -> sideways offset (grown plant)
	local trace: { any }? = nil -- while working out leans: every node on the main stem and room shoots
	local roomAxes: { [number]: number } = {} -- axis id -> its first room's node index
	local stretch: { [number]: number } = {}
	local axisStart: { [number]: Vector3 } = {}
	if plan then
		for vid in plan.rooms do
			for _, nd in G.nodes do
				if nd.vid == vid then
					if nd.axis ~= main and (roomAxes[nd.axis.id] == nil or nd.i < roomAxes[nd.axis.id]) then
						roomAxes[nd.axis.id] = nd.i
					end
					break
				end
			end
		end
	end
	local vegStart, vegEnd = Growth.VEGETATIVE[1], Growth.VEGETATIVE[2]
	local stature = G.stature or 1
	-- Bigger plants carry bigger rooms (and small ones smaller rooms): the
	-- room grows with the plant's stature. Homes keep the 0.1.3 size, so
	-- their rooms and the furniture in them stay where they were.
	local roomSize = if (g.habitat or 0) >= Derive.HOME_HABITAT then 1 else Layout.roomSize(stature)
	local H = lerp(3, 16, g.height) * stature
	local R0 = lerp(0.2, 0.9, g.stemThickness) * lerp(0.7, 1.2, g.height) -- mainStemThickness
	local leafLen0 = lerp(0.9, 3.6, g.leafSize) -- leafLength
	local plast = (vegEnd - vegStart) / (G.Tmax + 1)
	local span = math.clamp(plast * 4, 0.06, 0.3)
	local veg = phase(p, vegStart, vegEnd)
	local function birth(t: number): number
		return vegStart + t * plast
	end

	local scape: Derive.Axis? = nil
	if main.type == "Z" then
		for _, ax in G.axes do
			if ax.type == "S" and ax.parentType == "Z" then
				scape = ax
				break
			end
		end
	end
	local sInt = if main.type == "S" then H / main.n elseif scape then lerp(1.5, 6, g.height) * stature / scape.n else H / 8

	local function params(ax: Derive.Axis): (number, number, number, number) -- internode, diameter, tropism, curve
		local kind = ax.type
		if kind == "Z" then
			return 0.06, lerp(0.25, 0.6, g.stemThickness), 0, 0
		elseif kind == "S" and ax.parentType == "Z" then
			return lerp(1.5, 6, g.height) * stature / ax.n, lerp(0.15, 0.4, g.stemThickness), 0.15, g.stemCurve * 0.25
		elseif kind == "S" then
			return sInt * 0.7 ^ ax.order, R0 * 0.55 ^ ax.order, 0.15, g.stemCurve * 0.35
		elseif kind == "I" then
			return if ax.n == 1 then 0 else sInt * 0.42, R0 * 0.32, -0.05, 0.06
		elseif kind == "R" then
			return leafLen0 * 0.3, math.max(0.08, R0 * 0.16), -0.06, 0.04
		end
		return sInt * 0.75, R0 * 0.4, -0.16, g.stemCurve * 0.2 -- V, trailing
	end

	-- The room on a node at this growth (Habitat.room, as PlantBuilder's
	-- classic stem sizes it), its door turned away from the main stem when
	-- it sits on a side shoot.
	local function roomAt(number: number, grow: number, stemR: number, bottom: Vector3, isMain: boolean): Habitat.Room
		local room = Habitat.room(g, number, (swell :: number) * grow, stemR, roomSize)
		local out2 = if not isMain and number ~= 0 then flat(bottom) else nil
		if out2 then
			room.doorAz = math.atan2(out2.Z, out2.X)
		end
		return room
	end

	local walk: (Derive.Axis, Vector3, Vector3, Vector3, number) -> ()
	function walk(ax: Derive.Axis, start: Vector3, D: Vector3, U: Vector3, scale: number)
		local int, diameter, trop, curve = params(ax)
		local pos, d, u, prevD = start, D, U, D
		local az0 = Derive.rng(G.seed, ax.vid, 2):NextNumber() * TAU
		local axGrow = math.clamp((p - birth(ax.nodes[1].t)) / (span * 3), 0, 1)
		local isMain = ax == main
		if isMain then
			table.insert(out.main, start)
		end
		axisStart[ax.id] = start
		local reachOut = stretch[ax.id] or 1
		local reachTo = roomAxes[ax.id] or -1
		for i = 0, ax.n - 1 do
			local nd = ax.nodes[i + 1]
			local b = birth(nd.t)
			if p < b then
				break
			end
			local m = math.clamp((p - b) / span, 0, 1)
			local r = Derive.rng(G.seed, nd.vid, 1)
			local a, amt = r:NextNumber() * TAU, 0.4 + 0.6 * r:NextNumber()
			if curve > 0 or trop ~= 0 then
				local w0 = d:Cross(u)
				local tilt = u * math.cos(a) + w0 * math.sin(a)
				d = (d + tilt * curve * amt + UP * trop).Unit
				u = transport(u, d)
			end
			local len = int * scale * (0.12 + 0.88 * ease(m)) * (if i < reachTo then reachOut else 1)
			local thick = if isMain then lerp(0.3, 1, veg) else lerp(0.3, 1, axGrow)
			local function diam(j: number): number
				return diameter * lerp(1, 0.45, j / ax.n) * thick * scale
			end
			-- A room: the stem swells into it, straight up and as tall as it is.
			local roomNo = if roomOf then roomOf[nd.vid] else nil
			local room: Habitat.Room? = nil
			if roomNo then
				room = roomAt(roomNo, m, diam(i) / 2, pos, isMain)
				d = UP
				u = transport(u, d)
				prevD = d
				len = (room :: Habitat.Room).total
			end
			if avoidBoxes and not room and not isMain and not roomAxes[ax.id] and len > 1e-4 then
				-- grow round rooms (see steerOut); stop if there's no way round
				local nd2 = steerOut(avoidBoxes, pos, d, len)
				if not nd2 then
					break
				end
				if nd2 ~= d then
					d = nd2
					u = transport(u, d)
				end
			end
			local np = pos + d * len
			local leanAt = lean[ax.id] and lean[ax.id][i]
			if leanAt and not room then
				-- giving way to an older room: lean with this stretch's growth
				np += leanAt * (0.12 + 0.88 * ease(m))
			end
			if trace and (isMain or roomAxes[ax.id]) then
				table.insert(trace, { axis = ax.id, i = i, a = pos, b = np, room = room, r = diam(i + 1) / 2 })
			end
			-- A room on the next node: this node is under its floor.
			local below: Habitat.Room? = nil
			local nextNd = ax.nodes[i + 2]
			if roomOf and nextNd and roomOf[nextNd.vid] and p >= birth(nextNd.t) then
				local m2 = math.clamp((p - birth(nextNd.t)) / span, 0, 1)
				below = roomAt(roomOf[nextNd.vid], m2, diam(i + 1) / 2, np, isMain)
			end
			if len > 1e-4 then
				table.insert(out.stems, {
					vid = nd.vid,
					a = pos,
					b = np,
					ctrl = pos + prevD * len * 0.5,
					d0 = diam(i),
					d1 = diam(i + 1),
					t = i / ax.n,
					kind = ax.type,
					main = isMain,
					order = ax.order,
					axis = ax.id,
					room = room,
					under = below ~= nil,
				})
			end
			if room then
				table.insert(out.rooms, { number = roomNo :: number, vid = nd.vid, bottom = pos, room = room, stemR1 = diam(i + 1) / 2, main = isMain, axis = ax.id })
				if not isMain then
					out.climbAxes[ax.id] = true
				end
			end
			if isMain then
				table.insert(out.main, np)
				out.mainDiameter = math.max(out.mainDiameter, diam(i))
			end

			local atts = nd.atts
			local apex = i == ax.n - 1
			-- A sympodial fork: the tip ends in two or more shoots, spread evenly.
			local axesHere, hasFlower = 0, false
			for _, at in atts do
				if at.kind == "axis" then
					axesHere += 1
				elseif at.kind == "F" then
					hasFlower = true
				end
			end
			local fork = apex and not hasFlower and axesHere >= 2
			-- The terminal attachment carries the axis on, straight ahead.
			local term = 0
			if apex and not fork then
				for k, at in atts do
					if at.kind == "F" or (ax.type == "R" and at.kind == "T") then
						term = k
						break
					end
				end
				if term == 0 then
					for k, at in atts do
						if at.kind == "axis" then
							term = k
							break
						end
					end
				end
			end
			local lat = #atts - (if term > 0 then 1 else 0)
			local div = if lat <= 1 then (if g.phyllotaxis < 0.33 then math.pi else GOLDEN) elseif lat == 2 then math.pi / 2 else math.pi / lat
			local wv = d:Cross(u)
			local tpos = if ax.n > 1 then i / (ax.n - 1) else 0
			-- Off a room's roof, shoots and flower stalks start at its edge.
			local function sprout(o: Vector3): Vector3
				local of = if room then flat(o) else nil
				if not of then
					return np
				end
				local r = room :: Habitat.Room
				return np + of * Habitat.roofReach(r, roomLocal(r, of)) * 0.9
			end
			local li = 0
			for k, at in atts do
				local terminal = k == term
				local o: Vector3
				if ax.type == "R" then
					-- Leaflets pair off either side of the rachis, in its plane.
					local side = if lat == 1 then (if i % 2 == 1 then 1 else -1) else (if li % 2 == 1 then -1 else 1)
					o = wv * side
				else
					local az = az0 + i * div + li * TAU / math.max(1, lat)
					o = u * math.cos(az) + wv * math.sin(az)
				end
				if not terminal then
					li += 1
				end
				if at.kind == "L" or at.kind == "T" then
					local mL = math.clamp((p - b - plast * 0.3) / (span * 1.6), 0, 1)
					if mL > 0 then
						local leaflet = at.kind == "T"
						local elev = if leaflet then 1.0 elseif ax.type == "Z" then lerp(1.2, 1.45, g.leafDroop) else lerp(0.55, 1.2, g.leafDroop)
						local dir = if terminal then d else toward(d, o, elev)
						local L = if leaflet
							then leafLen0 * 0.42 * scale * (if terminal then 1.1 else lerp(1, 0.7, tpos))
							else leafLen0 * lerp(1.15, 0.6, tpos) * 0.75 ^ ax.order * (if ax.type == "Z" then 1.35 else 1)
						local lpos, stemD, sessile = np, diam(i + 1), leaflet
						local of = flat(o)
						if below and of then
							-- From the rounded belly of the room above, leaning a little down.
							local r = below :: Habitat.Room
							local y = r.round * 0.6
							local dx, dz = roomLocal(r, of)
							lpos = np + UP * y + of * (Habitat.surfaceReach(r, dx, dz, y) - r.wall * 0.5)
							dir = toward(UP, of, math.pi / 2 + 0.2)
							stemD, sessile = 0, true
						elseif room and of then
							-- From the room's rounded shoulder, just under the roof's edge,
							-- set into the shell (as on PlantBuilder's classic stem).
							local r = room :: Habitat.Room
							local y = r.coreHi + r.round * 0.45
							local dx, dz = roomLocal(r, of)
							lpos = pos + UP * y + of * (Habitat.surfaceReach(r, dx, dz, y) - r.wall * 0.5)
							dir = toward(UP, of, math.max(elev, math.pi / 2 - 0.5))
							stemD, sessile = 0, true
						end
						table.insert(out.leaves, { vid = at.vid, kind = at.kind, pos = lpos, dir = dir, len = L, maturity = mL, nodeT = tpos, stemD = stemD, sessile = sessile })
					end
				elseif at.kind == "F" then
					local fr = G.frank[at.vid] or 0
					local budStart = math.max(b + plast, Growth.BUD[1] + 0.12 * fr)
					local bud = phase(p, budStart, budStart + 0.12)
					if bud > 0 then
						local bloomStart = Growth.BLOOM[1] + 0.12 * fr
						local bloom = phase(p, bloomStart, bloomStart + 0.1)
						local umbel = ax.type == "I" and ax.n == 1
						local fscale = 0.8 ^ ax.order * (if ax.type == "I" then 0.7 else 1)
						local fpos, fdir, pedicel = np, d, nil
						local base = np
						if not terminal then
							base = sprout(o)
							local pdir = toward(d, o, if umbel then 0.97 else 0.95)
							local plen = if umbel then lerp(0.6, 1.4, g.flowerSize) else math.max(0.3, sInt * 0.35) * scale
							fpos = base + pdir * plen * (0.3 + 0.7 * bud)
							if g.petalCurl > 0.6 and not umbel then
								fdir = (pdir - UP * 0.9).Unit -- bells nod
							else
								fdir = (pdir + (if umbel then d else UP * 0.7)).Unit
							end
							pedicel = { a = base, b = fpos, d = 0.1 * fscale + 0.04 }
						end
						if avoidBoxes and not isMain and not roomAxes[ax.id] and inBox(avoidBoxes, fpos, Layout.AVOID_PAD) then
							continue -- it would open inside a room
						end
						table.insert(out.flowers, { vid = at.vid, pos = fpos, dir = fdir, scale = fscale, bud = bud, bloom = bloom, pedicel = pedicel, az = (at.vid % 6283) / 1000, top = isMain and terminal })
					end
				elseif at.axis and not (pruned and pruned[at.axis.vid]) then
					local ch = at.axis
					local nd2: Vector3
					if terminal then
						nd2 = toward(d, o, 0.06)
					elseif ch.type == "S" then
						local ang = lerp(0.35, 1.2, g.branchAngle) * (if fork then 0.7 else 1)
						nd2 = toward(d, o, if roomAxes[ch.id] then math.max(ang, 0.95) else ang)
					elseif ch.type == "I" then
						nd2 = toward(d, o, 0.75)
					elseif ch.type == "V" then
						nd2 = toward(d, o, 1.25)
					else
						nd2 = toward(d, o, if ax.type == "Z" then 1.3 else lerp(0.7, 1.2, g.leafDroop))
					end
					local nu = if ch.type == "R" then transport(UP, nd2) else transport(u, nd2)
					local sc = if ch.type == "R" then lerp(1.1, 0.65, tpos) * 0.8 ^ ax.order else 1
					walk(ch, if terminal then np else sprout(o), nd2, nu, sc)
				end
			end
			pos, prevD = np, d
		end
	end

	local function walkAll()
		out = newResult()
		out.veg = veg
		out.upright = main.type ~= "Z"
		walk(main, Vector3.zero, UP, Vector3.xAxis, 1)
	end

	if next(roomAxes) and plan then
		local vids = {}
		for vid, n in plan.rooms do
			table.insert(vids, vid * 8 + n)
		end
		table.sort(vids)
		local key = table.concat(vids, ",")
		local byPlan = stretches[G] or {}
		stretches[G] = byPlan
		local found = byPlan[key]
		if not found then
			-- Lay out the grown plant unstretched, then stretch each shoot just
			-- enough to clear its first room from the stem it grows from.
			local p0, swell0, veg0 = p, swell, veg
			p, swell, veg = 1, 1, 1
			roomOf = plan.rooms
			walkAll()
			local f: { [number]: number } = {}
			for _, R in out.rooms do
				local axisId = R.axis
				local ax = G.axes[axisId]
				local start = axisStart[axisId]
				if not R.main and start and roomAxes[axisId] and ax.nodes[roomAxes[axisId] + 1].vid == R.vid then
					local h = Vector2.new(R.bottom.X - start.X, R.bottom.Z - start.Z).Magnitude
					local need = Layout.roomReach(R.room) + R0 * 0.55 ^ math.max(ax.order - 1, 0) / 2 + 0.4
					f[axisId] = math.clamp(need / math.max(h, 0.05), 1, 5)
				end
			end
			found = f
			byPlan[key] = f
			p, swell, veg = p0, swell0, veg0
			roomOf = if swell then plan.rooms else nil
		end
		stretch = found
	end
	if plan and plan.yield and #plan.yield > 0 then
		local vids = {}
		for vid, n in plan.rooms do
			table.insert(vids, vid * 8 + n)
		end
		table.sort(vids)
		local key = table.concat(vids, ",") .. "|" .. boxKey(plan.yield)
		local byKey = leans[G] or {}
		leans[G] = byKey
		local found = byKey[key]
		if not found then
			local p0, swell0, veg0, roomOf0 = p, swell, veg, roomOf
			p, swell, veg = 1, 1, 1
			roomOf = if next(plan.rooms) then plan.rooms else nil
			local boxes = plan.yield
			local L: { [number]: { [number]: Vector3 } } = {}
			lean = L
			for _ = 1, Layout.YIELD_PASSES do
				trace = {}
				walkAll()
				local nodes = trace :: { any }
				trace = nil
				-- index the nodes of each axis, and find what must move
				local byAxis: { [number]: { [number]: any } } = {}
				for _, nd in nodes do
					byAxis[nd.axis] = byAxis[nd.axis] or {}
					byAxis[nd.axis][nd.i] = nd
				end
				-- one spot per axis each pass, the lowest: clearing it moves
				-- everything above, so the rest are looked at again next pass
				local done: { [number]: boolean } = {}
				table.sort(nodes, function(x, y)
					if x.axis ~= y.axis then
						return x.axis < y.axis
					end
					return x.i < y.i
				end)
				local moved = false
				for _, nd in nodes do
					if done[nd.axis] then
						continue
					end
					local push: Vector3
					local at: number -- the node whose end must move
					if nd.room then
						-- a room: its foot (the node before it) moves it clear
						local R = nd.room :: Habitat.Room
						push = clearOf(boxes, nd.a, Layout.roomReach(R), nd.a.Y, nd.a.Y + R.topY)
						at = nd.i - 1
					else
						local mid = (nd.a + nd.b) * 0.5
						push = clearOf(boxes, nd.b, nd.r, math.min(nd.a.Y, nd.b.Y), math.max(nd.a.Y, nd.b.Y))
						if push.Magnitude < 1e-4 then
							push = clearOf(boxes, mid, nd.r, mid.Y, mid.Y)
						end
						at = nd.i
					end
					if push.Magnitude > 1e-4 and at >= 0 then
						-- spread it over the plain stretches just below
						local list = byAxis[nd.axis]
						local free = {}
						local j = at
						while j >= 0 and #free < Layout.YIELD_WINDOW do
							local seg = list[j]
							if seg and not seg.room then
								table.insert(free, j)
							end
							j -= 1
						end
						done[nd.axis] = true
						if #free > 0 then
							moved = true
							local each = push / #free
							local axisLean = L[nd.axis] or {}
							L[nd.axis] = axisLean
							for _, k in free do
								axisLean[k] = (axisLean[k] or Vector3.zero) + each
							end
						end
					end
				end
				if not moved then
					break
				end
			end
			found = L
			byKey[key] = L
			p, swell, veg, roomOf = p0, swell0, veg0, roomOf0
		end
		lean = found
	end
	if plan and plan.avoid then
		-- Grow round rooms: other plants' (plan.avoid) and this plant's own,
		-- which stay where they are (no shoot carrying one ever turns).
		local boxes = table.clone(plan.avoid)
		if roomOf then
			walkAll()
			for _, R in out.rooms do
				local frame = Habitat.frameOf(CFrame.new(R.bottom), R.room)
				table.insert(boxes, { cf = frame, halfX = R.room.halfX, halfZ = R.room.halfZ, top = R.room.topY, own = true })
			end
		end
		avoidBoxes = if #boxes > 0 then boxes else nil
	end
	walkAll()
	return out
end

return Layout
