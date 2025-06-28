-- server.lua

local M = {
  money = 'econ_user_money',
  accts = 'econ_accounts',
  pays  = 'econ_payments',
  cards = 'econ_cards',
  dept  = 'econ_departments'
}
local SAVINGS_APR = 0.05

--[[-------------------------------------------------------------------------
  SCHEMA CREATION: run once on resource start
---------------------------------------------------------------------------]]
AddEventHandler('onResourceStart', function(resourceName)
  if GetCurrentResourceName() ~= resourceName then return end

  -- USER MONEY
  exports.oxmysql:execute(string.format([[
    CREATE TABLE IF NOT EXISTS `%s` (
      `discordid`     VARCHAR(32) NOT NULL PRIMARY KEY,
      `cash`          BIGINT      NOT NULL DEFAULT 0,
      `bank`          BIGINT      NOT NULL DEFAULT 0,
      `profile_picture` VARCHAR(255) DEFAULT '',
      `card_number`   VARCHAR(16) DEFAULT '',
      `exp_month`     INT         DEFAULT 0,
      `exp_year`      INT         DEFAULT 0,
      `card_status`   VARCHAR(16) DEFAULT ''
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]
    , M.money))

  -- ACCOUNTS
  exports.oxmysql:execute(string.format([[
    CREATE TABLE IF NOT EXISTS `%s` (
      `id`        INT AUTO_INCREMENT PRIMARY KEY,
      `discordid` VARCHAR(32) NOT NULL,
      `type`      ENUM('checking','savings') NOT NULL,
      `balance`   BIGINT NOT NULL DEFAULT 0,
      INDEX (discordid)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]
    , M.accts))

  -- PAYMENTS
  exports.oxmysql:execute(string.format([[
    CREATE TABLE IF NOT EXISTS `%s` (
      `id`            INT AUTO_INCREMENT PRIMARY KEY,
      `discordid`     VARCHAR(32) NOT NULL,
      `payee`         VARCHAR(64) NOT NULL,
      `amount`        BIGINT      NOT NULL,
      `schedule_date` DATETIME    NOT NULL,
      INDEX (discordid)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]
    , M.pays))

  -- CARDS
  exports.oxmysql:execute(string.format([[
    CREATE TABLE IF NOT EXISTS `%s` (
      `id`            INT AUTO_INCREMENT PRIMARY KEY,
      `discordid`     VARCHAR(32) NOT NULL,
      `card_number`   VARCHAR(16) NOT NULL,
      `exp_month`     INT         NOT NULL,
      `exp_year`      INT         NOT NULL,
      `status`        VARCHAR(16) NOT NULL,
      INDEX (discordid)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]
    , M.cards))

  -- DEPARTMENTS
  exports.oxmysql:execute(string.format([[
    CREATE TABLE IF NOT EXISTS `%s` (
      `discordid` VARCHAR(32) NOT NULL PRIMARY KEY,
      `paycheck`  BIGINT NOT NULL DEFAULT 0
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]
    , M.dept))

  print("^2[econ]^0 All econ tables ensured.")
end)

-- Helper: get Discord ID from identifiers
local function getDiscordID(src)
  for _, id in ipairs(GetPlayerIdentifiers(src)) do
    if id:sub(1,8) == 'discord:' then
      return id:sub(9)
    end
  end
end

-- Fetch or create user_money row
local function fetchMoney(did, cb)
  exports.oxmysql:query(
    string.format("SELECT * FROM `%s` WHERE discordid = ?", M.money),
    { did },
    function(res)
      if res[1] then cb(res[1])
      else
        exports.oxmysql:insert(
          string.format("INSERT INTO `%s` (discordid,cash,bank,profile_picture) VALUES (?,?,?, '')", M.money),
          { did, 0, 0 },
          function() fetchMoney(did, cb) end
        )
      end
    end
  )
end

-- Fetch or create accounts (checking + savings)
local function fetchAccounts(did, cb)
  exports.oxmysql:query(
    string.format("SELECT id,type,balance FROM `%s` WHERE discordid = ?", M.accts),
    { did },
    function(accts)
      if #accts == 0 then
        exports.oxmysql:insert(
          string.format(
            "INSERT INTO `%s` (discordid,type,balance) VALUES (?,?,?),(?,?,?)",
            M.accts
          ),
          { did,'checking',0, did,'savings',0 },
          function() fetchAccounts(did, cb) end
        )
      else
        for _, acct in ipairs(accts) do
          if acct.type == 'savings' then
            local rate = SAVINGS_APR / 365
            acct.apr = SAVINGS_APR
            acct.daily_interest = acct.balance * rate
          end
        end
        cb(accts)
      end
    end
  )
end

-- Fetch or create default card
local function fetchCards(did, cb)
  exports.oxmysql:query(
    string.format("SELECT * FROM `%s` WHERE discordid = ?", M.cards),
    { did },
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
          string.format(
            "INSERT INTO `%s` (discordid,card_number,exp_month,exp_year,status) VALUES (?,?,?,?,?)",
            M.cards
          ),
          { did, num, month, year, status },
          function()
            exports.oxmysql:execute(
              string.format(
                "UPDATE `%s` SET card_number=?,exp_month=?,exp_year=?,card_status=? WHERE discordid=?",
                M.money
              ),
              { num, month, year, status, did },
              function() cb({{card_number=num,exp_month=month,exp_year=year,status=status}}) end
            )
          end
        )
      else
        local c = cards[1]
        exports.oxmysql:execute(
          string.format(
            "UPDATE `%s` SET card_number=?,exp_month=?,exp_year=?,card_status=? WHERE discordid=?",
            M.money
          ),
          { c.card_number, c.exp_month, c.exp_year, c.status, did },
          function() cb(cards) end
        )
      end
    end
  )
end

-- Fetch or create department record
local function fetchDepartment(did, cb)
  exports.oxmysql:query(
    string.format("SELECT discordid FROM `%s` WHERE discordid = ?", M.dept),
    { did },
    function(rows)
      if #rows == 0 then
        exports.oxmysql:insert(
          string.format("INSERT INTO `%s` (discordid,paycheck) VALUES (?,?)", M.dept),
          { did, 0 },
          function() cb() end
        )
      else
        cb(rows)
      end
    end
  )
end

-- Push all data down to client
local function pushData(src, errMsg)
  local did = getDiscordID(src)
  if not did then return end

  fetchCards(did, function()
    fetchMoney(did, function(m)
      fetchAccounts(did, function(accts)
        local checking = 0
        for _, acct in ipairs(accts) do
          if acct.type == 'checking' then checking = tonumber(acct.balance) or 0 end
        end

        exports.oxmysql:query(
          string.format("SELECT payee,amount,schedule_date FROM `%s` WHERE discordid = ? ORDER BY schedule_date", M.pays),
          { did },
          function(pays)
            exports.oxmysql:query(
              string.format("SELECT card_number,exp_month,exp_year,status FROM `%s` WHERE discordid = ?", M.cards),
              { did },
              function(cds)
                exports.oxmysql:query(
                  string.format("SELECT paycheck FROM `%s` WHERE discordid = ?", M.dept),
                  { did },
                  function(dr)
                    local dept_pay = dr[1] and dr[1].paycheck or 0
                    local payload = {
                      cash                = m.cash,
                      bank                = checking,
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

-- Auto‑create on player connect
AddEventHandler('playerConnecting', function(name, setKick, def)
  local src = source
  local did = getDiscordID(src)
  if not did then return end
  fetchMoney(did, function() end)
  fetchAccounts(did, function() end)
  fetchCards(did, function() end)
  fetchDepartment(did, function() end)
end)

-- Events
RegisterServerEvent('my-bank-ui:getData', function() pushData(source) end)
RegisterServerEvent('my-bank-ui:deposit', function(data)
  local src, did = source, getDiscordID(source)
  local amt = tonumber(data.amount) or 0
  if amt > 0 and did then
    exports.oxmysql:execute(
      string.format("UPDATE `%s` SET cash = GREATEST(cash - ?,0) WHERE discordid = ?", M.money),
      { amt, did }
    )
    exports.oxmysql:execute(
      string.format("UPDATE `%s` SET balance = balance + ? WHERE discordid = ? AND type = 'checking'", M.accts),
      { amt, did }
    )
  end
  pushData(src)
end)
RegisterServerEvent('my-bank-ui:withdraw', function(data)
  local src, did = source, getDiscordID(source)
  local amt = tonumber(data.amount) or 0
  if amt > 0 and did then
    exports.oxmysql:execute(
      string.format("UPDATE `%s` SET balance = GREATEST(balance - ?,0) WHERE discordid = ? AND type = 'checking'", M.accts),
      { amt, did }
    )
    exports.oxmysql:execute(
      string.format("UPDATE `%s` SET cash = cash + ? WHERE discordid = ?", M.money),
      { amt, did }
    )
  end
  pushData(src)
end)
RegisterServerEvent('my-bank-ui:transfer', function(data)
  local src, did = source, getDiscordID(source)
  local tgt, amt = tostring(data.target), tonumber(data.amount) or 0
  if amt <= 0 or not did or not tgt then return pushData(src,"Invalid transfer parameters.") end

  exports.oxmysql:query(
    string.format("SELECT cash FROM `%s` WHERE discordid = ?", M.money),
    { did },
    function(res)
      local cash = res[1] and tonumber(res[1].cash) or 0
      if cash < amt then return pushData(src,"Not enough cash to transfer.") end

      exports.oxmysql:execute(
        string.format("UPDATE `%s` SET cash = cash - ? WHERE discordid = ?", M.money),
        { amt, did },
        function()
          exports.oxmysql:execute(
            string.format("UPDATE `%s` SET cash = cash + ? WHERE discordid = ?", M.money),
            { amt, tgt },
            function() pushData(src) end
          )
        end
      )
    end
  )
end)
RegisterServerEvent('my-bank-ui:addPayment', function(data)
  local src, did = source, getDiscordID(source)
  local payee = tostring(data.payee or "")
  local amt   = tonumber(data.amount) or 0
  local dt    = (data.schedule_date or "").." "..(data.schedule_time or "00:00:00")
  if payee ~= "" and amt > 0 and data.schedule_date ~= "" then
    exports.oxmysql:insert(
      string.format("INSERT INTO `%s` (discordid,payee,amount,schedule_date) VALUES (?,?,?,?)", M.pays),
      { did, payee, amt, dt },
      function() pushData(src) end
    )
  else
    pushData(src)
  end
end)
RegisterServerEvent('my-bank-ui:transferInternal', function(data)
  local src, did = source, getDiscordID(source)
  local from, to = data.from, data.to
  local amt      = tonumber(data.amount) or 0
  if amt <= 0 or from == to or not did then return pushData(src,"Invalid internal transfer.") end

  fetchMoney(did, function(m)
    fetchAccounts(did, function(accts)
      local bal = (from=='cash') and tonumber(m.cash) or (function()
        for _, a in ipairs(accts) do if a.type==from then return tonumber(a.balance) end end
        return 0
      end)()
      if bal < amt then return pushData(src,"Insufficient funds in "..from) end

      local Q = {}
      if from=='cash' then
        table.insert(Q,{ sql=string.format("UPDATE `%s` SET cash=cash-? WHERE discordid=?",M.money),
                         params={amt,did} })
      else
        table.insert(Q,{ sql=string.format("UPDATE `%s` SET balance=balance-? WHERE discordid=? AND type=?",M.accts),
                         params={amt,did,from} })
      end
      if to=='cash' then
        table.insert(Q,{ sql=string.format("UPDATE `%s` SET cash=cash+? WHERE discordid=?",M.money),
                         params={amt,did} })
      else
        table.insert(Q,{ sql=string.format("UPDATE `%s` SET balance=balance+? WHERE discordid=? AND type=?",M.accts),
                         params={amt,did,to} })
      end

      local function exec(i)
        if i>#Q then return pushData(src) end
        exports.oxmysql:execute(Q[i].sql, Q[i].params, function() exec(i+1) end)
      end
      exec(1)
    end)
  end)
end)
