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
- **Designed furniture**: chairs, stools, tables, benches, sofas, beds,
  bedside tables, lamps, bookcases and folding screens grown by a small shape grammar (**FurnitureGrammar**) from a
  short recipe of rule choices (legs, shape, back, trim, weight, size,
  colour), with **decor styles** that keep a set matching
  (**FurnitureRules**, after Liu et al. 2015, "Style Compatibility for 3D
  Furniture Models"). Market stalls and counters (`dstall`, `dcounter`) are
  grammar kinds too. Every other grown piece (chests, cupboards, barrels,
  rugs...) can be **dressed** in a style: its own working body in the
  style's colours plus the grammar's trim, crest and feet
  (`FurnitureGrammar.dress`, `FurnitureRules.DRESSED`), so any kind can be
  designed and bought in a style. Pass `decorSeed` to PlantBuilder and a
  building furnishes in that style, homes included.
  Town signs (`dsign`: posts, board, topper, trim, with a `face` panel to
  write on) and washing-line poles (`dpole`) are grammar kinds too, so a
  town's decorations match its furniture.
  Rooms needn't share their building's style: about 4 in 10 pick their own
  (`FurnitureRules.roomStyle`), and a big room may be split into two zones,
  the far one in a second style (`roomZones`, `Furniture.zone`). Sets that go
  together (a table and its chairs, a bed and its bedside chest, a fire and
  its armchairs: `FurnitureRules.SETS`) always match. All of it is seeded
  from the building, so every client agrees.
  There are 13 decor styles plus Mix & Match (Acorn Lodge, Fern Grotto,
  Beetle Shell, Dewdrop, Thistledown, Pebble Brook and Ember Hearth came in
  0.1.12, after Mix & Match so saved recipes keep their style).
  How full a room is is a seeded rule too (0.1.13): each room rolls cosy,
  homely, tidy or airy (`Furniture.DENSITY`), and `RoomPlanner` fills
  toward one piece per ~24 floor units times that, keeping walkways clear.
  Public rooms fill at half that.
  Lights keep apart (0.1.14): floor lamps, lanterns and glow jars never
  stand under or beside a wall lamp or near another light, and each picks
  the spot furthest from the room's other lights (`RoomPlanner.LIGHTS`).
- **RoomTidy**: suggests a better arrangement of a room's pieces by interior
  design rules (after Merrell et al. 2011, "Interactive Furniture Layout
  Using Interior Design Guidelines").

## Install

```toml
[dependencies]
Plants = "dooougs/plants@0.1.16"
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
| `features.generator` | `"classic"` | `"synth"` grows plants from the shape grammar (see below) |
| `features.organs` | `false` | every leaf and petal gets its own outline at detail 3 |

## Shape grammar (PlantSynth)

`PlantSynth` grows plants from a grammar learned from a dozen hand-drawn
example skeletons (after Merrell, *Example-Based Procedural Modeling Using
Graph Grammars*, 2023). Besides the six classic body plans it can grow
compound fronds, whorls, racemes and spikes, umbels on side shoots, forks
that fork again, trailing vines, and hybrids of two of these.

```lua
Plants.configure({ features = { generator = "synth", organs = true } })

-- or per build:
PlantBuilder.build(genome, progress, cf, { synth = true, examples = { "fern", "lily" } })
```

- A plant grows from its body plan's example (`PlantIndex.bodyOf`). The
  `donor` gene, away from 0.4 to 0.6, mixes in a second example; about 1 wild
  plant in 6 is such a hybrid.
- `organs = true` gives each leaf and petal its own outline at detail 3, from a
  small grammar of outlines (lance, oval, heart, strap, toothed, oak, cut;
  round, strap, spoon, notched, fringed, frilly, pointed) steered by
  `leafShape`, `petalWidth` and the `leafEdge` and `petalEdge` genes. It works
  with either generator.
- Determinism, growth and detail coherence hold as for classic plants: the
  skeleton is derived once per genome, and every choice is seeded by a stable
  per-node id.
- Every grammar plant draws its own stature (about 0.62 to 2.9 times its
  `height` gene's stem, most near 1, a few giants), so plants of one kind
  finish at different heights. Homes (habitat 1) keep their 0.1.3 heights
  (0.62 to 1.45) so their rooms never move. Bigger plants carry bigger rooms:
  a building plant's rooms scale with its stature (`Layout.roomSize`, 0.85 to
  1.8 times the usual size); homes keep the usual size.
- Building plants (habitat) keep the classic stem, rooms stacked up the
  middle, unless their `roomStems` gene is on (`Genome.roomsAnywhere`, at
  `Genome.ROOMS_ANYWHERE` = 0.2 or more). Then they grow from the grammar,
  whatever the generator switch says, and `PlantSynth.Rooms` puts their rooms
  on the main stem and on the side shoots growing from it: side shoots reach
  out and stretch so their room clears the stem, a room may clear a shoot out
  of its way, and higher `roomStems` leans further out onto the branches. A
  wild building plant has a room at every site that fits (no set count, up
  to a safety limit of `Rooms.CAP`) above a possible ground hall; a home
  (`options.maxRooms`) always has a ground hall and keeps its rooms where they
  were as it grows more. A plant whose stems can't fit a whole home keeps the
  classic stem.
- Other plants' rooms: `PlantBuilder.build(..., { keepOut = { { cf, halfX,
  halfZ, top } } })` (world studs; `cf` at the room's floor, Y up) makes
  leaves grow round them: a leaf heading into a room turns away from it, out
  and up, a little at a time as it grows, ends early if it can't, and isn't
  grown at all if its stalk can't clear. So plants can stand close to a
  building without leaves poking through its walls. Without `keepOut`
  nothing changes.
- Growing round rooms: in a real build a grammar plant's side shoots grow
  round other plants' rooms (`keepOut`) and its own: a shoot heading into a
  room turns away, under it or over it, and grows on from there, or stops if
  it can't get round; a flower that would open inside a room isn't grown.
  A plant's own leaves keep out of its own rooms too (leaves set into a
  room's shell stay). Main stems and shoots carrying rooms never turn, so
  rooms and the top flower stay where they are. Layout takes the rooms as
  `plan.avoid` (boxes in the plant's frame); without it nothing changes.
- Giving way to older plants: `PlantBuilder.build(..., { yieldTo = boxes })`
  (same boxes as `keepOut`, world studs) makes a grammar plant's main stem
  and room shoots lean out of the way of those rooms, rooms, side shoots and
  top flower riding along, until no stem or room of it is inside one. It's
  worked out on the grown plant a few passes over (clearing one spot can
  push another into a room) and a pure function of genome and boxes, so pass
  the same boxes everywhere (the game saves them with the plant when it's
  planted). `crown`, `flowerPoints` and `groundLift` take the same option.
  `PlantBuilder.roomBoxes(genome, baseCF, options)` gives a plant's grown
  rooms as such boxes. Layout takes them as `plan.yield`.
- `roomStems` reads 0 in every genome string saved before it existed, and
  `Genome.fromSeed` sets it to 0, so existing and fixed buildings keep their
  rooms exactly where they are. `Genome.spreadRooms(g, seed)` turns it on
  (`PlantIndex.wild` does, for wild plants).
- `PlantSynth.showcase()` lists eight plants the classic builder can't make
  (frond plant, whorl lily, candelabra, umbel shrub, trailing vine, flower
  spike and two hybrids), to try it out:

  ```lua
  for i, item in Plants.PlantSynth.showcase() do
      local model = Plants.PlantBuilder.build(item.genome, 1, CFrame.new(i * 25, 0, 0),
          { synth = true, examples = item.examples, detail = 3 })
      model.Parent = workspace
  end
  ```
- Both switches are off by default. With them off every plant builds exactly
  as before (building plants aside, see `roomStems`), and `Genome.hash`
  ignores the genes added since, so saved plants keep their shapes. `PlantSynth.Corpus.add(id, name, src)` adds an example.
