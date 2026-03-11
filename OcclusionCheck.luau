local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local RENDER_DISTANCE_SQUARED: number = 500 * 500
local CACHE_REFRESH_INTERVAL: number = 1
local ITERATION_YIELD_INTERVAL: number = 50
local RAY_PARALLEL_EPSILON: number = 1e-5
local DISTANCE_MINIMUM_EPSILON: number = 1e-10

local mathSqrt: (number) -> number = math.sqrt
local mathAbs: (number) -> number = math.abs
local mathMax: (number, number) -> number = math.max
local mathHuge: number = math.huge

local fnAddModelData: (data: { [string]: any }, key: string) -> boolean = add_model_data
local fnEditModelData: (data: { [string]: any }, key: string) -> boolean = edit_model_data
local fnRemoveModelData: (key: string) -> boolean = remove_model_data

type OBBEntry = {
	PositionX: number, PositionY: number, PositionZ: number,
	RightAxisX: number, RightAxisY: number, RightAxisZ: number, HalfSizeX: number,
	UpAxisX: number,    UpAxisY: number,    UpAxisZ: number,    HalfSizeY: number,
	ForwardAxisX: number, ForwardAxisY: number, ForwardAxisZ: number, HalfSizeZ: number,
	BoundingSphereRadiusSquared: number,
}

type PlayerRecord = {
	Player: Player,
	Name: string,
	CachedCharacter: Model?,
	CachedHumanoid: Humanoid?,
	SubmitGeneration: number,
	HasModelData: boolean,
}

local LocalPlayer: Player = Players.LocalPlayer :: Player

local CachedWorldParts: { OBBEntry } = {}
local CachedWorldPartCount: number = 0
local CharacterRootSet: { [Instance]: boolean } = {}
local PlayerRecords: { PlayerRecord } = {}
local PlayerRecordCount: number = 0
local PlayerRecordIndex: { [Player]: number } = {}
local CurrentPlayerSet: { [Player]: boolean } = {}
local WhitelistBuffer: { Whitelisted: boolean } = { Whitelisted = false }

local CACHEABLE_CLASSES: { [string]: boolean } = {
	Part = true,
	MeshPart = true,
	UnionOperation = true,
}

local function IsCharacterDescendant(instance: Instance): boolean
	local current: Instance? = instance.Parent
	while current ~= nil and current ~= (workspace :: Instance) do
		if CharacterRootSet[current :: Instance] then
			return true
		end
		current = (current :: Instance).Parent
	end
	return false
end

