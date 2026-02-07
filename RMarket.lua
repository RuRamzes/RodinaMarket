script_name("RMarket")
local SCRIPT_CURRENT_VERSION = "2.8"
script_version(SCRIPT_CURRENT_VERSION)
script_properties("work-in-pause")

local samp_loaded = false
local LOCAL_PLAYER_NICK = nil
local LOCAL_PLAYER_ID = -1

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
local raknet = require 'lib.samp.raknet'
local md5_lib = require 'md5' -- Убедись, что библиотека подключена

local ROOT_PATH = getWorkingDirectory() .. '/RMarket/'

local PATHS = {
    ROOT = ROOT_PATH,
    SETTINGS = ROOT_PATH .. 'settings.json',
    SESSION = ROOT_PATH .. 'session.json',
    -- Данные
    DATA = ROOT_PATH .. 'data/',
    CACHE = ROOT_PATH .. 'cache/',
    LOGS = ROOT_PATH .. 'logs/',
    -- Профили (конфиги) теперь в отдельных папках
    PROFILES_BUY = ROOT_PATH .. 'profiles/buy/',
    PROFILES_SELL = ROOT_PATH .. 'profiles/sell/',
}

-- Стандартные файлы данных (общие списки)
local FILES = {
    ITEMS_DB = PATHS.DATA .. 'items_db.json',
    UNSELLABLE = PATHS.DATA .. 'unsellable.json',
    ITEM_AMOUNTS = PATHS.DATA .. 'item_amounts.json',
    CACHE_SCANNED = PATHS.CACHE .. 'scanned_items.json',
    CACHE_PRICES = PATHS.CACHE .. 'average_prices.json',
    CACHE_BUYABLES = PATHS.CACHE .. 'buyable_items.json',
    CACHE_MARKET = PATHS.CACHE .. 'market_dump.json',
    CURRENT_SELL_LIST = PATHS.DATA .. 'current_sell.json', -- Текущий активный список
    CURRENT_BUY_LIST = PATHS.DATA .. 'current_buy.json'    -- Текущий активный список
}

local RODINA_SERVERS_DATA = {
    { id = "Central",   name = "Центральный", ip = "185.169.134.163", port = "7777", domains = {"central.rodina-rp.com"} },
    { id = "Southern",  name = "Южный",       ip = "185.169.134.60",  port = "8904", domains = {"southern.rodina-rp.com"} },
    { id = "Northern",  name = "Северный",    ip = "185.169.134.62",  port = "8904", domains = {"northern.rodina-rp.com"} },
    { id = "Eastern",   name = "Восточный",   ip = "185.169.134.108", port = "7777", domains = {"eastern.rodina-rp.com"} },
    { id = "Western",   name = "Западный",    ip = "80.66.71.85",     port = "7777", domains = {"western.rodina-rp.com"} },
    { id = "Primorsky", name = "Приморский",  ip = "80.66.82.58",     port = "7777", domains = {"primorsky.rodina-rp.com"} },
    { id = "Federal",   name = "Федеральный", ip = "80.66.82.55",     port = "7777", domains = {"federal.rodina-rp.com"} }
}

-- Таблицы для совместимости с остальным кодом
local SERVER_NAMES = {}
local SERVER_IPS_FIX = {}

-- Автоматическое заполнение таблиц совместимости
for _, srv in ipairs(RODINA_SERVERS_DATA) do
    local full_ip = srv.ip .. ":" .. srv.port
    
    -- Заполняем SERVER_IPS_FIX (ID -> IP)
    SERVER_IPS_FIX[srv.id] = full_ip
    
    -- Заполняем SERVER_NAMES (Все варианты -> Русское имя)
    SERVER_NAMES[full_ip] = srv.name
    SERVER_NAMES[srv.id] = srv.name
    SERVER_NAMES[srv.id:lower()] = srv.name
    
    -- Добавляем домены в SERVER_NAMES
    for _, domain in ipairs(srv.domains) do
        SERVER_NAMES[domain] = srv.name
        SERVER_NAMES[domain .. ":" .. srv.port] = srv.name
    end
end

-- Вспомогательная функция поиска конфигурации сервера
function findServerConfig(input)
    if not input then return nil end
    local s = tostring(input):lower()
    
    -- Очистка от протоколов если вдруг придут
    s = s:gsub("http://", ""):gsub("https://", "")

    for _, srv in ipairs(RODINA_SERVERS_DATA) do
        -- 1. Проверка по ID (например "Central" или "central")
        if s == srv.id:lower() then return srv end
        
        -- 2. Проверка по IP (точное совпадение начала строки)
        if s:find(srv.ip, 1, true) then return srv end
        
        -- 3. Проверка по Доменам
        for _, domain in ipairs(srv.domains) do
            if s:find(domain, 1, true) then return srv end
        end
        
        -- 4. Проверка по Русскому имени
        if s == srv.name:lower() then return srv end
    end
    return nil
end

function getServerDisplayName(serverId)
    local cfg = findServerConfig(serverId)
    return cfg and cfg.name or serverId
end

function normalizeServerId(serverId)
    local cfg = findServerConfig(serverId)
    if cfg then
        -- Всегда возвращаем IP:PORT, так как именно в таком формате хранятся логи
        return cfg.ip .. ":" .. cfg.port
    end
    -- Если сервер не найден в конфиге (например, новый), возвращаем как есть
    return serverId
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
    remote_shop_active = false,
    script_loaded = false,
    live_shop_active = false,
    show_config_selector = false,
    config_copy_pending = false,
    show_config_manager = false,
	show_sell_config_manager = false,
	rename_sell_config_idx = nil,
    render_radius = false,
    live_shop_uid = 0,
	is_busy_remote = false,
	uid_check_complete = false,     -- Проверяли ли мы уже UID в этой сессии
    current_game_uid = 0,           -- Сохраненный UID
    is_auto_checking_stats = false,
    pr_edit_state = {
        active = false,
        index = -1
    },

    -- [NEW] Поля для туториала
    show_tutorial = false,
    tutorial_step = 1
}

local HttpWorker = {
    queue = {},           -- Очередь задач
    current_task = nil,   -- Текущая выполняемая задача
    thread = nil,         -- Объект потока effil
    start_time = 0        -- Время начала задачи (для таймаута)
}

function cleanTextColors(text)
    -- Удаляем стандартные цвета SAMP {FFFFFF}
    local s = text:gsub("{......}", "")
    -- Удаляем цвета Rodina в скобках [FFFFFF]
    s = s:gsub("%[......%]", "")
    -- Удаляем табуляцию и лишние пробелы
    s = s:gsub("\t", " "):gsub("%s+", " ")
    return s
end

-- Функция-воркер, которая будет выполняться в отдельном потоке
function http_thread_func(method, url, args, lib_path, lib_cpath)
    package.path = lib_path
    package.cpath = lib_cpath
    
    -- Защита от краша при загрузке библиотеки в потоке
    local req_ok, requests = pcall(require, 'requests')
    if not req_ok then 
        return false, "Error loading 'requests': " .. tostring(requests) 
    end
    
    -- Убедимся, что таймаут установлен в аргументах
    if not args then args = {} end
    -- [FIX] Увеличили таймаут до 60 секунд, чтобы избежать ошибок при медленном интернете
    if not args.timeout then args.timeout = 60 end 

    local status, result = pcall(requests.request, method, url, args)
    
    if status then
        if result then 
            -- Чистим userdata, чтобы effil мог передать таблицу
            result.json, result.xml = nil, nil 
            if result.headers and type(result.headers) ~= 'table' then
                local safe_headers = {}
                -- Защищенный перебор заголовков
                pcall(function()
                    for k, v in pairs(result.headers) do safe_headers[k] = v end
                end)
                result.headers = safe_headers
            end
        end
        return true, result
    else
        return false, tostring(result)
    end
end

local VipData = {
    top_resale = {},
    last_update = 0,
    is_loading = false,
    selected_item_history = nil, -- Имя выбранного товара
    graph_points = {},           -- Точки графика
    show_graph_modal = false     -- Показать ли окно графика
}

local tabs = {
    {id = 1, name = "Продажа", icon = fa('cart_shopping')},
    {id = 2, name = "Скупка", icon = fa('bag_shopping')},
    {id = 3, name = "Логи", icon = fa('file_lines')},
    {id = 4, name = "Маркет", icon = fa('globe')},
    {id = 7, name = "VIP Аналитика", icon = fa('chart_line')}, -- <--- НОВАЯ ВКЛАДКА ID 7
    {id = 6, name = "Авто-Пиар", icon = fa('bullhorn')}, 
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
	auto_pr = {
        -- Буферы для создания нового сообщения
        add_message = imgui.new.char[4096](), -- Увеличенный лимит
        add_delay = imgui.new.int(60),        -- Точная задержка
        add_channel = imgui.new.int(0),       -- Индекс канала (0 = /vr)
        
        -- Буферы для редактирования
        edit_message = imgui.new.char[4096](),
        edit_delay = imgui.new.int(0),
        edit_channel = imgui.new.int(0)
    },
    cached_items = {},
    unsellable_items = {},
    buyable_items = {},
    current_view_logs = {}, 
    available_log_dates = {}, 
    cef_slots_data = {},
    cef_sell_queue = {},
    cef_inventory_items = {},
    item_names = {},
	item_categories = {},	
    item_names_reversed = {}, 
    average_prices = {},
    inventory_item_amounts = {},
    transaction_logs = {},
    settings = { 
        auto_name_enabled = false,
        shop_name = "Rodina Market",
        ui_scale_mode = 1,
        show_remote_shop_menu = true,
        delay_placement = 100,
        telegram_token = "",
		last_poll_time = 0
    },
    remote_shop_items = {},
    buy_configs = {},
    active_buy_config = 1,
    sell_configs = {},
    active_sell_config = 1
}

local UpdateState = {
    is_outdated = false,
    updater_missing = false,
    remote_version = "",
    -- Ссылка на тему или сайт, откуда качать апдейтер
    website_url = "https://rodina-market.ru/" 
}

-- Вспомогательная функция сравнения версий (как в апдейтере)
function compareVersions(v1, v2)
    if v1 == v2 then return 0 end
    local function split(v)
        local t = {}
        for num in v:gmatch("%d+") do table.insert(t, tonumber(num)) end
        return t
    end
    local a, b = split(v1), split(v2)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x > y then return 1 end
        if x < y then return -1 end
    end
    return 0
end

local function generate_signature(payload_body, timestamp, user_secret)
    -- [FIX] Принудительное приведение к строке для защиты от nil
    local body_str = tostring(payload_body or "")
    local ts_str = tostring(timestamp or os.time())
    local key_str = tostring(user_secret or "")
    
    -- Подписываем: Тело + Время + Секретный Ключ
    local raw_string = body_str .. ts_str .. key_str
    
    -- Убедимся, что md5 библиотека загружена
    if md5_lib then
        return md5_lib.sumhexa(raw_string)
    else
        print("[RMarket] Error: MD5 lib not found")
        return ""
    end
end

function signed_request(method, url, payload_table, callback)
    -- 1. Получаем ключ пользователя из настроек
    local user_token = Data.settings.telegram_token
    
    -- 2. ГЛАВНАЯ ЗАЩИТА: Если ключа нет — прерываем отправку.
    -- Это защищает глобальный рынок от мусора, так как только авторизованные юзеры шлют данные.
    if not user_token or user_token == "" or user_token:len() < 10 then
        print("[RMarket Security] Отмена отправки: Нет Telegram токена")
        return
    end

    local json_body = json.encode(payload_table)
    local timestamp = os.time()
    
    -- 3. Генерируем подпись
    local signature = generate_signature(json_body, timestamp, user_token)
    
    local headers = {
        ["Content-Type"] = "application/json",
        ["X-Timestamp"] = tostring(timestamp),
        ["X-Auth-Key"] = user_token,     -- Отправляем ключ, чтобы сервер нашел юзера
        ["X-Signature"] = signature,     -- Отправляем подпись для проверки целостности
        ["User-Agent"] = "RMarket-Client/2.8"
    }
    
    asyncHttpRequest(method, url, 
        {
            headers = headers,
            data = json_body
        },
        callback
    )
end

function api_CheckUpdate()
    -- 1. Проверяем наличие файла апдейтера рядом со скриптом
    local updater_path = getWorkingDirectory() .. "\\!RMarket_Updater.lua"
    UpdateState.updater_missing = not doesFileExist(updater_path)

    -- 2. Запрашиваем актуальную версию
    local url = "https://raw.githubusercontent.com/RuRamzes/RodinaMarket/main/versions.json?t=" .. os.time()
    
    asyncHttpRequest("GET", url, {},
        function(response)
            if response.status_code == 200 then
                local ok, data = pcall(json.decode, response.text)
                if ok and data and data.latest then
                    UpdateState.remote_version = data.latest
                    
                    -- Если версия на сервере больше текущей
                    if compareVersions(data.latest, SCRIPT_CURRENT_VERSION) > 0 then
                        UpdateState.is_outdated = true
                        
                        -- Если апдейтер отсутствует, принудительно показываем окно предупреждения
                        if UpdateState.updater_missing then
                            App.show_update_alert = true
                        else
                            addToastNotification("Доступно обновление: v" .. data.latest .. "\nВведите /rmupd", "warning", 10.0)
                        end
                    end
                end
            end
        end
    )
end

function isItemDbEmpty()
    return countTable(Data.item_names) < 10
end

local SaveScheduler = {
    lists_dirty = false,
    settings_dirty = false,
    last_save_time = os.clock(),
    SAVE_DELAY = 2.0
}

function scheduleSaveLists()
    SaveScheduler.lists_dirty = true
end

function scheduleSaveSettings()
    SaveScheduler.settings_dirty = true
end

local MarketConfig = {
    HOST = "http://195.133.8.145:3030",
    SYNC_INTERVAL = 60, 
    PING_INTERVAL = 15, 
    LAST_SYNC = 0,
    LAST_PING = 0
}

local Marketplace = {
    username = "",
    enabled = false,
    serverId = 0,
    LavkaUid = 0,
    items_sell = {},
    count_sell = {},
    price_sell = {},
    items_buy = {},
    count_buy = {},
    price_buy = {},
    is_cleared = true,
    publish_sell = false,
    publish_buy = false,
    sessionToken = nil 
}

local MarketData = {
    shops_list = {},      
    selected_shop = nil,  
    last_sent = 0,        
    last_fetch = 0,       
    is_loading = false,
    is_loading_details = false,  
    current_server_id = 0,
    search_buffer = imgui.new.char[128](),
    online_count = 0      
}

local ShopState = {
    has_active_items = false,  
    last_check_time = 0,
    check_interval = 30  
}

local data_indexes = {
    sell_list_by_model_id = {},
    buy_list_by_model_id = {},
    items_by_model_id = {},
    shops_by_nickname = {}
}

function rebuildIndexes()
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

local Buffers = {
    logs_search = imgui.new.char[128](),
    sell_search = imgui.new.char[128](),
    buy_search = imgui.new.char[128](),
	new_sell_config_name = imgui.new.char[128](),
    logs_current_date_idx = 0, 
    logs_dates_cache = {}, 
    input_buffers = {},
    buy_input_buffers = {},
    sell_input_buffers = {},
	pr_input_buffers = {}, 
    log_filters = {
        show_sales = imgui.new.bool(true),
        show_purchases = imgui.new.bool(true),
    },
    settings = {
		low_pc_mode = imgui.new.bool(false),
        shop_name = imgui.new.char[64](),
		telegram_token = imgui.new.char[64](),
        auto_name = imgui.new.bool(false),
		ui_scale_combo = imgui.new.int(1),
		show_remote_shop_menu = imgui.new.bool(true),
		theme_combo = imgui.new.int(0), 
        delay_placement = imgui.new.int(100)
    },
	remote_shop_search = imgui.new.char[128](),
	new_config_name = imgui.new.char[128](),
	config_selected = imgui.new.int(0),
	import_code = imgui.new.char[32](),
    
    -- [ИСПРАВЛЕНО ЗДЕСЬ] Переменные теперь внутри auto_pr
    auto_pr = {
        -- Для добавления
        add_message = imgui.new.char[4096](), -- Увеличенный лимит
        add_delay = imgui.new.int(60),        -- Точная задержка
        add_channel = imgui.new.int(0),       -- 0=/vr, 1=/b, 2=/s
        
        -- Для редактирования (чтобы не использовать те же буферы)
        edit_message = imgui.new.char[4096](),
        edit_delay = imgui.new.int(60),
        edit_channel = imgui.new.int(0)
    }
}

local PR_CHANNELS = {"VIP Чат (/vr)", "НонРП Чат (/b)", "Крик (/s)"}

local ShareState = {
    modal_active = false,
    generated_code = nil,
    config_name = ""
}

local State = {
    stats_requested_by_script = false, -- <--- ДОБАВЛЕНО
    buying_scan = {
        active = false,
        stage = nil,
        current_page = 1,
        all_items = {},
        current_dialog_id = nil
    },
    buying = {
        active = false,
        stage = nil,
        current_item_index = 1,
        items_to_buy = {},
        last_search_name = nil
    },
    smooth_scroll = {
        current = 0.0,
        target = 0.0,
        speed = 18.0,
        wheel_step = 80.0
    },
    log_stats = {
        total_sales = 0,
        total_purchases = 0,
        sales_amount = 0,
        purchases_amount = 0
    },
    avg_scan = {
        active = false,
        processed_count = 0
    },
    inventory_scan = {
        active = false,
        step = 0 
    },
	real_shop_scan = {
        active = false,
        step = 0, 
        waiting_dialog = false
    },
    sell_total = 0,
    buy_total = 0,
    dialog_9_line_count = 0
}

local refreshed_buyables = {}
local refresh_buyables = false
local last_buy_search = ""

local anim_tabs = {
    current_pos = 0.0,
    target_pos = 0.0,
    width = 0.0
}

local button_anim_states = {}
local tab_content_alpha = 1.0
local tab_content_target_alpha = 1.0
local last_active_tab = 1
local sw, sh = getScreenResolution()
local CURRENT_SCALE = 1.0 
local SCALE_MODES = {
    [0] = 0.85,  
    [1] = 1.0,   
    [2] = 1.25   
}
local fa_glyph_ranges = imgui.new.ImWchar[3](fa.min_range, fa.max_range, 0)

function S(value)
    local scaled = math.floor(value * CURRENT_SCALE + 0.5)
    return scaled > 0 and scaled or 1
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
    for word in text:gmatch("%S+") do
        table.insert(tokens, word)
    end
    return tokens
end

function SmartSearch.getMatchScore(query, target)
    if not query or query == "" or not target then return 0 end
    
    -- Приводим к нижнему регистру для нечувствительности к регистру
    local q_norm = to_lower(query) 
    local t_norm = to_lower(target)
    
    -- 1. Полное совпадение
    if q_norm == t_norm then return 100 end
    
    -- 2. Вхождение подстроки (самое важное)
    -- Например: query="подарки", target="новогодние подарки" -> найдет
    local find_start, find_end = t_norm:find(q_norm, 1, true)
    if find_start then
        -- Бонус, если совпадение в начале слова (после пробела или в начале строки)
        if find_start == 1 or t_norm:sub(find_start-1, find_start-1) == " " then
            return 90
        else
            return 80
        end
    end

    -- 3. Исправление раскладки (ghbdtn -> привет)
    local q_fixed = SmartSearch.fixLayout(q_norm)
    if q_fixed ~= q_norm and t_norm:find(q_fixed, 1, true) then
        return 75 
    end

    -- 4. Нечеткий поиск по словам (Levenshtein)
    -- Только если строка длиннее 3 символов, чтобы не искать мусор
    if #q_norm > 3 then
        local q_tokens = SmartSearch.tokenize(q_norm)
        local t_tokens = SmartSearch.tokenize(t_norm)
        
        local total_words_matched = 0
        local fuzzy_penalty = 0

        for _, q_word in ipairs(q_tokens) do
            local best_word_score = 0
            
            for _, t_word in ipairs(t_tokens) do
                if t_word == q_word then
                    best_word_score = 10
                elseif t_word:find(q_word, 1, true) then
                    best_word_score = 8
                elseif #q_word > 3 and #t_word > 3 then
                    local dist = SmartSearch.levenshtein(q_word, t_word)
                    -- Разрешаем 1 ошибку на 3 символа
                    local allowed_errors = math.floor(#q_word / 3) 
                    if dist <= allowed_errors then
                        best_word_score = 6 - dist 
                    end
                end
            end
            
            if best_word_score > 0 then
                total_words_matched = total_words_matched + 1
                fuzzy_penalty = fuzzy_penalty + (10 - best_word_score)
            end
        end

        if total_words_matched == #q_tokens then
            return 60 - fuzzy_penalty 
        end
    end

    return 0
end

local THEME_COLORS = {
    DARK_MODERN = {
        -- Глубокий темно-синий/угольный фон, приятнее для глаз ночью
        bg_main          = imgui.ImVec4(0.06, 0.07, 0.09, 1.00), 
        bg_secondary     = imgui.ImVec4(0.10, 0.11, 0.14, 1.00), 
        bg_tertiary      = imgui.ImVec4(0.14, 0.15, 0.19, 1.00),
        
        -- Акценты: Мягкий фиолетово-синий градиент (основной)
        accent_primary   = imgui.ImVec4(0.48, 0.40, 0.95, 1.00),
        accent_hover     = imgui.ImVec4(0.55, 0.48, 1.00, 1.00), -- Чуть светлее при наведении
        
        accent_secondary = imgui.ImVec4(0.20, 0.65, 0.95, 1.00), -- Голубой
        
        -- Статусы (пастельные тона, не режут глаз)
        accent_success   = imgui.ImVec4(0.35, 0.75, 0.45, 1.00), 
        accent_danger    = imgui.ImVec4(0.85, 0.35, 0.35, 1.00), 
        accent_warning   = imgui.ImVec4(0.95, 0.75, 0.30, 1.00),
        
        -- Текст
        text_primary     = imgui.ImVec4(0.95, 0.96, 0.98, 1.00),
        text_secondary   = imgui.ImVec4(0.65, 0.68, 0.75, 1.00),
        text_hint        = imgui.ImVec4(0.40, 0.44, 0.50, 1.00),
        
        border_light     = imgui.ImVec4(1.00, 1.00, 1.00, 0.06), -- Очень тонкие рамки
    },
    -- НОВАЯ ТЕМА ДЛЯ VIP
    GOLD_LUXURY = {
        bg_main          = imgui.ImVec4(0.05, 0.05, 0.05, 1.00), -- Глубокий черный
        bg_secondary     = imgui.ImVec4(0.10, 0.08, 0.06, 1.00), -- Шоколадный оттенок
        bg_tertiary      = imgui.ImVec4(0.16, 0.14, 0.10, 1.00), 
        accent_primary   = imgui.ImVec4(1.00, 0.84, 0.00, 1.00), -- ЗОЛОТО
        accent_secondary = imgui.ImVec4(0.85, 0.70, 0.20, 1.00), 
        accent_success   = imgui.ImVec4(0.40, 0.90, 0.40, 1.00), 
        accent_danger    = imgui.ImVec4(0.90, 0.20, 0.20, 1.00), 
        accent_warning   = imgui.ImVec4(1.00, 0.60, 0.00, 1.00),
        text_primary     = imgui.ImVec4(1.00, 0.95, 0.80, 1.00), -- Кремовый текст
        text_secondary   = imgui.ImVec4(0.80, 0.75, 0.60, 1.00), 
        text_hint        = imgui.ImVec4(0.50, 0.45, 0.35, 1.00),
        border_light     = imgui.ImVec4(1.00, 0.84, 0.00, 0.20), -- Золотая обводка
    },
    LIGHT_MODERN = {
        bg_main = imgui.ImVec4(0.97, 0.97, 0.99, 1.0),           
        bg_secondary = imgui.ImVec4(0.90, 0.91, 0.94, 1.0),      
        bg_tertiary = imgui.ImVec4(0.85, 0.86, 0.90, 1.0),       
        accent_primary = imgui.ImVec4(0.45, 0.25, 0.85, 1.0),    
        accent_secondary = imgui.ImVec4(0.15, 0.65, 0.95, 1.0),  
        accent_success = imgui.ImVec4(0.10, 0.75, 0.30, 1.0),    
        accent_danger = imgui.ImVec4(0.90, 0.15, 0.25, 1.0),     
        accent_warning = imgui.ImVec4(0.95, 0.60, 0.05, 1.0),    
        text_primary = imgui.ImVec4(0.05, 0.05, 0.10, 1.0),      
        text_secondary = imgui.ImVec4(0.20, 0.20, 0.30, 1.0),    
        text_hint = imgui.ImVec4(0.45, 0.45, 0.55, 1.0),         
        border_light = imgui.ImVec4(0.55, 0.55, 0.65, 1.0),      
        border_accent = imgui.ImVec4(0.45, 0.25, 0.85, 0.4),     
    }
}

local CURRENT_THEME = THEME_COLORS.DARK_MODERN

function applyTheme(theme_name)
    if THEME_COLORS[theme_name] then
        CURRENT_THEME = THEME_COLORS[theme_name]
        if Data.settings then
            Data.settings.current_theme = theme_name
            saveSettings()
        end
    end
end

function lerpColor(col1, col2, t)
    return imgui.ImVec4(
        col1.x + (col2.x - col1.x) * t,
        col1.y + (col2.y - col1.y) * t,
        col1.z + (col2.z - col1.z) * t,
        col1.w + (col2.w - col1.w) * t
    )
end

local sell_total_cache = { value = 0, timestamp = 0 }
local buy_total_cache = { value = 0, timestamp = 0 }
local TOTAL_CACHE_TIME = 0.1 
local toast_notifications = {}

function addToastNotification(message, notification_type, duration)
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

function renderVipAnalyticsTab()
    if VipData.show_graph_modal then renderPriceGraphModal() end

    local w = imgui.GetContentRegionAvail().x
    local h = imgui.GetContentRegionAvail().y
    
    if not Data.is_vip then
        renderVipPromoOverlay("Доступ к аналитике самых прибыльных товаров\nи графиков цен доступен только VIP пользователям.")
        return
    end

    -- 1. ВЕРХНЯЯ ПАНЕЛЬ
    local header_h = S(50)

    if VipData.is_loading then
        imgui.SetCursorPos(imgui.ImVec2(0, h/2 - S(20)))
        centerText(u8"Загрузка данных...")
        if font_fa then 
            imgui.SetWindowFontScale(2.0)
            local icon = fa('spinner')
            local isz = imgui.CalcTextSize(icon)
            imgui.SetCursorPos(imgui.ImVec2((w - isz.x)/2, h/2 + S(10)))
            imgui.TextColored(CURRENT_THEME.accent_primary, icon) 
            imgui.SetWindowFontScale(1.0)
        end
        return
    end

    if #VipData.top_resale == 0 then
        if VipData.last_update == 0 then
            api_GetVipAnalytics('top_resale')
        else
            renderEmptyState(fa('chart_simple'), "Нет данных", "В базе пока нет записей о выгодных перепродажах.")
        end
        return
    end

    -- 2. ЗАГОЛОВКИ
    local sub_header_h = S(30)
    imgui.BeginChild("VipTableHeaders", imgui.ImVec2(w, sub_header_h), false)
        local col1_w = w * 0.40
        local col2_w = w * 0.20
        local col3_w = w * 0.25
        local col4_w = w * 0.15

        local pos1_x = S(15)
        local pos2_x = pos1_x + col1_w
        local pos3_x = pos2_x + col2_w
        local pos4_x = pos3_x + col3_w

        imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_secondary)
        imgui.SetCursorPosX(pos1_x); imgui.Text(u8"ТОВАР / ПРОДАЖА")
        imgui.SameLine(); imgui.SetCursorPosX(pos2_x); imgui.Text(u8"РЕК. СКУПКА")
        imgui.SameLine(); imgui.SetCursorPosX(pos3_x); imgui.Text(u8"ПРОФИТ")
        imgui.SameLine(); imgui.SetCursorPosX(pos4_x); imgui.Text(u8"ОБЪЕМ")
        imgui.PopStyleColor()
        
        local dl = imgui.GetWindowDrawList()
        local p = imgui.GetWindowPos()
        dl:AddLine(imgui.ImVec2(p.x, p.y + sub_header_h - 1), imgui.ImVec2(p.x + w, p.y + sub_header_h - 1), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.border_light))
    imgui.EndChild()

    -- 3. СПИСОК
    local list_h = h - header_h - sub_header_h - S(5)
    
    imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_main)
    imgui.BeginChild("VipResaleList", imgui.ImVec2(w, list_h), true)
        
        local draw_list = imgui.GetWindowDrawList()
        local col1_w = w * 0.40
        local col2_w = w * 0.20
        local col3_w = w * 0.25
        local col4_w = w * 0.15
        local pos1_x = S(15)
        local pos2_x = pos1_x + col1_w
        local pos3_x = pos2_x + col2_w
        local pos4_x = pos3_x + col3_w

        for i, item in ipairs(VipData.top_resale) do
            imgui.PushIDInt(i)
            
            -- [[ ИСПРАВЛЕНИЕ ]]
            -- Фиксируем начальную Y позицию для текущего элемента
            local row_start_y = imgui.GetCursorPosY()
            
            -- Уменьшил высоту строки с 60 до 54 для компактности
            local item_h = S(54) 
            local cur_p = imgui.GetCursorScreenPos()
            
            -- Фон
            local bg_col = (i % 2 == 0) and CURRENT_THEME.bg_secondary or CURRENT_THEME.bg_tertiary
            draw_list:AddRectFilled(cur_p, imgui.ImVec2(cur_p.x + w, cur_p.y + item_h), imgui.ColorConvertFloat4ToU32(bg_col), S(6))
            
            -- Ховер
            if imgui.IsMouseHoveringRect(cur_p, imgui.ImVec2(cur_p.x + w, cur_p.y + item_h)) then
                draw_list:AddRect(cur_p, imgui.ImVec2(cur_p.x + w, cur_p.y + item_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary), S(6), 15, S(1))
            end

            local center_y = cur_p.y + item_h / 2

            -- 1. Товар
            local name_y = cur_p.y + S(8)
            imgui.SetCursorScreenPos(imgui.ImVec2(cur_p.x + pos1_x, name_y))
            imgui.PushFont(font_default)
            imgui.PushClipRect(imgui.ImVec2(cur_p.x + pos1_x, name_y), imgui.ImVec2(cur_p.x + pos2_x - S(10), name_y + S(20)), true)
            imgui.TextColored(CURRENT_THEME.text_primary, u8(item.name))
            imgui.PopClipRect()
            imgui.PopFont()
            
            imgui.SetCursorScreenPos(imgui.ImVec2(cur_p.x + pos1_x, name_y + S(20)))
            imgui.TextColored(CURRENT_THEME.text_hint, u8("Продажа: ") .. formatMoney(item.sell) .. "$")

            -- 2. Скупка
            local buy_price = item.buy
            if buy_price == 0 then buy_price = math.floor(item.sell * 0.7) end
            imgui.SetCursorScreenPos(imgui.ImVec2(cur_p.x + pos2_x, center_y - imgui.GetFontSize()/2))
            imgui.TextColored(CURRENT_THEME.accent_primary, formatMoney(buy_price) .. "$")

            -- 3. Профит
            local profit_y = cur_p.y + S(8)
            imgui.SetCursorScreenPos(imgui.ImVec2(cur_p.x + pos3_x, profit_y))
            if item.profit > 0 then
                imgui.TextColored(CURRENT_THEME.accent_success, "+" .. formatMoney(item.profit) .. "$")
            else
                imgui.TextColored(CURRENT_THEME.text_secondary, u8"~" .. formatMoney(item.sell - buy_price) .. "$")
            end
            
            imgui.SetCursorScreenPos(imgui.ImVec2(cur_p.x + pos3_x, profit_y + S(20)))
            if font_fa then imgui.PushFont(font_fa) end
            if item.tag == 'hot' then
                imgui.TextColored(imgui.ImVec4(1, 0.3, 0.2, 1), fa('fire') .. " " .. u8"Горячий")
            elseif item.tag == 'potential' then
                imgui.TextColored(imgui.ImVec4(0.3, 0.8, 1, 1), fa('gem') .. " " .. u8"Ликвид")
            else
                if font_fa then imgui.PopFont() end
                imgui.TextColored(CURRENT_THEME.text_hint, u8(item.seen or "-"))
                if font_fa then imgui.PushFont(font_fa) end -- hack to balance PopFont below
            end
            if font_fa then imgui.PopFont() end

            -- 4. Объем и график
            local vol_str = tostring(item.vol) .. u8" шт."
            local vol_sz = imgui.CalcTextSize(vol_str)
            imgui.SetCursorScreenPos(imgui.ImVec2(cur_p.x + pos4_x, center_y - vol_sz.y/2))
            imgui.TextColored(CURRENT_THEME.text_secondary, vol_str)
            
            local btn_sz = S(28)
            local btn_x = cur_p.x + w - btn_sz - S(25)
            imgui.SetCursorScreenPos(imgui.ImVec2(btn_x, center_y - btn_sz/2))
            
            if imgui.InvisibleButton("grp_btn_"..i, imgui.ImVec2(btn_sz, btn_sz)) then
                api_GetVipAnalytics('price_history', item.name)
            end
            
            local is_btn_hover = imgui.IsItemHovered()
            local icon_col = is_btn_hover and CURRENT_THEME.accent_primary or CURRENT_THEME.text_hint
            if font_fa then
                imgui.PushFont(font_fa)
                local ico = fa('chart_line')
                local isz = imgui.CalcTextSize(ico)
                draw_list:AddText(imgui.ImVec2(btn_x + (btn_sz-isz.x)/2, center_y - isz.y/2), imgui.ColorConvertFloat4ToU32(icon_col), ico)
                imgui.PopFont()
            end
            if is_btn_hover then imgui.SetTooltip(u8"Показать график цен") end

            -- Кнопка добавить (скрытая)
            imgui.SetCursorScreenPos(cur_p)
            if imgui.InvisibleButton("vip_act_"..i, imgui.ImVec2(w - S(60), item_h)) then
                table.insert(Data.buy_list, {
                    name = item.name, price = buy_price, amount = 1, active = true, index = -1 
                })
                saveListsConfig()
                calculateBuyTotal()
                addToastNotification("Добавлено в скупку: " .. item.name, "success")
            end
            if imgui.IsItemHovered() then imgui.SetTooltip(u8"Нажмите, чтобы добавить в скупку") end

            -- [[ ИСПРАВЛЕНИЕ ]]
            -- Вместо прибавления к текущему курсору (который уехал вниз из-за текста),
            -- мы жестко ставим курсор на (начало_строки + высота_строки + отступ_4px)
            imgui.SetCursorPosY(row_start_y + item_h + S(4))
            
            imgui.PopID()
        end
        
        imgui.Dummy(imgui.ImVec2(0, S(5)))
        
    imgui.EndChild()
    imgui.PopStyleColor()
end

function renderToastNotifications()
    local draw_list = imgui.GetBackgroundDrawList()
    local sw, sh = getScreenResolution()
    local current_time = os.clock()
    local y_offset = sh - 120
    for i = #toast_notifications, 1, -1 do
        local toast = toast_notifications[i]
        local elapsed = current_time - toast.created_at
        local progress = elapsed / toast.duration
        if elapsed < 0.3 then
            toast.alpha = (elapsed / 0.3) * 0.9
        elseif progress > 0.85 then
            toast.alpha = (1.0 - (progress - 0.85) / 0.15) * 0.9
        else
            toast.alpha = 0.9
        end
        if toast.alpha > 0.01 then
            local padding = S(20)
            local text_size = imgui.CalcTextSize(u8(toast.message))
            local width = text_size.x + padding * 2 + S(40)
            local height = text_size.y + padding
            local x = sw - width - S(20)
            local y = y_offset - (height + S(15))
            local bg_color = imgui.ColorConvertFloat4ToU32(
                imgui.ImVec4(CURRENT_THEME.bg_secondary.x, CURRENT_THEME.bg_secondary.y, 
                             CURRENT_THEME.bg_secondary.z, toast.alpha)
            )
            local border_color = imgui.ColorConvertFloat4ToU32(
                imgui.ImVec4(toast.color.x, toast.color.y, toast.color.z, toast.alpha)
            )
            draw_list:AddRectFilled(imgui.ImVec2(x, y), imgui.ImVec2(x + width, y + height), bg_color, S(8))
            draw_list:AddRect(imgui.ImVec2(x, y), imgui.ImVec2(x + width, y + height), border_color, S(8), imgui.DrawCornerFlags.All, S(2))
            local icon_x = x + padding
            local icon_y = y + (height - S(16)) / 2
            local icon_map = {
                success = fa('check_circle'),
                error = fa('circle_exclamation'),
                warning = fa('triangle_exclamation'),
                info = fa('circle_info')
            }
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
    -- [FIX] Синхронизируем количество с инвентарем для ВСЕХ предметов перед подсчетом
    -- Это решает проблему сбивания цены при скролле
    for _, item in ipairs(Data.sell_list) do
        if item.active ~= false then
             local max_inv_amount = getInventoryAmountForItem(item.model_id, item.slot)
             
             -- Если включен авто-максимум, ставим кол-во из инвентаря
             if item.auto_max then 
                 item.amount = max_inv_amount 
             end
             
             -- Если авто-максимум выключен, но мы пытаемся продать больше, чем есть - срезаем
             if not item.auto_max and (item.amount or 0) > max_inv_amount and max_inv_amount > 0 then
                 item.amount = max_inv_amount
             end
             
             -- Обновляем статус наличия
             item.missing = (max_inv_amount == 0)
        end
    end

    local now = os.clock()
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
    if (now - buy_total_cache.timestamp) < TOTAL_CACHE_TIME then
        return buy_total_cache.value
    end
    
    local total = 0
    for _, item in ipairs(Data.buy_list) do
        if item.active ~= false then 
            -- [FIX] Принудительное приведение к числу для защиты от сбоев
            local price = tonumber(item.price) or 0
            local amount = tonumber(item.amount) or 0
            total = total + (price * amount)
        end
    end
    
    State.buy_total = total
    buy_total_cache.value = total
    buy_total_cache.timestamp = now
    return total
end

function ensureDirectories()
    local dirs = {
        PATHS.ROOT, 
        PATHS.DATA, 
        PATHS.CACHE, 
        PATHS.LOGS,
        PATHS.PROFILES_BUY,
        PATHS.PROFILES_SELL
    }
    for _, dir in ipairs(dirs) do
        if not doesDirectoryExist(dir) then
            createDirectory(dir)
        end
    end
end

function loadConfigsFromDir(directory)
    local configs = {}
    if not doesDirectoryExist(directory) then return configs end
    
    for file in lfs.dir(directory) do
        if file ~= "." and file ~= ".." and file:match("%.json$") then
            local full_path = directory .. file
            local data = loadJsonFile(full_path)
            if data then
                data._filename = file -- Запоминаем имя файла для перезаписи/удаления
                table.insert(configs, data)
            end
        end
    end
    
    -- Сортировка по имени для стабильности списка
    table.sort(configs, function(a, b) 
        return (a.name or "") < (b.name or "") 
    end)
    
    return configs
end

-- Сохранение конкретного конфига (профиля)
function saveSingleConfig(directory, config_data)
    if not config_data.name then config_data.name = "Unnamed" end
    
    -- Если это новый конфиг и у него нет имени файла, генерируем
    if not config_data._filename then
        local safe_name = tostring(config_data.name):gsub("[^%w%s%-_]", ""):gsub("%s+", "_")
        if safe_name == "" then safe_name = "config_" .. os.time() end
        config_data._filename = safe_name .. ".json"
    end
    
    local save_path = directory .. config_data._filename
    
    -- Сохраняем только чистые данные
    local data_to_save = {
        name = config_data.name,
        items = config_data.items or {}
    }
    
    saveJsonFile(save_path, data_to_save)
end

function deleteConfigFile(directory, filename)
    if not filename then return end
    local path = directory .. filename
    if doesFileExist(path) then
        os.remove(path)
    end
end

function saveBuyConfigState()
    -- [FIX] Защита: Если скрипт не прогрузился, запрещаем перезапись конфига
    if not App.script_loaded then return end

    -- Синхронизируем текущий список с активным профилем и сохраняем профиль на диск
    if Data.active_buy_config and Data.buy_configs[Data.active_buy_config] then
        Data.buy_configs[Data.active_buy_config].items = {}
        for _, item in ipairs(Data.buy_list) do
            table.insert(Data.buy_configs[Data.active_buy_config].items, item)
        end
        saveSingleConfig(PATHS.PROFILES_BUY, Data.buy_configs[Data.active_buy_config])
    end
end

function loadJsonFile(path, default_value)
    if not doesFileExist(path) then return default_value end
    
    local file = io.open(path, "r")
    if not file then return default_value end
    
    local content = file:read("*a")
    file:close()
    
    if not content or #content == 0 then return default_value end
    
    local status, result = pcall(json.decode, content)
    if not status or result == nil then
        print('[RMarket] JSON Load Error (Corrupted): ' .. path)
        return default_value 
    end
    
    -- [FIX] Защита от неверных типов данных (например, если ожидаем таблицу, а получили число)
    if default_value ~= nil and type(default_value) == "table" and type(result) ~= "table" then
         print('[RMarket] JSON Type Mismatch (Resetting to default): ' .. path)
         return default_value
    end
    
    -- Конвертируем полученные UTF-8 строки обратно в CP1251
    return fromUTF8(result)
end

function saveSessionToken()
    local session_data = { token = Marketplace.sessionToken }
    saveJsonFile(PATHS.SETTINGS .. 'session.json', session_data)
end

function loadSessionToken()
    local path = PATHS.SETTINGS .. 'session.json'
    if doesFileExist(path) then
        local data = loadJsonFile(path, {})
        if data and data.token then
            Marketplace.sessionToken = data.token
            print("[RMarket] Loaded saved session token.")
        end
    end
end

function recursiveUTF8(tbl)
    if type(tbl) ~= "table" then return tbl end
    local res = {}
    for k, v in pairs(tbl) do
        local key = k
        if type(k) == "string" then
            -- Пробуем конвертировать, если не вышло - оставляем как есть
            local s, r = pcall(u8, k)
            if s then key = r end
        end
        
        if type(v) == "table" then
            res[key] = recursiveUTF8(v)
        elseif type(v) == "string" then
            local s, r = pcall(u8, v)
            if s then 
                res[key] = r 
            else
                res[key] = v
            end
        else
            res[key] = v
        end
    end
    return res
end

function toUTF8(tbl)
    if type(tbl) ~= 'table' then
        if type(tbl) == 'string' then return u8(tbl) end
        return tbl
    end
    local res = {}
    for k, v in pairs(tbl) do
        local key = (type(k) == 'string') and u8(k) or k
        res[key] = toUTF8(v)
    end
    return res
end

-- Рекурсивное перекодирование таблицы из UTF-8 в CP1251 (для загрузки)
function fromUTF8(tbl)
    if type(tbl) ~= 'table' then
        if type(tbl) == 'string' then
            -- Пытаемся декодировать, если это валидный UTF-8
            local success, result = pcall(u8.decode, u8, tbl)
            return success and result or tbl
        end
        return tbl
    end
    local res = {}
    for k, v in pairs(tbl) do
        local key = k
        if type(k) == 'string' then
            local s, r = pcall(u8.decode, u8, k)
            if s then key = r end
        end
        res[key] = fromUTF8(v)
    end
    return res
end

-- Обновленная функция сохранения
function saveJsonFile(path, data)
    if not data then return false end
    
    -- Конвертируем таблицу Lua в JSON строку (с UTF-8)
    local utf8_data = toUTF8(data)
    local status, content = pcall(json.encode, utf8_data, { indent = true })
    if not status then 
        print('[RMarket] JSON Encode Error: ' .. path .. ' | ' .. tostring(content))
        return false 
    end

    -- Записываем обычный текст
    local file = io.open(path, "w+")
    if not file then 
        ensureDirectories()
        file = io.open(path, "w+")
        if not file then
            print('[RMarket] File Write Error: ' .. path)
            return false 
        end
    end
    file:write(content)
    file:close()
    return true
end

function saveItemNames()
    -- Сохраняем в новом формате: ID = { n = "Имя", c = "Категория" }
    local db_to_save = {}
    for id, name in pairs(Data.item_names) do
        db_to_save[id] = {
            n = name,
            c = Data.item_categories[id] or "Предмет"
        }
    end
    saveJsonFile(FILES.ITEMS_DB, db_to_save)
end

function loadItemNames()
    local items_file = FILES.ITEMS_DB

    -- Сбрасываем таблицы
    Data.item_names = {}
    Data.item_categories = {}
    Data.item_names_reversed = {}

    -- Используем защищённую функцию загрузки
    -- loadJsonFile УЖЕ возвращает данные в кодировке CP1251 (благодаря fromUTF8 внутри)
    local result = loadJsonFile(items_file, nil)

    if result then
        collectgarbage("stop")

        local start_time = os.clock()
        local chunk_limit = 0.012

        for id, val in pairs(result) do
            local final_name = ""
            local final_cat  = "Предмет"

            -- Поддержка старого и нового формата
            if type(val) == "table" then
                final_name = val.n or ""
                final_cat  = val.c or "Предмет"
            else
                final_name = val
                -- Если формат старый, пытаемся извлечь категорию на лету
                final_cat  = extractCategory(final_name)
                final_name = cleanItemName(final_name)
            end

            -- [FIX] УБРАН БЛОК ПОВТОРНОГО ДЕКОДИРОВАНИЯ (u8.decode)
            -- Так как loadJsonFile уже вернул CP1251, повторное декодирование ломало текст.
            
            local str_id = tostring(id)

            Data.item_names[str_id]      = final_name
            Data.item_categories[str_id] = final_cat

            -- Обратный индекс для быстрого поиска
            if type(final_name) == "string" then
                local clean_key = cleanItemNameKey(final_name)
                Data.item_names_reversed[clean_key] = tonumber(str_id)
            end

            -- Не фризим игру на больших базах
            if os.clock() - start_time > chunk_limit then
                wait(0)
                start_time = os.clock()
            end
        end

        collectgarbage("restart")
    else
        -- Если файл отсутствует или повреждён — создаём пустой
        saveJsonFile(items_file, {})
    end

    print(string.format(
        "[RodinaMarket] Loaded %d items from database.",
        countTable(Data.item_names)
    ))
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

function updateLocalInventoryFromLog(transaction)
    -- Если лавка не активна, нет смысла пересчитывать для отправки
    if not Marketplace.enabled then return end
    
    local updated = false

    -- 1. У нас КУПИЛИ товар (Sale) -> Уменьшаем кол-во в списке продажи
    if transaction.type == "sale" then
        -- А. Обновляем Data.sell_list (локальный конфиг, чтобы в меню скрипта тоже обновилось)
        for _, item in ipairs(Data.sell_list) do
            if item.name == transaction.item and item.active then
                local current = tonumber(item.amount) or 0
                local new_amount = current - transaction.amount
                if new_amount < 0 then new_amount = 0 end
                
                item.amount = new_amount
                
                -- Если товар закончился, ставим пометку
                if new_amount == 0 then item.missing = true end
                break -- Считаем, что имена уникальны для активных товаров
            end
        end

        -- Б. Обновляем Marketplace (таблица, которая улетит на сервер)
        -- Marketplace.items_sell хранит закодированные (u8) имена
        if Marketplace.items_sell then
            for i, name_encoded in ipairs(Marketplace.items_sell) do
                local name_decoded = u8:decode(name_encoded)
                if name_decoded == transaction.item then
                    local current = tonumber(Marketplace.count_sell[i]) or 0
                    local new_val = current - transaction.amount
                    if new_val < 0 then new_val = 0 end
                    
                    Marketplace.count_sell[i] = new_val
                    updated = true
                    break
                end
            end
        end

    -- 2. Мы КУПИЛИ товар в скупке (Purchase) -> Уменьшаем потребность в скупке
    elseif transaction.type == "purchase" then
        -- А. Обновляем Data.buy_list
        for _, item in ipairs(Data.buy_list) do
            if item.name == transaction.item and item.active then
                local is_acc = isAccessory(item.name)
                local current = tonumber(item.amount) or 0
                local new_amount = current - transaction.amount
                if new_amount < 0 then new_amount = 0 end
                
                -- Для аксессуаров часто ставят 0 (любое кол-во), поэтому уменьшаем только если это не акс
                if not is_acc then
                   item.amount = new_amount
                end
                break
            end
        end

        -- Б. Обновляем Marketplace
        if Marketplace.items_buy then
            for i, name_encoded in ipairs(Marketplace.items_buy) do
                local name_decoded = u8:decode(name_encoded)
                if name_decoded == transaction.item then
                    local current = tonumber(Marketplace.count_buy[i]) or 0
                    
                    -- Если это аксессуар (у них обычно скупка по 1 шт в слоте или 0), логика может отличаться,
                    -- но для обычных ресурсов уменьшаем лимит скупки.
                    local new_val = current - transaction.amount
                    if new_val < 0 then new_val = 0 end
                    
                    Marketplace.count_buy[i] = new_val
                    updated = true
                    break
                end
            end
        end
    end

    if updated then
        -- ВАЖНО: Сбрасываем таймер синхронизации.
        -- Это заставит функцию ProcessMarketplaceSync отправить новые данные на сервер 
        -- в следующем кадре (почти мгновенно).
        MarketConfig.LAST_SYNC = 0 
        print("[RMarket] Остатки обновлены по логам. Мгновенная синхронизация...")
        
        -- Также сохраняем локальные конфиги, чтобы при перезаходе кол-во сохранилось
        saveListsConfig()
        calculateSellTotal()
        calculateBuyTotal()
    end
end

function parseShopMessage(text)
    -- 1. Удаляем цветовые коды
    local clean_text = text:gsub("{......}", ""):gsub("%s+$", "")

    -- 2. ГЛАВНАЯ ЗАЩИТА: Сообщение должно НАЧИНАТЬСЯ с [Лавка]
    -- Символ ^ означает начало строки. Если сообщение из VIP чата ([FOREVER]...: [Лавка]), этот чек вернет nil.
    if not clean_text:find("^%[Лавка%]") then return nil end

    -- Убираем префикс [Лавка] для удобства парсинга
    clean_text = clean_text:gsub("^%[Лавка%]%s*", "")

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

    -- === ПАРСИНГ: ИГРОК ПРОДАЛ ВАМ (СКУПКА) ===
    -- Структура: [Ник] продал Вам [Тип] [Название] (N шт.) за [Цена] руб.
    -- Используем .- после "Вам", чтобы пропустить тип (предмет/ларец/ящик) и взять только название
    if clean_text:find("продал Вам") then
        local player, item, amount, total_str = clean_text:match("^(.-)%s+продал Вам%s+.-%s+(.+)%s+%((%d+)%s+шт%.%)%s+за%s+([%d%.%s]+)%s+руб%.")
        
        if player and item and amount and total_str then
            transaction.type = "purchase"
            transaction.player = player
            transaction.item = item
            transaction.amount = tonumber(amount) or 1
            transaction.total = tonumber((total_str:gsub("[%.%s]", ""))) or 0 -- Удаляем точки и пробелы
            
            if transaction.amount > 0 then
                transaction.price = math.floor(transaction.total / transaction.amount)
            else
                transaction.price = transaction.total
            end
            return transaction
        end
    end

    -- === ПАРСИНГ: ИГРОК КУПИЛ У ВАС (ПРОДАЖА) ===
    -- Структура: [Ник] приобрел у Вас [Тип] [Название] [(id: N)] (N шт.) за [Цена] руб.
    if clean_text:find("приобрел у Вас") then
        local player, item, amount, total_str
        
        -- Вариант 1: С наличием ID (например, скины: ...одежда Гимли (муж.) (id: 920) (1 шт.)...)
        -- Мы отсекаем (id: ...) чтобы получить чистое название
        player, item, amount, total_str = clean_text:match("^(.-)%s+приобрел у Вас%s+.-%s+(.+)%s+%(id:%s*%d+%)%s+%((%d+)%s+шт%.%)%s+за%s+([%d%.%s]+)%s+руб%.")
        
        -- Вариант 2: Обычный, если ID не найден
        if not player then
             -- Жадный захват (.+) названия до последней скобки (N шт.)
             player, item, amount, total_str = clean_text:match("^(.-)%s+приобрел у Вас%s+.-%s+(.+)%s+%((%d+)%s+шт%.%)%s+за%s+([%d%.%s]+)%s+руб%.")
        end

        if player and item and amount and total_str then
            transaction.type = "sale"
            transaction.player = player
            transaction.item = item
            transaction.amount = tonumber(amount) or 1
            transaction.total = tonumber((total_str:gsub("[%.%s]", ""))) or 0
            
            if transaction.amount > 0 then
                transaction.price = math.floor(transaction.total / transaction.amount)
            else
                transaction.price = transaction.total
            end
            return transaction
        end
    end
    
    return nil
end

function addTransactionLog(transaction)
    if not transaction then return end

    -- === 1. ОБНОВЛЕНИЕ ОСТАТКОВ ТОВАРА (ЛОКАЛЬНО) ===
    updateLocalInventoryFromLog(transaction)

    -- === 2. СОХРАНЕНИЕ ЛОКАЛЬНОГО ЛОГА ===
    local current_date_str = os.date("%Y-%m-%d")
    local file_path = PATHS.LOGS .. current_date_str .. ".json"
    local day_logs = loadJsonFile(file_path, {})

    table.insert(day_logs, transaction)
    saveJsonFile(file_path, day_logs)

    if App.active_tab == 3 then
        refreshLogDates()
        updateLogView()
    end

    -- === 3. ОТПРАВКА СТАТИСТИКИ НА VPS (ГЛОБАЛЬНЫЙ СБОР) ===
    -- Отправляем ВСЕГДА, даже если нет VIP или токена
    api_SubmitTransaction(transaction)

    -- === 4. TELEGRAM УВЕДОМЛЕНИЕ (ТОЛЬКО ЕСЛИ ЕСТЬ ТОКЕН) ===
    if Data.settings.telegram_token and Data.settings.telegram_token ~= "" then
        sendTelegramNotification(transaction)
    end
end

function formatMoney(amount)
    local left, num, right = string.match(tostring(amount), '^([^%d]*%d)(%d*)(.-)$')
    return left .. (num:reverse():gsub('(%d%d%d)', '%1.'):reverse()) .. right
end

function getSafeLocalNickname()
    -- 1. Если есть подтвержденный ник, возвращаем его
    if LOCAL_PLAYER_NICK then 
        return LOCAL_PLAYER_NICK:gsub("_", " ") 
    end
    
    -- 2. Если нет, пытаемся взять из настроек (кеш)
    if Data.settings.last_nickname and Data.settings.last_nickname ~= "" then
        return Data.settings.last_nickname:gsub("_", " ")
    end
    
    -- 3. Если совсем ничего нет
    return "Unknown Player" 
end

function PrepareMarketplaceData()
    Marketplace.items_sell = {}
    Marketplace.count_sell = {}
    Marketplace.price_sell = {}
    Marketplace.items_buy = {}
    Marketplace.count_buy = {}
    Marketplace.price_buy = {}

    -- Если флаг продажи включен, собираем ВСЕ активные товары из конфига
    if Marketplace.publish_sell and Data.sell_list then
        for _, item in ipairs(Data.sell_list) do
            if item.active and (tonumber(item.price) or 0) > 0 and (tonumber(item.amount) or 0) > 0 then
                table.insert(Marketplace.items_sell, u8:encode(item.name))
                table.insert(Marketplace.count_sell, tonumber(item.amount))
                table.insert(Marketplace.price_sell, tonumber(item.price) or 0)
            end
        end
    end

    -- Если флаг скупки включен, собираем данные
    if Marketplace.publish_buy and Data.buy_list then
        for _, item in ipairs(Data.buy_list) do
            local is_acc = isAccessory(item.name)
            local amount = tonumber(item.amount) or 0
            
            if item.active and (tonumber(item.price) or 0) > 0 and (amount > 0 or is_acc) then
                table.insert(Marketplace.items_buy, u8:encode(item.name))
                table.insert(Marketplace.count_buy, amount)
                table.insert(Marketplace.price_buy, tonumber(item.price) or 0)
            end
        end
    end

    local ip, port = sampGetCurrentServerAddress()
    local my_nick = getSafeLocalNickname()
    
    Marketplace.username = u8:encode(my_nick)
    Marketplace.serverId = normalizeServerId(ip .. ":" .. port)
    
    -- ИСПОЛЬЗУЕМ СОХРАНЕННЫЙ ID. Если его нет, пытаемся получить стандартным способом.
    local res, myId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if LOCAL_PLAYER_ID ~= -1 then
        Marketplace.playerId = LOCAL_PLAYER_ID
    else
        Marketplace.playerId = res and myId or -1
    end
    
    if Marketplace.LavkaUid == 0 then
        Marketplace.LavkaUid = os.time()
    end
end

function ProcessMarketplacePing()
    if not Marketplace.enabled or not Marketplace.sessionToken then return end
    
    local current_time = os.time()
    
    if current_time >= MarketConfig.LAST_PING + MarketConfig.PING_INTERVAL then
        local payload = {
            username = Marketplace.username,
            serverId = Marketplace.serverId,
            token = Marketplace.sessionToken
        }
        
        asyncHttpRequest("POST", MarketConfig.HOST .. "/api/pingMarketplace", 
            {
                headers = {["Content-Type"] = "application/json"},
                data = json.encode(payload)
            },
            function(response)
                if response.status_code == 404 or response.status_code == 403 then
                    print("[RMarket] Session lost. Requesting re-sync.")
                    MarketConfig.LAST_SYNC = 0 
                end
            end
        )
        
        MarketConfig.LAST_PING = current_time
    end
end

function ProcessMarketplaceSync()
    if not Marketplace.enabled then return end

    -- SECURITY: не отправляем, если ник некорректный
    if Marketplace.username == "" or Marketplace.username == "Unknown Player" then
        return
    end
    
    -- [FIX] Проверка токена (ключа Telegram) перед отправкой
    if not Data.settings.telegram_token or #Data.settings.telegram_token < 10 then
        return
    end

    local current_time = os.time()
    if current_time < (MarketConfig.LAST_SYNC + MarketConfig.SYNC_INTERVAL) then
        return
    end

    -- Подготавливаем данные витрины
    PrepareMarketplaceData()

    -- Payload для подписи и отправки
    local payload = {
        username     = Marketplace.username,
        enabled      = true,
        serverId     = Marketplace.serverId,
        -- [FIX] Если токена сессии нет, отправляем пустую строку, чтобы не ломать JSON структуру
        token        = Marketplace.sessionToken or "", 
        playerId     = Marketplace.playerId,
        LavkaUid     = Marketplace.LavkaUid,
        vip          = Data.is_vip or false,
        items_sell   = Marketplace.items_sell,
        count_sell   = Marketplace.count_sell,
        price_sell   = Marketplace.price_sell,
        items_buy    = Marketplace.items_buy,
        count_buy    = Marketplace.count_buy,
        price_buy    = Marketplace.price_buy
    }

    -- Используем защищённый запрос
    signed_request(
        "POST",
        MarketConfig.HOST .. "/api/insertMarketplace",
        payload,
        function(response)
            if response.status_code ~= 200 then
                print("[RMarket] Sync failed, status: " .. tostring(response.status_code))
                return
            end

            local ok, data = pcall(json.decode, response.text)
            if not ok or not data then
                print("[RMarket] Invalid JSON response")
                return
            end

            -- ГЛАВНОЕ ИЗМЕНЕНИЕ: Обновляем токен сессии, если сервер выдал новый
            if data.token and Marketplace.sessionToken ~= data.token then
                Marketplace.sessionToken = data.token
                saveSessionToken() -- Сохраняем на диск
                print("[RMarket] Session established/renewed. Shop is warming up...")
            elseif data.status == 'success' then
                 -- print("[RMarket] Sync OK.") -- Можно раскомментировать для дебага
            end
        end
    )

    MarketConfig.LAST_SYNC = current_time
end

function reconstructInventoryFromCache()
    Data.cef_slots_data = {}
    Data.inventory_item_amounts = {}
    
    -- Если кэш пуст, ничего не делаем
    if not Data.scanned_items or #Data.scanned_items == 0 then return end
    
    print("[RMarket] Восстановление данных инвентаря из кэша...")

    for _, item in ipairs(Data.scanned_items) do
        if item.slot and item.model_id then
            local slot = tonumber(item.slot)
            local model = tonumber(item.model_id)
            local amount = tonumber(item.amount) or 1
            
            -- Восстанавливаем технические данные слота
            Data.cef_slots_data[slot] = {
                model_id = model,
                slot = slot,
                amount = amount,
                available = 1, -- Считаем доступным, раз он был в кэше
                text = item.text,
                time = item.time
            }
            
            -- Восстанавливаем общие количества
            local s_id = tostring(model)
            Data.inventory_item_amounts[s_id] = (Data.inventory_item_amounts[s_id] or 0) + amount
        end
    end

    -- Обновляем статусы "НЕТ В ИНВЕНТАРЕ" для списка продажи
    for _, sell_item in ipairs(Data.sell_list) do
        if sell_item.model_id then
            -- Проверяем наличие
            local max_inv = getInventoryAmountForItem(sell_item.model_id, sell_item.slot)
            
            -- Если предмет нашелся, убираем метку missing
            if max_inv > 0 then
                sell_item.missing = false
                
                -- Если включен авто-макс, обновляем кол-во
                if sell_item.auto_max then
                    sell_item.amount = max_inv
                end
            else
                sell_item.missing = true
            end
        end
    end
    
    calculateSellTotal()
end

function loadAllData()
    lua_thread.create(function()
        collectgarbage("stop")

        ensureDirectories()
        wait(0)

        -- ===============================
        -- ЗАГРУЗКА НАСТРОЕК
        -- ===============================
        local loaded_settings = loadJsonFile(PATHS.SETTINGS, {})

        Data.settings.auto_name_enabled      = loaded_settings.auto_name_enabled or false
        Data.settings.shop_name              = loaded_settings.shop_name or "Rodina Market"
        Data.settings.ui_scale_mode          = loaded_settings.ui_scale_mode or 1
        Data.settings.show_remote_shop_menu  = loaded_settings.show_remote_shop_menu ~= false
        Data.settings.current_theme          = loaded_settings.current_theme or "DARK_MODERN"
        Data.settings.delay_placement        = loaded_settings.delay_placement or 100
        Data.settings.telegram_token         = loaded_settings.telegram_token or ""
        Data.settings.tutorial_completed     = loaded_settings.tutorial_completed or false
        Data.settings.low_pc_mode            = loaded_settings.low_pc_mode or false
        Data.is_vip                          = loaded_settings.is_vip or false

        Data.settings.last_nickname = loaded_settings.last_nickname or nil
        if Data.settings.last_nickname and Data.settings.last_nickname ~= "" then
            LOCAL_PLAYER_NICK = Data.settings.last_nickname
            print("[RMarket] Авторизация: Ник загружен из файла (" .. LOCAL_PLAYER_NICK .. ")")
        end

        local loaded_pr = loaded_settings.auto_pr or {}
        Data.auto_pr = {
            active = loaded_pr.active or false,
            messages = {},
            current_index = 1,
            next_send_time = 0,
            last_vr_time = 0
        }

        if loaded_pr.messages and type(loaded_pr.messages) == "table" then
            for _, msg in ipairs(loaded_pr.messages) do
                if type(msg) == "string" then
                    table.insert(Data.auto_pr.messages, { text = msg, channel = 1, delay = 60, active = true })
                elseif type(msg) == "table" then
                    table.insert(Data.auto_pr.messages, {
                        text = msg.text or "", channel = msg.channel or 1, delay = msg.delay or 60, active = msg.active ~= false
                    })
                end
            end
        end

        if Data.settings.telegram_token ~= "" then
            lua_thread.create(function() wait(2000) checkVipStatus(Data.settings.telegram_token) end)
        end

        Buffers.settings.auto_name[0]              = Data.settings.auto_name_enabled
        Buffers.settings.low_pc_mode[0]            = Data.settings.low_pc_mode
        Buffers.settings.ui_scale_combo[0]         = Data.settings.ui_scale_mode
        Buffers.settings.show_remote_shop_menu[0]  = Data.settings.show_remote_shop_menu
        Buffers.settings.delay_placement[0]        = Data.settings.delay_placement
        Buffers.settings.theme_combo[0]            = (Data.settings.current_theme == "LIGHT_MODERN") and 1 or (Data.settings.current_theme == "GOLD_LUXURY" and 2 or 0)

        imgui.StrCopy(Buffers.settings.shop_name, Data.settings.shop_name)
        imgui.StrCopy(Buffers.settings.telegram_token, Data.settings.telegram_token)

        if not Data.settings.tutorial_completed then
            App.show_tutorial = true
            App.win_state[0] = true
        end

        wait(0)
        loadItemNames()
        wait(0)

        Data.buy_configs = loadConfigsFromDir(PATHS.PROFILES_BUY)
        if #Data.buy_configs == 0 then createBuyConfig("Основная") end
        Data.active_buy_config = 1

        Data.sell_configs = loadConfigsFromDir(PATHS.PROFILES_SELL)
        if #Data.sell_configs == 0 then createSellConfig("Основная") end
        Data.active_sell_config = 1

        -- [FIX] Безопасная загрузка списков
        Data.sell_list = loadJsonFile(FILES.CURRENT_SELL_LIST, {})
        if type(Data.sell_list) ~= "table" then Data.sell_list = {} end

        Data.buy_list  = loadJsonFile(FILES.CURRENT_BUY_LIST, {})
        if type(Data.buy_list) ~= "table" then Data.buy_list = {} end
        wait(0)

        if #Data.sell_list == 0 and Data.sell_configs[1] and #Data.sell_configs[1].items > 0 then
            Data.sell_list = {}
            for _, item in ipairs(Data.sell_configs[1].items) do table.insert(Data.sell_list, item) end
        end

        if #Data.buy_list == 0 and Data.buy_configs[1] and #Data.buy_configs[1].items > 0 then
            Data.buy_list = {}
            for _, item in ipairs(Data.buy_configs[1].items) do table.insert(Data.buy_list, item) end
        end

        -- МИГРАЦИЯ ИМЕН
        local function migrateListNames(list)
            if type(list) ~= "table" then return end
            for _, item in ipairs(list) do
                if item and item.name then item.name = cleanItemName(item.name) end
            end
        end

        migrateListNames(Data.sell_list)
        migrateListNames(Data.buy_list)
        for _, cfg in ipairs(Data.buy_configs) do migrateListNames(cfg.items) end
        for _, cfg in ipairs(Data.sell_configs) do migrateListNames(cfg.items) end

        saveListsConfig(true)
        saveBuyConfigs()
        saveSellConfigs()

        rebuildIndexes()
        wait(0)

        Data.unsellable_items = loadJsonFile(FILES.UNSELLABLE, {})
        Data.cached_items     = loadJsonFile(PATHS.CACHE .. 'cached_items.json', {})
        Data.scanned_items    = loadJsonFile(FILES.CACHE_SCANNED, {})
        if type(Data.scanned_items) ~= "table" then Data.scanned_items = {} end
        reconstructInventoryFromCache()

        Data.average_prices   = loadJsonFile(FILES.CACHE_PRICES, {})
        Data.buyable_items    = loadJsonFile(FILES.CACHE_BUYABLES, {})
        if type(Data.buyable_items) ~= "table" then Data.buyable_items = {} end

        refresh_buyables = true
        refreshLogDates()

        api_FetchMarketList()
        loadLocalMarketCache() -- [FIX] Добавил загрузку кэша с проверками
        loadSessionToken()
        loadLiveShopState()

        collectgarbage("restart")
        collectgarbage("step", 2000)

        App.script_loaded = true

        if Data.settings.current_theme then applyTheme(Data.settings.current_theme) end
        api_CheckUpdate()

        print("[RodinaMarket] Data loaded safely.")
    end)
end

function getUniqueFingerprint()
    local ip, port = sampGetCurrentServerAddress()
    local nick = getSafeLocalNickname() -- Ваша функция получения ника
    -- Отпечаток: Nickname@IP:PORT (Привязка к аккаунту и серверу)
    return string.format("%s@%s:%s", nick, ip, port)
end

function loadLocalMarketCache()
    local cache_path = PATHS.CACHE .. 'market_dump.json'
    if not doesFileExist(cache_path) then return end

    local data = loadJsonFile(cache_path, nil)
    if not data or type(data) ~= "table" then return end

    MarketData.shops_list = {}
    for _, shop in ipairs(data) do
        local s_list = {}
        if shop.items_sell and type(shop.items_sell) == "table" then
            for k, v in ipairs(shop.items_sell) do
                local safe_name = safe_decode(v)
                table.insert(s_list, {
                    name = safe_name, 
                    amount = shop.count_sell and shop.count_sell[k] or 0,
                    price = shop.price_sell and shop.price_sell[k] or 0
                })
            end
        end

        local b_list = {}
        if shop.items_buy and type(shop.items_buy) == "table" then
            for k, v in ipairs(shop.items_buy) do
                local safe_name = safe_decode(v)
                table.insert(b_list, {
                    name = safe_name,
                    amount = shop.count_buy and shop.count_buy[k] or 0,
                    price = shop.price_buy and shop.price_buy[k] or 0
                })
            end
        end

        local raw_nick = shop.user or shop.username
        local safe_nick = safe_decode(raw_nick)
        
        -- [FIX] Безопасное получение количества
        local sell_c = shop.sell or ((type(shop.items_sell) == 'table') and #shop.items_sell) or 0
        local buy_c  = shop.buy or ((type(shop.items_buy) == 'table') and #shop.items_buy) or 0
        
        table.insert(MarketData.shops_list, {
            nickname = safe_nick,
            serverId = shop.id or shop.serverId,
            vip = shop.vip or false,
            sell_count = sell_c,
            buy_count = buy_c,
            shop_name = "Лавка " .. tostring(safe_nick),
            sell_list = s_list,
            buy_list = b_list
        })
    end
    MarketData.online_count = #MarketData.shops_list
    MarketData.last_fetch = os.time()
    print("[RodinaMarket] Загружен локальный кэш лавок: " .. MarketData.online_count)
end

function sendTelegramNotification(transaction)
    if not Data.settings.telegram_token or Data.settings.telegram_token == "" then return end

    local current_money = getPlayerMoney()

    local current_date_str = os.date("%Y-%m-%d")
    local day_logs = loadLogsForDate(current_date_str) 
    
    local earned_today = 0
    local spent_today = 0
    
    for _, log in ipairs(day_logs) do
        if log.type == "sale" then
            earned_today = earned_today + (log.total or 0)
        elseif log.type == "purchase" then
            spent_today = spent_today + (log.total or 0)
        end
    end

    local profit_today = earned_today - spent_today

    local payload = {
        secret_key = Data.settings.telegram_token,
        data = {
            type = transaction.type,
            player = u8:encode(transaction.player), 
            item = u8:encode(transaction.item),
            amount = transaction.amount,
            price = transaction.price,
            total = transaction.total,
            server = Marketplace.serverId or "",
            balance = current_money,
            earned = earned_today,
            spent = spent_today,
            profit = profit_today
        }
    }

    -- ЗАМЕНИТЕ IP_ВАШЕГО_VPS на реальный IP адрес (например: http://45.12.34.56:3000/notify)
    -- Не забудьте открыть порт 3000 на VPS (ufw allow 3000)
    asyncHttpRequest("POST", "http://195.133.8.145:3040/notify", 
        {
            headers = {["Content-Type"] = "application/json"},
            data = json.encode(payload)
        },
        function(response)
            if response.status_code ~= 200 then
                print("[RMarket] Ошибка отправки VPS (" .. response.status_code .. "): " .. tostring(response.text))
            end
        end
    )
end

-- Хелпер для парсинга цен Родины (355.9к, 1.5кк)
function parseRodinaPrice(text)
    if not text or type(text) ~= "string" or text == "" then return 0 end
    
    -- Удаляем " р.", "р.", пробелы
    local clean = text:gsub(" р%.", ""):gsub(" р", ""):gsub("%s+", "")
    
    local multiplier = 1
    
    -- Проверка на миллиарды (ккк)
    if clean:find("ккк") or clean:find("kkk") or clean:find("KKK") then 
        multiplier = 1000000000
        clean = clean:gsub("ккк", ""):gsub("kkk", ""):gsub("KKK", "")
    -- Проверка на миллионы (кк, м, m)
    elseif clean:find("кк") or clean:find("kk") or clean:find("KK") or clean:find("м") or clean:find("m") then
        multiplier = 1000000
        clean = clean:gsub("кк", ""):gsub("kk", ""):gsub("KK", ""):gsub("м", ""):gsub("m", "")
    -- Проверка на тысячи (к, k)
    elseif clean:find("к") or clean:find("k") or clean:find("K") then
        multiplier = 1000
        clean = clean:gsub("к", ""):gsub("k", ""):gsub("K", "")
    end
    
    -- Заменяем запятую на точку и оставляем только цифры и точку
    local num_str = clean:gsub(",", ".")
    -- Извлекаем число (включая дробную часть)
    local num = tonumber(num_str) or 0
    
    return math.floor(num * multiplier)
end

function api_SyncInventory()
    -- Отправляем только если есть токен
    if Data.settings.telegram_token == "" then 
        print("[RMarket] Error: No token for sync")
        return 
    end
    
    print("[RMarket] Preparing inventory for cloud sync...")
    
    -- Формируем легкий список для отправки
    local inv_payload = {}
    for _, item in ipairs(Data.scanned_items) do
        -- Конвертируем имя из CP1251 в UTF-8 для веба
        local safe_name = item.name
        if u8 then
            safe_name = u8(item.name) -- u8(str) кодирует в UTF-8
        end

        table.insert(inv_payload, {
            name = safe_name,
            model_id = item.model_id,
            amount = item.amount,
            slot = item.slot,
            is_blocked = item.is_blocked
        })
    end
    
    local payload = {
        secret_key = Data.settings.telegram_token,
        inventory = inv_payload
    }
    
    print("[RMarket] Sending " .. #inv_payload .. " items to server...")

    asyncHttpRequest("POST", MarketConfig.HOST .. "/api/sync_inventory.php", 
        {
            headers = {["Content-Type"] = "application/json"},
            data = json.encode(payload)
        },
        function(response)
            if response.status_code == 200 then
                print("[RMarket] Inventory synced successfully!")
                addToastNotification("Инвентарь отправлен в MiniApp", "success")
            else
                print("[RMarket] Sync Error: " .. response.status_code .. " | " .. tostring(response.text))
            end
        end,
        function(err)
            print("[RMarket] Sync Connection Failed: " .. tostring(err))
        end
    )
end

function api_GetVipAnalytics(action, item_name)
    if not Data.is_vip then 
        addToastNotification("Функция доступна только для VIP", "error")
        return 
    end

    local ip, port = sampGetCurrentServerAddress()
    local server_id = normalizeServerId(ip .. ":" .. port)
    local url = MarketConfig.HOST .. "/api/proxy/vip_analytics?secret_key=" .. Data.settings.telegram_token .. "&server=" .. url_encode(server_id) .. "&action=" .. action
    
    if item_name then
        -- Данные внутри скрипта в CP1251, кодируем в UTF-8 для веба
        local utf8_name = u8:encode(item_name)
        url = url .. "&item=" .. url_encode(utf8_name)
    end

    VipData.is_loading = true
    
    asyncHttpRequest("GET", url, {}, 
        function(response)
            VipData.is_loading = false
            if response.status_code == 200 then
                local ok, data = pcall(json.decode, response.text)
                if ok and data then
                    if data.error == 'vip_required' then
                        Data.is_vip = false
                        addToastNotification("VIP статус истек или недействителен", "error")
                        return
                    end

                    if action == 'top_resale' then
                        VipData.top_resale = {}
                        for _, item in ipairs(data) do
                            -- JSON возвращает UTF-8. Конвертируем в CP1251 для хранения в памяти скрипта
                            -- (потому что весь скрипт работает на encoding.default = 'CP1251')
                            local name_cp1251 = item.name
                            if u8 then
                                local s, r = pcall(u8.decode, u8, item.name)
                                if s then name_cp1251 = r end
                            end
                            item.name = name_cp1251
                            table.insert(VipData.top_resale, item)
                        end
                        VipData.last_update = os.time()
                        
                    elseif action == 'price_history' then
                        VipData.graph_points = data
                        VipData.selected_item_history = item_name
                        VipData.show_graph_modal = true
                    end
                end
            else
                addToastNotification("Ошибка сервера: " .. response.status_code, "error")
            end
        end,
        function(err) 
            VipData.is_loading = false 
            addToastNotification("Ошибка соединения с аналитикой", "error")
        end
    )
end

function renderPriceGraphModal()
    if not VipData.show_graph_modal then return end

    local sw, sh = getScreenResolution()
    local modal_w, modal_h = S(550), S(400)
    
    imgui.SetNextWindowPos(imgui.ImVec2(sw/2, sh/2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(modal_w, modal_h), imgui.Cond.Always)
    
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleColor(imgui.Col.WindowBg, CURRENT_THEME.bg_main)
    
    if imgui.Begin("##PriceGraphModal", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse) then
        local dl = imgui.GetWindowDrawList()
        local p = imgui.GetCursorScreenPos()
        local w = imgui.GetWindowWidth()
        local h = imgui.GetWindowHeight()
        
        -- Хедер
        local header_h = S(50)
        dl:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + header_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary), S(10), 5)
        
        -- Закрыть
        local close_sz = S(30)
        local close_x = p.x + w - close_sz - S(10)
        local close_y = p.y + (header_h - close_sz)/2
        
        imgui.SetCursorScreenPos(imgui.ImVec2(close_x, close_y))
        if imgui.InvisibleButton("##cls_grp", imgui.ImVec2(close_sz, close_sz)) then
            VipData.show_graph_modal = false
        end
        if font_fa then
            imgui.PushFont(font_fa)
            local ic = fa('xmark')
            local isz = imgui.CalcTextSize(ic)
            dl:AddText(imgui.ImVec2(close_x + (close_sz-isz.x)/2, close_y + (close_sz-isz.y)/2), imgui.ColorConvertFloat4ToU32(imgui.IsItemHovered() and CURRENT_THEME.accent_danger or CURRENT_THEME.text_secondary), ic)
            imgui.PopFont()
        end
        
        local title = u8("История цен: ") .. u8(VipData.selected_item_history or "Товар")
        dl:AddText(imgui.ImVec2(p.x + S(15), p.y + S(15)), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary), title)
        
        -- График
        local graph_x = p.x + S(15)
        local graph_y = p.y + header_h + S(15)
        local graph_w = w - S(30)
        local graph_h = h - header_h - S(30)
        
        dl:AddRectFilled(imgui.ImVec2(graph_x, graph_y), imgui.ImVec2(graph_x + graph_w, graph_y + graph_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_tertiary), S(8))
        
        if #VipData.graph_points < 2 then
            local txt = u8"Недостаточно данных"
            local tsz = imgui.CalcTextSize(txt)
            dl:AddText(imgui.ImVec2(graph_x + (graph_w-tsz.x)/2, graph_y + (graph_h-tsz.y)/2), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint), txt)
        else
            local min_p, max_p = 2000000000, 0
            for _, pt in ipairs(VipData.graph_points) do
                local val = tonumber(pt.price) or 0
                if val < min_p then min_p = val end
                if val > max_p then max_p = val end
            end
            if max_p == min_p then max_p = max_p + 100; min_p = math.max(0, min_p - 100) end
            
            local pad_x = S(20)
            local pad_y = S(20)
            local draw_w = graph_w - pad_x * 2
            local draw_h = graph_h - pad_y * 2
            local points_count = #VipData.graph_points
            local step_x = draw_w / (points_count - 1)
            
            local prev_x, prev_y
            
            for i, pt in ipairs(VipData.graph_points) do
                local val = tonumber(pt.price) or 0
                local norm_y = (val - min_p) / (max_p - min_p)
                local x = graph_x + pad_x + (i - 1) * step_x
                local y = graph_y + graph_h - pad_y - (norm_y * draw_h)
                
                if prev_x then
                    dl:AddLine(imgui.ImVec2(prev_x, prev_y), imgui.ImVec2(x, y), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary), S(2))
                end
                
                dl:AddCircleFilled(imgui.ImVec2(x, y), S(4), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary))
                
                if points_count < 8 or (i % 2 == 1) then
                    local date_str = pt.label or "?"
                    local dsz = imgui.CalcTextSize(date_str)
                    dl:AddText(imgui.ImVec2(x - dsz.x/2, graph_y + graph_h - pad_y + S(5)), 0xFF808080, date_str)
                end
                
                if imgui.IsMouseHoveringRect(imgui.ImVec2(x - S(10), graph_y), imgui.ImVec2(x + S(10), graph_y + graph_h)) then
                    dl:AddLine(imgui.ImVec2(x, graph_y + pad_y), imgui.ImVec2(x, graph_y + graph_h - pad_y), 0x40FFFFFF, 1)
                    
                    local price_str = formatMoney(val) .. " $"
                    local psz = imgui.CalcTextSize(price_str)
                    local tip_padding = S(6)
                    local tip_w = psz.x + tip_padding * 2
                    
                    -- Позиция подсказки
                    local tip_draw_x = x - tip_w / 2
                    local tip_draw_y = y - S(30)
                    
                    -- [FIX] Ограничение по границам (Clamping)
                    if tip_draw_x < graph_x + S(5) then tip_draw_x = graph_x + S(5) end
                    if tip_draw_x + tip_w > graph_x + graph_w - S(5) then tip_draw_x = graph_x + graph_w - tip_w - S(5) end
                    if tip_draw_y < graph_y + S(5) then tip_draw_y = y + S(15) end -- Если вылезает вверх, рисуем снизу точки
                    
                    local tip_bg = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.1, 0.1, 0.1, 0.95))
                    
                    dl:AddRectFilled(imgui.ImVec2(tip_draw_x, tip_draw_y), imgui.ImVec2(tip_draw_x + tip_w, tip_draw_y + psz.y + tip_padding * 2), tip_bg, S(4))
                    dl:AddText(imgui.ImVec2(tip_draw_x + tip_padding, tip_draw_y + tip_padding), 0xFFFFFFFF, price_str)
                end
                
                prev_x, prev_y = x, y
            end
        end
    end
    imgui.End()
    imgui.PopStyleColor()
    imgui.PopStyleVar()
end

function api_SubmitShopScan(items)
    if #items == 0 then return end
    
    local ip, port = sampGetCurrentServerAddress()
    local server_id = normalizeServerId(ip .. ":" .. port)
    local my_nick = getSafeLocalNickname()

    local payload = {
        server = server_id,
        scanner = u8:encode(my_nick),
        items = items
    }

    -- Отправляем через прокси
    asyncHttpRequest("POST", MarketConfig.HOST .. "/api/proxy/submit_shop_scan", 
        {
            headers = {["Content-Type"] = "application/json"},
            data = json.encode(payload)
        },
        function(response)
            if response.status_code == 200 then
                -- print("[RMarket] Данные о ценах (" .. #items .. " шт) успешно отправлены.")
            else
                print("[RMarket] Ошибка отправки цен: " .. response.status_code)
            end
        end
    )
end

function api_TestTelegramToken(token)
    if not token or token == "" then return end
    
    -- Запускаем в потоке, чтобы можно было использовать wait
    lua_thread.create(function()
        addToastNotification("Проверка ключа...", "info")
        
        -- [FIX] Принудительно обновляем ник перед отправкой через stats
        if LOCAL_PLAYER_NICK == nil then
            State.stats_requested_by_script = true
            sampSendChat("/stats")
            -- Ждем обработки диалога
            local attempts = 0
            while LOCAL_PLAYER_NICK == nil and attempts < 30 do
                wait(100)
                attempts = attempts + 1
            end
        end
        
        -- Получаем ник (теперь он должен быть английским)
        local current_nick = getSafeLocalNickname()
        
        -- Последняя страховка: если ник все еще Unknown, пробуем стандартный метод, но это маловероятно
        if current_nick == "Unknown Player" then
            local _, myId = sampGetPlayerIdByCharHandle(PLAYER_PED)
            local nick = sampGetPlayerNickname(myId)
            if nick then current_nick = nick:gsub("_", " ") end
        end
        
        local payload = {
            secret_key = token,
            nickname = u8:encode(current_nick) -- Отправляем правильный ник
        }

        asyncHttpRequest("POST", MarketConfig.HOST .. "/api/proxy/test_tg", 
            {
                headers = {["Content-Type"] = "application/json"},
                data = json.encode(payload)
            },
            function(response)
                if response.status_code == 200 then
                    local ok, res = pcall(json.decode, response.text)
                    if ok and res.status == 'success' then
                        local was_vip = Data.is_vip
                        Data.is_vip = res.is_vip or false
                        saveSettings(true)
                        
                        local vip_text = ""
                        if Data.is_vip then 
                            vip_text = " (VIP АКТИВИРОВАН)" 
                        end
                        addToastNotification("Ключ привязан к: " .. current_nick .. vip_text, "success", 5.0)
                        
                        -- Просим сервер обновить ник в БД, если он вдруг был пустым
                        checkVipStatus(token) 
                        
                    elseif ok and res.message then
                        addToastNotification("Ошибка: " .. u8:decode(res.message), "error", 6.0)
                    else
                        addToastNotification("Ошибка ответа сервера", "error")
                    end
                elseif response.status_code == 403 then
                    addToastNotification("Ошибка: Неверный ключ!", "error")
                else
                    addToastNotification("Ошибка соединения: " .. response.status_code, "error")
                end
            end,
            function(err)
                addToastNotification("Ошибка запроса", "error")
            end
        )
    end)
end

function initializeLocalPlayer()
    local res, myId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    if not res then return false end
    
    local raw_nick = sampGetPlayerNickname(myId)
    if raw_nick then
        -- Преобразуем Name_Surname в Name Surname для внутреннего использования
        local clean_nick = raw_nick:gsub("_", " ")
        
        LOCAL_PLAYER_NICK = clean_nick
        LOCAL_PLAYER_ID = myId
        
        -- Проверяем, совпадает ли ник с сохраненным
        if Data.settings.last_nickname ~= clean_nick then
            print("[RMarket] Обнаружен новый никнейм. Обновление записи...")
            Data.settings.last_nickname = clean_nick
            -- Если ник новый, сбрасываем VIP статус до проверки
            -- Data.is_vip = false 
            saveSettings(true)
            
            -- Для нового ника полезно пробить stats для обновления данных API
            State.stats_requested_by_script = true
            sampSendChat("/stats")
        else
            print("[RMarket] Быстрая авторизация успешна: " .. clean_nick)
        end
        return true
    end
    return false
end

function saveSettings(force)
    if not force then
        scheduleSaveSettings()
        return
    end

    local status, err = pcall(function()
        -- ===============================
        -- ОСНОВНЫЕ НАСТРОЙКИ
        -- ===============================
        Data.settings.auto_name_enabled     = Buffers.settings.auto_name[0]
        Data.settings.shop_name             = ffi.string(Buffers.settings.shop_name)
        Data.settings.ui_scale_mode         = Buffers.settings.ui_scale_combo[0]
        Data.settings.show_remote_shop_menu = Buffers.settings.show_remote_shop_menu[0]
        Data.settings.delay_placement       = Buffers.settings.delay_placement[0]
        Data.settings.telegram_token        = ffi.string(Buffers.settings.telegram_token)
        Data.settings.low_pc_mode           = Buffers.settings.low_pc_mode[0]
        
        -- [NEW] Сохраняем текущий ник, если он определен
        if LOCAL_PLAYER_NICK then
            Data.settings.last_nickname = LOCAL_PLAYER_NICK
        end

        if Buffers.settings.theme_combo[0] == 1 then
            Data.settings.current_theme = "LIGHT_MODERN"
        else
            Data.settings.current_theme = "DARK_MODERN"
        end

        -- ===============================
        -- AUTO PR (ИСПРАВЛЕНО)
        -- ===============================
        -- Убрали старые привязки к delay_min/max, так как теперь настройки внутри каждого сообщения
        Data.settings.auto_pr = Data.auto_pr
        
        -- ===============================
        -- СОХРАНЕНИЕ
        -- ===============================
        saveJsonFile(PATHS.SETTINGS, Data.settings)
    end)

    if not status then
        print('[RodinaMarket] Ошибка сохранения настроек: ' .. tostring(err))
    end
end

function saveListsConfig(force)
    if not force then
        scheduleSaveLists()
        return
    end

    -- Очистка списков от пустых значений
    local valid_sell_list = {}
    for _, item in ipairs(Data.sell_list) do
        if item and item.name then  
            if item.active == nil then item.active = true end
            table.insert(valid_sell_list, item)
        end
    end
    Data.sell_list = valid_sell_list
    
    local valid_buy_list = {}
    for _, item in ipairs(Data.buy_list) do
        if item and item.name then  
            if item.active == nil then item.active = true end
            table.insert(valid_buy_list, item)
        end
    end
    Data.buy_list = valid_buy_list
    
    -- 1. Сохраняем "Текущее состояние" (current_buy.json / current_sell.json)
    -- Это нужно, чтобы при перезаходе восстановился именно тот список, который был на экране
    saveJsonFile(FILES.CURRENT_SELL_LIST, Data.sell_list)
    saveJsonFile(FILES.CURRENT_BUY_LIST, Data.buy_list)
    
    -- 2. Сохраняем состояние в активные профили (files inside profiles/...)
    saveBuyConfigState() 
    saveSellConfigState()
    
    rebuildIndexes()
end

function lerp(a, b, t) 
    return a + (b - a) * t 
end

local SmoothScrollStates = {}

function triggerScrollToBottom(window_id)
    if SmoothScrollStates[window_id] then
        -- Ставим счетчик на 5 кадров. Это гарантирует, что скролл 
        -- "дожмется" до низа даже если ImGui отрисует новый элемент с задержкой в 1 кадр.
        SmoothScrollStates[window_id].force_bottom_frames = 5
    end
end

function renderSmoothScrollBox(str_id, size, content_func)
    if not SmoothScrollStates[str_id] then
        SmoothScrollStates[str_id] = { 
            current = 0.0, 
            target = 0.0, 
            max = 0.0, 
            last_max = 0.0,
            force_bottom_frames = 0 
        }
    end
    local state = SmoothScrollStates[str_id]

    -- NoScrollWithMouse отключает дефолтный резкий скролл
    if imgui.BeginChild(str_id, size, true, imgui.WindowFlags.NoScrollWithMouse) then
        
        state.max = imgui.GetScrollMaxY()
        
        -- 1. Обработка колесика мыши
        if imgui.IsWindowHovered() then
            local wheel = imgui.GetIO().MouseWheel
            if wheel ~= 0 then
                -- Если юзер крутит колесо, отменяем авто-скролл
                state.force_bottom_frames = 0
                state.target = state.target - (wheel * 60.0) -- Скорость прокрутки колесом
            end
        end

        -- 2. Логика авто-прокрутки вниз (работает N кадров подряд)
        if state.force_bottom_frames > 0 then
            -- Ставим цель с большим запасом, чтобы точно упереться в дно
            state.target = state.max + 10000.0
            state.force_bottom_frames = state.force_bottom_frames - 1
        end
        
        -- 3. Ограничение границ (Clamping)
        if state.target < 0 then state.target = 0 end
        if state.target > state.max then state.target = state.max end

        -- 4. Фикс дёрганья при удалении (Anti-Jitter)
        -- Если максимальная высота уменьшилась (что-то удалили), мгновенно приравниваем позицию,
        -- чтобы не было визуального "отъезда" вверх.
        if state.max < state.last_max then
             state.current = state.target
        end
        state.last_max = state.max

        -- 5. Интерполяция (Плавность)
        local dt = imgui.GetIO().DeltaTime
        local diff = state.target - state.current
        
        -- Если разница маленькая, просто ставим в точку (чтобы не мылило текст)
        if math.abs(diff) < 0.5 then
            state.current = state.target
        else
            -- Скорость 15.0 - оптимальный баланс между плавностью и отзывчивостью
            state.current = state.current + diff * math.min(1.0, 18.0 * dt)
        end
        
        imgui.SetScrollY(state.current)
        
        -- 6. Синхронизация, если юзер тянет ползунок мышкой (Drag Scrollbar)
        -- Если реальный скролл сильно отличается от нашего (значит юзер тянет бар), обновляем нашу цель
        local actual_scroll = imgui.GetScrollY()
        if math.abs(actual_scroll - state.current) > 5.0 and imgui.IsMouseDown(0) then
             state.current = actual_scroll
             state.target = actual_scroll
             state.force_bottom_frames = 0
        end

        content_func()
    end
    imgui.EndChild()
end

function url_encode(str)
    if str then
        str = str:gsub("\n", "\r\n")
        str = str:gsub("([^%w %-%_%.%~])",
            function (c) return string.format ("%%%02X", string.byte(c)) end)
        str = str:gsub(" ", "+")
    end
    return str
end

function App.tasks.add(name, code, wait_time)
    
    App.tasks.remove_by_name(name)
    local task = {
        name = name, 
        code = code, 
        start_time = os.clock() * 1000, 
        wait_time = wait_time,
        dead = false 
    }
    table.insert(App.tasks_list, task)
end

function App.tasks.process()
    local current_time = os.clock() * 1000
    local i = 1
    
    while i <= #App.tasks_list do
        local task = App.tasks_list[i]
        
        
        if task.dead then
            table.remove(App.tasks_list, i)
        
        
        elseif (current_time - task.start_time >= task.wait_time) then
            
            task.dead = true 
            
            
            local status, err = pcall(task.code)
            
            if not status then
                print('[RodinaMarket] Ошибка выполнения задачи "' .. tostring(task.name) .. '": ' .. tostring(err))
            end
            
            
            table.remove(App.tasks_list, i)
            
        else
            
            i = i + 1
        end
    end
end

function App.tasks.remove_by_name(name)
    for i, v in ipairs(App.tasks_list) do
        if v.name == name then 
            v.dead = true 
            return 
        end
    end
end

function events.onServerMessage(color, text)
    -- Очищаем текст от цветовых кодов {FFFFFF} перед любой проверкой
    local clean_text = cleanTextColors(text)

    -- 1. Ловим сообщение от команды /id (оставляем без изменений)
    if clean_text:find("ID:%s*%d+%s*|%s*Имя:") then
        local msg_id, msg_nick = clean_text:match("ID:%s*(%d+)%s*|%s*Имя:%s*([%w_]+)")
        local res, myId = sampGetPlayerIdByCharHandle(PLAYER_PED)
        
        if msg_id and msg_nick and res then
            if tonumber(msg_id) == tonumber(myId) then
                LOCAL_PLAYER_NICK = msg_nick:gsub("_", " ")
                LOCAL_PLAYER_ID = tonumber(msg_id)
                print("[RMarket] Личность подтверждена: " .. LOCAL_PLAYER_NICK .. " [ID: " .. LOCAL_PLAYER_ID .. "]")
                return false
            end
        end
        return true
    end

    -- 2. Логика для Лавки (ОБНОВЛЕНО)
    -- Проверяем, начинается ли строка строго с [Лавка] (игнорируя цвета)
    -- Это отсекает сообщения из VIP чата, так как они начинаются с [FOREVER], [PREMIUM] и т.д.
    if not clean_text:find("^%[Лавка%]") then return true end
    
    -- Вызываем нашу обновленную функцию парсинга
    local transaction = parseShopMessage(text)
	
	if clean_text:find("Вы отказались от аренды лавки") or 
       clean_text:find("Вы сняли лавку") or 
       clean_text:find("Ваша лавка была закрыта") or
       clean_text:find("Вы покинули лавку") then
        
        Marketplace_Clear()
    end
	
    if transaction then
        addTransactionLog(transaction)
        
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

function to_lower(str)
    if not str then return "" end
    local res = {}
    for i = 1, #str do
        local c = str:byte(i)
        -- Диапазон русских заглавных букв в CP1251: 192-223 -> +32 -> строчные
        if c >= 192 and c <= 223 then
            table.insert(res, string.char(c + 32))
        -- Ё (168) -> ё (184)
        elseif c == 168 then
            table.insert(res, string.char(184))
        else
            table.insert(res, string.lower(string.char(c)))
        end
    end
    return table.concat(res)
end

function isAccessory(name)
    if not name then return false end
    -- Проверяем наличие слова "Аксессуар" в начале строки без to_lower, 
    -- так как с кириллицей в луа могут быть проблемы регистра
    return name:find("^Аксессуар") ~= nil or name:find("^аксессуар") ~= nil
end

local search_anim_state = { 
    active_t = 0.0, 
    hover_t = 0.0,
    clear_btn_alpha = 0.0,
    clear_scale = 1.0
}

function renderAnimatedSearchBar(buffer, hint, width)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    
    local height = S(42) 
    local rounding = height / 2 
    
    
    local col_bg_normal = CURRENT_THEME.bg_tertiary
    local col_bg_active = CURRENT_THEME.bg_secondary
    local col_accent = CURRENT_THEME.accent_primary
    local col_text_hint = CURRENT_THEME.text_hint
    
    
    local is_hovered_rect = imgui.IsMouseHoveringRect(p, imgui.ImVec2(p.x + width, p.y + height))
    local dt = imgui.GetIO().DeltaTime * 10.0
    
    search_anim_state.hover_t = lerp(search_anim_state.hover_t, is_hovered_rect and 1.0 or 0.0, dt)
    
    
    
    local focus_blend = math.max(search_anim_state.active_t, search_anim_state.hover_t * 0.3)
    local bg_r = lerp(col_bg_normal.x, col_bg_active.x, focus_blend)
    local bg_g = lerp(col_bg_normal.y, col_bg_active.y, focus_blend)
    local bg_b = lerp(col_bg_normal.z, col_bg_active.z, focus_blend)
    local bg_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(bg_r, bg_g, bg_b, 0.95))
    
    
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), bg_col, rounding)
    
    
    draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), 
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0.15 + search_anim_state.hover_t * 0.1)), 
        rounding, 15, S(1.0))

    
    if search_anim_state.active_t > 0.02 then
        
        local glow_alpha = search_anim_state.active_t * 0.6
        local glow_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(col_accent.x, col_accent.y, col_accent.z, glow_alpha))
        
        
        draw_list:AddRect(
            imgui.ImVec2(p.x - S(2), p.y - S(2)), 
            imgui.ImVec2(p.x + width + S(2), p.y + height + S(2)), 
            glow_col, 
            rounding, 
            15, 
            S(2.5) 
        )
    end

    
    local icon_offset_x = S(16)
    imgui.PushFont(font_fa)
    local icon_search = fa('magnifying_glass')
    local icon_size = imgui.CalcTextSize(icon_search)
    
    
    local icon_blend = math.max(search_anim_state.active_t * 0.8, search_anim_state.hover_t * 0.4)
    local icon_r = lerp(col_text_hint.x, col_accent.x, icon_blend)
    local icon_g = lerp(col_text_hint.y, col_accent.y, icon_blend)
    local icon_b = lerp(col_text_hint.z, col_accent.z, icon_blend)
    local icon_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(icon_r, icon_g, icon_b, 0.8))
    
    draw_list:AddText(imgui.ImVec2(p.x + icon_offset_x, p.y + (height - icon_size.y)/2), icon_col, icon_search)
    imgui.PopFont()

    
    
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.FrameBgHovered, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.FrameBgActive, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0,0,0,0))
    
    imgui.PushStyleColor(imgui.Col.TextSelectedBg, imgui.ImVec4(col_accent.x, col_accent.y, col_accent.z, 0.5))
    
    imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_primary)
    
    
    local text_pad_left = icon_offset_x + icon_size.x + S(12)
    local text_pad_right = S(35)
    
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y))
    
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(text_pad_left, (height - imgui.GetFontSize()) / 2))
    
    imgui.SetNextItemWidth(width - text_pad_right) 
    
    local changed = imgui.InputTextWithHint("##anim_search_bar", u8(hint), buffer, 128)
    local is_active = imgui.IsItemActive()
    
    imgui.PopStyleVar()
    imgui.PopStyleColor(6) 

    
    search_anim_state.active_t = lerp(search_anim_state.active_t, is_active and 1.0 or 0.0, dt * 0.8)

    
    local has_text = ffi.string(buffer) ~= ""
    search_anim_state.clear_btn_alpha = lerp(search_anim_state.clear_btn_alpha, has_text and 1.0 or 0.0, dt)

    if search_anim_state.clear_btn_alpha > 0.02 then
        imgui.PushFont(font_fa)
        local icon_clear = fa('circle_xmark')
        local clear_size = imgui.CalcTextSize(icon_clear)
        
        local btn_w = S(32)
        local btn_pos_x = p.x + width - btn_w - S(5)
        local btn_pos_y = p.y
        
        
        local is_mouse_on_clear = imgui.IsMouseHoveringRect(imgui.ImVec2(btn_pos_x, btn_pos_y), imgui.ImVec2(btn_pos_x + btn_w, btn_pos_y + height))
        
        
        local clear_scale = is_mouse_on_clear and 1.2 or 1.0
        search_anim_state.clear_scale = lerp(search_anim_state.clear_scale or 1.0, clear_scale, dt * 0.5)
        
        
        local clear_alpha_base = search_anim_state.clear_btn_alpha
        local clear_alpha = is_mouse_on_clear and (clear_alpha_base * 1.0) or (clear_alpha_base * 0.6)
        
        local clear_col_val = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(
            CURRENT_THEME.text_hint.x, 
            CURRENT_THEME.text_hint.y, 
            CURRENT_THEME.text_hint.z, 
            clear_alpha
        ))
        
        if is_mouse_on_clear then
            clear_col_val = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(
                CURRENT_THEME.accent_danger.x, 
                CURRENT_THEME.accent_danger.y, 
                CURRENT_THEME.accent_danger.z, 
                clear_alpha
            ))
            
            if imgui.IsMouseClicked(0) then
                buffer[0] = 0 
                changed = true
                search_anim_state.clear_btn_alpha = 0
            end
        end
        
        
        local offset_x = (btn_w - clear_size.x * search_anim_state.clear_scale) / 2
        local offset_y = (height - clear_size.y * search_anim_state.clear_scale) / 2
        
        draw_list:AddText(
            imgui.ImVec2(btn_pos_x + offset_x, btn_pos_y + offset_y), 
            clear_col_val, 
            icon_clear
        )
        imgui.PopFont()
    end
    
    return changed
end

function filterList(list, buffer_char)
    if not list or #list == 0 then 
        return {} 
    end
    
    -- Получаем строку из буфера ImGui
    local query_utf8 = ffi.string(buffer_char)
    
    if query_utf8 == "" then 
        return list 
    end
    
    -- Декодируем из UTF-8 в CP1251 (так как ImGui вводит в UTF-8, а скрипт в CP1251)
    local query = u8:decode(query_utf8)
    
    if not query or query == "" then 
        return list 
    end
    
    local results_with_score = {}
    
    for i, item in ipairs(list) do
        if item and item.name then
            -- Очищаем имя товара от цветов и тегов перед поиском
            local clean_name = enhancedCleanItemName(item.name)
            local score = SmartSearch.getMatchScore(query, clean_name)
            
            if score > 0 then
                table.insert(results_with_score, {data = item, score = score})
            end
        end
    end
    
    -- Сортируем по релевантности (чем больше score, тем выше)
    table.sort(results_with_score, function(a, b)
        return a.score > b.score
    end)
    
    local final_result = {}
    for _, entry in ipairs(results_with_score) do
        table.insert(final_result, entry.data)
    end
    
    return final_result
end

function tableContains(tbl, field_name, value)
    for _, item in ipairs(tbl) do
        if item[field_name] == value then
            return true
        end
    end
    return false
end

function tableFind(tbl, field_name, value)
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
    
    
    imgui.Dummy(imgui.ImVec2(width, height))
    
    
    draw_list:AddRectFilled(
        imgui.ImVec2(p.x + S(2), p.y + S(2)), 
        imgui.ImVec2(p.x + width + S(2), p.y + height + S(2)), 
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0, 0, 0, 0.2)), 
        S(10)
    )
    
    
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), imgui.ColorConvertFloat4ToU32(color_bg), S(10))
    
    
    draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.15)), S(10), nil, S(1.5))
    
    
    local title_pos = imgui.ImVec2(p.x + S(15), p.y + S(10))
    draw_list:AddText(title_pos, imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.7)), u8(label))
    
    
    local money_str = formatMoney(value)
    local value_pos = imgui.ImVec2(p.x + S(15), p.y + S(32))
    draw_list:AddText(value_pos, imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary), money_str)
end


function getPaginatedList(list, page, items_per_page)
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

function renderPaginationButtons(page, total_pages, on_page_change)
    if total_pages <= 1 then return end
    
    imgui.Separator()
    imgui.Spacing()
    
    local button_width = (imgui.GetContentRegionAvail().x - S(10)) / 3
    
    
    if page > 1 then
        if imgui.Button(fa('arrow_left') .. u8" Предыдущая", imgui.ImVec2(button_width, S(30))) then
            on_page_change(page - 1)
        end
    else
        imgui.Button(fa('arrow_left') .. u8" Предыдущая", imgui.ImVec2(button_width, S(30)))
    end
    imgui.BeginDisabled(true)
    imgui.SameLine()
    
    
    imgui.Button(u8(string.format("Страница %d / %d", page, total_pages)), imgui.ImVec2(button_width, S(30)))
    
    imgui.SameLine()
    imgui.EndDisabled()
    
    
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
            
            local date_str = file:sub(1, -6)
            table.insert(files, date_str)
        end
    end
    
    
    table.sort(files, function(a, b) return a > b end)
    
    Data.available_log_dates = files
    Buffers.logs_dates_cache = files
end


function loadLogsForDate(date_str)
    local path = PATHS.LOGS .. date_str .. ".json"
    return loadJsonFile(path, {})
end


function updateLogView()
    local selected_idx = Buffers.logs_current_date_idx
    local raw_logs = {}
    
    if selected_idx > 0 and Buffers.logs_dates_cache and Buffers.logs_dates_cache[selected_idx] then
        local date_str = Buffers.logs_dates_cache[selected_idx]
        raw_logs = loadLogsForDate(date_str)
    else
        local today = os.date("%Y-%m-%d")
        raw_logs = loadLogsForDate(today)
        
        if #raw_logs > 0 and #Buffers.logs_dates_cache == 0 then
             refreshLogDates()
        end
    end
    
    local filtered = {}
    local show_sales = Buffers.log_filters.show_sales[0]
    local show_purchases = Buffers.log_filters.show_purchases[0]
    
    table.sort(raw_logs, function(a, b) return (a.timestamp or 0) > (b.timestamp or 0) end)
    
    local income = 0
    local expense = 0
    
    for _, log in ipairs(raw_logs) do
        -- [FIXED] Убрано лишнее декодирование (safe_decode), так как loadLogsForDate 
        -- уже возвращает текст в корректной кодировке CP1251.
        -- Повторное декодирование ломало текст.

        -- === ИСПРАВЛЕНИЕ СТАРЫХ ЛОГОВ ===
        log.amount = tonumber(log.amount) or 1
        log.price = tonumber(log.price) or 0
        
        -- 1. Если поле total отсутствует (очень старые логи), считаем что price это и есть total
        if not log.total or log.total == 0 then
            log.total = log.price
        end
        
        -- 2. Логика пересчета:
        -- Если предметов больше 1, и Цена за штуку равна Общей сумме,
        -- значит в 'price' записана общая сумма. Нужно разделить.
        if log.amount > 1 and log.price == log.total then
             log.price = math.floor(log.total / log.amount)
        end
        -- ================================

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






function renderAAAPriceCard(price, label, icon, color, width)
    width = width or imgui.GetContentRegionAvail().x
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    local height = S(80)
    local padding = S(15)
    local border_radius = S(10)
    
    
    local bg_color = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_tertiary)
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), bg_color, border_radius)
    
    
    local border_color = imgui.ColorConvertFloat4ToU32(color)
    draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), border_color, border_radius, imgui.DrawCornerFlags.All, S(2))
    
    
    if icon and font_fa then
        imgui.PushFont(font_fa)
        local icon_color = imgui.ColorConvertFloat4ToU32(color)
        draw_list:AddText(imgui.ImVec2(p.x + padding, p.y + padding + S(5)), icon_color, icon)
        imgui.PopFont()
    end
    
    
    local price_text = formatMoney(price)
    local price_size = imgui.CalcTextSize(price_text)
    local price_color = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary)
    draw_list:AddText(imgui.ImVec2(p.x + width - price_size.x - padding, p.y + S(20)), price_color, price_text)
    
    
    local label_color = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_secondary)
    draw_list:AddText(imgui.ImVec2(p.x + padding + S(35), p.y + padding), label_color, u8(label))
    
    imgui.Dummy(imgui.ImVec2(width, height))
end


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


function renderAAAmountSelector(item_index, current_amount, on_change)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    local width = S(120)
    local height = S(36)
    local border_radius = S(8)
    
    
    local bg_color = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary)
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), bg_color, border_radius)
    
    
    local border_color = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.border_light)
    draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), border_color, border_radius, imgui.DrawCornerFlags.All, S(1))
    
    
    if imgui.InvisibleButton("##minus_" .. item_index, imgui.ImVec2(S(36), height)) then
        if on_change then on_change(math.max(1, current_amount - 1)) end
    end
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x + S(8), p.y + S(8)))
    local minus_color = imgui.IsItemHovered() and 0xFFFFFFFF or 0xB0FFFFFF
    draw_list:AddText(imgui.ImVec2(p.x + S(12), p.y + S(8)), minus_color, fa('minus'))
    
    
    local amount_text = tostring(current_amount)
    local text_size = imgui.CalcTextSize(amount_text)
    local text_color = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary)
    draw_list:AddText(imgui.ImVec2(p.x + (width - text_size.x) / 2, p.y + (height - text_size.y) / 2), text_color, amount_text)
    
    
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x + width - S(36), p.y))
    if imgui.InvisibleButton("##plus_" .. item_index, imgui.ImVec2(S(36), height)) then
        if on_change then on_change(current_amount + 1) end
    end
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x + width - S(28), p.y + S(8)))
    local plus_color = imgui.IsItemHovered() and 0xFFFFFFFF or 0xB0FFFFFF
    draw_list:AddText(imgui.ImVec2(p.x + width - S(24), p.y + S(8)), plus_color, fa('plus'))
    
    imgui.Dummy(imgui.ImVec2(width, height))
end


function renderActionButton(icon, label, width, on_click, tooltip, is_disabled)
    is_disabled = is_disabled or false
    width = width or -1
    
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    local avail_w = imgui.GetContentRegionAvail().x
    if width == -1 then width = avail_w end
    
    local height = S(45)
    local border_radius = S(8)
    
    
    if imgui.InvisibleButton("##action_btn", imgui.ImVec2(width, height)) then
        if not is_disabled and on_click then on_click() end
    end
    
    local is_hovered = imgui.IsItemHovered() and not is_disabled
    local is_pressed = imgui.IsItemActive()
    
    
    local bg_color = is_disabled and CURRENT_THEME.bg_secondary 
                    or (is_pressed and lerpColor(CURRENT_THEME.accent_primary, CURRENT_THEME.bg_secondary, 0.5))
                    or (is_hovered and lerpColor(CURRENT_THEME.accent_primary, CURRENT_THEME.bg_secondary, 0.3))
                    or CURRENT_THEME.bg_tertiary
    
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), imgui.ColorConvertFloat4ToU32(bg_color), border_radius)
    
    
    local border_color = is_disabled and CURRENT_THEME.border_light or CURRENT_THEME.accent_primary
    draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), imgui.ColorConvertFloat4ToU32(border_color), border_radius, imgui.DrawCornerFlags.All, S(2))
    
    
    if icon and font_fa then
        imgui.PushFont(font_fa)
        local icon_color = is_disabled and CURRENT_THEME.text_hint or CURRENT_THEME.accent_primary
        draw_list:AddText(imgui.ImVec2(p.x + S(12), p.y + (height - S(16)) / 2), 
                         imgui.ColorConvertFloat4ToU32(icon_color), icon)
        imgui.PopFont()
    end
    
    
    local text_color = is_disabled and CURRENT_THEME.text_hint or CURRENT_THEME.text_primary
    local text_size = imgui.CalcTextSize(u8(label))
    draw_list:AddText(imgui.ImVec2(p.x + S(40), p.y + (height - text_size.y) / 2), 
                     imgui.ColorConvertFloat4ToU32(text_color), u8(label))
    
    if is_hovered and tooltip then 
        imgui.SetTooltip(u8(tooltip)) 
    end
    
    imgui.Dummy(imgui.ImVec2(width, height))
end


function renderListHeader(icon, title, count)
    imgui.Spacing()
    
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    local avail_w = imgui.GetContentRegionAvail().x
    
    
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + avail_w, p.y + S(40)), 
                           imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary), S(8))
    
    
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + S(4), p.y + S(40)), 
                           imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary), 0)
    
    
    if icon and font_fa then
        imgui.PushFont(font_fa)
        draw_list:AddText(imgui.ImVec2(p.x + S(12), p.y + S(10)), 
                         imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary), icon)
        imgui.PopFont()
    end
    
    
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x + S(42), p.y + S(8)))
    imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_primary)
    imgui.Text(u8(title))
    imgui.PopStyleColor()
    
    
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

    -- Просто добавляем в очередь. Никаких потоков здесь.
    table.insert(HttpWorker.queue, {
        method = method,
        url = url,
        args = args or {},
        resolve = resolve,
        reject = reject
    })
end

function processHttpQueue()
    -- 1. Если поток уже запущен, проверяем его статус
    if HttpWorker.thread then
        -- [FIX] Оборачиваем получение статуса в pcall, чтобы краш effil не убивал скрипт
        local p_status, status, err = pcall(function() return HttpWorker.thread:status() end)
        
        -- Если effil выбросил ошибку (например, resource unavailable при проверке)
        if not p_status then
            print("[RMarket] Thread Status Error: " .. tostring(status))
            -- Пытаемся мягко убить поток и сбросить состояние
            pcall(function() HttpWorker.thread:cancel() end)
            HttpWorker.thread = nil
            HttpWorker.current_task = nil
            collectgarbage() -- Чистим мусор, чтобы освободить ресурсы
            return
        end
        
        if status == 'completed' then
            local ok, success, response = pcall(HttpWorker.thread.get, HttpWorker.thread)
            if ok and success then
                if HttpWorker.current_task and HttpWorker.current_task.resolve then
                    pcall(HttpWorker.current_task.resolve, response)
                end
            else
                local err_msg = tostring(response or err)
                if not err_msg:find("timeout") then
                    print("[RMarket] HTTP Request Failed: " .. err_msg)
                end
                
                if HttpWorker.current_task and HttpWorker.current_task.reject then
                    pcall(HttpWorker.current_task.reject, response or err)
                end
            end
            HttpWorker.thread = nil
            HttpWorker.current_task = nil
            
        elseif status == 'failed' or status == 'canceled' then
            -- [FIX] Добавлена проверка на наличие err перед tostring
            print("[RMarket] HTTP Thread Error: " .. tostring(err or "Unknown"))
            if HttpWorker.current_task and HttpWorker.current_task.reject then
                pcall(HttpWorker.current_task.reject, err)
            end
            HttpWorker.thread = nil
            HttpWorker.current_task = nil
            
        elseif os.clock() - HttpWorker.start_time > 70 then
            print("[RMarket] HTTP Thread Timeout (Killer)")
            if HttpWorker.thread then 
                pcall(HttpWorker.thread.cancel, HttpWorker.thread) 
            end
            if HttpWorker.current_task and HttpWorker.current_task.reject then
                pcall(HttpWorker.current_task.reject, "Timeout")
            end
            HttpWorker.thread = nil
            HttpWorker.current_task = nil
        end
        return
    end

    -- 2. Если потока нет, берем задачу из очереди
    if #HttpWorker.queue > 0 then
        -- [FIX] Сначала готовим поток, и только если он создался, удаляем задачу из очереди
        local task = HttpWorker.queue[1] 
        local p_path, p_cpath = package.path, package.cpath
        
        -- Оборачиваем создание потока в pcall, так как именно здесь вылетает "resource unavailable"
        local runner = effil.thread(http_thread_func)
        local create_ok, thread_obj = pcall(runner, 
            task.method, 
            task.url, 
            task.args, 
            p_path, 
            p_cpath
        )
        
        if create_ok then
            -- Успешно создали поток
            table.remove(HttpWorker.queue, 1) -- Теперь можно удалить из очереди
            HttpWorker.current_task = task
            HttpWorker.start_time = os.clock()
            HttpWorker.thread = thread_obj
        else
            -- Ошибка создания (лимит ресурсов). Не удаляем задачу, попробуем в следующем кадре.
            print("[RMarket] Failed to create thread (Resource limit?): " .. tostring(thread_obj))
            collectgarbage() -- Принудительная сборка мусора
        end
    end
end

function saveLiveShopState()
    local shop_state = {
        sell = Data.live_shop.sell or {},
        buy = Data.live_shop.buy or {},
        -- [FIX] Сохраняем флаги активности, чтобы пережить перезагрузку
        is_active = App.live_shop_active,
        marketplace_enabled = Marketplace.enabled,
        marketplace_uid = Marketplace.LavkaUid,
        publish_sell = Marketplace.publish_sell,
        publish_buy = Marketplace.publish_buy
    }
    saveJsonFile(PATHS.DATA .. 'live_shop_state.json', shop_state)
end

function loadLiveShopState()
    local path = PATHS.DATA .. 'live_shop_state.json'
    if doesFileExist(path) then
        local data = loadJsonFile(path, {})
        if data then
            Data.live_shop.sell = data.sell or {}
            Data.live_shop.buy = data.buy or {}
            
            -- [FIX] Восстанавливаем активность лавки
            if data.is_active or data.marketplace_enabled then
                App.live_shop_active = true
                Marketplace.enabled = true
                -- Восстанавливаем старый ID лавки, чтобы сервер не думал, что это новая
                Marketplace.LavkaUid = data.marketplace_uid or os.time()
                
                Marketplace.publish_sell = data.publish_sell or false
                Marketplace.publish_buy = data.publish_buy or false
                
                -- Форсируем немедленную синхронизацию (пинг)
                MarketConfig.LAST_SYNC = 0
                print("[RMarket] [FIX] Активность лавки восстановлена после перезагрузки.")
            end
        end
    end
end

function safe_decode(str)
    if str == nil or str == json.null then return "" end
    
    if type(str) ~= "string" then return tostring(str) end
    
    if #str == 0 then return "" end
    
    local status, result = pcall(u8.decode, u8, str)
    if status then 
        return result 
    else
        return str 
    end
end

function api_FetchMarketList()
    MarketData.is_loading = true
    
    asyncHttpRequest('GET', MarketConfig.HOST .. '/api/getArizonaMarkets', 
        {timeout = 20}, 
        function(response)
            if response.status_code == 200 then
                local file = io.open(PATHS.CACHE .. 'market_dump.json', "w")
                if file then
                    file:write(response.text)
                    file:close()
                end

                local decode_ok, data = pcall(json.decode, response.text)
                if decode_ok and type(data) == "table" then
                    MarketData.shops_list = {}
                    for _, shop in ipairs(data) do
                        local s_list = {}
                        if shop.items_sell and type(shop.items_sell) == "table" then
                            for k, v in ipairs(shop.items_sell) do
                                local safe_name = safe_decode(v)
                                table.insert(s_list, {
                                    name = safe_name,
                                    amount = shop.count_sell and shop.count_sell[k] or 0,
                                    price = shop.price_sell and shop.price_sell[k] or 0
                                })
                            end
                        end

                        local b_list = {}
                        if shop.items_buy and type(shop.items_buy) == "table" then
                            for k, v in ipairs(shop.items_buy) do
                                local safe_name = safe_decode(v)
                                table.insert(b_list, {
                                    name = safe_name,
                                    amount = shop.count_buy and shop.count_buy[k] or 0,
                                    price = shop.price_buy and shop.price_buy[k] or 0
                                })
                            end
                        end

                        local raw_nick = shop.username or shop.user or "Unknown"
                        local safe_nick = safe_decode(raw_nick)

                        -- [FIX] Безопасный подсчет
                        local sell_c = (type(shop.items_sell) == 'table') and #shop.items_sell or 0
                        local buy_c  = (type(shop.items_buy) == 'table') and #shop.items_buy or 0

                        table.insert(MarketData.shops_list, {
                            nickname = safe_nick,
                            serverId = shop.serverId or shop.id,
                            vip = shop.vip or false,
                            sell_count = sell_c,
                            buy_count = buy_c,
                            shop_name = "Лавка " .. safe_nick,
                            sell_list = s_list,
                            buy_list = b_list
                        })
                    end
                    MarketData.online_count = #MarketData.shops_list
                    MarketData.last_fetch = os.time()
                end
            else
                addToastNotification("Ошибка обновления данных: " .. response.status_code, "error")
            end
            MarketData.is_loading = false
        end,
        function(err)
            addToastNotification("Ошибка соединения", "error")
            MarketData.is_loading = false
        end
    )
end

function findPlayerIdByNickname(nick)
    if not nick or nick == "" then return -1 end

    -- 1. Попытка декодировать из UTF-8 в CP1251 (так как данные с веба)
    local search_name = nick
    if u8 then
        local status, result = pcall(u8.decode, u8, nick)
        if status then search_name = result end
    end

    -- 2. "Очистка" искомого ника:
    -- - Убираем цвета
    -- - Убираем пробелы по краям
    -- - ЗАМЕНЯЕМ ВСЕ ПРОБЕЛЫ НА _ (Самое важное для Маркета)
    -- - Приводим к нижнему регистру
    local target = tostring(search_name)
        :gsub("{......}", "")
        :match("^%s*(.-)%s*$")
        :gsub(" ", "_")
        :lower()
    
    -- 3. Проходимся по всему списку игроков
    local max_players = sampGetMaxPlayerId(false)
    for i = 0, max_players do
        if sampIsPlayerConnected(i) then
            local pNick = sampGetPlayerNickname(i)
            if pNick then
                -- Также очищаем ник игрока на сервере
                local current = pNick:gsub(" ", "_"):lower()
                
                if current == target then
                    return i
                end
            end
        end
    end

    return -1
end

function api_FetchShopDetails(server_id, nickname)
    if MarketData.is_loading_details then return end
    MarketData.is_loading_details = true

    local request_server_id = server_id
    if SERVER_IPS_FIX[server_id] then
        request_server_id = SERVER_IPS_FIX[server_id]
    end

    local encoded_nick = url_encode(u8:encode(nickname))
    local encoded_server = url_encode(tostring(request_server_id))
    
    local url = string.format("%s/api/getSelectedMarketplace?nick=%s&server=%s", 
        MarketConfig.HOST, encoded_nick, encoded_server)
        
    asyncHttpRequest('GET', url, 
        {timeout = 10},
        function(response)
            MarketData.is_loading_details = false
            
            if response.status_code == 200 and response.text and #response.text > 0 then
                local decode_ok, data = pcall(json.decode, response.text)
                
                if decode_ok and data and type(data) == "table" and (data.username or data.user) then
                    local shop_obj = {
                        nickname = safe_decode(data.username or data.user),
                        serverId = data.serverId,
                        playerId = tonumber(data.playerId) or -1, -- << ПОЛУЧАЕМ СОХРАНЕННЫЙ ID
                        sell_list = {},
                        buy_list = {}
                    }
                    
                    -- Если сервер не вернул ID или он устарел, ищем старым методом (на всякий случай)
                    if shop_obj.playerId == -1 then
                         shop_obj.playerId = findPlayerIdByNickname(shop_obj.nickname)
                    end
                    
                    if data.items_sell and type(data.items_sell) == "table" then
                        for i = 1, #data.items_sell do
                            table.insert(shop_obj.sell_list, {
                                name = safe_decode(data.items_sell[i]),
                                amount = (data.count_sell and data.count_sell[i]) or 0,
                                price = (data.price_sell and data.price_sell[i]) or 0
                            })
                        end
                    end
                    
                    if data.items_buy and type(data.items_buy) == "table" then
                        for i = 1, #data.items_buy do
                            table.insert(shop_obj.buy_list, {
                                name = safe_decode(data.items_buy[i]),
                                amount = (data.count_buy and data.count_buy[i]) or 0,
                                price = (data.price_buy and data.price_buy[i]) or 0
                            })
                        end
                    end
                    
                    MarketData.selected_shop = shop_obj
                else
                    addToastNotification("Лавка закрыта или удалена. Обновляю список...", "warning", 3.0)
                    api_FetchMarketList()
                end
            elseif response.status_code == 404 then
                addToastNotification("Лавка больше не существует. Обновляю список...", "warning", 3.0)
                api_FetchMarketList()
            else
                print("[RodinaMarket] API Error: " .. response.status_code .. " URL: " .. url)
                addToastNotification("Ошибка API (" .. response.status_code .. ")", "error")
            end
        end,
        function(err)
            MarketData.is_loading_details = false
            addToastNotification("Ошибка соединения с API", "error")
        end
    )
end

function renderMarketItemRow(index, item, width, is_sell)
    if not item then return end
    
    local height = S(48)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    imgui.PushIDInt(index)
    imgui.PushIDInt(is_sell and 1 or 0)
    
    
    local bg_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.10, 0.11, 0.14, 0.8))
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), bg_col, S(5))
    
    
    local bar_color = is_sell and 0xFF66CC66 or 0xFF6666FF
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + S(3), p.y + height), bar_color, S(5))

    
    local padding_x = S(12)
    local text_col_primary = 0xFFFFFFFF
    local text_col_secondary = 0xFFAAAAAA
    
    local safe_name = tostring(item.name or "Неизвестный товар")
    
    
    draw_list:AddText(imgui.ImVec2(p.x + padding_x, p.y + S(6)), text_col_primary, u8(safe_name))
    
    
    local safe_price = item.price or 0
    local price_str = formatMoney(safe_price) .. u8" $"
    local price_size = imgui.CalcTextSize(price_str)
    local price_col = is_sell and 0xFF66CC66 or 0xFF6666FF
    
    draw_list:AddText(
        imgui.ImVec2(p.x + width - price_size.x - padding_x, p.y + S(6)), 
        price_col, 
        price_str
    )
    
    
    local safe_amount = item.amount or 0
    local amount_str = u8("x" .. safe_amount)
    draw_list:AddText(imgui.ImVec2(p.x + padding_x, p.y + S(22)), text_col_secondary, amount_str)
    
    
    local operation_text = is_sell and u8"Продажа" or u8"Скупка"
    local op_size = imgui.CalcTextSize(operation_text)
    local op_col = is_sell and 0xFF66CC66 or 0xFF6666FF
    
    draw_list:AddText(
        imgui.ImVec2(p.x + width - op_size.x - padding_x, p.y + S(22)),
        op_col,
        operation_text
    )

    
    if imgui.InvisibleButton("##itemrow_" .. tostring(index) .. "_" .. (is_sell and "sell" or "buy"), imgui.ImVec2(width, height)) then
        if not is_sell then
            
            sampAddChatMessage('[RodinaMarket] {ffff00}[DEBUG] Добавляю товар: ' .. (item.name or "Unknown"), -1)
            
            
            local found = false
            for _, existing_item in ipairs(Data.buy_list) do
                if existing_item.name == item.name then
                    existing_item.amount = (existing_item.amount or 1) + 1
                    found = true
                    break
                end
            end
            
            if not found then
                
                table.insert(Data.buy_list, {
                    name = item.name,
                    price = item.price or 100,
                    amount = 1,
                    active = true,
                    model_id = -1,
                    index = item.index or -1
                })
            end
            
            
            saveListsConfig()
            calculateBuyTotal()
            sampAddChatMessage('[RodinaMarket] {00ff00}Товар добавлен в Мою скупку!', -1)
        end
    end

    
    imgui.Dummy(imgui.ImVec2(width, height))

    imgui.PopID()
    imgui.PopID()
end

function renderShopCardGrid(shop, width)
    if not shop then return end
    imgui.PushIDStr(tostring(shop.serverId) .. tostring(shop.nickname))
    
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    local height = width 
    
    local is_vip_shop = shop.vip or false
    
    -- Фон
    local bg_u32 = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary)
    
    -- [VIP ЭФФЕКТ] Анимированная подложка и БЛИК
    if is_vip_shop then
        -- Темно-золотой градиент фона
        draw_list:AddRectFilledMultiColor(
            p, 
            imgui.ImVec2(p.x + width, p.y + height), 
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.2, 0.15, 0.05, 1.0)), -- TL
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.1, 0.08, 0.02, 1.0)), -- TR
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.1, 0.08, 0.02, 1.0)), -- BR
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.2, 0.15, 0.05, 1.0))  -- BL
        )
    else
        draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), bg_u32, S(10))
    end
    
    -- Кнопка действия (невидимая)
    imgui.SetCursorScreenPos(p)
    if imgui.InvisibleButton("grid_card_btn", imgui.ImVec2(width, height)) then
        api_FetchShopDetails(shop.serverId, shop.nickname)
    end
    
    local is_hovered = imgui.IsItemHovered()
    
    -- [VIP ЭФФЕКТ] Анимация "Шиммер" (пролетающий блеск)
    if is_vip_shop then
        imgui.PushClipRect(p, imgui.ImVec2(p.x + width, p.y + height), true)
        
        local time = os.clock()
        -- Блик бегает каждые 3 секунды
        local progress = (time % 3.0) / 1.5 
        
        if progress < 1.0 then
            local sheen_width = width * 0.4
            local start_x = p.x - sheen_width
            local end_x = p.x + width + sheen_width
            local current_x = start_x + (end_x - start_x) * progress
            
            -- Рисуем наклонный блик
            draw_list:AddRectFilledMultiColor(
                imgui.ImVec2(current_x, p.y),
                imgui.ImVec2(current_x + S(30), p.y + height),
                0x00FFFFFF, -- Transparent
                0x40FFFFFF, -- White with alpha (Top Right)
                0x40FFFFFF, -- White with alpha (Bot Right)
                0x00FFFFFF  -- Transparent
            )
        end
        imgui.PopClipRect()
        
        -- Золотая рамка
        draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), 0xFFD700FF, S(10), 15, S(2))
        
        -- Бейдж "VIP" в углу
        local badge_size = S(24)
        draw_list:AddTriangleFilled(
            imgui.ImVec2(p.x + width - badge_size, p.y),
            imgui.ImVec2(p.x + width, p.y),
            imgui.ImVec2(p.x + width, p.y + badge_size),
            0xFFD700FF
        )
    else
        local border_col = is_hovered and imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary) or imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_tertiary)
        draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), border_col, S(10), 15, is_hovered and S(2) or S(1))
    end
    
    -- Иконка и Текст
    local center_x = p.x + (width / 2)
    local icon_size = S(38)
    local icon_y = p.y + S(15)
    
    local circle_col = is_vip_shop and 0x33D700FF or imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_tertiary)
    draw_list:AddCircleFilled(imgui.ImVec2(center_x, icon_y + icon_size/2), icon_size/2, circle_col)
    
    if font_fa then
        imgui.PushFont(font_fa)
        local icon = is_vip_shop and fa('crown') or fa('shop')
        local icon_col = is_vip_shop and 0xFFFFD700 or imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary)
        
        local txt_sz = imgui.CalcTextSize(icon)
        draw_list:AddText(imgui.ImVec2(center_x - txt_sz.x/2, icon_y + (icon_size - txt_sz.y)/2), icon_col, icon)
        imgui.PopFont()
    end
    
    -- Никнейм
    local nick_text = u8(shop.nickname)
    local nick_sz = imgui.CalcTextSize(nick_text)
    local text_y = icon_y + icon_size + S(8)
    
    local nick_col_u32 = is_vip_shop and 0xFFFFD700 or imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary)
    draw_list:AddText(imgui.ImVec2(center_x - nick_sz.x/2, text_y), nick_col_u32, nick_text)
    
    -- Название сервера
    local server_name = getServerDisplayName(shop.serverId)
    local srv_text = u8(server_name)
    
    imgui.SetWindowFontScale(0.85)
    local srv_sz = imgui.CalcTextSize(srv_text)
    draw_list:AddText(imgui.ImVec2(center_x - srv_sz.x/2, text_y + S(18)), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_secondary), srv_text)
    imgui.SetWindowFontScale(1.0)
    
    -- Статистика (продажа/скупка)
    local stats_y = p.y + height - S(25)
    local pad_x = S(15)
    
    local sell_count = shop.sell_count or 0
    local sell_col = sell_count > 0 and CURRENT_THEME.accent_success or CURRENT_THEME.text_hint
    
    if font_fa then
        imgui.PushFont(font_fa)
        local icon_up = fa('arrow_up')
        draw_list:AddText(imgui.ImVec2(p.x + pad_x, stats_y - S(2)), imgui.ColorConvertFloat4ToU32(sell_col), icon_up)
        imgui.PopFont()
    end
    draw_list:AddText(imgui.ImVec2(p.x + pad_x + S(16), stats_y), imgui.ColorConvertFloat4ToU32(sell_col), tostring(sell_count))
    
    local buy_count = shop.buy_count or 0
    local buy_col = buy_count > 0 and CURRENT_THEME.accent_secondary or CURRENT_THEME.text_hint
    local buy_str = tostring(buy_count)
    local buy_sz = imgui.CalcTextSize(buy_str)
    
    draw_list:AddText(imgui.ImVec2(p.x + width - pad_x - buy_sz.x, stats_y), imgui.ColorConvertFloat4ToU32(buy_col), buy_str)
    
    if font_fa then
        imgui.PushFont(font_fa)
        local icon_down = fa('arrow_down')
        local icon_sz = imgui.CalcTextSize(icon_down)
        draw_list:AddText(imgui.ImVec2(p.x + width - pad_x - buy_sz.x - icon_sz.x - S(4), stats_y - S(2)), imgui.ColorConvertFloat4ToU32(buy_col), icon_down)
        imgui.PopFont()
    end
    
    imgui.PopID()
end

local server_filter_idx = 0 
local server_combo_list = {}
local server_name_list = {}

-- Заполняем список серверов один раз
if #server_combo_list == 0 then
    table.insert(server_combo_list, u8"Все серверы")
    table.insert(server_name_list, "ALL")
    
    local unique_names = {}
    for ip, name in pairs(SERVER_NAMES) do
        if not unique_names[name] then unique_names[name] = ip end
    end
    
    local sorted_servers = {}
    for name, ip in pairs(unique_names) do
        table.insert(sorted_servers, {ip = ip, name = name})
    end
    
    table.sort(sorted_servers, function(a, b) return a.name < b.name end)
    
    for _, srv in ipairs(sorted_servers) do
        table.insert(server_combo_list, u8(srv.name))
        table.insert(server_name_list, srv.name)
    end
end

function detectCurrentServerIndex()
    local ip, port = sampGetCurrentServerAddress()
    local my_server_id = normalizeServerId(ip .. ":" .. port)
    local my_server_name = getServerDisplayName(my_server_id)
    
    for i, name in ipairs(server_name_list) do
        if name == my_server_name then
            server_filter_idx = i - 1 -- -1 так как 0 это "Все"
            return
        end
    end
end

function renderGlobalMarketTab()
    local full_w = imgui.GetContentRegionAvail().x

    if MarketData.selected_shop then
        renderShopDetailsView()
    else
        renderShopsListView()
    end
end

function renderModernShopItem(item, is_sell, custom_width)
    local p = imgui.GetCursorScreenPos()
    local w = custom_width or imgui.GetContentRegionAvail().x
    local h = S(50)
    local draw_list = imgui.GetWindowDrawList()
    
    local start_x = p.x
    local start_y = p.y
    
    local bg_col = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_tertiary)
    local hover_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(CURRENT_THEME.bg_tertiary.x + 0.05, CURRENT_THEME.bg_tertiary.y + 0.05, CURRENT_THEME.bg_tertiary.z + 0.05, 1.0))
    
    local is_hovered = imgui.IsMouseHoveringRect(p, imgui.ImVec2(start_x + w, start_y + h))
    draw_list:AddRectFilled(p, imgui.ImVec2(start_x + w, start_y + h), is_hovered and hover_col or bg_col, S(8))
    
    local accent = is_sell and CURRENT_THEME.accent_success or CURRENT_THEME.accent_primary
    draw_list:AddRectFilled(p, imgui.ImVec2(start_x + S(4), start_y + h), imgui.ColorConvertFloat4ToU32(accent), S(8), 5)

    local icon_size = S(32)
    local icon_pos_x = start_x + S(16)
    local icon_pos_y = start_y + (h - icon_size)/2
    
    draw_list:AddCircleFilled(imgui.ImVec2(icon_pos_x + icon_size/2, icon_pos_y + icon_size/2), icon_size/2, imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_main))
    
    if font_fa then
        imgui.PushFont(font_fa)
        local icon = is_sell and fa('box') or fa('bag_shopping')
        local tsz = imgui.CalcTextSize(icon)
        draw_list:AddText(imgui.ImVec2(icon_pos_x + (icon_size - tsz.x)/2, icon_pos_y + (icon_size - tsz.y)/2), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_secondary), icon)
        imgui.PopFont()
    end
    
    local content_x = icon_pos_x + icon_size + S(12)
    local name_y = start_y + S(8)
    
    local max_name_width = w - S(150) 
    imgui.PushClipRect(imgui.ImVec2(content_x, name_y), imgui.ImVec2(content_x + max_name_width, name_y + S(20)), true)
    draw_list:AddText(imgui.ImVec2(content_x, name_y), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary), u8(item.name))
    imgui.PopClipRect()
    
    local sub_y = name_y + S(20)
    local amount_str = u8(string.format("Количество: %s шт.", formatNumber(item.amount)))
    draw_list:AddText(imgui.ImVec2(content_x, sub_y), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint), amount_str)
    
    local price_str = formatMoney(item.price) .. " $"
    local price_sz = imgui.CalcTextSize(price_str)
    local price_x = start_x + w - price_sz.x - S(15)
    local price_y = start_y + (h - price_sz.y)/2
    
    draw_list:AddText(imgui.ImVec2(price_x, price_y), imgui.ColorConvertFloat4ToU32(accent), price_str)
    
    imgui.SetCursorScreenPos(p)
		if imgui.InvisibleButton("##item_"..tostring(item), imgui.ImVec2(w, h)) then
		if is_sell then
			setClipboardText(item.name)
			addToastNotification("Название скопировано", "info")
		end
	end
    
    imgui.SetCursorScreenPos(imgui.ImVec2(start_x, start_y + h + S(6))) 
end

function renderShopDetailsView()
    local shop = MarketData.selected_shop
    local total_w = imgui.GetContentRegionAvail().x
    
    local padding_x = S(15) 
    local content_w = total_w - (padding_x * 2) 

    if not MarketData.details_tab then MarketData.details_tab = 1 end

    local function setIndent() imgui.SetCursorPosX(padding_x) end

    if not shop then
        setIndent()
        imgui.TextColored(CURRENT_THEME.text_hint, u8"Данные отсутствуют.")
        setIndent()
        if imgui.Button(u8"Вернуться", imgui.ImVec2(S(120), S(35))) then
            MarketData.selected_shop = nil
        end
        return
    end

    setIndent()
    imgui.BeginGroup()
        if imgui.Button(fa('chevron_left'), imgui.ImVec2(S(40), S(40))) then
            MarketData.selected_shop = nil
        end
        
        imgui.SameLine()
        
        local p = imgui.GetCursorScreenPos()
        local draw_list = imgui.GetWindowDrawList()
        local avatar_sz = S(40)
        
        draw_list:AddCircleFilled(
            imgui.ImVec2(p.x + avatar_sz / 2, p.y + avatar_sz / 2),
            avatar_sz / 2,
            imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_tertiary)
        )

        if font_fa then
            imgui.PushFont(font_fa)
            local icon = fa('user')
            local isz = imgui.CalcTextSize(icon)
            draw_list:AddText(
                imgui.ImVec2(
                    p.x + (avatar_sz - isz.x) / 2,
                    p.y + (avatar_sz - isz.y) / 2
                ),
                imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_secondary),
                icon
            )
            imgui.PopFont()
        end
        
        local text_x = p.x + avatar_sz + S(12)
        draw_list:AddText(
            imgui.ImVec2(text_x, p.y),
            imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary),
            u8(shop.nickname)
        )

        local server_name = getServerDisplayName(shop.serverId)
        draw_list:AddText(
            imgui.ImVec2(text_x, p.y + S(20)),
            imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint),
            u8(server_name)
        )

        -- =====================================================
        -- === ИДЕАЛЬНАЯ ЛОГИКА GPS ============================
        -- =====================================================
        local target_id = -1
        
        -- 1. Главный метод: Поиск по нику с учетом кодировок
        if shop.nickname then
            target_id = findPlayerIdByNickname(shop.nickname)
        end

        -- 2. Резервный метод: Если по нику не нашли (например, сложный ник), 
        -- проверяем ID, который прислал сервер, если он там есть.
        if target_id == -1 and shop.playerId and shop.playerId ~= -1 then
            if sampIsPlayerConnected(shop.playerId) then
                -- Но убедимся, что это не другой игрок (сравним первые 3 буквы ника)
                -- Это защита от того, что ID уже занял другой человек
                local server_nick = sampGetPlayerNickname(shop.playerId) or ""
                local shop_nick = shop.nickname or ""
                
                if server_nick ~= "" and shop_nick ~= "" then
                    -- Грубое сравнение начал строк, чтобы отсеять явные несовпадения
                    if string.sub(server_nick, 1, 3):lower() == string.sub(shop_nick, 1, 3):lower() then
                        target_id = shop.playerId
                    end
                end
            end
        end

        local can_track = (target_id ~= -1)
        -- =====================================================

        local ip, port = sampGetCurrentServerAddress()
        local my_server_id = normalizeServerId(ip .. ":" .. port)
        local shop_server_id = normalizeServerId(shop.serverId)
        
        -- Проверка: совпадают ли сервера
        local is_same_server = (my_server_id == shop_server_id)
        local has_nickname = (shop.nickname and shop.nickname ~= "")
        
        -- Кнопка активна ТОЛЬКО если есть ник И мы на одном сервере
        local can_click_gps = is_same_server and has_nickname
        
        local gps_btn_sz = S(40)
        imgui.SetCursorPosX(padding_x + content_w - gps_btn_sz) 
        
        -- Визуальное состояние кнопки
        if not can_click_gps then
            -- Серый цвет (неактивна)
            imgui.PushStyleColor(imgui.Col.Button, CURRENT_THEME.bg_tertiary)
            imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_hint)
        else
            -- Акцентный цвет (активна)
            imgui.PushStyleColor(imgui.Col.Button, CURRENT_THEME.accent_primary)
            imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_primary)
        end
        
        if imgui.Button(fa('location_dot') .. "##gps", imgui.ImVec2(gps_btn_sz, gps_btn_sz)) then
            if can_click_gps then
                -- === ВЫПОЛНЯЕМ ПОИСК (Используем исправленную функцию поиска) ===
                local found_id = findPlayerIdByNickname(shop.nickname)
                
                if found_id ~= -1 then
                    print("[RMarket] GPS: Игрок найден ID: " .. found_id)
                    sampSendChat("/findilavka " .. found_id)
                    addToastNotification("Метка установлена на ID: " .. found_id, "success")
                else
                    print("[RMarket] GPS Error: Ник '" .. tostring(shop.nickname) .. "' не найден.")
                    
                    -- Резервный поиск по старому ID
                    if shop.playerId and shop.playerId ~= -1 and sampIsPlayerConnected(shop.playerId) then
                         sampSendChat("/findilavka " .. shop.playerId)
                         addToastNotification("Использован ID: " .. shop.playerId, "warning")
                    else
                        addToastNotification("Игрок не найден в сети", "error")
                    end
                end
            elseif not is_same_server then
                addToastNotification("Лавка находится на другом сервере!", "error")
            end
        end
        
        -- Подсказка при наведении, если сервера разные
        if imgui.IsItemHovered() and not is_same_server then
             imgui.SetTooltip(u8"Недоступно: Вы находитесь на другом сервере")
        end
        
        imgui.PopStyleColor(2)
        
    imgui.EndGroup()
    
    imgui.Dummy(imgui.ImVec2(0, S(15)))
    
    setIndent()
    local tab_w = content_w / 2
    local tab_h = S(35)
    
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, 0)) 
    
    local function drawTabBtn(id, name, icon, count, color)
        local is_act = MarketData.details_tab == id
        if is_act then
            imgui.PushStyleColor(imgui.Col.Button, CURRENT_THEME.bg_tertiary)
            imgui.PushStyleColor(imgui.Col.Text, color)
        else
            imgui.PushStyleColor(imgui.Col.Button, CURRENT_THEME.bg_main)
            imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_secondary)
        end
        
        if imgui.Button(string.format("%s %s (%d)", icon, name, count), imgui.ImVec2(tab_w, tab_h)) then
            MarketData.details_tab = id
        end
        
        if is_act then
            local min = imgui.GetItemRectMin()
            local max = imgui.GetItemRectMax()
            imgui.GetWindowDrawList():AddRectFilled(
                imgui.ImVec2(min.x, max.y - S(2)),
                max,
                imgui.ColorConvertFloat4ToU32(color),
                S(2)
            )
        end
        imgui.PopStyleColor(2)
    end
    
    drawTabBtn(1, u8("ПРОДАЖА"), fa('arrow_up_from_bracket'), #shop.sell_list, CURRENT_THEME.accent_success)
    imgui.SameLine()
    drawTabBtn(2, u8("СКУПКА"), fa('arrow_down_to_bracket'), #shop.buy_list, CURRENT_THEME.accent_primary)
    
    imgui.PopStyleVar()
    
    imgui.Dummy(imgui.ImVec2(0, S(5)))
    
    setIndent()
    
    local list_h = imgui.GetContentRegionAvail().y - S(5)
    
    imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_main)
    imgui.BeginChild("DetailsListScroll", imgui.ImVec2(content_w, list_h), false)
        
        local list = (MarketData.details_tab == 1) and shop.sell_list or shop.buy_list
        local is_sell = (MarketData.details_tab == 1)
        
        if #list == 0 then
            imgui.Dummy(imgui.ImVec2(0, S(30)))
            local txt = u8"Список пуст"
            local tw = imgui.CalcTextSize(txt).x
            imgui.SetCursorPosX((content_w - tw) / 2)
            imgui.TextColored(CURRENT_THEME.text_hint, txt)
        else
            imgui.Dummy(imgui.ImVec2(0, S(5)))
            for _, item in ipairs(list) do
                renderModernShopItem(item, is_sell, content_w)
            end
            imgui.Dummy(imgui.ImVec2(0, S(10)))
        end
        
    imgui.EndChild()
    imgui.PopStyleColor()
end

function renderMarketItemRowStyled(index, item, is_sell)
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    local h = S(45)
    local draw_list = imgui.GetWindowDrawList()
    
    local accent = is_sell and CURRENT_THEME.accent_success or CURRENT_THEME.accent_primary
    
    
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_tertiary), S(6))
    
    
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + S(3), p.y + h), imgui.ColorConvertFloat4ToU32(accent), S(6), 5)
    
    
    local text_x = p.x + S(12)
    local text_y = p.y + S(5)
    
    
    draw_list:AddText(imgui.ImVec2(text_x, text_y), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary), u8(item.name or "???"))
    
    
    local sub_y = p.y + S(24)
    draw_list:AddText(imgui.ImVec2(text_x, sub_y), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_secondary), u8("x" .. (item.amount or 0)))
    
    
    local price_str = formatMoney(item.price or 0) .. " $"
    local p_sz = imgui.CalcTextSize(price_str)
    draw_list:AddText(imgui.ImVec2(p.x + w - p_sz.x - S(10), p.y + (h - p_sz.y)/2), imgui.ColorConvertFloat4ToU32(accent), price_str)
    
    
    imgui.SetCursorScreenPos(p)
    
    if imgui.InvisibleButton("##row_"..index.."_"..(is_sell and "s" or "b"), imgui.ImVec2(w, h)) then
         if not is_sell then
            
            local found = false
            for _, existing_item in ipairs(Data.buy_list) do
                if existing_item.name == item.name then
                    existing_item.amount = (existing_item.amount or 1) + 1
                    found = true
                    break
                end
            end
            if not found then
                table.insert(Data.buy_list, {
                    name = item.name,
                    price = item.price or 100,
                    amount = 1,
                    active = true,
                    model_id = -1,
                    index = item.index or -1
                })
            end
            saveListsConfig()
            calculateBuyTotal()
            addToastNotification("Товар добавлен в скупку", "success", 2.0)
        end
    end
    
    if imgui.IsItemHovered() then
        draw_list:AddRect(p, imgui.ImVec2(p.x + w, p.y + h), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1,1,1,0.1)), S(6))
        if not is_sell then imgui.SetTooltip(u8("Нажмите, чтобы добавить в свою скупку")) end
    end
    
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + h + S(6)))
end

function searchItemsInShops(search_query)
    local search_q = to_lower(search_query)
    local results_sell = {}
    local results_buy = {}
    
    if search_q == "" then return {}, {} end
    
    -- Определяем имя выбранного сервера для фильтрации
    local selected_server_name = nil
    if server_filter_idx > 0 and server_name_list[server_filter_idx + 1] then
        selected_server_name = server_name_list[server_filter_idx + 1]
    end
    
    for _, shop in ipairs(MarketData.shops_list) do
        local pass_server = true
        
        -- Фильтрация по серверу, если он выбран в меню
        if selected_server_name then
            local shop_server_name = getServerDisplayName(shop.serverId)
            if shop_server_name ~= selected_server_name then 
                pass_server = false 
            end
        end

        if pass_server then
            -- Обработка списка ПРОДАЖИ
            if shop.sell_list then
                for _, item in ipairs(shop.sell_list) do
                    local i_name = item.name or ""
                    local clean_name = enhancedCleanItemName(i_name)
                    local score = SmartSearch.getMatchScore(search_q, clean_name)
                    
                    if score > 0 then
                        table.insert(results_sell, {
                            item_name = clean_name, 
                            original_name = i_name,
                            price = item.price,
                            amount = item.amount,
                            shop_nickname = shop.nickname,
                            server_id = shop.serverId,
                            server_name = getServerDisplayName(shop.serverId),
                            is_sell = true,
                            vip = shop.vip,
                            score = score 
                        })
                    end
                end
            end

            -- Обработка списка СКУПКИ
            if shop.buy_list then
                for _, item in ipairs(shop.buy_list) do
                    local i_name = item.name or ""
                    local clean_name = enhancedCleanItemName(i_name)
                    local score = SmartSearch.getMatchScore(search_q, clean_name)
                    
                    if score > 0 then
                        table.insert(results_buy, {
                            item_name = clean_name, 
                            original_name = i_name,
                            price = item.price,
                            amount = item.amount,
                            shop_nickname = shop.nickname,
                            server_id = shop.serverId,
                            server_name = getServerDisplayName(shop.serverId),
                            is_sell = false,
                            vip = shop.vip,
                            score = score 
                        })
                    end
                end
            end
        end
    end
    
    -- Сортировка
    table.sort(results_sell, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return (a.price or 0) < (b.price or 0)
    end)

    table.sort(results_buy, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return (a.price or 0) > (b.price or 0)
    end)
    
    return results_sell, results_buy
end

function renderShopsListView()
    local full_w = imgui.GetContentRegionAvail().x
    local full_h = imgui.GetContentRegionAvail().y
    
    local search_raw = ffi.string(MarketData.search_buffer)
    local search_q = ""
    
    if search_raw ~= "" then 
        search_q = to_lower(safe_decode(search_raw)) 
    end
    
    local is_search_mode = (search_q ~= "")
    
    -- === ВЫБОР СЕРВЕРА ===
    -- Блок фильтрации (показываем только если не идет поиск, или для инфо)
    if not is_search_mode then
        local margin_side = S(20)
        imgui.SetCursorPosX(margin_side)
        imgui.PushItemWidth(S(200))
        
        pushComboStyles()
        local current_text = server_combo_list[server_filter_idx + 1] or u8"Все серверы"
        if imgui.BeginCombo("##server_filter", current_text) then
            for i, item in ipairs(server_combo_list) do
                local is_selected = (server_filter_idx == (i - 1))
                if imgui.Selectable(item, is_selected) then
                    server_filter_idx = i - 1
                end
                if is_selected then
                    imgui.SetItemDefaultFocus()
                end
            end
            imgui.EndCombo()
        end
        popComboStyles()
        imgui.PopItemWidth()
        imgui.Spacing()
    end
    -- ===================================
    
    -- Получаем текущее имя сервера для отображения
    local ip, port = sampGetCurrentServerAddress()
    local current_server_id = normalizeServerId(ip .. ":" .. port)
    local current_server_name = getServerDisplayName(current_server_id)

    -- Если идет загрузка
    if MarketData.is_loading then
        imgui.Spacing()
        local spinner_text = u8("Загрузка рынка (" .. current_server_name .. ")...")
        local text_size = imgui.CalcTextSize(spinner_text)
        
        local center_y = full_h / 2 - S(20)
        imgui.SetCursorPosY(center_y)
        
        if font_fa then
             imgui.PushFont(font_fa)
             local icon_size = imgui.CalcTextSize(fa('spinner'))
             imgui.SetCursorPosX((full_w - icon_size.x) / 2)
             imgui.TextColored(CURRENT_THEME.accent_primary, fa('spinner'))
             imgui.PopFont()
        end
        
        imgui.SetCursorPosX((full_w - text_size.x) / 2)
        imgui.TextColored(CURRENT_THEME.text_secondary, spinner_text)
        return
    end

    -- Если список пуст
    if #MarketData.shops_list == 0 then
        local text = u8("Нет данных для сервера " .. current_server_name .. ".")
        local sub_text = u8("Нажмите кнопку обновления (справа сверху).")
        
        local t_size = imgui.CalcTextSize(text)
        local s_size = imgui.CalcTextSize(sub_text)
        
        local center_y = full_h / 2 - S(20)
        imgui.SetCursorPosY(center_y)
        
        imgui.SetCursorPosX((full_w - t_size.x) / 2)
        imgui.TextColored(CURRENT_THEME.text_primary, text)
        
        imgui.SetCursorPosX((full_w - s_size.x) / 2)
        imgui.TextColored(CURRENT_THEME.text_hint, sub_text)
        return
    end

    -- === ЛОГИКА ОТОБРАЖЕНИЯ ===
    
    if is_search_mode then
        -- Получаем результаты поиска (разделенные)
        local found_sell, found_buy = searchItemsInShops(search_q)
        local has_results = (#found_sell > 0) or (#found_buy > 0)
        
        if not has_results then
            local text = u8("Товары не найдены")
            local t_size = imgui.CalcTextSize(text)
            imgui.SetCursorPosY(full_h / 2 - S(10))
            imgui.SetCursorPosX((full_w - t_size.x) / 2)
            imgui.TextColored(CURRENT_THEME.text_hint, text)
        else
            -- Используем Child окна для идеального выравнивания
            local spacing = S(10)
            local col_width = (full_w - spacing) / 2
            local list_h = imgui.GetContentRegionAvail().y

            -- >> ЛЕВАЯ КОЛОНКА (ПРОДАЖА) <<
            imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
            imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0,0,0,0)) -- Прозрачный фон child
            
            imgui.BeginChild("SearchColSell", imgui.ImVec2(col_width, list_h), false)
                renderUnifiedHeader(u8"Продают (" .. #found_sell .. ")", fa('arrow_up_from_bracket'))
                
                -- Внутренний скролл для списка
                imgui.BeginChild("SearchListSell", imgui.ImVec2(col_width, list_h - S(45)), false)
                    if #found_sell == 0 then
                        imgui.TextColored(CURRENT_THEME.text_hint, u8" Нет предложений")
                    else
                        local render_limit = 50
                        for i, result in ipairs(found_sell) do
                            if i > render_limit then 
                                imgui.TextColored(CURRENT_THEME.text_hint, u8("... еще " .. (#found_sell - render_limit)))
                                break 
                            end
                            renderMarketSearchResultCard(result, col_width, i)
                        end
                    end
                imgui.EndChild()
            imgui.EndChild()

            imgui.SameLine()
            imgui.SetCursorPosX(col_width + spacing)

            -- >> ПРАВАЯ КОЛОНКА (СКУПКА) <<
            imgui.BeginChild("SearchColBuy", imgui.ImVec2(col_width, list_h), false)
                renderUnifiedHeader(u8"Скупают (" .. #found_buy .. ")", fa('arrow_down_to_bracket'))
                
                -- Внутренний скролл для списка
                imgui.BeginChild("SearchListBuy", imgui.ImVec2(col_width, list_h - S(45)), false)
                    if #found_buy == 0 then
                        imgui.TextColored(CURRENT_THEME.text_hint, u8" Нет запросов")
                    else
                        local render_limit = 50
                        for i, result in ipairs(found_buy) do
                            if i > render_limit then 
                                imgui.TextColored(CURRENT_THEME.text_hint, u8("... еще " .. (#found_buy - render_limit)))
                                break 
                            end
                            renderMarketSearchResultCard(result, col_width, i + 1000)
                        end
                    end
                imgui.EndChild()
            imgui.EndChild()
            
            imgui.PopStyleColor()
            imgui.PopStyleVar()
        end
        
    else
        -- === РЕЖИМ БЕЗ ПОИСКА: СПИСОК ЛАВОК (ТОЛЬКО СВОЙ СЕРВЕР) ===
        renderSmoothScrollBox("MarketListScroll", imgui.ImVec2(full_w, 0), function()
            local filtered_shops = {}
            for _, shop in ipairs(MarketData.shops_list) do
                if server_filter_idx == 0 then
                    table.insert(filtered_shops, shop)
                else
                    local selected_server_name = server_name_list[server_filter_idx + 1]
                    local shop_server_name = getServerDisplayName(shop.serverId)
                    if shop_server_name == selected_server_name then
                        table.insert(filtered_shops, shop)
                    end
                end
            end
            
            if #filtered_shops == 0 then
                    local text = u8("На выбранном сервере нет активных лавок с модом")
                    local t_size = imgui.CalcTextSize(text)
                    imgui.SetCursorPosX((full_w - t_size.x) / 2)
                    imgui.TextColored(CURRENT_THEME.text_hint, text)
            else
                -- Отображение плиток с лавками
                imgui.TextColored(CURRENT_THEME.text_secondary, u8("Активные лавки: " .. #filtered_shops))
                
                local min_card_width = S(160)
                local spacing_x = S(12)
                local spacing_y = S(12)
                
                local page_padding = S(10) 
                local available_w_for_grid = full_w - (page_padding * 2)
                
                local columns = math.floor((available_w_for_grid + spacing_x) / (min_card_width + spacing_x))
                if columns < 2 then columns = 2 end
                
                local item_w = (available_w_for_grid - (spacing_x * (columns - 1))) / columns
                
                imgui.SetCursorPosX(page_padding)
                
                for i, shop in ipairs(filtered_shops) do
                    local col_idx = (i - 1) % columns
                    
                    if col_idx > 0 then
                        imgui.SameLine(0, spacing_x)
                    else
                        if i > 1 then imgui.SetCursorPosX(page_padding) end
                    end
                    
                    renderShopCardGrid(shop, item_w)
                    
                    if col_idx == columns - 1 then
                        imgui.Dummy(imgui.ImVec2(0, spacing_y))
                    end
                end
            end
            imgui.Spacing()
        end)
    end
end

function formatNumber(n)
    if n == nil then return "0" end
    local s = tostring(math.floor(n))
    
    local formatted = s:reverse():gsub("(...)", "%1 "):reverse()
    formatted = formatted:gsub("^%s+", "")
    return formatted
end

function renderMarketSearchResultCard(result, width, index)
    local draw_list = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local height = S(65)
    
    local type_color = result.is_sell and CURRENT_THEME.accent_success or CURRENT_THEME.accent_primary
    local icon_char = result.is_sell and fa('box') or fa('bag_shopping')
    
    local is_me = (result.shop_nickname == getSafeLocalNickname())
    local is_vip = result.vip
    if is_me and Data.is_vip then is_vip = true end

    -- Цвета фона
    local col_bg_base = CURRENT_THEME.bg_secondary
    
    -- [VIP ЭФФЕКТ] Градиентный фон для VIP в поиске
    if is_vip then
        -- Легкий золотистый оттенок
        draw_list:AddRectFilledMultiColor(
            p, imgui.ImVec2(p.x + width, p.y + height),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.12, 0.10, 0.05, 1.0)), -- Left
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.09, 0.09, 0.11, 1.0)), -- Right
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.09, 0.09, 0.11, 1.0)),
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.12, 0.10, 0.05, 1.0))
        )
        -- Тонкая золотая рамка
        draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), 0x40FFD700, S(8))
    else
        draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), imgui.ColorConvertFloat4ToU32(col_bg_base), S(8))
    end
    
    -- Цветная полоска слева
    local bar_col_u32 = is_vip and 0xFFFFD700 or imgui.ColorConvertFloat4ToU32(type_color)
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + S(3), p.y + height), bar_col_u32, S(8), 5)
    
    -- Иконка
    local icon_size = S(36)
    local icon_x = p.x + S(12)
    local icon_y = p.y + (height - icon_size) / 2
    
    draw_list:AddCircleFilled(imgui.ImVec2(icon_x + icon_size/2, icon_y + icon_size/2), 
        icon_size/2, imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_tertiary))
    
    if font_fa then
        imgui.PushFont(font_fa)
        local txt_sz = imgui.CalcTextSize(icon_char)
        local ico_col = is_vip and 0xFFFFD700 or imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_secondary)
        draw_list:AddText(imgui.ImVec2(icon_x + (icon_size - txt_sz.x)/2, icon_y + (icon_size - txt_sz.y)/2), 
            ico_col, icon_char)
        imgui.PopFont()
    end
    
    local info_x = icon_x + icon_size + S(10)
    local right_padding = S(10)
    
    -- 1. Название товара
    local line1_y = p.y + S(8)
    imgui.PushFont(font_default)
    
    local text_col = CURRENT_THEME.text_primary
    if is_vip then text_col = imgui.ImVec4(1.0, 0.95, 0.8, 1.0) end -- Чуть ярче для VIP
    
    imgui.PushClipRect(imgui.ImVec2(info_x, line1_y), imgui.ImVec2(p.x + width - S(10), line1_y + S(20)), true)
    draw_list:AddText(imgui.ImVec2(info_x, line1_y), imgui.ColorConvertFloat4ToU32(text_col), u8(result.item_name))
    imgui.PopClipRect()
    imgui.PopFont()
    
    -- 2. Ник игрока и сервер
    local line2_y = p.y + S(24)
    local shop_info = string.format("%s | %s", result.shop_nickname, result.server_name)
    local shop_info_col = is_vip and 0xFFFFD700 or imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_secondary)
    
    if is_vip and font_fa then imgui.PushFont(font_fa) end
    draw_list:AddText(imgui.ImVec2(info_x, line2_y), shop_info_col, u8(shop_info))
    if is_vip and font_fa then imgui.PopFont() end
    
    -- 3. Количество
    local line3_y = p.y + S(40)
    local amount_str = "Кол-во: " .. formatNumber(result.amount or 0)
    draw_list:AddText(imgui.ImVec2(info_x, line3_y), 
        imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint), u8(amount_str))
    
    -- 4. Цена (справа)
    local price_str = formatMoney(result.price or 0) .. u8" $"
    local price_sz = imgui.CalcTextSize(price_str)
    local price_x = p.x + width - price_sz.x - S(12)
    local price_y = p.y + (height - price_sz.y)/2
    
    draw_list:AddText(imgui.ImVec2(price_x, price_y), 
        imgui.ColorConvertFloat4ToU32(type_color), price_str)
    
    -- Кнопка для клика
    local unique_id = string.format("##res_%s_%s_%d", result.shop_nickname, result.item_name, index)
    imgui.SetCursorScreenPos(p)
    if imgui.InvisibleButton(unique_id, imgui.ImVec2(width, height)) then
        api_FetchShopDetails(result.server_id, result.shop_nickname)
    end
    
    -- Ховер эффект
    if imgui.IsItemHovered() then
        draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), 
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.1)), S(8), 15, S(2))
        imgui.SetTooltip(u8("Нажмите, чтобы открыть лавку игрока " .. result.shop_nickname))
    end
    
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + height + S(6)))
end

function renderModernLogCard(log, width)
    local draw_list = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local height = S(60)
    
    local is_sale = log.type == "sale"
    local theme_col = is_sale and CURRENT_THEME.accent_success or CURRENT_THEME.accent_danger
    local icon = is_sale and fa('arrow_up_from_bracket') or fa('cart_shopping')
    
    -- [FIX] Фон карточки = secondary (серый), а фон списка будет main (темный).
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary), S(8))
    
    -- Цветная полоска слева
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + S(4), p.y + height), imgui.ColorConvertFloat4ToU32(theme_col), S(8), 5) 
    
    -- Иконка
    local icon_size = S(32)
    local icon_pos = imgui.ImVec2(p.x + S(16), p.y + (height - icon_size)/2)
    draw_list:AddCircleFilled(imgui.ImVec2(icon_pos.x + icon_size/2, icon_pos.y + icon_size/2), icon_size/2, imgui.ColorConvertFloat4ToU32(imgui.ImVec4(theme_col.x, theme_col.y, theme_col.z, 0.15)))
    
    imgui.PushFont(font_fa)
    local txt_sz = imgui.CalcTextSize(icon)
    draw_list:AddText(imgui.ImVec2(icon_pos.x + (icon_size - txt_sz.x)/2, icon_pos.y + (icon_size - txt_sz.y)/2), imgui.ColorConvertFloat4ToU32(theme_col), icon)
    imgui.PopFont()
    
    local content_x = p.x + S(60)
    local right_margin = S(15)
    
    -- Название товара
    local item_name = u8(log.item)
    local max_name_w = width - S(200) 
    imgui.PushClipRect(imgui.ImVec2(content_x, p.y), imgui.ImVec2(content_x + max_name_w, p.y + height), true)
    draw_list:AddText(imgui.ImVec2(content_x, p.y + S(8)), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary), item_name)
    imgui.PopClipRect()
    
    -- Мета-информация
    local meta_text = string.format("%s | %s", u8(log.player), log.date:match("%d%d:%d%d:%d%d") or log.date)
    draw_list:AddText(imgui.ImVec2(content_x, p.y + S(34)), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint), meta_text)
    
    -- Правая часть (Цены)
    local total_str = formatMoney(log.total) .. " $"
    local total_sz = imgui.CalcTextSize(total_str)
    
    draw_list:AddText(
        imgui.ImVec2(p.x + width - total_sz.x - right_margin, p.y + S(8)), 
        imgui.ColorConvertFloat4ToU32(is_sale and CURRENT_THEME.accent_success or CURRENT_THEME.accent_danger), 
        total_str
    )
    
    local details_str = ""
    if log.amount > 1 then
        details_str = string.format("%s шт. x %s $", formatNumber(log.amount), formatMoney(log.price))
    else
        details_str = "1 шт."
    end
    
    local details_u8 = u8(details_str)
    local details_sz = imgui.CalcTextSize(details_u8)
    
    draw_list:AddText(
        imgui.ImVec2(p.x + width - details_sz.x - right_margin, p.y + S(34)), 
        imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_secondary), 
        details_u8
    )
    
    imgui.SetCursorScreenPos(p)
    imgui.InvisibleButton("##log_"..tostring(log), imgui.ImVec2(width, height))
    
    if imgui.IsItemHovered() then
        draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1,1,1,0.1)), S(8), 15, S(1))
        
        imgui.BeginTooltip()
        imgui.Text(u8("Товар: ") .. item_name)
        imgui.Text(u8("Цена за шт: ") .. formatMoney(log.price) .. " $")
        imgui.Text(u8("Количество: ") .. formatNumber(log.amount))
        imgui.Separator()
        imgui.TextColored(is_sale and CURRENT_THEME.accent_success or CURRENT_THEME.accent_danger, u8("Итого: ") .. total_str)
        imgui.EndTooltip()
    end
    
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + height + S(8)))
end

function string.trim(s)
    return s:match("^%s*(.-)%s*$")
end

local ITEM_PREFIXES = {
    "Улучшение оружия", "Унив. тюнинг", "Виз. тюнинг", "Тех. тюнинг", "Авто. номер",
    "Аксессуар", "Сертификат", "Приманка", "Саженец", "Улучшение",
    "Винила", "Объект", "Одежда", "Телефон", "Урожай", "Чертёж",
    "Предмет", "Актер", "Ларец", "Рыба", "Семя", "Туша", "Шкура", "Ящик"
}

-- Базовая очистка от цветов и тегов
function enhancedCleanItemName(name)
    if not name then return "" end
    -- 1. Убираем цвета {FFFFFF} и теги в квадратных скобках [text]
    name = name:gsub("{......}", ""):gsub("%[.-%]", "")
    -- 2. Убираем ID предмета в скобках (id: 123)
    name = name:gsub("%s*%(id:?%s*%d+%)", "")
    -- 3. Убираем количество (x10), (10 шт.)
    name = name:gsub("%s*%(%s*x?%s*%d+%s*%)", "")
    name = name:gsub("%s*%(%s*%d+%s*шт%.?%s*%)", "")
    -- 4. Убираем окончания и мусор в начале (если есть)
    name = name:gsub("^ов%s+", ""):gsub("^ев%s+", ""):gsub("^шт%s+", ""):gsub("^кг%s+", "")
    return string.trim(name)
end

-- Вспомогательная функция проверки заглавной буквы (CP1251 + Latin)
local function isUpperCaseByte(byte)
    if not byte then return false end
    -- Latin A-Z (65-90)
    if byte >= 65 and byte <= 90 then return true end
    -- Cyrillic А-Я (192-223)
    if byte >= 192 and byte <= 223 then return true end
    -- Ё (168)
    if byte == 168 then return true end
    return false
end

-- Полная очистка с умным удалением префиксов
function cleanItemName(name)
    if not name then return "" end
    name = enhancedCleanItemName(name)
    
    -- Пытаемся найти и удалить категорию из начала строки
    for _, prefix in ipairs(ITEM_PREFIXES) do
        -- Экранируем точки для паттерна (чтобы "Авто. номер" работал корректно)
        local safe_prefix = prefix:gsub("%.", "%%.")
        local pattern = "^" .. safe_prefix .. "%s+"
        
        local start_pos, end_pos = name:find(pattern)
        
        if start_pos then
            -- Проверяем следующий символ после префикса и пробела
            if end_pos < #name then
                local next_char_code = name:byte(end_pos + 1)
                
                -- [[ НОВАЯ ЛОГИКА ]]
                -- Если следующая буква ЗАГЛАВНАЯ - считаем, что это Префикс + Имя (удаляем префикс)
                -- Пример: "Ларец Инкассатора" -> "Инкассатора"
                if isUpperCaseByte(next_char_code) then
                    return string.trim(name:sub(end_pos + 1))
                else
                    -- Если маленькая буква, цифра или символ - это часть составного названия (оставляем как есть)
                    -- Пример: "Ларец инкассатора" -> "Ларец инкассатора" (не режем)
                    -- Пример: "Аксессуар на спину" -> "Аксессуар на спину"
                    return name
                end
            else
                -- Если строка заканчивается префиксом, возвращаем как есть
                return name
            end
        end
    end
    
    return name
end

function extractCategory(raw_name)
    if not raw_name then return "Предмет" end
    local clean_raw = enhancedCleanItemName(raw_name)
    
    for _, prefix in ipairs(ITEM_PREFIXES) do
        local safe_prefix = prefix:gsub("%.", "%%.")
        -- Ищем "Категория " (с пробелом) в начале
        if clean_raw:find("^" .. safe_prefix .. "%s") then
            return prefix
        end
    end
    return "Предмет" -- Дефолтная категория, если не нашли
end

-- Для ключей в базе данных (алиас для совместимости)
function cleanItemNameKey(name)
    return enhancedCleanItemName(name)
end

-- Алиас для совместимости со старым кодом
function cleanCategoryPrefix(name)
    return cleanItemName(name)
end

function parseStatsDialog(text)
    -- Агрессивная очистка текста от всех видов цветов и мусора
    local clean = text
        :gsub("{......}", "") -- Удаляем {FFFFFF}
        :gsub("{...}", "")
        :gsub("%[......%]", "") -- Удаляем [FFFFFF]
        :gsub("%[...%]", "")
        :gsub("\t", " ")
        :gsub("\194\160", " ") -- Удаляем неразрывные пробелы
        :gsub(" +", " ")       -- Сжимаем пробелы
    
    local data = {
        level = 0,
        vip = "Нет",
        cash = 0,
        bank = 0,
        deposit = 0,
        job = "Безработный",
        org = "Нет",
        fam = "Нет"
    }
    
    local function parseMoney(line, pattern)
        if not line then return 0 end
        -- Ищем цифры с точками или пробелами
        local money_part = line:match(pattern .. "[:%s]*([%d%.%s]+)")
        if not money_part then 
            -- Запасной вариант: ищем просто число в конце строки перед "руб"
            money_part = line:match("[:%s]*([%d%.%s]+)%s*руб") 
        end
        
        if money_part then
            -- Удаляем точки и пробелы, чтобы получить чистое число
            local cleaned = money_part:gsub("%.", ""):gsub("%s", "")
            return tonumber(cleaned) or 0
        end
        return 0
    end
    
    for line in clean:gmatch("[^\r\n]+") do
        line = string.trim(line)
        
        if line:find("Уровень:", 1, true) then
            local level = line:match("Уровень:%s*(%d+)")
            data.level = tonumber(level) or 0
            
        elseif line:find("VIP статус:", 1, true) then
            local vip = line:match("VIP статус:%s*(.+)")
            if vip then data.vip = u8:encode(string.trim(vip)) end
            
        elseif line:find("Наличные деньги:", 1, true) then
            data.cash = parseMoney(line, "Наличные деньги")
            
        elseif line:find("Деньги в банке:", 1, true) then
            data.bank = parseMoney(line, "Деньги в банке")
            
        elseif line:find("Деньги на депозите:", 1, true) then
            data.deposit = parseMoney(line, "Деньги на депозите")
            
        elseif line:find("Работа:", 1, true) and not line:find("Опыт", 1, true) then
            local job = line:match("Работа:%s*(.+)")
            if job then data.job = u8:encode(string.trim(job)) end
            
        elseif line:find("Организация:", 1, true) then
            local org = line:match("Организация:%s*(.+)")
            if org then data.org = u8:encode(string.trim(org)) end
            
        elseif line:find("Семья:", 1, true) and not line:find("В семье с", 1, true) then
            local fam = line:match("Семья:%s*(.+)")
            if fam then
                fam = fam:gsub("%s*%[ID:%s*%d+%]", "")
                data.fam = u8:encode(string.trim(fam))
            end
        end
    end
    
    return data
end

function sendStatsToAPI(statsData)
    if Data.settings.telegram_token == "" then return end
    
    -- [[ FIX: Добавляем никнейм в данные для привязки ]]
    -- Получаем актуальный ник. Если LOCAL_PLAYER_NICK еще нет, пробуем получить стандартно.
    local current_nick = LOCAL_PLAYER_NICK
    if not current_nick then
        local _, myId = sampGetPlayerIdByCharHandle(PLAYER_PED)
        local nick = sampGetPlayerNickname(myId)
        if nick then current_nick = nick:gsub("_", " ") end
    end
    
    -- Добавляем ник в таблицу статистики
    statsData.nickname = u8:encode(current_nick or "Unknown Player")

    local payload = {
        secret_key = Data.settings.telegram_token,
        data = statsData
    }
    
    asyncHttpRequest("POST", MarketConfig.HOST .. "/api/proxy/receive_stats", 
        {
            headers = {["Content-Type"] = "application/json"},
            data = json.encode(payload)
        },
        function(response)
            if response.status_code == 200 then
                if response.text and response.text:find("success") then
                    sampAddChatMessage('[RMarket] {00ff00}Статистика обновлена в Mini App!', -1)
                end
            end
        end
    )
end

function checkVipStatus(token)
    if not token or token == "" then Data.is_vip = false return end
    
    local current_nick = getSafeLocalNickname()
    
    -- [FIX] Если ник еще не загрузился из файла или stats, прерываем проверку
    -- Это предотвращает ошибку "key bound error" при старте
    if current_nick == "Unknown Player" or current_nick == "Loading..." then
        print("[RMarket] Ожидание ника для проверки VIP...")
        return
    end
    
    local payload = { 
        secret_key = token,
        nickname = u8:encode(current_nick)
    }
    
    asyncHttpRequest("POST", MarketConfig.HOST .. "/api/proxy/check_vip", 
        {
            headers = {["Content-Type"] = "application/json"},
            data = json.encode(payload)
        },
        function(response)
            if response.status_code == 200 then
                local ok, res = pcall(json.decode, response.text)
                if ok and res.status == 'success' then
                    Data.is_vip = res.is_vip
                    if Data.is_vip then
                        print("[RMarket] VIP Активен! Ост. дней: " .. res.days_left)
                        Data.vip_days = res.days_left
                    end
                elseif ok and res.status == 'error' and res.msg == 'key_bound_error' then
                    Data.is_vip = false
                    print("[RMarket] Ошибка: Ключ привязан к другому нику ("..(res.bound_to or "?").."). Ваш ник: " .. current_nick)
                end
            end
        end
    )
end

function switchToRemoteProfile(mode)
    local profileName = "Remote_Import"
    local configs = (mode == "sell") and Data.sell_configs or Data.buy_configs
    local targetIndex = -1

    -- 1. Ищем существующий профиль
    for i, cfg in ipairs(configs) do
        if cfg.name == profileName then
            targetIndex = i
            break
        end
    end

    -- 2. Если нет - создаем
    if targetIndex == -1 then
        if mode == "sell" then
            targetIndex = createSellConfig(profileName)
        else
            targetIndex = createBuyConfig(profileName)
        end
        -- Перезагружаем список, так как create возвращает индекс
        configs = (mode == "sell") and Data.sell_configs or Data.buy_configs
    end

    -- 3. Переключаемся на него
    if mode == "sell" then
        selectSellConfig(targetIndex)
    else
        selectBuyConfig(targetIndex)
    end
    
    return targetIndex
end

function checkRemoteActions()
    if Data.settings.telegram_token == "" then return end
    -- Блокируем проверку, если мы уже заняты чем-то важным
    if App.is_scanning or App.is_selling_cef or State.buying.active then return end 
    if #HttpWorker.queue > 0 or HttpWorker.thread then return end

    local url = MarketConfig.HOST .. "/api/proxy/action?type=check&secret_key=" .. Data.settings.telegram_token

    asyncHttpRequest("GET", url, { timeout = 10 },
        function(response)
            if response.status_code ~= 200 then return end
            if not response.text or response.text == "" then return end

            local ok, res = pcall(json.decode, response.text)
            if not ok or not res or not res.command or res.command == "none" then return end

            -- [СТАТИСТИКА]
            if res.command == 'stats' then
                State.stats_requested_by_script = true 
                sampSendChat("/stats")
            end
            
            -- [[ СКАН ИНВЕНТАРЯ ]]
            if res.command == 'scan_inventory' then
                if os.clock() - (State.last_inventory_scan_time or 0) > 10 then
                    sampAddChatMessage('[RodinaMarket] {ffff00}[Remote] Запрос на сканирование инвентаря...', -1)
                    State.last_inventory_scan_time = os.clock()
                    startScanning()
                end
            end
            
            -- [[ ПРОДАЖА ]]
            if res.command == 'start_sell' and res.payload then
                sampAddChatMessage('[RodinaMarket] {ffff00}[Remote] Получена команда на продажу!', -1)
                
                Data.cef_sell_queue = {}
                Data.cef_slots_data = {}
                
                for _, item in ipairs(res.payload) do
                    local name_cp = item.name
                    if u8 then
                        local s, r = pcall(u8.decode, u8, item.name)
                        if s then name_cp = r end
                    end
                    
                    table.insert(Data.cef_sell_queue, {
                        slot = tonumber(item.slot),
                        model = tonumber(item.model_id),
                        amount = tonumber(item.amount),
                        price = tonumber(item.price),
                        name = name_cp,
                        retry_count = 0
                    })
                end
                
                if #Data.cef_sell_queue > 0 then
                    App.live_shop_active = true
                    Marketplace.enabled = true
                    Marketplace.is_cleared = false
                    Marketplace.publish_sell = true
                    
                    App.is_selling_cef = true
                    App.current_sell_item_index = 0
                    App.current_processing_item = nil
                    
                    sampAddChatMessage('[RodinaMarket] {00ff00}Удаленная задача: ' .. #Data.cef_sell_queue .. ' товаров. Открываю лавку...', -1)
                    
                    lua_thread.create(function()
                        wait(500)
                        setVirtualKeyDown(0x12, true) -- ALT
                        wait(150)
                        setVirtualKeyDown(0x12, false)
                    end)
                end
            end

            -- [[ СКУПКА (НОВАЯ ЛОГИКА) ]]
            if res.command == 'start_buy' and res.payload then
                sampAddChatMessage('[RodinaMarket] {ffff00}[Remote] Получена команда на скупку!', -1)
                
                -- 1. Очищаем текущий список скупки
                Data.buy_list = {}
                
                -- 2. Заполняем данными из Telegram
                for _, item in ipairs(res.payload) do
                    local name_cp = item.name
                    -- Декодируем UTF-8 в CP1251
                    if u8 then
                        local s, r = pcall(u8.decode, u8, item.name)
                        if s then name_cp = r end
                    end
                    
                    -- Ищем ID предмета по имени, если его нет
                    local item_idx = tonumber(item.model_id)
                    if not item_idx or item_idx == -1 then
                         -- Пытаемся найти в базе имен
                         if Data.item_names_reversed then
                             local clean = cleanItemNameKey(name_cp)
                             item_idx = Data.item_names_reversed[clean] or -1
                         end
                    end
                    
                    table.insert(Data.buy_list, {
                        name = name_cp,
                        -- index = ID в диалоге скупки. Важно для аксессуаров и предметов
                        index = item_idx, 
                        amount = tonumber(item.amount),
                        price = tonumber(item.price),
                        active = true
                    })
                end
                
                if #Data.buy_list > 0 then
                    -- 3. Сохраняем и запускаем
                    saveListsConfig()
                    sampAddChatMessage('[RodinaMarket] {00ff00}Удаленная задача: ' .. #Data.buy_list .. ' товаров на скупку.', -1)
                    
                    -- Запускаем функцию скупки с флагом is_remote_start = true
                    -- Это заставит её обновить буферы интерфейса
                    startBuying(true)
                else
                    sampAddChatMessage('[RodinaMarket] {ff0000}Ошибка: Список товаров пуст или некорректен.', -1)
                end
            end
        end
    )
end

function api_SubmitTransaction(transaction)
    -- Генерируем ID сервера
    local ip, port = sampGetCurrentServerAddress()
    local server_id = normalizeServerId(ip .. ":" .. port)

    -- Подготавливаем данные
    local payload = {
        server     = server_id,
        item       = u8:encode(transaction.item),
        price      = transaction.price,
        count      = transaction.amount,
        action     = transaction.type, -- "sale" или "purchase"
        secret_key = Data.settings.telegram_token or "" -- Дублируем в теле для легаси PHP скриптов
    }

    -- Используем защищенную отправку
    signed_request(
        "POST",
        MarketConfig.HOST .. "/api/submit_price.php",
        payload,
        function(response)
            -- Можно добавить лог успеха для дебага
            -- if response.status_code == 200 then print("Price submitted secure") end
        end
    )
end

local last_log_refresh_timer = 0

function renderLogsTab()
    local full_avail_w = imgui.GetContentRegionAvail().x
    local avail_h = imgui.GetContentRegionAvail().y 
    local margin_side = S(20)
    local margin_bottom = S(20) 
    
    local content_w = full_avail_w - (margin_side * 2)

    local current_time = os.clock()
    if current_time - last_log_refresh_timer > 2.0 then
        refreshLogDates()
        last_log_refresh_timer = current_time
        
        if Buffers.logs_current_date_idx == 0 or Buffers.logs_current_date_idx == 1 then
             cached_income, cached_expense = updateLogView()
        end
    end

    local function setIndent()
        imgui.SetCursorPosX(margin_side) 
    end
    
    local current_idx = Buffers.logs_current_date_idx
    local current_boxes = tostring(Buffers.log_filters.show_sales[0]) .. tostring(Buffers.log_filters.show_purchases[0])
    
    if current_idx ~= last_log_idx or current_boxes ~= last_check_boxes or not Data.current_view_logs then
        cached_income, cached_expense = updateLogView()
        last_log_idx = current_idx
        last_check_boxes = current_boxes
    end
    
    local profit = cached_income - cached_expense
    local filtered_list = Data.current_view_logs or {}
    
    imgui.Dummy(imgui.ImVec2(0, S(10)))

    setIndent()
    imgui.BeginGroup()
        local card_h = S(70)
        local gap = S(15)
        local card_w = (content_w - (gap * 2)) / 3

        drawStatCard("Доход", cached_income, imgui.ImVec4(0.15, 0.35, 0.20, 0.6), card_w, card_h)
        imgui.SameLine(nil, gap)
        drawStatCard("Расход", cached_expense, imgui.ImVec4(0.35, 0.15, 0.15, 0.6), card_w, card_h)
        imgui.SameLine(nil, gap)
        local profit_col = profit >= 0 and imgui.ImVec4(0.2, 0.2, 0.35, 0.6) or imgui.ImVec4(0.35, 0.2, 0.2, 0.6)
        drawStatCard("Прибыль", profit, profit_col, card_w, card_h)
    imgui.EndGroup()

    imgui.Dummy(imgui.ImVec2(0, S(15)))
    
    setIndent()
    imgui.PushItemWidth(content_w)
    imgui.Separator()
    imgui.PopItemWidth()
    
    imgui.Dummy(imgui.ImVec2(0, S(15)))

    setIndent()
    imgui.BeginGroup()
        imgui.AlignTextToFramePadding()
        imgui.TextColored(CURRENT_THEME.text_secondary, fa('calendar') .. " " .. u8("Архив:"))
        imgui.SameLine()
        
        imgui.SetNextItemWidth(S(140))
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

        imgui.SameLine(nil, S(25))
        imgui.Checkbox(u8("Продажи"), Buffers.log_filters.show_sales)
        imgui.SameLine(nil, S(15))
        imgui.Checkbox(u8("Покупки"), Buffers.log_filters.show_purchases)
    imgui.EndGroup()

    imgui.Dummy(imgui.ImVec2(0, S(10)))

    local remaining_h = imgui.GetContentRegionAvail().y
    local list_height = remaining_h - margin_bottom
    
    setIndent()
    
    imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_main) -- Делаем фон скролла темным
    renderSmoothScrollBox("LogsListScroll", imgui.ImVec2(content_w, list_height), function()
        if #filtered_list == 0 then
            local text = u8("История операций пуста")
            local t_size = imgui.CalcTextSize(text)
            imgui.SetCursorPosX((content_w - t_size.x) / 2)
            imgui.SetCursorPosY(S(60))
            if font_fa then
                imgui.PushFont(font_fa)
                local icon = fa('box_open')
                local i_size = imgui.CalcTextSize(icon)
                imgui.SetCursorPosX((content_w - i_size.x) / 2)
                imgui.TextColored(CURRENT_THEME.text_hint, icon)
                imgui.PopFont()
            end
            imgui.SetCursorPosX((content_w - t_size.x) / 2)
            imgui.TextColored(CURRENT_THEME.text_hint, text)
        else
            imgui.Dummy(imgui.ImVec2(0, S(5)))
            
            for i, log in ipairs(filtered_list) do
                local search_q = ffi.string(Buffers.logs_search):lower()
                local item_n = (log.item or ""):lower()
                local player_n = (log.player or ""):lower()
                
                if search_q == "" or item_n:find(search_q) or player_n:find(search_q) then
                    renderModernLogCard(log, content_w)
                end
            end
            imgui.Dummy(imgui.ImVec2(0, S(10)))
        end
    end)
	imgui.PopStyleColor()
end

function countTable(tbl)
    local count = 0
    for _ in pairs(tbl) do count = count + 1 end
    return count
end

function attemptOpenSettings()
    if not App.is_scanning or not State.inventory_scan.active then return end

    State.inventory_scan.attempts = (State.inventory_scan.attempts or 0) + 1

    if State.inventory_scan.attempts > 3 then
        App.is_scanning = false
        State.inventory_scan.active = false
        State.inventory_scan.waiting_for_packets = false
        sampAddChatMessage('[RodinaMarket] {ff0000}Сканирование прервано (диалог настроек не открылся)!', -1)
        return
    end

    if State.inventory_scan.attempts > 1 then
        sampAddChatMessage(string.format('[RodinaMarket] {ffff00}Попытка открытия меню (%d/3)...', State.inventory_scan.attempts), -1)
    end

    sampSendChat('/settings')

    App.tasks.add("scan_retry_wait", function()
        attemptOpenSettings()
    end, 3000)
end

function startScanning()
    if App.is_scanning or App.is_selling_cef or App.is_scanning_buy or State.buying.active then return end
    
    if not State.inventory_scan then
        State.inventory_scan = { active = false, waiting_for_packets = false }
    end

    Data.cef_inventory_items = {}
    Data.scanned_items = {}
    Data.cef_slots_data = {} 
    
    App.is_scanning = true
    State.inventory_scan.active = true
    State.inventory_scan.waiting_for_packets = false 
    State.inventory_scan.attempts = 0
    
    State.inventory_scan.last_packet_time = 0
    State.inventory_scan.has_received_data = false
    State.inventory_scan.start_wait_time = 0
    
    sampAddChatMessage('[RodinaMarket] {ffff00}Начинаю сканирование через настройки...', -1)
    
    attemptOpenSettings()
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
        
        
        
        saveJsonFile(PATHS.CACHE .. 'scanned_items.json', Data.scanned_items)
        saveJsonFile(PATHS.DATA .. 'item_amounts.json', Data.inventory_item_amounts) 
        saveListsConfig() 
        
        App.is_scanning = false
        Data.cached_sell_filtered = nil 
        
        sampAddChatMessage('[RodinaMarket] {00ff00}Сканирование завершено! Найдено слотов: ' .. #Data.scanned_items, -1)
        App.win_state[0] = true
    end, 500)
end

function isSlotInSellList(slot_id, model_id)
    if not slot_id then return false end
    for _, item in ipairs(Data.sell_list) do
        if item.slot and tonumber(item.slot) == tonumber(slot_id) then 
            if model_id then
                if item.model_id and tonumber(item.model_id) == tonumber(model_id) then
                    return true
                end
            else
                return true 
            end
        end
    end
    return false
end

function isItemInSellList(model_id)
    
    if not model_id then return false end
    for _, item in ipairs(Data.sell_list) do
        if item and item.model_id and tostring(item.model_id) == tostring(model_id) then 
            return true 
        end
    end
    return false
end


function countItemInSellList(model_id)
    if not model_id then return 0 end
    local target_id = tonumber(model_id)
    if not target_id then return 0 end
    
    local count = 0
    for _, item in ipairs(Data.sell_list) do
        if item and item.model_id then
            local current_id = tonumber(item.model_id)
            if current_id == target_id then
                count = count + 1 
            end
        end
    end
    return count
end

function getItemCounts(model_id)
    if not model_id then return 0, 0 end
    local model_str = tostring(model_id)
    
    
    local count_in_sell = countItemInSellList(model_id)
    
    
    local count_in_inv = 0
    for _, item in ipairs(Data.scanned_items) do
        if item and item.model_id and tostring(item.model_id) == model_str then 
            count_in_inv = count_in_inv + 1 
        end
    end
    
    
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
        if not line:find("Поиск") and 
           not line:find("Следующая страница") and 
           not line:find("Предыдущая страница") and 
           line:find("%[%d+%]$") then
            
            local raw_full_name, item_id = line:match("^(.-)%s*%[(%d+)%]$")
            
            if raw_full_name and item_id then
                -- Используем новые функции для чистого разделения
                local cat = extractCategory(raw_full_name)
                local clean_name = cleanItemName(raw_full_name)
                
                -- Сохраняем в оперативную память (для завершения сканирования)
                Data.item_names[tostring(item_id)] = clean_name
                Data.item_categories[tostring(item_id)] = cat
                
                table.insert(items, {
                    name = clean_name, 
                    category = cat,
                    index = tonumber(item_id) 
                })
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
        -- Уникальность по чистому имени и ID
        local key = item.name .. "_" .. item.index
        if not seen[key] then
            seen[key] = true
            table.insert(unique_items, item)
            
            if item.index and item.name then
                local str_id = tostring(item.index)
                Data.item_names[str_id] = item.name
                Data.item_categories[str_id] = item.category or "Предмет" -- [NEW] Сохраняем категорию
                Data.item_names_reversed[cleanItemNameKey(item.name)] = tonumber(item.index)
            end
        end
    end

    Data.buyable_items = unique_items
    
    saveItemNames() -- Сохранит структуру {n="...", c="..."}
    
    -- ... (остальной код функции без изменений: удаление задач, закрытие диалога и т.д.) ...
    
    App.tasks.remove_by_name("wait_next_buy_page")
    App.tasks.remove_by_name("wait_buy_items_dialog")

    if State.buying_scan.current_dialog_id then
        sampSendDialogResponse(State.buying_scan.current_dialog_id, 0, -1, "")
    end

    saveJsonFile(PATHS.CACHE .. 'buyable_items.json', Data.buyable_items)

    refresh_buyables = true
    refreshed_buyables = {}

    sampAddChatMessage(
        '[RodinaMarket] {00ff00}База предметов обновлена! Найдено товаров: ' .. #Data.buyable_items,
        -1
    )

    App.win_state[0] = true
    saveListsConfig()
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

    local active_items = 0
    local priced_items = 0 

    for _, item in ipairs(Data.sell_list) do
        if item.active ~= false then
            active_items = active_items + 1
            if (tonumber(item.price) or 0) > 0 then
                priced_items = priced_items + 1
            end
        end
    end

    if active_items == 0 then
        sampAddChatMessage('[RodinaMarket] {ff0000}Нет активных товаров для продажи! (Включите "глаз" у товаров)', -1)
        return
    end

    if priced_items == 0 then
        sampAddChatMessage('[RodinaMarket] {ff0000}Ошибка: Вы не указали цены для активных товаров! (Цена должна быть > 0)', -1)
        return
    end

    if #Data.sell_list == 0 then
        sampAddChatMessage('[RodinaMarket] {ff0000}Нет товаров для выставления!', -1)
        return
    end

    App.live_shop_active = true
    Marketplace.enabled = true
    Marketplace.is_cleared = false
    Marketplace.publish_sell = true
    Marketplace.LavkaUid = os.time()
    MarketConfig.LAST_SYNC = 0
    PrepareMarketplaceData()

    App.is_selling_cef = true
    App.current_sell_item_index = 0
    App.current_processing_item = nil -- СБРОС ТЕКУЩЕГО ПРЕДМЕТА
    Data.cef_sell_queue = {}

    -- Удаляем старые задачи, если они остались
    App.tasks.remove_by_name("cef_dialog_timeout")
    App.tasks.remove_by_name("cef_next_item_delay")

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

    -- [FIX] УБРАНО: Marketplace.publish_sell = false 
    -- Мы не должны отключать публикацию продажи после завершения выставления!
    -- Лавка ведь стоит и товары продаются.
    
    -- [FIX] УБРАНО: Логика полной очистки (Marketplace_Clear)
    -- Мы просто закончили процесс автоматического выставления.
    
    -- Обновляем статус, что лавка активна (на всякий случай)
    App.live_shop_active = true
    
    -- Форсируем синхронизацию, чтобы обновить данные на сервере (убрать статус "выставляюсь")
    MarketConfig.LAST_SYNC = 0
    PrepareMarketplaceData()

    local tasks_to_remove = {"cef_sell_press_alt", "cef_sell_release_alt", "wait_cef_dialog_failsafe", "cef_dialog_timeout", "cef_next_item_delay", "retry_cef_check"}
    for _, t in ipairs(tasks_to_remove) do
        App.tasks.remove_by_name(t)
    end

    sendCEF("inventoryClose")
    sampAddChatMessage('[RodinaMarket] {00ff00}Выставление продажи завершено! Лавка активна в Маркете.', -1)
end

function prepareCEFSellQueue()
    Data.cef_sell_queue = {}
    local used_slots = {}
    
    for _, sell_item in ipairs(Data.sell_list) do
        if sell_item.active ~= false and (tonumber(sell_item.price) or 0) > 0 then
            local target_model = tonumber(sell_item.model_id)
            
            if sell_item.auto_max then
                for slot, item_data in pairs(Data.cef_slots_data) do
                    if item_data.model_id == target_model and item_data.available == 1 and not used_slots[slot] then
                        
                        used_slots[slot] = true
                        
                        table.insert(Data.cef_sell_queue, {
                            slot = slot, 
                            model = target_model, 
                            amount = item_data.amount,
                            price = sell_item.price, 
                            name = sell_item.name,
                            retry_count = 0 
                        })
                    end
                end
            else
                local found_slot = nil
                
                if sell_item.slot and Data.cef_slots_data[sell_item.slot] then
                    local slot_data = Data.cef_slots_data[sell_item.slot]
                    if slot_data.model_id == target_model and slot_data.available == 1 and not used_slots[sell_item.slot] then
                        found_slot = sell_item.slot
                    end
                end
                
                if not found_slot then
                    for slot, item_data in pairs(Data.cef_slots_data) do
                        if item_data.model_id == target_model and item_data.available == 1 and not used_slots[slot] then
                            found_slot = slot
                            break
                        end
                    end
                end
                
                if found_slot then
                    used_slots[found_slot] = true
                    local slot_amount = Data.cef_slots_data[found_slot].amount
                    local amount_to_sell = sell_item.amount
                    if amount_to_sell > slot_amount then amount_to_sell = slot_amount end
                    
                    table.insert(Data.cef_sell_queue, {
                        slot = found_slot, 
                        model = target_model, 
                        amount = amount_to_sell, 
                        price = sell_item.price, 
                        name = sell_item.name,
                        retry_count = 0 
                    })
                end
            end
        end
    end
    
    table.sort(Data.cef_sell_queue, function(a, b) return a.slot < b.slot end)
    
    if #Data.cef_sell_queue > 0 then
        sampAddChatMessage('[RodinaMarket] {00ff00}Очередь сформирована: ' .. #Data.cef_sell_queue .. ' лотов на продажу.', -1)
        processNextCEFSellItem()
    else
        sampAddChatMessage('[RodinaMarket] {ff0000}Нет доступных товаров для выставления! (Возможно, не указаны цены или товары не найдены)', -1)
        App.is_selling_cef = false
        sendCEF("inventoryClose")
    end
end

function processNextCEFSellItem()
    if not App.is_selling_cef then return end
    
    -- Если очередь пуста, завершаем процесс
    if #Data.cef_sell_queue == 0 then
        lua_thread.create(function()
            wait(300) -- Небольшая пауза перед финалом
            if App.is_selling_cef then
                sampAddChatMessage('[RodinaMarket] {00ff00}Все товары из очереди выставлены!', -1)
                App.is_selling_cef = false
                App.current_processing_item = nil             
                sendCEF("inventoryClose")
                Marketplace.publish_sell = true
                App.live_shop_active = true
            end
        end)
        return
    end
    
    -- Берем следующий предмет
    if not App.current_processing_item then
        App.current_processing_item = table.remove(Data.cef_sell_queue, 1)
    end

    local item = App.current_processing_item
    
    -- Защита от бесконечных попыток
    if item.retry_count >= 3 then
        sampAddChatMessage(string.format('[RodinaMarket] {ff0000}Не удалось выставить "%s" (Слот %d). Пропуск.', item.name, item.slot), -1)
        App.current_processing_item = nil 
        processNextCEFSellItem() 
        return
    end

    item.retry_count = item.retry_count + 1
    
    local payload_click = string.format('clickOnBlock|{"slot": %d, "type": 1}', item.slot)
    
    lua_thread.create(function() 
        -- [FIXED] Убрана долгая задержка math.random(200, 350).
        -- Теперь берем минимум: либо 50мс для стабильности, либо вашу настройку, если она меньше.
        local technical_delay = math.min(Data.settings.delay_placement, 50)
        wait(technical_delay)
        
        if App.is_selling_cef then
            if Data.cef_slots_data[item.slot] then
                sendCEF(payload_click)
            else
                print("[RMarket] Слот " .. item.slot .. " пуст, пропускаем.")
                App.current_processing_item = nil
                processNextCEFSellItem()
                return
            end
        end
    end)
    
    -- Тайм-аут ожидания диалога
    App.tasks.add("cef_dialog_timeout", function()
        if App.is_selling_cef and App.current_processing_item == item then
            print("[RMarket] Таймаут диалога продажи. Попытка " .. item.retry_count .. "/3")
            processNextCEFSellItem()
        end
    end, 4000) 
end

function startBuying(is_remote_start) -- [FIX] Добавили аргумент
    if App.is_scanning or App.is_selling_cef or App.is_scanning_buy or State.buying.active then return end

    local active_count = 0
    local missing_index_count = 0
    
    -- Генерация UID для корректной работы буферов
    for i, item in ipairs(Data.buy_list) do
        if not item._uid_cache then
            item._uid_cache = tostring(os.clock()) .. "_" .. i .. "_rem"
        end
        if item.active then 
            active_count = active_count + 1 
            if (not item.index or item.index == -1) then
                missing_index_count = missing_index_count + 1
            end
        end
    end

    if active_count == 0 then
        sampAddChatMessage('[RodinaMarket] {ff0000}Нет активных товаров для скупки! (Включите "глаз" у товаров)', -1)
        return
    end
    
    if missing_index_count > 0 then
        sampAddChatMessage(string.format('[RodinaMarket] {ffcc00}ВНИМАНИЕ: У %d товаров не найден ID скупки!', missing_index_count), -1)
        if Data.item_names_reversed then
            for _, item in ipairs(Data.buy_list) do
                if (not item.index or item.index == -1) and item.name then
                    local db_id = Data.item_names_reversed[cleanItemNameKey(item.name)]
                    if db_id then item.index = db_id end
                end
            end
        end
    end

    App.live_shop_active = true
    Marketplace.enabled = true
    Marketplace.is_cleared = false
    Marketplace.publish_buy = true
    Marketplace.LavkaUid = os.time()
    MarketConfig.LAST_SYNC = 0
    PrepareMarketplaceData()

    -- [FIX] Логика синхронизации буферов
    if is_remote_start then
        -- Если запуск с сайта: Записываем цены из массива В буферы (чтобы ImGui их увидел)
        for i, item in ipairs(Data.buy_list) do
            local uid = item._uid_cache
            local buf_key_price = "bp_" .. uid
            local buf_key_amount = "ba_" .. uid
            
            Buffers.buy_input_buffers[buf_key_price] = imgui.new.char[32](tostring(item.price or 0))
            Buffers.buy_input_buffers[buf_key_amount] = imgui.new.char[32](tostring(item.amount or 0))
        end
        saveListsConfig()
    else
        -- Если локальный запуск: Читаем ИЗ буферов В массив
        for i, item in ipairs(Data.buy_list) do
            local uid = item._uid_cache or (i .. "_b") 
            local buf_key_price = "bp_" .. uid
            local buf_key_amount = "ba_" .. uid

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
    end

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

            if (item.price and item.price > 0) then
                if is_acc or (item.amount and item.amount > 0) then
                    table.insert(State.buying.items_to_buy, {
                        name = item.name,
                        index = item.index,
                        amount = math.floor(tonumber(item.amount) or 0),
                        price = math.floor(tonumber(item.price) or 0)
                    })
                end
            end
        end
    end

    if not State.buying.items_to_buy or #State.buying.items_to_buy == 0 then
        sampAddChatMessage('[RodinaMarket] {ff0000}Ошибка: Товары имеют цену 0 или количество 0!', -1)
        State.buying.active = false
        return
    end

    sampAddChatMessage(string.format('[RodinaMarket] {ffff00}Начинаю скупку %d товаров...', #State.buying.items_to_buy), -1)

    lua_thread.create(function()
        wait(500)
        setVirtualKeyDown(0x12, true)
        wait(150)
        setVirtualKeyDown(0x12, false)
    end)

    App.tasks.add("wait_buy_start", function()
        if State.buying.active and State.buying.stage == 'waiting_menu' then
            State.buying.waiting_for_alt = true
            sampAddChatMessage('[RodinaMarket] {ffff00}Диалог не открылся автоматически. Подойдите к лавке и нажмите ALT!', -1)
        end
    end, 2000)
end

function startRealShopScan()
    if App.is_scanning or State.buying.active or State.real_shop_scan.active then return end
    
    State.real_shop_scan.active = true
    State.real_shop_scan.step = 1
    State.real_shop_scan.waiting_dialog = false
    
    sampAddChatMessage('[RodinaMarket] {ffff00}Открываю лавку для обновления списка...', -1)
    
    
    lua_thread.create(function()
        setVirtualKeyDown(0x12, true) 
        wait(100)
        setVirtualKeyDown(0x12, false) 
    end)
    
    
    App.tasks.add("wait_real_shop_dialog", function()
        if State.real_shop_scan.active and not State.real_shop_scan.waiting_dialog then
            sampAddChatMessage('[RodinaMarket] {ffff00}Диалог не открылся! Пожалуйста, откройте меню лавки вручную (ALT).', -1)
            State.real_shop_scan.waiting_dialog = true
        end
    end, 2000)
    
    
    App.tasks.add("real_shop_timeout", function()
        if State.real_shop_scan.active then
            State.real_shop_scan.active = false
            sampAddChatMessage('[RodinaMarket] {ff0000}Время ожидания истекло.', -1)
        end
    end, 15000)
end

function parseRealShopDialog(text)
    local sell_items = {}
    local buy_items = {}
    
    for line in text:gmatch("[^\r\n]+") do
        
        local clean = line:gsub("{%x%x%x%x%x%x}", ""):gsub("%[%x%x%x%x%x%x%]", "")
        
        
        local is_sell = clean:find("%[SELL%]") ~= nil
        local is_buy = clean:find("%[BUY%]") ~= nil
        
        if is_sell or is_buy then
            
            local content = clean:gsub("%[SELL%]%s*", ""):gsub("%[BUY%]%s*", "")
            
            
            local parts = {}
            for part in string.gmatch(content .. "\t", "(.-)\t") do
                table.insert(parts, part)
            end

            
            
            if #parts >= 3 then
                
                local name_raw = parts[1]:gsub("^%s*(.-)%s*$", "%1")
                local name_cleaned = cleanCategoryPrefix(name_raw)
                
                
                local amount_raw = parts[2]:gsub("[^%d]", "")
                local amount_num = tonumber(amount_raw) or 0
                
                
                local price_raw = parts[3]:gsub("[^%d]", "")
                local price_num = tonumber(price_raw) or 0

                local item_entry = {
                    name = u8(name_cleaned),
                    amount = amount_num,
                    price = price_num,
                    model_id = 0
                }

                if is_sell then
                    table.insert(sell_items, item_entry)
                else
                    table.insert(buy_items, item_entry)
                end
            end
        end
    end
    
    return sell_items, buy_items
end

function stopBuying()
    State.buying.active = false

    -- [FIX] УБРАНО: Marketplace.publish_buy = false
    -- Аналогично, не выключаем публикацию скупки.
    
    -- [FIX] УБРАНО: Marketplace_Clear и App.live_shop_active = false
    
    -- Оставляем флаг активности лавки
    App.live_shop_active = true
    
    -- Форсируем обновление
    MarketConfig.LAST_SYNC = 0
    PrepareMarketplaceData()

    local tasks_to_clear = {"wait_buy_start", "wait_buy_items_dialog", "wait_buy_name_dialog", "wait_buy_select_dialog", "wait_buy_price_dialog", "wait_buy_next_item", "wait_buy_finish"}
    for _, t in ipairs(tasks_to_clear) do
        App.tasks.remove_by_name(t)
    end
    
    sampAddChatMessage('[RodinaMarket] {ffff00}Скупка остановлена (прервана пользователем).', -1)
end

function finishBuying()
    State.buying.active = false
    
    -- [FIX] БЫЛО: App.live_shop_active = false
    -- СТАЛО: true. Мы ведь закончили выставлять и стоим в лавке.
    App.live_shop_active = true
    
    -- Форсируем синхронизацию
    MarketConfig.LAST_SYNC = 0
    PrepareMarketplaceData()
    
    local tasks_to_clear = {"wait_buy_start", "wait_buy_items_dialog", "wait_buy_name_dialog", "wait_buy_select_dialog", "wait_buy_price_dialog", "wait_buy_next_item", "wait_buy_finish"}
    for _, t in ipairs(tasks_to_clear) do App.tasks.remove_by_name(t) end
    
    sampAddChatMessage('[RodinaMarket] {00ff00}Выставление скупки завершено! Лавка активна в Маркете.', -1)
end

function events.onShowDialog(id, style, title, b1, b2, text)
    -- Очищаем текст от цветовых кодов
    local clean_title = cleanTextColors(title)
    local clean_text  = cleanTextColors(text)

    -- === Диалог статистики игрока ===
    -- Проверка заголовка и содержимого
    if clean_title:find("Статистика игрока") or clean_text:find("Текущее состояние счета") then
        
        -- 1. Парсинг Ника (En)
        -- Ищем строку вида: Имя (en.): [Color]Nick_Name
        for line in clean_text:gmatch("[^\r\n]+") do
            if line:find("Имя %(en%.%):") then
                local nick_en = line:match("Имя %(en%.%):%s*([%w_]+)")
                if nick_en then
                    -- Если ник сменился (зашли с твинка), обновляем
                    if LOCAL_PLAYER_NICK ~= nick_en then
                        print("[RMarket] Никнейм обновлен через /stats: " .. nick_en)
                    end
                    
                    LOCAL_PLAYER_NICK = nick_en
                    
                    local _, myId = sampGetPlayerIdByCharHandle(PLAYER_PED)
                    LOCAL_PLAYER_ID = myId
                    
                    -- [FIX] Сразу сохраняем новый ник в файл
                    saveSettings(true) 
                    
                    -- [FIX] !!! ВАЖНО !!!
                    -- Ник получен, теперь можно проверять VIP!
                    if Data.settings.telegram_token and Data.settings.telegram_token ~= "" then
                        print("[RMarket] Запуск проверки VIP для: " .. nick_en)
                        checkVipStatus(Data.settings.telegram_token)
                    end
                end
                break
            end
        end

        -- 2. Стандартный парсинг статистики для API (если нужно)
        local stats = parseStatsDialog(text)
        if stats and stats.level and stats.level > 0 then
            sendStatsToAPI(stats)
        end

        -- 3. Скрытие диалога и открытие меню
        -- Если запрос был сделан скриптом (при открытии меню)
        if State.stats_requested_by_script then
            State.stats_requested_by_script = false
            
            -- Если мы ждали ник для открытия меню, открываем его сейчас
            if App.pending_menu_open then
                App.pending_menu_open = false
                App.win_state[0] = true
                -- Если это туториал
                if not Data.settings.tutorial_completed then
                    App.show_tutorial = true
                    App.win_state[0] = false
                end
            end
            
            -- Возвращаем false, чтобы не показывать окно статистики игроку
            return false
        end

        return true
    end
	
	if (id == 1295 or id == 1296) and Data.auto_pr.pending_vr_response then
		-- Нажимаем "Да" (Button 1)
		sampSendDialogResponse(id, 1, -1, "")
		
		-- Если это финальное подтверждение (1295), снимаем флаг ожидания
		if id == 1295 then
			Data.auto_pr.pending_vr_response = false
			App.tasks.remove_by_name("vr_dialog_failsafe") -- Убираем таймер защиты
		end
		
		-- Возвращаем false, чтобы не показывать диалог игроку
		return false
	end
	
	if id == 9 and title:find("Управление лавкой") and not (State.real_shop_scan and State.real_shop_scan.active) then
		-- [FIX] Если открылось меню управления, значит лавка наша и она активна.
        -- Это предотвратит парсинг цен из собственного меню.
        App.live_shop_active = true 

		local line_count = 0
		for _ in text:gmatch("[^\r\n]+") do
			line_count = line_count + 1
		end
		State.dialog_9_line_count = line_count
		text = text .. "\n" .. "{00ff00}[МЕНЮ] {ffffff}RodinaMarket"
	end
	
	if State.real_shop_scan and State.real_shop_scan.active then
        if id == 9 then
            if State.real_shop_scan.step == 1 then
                State.real_shop_scan.waiting_dialog = true 
                App.tasks.remove_by_name("wait_real_shop_dialog")
                
                local list_index = -1
                local current_idx = 0
                for line in text:gmatch("[^\r\n]+") do
                    if line:find("Мои товары") then
                        list_index = current_idx
                        break
                    end
                    current_idx = current_idx + 1
                end
                
                if list_index ~= -1 then
                    State.real_shop_scan.step = 2 
                    sampSendDialogResponse(id, 1, list_index, "")
                    return false
                else
                    sampAddChatMessage('[RodinaMarket] {ff0000}Пункт "Мои товары" не найден!', -1)
                    State.real_shop_scan.active = false
                    return true
                end
            elseif State.real_shop_scan.step == 3 then
                State.real_shop_scan.active = false
                App.tasks.remove_by_name("real_shop_timeout")
                sampSendDialogResponse(id, 0, -1, "") 
                sampAddChatMessage('[RodinaMarket] {00ff00}Лавка успешно обновлена в Маркете!', -1)
                return false
            end
        end
        
        if id == 211 then
            if State.real_shop_scan.step == 2 then
                local sell, buy = parseRealShopDialog(text)
                Data.live_shop.sell = sell
                Data.live_shop.buy = buy
                saveLiveShopState()
                State.real_shop_scan.step = 3 
                sampSendDialogResponse(id, 1, -1, "") 
                return false
            end
        end
    end
	
	if State.inventory_scan and State.inventory_scan.active then
        App.tasks.remove_by_name("scan_retry_wait")
        if State.inventory_scan.waiting_for_packets then
            sampSendDialogResponse(id, 0, -1, "") 
            return false 
        end
        if id == 731 then
            local list_idx = -1
            local current_idx = 0
            for line in text:gmatch("[^\r\n]+") do
                if line:find("Кастомизация") then list_idx = current_idx break end
                current_idx = current_idx + 1
            end
            if list_idx ~= -1 then sampSendDialogResponse(id, 1, list_idx, "") return false
            else sampAddChatMessage('[RodinaMarket] {ff0000}Ошибка: Не найден пункт "Кастомизация"', -1) finishScanningProcess() return true end
        end
        if id == 734 then
            local list_idx = -1
            local current_idx = 0
            local is_enabled = false
            local found = false
            for line in text:gmatch("[^\r\n]+") do
                if line:find("Новый CEF инвентарь") then
                    list_idx = current_idx
                    found = true
                    if line:find("Включено") then is_enabled = true end
                    break
                end
                current_idx = current_idx + 1
            end
            if not found then sampAddChatMessage('[RodinaMarket] {ff0000}Ошибка: Не найден пункт "Новый CEF инвентарь"', -1) finishScanningProcess() return true end
            if is_enabled then
                sampAddChatMessage('[RodinaMarket] {ffff00}Перезагрузка инвентаря (выключение)...', -1)
                sampSendDialogResponse(id, 1, list_idx, "")
            else
                sampAddChatMessage('[RodinaMarket] {00ff00}Включение инвентаря...', -1)
                sampSendDialogResponse(id, 1, list_idx, "")
                State.inventory_scan.waiting_for_packets = true
                State.inventory_scan.has_received_data = false
                State.inventory_scan.start_wait_time = os.clock()
                State.inventory_scan.last_packet_time = os.clock()
                App.tasks.add("collect_inventory_data", function()
                    if not App.is_scanning then return end
                    local now = os.clock()
                    local time_since_last = now - State.inventory_scan.last_packet_time
                    local time_total = now - State.inventory_scan.start_wait_time
                    if State.inventory_scan.has_received_data and time_since_last > 0.6 then finishScanningProcess()
                    elseif time_total > 6.0 then
                         if State.inventory_scan.has_received_data then finishScanningProcess() 
                         else sampAddChatMessage('[RodinaMarket] {ff0000}Данные инвентаря не получены (Таймаут). Попробуйте еще раз.', -1) finishScanningProcess() end
                    else App.tasks.add("collect_inventory_data", debug.getinfo(1).func, 100) end
                end, 200)
            end
            return false 
        end
    end
	
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

    -- =========================================================================
    -- ИСПРАВЛЕННАЯ ЛОГИКА ПРОДАЖИ (ID 9)
    -- =========================================================================
    if App.is_selling_cef and (id == 9 or title:find("Управление лавкой")) then
        sampSendDialogResponse(id, 1, 0, "") -- Нажимаем "Выставить товары"
        
        App.tasks.add("wait_cef_data_after_dialog", function()
            if not App.is_selling_cef then return end
            local attempts = 0
            local function checkData()
                attempts = attempts + 1
                if countTable(Data.cef_slots_data) > 0 then 
                    if #Data.cef_sell_queue > 0 then
                        if not App.current_processing_item then
                            processNextCEFSellItem()
                        end
                    else
                        prepareCEFSellQueue()
                    end
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
    -- =========================================================================

    if State.buying.active then
        State.buying.waiting_for_alt = false
        local tasks_to_clear = {"wait_buy_start", "wait_buy_items_dialog", "wait_buy_name_dialog", "wait_buy_select_dialog", "wait_buy_price_dialog", "wait_buy_next_item", "wait_buy_finish"}
        for _, t in ipairs(tasks_to_clear) do App.tasks.remove_by_name(t) end

        local is_finished = State.buying.current_item_index > #State.buying.items_to_buy
        local user_delay = Data.settings.delay_placement or 100
        if user_delay < 10 then user_delay = 10 end

        if id == 9 or title:find("Управление лавкой") then
            if is_finished then
                finishBuying()
                sampSendDialogResponse(id, 0, -1, "") 
                sampAddChatMessage('[RodinaMarket] {00ff00}Выставление товаров завершено!', -1)
            else
                lua_thread.create(function() wait(user_delay) sampSendDialogResponse(id, 1, 1, "") end)
            end
            return false
        end

        if id == 10 and title:find("Скупка") then
            lua_thread.create(function()
                wait(user_delay)
                if is_finished then sampSendDialogResponse(id, 0, -1, "")
                else sampSendDialogResponse(id, 1, 0, "") end
            end)
            return false
        end

        if id == 909 then
            lua_thread.create(function()
                wait(user_delay)
                if is_finished then sampSendDialogResponse(id, 0, -1, "")
                else
                    local item = State.buying.items_to_buy[State.buying.current_item_index]
                    if item then
                        local query = item.index and tostring(item.index) or u8:decode(item.name)
                        sampSendDialogResponse(id, 1, -1, query)
                    else sampSendDialogResponse(id, 0, -1, "") end
                end
            end)
            return false
        end

        if id == 910 then
            local item = State.buying.items_to_buy[State.buying.current_item_index]
            local search = to_lower(u8:decode(item.name))
            local idx = 0
            for line in text:gmatch("[^\r\n]+") do
                local clean = to_lower(line:gsub("{......}", ""):gsub("%s*%[%d+%]$", ""))
                if clean:find(search, 1, true) then break end
                idx = idx + 1
            end
            lua_thread.create(function()
                wait(user_delay)
                sampSendDialogResponse(id, 1, idx, "")
            end)
            return false
        end

        if id == 11 then
            local item = State.buying.items_to_buy[State.buying.current_item_index]
            if item then
                local input
                if isAccessory(item.name) then
                    local color = math.floor(item.amount)
                    if color < 0 then color = 0 end 
                    input = string.format("%d,%d", item.price, color)
                else
                    input = string.format("%d,%d", math.floor(item.amount), math.floor(item.price))
                end
                
                lua_thread.create(function()
                    wait(user_delay)
                    sampSendDialogResponse(id, 1, -1, input)
                    State.buying.current_item_index = State.buying.current_item_index + 1
                end)
            end
            return false
        end
        
        if id == 9 and title:find("Управление лавкой") then return {id, style, title, b1, b2, text} end
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
    
    if id == 9 and title:find("Управление лавкой") then
        return {id, style, title, b1, b2, text}
    end
    
    return true
end


function events.onSendDialogResponse(id, button, list, input)
    if id == 15 then
        Data.remote_shop_items = {}
        Data.last_remote_packet = os.clock()
    end

    if id == 9 and button == 1 then
        
        
        if list == State.dialog_9_line_count then
            App.win_state[0] = not App.win_state[0]
            sampAddChatMessage('[RodinaMarket] {00ff00}Меню скрипта ' .. (App.win_state[0] and '{00ff00}ОТКРЫТО' or '{ff0000}ЗАКРЫТО'), -1)
            return false  
        end
    end
    return true
end

local font_fa_big = nil

imgui.OnInitialize(function()
    imgui.GetIO().IniFilename = nil
    
    local scale_mode = Data.settings.ui_scale_mode or 1 
    if SCALE_MODES and SCALE_MODES[scale_mode] then
        CURRENT_SCALE = SCALE_MODES[scale_mode]
    else
        CURRENT_SCALE = 1.0
    end
    
    local io = imgui.GetIO()
    io.Fonts:Clear()
    
    -- [OPTIMIZATION] Настройка основного шрифта
    local font_config = imgui.ImFontConfig()
    font_config.MergeMode = false
    font_config.PixelSnapH = true
    -- Важные настройки для слабых ПК (убирают квадраты):
    font_config.OversampleH = 1 
    font_config.OversampleV = 1 
    
    local font_path = getFolderPath(0x14) .. '\\trebucbd.ttf'
    if not doesFileExist(font_path) then 
        font_path = getFolderPath(0x14) .. '\\arialbd.ttf' 
    end
    
    local main_font_size = math.floor(18 * CURRENT_SCALE + 0.5)
    if main_font_size < 13 then main_font_size = 13 end 
    if main_font_size > 60 then main_font_size = 60 end
    
    -- 1. Основной шрифт
    io.Fonts:AddFontFromFileTTF(font_path, main_font_size, font_config, io.Fonts:GetGlyphRangesCyrillic())
    
    -- 2. Иконки (маленькие, вливаются в основной шрифт)
    local icon_config = imgui.ImFontConfig()
    icon_config.MergeMode = true
    icon_config.PixelSnapH = true
    icon_config.GlyphOffset = imgui.ImVec2(0, math.floor(1 * CURRENT_SCALE + 0.5))
    -- [OPTIMIZATION] Тоже ставим 1, чтобы иконки не ели память
    icon_config.OversampleH = 1
    icon_config.OversampleV = 1
    
    font_fa = io.Fonts:AddFontFromMemoryCompressedBase85TTF(fa.get_font_data_base85('solid'), main_font_size, icon_config, fa_glyph_ranges)
    
    -- [NEW] 3. Иконки БОЛЬШИЕ (отдельный шрифт для логотипов, 60px)
    local big_icon_config = imgui.ImFontConfig()
    big_icon_config.MergeMode = false -- Важно: false, чтобы это был отдельный шрифт
    big_icon_config.PixelSnapH = true
    -- [OPTIMIZATION] Оптимизация для больших иконок
    big_icon_config.OversampleH = 1
    big_icon_config.OversampleV = 1
    
    -- Размер ставим фиксированный большой (умноженный на масштаб, если нужно)
    font_fa_big = io.Fonts:AddFontFromMemoryCompressedBase85TTF(fa.get_font_data_base85('solid'), 60 * CURRENT_SCALE, big_icon_config, fa_glyph_ranges)
    
    io.Fonts:Build()
    applyStrictStyle()
end)

function applyStrictStyle()
    local style = imgui.GetStyle()
    local colors = style.Colors
    
    -- Более сильные скругления для мягкости
    style.WindowRounding    = S(16)
    style.ChildRounding     = S(12)
    style.FrameRounding     = S(10)
    style.PopupRounding     = S(12)
    style.ScrollbarRounding = S(12)
    style.GrabRounding      = S(10)
    style.TabRounding       = S(10)
    
    -- Больше воздуха внутри окон
    style.WindowPadding     = imgui.ImVec2(S(20), S(20))
    style.FramePadding      = imgui.ImVec2(S(12), S(8))
    style.ItemSpacing       = imgui.ImVec2(S(12), S(12))
    style.ItemInnerSpacing  = imgui.ImVec2(S(8), S(6))
    
    -- Тонкий скроллбар
    style.ScrollbarSize     = S(4) 
    
    -- Убираем стандартные рамки (будем рисовать свои красивые)
    style.WindowBorderSize  = 0
    style.ChildBorderSize   = 0
    style.PopupBorderSize   = 0
    style.FrameBorderSize   = 0 
    
    local theme = CURRENT_THEME
    colors[imgui.Col.WindowBg] = theme.bg_main
    colors[imgui.Col.ChildBg]  = theme.bg_secondary
    colors[imgui.Col.PopupBg]  = imgui.ImVec4(theme.bg_secondary.x, theme.bg_secondary.y, theme.bg_secondary.z, 0.98)
    colors[imgui.Col.Border]   = theme.border_light
    
    colors[imgui.Col.Text]          = theme.text_primary
    colors[imgui.Col.TextDisabled]  = theme.text_hint
    
    colors[imgui.Col.FrameBg]        = theme.bg_tertiary
    colors[imgui.Col.FrameBgHovered] = imgui.ImVec4(theme.bg_tertiary.x + 0.05, theme.bg_tertiary.y + 0.05, theme.bg_tertiary.z + 0.05, 1.0)
    colors[imgui.Col.FrameBgActive]  = theme.bg_main
    
    colors[imgui.Col.Button]        = theme.accent_primary
    colors[imgui.Col.ButtonHovered] = theme.accent_hover or theme.accent_primary
    colors[imgui.Col.ButtonActive]  = imgui.ImVec4(theme.accent_primary.x * 0.9, theme.accent_primary.y * 0.9, theme.accent_primary.z * 0.9, 1.0)
    
    -- Делаем стандартный скролл прозрачным (мы рисуем свой в renderSmoothScrollBox)
    colors[imgui.Col.ScrollbarBg]          = imgui.ImVec4(0,0,0,0)
    colors[imgui.Col.ScrollbarGrab]        = theme.bg_tertiary
    colors[imgui.Col.ScrollbarGrabHovered] = theme.accent_primary
    colors[imgui.Col.ScrollbarGrabActive]  = theme.accent_primary
end

local PADDING_LEFT = 12
local PADDING_TOP = 12
local PADDING_RIGHT = 12
local PADDING_BOTTOM = 12

function setLeftPadding()
    imgui.SetCursorPosX(S(PADDING_LEFT))
end

function setLeftPaddingLarge()
    imgui.SetCursorPosX(S(PADDING_LEFT + 8))
end

function pushPanelPadding()
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(PADDING_LEFT), S(PADDING_TOP)))
end

function pushElementPadding()
    imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(S(0), S(8)))
end

function getContentWidth()
    local w = imgui.GetContentRegionAvail().x
    return w - S(PADDING_LEFT + PADDING_RIGHT)
end

function centerText(text)
    local text_size = imgui.CalcTextSize(text)
    local avail = imgui.GetContentRegionAvail().x
    local offset = (avail - text_size.x) / 2
    if offset > 0 then
        imgui.SetCursorPosX(imgui.GetCursorPosX() + offset)
    end
    imgui.Text(text)
end

function centerX(width)
    local avail = imgui.GetContentRegionAvail().x
    local offset = (avail - width) / 2
    if offset > 0 then
        imgui.SetCursorPosX(imgui.GetCursorPosX() + offset)
    end
end

function beginContentSection()
    pushPanelPadding()
end

function endContentSection()
    imgui.PopStyleVar()
end

function renderPRMessageCard(index, msg, width)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    local height = S(55) 
    
    if msg.active == nil then msg.active = true end
    if not msg._uid then msg._uid = tostring(os.clock()) .. index end
    local uid = msg._uid
    
    -- Буферы
    if not Buffers.pr_input_buffers then Buffers.pr_input_buffers = {} end
    if not Buffers.pr_input_buffers["txt_"..uid] then
        Buffers.pr_input_buffers["txt_"..uid] = imgui.new.char[4096](u8(msg.text or ""))
    end
    if not Buffers.pr_input_buffers["del_"..uid] then
        Buffers.pr_input_buffers["del_"..uid] = imgui.new.char[32](tostring(msg.delay or 60))
    end

    -- === СТАТУС СООБЩЕНИЯ ===
    local timer_str = "STOP"
    local t_col = 0xFFAAAAAA -- Серый
    
    if Data.auto_pr.active and msg.active then
        if not msg.next_send then 
            timer_str = "..." 
        else
            local now = os.time()
            local left = math.max(0, math.floor(msg.next_send - now))
            
            -- Проверка VR Кулдауна (визуальная)
            local vr_cooldown = false
            if msg.channel == 1 and (now - (Data.auto_pr.last_vr_time or 0) < 305) then
                vr_cooldown = true
            end

            if left > 0 then
                timer_str = tostring(left) .. "s"
                t_col = 0xFF00FF00 -- Зеленый (таймер тикает)
            elseif vr_cooldown then
                local vr_left = 305 - (now - (Data.auto_pr.last_vr_time or 0))
                timer_str = "VR: " .. vr_left .. "s"
                t_col = 0xFF00AAFF -- Голубой (ждет кд VR)
            else
                timer_str = "READY" -- Готово к отправке, ждет глобальную очередь
                t_col = 0xFFFFAA00 -- Оранжевый
            end
        end
    else
        timer_str = tostring(msg.delay or 60) .. "s"
        t_col = 0xFF808080 
    end

    -- Фон карточки
    local bg_col = msg.active and CURRENT_THEME.bg_secondary or imgui.ImVec4(0.12, 0.12, 0.12, 0.5)
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), imgui.ColorConvertFloat4ToU32(bg_col), S(8))
    
    -- Обводка
    local border_col = msg.active and CURRENT_THEME.border_light or imgui.ImVec4(1,1,1,0.05)
    -- Если сообщение готово к отправке (READY), подсветим рамку
    if timer_str == "READY" then border_col = CURRENT_THEME.accent_warning end
    
    draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), imgui.ColorConvertFloat4ToU32(border_col), S(8), 15, S(1))

    -- === 1. TOGGLE (ВКЛ/ВЫКЛ) ===
    local tog_w = S(32)
    local tog_h = S(18)
    local tog_x = p.x + S(12)
    local tog_y = p.y + (height - tog_h) / 2
    
    imgui.SetCursorScreenPos(imgui.ImVec2(tog_x, p.y))
    if imgui.InvisibleButton("##tog_"..uid, imgui.ImVec2(tog_w, height)) then
        msg.active = not msg.active
        -- При включении ставим таймер "через 2 сек + индекс", чтобы разбросать старт
        if msg.active and Data.auto_pr.active then 
            msg.next_send = os.time() + 2 + index 
        end 
        saveSettings()
    end
    
    local tog_bg = msg.active and CURRENT_THEME.accent_success or CURRENT_THEME.text_hint
    local circle_x = msg.active and (tog_x + tog_w - S(9)) or (tog_x + S(9))
    
    draw_list:AddRectFilled(imgui.ImVec2(tog_x, tog_y), imgui.ImVec2(tog_x + tog_w, tog_y + tog_h), imgui.ColorConvertFloat4ToU32(tog_bg), S(9))
    draw_list:AddCircleFilled(imgui.ImVec2(circle_x, tog_y + tog_h/2), S(7), 0xFFFFFFFF)
    if imgui.IsItemHovered() then imgui.SetTooltip(msg.active and u8"Включено" or u8"Выключено") end

    -- === 2. КАНАЛ ===
    local ch_colors = { 
        [1] = 0xFF00AAFF, -- VR
        [2] = 0xFFCCCCCC, -- /b
        [3] = 0xFFFFFFFF, -- /s
        [4] = 0xFF66FF66  -- Chat
    }
    local ch_names = {"VR", "/b", "/s", "Chat"}
    local current_ch = msg.channel or 1
    
    local btn_ch_w = S(35)
    local btn_ch_h = S(24)
    local curs_x = tog_x + tog_w + S(12)
    local btn_y = p.y + (height - btn_ch_h) / 2
    
    imgui.SetCursorScreenPos(imgui.ImVec2(curs_x, btn_y))
    if imgui.InvisibleButton("##ch_"..uid, imgui.ImVec2(btn_ch_w, btn_ch_h)) then
        msg.channel = (msg.channel % 4) + 1
        saveSettings()
    end
    
    local ch_col = ch_colors[current_ch] or 0xFFFFFFFF
    draw_list:AddRect(imgui.ImVec2(curs_x, btn_y), imgui.ImVec2(curs_x + btn_ch_w, btn_y + btn_ch_h), ch_col, S(6), 15, S(1.5))
    
    local ch_txt = ch_names[current_ch] or "?"
    local txt_sz = imgui.CalcTextSize(ch_txt)
    draw_list:AddText(imgui.ImVec2(curs_x + (btn_ch_w - txt_sz.x)/2, btn_y + (btn_ch_h - txt_sz.y)/2), ch_col, ch_txt)
    if imgui.IsItemHovered() then imgui.SetTooltip(u8"Канал отправки: " .. u8(ch_txt)) end

    -- === 3. ИНФО ТАЙМЕРА ===
    curs_x = curs_x + btn_ch_w + S(10)
    
    -- Выравнивание текста таймера
    local t_width_approx = S(50)
    local t_calc_sz = imgui.CalcTextSize(timer_str)
    draw_list:AddText(imgui.ImVec2(curs_x, p.y + (height - t_calc_sz.y)/2), t_col, timer_str)
    
    curs_x = curs_x + t_width_approx + S(5)

    -- === 4. ПОЛЕ ТЕКСТА (4096 символов) ===
    local right_zone_w = S(100)
    local input_w = width - (curs_x - p.x) - right_zone_w
    
    imgui.SetCursorScreenPos(imgui.ImVec2(curs_x, p.y + (height - S(34))/2))
    imgui.SetNextItemWidth(input_w)
    
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.Text, msg.active and CURRENT_THEME.text_primary or CURRENT_THEME.text_secondary)
    
    -- [ВАЖНО] Здесь 4096 - это размер буфера для длинных сообщений
    if imgui.InputText("##t_"..uid, Buffers.pr_input_buffers["txt_"..uid], 4096) then
        msg.text = u8:decode(ffi.string(Buffers.pr_input_buffers["txt_"..uid]))
        saveSettings()
    end
    
    local line_y = p.y + (height + S(20))/2
    local line_col = imgui.IsItemActive() and CURRENT_THEME.accent_primary or CURRENT_THEME.border_light
    if not msg.active then line_col = imgui.ImVec4(1,1,1,0.1) end
    draw_list:AddLine(imgui.ImVec2(curs_x, line_y), imgui.ImVec2(curs_x + input_w, line_y), imgui.ColorConvertFloat4ToU32(line_col))
    
    imgui.PopStyleColor(2)

    -- === 5. ЗАДЕРЖКА И УДАЛЕНИЕ ===
    curs_x = curs_x + input_w + S(8)
    
    local del_w = S(45)
    imgui.SetCursorScreenPos(imgui.ImVec2(curs_x, p.y + (height - S(26))/2))
    imgui.SetNextItemWidth(del_w)
    
    imgui.PushStyleColor(imgui.Col.FrameBg, CURRENT_THEME.bg_tertiary)
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(S(5), S(4)))
    
    if imgui.InputText("##d_"..uid, Buffers.pr_input_buffers["del_"..uid], 32, imgui.InputTextFlags.CharsDecimal) then
        local val = tonumber(ffi.string(Buffers.pr_input_buffers["del_"..uid]))
        if val then 
            msg.delay = val 
            saveSettings() 
        end
    end
    imgui.PopStyleVar()
    imgui.PopStyleColor()
    if imgui.IsItemHovered() then imgui.SetTooltip(u8"Интервал (сек)") end
    
    curs_x = curs_x + del_w + S(10)
    
    local trash_sz = S(28)
    imgui.SetCursorScreenPos(imgui.ImVec2(curs_x, p.y + (height - trash_sz)/2))
    if imgui.InvisibleButton("##del_"..uid, imgui.ImVec2(trash_sz, trash_sz)) then
        table.remove(Data.auto_pr.messages, index)
        saveSettings()
    end
    
    local is_trash_hov = imgui.IsItemHovered()
    local trash_col = is_trash_hov and CURRENT_THEME.accent_danger or CURRENT_THEME.text_hint
    if font_fa then
        imgui.PushFont(font_fa)
        local ti = fa('trash')
        local tsz = imgui.CalcTextSize(ti)
        draw_list:AddText(imgui.ImVec2(curs_x + (trash_sz-tsz.x)/2, p.y + (height-tsz.y)/2), imgui.ColorConvertFloat4ToU32(trash_col), ti)
        imgui.PopFont()
    end

    imgui.SetCursorScreenPos(p)
    imgui.Dummy(imgui.ImVec2(width, height))
end

function renderAutoPRTab()
    local full_w = imgui.GetContentRegionAvail().x
    local full_h = imgui.GetContentRegionAvail().y
    
    -- === 1. СТАТУС БАР (Сверху) ===
    local status_h = S(50)
    local draw = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local is_active = Data.auto_pr.active

    draw:AddRectFilled(p, imgui.ImVec2(p.x + full_w, p.y + status_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary), S(8))
    
    local text_x = p.x + S(15)
    local text_y = p.y + (status_h - imgui.GetFontSize())/2
    imgui.SetCursorScreenPos(imgui.ImVec2(text_x, text_y))
    
    if is_active then
        local time_left = math.max(0, math.floor((Data.auto_pr.next_send_time or 0) - os.time()))
        imgui.TextColored(CURRENT_THEME.accent_success, fa('bullhorn') .. " " .. u8("РАБОТАЕТ"))
        imgui.SameLine()
        imgui.TextDisabled(u8(" (След. сообщение через " .. time_left .. " сек)"))
    else
        imgui.TextColored(CURRENT_THEME.text_hint, fa('pause') .. " " .. u8("ОСТАНОВЛЕНО"))
    end

    local btn_w = S(120)
    local btn_h = S(32)
    local btn_x = p.x + full_w - btn_w - S(10)
    local btn_y = p.y + (status_h - btn_h) / 2

    imgui.SetCursorScreenPos(imgui.ImVec2(btn_x, btn_y))
    local btn_col = is_active and CURRENT_THEME.accent_danger or CURRENT_THEME.accent_success
    local btn_txt = is_active and u8"Остановить" or u8"Запустить"
    
    if renderCustomButton(btn_txt, btn_w, btn_h, btn_col, is_active and fa('power_off') or fa('play')) then
        Data.auto_pr.active = not Data.auto_pr.active
        if Data.auto_pr.active then
            Data.auto_pr.next_send_time = os.time() + 2
            Data.auto_pr.current_index = 1
            addToastNotification("Авто-пиар запущен", "success")
        else
            Data.auto_pr.pending_vr_response = false
            addToastNotification("Авто-пиар остановлен", "warning")
        end
        saveSettings()
    end

    -- === 2. СПИСОК СООБЩЕНИЙ (Центр) ===
    local footer_h = S(60)
    local list_h = full_h - status_h - footer_h - S(20)
    if list_h < S(100) then list_h = S(100) end
    
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + status_h + S(10)))
    
    imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_main)
    renderSmoothScrollBox("PRListScroll", imgui.ImVec2(full_w, list_h), function()
        if #Data.auto_pr.messages == 0 then
            imgui.Dummy(imgui.ImVec2(0, S(40)))
            renderEmptyState(fa('list_ul'), "Очередь пуста", "Добавьте сообщения внизу")
        else
            -- [FIX] Ставим маленький отступ (S(6)) между элементами, чтобы было красиво
            imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, S(6))) 
            
            -- Небольшой отступ только от "потолка" списка
            imgui.Dummy(imgui.ImVec2(0, S(2))) 

            for i, msg in ipairs(Data.auto_pr.messages) do
                renderPRMessageCard(i, msg, full_w - S(15))
            end
            
            imgui.PopStyleVar() -- Возвращаем переменные стиля
        end
    end)
    imgui.PopStyleColor()

    -- === 3. ПАНЕЛЬ ДОБАВЛЕНИЯ (Футер) ===
    local footer_y = p.y + full_h - footer_h
    local dl = imgui.GetWindowDrawList()
    
    -- Фон футера
    dl:AddRectFilled(imgui.ImVec2(p.x, footer_y), imgui.ImVec2(p.x + full_w, footer_y + footer_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary), S(10), 10)
    dl:AddLine(imgui.ImVec2(p.x, footer_y), imgui.ImVec2(p.x + full_w, footer_y), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.border_light))
    
    local input_y = footer_y + (footer_h - S(36)) / 2
    local start_x = p.x + S(10)
    
    -- Ширины элементов
    local w_ch = S(70)
    local w_delay = S(60)
    local w_btn = S(40)
    local w_text = full_w - w_ch - w_delay - w_btn - S(50)
    
    -- 1. Канал (Combo)
    imgui.SetCursorScreenPos(imgui.ImVec2(start_x, input_y))
    imgui.SetNextItemWidth(w_ch)
    pushComboStyles()
    -- !!! ВОТ ЗДЕСЬ ИЗМЕНЕНИЕ !!!
    local channels = {"VR", "/b", "/s", u8"Чат"} 
    local curr = Buffers.auto_pr.add_channel[0] + 1
    if imgui.BeginCombo("##add_pr_ch", channels[curr] or "VR") then
        for i, v in ipairs(channels) do
            if imgui.Selectable(v, curr == i) then Buffers.auto_pr.add_channel[0] = i - 1 end
        end
        imgui.EndCombo()
    end
    popComboStyles()
    if imgui.IsItemHovered() then imgui.SetTooltip(u8"Канал") end
    
    start_x = start_x + w_ch + S(10)
    
    -- 2. Текст
    imgui.SetCursorScreenPos(imgui.ImVec2(start_x, input_y))
    renderModernInput("##add_pr_txt", Buffers.auto_pr.add_message, w_text, "Текст нового сообщения...", false, 4096)
    
    start_x = start_x + w_text + S(10)
    
    -- 3. Задержка
    imgui.SetCursorScreenPos(imgui.ImVec2(start_x, input_y))
    imgui.SetNextItemWidth(w_delay)
    imgui.PushStyleColor(imgui.Col.FrameBg, CURRENT_THEME.bg_tertiary)
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(S(5), S(8)))
    imgui.InputInt("##add_pr_del", Buffers.auto_pr.add_delay, 0)
    imgui.PopStyleColor()
    imgui.PopStyleVar()
    if imgui.IsItemHovered() then imgui.SetTooltip(u8"Интервал (Сек)") end
    
    start_x = start_x + w_delay + S(10)
    
    -- 4. Кнопка (+)
    imgui.SetCursorScreenPos(imgui.ImVec2(start_x, input_y))
    if renderCustomButton("", w_btn, S(36), CURRENT_THEME.accent_primary, fa('plus')) then
        local txt = u8:decode(ffi.string(Buffers.auto_pr.add_message))
        if txt:gsub("%s+", "") ~= "" then
            table.insert(Data.auto_pr.messages, {
                text = txt,
                channel = Buffers.auto_pr.add_channel[0] + 1,
                delay = Buffers.auto_pr.add_delay[0],
                active = true
            })
            saveSettings()
            addToastNotification("Добавлено", "success")
            imgui.StrCopy(Buffers.auto_pr.add_message, "") 
        else
            addToastNotification("Введите текст!", "error")
        end
    end
end

function renderUnifiedHeader(text, icon)
    local p = imgui.GetCursorScreenPos()
    local w = imgui.GetContentRegionAvail().x
    
    
    imgui.Dummy(imgui.ImVec2(0, S(2)))
    
    
    if icon then
        imgui.TextColored(CURRENT_THEME.accent_secondary, icon)
        imgui.SameLine()
    end
    
    imgui.TextColored(CURRENT_THEME.accent_secondary, text)
    
    
    imgui.Separator()
    imgui.Spacing()
end


function renderModernInput(label_id, buffer, width, hint, is_secret, custom_size)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    local height = S(34) 
    local rounding = S(8)
    
    imgui.SetNextItemWidth(width)
    
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(S(8), (height - imgui.GetFontSize())/2))
    
    -- [FIX] Используем переданный размер буфера или 64 по стандарту
    local buffer_size = custom_size or 64
    local changed = imgui.InputText(label_id, buffer, buffer_size)
    
    local is_active = imgui.IsItemActive()
    local is_hovered = imgui.IsItemHovered()
    
    imgui.PopStyleVar()
    imgui.PopStyleColor(2)
    
    local bg_col = is_active and CURRENT_THEME.bg_secondary or CURRENT_THEME.bg_tertiary
    if is_hovered and not is_active then bg_col = imgui.ImVec4(bg_col.x+0.05, bg_col.y+0.05, bg_col.z+0.05, 1) end
    
    local border_col = is_active and CURRENT_THEME.accent_primary or CURRENT_THEME.border_light
    if is_hovered and not is_active then border_col = imgui.ImVec4(1,1,1,0.2) end
    
    local has_text = ffi.string(buffer) ~= ""
    
    if is_secret and not is_active and has_text then
        draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), imgui.ColorConvertFloat4ToU32(bg_col), rounding)
        draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), imgui.ColorConvertFloat4ToU32(border_col), rounding, 15, S(1.0))
        
        local mask_text = "••••••••••••••••••••"
        local text_col = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_secondary)
        draw_list:AddText(imgui.ImVec2(p.x + S(8), p.y + (height - imgui.GetFontSize())/2), text_col, mask_text)
    else
        draw_list:AddRect(p, imgui.ImVec2(p.x + width, p.y + height), imgui.ColorConvertFloat4ToU32(border_col), rounding, 15, is_active and S(1.5) or S(1.0))
    end
    
    if not has_text and not is_active and hint then
        local hint_col = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint)
        draw_list:AddText(imgui.ImVec2(p.x + S(8), p.y + (height - imgui.GetFontSize())/2), hint_col, u8(hint))
    end
    
    return changed
end


local average_price_cache = setmetatable({}, {__mode = 'v'})

local avg_price_lookup_cache = {}

function getAveragePriceForItem(item, mode, strict)
    if not item or not item.name then return nil end
    mode = mode or "sell" 
    
    -- Формируем ключ кэша
    local cache_key = item.name .. "_" .. mode .. "_" .. tostring(strict)
    if avg_price_lookup_cache[cache_key] ~= nil then
        local val = avg_price_lookup_cache[cache_key]
        return (val > 0) and val or nil
    end
    
    local search_name = item.name
    local found_data = nil
    
    -- [FIX] Этап 1: Поиск по "чистому" имени (удаляем id, цвет, x10)
    -- Это решит проблему с "Галадреель (муж.) (id: 921)" -> "Галадреель (муж.)"
    local clean_search_raw = enhancedCleanItemName(search_name) 
    
    if Data.average_prices[clean_search_raw] then
        found_data = Data.average_prices[clean_search_raw]
    elseif Data.average_prices[search_name] then
        -- Если вдруг в базе записано с мусором (редко)
        found_data = Data.average_prices[search_name]
    else
        -- [FIX] Этап 2: Полная очистка (удаление префиксов типа "Скин", "Ларец")
        -- И поиск перебором для нечетких совпадений
        local deep_clean_search = cleanItemName(search_name):lower()
        
        for avg_name, data in pairs(Data.average_prices) do
            -- Сравниваем очищенные версии имен
            if cleanItemName(avg_name):lower() == deep_clean_search then
                found_data = data
                break
            end
        end
    end
    
    local final_price = 0
    
    if found_data then
        if mode == "sell" then
            final_price = found_data.sell
            if (not final_price or final_price == 0) and not strict then
                if found_data.buy > 0 then final_price = math.floor(found_data.buy * 1.3) end
            end
        elseif mode == "buy" then
            final_price = found_data.buy
            if (not final_price or final_price == 0) and not strict then
                if found_data.sell > 0 then final_price = math.floor(found_data.sell * 0.7) end
            end
        end
        
        if (not final_price or final_price == 0) and not strict then
            final_price = found_data.price
        end
    end
    
    final_price = tonumber(final_price) or 0
    avg_price_lookup_cache[cache_key] = final_price
    return (final_price > 0) and final_price or nil
end

function stringToID(str)
    local hash = 0
    for i = 1, #str do hash = (hash * 31 + str:byte(i)) % 2147483647 end
    return hash
end

function addAccessoryWithAllColors(item)
    
    local color_count = 10 
    
    for color_id = 0, color_count - 1 do
        table.insert(Data.buy_list, {
            name = item.name, 
            price = 100, 
            amount = color_id,  
            index = item.index, 
            active = true
        })
    end
    
    saveListsConfig()
    calculateBuyTotal()
    sampAddChatMessage(string.format('[RodinaMarket] {00ff00}Добавлено %s со всеми цветами (%d шт)', item.name, color_count), -1)
end

function moveTableItem(tbl, from, to)
    if from == to or not tbl[from] then return end
    
    local item = table.remove(tbl, from)
    
    if to > from then 
        to = to - 1 
    end
    
    if to < 1 then to = 1 end
    if to > #tbl + 1 then to = #tbl + 1 end
    
    table.insert(tbl, to, item)
end

function renderMoneyTooltip(text_value)
    -- 1. Получаем состояние элемента (InputText)
    local is_active = imgui.IsItemActive()
    local is_hovered = imgui.IsItemHovered()
    
    -- Если мы не пишем и не навели мышку -- ничего не показываем
    if not is_active and not is_hovered then return end
    
    local val = tonumber(text_value)
    -- Показываем подсказку только для сумм от 1000, чтобы не мелькала на мелких числах
    if not val or val < 1000 then return end
    
    -- 2. Форматирование текста (сокращения)
    local formatted = ""
    if val >= 1000000000 then
        formatted = string.format(u8"%.2f млрд.", val / 1000000000)
    elseif val >= 1000000 then
        formatted = string.format(u8"%.2f млн.", val / 1000000)
    elseif val >= 1000 then
        formatted = string.format(u8"%.1f тыс.", val / 1000)
    end
    -- Убираем лишние ".00" или ".0"
    formatted = formatted:gsub("%.00", ""):gsub("%.0", "")
    
    -- Полное число с точками
    local money_str = formatMoney(val)
    
    -- 3. Отрисовка
    if is_hovered then
        -- ВАРИАНТ А: Мышь на поле. Используем стандартный Tooltip (следует за мышкой)
        imgui.BeginTooltip()
        imgui.TextColored(CURRENT_THEME.accent_success, formatted)
        imgui.SameLine()
        imgui.TextDisabled(string.format("(%s $)", money_str))
        imgui.EndTooltip()
        
    elseif is_active then
        -- ВАРИАНТ Б: Мы пишем, но мышь убрали. 
        -- Рисуем фиксированное окошко прямо НАД полем ввода.
        
        local p_min = imgui.GetItemRectMin()
        -- local p_max = imgui.GetItemRectMax() -- можно использовать для выравнивания
        
        -- Стилизация мини-окна под тему
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(8), S(4)))
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, S(6))
        imgui.PushStyleColor(imgui.Col.PopupBg, imgui.ImVec4(0.08, 0.08, 0.10, 0.95)) -- Темный фон
        imgui.PushStyleColor(imgui.Col.Border, CURRENT_THEME.accent_primary)          -- Цветная рамка
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, S(1))
        
        -- Позиция: X = начало поля, Y = над полем (с отступом S(32) вверх)
        local tooltip_pos = imgui.ImVec2(p_min.x, p_min.y - S(32))
        imgui.SetNextWindowPos(tooltip_pos)
        
        -- Флаги окна: Tooltip (поверх всего), без ввода, без заголовка, авто-размер
        local flags = imgui.WindowFlags.Tooltip + imgui.WindowFlags.NoInputs + 
                      imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoMove + 
                      imgui.WindowFlags.NoResize + imgui.WindowFlags.AlwaysAutoResize
        
        if imgui.Begin("##fixed_money_tooltip", nil, flags) then
            imgui.TextColored(CURRENT_THEME.accent_success, formatted)
            imgui.SameLine()
            imgui.TextDisabled(string.format("(%s $)", money_str))
            imgui.End()
        end
        
        imgui.PopStyleVar(3)
        imgui.PopStyleColor(2)
    end
end

function renderUnifiedConfigItem(index, item, mode)
    if not item then return end

    local is_sell = (mode == "sell")
    local draw_list = imgui.GetWindowDrawList()
    local p = imgui.GetCursorScreenPos()
    local avail_width = imgui.GetContentRegionAvail().x
    local height = S(85)
    local padding = S(10)

    -- Определяем, является ли предмет аксессуаром в режиме скупки
    local is_buy_accessory = (not is_sell) and isAccessory(item.name)

    if not item._uid_cache then
        item._uid_cache = tostring(item):gsub("table: ", "") .. tostring(os.clock())
    end
    local item_uid = item._uid_cache .. (is_sell and "_s" or "_b")
    
    imgui.PushIDStr("u_item_" .. item_uid)

    if item.active == nil then item.active = true end
    if is_sell and item.auto_max == nil then item.auto_max = true end

    local prefix = is_sell and "s" or "b"
    local buf_key_price  = prefix .. "p_" .. item_uid
    local buf_key_amount = prefix .. "a_" .. item_uid
    local buffer_table = is_sell and Buffers.sell_input_buffers or Buffers.buy_input_buffers

    if not buffer_table[buf_key_price] then 
        buffer_table[buf_key_price] = imgui.new.char[32](tostring(item.price or (is_sell and 0 or 100))) 
    end

    local max_inv_amount = 0
    if is_sell then
        max_inv_amount = getInventoryAmountForItem(item.model_id, item.slot)
        if item.auto_max then item.amount = max_inv_amount end
        if not item.auto_max and (item.amount or 0) > max_inv_amount and max_inv_amount > 0 then
            item.amount = max_inv_amount
        end
    end

    if not buffer_table[buf_key_amount] then 
        buffer_table[buf_key_amount] = imgui.new.char[32](tostring(item.amount or (is_buy_accessory and 0 or 1))) 
    end

    imgui.BeginGroup()
    
    imgui.SetCursorScreenPos(p)
    imgui.Dummy(imgui.ImVec2(avail_width, height))

    -- [FIX] Улучшенная логика фона для единого стиля
    local bg_col = CURRENT_THEME.bg_secondary -- Основной цвет карточки
    if is_sell and item.missing then 
        bg_col = imgui.ImVec4(0.25, 0.12, 0.12, 0.6) -- Полупрозрачный красный, если нет в инвентаре
    end
    
    local border_col = item.active and CURRENT_THEME.accent_primary or CURRENT_THEME.border_light
    -- Если не активен, делаем рамку почти прозрачной
    if not item.active then border_col = imgui.ImVec4(1, 1, 1, 0.05) end
    
    local border_thick = item.active and S(1.5) or S(1.0)

    -- Рисуем фон карточки
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + avail_width, p.y + height), imgui.ColorConvertFloat4ToU32(bg_col), S(10))
    -- Рисуем рамку
    draw_list:AddRect(p, imgui.ImVec2(p.x + avail_width, p.y + height), imgui.ColorConvertFloat4ToU32(border_col), S(10), 15, border_thick)

    local grip_width = S(28)
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x + S(4), p.y + (height - S(24))/2))
    
    imgui.InvisibleButton("##grip", imgui.ImVec2(grip_width, S(24)))
    local is_grip_hovered = imgui.IsItemHovered()
    
    if font_fa then
        imgui.PushFont(font_fa)
        local grip_icon = fa('grip_vertical')
        local grip_col = is_grip_hovered and CURRENT_THEME.accent_primary or CURRENT_THEME.text_hint
        local grip_pos_x = p.x + S(10)
        local grip_pos_y = p.y + (height - imgui.CalcTextSize(grip_icon).y)/2
        draw_list:AddText(imgui.ImVec2(grip_pos_x, grip_pos_y), imgui.ColorConvertFloat4ToU32(grip_col), grip_icon)
        imgui.PopFont()
    end
    if is_grip_hovered then imgui.SetTooltip(u8"Перетащите для сортировки") end

    if imgui.BeginDragDropSource() then
        imgui.SetDragDropPayload(is_sell and "DND_SELL" or "DND_BUY", ffi.new('int[1]', index), ffi.sizeof('int'))
        imgui.PushStyleColor(imgui.Col.PopupBg, imgui.ImVec4(0.08, 0.08, 0.1, 0.95))
        imgui.BeginGroup()
            imgui.TextColored(CURRENT_THEME.text_primary, u8(item.name))
        imgui.EndGroup()
        imgui.PopStyleColor()
        imgui.EndDragDropSource()
    end

    local content_offset_x = grip_width + S(10)
    local cursor_x = p.x + content_offset_x
    local row1_y = p.y + S(12)

    local toggle_w = S(36)
    local toggle_h = S(20)
    imgui.SetCursorScreenPos(imgui.ImVec2(cursor_x, row1_y))
    
    if imgui.InvisibleButton("act_toggle", imgui.ImVec2(toggle_w, toggle_h)) then
        item.active = not item.active
        saveListsConfig()
        if is_sell then calculateSellTotal() else calculateBuyTotal() end
    end
    
    local t_bg = item.active and CURRENT_THEME.accent_primary or CURRENT_THEME.text_hint
    local t_circle = CURRENT_THEME.text_primary
    local toggle_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(t_bg.x, t_bg.y, t_bg.z, item.active and 1.0 or 0.3))
    
    draw_list:AddRectFilled(imgui.ImVec2(cursor_x, row1_y), imgui.ImVec2(cursor_x + toggle_w, row1_y + toggle_h), toggle_col, S(10))
    local circle_center_x = item.active and (cursor_x + toggle_w - S(10)) or (cursor_x + S(10))
    draw_list:AddCircleFilled(imgui.ImVec2(circle_center_x, row1_y + S(10)), S(7), imgui.ColorConvertFloat4ToU32(t_circle))

    cursor_x = cursor_x + toggle_w + S(15)
    local name_str = item.name:gsub("%s*%(x%d+%)", "")
    local display_name = u8(index .. ". " .. name_str)
    
    if is_buy_accessory then
        display_name = u8(index .. ". " .. name_str .. " [Цвет: " .. (item.amount or 0) .. "]")
    end

    if is_sell and item.missing then display_name = u8(index .. ". " .. name_str .. " (НЕТ В ИНВЕНТАРЕ)") end

    imgui.SetCursorScreenPos(imgui.ImVec2(cursor_x, row1_y))
    
    -- [NEW] Логика цветов и средней цены
    -- Используем strict=true, чтобы получить цену именно для текущего режима (скупка или продажа)
    local avg_price = getAveragePriceForItem(item, mode)
    local strict_avg = getAveragePriceForItem(item, mode, true)
    
    local text_col = item.active and CURRENT_THEME.text_primary or CURRENT_THEME.text_secondary
    local price_warning = false
    
    if is_sell and item.missing then 
        text_col = CURRENT_THEME.accent_danger 
    else
        -- Проверка цен
        if strict_avg and strict_avg > 0 and (item.price or 0) > 0 then
            if is_sell then
                -- Если продаем дешевле рынка
                if item.price < strict_avg then 
                    text_col = CURRENT_THEME.accent_danger 
                    price_warning = true
                end
            else
                -- Если скупаем дороже рынка
                if item.price > strict_avg then 
                    text_col = CURRENT_THEME.accent_danger 
                    price_warning = true
                end
            end
        end
    end
    
    imgui.PushFont(font_default)
    imgui.TextColored(text_col, display_name)
    
    -- [ULTRADH: Улучшенный тултип с двумя ценами]
    if (imgui.IsItemHovered() or (imgui.IsItemHovered(imgui.HoveredFlags.AllowWhenOverlapped))) then
        local stat_sell = getAveragePriceForItem(item, "sell", true)
        local stat_buy  = getAveragePriceForItem(item, "buy", true)
        
        if (stat_sell and stat_sell > 0) or (stat_buy and stat_buy > 0) then
            imgui.BeginTooltip()
            
            -- Заголовок
            imgui.TextColored(CURRENT_THEME.text_secondary, u8"Средние цены по серверу:")
            imgui.Separator()
            
            -- Цена продажи (Зеленая)
            if stat_sell and stat_sell > 0 then
                imgui.Text(u8"Продажа: ")
                imgui.SameLine()
                imgui.TextColored(CURRENT_THEME.accent_success, formatMoney(stat_sell) .. " $")
            else
                imgui.TextDisabled(u8"Продажа: нет данных")
            end
            
            -- Цена скупки (Синяя/Голубая)
            if stat_buy and stat_buy > 0 then
                imgui.Text(u8"Скупка:  ")
                imgui.SameLine()
                imgui.TextColored(CURRENT_THEME.accent_primary, formatMoney(stat_buy) .. " $")
            else
                imgui.TextDisabled(u8"Скупка:  нет данных")
            end
            
            -- Предупреждение о цене
            if price_warning then
                imgui.Separator()
                if is_sell then
                    imgui.TextColored(CURRENT_THEME.accent_danger, u8("Внимание: Цена ниже рыночной!"))
                else
                    imgui.TextColored(CURRENT_THEME.accent_danger, u8("Внимание: Цена выше рыночной!"))
                end
                imgui.Text(u8("Ваша цена: ") .. formatMoney(item.price) .. " $")
            end
            
            -- Подсказка действия
            if avg_price and avg_price > 0 then
                imgui.Separator()
                local action_txt = u8("Нажмите ЛКМ, чтобы установить: ") .. formatMoney(avg_price) .. " $"
                imgui.TextDisabled(action_txt)
            end
            
            imgui.EndTooltip()
        end
    end

    if imgui.IsItemClicked() and avg_price and avg_price > 0 then
        item.price = avg_price
        buffer_table[buf_key_price] = imgui.new.char[32](tostring(avg_price))
        if is_sell then calculateSellTotal() else calculateBuyTotal() end
        saveListsConfig()
    end
    imgui.PopFont()

    local row2_y = p.y + S(45)
    cursor_x = p.x + content_offset_x 

    local input_price_w = S(120)
    local input_h = S(30)
    
    local bg_input_col = CURRENT_THEME.bg_tertiary
    local border_input_col = CURRENT_THEME.border_light
    
    -- Если цена плохая, подсвечиваем рамку инпута красным
    if price_warning then
        border_input_col = CURRENT_THEME.accent_danger
    end
    
    draw_list:AddRectFilled(imgui.ImVec2(cursor_x, row2_y), imgui.ImVec2(cursor_x + input_price_w, row2_y + input_h), imgui.ColorConvertFloat4ToU32(bg_input_col), S(6))
    draw_list:AddRect(imgui.ImVec2(cursor_x, row2_y), imgui.ImVec2(cursor_x + input_price_w, row2_y + input_h), imgui.ColorConvertFloat4ToU32(border_input_col), S(6), 15, S(1.0))

    imgui.SetCursorScreenPos(imgui.ImVec2(cursor_x, row2_y))
    local current_price_str = ffi.string(buffer_table[buf_key_price])
    local txt_width = imgui.CalcTextSize(current_price_str).x
    local pad_x = (input_price_w - txt_width) / 2
    if pad_x < S(5) then pad_x = S(5) end
    
    imgui.SetNextItemWidth(input_price_w)
    imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0,0,0,0)) 
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0,0,0,0))
    imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(pad_x, (input_h - imgui.GetFontSize()) / 2))
    
    local changed_price = imgui.InputText("##pr"..item_uid, buffer_table[buf_key_price], 32, imgui.InputTextFlags.CharsDecimal + imgui.InputTextFlags.CharsNoBlank)
    
    renderMoneyTooltip(ffi.string(buffer_table[buf_key_price]))
    
    imgui.PopStyleVar()
    imgui.PopStyleColor(2)
    
    if changed_price then
        item.price = tonumber(ffi.string(buffer_table[buf_key_price])) or 0
        if is_sell then calculateSellTotal() else calculateBuyTotal() end
    end
    if imgui.IsItemDeactivatedAfterEdit() then saveListsConfig() end
    cursor_x = cursor_x + input_price_w + S(8)

    if font_fa then
        imgui.PushFont(font_fa)
        local rub_sz = imgui.CalcTextSize(fa('ruble_sign'))
        draw_list:AddText(imgui.ImVec2(cursor_x, row2_y + (S(30)-rub_sz.y)/2), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint), fa('ruble_sign'))
        imgui.PopFont()
        cursor_x = cursor_x + rub_sz.x + S(8)
    else
        cursor_x = cursor_x + S(20)
    end

    if is_sell then
        local matches_count = 0
        for _, sit in ipairs(Data.sell_list) do
            if sit.name == item.name then matches_count = matches_count + 1 end
        end

        if matches_count > 1 then
            local tags_btn_sz = S(30)
            imgui.SetCursorScreenPos(imgui.ImVec2(cursor_x, row2_y))
            if imgui.InvisibleButton("##apply_all_"..item_uid, imgui.ImVec2(tags_btn_sz, S(30))) then
                local target_price = item.price
                local count_updated = 0
                for i, sit in ipairs(Data.sell_list) do
                    if sit.name == item.name then
                        sit.price = target_price
                        local s_uid = sit._uid_cache or (tostring(sit):gsub("table: ", "") .. tostring(os.clock()))
                        sit._uid_cache = s_uid
                        local s_uid_full = s_uid .. "_s"
                        local s_key = "sp_" .. s_uid_full
                        Buffers.sell_input_buffers[s_key] = imgui.new.char[32](tostring(target_price))
                        count_updated = count_updated + 1
                    end
                end
                calculateSellTotal()
                saveListsConfig()
                addToastNotification("Цена обновлена у " .. count_updated .. " товаров", "success")
            end
            
            local is_tags_hovered = imgui.IsItemHovered()
            local tags_col = is_tags_hovered and CURRENT_THEME.accent_warning or CURRENT_THEME.text_hint
            
            if font_fa then
                imgui.PushFont(font_fa)
                local icon_tags = fa('tags')
                local tsz = imgui.CalcTextSize(icon_tags)
                draw_list:AddText(imgui.ImVec2(cursor_x + (tags_btn_sz-tsz.x)/2, row2_y + (S(30)-tsz.y)/2), imgui.ColorConvertFloat4ToU32(tags_col), icon_tags)
                imgui.PopFont()
            end
            if is_tags_hovered then imgui.SetTooltip(u8"Применить эту цену ко всем таким товарам ("..matches_count..")") end
            
            cursor_x = cursor_x + tags_btn_sz + S(8)
        else
            cursor_x = cursor_x + S(10)
        end
    else
        cursor_x = cursor_x + S(10)
    end

    if is_sell then
        local am_btn_size = S(30)
        imgui.SetCursorScreenPos(imgui.ImVec2(cursor_x, row2_y))
        if imgui.InvisibleButton("##am_toggle", imgui.ImVec2(am_btn_size, S(30))) then
            item.auto_max = not item.auto_max
            if item.auto_max then
                item.amount = max_inv_amount
                calculateSellTotal()
            end
            saveListsConfig()
        end
        local am_col = item.auto_max and CURRENT_THEME.accent_primary or CURRENT_THEME.text_hint
        local am_bg = item.auto_max and imgui.ColorConvertFloat4ToU32(imgui.ImVec4(am_col.x, am_col.y, am_col.z, 0.2)) or 0
        if am_bg ~= 0 then draw_list:AddRectFilled(imgui.ImVec2(cursor_x, row2_y), imgui.ImVec2(cursor_x + am_btn_size, row2_y + S(30)), am_bg, S(6)) end
        
        if font_fa then
            imgui.PushFont(font_fa)
            local icon_layer = fa('layer_group')
            local isz = imgui.CalcTextSize(icon_layer)
            draw_list:AddText(imgui.ImVec2(cursor_x + (am_btn_size-isz.x)/2, row2_y + (S(30)-isz.y)/2), imgui.ColorConvertFloat4ToU32(am_col), icon_layer)
            imgui.PopFont()
        end
        if imgui.IsItemHovered() then imgui.SetTooltip(item.auto_max and u8"Авто-максимум: ВКЛ" or u8"Авто-максимум: ВЫКЛ") end
        cursor_x = cursor_x + am_btn_size + S(8)
    end

    local input_amt_w = S(70)
    imgui.SetCursorScreenPos(imgui.ImVec2(cursor_x, row2_y))

    if is_sell and item.auto_max then
        draw_list:AddRectFilled(imgui.ImVec2(cursor_x, row2_y), imgui.ImVec2(cursor_x + input_amt_w, row2_y + S(30)), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary), S(6))
        draw_list:AddRect(imgui.ImVec2(cursor_x, row2_y), imgui.ImVec2(cursor_x + input_amt_w, row2_y + S(30)), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint), S(6), 15, S(1))
        local txt_max = "MAX"
        local txt_sz = imgui.CalcTextSize(txt_max)
        draw_list:AddText(imgui.ImVec2(cursor_x + (input_amt_w - txt_sz.x)/2, row2_y + (S(30) - txt_sz.y)/2), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary), txt_max)
    else
        if not imgui.IsItemActive() then buffer_table[buf_key_amount] = imgui.new.char[32](tostring(item.amount)) end
        local amt_str = ffi.string(buffer_table[buf_key_amount])
        local amt_sz = imgui.CalcTextSize(amt_str).x
        local amt_pad = (input_amt_w - amt_sz) / 2
        if amt_pad < S(5) then amt_pad = S(5) end

        local input_bg_color = is_buy_accessory and CURRENT_THEME.bg_secondary or CURRENT_THEME.bg_tertiary
        
        draw_list:AddRectFilled(imgui.ImVec2(cursor_x, row2_y), imgui.ImVec2(cursor_x + input_amt_w, row2_y + S(30)), imgui.ColorConvertFloat4ToU32(input_bg_color), S(6))
        if is_buy_accessory then
            draw_list:AddRect(imgui.ImVec2(cursor_x, row2_y), imgui.ImVec2(cursor_x + input_amt_w, row2_y + S(30)), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary), S(6), 15, S(1.0))
        end

        imgui.SetNextItemWidth(input_amt_w)
        imgui.PushStyleColor(imgui.Col.FrameBg, imgui.ImVec4(0,0,0,0))
        imgui.PushStyleVarVec2(imgui.StyleVar.FramePadding, imgui.ImVec2(amt_pad, (S(30) - imgui.GetFontSize())/2))
        
        if imgui.InputText("##amt"..item_uid, buffer_table[buf_key_amount], 32, imgui.InputTextFlags.CharsDecimal + imgui.InputTextFlags.CharsNoBlank) then
            local val = tonumber(ffi.string(buffer_table[buf_key_amount])) or 0
            
            if is_buy_accessory then
                if val < 0 then val = 0 end
                if val > 9 then val = 9 end 
            else
                if is_sell and val > max_inv_amount then val = max_inv_amount end
                if val < 1 then val = 1 end
            end
            
            item.amount = val
            if is_sell then calculateSellTotal() else calculateBuyTotal() end
        end
        if imgui.IsItemHovered() and is_buy_accessory then
            imgui.SetTooltip(u8"Укажите ID цвета (0 - Нет цвета, и т.д.)")
        end

        imgui.PopStyleVar()
        imgui.PopStyleColor()
        if imgui.IsItemDeactivatedAfterEdit() then saveListsConfig() end
    end
    cursor_x = cursor_x + input_amt_w + S(8)
    
    imgui.SetCursorScreenPos(imgui.ImVec2(cursor_x, row2_y + S(7)))
    if is_buy_accessory then
        imgui.TextColored(CURRENT_THEME.accent_primary, u8"Цвет")
    else
        imgui.TextColored(CURRENT_THEME.text_hint, u8"шт.")
    end

    local del_size = S(30)
    local del_x = p.x + avail_width - del_size - S(10)
    imgui.SetCursorScreenPos(imgui.ImVec2(del_x, row2_y))
    if imgui.InvisibleButton("del_btn", imgui.ImVec2(del_size, S(30))) then
        table.remove(is_sell and Data.sell_list or Data.buy_list, index)
        saveListsConfig()
        if is_sell then calculateSellTotal() else calculateBuyTotal() end
    end
    local del_col = imgui.IsItemHovered() and CURRENT_THEME.accent_danger or CURRENT_THEME.text_hint
    if font_fa then
        imgui.PushFont(font_fa)
        local icon_trash = fa('trash')
        local tsz = imgui.CalcTextSize(icon_trash)
        draw_list:AddText(imgui.ImVec2(del_x + (del_size-tsz.x)/2, row2_y + (S(30)-tsz.y)/2), imgui.ColorConvertFloat4ToU32(del_col), icon_trash)
        imgui.PopFont()
    end

    imgui.EndGroup()

    if imgui.BeginDragDropTarget() then
        local payload_active = imgui.GetDragDropPayload()
        if payload_active then
            local payload_type = ffi.string(payload_active.DataType)
            local is_correct_payload = false
            
            if (is_sell and payload_type == "DND_SELL") or (not is_sell and payload_type == "DND_BUY") then
                is_correct_payload = true
            end

            if is_correct_payload then
                local mouse_y = imgui.GetMousePos().y
                local item_center_y = p.y + (height / 2)
                local is_bottom_half = mouse_y > item_center_y
                local line_y = is_bottom_half and (p.y + height + S(2)) or (p.y - S(2))
                local line_col = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary)
                draw_list:AddRectFilled(imgui.ImVec2(p.x, line_y - S(2)), imgui.ImVec2(p.x + avail_width, line_y + S(2)), line_col, S(2))
            end
        end

        local payload = imgui.AcceptDragDropPayload(is_sell and "DND_SELL" or "DND_BUY", imgui.DragDropFlags.AcceptNoDrawDefaultRect)
        if payload ~= nil then
            local from_index = ffi.cast("int*", payload.Data)[0]
            local mouse_y = imgui.GetMousePos().y
            local item_center_y = p.y + (height / 2)
            local is_bottom_half = mouse_y > item_center_y
            local to_index = is_bottom_half and (index + 1) or index
            
            local target_list = is_sell and Data.sell_list or Data.buy_list
            moveTableItem(target_list, from_index, to_index)
            saveListsConfig()
            if is_sell then calculateSellTotal() else calculateBuyTotal() end
        end
        imgui.EndDragDropTarget()
    end

    imgui.PopID()
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + height + padding))
end

function renderIconInButton(draw_list, icon, x, y, size, hovered, color_vec, disabled)
    if not font_fa then return end
    
    local col = color_vec or CURRENT_THEME.text_secondary
    if disabled then col = CURRENT_THEME.text_hint end
    if hovered and not disabled then col = CURRENT_THEME.text_primary end
    
    local u32 = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(col.x, col.y, col.z, disabled and 0.3 or 1.0))
    
    imgui.PushFont(font_fa)
    local sz = imgui.CalcTextSize(icon)
    draw_list:AddText(imgui.ImVec2(x + (size-sz.x)/2, y - sz.y/2), u32, icon)
    imgui.PopFont()
end

function startSingleItemSelling(item)
    if App.is_scanning or App.is_selling_cef or App.is_scanning_buy or State.buying.active then return end
    
    if item.active == false then
        sampAddChatMessage('[RodinaMarket] {ff0000}Товар отключен!', -1)
        return
    end
    
    App.live_shop_active = true
    Marketplace.enabled = true
    Marketplace.is_cleared = false
    Marketplace.publish_sell = true
    MarketConfig.LAST_SYNC = 0 
    
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
    
    App.tasks.add("cef_sell_single_prepare", function()
        if App.is_selling_cef then
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
                local final_amount = item.amount
                if item.auto_max then
                    local max_inv = getInventoryAmountForItem(target_model, found_slot)
                    if max_inv > 0 then 
                        final_amount = max_inv
                        item.amount = max_inv
                    end
                end

                table.insert(Data.cef_sell_queue, {
                    slot = found_slot,
                    model = target_model,
                    amount = final_amount,
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

    App.live_shop_active = true
    Marketplace.enabled = true
    Marketplace.is_cleared = false
    Marketplace.publish_buy = true
    MarketConfig.LAST_SYNC = 0
    
    State.buying = {
        active = true, 
        stage = 'waiting_menu',  
        items_to_buy = {item},
        current_item_index = 1,  
        last_search_name = nil,
        waiting_for_alt = false
    }
    
    sampAddChatMessage('[RodinaMarket] {ffff00}Начинаю скупку товара: ' .. item.name, -1)
    
    App.tasks.add("buy_press_alt", function()
        setVirtualKeyDown(0x12, true)
        App.tasks.add("buy_release_alt", function() 
            setVirtualKeyDown(0x12, false) 
        end, 50)
    end, 1000)
    
    App.tasks.add("wait_buy_dialog", function()
        if State.buying.active and State.buying.stage == 'waiting_menu' then  
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

function finishScanningProcess()
    App.is_scanning = false
    if State.inventory_scan then
        State.inventory_scan.active = false
        State.inventory_scan.waiting_for_packets = false
    end
    App.tasks.remove_by_name("scan_timeout")
    App.tasks.remove_by_name("collect_inventory_data") 
    
    if sampIsDialogActive() then
        sampCloseCurrentDialogWithButton(0)
    end
    
    Data.scanned_items = {}
    
    -- [FIX] Используем pairs вместо ipairs
    for _, item_data in pairs(Data.cef_inventory_items) do
        if Data.item_names[tostring(item_data.model_id)] and not isItemUnsellable(item_data.model_id) then
            local display_name = item_data.name
            
            if item_data.text and item_data.text ~= "" and item_data.text ~= tostring(item_data.amount) then
                display_name = display_name .. " [" .. item_data.text .. "]"
            end
            
            if item_data.amount and item_data.amount > 1 then
                display_name = display_name .. " (x" .. item_data.amount .. ")"
            end

            table.insert(Data.scanned_items, {
                name = display_name, 
                original_name = item_data.name,
                model_id = item_data.model_id,
                amount = item_data.amount, 
                slot = item_data.slot,
                text = item_data.text,
                time = item_data.time,
                -- [FIX] Важно: Передаем статус блокировки в финальный список
                is_blocked = item_data.is_blocked 
            })
        end
    end
    
    table.sort(Data.scanned_items, function(a, b) 
        return (tonumber(a.slot) or 0) < (tonumber(b.slot) or 0) 
    end)
    
    recalculateInventoryTotals()
    
    -- Обновляем локальные списки
    for _, sell_item in ipairs(Data.sell_list) do
        if sell_item.model_id then
            if sell_item.slot then
                local slot_num = tonumber(sell_item.slot)
                local saved_model = tonumber(sell_item.model_id)
                local actual_item = Data.cef_slots_data[slot_num]
                
                if not actual_item or tonumber(actual_item.model_id) ~= saved_model then
                    sell_item.slot = nil
                end
            end
            
            if not sell_item.slot then
                for _, scanned in ipairs(Data.scanned_items) do
                    if tonumber(scanned.model_id) == tonumber(sell_item.model_id) then
                        sell_item.slot = scanned.slot
                        break
                    end
                end
            end

            local max_inv = getInventoryAmountForItem(sell_item.model_id, sell_item.slot)
            sell_item.missing = (max_inv == 0)
            
            if sell_item.auto_max then
                sell_item.amount = max_inv
            end
        end
    end
    
    saveJsonFile(PATHS.CACHE .. 'scanned_items.json', Data.scanned_items)
    saveJsonFile(PATHS.DATA .. 'item_amounts.json', Data.inventory_item_amounts)
    
	api_SyncInventory()
	
    calculateSellTotal()
    saveListsConfig() 
    
    Data.cached_sell_filtered = nil 
    
    sampAddChatMessage('[RodinaMarket] {00ff00}Сканирование завершено! Найдено предметов: ' .. #Data.scanned_items, -1)
    
    -- [FIX] Если была запрошена удаленная команда, отправляем данные на сервер
    App.is_busy_remote = false
    App.win_state[0] = true
end

function parseCEFInventory(str)
    -- Очистка строки от мусора
    str = str:gsub("`", ""):gsub("^%s+", ""):gsub("%s+$", "")
    
    if not (str:find("event%.inventory%.playerInventory") or str:find("items") or str:find("action")) then return end
    
    -- Логика для авто-сканирования (через настройки)
    if State.inventory_scan and State.inventory_scan.waiting_for_packets then
        State.inventory_scan.last_packet_time = os.clock()
        State.inventory_scan.has_received_data = true
    end
    
    -- Поиск JSON
    local json_start = str:find("%[")
    if not json_start then return end
    
    local bracket_count = 0
    local json_end = nil
    for i = json_start, #str do
        local char = str:sub(i, i)
        if char == "[" then bracket_count = bracket_count + 1
        elseif char == "]" then
            bracket_count = bracket_count - 1
            if bracket_count == 0 then json_end = i break end
        end
    end
    if not json_end then return end
    
    local json_str = str:sub(json_start, json_end):gsub("%c", "")
    local status, data = pcall(json.decode, json_str)
    if not status or not data then return end
    
    for _, event_data in ipairs(data) do
        local action = event_data.action 
        local d = event_data.data
        
        -- ============================================================
        -- === ПРОСМОТР ЧУЖИХ ЛАВОК (ТОЛЬКО ВИЗУАЛ, БЕЗ ОТПРАВКИ) ===
        -- ============================================================
        if (action == 0 or action == 2) and d and (d.type == 9 or d.type == 10) and d.items then
            App.remote_shop_active = true
            
            if os.clock() - (Data.last_remote_packet or 0) > 1.5 then
                Data.remote_shop_items = {}
            end
            Data.last_remote_packet = os.clock()
            
            for _, item in ipairs(d.items) do
                if item.item then
                    local model_id = tonumber(item.item)
                    local item_name = Data.item_names[tostring(model_id)]
                    if not item_name or item_name == "" then
                        item_name = "Предмет_" .. tostring(model_id)
                    end
                    
                    local raw_price_text = item.text or "0"
                    local real_price = parseRodinaPrice(raw_price_text)

                    local exists = false
                    for _, existing in ipairs(Data.remote_shop_items) do
                        if existing.slot == item.slot then exists = true break end
                    end

                    if not exists then
                        table.insert(Data.remote_shop_items, {
                            name = item_name,
                            model_id = model_id,
                            slot = item.slot,
                            amount = item.amount or 1,
                            price_text = raw_price_text,
                            raw_price = real_price,
                            shop_type = d.type
                        })
                    end
                end
            end
            
            -- [УДАЛЕНО] Логика batch_items и отправки на сервер
            -- Теперь мы только показываем окно, но не собираем цены в базу

            table.sort(Data.remote_shop_items, function(a, b)
                return (a.slot or 0) < (b.slot or 0)
            end)
        end

        -- ============================================================
        -- === СВОЙ ИНВЕНТАРЬ (Тип 1) ===
        -- ============================================================
        if (action == 2 or action == 0) and d and d.type == 1 and d.items then
            for _, item in ipairs(d.items) do
                local slot = tonumber(item.slot)
                if slot and item.item then
                     local model_id = tonumber(item.item)
                     local final_amount = tonumber(item.amount)
                     if not final_amount then
                        if Data.cef_slots_data[slot] and Data.cef_slots_data[slot].model_id == model_id then
                            final_amount = Data.cef_slots_data[slot].amount
                        else final_amount = 1 end
                     end
                     Data.cef_slots_data[slot] = {
                        model_id = model_id,
                        slot = slot,
                        amount = final_amount,
                        available = item.available,
                        text = item.text,
                        time = item.time
                    }
                    if App.cef_inventory_active or State.inventory_scan.active then
                        Data.cef_inventory_items[slot] = {
                            model_id = model_id,
                            name = Data.item_names[tostring(model_id)] or "Unknown_"..model_id,
                            slot = slot,
                            amount = final_amount,
                            text = item.text,
                            time = item.time,
                            is_blocked = (item.blackout == 1) or (item.available == 0)
                        }
                    end
                elseif slot and item.available == 0 and not item.blackout then 
                    if Data.cef_slots_data[slot] then Data.cef_slots_data[slot] = nil end
                    if Data.cef_inventory_items[slot] then Data.cef_inventory_items[slot] = nil end
                end
            end
            recalculateInventoryTotals()
        end
    end
end

function getInventoryAmountForItem(model_id, specific_slot)
    if specific_slot and Data.cef_slots_data and Data.cef_slots_data[specific_slot] then
        local item = Data.cef_slots_data[specific_slot]
        if tonumber(item.model_id) == tonumber(model_id) then
            return item.amount or 0
        end
    end

    local model_str = tostring(model_id)
    if Data.inventory_item_amounts and Data.inventory_item_amounts[model_str] then
        return Data.inventory_item_amounts[model_str]
    end

    return 0
end

local header_particles = {}
local particle_icons = {
    fa('fire'), fa('star'), fa('circle'), fa('ghost'), fa('bolt'), fa('heart'), fa('clover')
}


local header_animation_time = 0.0

function create_particle(window_width, header_height)
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
        particle_type = particle_type, 
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
    
    imgui.SetCursorScreenPos(p)
    if imgui.InvisibleButton("##header_drag_zone", imgui.ImVec2(w, h)) then end
    
    if imgui.IsItemActive() and imgui.IsMouseDragging(0) then
        local delta = imgui.GetMouseDragDelta(0)
        local wp = imgui.GetWindowPos()
        imgui.SetWindowPosVec2(imgui.ImVec2(wp.x + delta.x, wp.y + delta.y))
        imgui.ResetMouseDragDelta(0)
    end
    
    imgui.SetItemAllowOverlap()
    p = imgui.GetWindowPos()
    imgui.SetCursorScreenPos(p)
    
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
        
        if part.y > h * 0.5 then
            part.opacity = math.min(0.6, part.opacity + delta_time * 1.2)
        else
            part.opacity = math.max(0.0, part.opacity - delta_time * 1.5)
        end
        
        local draw_pos = imgui.ImVec2(p.x + part.x + x_swing, p.y + part.y)
        local glow_col = imgui.ColorConvertFloat4ToU32(
            imgui.ImVec4(part.color.x, part.color.y, part.color.z, part.opacity * 0.4)
        )

        if font_fa then
            imgui.PushFont(font_fa)
            draw_list:AddText(imgui.ImVec2(draw_pos.x + 1, draw_pos.y + 1), glow_col, part.icon)
            draw_list:AddText(draw_pos,
                imgui.ColorConvertFloat4ToU32(
                    imgui.ImVec4(part.color.x, part.color.y, part.color.z, part.opacity)
                ),
                part.icon
            )
            imgui.PopFont()
        end

        if part.y < -30 or (part.opacity <= 0 and part.y < h * 0.5) then
            table.remove(header_particles, i)
        end
    end
    imgui.PopClipRect()

    local text_y = p.y + (h - imgui.GetFontSize()) * 0.5

    -- Иконка слева
    if font_fa then imgui.PushFont(font_fa) end
    draw_list:AddText(
        imgui.ImVec2(p.x + S(20), text_y),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.4, 0.25, 0.95, 0.9)),
        fa('code')
    )
    if font_fa then imgui.PopFont() end

    ----------------------------------------------------------------
    -- VIP ЗАГОЛОВОК
    ----------------------------------------------------------------
    local title_text = "RODINA MARKET"
    local title_x = p.x + S(50)
    local name_glow = 0.8 + math.sin(header_animation_time * 1.5) * 0.2
    
    -- [VIP VISUAL] Золотой цвет текста для VIP
    local title_color_vec
    if Data.is_vip then
        local t = (math.sin(header_animation_time * 2.0) + 1.0) * 0.5
        -- Перелив от золотого к светло-желтому
        title_color_vec = imgui.ImVec4(1.0, lerp(0.84, 0.95, t), lerp(0.0, 0.2, t), 1.0)
    else
        title_color_vec = CURRENT_THEME.text_primary
    end

    -- Рисуем название
    draw_list:AddText(
        imgui.ImVec2(title_x, text_y),
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(title_color_vec.x, title_color_vec.y, title_color_vec.z, name_glow)),
        title_text
    )
    
    local title_width = imgui.CalcTextSize(title_text).x
    local extra_offset = 0 -- Смещение для версии (изначально 0)

    -- [VIP VISUAL] Рисуем Корону и считаем отступ
    if Data.is_vip and font_fa then
        imgui.PushFont(font_fa)
        local crown_icon = fa('crown')
        local crown_sz = imgui.CalcTextSize(crown_icon)
        
        -- Рисуем корону сразу после текста
        draw_list:AddText(imgui.ImVec2(title_x + title_width + S(6), text_y), 0xFFFFD700, crown_icon)
        
        -- [FIX] Добавляем ширину короны к отступу для версии
        extra_offset = crown_sz.x + S(6)
        
        imgui.PopFont()
    end
    
    -- ЛОГИКА ОТОБРАЖЕНИЯ ВЕРСИИ
    local ver_str = "v" .. SCRIPT_CURRENT_VERSION
    if UpdateState.is_outdated then
        ver_str = u8"Обновить! (v" .. UpdateState.remote_version .. ")"
    end

    -- [FIX] Позиция X теперь учитывает extra_offset
    local badge_x = title_x + title_width + S(15) + extra_offset
    local badge_y = text_y - S(2)
    
    imgui.PushFont(font_default)
    imgui.SetWindowFontScale(0.75)
    local ver_sz = imgui.CalcTextSize(ver_str)
    local badge_w = ver_sz.x + S(12)
    local badge_h = ver_sz.y + S(4)
    
    local badge_col_u32 = UpdateState.is_outdated and 0xFF0033DD or 0xFF006633 
    
    draw_list:AddRectFilled(imgui.ImVec2(badge_x, badge_y), imgui.ImVec2(badge_x + badge_w, badge_y + badge_h), badge_col_u32, S(6))
    draw_list:AddText(imgui.ImVec2(badge_x + S(6), badge_y + S(2)), 0xFFFFFFFF, ver_str)
    
    imgui.SetWindowFontScale(1.0)
    imgui.PopFont()
    
    -- Социальные иконки (сдвигаем их тоже, чтобы не налезли на длинную версию)
    local social_x = badge_x + badge_w + S(15)
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

    local search_hint = ""
    local search_buffer = nil
    local is_search_active = false

    if App.active_tab == 1 then search_hint = "Поиск (Продажа)" search_buffer = Buffers.sell_search is_search_active = true
    elseif App.active_tab == 2 then search_hint = "Поиск (Скупка)" search_buffer = Buffers.buy_search is_search_active = true
    elseif App.active_tab == 3 then search_hint = "Поиск по логам" search_buffer = Buffers.logs_search is_search_active = true
    elseif App.active_tab == 4 then search_hint = "Поиск товара" search_buffer = MarketData.search_buffer is_search_active = true end

    if is_search_active and search_buffer then
        local search_w = S(300) 
        local search_h_real = S(40)
        local search_x = p.x + (w * 0.5) - (search_w * 0.5)
        local search_y = p.y + (h * 0.5) - (search_h_real * 0.5)
        imgui.SetCursorScreenPos(imgui.ImVec2(search_x, search_y))
        renderAnimatedSearchBar(search_buffer, search_hint, search_w)
    end
    
    local btn_size = S(32)
    local btn_spacing = S(8)
    local close_btn_x = p.x + w - btn_size - S(15)
    local close_btn_y = p.y + (h - btn_size) * 0.5
    local current_x = close_btn_x - btn_spacing
    
    local function drawHeaderBtn(icon, callback, color_active, tooltip, blink_alert)
        current_x = current_x - btn_size
        imgui.SetCursorScreenPos(imgui.ImVec2(current_x, close_btn_y))
        
        if imgui.InvisibleButton("##hbtn_"..icon, imgui.ImVec2(btn_size, btn_size)) then callback() end
        
        local is_hovered = imgui.IsItemHovered()
        local is_active = imgui.IsItemActive()
        
        -- Анимация наведения
        local btn_key = "hbtn_"..icon
        if not button_anim_states[btn_key] then button_anim_states[btn_key] = { scale = 1.0, target_scale = 1.0 } end
        local btn_state = button_anim_states[btn_key]
        btn_state.target_scale = (is_hovered or is_active) and 1.15 or 1.0
        btn_state.scale = lerp(btn_state.scale, btn_state.target_scale, 0.2)
        
        -- Цвет кнопки
        local icon_col = is_hovered and color_active or 0xB0FFFFFF
        
        -- Логика мигания
        if blink_alert then
            local pulse = (math.sin(os.clock() * 6) + 1.0) * 0.5 -- от 0 до 1
            local alert_col = imgui.ImVec4(1.0, 0.2, 0.2, 1.0) -- Красный
            local normal_col_vec = imgui.ImVec4(0.4, 0.8, 1.0, 1.0) -- Голубой (стандартный для этой кнопки)
            
            -- Смешиваем цвета
            local r = normal_col_vec.x + (alert_col.x - normal_col_vec.x) * pulse
            local g = normal_col_vec.y + (alert_col.y - normal_col_vec.y) * pulse
            local b = normal_col_vec.z + (alert_col.z - normal_col_vec.z) * pulse
            
            icon_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, 1.0))
        end

        if font_fa then imgui.PushFont(font_fa) end
        local txt_sz = imgui.CalcTextSize(icon)
        draw_list:AddText(imgui.ImVec2(current_x + (btn_size - txt_sz.x)/2, close_btn_y + (btn_size - txt_sz.y)/2), icon_col, icon)
        if font_fa then imgui.PopFont() end
        
        if is_hovered and tooltip then imgui.SetTooltip(u8(tooltip)) end
        current_x = current_x - btn_spacing
    end

    --if App.active_tab == 5 then
    --    local icon = App.render_radius and fa('eye') or fa('eye_slash')
    --    local color = App.render_radius and 0xFF66FF66 or 0xFFFFFFFF
    --    local tooltip = App.render_radius and "Скрыть радиус лавок" or "Показать радиус лавок (5м)"
    --    drawHeaderBtn(icon, function() App.render_radius = not App.render_radius addToastNotification(App.render_radius and "Радиус лавок включен" or "Радиус лавок выключен", "info") end, color, tooltip)
    --end
	
	local vip_color = Data.is_vip and 0xFFFFD700 or 0xFF808080 -- Золотой или Серый
    local vip_tooltip = Data.is_vip and "VIP Активирован! Спасибо за поддержку" or "Активировать VIP статус"
    
    drawHeaderBtn(fa('crown'), function() 
        os.execute('explorer "https://t.me/rdnMarket_bot?start=script"')
        addToastNotification("Перейдите в Telegram для управления VIP", "info", 4.0)
    end, vip_color, vip_tooltip, not Data.is_vip) -- Мигает если нет VIP
    
	    
	if App.active_tab == 7 then
        local icon = MarketData.is_loading and fa('spinner') or fa('arrows_rotate')
        drawHeaderBtn(icon, function() api_GetVipAnalytics('top_resale') MarketData.last_fetch = os.time() end, 0xFFFFFFFF, "Обновить список")
    end
	
    if App.active_tab == 4 then
        local icon = MarketData.is_loading and fa('spinner') or fa('arrows_rotate')
        drawHeaderBtn(icon, function() api_FetchMarketList() MarketData.last_fetch = os.time() end, 0xFFFFFFFF, "Обновить список")
    end
    
    if App.active_tab == 2 then
        -- Кнопка сканирования (Мигает, если база пуста)
        local db_empty = isItemDbEmpty()
        local scan_tooltip = db_empty and "ВНИМАНИЕ: База пуста! Нажмите для сканирования" or "Сканировать товары для скупки"
        
        drawHeaderBtn(fa('bag_shopping'), function() startBuyingScan() end, 0xFF66CCFF, scan_tooltip, db_empty)
        
        -- Кнопка конфигов (Блокируется, если база пуста)
        drawHeaderBtn(fa('sliders'), function() 
            if db_empty then
                addToastNotification("Сначала просканируйте товары (кнопка левее)!", "error")
            else
                App.show_config_manager = true 
            end
        end, 0xFFFFAA00, "Управление конфигами")
    end
    
    if App.active_tab == 1 then
        local db_empty = isItemDbEmpty()
        
        -- Скан средних цен
		drawHeaderBtn(fa('cloud_arrow_down'), function() 
			api_DownloadAveragePrices()
		end, 0xFF00A5FF, "Скачать средние цены")
        
        -- Конфиги продажи
        drawHeaderBtn(fa('sliders'), function() 
            if db_empty then
                addToastNotification("Сначала просканируйте базу товаров во вкладке 'Скупка'!", "error")
            else
                App.show_sell_config_manager = true 
            end
        end, 0xFFFFAA00, "Конфиги продажи")
        
        -- Скан инвентаря
        local has_db = not db_empty
        local scan_color = has_db and 0xFF66CC66 or 0xFF808080 
        local scan_tooltip = has_db and "Сканировать инвентарь" or "Сначала просканируйте товары во вкладке СКУПКА!"
        
		drawHeaderBtn(fa('magnifying_glass'), function() 
            if has_db then
                startScanning() 
            else
                addToastNotification("Ошибка: База предметов пуста!", "error")
                addToastNotification("Перейдите в 'Скупку' и просканируйте товары.", "warning", 4.0)
            end
        end, scan_color, scan_tooltip)
    end
    
    imgui.SetCursorScreenPos(imgui.ImVec2(close_btn_x, close_btn_y))
    if imgui.InvisibleButton("##close_header", imgui.ImVec2(btn_size, btn_size)) then App.win_state[0] = false end
    local h_close = imgui.IsItemHovered()
    
    draw_list:AddRectFilled(imgui.ImVec2(close_btn_x, close_btn_y), imgui.ImVec2(close_btn_x+btn_size, close_btn_y+btn_size), h_close and 0x40FF0000 or 0, S(6))
    if font_fa then imgui.PushFont(font_fa) end
    local x_sz = imgui.CalcTextSize(fa('xmark'))
    draw_list:AddText(imgui.ImVec2(close_btn_x + (btn_size - x_sz.x)/2, close_btn_y + (btn_size - x_sz.y)/2), h_close and 0xFFFFFFFF or 0xB0FFFFFF, fa('xmark'))
    if font_fa then imgui.PopFont() end
    
    draw_list:AddLine(imgui.ImVec2(p.x, p.y + h - 1), imgui.ImVec2(p.x + w, p.y + h - 1), 0x804D4D4D, 1.0)
    
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + h))
end

local remote_header_particles = {}
local remote_particle_icons = {
    fa('cart_plus'), fa('bag_shopping'), fa('money_bill'), fa('coins'), fa('percent'), fa('tag')
}

function create_remote_particle(window_width, header_height)
    return {
        x = math.random(-50, window_width),
        y = math.random(0, header_height),
        speed_x = math.random(10, 30) / 10, 
        speed_y = (math.random() - 0.5) * 0.5, 
        size = math.random(12, 18),
        rotation = math.random(0, 360) / 57.29,
        rot_speed = (math.random() - 0.5) * 2.0,
        opacity = 0.0,
        target_opacity = math.random(20, 50) / 100,
        color = imgui.ImVec4(0.2, 0.8, 0.4, 0.0), 
        icon = remote_particle_icons[math.random(1, #remote_particle_icons)]
    }
end

function renderRemoteShopHeader(w, h)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    
    
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
    
    
    local text_y = p.y + (h - imgui.GetFontSize()) * 0.5
    if font_fa then imgui.PushFont(font_fa) end
    draw_list:AddText(imgui.ImVec2(p.x + S(15), text_y), 
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.4, 1.0, 0.6, 1.0)), 
        fa('shop'))
    if font_fa then imgui.PopFont() end
    
    draw_list:AddText(imgui.ImVec2(p.x + S(40), text_y), 
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 1.0)), 
        u8"ПРОСМОТР ТОВАРОВ")
    
    
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x + w - S(50), text_y - S(15)))
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.4, 1.0, 0.6, 0.2))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.4, 1.0, 0.6, 0.4))
    
    if font_fa then imgui.PushFont(font_fa) end
    if imgui.Button(fa('copy') .. "##copy_remote", imgui.ImVec2(S(45), S(45))) then
        copyRemoteShopConfig()
    end
    if imgui.IsItemHovered() then imgui.SetTooltip(u8"Скопировать товары в конфиг") end
    if font_fa then imgui.PopFont() end
    
    imgui.PopStyleColor(3)
    
    
    imgui.SetCursorScreenPos(p)
    if imgui.InvisibleButton("##drag_remote", imgui.ImVec2(w - S(100), h)) then end
    
    
    if imgui.IsItemActive() and imgui.IsMouseDragging(0) then
        local delta = imgui.GetMouseDragDelta(0)
        local wp = imgui.GetWindowPos()
        imgui.SetWindowPosVec2(imgui.ImVec2(wp.x + delta.x, wp.y + delta.y))
        imgui.ResetMouseDragDelta(0)
    end
    
    
    imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + h))
end

function parseShopPrice(price_text)
    if not price_text or price_text == "" then return 0 end
    
    local text = tostring(price_text):gsub(" р.", ""):gsub(" р", ""):gsub("^%s+", ""):gsub("%s+$", "")
    local num_str = text:match("([0-9.]+)")
    if not num_str then return 0 end
    
    local num = tonumber(num_str) or 0
    
    if text:find("ккк") then
        num = num * 1000000000
    elseif text:find("кк") then
        num = num * 1000000
    elseif text:find("к") then
        num = num * 1000
    end
    
    return math.floor(num)
end

function saveBuyConfigs()
    -- Алиас для сохранения активного конфига (для совместимости)
    saveBuyConfigState()
end

function createBuyConfig(name)
    local new_config = { name = name or "Новый конфиг", items = {} }
    saveSingleConfig(PATHS.PROFILES_BUY, new_config)
    Data.buy_configs = loadConfigsFromDir(PATHS.PROFILES_BUY)
    return #Data.buy_configs
end

function deleteBuyConfig(index)
    if index < 1 or index > #Data.buy_configs then return end
    
    local config = Data.buy_configs[index]
    deleteConfigFile(PATHS.PROFILES_BUY, config._filename)
    
    table.remove(Data.buy_configs, index)
    
    if Data.active_buy_config >= index then
        Data.active_buy_config = math.max(1, Data.active_buy_config - 1)
    end
    
    if #Data.buy_configs == 0 then
        createBuyConfig("Основная")
        Data.active_buy_config = 1
    end
    
    addToastNotification("Конфиг удален", "success", 2.0)
end

function renameBuyConfig(index, new_name)
    if index < 1 or index > #Data.buy_configs then return end
    if new_name and new_name ~= "" then
        local config = Data.buy_configs[index]
        local old_filename = config._filename
        
        config.name = new_name
        config._filename = nil -- сброс, чтобы сгенерировалось новое имя файла
        
        saveSingleConfig(PATHS.PROFILES_BUY, config)
        
        -- Удаляем старый файл, если имя изменилось
        if old_filename and old_filename ~= config._filename then
            deleteConfigFile(PATHS.PROFILES_BUY, old_filename)
        end
        
        addToastNotification("Конфиг переименован", "success", 2.0)
    end
end

function selectBuyConfig(index)
    if index < 1 or index > #Data.buy_configs then return end
    Data.active_buy_config = index
    Data.buy_list = {}
    for _, item in ipairs(Data.buy_configs[index].items) do
        table.insert(Data.buy_list, item)
    end
    calculateBuyTotal()
    saveListsConfig() -- Сохраняем, что мы переключились на этот конфиг
    addToastNotification("Выбран конфиг: " .. Data.buy_configs[index].name, "info", 2.0)
end

function copyRemoteShopConfig()
    if #Data.remote_shop_items == 0 then
        addToastNotification("Список товаров пуст", "warning", 2.0)
        return
    end
    
    App.show_config_selector = true
    App.config_copy_pending = true
end

function performRemoteShopCopy(config_idx)
    if #Data.remote_shop_items == 0 then
        addToastNotification("Список товаров пуст", "warning", 2.0)
        return
    end
    
    if config_idx < 1 or config_idx > #Data.buy_configs then return end
    
    local target_config = Data.buy_configs[config_idx]
    local added_count = 0
    
    -- Создаем карту существующих предметов в конфиге для быстрого поиска дублей
    -- Ключ: Имя предмета (в нижнем регистре для надежности)
    local existing_items_map = {}
    for _, item in ipairs(target_config.items) do
        if item.name then
            existing_items_map[cleanItemNameKey(item.name):lower()] = true
        end
    end

    -- Подготовка базы индексов (из сканирования И из файла базы данных)
    local valid_indexes = {}
    
    -- 1. Берем из текущего сканирования (самое точное)
    if Data.buyable_items and #Data.buyable_items > 0 then
        for _, b_item in ipairs(Data.buyable_items) do
            if b_item.name then
                valid_indexes[cleanItemNameKey(b_item.name):lower()] = b_item.index
            end
        end
    end
    
    -- 2. Дополняем из базы данных (если не сканировали, но предмет есть в items_db)
    if Data.item_names_reversed then
        for name, id in pairs(Data.item_names_reversed) do
            local clean_k = name:lower()
            if not valid_indexes[clean_k] then
                valid_indexes[clean_k] = id
            end
        end
    end
    
    for _, remote_item in ipairs(Data.remote_shop_items) do
        local clean_name = enhancedCleanItemName(remote_item.name)
        local lower_name = clean_name:lower()
        
        -- Если такого предмета еще нет в конфиге
        if not existing_items_map[lower_name] then
            
            local parsed_price = parseShopPrice(remote_item.price_text)
            
            -- Пытаемся найти правильный ID для скупки
            local correct_index = -1
            if valid_indexes[lower_name] then
                correct_index = valid_indexes[lower_name]
            end

            -- Логика добавления
            local is_acc = isAccessory(clean_name)
            
            -- Если аксессуар - всегда ставим цвет 0 (стандарт) и amount = 0
            -- Если предмет - берем количество из лавки (или 1)
            local amount = is_acc and 0 or (remote_item.amount or 1)
            
            table.insert(target_config.items, {
                name = clean_name,
                price = parsed_price,
                amount = amount,
                active = true,
                model_id = remote_item.model_id or -1,
                index = correct_index -- Важно для скупки!
            })
            
            -- Помечаем как добавленный, чтобы не добавить дубликат (например, другой цвет того же акса)
            existing_items_map[lower_name] = true
            added_count = added_count + 1
        end
    end
    
    if added_count > 0 then
        saveBuyConfigs()
        addToastNotification(string.format("Добавлено %d товаров в конфиг", added_count), "success", 3.0)
        
        -- Подсказка для новичков, если ID не нашлись
        local missing_ids = false
        for _, item in ipairs(target_config.items) do
            if item.index == -1 then missing_ids = true break end
        end
        
        if missing_ids then
             addToastNotification("Внимание: Не у всех товаров найден ID!", "warning", 5.0)
             addToastNotification("Рекомендуется просканировать базу в 'Скупке'", "info", 5.0)
        end
    else
        addToastNotification("Новых товаров не найдено (дубликаты)", "info", 2.0)
    end
end

function renderRemoteShopWindow()
    local sw, sh = getScreenResolution()
    local w, h = 350, 500
    
    imgui.SetNextWindowPos(imgui.ImVec2(20, (sh - h) / 2), imgui.Cond.Appearing)
    imgui.SetNextWindowSize(imgui.ImVec2(w, h), imgui.Cond.FirstUseEver)
    
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 10)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.08, 0.09, 0.11, 0.98))
    
    if imgui.Begin("##RemoteShopViewer", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize) then
        local win_w = imgui.GetWindowWidth()
        
        imgui.BeginChild("RemoteHeader", imgui.ImVec2(win_w, S(50)), false, imgui.WindowFlags.NoScrollbar)
            renderRemoteShopHeader(win_w, S(50))
        imgui.EndChild()
        
        imgui.SetCursorPos(imgui.ImVec2(S(10), S(60)))
        renderAnimatedSearchBar(Buffers.remote_shop_search, "Поиск товара...", win_w - S(20))
        
        imgui.SetCursorPosY(S(110))
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(10), S(10)))
        imgui.BeginChild("RemoteItems", imgui.ImVec2(0, 0), true)
            
            local search_raw = ffi.string(Buffers.remote_shop_search)
            local filtered = {}
            
            if search_raw == "" then
                filtered = Data.remote_shop_items
            else
                local query = u8:decode(search_raw)
                local results_with_score = {}
                for _, item in ipairs(Data.remote_shop_items) do
                    local clean_name = enhancedCleanItemName(item.name)
                    local score = SmartSearch.getMatchScore(query, clean_name)
                    if score > 0 then
                        table.insert(results_with_score, {data = item, score = score})
                    end
                end
                table.sort(results_with_score, function(a, b) return a.score > b.score end)
                for _, entry in ipairs(results_with_score) do table.insert(filtered, entry.data) end
            end
            
            if #filtered == 0 then
                imgui.Spacing()
                imgui.Indent(S(10))
                local msg = (search_raw ~= "") and u8("Ничего не найдено") or u8("Загрузка или пусто...")
                imgui.TextColored(CURRENT_THEME.text_hint, msg)
                imgui.Unindent(S(10))
            else
                local draw_list = imgui.GetWindowDrawList()
                local item_h = S(55) 
                
                for i, item in ipairs(filtered) do
                    local p = imgui.GetCursorScreenPos()
                    local avail_w = imgui.GetContentRegionAvail().x
                    
                    local numeric_price = parseShopPrice(item.price_text)
                    local avg_price = getAveragePriceForItem({name = item.name})
                    
                    local is_good_deal = (numeric_price > 0 and avg_price and avg_price > 0 and numeric_price < avg_price)
                    
                    local bg_col_u32
                    local hover_col_u32
                    
                    if is_good_deal then
                        bg_col_u32 = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.15, 0.35, 0.15, 0.7))
                        hover_col_u32 = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.20, 0.45, 0.20, 0.9))
                    else
                        bg_col_u32 = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.12, 0.13, 0.16, 0.5))
                        hover_col_u32 = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.15, 0.16, 0.20, 0.8))
                    end
                    
                    imgui.PushIDInt(item.slot or i)
                    if imgui.InvisibleButton("##ritem"..i, imgui.ImVec2(avail_w, item_h)) then
                        if item.slot then
                            local payload = string.format('clickOnBlock|{"slot": %d, "type": 9}', item.slot)
                            sendCEF(payload)
                        end
                    end
                    local is_hovered = imgui.IsItemHovered()
                    if is_hovered then
                         local tooltip = u8("Нажмите, чтобы показать в лавке")
                         if avg_price then
                            tooltip = tooltip .. u8(string.format("\nРазница с рынком: %s$", formatMoney(avg_price - numeric_price)))
                         end
                        imgui.SetTooltip(tooltip)
                    end
                    imgui.PopID()
                    
                    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + avail_w, p.y + item_h), is_hovered and hover_col_u32 or bg_col_u32, S(6))
                    if is_good_deal then
                        draw_list:AddRect(p, imgui.ImVec2(p.x + avail_w, p.y + item_h), 0xFF66FF66, S(6), 15, S(1))
                    end

                    -- [FIX 3] Безопасное отображение имени
                    local safe_name = item.name or "???"
                    draw_list:AddText(imgui.ImVec2(p.x + S(10), p.y + S(5)), 0xFFFFFFFF, u8(safe_name))
                    
                    local price_text = u8(item.price_text or "0")
                    draw_list:AddText(imgui.ImVec2(p.x + S(10), p.y + S(23)), is_good_deal and 0xFF66FF66 or 0xFF6666FF, price_text)
                    
                    if avg_price and avg_price > 0 then
                        local avg_text = u8("(Ср: " .. formatMoney(avg_price) .. ")")
                        local price_width = imgui.CalcTextSize(price_text).x
                        draw_list:AddText(imgui.ImVec2(p.x + S(15) + price_width, p.y + S(23)), 0xFFAAAAAA, avg_text)
                    end
                    
                    local amount_text = u8("x" .. (item.amount or 1))
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

function renderMiniProcessWindow(title, status_text, progress_text, stop_callback)
    local sw, sh = getScreenResolution()
    local w = 300 
    
    
    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    
    
    
    imgui.SetNextWindowSizeConstraints(imgui.ImVec2(w, 100), imgui.ImVec2(w, sh * 0.5))
    
    
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(15, 15))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 10)
    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.07, 0.08, 0.10, 0.95))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(0.40, 0.25, 0.95, 0.5))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, S(1))

    
    if imgui.Begin("##MiniProcess", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove + imgui.WindowFlags.AlwaysAutoResize) then
        
        
        
        imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.40, 0.25, 0.95, 1.0))
        
        if imgui.Spinner and pcall(function() imgui.Spinner("##spin", S(7), S(2)) end) then
             
        else
             
             if font_fa then imgui.PushFont(font_fa) end
             imgui.Text(fa('spinner'))
             if font_fa then imgui.PopFont() end
        end
        imgui.PopStyleColor()
        
        imgui.SameLine()
        imgui.TextColored(CURRENT_THEME.text_primary, u8(title))
        
        imgui.Separator()
        imgui.Spacing()
        
        
        
        imgui.TextWrapped(u8(status_text))
        
        if progress_text then
            imgui.Spacing()
            imgui.TextDisabled(u8(progress_text))
        end
        
        
        imgui.Spacing()
        imgui.Spacing()
        
        
        
        local btn_h = S(30)
        
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.8, 0.2, 0.2, 0.8))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.9, 0.3, 0.3, 1.0))
        
        
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
    
    
    local clicked = imgui.InvisibleButton("##toggle", imgui.ImVec2(width, height))
    if clicked then
        bool_ptr[0] = not bool_ptr[0]
        saveSettings() 
    end
    
    
    local id = tostring(bool_ptr) 
    if not toggle_anims[id] then toggle_anims[id] = 0.0 end
    
    local target = bool_ptr[0] and 1.0 or 0.0
    local speed = imgui.GetIO().DeltaTime * 10.0
    toggle_anims[id] = toggle_anims[id] + (target - toggle_anims[id]) * speed
    
    
    local t = toggle_anims[id]
    
    
    local col_bg_inactive = CURRENT_THEME.bg_secondary
    local col_bg_active = CURRENT_THEME.accent_primary
    
    local r = col_bg_inactive.x + (col_bg_active.x - col_bg_inactive.x) * t
    local g = col_bg_inactive.y + (col_bg_active.y - col_bg_inactive.y) * t
    local b = col_bg_inactive.z + (col_bg_active.z - col_bg_inactive.z) * t
    local col_bg = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(r, g, b, 1.0))
    
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + width, p.y + height), col_bg, radius)
    
    
    local circle_pad = S(2)
    local circle_radius = radius - circle_pad
    local circle_x_start = p.x + radius
    local circle_x_end = p.x + width - radius
    local circle_x = circle_x_start + (circle_x_end - circle_x_start) * t
    
    draw_list:AddCircleFilled(imgui.ImVec2(circle_x, p.y + radius), circle_radius, 0xFFFFFFFF)
    
    imgui.EndGroup()
    
    
    imgui.SameLine(0, S(15))
    imgui.AlignTextToFramePadding()
    imgui.TextColored(CURRENT_THEME.text_primary, u8(label))
    
    imgui.PopID() 
    return clicked
end

-- [[ ЗАМЕНИТЬ ЭТУ ФУНКЦИЮ ПОЛНОСТЬЮ ]]
function api_DownloadAveragePrices()
    local ip, port = sampGetCurrentServerAddress()
    local server_id = normalizeServerId(ip .. ":" .. port)
    
    addToastNotification("Обновление рыночных цен...", "info", 2.0)
    print("[RMarket] Start download prices for: " .. tostring(server_id))
    
    local url = MarketConfig.HOST .. "/api/get_prices.php?server=" .. url_encode(server_id)
    
    -- Добавляем verify=false, чтобы избежать ошибок SSL
    -- Добавляем timeout=60, чтобы запрос не висел вечно
    asyncHttpRequest("GET", url, { verify = false, timeout = 60 }, 
        function(response)
            -- [DEBUG] Выводим статус в консоль
            print("[RMarket] Response Code: " .. tostring(response.status_code))
            
            if response.status_code == 200 then
				if not response.text or #response.text == 0 or response.text:sub(1,1) ~= "{" then
					print("[RMarket] Error: Invalid JSON response (HTML or Empty)")
					addToastNotification("Ошибка данных сервера (Неверный формат)", "error")
					return
				end

				local ok, data = pcall(json.decode, response.text)
				if not ok or type(data) ~= "table" then
					print("[RMarket] JSON Decode Error")
					return 
				end
                
                if data then
                    -- Проверяем, есть ли данные внутри
                    if next(data) == nil then
                        print("[RMarket] Database is empty for this server")
                        addToastNotification("База цен пуста для этого сервера", "warning", 3.0)
                        return
                    end

                    local count = 0
                    local new_prices = {}
                    
                    for name_utf8, info in pairs(data) do
                        local name_cp1251 = name_utf8
                        if u8 then
                             local s, r = pcall(u8.decode, u8, name_utf8)
                             if s then name_cp1251 = r end
                        else
                             -- Если u8 недоступен, оставляем как есть
                             print("[RMarket] Warning: u8 lib missing") 
                        end
                        
                        if info then
                            -- Сохраняем раздельные цены
                            new_prices[name_cp1251] = {
                                sell = tonumber(info.sell) or 0,
                                buy = tonumber(info.buy) or 0,
                                price = tonumber(info.price) or 0
                            }
                            count = count + 1
                        end
                    end
                    
                    print("[RMarket] Parsed items: " .. count)

                    if count > 0 then
                        Data.average_prices = new_prices
                        saveJsonFile(PATHS.CACHE .. 'average_prices.json', Data.average_prices)
                        addToastNotification("Цены обновлены! Товаров: " .. count, "success", 4.0)
                        avg_price_lookup_cache = {} -- Сброс кэша поиска
                    else
                        addToastNotification("Данные получены, но список товаров пуст", "warning")
                    end
                else
                    print("[RMarket] Data is nil after decode")
                    addToastNotification("Ошибка структуры данных", "error")
                end
            else
                print("[RMarket] HTTP Error. Body: " .. tostring(response.text))
                addToastNotification("Ошибка сервера цен (" .. response.status_code .. ")", "error")
            end
        end,
        function(err)
            print("[RMarket] Connection Failed: " .. tostring(err))
            addToastNotification("Ошибка соединения: " .. tostring(err), "error")
        end
    )
end

function api_ShareConfig(config_index)
    local config = Data.buy_configs[config_index]
    if not config or #config.items == 0 then
        addToastNotification("Пустой конфиг нельзя отправить", "warning")
        return
    end

    local payload = {
        name = u8:encode(config.name), 
        items = {}
    }

    for _, item in ipairs(config.items) do
        table.insert(payload.items, {
            name = u8:encode(item.name),
            price = item.price,
            amount = item.amount,
            model_id = item.model_id,
            active = item.active
        })
    end

    addToastNotification("Загрузка конфига на сервер...", "info")

    asyncHttpRequest("POST", MarketConfig.HOST .. "/api/shareConfig", 
        {
            headers = {["Content-Type"] = "application/json"},
            data = json.encode(payload)
        },
        function(response)
            if response.status_code == 200 then
                local ok, res = pcall(json.decode, response.text)
                if ok and res.status == 'success' and res.code then
                    ShareState.generated_code = res.code
                    ShareState.config_name = config.name
                    ShareState.modal_active = true
                    setClipboardText(res.code)
                    addToastNotification("Код скопирован в буфер!", "success")
                end
            else
                addToastNotification("Ошибка сервера: " .. response.status_code, "error")
            end
        end,
        function(err)
            addToastNotification("Ошибка соединения", "error")
        end
    )
end

function findRealIndexByName(name)
    if not name then return nil end
    local clean_target = cleanItemNameKey(name):lower()
    
    -- 1. Ищем в отсканированных товарах (самое точное)
    for _, item in ipairs(Data.buyable_items) do
        if item.name and cleanItemNameKey(item.name):lower() == clean_target then
            return item.index
        end
    end
    
    -- 2. Ищем в базе имен (если сканирование не проводилось, но база есть)
    if Data.item_names_reversed and Data.item_names_reversed[clean_target] then
        return Data.item_names_reversed[clean_target]
    end
    
    return nil
end

function api_ImportConfig()
    local code = ffi.string(Buffers.import_code)
    if code == "" then
        addToastNotification("Введите код конфига", "warning")
        return
    end

    addToastNotification("Поиск конфига...", "info")

    asyncHttpRequest("GET", MarketConfig.HOST .. "/api/getConfig/" .. code, {}, 
        function(response)
            if response.status_code == 200 then
                local ok, res = pcall(json.decode, response.text)
                if ok and res.status == 'found' and res.config then
                    local imported = res.config
                    
                    local new_items = {}
                    for _, item in ipairs(imported.items) do
                        local item_name = u8:decode(item.name)
                        
                        local resolved_index = -1
                        local resolved_model = tonumber(item.model_id) or -1

                        local real_idx = findRealIndexByName(item_name)
                        if real_idx then
                            resolved_index = real_idx
                            if resolved_model < 10 then resolved_model = real_idx end
                        end

                        if resolved_model < 10 or resolved_index == -1 then
                            local clean_key = cleanItemNameKey(item_name)
                            if Data.item_names_reversed[clean_key] then
                                local db_id = Data.item_names_reversed[clean_key]
                                resolved_model = db_id
                                if resolved_index == -1 then resolved_index = db_id end
                            end
                        end

                        table.insert(new_items, {
                            name = item_name,
                            price = tonumber(item.price),
                            amount = tonumber(item.amount),
                            model_id = resolved_model,
                            active = item.active,
                            index = resolved_index 
                        })
                    end

                    local new_name = u8:decode(imported.name or "Imported") .. " (Import)"
                    table.insert(Data.buy_configs, {
                        name = new_name,
                        items = new_items
                    })
                    
                    saveBuyConfigs()
                    addToastNotification("Конфиг успешно импортирован! (" .. #new_items .. " товаров)", "success")
                    imgui.StrCopy(Buffers.import_code, "") 
                else
                    addToastNotification("Некорректные данные сервера", "error")
                end
            elseif response.status_code == 404 then
                addToastNotification("Конфиг с таким кодом не найден", "error")
            else
                addToastNotification("Ошибка сервера", "error")
            end
        end,
        function(err)
            addToastNotification("Ошибка соединения", "error")
        end
    )
end

function renderShareResultModal()
    if not ShareState.modal_active then return end

    local sw, sh = getScreenResolution()
    local w, h = S(350), S(220)
    
    imgui.SetNextWindowPos(imgui.ImVec2(sw/2, sh/2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(w, h), imgui.Cond.Always)
    
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(20), S(20)))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 10)
    
    if imgui.Begin("##ShareResult", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize) then
        
        local icon_sz = S(40)
        local center_x = w / 2
        
        centerText(u8"Конфиг опубликован!")
        imgui.Dummy(imgui.ImVec2(0, S(10)))
        
        local code = ShareState.generated_code or "ERROR"
        
        imgui.PushStyleColor(imgui.Col.Button, CURRENT_THEME.bg_tertiary)
        imgui.PushStyleColor(imgui.Col.ButtonHovered, CURRENT_THEME.bg_tertiary)
        imgui.PushStyleColor(imgui.Col.ButtonActive, CURRENT_THEME.bg_tertiary)
        imgui.Button(code, imgui.ImVec2(w - S(40), S(40)))
        imgui.PopStyleColor(3)
        
        if imgui.IsItemHovered() then
            imgui.SetTooltip(u8"Нажмите, чтобы скопировать снова")
        end
        if imgui.IsItemClicked() then
            setClipboardText(code)
            addToastNotification("Скопировано!", "success")
        end

        imgui.Dummy(imgui.ImVec2(0, S(20)))
        
        if imgui.Button(u8"Закрыть", imgui.ImVec2(-1, S(35))) then
            ShareState.modal_active = false
        end
    end
    imgui.End()
    imgui.PopStyleVar(2)
end

function saveSellConfigs()
    saveSellConfigState()
end

function createSellConfig(name)
    local new_config = { name = name or "Новый конфиг", items = {} }
    saveSingleConfig(PATHS.PROFILES_SELL, new_config)
    Data.sell_configs = loadConfigsFromDir(PATHS.PROFILES_SELL)
    return #Data.sell_configs
end

function deleteSellConfig(index)
    if index < 1 or index > #Data.sell_configs then return end
    local config = Data.sell_configs[index]
    deleteConfigFile(PATHS.PROFILES_SELL, config._filename)
    table.remove(Data.sell_configs, index)
    
    if Data.active_sell_config >= index then
        Data.active_sell_config = math.max(1, Data.active_sell_config - 1)
    end
    
    if #Data.sell_configs == 0 then
        createSellConfig("Основная")
        Data.active_sell_config = 1
    end
    addToastNotification("Конфиг удален", "success", 2.0)
end

function renameSellConfig(index, new_name)
    if index < 1 or index > #Data.sell_configs then return end
    if new_name and new_name ~= "" then
        local config = Data.sell_configs[index]
        local old_filename = config._filename
        config.name = new_name
        config._filename = nil
        saveSingleConfig(PATHS.PROFILES_SELL, config)
        if old_filename and old_filename ~= config._filename then
            deleteConfigFile(PATHS.PROFILES_SELL, old_filename)
        end
        addToastNotification("Конфиг переименован", "success")
    end
end

function selectSellConfig(index)
    if index < 1 or index > #Data.sell_configs then return end
    Data.active_sell_config = index
    Data.sell_list = {}
    for _, item in ipairs(Data.sell_configs[index].items) do
        table.insert(Data.sell_list, item)
    end
    saveListsConfig()
    addToastNotification("Загружен конфиг: " .. Data.sell_configs[index].name, "success")
end

function saveSellConfigState()
    -- [FIX] Защита: Если скрипт не прогрузился, запрещаем перезапись конфига
    if not App.script_loaded then return end

    -- Синхронизируем текущий список с активным профилем и сохраняем профиль на диск
    if Data.active_sell_config and Data.sell_configs[Data.active_sell_config] then
        Data.sell_configs[Data.active_sell_config].items = {}
        for _, item in ipairs(Data.sell_list) do
            table.insert(Data.sell_configs[Data.active_sell_config].items, item)
        end
        saveSingleConfig(PATHS.PROFILES_SELL, Data.sell_configs[Data.active_sell_config])
    end
end

function renameSellConfig(index, new_name)
    if index < 1 or index > #Data.sell_configs then return end
    if new_name and new_name ~= "" then
        Data.sell_configs[index].name = new_name
        saveSellConfigs()
        addToastNotification("Конфиг переименован", "success")
    end
end

function renderSellConfigManager()
    local sw, sh = getScreenResolution()
    local w, h = S(450), S(600)

    if not App.sell_config_sort then 
        App.sell_config_sort = { mode = 0, asc = true } 
    end

    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(w, h), imgui.Cond.Always)

    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleColor(imgui.Col.WindowBg, CURRENT_THEME.bg_main)
    imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_secondary)

    if imgui.Begin("SellConfigManager", nil,
        imgui.WindowFlags.NoTitleBar +
        imgui.WindowFlags.NoCollapse +
        imgui.WindowFlags.NoResize
    ) then

        local draw_list = imgui.GetWindowDrawList()
        local p = imgui.GetCursorScreenPos()
        local win_w = imgui.GetWindowWidth()

        local header_h = S(50)
        local footer_h = S(120)
        local sort_bar_h = S(45) 
        local content_h = h - header_h - footer_h - sort_bar_h

        draw_list:AddRectFilled(p, imgui.ImVec2(p.x + win_w, p.y + header_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary), S(10), 5)
        draw_list:AddLine(imgui.ImVec2(p.x, p.y + header_h), imgui.ImVec2(p.x + win_w, p.y + header_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.border_light), 1)

        imgui.SetCursorPos(imgui.ImVec2(S(15), (header_h - S(20)) / 2))
        if font_fa then imgui.PushFont(font_fa) imgui.TextColored(CURRENT_THEME.accent_warning, fa('sliders')) imgui.PopFont() imgui.SameLine() end
        imgui.SetCursorPosY((header_h - imgui.GetFontSize()) / 2)
        imgui.TextColored(CURRENT_THEME.text_primary, u8"Управление конфигами (Продажа)")

        local btn_size = S(30)
        local btn_x = win_w - btn_size - S(10)
        imgui.SetCursorPos(imgui.ImVec2(btn_x, (header_h - btn_size) / 2))
        if imgui.InvisibleButton("##close_sell_cfg_mgr", imgui.ImVec2(btn_size, btn_size)) then
            App.show_sell_config_manager = false
            App.rename_sell_config_idx = nil
        end

        local close_center = imgui.ImVec2(p.x + btn_x + btn_size / 2, p.y + (header_h - btn_size) / 2 + btn_size / 2)
        if imgui.IsItemHovered() then
            draw_list:AddCircleFilled(close_center, btn_size / 2, imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1,0.3,0.3,0.2)))
        end

        if font_fa then
            imgui.PushFont(font_fa)
            local col = imgui.IsItemHovered() and CURRENT_THEME.accent_danger or CURRENT_THEME.text_secondary
            local sz = imgui.CalcTextSize(fa('xmark'))
            draw_list:AddText(imgui.ImVec2(close_center.x - sz.x/2, close_center.y - sz.y/2), imgui.ColorConvertFloat4ToU32(col), fa('xmark'))
            imgui.PopFont()
        end

        imgui.SetCursorPos(imgui.ImVec2(0, header_h))
        local margin_x = S(15)
        local sort_area_w = win_w - margin_x * 2
        local gap = S(6)
        local btn_w = (sort_area_w - gap*2) / 3
        local btn_h = S(30)
        
        local function renderCustomSortButton(label, icon, mode_idx)
            local is_active = (App.sell_config_sort.mode == mode_idx)
            local pos = imgui.GetCursorScreenPos()
            
            if imgui.InvisibleButton("##sort_sell_"..mode_idx, imgui.ImVec2(btn_w, btn_h)) then
                if is_active then
                    App.sell_config_sort.asc = not App.sell_config_sort.asc
                else
                    App.sell_config_sort.mode = mode_idx
                    App.sell_config_sort.asc = true
                end
            end
            
            local is_hovered = imgui.IsItemHovered()
            
            local bg_col
            local text_col
            local border_col = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.border_light)
            
            if is_active then
                bg_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(CURRENT_THEME.accent_primary.x, CURRENT_THEME.accent_primary.y, CURRENT_THEME.accent_primary.z, 0.2))
                text_col = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary)
                border_col = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary)
            else
                bg_col = imgui.ColorConvertFloat4ToU32(is_hovered and CURRENT_THEME.bg_tertiary or CURRENT_THEME.bg_secondary)
                text_col = imgui.ColorConvertFloat4ToU32(is_hovered and CURRENT_THEME.text_primary or CURRENT_THEME.text_secondary)
            end
            
            draw_list:AddRectFilled(pos, imgui.ImVec2(pos.x + btn_w, pos.y + btn_h), bg_col, S(6))
            draw_list:AddRect(pos, imgui.ImVec2(pos.x + btn_w, pos.y + btn_h), border_col, S(6))
            
            local label_sz = imgui.CalcTextSize(label)
            local icon_w = 0
            local sort_icon = ""
            if is_active and font_fa then
                sort_icon = App.sell_config_sort.asc and fa('arrow_down_a_z') or fa('arrow_up_a_z') 
                if mode_idx > 0 then sort_icon = App.sell_config_sort.asc and fa('arrow_down_1_9') or fa('arrow_up_1_9') end
                imgui.PushFont(font_fa)
                icon_w = imgui.CalcTextSize(sort_icon).x + S(6)
                imgui.PopFont()
            elseif icon and font_fa then
                 sort_icon = icon
                 imgui.PushFont(font_fa)
                 icon_w = imgui.CalcTextSize(sort_icon).x + S(6)
                 imgui.PopFont()
            end
            
            local content_w = label_sz.x + icon_w
            local start_x = pos.x + (btn_w - content_w) / 2
            local center_y = pos.y + btn_h / 2
            
            if sort_icon ~= "" and font_fa then
                imgui.PushFont(font_fa)
                draw_list:AddText(imgui.ImVec2(start_x, center_y - imgui.CalcTextSize(sort_icon).y/2), text_col, sort_icon)
                imgui.PopFont()
            end
            
            draw_list:AddText(imgui.ImVec2(start_x + icon_w, center_y - label_sz.y/2), text_col, label)
        end

        imgui.SetCursorPos(imgui.ImVec2(margin_x, header_h + (sort_bar_h - btn_h)/2))
        
        renderCustomSortButton(u8"Имя", fa('font'), 0)
        imgui.SameLine(0, gap)
        renderCustomSortButton(u8"Кол-во", fa('list_ol'), 1)
        imgui.SameLine(0, gap)
        renderCustomSortButton(u8"Цена", fa('coins'), 2)
        
        imgui.SetCursorPos(imgui.ImVec2(0, header_h + sort_bar_h))
        imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, S(6)))
        imgui.BeginChild("##SellConfigList", imgui.ImVec2(win_w, content_h), false)
        imgui.Dummy(imgui.ImVec2(0, S(6)))

        local item_w = win_w - margin_x*2 - S(5)
        local item_h = S(50)

        local display_list = {}
        for i, v in ipairs(Data.sell_configs) do
            local total_price = 0
            if App.sell_config_sort.mode == 2 then
                for _, item in ipairs(v.items or {}) do
                    total_price = total_price + (tonumber(item.price) or 0) * (tonumber(item.amount) or 1)
                end
            end
            table.insert(display_list, { 
                real_idx = i, 
                data = v, 
                count = #(v.items or {}),
                price = total_price,
                name_l = v.name:lower() 
            })
        end

        table.sort(display_list, function(a, b)
            local val_a, val_b
            
            if App.sell_config_sort.mode == 0 then 
                val_a, val_b = a.name_l, b.name_l
            elseif App.sell_config_sort.mode == 1 then 
                val_a, val_b = a.count, b.count
            elseif App.sell_config_sort.mode == 2 then 
                val_a, val_b = a.price, b.price
            end
            
            if val_a == val_b then
                return a.real_idx < b.real_idx
            end
            
            if App.sell_config_sort.asc then
                return val_a < val_b
            else
                return val_a > val_b
            end
        end)

        for _, entry in ipairs(display_list) do
            local i = entry.real_idx
            local config = entry.data
            local is_active = (Data.active_sell_config == i)
            local is_renaming = (App.rename_sell_config_idx == i)

            imgui.SetCursorPosX(margin_x)
            local item_p = imgui.GetCursorScreenPos()
            local dl = imgui.GetWindowDrawList()

            local bg = is_active and CURRENT_THEME.bg_tertiary or CURRENT_THEME.bg_secondary
            dl:AddRectFilled(item_p, imgui.ImVec2(item_p.x + item_w, item_p.y + item_h), imgui.ColorConvertFloat4ToU32(bg), S(8))
            if is_active then dl:AddRectFilled(item_p, imgui.ImVec2(item_p.x + S(4), item_p.y + item_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_success), S(8), 5) end

            imgui.BeginGroup()

            if is_renaming then
                local btn_sz = S(28)
                local input_w = item_w - btn_sz*2 - S(25)
                imgui.SetCursorPosY(imgui.GetCursorPosY() + (item_h - S(32))/2)
                
                renderModernInput("##ren_sell_"..i, Buffers.new_sell_config_name, input_w, "Имя...")
                
                imgui.SameLine()
                local save_pos = imgui.GetCursorScreenPos()
                if imgui.InvisibleButton("##sv_sell_"..i, imgui.ImVec2(btn_sz, btn_sz)) then
                    local name = u8:decode(ffi.string(Buffers.new_sell_config_name))
                    if name ~= "" then renameSellConfig(i,name) end
                    App.rename_sell_config_idx = nil
                end
                if font_fa then
                    imgui.PushFont(font_fa)
                    local col = imgui.IsItemHovered() and CURRENT_THEME.accent_success or CURRENT_THEME.text_hint
                    dl:AddText(imgui.ImVec2(save_pos.x + S(6), save_pos.y + S(6)), imgui.ColorConvertFloat4ToU32(col), fa('check'))
                    imgui.PopFont()
                end

                imgui.SameLine()
                local cancel_pos = imgui.GetCursorScreenPos()
                if imgui.InvisibleButton("##cn_sell_"..i, imgui.ImVec2(btn_sz, btn_sz)) then App.rename_sell_config_idx = nil end
                if font_fa then
                    imgui.PushFont(font_fa)
                    local col = imgui.IsItemHovered() and CURRENT_THEME.accent_danger or CURRENT_THEME.text_hint
                    dl:AddText(imgui.ImVec2(cancel_pos.x + S(6), cancel_pos.y + S(6)), imgui.ColorConvertFloat4ToU32(col), fa('xmark'))
                    imgui.PopFont()
                end
            else
                local buttons_zone = S(90)
                if imgui.InvisibleButton("##sel_sell_"..i, imgui.ImVec2(item_w - buttons_zone, item_h)) then selectSellConfig(i) end

                local cy = item_p.y + item_h/2
                local icon_x = item_p.x + S(20)
                if font_fa then
                    imgui.PushFont(font_fa)
                    dl:AddText(imgui.ImVec2(icon_x, cy - S(7)), imgui.ColorConvertFloat4ToU32(is_active and CURRENT_THEME.accent_primary or CURRENT_THEME.text_secondary), is_active and fa('folder_open') or fa('folder'))
                    imgui.PopFont()
                end

                local txt_x = icon_x + S(30)
                dl:AddText(imgui.ImVec2(txt_x, cy - S(10)), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary), u8(config.name))
                
                local info_text = tostring(#(config.items or {}))..u8(" шт.")
                if entry.price > 0 then
                    info_text = info_text .. " | " .. formatMoney(entry.price) .. " $"
                end
                
                dl:AddText(imgui.ImVec2(txt_x, cy + S(5)), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint), info_text)

                local btn_sz = S(28)
                local right = item_p.x + item_w - S(10)
                imgui.SetCursorScreenPos(imgui.ImVec2(right - btn_sz, cy - btn_sz/2))
                if imgui.InvisibleButton("##del_sell_"..i, imgui.ImVec2(btn_sz, btn_sz)) then deleteSellConfig(i) end

                imgui.SetCursorScreenPos(imgui.ImVec2(right - btn_sz*2 - S(5), cy - btn_sz/2))
                if imgui.InvisibleButton("##ren_sell_"..i, imgui.ImVec2(btn_sz, btn_sz)) then
                    App.rename_sell_config_idx = i
                    imgui.StrCopy(Buffers.new_sell_config_name, u8(config.name))
                end

                if font_fa then
                    imgui.PushFont(font_fa)
                    local iy = cy - S(7)
                    dl:AddText(imgui.ImVec2(right - btn_sz + S(6), iy), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint), fa('trash'))
                    dl:AddText(imgui.ImVec2(right - btn_sz*2 - S(5) + S(6), iy), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint), fa('pen'))
                    imgui.PopFont()
                end
            end

            imgui.EndGroup()
        end

        imgui.EndChild()
        imgui.PopStyleVar()

        imgui.SetCursorPos(imgui.ImVec2(0, h - footer_h))
        local fp = imgui.GetCursorScreenPos()
        draw_list:AddRectFilled(fp, imgui.ImVec2(fp.x + win_w, fp.y + footer_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary), S(10), 10)
        draw_list:AddLine(fp, imgui.ImVec2(fp.x + win_w, fp.y), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.border_light), 1)

        imgui.SetCursorPos(imgui.ImVec2(S(15), h - footer_h + S(25)))
        renderModernInput("##new_sell_name", Buffers.new_sell_config_name, win_w - S(140), "Новое название...")
        imgui.SameLine()
        if renderCustomButton(u8"Создать", S(100), S(32), CURRENT_THEME.accent_primary) then
            local name = u8:decode(ffi.string(Buffers.new_sell_config_name))
            if name ~= "" then
                createSellConfig(name)
                imgui.StrCopy(Buffers.new_sell_config_name, "")
            end
        end
    end

    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar()
end

function renderConfigManagerWindow()
    if ShareState.modal_active then renderShareResultModal() end

    local sw, sh = getScreenResolution()
    local w, h = S(450), S(600)
    
    if not App.buy_config_sort then 
        App.buy_config_sort = { mode = 0, asc = true } 
    end

    imgui.SetNextWindowPos(imgui.ImVec2(sw/2, sh/2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5,0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(w,h), imgui.Cond.Always)

    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0,0))
    imgui.PushStyleColor(imgui.Col.WindowBg, CURRENT_THEME.bg_main)
    imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_secondary)

    if imgui.Begin("ConfigManager", nil,
        imgui.WindowFlags.NoTitleBar +
        imgui.WindowFlags.NoCollapse +
        imgui.WindowFlags.NoResize
    ) then
        local draw_list = imgui.GetWindowDrawList()
        local p = imgui.GetCursorScreenPos()
        local win_w = imgui.GetWindowWidth()

        local header_h = S(50)
        local footer_h = S(120)
        local sort_bar_h = S(45)
        local content_h = h - header_h - footer_h - sort_bar_h

        draw_list:AddRectFilled(p, imgui.ImVec2(p.x + win_w, p.y + header_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary), S(10),5)
        draw_list:AddLine(imgui.ImVec2(p.x, p.y + header_h), imgui.ImVec2(p.x + win_w, p.y + header_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.border_light), 1)

        imgui.SetCursorPos(imgui.ImVec2(S(15), (header_h - S(20))/2))
        if font_fa then imgui.PushFont(font_fa) imgui.TextColored(CURRENT_THEME.accent_warning, fa('sliders')) imgui.PopFont() imgui.SameLine() end
        imgui.SetCursorPosY((header_h - imgui.GetFontSize())/2)
        imgui.TextColored(CURRENT_THEME.text_primary, u8"Управление конфигами (Скупка)")

        local btn_size = S(30)
        local btn_x = win_w - btn_size - S(10)
        imgui.SetCursorPos(imgui.ImVec2(btn_x, (header_h - btn_size)/2))
        if imgui.InvisibleButton("##close_cfg_mgr", imgui.ImVec2(btn_size, btn_size)) then
            App.show_config_manager = false
            App.rename_config_idx = nil
        end

        local close_center = imgui.ImVec2(p.x + btn_x + btn_size/2, p.y + (header_h - btn_size)/2 + btn_size/2)
        if imgui.IsItemHovered() then
            draw_list:AddCircleFilled(close_center, btn_size/2, imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1,0.3,0.3,0.2)))
        end
        if font_fa then
            imgui.PushFont(font_fa)
            local col = imgui.IsItemHovered() and CURRENT_THEME.accent_danger or CURRENT_THEME.text_secondary
            local sz = imgui.CalcTextSize(fa('xmark'))
            draw_list:AddText(imgui.ImVec2(close_center.x - sz.x/2, close_center.y - sz.y/2), imgui.ColorConvertFloat4ToU32(col), fa('xmark'))
            imgui.PopFont()
        end

        imgui.SetCursorPos(imgui.ImVec2(0, header_h))
        local margin_x = S(15)
        local sort_area_w = win_w - margin_x * 2
        local gap = S(6)
        local btn_w = (sort_area_w - gap*2) / 3
        local btn_h = S(30)
        
        local function renderCustomSortButton(label, icon, mode_idx)
            local is_active = (App.buy_config_sort.mode == mode_idx)
            local pos = imgui.GetCursorScreenPos()
            
            if imgui.InvisibleButton("##sort_buy_"..mode_idx, imgui.ImVec2(btn_w, btn_h)) then
                if is_active then
                    App.buy_config_sort.asc = not App.buy_config_sort.asc
                else
                    App.buy_config_sort.mode = mode_idx
                    App.buy_config_sort.asc = true
                end
            end
            
            local is_hovered = imgui.IsItemHovered()
            
            local bg_col
            local text_col
            local border_col = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.border_light)
            
            if is_active then
                bg_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(CURRENT_THEME.accent_primary.x, CURRENT_THEME.accent_primary.y, CURRENT_THEME.accent_primary.z, 0.2))
                text_col = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary)
                border_col = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary)
            else
                bg_col = imgui.ColorConvertFloat4ToU32(is_hovered and CURRENT_THEME.bg_tertiary or CURRENT_THEME.bg_secondary)
                text_col = imgui.ColorConvertFloat4ToU32(is_hovered and CURRENT_THEME.text_primary or CURRENT_THEME.text_secondary)
            end
            
            draw_list:AddRectFilled(pos, imgui.ImVec2(pos.x + btn_w, pos.y + btn_h), bg_col, S(6))
            draw_list:AddRect(pos, imgui.ImVec2(pos.x + btn_w, pos.y + btn_h), border_col, S(6))
            
            local label_sz = imgui.CalcTextSize(label)
            local icon_w = 0
            local sort_icon = ""
            if is_active and font_fa then
                sort_icon = App.buy_config_sort.asc and fa('arrow_down_a_z') or fa('arrow_up_a_z')
                if mode_idx > 0 then sort_icon = App.buy_config_sort.asc and fa('arrow_down_1_9') or fa('arrow_up_1_9') end
                imgui.PushFont(font_fa)
                icon_w = imgui.CalcTextSize(sort_icon).x + S(6)
                imgui.PopFont()
            elseif icon and font_fa then
                 sort_icon = icon
                 imgui.PushFont(font_fa)
                 icon_w = imgui.CalcTextSize(sort_icon).x + S(6)
                 imgui.PopFont()
            end
            
            local content_w = label_sz.x + icon_w
            local start_x = pos.x + (btn_w - content_w) / 2
            local center_y = pos.y + btn_h / 2
            
            if sort_icon ~= "" and font_fa then
                imgui.PushFont(font_fa)
                draw_list:AddText(imgui.ImVec2(start_x, center_y - imgui.CalcTextSize(sort_icon).y/2), text_col, sort_icon)
                imgui.PopFont()
            end
            
            draw_list:AddText(imgui.ImVec2(start_x + icon_w, center_y - label_sz.y/2), text_col, label)
        end

        imgui.SetCursorPos(imgui.ImVec2(margin_x, header_h + (sort_bar_h - btn_h)/2))
        
        renderCustomSortButton(u8"Имя", fa('font'), 0)
        imgui.SameLine(0, gap)
        renderCustomSortButton(u8"Кол-во", fa('list_ol'), 1)
        imgui.SameLine(0, gap)
        renderCustomSortButton(u8"Цена", fa('coins'), 2)

        imgui.SetCursorPos(imgui.ImVec2(0, header_h + sort_bar_h))
        imgui.PushStyleVarVec2(imgui.StyleVar.ItemSpacing, imgui.ImVec2(0, S(6)))
        imgui.BeginChild("##ConfigManagerList", imgui.ImVec2(win_w, content_h), false)
        imgui.Dummy(imgui.ImVec2(0, S(6)))

        local item_w = win_w - margin_x*2 - S(5)
        local item_h = S(50)

        local display_list = {}
        for i, v in ipairs(Data.buy_configs) do
            local total_price = 0
            if App.buy_config_sort.mode == 2 then
                for _, item in ipairs(v.items or {}) do
                    total_price = total_price + (tonumber(item.price) or 0) * (tonumber(item.amount) or 1)
                end
            end
            table.insert(display_list, { 
                real_idx = i, 
                data = v, 
                count = #(v.items or {}),
                price = total_price,
                name_l = v.name:lower()
            })
        end

        table.sort(display_list, function(a, b)
            local val_a, val_b
            if App.buy_config_sort.mode == 0 then 
                val_a, val_b = a.name_l, b.name_l
            elseif App.buy_config_sort.mode == 1 then 
                val_a, val_b = a.count, b.count
            elseif App.buy_config_sort.mode == 2 then 
                val_a, val_b = a.price, b.price
            end
            
            if val_a == val_b then
                return a.real_idx < b.real_idx
            end
            
            if App.buy_config_sort.asc then
                return val_a < val_b
            else
                return val_a > val_b
            end
        end)

        for _, entry in ipairs(display_list) do
            local i = entry.real_idx
            local config = entry.data
            local is_active = (Data.active_buy_config == i)
            local is_renaming = (App.rename_config_idx == i)

            imgui.SetCursorPosX(margin_x)
            local item_p = imgui.GetCursorScreenPos()
            local dl = imgui.GetWindowDrawList()

            local bg_col = is_active and CURRENT_THEME.bg_tertiary or CURRENT_THEME.bg_secondary
            dl:AddRectFilled(item_p, imgui.ImVec2(item_p.x + item_w, item_p.y + item_h), imgui.ColorConvertFloat4ToU32(bg_col), S(8))
            if is_active then dl:AddRectFilled(item_p, imgui.ImVec2(item_p.x + S(4), item_p.y + item_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_success), S(8),5) end

            imgui.BeginGroup()

            if is_renaming then
                local btn_sz = S(28)
                local input_w = item_w - btn_sz*2 - S(25)
                imgui.SetCursorPosY(imgui.GetCursorPosY() + (item_h - S(32))/2)
                
                renderModernInput("##ren_inp_"..i, Buffers.new_config_name, input_w, "Имя...")
                
                imgui.SameLine()
                local save_pos = imgui.GetCursorScreenPos()
                if imgui.InvisibleButton("##sv_rn_"..i, imgui.ImVec2(btn_sz, btn_sz)) then
                    local new_name = u8:decode(ffi.string(Buffers.new_config_name))
                    if new_name ~= "" then renameBuyConfig(i,new_name) end
                    App.rename_config_idx = nil
                end
                if font_fa then
                    imgui.PushFont(font_fa)
                    local col = imgui.IsItemHovered() and CURRENT_THEME.accent_success or CURRENT_THEME.text_hint
                    dl:AddText(imgui.ImVec2(save_pos.x + S(6), save_pos.y + S(6)), imgui.ColorConvertFloat4ToU32(col), fa('check'))
                    imgui.PopFont()
                end

                imgui.SameLine()
                local cancel_pos = imgui.GetCursorScreenPos()
                if imgui.InvisibleButton("##cn_rn_"..i, imgui.ImVec2(btn_sz, btn_sz)) then App.rename_config_idx = nil end
                if font_fa then
                    imgui.PushFont(font_fa)
                    local col = imgui.IsItemHovered() and CURRENT_THEME.accent_danger or CURRENT_THEME.text_hint
                    dl:AddText(imgui.ImVec2(cancel_pos.x + S(6), cancel_pos.y + S(6)), imgui.ColorConvertFloat4ToU32(col), fa('xmark'))
                    imgui.PopFont()
                end
            else
                local buttons_zone = S(100) 
                if imgui.InvisibleButton("##sel_cfg_"..i, imgui.ImVec2(item_w - buttons_zone, item_h)) then selectBuyConfig(i) end

                local cy = item_p.y + item_h/2
                local icon_x = item_p.x + S(20)

                if font_fa then
                    imgui.PushFont(font_fa)
                    dl:AddText(imgui.ImVec2(icon_x, cy - S(7)), imgui.ColorConvertFloat4ToU32(is_active and CURRENT_THEME.accent_primary or CURRENT_THEME.text_secondary), is_active and fa('folder_open') or fa('folder'))
                    imgui.PopFont()
                end

                local txt_x = icon_x + S(30)
                dl:AddText(imgui.ImVec2(txt_x, cy - S(10)), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary), u8(config.name))
                
                local info_text = tostring(#(config.items or {}))..u8(" шт.")
                if entry.price > 0 then
                    info_text = info_text .. " | " .. formatMoney(entry.price) .. " $"
                end
                
                dl:AddText(imgui.ImVec2(txt_x, cy + S(5)), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint), info_text)

                local btn_sz = S(28)
                local right = item_p.x + item_w - S(10)

                imgui.SetCursorScreenPos(imgui.ImVec2(right - btn_sz, cy - btn_sz/2))
                if imgui.InvisibleButton("##del_"..i, imgui.ImVec2(btn_sz, btn_sz)) then deleteBuyConfig(i) end

                imgui.SetCursorScreenPos(imgui.ImVec2(right - btn_sz*2 - S(5), cy - btn_sz/2))
                if imgui.InvisibleButton("##ren_"..i, imgui.ImVec2(btn_sz, btn_sz)) then
                    App.rename_config_idx = i
                    imgui.StrCopy(Buffers.new_config_name, u8(config.name))
                end

                imgui.SetCursorScreenPos(imgui.ImVec2(right - btn_sz*3 - S(10), cy - btn_sz/2))
                if imgui.InvisibleButton("##share_"..i, imgui.ImVec2(btn_sz, btn_sz)) then api_ShareConfig(i) end

                if font_fa then
                    imgui.PushFont(font_fa)
                    local iy = cy - S(7)
                    dl:AddText(imgui.ImVec2(right - btn_sz + S(6), iy), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint), fa('trash'))
                    dl:AddText(imgui.ImVec2(right - btn_sz*2 - S(5) + S(6), iy), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint), fa('pen'))
                    dl:AddText(imgui.ImVec2(right - btn_sz*3 - S(10) + S(6), iy), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint), fa('share'))
                    imgui.PopFont()
                end
            end

            imgui.EndGroup()
        end

        imgui.EndChild()
        imgui.PopStyleVar()

        imgui.SetCursorPos(imgui.ImVec2(0, h - footer_h))
        local footer_p = imgui.GetCursorScreenPos()
        draw_list:AddRectFilled(footer_p, imgui.ImVec2(footer_p.x + win_w, footer_p.y + footer_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary), S(10),10)
        draw_list:AddLine(footer_p, imgui.ImVec2(footer_p.x + win_w, footer_p.y), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.border_light),1)

        local input_w = win_w - S(140)
        imgui.SetCursorPos(imgui.ImVec2(S(15), h - footer_h + S(15)))
        renderModernInput("##new_cfg_name", Buffers.new_config_name, input_w, "Новое название...")
        imgui.SameLine()
        if renderCustomButton(u8"Создать", S(100), S(32), CURRENT_THEME.accent_primary) then
            local name = u8:decode(ffi.string(Buffers.new_config_name))
            if name ~= "" then
                createBuyConfig(name)
                imgui.StrCopy(Buffers.new_config_name, "")
            end
        end

        imgui.SetCursorPos(imgui.ImVec2(S(15), h - footer_h + S(60)))
        renderModernInput("##import_code", Buffers.import_code, input_w, "Код для импорта...")
        imgui.SameLine()
        if renderCustomButton(u8"Импорт", S(100), S(32), CURRENT_THEME.accent_secondary) then api_ImportConfig() end
    end

    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar()
end

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
    imgui.PopStyleColor(8) 
    imgui.PopStyleVar()
end


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
    
    
    if font_fa then imgui.PushFont(font_fa) end
    imgui.TextColored(CURRENT_THEME.accent_primary, icon)
    if font_fa then imgui.PopFont() end
    
    imgui.SameLine(nil, S(10))
    imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_primary)
    imgui.Text(name:upper()) 
    imgui.PopStyleColor()
    
    
    local line_y = imgui.GetCursorScreenPos().y - S(5)
    draw_list:AddRectFilledMultiColor(
        imgui.ImVec2(p.x, line_y),
        imgui.ImVec2(p.x + w, line_y + S(2)),
        imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary), 
        imgui.ColorConvertFloat4ToU32(lerpColor(CURRENT_THEME.accent_primary, CURRENT_THEME.bg_main, 0.5)), 
        imgui.ColorConvertFloat4ToU32(lerpColor(CURRENT_THEME.accent_primary, CURRENT_THEME.bg_main, 0.5)),
        imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary)
    )
    
    imgui.Spacing()
end

function renderBuyConfigSelectorModal()
    local sw, sh = getScreenResolution()
    local modal_w, modal_h = S(500), S(600)
    
    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(modal_w, modal_h), imgui.Cond.FirstUseEver)
    
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleColor(imgui.Col.WindowBg, CURRENT_THEME.bg_main)
    imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_secondary)
    
    if imgui.Begin("ConfigSelector", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoResize) then
        local draw_list = imgui.GetWindowDrawList()
        local p = imgui.GetCursorScreenPos()
        local win_w = imgui.GetContentRegionAvail().x
        
        local header_h = S(60)
        draw_list:AddRectFilled(p, imgui.ImVec2(p.x + win_w, p.y + header_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary), S(10), 5)
        draw_list:AddLine(imgui.ImVec2(p.x, p.y + header_h), imgui.ImVec2(p.x + win_w, p.y + header_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.border_light), 1.0)
        
        imgui.SetCursorPos(imgui.ImVec2(S(20), (header_h - imgui.GetFontSize())/2))
        if font_fa then 
            imgui.PushFont(font_fa) 
            imgui.TextColored(CURRENT_THEME.accent_primary, fa('download'))
            imgui.PopFont()
        end
        imgui.SameLine()
        imgui.TextColored(CURRENT_THEME.text_primary, u8"Копирование товаров")
        
        local footer_h = S(130)
        local list_h = modal_h - header_h - footer_h
        
        imgui.SetCursorPos(imgui.ImVec2(0, header_h))
        
        renderSmoothScrollBox("SelectorList", imgui.ImVec2(win_w, list_h), function()
            imgui.Dummy(imgui.ImVec2(0, S(10)))
            
            imgui.Indent(S(15))
            imgui.TextColored(CURRENT_THEME.text_secondary, u8"Выберите конфиг из списка:")
            imgui.Unindent(S(15))
            imgui.Dummy(imgui.ImVec2(0, S(5)))
            
            for i, config in ipairs(Data.buy_configs) do
                local is_selected = (Buffers.config_selected[0] == i - 1)
                
                local item_h = S(50)
                local margin_x = S(15)
                local item_w = win_w - (margin_x * 2)
                local item_p = imgui.GetCursorScreenPos()
                
                imgui.SetCursorPosX(margin_x)
                
                local bg_col = CURRENT_THEME.bg_secondary
                if is_selected then bg_col = CURRENT_THEME.bg_tertiary end
                
                draw_list:AddRectFilled(item_p, imgui.ImVec2(item_p.x + item_w, item_p.y + item_h), imgui.ColorConvertFloat4ToU32(bg_col), S(8))
                
                if is_selected then
                    draw_list:AddRect(item_p, imgui.ImVec2(item_p.x + item_w, item_p.y + item_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary), S(8), 15, S(2))
                end
                
                if imgui.InvisibleButton("##sel_item_"..i, imgui.ImVec2(item_w, item_h)) then
                    Buffers.config_selected[0] = i - 1
                end
                
                local cy = item_p.y + item_h/2
                local radio_x = item_p.x + S(20)
                draw_list:AddCircleFilled(imgui.ImVec2(radio_x, cy), S(8), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_main))
                draw_list:AddCircle(imgui.ImVec2(radio_x, cy), S(8), imgui.ColorConvertFloat4ToU32(is_selected and CURRENT_THEME.accent_primary or CURRENT_THEME.text_hint), 12, S(1.5))
                if is_selected then
                    draw_list:AddCircleFilled(imgui.ImVec2(radio_x, cy), S(4), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary))
                end
                
                local text_x = radio_x + S(25)
                local col_text = is_selected and CURRENT_THEME.text_primary or CURRENT_THEME.text_secondary
                draw_list:AddText(imgui.ImVec2(text_x, cy - imgui.GetFontSize()/2), imgui.ColorConvertFloat4ToU32(col_text), u8(config.name))
                
                local count_str = tostring(#config.items)
                local count_sz = imgui.CalcTextSize(count_str)
                draw_list:AddText(imgui.ImVec2(item_p.x + item_w - count_sz.x - S(20), cy - count_sz.y/2), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint), count_str)
                
                imgui.SetCursorPosY(imgui.GetCursorPosY() + S(8))
            end
            imgui.Dummy(imgui.ImVec2(0, S(10)))
        end)
        
        local footer_y = p.y + modal_h - footer_h
        draw_list:AddLine(imgui.ImVec2(p.x, footer_y), imgui.ImVec2(p.x + win_w, footer_y), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.border_light), 1.0)
        draw_list:AddRectFilled(imgui.ImVec2(p.x, footer_y), imgui.ImVec2(p.x + win_w, p.y + modal_h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary), S(10), 10)
        
        imgui.SetCursorPos(imgui.ImVec2(S(15), modal_h - footer_h + S(15)))
        imgui.TextColored(CURRENT_THEME.text_secondary, u8"Или создайте новый:")
        
        imgui.SetCursorPos(imgui.ImVec2(S(15), modal_h - footer_h + S(35)))
        renderModernInput("##new_cfg_name_modal", Buffers.new_config_name, win_w - S(30), "Название нового конфига...")
        
        local btn_area_y = modal_h - S(50)
        local gap = S(10)
        local btn_w = (win_w - (S(15)*2) - (gap*2)) / 3
        local btn_h = S(35)
        
        imgui.SetCursorPos(imgui.ImVec2(S(15), btn_area_y))
        if renderCustomButton(u8"Копировать", btn_w, btn_h, CURRENT_THEME.accent_success, fa('check')) then
            local selected_idx = Buffers.config_selected[0] + 1
            if selected_idx >= 1 and selected_idx <= #Data.buy_configs then
                performRemoteShopCopy(selected_idx)
                App.show_config_selector = false
                imgui.StrCopy(Buffers.new_config_name, "")
            end
        end
        
        imgui.SetCursorPos(imgui.ImVec2(S(15) + btn_w + gap, btn_area_y))
        if renderCustomButton(u8"Создать", btn_w, btn_h, CURRENT_THEME.accent_primary, fa('plus')) then
            local new_name_utf8 = ffi.string(Buffers.new_config_name)
            local new_name = u8:decode(new_name_utf8)
            
            if new_name and new_name ~= "" then
                local new_idx = createBuyConfig(new_name)
                Buffers.config_selected[0] = new_idx - 1
                imgui.StrCopy(Buffers.new_config_name, "")
            else
                 addToastNotification("Введите название!", "error")
            end
        end
        
        imgui.SetCursorPos(imgui.ImVec2(S(15) + (btn_w + gap)*2, btn_area_y))
        if renderCustomButton(u8"Отмена", btn_w, btn_h, imgui.ImVec4(0.4, 0.4, 0.45, 1.0), fa('xmark')) then
            App.show_config_selector = false
            imgui.StrCopy(Buffers.new_config_name, "")
        end
        
    end
    imgui.End()
    imgui.PopStyleColor(2)
    imgui.PopStyleVar()
end

function renderCustomButton(label, w, h, col, icon)
    local p = imgui.GetCursorScreenPos()
    local draw_list = imgui.GetWindowDrawList()
    local clicked = imgui.InvisibleButton("##btn_"..label, imgui.ImVec2(w, h))
    
    local is_hovered = imgui.IsItemHovered()
    local is_active = imgui.IsItemActive()
    
    local final_col = imgui.ImVec4(col.x, col.y, col.z, col.w)
    if is_hovered then final_col = imgui.ImVec4(col.x*1.15, col.y*1.15, col.z*1.15, 1) end
    if is_active then final_col = imgui.ImVec4(col.x*0.9, col.y*0.9, col.z*0.9, 1) end
    
    draw_list:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), imgui.ColorConvertFloat4ToU32(final_col), S(6))
    
    local text_sz = imgui.CalcTextSize(label)
    local icon_w = 0
    if icon and font_fa then
        imgui.PushFont(font_fa)
        icon_w = imgui.CalcTextSize(icon).x + S(8)
        imgui.PopFont()
    end
    
    local total_w = text_sz.x + icon_w
    local start_x = p.x + (w - total_w)/2
    local cy = p.y + h/2
    
    if icon and font_fa then
        imgui.PushFont(font_fa)
        draw_list:AddText(imgui.ImVec2(start_x, cy - imgui.GetFontSize()/2), 0xFFFFFFFF, icon)
        imgui.PopFont()
        start_x = start_x + icon_w
    end
    
    draw_list:AddText(imgui.ImVec2(start_x, cy - text_sz.y/2), 0xFFFFFFFF, label)
    
    return clicked
end

function renderEmptyState(icon, title, description, button_text, button_callback)
    local w = imgui.GetContentRegionAvail().x
    local h = imgui.GetContentRegionAvail().y
    
    local icon_size = S(60) -- Примерная высота иконки
    local title_size = imgui.CalcTextSize(u8(title)).y
    
    local desc_text = u8(description)
    local desc_width = w - S(40)
    local desc_size = imgui.CalcTextSize(desc_text, nil, false, desc_width).y
    
    local btn_h = S(40)
    local spacing = S(15)
    
    local total_content_h = icon_size + spacing + title_size + spacing + desc_size + spacing + btn_h
    
    local start_y = (h - total_content_h) / 2
    if start_y < S(20) then start_y = S(20) end
    
    imgui.SetCursorPos(imgui.ImVec2(0, start_y))
    
    if font_fa then
        imgui.PushFont(font_fa)
        imgui.SetWindowFontScale(2.5) 
        local icon_str_sz = imgui.CalcTextSize(icon)
        imgui.SetCursorPosX((w - icon_str_sz.x) / 2)
        local col = imgui.ImVec4(CURRENT_THEME.accent_primary.x, CURRENT_THEME.accent_primary.y, CURRENT_THEME.accent_primary.z, 0.2)
        imgui.TextColored(col, icon)
        imgui.SetWindowFontScale(1.0)
        imgui.PopFont()
    end
    
    imgui.Dummy(imgui.ImVec2(0, spacing))
    
    local t_sz = imgui.CalcTextSize(u8(title))
    imgui.SetCursorPosX((w - t_sz.x) / 2)
    imgui.TextColored(CURRENT_THEME.text_primary, u8(title))
    
    imgui.Dummy(imgui.ImVec2(0, S(5)))
    
    imgui.PushTextWrapPos(w - S(20)) 
    
    local d_sz = imgui.CalcTextSize(desc_text)
    if d_sz.x < (w - S(40)) then
        imgui.SetCursorPosX((w - d_sz.x) / 2)
    else
        imgui.SetCursorPosX(S(20))
    end
    
    imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_secondary)
    imgui.TextWrapped(desc_text)
    imgui.PopStyleColor()
    imgui.PopTextWrapPos()
    
    if button_text and button_callback then
        imgui.Dummy(imgui.ImVec2(0, spacing + S(5)))
        
        local btn_text_u8 = u8(button_text)
        local text_size = imgui.CalcTextSize(btn_text_u8)
        local btn_w = text_size.x + S(40) 
        
        if btn_w < S(180) then btn_w = S(180) end
        if btn_w > w - S(40) then btn_w = w - S(40) end
        
        imgui.SetCursorPosX((w - btn_w) / 2)
        
        imgui.PushStyleColor(imgui.Col.Button, CURRENT_THEME.accent_primary)
        imgui.PushStyleColor(imgui.Col.ButtonHovered, lerpColor(CURRENT_THEME.accent_primary, imgui.ImVec4(1,1,1,1), 0.2))
        imgui.PushStyleColor(imgui.Col.ButtonActive, lerpColor(CURRENT_THEME.accent_primary, imgui.ImVec4(0,0,0,1), 0.2))
        
        if imgui.Button(btn_text_u8, imgui.ImVec2(btn_w, btn_h)) then
            button_callback()
        end
        
        imgui.PopStyleColor(3)
    end
end

imgui.OnFrame(
    function()
        -- Если активно обучение, показываем его (и скрываем остальное, если надо, но тут условие OR)
        return App.show_tutorial 
            or App.win_state[0]
            or App.is_scanning_buy
            or State.buying.active
            or App.is_selling_cef
            or App.remote_shop_active
            or App.show_config_selector
            or App.show_config_manager
			or App.show_sell_config_manager
    end,
    function(player)
        -- [NEW] Окно критического обновления (самый высокий приоритет)
        if App.show_update_alert then
            renderUpdateAlertWindow()
            return
        end
        
        -- [NEW] ПРИОРИТЕТНОЕ ОТОБРАЖЕНИЕ ТУТОРИАЛА
        if App.show_tutorial then
            renderTutorialWindow()
            -- Если идет туториал, мы НЕ рисуем основное окно и другие окна
            -- Поэтому делаем return, чтобы прервать выполнение функции OnFrame для других окон
            return 
        end
		
        if App.show_config_selector then
            renderBuyConfigSelectorModal()
        end
        
        if App.show_config_manager then
            renderConfigManagerWindow()
        end
		
		if App.show_sell_config_manager then
			renderSellConfigManager()
		end
        
        
        if App.remote_shop_active and Data.settings.show_remote_shop_menu then
            renderRemoteShopWindow()

            
            if not App.win_state[0] then
                return
            end
        end

        
        
        

        
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

        
        if State.buying.active then
            local title = "ВЫСТАВЛЕНИЕ СКУПКИ"
            local status = "Выставляю товары..."
            local current_idx = State.buying.current_item_index or 0
            local total = State.buying.items_to_buy and #State.buying.items_to_buy or 0
            
            local progress = string.format(
                "Товар: %d / %d",
                current_idx,
                total
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

        
        if App.is_selling_cef then
            local current_idx = App.current_sell_item_index or 0
            local queue_size = (Data.cef_sell_queue and #Data.cef_sell_queue) or 0
            local total = queue_size + (App.current_processing_item and 1 or 0)

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

        
        
        
        if not App.win_state[0] then
            return
        end

        
        
        
        local sw, sh = getScreenResolution()

        
        local base_w, base_h = 1000, 650

        local scaled_w = math.floor(base_w * CURRENT_SCALE)
        local scaled_h = math.floor(base_h * CURRENT_SCALE)

        
        if scaled_w > sw * 0.95 then scaled_w = math.floor(sw * 0.95) end
        if scaled_h > sh * 0.95 then scaled_h = math.floor(sh * 0.95) end

        
        if scaled_w < 800 then scaled_w = 800 end
        if scaled_h < 500 then scaled_h = 500 end

        
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

        
        
        
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, 0)
        imgui.PushStyleVarFloat(imgui.StyleVar.WindowBorderSize, 0)

        imgui.PushStyleColor(imgui.Col.WindowBg, CURRENT_THEME.bg_main)
        imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_primary)
        imgui.PushStyleColor(imgui.Col.TextDisabled, CURRENT_THEME.text_hint)

        
        
        
        if imgui.Begin("Rodina Market", App.win_state,
        imgui.WindowFlags.NoCollapse + 
        imgui.WindowFlags.NoTitleBar + 
        imgui.WindowFlags.NoResize) then
        
        local window_pos = imgui.GetWindowPos()
        local window_size = imgui.GetWindowSize()
        
        renderCustomHeader()
        
        imgui.BeginChild("Tabs", imgui.ImVec2(window_size.x, S(55)), false, imgui.WindowFlags.NoScrollbar)
            imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_secondary)
            local draw_list = imgui.GetWindowDrawList()
            local p = imgui.GetCursorScreenPos()
            local w = window_size.x
            
            -- [NEW] Фильтрация вкладок: Скрываем ID 7 если нет VIP
            local visible_tabs = {}
            for _, t in ipairs(tabs) do
                if t.id ~= 7 or Data.is_vip then
                    table.insert(visible_tabs, t)
                end
            end

            local tab_count = #visible_tabs
            local tab_w = w / tab_count
            
            draw_list:AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + S(55)), 
                imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary))
            
            local dt = imgui.GetIO().DeltaTime
            
            -- [FIX] Находим порядковый номер (индекс) активной вкладки среди ВИДИМЫХ
            local active_index = 1
            local active_found = false
            for idx, t in ipairs(visible_tabs) do
                if t.id == App.active_tab then
                    active_index = idx
                    active_found = true
                    break
                end
            end
            
            -- Если активная вкладка стала скрытой (например, VIP кончился), переключаем на 1
            if not active_found then
                App.active_tab = 1
                active_index = 1
            end
            
            anim_tabs.target_pos = (active_index - 1) * tab_w
            
            anim_tabs.current_pos = anim_tabs.current_pos + (anim_tabs.target_pos - anim_tabs.current_pos) * 12.0 * dt
            
            tab_content_alpha = 1.0 

            local indicator_w = tab_w * 0.6
            local indicator_x = p.x + anim_tabs.current_pos + (tab_w - indicator_w) / 2
            
            draw_list:AddRectFilled(
                imgui.ImVec2(indicator_x, p.y + S(53)), 
                imgui.ImVec2(indicator_x + indicator_w, p.y + S(55)), 
                imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary), 
                S(3) 
            )
            
            -- Рендерим только видимые вкладки
            for i, tab in ipairs(visible_tabs) do
                local tab_p = imgui.ImVec2(p.x + (i-1) * tab_w, p.y)
                imgui.SetCursorScreenPos(tab_p)
                
                imgui.PushIDInt(tab.id)
                if imgui.InvisibleButton("##tab_"..i, imgui.ImVec2(tab_w, S(55))) then
                    App.active_tab = tab.id
                end
                
                local hovered = imgui.IsItemHovered()
                local is_active = (App.active_tab == tab.id)
                
                local target_col = is_active and CURRENT_THEME.accent_primary 
                                  or (hovered and CURRENT_THEME.text_primary or CURRENT_THEME.text_secondary)
                local col_u32 = imgui.ColorConvertFloat4ToU32(target_col)

                local icon_size = imgui.CalcTextSize(tab.icon)
                local label_size = imgui.CalcTextSize(u8(tab.name))
                
                local content_w = icon_size.x + S(8) + label_size.x
                local start_x = tab_p.x + (tab_w - content_w) / 2
                local start_y = tab_p.y + (S(55) - label_size.y) / 2
                
                if font_fa then
                    imgui.PushFont(font_fa)
                    draw_list:AddText(imgui.ImVec2(start_x, start_y), col_u32, tab.icon)
                    imgui.PopFont()
                end
                
                draw_list:AddText(imgui.ImVec2(start_x + icon_size.x + S(8), start_y), col_u32, u8(tab.name))
                imgui.PopID()
            end
            imgui.PopStyleColor()
        imgui.EndChild()
        
        imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(20), S(20)))
        imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_main)
        
        local content_size = imgui.GetContentRegionAvail()
        if content_size.y < 1 then content_size.y = 1 end
        
        imgui.BeginChild("Content", content_size, false, imgui.WindowFlags.NoScrollbar)
            
            if App.active_tab == 1 then
                
                if countTable(Data.item_names) < 10 then
                    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
                    
                    imgui.BeginChild("EmptyDBFullOverlay", imgui.GetContentRegionAvail(), false)
                        
                        renderEmptyState(
                            fa('triangle_exclamation'), 
                            "База предметов пуста", 
                            "Скрипту нужно узнать ID предметов.\n1. Арендуйте СВОБОДНУЮ лавку.\n2. Нажмите кнопку ниже.\n3. Дождитесь конца сканирования.",
                            "Начать сканирование", 
                            function() App.active_tab = 2 end 
                        )
                        
                    imgui.EndChild()
                    imgui.PopStyleVar()
                else
                    local avail_w = imgui.GetContentRegionAvail().x
                    local avail_h = imgui.GetContentRegionAvail().y

                    if not Data.cached_sell_filtered or ffi.string(Buffers.sell_search) ~= Data.last_sell_search_str then
                        Data.last_sell_search_str = ffi.string(Buffers.sell_search)
                        Data.cached_sell_filtered = filterList(Data.scanned_items, Buffers.sell_search)
                    end
                    local filtered_items = Data.cached_sell_filtered
                    local sell_total = calculateSellTotal()

                    imgui.Spacing()
                    imgui.Columns(2, "##sale_content", true)
                    imgui.SetColumnWidth(0, avail_w * 0.4)

                    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(12), S(12)))
                    local left_panel_height = avail_h - S(25)
                    
                    imgui.BeginChild("ScannedItemsPanel", imgui.ImVec2(0, left_panel_height), true, imgui.WindowFlags.NoScrollbar)
                        -- [FIX] 1. Делаем фон контейнера прозрачным, чтобы убрать лишний серый цвет
                        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0,0,0,0))
                        
                        renderUnifiedHeader(u8("Мой инвентарь"), fa('box_open'))

                        if #Data.scanned_items == 0 then
                            renderEmptyState(
                                fa('box_open'),
                                "Инвентарь не загружен",
                                "Скрипт должен прочитать ваш инвентарь.\nНажмите кнопку ниже - он сам откроет и считает предметы.",
                                "Сканировать инвентарь",
                                function() startScanning() end
                            )
                        else
                            -- [FIX] 2. Устанавливаем темный (bg_main) фон для самого списка товаров
                            imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_main)
                            
                            renderSmoothScrollBox("ScannedItemsScroll", imgui.ImVec2(0, 0), function()
								applyThemeTextColors()

								local item_h_real = S(36) + S(2)
								local total_items = #filtered_items
								local current_scroll = imgui.GetScrollY()
								local visible_height = imgui.GetWindowHeight()

								local start_idx = math.floor(current_scroll / item_h_real) + 1
								local end_idx = start_idx + math.ceil(visible_height / item_h_real) + 1

								start_idx = math.max(1, start_idx)
								end_idx = math.min(total_items, end_idx)

								imgui.SetCursorPosY((start_idx - 1) * item_h_real)

								for i = start_idx, end_idx do
									local item = filtered_items[i]
									if item then
										imgui.PushIDInt(i)
										
										local is_added = isSlotInSellList(item.slot, item.model_id)
										local count_in_sell = countItemInSellList(item.model_id)
										local is_rented = (item.time and tonumber(item.time) > 0)
										local has_avg = getAveragePriceForItem(item, "sell")

										local p = imgui.GetCursorScreenPos()
										local w = imgui.GetContentRegionAvail().x
										local h = S(36)

										imgui.SetCursorScreenPos(p)
										
										-- === [FIX] ЛОГИКА КЛИКА: УДАЛЕНИЕ ИЛИ ДОБАВЛЕНИЕ ===
										if imgui.InvisibleButton("##scan_btn_" .. i, imgui.ImVec2(w, h)) then
											if is_rented then
												addToastNotification("Нельзя продать арендованный товар!", "warning")
											elseif is_added then
												-- Удаление товара, если он уже есть в списке
												for k, v in ipairs(Data.sell_list) do
													if v.model_id == item.model_id and v.slot == item.slot then
														table.remove(Data.sell_list, k)
														addToastNotification("Товар убран из списка", "info", 1.5)
														break
													end
												end
												saveListsConfig()
												calculateSellTotal()
											else
												-- Добавление товара
												table.insert(Data.sell_list, {
													name = item.original_name or item.name,
													price = 0,
													amount = item.amount or 1,
													model_id = item.model_id, 
													slot = item.slot, 
													missing = false, 
													active = true,
													auto_max = true
												})
												saveListsConfig()
												calculateSellTotal()
												
												-- Скроллим список справа в самый низ (теперь работает с гарантией)
												triggerScrollToBottom("SellItemsScroll")
											end
										end
										-- ===================================================

										local is_hovered = imgui.IsItemHovered()
										if is_rented and is_hovered then
											imgui.SetTooltip(u8("Товар находится в аренде.\nЕго невозможно выставить на продажу."))
										end
										
										if not is_rented and not is_added and has_avg and is_hovered then
											 imgui.SetTooltip(u8("Доступна средняя цена: ") .. formatMoney(has_avg) .. " $")
										end

										local bg_col = 0
										
										if is_added then
											bg_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(CURRENT_THEME.accent_success.x, CURRENT_THEME.accent_success.y, CURRENT_THEME.accent_success.z, 0.2))
										elseif is_rented then
											bg_col = imgui.ColorConvertFloat4ToU32(imgui.ImVec4(CURRENT_THEME.accent_warning.x, CURRENT_THEME.accent_warning.y, CURRENT_THEME.accent_warning.z, 0.15))
										elseif is_hovered then
											bg_col = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_tertiary)
										else 
											bg_col = imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary)
										end

										if bg_col ~= 0 then
											imgui.GetWindowDrawList():AddRectFilled(p, imgui.ImVec2(p.x + w, p.y + h), bg_col, S(6))
										end

										local text_y = p.y + (h - imgui.CalcTextSize("A").y) / 2
										local icon_x = p.x + S(12)

										if font_fa then imgui.PushFont(font_fa) end
										
										local icon = fa('plus')
										local icon_col = CURRENT_THEME.text_hint
										
										if is_added then 
											icon = fa('check')
											icon_col = CURRENT_THEME.accent_success
										elseif is_rented then 
											icon = fa('clock')
											icon_col = CURRENT_THEME.accent_warning
										else
											if has_avg then
												icon_col = CURRENT_THEME.accent_warning
											end
										end
										
										imgui.GetWindowDrawList():AddText(imgui.ImVec2(icon_x, text_y),
											imgui.ColorConvertFloat4ToU32(icon_col),
											icon
										)
										if font_fa then imgui.PopFont() end

										local label_x = icon_x + S(24)
										local label = u8(item.name)
										if count_in_sell > 0 and not is_added then label = label .. u8(" (еще " .. count_in_sell .. " в списке)") end
										if is_rented then label = label .. u8(" (Аренда)") end

										local text_color = is_added and CURRENT_THEME.text_secondary or CURRENT_THEME.text_primary
										if is_rented then text_color = CURRENT_THEME.text_hint end

										imgui.GetWindowDrawList():AddText(imgui.ImVec2(label_x, text_y), imgui.ColorConvertFloat4ToU32(text_color), label)

										imgui.SetCursorScreenPos(imgui.ImVec2(p.x, p.y + h + S(2)))
										imgui.PopID()
									end
								end

								if end_idx < total_items then
									local remaining = total_items - end_idx
									imgui.SetCursorPosY(imgui.GetCursorPosY() + (remaining * item_h_real))
								end
								
								revertThemeTextColors()
							end)
                            imgui.PopStyleColor() -- Возврат цвета списка
                        end
                        imgui.PopStyleColor() -- Возврат прозрачности панели
                    imgui.EndChild()
                    imgui.PopStyleVar()

                    imgui.NextColumn()

                    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(12), S(12)))
                    local button_h = S(38)
                    local spacing_h = S(10)
                    local bottom_padding = S(25)
                    local button_area_h = button_h + spacing_h + bottom_padding
                    local right_panel_height = avail_h - button_area_h

                    imgui.BeginChild("SellListPanel", imgui.ImVec2(0, right_panel_height), true, imgui.WindowFlags.NoScrollbar)
                        -- [FIX] Меняем фон заголовка панели на темный или прозрачный, чтобы не было полос
                        imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0,0,0,0)) 

                        renderUnifiedHeader(u8("Очередь на продажу"), fa('list_check'))

						local win_pos = imgui.GetWindowPos()
						local win_width = imgui.GetWindowWidth()
						local sum_str = u8("Всего: ") .. formatMoney(sell_total)
						local sum_sz = imgui.CalcTextSize(sum_str)

						-- [NEW] Подсчет заниженных цен
						local bad_price_count = 0
						for _, it in ipairs(Data.sell_list) do
							if it.active then
								local avg = getAveragePriceForItem(it, "sell", true)
								if avg and avg > 0 and (it.price or 0) > 0 and it.price < avg then
									bad_price_count = bad_price_count + 1
								end
							end
						end

						-- Рисуем сумму
						imgui.GetWindowDrawList():AddText(
							imgui.ImVec2(win_pos.x + win_width - sum_sz.x - S(15), win_pos.y + S(12)),
							imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_success), sum_str
						)

						-- [NEW] Рисуем предупреждение, если есть заниженные цены
						if bad_price_count > 0 then
							local warn_text = u8(bad_price_count .. " ниже рынка!")
							local warn_sz = imgui.CalcTextSize(warn_text)
							-- Рисуем левее суммы
							imgui.GetWindowDrawList():AddText(
								imgui.ImVec2(win_pos.x + win_width - sum_sz.x - warn_sz.x - S(30), win_pos.y + S(12)),
								imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_danger), warn_text
							)
						end

                        imgui.GetWindowDrawList():AddText(
                            imgui.ImVec2(win_pos.x + win_width - sum_sz.x - S(15), win_pos.y + S(12)),
                            imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_success), sum_str
                        )

                        imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_main)
                        renderSmoothScrollBox("SellItemsScroll", imgui.ImVec2(0, 0), function()
                            local display_list = {}
                            local search_q = ffi.string(Buffers.sell_search)
                            local is_searching = search_q ~= ""
                            
                            if is_searching then
                                local decoded_q = u8:decode(search_q)
                                for i, item in ipairs(Data.sell_list) do
                                    if SmartSearch.getMatchScore(decoded_q, item.name) > 0 then
                                        table.insert(display_list, { data = item, real_idx = i })
                                    end
                                end
                            else
                                for i, item in ipairs(Data.sell_list) do
                                    table.insert(display_list, { data = item, real_idx = i })
                                end
                            end

                            if #display_list == 0 then
                                if is_searching then
                                    renderEmptyState(fa('magnifying_glass'), "Ничего не найдено", "Попробуйте изменить поисковый запрос.")
                                else
                                    renderEmptyState(
                                        fa('inbox'),
                                        "Список продажи пуст",
                                        "Нажмите на предметы в левой панели (Инвентарь), чтобы добавить их сюда.\nЗатем укажите цену и нажмите кнопку внизу."
                                    )
                                end
                            else
                                local item_h_real = S(85) + S(8)
                                local total_items = #display_list
                                local current_scroll = imgui.GetScrollY()
                                local visible_height = imgui.GetWindowHeight()

                                local start_idx = math.floor(current_scroll / item_h_real) + 1
                                local end_idx = start_idx + math.ceil(visible_height / item_h_real) + 1

                                start_idx = math.max(1, start_idx)
                                end_idx = math.min(total_items, end_idx)

                                imgui.SetCursorPosY((start_idx - 1) * item_h_real)

                                for i = start_idx, end_idx do
                                    local entry = display_list[i]
                                    renderUnifiedConfigItem(entry.real_idx, entry.data, "sell")
                                end

                                if end_idx < total_items then
                                    local remaining = total_items - end_idx
                                    imgui.SetCursorPosY(imgui.GetCursorPosY() + (remaining * item_h_real))
                                end
                            end
                        end)
						imgui.PopStyleColor()

                        imgui.PopStyleColor()
                    imgui.EndChild()
                    imgui.PopStyleVar()

                    imgui.PushStyleColor(imgui.Col.Button, CURRENT_THEME.accent_primary)
                    imgui.PushStyleColor(imgui.Col.ButtonHovered, lerpColor(CURRENT_THEME.accent_primary, imgui.ImVec4(1,1,1,1), 0.3))
                    imgui.PushStyleColor(imgui.Col.ButtonActive, lerpColor(CURRENT_THEME.accent_primary, imgui.ImVec4(0,0,0,1), 0.2))

                    if imgui.Button(fa('paper_plane') .. " " .. u8("Выставить на продажу"), imgui.ImVec2(-1, button_h)) then
                        startCEFSelling()
                    end

                    imgui.PopStyleColor(3)
                    imgui.Columns(1)
                end
                
            elseif App.active_tab == 2 then
                
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
                
                local buy_total = calculateBuyTotal()
                
                imgui.Spacing()
                imgui.Columns(2, "##buy_content", true)
                imgui.SetColumnWidth(0, avail_size.x * 0.4)
                
                imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(12), S(12)))
                local left_buy_height = avail_h - S(25)
                imgui.BeginChild("BuyableItemsPanel", imgui.ImVec2(0, left_buy_height), true, imgui.WindowFlags.NoScrollbar)
                    renderUnifiedHeader(u8("Поиск товаров"), fa('magnifying_glass'))
                    
                    renderSmoothScrollBox("BuyableScroll", imgui.ImVec2(0, 0), function()
                        
                        if #Data.buyable_items == 0 then
                            renderEmptyState(
                                fa('store'),
                                "Список товаров пуст",
                                "Чтобы скупать, нужно знать ID товаров.\n1. Арендуйте лавку.\n2. Нажмите кнопку ниже.\n3. Скрипт запомнит товары.",
                                "Сканировать",
                                function() startBuyingScan() end
                            )
                        elseif #refreshed_buyables == 0 then
                             renderEmptyState(fa('magnifying_glass'), "Не найдено", "Товар с таким названием не найден в базе.\nПопробуйте обновить базу (кнопка сканирования вверху).")
                        else
                            applyThemeTextColors()
                            
                            local item_height = S(28) 
                            local total_items = #refreshed_buyables
                            local total_height = total_items * item_height
                            
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
                                    local is_acc = isAccessory(item.name)
                                    
                                    local btn_width = is_acc and S(70) or w
                                    local text_width = w - (is_acc and S(80) or 0)
                                    
                                    if imgui.InvisibleButton("##src"..i, imgui.ImVec2(text_width, item_height)) then
										table.insert(Data.buy_list, {name = item.name, price = 100, amount = 1, index = item.index, active = true})
										saveListsConfig()
										calculateBuyTotal()
										
										-- [ДОБАВЛЕНО] Скроллим список скупки вниз
										triggerScrollToBottom("BuyItemsList") 
										
										addToastNotification("Добавлено: " .. item.name, "success")
									end
                                    
                                    local is_hovered = imgui.IsItemHovered()
                                    if is_hovered then
                                        imgui.GetWindowDrawList():AddRectFilled(p, imgui.ImVec2(p.x + text_width, p.y + item_height), 
                                            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(1, 1, 1, 0.05)), S(4))
                                    end
                                    
                                    local text_y = p.y + (item_height - imgui.CalcTextSize("A").y) / 2
                                    imgui.GetWindowDrawList():AddText(imgui.ImVec2(p.x + S(8), text_y), 
                                        imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary), u8(item.name))
                                    
                                    if is_acc then
                                        local btn_x = p.x + text_width + S(5)
                                        local btn_y = p.y + S(2)
                                        local btn_h = item_height - S(4)
                                        local btn_w = S(70)
                                        
                                        imgui.GetWindowDrawList():AddRectFilled(
                                            imgui.ImVec2(btn_x, btn_y), imgui.ImVec2(btn_x + btn_w, btn_y + btn_h),
                                            imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_primary), S(4)
                                        )
                                        
                                        local btn_text = u8("Все")
                                        local btn_text_sz = imgui.CalcTextSize(btn_text)
                                        imgui.GetWindowDrawList():AddText(
                                            imgui.ImVec2(btn_x + (btn_w - btn_text_sz.x) / 2, btn_y + (btn_h - btn_text_sz.y) / 2),
                                            imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_primary), btn_text
                                        )
                                        
                                        imgui.SetCursorScreenPos(imgui.ImVec2(btn_x, btn_y))
                                        if imgui.InvisibleButton("##btn_all_colors_"..i, imgui.ImVec2(btn_w, btn_h)) then
                                            addAccessoryWithAllColors(item)
                                        end
                                    end
                                end
                            end
                            
                            if end_idx < total_items then
                                 local remaining = total_items - end_idx
                                 imgui.SetCursorPosY(imgui.GetCursorPosY() + (remaining * item_height))
                            end
                            revertThemeTextColors()
                        end
                    end)
                imgui.EndChild()
                imgui.PopStyleVar()
                
                imgui.NextColumn()
                
                imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(12), S(12)))
                local button_h = S(38)
                local spacing_h = S(10)
                local bottom_padding = S(25)
                local button_area_h = button_h + spacing_h + bottom_padding
                local right_buy_height = avail_h - button_area_h

                imgui.BeginChild("BuySettingsPanel", imgui.ImVec2(0, right_buy_height), true, imgui.WindowFlags.NoScrollbar)
                    imgui.PushStyleColor(imgui.Col.ChildBg, imgui.ImVec4(0,0,0,0)) -- Прозрачный фон панели
                    
                    renderUnifiedHeader(u8("Моя скупка"), fa('basket_shopping'))

					local win_pos = imgui.GetWindowPos()
					local win_width = imgui.GetWindowWidth()
					local sum_str = u8("Всего: ") .. formatMoney(buy_total)
					local sum_sz = imgui.CalcTextSize(sum_str)

					-- [NEW] Подсчет завышенных цен
					local bad_price_count = 0
					for _, it in ipairs(Data.buy_list) do
						if it.active then
							local avg = getAveragePriceForItem(it, "buy", true)
							if avg and avg > 0 and (it.price or 0) > 0 and it.price > avg then
								bad_price_count = bad_price_count + 1
							end
						end
					end

					imgui.GetWindowDrawList():AddText(
						imgui.ImVec2(win_pos.x + win_width - sum_sz.x - S(15), win_pos.y + S(12)),
						imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_success), sum_str
					)

					-- [NEW] Рисуем предупреждение
					if bad_price_count > 0 then
						local warn_text = u8(bad_price_count .. " выше рынка!")
						local warn_sz = imgui.CalcTextSize(warn_text)
						imgui.GetWindowDrawList():AddText(
							imgui.ImVec2(win_pos.x + win_width - sum_sz.x - warn_sz.x - S(30), win_pos.y + S(12)),
							imgui.ColorConvertFloat4ToU32(CURRENT_THEME.accent_danger), warn_text
						)
					end
                    
                    imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_main) -- Темный фон списка
                    renderSmoothScrollBox("BuyItemsList", imgui.ImVec2(0, 0), function()
                         local display_list = {}
                         local search_q = ffi.string(Buffers.buy_search)
                         local is_searching = search_q ~= ""
                         
                         if is_searching then
                             local decoded_q = u8:decode(search_q)
                             for i, item in ipairs(Data.buy_list) do
                                 if SmartSearch.getMatchScore(decoded_q, item.name) > 0 then
                                     table.insert(display_list, { data = item, real_idx = i })
                                 end
                             end
                         else
                             for i, item in ipairs(Data.buy_list) do
                                 table.insert(display_list, { data = item, real_idx = i })
                             end
                         end

                         if #display_list == 0 then
                            if is_searching then
                                renderEmptyState(fa('magnifying_glass'), "Ничего не найдено", "Попробуйте изменить поисковый запрос.")
                            else
                                renderEmptyState(
                                    fa('basket_shopping'),
                                    "Список скупки пуст",
                                    "Найдите товары в левой панели и нажмите на них, чтобы добавить в этот список.\nЗатем укажите цены и нажмите кнопку внизу."
                                )
                            end
                        else
                            local item_h_real = S(85) + S(8)
                            local total_items = #display_list
                            local current_scroll = imgui.GetScrollY()
                            local visible_height = imgui.GetWindowHeight()

                            local start_idx = math.floor(current_scroll / item_h_real) + 1
                            local end_idx = start_idx + math.ceil(visible_height / item_h_real) + 1

                            start_idx = math.max(1, start_idx)
                            end_idx = math.min(total_items, end_idx)

                            imgui.SetCursorPosY((start_idx - 1) * item_h_real)

                            for i = start_idx, end_idx do
                                local entry = display_list[i]
                                renderUnifiedConfigItem(entry.real_idx, entry.data, "buy")
                            end

                            if end_idx < total_items then
                                local remaining = total_items - end_idx
                                imgui.SetCursorPosY(imgui.GetCursorPosY() + (remaining * item_h_real))
                            end
                        end
                    end)
					imgui.PopStyleColor()
                    
                    imgui.PopStyleColor()
                imgui.EndChild()
                imgui.PopStyleVar()
                
                local buy_btn_hovered = false
                imgui.PushStyleColor(imgui.Col.Button, CURRENT_THEME.accent_primary)
                imgui.PushStyleColor(imgui.Col.ButtonHovered, lerpColor(CURRENT_THEME.accent_primary, imgui.ImVec4(1,1,1,1), 0.3))
                imgui.PushStyleColor(imgui.Col.ButtonActive, lerpColor(CURRENT_THEME.accent_primary, imgui.ImVec4(0,0,0,1), 0.2))
                if imgui.Button(fa('shop') .. " " .. u8("Выставить всё на скуп"), imgui.ImVec2(-1, button_h)) then
                    saveBuyConfigState()
                    startBuying()
                end
                buy_btn_hovered = imgui.IsItemHovered()
                imgui.PopStyleColor(3)
                
                imgui.Columns(1)

            elseif App.active_tab == 3 then
                
                
                imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(25), S(25)))
                imgui.BeginChild("LogsContent", imgui.ImVec2(0, 0), true)
                    imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_secondary)
                    renderLogsTab()
                    imgui.PopStyleColor()
                imgui.EndChild()
                imgui.PopStyleVar()
            
            
            elseif App.active_tab == 4 then
                
                imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(25), S(25)))
                imgui.BeginChild("GlobalMarket", imgui.ImVec2(0, 0), true)
                    imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_secondary)
                    renderGlobalMarketTab()
                    imgui.PopStyleColor()
                imgui.EndChild()
                imgui.PopStyleVar()

			elseif App.active_tab == 5 then
				imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
				imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_secondary)
				
				if imgui.BeginChild("SettingsContent", imgui.ImVec2(0, 0), true) then
					
					local avail_w = imgui.GetContentRegionAvail().x
					local pad_x = S(40) 
					local content_w = avail_w - (pad_x * 2) 
					
					local function SetLayout()
						imgui.SetCursorPosX(pad_x)
					end

					local function DrawHelp(text)
						imgui.SameLine()
						imgui.TextDisabled("(?)")
						if imgui.IsItemHovered() then
							imgui.SetTooltip(u8(text))
						end
					end
					
					imgui.Dummy(imgui.ImVec2(0, S(15)))

					SetLayout()
					imgui.BeginGroup()
						renderAAASection(fa('store'), u8"Настройки Лавки")
					imgui.EndGroup()
					
					SetLayout()
					renderAAAToggle("Авто-название лавки", Buffers.settings.auto_name)
					DrawHelp("Если включено, скрипт сам введет название лавки при её аренде.\nВам не придется каждый раз писать текст вручную.")
					
					if Buffers.settings.auto_name[0] then
						imgui.Dummy(imgui.ImVec2(0, S(5)))
						SetLayout()
						imgui.TextColored(CURRENT_THEME.text_secondary, u8("Текст названия:"))
						
						SetLayout()
						if renderModernInput("##shop_name_input", Buffers.settings.shop_name, content_w, "Например: Скупаю все дорого!") then
							saveSettings()
						end
					end
					
					imgui.Dummy(imgui.ImVec2(0, S(15)))

					SetLayout()
					imgui.BeginGroup()
						renderAAASection(fa('paper_plane'), u8"Telegram Уведомления")
					imgui.EndGroup()
					
					SetLayout()
					imgui.TextColored(CURRENT_THEME.text_secondary, u8("Ваш секретный ключ:"))
					DrawHelp("Позволяет получать сообщения о покупках/продажах в Telegram.\n1. Зайдите в бота @rdnMarket_bot\n2. Нажмите /start\n3. Скопируйте ключ и вставьте сюда.")
					
					SetLayout()
					renderModernInput("##tg_token_inp", Buffers.settings.telegram_token, content_w, "Нажмите, чтобы вставить ключ...", true)
					
					imgui.Dummy(imgui.ImVec2(0, S(5)))
					SetLayout()
					if renderCustomButton(u8"Сохранить и Проверить", content_w, S(35), CURRENT_THEME.accent_primary, fa('check_double')) then
						saveSettings(true)
						
						local token_str = ffi.string(Buffers.settings.telegram_token)
						if token_str ~= "" then
							api_TestTelegramToken(token_str)
						else
							addToastNotification("Поле ключа пустое!", "warning")
						end
					end
					
					imgui.Dummy(imgui.ImVec2(0, S(15)))
					SetLayout()
					imgui.BeginGroup()
						renderAAASection(fa('microchip'), u8"Производительность") -- Иконка чипа
					imgui.EndGroup()

					SetLayout()
					renderAAAToggle("Режим для слабых ПК", Buffers.settings.low_pc_mode)
					DrawHelp("При выставлении товаров блокирует визуальное обновление инвентаря.\nЭто убирает лаги и фризы, но вы не увидите, как предметы исчезают из слотов в реальном времени.")
					

					imgui.Dummy(imgui.ImVec2(0, S(15)))
					
					SetLayout()
					imgui.BeginGroup()
						renderAAASection(fa('desktop'), u8"Внешний вид")
					imgui.EndGroup()
					
										
					SetLayout()
					imgui.TextColored(CURRENT_THEME.text_secondary, u8("Цветовая тема:"))
					
					local theme_items = {u8("Темная (Dark Modern)"), u8("Светлая (Light Modern)"), u8("GOLD (VIP)")}
					local theme_preview = theme_items[Buffers.settings.theme_combo[0] + 1] or theme_items[1]

					pushComboStyles()
					SetLayout()
					imgui.SetNextItemWidth(content_w)
					if imgui.BeginCombo("##theme_selector", theme_preview) then
						for i, item in ipairs(theme_items) do
							local is_selected = (Buffers.settings.theme_combo[0] == i - 1)
							
							-- Блокировка темы для не-вип
							if i == 3 and not Data.is_vip then
								imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.5, 0.5, 0.5, 1.0))
								imgui.Selectable(item .. u8" [Закрыто]", false)
								imgui.PopStyleColor()
								if imgui.IsItemHovered() then imgui.SetTooltip(u8"Доступно только для VIP пользователей") end
							else
								if imgui.Selectable(item, is_selected) then
									Buffers.settings.theme_combo[0] = i - 1
									if i == 1 then applyTheme("DARK_MODERN") 
									elseif i == 2 then applyTheme("LIGHT_MODERN")
									elseif i == 3 then applyTheme("GOLD_LUXURY") end
									saveSettings()
								end
							end
						end
						imgui.EndCombo()
					end
					
					imgui.Dummy(imgui.ImVec2(0, S(5)))
					
					SetLayout()
					imgui.TextColored(CURRENT_THEME.text_secondary, u8("Размер интерфейса:"))
					DrawHelp("Изменяет размер окна и шрифтов. Полезно для мониторов с высоким разрешением.")
					
					local scale_items = {u8("Компактный (0.85x)"), u8("Стандартный (1.0x)"), u8("Крупный (1.25x)")}
					local combo_preview = scale_items[Buffers.settings.ui_scale_combo[0] + 1] or scale_items[2]
					
					SetLayout()
					imgui.SetNextItemWidth(content_w)
					if imgui.BeginCombo("##scale_c", combo_preview) then
						for i, item in ipairs(scale_items) do
							local is_selected = (Buffers.settings.ui_scale_combo[0] == i - 1)
							if imgui.Selectable(item, is_selected) then
								Buffers.settings.ui_scale_combo[0] = i - 1
								CURRENT_SCALE = SCALE_MODES[i - 1] or 1.0
								applyStrictStyle()
								saveSettings()
								Data.force_window_resize = true 
								addToastNotification(string.format("Масштаб изменен на %.2fx", CURRENT_SCALE), "success", 3.0)
							end
						end
						imgui.EndCombo()
					end
					popComboStyles()
					
					imgui.Dummy(imgui.ImVec2(0, S(10)))
					
					SetLayout()
					renderAAAToggle("Окно просмотра чужих лавок", Buffers.settings.show_remote_shop_menu)
					DrawHelp("Когда вы открываете лавку другого игрока, скрипт показывает удобное окно со списком товаров, ценами и выгодными предложениями.")

					imgui.Dummy(imgui.ImVec2(0, S(15)))
					
					SetLayout()
					imgui.BeginGroup()
						renderAAASection(fa('shield'), u8"Безопасность")
					imgui.EndGroup()
					
					SetLayout()
					imgui.TextColored(CURRENT_THEME.text_secondary, u8("Задержка действий (мс):"))
					DrawHelp("Время между выставлением товаров. \nСлишком низкое значение может привести к ошибкам.\nРекомендуемое значение: 50-100 мс.")
					
					SetLayout()
					imgui.SetNextItemWidth(content_w)
					if imgui.SliderInt("##delay_placement", Buffers.settings.delay_placement, 10, 500, "%d ms") then
						saveSettings()
					end

					imgui.Dummy(imgui.ImVec2(0, S(30)))
				end
				imgui.EndChild()
				imgui.PopStyleColor()
				imgui.PopStyleVar()
				
			elseif App.active_tab == 6 then
                imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
                imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_main) 
                
                if imgui.BeginChild("AutoPRContent", imgui.ImVec2(0, 0), true) then
                    renderAutoPRTab() -- Функционал доступен всем!
                end
                imgui.EndChild()
                
                imgui.PopStyleColor()
                imgui.PopStyleVar()
            elseif App.active_tab == 7 then
				imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(S(20), S(20)))
				imgui.BeginChild("VipAnalyticsContent", imgui.ImVec2(0, 0), true)
					imgui.PushStyleColor(imgui.Col.ChildBg, CURRENT_THEME.bg_main)
					renderVipAnalyticsTab()
					imgui.PopStyleColor()
				imgui.EndChild()
				imgui.PopStyleVar()
			end
            
        imgui.EndChild() 
        
        
        
        imgui.PopStyleColor() 
        imgui.PopStyleVar()   
        
    end
    imgui.End()
    imgui.PopStyleVar(3)
    imgui.PopStyleColor(3)
end)

function renderVipPromoOverlay(reason_text)
    local w = imgui.GetContentRegionAvail().x
    local h = imgui.GetContentRegionAvail().y
    local p = imgui.GetCursorScreenPos()
    local center_y = h / 2
    
    -- Затемнение фона
    imgui.GetWindowDrawList():AddRectFilled(
        p, 
        imgui.ImVec2(p.x + w, p.y + h), 
        imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.05, 0.05, 0.07, 0.95))
    )
    
    -- Иконка короны
    if font_fa_big then
        imgui.PushFont(font_fa_big)
        local icon = fa('crown')
        local isz = imgui.CalcTextSize(icon)
        imgui.SetCursorPos(imgui.ImVec2((w - isz.x)/2, center_y - S(80)))
        imgui.TextColored(imgui.ImVec4(1, 0.84, 0, 1.0), icon)
        imgui.PopFont()
    end
    
    -- Текст
    imgui.SetCursorPosY(center_y + S(10))
    centerText(u8"Функция доступна только с VIP")
    
    imgui.SetCursorPosY(center_y + S(35))
    imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_secondary)
    local txt_w = imgui.CalcTextSize(u8(reason_text)).x
    imgui.SetCursorPosX((w - txt_w)/2)
    imgui.Text(u8(reason_text))
    imgui.PopStyleColor()
    
    -- Кнопка покупки
    local btn_w = S(220)
    local btn_h = S(45)
    imgui.SetCursorPos(imgui.ImVec2((w - btn_w)/2, center_y + S(70)))
    
    if renderCustomButton(u8"Купить подписку", btn_w, btn_h, imgui.ImVec4(1, 0.84, 0, 0.8), fa('gem')) then
        -- Ссылка на товар FunPay или бота
        os.execute('explorer "https://funpay.com/lots/offer?id=12345678"') 
    end
end

imgui.OnFrame(function() return true end, function(this)
    this.HideCursor = true
    drawRadiusGraphics() -- << ДОБАВЛЕНО СЮДА
    renderToastNotifications()
end)


local last_gc_time = os.clock()
local last_cache_cleanup_time = os.clock()
local CACHE_CLEANUP_INTERVAL = 30.0 

local SHOP_MODEL_IDS = {
    [1796] = true, -- Обычная лавка
    [5894] = true, -- Лавка с навесом
    [5856] = true,  -- Другой тип
	[6494] = true,
	[6492] = true,
	[16656] = true,
	[6495] = true,
	[6493] = true,
	[1342] = true,
	[1107] = true
}

function isCentralMarket(x, y)
    return (x > 1090 and x < 1180 and y > -1550 and y < -1429)
end

function renderUpdateAlertWindow()
    local sw, sh = getScreenResolution()
    local w, h = S(700), S(420) -- Сделали окно компактнее и шире для текста
    
    -- Центрирование окна
    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(w, h), imgui.Cond.Always)
    
    -- Стили окна
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleVarFloat(imgui.StyleVar.WindowRounding, S(12))
    imgui.PushStyleColor(imgui.Col.WindowBg, CURRENT_THEME.bg_main)
    
    if imgui.Begin("##UpdateAlert", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse) then
        local p = imgui.GetCursorScreenPos()
        local draw_list = imgui.GetWindowDrawList()
        
        -- Размеры сайдбара
        local sidebar_w = S(200) 
        
        -- [FIX] Рисуем сайдбар. Убрали rounding_flags, чтобы избежать крашей. 
        -- Просто рисуем прямоугольник, а скругление окна (WindowRounding) само обрежет углы.
        draw_list:AddRectFilled(
            p, 
            imgui.ImVec2(p.x + sidebar_w, p.y + h), 
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.20, 0.08, 0.08, 1.0)), -- Темно-красный фон
            S(12) -- Скругляем все углы, левые обрежутся окном, правые закроются фоном контента
        )
        -- "Выпрямляем" правые углы сайдбара, рисуя прямоугольник поверх правой части скругления
        draw_list:AddRectFilled(
            imgui.ImVec2(p.x + sidebar_w - S(10), p.y), 
            imgui.ImVec2(p.x + sidebar_w, p.y + h), 
            imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.20, 0.08, 0.08, 1.0))
        )
        
        -- Иконка в сайдбаре
        if font_fa_big then
            imgui.PushFont(font_fa_big)
            local icon = fa('triangle_exclamation')
            local isz = imgui.CalcTextSize(icon)
            imgui.SetCursorPos(imgui.ImVec2((sidebar_w - isz.x) / 2, h * 0.35))
            imgui.TextColored(CURRENT_THEME.accent_danger, icon)
            imgui.PopFont()
        end
        
        -- Текст в сайдбаре
        imgui.PushFont(font_default)
        local txt_head = u8"ТРЕБУЕТСЯ\nОБНОВЛЕНИЕ"
        local txt_sz = imgui.CalcTextSize(txt_head)
        imgui.SetCursorPos(imgui.ImVec2((sidebar_w - txt_sz.x) / 2, h * 0.55))
        imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_primary)
        imgui.Text(txt_head)
        imgui.PopStyleColor()
        
        -----------------------------------------------------
        -- ПРАВАЯ ЧАСТЬ (Контент)
        -----------------------------------------------------
        local content_x = sidebar_w + S(25)
        local content_w = w - content_x - S(25)
        
        imgui.SetCursorPos(imgui.ImVec2(content_x, S(25)))
        
        imgui.BeginGroup()
            -- Заголовок
            imgui.SetWindowFontScale(1.1) 
            imgui.TextColored(CURRENT_THEME.text_primary, u8"Ваша версия устарела!")
            imgui.SetWindowFontScale(1.0)
            
            imgui.Dummy(imgui.ImVec2(0, S(15)))
            
            -- Инфо о версиях
            imgui.TextColored(CURRENT_THEME.text_secondary, u8"Текущая версия:")
            imgui.SameLine(content_w * 0.6)
            imgui.TextColored(CURRENT_THEME.accent_danger, SCRIPT_CURRENT_VERSION)
            
            
            imgui.TextColored(CURRENT_THEME.text_secondary, u8"Новая версия:")
            imgui.SameLine(content_w * 0.6)
            imgui.TextColored(CURRENT_THEME.accent_success, UpdateState.remote_version or "...")
            
            
            -- Описание проблемы
            imgui.PushTextWrapPos(imgui.GetCursorPosX() + content_w)
            imgui.TextColored(CURRENT_THEME.text_primary, u8"Не найден файл авто-обновления (!RMarket_Updater.lua).")
            imgui.Dummy(imgui.ImVec2(0, S(5)))
            imgui.TextColored(CURRENT_THEME.text_hint, u8"Автоматическое обновление невозможно. Пожалуйста, скачайте новую версию вручную с Сайта или Telegram канала @rdnMarket")
            imgui.PopTextWrapPos()
            
            imgui.PopFont()
        imgui.EndGroup()
        
        -----------------------------------------------------
        -- КНОПКИ (Внизу справа)
        -----------------------------------------------------
        local btn_h = S(35)
        
        -- Позиционируем кнопки внизу окна
        local bot_y = h - S(30) - btn_h - S(30) -- Отступ под текстовой кнопкой
        imgui.SetCursorPos(imgui.ImVec2(content_x, bot_y))
        
        -- Кнопка "Открыть сайт"
        if renderCustomButton(u8"Открыть сайт", content_w, btn_h, CURRENT_THEME.accent_primary, fa('globe')) then
            if UpdateState.website_url then
                os.execute('explorer "' .. UpdateState.website_url .. '"')
            end
        end
        
        -- Кнопка "Закрыть" (Текстовая ссылка)
        local close_txt = u8"Закрыть и использовать старую версию"
        local close_sz = imgui.CalcTextSize(close_txt)
        local center_btn_x = content_x + (content_w - close_sz.x) / 2
        
        imgui.SetCursorPos(imgui.ImVec2(center_btn_x, h - S(40)))
        
        imgui.PushStyleColor(imgui.Col.Text, CURRENT_THEME.text_hint)
        imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0,0,0,0))
        imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0,0,0,0))
        imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0,0,0,0))
        
        if imgui.Button(close_txt) then
            App.show_update_alert = false
        end
        
        -- Подчеркивание при наведении (эффект ссылки)
        if imgui.IsItemHovered() then
            local p_min = imgui.GetItemRectMin()
            local p_max = imgui.GetItemRectMax()
            draw_list:AddLine(
                imgui.ImVec2(p_min.x, p_max.y - S(2)), 
                imgui.ImVec2(p_max.x, p_max.y - S(2)), 
                imgui.ColorConvertFloat4ToU32(CURRENT_THEME.text_hint)
            )
        end
        
        imgui.PopStyleColor(4)

    end
    imgui.End()
    imgui.PopStyleColor()
    imgui.PopStyleVar(2)
end

function renderTutorialWindow()
    local sw, sh = getScreenResolution()
    local w, h = S(650), S(500) -- Чуть увеличили размер для удобства
    
    imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
    imgui.SetNextWindowSize(imgui.ImVec2(w, h), imgui.Cond.Always)
    
    imgui.PushStyleVarVec2(imgui.StyleVar.WindowPadding, imgui.ImVec2(0, 0))
    imgui.PushStyleColor(imgui.Col.WindowBg, CURRENT_THEME.bg_main)
    
    -- Добавляем флаг NoCollapse, но убираем заголовок системы
    if imgui.Begin("##TutorialWizard", nil, imgui.WindowFlags.NoTitleBar + imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse) then
        local p = imgui.GetCursorScreenPos()
        local draw_list = imgui.GetWindowDrawList()
        
        -- === ЛЕВАЯ ЧАСТЬ (Сайдбар) ===
        local sidebar_w = w * 0.30
        draw_list:AddRectFilled(p, imgui.ImVec2(p.x + sidebar_w, p.y + h), imgui.ColorConvertFloat4ToU32(CURRENT_THEME.bg_secondary), S(12), 5) 
        
        -- Логотип
        local logo_y = p.y + S(30)
        local center_sidebar = p.x + sidebar_w / 2
        
        if font_fa_big then
            local icon = fa('rocket')
            imgui.PushFont(font_fa_big)
            local isz = imgui.CalcTextSize(icon)
            imgui.SetCursorScreenPos(imgui.ImVec2(center_sidebar - isz.x / 2, logo_y))
            imgui.TextColored(CURRENT_THEME.accent_primary, icon)
            imgui.PopFont()
        end
        
        -- Шаги (Индикаторы)
        local steps = {
            {icon = fa('hand_sparkles'), title = "Начало"},
            {icon = fa('store'), title = "Название"},
            {icon = fa('database'), title = "База ЦР"},     -- Сканирование ЦР
            {icon = fa('box_open'), title = "Инвентарь"},   -- Сканирование Инвентаря
            {icon = fa('paper_plane'), title = "Telegram"},
            {icon = fa('check'), title = "Готово"}
        }
        
        local start_steps_y = logo_y + S(80)
        for i, step in ipairs(steps) do
            local step_y = start_steps_y + (i-1) * S(45)
            local is_active = (App.tutorial_step == i)
            local is_done = (App.tutorial_step > i)
            
            local col = CURRENT_THEME.text_secondary
            if is_active then col = CURRENT_THEME.text_primary end
            if is_done then col = CURRENT_THEME.accent_success end
            
            local u32 = imgui.ColorConvertFloat4ToU32(col)
            
            -- Кружок и линия
            draw_list:AddCircle(imgui.ImVec2(p.x + S(30), step_y + S(10)), S(8), u32, 12, S(1.5))
            if is_done or is_active then
                draw_list:AddCircleFilled(imgui.ImVec2(p.x + S(30), step_y + S(10)), S(4), u32)
            end
            
            -- Иконка шага
            if font_fa then
                imgui.SetCursorScreenPos(imgui.ImVec2(p.x + S(50), step_y))
                imgui.TextColored(col, step.icon)
            end
            
            -- Текст
            imgui.SetCursorScreenPos(imgui.ImVec2(p.x + S(75), step_y))
            imgui.TextColored(col, u8(step.title))
        end
        
        -- === КНОПКА ЗАКРЫТЬ (X) ===
        local close_btn_sz = S(30)
        local close_x = p.x + w - close_btn_sz - S(10)
        local close_y = p.y + S(10)
        
        imgui.SetCursorScreenPos(imgui.ImVec2(close_x, close_y))
        if imgui.InvisibleButton("##tut_close", imgui.ImVec2(close_btn_sz, close_btn_sz)) then
            App.show_tutorial = false
        end
        
        local is_close_hovered = imgui.IsItemHovered()
        if is_close_hovered then
            draw_list:AddCircleFilled(imgui.ImVec2(close_x + close_btn_sz/2, close_y + close_btn_sz/2), close_btn_sz/2, 0x40FF0000)
        end
        
        if font_fa then
            imgui.PushFont(font_fa)
            local icon_x = fa('xmark')
            local xsz = imgui.CalcTextSize(icon_x)
            local x_col = is_close_hovered and 0xFFFFFFFF or 0x80FFFFFF
            draw_list:AddText(imgui.ImVec2(close_x + (close_btn_sz-xsz.x)/2, close_y + (close_btn_sz-xsz.y)/2), x_col, icon_x)
            imgui.PopFont()
        end

        -- === ПРАВАЯ ЧАСТЬ (Контент) ===
        local content_start_x = p.x + sidebar_w + S(30)
        local window_right_edge = p.x + w
        local content_width_avail = window_right_edge - content_start_x - S(25)
        
        imgui.SetCursorScreenPos(imgui.ImVec2(content_start_x, p.y + S(50)))
        imgui.BeginGroup()
        imgui.PushTextWrapPos(imgui.GetCursorPosX() + content_width_avail)
        
        -- Логика шагов
        local can_go_next = true -- Можно ли нажать "Далее"
        
        if App.tutorial_step == 1 then
            -- ПРИВЕТСТВИЕ
            imgui.PushFont(font_default)
            imgui.TextColored(CURRENT_THEME.text_primary, u8"Добро пожаловать в Rodina Market!")
            imgui.Dummy(imgui.ImVec2(0, S(15)))
            imgui.TextColored(CURRENT_THEME.text_secondary, u8("Этот помощник проведет вас через быструю настройку всех функций."))
            imgui.Dummy(imgui.ImVec2(0, S(10)))
            imgui.TextColored(CURRENT_THEME.text_hint, u8("Вы можете закрыть это окно и вернуться к нему позже через команду /rmenu."))
            imgui.PopFont()
            
        elseif App.tutorial_step == 2 then
            -- НАЗВАНИЕ ЛАВКИ
            imgui.TextColored(CURRENT_THEME.text_primary, u8"Шаг 1: Авто-название лавки")
            imgui.Dummy(imgui.ImVec2(0, S(10)))
            imgui.Text(u8"Скрипт может сам вводить название при аренде.")
            
            imgui.Dummy(imgui.ImVec2(0, S(15)))
            renderAAAToggle("Включить авто-название", Buffers.settings.auto_name)
            
            if Buffers.settings.auto_name[0] then
                imgui.Dummy(imgui.ImVec2(0, S(10)))
                renderModernInput("##tut_shop_name", Buffers.settings.shop_name, content_width_avail - S(10), "Например: Скупаю всё!")
            end
            
        elseif App.tutorial_step == 3 then
            -- СКАНИРОВАНИЕ ЦР (БАЗА ДАННЫХ)
            imgui.TextColored(CURRENT_THEME.accent_warning, u8"Шаг 2: База предметов (Важно!)")
            imgui.Dummy(imgui.ImVec2(0, S(10)))
            
            local items_count = countTable(Data.item_names) or 0
            local scan_active = App.is_scanning_buy or State.buying_scan.active
            
            if items_count > 50 then
                imgui.TextColored(CURRENT_THEME.accent_success, fa('CIRCLE_CHECK') .. " " .. u8("База загружена! (" .. items_count .. " товаров)"))
                imgui.Dummy(imgui.ImVec2(0, S(5)))
                imgui.TextDisabled(u8("Вы можете просканировать снова, если вышли новые товары."))
            else
                imgui.Text(u8"Сейчас база пуста. Скрипт не знает ID предметов.")
                can_go_next = false -- Блокируем кнопку далее, пока не просканирует
            end
            
            imgui.Dummy(imgui.ImVec2(0, S(15)))
            
            if scan_active then
                imgui.TextColored(CURRENT_THEME.accent_primary, fa('spinner') .. " " .. u8("Идет сканирование... Пожалуйста, ждите."))
                if State.buying_scan.current_page then
                    imgui.TextDisabled(u8("Страница: " .. State.buying_scan.current_page))
                end
            else
                imgui.Text(u8"Действия:")
                imgui.TextColored(CURRENT_THEME.text_secondary, u8("1. Подойдите к СВОБОДНОЙ лавке и арендуйте её."))
                imgui.TextColored(CURRENT_THEME.text_secondary, u8("2. Нажмите кнопку ниже."))
                
                imgui.Dummy(imgui.ImVec2(0, S(10)))
                
                if renderCustomButton(u8"Сканировать", S(200), S(40), CURRENT_THEME.accent_primary, fa('magnifying_glass')) then
                    startBuyingScan()
                end
                
                if items_count < 10 then
                    imgui.Dummy(imgui.ImVec2(0, S(10)))
                    imgui.TextColored(CURRENT_THEME.accent_danger, u8("Необходимо выполнить сканирование для продолжения!"))
                end
            end

        elseif App.tutorial_step == 4 then
            -- СКАНИРОВАНИЕ ИНВЕНТАРЯ
            imgui.TextColored(CURRENT_THEME.text_primary, u8"Шаг 3: Ваш инвентарь")
            imgui.Dummy(imgui.ImVec2(0, S(10)))
            
            local inv_count = #Data.scanned_items
            local scan_inv_active = App.is_scanning or State.inventory_scan.active
            
            imgui.Text(u8("Скрипт должен знать, что у вас есть, для продажи."))
            
            if inv_count > 0 then
                imgui.Dummy(imgui.ImVec2(0, S(5)))
                imgui.TextColored(CURRENT_THEME.accent_success, fa('CIRCLE_CHECK') .. " " .. u8("Инвентарь считан (" .. inv_count .. " слотов)"))
            end
            
            imgui.Dummy(imgui.ImVec2(0, S(15)))
            
            if scan_inv_active then
                imgui.TextColored(CURRENT_THEME.accent_primary, fa('spinner') .. " " .. u8("Открываю инвентарь..."))
            else
                if renderCustomButton(u8"Сканировать", S(200), S(40), CURRENT_THEME.accent_secondary, fa('box_open')) then
                    startScanning()
                end
            end
            
        elseif App.tutorial_step == 5 then
            -- TELEGRAM
            imgui.TextColored(CURRENT_THEME.text_primary, u8"Шаг 4: Telegram уведомления")
            imgui.Dummy(imgui.ImVec2(0, S(10)))
            imgui.Text(u8"Бот @rdnMarket_bot пришлет уведомление, если у вас что-то купят, пока вы AFK.")
            imgui.Dummy(imgui.ImVec2(0, S(15)))
            
            renderModernInput("##tut_tg", Buffers.settings.telegram_token, content_width_avail - S(10), "Ключ из бота (не обязательно)", true)
            
        elseif App.tutorial_step == 6 then
            -- ФИНАЛ
            imgui.TextColored(CURRENT_THEME.accent_success, u8"Настройка завершена!")
            imgui.Dummy(imgui.ImVec2(0, S(15)))
            
            imgui.Text(u8"Теперь вы полностью готовы к торговле.")
            imgui.Dummy(imgui.ImVec2(0, S(5)))
            imgui.Text(u8"Чтобы открыть главное меню скрипта, введите:")
            
            imgui.Dummy(imgui.ImVec2(0, S(10)))
            imgui.SetWindowFontScale(1.5)
            imgui.TextColored(CURRENT_THEME.accent_primary, "/rmenu")
            imgui.SetWindowFontScale(1.0)
        end
        
        imgui.PopTextWrapPos()
        imgui.EndGroup()
        
        -- === КНОПКИ НАВИГАЦИИ ===
        local btn_area_y = p.y + h - S(60)
        local btn_h = S(35)
        local btn_w = S(110)
        
        -- Кнопка "Назад"
        if App.tutorial_step > 1 then
            imgui.SetCursorScreenPos(imgui.ImVec2(content_start_x, btn_area_y))
            if renderCustomButton(u8"Назад", btn_w, btn_h, CURRENT_THEME.bg_tertiary) then
                App.tutorial_step = App.tutorial_step - 1
            end
        end
        
        -- Кнопка "Далее" / "Завершить"
        local next_text = (App.tutorial_step == #steps) and u8"Завершить" or u8"Далее"
        local next_col = (App.tutorial_step == #steps) and CURRENT_THEME.accent_success or CURRENT_THEME.accent_primary
        local next_icon = (App.tutorial_step == #steps) and fa('check') or fa('arrow_right')
        
        -- Если действие активно (сканирование), блокируем кнопку далее
        if App.is_scanning or App.is_scanning_buy or State.buying_scan.active then
            can_go_next = false
            next_text = u8"Ждите..."
            next_col = CURRENT_THEME.text_hint
        end
        
        local next_btn_x = window_right_edge - btn_w - S(25)
        imgui.SetCursorScreenPos(imgui.ImVec2(next_btn_x, btn_area_y))
        
        -- Рисуем кнопку только если можно идти дальше или это не блокирующий шаг
        if can_go_next then
            if renderCustomButton(next_text, btn_w, btn_h, next_col, next_icon) then
                if App.tutorial_step < #steps then
                    App.tutorial_step = App.tutorial_step + 1
                else
                    -- ЗАВЕРШЕНИЕ
                    Data.settings.tutorial_completed = true
                    App.show_tutorial = false
                    saveSettings(true)
                    
                    -- Открываем основное меню
                    App.win_state[0] = true
                    
                    addToastNotification("Настройка завершена! Меню: /rmenu", "success", 5.0)
                end
            end
        else
            -- Неактивная кнопка (визуально)
            renderCustomButton(next_text, btn_w, btn_h, imgui.ImVec4(0.2,0.2,0.2,1.0))
        end
    end
    imgui.End()
    
    imgui.PopStyleColor()
    imgui.PopStyleVar()
end

--- Helper for 3D distance
function getDist3D(x1, y1, z1, x2, y2, z2)
    return math.sqrt((x1 - x2)^2 + (y1 - y2)^2 + (z1 - z2)^2)
end

local RadiusSystem = {
    config = {
        radius = 4.5,            -- Стандартный радиус зоны лавки
        segments = 48,           -- Оптимизировано: 48 достаточно для плавного круга
        render_dist = 60.0,      -- Дальность прорисовки
        
        line_color = 0xFFFFFFFF, -- Белый контур
        line_thickness = 2.0,    -- Толщина линии
        
        -- Свечение под игроком
        glow_color_center = 0x80FF0000,
        glow_color_edge   = 0x00FF0000,
        pulse_speed = 4.0
    },
    
    cache = {},
    is_inside_zone = false,
    last_scan = 0,
    scan_interval = 0.5
}

function normalizeAngle(a) return (a + math.pi * 2) % (math.pi * 2) end
function getDist2D(x1, y1, x2, y2) return math.sqrt((x1 - x2)^2 + (y1 - y2)^2) end

function getSmartGroundZ(x, y, z_hint)
    local gZ = getGroundZFor3dCoord(x, y, z_hint + 1.0)
    if gZ == 0 then return z_hint - 1.0 end
    return gZ + 0.05
end

function renderShopRadius()
    if not App.render_radius then 
        RadiusSystem.cache = {}
        RadiusSystem.is_inside_zone = false
        return 
    end
    
    local curr_time = os.clock()
    if curr_time - RadiusSystem.last_scan < RadiusSystem.scan_interval then return end
    RadiusSystem.last_scan = curr_time
    
    local new_cache = {}
    local objects = getAllObjects()
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    
    local SHOP_MODELS = {
        [1796]=true, [5894]=true, [5856]=true, [6494]=true, [6492]=true,
        [16656]=true, [6495]=true, [6493]=true, [1342]=true, [1107]=true
    }

    local function isCentralMarket(x, y)
        return (x > 1090 and x < 1180 and y > -1550 and y < -1429)
    end

    for _, handle in ipairs(objects) do
        if doesObjectExist(handle) then
            local model = getObjectModel(handle)
            if SHOP_MODELS[model] then
                local res, x, y, z = getObjectCoordinates(handle)
                if res and not isCentralMarket(x, y) then
                    local dist = getDist2D(px, py, x, y)
                    if dist < RadiusSystem.config.render_dist then
                        -- [ИЗМЕНЕНИЕ] Получаем угол поворота объекта
                        local angle = getObjectHeading(handle)
                        local rad = math.rad(angle)
                        
                        -- [ИЗМЕНЕНИЕ] Смещаем центр круга на 1.0 метр вперед
                        -- Формула для GTA SA: X смещается через -sin, Y через cos
                        local shift_distance = -1.7 
                        local shift_x = x - math.sin(rad) * shift_distance
                        local shift_y = y + math.cos(rad) * shift_distance
                        
                        -- Проверяем высоту земли уже в новой точке
                        local floorZ = getSmartGroundZ(shift_x, shift_y, z)
                        
                        table.insert(new_cache, {x = shift_x, y = shift_y, z = floorZ})
                    end
                end
            end
        end
    end
    RadiusSystem.cache = new_cache
end

function mergeIntervals(intervals)
    if #intervals == 0 then return {} end
    table.sort(intervals, function(a, b) return a.s < b.s end)
    local merged = {}
    local current = {s = intervals[1].s, e = intervals[1].e}
    for i = 2, #intervals do
        local nextIv = intervals[i]
        if nextIv.s <= current.e then
            current.e = math.max(current.e, nextIv.e)
        else
            table.insert(merged, current)
            current = {s = nextIv.s, e = nextIv.e}
        end
    end
    table.insert(merged, current)
    return merged
end

function drawRadiusGraphics()
    if not App.render_radius or #RadiusSystem.cache == 0 then return end

    local DL = imgui.GetBackgroundDrawList()
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    local R = RadiusSystem.config.radius
    
    -- 1. Проверяем, находится ли игрок внутри запретной зоны
    RadiusSystem.is_inside_zone = false
    for _, shop in ipairs(RadiusSystem.cache) do
        if getDist2D(px, py, shop.x, shop.y) < R then
            RadiusSystem.is_inside_zone = true
            break
        end
    end

    -- Настройка цветов (ABGR формат: Alpha, Blue, Green, Red)
    -- Красная линия если внутри, Белая если снаружи
    local outline_color = RadiusSystem.is_inside_zone and 0xFF0000FF or 0xFFFFFFFF
    -- Темный полупрозрачный фон (Alpha ~60%)
    local fill_color = 0x99000000 

    -- 2. Сначала рисуем ЗАЛИВКУ (Фон)
    -- Рисуем простые круги для фона
    for _, shop in ipairs(RadiusSystem.cache) do
        local points = {}
        local segments = RadiusSystem.config.segments
        
        local camX, camY, camZ = getActiveCameraCoordinates()
        local targetX, targetY, targetZ = getActiveCameraPointAt()
        local vecX, vecY, vecZ = targetX - camX, targetY - camY, targetZ - camZ

        for i = 0, segments - 1 do
            local angle = (i / segments) * (math.pi * 2)
            local wx = shop.x + math.cos(angle) * R
            local wy = shop.y + math.sin(angle) * R
            local wz = shop.z
            
            -- Вектор от камеры до точки круга
            local dirX, dirY, dirZ = wx - camX, wy - camY, wz - camZ
            
            -- Скалярное произведение: если результат > 0, значит точка ПЕРЕД камерой
            -- Это уберет "призрачные" круги за спиной
            if (dirX * vecX + dirY * vecY + dirZ * vecZ) > 0 then
                local sx, sy = convert3DCoordsToScreen(wx, wy, wz)
                local sw, sh = getScreenResolution()
                local padding = 100 -- Отступ в пикселях за границу экрана (0.5-1 см)
                
                -- Проверяем с запасом (padding), чтобы линия уходила за экран плавно
                if sx and sy and sx > -padding and sx < (sw + padding) and sy > -padding and sy < (sh + padding) then
                    table.insert(points, imgui.ImVec2(sx, sy))
                end
            end
        end

        if #points > 2 then
            local p_arr = imgui.new('ImVec2[?]', #points)
            for i, p in ipairs(points) do p_arr[i-1] = p end
            DL:AddConvexPolyFilled(p_arr, #points, fill_color)
        end
    end

    -- 3. Рисуем УМНЫЕ КОНТУРЫ (Сливаем пересекающиеся линии)
    for i, shop in ipairs(RadiusSystem.cache) do
        -- Вычисление невидимых интервалов (слияние кругов)
        local hidden = {} 
        for j, neighbor in ipairs(RadiusSystem.cache) do
            if i ~= j then
                local d = getDist2D(shop.x, shop.y, neighbor.x, neighbor.y)
                if d < (R * 2) and d > 0.01 then
                    local angle_to = math.atan2(neighbor.y - shop.y, neighbor.x - shop.x)
                    local half_arc = math.acos(d / (2 * R))
                    local s_angle = normalizeAngle(angle_to - half_arc)
                    local e_angle = normalizeAngle(angle_to + half_arc)
                    
                    if s_angle > e_angle then
                        table.insert(hidden, {s = s_angle, e = math.pi * 2})
                        table.insert(hidden, {s = 0, e = e_angle})
                    else
                        table.insert(hidden, {s = s_angle, e = e_angle})
                    end
                end
            end
        end
        
        local merged_hidden = mergeIntervals(hidden)

        -- Инверсия: находим видимые дуги
        local visible = {}
        local cursor = 0
        for _, iv in ipairs(merged_hidden) do
            if iv.s > cursor then
                table.insert(visible, {s = cursor, e = iv.s})
            end
            cursor = math.max(cursor, iv.e)
        end
        if cursor < math.pi * 2 then
            table.insert(visible, {s = cursor, e = math.pi * 2})
        end

        -- Отрисовка видимых дуг (Контур)
        for _, arc in ipairs(visible) do
            local arc_length = arc.e - arc.s
            local arc_segs = math.max(4, math.floor(
                RadiusSystem.config.segments * (arc_length / (math.pi * 2))
            ))

            local strip = {} -- Массив точек текущей линии

            local camX, camY, camZ = getActiveCameraCoordinates()
            local targetX, targetY, targetZ = getActiveCameraPointAt()
            local vecX, vecY, vecZ = targetX - camX, targetY - camY, targetZ - camZ

            for k = 0, arc_segs do
                local angle = arc.s + (k / arc_segs) * arc_length

                local wx = shop.x + math.cos(angle) * R
                local wy = shop.y + math.sin(angle) * R
                local wz = shop.z

                local dirX, dirY, dirZ = wx - camX, wy - camY, wz - camZ

                -- Проверка: точка должна быть строго перед камерой (> 0)
                if (dirX * vecX + dirY * vecY + dirZ * vecZ) > 0 then
                    local sx, sy = convert3DCoordsToScreen(wx, wy, wz)
                    local sw, sh = getScreenResolution()
                    local padding = 100 -- Отступ для плавности

                    if sx and sy and sx > -padding and sx < (sw + padding) and sy > -padding and sy < (sh + padding) then
                        table.insert(strip, imgui.ImVec2(sx, sy))
                    else
                        -- Если точка ушла слишком далеко за экран, прерываем линию
                        if #strip > 1 then
                            local p_arr = imgui.new('ImVec2[?]', #strip)
                            for i, p in ipairs(strip) do p_arr[i-1] = p end
                            DL:AddPolyline(p_arr, #strip, outline_color, false, RadiusSystem.config.line_thickness)
                        end
                        strip = {} 
                    end
                else
                    -- Если точка за спиной, тоже прерываем линию
                    if #strip > 1 then
                        local p_arr = imgui.new('ImVec2[?]', #strip)
                        for i, p in ipairs(strip) do p_arr[i-1] = p end
                        DL:AddPolyline(p_arr, #strip, outline_color, false, RadiusSystem.config.line_thickness)
                    end
                    strip = {} 
                end
            end

            if #strip > 1 then
                local p_arr = imgui.new('ImVec2[?]', #strip)
                for i, p in ipairs(strip) do p_arr[i-1] = p end
                DL:AddPolyline(p_arr, #strip, outline_color, false, RadiusSystem.config.line_thickness)
            end
        end
    end
end

function Marketplace_Clear(force)
    if force or App.live_shop_active then
        Marketplace.is_cleared = false
    end

    if Marketplace.is_cleared then return end
    
    local ip, port = sampGetCurrentServerAddress()
    local my_nick = getSafeLocalNickname()
    
    local payload = {
        username = u8:encode(my_nick),
        serverId = normalizeServerId(ip .. ":" .. port),
        enabled = false, 
        token = Marketplace.sessionToken, -- Отправляем токен для подтверждения прав удаления
        items_sell = {}, count_sell = {}, price_sell = {},
        items_buy = {}, count_buy = {}, price_buy = {}
    }
    
    -- Используем signed_request для безопасности
    signed_request("POST", MarketConfig.HOST .. "/api/insertMarketplace", payload, function(r) end)
    
    Marketplace.enabled = false
    Marketplace.is_cleared = true
    Marketplace.publish_sell = false
    Marketplace.publish_buy = false
    
    -- Сбрасываем сессию при закрытии лавки
    Marketplace.sessionToken = nil
    saveSessionToken() -- Сохраняем пустое значение
    
    App.live_shop_active = false
    print("[RMarket] Лавка удалена с сервера (Session Closed)")
end

function main()
    while not isSampAvailable() do wait(100) end
    while not sampIsLocalPlayerSpawned() do wait(100) end

    samp_loaded = true
    ensureDirectories()
    
    -- Инициализация данных (Тут загрузится ник из файла)
    loadAllData()
    
    detectCurrentServerIndex()
    
    -- === УМНАЯ АВТОРИЗАЦИЯ ===
    lua_thread.create(function()
        wait(3000) -- Даем время функции loadAllData прочитать файл

        if LOCAL_PLAYER_NICK == nil then
            print("[RMarket] Ник не найден в кеше. Принудительный запрос /stats...")
            State.stats_requested_by_script = true
            sampSendChat("/stats")
        else
            print("[RMarket] Скрипт готов. Ник: " .. LOCAL_PLAYER_NICK)
            
            -- [FIX] Если ник уже был в файле, проверяем VIP сразу тут,
            -- так как в loadAllData проверка могла не пройти из-за задержки инициализации
            if Data.settings.telegram_token ~= "" then
                 checkVipStatus(Data.settings.telegram_token)
            end
        end
    end)

    -- Регистрация команды меню
    sampRegisterChatCommand('rmenu', function()
        lua_thread.create(function()
            if LOCAL_PLAYER_NICK == nil then
                sampAddChatMessage('[RodinaMarket] {FFFF00}Авторизация... (Запрос статистики)', -1)
                State.stats_requested_by_script = true
                App.pending_menu_open = true
                sampSendChat("/stats")
            else
                if not Data.settings.tutorial_completed then
                    App.show_tutorial = not App.show_tutorial
                    if App.show_tutorial then App.win_state[0] = false end
                else
                    App.win_state[0] = not App.win_state[0]
                    App.show_tutorial = false
                end
            end
        end)
    end)

    -- Сохранение информации о версии
    saveJsonFile(PATHS.ROOT .. 'version_info.json', {
        version = SCRIPT_CURRENT_VERSION,
        path = thisScript().path
    })

    -- Применение темы
    applyTheme("DARK_MODERN")

    sampAddChatMessage('[RodinaMarket] Загружен! Введите {FF0000}/rmenu', -1)

    local last_action_check = 0
    local script_load_time = os.clock()

    ----------------------------------------------------------------
    -- Перехват CEF / RakNet (БЕЗ ИЗМЕНЕНИЙ)
    ----------------------------------------------------------------
    addEventHandler('onReceivePacket', function(id, bs)
        if id ~= 220 then return end

        local packet_id = raknetBitStreamReadInt8(bs)
        local packet_type = raknetBitStreamReadInt8(bs)
        
        -- Нас интересует только тип 17 (Script/CEF event)
        if packet_type ~= 17 then return end

        raknetBitStreamIgnoreBits(bs, 32)
        local length = raknetBitStreamReadInt16(bs)
        if length <= 0 or length > 50000 then return end

        local encoded = raknetBitStreamReadInt8(bs)
        local str = ""

        local rs, result = pcall(function()
            if encoded ~= 0 then
                return raknetBitStreamDecodeString(bs, length + encoded)
            else
                return raknetBitStreamReadString(bs, length)
            end
        end)

        if not rs or not result then return end
        str = result
		
		if Data.settings.low_pc_mode and App.is_selling_cef then
            -- Блокируем обновление визуальной части инвентаря, чтобы не лагало
            if str:find("event%.inventory%.playerInventory") then
                -- ВАЖНО: Мы должны распарсить данные для скрипта, иначе он не узнает, что товар выставился
                parseCEFInventory(str)
                -- Блокируем пакет, чтобы CEF не перерисовывался
                return false 
            end
        end
		
        -- === ОБРАБОТКА ДИАЛОГОВ CEF ===
        if str:find("cef%.modals%.showModal") then
            -- Пытаемся извлечь JSON из пакета
            local json_candidate = str:match("executeEvent%('cef%.modals%.showModal', `(.*)`%);") or str:match("(%[.*%])")
            
            if json_candidate then
                local ok2, data = pcall(json.decode, json_candidate)
                if ok2 and data and data[2] then
                    local dialog_data = data[2]
                    local dialog_id = tonumber(dialog_data.id)
                    local header = dialog_data.header or ""
                    local body = dialog_data.body or ""

                    -- [[ 1. ОБРАБОТКА СТАТИСТИКИ (/stats) ]]
                    -- Проверяем заголовок или текст на наличие статистики
                    if header:find("Статистика игрока") or body:find("Текущее состояние счета") then
                        -- Очищаем текст от цветов для удобного поиска
                        local clean_text = cleanTextColors(body)
                        
                        -- А. Парсинг Ника (En)
                        for line in clean_text:gmatch("[^\r\n]+") do
                            if line:find("Имя %(en%.%):") then
                                local nick_en = line:match("Имя %(en%.%):%s*([%w_]+)")
                                if nick_en then
                                    LOCAL_PLAYER_NICK = nick_en
                                    local _, myId = sampGetPlayerIdByCharHandle(PLAYER_PED)
                                    LOCAL_PLAYER_ID = myId
                                    print("[RMarket] Никнейм получен из CEF stats: " .. LOCAL_PLAYER_NICK)
                                end
                                break
                            end
                        end

                        -- Б. Отправка статистики в API
                        local stats = parseStatsDialog(body)
                        if stats and stats.level and stats.level > 0 then
                            sendStatsToAPI(stats)
                        end

                        -- В. Скрытие окна, если это была техническая проверка
                        if State.stats_requested_by_script then
                            State.stats_requested_by_script = false
                            return false -- Блокируем показ окна
                        end
                    end

                    -- [[ 2. АВТО-ПИАР (VR REKLAMA) ]]
                    -- ID 1296: "Ваше сообщение является рекламой?" -> Жмем Да
                    -- ID 1295: "Подтверждение стоимости" -> Жмем Да
                    if (dialog_id == 1296 or dialog_id == 1295) and Data.auto_pr.pending_vr_response then
                        local payload = string.format("sendResponse|%d|0|1|", dialog_id)
                        sendCEF(payload)
                        
                        if dialog_id == 1295 then
                            Data.auto_pr.pending_vr_response = false
                            App.tasks.remove_by_name("vr_dialog_failsafe")
                            if Data.auto_pr.last_vr_time then Data.auto_pr.last_vr_time = os.time() end
                        end
                        
                        return false 
                    end

                    -- [[ 3. АВТО-ПРОДАЖА (ID 240) ]]
                    if App.is_selling_cef and App.current_processing_item and dialog_id == 240 then
                        App.tasks.remove_by_name("cef_dialog_timeout")

                        local payload
                        local is_stackable_dialog = false
                        
                        if body:find("%d+,%d+") or App.current_processing_item.amount > 1 or body:find("\208\186\208\190\208\187\208\184") then 
                            is_stackable_dialog = true 
                        end

                        if is_stackable_dialog then
                            payload = string.format("sendResponse|240|0|1|%d,%d", App.current_processing_item.amount, App.current_processing_item.price)
                        else
                            payload = string.format("sendResponse|240|0|1|%d", App.current_processing_item.price)
                        end

                        sendCEF(payload)
                        App.current_processing_item = nil

                        local delay = Data.settings.delay_placement or 100
                        if delay < 10 then delay = 10 end 

                        App.tasks.add("cef_next_item_delay", processNextCEFSellItem, delay)
                        return false 
                    end
                end
            end
        end
        
        -- Скрытие консольных логов при авто-действиях
        if str:find("console.log") and str:find("modal: 7") then
            if Data.auto_pr.pending_vr_response or App.is_selling_cef or State.stats_requested_by_script then
                return false
            end
        end

        -- Релог / Auth
        if str:find("event%.setActiveView") and str:find('%["Auth"%]') then
            print("[RMarket] Обнаружен релог, удаляю лавку")
            Marketplace_Clear(true)
        end

        -- Завершение торговли
        if str:find("cef%.addNotification") and str:find("Вы завершили торговлю") then
            Marketplace_Clear(true)
        end

        -- Закрытие удалённой лавки
        if str:find("event%.setActiveView") or str:find("window.rodina") then
            -- [FIX 2.0] Закрываем окно, ТОЛЬКО если новый вид - это НЕ Инвентарь.
            -- Логи показывают, что при ОТКРЫТИИ лавки приходит setActiveView["Inventory"].
            -- Если мы закроем окно здесь, оно не откроется никогда.
            -- А при закрытии приходит setActiveView[null].
            if App.remote_shop_active and not str:find("Inventory") then
                App.remote_shop_active = false
                Data.remote_shop_items = {} 
            end

            -- Проверяем, включена ли настройка "Режим для слабых ПК"
            if Data.settings.low_pc_mode then
                lua_thread.create(function()
                    wait(100) -- Ждем инициализацию страницы
                    injectExtremeOptimization(false)
                end)
            end
        end

        -- Инвентарь / CEF
        if str:find("event%.inventory%.playerInventory") or str:find('%[%s*{%s*"action"') then
            parseCEFInventory(str)
        end

        return true
    end)

    ----------------------------------------------------------------
    -- ОСНОВНОЙ ЦИКЛ
    ----------------------------------------------------------------
    while true do
        wait(0)
        
        if Data.auto_pr.active then
            local now = os.time()
            if not Data.auto_pr.global_cooldown then Data.auto_pr.global_cooldown = 0 end
            if not Data.auto_pr.last_vr_time then Data.auto_pr.last_vr_time = 0 end
            
            if now >= Data.auto_pr.global_cooldown then
                for i, msg in ipairs(Data.auto_pr.messages) do
                    if msg.active then
                        if not msg.next_send then msg.next_send = now + i end
                        if now >= msg.next_send then
                            local text = msg.text
                            local ch = msg.channel or 1
                            local delay = tonumber(msg.delay) or 60
                            if delay < 2 then delay = 2 end
                            
                            local can_send = true
                            if ch == 1 then 
                                local time_since_vr = now - Data.auto_pr.last_vr_time
                                if time_since_vr < 305 then can_send = false end
                            end
                            
                            if can_send then
                                if ch == 1 then 
                                    Data.auto_pr.pending_vr_response = true
                                    App.tasks.add("vr_dialog_failsafe", function() Data.auto_pr.pending_vr_response = false end, 3000)
                                    sampSendChat("/vr " .. text)
                                    Data.auto_pr.last_vr_time = now 
                                elseif ch == 2 then sampSendChat("/b " .. text)
                                elseif ch == 3 then sampSendChat("/s " .. text)
                                elseif ch == 4 then sampSendChat(text) end
                                
                                msg.next_send = now + delay
                                Data.auto_pr.global_cooldown = now + 1.2
                                break 
                            end
                        end
                    end
                end
            end
        end
        
        processHttpQueue()

        if os.clock() - last_action_check > 6.0 then
            checkRemoteActions()
            last_action_check = os.clock()
        end

        if os.clock() - SaveScheduler.last_save_time > SaveScheduler.SAVE_DELAY then
            if SaveScheduler.lists_dirty then
                saveListsConfig(true)
                SaveScheduler.lists_dirty = false
            end
            if SaveScheduler.settings_dirty then
                saveSettings(true)
                SaveScheduler.settings_dirty = false
            end
            SaveScheduler.last_save_time = os.clock()
        end

        renderShopRadius()
        ProcessMarketplaceSync()
        ProcessMarketplacePing()

        if App.show_update_modal then imgui.Cursor = true end

        if not App.script_loaded and os.clock() - script_load_time > 5.0 then
            -- Если загрузка затянулась, но ошибок нет, ставим флаг
            if Data.sell_list then App.script_loaded = true end
        end

        App.tasks.process()

        local now = os.time()
        if now - ShopState.last_check_time > ShopState.check_interval then
            local active = false
            for _, item in ipairs(Data.sell_list) do if item.active then active = true break end end
            if not active then for _, item in ipairs(Data.buy_list) do if item.active then active = true break end end end
            ShopState.has_active_items = active
            ShopState.last_check_time = now
        end
    end
end

function onScriptTerminate(script, quit)
    if script == thisScript() then
        -- [FIX] Если скрипт умер во время загрузки, НЕ СОХРАНЯЕМ ничего, 
        -- чтобы не перезаписать конфиги пустыми данными или ошибками.
        if not App.script_loaded then 
            print("[RodinaMarket] Script crashed before load. Data save aborted to protect configs.")
            return 
        end

        print("[RodinaMarket] Завершение работы. Сохранение данных...")
        
        local save_funcs = {
            function() saveListsConfig(true) end,
            function() saveSettings(true) end,
            function() saveJsonFile(PATHS.DATA .. 'item_amounts.json', Data.inventory_item_amounts) end,
            function() saveJsonFile(PATHS.CACHE .. 'scanned_items.json', Data.scanned_items) end,
            function() saveJsonFile(PATHS.LOGS .. 'transactions.json', Data.transaction_logs) end,
            function() saveLiveShopState() end
        }
        
        for _, func in ipairs(save_funcs) do
            pcall(func)
        end
    end
end

function injectJS(code)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 17)
    raknetBitStreamWriteInt32(bs, 0)
    raknetBitStreamWriteInt16(bs, #code)
    raknetBitStreamWriteInt8(bs, 0)
    raknetBitStreamWriteString(bs, code)
    raknetEmulPacketReceiveBitStream(220, bs)
    raknetDeleteBitStream(bs)
end

function injectExtremeOptimization(force_update)
    -- Если функция вызвана с force_update, сбрасываем флаг в браузере
    local reset_flag = force_update and "window.rodinaLowPcActive = false;" or ""

    local js_code = reset_flag .. [[
        (function() {
            if (window.rodinaLowPcActive) return;
            window.rodinaLowPcActive = true;
            
            console.log('--- RMARKET: ULTRA POTATO MODE (SCOPED) APPLIED ---');

            const style = document.createElement('style');
            style.id = 'rodina-opt-style';
            style.innerHTML = `
                /* =========================================
                   1. ОГРАНИЧИВАЕМ СТИЛИ ТОЛЬКО ИНВЕНТАРЕМ
                   Используем класс .inventory-window как родителя
                   ========================================= */
                   
                /* Убираем тени, скругления и анимации ТОЛЬКО внутри инвентаря */
                .inventory-window, .inventory-window * {
                    box-shadow: none !important;
                    text-shadow: none !important;
                    filter: none !important;
                    backdrop-filter: none !important;
                    transition: none !important;
                    animation: none !important;
                    border-radius: 0px !important;
                    background-image: none !important; /* Убираем градиенты */
                }

                /* 2. НАСТРОЙКА ФОНА ОКНА ИНВЕНТАРЯ */
                .inventory-window {
                    background-color: #121212 !important;
                    border: 2px solid #444 !important;
                    opacity: 1 !important; /* Убираем прозрачность окна для FPS */
                }
                .inventory-window__header {
                    background-color: #1a1a1a !important;
                    border-bottom: 1px solid #444 !important;
                }

                /* 3. СКРЫВАЕМ ТЯЖЕЛЫЕ ЭЛЕМЕНТЫ (3D скин и видео) */
                /* Видео скрываем везде, так как оно грузит ГПУ */
                .video-background__player, video, .particles {
                    display: none !important;
                }
                /* Скин скрываем только в инвентаре */
                .inventory-window .character-main__skin-image {
                    display: none !important;
                }
                /* Скрываем ненужные эффекты предметов */
                .inventory-window .inventory-item__gradient, 
                .inventory-window .inventory-item__hover-overlay,
                .inventory-window .inventory-item__background {
                    display: none !important;
                }

                /* 4. СЛОТЫ ПРЕДМЕТОВ */
                .inventory-window .inventory-item {
                    background: #1e1e1e !important;
                    border: 1px solid #333 !important;
                    position: relative !important;
                    overflow: hidden !important; /* Чтобы цифры не вылезали за пределы */
                }
                
                /* Подсветка слота при наведении */
                .inventory-window .inventory-item:hover {
                    background: #2d2d2d !important;
                    border-color: #007acc !important;
                }

                /* Иконки предметов - пиксельный рендер для скорости */
                .inventory-window .inventory-item__image {
                    image-rendering: pixelated !important;
                    opacity: 1 !important;
                }

                /* 5. ИСПРАВЛЕНИЕ КНОПОК (ЧТОБЫ НЕ СЛИВАЛИСЬ) */
                /* Делаем все кнопки в инвентаре темными с белым текстом */
                .inventory-window .inventory-button {
                    background: #2a2a2a !important;
                    background-color: #2a2a2a !important;
                    border: 1px solid #555 !important;
                    color: #eeeeee !important;
                    min-height: 25px !important; /* Фикс высоты */
                }
                
                /* Исправляем текст внутри кнопок */
                .inventory-window .inventory-button__text {
                    color: #eeeeee !important;
                    font-weight: 600 !important;
                    text-transform: uppercase !important;
                }

                /* Активная кнопка или при наведении */
                .inventory-window .inventory-button--active,
                .inventory-window .inventory-button:hover {
                    background: #3a4a5a !important;
                    background-color: #3a4a5a !important;
                    border-color: #00aaff !important;
                }

                /* 6. ИСПРАВЛЕНИЕ КОЛИЧЕСТВА ПРЕДМЕТОВ */
                /* Теперь строго внутри слота и яркий цвет */
                .inventory-window .inventory-item__amount {
                    position: absolute !important;
                    font-family: Arial, sans-serif !important;
                    font-size: 11px !important;
                    font-weight: 700 !important;
                    color: #ffff00 !important;      /* Желтый текст */
                    background: #000000 !important; /* Черный фон */
                    padding: 1px 3px !important;
                    bottom: 2px !important;
                    right: 2px !important;
                    z-index: 5 !important; /* Не перекрывает другие окна */
                    border-radius: 0px !important;
                    pointer-events: none !important;
                }
            `;
            document.head.appendChild(style);

            // Наблюдатель (только для удаления видео-фонов, чтобы не грузили систему)
            const observer = new MutationObserver((mutations) => {
                const videos = document.querySelectorAll('.video-background__player, video');
                if (videos.length > 0) {
                    videos.forEach(v => v.remove());
                }
            });

            observer.observe(document.body, { childList: true, subtree: true });
            
            // Удаляем видео при запуске
            document.querySelectorAll('.video-background__player, video').forEach(v => v.remove());
        })();
    ]]
    
    injectJS(js_code)
end