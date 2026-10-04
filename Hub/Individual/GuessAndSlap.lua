-- Guess And Slap | Rayfield Gen2 | Place 100975894126710
-- Execute in the connected client. Run again to replace the previous session.
-- Client automation cannot guarantee server acceptance or hidden-state accuracy.
local ENV = getgenv()
if ENV.GuessAndSlapSuite then ENV.GuessAndSlapSuite:Unload() end
assert(game.PlaceId == 100975894126710, "This script is for Guess And Slap")

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer
local Remotes = game:GetService("ReplicatedStorage"):WaitForChild("Remotes", 10)
assert(Remotes, "Game remotes are unavailable")
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()
local S = {
    alive = true, connections = {}, options = {slap=true, dodge=true, guess=true},
    stats = {slaps=0, perfect=0, dodges=0, dodgeSuccess=0, dodgeFailure=0, guesses=0},
    slapEpoch=0, dodgeEpoch=0, guessEpoch=0, round=0,
    slapDelay=0.12, dodgeDelay=0.10, candidates={}, observations={}, history={},
    status="Ready — enter a round", lastSample=0, lastUI=0,
}
ENV.GuessAndSlapSuite = S
local window = Rayfield:CreateWindow({name="Guess & Slap", subtitle="Developer controls • Gen2", theme="cobalt", sidebarLayout=true, showName="Guess & Slap"})
S.window = window
local tab = window:CreateTab({name="Automation"})
local status = tab:CreateText({name="Live status", text=S.status})
local function log(message)
    S.status=message
    table.insert(S.history, {time=os.clock(), message=message})
    if #S.history>40 then table.remove(S.history,1) end
end
local function connect(signal, callback)
    local connection=signal:Connect(function(...)
        if not S.alive then return end
        local ok, err=pcall(callback,...)
        if not ok then S.lastError=tostring(err); log("Error: "..tostring(err)) end
    end)
    table.insert(S.connections,connection)
    return connection
end
local function frames()
    local gui=LocalPlayer.PlayerGui:FindFirstChild("UI")
    return gui and gui:FindFirstChild("Frames")
end
local function resetRound()
    S.round+=1; S.observations={}; S.candidates={}; S.guessActive=false
    S.evidence=nil; S.revealed=nil; S.guessEpoch+=1
end
function S:Unload()
    if not self.alive then return end
    self.alive=false
    for _,c in self.connections do c:Disconnect() end
    if self.window and not self.window.unloaded then self.window:Unload() end
    if ENV.GuessAndSlapSuite==self then ENV.GuessAndSlapSuite=nil end
end

-- These animation IDs were observed on the slapper, separately from hit reactions.
local SLAPPER_ANIMATIONS = { ["71212205112374"]=true, ["78309173361667"]=true }
local function sampleSlapper()
    if not S.sitting or S.guessActive then return end
    local c=LocalPlayer.Character
    local root=c and c:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local found={}
    for _,p in Players:GetPlayers() do
        if p~=LocalPlayer then
            local pc=p.Character
            local pr=pc and pc:FindFirstChild("HumanoidRootPart")
            local h=pc and pc:FindFirstChildOfClass("Humanoid")
            if pr and h and (pr.Position-root.Position).Magnitude<=7 then
                for _,track in h:GetPlayingAnimationTracks() do
                    local id=track.Animation and track.Animation.AnimationId:match("%d+")
                    if SLAPPER_ANIMATIONS[id] and track.IsPlaying then
                        found[p.Name]=true
                        break
                    end
                end
            end
        end
    end
    local name, count=nil,0
    for n in found do name=n; count+=1 end
    if count==1 then S.observations={name=name,time=os.clock(),round=S.round} end
end
local function freezeEvidence()
    sampleSlapper()
    local o=S.observations
    if o.name and o.round==S.round and os.clock()-o.time<=1.5 then
        S.evidence={name=o.name,time=os.clock(),round=S.round}
    end
end
local function chooseCandidate(candidates,revealed,evidence,round,now)
    if revealed and candidates[revealed] then return revealed,"server reveal" end
    local only,count=nil,0
    for name in candidates do only=name; count+=1 end
    if count==1 then return only,"only candidate" end
    if evidence and evidence.round==round and now-evidence.time<=12 and candidates[evidence.name] then
        return evidence.name,"observed slapper animation"
    end
    return nil,"waiting for clear slapper evidence"
end
local function tryGuess()
    if not S.alive or not S.options.guess or not S.guessActive or S.guessSent then return end
    local name,reason=chooseCandidate(S.candidates,S.revealed,S.evidence,S.round,os.clock())
    if not name then log("Auto Guess: "..reason); return end
    if not Players:FindFirstChild(name) then return end
    S.guessSent=true
    Remotes.Guess:FireServer(name)
    S.stats.guesses+=1
    S.lastGuess={name=name,reason=reason}
    log("Guess sent: "..name.." • "..reason)
