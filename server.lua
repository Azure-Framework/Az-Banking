-- server.lua 
-- Banking server logic (MySQL-backed). Provides accounts (checking + savings with account_number)
-- Cards table, pin storage, transferInternal accepting acct:<id> values.

local M = {
  money = 'econ_user_money',
  accts = 'econ_accounts',
  pays  = 'econ_payments',
  cards = 'econ_cards',
  dept  = 'econ_departments',
  transactions = 'econ_transactions'    -- <- new
}

local SAVINGS_APR = 0.05
local DISPATCH_BLIP_SECONDS = 20
local DEBUG_DISPATCH = true

local function getDiscordID(src)
  for _, id in ipairs(GetPlayerIdentifiers(src)) do
    if id and id:sub(1,8) == 'discord:' then
      return (id:sub(9):gsub("%s+", "")) -- numeric part
    end
  end
  for _, id in ipairs(GetPlayerIdentifiers(src)) do
    if id and id:match('^%d+$') then return id end
  end
  return ""
end

local function getCharID(src)
  local cid = nil
  if exports['Az-Framework'] and exports['Az-Framework'].GetPlayerCharacter then
    cid = exports['Az-Framework']:GetPlayerCharacter(src)
  end
  if not cid or cid == '' then
    for _, id in ipairs(GetPlayerIdentifiers(src)) do
      if id and id:match('^%d+$') then cid = id; break end
    end
  end
  return cid and tostring(cid) or ''
end

-- Small helper to log when debug
local function DBG(...)
  if DEBUG_DISPATCH then print(string.format(...)) end
end

-- helper: try to resolve a transfer target to a charid (calls cb(characterId or nil, reasonIfAny))
local function resolveTargetToCharid(tgt, cb)
  if not tgt or tgt == '' then return cb(nil, "empty target") end

  -- 1) if it already looks like a charid (numeric)
  if tostring(tgt):match("^%d+$") then
    -- verify exists in econ_user_money
    exports.oxmysql:query(string.format("SELECT charid FROM `%s` WHERE charid = ? LIMIT 1", M.money), { tgt }, function(rows)
      if rows and rows[1] and rows[1].charid then
        return cb(rows[1].charid)
      else
        -- maybe it's an account_number in econ_accounts
        exports.oxmysql:query(string.format("SELECT charid FROM `%s` WHERE account_number = ? LIMIT 1", M.accts), { tgt }, function(ar)
          if ar and ar[1] and ar[1].charid and ar[1].charid ~= '' then
            return cb(ar[1].charid)
          end
          -- last attempt: maybe stored as discordid
          exports.oxmysql:query(string.format("SELECT charid FROM `%s` WHERE discordid = ? LIMIT 1", M.money), { tgt }, function(dr)
            if dr and dr[1] and dr[1].charid then cb(dr[1].charid) else cb(nil, "target not found") end
          end)
        end)
      end
    end)
  else
    -- not purely numeric: try discord: or account strings
    -- try discord:... (strip possible 'discord:' prefix)
    local just = tgt:gsub("^discord:", "")
    exports.oxmysql:query(string.format("SELECT charid FROM `%s` WHERE discordid = ? OR discordid = CONCAT('discord:', ?) LIMIT 1", M.money), { just, just }, function(rows)
      if rows and rows[1] and rows[1].charid then return cb(rows[1].charid) end
      -- try account_number on econ_accounts
      exports.oxmysql:query(string.format("SELECT charid FROM `%s` WHERE account_number = ? LIMIT 1", M.accts), { tgt }, function(ar)
        if ar and ar[1] and ar[1].charid then return cb(ar[1].charid) end
        cb(nil, "target not found")
      end)
    end)
  end
end

-- logTransaction helper: record a transaction row (non-blocking)
local function logTransaction(charid, discordid, ttype, amount, counterparty, account_id, description)
  -- defensive coercions
  local cid = tostring(charid or "")
  local did = tostring(discordid or "")
  local typ = tostring(ttype or "")
  local amt = tonumber(amount) or 0
  local cp  = tostring(counterparty or "")
  local aid = tonumber(account_id) or 0
  local desc = tostring(description or "")

  if not exports.oxmysql or not exports.oxmysql.insert then
    DBG("[econ] logTransaction: oxmysql.insert missing, skipping insert")
    return
  end

  -- Insert row (fire-and-forget)
  exports.oxmysql:insert(
    string.format("INSERT INTO `%s` (discordid,charid,type,amount,counterparty,account_id,description) VALUES (?,?,?,?,?,?,?)", M.transactions),
    { did, cid, typ, amt, cp, aid, desc },
    function(_) end
  )
end



-- helper: ensure a column exists (definition = full "`col` TYPE ...")
local function ensureColumn(tableName, columnName, definition, cb)
  exports.oxmysql:query([[
    SELECT COLUMN_NAME
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = ?
      AND COLUMN_NAME = ?
  ]], { tableName, columnName }, function(rows)
    if not rows or #rows == 0 then
      print(("^3[econ]^0 %s.%s missing - adding now..."):format(tableName, columnName))
      exports.oxmysql:execute(("ALTER TABLE `%s` ADD %s"):format(tableName, definition), {}, function()
        print(("^2[econ]^0 Added %s.%s (ALTER TABLE executed)."):format(tableName, columnName))
        if cb then cb(true) end
      end)
    else
      DBG("^2[econ]^0 %s.%s already present.", tableName, columnName)
      if cb then cb(false) end
    end
  end)
end

-- unique generators with DB collision checks
local function genAccountNumber(prefix)
  local rand = math.random(100, 999)
  return (prefix or "AC") .. tostring(os.time()):sub(-6) .. tostring(rand)
end

local function genCandidateCardNumber()
  -- simple pseudo-random 16-digit starting with 4 (Visa-like) for readability
  local a = tostring(math.random(4000,4999))
  local b = tostring(math.random(1000,9999))
  local c = tostring(math.random(1000,9999))
  local d = tostring(math.random(1000,9999))
  return a .. b .. c .. d
end

local function ensureUniqueAccountNumber(prefix, cb, attempts)
  attempts = attempts or 1
  if attempts > 10 then return cb(nil) end
  local cand = genAccountNumber(prefix)
  exports.oxmysql:query(string.format("SELECT id FROM `%s` WHERE account_number = ? LIMIT 1", M.accts), { cand }, function(rows)
    if rows and #rows > 0 then
      ensureUniqueAccountNumber(prefix, cb, attempts + 1)
    else
      cb(cand)
    end
  end)
