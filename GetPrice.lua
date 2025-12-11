script_name("RODINAMARKET")
script_author("sVor / Refactored by Gemini + Pickup Parser")
script_version("12.2 Elite UI + Pickup")

local imgui = require 'mimgui'
local ffi = require 'ffi'
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local ev = require 'lib.samp.events'
local json = require 'cjson'
local lfs = require 'lfs'

local theme = {
    bg          = imgui.ImVec4(0.06, 0.06, 0.11, 0.94), -- Темно-синий прозрачный фон
    sidebar     = imgui.ImVec4(0.05, 0.05, 0.09, 0.90), 
    
    -- Акцент (Оранжевый/Золотой как в ARZ)
    accent      = imgui.ImVec4(0.95, 0.55, 0.15, 1.00), 
    accent_hov  = imgui.ImVec4(1.00, 0.65, 0.20, 1.00), 
    accent_dim  = imgui.ImVec4(0.95, 0.55, 0.15, 0.20),
    
    -- Элементы
    item_bg     = imgui.ImVec4(0.08, 0.08, 0.14, 0.60), 
    item_bg_hov = imgui.ImVec4(0.12, 0.12, 0.18, 0.80),
    
    input_bg    = imgui.ImVec4(0.03, 0.03, 0.05, 0.90), -- Почти черные поля ввода
    border      = imgui.ImVec4(0.20, 0.20, 0.30, 0.50), 
    
    text        = imgui.ImVec4(0.95, 0.95, 0.95, 1.00),
    text_dim    = imgui.ImVec4(0.60, 0.60, 0.70, 1.00),
    
    red         = imgui.ImVec4(0.90, 0.30, 0.30, 1.00),
    green       = imgui.ImVec4(0.30, 0.90, 0.50, 1.00)
}

-- [[ Конфигурация ]]
local configDir = getWorkingDirectory() .. "\\config\\RODINAMARKET\\"
local shopCacheFile = configDir .. "shop_scanned_cache.json"
local itemsData = {} 
local settings = {
    lastScanDate = nil,
    showAllItems = false
}

-- [[ Пикап-сканер ]]
local isPickupScanning = false
local scanProgress = 0
local totalItemsScanned = 0
local currentScanPage = 1
local totalScanPages = 1

-- [[ UI State ]]
local WinState = imgui.new.bool(false)
local SearchBuffer = imgui.new.char[256]()
local SelectedItemKey = nil
local FilteredKeys = {} 
local LastSearchText = ""
local TotalItemsCount = 0

-- [[ ЛОГИ И СТАТИСТИКА ]] --
local logsFile = configDir .. "market_logs.json"
local marketLogs = {} 
local selectedLogDate = os.date("%d.%m.%Y")
local logSearchBuffer = imgui.new.char[256]()
local logSortType = 1 
local logFilterType = 1 -- 1: Все, 2: Продажи, 3: Покупки (НОВОЕ)
local logStats = { earned = 0, spent = 0, profit = 0, items_sold = 0, items_bought = 0 }

local ITEMS_JSON_FILE = configDir .. "items.json"
local itemNamesById = {}

-- [[ UI Settings ]]
local SIDEBAR_WIDTH = 280
local showSearchResults = false

local searchBarHeight = 0.0
local searchBarAlpha = 0.0
local SEARCH_TARGET_HEIGHT = 60.0

-- [[ Шрифты ]]
local fonts = {
    main = nil,
    bold = nil,
    big = nil
}

local isShopScanning = false
local isAutoBuying = false
local buyingQueue = {} -- Очередь товаров для выставления
local currentBuyingIndex = 1
local buyingFinished = false -- Флаг завершения процесса
local shopScanProgress = 0
local totalShopItemsScanned = 0
local currentShopScanPage = 1
local totalShopScanPages = 1
local shopItems = {} -- Все товары из лавки
local wantedItems = {} -- Товары для скупа {count = количество, price = цена}
local showShopScanButton = true
local lastScannedShopDate = nil

-- [[ UI ДЛЯ СКУПА ]] --
local shopSearchBuffer = imgui.new.char[256]()
local selectedShopItem = nil
local filteredShopItems = {}
local wantedItemsBuffer = {}
local shopConfigName = imgui.new.char[128]()
local shopFindBuffer = imgui.new.char[256]()
local shopFilteredItems = {}
local shopRefreshTable = false

local inventoryScanning = false
local inventoryScanProgress = 0.0
local playerInventoryItems = {} 
local selectedForSale = {} -- <--- ADD THIS LINE HERE
local lastInventoryScanTime = 0
local inventoryWaitingForModal = false
local MAX_INV_SLOTS = 180

local itemsData = {} 
local itemNamesById = {}

function loadItemsNames()
    if doesFileExist(ITEMS_JSON_FILE) then
        local f = io.open(ITEMS_JSON_FILE, "r")
        if f then
            local raw = f:read("*a")
            f:close()
            if raw then
                local status, res = pcall(json.decode, raw)
                if status and res then
                    itemNamesById = res
                    printDebug(string.format("Загружено %d названий предметов", getTableSize(itemNamesById)))
                else
                    printDebug("Ошибка декодирования items.json")
                end
            end
        else
            printDebug("Не удалось открыть items.json")
        end
    else
        printDebug("Файл items.json не найден")
    end
end