end
local function submitSlap()
    if not S.options.slap or not S.slapActive or S.slapSent then return end
    local target=S.slapTarget
    if type(target)~="number" or target~=target or target<0 or target>1 then return end
    S.slapSent=true
    Remotes.Slap:FireServer(target)
    S.stats.slaps+=1
    log("Perfect slap target submitted")
end
local function startSlap()
    if not S.alive or not S.options.slap or not S.slapAvailable or S.slapActive or S.slapStarted then return end
    S.slapStarted=true
    Remotes.Slap:FireServer()
    log("Slap meter started")
end
local function scheduleSlap()
    local epoch=S.slapEpoch
    task.delay(S.slapDelay,function()
        if S.alive and epoch==S.slapEpoch then submitSlap() end
    end)
end
local function submitDodge()
    if not S.options.dodge or not S.dodgeActive or S.dodgeSent then return end
    if os.clock()-S.dodgeStarted>0.48 then return end
    S.dodgeSent=true
    Remotes.Dodge:FireServer()
    S.stats.dodges+=1
    log("Dodge submitted")
end
local function scheduleDodge()
    local epoch=S.dodgeEpoch
    task.delay(S.dodgeDelay,function()
        if S.alive and epoch==S.dodgeEpoch then submitDodge() end
    end)
end
S.toggles={}
for _,item in {
    {key="slap",name="Auto Perfect Slap",description="Submits the exact target received for your turn."},
    {key="dodge",name="Auto Dodge",description="Responds once per dodge prompt."},
    {key="guess",name="Auto Guess",description="Uses slapper evidence; waits when the answer is unclear."},
} do
    S.toggles[item.key]=tab:CreateToggle({name=item.name,description=item.description,value=true,callback=function(v)
        S.options[item.key]=v
        if v then
            if item.key=="slap" then scheduleSlap() elseif item.key=="dodge" then scheduleDodge() else tryGuess() end
        end
    end})
end
local statsText=tab:CreateText({name="Session results",text="Waiting for server results."})
tab:CreateButton({name="Stop all",callback=function()
    for _,t in S.toggles do t:Set(false) end
    log("All automation stopped")
end})
local settings=window:CreateTab({name="Timing & details"})
settings:CreateSlider({name="Dodge delay",range={0,250},increment=5,value=100,suffix=" ms",callback=function(v) S.dodgeDelay=v/1000 end})
settings:CreateSlider({name="Slap delay",range={50,500},increment=10,value=120,suffix=" ms",callback=function(v) S.slapDelay=v/1000 end})
settings:CreateText({name="Accuracy",text="Slap uses the exact target. Dodge still depends on server timing and latency. Guess uses observed animations or a reveal, and skips uncertain answers. Counters distinguish sent actions from confirmed outcomes."})
settings:CreateButton({name="Unload",callback=function() S:Unload() end})

local function onEvent(action,a,b)
    if action=="SetCamera" then
        if a=="Sitting" then
            resetRound(); S.sitting=true
        elseif a=="Slap" then
            S.sitting=false
        elseif a==nil or a==false then
            S.sitting=false; resetRound()
            S.slapActive=false; S.dodgeActive=false
            S.slapEpoch+=1; S.dodgeEpoch+=1
        end
    elseif action=="Slider" then
        S.slapEpoch+=1; S.slapActive=a==true; S.slapSent=false; S.slapTarget=b
        if S.slapActive then scheduleSlap() end
    elseif action=="SlapUpdate" then
        S.slapAvailable=a==true
        if S.slapAvailable then
            S.slapStarted=false
            startSlap()
        else
            S.slapStarted=false
        end
    elseif action=="SliderFinish" then
        S.slapActive=false; S.slapEpoch+=1; S.lastAccuracy=b
        if type(b)=="number" then
            if b>=0.999999 then S.stats.perfect+=1 end
            log(string.format("Server slap result: %.2f%%",b*100))
        end
    elseif action=="CloseSlider" then
        S.slapActive=false; S.slapEpoch+=1
    elseif action=="Dodge" then
        if a==true then
            freezeEvidence()
            S.dodgeEpoch+=1; S.dodgeActive=true; S.dodgeSent=false; S.dodgeStarted=os.clock()
            scheduleDodge()
        elseif a==false then
            if S.dodgeSent then
                if b then S.stats.dodgeSuccess+=1 else S.stats.dodgeFailure+=1 end
                log(b and "Server confirmed dodge" or "Server reported failed dodge")
            end
            S.dodgeEpoch+=1; S.dodgeActive=false
        end
    elseif action=="Concuss" then
        freezeEvidence()
    elseif action=="SlapSFX" then
        if typeof(b)=="Instance" and LocalPlayer.Character and b:IsDescendantOf(LocalPlayer.Character) then freezeEvidence() end
    elseif action=="Guess" and type(a)=="table" then
        freezeEvidence()
        S.guessEpoch+=1; S.guessActive=true; S.guessSent=false; S.candidates={}
        for _,character in a do
            if typeof(character)=="Instance" then
                local p=Players:GetPlayerFromCharacter(character)
                if p and p~=LocalPlayer then S.candidates[p.Name]=true end
            end
        end
        tryGuess()
    elseif action=="RevealSlapper" then
        S.revealed=tostring(a)
        local p=Players:FindFirstChild(S.revealed)
        if not p then
            for _,candidate in Players:GetPlayers() do
                if tostring(candidate.UserId)==S.revealed then S.revealed=candidate.Name; break end
            end
        end
        tryGuess()
    elseif action=="CloseGuess" then
        S.guessActive=false; S.guessEpoch+=1; S.revealed=nil; S.evidence=nil; S.observations={}
    elseif action=="QueueUpdate" and a==false then
        S.sitting=false; resetRound()
        S.slapActive=false; S.dodgeActive=false; S.slapEpoch+=1; S.dodgeEpoch+=1
    end
