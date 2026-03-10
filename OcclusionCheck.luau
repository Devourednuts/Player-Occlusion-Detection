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
local CharacterRoots = {}
local CharacterRootCount = 0
local PlayerRecords = {}
local PlayerRecordCount = 0
local PlayerRecordIndex = {}
local CurrentPlayerSet = {}
local WhitelistUpdateBuffer = { Whitelisted = false }

local function IsCharacterDescendant(instance)
	for i = 1, CharacterRootCount do
		if instance:IsDescendantOf(CharacterRoots[i]) then
			return true
		end
	end
	return false
end

local function CacheNearbyWorldParts()
	local camera = workspace.CurrentCamera
	if not camera then return end
	local cameraPosition = camera.Position
	local cameraX = cameraPosition.X
	local cameraY = cameraPosition.Y
	local cameraZ = cameraPosition.Z

	local cachedParts = CachedWorldParts
	local partCount = 0
	local iterationCount = 0
	local descendants = workspace:GetDescendants()

	for i = 1, #descendants do
		local instance = descendants[i]
		local className = instance.ClassName
		if (className == "Part" or className == "MeshPart" or className == "UnionOperation")
			and instance.Parent and not IsCharacterDescendant(instance) then
			local position = instance.Position
			local deltaX = position.X - cameraX
			local deltaY = position.Y - cameraY
			local deltaZ = position.Z - cameraZ
			if deltaX * deltaX + deltaY * deltaY + deltaZ * deltaZ <= RENDER_DISTANCE_SQUARED then
				local cframe = instance.CFrame
				local size = instance.Size
				local halfSizeX = size.X * 0.5
				local halfSizeY = size.Y * 0.5
				local halfSizeZ = size.Z * 0.5
				local rightVector = cframe.RightVector
				local upVector = cframe.UpVector
				local lookVector = cframe.LookVector
				local boundingRadiusSquared = halfSizeX * halfSizeX + halfSizeY * halfSizeY + halfSizeZ * halfSizeZ
				partCount += 1
				local entry = cachedParts[partCount]
				if entry then
					entry.PositionX = position.X
					entry.PositionY = position.Y
					entry.PositionZ = position.Z
					entry.RightAxisX = rightVector.X
					entry.RightAxisY = rightVector.Y
					entry.RightAxisZ = rightVector.Z
					entry.HalfSizeX = halfSizeX
					entry.UpAxisX = upVector.X
					entry.UpAxisY = upVector.Y
					entry.UpAxisZ = upVector.Z
					entry.HalfSizeY = halfSizeY
					entry.ForwardAxisX = -lookVector.X
					entry.ForwardAxisY = -lookVector.Y
					entry.ForwardAxisZ = -lookVector.Z
					entry.HalfSizeZ = halfSizeZ
					entry.BoundingSphereRadiusSquared = boundingRadiusSquared
				else
					cachedParts[partCount] = {
						PositionX = position.X,       PositionY = position.Y,       PositionZ = position.Z,
						RightAxisX = rightVector.X,   RightAxisY = rightVector.Y,   RightAxisZ = rightVector.Z,   HalfSizeX = halfSizeX,
						UpAxisX = upVector.X,         UpAxisY = upVector.Y,         UpAxisZ = upVector.Z,         HalfSizeY = halfSizeY,
						ForwardAxisX = -lookVector.X, ForwardAxisY = -lookVector.Y, ForwardAxisZ = -lookVector.Z, HalfSizeZ = halfSizeZ,
						BoundingSphereRadiusSquared = boundingRadiusSquared,
					}
				end
			end
		end
		iterationCount += 1
		if iterationCount % ITERATION_YIELD_INTERVAL == 0 then
			task.wait()
		end
	end

	for i = partCount + 1, #cachedParts do
		cachedParts[i] = nil
	end

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
	local localPartCount = CachedWorldPartCount
	for partIndex = 1, localPartCount do
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

local function SubmitCharacterData(player, character, record, generation)
	if record.SubmitGeneration ~= generation then return true end
	local primaryPart = character.PrimaryPart
	local head = character:FindFirstChild("Head")
	local torso = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChild("Humanoid")
	if not primaryPart or not head or not torso or not humanoid then return false end
	local leftLeg = character:FindFirstChild("LeftLeg") or character:FindFirstChild("LeftLowerLeg") or primaryPart
	local rightLeg = character:FindFirstChild("RightLeg") or character:FindFirstChild("RightLowerLeg") or primaryPart
	local leftArm = character:FindFirstChild("LeftArm") or character:FindFirstChild("LeftLowerArm") or primaryPart
	local rightArm = character:FindFirstChild("RightArm") or character:FindFirstChild("RightLowerArm") or primaryPart
	local rigType = character:FindFirstChild("LowerTorso") and 1 or 0
	local bodyHeightScaleObject = character:FindFirstChild("BodyHeightScale")
	local bodyHeightScale = bodyHeightScaleObject and bodyHeightScaleObject.Value or 1
	if record.SubmitGeneration ~= generation then return true end
	remove_model_data(record.Name)
	add_model_data({
		Username = record.Name,
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
	}, record.Name)
	record.CachedHumanoid = humanoid
	return true
