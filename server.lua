-- server.lua

local M = {
  money = 'econ_user_money',
  accts = 'econ_accounts',
  pays  = 'econ_payments',
  cards = 'econ_cards',
  dept  = 'econ_departments'
}
local SAVINGS_APR = 0.05

-- Helper: get Discord ID from identifiers
local function getDiscordID(src)
  for _, id in ipairs(GetPlayerIdentifiers(src)) do
    if id:sub(1,8) == 'discord:' then
      return id:sub(9)
    end
  end
end

-- Fetch or create user_money row (now includes bank column)
local function fetchMoney(did, cb)
  exports.oxmysql:query(
    ("SELECT cash, bank, profile_picture, card_number, exp_month, exp_year, card_status FROM %s WHERE discordid = ?")
      :format(M.money),
    { did },
    function(res)
      if res[1] then
        cb(res[1])
      else
        exports.oxmysql:insert(
          ("INSERT INTO %s (discordid, cash, bank, profile_picture) VALUES (?, ?, ?, '')")
            :format(M.money),
          { did, 0, 0 },
          function() fetchMoney(did, cb) end
        )
      end
    end
  )
end

-- Fetch or create checking & savings accounts
local function fetchAccounts(did, cb)
  exports.oxmysql:query(
    ("SELECT id, type, balance FROM %s WHERE discordid = ?")
      :format(M.accts),
    { did },
    function(accts)
      if #accts == 0 then
        exports.oxmysql:insert(
          ("INSERT INTO %s (discordid, type, balance) VALUES (?, ?, ?), (?, ?, ?)")
            :format(M.accts),
          { did,'checking',0, did,'savings',0 },
          function() fetchAccounts(did, cb) end
        )
      else
        for _, acct in ipairs(accts) do
          if acct.type == 'savings' then
            local daily_rate = SAVINGS_APR / 365
            acct.apr = SAVINGS_APR
            acct.daily_interest = acct.balance * daily_rate
          end
        end
        cb(accts)
      end
    end
  )
end

-- Fetch or create default card, and sync into econ_user_money
local function fetchCards(did, cb)
  exports.oxmysql:query(
    ("SELECT id, card_number, exp_month, exp_year, status FROM %s WHERE discordid = ?")
      :format(M.cards),
    { did },
    function(cards)
      if #cards == 0 then
        -- generate a 16-digit card number starting with 4xxx
        local num   = tostring(math.random(4000,4999))
                      .. tostring(math.random(1000,9999))
                      .. tostring(math.random(1000,9999))
                      .. tostring(math.random(1000,9999))
        local month = math.random(1,12)
        local year  = tonumber(os.date("%Y")) + 3
        local status= 'active'

        -- insert into econ_cards
        exports.oxmysql:insert(
          ("INSERT INTO %s (discordid, card_number, exp_month, exp_year, status) VALUES (?,?,?,?,?)")
            :format(M.cards),
          { did, num, month, year, status },
          function()
            -- sync into econ_user_money
            exports.oxmysql:execute(
              ("UPDATE %s SET card_number = ?, exp_month = ?, exp_year = ?, card_status = ? WHERE discordid = ?")
                :format(M.money),
              { num, month, year, status, did },
              function()
                cb({ { card_number = num, exp_month = month, exp_year = year, status = status } })
              end
            )
          end
        )
      else
        local c = cards[1]
        -- ensure econ_user_money has the same values
        exports.oxmysql:execute(
          ("UPDATE %s SET card_number = ?, exp_month = ?, exp_year = ?, card_status = ? WHERE discordid = ?")
            :format(M.money),
          { c.card_number, c.exp_month, c.exp_year, c.status, did },
          function()
            cb(cards)
          end
        )
      end
    end
  )
end

-- Fetch or create department record
local function fetchDepartment(did, cb)
  exports.oxmysql:query(
    ("SELECT discordid FROM %s WHERE discordid = ?")
      :format(M.dept),
    { did },
    function(rows)
      if #rows == 0 then
        exports.oxmysql:insert(
          ("INSERT INTO %s (discordid, paycheck) VALUES (?,?)")
            :format(M.dept),
          { did, 0 },
          function() cb() end
        )
      else
        cb(rows)
      end
    end
  )
end


