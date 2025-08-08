----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------
local Config = {
  ATMModels = { `prop_atm_01`, `prop_atm_02`, `prop_atm_03`, `prop_fleeca_atm` },
  UseKey     = 38,    -- E
  PromptDist = 3.0,
  BlipDist   = 50.0,
  Blip = { sprite=108, color=2, scale=0.8, text="Bank ATM" }
}

----------------------------------------------------------------
-- NUI / banking logic
----------------------------------------------------------------
local nuiOpen = false
RegisterCommand("bank", function()
  if not nuiOpen then
    nuiOpen=true; SetNuiFocus(true,true)
    SendNUIMessage({action='show'})
    SendNUIMessage({action='refreshData'})
  end
end,false)

Citizen.CreateThread(function()
  while true do
    Citizen.Wait(0)
    if nuiOpen and IsControlJustReleased(0,322) then
      nuiOpen=false; SetNuiFocus(false,false); SendNUIMessage({action='hide'})
    end
  end
end)

-- NUI → client → server for internal transfers
RegisterNUICallback('transferInternal', function(data, cb)
  print("^5[bank-ui]^7 transferInternal NUI callback fired! from="..data.from.." to="..data.to.." amt="..data.amount)
  TriggerServerEvent('my-bank-ui:transferInternal', data)
  cb({})

  -- force a fresh pull once the server has had time to do its work
  Citizen.SetTimeout(250, function()
    print("^5[bank-ui]^7 calling refreshData after internal transfer")
    SendNUIMessage({ action = 'refreshData' })
  end)
end)


RegisterNUICallback('close', function(_,cb)
  nuiOpen=false; SetNuiFocus(false,false); SendNUIMessage({action='hide'}); cb({})
end)

-- existing callbacks
for _,evt in ipairs({'getData','deposit','withdraw','transfer','addPayment'}) do
  RegisterNUICallback(evt, function(data,cb)
    TriggerServerEvent('my-bank-ui:'..evt, data); cb({})
  end)
end

-- NEW: forward profile updates
RegisterNUICallback('updateProfile', function(data,cb)
  TriggerServerEvent('my-bank-ui:updateProfile', data)
  cb({})
end)

RegisterNetEvent('my-bank-ui:updateData')
AddEventHandler('my-bank-ui:updateData', function(d)
  SendNUIMessage({action='setData', data=d})
end)

