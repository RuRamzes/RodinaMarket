require('lib.moonloader')
-- dlstatus больше не нужен
local imgui = require 'mimgui'
local ffi = require 'ffi'
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local json = require 'dkjson'
local events = require('lib.samp.events')
local fa = require 'fAwesome6'

-- Константы и настройки
-- Версия теперь просто для отображения, обновление идет через имя файла
local SCRIPT_VERSION = "1.7.2" 

-- Создаем структуру папок
local BASE_FOLDER = getWorkingDirectory() .. "\\RodinaMarket"
local DATA_FOLDER = BASE_FOLDER .. "\\data"
local ITEMS_FOLDER = BASE_FOLDER .. "\\items"
local LOGS_FOLDER = BASE_FOLDER .. "\\logs"

-- Папка updates больше не нужна, её создаст лоадер во временной директории ОС если надо
local function createFolders()
    local folders = {BASE_FOLDER, DATA_FOLDER, ITEMS_FOLDER, LOGS_FOLDER}
    for _, folder in ipairs(folders) do
        if not doesDirectoryExist(folder) then
            createDirectory(folder)
        end
    end
end

createFolders()

-- Пути к файлам конфигурации
local CONFIG_PATHS = {
    sell_items = DATA_FOLDER .. "\\sell_items.json",
    buy_items = DATA_FOLDER .. "\\buy_items.json",
    cached_items = DATA_FOLDER .. "\\cached_items.json",
    scanned_items = DATA_FOLDER .. "\\scanned_items.json",
    unsellable_items = DATA_FOLDER .. "\\unsellable_items.json",
    buyable_items = DATA_FOLDER .. "\\buyable_items.json",
    transaction_logs = DATA_FOLDER .. "\\transaction_logs.json",
    average_prices = DATA_FOLDER .. "\\average_prices.json",
    settings = DATA_FOLDER .. "\\settings.json"
}

-- Версия items.json
local ITEMS_VERSION_FILE = ITEMS_FOLDER .. "\\version.json"
local ITEMS_FILE = ITEMS_FOLDER .. "\\items.json"

local App = {
    win_state = imgui.new.bool(false),
    active_tab = 1,
    is_scanning = false,
    is_scanning_buy = false,
    current_page = 1,
    current_model_id = nil,
    cef_inventory_active = false,
    cef_price_only = false,
    is_selling_cef = false,
    current_processing_item = nil,
    tasks = {},
    tasks_list = {}
    -- Поля обновлений удалены
}

local Cache = {
    sell_search_result = {},
    last_sell_query = "",
    buy_search_result = {},
    last_buy_query = ""
}

local Data = {
    scanned_items = {},
    sell_list = {},
    buy_list = {},
    cached_items = {},
    unsellable_items = {},
    buyable_items = {},
    transaction_logs = {},
    filtered_logs = {},
    cef_slots_data = {},
    cef_sell_queue = {},
    cef_inventory_items = {},
    item_names = {},
    average_prices = {},
    settings = {
        items_version = "0.0.0"
    }
}

local Buffers = {
    logs_search = imgui.new.char[128](),
    sell_search = imgui.new.char[128](),
    buy_search = imgui.new.char[128](),
    input_buffers = {},
    buy_input_buffers = {},
    log_filters = {
        show_sales = imgui.new.bool(true),
        show_purchases = imgui.new.bool(true),
        time_filter = 0,
        player_filter = imgui.new.char[64](),
        item_filter = imgui.new.char[64]()
    }
}

local State = {
    buying_scan = { active = false, stage = nil, current_page = 1, all_items = {}, current_dialog_id = nil },
    buying = { active = false, stage = nil, current_item_index = 1, items_to_buy = {}, last_search_name = nil },
    smooth_scroll = { current = 0.0, target = 0.0, speed = 18.0, wheel_step = 80.0 },
    log_stats = { total_sales = 0, total_purchases = 0, sales_amount = 0, purchases_amount = 0 },
    avg_scan = { active = false, processed_count = 0 }
}

local sw, sh = getScreenResolution()
local SCALE = math.max(1.0, sh / 1080)

function S(value) return value * SCALE end

