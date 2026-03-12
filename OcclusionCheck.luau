--!strict

local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local RENDER_DISTANCE_SQUARED:  number = 500 * 500
local CACHE_REFRESH_INTERVAL:   number = 0.3
local RAY_PARALLEL_EPSILON:     number = 1e-5
local DISTANCE_MINIMUM_EPSILON: number = 1e-10
local CHARACTER_ANCESTOR_LIMIT: number = 4

local mathSqrt   = math.sqrt
local mathAbs    = math.abs
local mathMax    = math.max
local mathHuge   = math.huge
local osClock    = os.clock
local tableClear = table.clear

local AddModelData:    (data: {[string]: any}, key: string) -> boolean = add_model_data
local EditModelData:   (data: {[string]: any}, key: string) -> boolean = edit_model_data
local RemoveModelData: (key: string) -> boolean                        = remove_model_data

type OrientedBoundingBoxEntry = {
    PositionX: number, PositionY: number, PositionZ: number,
    RightAxisX: number, RightAxisY: number, RightAxisZ: number, HalfSizeX: number,
    UpAxisX: number,    UpAxisY: number,    UpAxisZ: number,    HalfSizeY: number,
    ForwardAxisX: number, ForwardAxisY: number, ForwardAxisZ: number, HalfSizeZ: number,
    BoundingSphereRadiusSquared: number,
}

type PlayerRecord = {
    Player:           Player,
    Name:             string,
    CachedCharacter:  Model?,
    CachedHumanoid:   Humanoid?,
    SubmitGeneration: number,
    HasModelData:     boolean,
}

type PendingSubmit = {
    Player:     Player,
    Character:  Model,
    Record:     PlayerRecord,
    Generation: number,
}

local LocalPlayer: Player = Players.LocalPlayer :: Player

local CachedWorldParts:     { OrientedBoundingBoxEntry } = {}
local CachedWorldPartCount: number                        = 0
local CharacterRootSet:     { [Instance]: boolean }       = {}
local PlayerRecords:        { PlayerRecord }              = {}
local PlayerRecordCount:    number                        = 0
local PlayerRecordIndex:    { [Player]: number }          = {}
local CurrentPlayerSet:     { [Player]: boolean }         = {}
local WhitelistBuffer:      { Whitelisted: boolean }      = { Whitelisted = false }
local PendingSubmits:       { PendingSubmit }             = {}
local PendingSubmitCount:   number                        = 0
local LastSyncTime:         number                        = 0

local CACHEABLE_CLASSES: { [string]: boolean } = {
    Part           = true,
    MeshPart       = true,
    UnionOperation = true,
}

local BASEPART_CLASSES: { [string]: boolean } = {
    Part             = true,
    MeshPart         = true,
    UnionOperation   = true,
    SpawnLocation    = true,
    CornerWedgePart  = true,
    TrussPart        = true,
    WedgePart        = true,
}

local function IsCharacterDescendant(instance: Instance): boolean
    local current: Instance? = instance.Parent
    for _ = 1, CHARACTER_ANCESTOR_LIMIT do
        if current == nil or current == (workspace :: Instance) then return false end
        if CharacterRootSet[current :: Instance] then return true end
        current = (current :: Instance).Parent
    end
    return false
end

