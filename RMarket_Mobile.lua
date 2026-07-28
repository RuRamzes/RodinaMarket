script_name("RMarket Mobile")
script_version("1.2")

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

local win_state = imgui.new.bool(false)
local active_tab = 1

local LOCAL_PLAYER_NICK = nil
local req_ok, requests = pcall(require, 'requests')

local State = {
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

local pr_buffers = {}
local pr_delay_buffers = {}

local function getPRBuffer(idx, text)
    if not pr_buffers[idx] then pr_buffers[idx] = ffi.new('char[256]', text or "") end
    return pr_buffers[idx]
end

local function getPRDelayBuffer(idx, delay)
    if not pr_delay_buffers[idx] then pr_delay_buffers[idx] = ffi.new('char[32]', tostring(delay or 60)) end
    return pr_delay_buffers[idx]
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

local search_buf_sell = ffi.new('char[128]')
local search_buf_buy = ffi.new('char[128]')

local cfg_modal = {
    active = false,
    item = nil,
    index = nil,
    is_sell = false,
    target_table = nil,
    buf_price = ffi.new('char[32]'),
    buf_amount = ffi.new('char[32]')
}

local touch_state = {
    start_pos = imgui.ImVec2(0, 0),
    is_dragging = false,
    col = 0,
    threshold = 10.0
}

local ui_cache_sell = { query = nil, items = {} }
local ui_cache_buy = { query = nil, items = {} }

local active_cefs = {}
local was_menu_open = false

local ROOT_DIR = getWorkingDirectory() .. '/RMarket/'
local PATH_INV = ROOT_DIR .. 'mobile_inv.json'
local PATH_DB = ROOT_DIR .. 'mobile_buyable.json'
local PATH_NAMES = ROOT_DIR .. 'data/items_db.json'
local PATH_CFG_SELL = ROOT_DIR .. 'config_sell.json'
local PATH_CFG_BUY = ROOT_DIR .. 'config_buy.json'
local PATH_SETTINGS = ROOT_DIR .. 'settings.json'

local Settings = {
    auto_name = false,
    shop_name = "Rodina Market",
    api_key = "",
    auto_pr = { active = false, items = {} }
}

local THEME = {
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

local font_main = nil
local font_fa = nil
local font_fa_large = nil

local inv_items = {}
local db_items = {}
local item_names = {}

local function saveJsonFile(path, data)
    local clean_path = path:gsub("\\", "/")
    
    if not doesDirectoryExist(ROOT_DIR) then lfs.mkdir(ROOT_DIR) end
    if not doesDirectoryExist(ROOT_DIR .. 'data') then lfs.mkdir(ROOT_DIR .. 'data') end
    
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

local config_sell = loadJsonFile(PATH_CFG_SELL)
local config_buy = loadJsonFile(PATH_CFG_BUY)

local loaded_sets = loadJsonFile(PATH_SETTINGS)
if loaded_sets.auto_name ~= nil then Settings.auto_name = loaded_sets.auto_name end
if loaded_sets.shop_name then Settings.shop_name = loaded_sets.shop_name end
if loaded_sets.api_key then Settings.api_key = loaded_sets.api_key end
if loaded_sets.auto_pr then Settings.auto_pr = loaded_sets.auto_pr end

local b_auto_name = imgui.new.bool(Settings.auto_name)
local buf_shop_name = ffi.new('char[64]', Settings.shop_name)
local buf_api_key = ffi.new('char[128]', Settings.api_key)

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

local function parseMobileCEF(msgId, json_str)
    local ok, data = pcall(cjson.decode, json_str)
    if not ok or type(data) ~= "table" or type(data.items) ~= "table" then return end

    if State.selling.active and State.selling.stage == 'waiting_cef_data' and msgId == 52 then
        local received_valid_items = false
        
        for _, item in ipairs(data.items) do
            if tonumber(item.available) == 1 and item.item then
                table.insert(State.selling.available_items, {
                    slot = tonumber(item.slot),
                    model_id = tonumber(item.item),
                    amount = tonumber(item.amount) or 1
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
                if tonumber(item.available) == 1 and item.item and tonumber(item.is_use) ~= 1 then
                    local m_id = tonumber(item.item)
                    local name = item_names[tostring(m_id)]
                    
                    if name then
                        local exists = false
                        for _, v in ipairs(inv_items) do
                            if v.slot == tonumber(item.slot) and v.model_id == m_id then 
                                exists = true 
                                break 
                            end
                        end
                        
                        if not exists then
                            table.insert(inv_items, {
                                name = name, 
                                amount = tonumber(item.amount) or 1, 
                                model_id = m_id,
                                slot = tonumber(item.slot),
                                max_amount = tonumber(item.amount) or 1
                            })
                        end
                    end
                end
            end
        end
    end
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
    sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Откройте инвентарь самостоятельно для сканирования...", -1)
    lua_thread.create(function()
        local start_time = os.clock()
        while State.inventory_scan.active do
            wait(150)
            local now = os.clock()
            if State.inventory_scan.stage == "parsing" and State.inventory_scan.has_received_data then
                if (now - State.inventory_scan.last_packet_time > 1.0) then
                    finishInventoryScan()
                    break
                end
            end
            if now - start_time > 30.0 and not State.inventory_scan.has_received_data then
                sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ошибка: Таймаут. Вы не открыли инвентарь.", -1)
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
    
    local items_exhibited = 0
    
    for i, config_item in ipairs(config_sell) do
        if not State.selling.active then 
            sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Выставление принудительно остановлено!", -1)
            break 
        end
        
        local slot, model_id, real_stack_amount = nil, nil, nil
        local display_name = config_item.name and tostring(config_item.name) or "Неизвестный товар"
        
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
                if available.model_id == target_model_id then
                    slot = available.slot
                    model_id = available.model_id
                    real_stack_amount = available.amount
                    break
                end
            end
        end
        
        if slot and model_id then
            State.selling.current_idx = i
            State.selling.current_item = config_item
            State.selling.stage = 'waiting_input'
            
            sampAddChatMessage(string.format("{F0AD4E}[RMarket] {FFFFFF}Выставляем: %s (Слот: %d)", display_name, slot), -1)
            
            sendMobileCEFClick(slot, model_id, real_stack_amount)
            
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
                wait(1200)
            end
        else
            sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Пропущен: " .. display_name .. " (Не найден или серый слот)", -1)
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
            State.buying.stage = 'waiting_search_input'
            sampSendDialogResponse(id, 1, 0, "")
            return false
        end

        if State.buying.stage == 'waiting_search_input' and (id == 909 or text:find("название") or text:find("индекс")) then
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
        
        if State.selling.stage == 'waiting_input' and (id == 240 or text:find("цену") or text:find("через запятую") or text:find("количество")) then
            local input_str = ""
            local text_lower = text:lower()
            
            if text_lower:find("через запятую") or text_lower:find("введите количество") or text_lower:find("укажите количество") then
                input_str = string.format("%d,%d", State.selling.current_item.amount, State.selling.current_item.price)
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
    if clean:find("Вы успешно продали") or clean:find("Вы успешно купили") then
        local is_sale = clean:find("Вы успешно продали")
        local msg_type = is_sale and "sale" or "purchase"
        
        local item, amount_str, price_str = clean:match("успешно %S+ (.-)%s*%((%d+) шт%.%) за ([%d%.%,%s]+) руб")
        if not item then
            item, price_str = clean:match("успешно %S+ (.-)%s*за ([%d%.%,%s]+) руб")
            amount_str = "1"
        end
        
        if item and price_str and Settings.api_key ~= "" and req_ok then
            local price = tonumber((price_str:gsub("%D", ""))) or 0
            local amount = tonumber(amount_str) or 1
            
            lua_thread.create(function()
                print(string.format("[RMarket] Отправка сделки в ТГ: %s x%d = %d", u8(item), amount, price))
                local payload_str = cjson.encode({
                    secret_key = Settings.api_key,
                    data = {
                        type = msg_type,
                        item = u8(item),
                        amount = amount,
                        total = price,
                        price = math.floor(price / amount),
                        server = "Mobile Server",
                        player = "Игрок"
                    }
                })
                
                local ok, res = pcall(requests.post, "https://rodina-market.store/node-api/notify", {
                    data = payload_str,
                    headers = {
                        ["Content-Type"] = "application/json",
                        ["X-Auth-Key"] = Settings.api_key
                    },
                    timeout = 10,
                    verify = false
                })
                
                if not ok then
                    print("[RMarket] Ошибка отправки уведомления: " .. tostring(res))
                end
            end)
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
    local h = 65.0 
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
                price = 1000 
            })
            if is_sell then saveJsonFile(PATH_CFG_SELL, config_sell) else saveJsonFile(PATH_CFG_BUY, config_buy) end
        end
    end

    local bg_col = THEME.bg_main
    local border_col = THEME.border
    if is_added then
        bg_col = imgui.ImVec4(THEME.accent_success.x, THEME.accent_success.y, THEME.accent_success.z, 0.15)
        border_col = imgui.ImVec4(THEME.accent_success.x, THEME.accent_success.y, THEME.accent_success.z, 0.4)
    elseif is_active then
        bg_col = THEME.bg_tertiary
    end

    dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), imgui.ColorConvertFloat4ToU32(bg_col), 10.0)
    dl:AddRect(p, imgui.ImVec2(p.x + w, p.y + h), imgui.ColorConvertFloat4ToU32(border_col), 10.0, 15, 1.5)

    local icon_sz = 40.0
    local icon_x = p.x + 12.0
    local icon_y = p.y + (h - icon_sz) / 2
    local icon_bg = is_added and THEME.accent_success or THEME.bg_tertiary
    local icon_text_col = is_added and THEME.bg_main or THEME.text_secondary
    dl:AddCircleFilled(imgui.ImVec2(icon_x + icon_sz/2, icon_y + icon_sz/2), icon_sz/2, imgui.ColorConvertFloat4ToU32(icon_bg))
    
    imgui.PushFont(font_fa)
    local item_icon = is_added and fa('check') or (is_sell and fa('box') or fa('tag'))
    local isz = imgui.CalcTextSize(item_icon)
    dl:AddText(imgui.ImVec2(icon_x + (icon_sz - isz.x)/2, icon_y + (icon_sz - isz.y)/2), imgui.ColorConvertFloat4ToU32(icon_text_col), item_icon)
    imgui.PopFont()

    imgui.PushFont(font_fa)
    local plus_icon = is_added and fa('check') or fa('plus')
    local psz = imgui.CalcTextSize(plus_icon)
    local p_col = is_added and THEME.accent_success or (is_active and THEME.accent_success or THEME.text_secondary)
    local plus_x = p.x + w - psz.x - 15.0
    dl:AddText(imgui.ImVec2(plus_x, p.y + (h - psz.y)/2), imgui.ColorConvertFloat4ToU32(p_col), plus_icon)
    imgui.PopFont()

    local text_x = icon_x + icon_sz + 12.0
    imgui.PushFont(font_main)
    local name_str = u8(item.name)
    local text_y = p.y + (h - imgui.GetFontSize()) / 2
    
    dl:PushClipRect(imgui.ImVec2(text_x, p.y), imgui.ImVec2(plus_x - 10, p.y + h), true)
    
    if item.amount then
        dl:AddText(imgui.ImVec2(text_x, p.y + 10), imgui.ColorConvertFloat4ToU32(is_added and THEME.text_secondary or THEME.text_primary), name_str)
        dl:AddText(imgui.ImVec2(text_x, p.y + 36), imgui.ColorConvertFloat4ToU32(THEME.text_secondary), u8"В наличии: " .. item.amount)
    else
        dl:AddText(imgui.ImVec2(text_x, text_y), imgui.ColorConvertFloat4ToU32(THEME.text_primary), name_str)
    end
    
    dl:PopClipRect()
    imgui.PopFont()

    imgui.Dummy(imgui.ImVec2(0, 8))
end

local function renderTargetCard(item, is_sell, index, target_table)
    local w = imgui.GetContentRegionAvail().x
    local h = 80.0 
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
        ffi.copy(cfg_modal.buf_price, tostring(item.price))
        ffi.copy(cfg_modal.buf_amount, tostring(item.amount or 1))
    end

    local bg_col = is_active and THEME.bg_tertiary or THEME.bg_secondary
    dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), imgui.ColorConvertFloat4ToU32(bg_col), 12.0)
    
    local accent = is_sell and THEME.accent_success or THEME.accent_primary
    dl:AddRectFilled(p, imgui.ImVec2(p.x + 6, p.y + h), imgui.ColorConvertFloat4ToU32(accent), 12.0, 1 + 8)

    imgui.PushFont(font_fa)
    local gear_icon = fa('gear')
    local gsz = imgui.CalcTextSize(gear_icon)
    local gear_x = p.x + w - gsz.x - 15.0
    dl:AddText(imgui.ImVec2(gear_x, p.y + (h - gsz.y)/2), imgui.ColorConvertFloat4ToU32(THEME.text_secondary), gear_icon)
    imgui.PopFont()

    local text_x = p.x + 20.0
    imgui.PushFont(font_main)
    local name_str = u8(item.name)
    
    dl:PushClipRect(imgui.ImVec2(text_x, p.y), imgui.ImVec2(gear_x - 10, p.y + h), true)
    dl:AddText(imgui.ImVec2(text_x, p.y + 12), imgui.ColorConvertFloat4ToU32(THEME.text_primary), name_str)
    dl:PopClipRect()

    local price_str = formatMoney(item.price) .. " $  •  " .. (item.amount or 1) .. " шт."
    dl:AddText(imgui.ImVec2(text_x, p.y + 40), imgui.ColorConvertFloat4ToU32(accent), price_str)
    imgui.PopFont()

    imgui.Dummy(imgui.ImVec2(0, 8))
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
    function() return win_state[0] or State.inventory_scan.active or State.buying_scan.active or State.selling.active or State.buying.active end,
    function(this)
        local io = imgui.GetIO()
        local sw, sh = getScreenResolution()
        
        local win_w = sw * 0.98
        local win_h = sh * 0.90
        if win_w > 1200 then win_w = 1200 end

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
                        subtitle = u8"Пожалуйста, откройте свой инвентарь"
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
                if m_w > 650 then m_w = 650 end
                local m_h = 560.0
                local m_x = p.x + (win_w - m_w) / 2
                local m_y = p.y + (win_h - m_h) / 2
                
                dl:AddRectFilled(imgui.ImVec2(m_x, m_y), imgui.ImVec2(m_x + m_w, m_y + m_h), imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), 24.0)
                dl:AddRect(imgui.ImVec2(m_x, m_y), imgui.ImVec2(m_x + m_w, m_y + m_h), imgui.ColorConvertFloat4ToU32(THEME.accent_primary), 24.0, 15, 3.0)
                
                imgui.PushFont(font_fa_large)
                dl:AddText(imgui.ImVec2(m_x + 35, m_y + 35), imgui.ColorConvertFloat4ToU32(THEME.accent_primary), fa('sliders'))
                imgui.PopFont()
                
                imgui.PushFont(font_main)
                dl:AddText(imgui.ImVec2(m_x + 80, m_y + 42), imgui.ColorConvertFloat4ToU32(THEME.text_secondary), u8"НАСТРОЙКА ТОВАРА")
                dl:AddLine(imgui.ImVec2(m_x, m_y + 90), imgui.ImVec2(m_x + m_w, m_y + 90), imgui.ColorConvertFloat4ToU32(THEME.border), 2.0)
                
                local item_name = u8(cfg_modal.item.name)
                local n_sz = imgui.CalcTextSize(item_name)
                dl:AddText(imgui.ImVec2(m_x + (m_w - n_sz.x)/2, m_y + 110), imgui.ColorConvertFloat4ToU32(THEME.accent_success), item_name)
                
                local input_w = m_w - 70
                local input_x = m_x + 35
                
                local price_y = m_y + 160
                dl:AddText(imgui.ImVec2(input_x, price_y), imgui.ColorConvertFloat4ToU32(THEME.text_secondary), u8"Цена за 1 шт ($):")
                imgui.SetCursorScreenPos(imgui.ImVec2(input_x, price_y + 35))
                imgui.SetNextItemWidth(input_w)
                
                imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(20.0, 25.0))
                imgui.PushStyleColor(imgui.Col.FrameBg, THEME.bg_main)
                imgui.PushStyleColor(imgui.Col.Text, THEME.text_primary)
                imgui.InputText("##cfg_price", cfg_modal.buf_price, 32, imgui.InputTextFlags.CharsDecimal)
                
                local amount_y = price_y + 125
                local amt_label = u8"Количество:"
                if cfg_modal.is_sell and cfg_modal.item.max_amount then
                    amt_label = amt_label .. u8" (В наличии: " .. cfg_modal.item.max_amount .. u8")"
                elseif not cfg_modal.is_sell then
                    amt_label = u8"Кол-во / Цвет (если аксессуар):"
                end
                dl:AddText(imgui.ImVec2(input_x, amount_y), imgui.ColorConvertFloat4ToU32(THEME.text_secondary), amt_label)
                imgui.SetCursorScreenPos(imgui.ImVec2(input_x, amount_y + 35))
                imgui.SetNextItemWidth(input_w)
                imgui.InputText("##cfg_amount", cfg_modal.buf_amount, 32, imgui.InputTextFlags.CharsDecimal)
                
                imgui.PopStyleColor(2)
                imgui.PopStyleVar()
                imgui.PopFont()

                local btn_h = 60.0
                local btn_gap = 20.0
                local btn_y_1 = m_y + m_h - (btn_h * 2) - btn_gap - 30
                local btn_y_2 = m_y + m_h - btn_h - 30
                
                local function DrawModalBtn(id, label, icon, b_x, b_y, b_w, color)
                    imgui.SetCursorScreenPos(imgui.ImVec2(b_x, b_y))
                    local clicked = false
                    if imgui.InvisibleButton(id, imgui.ImVec2(b_w, btn_h)) then clicked = true end
                    
                    local active = imgui.IsItemActive()
                    local b_bg = active and imgui.ImVec4(color.x*0.8, color.y*0.8, color.z*0.8, 1) or color
                    dl:AddRectFilled(imgui.ImVec2(b_x, b_y), imgui.ImVec2(b_x + b_w, b_y + btn_h), imgui.ColorConvertFloat4ToU32(b_bg), 14.0)
                    
                    imgui.PushFont(font_fa_large)
                    local isz = imgui.CalcTextSize(icon)
                    imgui.PopFont()
                    imgui.PushFont(font_main)
                    local tsz = imgui.CalcTextSize(u8(label))
                    local cx = b_x + (b_w - (isz.x + 12 + tsz.x))/2
                    
                    imgui.PushFont(font_fa_large)
                    dl:AddText(imgui.ImVec2(cx, b_y + (btn_h - isz.y)/2), 0xFFFFFFFF, icon)
                    imgui.PopFont()
                    dl:AddText(imgui.ImVec2(cx + isz.x + 12, b_y + (btn_h - tsz.y)/2), 0xFFFFFFFF, u8(label))
                    imgui.PopFont()
                    
                    return clicked
                end

                if DrawModalBtn("##m_save", "СОХРАНИТЬ", fa('check'), input_x, btn_y_1, input_w, THEME.accent_success) then
                    local new_price = tonumber(ffi.string(cfg_modal.buf_price)) or 1000
                    local new_amount = tonumber(ffi.string(cfg_modal.buf_amount)) or 1
                    if cfg_modal.is_sell and cfg_modal.item.max_amount and new_amount > cfg_modal.item.max_amount then
                        new_amount = cfg_modal.item.max_amount
                    end
                    cfg_modal.target_table[cfg_modal.index].price = new_price
                    cfg_modal.target_table[cfg_modal.index].amount = new_amount
                    
                    if cfg_modal.is_sell then saveJsonFile(PATH_CFG_SELL, config_sell) else saveJsonFile(PATH_CFG_BUY, config_buy) end
                    
                    cfg_modal.active = false
                end
                
                local sub_w = (input_w - btn_gap) / 2
                if DrawModalBtn("##m_cancel", "ОТМЕНА", fa('xmark'), input_x, btn_y_2, sub_w, THEME.bg_tertiary) then
                    cfg_modal.active = false
                end
                if DrawModalBtn("##m_del", "УДАЛИТЬ", fa('trash'), input_x + sub_w + btn_gap, btn_y_2, sub_w, THEME.accent_danger) then
                    table.remove(cfg_modal.target_table, cfg_modal.index)
                    
                    if cfg_modal.is_sell then saveJsonFile(PATH_CFG_SELL, config_sell) else saveJsonFile(PATH_CFG_BUY, config_buy) end
                    
                    cfg_modal.active = false
                end

            else

            local header_h = 80.0
            dl:AddRectFilled(p, imgui.ImVec2(p.x + win_w, p.y + header_h), imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), 16.0, 1 + 2)
            dl:AddLine(imgui.ImVec2(p.x, p.y + header_h), imgui.ImVec2(p.x + win_w, p.y + header_h), imgui.ColorConvertFloat4ToU32(THEME.border), 2.0)

            imgui.PushFont(font_fa_large)
            dl:AddText(imgui.ImVec2(p.x + 20, p.y + (header_h - 36)/2), imgui.ColorConvertFloat4ToU32(THEME.accent_primary), fa('code'))
            imgui.PopFont()
            imgui.PushFont(font_main)
            dl:AddText(imgui.ImVec2(p.x + 65, p.y + (header_h - imgui.GetFontSize())/2), imgui.ColorConvertFloat4ToU32(THEME.text_primary), "RMARKET")
            imgui.PopFont()

            local btn_sz = 50.0
            local right_cursor = p.x + win_w - btn_sz - 15.0
            local btn_y = p.y + (header_h - btn_sz) / 2

            imgui.SetCursorScreenPos(imgui.ImVec2(right_cursor, btn_y))
            if imgui.InvisibleButton("##close_btn", imgui.ImVec2(btn_sz, btn_sz)) then win_state[0] = false end
            local close_hov = imgui.IsItemHovered()
            if imgui.IsItemActive() then dl:AddCircleFilled(imgui.ImVec2(right_cursor + btn_sz/2, btn_y + btn_sz/2), btn_sz/2, 0x40FF0000) end
            
            imgui.PushFont(font_fa_large)
            local cx_sz = imgui.CalcTextSize(fa('xmark'))
            dl:AddText(imgui.ImVec2(right_cursor + (btn_sz - cx_sz.x)/2, btn_y + (btn_sz - cx_sz.y)/2), imgui.ColorConvertFloat4ToU32(close_hov and THEME.accent_danger or THEME.text_secondary), fa('xmark'))
            imgui.PopFont()

            right_cursor = right_cursor - btn_sz - 10.0

            imgui.SetCursorScreenPos(imgui.ImVec2(right_cursor, btn_y))
            if imgui.InvisibleButton("##scan_btn", imgui.ImVec2(btn_sz, btn_sz)) then
                if active_tab == 1 then
                    win_state[0] = false
                    startInventoryScan()
                else
                    State.buying_scan = {active=true, stage='waiting_dialog', current_page=1, all_items={}, current_dialog_id=nil}
                    sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Подойдите к лавке и нажмите кнопку взаимодействия!", -1)
                    win_state[0] = false
                end
            end
            local scan_hov = imgui.IsItemHovered()
            local scan_icon = active_tab == 1 and fa('magnifying_glass') or fa('bag_shopping')
            local scan_col = active_tab == 1 and THEME.accent_success or THEME.accent_primary
            
            if imgui.IsItemActive() then dl:AddCircleFilled(imgui.ImVec2(right_cursor + btn_sz/2, btn_y + btn_sz/2), btn_sz/2, imgui.ColorConvertFloat4ToU32(imgui.ImVec4(scan_col.x, scan_col.y, scan_col.z, 0.3))) end
            
            imgui.PushFont(font_fa_large)
            local sx_sz = imgui.CalcTextSize(scan_icon)
            dl:AddText(imgui.ImVec2(right_cursor + (btn_sz - sx_sz.x)/2, btn_y + (btn_sz - sx_sz.y)/2), imgui.ColorConvertFloat4ToU32(scan_hov and THEME.text_primary or scan_col), scan_icon)
            imgui.PopFont()

            local search_w = win_w * 0.4 
            local search_h = 45.0
            local search_x = p.x + (win_w - search_w) / 2
            local search_y = p.y + (header_h - search_h) / 2
            
            local current_buf = (active_tab == 1) and search_buf_sell or search_buf_buy
            
            dl:AddRectFilled(imgui.ImVec2(search_x, search_y), imgui.ImVec2(search_x + search_w, search_y + search_h), imgui.ColorConvertFloat4ToU32(THEME.bg_tertiary), 22.0)
            dl:AddRect(imgui.ImVec2(search_x, search_y), imgui.ImVec2(search_x + search_w, search_y + search_h), imgui.ColorConvertFloat4ToU32(THEME.border), 22.0, 15, 1.5)
            
            imgui.PushFont(font_fa)
            local search_icon = fa('magnifying_glass')
            local sisz = imgui.CalcTextSize(search_icon)
            dl:AddText(imgui.ImVec2(search_x + 15, search_y + (search_h - sisz.y)/2), imgui.ColorConvertFloat4ToU32(THEME.text_secondary), search_icon)
            imgui.PopFont()
 
            imgui.SetCursorScreenPos(imgui.ImVec2(search_x + 45, search_y))
            imgui.SetNextItemWidth(search_w - 60)
            imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0,0,0,0))
            imgui.PushStyleColor(imgui.Col.Text, THEME.text_primary)
            imgui.PushFont(font_main)
            
            imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(0, (search_h - imgui.GetFontSize()) / 2))
            local hint_text = active_tab == 1 and u8"Поиск в инвентаре..." or u8"Поиск товара..."
            imgui.InputTextWithHint("##search_bar", hint_text, current_buf, 128)
            
            imgui.PopStyleVar()
            imgui.PopFont()
            imgui.PopStyleColor(2)

            imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + header_h))
            local tab_h = 75.0
            local tab_w = win_w / 4
            
            local function DrawMobileTab(id, title, icon, x_offset)
                local is_selected = (active_tab == id)
                local tab_p = imgui.ImVec2(p.x + x_offset, p.y + header_h)
                
                imgui.SetCursorScreenPos(tab_p)
                if imgui.InvisibleButton("##tab_"..id, imgui.ImVec2(tab_w, tab_h)) then active_tab = id end
                
                local bg_col = THEME.bg_main
                if is_selected then bg_col = THEME.bg_tertiary end
                if imgui.IsItemActive() then bg_col = imgui.ImVec4(THEME.bg_tertiary.x*1.2, THEME.bg_tertiary.y*1.2, THEME.bg_tertiary.z*1.2, 1) end
                
                dl:AddRectFilled(tab_p, imgui.ImVec2(tab_p.x + tab_w, tab_p.y + tab_h), imgui.ColorConvertFloat4ToU32(bg_col))
                
                local col = is_selected and THEME.accent_primary or THEME.text_secondary
                
                imgui.PushFont(font_fa)
                local isz = imgui.CalcTextSize(icon)
                imgui.PopFont()
                imgui.PushFont(font_main)
                local tsz = imgui.CalcTextSize(u8(title))
                imgui.PopFont()
                
                local content_w = isz.x + 10 + tsz.x
                local start_x = tab_p.x + (tab_w - content_w) / 2
                
                imgui.PushFont(font_fa)
                dl:AddText(imgui.ImVec2(start_x, tab_p.y + (tab_h - isz.y)/2), imgui.ColorConvertFloat4ToU32(col), icon)
                imgui.PopFont()
                imgui.PushFont(font_main)
                dl:AddText(imgui.ImVec2(start_x + isz.x + 10, tab_p.y + (tab_h - tsz.y)/2), imgui.ColorConvertFloat4ToU32(col), u8(title))
                imgui.PopFont()
                
                if is_selected then
                    dl:AddRectFilled(imgui.ImVec2(tab_p.x, tab_p.y + tab_h - 4.0), imgui.ImVec2(tab_p.x + tab_w, tab_p.y + tab_h), imgui.ColorConvertFloat4ToU32(THEME.accent_primary))
                end
            end
            
            DrawMobileTab(1, "ПРОДАЖА", fa('arrow_up_from_bracket'), 0)
            DrawMobileTab(2, "СКУПКА", fa('arrow_down_to_bracket'), tab_w)
            DrawMobileTab(3, "ПИАР", fa('bullhorn'), tab_w * 2)
            DrawMobileTab(4, "НАСТРОЙКИ", fa('gear'), tab_w * 3)

            local footer_h = 80.0
            local content_y = p.y + header_h + tab_h
            local content_h = win_h - header_h - tab_h - footer_h
            
            local scroll_zone_w = 65.0 
            local col_padding = 10.0
            local col_gap = 25.0
            local inner_gap = 12.0
            
            local col_w = (win_w - (scroll_zone_w * 2) - (col_padding * 2) - (inner_gap * 2) - col_gap) / 2

            local function DrawScrollZone(id, x, y, w, h)
                imgui.SetCursorScreenPos(imgui.ImVec2(x, y))
                imgui.InvisibleButton(id, imgui.ImVec2(w, h))
                local active = imgui.IsItemActive()
                
                local bg_col = active and imgui.ImVec4(THEME.accent_primary.x, THEME.accent_primary.y, THEME.accent_primary.z, 0.4) or imgui.ImVec4(THEME.bg_main.x, THEME.bg_main.y, THEME.bg_main.z, 0.7)
                dl:AddRectFilled(imgui.ImVec2(x, y), imgui.ImVec2(x + w, y + h), imgui.ColorConvertFloat4ToU32(bg_col), 16.0)
                dl:AddRect(imgui.ImVec2(x, y), imgui.ImVec2(x + w, y + h), imgui.ColorConvertFloat4ToU32(THEME.border), 16.0, 15, 2.0)
                
                imgui.PushFont(font_fa_large)
                local icon = fa('arrows_up_down')
                local isz = imgui.CalcTextSize(icon)
                local col_icon = active and THEME.text_primary or THEME.text_secondary
                dl:AddText(imgui.ImVec2(x + (w - isz.x)/2, y + (h - isz.y)/2), imgui.ColorConvertFloat4ToU32(col_icon), icon)
                imgui.PopFont()
                
                return active and io.MouseDelta.y or 0
            end

            local current_search_str = to_lower(u8:decode(ffi.string(current_buf)))

            local function CenterText(text, color)
                local t_sz = imgui.CalcTextSize(text)
                imgui.SetCursorPosX((col_w - t_sz.x) / 2)
                imgui.TextColored(color, text)
            end

            if active_tab == 1 or active_tab == 2 then
                local left_scroll_x  = p.x + col_padding
                local left_list_x    = left_scroll_x + scroll_zone_w + inner_gap
                local right_list_x   = left_list_x + col_w + col_gap
                local right_scroll_x = right_list_x + col_w + inner_gap

                local delta_left = DrawScrollZone("##scroll_left", left_scroll_x, content_y + 10, scroll_zone_w, content_h - 10)
                local delta_right = DrawScrollZone("##scroll_right", right_scroll_x, content_y + 10, scroll_zone_w, content_h - 10)

                imgui.SetCursorScreenPos(imgui.ImVec2(left_list_x, content_y + 10))
                imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0,0,0,0))
                if imgui.BeginChild("SourceListCol", imgui.ImVec2(col_w, content_h - 10), false, imgui.WindowFlags.NoScrollbar) then
                    if delta_left ~= 0 then imgui.SetScrollY(imgui.GetScrollY() - delta_left) end
                    
                    imgui.PushFont(font_main)
                    local title_src = active_tab == 1 and u8"Ваш инвентарь" or u8"База товаров"
                    CenterText(title_src, THEME.text_secondary)
                    imgui.Dummy(imgui.ImVec2(0, 10))
                    imgui.PopFont()

                    local source_items = active_tab == 1 and inv_items or db_items
                    local target_config = active_tab == 1 and config_sell or config_buy
                    local cache = active_tab == 1 and ui_cache_sell or ui_cache_buy

                    if cache.query ~= current_search_str or #cache.items == 0 then
                        cache.items = {}
                        for i, item in ipairs(source_items) do
                            local item_name_lower = to_lower(item.name)
                            if current_search_str == "" or item_name_lower:find(current_search_str, 1, true) then
                                table.insert(cache.items, { data = item, original_index = i })
                            end
                        end
                        cache.query = current_search_str
                    end

                    if #cache.items > 0 then
                        local clipper = imgui.ImGuiListClipper(#cache.items)
                        while clipper:Step() do
                            for i = clipper.DisplayStart + 1, clipper.DisplayEnd do
                                local entry = cache.items[i]
                                renderSourceCard(entry.data, (active_tab == 1), entry.original_index, target_config)
                            end
                        end
                    else
                        imgui.PushFont(font_main)
                        imgui.Dummy(imgui.ImVec2(0, 20))
                        CenterText(u8"Товары не найдены", THEME.text_secondary)
                        imgui.PopFont()
                    end
                end
                imgui.EndChild()
                imgui.PopStyleColor()

                imgui.SetCursorScreenPos(imgui.ImVec2(right_list_x, content_y + 10))
                imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0,0,0,0))
                if imgui.BeginChild("TargetListCol", imgui.ImVec2(col_w, content_h - 10), false, imgui.WindowFlags.NoScrollbar) then
                    if delta_right ~= 0 then imgui.SetScrollY(imgui.GetScrollY() - delta_right) end
                    
                    imgui.PushFont(font_main)
                    local title_tgt = active_tab == 1 and u8"Список на продажу" or u8"Список на скупку"
                    CenterText(title_tgt, THEME.text_secondary)
                    imgui.Dummy(imgui.ImVec2(0, 10))
                    imgui.PopFont()

                    local target_config = active_tab == 1 and config_sell or config_buy

                    if #target_config == 0 then
                        imgui.PushFont(font_main)
                        imgui.Dummy(imgui.ImVec2(0, 20))
                        imgui.TextColored(THEME.text_secondary, u8"Список пуст.\nНажмите на предмет слева.")
                        imgui.PopFont()
                    else
                        for i, item in ipairs(target_config) do
                            renderTargetCard(item, (active_tab == 1), i, target_config)
                        end
                    end
                end
                imgui.EndChild()
                imgui.PopStyleColor()
            elseif active_tab == 3 or active_tab == 4 then
                local scroll_zone_w = 65.0 
                local list_w = win_w - scroll_zone_w - 30.0
                local delta = DrawScrollZone("##scroll_pr_sets", p.x + list_w + 20, content_y + 10, scroll_zone_w, content_h - 10)

                imgui.SetCursorScreenPos(imgui.ImVec2(p.x + 15, content_y + 10))
                imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0,0,0,0))
                
                if active_tab == 3 then
                    if imgui.BeginChild("AutoPRChild", imgui.ImVec2(list_w, content_h - 10), false, imgui.WindowFlags.NoScrollbar) then
                        local w_pos = imgui.GetWindowPos()
                        local w_size = imgui.GetWindowSize()
                        dl:PushClipRect(w_pos, imgui.ImVec2(w_pos.x + w_size.x, w_pos.y + w_size.y), true)
                        
                        if delta ~= 0 then imgui.SetScrollY(imgui.GetScrollY() - delta) end
                        imgui.PushFont(font_main)
                        
                        local is_pr_active = Settings.auto_pr.active
                        local btn_w = (list_w - 20) / 2
                        
                        if DrawStyledButton("##pr_main_btn", is_pr_active and u8"ОСТАНОВИТЬ ПИАР" or u8"ЗАПУСТИТЬ ПИАР", btn_w, 65.0, is_pr_active and THEME.accent_danger or THEME.accent_success, is_pr_active and fa('stop') or fa('play'), dl) then
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
                        
                        imgui.SameLine(nil, 20)
                        if DrawStyledButton("##pr_add_btn", u8"ДОБАВИТЬ ФРАЗУ", btn_w, 65.0, THEME.accent_primary, fa('plus'), dl) then
                            table.insert(Settings.auto_pr.items, { text = "", channel = 1, delay = 60, active = true, next_send = 0 })
                            saveJsonFile(PATH_SETTINGS, Settings)
                        end
                        
                        imgui.Dummy(imgui.ImVec2(0, 15))
                        
                        for i, item in ipairs(Settings.auto_pr.items) do
                            local p_item = imgui.GetCursorScreenPos()
                            local item_h = 145.0
                            dl:AddRectFilled(p_item, imgui.ImVec2(p_item.x + list_w, p_item.y + item_h), imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), 16.0)
                            
                            local t_p = imgui.ImVec2(p_item.x + 15, p_item.y + 15)
                            imgui.SetCursorScreenPos(t_p)
                            if imgui.InvisibleButton("##pr_act_"..i, imgui.ImVec2(50, 50)) then
                                item.active = not item.active
                                if item.active and Settings.auto_pr.active then item.next_send = os.time() + 2 end
                                saveJsonFile(PATH_SETTINGS, Settings)
                            end
                            dl:AddRectFilled(t_p, imgui.ImVec2(t_p.x + 50, t_p.y + 50), imgui.ColorConvertFloat4ToU32(item.active and THEME.accent_success or THEME.bg_main), 12.0)
                            if item.active then
                                imgui.PushFont(font_fa)
                                local check_sz = imgui.CalcTextSize(fa('check'))
                                dl:AddText(imgui.ImVec2(t_p.x + (50 - check_sz.x)/2, t_p.y + (50 - check_sz.y)/2), 0xFFFFFFFF, fa('check'))
                                imgui.PopFont()
                            end
                            
                            local ch_names = {"VR", "/b", "/s", "Chat", "/fam", "/al"}
                            local ch_colors = {0xFF00AAFF, 0xFFCCCCCC, 0xFFFFFFFF, 0xFF66FF66, 0xFFFFFF00, 0xFF00FFFF}
                            local curr_ch = item.channel or 1
                            
                            local ch_w = 90
                            local ch_p = imgui.ImVec2(p_item.x + 80, p_item.y + 15)
                            imgui.SetCursorScreenPos(ch_p)
                            if imgui.InvisibleButton("##pr_ch_"..i, imgui.ImVec2(ch_w, 50)) then
                                item.channel = (item.channel % 6) + 1
                                saveJsonFile(PATH_SETTINGS, Settings)
                            end
                            dl:AddRect(ch_p, imgui.ImVec2(ch_p.x + ch_w, ch_p.y + 50), ch_colors[curr_ch], 12.0, 15, 2.0)
                            local ch_txt = ch_names[curr_ch]
                            local ctx_sz = imgui.CalcTextSize(ch_txt)
                            dl:AddText(imgui.ImVec2(ch_p.x + (ch_w - ctx_sz.x)/2, ch_p.y + (50 - ctx_sz.y)/2), ch_colors[curr_ch], ch_txt)
                            
                            local del_w = 120
                            local del_p = imgui.ImVec2(p_item.x + 185, p_item.y + 15)
                            imgui.SetCursorScreenPos(del_p)
                            imgui.SetNextItemWidth(del_w)
                            imgui.PushStyleColor(imgui.Col.FrameBg, THEME.bg_tertiary)
                            imgui.PushStyleColor(imgui.Col.Text, THEME.text_primary)
                            imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(15.0, 15.0))
                            if imgui.InputText("##pr_del_"..i, getPRDelayBuffer(i, item.delay), 32, imgui.InputTextFlags.CharsDecimal) then
                                item.delay = tonumber(ffi.string(getPRDelayBuffer(i))) or 60
                                saveJsonFile(PATH_SETTINGS, Settings)
                            end
                            imgui.PopStyleVar()
                            imgui.PopStyleColor(2)
                            
                            local del_btn_p = imgui.ImVec2(p_item.x + list_w - 65, p_item.y + 15)
                            imgui.SetCursorScreenPos(del_btn_p)
                            if imgui.InvisibleButton("##pr_trash_"..i, imgui.ImVec2(50, 50)) then
                                table.remove(Settings.auto_pr.items, i)
                                saveJsonFile(PATH_SETTINGS, Settings)
                                break
                            end
                            local is_trash_hov = imgui.IsItemHovered()
                            dl:AddRectFilled(del_btn_p, imgui.ImVec2(del_btn_p.x + 50, del_btn_p.y + 50), imgui.ColorConvertFloat4ToU32(is_trash_hov and THEME.bg_main or THEME.bg_tertiary), 12.0)
                            imgui.PushFont(font_fa)
                            local trash_sz = imgui.CalcTextSize(fa('trash'))
                            dl:AddText(imgui.ImVec2(del_btn_p.x + (50 - trash_sz.x)/2, del_btn_p.y + (50 - trash_sz.y)/2), imgui.ColorConvertFloat4ToU32(THEME.accent_danger), fa('trash'))
                            imgui.PopFont()
                            
                            imgui.SetCursorScreenPos(imgui.ImVec2(p_item.x + 15, p_item.y + 80))
                            imgui.SetNextItemWidth(list_w - 30)
                            imgui.PushStyleColor(imgui.Col.FrameBg, THEME.bg_tertiary)
                            imgui.PushStyleColor(imgui.Col.Text, THEME.text_primary)
                            imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(15.0, 15.0))
                            if imgui.InputText("##pr_txt_"..i, getPRBuffer(i, item.text), 256) then
                                item.text = ffi.string(getPRBuffer(i))
                                saveJsonFile(PATH_SETTINGS, Settings)
                            end
                            imgui.PopStyleVar()
                            imgui.PopStyleColor(2)
                            
                            imgui.Dummy(imgui.ImVec2(0, 15))
                        end
                        imgui.PopFont()
                        imgui.Dummy(imgui.ImVec2(0, 10))
                        dl:PopClipRect()
                    end
                    imgui.EndChild()
                elseif active_tab == 4 then
                    if imgui.BeginChild("SettingsChild", imgui.ImVec2(list_w, content_h - 10), false, imgui.WindowFlags.NoScrollbar) then
                        local w_pos = imgui.GetWindowPos()
                        local w_size = imgui.GetWindowSize()
                        dl:PushClipRect(w_pos, imgui.ImVec2(w_pos.x + w_size.x, w_pos.y + w_size.y), true)
                        
                        if delta ~= 0 then imgui.SetScrollY(imgui.GetScrollY() - delta) end
                        imgui.PushFont(font_main)
                        
                        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(20.0, 25.0))
                        imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(10.0, 25.0))
                        
                        imgui.TextColored(THEME.accent_primary, u8"АВТОМАТИЗАЦИЯ ЛАВКИ")
                        
                        local t_p = imgui.GetCursorScreenPos()
                        if imgui.InvisibleButton("##cb_auto_name", imgui.ImVec2(55, 55)) then
                            b_auto_name[0] = not b_auto_name[0]
                        end
                        local is_hov = imgui.IsItemHovered()
                        local cb_bg = b_auto_name[0] and THEME.accent_success or (is_hov and imgui.ImVec4(1,1,1,0.1) or THEME.bg_tertiary)
                        dl:AddRectFilled(t_p, imgui.ImVec2(t_p.x + 55, t_p.y + 55), imgui.ColorConvertFloat4ToU32(cb_bg), 12.0)
                        if b_auto_name[0] then
                            imgui.PushFont(font_fa_large)
                            local isz = imgui.CalcTextSize(fa('check'))
                            dl:AddText(imgui.ImVec2(t_p.x + (55 - isz.x)/2, t_p.y + (55 - isz.y)/2), 0xFFFFFFFF, fa('check'))
                            imgui.PopFont()
                        end
                        
                        imgui.SameLine(nil, 20)
                        imgui.SetCursorPosY(imgui.GetCursorPosY() + 17)
                        imgui.Text(u8"Автоматически вводить название")
                        
                        imgui.TextColored(THEME.text_secondary, u8"Желаемое название лавки:")
                        imgui.PushItemWidth(list_w)
                        imgui.PushStyleColor(imgui.Col.FrameBg, THEME.bg_tertiary)
                        imgui.PushStyleColor(imgui.Col.Text, THEME.text_primary)
                        imgui.InputText("##shopname", buf_shop_name, 64)
                        imgui.PopStyleColor(2)
                        imgui.PopItemWidth()
                        
                        imgui.Dummy(imgui.ImVec2(0, 15))
                        
                        imgui.TextColored(THEME.accent_primary, u8"УВЕДОМЛЕНИЯ ТЕЛЕГРАМ / ВК")
                        
                        imgui.TextColored(THEME.text_secondary, u8"Секретный ключ (из бота RMarket):")
                        imgui.PushItemWidth(list_w)
                        imgui.PushStyleColor(imgui.Col.FrameBg, THEME.bg_tertiary)
                        imgui.PushStyleColor(imgui.Col.Text, THEME.text_primary)
                        local flags = imgui.InputTextFlags.Password
                        imgui.InputText("##apikey", buf_api_key, 128, flags)
                        imgui.PopStyleColor(2)
                        imgui.PopItemWidth()
                        
                        imgui.Dummy(imgui.ImVec2(0, 10))
                        if DrawStyledButton("##test_tg", u8"ПРОВЕРИТЬ КЛЮЧ", list_w, 55.0, THEME.accent_primary, fa('paper_plane'), dl) then
                            Settings.api_key = ffi.string(buf_api_key)
                            saveJsonFile(PATH_SETTINGS, Settings)
                            if Settings.api_key ~= "" then
                                api_TestTelegramToken()
                                sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Проверка ключа...", -1)
                            else
                                sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Введите ключ перед проверкой!", -1)
                            end
                        end
                        
                        imgui.PopStyleVar(2)
                        imgui.PopFont()
                        dl:PopClipRect()
                    end
                    imgui.EndChild()
                end
                imgui.PopStyleColor()
            end

            local footer_y = p.y + win_h - footer_h
            dl:AddRectFilled(imgui.ImVec2(p.x, footer_y), imgui.ImVec2(p.x + win_w, p.y + win_h), imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), 16.0, 4 + 8) 
            dl:AddLine(imgui.ImVec2(p.x, footer_y), imgui.ImVec2(p.x + win_w, footer_y), imgui.ColorConvertFloat4ToU32(THEME.border), 1.0)
            
            local btn_h = 55.0
            local btn_w = win_w - 30.0
            local btn_x = p.x + 15.0
            local btn_y = footer_y + (footer_h - btn_h) / 2
            
            imgui.SetCursorScreenPos(imgui.ImVec2(btn_x, btn_y))
            if imgui.InvisibleButton("##main_action_btn", imgui.ImVec2(btn_w, btn_h)) then
                if active_tab == 1 then
                    if #config_sell == 0 then
                        sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Список на продажу пуст!", -1)
                    else
                        State.selling = { active = true, stage = 'waiting_dialog', current_idx = 1, total = #config_sell, current_item = nil }
                        sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Откройте лавку для выставления товаров!", -1)
                        win_state[0] = false
                    end
                elseif active_tab == 2 then
                    if #config_buy == 0 then
                        sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Список на скупку пуст!", -1)
                    else
                        State.buying = { active = true, stage = 'waiting_dialog', current_idx = 1, total = #config_buy, current_item = nil }
                        sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Откройте лавку для выставления товаров на скупку!", -1)
                        win_state[0] = false
                    end
                elseif active_tab == 3 then
                    sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Авто-пиар сохранен!", -1)
                elseif active_tab == 4 then
                    Settings.auto_name = b_auto_name[0]
                    Settings.shop_name = ffi.string(buf_shop_name)
                    Settings.api_key = ffi.string(buf_api_key)
                    saveJsonFile(PATH_SETTINGS, Settings)
                    sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Настройки успешно сохранены!", -1)
                end
            end
            
            local btn_active = imgui.IsItemActive()
            local base_btn_col = active_tab == 1 and THEME.accent_success or (active_tab == 2 and THEME.accent_primary or THEME.bg_tertiary)
            local btn_color = btn_active and imgui.ImVec4(base_btn_col.x*0.8, base_btn_col.y*0.8, base_btn_col.z*0.8, 1) or base_btn_col
            
            dl:AddRectFilled(imgui.ImVec2(btn_x, btn_y), imgui.ImVec2(btn_x + btn_w, btn_y + btn_h), imgui.ColorConvertFloat4ToU32(btn_color), 12.0)
            
            local action_txt = ""
            local action_icon = ""
            if active_tab == 1 then
                action_txt = u8"ВЫСТАВИТЬ ТОВАРЫ НА ПРОДАЖУ"
                action_icon = fa('paper_plane')
            elseif active_tab == 2 then
                action_txt = u8"НАЧАТЬ СКУПКУ"
                action_icon = fa('shop')
            elseif active_tab == 3 then
                action_txt = u8"СОХРАНИТЬ НАСТРОЙКИ"
                action_icon = fa('floppy_disk')
            elseif active_tab == 4 then
                action_txt = u8"СОХРАНИТЬ НАСТРОЙКИ"
                action_icon = fa('floppy_disk')
            end
            
            imgui.PushFont(font_fa)
            local a_isz = imgui.CalcTextSize(action_icon)
            imgui.PopFont()
            imgui.PushFont(font_main)
            local a_tsz = imgui.CalcTextSize(action_txt)
            
            local center_ax = btn_x + (btn_w - (a_isz.x + 15 + a_tsz.x)) / 2
            
            imgui.PushFont(font_fa)
            dl:AddText(imgui.ImVec2(center_ax, btn_y + (btn_h - a_isz.y)/2), 0xFFFFFFFF, action_icon)
            imgui.PopFont()
            dl:AddText(imgui.ImVec2(center_ax + a_isz.x + 15, btn_y + (btn_h - a_tsz.y)/2), 0xFFFFFFFF, action_txt)
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
        print("[RMarket] Ошибка: requests == nil")
        return
    end

    lua_thread.create(function()
        print("[RMarket] Запуск проверки ключа...")
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
            print("[RMarket] Сбой pcall (системная ошибка сети): " .. tostring(res))
            sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Системная ошибка сети! Смотрите moonloader.log", -1)
            return
        end
        
        print("[RMarket] Код ответа сервера: " .. tostring(res and res.status_code or "N/A"))
        
        if res and res.status_code == 200 then
            print("[RMarket] Ответ сервера: " .. tostring(res.text))
            local ok_json, data = pcall(cjson.decode, res.text)
            if ok_json then
                if data.status == 'success' then
                    sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Ключ успешно привязан к Telegram!", -1)
                else
                    sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ошибка привязки: " .. tostring(data.message or "Неизвестная ошибка"), -1)
                end
            else
                print("[RMarket] Ошибка парсинга JSON: " .. tostring(res.text))
                sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ошибка сервера: неверный формат ответа.", -1)
            end
        else
            print("[RMarket] Неверный статус код или пустой ответ.")
            sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ошибка сети или неверный ключ!", -1)
        end
    end)
end

function main()
    while not isSampAvailable() do wait(100) end
    
    lua_thread.create(function()
        while not sampIsLocalPlayerSpawned() do wait(100) end
        if Settings.api_key ~= "" then
            State.silent_stats = true
            sampSendChat("/stats")
        end
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