function sendCEF(payload)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 220)
    raknetBitStreamWriteInt8(bs, 18)
    raknetBitStreamWriteInt16(bs, #payload)
    raknetBitStreamWriteString(bs, payload)
    raknetBitStreamWriteInt32(bs, 0)
    raknetSendBitStream(bs, 2, 9, 6)
    raknetDeleteBitStream(bs)
end

function closeCEFInventory()
    sendCEF("inventoryClose")
    App.cef_inventory_active = false
    Data.cef_inventory_items = {}
end

function log(text) print("[RodinaMarket] " .. text) end

local function loadJSONFile(path, default)
    local file = io.open(path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local status, result = pcall(json.decode, content)
        if status and result then
            return result
        end
    end
    return default or {}
end

local function saveJSONFile(path, data)
    -- Профессиональный подход: Атомарная запись
    -- 1. Пишем во временный файл
    local temp_path = path .. ".tmp"
    local file = io.open(temp_path, "w")
    if file then
        -- Используем pcall для защиты от ошибок кодирования JSON
        local status, content = pcall(json.encode, data, { indent = true })
        if not status then
            print("[RodinaMarket] Error encoding JSON for " .. path .. ": " .. tostring(content))
            file:close()
            os.remove(temp_path)
            return false
        end
        
        file:write(content)
        file:close()
        
        -- 2. Удаляем старый файл (если есть) и переименовываем временный
        -- На Windows os.rename может не сработать, если целевой файл существует, поэтому удаляем
        os.remove(path) 
        local result, err = os.rename(temp_path, path)
        if not result then
            print("[RodinaMarket] Error renaming file: " .. tostring(err))
            return false
        end
        return true
    end
    return false
end

-- Загрузка items.json с обработкой кодировки
function loadItemNames()
    if doesFileExist(ITEMS_FILE) then
        local file = io.open(ITEMS_FILE, "r")
        if file then
            local content = file:read("*a")
            file:close()
            local status, result = pcall(json.decode, content)
            if status and result then
                Data.item_names = {}
                for id, name in pairs(result) do
                    -- Декодируем из UTF-8 в CP1251 для использования в игре
                    Data.item_names[tostring(id)] = u8:decode(name)
                end
                sampAddChatMessage('[RodinaMarket] {00ff00}Загружено названий предметов: ' .. countTable(Data.item_names), -1)
            end
        end
    else
        sampAddChatMessage('[RodinaMarket] {ffff00}Файл items.json не найден. Будет скачан при следующей проверке обновлений.', -1)
    end
    
    -- Загружаем версию items.json
    if doesFileExist(ITEMS_VERSION_FILE) then
        local version_data = loadJSONFile(ITEMS_VERSION_FILE)
        if version_data and version_data.version then
            Data.settings.items_version = version_data.version
        end
    end
end

function parseShopMessage(text)
    local clean_text = text:gsub("{......}", "")
    if not clean_text:find("[Лавка]") then return nil end
    clean_text = clean_text:gsub("%[Лавка%]%s*", "")
    local transaction = {
        timestamp = os.time(),
        date = os.date("%Y-%m-%d %H:%M:%S"),
        type = nil,
        player = nil,
        item = nil,
        amount = 0,
        price = 0,
        total = 0
    }
    local pattern_sale = "(.+) продал Вам предмет (.+) %((%d+) шт%.%) за (.+) руб%."
    local player_sale, item_sale, amount_sale, price_sale = clean_text:match(pattern_sale)
    if player_sale and item_sale then
        transaction.type = "purchase"
        if player_sale then player_sale = player_sale:gsub("^%s*(.-)%s*$", "%1") end
        transaction.item = item_sale:gsub("^%s*(.-)%s*$", "%1")
        transaction.amount = tonumber(amount_sale) or 0
        local price_clean = price_sale:gsub("%.", "")
        transaction.price = tonumber(price_clean) or 0
        transaction.total = transaction.price
        return transaction
    end
    local pattern_buy_complex = "(.+) приобрел у Вас (.+) %((%d+) шт%.%) за (.+) руб%."
    local player_buy, item_buy, amount_buy, price_buy = clean_text:match(pattern_buy_complex)
    if not player_buy then
        local pattern_buy_simple = "(.+) приобрел у Вас (.+) за (.+) руб%."
        player_buy, item_buy, price_buy = clean_text:match(pattern_buy_simple)
        amount_buy = 1
    end
    if player_buy and item_buy then
        transaction.type = "sale"
        transaction.player = player_buy:gsub("^%s*(.-)%s*$", "%1")
        transaction.item = item_buy:gsub("^%s*(.-)%s*$", "%1")
        transaction.amount = tonumber(amount_buy) or 1
        if price_buy then
            local price_clean = price_buy:gsub("%.", "")
            transaction.price = tonumber(price_clean) or 0
            transaction.total = transaction.price
        end
        return transaction
    end
    return nil
end

function addTransactionLog(transaction)
    if not transaction then return end
    table.insert(Data.transaction_logs, 1, transaction)
    if transaction.type == "sale" then
        State.log_stats.total_sales = State.log_stats.total_sales + 1
        State.log_stats.sales_amount = State.log_stats.sales_amount + transaction.total
    else
        State.log_stats.total_purchases = State.log_stats.total_purchases + 1
        State.log_stats.purchases_amount = State.log_stats.purchases_amount + transaction.total
    end
    if #Data.transaction_logs > 1000 then table.remove(Data.transaction_logs, 1001) end
    saveConfig()
    filterLogs()
end

function filterLogs()
    Data.filtered_logs = {}
    local search_text = ffi.string(Buffers.logs_search):lower()
    local player_filter = ffi.string(Buffers.log_filters.player_filter):lower()
    local item_filter = ffi.string(Buffers.log_filters.item_filter):lower()
    local now = os.time()
    local time_filter_days = {[0]=36500, [1]=1, [2]=2, [3]=7, [4]=30}
    local max_age = time_filter_days[Buffers.log_filters.time_filter] or 36500
    for _, log_entry in ipairs(Data.transaction_logs) do
        local log_age = (now - log_entry.timestamp) / 86400
        if log_age > max_age then goto continue end
        if log_entry.type == "sale" and not Buffers.log_filters.show_sales[0] then goto continue end
        if log_entry.type == "purchase" and not Buffers.log_filters.show_purchases[0] then goto continue end
        if player_filter ~= "" and not log_entry.player:lower():find(player_filter, 1, true) then goto continue end
        if item_filter ~= "" and not log_entry.item:lower():find(item_filter, 1, true) then goto continue end
        if search_text ~= "" then
            local found = false
            if log_entry.player:lower():find(search_text, 1, true) then found = true
            elseif log_entry.item:lower():find(search_text, 1, true) then found = true
            elseif tostring(log_entry.amount):find(search_text, 1, true) then found = true
            elseif formatMoney(log_entry.total):lower():find(search_text, 1, true) then found = true
            end
            if not found then goto continue end
        end
        table.insert(Data.filtered_logs, log_entry)
        ::continue::
    end
end

function formatMoney(amount)
    if amount < 1000 then return tostring(amount) end
    local formatted = tostring(amount)
    local result = ""
    local counter = 0
    for i = #formatted, 1, -1 do
        counter = counter + 1
        result = formatted:sub(i, i) .. result
        if counter % 3 == 0 and i ~= 1 then result = "." .. result end
    end
    return result
end

function loadLogsFromConfig()
    Data.transaction_logs = loadJSONFile(CONFIG_PATHS.transaction_logs, {})
    recalculateStats()
    filterLogs()
end

function recalculateStats()
    State.log_stats = {total_sales=0, total_purchases=0, sales_amount=0, purchases_amount=0}
    for _, log_entry in ipairs(Data.transaction_logs) do
        if log_entry.type == "sale" then
            State.log_stats.total_sales = State.log_stats.total_sales + 1
            State.log_stats.sales_amount = State.log_stats.sales_amount + (log_entry.total or 0)
        else
            State.log_stats.total_purchases = State.log_stats.total_purchases + 1
            State.log_stats.purchases_amount = State.log_stats.purchases_amount + (log_entry.total or 0)
        end
    end
end

function saveLogsToConfig()
    saveJSONFile(CONFIG_PATHS.transaction_logs, Data.transaction_logs)
end

function clearLogs()
    Data.transaction_logs = {}
    Data.filtered_logs = {}
    recalculateStats()
    saveLogsToConfig()
    sampAddChatMessage('[RodinaMarket] {00ff00}Логи очищены!', -1)
end

function exportLogsToCSV()
    local filename = "RodinaMarket_Logs_" .. os.date("%Y-%m-%d_%H-%M-%S") .. ".csv"
    local file = io.open(LOGS_FOLDER .. "\\" .. filename, "w")
    if not file then return end
    file:write("Дата;Тип;Игрок;Предмет;Количество;Цена;Итого\n")
    for _, log_entry in ipairs(Data.transaction_logs) do
        local type_str = (log_entry.type == "sale") and "Продажа" or "Покупка"
        file:write(string.format("%s;%s;%s;%s;%d;%s;%s\n",
            log_entry.date, type_str, log_entry.player:gsub(";", ","), log_entry.item:gsub(";", ","),
            log_entry.amount, formatMoney(log_entry.price or 0), formatMoney(log_entry.total or 0)
        ))
    end
    file:close()
    sampAddChatMessage('[RodinaMarket] {00ff00}Экспорт: ' .. filename, -1)
end


function clamp(v, min, max)
    if v < min then return min end
    if v > max then return max end
    return v
end

function lerp(a, b, t) return a + (b - a) * t end

function handleSmoothScroll(content_height)
    local io = imgui.GetIO()
    if imgui.IsWindowHovered() and io.MouseWheel ~= 0 then
        State.smooth_scroll.target = State.smooth_scroll.target - io.MouseWheel * State.smooth_scroll.wheel_step
    end
    local max_scroll = math.max(0, content_height - imgui.GetWindowHeight())
    State.smooth_scroll.target = clamp(State.smooth_scroll.target, 0, max_scroll)
    State.smooth_scroll.current = lerp(State.smooth_scroll.current, State.smooth_scroll.target, imgui.GetIO().DeltaTime * State.smooth_scroll.speed)
    imgui.SetScrollY(State.smooth_scroll.current)
end

function App.tasks.add(name, code, wait_time)
    local task = {name = name, code = code, start_time = os.clock() * 1000, wait_time = wait_time}
    table.insert(App.tasks_list, task)
end

function App.tasks.process()
    local i = 1
    while i <= #App.tasks_list do
        local v = App.tasks_list[i]
        if (os.clock() * 1000) - v.start_time >= v.wait_time then
            local status, err = pcall(v.code)
            if not status then print("Task Error: " .. err) end
            table.remove(App.tasks_list, i)
        else
            i = i + 1
        end
    end
end

function App.tasks.remove_by_name(name)
    for i, v in ipairs(App.tasks_list) do
        if v.name == name then table.remove(App.tasks_list, i) return end
    end
end

function saveConfig()
    saveJSONFile(CONFIG_PATHS.sell_items, Data.sell_list)
    saveJSONFile(CONFIG_PATHS.buy_items, Data.buy_list)
    saveJSONFile(CONFIG_PATHS.cached_items, Data.cached_items)
    saveJSONFile(CONFIG_PATHS.scanned_items, Data.scanned_items)
    saveJSONFile(CONFIG_PATHS.unsellable_items, Data.unsellable_items)
    saveJSONFile(CONFIG_PATHS.buyable_items, Data.buyable_items)
    saveJSONFile(CONFIG_PATHS.transaction_logs, Data.transaction_logs)
    saveJSONFile(CONFIG_PATHS.average_prices, Data.average_prices)
    saveJSONFile(CONFIG_PATHS.settings, Data.settings)
end

function loadConfigData()
    Data.sell_list = loadJSONFile(CONFIG_PATHS.sell_items, {})
    Data.buy_list = loadJSONFile(CONFIG_PATHS.buy_items, {})
    Data.cached_items = loadJSONFile(CONFIG_PATHS.cached_items, {})
    Data.scanned_items = loadJSONFile(CONFIG_PATHS.scanned_items, {})
    Data.unsellable_items = loadJSONFile(CONFIG_PATHS.unsellable_items, {})
    Data.buyable_items = loadJSONFile(CONFIG_PATHS.buyable_items, {})
    Data.transaction_logs = loadJSONFile(CONFIG_PATHS.transaction_logs, {})
    Data.average_prices = loadJSONFile(CONFIG_PATHS.average_prices, {})
    Data.settings = loadJSONFile(CONFIG_PATHS.settings, Data.settings)
    
    recalculateStats()
    filterLogs()
end

function updateAveragePrice(item_name, new_price)
    new_price = tonumber(new_price)
    if not new_price or new_price <= 0 then return end
    
    local clean_name = item_name:gsub("{......}", ""):gsub("^%s*(.-)%s*$", "%1")
    
    if not Data.average_prices[clean_name] then
        Data.average_prices[clean_name] = { price = new_price, count = 1 }
    else
        local data = Data.average_prices[clean_name]
        local total_sum = (data.price * data.count) + new_price
        local new_count = data.count + 1
        data.price = math.floor(total_sum / new_count)
        data.count = new_count
    end
    
    saveJSONFile(CONFIG_PATHS.average_prices, Data.average_prices)
end

function startAvgPriceScan()
    if App.is_scanning or State.avg_scan.active then return end
    State.avg_scan.active = true
    State.avg_scan.processed_count = 0
    sampAddChatMessage('[RodinaMarket] {ffff00}Начинаю сканирование средних цен...', -1)
    sampAddChatMessage('[RodinaMarket] {ffff00}Откройте диалог "Ценовая политика" (пикап на ЦР), если он не открыт.', -1)
end

function events.onServerMessage(color, text)
    if not text:find("[Лавка]") then return true end
    local transaction = parseShopMessage(text)
    if transaction then
        addTransactionLog(transaction)
        local color_msg = (transaction.type == "sale") and "00ff00" or "ffff00"
        local type_msg = (transaction.type == "sale") and "Продажа" or "Покупка"
        sampAddChatMessage(string.format('[RodinaMarket] {%s}%s: %s %s (%d шт.) за %s руб.', color_msg, type_msg, transaction.player, transaction.item, transaction.amount, formatMoney(transaction.total)), -1)
    end
    return true
end

function to_lower(str)
    local res = {}
    local len = #str
    for i = 1, len do
        local b = string.byte(str, i)
        if b >= 192 and b <= 223 then
            table.insert(res, string.char(b + 32))
        elseif b == 168 then
            table.insert(res, string.char(184))
        else
            table.insert(res, string.char(b):lower())
        end
    end
    return table.concat(res)
end

function renderModernSearchBar(buffer, hint, width)
    imgui.PushStyleVarFloat(imgui.StyleVar.FrameRounding, S(6.0))
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(S(12), S(10)))
    imgui.SetNextItemWidth(width)
    local changed = imgui.InputTextWithHint("##search_" .. tostring(buffer), u8(hint), buffer, 128)
    local min = imgui.GetItemRectMin()
    local max = imgui.GetItemRectMax()
    local draw_list = imgui.GetWindowDrawList()
    local icon = fa('magnifying_glass')
    local font_size = imgui.GetFontSize()
    local icon_pos = imgui.ImVec2(max.x - font_size - S(10), min.y + (max.y - min.y - font_size) / 2)
    draw_list:AddText(icon_pos, imgui.GetColorU32(imgui.Col.TextDisabled), icon)
    imgui.PopStyleVar(2)
    return changed
end

function getFilteredItems(list, buffer_char, cache_key_result, cache_key_query)
    local query_utf8 = ffi.string(buffer_char)
    
    -- Если запрос не изменился и есть кэш — отдаем кэш
    if query_utf8 == Cache[cache_key_query] and Cache[cache_key_result] then
        return Cache[cache_key_result]
    end

    -- Иначе фильтруем
    local query = u8:decode(query_utf8):lower() -- Декодируем один раз
    local result = {}
    
    if query == "" then
        result = list
    else
        -- Используем предвычисленный lower case, если возможно, или вычисляем тут
        for _, item in ipairs(list) do
            -- Оптимизация: проверяем наличие item.name_lower (можно добавить при сканировании)
            -- Если нет, то to_lower(item.name)
            local item_name = item.name:lower() 
            if item_name:find(query, 1, true) then
                table.insert(result, item)
            end
        end
    end

    -- Обновляем кэш
    Cache[cache_key_query] = query_utf8
    Cache[cache_key_result] = result
    return result
end

function renderLogsTab()
    local avail_size = imgui.GetContentRegionAvail()
    imgui.BeginChild("LogsFilters", imgui.ImVec2(0, 110), true)
    imgui.Text(u8("Фильтры:"))
    imgui.SameLine()
    imgui.Checkbox(u8("Продажи"), Buffers.log_filters.show_sales)
    imgui.SameLine()
    imgui.Checkbox(u8("Покупки"), Buffers.log_filters.show_purchases)
    imgui.SameLine(200)
    imgui.Text(u8("Период:"))
    imgui.SameLine()
    imgui.SetNextItemWidth(120)
    if imgui.BeginCombo("##time_filter",
        Buffers.log_filters.time_filter == 0 and u8"Все время" or
        Buffers.log_filters.time_filter == 1 and u8"Сегодня" or
        Buffers.log_filters.time_filter == 2 and u8"Вчера" or
        Buffers.log_filters.time_filter == 3 and u8"7 дней" or u8"30 дней") then
        if imgui.Selectable(u8"Все время", Buffers.log_filters.time_filter == 0) then Buffers.log_filters.time_filter = 0 filterLogs() end
        if imgui.Selectable(u8"Сегодня", Buffers.log_filters.time_filter == 1) then Buffers.log_filters.time_filter = 1 filterLogs() end
        if imgui.Selectable(u8"Вчера", Buffers.log_filters.time_filter == 2) then Buffers.log_filters.time_filter = 2 filterLogs() end
        if imgui.Selectable(u8"7 дней", Buffers.log_filters.time_filter == 3) then Buffers.log_filters.time_filter = 3 filterLogs() end
        if imgui.Selectable(u8"30 дней", Buffers.log_filters.time_filter == 4) then Buffers.log_filters.time_filter = 4 filterLogs() end
        imgui.EndCombo()
    end
    imgui.Spacing()
    imgui.Text(u8("Поиск:"))
    imgui.SameLine()
    imgui.SetNextItemWidth(250)
    if imgui.InputTextWithHint("##logs_search", u8"Введите текст...", Buffers.logs_search, ffi.sizeof(Buffers.logs_search)) then filterLogs() end
    imgui.SameLine()
    if imgui.Button(u8("Применить")) then filterLogs() end
    imgui.Spacing()
    imgui.Text(u8("Игрок:"))
    imgui.SameLine()
    imgui.SetNextItemWidth(180)
    if imgui.InputTextWithHint("##player_filter", u8"Фильтр по игроку...", Buffers.log_filters.player_filter, ffi.sizeof(Buffers.log_filters.player_filter)) then end
    imgui.SameLine()
    imgui.Text(u8("Предмет:"))
    imgui.SameLine()
    imgui.SetNextItemWidth(180)
    if imgui.InputTextWithHint("##item_filter", u8"Фильтр по предмету...", Buffers.log_filters.item_filter, ffi.sizeof(Buffers.log_filters.item_filter)) then end
    imgui.EndChild()
    imgui.BeginChild("LogsStats", imgui.ImVec2(0, 60), true)
    imgui.Columns(4, "StatsColumns", false)
    imgui.TextColored(imgui.ImVec4(0, 1, 0, 1), u8("Продажи:"))
    imgui.Text(u8("Кол: " .. State.log_stats.total_sales .. " | Сумма: " .. formatMoney(State.log_stats.sales_amount)))
    imgui.NextColumn()
    imgui.TextColored(imgui.ImVec4(1, 1, 0, 1), u8("Покупки:"))
    imgui.Text(u8("Кол: " .. State.log_stats.total_purchases .. " | Сумма: " .. formatMoney(State.log_stats.purchases_amount)))
    imgui.NextColumn()
    imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), u8("Итого транзакций: " .. (State.log_stats.total_sales + State.log_stats.total_purchases)))
    local balance = State.log_stats.sales_amount - State.log_stats.purchases_amount
    local balance_color = (balance >= 0) and imgui.ImVec4(0, 1, 0, 1) or imgui.ImVec4(1, 0, 0, 1)
    imgui.TextColored(balance_color, u8("Баланс: " .. formatMoney(balance)))
    imgui.NextColumn()
    if imgui.Button(u8("Экспорт CSV"), imgui.ImVec2(100, 0)) then exportLogsToCSV() end
    imgui.SameLine()
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.2, 0.2, 1.0))
    if imgui.Button(u8("Очистить"), imgui.ImVec2(80, 0)) then clearLogs() end
    imgui.PopStyleColor()
    imgui.Columns(1)
    imgui.EndChild()
    imgui.BeginChild("LogsTable", imgui.ImVec2(0, 0), true)
    if #Data.filtered_logs == 0 then
        imgui.Text(u8("Нет записей."))
        imgui.EndChild()
        return
    end
    imgui.Columns(7, "LogsColumns", true)
    imgui.Separator()
    imgui.Text(u8("Дата")); imgui.NextColumn()
    imgui.Text(u8("Тип")); imgui.NextColumn()
    imgui.Text(u8("Игрок")); imgui.NextColumn()
    imgui.Text(u8("Предмет")); imgui.NextColumn()
    imgui.Text(u8("Кол-во")); imgui.NextColumn()
    imgui.Text(u8("Цена")); imgui.NextColumn()
    imgui.Text(u8("Итого")); imgui.NextColumn()
    imgui.Separator()
    local line_height = imgui.GetTextLineHeightWithSpacing()
    local scroll_y = imgui.GetScrollY()
    local window_height = imgui.GetWindowHeight()
    local items_per_screen = math.ceil(window_height / line_height)
    local first_item = math.floor(scroll_y / line_height)
    local last_item = math.min(first_item + items_per_screen + 2, #Data.filtered_logs)
    imgui.Dummy(imgui.ImVec2(0, first_item * line_height))
    for i = first_item + 1, last_item do
        local log_entry = Data.filtered_logs[i]
        imgui.Text(u8(log_entry.date)); imgui.NextColumn()
        if log_entry.type == "sale" then imgui.TextColored(imgui.ImVec4(0, 1, 0, 1), u8("Продажа"))
        else imgui.TextColored(imgui.ImVec4(1, 1, 0, 1), u8("Покупка")) end
        imgui.NextColumn()
        imgui.Text(u8(log_entry.player)); imgui.NextColumn()
        imgui.TextWrapped(u8(log_entry.item)); imgui.NextColumn()
        imgui.Text(u8(tostring(log_entry.amount))); imgui.NextColumn()
        imgui.Text(u8(formatMoney(log_entry.price))); imgui.NextColumn()
        imgui.TextColored(imgui.ImVec4(1, 1, 1, 1), u8(formatMoney(log_entry.total))); imgui.NextColumn()
        imgui.Separator()
    end
    local remaining_items = #Data.filtered_logs - last_item
    if remaining_items > 0 then imgui.Dummy(imgui.ImVec2(0, remaining_items * line_height)) end
    imgui.Columns(1)
    imgui.EndChild()
end

function countTable(tbl)
    local count = 0
    for _ in pairs(tbl) do count = count + 1 end
    return count
end

function startScanning()
    if App.is_scanning or App.is_selling_cef or App.is_scanning_buy or State.buying.active then return end
    startCEFScanning()
end

function startCEFScanning()
    App.cef_inventory_active = true
    Data.cef_inventory_items = {}
    Data.scanned_items = {}
    App.is_scanning = true
    sampAddChatMessage('[RodinaMarket] {ffff00}Начинаю сканирование инвентаря...', -1)
    sampSendChat('/invent')
    App.tasks.add("wait_cef_data", function()
        if not App.cef_inventory_active or not App.is_scanning then return end
        for item_id, item_data in pairs(Data.cef_inventory_items) do
            if not isItemUnsellable(item_data.model_id) then
                table.insert(Data.scanned_items, {name = item_data.name, model_id = item_data.model_id})
            end
        end
        closeCEFInventory()
        local unique_items = {}
        local seen_names = {}
        for _, item in ipairs(Data.scanned_items) do
            if not seen_names[item.name] then
                seen_names[item.name] = true
                table.insert(unique_items, item)
            end
        end
        Data.scanned_items = unique_items
        saveConfig()
        App.is_scanning = false
        sampAddChatMessage('[RodinaMarket] {00ff00}Сканирование завершено! Найдено: ' .. #Data.scanned_items, -1)
        App.win_state[0] = true
    end, 2000)
end

function isItemUnsellable(model_id)
    for _, unsellable_id in ipairs(Data.unsellable_items) do
        if tostring(unsellable_id) == tostring(model_id) then return true end
    end
    return false
end

function startBuyingScan()
    if App.is_scanning or App.is_selling_cef or App.is_scanning_buy or State.buying.active then return end
    Data.buyable_items = {}
    State.buying_scan = {active=true, stage='waiting_dialog', current_page=1, all_items={}, current_dialog_id=nil}
    App.is_scanning_buy = true
    sampAddChatMessage('[RodinaMarket] {ffff00}Сканирование товаров для скупки...', -1)
    App.tasks.add("buy_press_alt", function()
        setVirtualKeyDown(0x12, true)
        App.tasks.add("buy_release_alt", function() setVirtualKeyDown(0x12, false) end, 50)
    end, 1000)
    App.tasks.add("wait_buy_dialog", function()
        if State.buying_scan.active and State.buying_scan.stage == 'waiting_dialog' then
            stopBuyingScan()
        end
    end, 3000)
end

function processBuyingPage(dialog_text, dialog_id)
    if not State.buying_scan.active then return end
    State.buying_scan.current_dialog_id = dialog_id
    local items_on_page = parseBuyingItems(dialog_text)
    for _, item in ipairs(items_on_page) do table.insert(State.buying_scan.all_items, item) end
    App.tasks.remove_by_name("wait_next_buy_page")
    if dialog_text:find("Следующая страница") then
        State.buying_scan.current_page = State.buying_scan.current_page + 1
        local next_page_index = findNextPageIndex(dialog_text)
        if next_page_index then
            sampSendDialogResponse(dialog_id, 1, next_page_index, "")
            App.tasks.add("wait_next_buy_page", function()
                if State.buying_scan.active then finishBuyingScan() end
            end, 4000)
        else
            finishBuyingScan()
        end
    else
        finishBuyingScan()
    end
end

function findNextPageIndex(text)
    local i = 0
    for line in text:gmatch("[^\r\n]+") do
        if line:find("Следующая страница") then return i end
        i = i + 1
    end
    return nil
end

function parseBuyingItems(text)
    local items = {}
    for line in text:gmatch("[^\r\n]+") do
        if not line:find("Поиск") and not line:find("Следующая страница") and not line:find("Предыдущая страница") and line:find("%[%d+%]$") then
            local item_name, item_index = line:match("(.+)%s+%[(%d+)%]$")
            if not item_name then item_name, item_index = line:match("(.+)%[(%d+)%]$") end
            if item_name and item_index then
                item_name = item_name:gsub("{......}", ""):gsub("%[[%x%x%x%x%x%x%]", ""):gsub("^%s*(.-)%s*$", "%1")
                table.insert(items, {name = item_name, index = tonumber(item_index)})
            end
        end
    end
    return items
end

function finishBuyingScan()
    State.buying_scan.active = false
    App.is_scanning_buy = false
    Data.buyable_items = State.buying_scan.all_items
    local unique_items = {}
    local seen = {}
    for _, item in ipairs(Data.buyable_items) do
        local key = item.name .. "_" .. item.index
        if not seen[key] then
            seen[key] = true
            table.insert(unique_items, item)
        end
    end
    Data.buyable_items = unique_items
    App.tasks.remove_by_name("wait_next_buy_page")
    App.tasks.remove_by_name("wait_buy_items_dialog")
    if State.buying_scan.current_dialog_id then sampSendDialogResponse(State.buying_scan.current_dialog_id, 0, -1, "") end
    saveConfig()
    sampAddChatMessage('[RodinaMarket] {00ff00}Найдено товаров для скупки: ' .. #Data.buyable_items, -1)
    App.win_state[0] = true
end

function stopBuyingScan()
    App.is_scanning_buy = false
    State.buying_scan.active = false
    App.tasks.remove_by_name("wait_buy_dialog")
    App.tasks.remove_by_name("wait_next_buy_page")
    App.tasks.remove_by_name("wait_buy_items_dialog")
    if State.buying_scan.current_dialog_id then sampSendDialogResponse(State.buying_scan.current_dialog_id, 0, -1, "") end
    sampAddChatMessage('[RodinaMarket] {ff0000}Сканирование для скупки прервано!', -1)
end

function startSelling()
    startCEFSelling()
end

function startCEFSelling()
    if App.is_scanning or App.is_selling_cef or App.is_scanning_buy or State.buying.active then return end
    if #Data.sell_list == 0 then
        sampAddChatMessage('[RodinaMarket] {ff0000}Нет товаров для выставления!', -1)
        return
    end
    App.is_selling_cef = true
    Data.cef_slots_data = {}
    Data.cef_sell_queue = {}
    sampAddChatMessage('[RodinaMarket] {ffff00}Начинаю выставление товаров...', -1)
    App.tasks.add("cef_sell_press_alt", function()
        setVirtualKeyDown(0x12, true)
        App.tasks.add("cef_sell_release_alt", function() setVirtualKeyDown(0x12, false) end, 50)
    end, 500)
    App.tasks.add("wait_cef_dialog_failsafe", function()
        if App.is_selling_cef and countTable(Data.cef_slots_data) == 0 then
            log("Ожидание данных CEF или диалога...")
        end
    end, 3000)
end

function prepareCEFSellQueue()
    Data.cef_sell_queue = {}
    local used_slots = {}
    for _, sell_item in ipairs(Data.sell_list) do
        local target_model = tonumber(sell_item.model_id)
        local found_slot = nil
        for slot, item_data in pairs(Data.cef_slots_data) do
            if item_data.model_id == target_model and not used_slots[slot] then
                found_slot = slot
                used_slots[slot] = true
                break
            end
        end
        if found_slot then
            table.insert(Data.cef_sell_queue, {slot=found_slot, model=target_model, amount=sell_item.amount, price=sell_item.price, name=sell_item.name})
        end
    end
    if #Data.cef_sell_queue > 0 then
        sampAddChatMessage('[RodinaMarket] {00ff00}Найдено товаров для продажи: ' .. #Data.cef_sell_queue, -1)
        processNextCEFSellItem()
    else
        sampAddChatMessage('[RodinaMarket] {ff0000}Товары из списка не найдены в инвентаре!', -1)
        App.is_selling_cef = false
        sendCEF("inventoryClose")
    end
end

function processNextCEFSellItem()
    if not App.is_selling_cef then return end
    if #Data.cef_sell_queue == 0 then
        sampAddChatMessage('[RodinaMarket] {00ff00}Все товары выставлены!', -1)
        App.is_selling_cef = false
        App.current_processing_item = nil
        sendCEF("inventoryClose")
        return
    end
    App.current_processing_item = table.remove(Data.cef_sell_queue, 1)
    local payload_click = string.format('clickOnBlock|{"slot": %d, "type": 1}', App.current_processing_item.slot)
    sendCEF(payload_click)
    App.tasks.add("cef_dialog_timeout", function()
        if App.is_selling_cef and App.current_processing_item then
            log("Таймаут ожидания диалога (не прогрузился). Пропуск.")
            processNextCEFSellItem()
        end
    end, 3000)
end

function startBuying()
    if App.is_scanning or App.is_selling_cef or App.is_scanning_buy or State.buying.active then return end
    if #Data.buy_list == 0 then sampAddChatMessage('[RodinaMarket] {ff0000}Нет товаров для скупки!', -1) return end
    State.buying = {active=true, stage='waiting_dialog', current_item_index=1, items_to_buy={}, last_search_name=nil}
    for _, item in ipairs(Data.buy_list) do
        table.insert(State.buying.items_to_buy, {name=item.name, index=item.index, amount=item.amount or 10, price=item.price or 100})
    end
    sampAddChatMessage('[RodinaMarket] {ffff00}Начинаю выставление товаров на скупку...', -1)
    App.tasks.add("buy_press_alt", function()
        setVirtualKeyDown(0x12, true)
        App.tasks.add("buy_release_alt", function() setVirtualKeyDown(0x12, false) end, 50)
    end, 1000)
    App.tasks.add("wait_buy_dialog", function()
        if State.buying.active and State.buying.stage == 'waiting_dialog' then stopBuying() end
    end, 3000)
end

function stopBuying()
    State.buying.active = false
    App.tasks.remove_by_name("wait_buy_dialog")
    App.tasks.remove_by_name("wait_buy_items_dialog")
    App.tasks.remove_by_name("wait_buy_name_dialog")
    App.tasks.remove_by_name("wait_buy_select_dialog")
    App.tasks.remove_by_name("wait_buy_price_dialog")
    App.tasks.remove_by_name("wait_buy_next_item")
    App.tasks.remove_by_name("wait_buy_finish")
    sampAddChatMessage('[RodinaMarket] {ff0000}Выставление товаров на скупку прервано!', -1)
end

function finishBuying()
    State.buying.active = false
    App.tasks.remove_by_name("wait_buy_dialog")
    App.tasks.remove_by_name("wait_buy_items_dialog")
    App.tasks.remove_by_name("wait_buy_name_dialog")
    App.tasks.remove_by_name("wait_buy_select_dialog")
    App.tasks.remove_by_name("wait_buy_price_dialog")
    App.tasks.remove_by_name("wait_buy_next_item")
    App.tasks.remove_by_name("wait_buy_finish")
    sampAddChatMessage('[RodinaMarket] {00ff00}Все товары выставлены на скуп!', -1)
end

function sampGetListboxItemByText(text, plain)
    if not sampIsDialogActive() then return -1 end
    plain = not (plain == false)
    for i = 0, sampGetListboxItemsCount() - 1 do
        if sampGetListboxItemText(i):find(text, 1, plain) then
            return i
        end
    end
    return -1
end

function events.onShowDialog(id, style, title, b1, b2, text)
	if title:find("Ценовая статистика") or title:find("Средние цены") then
        if not State.avg_scan.active then
            -- Если сканирование не запущено скриптом - просто показываем диалог
            return true 
        else
            -- Запускаем поток обработки, чтобы не морозить игру
            lua_thread.create(function()
                -- Ждем пару кадров, чтобы диалог точно прогрузился в память
                wait(10)
                if not sampIsDialogActive() then return end

                local text = sampGetDialogText()
                -- Парсинг цен на текущей странице
                for line in text:gmatch("[^\r\n]+") do
                    if not line:find("Следующая страница") and not line:find("Предыдущая страница") and not line:find("Средняя цена") then
                        -- Пробуем разные форматы строк (иногда TAB-ов разное количество)
                        local item_name, price = line:match("(.+)\t%d+\t(%d+)")
                        if not item_name then item_name, price = line:match("(.+)\t(%d+)") end

                        if item_name and price then
                            updateAveragePrice(item_name, price)
                            State.avg_scan.processed_count = State.avg_scan.processed_count + 1
                        end
                    end
                end

                -- Ищем кнопку "Следующая страница" через память игры (самый надежный способ)
                local next_btn_index = sampGetListboxItemByText("Следующая страница")

                if next_btn_index ~= -1 then
                    -- Если кнопка есть - нажимаем её
                    wait(10) -- Небольшая задержка для стабильности
                    sampSetCurrentDialogListItem(next_btn_index)
                    if sampIsDialogActive() then
                         sampCloseCurrentDialogWithButton(1) -- Нажимаем "Выбрать/Далее"
                    end
                else
                    -- Если кнопки нет - это конец списка
                    State.avg_scan.active = false
                    saveConfig()
                    sampAddChatMessage('[RodinaMarket] {00ff00}Сканирование завершено! Обработано товаров: ' .. State.avg_scan.processed_count, -1)
                    sampCloseCurrentDialogWithButton(0) -- Закрываем диалог
                end
            end)
            
            -- ВАЖНО: Возвращаем true (или ничего), чтобы диалог отобразился. 
            -- Функции sampGetListboxItemByText работают ТОЛЬКО с видимым диалогом.
            -- Скрипт будет листать страницы очень быстро, вы увидите мелькание, но зато это будет работать.
            return nil 
        end
    end
    if App.is_selling_cef and (id == 9 or title:find("Управление лавкой")) then
        sampSendDialogResponse(id, 1, 0, "")
        App.tasks.add("wait_cef_data_after_dialog", function()
            if not App.is_selling_cef then return end
            local attempts = 0
            local function checkData()
                attempts = attempts + 1
                if countTable(Data.cef_slots_data) > 0 then
                    prepareCEFSellQueue()
                else
                    if attempts < 10 then App.tasks.add("retry_cef_check_"..attempts, checkData, 500)
                    else
                        sampAddChatMessage('[RodinaMarket] {ff0000}Данные CEF не получены!', -1)
                        App.is_selling_cef = false
                    end
                end
            end
            checkData()
        end, 1000)
        return false
    end
    if State.buying.active then
        App.tasks.remove_by_name("wait_buy_dialog")
        App.tasks.remove_by_name("wait_buy_items_dialog")
        App.tasks.remove_by_name("wait_buy_name_dialog")
        App.tasks.remove_by_name("wait_buy_select_dialog")
        App.tasks.remove_by_name("wait_buy_price_dialog")
        App.tasks.remove_by_name("wait_buy_next_item")
        App.tasks.remove_by_name("wait_buy_finish")
        if State.buying.stage == 'waiting_dialog' and title:find("Управление лавкой") then
            State.buying.stage = 'waiting_items'
            sampSendDialogResponse(id, 1, 1, "")
            App.tasks.add("wait_buy_items_dialog", function()
                if State.buying.active and State.buying.stage == 'waiting_items' then stopBuying() end
            end, 5000)
            return false
        end
        if (id == 10 or (title:find("Скупка") and text:find("Поиск предмета по названию"))) then
            if State.buying.stage == 'finishing' then
                sampSendDialogResponse(id, 0, -1, "")
                return false
            end
            if State.buying.stage == 'waiting_items' then
                State.buying.stage = 'waiting_name_input'
                sampSendDialogResponse(id, 1, 0, "")
                App.tasks.add("wait_buy_name_dialog", function()
                    if State.buying.active and State.buying.stage == 'waiting_name_input' then stopBuying() end
                end, 5000)
                return false
            end
        end
        if State.buying.stage == 'waiting_name_input' and title:find("Поиск предмета для скупки") then
            local current_item = State.buying.items_to_buy[State.buying.current_item_index]
            if current_item then
                State.buying.last_search_name = current_item.name
                State.buying.stage = 'waiting_select'
                sampSendDialogResponse(id, 1, -1, current_item.name)
                App.tasks.add("wait_buy_select_dialog", function()
                    if State.buying.active and State.buying.stage == 'waiting_select' then stopBuying() end
                end, 5000)
            end
            return false
        end
        if State.buying.stage == 'waiting_select' and title:find("Скупка") and text then
            local current_item = State.buying.items_to_buy[State.buying.current_item_index]
            if current_item and State.buying.last_search_name then
                local found_index = -1
                local search_name_lower = State.buying.last_search_name:lower()
                local lines = {}
                for line in text:gmatch("[^\r\n]+") do table.insert(lines, line) end
                for i, line in ipairs(lines) do
                    local clean_line = line:gsub("%[%x%x%x%x%x%x%]", ""):gsub("{......}", ""):gsub("^%s*(.-)%s*$", "%1"):lower()
                    if clean_line:find(search_name_lower, 1, true) then found_index = i - 1 break end
                end
                if found_index == -1 and #lines > 0 then found_index = 0 end
                State.buying.stage = 'waiting_price_input'
                sampSendDialogResponse(id, 1, found_index, "")
                App.tasks.add("wait_buy_price_dialog", function()
                    if State.buying.active and State.buying.stage == 'waiting_price_input' then stopBuying() end
                end, 5000)
            end
            return false
        end
        if State.buying.stage == 'waiting_price_input' and title:find("Скупка") and text then
            local current_item = State.buying.items_to_buy[State.buying.current_item_index]
            if current_item then
                local input = ""
                if text:find("Укажите количество товара") then
                    input = string.format("%d,%d", current_item.amount, current_item.price)
                elseif text:find("Укажите цену и цвет") then
                    input = string.format("%d,%d", current_item.price, 0)
                end
                if input ~= "" then
                    sampSendDialogResponse(id, 1, -1, input)
                    State.buying.current_item_index = State.buying.current_item_index + 1
                    if State.buying.current_item_index <= #State.buying.items_to_buy then
                        State.buying.stage = 'waiting_items'
                        App.tasks.add("wait_buy_items_dialog", function()
                            if State.buying.active then stopBuying() end
                        end, 5000)
                    else
                        State.buying.stage = 'finishing'
                        App.tasks.add("wait_buy_finish", function()
                            finishBuying()
                        end, 5000)
                    end
                end
            end
            return false
        end
        if State.buying.stage == 'finishing' and title:find("Управление лавкой") then
            sampSendDialogResponse(id, 0, -1, "")
            finishBuying()
            return false
        end
    end
    if State.buying_scan.active then
        App.tasks.remove_by_name("wait_buy_dialog")
        App.tasks.remove_by_name("wait_buy_items_dialog")
        App.tasks.remove_by_name("wait_next_buy_page")
        App.tasks.remove_by_name("wait_category_menu")
        App.tasks.remove_by_name("wait_full_list_menu")
        if State.buying_scan.stage == 'waiting_dialog' and title:find("Управление лавкой") then
            State.buying_scan.stage = 'waiting_category_menu'
            sampSendDialogResponse(id, 1, 1, "")
            App.tasks.add("wait_category_menu", function()
                if State.buying_scan.active and State.buying_scan.stage == 'waiting_category_menu' then stopBuyingScan() end
            end, 5000)
        end
        if State.buying_scan.stage == 'waiting_category_menu' and (id == 10 and title:find("Скупка:")) then
            State.buying_scan.stage = 'waiting_full_list_menu'
            sampSendDialogResponse(id, 1, 1, "")
            App.tasks.add("wait_full_list_menu", function()
                if State.buying_scan.active and State.buying_scan.stage == 'waiting_full_list_menu' then stopBuyingScan() end
            end, 5000)
        end
        if State.buying_scan.stage == 'waiting_full_list_menu' and (id == 911 and title:find("Категории для поиска")) then
            State.buying_scan.stage = 'processing_page'
            local found_index = -1
            local lines = {}
            for line in text:gmatch("[^\r\n]+") do table.insert(lines, line) end
            for i, line in ipairs(lines) do
                if line:find("Весь список") then
                    found_index = i - 1
                    break
                end
            end
            if found_index ~= -1 then
                sampSendDialogResponse(id, 1, found_index, "")
            else
                sampAddChatMessage('[RodinaMarket] {ff0000}Ошибка: Не найдена опция "Весь список" в категориях.', -1)
                stopBuyingScan()
            end
            App.tasks.add("wait_buy_items_dialog", function()
                if State.buying_scan.active and State.buying_scan.stage == 'processing_page' then stopBuyingScan() end
            end, 5000)
        end
        if State.buying_scan.stage == 'processing_page' and title:find("Скупка:") then
            State.buying_scan.current_dialog_id = id
            processBuyingPage(text, id)
        end
    end
    return true
end

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    loadConfigData()
    applyStrictStyle()
    local io = imgui.GetIO()
    io.Fonts:Clear()
    local font_config = imgui.ImFontConfig()
    font_config.MergeMode = false
    font_config.PixelSnapH = true
    local font_path = getFolderPath(0x14) .. '\\trebucbd.ttf'
    if not doesFileExist(font_path) then font_path = getFolderPath(0x14) .. '\\arialbd.ttf' end
    local font_main = io.Fonts:AddFontFromFileTTF(font_path, 14 * SCALE, font_config, io.Fonts:GetGlyphRangesCyrillic())
    local icon_config = imgui.ImFontConfig()
    icon_config.MergeMode = true
    icon_config.PixelSnapH = true
    icon_config.GlyphOffset = imgui.ImVec2(0, 2 * SCALE)
    local iconRanges = imgui.new.ImWchar[3](fa.min_range, fa.max_range, 0)
    io.Fonts:AddFontFromMemoryCompressedBase85TTF(fa.get_font_data_base85('solid'), 14 * SCALE, icon_config, iconRanges)
    io.Fonts:Build()
end)

function applyStrictStyle()
    local style = imgui.GetStyle()
    local colors = style.Colors
    style.WindowRounding = 4.0 * SCALE
    style.ChildRounding = 4.0 * SCALE
    style.FrameRounding = 4.0 * SCALE
    style.PopupRounding = 4.0 * SCALE
    style.GrabRounding = 3.0 * SCALE
    style.ScrollbarRounding = 9.0 * SCALE
    style.TabRounding = 4.0 * SCALE
    style.WindowPadding = imgui.ImVec2(15 * SCALE, 15 * SCALE)
    style.FramePadding = imgui.ImVec2(12 * SCALE, 8 * SCALE)
    style.ItemSpacing = imgui.ImVec2(10 * SCALE, 8 * SCALE)
    style.ScrollbarSize = 16 * SCALE
    style.IndentSpacing = 20 * SCALE
    style.WindowBorderSize = 0
    style.ChildBorderSize = 1
    style.PopupBorderSize = 1
    style.FrameBorderSize = 0
    local bg_dark = imgui.ImVec4(0.10, 0.10, 0.11, 1.00)
    local bg_light = imgui.ImVec4(0.16, 0.16, 0.17, 1.00)
    local accent = imgui.ImVec4(0.85, 0.25, 0.25, 1.00)
    local accent_hover = imgui.ImVec4(0.95, 0.35, 0.35, 1.00)
    local accent_active = imgui.ImVec4(1.00, 0.40, 0.40, 1.00)
    colors[imgui.Col.WindowBg] = bg_dark
    colors[imgui.Col.ChildBg] = bg_light
    colors[imgui.Col.PopupBg] = imgui.ImVec4(0.14, 0.14, 0.15, 1.00)
    colors[imgui.Col.Border] = imgui.ImVec4(0.25, 0.25, 0.26, 1.00)
    colors[imgui.Col.FrameBg] = imgui.ImVec4(0.06, 0.06, 0.07, 1.00)
    colors[imgui.Col.FrameBgHovered] = imgui.ImVec4(0.12, 0.12, 0.13, 1.00)
    colors[imgui.Col.FrameBgActive] = imgui.ImVec4(0.20, 0.20, 0.20, 1.00)
    colors[imgui.Col.TitleBg] = bg_dark
    colors[imgui.Col.TitleBgActive] = bg_dark
    colors[imgui.Col.Button] = imgui.ImVec4(0.22, 0.22, 0.23, 1.00)
    colors[imgui.Col.ButtonHovered] = accent_hover
    colors[imgui.Col.ButtonActive] = accent_active
    colors[imgui.Col.CheckMark] = accent
    colors[imgui.Col.SliderGrab] = accent
    colors[imgui.Col.SliderGrabActive] = accent_active
    colors[imgui.Col.Header] = imgui.ImVec4(accent.x, accent.y, accent.z, 0.5)
    colors[imgui.Col.HeaderHovered] = accent_hover
    colors[imgui.Col.HeaderActive] = accent_active
    colors[imgui.Col.Text] = imgui.ImVec4(0.92, 0.92, 0.94, 1.00)
    colors[imgui.Col.TextDisabled] = imgui.ImVec4(0.50, 0.50, 0.55, 1.00)
end

function renderTooltip(text)
    if imgui.IsItemHovered() then
        imgui.BeginTooltip()
        imgui.Text(u8(text))
        imgui.EndTooltip()
    end
end

function IconButtonCentered(id, icon, size, tooltip)
    local draw = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    if imgui.InvisibleButton("##iconbtn_" .. tostring(id), size) then return true end
    local min = imgui.GetItemRectMin()
    local max = imgui.GetItemRectMax()
    local col = imgui.GetColorU32(imgui.Col.Button)
    if imgui.IsItemActive() then col = imgui.GetColorU32(imgui.Col.ButtonActive)
    elseif imgui.IsItemHovered() then col = imgui.GetColorU32(imgui.Col.ButtonHovered) end
    draw:AddRectFilled(min, max, col, 0)
    local text_size = imgui.CalcTextSize(icon)
    local text_pos = imgui.ImVec2(min.x + (size.x - text_size.x) * 0.5, min.y + (size.y - text_size.y) * 0.5)
    draw:AddText(text_pos, imgui.GetColorU32(imgui.Col.Text), icon)
    if tooltip and imgui.IsItemHovered() then imgui.SetTooltip(u8(tooltip)) end
    return false
end

function renderHeaderSearch(buf, width)
    imgui.SetNextItemWidth(width)
    imgui.InputTextWithHint("##buy_search", u8"Поиск товара...", buf, ffi.sizeof(buf))
end

function renderSellItem(index, item)
    imgui.PushIDInt(index)
    local display_name = item.name
    if item.model_id then display_name = display_name .. " (ID: " .. item.model_id .. ")" end
    imgui.Text(u8(index .. '. ' .. display_name))
    imgui.PushItemWidth(100)
    local buf_key_price = "p_" .. index
    local buf_key_amount = "a_" .. index
    if not Buffers.input_buffers[buf_key_price] then Buffers.input_buffers[buf_key_price] = imgui.new.int(item.price or 0) end
    if not Buffers.input_buffers[buf_key_amount] then Buffers.input_buffers[buf_key_amount] = imgui.new.int(item.amount or 1) end
    local price_changed = false
    if imgui.InputInt("##price", Buffers.input_buffers[buf_key_price], 0) then
        price_changed = true
    end
    if imgui.IsItemDeactivatedAfterEdit() and price_changed then
        item.price = Buffers.input_buffers[buf_key_price][0]
        saveConfig()
        price_changed = false
    end
    renderTooltip("Цена за шт.")
    imgui.SameLine()
    local amount_changed = false
    if imgui.InputInt("##amount", Buffers.input_buffers[buf_key_amount], 0) then
        amount_changed = true
    end
    if imgui.IsItemDeactivatedAfterEdit() and amount_changed then
        item.amount = Buffers.input_buffers[buf_key_amount][0]
        saveConfig()
        amount_changed = false
    end
    renderTooltip("Количество")
    imgui.PopItemWidth()

    -- [НОВАЯ ЧАСТЬ] Всплывающее окно со средней ценой при наведении на строку
    -- Мы проверяем, наведен ли курсор на любой элемент в этой строке (группе)
    if imgui.IsItemHovered() then
        local clean_name = item.name:gsub("{......}", ""):gsub("^%s*(.-)%s*$", "%1")
        local avg_data = Data.average_prices[clean_name]
        
        if avg_data then
            imgui.BeginTooltip()
            imgui.TextColored(imgui.ImVec4(1, 0.8, 0, 1), u8("Средняя цена (сканер):"))
            imgui.Text(u8("Цена: " .. formatMoney(avg_data.price) .. " руб."))
            imgui.TextColored(imgui.ImVec4(0.7, 0.7, 0.7, 1), u8("Записей: " .. avg_data.count))
            imgui.EndTooltip()
        else
            -- Можно раскомментировать, если хотите видеть подсказку, что данных нет
            imgui.SetTooltip(u8("Нет данных о средней цене"))
        end
    end
    -- [КОНЕЦ НОВОЙ ЧАСТИ]

    imgui.SameLine()
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.6, 0.2, 0.2, 1.0))
    if imgui.Button(fa('trash')) then
        table.remove(Data.sell_list, index)
        Buffers.input_buffers[buf_key_price] = nil
        Buffers.input_buffers[buf_key_amount] = nil
        saveConfig()
    end
    imgui.PopStyleColor()
    imgui.Separator()
    imgui.PopID()
end

function stringToID(str)
    local hash = 0
    for i = 1, #str do hash = (hash * 31 + str:byte(i)) % 2147483647 end
    return hash
end

function renderBuyItem(index, item)
    imgui.PushIDInt(stringToID("buy_" .. index))
    local buf_key_price = "bp_" .. index
    local buf_key_amount = "ba_" .. index
    if not Buffers.buy_input_buffers[buf_key_price] then
        Buffers.buy_input_buffers[buf_key_price] = imgui.new.char[32]()
        ffi.copy(Buffers.buy_input_buffers[buf_key_price], tostring(item.price or 100))
    end
    if not Buffers.buy_input_buffers[buf_key_amount] then
        Buffers.buy_input_buffers[buf_key_amount] = imgui.new.char[32]()
        ffi.copy(Buffers.buy_input_buffers[buf_key_amount], tostring(item.amount or 10))
    end
    local display_name = tostring(index) .. '. ' .. item.name
    if item.index then display_name = display_name .. " (ID: " .. item.index .. ")" end
    imgui.Text(u8(display_name))
    imgui.PushItemWidth(80)
    local price_changed = false
    if imgui.InputText("##buy_price", Buffers.buy_input_buffers[buf_key_price], 32, imgui.InputTextFlags.CharsDecimal) then
        price_changed = true
    end
    if imgui.IsItemDeactivatedAfterEdit() and price_changed then
        local price_str = ffi.string(Buffers.buy_input_buffers[buf_key_price])
        item.price = tonumber(price_str) or 100
        saveConfig()
        price_changed = false
    end
    if imgui.IsItemHovered() then imgui.SetTooltip(u8"Цена за шт.") end
    imgui.SameLine()
    local amount_changed = false
    if imgui.InputText("##buy_amount", Buffers.buy_input_buffers[buf_key_amount], 32, imgui.InputTextFlags.CharsDecimal) then
        amount_changed = true
    end
    if imgui.IsItemDeactivatedAfterEdit() and amount_changed then
        local amount_str = ffi.string(Buffers.buy_input_buffers[buf_key_amount])
        item.amount = tonumber(amount_str) or 10
        saveConfig()
        amount_changed = false
    end
    if imgui.IsItemHovered() then imgui.SetTooltip(u8"Макс. кол-во") end
    imgui.PopItemWidth()
    imgui.SameLine()
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.6, 0.2, 0.2, 1.0))
    if imgui.Button(fa('trash')) then
        table.remove(Data.buy_list, index)
        Buffers.buy_input_buffers[buf_key_price] = nil
        Buffers.buy_input_buffers[buf_key_amount] = nil
        saveConfig()
    end
    imgui.PopStyleColor()
    imgui.Separator()
    imgui.PopID()
