local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local RENDER_DISTANCE_SQUARED = 500 * 500
local CACHE_REFRESH_INTERVAL = 1
local ITERATION_YIELD_INTERVAL = 50
local RAY_PARALLEL_EPSILON = 1e-5
local DISTANCE_MINIMUM_EPSILON = 1e-10

local mathSquareRoot = math.sqrt
local mathAbsolute = math.abs
local mathMaximum = math.max
local mathInfinity = math.huge

local LocalPlayer = Players.LocalPlayer
local CachedWorldParts = {}
local CachedWorldPartCount = 0
local RegisteredPlayerNames = {}
local ActivePlayers = {}
local ActivePlayerCount = 0
local WhitelistUpdateBuffer = { Whitelisted = false }

local function BuildIgnoredCharacterTable()
	local ignoredInstances = {}
	for _, player in Players:GetChildren() do
		local character = player.Character
		if character then
			ignoredInstances[character] = true
		end
	end
	return ignoredInstances
end

local function CacheNearbyWorldParts()
	local camera = workspace.CurrentCamera
	if not camera then return end
	local cameraPosition = camera.Position
	local cameraX = cameraPosition.X
	local cameraY = cameraPosition.Y
	local cameraZ = cameraPosition.Z
	local ignoredInstances = BuildIgnoredCharacterTable()
	local nearbyParts = {}
	local partCount = 0
	local iterationCount = 0
	local traversalStack = { workspace }
	local traversalStackSize = 1
	while traversalStackSize > 0 do
		local instance = traversalStack[traversalStackSize]
		traversalStack[traversalStackSize] = nil
		traversalStackSize = traversalStackSize - 1
		if instance and instance.Parent and not ignoredInstances[instance] then
			local className = instance.ClassName
			if className == "Part" or className == "MeshPart" or className == "UnionOperation" then
				local partPosition = instance.Position
				if partPosition then
					local deltaX = partPosition.X - cameraX
					local deltaY = partPosition.Y - cameraY
					local deltaZ = partPosition.Z - cameraZ
					if deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ <= RENDER_DISTANCE_SQUARED then
						local partCFrame = instance.CFrame
						local partSize = instance.Size
						if partCFrame and partSize then
							local rightVector = partCFrame.RightVector
							local upVector = partCFrame.UpVector
							local lookVector = partCFrame.LookVector
							local halfSizeX = partSize.X * 0.5
							local halfSizeY = partSize.Y * 0.5
							local halfSizeZ = partSize.Z * 0.5
							partCount = partCount + 1
							nearbyParts[partCount] = {
								PositionX = partPosition.X, PositionY = partPosition.Y, PositionZ = partPosition.Z,
								RightAxisX = rightVector.X,   RightAxisY = rightVector.Y,   RightAxisZ = rightVector.Z,   HalfSizeX = halfSizeX,
								UpAxisX = upVector.X,         UpAxisY = upVector.Y,         UpAxisZ = upVector.Z,         HalfSizeY = halfSizeY,
								ForwardAxisX = -lookVector.X, ForwardAxisY = -lookVector.Y, ForwardAxisZ = -lookVector.Z, HalfSizeZ = halfSizeZ,
								BoundingSphereRadiusSquared = halfSizeX * halfSizeX + halfSizeY * halfSizeY + halfSizeZ * halfSizeZ,
							}
						end
					end
				end
			end
			local children = instance:GetChildren()
			for childIndex = 1, #children do
				traversalStackSize = traversalStackSize + 1
				traversalStack[traversalStackSize] = children[childIndex]
			end
			iterationCount = iterationCount + 1
			if iterationCount % ITERATION_YIELD_INTERVAL == 0 then
				task.wait()
			end
		end
	end
	CachedWorldParts = nearbyParts
	CachedWorldPartCount = partCount
end

