-- Royal High Campus 4 — Diamond Farm
-- GUI: LinoriaLib (violin-suzutsuki/LinoriaLib)
-- target: PlaceId 79319660271166 (Campus 4)
--
-- Anticheat notes (respected below):
--   * Server invokes GetGeometry on the client after each diamond touch — the client
--     must return valid math, geometry, PlayerHacked{} table. NEVER move the diamond
--     part or the geometry table gets a HACKED flag and credit is denied.
--   * PlayerHacked is set to {HACKED=true} when the character's PrimaryPart moves
--     more than 750 studs in a single Heartbeat frame. All character teleports below
--     step in 500-stud hops with a Heartbeat wait between hops.
--   * The Lost Books remote fires by name — the server owns the credit; the client
--     script rate-limits itself to 5 fires/sec so we do the same.

if not (game:GetService("Players").LocalPlayer) then return end
if _G.__RH_FARM_LOADED then _G.__RH_FARM_UNLOAD() end
_G.__RH_FARM_LOADED = true

------------------------------------------------------------------------
-- services / cache
------------------------------------------------------------------------
local Players            = game:GetService("Players")
local Workspace          = game:GetService("Workspace")
local RunService         = game:GetService("RunService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local StarterGui         = game:GetService("StarterGui")
local UserInputService   = game:GetService("UserInputService")
local VirtualUser        = game:GetService("VirtualUser")
local TweenService       = game:GetService("TweenService")

local LP = Players.LocalPlayer

local function character() return LP.Character end
local function hrp()
    local ch = LP.Character
    return ch and ch:FindFirstChild("HumanoidRootPart")
end
local function humanoid()
    local ch = LP.Character
    return ch and ch:FindFirstChildOfClass("Humanoid")
end

------------------------------------------------------------------------
-- lifecycle bag — every connection we make lands here so unload is clean
------------------------------------------------------------------------
local Bag = {conns = {}, loops = {}, restore = {}}
local function track(conn) table.insert(Bag.conns, conn); return conn end
local function newLoop(name, interval, fn)
    Bag.loops[name] = {alive = true, interval = interval, fn = fn}
    task.spawn(function()
        local loop = Bag.loops[name]
        while loop and loop.alive do
            local ok, err = pcall(loop.fn)
            if not ok then warn("[RH-Farm] loop "..name.." err: "..tostring(err)) end
            task.wait(loop.interval)
        end
    end)
end
local function killLoop(name)
    if Bag.loops[name] then Bag.loops[name].alive = false; Bag.loops[name] = nil end
end

------------------------------------------------------------------------
-- LinoriaLib load (with fallback URL)
------------------------------------------------------------------------
local function safeHttp(url)
    local ok, body = pcall(function() return game:HttpGet(url) end)
    if not ok then return nil end
    return body
end

local function loadLib(url)
    local body = safeHttp(url)
    if not body then return nil end
    local ok, mod = pcall(loadstring, body)
    if not ok or not mod then return nil end
    local ok2, res = pcall(mod)
    if not ok2 then return nil end
    return res
end

local Library      = loadLib("https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/Library.lua")
local ThemeManager = loadLib("https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/addons/ThemeManager.lua")
local SaveManager  = loadLib("https://raw.githubusercontent.com/violin-suzutsuki/LinoriaLib/main/addons/SaveManager.lua")

if not Library then
    warn("[RH-Farm] failed to load LinoriaLib — aborting")
    _G.__RH_FARM_LOADED = nil
    return
end

------------------------------------------------------------------------
-- window
------------------------------------------------------------------------
local Window = Library:CreateWindow({
    Title      = "Royal High — Diamond Farm",
    Center     = true,
    AutoShow   = true,
    TabPadding = 8,
    MenuFadeTime = 0.2,
})

local Tabs = {
    Main    = Window:AddTab("Diamonds"),
    Class   = Window:AddTab("Classes"),
    Utility = Window:AddTab("Utility"),
    Info    = Window:AddTab("Info"),
    Settings= Window:AddTab("Settings"),
}

------------------------------------------------------------------------
-- shared state
------------------------------------------------------------------------
local State = {
    AutoCollectDiamonds = false,
    AutoCollectBooks    = false,
    AutoReturnBooks     = false,
    AutoJoinClass       = false,
    AutoClassMinigame   = false,
    WalkSpeed           = 16,
    JumpPower           = 50,
    InfiniteJump        = false,
    AntiAFK             = false,
    NoclipDiamonds      = false,   -- for pickup only, temporary during hop
    DiamondsCollected   = 0,
    BooksCollected      = 0,
}

------------------------------------------------------------------------
-- safe character teleport — respects the >750 stud/frame anticheat gate
------------------------------------------------------------------------
local MAX_STEP = 500  -- well under the 750 threshold; leaves margin for lag

local function safeTeleport(targetPos)
    local root = hrp()
    if not root then return false end
    local start = root.Position
    local dir = targetPos - start
    local dist = dir.Magnitude
    if dist < 0.1 then return true end
    local steps = math.ceil(dist / MAX_STEP)
    for i = 1, steps do
        root = hrp()
        if not root then return false end
        local frac = i / steps
        local pos = start:Lerp(targetPos, frac)
        root.CFrame = CFrame.new(pos)
        RunService.Heartbeat:Wait()
    end
    return true
end

------------------------------------------------------------------------
-- Diamond Farm — workspace.CollectibleDiamonds
------------------------------------------------------------------------
local function getCollectibleDiamonds()
    return Workspace:FindFirstChild("CollectibleDiamonds")
end

local function diamondFarmTick()
    local folder = getCollectibleDiamonds()
    if not folder then return end
    local hum = humanoid()
    if not hum or hum.Health <= 0 then return end
    for _, d in ipairs(folder:GetChildren()) do
        if not State.AutoCollectDiamonds then break end
        if d:IsA("BasePart") and d.Parent == folder then
            local pos = d.Position
            local start = hrp() and hrp().Position
            if start then
                safeTeleport(pos + Vector3.new(0, 2, 0))
                -- give the server 1 heartbeat to observe the touch and fire GetGeometry
                RunService.Heartbeat:Wait()
                RunService.Heartbeat:Wait()
                State.DiamondsCollected = State.DiamondsCollected + 1
            end
        end
    end
end

------------------------------------------------------------------------
-- Lost Books Farm — workspace.ActiveLostBooks
------------------------------------------------------------------------
local function getLostBooksRemote()
    local server = Workspace:FindFirstChild("LostBooksServer")
    return server and server:FindFirstChild("LostBooksRemote")
end

local function bookFarmTick()
    local folder = Workspace:FindFirstChild("ActiveLostBooks")
    local remote = getLostBooksRemote()
    if not folder or not remote then return end
    for _, b in ipairs(folder:GetChildren()) do
        if not State.AutoCollectBooks then break end
        if b:IsA("BasePart") and b.Transparency < 0.9 then
            -- match the vanilla client's fire signature exactly
            local ok = pcall(function()
                remote:FireServer("Get", b.Name)
            end)
            if ok then
                State.BooksCollected = State.BooksCollected + 1
                -- vanilla script gates at 0.2s per fire; honour it
                task.wait(0.22)
            end
        end
    end
end

local function returnBooksTick()
    local returnPart = Workspace:FindFirstChild("LostBooksReturn")
    if not returnPart then return end
    local prompt = returnPart:FindFirstChildOfClass("ProximityPrompt")
        or (returnPart:FindFirstChild("ProximityPromptPart") and returnPart.ProximityPromptPart:FindFirstChildOfClass("ProximityPrompt"))
    if not prompt then
        for _, d in ipairs(returnPart:GetDescendants()) do
            if d:IsA("ProximityPrompt") then prompt = d; break end
        end
    end
    if not prompt then return end
    -- only return when it's actually giving books (Enabled) and the character
    -- is within a reasonable magnitude — this mirrors real interaction
    if prompt.Enabled and hrp() then
        local anchor = prompt.Parent
        if anchor and anchor:IsA("BasePart") then
            local mag = (anchor.Position - hrp().Position).Magnitude
            if mag > (prompt.MaxActivationDistance or 10) then
                safeTeleport(anchor.Position + Vector3.new(0, 3, 4))
                RunService.Heartbeat:Wait()
            end
            pcall(function()
                fireproximityprompt(prompt, prompt.HoldDuration or 0)
            end)
        end
    end
end

------------------------------------------------------------------------
-- Auto Join Class — the confirmation dialog fires ClassroomDoorGui:FireServer()
------------------------------------------------------------------------
local ClassroomDoorGui = ReplicatedStorage:WaitForChild("ClassroomDoorGui", 10)

local function bindAutoJoin()
    if not ClassroomDoorGui then return end
    track(ClassroomDoorGui.OnClientEvent:Connect(function(visible)
        if visible and State.AutoJoinClass then
            task.wait(0.3)
            pcall(function()
                ClassroomDoorGui:FireServer()
            end)
        end
    end))
end

------------------------------------------------------------------------
-- Auto Complete Class Minigames — generic dispatcher
--
-- RH classroom minigames each have their own Workspace.*.Client script that
-- appears when you're actually in the classroom. We hook the ones that we
-- can safely automate without moving diamonds or breaching the geometry AC.
------------------------------------------------------------------------
local ClassHandlers = {}

-- Stamping (Home Ec) — StampingMinigameRemote:FireServer("Stamp", score)
ClassHandlers.Stamping = function()
    local server = Workspace:FindFirstChild("StampingMinigame") or Workspace:FindFirstChild("StampingMinigameServer")
    if not server then return end
    local remote = server:FindFirstChild("StampingMinigameRemote", true)
    if not remote then return end
    pcall(function() remote:FireServer("Stamp", 100) end)
end

-- Flight (Airborne / Flight class) — FlightMinigameRemote:FireServer("GetRing", ringId)
ClassHandlers.Flight = function()
    local remote = Workspace:FindFirstChild("FlightMinigameRemote", true)
        or ReplicatedStorage:FindFirstChild("FlightMinigameRemote", true)
    if not remote then return end
    local ringFolder = Workspace:FindFirstChild("FlightRings") or Workspace:FindFirstChild("Rings", true)
    if not ringFolder then return end
    for _, r in ipairs(ringFolder:GetChildren()) do
        if r:IsA("BasePart") and r.Transparency < 0.9 then
            pcall(function() remote:FireServer("GetRing", r.Name) end)
            task.wait(0.05)
        end
    end
end

-- Slide (Water slide relay) — GetCurrentMovement / RunMovement
ClassHandlers.Slide = function()
    -- passive: RH slides give diamonds just for finishing, walking works fine
end

-- Secret Brick Door — MainCampusSecretEvents.Submit:FireServer
ClassHandlers.SecretDoor = function()
    local part = Workspace:FindFirstChild("SecretBrickDoor")
    if not part then return end
    local ev = ReplicatedStorage:FindFirstChild("MainCampusSecretEvents", true)
    if ev and ev:FindFirstChild("Submit") then
        pcall(function() ev.Submit:FireServer(true) end)
    end
end

-- Attic key (bookshelf) — AtticKeyRemote:FireServer("Get", key)
ClassHandlers.Attic = function()
    local server = Workspace:FindFirstChild("ATTIC") and Workspace.ATTIC:FindFirstChild("AtticKeyServer")
    if not server then return end
    local remote = server:FindFirstChild("AtticKeyRemote")
    if not remote then return end
    local keys = Workspace:FindFirstChild("AtticKeys") or Workspace:FindFirstChild("ActiveAtticKeys")
    if not keys then return end
    for _, k in ipairs(keys:GetChildren()) do
        if k:IsA("BasePart") then
            pcall(function() remote:FireServer("Get", k.Name) end)
            task.wait(0.15)
        end
    end
end

local function classMinigameTick()
    if not State.AutoClassMinigame then return end
    for _, handler in pairs(ClassHandlers) do
        pcall(handler)
    end
end

------------------------------------------------------------------------
-- Utility: WalkSpeed / JumpPower — client-only, does NOT trigger the
-- >750-stud teleport detector because vanilla Humanoid movement uses
-- normal replicated physics per frame.
------------------------------------------------------------------------
local function applyMovement()
    local hum = humanoid()
    if not hum then return end
    hum.WalkSpeed = State.WalkSpeed
    hum.JumpPower = State.JumpPower
    hum.UseJumpPower = true
end

local function bindCharacterMovement()
    if hrp() then applyMovement() end
    track(LP.CharacterAdded:Connect(function(ch)
        ch:WaitForChild("Humanoid", 5)
        task.wait(0.5)
        applyMovement()
    end))
end

------------------------------------------------------------------------
-- Utility: Infinite Jump
------------------------------------------------------------------------
local function bindInfiniteJump()
    track(UserInputService.JumpRequest:Connect(function()
        if not State.InfiniteJump then return end
        local hum = humanoid()
        if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
    end))
end

------------------------------------------------------------------------
-- Utility: Anti-AFK — VirtualUser input every 60s
------------------------------------------------------------------------
local function bindAntiAFK()
    track(LP.Idled:Connect(function()
        if not State.AntiAFK then return end
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(Vector2.new())
        end)
    end))
