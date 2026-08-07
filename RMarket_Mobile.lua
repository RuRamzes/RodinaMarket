script_name("RMarket Mobile")
script_version("1.4")

require 'lib.moonloader'
local imgui = require 'mimgui'
local ffi = require 'ffi'
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local fa = require 'fAwesome6'
local lfs = require 'lfs'
local cjson = require 'cjson'
local raknet = require 'lib.samp.raknet'
local events = require 'lib.samp.events'
local effil = require 'effil'

search_thread_1 = nil
search_thread_4 = nil
market_search_results_sell = {}
market_search_results_buy = {}

win_state = imgui.new.bool(false)
active_tab = 1
active_sub_tab = 1

LOCAL_PLAYER_NICK = nil
req_ok, requests = pcall(require, 'requests')

show_update_window = imgui.new.bool(false)

State = {
    update = { available = false, version = "", url = "", text = "" },
    stats_requested = false,
    silent_stats = false,
    auto_pr = { global_cooldown = 0, last_vr_time = 0, pending_vr_response = false },
    buying_scan = { active = false, stage = nil, current_page = 1, all_items = {}, current_dialog_id = nil },
    inventory_scan = { 
        active = false, stage = "", has_received_data = false, last_packet_time = 0, current_dialog_id = nil
    },
    selling = {
        active = false, stage = "", current_idx = 1, total = 0, current_item = nil, available_items = {}, last_packet_time = 0
    },
    buying = {
        active = false, stage = "", current_idx = 1, total = 0, current_item = nil
    }
}

pr_buffers = {}
pr_delay_buffers = {}

local function getPRBuffer(idx, text)
    if not pr_buffers[idx] then pr_buffers[idx] = ffi.new('char[256]', text or "") end
    return pr_buffers[idx]
end

local function getPRDelayBuffer(idx, delay)
    if not pr_delay_buffers[idx] then pr_delay_buffers[idx] = ffi.new('char[32]', tostring(delay or 60)) end
    return pr_delay_buffers[idx]
end

local function checkUpdate()
    local thread_code = [[
        return function (url)
            local http = require 'socket.http'
            local body, code = http.request(url)
            if tonumber(code) == 200 and body then
                return true, body
            end
            return false, nil
        end
    ]]
    local thread_func = assert(loadstring(thread_code))()
    local runner = effil.thread(thread_func)("https://raw.githubusercontent.com/RuRamzes/RodinaMarket/main/update.json")
    
    lua_thread.create(function()
        while true do
            local status, err = runner:status()
            if not err then
                if status == 'completed' then
                    local ok, json_text = runner:get()
                    if ok and json_text then
                        local cjson = require 'cjson'
                        local json_ok, data = pcall(cjson.decode, json_text)
                        if json_ok and type(data) == "table" then
                            if data.version and data.version ~= thisScript().version then
                                State.update.version = data.version
                                State.update.url = data.url
                                State.update.text = data.text or "Доступна новая версия!"
                                State.update.available = true
                                show_update_window[0] = true
                            end
                        end
                    end
                    return
                elseif status == 'canceled' then
                    return
                end
            else
                sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Сбой проверки обновлений.", -1)
                return
            end
            wait(0)
        end
    end)
end

local function downloadScriptUpdate(url, dest, callback)
    local thread_code = [[
        return function (url, dest)
            local http = require 'socket.http'
            local ltn12 = require 'ltn12'
            local f = io.open(dest, "wb")
            if not f then return false, "Ошибка доступа к файлу" end
            
            local _, code = http.request{
                url = url,
                method = "GET",
                sink = ltn12.sink.file(f)
            }
            
            if tonumber(code) == 200 then
                return true, "Успешно"
            else
                return false, "Код ошибки HTTP: " .. tostring(code)
            end
        end
    ]]
    local thread_func = assert(loadstring(thread_code))()
    local runner = effil.thread(thread_func)(url, dest)
    
    lua_thread.create(function()
        while true do
            local status, err = runner:status()
            if not err then
                if status == 'completed' then
                    local success, reason = runner:get()
                    callback(success, reason)
                    return
                elseif status == 'canceled' then
                    callback(false, "Отменено пользователем")
                    return
                end
            else
                callback(false, "Ошибка записи потока")
                return
            end
            wait(0)
        end
    end)
end

local function processPRVariables(text)
    if not text then return "" end
    local _, myId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    local myName = LOCAL_PLAYER_NICK or "Unknown"
    local vars = {
        ["{id}"] = tostring(myId),
        ["{name}"] = myName,
        ["{name_space}"] = myName:gsub("_", " "),
        ["{lvl}"] = tostring(sampGetPlayerScore(myId)),
        ["{time}"] = os.date("%H:%M")
    }
    return text:gsub("{(.-)}", function(k) return vars["{"..k.."}"] or "{"..k.."}" end)
end

local function cleanTextColors(text)
    if type(text) ~= 'string' or text == "" then return "" end
    return text:gsub("{%x%x%x%x%x%x}", ""):gsub("%[%x%x%x%x%x%x%]", ""):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
end

local ITEM_PREFIXES = {
    "Улучшение оружия", "Унив. тюнинг", "Виз. тюнинг", "Тех. тюнинг", "Авто. номер",
    "Аксессуар", "Сертификат", "Приманка", "Саженец", "Улучшение",
    "Винила", "Объект", "Одежда", "Телефон", "Урожай", "Чертёж",
    "Предмет", "Актер", "Ларец", "Рыба", "Семя", "Туша", "Шкура", "Ящик"
}

local function cleanItemName(name)
    local original = name
    name = name:gsub("{%x%x%x%x%x%x}", ""):gsub("%[.-%]", ""):gsub("^[оеш]?[втг]%s+", "")
    return name:match("^%s*(.-)%s*$") or ""
end

search_buf_sell = ffi.new('char[128]')
search_buf_buy = ffi.new('char[128]')
search_buf_market = ffi.new('char[128]')

local RODINA_SERVERS_DATA = {
    { id = "Central",   name = "Центральный", ip = "185.169.134.163", port = "7777" },
    { id = "Southern",  name = "Южный",       ip = "185.169.134.60",  port = "8904" },
    { id = "Northern",  name = "Северный",    ip = "185.169.134.62",  port = "8904" },
    { id = "Eastern",   name = "Восточный",   ip = "185.169.134.108", port = "7777" },
    { id = "Western",   name = "Западный",    ip = "80.66.71.85",     port = "7777" },
    { id = "Primorsky", name = "Приморский",  ip = "80.66.82.58",     port = "7777" },
    { id = "Federal",   name = "Федеральный", ip = "80.66.82.55",     port = "7777" }
}

local function normalizeServerId(ip_port)
    for _, srv in ipairs(RODINA_SERVERS_DATA) do
        if ip_port:find(srv.ip) then return srv.id end
    end
    return "Unknown"
end

local function getServerDisplayName(id)
    for _, srv in ipairs(RODINA_SERVERS_DATA) do
        if srv.id == id then return srv.name end
    end
    return id
end

StateMarket = {
    is_loading = false,
    shops_list = {},
    selected_shop = nil,
    gps_active = false,
    gps_target = nil,
    current_server_id = "Unknown",
    server_filter_idx = 0 
}

cfg_modal = {
    active = false,
    item = nil,
    index = nil,
    is_sell = false,
    target_table = nil,
    buf_price = ffi.new('char[32]'),
    buf_amount = ffi.new('char[32]')
}

touch_state = {
    start_pos = imgui.ImVec2(0, 0),
    is_dragging = false,
    col = 0,
    threshold = 10.0
}

ui_cache_sell = { query = nil, items = {} }
ui_cache_buy = { query = nil, items = {} }

active_cefs = {}
was_menu_open = false

undo_stack = {}
undo_timer = 0

local ROOT_DIR = getWorkingDirectory() .. '/RMarket/'
local PATH_INV = ROOT_DIR .. 'mobile_inv.json'
local PATH_DB = ROOT_DIR .. 'mobile_buyable.json'
local PATH_NAMES = ROOT_DIR .. 'data/items_db.json'
local PATH_CFG_SELL = ROOT_DIR .. 'config_sell.json'
local PATH_CFG_BUY = ROOT_DIR .. 'config_buy.json'
local PATH_SETTINGS = ROOT_DIR .. 'settings.json'
local PATH_LOGS = ROOT_DIR .. 'logs/'
local PATH_PRICES = ROOT_DIR .. 'average_prices.json'

local function saveJsonFile(path, data)
    local clean_path = path:gsub("\\", "/")
    
    if not doesDirectoryExist(ROOT_DIR) then lfs.mkdir(ROOT_DIR) end
    if not doesDirectoryExist(ROOT_DIR .. 'data') then lfs.mkdir(ROOT_DIR .. 'data') end
    if not doesDirectoryExist(PATH_LOGS) then lfs.mkdir(PATH_LOGS) end
    
    local f = io.open(clean_path, "w")
    if f then f:write(cjson.encode(data)); f:close() end
end

local function loadJsonFile(path)
    local f = io.open(path, "r")
    if f then
        local str = f:read("*a")
        f:close()
        local ok, res = pcall(cjson.decode, str)
        return ok and res or {}
    end
    return {}
end

Settings = {
    auto_name = false,
    shop_name = "Rodina Market",
    api_key = "",
    auto_pr = { active = false, items = {} }
}

LogsState = {
    cached_income = 0,
    cached_expense = 0,
    today = { earned = 0, spent = 0, trades = 0, date = "" },
    logs_dates_cache = {},
    logs_current_date_idx = 0,
    current_view_logs = {}
}

log_filters = {
    show_sales = imgui.new.bool(true),
    show_purchases = imgui.new.bool(true)
}

local function refreshLogDates()
    if not doesDirectoryExist(PATH_LOGS) then lfs.mkdir(PATH_LOGS) end
    local files = {}
    for file in lfs.dir(PATH_LOGS) do
        if file:match("^%d%d%d%d%-%d%d%-%d%d%.json$") then
            table.insert(files, file:sub(1, -6))
        end
    end
    table.sort(files, function(a, b) return a > b end)
    LogsState.logs_dates_cache = files
end

local function loadLogsForDate(date_str)
    local path = PATH_LOGS .. date_str .. ".json"
    return loadJsonFile(path)
end

local function updateLogView()
    local selected_idx = LogsState.logs_current_date_idx
    local raw_logs = {}
    
    if selected_idx > 0 and LogsState.logs_dates_cache[selected_idx] then
        raw_logs = loadLogsForDate(LogsState.logs_dates_cache[selected_idx])
    else
        raw_logs = loadLogsForDate(os.date("%Y-%m-%d"))
        if #raw_logs > 0 and #LogsState.logs_dates_cache == 0 then refreshLogDates() end
    end
    
    local filtered = {}
    local show_sales = log_filters.show_sales[0]
    local show_purchases = log_filters.show_purchases[0]
    
    table.sort(raw_logs, function(a, b) return (a.timestamp or 0) > (b.timestamp or 0) end)
    
    local income, expense = 0, 0
    for _, log in ipairs(raw_logs) do
        local pass = true
        if log.type == "sale" and not show_sales then pass = false end
        if log.type == "purchase" and not show_purchases then pass = false end
        if pass then
            table.insert(filtered, log)
            if log.type == "sale" then income = income + log.total else expense = expense + log.total end
        end
    end
    LogsState.current_view_logs = filtered
    return income, expense
end

local function calculateTodayStats()
    local today_str = os.date("%Y-%m-%d")
    local logs = loadLogsForDate(today_str)
    local earned, spent = 0, 0
    for _, log in ipairs(logs) do
        if log.type == "sale" then earned = earned + log.total
        elseif log.type == "purchase" then spent = spent + log.total end
    end
    LogsState.today.earned = earned
    LogsState.today.spent = spent
    LogsState.today.trades = #logs
    LogsState.today.date = today_str
end

local function sendTelegramNotification(transaction)
    if Settings.api_key == "" or not req_ok then return end
    local ip, port = sampGetCurrentServerAddress()
    local srv_id = normalizeServerId(ip .. ":" .. port)
    
    local payload_str = cjson.encode({
        secret_key = Settings.api_key,
        data = {
            type = transaction.type,
            player = u8(transaction.player), 
            item = u8(transaction.item),
            amount = transaction.amount,
            price = transaction.price,
            total = transaction.total,
            tax_percent = 0,
            tax_amount = 0,
            net_total = transaction.total,
            est_item_profit = 0, 
            avg_buy_price = 0,
            server = srv_id,
            balance = getPlayerMoney(),
            earned = LogsState.today.earned,
            spent = LogsState.today.spent,
            profit = LogsState.today.earned - LogsState.today.spent
        }
    })
    
    lua_thread.create(function()
        pcall(requests.post, "https://rodina-market.store/node-api/notify", {
            data = payload_str,
            headers = { ["Content-Type"] = "application/json", ["X-Auth-Key"] = Settings.api_key },
            timeout = 10,
            verify = false
        })
    end)
end

local function addTransactionLog(transaction)
    if not transaction then return end
    if not doesDirectoryExist(PATH_LOGS) then lfs.mkdir(PATH_LOGS) end
    local current_date_str = os.date("%Y-%m-%d")
    local file_path = PATH_LOGS .. current_date_str .. ".json"
    
    local day_logs = loadJsonFile(file_path)
    table.insert(day_logs, transaction)
    saveJsonFile(file_path, day_logs)

    calculateTodayStats()
    if active_tab == 3 then
        refreshLogDates()
        LogsState.cached_income, LogsState.cached_expense = updateLogView()
    end
    sendTelegramNotification(transaction)
end

THEME = {
    bg_main          = imgui.ImVec4(0.09, 0.09, 0.11, 1.00),
    bg_secondary     = imgui.ImVec4(0.13, 0.13, 0.16, 1.00),
    bg_tertiary      = imgui.ImVec4(0.18, 0.18, 0.22, 1.00),
    accent_primary   = imgui.ImVec4(0.38, 0.28, 0.65, 1.00), 
    accent_success   = imgui.ImVec4(0.40, 0.80, 0.50, 1.00), 
    accent_danger    = imgui.ImVec4(0.90, 0.35, 0.35, 1.00), 
    text_primary     = imgui.ImVec4(0.98, 0.98, 0.99, 1.00),
    text_secondary   = imgui.ImVec4(0.60, 0.62, 0.70, 1.00),
    border           = imgui.ImVec4(1.00, 1.00, 1.00, 0.08)
}

font_main = nil
font_fa = nil
font_fa_large = nil

inv_items = {}
db_items = {}
item_names = {}

config_sell = loadJsonFile(PATH_CFG_SELL)
config_buy = loadJsonFile(PATH_CFG_BUY)
average_prices = loadJsonFile(PATH_PRICES)

local loaded_sets = loadJsonFile(PATH_SETTINGS)
if loaded_sets.auto_name ~= nil then Settings.auto_name = loaded_sets.auto_name end
if loaded_sets.shop_name then Settings.shop_name = loaded_sets.shop_name end
if loaded_sets.api_key then Settings.api_key = loaded_sets.api_key end
if loaded_sets.auto_pr then Settings.auto_pr = loaded_sets.auto_pr end
if loaded_sets.show_live_hud ~= nil then Settings.show_live_hud = loaded_sets.show_live_hud else Settings.show_live_hud = true end
if loaded_sets.show_float_btn ~= nil then Settings.show_float_btn = loaded_sets.show_float_btn else Settings.show_float_btn = true end
if loaded_sets.hud_pos_x then Settings.hud_pos_x = loaded_sets.hud_pos_x end
if loaded_sets.hud_pos_y then Settings.hud_pos_y = loaded_sets.hud_pos_y end
if loaded_sets.rm_btn_x then Settings.rm_btn_x = loaded_sets.rm_btn_x end
if loaded_sets.rm_btn_y then Settings.rm_btn_y = loaded_sets.rm_btn_y end
if loaded_sets.trade_delay then Settings.trade_delay = loaded_sets.trade_delay else Settings.trade_delay = 1200 end

b_auto_name = imgui.new.bool(Settings.auto_name)
b_show_hud = imgui.new.bool(Settings.show_live_hud)
b_show_float = imgui.new.bool(Settings.show_float_btn)
buf_shop_name = ffi.new('char[64]', Settings.shop_name)
buf_api_key = ffi.new('char[128]', Settings.api_key)
sl_delay = imgui.new.int(Settings.trade_delay)

local function stopBuyingScan()
    if State.buying_scan.current_dialog_id then 
        sampSendDialogResponse(State.buying_scan.current_dialog_id, 0, 0, "") 
    end
    sampAddChatMessage('{FF0000}[RMarket] Сканирование прервано', -1)
    
    State.buying_scan.stage = 'closing'
    lua_thread.create(function()
        local start = os.clock()
        while State.buying_scan.active and State.buying_scan.stage == 'closing' do
            wait(100)
            if os.clock() - start > 1.5 then
                State.buying_scan.active = false
                break
            end
        end
    end)
end