end

function parseCEFInventory(str)
    str = str:gsub("`", ""):gsub("^%s+", ""):gsub("%s+$", "")
    local json_start = str:find("%[")
    if not json_start then
        local match = str:match("event%.inventory%.playerInventory.*%[")
        if match then json_start = str:find("%[", #match) end
    end
    if not json_start then return end
    if str:find("Введите цену за один товар") then
        App.cef_price_only = true
    else
        App.cef_price_only = false
    end
    local bracket_count = 0
    local json_end = nil
    for i = json_start, #str do
        local char = str:sub(i, i)
        if char == "[" then bracket_count = bracket_count + 1
        elseif char == "]" then bracket_count = bracket_count - 1
            if bracket_count == 0 then json_end = i break end
        end
    end
    if not json_end then return end
    local json_str = str:sub(json_start, json_end):gsub("%c", "")
    local status, data = pcall(json.decode, json_str)
    if not status or not data then return end
    for _, event_data in ipairs(data) do
        if (event_data.action == 2 or event_data.action == 0) and event_data.data and event_data.data.items then
            for _, item in ipairs(event_data.data.items) do
                if item.item then
                    local item_id = tostring(item.item)
                    local item_slot = item.slot
                    Data.cef_slots_data[item_slot] = {model_id=item.item, slot=item_slot, amount=item.amount or 1}
                    if Data.item_names[item_id] then
                        Data.cef_inventory_items[item_id] = {name=Data.item_names[item_id], model_id=item.item, slot=item_slot}
                    end
                end
            end
        end
    end
end

function renderCustomHeader()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetWindowWidth()
    local h = S(50)
    local draw_list = imgui.GetWindowDrawList()
    local header_bg = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.08, 0.08, 0.09, 1.00))
    local accent_color = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.85, 0.25, 0.25, 1.00))
    local text_white = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.95, 0.95, 0.95, 1.00))
    local update_color = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1.0, 0.5, 0.0, 1.00))
    
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), header_bg)
    draw_list:AddLine(imgui.ImVec2(p.x, p.y + h), imgui.ImVec2(p.x + w, p.y + h), accent_color, S(1.5))
    
    local icon = fa('shop')
    local title = "Rodina Market"
    local text_offset_x = S(20)
    local text_pos_y = p.y + (h - imgui.GetFontSize()) / 2
    
    -- Индикатор обновления скрипта
    if App.update_available then
        local update_icon = fa('arrow_up')
        local update_icon_size = imgui.CalcTextSize(update_icon)
        draw_list:AddText(imgui.ImVec2(p.x + text_offset_x, text_pos_y), update_color, update_icon)
        text_offset_x = text_offset_x + update_icon_size.x + S(5)
    end
    
    draw_list:AddText(imgui.ImVec2(p.x + text_offset_x, text_pos_y), accent_color, icon)
    draw_list:AddText(imgui.ImVec2(p.x + text_offset_x + S(30), text_pos_y), text_white, title)
    
    -- Индикатор обновления items.json
    if App.items_update_available then
        local items_update_icon = fa('download')
        local items_icon_pos = imgui.ImVec2(p.x + w - S(80), text_pos_y)
        draw_list:AddText(items_icon_pos, update_color, items_update_icon)
    end
    
    local btn_size = h
    local close_p = imgui.ImVec2(p.x + w - btn_size, p.y)
    imgui.SetCursorScreenPos(close_p)
    if imgui.InvisibleButton("##close_app", imgui.ImVec2(btn_size, btn_size)) then
        App.win_state[0] = false
    end
    if imgui.IsItemHovered() then
        local close_bg = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.8, 0.15, 0.15, 1.00))
        draw_list:AddRectFilled(close_p, imgui.ImVec2(close_p.x + btn_size, close_p.y + btn_size), close_bg)
    end
    local close_icon = fa('xmark')
    local icon_size = imgui.CalcTextSize(close_icon)
    draw_list:AddText(imgui.ImVec2(close_p.x + (btn_size - icon_size.x)/2, close_p.y + (btn_size - icon_size.y)/2), text_white, close_icon)
    
    imgui.SetCursorScreenPos(p)
    if imgui.InvisibleButton("##drag_area", imgui.ImVec2(w - btn_size, h)) then end
    if imgui.IsItemActive() and imgui.IsMouseDragging(0) then
        local delta = imgui.GetMouseDragDelta(0)
        local win_pos = imgui.GetWindowPos()
        imgui.SetWindowPosVec2(imgui.ImVec2(win_pos.x + delta.x, win_pos.y + delta.y))
        imgui.ResetMouseDragDelta(0)
    end
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + h + S(5)))
end

