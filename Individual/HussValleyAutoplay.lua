-- Huss Valley Autoplay, Rayfield Gen2. Run in the connected client/executor.
-- Re-running replaces this controller. F6 pauses; F7 hides the window.
-- Built against place 107535308163741 on 2026-10-04.
local env = getgenv and getgenv() or _G
local previous = env.__HussValleyAutoPlay
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local HttpService = game:GetService("HttpService")
local Debris = game:GetService("Debris")
local VirtualUser = game:GetService("VirtualUser")
local PathfindingService = game:GetService("PathfindingService")
local player = Players.LocalPlayer
local gameFolder = game.ReplicatedStorage:WaitForChild("ChickenOrHero", 15)
assert(gameFolder, "Huss Valley is not loaded")
local gameState = gameFolder:WaitForChild("Game")
local session = gameState:WaitForChild("Session")
local movement = require(gameFolder.Movement.MovementModel)
local profiles = require(gameFolder.Movement.MovementProfiles)
local directory = require(gameFolder.Presentation.ParticipantDirectory)
local gate = require(gameFolder.Movement.ControlGate)
-- Older server builds expose only reason(); newer builds split movement gating.
local movementGateReason = type(gate.movementReason) == "function" and gate.movementReason or gate.reason
assert(type(movementGateReason) == "function", "The game's movement controls are unavailable")
local tackle = require(gameState.TacklePrediction)
-- Some server builds use MeleeInputClient instead of this prediction module.
-- Never index an optional child directly or send the old payload on those builds.
local combat
local combatModule = gameState:FindFirstChild("CombatPrediction")
if combatModule and combatModule:IsA("ModuleScript") then
    local loaded, module = pcall(require, combatModule)
    if loaded and type(module) == "table" and type(module.meleeRemaining) == "function"
        and type(module.begin) == "function" and type(module.meleeBox) == "function" then
        combat = module
    end
end
local contact = require(gameState.ContactCatchConfig)
local rescueConfig = require(gameState.RescueConfig)
local hudNavigation = require(gameFolder.Presentation.HudNavigation)
local questEvent = gameFolder.Quests.QuestEvent
local spinEvent = gameFolder.SpinWheelEvent
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()
-- Keep an existing controller alive if loading a dependency fails.
local carry = previous and {Enabled = previous.Config.Enabled
        or previous.PauseReason == "Paused after repeated errors; AFK protection remains active", Stats = table.clone(previous.Stats),
    History = table.clone(previous.History), LastDash = previous.LastDash, Rewards = previous.Rewards,
    SessionStats = previous.SessionStats}
if previous and previous.Unload then previous.Unload() end
local DASH_DISTANCE = 20

local config = {
    Enabled = not carry or carry.Enabled, Acceleration = 3, TopSpeed = 1,
    AutoDash = env.__HussValleyDashWarningJob ~= game.JobId, DashInterval = 4.5, DashDistance = DASH_DISTANCE,
    Gems = true, Hunter = true, Melee = true, Tackle = true,
    Rescue = true, Abilities = true,
    Choice = "Chicken", Avoidance = 22,
    HunterAcquireDistance = 85, HunterGiveUpDistance = 105, HunterRetryDelay = 8,
}
local S = {
    Config = config, Version = "1.4.2", Alive = true, Ready = false,
    CombatMode = combat and "Prediction" or "Native input",
    WarningDashDisabled = not config.AutoDash,
    Direction = Vector3.zero, Driving = false, Status = "Starting",
    Stats = {Gems = 0, Pickups = 0, Dashes = 0, Melees = 0, Tackles = 0,
        AcceptedMelees = 0, AcceptedTackles = 0, Escapes = 0, Rescues = 0,
        IdlePulses = 0, Choices = 0, Recoveries = 0, Errors = 0, Catches = 0, AFKCorrections = 0,
        Spins = 0, QuestClaims = 0, ChasesAbandoned = 0},
    Connections = {}, Actors = {}, History = {}, LastError = "",
    LastDash = -10, LastAttack = -10, LastIdle = -100,
    LastAbility = -10, LastChoice = -10, LastAFK = -10,
    LastPlan = 0, LastUI = 0, LastActors = 0, LastPath = -10,
    TargetName = "None", NavGeneration = 0, SkippedGems = setmetatable({}, {__mode = "k"}), AFKHooks = {},
    QuestFocus = {Summary = "Loading quests..."}, ConsecutiveErrors = 0,
    IgnoredRunners = {}, RouteSide = nil,
}
if carry then
    for key, value in carry.Stats do S.Stats[key] = value end
    S.History, S.LastDash = carry.History, carry.LastDash
end
S.Rewards = carry and carry.Rewards or {
    PendingClaims = {}, ConfirmedClaims = {}, LastQuestRequest = -100, QuestAt = -100,
    LastClaim = -100, SpinAt = -100, LastSpinRequest = -100, SpinNextAllowed = 0,
    Credits = 0, NextFreeAt = 0, SpinReady = false, LastTick = -100,
}
S.SessionStats = carry and carry.SessionStats or {
    StartedAt = os.clock(), ActiveSeconds = 0, Metrics = {}, LastClock = os.clock(),
    ActivityStart = table.clone(S.Stats),
}
S.SessionStats.ActivityStart = S.SessionStats.ActivityStart or table.clone(S.Stats)
S.SessionStats.LastClock = os.clock()
env.__HussValleyAutoPlay = S
local function connect(signal, callback)
    local c = signal:Connect(callback)
    table.insert(S.Connections, c)
    return c
end
local function flat(v) return Vector3.new(v.X, 0, v.Z) end
local function unit(v) v = flat(v) return v.Magnitude > 0.001 and v.Unit or Vector3.zero end
local function distance(a, b) return flat(a - b).Magnitude end
local function record(message)
    table.insert(S.History, {at = os.clock(), message = message})
    if #S.History > 24 then table.remove(S.History, 1) end
end
-- Counts every observed positive award separately from spending and net change.
function S.ObserveMetric(tracker, key, value)
    if type(value) ~= "number" or value ~= value then return end
    local metric = tracker.Metrics[key]
    if not metric then
        tracker.Metrics[key] = {Start = value, Current = value, Gained = 0, Spent = 0, Net = 0}
        return
    end
    local change = value - metric.Current
    metric.Gained += math.max(0, change)
    metric.Spent += math.max(0, -change)
    metric.Current, metric.Net = value, value - metric.Start
end
local function observeWallet(wallet)
    if type(wallet) == "table" and wallet.loaded then
        S.ObserveMetric(S.SessionStats, "Gems", wallet.gems)
        S.ObserveMetric(S.SessionStats, "Coins", wallet.coins)
    end
end
function S.RefreshSessionStats()
    local tracker, now = S.SessionStats, os.clock()
    if config.Enabled then tracker.ActiveSeconds += math.max(0, now - tracker.LastClock) end
    tracker.LastClock = now
    -- Seed from the loaded HUD, then use ordered server wallet snapshots only.
    -- Reading an older HUD cache between events could count the same award twice.
    if not S.WalletStateSeen then observeWallet(hudNavigation.wallet) end
    if player:GetAttribute("StatsLoaded") == true then
        S.ObserveMetric(tracker, "XP", player:GetAttribute("TotalXP"))
        S.ObserveMetric(tracker, "Levels", player:GetAttribute("Level"))
        local leaderstats = player:FindFirstChild("leaderstats")
        if leaderstats then
            for _, key in {"Wins", "Catches", "LMS"} do
                local value = leaderstats:FindFirstChild(key)
                if value and value:IsA("ValueBase") then S.ObserveMetric(tracker, key, value.Value) end
            end
        end
    end