local function finishBuyingScan()
    local unique_items = {}
    local seen = {}
    for _, item in ipairs(State.buying_scan.all_items) do
        local key = item.name .. "_" .. item.index
        if not seen[key] then
            seen[key] = true
            table.insert(unique_items, item)
            item_names[tostring(item.index)] = item.name
        end
    end
    
    db_items = unique_items
    saveJsonFile(PATH_DB, db_items)
    saveJsonFile(PATH_NAMES, item_names)
    
    sampAddChatMessage('{5CB85C}[RMarket] {FFFFFF}База товаров обновлена: ' .. #db_items .. ' шт.', -1)
    ui_cache_buy.query = nil
    
    if State.buying_scan.current_dialog_id then 
        sampSendDialogResponse(State.buying_scan.current_dialog_id, 0, 0, "") 
    end

    State.buying_scan.stage = 'closing'
    
    lua_thread.create(function()
        local start = os.clock()
        while State.buying_scan.active and State.buying_scan.stage == 'closing' do
            wait(100)
            if os.clock() - start > 1.5 then
                State.buying_scan.active = false
                win_state[0] = true
                break
            end
        end
    end)
end

local function processBuyingPage(dialog_text, dialog_id)
    State.buying_scan.current_dialog_id = dialog_id

    local next_page_idx = -1
    local current_idx = 0
    
    local sorted_prefixes = {}
    for _, p in ipairs(ITEM_PREFIXES) do table.insert(sorted_prefixes, p) end
    table.sort(sorted_prefixes, function(a, b) return #a > #b end)

    for line in dialog_text:gmatch("[^\r\n]+") do
        local clean = cleanTextColors(line)
        
        if clean:find("Следующая страница") or clean:find("^%s*>") then
            next_page_idx = current_idx
        elseif not clean:find("Поиск предмета") and not clean:find("Поиск по категориям") and not clean:find("Предыдущая страница") then
            local raw_name, item_id = clean:match("^(.-)%s*%[(%d+)%]$")
            if raw_name and item_id then
                local name = raw_name
                
                for _, pfx in ipairs(sorted_prefixes) do
                    local safe_pfx = pfx:gsub("%.", "%%.")
                    if name:match("^" .. safe_pfx .. "%s+") then
                        name = name:sub(#pfx + 2)
                        break
                    end
                end
                
                table.insert(State.buying_scan.all_items, { 
                    name = cleanItemName(name), 
                    index = tonumber(item_id) 
                })
            end
        end
        current_idx = current_idx + 1
    end

    if next_page_idx ~= -1 then
        State.buying_scan.current_page = State.buying_scan.current_page + 1
        sampSendDialogResponse(dialog_id, 1, next_page_idx, "")
    else
        finishBuyingScan()
    end
end

inv_items = loadJsonFile(PATH_INV)
db_items = loadJsonFile(PATH_DB)
local raw_names = loadJsonFile(PATH_NAMES)
if raw_names then
    for k, v in pairs(raw_names) do
        item_names[tostring(k)] = type(v) == "table" and v.n or v
    end
end

local function safeParseMarketItems(ids_tbl, counts_tbl, prices_tbl)
    local list = {}
    if type(ids_tbl) ~= "table" then return list end
    for k, v in pairs(ids_tbl) do
        local model_id = tonumber(v) or 0
        local amount = 0
        local price = 0
        if type(counts_tbl) == "table" then amount = tonumber(counts_tbl[k]) or 0 end
        if type(prices_tbl) == "table" then price = tonumber(prices_tbl[k]) or 0 end
        if model_id > 0 then
            table.insert(list, {
                name = item_names[tostring(model_id)] or "Предмет_"..model_id,
                model_id = model_id,
                amount = amount,
                price = price
            })
        end
    end
    return list
end

local function api_DownloadAveragePrices()
    sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Скачивание средних цен...", -1)
    lua_thread.create(function()
        local ip, port = sampGetCurrentServerAddress()
        local srv_id = normalizeServerId(ip .. ":" .. port)
        local ok, res = pcall(requests.get, "https://rodina-market.store/node-api/get_prices?server=" .. srv_id, {timeout = 15, verify = false})
        if ok and res.status_code == 200 then
            local json_ok, data = pcall(cjson.decode, res.text)
            if json_ok then
                average_prices = {}
                for k, v in pairs(data) do
                    local clean_k = cleanItemName(u8:decode(k))
                    average_prices[clean_k] = { sell = v.s, buy = v.b }
                end
                saveJsonFile(PATH_PRICES, average_prices)
                sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Средние цены успешно обновлены!", -1)
            end
        else
            sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ошибка сети при скачивании цен.", -1)
        end
    end)
end

local function api_FetchMarketList()
    if StateMarket.is_loading then return end
    StateMarket.is_loading = true
    
    local ip, port = sampGetCurrentServerAddress()
    StateMarket.current_server_id = normalizeServerId(ip .. ":" .. port)
    
    for i, srv in ipairs(RODINA_SERVERS_DATA) do
        if srv.id == StateMarket.current_server_id then
            StateMarket.server_filter_idx = i
            break
        end
    end
    
    lua_thread.create(function()
        local ok, res = pcall(requests.get, "https://rodina-market.store/node-api/marketplace?action=list", {
            timeout = 15,
            verify = false
        })
        if ok and res.status_code == 200 then
            local json_ok, data = pcall(cjson.decode, res.text)
            if json_ok and type(data) == "table" then
                StateMarket.shops_list = {}
                for _, shop in ipairs(data) do
                    local s_list = safeParseMarketItems(shop.items_sell, shop.count_sell, shop.price_sell)
                    local b_list = safeParseMarketItems(shop.items_buy, shop.count_buy, shop.price_buy)
                    if #s_list > 0 or #b_list > 0 then
                        table.insert(StateMarket.shops_list, {
                            nickname = shop.username or shop.user or "Unknown",
                            serverId = shop.serverId or shop.server_id,
                            vip = shop.vip or false,
                            sell_list = s_list,
                            buy_list = b_list,
                            sell_count = #s_list,
                            buy_count = #b_list
                        })
                    end
                end
            end
        end
        StateMarket.is_loading = false
    end)
end

local function finishInventoryScan()
    State.inventory_scan.active = false
    
    if State.inventory_scan.current_dialog_id then
        sampSendDialogResponse(State.inventory_scan.current_dialog_id, 0, 0, "")
        State.inventory_scan.current_dialog_id = nil
    end
    
    table.sort(inv_items, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
    
    saveJsonFile(PATH_INV, inv_items)
    ui_cache_sell.query = nil
    
    sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Инвентарь считан: " .. #inv_items .. " слотов.", -1)
    
    win_state[0] = true
end

local function startInventoryScan()
    if State.inventory_scan.active then return end
    inv_items = {}
    State.inventory_scan.active = true
    State.inventory_scan.stage = "waiting_user"
    State.inventory_scan.has_received_data = false
    State.inventory_scan.last_packet_time = 0
    State.inventory_scan.current_dialog_id = nil
    sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Для считывания просто откройте ваш инвентарь.", -1)
    lua_thread.create(function()
        local start_time = os.clock()
        while State.inventory_scan.active do
            wait(150)
            local now = os.clock()
            if State.inventory_scan.stage == "parsing" and State.inventory_scan.has_received_data then
                if (now - State.inventory_scan.last_packet_time > 3.5) then
                    finishInventoryScan()
                    break
                end
            end
            if now - start_time > 120.0 and not State.inventory_scan.has_received_data then
                sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ошибка: Таймаут (120 сек). Сканирование отменено.", -1)
                State.inventory_scan.active = false
                win_state[0] = true
                break
            end
        end
    end)
end

local function sendMobileCEFClick(slot, model_id, amount)
    local json_str = string.format('{"amount":%d,"id":%d,"slot":%d,"type":1}', amount, model_id, slot)
    
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 220) 
    raknetBitStreamWriteInt8(bs, 63)  
    raknetBitStreamWriteInt8(bs, 60)  
    raknetBitStreamWriteInt32(bs, -1) 
    raknetBitStreamWriteInt32(bs, 2)  
    raknetBitStreamWriteInt16(bs, #json_str)
    raknetBitStreamWriteString(bs, json_str) 
    
    raknetSendBitStreamEx(bs, 1, 7, 0)
    raknetDeleteBitStream(bs)
end

local function processSellingCoroutine()
    sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Активных слотов в лавке: " .. #State.selling.available_items .. ". Ищем совпадения...", -1)
    wait(1000) 
    
    local sell_queue = {}
    local used_slots = {}
    
    for i, config_item in ipairs(config_sell) do
        local target_model_id = tonumber(config_item.model_id)
        if not target_model_id then
            for _, inv_item in ipairs(inv_items) do
                if inv_item.name == config_item.name then
                    target_model_id = tonumber(inv_item.model_id)
                    break
                end
            end
        end
        
        if target_model_id then
            for _, available in ipairs(State.selling.available_items) do
                if available.model_id == target_model_id and not used_slots[available.slot] then
                    used_slots[available.slot] = true
                    table.insert(sell_queue, {
                        slot = available.slot,
                        model_id = available.model_id,
                        real_stack_amount = available.amount or 1,
                        name = config_item.name,
                        price = config_item.price,
                        amount = config_item.amount,
                        auto_max = config_item.auto_max
                    })
                end
            end
        end
    end

    if #sell_queue == 0 then
        sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Товары из конфига не найдены в активных слотах!", -1)
        State.selling.active = false
        return
    end

    State.selling.total = #sell_queue
    local items_exhibited = 0
    
    for i, q_item in ipairs(sell_queue) do
        if not State.selling.active then 
            sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Выставление принудительно остановлено!", -1)
            break 
        end
        
        State.selling.current_idx = i
        State.selling.current_item = q_item
        State.selling.stage = 'waiting_input'
        
        local display_name = q_item.name and tostring(q_item.name) or "Неизвестный товар"
        sampAddChatMessage(string.format("{F0AD4E}[RMarket] {FFFFFF}Выставляем: %s (Слот: %d)", display_name, q_item.slot), -1)
        
        sendMobileCEFClick(q_item.slot, q_item.model_id, q_item.real_stack_amount)
        
        local wait_time = 0
        while State.selling.stage == 'waiting_input' and State.selling.active do
            wait(100)
            wait_time = wait_time + 100
            if wait_time > 9000 then 
                sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Таймаут окна ввода цены для: " .. display_name, -1)
                break 
            end
        end
        
        if State.selling.stage == 'next_item' then
            items_exhibited = items_exhibited + 1
            wait(Settings.trade_delay or 1200)
        end
    end
    
    if State.selling.active then
        sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Готово! Выставлено товаров: " .. items_exhibited, -1)
        
        State.selling.stage = 'closing'
        sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Закрытие меню лавки...", -1)
        
        local bs = raknetNewBitStream()
        raknetBitStreamWriteInt8(bs, 220)
        raknetBitStreamWriteInt8(bs, 66)
        raknetBitStreamWriteInt8(bs, 60)
        raknetBitStreamWriteBool(bs, false)
        raknetSendBitStreamEx(bs, 1, 7, 0)
        raknetDeleteBitStream(bs)
        
        local wait_close = 0
        while State.selling.active and wait_close < 3000 do
            wait(100)
            wait_close = wait_close + 100
        end
    end
end

function events.onShowDialog(id, style, title, b1, b2, text)
    local clean_title = cleanTextColors(title)
    local clean_text = cleanTextColors(text)

    if (id == 1295 or id == 1296) and State.auto_pr.pending_vr_response then
        sampSendDialogResponse(id, 1, -1, "")
        if id == 1295 then State.auto_pr.pending_vr_response = false end
        return false
    end

    if clean_title:find("Статистика игрока") or clean_text:find("Текущее состояние счета") then
        local nick = clean_text:match("Имя %(en%.%):%s*([%w_]+)")
        if nick then LOCAL_PLAYER_NICK = nick end
        
        if State.stats_requested then
            State.stats_requested = false
            api_TestTelegramToken()
            return false
        end
        if State.silent_stats then
            State.silent_stats = false
            return false
        end
    end

    if id == 8 and (title:find("Название лавки") or title:find("Название")) then
        if Settings.auto_name and Settings.shop_name ~= "" then
            lua_thread.create(function()
                wait(200)
                sampSendDialogResponse(id, 1, 0, u8:decode(Settings.shop_name))
            end)
            return false
        end
    end

    if State.inventory_scan.active then
        if id == 731 or id == 1191 then
            if State.inventory_scan.stage == "settings" then
                local list_idx = -1
                local current_idx = 0
                for line in text:gmatch("[^\r\n]+") do
                    local c_line = cleanTextColors(line):gsub("%s+", "")
                    if c_line:find("Настройкиинвентаря") then 
                        list_idx = (style == 5 and current_idx - 1) or current_idx 
                        break 
                    end
                    current_idx = current_idx + 1
                end
                if list_idx ~= -1 then
                    sampSendDialogResponse(id, 1, list_idx, "")
                end
            elseif State.inventory_scan.stage == "parsing" then
                sampSendDialogResponse(id, 0, 0, "")
            end
            return false
        end
        
        if id == 734 or id == 1190 then
            if State.inventory_scan.stage == "settings" then
                local list_idx = -1
                local current_idx = 0
                local is_enabled = false
                
                for line in text:gmatch("[^\r\n]+") do
                    local c_line = cleanTextColors(line):gsub("%s+", "")
                    if c_line:find("Новыйинвентарь") or c_line:find("НовыйCEFинвентарь") then
                        list_idx = (style == 5 and current_idx - 1) or current_idx
                        if c_line:find("Включено") or c_line:find("Включен") then 
                            is_enabled = true 
                        end
                        break
                    end
                    current_idx = current_idx + 1
                end
                
                if list_idx ~= -1 then
                    if is_enabled then
                        sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Перезапуск CEF инвентаря...", -1)
                        sampSendDialogResponse(id, 1, list_idx, "")
                    else
                        sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Чтение пакетов инвентаря...", -1)
                        State.inventory_scan.stage = "parsing"
                        sampSendDialogResponse(id, 1, list_idx, "")
                    end
                end
            elseif State.inventory_scan.stage == "parsing" then
                sampSendDialogResponse(id, 0, 0, "")
            end
            return false
        end
    end

    if State.buying_scan.active then
        if State.buying_scan.stage == 'waiting_dialog' and (title:find("Управление лавкой") or title:find("Лавка") or id == 9) then
            State.buying_scan.stage = 'waiting_category_menu'
            local idx = 0
            local target_idx = 1
            for line in text:gmatch("[^\r\n]+") do
                if cleanTextColors(line):find("Выставить товар на скупку") then target_idx = idx break end
                idx = idx + 1
            end
            sampSendDialogResponse(id, 1, target_idx, "")
            return false
        end
        
        if State.buying_scan.stage == 'waiting_category_menu' and (title:find("Скупка:") or id == 10 or id == 801) then
            State.buying_scan.stage = 'waiting_full_list_menu'
            local idx = 0
            local target_idx = 1
            for line in text:gmatch("[^\r\n]+") do
                if cleanTextColors(line):find("Поиск по категориям") then target_idx = idx break end
                idx = idx + 1
            end
            sampSendDialogResponse(id, 1, target_idx, "")
            return false
        end
        
        if State.buying_scan.stage == 'waiting_full_list_menu' and (id == 911 or id == 802 or title:find("Категории для поиска") or text:find("Весь список")) then
            State.buying_scan.stage = 'processing_page'
            local idx = 0
            local target_idx = -1
            for line in text:gmatch("[^\r\n]+") do
                if cleanTextColors(line):find("Весь список") then target_idx = idx break end
                idx = idx + 1
            end
            if target_idx == -1 then target_idx = idx - 1 end
            sampSendDialogResponse(id, 1, target_idx, "")
            return false
        end
        
        if State.buying_scan.stage == 'processing_page' and (id == 10 or title:find("Скупка:") or title:find("Весь список") or title:find("Страница")) then
            processBuyingPage(text, id)
            return false
        end
        
        if State.buying_scan.stage == 'closing' then
            sampSendDialogResponse(id, 0, 0, "")
            if title:find("Управление лавкой") or title:find("Лавка") or id == 9 then
                State.buying_scan.active = false
                win_state[0] = true
            end
            return false
        end
    end

    if State.buying.active then
        if State.buying.stage == 'waiting_dialog' and (title:find("Управление лавкой") or title:find("Лавка") or id == 9) then
            State.buying.current_item = config_buy[State.buying.current_idx]
            State.buying.stage = 'waiting_search_menu'
            sampSendDialogResponse(id, 1, 1, "")
            return false
        end

        if State.buying.stage == 'waiting_search_menu' and (id == 10 or id == 801 or title:find("Скупка:")) then
            State.buying.stage = 'processing_delay'
            lua_thread.create(function()
                if State.buying.current_idx > 1 then
                    wait(Settings.trade_delay or 1200)
                end
                State.buying.stage = 'waiting_search_input'
                sampSendDialogResponse(id, 1, 0, "")
            end)
            return false
        end

        if (State.buying.stage == 'waiting_search_input' or State.buying.stage == 'processing_delay') and (id == 909 or id == 800 or text:find("название") or text:find("индекс")) then
            State.buying.stage = 'waiting_amount_price'
            local item_id = State.buying.current_item.model_id or State.buying.current_item.index
            if not item_id then
                for _, db_item in ipairs(db_items) do
                    if db_item.name == State.buying.current_item.name then
                        item_id = db_item.index
                        break
                    end
                end
            end
            sampSendDialogResponse(id, 1, 0, tostring(item_id or State.buying.current_item.name))
            return false
        end

        if State.buying.stage == 'waiting_amount_price' and (id == 11 or text:find("через запятую") or text:find("количество") or text:find("цену") or text:find("штук") or text:find("цвет")) then
            local input_str = ""
            local text_lower = text:lower()

            if text_lower:find("цвет аксессуара") or text_lower:find("и цвет") then
                local color_id = math.max(0, math.floor(State.buying.current_item.amount or 0))
                input_str = string.format("%d,%d", math.floor(State.buying.current_item.price), color_id)
            elseif text_lower:find("количество") or text_lower:find("штук") then
                local amount = math.max(1, math.floor(State.buying.current_item.amount or 1))
                input_str = string.format("%d,%d", amount, math.floor(State.buying.current_item.price))
            else
                input_str = string.format("%d,%d", math.floor(State.buying.current_item.amount or 1), math.floor(State.buying.current_item.price))
            end
            
            sampSendDialogResponse(id, 1, 0, input_str)

            State.buying.current_idx = State.buying.current_idx + 1
            if State.buying.current_idx > State.buying.total then
                State.buying.stage = 'closing'
            else
                State.buying.current_item = config_buy[State.buying.current_idx]
                State.buying.stage = 'waiting_search_menu'
            end
            return false
        end

        if State.buying.stage == 'closing' then
            sampSendDialogResponse(id, 0, 0, "")
            if title:find("Управление лавкой") or title:find("Лавка") or id == 9 then
                State.buying.active = false
                win_state[0] = true
                sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Все товары выставлены на скупку!", -1)
            end
            return false
        end
    end

    if State.selling.active then
        if State.selling.stage == 'waiting_dialog' and (title:find("Управление лавкой") or title:find("Лавка") or id == 9) then
            local target_idx = 0
            local current = 0
            for line in text:gmatch("[^\r\n]+") do
                if cleanTextColors(line):find("Выставить товар на продажу") then target_idx = current break end
                current = current + 1
            end
            sampSendDialogResponse(id, 1, target_idx, "")
            
            State.selling.available_items = {}
            State.selling.last_packet_time = 0
            State.selling.stage = 'waiting_cef_data'
            sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Сбор данных лавки...", -1)
            return false
        end
        
        if State.selling.stage == 'waiting_input' and (id == 240 or clean_text:find("цену") or clean_text:find("через запятую") or clean_text:find("количество")) then
            local input_str = ""
            local text_lower = clean_text:lower()
            
            local amt = State.selling.current_item.amount
            if State.selling.current_item.auto_max then
                local stack_in_dialog = clean_text:match("стаке:%s*(%d+)") or clean_text:match("выставить%s*(%d+)%s*шт")
                if stack_in_dialog then
                    amt = tonumber(stack_in_dialog)
                else
                    amt = State.selling.current_item.real_stack_amount or 1
                end
            end
            
            if text_lower:find("через запятую") or text_lower:find("введите количество") or text_lower:find("укажите количество") then
                input_str = string.format("%d,%d", amt, State.selling.current_item.price)
            else
                input_str = tostring(State.selling.current_item.price)
            end
            
            sampSendDialogResponse(id, 1, 0, input_str)
            State.selling.stage = 'next_item'
            return false
        end
        
        if State.selling.stage == 'closing' then
            sampSendDialogResponse(id, 0, 0, "")
            if title:find("Управление лавкой") or title:find("Лавка") or id == 9 then
                State.selling.active = false
                win_state[0] = true
            end
            return false
        end
    end
end

function events.onServerMessage(color, text)
    local clean = cleanTextColors(text)
    
    if StateMarket.gps_active and StateMarket.gps_target then
        local target = StateMarket.gps_target
        if clean:find("ID:%s*(%d+)%s*|%s*Имя:%s*" .. target) then
            local found_id = clean:match("ID:%s*(%d+)")
            if found_id then
                StateMarket.gps_active = false
                StateMarket.gps_target = nil
                sampSendChat("/findilavka " .. found_id)
                sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Метка на лавку установлена!", -1)
                return false
            end
        elseif clean:find("Игрок не найден") or clean:find("Ничего не найдено") then
            StateMarket.gps_active = false
            StateMarket.gps_target = nil
            sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Игрок оффлайн. Невозможно поставить метку.", -1)
            return false
        end
    end

    if clean:find("Вы успешно продали") or clean:find("Вы успешно купили") then
        local is_sale = clean:find("Вы успешно продали")
        local item, amount_str, total_str = clean:match("успешно %S+ (.-)%s*%((%d+) шт%.%) за ([%d%.%,%s]+) руб")
        if not item then
            item, total_str = clean:match("успешно %S+ (.-)%s*за ([%d%.%,%s]+) руб")
            amount_str = "1"
        end
        
        if item and total_str then
            local amount = tonumber((amount_str:gsub("%D", ""))) or 1
            local total = tonumber((total_str:gsub("%D", ""))) or 0
            local price = amount > 0 and math.floor(total / amount) or total
            
            local transaction = {
                timestamp = os.time(),
                date = os.date("%Y-%m-%d %H:%M:%S"),
                type = is_sale and "sale" or "purchase", 
                player = "Игрок",
                item = cleanItemName(item),
                amount = amount,
                price = price,
                total = total
            }
            addTransactionLog(transaction)
        end
    end
end

local function parseMobileCEF(msgId, json_str)
    local ok, data = pcall(cjson.decode, json_str)
    if not ok or type(data) ~= "table" or type(data.items) ~= "table" then return end

    if State.selling.active and State.selling.stage == 'waiting_cef_data' and msgId == 52 then
        local received_valid_items = false
        
        for _, item in ipairs(data.items) do
            if tonumber(item.available) == 1 and item.item then
                local item_amt = tonumber(item.count) or tonumber(item.amount)
                if not item_amt and item.text then
                    local clean_txt = tostring(item.text):gsub("{%x%x%x%x%x%x}", "")
                    local num_str = clean_txt:match("%d+")
                    if num_str then item_amt = tonumber(num_str) end
                end
                
                table.insert(State.selling.available_items, {
                    slot = tonumber(item.slot),
                    model_id = tonumber(item.item),
                    amount = item_amt or 1
                })
                received_valid_items = true
            end
        end
        
        if received_valid_items or State.selling.last_packet_time == 0 then
            State.selling.last_packet_time = os.clock()
        end
    end

    if State.inventory_scan.active and (State.inventory_scan.stage == "parsing" or State.inventory_scan.stage == "waiting_user") and (msgId == 52 or msgId == 64 or msgId == 67) then
        if State.inventory_scan.stage == "waiting_user" then State.inventory_scan.stage = "parsing" end
        State.inventory_scan.last_packet_time = os.clock()
        State.inventory_scan.has_received_data = true

        if tonumber(data.type) == 1 then
            for _, item in ipairs(data.items) do
                local slot_id = tonumber(item.slot)
                if slot_id then
                    local item_amt = tonumber(item.count) or tonumber(item.amount)
                    local has_explicit_amount = (item_amt ~= nil)
                    
                    if not item_amt and item.text then
                        local clean_txt = tostring(item.text):gsub("{%x%x%x%x%x%x}", "")
                        local num_str = clean_txt:match("%d+")
                        if num_str then 
                            item_amt = tonumber(num_str)
                            has_explicit_amount = true
                        end
                    end
                    item_amt = item_amt or 1
    
                    local existing_item = nil
                    for _, v in ipairs(inv_items) do
                        if v.slot == slot_id then existing_item = v break end
                    end
    
                    if existing_item then
                        if has_explicit_amount and item_amt > 1 then
                            existing_item.amount = item_amt
                            existing_item.max_amount = item_amt
                        end
                    elseif item.item and tonumber(item.available) == 1 and tonumber(item.is_use) ~= 1 then
                        local m_id = tonumber(item.item)
                        local name = item_names[tostring(m_id)]
                        if name then
                            table.insert(inv_items, { name = name, amount = item_amt, model_id = m_id, slot = slot_id, max_amount = item_amt })
                        end
                    end
                end
            end
        end
    end
end

addEventHandler('onReceivePacket', function(id, bs)
    if id == 220 then
        local saved_offset = raknetBitStreamGetReadOffset(bs)
        raknetBitStreamIgnoreBits(bs, 8)
        local pType = raknetBitStreamReadInt8(bs)
        
        if pType == 84 and (State.inventory_scan.active or State.buying_scan.active or State.selling.active) then
            local interfaceid = raknetBitStreamReadInt8(bs)
            local subid = raknetBitStreamReadInt8(bs)
            local len = raknetBitStreamReadInt16(bs) 
            local encoded = raknetBitStreamReadInt8(bs)
            
            local ok, json_str = pcall(function()
                if encoded ~= 0 then 
                    return raknetBitStreamDecodeString(bs, len + encoded)
                else 
                    return raknetBitStreamReadString(bs, len) 
                end
            end)
            
            if ok and type(json_str) == "string" and json_str ~= "" then
                json_str = json_str:gsub("%z", "")
                parseMobileCEF(interfaceid, json_str)
            end
        end
        
        raknetBitStreamSetReadOffset(bs, saved_offset)
    end
end)

local function formatMoney(amount)
    local left, num, right = string.match(tostring(amount), '^([^%d]*%d)(%d*)(.-)$')
    return left .. (num:reverse():gsub('(%d%d%d)', '%1.'):reverse()) .. right
end

local LOWERCASE_MAP = {}
for i = 0, 255 do
    local char = string.char(i)
    if i >= 192 and i <= 223 then
        LOWERCASE_MAP[char] = string.char(i + 32)
    elseif i == 168 then
        LOWERCASE_MAP[char] = string.char(184)
    else
        LOWERCASE_MAP[char] = string.lower(char)
    end
end

local function to_lower(str)
    if type(str) ~= "string" then return "" end
    return (str:gsub(".", LOWERCASE_MAP))
end

local SmartSearch = {}
local LAYOUT_MAP = {
    ["q"]="й", ["w"]="ц", ["e"]="у", ["r"]="к", ["t"]="е", ["y"]="н", ["u"]="г", ["i"]="ш", ["o"]="щ", ["p"]="з", ["["]="х", ["]"]="ъ",
    ["a"]="ф", ["s"]="ы", ["d"]="в", ["f"]="а", ["g"]="п", ["h"]="р", ["j"]="о", ["k"]="л", ["l"]="д", [";"]="ж", ["'"]="э",
    ["z"]="я", ["x"]="ч", ["c"]="с", ["v"]="м", ["b"]="и", ["n"]="т", ["m"]="ь", [","]="б", ["."]="ю", ["`"]="ё"
}

function SmartSearch.levenshtein(s1, s2)
    if #s1 == 0 then return #s2 end
    if #s2 == 0 then return #s1 end
    if s1 == s2 then return 0 end
    local matrix = {}
    for i = 0, #s1 do matrix[i] = {[0] = i} end
    for j = 0, #s2 do matrix[0][j] = j end
    for i = 1, #s1 do
        for j = 1, #s2 do
            local cost = (s1:sub(i,i) == s2:sub(j,j)) and 0 or 1
            matrix[i][j] = math.min(matrix[i-1][j] + 1, matrix[i][j-1] + 1, matrix[i-1][j-1] + cost)
        end
    end
    return matrix[#s1][#s2]
end

function SmartSearch.fixLayout(text)
    local result = {}
    for i = 1, #text do
        local char = text:sub(i, i)
        table.insert(result, LAYOUT_MAP[char] or char)
    end
    return table.concat(result)
end

function SmartSearch.tokenize(text)
    local tokens = {}
    for word in text:gmatch("%S+") do table.insert(tokens, word) end
    return tokens
end

function SmartSearch.getMatchScore(query, target)
    if not query or query == "" or not target then return 0 end
    local q_norm = to_lower(query) 
    local t_norm = to_lower(target)
    if q_norm == t_norm then return 100 end
    local find_start = t_norm:find(q_norm, 1, true)
    if find_start then
        if find_start == 1 or t_norm:sub(find_start-1, find_start-1) == " " then return 90 else return 80 end
    end
    local q_tokens = SmartSearch.tokenize(q_norm)
    if #q_tokens > 1 then
        local all_words_found = true
        for _, q_word in ipairs(q_tokens) do
            if not t_norm:find(q_word, 1, true) then all_words_found = false break end
        end
        if all_words_found then return 75 end
    end
    local q_fixed = SmartSearch.fixLayout(q_norm)
    if q_fixed ~= q_norm then
        if t_norm:find(q_fixed, 1, true) then return 70 end
        local fixed_tokens = SmartSearch.tokenize(q_fixed)
        if #fixed_tokens > 1 then
            local all_fixed_found = true
            for _, f_word in ipairs(fixed_tokens) do
                if not t_norm:find(f_word, 1, true) then all_fixed_found = false break end
            end
            if all_fixed_found then return 65 end
        end
    end
    if #q_norm > 3 then
        local t_tokens = SmartSearch.tokenize(t_norm)
        local total_words_matched = 0
        local fuzzy_penalty = 0
        for _, q_word in ipairs(q_tokens) do
            local best_word_score = 0
            for _, t_word in ipairs(t_tokens) do
                if t_word == q_word then best_word_score = 10
                elseif t_word:find(q_word, 1, true) then best_word_score = 8
                elseif #q_word > 2 and #t_word > 2 then
                    local dist = SmartSearch.levenshtein(q_word, t_word)
                    local allowed_errors = math.floor(#q_word / 3) 
                    if dist <= allowed_errors then best_word_score = 6 - dist end
                end
            end
            if best_word_score > 0 then
                total_words_matched = total_words_matched + 1
                fuzzy_penalty = fuzzy_penalty + (10 - best_word_score)
            end
        end
        if total_words_matched > 0 and total_words_matched == #q_tokens then
            return 60 - fuzzy_penalty 
        end
    end
    return 0
end

local hud_anim = { e = 0, s = 0 }
local function renderLiveProfitHUD()
    if not Settings.show_live_hud then return end 
    local io = imgui.GetIO()
    local sw, sh = getScreenResolution()
    
    if Settings.hud_pos_x == nil or Settings.hud_pos_x == -1 then
        imgui.SetNextWindowPos(imgui.ImVec2(sw - 20, sh - 80), imgui.Cond.FirstUseEver, imgui.ImVec2(1.0, 1.0))
    else
        imgui.SetNextWindowPos(imgui.ImVec2(Settings.hud_pos_x, Settings.hud_pos_y), imgui.Cond.FirstUseEver)
    end
    
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(18, 16))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 12.0)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.06, 0.07, 0.09, 0.95)) 
    imgui.PushStyleColor(imgui.Col.Border, THEME.accent_primary)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 1.5)

    local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.AlwaysAutoResize + imgui.WindowFlags.NoSavedSettings
    
    if imgui.Begin("##LiveProfitHUDMob", nil, flags) then
        local dl = imgui.GetWindowDrawList()
        local p = imgui.GetWindowPos()
        local win_w = imgui.GetWindowWidth()
        
        if imgui.IsWindowHovered() and imgui.IsMouseReleased(0) then
            if p.x ~= Settings.hud_pos_x or p.y ~= Settings.hud_pos_y then
                Settings.hud_pos_x = p.x
                Settings.hud_pos_y = p.y
                saveJsonFile(PATH_SETTINGS, Settings)
            end
        end
        
        imgui.Dummy(imgui.ImVec2(240, 0))
        local content_w = math.max(240, win_w - 36)

        local earned = LogsState.today.earned or 0
        local spent = LogsState.today.spent or 0
        local trades_count = LogsState.today.trades or 0

        local dt = io.DeltaTime
        hud_anim.e = hud_anim.e + (earned - hud_anim.e) * dt * 8.0
        hud_anim.s = hud_anim.s + (spent - hud_anim.s) * dt * 8.0

        if font_fa then
            imgui.PushFont(font_fa)
            imgui.TextColored(THEME.accent_primary, fa('chart_pie'))
            imgui.PopFont()
            imgui.SameLine(0, 8)
        end
        imgui.TextColored(imgui.ImVec4(1, 1, 1, 0.95), u8"RMarket Live")
        
        local dot_center = imgui.ImVec2(p.x + win_w - 18 - 2, p.y + 16 + 6)
        local t = os.clock() * 1.5
        local fract = t % 1.0
        local pulse_r = 4 + (fract * 10)
        local pulse_a = 1.0 - (fract * fract)
        dl:AddCircleFilled(dot_center, pulse_r, imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.2, 0.8, 0.3, pulse_a * 0.5)))
        local inner_a = 0.6 + (math.sin(os.clock() * 6) + 1) * 0.2
        dl:AddCircleFilled(dot_center, 4, imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.2, 0.9, 0.3, inner_a)))
        
        imgui.Dummy(imgui.ImVec2(0, 8))
        
        local function DrawRowAligned(label, val_str, val_col, icon)
            if font_fa then
                imgui.PushFont(font_fa)
                imgui.TextColored(THEME.text_secondary, icon)
                imgui.PopFont()
                imgui.SameLine(0, 8)
            end
            imgui.TextColored(THEME.text_secondary, label)
            imgui.PushFont(font_main)
            local v_sz = imgui.CalcTextSize(val_str)
            imgui.SameLine(18 + content_w - v_sz.x)
            imgui.TextColored(val_col, val_str)
            imgui.PopFont()
        end

        DrawRowAligned(u8"Сделок:", tostring(trades_count), THEME.text_primary, fa('handshake'))
        DrawRowAligned(u8"Доход:", "+" .. formatMoney(math.floor(hud_anim.e)) .. " $", THEME.accent_success, fa('arrow_up'))
        DrawRowAligned(u8"Расход:", "-" .. formatMoney(math.floor(hud_anim.s)) .. " $", THEME.accent_danger, fa('arrow_down'))
        
        imgui.Dummy(imgui.ImVec2(0, 6))
        local sep_y = imgui.GetCursorScreenPos().y
        local c_clear = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(THEME.border.x, THEME.border.y, THEME.border.z, 0.0))
        local c_solid = imgui.ColorConvertFloat4ToU32(THEME.border)
        dl:AddRectFilledMultiColor(imgui.ImVec2(p.x, sep_y), imgui.ImVec2(p.x + win_w/2, sep_y + 1), c_clear, c_solid, c_solid, c_clear)
        dl:AddRectFilledMultiColor(imgui.ImVec2(p.x + win_w/2, sep_y), imgui.ImVec2(p.x + win_w, sep_y + 1), c_solid, c_clear, c_clear, c_solid)
        imgui.Dummy(imgui.ImVec2(0, 8))
        
        local profit_anim = math.floor(hud_anim.e) - math.floor(hud_anim.s)
        local p_str = (profit_anim > 0 and "+" or "") .. formatMoney(profit_anim) .. " $"
        local p_col = profit_anim >= 0 and THEME.accent_success or THEME.accent_danger
        local profit_bg = profit_anim >= 0 and imgui.ColorConvertFloat4ToU32(imgui.ImVec4(THEME.accent_success.x, THEME.accent_success.y, THEME.accent_success.z, 0.15)) or imgui.ColorConvertFloat4ToU32(imgui.ImVec4(THEME.accent_danger.x, THEME.accent_danger.y, THEME.accent_danger.z, 0.15))
        
        local cur_y = imgui.GetCursorScreenPos().y
        dl:AddRectFilled(imgui.ImVec2(p.x, cur_y - 4), imgui.ImVec2(p.x + win_w, cur_y + imgui.GetFontSize() + 4), profit_bg)

        imgui.TextColored(THEME.text_primary, u8"ЧИСТАЯ ПРИБЫЛЬ:")
        imgui.PushFont(font_main)
        local p_sz = imgui.CalcTextSize(p_str)
        imgui.SameLine(18 + content_w - p_sz.x)
        imgui.TextColored(p_col, p_str)
        imgui.PopFont()
    end
    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(3)