-- [[ PACKET HELPERS ]]
-- Sends a CEF event to the server (clicks)
function sendCefAction(payload)
	local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 220)
    raknetBitStreamWriteInt8(bs, 18)
    raknetBitStreamWriteInt16(bs, #payload)
    raknetBitStreamWriteString(bs, payload)
    raknetBitStreamWriteInt32(bs, 0)
    raknetSendBitStream(bs)
    raknetDeleteBitStream(bs)
end

-- Closes the item info modal so the script can proceed
function closeCefModal()
    sendCefAction('sendResponse|0|0|1|')
    sendCefAction('window.executeEvent(\'cef.modals.closeModal\', `["dialog"]`);')
end

function startInventoryScanning()
    if inventoryScanning then return end
    
    playerInventoryItems = {} -- Clear previous result
    inventoryScanning = true
    inventoryScanProgress = 0.0
    
    systemMessage("Запуск сканирования инвентаря...")
    systemMessage("Открываю инвентарь...")
    
    -- Открываем инвентарь
    sampSendChat("/invent")
    
    lua_thread.create(function()
        wait(1500) -- Ждем открытия инвентаря
        
        if not inventoryScanning then return end
        
        systemMessage("Жду данные инвентаря... (5 сек)")
        
        local startWaitTime = os.clock()
        while inventoryScanning and (os.clock() - startWaitTime) < 5.0 do
            wait(100)
            
            -- Проверяем, получили ли мы данные инвентаря
            if getTableSize(playerInventoryItems) > 0 then
                break
            end
        end
        
        -- Закрываем инвентарь через CEF
        if inventoryScanning then
            systemMessage("Закрываю инвентарь...")
            sendCefAction("inventoryClose")
            wait(500)
        end
        
        inventoryScanning = false
        lastInventoryScanTime = os.time()
        
        local itemCount = 0
        for _, count in pairs(playerInventoryItems) do
            itemCount = itemCount + count
        end
        
        systemMessage(string.format("Сканирование завершено! Найдено %d предметов (%d уникальных)", 
            itemCount, getTableSize(playerInventoryItems)))
    end)
end

-- [[ PACKET HOOK ]]
-- Add this to your events (ev). If you use `sampev`, ensure you have the `onReceivePacket` handler.
function ev.onReceivePacket(id, bs)
    if id == 220 then
        raknetBitStreamResetReadPointer(bs)
        raknetBitStreamIgnoreBits(bs, 8) -- Пропускаем packet_id (220)
        local packetType = raknetBitStreamReadInt8(bs)
        
        -- Пакет типа 17 (входящий CEF)
        if packetType == 17 then
            raknetBitStreamIgnoreBits(bs, 32) -- Пропускаем _unused
            local length = raknetBitStreamReadInt16(bs)
            local encoded = raknetBitStreamReadInt8(bs)
            
            local str
            if encoded ~= 0 then
                str = raknetBitStreamDecodeString(bs, length + encoded)
            else
                str = raknetBitStreamReadString(bs, length)
            end
            
            -- Парсим инвентарь
            if str and str:find("event.inventory.playerInventory") then
                parseInventoryFromCEF(str)
            end
        end
    end
end

function raknetBitStreamDecodeString(bs, length)
    local decoded = raknetBitStreamReadString(bs, length)
    -- Простая декодировка (может потребоваться адаптация под ваш сервер)
    return decoded:gsub("\\\"", "\""):gsub("\\\\", "\\")
end

function parseInventoryFromCEF(cefStr)
    if not cefStr or not inventoryScanning then return end
    
    -- Ищем JSON данные инвентаря
    local jsonStart = cefStr:find("%[%{")
    local jsonEnd = cefStr:find("%}%]")
    
    if jsonStart and jsonEnd then
        local jsonData = cefStr:sub(jsonStart, jsonEnd)
        
        local status, inventoryData = pcall(json.decode, jsonData)
        if status and inventoryData and type(inventoryData) == "table" then
            for _, invBlock in ipairs(inventoryData) do
                if invBlock.data and invBlock.data.items then
                    for _, slotData in ipairs(invBlock.data.items) do
                        -- Проверяем, что слот доступен и содержит предмет
                        if slotData.available == 1 and slotData.item and slotData.item ~= 0 then
                            local itemId = tostring(slotData.item)
                            local itemName = itemNamesById[itemId]
                            
                            if itemName then
                                -- Преобразуем UTF-8 в CP1251
                                local decodedName = u8:decode(itemName)
                                if playerInventoryItems[decodedName] then
                                    playerInventoryItems[decodedName] = playerInventoryItems[decodedName] + 1
                                else
                                    playerInventoryItems[decodedName] = 1
                                end
                                
                                -- Обновляем прогресс
                                if slotData.slot then
                                    inventoryScanProgress = ((slotData.slot + 1) / MAX_INV_SLOTS) * 100
                                end
                            else
                                printDebug(string.format("Неизвестный ID предмета: %d", slotData.item))
                            end
                        end
                    end
                end
            end
            printDebug(string.format("Парсинг инвентаря: найдено %d уникальных предметов", getTableSize(playerInventoryItems)))
        end
    end
end

function ev.onServerMessage(color, text)
    -- Добавляем общие проверки, чтобы не парсить все сообщения
    if text:find("приобрел у Вас") or text:find("Вы купили") then
        local cleanText = stripColor(text)
        
        -- Единый, более гибкий паттерн для захвата: [КАТЕГОРИЯ] Товар (Кол-во шт.) за Цена
        local item_details_pattern = "[^ ]+ (.+) %((%d+) шт%.%) за ([%d%.]+) руб%."
        local nick, item, count, priceStr

        -- 1. ПРОДАЖА (У нас купили) - Обновленная логика
        local sale_pattern = "Лавка%] (.+) приобрел у Вас " .. item_details_pattern
        nick, item, count, priceStr = cleanText:match(sale_pattern)
        
        if not nick then 
            -- Запасной паттерн для продажи (без [Лавка])
            local sale_fallback_pattern = "(.+) приобрел у Вас " .. item_details_pattern
            nick, item, count, priceStr = cleanText:match(sale_fallback_pattern)
        end
        
        if nick and item and count and priceStr then
            local price = parsePrice(priceStr)
            -- ИСПРАВЛЕНИЕ CRASH: безопасная проверка item на nil и на тип string
            local safeItem = ""
            if type(item) == "string" then
                -- Обрезаем пробелы вручную, так как в Lua нет встроенного trim()
                safeItem = item:gsub("^%s*(.-)%s*$", "%1")
            end
            if safeItem == "" then safeItem = "Неизвестный предмет" end
            addLogEntry("sell", nick, safeItem, count, price)
            return
        end

        -- 2. ПОКУПКА (Мы купили) - Теперь также поддерживает "аксессуар" и другие категории
        -- ПЕРВЫЙ ПАТТЕРН ПОКУПКИ (Ник в конце):
        local buy_pattern_end_nick = "Вы купили " .. item_details_pattern .. " у (.+)"
        item, count, priceStr, nick = cleanText:match(buy_pattern_end_nick)

        if not nick then 
             -- ВТОРОЙ ПАТТЕРН ПОКУПКИ (Ник в начале):
             local buy_pattern_start_nick = "Вы купили у (.+) " .. item_details_pattern
             nick, item, count, priceStr = cleanText:match(buy_pattern_start_nick)
        end
        
        if nick and item and count and priceStr then
            local price = parsePrice(priceStr)
            -- ИСПРАВЛЕНИЕ CRASH: безопасная проверка item на nil и на тип string
            local safeItem = ""
            if type(item) == "string" then
                -- Обрезаем пробелы вручную, так как в Lua нет встроенного trim()
                safeItem = item:gsub("^%s*(.-)%s*$", "%1")
            end
            if safeItem == "" then safeItem = "Неизвестный предмет" end
            addLogEntry("buy", nick, safeItem, count, price)
            return
        end
    end
end

function getDayProfit(dateKey)
    local logs = marketLogs[dateKey]
    if not logs then return 0 end
    local prof = 0
    for _, entry in ipairs(logs) do
        if entry.type == "sell" then prof = prof + entry.price
        elseif entry.type == "buy" then prof = prof - entry.price end
    end
    return prof
end

function renderLogsPage()
    local contentWidth = imgui.GetContentRegionAvail().x
    local contentHeight = imgui.GetContentRegionAvail().y
    local draw_list = imgui.GetWindowDrawList()

    -- Разделяем на Сайдбар (Даты) и Контент (Логи)
    imgui.Columns(2, "LogsCols", true)
    
    if isFirstFrame then imgui.SetColumnWidth(0, 180) end -- Чуть шире для отображения сумм
    
    -- [[ КОЛОНКА 1: ДАТЫ ]]
    imgui.BeginChild("LogDates", imgui.ImVec2(0, contentHeight), true)
        imgui.TextColored(theme.accent, u8"История операций")
        imgui.Separator()
        
        -- Сбор и сортировка дат
        local dates = {}
        for date, _ in pairs(marketLogs) do table.insert(dates, date) end
        table.sort(dates, function(a,b) 
            local d1,m1,y1 = a:match("(%d+).(%d+).(%d+)")
            local d2,m2,y2 = b:match("(%d+).(%d+).(%d+)")
            return os.time({day=d1,month=m1,year=y1}) > os.time({day=d2,month=m2,year=y2})
        end)
        
        if #dates == 0 then
            imgui.TextColored(theme.text_dim, u8"Нет данных")
        end

        for _, date in ipairs(dates) do
            local isSelected = (date == selectedLogDate)
            local dayProfit = getDayProfit(date)
            
            -- Стиль кнопки
            if isSelected then 
                imgui.PushStyleColor(imgui.Col.Button, theme.accent)
                imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.1, 0.1, 0.1, 1))
            else
                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0,0,0,0))
                imgui.PushStyleColor(imgui.Col.Text, theme.text)
            end
            
            -- Отрисовка кнопки даты
            if imgui.Button(date .. "##Date" .. date, imgui.ImVec2(-1, 35)) then
                selectedLogDate = date
                calculateLogStats()
            end
            
            -- Отображение профита поверх кнопки (справа)
            if not isSelected then -- Если выбрано, цвет текста черный, подгонять сложнее, показываем только на неактивных
                local profitText = (dayProfit >= 0 and "+" or "") .. formatNumber(dayProfit) .. "$"
                local profitColor = (dayProfit >= 0) and theme.green or theme.red
                local txtSz = imgui.CalcTextSize(profitText)
                
                local pMin = imgui.GetItemRectMin()
                local pMax = imgui.GetItemRectMax()
                
                imgui.SetCursorScreenPos(imgui.ImVec2(pMax.x - txtSz.x - 5, pMin.y + (35 - txtSz.y)/2))
                imgui.TextColored(profitColor, profitText)
                -- Возвращаем курсор обратно для ImGui layout flow (хотя для кнопки это не критично)
                imgui.SetCursorScreenPos(imgui.ImVec2(pMin.x, pMax.y)) 
            end

            imgui.PopStyleColor(2)
        end
    imgui.EndChild()
    
    imgui.NextColumn()
    
    -- [[ КОЛОНКА 2: СОДЕРЖИМОЕ ]]
    imgui.BeginChild("LogContent", imgui.ImVec2(0, contentHeight), true)
        
        -- 1. КАРТОЧКИ СТАТИСТИКИ (ВЕРХУШКА)
        local statsH = 70
        local cardW = (imgui.GetContentRegionAvail().x - 16) / 3
        
        local function DrawStatCard(label, val, col, x_offset)
            imgui.SetCursorPos(imgui.ImVec2(x_offset, 0))
            local p = imgui.GetCursorScreenPos()
            
            -- Фон карточки
            draw_list:AddRectFilled(p, imgui.ImVec2(p.x + cardW, p.y + statsH), imgui.GetColorU32Vec4(imgui.ImVec4(1,1,1,0.03)), 6.0)
            draw_list:AddRect(p, imgui.ImVec2(p.x + cardW, p.y + statsH), imgui.GetColorU32Vec4(imgui.ImVec4(1,1,1,0.05)), 6.0)
            
            -- Текст
            imgui.SetCursorPos(imgui.ImVec2(x_offset + 10, 8))
            imgui.TextColored(theme.text_dim, u8(label))
            
            imgui.SetCursorPos(imgui.ImVec2(x_offset + 10, 30))
            imgui.PushFont(fonts.big)
            imgui.TextColored(col, formatNumber(val) .. " $")
            imgui.PopFont()
        end
        
        DrawStatCard("Заработано", logStats.earned, theme.green, 0)
        DrawStatCard("Потрачено", logStats.spent, theme.red, cardW + 8)
        DrawStatCard("Чистая прибыль", logStats.profit, (logStats.profit >= 0 and theme.accent or theme.red), (cardW + 8) * 2)
        
        imgui.SetCursorPosY(statsH + 10)
        imgui.Separator()
        imgui.SetCursorPosY(imgui.GetCursorPosY() + 10)
        
        -- 2. ФИЛЬТРЫ И ПОИСК
        imgui.BeginGroup()
            -- Кнопки фильтров
            local function FilterBtn(label, typeId)
                if logFilterType == typeId then
                    imgui.PushStyleColor(imgui.Col.Button, theme.accent)
                    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.05, 0.05, 0.05, 1))
                else
                    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(1,1,1,0.05))
                    imgui.PushStyleColor(imgui.Col.Text, theme.text)
                end
                
                if imgui.Button(u8(label), imgui.ImVec2(100, 26)) then logFilterType = typeId end
                imgui.PopStyleColor(2)
            end
            
            FilterBtn("Все", 1)
            imgui.SameLine()
            FilterBtn("Продажи", 2)
            imgui.SameLine()
            FilterBtn("Покупки", 3)
            
            imgui.SameLine()
        imgui.EndGroup()
        
        imgui.Spacing()
        
        -- 3. СПИСОК ТРАНЗАКЦИЙ
        imgui.BeginChild("LogListScroller", imgui.ImVec2(0, 0), true)
            local currentLogs = marketLogs[selectedLogDate] or {}
            
            -- Подготовка (фильтрация)
            local displayLogs = {}
            local search = ffi.string(logSearchBuffer)
            local searchLower = u8:decode(search):lower()
            
            for _, entry in ipairs(currentLogs) do
                local match = true
                
                -- Фильтр по типу
                if logFilterType == 2 and entry.type ~= "sell" then match = false end
                if logFilterType == 3 and entry.type ~= "buy" then match = false end
                
                -- Поиск
                if match and searchLower ~= "" then
                    local itemLower = entry.item:lower()
                    local nickLower = entry.nick:lower()
                    if not itemLower:find(searchLower, 1, true) and not nickLower:find(searchLower, 1, true) then
                        match = false
                    end
                end
                
                if match then table.insert(displayLogs, entry) end
            end
            
            -- Сортировка: Свежие сверху
            table.sort(displayLogs, function(a, b) return a.unix > b.unix end)
            
            -- Отрисовка
            for i, entry in ipairs(displayLogs) do
                local p = imgui.GetCursorScreenPos()
                local rowH = 50
                local availW = imgui.GetContentRegionAvail().x
                
                -- Подложка
                local bgColor = imgui.ImVec4(0.08, 0.08, 0.1, 0.4)
                if i % 2 == 0 then bgColor = imgui.ImVec4(0.1, 0.1, 0.12, 0.4) end
                
                draw_list:AddRectFilled(p, imgui.ImVec2(p.x + availW, p.y + rowH), imgui.GetColorU32Vec4(bgColor), 4.0)
                
                -- Цветная полоска слева (Индикатор типа)
                local typeColor = (entry.type == "sell") and theme.green or theme.red
                draw_list:AddRectFilled(p, imgui.ImVec2(p.x + 4, p.y + rowH), imgui.GetColorU32Vec4(typeColor), 4.0)
                
                -- Время
                imgui.SetCursorPos(imgui.ImVec2(15, imgui.GetCursorPosY() + 15))
                imgui.TextColored(theme.text_dim, entry.time:sub(1, 5)) -- Только HH:MM
                
                -- Иконка действия (текстовая)
                imgui.SameLine(70)
                imgui.SetCursorPosY(imgui.GetCursorPosY() - 2)
                local typeLabel = (entry.type == "sell") and u8"ПРОДАЖА" or u8"ПОКУПКА"
                
                -- Маленький бейдж для типа
                local badgeColor = (entry.type == "sell") and imgui.ImVec4(0.2, 0.6, 0.3, 0.2) or imgui.ImVec4(0.6, 0.2, 0.2, 0.2)
                local badgeP = imgui.GetCursorScreenPos()
                local badgeSz = imgui.CalcTextSize(typeLabel)
                badgeSz.x = badgeSz.x + 10
                badgeSz.y = badgeSz.y + 4
                
                draw_list:AddRectFilled(badgeP, imgui.ImVec2(badgeP.x + badgeSz.x, badgeP.y + badgeSz.y), imgui.GetColorU32Vec4(badgeColor), 4.0)
                imgui.SetCursorPosX(imgui.GetCursorPosX() + 5)
                imgui.TextColored(typeColor, typeLabel)
                
                -- Товар и Ник
                imgui.SameLine(160)
                imgui.SetCursorPosY(imgui.GetCursorPosY() - 11) -- Чуть выше для первой строки
                imgui.BeginGroup()
                    imgui.Text(u8(entry.item)) -- Название
                    
                    imgui.PushStyleColor(imgui.Col.Text, theme.text_dim)
                    local infoText = string.format("%s | %d шт.", entry.nick, entry.count)
                    imgui.Text(u8(infoText)) -- Ник и кол-во
                    imgui.PopStyleColor()
                imgui.EndGroup()
                
                -- Цена (Справа)
                local priceStr = (entry.type == "sell" and "+" or "-") .. formatNumber(entry.price) .. " $"
                local priceSz = imgui.CalcTextSize(priceStr)
                
                imgui.SameLine(availW - priceSz.x - 15)
                imgui.SetCursorPosY(imgui.GetCursorPosY() + 8) -- Центрируем по высоте
                imgui.PushFont(fonts.big)
                imgui.TextColored((entry.type == "sell" and theme.green or theme.red), priceStr)
                imgui.PopFont()
                
                -- Отступ после строки
                imgui.SetCursorPosY(imgui.GetCursorPosY() + rowH - 26) 
                imgui.SetCursorPosY(imgui.GetCursorPosY() + 5) -- Отступ между карточками
            end
            
            if #displayLogs == 0 then
                imgui.SetCursorPos(imgui.ImVec2(20, 20))
                imgui.TextColored(theme.text_dim, u8"Записи не найдены")
            end
            
        imgui.EndChild()
        
    imgui.EndChild()
    imgui.Columns(1)
end

function saveScannedShopItems()
    local exportData = {}
    for name, data in pairs(shopItems) do
        exportData[u8(name)] = data
    end
    
    local f = io.open(shopCacheFile, "w")
    if f then
        f:write(json.encode(exportData))
        f:close()
    end
end

function loadScannedShopItems()
    if doesFileExist(shopCacheFile) then
        local f = io.open(shopCacheFile, "r")
        if f then
            local raw = f:read("*a")
            f:close()
            if raw then
                local status, res = pcall(json.decode, raw)
                if status and res then
                    shopItems = {}
                    for name, data in pairs(res) do
                        shopItems[u8:decode(name)] = data
                    end
                    totalShopItemsScanned = getTableSize(shopItems)
                    updateFilteredShopItems()
                    systemMessage(string.format("Загружен кэш лавки: {2ecc71}%d {FFFFFF}товаров.", totalShopItemsScanned))
                end
            end
        end
    end
end

function startShopScanning()
    if isShopScanning then
        systemMessage("Сканирование уже активно! Откройте лавку (Alt).")
        return
    end
    
    shopItems = {}
    filteredShopItems = {}
    
    isShopScanning = true
    shopScanProgress = 0
    totalShopItemsScanned = 0
    currentShopScanPage = 1
    totalShopScanPages = 1
    showShopScanButton = false
    
    systemMessage("Режим сканирования включен.")
    systemMessage("{e74c3c}Подойдите к лавке и нажмите ALT, чтобы начать сканирование!")
