local M = {
  money = 'econ_user_money',
  accts = 'econ_accounts',
  pays  = 'econ_payments',
  cards = 'econ_cards',
  dept  = 'econ_departments',
  prof  = 'econ_user_money'
}
local SAVINGS_APR = 0.05

-- Helper to get Discord ID
local function getDiscordID(src)
  for _, id in ipairs(GetPlayerIdentifiers(src)) do
    if id:sub(1,8) == 'discord:' then
      return id:sub(9)
    end
  end
end

-- Fetch or create the user's cash & profile record
local function fetchMoney(did, cb)
  exports.oxmysql:query(
    ("SELECT cash, firstname, lastname, profile_picture, card_number, exp_month, exp_year, card_status FROM %s WHERE discordid=?")
      :format(M.money),
    { did },
    function(res)
      if res[1] then
        cb(res[1])
      else
        exports.oxmysql:insert(
          ("INSERT INTO %s (discordid, cash, firstname, lastname) VALUES (?,?, '', '')")
            :format(M.money),
          { did, 0 },
          function() fetchMoney(did, cb) end
        )
      end
    end
  )
end

-- Fetch or create checking & savings accounts, compute savings APR
local function fetchAccounts(did, cb)
  exports.oxmysql:query(
    ("SELECT id, type, balance FROM %s WHERE discordid=?"):format(M.accts),
    { did },
    function(accts)
      if #accts == 0 then
        exports.oxmysql:insert(
          ("INSERT INTO %s (discordid, type, balance) VALUES (?,?,?),(?,?,?)")
            :format(M.accts),
          { did,'checking',0, did,'savings',0 },
          function() fetchAccounts(did, cb) end
        )
      else
        for _, acct in ipairs(accts) do
          if acct.type=='savings' then
            local daily_rate = SAVINGS_APR/365
            acct.apr = SAVINGS_APR
            acct.daily_interest = acct.balance * daily_rate
          end
        end
        cb(accts)
      end
    end
  )
end

-- Assemble & send full payload
local function pushData(src)
  local did = getDiscordID(src); if not did then return end

  fetchMoney(did, function(m)
    fetchAccounts(did, function(accts)
      local total_bank = 0
      for _, a in ipairs(accts) do total_bank = total_bank + tonumber(a.balance) end

      exports.oxmysql:query(
        ("SELECT payee,amount,schedule_date FROM %s WHERE discordid=? ORDER BY schedule_date")
          :format(M.pays), {did},
        function(pays)
          exports.oxmysql:query(
            ("SELECT card_number,exp_month,exp_year,status FROM %s WHERE discordid=?")
              :format(M.cards), {did},
            function(cds)
              exports.oxmysql:query(
                ("SELECT firstname,lastname,profile_picture FROM %s WHERE discordid=?")
                  :format(M.prof), {did},
                function(pr)
                  local profile = pr[1] or { firstname="", lastname="", profile_picture="" }
                  exports.oxmysql:query(
                    ("SELECT paycheck FROM %s WHERE discordid=?"):format(M.dept),
                    {did},
                    function(dr)
                      local dept_pay = dr[1] and dr[1].paycheck or 0
                      TriggerClientEvent('my-bank-ui:updateData', src, {
                        cash                = m.cash,
                        bank                = total_bank,
                        card_number         = m.card_number or "",
                        exp_month           = m.exp_month or 0,
                        exp_year            = m.exp_year or 0,
                        card_status         = m.card_status or "active",
                        department_paycheck = dept_pay,
                        accounts            = accts,
                        payments            = pays,
                        cards               = cds,
                        profile             = profile
                      })
                    end
                  )
                end
              )
            end
          )
        end
      )
    end)
  end)
end

RegisterServerEvent('my-bank-ui:getData', function() pushData(source) end)

RegisterServerEvent('my-bank-ui:deposit', function(data)
  local src, did = source, getDiscordID(source)
  local amt = tonumber(data.amount) or 0
  if amt > 0 then
    exports.oxmysql:execute(
      ("UPDATE %s SET cash = cash + ? WHERE discordid=?"):format(M.money),
      { amt, did }
    )
  end
  pushData(src)
end)

