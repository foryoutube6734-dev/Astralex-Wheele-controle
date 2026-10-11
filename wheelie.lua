--[[
    ╔══════════════════════════════════════════════════════╗
    ║        WHEELIE AUTO-THROTTLE v11 (FINAL)             ║
    ║  START/STOP toggle button                            ║
    ╚══════════════════════════════════════════════════════╝
]]

local Players              = game:GetService("Players")
local RunService           = game:GetService("RunService")
local UserInputService     = game:GetService("UserInputService")
local VirtualInputManager  = game:GetService("VirtualInputManager")
local TweenService         = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer

------------------------------------------------------------
-- ⚙ HIDDEN CONFIG
------------------------------------------------------------
local CONFIG = {
    GAS_KEY      = Enum.KeyCode.W,
    BRAKE_KEY    = Enum.KeyCode.S,
    WHEELIE_KEY  = Enum.KeyCode.LeftShift,
    STUDS_TO_KMH = 0.64,
    SPEED_TOL    = 2.0,
}

------------------------------------------------------------
-- СОСТОЯНИЕ
------------------------------------------------------------
local State = {
    enabled       = true,
    active        = false,
    maxAngle      = 30,
    hysteresis    = 5,
    targetSpeed   = 0,
    stopOnManual  = true,
    autoStart     = false,
    scooter       = nil,
    mainPart      = nil,
    angle         = 0,
    speedKmh      = 0,
    isGassing     = false,
    isBraking     = false,
    lastAction    = "—",
    lastWheelie   = 0,
    sendingKey    = false,
    listeningKb   = false,
}

------------------------------------------------------------
-- ПОИСК САМОКАТА
------------------------------------------------------------
local function findScooter()
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj.Name == "ScooterOwner"
        and (obj:IsA("ObjectValue") or obj:IsA("StringValue")) then
            local ok, val = pcall(function() return obj.Value end)
            if ok and val ~= nil then
                if typeof(val) == "Instance" and val:IsA("Player") then
                    if val == LocalPlayer then return obj.Parent end
                else
                    local raw = tostring(val)
                    if raw == LocalPlayer.Name
                    or raw == LocalPlayer.DisplayName
                    or raw == tostring(LocalPlayer.UserId) then
                        return obj.Parent
                    end
                end
            end
        end
    end
end

local function findMainPart(scooter)
    if not scooter then return nil end
    local body = scooter:FindFirstChild("Body", true)
    if body and body:IsA("BasePart") then return body end
    if scooter.PrimaryPart then return scooter.PrimaryPart end
    for _, obj in ipairs(scooter:GetDescendants()) do
        if obj:IsA("BasePart") then return obj end
    end
end

------------------------------------------------------------
-- УГОЛ И СКОРОСТЬ
------------------------------------------------------------
local function getWheelieAngle(part)
    if not part or not part.Parent then return 0 end
    local look = part.CFrame.LookVector
    return math.deg(math.asin(math.clamp(look.Y, -1, 1)))
end

local function getSpeedKmh(part)
    if not part or not part.Parent then return 0 end
    local vel = part.AssemblyLinearVelocity
    local horiz = Vector3.new(vel.X, 0, vel.Z).Magnitude
    return horiz * CONFIG.STUDS_TO_KMH
end

------------------------------------------------------------
-- УПРАВЛЕНИЕ
------------------------------------------------------------
local function pressKey(key)
    State.sendingKey = true
    pcall(function() VirtualInputManager:SendKeyEvent(true, key, false, game) end)
    task.delay(0.15, function() State.sendingKey = false end)
end

local function releaseKey(key)
    State.sendingKey = true
    pcall(function() VirtualInputManager:SendKeyEvent(false, key, false, game) end)
    task.delay(0.15, function() State.sendingKey = false end)
end

local function pressGas()    pressKey(CONFIG.GAS_KEY)   end
local function releaseGas()  releaseKey(CONFIG.GAS_KEY) end
local function pressBrake()  pressKey(CONFIG.BRAKE_KEY)   end
local function releaseBrake()releaseKey(CONFIG.BRAKE_KEY) end

local function forceReleaseGas()
    if State.isGassing then
        releaseGas()
        State.isGassing = false
    end
end

local function forceReleaseBrake()
    if State.isBraking then
        releaseBrake()
        State.isBraking = false
    end
end

