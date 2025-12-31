script_name("RodinaMarket")
script_version("1.6")

-- === АВТООБНОВЛЕНИЕ СКРИПТА (С МЕНЮ ПОДТВЕРЖДЕНИЯ) ===
-- https://github.com/qrlk/moonloader-script-updater
local enable_autoupdate = true

function checkScriptUpdate()
    if not enable_autoupdate then return end
    
    lua_thread.create(function()
        local json_url = "https://raw.githubusercontent.com/RuRamzes/RodinaMarket/main/version.json?" .. tostring(os.clock())
        local e = os.tmpname()
        
        if doesFileExist(e) then os.remove(e) end
        
        downloadUrlToFile(json_url, e, function(id, status, p1, p2)
            local download_status = require('moonloader').download_status
            
            if status == download_status.STATUSEX_ENDDOWNLOAD then
                if doesFileExist(e) then
                    local k = io.open(e, 'r')
                    if k then
                        local json_data = decodeJson(k:read('*a'))
                        k:close()
                        os.remove(e)
                        
                        if json_data and json_data.latest and json_data.updateurl then
                            local update_version = json_data.latest
                            local current_version = thisScript().version
                            
                            if update_version ~= current_version then
                                -- Обновление доступно!
                                DownloadState.update_available = true
                                DownloadState.update_version = update_version
                                DownloadState.update_url = json_data.updateurl
                                DownloadState.update_alpha = 0.0
                                print(string.format("[RodinaMarket] Обновление доступно: %s -> %s", current_version, update_version))
                            else
                                print(string.format("[RodinaMarket] Вы используете актуальную версию: %s", current_version))
                            end
                        end
                    end
                end
            end
        end)
    end)
end

-- === КОНЕЦ АВТООБНОВЛЕНИЯ ===

require('lib.moonloader')
local imgui = require 'mimgui'
local ffi = require 'ffi'
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8
local lfs = require 'lfs'
local json = require 'dkjson'
local events = require('lib.samp.events')
local fa = require 'fAwesome6'
local effil = require 'effil'

local ROOT_PATH = getWorkingDirectory() .. '\\RMarket\\'
local PATHS = {
    ROOT = ROOT_PATH,
    DATA = ROOT_PATH .. 'data\\',
    LOGS = ROOT_PATH .. 'logs\\',
    CACHE = ROOT_PATH .. 'cache\\',
    SETTINGS = ROOT_PATH .. 'settings.json'
}

local SERVER_NAMES = {
    ["western.rodina-rp.com:7777"] = "Западный",
    ["primorsky.rodina-rp.com:7777"] = "Приморский", 
    ["federal.rodina-rp.com:7777"] = "Федеральный",
    ["southern.rodina-rp.com:8904"] = "Южный",
    ["eastern.rodina-rp.com:7777"] = "Восточный",
    ["northern.rodina-rp.com:8904"] = "Северный",
    ["central.rodina-rp.com:7777"] = "Центральный"
}

function getServerDisplayName(serverId)
    return SERVER_NAMES[serverId] or serverId
end

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
    tasks_list = {},
	remote_shop_active = false
}

local tabs = {
    {id = 1, name = "Продажа", icon = fa('cart_shopping')},
    {id = 2, name = "Скупка", icon = fa('bag_shopping')},
    {id = 3, name = "Логи", icon = fa('file_lines')},
    {id = 4, name = "Маркет", icon = fa('globe')}, -- НОВАЯ ВКЛАДКА
    {id = 5, name = "Настройки", icon = fa('gear')}
}

local Data = {
    scanned_items = {},
    sell_list = {},
    buy_list = {},
	live_shop = {
        sell = {},
        buy = {}
    },
    cached_items = {},
    unsellable_items = {},
    buyable_items = {},
    
    -- НОВЫЕ ПОЛЯ ДЛЯ ЛОГОВ:
    current_view_logs = {}, -- Логи, которые мы видим сейчас на экране
    available_log_dates = {}, -- Список дат (файлов), которые есть в папке
    
    cef_slots_data = {},
    cef_sell_queue = {},
    cef_inventory_items = {},
    item_names = {},
    average_prices = {},
    settings = { 
        auto_name_enabled = false,
        shop_name = "Rodina Market",
		ui_scale_mode = 1,
		show_remote_shop_menu = true
    },
	remote_shop_items = {}
}

local MarketConfig = {
    URL = "http://195.133.8.145:3030", -- УКАЖИ ЗДЕСЬ IP СВОЕГО СЕРВЕРА
    UPDATE_INTERVAL = 60, -- Секунд
    FETCH_INTERVAL = 10   -- Секунд (для списка)
}

local MarketData = {
    shops_list = {},      -- Список всех лавок
    selected_shop = nil,  -- Детали выбранной лавки
    last_sent = 0,        -- Таймер отправки
    last_fetch = 0,       -- Таймер получения
    is_loading = false,
    current_server_id = 0,
    search_buffer = imgui.new.char[128](),
    online_count = 0      -- [FIX] Счетчик онлайна
}

local ShopState = {
    has_active_items = false,  -- Флаг наличия активных товаров
    last_check_time = 0,
    check_interval = 30  -- Проверять каждые 30 секунд
}

-- === ИНДЕКСЫ ДЛЯ БЫСТРОГО ПОИСКА === --
-- Для оптимизации поиска по model_id и другим часто используемым полям
local data_indexes = {
    sell_list_by_model_id = {},
    buy_list_by_model_id = {},
    items_by_model_id = {},
    shops_by_nickname = {}
}

-- Функция для перестройки индексов при изменении данных
local function rebuildIndexes()
    data_indexes.sell_list_by_model_id = {}
    data_indexes.buy_list_by_model_id = {}
    
    for i, item in ipairs(Data.sell_list) do
        if item and item.model_id then
            data_indexes.sell_list_by_model_id[item.model_id] = i
        end
    end
    
    for i, item in ipairs(Data.buy_list) do
        if item and item.model_id then
            data_indexes.buy_list_by_model_id[item.model_id] = i
        end
    end
end

local ITEMS_GITHUB_URL = "https://raw.githubusercontent.com/RuRamzes/RodinaMarket/main/items.json" 

local DownloadState = {
    is_missing = false,
    is_downloading = false,
    progress = 0,
    status_text = "Файл items.json не найден",
    show_window = imgui.new.bool(true),
    should_reload = false,
    alpha = 0.0,          
    icon_rotation = 0.0,
    
    -- === СОСТОЯНИЕ ДЛЯ ОБНОВЛЕНИЯ СКРИПТА ===
    update_available = false,
    update_version = nil,
    update_url = nil,
    update_in_progress = false,
    update_alpha = 0.0,
}

local Buffers = {
    logs_search = imgui.new.char[128](),
    sell_search = imgui.new.char[128](),
    buy_search = imgui.new.char[128](),
    
    logs_current_date_idx = 0, -- Индекс выбранной даты в комбобоксе
    logs_dates_cache = {}, -- Кэш для комбобокса (строки)
    
    input_buffers = {},
    buy_input_buffers = {},
    sell_input_buffers = {},
    log_filters = {
        -- Оставляем только галочки продаж/покупок, фильтр времени переезжает в выбор файла
        show_sales = imgui.new.bool(true),
        show_purchases = imgui.new.bool(true),
    },
    settings = {
        shop_name = imgui.new.char[64](),
        auto_name = imgui.new.bool(false),
		ui_scale_combo = imgui.new.int(1),
		show_remote_shop_menu = imgui.new.bool(true),
		theme_combo = imgui.new.int(0) -- 0 = DARK, 1 = LIGHT
    },
	remote_shop_search = imgui.new.char[128]()
}

local State = {
    buying_scan = { active = false, stage = nil, current_page = 1, all_items = {}, current_dialog_id = nil },
    buying = { active = false, stage = nil, current_item_index = 1, items_to_buy = {}, last_search_name = nil },
    smooth_scroll = { current = 0.0, target = 0.0, speed = 18.0, wheel_step = 80.0 },
    log_stats = { total_sales = 0, total_purchases = 0, sales_amount = 0, purchases_amount = 0 },
    avg_scan = { active = false, processed_count = 0 },
    sell_total = 0,
    buy_total = 0
}

local refreshed_buyables = {}
local refresh_buyables = false
local last_buy_search = ""

-- === КЭШИРОВАНИЕ ФИЛЬТРАЦИИ === --
-- Кэш результатов поиска для оптимизации производительности
local search_cache = {
    sell_items = { query = "", result = {}, timestamp = 0 },
    buy_items = { query = "", result = {}, timestamp = 0 },
    shops_list = { query = "", result = {}, timestamp = 0 },
    remote_items = { query = "", result = {}, timestamp = 0 }
}

-- Функция очистки кэша спустя время
local CACHE_EXPIRE_TIME = 0.5 -- Кэш живет 0.5 секунд

local function invalidateSearchCache(cache_name)
    if search_cache[cache_name] then
        search_cache[cache_name].query = nil
        search_cache[cache_name].timestamp = 0
    end
end

local function getSearchResults(cache_name, data_list, search_query, search_func)
    local cache = search_cache[cache_name]
    local now = os.clock()
    
    -- Если кэш еще свежий и запрос совпадает, возвращаем кэшированный результат
    if cache.query == search_query and (now - cache.timestamp) < CACHE_EXPIRE_TIME then
        return cache.result
    end
    
    -- Иначе пересчитываем
    local result = search_func(data_list, search_query)
    cache.query = search_query
    cache.result = result
    cache.timestamp = now
    return result
end

-- Кэш для форматирования денег и средних цен
local money_format_cache = setmetatable({}, {__mode = 'v'})
local average_price_cache = setmetatable({}, {__mode = 'v'})
local lower_cache = setmetatable({}, {__mode = 'v'})

-- Функция для очистки кэшей если они растут слишком большими
local CACHE_SIZE_LIMIT = 500

function cleanupCaches()
    -- Очищаем money_format_cache если он растет слишком большим
    if money_format_cache then
        local count = 0
        for _ in pairs(money_format_cache) do count = count + 1 end
        if count > CACHE_SIZE_LIMIT then
            for k, _ in pairs(money_format_cache) do
                money_format_cache[k] = nil
            end
        end
    end
    
    -- Очищаем average_price_cache
    if average_price_cache then
        local count = 0
        for _ in pairs(average_price_cache) do count = count + 1 end
        if count > CACHE_SIZE_LIMIT then
            for k, _ in pairs(average_price_cache) do
                average_price_cache[k] = nil
            end
        end
    end
end

local anim_tabs = {
    current_pos = 0.0,
    target_pos = 0.0,
    width = 0.0
}

local sw, sh = getScreenResolution()

-- == DYNAMIC SCALING (NOW WORKING) == --
-- Масштаб интерфейса применяется в зависимости от выбора пользователя
local CURRENT_SCALE = 1.0 
local SCALE_MODES = {
    [0] = 0.85,  -- Компактный
    [1] = 1.0,   -- Стандартный
    [2] = 1.25   -- Крупный
}

-- Garbage Collector protection for fonts
local fa_glyph_ranges = imgui.new.ImWchar[3](fa.min_range, fa.max_range, 0)

-- Функция S() применяет масштабирование
function S(value)
    local scaled = math.floor(value * CURRENT_SCALE + 0.5)
    return scaled > 0 and scaled or 1
end

-- === СИСТЕМА ТЕМ ДЛЯ AAA-УРОВНЯ UI === --
-- Современные цветовые схемы вдохновленные популярными играми
local THEME_COLORS = {
    DARK_MODERN = {
        bg_main = imgui.ImVec4(0.08, 0.08, 0.12, 1.0),
        bg_secondary = imgui.ImVec4(0.12, 0.12, 0.16, 1.0),
        bg_tertiary = imgui.ImVec4(0.15, 0.15, 0.20, 1.0),
        accent_primary = imgui.ImVec4(0.40, 0.25, 0.95, 1.0),   -- Фиолетовый неон
        accent_secondary = imgui.ImVec4(0.20, 0.70, 0.95, 1.0),  -- Синий неон
        accent_success = imgui.ImVec4(0.10, 0.85, 0.35, 1.0),    -- Зеленый неон
        accent_danger = imgui.ImVec4(1.0, 0.20, 0.30, 1.0),      -- Красный
        accent_warning = imgui.ImVec4(1.0, 0.70, 0.10, 1.0),     -- Оранжевый
        text_primary = imgui.ImVec4(0.95, 0.95, 0.98, 1.0),
        text_secondary = imgui.ImVec4(0.70, 0.70, 0.75, 1.0),
        text_hint = imgui.ImVec4(0.50, 0.50, 0.55, 1.0),
        border_light = imgui.ImVec4(0.25, 0.25, 0.35, 1.0),
        border_accent = imgui.ImVec4(0.40, 0.25, 0.95, 0.5),
    },
    LIGHT_MODERN = {
        bg_main = imgui.ImVec4(0.97, 0.97, 0.99, 1.0),           -- Почти белый
        bg_secondary = imgui.ImVec4(0.90, 0.91, 0.94, 1.0),      -- Светло-серый
        bg_tertiary = imgui.ImVec4(0.85, 0.86, 0.90, 1.0),       -- Светлый серый
        accent_primary = imgui.ImVec4(0.45, 0.25, 0.85, 1.0),    -- Глубокий фиолетовый
        accent_secondary = imgui.ImVec4(0.15, 0.65, 0.95, 1.0),  -- Насыщенный синий
        accent_success = imgui.ImVec4(0.10, 0.75, 0.30, 1.0),    -- Насыщенный зеленый
        accent_danger = imgui.ImVec4(0.90, 0.15, 0.25, 1.0),     -- Насыщенный красный
        accent_warning = imgui.ImVec4(0.95, 0.60, 0.05, 1.0),    -- Насыщенный оранжевый
        text_primary = imgui.ImVec4(0.05, 0.05, 0.10, 1.0),      -- Почти черный (очень темный)
        text_secondary = imgui.ImVec4(0.20, 0.20, 0.30, 1.0),    -- Темно-серый
        text_hint = imgui.ImVec4(0.45, 0.45, 0.55, 1.0),         -- Серый (для подсказок)
        border_light = imgui.ImVec4(0.55, 0.55, 0.65, 1.0),      -- Темный серый для границ
        border_accent = imgui.ImVec4(0.45, 0.25, 0.85, 0.4),     -- Темный фиолетовый для границ
    }
}

-- Текущая активная тема (по умолчанию темная)
local CURRENT_THEME = THEME_COLORS.DARK_MODERN

-- Функция для применения темы
function applyTheme(theme_name)
    if THEME_COLORS[theme_name] then
        CURRENT_THEME = THEME_COLORS[theme_name]
        -- Здесь можно сохранить выбор темы
        if Data.settings then
            Data.settings.current_theme = theme_name
            saveSettings()
        end
    end
end

-- Вспомогательная функция для интерполяции цветов
function lerpColor(col1, col2, t)
    return imgui.ImVec4(
        col1.x + (col2.x - col1.x) * t,
        col1.y + (col2.y - col1.y) * t,
        col1.z + (col2.z - col1.z) * t,
        col1.w + (col2.w - col1.w) * t
    )
end

-- === КЭШИРОВАНИЕ TOTALS ДЛЯ ПРОИЗВОДИТЕЛЬНОСТИ === --
local sell_total_cache = { value = 0, timestamp = 0 }
local buy_total_cache = { value = 0, timestamp = 0 }
local TOTAL_CACHE_TIME = 0.1 -- Кэш живет 0.1 секунды

-- === СИСТЕМА TOAST-УВЕДОМЛЕНИЙ === --
local toast_notifications = {}

local function addToastNotification(message, notification_type, duration)
    notification_type = notification_type or "info"
    duration = duration or 3.0
    
    local color_map = {
        success = CURRENT_THEME.accent_success,
        error = CURRENT_THEME.accent_danger,
        warning = CURRENT_THEME.accent_warning,
        info = CURRENT_THEME.accent_primary
    }
    
    table.insert(toast_notifications, {
        message = message,
        type = notification_type,
        color = color_map[notification_type] or CURRENT_THEME.accent_primary,
        created_at = os.clock(),
        duration = duration,
        alpha = 0.0
    })
end

local function renderToastNotifications()
    local draw_list = imgui.GetBackgroundDrawList()
    local sw, sh = getScreenResolution()
    
    local current_time = os.clock()
    local y_offset = sh - 120
    
    for i = #toast_notifications, 1, -1 do
        local toast = toast_notifications[i]
        local elapsed = current_time - toast.created_at
        local progress = elapsed / toast.duration
        
        -- Анимация входа
        if elapsed < 0.3 then
            toast.alpha = (elapsed / 0.3) * 0.9
        elseif progress > 0.85 then
            toast.alpha = (1.0 - (progress - 0.85) / 0.15) * 0.9
        else
            toast.alpha = 0.9
        end
        
        if toast.alpha > 0.01 then
            -- Размеры
            local padding = S(20)
            local text_size = imgui.CalcTextSize(u8(toast.message))
            local width = text_size.x + padding * 2 + S(40)
            local height = text_size.y + padding
            
            local x = sw - width - S(20)
            local y = y_offset - (height + S(15))
            
            -- Отрисовка фона с затемнением
            local bg_color = imgui.ColorConvertFloat4ToU32(
                imgui.ImVec4(CURRENT_THEME.bg_secondary.x, CURRENT_THEME.bg_secondary.y, 
                             CURRENT_THEME.bg_secondary.z, toast.alpha)
            )
            
            -- Граница с акцентным цветом
            local border_color = imgui.ColorConvertFloat4ToU32(
                imgui.ImVec4(toast.color.x, toast.color.y, toast.color.z, toast.alpha)
            )
            
            draw_list:AddRectFilled(imgui.ImVec2(x, y), imgui.ImVec2(x + width, y + height), bg_color, S(8))
            draw_list:AddRect(imgui.ImVec2(x, y), imgui.ImVec2(x + width, y + height), border_color, S(8), imgui.DrawCornerFlags.All, S(2))
            
            -- Иконка типа
            local icon_x = x + padding
            local icon_y = y + (height - S(16)) / 2
            local icon_map = {
                success = fa('check_circle'),
                error = fa('circle_exclamation'),
                warning = fa('triangle_exclamation'),
                info = fa('circle_info')
            }
            
            -- Текст
            local text_color = imgui.ColorConvertFloat4ToU32(
                imgui.ImVec4(toast.color.x, toast.color.y, toast.color.z, toast.alpha * 1.5)
            )
            draw_list:AddText(imgui.ImVec2(icon_x + S(25), y + padding * 0.5), text_color, u8(toast.message))
            
            y_offset = y
        end
        
        if elapsed > toast.duration then
            table.remove(toast_notifications, i)
        end
    end
end

function calculateSellTotal()
    local now = os.clock()
    
    -- Если кэш еще свежий, возвращаем его
    if (now - sell_total_cache.timestamp) < TOTAL_CACHE_TIME then
        return sell_total_cache.value
    end
    
    local total = 0
    for _, item in ipairs(Data.sell_list) do
        if item.active ~= false then 
            total = total + (tonumber(item.price) or 0) * (tonumber(item.amount) or 1)
        end
    end
    State.sell_total = total
    sell_total_cache.value = total
    sell_total_cache.timestamp = now
    return total
end

function calculateBuyTotal()
    local now = os.clock()
    
    -- Если кэш еще свежий, возвращаем его
    if (now - buy_total_cache.timestamp) < TOTAL_CACHE_TIME then
        return buy_total_cache.value
    end
    
    local total = 0
    for _, item in ipairs(Data.buy_list) do
        if item.active ~= false then -- Учитываем только активные
            total = total + (tonumber(item.price) or 0) * (tonumber(item.amount) or 1)
        end
    end
    State.buy_total = total
    buy_total_cache.value = total
    buy_total_cache.timestamp = now
    return total
end

local pending_effil_requests = {}

-- Функция-воркер, которая будет работать в отдельном потоке
function httpRequestWorker(method, url, args)
    local requests = require 'requests' -- Подключаем только внутри потока
    local result = {}
    
    -- Безопасный вызов запроса
    local status, response = pcall(function()
        return requests.request(method, url, args)
    end)

    if status and response then
        result.success = true
        result.status_code = response.status_code
        result.text = response.text
        -- Копируем заголовки в простую таблицу, чтобы effil мог их передать
        result.headers = {}
        if response.headers then
            for k, v in pairs(response.headers) do
                result.headers[k] = v
            end
        end
    else
        result.success = false
        result.error = tostring(response)
    end

    return result
end

-- == ФУНКЦИОНАЛ ФАЙЛОВОЙ СИСТЕМЫ == --

-- Создание папок, если их нет
function ensureDirectories()
    local dirs = {PATHS.ROOT, PATHS.DATA, PATHS.LOGS, PATHS.CACHE}
    for _, dir in ipairs(dirs) do
        if not doesDirectoryExist(dir) then
            createDirectory(dir)
        end
    end
    
    -- Создаем пустой файл item_amounts.json, если его нет
    local item_amounts_path = PATHS.DATA .. 'item_amounts.json'
    if not doesFileExist(item_amounts_path) then
        -- ИСПРАВЛЕНИЕ: Используем io.open вместо saveJsonFile, чтобы избежать рекурсии
        local f = io.open(item_amounts_path, "w")
        if f then
            f:write("{}")
            f:close()
        end
    end
end

-- Чтение JSON файла (UTF-8 -> CP1251) с улучшенной обработкой ошибок
function loadJsonFile(path, default_value)
    if not doesFileExist(path) then 
        return default_value 
    end
    
    local file = io.open(path, "r")
    if not file then return default_value end
    
    local content = file:read("*a")
    file:close()
    
    if not content or #content == 0 then return default_value end
    
    local status, result = pcall(json.decode, content)
    if not status or not result then return default_value end
    
    local function convertTableToCP1251(tbl)
        if type(tbl) ~= "table" then return tbl end
        local new_tbl = {}
        for k, v in pairs(tbl) do
            -- Безопасное преобразование ключей
            local new_k = k
            if type(k) == "string" then
                local s, res = pcall(u8.decode, u8, k)
                if s then new_k = res end
            end
            
            local new_v = v
            if type(v) == "string" then
                -- Безопасное преобразование значений
                local s, res = pcall(u8.decode, u8, v)
                if s then new_v = res end
            elseif type(v) == "table" then
                new_v = convertTableToCP1251(v)
            end
            new_tbl[new_k] = new_v
        end
        return new_tbl
    end
    
    return convertTableToCP1251(result)
end

-- Запись JSON файла (CP1251 -> UTF-8) с обработкой ошибок
function saveJsonFile(path, data)
    ensureDirectories()
    
    if not data or type(data) ~= "table" then
        -- Используем print вместо sampAddChatMessage, чтобы не спамить в чат
        print('[RodinaMarket] Ошибка: неверные данные для сохранения в ' .. path)
        return false
    end
    
    local status, err = pcall(function()
        -- Рекурсивная конвертация CP1251 -> UTF8 для сохранения
        local function convertTableToUTF8(tbl)
            if not tbl or type(tbl) ~= "table" then 
                return tbl 
            end
            
            local new_tbl = {}
            for k, v in pairs(tbl) do
                local new_k = type(k) == "string" and u8(k) or k
                local new_v = v
                if type(v) == "string" then
                    new_v = u8(v)
                elseif type(v) == "table" then
                    new_v = convertTableToUTF8(v)
                end
                new_tbl[new_k] = new_v
            end
            return new_tbl
        end
        
        local export_data = convertTableToUTF8(data)
        local content = json.encode(export_data, { indent = true })
        
        -- Атомарная запись: пишем в .tmp, потом переименовываем
        local temp_path = path .. ".tmp"
        local file = io.open(temp_path, "w+")
        if file then
            file:write(content)
            file:close()
            
            -- Удаляем старый файл и ставим на его место новый
            os.remove(path)
            os.rename(temp_path, path)
        else
            error("Не удалось открыть файл для записи: " .. temp_path)
        end
    end)
    
    if not status then
        -- Также заменяем на print для ошибок записи
        print('[RodinaMarket] Ошибка сохранения в ' .. path .. ': ' .. tostring(err))
        return false
    end
    
    return true
end