end

function startAutoBuying()
    if getTableSize(wantedItems) == 0 then
        systemMessage("Список скупа пуст! Добавьте товары.")
        return
    end

    isAutoBuying = true
    buyingQueue = {}
    currentBuyingIndex = 1
    buyingFinished = false

    for name, data in pairs(wantedItems) do
        table.insert(buyingQueue, {
            name = name,
            count = data.count,
            price = data.price,
            id = data.id
        })
    end

    systemMessage(string.format("Запуск выставления на скуп. Товаров в очереди: {2ecc71}%d", #buyingQueue))
    systemMessage("{e74c3c}Подойдите к лавке и нажмите ALT, скрипт сделает остальное.")
end

function finishShopScanning()
    isShopScanning = false
    shopScanProgress = 100
    
    lastScannedShopDate = os.date("%d.%m.%Y %H:%M")
    
    updateFilteredShopItems()
    saveScannedShopItems()
    
    systemMessage(string.format("Сканирование завершено! Найдено {2ecc71}%d {FFFFFF}товаров.", totalShopItemsScanned))
end

function updateFilteredShopItems()
    shopRefreshTable = true
    shopFilteredItems = {}
    
    -- Получаем текст из поиска. Буфер mimgui в UTF-8, нам нужно перевести его в CP1251 для сравнения
    local request = ffi.string(shopFindBuffer)
    local sCP1251 = ""
    pcall(function() sCP1251 = u8:decode(request) end)
    local requestLower = string.lower(sCP1251)
    
    for itemName, itemData in pairs(shopItems) do
        -- itemName УЖЕ в CP1251, не нужно его декодировать!
        local displayName = itemName
        
        -- Убираем префиксы (работаем с CP1251 строками)
        displayName = displayName:gsub("^Аксессуар ", ""):gsub("^Предмет ", ""):gsub("^Оружие ", ""):gsub("^Одежда ", ""):gsub("^Объект ", "")
        
        if requestLower == "" or string.lower(displayName):find(requestLower, 1, true) then
            table.insert(shopFilteredItems, {
                name = itemName,
                id = itemData.id,
                displayName = displayName -- Храним чистое имя в CP1251
            })
        end
    end
    
    -- Сортировка по алфавиту (CP1251)
    table.sort(shopFilteredItems, function(a, b)
        return a.displayName < b.displayName
    end)
end

function refreshShopTable()
    if not shopRefreshTable then return end
    
    shopRefreshTable = false
    shopFilteredItems = {}
    
    local request = ffi.string(shopFindBuffer)
    local sCP1251 = ""
    pcall(function() sCP1251 = u8:decode(request) end)
    local requestLower = string.lower(sCP1251)
    
    for itemName, itemData in pairs(shopItems) do
        local displayName = itemName
        displayName = displayName:gsub("^Аксессуар ", ""):gsub("^Предмет ", ""):gsub("^Оружие ", ""):gsub("^Одежда ", ""):gsub("^Объект ", "")
        
        if requestLower == "" or string.lower(displayName):find(requestLower, 1, true) then
            table.insert(shopFilteredItems, {
                name = itemName,
                id = itemData.id,
                displayName = displayName
            })
        end
    end
    
    table.sort(shopFilteredItems, function(a, b)
        return a.displayName < b.displayName
    end)
end

function addToWantedList(itemName, itemId)
    -- Сохраняем оригинальное имя (в CP1251) для ключа
    wantedItems[itemName] = {
        count = 1,
        price = 0,
        id = itemId
    }
    systemMessage(string.format("Товар '{3498db}%s{FFFFFF}' добавлен в список скупа.", u8:decode(itemName)))
end

function removeFromWantedList(itemName)
    local displayName = u8:decode(itemName)
    wantedItems[itemName] = nil
    systemMessage(string.format("Товар '{e74c3c}%s{FFFFFF}' удален из списка скупа.", displayName))
end

function saveShopConfig()
    local configName = ffi.string(shopConfigName)
    if configName == "" then
        configName = "default"
    end
    
    local configFile = configDir .. "shop_" .. configName .. ".json"
    local configData = {
        items = wantedItems,
        date = os.time(),
        name = configName
    }
    
    local f = io.open(configFile, "w")
    if f then
        f:write(json.encode(to_utf8_mode(configData)))
        f:close()
        systemMessage(string.format("Конфигурация сохранена: {2ecc71}%s.json", configName))
    else
        systemMessage("{e74c3c}Ошибка сохранения конфигурации!")
    end
end

function loadShopConfig(configName)
    local configFile = configDir .. "shop_" .. configName .. ".json"
    if doesFileExist(configFile) then
        local f = io.open(configFile, "r")
        if f then
            local raw = f:read("*a")
            f:close()
            if raw then
                local status, res = pcall(json.decode, raw)
                if status and res then
                    wantedItems = from_utf8(res.items) or {}
                    systemMessage(string.format("Загружена конфигурация: {2ecc71}%s", configName))
                    return true
                end
            end
        end
    end
    return false
end

function getShopConfigs()
    local configs = {}
    for file in lfs.dir(configDir) do
        if file:match("^shop_.+%.json$") then
            local configName = file:match("^shop_(.+)%.json$")
            table.insert(configs, configName)
        end
    end
    return configs
end

-- [[ Helpers ]]
function from_utf8(data)
    if type(data) == "string" then return u8:decode(data) end
    if type(data) == "table" then
        local newT = {}
        for k, v in pairs(data) do newT[from_utf8(k)] = from_utf8(v) end
        return newT
    end
    return data
end

function to_utf8_mode(data)
    if type(data) == "string" then 
        return u8(data) 
    end
    if type(data) == "table" then
        local newT = {}
        for k, v in pairs(data) do 
            -- Конвертируем ключи и значения
            -- Если ключ - строка, конвертируем. Если число - оставляем.
            local newKey = (type(k) == "string") and u8(k) or k
            
            -- Рекурсивный вызов для значений
            newT[newKey] = to_utf8_mode(v)
        end
        return newT
    end
    return data
end

function systemMessage(text)
    sampAddChatMessage("{3498db}[RODINAMARKET] {FFFFFF}" .. text, -1)
end

function stripColor(text)
    if not text then return "" end
    text = text:gsub('{[&%x]+}', '')
    text = text:gsub('%[[%x]+%]', '')
    return text
end

-- Функция для обрезки пробелов (аналог trim())
function trimString(str)
    if type(str) ~= "string" then return str end
    return str:match("^%s*(.-)%s*$") or str
end

function formatNumber(number)
    if not number then return "0" end
    local i, j, minus, int, fraction = tostring(number):find('([-]?)(%d+)([.]?%d*)')
    if not int then return tostring(number) end
    int = int:reverse():gsub("(%d%d%d)", "%1 ")
    return minus .. int:reverse():gsub("^%s", "") .. fraction
end

function comma_value(n)
    local left, num, right = string.match(tostring(n), '^([^%d]*%d)(%d*)(.-)$')
    if num == nil then return tostring(n) end
    return left..(num:reverse():gsub('(%d%d%d)','%1.'):reverse())..right
end

function os.time_formatted(timestamp)
    return os.date("%d.%m %H:%M", timestamp)
end

function string_contains_ignore_case(str, substr)
    if not str or not substr then return false end
    return string.lower(str):find(string.lower(substr), 1, true) ~= nil
end

function getListboxItemByText(text, plain)
    if not sampIsDialogActive() then return -1 end
    plain = not (plain == false)
    for i = 0, sampGetListboxItemsCount() - 1 do
        if sampGetListboxItemText(i):find(text, 1, plain) then
            return i
        end
    end
    return -1
end

function math_round(num, idp)
    local mult = 10^(idp or 0)
    return math.floor(num * mult + 0.5) / mult
end

function updateFilteredList()
    local currentSearch = ffi.string(SearchBuffer)
    local sCP1251 = ""
    pcall(function() sCP1251 = u8:decode(currentSearch) end)
    local lowerS = string.lower(sCP1251)
    
    -- Всегда обновляем список при изменении поиска или смене вкладки
    LastSearchText = lowerS
    FilteredKeys = {}
    
    -- Если поиск пуст и это вкладка Продажа (2) - показываем все товары
    if (currentTab == 2 and lowerS == "") or settings.showAllItems then
        for k in pairs(itemsData) do
            FilteredKeys[#FilteredKeys + 1] = k
        end
        showSearchResults = true
    elseif lowerS ~= "" then
        -- Поиск с учетом регистра
        for k in pairs(itemsData) do
            if string_contains_ignore_case(k, lowerS) then
                FilteredKeys[#FilteredKeys + 1] = k
                showSearchResults = true
            end
        end
    else
        showSearchResults = false
    end
    
    if #FilteredKeys > 0 then
        table.sort(FilteredKeys)
    end
    
    TotalItemsCount = getTableSize(itemsData)
end

function loadMarketLogs()
    if doesFileExist(logsFile) then
        local f = io.open(logsFile, "r")
        if f then
            local raw = f:read("*a")
            f:close()
            if raw then
                local status, res = pcall(json.decode, raw)
                if status and res then
                    -- Конвертируем ключи и строковые значения из UTF8 (json) в CP1251 (скрипт)
                    marketLogs = from_utf8(res)
                end
            end
        end
    end
    calculateLogStats()
end

function saveMarketLogs()
    local f = io.open(logsFile, "w")
    if f then
        -- Конвертируем в UTF8 перед сохранением
        f:write(json.encode(to_utf8_mode(marketLogs)))
        f:close()
    end
end

function addLogEntry(actionType, nick, item, count, price)
    local date = os.date("%d.%m.%Y")
    local time = os.date("%H:%M:%S")
    local unix = os.time()
    
    if not marketLogs[date] then marketLogs[date] = {} end
    
    table.insert(marketLogs[date], {
        time = time,
        unix = unix,
        type = actionType, -- "sell" или "buy"
        nick = nick,
        item = item,
        count = tonumber(count),
        price = tonumber(price)
    })
    
    saveMarketLogs()
    if date == selectedLogDate then calculateLogStats() end
end

function calculateLogStats()
    logStats = { earned = 0, spent = 0, profit = 0, items_sold = 0, items_bought = 0 }
    
    local logs = marketLogs[selectedLogDate]
    if not logs then return end
    
    for _, entry in ipairs(logs) do
        if entry.type == "sell" then
            logStats.earned = logStats.earned + entry.price
            logStats.items_sold = logStats.items_sold + entry.count
        elseif entry.type == "buy" then
            logStats.spent = logStats.spent + entry.price
            logStats.items_bought = logStats.items_bought + entry.count
        end
    end
    logStats.profit = logStats.earned - logStats.spent
end

-- Вспомогательная для очистки цены от точек (623.784 -> 623784)
function parsePrice(str)
    if not str then return 0 end
    local cleaned = (str:gsub("%.", ""))
    return tonumber(cleaned) or 0
end

-- [[ File System ]]
function getBucketName(itemName)
    local byte = string.byte(itemName, 1)
    if not byte then return "Misc.json" end
    if (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) then return itemName:sub(1,1):upper() .. ".json" end
    if byte >= 48 and byte <= 57 then return "Numbers.json" end
    if byte >= 192 then return "Cyrillic.json" end
    return "Misc.json"
end

function loadAllPrices()
    if not doesDirectoryExist(configDir) then createDirectory(configDir) end
    
    local settingsFile = configDir .. "settings.json"
    if doesFileExist(settingsFile) then
        local f = io.open(settingsFile, "r")
        if f then
            local raw = f:read("*a")
            f:close()
            if raw then
                local status, res = pcall(json.decode, raw)
                if status and res then
                    settings = from_utf8(res)
                end
            end
        end
    end
    
    itemsData = {}
    for file in lfs.dir(configDir) do
        if file:match("%.json$") and file ~= "settings.json" then
            local f = io.open(configDir .. file, "r")
            if f then
                local raw = f:read("*a")
                f:close()
                if raw then
                    local status, res = pcall(json.decode, raw)
                    if status and res then
                        local decoded = from_utf8(res)
                        for k, v in pairs(decoded) do 
                            itemsData[k] = v 
                        end
                    end
                end
            end
        end
    end
    updateFilteredList()
end

function saveItemBucket(itemName)
    local bucketName = getBucketName(itemName)
    local bucketData = {}
    for name, history in pairs(itemsData) do
        if getBucketName(name) == bucketName then bucketData[name] = history end
    end
    local f = io.open(configDir .. bucketName, "w")
    if f then
        f:write(json.encode(to_utf8_mode(bucketData))) 
        f:close()
    end
end

function saveAllBuckets()
    -- Принудительная очистка мусора перед тяжелой операцией
    collectgarbage()

    -- 1. Группируем данные в локальную таблицу (это безопасно для памяти)
    local buckets = {}
    for name, history in pairs(itemsData) do
        local bName = getBucketName(name)
        if not buckets[bName] then 
            buckets[bName] = {} 
        end
        buckets[bName][name] = history
    end

    -- 2. Сохраняем каждый файл отдельно с паузой
    for bName, data in pairs(buckets) do
        local f = io.open(configDir .. bName, "w")
        if f then
            -- Оборачиваем конвертацию в pcall, чтобы поймать ошибки кодировки
            -- Если to_utf8_mode упадет, скрипт не крашнется, а просто напишет ошибку в консоль
            local status, result = pcall(to_utf8_mode, data)
            
            if status then
                f:write(json.encode(result))
            else
                print("[RODINAMARKET] Ошибка кодировки при сохранении: " .. tostring(bName))
            end
            f:close()
        end
        
        -- КРИТИЧНО ВАЖНО:
        -- Ждем 10мс после каждого файла. Это сбрасывает стек потока и дает игре обработать кадр.
        wait(10) 
    end
    
    -- Финальная очистка
    collectgarbage()
    systemMessage("База данных успешно сохранена.")
end

function saveSettings()
    local settingsFile = configDir .. "settings.json"
    local f = io.open(settingsFile, "w")
    if f then
        f:write(json.encode(to_utf8_mode(settings)))
        f:close()
    end
end

-- [[ Logic ]]
function getAveragePrice(history)
    if not history or #history == 0 then return 0 end
    local sum = 0
    for _, v in ipairs(history) do sum = sum + v.price end
    return math.floor(sum / #history)
end

function getMinMaxPrice(history)
    if not history or #history == 0 then return 0, 0 end
    local minP, maxP = history[1].price, history[1].price
    for _, v in ipairs(history) do
        if v.price < minP then minP = v.price end
        if v.price > maxP then maxP = v.price end
    end
    return minP, maxP
end

function addPriceEntry(name, price, sharp, rawDesc, batchMode)
    if price == 0 then return end
    
    local key = name
    if sharp and sharp > 0 then key = name .. " [+" .. sharp .. "]" end
    
    if not itemsData[key] then 
        itemsData[key] = {} 
    end
    local history = itemsData[key]
    
    -- Если последняя цена такая же, просто обновляем дату
    if #history > 0 and history[#history].price == price then
        history[#history].date = os.time()
        if rawDesc then history[#history].desc = rawDesc end
        
        -- Если это не массовое сканирование, сохраняем сразу
        if not batchMode then
            saveItemBucket(key)
            updateFilteredList()
        end
        return
    end

    -- Добавляем новую запись
    table.insert(history, { price = price, sharp = sharp or 0, date = os.time(), desc = rawDesc })
    if #history > 40 then table.remove(history, 1) end
    
    itemsData[key] = history
    
    -- Если это не массовое сканирование, сохраняем и уведомляем
    if not batchMode then
        saveItemBucket(key)
        updateFilteredList()
        
        local sText = (sharp and sharp > 0) and ("(+"..sharp..")") or ""
        systemMessage(string.format("Saved: {3498db}%s %s {FFFFFF}| Price: {2ecc71}$%s", name, sText, formatNumber(price)))
    end
end

function deletePriceEntry(key, index)
    if itemsData[key] and itemsData[key][index] then
        local entryPrice = itemsData[key][index].price
        table.remove(itemsData[key], index)
        if #itemsData[key] == 0 then
            deleteItem(key)
        else
            saveItemBucket(key)
            systemMessage(string.format("Удалена запись цены {e74c3c}$%s {FFFFFF} для {3498db}%s", formatNumber(entryPrice), key))
        end
        SelectedItemKey = key 
        return true
    end
    return false
end

function deleteItem(key)
    if itemsData[key] then
        itemsData[key] = nil
        saveItemBucket(key)
        SelectedItemKey = nil
        updateFilteredList()
        systemMessage(string.format("Удален товар {e74c3c}%s{FFFFFF} из базы.", key))
        return true
    end
    return false
end

function startPickupScanning()
    if isPickupScanning then
        systemMessage("Сканирование уже запущено!")
        return
    end
    
    systemMessage("Сканирование запущено. Встаньте на пикап с информацией внутри ЦР.")
    isPickupScanning = true
    scanProgress = 0
    totalItemsScanned = 0
    currentScanPage = 1
    totalScanPages = 1
end

function finishPickupScanning()
    isPickupScanning = false
    scanProgress = 100
    
    settings.lastScanDate = os.date(u8"%d.%m.%Y")
    saveSettings()
    
    systemMessage(string.format("Сканирование завершено! Найдено {2ecc71}%s {FFFFFF}товаров.", totalItemsScanned))
    systemMessage("Сохранение базы данных... (Не закрывайте игру)")
    
    -- Запускаем процесс в отдельном потоке
    lua_thread.create(function()
        -- Небольшая пауза перед стартом тяжелой работы
        wait(100)
        
        -- Вызов безопасной функции сохранения
        saveAllBuckets()
        
        -- Обновление интерфейса
        updateFilteredList()
    end)
end

function addToSaleList(itemName, maxCount)
    if not selectedForSale[itemName] then
        selectedForSale[itemName] = {
            count = 1,
            price = 0,
            maxCount = playerInventoryItems[itemName] or 1
        }
    else
        -- Увеличиваем количество, но не более чем есть в инвентаре
        local current = selectedForSale[itemName]
        if current.count < current.maxCount then
            current.count = current.count + 1
        end
    end
end

-- Функция для удаления товара из списка продажи
function removeFromSaleList(itemName)
    selectedForSale[itemName] = nil
end

-- Функция для сохранения конфигурации продажи
function saveSaleConfig()
    local configName = "sale_default"
    local configFile = configDir .. "sale_" .. configName .. ".json"
    local configData = {
        items = selectedForSale,
        date = os.time(),
        name = configName
    }
    
    local f = io.open(configFile, "w")
    if f then
        f:write(json.encode(to_utf8_mode(configData)))
        f:close()
        systemMessage(string.format("Конфигурация продажи сохранена: {2ecc71}%s.json", configName))
    else
        systemMessage("{e74c3c}Ошибка сохранения конфигурации!")
    end
end

-- Функция для загрузки конфигурации продажи
function loadSaleConfig(configName)
    local configFile = configDir .. "sale_" .. configName .. ".json"
    if doesFileExist(configFile) then
        local f = io.open(configFile, "r")
        if f then
            local raw = f:read("*a")
            f:close()
            if raw then
                local status, res = pcall(json.decode, raw)
                if status and res then
                    selectedForSale = from_utf8(res.items) or {}
                    systemMessage(string.format("Загружена конфигурация продажи: {2ecc71}%s", configName))
                    return true
                end
            end
        end
    end
    return false
end

-- Функция для отображения вкладки "Продажа" (замените существующую renderItemsList)
function renderSalePage()
    local contentWidth = imgui.GetContentRegionAvail().x
    local contentHeight = imgui.GetContentRegionAvail().y
    local draw_list = imgui.GetWindowDrawList()
    
    -------------------------------------------------------------
    --  TOOLBAR
    -------------------------------------------------------------
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.04, 0.04, 0.06, 0.5))
    imgui.BeginChild("SaleToolbar", imgui.ImVec2(contentWidth, 55), false)
        imgui.SetCursorPos(imgui.ImVec2(15, 12))
        
        -- SCAN BUTTON
        if inventoryScanning then
            imgui.PushStyleColor(imgui.Col.Button, theme.red)
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1, 1, 1, 1))
            if imgui.Button(u8(string.format("СТОП (%.0f%%)", inventoryScanProgress)), imgui.ImVec2(160, 28)) then
                inventoryScanning = false
                inventoryWaitingForModal = false
            end
            imgui.PopStyleColor(2)
        else
            if imgui.Button(u8"Сканировать инвентарь", imgui.ImVec2(160, 28)) then
                startInventoryScanning()
            end
        end
        
        imgui.SameLine()
        
        if lastInventoryScanTime > 0 then
            imgui.SetCursorPosY(18)
            imgui.TextColored(theme.text_dim, os.date("%H:%M", lastInventoryScanTime))
        end

        -- Save/Load Config buttons for Sale (Right side)
        imgui.SameLine(contentWidth - 180)
        if imgui.Button(u8"Сохранить сет", imgui.ImVec2(100, 28)) then
            saveSaleConfig()
        end

    imgui.EndChild()
    imgui.PopStyleColor()
    
    imgui.PushStyleColor(imgui.Col.Separator, theme.border)
    imgui.Separator()
    imgui.PopStyleColor()

    -------------------------------------------------------------
    --  COLUMNS: INVENTORY (Left) vs SALE LIST (Right)
    -------------------------------------------------------------
    imgui.Columns(2, "SaleCols", true)
    
    -- [[ LEFT: PLAYER INVENTORY ]]
    imgui.BeginChild("InvList", imgui.ImVec2(0, contentHeight - 80), true)
        imgui.TextColored(theme.accent, u8"Ваш Инвентарь")
        imgui.Separator()
        
        if getTableSize(playerInventoryItems) == 0 then
             imgui.SetCursorPos(imgui.ImVec2(20, 50))
             imgui.TextColored(theme.text_dim, u8"Список пуст. Нажмите 'Сканировать'")
        else
            for name, count in pairs(playerInventoryItems) do
                local p = imgui.GetCursorScreenPos()
                
                -- Row Background
                draw_list:AddRectFilled(p, imgui.ImVec2(p.x + imgui.GetContentRegionAvail().x, p.y + 35), imgui.GetColorU32Vec4(imgui.ImVec4(0.05, 0.05, 0.07, 0.5)), 4.0)
                
                -- Name
                imgui.SetCursorPos(imgui.ImVec2(10, imgui.GetCursorPosY() + 8))
                imgui.Text(u8(name))
                
                -- Count found
                imgui.SameLine(imgui.GetContentRegionAvail().x - 70)
                imgui.TextColored(theme.text_dim, "x"..count)
                
                -- Add Button
                imgui.SameLine(imgui.GetContentRegionAvail().x - 30)
                imgui.SetCursorPosY(imgui.GetCursorPosY() - 3)
                if imgui.Button("+".."##"..name, imgui.ImVec2(25, 25)) then
                    addToSaleList(name, count) -- Uses your existing logic
                end
                
                imgui.SetCursorPosY(imgui.GetCursorPosY() + 10)
            end
        end
    imgui.EndChild()
    
    imgui.NextColumn()
    
    -- [[ RIGHT: SELLING LIST ]]
    imgui.BeginChild("SellingList", imgui.ImVec2(0, contentHeight - 80), true)
        imgui.TextColored(theme.accent, u8"Выставить на продажу")
        imgui.Separator()
        
        -- Reuse the logic you had for the Sale List rendering here
        -- Iterate `selectedForSale` table
        -- ... (Paste your existing right-column logic here) ...
        
        -- Example of existing logic integration:
        local saleArray = {}
        for name, data in pairs(selectedForSale) do table.insert(saleArray, {name=name, data=data}) end
        table.sort(saleArray, function(a,b) return a.name < b.name end)
        
        for idx, item in ipairs(saleArray) do
             -- Render your sale item cards (inputs for Price/Count)
             -- ...
             local name = item.name
             local data = item.data
             
             -- Simple render example:
             imgui.Text(u8(name))
             imgui.SameLine()
             if imgui.Button("X##"..idx) then removeFromSaleList(name) end
             -- Add inputs for data.price and data.count
        end

    imgui.EndChild()
    
    imgui.Columns(1)
end

function printDebug(msg)
    local timestamp = os.date("%H:%M:%S")
    print(string.format("[%s] [DEBUG] %s", timestamp, msg))
end

-- [[ ОБРАБОТКА ДИАЛОГА ]]
function ev.onShowDialog(id, style, title, button1, button2, text)
    if id == 9 and title and title:find("Управление лавкой") then
        if buyingFinished then
            buyingFinished = false
            systemMessage("Выставление товаров завершено!")
            sampSendDialogResponse(id, 0, -1, "")
            return false
        end

        if isShopScanning or isAutoBuying then
            sampSendDialogResponse(id, 1, 1, "")
            return
        end
    end

    if id == 10 and title and (title:find("Скупка") or title:find("Выкуп")) then
        if isAutoBuying then
            local currentItem = buyingQueue[currentBuyingIndex]

            if currentItem then
                sampSendDialogResponse(id, 1, 0, "")
            else
                isAutoBuying = false
                buyingFinished = true
                sampSendDialogResponse(id, 0, -1, "")
            end
            
            local statusInfo = (buyingQueue[currentBuyingIndex]) 
                and string.format("Выставляем: %s (%d/%d)", buyingQueue[currentBuyingIndex].name, currentBuyingIndex, #buyingQueue)
                or "Завершение..."
            return {id, style, "{3498db}[AUTO] " .. statusInfo, button1, button2, text}
        end

        if isShopScanning then
            local cleanTitle = stripColor(title)
            local currentPageStr, totalPagesStr = cleanTitle:match("(%d+)%s*/%s*(%d+)")
            local currentPage = tonumber(currentPageStr)
            local totalPages = tonumber(totalPagesStr)
            
            if currentPage and totalPages then
                currentShopScanPage = currentPage
                totalShopScanPages = totalPages
                shopScanProgress = (currentPage / totalPages) * 100
            end

            local nextPageListIndex = -1
            local lineCounter = 0

            for line in text:gmatch('([^\n\r]+)') do
				if not line:find("Средняя цена:") and not line:find("Следующая страница") and not line:find("Предыдущая страница") then
					-- Старый паттерн: Имя (tab) Кол-во (tab) Средняя цена
					local rawName = line:match("(.+)\t%d+\t%d+")
					local priceStr = line:match(".+\t%d+\t(%d+)")
					
					if rawName and priceStr then
						-- Чистим имя от цветов
						local name = stripColor(rawName):gsub("^%s*(.-)%s*$", "%1")
						local price = tonumber(priceStr)
						
						if price and price > 0 then
							-- Добавляем в базу c флагом batchMode = true (последний аргумент)
							-- Это предотвратит лаги во время сканирования
							addPriceEntry(name, price, 0, nil, true)
							totalItemsScanned = totalItemsScanned + 1
						end
					end
				end
			end
            
            if nextPageListIndex ~= -1 then
                sampSendDialogResponse(id, 1, nextPageListIndex, "")
                return {id, style, string.format("{3498db}[SCAN] {FFFFFF}Страница %d...", currentShopScanPage), button1, button2, text}
            else
                lua_thread.create(function()
                    wait(200)
                    finishShopScanning()
                    sampSendDialogResponse(id, 0, -1, "")
                end)
                return {id, style, title, button1, button2, text}
            end
        end
    end

    if id == 909 and isAutoBuying then
        local currentItem = buyingQueue[currentBuyingIndex]
        if currentItem then
            sampSendDialogResponse(id, 1, 0, currentItem.name)
            return {id, style, title, button1, button2, "Вводим: " .. currentItem.name}
        end
    end

    if id == 910 and isAutoBuying then
        local currentItem = buyingQueue[currentBuyingIndex]
        if currentItem then
            local targetName = currentItem.name
            local foundIndex = -1
            local lineCount = 0
            
            for line in text:gmatch('([^\n\r]+)') do
                local cleanLine = stripColor(line)
                local nameInDialog = cleanLine:match("^(.-)%s*%[") or cleanLine
                nameInDialog = nameInDialog:gsub("^%s*(.-)%s*$", "%1")
                
                if nameInDialog == targetName then
                    foundIndex = lineCount
                    break
                end
                
                local nameWithoutPrefix = nameInDialog:gsub("^Предмет ", "")
                if nameWithoutPrefix == targetName then
                    foundIndex = lineCount
                    break
                end
                
                lineCount = lineCount + 1
            end

            if foundIndex == -1 then
                lineCount = 0
                for line in text:gmatch('([^\n\r]+)') do
                    local cleanLine = stripColor(line)
                    if cleanLine:find(targetName, 1, true) then
                        local itemNameFromLine = cleanLine:match("^(.-)%s*%[") or cleanLine
                        itemNameFromLine = itemNameFromLine:gsub("^%s*(.-)%s*$", "%1")
                        
                        if itemNameFromLine == targetName or 
                           itemNameFromLine:gsub("^Предмет ", "") == targetName then
                            foundIndex = lineCount
                            break
                        end
                    end
                    lineCount = lineCount + 1
                end
            end

            if foundIndex == -1 and currentItem.id then
                lineCount = 0
                for line in text:gmatch('([^\n\r]+)') do
                    local idInLine = line:match("%[(%d+)%]$")
                    if idInLine and tonumber(idInLine) == currentItem.id then
                        foundIndex = lineCount
                        break
                    end
                    lineCount = lineCount + 1
                end
            end

            if foundIndex == -1 then
                systemMessage(string.format("Товар '{e74c3c}%s{FFFFFF}' не найден в списке. Пропускаем.", targetName))
                currentBuyingIndex = currentBuyingIndex + 1
                
                if currentBuyingIndex > #buyingQueue then
                    buyingFinished = true
                    isAutoBuying = false
                    systemMessage("Скуп завершен!")
                end
                sampSendDialogResponse(id, 0, -1, "")
                return {id, style, string.format("{3498db}[AUTO] {e74c3c}Товар не найден: %s", targetName), button1, button2, text}
            end
            sampSendDialogResponse(id, 1, foundIndex, "")
            return {id, style, string.format("{3498db}[AUTO] {FFFFFF}Выбираем: %s", targetName), button1, button2, text}
        end
    end

    if id == 11 and isAutoBuying then
        local currentItem = buyingQueue[currentBuyingIndex]
        if currentItem then
            local inputStr = string.format("%d,%d", currentItem.count, currentItem.price)
            
            sampSendDialogResponse(id, 1, 0, inputStr)
            currentBuyingIndex = currentBuyingIndex + 1
            return {id, style, title, button1, button2, "Вводим: " .. inputStr}
        end
    end
    
    if style == 5 and title and title:find("Ценовая статистика за сутки:") then
        if not isPickupScanning then
            systemMessage("Для сканирования запустите его через меню или /scanpickup")
            return
        end
        
        local currentPageStr, totalPagesStr = title:match("%{......%}(%d+) /"), title:match("/ (%d+)")
        local currentPage = tonumber(currentPageStr)
        local totalPages = tonumber(totalPagesStr)

        if currentPage and totalPages then
            scanProgress = (currentPage / totalPages) * 100
            currentScanPage = currentPage
            totalScanPages = totalPages
        end
        
        -- ЛОГИКА ИЗ СТАРОГО СКРИПТА (Парсинг через табуляцию)
        for line in text:gmatch('([^\n\r]+)') do
            if not line:find("Средняя цена:") and not line:find("Следующая страница") and not line:find("Предыдущая страница") then
                -- Старый паттерн: Имя (tab) Кол-во (tab) Средняя цена
                local rawName = line:match("(.+)\t%d+\t%d+")
                local priceStr = line:match(".+\t%d+\t(%d+)")
                
                if rawName and priceStr then
                    -- Чистим имя от цветов
                    local name = stripColor(rawName):gsub("^%s*(.-)%s*$", "%1")
                    local price = tonumber(priceStr)
                    
                    if price and price > 0 then
                        -- Добавляем в базу
                        addPriceEntry(name, price, 0, nil)
                        totalItemsScanned = totalItemsScanned + 1
                    end
                end
            end
        end
        -- КОНЕЦ ЛОГИКИ ИЗ СТАРОГО СКРИПТА

        if text:find("Следующая страница") then
            lua_thread.create(function()
                wait(20) -- Уменьшил задержку для скорости как в старом
                local listIndex = getListboxItemByText("Следующая страница")
                if listIndex ~= -1 then
                    sampSetCurrentDialogListItem(listIndex)
                    sampSendDialogResponse(id, 1, listIndex, "")
                end
            end)
            return {id, style, string.format("{ffffff}Просканировано: {3498db}%.1f%%", scanProgress), button1, button2, text}
        elseif text:find("Предыдущая страница") or scanProgress >= 99 then
            lua_thread.create(function()
                wait(100)
                finishPickupScanning()
                sampSendDialogResponse(id, 0, -1, "")
            end)
            return {id, style, string.format("{ffffff}Завершено: {2ecc71}100%%", scanProgress), button1, button2, text}
        end
        
        return {id, style, string.format("{ffffff}Просканировано: {3498db}%.1f%%", scanProgress), button1, button2, text}
    end
    
    if id == 9 and title and title:find("Управление лавкой") then
        if isShopScanning then
            sampSendDialogResponse(id, 1, 1, "")
            return
        end
    end
    
    if id == 10 and title and (title:find("Скупка") or title:find("Выкуп")) then
        if not isShopScanning then
            return
        end
        
        local cleanTitle = stripColor(title)
        local currentPageStr, totalPagesStr = cleanTitle:match("(%d+)%s*/%s*(%d+)")
        local currentPage = tonumber(currentPageStr)
        local totalPages = tonumber(totalPagesStr)
        
        if currentPage and totalPages then
            currentShopScanPage = currentPage
            totalShopScanPages = totalPages
            shopScanProgress = (currentPage / totalPages) * 100
        end

        local nextPageListIndex = -1
        local lineCounter = 0

        for line in text:gmatch('([^\n\r]+)') do
            if line:find("Следующая страница") then
                nextPageListIndex = lineCounter
            end

            if not line:find("Поиск предмета") and not line:find("Поиск по категориям") 
               and not line:find("Следующая страница") and not line:find("Предыдущая страница") then
                
                local itemName, itemId = line:match("(.+)%s+%[(%d+)%]$")
                if not itemName then
                    itemName, itemId = line:match("(.+)%[(%d+)%]$")
                end
                
                if itemName and itemId then
                    itemName = stripColor(itemName):gsub("^%s*(.-)%s*$", "%1")
                    itemId = tonumber(itemId)
                    
                    if itemName and itemId and not shopItems[itemName] then
                        shopItems[itemName] = {
                            id = itemId,
                            page = currentPage or 1
                        }
                        totalShopItemsScanned = totalShopItemsScanned + 1
                    end
                end
            end
            
            lineCounter = lineCounter + 1
        end
        
        if nextPageListIndex ~= -1 then
            lua_thread.create(function()
                wait(50)
                sampSendDialogResponse(id, 1, nextPageListIndex, "")
            end)
            
            local newTitle = string.format("{3498db}[SCAN] {FFFFFF}Страница %d из %d...", currentShopScanPage, totalShopScanPages)
            return {id, style, newTitle, button1, button2, text}
        else
            lua_thread.create(function()
                wait(100)
                finishShopScanning()
                sampSendDialogResponse(id, 0, -1, "")
            end)
            return {id, style, title, button1, button2, text}
        end
    end
    
    if id == 240 or (text and (text:find("за один товар") or text:find("Вы действительно хотите"))) then
        local cleanText = stripColor(text)
        local itemName = nil
        
        -- Паттерн 1: "купить товар (Название) у игрока"
        itemName = cleanText:match("товар%s+%((.+)%)%s+у")
        
        -- Паттерн 2: "товар (Название) через"
        if not itemName then
            itemName = cleanText:match("товар%s+%((.+)%)%s+через")
        end
        
        -- Паттерн 3: "товар (Название):"
        if not itemName then
            itemName = cleanText:match("товар%s+%((.+)%):")
        end

        -- Паттерн 4: Универсальный для скобок, если другие не сработали
        if not itemName then
             itemName = cleanText:match("%((.+)%)")
        end

        if itemName then
            -- Убираем лишние пробелы по краям
            itemName = itemName:gsub("^%s*(.-)%s*$", "%1")
            
            -- Игнорируем, если выцепили число или цену вместо названия
            if not tonumber(itemName) then
                lua_thread.create(function()
                    wait(50)
                    checkPriceForAdvice(itemName)
                end)
            end
        end
        -- Не делаем return, чтобы диалог открылся нормально
    end
end

function getTableSize(t)
    if t == nil or type(t) ~= 'table' then return 0 end -- Добавлена проверка на nil
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count
end

function checkPriceForAdvice(itemName)
    if not itemName or type(itemName) ~= "string" then 
        systemMessage("Некорректное название предмета")
        return 
    end
    
    -- Убедимся, что itemName - строка
    itemName = tostring(itemName)
    local cleanName = itemName:gsub("^Предмет ", ""):gsub("^предмет ", ""):gsub("^Аксессуар ", ""):gsub("%s+$", "")
    
    local foundKey = nil
    local foundHistory = nil
    
    -- Проверка прямого совпадения с защитой типа
    if itemsData[itemName] and type(itemsData[itemName]) == 'table' and #itemsData[itemName] > 0 then
        foundKey = itemName
        foundHistory = itemsData[itemName]
    elseif itemsData[cleanName] and type(itemsData[cleanName]) == 'table' and #itemsData[cleanName] > 0 then
        foundKey = cleanName
        foundHistory = itemsData[cleanName]
    else
        -- Нечеткий поиск
        local lowerItemName = string.lower(itemName)
        local lowerCleanName = string.lower(cleanName)
        local candidates = {}
        
        for key, history in pairs(itemsData) do
            -- Пропускаем битые данные (числа вместо таблиц)
            if history and type(history) == 'table' and #history > 0 then
                local lowerKey = string.lower(key)
                local matchScore = 0
                
                if lowerKey == lowerItemName or lowerKey == lowerCleanName then
                    matchScore = 100
                elseif lowerKey:find(lowerItemName, 1, true) or lowerKey:find(lowerCleanName, 1, true) then
                    matchScore = 50
                elseif lowerItemName:find(lowerKey, 1, true) or lowerCleanName:find(lowerKey, 1, true) then
                    matchScore = 30
                end
                
                if matchScore > 0 then
                    table.insert(candidates, {
                        key = key,
                        history = history,
                        score = matchScore,
                        length = #key
                    })
                end
            end
        end
        
        if #candidates > 0 then
            table.sort(candidates, function(a, b)
                if a.score ~= b.score then return a.score > b.score end
                return a.length < b.length
            end)
            foundKey = candidates[1].key
            foundHistory = candidates[1].history
            systemMessage(string.format("Найдено совпадение: '{3498db}%s{FFFFFF}' -> '{3498db}%s{FFFFFF}'", itemName, foundKey))
        end
    end

    if not foundHistory or #foundHistory == 0 then
        systemMessage(string.format("Для товара '{e74c3c}%s{FFFFFF}' нет данных о ценах.", itemName))
        return
    end

    local avg = getAveragePrice(foundHistory)
    local lastEntry = foundHistory[#foundHistory]
    
    if not lastEntry then return end
    
    local last = lastEntry.price
    local color = (last >= avg) and "{2ecc71}" or "{e74c3c}"
    
    systemMessage(string.format("Анализ: {3498db}%s", foundKey))
    sampAddChatMessage(string.format("      {FFFFFF}Средняя: {3498db}$%s {FFFFFF}| Последняя: %s$%s", formatNumber(avg), color, formatNumber(last)), -1)
end

-- [[ UI STYLES ]]

local currentTab = 1
local tabs = {
    {name = "Основное"},
    {name = "Продажа"},
    {name = "Скупка"}, 
    {name = "Настройки"},
    {name = "Логи"},
    {name = "Функции"},
    {name = "Маркет-Плейс"},
    {name = "Дополнения"},
    {name = "Рейтинг"},
    {name = "Меню"},
    {name = "Обзоры"}
}

local priceCache = {}

-- Инициализация шрифтов без иконок
imgui.OnInitialize(function()
    local io = imgui.GetIO()
    io.IniFilename = nil

    local fonts_dir = getFolderPath(0x14)
    local glyph = io.Fonts:GetGlyphRangesCyrillic()

    -- Основные шрифты
    fonts.main = io.Fonts:AddFontFromFileTTF(fonts_dir .. '\\arial.ttf', 14, nil, glyph)
    fonts.bold = io.Fonts:AddFontFromFileTTF(fonts_dir .. '\\arialbd.ttf', 14, nil, glyph)
    fonts.big = io.Fonts:AddFontFromFileTTF(fonts_dir .. '\\arial.ttf', 18, nil, glyph)

    io.Fonts:Build()

    -- Стилизация
    local style = imgui.GetStyle()
    
    style.WindowRounding    = 0.0
    style.ChildRounding     = 0.0
    style.FrameRounding     = 0.0
    style.PopupRounding     = 0.0
    style.ScrollbarSize     = 3.0
    style.ScrollbarRounding = 0.0
    
    style.WindowBorderSize  = 0.0
    style.ChildBorderSize   = 0.0
    style.PopupBorderSize   = 1.0
    style.FrameBorderSize   = 0.0 
    
    style.WindowPadding     = imgui.ImVec2(0, 0)
    style.ItemSpacing       = imgui.ImVec2(8, 8)
    style.FramePadding      = imgui.ImVec2(10, 8)
    
    local colors = style.Colors
    colors[imgui.Col.WindowBg]           = theme.bg
    colors[imgui.Col.ChildBg]            = imgui.ImVec4(0, 0, 0, 0)
    colors[imgui.Col.Border]             = theme.border
    colors[imgui.Col.Text]               = theme.text
    colors[imgui.Col.TextDisabled]       = theme.text_dim
    
    colors[imgui.Col.FrameBg]            = theme.input_bg
    colors[imgui.Col.FrameBgHovered]     = imgui.ImVec4(0.15, 0.15, 0.20, 1.0)
    colors[imgui.Col.FrameBgActive]      = imgui.ImVec4(0.20, 0.20, 0.25, 1.0)
    
    colors[imgui.Col.Button]             = imgui.ImVec4(0,0,0,0)
    colors[imgui.Col.ButtonHovered]      = imgui.ImVec4(1,1,1,0.05)
    colors[imgui.Col.ButtonActive]       = imgui.ImVec4(1,1,1,0.1)
    
    colors[imgui.Col.ScrollbarBg]        = imgui.ImVec4(0,0,0,0)
    colors[imgui.Col.ScrollbarGrab]      = theme.accent
    colors[imgui.Col.ScrollbarGrabHovered] = theme.accent_hov
    colors[imgui.Col.ScrollbarGrabActive] = theme.accent_hov
    
    colors[imgui.Col.Separator]          = theme.border
    colors[imgui.Col.Header]             = theme.accent_dim
    colors[imgui.Col.HeaderHovered]      = theme.accent
    colors[imgui.Col.HeaderActive]       = theme.accent
    colors[imgui.Col.SeparatorHovered]   = imgui.ImVec4(0.12, 0.12, 0.12, 1)
    colors[imgui.Col.SeparatorActive]    = imgui.ImVec4(0.12, 0.12, 0.12, 1)
    colors[imgui.Col.ResizeGrip]         = imgui.ImVec4(1, 1, 1, 0.25)
    colors[imgui.Col.ResizeGripHovered]  = imgui.ImVec4(1, 1, 1, 0.67)
    colors[imgui.Col.ResizeGripActive]   = imgui.ImVec4(1, 1, 1, 0.95)
    colors[imgui.Col.Tab]                = imgui.ImVec4(0.12, 0.12, 0.12, 1)
    colors[imgui.Col.TabHovered]         = imgui.ImVec4(0.28, 0.28, 0.28, 1)
    colors[imgui.Col.TabActive]          = imgui.ImVec4(0.3, 0.3, 0.3, 1)
    colors[imgui.Col.TabUnfocused]       = imgui.ImVec4(0.07, 0.1, 0.15, 0.97)
    colors[imgui.Col.TabUnfocusedActive] = imgui.ImVec4(0.14, 0.26, 0.42, 1)
    colors[imgui.Col.PlotLines]          = imgui.ImVec4(0.61, 0.61, 0.61, 1)
    colors[imgui.Col.PlotLinesHovered]   = imgui.ImVec4(1, 0.43, 0.35, 1)
    colors[imgui.Col.PlotHistogram]      = imgui.ImVec4(0.9, 0.7, 0, 1)
    colors[imgui.Col.PlotHistogramHovered] = imgui.ImVec4(1, 0.6, 0, 1)
    colors[imgui.Col.TextSelectedBg]     = imgui.ImVec4(1, 0, 0, 0.35)
    colors[imgui.Col.DragDropTarget]     = imgui.ImVec4(1, 1, 0, 0.9)
    colors[imgui.Col.NavHighlight]       = imgui.ImVec4(0.26, 0.59, 0.98, 1)
    colors[imgui.Col.NavWindowingHighlight] = imgui.ImVec4(1, 1, 1, 0.7)
    colors[imgui.Col.NavWindowingDimBg]  = imgui.ImVec4(0.8, 0.8, 0.8, 0.2)
    colors[imgui.Col.ModalWindowDimBg]   = imgui.ImVec4(0, 0, 0, 0.7)
end)

function renderSampText(text)
    if not text then return end
    local u8text = u8(text) 
    local pattern = "([{%[]%x%x%x%x%x%x[%]}]?)"
    
    for line in u8text:gmatch("[^\r\n]+") do
        local last_pos = 1
        local color_pushes = 0
        local function iter_func()
            local s, e = line:find(pattern, last_pos)
            if s then
                local tag = line:sub(s, e)
                local hex = tag:match("%x+")
                last_pos = e + 1
                color_pushes = color_pushes + 1
                return s, e, hex
            end
        end
        
        local text_parts = {}
        local color_parts = {}
        local s, e, hex_color = iter_func()
        while s do
            table.insert(text_parts, line:sub(last_pos, s - 1))
            table.insert(color_parts, hex_color)
            s, e, hex_color = iter_func()
        end
        table.insert(text_parts, line:sub(last_pos))
        
        for i, part in ipairs(text_parts) do
            if #part > 0 then 
                if color_parts[i-1] then
                    local hex = color_parts[i-1]
                    local r, g, b = tonumber(hex:sub(1,2),16)/255, tonumber(hex:sub(3,4),16)/255, tonumber(hex:sub(5,6),16)/255
                    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(r, g, b, 1))
                end
                
                imgui.TextUnformatted(part)
                if i < #text_parts then imgui.SameLine() end
                
                if color_parts[i-1] then
                    imgui.PopStyleColor(1)
                end
            end
        end
    end
end

function getFormattedPrice(price)
    if not price then return "0" end
    local cached = priceCache[price]
    if cached then return cached end
    
    local i, j, minus, int, fraction = tostring(price):find('([-]?)(%d+)([.]?%d*)')
    if not int then 
        priceCache[price] = tostring(price)
        return tostring(price)
    end
    int = int:reverse():gsub("(%d%d%d)", "%1 ")
    local result = minus .. int:reverse():gsub("^%s", "") .. fraction
    priceCache[price] = result
    return result
end

function drawScanProgressBar()
    if not isPickupScanning then return end
    
    local dl = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetWindowWidth() - 60
    local h = 20
    
    dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), imgui.GetColorU32Vec4(imgui.ImVec4(0.1, 0.1, 0.12, 1)), 4.0)
    
    if scanProgress > 0 then
        local progressW = w * (scanProgress / 100)
        dl:AddRectFilled(p, imgui.ImVec2(p.x + progressW, p.y + h), imgui.GetColorU32Vec4(theme.accent), 4.0)
    end
    
    imgui.SetCursorPos(imgui.ImVec2(imgui.GetCursorPosX() + w/2 - 50, imgui.GetCursorPosY() + 2))
    imgui.TextColored(theme.accent, string.format(u8"Сканирование: %.1f%%", scanProgress))
    
    imgui.SetCursorPosY(imgui.GetCursorPosY() + h + 10)
end

function renderHomePage()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    
    imgui.GetWindowDrawList():AddRectFilledMultiColor(
        p, 
        imgui.ImVec2(p.x + w, p.y + 120), 
        imgui.GetColorU32Vec4(imgui.ImVec4(theme.accent.x, theme.accent.y, theme.accent.z, 0.15)), 
        imgui.GetColorU32Vec4(imgui.ImVec4(theme.accent.x, theme.accent.y, theme.accent.z, 0.05)),
        imgui.GetColorU32Vec4(imgui.ImVec4(theme.accent.x, theme.accent.y, theme.accent.z, 0.05)),
        imgui.GetColorU32Vec4(imgui.ImVec4(theme.accent.x, theme.accent.y, theme.accent.z, 0.15))
    )
    imgui.GetWindowDrawList():AddRect(p, imgui.ImVec2(p.x + w, p.y + 120), imgui.GetColorU32Vec4(theme.accent), 8.0)
    
    imgui.SetCursorPos(imgui.ImVec2(imgui.GetCursorPosX() + 20, imgui.GetCursorPosY() + 20))
    imgui.PushFont(fonts.big)
    imgui.TextColored(theme.accent, u8"RODINA MARKET 2.0")
    imgui.PopFont()
    
    imgui.SetCursorPos(imgui.ImVec2(imgui.GetCursorPosX() + 20, imgui.GetCursorPosY() + 5))
    imgui.TextColored(theme.text, u8"Ваш лучший помощник в торговле на Центральном Рынке.")
    
    imgui.SetCursorPosY(imgui.GetCursorPosY() + 60)
    
    imgui.Columns(3, "HomeStats", false)
    
    imgui.Text(u8"Товаров: " .. TotalItemsCount)
    imgui.NextColumn()
    imgui.Text(u8"Обновлено: " .. (settings.lastScanDate or "-"))
    imgui.NextColumn()
    imgui.Text("v12.2 Elite")
    
    imgui.Columns(1)
    imgui.Spacing()
    imgui.Separator()
    imgui.Spacing()
    
    imgui.TextColored(theme.text_dim, u8"ИНСТРУКЦИЯ ПО ИСПОЛЬЗОВАНИЮ:")
    imgui.Spacing()
    
    local function drawStep(text)
        imgui.Text("• " .. u8(text))
        imgui.Spacing()
    end
    
    drawStep("Введите название товара сверху для поиска цен.")
    drawStep("Нажмите 'Скан Пикапа' стоя на метке ЦР, чтобы обновить цены.")
    drawStep("Вкладка 'Товары' покажет историю изменения цен.")
end

function renderItemsList()
    local draw_list = imgui.GetWindowDrawList()
    
    -- Обновляем список при открытии вкладки
    if currentTab == 2 then
        updateFilteredList()
    end

    ---------------------------------------------------------
    --  ПУСТОЙ ПОИСК (нет фильтра, нет результатов)
    ---------------------------------------------------------
    if #FilteredKeys == 0 and not showSearchResults then
        imgui.SetCursorPos(imgui.ImVec2(0, 100))
        
        local msg = u8"Начните вводить название товара для поиска"
        local msgW = imgui.CalcTextSize(msg).x
        imgui.SetCursorPosX((imgui.GetWindowWidth() - msgW) / 2)
        imgui.TextColored(theme.text_dim, msg)
        return
    end
    
    ---------------------------------------------------------
    --  РЕЗУЛЬТАТЫ ЕСТЬ, НО СПИСОК ПУСТ
    ---------------------------------------------------------
    if #FilteredKeys == 0 and showSearchResults then
        imgui.SetCursorPos(imgui.ImVec2(20, 20))
        imgui.TextColored(theme.red, u8"Товары не найдены")
        return
    end

    ---------------------------------------------------------
    --  ОСНОВНОЙ СПИСОК ПРЕДМЕТОВ
    ---------------------------------------------------------
    local contentW = imgui.GetContentRegionAvail().x

    for i, key in ipairs(FilteredKeys) do
        local history = itemsData[key]
        if history and #history > 0 then
            local lastData = history[#history]
            local formattedPrice = getFormattedPrice(lastData.price)

            imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, 5))

            local p = imgui.GetCursorScreenPos()
            local cardH = 60

            imgui.InvisibleButton("Item"..i, imgui.ImVec2(contentW, cardH))
            local isHovered = imgui.IsItemHovered()

            imgui.SetCursorPos(imgui.ImVec2(imgui.GetCursorPosX(), imgui.GetCursorPosY() - cardH - 5))

            -- Фон карточки
            local bgColor = isHovered and theme.item_bg_hov or theme.item_bg
            draw_list:AddRectFilled(
                p,
                imgui.ImVec2(p.x + contentW, p.y + cardH),
                imgui.GetColorU32Vec4(bgColor),
                6.0
            )

            -- Левая полоска акцента
            draw_list:AddRectFilledMultiColor(
                p, imgui.ImVec2(p.x + 4, p.y + cardH),
                imgui.GetColorU32Vec4(theme.accent),
                imgui.GetColorU32Vec4(theme.accent),
                imgui.GetColorU32Vec4(theme.accent_hov),
                imgui.GetColorU32Vec4(theme.accent_hov)
            )

            -------------------------------------------------
            -- НАЗВАНИЕ ПРЕДМЕТА
            -------------------------------------------------
            imgui.SetCursorScreenPos(imgui.ImVec2(p.x + 20, p.y + 10))
            imgui.PushFont(fonts.bold)
            imgui.TextColored(theme.text, u8(key))
            imgui.PopFont()

            -------------------------------------------------
            -- Последнее обновление
            -------------------------------------------------
            imgui.SetCursorScreenPos(imgui.ImVec2(p.x + 20, p.y + 32))
            imgui.TextColored(theme.text_dim, u8"Обновлено: " .. os.time_formatted(lastData.date))

            -------------------------------------------------
            -- Цена
            -------------------------------------------------
            local priceText = formattedPrice .. " $"
            imgui.SetCursorScreenPos(imgui.ImVec2(p.x + contentW - imgui.CalcTextSize(priceText).x - 60, p.y + 14))
            imgui.PushFont(fonts.big)
            imgui.TextColored(theme.text, priceText)
            imgui.PopFont()

            -------------------------------------------------
            -- КНОПКА УДАЛЕНИЯ
            -------------------------------------------------
            imgui.SetCursorScreenPos(imgui.ImVec2(p.x + contentW - 45, p.y + 15))
            
            imgui.PushStyleColor(imgui.Col.Text, theme.red)
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0,0,0,0))
            
            if imgui.Button(u8"Удалить##Del"..i, imgui.ImVec2(60, 30)) then
                deleteItem(key)
            end
            
            imgui.PopStyleColor(2)

            imgui.PopStyleVar(1)
            imgui.SetCursorPosY(imgui.GetCursorPosY() + 5)
        end
    end
