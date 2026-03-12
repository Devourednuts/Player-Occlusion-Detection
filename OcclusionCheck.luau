local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")

local RENDER_DISTANCE_SQUARED: number  = 500 * 500
local CACHE_REFRESH_INTERVAL:  number  = 0.3
local RAY_PARALLEL_EPSILON:    number  = 1e-5
local DISTANCE_MINIMUM_EPSILON: number = 1e-10

local mathSqrt: (number) -> number          = math.sqrt
local mathAbs:  (number) -> number          = math.abs
local mathMax:  (number, number) -> number  = math.max
local mathHuge: number                      = math.huge
local osClock:  () -> number                = os.clock
local tblClear                              = table.clear
local fnAddModelData:    (data: {[string]: any}, key: string) -> boolean = add_model_data
local fnEditModelData:   (data: {[string]: any}, key: string) -> boolean = edit_model_data
local fnRemoveModelData: (key: string) -> boolean                        = remove_model_data

type OBBEntry = {
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
local CachedWorldParts:     { OBBEntry }            = {}
local CachedWorldPartCount: number                  = 0
local CharacterRootSet:     { [Instance]: boolean } = {}
local PlayerRecords:        { PlayerRecord }        = {}
local PlayerRecordCount:    number                  = 0
local PlayerRecordIndex:    { [Player]: number }    = {}
local CurrentPlayerSet:     { [Player]: boolean }   = {}
local WhitelistBuffer:      { Whitelisted: boolean } = { Whitelisted = false }
local PendingSubmits:       { PendingSubmit }       = {}
local PendingSubmitCount:   number                  = 0
local _lastSync:            number                  = 0

local CACHEABLE_CLASSES: { [string]: boolean } = {
    Part           = true,
    MeshPart       = true,
    UnionOperation = true,
}

local function IsCharacterDescendant(instance: Instance): boolean
    local current: Instance? = instance.Parent
    while current ~= nil and current ~= (workspace :: Instance) do
        if CharacterRootSet[current :: Instance] then return true end
        current = (current :: Instance).Parent
    end
    return false
end

local function CacheChildren(parent: Instance, camX: number, camY: number, camZ: number)
    local parts = CachedWorldParts
    local count = CachedWorldPartCount
    for _, inst in parent:GetChildren() do
        if CACHEABLE_CLASSES[inst.ClassName] and inst.Parent ~= nil and not IsCharacterDescendant(inst) then
            local bp  = inst :: BasePart
            local pos = bp.Position
            local dx  = pos.X - camX ; local dy = pos.Y - camY ; local dz = pos.Z - camZ
            if dx*dx + dy*dy + dz*dz <= RENDER_DISTANCE_SQUARED then
                local sz  = bp.Size
                local hx  = sz.X * 0.5 ; local hy = sz.Y * 0.5 ; local hz = sz.Z * 0.5
                local rv  = bp.RightVector ; local uv = bp.UpVector ; local lv = bp.LookVector
                local bsr = hx*hx + hy*hy + hz*hz
                count += 1
                local e: OBBEntry? = parts[count]
                if e ~= nil then
                    local en = e :: OBBEntry
                    en.PositionX    = pos.X ; en.PositionY    = pos.Y ; en.PositionZ    = pos.Z
                    en.RightAxisX   = rv.X  ; en.RightAxisY   = rv.Y  ; en.RightAxisZ   = rv.Z  ; en.HalfSizeX = hx
                    en.UpAxisX      = uv.X  ; en.UpAxisY      = uv.Y  ; en.UpAxisZ      = uv.Z  ; en.HalfSizeY = hy
                    en.ForwardAxisX = -lv.X ; en.ForwardAxisY = -lv.Y ; en.ForwardAxisZ = -lv.Z ; en.HalfSizeZ = hz
                    en.BoundingSphereRadiusSquared = bsr
                else
                    parts[count] = {
                        PositionX = pos.X, PositionY = pos.Y, PositionZ = pos.Z,
                        RightAxisX = rv.X, RightAxisY = rv.Y, RightAxisZ = rv.Z, HalfSizeX = hx,
                        UpAxisX = uv.X, UpAxisY = uv.Y, UpAxisZ = uv.Z, HalfSizeY = hy,
                        ForwardAxisX = -lv.X, ForwardAxisY = -lv.Y, ForwardAxisZ = -lv.Z, HalfSizeZ = hz,
                        BoundingSphereRadiusSquared = bsr,
                    }
                end
            end
        end
        if inst:FindFirstChildOfClass("BasePart") ~= nil or inst:FindFirstChildOfClass("Model") ~= nil or inst:FindFirstChildOfClass("Folder") ~= nil then
            CachedWorldPartCount = count
            CacheChildren(inst, camX, camY, camZ)
            count = CachedWorldPartCount
        end
    end
    CachedWorldPartCount = count
end

local function CacheNearbyWorldParts()
    local cam = workspace.CurrentCamera
    if cam == nil then return end
    local p = cam.CFrame.Position
    CachedWorldPartCount = 0
    CacheChildren(workspace, p.X, p.Y, p.Z)
    local parts = CachedWorldParts
    for i = CachedWorldPartCount + 1, #parts do parts[i] = nil :: any end
end

local function RayOBBIntersect(
    rox: number, roy: number, roz: number,
    rdx: number, rdy: number, rdz: number,
    box: OBBEntry
): number?
    local ox = box.PositionX - rox ; local oy = box.PositionY - roy ; local oz = box.PositionZ - roz
    local tMin = -mathHuge ; local tMax = mathHuge
    local proj: number ; local dot: number ; local near: number ; local far: number ; local half: number
    proj = box.RightAxisX*ox + box.RightAxisY*oy + box.RightAxisZ*oz
    dot  = box.RightAxisX*rdx + box.RightAxisY*rdy + box.RightAxisZ*rdz ; half = box.HalfSizeX
    if mathAbs(dot) > RAY_PARALLEL_EPSILON then
        near = (proj+half)/dot ; far = (proj-half)/dot
        if near > far then near,far = far,near end
        if near > tMin then tMin = near end ; if far < tMax then tMax = far end
        if tMin > tMax or tMax < RAY_PARALLEL_EPSILON then return nil end
    elseif -proj-half > 0 or -proj+half < 0 then return nil end
    proj = box.UpAxisX*ox + box.UpAxisY*oy + box.UpAxisZ*oz
    dot  = box.UpAxisX*rdx + box.UpAxisY*rdy + box.UpAxisZ*rdz ; half = box.HalfSizeY
    if mathAbs(dot) > RAY_PARALLEL_EPSILON then
        near = (proj+half)/dot ; far = (proj-half)/dot
        if near > far then near,far = far,near end
        if near > tMin then tMin = near end ; if far < tMax then tMax = far end
        if tMin > tMax or tMax < RAY_PARALLEL_EPSILON then return nil end
    elseif -proj-half > 0 or -proj+half < 0 then return nil end
    proj = box.ForwardAxisX*ox + box.ForwardAxisY*oy + box.ForwardAxisZ*oz
    dot  = box.ForwardAxisX*rdx + box.ForwardAxisY*rdy + box.ForwardAxisZ*rdz ; half = box.HalfSizeZ
    if mathAbs(dot) > RAY_PARALLEL_EPSILON then
        near = (proj+half)/dot ; far = (proj-half)/dot
        if near > far then near,far = far,near end
        if near > tMin then tMin = near end ; if far < tMax then tMax = far end
        if tMin > tMax or tMax < RAY_PARALLEL_EPSILON then return nil end
    elseif -proj-half > 0 or -proj+half < 0 then return nil end
    return mathMax(0, tMin)
end

local function IsPositionOccluded(cx: number, cy: number, cz: number, tx: number, ty: number, tz: number): boolean
    local dx = tx-cx ; local dy = ty-cy ; local dz = tz-cz
    local distSq = dx*dx + dy*dy + dz*dz
    if distSq < DISTANCE_MINIMUM_EPSILON then return false end
    local invMag = 1 / mathSqrt(distSq)
    local rdx = dx*invMag ; local rdy = dy*invMag ; local rdz = dz*invMag
    local rayLen = 1 / invMag
    local parts = CachedWorldParts ; local count = CachedWorldPartCount
    for i = 1, count do
        local box = parts[i]
        local bx = box.PositionX-cx ; local by = box.PositionY-cy ; local bz = box.PositionZ-cz
        local ca = bx*rdx + by*rdy + bz*rdz
        if bx*bx + by*by + bz*bz - ca*ca <= box.BoundingSphereRadiusSquared then
            local t = RayOBBIntersect(cx, cy, cz, rdx, rdy, rdz, box)
            if t ~= nil and t < rayLen then return true end
        end
    end
    return false
end

local function TrySubmit(p: PendingSubmit): boolean
    local record    = p.Record
    local character = p.Character
    if record.SubmitGeneration ~= p.Generation then return true end
    if character.Parent == nil then return true end
    local primaryPart = character.PrimaryPart
    local head        = character:FindFirstChild("Head")
    local torso       = character:FindFirstChild("HumanoidRootPart")
    local humanoid    = character:FindFirstChildOfClass("Humanoid")
    if primaryPart == nil or head == nil or torso == nil or humanoid == nil then return false end
    local leftLeg  = character:FindFirstChild("LeftLeg")  or character:FindFirstChild("LeftLowerLeg")  or (primaryPart :: Instance)
    local rightLeg = character:FindFirstChild("RightLeg") or character:FindFirstChild("RightLowerLeg") or (primaryPart :: Instance)
    local leftArm  = character:FindFirstChild("LeftArm")  or character:FindFirstChild("LeftLowerArm")  or (primaryPart :: Instance)
    local rightArm = character:FindFirstChild("RightArm") or character:FindFirstChild("RightLowerArm") or (primaryPart :: Instance)
    local rigType  = if character:FindFirstChild("LowerTorso") ~= nil then 1 else 0
    local bhsObj   = character:FindFirstChild("BodyHeightScale")
    local bhs: number = if bhsObj ~= nil then (bhsObj :: NumberValue).Value else 1
    if record.SubmitGeneration ~= p.Generation then return true end
    if record.HasModelData then fnRemoveModelData(record.Name) end
    local hum = humanoid :: Humanoid
    fnAddModelData({
        Username        = record.Name,       Displayname     = p.Player.DisplayName,
        Userid          = p.Player.UserId,   Character       = character,
        PrimaryPart     = primaryPart,       Head            = head,
        Torso           = torso,             LeftLeg         = leftLeg,
        RightLeg        = rightLeg,          LeftArm         = leftArm,
        RightArm        = rightArm,          Humanoid        = hum,
        Health          = hum.Health,        MaxHealth       = hum.MaxHealth,
        Toolname        = "",                Teamname        = "",
        BodyHeightScale = bhs,               RigType         = rigType,
        Whitelisted     = false,             Archenemies     = false,
        Aimbot_Part     = head,              Aimbot_TP_Part  = torso,
        Triggerbot_Part = head,              body_parts_data = {},
        full_body_data  = {},
    }, record.Name)
    record.HasModelData   = true
    record.CachedHumanoid = hum
    return true
end

local function EnqueueSubmit(player: Player, character: Model, record: PlayerRecord)
    PendingSubmitCount += 1
    PendingSubmits[PendingSubmitCount] = { Player = player, Character = character, Record = record, Generation = record.SubmitGeneration }
end
local function FlushPendingSubmits()
    local i = 1
    while i <= PendingSubmitCount do
        if TrySubmit(PendingSubmits[i]) then
            PendingSubmits[i] = PendingSubmits[PendingSubmitCount]
            PendingSubmits[PendingSubmitCount] = nil :: any
            PendingSubmitCount -= 1
        else
            i += 1
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
    local i = index :: number ; local record = PlayerRecords[i]
    record.SubmitGeneration += 1
    if record.HasModelData then fnRemoveModelData(record.Name) ; record.HasModelData = false end
    if i ~= PlayerRecordCount then
        local last = PlayerRecords[PlayerRecordCount]
        PlayerRecords[i] = last ; PlayerRecordIndex[last.Player] = i
    end
    PlayerRecords[PlayerRecordCount] = nil :: any
    PlayerRecordIndex[player]        = nil :: any
    PlayerRecordCount -= 1
end

local function SyncState()
    tblClear(CurrentPlayerSet) ; tblClear(CharacterRootSet)
    for _, obj in Players:GetChildren() do
        if obj.ClassName ~= "Player" then continue end
        local p = obj :: Player
        CurrentPlayerSet[p] = true
        AddPlayer(p)
        local character = p.Character
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
    if now - _lastSync >= CACHE_REFRESH_INTERVAL then
        _lastSync = now
        SyncState()
        CacheNearbyWorldParts()
    end
    FlushPendingSubmits()
end)

RunService.PostLocal:Connect(function()
    if not isrbxactive() then return end
    local cam = workspace.CurrentCamera
    if cam == nil then return end
    local camPos = cam.CFrame.Position
    local cx = camPos.X ; local cy = camPos.Y ; local cz = camPos.Z
    local records   = PlayerRecords
    local wbuf      = WhitelistBuffer
    local localTeam = LocalPlayer.Team
    for i = 1, PlayerRecordCount do
        local record  = records[i]
        local player  = record.Player
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
            wbuf.Whitelisted = true
            fnEditModelData(wbuf, record.Name)
            continue
        end
        local primaryPart = (character :: Model).PrimaryPart
        if primaryPart == nil then continue end
        local pos = (primaryPart :: BasePart).Position
        wbuf.Whitelisted = IsPositionOccluded(cx, cy, cz, pos.X, pos.Y, pos.Z)
        fnEditModelData(wbuf, record.Name)
    end
end)