----------------------------------------------------------------
-- ATM BLIP & “[E] Use Bank” PROMPT
----------------------------------------------------------------
local atmEntities, atmBlips = {}, {}
local function DrawText3D(x,y,z,txt)
  local onScreen,sx,sy=World3dToScreen2d(x,y,z)
  if onScreen then
    SetTextScale(0.35,0.35); SetTextFont(4); SetTextCentre(true)
    SetTextEntry("STRING"); AddTextComponentString(txt); DrawText(sx,sy)
    DrawRect(sx,sy+0.0125,#txt/370,0.03,0,0,0,125)
  end
end

Citizen.CreateThread(function()
  while true do
    Citizen.Wait(2000)
    atmEntities={}
    local handle,obj=FindFirstObject(); local success=true
    repeat
      local m=GetEntityModel(obj)
      for _,mm in ipairs(Config.ATMModels) do if m==mm then atmEntities[obj]=true end end
      success,obj=FindNextObject(handle)
    until not success
    EndFindObject(handle)
  end
end)

Citizen.CreateThread(function()
  while true do
    Citizen.Wait(0)
    local pPed=PlayerPedId(); local pCoords=GetEntityCoords(pPed)
    for obj,_ in pairs(atmEntities) do
      if DoesEntityExist(obj) then
        local oCoords=GetEntityCoords(obj); local dist=#(pCoords-oCoords)
        if dist<=Config.BlipDist and not atmBlips[obj] then
          local b=AddBlipForCoord(oCoords.x,oCoords.y,oCoords.z)
          SetBlipSprite(b,Config.Blip.sprite); SetBlipColour(b,Config.Blip.color)
          SetBlipScale(b,Config.Blip.scale)
          BeginTextCommandSetBlipName("STRING")
            AddTextComponentString(Config.Blip.text)
          EndTextCommandSetBlipName(b)
          atmBlips[obj]=b
        elseif dist>Config.BlipDist and atmBlips[obj] then
          RemoveBlip(atmBlips[obj]); atmBlips[obj]=nil
        end
        if dist<=Config.PromptDist then
          DrawText3D(oCoords.x,oCoords.y,oCoords.z+1.0,"[E] Use Bank")
          if IsControlJustReleased(0,Config.UseKey) then ExecuteCommand("bank") end
        end
      end
    end
  end
end)




-- client.lua

-- Toggle and effect state
local underglowOn = false
local effectThread = nil

-- Neon light indexes: left, right, front, back
local neonIndexes = {0, 1, 2, 3}

-- Normalize raw color strings to six-digit hex (no prefix)
local function normalizeHex(raw)
    local clean = raw:gsub('[^%x]', '')
    if #clean == 3 then
        clean = clean:sub(1,1):rep(2)
               .. clean:sub(2,2):rep(2)
               .. clean:sub(3,3):rep(2)
    end
    if #clean > 6 then
        clean = clean:sub(1, 6)
    elseif #clean < 6 then
        clean = string.rep('0', 6 - #clean) .. clean
    end
    return clean
end

-- Convert HSV (0–360, 0–1, 0–1) to RGB (0–1)
local function hsvToRgb(h, s, v)
    local c = v * s
    local x = c * (1 - math.abs((h / 60) % 2 - 1))
    local m = v - c
    local r1, g1, b1
    if h < 60 then r1, g1, b1 = c, x, 0
    elseif h < 120 then r1, g1, b1 = x, c, 0
    elseif h < 180 then r1, g1, b1 = 0, c, x
    elseif h < 240 then r1, g1, b1 = 0, x, c
    elseif h < 300 then r1, g1, b1 = x, 0, c
    else r1, g1, b1 = c, 0, x end
    return r1 + m, g1 + m, b1 + m
end

-- Apply neon lights on all sides with given RGB and enabled state
local function applyNeon(vehicle, r, g, b, enabled, indexes)
    indexes = indexes or neonIndexes
    for _, idx in ipairs(indexes) do
        SetVehicleNeonLightEnabled(vehicle, idx, enabled)
    end
    if enabled then
        SetVehicleNeonLightsColour(vehicle, r, g, b)
    end
end

-- Smooth RGB cycle effect (hue rotation)
local function smoothCycle(vehicle, speed)
    local hue = 0
    while underglowOn do
        local r1, g1, b1 = hsvToRgb(hue % 360, 1, 1)
        applyNeon(vehicle,
            math.floor(r1 * 255),
            math.floor(g1 * 255),
            math.floor(b1 * 255),
            true
        )
        hue = hue + speed
        Wait(50)
    end
end

-- Strobe (blink) effect
local function strobeEffect(vehicle, r, g, b, interval)
    while underglowOn do
        applyNeon(vehicle, r, g, b, true)
        Wait(interval)
        applyNeon(vehicle, r, g, b, false)
        Wait(interval)
    end
end

-- Police pattern: red & blue alternating
local function policeEffect(vehicle, interval)
    local red = {255,1,1}
    local blue = {3,83,255}
    local toggle = true
    while underglowOn do
        if toggle then
            applyNeon(vehicle, red[1], red[2], red[3], true, {0,3}) -- left/back red
            applyNeon(vehicle, blue[1], blue[2], blue[3], true, {1,2}) -- right/front blue
        else
            applyNeon(vehicle, blue[1], blue[2], blue[3], true, {0,3})
            applyNeon(vehicle, red[1], red[2], red[3], true, {1,2})
        end
        toggle = not toggle
        Wait(interval)
    end
end

-- Circular chase effect
local function circleEffect(vehicle, r, g, b, interval)
    local count = #neonIndexes
    local idx = 1
    while underglowOn do
        -- clear all
        applyNeon(vehicle, r, g, b, false)
        -- light current
        applyNeon(vehicle, r, g, b, true, {neonIndexes[idx]})
        idx = idx % count + 1
        Wait(interval)
    end
end

-- Open the underglow settings menu
local function openUnderglowMenu()
    local input = lib.inputDialog('Underglow Settings', {
        { type = 'color',  label = 'Choose Color', default = '#ff0000', format = 'hex' },
        { type = 'select', label = 'Effect', options = {
            { value = 'static', label = 'Static' },
            { value = 'smooth', label = 'RGB Smooth' },
            { value = 'strobe', label = 'Strobe' },
            { value = 'police', label = 'Police Red/Blue' },
            { value = 'circle', label = 'Circle Chase' }
        }, default = 'static' },
        { type = 'number', label = 'Speed (1-100)', default = 50, min = 1, max = 100, step = 1 }
    }, { allowCancel = true })

    if not input then return end

    local rawHex = input[1]
    local cleanHex = normalizeHex(rawHex)
    local r = tonumber(cleanHex:sub(1,2), 16) or 0
    local g = tonumber(cleanHex:sub(3,4), 16) or 0
    local b = tonumber(cleanHex:sub(5,6), 16) or 0

    local effect = input[2]
    local speed  = input[3]
    local interval = math.floor(1000 / speed)

    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then
        return lib.notify({ title = 'No Vehicle', description = 'You must be in a vehicle to toggle underglow.', type = 'error', position = 'top' })
    end

    if underglowOn then
        underglowOn = false
        if effectThread then effectThread = nil end
        applyNeon(veh, 0, 0, 0, false)
        return lib.notify({ title = 'Underglow Disabled', type = 'inform' })
    end

    underglowOn = true
    applyNeon(veh, r, g, b, true)

    -- Start chosen effect
    if effect == 'smooth' then
        effectThread = CreateThread(function() smoothCycle(veh, speed / 2) end)
    elseif effect == 'strobe' then
        effectThread = CreateThread(function() strobeEffect(veh, r, g, b, interval) end)
    elseif effect == 'police' then
        effectThread = CreateThread(function() policeEffect(veh, interval) end)
    elseif effect == 'circle' then
        effectThread = CreateThread(function() circleEffect(veh, r, g, b, interval) end)
    end

    lib.notify({ title = 'Underglow Enabled', description = ('%s @ %d'):format(effect, speed), type = 'success' })
end

-- Register the /underglow command
RegisterCommand('underglow', function() openUnderglowMenu() end, false)

-- Cleanup neon on resource stop
AddEventHandler('onClientResourceStop', function(resName)
    if resName == GetCurrentResourceName() then
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 then applyNeon(veh, 0, 0, 0, false) end
    end
end)
