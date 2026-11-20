--!strict
--[[
	Organs: a small grammar for leaf and petal outlines, used by the close-up
	build (detail 3) so that no two leaves or petals on a plant are quite the
	same.

	An outline is a chain of segments from base to tip, one letter each:

	  c claw     w widening   W widest    n narrowing   p point
	  r round    l lobe       s sinus     t tooth       h heart base
	  q ruffle   f fringe     k notched tip

	Example outlines (LEAF and PETAL below) teach which segment may follow
	which, in which part of the organ (base, mid, top, tip). The genes choose
	the examples: leafShape and leafLength the plant's own leaf, petalWidth
	its petal, and leafEdge and petalEdge mix in toothed, lobed, cut,
	notched, fringed, frilly or pointed ones. Each organ then grows its own
	chain from Random seeded by its id (salt 5), so it is the same on every
	client and at every growth stage, and neighbours differ.

	PlantBuilder draws a chain as one blade segment per letter (widths from
	WIDTH), with teeth, fringe, ruffles and a notched tip where the letters
	say, and the veins the example names (pinnate, parallel or palmate).
]]

local Organs = {}

local PRIME = 2147483647

export type Example = { id: string, src: string, vein: string? }
export type Grammar = { ctx: { [string]: { { tok: string, w: number } } }, lengths: { number }, veins: { { vein: string, w: number } } }
export type Chain = { toks: { string }, vein: string }

Organs.LEAF = {
	lance = { id = "lance", src = "c w W W w n n p", vein = "pinnate" },
	ovate = { id = "ovate", src = "c W W W w n p", vein = "pinnate" },
	heart = { id = "heart", src = "h W W w n n p", vein = "palmate" },
	strap = { id = "strap", src = "c w w w w w w n p", vein = "parallel" },
	toothed = { id = "toothed", src = "c w t W t W t w t n p", vein = "pinnate" },
	oak = { id = "oak", src = "c l s l s l s n p", vein = "pinnate" },
	cut = { id = "cut", src = "c l s s l s s l s p", vein = "pinnate" },
} :: { [string]: Example }

Organs.PETAL = {
	round = { id = "round", src = "c w W W w r" },
	strap = { id = "strap", src = "c w w w w w r" },
	spoon = { id = "spoon", src = "c c c w W r" },
	notched = { id = "notched", src = "c w W W w k" },
	fringed = { id = "fringed", src = "c w W f f f r" },
	frilly = { id = "frilly", src = "c w q W q W q r" },
	pointed = { id = "pointed", src = "c w W w n p" },
} :: { [string]: Example }

-- Width at the end of each segment, as a share of the organ's widest.
Organs.WIDTH = { c = 0.35, w = 0.8, W = 1, n = 0.55, p = 0.12, r = 0.7, l = 1.15, s = 0.4, t = 0.9, h = 0.95, q = 0.95, f = 0.85, k = 0.75 } :: { [string]: number }
-- Segments that may end an organ, and only end it.
Organs.TIP = { p = true, r = true, k = true } :: { [string]: boolean }

local function split(src: string): { string }
	local toks = {}
	for tok in string.gmatch(src, "%S+") do
		table.insert(toks, tok)
	end
	return toks
end

local function zoneOf(i: number, n: number): string -- i from 0
	if i == n - 1 then
		return "tip"
	end
	local f = i / (n - 1)
	return if f < 0.34 then "base" elseif f < 0.67 then "mid" else "top"
end

-- How far an edge gene is from plain (0.5), and so how much its example counts.
local function edgeAmount(e: number): number
	return math.abs(e - 0.5) * 2
end

function Organs.leafExamples(g: { [string]: number }): { { ex: Example, weight: number } }
	local base = if g.leafShape < 0.33 then (if g.leafLength > 0.75 then "strap" else "lance") elseif g.leafShape < 0.66 then "ovate" else "heart"
	local list = { { ex = Organs.LEAF[base], weight = 1 } }
	local e = g.leafEdge or 0.5
	if edgeAmount(e) > 0.2 then
		local id = if e < 0.5 then (if e < 0.2 then "cut" else "toothed") else "oak"
		table.insert(list, { ex = Organs.LEAF[id], weight = edgeAmount(e) * 1.5 })
	end
	return list
end

