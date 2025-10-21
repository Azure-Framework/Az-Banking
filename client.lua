-- client.lua
-- Bank UI + ATM scanning + ATM robbery (glitch-minigames or ox_lib fallback)
-- Requires: oxmysql for DB interactions server-side, Az-Framework (for addMoney), optional glitch-minigames / ox_lib (lib.skillCheck)

-- CONFIG
local Config = {
  ATMModels = { `prop_atm_01`, `prop_atm_02`, `prop_atm_03`, `prop_fleeca_atm` },
  UseKey     = 38,    -- E
  PromptDist = 3.0,
  BlipDist   = 50.0,
  Blip = { sprite=108, color=2, scale=0.8, text="Bank ATM" },

  -- ATM Robbery fallback minigame settings
  GlitchCircuitParams = {2, 1, 1000, 3000, 3000, 0, 10000, 3000, 30000}, -- params passed into StartCircuitBreaker
  -- <<-- EASIER skill-check sequence: easy preset + custom (large area, slower) -->>
  SkillCheckSeq = {'easy', { areaSize = 80, speedMultiplier = 0.8 }},
  SkillCheckInputs = {'e'},

  -- ATM robbery settings
  atmRobberyCooldown = 600, -- seconds
  atmMinReward = 500,
  atmMaxReward = 3000,
  RobKey = 74, -- H
  TextScale = 0.60
}

-- NUI / banking state
local nuiOpen = false

-- ATM entities / blips
local atmEntities = {}
local atmBlips = {}

-- atm closed states (key -> expiryTime seconds in client time, i.e. GetGameTimer()/1000 + remaining)
local atmStates = {}

-- Utility: DrawText3D with optional scale
function DrawText3D(x, y, z, text, scale)
  scale = scale or 0.35
  SetTextScale(scale, scale)
  SetTextFont(4)
  SetTextProportional(1)
  SetTextColour(255, 255, 255, 215)
  SetTextCentre(true)
  SetTextEntry('STRING')
  AddTextComponentString(text)
  SetDrawOrigin(x, y, z, 0)
  DrawText(0.0, 0.0)
  ClearDrawOrigin()
end

