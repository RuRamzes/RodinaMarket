local effil_check, effil = pcall(require, 'effil')
local requests_check, requests = pcall(require, 'requests')
local imgui_check, imgui = pcall(require, 'mimgui')
local samp_check, samp = pcall(require, 'samp.events')
local lfs_check, lfs = pcall(require, 'lfs')
local fa_check, faicons = pcall(require, 'fawesome6')
local encoding = require 'encoding'
local ffi = require 'ffi'

encoding.default = 'CP1251'
local u8 = encoding.UTF8

if not imgui_check or not samp_check or not effil_check or not requests_check or not fa_check then 
    function main()
        while not isSampAvailable() do wait(100) end
        sampAddChatMessage('[Mining Manager] {FF0000}Error: Missing libraries (mimgui, effil, requests, fawesome6).', -1)
        thisScript():unload()
    end
    return
end

local WM_KEYDOWN = 0x100
local WM_KEYUP = 0x101

function table.assign(target, def, deep)
    target = target or {}
    for k, v in pairs(def or {}) do
        if target[k] == nil then
            if type(v) == 'table' then
                target[k] = {}
                table.assign(target[k], v, deep)
            else  
                target[k] = v
            end
        elseif deep and type(v) == 'table' and type(target[k]) == 'table' then 
            table.assign(target[k], v, deep)
        end
    end 
    return target
end

local configDirsCreated = false

local JsonHandler = {}
JsonHandler.__index = JsonHandler

function JsonHandler:save(array)
    if array and type(array) == 'table' then
        local file = io.open(self.fullPath, 'w')
        if file then
            pcall(function() file:write(encodeJson(array)) end)
            file:close()
        end
    end
end

function JsonHandler:load(array)
    local result = {}
    local file = io.open(self.fullPath, 'r')
    if file then
        local text = file:read('*a')
        if text and text ~= '' then
            local status, decoded = pcall(decodeJson, text)
            if status and type(decoded) == 'table' then 
                result = decoded 
            end
        end
        file:close()
    end
    if type(result) ~= 'table' then result = {} end
    return table.assign(result, array, true)
end

local function json(path)
    local basePath = getWorkingDirectory() .. '\\config'
    local miningPath = basePath .. '\\MiningManager'
    
    if not configDirsCreated then
        if not doesDirectoryExist(basePath) then createDirectory(basePath) end
        if not doesDirectoryExist(miningPath) then createDirectory(miningPath) end
        configDirsCreated = true
    end
    
    local instance = { fullPath = miningPath .. '\\' .. path }
    setmetatable(instance, JsonHandler)
    return instance
end

local new = imgui.new
local WinState = new.bool()
local bigIconFont = nil
local SettingsState = new.bool()
local updateid = 0
local shelvesCache = json('shelves_cache.json')
local shelvesData = shelvesCache:load({ list = {} }).list
local isAutoCollecting = false 
local specificAction = nil
local currentTaskIndex = -1 
local currentTaskType = nil
local actionLock = false 
local nextActionTime = 0 
local animTime = 0.0

local activeShelfDialog = {
    visible = false,
    title = "",
    actions = {}
}

local activeConfirmDialog = {
    visible = false,
    amount = "0",
    fullAmount = "0.0000"
}

local telegramQueue = {}

local paydayStats = json('payday_stats.json'):load({
    totalPaydays = 0,
    lastReset = os.time(),
    collectedAt = 0,
    currentCounter = 0,
    lastServerTime = os.time()
})

local paydayCounter = paydayStats.currentCounter or 0

local notfState = json('notifications.json'):load({
    h3 = false,
    h2 = false, 
    h1 = false,
    full = false,
    lastCheck = os.time(),
    shelfStates = {}
})

local MINING_RATES = { 0.029999, 0.059999, 0.09, 0.11999, 0.15, 0.18, 0.209999, 0.239999, 0.27, 0.3 }
local D_LIST = 269
local D_SHELF = 270
local D_CONFIRM = 271

local cfg = json('settings.json'):load({
    hasRtx4090 = false,
    window = { w = 920, h = 600 },
    telegram = {
        token = '',
        chatId = '',
        enabled = false
    }
})

local inputToken = new.char[128](cfg.telegram.token)
local inputChatId = new.char[128](cfg.telegram.chatId)
local inputEnabled = new.bool(cfg.telegram.enabled)
local inputRtx = new.bool(cfg.hasRtx4090)

local stats = json('stats.json'):load({ history = {} })

local function requestRunner()
    return effil.thread(function(u, a)
       local https = require 'ssl.https'
       local ok, result = pcall(https.request, u, a)
       return {ok, result}
    end)
end

local function threadHandle(runner, url, args, resolve, reject)
    local t = runner(url, args)
    local r = t:get(0)
    while not r do
       r = t:get(0)
       wait(0)
    end
    
    local status = t:status()
    if status == 'completed' then
       local ok, result = r[1], r[2]
       if ok then
            if type(result) ~= 'string' then resolve('') else resolve(result) end
        else
            if reject then reject(result) end
        end
    elseif status == 'canceled' then
        if reject then reject(status) end
    else
        if reject then reject('unknown error') end
    end
    t:cancel(0)
end
 
local function async_http_request(url, args, resolve, reject)
    if not reject then reject = function() end end
    lua_thread.create(function()
       threadHandle(requestRunner(), url, args, resolve, reject)
    end)
end

local function encodeUrl(str)
    str = str:gsub(' ', '%+')
    str = str:gsub('\n', '%%0A')
    return u8:encode(str)
end

function sendTelegramNotification(msg)
    if not cfg.telegram.enabled or cfg.telegram.token == '' or cfg.telegram.chatId == '' then 
        return false
    end

    if type(msg) == 'table' then
        msg = tostring(msg):gsub('table:', ''):gsub('effil%.', ''):gsub('userdata:', '')
    elseif type(msg) ~= 'string' then
        msg = tostring(msg)
    end

    msg = msg:gsub('%b{}', ''):gsub('effil%.table:[%x]+', ''):gsub('userdata:[%x]+', '')
    
    if #msg < 3 then return false end

    table.insert(telegramQueue, msg)
    return true
end

local isTelegramBusy = false

function getTelegramUpdates()
    while not isSampAvailable() do wait(1000) end
    
    isTelegramBusy = true
    async_http_request('https://api.telegram.org/bot'..cfg.telegram.token..'/getUpdates?offset=-1', '', function(result)
        if result and type(result) == 'string' then
            local success, proc_table = pcall(decodeJson, result)
            if success and proc_table and proc_table.ok then
                if #proc_table.result > 0 then
                    updateid = proc_table.result[1].update_id
                else
                    updateid = 0
                end
            end
        end
        isTelegramBusy = false
    end, function(error)
        print('[Mining] Ошибка получения начального update_id: ' .. tostring(error))
        isTelegramBusy = false
    end)

    while isTelegramBusy do wait(100) end
    if updateid == nil then updateid = 0 end

    while true do
        wait(200)
        
        if not isTelegramBusy and cfg.telegram.enabled and cfg.telegram.token ~= '' then
            isTelegramBusy = true
            
            local url = 'https://api.telegram.org/bot'..cfg.telegram.token..'/getUpdates?offset='..(updateid + 1)..'&timeout=10'
            
            async_http_request(url, '', function(result)
                if result and type(result) == 'string' then
                    processTelegramMessages(result)
                end
                isTelegramBusy = false
            end, function(error)
                local errStr = tostring(error)
                print('[Mining] Ошибка Telegram: ' .. errStr)
                
                if errStr:find("Conflict") or errStr:find("terminated") then
                    print('[Mining] Обнаружен конфликт соединений. Жду 15 секунд...')
                    wait(15000)
                else
                    wait(3000)
                end
                
                isTelegramBusy = false
            end)
        end
    end
