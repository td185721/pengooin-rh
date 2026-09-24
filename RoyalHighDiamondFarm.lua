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
    PauseFarmDuringClass= true,    -- don't hop to diamonds while a class is running
    WalkSpeed           = 16,
    JumpPower           = 50,
    InfiniteJump        = false,
    AntiAFK             = false,
    NoclipDiamonds      = false,   -- for pickup only, temporary during hop
    DiamondsCollected   = 0,
    BooksCollected      = 0,
    ClassesJoined       = 0,
    ClassesAced         = 0,
}

------------------------------------------------------------------------
-- Class period tracker — one authoritative record per class window.
-- Everything class-related (join, ace, farm-pause, end-detection) reads
-- from this. Started by SetClassName or by the announcement fallback,
-- ended by another SetClassName, an explicit end signal, or the max-
-- duration safety cap.
------------------------------------------------------------------------
local ClassPeriod = {
    id          = 0,
    active      = false,
    joined      = false,      -- true once we've fired the join for THIS period
    name        = nil,
    startedAt   = 0,
    joinedAt    = 0,
    maxDuration = 360,        -- 6 min hard cap — RH class window is ~5 min
}

local function endClassPeriod()
    if ClassPeriod.active then
        ClassPeriod.active = false
        ClassPeriod.joined = false
        ClassPeriod.name   = nil
    end
end

local function isInClassPeriod()
    if not ClassPeriod.active then return false end
    if (tick() - ClassPeriod.startedAt) > ClassPeriod.maxDuration then
        endClassPeriod()
        return false
    end
    return true
end

local function beginClassPeriod(name)
    ClassPeriod.id        = ClassPeriod.id + 1
    ClassPeriod.active    = true
    ClassPeriod.joined    = false
    ClassPeriod.name      = name or ("class-" .. ClassPeriod.id)
    ClassPeriod.startedAt = tick()
    ClassPeriod.joinedAt  = 0
end

-- farm pause helper — used by every hop-loop that would drag the character
-- out of the classroom mid-lesson.
local function farmBlockedByClass()
    return State.PauseFarmDuringClass and isInClassPeriod() and ClassPeriod.joined
end

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
    if farmBlockedByClass() then return end
    local folder = getCollectibleDiamonds()
    if not folder then return end
    local hum = humanoid()
    if not hum or hum.Health <= 0 then return end
    for _, d in ipairs(folder:GetChildren()) do
        if not State.AutoCollectDiamonds then break end
        if farmBlockedByClass() then break end
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
    if farmBlockedByClass() then return end
    local folder = Workspace:FindFirstChild("ActiveLostBooks")
    local remote = getLostBooksRemote()
    if not folder or not remote then return end
    for _, b in ipairs(folder:GetChildren()) do
        if not State.AutoCollectBooks then break end
        if farmBlockedByClass() then break end
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
    if farmBlockedByClass() then return end
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
-- Auto Join Class
--
-- ScheduleLocalScript wires MouseButton1Click on
--   PlayerGui.RH4Classes.AnnouncementFrame.AnnouncementSlide.Container.TeleportFrame.TeleportButton
-- and the click ultimately fires ReplicatedStorage.RH4ScheduleRemote.GoClicked
-- to the server. We watch the TeleportFrame Visible property and fire both:
-- firesignal on the button (mimics a real click, running any UI transitions)
-- and GoClicked as a redundant safety.
------------------------------------------------------------------------
local RH4ScheduleRemote  = ReplicatedStorage:WaitForChild("RH4ScheduleRemote", 10)

local function getAnnounceTeleportFrame()
    local pg = LP:FindFirstChild("PlayerGui")
    if not pg then return nil end
    local rh4 = pg:FindFirstChild("RH4Classes")
    if not rh4 then return nil end
    local af = rh4:FindFirstChild("AnnouncementFrame")
    if not af then return nil end
    local slide = af:FindFirstChild("AnnouncementSlide")
    if not slide then return nil end
    local container = slide:FindFirstChild("Container")
    if not container then return nil end
    return container:FindFirstChild("TeleportFrame")
end

local function fireGoClicked()
    if RH4ScheduleRemote and RH4ScheduleRemote:FindFirstChild("GoClicked") then
        pcall(function() RH4ScheduleRemote.GoClicked:FireServer() end)
    end
end

