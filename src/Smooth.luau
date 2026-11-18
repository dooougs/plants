local WorkQueue = require(script.Parent.WorkQueue)
--[[
	Smooth: unions the pieces of one plant organ into a single smooth shape.

	PlantBuilder makes leaves, petals, sepals and stems from plain blocks,
	wedges, cylinders and balls, and groups them: one group per organ that
	swings at its own wind joint (a leaf, a petal, a flower head), and one per
	stretch of stem between two nodes. Smooth.queue unions each group in the
	background, a few a frame within the frame's shared time allowance (Shared.Perf), so a plant reads as a few grown surfaces
	instead of a pile of facets. Unions never cross a joint, so every organ
	still swings on its own.

	Each union carries a "SwayRef" ObjectValue naming one of the pieces it
	replaced; PlantRenderer sways the union exactly as it swayed that piece.
	The pieces are destroyed once the union is in place. On a plant already
	in the world they stay a moment longer (Smooth.PIECE_LINGER): a fresh
	union draws as nothing for a few frames, and without the pieces that
	stretch of the plant would blink out.

	If unions aren't available (or one fails) Smooth turns itself off and the
	pieces simply stay as they are. A group whose model was rebuilt or removed
	meanwhile is skipped.

	Each model counts its unions still to come in the "SmoothPending"
	attribute (shared with Habitat's room shells), so PlantRenderer can keep a
	build out of sight until it is whole.
]]

local Host = require(script.Parent.Host)
local Perf = Host.perf

local Smooth = {}

Smooth.ENABLED = Host.features.unions ~= false
Smooth.SMOOTHING_ANGLE = 45

Smooth.WORKERS = 4 -- unions in flight at once
-- Each union is charged this much of the frame's shared time allowance
-- (Shared.Perf): the engine does the work, so it can't be timed from here.
-- With building going on in the same frame, unions wait their turn.
Smooth.UNION_COST = 0.0008 -- seconds
Smooth.PENDING_ATTRIBUTE = "SmoothPending" -- unions still to come on a model (Habitat counts here too)
-- Seconds (and at least this many frames) a shown plant keeps the pieces a
-- union replaced, so the union is drawing before they go.
Smooth.PIECE_LINGER = 0.6
Smooth.PIECE_LINGER_FRAMES = 12

local Workspace = game:GetService("Workspace")

-- Wait until both `seconds` and `frames` frames have gone by.
function Smooth.waitDrawn(seconds: number, frames: number)
	local start = os.clock()
	local n = 0
	while n < frames or os.clock() - start < seconds do
		task.wait()
		n += 1
	end
end

local function count(model: Model, by: number)
	local n = (model:GetAttribute(Smooth.PENDING_ATTRIBUTE) or 0) + by
	model:SetAttribute(Smooth.PENDING_ATTRIBUTE, math.max(n, 0))
end

-- A model still being built (a big plant is built over several frames, see
-- PlantBuilder options.breathe) is held: its unions, and Habitat's room
-- shells, wait until whoever is building it has finished and put it where
-- it belongs, then calls Smooth.release. Without that they would start on
-- a half-built model with no parent and be skipped.
local HOLD_MAX = 30 -- seconds; a hold older than this is forgotten (its builder must have failed)
local held: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any

function Smooth.hold(model: Model)
	held[model] = os.clock()
end

function Smooth.release(model: Model)
	held[model] = nil
end

function Smooth.isHeld(model: Model): boolean
	local since = held[model]
	if since and os.clock() - since > HOLD_MAX then
		held[model] = nil
		return false
	end
	return since ~= nil
end

local queue = WorkQueue.new()
local running = 0

local function unionOf(group: { BasePart }): BasePart?
	local rest = table.move(group, 2, #group, 1, {})
	local ok, result = pcall(function()
		local GeometryService = game:GetService("GeometryService")
		return GeometryService:UnionAsync(group[1], rest, {
			CollisionFidelity = Enum.CollisionFidelity.Box,
			RenderFidelity = Enum.RenderFidelity.Automatic,
			SplitApart = false,
		})
	end)
	if ok and type(result) == "table" and result[1] and result[1]:IsA("BasePart") then
		return result[1]
	end
	-- Older API.
	local ok2, union = pcall(function()
		return group[1]:UnionAsync(rest, Enum.CollisionFidelity.Box, Enum.RenderFidelity.Automatic)
	end)
	if ok2 and union then
		return union
	end
	warn("[Smooth] couldn't union a plant's pieces, keeping them as they are:", result, union)
	Smooth.ENABLED = false
	return nil
end

local function smoothOne(model: Model, group: { BasePart })
	local live = {}
	for _, p in group do
		if p.Parent == model then
			table.insert(live, p)
		end
	end
	if #live < 2 then
		return
	end
	-- The renderer may move the pieces while the union is made: remember one
	-- piece's pose, and put the union back relative to it afterwards.
	local ref = live[1]
	local refBefore = ref.CFrame
	local union = unionOf(live)
	if not union then
		return
	end
	if not model.Parent or not ref.Parent then
		union:Destroy()
		return
	end
	union.Name = ref.Name
	union.CFrame = ref.CFrame * refBefore:ToObjectSpace(union.CFrame)
	union.Anchored = true
	union.CanCollide = false
	union.CanQuery = false
	union.CanTouch = false
	union.CastShadow = ref.CastShadow
	union.Reflectance = ref.Reflectance -- a fire plant's metal leaves shine (Palette.REFLECT_FIRE)
	local op = union :: any
	pcall(function()
		op.UsePartColor = false
		op.SmoothingAngle = Smooth.SMOOTHING_ANGLE
	end)
	local link = Instance.new("ObjectValue")
	link.Name = "SwayRef" -- PlantRenderer sways the union as it swayed this piece
	link.Value = ref
	link.Parent = union
	union.Parent = model
	if model:IsDescendantOf(Workspace) then
		-- shown already: keep the pieces until the union draws
		task.spawn(function()
			Smooth.waitDrawn(Smooth.PIECE_LINGER, Smooth.PIECE_LINGER_FRAMES)
			for _, p in live do
				p:Destroy()
			end
		end)
	else
		for _, p in live do
			p:Destroy()
		end
	end
end

local function drain()
	while WorkQueue.count(queue) > 0 do
		local job = WorkQueue.pop(queue)
		if Smooth.ENABLED and Smooth.isHeld(job.model) then
			WorkQueue.push(queue, job) -- still being built: come back to it
			task.wait()
		elseif Smooth.ENABLED and job.model.Parent then
			local waited = 0
			while Perf.busy() and waited < 6 do
				waited += 1
				task.wait() -- this frame's allowance is spent: try the next (never starve, though)
			end
			if not job.model.Parent then
				count(job.model, -1) -- replaced while it waited
				continue
			end
			Perf.charge(Smooth.UNION_COST)
			pcall(smoothOne, job.model, job.group)
			count(job.model, -1)
			task.wait() -- spread the work over frames
		else
			-- A replaced plant (rebuilt at another stage or detail) is skipped at once.
			count(job.model, -1)
		end
	end
	running -= 1
end

-- Do this model's unions next (a plant you just watered, so its new
-- stage shows quickly instead of waiting behind every other plant's).
function Smooth.rush(model: Model)
	local mine, rest = {}, {}
	for _, job in WorkQueue.values(queue) do
		table.insert(if job.model == model then mine else rest, job)
	end
	if #mine == 0 then
		return
	end
	table.move(rest, 1, #rest, #mine + 1, mine)
	queue = WorkQueue.new(mine)
end

function Smooth.queue(model: Model, groups: { { BasePart } })
	if not Smooth.ENABLED then
		return
	end
	for _, group in groups do
		WorkQueue.push(queue, { model = model, group = group })
	end
	count(model, #groups)
	while running < Smooth.WORKERS and running < WorkQueue.count(queue) do
		running += 1
		task.defer(drain) -- after the renderer has parented the model
	end
end

return Smooth