-- Helper for screen-space 3D hints (used by older bank code)
local function DrawText3DScreen(x,y,z,txt)
  local onScreen,sx,sy=World3dToScreen2d(x,y,z)
  if onScreen then
    SetTextScale(0.35,0.35); SetTextFont(4); SetTextCentre(true)
    SetTextEntry("STRING"); AddTextComponentString(txt); DrawText(sx,sy)
    DrawRect(sx,sy+0.0125,#txt/370,0.03,0,0,0,125)
  end
end

-- Convert vector coords to a simple key
local function coordsToKey(v)
  return string.format("%.1f:%.1f:%.1f", v.x, v.y, v.z)
end

-- small notification helper
local function shortNotify(text)
  SetNotificationTextEntry("STRING")
  AddTextComponentString(text)
  DrawNotification(false,false)
end

-- BANK NUI: open/close + callbacks ------------------------------------------------
RegisterCommand("bank", function()
  if not nuiOpen then
    nuiOpen=true; SetNuiFocus(true,true)
    SendNUIMessage({action='show'})
    SendNUIMessage({action='refreshData'})
  end
end, false)

RegisterNUICallback('close', function(_,cb)
  nuiOpen=false; SetNuiFocus(false,false); SendNUIMessage({action='hide'}); cb({})
end)

-- forward simple bank RPCs to server
for _,evt in ipairs({'getData','deposit','withdraw','transfer','addPayment'}) do
  RegisterNUICallback(evt, function(data,cb)
    TriggerServerEvent('my-bank-ui:'..evt, data); cb({}) 
  end)
end

RegisterNUICallback('transferInternal', function(data, cb)
  TriggerServerEvent('my-bank-ui:transferInternal', data)
  cb({})
  Citizen.SetTimeout(250, function() SendNUIMessage({ action = 'refreshData' }) end)
end)

RegisterNUICallback('updateProfile', function(data,cb)
  TriggerServerEvent('my-bank-ui:updateProfile', data)
  cb({})
end)

-- only one updateData handler — sends payload to NUI
RegisterNetEvent('my-bank-ui:updateData')
AddEventHandler('my-bank-ui:updateData', function(d)
  SendNUIMessage({action='setData', data=d})
end)

-- ATM detection: scan objects periodically and store any that match ATMModels ----
Citizen.CreateThread(function()
  while true do
    Citizen.Wait(2000)
    atmEntities = {}
    local handle, obj = FindFirstObject()
    local success = true
    repeat
      if DoesEntityExist(obj) then
        local m = GetEntityModel(obj)
        for _, mm in ipairs(Config.ATMModels) do
          if m == mm then
            atmEntities[obj] = true
            break
          end
        end
      end
      success, obj = FindNextObject(handle)
    until not success
    EndFindObject(handle)
  end
end)

-- create/remove blips and draw prompts in main loop -------------------------------
Citizen.CreateThread(function()
  while true do
    Citizen.Wait(0)
    local pPed = PlayerPedId()
    local pCoords = GetEntityCoords(pPed)
    local nowSec = math.floor(GetGameTimer() / 1000)
    for obj,_ in pairs(atmEntities) do
      if DoesEntityExist(obj) then
        local oCoords = GetEntityCoords(obj)
        local dist = #(pCoords - oCoords)
        -- blip management
        if dist <= Config.BlipDist and not atmBlips[obj] then
          local b = AddBlipForCoord(oCoords.x, oCoords.y, oCoords.z)
          SetBlipSprite(b, Config.Blip.sprite); SetBlipColour(b, Config.Blip.color)
          SetBlipScale(b, Config.Blip.scale)
          BeginTextCommandSetBlipName("STRING"); AddTextComponentString(Config.Blip.text); EndTextCommandSetBlipName(b)
          atmBlips[obj] = b
        elseif dist > Config.BlipDist and atmBlips[obj] then
          RemoveBlip(atmBlips[obj]); atmBlips[obj] = nil
        end

        -- prompt / interaction
        if dist <= Config.PromptDist then
          local key = coordsToKey(oCoords)
          local expiry = atmStates[key] -- expiry is client-time (GetGameTimer()/1000) + remaining
          if expiry and expiry > nowSec then
            local remaining = math.max(0, expiry - nowSec)
            local mins = math.floor(remaining/60); local secs = remaining % 60
            DrawText3D(oCoords.x, oCoords.y, oCoords.z+1.0, ('~r~This atm is Closed - %02d:%02d'):format(mins, secs), 0.5)
          else
            -- show larger prompt (Open bank / Rob ATM)
            DrawText3D(oCoords.x, oCoords.y, oCoords.z+1.0, "[~g~E~w~] Use ATM    [~r~H~w~] Rob ATM", Config.TextScale)
            -- open bank NUI
            if IsControlJustReleased(0, Config.UseKey) then
              ExecuteCommand("bank")
            end
            -- attempt robbery with H
            if IsControlJustReleased(0, Config.RobKey) then
              -- optional: local checks (weapon, not in vehicle, etc.) could go here
              attemptAtmRobbery(oCoords, pCoords)
            end
          end
        end
      end
    end
  end
end)

-- ATM minigame runner: try glitch-minigames first, else fall back to lib.skillCheck
function attemptAtmRobbery(atmCoords, playerCoords)
  if not atmCoords then return end

  -- find resource state for glitch-minigames
  local gmState = GetResourceState and GetResourceState('glitch-minigames') or nil
  if gmState == 'started' then
    local ok, result = pcall(function()
      return exports['glitch-minigames']:StartCircuitBreaker(table.unpack(Config.GlitchCircuitParams))
    end)
    if ok and result then
      TriggerServerEvent('atm:attemptRob', coordsToKey(atmCoords), atmCoords, playerCoords)
      shortNotify("ATM breach succeeded!")
    else
      shortNotify("ATM breach failed.")
    end
    return
  end

  -- fallback: lib.skillCheck (ox_lib)
  local ok, callOk = pcall(function()
    if type(lib) == 'table' and lib.skillCheck then
      -- use the easier skill-check sequence from Config
      return lib.skillCheck(Config.SkillCheckSeq, Config.SkillCheckInputs)
    end
    return false
  end)

  if ok and callOk then
    TriggerServerEvent('atm:attemptRob', coordsToKey(atmCoords), atmCoords, playerCoords)
    shortNotify("ATM breach succeeded!")
  else
    shortNotify("No minigame available (glitch-minigames / ox_lib missing) or skill check failed.")
  end
end

-- client.lua: add this handler to show blip + nicer notification for police players
RegisterNetEvent('dispatch:atmRobbery')
AddEventHandler('dispatch:atmRobbery', function(payload)
  if not payload or not payload.coords then return end

  local x, y, z = payload.coords.x or 0.0, payload.coords.y or 0.0, payload.coords.z or 0.0
  local duration = tonumber(payload.blipDuration) or 20
  local reward = tonumber(payload.reward) or 0

  -- create blip
  local b = AddBlipForCoord(x, y, z)
  SetBlipSprite(b, 161)             -- choose police-related sprite
  SetBlipColour(b, 3)              -- color (tweak if you want)
  SetBlipScale(b, 1.0)
  SetBlipAsShortRange(b, false)
  BeginTextCommandSetBlipName("STRING"); AddTextComponentString("ATM Robbery"); EndTextCommandSetBlipName(b)
  SetBlipFlashes(b, true)
  SetBlipFlashInterval(b, 250)

  -- optional: create a route on the map (uncomment if you want)
  -- SetNewWaypoint(x, y)

  -- remove blip after duration seconds
  Citizen.SetTimeout(duration * 1000, function()
    if DoesBlipExist(b) then RemoveBlip(b) end
  end)

  -- nicer notification (uses DrawNotification fallback)
  local locText = ("%.1f, %.1f"):format(x, y)
  local msg = ("~r~ATM ROBBERY ~s~| ~y~Location: ~s~%s ~s~| ~g~Reward: $%d"):format(locText, reward)

  -- Show the notification on screen
  SetNotificationTextEntry("STRING")
  AddTextComponentString(msg)
  DrawNotification(false, false)

  -- also show a short chat message (so people who have chat visible see it)
  TriggerEvent('chat:addMessage', {
    color = { 255, 170, 0},
    multiline = false,
    args = { "DISPATCH", ("ATM Robbery — Location: %s — Reward: $%d"):format(locText, reward) }
  })
end)


-- listen for ATM closed updates from server
RegisterNetEvent('atm:closedStatus')
AddEventHandler('atm:closedStatus', function(atmKey, remainingSeconds)
  if not atmKey then return end
  if remainingSeconds and remainingSeconds > 0 then
    -- store client-side expiry based on game timer
    local expiry = math.floor(GetGameTimer() / 1000) + math.floor(remainingSeconds)
    atmStates[atmKey] = expiry
  else
    atmStates[atmKey] = nil
  end
end)

-- on resource start refresh bank UI state
AddEventHandler('onClientResourceStart', function(res)
  if GetCurrentResourceName() == res then
    TriggerServerEvent('my-bank-ui:getData')
  end
end)


-- add setPin & verifyPin to the NUI forward list
for _,evt in ipairs({'getData','deposit','withdraw','transfer','addPayment','setPin','verifyPin'}) do
  RegisterNUICallback(evt, function(data,cb)
    TriggerServerEvent('my-bank-ui:'..evt, data)
    cb({})
  end)
end

-- existing callbacks preserved (transferInternal, updateProfile etc.)

-- forward server-side pin events to the NUI
RegisterNetEvent('my-bank-ui:pinVerified')
AddEventHandler('my-bank-ui:pinVerified', function(success, message)
  SendNUIMessage({ action = 'pinResult', success = success or false, message = message or "" })
end)

RegisterNetEvent('my-bank-ui:pinSet')
AddEventHandler('my-bank-ui:pinSet', function(success, message)
  SendNUIMessage({ action = 'pinSetResult', success = success or false, message = message or "" })
end)

-- existing UpdateData handler (keeps sending setData to NUI)
AddEventHandler('my-bank-ui:updateData', function(d)
  SendNUIMessage({action='setData', data=d})
end)

-- on resource start, request data as before
AddEventHandler('onClientResourceStart', function(res)
  if GetCurrentResourceName() == res then
    TriggerServerEvent('my-bank-ui:getData')
  end
end)