function RenderSidebarItem(label, icon, active, size)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    local clicked = imgui.InvisibleButton("##side_"..label, size)
    local hovered = imgui.IsItemHovered()
    local is_active_or_hovered = active or hovered
    local bg_col = 0
    if active then
        bg_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.18, 0.18, 0.20, 1.00))
    elseif hovered then
        bg_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.14, 0.14, 0.15, 1.00))
    end
    local text_col = active and 0xFFFFFFFF or imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.60, 0.60, 0.65, 1.00))
    local accent_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.85, 0.25, 0.25, 1.00))
    if is_active_or_hovered then
        draw_list:AddRectFilled(p, imgui.ImVec2(p.x + size.x, p.y + size.y), bg_col, S(5.0))
    end
    if active then
        draw_list:AddRectFilled(imgui.ImVec2(p.x, p.y + S(8)), imgui.ImVec2(p.x + S(4), p.y + size.y - S(8)), accent_col, S(2.0))
    end
    local icon_offset_x = S(15)
    local icon_size = imgui.CalcTextSize(icon)
    draw_list:AddText(imgui.ImVec2(p.x + icon_offset_x, p.y + (size.y - icon_size.y) / 2), active and accent_col or text_col, icon)
    local label_offset_x = S(45)
    local label_size = imgui.CalcTextSize(label)
    draw_list:AddText(imgui.ImVec2(p.x + label_offset_x, p.y + (size.y - label_size.y) / 2), text_col, label)
    return clicked