end

function drawGradientButton(label, size)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    local w, h = size.x, size.y
    local hovered = imgui.IsMouseHoveringRect(p, imgui.ImVec2(p.x + w, p.y + h))
    
    local col_top_left = imgui.GetColorU32Vec4(theme.accent)
    local col_bot_right = imgui.GetColorU32Vec4(theme.accent_hov)
    
    if hovered then
        col_top_left = imgui.GetColorU32Vec4(imgui.ImVec4(1.0, 0.35, 0.50, 1.0))
    end
    
    draw_list:AddRectFilledMultiColor(p, imgui.ImVec2(p.x + w, p.y + h), col_top_left, col_bot_right, col_bot_right, col_top_left)
    
    imgui.InvisibleButton(label, size)
    local pressed = imgui.IsItemClicked()
    
    local text_size = imgui.CalcTextSize(label)
    local start_x = p.x + (w - text_size.x) / 2
    local start_y = p.y + (h - text_size.y) / 2
    
    draw_list:AddText(imgui.ImVec2(start_x, start_y), 0xFFFFFFFF, label)
    
    return pressed
end

function imgui.ToggleButton(str_id, v)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    local height = 18
    local width = 34
    local radius = height * 0.50
    
    imgui.InvisibleButton(str_id, imgui.ImVec2(width, height))
    if imgui.IsItemClicked() then
        v[0] = not v[0]
    end
    
    local t = v[0] and 1.0 or 0.0
    
    local col_bg
    if v[0] then
        col_bg = imgui.GetColorU32Vec4(theme.accent)
    else
        col_bg = imgui.GetColorU32Vec4(imgui.ImVec4(0.5, 0.5, 0.55, 1.0))
    end
    
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), col_bg, radius)
    
    local circle_radius = radius - 2
    local circle_x = v[0] and (p.x + width - radius) or (p.x + radius)
    
    draw_list:AddCircleFilled(imgui.ImVec2(circle_x, p.y + radius), circle_radius, 0xFFFFFFFF)
    
    return v[0]
