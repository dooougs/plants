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

	Salts used: 1 node bend, 2 axis start angle.
]]

local Growth = require(script.Parent.Parent.Growth)
local Derive = require(script.Parent.Derive)

local Layout = {}

local TAU = math.pi * 2
local GOLDEN = math.rad(137.508)
local UP = Vector3.yAxis

export type Stem = { vid: number, a: Vector3, b: Vector3, ctrl: Vector3, d0: number, d1: number, t: number, kind: string, main: boolean, order: number }
export type Leaf = { vid: number, kind: string, pos: Vector3, dir: Vector3, len: number, maturity: number, nodeT: number, stemD: number, sessile: boolean }
export type Flower = { vid: number, pos: Vector3, dir: Vector3, scale: number, bud: number, bloom: number, pedicel: { a: Vector3, b: Vector3, d: number }?, az: number, top: boolean }
export type Result = {
	stems: { Stem },
	leaves: { Leaf },
	flowers: { Flower },
	main: { Vector3 }, -- the main axis's node positions, base first (the climbing line)
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

function Layout.layout(G: Derive.Graph, g: { [string]: number }, p: number): Result
	local out: Result = { stems = {}, leaves = {}, flowers = {}, main = {}, mainDiameter = 0, upright = true, veg = 0 }
	local main = G.axes[1]
	local vegStart, vegEnd = Growth.VEGETATIVE[1], Growth.VEGETATIVE[2]
	local H = lerp(3, 16, g.height)
	local R0 = lerp(0.2, 0.9, g.stemThickness) * lerp(0.7, 1.2, g.height) -- mainStemThickness
	local leafLen0 = lerp(0.9, 3.6, g.leafSize) -- leafLength
	local plast = (vegEnd - vegStart) / (G.Tmax + 1)
	local span = math.clamp(plast * 4, 0.06, 0.3)
	local veg = phase(p, vegStart, vegEnd)
	out.veg = veg
	out.upright = main.type ~= "Z"
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
	local sInt = if main.type == "S" then H / main.n elseif scape then lerp(1.5, 6, g.height) / scape.n else H / 8

	local function params(ax: Derive.Axis): (number, number, number, number) -- internode, diameter, tropism, curve
		local kind = ax.type
		if kind == "Z" then
			return 0.06, lerp(0.25, 0.6, g.stemThickness), 0, 0
		elseif kind == "S" and ax.parentType == "Z" then
			return lerp(1.5, 6, g.height) / ax.n, lerp(0.15, 0.4, g.stemThickness), 0.15, g.stemCurve * 0.25
		elseif kind == "S" then
			return sInt * 0.7 ^ ax.order, R0 * 0.55 ^ ax.order, 0.15, g.stemCurve * 0.35
		elseif kind == "I" then
			return if ax.n == 1 then 0 else sInt * 0.42, R0 * 0.32, -0.05, 0.06
		elseif kind == "R" then
			return leafLen0 * 0.3, math.max(0.08, R0 * 0.16), -0.06, 0.04
		end
		return sInt * 0.75, R0 * 0.4, -0.16, g.stemCurve * 0.2 -- V, trailing
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
			local len = int * scale * (0.12 + 0.88 * ease(m))
			local np = pos + d * len
			local thick = if isMain then lerp(0.3, 1, veg) else lerp(0.3, 1, axGrow)
			local function diam(j: number): number
				return diameter * lerp(1, 0.45, j / ax.n) * thick * scale
			end
			if len > 1e-4 then
				table.insert(out.stems, { vid = nd.vid, a = pos, b = np, ctrl = pos + prevD * len * 0.5, d0 = diam(i), d1 = diam(i + 1), t = i / ax.n, kind = ax.type, main = isMain, order = ax.order })
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
						table.insert(out.leaves, { vid = at.vid, kind = at.kind, pos = np, dir = dir, len = L, maturity = mL, nodeT = tpos, stemD = diam(i + 1), sessile = leaflet })
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
						if not terminal then
							local pdir = toward(d, o, if umbel then 0.97 else 0.95)
							local plen = if umbel then lerp(0.6, 1.4, g.flowerSize) else math.max(0.3, sInt * 0.35) * scale
							fpos = np + pdir * plen * (0.3 + 0.7 * bud)
							if g.petalCurl > 0.6 and not umbel then
								fdir = (pdir - UP * 0.9).Unit -- bells nod
							else
								fdir = (pdir + (if umbel then d else UP * 0.7)).Unit
							end
							pedicel = { a = np, b = fpos, d = 0.1 * fscale + 0.04 }
						end
						table.insert(out.flowers, { vid = at.vid, pos = fpos, dir = fdir, scale = fscale, bud = bud, bloom = bloom, pedicel = pedicel, az = (at.vid % 6283) / 1000, top = isMain and terminal })
					end
				elseif at.axis then
					local ch = at.axis
					local nd2: Vector3
					if terminal then
						nd2 = toward(d, o, 0.06)
					elseif ch.type == "S" then
						nd2 = toward(d, o, lerp(0.35, 1.2, g.branchAngle) * (if fork then 0.7 else 1))
					elseif ch.type == "I" then
						nd2 = toward(d, o, 0.75)
					elseif ch.type == "V" then
						nd2 = toward(d, o, 1.25)
					else
						nd2 = toward(d, o, if ax.type == "Z" then 1.3 else lerp(0.7, 1.2, g.leafDroop))
					end
					local nu = if ch.type == "R" then transport(UP, nd2) else transport(u, nd2)
					local sc = if ch.type == "R" then lerp(1.1, 0.65, tpos) * 0.8 ^ ax.order else 1
					walk(ch, np, nd2, nu, sc)
				end
			end
			pos, prevD = np, d
		end
	end

	walk(main, Vector3.zero, UP, Vector3.xAxis, 1)
	return out
end

return Layout
