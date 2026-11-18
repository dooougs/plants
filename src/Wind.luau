--[[
	Wind: one shared wind field for the whole world, and how plants bend in it.

	Every value here is a pure function of (world seed, position, time), with
	time taken from workspace:GetServerTimeNow(). That clock is synced to UTC on
	every Roblox server (and each client tracks its server's clock), so every
	player on every server sees the same gust roll across the same meadow and
	the same plant sway the same way at the same moment. Nothing is sent over
	the network.

	Only periodic functions of time are used (no noise lookups on huge time
	values), which keeps full precision with epoch-sized timestamps.

	Wind.at(position, t, seed) -> the world's wind currents at a point: (direction: Vector3 (unit, horizontal), strength: number 0..~1.4)
	Wind.bend(genes, position, height, t, seed) -> (Vector3, strength)
	    horizontal vector: direction the plant's tip moves, length = sway amount (radians; times TIP_GAIN gives the tip angle);
	    the stiffness gene sets how far and how quickly a plant sways
	Wind.stemCurve(tipAngle, height) -> curve
	    the bent shape of a stem whose bend builds up toward the tip: stiff at the
	    base, loosest at the top, like a real plant. Pass to Wind.alongStem.
	Wind.alongStem(curve, r) -> (sideways: number, up: number, angle: number)
	    where the point a fraction r (0 base .. 1 tip) up the rest stem ends up,
	    in the bend plane relative to the flex base, and how far it is tilted
	Wind.jointSway(kind, jointPos, t, strength) -> (a: number, b: number)
	    how far a leaf, petal or flower head swings at the joint where it
	    meets its stem, on top of the stem's own bend (radians):
	      "leaf":  a = lift (always >= 0: the wind lifts leaves, it never
	               pushes them down into the ground), b = turn about the
	               vertical (heights don't change, so ground clearance holds)
	      "head":  a = nod downwind, b = nod across the wind
	      "petal": a = flap about the petal's base, b = 0
	    strength already includes any calming (climbed plants).
]]

-- The wind field and sway are tuned in the original design studs; world
-- positions and heights are divided by the world scale on the way in.
local Host = require(script.Parent.Host)
local WORLD = Host.worldScale()
local Workspace = game:GetService("Workspace")

local Wind = {}

-- How hard the wind moves things, as one dial: every visible wind motion
-- (stem bend and idle sway, leaf/petal/head joint swing, flutter, grass) is
-- scaled by this. Wind.at itself is unscaled, so the Weather Vane still reads
-- the real breeze. 1 = the original tuning. 0.2 (#109) left the sway at about
-- one degree every five seconds, which read as no wind at all; 0.5 is gentle
-- but visible. The amount costs nothing: frame time is set by how many plants
-- sway (PlantRenderer tiers), not by how far they move.
Wind.EFFECT = Host.features.windEffect -- 0.5 by default (Plants.configure features.windEffect)

Wind.GUST_SPEED = 18 -- studs per second that gust fronts travel downwind
Wind.GUST_SPACING = 45 -- studs between gust fronts (divided by 2*pi)
Wind.BACKGROUND = 0.3 -- minimum breeze strength everywhere, always: plants never go fully still
Wind.IDLE_BEND = 0.03 -- radians of gentle sway every plant keeps, however stiff
-- How the bend spreads along a stem: tilt at fraction r of the height is
-- tipAngle * r^CURVE_POWER, so the base barely flexes and the top whips.
Wind.CURVE_POWER = 2.2
-- Concentrating the bend near the top moves the tip less than tilting the whole
-- stem would, so the tip bends further to keep the sway lively.
Wind.TIP_GAIN = 2.0
Wind.MAX_TIP_ANGLE = 1.3 -- radians; even the floppiest top never folds over
Wind.CURVE_STEPS = 12

local TAU = math.pi * 2
local sin, cos = math.sin, math.cos

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- The shared procedural key: the world seed every server already shares.
function Wind.seed(): number
	return Host.windSeed()
end

-- The shared clock, slowed: every wind motion (currents, gusts, stem and
-- joint sway, flutter, grass) runs on this, so TIME_SCALE paces them all at
-- once. Still a pure function of the synced server clock.
Wind.TIME_SCALE = 0.5
function Wind.now(): number
	return Workspace:GetServerTimeNow() * Wind.TIME_SCALE
end

-- One exact-time context; no time quantization or retained world-position keys.
local context = {}
function Wind.context(t: number, seed: number)
	if context.t ~= t or context.seed ~= seed then
		local s = (seed % 10007) / 10007
		local slow = 0.5 * sin(t * 0.011 + s * 40)
		context = { t = t, seed = seed, s = s, slow = slow,
			fast = 0.25 * sin(t * 0.029 + s * 17),
			strength = 0.45 + 0.2 * sin(t * 0.047 + s * 9) + 0.1 * sin(t * 0.13 + s * 23),
			mx = cos(s * TAU + slow), mz = sin(s * TAU + slow),
			gust = 0.6 + 0.4 * sin(t * 0.07 + s * 31) }
	end
	return context
end

function Wind.at(position: Vector3, t: number, seed: number): (Vector3, number)
	local ctx = Wind.context(t, seed)
	local s = ctx.s
	local x, z = position.X / WORLD, position.Z / WORLD
	-- Global currents: the wind direction is a smooth field over the world, so
	-- different regions have their own currents that curve and meet, and the
	-- whole pattern drifts slowly over minutes.
	local angle = s * TAU
		+ 1.2 * sin(x / 700 + s * 5 + t * 0.004) * cos(z / 900 + s * 3)
		+ 0.8 * sin((x + z) / 1500 + s * 11 - t * 0.003)
		+ ctx.slow
		+ ctx.fast
	local dir = Vector3.new(cos(angle), 0, sin(angle))
	-- Breeze strength breathes over tens of seconds and is stronger in some currents.
	local strength = ctx.strength
		+ 0.15 * sin(x / 500 - z / 650 + s * 13 + t * 0.01)
	-- Gust fronts roll across the world along the prevailing (world-wide) wind,
	-- with wavy edges. Their phase uses the prevailing direction, not the local
	-- one, so fronts keep an even spacing everywhere in the world.
	local mx, mz = ctx.mx, ctx.mz
	local along = x * mx + z * mz
	local across = z * mx - x * mz
	local front = sin((along - t * Wind.GUST_SPEED) / Wind.GUST_SPACING + 0.6 * sin(across / 70))
	local gust = math.max(0, front) ^ 4 * ctx.gust
	-- A background breeze is always blowing; the breathing and gusts ride on top.
	strength = Wind.BACKGROUND + (1 - Wind.BACKGROUND) * math.max(0, strength)
	return dir, math.clamp(strength + gust * 0.7, Wind.BACKGROUND, 1.4)
end

function Wind.prepareBend(genes, position: Vector3, height: number)
	local stiff = genes.stiffness or 0.5
	local h = math.max(height / WORLD, 0.5)
	-- Natural sway frequency (Hz): stiff plants are quicker, tall plants slower.
	local freq = lerp(0.35, 1.1, stiff) * math.sqrt(6 / (h + 2))
	-- Deterministic per-plant phase so neighbours don't move in lockstep.
	local phase = (position.X * 0.173 + position.Z * 0.311) / WORLD
	local maxBend = lerp(0.42, 0.1, stiff)
	return { freq = freq, phase = phase, maxBend = maxBend }
end

function Wind.bend(genes, position: Vector3, height: number, t: number, seed: number, prepared: any?): (Vector3, number, Vector3)
	local data = prepared or Wind.prepareBend(genes, position, height)
	local freq, phase, maxBend = data.freq, data.phase, data.maxBend
	local dir, strength = Wind.at(position, t, seed)
	local side = Vector3.new(-dir.Z, 0, dir.X)
	local lean = strength * 0.6 -- steady lean downwind
	local osc = strength * (0.35 * sin(TAU * freq * t + phase) + 0.12 * sin(TAU * freq * 2.3 * t + phase * 1.7))
	local wobble = strength * 0.12 * sin(TAU * freq * 0.7 * t + phase * 2.1)
	-- Permanent small idle motion, so even the stiffest plant on the calmest
	-- moment still breathes a little.
	local idleAlong = Wind.IDLE_BEND * sin(TAU * freq * t + phase)
	local idleSide = Wind.IDLE_BEND * 0.6 * sin(TAU * freq * 0.83 * t + phase * 1.3)
	return (dir * (maxBend * (lean + osc) + idleAlong) + side * (maxBend * wobble + idleSide)) * Wind.EFFECT, strength, dir
end

local coefficients = { n = 0, power = 0, values = {} }
function Wind.stemCurve(tipAngle: number, height: number, reuse: any?)
	local n = Wind.CURVE_STEPS
	local pw = Wind.CURVE_POWER
	local ds = height / n
	if coefficients.n ~= n or coefficients.power ~= pw then
		coefficients = { n = n, power = pw, values = {} }
		for k = 1, n do coefficients.values[k] = ((k - 0.5) / n) ^ pw end
	end
	local curve = reuse or { xs = {}, ys = {}, samples = {} }
	if curve.n ~= n or curve.power ~= pw then table.clear(curve.samples) end
	local xs, ys = curve.xs, curve.ys
	xs[1], ys[1] = 0, 0
	local x, y = 0, 0
	for k = 1, n do
		-- Integrate the tilt along the stem (midpoint rule) to get its bent shape.
		local a = tipAngle * coefficients.values[k]
		x += sin(a) * ds
		y += cos(a) * ds
		xs[k + 1] = x
		ys[k + 1] = y
	end
	curve.tip, curve.n, curve.power = tipAngle, n, pw
	return curve
end

function Wind.alongStem(curve, r: number): (number, number, number)
	r = math.clamp(r, 0, 1)
	local sample = curve.samples[r]
	if not sample then
		local f = r * curve.n
		local k = math.min(math.floor(f), curve.n - 1)
		sample = { k = k, frac = f - k, tilt = r ^ Wind.CURVE_POWER }
		curve.samples[r] = sample
	end
	local k, frac = sample.k, sample.frac
	local xs, ys = curve.xs, curve.ys
	return lerp(xs[k + 1], xs[k + 2], frac), lerp(ys[k + 1], ys[k + 2], frac), curve.tip * sample.tilt
end

-- Small extra flutter for leaves and petals (radians), coherent across one leaf.
-- Never more than FLUTTER_MAX (PlantBuilder keeps that much room under low leaves).
Wind.FLUTTER = 0.09
Wind.FLUTTER_MAX = Wind.FLUTTER * 1.4 * Wind.EFFECT -- at the strongest gust
function Wind.flutterPhase(position: Vector3): number
	return (position.X + position.Z) * 0.8 / WORLD
end
function Wind.flutter(position: Vector3, t: number, strength: number, phase: number?): number
	return Wind.FLUTTER * Wind.EFFECT * strength * sin(t * 5.5 + (phase or Wind.flutterPhase(position)))
end

-- Swing at the joints. Each organ gets its own deterministic phase from where
-- its joint sits in the world, so neighbouring leaves don't flap in step.
Wind.LEAF_LIFT = 0.22 -- radians at full strength
Wind.LEAF_TURN = 0.1
Wind.HEAD_NOD = 0.2 -- flower heads are heavy: slower, a bit larger nod
Wind.PETAL_FLAP = 0.1
function Wind.prepareJoint(jointPos: Vector3)
	local ph = (jointPos.X * 1.37 + jointPos.Y * 0.71 + jointPos.Z * 2.03) / WORLD
	-- Each organ's own natural frequency, varied a little per organ.
	local wobble = 0.85 + 0.3 * (0.5 + 0.5 * sin(ph * 3.1))
	return { phase = ph, wobble = wobble }
end
function Wind.jointSway(kind: string, jointPos: Vector3, t: number, strength: number, prepared: any?): (number, number)
	strength *= Wind.EFFECT
	local data = prepared or Wind.prepareJoint(jointPos)
	local ph, wobble = data.phase, data.wobble
	if kind == "leaf" then
		local f = 0.9 * wobble
		local lift = Wind.LEAF_LIFT * strength * (0.55 + 0.35 * sin(TAU * f * t + ph) + 0.1 * sin(TAU * f * 2.7 * t + ph * 1.3))
		local turn = Wind.LEAF_TURN * strength * sin(TAU * f * 0.71 * t + ph * 1.9)
		return math.max(0, lift), turn
	elseif kind == "head" then
		local f = 0.55 * wobble
		local nod = Wind.HEAD_NOD * strength * (0.45 + 0.4 * sin(TAU * f * t + ph) + 0.15 * sin(TAU * f * 2.3 * t + ph * 0.7))
		local across = Wind.HEAD_NOD * 0.35 * strength * sin(TAU * f * 0.8 * t + ph * 1.6)
		return nod, across
	elseif kind == "petal" then
		local f = 2.2 * wobble
		return Wind.PETAL_FLAP * strength * sin(TAU * f * t + ph), 0
	end
	return 0, 0
end

return Wind