end

imgui.OnInitialize(function()
    local io = imgui.GetIO()
    io.IniFilename = nil
    
    local style = imgui.GetStyle()
    style.WindowRounding    = 16.0
    style.ChildRounding     = 12.0
    style.FrameRounding     = 12.0
    style.ScrollbarSize     = 20.0
    style.ScrollbarRounding = 10.0
    style.WindowPadding     = imgui.ImVec2(0, 0)
    style.ItemSpacing       = imgui.ImVec2(10, 10)

    style.Colors[imgui.Col.WindowBg]             = THEME.bg_main
    style.Colors[imgui.Col.ChildBg]              = THEME.bg_secondary
    style.Colors[imgui.Col.Text]                 = THEME.text_primary
    style.Colors[imgui.Col.TextDisabled]         = THEME.text_secondary
    style.Colors[imgui.Col.Border]               = THEME.border
    style.Colors[imgui.Col.ScrollbarBg]          = imgui.ImVec4(0,0,0,0)
    style.Colors[imgui.Col.ScrollbarGrab]        = THEME.bg_tertiary
    style.Colors[imgui.Col.ScrollbarGrabHovered] = THEME.bg_tertiary
    style.Colors[imgui.Col.ScrollbarGrabActive]  = THEME.accent_primary

    local config = imgui.ImFontConfig()
    config.MergeMode = false
    
    local font_path = getWorkingDirectory() .. '/resource/fonts/trebucbd.ttf'
    
    font_main = io.Fonts:AddFontFromFileTTF(font_path, 20.0, config, io.Fonts:GetGlyphRangesCyrillic())
    
    local icon_config = imgui.ImFontConfig()
    icon_config.MergeMode = true
    icon_config.GlyphOffset = imgui.ImVec2(0, 2)
    local fa_ranges = imgui.new.ImWchar[3](fa.min_range, fa.max_range, 0)
    
    font_fa = io.Fonts:AddFontFromMemoryCompressedBase85TTF(fa.get_font_data_base85('solid'), 20.0, icon_config, fa_ranges)
    
    local large_icon_config = imgui.ImFontConfig()
    font_fa_large = io.Fonts:AddFontFromMemoryCompressedBase85TTF(fa.get_font_data_base85('solid'), 28.0, large_icon_config, fa_ranges)
end)

local function renderSourceCard(item, is_sell, index, target_table)
    local w = imgui.GetContentRegionAvail().x
    local h = 95.0 
    local p = imgui.GetCursorScreenPos()
    local dl = imgui.GetWindowDrawList()

    local is_added = false
    if is_sell then
        for _, v in ipairs(target_table) do
            if v.name == item.name then is_added = true break end
        end
    end

    imgui.SetCursorScreenPos(p)
    imgui.InvisibleButton("##src_"..tostring(is_sell).."_"..index, imgui.ImVec2(w, h))
    local is_active = imgui.IsItemActive()

    if imgui.IsItemHovered() and imgui.IsMouseReleased(0) and not touch_state.is_dragging then
        if not is_added then
            table.insert(target_table, {
                name = item.name,
                model_id = item.model_id or item.index,
                amount = item.max_amount or 1, 
                max_amount = item.max_amount,
                price = 1000,
                auto_max = is_sell
            })
            if is_sell then saveJsonFile(PATH_CFG_SELL, config_sell) else saveJsonFile(PATH_CFG_BUY, config_buy) end
        end
    end

    local bg_col = THEME.bg_secondary
    local border_col = THEME.border
    if is_added then
        bg_col = imgui.ImVec4(THEME.accent_success.x, THEME.accent_success.y, THEME.accent_success.z, 0.15)
        border_col = imgui.ImVec4(THEME.accent_success.x, THEME.accent_success.y, THEME.accent_success.z, 0.4)
    elseif is_active then
        bg_col = THEME.bg_tertiary
    end

    dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), imgui.ColorConvertFloat4ToU32(bg_col), 16.0)
    dl:AddRect(p, imgui.ImVec2(p.x + w, p.y + h), imgui.ColorConvertFloat4ToU32(border_col), 16.0, 15, 2.0)

    local icon_sz = 56.0
    local icon_x = p.x + 20.0
    local icon_y = p.y + (h - icon_sz) / 2
    local icon_bg = is_added and THEME.accent_success or THEME.bg_main
    local icon_text_col = is_added and THEME.bg_main or THEME.text_secondary
    dl:AddCircleFilled(imgui.ImVec2(icon_x + icon_sz/2, icon_y + icon_sz/2), icon_sz/2, imgui.ColorConvertFloat4ToU32(icon_bg))
    
    imgui.PushFont(font_fa_large)
    local item_icon = is_added and fa('check') or (is_sell and fa('box') or fa('tag'))
    local isz = imgui.CalcTextSize(item_icon)
    dl:AddText(imgui.ImVec2(icon_x + (icon_sz - isz.x)/2, icon_y + (icon_sz - isz.y)/2), imgui.ColorConvertFloat4ToU32(icon_text_col), item_icon)
    imgui.PopFont()

    local plus_area_w = 80.0
    local plus_x = p.x + w - plus_area_w
    dl:AddRectFilled(imgui.ImVec2(plus_x, p.y), imgui.ImVec2(p.x + w, p.y + h), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0,0,0,0.1)), 16.0, 6)
    dl:AddLine(imgui.ImVec2(plus_x, p.y), imgui.ImVec2(plus_x, p.y + h), imgui.ColorConvertFloat4ToU32(THEME.border), 2.0)

    imgui.PushFont(font_fa_large)
    local plus_icon = is_added and fa('check') or fa('plus')
    local psz = imgui.CalcTextSize(plus_icon)
    local p_col = is_added and THEME.accent_success or (is_active and THEME.accent_success or THEME.text_secondary)
    dl:AddText(imgui.ImVec2(plus_x + (plus_area_w - psz.x)/2, p.y + (h - psz.y)/2), imgui.ColorConvertFloat4ToU32(p_col), plus_icon)
    imgui.PopFont()

    local text_x = icon_x + icon_sz + 20.0
    imgui.PushFont(font_main)
    local name_str = u8(item.name)
    local text_y = p.y + (h - imgui.GetFontSize()) / 2
    
    dl:PushClipRect(imgui.ImVec2(text_x, p.y), imgui.ImVec2(plus_x - 15, p.y + h), true)
    
    if not is_sell and item.amount then
        dl:AddText(imgui.ImVec2(text_x, p.y + 20), imgui.ColorConvertFloat4ToU32(is_added and THEME.text_secondary or THEME.text_primary), name_str)
        dl:AddText(imgui.ImVec2(text_x, p.y + 48), imgui.ColorConvertFloat4ToU32(THEME.text_secondary), u8"В наличии: " .. item.amount)
    else
        dl:AddText(imgui.ImVec2(text_x, text_y), imgui.ColorConvertFloat4ToU32(THEME.text_primary), name_str)
    end
    
    dl:PopClipRect()
    imgui.PopFont()

    imgui.Dummy(imgui.ImVec2(0, 12))
end

local function renderTargetCard(item, is_sell, index, target_table)
    local w = imgui.GetContentRegionAvail().x
    local h = 95.0 
    local p = imgui.GetCursorScreenPos()
    local dl = imgui.GetWindowDrawList()

    imgui.SetCursorScreenPos(p)
    imgui.InvisibleButton("##tgt_"..tostring(is_sell).."_"..index, imgui.ImVec2(w, h))
    local is_active = imgui.IsItemActive()

    if imgui.IsItemHovered() and imgui.IsMouseReleased(0) and not touch_state.is_dragging then
        cfg_modal.active = true
        cfg_modal.item = item
        cfg_modal.index = index
        cfg_modal.is_sell = is_sell
        cfg_modal.target_table = target_table
        cfg_modal.auto_max = item.auto_max or false
        ffi.copy(cfg_modal.buf_price, tostring(item.price))
        ffi.copy(cfg_modal.buf_amount, tostring(item.amount or 1))
    end

    local bg_col = is_active and THEME.bg_tertiary or THEME.bg_secondary
    dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), imgui.ColorConvertFloat4ToU32(bg_col), 16.0)
    dl:AddRect(p, imgui.ImVec2(p.x + w, p.y + h), imgui.ColorConvertFloat4ToU32(THEME.border), 16.0, 15, 1.5)
    
    local accent = is_sell and THEME.accent_success or THEME.accent_primary
    dl:AddRectFilled(p, imgui.ImVec2(p.x + 8, p.y + h), imgui.ColorConvertFloat4ToU32(accent), 16.0, 9)

    local gear_area_w = 80.0
    local gear_x = p.x + w - gear_area_w
    dl:AddRectFilled(imgui.ImVec2(gear_x, p.y), imgui.ImVec2(p.x + w, p.y + h), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0,0,0,0.1)), 16.0, 6)
    dl:AddLine(imgui.ImVec2(gear_x, p.y), imgui.ImVec2(gear_x, p.y + h), imgui.ColorConvertFloat4ToU32(THEME.border), 2.0)

    imgui.PushFont(font_fa_large)
    local gear_icon = fa('gear')
    local gsz = imgui.CalcTextSize(gear_icon)
    dl:AddText(imgui.ImVec2(gear_x + (gear_area_w - gsz.x)/2, p.y + (h - gsz.y)/2), imgui.ColorConvertFloat4ToU32(is_active and THEME.text_primary or THEME.text_secondary), gear_icon)
    imgui.PopFont()

    local text_x = p.x + 25.0
    imgui.PushFont(font_main)
    local name_str = u8(item.name)
    
    dl:PushClipRect(imgui.ImVec2(text_x, p.y), imgui.ImVec2(gear_x - 15, p.y + h), true)
    dl:AddText(imgui.ImVec2(text_x, p.y + 20), imgui.ColorConvertFloat4ToU32(THEME.text_primary), name_str)
    dl:PopClipRect()

    local price_str = formatMoney(item.price) .. " $  •  " .. (item.amount or 1) .. " шт."
    dl:AddText(imgui.ImVec2(text_x, p.y + 48), imgui.ColorConvertFloat4ToU32(accent), price_str)
    imgui.PopFont()

    imgui.Dummy(imgui.ImVec2(0, 12))
end