end
local function duration(seconds)
    local total = math.max(0, math.floor(seconds))
    return string.format("%02d:%02d:%02d", math.floor(total / 3600), math.floor(total / 60) % 60, total % 60)
end
local function metricLine(key, name)
    local metric = S.SessionStats.Metrics[key]
    if not metric then return (name or key) .. ": loading..." end
    return string.format("%s: +%d | Total: %d", name or key, metric.Gained, metric.Current)
end
local function activity(key)
    return math.max(0, (S.Stats[key] or 0) - (S.SessionStats.ActivityStart[key] or 0))
end
-- Quest plans use replicated objectives; progress is earned by ordinary play.
-- These helpers are exposed for focused diagnostics without changing game state.
function S.BuildQuestPlan(state)
    local plan = {Summary = "Loading quests...", NeedGems = false, SafeRun = false, NeedRescue = false}
    local candidates, claims, claimed = {}, {}, {}
    if type(state) ~= "table" or not state.loaded then return plan, claims, claimed end
    if state.mode == "Daily" and type(state.daily) == "table" then
        for _, q in state.daily.quests or {} do
            local key = "Daily:" .. tostring(state.daily.day) .. ":" .. tostring(q.id)
            if q.claimed then claimed[key] = true
            elseif q.complete then table.insert(claims, {key = key, action = "ClaimDaily", id = q.id, text = q.text})
            else table.insert(candidates, q) end
        end
    elseif state.mode == "Event" and type(state.event) == "table" then
        local event = state.event
        for _, weapon in event.weapons or {} do
            local key = "Event:" .. tostring(event.id) .. ":" .. tostring(weapon.id)
            if weapon.claimed then claimed[key] = true
            elseif not weapon.locked then
                if weapon.claimable and event.claimsEnabled then
                    table.insert(claims, {key = key, action = "ClaimEvent", id = weapon.id, text = weapon.name})
                end
                if event.phase == "Active" then
                    for _, q in weapon.quests or {} do
                        if not q.complete then table.insert(candidates, q) end
                    end
                end
            end
        end
    end
    local lead, best = nil, -1
    for _, q in candidates do
        local text = string.lower(tostring(q.id or "") .. " " .. tostring(q.text or ""))
        local target, progress = tonumber(q.target) or 1, tonumber(q.progress) or 0
        local ratio = math.clamp(progress / math.max(1, target), 0, 1)
        if q.alternateTarget then ratio = math.max(ratio, (tonumber(q.alternateProgress) or 0) / math.max(1, q.alternateTarget)) end
        if string.find(text, "gem") or string.find(text, "pickup") then plan.NeedGems = true end
        if string.find(text, "surviv") or string.find(text, "cross") or string.find(text, "escape") or string.find(text, "win") then plan.SafeRun = true end
        if string.find(text, "reviv") or string.find(text, "rescue") then plan.NeedRescue = true end
        if ratio > best then lead, best = q, ratio end
    end
    if lead then
        plan.Summary = string.format("%s: %d / %d", tostring(lead.text or lead.id), lead.progress or 0, lead.target or 0)
        if lead.alternateTarget then
            plan.Summary ..= string.format(" (or %d / %d)", lead.alternateProgress or 0, lead.alternateTarget)
        end
    else
        plan.Summary = #claims > 0 and "Claiming completed quest rewards..." or "Available quests complete; waiting for the next set."
    end
    plan.SafeRun = plan.SafeRun and not plan.NeedGems
    return plan, claims, claimed
end
local function receiveQuests(kind, state)
    if kind ~= "State" or type(state) ~= "table" then return end
    local rewards = S.Rewards
    rewards.QuestState, rewards.QuestAt = state, os.clock()
    local plan, claims, claimed = S.BuildQuestPlan(state)
    S.QuestFocus, rewards.Claimable = plan, claims
    for key in claimed do
        if rewards.PendingClaims[key] and not rewards.ConfirmedClaims[key] then
            rewards.ConfirmedClaims[key] = true
            S.Stats.QuestClaims += 1
            record("Quest reward confirmed: " .. tostring(rewards.PendingClaims[key].text or key))
        end
        rewards.PendingClaims[key] = nil
    end
    rewards.QuestMessage = state.message
end
local function receiveSpin(kind, state)
    if kind ~= "State" or type(state) ~= "table" then return end
    local rewards, now = S.Rewards, os.clock()
    rewards.Credits = math.max(0, tonumber(state.credits) or 0)
    rewards.NextFreeAt = tonumber(state.nextFreeAt) or 0
    rewards.SpinAt, rewards.SpinReady = now, true
    if state.result then
        if rewards.PendingSpin then
            S.Stats.Spins += 1
            rewards.LastSpinReward = tostring(state.result.message or "Spin reward received")
            record(rewards.LastSpinReward)
            if rewards.SpinOwnsPanel then rewards.CloseSpinAt = now + 6.2 end
        end
        rewards.PendingSpin = nil
        rewards.SpinNextAllowed = now + 7
    elseif state.message then
        rewards.PendingSpin = nil
        rewards.SpinMessage = tostring(state.message)
        rewards.SpinNextAllowed = now + 30
    end
end
local function rewardsTick()
    local rewards, now = S.Rewards, os.clock()
    if now - rewards.LastTick < 1 then return end
    rewards.LastTick = now
    if rewards.CloseSpinAt and now >= rewards.CloseSpinAt then
        rewards.CloseSpinAt = nil
        if rewards.SpinOwnsPanel then
            local gui = player.PlayerGui:FindFirstChild("SpinWheel")
            local main = gui and gui:FindFirstChild("Main")
            local close = main and main:FindFirstChild("CloseButton")
            if gui and gui.Enabled and close and firesignal then firesignal(close.Activated) end
        end
        rewards.SpinOwnsPanel = false
    end
    if not config.Enabled or player:GetAttribute("ClientReady") ~= true then return end
    local missingQuests = not rewards.QuestState or not rewards.QuestState.loaded
    if now - rewards.LastQuestRequest >= (missingQuests and 8 or 30) then
        rewards.LastQuestRequest = now
        questEvent:FireServer("Get")
    end
    if rewards.QuestState and rewards.QuestState.loaded and now - rewards.QuestAt < 45 and now - rewards.LastClaim >= 1.5 then
        for _, claim in rewards.Claimable or {} do
            local pending = rewards.PendingClaims[claim.key]
            if not rewards.ConfirmedClaims[claim.key] and (not pending or now >= pending.retryAt) then
                local attempts = pending and pending.attempts + 1 or 1
                rewards.PendingClaims[claim.key] = {at = now, attempts = attempts, retryAt = now + (attempts >= 3 and 60 or 10), text = claim.text}
                rewards.LastClaim = now
                questEvent:FireServer(claim.action, claim.id)
                break
            end
        end
    end
    if rewards.PendingSpin and now - rewards.PendingSpin > 12 then
        -- A late response must be reconciled before another credit is spent.
        rewards.PendingSpin = nil
        rewards.SpinReady = false
        rewards.SpinNextAllowed = now + 15
    end
    local freeDue = rewards.NextFreeAt > 0 and workspace:GetServerTimeNow() >= rewards.NextFreeAt
    if not rewards.PendingSpin and now - rewards.LastSpinRequest >= ((not rewards.SpinReady or freeDue) and 8 or 30) then
        rewards.LastSpinRequest = now
        spinEvent:FireServer("State")
    end
    if player:GetAttribute("InMatch") == true or session:GetAttribute("GlobalPaused") or session:GetAttribute("MapChanging") then return end
    if rewards.SpinReady and rewards.Credits >= 1 and not rewards.PendingSpin and now >= rewards.SpinNextAllowed and now - rewards.SpinAt < 45 then
        local gui = player.PlayerGui:FindFirstChild("SpinWheel")
        rewards.SpinOwnsPanel = gui and not gui.Enabled or false
        rewards.PendingSpin = now
        rewards.SpinNextAllowed = now + 10
        spinEvent:FireServer("Spin")
    end