local function RayOrientedBoundingBoxIntersect(rayOriginX, rayOriginY, rayOriginZ, rayDirectionX, rayDirectionY, rayDirectionZ, orientedBox)
	local offsetX = orientedBox.PositionX - rayOriginX
	local offsetY = orientedBox.PositionY - rayOriginY
	local offsetZ = orientedBox.PositionZ - rayOriginZ
	local intersectionMinimum = -mathInfinity
	local intersectionMaximum = mathInfinity
	local axisProjection, slabDot, slabNear, slabFar, halfSize

	axisProjection = orientedBox.RightAxisX * offsetX + orientedBox.RightAxisY * offsetY + orientedBox.RightAxisZ * offsetZ
	slabDot = orientedBox.RightAxisX * rayDirectionX + orientedBox.RightAxisY * rayDirectionY + orientedBox.RightAxisZ * rayDirectionZ
	halfSize = orientedBox.HalfSizeX
	if mathAbsolute(slabDot) > RAY_PARALLEL_EPSILON then
		slabNear = (axisProjection + halfSize) / slabDot
		slabFar = (axisProjection - halfSize) / slabDot
		if slabNear > slabFar then slabNear, slabFar = slabFar, slabNear end
		if slabNear > intersectionMinimum then intersectionMinimum = slabNear end
		if slabFar < intersectionMaximum then intersectionMaximum = slabFar end
		if intersectionMinimum > intersectionMaximum or intersectionMaximum < RAY_PARALLEL_EPSILON then return nil end
	elseif (-axisProjection - halfSize > 0) or (-axisProjection + halfSize < 0) then
		return nil
	end

	axisProjection = orientedBox.UpAxisX * offsetX + orientedBox.UpAxisY * offsetY + orientedBox.UpAxisZ * offsetZ
	slabDot = orientedBox.UpAxisX * rayDirectionX + orientedBox.UpAxisY * rayDirectionY + orientedBox.UpAxisZ * rayDirectionZ
	halfSize = orientedBox.HalfSizeY
	if mathAbsolute(slabDot) > RAY_PARALLEL_EPSILON then
		slabNear = (axisProjection + halfSize) / slabDot
		slabFar = (axisProjection - halfSize) / slabDot
		if slabNear > slabFar then slabNear, slabFar = slabFar, slabNear end
		if slabNear > intersectionMinimum then intersectionMinimum = slabNear end
		if slabFar < intersectionMaximum then intersectionMaximum = slabFar end
		if intersectionMinimum > intersectionMaximum or intersectionMaximum < RAY_PARALLEL_EPSILON then return nil end
	elseif (-axisProjection - halfSize > 0) or (-axisProjection + halfSize < 0) then
		return nil
	end

	axisProjection = orientedBox.ForwardAxisX * offsetX + orientedBox.ForwardAxisY * offsetY + orientedBox.ForwardAxisZ * offsetZ
	slabDot = orientedBox.ForwardAxisX * rayDirectionX + orientedBox.ForwardAxisY * rayDirectionY + orientedBox.ForwardAxisZ * rayDirectionZ
	halfSize = orientedBox.HalfSizeZ
	if mathAbsolute(slabDot) > RAY_PARALLEL_EPSILON then
		slabNear = (axisProjection + halfSize) / slabDot
		slabFar = (axisProjection - halfSize) / slabDot
		if slabNear > slabFar then slabNear, slabFar = slabFar, slabNear end
		if slabNear > intersectionMinimum then intersectionMinimum = slabNear end
		if slabFar < intersectionMaximum then intersectionMaximum = slabFar end
		if intersectionMinimum > intersectionMaximum or intersectionMaximum < RAY_PARALLEL_EPSILON then return nil end
	elseif (-axisProjection - halfSize > 0) or (-axisProjection + halfSize < 0) then
		return nil
	end

	return mathMaximum(0, intersectionMinimum)
end

local function IsPositionOccluded(cameraX, cameraY, cameraZ, targetX, targetY, targetZ)
	local deltaX = targetX - cameraX
	local deltaY = targetY - cameraY
	local deltaZ = targetZ - cameraZ
	local distanceSquared = deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ
	if distanceSquared < DISTANCE_MINIMUM_EPSILON then return false end
	local inverseMagnitude = 1 / mathSquareRoot(distanceSquared)
	local rayDirectionX = deltaX * inverseMagnitude
	local rayDirectionY = deltaY * inverseMagnitude
	local rayDirectionZ = deltaZ * inverseMagnitude
	local rayLength = 1 / inverseMagnitude
	local localCachedParts = CachedWorldParts
	for partIndex = 1, CachedWorldPartCount do
		local orientedBox = localCachedParts[partIndex]
		local boxOffsetX = orientedBox.PositionX - cameraX
		local boxOffsetY = orientedBox.PositionY - cameraY
		local boxOffsetZ = orientedBox.PositionZ - cameraZ
		local closestApproach = boxOffsetX * rayDirectionX + boxOffsetY * rayDirectionY + boxOffsetZ * rayDirectionZ
		local perpendicularDistanceSquared = boxOffsetX * boxOffsetX + boxOffsetY * boxOffsetY + boxOffsetZ * boxOffsetZ - closestApproach * closestApproach
		if perpendicularDistanceSquared <= orientedBox.BoundingSphereRadiusSquared then
			local intersectionDistance = RayOrientedBoundingBoxIntersect(cameraX, cameraY, cameraZ, rayDirectionX, rayDirectionY, rayDirectionZ, orientedBox)
			if intersectionDistance ~= nil and intersectionDistance < rayLength then return true end
		end
	end
	return false
