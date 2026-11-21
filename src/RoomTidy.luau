--[[
	RoomTidy: suggests a better arrangement for the pieces already in a room,
	by interior design rules (the decorate tools' ✨ Tidy button).

	After Merrell, Schkufza, Li, Agrawala and Koltun, "Interactive Furniture
	Layout Using Interior Design Guidelines" (SIGGRAPH 2011). A layout's cost
	is a weighted sum of guideline terms, and a Markov chain (Metropolis-
	Hastings: nudge a piece, turn a piece, swap two pieces, put a piece back to
	a wall) wanders toward cheaper layouts as it cools:

	  clearance     open floor in front of what needs it (a bed's side, a
	                bookcase's front) is kept clear of other pieces
	  circulation   the free floor stays one connected walkable space
	  pairwise      seats sit at their table and face it; lamps and chests
	                stand by beds and seats; tables stand on rugs
	  conversation  free seats sit a talking distance apart, facing each other
	  balance       the furniture's weight sits near the middle of the room
	  alignment     pieces stand square to the walls and to each other
	  emphasis      seats look at the room's focal point (a fire, a stage)
	  walls         pieces made for a wall keep their backs to one

	(Their weights are used as published where the term is the same.) Hard
	rules never break: every piece stays where RoomPlanner.fits allows (in the
	walls, off the stem's climbing hole, out of the door lane, not in another
	piece), so a suggestion is always a layout the owner could have made.

	Plain Lua, testable outside Roblox. Measurements are RoomPlanner's: normal
	studs on the room's floor, x out through the door, the stem at 0, 0.
]]

local RoomPlanner = require(script.Parent.RoomPlanner)

local RoomTidy = {}

RoomTidy.ITERATIONS = 4000
RoomTidy.WEIGHTS = {
	clearance = 2, circulation = 1, pairDistance = 2, pairAngle = 2,
	conversationDistance = 2, conversationAngle = 2, balance = 1.5,
	furnitureAlign = 2.5, wallAlign = 2.5, emphasis = 4, wall = 3, misfit = 25,
}

-- What each kind of piece is to the rules.
-- (Dining seats always look for a table; other seats gather for a chat.)
local DINING = { stool = true, dchair = true, dstool = true }
local ROLE = {
	stool = "seat", armchair = "seat", beanbag = "seat", bench = "seat",
	dchair = "seat", dstool = "seat", dbench = "seat",
	table = "table", roundTable = "table", teacup = "table", gameTable = "table", dtable = "table",
	bed = "bed", bunk = "bed", dbed = "bed", mossbed = "bed", hammock = "bed",
	chest = "side", lantern = "side", jars = "side", dlamp = "side", planter = "side", basket = "side",
	fireplace = "focal", stove = "focal", stage = "focal", telescope = "focal", board = "focal",
}
RoomTidy.ROLE = ROLE

local function angleOf(lx, lz)
	return math.atan2(lz, lx)
end

-- Merrell's t(d, m, M, a): 1 inside [m, M], falling off outside it.
local function within(d, m, M)
	if d < m then
		return (math.max(d, 0.01) / m) ^ 2
	elseif d > M then
		return (M / d) ^ 2
	end
	return 1
end

local function bodyOf(p)
	return RoomPlanner.box(p.x, p.z, p.lx, p.lz, p.w / 2 * p.s, p.d / 2 * p.s)
end

local function accessOf(p)
	local a = (p.access or 0) * p.s
	if a <= 0 or p.flat then
		return nil
	end
	local hd = p.d / 2 * p.s
	return RoomPlanner.box(p.x + p.lx * (hd + a / 2), p.z + p.lz * (hd + a / 2), p.lx, p.lz, p.w / 2 * p.s, a / 2)
end

-- Can piece i stand where it is, among the others?
local others = {}
local function fits(room, pieces, i)
	table.clear(others)
	for j, o in ipairs(pieces) do
		if j ~= i then
			table.insert(others, o)
		end
	end
	local ok = RoomPlanner.fits(room, pieces[i], others)
	table.clear(others)
	return ok
end

-- The free floor's connected pieces (Merrell's circulation term), on a
-- coarse grid: a person (radius `person`) fits in a cell if no standing
-- piece is closer.
local function regions(room, pieces, bodies)
	local g = 0.9
	local person = 0.55
	local nx, nz = math.floor(room.ax / g), math.floor(room.az / g)
	local free = {}
	local ring = room.stemKeep
	for i = -nx, nx do
		for j = -nz, nz do
			local x, z = i * g, j * g
			local ok = RoomPlanner.wallDistance(room, x, z) < -person and math.sqrt(x * x + z * z) > ring
			if ok then
				for k, b in ipairs(bodies) do
					if not pieces[k].flat and RoomPlanner.distanceTo(b, x, z) < person then
						ok = false
						break
					end
				end
			end
			if ok then
				free[i * 1000 + j] = true
			end
		end
	end
	local seen, count = {}, 0
	for key in free do
		if not seen[key] then
			count = count + 1
			local stack = { key }
			seen[key] = true
			while #stack > 0 do
				local k = table.remove(stack)
				for _, step in ipairs({ 1, -1, 1000, -1000 }) do
					local n = k + step
					if free[n] and not seen[n] then
						seen[n] = true
						table.insert(stack, n)
					end
				end
			end
		end
	end
	return count
end

-- The cost of a layout (lower is better), and its terms.
function RoomTidy.cost(room, pieces, focal)
	local W = RoomTidy.WEIGHTS
	local bodies, access = {}, {}
	for i, p in ipairs(pieces) do
		bodies[i] = bodyOf(p)
		access[i] = accessOf(p)
	end
	local terms = {}

	-- clearance: other standing pieces in a piece's access area
	local clear = 0
	for i, a in pairs(access) do
		for j, b in ipairs(bodies) do
			if i ~= j and not pieces[j].flat and RoomPlanner.overlaps(a, b, 0) then
				clear = clear + 1
			end
		end
	end
	terms.clearance = clear

	-- circulation: one walkable space
	terms.circulation = math.max(regions(room, pieces, bodies) - 1, 0)

	-- pairwise: seats to the nearest table, sides to beds and seats, tables to rugs
	local pd, pa = 0, 0
	local tables, beds, seats, rugs = {}, {}, {}, {}
	for i, p in ipairs(pieces) do
		local role = ROLE[p.id]
		if role == "table" then
			table.insert(tables, i)
		elseif role == "bed" then
			table.insert(beds, i)
		elseif role == "seat" then
			table.insert(seats, i)
		end
		if p.flat then
			table.insert(rugs, i)
		end
	end
	local atTable = {}
	for _, i in ipairs(seats) do
		local p = pieces[i]
		local best, bestD = nil, math.huge
		for _, t in ipairs(tables) do
			local d = RoomPlanner.distanceTo(bodies[t], p.x, p.z)
			if d < bestD then
				best, bestD = t, d
			end
		end
		if best and (bestD < 4 or DINING[p.id]) then
			atTable[i] = true
			pd = pd - within(bestD, 0.3, 1.4)
			local t = pieces[best]
			local dx, dz = t.x - p.x, t.z - p.z
			local len = math.sqrt(dx * dx + dz * dz)
			if len > 1e-3 then
				pa = pa - (p.lx * dx + p.lz * dz) / len
			end
		end
	end
	for _, p in ipairs(pieces) do
		if ROLE[p.id] == "side" then
			local best = math.huge
			for _, b in ipairs(beds) do
				best = math.min(best, RoomPlanner.distanceTo(bodies[b], p.x, p.z))
			end
			for _, s in ipairs(seats) do
				best = math.min(best, RoomPlanner.distanceTo(bodies[s], p.x, p.z) + 0.5)
			end
			if best < math.huge then
				pd = pd - within(best, 0, 1.2) * 0.5
			end
		elseif ROLE[p.id] == "table" and #rugs > 0 then
			local best = math.huge
			for _, r in ipairs(rugs) do
				best = math.min(best, math.sqrt((pieces[r].x - p.x) ^ 2 + (pieces[r].z - p.z) ^ 2))
			end
			pd = pd - within(best, 0, 0.8) * 0.5
		end
	end
	terms.pairDistance, terms.pairAngle = pd, pa

	-- conversation: seats not at a table
	local cd, ca = 0, 0
	for a = 1, #seats do
		for b = a + 1, #seats do
			local i, j = seats[a], seats[b]
			if not atTable[i] and not atTable[j] then
				local p, q = pieces[i], pieces[j]
				local dx, dz = q.x - p.x, q.z - p.z
				local d = math.sqrt(dx * dx + dz * dz)
				cd = cd - within(d, 4, 9)
				if d > 1e-3 then
					local c1 = (p.lx * dx + p.lz * dz) / d
					local c2 = -(q.lx * dx + q.lz * dz) / d
					ca = ca - (c1 + 1) * (c2 + 1) / 4
				end
			end
		end
	end
	terms.conversationDistance, terms.conversationAngle = cd, ca

	-- balance: area-weighted centre of the standing furniture near the room's
	local sx, sz, sa = 0, 0, 0
	for _, p in ipairs(pieces) do
		if not p.flat then
			local area = p.w * p.d * p.s * p.s
			sx, sz, sa = sx + p.x * area, sz + p.z * area, sa + area
		end
	end
	terms.balance = if sa > 0 then math.sqrt((sx / sa) ^ 2 + (sz / sa) ^ 2) / math.max(room.ax, room.az) else 0

	-- alignment: square to the nearest wall, and to each other
	local wa, fa = 0, 0
	for i, p in ipairs(pieces) do
		local nx, nz = RoomPlanner.wallFacing(room, p.x, p.z)
		local th = angleOf(p.lx, p.lz)
		wa = wa - math.cos(4 * (th - angleOf(nx, nz)))
		for j = i + 1, #pieces do
			local q = pieces[j]
			fa = fa - math.cos(4 * (th - angleOf(q.lx, q.lz))) * 0.25
		end
	end
	terms.wallAlign, terms.furnitureAlign = wa, fa

	-- emphasis: free seats look at the focal point
	local ef = 0
	if focal then
		for _, i in ipairs(seats) do
			if not atTable[i] then
				local p = pieces[i]
				local dx, dz = focal.x - p.x, focal.z - p.z
				local d = math.sqrt(dx * dx + dz * dz)
				if d > 1e-3 then
					ef = ef - (p.lx * dx + p.lz * dz) / d
				end
			end
		end
	end
	terms.emphasis = ef

	-- walls: wall pieces' backs against a wall
	local wl = 0
	for _, p in ipairs(pieces) do
		if p.place == "wall" or p.place == "window" then
			local hd = p.d / 2 * p.s
			local bx, bz = p.x - p.lx * hd, p.z - p.lz * hd
			wl = wl + math.min(math.abs(RoomPlanner.wallDistance(room, bx, bz)), 4)
			local nx, nz = RoomPlanner.wallFacing(room, p.x, p.z)
			local len = math.sqrt(nx * nx + nz * nz)
			if len > 1e-3 then
				wl = wl + (1 - (p.lx * nx + p.lz * nz) / len) * 0.5
			end
		end
	end
	terms.wall = wl

	-- pieces that stand where they couldn't be put (an old layout's): pushed out
	local mis = 0
	for i in ipairs(pieces) do
		if not fits(room, pieces, i) then
			mis = mis + 1
		end
	end
	terms.misfit = mis

	local total = W.clearance * terms.clearance + W.circulation * terms.circulation
		+ W.pairDistance * terms.pairDistance + W.pairAngle * terms.pairAngle
		+ W.conversationDistance * terms.conversationDistance + W.conversationAngle * terms.conversationAngle
		+ W.balance * terms.balance + W.wallAlign * terms.wallAlign + W.furnitureAlign * terms.furnitureAlign
		+ W.emphasis * terms.emphasis + W.wall * terms.wall + W.misfit * terms.misfit
	return total, terms