end
for _,remote in Remotes:GetChildren() do
    if remote:IsA("RemoteEvent") then connect(remote.OnClientEvent,onEvent) end
end
connect(LocalPlayer.CharacterAdded,function()
    resetRound(); S.sitting=false; S.slapActive=false; S.dodgeActive=false
    S.slapEpoch+=1; S.dodgeEpoch+=1; log("Respawned — waiting for a new turn")
end)
connect(Players.PlayerRemoving,function(p)
    S.candidates[p.Name]=nil
    -- Do not infer a new answer after a candidate leaves; wait for a new prompt.
end)
connect(RunService.Heartbeat,function()
    if window.unloaded then S:Unload(); return end
    local now=os.clock()
    if now-S.lastSample>=0.03 then
        S.lastSample=now; sampleSlapper()
    end
    if now-S.lastUI>=0.3 then
        S.lastUI=now
        status:Set(S.status)
        local n=S.stats
        statsText:Set(string.format("Slap: %d sent / %d confirmed 100%%\nDodge: %d sent / %d confirmed / %d failed\nGuess: %d sent",n.slaps,n.perfect,n.dodges,n.dodgeSuccess,n.dodgeFailure,n.guesses))
    end
end)

-- Read-only recovery when loaded midway through a turn. No guessed upvalue indices.
if type(filtergc)=="function" and debug.getupvalues then
    local matches=filtergc("table",{Keys={"Guess","Dodge","Slider","SetCamera","SlapSFX"}},false)
    for _,handlers in matches do
        local source=debug.info(handlers.Guess,"s") or ""
        if source:find("This is where i do all the front end stuff lol",1,true) then
            S.handlers=handlers
            for _,value in debug.getupvalues(handlers.Slider) do
                if type(value)=="boolean" then S.slapActive=value
                elseif type(value)=="number" then S.slapTarget=value end
            end
            if S.slapActive then scheduleSlap() end
            break
        end
    end
end
local f=frames()
if f then
    local gui=LocalPlayer.PlayerGui:FindFirstChild("UI")
    local buttons=gui and gui:FindFirstChild("Buttons")
    local slapButton=buttons and buttons:FindFirstChild("Slap")
    if slapButton and slapButton.Visible then S.slapAvailable=true; startSlap() end
    local guess=f:FindFirstChild("Guess")
    if guess and guess.Visible then
        S.guessActive=true
        for _,cell in guess.List:GetChildren() do
            if cell:IsA("Frame") and Players:FindFirstChild(cell.Name) and cell.Name~=LocalPlayer.Name then S.candidates[cell.Name]=true end
        end
        tryGuess()
    end
end
-- Pure decision tests; these do not send remotes or change the game.
function S:SelfTest()
    local passed=0
    local function check(expected,...)
        local actual=chooseCandidate(...)
        assert(actual==expected,"Guess selection test failed")
        passed+=1
    end
    check("A",{A=true},nil,nil,1,10)
    check(nil,{A=true,B=true},nil,nil,1,10)
    check("B",{A=true,B=true},"B",nil,1,10)
    check("A",{A=true,B=true},nil,{name="A",round=1,time=9},1,10)
    check(nil,{A=true,B=true},nil,{name="A",round=0,time=9},1,10)
    check(nil,{A=true,B=true},nil,{name="A",round=1,time=0},1,20)
    check(nil,{A=true,B=true},nil,{name="C",round=1,time=9},1,10)
    check(nil,{},nil,nil,1,10)
    return {passed=passed,total=8}
end
S.ready=true
window:Notify({title="Guess & Slap ready",content="All three controls are enabled. Enter a round to use them."})