local function CacheNearbyWorldParts(): ()
	local camera: Camera? = workspace.CurrentCamera
	if camera == nil then
		return
	end
	local camPos: Vector3 = (camera :: Camera).Position
	local camX: number = camPos.X
	local camY: number = camPos.Y
	local camZ: number = camPos.Z

	local parts: { OBBEntry } = CachedWorldParts
	local partCount: number = 0
	local yieldCounter: number = ITERATION_YIELD_INTERVAL
	local descendants: { Instance } = workspace:GetDescendants()

	for i: number = 1, #descendants do
		local inst: Instance = descendants[i]
		if CACHEABLE_CLASSES[inst.ClassName] and inst.Parent ~= nil and not IsCharacterDescendant(inst) then
			local bp: BasePart = inst :: BasePart
			local pos: Vector3 = bp.Position
			local dx: number = pos.X - camX
			local dy: number = pos.Y - camY
			local dz: number = pos.Z - camZ
			if dx * dx + dy * dy + dz * dz <= RENDER_DISTANCE_SQUARED then
				local sz: Vector3 = bp.Size
				local hx: number = sz.X * 0.5
				local hy: number = sz.Y * 0.5
				local hz: number = sz.Z * 0.5
				local rv: Vector3 = bp.RightVector
				local uv: Vector3 = bp.UpVector
				local lv: Vector3 = bp.LookVector
				local bsr: number = hx * hx + hy * hy + hz * hz
				partCount += 1
				local entry: OBBEntry? = parts[partCount]
				if entry ~= nil then
					local e: OBBEntry = entry :: OBBEntry
					e.PositionX    = pos.X
					e.PositionY    = pos.Y
					e.PositionZ    = pos.Z
					e.RightAxisX   = rv.X
					e.RightAxisY   = rv.Y
					e.RightAxisZ   = rv.Z
					e.HalfSizeX    = hx
					e.UpAxisX      = uv.X
					e.UpAxisY      = uv.Y
					e.UpAxisZ      = uv.Z
					e.HalfSizeY    = hy
					e.ForwardAxisX = -lv.X
					e.ForwardAxisY = -lv.Y
					e.ForwardAxisZ = -lv.Z
					e.HalfSizeZ    = hz
					e.BoundingSphereRadiusSquared = bsr
				else
					parts[partCount] = {
						PositionX    = pos.X,   PositionY    = pos.Y,   PositionZ    = pos.Z,
						RightAxisX   = rv.X,    RightAxisY   = rv.Y,    RightAxisZ   = rv.Z,   HalfSizeX = hx,
						UpAxisX      = uv.X,    UpAxisY      = uv.Y,    UpAxisZ      = uv.Z,   HalfSizeY = hy,
						ForwardAxisX = -lv.X,   ForwardAxisY = -lv.Y,   ForwardAxisZ = -lv.Z,  HalfSizeZ = hz,
						BoundingSphereRadiusSquared = bsr,
					}
				end
			end
		end
		yieldCounter -= 1
		if yieldCounter == 0 then
			yieldCounter = ITERATION_YIELD_INTERVAL
			task.wait()
		end
	end

	for i: number = partCount + 1, #parts do
		parts[i] = nil :: any
	end

	CachedWorldPartCount = partCount
end

local function RayOBBIntersect(
	rox: number, roy: number, roz: number,
	rdx: number, rdy: number, rdz: number,
	box: OBBEntry
): number?
	local ox: number = box.PositionX - rox
	local oy: number = box.PositionY - roy
	local oz: number = box.PositionZ - roz
	local tMin: number = -mathHuge
	local tMax: number = mathHuge
	local proj: number
	local dot: number
	local near: number
	local far: number
	local half: number

	proj = box.RightAxisX * ox + box.RightAxisY * oy + box.RightAxisZ * oz
	dot  = box.RightAxisX * rdx + box.RightAxisY * rdy + box.RightAxisZ * rdz
	half = box.HalfSizeX
	if mathAbs(dot) > RAY_PARALLEL_EPSILON then
		near = (proj + half) / dot
		far  = (proj - half) / dot
		if near > far then near, far = far, near end
		if near > tMin then tMin = near end
		if far  < tMax then tMax = far  end
		if tMin > tMax or tMax < RAY_PARALLEL_EPSILON then return nil end
	elseif -proj - half > 0 or -proj + half < 0 then
		return nil
	end

	proj = box.UpAxisX * ox + box.UpAxisY * oy + box.UpAxisZ * oz
	dot  = box.UpAxisX * rdx + box.UpAxisY * rdy + box.UpAxisZ * rdz
	half = box.HalfSizeY
	if mathAbs(dot) > RAY_PARALLEL_EPSILON then
		near = (proj + half) / dot
		far  = (proj - half) / dot
		if near > far then near, far = far, near end
		if near > tMin then tMin = near end
		if far  < tMax then tMax = far  end
		if tMin > tMax or tMax < RAY_PARALLEL_EPSILON then return nil end
	elseif -proj - half > 0 or -proj + half < 0 then
		return nil
	end

	proj = box.ForwardAxisX * ox + box.ForwardAxisY * oy + box.ForwardAxisZ * oz
	dot  = box.ForwardAxisX * rdx + box.ForwardAxisY * rdy + box.ForwardAxisZ * rdz
	half = box.HalfSizeZ
	if mathAbs(dot) > RAY_PARALLEL_EPSILON then
		near = (proj + half) / dot
		far  = (proj - half) / dot
		if near > far then near, far = far, near end
		if near > tMin then tMin = near end
		if far  < tMax then tMax = far  end
		if tMin > tMax or tMax < RAY_PARALLEL_EPSILON then return nil end
	elseif -proj - half > 0 or -proj + half < 0 then
		return nil
	end

	return mathMax(0, tMin)
