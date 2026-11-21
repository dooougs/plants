--!strict
--[[
	Rooms: where a building plant's rooms go, when its rooms may sit on any
	of its stems (Genome.roomsAnywhere), not only stacked up the main stem.

	Rooms are part of the grammar's skeleton: a room is a node of the
	derived plant (Derive) whose internode swells into a room, the same room
	PlantBuilder's classic stem grows (Habitat.room). Rooms can go on the
	main stem or on any side shoot growing from it (the shoots players can
	climb onto from the main stem), so one plant has a room high on its
	main stem and two out on its branches, another all of them in a row up
	the middle.

	  room 0      the ground hall, the main stem's first internode, when the
	              plant has one (homes always do)
	  rooms 1..   the "sites": nodes picked one at a time, mostly from the
	              bottom up, each kept only if it fits: clear of the other
	              rooms, the stems and (first time round) the leaves, and up
	              off the ground

	Rooms.sites lists up to MAX - 1 sites for a plant. A plant with n rooms
	above the ground uses the first n, so a home that grows a room keeps the
	rooms it had exactly where they were: a site is only ever checked against
	the rooms picked before it, and is never under one of them on its stem
	(it would push that room up).

	Everything is derived from the genome and seed, so every server and
	client puts the rooms in the same places.

	Salts used: 19 ground hall, 21 site order, 23 room count.
]]

local Habitat = require(script.Parent.Parent.Habitat)
local Derive = require(script.Parent.Derive)
local Layout = require(script.Parent.Layout)

local Rooms = {}

Rooms.MAX = 5 -- rooms in all, ground hall included (as many as a home grows)
Rooms.LIFT = 0.5 -- an upper room's floor is at least this far up (design studs), plus a share of its width

export type Sites = { number } -- node vids, room 1 first

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Whether a plant without a set room count (a wild one) has a ground hall.
function Rooms.hallFor(g: { [string]: number }, seed: number): boolean
	return g.habitat >= 0.99 or Derive.rng(seed, 1, 19):NextNumber() < Habitat.GROUND_HALL_CHANCE
end

-- How many rooms above the ground a wild building plant has: 1 to 4, more
-- on plants with more nodes.
function Rooms.countFor(g: { [string]: number }, seed: number): number
	local r = Derive.rng(seed, 1, 23):NextNumber()
	return 1 + math.floor((0.4 * g.nodes + 0.6 * r) * 3.999)
end

-- The node a node's axis grows from, up to the main axis: is `a` on the way
-- up to `b` (strictly below it on the same path)?
local function below(a: Derive.Node, b: Derive.Node): boolean
	local n: Derive.Node? = b
	local first = true
	while n do
		if n.axis == a.axis and (n.i > a.i or (not first and n.i == a.i)) then
			return true
		end
		first = false
		n = n.axis.parentNode
	end
	return false
end

local reachOf = Layout.roomReach

local function sample(a: Vector3, ctrl: Vector3, b: Vector3, u: number): Vector3
	return a * (1 - u) ^ 2 + ctrl * 2 * u * (1 - u) + b * u * u
end