function loadItemNames()
    local items_file = getWorkingDirectory() .. "\\RMarket\\items.json"
    local file = io.open(items_file, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local status, result = pcall(json.decode, content)
        if status and result then
            Data.item_names = {}
            for id, name in pairs(result) do
                Data.item_names[id] = u8:decode(name)
            end
        end
    end
end

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
        transaction.player = player_sale:gsub("^%s*(.-)%s*$", "%1")
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
    
    -- Определяем файл текущего дня
    local current_date_str = os.date("%Y-%m-%d")
    local file_path = PATHS.LOGS .. current_date_str .. ".json"
    
    -- Загружаем текущие логи за день (или создаем пустой список)
    local day_logs = loadJsonFile(file_path, {})
    
    -- Добавляем новый лог
    table.insert(day_logs, transaction)
    
    -- Сохраняем обратно в файл
    saveJsonFile(file_path, day_logs)
    
    -- Обновляем UI, если мы смотрим на этот день
    if App.active_tab == 3 then
        refreshLogDates() -- Обновить список дат, если вдруг наступил новый день
        updateLogView() -- Обновить таблицу
    end
end

-- Кэш для форматирования денег
local money_format_cache = setmetatable({}, {__mode = 'v'})

function formatMoney(amount)
    -- Защита от nil и конвертация строки в число
    local val = tonumber(amount)
    if not val then return "0" end
    
    -- Проверяем кэш
    if money_format_cache[val] then
        return money_format_cache[val]
    end
    
    local result
    if val < 1000 then
        result = tostring(val)
    else
        local formatted = tostring(val)
        result = ""
        local counter = 0
        for i = #formatted, 1, -1 do
            counter = counter + 1
            result = formatted:sub(i, i) .. result
            if counter % 3 == 0 and i ~= 1 then result = "." .. result end
        end
    end
    
    money_format_cache[val] = result
    return result
end

function downloadItemsFile()
    if DownloadState.is_downloading then return end 
    
    DownloadState.is_downloading = true
    DownloadState.status_text = "Установка соединения..."
    DownloadState.progress = 0
    
    local file_path = PATHS.ROOT .. "items.json"
    
    -- Удаляем старый файл перед загрузкой, если он есть, 
    -- чтобы проверка в конце была честной
    if doesFileExist(file_path) then os.remove(file_path) end

    downloadUrlToFile(ITEMS_GITHUB_URL, file_path, function(id, status, p1, p2)
        -- 1 = STATUS_DOWNLOADINGDATA
        if status == 1 then
            if p1 and p2 and p2 > 0 then 
                local percent = math.floor((p1 / p2) * 100)
                DownloadState.progress = percent / 100
                DownloadState.status_text = string.format("Загрузка: %d%%", percent)
            end
            
        -- 2, 3, 4 часто означают успешное завершение в разных версиях API
        elseif status == 2 or status == 3 or status == 4 then
            -- Ждем долю секунды, чтобы система "отпустила" файл
            lua_thread.create(function()
                wait(200) 
                if doesFileExist(file_path) then
                    local f = io.open(file_path, "r")
                    if f then
                        local size = f:seek("end")
                        f:close()
                        if size > 0 then
                            DownloadState.status_text = "Файл получен! Перезапуск..."
                            DownloadState.progress = 1.0
                            DownloadState.should_reload = true
                            return
                        end
                    end
                end
                -- Если файла нет или он 0 байт
                DownloadState.is_downloading = false
                DownloadState.status_text = "Ошибка: файл пустой."
            end)

        -- 5 = STATUS_ERROR
        elseif status == 5 then
            DownloadState.is_downloading = false
            DownloadState.status_text = "Сетевая ошибка (код 5)."
        end
    end)
end

function downloadScriptUpdate()
    if DownloadState.update_in_progress then return end 
    
    DownloadState.update_in_progress = true
    DownloadState.status_text = "Установка соединения..."
    DownloadState.progress = 0
    
    local script_path = thisScript().path
    local backup_path = script_path .. ".backup"
    
    -- Создаем резервную копию
    if doesFileExist(script_path) then
        os.execute("copy \"" .. script_path .. "\" \"" .. backup_path .. "\"")
    end

    downloadUrlToFile(DownloadState.update_url, script_path, function(id, status, p1, p2)
        -- 1 = STATUS_DOWNLOADINGDATA
        if status == 1 then
            if p1 and p2 and p2 > 0 then 
                local percent = math.floor((p1 / p2) * 100)
                DownloadState.progress = percent / 100
                DownloadState.status_text = string.format("Загрузка: %d%%", percent)
            end
            
        -- 2, 3, 4 = Успешное завершение
        elseif status == 2 or status == 3 or status == 4 then
            lua_thread.create(function()
                wait(200) 
                if doesFileExist(script_path) then
                    local f = io.open(script_path, "r")
                    if f then
                        local size = f:seek("end")
                        f:close()
                        if size > 0 then
                            DownloadState.status_text = "Обновление завершено! Перезагружаюсь..."
                            DownloadState.progress = 1.0
                            wait(1500)
                            thisScript():reload()
                            return
                        end
                    end
                end
                -- Если файла нет или он 0 байт - восстанавливаем из резервной копии
                DownloadState.update_in_progress = false
                DownloadState.status_text = "Ошибка загрузки. Восстанавливаю старую версию..."
                wait(1000)
                if doesFileExist(backup_path) then
                    os.execute("copy \"" .. backup_path .. "\" \"" .. script_path .. "\"")
                end
                DownloadState.update_available = false
                DownloadState.update_in_progress = false
            end)

        -- 5 = STATUS_ERROR
        elseif status == 5 then
            DownloadState.update_in_progress = false
            DownloadState.status_text = "Сетевая ошибка. Восстанавливаю старую версию..."
            wait(1000)
            if doesFileExist(backup_path) then
                os.execute("copy \"" .. backup_path .. "\" \"" .. script_path .. "\"")
            end
            DownloadState.update_available = false
        end
    end)
end

function loadAllData()
    ensureDirectories()
    
    local loaded_settings = loadJsonFile(PATHS.SETTINGS, {})
    
    Data.settings.auto_name_enabled = loaded_settings.auto_name_enabled or false
    Data.settings.shop_name = loaded_settings.shop_name or "Rodina Market"
    Data.settings.ui_scale_mode = loaded_settings.ui_scale_mode or 1
    Data.settings.show_remote_shop_menu = loaded_settings.show_remote_shop_menu ~= false
    Data.settings.current_theme = loaded_settings.current_theme or "DARK_MODERN"
    
    Buffers.settings.auto_name[0] = Data.settings.auto_name_enabled
    Buffers.settings.ui_scale_combo[0] = Data.settings.ui_scale_mode
    Buffers.settings.show_remote_shop_menu[0] = Data.settings.show_remote_shop_menu
    
    -- Определяем индекс темы для комбобокса (0 = DARK, 1 = LIGHT)
    if Data.settings.current_theme == "LIGHT_MODERN" then
        Buffers.settings.theme_combo[0] = 1
    else
        Buffers.settings.theme_combo[0] = 0
    end
    
    imgui.StrCopy(Buffers.settings.shop_name, Data.settings.shop_name)
    
    Data.sell_list = loadJsonFile(PATHS.DATA .. 'sell_items.json', {})
    Data.buy_list = loadJsonFile(PATHS.DATA .. 'buy_items.json', {})
    
    -- Валидация и очистка поломанных данных
    local cleaned_sell = {}
    for _, item in ipairs(Data.sell_list) do
        if item and item.model_id then
            if item.active == nil then item.active = true end
            table.insert(cleaned_sell, item)
        end
    end
    Data.sell_list = cleaned_sell
    
    local cleaned_buy = {}
    for _, item in ipairs(Data.buy_list) do
        if item and item.model_id then
            if item.active == nil then item.active = true end
            table.insert(cleaned_buy, item)
        end
    end
    Data.buy_list = cleaned_buy
    
    -- Перестраиваем индексы после загрузки данных
    rebuildIndexes()
    
    Data.unsellable_items = loadJsonFile(PATHS.DATA .. 'unsellable.json', {})
    Data.cached_items = loadJsonFile(PATHS.CACHE .. 'cached_items.json', {})
    Data.scanned_items = loadJsonFile(PATHS.CACHE .. 'scanned_items.json', {})
    Data.average_prices = loadJsonFile(PATHS.CACHE .. 'average_prices.json', {})
    Data.buyable_items = loadJsonFile(PATHS.CACHE .. 'buyable_items.json', {})
    Data.inventory_item_amounts = loadJsonFile(PATHS.DATA .. 'item_amounts.json', {})
    
    if #Data.buyable_items > 0 then
        refresh_buyables = true
        refreshed_buyables = {}
    end
    
    -- Инициализируем список дат логов
    refreshLogDates()
    
    print("[RodinaMarket] Data loaded. Scale Mode: " .. Data.settings.ui_scale_mode .. " Theme: " .. Data.settings.current_theme)
end

function saveSettings()
    local status, err = pcall(function()
        Data.settings.auto_name_enabled = Buffers.settings.auto_name[0]
        Data.settings.shop_name = ffi.string(Buffers.settings.shop_name)
        Data.settings.ui_scale_mode = Buffers.settings.ui_scale_combo[0]
        Data.settings.show_remote_shop_menu = Buffers.settings.show_remote_shop_menu[0]
        
        -- Сохраняем текущую тему
        if Buffers.settings.theme_combo[0] == 1 then
            Data.settings.current_theme = "LIGHT_MODERN"
        else
            Data.settings.current_theme = "DARK_MODERN"
        end
        
        saveJsonFile(PATHS.SETTINGS, Data.settings)
    end)
    
    if not status then
        sampAddChatMessage('[RodinaMarket] {ff0000}Ошибка сохранения настроек: ' .. tostring(err), -1)
    end
end

-- Сохранение всего (используется редко, например при выходе)
function saveConfig()
    saveJsonFile(PATHS.DATA .. 'sell_items.json', Data.sell_list)
    saveJsonFile(PATHS.DATA .. 'buy_items.json', Data.buy_list)
    saveJsonFile(PATHS.DATA .. 'unsellable.json', Data.unsellable_items)
    
    saveJsonFile(PATHS.CACHE .. 'cached_items.json', Data.cached_items)
    saveJsonFile(PATHS.CACHE .. 'scanned_items.json', Data.scanned_items)
    saveJsonFile(PATHS.CACHE .. 'buyable_items.json', Data.buyable_items)
    saveJsonFile(PATHS.CACHE .. 'average_prices.json', Data.average_prices)
    
    -- Сохранение количеств предметов из инвентаря
    saveJsonFile(PATHS.DATA .. 'item_amounts.json', Data.inventory_item_amounts)
    
    saveJsonFile(PATHS.LOGS .. 'transactions.json', Data.transaction_logs)
end

-- Отдельная функция для сохранения только настроек скупки/продажи (для оптимизации)
function saveListsConfig()
    -- Сохраняем активность для всех товаров продажи и очищаем поломанные данные
    local valid_sell_list = {}
    for _, item in ipairs(Data.sell_list) do
        if item and item.name then  -- Проверяем наличие name вместо model_id
            if item.active == nil then item.active = true end
            table.insert(valid_sell_list, item)
        end
    end
    Data.sell_list = valid_sell_list
    
    local valid_buy_list = {}
    for _, item in ipairs(Data.buy_list) do
        if item and item.name then  -- Проверяем наличие name вместо model_id
            if item.active == nil then item.active = true end
            table.insert(valid_buy_list, item)
        end
    end
    Data.buy_list = valid_buy_list
    
    saveJsonFile(PATHS.DATA .. 'sell_items.json', Data.sell_list)
    saveJsonFile(PATHS.DATA .. 'buy_items.json', Data.buy_list)
    
    -- Перестраиваем индексы после сохранения
    rebuildIndexes()
end

-- === СИСТЕМА ПЛАВНОГО СКРОЛЛА (NATIVE FIX) === --
local scroll_state = {}

-- Улучшенная функция интерполяции (экспоненциальное сглаживание)
local function lerp(a, b, t) 
    return a + (b - a) * t 
end

function renderSmoothScrollBox(str_id, size, content_func)
    -- Инициализация состояния
    if not scroll_state[str_id] then
        scroll_state[str_id] = {
            current_y = 0.0,    -- Текущая визуальная позиция
            target_y = 0.0,     -- Куда стремимся
            max_scroll = 0.0,   -- Максимальный скролл (считается автоматически)
            scrollbar_alpha = 0.0,
            last_activity = 0.0
        }
    end
    local state = scroll_state[str_id]
    local dt = imgui.GetIO().DeltaTime
    
    -- Отключаем стандартный скроллбар и скролл мышью (мы обработаем его сами)
    -- WindowFlags.NoScrollWithMouse важен, чтобы не конфликтовать с нашей физикой
    local flags = imgui.WindowFlags.NoScrollbar + imgui.WindowFlags.NoScrollWithMouse
    
    -- Начинаем Child-окно
    -- Размер (0,0) означает авто-заполнение, если size не задан
    local res = imgui.BeginChild(str_id, size, false, flags)
    
    if res then
        local win_h = imgui.GetWindowHeight()
        local win_pos = imgui.GetWindowPos()
        local win_w = imgui.GetWindowWidth()
        
        -- Получаем реальный предел скролла от самого ImGui
        -- Это исправляет баг, когда скролл улетал в пустоту или останавливался на середине
        state.max_scroll = imgui.GetScrollMaxY()
        
        -- 1. ОБРАБОТКА ВВОДА
        if imgui.IsWindowHovered() then
            local wheel = imgui.GetIO().MouseWheel
            if wheel ~= 0 then
                -- Скорость прокрутки (S(50) - оптимально для списков)
                local scroll_step = S(50)
                state.target_y = state.target_y - (wheel * scroll_step)
                state.last_activity = os.clock()
            end
        end
        
        -- 2. ОГРАНИЧЕНИЕ ЦЕЛИ (CLAMP)
        -- Не даем целевой точке улететь за пределы реального контента
        if state.target_y < 0 then state.target_y = 0 end
        if state.target_y > state.max_scroll then state.target_y = state.max_scroll end
        
        -- 3. ФИЗИКА (ПЛАВНОСТЬ)
        -- Используем dt * скорость. 15.0 - это "вязкость". 
        -- Меньше число = медленнее/плавнее. Больше = резче.
        -- Убрали math.floor, чтобы движение было идеально гладким (sub-pixel)
        if math.abs(state.target_y - state.current_y) < 0.1 then
            state.current_y = state.target_y
        else
            state.current_y = lerp(state.current_y, state.target_y, dt * 15.0)
        end
        
        -- 4. ПРИМЕНЕНИЕ СКРОЛЛА
        -- Используем нативную функцию ImGui вместо сдвига курсора!
        imgui.SetScrollY(state.current_y)
        
        -- 5. ОТРИСОВКА КОНТЕНТА
        content_func()
        
        -- 6. ОТРИСОВКА КАСТОМНОГО СКРОЛЛБАРА
        if state.max_scroll > 0 then
            local draw_list = imgui.GetWindowDrawList()
            
            -- Логика исчезновения
            local time_since_active = os.clock() - state.last_activity
            local target_alpha = 0.0
            
            local is_scrolling_fast = math.abs(state.target_y - state.current_y) > 1.0
            
            if imgui.IsWindowHovered() or is_scrolling_fast then
                target_alpha = 1.0
                if is_scrolling_fast then state.last_activity = os.clock() end
            elseif time_since_active < 0.8 then
                target_alpha = 1.0 - (time_since_active / 0.8)
            end
            
            state.scrollbar_alpha = lerp(state.scrollbar_alpha, target_alpha, dt * 8.0)
            
            if state.scrollbar_alpha > 0.01 then
                local bar_w = S(4) -- Толщина полоски
                local scrollbar_padding_right = S(2)
                
                -- Высота ползунка зависит от отношения окна к контенту
                local content_total_h = state.max_scroll + win_h
                local viewport_ratio = win_h / content_total_h
                local grab_h = math.max(S(30), win_h * viewport_ratio)
                
                -- Позиция ползунка
                -- state.current_y / state.max_scroll дает прогресс от 0 до 1
                local scroll_ratio = state.current_y / state.max_scroll
                -- Защита от NaN при делении на 0
                if state.max_scroll <= 0.1 then scroll_ratio = 0 end
                
                local track_space = win_h - grab_h - S(8)
                local grab_y = win_pos.y + S(4) + (scroll_ratio * track_space)
                local grab_x = win_pos.x + win_w - bar_w - scrollbar_padding_right
                
                -- Цвета
                local col = CURRENT_THEME.accent_primary
                local col_u32 = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(col.x, col.y, col.z, state.scrollbar_alpha * 0.9))
                local bg_u32 = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, state.scrollbar_alpha * 0.15))
                
                -- Фон трека (опционально, можно убрать для минимализма)
                draw_list:AddRectFilled(
                    imgui.ImVec2(grab_x, win_pos.y + S(2)),
                    imgui.ImVec2(grab_x + bar_w, win_pos.y + win_h - S(2)),
                    bg_u32, 
                    bar_w / 2
                )
                
                -- Сам ползунок
                draw_list:AddRectFilled(
                    imgui.ImVec2(grab_x, grab_y),
                    imgui.ImVec2(grab_x + bar_w, grab_y + grab_h),
                    col_u32, 
                    bar_w / 2
                )
            end
        end
    end
    imgui.EndChild()
end

-- === КЭШИРОВАНИЕ ЦВЕТОВ === --
-- Кэш для Color Convert операций (часто используемые цвета)
local color_cache = {}

function getCachedColor(r, g, b, a)
    local key = string.format("%.2f_%.2f_%.2f_%.2f", r, g, b, a)
    if not color_cache[key] then
        color_cache[key] = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, a))
    end
    return color_cache[key]
end

-- Предкэшированные стандартные цвета для быстрого доступа
local COLORS = {
    TEXT_WHITE = getCachedColor(1, 1, 1, 1),
    TEXT_GREY = getCachedColor(0.5, 0.5, 0.5, 1),
    TEXT_GREY_DIM = getCachedColor(0.5, 0.5, 0.5, 0.7),
    ACCENT_PURPLE = getCachedColor(0.4, 0.25, 0.95, 1),
    ACCENT_GREEN = getCachedColor(0.4, 1, 0.6, 1),
    ACCENT_BLUE = getCachedColor(0.4, 0.8, 1, 1),
    ACCENT_RED = getCachedColor(1, 0.3, 0.3, 0.8),
    BG_DARK = getCachedColor(0.08, 0.08, 0.08, 0.5),
    BG_DARKER = getCachedColor(0.08, 0.08, 0.08, 0.7),
    BG_ALT1 = getCachedColor(0.10, 0.11, 0.14, 0.8),
    BG_ALT2 = getCachedColor(0.12, 0.13, 0.16, 0.8)
}

function url_encode(str)
    if str then
        str = str:gsub("\n", "\r\n")
        str = str:gsub("([^%w %-%_%.%~])",
            function (c) return string.format ("%%%02X", string.byte(c)) end)
        str = str:gsub(" ", "+")
    end
    return str
end

-- === АНИМАЦИЯ ЗНАЧЕНИЙ === --
-- Для плавного отображения изменения чисел
local animated_values = {}

function getAnimatedValue(key, target_value, speed)
    speed = speed or 0.1 -- 0.1 = медленная анимация, 1.0 = мгновенная
    
    if not animated_values[key] then
        animated_values[key] = { current = target_value, target = target_value }
    end
    
    local anim = animated_values[key]
    anim.target = target_value
    anim.current = lerp(anim.current, anim.target, speed)
    
    return math.floor(anim.current)
end

function App.tasks.add(name, code, wait_time)
    -- Если задача с таким именем уже есть, удаляем старую перед добавлением новой
    App.tasks.remove_by_name(name)
    local task = {
        name = name, 
        code = code, 
        start_time = os.clock() * 1000, 
        wait_time = wait_time,
        dead = false -- Флаг для безопасного удаления
    }
    table.insert(App.tasks_list, task)
end

function App.tasks.process()
    local current_time = os.clock() * 1000
    local i = 1
    
    while i <= #App.tasks_list do
        local task = App.tasks_list[i]
        
        -- Если задача помечена как мертвая, удаляем её и не сдвигаем индекс
        if task.dead then
            table.remove(App.tasks_list, i)
        
        -- Если время пришло
        elseif (current_time - task.start_time >= task.wait_time) then
            -- Сначала помечаем как мертвую, чтобы она не выполнилась дважды
            task.dead = true 
            
            -- Безопасный вызов функции
            local status, err = pcall(task.code)
            
            if not status then
                print('[RodinaMarket] Ошибка выполнения задачи "' .. tostring(task.name) .. '": ' .. tostring(err))
            end
            
            -- Удаляем задачу из списка
            table.remove(App.tasks_list, i)
            -- НЕ увеличиваем i, так как следующий элемент сместился на текущее место
        else
            -- Переходим к следующей задаче
            i = i + 1
        end
    end
end

function App.tasks.remove_by_name(name)
    for i, v in ipairs(App.tasks_list) do
        if v.name == name then 
            v.dead = true -- Просто помечаем как мертвую, удалится в process()
            return 
        end
    end
end

function updateAveragePrice(item_name, new_price)
    new_price = tonumber(new_price)
    
    -- Игнорируем цены <= 0
    if not new_price or new_price <= 0 then return end
    
    local clean_name = cleanItemName(item_name)
    if clean_name == "" then return end
    
    -- Пытаемся найти существующий ключ для обновления
    for existing_name, _ in pairs(Data.average_prices) do
        if cleanItemName(existing_name) == clean_name then
            clean_name = existing_name 
            break
        end
    end
    
    -- Перезаписываем цену. 
    -- count = 1, так как сервер уже выдает среднее, нам не нужно усреднять его еще раз
    Data.average_prices[clean_name] = { price = new_price, count = 1 }
end

function events.onServerMessage(color, text)
    if not text:find("[Лавка]") then return true end
    local transaction = parseShopMessage(text)
    if transaction then
        addTransactionLog(transaction)
        
        -- Используем красивые Toast-уведомления вместо chat message
        if transaction.type == "sale" then
            addToastNotification(
                string.format("Продано: %s (%dх) за %s руб.", transaction.item, transaction.amount, formatMoney(transaction.total)),
                "success",
                4.0
            )
        else
            addToastNotification(
                string.format("Куплено: %s (%dх) за %s руб.", transaction.item, transaction.amount, formatMoney(transaction.total)),
                "info",
                4.0
            )
        end
    end
    return true
end

-- Кэш для часто используемых строк в нижнем регистре
local lower_cache = setmetatable({}, {__mode = 'v'})

function to_lower(str)
    if not str or str == "" then return "" end
    
    -- Проверяем кэш
    if lower_cache[str] then
        return lower_cache[str]
    end
    
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
    
    local result = table.concat(res)
    lower_cache[str] = result
    return result
end

function isAccessory(name)
    local clean = to_lower(name)
    -- Проверяем ключевое слово "аксессуар" или специфичные предметы, если нужно
    return clean:find("аксессуар") ~= nil
end

-- Текст подсказки для цветов
local color_tooltip_text = [[
ID Цветов:
0 - Нет
1 - Красный
2 - Темно-Оранжевый
3 - Оранжевый
4 - Желтый
5 - Зеленый
6 - Голубой
7 - Синий
8 - Розовый
9 - Малиновый
]]

local search_anim_state = { 
    active_t = 0.0, 
    hover_t = 0.0,
    -- Добавим плавность для иконки очистки
    clear_btn_alpha = 0.0
}

function renderAnimatedSearchBar(buffer, hint, width)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    -- Размеры
    local height = S(40) 
    local rounding = height / 2 -- Идеальный круг по бокам (Pill shape)
    
    -- Цвета из текущей темы с улучшенной визуализацией
    local col_bg_normal = CURRENT_THEME.bg_tertiary
    local col_bg_active = CURRENT_THEME.bg_secondary
    local col_accent = CURRENT_THEME.accent_primary
    local col_text_hint = CURRENT_THEME.text_hint
    
    -- Логика наведения и анимации
    local is_hovered_rect = imgui.IsMouseHoveringRect(p, imgui.ImVec2(p.x + width, p.y + height))
    local dt = imgui.GetIO().DeltaTime * 10.0
    
    search_anim_state.hover_t = lerp(search_anim_state.hover_t, is_hovered_rect and 1.0 or 0.0, dt)
    
    -- 1. ОТРИСОВКА ФОНА (DrawList)
    -- Считаем цвет фона с учетом анимации фокуса и наведения
    local bg_r = lerp(col_bg_normal.x, col_bg_active.x, math.max(search_anim_state.active_t, search_anim_state.hover_t * 0.3))
    local bg_g = lerp(col_bg_normal.y, col_bg_active.y, math.max(search_anim_state.active_t, search_anim_state.hover_t * 0.3))
    local bg_b = lerp(col_bg_normal.z, col_bg_active.z, math.max(search_anim_state.active_t, search_anim_state.hover_t * 0.3))
    local bg_b = lerp(col_bg_normal.z, col_bg_active.z, search_anim_state.active_t)
    local bg_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(bg_r, bg_g, bg_b, 1.0))
    
    -- Рисуем основное тело
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), bg_col, rounding)
    
    -- Рисуем тонкую обводку в состоянии покоя (чтобы границы были видны)
    local border_idle_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.1 + (search_anim_state.hover_t * 0.1)))
    draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), border_idle_col, rounding, 15, S(1.0))

    -- 2. ЭФФЕКТ СВЕЧЕНИЯ (GLOW) при активности
    if search_anim_state.active_t > 0.01 then
        -- Цвет свечения (акцентный с прозрачностью)
        local glow_alpha = search_anim_state.active_t * 0.5
        local glow_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(col_accent.x, col_accent.y, col_accent.z, glow_alpha))
        
        -- ВАЖНО: Рисуем прямоугольник чуть больше (+1 пиксель), но с ТЕМ ЖЕ радиусом скругления (rounding)
        -- Flags 15 = скруглить все углы
        draw_list:AddRect(
            imgui.ImVec2(p.x - S(1), p.y - S(1)), 
            imgui.ImVec2(p.x + width + S(1), p.y + height + S(1)), 
            glow_col, 
            rounding, 
            15, 
            S(2.0) -- Толщина обводки
        )
    end

    -- 3. ИКОНКА ЛУПЫ
    local icon_offset_x = S(15)
    imgui.PushFont(font_fa)
    local icon_search = fa('magnifying_glass')
    local icon_size = imgui.CalcTextSize(icon_search)
    
    -- Цвет иконки: серый -> акцентный
    local icon_r = lerp(col_text_hint.x, col_accent.x, search_anim_state.active_t)
    local icon_g = lerp(col_text_hint.y, col_accent.y, search_anim_state.active_t)
    local icon_b = lerp(col_text_hint.z, col_accent.z, search_anim_state.active_t)
    local icon_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(icon_r, icon_g, icon_b, 1.0))
    
    draw_list:AddText(imgui.ImVec2(p.x + icon_offset_x, p.y + (height - icon_size.y)/2), icon_col, icon_search)
    imgui.PopFont()

    -- 4. САМО ПОЛЕ ВВОДА (InputText)
    -- Делаем его полностью прозрачным и накладываем поверх нашего рисунка
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.FrameBgActive, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.TextSelectedBg, imgui.ImVec4(col_accent.x, col_accent.y, col_accent.z, 0.4))
    
    -- Отступ текста слева (чтобы не наезжал на лупу) и справа (для крестика)
    local text_pad_left = icon_offset_x + icon_size.x + S(10)
    local text_pad_right = S(30)
    
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y))
    -- Используем PushStyleVar для внутренних отступов InputText
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(text_pad_left, (height - imgui.GetFontSize()) / 2))
    
    imgui.SetNextItemWidth(width - text_pad_right) 
    
    local changed = imgui.InputTextWithHint("##anim_search_bar", u8(hint), buffer, 128)
    local is_active = imgui.IsItemActive()
    
    imgui.PopStyleVar()
    imgui.PopStyleColor(5)

    -- Обновляем анимацию активности
    search_anim_state.active_t = lerp(search_anim_state.active_t, is_active and 1.0 or 0.0, dt)

    -- 5. КНОПКА ОЧИСТКИ (КРЕСТИК)
    local has_text = ffi.string(buffer) ~= ""
    search_anim_state.clear_btn_alpha = lerp(search_anim_state.clear_btn_alpha, has_text and 1.0 or 0.0, dt)

    if search_anim_state.clear_btn_alpha > 0.01 then
        imgui.PushFont(font_fa)
        local icon_clear = fa('circle_xmark') -- Более "плотная" иконка
        local clear_size = imgui.CalcTextSize(icon_clear)
        
        local btn_w = S(30)
        local btn_pos_x = p.x + width - btn_w
        local btn_pos_y = p.y
        
        -- Рисуем крестик
        local clear_col_val = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(CURRENT_THEME.text_hint.x, CURRENT_THEME.text_hint.y, CURRENT_THEME.text_hint.z, search_anim_state.clear_btn_alpha))
        
        -- Проверка ховера на крестик
        local is_mouse_on_clear = imgui.IsMouseHoveringRect(imgui.ImVec2(btn_pos_x, btn_pos_y), imgui.ImVec2(btn_pos_x + btn_w, btn_pos_y + height))
        
        if is_mouse_on_clear then
            clear_col_val = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(CURRENT_THEME.accent_danger.x, CURRENT_THEME.accent_danger.y, CURRENT_THEME.accent_danger.z, search_anim_state.clear_btn_alpha))
            if imgui.IsMouseClicked(0) then
                buffer[0] = 0 -- Очистка буфера
                changed = true
            end
        end
        
        draw_list:AddText(imgui.ImVec2(btn_pos_x + (btn_w - clear_size.x)/2, btn_pos_y + (height - clear_size.y)/2), clear_col_val, icon_clear)
        imgui.PopFont()
    end
    
    return changed
end

function filterList(list, buffer_char)
    if not list or #list == 0 then 
        return {} 
    end
    
    local query_utf8 = ffi.string(buffer_char)
    
    -- Пустой поиск - возвращаем весь список
    if query_utf8 == "" then 
        return list 
    end
    
    local query = u8:decode(query_utf8)
    query = to_lower(query)
    
    if not query or query == "" then 
        return list 
    end
    
    local result = {}
    local query_len = #query
    
    for i, item in ipairs(list) do
        if item and item.name then
            local item_name = to_lower(item.name)
            -- Быстрая проверка длины перед поиском
            if #item_name >= query_len and item_name:find(query, 1, true) then
                table.insert(result, item)
            end
        end
    end
    
    return result
end

-- Функция для отрисовки красивой карточки статистики
-- === УТИЛИТЫ ТАБЛИЦ ДЛЯ ОПТИМИЗАЦИИ === --
local function tableContains(tbl, field_name, value)
    for _, item in ipairs(tbl) do
        if item[field_name] == value then
            return true
        end
    end
    return false
end

local function tableFind(tbl, field_name, value)
    for idx, item in ipairs(tbl) do
        if item[field_name] == value then
            return idx, item
        end
    end
    return nil
end

function drawStatCard(label, value, color_bg, width, height)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    -- 1. Резервируем место
    imgui.Dummy(imgui.ImVec2(width, height))
    
    -- 2. Рисуем тень под карточкой
    draw_list:AddRectFilled(
        imgui.ImVec2(p.x + S(2), p.y + S(2)), 
        imgui.ImVec2(p.x + width + S(2), p.y + height + S(2)), 
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0.2)), 
        S(10)
    )
    
    -- 3. Рисуем саму карточку с бордером
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), imgui.ColorConvertFloat4ToU32(color_bg), S(10))
    
    -- 4. Добавляем легкий бордер для выделения
    draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.15)), S(10), nil, S(1.5))
    
    -- 5. Текст заголовка
    local title_pos = imgui.ImVec2(p.x + S(15), p.y + S(10))
    draw_list:AddText(title_pos, imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.7)), u8(label))
    
    -- 6. Значение (деньги) - более крупно
    local money_str = formatMoney(value)
    local value_pos = imgui.ImVec2(p.x + S(15), p.y + S(32))
    draw_list:AddText(value_pos, imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary), money_str)
end