end

-- Функция renderBuyingPage
function renderBuyingPage()
    local contentWidth = imgui.GetContentRegionAvail().x
    local contentHeight = imgui.GetContentRegionAvail().y
    local draw_list = imgui.GetWindowDrawList()
    
    -------------------------------------------------------------
    --  ПАНЕЛЬ УПРАВЛЕНИЯ (ТОП БАР)
    -------------------------------------------------------------
    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.04, 0.04, 0.06, 0.5))
    imgui.BeginChild("BuyingToolbar", imgui.ImVec2(contentWidth, 55), false)
        imgui.SetCursorPos(imgui.ImVec2(15, 12))
        
        -- Выбор конфига
        imgui.SetNextItemWidth(140)
        local configNameStr = ffi.string(shopConfigName)
        if configNameStr == "" then configNameStr = "Конфигурация" end
        
        -- u8 здесь нужен, так как configNameStr (ffi.string) может быть в UTF-8, но если название английское, u8 не повредит
        if imgui.BeginCombo("##Cfg", u8(configNameStr), imgui.ComboFlags.HeightSmall) then
            local configs = getShopConfigs()
            if #configs == 0 then imgui.Selectable(u8"Нет файлов", false, imgui.SelectableFlags.Disabled) end
            for _, name in ipairs(configs) do
                if imgui.Selectable(u8(name)) then 
                    loadShopConfig(name) 
                    ffi.copy(shopConfigName, name)
                end
            end
            imgui.EndCombo()
        end
        
        imgui.SameLine()
        
        -- Кнопка Сохранить
        if imgui.Button(u8"Сохранить", imgui.ImVec2(80, 28)) then 
            saveShopConfig() 
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Сохранить настройки") end
        
        -- Правая часть кнопок
        local btnW = 100
        imgui.SameLine(contentWidth - (btnW * 2) - 25)
        
        -- Кнопка Скан
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.2, 0.2, 0.25, 0.5))
        if imgui.Button(u8"Скан", imgui.ImVec2(btnW, 28)) then 
            startShopScanning() 
        end
        imgui.PopStyleColor()
        
        imgui.SameLine()

        -- Кнопка СТАРТ / СТОП
        local actColor = isAutoBuying and theme.red or theme.accent
        local actText = isAutoBuying and u8"СТОП" or u8"СТАРТ"
        
        imgui.PushStyleColor(imgui.Col.Button, actColor)
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.1, 0.1, 0.1, 1))
        
        if imgui.Button(actText, imgui.ImVec2(btnW, 28)) then
            if isAutoBuying then 
                isAutoBuying = false 
            else 
                startAutoBuying() 
            end
        end
        
        imgui.PopStyleColor(2)
        
    imgui.EndChild()
    imgui.PopStyleColor()
    
    -------------------------------------------------------------
    -- Разделитель
    -------------------------------------------------------------
    imgui.PushStyleColor(imgui.Col.Separator, theme.border)
    imgui.Separator()
    imgui.PopStyleColor()
    
    -- Обновляем таблицу (важно для поиска)
    refreshShopTable()
    
    -------------------------------------------------------------
    -- ДВЕ КОЛОНКИ: Товары лавки и Список на скуп
    -------------------------------------------------------------
    imgui.Columns(2, "BuyingColumns", true)
    
    -- [[ ЛЕВАЯ КОЛОНКА: Товары в лавке ]]
    imgui.BeginChild("ShopItemsList", imgui.ImVec2(0, contentHeight - 100), true)
        imgui.TextColored(theme.accent, u8"Товары в лавке")
        imgui.Separator()
        
        if #shopFilteredItems == 0 then
            imgui.SetCursorPosY(50)
            local msg = u8"Сделайте сканирование лавки"
            local msgW = imgui.CalcTextSize(msg).x
            imgui.SetCursorPosX((imgui.GetContentRegionAvail().x - msgW) / 2)
            imgui.TextColored(theme.text_dim, msg)
        else
            -- Список товаров в лавке
            local maxResults = 100
            for i = 1, math.min(#shopFilteredItems, maxResults) do
                local item = shopFilteredItems[i]
                
                local p = imgui.GetCursorScreenPos()
                local rowH = 40
                
                -- Фон строки
                local isHovered = imgui.IsMouseHoveringRect(p, imgui.ImVec2(p.x + imgui.GetContentRegionAvail().x, p.y + rowH))
                local bgColor = isHovered and imgui.ImVec4(0.12, 0.12, 0.18, 0.8) or 
                               (i % 2 == 0 and imgui.ImVec4(0.05, 0.05, 0.07, 0.5) or imgui.ImVec4(0.08, 0.08, 0.10, 0.3))
                
                draw_list:AddRectFilled(
                    p, 
                    imgui.ImVec2(p.x + imgui.GetContentRegionAvail().x, p.y + rowH), 
                    imgui.GetColorU32Vec4(bgColor), 
                    0.0
                )
                
                -- Кнопка добавления (на всю строку)
                imgui.InvisibleButton("##ShopItemBtn" .. i, imgui.ImVec2(imgui.GetContentRegionAvail().x, rowH))
                if imgui.IsItemClicked() then
                    if wantedItems[item.name] then
                        removeFromWantedList(item.name)
                    else
                        addToWantedList(item.name, item.id)
                    end
                end
                
                -- Иконка +/-
                imgui.SetCursorPos(imgui.ImVec2(10, imgui.GetCursorPosY() + 10 - rowH))
                if wantedItems[item.name] then
                    imgui.TextColored(theme.green, "?") -- Галочка (можно u8 если шрифт поддерживает)
                else
                    imgui.TextColored(theme.text_dim, "+")
                end
                
                -- Название (оборачиваем displayName в u8)
                imgui.SameLine()
                imgui.SetCursorPosX(30)
                imgui.TextWrapped(u8(item.displayName))
                
                -- ID
                imgui.SameLine(imgui.GetContentRegionAvail().x - 35)
                imgui.TextColored(theme.text_dim, tostring(item.id))
                
                imgui.SetCursorPosY(imgui.GetCursorPosY() + 15)
            end
        end
    imgui.EndChild()
    
    imgui.NextColumn()
    
    -- [[ ПРАВАЯ КОЛОНКА: Список на скуп ]]
    imgui.BeginChild("BuyingList", imgui.ImVec2(0, contentHeight - 100), true)
        imgui.TextColored(theme.accent, u8"Товары на скуп")
        imgui.Separator()
        
        if getTableSize(wantedItems) == 0 then
            imgui.SetCursorPosY(50)
            local msg = u8"Добавьте товары из лавки"
            local msgW = imgui.CalcTextSize(msg).x
            imgui.SetCursorPosX((imgui.GetContentRegionAvail().x - msgW) / 2)
            imgui.TextColored(theme.text_dim, msg)
        else
            -- Подготовка списка к сортировке
            local wantedItemsArray = {}
            for name, data in pairs(wantedItems) do
                table.insert(wantedItemsArray, {name = name, data = data})
            end
            
            -- Сортировка по CP1251 именам (без декодирования!)
            table.sort(wantedItemsArray, function(a, b) 
                local nameA = a.name:gsub("^Аксессуар ", ""):gsub("^Предмет ", ""):gsub("^Объект ", ""):gsub("^Одежда ", ""):gsub("^Оружие ", "")
                local nameB = b.name:gsub("^Аксессуар ", ""):gsub("^Предмет ", ""):gsub("^Объект ", ""):gsub("^Одежда ", ""):gsub("^Оружие ", "")
                return nameA < nameB 
            end)
            
            -- Отрисовка
            for idx, item in ipairs(wantedItemsArray) do
                local name = item.name -- Это CP1251
                local data = item.data
                
                local p = imgui.GetCursorScreenPos()
                local rowH = 70
                
                -- Фон
                draw_list:AddRectFilled(
                    p, 
                    imgui.ImVec2(p.x + imgui.GetContentRegionAvail().x, p.y + rowH), 
                    imgui.GetColorU32Vec4(theme.item_bg), 
                    4.0
                )
                
                -- Название товара
                imgui.SetCursorPos(imgui.ImVec2(10, imgui.GetCursorPosY() + 10))
                
                -- Чистим название (в CP1251), НЕ декодируем!
                local displayName = name:gsub("^Аксессуар ", ""):gsub("^Предмет ", ""):gsub("^Оружие ", ""):gsub("^Одежда ", ""):gsub("^Объект ", "")
                
                -- Отображаем (оборачиваем в u8 только здесь)
                local textSize = imgui.CalcTextSize(u8(displayName))
                if textSize.x > imgui.GetContentRegionAvail().x - 100 then
                    imgui.TextWrapped(u8(displayName))
                else
                    imgui.Text(u8(displayName))
                end
                
                -- Инпуты количества и цены
                imgui.SetCursorPos(imgui.ImVec2(10, imgui.GetCursorPosY() + 8))
                
                -- Кол-во
                imgui.TextColored(theme.text_dim, u8"Кол-во:")
                imgui.SameLine()
                imgui.PushItemWidth(70)
                
                local countBuf = imgui.new.int(data.count)
                if imgui.InputInt("##Cnt" .. idx, countBuf, 0, 0) then
                    local newCount = math.max(1, countBuf[0])
                    data.count = newCount
                end
                imgui.PopItemWidth()
                
                -- Цена
                imgui.SameLine()
                imgui.SetCursorPosX(150)
                imgui.TextColored(theme.text_dim, u8"Цена:")
                imgui.SameLine()
                imgui.PushItemWidth(100)
                
                local priceBuf = imgui.new.int(data.price)
                if imgui.InputInt("##Prc" .. idx, priceBuf, 0, 0) then
                    data.price = math.max(0, priceBuf[0])
                end
                imgui.PopItemWidth()
                
                imgui.SameLine()
                imgui.TextColored(theme.accent, "SA$")
                
                -- Кнопка удаления (Крестик)
                imgui.SetCursorPos(imgui.ImVec2(imgui.GetContentRegionAvail().x - 40, p.y - imgui.GetWindowPos().y + 15))
                
                imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.9, 0.3, 0.3, 0.3))
                imgui.PushStyleColor(imgui.Col.Text, theme.red)
                
                if imgui.Button("X##Del" .. idx, imgui.ImVec2(30, 30)) then
                    removeFromWantedList(name)
                end
                
                imgui.PopStyleColor(2)
                
                imgui.SetCursorPosY(imgui.GetCursorPosY() + 15)
            end
        end
    imgui.EndChild()
    
    imgui.Columns(1)