local function renderUndoSnackbar()
    if #undo_stack == 0 then return end
    
    local now = os.clock()
    if now > undo_timer then
        undo_stack = {}
        return
    end

    local sw, sh = getScreenResolution()
    local last_deleted = undo_stack[#undo_stack]
    local name_short = last_deleted.item.name
    if #name_short > 20 then name_short = name_short:sub(1, 20) .. "..." end
    
    local text = u8"Удалено: " .. u8(name_short)
    local btn_text = u8"ВЕРНУТЬ"
    
    imgui.PushFont(font_main)
    local t_sz = imgui.CalcTextSize(text)
    local b_sz = imgui.CalcTextSize(btn_text)
    imgui.PopFont()

    local box_w = t_sz.x + b_sz.x + 80.0
    local box_h = 55.0
    local box_x = (sw - box_w) / 2
    local box_y = 60.0

    local alpha = 1.0
    local time_left = undo_timer - now
    if time_left < 0.5 then alpha = time_left * 2.0 end

    imgui.SetNextWindowPos(imgui.ImVec2(box_x, box_y), imgui.Cond.Always)
    imgui.SetNextWindowSize(imgui.ImVec2(box_w, box_h), imgui.Cond.Always)
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, box_h / 2)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.12, 0.12, 0.14, 0.95 * alpha))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(1, 1, 1, 0.1 * alpha))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 2.0)

    if imgui.Begin("##UndoSnackbar", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoSavedSettings) then
        local dl = imgui.GetWindowDrawList()
        
        imgui.PushFont(font_main)
        dl:AddText(imgui.ImVec2(box_x + 20.0, box_y + (box_h - t_sz.y)/2), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.8, 0.8, 0.8, alpha)), text)
        
        local btn_x = box_x + box_w - b_sz.x - 25.0
        
        imgui.SetCursorScreenPos(imgui.ImVec2(btn_x - 10.0, box_y))
        if imgui.InvisibleButton("##undo_btn", imgui.ImVec2(b_sz.x + 20.0, box_h)) then
            local target_list = (last_deleted.list == "sell") and config_sell or config_buy
            local target_index = math.min(last_deleted.index, #target_list + 1)
            
            table.insert(target_list, target_index, last_deleted.item)
            table.remove(undo_stack, #undo_stack)
            
            if last_deleted.list == "sell" then saveJsonFile(PATH_CFG_SELL, config_sell) else saveJsonFile(PATH_CFG_BUY, config_buy) end
        end
        
        local btn_col = imgui.IsItemActive() and THEME.text_primary or THEME.accent_primary
        dl:AddText(imgui.ImVec2(btn_x, box_y + (box_h - b_sz.y)/2), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(btn_col.x, btn_col.y, btn_col.z, alpha)), btn_text)
        imgui.PopFont()
    end
    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(3)
end

local function DrawStyledButton(id, label, w, h, col, icon, dl)
    local p = imgui.GetCursorScreenPos()
    local clicked = false
    if imgui.InvisibleButton(id, imgui.ImVec2(w, h)) then clicked = true end
    local active = imgui.IsItemActive()
    local bg = active and imgui.ImVec4(col.x*0.8, col.y*0.8, col.z*0.8, 1) or col
    dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), imgui.ColorConvertFloat4ToU32(bg), 12.0)
    
    local c_w = 0
    imgui.PushFont(font_fa)
    local i_sz = icon and imgui.CalcTextSize(icon) or imgui.ImVec2(0,0)
    imgui.PopFont()
    imgui.PushFont(font_main)
    local t_sz = imgui.CalcTextSize(label)
    imgui.PopFont()
    
    if icon then c_w = i_sz.x + 10 + t_sz.x else c_w = t_sz.x end
    local start_x = p.x + (w - c_w) / 2
    
    if icon then
        imgui.PushFont(font_fa)
        dl:AddText(imgui.ImVec2(start_x, p.y + (h - i_sz.y)/2), 0xFFFFFFFF, icon)
        imgui.PopFont()
        start_x = start_x + i_sz.x + 10
    end
    imgui.PushFont(font_main)
    dl:AddText(imgui.ImVec2(start_x, p.y + (h - t_sz.y)/2), 0xFFFFFFFF, label)
    imgui.PopFont()
    
    return clicked
end