-- Fire the join exactly ONCE per period. ClassPeriod.joined is the gate;
-- once true, no button click, no GoClicked, until a new period starts.
-- This is what stops the "teleport spam" — the game teleports us to the
-- classroom on the first fire; any subsequent fire risks bouncing us
-- back to spawn or firing GoClicked with a stale class id.
local function joinClassNow(className)
    if ClassPeriod.joined then return end
    if not isInClassPeriod() then
        -- manual "Join Current Class Now" button path: if we don't have a
        -- period tracked yet but an announcement is up, adopt it.
        local tf = getAnnounceTeleportFrame()
        if not (tf and tf.Visible) then return end
        beginClassPeriod(className)
    end

    ClassPeriod.joined = true
    ClassPeriod.joinedAt = tick()
    State.ClassesJoined = State.ClassesJoined + 1

    local tf = getAnnounceTeleportFrame()
    if tf then
        local btn = tf:FindFirstChild("TeleportButton")
        if btn and btn:IsA("GuiButton") then
            pcall(function() firesignal(btn.MouseButton1Click) end)
        end
    end
    fireGoClicked()
end

local autoJoinBound = false
local function bindAutoJoin()
    if autoJoinBound then return end
    autoJoinBound = true

    if RH4ScheduleRemote then
        -- SetClassName is the canonical class-period start signal. We
        -- always open a fresh period on it (even with AutoJoin off) so
        -- the farm-pause behavior stays consistent.
        local cn = RH4ScheduleRemote:FindFirstChild("SetClassName")
        if cn then
            track(cn.OnClientEvent:Connect(function(className)
                -- if there was a running period, close it — the server just
                -- moved us onto a new class.
                if ClassPeriod.active then endClassPeriod() end

                -- an empty name means "no class right now" — respect it.
                if type(className) ~= "string" or className == "" then
                    return
                end

                beginClassPeriod(className)

                if not State.AutoJoinClass then return end
                task.wait(0.6)
                if not isInClassPeriod() then return end
                if ClassPeriod.joined then return end
                joinClassNow(className)
            end))
        end

        -- Look for a class-end signal by name so the farm can resume
        -- immediately instead of waiting for maxDuration.
        for _, sub in ipairs(RH4ScheduleRemote:GetChildren()) do
            if sub:IsA("RemoteEvent") then
                local n = sub.Name:lower()
                if n:find("classend") or n:find("classover")
                   or n:find("endclass") or n:find("classfinish") then
                    track(sub.OnClientEvent:Connect(function() endClassPeriod() end))
                end
            end
        end
    end

    -- Fallback: catch the announcement UI if SetClassName was missed
    -- (e.g. joined server mid-announcement). Never re-fires within a
    -- period thanks to the ClassPeriod.joined gate.
    newLoop("autojoin", 1.5, function()
        if not State.AutoJoinClass then return end
        if ClassPeriod.joined then return end
        local tf = getAnnounceTeleportFrame()
        if not tf or not tf.Visible then return end
        if not ClassPeriod.active then
            beginClassPeriod("fallback-" .. ClassPeriod.id + 1)
        end
        joinClassNow(ClassPeriod.name)
    end)
end

local function setGameAutoJoinPref(pref)
    if not RH4ScheduleRemote then return false, "no schedule remote" end
    local rem = RH4ScheduleRemote:FindFirstChild("SetJoinPref")
    if not rem then return false, "no SetJoinPref" end
    local ok, err = pcall(function() rem:FireServer(pref) end)
    return ok, err
end

local function fireToolBonus()
    if not RH4ScheduleRemote then return end
    local tb = RH4ScheduleRemote:FindFirstChild("ToolBonus")
    if tb then pcall(function() tb:FireServer(true) end) end
end

------------------------------------------------------------------------
-- Auto Complete Class Minigames — generic dispatcher
--
-- RH classroom minigames each have their own Workspace.*.Client script that
-- appears when you're actually in the classroom. We hook the ones that we
-- can safely automate without moving diamonds or breaching the geometry AC.
------------------------------------------------------------------------
-- humanized short delay so we don't fire on the same frame the server sent.
-- Tuned tight: RH class minigames typically have short input windows and
-- a delayed response caps your score below max. 20-60ms is well inside
-- any reasonable "human" ceiling and safely above per-frame anti-cheat
-- rate limits.
local function humanDelay(loMs, hiMs)
    task.wait(math.random(loMs or 20, hiMs or 60) / 1000)
end