end

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------

-- Diamonds tab -----------------------------------------------------------
local LeftBox  = Tabs.Main:AddLeftGroupbox("Diamond Farm")
local RightBox = Tabs.Main:AddRightGroupbox("Stats")

LeftBox:AddToggle("AutoDiamond", {
    Text = "Auto-collect Diamonds",
    Default = false,
    Tooltip = "Safely teleports the character to each spawned diamond in workspace.CollectibleDiamonds. Steps in 500-stud hops to stay under the anticheat's 750-stud/frame teleport gate.",
}):OnChanged(function(v)
    State.AutoCollectDiamonds = v
    if v then
        newLoop("diamonds", 0.5, diamondFarmTick)
    else
        killLoop("diamonds")
    end
end)

LeftBox:AddToggle("AutoBooks", {
    Text = "Auto-collect Lost Books",
    Default = false,
    Tooltip = "Fires LostBooksRemote:FireServer('Get', name) for each active book. Rate-limited to match the vanilla client (0.22s per fire).",
}):OnChanged(function(v)
    State.AutoCollectBooks = v
    if v then
        newLoop("books", 0.4, bookFarmTick)
    else
        killLoop("books")
    end
end)

LeftBox:AddToggle("AutoReturnBooks", {
    Text = "Auto-return Books",
    Default = false,
    Tooltip = "Fires the LostBooksReturn proximity prompt when it's enabled.",
}):OnChanged(function(v)
    State.AutoReturnBooks = v
    if v then
        newLoop("returnbooks", 1.5, returnBooksTick)
    else
        killLoop("returnbooks")
    end
end)