end
S.RewardsTick = rewardsTick
local function character()
    local c = player.Character
    return c, c and c:FindFirstChildOfClass("Humanoid"), c and c:FindFirstChild("HumanoidRootPart")
end
local function cancelRescue()
    if S.Rescuing then
        gameState.RescueEvent:FireServer("Cancel", S.Rescuing.id)
        S.Rescuing = nil
    end
end
local function stopDash()
    if S.DashVelocity then S.DashVelocity:Destroy() S.DashVelocity = nil end
    if S.DashAttachment then S.DashAttachment:Destroy() S.DashAttachment = nil end
end
function S.DisableDashForWarning()
    if not S.Alive then return end
    config.AutoDash = false
    env.__HussValleyDashWarningJob = game.JobId
    stopDash()
    if not S.WarningDashDisabled then
        S.WarningDashDisabled = true
        record("Movement warning: all script dashes disabled for this server session")
        if S.Window then
            S.Window:Notify({title = "Dashing switched off", content = "Movement warning received. Autoplay continues without dashes."})
        end
    end
    -- Use the existing acknowledgment button after disabling the burst.
    -- This releases the game's ordinary menu gate for melee and abilities.
    task.defer(function()
        if not S.Alive or player:GetAttribute("FairPlayNoticeOpen") ~= true then return end
        pcall(function()
            local gui = player.PlayerGui:FindFirstChild("ValleyFairPlay")
            local shade = gui and gui:FindFirstChild("WarningShade")
            local warning = shade and shade:FindFirstChild("Warning")
            local button = warning and warning:FindFirstChild("Acknowledge")
            if button and firesignal then firesignal(button.Activated) end
        end)
    end)
end
local function stopMotion()
    S.Direction = Vector3.zero
    S.Driving = false
    S.NavGeneration += 1
    S.Path = nil
    S.PathBusy = false
    stopDash()
    cancelRescue()
    local _, h = character()
    if h then h:Move(Vector3.zero, false) end
end
function S.SetEnabled(value)
    S.RefreshSessionStats()
    config.Enabled = value == true
    S.PauseReason = nil
    stopMotion()
    S.Status = config.Enabled and "Starting" or "Paused"
    if S.EnableToggle then S.EnableToggle:Set(config.Enabled, true) end
end

-- Unwrap only the exact small Acceleration/MaxSpeed wrappers used by the
-- supplied script. This prevents the already-loaded script stacking 3x twice.
local entryStep = movement.step
local baseStep = entryStep
if debug.getconstants and debug.getupvalues then
    for _ = 1, 8 do
        local ok, nextStep = pcall(function()
            local names = {}
            for _, value in debug.getconstants(baseStep) do
                if type(value) == "string" then names[value] = true end
            end
            if not (names.Acceleration and names.MaxSpeed and names.clone)
                or names.dashRemaining or names.outputSpeed then return nil end
            local found
            for _, value in debug.getupvalues(baseStep) do
                if type(value) == "function" then
                    if found then return nil end
                    found = value
                end
            end
            return found
        end)
        if not ok or not nextStep then break end
        baseStep = nextStep
    end
end
S.BaseStep = baseStep
local wrapper
wrapper = function(state, input, speed, dt, profile, grounded, cameraInput, pace, request, velocity, touch)
    if S.Alive and config.Enabled then
        local adjusted = table.clone(profile)
        adjusted.Acceleration = profile.Acceleration * config.Acceleration
        adjusted.MaxSpeed = profile.MaxSpeed * config.TopSpeed
        S.AppliedAcceleration = adjusted.Acceleration
        S.BaseAcceleration = profile.Acceleration
        if S.Driving then
            input = S.Direction
            pace = 1
            local camera = workspace.CurrentCamera
            if camera then
                local forward = unit(camera.CFrame.LookVector)
                cameraInput = Vector3.new(input:Dot(forward:Cross(Vector3.yAxis)), 0, -input:Dot(forward))
            end
        end
        return baseStep(state, input, speed, dt, adjusted, grounded, cameraInput, pace, request, velocity, touch)
    end
    return baseStep(state, input, speed, dt, profile, grounded, cameraInput, pace, request, velocity, touch)
end
movement.step = wrapper

local function refreshActors(root)
    local actors, exclusions = {}, {player.Character}
    for _, participant in directory.list() do
        local c = participant.Character
        local r = c and c:FindFirstChild("HumanoidRootPart")
        local h = c and c:FindFirstChildOfClass("Humanoid")
        if c then table.insert(exclusions, c) end
        if participant.UserId ~= player.UserId and r and h and h.Health > 0 then
            table.insert(actors, {id = participant.UserId, name = participant.DisplayName or participant.Name,
                character = c, root = r, participant = participant,
                role = participant:GetAttribute("GameRole"), state = participant:GetAttribute("RunState")})
        end
    end
    S.Actors = actors
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = exclusions
    params.RespectCanCollide = true
    params.CollisionGroup = root.CollisionGroup
    S.Raycast = params
end
local function mapInfo()
    local active = gameState:FindFirstChild("ActiveMap")
    local map = active and active.Value
    local field = map and map:FindFirstChild("Field")
    if not field then return nil end
    local a, b = field:FindFirstChild("SafezoneASide"), field:FindFirstChild("SafezoneBSide")
    if not a or not b then return nil end
    local forward = unit(b.Position - a.Position)
    local across = Vector3.new(-forward.Z, 0, forward.X)
    local center = (a.Position + b.Position) * 0.5
    local width = math.max(a.Size.X, a.Size.Z)
    return {a = a, b = b, forward = forward, across = across, center = center,
        halfWidth = width * 0.5 - 5, halfLength = distance(a.Position, b.Position) * 0.5 - 16}
end
local function clampField(point, info, allowSafe)
    if not info then return point end
    local d = flat(point - info.center)
    local x = math.clamp(d:Dot(info.across), -info.halfWidth, info.halfWidth)
    local length = info.halfLength + (allowSafe and 25 or 0)
    local z = math.clamp(d:Dot(info.forward), -length, length)
    local p = info.center + info.across * x + info.forward * z
    return Vector3.new(p.X, point.Y, p.Z)