-- === ФУНКЦИИ ПАГИНАЦИИ ДЛЯ БОЛЬШИХ СПИСКОВ === --
local function getPaginatedList(list, page, items_per_page)
    if not list or #list == 0 then return {}, 0 end
    
    local total_pages = math.ceil(#list / items_per_page)
    page = math.max(1, math.min(page, total_pages))
    
    local start_idx = (page - 1) * items_per_page + 1
    local end_idx = math.min(page * items_per_page, #list)
    
    local paginated = {}
    for i = start_idx, end_idx do
        table.insert(paginated, list[i])
    end
    
    return paginated, total_pages
end

local function renderPaginationButtons(page, total_pages, on_page_change)
    if total_pages <= 1 then return end
    
    imgui.Separator()
    imgui.Spacing()
    
    local button_width = (imgui.GetContentRegionAvail().x - S(10)) / 3
    
    -- Кнопка "Предыдущая"
    if page > 1 then
        if imgui.Button(fa('arrow_left') .. u8" Предыдущая", imgui.ImVec2(button_width, S(30))) then
            on_page_change(page - 1)
        end
    else
        imgui.Button(fa('arrow_left') .. u8" Предыдущая", imgui.ImVec2(button_width, S(30)))
    end
    imgui.BeginDisabled(true)
    imgui.SameLine()
    
    -- Текст страницы
    imgui.Button(u8(string.format("Страница %d / %d", page, total_pages)), imgui.ImVec2(button_width, S(30)))
    
    imgui.SameLine()
    imgui.EndDisabled()
    
    -- Кнопка "Следующая"
    if page < total_pages then
        if imgui.Button(u8"Следующая " .. fa('arrow_right'), imgui.ImVec2(button_width, S(30))) then
            on_page_change(page + 1)
        end
    else
        imgui.Button(u8"Следующая " .. fa('arrow_right'), imgui.ImVec2(button_width, S(30)))
    end
end

function refreshLogDates()
    local files = {}
    local path = PATHS.LOGS
    
    if not doesDirectoryExist(path) then createDirectory(path) end
    
    for file in lfs.dir(path) do
        if file:match("^%d%d%d%d%-%d%d%-%d%d%.json$") then
            -- Убираем .json расширение для отображения
            local date_str = file:sub(1, -6)
            table.insert(files, date_str)
        end
    end
    
    -- Сортируем от новых к старым
    table.sort(files, function(a, b) return a > b end)
    
    Data.available_log_dates = files
    Buffers.logs_dates_cache = files
end

-- Загрузка логов за конкретную дату
function loadLogsForDate(date_str)
    local path = PATHS.LOGS .. date_str .. ".json"
    return loadJsonFile(path, {})
end

-- Обновление отображаемых логов (вызывается при смене даты или фильтра)
function updateLogView()
    local selected_idx = Buffers.logs_current_date_idx
    local raw_logs = {}
    
    -- Теперь логика простая: берем дату напрямую из кэша по индексу
    if Buffers.logs_dates_cache and Buffers.logs_dates_cache[selected_idx] then
        local date_str = Buffers.logs_dates_cache[selected_idx]
        raw_logs = loadLogsForDate(date_str)
    else
        -- Если ничего не выбрано (например, при первом запуске), грузим текущий день
        local today = os.date("%Y-%m-%d")
        raw_logs = loadLogsForDate(today)
    end
    
    local filtered = {}
    local show_sales = Buffers.log_filters.show_sales[0]
    local show_purchases = Buffers.log_filters.show_purchases[0]
    
    -- Сортировка: новые записи вверху
    table.sort(raw_logs, function(a, b) return (a.timestamp or 0) > (b.timestamp or 0) end)
    
    local income = 0
    local expense = 0
    
    for _, log in ipairs(raw_logs) do
        local pass = true
        if log.type == "sale" and not show_sales then pass = false end
        if log.type == "purchase" and not show_purchases then pass = false end
        
        if pass then
            table.insert(filtered, log)
            if log.type == "sale" then income = income + log.total
            else expense = expense + log.total end
        end
    end
    
    Data.current_view_logs = filtered
    return income, expense
end

local cached_income = 0
local cached_expense = 0
local last_log_search = ""
local last_log_idx = -1
local last_check_boxes = "11"

-- == НОВАЯ ФУНКЦИЯ ДЛЯ ЗАПРОСОВ == --

-- === КРАСИВЫЕ КОМПОНЕНТЫ ДЛЯ AAA UI === --

-- Функция для отображения красивого блока информации
function renderAAAPriceCard(price, label, icon, color, width)
    width = width or imgui.GetContentRegionAvail().x
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    local height = S(80)
    local padding = S(15)
    local border_radius = S(10)
    
    -- Фон
    local bg_color = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_tertiary)
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), bg_color, border_radius)
    
    -- Граница с акцентом
    local border_color = imgui.ColorConvertFloat4ToU32(color)
    draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), border_color, border_radius, imgui.DrawCornerFlags.All, S(2))
    
    -- Иконка
    if icon and font_fa then
        imgui.PushFont(font_fa)
        local icon_color = imgui.ColorConvertFloat4ToU32(color)
        draw_list:AddText(imgui.ImVec2(p.x + padding, p.y + padding + S(5)), icon_color, icon)
        imgui.PopFont()
    end
    
    -- Текст цены
    local price_text = formatMoney(price)
    local price_size = imgui.CalcTextSize(price_text)
    local price_color = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary)
    draw_list:AddText(imgui.ImVec2(p.x + width - price_size.x - padding, p.y + S(20)), price_color, price_text)
    
    -- Текст лейбла
    local label_color = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_secondary)
    draw_list:AddText(imgui.ImVec2(p.x + padding + S(35), p.y + padding), label_color, u8(label))
    
    imgui.Dummy(imgui.ImVec2(width, height))
end

-- Функция для отображения статуса товара
function renderAAAPriceStatus(price, avg_price, label)
    if not avg_price or avg_price <= 0 then
        imgui.TextDisabled(u8(label .. ": нет данных"))
        return
    end
    
    local diff = price - avg_price
    local diff_percent = ((diff / avg_price) * 100)
    
    imgui.BeginGroup()
    
    imgui.TextColored(CURRENT_THEME.text_secondary, u8(label))
    imgui.SameLine()
    
    local status_color = CURRENT_THEME.text_hint
    local status_icon = ""
    
    if diff > 0 then
        status_color = CURRENT_THEME.accent_success
        status_icon = fa('arrow_up')
    elseif diff < 0 then
        status_color = CURRENT_THEME.accent_danger
        status_icon = fa('arrow_down')
    else
        status_color = CURRENT_THEME.text_secondary
        status_icon = fa('minus')
    end
    
    local status_text = string.format("%s %.1f%% (%s)", status_icon, math.abs(diff_percent), formatMoney(avg_price))
    imgui.TextColored(status_color, u8(status_text))
    
    imgui.EndGroup()
end

-- Красивое отображение количества товара
function renderAAAmountSelector(item_index, current_amount, on_change)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    local width = S(120)
    local height = S(36)
    local border_radius = S(8)
    
    -- Фон
    local bg_color = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary)
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), bg_color, border_radius)
    
    -- Граница
    local border_color = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.border_light)
    draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), border_color, border_radius, imgui.DrawCornerFlags.All, S(1))
    
    -- Кнопка минус
    if imgui.InvisibleButton("##minus_" .. item_index, imgui.ImVec2(S(36), height)) then
        if on_change then on_change(math.max(1, current_amount - 1)) end
    end
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x + S(8), p.y + S(8)))
    local minus_color = imgui.IsItemHovered() and 0xFFFFFFFF or 0xB0FFFFFF
    draw_list:AddText(imgui.ImVec2(p.x + S(12), p.y + S(8)), minus_color, fa('minus'))
    
    -- Текст количества
    local amount_text = tostring(current_amount)
    local text_size = imgui.CalcTextSize(amount_text)
    local text_color = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary)
    draw_list:AddText(imgui.ImVec2(p.x + (width - text_size.x) / 2, p.y + (height - text_size.y) / 2), text_color, amount_text)
    
    -- Кнопка плюс
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x + width - S(36), p.y))
    if imgui.InvisibleButton("##plus_" .. item_index, imgui.ImVec2(S(36), height)) then
        if on_change then on_change(current_amount + 1) end
    end
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x + width - S(28), p.y + S(8)))
    local plus_color = imgui.IsItemHovered() and 0xFFFFFFFF or 0xB0FFFFFF
    draw_list:AddText(imgui.ImVec2(p.x + width - S(24), p.y + S(8)), plus_color, fa('plus'))
    
    imgui.Dummy(imgui.ImVec2(width, height))
end

-- Красивая кнопка действия с иконкой
function renderActionButton(icon, label, width, on_click, tooltip, is_disabled)
    is_disabled = is_disabled or false
    width = width or -1
    
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    local avail_w = imgui.GetContentRegionAvail().x
    if width == -1 then width = avail_w end
    
    local height = S(45)
    local border_radius = S(8)
    
    -- Фон кнопки (светлее при наведении)
    if imgui.InvisibleButton("##action_btn", imgui.ImVec2(width, height)) then
        if not is_disabled and on_click then on_click() end
    end
    
    local is_hovered = imgui.IsItemHovered() and not is_disabled
    local is_pressed = imgui.IsItemActive()
    
    -- Цвет фона
    local bg_color = is_disabled and CURRENT_THEME.bg_secondary 
                    or (is_pressed and lerpColor(CURRENT_THEME.accent_primary, CURRENT_THEME.bg_secondary, 0.5))
                    or (is_hovered and lerpColor(CURRENT_THEME.accent_primary, CURRENT_THEME.bg_secondary, 0.3))
                    or CURRENT_THEME.bg_tertiary
    
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), imgui.ColorConvertFloat4ToU32(bg_color), border_radius)
    
    -- Граница
    local border_color = is_disabled and CURRENT_THEME.border_light or CURRENT_THEME.accent_primary
    draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), imgui.ColorConvertFloat4ToU32(border_color), border_radius, imgui.DrawCornerFlags.All, S(2))
    
    -- Иконка
    if icon and font_fa then
        imgui.PushFont(font_fa)
        local icon_color = is_disabled and CURRENT_THEME.text_hint or CURRENT_THEME.accent_primary
        draw_list:AddText(imgui.ImVec2(p.x + S(12), p.y + (height - S(16)) / 2), 
                         imgui.ColorConvertFloat4ToU32(icon_color), icon)
        imgui.PopFont()
    end
    
    -- Текст
    local text_color = is_disabled and CURRENT_THEME.text_hint or CURRENT_THEME.text_primary
    local text_size = imgui.CalcTextSize(u8(label))
    draw_list:AddText(imgui.ImVec2(p.x + S(40), p.y + (height - text_size.y) / 2), 
                     imgui.ColorConvertFloat4ToU32(text_color), u8(label))
    
    if is_hovered and tooltip then 
        imgui.SetTooltip(u8(tooltip)) 
    end
    
    imgui.Dummy(imgui.ImVec2(width, height))
end

-- Красивое разделение списков с иконкой и подсчетом
function renderListHeader(icon, title, count)
    imgui.Spacing()
    
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    local avail_w = imgui.GetContentRegionAvail().x
    
    -- Фон
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + avail_w, p.y + S(40)), 
                           imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary), S(8))
    
    -- Граница слева
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + S(4), p.y + S(40)), 
                           imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary), 0)
    
    -- Иконка
    if icon and font_fa then
        imgui.PushFont(font_fa)
        draw_list:AddText(imgui.ImVec2(p.x + S(12), p.y + S(10)), 
                         imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary), icon)
        imgui.PopFont()
    end
    
    -- Заголовок
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x + S(42), p.y + S(8)))
    imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_primary)
    imgui.Text(u8(title))
    imgui.PopStyleColor()
    
    -- Счетчик справа
    if count then
        local count_text = "(" .. tostring(count) .. ")"
        local count_size = imgui.CalcTextSize(count_text)
        draw_list:AddText(imgui.ImVec2(p.x + avail_w - count_size.x - S(12), p.y + S(10)), 
                         imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_secondary), count_text)
    end
    
    imgui.Dummy(imgui.ImVec2(avail_w, S(40)))
end

function asyncHttpRequest(method, url, args, resolve, reject)
    if not resolve then resolve = function() end end
    if not reject then reject = function() end end

    -- Захватываем пути к библиотекам из основного потока
    local p_path, p_cpath = package.path, package.cpath

    local request_thread = effil.thread(function (method, url, args, lib_path, lib_cpath)
        -- Восстанавливаем пути, чтобы require 'requests' сработал
        package.path = lib_path
        package.cpath = lib_cpath
        
        local requests = require 'requests'
        local result, response = pcall(requests.request, method, url, args)
        if result then
            -- Удаляем userdata/функции из ответа, так как effil не может их передать
            response.json, response.xml = nil, nil
            return true, response
        else
            return false, response
        end
    end)(method, url, args, p_path, p_cpath)

    -- Создаем микро-поток в Lua для проверки статуса
    lua_thread.create(function()
        local runner = request_thread
        while true do
            local status, err = runner:status()
            if not err then
                if status == 'completed' then
                    local result, response = runner:get()
                    if result then
                        resolve(response)
                    else
                        reject(response)
                    end
                    return
                elseif status == 'canceled' then
                    return reject("Canceled")
                elseif status == 'failed' then
                    local err_msg = runner:get()
                    return reject(err_msg)
                end
            else
                return reject(err)
            end
            wait(100) -- Проверяем каждые 100мс
        end
    end)
end

function api_SendHeartbeat()
    local server_ip, server_port = sampGetCurrentServerAddress()
    local my_nick = sampGetPlayerNickname(select(2, sampGetPlayerIdByCharHandle(PLAYER_PED)))
    
    if not my_nick or not server_ip then return end
    
    local unique_id = my_nick .. "@" .. server_ip .. ":" .. server_port
    
    local payload = { uid = unique_id }
    
    asyncHttpRequest('POST', MarketConfig.URL .. '/api/ping', 
        {
            data = json.encode(payload),
            headers = {['Content-Type'] = 'application/json'},
            timeout = 5
        },
        function(response)
            if response.status_code == 200 then
                local decode_ok, json_data = pcall(json.decode, response.text)
                if decode_ok and json_data.online_count then
                    MarketData.online_count = json_data.online_count
                end
            end
        end
    )
end

function api_DeleteMyShop()
    if not sampIsLocalPlayerSpawned() then return end

    local result, my_id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if not result then return end 
    
    local my_nick = sampGetPlayerNickname(my_id)
    if not my_nick or #my_nick == 0 then return end

    local server_ip, server_port = sampGetCurrentServerAddress()
    local server_id = server_ip .. ":" .. server_port

    local payload = {
        serverId = server_id,
        nickname = my_nick
    }

    asyncHttpRequest('POST', MarketConfig.URL .. '/market/remove', 
        {
            data = json.encode(payload),
            headers = {['Content-Type'] = 'application/json'},
            timeout = 10
        },
        function(response)
            if response.status_code == 200 then
                print("[RMarket] Лавка успешно удалена с сервера.")
                -- УБРАНО: sampAddChatMessage с уведомлением в чат
            else
                print("[RMarket] Ошибка удаления: " .. tostring(response.status_code))
            end
        end,
        function(err)
            print("[RMarket] Ошибка запроса удаления: " .. tostring(err))
        end
    )
end

function updateLiveShopState(mode)
    if mode == 'sell' then
        Data.live_shop.sell = {}
        for _, item in ipairs(Data.sell_list) do
            -- Переносим только активные товары, которые мы планировали продать
            if item.active ~= false then
                table.insert(Data.live_shop.sell, {
                    name = u8(item.name),
                    price = item.price, 
                    amount = item.amount, 
                    model_id = item.model_id
                })
            end
        end
    elseif mode == 'buy' then
        Data.live_shop.buy = {}
        for _, item in ipairs(Data.buy_list) do
            -- Переносим только активные товары, которые мы планировали купить
            if item.active ~= false then
                table.insert(Data.live_shop.buy, {
                    name = u8(item.name),
                    price = item.price, 
                    amount = item.amount, 
                    index = item.index
                })
            end
        end
    end
end

function api_SendMyData()
    if not sampIsLocalPlayerSpawned() then return end

    local result, my_id = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if not result then return end 
    
    local my_nick = sampGetPlayerNickname(my_id)
    if not my_nick or #my_nick == 0 then return end

    -- Проверяем, есть ли вообще что-то в "Живой лавке"
    if #Data.live_shop.sell == 0 and #Data.live_shop.buy == 0 then
        api_DeleteMyShop()
        return
    end

    local server_ip, server_port = sampGetCurrentServerAddress()
    local server_id = server_ip .. ":" .. server_port

    local payload = {
        nickname = my_nick,
        playerId = my_id,
        serverId = server_id,
        shop_name = ffi.string(Buffers.settings.shop_name),
        sell_list = Data.live_shop.sell,
        buy_list = Data.live_shop.buy
    }

    asyncHttpRequest('POST', MarketConfig.URL .. '/api/update', 
        {
            data = json.encode(payload),
            headers = {['Content-Type'] = 'application/json'},
            timeout = 10
        },
        function(response) 
            if response.status_code == 200 then
                print(string.format("[RMarket] Лавка обновлена. ID: %d, Актив: Sell[%d] Buy[%d]", my_id, #Data.live_shop.sell, #Data.live_shop.buy))
                -- УБРАНО: sampAddChatMessage с уведомлением в чат
            else
                print("[RMarket] Ошибка обновления: " .. tostring(response.status_code))
            end
        end,
        function(err) 
            print("[RMarket] Ошибка отправки данных: " .. tostring(err)) 
        end
    )
end

function api_FetchMarketList()
    MarketData.is_loading = true
    
    asyncHttpRequest('GET', MarketConfig.URL .. '/api/list', 
        {timeout = 10},
        function(response)
            if response.status_code == 200 then
                local decode_ok, json_data = pcall(json.decode, response.text)
                if decode_ok then 
                    -- [FIX] Сервер теперь возвращает объект, а не массив
                    if json_data.shops then
                        MarketData.shops_list = recursiveToCP1251(json_data.shops)
                        -- Обновляем онлайн из глобального счетчика, если есть
                        if json_data.online_global then
                            MarketData.online_count = json_data.online_global
                        else
                            MarketData.online_count = #MarketData.shops_list
                        end
                    -- Поддержка старого формата (если сервер старый)
                    elseif #json_data > 0 or type(json_data) == 'table' then
                        MarketData.shops_list = recursiveToCP1251(json_data)
                        MarketData.online_count = #MarketData.shops_list
                    end
                else
                    print("[RMarket] Ошибка JSON при получении списка")
                end
            else
                print("[RMarket] Ошибка HTTP списка: " .. tostring(response.status_code))
            end
            MarketData.is_loading = false
        end,
        function(err)
            print("[RMarket] Не удалось загрузить список: " .. tostring(err))
            MarketData.is_loading = false
        end
    )
end

function api_FetchShopDetails(server_id, nickname)
    MarketData.selected_shop = nil 
    
    local safe_sid = url_encode(server_id)
    -- Если ник в CP1251, для URL может потребоваться конвертация, но обычно ники английские
    local safe_nick = url_encode(nickname) 
    local full_url = MarketConfig.URL .. '/api/shop/' .. safe_sid .. '/' .. safe_nick

    asyncHttpRequest('GET', full_url, 
        {timeout = 10},
        function(response)
            if response.status_code == 200 then
                local decode_ok, json_data = pcall(json.decode, response.text)
                if decode_ok then 
                    -- [FIX] Переводим детали лавки (списки товаров) в CP1251
                    MarketData.selected_shop = recursiveToCP1251(json_data)
                else
                    print("[RMarket] Ошибка JSON деталей лавки")
                end
            else
                print("[RMarket] Лавка не найдена или офлайн (Code: " .. tostring(response.status_code) .. ")")
            end
        end,
        function(err)
            print("[RMarket] Ошибка загрузки деталей: " .. tostring(err))
        end
    )
end

function renderMarketItemRow(index, item, width, is_sell)
    if not item then return end
    
    local height = S(50)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    -- Используем индекс для ID, это намного безопаснее и быстрее, чем строки
    imgui.PushIDInt(index)
    imgui.PushIDInt(is_sell and 1 or 0)
    
    -- 1. Фон карточки
    local bg_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.12, 0.13, 0.16, 1.0))
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), bg_col, S(6))
    
    -- 2. Цветной бар слева
    local bar_color = is_sell and 0xFF66CC66 or 0xFF6666FF
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + S(4), p.y + height), bar_color, S(6), 5)

    -- 3. Название товара (с проверкой на nil)
    local text_pos_x = p.x + S(15)
    local text_pos_y = p.y + S(8)
    
    local safe_name = tostring(item.name or "Неизвестный товар")
    draw_list:AddText(imgui.ImVec2(text_pos_x, text_pos_y), 0xFFFFFFFF, u8(safe_name))
    
    -- 4. Цена (Справа)
    local safe_price = item.price or 0
    local price_str = formatMoney(safe_price) .. " $"
    local price_size = imgui.CalcTextSize(price_str)
    local price_x = p.x + width - price_size.x - S(10)
    
    local price_col = is_sell and 0xFF66CC66 or 0xFF6666FF
    draw_list:AddText(imgui.ImVec2(price_x, text_pos_y), price_col, price_str)
    
    -- 5. Количество
    local amount_y = p.y + S(26)
    local safe_amount = item.amount or 0
    local amount_str = u8("Количество: " .. safe_amount .. " шт.")
    draw_list:AddText(imgui.ImVec2(text_pos_x, amount_y), 0xFF999999, amount_str)

    -- Отступ - устанавливаем курсор в конец этого элемента
    imgui.Dummy(imgui.ImVec2(width, height))
    
    -- Невидимая кнопка для обработки клика (добавляем ПОСЛЕ Dummy)
    local btn_p = imgui.ImVec2(p.x - imgui.GetScrollX(), p.y - imgui.GetScrollY())
    imgui.SetCursorScreenPos(btn_p)
    if imgui.InvisibleButton("##itemrow_" .. tostring(index) .. "_" .. (is_sell and "sell" or "buy"), imgui.ImVec2(width, height)) then
        if not is_sell then
            -- Клик на товар в скупке - добавляем в "Моя скупка"
            sampAddChatMessage('[RodinaMarket] {ffff00}[DEBUG] Добавляю товар: ' .. (item.name or "Unknown"), -1)
            
            -- Проверяем, есть ли уже такой товар в списке
            local found = false
            for _, existing_item in ipairs(Data.buy_list) do
                if existing_item.name == item.name then
                    existing_item.amount = (existing_item.amount or 1) + 1
                    found = true
                    break
                end
            end
            
            if not found then
                -- Добавляем товар с необходимыми полями
                table.insert(Data.buy_list, {
                    name = item.name,
                    price = item.price or 100,
                    amount = 1,
                    active = true,
                    model_id = -1,
                    index = item.index or -1
                })
            end
            
            -- Сохраняем используя функцию saveListsConfig
            saveListsConfig()
            calculateBuyTotal()
            sampAddChatMessage('[RodinaMarket] {00ff00}Товар добавлен в Мою скупку!', -1)
        end
    end
    
    imgui.PopID()
    imgui.PopID()
end

function renderShopCardGrid(shop, width, height)
    if not shop then return end
    -- ИСПРАВЛЕНИЕ: Используем PushIDStr вместо PushID
    imgui.PushIDStr(tostring(shop.serverId) .. tostring(shop.nickname))
    
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    imgui.SetCursorScreenPos(p)
    if imgui.InvisibleButton("card_btn", imgui.ImVec2(width, height)) then
        api_FetchShopDetails(shop.serverId, shop.nickname)
    end
    
    local is_hovered = imgui.IsItemHovered()
    
    local bg_col_vec = is_hovered and imgui.ImVec4(0.16, 0.17, 0.22, 1.0) or imgui.ImVec4(0.12, 0.13, 0.16, 1.0)
    local bg_col = imgui.ColorConvertFloat4ToU32(bg_col_vec)
    local border_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, is_hovered and 0.1 or 0.03))
    
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), bg_col, S(10))
    draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), border_col, S(10), 15, S(1))
    
    -- Иконка
    local icon_radius = S(18)
    local icon_center = imgui.ImVec2(p.x + S(25), p.y + height/2)
    draw_list:AddCircleFilled(icon_center, icon_radius, imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.25, 0.25, 0.35, 1.0)))
    
    if font_fa then
        imgui.PushFont(font_fa)
        local icon_txt = fa('store')
        local txt_size = imgui.CalcTextSize(icon_txt)
        draw_list:AddText(imgui.ImVec2(icon_center.x - txt_size.x/2, icon_center.y - txt_size.y/2), 0xFFFFFFFF, icon_txt)
        imgui.PopFont()
    end
    
    local content_x = p.x + S(55)
    draw_list:AddText(imgui.ImVec2(content_x, p.y + S(12)), 0xFFFFFFFF, u8(shop.nickname))
    
    local shop_name = (shop.shop_name and shop.shop_name ~= "") and u8(shop.shop_name) or u8"Без названия"
    draw_list:AddText(imgui.ImVec2(content_x, p.y + S(30)), 0xFFAAAAAA, shop_name)
    
    local stats = string.format("S: %d  B: %d", shop.sell_count or 0, shop.buy_count or 0)
    local stats_size = imgui.CalcTextSize(stats)
    draw_list:AddText(imgui.ImVec2(p.x + width - stats_size.x - S(15), p.y + height/2 - stats_size.y/2), 0xFF808080, stats)
    
    imgui.PopID()
end

function renderGlobalMarketTab()
    local avail_w = imgui.GetContentRegionAvail().x
    local avail_h = imgui.GetContentRegionAvail().y
    local current_time = os.time()

    -- === Авто-обновление списка ===
    if current_time - MarketData.last_fetch > MarketConfig.FETCH_INTERVAL then
        api_FetchMarketList()
        MarketData.last_fetch = current_time
    end

    -- ======================================================
    -- === СЦЕНА 1: ПРОСМОТР ВЫБРАННОЙ ЛАВКИ ===
    -- ======================================================
    if MarketData.selected_shop then
        local shop = MarketData.selected_shop

        -- --- Шапка ---
        imgui.Dummy(imgui.ImVec2(0, S(5))) -- Отступ сверху
        
        -- Используем группу для выравнивания
        imgui.BeginGroup()
            -- Отступ кнопки от левого края
            imgui.SetCursorPosX(S(15))
            
            -- 1. Кнопка НАЗАД
            if imgui.Button(fa('arrow_left'), imgui.ImVec2(S(40), S(40))) then
                MarketData.selected_shop = nil
            end
            if imgui.IsItemHovered() then imgui.SetTooltip(u8"Вернуться к списку") end

            imgui.SameLine(nil, S(10))

            -- 2. Кнопка НАЙТИ ЛАВКУ (GPS)
            if imgui.Button(fa('location_dot'), imgui.ImVec2(S(40), S(40))) then
				-- Пытаемся использовать playerId из данных лавки (если есть)
				local target_id = nil
				local nickname = shop.nickname
				
				-- Если у лавки есть playerId (полученный с сервера), используем его
				if shop.playerId and shop.playerId ~= 0 then
					target_id = shop.playerId
					sampSendChat("/findilavka " .. target_id)
					sampAddChatMessage(string.format('[RodinaMarket] {00ff00}Метка на лавку игрока %s (ID: %d) установлена!', nickname, target_id), -1)
				else
					-- Если playerId нет, пытаемся найти ID по нику
					local found_id = nil
					
					-- Пробуем найти ID через sampGetPlayerIdByNickname
					local status, id = pcall(sampGetPlayerIdByNickname, shop.nickname)
					if status and id and id ~= -1 then
						found_id = id
					else
						-- Ищем вручную в списке игроков
						for i = 0, 1000 do
							if sampIsPlayerConnected(i) then
								local playerNick = sampGetPlayerNickname(i)
								if playerNick and playerNick == shop.nickname then
									found_id = i
									break
								end
							end
						end
					end
					
					if found_id then
						sampSendChat("/findilavka " .. found_id)
						sampAddChatMessage(string.format('[RodinaMarket] {00ff00}Метка на лавку игрока %s (ID: %d) установлена!', shop.nickname, found_id), -1)
					else
						sampSendChat("/findilavka " .. shop.nickname)
						sampAddChatMessage(string.format('[RodinaMarket] {ffff00}Команда отправлена: /findilavka %s (ID не найден)', shop.nickname), -1)
					end
				end
			end
            if imgui.IsItemHovered() then imgui.SetTooltip(u8"Поставить метку (/findilavka)") end

            imgui.SameLine(nil, S(15))

            -- 3. Информация о лавке (Вертикальное центрирование относительно кнопок)
            local cursor_y = imgui.GetCursorPosY()
            imgui.SetCursorPosY(cursor_y + S(2)) 
            
            imgui.BeginGroup()
                -- Никнейм
                imgui.PushFont(font_fa) 
                imgui.TextColored(CURRENT_THEME.text_primary, u8(shop.nickname))
                imgui.PopFont()
                
                -- Название сервера (Используем функцию для преобразования IP в Имя)
                local server_name = getServerDisplayName(shop.serverId)
                imgui.TextDisabled(u8(server_name))
            imgui.EndGroup()
        imgui.EndGroup()

        imgui.Dummy(imgui.ImVec2(0, S(5)))
        imgui.Separator()
        
        -- Рассчитываем высоту для списков
        local list_h = imgui.GetContentRegionAvail().y - S(10)

        -- === КОЛОНКИ ===
        imgui.Columns(2, "ShopDetailsColumns", false) 

        -- ===== ПРОДАЖА (Левая колонка) =====
        do
            -- Фон заголовка
            local p = imgui.GetCursorScreenPos()
            local col_w = imgui.GetColumnWidth()
            local draw_list = imgui.GetWindowDrawList()
            
            -- Рисуем подложку под заголовок (Зеленоватый оттенок)
            draw_list:AddRectFilled(
                p, 
                imgui.ImVec2(p.x + col_w - S(5), p.y + S(30)), 
                imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.15, 0.25, 0.15, 0.6)), 
                S(5)
            )

            -- Центрируем заголовок
            local title = fa('arrow_up_from_bracket') .. " " .. u8"ПРОДАЖА"
            local tw = imgui.CalcTextSize(title).x
            imgui.SetCursorPosX(imgui.GetCursorPosX() + (col_w - tw) / 2)
            imgui.SetCursorPosY(imgui.GetCursorPosY() + S(5))
            
            imgui.TextColored(imgui.ImVec4(0.6, 1.0, 0.6, 1.0), title)
            
            imgui.Dummy(imgui.ImVec2(0, S(10)))

            -- Список товаров
            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.08, 0.09, 0.11, 0.3))
            imgui.BeginChild("ShopSellList", imgui.ImVec2(col_w - S(5), list_h - S(40)), true)
                if #shop.sell_list == 0 then
                    local txt = u8"Нет товаров"
                    local txt_size = imgui.CalcTextSize(txt)
                    imgui.SetCursorPos(imgui.ImVec2((imgui.GetWindowWidth() - txt_size.x)/2, S(50)))
                    imgui.TextDisabled(txt)
                else
                    -- ИСПРАВЛЕНО: передаем i (индекс) первым параметром
                    for i, item in ipairs(shop.sell_list) do
                        renderMarketItemRow(i, item, imgui.GetContentRegionAvail().x, true)
                        imgui.Dummy(imgui.ImVec2(0, S(5)))
                    end
                end
            imgui.EndChild()
            imgui.PopStyleColor()
        end

        imgui.NextColumn()

        -- ===== СКУПКА (Правая колонка) =====
        do
             -- Фон заголовка
             local p = imgui.GetCursorScreenPos()
             local col_w = imgui.GetColumnWidth()
             local draw_list = imgui.GetWindowDrawList()
             
             -- Рисуем подложку под заголовок (Красноватый оттенок)
             draw_list:AddRectFilled(
                 p, 
                 imgui.ImVec2(p.x + col_w, p.y + S(30)), 
                 imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.25, 0.15, 0.15, 0.6)), 
                 S(5)
             )

            local title = fa('arrow_down_to_bracket') .. " " .. u8"СКУПКА"
            local tw = imgui.CalcTextSize(title).x
            imgui.SetCursorPosX(imgui.GetCursorPosX() + (col_w - tw) / 2)
            imgui.SetCursorPosY(imgui.GetCursorPosY() + S(5))

            imgui.TextColored(imgui.ImVec4(1.0, 0.6, 0.6, 1.0), title)
            
            imgui.Dummy(imgui.ImVec2(0, S(10)))

            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0.08, 0.09, 0.11, 0.3))
            imgui.BeginChild("ShopBuyList", imgui.ImVec2(0, list_h - S(40)), true)
                if #shop.buy_list == 0 then
                    local txt = u8"Скупка пуста"
                    local txt_size = imgui.CalcTextSize(txt)
                    imgui.SetCursorPos(imgui.ImVec2((imgui.GetWindowWidth() - txt_size.x)/2, S(50)))
                    imgui.TextDisabled(txt)
                else
                    -- ИСПРАВЛЕНО: передаем i (индекс) первым параметром
                    for i, item in ipairs(shop.buy_list) do
                        renderMarketItemRow(i, item, imgui.GetContentRegionAvail().x, false)
                        imgui.Dummy(imgui.ImVec2(0, S(5)))
                    end
                end
            imgui.EndChild()
            imgui.PopStyleColor()
        end

        imgui.Columns(1)

    -- ======================================================
    -- === СЦЕНА 2: СПИСОК ВСЕХ ЛАВОК ===
    -- ======================================================
    else
        local padding = S(15)
        local working_w = avail_w - padding * 2
        imgui.SetCursorPosX(padding)

        imgui.BeginGroup()
            imgui.Dummy(imgui.ImVec2(0, S(5)))

            -- === Фильтрация ===
            local search_q = u8:decode(ffi.string(MarketData.search_buffer)):lower()
            local filtered = {}

            for _, shop in ipairs(MarketData.shops_list) do
                local nick = shop.nickname:lower()
                local name = (shop.shop_name or ""):lower()
                if search_q == ""
                or nick:find(search_q, 1, true)
                or name:find(search_q, 1, true) then
                    table.insert(filtered, shop)
                end
            end

            if MarketData.is_loading then
                imgui.TextColored(
                    imgui.ImVec4(0.4, 0.8, 1.0, 1.0),
                    fa('spinner') .. u8" Загрузка данных..."
                )
            else
                imgui.TextDisabled(
                    string.format(u8"Найдено лавок: %d", #filtered)
                )
            end

            imgui.Separator()
            imgui.Dummy(imgui.ImVec2(0, S(10)))

            -- === GRID ===
            local card_h = S(70)
            local gap_x = S(15)
            local gap_y = S(15)
            local min_w = S(280)

            local columns = math.floor((working_w + gap_x) / (min_w + gap_x))
            if columns < 1 then columns = 1 end
            if columns > 3 then columns = 3 end

            local card_w = (working_w - gap_x * (columns - 1)) / columns

            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0, 0, 0, 0))
            imgui.BeginChild("ShopsGrid", imgui.ImVec2(working_w, -1), false)

                if #filtered == 0 and not MarketData.is_loading then
                    local txt = u8"Лавки не найдены"
                    local tw = imgui.CalcTextSize(txt).x
                    imgui.SetCursorPos(imgui.ImVec2((working_w - tw) / 2, S(50)))
                    imgui.TextDisabled(txt)
                else
                    for i, shop in ipairs(filtered) do
                        local col = (i - 1) % columns
                        if col > 0 then imgui.SameLine(0, gap_x) end

                        renderShopCardGrid(shop, card_w, card_h)

                        if col == columns - 1 then
                            imgui.Dummy(imgui.ImVec2(0, gap_y))
                        end
                    end
                end

            imgui.EndChild()
            imgui.PopStyleColor()

        imgui.EndGroup()
    end