local function forceReleaseAll()
    forceReleaseGas()
    forceReleaseBrake()
end

local function triggerWheelie()
    forceReleaseGas()
    State.sendingKey = true
    pcall(function() VirtualInputManager:SendKeyEvent(true, CONFIG.WHEELIE_KEY, false, game) end)
    task.wait(0.1)
    pcall(function() VirtualInputManager:SendKeyEvent(false, CONFIG.WHEELIE_KEY, false, game) end)
    task.delay(0.15, function() State.sendingKey = false end)
    State.lastWheelie = tick()
    State.lastAction = "START"
end

local function emergencyStop(reason)
    forceReleaseAll()
    State.active = false
    State.autoStart = false
    State.lastAction = reason or "STOP"
    if _G._ASTRALEX_UI then _G._ASTRALEX_UI.setStopped() end
end

------------------------------------------------------------
-- СТОП НА W/S
------------------------------------------------------------
UserInputService.InputBegan:Connect(function(input, processed)
    if State.sendingKey then return end
    if State.listeningKb then return end
    if processed then return end
    if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
    if not State.active then return end
    if not State.stopOnManual then return end

    if input.KeyCode == CONFIG.GAS_KEY or input.KeyCode == CONFIG.BRAKE_KEY then
        emergencyStop("MANUAL " .. input.KeyCode.Name)
    end
end)

------------------------------------------------------------
-- ГЛАВНЫЙ ЦИКЛ
------------------------------------------------------------
RunService.Heartbeat:Connect(function()
    if not State.scooter or not State.scooter.Parent then
        State.scooter = findScooter()
        State.mainPart = nil
    end
    if State.scooter and (not State.mainPart or not State.mainPart.Parent) then
        State.mainPart = findMainPart(State.scooter)
    end

    State.angle = getWheelieAngle(State.mainPart)
    State.speedKmh = getSpeedKmh(State.mainPart)

    if not State.active or not State.mainPart then
        forceReleaseAll()
        return
    end

    local a      = State.angle
    local s      = State.speedKmh
    local maxA   = State.maxAngle
    local minA   = State.maxAngle - State.hysteresis
    local target = State.targetSpeed
    local tol    = CONFIG.SPEED_TOL

    -- ═══ РЕЖИМ 1: SPEED LIMIT (круиз-контроль) ═══
    if target and target > 0 then
        if a >= maxA then
            forceReleaseGas()
            if s > target + tol then
                if not State.isBraking then
                    pressBrake()
                    State.isBraking = true
                end
                State.lastAction = "BRAKE"
            else
                forceReleaseBrake()
                State.lastAction = "RELEASE"
            end
            return
        end

        if a < minA then
            if s < target - tol then
                forceReleaseBrake()
                if not State.isGassing then
                    pressGas()
                    State.isGassing = true
                end
                State.lastAction = "GAS"
            elseif s > target + tol then
                forceReleaseGas()
                if not State.isBraking then
                    pressBrake()
                    State.isBraking = true
                end
                State.lastAction = "BRAKE"
            else
                forceReleaseBrake()
                if not State.isGassing then
                    pressGas()
                    State.isGassing = true
                end
                State.lastAction = "GAS"
            end
            return
        end

        if s < target - tol then
            forceReleaseBrake()
            if not State.isGassing then
                pressGas()
                State.isGassing = true
            end
            State.lastAction = "GAS"
        elseif s > target + tol then
            forceReleaseGas()
            if not State.isBraking then
                pressBrake()
                State.isBraking = true
            end
            State.lastAction = "BRAKE"
        else
            forceReleaseAll()
            State.lastAction = "HOLD"
        end
        return
    end

    -- ═══ РЕЖИМ 2: NORMAL WHEELIE ═══
    forceReleaseBrake()

    if a >= maxA then
        forceReleaseGas()
        State.lastAction = "RELEASE"
        return
    end

    if a < minA then
        if not State.isGassing then
            pressGas()
            State.isGassing = true
        end
        State.lastAction = "GAS"
    else
        State.lastAction = "HOLD"
    end
end)

------------------------------------------------------------
-- GUI
------------------------------------------------------------
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "WheelieAutoThrottle"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.Parent = (gethui and gethui()) or LocalPlayer:WaitForChild("PlayerGui")