-- Does the layout with these rooms fit? strict: leaves must keep out of the
-- newest room (vid `new`) too. If not, also returns the node whose stem or
-- leaf is in the way (nil when it was the ground or another room).
local function fits(L: Layout.Result, strict: boolean, new: number, nodeOf: { [number]: Derive.Node }, organNode: { [number]: number }): (boolean, Derive.Node?)
	for k, R in L.rooms do
		local room = R.room
		local rc = reachOf(room)
		local c = Vector2.new(R.bottom.X, R.bottom.Z)
		local y0, y1 = R.bottom.Y, R.bottom.Y + room.topY
		if not room.ground and y0 < Rooms.LIFT + 0.35 * rc then
			return false, nil -- too low: it would sit in the soil on any slope
		end
		local function inside(q: Vector3, pad: number): boolean
			return q.Y >= y0 and q.Y <= y1 and (Vector2.new(q.X, q.Z) - c).Magnitude < rc + pad
		end
		-- Other rooms (one stacked straight on another is fine).
		for k2 = k + 1, #L.rooms do
			local R2 = L.rooms[k2]
			local lo, hi = R2.bottom.Y, R2.bottom.Y + R2.room.topY
			local stacked = R2.axis == R.axis and math.abs(nodeOf[R2.vid].i - nodeOf[R.vid].i) == 1
			if not stacked and lo < y1 + Layout.ROOM_GAP and hi > y0 - Layout.ROOM_GAP then
				if (Vector2.new(R2.bottom.X, R2.bottom.Z) - c).Magnitude < rc + reachOf(R2.room) then
					return false, nil
				end
			end
		end
		-- What grows at the room's own node and the node under it is fitted
		-- to the room already (Layout); everything else keeps out.
		local node = nodeOf[R.vid]
		local ax = node.axis
		local under = ax.nodes[node.i] -- the node before it (1-based list), if any
		local above = ax.nodes[node.i + 2]
		local own = { [R.vid] = true, [if under then under.vid else -1] = true }
		for _, s in L.stems do
			if own[s.vid] or (above and s.vid == above.vid) then
				continue
			end
			local sn = nodeOf[s.vid]
			local sax = sn and sn.axis
			if sax and sax.parentNode and own[sax.parentNode.vid] and sn.i == 0 then
				continue -- the first stretch of a shoot leaving the roof's edge
			end
			for j = 1, 4 do
				if inside(sample(s.a, s.ctrl, s.b, j / 4), (s.d0 + s.d1) / 4) then
					return false, sn
				end
			end
		end
		if strict and R.vid == new then
			for _, lf in L.leaves do
				local ln = organNode[lf.vid]
				if own[ln or -1] then
					continue
				end
				for j = 1, 3 do
					if inside(lf.pos + lf.dir * lf.len * 0.9 * j / 3, 0) then
						return false, if ln then nodeOf[ln] else nil
					end
				end
			end
		end
	end
	return true, nil
end

export type Result = {
	sites: Sites,
	-- Shoots a room took the place of: axis vid -> the room (site number)
	-- that did, so a plant with fewer rooms keeps them.
	pruned: { [number]: number },
}

local cache: { [Derive.Graph]: { [string]: Result } } = setmetatable({}, { __mode = "k" }) :: any

Rooms.PRUNE = 3 -- side shoots a room may clear out of its way