-- Assemble & send payload to client, ensuring card exists first
local function pushData(src, errMsg)
  local did = getDiscordID(src)
  if not did then return end

  fetchCards(did, function()
    fetchMoney(did, function(m)
      fetchAccounts(did, function(accts)
        exports.oxmysql:query(
          ("SELECT payee, amount, schedule_date FROM %s WHERE discordid = ? ORDER BY schedule_date")
            :format(M.pays),
          { did },
          function(pays)
            exports.oxmysql:query(
              ("SELECT card_number, exp_month, exp_year, status FROM %s WHERE discordid = ?")
                :format(M.cards),
              { did },
              function(cds)
                exports.oxmysql:query(
                  ("SELECT paycheck FROM %s WHERE discordid = ?")
                    :format(M.dept),
                  { did },
                  function(dr)
                    local dept_pay = dr[1] and dr[1].paycheck or 0

                    local payload = {
                      cash                = m.cash,
                      bank                = tonumber(m.bank),
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
                    if errMsg then
                      payload.transferError = errMsg
                    end

                   
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

-- Ensure user data exists on join
AddEventHandler('playerConnecting', function(name, setKick, def)
  local src = source
  local did = getDiscordID(src)
  if not did then return end

  fetchMoney(did, function() end)
  fetchAccounts(did, function() end)
  fetchCards(did, function() end)
  fetchDepartment(did, function() end)
end)

-- Events -------------------------------------------------------------------
RegisterServerEvent('my-bank-ui:getData', function() pushData(source) end)

RegisterServerEvent('my-bank-ui:deposit', function(data)
  local src, did = source, getDiscordID(source)
  local amt = tonumber(data.amount) or 0
  if amt > 0 and did then
    exports.oxmysql:execute(
      ("UPDATE %s SET cash = GREATEST(cash - ?, 0) WHERE discordid = ?"):format(M.money),
      { amt, did }
    )
    exports.oxmysql:execute(
      ("UPDATE %s SET balance = balance + ? WHERE discordid = ? AND type = 'checking'"):format(M.accts),
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
      ("UPDATE %s SET balance = GREATEST(balance - ?, 0) WHERE discordid = ? AND type = 'checking'"):format(M.accts),
      { amt, did }
    )
    exports.oxmysql:execute(
      ("UPDATE %s SET cash = cash + ? WHERE discordid = ?"):format(M.money),
      { amt, did }
    )
  end
  pushData(src)
end)

RegisterServerEvent('my-bank-ui:transfer', function(data)
  local src, did = source, getDiscordID(source)
  local tgt, amt = tostring(data.target), tonumber(data.amount) or 0

  if amt <= 0 or not did or not tgt then
    return pushData(src, "Invalid transfer parameters.")
  end

  -- Check sender cash
  exports.oxmysql:query(
    ("SELECT cash FROM %s WHERE discordid = ?"):format(M.money),
    { did },
    function(res)
      local cash = res[1] and tonumber(res[1].cash) or 0
      if cash < amt then
        return pushData(src, "Not enough cash to transfer.")
      end

      -- Perform debit + credit
      exports.oxmysql:execute(
        ("UPDATE %s SET cash = cash - ? WHERE discordid = ?"):format(M.money),
        { amt, did },
        function()
          exports.oxmysql:execute(
            ("UPDATE %s SET cash = cash + ? WHERE discordid = ?"):format(M.money),
            { amt, tgt },
            function()
              pushData(src)
            end
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
      ("INSERT INTO %s (discordid, payee, amount, schedule_date) VALUES (?, ?, ?, ?)"):format(M.pays),
      { did, payee, amt, dt },
      function() pushData(src) end
    )
  else
    pushData(src)
  end
end)

RegisterServerEvent('my-bank-ui:transferInternal', function(data)
  local src, did = source, getDiscordID(source)
  local from, to   = data.from, data.to
  local amt        = tonumber(data.amount) or 0

  if amt <= 0 or from == to or not did then
    return pushData(src, "Invalid internal transfer.")
  end

  fetchMoney(did, function(m)
    fetchAccounts(did, function(accts)
      local bal = (from == 'cash')
        and tonumber(m.cash)
        or (function()
            for _, a in ipairs(accts) do
              if a.type == from then return tonumber(a.balance) end
            end
            return 0
          end)()

      if bal < amt then
        return pushData(src, "Insufficient funds in " .. from .. ".")
      end

      local q = {}
      if from == 'cash' then
        table.insert(q, {
          sql    = ("UPDATE %s SET cash = cash - ? WHERE discordid = ?"):format(M.money),
          params = { amt, did }
        })
      else
        table.insert(q, {
          sql    = ("UPDATE %s SET balance = balance - ? WHERE discordid = ? AND type = ?")
                     :format(M.accts),
          params = { amt, did, from }
        })
      end

      if to == 'cash' then
        table.insert(q, {
          sql    = ("UPDATE %s SET cash = cash + ? WHERE discordid = ?"):format(M.money),
          params = { amt, did }
        })
      else
        table.insert(q, {
          sql    = ("UPDATE %s SET balance = balance + ? WHERE discordid = ? AND type = ?")
                     :format(M.accts),
          params = { amt, did, to }
        })
      end

      local function exec(i)
        if i > #q then return pushData(src) end
        exports.oxmysql:execute(q[i].sql, q[i].params, function() exec(i+1) end)
      end
      exec(1)
    end)
  end)
end)
