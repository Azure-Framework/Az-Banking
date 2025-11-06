-- server.lua — banking backend (MySQL / oxmysql)
-- Internal/external transfers + NUI.
-- Authoritative sources:
--   - HUD CASH  = econ_user_money.cash
--   - HUD BANK  = SUM(econ_accounts.balance) over checking+savings
-- We DO NOT use econ_user_money.bank at all.
-- Now fully instrumented with DEBUG logs, including the exact values sent to updateCashHUD.
-- Fixes included:
--   - All balance mutations are per-character (no discord-wide UPDATEs).
--   - fetchAccounts() is char-scoped only.
--   - fetchMoney() fallback no longer depends on a table `id` column; uses a safe LIMIT update.
--   - Monthly totals exclude internal transfers so "spending" isn't inflated.
--   - Deposit/Withdraw update exactly one account row by id.

------------------------------------------------------------
-- CONFIG / DEBUG
------------------------------------------------------------
-- Toggle with server.cfg: setr az_econ_debug 1  (1=on, 0=off)
local DEBUG = (GetConvarInt and (GetConvarInt('az_econ_debug', 1) == 1)) or true


-- Sanitize user-entered amounts like "10,000", "$10,000.00", " 10000 "
local function parseAmount(x)
  local s = tostring(x or "")
  -- strip spaces & common currency separators/symbols
  s = s:gsub("%s+", "")
       :gsub("[,%$€£_]", "")
       :gsub("[^%d%.]", "")   -- keep only digits and a dot
  local n = tonumber(s)
  return math.floor(n or 0)
end


-- Pretty printer (safe/compact)
local function _dump(val, depth, seen)
  depth = depth or 2
  seen = seen or {}
  local t = type(val)
  if t ~= "table" then
    if t == "string" then
      return string.format("%q", val)
    else
      return tostring(val)
    end
  end
  if seen[val] then return "<rec>" end
  if depth <= 0 then return "{...}" end
  seen[val] = true
  local parts = {}
  for k,v in pairs(val) do
    local kk = type(k)=="string" and k or ("["..tostring(k).."]")
    table.insert(parts, kk.."=".._dump(v, depth-1, seen))
  end
  return "{"..table.concat(parts, ", ").."}"
end

local function dprint(fmt, ...)
  if not DEBUG then return end
  local ok, msg = pcall(string.format, fmt, ...)
  if not ok then msg = fmt end
  print(("^3[econ DEBUG]^7 %s"):format(msg))
end

local function dsql(tag, sql, params)
  if not DEBUG then return end
  local p = params and _dump(params, 3) or "[]"
  dprint("%s SQL: %s | params=%s", tag, sql, p)
end

------------------------------------------------------------
-- TABLE/RESOURCE CONSTANTS
------------------------------------------------------------
local T = {
  money = 'econ_user_money',
  accts = 'econ_accounts',
  pays  = 'econ_payments',
  cards = 'econ_cards',
  tx    = 'econ_transactions'
}

------------------------------------------------------------
-- IDENTIFIERS
------------------------------------------------------------
local function getDiscordID(src)
  for _, id in ipairs(GetPlayerIdentifiers(src)) do
    if id:sub(1,8) == 'discord:' then
      local did = id:sub(9)
      dprint("getDiscordID(src=%s) -> %s", tostring(src), tostring(did))
      return did
    end
  end
  dprint("getDiscordID(src=%s) -> '' (not found)", tostring(src))
  return ''
end

local function getCharID(src)
  if exports['Az-Framework'] and exports['Az-Framework'].GetPlayerCharacter then
    local cid = exports['Az-Framework']:GetPlayerCharacter(src)
    if cid and cid ~= '' then
      dprint("getCharID(Az-Framework, src=%s) -> %s", tostring(src), tostring(cid))
      return tostring(cid)
    end
  end
  for _, id in ipairs(GetPlayerIdentifiers(src)) do
    if id:match('^%d+$') then
      dprint("getCharID(fallback numeric, src=%s) -> %s", tostring(src), tostring(id))
      return id
    end
  end
  dprint("getCharID(src=%s) -> '' (not found)", tostring(src))
  return ''