function Organs.petalExamples(g: { [string]: number }): { { ex: Example, weight: number } }
	local base = if g.petalWidth < 0.35 then "strap" elseif g.petalWidth < 0.7 then "round" else "spoon"
	local list = { { ex = Organs.PETAL[base], weight = 1 } }
	local e = g.petalEdge or 0.5
	if edgeAmount(e) > 0.2 then
		local id = if e < 0.5 then (if e < 0.2 then "fringed" else "notched") else (if e > 0.8 then "frilly" else "pointed")
		table.insert(list, { ex = Organs.PETAL[id], weight = edgeAmount(e) * 1.5 })
	end
	return list
end

function Organs.grammar(list: { { ex: Example, weight: number } }): Grammar
	local G: Grammar = { ctx = {}, lengths = {}, veins = {} }
	local index: { [string]: { [string]: { tok: string, w: number } } } = {}
	local function add(key: string, tok: string, w: number)
		local byKey = index[key]
		if not byKey then
			byKey = {}
			index[key] = byKey
			G.ctx[key] = {}
		end
		local e = byKey[tok]
		if not e then
			e = { tok = tok, w = 0 }
			byKey[tok] = e
			table.insert(G.ctx[key], e)
		end
		e.w += w
	end
	for _, item in list do
		local toks = split(item.ex.src)
		local n = #toks
		table.insert(G.lengths, n)
		local prev = "^"
		for i, tok in toks do
			local z = zoneOf(i - 1, n)
			add(prev .. "|" .. z, tok, item.weight / n)
			add(z, tok, item.weight / n)
			prev = tok
		end
		local vein = item.ex.vein or "pinnate"
		local found = false
		for _, v in G.veins do
			if v.vein == vein then
				v.w += item.weight
				found = true
			end
		end
		if not found then
			table.insert(G.veins, { vein = vein, w = item.weight })
		end
	end
	return G
end

-- The leaf and petal grammars for a genome's genes, learned once per distinct choice.
local cache: { [string]: Grammar } = {}
local cached = 0
local function cachedGrammar(list: { { ex: Example, weight: number } }, kind: string): Grammar
	local parts = { kind }
	for _, item in list do
		table.insert(parts, item.ex.id .. "*" .. string.format("%.3f", item.weight))
	end
	local key = table.concat(parts, ",")
	local G = cache[key]
	if not G then
		if cached >= 512 then
			table.clear(cache)
			cached = 0
		end
		G = Organs.grammar(list)
		cache[key] = G
		cached += 1
	end
	return G
end

function Organs.forGenes(g: { [string]: number }): { leaf: Grammar, petal: Grammar }
	return { leaf = cachedGrammar(Organs.leafExamples(g), "leaf"), petal = cachedGrammar(Organs.petalExamples(g), "petal") }
end

-- One organ's outline, grown from its own id.
function Organs.chain(G: Grammar, seed: number, vid: number): Chain
	local r = Random.new((seed + 5 * 104729 + vid * 7919) % PRIME)
	local n = G.lengths[r:NextInteger(1, #G.lengths)]
	local toks = {}
	local prev = "^"
	for i = 0, n - 1 do
		local last = i == n - 1
		local z = zoneOf(i, n)
		local pick: string? = nil
		for _, key in { prev .. "|" .. z, z } do
			local list = G.ctx[key]
			if list then
				local cands, total = {}, 0
				for _, e in list do
					local isTip = Organs.TIP[e.tok] == true
					if isTip == last and not (i > 0 and e.tok == "h") then
						table.insert(cands, e)
						total += e.w
					end
				end
				if #cands > 0 then
					local x = r:NextNumber() * total
					for _, e in cands do
						x -= e.w
						if x < 0 then
							pick = e.tok
							break
						end
					end
					pick = pick or cands[#cands].tok
					break
				end
			end
		end
		local tok = pick or (if last then "p" else "w")
		table.insert(toks, tok)
		prev = tok
	end
	local total = 0
	for _, v in G.veins do
		total += v.w
	end
	local x = r:NextNumber() * total
	local vein = G.veins[1].vein
	for _, v in G.veins do
		x -= v.w
		if x < 0 then
			vein = v.vein
			break
		end
	end
	return { toks = toks, vein = vein }
end

-- Full width of a chain's outline at t (0 base .. 1 tip), as a share of the widest.
function Organs.widthAt(chain: Chain, t: number): number
	local toks = chain.toks
	local n = #toks
	local k = math.min(n, math.floor(t * n + 0.5))
	if k == 0 then
		return if toks[1] == "h" then 0.75 else 0.12
	end
	return Organs.WIDTH[toks[k]]
end

return Organs