end
local function clearance(root, direction, length)
    if direction.Magnitude < 0.001 then return 0 end
    local side = Vector3.new(-direction.Z, 0, direction.X) * 1.4
    local best = length
    for _, offset in {Vector3.zero, side, -side} do
        local hit = workspace:Raycast(root.Position + offset, direction * length, S.Raycast)
        if hit then best = math.min(best, hit.Distance) end
    end
    return best
end
local function danger(point, horizon)
    local penalty, nearest = 0, math.huge
    local radius = S.QuestFocus.SafeRun and math.max(config.Avoidance, 30) or config.Avoidance
    for _, actor in S.Actors do
        if actor.role == "Catcher" and actor.state == "Active" and actor.root.Parent then
            local p = actor.root.Position + flat(actor.root.AssemblyLinearVelocity) * horizon
            local d = distance(point, p)
            nearest = math.min(nearest, d)
            penalty += math.max(0, radius - d) ^ 2 / 25
        end
    end
    return penalty, nearest
end
local function steering(root, goal, runner, info)
    local direct = unit(goal - root.Position)
    if direct.Magnitude == 0 then return direct end
    local best, score = direct, -math.huge
    local lookahead = math.clamp(flat(root.AssemblyLinearVelocity).Magnitude * 0.22 + 5, 9, 19)
    for _, angle in {0, 20, -20, 45, -45, 70, -70, 100, -100, 145, -145, 180} do
        local d = CFrame.Angles(0, math.rad(angle), 0):VectorToWorldSpace(direct)
        local clear = clearance(root, d, lookahead)
        local future = root.Position + d * math.min(lookahead, clear)
        local s = d:Dot(direct) * 9 + d:Dot(S.Direction) * 1.3
        s -= (1 - clear / lookahead) * 28
        if clear < 3 then s -= 100 end
        if info then
            local bounded = clampField(future, info, runner)
            s -= distance(future, bounded) * 5
        end
        if runner then
            local risk = danger(future, 0.15)
            s -= math.min(risk * 0.35, 11)
        end
        if s > score then score, best = s, d end
    end
    return best
end
local function requestPath(root, goal)
    if S.PathBusy or os.clock() - S.LastPath < 3 then return end
    S.LastPath = os.clock()
    S.PathBusy = true
    S.NavGeneration += 1
    local generation, start = S.NavGeneration, root.Position
    task.spawn(function()
        local ok, result = pcall(function()
            local path = PathfindingService:CreatePath({AgentRadius = 2, AgentHeight = 5, AgentCanJump = false, WaypointSpacing = 5})
            path:ComputeAsync(start, goal)
            return path.Status == Enum.PathStatus.Success and path:GetWaypoints() or nil
        end)
        if not S.Alive or generation ~= S.NavGeneration then return end
        S.PathBusy = false
        if ok and result and #result > 1 then
            S.Path = {points = result, index = 2, expires = os.clock() + 4, goal = goal}
            S.Stats.Recoveries += 1
        end
    end)
end
local function navigate(root, goal, runner, info)
    S.Goal = goal
    local now = os.clock()
    if not S.ProgressAt or not S.ProgressPosition or distance(root.Position, S.ProgressPosition) > 4 then
        S.ProgressAt, S.ProgressPosition = now, root.Position
    elseif now - S.ProgressAt > 1.25 and distance(root.Position, goal) > 6 then
        requestPath(root, goal)
        S.ProgressAt, S.ProgressPosition = now, root.Position
    end
    local target = goal
    if S.Path then
        if now > S.Path.expires or distance(goal, S.Path.goal) > 24 then
            S.Path = nil
        else
            local w = S.Path.points[S.Path.index]
            if w and distance(root.Position, w.Position) < 4 then
                S.Path.index += 1
                w = S.Path.points[S.Path.index]
            end
            if w then target = w.Position else S.Path = nil end
        end
    end
    S.Direction = distance(root.Position, target) < 1.7 and Vector3.zero or steering(root, target, runner, info)
    S.Driving = true
end
local function dash(root, humanoid, runner, manual)
    local now = os.clock()
    local direction = manual and unit(root.CFrame.LookVector) or S.Direction
    if not config.AutoDash or S.WarningDashDisabled or now - S.LastDash < config.DashInterval or direction.Magnitude < 0.1
        or humanoid.FloorMaterial == Enum.Material.Air or S.Rescuing then return end
    local c = root.Parent
    if c:GetAttribute("TackleActive") or tackle.isActive(c) or c:GetAttribute("GearMotion")
        or c:GetAttribute("MovementLocked") or now - S.LastAttack < 0.7 then return end
    local remaining = manual and DASH_DISTANCE + 9 or (S.Goal and distance(root.Position, S.Goal) or 0)
    local length = DASH_DISTANCE
    if remaining < length + (runner and 2 or 9) or clearance(root, direction, length + 3) < length + 2 then return end
    if runner and not manual then
        local _, d = danger(root.Position + direction * length, 0.15)
        if d < 10 then return end
    end
    stopDash()
    S.LastDash = now
    -- The supplied script's forward burst, using a horizontal plane so gravity remains normal.
    local attachment = Instance.new("Attachment")
    attachment.Name = "HussAutoDashAttachment"
    attachment.Parent = root
    local velocity = Instance.new("LinearVelocity")
    velocity.Name = "HussAutoDashVelocity"
    velocity.Attachment0 = attachment
    velocity.RelativeTo = Enum.ActuatorRelativeTo.World
    velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
    velocity.PrimaryTangentAxis = Vector3.xAxis
    velocity.SecondaryTangentAxis = Vector3.zAxis
    velocity.PlaneVelocity = Vector2.new(direction.X, direction.Z) * 75
    velocity.ForceLimitsEnabled = false
    velocity.Parent = root
    S.DashVelocity, S.DashAttachment = velocity, attachment
    Debris:AddItem(velocity, length / 75)
    Debris:AddItem(attachment, length / 75)
    S.Stats.Dashes += 1
end
local nativeMelee, nativeMeleeScript, lastMeleeLookup = nil, nil, -100
local function resolveNativeMelee()
    local scripts = player:FindFirstChild("PlayerScripts")
    local source = scripts and scripts:FindFirstChild("MeleeInputClient")
    if nativeMelee and source == nativeMeleeScript then return nativeMelee end
    nativeMelee, nativeMeleeScript = nil, nil
    if not source or os.clock() - lastMeleeLookup < 5 then return nil end
    lastMeleeLookup = os.clock()
    local function matches(fn)
        if type(fn) ~= "function" or not getfenv then return false end
        local ok, fnEnv = pcall(getfenv, fn)
        return ok and fnEnv and fnEnv.script == source and debug.info(fn, "n") == "request"
    end
    -- Prefer the live button's bound request closure; do not fire its touch-only UI.
    if getconnections and debug.getupvalues then
        local gui = player:FindFirstChild("PlayerGui")
        local hud = gui and gui:FindFirstChild("HUD")
        local button = hud and hud:FindFirstChild("MeleeButton")
        if button then
            pcall(function()
                for _, connection in getconnections(button.Activated) do
                    if type(connection.Function) == "function" then
                        for _, fn in debug.getupvalues(connection.Function) do
                            if matches(fn) then nativeMelee = fn break end
                        end
                    end
                    if nativeMelee then break end
                end
            end)
        end
    end
    if not nativeMelee and filtergc then
        pcall(function()
            local found = filtergc("function", {Name = "request", Constants = {"ReachStartedAt", "FireServer"}}, false)
            for _, fn in found or {} do
                if matches(fn) then nativeMelee = fn break end
            end
        end)
    end
    if nativeMelee then nativeMeleeScript = source end
    return nativeMelee