end

function processTelegramMessages(result)
    if type(result) ~= 'string' then 
        return 
    end
    
    if result == '' or result == 'null' then 
        return 
    end
    
    local success, proc_table = pcall(decodeJson, result)
    
    if not success then
        if result:find("<html>") or result:find("<title>") then return end
        print('[Mining] Ошибка парсинга JSON: ' .. tostring(proc_table))
        return
    end
    
    if not proc_table or type(proc_table) ~= 'table' then 
        return 
    end
    
    if not proc_table.ok then 
        if proc_table.description and not proc_table.description:find("Conflict") then
             print('[Mining] Telegram API: ' .. tostring(proc_table.description))
        end
        return 
    end
    
    if not proc_table.result or type(proc_table.result) ~= 'table' then 
        return 
    end

    for _, update in ipairs(proc_table.result) do
        if update.update_id and update.update_id > updateid then
            updateid = update.update_id
            
            if update.message and update.message.text then
                local message = update.message.text
                local chatId = tostring(update.message.chat.id)
                
                if update.message.from and update.message.from.is_bot then
                elseif chatId == cfg.telegram.chatId then
                    if message == '/start' or message == '/help' then
                        sendTelegramNotification("*Mining Manager Bot*\n\nКоманды:\n/stats - Статистика майнинга\n/ping - Проверка работы")
                    
                    elseif message == '/ping' then
                        sendTelegramNotification("Pong! \nЯ работаю и слежу за фермой.\nPayDay счетчик: " .. paydayCounter)
                    
                    elseif message == '/stats' then
                        local report = getStatsReport()
                        sendTelegramNotification(report)
                    end
                end
            end
        end
    end
end

function addStatRecord(amount)
    if amount <= 0 then return end
    table.insert(stats.history, { ts = os.time(), amount = amount })
    json('stats.json'):save(stats)
end

function getStatsReport()
    local total, month, week = 0, 0, 0
    local now = os.time()
    local currentMonthStr = os.date("%m%Y", now)
    
    for _, record in ipairs(stats.history) do
        total = total + record.amount
        local recMonthStr = os.date("%m%Y", record.ts)
        if recMonthStr == currentMonthStr then month = month + record.amount end
        if (now - record.ts) <= 604800 then week = week + record.amount end
    end
    
    local prediction = ""
    local minPayDays = 999
    
    if #shelvesData > 0 then
        for _, item in ipairs(shelvesData) do
            if item.status:find("Работает") then
                local rate = (MINING_RATES[item.level] or 0) * (cfg.hasRtx4090 and 1.25 or 1.0)
                if rate > 0 then
                    local rem = (9.0 - item.profit) / rate
                    if rem < minPayDays then minPayDays = rem end
                end
            end
        end
    end
    
    if minPayDays == 999 then 
        prediction = "Ферма не работает или полна" 
    elseif minPayDays <= 0 then
        prediction = "УЖЕ ЗАПОЛНЕНО!"
    else
        prediction = string.format("%d PayDay", math.ceil(minPayDays))
    end
    
    return string.format(
        "*Статистика Mining Manager:*\n\n" ..
        "*За все время:* %.4f BTC\n" ..
        "*За этот месяц:* %.4f BTC\n" ..
        "*PayDay счетчик:* %d\n\n" ..
        "*До полного заполнения:* %s",
        total, month, paydayCounter, prediction
    )
end

function checkMiningStatusForNotifications()
    if #shelvesData == 0 or not cfg.telegram.enabled then return end

    local criticalShelves = {}
    
    for i, item in ipairs(shelvesData) do
        local rate = (MINING_RATES[item.level] or 0) * (cfg.hasRtx4090 and 1.25 or 1.0)
        
        if rate > 0 and (item.status:find("Работает") or item.status:find("В работе")) then
            local remainingSpace = 9.0 - item.profit
            if remainingSpace < 0 then remainingSpace = 0 end
            
            local pdsLeft = 999
            if rate > 0 then pdsLeft = remainingSpace / rate end
            
            local shelfKey = "shelf_" .. item.shelf
            local prevState = notfState.shelfStates[shelfKey] or {}
            
            if pdsLeft <= 3 and pdsLeft > 2 and (not prevState.h3 or (os.time() - (prevState.lastAlert or 0)) > 3600) then
                table.insert(criticalShelves, {shelf = item.shelf, pds = 3, level = "h3", profit = item.profit})
                notfState.shelfStates[shelfKey] = {h3 = true, lastAlert = os.time()}
            elseif pdsLeft <= 2 and pdsLeft > 1 and (not prevState.h2 or (os.time() - (prevState.lastAlert or 0)) > 1800) then
                table.insert(criticalShelves, {shelf = item.shelf, pds = 2, level = "h2", profit = item.profit})
                notfState.shelfStates[shelfKey] = {h2 = true, lastAlert = os.time()}
            elseif pdsLeft <= 1 and pdsLeft > 0.05 and (not prevState.h1 or (os.time() - (prevState.lastAlert or 0)) > 900) then
                table.insert(criticalShelves, {shelf = item.shelf, pds = 1, level = "h1", profit = item.profit})
                notfState.shelfStates[shelfKey] = {h1 = true, lastAlert = os.time()}
            elseif (pdsLeft <= 0.05 or item.profit >= 9.0) and (not prevState.full or (os.time() - (prevState.lastAlert or 0)) > 600) then
                table.insert(criticalShelves, {shelf = item.shelf, pds = 0, level = "full", profit = item.profit})
                notfState.shelfStates[shelfKey] = {full = true, lastAlert = os.time()}
            end
        end
    end

    for _, critical in ipairs(criticalShelves) do
        local alertMsg = ""
        if critical.level == "h3" then
            alertMsg = string.format("*ВНИМАНИЕ!* Стойка %d заполнится через ~3 PayDay!\nПрибыль: %.2f BTC", critical.shelf, critical.profit)
        elseif critical.level == "h2" then
            alertMsg = string.format("*СРОЧНО!* Стойка %d заполнится через ~2 PayDay!\nПрибыль: %.2f BTC", critical.shelf, critical.profit)
        elseif critical.level == "h1" then
            alertMsg = string.format("*КРИТИЧЕСКИ!* Стойка %d заполнится в следующий PayDay!\nПрибыль: %.2f BTC", critical.shelf, critical.profit)
        elseif critical.level == "full" then
            alertMsg = string.format("*ФЕРМА ЗАПОЛНЕНА!* Стойка %d (%.2f BTC).\nНемедленно соберите биткоины!", critical.shelf, critical.profit)
        end
        
        if alertMsg ~= "" then
            sendTelegramNotification(alertMsg)
            
            local shelfKey = "shelf_" .. critical.shelf
            if critical.level == "h3" then notfState.shelfStates[shelfKey] = {h3 = true, lastAlert = os.time()} end
            if critical.level == "h2" then notfState.shelfStates[shelfKey] = {h2 = true, lastAlert = os.time()} end
            if critical.level == "h1" then notfState.shelfStates[shelfKey] = {h1 = true, lastAlert = os.time()} end
            if critical.level == "full" then notfState.shelfStates[shelfKey] = {full = true, lastAlert = os.time()} end
        end
    end
    notfState.lastCheck = os.time()
    json('notifications.json'):save(notfState)
end

function cleanText(text)
    return text:gsub('%b{}', ''):gsub('%b[]', '')