end

local function WaitAndSubmitCharacter(player, character, record)
	local generation = record.SubmitGeneration
	task.spawn(function()
		while character.Parent do
			if SubmitCharacterData(player, character, record, generation) then break end
			task.wait()
		end
	end)
end

local function AddPlayer(player)
	if player == LocalPlayer then return end
	if PlayerRecordIndex[player] then return end
	local record = {
		Player = player,
		Name = player.Name,
		CachedCharacter = nil,
		CachedHumanoid = nil,
		SubmitGeneration = 0,
	}
	PlayerRecordCount += 1
	PlayerRecords[PlayerRecordCount] = record
	PlayerRecordIndex[player] = PlayerRecordCount
	local character = player.Character
	if character then
		record.CachedCharacter = character
		WaitAndSubmitCharacter(player, character, record)
	end
end

local function RemovePlayer(player)
	local index = PlayerRecordIndex[player]
	if not index then return end
	local record = PlayerRecords[index]
	record.SubmitGeneration += 1
	remove_model_data(record.Name)
	if index ~= PlayerRecordCount then
		local lastRecord = PlayerRecords[PlayerRecordCount]
		PlayerRecords[index] = lastRecord
		PlayerRecordIndex[lastRecord.Player] = index
	end
	PlayerRecords[PlayerRecordCount] = nil
	PlayerRecordIndex[player] = nil
	PlayerRecordCount -= 1
end

local function SyncState()
	local previousRootCount = CharacterRootCount
	CharacterRootCount = 0
	table.clear(CurrentPlayerSet)

	for _, player in Players:GetChildren() do
		CurrentPlayerSet[player] = true
		AddPlayer(player)
		local character = player.Character
		if character then
			CharacterRootCount += 1
			CharacterRoots[CharacterRootCount] = character
		end
	end

	for i = CharacterRootCount + 1, previousRootCount do
		CharacterRoots[i] = nil
	end

	for i = PlayerRecordCount, 1, -1 do
		if not CurrentPlayerSet[PlayerRecords[i].Player] then
			RemovePlayer(PlayerRecords[i].Player)
		end
	end
end

SyncState()

task.spawn(function()
	while true do
		SyncState()
		CacheNearbyWorldParts()
		task.wait(CACHE_REFRESH_INTERVAL)
	end
end)

RunService.Render:Connect(function()
	local camera = workspace.CurrentCamera
	if not camera then return end
	local cameraPosition = camera.Position
	local cameraPositionX = cameraPosition.X
	local cameraPositionY = cameraPosition.Y
	local cameraPositionZ = cameraPosition.Z
	local localPlayerRecords = PlayerRecords
	local whitelistUpdateBuffer = WhitelistUpdateBuffer
	local localPlayerTeam = LocalPlayer.Team
	for i = 1, PlayerRecordCount do
		local record = localPlayerRecords[i]
		local player = record.Player
		if localPlayerTeam ~= nil and player.Team == localPlayerTeam then continue end
		local character = player.Character
		if not character or character.ClassName ~= "Model" then continue end
		if record.CachedCharacter ~= character then
			record.CachedCharacter = character
			record.CachedHumanoid = nil
			record.SubmitGeneration += 1
			WaitAndSubmitCharacter(player, character, record)
			continue
		end
		local humanoid = record.CachedHumanoid
		if not humanoid then continue end
		if humanoid.Health <= 0 then
			whitelistUpdateBuffer.Whitelisted = true
			edit_model_data(whitelistUpdateBuffer, record.Name)
			continue
		end
		local primaryPart = character.PrimaryPart
		if not primaryPart then continue end
		local primaryPartPosition = primaryPart.Position
		whitelistUpdateBuffer.Whitelisted = IsPositionOccluded(cameraPositionX, cameraPositionY, cameraPositionZ, primaryPartPosition.X, primaryPartPosition.Y, primaryPartPosition.Z)
		edit_model_data(whitelistUpdateBuffer, record.Name)
	end
end)

print("Player Occlusion Detection Initilised")