end
local function attack(root, target)
    local c = root.Parent
    if gate.reason(player) or c:GetAttribute("TackleActive") or tackle.isActive(c)
        or c:GetAttribute("DaggerEquipped") and c:GetAttribute("DaggerState") ~= "Held" then return end
    local now, serverNow = os.clock(), workspace:GetServerTimeNow()
    local d = distance(root.Position, target.root.Position)
    local aim = unit(target.root.Position + flat(target.root.AssemblyLinearVelocity) * (d < 9 and 0.12 or 0.24) - root.Position)
    if aim.Magnitude == 0 then return end
    if clearance(root, aim, math.max(0, d - 2)) < d - 3 then return end
    local reachAt = c:GetAttribute("ReachStartedAt") or -100
    local remaining = math.max(0, combat and combat.meleeRemaining() or 0,
        reachAt + contact.Windup + contact.ActiveDuration + contact.Recovery - serverNow)
    if config.Melee and contact.Enabled ~= false and d < 9 and now - S.LastAttack >= 0.88 and remaining <= 0 then
        local nativeRequest = not combat and resolveNativeMelee() or nil
        if not combat and not nativeRequest then
            S.CombatNote = "Melee waiting for the game's controls"
            return
        end
        S.CombatNote = nil
        stopDash()
        root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)
        S.LastAttack = now
        if combat then
            local id = HttpService:GenerateGUID(false)
            gameState.MeleeEvent:FireServer({id = id, at = serverNow, direction = aim, position = root.Position})
            combat.begin({kind = "Melee", predicted = true, id = id, character = c,
                startedAt = serverNow, starts = serverNow + contact.Windup,
                ends = serverNow + contact.Windup + contact.ActiveDuration,
                direction = aim, box = combat.meleeBox(c)})
        else
            -- The game's request owns its numeric ID, cooldown and acknowledgment.
            -- Reusing it also avoids conflicting with manual melee input.
            nativeRequest()
        end
        S.Stats.Melees += 1
    elseif config.Tackle and d >= 9 and d < 14 and now - S.LastAttack >= 0.9
        and remaining <= 0 and tackle.remaining() <= 0.02 then
        stopDash()
        root.CFrame = CFrame.lookAt(root.Position, root.Position + aim)
        if tackle.request() then S.LastAttack = now S.Stats.Tackles += 1 end
    end
end
local function useAbility(nearby)
    if not config.Abilities or nearby > 35 or os.clock() - S.LastAbility < 1.5 or gate.reason(player) then return end
    local knife = player:GetAttribute("EquippedKnife")
    local name, ready
    if knife == "GhostScythe" then name, ready = "GhostAbilityEvent", "GhostAbilityReadyAt"
    elseif knife == "CloneDagger" then name, ready = "CloneAbilityEvent", "CloneAbilityReadyAt" end
    if name and (player:GetAttribute(ready) or 0) <= workspace:GetServerTimeNow() then
        local remote = gameFolder.Weapons:FindFirstChild(name)
        if remote then S.LastAbility = os.clock() remote:FireServer("Activate") end
    end
end
local function sideRoute(root, safe, info)
    local key = tostring(session:GetAttribute("RunNumber")) .. ":" .. tostring(session:GetAttribute("StartSide"))
    local localPosition = flat(root.Position - info.center)
    local x, z = localPosition:Dot(info.across), localPosition:Dot(info.forward)
    local destinationZ = flat(safe - info.center):Dot(info.forward)
    local travelSign = destinationZ >= z and 1 or -1
    local width = math.max(8, info.halfWidth - 12)
    if S.RouteKey ~= key or not S.RouteSide then
        local preferred = ((session:GetAttribute("RunNumber") or 0) + player.UserId) % 2 == 0 and 1 or -1
        local bestSide, lowest = preferred, math.huge
        for _, side in {preferred, -preferred} do
            local probe = info.center + info.across * width * side + info.forward * (z + travelSign * 30)
            local risk = danger(probe, 0.4)
            local cost = math.abs(x - width * side) * 0.2 + risk * 2 - (side == preferred and 5 or 0)
            if cost < lowest then bestSide, lowest = side, cost end
        end
        S.RouteKey, S.RouteSide = key, bestSide
    end
    -- Stable side choice per crossing, with smooth variation instead of frame-to-frame zigzag.
    local wave = math.sin(z / 24 + (session:GetAttribute("RunNumber") or 0) * 1.7) * 6
    local laneX = math.clamp(S.RouteSide * width + wave, -info.halfWidth + 4, info.halfWidth - 4)
    local remaining = math.abs(destinationZ - z)
    local lookahead = math.min(35, remaining)
    local laneBlend = math.clamp(lookahead / (math.abs(laneX - x) + lookahead + 0.001), 0.35, 1)
    local nextX = remaining < 25 and x or x + (laneX - x) * laneBlend
    local nextZ = z + travelSign * lookahead
    local point = info.center + info.across * nextX + info.forward * nextZ
    return Vector3.new(point.X, root.Position.Y, point.Z)
end
-- Higher-value tiers outrank distance: a reachable safe 6 beats a 3, and a 3 beats a 1.
function S.GemRank(amount, d, risk, held)
    local tier = amount >= 6 and 3 or amount >= 3 and 2 or 1
    return tier, d + risk * 1.5 - (held and 18 or 0)