end

local function IsPositionOccluded(
	cx: number, cy: number, cz: number,
	tx: number, ty: number, tz: number
): boolean
	local dx: number = tx - cx
	local dy: number = ty - cy
	local dz: number = tz - cz
	local distSq: number = dx * dx + dy * dy + dz * dz
	if distSq < DISTANCE_MINIMUM_EPSILON then
		return false
	end
	local invMag: number = 1 / mathSqrt(distSq)
	local rdx: number = dx * invMag
	local rdy: number = dy * invMag
	local rdz: number = dz * invMag
	local rayLen: number = 1 / invMag
	local parts: { OBBEntry } = CachedWorldParts
	local count: number = CachedWorldPartCount
	for i: number = 1, count do
		local box: OBBEntry = parts[i]
		local bx: number = box.PositionX - cx
		local by: number = box.PositionY - cy
		local bz: number = box.PositionZ - cz
		local ca: number = bx * rdx + by * rdy + bz * rdz
		local perpSq: number = bx * bx + by * by + bz * bz - ca * ca
		if perpSq <= box.BoundingSphereRadiusSquared then
			local t: number? = RayOBBIntersect(cx, cy, cz, rdx, rdy, rdz, box)
			if t ~= nil and t < rayLen then
				return true
			end
		end
	end
	return false
end

local function SubmitCharacterData(player: Player, character: Model, record: PlayerRecord, generation: number): boolean
	if record.SubmitGeneration ~= generation then
		return true
	end
	local primaryPart: BasePart? = character.PrimaryPart
	local head: Instance? = character:FindFirstChild("Head")
	local torso: Instance? = character:FindFirstChild("HumanoidRootPart")
	local humanoid: Instance? = character:FindFirstChildOfClass("Humanoid")
	if primaryPart == nil or head == nil or torso == nil or humanoid == nil then
		return false
	end
	local leftLeg: Instance = character:FindFirstChild("LeftLeg") or character:FindFirstChild("LeftLowerLeg") or (primaryPart :: Instance)
	local rightLeg: Instance = character:FindFirstChild("RightLeg") or character:FindFirstChild("RightLowerLeg") or (primaryPart :: Instance)
	local leftArm: Instance = character:FindFirstChild("LeftArm") or character:FindFirstChild("LeftLowerArm") or (primaryPart :: Instance)
	local rightArm: Instance = character:FindFirstChild("RightArm") or character:FindFirstChild("RightLowerArm") or (primaryPart :: Instance)
	local rigType: number = if character:FindFirstChild("LowerTorso") ~= nil then 1 else 0
	local bhsObject: Instance? = character:FindFirstChild("BodyHeightScale")
	local bodyHeightScale: number = if bhsObject ~= nil then (bhsObject :: NumberValue).Value else 1
	if record.SubmitGeneration ~= generation then
		return true
	end
	if record.HasModelData then
		fnRemoveModelData(record.Name)
	end
	local hum: Humanoid = humanoid :: Humanoid
	fnAddModelData({
		Username        = record.Name,
		Displayname     = player.DisplayName,
		Userid          = player.UserId,
		Character       = character,
		PrimaryPart     = primaryPart,
		Head            = head,
		Torso           = torso,
		LeftLeg         = leftLeg,
		RightLeg        = rightLeg,
		LeftArm         = leftArm,
		RightArm        = rightArm,
		Humanoid        = hum,
		Health          = hum.Health,
		MaxHealth       = hum.MaxHealth,
		Toolname        = "",
		Teamname        = "",
		BodyHeightScale = bodyHeightScale,
		RigType         = rigType,
		Whitelisted     = false,
		Archenemies     = false,
		Aimbot_Part     = head,
		Aimbot_TP_Part  = torso,
		Triggerbot_Part = head,
		body_parts_data = {},
		full_body_data  = {},
	}, record.Name)
	record.HasModelData = true
	record.CachedHumanoid = hum
	return true