end

function renderLogsTab()
    local avail_w = imgui.GetContentRegionAvail().x
    local side_padding = S(15)
    imgui.Dummy(imgui.ImVec2(0, S(10))) 
    imgui.Indent(side_padding)
    local content_w = avail_w - (side_padding * 2)

    -- Обновление данных логов
    local current_idx = Buffers.logs_current_date_idx
    local current_boxes = tostring(Buffers.log_filters.show_sales[0]) .. tostring(Buffers.log_filters.show_purchases[0])
    
    if current_idx ~= last_log_idx or current_boxes ~= last_check_boxes or not Data.current_view_logs then
        cached_income, cached_expense = updateLogView()
        last_log_idx = current_idx
        last_check_boxes = current_boxes
    end
    
    local profit = cached_income - cached_expense
    local filtered_list = Data.current_view_logs or {}

    -- === 1. ДАШБОРД (Карточки) ===
    local card_h = S(70)
    local gap = S(12)
    local card_w = (content_w - (gap * 2)) / 3

    drawStatCard("Доход", cached_income, imgui.ImVec4(0.15, 0.35, 0.20, 0.8), card_w, card_h)
    imgui.SameLine(nil, gap)
    drawStatCard("Расход", cached_expense, imgui.ImVec4(0.35, 0.15, 0.15, 0.8), card_w, card_h)
    imgui.SameLine(nil, gap)
    local profit_col = profit >= 0 and imgui.ImVec4(0.2, 0.2, 0.35, 0.8) or imgui.ImVec4(0.35, 0.2, 0.2, 0.8)
    drawStatCard("Прибыль", profit, profit_col, card_w, card_h)

    imgui.Dummy(imgui.ImVec2(0, S(20)))

    -- === 2. ФИЛЬТРЫ ===
    imgui.BeginGroup()
        -- Красивый селектор даты
        imgui.TextColored(CURRENT_THEME.text_secondary, u8("Архив за дату:"))
        imgui.SameLine()
        imgui.SetNextItemWidth(S(150))
        pushComboStyles()
        if Buffers.logs_current_date_idx == 0 and #Buffers.logs_dates_cache > 0 then Buffers.logs_current_date_idx = 1 end
        local combo_preview = Buffers.logs_dates_cache[Buffers.logs_current_date_idx] or u8("Нет данных")
        if imgui.BeginCombo("##date_selector", combo_preview) then
            for i, date in ipairs(Buffers.logs_dates_cache) do
                if imgui.Selectable(date, Buffers.logs_current_date_idx == i) then
                    Buffers.logs_current_date_idx = i
                    cached_income, cached_expense = updateLogView()
                end
            end
            imgui.EndCombo()
        end
        popComboStyles()

        imgui.SameLine(nil, S(20))
        imgui.Checkbox(u8("Продажи"), Buffers.log_filters.show_sales)
        imgui.SameLine(nil, S(15))
        imgui.Checkbox(u8("Покупки"), Buffers.log_filters.show_purchases)
        
        imgui.SameLine(nil, S(20))
        if imgui.Button(fa('arrows_rotate'), imgui.ImVec2(S(30), S(30))) then
            refreshLogDates()
            cached_income, cached_expense = updateLogView()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(u8"Обновить список") end
    imgui.EndGroup()

    imgui.Dummy(imgui.ImVec2(0, S(10)))
    imgui.Separator()
    imgui.Dummy(imgui.ImVec2(0, S(10)))

    -- === 3. СПИСОК (КАРТОЧКИ) ===
    renderSmoothScrollBox("LogsListScroll", imgui.ImVec2(content_w, -S(35)), function()
        if #filtered_list == 0 then
            local text = u8("В этот день сделок не зафиксировано")
            local t_size = imgui.CalcTextSize(text)
            imgui.SetCursorPosX((content_w - t_size.x) / 2)
            imgui.SetCursorPosY(S(50))
            imgui.TextDisabled(text)
        else
            local draw_list = imgui.GetWindowDrawList()
            local row_h = S(45)
            
            for i, log in ipairs(filtered_list) do
                local p = imgui.GetCursorScreenPos()
                
                -- Фон строки
                local bg_col = (i % 2 == 0) and CURRENT_THEME.bg_secondary or CURRENT_THEME.bg_tertiary
                draw_list:AddRectFilled(p, imgui.ImVec2(p.x + content_w, p.y + row_h), imgui.ColorConvertFloat4ToU32(bg_col), S(6))
                
                -- Цветной индикатор слева
                local indicator_col = (log.type == "sale") and CURRENT_THEME.accent_success or CURRENT_THEME.accent_danger
                draw_list:AddRectFilled(p, imgui.ImVec2(p.x + S(4), p.y + row_h), imgui.ColorConvertFloat4ToU32(indicator_col), S(6), 5)
                
                local cy = p.y + row_h/2
                
                -- Время
                local time_str = log.date:match("%d%d:%d%d:%d%d") or log.date
                draw_list:AddText(imgui.ImVec2(p.x + S(15), cy - S(7)), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint), time_str)
                
                -- Иконка типа
                if font_fa then
                    imgui.PushFont(font_fa)
                    local icon = (log.type == "sale") and fa('arrow_right_from_bracket') or fa('arrow_right_to_bracket')
                    draw_list:AddText(imgui.ImVec2(p.x + S(80), cy - S(7)), imgui.ColorConvertFloat4ToU32(indicator_col), icon)
                    imgui.PopFont()
                end
                
                -- Игрок
                draw_list:AddText(imgui.ImVec2(p.x + S(110), cy - S(7)), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_secondary), u8(log.player))
                
                -- Товар (Жирнее)
                local item_str = u8(log.item) .. " (x" .. log.amount .. ")"
                draw_list:AddText(imgui.ImVec2(p.x + S(260), cy - S(7)), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary), item_str)
                
                -- Цена (Справа)
                local price_str = formatMoney(log.total) .. " $"
                local price_sz = imgui.CalcTextSize(price_str)
                draw_list:AddText(imgui.ImVec2(p.x + content_w - price_sz.x - S(15), cy - S(7)), imgui.ColorConvertFloat4ToU32(indicator_col), price_str)
                
                imgui.Dummy(imgui.ImVec2(0, row_h + S(4))) -- Отступ между строками
            end
        end
    end)
    
    imgui.Unindent(side_padding)
    imgui.Dummy(imgui.ImVec2(0, S(10)))
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
        
        -- ... (код цикла for ... do, который заполняет Data.scanned_items оставляем без изменений) ...
        -- Просто скопируй старый цикл сюда, если он большой, или замени только конец функции:

        for _, item_data in pairs(Data.cef_inventory_items) do
            if not isItemUnsellable(item_data.model_id) then
                local display_name = item_data.name
                if item_data.amount and item_data.amount > 1 then
                    display_name = display_name .. " (x" .. item_data.amount .. ")"
                end

                table.insert(Data.scanned_items, {
                    name = display_name, 
                    original_name = item_data.name,
                    model_id = item_data.model_id,
                    amount = item_data.amount
                })
            end
        end
        closeCEFInventory()
        
        local inventory_ids = {}
        for _, item in ipairs(Data.scanned_items) do
            inventory_ids[tostring(item.model_id)] = true
        end
        
        for _, sell_item in ipairs(Data.sell_list) do
            if sell_item.model_id then
                if inventory_ids[tostring(sell_item.model_id)] then
                    sell_item.missing = false
                else
                    sell_item.missing = true
                end
            end
        end
        
        -- === НОВЫЙ БЛОК СОХРАНЕНИЯ ===
        -- Сохраняем только по факту завершения сканирования
        saveJsonFile(PATHS.CACHE .. 'scanned_items.json', Data.scanned_items)
        saveJsonFile(PATHS.DATA .. 'item_amounts.json', Data.inventory_item_amounts) -- Сохраняем количества
        saveListsConfig() -- Сохраняем sell_list (обновились статусы missing)
        
        App.is_scanning = false
        Data.cached_sell_filtered = nil 
        
        sampAddChatMessage('[RodinaMarket] {00ff00}Сканирование завершено! Найдено слотов: ' .. #Data.scanned_items, -1)
        App.win_state[0] = true
    end, 500)
end

function isItemInSellList(model_id)
    -- Проверяем есть ли хотя бы один товар с этим model_id в списке продажи
    if not model_id then return false end
    for _, item in ipairs(Data.sell_list) do
        if item and item.model_id and tostring(item.model_id) == tostring(model_id) then 
            return true 
        end
    end
    return false
end

-- Функция для подсчета количества товаров с одинаковым model_id в списке продажи
function countItemInSellList(model_id)
    if not model_id then return 0 end
    local count = 0
    for _, item in ipairs(Data.sell_list) do
        if item and item.model_id and tostring(item.model_id) == tostring(model_id) then 
            count = count + 1 
        end
    end
    return count
end

-- Оптимизированная версия для вычисления количества предметов
function getItemCounts(model_id)
    if not model_id then return 0, 0 end
    local model_str = tostring(model_id)
    
    -- Считаем сколько раз предмет уже добавлен в список продажи
    local count_in_sell = countItemInSellList(model_id)
    
    -- Считаем сколько таких предметов (стаков) найдено при сканировании
    local count_in_inv = 0
    for _, item in ipairs(Data.scanned_items) do
        if item and item.model_id and tostring(item.model_id) == model_str then 
            count_in_inv = count_in_inv + 1 
        end
    end
    
    -- Возвращаем оба значения для использования в интерфейсе
    return count_in_sell, count_in_inv
end

function isItemUnsellable(model_id)
    if not model_id then return false end
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
    -- App.win_state[0] = false -- УДАЛИТЬ ИЛИ ЗАКОММЕНТИРОВАТЬ ЭТУ СТРОКУ
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
    
    -- Сохраняем доступные товары для скупки
    saveJsonFile(PATHS.CACHE .. 'buyable_items.json', Data.buyable_items)
    
    refresh_buyables = true
    refreshed_buyables = {}
    
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

function startCEFSelling()
    if App.is_scanning or App.is_selling_cef or App.is_scanning_buy or State.buying.active then return end
    
    -- Проверяем активные товары
    local active_items = 0
    for _, item in ipairs(Data.sell_list) do
        if item.active ~= false then
            active_items = active_items + 1
        end
    end
    
    if active_items == 0 then
        sampAddChatMessage('[RodinaMarket] {ff0000}Нет активных товаров для продажи! (Включите "глаз" у товаров)', -1)
        return
    end
    
    if #Data.sell_list == 0 then
        sampAddChatMessage('[RodinaMarket] {ff0000}Нет товаров для выставления!', -1)
        return
    end
    
    App.is_selling_cef = true
    App.current_sell_item_index = 0
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
    end, 500)
end

function stopSelling()
    if not App.is_selling_cef then return end
    
    App.is_selling_cef = false
    Data.cef_sell_queue = {}
    App.current_processing_item = nil
    
    -- Очищаем задачи
    App.tasks.remove_by_name("cef_sell_press_alt")
    App.tasks.remove_by_name("cef_sell_release_alt")
    App.tasks.remove_by_name("wait_cef_dialog_failsafe")
    App.tasks.remove_by_name("cef_dialog_timeout")
    App.tasks.remove_by_name("cef_next_item_delay")
    App.tasks.remove_by_name("retry_cef_check")
    
    -- !!! ПРИ ПРЕРЫВАНИИ ТОЖЕ ОБНОВЛЯЕМ !!!
    -- Считаем, что пользователь выставил то, что успел, или то, что было активно в списке
    updateLiveShopState('sell') 
    api_SendMyData()
    
    sendCEF("inventoryClose")
    
    -- ЗАКОММЕНТИРОВАТЬ или УДАЛИТЬ следующую строку:
    -- sampAddChatMessage('[RodinaMarket] {ff0000}Продажа товаров остановлена (Список обновлен)!', -1)
end

