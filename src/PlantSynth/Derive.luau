--!strict
--[[
	Derive: grows a plant's skeleton from the grammar (Rules), once per genome.

	The skeleton is a tree of axes (shoots, rosettes, racemes, fronds, vines),
	each a list of nodes, each node carrying organs (leaves, flowers,
	leaflets) and child axes. It is derived for the adult plant only; growth
	stages reveal it node by node (Layout), so a plant never reshuffles as it
	grows, and every detail level builds on the same skeleton.

	Determinism: every node and organ has a stable id from its parent's id and
	its slot (vidOf), and every random choice is drawn from
	Random.new(seed + salt * 104729 + id * 7919), the same formula as
	PlantBuilder's plantRng. The same genome gives the same plant on every
	server and client, and a choice at one node never shifts another's.

	Salts used: 3 node star, 11 axis length (Layout uses 1, 2 and 977, Organs 5).
]]

local Rules = require(script.Parent.Rules)

local Derive = {}

local PRIME = 2147483647
local BUDGET = 900 -- nodes and organs; past this no more side shoots

export type Organ = { vid: number, kind: string, node: Node }
export type Attachment = { vid: number, kind: string, axis: Axis? }
export type Node = {
	vid: number,
	i: number, -- 0 based along its axis
	zone: string,
	sig: string,
	radius: number, -- context used: 1 label|zone|prev, 0 label|zone, -1 label|*, -2 forced
	t: number, -- birth order (plastochrons from the seed)
	atts: { Attachment },
	axis: Axis,
}
export type Axis = {
	id: number,
	type: string,
	order: number,
	label: string,
	parentType: string?,
	vid: number,
	n: number,
	nodes: { Node },
}
export type Graph = {
	seed: number,
	axes: { Axis },
	nodes: { Node },
	organs: { Organ },
	Tmax: number,
	frank: { [number]: number }, -- flower id -> 0 first to open .. 1 last
	stats: { r1: number, r0: number, rz: number, forced: number },
}

function Derive.vidOf(parent: number, slot: number): number
	return (parent * 33 + slot * 7919 + 17) % PRIME
end

function Derive.rng(seed: number, vid: number, salt: number): Random
	return Random.new((seed + salt * 104729 + vid * 7919) % PRIME)
end

-- How many leaves a node wants (the phyllotaxis genes, as in PlantBuilder.growAxis).
local function leafTarget(g): number
	if g.phyllotaxis < 0.33 then
		return 1
	elseif g.phyllotaxis < 0.66 then
		return 2
	end
	return 1 + math.floor(g.leafPerNode * 2.99)
end

-- Genes lean on the grammar's choices: branching favours side shoots,
-- phyllotaxis the number of leaves per node, flowersPerTip flower clusters.
local function geneBias(c: Rules.Candidate, g): number
	local n = c.n
	local w = math.max(0.03, g.branching * 2) ^ n.S
	if n.L > 0 then
		w *= math.exp(-1.1 * math.abs(n.L - leafTarget(g)))
	end
	if n.F > 1 then
		w *= (0.5 + g.flowersPerTip) ^ (n.F - 1)
	end
	w *= (0.4 + g.flowersPerTip * 1.2) ^ n.I
	return w
end