local dimmer = Instance.new("Frame")
dimmer.Size = UDim2.new(1, 0, 1, 0)
dimmer.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
dimmer.BackgroundTransparency = 0.55
dimmer.BorderSizePixel = 0
dimmer.ZIndex = 99
dimmer.Parent = screenGui

-- ═══════════════ MAIN WINDOW ═══════════════
local main = Instance.new("Frame")
main.Size = UDim2.new(0, 380, 0, 440)
main.Position = UDim2.new(0.5, -190, 0.5, -220)
main.BackgroundColor3 = Color3.fromRGB(22, 24, 36)
main.BorderSizePixel = 0
main.Active = true
main.Visible = false
main.Parent = screenGui

local mc = Instance.new("UICorner")
mc.CornerRadius = UDim.new(0, 12)
mc.Parent = main

local ms = Instance.new("UIStroke")
ms.Color = Color3.fromRGB(124, 58, 237)
ms.Thickness = 1
ms.Transparency = 0.5
ms.Parent = main

local header = Instance.new("Frame")
header.Size = UDim2.new(1, 0, 0, 42)
header.BackgroundColor3 = Color3.fromRGB(16, 18, 28)
header.BorderSizePixel = 0
header.Parent = main

local hc = Instance.new("UICorner")
hc.CornerRadius = UDim.new(0, 12)
hc.Parent = header

local hFix = Instance.new("Frame")
hFix.Size = UDim2.new(1, 0, 0, 14)
hFix.Position = UDim2.new(0, 0, 1, -14)
hFix.BackgroundColor3 = Color3.fromRGB(16, 18, 28)
hFix.BorderSizePixel = 0
hFix.Parent = header

local title = Instance.new("TextLabel")
title.BackgroundTransparency = 1
title.Size = UDim2.new(1, -100, 1, 0)
title.Position = UDim2.new(0, 14, 0, 0)
title.Font = Enum.Font.GothamBold
title.Text = "WHEELIE AUTO"
title.TextSize = 14
title.TextColor3 = Color3.fromRGB(230, 232, 240)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = header

-- [✕] Close (только одна кнопка в шапке)
local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0, 26, 0, 26)
closeBtn.Position = UDim2.new(1, -38, 0.5, -13)
closeBtn.BackgroundColor3 = Color3.fromRGB(60, 30, 40)
closeBtn.BorderSizePixel = 0
closeBtn.Text = "X"
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 12
closeBtn.TextColor3 = Color3.fromRGB(255, 200, 200)
closeBtn.AutoButtonColor = false
closeBtn.Parent = header

local clc = Instance.new("UICorner")
clc.CornerRadius = UDim.new(0, 6)
clc.Parent = closeBtn

local statusLbl = Instance.new("TextLabel")
statusLbl.BackgroundTransparency = 1
statusLbl.Position = UDim2.new(0, 14, 0, 54)
statusLbl.Size = UDim2.new(1, -28, 0, 16)
statusLbl.Font = Enum.Font.Gotham
statusLbl.Text = "Searching for scooter..."
statusLbl.TextSize = 11
statusLbl.TextColor3 = Color3.fromRGB(139, 143, 168)
statusLbl.TextXAlignment = Enum.TextXAlignment.Left
statusLbl.Parent = main

local angleBig = Instance.new("TextLabel")
angleBig.BackgroundTransparency = 1
angleBig.Position = UDim2.new(0, 14, 0, 78)
angleBig.Size = UDim2.new(0, 180, 0, 56)
angleBig.Font = Enum.Font.GothamBlack
angleBig.Text = "0.0°"
angleBig.TextSize = 40
angleBig.TextColor3 = Color3.fromRGB(167, 139, 250)
angleBig.TextXAlignment = Enum.TextXAlignment.Left
angleBig.Parent = main

local speedBig = Instance.new("TextLabel")
speedBig.BackgroundTransparency = 1
speedBig.Position = UDim2.new(0, 190, 0, 88)
speedBig.Size = UDim2.new(1, -204, 0, 40)
speedBig.Font = Enum.Font.GothamBlack
speedBig.Text = "0 km/h"
speedBig.TextSize = 22
speedBig.TextColor3 = Color3.fromRGB(96, 165, 250)
speedBig.TextXAlignment = Enum.TextXAlignment.Right
speedBig.Parent = main