function prepareCEFSellQueue()
    Data.cef_sell_queue = {}
    local used_slots = {}
    for _, sell_item in ipairs(Data.sell_list) do
        if sell_item.active ~= false then
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
                -- Добавляем поле retry_count
                table.insert(Data.cef_sell_queue, {
                    slot=found_slot, 
                    model=target_model, 
                    amount=sell_item.amount, 
                    price=sell_item.price, 
                    name=sell_item.name,
                    retry_count = 0 
                })
            end
        end
    end
    if #Data.cef_sell_queue > 0 then
        sampAddChatMessage('[RodinaMarket] {00ff00}Найдено активных товаров для продажи: ' .. #Data.cef_sell_queue, -1)
        processNextCEFSellItem()
    else
        sampAddChatMessage('[RodinaMarket] {ff0000}Активные товары из списка не найдены в инвентаре!', -1)
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
        
        -- !!! ВОТ ЗДЕСЬ ОБНОВЛЯЕМ МАРКЕТ !!!
        updateLiveShopState('sell') -- Фиксируем список продажи
        api_SendMyData()            -- Отправляем на сервер (скупка останется старой, если была)
        
        sendCEF("inventoryClose")
        return
    end
    
    -- Берем первый элемент, но НЕ удаляем его сразу, пока не убедимся, что процесс пошел
    -- Или удаляем и храним в App.current_processing_item (как сейчас), но с логикой повтора
    
    -- В текущей логике элемент уже удален из очереди в переменную App.current_processing_item
    -- Если App.current_processing_item существует и мы здесь снова (из-за таймаута), значит это повтор
    
    if not App.current_processing_item then
        App.current_processing_item = table.remove(Data.cef_sell_queue, 1)
    end

    local item = App.current_processing_item
    
    -- Проверка на количество попыток
    if item.retry_count >= 3 then
        sampAddChatMessage(string.format('[RodinaMarket] {ff0000}Ошибка выставления "%s". Пропуск.', item.name), -1)
        App.current_processing_item = nil -- Сбрасываем текущий предмет
        processNextCEFSellItem() -- Переходим к следующему
        return
    end

    item.retry_count = item.retry_count + 1
    
    local payload_click = string.format('clickOnBlock|{"slot": %d, "type": 1}', item.slot)
    sendCEF(payload_click)
    
    App.tasks.add("cef_dialog_timeout", function()
        if App.is_selling_cef and App.current_processing_item then
            log("Таймаут ожидания диалога. Попытка " .. item.retry_count .. "/3")
            -- Не удаляем item, функция вызовется снова и проверит retry_count
            processNextCEFSellItem()
        end
    end, 2000) -- Уменьшил тайм-аут до 2 сек для скорости
end

function startBuying()
    if App.is_scanning or App.is_selling_cef or App.is_scanning_buy or State.buying.active then return end
    
    local active_count = 0
    for _, item in ipairs(Data.buy_list) do
        if item.active then active_count = active_count + 1 end
    end
    
    if active_count == 0 then 
        sampAddChatMessage('[RodinaMarket] {ff0000}Нет активных товаров для скупки! (Включите "глаз" у товаров)', -1) 
        return 
    end
    
    -- Обновляем данные из буферов
    for i, item in ipairs(Data.buy_list) do
        local buf_key_price = "bp_" .. i
        local buf_key_amount = "ba_" .. i
        
        if Buffers.buy_input_buffers[buf_key_price] then
            local price_str = ffi.string(Buffers.buy_input_buffers[buf_key_price])
            item.price = tonumber(price_str) or 0
        end
        
        if Buffers.buy_input_buffers[buf_key_amount] then
            local amount_str = ffi.string(Buffers.buy_input_buffers[buf_key_amount])
            item.amount = tonumber(amount_str) or 0
        end
    end
    
    saveListsConfig()
    
    State.buying = {
        active = true, 
        stage = 'waiting_menu',
        current_item_index = 1, 
        items_to_buy = {}, 
        last_search_name = nil,
        waiting_for_alt = false
    }
    
    for _, item in ipairs(Data.buy_list) do
        if item.active then
            local is_acc = isAccessory(item.name)
            
            if item.price > 0 then
                if is_acc or item.amount > 0 then
                    table.insert(State.buying.items_to_buy, {
                        name = item.name, 
                        index = item.index, 
                        amount = math.floor(item.amount),
                        price = math.floor(item.price)
                    })
                end
            end
        end
    end

    if #State.buying.items_to_buy == 0 then
        sampAddChatMessage('[RodinaMarket] {ff0000}Ошибка: Товары имеют цену 0 или количество 0 (для не-аксессуаров)!', -1)
        State.buying.active = false
        return
    end
    
    sampAddChatMessage(string.format('[RodinaMarket] {ffff00}Начинаю скупку %d товаров...', #State.buying.items_to_buy), -1)

    -- Попытка нажать альт программно
    lua_thread.create(function()
        wait(500)
        setVirtualKeyDown(0x12, true)
        wait(150)
        setVirtualKeyDown(0x12, false)
    end)
    
    -- Таймер проверки: если диалог не открылся сам, просим игрока
    App.tasks.add("wait_buy_start", function()
        if State.buying.active and State.buying.stage == 'waiting_menu' then 
            State.buying.waiting_for_alt = true
            sampAddChatMessage('[RodinaMarket] {ffff00}Диалог не открылся автоматически. Подойдите к лавке и нажмите ALT!', -1)
        end
    end, 2000)
end

function recursiveToCP1251(tbl)
    if type(tbl) ~= "table" then return tbl end
    
    local new_tbl = {}
    for k, v in pairs(tbl) do
        local new_k = k
        if type(k) == "string" then
            local status, res = pcall(u8.decode, u8, k)
            if status then new_k = res end
        end
        
        local new_v = v
        if type(v) == "string" then
            -- Пытаемся декодировать, если ошибка - оставляем как есть
            local status, res = pcall(u8.decode, u8, v)
            if status then new_v = res end
        elseif type(v) == "table" then
            new_v = recursiveToCP1251(v)
        end
        
        -- Защита от null значений из JSON
        if new_v == json.null then new_v = nil end
        
        new_tbl[new_k] = new_v
    end
    return new_tbl
end

function sampGetPlayerIdByNickname(nick)
    -- Если ник не передан, пытаемся вернуть свой ID
    if nick == nil then
        local res, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
        if res then return true, id else return false, -1 end
    end
    
    -- Стандартный поиск по нику
    for i = 0, 1000 do
        if sampIsPlayerConnected(i) then
            if sampGetPlayerNickname(i) == nick then
                return true, i
            end
        end
    end
    return false, -1
end

function stopBuying()
    State.buying.active = false

    local tasks_to_clear = {"wait_buy_start", "wait_buy_items_dialog", "wait_buy_name_dialog", "wait_buy_select_dialog", "wait_buy_price_dialog", "wait_buy_next_item", "wait_buy_finish"}
    for _, t in ipairs(tasks_to_clear) do App.tasks.remove_by_name(t) end
    
    -- При остановке обновляем скупку согласно текущему конфигу
    updateLiveShopState('buy')
    api_SendMyData()
    
    -- ЗАКОММЕНТИРОВАТЬ или УДАЛИТЬ следующую строку:
    -- sampAddChatMessage('[RodinaMarket] {ff0000}Скупка остановлена! Список в Маркете обновлен.', -1)
end

function finishBuying()
    State.buying.active = false
    
    local tasks_to_clear = {"wait_buy_start", "wait_buy_items_dialog", "wait_buy_name_dialog", "wait_buy_select_dialog", "wait_buy_price_dialog", "wait_buy_next_item", "wait_buy_finish"}
    for _, t in ipairs(tasks_to_clear) do App.tasks.remove_by_name(t) end
    
    -- !!! ФИКСИРУЕМ СКУПКУ !!!
    updateLiveShopState('buy') -- Обновляем раздел скупки в "живой лавке"
    api_SendMyData()           -- Отправляем (продажа не сотрется, так как берется из Data.live_shop.sell)
    
    -- ЗАКОММЕНТИРОВАТЬ или УДАЛИТЬ следующую строку:
    -- sampAddChatMessage('[RodinaMarket] {00ff00}Готово! Все товары выставлены на скуп. Лавка обновлена.', -1)
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

function startAvgPriceScan()
    if App.is_scanning or App.is_selling_cef or App.is_scanning_buy or State.buying.active or State.avg_scan.active then 
        return 
    end
    
    State.avg_scan.active = true
    State.avg_scan.processed_count = 0
    
    sampAddChatMessage('[RodinaMarket] {ffff00}Начинаю сканирование средних цен...', -1)
    sampAddChatMessage('[RodinaMarket] {ffff00}Подойдите к пикапу "Ценовая политика" в ЦР и откройте диалог.', -1)
    
    App.tasks.add("avg_scan_timeout", function()
        if State.avg_scan.active then
            State.avg_scan.active = false
            sampAddChatMessage('[RodinaMarket] {ff0000}Сканирование прервано: диалог не был открыт вовремя!', -1)
        end
    end, 10000)
end

function events.onDialogResponse(id, button, listbox_item, input)
    -- Управление лавкой
    if id == 9 and button == 1 then
        local dialog_text = sampGetDialogText()
        if dialog_text then
            local index = 0
            for line in dialog_text:gmatch("[^\r\n]+") do
                -- убираем цвет-коды
                local clean = line:gsub("{......}", "")

                if index == listbox_item then
                    if clean:find("Открыть меню") then
                        App.win_state[0] = true
                        sampAddChatMessage(
                            '[RodinaMarket] {00ff00}Меню скрипта открыто.',
                            -1
                        )
                        return false -- ПЕРЕХВАТ
                    end
                    break
                end
                index = index + 1
            end
        end
    end
    return true
end

function events.onShowDialog(id, style, title, b1, b2, text)
    -- Авто-название лавки
    if title:find("Название лавки") or id == 8 then
        if Buffers.settings.auto_name[0] then
            local name_utf8 = ffi.string(Buffers.settings.shop_name)
            if name_utf8 ~= "" then
                lua_thread.create(function()
                    wait(math.random(300, 500)) 
                    local name_cp1251 = u8:decode(name_utf8)
                    sampSendDialogResponse(id, 1, 0, name_cp1251)
                    sampAddChatMessage(string.format('[RodinaMarket] {00ff00}Лавка названа автоматически: "%s"', name_cp1251), -1)
                end)
                return false 
            end
        end
    end

    -- Сканирование средних цен
    if title:find("Ценовая статистика") or title:find("Средние цены") then
        if not State.avg_scan.active then return true end
        
        App.tasks.remove_by_name("avg_scan_timeout")
        
        -- Используем задачу вместо потока для стабильности
        App.tasks.add("process_avg_scan", function()
            if not sampIsDialogActive() then return end
            -- ... (твой код парсинга цен) ...
            -- Скопируй сюда внутрянку из старого onShowDialog для avg_scan
            -- (код парсинга цен оставляем тот же, он не вызывает краш)
            local dialog_text = sampGetDialogText()
            for line in dialog_text:gmatch("[^\r\n]+") do
                if not line:find("Средняя цена") and not line:find("Следующая страница") and not line:find("Предыдущая страница") and not line:find("Ценовая статистика") then
                    local item_name, price = line:match("(.+)\t%d+\t(%d+)")
                    if not item_name then item_name, price = line:match("(.+)\t(%d+)") end
                    if item_name and price and tonumber(price) and tonumber(price) > 0 then 
                        updateAveragePrice(item_name, price) 
                        State.avg_scan.processed_count = State.avg_scan.processed_count + 1 
                    end
                end
            end
            
            local next_btn_index = sampGetListboxItemByText("Следующая страница")
            if next_btn_index ~= -1 then
                sampSetCurrentDialogListItem(next_btn_index)
                if sampIsDialogActive() then sampCloseCurrentDialogWithButton(1) end
            else
                State.avg_scan.active = false
                saveJsonFile(PATHS.CACHE .. 'average_prices.json', Data.average_prices)
                sampAddChatMessage(string.format('[RodinaMarket] {00ff00}Сканирование завершено! Обновлено товаров: %d', State.avg_scan.processed_count), -1)
                sampCloseCurrentDialogWithButton(0)
                App.win_state[0] = true
            end
        end, 100)
        return true -- Возвращаем true, чтобы диалог отрисовался (или false если хочешь скрыть)
    end

    -- Обработка CEF продажи
    if App.is_selling_cef and (id == 9 or title:find("Управление лавкой")) then
        sampSendDialogResponse(id, 1, 0, "")
        App.tasks.add("wait_cef_data_after_dialog", function()
            if not App.is_selling_cef then return end
            local attempts = 0
            local function checkData()
                attempts = attempts + 1
                if countTable(Data.cef_slots_data) > 0 then prepareCEFSellQueue()
                else 
                    if attempts < 10 then 
                        App.tasks.add("retry_cef_check_"..attempts, checkData, 500) 
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
	
	if id == 9 and title:find("Управление лавкой")
	   and not App.is_selling_cef
	   and not State.buying.active then

		if not text:find("Открыть меню скрипта") then
			local new_text = text .. "\n[40B5FF]8. Открыть меню скрипта"
			sampShowDialog(id, title, new_text, b1, b2, style)
			return false
		end
	end

    -- === ЛОГИКА СКУПКИ (ИСПРАВЛЕННАЯ) ===
    if State.buying.active then
        -- Сбрасываем ожидание
        State.buying.waiting_for_alt = false
        
        -- Очищаем старые задачи, чтобы они не наслоились
        local tasks_to_clear = {"wait_buy_start", "wait_buy_items_dialog", "wait_buy_name_dialog", "wait_buy_select_dialog", "wait_buy_price_dialog", "wait_buy_next_item", "wait_buy_finish"}
        for _, t in ipairs(tasks_to_clear) do App.tasks.remove_by_name(t) end

        -- Вместо lua_thread используем задачу с задержкой, это безопаснее для памяти
        App.tasks.add("buying_dialog_process", function()
            if not State.buying.active then return end

            -- Главное меню лавки
            if id == 9 or title:find("Управление лавкой") then
                if State.buying.stage == 'waiting_menu' or State.buying.stage == 'cycle_next' then
                    State.buying.stage = 'waiting_category_list'
                    sampSendDialogResponse(id, 1, 1, "")
                elseif State.buying.stage == 'finishing' then
                    sampSendDialogResponse(id, 0, -1, "")
                    finishBuying()
                end
                return
            end

            -- Выбор категории
            if id == 10 or (title:find("Скупка") and text:find("Поиск предмета")) then
                if State.buying.stage == 'waiting_category_list' or State.buying.stage == 'cycle_next' then
                    if State.buying.current_item_index > #State.buying.items_to_buy then
                        State.buying.stage = 'finishing'
                        sampSendDialogResponse(id, 0, -1, "")
                    else
                        State.buying.stage = 'waiting_name_input'
                        sampSendDialogResponse(id, 1, 0, "")
                    end
                end
                return
            end

            -- Ввод названия
            if id == 909 or title:find("Поиск предмета") then
                if State.buying.stage == 'waiting_name_input' then
                    local current_item = State.buying.items_to_buy[State.buying.current_item_index]
                    if current_item then
                        State.buying.last_search_name = current_item.name
                        State.buying.stage = 'waiting_select'
                        
                        local search_query = ""
                        if current_item.index and tonumber(current_item.index) then
                            search_query = tostring(current_item.index)
                        else
                            search_query = u8:decode(current_item.name)
                        end
                        sampSendDialogResponse(id, 1, -1, search_query)
                    end
                end
                return
            end

            -- Выбор предмета из списка
            if id == 910 then
                if State.buying.stage == 'waiting_select' then
                    local found_index = 0
                    if text and State.buying.last_search_name then
                        local search_name_lower = to_lower(u8:decode(State.buying.last_search_name))
                        local list_idx = 0
                        for line in text:gmatch("[^\r\n]+") do
                            local clean_line = line:gsub("{......}", ""):gsub("%s*%[%d+%]$", ""):gsub("^%s+", ""):gsub("%s+$", "")
                            clean_line = to_lower(clean_line)
                            if clean_line:find(search_name_lower, 1, true) then
                                found_index = list_idx
                                break
                            end
                            list_idx = list_idx + 1
                        end
                    end
                    State.buying.stage = 'waiting_price_input'
                    sampSendDialogResponse(id, 1, found_index, "")
                end
                return
            end

            -- Ввод цены и количества
            if id == 11 or (title:find("Скупка") and style == 1) then
                if State.buying.stage == 'waiting_price_input' or State.buying.stage == 'waiting_select' then
                    local current_item = State.buying.items_to_buy[State.buying.current_item_index]
                    if current_item then
                        local input_str = ""
                        
                        if isAccessory(current_item.name) then
                            local color_id = math.floor(current_item.amount) 
                            local price_val = math.floor(current_item.price)
                            input_str = string.format("%d,%d", price_val, color_id)
                        else
                            input_str = string.format("%d,%d", math.floor(current_item.amount), math.floor(current_item.price))
                        end

                        sampSendDialogResponse(id, 1, -1, input_str)
                        
                        State.buying.current_item_index = State.buying.current_item_index + 1
                        State.buying.stage = 'cycle_next'
                    end
                end
                return
            end
        end, 20) -- Небольшая задержка 20мс, чтобы не флудить
        return false
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
            App.tasks.add("wait_category_menu", function() if State.buying_scan.active and State.buying_scan.stage == 'waiting_category_menu' then stopBuyingScan() end end, 5000)
        end
        if State.buying_scan.stage == 'waiting_category_menu' and (id == 10 and title:find("Скупка:")) then
            State.buying_scan.stage = 'waiting_full_list_menu'
            sampSendDialogResponse(id, 1, 1, "")
            App.tasks.add("wait_full_list_menu", function() if State.buying_scan.active and State.buying_scan.stage == 'waiting_full_list_menu' then stopBuyingScan() end end, 5000)
        end
        if State.buying_scan.stage == 'waiting_full_list_menu' and (id == 911 and title:find("Категории для поиска")) then
            State.buying_scan.stage = 'processing_page'
            local found_index = -1
            local lines = {}
            for line in text:gmatch("[^\r\n]+") do table.insert(lines, line) end
            for i, line in ipairs(lines) do if line:find("Весь список") then found_index = i - 1 break end end
            if found_index ~= -1 then sampSendDialogResponse(id, 1, found_index, "") else sampAddChatMessage('[RodinaMarket] {ff0000}Ошибка: Не найдена опция "Весь список" в категориях.', -1) stopBuyingScan() end
            App.tasks.add("wait_buy_items_dialog", function() if State.buying_scan.active and State.buying_scan.stage == 'processing_page' then stopBuyingScan() end end, 5000)
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
    
    if not Data.settings.ui_scale_mode then
        loadAllData() 
    end
    
    -- === ПРИМЕНЯЕМ МАСШТАБ ИЗ НАСТРОЕК ===
    local scale_mode = Data.settings.ui_scale_mode or 1
    CURRENT_SCALE = SCALE_MODES[scale_mode] or 1.0
    print("[RMarket] Применен масштаб: " .. tostring(CURRENT_SCALE) .. "x (режим " .. tostring(scale_mode) .. ")")
    
    local io = imgui.GetIO()
    io.Fonts:Clear()
    
    local font_config = imgui.ImFontConfig()
    font_config.MergeMode = false
    font_config.PixelSnapH = true
    
    local font_path = getFolderPath(0x14) .. '\\trebucbd.ttf'
    if not doesFileExist(font_path) then 
        font_path = getFolderPath(0x14) .. '\\arialbd.ttf' 
    end
    
    -- == БЕЗОПАСНЫЙ РАСЧЕТ РАЗМЕРА == --
    -- Базовый размер теперь зависит от масштаба
    local main_font_size = math.floor(18 * CURRENT_SCALE + 0.5)
    
    if main_font_size < 13 then main_font_size = 13 end -- Минимальный лимит
    if main_font_size > 60 then main_font_size = 60 end
    
    local font_main = io.Fonts:AddFontFromFileTTF(
        font_path, 
        main_font_size, 
        font_config, 
        io.Fonts:GetGlyphRangesCyrillic()
    )
    
    local icon_config = imgui.ImFontConfig()
    icon_config.MergeMode = true
    icon_config.PixelSnapH = true
    icon_config.GlyphOffset = imgui.ImVec2(0, math.floor(1 * CURRENT_SCALE + 0.5))
    
    font_fa = io.Fonts:AddFontFromMemoryCompressedBase85TTF(
        fa.get_font_data_base85('solid'), 
        main_font_size, 
        icon_config, 
        fa_glyph_ranges 
    )
    
    io.Fonts:Build()
    
    applyStrictStyle()
end)

function applyStrictStyle()
    local style = imgui.GetStyle()
    local colors = style.Colors
    
    -- Увеличиваем радиусы для мягкости
    style.WindowRounding = S(10)
    style.ChildRounding = S(8)
    style.FrameRounding = S(6)
    style.PopupRounding = S(8)
    style.ScrollbarRounding = S(6)
    style.TabRounding = S(6)
    
    -- == ВАЖНО: УВЕЛИЧЕННЫЕ ОТСТУПЫ ==
    style.WindowPadding = imgui.ImVec2(S(20), S(20)) 
    style.FramePadding = imgui.ImVec2(S(12), S(7))    
    style.ItemSpacing = imgui.ImVec2(S(12), S(10))     
    style.ItemInnerSpacing = imgui.ImVec2(S(8), S(6))
    
    style.ScrollbarSize = S(14)
    
    style.WindowBorderSize = 0
    style.ChildBorderSize = 0
    style.PopupBorderSize = 0
    style.FrameBorderSize = 0
    
    -- === ПРИМЕНЯЕМ ЦВЕТА С УЧЕТОМ ТЕКУЩЕЙ ТЕМЫ === --
    local bg_dark = imgui.ImVec4(CURRENT_THEME.bg_main.x, CURRENT_THEME.bg_main.y, CURRENT_THEME.bg_main.z, 0.98)
    local bg_medium = imgui.ImVec4(CURRENT_THEME.bg_secondary.x, CURRENT_THEME.bg_secondary.y, CURRENT_THEME.bg_secondary.z, 1.0)
    local bg_light = imgui.ImVec4(CURRENT_THEME.bg_tertiary.x, CURRENT_THEME.bg_tertiary.y, CURRENT_THEME.bg_tertiary.z, 1.0)
    local accent_primary = CURRENT_THEME.accent_primary
    local accent_hover = imgui.ImVec4(accent_primary.x * 1.2, accent_primary.y * 1.2, accent_primary.z, 1.0)
    local accent_active = imgui.ImVec4(accent_primary.x * 1.4, accent_primary.y * 1.4, accent_primary.z, 1.0)
    local text_primary = CURRENT_THEME.text_primary
    local text_disabled = CURRENT_THEME.text_hint
    
    -- Ограничиваем максимальные значения для accent цветов
    if accent_hover.x > 1.0 then accent_hover.x = 1.0 end
    if accent_hover.y > 1.0 then accent_hover.y = 1.0 end
    if accent_active.x > 1.0 then accent_active.x = 1.0 end
    if accent_active.y > 1.0 then accent_active.y = 1.0 end
    
    colors[imgui.Col.WindowBg] = bg_dark
    colors[imgui.Col.ChildBg] = bg_medium
    colors[imgui.Col.PopupBg] = bg_light
    colors[imgui.Col.Border] = CURRENT_THEME.border_light
    colors[imgui.Col.FrameBg] = bg_light
    colors[imgui.Col.FrameBgHovered] = imgui.ImVec4(CURRENT_THEME.bg_tertiary.x * 1.1, CURRENT_THEME.bg_tertiary.y * 1.1, CURRENT_THEME.bg_tertiary.z * 1.1, 1.0)
    colors[imgui.Col.FrameBgActive] = imgui.ImVec4(CURRENT_THEME.bg_tertiary.x * 1.2, CURRENT_THEME.bg_tertiary.y * 1.2, CURRENT_THEME.bg_tertiary.z * 1.2, 1.0)
    
    -- === КНОПКИ ===
    colors[imgui.Col.Button] = accent_primary
    colors[imgui.Col.ButtonHovered] = accent_hover
    colors[imgui.Col.ButtonActive] = accent_active
    
    -- === ВЫБОР И ЗАГОЛОВКИ ===
    colors[imgui.Col.Header] = imgui.ImVec4(accent_primary.x, accent_primary.y, accent_primary.z, 0.3)
    colors[imgui.Col.HeaderHovered] = imgui.ImVec4(accent_primary.x, accent_primary.y, accent_primary.z, 0.5)
    colors[imgui.Col.HeaderActive] = imgui.ImVec4(accent_primary.x, accent_primary.y, accent_primary.z, 0.8)
    
    -- === ТЕКСТ ===
    colors[imgui.Col.Text] = text_primary
    colors[imgui.Col.TextDisabled] = text_disabled
    colors[imgui.Col.TextSelectedBg] = imgui.ImVec4(accent_primary.x, accent_primary.y, accent_primary.z, 0.3)
    
    -- === ЧЕКБОКСЫ И РАДИОКНОПКИ ===
    colors[imgui.Col.CheckMark] = accent_primary
    
    -- === СЛАЙДЕРЫ ===
    colors[imgui.Col.SliderGrab] = accent_primary
    colors[imgui.Col.SliderGrabActive] = accent_active
    
    -- === ТАБЫ ===
    colors[imgui.Col.Tab] = bg_light
    colors[imgui.Col.TabHovered] = imgui.ImVec4(bg_light.x * 1.1, bg_light.y * 1.1, bg_light.z * 1.1, 1.0)
    colors[imgui.Col.TabActive] = bg_medium
    colors[imgui.Col.TabUnfocused] = bg_light
    colors[imgui.Col.TabUnfocusedActive] = bg_medium
    
    -- === СКРОЛЛБАР ===
    colors[imgui.Col.ScrollbarBg] = imgui.ImVec4(CURRENT_THEME.bg_main.x, CURRENT_THEME.bg_main.y, CURRENT_THEME.bg_main.z, 0.2)
    colors[imgui.Col.ScrollbarGrab] = CURRENT_THEME.bg_tertiary
    colors[imgui.Col.ScrollbarGrabHovered] = imgui.ImVec4(CURRENT_THEME.bg_tertiary.x * 1.2, CURRENT_THEME.bg_tertiary.y * 1.2, CURRENT_THEME.bg_tertiary.z * 1.2, 1.0)
    colors[imgui.Col.ScrollbarGrabActive] = accent_primary
    
    -- === РАЗДЕЛИТЕЛИ ===
    colors[imgui.Col.Separator] = CURRENT_THEME.border_light
    colors[imgui.Col.SeparatorHovered] = accent_primary
    colors[imgui.Col.SeparatorActive] = accent_active
    
    -- === ОСТАЛЬНЫЕ ЭЛЕМЕНТЫ ===
    colors[imgui.Col.TitleBg] = CURRENT_THEME.bg_main
    colors[imgui.Col.TitleBgActive] = CURRENT_THEME.bg_secondary
    colors[imgui.Col.MenuBarBg] = CURRENT_THEME.bg_secondary
    colors[imgui.Col.ModalWindowDimBg] = imgui.ImVec4(0.00, 0.00, 0.00, 0.60)
    
    -- === COMBO, PLOT, TABLE ===
    colors[imgui.Col.PlotLines] = accent_primary
    colors[imgui.Col.PlotLinesHovered] = accent_hover
    colors[imgui.Col.PlotHistogram] = accent_secondary or accent_primary
    colors[imgui.Col.PlotHistogramHovered] = accent_hover
    
    -- === RESIZER И ДРУГИЕ ИНТЕРАКТИВНЫЕ ЭЛЕМЕНТЫ ===
    colors[imgui.Col.ResizeGrip] = imgui.ImVec4(accent_primary.x, accent_primary.y, accent_primary.z, 0.5)
    colors[imgui.Col.ResizeGripHovered] = imgui.ImVec4(accent_primary.x, accent_primary.y, accent_primary.z, 0.7)
    colors[imgui.Col.ResizeGripActive] = accent_hover
    
    -- === DRAG AND DROP ===
    colors[imgui.Col.DragDropTarget] = imgui.ImVec4(accent_primary.x, accent_primary.y, accent_primary.z, 0.9)
end

-- === ИСПРАВЛЕННАЯ ФУНКЦИЯ ИНПУТОВ === --
function renderUnifiedHeader(text, icon)
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    
    -- Небольшой отступ сверху
    imgui.Dummy(imgui.ImVec2(0, S(2)))
    
    -- Иконка (если есть) и текст
    if icon then
        imgui.TextColored(CURRENT_THEME.accent_secondary, icon)
        imgui.SameLine()
    end
    
    imgui.TextColored(CURRENT_THEME.accent_secondary, text)
    
    -- Линия-разделитель
    imgui.Separator()
    imgui.Spacing()
end

-- Исправленная функция ввода (Белый текст + Modern Style)
function renderModernInput(label_id, buffer, width, hint)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    local height = S(32)
    local rounding = S(6)
    
    -- 1. РАЗДЕЛЯЕМ ОТРИСОВКУ НА 2 СЛОЯ
    -- Слой 0: Фон (рисуется первым)
    -- Слой 1: Текст и Инпут (рисуется поверх фона)
    draw_list:ChannelsSplit(2)
    
    -- === ПЕРЕКЛЮЧАЕМСЯ НА СЛОЙ 1 (ПЕРЕДНИЙ) ДЛЯ ИНПУТА ===
    draw_list:ChannelsSetCurrent(1)
    
    imgui.SetNextItemWidth(width)
    
    -- Делаем стандартный фон полностью прозрачным, чтобы видеть наш кастомный фон со слоя 0
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.FrameBgActive, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0,0,0,0))
    
    -- ТЕКСТ: Белый (0.95), чтобы его было видно на темном фоне
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.95, 0.95, 0.95, 1.0))
    
    -- Центрирование текста
    local text_padding_y = (height - imgui.GetTextLineHeight()) / 2
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(S(8), text_padding_y))
    
    -- Рисуем сам инпут (Текст появится на слое 1)
    local changed = imgui.InputText(label_id, buffer, 64)
    
    local is_active = imgui.IsItemActive()
    local is_hovered = imgui.IsItemHovered()
    
    imgui.PopStyleVar()
    imgui.PopStyleColor(5)
    
    -- === ПЕРЕКЛЮЧАЕМСЯ НА СЛОЙ 0 (ЗАДНИЙ) ДЛЯ ФОНА ===
    draw_list:ChannelsSetCurrent(0)
    
    -- Цвета фона
    local bg_color_u32 = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.08, 0.08, 0.10, 1.0))
    if is_hovered then bg_color_u32 = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.12, 0.12, 0.15, 1.0)) end
    if is_active then bg_color_u32 = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.15, 0.15, 0.18, 1.0)) end

    -- Рисуем прямоугольник фона (теперь он точно ПОД текстом)
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), bg_color_u32, rounding)
    
    -- Обводка
    local border_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.1))
    if is_active then 
        border_col = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary)
    elseif is_hovered then
        border_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.3))
    end
    
    draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), border_col, rounding, 15, is_active and S(1.5) or S(1.0))
    
    -- Подсказка (Hint)
    -- Рисуем на слое 0, чтобы курсор ввода перекрывал подсказку, если нужно
    if ffi.string(buffer) == "" and not is_active and hint then
        draw_list:AddText(imgui.ImVec2(p.x + S(8), p.y + text_padding_y), 
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.6, 0.6, 0.6, 1.0)), u8(hint))
    end
    
    -- 2. ОБЪЕДИНЯЕМ СЛОИ ОБРАТНО
    draw_list:ChannelsMerge()
    
    return changed
end

function renderSellItem(index, item)
    local draw_list = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local avail_width = imgui.GetContentRegionAvail().x
    local height = S(50)

    local item_uid = tostring(item)
    imgui.PushIDInt(stringToID("sell_item_" .. item_uid))

    if item.active == nil then item.active = true end

    -- Буферы
    local buf_key_price  = "sp_" .. item_uid
    local buf_key_amount = "sa_" .. item_uid
    local buf_key_active = "sactive_" .. item_uid

    if not Buffers.sell_input_buffers[buf_key_price] then Buffers.sell_input_buffers[buf_key_price] = imgui.new.char[32](tostring(item.price or 1000)) end
    if not Buffers.sell_input_buffers[buf_key_amount] then Buffers.sell_input_buffers[buf_key_amount] = imgui.new.char[32](tostring(item.amount or 1)) end
    if not Buffers.sell_input_buffers[buf_key_active] then Buffers.sell_input_buffers[buf_key_active] = imgui.new.bool(item.active ~= false) end

    local is_active = Buffers.sell_input_buffers[buf_key_active][0]

    -- 1. Фон карточки
    local bg_col_vec = (index % 2 == 0) and CURRENT_THEME.bg_secondary or CURRENT_THEME.bg_tertiary
    if not is_active then bg_col_vec = imgui.ImVec4(bg_col_vec.x, bg_col_vec.y, bg_col_vec.z, 0.5) end
    if item.missing then bg_col_vec = imgui.ImVec4(0.3, 0.1, 0.1, 0.3) end 

    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + avail_width, p.y + height), imgui.ColorConvertFloat4ToU32(bg_col_vec), S(8))
    
    -- Активная полоска слева
    if is_active and not item.missing then
        draw_list:AddRectFilled(p, imgui.ImVec2(p.x + S(4), p.y + height), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_success), S(8), 5)
    end

    local cy = p.y + height / 2

    -- == ПРАВАЯ ЧАСТЬ (РАСЧЕТ МЕСТА) == --
    local btn_w = S(28)
    local input_p_w = S(115) -- УВЕЛИЧИЛ ШИРИНУ ЦЕНЫ (БЫЛО 85)
    local input_a_w = S(45)  -- Немного уменьшил кол-во
    local gap = S(6)         -- Уменьшил отступы
    local right_margin = S(10)
    
    -- Считаем координаты справа налево
    local x_del = p.x + avail_width - right_margin - btn_w
    local x_play = x_del - gap - btn_w
    local x_eye = x_play - gap - btn_w
    
    local x_input_p = x_eye - gap - input_p_w - S(20) -- Поле цены
    local x_ruble = x_input_p + input_p_w + S(4)      -- Знак рубля справа от цены
    
    local x_input_a = x_input_p - gap - input_a_w - S(20) -- Поле количества
    local x_sht = x_input_a + input_a_w + S(4)            -- Текст "шт"

    -- 2. Название (Слева) занимает все оставшееся место до инпутов
    local max_name_w = x_input_a - p.x - S(20)
    
    -- Клиппинг текста названия, чтобы не налезал на инпуты
    imgui.PushClipRect(imgui.ImVec2(p.x, p.y), imgui.ImVec2(p.x + max_name_w, p.y + height), true)
    
    local display_name = u8(index .. ". " .. item.name)
    local text_col = (is_active and not item.missing) and CURRENT_THEME.text_primary or CURRENT_THEME.text_secondary
    
    local name_size = imgui.CalcTextSize(display_name)
    draw_list:AddText(imgui.ImVec2(p.x + S(15), cy - name_size.y/2), imgui.ColorConvertFloat4ToU32(text_col), display_name)
    imgui.PopClipRect()

    -- Клик по названию
    imgui.SetCursorScreenPos(p)
    if imgui.InvisibleButton("##name_clk", imgui.ImVec2(max_name_w, height)) then
        local avg = getAveragePriceForItem(item)
        if avg then
            item.price = avg
            Buffers.sell_input_buffers[buf_key_price] = imgui.new.char[32](tostring(avg))
            saveListsConfig()
            calculateSellTotal()
        end
    end
    if imgui.IsItemHovered() then
        local avg = getAveragePriceForItem(item)
        imgui.SetTooltip(avg and u8("Средняя цена: " .. formatMoney(avg)) or u8("Нет данных о цене"))
    end

    -- 3. Элементы управления
    
    -- А) Кнопка Удалить
    imgui.SetCursorScreenPos(imgui.ImVec2(x_del, cy - btn_w/2))
    if imgui.InvisibleButton("##del", imgui.ImVec2(btn_w, btn_w)) then
        table.remove(Data.sell_list, index)
        saveListsConfig()
        calculateSellTotal()
    end
    local del_col = imgui.IsItemHovered() and 0xFF4D4DFF or 0xFF666666
    if font_fa then 
        imgui.PushFont(font_fa)
        local isz = imgui.CalcTextSize(fa('trash'))
        draw_list:AddText(imgui.ImVec2(x_del + (btn_w-isz.x)/2, cy - isz.y/2), del_col, fa('trash'))
        imgui.PopFont()
    end

    -- Б) Кнопка Play
    imgui.SetCursorScreenPos(imgui.ImVec2(x_play, cy - btn_w/2))
    if imgui.InvisibleButton("##play", imgui.ImVec2(btn_w, btn_w)) then if is_active then startSingleItemSelling(item) end end
    local play_col = is_active and (imgui.IsItemHovered() and 0xFFFFFFFF or 0xFFBBBBBB) or 0x50FFFFFF
    if font_fa then 
        imgui.PushFont(font_fa)
        local isz = imgui.CalcTextSize(fa('play'))
        draw_list:AddText(imgui.ImVec2(x_play + (btn_w-isz.x)/2, cy - isz.y/2), play_col, fa('play'))
        imgui.PopFont()
    end

    -- В) Кнопка Глаз
    imgui.SetCursorScreenPos(imgui.ImVec2(x_eye, cy - btn_w/2))
    if imgui.InvisibleButton("##eye", imgui.ImVec2(btn_w, btn_w)) then
        Buffers.sell_input_buffers[buf_key_active][0] = not is_active
        item.active = Buffers.sell_input_buffers[buf_key_active][0]
        saveListsConfig()
        calculateSellTotal()
        api_SendMyData()
    end
    local eye_icon = is_active and fa('eye') or fa('eye_slash')
    local eye_col = is_active and 0xFFFFFFFF or 0xFF666666
    if font_fa then 
        imgui.PushFont(font_fa)
        local isz = imgui.CalcTextSize(eye_icon)
        draw_list:AddText(imgui.ImVec2(x_eye + (btn_w-isz.x)/2, cy - isz.y/2), eye_col, eye_icon)
        imgui.PopFont()
    end

    -- Г) Инпут Цены
    imgui.SetCursorScreenPos(imgui.ImVec2(x_input_p, cy - S(16)))
    if renderModernInput("##sp"..item_uid, Buffers.sell_input_buffers[buf_key_price], input_p_w, "Цена") then
        item.price = tonumber(ffi.string(Buffers.sell_input_buffers[buf_key_price])) or 0
        calculateSellTotal()
    end
    if imgui.IsItemDeactivatedAfterEdit() then saveListsConfig() end
    
    if font_fa then
        imgui.PushFont(font_fa)
        draw_list:AddText(imgui.ImVec2(x_ruble, cy - S(7)), 0xFF808080, fa('ruble_sign'))
        imgui.PopFont()
    end

    -- Д) Инпут Количества
    imgui.SetCursorScreenPos(imgui.ImVec2(x_input_a, cy - S(16)))
    if renderModernInput("##sa"..item_uid, Buffers.sell_input_buffers[buf_key_amount], input_a_w, "Шт") then
        item.amount = tonumber(ffi.string(Buffers.sell_input_buffers[buf_key_amount])) or 1
        calculateSellTotal()
    end
    if imgui.IsItemDeactivatedAfterEdit() then saveListsConfig() end
    
    draw_list:AddText(imgui.ImVec2(x_sht, cy - S(7)), 0xFF808080, u8("шт"))

    imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + height + S(4)))
    imgui.PopID()
end

-- Кэш для средних цен товаров
local average_price_cache = setmetatable({}, {__mode = 'v'})

function getAveragePriceForItem(item)
    -- Используем item.model_id как ключ кэша если есть
    local cache_key = item.model_id or item.name
    
    -- Проверяем кэш
    if average_price_cache[cache_key] then
        return average_price_cache[cache_key]
    end
    
    local clean_item_name = cleanItemName(item.name)
    clean_item_name = clean_item_name:gsub("%s*%(%d+%)$", ""):gsub("%s*%[x%d+%]$", "")
    local original_name = item.original_name and cleanItemName(item.original_name) or clean_item_name
    original_name = original_name:gsub("%s*%(%d+%)$", ""):gsub("%s*%[x%d+%]$", "")
        
    local result = nil
    for avg_name, data in pairs(Data.average_prices) do
        local clean_avg_name = cleanItemName(avg_name)
        clean_avg_name = clean_avg_name:gsub("^Предмет%s+", "")
            
        if clean_avg_name == clean_item_name or 
            clean_avg_name == original_name or
            clean_item_name:find(clean_avg_name, 1, true) or
            clean_avg_name:find(clean_item_name, 1, true) then
            result = data.price
            break
        end
    end
    
    -- Кэшируем результат
    average_price_cache[cache_key] = result
    return result
end

function enhancedCleanItemName(name)
    if not name then return "" end
    name = name:gsub("{......}", "")
    name = name:gsub("%[.*%]", "")
    name = name:gsub("%s*%(%s*x?%s*%d+%s*%)", "")
    name = name:gsub("^%s*(.-)%s*$", "%1")
    return name
end

function cleanItemName(name)
    if not name then return "" end
    return enhancedCleanItemName(name)
end

function stringToID(str)
    local hash = 0
    for i = 1, #str do hash = (hash * 31 + str:byte(i)) % 2147483647 end
    return hash
end