end
local function runnerGoal(root, info, phase)
    local targetZone = info and (session:GetAttribute("StartSide") == "B" and info.a or info.b)
    if not targetZone then S.Status = "Waiting for map safe zones" return nil end
    local projected = targetZone.CFrame:PointToObjectSpace(root.Position)
    local safe = targetZone.CFrame:PointToWorldSpace(Vector3.new(math.clamp(projected.X, -targetZone.Size.X/2+8, targetZone.Size.X/2-8), 0, 0))
    safe = Vector3.new(safe.X, root.Position.Y, safe.Z)
    local timeLeft = (session:GetAttribute("EndsAt") or 0) - workspace:GetServerTimeNow()
    local moveSpeed = math.max(20, profiles.get("Runner", player).MaxSpeed * config.TopSpeed)
    local _, nearestThreat = danger(root.Position, 0)
    useAbility(nearestThreat)
    local best, bestTier, bestScore = nil, 0, math.huge
    local gems = workspace:FindFirstChild("LocalRunnerGems")
    if S.GemTarget and S.GemTarget.Parent then
        local d = distance(root.Position, S.GemTarget.Position)
        if not S.GemBestDistance or d < S.GemBestDistance - 2 then
            S.GemBestDistance, S.GemProgressAt = d, os.clock()
        elseif os.clock() - (S.GemProgressAt or os.clock()) > 4.5 then
            S.SkippedGems[S.GemTarget] = os.clock() + 6
            S.GemTarget = nil
        end
    end
    if config.Gems and gems and timeLeft > distance(root.Position, safe) / moveSpeed + 2.5 then
        for _, gem in gems:GetChildren() do
            if gem:IsA("BasePart") and (S.SkippedGems[gem] or 0) < os.clock() then
                local gui = gem:FindFirstChildOfClass("BillboardGui")
                local icon = gui and gui:FindFirstChild("Gem")
                if gui and gui.Enabled and (not icon or icon.Visible) then
                    local label = gui:FindFirstChild("Amount")
                    local amount = label and tonumber(label.Text:match("%d+")) or 1
                    local d = distance(root.Position, gem.Position)
                    local onward = distance(gem.Position, safe)
                    local travel = (d + onward) / moveSpeed
                    local detour = d + onward - distance(root.Position, safe)
                    local risk, threat = danger(gem.Position, math.clamp(d / moveSpeed, 0.1, 0.7))
                    local worthDetour = amount >= 3 or d <= 32 or detour <= 15
                    if worthDetour and travel + 2.5 < timeLeft and threat > (amount >= 3 and 9 or 14) then
                        local tier, score = S.GemRank(amount, d, risk, S.GemTarget == gem)
                        if tier > bestTier or (tier == bestTier and score < bestScore) then
                            best, bestTier, bestScore = gem, tier, score
                        end
                    end
                end
            end
        end
    end
    if S.GemTarget ~= best then
        S.GemSince, S.GemProgressAt = os.clock(), os.clock()
        S.GemBestDistance = best and distance(root.Position, best.Position) or nil
    end
    S.GemTarget = best
    if best then
        cancelRescue()
        S.Status = bestTier == 3 and "Collecting 6-gem pickup" or bestTier == 2 and "Collecting 3-gem pickup" or "Collecting nearby gem"
        S.TargetName = best.Name
        return Vector3.new(best.Position.X, root.Position.Y, best.Position.Z)
    end
    if config.Rescue and nearestThreat > 22 and timeLeft > distance(root.Position, safe) / moveSpeed + 5 then
        for _, actor in S.Actors do
            local other = actor.character
            local helper = other:GetAttribute("RescueHelperId")
            if actor.role == "Runner" and other:GetAttribute("RescueAvailable") and other:GetAttribute("Ragdolled")
                and (not helper or helper == player.UserId) and distance(root.Position, actor.root.Position) < rescueConfig.Range - 1 then
                if S.Rescuing and S.Rescuing.id ~= actor.id then cancelRescue() end
                if not S.Rescuing then
                    S.Rescuing = {id = actor.id, at = os.clock()}
                    gameState.RescueEvent:FireServer("Begin", actor.id)
                elseif not S.Rescuing.sent and os.clock() - S.Rescuing.at >= rescueConfig.HoldSeconds + 0.05 then
                    gameState.RescueEvent:FireServer("Finish", actor.id)
                    S.Rescuing.sent = true
                    S.Stats.Rescues += 1
                end
                if os.clock() - S.Rescuing.at < rescueConfig.HoldSeconds + rescueConfig.FinishGrace then
                    S.Status, S.TargetName = "Reviving a nearby runner", actor.name
                    return root.Position
                end
            end
        end
    end
    cancelRescue()
    S.Status, S.TargetName = "Crossing along the side", targetZone.Name
    if timeLeft < distance(root.Position, safe) / moveSpeed + 2 then return safe end
    return sideRoute(root, safe, info)
end
local function hunterGoal(root, info)
    local now = os.clock()
    local current
    for _, actor in S.Actors do if actor.id == S.HunterTarget then current = actor break end end
    if current and current.root.Parent then
        local d = distance(root.Position, current.root.Position)
        local lostDistance = d > config.HunterGiveUpDistance
        local losingChase = S.ChaseProgressAt and now - S.ChaseProgressAt > 4 and d > 45
        if lostDistance or losingChase then
            S.IgnoredRunners[current.id] = now + config.HunterRetryDelay
            S.HunterTarget, S.ChaseProgressAt, S.ChaseBestDistance = nil, nil, nil
            S.Path = nil
            S.Stats.ChasesAbandoned += 1
            record("Abandoned distant runner: " .. current.name)
        end
    end
    local best, score = nil, math.huge
    for _, actor in S.Actors do
        if actor.role == "Runner" and actor.state == "Active" and actor.root.Parent
            and not actor.character:GetAttribute("Ragdolled") then
            local d = distance(root.Position, actor.root.Position)
            local isCurrent = S.HunterTarget == actor.id
            local limit = isCurrent and config.HunterGiveUpDistance or config.HunterAcquireDistance
            if d <= limit and (S.IgnoredRunners[actor.id] or 0) <= now then
                local rank = d - (isCurrent and 10 or 0)
                if rank < score then best, score = actor, rank end
            end
        end
    end
    if not best then
        S.HunterTarget = nil
        S.Status, S.TargetName = "Holding the middle for runners", "Center field"
        return info and Vector3.new(info.center.X, root.Position.Y, info.center.Z) or root.Position
    end
    local d = distance(root.Position, best.root.Position)
    if S.HunterTarget ~= best.id then
        S.ChaseProgressAt, S.ChaseBestDistance = now, d
        S.Path = nil
    elseif not S.ChaseBestDistance or d < S.ChaseBestDistance - 3 then
        S.ChaseProgressAt, S.ChaseBestDistance = now, d
    end
    S.HunterTarget = best.id
    S.Status, S.TargetName = "Hunting runners", best.name
    local speed = math.max(20, profiles.get("Catcher", player).MaxSpeed * config.TopSpeed)
    local lead = math.clamp(d / speed * 0.65, 0.05, 0.75)
    local goal = best.root.Position + flat(best.root.AssemblyLinearVelocity) * lead
    goal = clampField(Vector3.new(goal.X, root.Position.Y, goal.Z), info, false)
    attack(root, best)
    useAbility(d)
    return goal
end
local function choices(root, phase)
    if os.clock() - S.LastChoice < 1.5 then return end
    if phase == "HeroChoice" and session:GetAttribute("SelectedUserId") == player.UserId then
        S.LastChoice = os.clock()
        local choice = "Chicken"
        gameState.GameAction:FireServer("HeroChoice", choice)
        S.Stats.Choices += 1
        record("Chose " .. choice)
    elseif phase == "SelectHero" and session:GetAttribute("LeadUserId") == player.UserId then
        local chosen, best = nil, math.huge
        for _, a in S.Actors do
            if a.role == "Runner" then
                local d = distance(root.Position, a.root.Position)
                if d < best then chosen, best = a, d end
            end
        end
        if chosen then
            S.LastChoice = os.clock()
            gameState.GameAction:FireServer("SelectHero", chosen.id)
            S.Stats.Choices += 1
            record("Selected " .. chosen.name)
        end
    end
end
function S.IdlePulse()
    if not S.Alive then return end
    local ok, err = pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.zero)
    end)
    S.LastIdle = os.clock()
    S.IdleWorking = ok
    if ok then S.Stats.IdlePulses += 1 else S.LastError = "Idle prevention: " .. tostring(err) end
end
function S.KeepAFKOff()
    if not S.Alive then return end
    if player:GetAttribute("AFK") == true and os.clock() - S.LastAFK >= 0.6 then
        S.LastAFK = os.clock()
        gameState.PlayerPreferences:FireServer("SetAFK", false)
        S.Stats.AFKCorrections += 1
    end
