--[[
	Host: the hooks a game plugs into the Plants package, and its feature
	switches. Set once with Plants.configure(options) before any plant
	module is required; every hook has a standalone default.

	Hooks that read game modules are providers (functions), resolved the
	first time a plant module needs them, so requiring a light module
	(Genome, Palette...) never pulls in the game's world config.

	Options:
	  worldScale     number | () -> number   world studs per design stud (1)
	  groundHeight   (x, z) -> number        terrain height for rooting plants (flat 0)
	  playerScale    number | () -> number   player size rooms are built for (1)
	  biomes         () -> module?           optional biome classifier with
	                                         classify(t, m, tundraT), LAYOUT_TUNDRA_TEMPERATURE
	  civic          () -> { byBuilding = {[kind]=any}, BACK = number }?
	                                         ground-floor service desks to keep clear
	  windSeed       () -> number            shared seed for the wind field
	                                         (default: ReplicatedStorage attribute "WorldSeed")
	  perf           { busy, charge, measure, isObserving }  frame budget hooks (no-ops)
	  features = {
	    rooms        true   plants with the habitat gene grow walk-in rooms
	    furniture    true   rooms grow furniture
	    climb        true   invisible footholds so players can climb plants
	    unions       true   smooth organs with UnionAsync (Smooth)
	    windEffect   0.5    sway strength multiplier (0 = still plants)
	    generator    "classic"  "synth": grow plants from the shape grammar (PlantSynth)
	    organs       false  every leaf and petal gets its own outline at detail 3
	  }
]]

local Host = {}

local function constant(value: any): () -> any
	return function()
		return value
	end
end

local function provider(value: any, fallback: any): () -> any
	if value == nil then
		return constant(fallback)
	end
	if type(value) == "function" then
		local cached, done = nil, false
		return function()
			if not done then
				cached, done = value(), true
			end
			return cached
		end
	end
	return constant(value)
end

local noop = function() end

Host.features = {
	rooms = true,
	furniture = true,
	climb = true,
	unions = true,
	windEffect = 0.5,
	generator = "classic", -- "synth": grow plants from the shape grammar (PlantSynth)
	organs = false, -- true: every leaf and petal gets its own outline at detail 3 (PlantSynth.Organs)
}

Host.worldScale = constant(1)
Host.playerScale = constant(1)
Host.biomes = constant(nil)
Host.civic = constant(nil)
Host.groundHeight = function(_x: number, _z: number): number
	return 0
end
Host.windSeed = function(): number
	local s = game:GetService("ReplicatedStorage"):GetAttribute("WorldSeed")
	return if typeof(s) == "number" then s else 0
end
Host.perf = {
	busy = function()
		return false
	end,
	charge = noop,
	measure = noop,
	isObserving = function()
		return false
	end,
}

Host.configured = false

function Host.configure(options: { [string]: any })
	options = options or {}
	Host.worldScale = provider(options.worldScale, 1)
	Host.playerScale = provider(options.playerScale, 1)
	Host.biomes = provider(options.biomes, nil)
	Host.civic = provider(options.civic, nil)
	if options.groundHeight then
		Host.groundHeight = options.groundHeight
	end
	if options.windSeed then
		Host.windSeed = options.windSeed
	end
	if options.perf then
		local p = options.perf
		Host.perf = {
			busy = p.busy or Host.perf.busy,
			charge = p.charge or noop,
			measure = p.measure or noop,
			isObserving = p.isObserving or Host.perf.isObserving,
		}
	end
	for key, value in options.features or {} do
		assert(Host.features[key] ~= nil, `Plants: unknown feature "{key}"`)
		Host.features[key] = value
	end
	Host.configured = true
end

return Host