end

function RenderCardHeader(text, icon, color_bg, color_accent)
    local draw_list = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    local h = 35
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), color_bg, 3.0, 1 + 2)
    draw_list:AddRectFilled(imgui.ImVec2(p.x, p.y + h - 2), imgui.ImVec2(p.x + w, p.y + h), color_accent)
    local icon_size = imgui.CalcTextSize(icon)
    draw_list:AddText(imgui.ImVec2(p.x + 10, p.y + (h - icon_size.y) / 2), color_accent, icon)
    imgui.SetCursorPos(imgui.ImVec2(imgui.GetCursorPosX() + 35, imgui.GetCursorPosY() + (h - imgui.GetFontSize())/2))
    imgui.TextColored(imgui.ImVec4(1,1,1,1), text)
    imgui.SetCursorPosY(imgui.GetCursorPosY() + h/2 + 5)
end

function RenderListRow(index, height, callback)
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    local draw_list = imgui.GetWindowDrawList()
    if index % 2 == 0 then
        draw_list:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + height), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.03)))
    end
    imgui.PushIDInt(index)
    local hovered = false
    imgui.BeginGroup()
        callback()
    imgui.EndGroup()
    if imgui.IsItemHovered() then
        draw_list:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + height), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.05)))
    end
    imgui.PopID()