end

local function gauss(rng)
	local u = math.max(rng:NextNumber(), 1e-9)
	return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * rng:NextNumber())
end

local function copy(p)
	local out = {}
	for k, v in pairs(p) do
		out[k] = v
	end
	return out
end

-- Puts a piece back to the wall nearest it, facing into the room.
local function toWall(room, p)
	local nx, nz = RoomPlanner.wallFacing(room, p.x, p.z)
	local len = math.sqrt(nx * nx + nz * nz)
	if len < 1e-3 then
		return
	end
	nx, nz = nx / len, nz / len
	local hd = p.d / 2 * p.s
	-- slide out to the wall along -n, then back off by half the depth
	local d = RoomPlanner.wallDistance(room, p.x, p.z)
	p.x = p.x - nx * (-d - hd - RoomPlanner.GAP)
	p.z = p.z - nz * (-d - hd - RoomPlanner.GAP)
	p.lx, p.lz = nx, nz
end

-- pieces: { { key, id, x, z, lx, lz, w, d, h, s, flat, access, place } }
-- (Furniture.wantOf gives a piece's w, d, h, access and place).
-- Returns a new list (same order, keys kept) and how much better it is
-- (0 when nothing better was found). `pause` may yield between steps.
function RoomTidy.tidy(room, pieces, rng, pause)
	local cur = {}
	for i, p in ipairs(pieces) do
		cur[i] = copy(p)
	end
	local n = #cur
	if n == 0 then
		return cur, 0
	end
	local focal = nil
	for i, p in ipairs(cur) do
		if ROLE[p.id] == "focal" then
			focal = i
			break
		end
	end
	local function focalNow()
		return if focal then { x = cur[focal].x, z = cur[focal].z } else nil
	end
	local start = RoomTidy.cost(room, cur, focalNow())
	local curCost = start
	local best, bestCost = {}, start
	for i, p in ipairs(cur) do
		best[i] = copy(p)
	end
	local sigma = math.max(room.ax, room.az) * 0.18
	local iters = RoomTidy.ITERATIONS
	for it = 1, iters do
		if pause and it % 40 == 0 then
			pause()
		end
		local beta = 1.5 + 14 * (it / iters) -- cooling
		local move = rng:NextInteger(1, 5)
		local changed = {}
		local saved = {}
		local fitted = {}
		local function take(i)
			if not saved[i] then
				fitted[i] = fits(room, cur, i)
				saved[i] = copy(cur[i])
				table.insert(changed, i)
			end
		end
		local i = rng:NextInteger(1, n)
		if move == 1 then
			take(i)
			local s = sigma * (1 - 0.7 * it / iters)
			cur[i].x = cur[i].x + gauss(rng) * s
			cur[i].z = cur[i].z + gauss(rng) * s
		elseif move == 2 then
			take(i)
			local th = angleOf(cur[i].lx, cur[i].lz)
			if rng:NextNumber() < 0.5 then
				th = math.floor(th / (math.pi / 2) + 0.5 + (if rng:NextNumber() < 0.5 then 1 else -1)) * (math.pi / 2)
			else
				th = th + gauss(rng) * 0.5
			end
			cur[i].lx, cur[i].lz = math.cos(th), math.sin(th)
		elseif move == 3 then
			local j = rng:NextInteger(1, n)
			if j ~= i and (cur[i].flat == true) == (cur[j].flat == true) then
				take(i)
				take(j)
				local a, b = cur[i], cur[j]
				a.x, b.x = b.x, a.x
				a.z, b.z = b.z, a.z
				a.lx, b.lx = b.lx, a.lx
				a.lz, b.lz = b.lz, a.lz
			end
		elseif move == 4 and not fits(room, cur, i) then
			-- a piece standing where it shouldn't: try it somewhere else entirely
			take(i)
			cur[i].x = rng:NextNumber(-room.ax, room.ax)
			cur[i].z = rng:NextNumber(-room.az, room.az)
			if cur[i].place == "wall" or cur[i].place == "window" then
				toWall(room, cur[i])
			end
		else
			-- back to a wall: pick one of the wall pieces
			local walls = {}
			for k, p in ipairs(cur) do
				if p.place == "wall" or p.place == "window" then
					table.insert(walls, k)
				end
			end
			if #walls > 0 then
				local k = walls[rng:NextInteger(1, #walls)]
				take(k)
				toWall(room, cur[k])
				-- and slide it along the wall a little
				local tx, tz = -cur[k].lz, cur[k].lx
				local slide = gauss(rng) * sigma
				cur[k].x = cur[k].x + tx * slide
				cur[k].z = cur[k].z + tz * slide
			end
		end
		if #changed > 0 then
			local ok = true
			for _, k in ipairs(changed) do
				-- never break a rule a piece kept (a misfit may move anywhere)
				if fitted[k] and not fits(room, cur, k) then
					ok = false
					break
				end
			end
			local newCost = if ok then RoomTidy.cost(room, cur, focalNow()) else math.huge
			if ok and (newCost <= curCost or rng:NextNumber() < math.exp(-beta * (newCost - curCost))) then
				curCost = newCost
				if newCost < bestCost then
					bestCost = newCost
					for k, p in ipairs(cur) do
						best[k] = copy(p)
					end
				end
			else
				for _, k in ipairs(changed) do
					cur[k] = saved[k]
				end
			end
		end
	end
	-- face each piece a whole number of degrees and snap it to tenths, as
	-- RoomFurniture stores it; a piece the snap would push into another
	-- keeps its old place
	for i, p in ipairs(best) do
		local keep = copy(p)
		local deg = math.floor(math.deg(angleOf(p.lx, p.lz)) + 0.5)
		p.lx, p.lz = math.cos(math.rad(deg)), math.sin(math.rad(deg))
		p.x = math.floor(p.x * 10 + 0.5) / 10
		p.z = math.floor(p.z * 10 + 0.5) / 10
		if not fits(room, best, i) then
			best[i] = keep
		end
	end
	local final = RoomTidy.cost(room, best, if focal then { x = best[focal].x, z = best[focal].z } else nil)
	return best, math.max(start - final, 0)
end

return RoomTidy