end
-- Block the actual UI/hotkey callback, rather than toggling the AFK flag.
-- The signal below also handles server-originated AFK changes and respawns.
local function installAFKLock()
    if hookfunction and getfenv then
        local matches = {}
        -- Prefer the connected callback: restored hook copies may remain in GC.
        if getconnections then
            pcall(function()
                local misc = player.PlayerGui:FindFirstChild("Misc")
                local main = misc and misc:FindFirstChild("MainFrame")
                local controls = main and main:FindFirstChild("LobbyControls")
                local frame = controls and controls:FindFirstChild("AFKF")
                local button = frame and frame:FindFirstChild("AFKButton")
                if button then
                    for _, connection in getconnections(button.Activated) do
                        local fn = connection.Function
                        if type(fn) == "function" and debug.info(fn, "n") == "toggleAFK" then table.insert(matches, fn) end
                    end
                end
            end)
        end
        if #matches == 0 and filtergc then
            local ok, found = pcall(filtergc, "function", {Name = "toggleAFK", Constants = {"SetAFK", "AFK"}}, false)
            if ok and type(found) == "table" then matches = found end
        end
        if #matches > 0 then
            for _, fn in matches do
                local envOK, fnEnv = pcall(getfenv, fn)
                local source = envOK and fnEnv and fnEnv.script
                if typeof(source) == "Instance" and source.Name == "LobbyControlsClient" and source:IsDescendantOf(player.PlayerGui) then
                    local hooked, original = pcall(hookfunction, fn, function() S.KeepAFKOff() end)
                    if hooked then table.insert(S.AFKHooks, {fn = fn, original = original}) end
                end
            end
        end
    end
    ContextActionService:BindActionAtPriority("HussAutoplayKeepAFKOff", function()
        return Enum.ContextActionResult.Sink
    end, false, 10000, Enum.KeyCode.K)
    S.AFKLocked = #S.AFKHooks > 0
end
local function tick()
    local now = os.clock()
    if now - S.LastIdle > 55 then S.IdlePulse() end
    S.KeepAFKOff()
    if player:GetAttribute("FairPlayNoticeOpen") == true then S.DisableDashForWarning() end
    if not config.Enabled then S.Status = S.PauseReason or "Paused" return end
    local c, h, root = character()
    if not root or not h or h.Health <= 0 then stopMotion() S.Status = "Waiting for respawn" return end
    if now - S.LastActors > 0.3 then S.LastActors = now refreshActors(root) end
    local phase = session:GetAttribute("Phase") or "Lobby"
    local role, state = player:GetAttribute("GameRole"), player:GetAttribute("RunState")
    local mode = tostring(phase) .. "/" .. tostring(role) .. "/" .. tostring(state)
    if mode ~= S.Mode then
        S.Mode = mode
        stopMotion()
        S.GemTarget, S.HunterTarget, S.ProgressAt = nil, nil, nil
        record(mode)
    end
    S.Phase, S.Role, S.RunState = phase, role, state
    choices(root, phase)
    local blocked = movementGateReason(player)
    if UserInputService:GetFocusedTextBox() then blocked = "Typing" end
    if blocked or root.Anchored or c:GetAttribute("MovementLocked") or c:GetAttribute("Ragdolled")
        or h.PlatformStand or h.Sit then
        stopMotion()
        S.Status = "Waiting: " .. tostring(blocked or c:GetAttribute("MovementLockReason") or state or "movement lock")
        return
    end
    if player:GetAttribute("InMatch") ~= true or state ~= "Active" then
        stopMotion()
        S.Status = state == "Caught" and "Caught: waiting for rescue or hunter role"
            or state == "Safe" and "Safe: waiting for next crossing" or "Waiting for the next round"
        return
    end
    local running = phase == "GroupRun" or phase == "HeroRun" or phase == "FinalRun"
    if not running then stopMotion() S.Status = "Round: " .. phase return end
    local info = mapInfo()
    local goal
    if role == "Runner" then goal = runnerGoal(root, info, phase)
    elseif role == "Catcher" and config.Hunter then goal = hunterGoal(root, info)
    else stopMotion() S.Status = "Waiting for an active role" return end
    if not goal then stopMotion() return end
    navigate(root, goal, role == "Runner", info)
    dash(root, h, role == "Runner")
end

connect(player.Idled, S.IdlePulse)
connect(gameFolder.Weapons.ArmoryEvent.OnClientEvent, function(kind, state)
    if kind == "State" and type(state) == "table" and state.loaded then
        S.WalletStateSeen = true
        observeWallet(state)
    end
end)
connect(player:GetAttributeChangedSignal("TotalXP"), S.RefreshSessionStats)
connect(player:GetAttributeChangedSignal("Level"), S.RefreshSessionStats)
connect(questEvent.OnClientEvent, receiveQuests)
connect(spinEvent.OnClientEvent, receiveSpin)
connect(player:GetAttributeChangedSignal("AFK"), S.KeepAFKOff)
connect(player:GetAttributeChangedSignal("FairPlayNoticeOpen"), function()
    if player:GetAttribute("FairPlayNoticeOpen") == true then S.DisableDashForWarning() end
end)
connect(gameFolder.Presentation.MovementGuardEvent.OnClientEvent, function(kind)
    if kind == "Warning" then S.DisableDashForWarning() end
end)
connect(player.CharacterAdded, function() stopMotion() S.LastActors = 0 end)
connect(gameFolder.Collectibles.GemEvent.OnClientEvent, function(kind, data)
    if kind == "Collected" and type(data) == "table" then
        S.Stats.Gems += tonumber(data.amount) or 1
        S.Stats.Pickups += 1
        record("Collected " .. tostring(data.amount or 1) .. " gems")
    end
end)
connect(gameState.MeleeEvent.OnClientEvent, function(_, accepted)
    if accepted then S.Stats.AcceptedMelees += 1 end
end)
connect(gameState.GameAction.OnClientEvent, function(kind, _, accepted)
    if kind == "TackleResult" and accepted then S.Stats.AcceptedTackles += 1 end
end)
connect(gameFolder.Audio.Events.OnClientEvent, function(kind, data)
    if kind == "CatchConfirmed" and type(data) == "table" and data.catcher == player.UserId then
        S.Stats.Catches += 1
        record("Caught " .. tostring(data.name or "runner"))
    end
end)
connect(player:GetAttributeChangedSignal("RunState"), function()
    if player:GetAttribute("RunState") == "Safe" then S.Stats.Escapes += 1 record("Reached safety") end
end)

function S.Unload()
    if not S.Alive then return end
    S.Alive = false
    stopMotion()
    for _, c in S.Connections do c:Disconnect() end
    table.clear(S.Connections)
    ContextActionService:UnbindAction("HussAutoplayKeepAFKOff")
    for _, hook in S.AFKHooks do pcall(hookfunction, hook.fn, hook.original) end
    table.clear(S.AFKHooks)
    if movement.step == wrapper then movement.step = entryStep end
    if S.Window and not S.Window.unloaded then S.Window:Unload() end
    if env.__HussValleyAutoPlay == S then env.__HussValleyAutoPlay = nil end