LeftBox:AddButton({
    Text = "Reset Stats",
    Func = function()
        State.DiamondsCollected = 0
        State.BooksCollected = 0
    end,
})

local diamondLabel = RightBox:AddLabel("Diamonds this session: 0")
local bookLabel    = RightBox:AddLabel("Books this session: 0")

local function setLabel(lbl, text)
    if not lbl then return end
    if type(lbl.SetText) == "function" then
        lbl:SetText(text)
    elseif lbl.Label and lbl.Label.Text then
        lbl.Label.Text = text
    end
end

-- ambient stats refresher
newLoop("statsLabel", 0.5, function()
    setLabel(diamondLabel, "Diamonds this session: " .. State.DiamondsCollected)
    setLabel(bookLabel,    "Books this session: "    .. State.BooksCollected)
end)

-- Classes tab ------------------------------------------------------------
local ClassBoxL = Tabs.Class:AddLeftGroupbox("Class Automation")
local ClassBoxR = Tabs.Class:AddRightGroupbox("Notes")

ClassBoxL:AddToggle("AutoJoinClass", {
    Text = "Auto-join Classes",
    Default = false,
    Tooltip = "Automatically accepts the classroom door confirmation when it appears (fires ClassroomDoorGui:FireServer()).",
}):OnChanged(function(v)
    State.AutoJoinClass = v
end)

