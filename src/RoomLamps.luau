--!strict
--[[
	Room lamps: the lights grown inside rooms (wall lamps, firefly lanterns,
	glow jars, stoves and fireplaces) and how they're marked for
	Client.RoomLamps, which makes them pool warm light on the floor and
	walls like the town path lanterns do.

	A room is built in design studs and scaled up afterwards (PlantBuilder
	ScaleTo), so a lamp's reach is noted here in the same build units as its
	bulb (LampReach, LampSize); the client turns that into real studs from
	the bulb's size in the world, whatever the scaling did to the light.

	FurnitureClient switches a lamp with RoomLamps.setOn (attribute LampOff)
	instead of Light.Enabled, because Client.RoomLamps decides which lamps
	are lit at all (only the nearest few, see Fidelity ROOM_LAMP_*).
]]

local CollectionService = game:GetService("CollectionService")

local RoomLamps = {}

RoomLamps.TAG = "RoomLamp"

-- Marks `light` on `part` as a room lamp reaching `reach` build studs
-- (the same units as part.Size when it was built), at `brightness`.
function RoomLamps.mark(light: Light, part: BasePart, reach: number, brightness: number)
	light:SetAttribute("LampReach", reach)
	light:SetAttribute("LampSize", part.Size.X)
	light:SetAttribute("LampBright", brightness)
	CollectionService:AddTag(light, RoomLamps.TAG)
end

function RoomLamps.isLamp(light: Instance): boolean
	return CollectionService:HasTag(light, RoomLamps.TAG)
end

-- Switches a light on or off (a room lamp by its LampOff attribute).
function RoomLamps.setOn(light: Light, on: boolean)
	if RoomLamps.isLamp(light) then
		if light:GetAttribute("LampOff") ~= (not on or nil) then
			light:SetAttribute("LampOff", if on then nil else true)
		end
		if not on then
			light.Enabled = false
		end
	else
		light.Enabled = on
	end
end

return RoomLamps