end


-- Функция для отрисовки UI
imgui.OnFrame(function() return WinState[0] end, function(player)
    local screenX, screenY = getScreenResolution()
    local targetW, targetH = 920, 580
    
    imgui.SetNextWindowSize(imgui.ImVec2(targetW, targetH), imgui.Cond.FirstUseEver)
    
    imgui.Begin("RODINAMARKET", WinState, 
        imgui.WindowFlags.NoCollapse + 
        imgui.WindowFlags.NoTitleBar +
        imgui.WindowFlags.NoResize
    )
    
    local W, H = imgui.GetWindowSize().x, imgui.GetWindowSize().y
    local sidebarW = 200
    local contentW = W - sidebarW
    local draw_list = imgui.GetWindowDrawList()
    
    -- ===========================
    -- [САЙДБАР]
    -- ===========================
    imgui.SetCursorPos(imgui.ImVec2(0, 0))
    imgui.PushStyleColor(imgui.Col.ChildBg, theme.sidebar)
    imgui.BeginChild("Sidebar", imgui.ImVec2(sidebarW, H), false)
        
        -- ЛОГОТИП
        imgui.SetCursorPos(imgui.ImVec2(20, 25))
        imgui.PushFont(fonts.big)
        imgui.TextColored(theme.text, "RODINA")
        imgui.SameLine(0, 0)
        imgui.TextColored(theme.accent, "MARKET")
        imgui.PopFont()
        
        imgui.SetCursorPosY(80)
        
        -- ТАБЫ МЕНЮ
        for i, tabInfo in ipairs(tabs) do
            local isSelected = (currentTab == i)

            if isSelected then
                local p = imgui.GetCursorScreenPos()
                draw_list:AddRectFilled(
                    p, 
                    imgui.ImVec2(p.x + 3, p.y + 38), 
                    imgui.GetColorU32Vec4(theme.accent), 0.0
                )
                draw_list:AddRectFilled(
                    p, 
                    imgui.ImVec2(p.x + sidebarW, p.y + 38), 
                    imgui.GetColorU32Vec4(imgui.ImVec4(1,1,1,0.03)), 
                    0.0
                )
                imgui.PushStyleColor(imgui.Col.Text, theme.text)
            else
                imgui.PushStyleColor(imgui.Col.Text, theme.text_dim)
            end

            if imgui.Button("##Tab"..i, imgui.ImVec2(sidebarW, 38)) then
                currentTab = i
                showSearchResults = (i == 3)
            end
            
            local curY = imgui.GetItemRectMin().y
            imgui.SetCursorPos(imgui.ImVec2(20, (curY - imgui.GetWindowPos().y) + 10))
            
            imgui.Text(u8(tabInfo.name))

            imgui.PopStyleColor()
        end
        
    imgui.EndChild()
    imgui.PopStyleColor()
    
    imgui.SameLine()
    
    -- ===========================
    -- [ОСНОВНОЙ КОНТЕНТ]
    -- ===========================
    imgui.BeginGroup()
        
        -- ШАПКА (HEADER)
        local headerH = 50
        local p = imgui.GetCursorScreenPos()
        draw_list:AddLine(
            imgui.ImVec2(p.x, p.y + headerH),
            imgui.ImVec2(p.x + contentW, p.y + headerH),
            imgui.GetColorU32Vec4(theme.border), 1.0
        )
        
        -- ПОЛЕ ПОИСКА
        local searchW = 350
        local searchHint = u8"Поиск..."
        
        if currentTab == 3 then -- Вкладка Скупка
            searchHint = u8"Поиск товаров для скупа..."
        elseif currentTab == 2 then -- Вкладка Продажа
            searchHint = u8"Поиск товаров в базе..."
        end
        
        imgui.SetCursorPos(imgui.ImVec2(sidebarW + (contentW - searchW)/2, 10))

        imgui.PushStyleColor(imgui.Col.FrameBg, theme.input_bg)
        imgui.PushStyleColor(imgui.Col.Border, theme.border)
        imgui.SetNextItemWidth(searchW)

        if currentTab == 3 then
            -- Для вкладки Скупка используем shopFindBuffer
            if imgui.InputTextWithHint("##GlobalSearch", searchHint, shopFindBuffer, 256) then
                updateFilteredShopItems()
            end
        else
            -- Для других вкладок используем SearchBuffer
            if imgui.InputTextWithHint("##GlobalSearch", searchHint, SearchBuffer, 256) then
                updateFilteredList()
            end
        end

        imgui.PopStyleColor(2)
        
        -- КНОПКА ЗАКРЫТИЯ
        imgui.SetCursorPos(imgui.ImVec2(W - 40, 12))
        imgui.PushStyleColor(imgui.Col.Text, theme.text_dim)

        if imgui.Button("X", imgui.ImVec2(30, 30)) then 
            WinState[0] = false 
        end

        imgui.PopStyleColor()
        
        -- КОНТЕНТ СТРАНИЦЫ
        imgui.SetCursorPos(imgui.ImVec2(sidebarW, headerH))
        imgui.BeginChild("PageContent", imgui.ImVec2(contentW, H - headerH), false)
            
            if currentTab == 3 then
                renderBuyingPage()
            elseif currentTab == 1 then
                renderHomePage()
            elseif currentTab == 2 then
                renderSalePage()
			elseif currentTab == 5 then -- Логи (индекс 5)
				renderLogsPage()
            else
                imgui.SetCursorPos(imgui.ImVec2(contentW/2 - 60, H/2 - 20))
                imgui.TextColored(theme.text_dim, u8"Раздел в разработке")
            end
            
        imgui.EndChild()

    imgui.EndGroup()
    
    imgui.End()
end)