end

local function RegisterPlayerCharacter(player)
	if player == LocalPlayer then return end
	local character = player.Character
	if not character then return end
	local primaryPart = character.PrimaryPart
	local head = character:FindFirstChild("Head")
	local torso = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChild("Humanoid")
	if not primaryPart or not head or not torso or not humanoid then return end
	local leftLeg = character:FindFirstChild("LeftLeg") or character:FindFirstChild("LeftLowerLeg") or primaryPart
	local rightLeg = character:FindFirstChild("RightLeg") or character:FindFirstChild("RightLowerLeg") or primaryPart
	local leftArm = character:FindFirstChild("LeftArm") or character:FindFirstChild("LeftLowerArm") or primaryPart
	local rightArm = character:FindFirstChild("RightArm") or character:FindFirstChild("RightLowerArm") or primaryPart
	local rigType = character:FindFirstChild("LowerTorso") and 1 or 0
	local bodyHeightScaleObject = character:FindFirstChild("BodyHeightScale")
	local bodyHeightScale = bodyHeightScaleObject and bodyHeightScaleObject.Value or 1
	add_model_data({
		Username = player.Name,
		Displayname = player.DisplayName,
		Userid = player.UserId,
		Character = character,
		PrimaryPart = primaryPart,
		Head = head,
		Torso = torso,
		LeftLeg = leftLeg,
		RightLeg = rightLeg,
		LeftArm = leftArm,
		RightArm = rightArm,
		Humanoid = humanoid,
		Health = humanoid.Health,
		MaxHealth = humanoid.MaxHealth,
		Toolname = "",
		Teamname = "",
		BodyHeightScale = bodyHeightScale,
		RigType = rigType,
		Whitelisted = false,
		Archenemies = false,
		Aimbot_Part = head,
		Aimbot_TP_Part = torso,
		Triggerbot_Part = head,
		body_parts_data = {},
		full_body_data = {},
	}, player.Name)
	RegisteredPlayerNames[player.Name] = true
	ActivePlayerCount = ActivePlayerCount + 1
	ActivePlayers[ActivePlayerCount] = player
end

for _, player in Players:GetChildren() do
	RegisterPlayerCharacter(player)
end

task.spawn(CacheNearbyWorldParts)

task.spawn(function()
	while true do
		task.wait(CACHE_REFRESH_INTERVAL)
		task.spawn(CacheNearbyWorldParts)
	end
end)

RunService.Render:Connect(function()
	local camera = workspace.CurrentCamera
	if not camera then return end
	local cameraPosition = camera.Position
	local cameraPositionX = cameraPosition.X
	local cameraPositionY = cameraPosition.Y
	local cameraPositionZ = cameraPosition.Z
	local localActivePlayers = ActivePlayers
	local whitelistUpdateBuffer = WhitelistUpdateBuffer
	for playerIndex = 1, ActivePlayerCount do
		local player = localActivePlayers[playerIndex]
		if not RegisteredPlayerNames[player.Name] then continue end
		local character = player.Character
		if not character then continue end
		local primaryPart = character.PrimaryPart
		if not primaryPart then continue end
		local primaryPartPosition = primaryPart.Position
		whitelistUpdateBuffer.Whitelisted = IsPositionOccluded(cameraPositionX, cameraPositionY, cameraPositionZ, primaryPartPosition.X, primaryPartPosition.Y, primaryPartPosition.Z)
		edit_model_data(whitelistUpdateBuffer, player.Name)
	end
end)