ClassBoxL:AddToggle("AutoClassMinigame", {
    Text = "Auto-play Class Minigames",
    Default = false,
    Tooltip = "Best-effort automation of known class minigames: Stamping, Flight rings, Secret Brick Door, Attic Keys. Only fires when the corresponding class objects exist in workspace.",
}):OnChanged(function(v)
    State.AutoClassMinigame = v
    if v then
        newLoop("classmini", 0.6, classMinigameTick)
    else
        killLoop("classmini")
    end
end)

ClassBoxR:AddLabel("Classes reward diamonds when finished. Enable Auto-join + Auto-play for hands-off farming during the class period.")
ClassBoxR:AddLabel("Diamonds/Books cap per period is server-enforced (~10 diamonds & book cap).")
ClassBoxR:AddLabel("Fountain wish (dorm) rewards diamonds once per in-game day — do it manually to avoid the story cutscene edge cases.")

-- Utility tab ------------------------------------------------------------
local UtilL = Tabs.Utility:AddLeftGroupbox("Movement")
local UtilR = Tabs.Utility:AddRightGroupbox("Session")

UtilL:AddSlider("WalkSpeed", {
    Text = "Walk Speed",
    Default = 16, Min = 8, Max = 80, Rounding = 0, Suffix = " s/s",
    Compact = false,
}):OnChanged(function(v)
    State.WalkSpeed = v
    applyMovement()
end)