local function CacheNearbyWorldParts()
    local camera = workspace.CurrentCamera
    if camera == nil then return end
    local cameraPosition = camera.CFrame.Position
    local cameraX        = cameraPosition.X
    local cameraY        = cameraPosition.Y
    local cameraZ        = cameraPosition.Z
    local parts          = CachedWorldParts
    local count          = 0
    for _, instance in workspace:GetDescendants() do
        if not CACHEABLE_CLASSES[instance.ClassName] or instance.Parent == nil or IsCharacterDescendant(instance) then
            continue
        end
        local basePart = instance :: BasePart
        local cframe   = basePart.CFrame
        local position = cframe.Position
        local deltaX   = position.X - cameraX
        local deltaY   = position.Y - cameraY
        local deltaZ   = position.Z - cameraZ
        if deltaX*deltaX + deltaY*deltaY + deltaZ*deltaZ > RENDER_DISTANCE_SQUARED then continue end
        local size                        = basePart.Size
        local halfSizeX                   = size.X * 0.5
        local halfSizeY                   = size.Y * 0.5
        local halfSizeZ                   = size.Z * 0.5
        local rightVector                 = cframe.RightVector
        local upVector                    = cframe.UpVector
        local lookVector                  = cframe.LookVector
        local boundingSphereRadiusSquared = halfSizeX*halfSizeX + halfSizeY*halfSizeY + halfSizeZ*halfSizeZ
        count += 1
        local existingEntry: OrientedBoundingBoxEntry? = parts[count]
        if existingEntry ~= nil then
            local entry = existingEntry :: OrientedBoundingBoxEntry
            entry.PositionX    = position.X    ; entry.PositionY    = position.Y    ; entry.PositionZ    = position.Z
            entry.RightAxisX   = rightVector.X ; entry.RightAxisY   = rightVector.Y ; entry.RightAxisZ   = rightVector.Z ; entry.HalfSizeX = halfSizeX
            entry.UpAxisX      = upVector.X    ; entry.UpAxisY      = upVector.Y    ; entry.UpAxisZ      = upVector.Z    ; entry.HalfSizeY = halfSizeY
            entry.ForwardAxisX = -lookVector.X ; entry.ForwardAxisY = -lookVector.Y ; entry.ForwardAxisZ = -lookVector.Z ; entry.HalfSizeZ = halfSizeZ
            entry.BoundingSphereRadiusSquared = boundingSphereRadiusSquared
        else
            parts[count] = {
                PositionX = position.X, PositionY = position.Y, PositionZ = position.Z,
                RightAxisX = rightVector.X, RightAxisY = rightVector.Y, RightAxisZ = rightVector.Z, HalfSizeX = halfSizeX,
                UpAxisX = upVector.X, UpAxisY = upVector.Y, UpAxisZ = upVector.Z, HalfSizeY = halfSizeY,
                ForwardAxisX = -lookVector.X, ForwardAxisY = -lookVector.Y, ForwardAxisZ = -lookVector.Z, HalfSizeZ = halfSizeZ,
                BoundingSphereRadiusSquared = boundingSphereRadiusSquared,
            }
        end
    end
    for index = count + 1, #parts do parts[index] = nil :: any end
    CachedWorldPartCount = count
end