function cmd_price(arg)
    if not arg or arg == "" then
        systemMessage("Использование: /price [название]")
        return
    end
    
    local s = string.lower(arg)
    local found = {}
    
    for k, v in pairs(itemsData) do
        -- ЗАЩИТА ОТ КРАША: проверяем, что v это таблица, прежде чем брать длину
        if v and type(v) == 'table' and #v > 0 and string_contains_ignore_case(k, s) then 
            table.insert(found, {k, v}) 
        end
    end
    
    if #found == 0 then 
        systemMessage("Товар не найден.") 
        return 
    end
    
    -- Сортировка с защитой от ошибок типов
    table.sort(found, function(a,b) 
        local lenA = a[1] and #tostring(a[1]) or 0
        local lenB = b[1] and #tostring(b[1]) or 0
        return lenA < lenB 
    end)
    
    systemMessage("Найдено " .. #found .. " похожих:")
    for i = 1, math.min(#found, 5) do
        local name, hist = found[i][1], found[i][2]
        
        if hist and type(hist) == 'table' and #hist > 0 then
            local lastEntry = hist[#hist]
            if lastEntry then
                local lastPrice = lastEntry.price
                sampAddChatMessage(string.format("{3498db}> %s {FFFFFF}: {2ecc71}$%s", name, formatNumber(lastPrice)), -1)
            end
        end
    end
end

function main()
    while not isSampAvailable() do wait(100) end
    if not doesDirectoryExist(configDir) then createDirectory(configDir) end
    
    loadAllPrices()
    loadScannedShopItems()
    loadMarketLogs()
    
    -- Загружаем названия предметов
    loadItemsNames()
    
    ffi.copy(shopFindBuffer, "")
    
    sampRegisterChatCommand("rodinamenu", function() 
        WinState[0] = not WinState[0] 
    end)
    
    sampRegisterChatCommand("price", cmd_price)
    
    sampRegisterChatCommand("scanpickup", function() 
        if isPickupScanning then
            isPickupScanning = false
            systemMessage("Сканирование остановлено.")
        else
            startPickupScanning()
        end
    end)
    
    -- Команда для сканирования инвентаря
    sampRegisterChatCommand("scansale", function()
        startInventoryScanning()
    end)
    
    systemMessage("RODINAMARKET v12.2 PRO Loaded. /rodinamenu | /scanpickup | /scansale")
    wait(-1)
end