end

function formatTimeLeft(currentProfit, level)
    if not level or level < 1 or level > 10 then return u8"Н/Д" end
    local rate = MINING_RATES[level]
    if not rate then return u8"Н/Д" end
    if cfg.hasRtx4090 then rate = rate * 1.25 end
    
    local remaining = 9.0 - currentProfit
    if remaining <= 0 then return u8"ЗАПОЛНЕНО" end
    
    local paydaysNeeded = math.ceil(remaining / rate)
    
    return string.format("%d PayDay", paydaysNeeded)
end

function parseMainDialog(text)
    local data = {}
    local lines = {}
    for line in text:gmatch("[^\r\n]+") do table.insert(lines, line) end

    for i = 2, #lines do
        local rawLine = lines[i]
        local cleanLine = cleanText(rawLine)
        
        local shelfNum = cleanLine:match('Полка №(%d+)')
        local statusRaw = rawLine:match("|%s*(.-)\t") or rawLine:match("|%s*(.-)%s%s")
        local statusText = statusRaw and cleanText(statusRaw):match("^%s*(.-)%s*$") or "Неизвестно"
        local profit = cleanLine:match('(%d+%.%d+) BTC') or cleanLine:match('(%d+) BTC')
        local level = cleanLine:match('(%d+) уровень')
        local cooling = cleanLine:match('(%d+%.%d+)%%') or cleanLine:match('(%d+)%%')
        
        if shelfNum then
            table.insert(data, {
                listId = i - 2, 
                shelf = tonumber(shelfNum),
                status = statusText,
                profit = tonumber(profit) or 0.0,
                level = tonumber(level) or 0,
                cooling = tonumber(cooling) or 0.0
            })
        end
    end
    return data
end

function parseShelfDialogActions(text)
    local actions = {}
    local lines = {}
    for line in text:gmatch("[^\r\n]+") do 
        table.insert(lines, line) 
    end
    
    for i, line in ipairs(lines) do
        local cleanLine = cleanText(line)
        if #cleanLine > 1 then
            local icon = faicons('circle_question')
            local color = imgui.ImVec4(1, 1, 1, 1)
            
            if cleanLine:find("Остановить") then
                icon = faicons('ban') 
                color = imgui.ImVec4(1.0, 0.3, 0.3, 1.0)
            elseif cleanLine:find("Запустить") then
                icon = faicons('power_off')
                color = imgui.ImVec4(0.4, 0.9, 0.4, 1.0)
            elseif cleanLine:find("Забрать") then
                icon = faicons('coins')
                color = imgui.ImVec4(1.0, 0.8, 0.2, 1.0)
            elseif cleanLine:find("жидкость") then
                icon = faicons('droplet')
                color = imgui.ImVec4(0.2, 0.6, 1.0, 1.0)
            elseif cleanLine:find("Достать") then
                icon = faicons('eject')
                color = imgui.ImVec4(0.7, 0.7, 0.7, 1.0)
            end
            
            table.insert(actions, {
                listId = i - 1,
                label = cleanLine,
                icon = icon,
                color = color
            })
        end
    end
    return actions
end

function calculateGlobalStats()
    local stats = {
        totalProfit = 0,
        totalSpeed = 0,
        dailyProfit = 0,
        nextFullPayDays = 0,
        nextFullShelf = 0,
        workingCount = 0
    }
    
    local minPayDays = 999.0
    
    for _, item in ipairs(shelvesData) do
        stats.totalProfit = stats.totalProfit + item.profit
        
        if item.status:find("Работает") then
            stats.workingCount = stats.workingCount + 1
            local rate = (MINING_RATES[item.level] or 0) * (cfg.hasRtx4090 and 1.25 or 1.0)
            stats.totalSpeed = stats.totalSpeed + rate
            
            local remaining = 9.0 - item.profit
            if remaining > 0 and rate > 0 then
                local pds = remaining / rate
                if pds < minPayDays then
                    minPayDays = pds
                    stats.nextFullShelf = item.shelf
                end
            end
        elseif item.profit >= 9.0 then
            minPayDays = 0
            stats.nextFullShelf = item.shelf
        end
    end
    
    stats.dailyProfit = stats.totalSpeed * 24 
    if minPayDays ~= 999.0 then 
        stats.nextFullPayDays = math.ceil(minPayDays) 
    end
    
    return stats
end

function startMiningAction(mode)
    if sampIsDialogActive() then
        local found = false
        isAutoCollecting = true
        specificAction = mode
        nextActionTime = os.clock()
        
        if (mode == 'collect' or mode == 'all') then
            for i, item in ipairs(shelvesData) do if item.profit >= 1.0 then currentTaskIndex = i; currentTaskType = 'collect'; sampSendDialogResponse(D_LIST, 1, item.listId, ""); found = true; break end end
        end
        if not found and (mode == 'restore' or mode == 'all') then
            for i, item in ipairs(shelvesData) do if item.cooling < 50 then currentTaskIndex = i; currentTaskType = 'restore'; sampSendDialogResponse(D_LIST, 1, item.listId, ""); found = true; break end end
        end
        if not found and (mode == 'start' or mode == 'all') then
            for i, item in ipairs(shelvesData) do if item.status:find("На паузе") or item.status:find("Выключ") then currentTaskIndex = i; currentTaskType = 'start'; sampSendDialogResponse(D_LIST, 1, item.listId, ""); found = true; break end end
        end
        
        if found then nextActionTime = os.clock() + 0.5 end
    else
        isAutoCollecting = true
        specificAction = mode
        nextActionTime = os.clock()
        sampAddChatMessage("[Mining] Откройте меню фермы (или дождитесь обновления) для старта.", -1)
    end
end

function main()
    while not isSampAvailable() do wait(100) end
    
    paydayCounter = paydayStats.currentCounter or 0
    local lastAutoSave = os.time()
    
    lua_thread.create(function()
        while true do
            if #telegramQueue > 0 then
                local msg = table.remove(telegramQueue, 1)
                local encoded = encodeUrl(msg)
                if encoded and #encoded > 3 then
                    local url = string.format(
                        'https://api.telegram.org/bot%s/sendMessage?chat_id=%s&text=%s&parse_mode=Markdown',
                        cfg.telegram.token, cfg.telegram.chatId, encoded
                    )
                    async_http_request(url, '', function() end, function() end)
                    wait(1500)
                end
            else
                wait(200)
            end
        end
    end)

    local timeSinceLast = os.time() - paydayStats.lastReset
    if timeSinceLast > 3600 and paydayCounter > 0 then
        print("[Mining] Восстановление PayDay счетчика: " .. paydayCounter)
    end
    
    if not doesDirectoryExist(getWorkingDirectory() .. '\\resource\\fonts') then
        createDirectory(getWorkingDirectory() .. '\\resource\\fonts')
    end

    lua_thread.create(getTelegramUpdates)
    
    addEventHandler('onWindowMessage', function(msg, wparam, lparam)
        if WinState[0] and not SettingsState[0] then 
            if msg == WM_KEYDOWN then
                if wparam == 27 then
                    if activeShelfDialog.visible then
                        activeShelfDialog.visible = false
                        sampSendDialogResponse(D_SHELF, 0, -1, "")
                        consumeWindowMessage(true, false)
                    elseif activeConfirmDialog.visible then
                        activeConfirmDialog.visible = false
                        sampSendDialogResponse(D_CONFIRM, 0, -1, "")
                        consumeWindowMessage(true, false)
                    else
                        consumeWindowMessage(true, false)
                    end
                elseif wparam == 32 and not isAutoCollecting then
                    startMiningAction('all')
                    consumeWindowMessage(true, false)
                end
            end
            
            if msg == WM_KEYUP and wparam == 27 then
                if not activeShelfDialog.visible then
                     WinState[0] = false
                     SettingsState[0] = false
                     isAutoCollecting = false
                     actionLock = false
                end
            end
        elseif SettingsState[0] and wparam == 27 and msg == WM_KEYUP then
             SettingsState[0] = false
        end
    end)
    
    while true do
        wait(0)
        
        if os.time() > lastAutoSave + 300 then
            lastAutoSave = os.time()
            paydayStats.currentCounter = paydayCounter
            paydayStats.lastServerTime = os.time()
            json('payday_stats.json'):save(paydayStats)
        end
        
        if isAutoCollecting then
            if os.clock() > nextActionTime + 5.0 and actionLock then 
                actionLock = false 
                sampAddChatMessage("[Mining] Сброс зависшей блокировки...", -1)
            end
            if os.clock() >= nextActionTime then
                if not sampIsDialogActive() then
                    setGameKeyState(21, 255); wait(10); setGameKeyState(21, 0)
                    nextActionTime = os.clock() + 0.4 
                end
            end
        end
    end