local actionLbl = Instance.new("TextLabel")
actionLbl.BackgroundTransparency = 1
actionLbl.Position = UDim2.new(0, 14, 0, 118)
actionLbl.Size = UDim2.new(1, -28, 0, 20)
actionLbl.Font = Enum.Font.GothamBold
actionLbl.Text = "—"
actionLbl.TextSize = 14
actionLbl.TextColor3 = Color3.fromRGB(139, 143, 168)
actionLbl.TextXAlignment = Enum.TextXAlignment.Left
actionLbl.Parent = main

-- ═══ START/STOP BUTTON ═══
local startBtn = Instance.new("TextButton")
startBtn.Size = UDim2.new(1, -28, 0, 46)
startBtn.Position = UDim2.new(0, 14, 0, 148)
startBtn.BackgroundColor3 = Color3.fromRGB(124, 58, 237)
startBtn.BorderSizePixel = 0
startBtn.Text = "START WHEELIE"
startBtn.Font = Enum.Font.GothamBold
startBtn.TextSize = 14
startBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
startBtn.AutoButtonColor = false
startBtn.Parent = main

local sbc = Instance.new("UICorner")
sbc.CornerRadius = UDim.new(0, 8)
sbc.Parent = startBtn

-- ═══ STOP ON W/S ═══
local stopBtn = Instance.new("TextButton")
stopBtn.Size = UDim2.new(1, -28, 0, 28)
stopBtn.Position = UDim2.new(0, 14, 0, 206)
stopBtn.BackgroundColor3 = Color3.fromRGB(34, 197, 94)
stopBtn.BorderSizePixel = 0
stopBtn.Text = "Stop on Manual W/S: ON"
stopBtn.Font = Enum.Font.GothamSemibold
stopBtn.TextSize = 11
stopBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
stopBtn.AutoButtonColor = false
stopBtn.Parent = main

local stbc = Instance.new("UICorner")
stbc.CornerRadius = UDim.new(0, 7)
stbc.Parent = stopBtn

-- Target Speed
local msTitle = Instance.new("TextLabel")
msTitle.BackgroundTransparency = 1
msTitle.Position = UDim2.new(0, 14, 0, 248)
msTitle.Size = UDim2.new(0, 170, 0, 18)
msTitle.Font = Enum.Font.GothamSemibold
msTitle.Text = "Target Wheelie Speed:"
msTitle.TextSize = 12
msTitle.TextColor3 = Color3.fromRGB(230, 232, 240)
msTitle.TextXAlignment = Enum.TextXAlignment.Left
msTitle.Parent = main

local msBox = Instance.new("TextBox")
msBox.Position = UDim2.new(0, 190, 0, 245)
msBox.Size = UDim2.new(0, 70, 0, 26)
msBox.BackgroundColor3 = Color3.fromRGB(30, 34, 50)
msBox.BorderSizePixel = 0
msBox.Font = Enum.Font.Code
msBox.Text = tostring(State.targetSpeed)
msBox.TextSize = 13
msBox.TextColor3 = Color3.fromRGB(96, 165, 250)
msBox.ClearTextOnFocus = false
msBox.Parent = main

local msc = Instance.new("UICorner")
msc.CornerRadius = UDim.new(0, 6)
msc.Parent = msBox

local msUnit = Instance.new("TextLabel")
msUnit.BackgroundTransparency = 1
msUnit.Position = UDim2.new(0, 264, 0, 248)
msUnit.Size = UDim2.new(0, 100, 0, 18)
msUnit.Font = Enum.Font.Gotham
msUnit.Text = "km/h (0=off)"
msUnit.TextSize = 10
msUnit.TextColor3 = Color3.fromRGB(139, 143, 168)
msUnit.TextXAlignment = Enum.TextXAlignment.Left
msUnit.Parent = main

-- Max Angle
local maTitle = Instance.new("TextLabel")
maTitle.BackgroundTransparency = 1
maTitle.Position = UDim2.new(0, 14, 0, 284)
maTitle.Size = UDim2.new(0, 170, 0, 18)
maTitle.Font = Enum.Font.GothamSemibold
maTitle.Text = "Max Angle (deg):"
maTitle.TextSize = 12
maTitle.TextColor3 = Color3.fromRGB(230, 232, 240)
maTitle.TextXAlignment = Enum.TextXAlignment.Left
maTitle.Parent = main