end

local function ensureUniqueCardNumber(cb, attempts)
  attempts = attempts or 1
  if attempts > 12 then return cb(nil) end
  local cand = genCandidateCardNumber()
  exports.oxmysql:query(string.format("SELECT id FROM `%s` WHERE card_number = ? LIMIT 1", M.cards), { cand }, function(rows)
    if rows and #rows > 0 then
      ensureUniqueCardNumber(cb, attempts + 1)
    else
      -- also check econ_user_money just in case
      exports.oxmysql:query(string.format("SELECT charid FROM `%s` WHERE card_number = ? LIMIT 1", M.money), { cand }, function(rows2)
        if rows2 and #rows2 > 0 then
          ensureUniqueCardNumber(cb, attempts + 1)
        else
          cb(cand)
        end
      end)
    end
  end)
end

-- ensure tables exist
AddEventHandler('onResourceStart', function(resourceName)
  if GetCurrentResourceName() ~= resourceName then return end

  -- econ_user_money
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

      -- econ_transactions: keeps a simple transaction history for UI
  exports.oxmysql:execute(string.format([[ 
    CREATE TABLE IF NOT EXISTS `%s` (
      `id` INT AUTO_INCREMENT PRIMARY KEY,
      `discordid` VARCHAR(64) DEFAULT '',
      `charid` VARCHAR(100) DEFAULT '',
      `type` VARCHAR(32) NOT NULL,
      `amount` DECIMAL(12,2) NOT NULL,
      `counterparty` VARCHAR(255) DEFAULT '',
      `account_id` INT DEFAULT NULL,
      `description` TEXT,
      `created_at` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
      INDEX (charid),
      INDEX (discordid)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
  ]], M.transactions))  -- <--- fixed: added missing closing parenthesis here

  -- econ_accounts (added account_number column)
  exports.oxmysql:execute(string.format([[
    CREATE TABLE IF NOT EXISTS `%s` (
      `id` INT AUTO_INCREMENT PRIMARY KEY,
      `discordid` VARCHAR(64) DEFAULT '',
      `charid` VARCHAR(100) DEFAULT '',
      `type` ENUM('checking','savings') NOT NULL,
      `balance` BIGINT NOT NULL DEFAULT 0,
      `account_number` VARCHAR(32) DEFAULT '',
      INDEX (charid)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]
    , M.accts))

  -- econ_payments
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

  -- econ_cards
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

  -- econ_departments
  exports.oxmysql:execute(string.format([[
    CREATE TABLE IF NOT EXISTS `%s` (
      `discordid` VARCHAR(64) DEFAULT '',
      `charid` VARCHAR(100) DEFAULT '',
      `paycheck` BIGINT NOT NULL DEFAULT 0,
      PRIMARY KEY (charid)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]]
    , M.dept))

  -- ensure pin_hash exists in user_characters
  exports.oxmysql:query([[
    SELECT COLUMN_NAME
    FROM INFORMATION_SCHEMA.COLUMNS
    WHERE TABLE_SCHEMA = DATABASE()
      AND TABLE_NAME = ?
      AND COLUMN_NAME = ?
  ]], { 'user_characters', 'pin_hash' }, function(rows)
    if not rows or #rows == 0 then
      print("^3[econ]^0 pin_hash column missing in user_characters - adding now...")
      exports.oxmysql:execute([[ALTER TABLE `user_characters` ADD COLUMN `pin_hash` VARCHAR(128) DEFAULT '' ]], {}, function(affected)
        print("^2[econ]^0 Added user_characters.pin_hash (ALTER TABLE executed).")
      end)
    else
      print("^2[econ]^0 user_characters.pin_hash already present.")
    end
  end)

  -- -------------------------
  -- Ensure/alter additional missing columns and backfill values
  -- -------------------------
  -- Add columns if missing (economy tables)
  ensureColumn(M.accts, "account_number", "`account_number` VARCHAR(32) DEFAULT ''")
  ensureColumn(M.money, "card_number", "`card_number` VARCHAR(16) DEFAULT NULL")
  ensureColumn(M.money, "exp_month", "`exp_month` TINYINT(4) DEFAULT NULL")
  ensureColumn(M.money, "exp_year", "`exp_year` SMALLINT(6) DEFAULT NULL")
  ensureColumn(M.money, "card_status", "`card_status` VARCHAR(16) NOT NULL DEFAULT 'active'")
  ensureColumn(M.cards, "status", "`status` VARCHAR(16) NOT NULL DEFAULT 'active'")

  -- After ensuring columns, backfill missing account numbers and card numbers
  Citizen.CreateThread(function()
    Citizen.Wait(1000) -- small delay to allow previous ALTERs to finish

    -- Backfill missing account numbers per account row (treat placeholders as missing)
    exports.oxmysql:query(string.format([[
      SELECT id,`type` FROM `%s`
      WHERE account_number IS NULL
         OR account_number = ''
         OR account_number = '0000000000'
         OR account_number = '0'
         OR account_number = '00000000'
    ]], M.accts), {}, function(rows)
      if rows and #rows > 0 then
        print(("^3[econ]^0 Backfilling %d account(s) missing account_number (including placeholders)..."):format(#rows))
        for _, r in ipairs(rows) do
          local prefix = "AC"
          if r.type == 'checking' then prefix = "CHK" elseif r.type == 'savings' then prefix = "SVG" end
          ensureUniqueAccountNumber(prefix, function(newAcctNum)
            if newAcctNum then
              exports.oxmysql:execute(string.format("UPDATE `%s` SET account_number = ? WHERE id = ?", M.accts), { newAcctNum, r.id })
              DBG("^2[econ]^0 Updated account id=%s -> account_number=%s", tostring(r.id), tostring(newAcctNum))
            else
              print(("^1[econ]^0 Failed to generate unique account number for account id=%s (too many attempts)"):format(tostring(r.id)))
            end
          end)
        end
      else
        DBG("^2[econ]^0 No accounts need account_number backfill (including placeholders).")
      end
    end)

    -- Backfill missing card rows (econ_cards)
    exports.oxmysql:query(string.format("SELECT id,charid,discordid,card_number FROM `%s` WHERE card_number IS NULL OR card_number = ''", M.cards), {}, function(rows)
      if rows and #rows > 0 then
        print(("^3[econ]^0 Backfilling %d card row(s) missing card_number..."):format(#rows))
        for _, r in ipairs(rows) do
          ensureUniqueCardNumber(function(newCard)
            if newCard then
              local month = math.random(1,12)
              local year = tonumber(os.date("%Y")) + 3
              exports.oxmysql:execute(string.format("UPDATE `%s` SET card_number = ?, exp_month = ?, exp_year = ?, status = ? WHERE id = ?", M.cards),
                { newCard, month, year, 'active', r.id })
              DBG("^2[econ]^0 Updated card id=%s -> card_number=%s", tostring(r.id), tostring(newCard))
              -- also mirror into econ_user_money rows if present
              exports.oxmysql:execute(string.format("UPDATE `%s` SET card_number = ?, exp_month = ?, exp_year = ?, card_status = ? WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?)", M.money),
                { newCard, month, year, 'active', r.charid or '', r.discordid or '', r.discordid or '' })
            else
              print(("^1[econ]^0 Failed to generate unique card number for card id=%s"):format(tostring(r.id)))
            end
          end)
        end
      else
        DBG("^2[econ]^0 No econ_cards rows need backfill.")
      end
    end)

    -- Ensure econ_user_money rows have a card. For each money row missing card_number, try to find matching econ_cards row, else create new card
    exports.oxmysql:query(string.format("SELECT charid,discordid FROM `%s` WHERE (card_number IS NULL OR card_number = '')", M.money), {}, function(rows)
      if rows and #rows > 0 then
        print(("^3[econ]^0 Backfilling card info for %d user money row(s)..."):format(#rows))
        for _, r in ipairs(rows) do
          local cid = r.charid or ''
          local did = r.discordid or ''

          -- try to find a card for this character
          exports.oxmysql:query(string.format("SELECT id,card_number,exp_month,exp_year,status FROM `%s` WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?) LIMIT 1", M.cards), { cid, did or cid, did or cid }, function(cardRows)
            if cardRows and cardRows[1] and cardRows[1].card_number and cardRows[1].card_number ~= '' then
              local c = cardRows[1]
              exports.oxmysql:execute(string.format("UPDATE `%s` SET card_number = ?, exp_month = ?, exp_year = ?, card_status = ? WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?)", M.money),
                { c.card_number, c.exp_month, c.exp_year, c.status or 'active', cid, did or cid, did or cid })
              DBG("^2[econ]^0 Mirrored card %s into econ_user_money for charid=%s", tostring(c.card_number), tostring(cid))
            else
              -- create a new card and mirror it
              ensureUniqueCardNumber(function(newCard)
                if not newCard then
                  print(("^1[econ]^0 Failed to generate new card for charid=%s"):format(tostring(cid)))
                  return
                end
                local month = math.random(1,12)
                local year = tonumber(os.date("%Y")) + 3
                exports.oxmysql:insert(string.format("INSERT INTO `%s` (discordid,charid,card_number,exp_month,exp_year,status) VALUES (?,?,?,?,?,?)", M.cards),
                  { did or '', cid, newCard, month, year, 'active' },
                  function()
                    exports.oxmysql:execute(string.format("UPDATE `%s` SET card_number = ?, exp_month = ?, exp_year = ?, card_status = ? WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?)", M.money),
                      { newCard, month, year, 'active', cid, did or cid, did or cid })
                    DBG("^2[econ]^0 Created and mirrored new card %s for charid=%s", tostring(newCard), tostring(cid))
                  end)
              end)
            end
          end)
        end
      else
        DBG("^2[econ]^0 No econ_user_money rows need card backfill.")
      end
    end)

    -- Immediate one-shot placeholder-fix: if some rows already have '0000000000' or similar, patch them right away
    Citizen.Wait(500) -- small extra wait
    exports.oxmysql:query(string.format([[
      SELECT id, `type` FROM `%s`
      WHERE account_number = '0000000000' OR account_number = '0' OR account_number = '00000000'
    ]], M.accts), {}, function(rows)
      if rows and #rows > 0 then
        print(("^3[econ]^0 Immediate placeholder-fix: %d accounts to update..."):format(#rows))
        for _, r in ipairs(rows) do
          local prefix = "AC"
          if r.type == 'checking' then prefix = "CHK" elseif r.type == 'savings' then prefix = "SVG" end
          ensureUniqueAccountNumber(prefix, function(newAcct)
            if newAcct then
              exports.oxmysql:execute(string.format("UPDATE `%s` SET account_number = ? WHERE id = ?", M.accts), { newAcct, r.id })
              print(("^2[econ]^0 Fixed placeholder account id=%s -> %s"):format(tostring(r.id), tostring(newAcct)))
            else
              print(("^1[econ]^0 Failed to fix placeholder for account id=%s"):format(tostring(r.id)))
            end
          end)
        end
      else
        DBG("^2[econ]^0 No placeholder accounts found in immediate-fix.")
      end
    end)

  end)

  print("^2[econ]^0 Tables ensured (charid-aware) and migration tasks queued.")
end)

-- fetchMoney
local function fetchMoney(did, cid, cb)
  if not cid or cid == '' then return cb(nil) end
  if DEBUG_DISPATCH then print(("[econ] fetchMoney called did=%s cid=%s"):format(tostring(did), tostring(cid))) end

  exports.oxmysql:query(
    string.format("SELECT * FROM `%s` WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?) LIMIT 1", M.money),
    { cid, did or cid, did or cid },
    function(res)
      if res and res[1] then
        if did and did ~= '' and res[1].discordid ~= did then
          exports.oxmysql:execute(
            string.format("UPDATE `%s` SET discordid = ? WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?)", M.money),
            { did, cid, did, did }
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

-- fetchAccounts(did, cid, cb)
-- Returns an array of account rows for the given identifiers. Ensures any placeholder/zero account_number
-- values are replaced with a unique account_number before calling cb(accts).
-- fetchAccounts(did, cid, cb)
-- Returns an array of account rows for the given identifiers. Ensures any placeholder/zero account_number
-- values are replaced with a unique account_number before calling cb(accts).
local function fetchAccounts(did, cid, cb)
  if not cid or cid == '' then return cb({}) end
  if DEBUG_DISPATCH then print(("[econ] fetchAccounts called did=%s cid=%s"):format(tostring(did), tostring(cid))) end

  exports.oxmysql:query(
    string.format("SELECT id,discordid,charid,type,balance,account_number FROM `%s` WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?) ORDER BY id", M.accts),
    { cid, did or cid, did or cid },
    function(accts)
      -- If no accounts, create default checking + savings with generated numbers
      if #accts == 0 then
        -- generate candidate numbers first
        ensureUniqueAccountNumber("CHK", function(acc1)
          ensureUniqueAccountNumber("SVG", function(acc2)
            -- re-check right before insert to avoid race with other concurrent calls
            exports.oxmysql:query(string.format("SELECT id FROM `%s` WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?) LIMIT 1", M.accts),
              { cid, did or cid, did or cid }, function(checkRows)
                if checkRows and #checkRows > 0 then
                  -- someone else created accounts in the meantime; re-run fetch to get them
                  return fetchAccounts(did, cid, cb)
                end

                -- safe to insert the two accounts
                exports.oxmysql:insert(
                  string.format("INSERT INTO `%s` (discordid,charid,type,balance,account_number) VALUES (?,?,?,?,?),(?,?,?,?,?)", M.accts),
                  { did or '', cid, 'checking', 0, acc1, did or '', cid, 'savings', 0, acc2 },
                  function()
                    -- re-run to fetch the newly inserted rows
                    fetchAccounts(did, cid, cb)
                  end
                )
            end)
          end)
        end)
        return
      end

      -- update discordid/charid and compute savings APR info for the returned rows
      for _, acct in ipairs(accts) do
        if (not acct.discordid or acct.discordid == '') and did and did ~= '' then
          exports.oxmysql:execute(string.format("UPDATE `%s` SET discordid = ? WHERE id = ?", M.accts), { did, acct.id })
        end
        if (not acct.charid or acct.charid == '') and cid and cid ~= '' then
          exports.oxmysql:execute(string.format("UPDATE `%s` SET charid = ? WHERE id = ?", M.accts), { cid, acct.id })
        end
        if acct.type == 'savings' then
          local rate = SAVINGS_APR / 365
          acct.apr = SAVINGS_APR
          acct.daily_interest = tonumber(acct.balance) * rate
        end
      end

      -- Fix placeholder account_number values (empty or all-zero strings) before returning
      local pendingFixes = 0
      for _, acct in ipairs(accts) do
        local an = acct.account_number or ""
        if an == '' or tostring(an):match('^0+$') then
          pendingFixes = pendingFixes + 1
          local prefix = "AC"
          if acct.type == 'checking' then prefix = "CHK"
          elseif acct.type == 'savings' then prefix = "SVG" end

          ensureUniqueAccountNumber(prefix, function(newAcctNum)
            if newAcctNum then
              exports.oxmysql:execute(string.format("UPDATE `%s` SET account_number = ? WHERE id = ?", M.accts),
                { newAcctNum, acct.id }, function()
                  acct.account_number = newAcctNum
                  pendingFixes = pendingFixes - 1
                  if pendingFixes == 0 then cb(accts) end
              end)
            else
              -- couldn't generate unique number; still count down to avoid hang
              pendingFixes = pendingFixes - 1
              if pendingFixes == 0 then cb(accts) end
            end
          end)
        end
      end

      if pendingFixes == 0 then
        cb(accts)
      end
    end
  )
end


-- fetchCards(did, cid, cb)
-- Ensures a valid card exists for the character (creates one if missing). Mirrors card info into econ_user_money.
local function fetchCards(did, cid, cb)
  if not cid or cid == '' then return cb({}) end
  if DEBUG_DISPATCH then print(("[econ] fetchCards called did=%s cid=%s"):format(tostring(did), tostring(cid))) end

  exports.oxmysql:query(
    string.format("SELECT * FROM `%s` WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?) LIMIT 1", M.cards),
    { cid, did or cid, did or cid },
    function(cards)
      -- No card rows -> create one and mirror into econ_user_money
      if #cards == 0 then
        ensureUniqueCardNumber(function(num)
          if not num then
            -- failed to generate; return empty
            return cb({})
          end
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
                function() cb({ { card_number = num, exp_month = month, exp_year = year, status = status } }) end
              )
            end
          )
        end)
        return
      end

      -- Have at least one card row
      local c = cards[1]

      -- If card_number is missing or all zeros, regenerate and mirror
      if not c.card_number or c.card_number == '' or tostring(c.card_number):match('^0+$') then
        ensureUniqueCardNumber(function(newNum)
          if not newNum then
            -- fallback: update econ_user_money with existing values and return original rows
            exports.oxmysql:execute(
              string.format("UPDATE `%s` SET card_number=?,exp_month=?,exp_year=?,card_status=?,discordid=? WHERE charid=?", M.money),
              { c.card_number or '', c.exp_month, c.exp_year, c.status or 'active', did or '', cid },
              function() cb(cards) end
            )
            return
          end
          local month = math.random(1,12)
          local year  = tonumber(os.date("%Y")) + 3
          local status = 'active'
          -- update cards row
          exports.oxmysql:execute(string.format("UPDATE `%s` SET card_number = ?, exp_month = ?, exp_year = ?, status = ? WHERE id = ?", M.cards),
            { newNum, month, year, status, c.id }, function()
              -- mirror into econ_user_money
              exports.oxmysql:execute(string.format("UPDATE `%s` SET card_number = ?, exp_month = ?, exp_year = ?, card_status = ? WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?)", M.money),
                { newNum, month, year, status, cid, did or cid, did or cid }, function()
                  cb({ { card_number = newNum, exp_month = month, exp_year = year, status = status } })
                end)
            end)
        end)
        return
      end

      -- Normal path: ensure discordid/charid present and mirror into econ_user_money, then return card(s)
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
      if (not c.charid or c.charid == '') and cid and cid ~= '' then
        exports.oxmysql:execute(
          string.format("UPDATE `%s` SET charid = ? WHERE id = ?", M.cards),
          { cid, c.id }
        )
      end

      exports.oxmysql:execute(
        string.format("UPDATE `%s` SET card_number=?,exp_month=?,exp_year=?,card_status=?,discordid=? WHERE charid=?", M.money),
        { c.card_number, c.exp_month, c.exp_year, c.status, did or '', cid },
        function() cb(cards) end
      )
    end
  )
end


local function fetchDepartment(did, cid, cb)
  if not cid or cid == '' then return cb() end
  exports.oxmysql:query(
    string.format("SELECT discordid,charid,paycheck FROM `%s` WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?) LIMIT 1", M.dept),
    { cid, did or cid, did or cid },
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
            string.format("UPDATE `%s` SET discordid = ? WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?)", M.dept),
            { did, cid, did, did }
          )
        end
        if (not rows[1].charid or rows[1].charid == '') and cid and cid ~= '' then
          exports.oxmysql:execute(
            string.format("UPDATE `%s` SET charid = ? WHERE discordid = ? OR discordid = CONCAT('discord:', ?)", M.dept),
            { cid, did or cid, did or cid }
          )
        end
        cb(rows)
      end
    end
  )
end

-- Push data to client (fixed nesting & transaction totals)
local function pushData(src, errMsg)
  local did = getDiscordID(src)
  local cid = getCharID(src)
  if cid == '' then return end

  if DEBUG_DISPATCH then
    print(("[econ] pushData identifiers: src=%s discord=%s charid=%s"):format(tostring(src), tostring(did), tostring(cid)))
  end

  fetchCards(did, cid, function()
    fetchMoney(did, cid, function(m)
      fetchAccounts(did, cid, function(accts)
        local checking_sum = 0
        local savings_sum = 0
        for _, acct in ipairs(accts) do
          local bal = tonumber(acct.balance) or 0
          if acct.type == 'checking' then
            checking_sum = checking_sum + bal
          elseif acct.type == 'savings' then
            savings_sum = savings_sum + bal
          end
        end

        -- payments
        exports.oxmysql:query(
          string.format("SELECT payee,amount,schedule_date FROM `%s` WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?) ORDER BY schedule_date", M.pays),
          { cid, did or cid, did or cid },
          function(pays)
            -- cards
            exports.oxmysql:query(
              string.format("SELECT card_number,exp_month,exp_year,status FROM `%s` WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?) LIMIT 1", M.cards),
              { cid, did or cid, did or cid },
              function(cds)
                -- department/paycheck
                exports.oxmysql:query(
                  string.format("SELECT paycheck FROM `%s` WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?) LIMIT 1", M.dept),
                  { cid, did or cid, did or cid },
                  function(dr)
                    -- pin hash
                    exports.oxmysql:query(
                      [[ SELECT pin_hash FROM `user_characters` WHERE charid = ? OR discordid = ? LIMIT 1 ]],
                      { cid, did or cid },
                      function(pinRows)
                        local pin_hash_stored = pinRows and pinRows[1] and pinRows[1].pin_hash or ''
                        local dept_pay = dr and dr[1] and dr[1].paycheck or 0
                        local cardNum = (cds and cds[1] and cds[1].card_number) or (m and m.card_number) or ''

                        -- attach card number to savings accounts so UI can show it
                        for _, acct in ipairs(accts) do
                          if acct.type == 'savings' then acct.card_number = cardNum end
                        end

                        -- build initial payload (without transactions)
                        local payload = {
                          cash                = tonumber(m.cash) or 0,
                          checking            = tonumber(checking_sum) or 0,
                          savings             = tonumber(savings_sum) or 0,
                          bank                = ((tonumber(checking_sum) or 0) + (tonumber(savings_sum) or 0)),
                          card_number         = m.card_number or "",
                          exp_month           = m.exp_month or 0,
                          exp_year            = m.exp_year or 0,
                          card_status         = m.card_status or "active",
                          department_paycheck = dept_pay,
                          accounts            = accts,
                          payments            = pays,
                          cards               = cds,
                          profile_picture     = m.profile_picture or "",
                          has_pin             = (pin_hash_stored and pin_hash_stored ~= '')
                        }
                        if errMsg then payload.transferError = errMsg end

                        -- Query recent transactions and attach
                        exports.oxmysql:query(
                          string.format("SELECT type,amount,counterparty,account_id,description,UNIX_TIMESTAMP(created_at) AS ts FROM `%s` WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?) ORDER BY created_at DESC LIMIT 50", M.transactions),
                          { cid, did or cid, did or cid },
                          function(txrows)
                            local txs = {}
                            local money_in = 0
                            local money_out = 0
                            local total_tx = 0

                            -- compute start of current month (server local time)
                            local now = os.time()
                            local now_t = os.date("*t", now)
                            local month_start = os.time{ year = now_t.year, month = now_t.month, day = 1, hour = 0, min = 0, sec = 0 }

                            local function isIncomingType(typ)
                              if not typ then return false end
                              typ = tostring(typ):lower()
                              if typ:find("deposit") or typ:find("_in") or typ:match("in$") then
                                return true
                              end
                              return false
                            end

                            if txrows and #txrows > 0 then
                              total_tx = #txrows
                              for _, tr in ipairs(txrows) do
                                local amt = tonumber(tr.amount) or 0
                                local incoming = isIncomingType(tr.type)
                                local ts = tonumber(tr.ts) or 0
                                if ts >= month_start then
                                  if incoming then money_in = money_in + amt else money_out = money_out + amt end
                                end
                                local displayAmt = incoming and amt or -amt
                                table.insert(txs, {
                                  type = tr.type,
                                  amount = tostring(displayAmt),
                                  counterparty = tr.counterparty or '',
                                  account_id = tr.account_id or 0,
                                  description = tr.description or '',
                                  timestamp = (tr.ts and tonumber(tr.ts) * 1000) or nil
                                })
                              end
                            end

                            -- Attach computed fields
                            payload.transactions = txs
                            payload.total_transactions = total_tx
                            payload.money_in = money_in
                            payload.money_out = money_out
                            payload.month_change = (money_in - money_out)

                            -- debug printing
                            if DEBUG_DISPATCH then
                              print(("[econ]^0 pushData txs=%d money_in=%0.2f money_out=%0.2f month_change=%0.2f"):format(#txs, money_in, money_out, payload.month_change))
                              local ok, s = pcall(function() return json and json.encode and json.encode(payload) or tostring(payload) end)
                              if ok then
                                print(("^2[econ]^0 pushData -> src=%s payload=%s"):format(tostring(src), s))
                              else
                                print(("^1[econ]^0 pushData -> src=%s payload (failed to encode)"):format(tostring(src)))
                              end
                            end

                            TriggerClientEvent('my-bank-ui:updateData', src, payload)
                            TriggerClientEvent('updateCashHUD', src, payload.cash, payload.bank)
                          end
                        ) -- end transactions query
                      end
                    ) -- end pinRows query
                  end
                ) -- end dept query
              end
            ) -- end cards query
          end
        ) -- end payments query
      end) -- end fetchAccounts callback
    end) -- end fetchMoney callback
  end) -- end fetchCards callback
end



-- Ensure rows on connect
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

-- RPCs
RegisterServerEvent('my-bank-ui:getData', function() pushData(source) end)

-- setPin
RegisterServerEvent('my-bank-ui:setPin')
AddEventHandler('my-bank-ui:setPin', function(data)
  local src = source
  local cid = getCharID(src)
  local did = getDiscordID(src)
  local pin_hash = tostring(data.pin_hash or "")
  if cid == '' then
    TriggerClientEvent('my-bank-ui:pinSet', src, false, "Character not found.")
    return
  end
  if pin_hash == "" or #pin_hash < 10 then
    TriggerClientEvent('my-bank-ui:pinSet', src, false, "Invalid PIN hash.")
    return
  end

  exports.oxmysql:query("SELECT id FROM `user_characters` WHERE charid = ? LIMIT 1", { cid }, function(rows)
    if rows and rows[1] then
      exports.oxmysql:execute("UPDATE `user_characters` SET pin_hash = ?, discordid = ? WHERE charid = ?", { pin_hash, did or '', cid }, function()
        TriggerClientEvent('my-bank-ui:pinSet', src, true, "PIN created.")
        pushData(src)
      end)
    else
      exports.oxmysql:insert("INSERT INTO `user_characters` (discordid,charid,name,active_department,license_status,pin_hash) VALUES (?,?,?,?,?,?)",
        { did or '', cid, '', '', 'UNKNOWN', pin_hash },
        function()
          TriggerClientEvent('my-bank-ui:pinSet', src, true, "PIN created (new user_characters row inserted).")
          pushData(src)
        end)
    end
  end)
end)

-- verifyPin
RegisterServerEvent('my-bank-ui:verifyPin')
AddEventHandler('my-bank-ui:verifyPin', function(data)
  local src = source
  local cid = getCharID(src)
  local supplied = tostring(data.pin_hash or "")
  if cid == '' then
    TriggerClientEvent('my-bank-ui:pinVerified', src, false, "Character not found.")
    return
  end
  exports.oxmysql:query("SELECT pin_hash FROM `user_characters` WHERE charid = ? OR discordid = ? LIMIT 1", { cid, getDiscordID(src) }, function(rows)
    local stored = rows[1] and rows[1].pin_hash or ''
    if stored ~= '' and supplied ~= '' and supplied == stored then
      TriggerClientEvent('my-bank-ui:pinVerified', src, true, "PIN OK")
      pushData(src)
    else
      TriggerClientEvent('my-bank-ui:pinVerified', src, false, "Incorrect PIN")
    end
  end)
end)

RegisterServerEvent('my-bank-ui:deposit', function(data)
  local src = source
  local did = getDiscordID(src)
  local cid = getCharID(src)
  local amt = tonumber(data.amount) or 0
  if amt > 0 and cid ~= '' then
    exports.oxmysql:execute(
      string.format("UPDATE `%s` SET cash = GREATEST(cash - ?,0), discordid = ? WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?)", M.money),
      { amt, did or '', cid, did or '', did or '' }
    )
    exports.oxmysql:execute(
      string.format("UPDATE `%s` SET balance = balance + ?, discordid = ? WHERE (charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?)) AND type = 'checking'", M.accts),
      { amt, did or '', cid, did or '', did or '' }
    )

    -- Log deposit transaction
    logTransaction(cid, did, 'deposit', amt, '', 0, 'Deposit to checking')
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
      string.format("UPDATE `%s` SET balance = GREATEST(balance - ?,0), discordid = ? WHERE (charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?)) AND type = 'checking'", M.accts),
      { amt, did or '', cid, did or '', did or '' }
    )
    exports.oxmysql:execute(
      string.format("UPDATE `%s` SET cash = cash + ?, discordid = ? WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?)", M.money),
      { amt, did or '', cid, did or '', did or '' }
    )

    -- Log withdrawal
    logTransaction(cid, did, 'withdraw', amt, '', 0, 'Withdraw from checking')
  end
  pushData(src)
end)


RegisterServerEvent('my-bank-ui:transfer', function(data)
  local src = source
  local did = getDiscordID(src)
  local cid = getCharID(src)
  local rawTarget = tostring(data.target or "")
  local amt = tonumber(data.amount) or 0

  if amt <= 0 or cid == '' or rawTarget == '' then
    return pushData(src, "Invalid transfer parameters.")
  end

  resolveTargetToCharid(rawTarget, function(targetCharid, reason)
    if not targetCharid then
      return pushData(src, ("Transfer failed: could not resolve target (%s)."):format(reason or "unknown"))
    end

    -- check sender cash
    exports.oxmysql:query(string.format("SELECT cash FROM `%s` WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?) LIMIT 1", M.money),
      { cid, did or cid, did or cid },
      function(res)
        local cash = res[1] and tonumber(res[1].cash) or 0
        if cash < amt then return pushData(src, "Not enough cash to transfer.") end

        -- subtract from sender
        exports.oxmysql:execute(string.format("UPDATE `%s` SET cash = cash - ?, discordid = ? WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?)",
          M.money), { amt, did or '', cid, did or '', did or '' }, function()
            -- add to recipient (create if not exists)
            exports.oxmysql:query(string.format("SELECT charid FROM `%s` WHERE charid = ? LIMIT 1", M.money), { targetCharid }, function(r2)
              if #r2 == 0 then
                exports.oxmysql:insert(string.format("INSERT INTO `%s` (discordid,charid,cash,bank,card_status) VALUES (?,?,?,?,?)", M.money),
                  { '', targetCharid, amt, 0, 'active' }, function()
                    -- log transactions: sender (out) and recipient (in)
                    logTransaction(cid, did, 'transfer_out', amt, targetCharid, 0, ('Transfer to %s'):format(tostring(rawTarget)))
                    logTransaction(targetCharid, '', 'transfer_in', amt, cid, 0, ('Received transfer from %s'):format(tostring(cid)))
                    pushData(src)
                  end)
              else
                exports.oxmysql:execute(string.format("UPDATE `%s` SET cash = cash + ? WHERE charid = ?", M.money),
                  { amt, targetCharid }, function()
                    -- log transactions
                    logTransaction(cid, did, 'transfer_out', amt, targetCharid, 0, ('Transfer to %s'):format(tostring(rawTarget)))
                    logTransaction(targetCharid, '', 'transfer_in', amt, cid, 0, ('Received transfer from %s'):format(tostring(cid)))
                    pushData(src)
                  end)
              end
            end)
          end)
      end)
  end)
end)



-- addPayment
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

RegisterServerEvent('my-bank-ui:transferInternal')
AddEventHandler('my-bank-ui:transferInternal', function(data)
  local src = source
  local did = getDiscordID(src)
  local cid = getCharID(src)
  local from = tostring(data.from or "")
  local to   = tostring(data.to or "")
  local amt  = tonumber(data.amount) or 0
  if amt <= 0 or cid == '' then return pushData(src, "Invalid transfer amount or character.") end

  fetchMoney(did, cid, function(m)
    fetchAccounts(did, cid, function(accts)
      local function isAcctId(s) return s:sub(1,5) == 'acct:' end

      local srcBal = 0
      local fromAccountId = 0
      local toAccountId = 0

      if from == 'cash' then
        srcBal = tonumber(m.cash) or 0
      elseif isAcctId(from) then
        local aid = tonumber(from:sub(6))
        fromAccountId = aid or 0
        for _, a in ipairs(accts) do if a.id == aid then srcBal = tonumber(a.balance) or 0; break end end
      else
        for _, a in ipairs(accts) do if a.type == from then srcBal = tonumber(a.balance) or 0; fromAccountId = a.id; break end end
      end

      if srcBal < amt then return pushData(src, "Insufficient funds in source account.") end

      local Q = {}

      if from == 'cash' then
        table.insert(Q, {
          sql = string.format("UPDATE `%s` SET cash = cash - ?, discordid = ? WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?)", M.money),
          params = { amt, did or '', cid, did or '', did or '' }
        })
      elseif isAcctId(from) then
        local aid = tonumber(from:sub(6))
        table.insert(Q, {
          sql = string.format("UPDATE `%s` SET balance = balance - ?, discordid = ? WHERE id = ? AND (charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?))", M.accts),
          params = { amt, did or '', aid, cid, did or '', did or '' }
        })
      else
        table.insert(Q, {
          sql = string.format("UPDATE `%s` SET balance = balance - ?, discordid = ? WHERE (charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?)) AND type = ?", M.accts),
          params = { amt, did or '', cid, did or '', did or '', from }
        })
      end

      if to == 'cash' then
        table.insert(Q, {
          sql = string.format("UPDATE `%s` SET cash = cash + ?, discordid = ? WHERE charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?)", M.money),
          params = { amt, did or '', cid, did or '', did or '' }
        })
      elseif isAcctId(to) then
        local aid = tonumber(to:sub(6))
        toAccountId = aid or 0
        table.insert(Q, {
          sql = string.format("UPDATE `%s` SET balance = balance + ? WHERE id = ?", M.accts),
          params = { amt, aid }
        })
      else
        table.insert(Q, {
          sql = string.format("UPDATE `%s` SET balance = balance + ?, discordid = ? WHERE (charid = ? OR discordid = ? OR discordid = CONCAT('discord:', ?)) AND type = ?", M.accts),
          params = { amt, did or '', cid, did or '', did or '', to }
        })
      end

      local function exec(i)
        if i > #Q then
          -- record internal transfer entries: out and in (same charid)
          local fromLabel = from
          local toLabel   = to
          logTransaction(cid, did, 'transfer_internal_out', amt, toLabel, fromAccountId or 0, ('Internal transfer %s -> %s'):format(tostring(fromLabel), tostring(toLabel)))
          logTransaction(cid, did, 'transfer_internal_in', amt, fromLabel, toAccountId or 0, ('Internal transfer %s -> %s'):format(tostring(fromLabel), tostring(toLabel)))
          return pushData(src)
        end
        exports.oxmysql:execute(Q[i].sql, Q[i].params, function() exec(i + 1) end)
      end

      exec(1)
    end)
  end)
end)


----------------------------------------------------------------
-- ATM Robbery / dispatch code (unchanged from earlier) --
----------------------------------------------------------------

local ATMState = {} -- atmKey -> { closedUntil = timestamp, coords = {x,y,z} }

local ATMConfig = {
  cooldown = 600,
  minReward = 500,
  maxReward = 3000,
  maxAllowedDistance = 5.0
}

-- Broadcast ATM state to clients: send remaining seconds (not unix timestamp)
local function broadcastAtmState(atmKey, closedUntil)
  local remaining = 0
  if closedUntil and closedUntil > 0 then
    remaining = math.max(0, closedUntil - os.time())
  end
  TriggerClientEvent('atm:closedStatus', -1, atmKey, remaining)
end

-- Police job names to match against (lowercase)
local POLICE_JOB_NAMES = {
  ['police'] = true,
  ['pd'] = true,
  ['sheriff'] = true,
  ['policeofficer'] = true,
  ['police_officer'] = true,
  -- add more as needed
}

-- Normalize job value returned by Az-Framework
local function normalizeJob(jobVal)
  if not jobVal then return nil end
  if type(jobVal) == 'table' then
    if jobVal.name and type(jobVal.name) == 'string' then
      return jobVal.name:lower()
    elseif jobVal.job and type(jobVal.job) == 'string' then
      return jobVal.job:lower()
    elseif jobVal.department and type(jobVal.department) == 'string' then
      return jobVal.department:lower()
    else
      for k,v in pairs(jobVal) do
        if type(v) == 'string' then return v:lower() end
      end
      return tostring(jobVal)
    end
  end
  if type(jobVal) == 'string' then return jobVal:lower() end
  return tostring(jobVal)
end

-- notifyPolice: iterate players and notify those with a police job + verbose debug
local function notifyPolice(payload)
  TriggerEvent('dispatch:notifyPolice', payload) -- allow other server modules to hook

  local players = GetPlayers()
  local foundAny = false

  if DEBUG_DISPATCH then
    print(("[dispatch] notifyPolice called. payload.atmKey=%s coords=%s"):format(
      tostring(payload.atmKey),
      payload.coords and (("%0.2f,%0.2f,%0.2f"):format(payload.coords.x or 0, payload.coords.y or 0, payload.coords.z or 0)) or "nil"
    ))
  end

  for _, pid in ipairs(players) do
    local srvId = tonumber(pid)
    if srvId then
      local ok, jobVal = pcall(function()
        if exports['Az-Framework'] and exports['Az-Framework'].getPlayerJob then
          return exports['Az-Framework']:getPlayerJob(srvId)
        elseif exports['Az-Framework'] and exports['Az-Framework'].GetPlayerJob then
          return exports['Az-Framework']:GetPlayerJob(srvId)
        end
        return nil
      end)

      local serialized = nil
      pcall(function() serialized = (type(jobVal) == 'table' and (json and json.encode and json.encode(jobVal) or tostring(jobVal)) or tostring(jobVal)) end)

      if DEBUG_DISPATCH then
        print(("[dispatch] pid=%s getPlayerJob ok=%s returnedType=%s returned=%s"):format(
          tostring(srvId),
          tostring(ok),
          type(jobVal),
          tostring(serialized)
        ))
      end

      if ok and jobVal then
        local jobName = normalizeJob(jobVal)
        if DEBUG_DISPATCH then
          print(("[dispatch] pid=%s normalized job => %s"):format(tostring(srvId), tostring(jobName)))
        end

        if jobName and POLICE_JOB_NAMES[jobName] then
          foundAny = true
          if DEBUG_DISPATCH then
            print(("[dispatch] notifying pid=%s (job=%s)"):format(tostring(srvId), tostring(jobName)))
          end
          TriggerClientEvent('dispatch:atmRobbery', srvId, payload)
          TriggerClientEvent('chat:addMessage', srvId, {
            args = {
              '^1[DISPATCH]',
              ('^3ATM Robbery^7 — Location: (%.1f, %.1f, %.1f) — Reward: $%d')
                :format((payload.coords and payload.coords.x) or 0, (payload.coords and payload.coords.y) or 0, (payload.coords and payload.coords.z) or 0, payload.reward or 0)
            }
          })
        end
      else
        if DEBUG_DISPATCH then
          print(("[dispatch] pid=%s getPlayerJob failed or nil (ok=%s)"):format(tostring(srvId), tostring(ok)))
        end
      end
    end
  end

  if not foundAny and DEBUG_DISPATCH then
    print("[dispatch] notifyPolice: no police players matched POLICE_JOB_NAMES (check job strings or returned job shape).")
  end
end

-- Debug command to force a notify from console / player (for testing)
RegisterCommand('atm_debug_notify', function(source, args, raw)
  local src = source
  local sender = (src == 0) and "console" or ("player:"..tostring(src))
  print(("[dispatch] /atm_debug_notify called by %s"):format(sender))
  local coords = { x = tonumber(args[1]) or 0, y = tonumber(args[2]) or 0, z = tonumber(args[3]) or 0 }
  local payload = {
    source = src,
    atmKey = args[4] or "debug_atm",
    coords = coords,
    reward = 0,
    closedUntil = os.time() + (tonumber(args[5]) or 60),
    timestamp = os.time()
  }
  notifyPolice(payload)
end, false)

-- atm:attemptRob handler (with debug prints)
RegisterServerEvent('atm:attemptRob')
AddEventHandler('atm:attemptRob', function(atmKey, atmCoords, reportedPlayerCoords)
  local src = source

  if DEBUG_DISPATCH then
    print(("[ATM] atm:attemptRob src=%s atmKey=%s atmCoords=%s reported=%s"):format(
      tostring(src),
      tostring(atmKey),
      atmCoords and (("%0.2f,%0.2f,%0.2f"):format(atmCoords.x or 0, atmCoords.y or 0, atmCoords.z or 0)) or "nil",
      reportedPlayerCoords and (("%0.2f,%0.2f,%0.2f"):format(reportedPlayerCoords.x or 0, reportedPlayerCoords.y or 0, reportedPlayerCoords.z or 0)) or "nil"
    ))
  end

  if not atmKey then
    TriggerClientEvent('chat:addMessage', src, { args = {'^1ATM', 'Invalid ATM identifier.'} })
    return
  end

  local state = ATMState[atmKey]
  if state and state.closedUntil and state.closedUntil > os.time() then
    local remaining = state.closedUntil - os.time()
    TriggerClientEvent('chat:addMessage', src, { args = {'^1ATM', ('This ATM is closed due to a recent robbery. Reopens in %ds'):format(remaining)} })
    return
  end

  if atmCoords and reportedPlayerCoords then
    local dx = atmCoords.x - reportedPlayerCoords.x
    local dy = atmCoords.y - reportedPlayerCoords.y
    local dz = (atmCoords.z or 0) - (reportedPlayerCoords.z or 0)
    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
    if dist > (ATMConfig.maxAllowedDistance or 5.0) then
      print(("[SECURITY] atm:attemptRob denied for src=%d dist=%.2f (allowed=%.2f)"):format(src, dist, ATMConfig.maxAllowedDistance))
      TriggerClientEvent('chat:addMessage', src, { args = {'^1ATM', 'Robbery failed: you are not close enough to the ATM.'} })
      return
    end
  else
    TriggerClientEvent('chat:addMessage', src, { args = {'^1ATM', 'Robbery failed: invalid coordinates provided.'} })
    return
  end

  local cooldown = tonumber(ATMConfig.cooldown) or 600
  local closedUntil = os.time() + cooldown
  ATMState[atmKey] = { closedUntil = closedUntil, coords = atmCoords }
  broadcastAtmState(atmKey, closedUntil)

  local minR = tonumber(ATMConfig.minReward) or 500
  local maxR = tonumber(ATMConfig.maxReward) or 3000
  if minR > maxR then minR, maxR = maxR, minR end
  local reward = math.random(minR, maxR)

  local ok, err = pcall(function()
    if exports['Az-Framework'] and exports['Az-Framework'].addMoney then
      exports['Az-Framework']:addMoney(src, reward)
    else
      if exports['Az-Framework'] and exports['Az-Framework'].AddMoney then
        exports['Az-Framework']:AddMoney(src, reward)
      else
        error("Az-Framework addMoney export missing")
      end
    end
  end)

  if ok then
    TriggerClientEvent('chat:addMessage', src, { args = {'^2ATM', ('Robbery successful! You received $%d'):format(reward)} })
  else
    TriggerClientEvent('chat:addMessage', src, { args = {'^1ATM', 'Robbery succeeded but reward delivery failed.'} })
    print(("[ATM] addMoney failed for src=%d err=%s"):format(src, tostring(err)))
  end

  local payload = {
    source      = src,
    atmKey      = atmKey,
    coords      = atmCoords,
    reward      = reward,
    closedUntil = closedUntil,
    timestamp   = os.time(),
    blipDuration = DISPATCH_BLIP_SECONDS
  }

  if DEBUG_DISPATCH then
    print(("[ATM] calling notifyPolice payload.atmKey=%s coords=%s"):format(
      tostring(payload.atmKey),
      payload.coords and (("%0.2f,%0.2f,%0.2f"):format(payload.coords.x or 0, payload.coords.y or 0, payload.coords.z or 0)) or "nil"
    ))
  end

  notifyPolice(payload)

  Citizen.CreateThread(function()
    Citizen.Wait((cooldown * 1000) + 500)
    if ATMState[atmKey] and ATMState[atmKey].closedUntil <= os.time() then
      ATMState[atmKey] = nil
      broadcastAtmState(atmKey, 0)
    end
  end)
end)

-- End of server.lua
