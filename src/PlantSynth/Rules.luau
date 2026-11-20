--!strict
--[[
	Rules: the shape grammar learned from example skeletons (Corpus).

	Every node of every example is a "vertex star": what grows at that node
	(its attachments, e.g. "LS" for a leaf and a side shoot). A star is
	recorded under three contexts, most specific first:

	  label|zone|prev   the axis it is on, how far along (base, mid, top,
	                    apex) and the star of the node before it
	  label|zone        the same without the previous node
	  label|*           anywhere on that kind of axis

	The label is the axis letter, with shoots split by branching order (S0
	main stem, S1 side shoot, S2 and deeper). Derive picks a star for each new
	node from the most specific context that has any, so plants copy their
	examples' local structure where they can and fall back gracefully where
	a hybrid of two examples meets something neither showed.

	Rules are learned once per set of examples and cached.
]]

local Corpus = require(script.Parent.Corpus)

local Rules = {}

export type Counts = { [string]: number }
export type Candidate = { sig: string, atts: { string }, n: Counts, w: number }
export type Grammar = {
	ctx: { [string]: { Candidate } },
	lengths: { [string]: { number } },
	roots: { [string]: boolean },
}

Rules.KINDS = { "L", "F", "T", "S", "R", "I", "Z", "V" }

function Rules.labelOf(kind: string, order: number): string
	if kind == "S" then
		return "S" .. math.min(order, 2)
	end
	return kind
end

-- A child axis's branching order: side shoots off a shoot go one deeper.
function Rules.childOrder(parentKind: string, kind: string, order: number): number
	if kind == "S" then
		return if parentKind == "S" then order + 1 else 1
	end
	return 0
end

function Rules.zoneOf(i: number, n: number): string -- i from 0
	if i == n - 1 then
		return "apex"
	end
	local f = if n <= 1 then 0 else i / (n - 1)
	return if f < 0.34 then "base" elseif f < 0.67 then "mid" else "top"
end

function Rules.count(atts: { string }): Counts
	local n: Counts = {}
	for _, k in Rules.KINDS do
		n[k] = 0
	end
	for _, a in atts do
		n[a] += 1
	end
	return n
end

local function kindOf(a: any): string
	return if type(a) == "string" then a else a.type
end

function Rules.extract(list: { Corpus.Entry }): Grammar
	local G: Grammar = { ctx = {}, lengths = {}, roots = {} }
	local index: { [string]: { [string]: Candidate } } = {}
	local function add(key: string, sig: string, atts: { string }, w: number)
		local byKey = index[key]
		if not byKey then
			byKey = {}
			index[key] = byKey
			G.ctx[key] = {}
		end
		local c = byKey[sig]
		if not c then
			c = { sig = sig, atts = atts, n = Rules.count(atts), w = 0 }
			byKey[sig] = c
			table.insert(G.ctx[key], c) -- insertion order: deterministic picks
		end
		c.w += w
	end
	for _, entry in list do
		local tree = entry.ex.tree
		G.roots[tree.type] = true
		-- Each example counts as much as another however big it is.
		local stars = 0
		local function countStars(ax: Corpus.Axis)
			for _, nd in ax.nodes do
				stars += 1
				for _, a in nd do
					if type(a) ~= "string" then
						countStars(a)
					end
				end
			end
		end
		countStars(tree)
		local w = entry.weight / stars
		local function walk(ax: Corpus.Axis, order: number)
			local label = Rules.labelOf(ax.type, order)
			local n = #ax.nodes
			local lengths = G.lengths[label]
			if not lengths then
				lengths = {}
				G.lengths[label] = lengths
			end
			table.insert(lengths, n)
			local prev = "^"
			for i, nd in ax.nodes do
				local atts = {}
				for _, a in nd do
					table.insert(atts, kindOf(a))
				end
				table.sort(atts)
				local sig = if #atts > 0 then table.concat(atts) else "-"
				local z = Rules.zoneOf(i - 1, n)
				add(label .. "|" .. z .. "|" .. prev, sig, atts, w)
				add(label .. "|" .. z, sig, atts, w)
				add(label .. "|*", sig, atts, w)
				prev = sig
				for _, a in nd do
					if type(a) ~= "string" then
						walk(a, Rules.childOrder(ax.type, a.type, order))
					end
				end
			end
		end
		walk(tree, 0)
	end
	return G
end

-- Rules for a list of examples, learned once and kept (keyed by Corpus.forGenome's key).
local cache: { [string]: Grammar } = {}
local cached = 0
function Rules.forCorpus(list: { Corpus.Entry }, key: string): Grammar
	local G = cache[key]
	if not G then
		if cached >= 256 then
			table.clear(cache) -- a handful of keys in practice; a bound all the same
			cached = 0
		end
		G = Rules.extract(list)
		cache[key] = G
		cached += 1
	end
	return G
end

return Rules