-- Only run a minigame hook if we're actually in an active class period
-- AND the user has toggled autoplay on. Prevents accidental fires when
-- a stale server event lands after the class window.
local function minigameGate()
    if not State.AutoClassMinigame then return false end
    if not isInClassPeriod() then return false end
    return true
end

-- one-shot install: hook each class's server-to-client event and echo back
-- the max-score / collect response. All hooks are gated by
-- State.AutoClassMinigame so the toggle disables them at runtime.
local classHooksInstalled = false
local function installClassAutoplayHooks()
    if classHooksInstalled then return end
    classHooksInstalled = true

    -- ================== TELESCOPE ==================
    -- server sends {"ShootingStar", id, ...} / {"RainbowStar", id, ...} / {"UFO", id, ...}
    -- client replies "CollectShootingStar" / "CollectRainbowStar" / "CollectUFO"
    -- with the same id. Every miss is 1 diamond dropped, so we reply on the
    -- next frame — no random delay.
    local tel = ReplicatedStorage:FindFirstChild("TelescopeGameRemote")
    if tel and tel:IsA("RemoteEvent") then
        track(tel.OnClientEvent:Connect(function(action, ...)
            if not minigameGate() then return end
            if type(action) ~= "string" then return end
            local args = {...}
            local reply
            local a = action:lower()
            if a:find("shooting") or a == "star" then reply = "CollectShootingStar"
            elseif a:find("rainbow") then             reply = "CollectRainbowStar"
            elseif a:find("ufo") then                 reply = "CollectUFO"
            elseif a:find("meteor") then              reply = "CollectMeteor"
            end
            if reply then
                RunService.Heartbeat:Wait()
                pcall(function() tel:FireServer(reply, unpack(args)) end)
            end
        end))
    end

    -- ================== COMPUTER ==================
    -- ComputerMinigameRemotes.Update sends CurrentWord; we type each letter.
    -- One in-flight word at a time — if a new word arrives mid-type, cancel
    -- the previous run so we don't type letters into the wrong word.
    local cmg = ReplicatedStorage:FindFirstChild("ComputerMinigameRemotes")
    if cmg then
        local update = cmg:FindFirstChild("Update")
        local letter = cmg:FindFirstChild("LetterTyped")
        if update and letter then
            local runToken = 0
            track(update.OnClientEvent:Connect(function(...)
                if not minigameGate() then return end
                runToken = runToken + 1
                local myToken = runToken
                for _, v in ipairs({...}) do
                    if type(v) == "string" and #v >= 2 and #v <= 30 and v:match("^[%a%-']+$") then
                        for i = 1, #v do
                            if runToken ~= myToken then return end
                            if not minigameGate() then return end
                            humanDelay(35, 75)
                            pcall(function() letter:FireServer(string.sub(v, i, i)) end)
                        end
                        break
                    end
                end
            end))
        end
    end

    -- ================== STUDY HALL ==================
    -- server sends the flashcard sequence; we mirror it back on the same event.
    -- Sequence arrives as a table OR a comma-separated string OR a stream of
    -- individual "Show" events with one item each. All three shapes captured.
    local sh = ReplicatedStorage:FindFirstChild("StudyHallRemote")
    if sh and sh:IsA("RemoteEvent") then
        local lastSequence = {}
        local capturing    = false
        track(sh.OnClientEvent:Connect(function(...)
            if not minigameGate() then return end
            local args = {...}
            local head = type(args[1]) == "string" and args[1]:lower() or nil

            -- open a fresh capture buffer when the server signals "show"/"start"
            if head and (head:find("start") or head:find("show") or head:find("begin") or head:find("sequence")) then
                lastSequence = {}
                capturing    = true
            end

            -- vacuum any table or scalar items into the buffer
            for i, v in ipairs(args) do
                if i > 1 or not head then
                    if type(v) == "table" then
                        for _, item in ipairs(v) do table.insert(lastSequence, item) end
                    elseif type(v) == "string" and v ~= head and #v <= 40 then
                        -- comma-separated → split
                        if v:find(",") then
                            for tok in v:gmatch("([^,]+)") do
                                table.insert(lastSequence, tok:match("^%s*(.-)%s*$"))
                            end
                        elseif capturing then
                            table.insert(lastSequence, v)
                        end
                    elseif type(v) == "number" or type(v) == "userdata" then
                        if capturing then table.insert(lastSequence, v) end
                    end
                end
            end

            -- reply on input-time signals
            if head and (head:find("answer") or head:find("input") or head:find("time") or head:find("go")) then
                capturing = false
                if #lastSequence == 0 then return end
                task.wait(0.15)
                for _, item in ipairs(lastSequence) do
                    if not minigameGate() then break end
                    humanDelay(40, 90)
                    pcall(function() sh:FireServer("Answer", item) end)
                end
                lastSequence = {}
            end
        end))
    end

    -- ================== POTIONOLOGY ==================
    -- server sends the recipe (colors in order); we send the same order back.
    -- Some builds use "Ingredient"/"Add" instead of "Pick" — try both.
    local po = ReplicatedStorage:FindFirstChild("PotionologyClassRemote")
        or ReplicatedStorage:FindFirstChild("PotionologyRemote")
    if po and po:IsA("RemoteEvent") then
        track(po.OnClientEvent:Connect(function(...)
            if not minigameGate() then return end
            local args = {...}
            for _, v in ipairs(args) do
                if type(v) == "table" and #v > 0 then
                    task.wait(0.2)
                    for _, color in ipairs(v) do
                        if not minigameGate() then break end
                        humanDelay(50, 110)
                        pcall(function() po:FireServer("Pick", color) end)
                    end
                    break
                end
            end
        end))
    end

    -- ================== ENGLISH ==================
    -- server sends question + options; the correct option is marked via
    -- attribute, name, IsCorrect BoolValue child, or comes back as an
    -- explicit "Answer"/"CorrectAnswer" arg on the event. We check each
    -- source in that order.
    local en = ReplicatedStorage:FindFirstChild("EnglishClassRemote")
        or ReplicatedStorage:FindFirstChild("EnglishRemote")
    if en and en:IsA("RemoteEvent") then
        track(en.OnClientEvent:Connect(function(...)
            if not minigameGate() then return end
            local args = {...}
            local declaredAnswer
            for i, v in ipairs(args) do
                if type(v) == "string" then
                    local prev = args[i-1]
                    if type(prev) == "string" then
                        local p = prev:lower()
                        if p:find("answer") or p == "correct" then
                            declaredAnswer = v
                            break
                        end
                    end
                end
            end

            task.wait(0.15)  -- let UI populate
            local pg = LP:FindFirstChild("PlayerGui")
            local rh4 = pg and pg:FindFirstChild("RH4Classes")
            local eng = rh4 and (rh4:FindFirstChild("EnglishClass")
                            or rh4:FindFirstChild("English"))
            local correctBtn
            if eng then
                for _, d in ipairs(eng:GetDescendants()) do
                    if d:IsA("GuiButton") and d.Visible then
                        local isCorrect = false
                        local n = d.Name:lower()
                        if n:find("correct") then isCorrect = true end
                        if declaredAnswer and (
                              n == declaredAnswer:lower()
                              or (d:IsA("TextButton") and d.Text and d.Text:lower() == declaredAnswer:lower())
                           ) then
                            isCorrect = true
                        end
                        local ok, attr = pcall(function() return d:GetAttribute("Correct") end)
                        if ok and attr then isCorrect = true end
                        local ic = d:FindFirstChild("IsCorrect")
                        if ic and ic:IsA("BoolValue") and ic.Value then isCorrect = true end
                        if isCorrect then correctBtn = d; break end
                    end
                end
            end
            if correctBtn then
                humanDelay(60, 140)
                pcall(function() firesignal(correctBtn.MouseButton1Click) end)
                pcall(function() en:FireServer("PickAnswer", correctBtn.Name) end)
            elseif declaredAnswer then
                humanDelay(60, 140)
                pcall(function() en:FireServer("PickAnswer", declaredAnswer) end)
            end
        end))
    end

    -- ================== DETENTION ==================
    -- rhythm game: server fires "Beat" events; we mirror back "Beats" with
    -- matching id on the next frame — anything slower shaves the score.
    local det = ReplicatedStorage:FindFirstChild("DetentionRemote")
        or ReplicatedStorage:FindFirstChild("DetentionClassRemote")
    if det and det:IsA("RemoteEvent") then
        track(det.OnClientEvent:Connect(function(action, ...)
            if not minigameGate() then return end
            if type(action) == "string" and action:lower():find("beat") then
                RunService.Heartbeat:Wait()
                pcall(function() det:FireServer("Beats", ...) end)
            end
        end))
    end

    -- ================== SCIENCE / CHEMISTRY ==================
    -- Some campuses expose a ChemistryClassRemote for the beaker-mixing
    -- sequence. Same pattern as Potionology: table sequence → mirror.
    local chem = ReplicatedStorage:FindFirstChild("ChemistryClassRemote")
        or ReplicatedStorage:FindFirstChild("ScienceClassRemote")
    if chem and chem:IsA("RemoteEvent") then
        track(chem.OnClientEvent:Connect(function(...)
            if not minigameGate() then return end
            for _, v in ipairs({...}) do
                if type(v) == "table" and #v > 0 then
                    task.wait(0.2)
                    for _, item in ipairs(v) do
                        if not minigameGate() then break end
                        humanDelay(50, 110)
                        pcall(function() chem:FireServer("Pick", item) end)
                    end
                    break
                end
            end
        end))
    end

    -- ================== TOOL BONUS ==================
    -- fire once per class start so we're auto-credited when equipped
    if RH4ScheduleRemote then
        local scn = RH4ScheduleRemote:FindFirstChild("SetClassName")
        if scn then
            track(scn.OnClientEvent:Connect(function()
                if not State.AutoClassMinigame then return end
                task.wait(2)
                fireToolBonus()
            end))
        end
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
local classLabel   = RightBox:AddLabel("Classes joined: 0")
local statusLabel  = RightBox:AddLabel("Status: idle")

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
    setLabel(classLabel,   "Classes joined: "        .. State.ClassesJoined)
    if isInClassPeriod() then
        local elapsed = math.floor(tick() - ClassPeriod.startedAt)
        setLabel(statusLabel, ("Status: in class '%s' (%ds) — farm paused"):format(tostring(ClassPeriod.name), elapsed))
    else
        setLabel(statusLabel, "Status: idle")
    end