UtilL:AddSlider("JumpPower", {
    Text = "Jump Power",
    Default = 50, Min = 30, Max = 200, Rounding = 0,
}):OnChanged(function(v)
    State.JumpPower = v
    applyMovement()
end)

UtilL:AddToggle("InfJump", {
    Text = "Infinite Jump",
    Default = false,
}):OnChanged(function(v)
    State.InfiniteJump = v
end)

UtilR:AddToggle("AntiAFK", {
    Text = "Anti-AFK",
    Default = false,
    Tooltip = "Blocks the 20-minute idle disconnect using VirtualUser input.",
}):OnChanged(function(v)
    State.AntiAFK = v
end)

UtilR:AddButton({
    Text = "Rejoin Server",
    Func = function()
        local ts = game:GetService("TeleportService")
        pcall(function() ts:Teleport(game.PlaceId, LP) end)
    end,
})

UtilR:AddButton({
    Text = "Reset Character",
    Func = function()
        local hum = humanoid()
        if hum then hum.Health = 0 end
    end,
})

-- Info tab ---------------------------------------------------------------
local InfoBox = Tabs.Info:AddLeftGroupbox("Anticheat Notes")
InfoBox:AddLabel("The game verifies each diamond touch server-side")
InfoBox:AddLabel("via GetGeometry RemoteFunction (server -> client).")
InfoBox:AddDivider()
InfoBox:AddLabel("- Do NOT move diamond parts (get flagged HACKED).")
InfoBox:AddLabel("- Character hops > 750 studs / frame are flagged.")
InfoBox:AddLabel("- We use 500-stud stepped teleports w/ Heartbeat.")

local AboutBox = Tabs.Info:AddRightGroupbox("About")
AboutBox:AddLabel("Royal High Diamond Farm")
AboutBox:AddLabel("GUI: LinoriaLib")
AboutBox:AddLabel("Verified against Campus 4 (PlaceId 79319660271166)")

-- Settings tab -----------------------------------------------------------
local MenuGroup = Tabs.Settings:AddLeftGroupbox("Menu")
MenuGroup:AddButton({
    Text = "Unload",
    Func = function()
        _G.__RH_FARM_UNLOAD()
    end,
})
MenuGroup:AddDivider()
local menuKey = MenuGroup:AddLabel("Menu bind:"):AddKeyPicker("MenuKeybind", {Default = "End", NoUI = true, Text = "Menu keybind"})
pcall(function() Library.ToggleKeybind = menuKey end)

------------------------------------------------------------------------
-- theme + save managers (from Linoria addons)
------------------------------------------------------------------------
pcall(function()
    if ThemeManager then
        ThemeManager:SetLibrary(Library)
        ThemeManager:SetFolder("RH_DiamondFarm")
        ThemeManager:ApplyToTab(Tabs.Settings)
    end
end)
pcall(function()
    if SaveManager then
        SaveManager:SetLibrary(Library)
        SaveManager:IgnoreThemeSettings()
        SaveManager:SetIgnoreIndexes({"MenuKeybind"})
        SaveManager:SetFolder("RH_DiamondFarm/campus4")
        SaveManager:BuildConfigSection(Tabs.Settings)
        SaveManager:LoadAutoloadConfig()
    end
end)

------------------------------------------------------------------------
-- kick off character-scoped bindings
------------------------------------------------------------------------
bindAutoJoin()
bindCharacterMovement()
bindInfiniteJump()
bindAntiAFK()

------------------------------------------------------------------------
-- global unload
------------------------------------------------------------------------
_G.__RH_FARM_UNLOAD = function()
    for name in pairs(Bag.loops) do killLoop(name) end
    for _, c in ipairs(Bag.conns) do pcall(function() c:Disconnect() end) end
    for _, r in ipairs(Bag.restore) do pcall(r) end
    pcall(function() Library:Unload() end)
    _G.__RH_FARM_LOADED = nil
end

Library:Notify("Royal High Diamond Farm loaded ♦")
