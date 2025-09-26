local M = {
  money = 'econ_user_money',
  accts = 'econ_accounts',
  pays  = 'econ_payments',
  cards = 'econ_cards',
  dept  = 'econ_departments'
}
local SAVINGS_APR = 0.05


local function getDiscordID(src)
  for _, id in ipairs(GetPlayerIdentifiers(src)) do
    if id:sub(1,8) == 'discord:' then
      return id:sub(9)
    end
  end
  
  local ids = GetPlayerIdentifiers(src)
  return ids and ids[1] or ''
end


local function getCharID(src)
  local cid = nil
  
  if exports['Az-Framework'] and exports['Az-Framework'].GetPlayerCharacter then
    cid = exports['Az-Framework']:GetPlayerCharacter(src)
  end
  
  if not cid or cid == '' then
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
      if id and id:match('^%d+$') then
        cid = id
        break
      end
    end
  end
  return cid and tostring(cid) or ''
end


AddEventHandler('onResourceStart', function(resourceName)
  if GetCurrentResourceName() ~= resourceName then return end

  
  exports.oxmysql:execute(string.format([[
    CREATE TABLE IF NOT EXISTS `%s` (
      `discordid` varchar(64) DEFAULT '',
      `charid` varchar(100) NOT NULL,
      `firstname` varchar(100) NOT NULL DEFAULT '',
      `lastname` varchar(100) NOT NULL DEFAULT '',
      `profile_picture` varchar(255) DEFAULT NULL,
      `cash` BIGINT NOT NULL DEFAULT 0,
      `bank` BIGINT NOT NULL DEFAULT 0,
      `last_daily` BIGINT NOT NULL DEFAULT 0,
      `card_number` varchar(16) DEFAULT NULL,
      `exp_month` tinyint(4) DEFAULT NULL,
      `exp_year` smallint(6) DEFAULT NULL,
      `card_status` varchar(16) NOT NULL DEFAULT 'active',
      KEY (charid)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]
    , M.money))

  
  exports.oxmysql:execute(string.format([[
    CREATE TABLE IF NOT EXISTS `%s` (
      `id` INT AUTO_INCREMENT PRIMARY KEY,
      `discordid` VARCHAR(64) DEFAULT '',
      `charid` VARCHAR(100) DEFAULT '',
      `type` ENUM('checking','savings') NOT NULL,
      `balance` BIGINT NOT NULL DEFAULT 0,
      INDEX (charid)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]
    , M.accts))

  
  exports.oxmysql:execute(string.format([[
    CREATE TABLE IF NOT EXISTS `%s` (
      `id` INT AUTO_INCREMENT PRIMARY KEY,
      `discordid` VARCHAR(64) DEFAULT '',
      `charid` VARCHAR(100) DEFAULT '',
      `payee` VARCHAR(64) NOT NULL,
      `amount` BIGINT NOT NULL,
      `schedule_date` DATETIME NOT NULL,
      INDEX (charid)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]
    , M.pays))

  
  exports.oxmysql:execute(string.format([[
    CREATE TABLE IF NOT EXISTS `%s` (
      `id` INT AUTO_INCREMENT PRIMARY KEY,
      `discordid` VARCHAR(64) DEFAULT '',
      `charid` VARCHAR(100) DEFAULT '',
      `card_number` VARCHAR(16) NOT NULL,
      `exp_month` INT NOT NULL,
      `exp_year` INT NOT NULL,
      `status` VARCHAR(16) NOT NULL,
      INDEX (charid)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]
    , M.cards))

  
  exports.oxmysql:execute(string.format([[
    CREATE TABLE IF NOT EXISTS `%s` (
      `discordid` VARCHAR(64) DEFAULT '',
      `charid` VARCHAR(100) DEFAULT '',
      `paycheck` BIGINT NOT NULL DEFAULT 0,
      PRIMARY KEY (charid)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]
    , M.dept))

  print("^2[econ]^0 Tables ensured (discordid+charid aware).")
end)


local function fetchMoney(did, cid, cb)
  if not cid or cid == '' then return cb(nil) end
  exports.oxmysql:query(
    string.format("SELECT * FROM `%s` WHERE charid = ? LIMIT 1", M.money),
    { cid },
    function(res)
      if res and res[1] then
        
        if did and did ~= '' and res[1].discordid ~= did then
          exports.oxmysql:execute(
            string.format("UPDATE `%s` SET discordid = ? WHERE charid = ?", M.money),
            { did, cid }
          )
        end
        cb(res[1])
      else
        
        exports.oxmysql:insert(
          string.format("INSERT INTO `%s` (discordid,charid,cash,bank,profile_picture,firstname,lastname,card_status) VALUES (?,?,?,?,?,?,?,?)", M.money),
          { did or '', cid, 0, 0, '', '', '', 'active' },
          function() fetchMoney(did, cid, cb) end
        )
      end
    end
  )
end


local function fetchAccounts(did, cid, cb)
  if not cid or cid == '' then return cb({}) end
  exports.oxmysql:query(
    string.format("SELECT id,discordid,charid,type,balance FROM `%s` WHERE charid = ? OR discordid = ? ORDER BY id", M.accts),
    { cid, did or cid },
    function(accts)
      if #accts == 0 then
        exports.oxmysql:insert(
          string.format("INSERT INTO `%s` (discordid,charid,type,balance) VALUES (?,?,?,?),(?,?,?,?)", M.accts),
          { did or '', cid, 'checking', 0, did or '', cid, 'savings', 0 },
          function() fetchAccounts(did, cid, cb) end
        )
      else
        
        for _, acct in ipairs(accts) do
          if (not acct.discordid or acct.discordid == '') and did and did ~= '' then
            exports.oxmysql:execute(
              string.format("UPDATE `%s` SET discordid = ? WHERE id = ?", M.accts),
              { did, acct.id }
            )
          end
          if acct.type == 'savings' then
            local rate = SAVINGS_APR / 365
            acct.apr = SAVINGS_APR
            acct.daily_interest = tonumber(acct.balance) * rate
          end
        end
        cb(accts)
      end
    end
  )
end


local function fetchCards(did, cid, cb)
  if not cid or cid == '' then return cb({}) end
  exports.oxmysql:query(
    string.format("SELECT * FROM `%s` WHERE charid = ? OR discordid = ? LIMIT 1", M.cards),
    { cid, did or cid },
    function(cards)
      if #cards == 0 then
        local num   = tostring(math.random(4000,4999))
                      .. tostring(math.random(1000,9999))
                      .. tostring(math.random(1000,9999))
                      .. tostring(math.random(1000,9999))
        local month = math.random(1,12)
        local year  = tonumber(os.date("%Y")) + 3
        local status = 'active'
        exports.oxmysql:insert(
          string.format("INSERT INTO `%s` (discordid,charid,card_number,exp_month,exp_year,status) VALUES (?,?,?,?,?,?)", M.cards),
          { did or '', cid, num, month, year, status },
          function()
            
            exports.oxmysql:execute(
              string.format("UPDATE `%s` SET card_number=?,exp_month=?,exp_year=?,card_status=?,discordid=? WHERE charid=?", M.money),
              { num, month, year, status, did or '', cid },
              function() cb({{card_number=num,exp_month=month,exp_year=year,status=status}}) end
            )
          end
        )
      else
        local c = cards[1]
        
        if (not c.discordid or c.discordid == '') and did and did ~= '' then
          exports.oxmysql:execute(
            string.format("UPDATE `%s` SET discordid = ? WHERE id = ?", M.cards),
            { did, c.id }
          )
          exports.oxmysql:execute(
            string.format("UPDATE `%s` SET discordid = ? WHERE charid = ?", M.money),
            { did or '', cid }
          )
        end
        exports.oxmysql:execute(
          string.format("UPDATE `%s` SET card_number=?,exp_month=?,exp_year=?,card_status=?,discordid=? WHERE charid=?", M.money),
          { c.card_number, c.exp_month, c.exp_year, c.status, did or '', cid },
          function() cb(cards) end
        )
      end
    end
  )
end


local function fetchDepartment(did, cid, cb)
  if not cid or cid == '' then return cb() end
  exports.oxmysql:query(
    string.format("SELECT discordid,charid,paycheck FROM `%s` WHERE charid = ? LIMIT 1", M.dept),
    { cid },
    function(rows)
      if #rows == 0 then
        exports.oxmysql:insert(
          string.format("INSERT INTO `%s` (discordid,charid,paycheck) VALUES (?,?,?)", M.dept),
          { did or '', cid, 0 },
          function() cb() end
        )
      else
        
        if did and did ~= '' and rows[1].discordid ~= did then
          exports.oxmysql:execute(
            string.format("UPDATE `%s` SET discordid = ? WHERE charid = ?", M.dept),
            { did, cid }
          )
        end
        cb(rows)
      end
    end
  )
end


local function pushData(src, errMsg)
  local did = getDiscordID(src)
  local cid = getCharID(src)
  if cid == '' then return end

  fetchCards(did, cid, function()
    fetchMoney(did, cid, function(m)
      fetchAccounts(did, cid, function(accts)
        local checking = 0
        for _, acct in ipairs(accts) do
          if acct.type == 'checking' then checking = tonumber(acct.balance) or 0 end
        end

        exports.oxmysql:query(
          string.format("SELECT payee,amount,schedule_date FROM `%s` WHERE charid = ? ORDER BY schedule_date", M.pays),
          { cid },
          function(pays)
            exports.oxmysql:query(
              string.format("SELECT card_number,exp_month,exp_year,status FROM `%s` WHERE charid = ? LIMIT 1", M.cards),
              { cid },
              function(cds)
                exports.oxmysql:query(
                  string.format("SELECT paycheck FROM `%s` WHERE charid = ? LIMIT 1", M.dept),
                  { cid },
                  function(dr)
                    local dept_pay = dr[1] and dr[1].paycheck or 0
                    local payload = {
                      cash                = tonumber(m.cash) or 0,
                      bank                = tonumber(checking) or 0,
                      card_number         = m.card_number or "",
                      exp_month           = m.exp_month or 0,
                      exp_year            = m.exp_year or 0,
                      card_status         = m.card_status or "active",
                      department_paycheck = dept_pay,
                      accounts            = accts,
                      payments            = pays,
                      cards               = cds,
                      profile_picture     = m.profile_picture or ""
                    }
                    if errMsg then payload.transferError = errMsg end
                    TriggerClientEvent('my-bank-ui:updateData', src, payload)
                    TriggerClientEvent('updateCashHUD', src, payload.cash, payload.bank)
                  end
                )
              end
            )
          end
        )
      end)
    end)
  end)
end


AddEventHandler('playerConnecting', function(name, setKick, def)
  local src = source
  local did = getDiscordID(src)
  local cid = getCharID(src)
  if cid == '' then return end
  fetchMoney(did, cid, function() end)
  fetchAccounts(did, cid, function() end)
  fetchCards(did, cid, function() end)
  fetchDepartment(did, cid, function() end)
end)


RegisterServerEvent('my-bank-ui:getData', function() pushData(source) end)

RegisterServerEvent('my-bank-ui:deposit', function(data)
  local src = source
  local did = getDiscordID(src)
  local cid = getCharID(src)
  local amt = tonumber(data.amount) or 0
  if amt > 0 and cid ~= '' then
    
    exports.oxmysql:execute(
      string.format("UPDATE `%s` SET cash = GREATEST(cash - ?,0), discordid = ? WHERE charid = ?", M.money),
      { amt, did or '', cid }
    )
    exports.oxmysql:execute(
      string.format("UPDATE `%s` SET balance = balance + ?, discordid = ? WHERE charid = ? AND type = 'checking'", M.accts),
      { amt, did or '', cid }
    )
  end
  pushData(src)
end)

RegisterServerEvent('my-bank-ui:withdraw', function(data)
  local src = source
  local did = getDiscordID(src)
  local cid = getCharID(src)
  local amt = tonumber(data.amount) or 0
  if amt > 0 and cid ~= '' then
    exports.oxmysql:execute(
      string.format("UPDATE `%s` SET balance = GREATEST(balance - ?,0), discordid = ? WHERE charid = ? AND type = 'checking'", M.accts),
      { amt, did or '', cid }
    )
    exports.oxmysql:execute(
      string.format("UPDATE `%s` SET cash = cash + ?, discordid = ? WHERE charid = ?", M.money),
      { amt, did or '', cid }
    )
  end
  pushData(src)
end)

RegisterServerEvent('my-bank-ui:transfer', function(data)
  
  local src = source
  local did = getDiscordID(src)
  local cid = getCharID(src)
  local tgt = tostring(data.target or "")
  local amt = tonumber(data.amount) or 0
  if amt <= 0 or cid == '' or tgt == '' or tgt == cid then return pushData(src,"Invalid transfer parameters.") end

  exports.oxmysql:query(
    string.format("SELECT cash FROM `%s` WHERE charid = ? LIMIT 1", M.money),
    { cid },
    function(res)
      local cash = res[1] and tonumber(res[1].cash) or 0
      if cash < amt then return pushData(src,"Not enough cash to transfer.") end

      
      exports.oxmysql:execute(
        string.format("UPDATE `%s` SET cash = cash - ?, discordid = ? WHERE charid = ?", M.money),
        { amt, did or '', cid },
        function()
          
          exports.oxmysql:query(
            string.format("SELECT charid FROM `%s` WHERE charid = ? LIMIT 1", M.money),
            { tgt },
            function(r2)
              local function addToTarget()
                exports.oxmysql:execute(
                  string.format("UPDATE `%s` SET cash = cash + ? WHERE charid = ?", M.money),
                  { amt, tgt },
                  function() pushData(src) end
                )
              end

              if #r2 == 0 then
                exports.oxmysql:insert(
                  string.format("INSERT INTO `%s` (discordid,charid,cash,bank,card_status) VALUES (?,?,?,?,?)", M.money),
                  { '', tgt, amt, 0, 'active' },
                  function() pushData(src) end
                )
              else
                addToTarget()
              end
            end
          )
        end
      )
    end
  )
end)

RegisterServerEvent('my-bank-ui:addPayment', function(data)
  local src = source
  local did = getDiscordID(src)
  local cid = getCharID(src)
  local payee = tostring(data.payee or "")
  local amt   = tonumber(data.amount) or 0
  local dt    = (data.schedule_date or "") .. " " .. (data.schedule_time or "00:00:00")
  if payee ~= "" and amt > 0 and data.schedule_date ~= "" and cid ~= '' then
    exports.oxmysql:insert(
      string.format("INSERT INTO `%s` (discordid,charid,payee,amount,schedule_date) VALUES (?,?,?,?,?)", M.pays),
      { did or '', cid, payee, amt, dt },
      function() pushData(src) end
    )
  else
    pushData(src)
  end
end)

RegisterServerEvent('my-bank-ui:transferInternal', function(data)
  local src = source
  local did = getDiscordID(src)
  local cid = getCharID(src)
  local from, to = data.from, data.to
  local amt      = tonumber(data.amount) or 0
  if amt <= 0 or from == to or cid == '' then return pushData(src,"Invalid internal transfer.") end

  fetchMoney(did, cid, function(m)
    fetchAccounts(did, cid, function(accts)
      local bal = 0
      if from == 'cash' then bal = tonumber(m.cash) or 0
      else
        for _, a in ipairs(accts) do if a.type == from then bal = tonumber(a.balance) or 0 end end
      end
      if bal < amt then return pushData(src,"Insufficient funds in " .. from) end

      local Q = {}
      if from == 'cash' then
        table.insert(Q, {
          sql    = string.format("UPDATE `%s` SET cash = cash - ?, discordid = ? WHERE charid = ?", M.money),
          params = { amt, did or '', cid }
        })
      else
        table.insert(Q, {
          sql    = string.format("UPDATE `%s` SET balance = balance - ?, discordid = ? WHERE charid = ? AND type = ?", M.accts),
          params = { amt, did or '', cid, from }
        })
      end

      if to == 'cash' then
        table.insert(Q, {
          sql    = string.format("UPDATE `%s` SET cash = cash + ?, discordid = ? WHERE charid = ?", M.money),
          params = { amt, did or '', cid }
        })
      else
        table.insert(Q, {
          sql    = string.format("UPDATE `%s` SET balance = balance + ?, discordid = ? WHERE charid = ? AND type = ?", M.accts),
          params = { amt, did or '', cid, to }
        })
      end

      local function exec(i)
        if i > #Q then return pushData(src) end
        exports.oxmysql:execute(Q[i].sql, Q[i].params, function() exec(i + 1) end)
      end

      exec(1)
    end)
  end)
end)