imgui.OnFrame(
    function() return true end,
    function(this)
        pcall(renderLiveProfitHUD)
        pcall(renderUndoSnackbar)
        
        if show_update_window[0] then
            local sw, sh = getScreenResolution()
            local m_w = 480.0
            
            imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
            imgui.SetNextWindowSize(imgui.ImVec2(m_w, -1), imgui.Cond.Always)
            
            imgui.PushStyleColor(imgui.Col.WindowBg, THEME.bg_secondary)
            imgui.PushStyleColor(imgui.Col.Border, THEME.accent_primary)
            imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 24.0)
            imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 3.0)
            
            if imgui.Begin("##UpdateModal", show_update_window, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove + imgui.WindowFlags.AlwaysAutoResize) then
                local p = imgui.GetCursorScreenPos()
                local dl = imgui.GetWindowDrawList()
                
                local cur_y = p.y + 25
                
                imgui.PushFont(font_fa_large)
                local brand_ic = fa('store')
                local ic_sz = imgui.CalcTextSize(brand_ic)
                imgui.PopFont()
                
                imgui.PushFont(font_main)
                local brand_txt = " RMARKET"
                local txt_sz = imgui.CalcTextSize(brand_txt)
                
                local total_brand_w = ic_sz.x + txt_sz.x
                local brand_x = p.x + (m_w - total_brand_w) / 2
                
                imgui.PushFont(font_fa_large)
                dl:AddText(imgui.ImVec2(brand_x, cur_y), imgui.ColorConvertFloat4ToU32(THEME.accent_primary), brand_ic)
                imgui.PopFont()
                dl:AddText(imgui.ImVec2(brand_x + ic_sz.x, cur_y + (ic_sz.y - txt_sz.y)/2), 0xFFFFFFFF, brand_txt)
                
                cur_y = cur_y + ic_sz.y + 20
                dl:AddLine(imgui.ImVec2(p.x, cur_y), imgui.ImVec2(p.x + m_w, cur_y), imgui.ColorConvertFloat4ToU32(THEME.border), 2.0)
                
                cur_y = cur_y + 20
                
                local t_str = u8"ДОСТУПНО ОБНОВЛЕНИЕ"
                local t_sz = imgui.CalcTextSize(t_str)
                dl:AddText(imgui.ImVec2(p.x + (m_w - t_sz.x)/2, cur_y), imgui.ColorConvertFloat4ToU32(THEME.text_primary), t_str)
                
                cur_y = cur_y + t_sz.y + 8
                
                local v_str = u8"Новая версия: " .. State.update.version
                local v_sz = imgui.CalcTextSize(v_str)
                dl:AddText(imgui.ImVec2(p.x + (m_w - v_sz.x)/2, cur_y), imgui.ColorConvertFloat4ToU32(THEME.accent_success), v_str)
                
                cur_y = cur_y + v_sz.y + 35
                
                imgui.Dummy(imgui.ImVec2(0, cur_y - p.y))
                
                local btn_y = imgui.GetCursorScreenPos().y
                local btn_w = (m_w - 60) / 2
                local btn_h = 55.0
                
                local function drawUpdBtn(id, label, icon, bx, by, bw, color)
                    imgui.SetCursorScreenPos(imgui.ImVec2(bx, by))
                    local clicked = false
                    if imgui.InvisibleButton(id, imgui.ImVec2(bw, btn_h)) then clicked = true end
                    local bg = imgui.IsItemActive() and imgui.ImVec4(color.x*0.8, color.y*0.8, color.z*0.8, 1) or color
                    dl:AddRectFilled(imgui.ImVec2(bx, by), imgui.ImVec2(bx + bw, by + btn_h), imgui.ColorConvertFloat4ToU32(bg), 15.0)
                    
                    imgui.PushFont(font_fa_large)
                    local isz = imgui.CalcTextSize(icon)
                    imgui.PopFont()
                    
                    local tsz = imgui.CalcTextSize(u8(label))
                    local cx = bx + (bw - (isz.x + 15 + tsz.x))/2
                    
                    imgui.PushFont(font_fa_large)
                    dl:AddText(imgui.ImVec2(cx, by + (btn_h - isz.y)/2), 0xFFFFFFFF, icon)
                    imgui.PopFont()
                    dl:AddText(imgui.ImVec2(cx + isz.x + 15, by + (btn_h - tsz.y)/2), 0xFFFFFFFF, u8(label))
                    
                    return clicked
                end
                
                if drawUpdBtn("##btn_upd_later", "ПОЗЖЕ", fa('clock'), p.x + 20, btn_y, btn_w, THEME.bg_tertiary) then
                    show_update_window[0] = false
                end
                
                if drawUpdBtn("##btn_upd_now", "ОБНОВИТЬ", fa('download'), p.x + 20 + btn_w + 20, btn_y, btn_w, THEME.accent_success) then
                    show_update_window[0] = false
                    sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Начинаю загрузку обновления...", -1)
                    downloadScriptUpdate(State.update.url, thisScript().path, function(success, reason)
                        if success then
                            sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Обновление успешно загружено! Скрипт перезапускается...", -1)
                            thisScript():reload()
                        else
                            sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ошибка при скачивании: " .. tostring(reason), -1)
                        end
                    end)
                end
                
                imgui.Dummy(imgui.ImVec2(0, btn_h + 10))
                imgui.PopFont()
            end
            imgui.End()
            imgui.PopStyleVar(2)
            imgui.PopStyleColor(2)
        end
        
        local io = imgui.GetIO()
        local sw, sh = getScreenResolution()
        
        local btn_w, btn_h = 280, 65
        local padding = 20
        local win_w, win_h = btn_w + padding * 2, btn_h + padding * 2
        
        if Settings.rm_btn_x == nil then Settings.rm_btn_x = sw - win_w - 10 end
        if Settings.rm_btn_y == nil then Settings.rm_btn_y = sh / 2 - win_h / 2 end
        
        if Settings.show_float_btn then
            imgui.SetNextWindowPos(imgui.ImVec2(Settings.rm_btn_x, Settings.rm_btn_y), imgui.Cond.Always)
            imgui.SetNextWindowSize(imgui.ImVec2(win_w, win_h), imgui.Cond.Always)
            
            imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, btn_h / 2)
            imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
            imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0,0,0,0))
            imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0,0,0,0))
            imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 0.0)
            
            if imgui.Begin("##RMFloatingBtn", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoSavedSettings + imgui.WindowFlags.NoBackground) then
                local dl = imgui.GetWindowDrawList()
                local p = imgui.GetWindowPos()
                
                local c_x_start = p.x + padding
                local c_y_start = p.y + padding
                
                imgui.SetCursorScreenPos(imgui.ImVec2(c_x_start, c_y_start))
                if imgui.InvisibleButton("##rm_float_click", imgui.ImVec2(btn_w, btn_h)) then
                    win_state[0] = not win_state[0]
                end
                
                local is_active = imgui.IsItemActive()
                local is_hov = imgui.IsItemHovered()
                
                if is_active and imgui.IsMouseDragging(0) then
                    local delta = imgui.GetMouseDragDelta(0)
                    Settings.rm_btn_x = Settings.rm_btn_x + delta.x
                    Settings.rm_btn_y = Settings.rm_btn_y + delta.y
                    imgui.ResetMouseDragDelta(0)
                    saveJsonFile(PATH_SETTINGS, Settings)
                end
                
                local r = btn_h / 2
                local scale = is_active and 0.95 or 1.0
                local dw = (btn_w - (btn_w * scale)) / 2
                local dh = (btn_h - (btn_h * scale)) / 2
                local base_p = imgui.ImVec2(c_x_start + dw, c_y_start + dh)
                local base_sz = imgui.ImVec2(c_x_start + btn_w - dw, c_y_start + btn_h - dh)

                for i = 1, 8 do
                    local s_a = 0.20 - (i * 0.025)
                    dl:AddRectFilled(imgui.ImVec2(base_p.x - i, base_p.y - i + 2), imgui.ImVec2(base_sz.x + i, base_sz.y + i + 2), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(THEME.accent_primary.x, THEME.accent_primary.y, THEME.accent_primary.z, s_a)), r + i)
                end

                dl:AddRectFilled(base_p, base_sz, imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.08, 0.08, 0.1, 0.95)), r)
                
                local t = os.clock() * 1.5
                local pulse = (math.sin(t) + 1) * 0.5
                local pulse_color = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(THEME.accent_primary.x, THEME.accent_primary.y, THEME.accent_primary.z, 0.15 + pulse * 0.15))
                dl:AddRectFilled(base_p, base_sz, pulse_color, r)

                dl:AddRect(base_p, base_sz, imgui.ColorConvertFloat4ToU32(THEME.accent_primary), r, 15, 2.5)
                
                if is_hov then dl:AddRectFilled(base_p, base_sz, imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.08)), r) end
                
                imgui.PushFont(font_fa_large)
                local icon = fa('store')
                local isz = imgui.CalcTextSize(icon)
                imgui.PopFont()
                
                imgui.PushFont(font_main)
                local txt = u8"RMARKET"
                local tsz = imgui.CalcTextSize(txt)
                imgui.PopFont()

                local total_w = isz.x + 15 + tsz.x
                local cx = base_p.x + (btn_w * scale - total_w) / 2

                imgui.PushFont(font_fa_large)
                dl:AddText(imgui.ImVec2(cx, base_p.y + (btn_h * scale - isz.y)/2), imgui.ColorConvertFloat4ToU32(THEME.accent_primary), icon)
                imgui.PopFont()
                
                imgui.PushFont(font_main)
                dl:AddText(imgui.ImVec2(cx + isz.x + 15, base_p.y + (btn_h * scale - tsz.y)/2), 0xFFFFFFFF, txt)
                imgui.PopFont()
            end
            imgui.End()
            imgui.PopStyleVar(3)
            imgui.PopStyleColor(2)
        end
        
        if not (win_state[0] or State.inventory_scan.active or State.buying_scan.active or State.selling.active or State.buying.active) then return end
        
        local io = imgui.GetIO()
        local sw, sh = getScreenResolution()
        
        local win_w = sw * 0.98
        local win_h = sh * 0.90
        if win_w > 1300 then win_w = 1300 end

        if State.inventory_scan.active or State.buying_scan.active or State.selling.active or State.buying.active then
            local mod_w, mod_h = 460.0, 280.0
            imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
            imgui.SetNextWindowSize(imgui.ImVec2(mod_w, mod_h), imgui.Cond.Always)
            
            imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(THEME.bg_secondary.x, THEME.bg_secondary.y, THEME.bg_secondary.z, 0.98))
            imgui.PushStyleColor(imgui.Col.Border, THEME.accent_primary)
            imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 20.0)
            imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 2.0)
            
            if imgui.Begin("##ScanningModal", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove) then
                local p = imgui.GetCursorScreenPos()
                local dl = imgui.GetWindowDrawList()
                
                local title = ""
                local subtitle = ""
                local icon = fa('spinner')
                local is_waiting = false
                local items_count = 0
                local accent_color = THEME.accent_primary

                if State.inventory_scan.active then
                    accent_color = THEME.accent_success
                    icon = fa('box_open')
                    items_count = #inv_items
                    if State.inventory_scan.stage == "waiting_user" then
                        title = u8"Ожидание инвентаря"
                        subtitle = u8"Откройте инвентарь или\nвведите /rec для точного кол-ва"
                        is_waiting = true
                    elseif State.inventory_scan.stage == "settings" then
                        title = u8"Настройка инвентаря"
                        subtitle = u8"Подготовка интерфейса CEF..."
                    elseif State.inventory_scan.stage == "parsing" then
                        title = u8"Чтение предметов"
                        subtitle = u8"Сбор данных... Не закрывайте окно"
                    end
                elseif State.buying_scan.active then
                    icon = fa('shop')
                    items_count = #State.buying_scan.all_items
                    if State.buying_scan.stage == 'waiting_dialog' then
                        title = u8"Ожидание лавки"
                        subtitle = u8"Откройте диалоговое окно лавки"
                        is_waiting = true
                    elseif State.buying_scan.stage == 'waiting_category_menu' or State.buying_scan.stage == 'waiting_full_list_menu' then
                        title = u8"Навигация по меню"
                        subtitle = u8"Открываем полный список товаров..."
                    elseif State.buying_scan.stage == 'processing_page' then
                        title = u8"Сканирование товаров"
                        subtitle = u8"Считывание страницы: " .. State.buying_scan.current_page
                    elseif State.buying_scan.stage == 'closing' then
                        title = u8"Завершение"
                        subtitle = u8"Автоматическое закрытие диалогов..."
                    end
                elseif State.selling.active then
                    icon = fa('paper_plane')
                    items_count = State.selling.total
                    if State.selling.stage == 'waiting_dialog' then
                        title = u8"Ожидание лавки"
                        subtitle = u8"Откройте диалоговое окно лавки"
                        is_waiting = true
                    elseif State.selling.stage == 'waiting_cef' then
                        title = u8"Загрузка инвентаря"
                        subtitle = u8"Ожидание интерфейса лавки..."
                    elseif State.selling.stage == 'waiting_input' or State.selling.stage == 'next_item' then
                        title = u8"Выставление товаров"
                        local cur_name = State.selling.current_item and u8(State.selling.current_item.name) or u8"Товар"
                        subtitle = string.format(u8"Товар (%d из %d):\n%s", State.selling.current_idx, State.selling.total, cur_name)
                    elseif State.selling.stage == 'closing' then
                        title = u8"Завершение"
                        subtitle = u8"Закрываем окна..."
                    end
                elseif State.buying.active then
                    icon = fa('cart_arrow_down')
                    items_count = State.buying.total
                    if State.buying.stage == 'waiting_dialog' then
                        title = u8"Ожидание лавки"
                        subtitle = u8"Откройте диалоговое окно лавки"
                        is_waiting = true
                    elseif State.buying.stage == 'closing' then
                        title = u8"Завершение"
                        subtitle = u8"Закрываем окна..."
                    else
                        title = u8"Скупка товаров"
                        local cur_name = State.buying.current_item and u8(State.buying.current_item.name) or u8"Товар"
                        subtitle = string.format(u8"Товар (%d из %d):\n%s", State.buying.current_idx, State.buying.total, cur_name)
                    end
                end

                local icon_sz = 64.0
                local center_icon = imgui.ImVec2(p.x + mod_w/2, p.y + 55)

                dl:AddCircleFilled(center_icon, icon_sz/2, imgui.ColorConvertFloat4ToU32(THEME.bg_main))

                if is_waiting then
                    local pulse = (math.sin(os.clock() * 5) + 1) * 0.5
                    local radius = (icon_sz/2) + (pulse * 10)
                    dl:AddCircle(center_icon, radius, imgui.ColorConvertFloat4ToU32(imgui.ImVec4(accent_color.x, accent_color.y, accent_color.z, 0.5 - pulse*0.5)), 32, 2.0)
                else
                    local time = os.clock() * 3
                    local a_min = time
                    local a_max = time + math.pi * 1.2
                    dl:PathArcTo(center_icon, (icon_sz/2) + 6, a_min, a_max, 32)
                    dl:PathStroke(imgui.ColorConvertFloat4ToU32(accent_color), false, 4.0)
                end

                imgui.PushFont(font_fa_large)
                local isz = imgui.CalcTextSize(icon)
                dl:AddText(imgui.ImVec2(center_icon.x - isz.x/2, center_icon.y - isz.y/2), imgui.ColorConvertFloat4ToU32(accent_color), icon)
                imgui.PopFont()

                imgui.PushFont(font_main)
                
                local function drawCentered(text, y, col)
                    for line in text:gmatch("[^\r\n]+") do
                        local sz = imgui.CalcTextSize(line)
                        imgui.SetCursorScreenPos(imgui.ImVec2(p.x + (mod_w - sz.x)/2, y))
                        imgui.TextColored(col, line)
                        y = y + imgui.GetFontSize() + 4
                    end
                    return y
                end

                local title_y = drawCentered(title, p.y + 105, THEME.text_primary)
                local sub_y = drawCentered(subtitle, title_y + 4, THEME.text_secondary)
                
                if items_count > 0 then
                    local badge_txt = u8"Найдено товаров: " .. items_count
                    local bsz = imgui.CalcTextSize(badge_txt)
                    local bx = p.x + (mod_w - (bsz.x + 24))/2
                    local by = sub_y + 8
                    dl:AddRectFilled(imgui.ImVec2(bx, by), imgui.ImVec2(bx + bsz.x + 24, by + bsz.y + 12), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(accent_color.x, accent_color.y, accent_color.z, 0.2)), 8.0)
                    dl:AddText(imgui.ImVec2(bx + 12, by + 6), imgui.ColorConvertFloat4ToU32(accent_color), badge_txt)
                end
                
                imgui.PopFont()

                local btn_h = 45.0
                local btn_w = mod_w - 40.0
                local btn_y = p.y + mod_h - btn_h - 20.0
                local btn_x = p.x + 20.0

                imgui.SetCursorScreenPos(imgui.ImVec2(btn_x, btn_y))
                if imgui.InvisibleButton("##cancel_scan", imgui.ImVec2(btn_w, btn_h)) then
                    if State.inventory_scan.active then State.inventory_scan.active = false end
                    if State.buying_scan.active then stopBuyingScan() end
                    if State.buying.active then State.buying.active = false end
                    win_state[0] = true
                end

                local btn_active = imgui.IsItemActive()
                local c_bg = btn_active and imgui.ImVec4(THEME.accent_danger.x*0.8, THEME.accent_danger.y*0.8, THEME.accent_danger.z*0.8, 1) or THEME.bg_main
                
                dl:AddRectFilled(imgui.ImVec2(btn_x, btn_y), imgui.ImVec2(btn_x + btn_w, btn_y + btn_h), imgui.ColorConvertFloat4ToU32(c_bg), 12.0)
                dl:AddRect(imgui.ImVec2(btn_x, btn_y), imgui.ImVec2(btn_x + btn_w, btn_y + btn_h), imgui.ColorConvertFloat4ToU32(THEME.accent_danger), 12.0, 15, 1.5)

                imgui.PushFont(font_main)
                local c_txt = u8"ОТМЕНИТЬ СКАНИРОВАНИЕ"
                local csz = imgui.CalcTextSize(c_txt)
                dl:AddText(imgui.ImVec2(btn_x + (btn_w - csz.x)/2, btn_y + (btn_h - csz.y)/2), imgui.ColorConvertFloat4ToU32(THEME.accent_danger), c_txt)
                imgui.PopFont()
            end
            imgui.End()
            imgui.PopStyleVar(2)
            imgui.PopStyleColor(2)
            if not win_state[0] then return end
        end

        imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
        imgui.SetNextWindowSize(imgui.ImVec2(win_w, win_h), imgui.Cond.Always)
        local flags = imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoCollapse
        
        if imgui.Begin("RMarketMobile", win_state, flags) then
            local p = imgui.GetWindowPos()
            local dl = imgui.GetWindowDrawList()

            if cfg_modal.active then
                dl:AddRectFilled(p, imgui.ImVec2(p.x + win_w, p.y + win_h), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.05, 0.05, 0.07, 0.95)), 16.0)
                
                local m_w = win_w * 0.85
                if m_w > 700 then m_w = 700 end
                local m_h = 630.0
                local m_x = p.x + (win_w - m_w) / 2
                local m_y = p.y + (win_h - m_h) / 2
                
                dl:AddRectFilled(imgui.ImVec2(m_x, m_y), imgui.ImVec2(m_x + m_w, m_y + m_h), imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), 24.0)
                dl:AddRect(imgui.ImVec2(m_x, m_y), imgui.ImVec2(m_x + m_w, m_y + m_h), imgui.ColorConvertFloat4ToU32(THEME.accent_primary), 24.0, 15, 3.0)
                
                local cur_y = m_y + 25
                imgui.PushFont(font_fa_large)
                dl:AddText(imgui.ImVec2(m_x + 35, cur_y), imgui.ColorConvertFloat4ToU32(THEME.accent_primary), fa('sliders'))
                imgui.PopFont()
                
                imgui.PushFont(font_main)
                dl:AddText(imgui.ImVec2(m_x + 80, cur_y + 5), imgui.ColorConvertFloat4ToU32(THEME.text_secondary), u8"НАСТРОЙКИ ТОВАРА")
                cur_y = cur_y + 45
                dl:AddLine(imgui.ImVec2(m_x, cur_y), imgui.ImVec2(m_x + m_w, cur_y), imgui.ColorConvertFloat4ToU32(THEME.border), 2.0)
                
                cur_y = cur_y + 20
                local item_name = u8(cfg_modal.item.name)
                local n_sz = imgui.CalcTextSize(item_name)
                dl:AddText(imgui.ImVec2(m_x + (m_w - n_sz.x)/2, cur_y), imgui.ColorConvertFloat4ToU32(THEME.accent_success), item_name)
                
                cur_y = cur_y + 30
                local avg_txt = u8"Нет данных"
                if average_prices then
                    local clean_k = cleanItemName(cfg_modal.item.name)
                    if average_prices[clean_k] then
                        local p_val = cfg_modal.is_sell and average_prices[clean_k].sell or average_prices[clean_k].buy
                        if p_val and p_val > 0 then avg_txt = formatMoney(p_val) .. " $" end
                    end
                end
                local avg_u8 = u8"Средняя цена: " .. avg_txt
                local a_sz = imgui.CalcTextSize(avg_u8)
                dl:AddText(imgui.ImVec2(m_x + (m_w - a_sz.x)/2, cur_y), imgui.ColorConvertFloat4ToU32(THEME.text_secondary), avg_u8)

                cur_y = cur_y + 40
                local input_w = m_w - 60
                local input_x = m_x + 30
                
                dl:AddText(imgui.ImVec2(input_x + 5, cur_y), imgui.ColorConvertFloat4ToU32(THEME.text_primary), u8"Цена за 1 шт ($):")
                cur_y = cur_y + 30
                imgui.SetCursorScreenPos(imgui.ImVec2(input_x, cur_y))
                imgui.SetNextItemWidth(input_w)
                
                imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(25.0, 25.0))
                imgui.PushStyleColor(imgui.Col.FrameBg, THEME.bg_main)
                imgui.PushStyleColor(imgui.Col.Text, THEME.text_primary)
                imgui.InputText("##cfg_price", cfg_modal.buf_price, 32, imgui.InputTextFlags.CharsDecimal)
                
                cur_y = cur_y + 90
                local amt_label = cfg_modal.is_sell and u8"Количество:" or u8"Кол-во / Цвет (если аксессуар):"
                
                dl:AddText(imgui.ImVec2(input_x + 5, cur_y), imgui.ColorConvertFloat4ToU32(THEME.text_primary), amt_label)
                cur_y = cur_y + 30
                imgui.SetCursorScreenPos(imgui.ImVec2(input_x, cur_y))
                
                if cfg_modal.is_sell then
                    local max_btn_w = 120.0
                    local inp_w = input_w - max_btn_w - 15.0
                    
                    if cfg_modal.auto_max then
                        dl:AddRectFilled(imgui.ImVec2(input_x, cur_y), imgui.ImVec2(input_x + inp_w, cur_y + 70), imgui.ColorConvertFloat4ToU32(THEME.bg_main), 16.0)
                        local txt = u8"Все доступные"
                        local sz = imgui.CalcTextSize(txt)
                        dl:AddText(imgui.ImVec2(input_x + (inp_w - sz.x)/2, cur_y + (70 - sz.y)/2), imgui.ColorConvertFloat4ToU32(THEME.text_secondary), txt)
                    else
                        imgui.SetNextItemWidth(inp_w)
                        imgui.InputText("##cfg_amount", cfg_modal.buf_amount, 32, imgui.InputTextFlags.CharsDecimal)
                    end
                    
                    local max_x = input_x + inp_w + 15.0
                    imgui.SetCursorScreenPos(imgui.ImVec2(max_x, cur_y))
                    if imgui.InvisibleButton("##btn_max", imgui.ImVec2(max_btn_w, 70.0)) then cfg_modal.auto_max = not cfg_modal.auto_max end
                    
                    local max_bg = cfg_modal.auto_max and THEME.accent_success or THEME.bg_tertiary
                    if imgui.IsItemActive() then max_bg = imgui.ImVec4(max_bg.x*0.8, max_bg.y*0.8, max_bg.z*0.8, 1) end
                    dl:AddRectFilled(imgui.ImVec2(max_x, cur_y), imgui.ImVec2(max_x + max_btn_w, cur_y + 70), imgui.ColorConvertFloat4ToU32(max_bg), 16.0)
                    
                    imgui.PushFont(font_main)
                    local max_txt = "MAX"
                    local max_sz = imgui.CalcTextSize(max_txt)
                    dl:AddText(imgui.ImVec2(max_x + (max_btn_w - max_sz.x)/2, cur_y + (70 - max_sz.y)/2), imgui.ColorConvertFloat4ToU32(cfg_modal.auto_max and THEME.bg_main or THEME.text_primary), max_txt)
                    imgui.PopFont()
                else
                    imgui.SetNextItemWidth(input_w)
                    imgui.InputText("##cfg_amount", cfg_modal.buf_amount, 32, imgui.InputTextFlags.CharsDecimal)
                end
                
                imgui.PopStyleColor(2)
                imgui.PopStyleVar()
                imgui.PopFont()

                local btn_h = 75.0
                local btn_gap = 15.0
                local btn_y_1 = m_y + m_h - (btn_h * 2) - btn_gap - 25
                local btn_y_2 = m_y + m_h - btn_h - 25
                
                local function DrawModalBtn(id, label, icon, b_x, b_y, b_w, color)
                    imgui.SetCursorScreenPos(imgui.ImVec2(b_x, b_y))
                    local clicked = false
                    if imgui.InvisibleButton(id, imgui.ImVec2(b_w, btn_h)) then clicked = true end
                    local b_bg = imgui.IsItemActive() and imgui.ImVec4(color.x*0.8, color.y*0.8, color.z*0.8, 1) or color
                    dl:AddRectFilled(imgui.ImVec2(b_x, b_y), imgui.ImVec2(b_x + b_w, b_y + btn_h), imgui.ColorConvertFloat4ToU32(b_bg), 20.0)
                    imgui.PushFont(font_fa_large)
                    local isz = imgui.CalcTextSize(icon)
                    imgui.PopFont()
                    imgui.PushFont(font_main)
                    local tsz = imgui.CalcTextSize(u8(label))
                    local cx = b_x + (b_w - (isz.x + 15 + tsz.x))/2
                    imgui.PushFont(font_fa_large)
                    dl:AddText(imgui.ImVec2(cx, b_y + (btn_h - isz.y)/2), 0xFFFFFFFF, icon)
                    imgui.PopFont()
                    dl:AddText(imgui.ImVec2(cx + isz.x + 15, b_y + (btn_h - tsz.y)/2), 0xFFFFFFFF, u8(label))
                    imgui.PopFont()
                    return clicked
                end

                if DrawModalBtn("##m_save", "СОХРАНИТЬ", fa('check'), input_x, btn_y_1, input_w, THEME.accent_success) then
                    local new_price = tonumber(ffi.string(cfg_modal.buf_price)) or 1000
                    local new_amount = tonumber(ffi.string(cfg_modal.buf_amount)) or 1
                    cfg_modal.target_table[cfg_modal.index].price = new_price
                    cfg_modal.target_table[cfg_modal.index].amount = new_amount
                    if cfg_modal.is_sell then cfg_modal.target_table[cfg_modal.index].auto_max = cfg_modal.auto_max end
                    if cfg_modal.is_sell then saveJsonFile(PATH_CFG_SELL, config_sell) else saveJsonFile(PATH_CFG_BUY, config_buy) end
                    cfg_modal.active = false
                end
                
                local sub_w = (input_w - btn_gap) / 2
                if DrawModalBtn("##m_cancel", "ОТМЕНА", fa('xmark'), input_x, btn_y_2, sub_w, THEME.bg_tertiary) then cfg_modal.active = false end
                if DrawModalBtn("##m_del", "УДАЛИТЬ", fa('trash'), input_x + sub_w + btn_gap, btn_y_2, sub_w, THEME.accent_danger) then
                    local deleted_copy = {}
                    for k,v in pairs(cfg_modal.target_table[cfg_modal.index]) do deleted_copy[k] = v end
                    table.insert(undo_stack, { list = cfg_modal.is_sell and "sell" or "buy", index = cfg_modal.index, item = deleted_copy })
                    undo_timer = os.clock() + 5.0
                    table.remove(cfg_modal.target_table, cfg_modal.index)
                    if cfg_modal.is_sell then saveJsonFile(PATH_CFG_SELL, config_sell) else saveJsonFile(PATH_CFG_BUY, config_buy) end
                    cfg_modal.active = false
                end

            else

            local nav_w = 120.0
            local header_h = 100.0
            local footer_h = 120.0
            local c_x = p.x + nav_w
            local c_w = win_w - nav_w
            local content_y = p.y + header_h
            local content_h = win_h - header_h - footer_h

            dl:AddRectFilled(p, imgui.ImVec2(p.x + nav_w, p.y + win_h), imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), 16.0, 1 + 8)
            dl:AddLine(imgui.ImVec2(p.x + nav_w, p.y), imgui.ImVec2(p.x + nav_w, p.y + win_h), imgui.ColorConvertFloat4ToU32(THEME.border), 2.0)

            imgui.PushFont(font_fa_large)
            local code_ic = fa('code')
            local code_sz = imgui.CalcTextSize(code_ic)
            dl:AddText(imgui.ImVec2(p.x + (nav_w - code_sz.x)/2, p.y + 35), imgui.ColorConvertFloat4ToU32(THEME.accent_primary), code_ic)
            imgui.PopFont()

            local tab_h = 85.0
            local start_y = p.y + 110.0
            
            local function DrawNavTab(id, icon, y_offset)
                local is_sel = (active_tab == id)
                local t_p = imgui.ImVec2(p.x, start_y + y_offset)
                imgui.SetCursorScreenPos(t_p)
                if imgui.InvisibleButton("##tab_"..id, imgui.ImVec2(nav_w, tab_h)) then
                    active_tab = id
                    active_sub_tab = 1
                    if id == 5 and #StateMarket.shops_list == 0 then api_FetchMarketList() end
                end
                local bg = is_sel and THEME.bg_tertiary or (imgui.IsItemActive() and imgui.ImVec4(THEME.bg_tertiary.x, THEME.bg_tertiary.y, THEME.bg_tertiary.z, 0.5) or imgui.ImVec4(0,0,0,0))
                dl:AddRectFilled(t_p, imgui.ImVec2(t_p.x + nav_w, t_p.y + tab_h), imgui.ColorConvertFloat4ToU32(bg))
                if is_sel then dl:AddRectFilled(t_p, imgui.ImVec2(t_p.x + 6.0, t_p.y + tab_h), imgui.ColorConvertFloat4ToU32(THEME.accent_primary)) end
                
                local col = is_sel and THEME.accent_primary or THEME.text_secondary
                imgui.PushFont(font_fa_large)
                local isz = imgui.CalcTextSize(icon)
                dl:AddText(imgui.ImVec2(t_p.x + (nav_w - isz.x)/2, t_p.y + (tab_h - isz.y)/2), imgui.ColorConvertFloat4ToU32(col), icon)
                imgui.PopFont()
            end

            DrawNavTab(1, fa('arrow_up_from_bracket'), 0)
            DrawNavTab(2, fa('arrow_down_to_bracket'), tab_h)
            DrawNavTab(3, fa('file_lines'), tab_h * 2)
            DrawNavTab(4, fa('globe'), tab_h * 3)
            DrawNavTab(5, fa('bullhorn'), tab_h * 4)
            DrawNavTab(6, fa('gear'), tab_h * 5)

            local close_sz = 70.0
            local close_y = p.y + win_h - close_sz - 20.0
            imgui.SetCursorScreenPos(imgui.ImVec2(p.x + (nav_w - close_sz)/2, close_y))
            if imgui.InvisibleButton("##close_btn", imgui.ImVec2(close_sz, close_sz)) then win_state[0] = false end
            local c_col = imgui.IsItemActive() and THEME.accent_danger or THEME.text_secondary
            dl:AddRectFilled(imgui.ImVec2(p.x + (nav_w - close_sz)/2, close_y), imgui.ImVec2(p.x + (nav_w + close_sz)/2, close_y + close_sz), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1,1,1,0.05)), 16.0)
            imgui.PushFont(font_fa_large)
            local cxsz = imgui.CalcTextSize(fa('xmark'))
            dl:AddText(imgui.ImVec2(p.x + (nav_w - cxsz.x)/2, close_y + (close_sz - cxsz.y)/2), imgui.ColorConvertFloat4ToU32(c_col), fa('xmark'))
            imgui.PopFont()

            dl:AddRectFilled(imgui.ImVec2(c_x, p.y), imgui.ImVec2(p.x + win_w, p.y + header_h), imgui.ColorConvertFloat4ToU32(THEME.bg_main), 16.0, 2)
            dl:AddLine(imgui.ImVec2(c_x, p.y + header_h), imgui.ImVec2(p.x + win_w, p.y + header_h), imgui.ColorConvertFloat4ToU32(THEME.border), 2.0)

            local current_buf = search_buf_sell
            if active_tab == 2 then current_buf = search_buf_buy
            elseif active_tab == 4 then current_buf = search_buf_market end

            local search_w = c_w * 0.55
            local search_h = 65.0
            local search_x = c_x + 30.0
            local search_y = p.y + (header_h - search_h) / 2
            
            if active_tab ~= 3 and active_tab ~= 5 and active_tab ~= 6 then
                dl:AddRectFilled(imgui.ImVec2(search_x, search_y), imgui.ImVec2(search_x + search_w, search_y + search_h), imgui.ColorConvertFloat4ToU32(THEME.bg_tertiary), 22.0)
                dl:AddRect(imgui.ImVec2(search_x, search_y), imgui.ImVec2(search_x + search_w, search_y + search_h), imgui.ColorConvertFloat4ToU32(THEME.border), 22.0, 15, 2.0)
                
                imgui.PushFont(font_fa_large)
                local search_icon = fa('magnifying_glass')
                local sisz = imgui.CalcTextSize(search_icon)
                dl:AddText(imgui.ImVec2(search_x + 25, search_y + (search_h - sisz.y)/2), imgui.ColorConvertFloat4ToU32(THEME.text_secondary), search_icon)
                imgui.PopFont()
     
                imgui.SetCursorScreenPos(imgui.ImVec2(search_x + 70, search_y))
                imgui.SetNextItemWidth(search_w - 90)
                imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0,0,0,0))
                imgui.PushStyleColor(imgui.Col.Text, THEME.text_primary)
                imgui.PushFont(font_main)
                imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(0, (search_h - imgui.GetFontSize()) / 2))
                local hint_text = active_tab == 1 and u8"Поиск в инвентаре..." or (active_tab == 4 and u8"Поиск лавки или товара..." or u8"Поиск товара...")
                imgui.InputTextWithHint("##search_bar", hint_text, current_buf, 128)
                imgui.PopStyleVar()
                imgui.PopFont()
                imgui.PopStyleColor(2)
            else
                imgui.PushFont(font_main)
                local title_text = ""
                if active_tab == 3 then title_text = u8"ИСТОРИЯ СДЕЛОК"
                elseif active_tab == 5 then title_text = u8"АВТОМАТИЧЕСКИЙ ПИАР"
                elseif active_tab == 6 then title_text = u8"НАСТРОЙКИ RMARKET" end
                local title_sz = imgui.CalcTextSize(title_text)
                dl:AddText(imgui.ImVec2(c_x + 40, p.y + (header_h - title_sz.y)/2), imgui.ColorConvertFloat4ToU32(THEME.text_primary), title_text)
                imgui.PopFont()
            end

            local btn_sz = 65.0
            local right_cursor = p.x + win_w - btn_sz - 30.0
            local top_btn_y = p.y + (header_h - btn_sz) / 2

            if active_tab == 4 then
                local srv_names = {"Все серверы"}
                for _, srv in ipairs(RODINA_SERVERS_DATA) do table.insert(srv_names, srv.name) end
                local filter_w = 250.0
                right_cursor = right_cursor - filter_w + btn_sz
                imgui.SetCursorScreenPos(imgui.ImVec2(right_cursor, top_btn_y))
                local current_srv_name = srv_names[StateMarket.server_filter_idx + 1]
                if DrawStyledButton("##srv_filter_hdr", u8(current_srv_name), filter_w, btn_sz, THEME.bg_tertiary, fa('server'), dl) then imgui.OpenPopup("ServerFilterPopupHeaderMobile") end
                imgui.SetNextWindowPos(imgui.ImVec2(right_cursor, top_btn_y + btn_sz + 10))
                imgui.PushStyleColor(imgui.Col.PopupBg, THEME.bg_secondary)
                if imgui.BeginPopup("ServerFilterPopupHeaderMobile") then
                    imgui.PushFont(font_main)
                    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(15, 25))
                    for i, name in ipairs(srv_names) do
                        if imgui.Selectable(u8(name)) then
                            StateMarket.server_filter_idx = i - 1
                            search_buf_market[0] = 0
                        end
                    end
                    imgui.PopStyleVar()
                    imgui.PopFont()
                    imgui.EndPopup()
                end
                imgui.PopStyleColor()
            end

            if active_tab == 1 or active_tab == 2 then
                imgui.SetCursorScreenPos(imgui.ImVec2(right_cursor, top_btn_y))
                if imgui.InvisibleButton("##scan_btn", imgui.ImVec2(btn_sz, btn_sz)) then
                    if active_tab == 1 then startInventoryScan() else
                        State.buying_scan = {active=true, stage='waiting_dialog', current_page=1, all_items={}, current_dialog_id=nil}
                        sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Подойдите к лавке и нажмите кнопку взаимодействия!", -1)
                    end
                    win_state[0] = false
                end
                local scan_hov = imgui.IsItemHovered()
                local scan_icon = active_tab == 1 and fa('magnifying_glass') or fa('bag_shopping')
                local scan_col = active_tab == 1 and THEME.accent_success or THEME.accent_primary
                if imgui.IsItemActive() then dl:AddCircleFilled(imgui.ImVec2(right_cursor + btn_sz/2, top_btn_y + btn_sz/2), btn_sz/2, imgui.ColorConvertFloat4ToU32(imgui.ImVec4(scan_col.x, scan_col.y, scan_col.z, 0.3))) end
                imgui.PushFont(font_fa_large)
                local sx_sz = imgui.CalcTextSize(scan_icon)
                dl:AddText(imgui.ImVec2(right_cursor + (btn_sz - sx_sz.x)/2, top_btn_y + (btn_sz - sx_sz.y)/2), imgui.ColorConvertFloat4ToU32(scan_hov and THEME.text_primary or scan_col), scan_icon)
                imgui.PopFont()
                
                if active_tab == 1 then
                    right_cursor = right_cursor - btn_sz - 20.0
                    imgui.SetCursorScreenPos(imgui.ImVec2(right_cursor, top_btn_y))
                    if imgui.InvisibleButton("##dl_prices_btn", imgui.ImVec2(btn_sz, btn_sz)) then api_DownloadAveragePrices() end
                    local p_col = imgui.ImVec4(0.2, 0.6, 0.9, 1.0)
                    if imgui.IsItemActive() then dl:AddCircleFilled(imgui.ImVec2(right_cursor + btn_sz/2, top_btn_y + btn_sz/2), btn_sz/2, imgui.ColorConvertFloat4ToU32(imgui.ImVec4(p_col.x, p_col.y, p_col.z, 0.3))) end
                    imgui.PushFont(font_fa_large)
                    local px_sz = imgui.CalcTextSize(fa('cloud_arrow_down'))
                    dl:AddText(imgui.ImVec2(right_cursor + (btn_sz - px_sz.x)/2, top_btn_y + (btn_sz - px_sz.y)/2), imgui.ColorConvertFloat4ToU32(imgui.IsItemHovered() and THEME.text_primary or p_col), fa('cloud_arrow_down'))
                    imgui.PopFont()
                end
            end

            local scroll_w = 90.0
            local list_w = c_w - scroll_w - 50.0
            local list_x = c_x + 30.0

            local function DrawScrollZone(id, x, y, w, h)
                imgui.SetCursorScreenPos(imgui.ImVec2(x, y))
                imgui.InvisibleButton(id, imgui.ImVec2(w, h))
                local active = imgui.IsItemActive()
                local bg_col = active and imgui.ImVec4(THEME.accent_primary.x, THEME.accent_primary.y, THEME.accent_primary.z, 0.4) or imgui.ImVec4(THEME.bg_secondary.x, THEME.bg_secondary.y, THEME.bg_secondary.z, 0.8)
                dl:AddRectFilled(imgui.ImVec2(x, y), imgui.ImVec2(x + w, y + h), imgui.ColorConvertFloat4ToU32(bg_col), 24.0)
                dl:AddRect(imgui.ImVec2(x, y), imgui.ImVec2(x + w, y + h), imgui.ColorConvertFloat4ToU32(THEME.border), 24.0, 15, 2.0)
                imgui.PushFont(font_fa_large)
                local icon = fa('arrows_up_down')
                local isz = imgui.CalcTextSize(icon)
                dl:AddText(imgui.ImVec2(x + (w - isz.x)/2, y + (h - isz.y)/2), imgui.ColorConvertFloat4ToU32(active and THEME.text_primary or THEME.text_secondary), icon)
                imgui.PopFont()
                return active and io.MouseDelta.y * 1.5 or 0
            end

            local current_search_str = to_lower(u8:decode(ffi.string(current_buf)))
            local function CenterText(text, color, max_w)
                local t_sz = imgui.CalcTextSize(text)
                imgui.SetCursorPosX((max_w - t_sz.x) / 2)
                imgui.TextColored(color, text)
            end

            if active_tab == 1 or active_tab == 2 then
                local seg_w = list_w
                local seg_h = 85.0
                local seg_y = content_y + 20.0
                
                dl:AddRectFilled(imgui.ImVec2(list_x, seg_y), imgui.ImVec2(list_x + seg_w, seg_y + seg_h), imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), 24.0)
                dl:AddRect(imgui.ImVec2(list_x, seg_y), imgui.ImVec2(list_x + seg_w, seg_y + seg_h), imgui.ColorConvertFloat4ToU32(THEME.border), 24.0, 15, 2.0)

                local half_w = seg_w / 2
                local function DrawSegBtn(id, label, icon, is_left)
                    local b_x = is_left and list_x or (list_x + half_w)
                    imgui.SetCursorScreenPos(imgui.ImVec2(b_x, seg_y))
                    if imgui.InvisibleButton("##seg_"..id, imgui.ImVec2(half_w, seg_h)) then active_sub_tab = id end
                    local is_act = (active_sub_tab == id)
                    if is_act then
                        dl:AddRectFilled(imgui.ImVec2(b_x + 8, seg_y + 8), imgui.ImVec2(b_x + half_w - 8, seg_y + seg_h - 8), imgui.ColorConvertFloat4ToU32(THEME.bg_tertiary), 18.0)
                        dl:AddRect(imgui.ImVec2(b_x + 8, seg_y + 8), imgui.ImVec2(b_x + half_w - 8, seg_y + seg_h - 8), imgui.ColorConvertFloat4ToU32(active_tab == 1 and THEME.accent_success or THEME.accent_primary), 18.0, 15, 3.0)
                    end
                    imgui.PushFont(font_fa_large)
                    local isz = imgui.CalcTextSize(icon)
                    imgui.PopFont()
                    imgui.PushFont(font_main)
                    local tsz = imgui.CalcTextSize(u8(label))
                    imgui.PopFont()
                    local cnt_w = isz.x + 20 + tsz.x
                    local cnt_x = b_x + (half_w - cnt_w)/2
                    local col = is_act and THEME.text_primary or THEME.text_secondary
                    imgui.PushFont(font_fa_large)
                    dl:AddText(imgui.ImVec2(cnt_x, seg_y + (seg_h - isz.y)/2), imgui.ColorConvertFloat4ToU32(col), icon)
                    imgui.PopFont()
                    imgui.PushFont(font_main)
                    dl:AddText(imgui.ImVec2(cnt_x + isz.x + 20, seg_y + (seg_h - tsz.y)/2), imgui.ColorConvertFloat4ToU32(col), u8(label))
                    imgui.PopFont()
                end
                
                DrawSegBtn(1, active_tab == 1 and "ИНВЕНТАРЬ ИГРОКА" or "БАЗА ТОВАРОВ", fa('database'), true)
                local tgt_count = #(active_tab == 1 and config_sell or config_buy)
                DrawSegBtn(2, (active_tab == 1 and "СПИСОК НА ПРОДАЖУ (" or "СПИСОК НА СКУПКУ (") .. tgt_count .. ")", fa('list_check'), false)

                local actual_list_y = seg_y + seg_h + 25.0
                local actual_list_h = content_h - (seg_h + 45.0)

                local delta = DrawScrollZone("##main_scroll", list_x + list_w + 20, actual_list_y, scroll_w, actual_list_h)

                imgui.SetCursorScreenPos(imgui.ImVec2(list_x, actual_list_y))
                imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0,0,0,0))
                if imgui.BeginChild("MainList", imgui.ImVec2(list_w, actual_list_h), false, imgui.WindowFlags.NoScrollbar) then
                    local c_pos = imgui.GetWindowPos()
                    local c_size = imgui.GetWindowSize()
                    dl:PushClipRect(c_pos, imgui.ImVec2(c_pos.x + c_size.x, c_pos.y + c_size.y), true)
                    if delta ~= 0 then imgui.SetScrollY(imgui.GetScrollY() - delta) end
                    
                    if active_sub_tab == 1 then
                        local source_items = active_tab == 1 and inv_items or db_items
                        local target_config = active_tab == 1 and config_sell or config_buy
                        local cache = active_tab == 1 and ui_cache_sell or ui_cache_buy

                        if cache.query ~= current_search_str then
                            cache.query = current_search_str
                            if search_thread_1 then search_thread_1:terminate() end
                            search_thread_1 = lua_thread.create(function()
                                local temp = {}
                                for i, item in ipairs(source_items) do
                                    local item_name_lower = to_lower(item.name)
                                    local score = SmartSearch.getMatchScore(current_search_str, item_name_lower)
                                    if current_search_str == "" or score > 0 then
                                        table.insert(temp, { data = item, original_index = i, score = score })
                                    end
                                    if i % 50 == 0 then wait(0) end 
                                end
                                if current_search_str ~= "" then table.sort(temp, function(a, b) return a.score > b.score end) end
                                cache.items = temp
                            end)
                        end
                        
                        if search_thread_1 and search_thread_1:status() ~= "dead" then
                            imgui.PushFont(font_main)
                            imgui.Dummy(imgui.ImVec2(0, 50))
                            CenterText(u8"Поиск...", THEME.accent_primary, list_w)
                            imgui.PopFont()
                        elseif cache.items and #cache.items > 0 then
                            local clipper = imgui.ImGuiListClipper(#cache.items)
                            while clipper:Step() do
                                for i = clipper.DisplayStart + 1, clipper.DisplayEnd do
                                    local entry = cache.items[i]
                                    renderSourceCard(entry.data, (active_tab == 1), entry.original_index, target_config)
                                end
                            end
                        else
                            imgui.PushFont(font_main)
                            imgui.Dummy(imgui.ImVec2(0, 50))
                            CenterText(u8"Товары не найдены", THEME.text_secondary, list_w)
                            imgui.PopFont()
                        end
                    else
                        local target_config = active_tab == 1 and config_sell or config_buy
                        if #target_config == 0 then
                            imgui.PushFont(font_main)
                            imgui.Dummy(imgui.ImVec2(0, 50))
                            CenterText(u8"Список пуст. Перейдите в базу для добавления.", THEME.text_secondary, list_w)
                            imgui.PopFont()
                        else
                            for i, item in ipairs(target_config) do
                                renderTargetCard(item, (active_tab == 1), i, target_config)
                            end
                        end
                    end
                    dl:PopClipRect()
                end
                imgui.EndChild()
                imgui.PopStyleColor()

            elseif active_tab == 3 then
                if LogsState.logs_current_date_idx == 0 then
                    refreshLogDates()
                    LogsState.cached_income, LogsState.cached_expense = updateLogView()
                    LogsState.logs_current_date_idx = 1
                end

                local delta = DrawScrollZone("##scroll_logs", list_x + list_w + 20, content_y + 20, scroll_w, content_h - 40)

                imgui.SetCursorScreenPos(imgui.ImVec2(list_x, content_y + 20))
                imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0,0,0,0))
                if imgui.BeginChild("LogsChild", imgui.ImVec2(list_w, content_h - 40), false, imgui.WindowFlags.NoScrollbar) then
                    local c_pos = imgui.GetWindowPos()
                    local c_size = imgui.GetWindowSize()
                    dl:PushClipRect(c_pos, imgui.ImVec2(c_pos.x + c_size.x, c_pos.y + c_size.y), true)
                    if delta ~= 0 then imgui.SetScrollY(imgui.GetScrollY() - delta) end
                    
                    imgui.PushFont(font_main)
                    local stat_card_w = (list_w - 40) / 3
                    local stat_card_h = 100.0
                    
                    local function drawStatCard(x, y, label, val, color)
                        dl:AddRectFilled(imgui.ImVec2(x, y), imgui.ImVec2(x + stat_card_w, y + stat_card_h), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(color.x, color.y, color.z, 0.2)), 20.0)
                        dl:AddRect(imgui.ImVec2(x, y), imgui.ImVec2(x + stat_card_w, y + stat_card_h), imgui.ColorConvertFloat4ToU32(color), 20.0, 15, 2.0)
                        dl:AddText(imgui.ImVec2(x + 25, y + 20), imgui.ColorConvertFloat4ToU32(THEME.text_secondary), u8(label))
                        dl:AddText(imgui.ImVec2(x + 25, y + 55), imgui.ColorConvertFloat4ToU32(THEME.text_primary), formatMoney(val) .. " $")
                    end

                    local profit = LogsState.cached_income - LogsState.cached_expense
                    local profit_col = profit >= 0 and THEME.accent_success or THEME.accent_danger
                    drawStatCard(c_pos.x, c_pos.y, "Доход", LogsState.cached_income, THEME.accent_success)
                    drawStatCard(c_pos.x + stat_card_w + 20, c_pos.y, "Расход", LogsState.cached_expense, THEME.accent_primary)
                    drawStatCard(c_pos.x + stat_card_w*2 + 40, c_pos.y, "Прибыль", profit, profit_col)
                    
                    imgui.Dummy(imgui.ImVec2(0, stat_card_h + 30))
                    
                    local filters_y = c_pos.y + stat_card_h + 40
                    imgui.SetCursorScreenPos(imgui.ImVec2(c_pos.x, filters_y))
                    
                    if imgui.Checkbox(u8"Продажи", log_filters.show_sales) then LogsState.cached_income, LogsState.cached_expense = updateLogView() end
                    imgui.SameLine(0, 50)
                    if imgui.Checkbox(u8"Покупки", log_filters.show_purchases) then LogsState.cached_income, LogsState.cached_expense = updateLogView() end
                    
                    imgui.SameLine(0, 80)
                    local combo_w = 400.0
                    local combo_h = 60.0
                    local combo_x = imgui.GetCursorScreenPos().x
                    local combo_y = filters_y - 15
                    
                    if DrawStyledButton("##date_combo_btn", LogsState.logs_dates_cache[LogsState.logs_current_date_idx] or u8"Выберите дату", combo_w, combo_h, THEME.bg_tertiary, fa('calendar_days'), dl) then imgui.OpenPopup("DateFilterPopupMobile") end
                    imgui.SetNextWindowPos(imgui.ImVec2(combo_x, combo_y + combo_h + 10))
                    imgui.PushStyleColor(imgui.Col.PopupBg, THEME.bg_secondary)
                    if imgui.BeginPopup("DateFilterPopupMobile") then
                        imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(15, 25))
                        for i, date_str in ipairs(LogsState.logs_dates_cache) do
                            if imgui.Selectable(date_str, LogsState.logs_current_date_idx == i) then
                                LogsState.logs_current_date_idx = i
                                LogsState.cached_income, LogsState.cached_expense = updateLogView()
                            end
                        end
                        imgui.PopStyleVar()
                        imgui.EndPopup()
                    end
                    imgui.PopStyleColor()
                    
                    imgui.Dummy(imgui.ImVec2(0, 30))
                    dl:AddLine(imgui.ImVec2(c_pos.x, imgui.GetCursorScreenPos().y), imgui.ImVec2(c_pos.x + list_w, imgui.GetCursorScreenPos().y), imgui.ColorConvertFloat4ToU32(THEME.border), 2.0)
                    imgui.Dummy(imgui.ImVec2(0, 20))
                    
                    if #LogsState.current_view_logs == 0 then
                        imgui.Dummy(imgui.ImVec2(0, 50))
                        CenterText(u8"Нет операций за эту дату", THEME.text_secondary, list_w)
                    else
                        for i, log in ipairs(LogsState.current_view_logs) do
                            local item_p = imgui.GetCursorScreenPos()
                            local item_h = 100.0
                            local is_sale = log.type == "sale"
                            local acc_col = is_sale and THEME.accent_success or THEME.accent_primary
                            
                            dl:AddRectFilled(item_p, imgui.ImVec2(item_p.x + list_w, item_p.y + item_h), imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), 16.0)
                            dl:AddRectFilled(item_p, imgui.ImVec2(item_p.x + 10, item_p.y + item_h), imgui.ColorConvertFloat4ToU32(acc_col), 16.0, 9)
                            
                            imgui.PushFont(font_fa_large)
                            local ic = is_sale and fa('arrow_up_from_bracket') or fa('cart_shopping')
                            dl:AddText(imgui.ImVec2(item_p.x + 30, item_p.y + (item_h - 28)/2), imgui.ColorConvertFloat4ToU32(acc_col), ic)
                            imgui.PopFont()
                            
                            dl:PushClipRect(imgui.ImVec2(item_p.x + 85, item_p.y), imgui.ImVec2(item_p.x + list_w - 250, item_p.y + item_h), true)
                            dl:AddText(imgui.ImVec2(item_p.x + 85, item_p.y + 20), imgui.ColorConvertFloat4ToU32(THEME.text_primary), u8(log.item))
                            local meta_str = string.format("%s | %s", log.player or "Игрок", log.date:match("%d%d:%d%d:%d%d") or "")
                            dl:AddText(imgui.ImVec2(item_p.x + 85, item_p.y + 55), imgui.ColorConvertFloat4ToU32(THEME.text_secondary), u8(meta_str))
                            dl:PopClipRect()
                            
                            local total_str = formatMoney(log.total) .. " $"
                            local t_sz = imgui.CalcTextSize(total_str)
                            dl:AddText(imgui.ImVec2(item_p.x + list_w - t_sz.x - 30, item_p.y + 20), imgui.ColorConvertFloat4ToU32(acc_col), total_str)
                            
                            local details = log.amount > 1 and string.format("%d шт. x %s", log.amount, formatMoney(log.price)) or "1 шт."
                            local d_sz = imgui.CalcTextSize(details)
                            dl:AddText(imgui.ImVec2(item_p.x + list_w - d_sz.x - 30, item_p.y + 55), imgui.ColorConvertFloat4ToU32(THEME.text_secondary), u8(details))
                            
                            imgui.Dummy(imgui.ImVec2(0, item_h + 20))
                        end
                    end
                    imgui.PopFont()
                    dl:PopClipRect()
                end
                imgui.EndChild()
                imgui.PopStyleColor()

            elseif active_tab == 4 then
                local m_delta = DrawScrollZone("##scroll_market", list_x + list_w + 20, content_y + 20, scroll_w, content_h - 40)

                imgui.SetCursorScreenPos(imgui.ImVec2(list_x, content_y + 20))
                imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0,0,0,0))
                if imgui.BeginChild("MarketChild", imgui.ImVec2(list_w, content_h - 40), false, imgui.WindowFlags.NoScrollbar) then
                    local c_pos = imgui.GetWindowPos()
                    local c_size = imgui.GetWindowSize()
                    dl:PushClipRect(c_pos, imgui.ImVec2(c_pos.x + c_size.x, c_pos.y + c_size.y), true)
                    
                    if m_delta ~= 0 then imgui.SetScrollY(imgui.GetScrollY() - m_delta) end
                    
                    if StateMarket.is_loading then
                        imgui.Dummy(imgui.ImVec2(0, 50))
                        CenterText(u8"Загрузка лавок с сервера...", THEME.accent_primary, list_w)
                    elseif StateMarket.selected_shop then
                        local shop = StateMarket.selected_shop
                        imgui.PushFont(font_main)
                        
                        local top_bar_h = 70.0
                        if DrawStyledButton("##mkt_back", u8"НАЗАД", 250, top_bar_h, THEME.bg_tertiary, fa('arrow_left'), dl) then StateMarket.selected_shop = nil end
                        imgui.SameLine(nil, 30)
                        
                        local gps_btn_col = StateMarket.gps_active and THEME.bg_tertiary or THEME.accent_primary
                        local gps_btn_txt = StateMarket.gps_active and u8"Поиск..." or u8"МЕТКА НА ЛАВКУ"
                        if DrawStyledButton("##mkt_gps", gps_btn_txt, 350, top_bar_h, gps_btn_col, fa('location_dot'), dl) then
                            if not StateMarket.gps_active then
                                StateMarket.gps_active = true
                                StateMarket.gps_target = shop.nickname:gsub(" ", "_")
                                sampSendChat("/id " .. StateMarket.gps_target)
                                sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Поиск игрока " .. StateMarket.gps_target .. "...", -1)
                            end
                        end
                        
                        imgui.Dummy(imgui.ImVec2(0, 30))
                        local srv_name = getServerDisplayName(shop.serverId)
                        
                        if shop.vip then
                            imgui.PushFont(font_fa_large)
                            imgui.TextColored(imgui.ImVec4(1.0, 0.84, 0.0, 1.0), fa('crown'))
                            imgui.PopFont()
                            imgui.SameLine(nil, 15)
                        end
                        imgui.SetCursorPosY(imgui.GetCursorPosY() + 5)
                        imgui.TextColored(shop.vip and imgui.ImVec4(1.0, 0.84, 0.0, 1.0) or THEME.text_primary, u8(shop.nickname .. " | " .. srv_name))
                        imgui.Dummy(imgui.ImVec2(0, 20))
                        
                        if not StateMarket.details_tab then StateMarket.details_tab = 1 end
                        local d_tab_w = list_w / 2
                        local d_tab_h = 80.0
                        local d_p = imgui.GetCursorScreenPos()
                        
                        imgui.SetCursorScreenPos(d_p)
                        if imgui.InvisibleButton("##d_tab_sell", imgui.ImVec2(d_tab_w, d_tab_h)) then StateMarket.details_tab = 1 end
                        local is_s_act = StateMarket.details_tab == 1
                        dl:AddRectFilled(d_p, imgui.ImVec2(d_p.x + d_tab_w, d_p.y + d_tab_h), imgui.ColorConvertFloat4ToU32(is_s_act and THEME.bg_tertiary or THEME.bg_secondary), 20.0, 1 + 2)
                        local s_txt = u8("В ПРОДАЖЕ (" .. #shop.sell_list .. ")")
                        local s_sz = imgui.CalcTextSize(s_txt)
                        dl:AddText(imgui.ImVec2(d_p.x + (d_tab_w - s_sz.x)/2, d_p.y + (d_tab_h - s_sz.y)/2), imgui.ColorConvertFloat4ToU32(is_s_act and THEME.text_primary or THEME.text_secondary), s_txt)
                        if is_s_act then dl:AddRectFilled(imgui.ImVec2(d_p.x, d_p.y + d_tab_h - 8.0), imgui.ImVec2(d_p.x + d_tab_w, d_p.y + d_tab_h), imgui.ColorConvertFloat4ToU32(THEME.accent_success)) end
                        
                        imgui.SetCursorScreenPos(imgui.ImVec2(d_p.x + d_tab_w, d_p.y))
                        if imgui.InvisibleButton("##d_tab_buy", imgui.ImVec2(d_tab_w, d_tab_h)) then StateMarket.details_tab = 2 end
                        local is_b_act = StateMarket.details_tab == 2
                        dl:AddRectFilled(imgui.ImVec2(d_p.x + d_tab_w, d_p.y), imgui.ImVec2(d_p.x + list_w, d_p.y + d_tab_h), imgui.ColorConvertFloat4ToU32(is_b_act and THEME.bg_tertiary or THEME.bg_secondary), 20.0, 4 + 8)
                        local b_txt = u8("В СКУПКЕ (" .. #shop.buy_list .. ")")
                        local b_sz = imgui.CalcTextSize(b_txt)
                        dl:AddText(imgui.ImVec2(d_p.x + d_tab_w + (d_tab_w - b_sz.x)/2, d_p.y + (d_tab_h - b_sz.y)/2), imgui.ColorConvertFloat4ToU32(is_b_act and THEME.text_primary or THEME.text_secondary), b_txt)
                        if is_b_act then dl:AddRectFilled(imgui.ImVec2(d_p.x + d_tab_w, d_p.y + d_tab_h - 8.0), imgui.ImVec2(d_p.x + list_w, d_p.y + d_tab_h), imgui.ColorConvertFloat4ToU32(THEME.accent_primary)) end

                        imgui.SetCursorScreenPos(imgui.ImVec2(d_p.x, d_p.y + d_tab_h + 30))
                        
                        local current_list = StateMarket.details_tab == 1 and shop.sell_list or shop.buy_list
                        local is_sell = StateMarket.details_tab == 1
                        
                        if #current_list == 0 then
                            imgui.Dummy(imgui.ImVec2(0, 50))
                            CenterText(u8"В этой категории товаров нет.", THEME.text_secondary, list_w)
                        else
                            local cols = 2
                            local spacing = 25.0
                            local card_w = (list_w - spacing * (cols - 1)) / cols
                            local card_h = 120.0
                            local start_pos = imgui.GetCursorScreenPos()
                            
                            local total_rows = math.ceil(#current_list / cols)
                            local clipper = imgui.ImGuiListClipper(total_rows)
                            while clipper:Step() do
                                for row = clipper.DisplayStart, clipper.DisplayEnd - 1 do
                                    for col = 0, cols - 1 do
                                        local i = row * cols + col + 1
                                        if i > #current_list then break end
                                        local item = current_list[i]
                                        local cx = start_pos.x + col * (card_w + spacing)
                                        local cy = start_pos.y + row * (card_h + spacing)
                                        
                                        dl:AddRectFilled(imgui.ImVec2(cx, cy), imgui.ImVec2(cx + card_w, cy + card_h), imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), 20.0)
                                        dl:AddRectFilled(imgui.ImVec2(cx, cy), imgui.ImVec2(cx + 10, cy + card_h), imgui.ColorConvertFloat4ToU32(is_sell and THEME.accent_success or THEME.accent_primary), 20.0, 9)
                                        
                                        local icon_sz = 60.0
                                        dl:AddCircleFilled(imgui.ImVec2(cx + 30 + icon_sz/2, cy + 30 + icon_sz/2), icon_sz/2, imgui.ColorConvertFloat4ToU32(THEME.bg_tertiary))
                                        imgui.PushFont(font_fa_large)
                                        local ic = is_sell and fa('box') or fa('basket_shopping')
                                        local isz = imgui.CalcTextSize(ic)
                                        dl:AddText(imgui.ImVec2(cx + 30 + (icon_sz-isz.x)/2, cy + 30 + (icon_sz-isz.y)/2), imgui.ColorConvertFloat4ToU32(is_sell and THEME.accent_success or THEME.accent_primary), ic)
                                        imgui.PopFont()
                                        
                                        local text_x = cx + 30 + icon_sz + 20
                                        dl:PushClipRect(imgui.ImVec2(text_x, cy), imgui.ImVec2(cx + card_w - 5, cy + card_h), true)
                                        dl:AddText(imgui.ImVec2(text_x, cy + 25), imgui.ColorConvertFloat4ToU32(THEME.text_primary), u8(item.name))
                                        dl:PopClipRect()
                                        
                                        local price_str = formatMoney(item.price) .. " $"
                                        dl:AddText(imgui.ImVec2(text_x, cy + 55), imgui.ColorConvertFloat4ToU32(is_sell and THEME.accent_success or THEME.accent_primary), price_str)
                                        dl:AddText(imgui.ImVec2(text_x, cy + 85), imgui.ColorConvertFloat4ToU32(THEME.text_secondary), u8(item.amount .. " шт."))
                                    end
                                end
                            end
                            imgui.Dummy(imgui.ImVec2(0, total_rows * (card_h + spacing) + 20))
                        end
                        imgui.PopFont()
                    else
                        imgui.Dummy(imgui.ImVec2(0, 15))
                        if #StateMarket.shops_list == 0 then
                            imgui.Dummy(imgui.ImVec2(0, 50))
                            imgui.PushFont(font_main)
                            CenterText(u8"Нет активных лавок. Нажмите ОБНОВИТЬ СПИСОК внизу.", THEME.text_secondary, list_w)
                            imgui.PopFont()
                        else
                            local search_q = current_search_str
                            imgui.PushFont(font_main)
                            
                            if search_q ~= "" then
                                if StateMarket.last_query ~= search_q then
                                    StateMarket.last_query = search_q
                                    if search_thread_4 then search_thread_4:terminate() end
                                    search_thread_4 = lua_thread.create(function()
                                        local temp_s, temp_b = {}, {}
                                        local iter = 0
                                        for _, shop in ipairs(StateMarket.shops_list) do
                                            local pass_srv = (StateMarket.server_filter_idx == 0) or (StateMarket.server_filter_idx > 0 and shop.serverId == RODINA_SERVERS_DATA[StateMarket.server_filter_idx].id)
                                            if pass_srv then
                                                for _, item in ipairs(shop.sell_list) do
                                                    if to_lower(item.name):find(search_q, 1, true) then table.insert(temp_s, { shop = shop, item = item, is_sell = true }) end
                                                    iter = iter + 1
                                                    if iter % 100 == 0 then wait(0) end
                                                end
                                                for _, item in ipairs(shop.buy_list) do
                                                    if to_lower(item.name):find(search_q, 1, true) then table.insert(temp_b, { shop = shop, item = item, is_sell = false }) end
                                                    iter = iter + 1
                                                    if iter % 100 == 0 then wait(0) end
                                                end
                                            end
                                        end
                                        local function sortRes(a, b)
                                            if a.shop.vip ~= b.shop.vip then return a.shop.vip end
                                            return (tonumber(a.item.price) or 0) < (tonumber(b.item.price) or 0)
                                        end
                                        table.sort(temp_s, sortRes)
                                        table.sort(temp_b, sortRes)
                                        market_search_results_sell = temp_s
                                        market_search_results_buy = temp_b
                                    end)
                                end

                                if search_thread_4 and search_thread_4:status() ~= "dead" then
                                    imgui.Dummy(imgui.ImVec2(0, 50))
                                    CenterText(u8"Ищем товары...", THEME.accent_primary, list_w)
                                elseif #market_search_results_sell == 0 and #market_search_results_buy == 0 then
                                    imgui.Dummy(imgui.ImVec2(0, 50))
                                    CenterText(u8"Товары не найдены.", THEME.text_secondary, list_w)
                                else
                                    local results_sell = market_search_results_sell
                                    local results_buy = market_search_results_buy
                                    
                                    local start_pos = imgui.GetCursorScreenPos()
                                    local seg_w = list_w
                                    local seg_h = 70.0
                                    
                                    dl:AddRectFilled(imgui.ImVec2(start_pos.x, start_pos.y), imgui.ImVec2(start_pos.x + seg_w, start_pos.y + seg_h), imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), 20.0)
                                    dl:AddRect(imgui.ImVec2(start_pos.x, start_pos.y), imgui.ImVec2(start_pos.x + seg_w, start_pos.y + seg_h), imgui.ColorConvertFloat4ToU32(THEME.border), 20.0, 15, 2.0)

                                    if not StateMarket.search_sub_tab then StateMarket.search_sub_tab = 1 end
                                    local half_w = seg_w / 2
                                    
                                    local function DrawMarketSegBtn(id, label, is_left)
                                        local b_x = is_left and start_pos.x or (start_pos.x + half_w)
                                        imgui.SetCursorScreenPos(imgui.ImVec2(b_x, start_pos.y))
                                        if imgui.InvisibleButton("##mkt_seg_"..id, imgui.ImVec2(half_w, seg_h)) then StateMarket.search_sub_tab = id end
                                        local is_act = (StateMarket.search_sub_tab == id)
                                        if is_act then
                                            dl:AddRectFilled(imgui.ImVec2(b_x + 6, start_pos.y + 6), imgui.ImVec2(b_x + half_w - 6, start_pos.y + seg_h - 6), imgui.ColorConvertFloat4ToU32(THEME.bg_tertiary), 16.0)
                                            dl:AddRect(imgui.ImVec2(b_x + 6, start_pos.y + 6), imgui.ImVec2(b_x + half_w - 6, start_pos.y + seg_h - 6), imgui.ColorConvertFloat4ToU32(id == 1 and THEME.accent_success or THEME.accent_primary), 16.0, 15, 2.5)
                                        end
                                        imgui.PushFont(font_main)
                                        local tsz = imgui.CalcTextSize(u8(label))
                                        local col = is_act and THEME.text_primary or THEME.text_secondary
                                        dl:AddText(imgui.ImVec2(b_x + (half_w - tsz.x)/2, start_pos.y + (seg_h - tsz.y)/2), imgui.ColorConvertFloat4ToU32(col), u8(label))
                                        imgui.PopFont()
                                    end
                                    
                                    DrawMarketSegBtn(1, "В ПРОДАЖЕ (" .. #results_sell .. ")", true)
                                    DrawMarketSegBtn(2, "В СКУПКЕ (" .. #results_buy .. ")", false)
                                    
                                    local list_start_y = start_pos.y + seg_h + 20.0
                                    local current_res = StateMarket.search_sub_tab == 1 and results_sell or results_buy
                                    local item_card_h = 95.0
                                    local spacing = 15.0
                                    local card_w = list_w
                                    
                                    local function drawSearchCard(res, idx, cx, cy)
                                        imgui.SetCursorScreenPos(imgui.ImVec2(cx, cy))
                                        if imgui.InvisibleButton("##mkt_item_"..tostring(res.is_sell).."_"..idx, imgui.ImVec2(card_w, item_card_h)) then
                                            StateMarket.selected_shop = res.shop
                                            search_buf_market[0] = 0 
                                            StateMarket.details_tab = res.is_sell and 1 or 2
                                        end
                                        local is_active = imgui.IsItemActive()
                                        local bg_col = is_active and THEME.bg_tertiary or THEME.bg_secondary
                                        
                                        dl:AddRectFilled(imgui.ImVec2(cx, cy), imgui.ImVec2(cx + card_w, cy + item_card_h), imgui.ColorConvertFloat4ToU32(bg_col), 16.0)
                                        dl:AddRect(imgui.ImVec2(cx, cy), imgui.ImVec2(cx + card_w, cy + item_card_h), imgui.ColorConvertFloat4ToU32(res.shop.vip and imgui.ImVec4(1.0, 0.84, 0.0, 0.8) or THEME.border), 16.0, 15, res.shop.vip and 2.0 or 1.5)
                                        
                                        local accent = res.is_sell and THEME.accent_success or THEME.accent_primary
                                        dl:AddRectFilled(imgui.ImVec2(cx, cy), imgui.ImVec2(cx + 8, cy + item_card_h), imgui.ColorConvertFloat4ToU32(accent), 16.0, 9)

                                        local gear_area_w = 80.0
                                        local gear_x = cx + card_w - gear_area_w
                                        dl:AddRectFilled(imgui.ImVec2(gear_x, cy), imgui.ImVec2(cx + card_w, cy + item_card_h), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0,0,0,0.1)), 16.0, 6)
                                        dl:AddLine(imgui.ImVec2(gear_x, cy), imgui.ImVec2(gear_x, cy + item_card_h), imgui.ColorConvertFloat4ToU32(THEME.border), 2.0)

                                        imgui.PushFont(font_fa_large)
                                        local gear_icon = fa('store')
                                        local gsz = imgui.CalcTextSize(gear_icon)
                                        dl:AddText(imgui.ImVec2(gear_x + (gear_area_w - gsz.x)/2, cy + (item_card_h - gsz.y)/2), imgui.ColorConvertFloat4ToU32(is_active and THEME.text_primary or THEME.text_secondary), gear_icon)
                                        imgui.PopFont()

                                        local text_x = cx + 25.0
                                        imgui.PushFont(font_main)
                                        
                                        dl:PushClipRect(imgui.ImVec2(text_x, cy), imgui.ImVec2(gear_x - 15, cy + item_card_h), true)
                                        dl:AddText(imgui.ImVec2(text_x, cy + 20), imgui.ColorConvertFloat4ToU32(THEME.text_primary), u8(res.item.name))
                                        
                                        local shop_info = res.shop.nickname .. " | " .. getServerDisplayName(res.shop.serverId)
                                        dl:AddText(imgui.ImVec2(text_x, cy + 50), imgui.ColorConvertFloat4ToU32(res.shop.vip and imgui.ImVec4(1.0, 0.84, 0.0, 1.0) or THEME.text_secondary), u8(shop_info))
                                        dl:PopClipRect()

                                        local price_str = formatMoney(res.item.price) .. " $  •  " .. res.item.amount .. " шт."
                                        local psz = imgui.CalcTextSize(price_str)
                                        dl:AddText(imgui.ImVec2(gear_x - psz.x - 20, cy + (item_card_h - psz.y)/2), imgui.ColorConvertFloat4ToU32(accent), price_str)
                                        imgui.PopFont()
                                    end

                                    local clipper = imgui.ImGuiListClipper(#current_res)
                                    while clipper:Step() do
                                        for i = clipper.DisplayStart + 1, clipper.DisplayEnd do
                                            local res = current_res[i]
                                            local cy = list_start_y + (i - 1) * (item_card_h + spacing)
                                            drawSearchCard(res, i, start_pos.x, cy)
                                        end
                                    end
                                    imgui.Dummy(imgui.ImVec2(0, seg_h + 20.0 + #current_res * (item_card_h + spacing) + 20))
                                end
                            else
                                local filtered_shops = {}
                                for _, shop in ipairs(StateMarket.shops_list) do
                                    local pass_srv = false
                                    if StateMarket.server_filter_idx == 0 then pass_srv = true
                                    elseif StateMarket.server_filter_idx > 0 and shop.serverId == RODINA_SERVERS_DATA[StateMarket.server_filter_idx].id then pass_srv = true end
                                    if pass_srv then table.insert(filtered_shops, shop) end
                                end
                                table.sort(filtered_shops, function(a, b)
                                    if a.vip ~= b.vip then return a.vip end
                                    return a.nickname < b.nickname
                                end)
                                
                                if #filtered_shops == 0 then
                                    imgui.Dummy(imgui.ImVec2(0, 50))
                                    CenterText(u8"На этом сервере нет лавок.", THEME.text_secondary, list_w)
                                else
                                    local cols = 2
                                    local spacing = 25.0
                                    local card_w = (list_w - spacing * (cols - 1)) / cols
                                    local card_h = 140.0
                                    local start_pos = imgui.GetCursorScreenPos()
                                    local total_rows = math.ceil(#filtered_shops / cols)
                                    
                                    local clipper = imgui.ImGuiListClipper(total_rows)
                                    while clipper:Step() do
                                        for row = clipper.DisplayStart, clipper.DisplayEnd - 1 do
                                            for col = 0, cols - 1 do
                                                local i = row * cols + col + 1
                                                if i > #filtered_shops then break end
                                                local shop = filtered_shops[i]
                                                local cx = start_pos.x + col * (card_w + spacing)
                                                local cy = start_pos.y + row * (card_h + spacing)
                                                
                                                imgui.SetCursorScreenPos(imgui.ImVec2(cx, cy))
                                                if imgui.InvisibleButton("##shop_grid_"..i, imgui.ImVec2(card_w, card_h)) then StateMarket.selected_shop = shop end
                                                
                                                local bg_col = imgui.IsItemActive() and THEME.bg_tertiary or THEME.bg_secondary
                                                local border_col = THEME.border
                                                if shop.vip then 
                                                    bg_col = imgui.ImVec4(0.25, 0.20, 0.05, 1.0)
                                                    border_col = imgui.ImVec4(1.0, 0.84, 0.0, 0.8)
                                                end
                                                
                                                dl:AddRectFilled(imgui.ImVec2(cx, cy), imgui.ImVec2(cx + card_w, cy + card_h), imgui.ColorConvertFloat4ToU32(bg_col), 24.0)
                                                dl:AddRect(imgui.ImVec2(cx, cy), imgui.ImVec2(cx + card_w, cy + card_h), imgui.ColorConvertFloat4ToU32(border_col), 24.0, 15, shop.vip and 3.0 or 2.0)
                                                
                                                imgui.PushFont(font_fa_large)
                                                local icon_col = shop.vip and imgui.ImVec4(1.0, 0.84, 0.0, 1.0) or THEME.accent_primary
                                                dl:AddText(imgui.ImVec2(cx + 25, cy + 40), imgui.ColorConvertFloat4ToU32(icon_col), shop.vip and fa('crown') or fa('store'))
                                                imgui.PopFont()
                                                
                                                dl:AddText(imgui.ImVec2(cx + 90, cy + 25), imgui.ColorConvertFloat4ToU32(THEME.text_primary), u8(shop.nickname))
                                                dl:AddText(imgui.ImVec2(cx + 90, cy + 55), imgui.ColorConvertFloat4ToU32(THEME.text_secondary), u8(getServerDisplayName(shop.serverId)))
                                                dl:AddText(imgui.ImVec2(cx + 90, cy + 85), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.4, 0.42, 0.5, 1.0)), u8(string.format("Sell: %d | Buy: %d", shop.sell_count, shop.buy_count)))
                                            end
                                        end
                                    end
                                    imgui.Dummy(imgui.ImVec2(0, total_rows * (card_h + spacing) + 20))
                                end
                            end
                            imgui.PopFont()
                        end
                    end
                    dl:PopClipRect()
                end
                imgui.EndChild()
                imgui.PopStyleColor()

            elseif active_tab == 5 or active_tab == 6 then
                local delta = DrawScrollZone("##scroll_pr_sets", list_x + list_w + 20, content_y + 20, scroll_w, content_h - 40)

                imgui.SetCursorScreenPos(imgui.ImVec2(list_x, content_y + 20))
                imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0,0,0,0))
                
                if active_tab == 5 then
                    if imgui.BeginChild("AutoPRChild", imgui.ImVec2(list_w, content_h - 40), false, imgui.WindowFlags.NoScrollbar) then
                        local c_pos = imgui.GetWindowPos()
                        local c_size = imgui.GetWindowSize()
                        dl:PushClipRect(c_pos, imgui.ImVec2(c_pos.x + c_size.x, c_pos.y + c_size.y), true)
                        
                        if delta ~= 0 then imgui.SetScrollY(imgui.GetScrollY() - delta) end
                        imgui.PushFont(font_main)
                        
                        local is_pr_active = Settings.auto_pr.active
                        local btn_w = (list_w - 30) / 2
                        
                        if DrawStyledButton("##pr_main_btn", is_pr_active and u8"ОСТАНОВИТЬ ПИАР" or u8"ЗАПУСТИТЬ ПИАР", btn_w, 85.0, is_pr_active and THEME.accent_danger or THEME.accent_success, is_pr_active and fa('stop') or fa('play'), dl) then
                            Settings.auto_pr.active = not Settings.auto_pr.active
                            if Settings.auto_pr.active then
                                local now = os.time()
                                for i, item in ipairs(Settings.auto_pr.items) do item.next_send = now + 2 + i end
                                sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Авто-пиар запущен!", -1)
                            else
                                State.auto_pr.pending_vr_response = false
                                sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Авто-пиар остановлен!", -1)
                            end
                            saveJsonFile(PATH_SETTINGS, Settings)
                        end
                        
                        imgui.SameLine(nil, 30)
                        if DrawStyledButton("##pr_add_btn", u8"ДОБАВИТЬ ФРАЗУ", btn_w, 85.0, THEME.accent_primary, fa('plus'), dl) then
                            table.insert(Settings.auto_pr.items, { text = "", channel = 1, delay = 60, active = true, next_send = 0 })
                            saveJsonFile(PATH_SETTINGS, Settings)
                        end
                        
                        imgui.Dummy(imgui.ImVec2(0, 30))
                        
                        for i, item in ipairs(Settings.auto_pr.items) do
                            local p_item = imgui.GetCursorScreenPos()
                            local item_h = 175.0
                            dl:AddRectFilled(p_item, imgui.ImVec2(p_item.x + list_w, p_item.y + item_h), imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), 24.0)

                            local top_y = p_item.y + 20
                            local inner_w = list_w - 40
                            local start_x = p_item.x + 20
                            
                            local t_p = imgui.ImVec2(start_x, top_y)
                            imgui.SetCursorScreenPos(t_p)
                            if imgui.InvisibleButton("##pr_act_"..i, imgui.ImVec2(60, 60)) then
                                item.active = not item.active
                                if item.active and Settings.auto_pr.active then item.next_send = os.time() + 2 end
                                saveJsonFile(PATH_SETTINGS, Settings)
                            end
                            dl:AddRectFilled(t_p, imgui.ImVec2(t_p.x + 60, t_p.y + 60), imgui.ColorConvertFloat4ToU32(item.active and THEME.accent_success or THEME.bg_main), 16.0)
                            if item.active then
                                imgui.PushFont(font_fa_large)
                                local check_sz = imgui.CalcTextSize(fa('check'))
                                dl:AddText(imgui.ImVec2(t_p.x + (60 - check_sz.x)/2, t_p.y + (60 - check_sz.y)/2), 0xFFFFFFFF, fa('check'))
                                imgui.PopFont()
                            end
                            
                            local ch_names = {"VR", "/b", "/s", "Chat", "/fam", "/al"}
                            local ch_colors = {0xFF00AAFF, 0xFFCCCCCC, 0xFFFFFFFF, 0xFF66FF66, 0xFFFFFF00, 0xFF00FFFF}
                            local curr_ch = item.channel or 1
                            
                            local ch_w = 120
                            local ch_p = imgui.ImVec2(t_p.x + 60 + 15, top_y)
                            imgui.SetCursorScreenPos(ch_p)
                            if imgui.InvisibleButton("##pr_ch_"..i, imgui.ImVec2(ch_w, 60)) then
                                item.channel = (item.channel % 6) + 1
                                saveJsonFile(PATH_SETTINGS, Settings)
                            end
                            dl:AddRect(ch_p, imgui.ImVec2(ch_p.x + ch_w, ch_p.y + 60), ch_colors[curr_ch], 16.0, 15, 3.0)
                            local ch_txt = ch_names[curr_ch]
                            local ctx_sz = imgui.CalcTextSize(ch_txt)
                            dl:AddText(imgui.ImVec2(ch_p.x + (ch_w - ctx_sz.x)/2, ch_p.y + (60 - ctx_sz.y)/2), ch_colors[curr_ch], ch_txt)
                            
                            local trash_sz = 60.0
                            local del_btn_p = imgui.ImVec2(start_x + inner_w - trash_sz, top_y)
                            
                            local del_w = inner_w - (60 + 15 + ch_w + 15 + 15 + trash_sz)
                            if del_w < 100 then del_w = 100 end 
                            local del_p = imgui.ImVec2(ch_p.x + ch_w + 15, top_y)
                            
                            imgui.SetCursorScreenPos(del_p)
                            imgui.SetNextItemWidth(del_w)
                            imgui.PushStyleColor(imgui.Col.FrameBg, THEME.bg_tertiary)
                            imgui.PushStyleColor(imgui.Col.Text, THEME.text_primary)
                            imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(15.0, (60 - imgui.GetFontSize()) / 2))
                            if imgui.InputText("##pr_del_"..i, getPRDelayBuffer(i, item.delay), 32, imgui.InputTextFlags.CharsDecimal) then
                                item.delay = tonumber(ffi.string(getPRDelayBuffer(i))) or 60
                                saveJsonFile(PATH_SETTINGS, Settings)
                            end
                            imgui.PopStyleVar()
                            imgui.PopStyleColor(2)
                            
                            imgui.SetCursorScreenPos(del_btn_p)
                            if imgui.InvisibleButton("##pr_trash_"..i, imgui.ImVec2(trash_sz, trash_sz)) then
                                table.remove(Settings.auto_pr.items, i)
                                saveJsonFile(PATH_SETTINGS, Settings)
                                break
                            end
                            dl:AddRectFilled(del_btn_p, imgui.ImVec2(del_btn_p.x + trash_sz, del_btn_p.y + trash_sz), imgui.ColorConvertFloat4ToU32(imgui.IsItemHovered() and THEME.bg_main or THEME.bg_tertiary), 16.0)
                            imgui.PushFont(font_fa_large)
                            local tr_sz = imgui.CalcTextSize(fa('trash'))
                            dl:AddText(imgui.ImVec2(del_btn_p.x + (trash_sz - tr_sz.x)/2, del_btn_p.y + (trash_sz - tr_sz.y)/2), imgui.ColorConvertFloat4ToU32(THEME.accent_danger), fa('trash'))
                            imgui.PopFont()
                            
                            imgui.SetCursorScreenPos(imgui.ImVec2(start_x, top_y + 60 + 15))
                            imgui.SetNextItemWidth(inner_w)
                            imgui.PushStyleColor(imgui.Col.FrameBg, THEME.bg_tertiary)
                            imgui.PushStyleColor(imgui.Col.Text, THEME.text_primary)
                            imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(20.0, (60 - imgui.GetFontSize()) / 2))
                            if imgui.InputText("##pr_txt_"..i, getPRBuffer(i, item.text), 256) then
                                item.text = ffi.string(getPRBuffer(i))
                                saveJsonFile(PATH_SETTINGS, Settings)
                            end
                            imgui.PopStyleVar()
                            imgui.PopStyleColor(2)
                            
                            imgui.SetCursorScreenPos(imgui.ImVec2(p_item.x, p_item.y + item_h + 15))
                        end
                        imgui.PopFont()
                        imgui.Dummy(imgui.ImVec2(0, 20))
                        dl:PopClipRect()
                    end
                    imgui.EndChild()
                elseif active_tab == 6 then
                    if imgui.BeginChild("SettingsChild", imgui.ImVec2(list_w, content_h - 25), false, imgui.WindowFlags.NoScrollbar) then
                        local c_pos = imgui.GetWindowPos()
                        local c_size = imgui.GetWindowSize()
                        dl:PushClipRect(c_pos, imgui.ImVec2(c_pos.x + c_size.x, c_pos.y + c_size.y), true)
                        
                        if delta ~= 0 then imgui.SetScrollY(imgui.GetScrollY() - delta) end
                        imgui.PushFont(font_main)
                        
                        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(30.0, 35.0))
                        imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(10.0, 35.0))
                        
                        imgui.TextColored(THEME.accent_primary, u8"АВТОМАТИЗАЦИЯ ЛАВКИ")
                        
                        local t_p = imgui.GetCursorScreenPos()
                        if imgui.InvisibleButton("##cb_auto_name", imgui.ImVec2(75, 75)) then b_auto_name[0] = not b_auto_name[0] end
                        local cb_bg = b_auto_name[0] and THEME.accent_success or (imgui.IsItemHovered() and imgui.ImVec4(1,1,1,0.1) or THEME.bg_tertiary)
                        dl:AddRectFilled(t_p, imgui.ImVec2(t_p.x + 75, t_p.y + 75), imgui.ColorConvertFloat4ToU32(cb_bg), 20.0)
                        if b_auto_name[0] then
                            imgui.PushFont(font_fa_large)
                            local isz = imgui.CalcTextSize(fa('check'))
                            dl:AddText(imgui.ImVec2(t_p.x + (75 - isz.x)/2, t_p.y + (75 - isz.y)/2), 0xFFFFFFFF, fa('check'))
                            imgui.PopFont()
                        end
                        
                        imgui.SameLine(nil, 30)
                        imgui.SetCursorPosY(imgui.GetCursorPosY() + 26)
                        imgui.Text(u8"Автоматически вводить название")
                        
                        imgui.TextColored(THEME.text_secondary, u8"Желаемое название лавки:")
                        imgui.PushItemWidth(list_w)
                        imgui.PushStyleColor(imgui.Col.FrameBg, THEME.bg_tertiary)
                        imgui.PushStyleColor(imgui.Col.Text, THEME.text_primary)
                        imgui.InputText("##shopname", buf_shop_name, 64)
                        imgui.PopStyleColor(2)
                        imgui.PopItemWidth()
                        
                        imgui.Dummy(imgui.ImVec2(0, 30))
                        
                        imgui.TextColored(THEME.accent_primary, u8"УВЕДОМЛЕНИЯ ТЕЛЕГРАМ / ВК")
                        
                        imgui.TextColored(THEME.text_secondary, u8"Секретный ключ (из бота RMarket):")
                        imgui.PushItemWidth(list_w)
                        imgui.PushStyleColor(imgui.Col.FrameBg, THEME.bg_tertiary)
                        imgui.PushStyleColor(imgui.Col.Text, THEME.text_primary)
                        imgui.InputText("##apikey", buf_api_key, 128, imgui.InputTextFlags.Password)
                        imgui.PopStyleColor(2)
                        imgui.PopItemWidth()
                        
                        imgui.Dummy(imgui.ImVec2(0, 20))
                        if DrawStyledButton("##test_tg", u8"ПРОВЕРИТЬ КЛЮЧ", list_w, 80.0, THEME.accent_primary, fa('paper_plane'), dl) then
                            Settings.api_key = ffi.string(buf_api_key)
                            saveJsonFile(PATH_SETTINGS, Settings)
                            if Settings.api_key ~= "" then
                                api_TestTelegramToken()
                                sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Проверка ключа...", -1)
                            else
                                sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Введите ключ перед проверкой!", -1)
                            end
                        end
                        
                        imgui.Dummy(imgui.ImVec2(0, 30))
                        imgui.TextColored(THEME.accent_primary, u8"ЗАДЕРЖКА ВЫСТАВЛЕНИЯ")
                        imgui.TextColored(THEME.text_secondary, u8"Пауза между товарами в лавке (мс):")
                        
                        imgui.PushItemWidth(list_w)
                        imgui.PushStyleColor(imgui.Col.FrameBg, THEME.bg_tertiary)
                        imgui.PushStyleColor(imgui.Col.SliderGrab, THEME.accent_primary)
                        imgui.PushStyleColor(imgui.Col.SliderGrabActive, THEME.accent_success)
                        if imgui.SliderInt("##trade_delay_slider", sl_delay, 100, 3000, "%d ms") then
                            Settings.trade_delay = sl_delay[0]
                            saveJsonFile(PATH_SETTINGS, Settings)
                        end
                        imgui.PopStyleColor(3)
                        imgui.PopItemWidth()
                        
                        imgui.Dummy(imgui.ImVec2(0, 30))
                        imgui.TextColored(THEME.accent_primary, u8"ИНТЕРФЕЙС")
                        
                        local hud_p = imgui.GetCursorScreenPos()
                        if imgui.InvisibleButton("##cb_show_hud", imgui.ImVec2(75, 75)) then b_show_hud[0] = not b_show_hud[0] end
                        local hud_bg = b_show_hud[0] and THEME.accent_success or (imgui.IsItemHovered() and imgui.ImVec4(1,1,1,0.1) or THEME.bg_tertiary)
                        dl:AddRectFilled(hud_p, imgui.ImVec2(hud_p.x + 75, hud_p.y + 75), imgui.ColorConvertFloat4ToU32(hud_bg), 20.0)
                        if b_show_hud[0] then
                            imgui.PushFont(font_fa_large)
                            local isz = imgui.CalcTextSize(fa('check'))
                            dl:AddText(imgui.ImVec2(hud_p.x + (75 - isz.x)/2, hud_p.y + (75 - isz.y)/2), 0xFFFFFFFF, fa('check'))
                            imgui.PopFont()
                        end
                        
                        imgui.SameLine(nil, 30)
                        imgui.SetCursorPosY(imgui.GetCursorPosY() + 15)
                        imgui.BeginGroup()
                        imgui.Text(u8"RMarket Live (HUD Прибыли)")
                        imgui.TextColored(THEME.text_secondary, u8"Виджет дохода на экране")
                        imgui.EndGroup()

                        imgui.Dummy(imgui.ImVec2(0, 10))

                        local float_p = imgui.GetCursorScreenPos()
                        if imgui.InvisibleButton("##cb_show_float", imgui.ImVec2(75, 75)) then b_show_float[0] = not b_show_float[0] end
                        local float_bg = b_show_float[0] and THEME.accent_success or (imgui.IsItemHovered() and imgui.ImVec4(1,1,1,0.1) or THEME.bg_tertiary)
                        dl:AddRectFilled(float_p, imgui.ImVec2(float_p.x + 75, float_p.y + 75), imgui.ColorConvertFloat4ToU32(float_bg), 20.0)
                        if b_show_float[0] then
                            imgui.PushFont(font_fa_large)
                            local isz = imgui.CalcTextSize(fa('check'))
                            dl:AddText(imgui.ImVec2(float_p.x + (75 - isz.x)/2, float_p.y + (75 - isz.y)/2), 0xFFFFFFFF, fa('check'))
                            imgui.PopFont()
                        end
                        
                        imgui.SameLine(nil, 30)
                        imgui.SetCursorPosY(imgui.GetCursorPosY() + 15)
                        imgui.BeginGroup()
                        imgui.Text(u8"Плавающая кнопка")
                        imgui.TextColored(THEME.text_secondary, u8"Кнопка быстрого доступа на экране")
                        imgui.EndGroup()
                        
                        imgui.PopStyleVar(2)
                        imgui.PopFont()
                        dl:PopClipRect()
                    end
                    imgui.EndChild()
                end
                imgui.PopStyleColor()
            end

            local footer_y = p.y + win_h - footer_h
            dl:AddRectFilled(imgui.ImVec2(c_x, footer_y), imgui.ImVec2(c_x + c_w, p.y + win_h), imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), 16.0, 4) 
            dl:AddLine(imgui.ImVec2(c_x, footer_y), imgui.ImVec2(c_x + c_w, footer_y), imgui.ColorConvertFloat4ToU32(THEME.border), 2.0)
            
            local btn_h = 70.0
            local btn_w = c_w - 50.0
            local btn_x = c_x + 25.0
            local btn_y = footer_y + (footer_h - btn_h) / 2
            
            imgui.SetCursorScreenPos(imgui.ImVec2(btn_x, btn_y))
            if imgui.InvisibleButton("##main_action_btn", imgui.ImVec2(btn_w, btn_h)) then
                if active_tab == 1 then
                    if #config_sell == 0 then sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Список на продажу пуст!", -1) else
                        State.selling = { active = true, stage = 'waiting_dialog', current_idx = 1, total = #config_sell, current_item = nil }
                        sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Откройте лавку для выставления товаров!", -1)
                        win_state[0] = false
                    end
                elseif active_tab == 2 then
                    if #config_buy == 0 then sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Список на скупку пуст!", -1) else
                        State.buying = { active = true, stage = 'waiting_dialog', current_idx = 1, total = #config_buy, current_item = nil }
                        sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Откройте лавку для выставления товаров на скупку!", -1)
                        win_state[0] = false
                    end
                elseif active_tab == 3 then LogsState.cached_income, LogsState.cached_expense = updateLogView()
                elseif active_tab == 4 then api_FetchMarketList()
                elseif active_tab == 5 then sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Авто-пиар сохранен!", -1)
                elseif active_tab == 6 then
                    Settings.auto_name = b_auto_name[0]
                    Settings.show_live_hud = b_show_hud[0]
                    Settings.show_float_btn = b_show_float[0]
                    Settings.shop_name = ffi.string(buf_shop_name)
                    Settings.api_key = ffi.string(buf_api_key)
                    saveJsonFile(PATH_SETTINGS, Settings)
                    sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Настройки успешно сохранены!", -1)
                end
            end
            
            local base_btn_col = THEME.bg_tertiary
            if active_tab == 1 then base_btn_col = THEME.accent_success
            elseif active_tab == 2 then base_btn_col = THEME.accent_primary end
            local btn_color = imgui.IsItemActive() and imgui.ImVec4(base_btn_col.x*0.8, base_btn_col.y*0.8, base_btn_col.z*0.8, 1.0) or base_btn_col
            dl:AddRectFilled(imgui.ImVec2(btn_x, btn_y), imgui.ImVec2(btn_x + btn_w, btn_y + btn_h), imgui.ColorConvertFloat4ToU32(btn_color), 16.0)
            
            local action_txt, action_icon = "", ""
            if active_tab == 1 then action_txt, action_icon = u8"ВЫСТАВИТЬ ТОВАРЫ НА ПРОДАЖУ", fa('paper_plane')
            elseif active_tab == 2 then action_txt, action_icon = u8"НАЧАТЬ СКУПКУ", fa('shop')
            elseif active_tab == 3 then action_txt, action_icon = u8"ОБНОВИТЬ ИСТОРИЮ", fa('arrows_rotate')
            elseif active_tab == 4 then action_txt, action_icon = u8"ОБНОВИТЬ СПИСОК ЛАВОК", fa('arrows_rotate')
            elseif active_tab == 5 then action_txt, action_icon = u8"СОХРАНИТЬ НАСТРОЙКИ", fa('floppy_disk')
            elseif active_tab == 6 then action_txt, action_icon = u8"СОХРАНИТЬ НАСТРОЙКИ", fa('floppy_disk') end
            
            imgui.PushFont(font_fa_large)
            local a_isz = imgui.CalcTextSize(action_icon)
            imgui.PopFont()
            imgui.PushFont(font_main)
            local a_tsz = imgui.CalcTextSize(action_txt)
            local center_ax = btn_x + (btn_w - (a_isz.x + 20 + a_tsz.x)) / 2
            
            imgui.PushFont(font_fa_large)
            dl:AddText(imgui.ImVec2(center_ax, btn_y + (btn_h - a_isz.y)/2), 0xFFFFFFFF, action_icon)
            imgui.PopFont()
            dl:AddText(imgui.ImVec2(center_ax + a_isz.x + 20, btn_y + (btn_h - a_tsz.y)/2), 0xFFFFFFFF, action_txt)
            imgui.PopFont()
            
            end

        end
        imgui.End()
    end
)

function api_TestTelegramToken()
    if Settings.api_key == "" then 
        sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Введите ключ перед проверкой!", -1)
        return 
    end
    
    if not req_ok then
        sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Критическая ошибка: библиотека requests не загружена!", -1)
        return
    end

    sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Проверка ключа...", -1)

    lua_thread.create(function()
        local payload_str = cjson.encode({
            secret_key = Settings.api_key,
            nickname = u8(LOCAL_PLAYER_NICK or "Mobile_User"),
            account_id = 0
        })
        
        local ok_req, res = pcall(requests.post, "https://rodina-market.store/node-api/test_tg", {
            data = payload_str,
            headers = { ["Content-Type"] = "application/json" },
            timeout = 15,
            verify = false 
        })
        
        if not ok_req then
            sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Системная ошибка сети! Смотрите moonloader.log", -1)
            return
        end
        
        if res and res.status_code == 200 then
            local ok_json, data = pcall(cjson.decode, res.text)
            if ok_json then
                if data.status == 'success' then
                    sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Ключ успешно привязан к Telegram!", -1)
                else
                    sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ошибка привязки: " .. tostring(data.message or "Неизвестная ошибка"), -1)
                end
            else
                sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ошибка сервера: неверный формат ответа.", -1)
            end
        else
            sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ошибка сети или неверный ключ!", -1)
        end
    end)
end

function main()
    while not isSampAvailable() do wait(100) end
    
    checkUpdate()
    
    lua_thread.create(function()
        while not sampIsLocalPlayerSpawned() do wait(100) end
        
        local ip, port = sampGetCurrentServerAddress()
        local my_srv_id = normalizeServerId(ip .. ":" .. port)
        for i, srv in ipairs(RODINA_SERVERS_DATA) do
            if srv.id == my_srv_id then
                StateMarket.server_filter_idx = i 
                break
            end
        end

        if Settings.api_key ~= "" then
            State.silent_stats = true
            sampSendChat("/stats")
        end
        api_FetchMarketList()
    end)

    lua_thread.create(function()
        local wait_start = 0
        while true do
            wait(150)
            if State.selling.active then
                if State.selling.stage == 'waiting_cef_data' then
                    if wait_start == 0 then wait_start = os.clock() end
                    
                    local now = os.clock()
                    if State.selling.last_packet_time > 0 and (now - State.selling.last_packet_time > 0.5) then
                        State.selling.stage = 'running'
                        wait_start = 0
                        processSellingCoroutine()
                    elseif now - wait_start > 10.0 then
                        sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ошибка: Данные лавки не поступили (таймаут).", -1)
                        State.selling.active = false
                        wait_start = 0
                    end
                else
                    wait_start = 0
                end
            else
                wait_start = 0
            end
        end
    end)

    sampRegisterChatCommand('rmenu', function()
        win_state[0] = not win_state[0]
    end)
    
    sampAddChatMessage("{5CB85C}[RMarket Mobile] {FFFFFF}Скрипт успешно запущен. Введите {5CB85C}/rmenu", -1)

    while true do
        wait(0)
        
        if Settings.auto_pr and Settings.auto_pr.active then
            local now = os.time()
            if now >= State.auto_pr.global_cooldown then
                local best_item = nil
                local max_overdue = -1
                
                for i, item in ipairs(Settings.auto_pr.items) do
                    if item.active then
                        if not item.next_send then item.next_send = now + 2 + i end
                        if now >= item.next_send then
                            local text_to_send = item.text
                            local channel_to_send = item.channel or 1
                            
                            if text_to_send and text_to_send ~= "" then
                                local can_send = true
                                if channel_to_send == 1 and (now - State.auto_pr.last_vr_time < 305) then
                                    can_send = false
                                end
                                
                                if can_send then
                                    local overdue = now - item.next_send
                                    if overdue > max_overdue then
                                        max_overdue = overdue
                                        best_item = item
                                    end
                                end
                            end
                        end
                    end
                end
                
                if best_item then
                    local decoded_text = u8:decode(best_item.text or "")
                    local final_text = processPRVariables(decoded_text)
                    local ch = best_item.channel or 1
                    
                    if ch == 1 then 
                        State.auto_pr.pending_vr_response = true
                        lua_thread.create(function() wait(3000) State.auto_pr.pending_vr_response = false end)
                        sampSendChat("/vr " .. final_text)
                        State.auto_pr.last_vr_time = now 
                    elseif ch == 2 then sampSendChat("/b " .. final_text)
                    elseif ch == 3 then sampSendChat("/s " .. final_text)
                    elseif ch == 4 then sampSendChat(final_text)
                    elseif ch == 5 then sampSendChat("/fam " .. final_text)
                    elseif ch == 6 then sampSendChat("/al " .. final_text)
                    end
                    
                    best_item.next_send = now + (best_item.delay or 60)
                    State.auto_pr.global_cooldown = now + 2.0
                end
            end
        end

        if win_state[0] ~= was_menu_open then
            was_menu_open = win_state[0]
        end
    end
end