local function RayIntersectsOrientedBoundingBox(
    rayOriginX: number, rayOriginY: number, rayOriginZ: number,
    rayDirectionX: number, rayDirectionY: number, rayDirectionZ: number,
    boundingBox: OrientedBoundingBoxEntry
): number?
    local offsetX = boundingBox.PositionX - rayOriginX
    local offsetY = boundingBox.PositionY - rayOriginY
    local offsetZ = boundingBox.PositionZ - rayOriginZ
    local minimumIntersection = -mathHuge
    local maximumIntersection =  mathHuge
    local projection:    number
    local dotProduct:    number
    local nearDistance:  number
    local farDistance:   number
    local halfExtent:    number

    projection = boundingBox.RightAxisX*offsetX + boundingBox.RightAxisY*offsetY + boundingBox.RightAxisZ*offsetZ
    dotProduct = boundingBox.RightAxisX*rayDirectionX + boundingBox.RightAxisY*rayDirectionY + boundingBox.RightAxisZ*rayDirectionZ
    halfExtent = boundingBox.HalfSizeX
    if mathAbs(dotProduct) > RAY_PARALLEL_EPSILON then
        nearDistance = (projection + halfExtent) / dotProduct
        farDistance  = (projection - halfExtent) / dotProduct
        if nearDistance > farDistance then nearDistance, farDistance = farDistance, nearDistance end
        if nearDistance > minimumIntersection then minimumIntersection = nearDistance end
        if farDistance  < maximumIntersection then maximumIntersection = farDistance  end
        if minimumIntersection > maximumIntersection or maximumIntersection < RAY_PARALLEL_EPSILON then return nil end
    elseif -projection - halfExtent > 0 or -projection + halfExtent < 0 then return nil end

    projection = boundingBox.UpAxisX*offsetX + boundingBox.UpAxisY*offsetY + boundingBox.UpAxisZ*offsetZ
    dotProduct = boundingBox.UpAxisX*rayDirectionX + boundingBox.UpAxisY*rayDirectionY + boundingBox.UpAxisZ*rayDirectionZ
    halfExtent = boundingBox.HalfSizeY
    if mathAbs(dotProduct) > RAY_PARALLEL_EPSILON then
        nearDistance = (projection + halfExtent) / dotProduct
        farDistance  = (projection - halfExtent) / dotProduct
        if nearDistance > farDistance then nearDistance, farDistance = farDistance, nearDistance end
        if nearDistance > minimumIntersection then minimumIntersection = nearDistance end
        if farDistance  < maximumIntersection then maximumIntersection = farDistance  end
        if minimumIntersection > maximumIntersection or maximumIntersection < RAY_PARALLEL_EPSILON then return nil end
    elseif -projection - halfExtent > 0 or -projection + halfExtent < 0 then return nil end

    projection = boundingBox.ForwardAxisX*offsetX + boundingBox.ForwardAxisY*offsetY + boundingBox.ForwardAxisZ*offsetZ
    dotProduct = boundingBox.ForwardAxisX*rayDirectionX + boundingBox.ForwardAxisY*rayDirectionY + boundingBox.ForwardAxisZ*rayDirectionZ
    halfExtent = boundingBox.HalfSizeZ
    if mathAbs(dotProduct) > RAY_PARALLEL_EPSILON then
        nearDistance = (projection + halfExtent) / dotProduct
        farDistance  = (projection - halfExtent) / dotProduct
        if nearDistance > farDistance then nearDistance, farDistance = farDistance, nearDistance end
        if nearDistance > minimumIntersection then minimumIntersection = nearDistance end
        if farDistance  < maximumIntersection then maximumIntersection = farDistance  end
        if minimumIntersection > maximumIntersection or maximumIntersection < RAY_PARALLEL_EPSILON then return nil end
    elseif -projection - halfExtent > 0 or -projection + halfExtent < 0 then return nil end

    return mathMax(0, minimumIntersection)
end

local function IsPositionOccluded(
    cameraX: number, cameraY: number, cameraZ: number,
    targetX: number, targetY: number, targetZ: number
): boolean
    local directionX      = targetX - cameraX
    local directionY      = targetY - cameraY
    local directionZ      = targetZ - cameraZ
    local distanceSquared = directionX*directionX + directionY*directionY + directionZ*directionZ
    if distanceSquared < DISTANCE_MINIMUM_EPSILON then return false end
    local inverseMagnitude = 1 / mathSqrt(distanceSquared)
    local rayDirectionX    = directionX * inverseMagnitude
    local rayDirectionY    = directionY * inverseMagnitude
    local rayDirectionZ    = directionZ * inverseMagnitude
    local rayLength        = 1 / inverseMagnitude
    local parts = CachedWorldParts
    local count = CachedWorldPartCount
    for i = 1, count do
        local boundingBox      = parts[i]
        local boxOffsetX       = boundingBox.PositionX - cameraX
        local boxOffsetY       = boundingBox.PositionY - cameraY
        local boxOffsetZ       = boundingBox.PositionZ - cameraZ
        local centerProjection = boxOffsetX*rayDirectionX + boxOffsetY*rayDirectionY + boxOffsetZ*rayDirectionZ
        if boxOffsetX*boxOffsetX + boxOffsetY*boxOffsetY + boxOffsetZ*boxOffsetZ - centerProjection*centerProjection <= boundingBox.BoundingSphereRadiusSquared then
            local intersectionDistance = RayIntersectsOrientedBoundingBox(cameraX, cameraY, cameraZ, rayDirectionX, rayDirectionY, rayDirectionZ, boundingBox)
            if intersectionDistance ~= nil and intersectionDistance < rayLength then return true end
        end
    end
    return false