end

local function WaitAndSubmitCharacter(player: Player, character: Model, record: PlayerRecord): ()
	local generation: number = record.SubmitGeneration
	task.spawn(function()
		while character.Parent ~= nil do
			if SubmitCharacterData(player, character, record, generation) then
				break
			end
			task.wait()
		end
	end)
end

local function AddPlayer(player: Player): ()
	if player == LocalPlayer or PlayerRecordIndex[player] ~= nil then
		return
	end
	local record: PlayerRecord = {
		Player           = player,
		Name             = player.Name,
		CachedCharacter  = nil,
		CachedHumanoid   = nil,
		SubmitGeneration = 0,
		HasModelData     = false,
	}
	PlayerRecordCount += 1
	PlayerRecords[PlayerRecordCount] = record
	PlayerRecordIndex[player] = PlayerRecordCount
	local character: Model? = player.Character
	if character ~= nil then
		record.CachedCharacter = character
		WaitAndSubmitCharacter(player, character :: Model, record)
	end
end

local function RemovePlayer(player: Player): ()
	local index: number? = PlayerRecordIndex[player]
	if index == nil then
		return
	end
	local i: number = index :: number
	local record: PlayerRecord = PlayerRecords[i]
	record.SubmitGeneration += 1
	if record.HasModelData then
		fnRemoveModelData(record.Name)
		record.HasModelData = false
	end
	if i ~= PlayerRecordCount then
		local lastRecord: PlayerRecord = PlayerRecords[PlayerRecordCount]
		PlayerRecords[i] = lastRecord
		PlayerRecordIndex[lastRecord.Player] = i
	end
	PlayerRecords[PlayerRecordCount] = nil :: any
	PlayerRecordIndex[player] = nil :: any
	PlayerRecordCount -= 1
end

local function SyncState(): ()
	table.clear(CurrentPlayerSet)
	table.clear(CharacterRootSet)
	for _, player: Player in Players:GetChildren() do
		CurrentPlayerSet[player] = true
		AddPlayer(player)
		local character: Model? = player.Character
		if character ~= nil then
			CharacterRootSet[character :: Instance] = true
		end
	end
	for i: number = PlayerRecordCount, 1, -1 do
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
	local camera: Camera? = workspace.CurrentCamera
	if camera == nil then
		return
	end
	local camPos: Vector3 = (camera :: Camera).Position
	local cx: number = camPos.X
	local cy: number = camPos.Y
	local cz: number = camPos.Z
	local records: { PlayerRecord } = PlayerRecords
	local wbuf: { Whitelisted: boolean } = WhitelistBuffer
	local localTeam: Team? = LocalPlayer.Team
	for i: number = 1, PlayerRecordCount do
		local record: PlayerRecord = records[i]
		local player: Player = record.Player
		if localTeam ~= nil and player.Team == localTeam then
			continue
		end
		local character: Model? = player.Character
		if character == nil then
			continue
		end
		if record.CachedCharacter ~= character then
			record.CachedCharacter = character
			record.CachedHumanoid = nil
			record.SubmitGeneration += 1
			WaitAndSubmitCharacter(player, character :: Model, record)
			continue
		end
		local humanoid: Humanoid? = record.CachedHumanoid
		if humanoid == nil then
			continue
		end
		if (humanoid :: Humanoid).Health <= 0 then
			wbuf.Whitelisted = true
			fnEditModelData(wbuf, record.Name)
			continue
		end
		local primaryPart: BasePart? = (character :: Model).PrimaryPart
		if primaryPart == nil then
			continue
		end
		local pos: Vector3 = (primaryPart :: BasePart).Position
		wbuf.Whitelisted = IsPositionOccluded(cx, cy, cz, pos.X, pos.Y, pos.Z)
		fnEditModelData(wbuf, record.Name)
	end
end)

print("Player Occlusion Detection Initilised")