end

------------------------------------------------------------
-- NUI RELAY
------------------------------------------------------------
local function nui(src, action, payload)
  dprint("NUI -> src=%s action=%s payload=%s", tostring(src), tostring(action), _dump(payload, 2))
  TriggerClientEvent('my-bank-ui:nui', src, { action = action, payload = payload })
end
local function notify(src, typ, text)
  dprint("notify -> src=%s type=%s text=%s", tostring(src), tostring(typ), tostring(text))
  nui(src, 'notify', { type = typ, text = text })
end

------------------------------------------------------------
-- TX LOGGER
------------------------------------------------------------
local function logTx(charid, discordid, typ, signedAmount, desc, account_id, counterparty)
  local sql = ("INSERT INTO `%s` (discordid,charid,type,amount,description,account_id,counterparty) VALUES (?,?,?,?,?,?,?)"):format(T.tx)
  local params = {
    tostring(discordid or ''), tostring(charid or ''), tostring(typ or ''),
    tonumber(signedAmount) or 0.0, tostring(desc or ''), tonumber(account_id) or 0,
    tostring(counterparty or '')
  }
  dsql("logTx", sql, params)
  exports.oxmysql:insert(sql, params, function(insertId)
    dprint("logTx done -> insertId=%s", tostring(insertId))
  end)
end

------------------------------------------------------------
-- ANTI DOUBLE-CLICK PER-PLAYER
------------------------------------------------------------
local Lock = {}
local function with_lock(src, key, ms, fn)
  Lock[src] = Lock[src] or {}
  if Lock[src][key] then
    dprint("with_lock BLOCKED src=%s key=%s (still locked)", tostring(src), tostring(key))
    return
  end
  Lock[src][key] = true
  dprint("with_lock ACQUIRE src=%s key=%s (timeout=%sms)", tostring(src), tostring(key), tostring(ms or 800))
  local ok, err = pcall(fn)
  if not ok then print(('[econ] %s error: %s'):format(key, err)) end
  Citizen.SetTimeout(ms or 800, function()
    Lock[src][key] = false
    dprint("with_lock RELEASE src=%s key=%s", tostring(src), tostring(key))
  end)
end