end

local function TrySubmit(pendingSubmit: PendingSubmit): boolean
    local record    = pendingSubmit.Record
    local character = pendingSubmit.Character
    if record.SubmitGeneration ~= pendingSubmit.Generation then return true end
    if character.Parent == nil then return true end
    if character.ClassName ~= "Model" then return true end
    local primaryPart        = character.PrimaryPart
    local head               = character:FindFirstChild("Head")
    local torso              = character:FindFirstChild("HumanoidRootPart")
    local humanoidObject     = character:FindFirstChildOfClass("Humanoid")
    if primaryPart == nil or head == nil or torso == nil or humanoidObject == nil then return false end
    local leftLeg  = character:FindFirstChild("LeftLeg")  or character:FindFirstChild("LeftLowerLeg")  or (primaryPart :: Instance)
    local rightLeg = character:FindFirstChild("RightLeg") or character:FindFirstChild("RightLowerLeg") or (primaryPart :: Instance)
    local leftArm  = character:FindFirstChild("LeftArm")  or character:FindFirstChild("LeftLowerArm")  or (primaryPart :: Instance)
    local rightArm = character:FindFirstChild("RightArm") or character:FindFirstChild("RightLowerArm") or (primaryPart :: Instance)
    local rigType: number         = if character:FindFirstChild("LowerTorso") ~= nil then 1 else 0
    local bodyHeightScaleObject   = character:FindFirstChild("BodyHeightScale")
    local bodyHeightScale: number = if bodyHeightScaleObject ~= nil then (bodyHeightScaleObject :: NumberValue).Value else 1
    if record.SubmitGeneration ~= pendingSubmit.Generation then return true end
    if record.HasModelData then RemoveModelData(record.Name) end
    local humanoid = humanoidObject :: Humanoid
    AddModelData({
        Username        = record.Name,                        Displayname     = pendingSubmit.Player.DisplayName,
        Userid          = pendingSubmit.Player.UserId,        Character       = character,
        PrimaryPart     = primaryPart,                        Head            = head,
        Torso           = torso,                              LeftLeg         = leftLeg,
        RightLeg        = rightLeg,                           LeftArm         = leftArm,
        RightArm        = rightArm,                           Humanoid        = humanoid,
        Health          = humanoid.Health,                    MaxHealth       = humanoid.MaxHealth,
        Toolname        = "",                                 Teamname        = "",
        BodyHeightScale = bodyHeightScale,                    RigType         = rigType,
        Whitelisted     = false,                              Archenemies     = false,
        Aimbot_Part     = head,                               Aimbot_TP_Part  = torso,
        Triggerbot_Part = head,                               body_parts_data = {},
        full_body_data  = {},
    }, record.Name)
    record.HasModelData   = true
    record.CachedHumanoid = humanoid
    return true
end

local function EnqueueSubmit(player: Player, character: Model, record: PlayerRecord)
    PendingSubmitCount += 1
    PendingSubmits[PendingSubmitCount] = { Player = player, Character = character, Record = record, Generation = record.SubmitGeneration }
end

local function FlushPendingSubmits()
    local index = 1
    while index <= PendingSubmitCount do
        if TrySubmit(PendingSubmits[index]) then
            PendingSubmits[index] = PendingSubmits[PendingSubmitCount]
            PendingSubmits[PendingSubmitCount] = nil :: any
            PendingSubmitCount -= 1
        else
            index += 1
        end
    end
end

