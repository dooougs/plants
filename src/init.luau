--[[
	Plants: procedural plants from a compact genome, with hybrids, growth
	stages, wind sway, climbing, and plants big enough to grow walk-in rooms
	that furnish themselves. Extracted from Plant World.

	  local Plants = require(ReplicatedStorage.Packages.Plants)
	  Plants.configure({ worldScale = 10, features = { rooms = false } })  -- once, first

	  local g = Plants.Genome.fromSeed(123)
	  local model = Plants.PlantBuilder.build(g, progress, baseCFrame, options)

	Modules (loaded on first use):
	  Genome        genes, fromSeed/fromParent/splice, encode/decode, describe
	  Growth        stages and biome fit
	  Element       water / fire / steam plants
	  Palette       the art style: colours and materials
	  PlantIndex    collectable index of plant kinds
	  PlantBuilder  builds a plant model (and its rooms) from a genome
	  PlantSynth    plants grown from a shape grammar learned from example plants
	  Wind          deterministic shared wind and sway (pure function of seed + clock)
	  Climb         footholds and stem lines for climbing plants
	  Smooth        unions organ pieces into smooth shapes over frames
	  Habitat       the walk-in rooms inside big stems
	  Furniture     furniture that grows in rooms; FurnitureUse what it does
	  RoomPlanner   lays furniture out in a room; RoomFurniture owner arrangements
	  RoomLamps     tagged room lamps; Drafts a playable drafts board

	Options for configure: see Host.luau (worldScale, groundHeight,
	playerScale, biomes, civic, windSeed, perf, features).
]]

local Host = require(script.Host)

local Plants = {}
Plants.VERSION = "0.1.5"
Plants.Host = Host
Plants.features = Host.features

function Plants.configure(options: { [string]: any })
	Host.configure(options)
	return Plants
end

setmetatable(Plants, {
	__index = function(t, key)
		local child = script:FindFirstChild(key)
		if child and child:IsA("ModuleScript") then
			local mod = require(child) :: any
			rawset(t, key, mod)
			return mod
		end
		return nil
	end,
})

return Plants