function renderBuyItem(index, item)
    local draw_list = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local avail_width = imgui.GetContentRegionAvail().x
    local height = S(50)

    local item_uid = tostring(item)
    imgui.PushIDInt(stringToID("buy_item_" .. item_uid))

    if item.active == nil then item.active = true end
    
    local buf_key_price = "bp_" .. item_uid
    local buf_key_amount = "ba_" .. item_uid
    local buf_key_active = "bactive_" .. item_uid
    
    if not Buffers.buy_input_buffers[buf_key_price] then Buffers.buy_input_buffers[buf_key_price] = imgui.new.char[32](tostring(item.price or 100)) end
    if not Buffers.buy_input_buffers[buf_key_amount] then Buffers.buy_input_buffers[buf_key_amount] = imgui.new.char[32](tostring(item.amount or 1)) end
    if not Buffers.buy_input_buffers[buf_key_active] then Buffers.buy_input_buffers[buf_key_active] = imgui.new.bool(item.active ~= false) end

    local is_active = Buffers.buy_input_buffers[buf_key_active][0]
    local is_acc = isAccessory(item.name)

    -- Фон
    local bg_col_vec = (index % 2 == 0) and CURRENT_THEME.bg_secondary or CURRENT_THEME.bg_tertiary
    if not is_active then bg_col_vec = imgui.ImVec4(bg_col_vec.x, bg_col_vec.y, bg_col_vec.z, 0.5) end

    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + avail_width, p.y + height), imgui.ColorConvertFloat4ToU32(bg_col_vec), S(8))
    
    if is_active then
        draw_list:AddRectFilled(p, imgui.ImVec2(p.x + S(4), p.y + height), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_secondary), S(8), 5)
    end

    local cy = p.y + height / 2

    -- == ПРАВАЯ ЧАСТЬ == --
    local btn_w = S(28)
    local input_p_w = S(115) -- УВЕЛИЧИЛ
    local input_a_w = S(45)
    local gap = S(6)
    local right_margin = S(10)

    local x_del = p.x + avail_width - right_margin - btn_w
    local x_play = x_del - gap - btn_w
    local x_eye = x_play - gap - btn_w
    
    local x_input_p = x_eye - gap - input_p_w - S(20)
    local x_ruble = x_input_p + input_p_w + S(4)
    
    local x_input_a = x_input_p - gap - input_a_w - S(20)
    local x_sht = x_input_a + input_a_w + S(4)

    -- Название (Слева)
    local max_name_w = x_input_a - p.x - S(20)
    imgui.PushClipRect(imgui.ImVec2(p.x, p.y), imgui.ImVec2(p.x + max_name_w, p.y + height), true)
    
    local display_name = u8(index .. ". " .. item.name)
    local text_col = is_active and CURRENT_THEME.text_primary or CURRENT_THEME.text_secondary
    local nm_sz = imgui.CalcTextSize(display_name)
    draw_list:AddText(imgui.ImVec2(p.x + S(15), cy - nm_sz.y/2), imgui.ColorConvertFloat4ToU32(text_col), display_name)
    imgui.PopClipRect()

    -- Кнопки
    imgui.SetCursorScreenPos(imgui.ImVec2(x_del, cy - btn_w/2))
    if imgui.InvisibleButton("##del", imgui.ImVec2(btn_w, btn_w)) then
        table.remove(Data.buy_list, index)
        saveListsConfig()
        calculateBuyTotal()
    end
    local del_col = imgui.IsItemHovered() and 0xFF4D4DFF or 0xFF666666
    if font_fa then 
        imgui.PushFont(font_fa)
        local isz = imgui.CalcTextSize(fa('trash'))
        draw_list:AddText(imgui.ImVec2(x_del + (btn_w-isz.x)/2, cy - isz.y/2), del_col, fa('trash'))
        imgui.PopFont() 
    end
    
    imgui.SetCursorScreenPos(imgui.ImVec2(x_play, cy - btn_w/2))
    if imgui.InvisibleButton("##sng", imgui.ImVec2(btn_w, btn_w)) then
        if is_active then startSingleItemBuying(item) end
    end
    local play_col = is_active and (imgui.IsItemHovered() and 0xFFFFFFFF or 0xFFBBBBBB) or 0x50FFFFFF
    if font_fa then 
        imgui.PushFont(font_fa)
        local isz = imgui.CalcTextSize(fa('play'))
        draw_list:AddText(imgui.ImVec2(x_play + (btn_w-isz.x)/2, cy - isz.y/2), play_col, fa('play'))
        imgui.PopFont() 
    end

    imgui.SetCursorScreenPos(imgui.ImVec2(x_eye, cy - btn_w/2))
    if imgui.InvisibleButton("##eye", imgui.ImVec2(btn_w, btn_w)) then
        Buffers.buy_input_buffers[buf_key_active][0] = not is_active
        item.active = Buffers.buy_input_buffers[buf_key_active][0]
        saveListsConfig()
        calculateBuyTotal()
        api_SendMyData()
    end
    local eye_icon = is_active and fa('eye') or fa('eye_slash')
    local eye_col = is_active and 0xFFFFFFFF or 0xFF666666
    if font_fa then 
        imgui.PushFont(font_fa)
        local isz = imgui.CalcTextSize(eye_icon)
        draw_list:AddText(imgui.ImVec2(x_eye + (btn_w-isz.x)/2, cy - isz.y/2), eye_col, eye_icon)
        imgui.PopFont() 
    end

    -- Инпуты
    imgui.SetCursorScreenPos(imgui.ImVec2(x_input_p, cy - S(16)))
    if renderModernInput("##bp"..item_uid, Buffers.buy_input_buffers[buf_key_price], input_p_w, "Цена") then
        item.price = tonumber(ffi.string(Buffers.buy_input_buffers[buf_key_price])) or 0
        calculateBuyTotal()
    end
    if imgui.IsItemDeactivatedAfterEdit() then saveListsConfig() end
    if font_fa then
        imgui.PushFont(font_fa)
        draw_list:AddText(imgui.ImVec2(x_ruble, cy - S(7)), 0xFF808080, fa('ruble_sign'))
        imgui.PopFont()
    end

    imgui.SetCursorScreenPos(imgui.ImVec2(x_input_a, cy - S(16)))
    if renderModernInput("##ba"..item_uid, Buffers.buy_input_buffers[buf_key_amount], input_a_w, is_acc and "Color" or "Шт") then
        item.amount = tonumber(ffi.string(Buffers.buy_input_buffers[buf_key_amount])) or 0
        calculateBuyTotal()
    end
    if imgui.IsItemDeactivatedAfterEdit() then saveListsConfig() end
    
    local label_q = is_acc and "col" or "шт"
    draw_list:AddText(imgui.ImVec2(x_sht, cy - S(7)), 0xFF808080, u8(label_q))
    
    if is_acc and imgui.IsMouseHoveringRect(imgui.ImVec2(x_input_a, cy - 10), imgui.ImVec2(x_input_a + input_a_w, cy + 10)) then
        imgui.BeginTooltip()
        imgui.Text(u8(color_tooltip_text))
        imgui.EndTooltip()
    end

    imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + height + S(4)))
    imgui.PopID()
end

function startSingleItemSelling(item)
    if App.is_scanning or App.is_selling_cef or App.is_scanning_buy or State.buying.active then return end
    
    if item.active == false then
        sampAddChatMessage('[RodinaMarket] {ff0000}Товар отключен!', -1)
        return
    end
    
    -- Создаём временный список с одним товаром
    local single_item_list = {item}
    
    App.is_selling_cef = true
    App.current_sell_item_index = 0
    Data.cef_slots_data = {}
    Data.cef_sell_queue = {}
    
    sampAddChatMessage('[RodinaMarket] {ffff00}Начинаю выставление товара: ' .. item.name, -1)
    
    App.tasks.add("cef_sell_single_press_alt", function()
        setVirtualKeyDown(0x12, true)
        App.tasks.add("cef_sell_single_release_alt", function()
            setVirtualKeyDown(0x12, false)
        end, 50)
    end, 1000)
    
    -- Подготавливаем очередь для одного товара
    App.tasks.add("cef_sell_single_prepare", function()
        if App.is_selling_cef then
            -- Готовим очередь с одним товаром
            Data.cef_sell_queue = {}
            local used_slots = {}
            local target_model = tonumber(item.model_id)
            local found_slot = nil
            
            for slot, item_data in pairs(Data.cef_slots_data) do
                if item_data.model_id == target_model and not used_slots[slot] then
                    found_slot = slot
                    used_slots[slot] = true
                    break
                end
            end
            
            if found_slot then
                table.insert(Data.cef_sell_queue, {
                    slot = found_slot,
                    model = target_model,
                    amount = item.amount,
                    price = item.price,
                    name = item.name,
                    retry_count = 0
                })
                processNextCEFSellItem()
            else
                sampAddChatMessage('[RodinaMarket] {ff0000}Товар не найден в инвентаре!', -1)
                App.is_selling_cef = false
                sendCEF("inventoryClose")
            end
        end
    end, 2000)
    
    App.tasks.add("cef_sell_single_timeout", function()
        if App.is_selling_cef then
            stopSelling()
        end
    end, 15000)
end

function startSingleItemBuying(item)
    if App.is_scanning or App.is_selling_cef or App.is_scanning_buy or State.buying.active then return end
    
    if item.active == false then
        sampAddChatMessage('[RodinaMarket] {ff0000}Товар отключен!', -1)
        return
    end
    
    State.buying = {
        active = true, 
        stage = 'waiting_dialog', 
        items_to_buy = {item}, 
        last_search_name = nil
    }
    
    sampAddChatMessage('[RodinaMarket] {ffff00}Начинаю скупку товара: ' .. item.name, -1)
    
    App.tasks.add("buy_press_alt", function()
        setVirtualKeyDown(0x12, true)
        App.tasks.add("buy_release_alt", function() 
            setVirtualKeyDown(0x12, false) 
        end, 50)
    end, 1000)
    
    App.tasks.add("wait_buy_dialog", function()
        if State.buying.active and State.buying.stage == 'waiting_dialog' then 
            stopBuying() 
        end
    end, 3000)
end

function recalculateInventoryTotals()
    Data.inventory_item_amounts = {}
    for slot, data in pairs(Data.cef_slots_data) do
        if data.model_id and data.amount then
            local s_id = tostring(data.model_id)
            Data.inventory_item_amounts[s_id] = (Data.inventory_item_amounts[s_id] or 0) + data.amount
        end
    end
end

function parseCEFInventory(str)
    -- Очистка строки от мусора (обратные кавычки и пробелы)
    str = str:gsub("`", ""):gsub("^%s+", ""):gsub("%s+$", "")
    
    local json_start = str:find("%[")
    if not json_start then
        local match = str:match("event%.inventory%.playerInventory.*%[")
        if match then json_start = str:find("%[", #match) end
    end
    if not json_start then return end
    
    -- Проверка на режим "только цена" (для выставления товара)
    if str:find("Введите цену за один товар") then
        App.cef_price_only = true
    else
        App.cef_price_only = false
    end
    
    -- Извлечение JSON
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
    
    local needs_recalc = false

    for _, event_data in ipairs(data) do
        local action = event_data.action -- 0 = Полная загрузка, 2 = Обновление UI
        local inv_type = event_data.data and event_data.data.type
        
        -- === ОБРАБОТКА ЧУЖОЙ ЛАВКИ (TYPE 9) ===
        if inv_type == 9 then
            if action == 0 and event_data.data.items then
                App.remote_shop_active = true
                for _, item in ipairs(event_data.data.items) do
                    if item.available == 1 and item.item then
                        local model_id = item.item
                        local item_name = Data.item_names[tostring(model_id)] or ("Item_" .. model_id)
                        
                        local found_idx = -1
                        for idx, existing in ipairs(Data.remote_shop_items) do
                            if existing.slot == item.slot then found_idx = idx break end
                        end
                        
                        local new_entry = {
                            name = item_name,
                            model_id = model_id,
                            slot = item.slot,
                            amount = item.amount or 1,
                            price_text = item.text or "???"
                        }
                        
                        if found_idx ~= -1 then Data.remote_shop_items[found_idx] = new_entry
                        else table.insert(Data.remote_shop_items, new_entry) end
                    end
                end
                table.sort(Data.remote_shop_items, function(a, b) return a.slot < b.slot end)
            end
        end

        -- === ОБРАБОТКА СВОЕГО ИНВЕНТАРЯ (TYPE 1) ===
        if inv_type == 1 and event_data.data.items then
            -- Action 0: Полная синхронизация (обычно при входе). Стираем старое, верим новому.
            if action == 0 then
                Data.cef_slots_data = {}
                Data.inventory_item_amounts = {}
                needs_recalc = true
            end

            for _, item in ipairs(event_data.data.items) do
                local slot = item.slot
                
                -- Если слот помечен как недоступный (пустой), удаляем его из памяти
                if item.available == 0 then
                    if Data.cef_slots_data[slot] then
                        Data.cef_slots_data[slot] = nil
                        needs_recalc = true
                    end
                
                -- Если в слоте есть предмет
                elseif item.item then
                    local model_id = item.item
                    local incoming_amount = item.amount -- Может быть nil в Action 2
                    
                    local final_amount = 1
                    
                    -- == ЛОГИКА ОПРЕДЕЛЕНИЯ КОЛИЧЕСТВА ==
                    
                    if incoming_amount then
                        -- 1. Если сервер явно прислал количество (обычно Action 0), используем его.
                        final_amount = incoming_amount
                    else
                        -- 2. Если сервер НЕ прислал количество (обычно Action 2), 
                        -- пытаемся найти данные в памяти.
                        if Data.cef_slots_data[slot] and Data.cef_slots_data[slot].model_id == model_id then
                            -- Если в этом слоте лежал ТОТ ЖЕ предмет, сохраняем СТАРОЕ количество.
                            final_amount = Data.cef_slots_data[slot].amount
                        else
                            -- Если мы не знаем этот слот или предмет изменился, а количества нет — ставим 1.
                            final_amount = 1
                        end
                    end
                    
                    -- Обновляем данные слота
                    Data.cef_slots_data[slot] = {
                        model_id = model_id,
                        slot = slot,
                        amount = final_amount
                    }
                    needs_recalc = true

                    -- Обновляем список для CEF инвентаря (визуальный список для сканера)
                    local item_name_str = Data.item_names[tostring(model_id)]
                    if item_name_str then
                        local found = false
                        for k, v in ipairs(Data.cef_inventory_items) do
                            if v.slot == slot then
                                Data.cef_inventory_items[k] = {
                                    name = item_name_str, 
                                    model_id = model_id, 
                                    slot = slot,
                                    amount = final_amount
                                }
                                found = true
                                break
                            end
                        end
                        if not found then
                            table.insert(Data.cef_inventory_items, {
                                name = item_name_str, 
                                model_id = model_id, 
                                slot = slot,
                                amount = final_amount
                            })
                        end
                    end
                end
            end
        end
    end
    
    -- Пересчитываем общие суммы только если данные реально менялись
    if needs_recalc then
        recalculateInventoryTotals()
    end
end

function getTotalInventoryAmount(model_id)
    if not model_id then return 0 end
    
    -- Пробуем получить из таблицы с суммами
    local total = Data.inventory_item_amounts[tostring(model_id)] or 0
    
    -- Если в таблице нет, пробуем посчитать по слотам
    if total == 0 then
        for _, slot_data in pairs(Data.cef_slots_data) do
            if tostring(slot_data.model_id) == tostring(model_id) then
                total = total + (tonumber(slot_data.amount) or 1)
            end
        end
    end
    
    return total
end

local header_particles = {}
local particle_icons = {
    fa('fire'), fa('star'), fa('circle'), fa('ghost'), fa('bolt'), fa('heart'), fa('clover')
}

-- Глобальный таймер для анимации шапки
local header_animation_time = 0.0

local function create_particle(window_width, header_height)
    local particle_type = math.random(1, 3)
    local particle = {
        x = math.random(0, window_width),
        y = header_height + math.random(10, 30), 
        speed = math.random(15, 40) / 10,
        sin_offset = math.random(0, 360),
        size = math.random(10, 18),
        rotation = math.random(0, 360) / 57.29,
        rot_speed = (math.random() - 0.5) * 3.0,
        opacity = 0.0,
        color = imgui.ImVec4(
            0.4 + (math.random() * 0.15),
            0.25 + (math.random() * 0.15),
            0.95 + (math.random() * 0.05),
            0.0
        ),
        icon = particle_icons[math.random(1, #particle_icons)],
        particle_type = particle_type, -- 1 = иконка, 2 = линия, 3 = точка
        lifetime = 0.0,
        max_lifetime = math.random(20, 40) / 10
    }
    return particle
end

function renderCustomHeader()
    header_animation_time = header_animation_time + imgui.GetIO().DeltaTime
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetWindowWidth()
    local h = S(90) 
    local draw_list = imgui.GetWindowDrawList()
    
    -- 1. Фон и частицы
    draw_list:AddRectFilledMultiColor(
        p, imgui.ImVec2(p.x + w, p.y + h),
        imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_main),
        imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary),
        imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_main),
        imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary)
    )

    imgui.PushClipRect(p, imgui.ImVec2(p.x + w, p.y + h), true)
    local delta_time = imgui.GetIO().DeltaTime
    
    if #header_particles < 15 then 
        table.insert(header_particles, create_particle(w, h)) 
    end

    for i = #header_particles, 1, -1 do
        local part = header_particles[i]
        part.lifetime = part.lifetime + delta_time
        
        part.y = part.y - part.speed
        part.sin_offset = part.sin_offset + delta_time * 2.5
        part.rotation = part.rotation + (part.rot_speed * delta_time)
        local x_swing = math.sin(part.sin_offset) * (12 + math.sin(header_animation_time) * 2)
        
        -- Плавное появление и исчезновение
        if part.y > h * 0.5 then 
            part.opacity = math.min(0.6, part.opacity + delta_time * 1.2)
        else 
            part.opacity = math.max(0.0, part.opacity - delta_time * 1.5) 
        end

        local draw_pos = imgui.ImVec2(p.x + part.x + x_swing, p.y + part.y)
        local glow_strength = 0.6 + math.sin(header_animation_time * 2) * 0.2
        local glow_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(part.color.x, part.color.y, part.color.z, part.opacity * glow_strength * 0.4))
        
        if font_fa then
            imgui.PushFont(font_fa)
            draw_list:AddText(imgui.ImVec2(draw_pos.x + 2, draw_pos.y + 2), glow_col, part.icon)
            draw_list:AddText(imgui.ImVec2(draw_pos.x + 1, draw_pos.y + 1), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(part.color.x, part.color.y, part.color.z, part.opacity * 0.3)), part.icon)
            local main_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(part.color.x, part.color.y, part.color.z, part.opacity))
            draw_list:AddText(draw_pos, main_col, part.icon)
            imgui.PopFont()
        end

        if part.y < -30 or (part.opacity <= 0 and part.y < h * 0.5) then table.remove(header_particles, i) end
    end
    imgui.PopClipRect()
    
    -- 2. Логотип и Название
    local text_y = p.y + (h - imgui.GetFontSize()) * 0.5
    
    local store_icon_glow = 0.4 + (math.sin(header_animation_time * 2.5) * 0.15)
    local store_icon_color = imgui.ImVec4(0.4, 0.25, 0.95, store_icon_glow + 0.5)
    
    if font_fa then imgui.PushFont(font_fa) end
    draw_list:AddText(imgui.ImVec2(p.x + S(20) - 1, text_y - 1), 
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.4, 0.25, 0.95, store_icon_glow * 0.4)), 
        fa('store'))
    draw_list:AddText(imgui.ImVec2(p.x + S(20), text_y), 
        imgui.ColorConvertFloat4ToU32(store_icon_color), 
        fa('store'))
    if font_fa then imgui.PopFont() end
    
    local name_glow = 0.8 + math.sin(header_animation_time * 1.5) * 0.2
    draw_list:AddText(imgui.ImVec2(p.x + S(50), text_y), 
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(CURRENT_THEME.text_primary.x, CURRENT_THEME.text_primary.y, CURRENT_THEME.text_primary.z, name_glow)), 
        "RODINA MARKET")

    -- 3. СОЦИАЛЬНЫЕ СЕТИ (возвращаем из старой версии)
    local title_width = imgui.CalcTextSize("RODINA MARKET").x
    local social_x = p.x + S(50) + title_width + S(20)
    local social_icon_size = S(20)
    
    local drawSocialIcon = function(id, icon, x, y, color, url, tooltip)
        imgui.SetCursorScreenPos(imgui.ImVec2(x, y - S(2)))
        if imgui.InvisibleButton(id, imgui.ImVec2(social_icon_size, social_icon_size)) then
            os.execute("explorer " .. url)
        end
        local is_hovered = imgui.IsItemHovered()
        local final_color = is_hovered and CURRENT_THEME.text_primary or color
        final_color = imgui.ImVec4(final_color.x, final_color.y, final_color.z, final_color.w + (is_hovered and 0.2 or 0))
        
        if font_fa then imgui.PushFont(font_fa) end
        if is_hovered then
            draw_list:AddText(imgui.ImVec2(x - 1, y - 1), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(final_color.x, final_color.y, final_color.z, final_color.w * 0.5)), fa(icon))
        end
        draw_list:AddText(imgui.ImVec2(x, y), imgui.ColorConvertFloat4ToU32(final_color), fa(icon))
        if font_fa then imgui.PopFont() end
        if is_hovered then imgui.SetTooltip(u8(tooltip)) end
    end

    drawSocialIcon("##tg_link", "paper_plane", social_x, text_y, imgui.ImVec4(0.24, 0.67, 0.89, 0.8), "https://t.me/rdnMarket", "Telegram канал")
    drawSocialIcon("##yt_link", "play", social_x + S(25), text_y, imgui.ImVec4(1.0, 0.0, 0.0, 0.8), "https://youtube.com/@feyzer", "YouTube канал")

    -- 4. УЛУЧШЕННЫЙ ОНЛАЙН (Бейджик)
    local online_count = MarketData.online_count or 0
    local online_str = tostring(online_count)
    local online_icon = fa('users')
    
    if font_fa then imgui.PushFont(font_fa) end
    local icon_w = imgui.CalcTextSize(online_icon).x
    if font_fa then imgui.PopFont() end
    local text_w = imgui.CalcTextSize(online_str).x
    
    local badge_h = S(26)
    local badge_w = icon_w + text_w + S(25)
    local badge_x = social_x + S(60) -- Позиция после соцсетей
    local badge_y = p.y + (h - badge_h) / 2
    
    -- Фон бейджика
    draw_list:AddRectFilled(
        imgui.ImVec2(badge_x, badge_y), 
        imgui.ImVec2(badge_x + badge_w, badge_y + badge_h),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0.3)), 
        S(13)
    )
    
    -- Иконка
    if font_fa then imgui.PushFont(font_fa) end
    draw_list:AddText(imgui.ImVec2(badge_x + S(10), badge_y + S(5)), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_success), online_icon)
    if font_fa then imgui.PopFont() end
    
    -- Текст
    draw_list:AddText(imgui.ImVec2(badge_x + S(10) + icon_w + S(5), badge_y + S(5)), 0xFFFFFFFF, online_str)
    
    -- Пульсирующая точка (Live)
    local pulse_alpha = 0.6 + math.sin(header_animation_time * 5) * 0.4
    local dot_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.2, 0.9, 0.4, pulse_alpha))
    draw_list:AddCircleFilled(imgui.ImVec2(badge_x + badge_w - S(6), badge_y + S(6)), S(3), dot_col)

    -- 5. ПОИСК (Центр)
    local search_hint = ""
    local search_buffer = nil
    local is_search_active = false

    if App.active_tab == 1 then search_hint = "Поиск (Продажа)" search_buffer = Buffers.sell_search is_search_active = true
    elseif App.active_tab == 2 then search_hint = "Поиск (Скупка)" search_buffer = Buffers.buy_search is_search_active = true
    elseif App.active_tab == 3 then search_hint = "Поиск по логам" search_buffer = Buffers.logs_search is_search_active = true
    elseif App.active_tab == 4 then search_hint = "Поиск лавки" search_buffer = MarketData.search_buffer is_search_active = true end

    if is_search_active and search_buffer then
        local search_w = S(280)
        local search_h_real = S(35)
        local search_x = p.x + (w * 0.5) - (search_w * 0.5)
        local search_y = p.y + (h * 0.5) - (search_h_real * 0.5)
        
        -- Сдвигаем, если налезает на бейджик
        if search_x < (badge_x + badge_w + S(20)) then
             search_x = badge_x + badge_w + S(20)
        end
        imgui.SetCursorScreenPos(imgui.ImVec2(search_x, search_y))
        renderAnimatedSearchBar(search_buffer, search_hint, search_w)
    end
    
    -- 6. УПРАВЛЕНИЕ И КОНТЕКСТНЫЕ КНОПКИ (Справа)
    local btn_size = S(32)
    local btn_spacing = S(8)
    local close_btn_x = p.x + w - btn_size - S(15)
    local close_btn_y = p.y + (h - btn_size) * 0.5
    
    local current_x = close_btn_x - btn_spacing
    
    local function drawHeaderBtn(icon, callback, color_active, tooltip)
        current_x = current_x - btn_size
        imgui.SetCursorScreenPos(imgui.ImVec2(current_x, close_btn_y))
        if imgui.InvisibleButton("##hbtn_"..icon, imgui.ImVec2(btn_size, btn_size)) then callback() end
        
        local is_hovered = imgui.IsItemHovered()
        local bg_col = is_hovered and imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1,1,1,0.1)) or 0
        local icon_col = is_hovered and color_active or 0xB0FFFFFF
        
        if bg_col ~= 0 then
            draw_list:AddRectFilled(imgui.ImVec2(current_x, close_btn_y), imgui.ImVec2(current_x+btn_size, close_btn_y+btn_size), bg_col, S(6))
        end
        
        if font_fa then imgui.PushFont(font_fa) end
        local txt_sz = imgui.CalcTextSize(icon)
        draw_list:AddText(imgui.ImVec2(current_x + (btn_size - txt_sz.x)/2, close_btn_y + (btn_size - txt_sz.y)/2), icon_col, icon)
        if font_fa then imgui.PopFont() end
        
        if is_hovered and tooltip then imgui.SetTooltip(u8(tooltip)) end
        current_x = current_x - btn_spacing
    end

    -- КНОПКИ ПОЯВЛЯЮТСЯ ТОЛЬКО НА НУЖНЫХ ВКЛАДКАХ
    
    -- Вкладка 4: Глобальный маркет (Обновить)
    if App.active_tab == 4 then
        local icon = MarketData.is_loading and fa('spinner') or fa('arrows_rotate')
        drawHeaderBtn(icon, function() api_FetchMarketList() end, 0xFFFFFFFF, "Обновить список")
    end
    
    -- Вкладка 2: Скупка (Сканер Цен + Сканер Скупки)
    if App.active_tab == 2 then
        drawHeaderBtn(fa('chart_line'), function() startAvgPriceScan() end, 0xFF00A5FF, "Сканировать ср. цены")
        drawHeaderBtn(fa('bag_shopping'), function() startBuyingScan() end, 0xFF66CCFF, "Сканировать товары для скупки")
    end
    
    -- Вкладка 1: Продажа (Сканер Инвентаря)
    if App.active_tab == 1 then
        drawHeaderBtn(fa('magnifying_glass'), function() startScanning() end, 0xFF66CC66, "Сканировать инвентарь")
    end
    
    -- Кнопка закрытия (всегда)
    imgui.SetCursorScreenPos(imgui.ImVec2(close_btn_x, close_btn_y))
    if imgui.InvisibleButton("##close_header", imgui.ImVec2(btn_size, btn_size)) then App.win_state[0] = false end
    local h_close = imgui.IsItemHovered()
    
    draw_list:AddRectFilled(imgui.ImVec2(close_btn_x, close_btn_y), imgui.ImVec2(close_btn_x+btn_size, close_btn_y+btn_size), 
        h_close and 0x40FF0000 or 0, S(6))
        
    if font_fa then imgui.PushFont(font_fa) end
    local x_sz = imgui.CalcTextSize(fa('xmark'))
    draw_list:AddText(imgui.ImVec2(close_btn_x + (btn_size - x_sz.x)/2, close_btn_y + (btn_size - x_sz.y)/2), 
        h_close and 0xFFFFFFFF or 0xB0FFFFFF, fa('xmark'))
    if font_fa then imgui.PopFont() end
    
    draw_list:AddLine(imgui.ImVec2(p.x, p.y + h - 1), imgui.ImVec2(p.x + w, p.y + h - 1), 0x804D4D4D, 1.0)
    
    -- Перетаскивание
    imgui.SetCursorScreenPos(p)
    if imgui.InvisibleButton("##header_drag", imgui.ImVec2(w - S(200), h)) then end
    if imgui.IsItemActive() and imgui.IsMouseDragging(0) then
        local delta = imgui.GetMouseDragDelta(0)
        local wp = imgui.GetWindowPos()
        imgui.SetWindowPosVec2(imgui.ImVec2(wp.x + delta.x, wp.y + delta.y))
        imgui.ResetMouseDragDelta(0)
    end
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + h))
end

local remote_header_particles = {}
local remote_particle_icons = {
    fa('cart_plus'), fa('bag_shopping'), fa('money_bill'), fa('coins'), fa('percent'), fa('tag')
}