end

function samp.onServerMessage(color, text)
    if text:find("На банковском счету") then
        paydayCounter = paydayCounter + 1
        paydayStats.totalPaydays = paydayStats.totalPaydays + 1
        paydayStats.currentCounter = paydayCounter
        paydayStats.lastReset = os.time()
        json('payday_stats.json'):save(paydayStats)
        
        table.insert(stats.history, { ts = os.time(), amount = 0, type = "payday", counter = paydayCounter })
        if #stats.history > 1000 then table.remove(stats.history, 1) end
        json('stats.json'):save(stats)
        
        local updated = false
        if #shelvesData > 0 then
            for i, item in ipairs(shelvesData) do
                if item.status:find("Работает") or item.status:find("В работе") then
                    local rate = (MINING_RATES[item.level] or 0) * (cfg.hasRtx4090 and 1.25 or 1.0)
                    if rate > 0 then
                        item.profit = item.profit + rate
                        if item.profit > 9.0 then item.profit = 9.0 end
                        
                        if item.cooling > 0 then item.cooling = item.cooling - 2 end 
                        updated = true
                    end
                end
            end
        end

        if updated then
            shelvesCache:save({ list = shelvesData })
            sampAddChatMessage("[Mining] Данные обновлены виртуально (PayDay). Проверка уведомлений...", 0x4ea8de)
            checkMiningStatusForNotifications()
        end
    end

    if text:find('Добавлено в инвентарь: предмет "Bitcoin %(BTC%)"') then
        local count = 1
        local countStr = text:match('%((%d+) шт%)')
        if countStr then count = tonumber(countStr) end
        
        addStatRecord(count * 1.0)
        
        for shelfKey, _ in pairs(notfState.shelfStates) do
            notfState.shelfStates[shelfKey] = {}
        end
        notfState.h3 = false; notfState.h2 = false; notfState.h1 = false; notfState.full = false
        json('notifications.json'):save(notfState)
        
        paydayStats.collectedAt = paydayCounter
        paydayCounter = 0
        paydayStats.currentCounter = 0
        json('payday_stats.json'):save(paydayStats)
        
        if #shelvesData > 0 then
            for i, item in ipairs(shelvesData) do
                if item.profit >= 1.0 then item.profit = 0.0 end
            end
            shelvesCache:save({ list = shelvesData })
        end
        
        sampAddChatMessage(string.format('[Mining] Статистика: +%d BTC. Таймеры уведомлений сброшены.', count), 0x4ea8de)
    end
end

function samp.onShowDialog(id, style, title, button1, button2, text)
    if id == D_LIST then
        actionLock = false 
        shelvesData = parseMainDialog(text)
        shelvesCache:save({ list = shelvesData })
        
        checkMiningStatusForNotifications()
        
        nextActionTime = os.clock() + 0.1

        if isAutoCollecting then
            local found = false
            
            if not found and (specificAction == 'collect' or specificAction == 'all') then
                for i, item in ipairs(shelvesData) do
                    if item.profit >= 1.0 then 
                        currentTaskIndex = i; currentTaskType = 'collect'; 
                        sampSendDialogResponse(D_LIST, 1, item.listId, ""); found = true; break 
                    end
                end
            end

            if not found and (specificAction == 'restore' or specificAction == 'all') then 
                for i, item in ipairs(shelvesData) do 
                    if item.cooling < 50 then 
                        currentTaskIndex = i; currentTaskType = 'restore'; 
                        sampSendDialogResponse(D_LIST, 1, item.listId, ""); found = true; break 
                    end 
                end 
            end
            
            if not found and (specificAction == 'start' or specificAction == 'all') then 
                for i, item in ipairs(shelvesData) do 
                    if item.status:find("На паузе") or item.status:find("Выключ") then 
                        currentTaskIndex = i; currentTaskType = 'start'; 
                        sampSendDialogResponse(D_LIST, 1, item.listId, ""); found = true; break 
                    end 
                end 
            end

            if not found then
                isAutoCollecting = false; currentTaskIndex = -1; currentTaskType = nil; specificAction = nil
                sampAddChatMessage("{4ea8de}[Mining] {FFFFFF}Выбранные задачи выполнены.", -1)
                WinState[0] = true 
            end
            return false
        else 
            WinState[0] = true 
        end
        return false
    end

    if id == D_SHELF then
        if isAutoCollecting then
            if actionLock then return false end
            local listId = -1; local lines = {}; for line in text:gmatch("[^\r\n]+") do table.insert(lines, line) end
            local searchKey = ""
            if currentTaskType == 'collect' then searchKey = "BTC"
            elseif currentTaskType == 'restore' then searchKey = "жидкость"
            elseif currentTaskType == 'start' then searchKey = "Запустить" end

            for i, line in ipairs(lines) do
                local clean = cleanText(line) 
                if clean:find(searchKey) and not clean:find("Остановить") then
                    if currentTaskType == 'collect' then
                         local profitVal = clean:match('(%d+%.%d+)') or clean:match('(%d+)')
                         if profitVal and tonumber(profitVal) > 0 then listId = i - 1; break end
                    else listId = i - 1; break end
                end
            end

            if listId ~= -1 then
                actionLock = true; sampSendDialogResponse(D_SHELF, 1, listId, "")
                if currentTaskType == 'restore' or currentTaskType == 'start' then
                    lua_thread.create(function() wait(50); sampSendDialogResponse(D_SHELF, 0, -1, ""); nextActionTime = os.clock() + 0.3 end)
                else 
                    nextActionTime = os.clock() + 0.2 
                end
            else
                sampSendDialogResponse(D_SHELF, 0, -1, ""); isAutoCollecting = false; WinState[0] = true 
                sampAddChatMessage("{FF0000}[Mining] {FFFFFF}Ошибка поиска кнопки: "..searchKey, -1)
            end
            return false
        else
            activeShelfDialog.title = cleanText(title)
            activeShelfDialog.actions = parseShelfDialogActions(text)
            activeShelfDialog.visible = true
            WinState[0] = true
            return false
        end
    end
    
    if id == D_CONFIRM then
        if isAutoCollecting and currentTaskType == 'collect' then
            sampSendDialogResponse(D_CONFIRM, 1, -1, "")
            nextActionTime = os.clock() + 0.3
            return false 
        end
        
        local clean = cleanText(text)
        local avail = clean:match("доступно.-:%s*(%d+)") or "0"
        local full = clean:match("добыто%s*([%d%.]+)") or "0.0000"
        
        activeConfirmDialog.amount = avail
        activeConfirmDialog.fullAmount = full
        activeConfirmDialog.visible = true
        WinState[0] = true
        return false
    end