end)

-- Classes tab ------------------------------------------------------------
local ClassBoxL = Tabs.Class:AddLeftGroupbox("Class Automation")
local ClassBoxR = Tabs.Class:AddRightGroupbox("Notes")

ClassBoxL:AddToggle("AutoJoinClass", {
    Text = "Auto-join Classes",
    Default = false,
    Tooltip = "Watches RH4Classes.AnnouncementFrame.AnnouncementSlide.Container.TeleportFrame and fires the TeleportButton + RH4ScheduleRemote.GoClicked when a class prompt appears.",
}):OnChanged(function(v)
    State.AutoJoinClass = v
end)

ClassBoxL:AddButton({
    Text = "Enable in-game Auto-Join (persistent)",
    Func = function()
        local ok, err = setGameAutoJoinPref("On")
        if ok then Library:Notify("Auto-Join set to On") else Library:Notify("Failed: " .. tostring(err)) end
    end,
})

ClassBoxL:AddButton({
    Text = "Join Current Class Now",
    Func = function()
        joinClassNow()
        Library:Notify("Sent join request")
    end,
})

ClassBoxL:AddToggle("AutoClassMinigame", {
    Text = "Auto-play Class Minigames (max grade)",
    Default = false,
    Tooltip = "Event-hook autoplay tuned to reply on the next frame: Telescope, Computer, Study Hall, Potionology, English, Detention, Chemistry, plus Tool Bonus on class start. Every hook is gated by the class-period tracker so stale events after class-end are ignored.",
}):OnChanged(function(v)
    State.AutoClassMinigame = v
end)

ClassBoxL:AddToggle("PauseFarmDuringClass", {
    Text = "Pause diamond/book farm during class",
    Default = true,
    Tooltip = "Freezes the diamond/book/return hop loops from the moment the class join fires until the class ends. Prevents the character being yanked out of the classroom mid-minigame (which was previously causing the teleport-spam behavior).",
}):OnChanged(function(v)
    State.PauseFarmDuringClass = v
end)

ClassBoxL:AddButton({
    Text = "Force End Class Period",
    Func = function()
        endClassPeriod()
        Library:Notify("Class period cleared — farm resumes")
    end,
})

ClassBoxR:AddLabel("Auto-join fires ONCE per class period on the SetClassName event.")
ClassBoxR:AddLabel("A fallback catches the announcement UI if SetClassName was missed.")
ClassBoxR:AddLabel("Persistent button sets RH4ScheduleRemote.SetJoinPref = 'On'.")
ClassBoxR:AddDivider()
ClassBoxR:AddLabel("Farm pauses from join → class-end (or 6 min cap).")
ClassBoxR:AddLabel("Minigame hooks reply next-frame for max grade.")
ClassBoxR:AddLabel("Diamonds/Books cap per period is server-enforced.")

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
installClassAutoplayHooks()
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