end

function RenderCompactInput(label, buf, width)
    imgui.PushItemWidth(width)
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(5, 2))
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0.08, 0.08, 0.08, 1.0))
    local changed = imgui.InputText("##"..label, buf, 32, imgui.InputTextFlags.CharsDecimal)
    imgui.PopStyleColor()
    imgui.PopStyleVar()
    imgui.PopItemWidth()
    return changed
end

imgui.OnFrame(function() return App.win_state[0] end, function(player)
    imgui.SetNextWindowSize(imgui.ImVec2(sw * 0.8, sh * 0.9), imgui.Cond.FirstUseEver)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    if imgui.Begin("Rodina Market", App.win_state, imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize) then
        renderCustomHeader()
        
        -- Панель обновлений (если есть)
        if App.update_available or App.items_update_available then
            imgui.BeginChild("UpdatesPanel", imgui.ImVec2(0, S(60)), true)
            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.2, 0.15, 0.1, 0.8))
            
            if App.update_available and App.update_info then
                imgui.TextColored(imgui.ImVec4(1, 0.5, 0, 1), u8("Доступно обновление скрипта v" .. App.update_info.version))
                imgui.SameLine()
                if imgui.Button(u8("Скачать"), imgui.ImVec2(S(80), S(20))) then
                    downloadScriptUpdate()
                end
                imgui.SameLine()
                if imgui.Button(u8("Пропустить"), imgui.ImVec2(S(80), S(20))) then
                    App.update_available = false
                end
            end
            
            if App.items_update_available then
                imgui.TextColored(imgui.ImVec4(1, 0.5, 0, 1), u8("items.json обновлен до v" .. App.items_update_info.version))
                imgui.SameLine()
                imgui.Text(u8("(автоматически скачан)"))
            end
            
            imgui.PopStyleColor()
            imgui.EndChild()
        end
        
        -- Остальной интерфейс без изменений
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
        imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, 0))
        
        local sidebar_width = 180
        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.10, 0.10, 0.10, 1.00))
        imgui.BeginChild("Sidebar", imgui.ImVec2(sidebar_width, 0), true)
            imgui.Dummy(imgui.ImVec2(0, 10))
            imgui.SetCursorPosX(10)
            
            if RenderSidebarItem(u8"Продажа", fa('shop'), App.active_tab == 1, imgui.ImVec2(sidebar_width - 20, 45)) then
                App.active_tab = 1
            end
            imgui.Dummy(imgui.ImVec2(0, 5))
            
            if RenderSidebarItem(u8"Скупка", fa('hand_holding_dollar'), App.active_tab == 2, imgui.ImVec2(sidebar_width - 20, 45)) then
                App.active_tab = 2
            end
            imgui.Dummy(imgui.ImVec2(0, 5))
            
            if RenderSidebarItem(u8"Логи", fa('file_lines'), App.active_tab == 3, imgui.ImVec2(sidebar_width - 20, 45)) then
                App.active_tab = 3
            end
            
        imgui.EndChild()
        imgui.PopStyleColor()
        imgui.SameLine()
        
        imgui.BeginGroup()
            imgui.Dummy(imgui.ImVec2(0, 10))
            imgui.Indent(15)
            imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(8, 6))
            local content_avail_w = imgui.GetContentRegionAvail().x - 15
            
            imgui.BeginChild("ContentRegion", imgui.ImVec2(content_avail_w, 0), false)
            
            -- Вкладка обновлений
            if App.active_tab == 1 then
                imgui.BeginChild("Header", imgui.ImVec2(0, 50), true)
                    imgui.SetCursorPos(imgui.ImVec2(10, 10))
                    if IconButtonCentered("scan_inv", fa('magnifying_glass'), imgui.ImVec2(35, 30), "Сканировать") then
                        App.win_state[0] = false
                        startScanning()
                    end
                    imgui.SameLine()
                    if IconButtonCentered("reload", fa('file_arrow_up'), imgui.ImVec2(35,30), "Перезагрузить конфиг") then
                        loadConfigData()
                        sampAddChatMessage("[RodinaMarket] Конфиг перезагружен.", -1)
                    end
                    imgui.SameLine()
                    if IconButtonCentered("sell", fa('shop'), imgui.ImVec2(35,30), "Выставить товары") then
                        App.win_state[0] = false
                        startSelling()
                    end
					imgui.SameLine()
					if IconButtonCentered("scan_avg", fa('chart_line'), imgui.ImVec2(35, 30), "Сканировать ср. цены (у пикапа)") then
						 App.win_state[0] = false -- Закрываем окно скрипта
						 startAvgPriceScan() -- Запускаем функцию подготовки
					end
                    local avail_w = imgui.GetContentRegionAvail().x
                    imgui.SameLine(avail_w - 250)
                    renderModernSearchBar(Buffers.sell_search, "Поиск предмета...", 250)
                imgui.EndChild()
                imgui.Columns(2, "SellColumns", true)
                local filtered_scanned = getFilteredItems(Data.scanned_items, Buffers.sell_search, "sell_search_result", "last_sell_query")
                imgui.TextColored(imgui.ImVec4(1, 1, 0, 1), u8("Найденные товары (" .. #filtered_scanned .. ")"))
                imgui.BeginChild("InventoryList", imgui.ImVec2(0, 0), true)
                    if #filtered_scanned == 0 then
                        if #Data.scanned_items == 0 then imgui.TextWrapped(u8("Пусто. Сканируйте инвентарь."))
                        else imgui.TextWrapped(u8("Ничего не найдено.")) end
                    else
                        for i, item in ipairs(filtered_scanned) do
                            local display_text = i .. ". " .. item.name
                            if item.model_id then display_text = display_text .. " (ID: " .. item.model_id .. ")" end
                            if imgui.Selectable(u8(display_text), false) then
                                table.insert(Data.sell_list, {name = item.name, price = 1000, amount = 1, model_id = item.model_id})
                                saveConfig()
                            end
                        end
                    end
                imgui.EndChild()
                imgui.NextColumn()
                imgui.TextColored(imgui.ImVec4(0, 1, 0, 1), u8("Список на продажу (" .. #Data.sell_list .. ")"))
                imgui.BeginChild("SellList", imgui.ImVec2(0, 0), true)
                    if #Data.sell_list == 0 then imgui.TextWrapped(u8("Список пуст."))
                    else for i, item in ipairs(Data.sell_list) do renderSellItem(i, item) end end
                imgui.EndChild()
                imgui.Columns(1)
            elseif App.active_tab == 2 then
                local avail_size = imgui.GetContentRegionAvail()
                imgui.BeginChild("HeaderBuy", imgui.ImVec2(0, 50), false)
                imgui.SetCursorPos(imgui.ImVec2(10, 10))
                if IconButtonCentered("buy_scan", fa('magnifying_glass'), imgui.ImVec2(32,32), "Сканировать товары") then
                    App.win_state[0] = false
                    startBuyingScan()
                end
                imgui.SameLine()
                if IconButtonCentered("buy_reload", fa('file_arrow_up'), imgui.ImVec2(32,32), "Перезагрузить конфиг") then
                    loadConfigData()
                    sampAddChatMessage("[RodinaMarket] Конфиг перезагружен.", -1)
                end
                imgui.SameLine()
                if IconButtonCentered("buy_start", fa('shop'), imgui.ImVec2(32,32), "Выставить на скупку") then
                    App.win_state[0] = false
                    startBuying()
                end
                local search_width = 250
                imgui.SetCursorPos(imgui.ImVec2(avail_size.x - search_width - 10, 8))
                renderModernSearchBar(Buffers.buy_search, "Поиск товара...", search_width)
                imgui.EndChild()
                imgui.Separator()
                local remaining_height = avail_size.y - 50 - 6
                imgui.Columns(2, "BuyColumns", false)
                imgui.SetColumnWidth(0, avail_size.x * 0.5)
                imgui.BeginChild("BuyableList", imgui.ImVec2(0, remaining_height), true)
                local filtered = filterList(Data.buyable_items, Buffers.buy_search)
                local total = #filtered
                if total == 0 then
                    if #Data.buyable_items == 0 then imgui.TextWrapped(u8("Пусто. Нажмите лупу для сканирования."))
                    else imgui.TextWrapped(u8("Ничего не найдено.")) end
                else
                    imgui.BeginChild("BuyableScroll", imgui.ImVec2(0, 0), false)
                    local content_height = total * 25
                    handleSmoothScroll(content_height)
                    local scroll_y = imgui.GetScrollY()
                    local window_height = imgui.GetWindowHeight()
                    local items_per_screen = math.ceil(window_height / 25) + 2
                    local first = math.floor(scroll_y / 25)
                    if first < 0 then first = 0 end
                    local last = first + items_per_screen
                    if last > total then last = total end
                    imgui.Dummy(imgui.ImVec2(0, first * 25))
                    for i = first + 1, last do
                        local item = filtered[i]
                        imgui.PushIDInt(stringToID(i .. "_" .. (item.index or 0)))
                        local text = tostring(i) .. ". " .. item.name
                        if item.index then text = text .. " [ID: " .. item.index .. "]" end
                        if imgui.Selectable(u8(text), false, imgui.SelectableFlags.None, imgui.ImVec2(0, 25)) then
                            table.insert(Data.buy_list, {name = item.name, price = 100, amount = 10, index = item.index})
                            saveConfig()
                        end
                        imgui.PopID()
                    end
                    local remaining = content_height - last * 25
                    if remaining > 0 then imgui.Dummy(imgui.ImVec2(0, remaining)) end
                    imgui.EndChild()
                end
                imgui.EndChild()
                imgui.NextColumn()
                imgui.BeginChild("BuyList", imgui.ImVec2(0, remaining_height), true)
                if #Data.buy_list == 0 then imgui.TextWrapped(u8("Список пуст. Выберите товары слева."))
                else
                    imgui.BeginChild("BuyListScroll", imgui.ImVec2(0, 0), true)
                    for i, item in ipairs(Data.buy_list) do renderBuyItem(i, item) end
                    imgui.EndChild()
                end
                imgui.EndChild()
                imgui.Columns(1)
            elseif App.active_tab == 3 then
                renderLogsTab()
            end
            imgui.EndChild()
            imgui.PopStyleVar()
            imgui.Unindent(15)
        imgui.EndGroup()
        imgui.PopStyleVar(2)
    end
    imgui.End()
    imgui.PopStyleVar()
end)

function main()
    while not isSampAvailable() do wait(100) end
    
    -- Регистрируем команды
    sampRegisterChatCommand('rmenu', function() App.win_state[0] = not App.win_state[0] end)
    
    -- Загружаем данные
    loadConfigData()
    loadItemNames()
    
    sampAddChatMessage('[RodinaMarket] {00ff00}Загружен! v' .. SCRIPT_VERSION, -1)
    sampAddChatMessage('[RodinaMarket] {ffff00}Введите {FF0000}/rmenu {FFFF00}для открытия меню', -1)
    
    -- Оригинальный обработчик пакетов и основной цикл
    addEventHandler('onReceivePacket', function(id, bs)
        if id == 220 and (App.is_scanning or App.is_selling_cef) then
            local packet_id = raknetBitStreamReadInt8(bs)
            local packet_type = raknetBitStreamReadInt8(bs)
            if packet_type == 17 then
                raknetBitStreamIgnoreBits(bs, 32)
                local length = raknetBitStreamReadInt16(bs)
                local encoded = raknetBitStreamReadInt8(bs)
                local str
                if encoded ~= 0 then str = raknetBitStreamDecodeString(bs, length + encoded)
                else str = raknetBitStreamReadString(bs, length) end
                if not str then return end
                if (App.is_scanning or App.is_selling_cef) and (str:find("event%.inventory%.playerInventory") or str:find("%[%s*{%s*\"action\"")) then
                    parseCEFInventory(str)
                end
                if App.is_selling_cef and App.current_processing_item and str:find("cef%.modals%.showModal") then
                    local json_candidate = str:match("(%[.*%])")
                    if json_candidate then
                        local status, data = pcall(json.decode, json_candidate)
                        if status and data and data[2] and data[2].id == 240 then
                            App.tasks.remove_by_name("cef_dialog_timeout")
                            local body_text = data[2].body or ""
                            local payload_response
                            if body_text:find("Введите цену за один товар") then
                                payload_response = string.format("sendResponse|240|0|1|%d", App.current_processing_item.price)
                                log("Режим продажи: Только цена (Авто)")
                            else
                                payload_response = string.format("sendResponse|240|0|1|%d,%d", App.current_processing_item.amount, App.current_processing_item.price)
                                log("Режим продажи: Кол-во + Цена (Авто)")
                            end
                            sendCEF(payload_response)
                            App.tasks.add("cef_next_item_delay", processNextCEFSellItem, 800)
                        end
                    end
                end
            end
        end
    end)
    while true do wait(0) App.tasks.process() end
end