end

function DrawCustomProgressBar(fraction, size, colorBase)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    local w, h = size.x, size.y
    if w <= 0 then w = imgui.GetContentRegionAvail().x end
    local bgColor = imgui.GetColorU32Vec4(imgui.ImVec4(0.00, 0.00, 0.00, 0.4))
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), bgColor, h/2) 
    if fraction > 0.01 then
        local f = fraction > 1.0 and 1.0 or fraction
        local col = imgui.GetColorU32Vec4(colorBase)
        draw_list:AddRectFilled(p, imgui.ImVec2(p.x + w * f, p.y + h), col, h/2)
    end
    imgui.Dummy(imgui.ImVec2(w, h))
end

function DrawNeonBorder(thickness, rounding)
    local p = imgui.GetWindowPos()
    local s = imgui.GetWindowSize()
    local dl = imgui.GetWindowDrawList()
    dl:AddRect(p, imgui.ImVec2(p.x + s.x, p.y + s.y), imgui.GetColorU32Vec4(imgui.ImVec4(0.2, 0.6, 1.0, 0.8)), rounding, 15, thickness)
    dl:AddRect(p, imgui.ImVec2(p.x + s.x, p.y + s.y), imgui.GetColorU32Vec4(imgui.ImVec4(0.2, 0.6, 1.0, 0.15)), rounding, 15, thickness + 4.0)
end

function DrawStatCard(label, value, icon, iconColor, width)
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(1.00, 1.00, 1.00, 0.03)) 
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(1.00, 1.00, 1.00, 0.05))
    imgui.BeginChild(label, imgui.ImVec2(width, 75), true)
        imgui.SetCursorPos(imgui.ImVec2(15, 15))
        imgui.BeginGroup()
            imgui.PushFont(nil) 
                imgui.TextColored(imgui.ImVec4(0.70, 0.70, 0.70, 1.0), label:upper())
            imgui.PopFont()
        imgui.EndGroup()
        imgui.SetCursorPos(imgui.ImVec2(15, 40))
        imgui.PushFont(nil) 
            imgui.TextColored(imgui.ImVec4(1.00, 1.00, 1.00, 1.00), value)
        imgui.PopFont()
        local iconSize = 24
        imgui.SetCursorPos(imgui.ImVec2(width - iconSize - 15, 25))
        imgui.SetWindowFontScale(1.5) 
        imgui.TextColored(imgui.ImVec4(iconColor.x, iconColor.y, iconColor.z, 0.4), icon) 
        imgui.SetWindowFontScale(1.0)
    imgui.EndChild()
    imgui.PopStyleColor(2)
end

imgui.OnInitialize(function()
    local config = imgui.ImFontConfig()
    config.MergeMode = true
    config.PixelSnapH = true
    
    imgui.GetIO().Fonts:AddFontFromFileTTF(getWorkingDirectory() .. '\\resource\\fonts\\trebuc.ttf', 15.0, nil, imgui.GetIO().Fonts:GetGlyphRangesCyrillic())
    
    local iconRanges = new.ImWchar[3](faicons.min_range, faicons.max_range, 0)
    imgui.GetIO().Fonts:AddFontFromMemoryCompressedBase85TTF(faicons.get_font_data_base85('solid'), 14, config, iconRanges)
    
    local configBig = imgui.ImFontConfig()
    configBig.MergeMode = false
    configBig.PixelSnapH = true
    bigIconFont = imgui.GetIO().Fonts:AddFontFromMemoryCompressedBase85TTF(faicons.get_font_data_base85('solid'), 45, configBig, iconRanges)
    
    local style = imgui.GetStyle()
    local colors = style.Colors
    local clr = imgui.Col
    local ImVec4 = imgui.ImVec4

    style.WindowRounding    = 8.0
    style.ChildRounding     = 6.0
    style.FrameRounding     = 6.0
    style.PopupRounding     = 8.0
    style.ScrollbarRounding = 8.0
    style.GrabRounding      = 6.0
    
    style.WindowBorderSize  = 0.0 
    style.ChildBorderSize   = 0.0
    style.FrameBorderSize   = 0.0
    
    style.WindowPadding     = imgui.ImVec2(20, 20)
    style.ItemSpacing       = imgui.ImVec2(10, 10)
    style.ScrollbarSize     = 6.0 

    colors[clr.WindowBg]        = ImVec4(0.04, 0.04, 0.06, 1.00)
    colors[clr.ChildBg]         = ImVec4(0.07, 0.07, 0.09, 1.00)
    colors[clr.PopupBg]         = ImVec4(0.05, 0.05, 0.07, 1.00)
    colors[clr.Text]            = ImVec4(0.95, 0.96, 0.98, 1.00)
    colors[clr.TextDisabled]    = ImVec4(0.50, 0.50, 0.50, 1.00)
    colors[clr.Border]          = ImVec4(0, 0, 0, 0)
    colors[clr.Separator]       = ImVec4(1.00, 1.00, 1.00, 0.05)
    colors[clr.Button]          = ImVec4(1.00, 1.00, 1.00, 0.03)
    colors[clr.ButtonHovered]   = ImVec4(1.00, 1.00, 1.00, 0.08)
    colors[clr.ButtonActive]    = ImVec4(1.00, 1.00, 1.00, 0.12)
    colors[clr.FrameBg]         = ImVec4(0.12, 0.12, 0.14, 1.00)
    colors[clr.FrameBgHovered]  = ImVec4(0.18, 0.18, 0.20, 1.00)
    colors[clr.FrameBgActive]   = ImVec4(0.22, 0.22, 0.24, 1.00)
    colors[clr.CheckMark]       = ImVec4(0.00, 0.60, 0.90, 1.00)
    colors[clr.ScrollbarBg]     = ImVec4(0.02, 0.02, 0.02, 0.00)
    colors[clr.ScrollbarGrab]   = ImVec4(0.30, 0.30, 0.35, 1.00)
    colors[clr.ScrollbarGrabHovered] = ImVec4(0.40, 0.40, 0.45, 1.00)
    colors[clr.ScrollbarGrabActive]  = ImVec4(0.50, 0.50, 0.55, 1.00)
    colors[clr.TitleBgActive]   = ImVec4(0.04, 0.04, 0.06, 1.00)
end)

function DrawActionGridButton(label, icon, color, width, height)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    local x, y = p.x, p.y
    
    imgui.PushIDStr(label)
    local clicked = imgui.InvisibleButton("##btn", imgui.ImVec2(width, height))
    local hovered = imgui.IsItemHovered()
    local active = imgui.IsItemActive()
    imgui.PopID()

    local baseCol = imgui.ImVec4(color.x, color.y, color.z, 0.10)
    if active then baseCol = imgui.ImVec4(color.x, color.y, color.z, 0.30)
    elseif hovered then baseCol = imgui.ImVec4(color.x, color.y, color.z, 0.20) end
    
    local rectCol = imgui.GetColorU32Vec4(baseCol)
    local textCol = imgui.GetColorU32Vec4(imgui.ImVec4(1, 1, 1, 0.9))
    local iconCol = imgui.GetColorU32Vec4(imgui.ImVec4(color.x, color.y, color.z, 1.0))

    draw_list:AddRectFilled(imgui.ImVec2(x, y), imgui.ImVec2(x + width, y + height), rectCol, 12.0)
    
    if bigIconFont then imgui.PushFont(bigIconFont) end 
    
    local iconSize = imgui.CalcTextSize(icon)
    local iconY = y + (height * 0.4) - (iconSize.y / 2)
    local iconX = x + (width / 2) - (iconSize.x / 2)
    draw_list:AddText(imgui.ImVec2(iconX, iconY), iconCol, icon)
    
    if bigIconFont then imgui.PopFont() end
    
    imgui.PushFont(nil)
    local labelSize = imgui.CalcTextSize(label)
    local labelY = y + (height * 0.82) - (labelSize.y / 2)
    local labelX = x + (width / 2) - (labelSize.x / 2)
    draw_list:AddText(imgui.ImVec2(labelX, labelY), textCol, label)
    imgui.PopFont()

    return clicked