local function create_remote_particle(window_width, header_height)
    return {
        x = math.random(-50, window_width),
        y = math.random(0, header_height),
        speed_x = math.random(10, 30) / 10, -- Движение вправо
        speed_y = (math.random() - 0.5) * 0.5, -- Легкое колебание по вертикали
        size = math.random(12, 18),
        rotation = math.random(0, 360) / 57.29,
        rot_speed = (math.random() - 0.5) * 2.0,
        opacity = 0.0,
        target_opacity = math.random(20, 50) / 100,
        color = imgui.ImVec4(0.2, 0.8, 0.4, 0.0), -- Зеленоватые оттенки
        icon = remote_particle_icons[math.random(1, #remote_particle_icons)]
    }
end

function renderRemoteShopHeader(w, h)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    -- Фон заголовка (темно-зеленый градиент)
    draw_list:AddRectFilledMultiColor(
        p, 
        imgui.ImVec2(p.x + w, p.y + h),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.05, 0.15, 0.08, 1.0)),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.08, 0.20, 0.12, 1.0)),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.05, 0.15, 0.08, 1.0)),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.08, 0.20, 0.12, 1.0))
    )

    imgui.PushClipRect(p, imgui.ImVec2(p.x + w, p.y + h), true)
    local delta_time = imgui.GetIO().DeltaTime
    
    if #remote_header_particles < 12 then 
        table.insert(remote_header_particles, create_remote_particle(w, h)) 
    end

    for i = #remote_header_particles, 1, -1 do
        local part = remote_header_particles[i]
        
        part.x = part.x + part.speed_x
        part.y = part.y + part.speed_y
        part.rotation = part.rotation + (part.rot_speed * delta_time)
        
        if part.x < w * 0.1 then
            part.opacity = lerp(part.opacity, part.target_opacity, delta_time * 2)
        elseif part.x > w * 0.9 then
            part.opacity = lerp(part.opacity, 0.0, delta_time * 2)
        end

        local col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(part.color.x, part.color.y, part.color.z, part.opacity))
        
        imgui.PushFont(font_fa or nil)
        draw_list:AddText(imgui.ImVec2(p.x + part.x, p.y + part.y), col, part.icon)
        imgui.PopFont()

        if part.x > w + 20 then
            table.remove(remote_header_particles, i)
        end
    end
    imgui.PopClipRect()
    
    -- Текст заголовка
    local text_y = p.y + (h - imgui.GetFontSize()) * 0.5
    if font_fa then imgui.PushFont(font_fa) end
    draw_list:AddText(imgui.ImVec2(p.x + S(15), text_y), 
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.4, 1.0, 0.6, 1.0)), 
        fa('shop'))
    if font_fa then imgui.PopFont() end
    
    draw_list:AddText(imgui.ImVec2(p.x + S(40), text_y), 
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 1.0)), 
        u8"ПРОСМОТР ТОВАРОВ")
    
    -- == ПЕРЕТАСКИВАНИЕ ОКНА ==
    -- Создаем невидимую кнопку почти на всю ширину (оставляем место справа под крестик)
    imgui.SetCursorScreenPos(p)
    if imgui.InvisibleButton("##drag_remote", imgui.ImVec2(w - S(40), h)) then end
    
    -- Логика перетаскивания
    if imgui.IsItemActive() and imgui.IsMouseDragging(0) then
        local delta = imgui.GetMouseDragDelta(0)
        local wp = imgui.GetWindowPos()
        imgui.SetWindowPosVec2(imgui.ImVec2(wp.x + delta.x, wp.y + delta.y))
        imgui.ResetMouseDragDelta(0)
    end
    
    -- Восстанавливаем позицию курсора для дальнейшей отрисовки контента
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + h))
end

function renderRemoteShopWindow()
    local sw, sh = getScreenResolution()
    local w, h = 350, 500
    
    -- ПОЗИЦИЯ: Левый край (20 отступ), Центр по вертикали
    imgui.SetNextWindowPos(imgui.ImVec2(20, (sh - h) / 2), imgui.Cond.Appearing)
    imgui.SetNextWindowSize(imgui.ImVec2(w, h), imgui.Cond.FirstUseEver)
    
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 10)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.08, 0.09, 0.11, 0.98))
    
    if imgui.Begin("##RemoteShopViewer", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize) then
        local win_w = imgui.GetWindowWidth()
        
        -- 1. Шапка
        imgui.BeginChild("RemoteHeader", imgui.ImVec2(win_w, S(50)), false, imgui.WindowFlags.NoScrollbar)
            renderRemoteShopHeader(win_w, S(50))
        imgui.EndChild()
        
        -- 2. Поиск
        imgui.SetCursorPos(imgui.ImVec2(S(10), S(60)))
        renderAnimatedSearchBar(Buffers.remote_shop_search, "Поиск товара...", win_w - S(20))
        
        -- 3. Список товаров
        imgui.SetCursorPosY(S(110))
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(10), S(10)))
        imgui.BeginChild("RemoteItems", imgui.ImVec2(0, 0), true)
            
            -- Фильтрация
            local query = ffi.string(Buffers.remote_shop_search):lower()
            local filtered = {}
            if query == "" then
                filtered = Data.remote_shop_items
            else
                local q_utf8 = u8:decode(query):lower()
                for _, item in ipairs(Data.remote_shop_items) do
                    if item.name:lower():find(q_utf8, 1, true) then
                        table.insert(filtered, item)
                    end
                end
            end
            
            if #filtered == 0 then
                imgui.TextDisabled(u8("Товары не найдены или список пуст"))
            else
                local draw_list = imgui.GetWindowDrawList()
                local item_h = S(50)
                
                for i, item in ipairs(filtered) do
                    local p = imgui.GetCursorScreenPos()
                    local avail_w = imgui.GetContentRegionAvail().x
                    
                    -- Фон элемента
                    local bg_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.12, 0.13, 0.16, 0.5))
                    local hover_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.15, 0.16, 0.20, 0.8))
                    
                    -- Невидимая кнопка во всю ширину для клика
                    imgui.PushIDInt(item.slot)
                    if imgui.InvisibleButton("##ritem"..i, imgui.ImVec2(avail_w, item_h)) then
                        local payload = string.format('clickOnBlock|{"slot": %d, "type": 9}', item.slot)
                        sendCEF(payload)
                    end
                    local is_hovered = imgui.IsItemHovered()
                    if is_hovered then
                        imgui.SetTooltip(u8("Нажмите, чтобы показать в лавке"))
                    end
                    imgui.PopID()
                    
                    -- Отрисовка
                    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + avail_w, p.y + item_h), is_hovered and hover_col or bg_col, S(6))
                    
                    -- Название
                    draw_list:AddText(imgui.ImVec2(p.x + S(10), p.y + S(5)), 0xFFFFFFFF, u8(item.name))
                    
                    -- Цена и кол-во
                    local price_text = u8(item.price_text)
                    local amount_text = u8("x" .. item.amount)
                    
                    -- Отрисовка цены зеленым
                    draw_list:AddText(imgui.ImVec2(p.x + S(10), p.y + S(25)), 0xFF66FF66, price_text)
                    
                    -- Отрисовка количества справа
                    local amount_size = imgui.CalcTextSize(amount_text)
                    draw_list:AddText(imgui.ImVec2(p.x + avail_w - amount_size.x - S(10), p.y + (item_h - amount_size.y)/2), 0xFFAAAAAA, amount_text)
                    
                    imgui.SetCursorPosY(imgui.GetCursorPosY() - item_h + item_h + S(5))
                end
            end
            
        imgui.EndChild()
        imgui.PopStyleVar()
    end
    imgui.End()
    imgui.PopStyleColor()
    imgui.PopStyleVar(2)
end

function renderDownloadModal()
    local sw, sh = getScreenResolution()
    local w, h = 450, 280
    
    -- Плавное появление окна (fade-in)
    if DownloadState.alpha < 1.0 then DownloadState.alpha = DownloadState.alpha + 0.05 end
    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, DownloadState.alpha)
    
    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(w, h))
    
    -- Стилизация под современный UI
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 15)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.07, 0.08, 0.10, 1.0))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0.40, 0.25, 0.95, 0.3))

    if imgui.Begin("##RMarketDownload", DownloadState.show_window, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove) then
        local dl = imgui.GetWindowDrawList()
        local p = imgui.GetCursorScreenPos()
        local time = os.clock()

        -- Шапка с градиентом
        dl:AddRectFilledMultiColor(p, imgui.ImVec2(p.x + w, p.y + 140), 
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.12, 0.10, 0.20, 1.0)),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.12, 0.10, 0.20, 1.0)),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.07, 0.08, 0.10, 1.0)),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.07, 0.08, 0.10, 1.0))
        )

        -- Анимированная иконка
        if font_fa then imgui.PushFont(font_fa) end
        local icon = fa('cloud_arrow_down')
        local icon_color = imgui.ImVec4(0.5, 0.4, 1.0, 1.0)
        
        if DownloadState.is_downloading then
            icon = fa('spinner')
            DownloadState.icon_rotation = time * 5 -- Скорость вращения
            -- Эффект пульсации цвета при загрузке
            local pulse = (math.sin(time * 4) + 1) / 2
            icon_color = imgui.ImVec4(0.5 + (pulse * 0.2), 0.4, 1.0, 1.0)
        end

        imgui.SetWindowFontScale(3.5)
        local icon_size = imgui.CalcTextSize(icon)
        imgui.SetCursorPos(imgui.ImVec2((w - icon_size.x) / 2, S(40)))
        
        imgui.TextColored(icon_color, icon)
        imgui.SetWindowFontScale(1.0)
        if font_fa then imgui.PopFont() end

        -- Текст и статус
        imgui.SetCursorPosY(S(145))
        local status_u8 = u8(DownloadState.status_text)
        imgui.SetCursorPosX((w - imgui.CalcTextSize(status_u8).x) / 2)
        imgui.Text(status_u8)

        -- Кнопки или Прогресс-бар
        imgui.SetCursorPosY(h - S(70))
        if not DownloadState.is_downloading then
            local bw, bh = S(140), S(40)
            imgui.SetCursorPosX((w - (bw * 2 + S(15))) / 2)
            
            -- Кнопка скачать (Акцентная)
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.40, 0.25, 0.95, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.45, 0.35, 1.0, 1.0))
            if imgui.Button(u8("Установить"), imgui.ImVec2(bw, bh)) then
                downloadItemsFile()
            end
            imgui.PopStyleColor(2)
            
            imgui.SameLine()
            
            -- Кнопка закрыть (Вторичная)
            if imgui.Button(u8("Позже"), imgui.ImVec2(bw, bh)) then
                DownloadState.is_missing = false
            end
        else
            -- Плавный прогресс-бар
            imgui.SetCursorPosX(S(50))
            imgui.PushStyleColor(imgui.Col.PlotHistogram, imgui.ImVec4(0.40, 0.25, 0.95, 1.0))
            imgui.ProgressBar(DownloadState.progress, imgui.ImVec2(w - S(100), S(10)), "")
            imgui.PopStyleColor()
        end
    end
    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(3)
end

function renderScriptUpdateModal()
    local sw, sh = getScreenResolution()
    local w, h = 500, 300
    
    -- Плавное появление окна (fade-in)
    if DownloadState.update_alpha < 1.0 then DownloadState.update_alpha = DownloadState.update_alpha + 0.05 end
    imgui.PushStyleVarFloat(imgui.StyleVar.Alpha, DownloadState.update_alpha)
    
    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(w, h))
    
    -- Стилизация под современный UI
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 15)
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.07, 0.08, 0.10, 1.0))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0.25, 0.65, 0.95, 0.3))

    if imgui.Begin("##ScriptUpdate", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove) then
        local dl = imgui.GetWindowDrawList()
        local p = imgui.GetCursorScreenPos()
        local time = os.clock()

        -- Шапка с градиентом (голубой для обновления)
        dl:AddRectFilledMultiColor(p, imgui.ImVec2(p.x + w, p.y + 150), 
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.10, 0.15, 0.25, 1.0)),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.10, 0.15, 0.25, 1.0)),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.07, 0.08, 0.10, 1.0)),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.07, 0.08, 0.10, 1.0))
        )

        -- Анимированная иконка
        if font_fa then imgui.PushFont(font_fa) end
        local icon = fa('download')
        local icon_color = imgui.ImVec4(0.4, 0.7, 1.0, 1.0)
        
        if DownloadState.update_in_progress then
            icon = fa('spinner')
            -- Эффект пульсации цвета при загрузке
            local pulse = (math.sin(time * 4) + 1) / 2
            icon_color = imgui.ImVec4(0.4, 0.7 + (pulse * 0.2), 1.0, 1.0)
        end

        imgui.SetWindowFontScale(3.5)
        local icon_size = imgui.CalcTextSize(icon)
        imgui.SetCursorPos(imgui.ImVec2((w - icon_size.x) / 2, S(40)))
        
        imgui.TextColored(icon_color, icon)
        imgui.SetWindowFontScale(1.0)
        if font_fa then imgui.PopFont() end

        -- Заголовок
        imgui.SetCursorPosY(S(130))
        local title = u8("Доступно обновление RodinaMarket")
        imgui.SetCursorPosX((w - imgui.CalcTextSize(title).x) / 2)
        imgui.TextColored(imgui.ImVec4(0.4, 0.7, 1.0, 1.0), title)

        -- Информация о версии
        imgui.SetCursorPosY(S(160))
        imgui.SetCursorPosX(S(30))
        local current_version = thisScript().version
        local new_version = DownloadState.update_version or "?"
        local version_text = u8(string.format("%s ? %s", current_version, new_version))
        imgui.TextColored(imgui.ImVec4(0.8, 0.8, 0.8, 1.0), version_text)

        -- Текст статуса при загрузке
        if DownloadState.update_in_progress then
            imgui.SetCursorPosY(S(190))
            local status_u8 = u8(DownloadState.status_text)
            imgui.SetCursorPosX((w - imgui.CalcTextSize(status_u8).x) / 2)
            imgui.Text(status_u8)
        end

        -- Кнопки или Прогресс-бар
        imgui.SetCursorPosY(h - S(70))
        if not DownloadState.update_in_progress then
            local bw, bh = S(140), S(40)
            imgui.SetCursorPosX((w - (bw * 2 + S(15))) / 2)
            
            -- Кнопка обновить (Акцентная, голубая)
            imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.25, 0.65, 0.95, 1.0))
            imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.35, 0.75, 1.0, 1.0))
            if imgui.Button(u8("Обновить"), imgui.ImVec2(bw, bh)) then
                downloadScriptUpdate()
            end
            imgui.PopStyleColor(2)
            
            imgui.SameLine()
            
            -- Кнопка позже (Вторичная)
            if imgui.Button(u8("Позже"), imgui.ImVec2(bw, bh)) then
                DownloadState.update_available = false
                DownloadState.update_alpha = 0.0
            end
        else
            -- Плавный прогресс-бар
            imgui.SetCursorPosX(S(50))
            imgui.PushStyleColor(imgui.Col.PlotHistogram, imgui.ImVec4(0.25, 0.65, 0.95, 1.0))
            imgui.ProgressBar(DownloadState.progress, imgui.ImVec2(w - S(100), S(10)), "")
            imgui.PopStyleColor()
        end
    end
    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar(3)
end

function renderMiniProcessWindow(title, status_text, progress_text, stop_callback)
    local sw, sh = getScreenResolution()
    local w = 300 -- Фиксируем только ширину
    
    -- Центрируем окно
    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    
    -- Ограничиваем ширину, но высоту оставляем автоматической (0 = авто)
    -- Используем SetNextWindowSizeConstraints, чтобы окно не сжималось слишком сильно
    imgui.SetNextWindowSizeConstraints(imgui.ImVec2(w, 100), imgui.ImVec2(w, sh * 0.5))
    
    -- Стилизация
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(15, 15))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 10)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.07, 0.08, 0.10, 0.95))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0.40, 0.25, 0.95, 0.5))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, S(1))

    -- Добавляем флаг AlwaysAutoResize, чтобы окно подстраивалось под содержимое
    if imgui.Begin("##MiniProcess", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove + imgui.WindowFlags.AlwaysAutoResize) then
        
        -- == ЗАГОЛОВОК == --
        -- Используем нативный спиннер ImGui для анимации загрузки (он выглядит плавнее статического текста)
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.40, 0.25, 0.95, 1.0))
        -- (label, radius, thickness) - подберите параметры под свой масштаб
        if imgui.Spinner and pcall(function() imgui.Spinner("##spin", S(7), S(2)) end) then
             -- Если функция Spinner есть (зависит от версии mimgui)
        else
             -- Фоллбэк на иконку FA, если спиннера нет
             if font_fa then imgui.PushFont(font_fa) end
             imgui.Text(fa('spinner'))
             if font_fa then imgui.PopFont() end
        end
        imgui.PopStyleColor()
        
        imgui.SameLine()
        imgui.TextColored(CURRENT_THEME.text_primary, u8(title))
        
        imgui.Separator()
        imgui.Spacing()
        
        -- == ТЕКСТ СТАТУСА == --
        -- TextWrapped автоматически перенесет текст
        imgui.TextWrapped(u8(status_text))
        
        if progress_text then
            imgui.Spacing()
            imgui.TextDisabled(u8(progress_text))
        end
        
        -- Добавляем отступ перед кнопкой
        imgui.Spacing()
        imgui.Spacing()
        
        -- == КНОПКА == --
        -- Мы больше не используем SetCursorPosY, кнопка встанет сразу после текста
        local btn_h = S(30)
        
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.2, 0.2, 0.8))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.9, 0.3, 0.3, 1.0))
        
        -- Растягиваем кнопку на всю ширину (-1)
        if imgui.Button(u8("ПРЕРВАТЬ"), imgui.ImVec2(-1, btn_h)) then
            if stop_callback then stop_callback() end
        end
        
        imgui.PopStyleColor(2)
    end
    imgui.End()
    imgui.PopStyleVar(3)
    imgui.PopStyleColor(2)
end

local toggle_anims = {}
function renderAAAToggle(label, bool_ptr)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    local height = S(24)
    local width = S(44)
    local radius = height * 0.50
    
    imgui.PushIDInt(stringToID(label))
    imgui.BeginGroup()
    
    -- Logic
    local clicked = imgui.InvisibleButton("##toggle", imgui.ImVec2(width, height))
    if clicked then
        bool_ptr[0] = not bool_ptr[0]
        saveSettings() 
    end
    
    -- Animation State
    local id = tostring(bool_ptr) 
    if not toggle_anims[id] then toggle_anims[id] = 0.0 end
    
    local target = bool_ptr[0] and 1.0 or 0.0
    local speed = imgui.GetIO().DeltaTime * 10.0
    toggle_anims[id] = toggle_anims[id] + (target - toggle_anims[id]) * speed
    
    -- Drawing
    local t = toggle_anims[id]
    
    -- Background Color используем тему
    local col_bg_inactive = CURRENT_THEME.bg_secondary
    local col_bg_active = CURRENT_THEME.accent_primary
    
    local r = col_bg_inactive.x + (col_bg_active.x - col_bg_inactive.x) * t
    local g = col_bg_inactive.y + (col_bg_active.y - col_bg_inactive.y) * t
    local b = col_bg_inactive.z + (col_bg_active.z - col_bg_inactive.z) * t
    local col_bg = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, 1.0))
    
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), col_bg, radius)
    
    -- Circle Knob
    local circle_pad = S(2)
    local circle_radius = radius - circle_pad
    local circle_x_start = p.x + radius
    local circle_x_end = p.x + width - radius
    local circle_x = circle_x_start + (circle_x_end - circle_x_start) * t
    
    draw_list:AddCircleFilled(imgui.ImVec2(circle_x, p.y + radius), circle_radius, 0xFFFFFFFF)
    
    imgui.EndGroup()
    
    -- Text Label next to toggle
    imgui.SameLine(0, S(15))
    imgui.AlignTextToFramePadding()
    imgui.TextColored(CURRENT_THEME.text_primary, u8(label))
    
    imgui.PopID() 
    return clicked
end

-- === ФУНКЦИЯ ДЛЯ СТИЛИЗАЦИИ COMBO === --
function pushComboStyles()
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(S(10), S(8)))
    imgui.PushStyleColor(imgui.Col.FrameBg, CURRENT_THEME.bg_tertiary)
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(CURRENT_THEME.bg_tertiary.x * 1.1, CURRENT_THEME.bg_tertiary.y * 1.1, CURRENT_THEME.bg_tertiary.z * 1.1, 1.0))
    imgui.PushStyleColor(imgui.Col.FrameBgActive, imgui.ImVec4(CURRENT_THEME.bg_tertiary.x * 1.2, CURRENT_THEME.bg_tertiary.y * 1.2, CURRENT_THEME.bg_tertiary.z * 1.2, 1.0))
    imgui.PushStyleColor(imgui.Col.PopupBg, CURRENT_THEME.bg_main)
    imgui.PushStyleColor(imgui.Col.Header, imgui.ImVec4(CURRENT_THEME.accent_primary.x, CURRENT_THEME.accent_primary.y, CURRENT_THEME.accent_primary.z, 0.3))
    imgui.PushStyleColor(imgui.Col.HeaderHovered, imgui.ImVec4(CURRENT_THEME.accent_primary.x, CURRENT_THEME.accent_primary.y, CURRENT_THEME.accent_primary.z, 0.5))
    imgui.PushStyleColor(imgui.Col.HeaderActive, imgui.ImVec4(CURRENT_THEME.accent_primary.x, CURRENT_THEME.accent_primary.y, CURRENT_THEME.accent_primary.z, 0.8))
    imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_primary)
end

function popComboStyles()
    imgui.PopStyleColor(8) -- 7 цветов + 1 от FramePadding
    imgui.PopStyleVar()
end

-- === ФУНКЦИЯ ДЛЯ БЫСТРОГО ПРИМЕНЕНИЯ ЦВЕТОВ ТЕКСТА ТЕКУЩЕЙ ТЕМЫ === --
function applyThemeTextColors()
    imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_primary)
    imgui.PushStyleColor(imgui.Col.TextDisabled, CURRENT_THEME.text_hint)
    imgui.PushStyleColor(imgui.Col.FrameBg, CURRENT_THEME.bg_tertiary)
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(CURRENT_THEME.bg_tertiary.x * 1.1, CURRENT_THEME.bg_tertiary.y * 1.1, CURRENT_THEME.bg_tertiary.z * 1.1, 1.0))
    imgui.PushStyleColor(imgui.Col.FrameBgActive, imgui.ImVec4(CURRENT_THEME.bg_tertiary.x * 1.2, CURRENT_THEME.bg_tertiary.y * 1.2, CURRENT_THEME.bg_tertiary.z * 1.2, 1.0))
    imgui.PushStyleColor(imgui.Col.Border, CURRENT_THEME.border_light)
end

function revertThemeTextColors()
    imgui.PopStyleColor(6)
end

function renderAAASection(icon, name)
    imgui.Spacing()
    imgui.Spacing()
    
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    local w = imgui.GetContentRegionAvail().x
    
    -- Icon + Text
    if font_fa then imgui.PushFont(font_fa) end
    imgui.TextColored(CURRENT_THEME.accent_primary, icon)
    if font_fa then imgui.PopFont() end
    
    imgui.SameLine(nil, S(10))
    imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_primary)
    imgui.Text(name:upper()) 
    imgui.PopStyleColor()
    
    -- Gradient Line
    local line_y = imgui.GetCursorScreenPos().y - S(5)
    draw_list:AddRectFilledMultiColor(
        imgui.ImVec2(p.x, line_y),
        imgui.ImVec2(p.x + w, line_y + S(2)),
        imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary), -- Left
        imgui.ColorConvertFloat4ToU32(lerpColor(CURRENT_THEME.accent_primary, CURRENT_THEME.bg_main, 0.5)), -- Right
        imgui.ColorConvertFloat4ToU32(lerpColor(CURRENT_THEME.accent_primary, CURRENT_THEME.bg_main, 0.5)),
        imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary)
    )
    
    imgui.Spacing()
end

