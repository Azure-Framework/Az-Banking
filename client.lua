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