local maBox = Instance.new("TextBox")
maBox.Position = UDim2.new(0, 190, 0, 281)
maBox.Size = UDim2.new(0, 70, 0, 26)
maBox.BackgroundColor3 = Color3.fromRGB(30, 34, 50)
maBox.BorderSizePixel = 0
maBox.Font = Enum.Font.Code
maBox.Text = tostring(State.maxAngle)
maBox.TextSize = 13
maBox.TextColor3 = Color3.fromRGB(230, 232, 240)
maBox.ClearTextOnFocus = false
maBox.Parent = main

local mac = Instance.new("UICorner")
mac.CornerRadius = UDim.new(0, 6)
mac.Parent = maBox

-- Hysteresis
local hTitle = Instance.new("TextLabel")
hTitle.BackgroundTransparency = 1
hTitle.Position = UDim2.new(0, 14, 0, 320)
hTitle.Size = UDim2.new(0, 170, 0, 18)
hTitle.Font = Enum.Font.GothamSemibold
hTitle.Text = "Hysteresis (deg):"
hTitle.TextSize = 12
hTitle.TextColor3 = Color3.fromRGB(230, 232, 240)
hTitle.TextXAlignment = Enum.TextXAlignment.Left
hTitle.Parent = main

local hBox = Instance.new("TextBox")
hBox.Position = UDim2.new(0, 190, 0, 317)
hBox.Size = UDim2.new(0, 70, 0, 26)
hBox.BackgroundColor3 = Color3.fromRGB(30, 34, 50)
hBox.BorderSizePixel = 0
hBox.Font = Enum.Font.Code
hBox.Text = tostring(State.hysteresis)
hBox.TextSize = 13
hBox.TextColor3 = Color3.fromRGB(230, 232, 240)
hBox.ClearTextOnFocus = false
hBox.Parent = main

local hbcc = Instance.new("UICorner")
hbcc.CornerRadius = UDim.new(0, 6)
hbcc.Parent = hBox

-- Apply
local applyBtn = Instance.new("TextButton")
applyBtn.Size = UDim2.new(1, -28, 0, 36)
applyBtn.Position = UDim2.new(0, 14, 0, 358)
applyBtn.BackgroundColor3 = Color3.fromRGB(99, 102, 241)
applyBtn.BorderSizePixel = 0
applyBtn.Text = "Apply Settings"
applyBtn.Font = Enum.Font.GothamBold
applyBtn.TextSize = 12
applyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
applyBtn.AutoButtonColor = false
applyBtn.Parent = main

local applyc = Instance.new("UICorner")
applyc.CornerRadius = UDim.new(0, 8)
applyc.Parent = applyBtn

-- Hint
local hint = Instance.new("TextLabel")
hint.BackgroundTransparency = 1
hint.Position = UDim2.new(0, 14, 0, 402)
hint.Size = UDim2.new(1, -28, 0, 28)
hint.Font = Enum.Font.Gotham
hint.Text = "Fill Target Speed to hold a specific speed,\nor set to 0 for normal wheelie mode"
hint.TextSize = 10
hint.TextColor3 = Color3.fromRGB(110, 115, 140)
hint.TextXAlignment = Enum.TextXAlignment.Center
hint.TextWrapped = true
hint.Parent = main

-- ═══════════════════════════════════════════════
-- TUTORIAL
-- ═══════════════════════════════════════════════
local tutOverlay = Instance.new("Frame")
tutOverlay.Size = UDim2.new(0, 560, 0, 620)
tutOverlay.Position = UDim2.new(0.5, -280, 0.5, -310)
tutOverlay.BackgroundColor3 = Color3.fromRGB(18, 20, 30)
tutOverlay.BorderSizePixel = 0
tutOverlay.ZIndex = 100
tutOverlay.Active = true
tutOverlay.Parent = screenGui

local tuc = Instance.new("UICorner")
tuc.CornerRadius = UDim.new(0, 14)
tuc.Parent = tutOverlay

local tus = Instance.new("UIStroke")
tus.Color = Color3.fromRGB(124, 58, 237)
tus.Thickness = 2
tus.Transparency = 0.3
tus.Parent = tutOverlay

local tutHeader = Instance.new("Frame")
tutHeader.Size = UDim2.new(1, 0, 0, 60)
tutHeader.BackgroundColor3 = Color3.fromRGB(14, 16, 24)
tutHeader.BorderSizePixel = 0
tutHeader.ZIndex = 101
tutHeader.Parent = tutOverlay