RegisterServerEvent('my-bank-ui:withdraw', function(data)
  local src, did = source, getDiscordID(source)
  local amt = tonumber(data.amount) or 0
  if amt > 0 then
    exports.oxmysql:execute(
      ("UPDATE %s SET cash = GREATEST(cash - ?, 0) WHERE discordid=?"):format(M.money),
      { amt, did }
    )
  end
  pushData(src)
end)

RegisterServerEvent('my-bank-ui:transfer', function(data)
  local src, did = source, getDiscordID(source)
  local tgtID = tostring(data.target)
  local amt = tonumber(data.amount) or 0
  if amt > 0 and did and tgtID then
    -- debit sender
    exports.oxmysql:execute(
      ("UPDATE %s SET cash = GREATEST(cash - ?,0) WHERE discordid=?"):format(M.money),
      { amt, did }
    )
    -- credit recipient
    exports.oxmysql:execute(
      ("UPDATE %s SET cash = cash + ? WHERE discordid=?"):format(M.money),
      { amt, tgtID }
    )
  end
  pushData(src)
end)

RegisterServerEvent('my-bank-ui:addPayment', function(data)
  local src, did = source, getDiscordID(source)
  local payee = tostring(data.payee or "")
  local amt   = tonumber(data.amount) or 0
  local dt    = (data.schedule_date or "").." "..(data.schedule_time or "00:00:00")
  if payee~="" and amt>0 and data.schedule_date~="" then
    exports.oxmysql:insert(
      ("INSERT INTO %s (discordid,payee,amount,schedule_date) VALUES (?,?,?,?)"):format(M.pays),
      { did, payee, amt, dt },
      function() pushData(src) end
    )
  else
    pushData(src)
  end
end)

RegisterServerEvent('my-bank-ui:updateProfile', function(data)
  local src, did = source, getDiscordID(source)
  if not did then return end
  exports.oxmysql:execute(
    ("UPDATE %s SET firstname=?,lastname=?,profile_picture=? WHERE discordid=?"):format(M.money),
    { data.firstname or "", data.lastname or "", data.profile_picture or "", did },
    function() pushData(src) end
  )
end)

RegisterServerEvent('my-bank-ui:transferInternal', function(data)
  local src = source
  local did = getDiscordID(src)
  local from, to = data.from, data.to
  local amt = tonumber(data.amount) or 0

  if amt <= 0 or from == to or not did then
    pushData(src)
    return
  end

  -- Run debit + credit SQL in sequence
  local queries = {}

  -- Debit from `from`
  if from == 'cash' then
    table.insert(queries, {
      sql = ("UPDATE %s SET cash = GREATEST(cash - ?, 0) WHERE discordid = ?"):format(M.money),
      params = { amt, did }
    })
  else
    table.insert(queries, {
      sql = ("UPDATE %s SET balance = GREATEST(balance - ?, 0) WHERE discordid = ? AND type = ?"):format(M.accts),
      params = { amt, did, from }
    })
  end

  -- Credit to `to`
  if to == 'cash' then
    table.insert(queries, {
      sql = ("UPDATE %s SET cash = cash + ? WHERE discordid = ?"):format(M.money),
      params = { amt, did }
    })
  else
    table.insert(queries, {
      sql = ("UPDATE %s SET balance = balance + ? WHERE discordid = ? AND type = ?"):format(M.accts),
      params = { amt, did, to }
    })
  end

  -- Execute all queries, then refresh UI using exported GetMoney/sendMoneyToClient
  local function exec(i)
    if i > #queries then
      -- Use exported GetMoney to retrieve updated balances
      exports['Az-Framework']:GetMoney(did, function(data)
        -- Use exported sendMoneyToClient to push data back to client
        exports['Az-Framework']:sendMoneyToClient(src, did)
      end)
      return
    end

    exports.oxmysql:execute(queries[i].sql, queries[i].params, function()
      exec(i + 1)
    end)
  end

  exec(1)
end)