imgui.OnFrame(
    function()
        return App.win_state[0]
            or DownloadState.is_missing
            or App.is_scanning_buy
            or State.buying.active
            or App.is_selling_cef
            or App.remote_shop_active
    end,
    function(player)

        ----------------------------------------------------------------
        -- 1. ПРИОРИТЕТ: ОКНО ЗАГРУЗКИ ФАЙЛОВ
        ----------------------------------------------------------------
        if DownloadState.is_missing then
            renderDownloadModal()
            return
        end

        ----------------------------------------------------------------
        -- 1.5. ПРИОРИТЕТ: ОКНО ОБНОВЛЕНИЯ СКРИПТА
        ----------------------------------------------------------------
        if DownloadState.update_available then
            renderScriptUpdateModal()
            return
        end

        ----------------------------------------------------------------
        -- 2. ПРИОРИТЕТ: ПРОСМОТР ЧУЖОЙ ЛАВКИ
        ----------------------------------------------------------------
        if App.remote_shop_active and Data.settings.show_remote_shop_menu then
            renderRemoteShopWindow()

            -- если главное окно закрыто — рисуем ТОЛЬКО лавку
            if not App.win_state[0] then
                return
            end
        end

        ----------------------------------------------------------------
        -- 3. МИНИ-ПРОЦЕССЫ
        ----------------------------------------------------------------

        -- А) Сканирование лавки для скупки
        if App.is_scanning_buy then
            local page_info = State.buying_scan.current_page
                and ("Страница: " .. State.buying_scan.current_page)
                or ""

            renderMiniProcessWindow(
                "СКАНЕР СКУПКИ",
                "Сканирую товары в лавке...",
                page_info,
                function()
                    stopBuyingScan()
                    App.win_state[0] = true
                end
            )
            return
        end

        -- Б) Процесс выставления скупки
        if State.buying.active then
            local title = "ВЫСТАВЛЕНИЕ СКУПКИ"
            local status = "Выставляю товары..."
            local progress = string.format(
                "Товар: %d / %d",
                State.buying.current_item_index,
                #State.buying.items_to_buy
            )

            if State.buying.waiting_for_alt then
                title = "ОЖИДАНИЕ ЛАВКИ"
                status = "Подойдите к лавке и нажмите ALT!"
                progress = "Ожидание диалога..."
            end

            renderMiniProcessWindow(
                title,
                status,
                progress,
                function()
                    stopBuying()
                    App.win_state[0] = true
                end
            )
            return
        end

        -- В) Процесс продажи (CEF)
        if App.is_selling_cef then
            local current_idx = App.current_sell_item_index or 0
            local total = #Data.cef_sell_queue + (App.current_processing_item and 1 or 0)

            renderMiniProcessWindow(
                "ВЫСТАВЛЕНИЕ ПРОДАЖИ",
                "Выставляю товары...",
                string.format("Товар: %d / %d", current_idx, total),
                function()
                    stopSelling()
                    App.win_state[0] = true
                end
            )
            return
        end

        ----------------------------------------------------------------
        -- 4. ЕСЛИ ГЛАВНОЕ ОКНО ЗАКРЫТО — НИЧЕГО НЕ РИСУЕМ
        ----------------------------------------------------------------
        if not App.win_state[0] then
            return
        end

        ----------------------------------------------------------------
        -- 5. ЛОГИКА РАЗМЕРА ОКНА (МАСШТАБ + ОГРАНИЧЕНИЯ)
        ----------------------------------------------------------------
        local sw, sh = getScreenResolution()

        -- базовый размер при scale = 1.0
        local base_w, base_h = 1000, 650

        local scaled_w = math.floor(base_w * CURRENT_SCALE)
        local scaled_h = math.floor(base_h * CURRENT_SCALE)

        -- ограничение по экрану
        if scaled_w > sw * 0.95 then scaled_w = math.floor(sw * 0.95) end
        if scaled_h > sh * 0.95 then scaled_h = math.floor(sh * 0.95) end

        -- минимальные размеры
        if scaled_w < 800 then scaled_w = 800 end
        if scaled_h < 500 then scaled_h = 500 end

        -- условие применения размера
        local size_cond = imgui.Cond.FirstUseEver
        if Data.force_window_resize then
            size_cond = imgui.Cond.Always
            Data.force_window_resize = false
        end

        imgui.SetNextWindowSize(
            imgui.ImVec2(scaled_w, scaled_h),
            size_cond
        )

        imgui.SetNextWindowPos(
            imgui.ImVec2(
                (sw - scaled_w) * 0.5,
                (sh - scaled_h) * 0.5
            ),
            imgui.Cond.FirstUseEver
        )

        ----------------------------------------------------------------
        -- 6. СТИЛЬ ОКНА
        ----------------------------------------------------------------
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 0)
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 0)

        imgui.PushStyleColor(imgui.Col.WindowBg, CURRENT_THEME.bg_main)
        imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_primary)
        imgui.PushStyleColor(imgui.Col.TextDisabled, CURRENT_THEME.text_hint)

        ----------------------------------------------------------------
        -- 7. ГЛАВНОЕ ОКНО
        ----------------------------------------------------------------
        if imgui.Begin("Rodina Market", App.win_state,
        imgui.WindowFlags.NoCollapse + 
        imgui.WindowFlags.NoTitleBar + 
        imgui.WindowFlags.NoResize) then
        
        local window_pos = imgui.GetWindowPos()
        local window_size = imgui.GetWindowSize()
        
        -- == HEADER == --
        imgui.BeginChild("Header", imgui.ImVec2(window_size.x, S(90)), false, imgui.WindowFlags.NoScrollbar)
            imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_secondary)
            renderCustomHeader()
            imgui.PopStyleColor()
        imgui.EndChild()
        
        -- == TABS == --
        imgui.BeginChild("Tabs", imgui.ImVec2(window_size.x, S(55)), false, imgui.WindowFlags.NoScrollbar)
            imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_secondary)
            local draw_list = imgui.GetWindowDrawList()
            local p = imgui.GetCursorScreenPos()
            local w = window_size.x
            local tab_count = #tabs
            local tab_w = w / tab_count
            
            draw_list:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + S(55)), 
                imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary))
            
            -- Анимация индикатора вкладки
            anim_tabs.target_pos = (App.active_tab - 1) * tab_w
            anim_tabs.current_pos = lerp(anim_tabs.current_pos, anim_tabs.target_pos, 0.2)
            
            local indicator_w = tab_w * 0.6
            local indicator_x = p.x + anim_tabs.current_pos + (tab_w - indicator_w) / 2
            
            draw_list:AddRectFilled(
                imgui.ImVec2(indicator_x, p.y + S(53)), 
                imgui.ImVec2(indicator_x + indicator_w, p.y + S(55)), 
                imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary), 
                S(2)
            )
            
            for i, tab in ipairs(tabs) do
                local tab_p = imgui.ImVec2(p.x + (i-1) * tab_w, p.y)
                imgui.SetCursorScreenPos(tab_p)
                
                imgui.PushIDInt(tab.id)
                if imgui.InvisibleButton("##tab_"..i, imgui.ImVec2(tab_w, S(55))) then
                    App.active_tab = tab.id
                end
                
                local hovered = imgui.IsItemHovered()
                local is_active = (App.active_tab == tab.id)
                local text_color = is_active and CURRENT_THEME.accent_primary 
                                  or hovered and CURRENT_THEME.text_primary 
                                  or CURRENT_THEME.text_secondary
                
                local icon = tab.icon
                local label = u8(tab.name)
                local icon_size = imgui.CalcTextSize(icon)
                local label_size = imgui.CalcTextSize(label)
                local total_w = icon_size.x + S(10) + label_size.x
                
                local start_x = tab_p.x + (tab_w - total_w) * 0.5
                local start_y = tab_p.y + (S(55) - label_size.y) * 0.5
                
                imgui.PushFont(font_fa or nil)
                draw_list:AddText(imgui.ImVec2(start_x, start_y), imgui.ColorConvertFloat4ToU32(text_color), icon)
                imgui.PopFont()
                
                draw_list:AddText(imgui.ImVec2(start_x + icon_size.x + S(10), start_y), imgui.ColorConvertFloat4ToU32(text_color), label)
                imgui.PopID()
            end
            imgui.PopStyleColor()
        imgui.EndChild()
        
        -- == CONTENT == --
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(20), S(20)))
        imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_main)
        imgui.BeginChild("Content", imgui.ImVec2(0, 0), false, imgui.WindowFlags.NoScrollbar)
            
            if App.active_tab == 1 then
                -- [ВКЛАДКА 1: ПРОДАЖА]
                local avail_w = imgui.GetContentRegionAvail().x
                local avail_h = imgui.GetContentRegionAvail().y
                
                if not Data.cached_sell_filtered or ffi.string(Buffers.sell_search) ~= Data.last_sell_search_str then
                    Data.last_sell_search_str = ffi.string(Buffers.sell_search)
                    Data.cached_sell_filtered = filterList(Data.scanned_items, Buffers.sell_search)
                end
                local filtered_items = Data.cached_sell_filtered
                
                -- Считаем сумму
                local sell_total = calculateSellTotal()
                
                imgui.Spacing()
                imgui.Columns(2, "##sale_content", true)
                imgui.SetColumnWidth(0, avail_w * 0.4)
                
                -- ЛЕВАЯ КОЛОНКА (Найденные)
                imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(12), S(12)))
                local left_panel_height = avail_h - S(10)
                imgui.BeginChild("ScannedItemsPanel", imgui.ImVec2(0, left_panel_height), true, imgui.WindowFlags.NoScrollbar)
                    imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_secondary)
                    renderUnifiedHeader(u8("Найденные предметы"), fa('magnifying_glass'))
                    
                    -- СКРОЛЛИРУЕМЫЙ СПИСОК
                    renderSmoothScrollBox("ScannedItemsScroll", imgui.ImVec2(0, 0), function()
                        applyThemeTextColors()
                        imgui.PushStyleColor(imgui.Col.Header, imgui.ImVec4(CURRENT_THEME.accent_primary.x, CURRENT_THEME.accent_primary.y, CURRENT_THEME.accent_primary.z, 0.3))
                        imgui.PushStyleColor(imgui.Col.HeaderHovered, imgui.ImVec4(CURRENT_THEME.accent_primary.x, CURRENT_THEME.accent_primary.y, CURRENT_THEME.accent_primary.z, 0.5))
                        imgui.PushStyleColor(imgui.Col.HeaderActive, imgui.ImVec4(CURRENT_THEME.accent_primary.x, CURRENT_THEME.accent_primary.y, CURRENT_THEME.accent_primary.z, 0.8))
                        
                        for i, item in ipairs(filtered_items) do
                            imgui.PushIDInt(i)
                            
                            local is_added = isItemInSellList(item.model_id)
                            local count_in_sell = countItemInSellList(item.model_id)
                            
                            local p = imgui.GetCursorScreenPos()
                            local w = imgui.GetContentRegionAvail().x
                            local h = S(36)
                            
                            imgui.SetCursorScreenPos(p)
                            if imgui.InvisibleButton("##scan_btn_"..i, imgui.ImVec2(w, h)) then
                                if not is_added then
                                    table.insert(Data.sell_list, {
                                        name = item.name, 
                                        price = 1000, 
                                        amount = 1, 
                                        model_id = item.model_id, 
                                        missing = false, 
                                        active = true
                                    })
                                    saveListsConfig()
                                    calculateSellTotal()
                                end
                            end
                            
                            local is_hovered = imgui.IsItemHovered()
                            local bg_col = 0
                            if is_added then
                                bg_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(CURRENT_THEME.accent_success.x, CURRENT_THEME.accent_success.y, CURRENT_THEME.accent_success.z, 0.15))
                            elseif is_hovered then
                                bg_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.05))
                            end
                            
                            if bg_col ~= 0 then
                                imgui.GetWindowDrawList():AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), bg_col, S(4))
                            end
                            
                            local text_y = p.y + (h - imgui.CalcTextSize("A").y) / 2
                            local icon_x = p.x + S(8)
                            
                            if is_added then
                                if font_fa then imgui.PushFont(font_fa) end
                                imgui.GetWindowDrawList():AddText(imgui.ImVec2(icon_x, text_y), 
                                    imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_success), fa('check'))
                                if font_fa then imgui.PopFont() end
                            else
                                if font_fa then imgui.PushFont(font_fa) end
                                imgui.GetWindowDrawList():AddText(imgui.ImVec2(icon_x, text_y), 
                                    imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint), fa('plus'))
                                if font_fa then imgui.PopFont() end
                            end
                            
                            local label_x = icon_x + S(20)
                            local label = u8(item.name)
                            if count_in_sell > 1 then label = label .. u8(" (x" .. count_in_sell .. ")") end
                            
                            local text_col = is_added and CURRENT_THEME.text_secondary or CURRENT_THEME.text_primary
                            imgui.GetWindowDrawList():AddText(imgui.ImVec2(label_x, text_y), 
                                imgui.ColorConvertFloat4ToU32(text_col), label)

                            imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + h + S(2)))
                            imgui.PopID()
                        end
                        
                        imgui.PopStyleColor(3)
                        revertThemeTextColors()
                    end)
                    imgui.PopStyleColor()
                imgui.EndChild()
                imgui.PopStyleVar()
                
                imgui.NextColumn()
                
                -- ПРАВАЯ КОЛОНКА (Список на продажу)
                imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(12), S(12)))
                local right_panel_height = avail_h - S(10)
                imgui.BeginChild("SellListPanel", imgui.ImVec2(0, right_panel_height), true, imgui.WindowFlags.NoScrollbar)
                    imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_secondary)
                    
                    -- Заголовок
                    renderUnifiedHeader(u8("Список на продажу"), fa('list'))
                    
                    -- Сумма справа
                    local win_pos = imgui.GetWindowPos()
                    local win_width = imgui.GetWindowWidth()
                    local sum_str = u8("Всего: ") .. formatMoney(sell_total)
                    local sum_sz = imgui.CalcTextSize(sum_str)
                    
                    imgui.GetWindowDrawList():AddText(
                        imgui.ImVec2(win_pos.x + win_width - sum_sz.x - S(15), win_pos.y + S(12)),
                        imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_success),
                        sum_str
                    )
                    
                    -- ? ФИКС: считаем высоту кнопки + отступы
                    local button_h = S(38)
                    local bottom_padding = S(12)
                    local scroll_h = imgui.GetContentRegionAvail().y - button_h - bottom_padding
                    
                    -- СКРОЛЛИРУЕМЫЙ список (ТОЛЬКО ОН)
                    renderSmoothScrollBox("SellItemsScroll", imgui.ImVec2(0, scroll_h), function()
                        if #Data.sell_list == 0 then
                            imgui.Spacing()
                            imgui.Indent(S(10))
                            imgui.TextColored(CURRENT_THEME.text_hint, fa('inbox') .. " " .. u8("Нет товаров"))
                            imgui.Unindent(S(10))
                        else
                            for i, item in ipairs(Data.sell_list) do
                                renderSellItem(i, item)
                            end
                        end
                    end)
                    
                    imgui.Spacing()
                    imgui.Dummy(imgui.ImVec2(0, S(5)))
                    
                    -- КНОПКА (БОЛЬШЕ НЕ СКРОЛЛИТСЯ)
                    imgui.PushStyleColor(imgui.Col.Button, CURRENT_THEME.accent_primary)
                    imgui.PushStyleColor(imgui.Col.ButtonHovered, lerpColor(CURRENT_THEME.accent_primary, CURRENT_THEME.accent_secondary, 0.5))
                    
                    if imgui.Button(
                        fa('paper_plane') .. " " .. u8("Выставить на продажу"),
                        imgui.ImVec2(-1, button_h)
                    ) then
                        startCEFSelling()
                    end
                    
                    imgui.PopStyleColor(2)
                imgui.EndChild()
                imgui.PopStyleVar()
                
                imgui.Columns(1)
                
            elseif App.active_tab == 2 then
                -- [ВКЛАДКА 2: СКУПКА]
                local avail_size = imgui.GetContentRegionAvail()
                local avail_h = avail_size.y
                local current_search = ffi.string(Buffers.buy_search)
                if current_search ~= last_buy_search then refresh_buyables = true last_buy_search = current_search end
                
                if refresh_buyables then
                    refresh_buyables = false refreshed_buyables = {}
                    local query_utf8 = current_search
                    if query_utf8 ~= "" then
                        local query = u8:decode(query_utf8):lower()
                        for _, item in ipairs(Data.buyable_items) do if item.name:lower():find(query, 1, true) then table.insert(refreshed_buyables, item) end end
                    else refreshed_buyables = Data.buyable_items end
                end
                
                -- Считаем сумму
                local buy_total = calculateBuyTotal()
                
                imgui.Spacing()
                imgui.Columns(2, "##buy_content", true)
                imgui.SetColumnWidth(0, avail_size.x * 0.4)
                
                -- ЛЕВАЯ КОЛОНКА (Доступные товары)
                imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(12), S(12)))
                local left_buy_height = avail_h - S(10)
                imgui.BeginChild("BuyableItemsPanel", imgui.ImVec2(0, left_buy_height), true, imgui.WindowFlags.NoScrollbar)
                    
                    renderUnifiedHeader(u8("Доступные товары"), fa('magnifying_glass'))
                    
                    renderSmoothScrollBox("BuyableScroll", imgui.ImVec2(0, 0), function()
                        applyThemeTextColors()
                        
                        -- [FIX: OPTIMIZATION] Ручная виртуализация списка для высокого ФПС
                        local item_height = S(28) 
                        local total_items = #refreshed_buyables
                        local total_height = total_items * item_height
                        
                        imgui.Dummy(imgui.ImVec2(10, total_height))
                        
                        local current_scroll_y = imgui.GetScrollY()
                        local visible_h = imgui.GetWindowHeight()
                        
                        local start_idx = math.floor(current_scroll_y / item_height) + 1
                        local end_idx = start_idx + math.ceil(visible_h / item_height) + 1
                        
                        if start_idx < 1 then start_idx = 1 end
                        if end_idx > total_items then end_idx = total_items end
                        
                        imgui.SetCursorPosY((start_idx - 1) * item_height)
                        
                        for i = start_idx, end_idx do
                            local item = refreshed_buyables[i]
                             if item then
                                local p = imgui.GetCursorScreenPos()
                                local w = imgui.GetContentRegionAvail().x
                                
                                if imgui.InvisibleButton("##src"..i, imgui.ImVec2(w, item_height)) then
                                    table.insert(Data.buy_list, {name = item.name, price = 100, amount = 1, index = item.index, active = true})
                                    saveListsConfig()
                                    calculateBuyTotal()
                                end
                                
                                local is_hovered = imgui.IsItemHovered()
                                if is_hovered then
                                    imgui.GetWindowDrawList():AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + item_height), 
                                        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.05)), S(4))
                                end
                                
                                local text_y = p.y + (item_height - imgui.CalcTextSize("A").y) / 2
                                imgui.GetWindowDrawList():AddText(imgui.ImVec2(p.x + S(8), text_y), 
                                    imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary), u8(item.name))
                            end
                        end
                        revertThemeTextColors()
                    end)
                imgui.EndChild()
                imgui.PopStyleVar()
                
                imgui.NextColumn()
                
                -- ПРАВАЯ КОЛОНКА (Моя скупка)
                imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(12), S(12)))
                local right_buy_height = avail_h - S(10)
                imgui.BeginChild("BuySettingsPanel", imgui.ImVec2(0, right_buy_height), true, imgui.WindowFlags.NoScrollbar)
                    imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_secondary)
                    
                    -- Заголовок
                    renderUnifiedHeader(u8("Моя скупка"), fa('basket_shopping'))
                    
                    -- Сумма справа
                    local win_pos = imgui.GetWindowPos()
                    local win_width = imgui.GetWindowWidth()
                    local sum_str = u8("Всего: ") .. formatMoney(buy_total)
                    local sum_sz = imgui.CalcTextSize(sum_str)
                    
                    imgui.GetWindowDrawList():AddText(
                        imgui.ImVec2(win_pos.x + win_width - sum_sz.x - S(15), win_pos.y + S(12)),
                        imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_success),
                        sum_str
                    )
                    
                    -- ? ФИКС: считаем высоту кнопки + отступы
                    local button_h = S(38)
                    local bottom_padding = S(12)
                    local scroll_h = imgui.GetContentRegionAvail().y - button_h - bottom_padding
                    
                    -- СКРОЛЛИРУЕМЫЙ список (ТОЛЬКО ОН)
                    renderSmoothScrollBox("BuyItemsList", imgui.ImVec2(0, scroll_h), function()
                         if #Data.buy_list == 0 then
                            imgui.Spacing()
                            imgui.Indent(S(10))
                            imgui.TextColored(CURRENT_THEME.text_hint, fa('inbox') .. " " .. u8("Нет товаров"))
                            imgui.Unindent(S(10))
                        else
                            for i, item in ipairs(Data.buy_list) do
                                renderBuyItem(i, item)
                            end
                        end
                    end)
                    
                    imgui.Spacing()
                    imgui.Dummy(imgui.ImVec2(0, S(5)))
                    
                    -- КНОПКА (БОЛЬШЕ НЕ СКРОЛЛИТСЯ)
                    imgui.PushStyleColor(imgui.Col.Button, CURRENT_THEME.accent_primary)
                    imgui.PushStyleColor(imgui.Col.ButtonHovered, lerpColor(CURRENT_THEME.accent_primary, CURRENT_THEME.accent_secondary, 0.5))
                    if imgui.Button(fa('shop') .. " " .. u8("Выставить всё на скуп"), imgui.ImVec2(-1, button_h)) then
                        startBuying()
                    end
                    imgui.PopStyleColor(2)
                imgui.EndChild()
                imgui.PopStyleVar()
                
                imgui.Columns(1)

            elseif App.active_tab == 3 then
                imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(12), S(12)))
                imgui.BeginChild("LogsContent", imgui.ImVec2(0, 0), true)
                    imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_secondary)
                    renderLogsTab()
                    imgui.PopStyleColor()
                imgui.EndChild()
                imgui.PopStyleVar()
            
            -- == НОВЫЙ БЛОК НАСТРОЕК == --
            elseif App.active_tab == 4 then
                imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(12), S(12)))
                imgui.BeginChild("GlobalMarket", imgui.ImVec2(0, 0), true)
                    imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_secondary)
                    renderGlobalMarketTab()
                    imgui.PopStyleColor()
                imgui.EndChild()
                imgui.PopStyleVar()

			elseif App.active_tab == 5 then
                imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(12), S(12)))
                imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_secondary)
                imgui.BeginChild("SettingsContent", imgui.ImVec2(0, 0), true)
                    
                    -- Padding container
                    imgui.Indent(S(30))
                    imgui.PushItemWidth(S(300)) -- Standardize input width
                    
                    -- === SECTION 1: SHOP CONFIGURATION ===
                    renderAAASection(fa('store'), u8"Конфигурация Лавки")
                    
                    -- Auto Name Feature
                    renderAAAToggle("Авто-название лавки", Buffers.settings.auto_name)
                    imgui.SameLine()
                    imgui.TextDisabled("(?)")
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip(u8("Автоматически вводит название при\nоткрытии диалога аренды."))
                    end
                    
                    -- Name Input
                    if Buffers.settings.auto_name[0] then
                        imgui.Indent(S(58)) -- Indent to align with text
                        imgui.Spacing()
                        imgui.TextColored(CURRENT_THEME.text_hint, u8("Название магазина:"))
                        
                        -- Styled Input
                        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(S(10), S(8)))
                        imgui.PushStyleColor(imgui.Col.FrameBg, CURRENT_THEME.bg_tertiary)
                        imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(CURRENT_THEME.bg_tertiary.x * 1.1, CURRENT_THEME.bg_tertiary.y * 1.1, CURRENT_THEME.bg_tertiary.z * 1.1, 1.0))
                        imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_primary)
                        
                        if renderModernInput("##shop_name_input", Buffers.settings.shop_name, S(300), u8("Введите название лавки")) then
                            saveSettings()
                        end
                        
                        imgui.PopStyleColor(3)
                        imgui.PopStyleVar()
                        imgui.Unindent(S(58))
                    end
                    
                    -- === SECTION 2: INTERFACE & UX ===
                    renderAAASection(fa('desktop'), u8"Интерфейс")
                    
                    -- Theme Selection
                    imgui.Text(u8("Тема оформления"))
                    imgui.SameLine()
                    imgui.TextDisabled("(?)")
                    if imgui.IsItemHovered() then imgui.SetTooltip(u8("Выберите стиль оформления интерфейса")) end
                    
                    local theme_items = {u8("Темная (Dark Modern)"), u8("Светлая (Light Modern)")}
                    local theme_preview = theme_items[Buffers.settings.theme_combo[0] + 1] or theme_items[1]
                    
                    pushComboStyles()
                    if imgui.BeginCombo("##theme_selector", theme_preview) then
                        for i, item in ipairs(theme_items) do
                            local is_selected = (Buffers.settings.theme_combo[0] == i - 1)
                            if imgui.Selectable(item, is_selected) then
                                Buffers.settings.theme_combo[0] = i - 1
                                if i == 1 then
                                    applyTheme("DARK_MODERN")
                                else
                                    applyTheme("LIGHT_MODERN")
                                end
                                saveSettings()
                            end
                            if is_selected then imgui.SetItemDefaultFocus() end
                        end
                        imgui.EndCombo()
                    end
                    popComboStyles()
                    
                    imgui.Spacing()
                    imgui.Spacing()
                    
                    -- UI Scaling
                    imgui.Text(u8("Масштаб интерфейса"))
                    imgui.SameLine()
                    imgui.TextDisabled("(?)")
                    if imgui.IsItemHovered() then imgui.SetTooltip(u8("Масштаб применяется автоматически")) end
                    
                    local scale_items = {u8("Компактный (0.85x)"), u8("Стандартный (1.0x)"), u8("Крупный (1.25x)")}
                    local combo_preview = scale_items[Buffers.settings.ui_scale_combo[0] + 1] or scale_items[2]
                    
                    pushComboStyles()
                    if imgui.BeginCombo("##scale_c", combo_preview) then
                        for i, item in ipairs(scale_items) do
                            local is_selected = (Buffers.settings.ui_scale_combo[0] == i - 1)
                            if imgui.Selectable(item, is_selected) then
								local old_scale = Buffers.settings.ui_scale_combo[0]
								Buffers.settings.ui_scale_combo[0] = i - 1
								
								-- === ДИНАМИЧЕСКОЕ ПРИМЕНЕНИЕ МАСШТАБА ===
								CURRENT_SCALE = SCALE_MODES[i - 1] or 1.0
								
								-- Пересчитываем стиль с новым масштабом
								applyStrictStyle()
								
								-- Сохраняем в настройки
								saveSettings()
								
								-- !!! ВАЖНО: Флаг для принудительного изменения размера окна !!!
								Data.force_window_resize = true 
								
								addToastNotification(string.format("Масштаб изменен на %.2fx", CURRENT_SCALE), "success", 3.0)
							end
                            if is_selected then imgui.SetItemDefaultFocus() end
                        end
                        imgui.EndCombo()
                    end
                    popComboStyles()
                    
                    imgui.Spacing()
                    
                    -- Remote Shop Menu
                    renderAAAToggle("Окно просмотра товаров", Buffers.settings.show_remote_shop_menu)
                    imgui.SameLine()
                    imgui.TextDisabled("(?)")
                    if imgui.IsItemHovered() then
                        imgui.SetTooltip(u8("Показывать отдельное окно со списком товаров\nпри просмотре чужой лавки."))
                    end
                    
                    -- === SECTION 3: DATA MANAGEMENT ===
                    renderAAASection(fa('database'), u8"Данные")
                    
                    if imgui.Button(u8("Перезагрузить items.json"), imgui.ImVec2(S(250), S(35))) then
                        downloadItemsFile()
                    end
                    imgui.SameLine()
                    imgui.TextDisabled(u8("Версия с GitHub"))

                    imgui.PopItemWidth()
                    imgui.Unindent(S(30))
                    
                imgui.EndChild()
                imgui.PopStyleColor()
                imgui.PopStyleVar()
            end
            
        imgui.EndChild()
        imgui.PopStyleVar()
        
    end
    imgui.End()
    imgui.PopStyleVar(3)
    imgui.PopStyleColor(3)
    
    -- Рендерим Toast-уведомления (они рендерятся поверх всего интерфейса)
    renderToastNotifications()
end)

function onReceivePacket(id)
    if id == 32 then
		api_DeleteMyShop()
    end
end

-- === ПЕРЕМЕННЫЕ ДЛЯ ОПТИМИЗАЦИИ ПАМЯТИ === --
local last_gc_time = os.clock()
local last_cache_cleanup_time = os.clock()
local CACHE_CLEANUP_INTERVAL = 30.0 -- Очищаем кэши каждые 30 секунд

function main()
    while not isSampAvailable() do wait(100) end
    
    -- === ПРОВЕРКА ОБНОВЛЕНИЯ СКРИПТА ===
    if enable_autoupdate then
        checkScriptUpdate()
    end
    -- === КОНЕЦ ПРОВЕРКИ ОБНОВЛЕНИЯ ===
    
    ensureDirectories() 

    -- Проверка наличия items.json
    local items_path = PATHS.ROOT .. "items.json"
    if not doesFileExist(items_path) then
        DownloadState.is_missing = true
        App.win_state[0] = false 
        sampAddChatMessage('[RodinaMarket] {ff0000}Отсутствует items.json! Следуйте инструкциям на экране.', -1)
        
        while DownloadState.is_missing do
            wait(0)
            if DownloadState.should_reload then
                sampAddChatMessage('[RodinaMarket] {00ff00}Файл успешно загружен. Перезагрузка скрипта...', -1)
                wait(500)
                thisScript():reload()
                return
            end
        end
    end

    sampRegisterChatCommand('rmenu', function() App.win_state[0] = not App.win_state[0] end)
    
    loadAllData()
    loadItemNames()
    
    -- === ИНИЦИАЛИЗАЦИЯ ТЕМЫ === --
    -- Загружаем сохраненную тему из настроек или используем по умолчанию
    if Data.settings.current_theme then
        applyTheme(Data.settings.current_theme)
        print("[RMarket] Загружена тема: " .. Data.settings.current_theme)
    else
        applyTheme("DARK_MODERN") -- Тема по умолчанию
        print("[RMarket] Загружена тема по умолчанию: DARK_MODERN")
    end
    
    calculateSellTotal()
    calculateBuyTotal()
    
    sampAddChatMessage('[RodinaMarket] Загружен! Введите {FF0000}/rmenu', -1)
    
    local last_gc_time = os.clock()
    local last_save_time = os.clock()
    
    addEventHandler('onReceivePacket', function(id, bs)
		if id ~= 220 then return end

		local status, err = pcall(function()
			local packet_id = raknetBitStreamReadInt8(bs)
			local packet_type = raknetBitStreamReadInt8(bs)

			if packet_type ~= 17 then return end

			raknetBitStreamIgnoreBits(bs, 32)
			local length = raknetBitStreamReadInt16(bs)

			if length <= 0 or length > 50000 then return end

			local encoded = raknetBitStreamReadInt8(bs)
			local str
			
			local read_status, result_str = pcall(function() 
				if encoded ~= 0 then
					return raknetBitStreamDecodeString(bs, length + encoded)
				else
					return raknetBitStreamReadString(bs, length)
				end
			end)
			
			if not read_status or not result_str then return end
			str = result_str

			-- 1. Ловим закрытие интерфейса для Remote Shop
			if str:find("event%.setActiveView") and str:find("null") then
				if App.remote_shop_active then
					App.remote_shop_active = false
					Data.remote_shop_items = {}
				end
			end

			-- 2. Парсинг инвентаря
			if str:find("event%.inventory%.playerInventory") or str:find("%[%s*{%s*\"action\"") then
				parseCEFInventory(str)
			end

			-- 3. НОВОЕ: Обработка события завершения торговли
			if str:find("cef%.addNotification") then
                -- Ищем уведомление о завершении торговли
                local utf8_phrase = ("Вы завершили торговлю")
                if str:find(utf8_phrase, 1, true) then
                    print("[RMarket] Обнаружено завершение торговли. Удаляю лавку...")
                    api_DeleteMyShop()
                    -- УБРАНО уведомление в чат
                end
            end


            -- 3. АВТО-ОТВЕТ НА ОКНО ПРОДАЖИ
            if App.is_selling_cef and App.current_processing_item and str:find("cef%.modals%.showModal") then
                local json_candidate = str:match("(%[.*%])")
                if json_candidate and #json_candidate < 2000 then
                    local ok, data = pcall(json.decode, json_candidate)
                    if ok and data and data[2] and data[2].id == 240 then
                        App.tasks.remove_by_name("cef_dialog_timeout")

                        local body_text = data[2].body or ""
                        local payload_response

                        if body_text:find("Введите цену за один товар") then
                            payload_response = string.format(
                                "sendResponse|240|0|1|%d",
                                App.current_processing_item.price
                            )
                        else
                            payload_response = string.format(
                                "sendResponse|240|0|1|%d,%d",
                                App.current_processing_item.amount,
                                App.current_processing_item.price
                            )
                        end

                        sendCEF(payload_response)
                        -- Удаляем уже обработанный предмет, чтобы не зависнуть
                        App.current_processing_item = nil
                        App.tasks.add("cef_next_item_delay", processNextCEFSellItem, 800)
                    end
                end
            end
        end)

        if not status then
            -- Выводим ошибку в консоль, а не крашим игру
            print("[RMarket] Error handling packet: " .. tostring(err))
        end
    end)
	local last_ping_time = 0 

    while true do 
        wait(0)
        
        App.tasks.process() 
        
        -- [FIX] Отправляем Heartbeat каждые 30 секунд
        if os.clock() - last_ping_time > 30.0 then
            api_SendHeartbeat()
            last_ping_time = os.clock()
        end
        
        if os.clock() - last_gc_time > 10.0 then
            collectgarbage("collect")
            last_gc_time = os.clock()
        end
        
        -- Периодическая очистка кэшей памяти
        if os.clock() - last_cache_cleanup_time > CACHE_CLEANUP_INTERVAL then
            cleanupCaches()
            last_cache_cleanup_time = os.clock()
        end
        
        local current_time = os.time()
        
        -- === ОБНОВЛЕНИЕ ЛАВКИ (ТОЛЬКО ПРИ ИЗМЕНЕНИЯХ) ===
        -- Вместо автоматического обновления раз в минуту
        -- мы будем обновлять только при реальных изменениях
        
        -- === ПРОВЕРКА СОСТОЯНИЯ АКТИВНЫХ ТОВАРОВ ===
        -- (Это дополнительная проверка на случай, если пользователь вручную отключил все товары)
        if current_time - ShopState.last_check_time > ShopState.check_interval then
            local has_active = false
            
            -- Проверяем активные товары для продажи
            for _, item in ipairs(Data.sell_list) do
                if item.active then
                    has_active = true
                    break
                end
            end
            
            -- Проверяем активные товары для скупки
            if not has_active then
                for _, item in ipairs(Data.buy_list) do
                    if item.active then
                        has_active = true
                        break
                    end
                end
            end
            
            -- Если раньше были активные товары, а сейчас их нет - удаляем лавку
            if ShopState.has_active_items and not has_active then
                print("[RMarket] Обнаружено отключение всех товаров. Удаляем лавку...")
                api_DeleteMyShop()
            end
            
            ShopState.has_active_items = has_active
            ShopState.last_check_time = current_time
        end
    end
end

function onScriptTerminate(script, quit)
    if script == thisScript() then
        log("Завершение работы. Полное сохранение данных...")
        
        -- Сохраняем списки товаров (покупки/продажи)
        saveJsonFile(PATHS.DATA .. 'sell_items.json', Data.sell_list)
        saveJsonFile(PATHS.DATA .. 'buy_items.json', Data.buy_list)
        
        -- Сохраняем кэшированные данные
        saveJsonFile(PATHS.DATA .. 'item_amounts.json', Data.inventory_item_amounts)
        saveJsonFile(PATHS.CACHE .. 'average_prices.json', Data.average_prices)
        saveJsonFile(PATHS.CACHE .. 'scanned_items.json', Data.scanned_items)
        
        -- Сохраняем логи
        saveJsonFile(PATHS.LOGS .. 'transactions.json', Data.transaction_logs)
        
        -- Сохраняем настройки
        saveSettings()
    end
end