local thc = Instance.new("UICorner")
thc.CornerRadius = UDim.new(0, 14)
thc.Parent = tutHeader

local thFix = Instance.new("Frame")
thFix.Size = UDim2.new(1, 0, 0, 20)
thFix.Position = UDim2.new(0, 0, 1, -20)
thFix.BackgroundColor3 = Color3.fromRGB(14, 16, 24)
thFix.BorderSizePixel = 0
thFix.ZIndex = 101
thFix.Parent = tutHeader

local tutTitle = Instance.new("TextLabel")
tutTitle.BackgroundTransparency = 1
tutTitle.Size = UDim2.new(1, -28, 1, 0)
tutTitle.Position = UDim2.new(0, 24, 0, 0)
tutTitle.Font = Enum.Font.GothamBold
tutTitle.Text = "How to use Wheelie Auto"
tutTitle.TextSize = 19
tutTitle.TextColor3 = Color3.fromRGB(230, 232, 240)
tutTitle.TextXAlignment = Enum.TextXAlignment.Left
tutTitle.ZIndex = 101
tutTitle.Parent = tutHeader

local tutBody = Instance.new("ScrollingFrame")
tutBody.BackgroundTransparency = 1
tutBody.Position = UDim2.new(0, 20, 0, 76)
tutBody.Size = UDim2.new(1, -40, 1, -160)
tutBody.BorderSizePixel = 0
tutBody.ScrollBarThickness = 6
tutBody.ScrollBarImageColor3 = Color3.fromRGB(124, 58, 237)
tutBody.CanvasSize = UDim2.new(0, 0, 0, 0)
tutBody.AutomaticCanvasSize = Enum.AutomaticSize.Y
tutBody.ZIndex = 101
tutBody.Parent = tutOverlay

local tutLayout = Instance.new("UIListLayout")
tutLayout.Padding = UDim.new(0, 6)
tutLayout.SortOrder = Enum.SortOrder.LayoutOrder
tutLayout.Parent = tutBody

local function addTutLine(text, color, size, isBold)
    local lbl = Instance.new("TextLabel")
    lbl.BackgroundTransparency = 1
    lbl.Size = UDim2.new(1, -10, 0, 0)
    lbl.AutomaticSize = Enum.AutomaticSize.Y
    lbl.Font = isBold and Enum.Font.GothamBold or Enum.Font.Gotham
    lbl.Text = text
    lbl.TextSize = size or 13
    lbl.TextColor3 = color or Color3.fromRGB(210, 214, 228)
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.TextYAlignment = Enum.TextYAlignment.Top
    lbl.TextWrapped = true
    lbl.ZIndex = 102
    lbl.Parent = tutBody
end

local colTitle = Color3.fromRGB(167, 139, 250)
local colBody  = Color3.fromRGB(200, 204, 220)
local colGreen = Color3.fromRGB(34, 197, 94)
local colRed   = Color3.fromRGB(239, 68, 68)
local colBlue  = Color3.fromRGB(96, 165, 250)

addTutLine("Welcome to Wheelie Auto!", colTitle, 16, true)
addTutLine("This script automatically controls your scooter to keep a perfect wheelie at the speed you want.", colBody)
addTutLine("", colBody, 4)

addTutLine("HOW IT WORKS", colTitle, 14, true)
addTutLine("1. Sit on your scooter. The script finds it automatically.", colBody)
addTutLine("2. Wait for the green status: Kukirin G4 -> Body", colBody)
addTutLine("3. Press START WHEELIE. The script triggers the initial wheelie for you.", colBody)
addTutLine("4. The script takes over. Press the same button (now red) to STOP.", colBody)
addTutLine("", colBody, 4)

addTutLine("TWO MODES", colTitle, 14, true)
addTutLine("Target Speed > 0  -  CRUISE MODE", colBlue, 13, true)
addTutLine("The script holds a specific speed. Presses W when slow, S when too fast, keeping you in a tight +-2 km/h band.", colBody)
addTutLine("", colBody, 4)
addTutLine("Target Speed = 0 or empty  -  NORMAL WHEELIE MODE", colBlue, 13, true)
addTutLine("No speed limit. The script just pushes the angle up to Max and releases when it's too high. You accelerate freely while holding the wheelie.", colBody)
addTutLine("", colBody, 4)