local function AddPlayer(player: Player)
    if player == LocalPlayer or PlayerRecordIndex[player] ~= nil then return end
    local record: PlayerRecord = {
        Player = player, Name = player.Name, CachedCharacter = nil,
        CachedHumanoid = nil, SubmitGeneration = 0, HasModelData = false,
    }
    PlayerRecordCount += 1
    PlayerRecords[PlayerRecordCount] = record
    PlayerRecordIndex[player]        = PlayerRecordCount
    local character = player.Character
    if character ~= nil then
        record.CachedCharacter = character
        EnqueueSubmit(player, character :: Model, record)
    end
end

local function RemovePlayer(player: Player)
    local index = PlayerRecordIndex[player]
    if index == nil then return end
    local recordIndex = index :: number
    local record      = PlayerRecords[recordIndex]
    record.SubmitGeneration += 1
    if record.HasModelData then RemoveModelData(record.Name) ; record.HasModelData = false end
    if recordIndex ~= PlayerRecordCount then
        local lastRecord = PlayerRecords[PlayerRecordCount]
        PlayerRecords[recordIndex]           = lastRecord
        PlayerRecordIndex[lastRecord.Player] = recordIndex
    end
    PlayerRecords[PlayerRecordCount] = nil :: any
    PlayerRecordIndex[player]        = nil :: any
    PlayerRecordCount -= 1
end

local function SyncState()
    tableClear(CurrentPlayerSet) ; tableClear(CharacterRootSet)
    for _, object in Players:GetChildren() do
        if object.ClassName ~= "Player" then continue end
        local player = object :: Player
        CurrentPlayerSet[player] = true
        AddPlayer(player)
        local character = player.Character
        if character ~= nil then CharacterRootSet[character :: Instance] = true end
    end
    for i = PlayerRecordCount, 1, -1 do
        if not CurrentPlayerSet[PlayerRecords[i].Player] then RemovePlayer(PlayerRecords[i].Player) end
    end
end

SyncState()

RunService.PostModel:Connect(function()
    if not isrbxactive() then return end
    local now = osClock()
    if now - LastSyncTime >= CACHE_REFRESH_INTERVAL then
        LastSyncTime = now
        SyncState()
        CacheNearbyWorldParts()
    end
    FlushPendingSubmits()
end)

RunService.PostLocal:Connect(function()
    if not isrbxactive() then return end
    local camera = workspace.CurrentCamera
    if camera == nil then return end
    local cameraPosition  = camera.CFrame.Position
    local cameraX         = cameraPosition.X
    local cameraY         = cameraPosition.Y
    local cameraZ         = cameraPosition.Z
    local records         = PlayerRecords
    local whitelistBuffer = WhitelistBuffer
    local localTeam       = LocalPlayer.Team
    for i = 1, PlayerRecordCount do
        local record = records[i]
        local player = record.Player
        if localTeam ~= nil and player.Team == localTeam then continue end
        local character = player.Character
        if character == nil then continue end
        if record.CachedCharacter ~= character then
            record.CachedCharacter  = character
            record.CachedHumanoid   = nil
            record.SubmitGeneration += 1
            EnqueueSubmit(player, character :: Model, record)
            continue
        end
        local humanoid = record.CachedHumanoid
        if humanoid == nil then continue end
        if (humanoid :: Humanoid).Health <= 0 then
            whitelistBuffer.Whitelisted = true
            EditModelData(whitelistBuffer, record.Name)
            continue
        end
        local primaryPart = (character :: Model).PrimaryPart
        if primaryPart == nil or not BASEPART_CLASSES[primaryPart.ClassName] then continue end
        local position = (primaryPart :: BasePart).Position
        whitelistBuffer.Whitelisted = IsPositionOccluded(cameraX, cameraY, cameraZ, position.X, position.Y, position.Z)
        EditModelData(whitelistBuffer, record.Name)
    end
end)

print("Player Occlusion Detection Initilised")
