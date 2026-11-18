--[[
	RoomPlanner: lays out the furniture of one building-plant room.

	A room's floor (seen from above) is a rounded rectangle with the plant's
	stem standing in the middle of it. Above the ground the stem comes up
	through a climbing hole in the floor, and you climb in and out of the room
	there. So the planner keeps, besides the walls:

	  - a ring of bare floor round the stem and its hole (WALK wide), so you
	    can always step off the stem onto the floor and grab it again;
	  - a lane from the stem out through the door;
	  - the windows clear of anything taller than their sills, and the wall
	    lamps clear of tall pieces.

	Every piece is a rectangle on the floor (its footprint) with a front, and
	most want some open floor in front of them (their access: room to get into
	a bed or reach a shelf). Pieces may not overlap each other, nor anyone's
	access. Flat pieces (rugs) only avoid the hole and each other: tables and
	chairs stand on them.

	Each piece says how it likes to stand:
	  wall   - back to a wall (or, with `along`, its side), scored by which wall
	           and how close to a corner it likes to be;
	  window - in front of a window, looking out (a telescope, a window box);
	  free   - out in the room, between the stem ring and the walls, facing the
	           stem or the piece named in `facing`; `sideways` also tries a quarter turn;
	and may want to be `near` another kind of piece (a chest by its bed, a
	table on its rug). Tables bring `seats` that ring them afterwards.

	Pieces go in the order given, each to its best scoring spot, shrinking a
	little (SCALES) if it fits nowhere and skipped if it still doesn't. Then
	fillers (pot plants, jars, baskets...) go in the biggest gaps left, so no
	room looks empty. A seeded Random breaks ties, so every room grows its own
	layout but the same room always grows the same one.

	All measurements are normal Roblox studs (the room's unit of 1), on the
	room's floor: x out through the door (+), z across it. A layout entry's
	look (lx, lz) is the way its front faces.

	Written in plain Lua (no type annotations or compound assignment) so the
	layout can be tested outside Roblox.
]]

local RoomPlanner = {}

RoomPlanner.WALK = 1.8 -- bare floor kept round the stem's hole, for climbing on and off
RoomPlanner.GAP = 0.15 -- between a piece's back and the wall
RoomPlanner.SPACING = 0.12 -- between two pieces
RoomPlanner.SCALES = { 1, 0.88, 0.76, 0.64 }
RoomPlanner.STEP = 0.5 -- spacing of the spots tried along a wall
RoomPlanner.GRID = 0.7 -- spacing of the spots tried out in the room
RoomPlanner.DOOR_LANE = 1.1 -- added each side of the doorway, for the lane to the stem
RoomPlanner.WINDOW_DEPTH = 2.4 -- how far out from a window tall pieces keep away
RoomPlanner.LAMP_DEPTH = 2.8 -- how far out from the back wall the lamps reach
RoomPlanner.FLOOR_PER_PIECE = 55 -- square studs of floor per standing piece, for the fill target
RoomPlanner.FILL_REPEAT = 2 -- at most this many of one filler

local DEFAULT_WALLS = { back = 1, left = 0.9, right = 0.9, front = 0.45 }

local function clamp(x, lo, hi)
	if x < lo then
		return lo
	end
	if x > hi then
		return hi
	end
	return x
end

---------------------------------------------------------------- shapes

-- A rectangle on the floor: centre, half sizes, and its two axes. U is the
-- piece's right (width hw), V its back (depth hd); look = -V is its front.
local function box(cx, cz, lx, lz, hw, hd)
	return { cx = cx, cz = cz, ux = -lz, uz = lx, vx = -lx, vz = -lz, hw = hw, hd = hd }
end
RoomPlanner.box = box

local function aabb(x0, z0, x1, z1)
	return { cx = (x0 + x1) / 2, cz = (z0 + z1) / 2, ux = 1, uz = 0, vx = 0, vz = 1, hw = (x1 - x0) / 2, hd = (z1 - z0) / 2 }
end

local function cornersOf(b)
	local out = {}
	for _, su in ipairs({ -1, 1 }) do
		for _, sv in ipairs({ -1, 1 }) do
			table.insert(out, {
				b.cx + b.ux * b.hw * su + b.vx * b.hd * sv,
				b.cz + b.uz * b.hw * su + b.vz * b.hd * sv,
			})
		end
	end
	return out
end
RoomPlanner.corners = cornersOf

local function radiusOn(b, ax, az)
	return b.hw * math.abs(b.ux * ax + b.uz * az) + b.hd * math.abs(b.vx * ax + b.vz * az)
end

local function separated(a, b, dx, dz, ax, az, pad)
	return math.abs(dx * ax + dz * az) >= radiusOn(a, ax, az) + radiusOn(b, ax, az) + pad
end

-- Do two rectangles overlap (closer than pad)? Separating axis test.
local function overlaps(a, b, pad)
	pad = pad or 0
	local dx, dz = b.cx - a.cx, b.cz - a.cz
	return not (
		separated(a, b, dx, dz, a.ux, a.uz, pad)
		or separated(a, b, dx, dz, a.vx, a.vz, pad)
		or separated(a, b, dx, dz, b.ux, b.uz, pad)
		or separated(a, b, dx, dz, b.vx, b.vz, pad)
	)
end
RoomPlanner.overlaps = overlaps

-- Distance from a point to a rectangle (0 inside).
local function distanceTo(b, x, z)
	local dx, dz = x - b.cx, z - b.cz
	local pu = dx * b.ux + dz * b.uz
	local pv = dx * b.vx + dz * b.vz
	local eu = math.max(math.abs(pu) - b.hw, 0)
	local ev = math.max(math.abs(pv) - b.hd, 0)
	return math.sqrt(eu * eu + ev * ev)
end
RoomPlanner.distanceTo = distanceTo

-- Signed distance from a point to the room's inner walls (negative inside).
local function wallDistance(room, x, z)
	local qx = math.abs(x) - (room.ax - room.rc)
	local qz = math.abs(z) - (room.az - room.rc)
	local ox, oz = math.max(qx, 0), math.max(qz, 0)
	return math.sqrt(ox * ox + oz * oz) + math.min(math.max(qx, qz), 0) - room.rc
end
RoomPlanner.wallDistance = wallDistance

-- Inward normal of the nearest wall, including the rounded corners.
function RoomPlanner.wallFacing(room, x, z)
	local qx = math.abs(x) - (room.ax - room.rc)
	local qz = math.abs(z) - (room.az - room.rc)
	local nx = if x >= 0 then -1 else 1
	local nz = if z >= 0 then -1 else 1
	if qx > 0 and qz > 0 then
		return nx * qx, nz * qz
	elseif qx >= qz then
		return nx, 0
	end
	return 0, nz
end

local function insideRoom(room, b, margin)
	for _, p in ipairs(cornersOf(b)) do
		if wallDistance(room, p[1], p[2]) > -margin then
			return false
		end
	end
	return true
end

---------------------------------------------------------------- the room

-- The walls, each with the way into the room from it (n) and the way along it (t).
local function wallsOf(room)
	return {
		{ name = "back", nx = 1, nz = 0, tx = 0, tz = 1, px = -room.ax, pz = 0, half = room.az },
		{ name = "front", nx = -1, nz = 0, tx = 0, tz = 1, px = room.ax, pz = 0, half = room.az },
		{ name = "left", nx = 0, nz = 1, tx = 1, tz = 0, px = 0, pz = -room.az, half = room.ax },
		{ name = "right", nx = 0, nz = -1, tx = 1, tz = 0, px = 0, pz = room.az, half = room.ax },
	}
end

-- Floor no piece may stand on (taller than maxH): the door lane, the
-- windows (above their sills) and the lamps.
local function zonesOf(room)
	local zones = {}
	local lane = room.doorHalf + (room.doorLane or RoomPlanner.DOOR_LANE)
	table.insert(zones, { box = aabb(0, -lane, room.ax + 1, lane), maxH = -1 })
	local walls = wallsOf(room)
	for _, w in ipairs(room.windows or {}) do
		for _, wall in ipairs(walls) do
			if wall.name == w.wall then
				local d = RoomPlanner.WINDOW_DEPTH
				local x0 = wall.px + wall.tx * -w.half - wall.nx * 1
				local z0 = wall.pz + wall.tz * -w.half - wall.nz * 1
				local x1 = wall.px + wall.tx * w.half + wall.nx * d
				local z1 = wall.pz + wall.tz * w.half + wall.nz * d
				table.insert(zones, {
					box = aabb(math.min(x0, x1), math.min(z0, z1), math.max(x0, x1), math.max(z0, z1)),
					maxH = w.sill - 0.2,
					window = w,
				})
			end
		end
	end
	for _, l in ipairs(room.lamps or {}) do
		table.insert(zones, { box = aabb(-room.ax - 1, l.z - 1.5, -room.ax + RoomPlanner.LAMP_DEPTH, l.z + 1.5), maxH = l.low })
	end
	return zones
end

---------------------------------------------------------------- planning

-- room: { ax, az (inner half sizes), rc (inner corner radius), stemKeep
--         (radius kept free for the stem and its hole), doorHalf, ceiling,
--         windows = { { wall, half, sill } }, lamps = { { z, low } },
--         reserved = optional boxes for fixtures and their approaches,
--         walk, doorLane, spacing = optional overrides for public rooms }
-- wants: ordered list of pieces to place:
--   { id, w, d, h, place = "wall"|"window"|"free", walls = { back = 1, ... },
--     corner (liking for wall ends, -1..1), access (open floor in front),
--     along (may stand side-on to a wall), flat, near = id, facing = id or facePoint = { x, z },
--     flip (face away from `facing`), faceDist, seats = { id, w, d, h, n } }
-- fill: list of filler wants (or functions making one), tried in the gaps afterwards.
-- Returns { { want, x, z, lx, lz, s, seatOf } }.
function RoomPlanner.plan(room, wants, fill, rng, pause: (() -> ())?)
	local ring = room.stemKeep + (room.walk or RoomPlanner.WALK)
	local spacing = room.spacing or RoomPlanner.SPACING
	local reserved = room.reserved or {}
	local zones = zonesOf(room)
	local walls = wallsOf(room)
	local placed = {}
	local layout = {}

	local function valid(want, body, access, s, host)
		if want.h * s > room.ceiling then
			return false
		end
		if not insideRoom(room, body, 0.02) then
			return false
		end
		if want.flat then
			if distanceTo(body, 0, 0) < room.stemKeep + 0.3 then
				return false
			end
			for _, p in ipairs(placed) do
				if p.flat and overlaps(body, p.body, 0.3) then
					return false
				end
			end
			-- rugs keep out of the doorway lane too, so what stands on them can
			return not overlaps(body, zones[1].box)
		end
		if distanceTo(body, 0, 0) < ring then
			return false
		end
		for _, obstacle in ipairs(reserved) do
			if overlaps(body, obstacle) or (access and overlaps(access, obstacle)) then
				return false
			end
		end
		for _, z in ipairs(zones) do
			if want.h * s > z.maxH and not (want.place == "window" and z.window) and overlaps(body, z.box) then
				return false
			end
		end
		for _, p in ipairs(placed) do
			-- a seat's own table is round it by construction
			if not p.flat and p ~= host then
				if overlaps(body, p.body, spacing) then
					return false
				end
				if p.access and overlaps(body, p.access) then
					return false
				end
				if access and overlaps(access, p.body) then
					return false
				end
			end
		end
		if access and not insideRoom(room, access, -0.4) then
			return false
		end
		return true
	end

	-- Nearest placed piece of kind id to a point, and its distance.
	local function nearest(id, x, z)
		local best, bestD = nil, math.huge
		for _, p in ipairs(placed) do
			if p.want.id == id then
				local d = math.sqrt((p.x - x) ^ 2 + (p.z - z) ^ 2)
				if d < bestD then
					best, bestD = p, d
				end
			end
		end
		return best, bestD
	end

	-- How far a body is from every other standing piece (capped): fillers and
	-- most wall pieces like a bit of room round them.
	local function spread(body)
		local best = 4
		for _, p in ipairs(placed) do
			if not p.flat then
				local d = math.min(distanceTo(p.body, body.cx, body.cz), 4)
				if d < best then
					best = d
				end
			end
		end
		return best
	end

	local function makeAccess(want, cx, cz, lx, lz, hw, hd, s)
		local a = (want.access or 0) * s
		if a <= 0 then
			return nil
		end
		return box(cx + lx * (hd + a / 2), cz + lz * (hd + a / 2), lx, lz, hw, a / 2)
	end

	-- Every spot a piece could stand at scale s: { x, z, lx, lz, score }.
	local function candidates(want, s)
		local out = {}
		local hw, hd = want.w / 2 * s, want.d / 2 * s
		local prefs = want.walls or DEFAULT_WALLS
		local function add(x, z, lx, lz, score, bw, bd)
			table.insert(out, { x = x, z = z, lx = lx, lz = lz, score = score, hw = bw or hw, hd = bd or hd })
		end
		if want.place == "wall" or want.place == "window" then
			for _, wall in ipairs(walls) do
				local pref = prefs[wall.name] or 0
				local windowAt = nil
				for _, w in ipairs(room.windows or {}) do
					if w.wall == wall.name then
						windowAt = w
					end
				end
				if want.place == "window" then
					if windowAt then
						for _, t in ipairs({ -0.4, 0, 0.4 }) do
							local off = hd + RoomPlanner.GAP
							add(wall.px + wall.tx * t + wall.nx * off, wall.pz + wall.tz * t + wall.nz * off, wall.nx, wall.nz, pref + 1)
						end
					end
				elseif pref > 0 then
					local steps = math.floor(wall.half / RoomPlanner.STEP)
					for k = -steps, steps do
						if pause and k % 16 == 0 then
							pause()
						end
						local t = k * RoomPlanner.STEP
						local ends = math.abs(t) / wall.half
						local base = pref + (want.corner or 0) * ends
						-- back to the wall, looking into the room
						local off = hd + RoomPlanner.GAP
						add(wall.px + wall.tx * t + wall.nx * off, wall.pz + wall.tz * t + wall.nz * off, wall.nx, wall.nz, base)
						if want.along then
							-- side to the wall, looking along it (its width now runs out from the wall)
							local offA = hw + RoomPlanner.GAP
							for _, sgn in ipairs({ -1, 1 }) do
								add(wall.px + wall.tx * t + wall.nx * offA, wall.pz + wall.tz * t + wall.nz * offA, wall.tx * sgn, wall.tz * sgn, base + 0.05)
							end
						end
					end
				end
			end
		else
			local g = RoomPlanner.GRID
			local nx, nz = math.floor(room.ax / g), math.floor(room.az / g)
			local mid = (ring + math.min(room.ax, room.az)) / 2
			for i = -nx, nx do
				if pause then
					pause()
				end
				for j = -nz, nz do
					local x, z = i * g, j * g
					local r = math.sqrt(x * x + z * z)
					if r > 1e-3 then
						local lx, lz = -x / r, -z / r
						-- out in open floor, halfway between the stem ring and the walls
						local open = math.min(-wallDistance(room, x, z), 6)
						local score = -math.abs(r - mid) * 0.3 + open * (want.flat and 0.45 or 0.25)
						if want.flat then
							-- rugs lie square to the room, longer side across the longer floor
							lx, lz = 1, 0
							if math.abs(z) > math.abs(x) then
								lx, lz = 0, 1
							end
						end
						add(x, z, lx, lz, score)
						if want.sideways then
							add(x, z, -lz, lx, score)
						end
					end
				end
			end
		end
		return out
	end

	local function scoreOf(want, c, body)
		local score = c.score + rng:NextNumber() * 0.6
		if want.near then
			local p, d = nearest(want.near, c.x, c.z)
			if p then
				score = score - d * (want.nearWeight or 0.6)
			end
		end
	if c.faceD then
			score = score - math.abs(c.faceD - (want.faceDist or 4)) * 0.8
		end
		if want.place ~= "free" and not want.near then
			score = score + spread(body) * 0.25
		end
		return score
	end

	local function record(want, c, body, access, s, seatOf)
		local p = { want = want, x = c.x, z = c.z, lx = c.lx, lz = c.lz, body = body, access = access, flat = want.flat, s = s }
		table.insert(placed, p)
		table.insert(layout, { want = want, x = c.x, z = c.z, lx = c.lx, lz = c.lz, s = s, seatOf = seatOf })
		return p
	end

	-- Ring seats round a placed table, facing it.
	local function seat(host, hostWant, hs)
		local seatWant = hostWant.seats
		local n = rng:NextInteger(seatWant.n[1], seatWant.n[2])
		local start = rng:NextNumber() * math.pi * 2
		local sr = math.max(seatWant.w, seatWant.d) / 2 * hs
		local reach = math.max(host.body.hw, host.body.hd) + sr + 0.35 * hs
		for i = 0, n - 1 do
			local a = start + i / n * math.pi * 2
			local x, z = host.x + math.cos(a) * reach, host.z + math.sin(a) * reach
			local lx, lz = -math.cos(a), -math.sin(a)
			local body = box(x, z, lx, lz, seatWant.w / 2 * hs, seatWant.d / 2 * hs)
			if valid(seatWant, body, nil, hs, host) then
				record(seatWant, { x = x, z = z, lx = lx, lz = lz }, body, nil, hs, host)
			end
		end
	end

	local function place(want, scales)
		for _, s in ipairs(scales) do
			if pause then
				pause()
			end
			local best, bestScore = nil, -math.huge
			local cands = candidates(want, s)
			local target = want.facePoint
			if want.facing then
				target = nearest(want.facing, 0, 0)
			end
			for i, c in ipairs(cands) do
				if pause and i % 16 == 0 then
					pause()
				end
				if target then
					local dx, dz = target.x - c.x, target.z - c.z
					local d = math.sqrt(dx * dx + dz * dz)
					if d > 1e-3 then
						local sgn = want.flip and -1 or 1
						c.lx, c.lz = dx / d * sgn, dz / d * sgn
						c.faceD = d
					end
				end
				local body = box(c.x, c.z, c.lx, c.lz, c.hw, c.hd)
				local access = makeAccess(want, c.x, c.z, c.lx, c.lz, c.hw, c.hd, s)
				if valid(want, body, access, s) then
					local score = scoreOf(want, c, body)
					if score > bestScore then
						best, bestScore = { c = c, body = body, access = access }, score
					end
				end
			end
			if best then
				local p = record(want, best.c, best.body, best.access, s)
				if want.seats then
					seat(p, want, s)
				end
				return true
			end
		end
		return false
	end

	for _, want in ipairs(wants) do
		place(want, want.scales or RoomPlanner.SCALES)
	end

	-- Fill the gaps so the room never looks bare.
	if fill and #fill > 0 then
		local floor = 4 * room.ax * room.az - math.pi * ring * ring
		local target = clamp(math.floor(floor / RoomPlanner.FLOOR_PER_PIECE), 4, 12)
		local used = {}
		local standing = 0
		for _, p in ipairs(placed) do
			if not p.flat then
				standing = standing + 1
			end
		end
		local tries = 0
		while standing < target and tries < #fill * 2 + 4 do
			tries = tries + 1
			local want = fill[rng:NextInteger(1, #fill)]
			if type(want) == "function" then
				want = want()
			end
			if want and (used[want.id] or 0) < RoomPlanner.FILL_REPEAT and place(want, { 1, 0.8 }) then
				standing = standing + 1
				used[want.id] = (used[want.id] or 0) + 1
			end
		end
	end

	return layout
end

---------------------------------------------------------------- owners placing

-- Can a piece its owner is putting down stand here (Client.DecorateClient)?
-- Owners may put things where the planner wouldn't (in front of a window,
-- by a lamp), but a piece must stay inside the walls, off the stem's
-- climbing hole and out of the lane to the door, and not stand in another
-- piece (rugs only mind other rugs).
-- piece, others: { x, z, lx, lz, w, d, h, s, flat }. Returns ok, why.
function RoomPlanner.fits(room, piece, others)
	local body = box(piece.x, piece.z, piece.lx, piece.lz, piece.w / 2 * piece.s, piece.d / 2 * piece.s)
	if piece.h * piece.s > room.ceiling + 0.5 then
		return false, "too tall"
	end
	if not insideRoom(room, body, 0.02) then
		return false, "wall"
	end
	if distanceTo(body, 0, 0) < room.stemKeep + (piece.flat and 0.3 or 0.6) then
		return false, "stem"
	end
	if not piece.flat and overlaps(body, zonesOf(room)[1].box) then
		return false, "door"
	end
	for _, o in ipairs(others) do
		if (o.flat == true) == (piece.flat == true) then
			local ob = box(o.x, o.z, o.lx, o.lz, o.w / 2 * o.s, o.d / 2 * o.s)
			if overlaps(body, ob, 0) then
				return false, "piece"
			end
		end
	end
	return true, nil
end

return RoomPlanner