addTutLine("SETTINGS", colTitle, 14, true)
addTutLine("Target Wheelie Speed  -  speed to hold. Set 0 to disable cruise.", colBody)
addTutLine("Max Angle  -  how far the wheelie can lean (default 45).", colBody)
addTutLine("Hysteresis  -  how much it falls back before re-gassing (default 5).", colBody)
addTutLine("Stop on Manual W/S  -  stops the script when you press W or S yourself.", colBody)
addTutLine("", colBody, 4)

addTutLine("SAFETY", colTitle, 14, true)
addTutLine("Press W or S  ->  emergency stop", colRed)
addTutLine("Press STOP WHEELIE  ->  stops the script", colRed)
addTutLine("Close (X)  ->  unloads the script", colRed)
addTutLine("", colBody, 4)

addTutLine("Ready to ride! Press 'Got it' below.", colGreen, 14, true)

local gotItBtn = Instance.new("TextButton")
gotItBtn.Size = UDim2.new(1, -48, 0, 48)
gotItBtn.Position = UDim2.new(0, 24, 1, -60)
gotItBtn.BackgroundColor3 = Color3.fromRGB(124, 58, 237)
gotItBtn.BorderSizePixel = 0
gotItBtn.Text = "Got it, let's ride!"
gotItBtn.Font = Enum.Font.GothamBold
gotItBtn.TextSize = 15
gotItBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
gotItBtn.AutoButtonColor = false
gotItBtn.ZIndex = 101
gotItBtn.Parent = tutOverlay

local gic = Instance.new("UICorner")
gic.CornerRadius = UDim.new(0, 10)
gic.Parent = gotItBtn