end

imgui.OnFrame(function() return WinState[0] end, function(player)
    local io = imgui.GetIO()
    local resX, resY = getScreenResolution()
    
    if not cfg.window then cfg.window = { w = 920, h = 600 } end

    imgui.SetNextWindowSize(imgui.ImVec2(cfg.window.w, cfg.window.h), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowPos(imgui.ImVec2(resX * 0.5, resY * 0.5), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
    
    imgui.Begin(u8'MINING MANAGER', WinState, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoTitleBar)
    
    local curSize = imgui.GetWindowSize()
    if curSize.x ~= cfg.window.w or curSize.y ~= cfg.window.h then
        cfg.window.w = curSize.x
        cfg.window.h = curSize.y
    end

    DrawNeonBorder(1.5, imgui.GetStyle().WindowRounding)
    
    local winW = imgui.GetContentRegionAvail().x
    local winH = imgui.GetContentRegionAvail().y
    local startP = imgui.GetCursorScreenPos()

    local headerHeight = 40
    
    imgui.BeginGroup()
        imgui.AlignTextToFramePadding()
        if activeShelfDialog.visible then
            imgui.TextColored(imgui.ImVec4(0.20, 0.60, 1.00, 1.0), faicons('microchip')) 
            imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(1.00, 1.00, 1.00, 0.95), u8(activeShelfDialog.title))
        else
            imgui.TextColored(imgui.ImVec4(0.20, 0.60, 1.00, 1.0), faicons('chart_pie')) 
            imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(1.00, 1.00, 1.00, 0.95), u8"MINING ANALYTICS")
            imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(0.5, 0.5, 0.5, 0.7), u8(" | PayDay: " .. paydayCounter))
        end
    imgui.EndGroup()

    local btnSize = 26
    local spacing = 10
    local currentX = winW - btnSize 
    
    imgui.SetCursorPos(imgui.ImVec2(currentX, 15))
    if imgui.Button(faicons('xmark'), imgui.ImVec2(btnSize, btnSize)) then
        if activeShelfDialog.visible then
            sampSendDialogResponse(D_SHELF, 0, -1, "")
            activeShelfDialog.visible = false
        elseif activeConfirmDialog.visible then
            sampSendDialogResponse(D_CONFIRM, 0, -1, "")
            activeConfirmDialog.visible = false
        else
            sampSendDialogResponse(D_LIST, 0, -1, "")
            WinState[0] = false
            SettingsState[0] = false
            isAutoCollecting = false
            actionLock = false
        end
    end
    
    if not activeShelfDialog.visible then
        currentX = currentX - btnSize - spacing
        imgui.SetCursorPos(imgui.ImVec2(currentX, 15))
        if imgui.Button(faicons('gear'), imgui.ImVec2(btnSize, btnSize)) then SettingsState[0] = not SettingsState[0] end
        
        currentX = currentX - btnSize - spacing - 10 
        imgui.SetCursorPos(imgui.ImVec2(currentX, 15))
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(1.0, 0.7, 0.0, 0.1))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.7, 0.0, 0.2))
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 0.8, 0.2, 1.0))
        if imgui.Button(faicons('cart_shopping'), imgui.ImVec2(btnSize + 10, btnSize)) then os.execute('explorer "https://t.me/rdnMarket"') end
        imgui.PopStyleColor(3)
    end
    
    if SettingsState[0] then
        local centerPos = imgui.GetWindowPos()
        centerPos.x = centerPos.x + (imgui.GetWindowWidth() * 0.5)
        centerPos.y = centerPos.y + (imgui.GetWindowHeight() * 0.5)
        
        imgui.SetNextWindowPos(centerPos, imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(500, 320))
        
        imgui.Begin(u8"MiningSettings", SettingsState, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoTitleBar)
            DrawNeonBorder(1.5, imgui.GetStyle().WindowRounding)
            imgui.BeginGroup()
                imgui.TextColored(imgui.ImVec4(0.6, 0.6, 0.6, 1.0), faicons('gear'))
                imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), u8"НАСТРОЙКИ СКРИПТА")
            imgui.EndGroup()
            imgui.SameLine()
            imgui.SetCursorPosX(imgui.GetWindowWidth() - 35)
            if imgui.Button(faicons('xmark'), imgui.ImVec2(25, 25)) then SettingsState[0] = false end
            
            imgui.Separator(); imgui.Dummy(imgui.ImVec2(0, 10))
            
            imgui.TextColored(imgui.ImVec4(0.2, 0.6, 1.0, 1.0), faicons('plane')..u8" Telegram уведомления")
            imgui.Dummy(imgui.ImVec2(0, 5))
            imgui.Checkbox(u8" Включить уведомления", inputEnabled)
            imgui.Dummy(imgui.ImVec2(0, 5))
            imgui.PushItemWidth(300)
            imgui.InputText(u8"Token Бота", inputToken, 128, imgui.InputTextFlags.Password)
            imgui.InputText(u8"Ваш Chat ID", inputChatId, 128)
            imgui.PopItemWidth()
            imgui.Dummy(imgui.ImVec2(0, 10))
            imgui.Separator(); imgui.Dummy(imgui.ImVec2(0, 5))
            
            imgui.TextColored(imgui.ImVec4(1.0, 0.7, 0.2, 1.0), faicons('crown')..u8" Прочее")
            imgui.Checkbox(u8" Аксессуар: RTX 4090 (+25% скорости)", inputRtx)
            
            imgui.Dummy(imgui.ImVec2(0, 15))
            imgui.SetCursorPosX((imgui.GetWindowWidth() - 200) / 2)
            if imgui.Button(u8"СОХРАНИТЬ", imgui.ImVec2(200, 35)) then
                cfg.telegram.token = ffi.string(inputToken)
                cfg.telegram.chatId = ffi.string(inputChatId)
                cfg.telegram.enabled = inputEnabled[0]
                cfg.hasRtx4090 = inputRtx[0]
                json('settings.json'):save(cfg)
                sampAddChatMessage("[Mining] Настройки сохранены.", 0x4ea8de)
                SettingsState[0] = false
            end
        imgui.End()
    end
    
    if activeShelfDialog.visible then
        local footerHeight = 50
        local topPadding = 10
        local availableH = winH - headerHeight - footerHeight - topPadding
        local availableW = winW
        local cols = 2; local rows = 2; local gap = 15
        local btnWidth = (availableW - gap) / cols
        local btnHeight = (availableH - gap) / rows
        if btnHeight < 80 then btnHeight = 80 end; if btnHeight > 180 then btnHeight = 180 end
        
        imgui.SetCursorPosY(headerHeight + topPadding)
        imgui.BeginGroup()
            local colCount = 0
            for i, action in ipairs(activeShelfDialog.actions) do
                if colCount > 0 then imgui.SameLine(0, gap) end
                if DrawActionGridButton(u8(action.label), action.icon, action.color, btnWidth, btnHeight) then
                    sampSendDialogResponse(D_SHELF, 1, action.listId, "")
                    activeShelfDialog.visible = false
                end
                colCount = colCount + 1
                if colCount >= cols then colCount = 0; imgui.Dummy(imgui.ImVec2(0, gap)) end
            end
        imgui.EndGroup()
        
        imgui.SetCursorPosY(winH - 45)
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(1, 1, 1, 0.05))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1, 1, 1, 0.1))
        if imgui.Button(faicons('arrow_left') .. u8"  Вернуться к списку", imgui.ImVec2(-1, 40)) then
            sampSendDialogResponse(D_SHELF, 0, -1, "")
            activeShelfDialog.visible = false
        end
        imgui.PopStyleColor(2)

    elseif activeConfirmDialog.visible then
        local availH = winH - headerHeight
        
        imgui.SetCursorPosY(headerHeight + (availH * 0.15))
        
        local iconSize = 80
        imgui.SetCursorPosX((winW - iconSize) / 2)
        if bigIconFont then imgui.PushFont(bigIconFont) end
        imgui.TextColored(imgui.ImVec4(1.0, 0.8, 0.2, 1.0), faicons('coins'))
        if bigIconFont then imgui.PopFont() end
        
        imgui.PushFont(nil)
        
        local title = u8"ПОДТВЕРЖДЕНИЕ ВЫВОДА"
        local titleW = imgui.CalcTextSize(title).x
        imgui.SetCursorPosX((winW - titleW) / 2)
        imgui.TextColored(imgui.ImVec4(1, 1, 1, 0.5), title)
        
        imgui.Dummy(imgui.ImVec2(0, 10))
        
        local amountStr = activeConfirmDialog.amount .. " BTC"
        imgui.SetWindowFontScale(2.0)
        local amountW = imgui.CalcTextSize(amountStr).x
        imgui.SetCursorPosX((winW - amountW) / 2)
        imgui.TextColored(imgui.ImVec4(0.4, 0.9, 0.4, 1.0), amountStr)
        imgui.SetWindowFontScale(1.0)
        
        imgui.Dummy(imgui.ImVec2(0, 5))
        
        local sub = u8"(Всего добыто: " .. activeConfirmDialog.fullAmount .. " BTC)"
        local subW = imgui.CalcTextSize(sub).x
        imgui.SetCursorPosX((winW - subW) / 2)
        imgui.TextColored(imgui.ImVec4(1, 1, 1, 0.3), sub)
        
        imgui.PopFont()
        
        imgui.SetCursorPosY(winH - 70)
        
        local btnW = (winW - 40) / 2
        local btnH = 50
        
        imgui.SetCursorPosX(15)
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(1, 0.3, 0.3, 0.15))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1, 0.3, 0.3, 0.3))
        if imgui.Button(u8"ОТМЕНА", imgui.ImVec2(btnW, btnH)) then
            sampSendDialogResponse(D_CONFIRM, 0, -1, "")
            activeConfirmDialog.visible = false
        end
        imgui.PopStyleColor(2)
        
        imgui.SameLine()
        
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.4, 0.9, 0.4, 0.2))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.4, 0.9, 0.4, 0.4))
        if imgui.Button(u8"ПОДТВЕРДИТЬ", imgui.ImVec2(btnW, btnH)) then
            sampSendDialogResponse(D_CONFIRM, 1, -1, "")
            activeConfirmDialog.visible = false
            sampAddChatMessage("[Mining] Успешный вывод средств.", 0x4ea8de)
        end
        imgui.PopStyleColor(2)

    else
        
        imgui.SetCursorPosY(headerHeight + 5)

        local stats = calculateGlobalStats()
        local cardGap = 10
        local cardWidth = (winW - (cardGap * 3)) / 4
        
        DrawStatCard(u8'ОБЩИЙ БАЛАНС', string.format('%.4f BTC', stats.totalProfit), faicons('coins'), imgui.ImVec4(1.00, 0.80, 0.20, 1.0), cardWidth)
        imgui.SameLine()
        DrawStatCard(u8'СКОРОСТЬ ФЕРМЫ', string.format(u8'%.4f BTC/ч', stats.totalSpeed), faicons('bolt'), imgui.ImVec4(0.2, 0.8, 1.0, 1.0), cardWidth)
        imgui.SameLine()
        DrawStatCard(u8'ДОХОД ЗА 24Ч', string.format('%.4f BTC', stats.dailyProfit), faicons('calendar_check'), imgui.ImVec4(0.4, 0.9, 0.4, 1.0), cardWidth)
        imgui.SameLine()
        
        local fullTimeStr = u8"Не работает"
        local fullColor = imgui.ImVec4(0.5, 0.5, 0.5, 1.0)
        if stats.workingCount > 0 then
            if stats.nextFullPayDays <= 0 then
                fullTimeStr = u8"ЗАПОЛНЕНО!"
                fullColor = imgui.ImVec4(1.0, 0.3, 0.3, 1.0)
            else
                fullTimeStr = string.format("%d PayDay", stats.nextFullPayDays)
                fullColor = (stats.nextFullPayDays <= 2) and imgui.ImVec4(1.0, 0.6, 0.2, 1.0) or imgui.ImVec4(0.2, 0.8, 0.5, 1.0)
            end
        end
        DrawStatCard(u8'СЛЕД. ЗАПОЛНЕНИЕ', fullTimeStr, faicons('hourglass'), fullColor, cardWidth)

        imgui.Dummy(imgui.ImVec2(0, 10))
        
        local btnHeight = 40
        
        if isAutoCollecting then
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.6, 1.0, 0.1))
            animTime = animTime + imgui.GetIO().DeltaTime
            local phase = animTime % 1.5
            local dots = (phase > 1.0 and "...") or (phase > 0.5 and "..") or "."
            
            local statusStr = u8' ВЫПОЛНЕНИЕ ЗАДАЧ'
            if currentTaskType == 'collect' then statusStr = u8' СБОР ПРИБЫЛИ'
            elseif currentTaskType == 'restore' then statusStr = u8' ЗАЛИВКА ЖИДКОСТИ'
            elseif currentTaskType == 'start' then statusStr = u8' ЗАПУСК ВИДЕОКАРТ' end
            
            if imgui.Button(faicons('arrows_rotate').. statusStr .. dots, imgui.ImVec2(-1, btnHeight)) then
                isAutoCollecting = false; specificAction = nil
                sampAddChatMessage("[Mining] Автоматизация остановлена.", -1)
            end
            imgui.PopStyleColor()
        else
            local countCollect, countRestore, countStart = 0, 0, 0
            for _, item in ipairs(shelvesData) do
                if item.profit >= 1.0 then countCollect = countCollect + 1 end
                if item.cooling < 50 then countRestore = countRestore + 1 end
                if item.status:find("На паузе") or item.status:find("Выключ") then countStart = countStart + 1 end
            end

            imgui.Columns(3, "ActionButtons", false)
            local function DrawGlobalBtn(icon, label, count, color, action)
                 if count > 0 then
                    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(color.x, color.y, color.z, 0.6))
                    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(color.x, color.y, color.z, 0.8))
                else
                    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(1, 1, 1, 0.05))
                    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1, 1, 1, 0.05))
                end
                if imgui.Button(icon..u8(label.." ("..count..")"), imgui.ImVec2(-1, btnHeight)) and count > 0 then startMiningAction(action) end
                imgui.PopStyleColor(2)
            end
            
            DrawGlobalBtn(faicons('coins').." ", " Собрать", countCollect, imgui.ImVec4(0.1, 0.7, 0.3, 1), 'collect')
            imgui.NextColumn()
            DrawGlobalBtn(faicons('droplet').." ", " Жидкость", countRestore, imgui.ImVec4(0.0, 0.5, 0.9, 1), 'restore')
            imgui.NextColumn()
            DrawGlobalBtn(faicons('power_off').." ", " Запуск", countStart, imgui.ImVec4(0.9, 0.5, 0.0, 1), 'start')
            imgui.NextColumn()
            imgui.Columns(1)
            
            if countCollect + countRestore + countStart > 0 then
                imgui.Dummy(imgui.ImVec2(0, 5))
                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(1, 1, 1, 0.1))
                if imgui.Button(u8"ВЫПОЛНИТЬ ВСЕ ДЕЙСТВИЯ СРАЗУ (Пробел)", imgui.ImVec2(-1, 30)) then startMiningAction('all') end
                imgui.PopStyleColor()
            end
        end

        imgui.Dummy(imgui.ImVec2(0, 5)) 
        
        local cw = imgui.GetContentRegionAvail().x
        local col_w = {
            id = cw * 0.03,
            status = cw * 0.15,
            liquid = cw * 0.40, 
            balance = cw * 0.65,
            time = cw * 0.85
        }

        imgui.BeginGroup()
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.55, 0.6, 1.0))
            imgui.SetCursorPosX(col_w.id + 8)  imgui.Text("#")
            imgui.SameLine(col_w.status + 8)   imgui.Text(u8"СТАТУС")
            imgui.SameLine(col_w.liquid + 8)   imgui.Text(u8"ОХЛАЖДЕНИЕ")
            imgui.SameLine(col_w.balance + 8)  imgui.Text(u8"ПРИБЫЛЬ")
            imgui.SameLine(col_w.time + 8)     imgui.Text(u8"ПРОГНОЗ")
            imgui.PopStyleColor()
        imgui.EndGroup()
        
        imgui.Separator()

        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0,0,0,0))
        imgui.BeginChild("CardsList", imgui.ImVec2(0, 0), false) 
            
            local ROW_HEIGHT = 55.0 
            local dl = imgui.GetWindowDrawList()
            
            cw = imgui.GetContentRegionAvail().x 
            col_w = {
                id = cw * 0.03,
                status = cw * 0.12,
                liquid = cw * 0.35,
                balance = cw * 0.65,
                time = cw * 0.82
            }

            for i, item in ipairs(shelvesData) do
                local p = imgui.GetCursorScreenPos()
                local p_end = imgui.ImVec2(p.x + cw, p.y + ROW_HEIGHT)
                
                local isActive = (isAutoCollecting and i == currentTaskIndex)
                
                local bgCol = imgui.ImVec4(1, 1, 1, 0.03) 
                if isActive then bgCol = imgui.ImVec4(0.2, 0.6, 1.0, 0.15)
                elseif imgui.IsMouseHoveringRect(p, p_end) then bgCol = imgui.ImVec4(1, 1, 1, 0.07) end
                
                dl:AddRectFilled(p, p_end, imgui.GetColorU32Vec4(bgCol), 6.0)
                
                local textCenterY = (ROW_HEIGHT - imgui.CalcTextSize("A").y) / 2
                
                dl:AddText(imgui.ImVec2(p.x + col_w.id + 5, p.y + textCenterY), imgui.GetColorU32Vec4(imgui.ImVec4(1,1,1,0.3)), tostring(item.shelf))
                
                local isWorking = item.status:find("Работает")
                local stIcon = isWorking and faicons('circle_check') or faicons('circle_xmark')
                local stColor = isWorking and imgui.ImVec4(0.4, 0.9, 0.4, 1.0) or imgui.ImVec4(0.9, 0.3, 0.3, 1.0)
                
                dl:AddText(imgui.ImVec2(p.x + col_w.status, p.y + textCenterY), imgui.GetColorU32Vec4(stColor), stIcon)
                dl:AddText(imgui.ImVec2(p.x + col_w.status + 25, p.y + textCenterY), imgui.GetColorU32Vec4(imgui.ImVec4(0.9, 0.9, 0.9, 0.9)), isWorking and u8"В работе" or u8"Стоп")
                
                local barW = cw * 0.20
                local barH = 8.0
                local barX = p.x + col_w.liquid
                local barY = p.y + (ROW_HEIGHT - barH) / 2
                
                local barColor = imgui.ImVec4(0.2, 0.6, 1.0, 1.0)
                if item.cooling < 50 then barColor = imgui.ImVec4(0.9, 0.3, 0.3, 1.0)
                elseif item.cooling < 80 then barColor = imgui.ImVec4(1.0, 0.7, 0.0, 1.0) end
                
                dl:AddRectFilled(imgui.ImVec2(barX, barY), imgui.ImVec2(barX + barW, barY + barH), imgui.GetColorU32Vec4(imgui.ImVec4(1,1,1,0.1)), 4.0)
                if item.cooling > 0 then
                    local fillW = barW * (item.cooling / 100.0)
                    dl:AddRectFilled(imgui.ImVec2(barX, barY), imgui.ImVec2(barX + fillW, barY + barH), imgui.GetColorU32Vec4(barColor), 4.0)
                end
                dl:AddText(imgui.ImVec2(barX + barW + 10, p.y + textCenterY), imgui.GetColorU32Vec4(imgui.ImVec4(1,1,1,0.6)), string.format("%d%%", item.cooling))

                local profitStr = string.format('%.4f', item.profit)
                dl:AddText(imgui.ImVec2(p.x + col_w.balance, p.y + textCenterY), 
                           item.profit > 0 and imgui.GetColorU32Vec4(imgui.ImVec4(1, 1, 1, 0.9)) or imgui.GetColorU32Vec4(imgui.ImVec4(1,1,1,0.2)), 
                           profitStr)
                if item.profit > 0 then
                   dl:AddText(imgui.ImVec2(p.x + col_w.balance + imgui.CalcTextSize(profitStr).x + 5, p.y + textCenterY), imgui.GetColorU32Vec4(imgui.ImVec4(1, 0.84, 0, 1)), faicons('coin'))
                end
                
                local timeStr = formatTimeLeft(item.profit, item.level)
                local isFull = (9.0 - item.profit) <= 0
                local timeCol = isFull and imgui.ImVec4(1.0, 0.3, 0.3, 1.0) or imgui.ImVec4(0.5, 0.8, 1.0, 0.8)
                dl:AddText(imgui.ImVec2(p.x + col_w.time, p.y + textCenterY), imgui.GetColorU32Vec4(timeCol), u8(timeStr))
                
                local btnSz = 30
                local btnX = p.x + cw - btnSz - 15
                local btnY = p.y + (ROW_HEIGHT - btnSz) / 2

                imgui.SetCursorScreenPos(imgui.ImVec2(btnX, btnY))
                
                if isActive then
                    imgui.TextColored(imgui.ImVec4(0.4, 0.7, 1.0, 1.0), faicons('spinner'))
                else
                    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(1,1,1,0.05))
                    imgui.PushIDInt(i)
                    if imgui.Button(faicons('gear'), imgui.ImVec2(btnSz, btnSz)) then 
                        sampSendDialogResponse(D_LIST, 1, item.listId, "") 
                    end
                    imgui.PopID()
                    imgui.PopStyleColor()
                end
                
                imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + ROW_HEIGHT + 5))
            end
            
        imgui.EndChild() 
        imgui.PopStyleColor()
    end
    imgui.End()
end)