function Derive.derive(g: { [string]: number }, seed: number, G: Rules.Grammar): Graph
	local graph: Graph = {
		seed = seed,
		axes = {},
		nodes = {},
		organs = {},
		Tmax = 0,
		frank = {},
		stats = { r1 = 0, r0 = 0, rz = 0, forced = 0 },
	}
	local count = 0
	local rootType = if G.roots.Z and (g.form < 0.3 or not G.roots.S) then "Z" elseif G.roots.S then "S" else "Z"

	local function axisLen(kind: string, order: number, label: string, vid: number): number
		if kind == "S" and order == 0 then
			return 3 + math.floor(g.nodes * 9) -- PlantBuilder's main stem
		elseif kind == "Z" then
			return 6 + math.floor(g.nodes * 14) -- PlantBuilder's rosette
		end
		local obs = G.lengths[label] or { 3 }
		local L = obs[Derive.rng(seed, vid, 11):NextInteger(1, #obs)]
		if kind == "S" then
			L = math.floor(L * (0.6 + g.nodes * 0.8) + 0.5)
		elseif kind == "I" and L > 1 then
			L = math.floor(L * (0.6 + g.flowersPerTip * 0.8) + 0.5)
		end
		return math.max(1, L)
	end

	local function allowed(c: Rules.Candidate, kind: string, order: number, apex: boolean): boolean
		local n = c.n
		if n.S > 0 and (order >= 2 or count > BUDGET) then
			return false
		end
		if n.V > 0 and kind == "V" then
			return false
		end
		if kind == "R" and (n.S + n.R + n.I + n.L) > 0 then
			return false -- a frond carries leaflets only
		end
		-- Every shoot ends in a flower, or hands over to another axis.
		if apex and (kind == "S" or kind == "Z" or kind == "V") and n.F + n.I + n.S == 0 then
			return false
		end
		return true
	end

	local grow: (string, number, number, number, string?) -> Axis
	function grow(kind: string, order: number, vid: number, t0: number, parentType: string?): Axis
		local label = Rules.labelOf(kind, order)
		local ax: Axis = { id = #graph.axes + 1, type = kind, order = order, label = label, parentType = parentType, vid = vid, n = 0, nodes = {} }
		table.insert(graph.axes, ax)
		local n = axisLen(kind, order, label, vid)
		ax.n = n
		local prev = "^"
		for i = 0, n - 1 do
			local nvid = Derive.vidOf(vid, i + 1)
			local z = Rules.zoneOf(i, n)
			local apex = i == n - 1
			local cands: { Rules.Candidate } = {}
			local radius = -2
			for _, key in { { label .. "|" .. z .. "|" .. prev, 1 }, { label .. "|" .. z, 0 }, { label .. "|*", -1 } } do
				local list = G.ctx[key[1] :: string]
				if list then
					for _, c in list do
						if allowed(c, kind, order, apex) then
							table.insert(cands, c)
						end
					end
					if #cands > 0 then
						radius = key[2] :: number
						break
					end
				end
			end
			local atts: { string }
			local sig: string
			if #cands > 0 then
				local weights, total = {}, 0
				for k, c in cands do
					weights[k] = c.w * geneBias(c, g)
					total += weights[k]
				end
				local pick = 1
				if total > 0 then
					local x = Derive.rng(seed, nvid, 3):NextNumber() * total
					while pick < #cands and x >= weights[pick] do
						x -= weights[pick]
						pick += 1
					end
				end
				atts, sig = cands[pick].atts, cands[pick].sig
			else
				-- Nothing the examples showed fits here: close the axis simply.
				atts = if apex and kind ~= "R" then { "F" } elseif apex then { "T" } else {}
				sig = if #atts > 0 then table.concat(atts) else "-"
			end
			if radius == 1 then
				graph.stats.r1 += 1
			elseif radius == 0 then
				graph.stats.r0 += 1
			elseif radius == -1 then
				graph.stats.rz += 1
			else
				graph.stats.forced += 1
			end
			local node: Node = { vid = nvid, i = i, zone = z, sig = sig, radius = radius, t = t0 + i, atts = {}, axis = ax }
			table.insert(ax.nodes, node)
			table.insert(graph.nodes, node)
			graph.Tmax = math.max(graph.Tmax, node.t)
			count += 1
			for k, tok in atts do
				local v2 = Derive.vidOf(nvid, k)
				if tok == "L" or tok == "F" or tok == "T" then
					table.insert(node.atts, { vid = v2, kind = tok })
					table.insert(graph.organs, { vid = v2, kind = tok, node = node })
					count += 1
				else
					local child = grow(tok, Rules.childOrder(kind, tok, order), v2, node.t + 1, kind)
					table.insert(node.atts, { vid = v2, kind = "axis", axis = child })
				end
			end
			prev = sig
		end
		return ax
	end

	grow(rootType, 0, 1, 0, nil)

	-- Flowers open in birth order: lowest first on a raceme, the main tip before side shoots.
	local lo, hi = math.huge, -math.huge
	for _, o in graph.organs do
		if o.kind == "F" then
			lo = math.min(lo, o.node.t)
			hi = math.max(hi, o.node.t)
		end
	end
	for _, o in graph.organs do
		if o.kind == "F" then
			graph.frank[o.vid] = if hi > lo then (o.node.t - lo) / (hi - lo) else 0
		end
	end
	return graph
end

return Derive