------------------------------------------------------------
-- BOOT TABLES
------------------------------------------------------------
AddEventHandler('onResourceStart', function(res)
  if res ~= GetCurrentResourceName() then return end
  dprint("onResourceStart -> ensuring tables...")

  -- Note: CREATE TABLE IF NOT EXISTS won't modify existing schemas. We avoid depending on any column
  -- that older installs might not have (e.g., an `id` on money). This DDL includes an id for new installs.
  local sql1 = ([[CREATE TABLE IF NOT EXISTS `%s`(
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `discordid` varchar(64) DEFAULT '',
    `charid` varchar(100) NOT NULL,
    `firstname` varchar(100) DEFAULT '',
    `lastname` varchar(100) DEFAULT '',
    `profile_picture` varchar(255) DEFAULT NULL,
    `cash` BIGINT NOT NULL DEFAULT 0,
    `bank` BIGINT NOT NULL DEFAULT 0,
    `last_daily` BIGINT NOT NULL DEFAULT 0,
    `card_number` varchar(16) DEFAULT NULL,
    `exp_month` tinyint(4) DEFAULT NULL,
    `exp_year` smallint(6) DEFAULT NULL,
    `card_status` varchar(16) NOT NULL DEFAULT 'active',
    KEY (charid)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]):format(T.money)
  dsql("ensure money", sql1)
  exports.oxmysql:execute(sql1)

  local sql2 = ([[CREATE TABLE IF NOT EXISTS `%s`(
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `discordid` varchar(64) DEFAULT '',
    `charid` varchar(100) DEFAULT '',
    `type` ENUM('checking','savings') NOT NULL,
    `balance` DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    `account_number` varchar(32) DEFAULT '',
    INDEX (charid)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]):format(T.accts)
  dsql("ensure accts", sql2)
  exports.oxmysql:execute(sql2)

  local sql3 = ([[CREATE TABLE IF NOT EXISTS `%s`(
    `id` INT AUTO_INCREMENT PRIMARY KEY,
    `discordid` varchar(64) DEFAULT '',
    `charid` varchar(100) DEFAULT '',
    `type` varchar(32) NOT NULL,
    `amount` DECIMAL(12,2) NOT NULL,
    `counterparty` varchar(255) DEFAULT '',
    `account_id` INT DEFAULT NULL,
    `description` text,
    `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    INDEX (charid), INDEX(discordid)
  ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]):format(T.tx)
  dsql("ensure tx", sql3)
  exports.oxmysql:execute(sql3)

  print('^2[econ]^7 tables ensured (debug='..tostring(DEBUG)..')')
end)

------------------------------------------------------------
-- FETCH HELPERS
------------------------------------------------------------
-- -------- fetch helpers (prefer charid; discord fallback with safe auto-repair) --------
local function fetchMoney(did, cid, cb)
  -- 1) Try strict charid match (authoritative per-character row)
  local sql1 = ("SELECT * FROM `%s` WHERE charid=? LIMIT 1"):format(T.money)
  local p1   = { cid }
  dsql("fetchMoney#1(charid)", sql1, p1)
  exports.oxmysql:query(sql1, p1, function(r1)
    if r1 and r1[1] then
      dprint("fetchMoney#1 -> HIT charid row: %s", _dump(r1[1], 2))
      return cb(r1[1])
    end

    -- 2) Fallback: pick the best discordid row (highest cash)
    local sql2 = ("SELECT * FROM `%s` WHERE discordid=? OR discordid=CONCAT('discord:',?) ORDER BY cash DESC LIMIT 1"):format(T.money)
    local p2   = { did or cid, did or cid }
    dsql("fetchMoney#2(discordid)", sql2, p2)
    exports.oxmysql:query(sql2, p2, function(r2)
      if r2 and r2[1] then
        local row = r2[1]
        dprint("fetchMoney#2 -> HIT discord row: %s", _dump(row, 2))

        -- 2a) Auto-repair: if that row has bad/empty charid, stamp the real cid
        if not row.charid or row.charid == '' or row.charid == '0' then
          local up = ("UPDATE `%s` SET charid=? WHERE (discordid=? OR discordid=CONCAT('discord:',?)) AND (charid='' OR charid='0') ORDER BY cash DESC LIMIT 1"):format(T.money)
          local pu = { cid, did or cid, did or cid }
          dsql("fetchMoney repair charid", up, pu)
          exports.oxmysql:execute(up, pu, function(aff)
            dprint("fetchMoney repair -> updated rows=%s (cid=%s)", tostring(aff), tostring(cid))
          end)
          row.charid = cid
        end

        return cb(row)
      end

      -- 3) Seed if nothing found at all
      local ins = ("INSERT INTO `%s` (discordid,charid,cash,bank,card_status) VALUES (?,?,?,?,?)"):format(T.money)
      local ip  = { did or '', cid, 0, 0, 'active' }
      dsql("fetchMoney seed", ins, ip)
      exports.oxmysql:insert(ins, ip, function()
        dprint("fetchMoney seed -> re-query")
        fetchMoney(did, cid, cb)
      end)
    end)
  end)
end

local function fetchAccounts(did, cid, cb)
  -- STRICTLY per-character to avoid cross-character bleed
  local sql = ("SELECT * FROM `%s` WHERE charid=? ORDER BY id"):format(T.accts)
  local params = { cid }
  dsql("fetchAccounts", sql, params)
  exports.oxmysql:query(sql, params, function(rows)
    dprint("fetchAccounts rows=%s", rows and #rows or 0)
    if rows and #rows > 0 then
      if DEBUG then
        for i,a in ipairs(rows) do dprint("acct[%d] -> %s", i, _dump(a, 2)) end
      end
      return cb(rows)
    end
    -- create default checking + savings
    local ins = ("INSERT INTO `%s` (discordid,charid,type,balance,account_number) VALUES (?,?,?,?,?),(?,?,?,?,?)"):format(T.accts)
    local now = os.time()
    local ip = { did or '', cid, 'checking', 0, 'CHK'..now,  did or '', cid, 'savings', 0, 'SVG'..now }
    dsql("fetchAccounts (seed)", ins, ip)
    exports.oxmysql:insert(ins, ip, function()
      dprint("fetchAccounts seeded -> re-query")
      fetchAccounts(did, cid, cb)
    end)
  end)
end

-- find first account ID of a given type (to avoid updating multiple rows)
local function firstAccountIdOfType(accts, typ)
  for _,a in ipairs(accts or {}) do
    if a.type == typ then
      dprint("firstAccountIdOfType(%s) -> %s", tostring(typ), tostring(a.id))
      return a.id
    end
  end
  dprint("firstAccountIdOfType(%s) -> nil", tostring(typ))
  return nil
end

------------------------------------------------------------
-- PUSH DATA (authoritative DB)
------------------------------------------------------------
local function pushData(src, err)
  local did, cid = getDiscordID(src), getCharID(src)
  if cid == '' then dprint("pushData: no CID for src=%s", tostring(src)); return end
  dprint("pushData start -> src=%s did=%s cid=%s", tostring(src), tostring(did), tostring(cid))

  fetchMoney(did, cid, function(m)
    fetchAccounts(did, cid, function(accts)
      local checking, savings = 0.0, 0.0
      for _,a in ipairs(accts) do
        if a.type == 'checking' then checking = checking + (tonumber(a.balance) or 0)
        elseif a.type == 'savings' then savings = savings + (tonumber(a.balance) or 0) end
      end
      local bank_total = checking + savings
      dprint("pushData balances -> checking=%.2f savings=%.2f bank_total=%.2f", checking, savings, bank_total)

      -- Transactions: per-character only
      local txsql = ("SELECT type,amount,description,account_id,counterparty,UNIX_TIMESTAMP(created_at) AS ts FROM `%s` WHERE charid=? ORDER BY id DESC LIMIT 50"):format(T.tx)
      local txp = { cid }
      dsql("pushData tx query", txsql, txp)
      exports.oxmysql:query(txsql, txp, function(txs)
        local money_in, money_out = 0, 0
        local tnow = os.date('*t'); local monthStart = os.time{year=tnow.year, month=tnow.month, day=1}
        for _,t in ipairs(txs or {}) do
          local amt = tonumber(t.amount) or 0
          -- Exclude internal moves from "income/expense"
          if (t.ts or 0) >= monthStart and t.type ~= 'transfer_internal' then
            if amt > 0 then money_in = money_in + amt else money_out = money_out + math.abs(amt) end
          end
        end
        dprint("pushData tx -> thisMonth in=%.2f out=%.2f tx_count=%s", money_in, money_out, txs and #txs or 0)

        local payload = {
          cash     = tonumber(m.cash) or 0,     -- from econ_user_money.cash
          checking = checking,
          savings  = savings,
          bank     = bank_total,                -- sum of accounts
          accounts = accts,
          transactions = (txs or {}),
          total_transactions = txs and #txs or 0,
          money_in = money_in, money_out = money_out,
          month_change = money_in - money_out,
          transferError = err
        }

        dprint("pushData payload -> cash=%s bank=%s (checking=%s savings=%s) transferError=%s",
          tostring(payload.cash), tostring(payload.bank), tostring(checking), tostring(savings), tostring(err))

        -- Update NUI
        dprint("Emit: my-bank-ui:updateData src=%s", tostring(src))
        TriggerClientEvent('my-bank-ui:updateData', src, payload)

        -- Update HUD (SPECIFIC DEBUG HERE)
        dprint("Emit: updateCashHUD src=%s CASH=%s BANK=%s", tostring(src), tostring(payload.cash), tostring(payload.bank))
        TriggerClientEvent('updateCashHUD', src, payload.cash, payload.bank)
      end)
    end)
  end)
end

------------------------------------------------------------
-- NUI BRIDGE
------------------------------------------------------------
RegisterNetEvent('my-bank-ui:getData', function()
  dprint("EVT my-bank-ui:getData src=%s", tostring(source))
  pushData(source)
end)

------------------------------------------------------------
-- DEPOSIT: cash -> checking
------------------------------------------------------------
RegisterNetEvent('my-bank-ui:deposit', function(data)
  local src = source
  dprint("EVT deposit src=%s data=%s", tostring(src), _dump(data, 2))
  with_lock(src, 'deposit', 800, function()
    local did, cid = getDiscordID(src), getCharID(src)
    local rawAmt = data and data.amount
    local amt = parseAmount(rawAmt)
    dprint("deposit -> cid=%s raw=%s parsed=%d", tostring(cid), tostring(rawAmt), amt)
    if amt <= 0 or cid == '' then notify(src,'error','Invalid deposit amount.'); return end

    -- HARD CHECK: make sure wallet has enough cash before moving to checking
    exports.oxmysql:query(("SELECT cash FROM `%s` WHERE charid=? LIMIT 1"):format(T.money), { cid }, function(r)
      local have = r and r[1] and tonumber(r[1].cash) or 0
      if have < amt then notify(src, 'error', 'Not enough cash in wallet.'); return end

      fetchAccounts(did, cid, function(accts)
        local chkId = firstAccountIdOfType(accts, 'checking')
        if not chkId then notify(src,'error','No checking account found.'); return end

        local sqlA = ("UPDATE `%s` SET cash=cash-? WHERE charid=?"):format(T.money)
        local pA = { amt, cid }
        dsql("deposit dec cash", sqlA, pA)
        exports.oxmysql:execute(sqlA, pA, function()
          local sqlB = ("UPDATE `%s` SET balance=balance+? WHERE id=?"):format(T.accts)
          local pB = { amt, chkId }
          dsql("deposit inc checking", sqlB, pB)
          exports.oxmysql:execute(sqlB, pB, function()
            logTx(cid, did, 'deposit',  amt, 'Deposit to checking', chkId)
            notify(src,'success',('Deposited $%d to checking'):format(amt))
            pushData(src)
          end)
        end)
      end)
    end)
  end)
end)


------------------------------------------------------------
-- WITHDRAW: checking -> cash
------------------------------------------------------------
RegisterNetEvent('my-bank-ui:withdraw', function(data)
  local src = source
  dprint("EVT withdraw src=%s data=%s", tostring(src), _dump(data, 2))
  with_lock(src, 'withdraw', 800, function()
    local did, cid = getDiscordID(src), getCharID(src)
    local rawAmt = data and data.amount
    local amt = parseAmount(rawAmt)
    dprint("withdraw -> cid=%s raw=%s parsed=%d", tostring(cid), tostring(rawAmt), amt)
    if amt <= 0 or cid == '' then notify(src,'error','Invalid withdraw amount.'); return end

    fetchAccounts(did, cid, function(accts)
      local chkId = firstAccountIdOfType(accts, 'checking')
      if not chkId then notify(src,'error','No checking account found.'); return end
      local q = ("SELECT balance FROM `%s` WHERE id=? LIMIT 1"):format(T.accts)
      local qp = { chkId }
      dsql("withdraw check balance", q, qp)
      exports.oxmysql:query(q, qp, function(r)
        local have = r and r[1] and tonumber(r[1].balance) or 0
        dprint("withdraw checking id=%s have=%.2f need=%d", tostring(chkId), have, amt)
        if have < amt then notify(src,'error','Not enough in checking.'); return end

        local u1 = ("UPDATE `%s` SET balance=balance-? WHERE id=?"):format(T.accts)
        local p1 = { amt, chkId }
        dsql("withdraw dec checking", u1, p1)
        exports.oxmysql:execute(u1, p1, function(a1)
          dprint("withdraw dec checking affected=%s", tostring(a1))
          local u2 = ("UPDATE `%s` SET cash=cash+? WHERE charid=?"):format(T.money)
          local p2 = { amt, cid }
          dsql("withdraw inc cash", u2, p2)
          exports.oxmysql:execute(u2, p2, function(a2)
            dprint("withdraw inc cash affected=%s", tostring(a2))
            logTx(cid, did, 'withdraw', -amt, 'Withdraw from checking', chkId)
            notify(src,'success',('Withdrew $%d to wallet'):format(amt))
            pushData(src)
          end)
        end)
      end)
    end)
  end)
end)

------------------------------------------------------------
-- EXTERNAL TRANSFER: wallet cash -> other charid
------------------------------------------------------------
RegisterNetEvent('my-bank-ui:transfer', function(data)
  local src = source
  dprint("EVT transfer (external) src=%s data=%s", tostring(src), _dump(data, 2))
  with_lock(src, 'transfer', 1000, function()
    local did, cid = getDiscordID(src), getCharID(src)
    local target  = tostring(data.target or '')
    local rawAmt  = data and data.amount
    local amt     = parseAmount(rawAmt)
    dprint("transfer external -> from=%s to=%s raw=%s parsed=%d", tostring(cid), tostring(target), tostring(rawAmt), amt)

    if amt <= 0 or cid == '' or target == '' then
      notify(src,'error','Invalid transfer.')
      nui(src,'transferResult',{success=false,error='Invalid transfer'})
      return pushData(src)
    end

    local q1 = ("SELECT charid FROM `%s` WHERE charid=? LIMIT 1"):format(T.money)
    local p1 = { target }
    dsql("transfer check target", q1, p1)
    exports.oxmysql:query(q1, p1, function(r)
      if not r or not r[1] then
        notify(src,'error','Target not found.')
        nui(src,'transferResult',{success=false,error='Target not found'})
        return pushData(src)
      end

      local q2 = ("SELECT cash FROM `%s` WHERE charid=? LIMIT 1"):format(T.money)
      local p2 = { cid }
      dsql("transfer get my cash", q2, p2)
      exports.oxmysql:query(q2, p2, function(me)
        local have = me and me[1] and tonumber(me[1].cash) or 0
        dprint("transfer external -> have=%s need=%s", tostring(have), tostring(amt))
        if have < amt then
          notify(src,'error','Not enough cash.')
          nui(src,'transferResult',{success=false,error='Not enough cash'})
          return pushData(src)
        end

        local u1 = ("UPDATE `%s` SET cash=cash-? WHERE charid=?"):format(T.money)
        local pU1 = { amt, cid }
        dsql("transfer dec sender cash", u1, pU1)
        exports.oxmysql:execute(u1, pU1, function(a1)
          dprint("transfer dec sender affected=%s", tostring(a1))
          local u2 = ("UPDATE `%s` SET cash=cash+? WHERE charid=?"):format(T.money)
          local pU2 = { amt, target }
          dsql("transfer inc target cash", u2, pU2)
          exports.oxmysql:execute(u2, pU2, function(a2)
            dprint("transfer inc target affected=%s", tostring(a2))
            logTx(cid, did, 'transfer_out', -amt, ('Transfer to %s'):format(target))
            notify(src,'success',('Transferred $%d to %s'):format(amt, target))
            nui(src,'transferResult',{success=true})
            pushData(src)
          end)
        end)
      end)
    end)
  end)
end)

------------------------------------------------------------
-- INTERNAL TRANSFER: cash <-> accounts and account <-> account
------------------------------------------------------------
RegisterNetEvent('my-bank-ui:transferInternal', function(data)
  local src = source
  dprint("EVT transferInternal src=%s data=%s", tostring(src), _dump(data, 2))
  with_lock(src, 'transferInternal', 1000, function()
    local did, cid = getDiscordID(src), getCharID(src)
    local from = tostring(data.from or '')
    local to   = tostring(data.to or '')
    local rawAmt = data and data.amount
    local amt  = parseAmount(rawAmt)
    dprint("transferInternal -> cid=%s from=%s to=%s raw=%s parsed=%d", tostring(cid), tostring(from), tostring(to), tostring(rawAmt), amt)

    if amt <= 0 or cid == '' or from == '' or to == '' then
      notify(src,'error','Invalid internal transfer.')
      nui(src,'transferResult',{success=false,error='Invalid internal transfer'})
      return pushData(src)
    end
    if from == to then
      notify(src,'error','Source and destination are the same.')
      nui(src,'transferResult',{success=false,error='Same source & destination'})
      return pushData(src)
    end

    fetchMoney(did, cid, function(m)
      fetchAccounts(did, cid, function(accts)

        local function getAcctById(id)
          for _,a in ipairs(accts) do if tonumber(a.id) == tonumber(id) then return a end end
        end
        local function resolveLabelToId(label)
          if label == 'checking' or label == 'savings' then
            return firstAccountIdOfType(accts, label)
          end
          return nil
        end
        local function balanceOf(label)
          if label == 'cash' then return tonumber(m.cash) or 0 end
          if label:sub(1,5) == 'acct:' then
            local a = getAcctById(tonumber(label:sub(6))); return a and tonumber(a.balance) or 0
          end
          local id = resolveLabelToId(label); if id then
            local a = getAcctById(id); return a and tonumber(a.balance) or 0
          end
          return 0
        end

        local haveFrom = balanceOf(from)
        dprint("transferInternal check funds -> from=%s have=%.2f need=%d", tostring(from), haveFrom, amt)
        if haveFrom < amt then
          notify(src,'error','Insufficient funds.')
          nui(src,'transferResult',{success=false,error='Insufficient funds'})
          return pushData(src)
        end

        local Q = {}
        local desc = ('Internal transfer %s -> %s'):format(from, to)

        -- debit
        if from == 'cash' then
          table.insert(Q, { ("UPDATE `%s` SET cash=cash-? WHERE charid=?"):format(T.money), { amt, cid }, "dec cash" })
        elseif from:sub(1,5) == 'acct:' or from == 'checking' or from == 'savings' then
          local id = (from:sub(1,5) == 'acct:') and tonumber(from:sub(6)) or resolveLabelToId(from)
          if not id then notify(src,'error','Source account not found.'); nui(src,'transferResult',{success=false,error='Source account not found'}); return end
          table.insert(Q, { ("UPDATE `%s` SET balance=balance-? WHERE id=?"):format(T.accts), { amt, id }, "dec acct "..tostring(id) })
        else
          notify(src,'error','Invalid source.'); nui(src,'transferResult',{success=false,error='Invalid source'}); return
        end

        -- credit
        if to == 'cash' then
          table.insert(Q, { ("UPDATE `%s` SET cash=cash+? WHERE charid=?"):format(T.money), { amt, cid }, "inc cash" })
        elseif to:sub(1,5) == 'acct:' or to == 'checking' or to == 'savings' then
          local id = (to:sub(1,5) == 'acct:') and tonumber(to:sub(6)) or resolveLabelToId(to)
          if not id then notify(src,'error','Destination account not found.'); nui(src,'transferResult',{success=false,error='Destination account not found'}); return end
          table.insert(Q, { ("UPDATE `%s` SET balance=balance+? WHERE id=?"):format(T.accts), { amt, id }, "inc acct "..tostring(id) })
        else
          notify(src,'error','Invalid destination.'); nui(src,'transferResult',{success=false,error='Invalid destination'}); return
        end

        local function exec(i)
          if i > #Q then
            logTx(cid, did, 'transfer_internal', -amt, desc)
            notify(src,'success',('Moved $%d (%s → %s)'):format(amt, from, to))
            nui(src,'transferResult',{success=true})
            return pushData(src)
          end
          local sql, params, tag = Q[i][1], Q[i][2], Q[i][3]
          dsql("transferInternal step "..tostring(i).." "..tostring(tag), sql, params)
          exports.oxmysql:execute(sql, params, function(aff)
            dprint("transferInternal step %s affected=%s", tostring(i), tostring(aff))
            exec(i+1)
          end)
        end
        exec(1)
      end)
    end)
  end)
end)