end
local ok, setupError = xpcall(function()
    local window = Rayfield:CreateWindow({name = "Huss Valley Autoplay", subtitle = "Every crossing. Every role.",
        sidebarLayout = true, theme = "cobalt", showName = "Autoplay"})
    S.Window = window
    local home = window:CreateTab({name = "Autoplay", icon = "play"})
    local movementTab = window:CreateTab({name = "Movement", icon = "activity"})
    local sessionTab = window:CreateTab({name = "Session", icon = "chart-no-axes-combined"})
    S.StatusText = home:CreateText({name = "Live status", text = "Starting controller..."})
    S.EnableToggle = home:CreateToggle({name = "Play automatically", value = config.Enabled,
        forgetState = true, callback = S.SetEnabled})
    S.HealthText = home:CreateText({name = "AFK stays OFF", text = "Always protected, including while Autoplay is paused."})
    S.StatsText = home:CreateText({name = "This session", text = "Waiting for results..."})
    S.RewardsText = home:CreateText({name = "Quests & spins", text = "Checking quest progress and available spins..."})
    home:CreateText({name = "Controls", text = "F6: pause / resume   F7: hide / show   P: dash\nQuests, available spins, gems and hunter actions run automatically."})
    home:CreateButton({name = "Stop and unload", callback = S.Unload})
    movementTab:CreateText({name = "3x acceleration", text = "Fixed at maximum. Uses the original script's forward dash, aimed toward the current destination."})
    movementTab:CreateSlider({name = "Dash interval", range = {4, 5}, increment = 0.1, value = 4.5, suffix = " s",
        callback = function(v) config.DashInterval = v end})
    S.DashText = movementTab:CreateText({name = "20-stud dash", text = "Distance fixed at 20 studs. A movement warning automatically switches dashing off."})
    S.SessionClockText = sessionTab:CreateText({name = "Session time", text = "Starting..."})
    S.SessionEconomyText = sessionTab:CreateText({name = "Gems & coins earned", text = "Loading wallet..."})
    S.SessionProgressText = sessionTab:CreateText({name = "XP & levels gained", text = "Loading progression..."})
    S.SessionMatchesText = sessionTab:CreateText({name = "Match results", text = "Loading stats..."})
    S.SessionActivityText = sessionTab:CreateText({name = "Autoplay activity", text = "Waiting for results..."})
    connect(UserInputService.InputBegan, function(input, processed)
        if processed or UserInputService:GetFocusedTextBox() then return end
        if input.KeyCode == Enum.KeyCode.F6 then S.SetEnabled(not config.Enabled)
        elseif input.KeyCode == Enum.KeyCode.F7 then window:ToggleHide()
        elseif input.KeyCode == Enum.KeyCode.P then
            local c, h, root = character()
            if root and h and h.Health > 0 and not root.Anchored and not c:GetAttribute("MovementLocked") then
                refreshActors(root)
                dash(root, h, player:GetAttribute("GameRole") == "Runner", true)
            end
        end
    end)
    local originalUnload = window.Unload
    window.Unload = function(self, ...)
        if S.Alive then S.Unload() return end
        return originalUnload(self, ...)
    end
    connect(RunService.Heartbeat, function()
        if not S.Alive then return end
        local now = os.clock()
        if now - S.LastPlan >= 0.1 then
            S.LastPlan = now
            local success, err = xpcall(tick, debug.traceback)
            if not success then
                S.Stats.Errors += 1
                S.ConsecutiveErrors += 1
                S.LastError = tostring(err)
                S.Direction = Vector3.zero
                stopDash()
                S.Status = "Recovering from controller error"
                if S.ConsecutiveErrors >= 3 then
                    S.SetEnabled(false)
                    S.PauseReason = "Paused after repeated errors; AFK protection remains active"
                end
                if S.Stats.Errors <= 3 then warn("[HussAutoplay] " .. tostring(err)) end
            else
                S.ConsecutiveErrors = 0
            end
        end
        local rewardsOK, rewardsError = pcall(rewardsTick)
        S.Rewards.LastError = not rewardsOK and tostring(rewardsError) or nil
        if now - S.LastUI >= 0.6 then
            S.LastUI = now
            pcall(function()
                S.RefreshSessionStats()
                S.StatusText:Set(string.format("%s\nRole: %s | Round: %s\nTarget: %s%s", S.Status, S.Role or "Loading", S.Phase or "Loading", S.TargetName,
                    S.CombatNote and "\n" .. S.CombatNote or ""))
                S.StatsText:Set(string.format("Gems: %d | Escapes: %d | Catches: %d\nDashes: %d | Errors: %d", S.Stats.Gems, S.Stats.Escapes, S.Stats.Catches, S.Stats.Dashes, S.Stats.Errors))
                S.RewardsText:Set(string.format("%s\nQuest rewards claimed: %d | Spins used: %d | Available: %d%s", S.QuestFocus.Summary,
                    S.Stats.QuestClaims, S.Stats.Spins, S.Rewards.Credits, S.Rewards.LastError and "\nRewards retrying: " .. S.Rewards.LastError:sub(1, 80) or ""))
                S.DashText:Set(S.WarningDashDisabled and "OFF after a movement warning. Autoplay continues without dashes."
                    or string.format("Fixed at 20 studs. Minimum delay: %.1f seconds. Skips dashes when the destination is too close.", config.DashInterval))
                S.HealthText:Set(string.format("Game AFK: %s | Toggle: %s\nIdle prevention: %s (%d pulses)%s", player:GetAttribute("AFK") == true and "clearing..." or "OFF", S.AFKLocked and "locked" or "K blocked / state watched", S.IdleWorking == false and "unavailable" or "active", S.Stats.IdlePulses, S.LastError ~= "" and "\n" .. S.LastError:sub(1, 160) or ""))
                S.SessionClockText:Set("Elapsed: " .. duration(now - S.SessionStats.StartedAt) .. "\nAutoplay active: " .. duration(S.SessionStats.ActiveSeconds))
                local gems, coins = S.SessionStats.Metrics.Gems, S.SessionStats.Metrics.Coins
                local walletText = metricLine("Gems") .. "\n" .. metricLine("Coins")
                if gems and coins then walletText ..= string.format("\nSpent: %d gems / %d coins | Net: %+d / %+d", gems.Spent, coins.Spent, gems.Net, coins.Net) end
                S.SessionEconomyText:Set(walletText)
                S.SessionProgressText:Set(metricLine("XP") .. "\n" .. metricLine("Levels"))
                S.SessionMatchesText:Set(metricLine("Catches") .. "\n" .. metricLine("Wins") .. "\n" .. metricLine("LMS", "Last-runner wins"))
                S.SessionActivityText:Set(string.format("Gem pickups: %d | Gems from pickups: %d\nCrossings: %d | Dashes: %d\nSpins: %d | Quest claims: %d\nChases abandoned: %d | Route recoveries: %d", activity("Pickups"), activity("Gems"),
                    activity("Escapes"), activity("Dashes"), activity("Spins"), activity("QuestClaims"), activity("ChasesAbandoned"), activity("Recoveries")))
            end)
        end
    end)
    S.Ready = true
    S.RefreshSessionStats()
    installAFKLock()
    S.KeepAFKOff()
    S.IdlePulse()
    window:Notify({title = "Autoplay enabled", content = S.WarningDashDisabled and "AFK locked off. Dashing remains off after the movement warning."
        or "AFK locked off. 3x acceleration. Fixed 20-stud dash every 4.5s when clear. F6 pauses."})
end, debug.traceback)
if not ok then S.Unload() error(setupError) end
return S