local function closeTutorial()
    TweenService:Create(tutOverlay, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
    TweenService:Create(tus, TweenInfo.new(0.25), { Transparency = 1 }):Play()
    TweenService:Create(dimmer, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()

    for _, obj in ipairs(tutOverlay:GetDescendants()) do
        if obj:IsA("TextLabel") then
            TweenService:Create(obj, TweenInfo.new(0.25), { TextTransparency = 1 }):Play()
        elseif obj:IsA("TextButton") then
            TweenService:Create(obj, TweenInfo.new(0.25), {
                TextTransparency = 1,
                BackgroundTransparency = 1
            }):Play()
        elseif obj:IsA("Frame") then
            TweenService:Create(obj, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
        elseif obj:IsA("UIStroke") then
            TweenService:Create(obj, TweenInfo.new(0.25), { Transparency = 1 }):Play()
        end
    end

    task.wait(0.3)
    tutOverlay:Destroy()
    dimmer:Destroy()
    main.Visible = true
end

gotItBtn.MouseButton1Click:Connect(closeTutorial)

------------------------------------------------------------
-- UI FUNCTIONS
------------------------------------------------------------
local function setStarted()
    startBtn.Text = "STOP WHEELIE"
    startBtn.BackgroundColor3 = Color3.fromRGB(200, 40, 40)
end

local function setStopped()
    startBtn.Text = "START WHEELIE"
    startBtn.BackgroundColor3 = Color3.fromRGB(124, 58, 237)
end

_G._ASTRALEX_UI = {
    setStopped = setStopped,
}

------------------------------------------------------------
-- START / STOP BUTTON LOGIC
------------------------------------------------------------
startBtn.MouseButton1Click:Connect(function()
    if State.active then
        -- STOP
        State.active = false
        forceReleaseAll()
        State.lastAction = "STOP"
        setStopped()
    else
        -- START
        State.active = true
        task.spawn(triggerWheelie)
        setStarted()
    end
end)

stopBtn.MouseButton1Click:Connect(function()
    State.stopOnManual = not State.stopOnManual
    if State.stopOnManual then
        stopBtn.Text = "Stop on Manual W/S: ON"
        stopBtn.BackgroundColor3 = Color3.fromRGB(34, 197, 94)
    else
        stopBtn.Text = "Stop on Manual W/S: OFF"
        stopBtn.BackgroundColor3 = Color3.fromRGB(30, 34, 50)
    end
end)

local function applySettings()
    local a  = tonumber(maBox.Text)
    local h  = tonumber(hBox.Text)
    local sp = tonumber(msBox.Text)

    if a and a > 0 and a <= 89 then State.maxAngle = a end
    if h and h >= 0 and h < State.maxAngle then State.hysteresis = h end

    if not sp or sp <= 0 then
        State.targetSpeed = 0
        msBox.Text = "0"
    else
        State.targetSpeed = sp
    end

    applyBtn.Text = "Applied!"
    task.delay(1.5, function() applyBtn.Text = "Apply Settings" end)
end

applyBtn.MouseButton1Click:Connect(applySettings)
maBox.FocusLost:Connect(function(enter) if enter then applySettings() end end)
hBox.FocusLost:Connect(function(enter) if enter then applySettings() end end)
msBox.FocusLost:Connect(function(enter) if enter then applySettings() end end)

closeBtn.MouseButton1Click:Connect(function()
    forceReleaseAll()
    _G._ASTRALEX_UI = nil
    screenGui:Destroy()
end)

------------------------------------------------------------
-- DRAG MAIN
------------------------------------------------------------
do
    local dragging, dragStart, startPos
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = main.Position
        end
    end)
    header.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
end

do
    local dragging, dragStart, startPos
    tutHeader.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = tutOverlay.Position
        end
    end)
    tutHeader.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
        or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            tutOverlay.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
end

------------------------------------------------------------
-- ДИСПЛЕЙ
------------------------------------------------------------
task.spawn(function()
    while screenGui.Parent do
        task.wait(0.05)

        if State.mainPart and State.mainPart.Parent then
            statusLbl.Text = "OK: " .. State.scooter.Name .. " -> " .. State.mainPart.Name
            statusLbl.TextColor3 = Color3.fromRGB(34, 197, 94)
        else
            statusLbl.Text = "Searching for scooter... (sit on yours)"
            statusLbl.TextColor3 = Color3.fromRGB(139, 143, 168)
        end

        angleBig.Text = string.format("%.1f", State.angle) .. "°"
        speedBig.Text = string.format("%.0f", State.speedKmh) .. " km/h"

        if State.targetSpeed > 0 then
            local diff = math.abs(State.speedKmh - State.targetSpeed)
            if diff <= 3 then
                speedBig.TextColor3 = Color3.fromRGB(34, 197, 94)
            elseif diff <= 8 then
                speedBig.TextColor3 = Color3.fromRGB(250, 204, 21)
            else
                speedBig.TextColor3 = Color3.fromRGB(96, 165, 250)
            end
        else
            speedBig.TextColor3 = Color3.fromRGB(96, 165, 250)
        end

        if State.angle >= State.maxAngle then
            angleBig.TextColor3 = Color3.fromRGB(239, 68, 68)
        elseif State.angle >= State.maxAngle - State.hysteresis then
            angleBig.TextColor3 = Color3.fromRGB(250, 204, 21)
        else
            angleBig.TextColor3 = Color3.fromRGB(167, 139, 250)
        end

        if not State.active then
            if string.find(State.lastAction, "MANUAL", 1, true)
            or State.lastAction == "STOP" then
                actionLbl.Text = State.lastAction
                actionLbl.TextColor3 = Color3.fromRGB(239, 68, 68)
            else
                actionLbl.Text = "Idle - press START"
                actionLbl.TextColor3 = Color3.fromRGB(139, 143, 168)
            end
        elseif State.lastAction == "GAS" then
            actionLbl.Text = "GAS"
            actionLbl.TextColor3 = Color3.fromRGB(34, 197, 94)
        elseif State.lastAction == "BRAKE" then
            actionLbl.Text = "BRAKE"
            actionLbl.TextColor3 = Color3.fromRGB(239, 68, 68)
        elseif State.lastAction == "HOLD" then
            actionLbl.Text = "HOLD (cruise)"
            actionLbl.TextColor3 = Color3.fromRGB(250, 204, 21)
        elseif State.lastAction == "RELEASE" then
            actionLbl.Text = "RELEASE"
            actionLbl.TextColor3 = Color3.fromRGB(239, 68, 68)
        elseif State.lastAction == "START" then
            actionLbl.Text = "START"
            actionLbl.TextColor3 = Color3.fromRGB(167, 139, 250)
        else
            actionLbl.Text = "—"
            actionLbl.TextColor3 = Color3.fromRGB(139, 143, 168)
        end
    end
end)

print("[WheelieAutoThrottle v11] loaded.")
print("  Target: " .. State.targetSpeed .. " km/h (0 = normal wheelie mode)")
print("  Max angle: " .. State.maxAngle .. "°  Hysteresis: " .. State.hysteresis .. "°")
