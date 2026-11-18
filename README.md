# Plants

Procedural plants for Roblox, extracted from Plant World.

- A ~70 character **genome** per plant: breed hybrids (`fromParent`, `splice`),
  encode/decode, describe, a collectable **index**.
- **Growth** stages and biome fit; water, fire and steam **elements**.
- **PlantBuilder** builds the model for any genome at any growth progress,
  with smooth unioned organs (**Smooth**, spread over frames).
- Deterministic **Wind**: every server and client sways the same from a
  shared seed and the server clock, with nothing sent over the network.
- **Climb**: invisible footholds so players can climb stems and stand on
  flowers.
- **Rooms**: plants with the habitat gene grow walk-in rooms (**Habitat**)
  that **furnish** themselves, with usable furniture (**FurnitureUse**),
  lamps, a drafts board, and owner arrangements (**RoomFurniture**).

## Install

```toml
[dependencies]
Plants = "dooougs/plants@0.1.1"
```

## Use

```lua
local Plants = require(ReplicatedStorage.Packages.Plants)

Plants.configure({
    worldScale = 10,                       -- or function() return ... end
    groundHeight = function(x, z) return 0 end,
    features = { rooms = true, furniture = false, climb = true, unions = true, windEffect = 0.5 },
})

local genome = Plants.Genome.fromSeed(42)
local model = Plants.PlantBuilder.build(genome, 1, CFrame.new(0, 0, 0))
model.Parent = workspace
```

Call `configure` once, before any plant module is used.

## Options

| option | default | |
|---|---|---|
| `worldScale` | `1` | world studs per design stud (number or provider) |
| `playerScale` | `1` | player size rooms are built for |
| `groundHeight(x, z)` | flat `0` | terrain height for rooting plants |
| `biomes()` | none | optional biome classifier for colours/fit |
| `civic()` | none | `{ byBuilding, BACK }` service desks kept clear in ground rooms |
| `windSeed()` | `ReplicatedStorage` attribute `WorldSeed` | shared wind seed |
| `perf` | no-ops | `{ busy, charge, measure, isObserving }` frame-budget hooks |
| `features.rooms` | `true` | habitat plants grow rooms |
| `features.furniture` | `true` | rooms grow furniture |
| `features.climb` | `true` | climbing footholds |
| `features.unions` | `true` | smooth organs with UnionAsync |
| `features.windEffect` | `0.5` | sway strength, `0` for still plants |