--[[
	Up to MAX - 1 sites for the upper rooms of a plant, room 1 first (fewer
	if no more fit), and the side shoots they cleared away. hall: whether the
	main stem's first internode is a ground hall. lean (0..1): how strongly
	the plant puts its rooms out on side shoots rather than up the main stem.
	breathe: called between tries (may yield), for big plants built over
	several frames.

	A room in the way of a side shoot (one with no room on it or beyond it)
	may take its place: the shoot doesn't grow, as a gardener would prune a
	branch for a treehouse. At most PRUNE per room.
]]
function Rooms.sites(G: Derive.Graph, g: { [string]: number }, hall: boolean, lean: number, breathe: (() -> ())?): Result
	local key = (if hall then "h" else "-") .. string.format("%.3f", lean)
	local byKey = cache[G]
	if byKey and byKey[key] then
		return byKey[key]
	end
	local main = G.axes[1]
	local nodeOf: { [number]: Derive.Node } = {}
	for _, nd in G.nodes do
		nodeOf[nd.vid] = nd
	end
	local organNode: { [number]: number } = {}
	for _, o in G.organs do
		organNode[o.vid] = o.node.vid
	end

	-- Candidates: nodes on the main stem or a shoot straight off it (not the
	-- tip, which carries the flower), whose node below bears no flower (a
	-- shoot there is cleared away for the room).
	type Cand = { node: Derive.Node, key: number }
	local cands: { Cand } = {}
	for _, ax in G.axes do
		local onMain = ax == main
		if ax.type ~= "S" or not (onMain or (ax.order == 1 and ax.parent == main)) then
			continue
		end
		local first = if onMain and hall then 2 else 1
		for i = first, ax.n - 2 do
			local nd = ax.nodes[i + 1]
			local prev = ax.nodes[i]
			local plain = true
			for _, at in prev.atts do
				if at.kind == "F" then
					plain = false
					break
				end
			end
			if plain then
				-- Mostly bottom up, shuffled a little; a plant that leans out
				-- tries its side shoots first.
				local jitter = Derive.rng(G.seed, nd.vid, 21):NextNumber() * 2.5
				table.insert(cands, { node = nd, key = nd.t + jitter + (if onMain then 2 + lean * 8 else 0) })
			end
		end
	end
	table.sort(cands, function(a, b)
		if a.key ~= b.key then
			return a.key < b.key
		end
		return a.node.vid < b.node.vid
	end)

	local result: Result = { sites = {}, pruned = {} }
	local sites = result.sites
	local map: { [number]: number } = {}
	if hall then
		map[main.nodes[1].vid] = 0
	end
	local prunedSet: { [number]: boolean } = {}
	local taken: { Derive.Node } = {}
	local used: { [number]: boolean } = {}
	local function free(nd: Derive.Node): boolean
		if used[nd.vid] or prunedSet[nd.axis.vid] then
			return false
		end
		for _, t in taken do
			if below(nd, t) then
				return false -- would push a room already placed upward
			end
		end
		return true
	end
	-- A side shoot that may be cleared away: the one a node is on, or the
	-- order-1 shoot it belongs to, if no room is on it or beyond it.
	local function hasRoom(ax: Derive.Axis): boolean
		for _, nd in ax.nodes do
			if map[nd.vid] then
				return true
			end
			for _, at in nd.atts do
				if at.axis and hasRoom(at.axis) then
					return true
				end
			end
		end
		return false
	end
	local function prunableAxis(ax: Derive.Axis): boolean
		return ax ~= main and not prunedSet[ax.vid] and not hasRoom(ax)
	end
	local function prunable(nd: Derive.Node?): Derive.Axis?
		if nd and prunableAxis(nd.axis) then
			return nd.axis
		end
		return nil
	end
	-- Twice through: first keeping clear of leaves too, then of stems only.
	for _, strict in { true, false } do
		for _, c in cands do
			if #sites >= Rooms.MAX - 1 then
				break
			end
			if not free(c.node) then
				continue
			end
			if breathe then
				breathe()
			end
			map[c.node.vid] = #sites + 1
			local cleared: { number } = {}
			local ok = true
			-- Shoots on the node under the room would grow up its walls.
			local prev = c.node.axis.nodes[c.node.i]
			for _, at in prev.atts do
				if at.axis then
					if prunableAxis(at.axis) then
						prunedSet[at.axis.vid] = true
						table.insert(cleared, at.axis.vid)
					elseif not prunedSet[at.axis.vid] then
						ok = false
					end
				end
			end
			for _ = 0, if ok then Rooms.PRUNE else -1 do
				ok = false
				local L = Layout.layout(G, g, 1, { rooms = map, swell = 1, pruned = prunedSet })
				local fit, blocker = fits(L, strict, c.node.vid, nodeOf, organNode)
				if fit then
					ok = true
					break
				end
				local ax = prunable(blocker)
				if not ax then
					break
				end
				prunedSet[ax.vid] = true
				table.insert(cleared, ax.vid)
			end
			if ok then
				table.insert(sites, c.node.vid)
				table.insert(taken, c.node)
				used[c.node.vid] = true
				for _, v in cleared do
					result.pruned[v] = #sites
				end
			else
				map[c.node.vid] = nil
				for _, v in cleared do
					prunedSet[v] = nil
				end
			end
		end
	end

	byKey = cache[G] or {}
	byKey[key] = result
	cache[G] = byKey
	return result
end

-- How far a plant leans its rooms out onto side shoots (0..1), from its roomStems gene.
function Rooms.lean(g: { [string]: number }): number
	return math.clamp(lerp(0, 1, ((g.roomStems or 0) - 0.2) / 0.8), 0, 1)
end

return Rooms
