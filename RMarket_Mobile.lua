script_name("RMarket Mobile")
script_version("2.2")

require 'lib.moonloader'
require 'RakLua'
local Dependencies = {
    imgui = require 'mimgui',
    ffi = require 'ffi',
    encoding = require 'encoding',
    fa = require 'fAwesome6',
    lfs = require 'lfs',
    cjson = require 'cjson',
    raknet = require 'lib.samp.raknet',
    events = require 'lib.samp.events',
    bit = require 'bit',
    effil = require 'effil'
}
Dependencies.encoding.default = 'CP1251'
Dependencies.u8 = Dependencies.encoding.UTF8

local Settings = {
    auto_name = false,
    shop_name = "Rodina Market",
    api_key = "",
    auto_pr = { active = false, items = {} },
    win_w_percent = 0.90,
    win_h_percent = 0.90,
    ui_scale = 1.0
}
local State = {
    update = { available = false, version = "", url = "", text = "" },
    stats_requested = false,
    silent_stats = false,
    pending_nickname_bind_check = false,
    pending_test_tg = nil,
    auto_pr = { global_cooldown = 0, last_vr_time = 0, pending_vr_response = false },
    inventory_scan = { active = false, stage = "" },
    selling = { active = false, stage = "", current_idx = 1, total = 0, current_item = nil, available_items = {}, last_packet_time = 0 },
    buying = { active = false, stage = "", current_idx = 1, total = 0, current_item = nil },
    recent_transactions = {},
    show_db_modal = false,
    pending_scan_after_db = false,
    is_downloading_db = false,
    is_downloading_prices = false,
    is_terminating = false,
    last_inventory_scan_time = 0,
    last_disconnect_notif_time = 0,
    last_gamestate = -1,
    is_currently_disconnected = false,
    last_manual_buy_seller = nil,
    payday = { active = false, timer = 0, data = {} }
}
local ApiState = {
    key_valid = false,
    key_checked = false,
    token_state = "missing",
    checking = false,
    vip_checking_in_progress = false,
    vip_check_attempts = 0,
    last_check = 0,
    is_vip = false,
    server_vip_verified = false,
    vip_verified_nick = nil,
    vip_validated_at = 0,
    vip_days = 0,
    vip_months = 1,
    vip_expire = 0,
    vip_users_cache = {},
    authenticated_loads_started = false,
    pending_manual_price_download = false
}
local StateMarket = {
    is_loading = false,
    shops_list = {},
    selected_shop = nil,
    gps_active = false,
    gps_target = nil,
    current_server_id = "Unknown",
    server_filter_idx = 0,
    search_cache_key = nil,
    request_id = 0,
    loaded_snapshot_id = 0,
    loaded_snapshot_time = 0,
    loaded_snapshot_epoch = "",
    request_started_at = 0,
    loading_started_at = 0,
    loading_stage = "idle",
    loading_response_bytes = 0,
    request_silent = true,
    last_error = nil,
    refresh_failures = 0,
    next_auto_refresh_at = 0,
    last_fetch = 0,
    online_count = 0
}
local StateArbitrage = {
    is_loading = false,
    list = {},
    last_fetch = 0,
    last_error = nil,
    sub_tab = 1,
    tax_pct = 8,
    sort_mode = 1,
    blacklist = {},
    search_buf = Dependencies.ffi.new('char[128]')
}
local Marketplace = {
    enabled = false,
    owner_name = nil,
    current_shop_owner = nil,
    current_shop_id = -1,
    waiting_for_owner_id = false,
    last_updated_type = nil,
    last_packet_time = 0,
    remote_shop_items = {},
    username = "",
    server_id = "Unknown",
    session_token = "",
    lavka_uid = 0,
    sell = {},
    buy = {},
    sell_seen = false,
    buy_seen = false,
    is_cleared = true,
    publish_sell = false,
    publish_buy = false,
    dirty = false,
    sync_queued_at = 0,
    last_sync = 0,
    last_ping = 0,
    sync_interval = 15,
    ping_interval = 15,
    sync_in_progress = false,
    clear_pending = nil,
    clear_in_progress = false,
    clear_retry_at = 0,
    pending_cef = {}
}
local CloudSync = {
    needs_push = false,
    is_syncing = false,
    last_push = 0,
    status = "synced"
}
local Tasks = {
    list = {}
}
local cfg_modal = {
    active = false,
    item = nil,
    index = nil,
    is_sell = false,
    target_table = nil,
    buf_price = Dependencies.ffi.new('char[32]'),
    buf_amount = Dependencies.ffi.new('char[32]')
}
local touch_state = {
    start_pos = Dependencies.imgui.ImVec2(0, 0),
    is_dragging = false,
    col = 0,
    threshold = 10.0
}
local ui_cache_sell = { query = nil, items = {}, index = nil }
local ui_cache_buy = { query = nil, items = {}, index = nil }
local LogsState = {
    cached_income = 0,
    cached_expense = 0,
    today = { earned = 0, spent = 0, trades = 0, date = "" },
    logs_dates_cache = {},
    logs_current_date_idx = 0,
    current_view_logs = {}
}
local log_filters = {
    show_sales = Dependencies.imgui.new.bool(true),
    show_purchases = Dependencies.imgui.new.bool(true)
}
local THEME = {
    bg_main          = Dependencies.imgui.ImVec4(0.055, 0.070, 0.082, 1.00),
    bg_secondary     = Dependencies.imgui.ImVec4(0.090, 0.115, 0.130, 1.00),
    bg_tertiary      = Dependencies.imgui.ImVec4(0.135, 0.170, 0.185, 1.00),
    accent_primary   = Dependencies.imgui.ImVec4(0.12, 0.68, 0.67, 1.00),
    accent_success   = Dependencies.imgui.ImVec4(0.43, 0.77, 0.48, 1.00),
    accent_danger    = Dependencies.imgui.ImVec4(0.88, 0.34, 0.31, 1.00),
    text_primary     = Dependencies.imgui.ImVec4(0.96, 0.98, 0.97, 1.00),
    text_secondary   = Dependencies.imgui.ImVec4(0.62, 0.70, 0.71, 1.00),
    text_hint        = Dependencies.imgui.ImVec4(0.46, 0.55, 0.57, 1.00),
    border           = Dependencies.imgui.ImVec4(0.72, 0.84, 0.83, 0.12)
}
local SmartSearch = {}
local UI = {
    force_alt_sync_frames = 0,
    scale = 1.0,
    win_state = Dependencies.imgui.new.bool(false),
    active_tab = 1,
    active_sub_tab = 1,
    player_nickname = "",
    show_update_window = Dependencies.imgui.new.bool(false),
    pr_buffers = {},
    pr_delay_buffers = {},
    search_buf_sell = Dependencies.ffi.new('char[128]'),
    search_buf_buy = Dependencies.ffi.new('char[128]'),
    search_buf_market = Dependencies.ffi.new('char[128]'),
    search_focus_requested = false,
    unknown_server_warning_shown = false,
    undo_stack = {},
    undo_timer = 0,
    font_main = nil,
    font_fa = nil,
    font_fa_large = nil,
    inv_items = {},
    db_items = {},
    item_names = {},
    config_sell = nil,
    config_buy = nil,
    average_prices = nil,
    loaded_sets = nil,
    b_auto_name = nil,
    b_show_hud = nil,
    b_show_float = nil,
    buf_shop_name = nil,
    buf_api_key = nil,
    sl_delay = nil,
    is_checking_remote = false,
    LOWERCASE_MAP = {},
    hud_anim = { e = 0, s = 0 },
    hud_expanded = false,
    hud_dragged = false,
    float_btn_dragged = false,
    player_nickname_rus = "",
    account_id = 0,
    item_names_reversed = {},
    average_prices_by_id = {},
    daily_prices = {},
    market_search_results_buy = {},
    market_search_results_sell = {},
    ROOT_DIR = getWorkingDirectory() .. '/RMarket/',
    UPDATE_MANIFEST_URL = "https://raw.githubusercontent.com/RuRamzes/RodinaMarket/refs/heads/main/update.json",
    ITEM_PREFIXES = {
    "Улучшение оружия", "Унив. тюнинг", "Виз. тюнинг", "Тех. тюнинг", "Авто. номер",
    "Аксессуар", "Сертификат", "Приманка", "Саженец", "Улучшение",
    "Винила", "Объект", "Одежда", "Телефон", "Урожай", "Чертёж",
    "Предмет", "Актер", "Ларец", "Рыба", "Семя", "Туша", "Шкура", "Ящик"
    },
    RODINA_SERVERS_DATA = {
    { id = "Central",   name = "Центральный", ip = "185.169.134.163", port = "7777" },
    { id = "Southern",  name = "Южный",       ip = "185.169.134.60",  port = "8904" },
    { id = "Northern",  name = "Северный",    ip = "185.169.134.62",  port = "8904" },
    { id = "Eastern",   name = "Восточный",   ip = "185.169.134.108", port = "7777" },
    { id = "Western",   name = "Западный",    ip = "80.66.71.85",     port = "7777" },
    { id = "Primorsky", name = "Приморский",  ip = "80.66.82.58",     port = "7777" },
    { id = "Federal",   name = "Федеральный", ip = "80.66.82.55",     port = "7777" },
    { id = "Moscow",    name = "Москва",      ip = "80.66.82.25",     port = "7777", domain = "moscow.rodina-rp.com" },
    { id = "SPB",       name = "Санкт-Петербург", ip = "80.66.82.213", port = "7777", domain = "spb.rodina-rp.com" }
    },
    LAYOUT_MAP = {
    ["q"]="й", ["w"]="ц", ["e"]="у", ["r"]="к", ["t"]="е", ["y"]="н", ["u"]="г", ["i"]="ш", ["o"]="щ", ["p"]="з", ["["]="х", ["]"]="ъ",
    ["a"]="ф", ["s"]="ы", ["d"]="в", ["f"]="а", ["g"]="п", ["h"]="р", ["j"]="о", ["k"]="л", ["l"]="д", [";"]="ж", ["'"]="э",
    ["z"]="я", ["x"]="ч", ["c"]="с", ["v"]="м", ["b"]="и", ["n"]="т", ["m"]="ь", [","]="б", ["."]="ю", ["`"]="ё"
    }
}
local function D(value)
    return value * UI.scale
end
local function Touch(value)
    return D(math.max(48.0, value))
end
UI.PATH_INV = UI.ROOT_DIR .. 'mobile_inv.json'
UI.PATH_DB = UI.ROOT_DIR .. 'mobile_buyable.json'
UI.PATH_NAMES = UI.ROOT_DIR .. 'data/items_db.json'
UI.PATH_CFG_SELL = UI.ROOT_DIR .. 'config_sell.json'
UI.PATH_CFG_BUY = UI.ROOT_DIR .. 'config_buy.json'
UI.PATH_SETTINGS = UI.ROOT_DIR .. 'settings.json'
UI.PATH_LOGS = UI.ROOT_DIR .. 'logs/'
UI.PATH_PRICES = UI.ROOT_DIR .. 'average_prices.json'
UI.PATH_DAILY_PRICES = UI.ROOT_DIR .. 'daily_prices.json'
UI.PATH_PRICE_META = UI.ROOT_DIR .. 'price_update_meta.json'
UI.PATH_SESSION = UI.ROOT_DIR .. 'session.json'
UI.PATH_LIVE_SHOP = UI.ROOT_DIR .. 'live_shop_state.json'
UI.PATH_VIP_CACHE = UI.ROOT_DIR .. 'vips.json'
UI.PATH_ARB_BLACKLIST = UI.ROOT_DIR .. 'arb_blacklist.json'

function Tasks.add(name, code, wait_time)
    local cur_time = os.clock() * 1000
    local w_time = tonumber(wait_time) or 0
    for i = 1, #Tasks.list do
        local t = Tasks.list[i]
        if t.name == name then
            t.code = code
            t.start_time = cur_time
            t.wait_time = w_time
            t.dead = false
            return
        end
    end
    table.insert(Tasks.list, {
        name = name,
        code = code,
        start_time = cur_time,
        wait_time = w_time,
        dead = false
    })
end

function Tasks.remove_by_name(name)
    for i = 1, #Tasks.list do
        if Tasks.list[i].name == name then
            Tasks.list[i].dead = true
            return
        end
    end
end

function Tasks.process()
    if #Tasks.list == 0 then return end
    local current_time = os.clock() * 1000
    local i = 1
    while i <= #Tasks.list do
        local task = Tasks.list[i]
        if task.dead then
            table.remove(Tasks.list, i)
        elseif current_time >= (task.start_time + task.wait_time) then
            table.remove(Tasks.list, i)
            pcall(task.code)
        else
            i = i + 1
        end
    end
end

local MarketConfig = {
    HOST = "https://103.102.228.105",
    PROXY_HOST = "http://48.102.189.88:8992"
}

local SHA256_K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
}

local function sha256_raw(msg)
    local bit = Dependencies.bit
    msg = tostring(msg or "")
    local len = #msg
    local bit_len = len * 8
    local pad_len = 64 - ((len + 9) % 64)
    if pad_len == 64 then pad_len = 0 end
    local hi = math.floor(bit_len / 4294967296)
    local lo = bit_len % 4294967296
    local padded = msg .. "\128" .. string.rep("\0", pad_len) .. string.char(
        bit.band(bit.rshift(hi, 24), 255), bit.band(bit.rshift(hi, 16), 255),
        bit.band(bit.rshift(hi, 8), 255), bit.band(hi, 255),
        bit.band(bit.rshift(lo, 24), 255), bit.band(bit.rshift(lo, 16), 255),
        bit.band(bit.rshift(lo, 8), 255), bit.band(lo, 255)
    )
    local h1, h2, h3, h4, h5, h6, h7, h8 =
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    local w = {}
    for offset = 1, #padded, 64 do
        for i = 1, 16 do
            local b = offset + (i - 1) * 4
            local b1, b2, b3, b4 = padded:byte(b, b + 3)
            w[i] = ((b1 * 16777216) + (b2 * 65536) + (b3 * 256) + b4) % 4294967296
        end
        for i = 17, 64 do
            local w15 = w[i - 15]
            local w2 = w[i - 2]
            local s0 = bit.bxor(bit.ror(w15, 7), bit.ror(w15, 18), bit.rshift(w15, 3)) % 4294967296
            local s1 = bit.bxor(bit.ror(w2, 17), bit.ror(w2, 19), bit.rshift(w2, 10)) % 4294967296
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 4294967296
        end
        local a, b, c, d, e, f, g, h = h1, h2, h3, h4, h5, h6, h7, h8
        for i = 1, 64 do
            local s1 = bit.bxor(bit.ror(e, 6), bit.ror(e, 11), bit.ror(e, 25)) % 4294967296
            local ch = bit.bxor(bit.band(e, f), bit.band(bit.bnot(e), g)) % 4294967296
            local t1 = (h + s1 + ch + SHA256_K[i] + w[i]) % 4294967296
            local s0 = bit.bxor(bit.ror(a, 2), bit.ror(a, 13), bit.ror(a, 22)) % 4294967296
            local maj = bit.bxor(bit.band(a, b), bit.band(a, c), bit.band(b, c)) % 4294967296
            local t2 = (s0 + maj) % 4294967296
            h = g
            g = f
            f = e
            e = (d + t1) % 4294967296
            d = c
            c = b
            b = a
            a = (t1 + t2) % 4294967296
        end
        h1 = (h1 + a) % 4294967296
        h2 = (h2 + b) % 4294967296
        h3 = (h3 + c) % 4294967296
        h4 = (h4 + d) % 4294967296
        h5 = (h5 + e) % 4294967296
        h6 = (h6 + f) % 4294967296
        h7 = (h7 + g) % 4294967296
        h8 = (h8 + h) % 4294967296
    end
    local out = {}
    local hs = { h1, h2, h3, h4, h5, h6, h7, h8 }
    for i = 1, 8 do
        local v = hs[i]
        out[i] = string.char(
            bit.band(bit.rshift(v, 24), 255),
            bit.band(bit.rshift(v, 16), 255),
            bit.band(bit.rshift(v, 8), 255),
            bit.band(v, 255)
        )
    end
    return table.concat(out)
end

local function hmac_sha256(key, msg)
    local bit = Dependencies.bit
    key = tostring(key or "")
    msg = tostring(msg or "")
    if #key > 64 then key = sha256_raw(key) end
    if #key < 64 then key = key .. string.rep("\0", 64 - #key) end
    local ipad, opad = {}, {}
    for i = 1, 64 do
        local kb = key:byte(i)
        ipad[i] = string.char(bit.bxor(kb, 0x36))
        opad[i] = string.char(bit.bxor(kb, 0x5c))
    end
    local inner = sha256_raw(table.concat(ipad) .. msg)
    local outer = sha256_raw(table.concat(opad) .. inner)
    local hex = {}
    for i = 1, #outer do
        hex[i] = string.format("%02x", outer:byte(i))
    end
    return table.concat(hex)
end

local HttpManager = {
    _threads = {},
    _queue = {},
    _request_counter = 0,
    _max_parallel = 5,
    _max_regular_parallel = 4,
    _max_queue_size = 32,
    _poll_interval_ms = 50,
    _default_timeout_s = 15,
    _host_header = "rodina-market.store",
    _hosts = {
        { base = MarketConfig.HOST, header = "rodina-market.store" },
        { base = MarketConfig.PROXY_HOST, header = "rodina-market.store" },
        { base = "https://rodina-market.store", header = "rodina-market.store" }
    }
}

local function _httpWorker(method, full_url, req_data, headers_packed, timeout_s, verify_ssl, pkg_path, pkg_cpath)
    if pkg_path and pkg_path ~= '' then package.path = pkg_path end
    if pkg_cpath and pkg_cpath ~= '' then package.cpath = pkg_cpath end
    local headers = {}
    if type(headers_packed) == 'string' and headers_packed ~= '' then
        for entry in headers_packed:gmatch("([^\2]+)") do
            local k, v = entry:match("^([^\1]+)\1(.*)$")
            if k then headers[k] = v end
        end
    end
    local req_args = {
        headers = headers,
        timeout = tonumber(timeout_s) or 15
    }
    if not verify_ssl then
        req_args.verify = false
    end
    if type(req_data) == 'string' and req_data ~= '' then
        req_args.data = req_data
    end
    local ok_load, requests = pcall(require, 'requests')
    if ok_load and requests and type(requests.request) == 'function' then
        local ok_call, response = pcall(requests.request, method, full_url, req_args)
        if ok_call and type(response) == 'table' and tonumber(response.status_code) and tonumber(response.status_code) > 0 then
            return true, {
                status_code = tonumber(response.status_code) or 0,
                text = tostring(response.text or '')
            }
        end
    end
    local is_https = tostring(full_url):sub(1, 8):lower() == "https://"
    local ok_ltn12, ltn12 = pcall(require, 'ltn12')
    local ok_proto, proto = pcall(require, is_https and 'ssl.https' or 'socket.http')
    if ok_ltn12 and ltn12 and ok_proto and proto then
        proto.TIMEOUT = tonumber(timeout_s) or 15
        local resp_chunks = {}
        local req_tbl = {
            url = full_url,
            method = method,
            headers = headers,
            sink = ltn12.sink.table(resp_chunks)
        }
        if is_https then
            req_tbl.verify = verify_ssl and "peer" or "none"
        end
        if type(req_data) == 'string' and req_data ~= '' then
            req_tbl.headers["Content-Length"] = tostring(#req_data)
            req_tbl.source = ltn12.source.string(req_data)
        end
        local ok_req, res_ok, code = pcall(proto.request, req_tbl)
        if ok_req and res_ok and tonumber(code) then
            return true, {
                status_code = tonumber(code) or 0,
                text = table.concat(resp_chunks)
            }
        end
        return false, tostring(code or res_ok or 'http_request_failed')
    end
    return false, 'requests_module_unavailable'
end

function HttpManager._buildUrl(raw_url, host_index, external)
    if external then return tostring(raw_url or '') end
    local path = tostring(raw_url or '')
    if path:match("^https?://") then
        path = path:gsub("^https?://[^/]+", "")
    end
    if path == "" then path = "/" end
    if path:sub(1, 1) ~= "/" then path = "/" .. path end
    local host = HttpManager._hosts[tonumber(host_index) or 1] or HttpManager._hosts[1]
    if path == "/data" or path:sub(1, 6) == "/data/" then
        return host.base .. path
    end
    path = path:gsub("^/api/", "/node-api/")
    if not path:find("^/node%-api") then
        path = "/node-api" .. path
    end
    return host.base .. path
end

function HttpManager._countActive()
    local count = 0
    for _ in pairs(HttpManager._threads) do count = count + 1 end
    return count
end

function HttpManager._releaseSlot(request_id, reason)
    local entry = HttpManager._threads[request_id]
    if not entry then return end
    HttpManager._threads[request_id] = nil
    if entry.thread then
        pcall(function() entry.thread:cancel(0) end)
    end
    if reason and entry.reject then
        pcall(entry.reject, reason)
    end
end

function HttpManager._drainQueue()
    if #HttpManager._queue == 0 then return end
    local active_count = HttpManager._countActive()
    local next_req = HttpManager._queue[1]
    if active_count >= HttpManager._max_parallel then return end
    if next_req and not next_req.priority and active_count >= HttpManager._max_regular_parallel then return end
    next_req = table.remove(HttpManager._queue, 1)
    if next_req then
        HttpManager._spawn(next_req)
    end
end

function HttpManager._fallbackRequest(req, request_id, reason)
    if not req or req.external then return false end
    local next_host = (tonumber(req.host_index) or 1) + 1
    if next_host > #HttpManager._hosts then return false end
    Tasks.add("http_proxy_retry_" .. tostring(request_id or HttpManager._request_counter), function()
        HttpManager.request(
            req.method,
            req.url,
            req.args,
            req.resolve,
            req.reject,
            req.priority,
            next_host,
            req.external
        )
    end, 100)
    return true
end

function HttpManager._spawn(req)
    HttpManager._request_counter = HttpManager._request_counter + 1
    local request_id = "req_" .. HttpManager._request_counter
    local host_index = tonumber(req.host_index) or 1
    local host = HttpManager._hosts[host_index] or HttpManager._hosts[1]
    local full_url = HttpManager._buildUrl(req.url, host_index, req.external)

    local req_args = {}
    for key, value in pairs(req.args or {}) do
        req_args[key] = value
    end
    local request_headers = {}
    for key, value in pairs(req_args.headers or {}) do
        request_headers[key] = value
    end
    if not req.external and not request_headers["Host"] and not request_headers["host"] then
        request_headers["Host"] = host.header or HttpManager._host_header
    end
    local verify_ssl = req_args.verify == true
    local timeout_s = tonumber(req_args.timeout) or HttpManager._default_timeout_s
    local hard_timeout_s = tonumber(req_args.hard_timeout) or (timeout_s + 15)
    local req_data = req_args.data ~= nil and tostring(req_args.data) or ""
    local header_pairs = {}
    for key, value in pairs(request_headers) do
        header_pairs[#header_pairs + 1] = tostring(key) .. "\1" .. tostring(value)
    end
    local headers_packed = table.concat(header_pairs, "\2")

    local ok_spawn, thread = pcall(function()
        return Dependencies.effil.thread(_httpWorker)(req.method, full_url, req_data, headers_packed, timeout_s, verify_ssl, package.path, package.cpath)
    end)

    if not ok_spawn or not thread then
        local retrying = HttpManager._fallbackRequest(req, request_id, "thread_spawn_error")
        if not retrying and req.reject then pcall(req.reject, "thread_spawn_error") end
        if #HttpManager._queue > 0 then
            Tasks.add("http_drain_retry", HttpManager._drainQueue, 500)
        end
        return
    end

    HttpManager._threads[request_id] = {
        thread = thread,
        method = req.method,
        started_at = os.time(),
        hard_timeout = hard_timeout_s,
        req = req,
        host_index = host_index,
        request_id = request_id,
        resolve = req.resolve,
        reject = req.reject
    }

    Tasks.add("http_poll_" .. request_id, function()
        HttpManager._poll(request_id)
    end, HttpManager._poll_interval_ms)
end

function HttpManager._fallback(entry, reason)
    if not entry or not entry.req then return false end
    return HttpManager._fallbackRequest(entry.req, entry.request_id, reason)
end

function HttpManager._poll(request_id)
    local entry = HttpManager._threads[request_id]
    if not entry then return end

    if State.is_terminating then
        HttpManager._releaseSlot(request_id, "shutdown")
        HttpManager._drainQueue()
        return
    end

    local ok_status, status, err = pcall(function()
        return entry.thread:status()
    end)

    if not ok_status or err then
        local reason = tostring(err or "thread_error")
        if HttpManager._fallback(entry, reason) then
            HttpManager._releaseSlot(request_id)
        else
            HttpManager._releaseSlot(request_id, reason)
        end
        HttpManager._drainQueue()
        return
    end

    if status == 'completed' then
        HttpManager._threads[request_id] = nil
        local ok_get, success, result = pcall(function()
            local a, b = entry.thread:get()
            return a, b
        end)
        if not ok_get then
            if not HttpManager._fallback(entry, "deserialize_error") then
                if entry.reject then pcall(entry.reject, "deserialize_error") end
            end
        elseif success then
            local status_code = tonumber(result.status_code) or 0
            local should_fallback = (status_code == 0 or status_code >= 500)
                and entry.host_index < #HttpManager._hosts
                and not entry.req.external
            if should_fallback then
                HttpManager._fallback(entry, "http_" .. status_code)
            elseif entry.resolve then
                local callback_ok = pcall(entry.resolve, result)
                if not callback_ok and entry.reject then
                    pcall(entry.reject, "response_callback_failed")
                end
            end
        else
            if not HttpManager._fallback(entry, tostring(result or "request_failed")) then
                if entry.reject then pcall(entry.reject, result or "request_failed") end
            end
        end
        HttpManager._drainQueue()
        return
    end

    if status == 'canceled' then
        local retrying = HttpManager._fallback(entry, "canceled")
        if retrying then
            HttpManager._releaseSlot(request_id)
        else
            HttpManager._releaseSlot(request_id, "canceled")
        end
        HttpManager._drainQueue()
        return
    end

    if status ~= 'running' and status ~= 'paused' then
        local reason = "thread_status_" .. tostring(status)
        if HttpManager._fallback(entry, reason) then
            HttpManager._releaseSlot(request_id)
        else
            HttpManager._releaseSlot(request_id, reason)
        end
        HttpManager._drainQueue()
        return
    end

    if os.time() - entry.started_at > entry.hard_timeout then
        if HttpManager._fallback(entry, "timeout") then
            HttpManager._releaseSlot(request_id)
        else
            HttpManager._releaseSlot(request_id, "timeout")
        end
        HttpManager._drainQueue()
        return
    end

    Tasks.add("http_poll_" .. request_id, function()
        HttpManager._poll(request_id)
    end, HttpManager._poll_interval_ms)
end

function HttpManager.request(method, url, args, resolve, reject, priority, host_index, external)
    if not url or url == "" then
        if reject then pcall(reject, "empty_url") end
        return
    end
    if State.is_terminating then return end

    local req = {
        method = method or "GET",
        url = url,
        args = args or {},
        resolve = resolve or function() end,
        reject = reject or function() end,
        priority = priority == true,
        host_index = tonumber(host_index) or 1,
        external = external == true or (args and args.external == true)
    }

    local active_count = HttpManager._countActive()
    if active_count < HttpManager._max_parallel and (req.priority or active_count < HttpManager._max_regular_parallel) then
        HttpManager._spawn(req)
    else
        if #HttpManager._queue >= HttpManager._max_queue_size then
            pcall(req.reject, "queue_overflow")
            return
        end
        if req.priority then
            table.insert(HttpManager._queue, 1, req)
        else
            table.insert(HttpManager._queue, req)
        end
    end
end

function HttpManager.shutdown()
    for _, entry in pairs(HttpManager._threads) do
        if entry.thread then
            pcall(function() entry.thread:cancel(0) end)
        end
    end
    HttpManager._threads = {}
    HttpManager._queue = {}
end

local function isUTF8(str)
    if type(str) ~= 'string' then return false end
    if not str:find("[\128-\255]") then return false end
    local i, len = 1, #str
    local has_multibyte = false
    while i <= len do
        local b = str:byte(i)
        if b >= 0x80 then
            has_multibyte = true
            if b >= 0xC2 and b <= 0xDF then
                if i + 1 > len then return false end
                local b2 = str:byte(i + 1)
                if b2 < 0x80 or b2 > 0xBF then return false end
                i = i + 2
            elseif b >= 0xE0 and b <= 0xEF then
                if i + 2 > len then return false end
                local b2, b3 = str:byte(i + 1), str:byte(i + 2)
                if b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF then return false end
                i = i + 3
            elseif b >= 0xF0 and b <= 0xF4 then
                if i + 3 > len then return false end
                local b2, b3, b4 = str:byte(i + 1), str:byte(i + 2), str:byte(i + 3)
                if b2 < 0x80 or b2 > 0xBF or b3 < 0x80 or b3 > 0xBF or b4 < 0x80 or b4 > 0xBF then return false end
                i = i + 4
            else
                return false
            end
        else
            i = i + 1
        end
    end
    return has_multibyte
end

local function ensureUTF8(val)
    if type(val) == 'string' then
        if not val:find("[\128-\255]") then return val end
        if not isUTF8(val) then
            local ok, res = pcall(Dependencies.u8.encode, Dependencies.u8, val)
            if ok and res then return res end
        end
        return val
    end
    if type(val) == 'table' then
        local res = {}
        for k, v in pairs(val) do res[ensureUTF8(k)] = ensureUTF8(v) end
        return res
    end
    return val
end

local UTF8_EXTRA_MAP = {
    [0x0401] = 168,
    [0x0451] = 184,
    [0x0404] = 170,
    [0x0454] = 186,
    [0x0406] = 178,
    [0x0456] = 179,
    [0x0407] = 175,
    [0x0457] = 191,
    [0x0490] = 165,
    [0x0491] = 180,
    [0x2116] = 185,
    [0x2013] = 150,
    [0x2014] = 151,
    [0x2018] = 145,
    [0x2019] = 146,
    [0x201C] = 147,
    [0x201D] = 148,
    [0x201E] = 132,
    [0x2026] = 133,
    [0x00AB] = 171,
    [0x00BB] = 187
}

local function utf8ToCp1251Fast(str)
    if type(str) ~= 'string' or not str:find("[\128-\255]") then return str end
    local out = {}
    local i, len = 1, #str
    while i <= len do
        local b1 = str:byte(i)
        if b1 < 0x80 then
            out[#out + 1] = string.char(b1)
            i = i + 1
        elseif b1 >= 0xC2 and b1 <= 0xDF and i + 1 <= len then
            local b2 = str:byte(i + 1)
            if b2 >= 0x80 and b2 <= 0xBF then
                local cp = (b1 - 0xC0) * 64 + (b2 - 0x80)
                if cp >= 0x0410 and cp <= 0x044F then
                    out[#out + 1] = string.char(cp - 0x0410 + 192)
                elseif UTF8_EXTRA_MAP[cp] then
                    out[#out + 1] = string.char(UTF8_EXTRA_MAP[cp])
                else
                    out[#out + 1] = "?"
                end
                i = i + 2
            else
                return str
            end
        elseif b1 >= 0xE0 and b1 <= 0xEF and i + 2 <= len then
            local b2, b3 = str:byte(i + 1, i + 2)
            if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF then
                local cp = ((b1 - 0xE0) * 4096) + ((b2 - 0x80) * 64) + (b3 - 0x80)
                if UTF8_EXTRA_MAP[cp] then
                    out[#out + 1] = string.char(UTF8_EXTRA_MAP[cp])
                else
                    out[#out + 1] = "?"
                end
                i = i + 3
            else
                return str
            end
        elseif b1 >= 0xF0 and b1 <= 0xF4 and i + 3 <= len then
            i = i + 4
        else
            return str
        end
    end
    return table.concat(out)
end

local function ensureCP1251(val)
    if val == Dependencies.cjson.null then return nil end
    if type(val) == 'string' then
        return utf8ToCp1251Fast(val)
    end
    if type(val) == 'table' then
        local res = {}
        for k, v in pairs(val) do
            local nk = ensureCP1251(k)
            if nk ~= nil then res[nk] = ensureCP1251(v) end
        end
        return res
    end
    return val
end

function apiEncodeJson(tbl)
    return Dependencies.cjson.encode(ensureUTF8(tbl))
end

function apiDecodeJson(str)
    if type(str) ~= "string" or str == "" then return nil end
    local ok, parsed = pcall(Dependencies.cjson.decode, str)
    if ok and parsed ~= nil then return ensureCP1251(parsed) end
    return nil
end

function url_encode(str)
    if str then
        str = tostring(str):gsub("\n", "\r\n")
        str = str:gsub("([^%w %-%_%.%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        str = str:gsub(" ", "+")
    end
    return str or ""
end

function onScriptTerminate(script, quit)
    if script ~= thisScript() then return end
    State.is_terminating = true
    HttpManager.shutdown()
    if quit then
        sendDisconnectNotification("Выход из игры (/q) или Краш клиента")
    end
end

function isTokenPresent()
    return Settings and Settings.api_key and type(Settings.api_key) == "string" and #Settings.api_key >= 16
end

function isTokenVerified()
    return isTokenPresent() and type(ApiState) == "table" and ApiState.key_valid == true
end

function isVerifiedVip()
    if not ApiState.server_vip_verified or not ApiState.is_vip then return false end
    if not isTokenPresent() then
        ApiState.is_vip = false
        ApiState.server_vip_verified = false
        return false
    end
    local current_nick = getSafeLocalNickname()
    local current_time = os.time()
    if not ApiState.vip_expire or ApiState.vip_expire <= 0 or current_time >= ApiState.vip_expire then
        ApiState.is_vip = false
        ApiState.server_vip_verified = false
        return false
    end
    if not current_nick or current_nick == "Unknown Player" or current_nick ~= ApiState.vip_verified_nick then
        if not ApiState.vip_checking_in_progress then
            checkVipStatus(Settings.api_key, 0)
        end
    end
    if not ApiState.vip_validated_at or (current_time - ApiState.vip_validated_at > 1800) then
        if not ApiState.vip_checking_in_progress then
            checkVipStatus(Settings.api_key, 0)
        end
    end
    return true
end

function getSafeLocalNickname()
    local nick = UI.player_nickname
    if (not nick or nick == "") and Settings and Settings.last_nickname then
        nick = Settings.last_nickname
    end
    if (not nick or nick == "") then
        pcall(function()
            local res, my_id = sampGetPlayerIdByCharHandle(PLAYER_PED)
            if res then
                local n = sampGetPlayerNickname(my_id)
                if n and n ~= "" and not n:find("^Player_%d+$") then nick = n end
            end
        end)
    end
    if nick and nick ~= "" then
        return nick:gsub("_", " ")
    end
    return "Unknown Player"
end

function signedRequest(method, url, payload_table, callback, opts)
    if not isTokenVerified() and not (opts and opts.allow_unverified) then
        if callback then pcall(callback, 401, "") end
        return
    end
    local user_token = (Settings and Settings.api_key) or ""
    local json_body = ""
    if method == "POST" then
        if type(payload_table) == "string" then
            local ok, parsed = pcall(Dependencies.cjson.decode, payload_table)
            if ok and type(parsed) == "table" then
                json_body = apiEncodeJson(parsed)
            else
                json_body = payload_table
            end
        elseif type(payload_table) == "table" then
            json_body = apiEncodeJson(payload_table)
        else
            json_body = "{}"
        end
    end
    local ts = tostring(os.time())
    local nonce = string.format("%x%x%x", os.time(), math.floor(os.clock() * 1000), math.random(10000, 99999))
    local headers = {
        ["Content-Type"] = "application/json"
    }
    if user_token ~= "" then
        headers["X-Auth-Key"] = user_token
        headers["X-Timestamp"] = ts
        headers["X-Nonce"] = nonce
        headers["X-Signature"] = hmac_sha256(user_token .. ":rmarket_v2_salt", ts .. ":" .. nonce .. ":" .. json_body)
    end
    local req_args = {
        headers = headers
    }
    if method == "POST" then
        req_args.data = json_body
    end
    if opts and opts.timeout then
        req_args.timeout = opts.timeout
    end
    HttpManager.request(
        method or "GET",
        url,
        req_args,
        function(res)
            if callback then pcall(callback, tonumber(res.status_code) or 0, tostring(res.text or "")) end
        end,
        function()
            if callback then pcall(callback, 0, "") end
        end,
        opts and opts.priority == true
    )
end

function apiKeyCheckFailure(message, options, callback, token_state)
    ApiState.checking = false
    ApiState.key_checked = true
    ApiState.last_check = os.time()
    ApiState.key_valid = false
    ApiState.token_state = token_state or "invalid"
    if not (options and options.silent) then
        sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}" .. tostring(message), -1)
    end
    if callback then callback(false, tostring(message)) end
end

function executeTestTgRequest(token, callback, options, attempt)
    if token ~= Settings.api_key then
        ApiState.checking = false
        return
    end
    attempt = tonumber(attempt) or 1
    local current_nick = getSafeLocalNickname()
    local payload = {
        secret_key = token,
        nickname = current_nick,
        account_id = tonumber(UI.account_id) or 0
    }
    local function handleResponse(status, body)
        if token ~= Settings.api_key then return end
        if status == 200 and body ~= "" then
            local data = apiDecodeJson(body)
            if data and data.status == "success" then
                ApiState.checking = false
                ApiState.key_checked = true
                ApiState.last_check = os.time()
                ApiState.key_valid = true
                ApiState.token_state = "valid"
                ApiState.is_vip = data.is_vip or false
                ApiState.vip_validated_at = os.time()
                ApiState.vip_months = tonumber(data.vip_months) or 1
                ApiState.vip_expire = tonumber(data.expire_ts) or 0
                saveJsonFile(UI.PATH_SETTINGS, Settings)
                if not (options and options.silent) then
                    local bind_msg = (tonumber(UI.account_id) or 0) > 0 and ("ID: " .. tostring(UI.account_id)) or ("Ник: " .. current_nick)
                    sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Ключ подтвержден! Привязано к " .. bind_msg, -1)
                end
                startAuthenticatedDataLoads()
                checkVipStatus(token, 0)
                api_PullConfigsFromCloud(token)
                if callback then callback(true, data) end
                return
            end
            apiKeyCheckFailure((data and data.message) or "Ошибка ответа сервера", options, callback, "invalid")
        elseif status == 400 then
            apiKeyCheckFailure("Ключ выглядит неполным. Скопируйте его заново из профиля бота.", options, callback, "invalid")
        elseif status == 403 then
            local err_data = apiDecodeJson(body)
            local msg = (err_data and err_data.code == "KEY_BLOCKED")
                and "Ключ заблокирован. Обратитесь в поддержку."
                or "Ключ не найден. Откройте профиль бота и скопируйте его заново."
            apiKeyCheckFailure(msg, options, callback, "invalid")
        elseif status == 409 then
            local err_data = apiDecodeJson(body)
            local msg = (err_data and err_data.code == "ACCOUNT_LOCKED")
                and "Привязка аккаунта заблокирована. Обратитесь в поддержку."
                or "Этот ключ уже привязан к другому игровому аккаунту."
            apiKeyCheckFailure(msg, options, callback, "invalid")
        elseif status == 429 then
            apiKeyCheckFailure("Слишком много попыток. Подождите минуту и повторите.", options, callback, "error")
        elseif status >= 500 or status == 0 then
            if attempt < 3 then
                Tasks.add("key_verify_retry", function()
                    if token == Settings.api_key then
                        executeTestTgRequest(token, callback, options, attempt + 1)
                    end
                end, 500 * attempt)
                return
            end
            apiKeyCheckFailure("Нет связи с сервером. Проверьте интернет и повторите.", options, callback, "error")
        else
            apiKeyCheckFailure("HTTP " .. tostring(status), options, callback, "error")
        end
    end

    HttpManager.request(
        "POST",
        "/node-api/test_tg",
        {
            headers = { ["Content-Type"] = "application/json" },
            data = apiEncodeJson(payload)
        },
        function(res)
            handleResponse(tonumber(res.status_code) or 0, tostring(res.text or ""))
        end,
        function()
            handleResponse(0, "")
        end,
        true
    )
end

function checkApiKey(token, callback, options)
    options = options or {}
    token = tostring(token or ""):match("^%s*(.-)%s*$") or ""
    if #token < 16 then
        ApiState.key_valid = false
        ApiState.key_checked = true
        ApiState.token_state = "missing"
        if callback then callback(false, "too_short") end
        return
    end
    Settings.api_key = token
    saveJsonFile(UI.PATH_SETTINGS, Settings)
    ApiState.token_state = "checking"
    ApiState.key_valid = false
    if ApiState.checking then return end
    ApiState.checking = true

    if (tonumber(UI.account_id) or 0) == 0 or UI.player_nickname == "" then
        State.pending_test_tg = { token = token, callback = callback, options = options, deadline = os.clock() + 2.5 }
        if not State.silent_stats and not State.stats_requested then
            State.silent_stats = true
            sampSendChat("/stats")
        end
        Tasks.add("tg_stats_wait", function()
            if State.pending_test_tg and State.pending_test_tg.token == token then
                local pending = State.pending_test_tg
                State.pending_test_tg = nil
                executeTestTgRequest(pending.token, pending.callback, pending.options, 1)
            end
        end, 2200)
    else
        executeTestTgRequest(token, callback, options, 1)
    end
end

function checkVipStatus(token, attempt)
    token = tostring(token or ""):match("^%s*(.-)%s*$") or ""
    if token ~= Settings.api_key then return end
    if #token < 16 then
        ApiState.key_valid = false
        ApiState.token_state = "missing"
        ApiState.is_vip = false
        ApiState.server_vip_verified = false
        ApiState.vip_validated_at = 0
        ApiState.key_checked = true
        return
    end
    if ApiState.vip_checking_in_progress then return end

    local current_nick = getSafeLocalNickname()
    if not current_nick or current_nick == "Unknown Player" then
        attempt = (tonumber(attempt) or 0) + 1
        ApiState.token_state = "checking"
        ApiState.vip_check_attempts = attempt
        if not State.silent_stats and not State.stats_requested then
            State.silent_stats = true
            sampSendChat("/stats")
        end
        if attempt >= 30 then
            ApiState.token_state = "error"
            ApiState.key_checked = true
            ApiState.pending_manual_price_download = false
            return
        end
        ApiState.vip_checking_in_progress = true
        Tasks.add("saved_token_verify_retry", function()
            ApiState.vip_checking_in_progress = false
            checkVipStatus(token, attempt)
        end, 500)
        return
    end

    ApiState.vip_check_attempts = 0
    ApiState.vip_checking_in_progress = true
    ApiState.token_state = "checking"
    local retry_attempt = tonumber(attempt) or 0

    local function scheduleRetry()
        Tasks.add("saved_token_verify_retry", function()
            if token ~= Settings.api_key then return end
            ApiState.vip_checking_in_progress = false
            checkVipStatus(token, math.min(retry_attempt + 1, 3))
        end, math.min(5000 * (2 ^ math.min(retry_attempt, 3)), 60000))
    end

    local payload = {
        secret_key = token,
        nickname = current_nick,
        nickname_rus = UI.player_nickname_rus or "",
        account_id = tonumber(UI.account_id) or 0
    }

    local function handleVipResponse(status, body)
        if token ~= Settings.api_key then return end
        ApiState.vip_checking_in_progress = false
        if status == 200 and body ~= "" then
            local res = apiDecodeJson(body)
            if type(res) == "table" and res.status == "success" then
                ApiState.key_valid = true
                ApiState.token_state = "valid"
                if res.is_vip == true then
                    ApiState.is_vip = true
                    ApiState.server_vip_verified = true
                    ApiState.vip_verified_nick = current_nick
                    ApiState.vip_validated_at = os.time()
                    ApiState.vip_days = res.days_left
                    ApiState.vip_months = tonumber(res.vip_months) or 1
                    ApiState.vip_expire = tonumber(res.expire_ts) or 0
                    local m = tonumber(res.vip_months) or 1
                    ApiState.vip_users_cache[current_nick] = m
                    ApiState.vip_users_cache[current_nick:gsub(" ", "_")] = m
                    if UI.player_nickname_rus ~= "" then
                        ApiState.vip_users_cache[UI.player_nickname_rus] = m
                        ApiState.vip_users_cache[UI.player_nickname_rus:gsub(" ", "_")] = m
                    end
                    saveJsonFile(UI.PATH_VIP_CACHE, ApiState.vip_users_cache)
                else
                    ApiState.is_vip = false
                    ApiState.server_vip_verified = false
                    ApiState.vip_validated_at = 0
                end
                ApiState.key_checked = true
                startAuthenticatedDataLoads()
                return
            end
            ApiState.token_state = "error"
            ApiState.key_checked = true
            scheduleRetry()
        elseif status == 403 then
            ApiState.key_valid = false
            ApiState.pending_manual_price_download = false
            ApiState.is_vip = false
            ApiState.server_vip_verified = false
            ApiState.vip_validated_at = 0
            ApiState.authenticated_loads_started = false
            local mres = apiDecodeJson(body)
            if type(mres) == "table" and (mres.msg == "account_locked" or mres.msg == "account_mismatch") then
                ApiState.token_state = "error"
                sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Аккаунт зафиксирован администратором. Обратитесь в поддержку.", -1)
            else
                ApiState.token_state = "invalid"
            end
            ApiState.key_checked = true
        else
            ApiState.token_state = "error"
            ApiState.key_checked = true
            scheduleRetry()
        end
    end

    HttpManager.request(
        "POST",
        "/node-api/check_vip",
        {
            headers = { ["Content-Type"] = "application/json" },
            data = apiEncodeJson(payload)
        },
        function(res)
            handleVipResponse(tonumber(res.status_code) or 0, tostring(res.text or ""))
        end,
        function()
            handleVipResponse(0, "")
        end,
        true
    )
end

function tryAutoUpdatePrices()
    local now = os.time()
    local meta = loadJsonFile(UI.PATH_PRICE_META)
    local last_ts = tonumber(meta and meta.last_update) or 0
    local prices_empty = type(UI.average_prices) ~= "table" or next(UI.average_prices) == nil
    if prices_empty or last_ts == 0 or (now - last_ts) > 86400 then
        api_DownloadAveragePrices()
    end
end

function api_DownloadVipCache()
    if not isTokenVerified() then return end
    signedRequest("GET", "/get_vips", nil, function(status, body)
        if status == 200 and body ~= "" then
            local data = apiDecodeJson(body)
            if type(data) == "table" then
                local new_cache = {}
                for vip_nick, months in pairs(data) do
                    local m = tonumber(months) or 1
                    new_cache[vip_nick] = m
                    new_cache[tostring(vip_nick):gsub(" ", "_")] = m
                end
                if ApiState.is_vip and UI.player_nickname ~= "" then
                    local local_m = ApiState.vip_months or 1
                    new_cache[UI.player_nickname] = local_m
                    new_cache[UI.player_nickname:gsub(" ", "_")] = local_m
                end
                ApiState.vip_users_cache = new_cache
                saveJsonFile(UI.PATH_VIP_CACHE, ApiState.vip_users_cache)
            end
        end
    end)
end

function startAuthenticatedDataLoads()
    if not isTokenVerified() or ApiState.authenticated_loads_started then return end
    ApiState.authenticated_loads_started = true
    lua_thread.create(function()
        while not UI.caches_loaded and not State.is_terminating do
            wait(50)
        end
        if State.is_terminating or not isTokenVerified() then return end
        if ApiState.pending_manual_price_download then
            ApiState.pending_manual_price_download = false
            api_DownloadAveragePrices()
        else
            tryAutoUpdatePrices()
        end
        wait(300)
        if State.is_terminating or not isTokenVerified() then return end
        if isItemDbEmpty() then api_CheckAndDownloadItemsDB(false) end
        api_DownloadVipCache()
        wait(300)
        if State.is_terminating or not isTokenVerified() then return end
        api_FetchMarketList(true)
    end)
end

function getPRBuffer(idx, text)
    if not UI.pr_buffers[idx] then UI.pr_buffers[idx] = Dependencies.ffi.new('char[256]', text or "") end
    return UI.pr_buffers[idx]
end

function getPRDelayBuffer(idx, delay)
    if not UI.pr_delay_buffers[idx] then UI.pr_delay_buffers[idx] = Dependencies.ffi.new('char[32]', tostring(delay or 60)) end
    return UI.pr_delay_buffers[idx]
end

function getDownloadUrls(url)
    local urls = {}
    local seen = {}
    local owner, repository, branch, path = url:match("^https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/([^/]+)/(.*)$")
    if owner then
        if branch == "refs" then
            local ref_branch, ref_path = path:match("^heads/([^/]+)/(.*)$")
            if ref_branch then branch, path = ref_branch, ref_path end
        end
        local candidates = {
            string.format("https://fastly.jsdelivr.net/gh/%s/%s@%s/%s", owner, repository, branch, path),
            string.format("https://cdn.jsdelivr.net/gh/%s/%s@%s/%s", owner, repository, branch, path),
            string.format("https://raw.githack.com/%s/%s/%s/%s", owner, repository, branch, path)
        }
        for _, u in ipairs(candidates) do
            if not seen[u] then
                seen[u] = true
                urls[#urls + 1] = u
            end
        end
    end
    if not seen[url] then
        urls[#urls + 1] = url
    end
    return urls
end

function replaceDownloadedFile(source, destination)
    local backup = destination .. ".previous"
    pcall(os.remove, backup)
    local dest_file = io.open(destination, "rb")
    local had_previous = dest_file ~= nil
    if dest_file then dest_file:close() end
    if had_previous and not os.rename(destination, backup) then return false end
    if not os.rename(source, destination) then
        if had_previous then os.rename(backup, destination) end
        return false
    end
    if had_previous then pcall(os.remove, backup) end
    return true
end

function readUpdateManifest(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    local ok, data = pcall(Dependencies.cjson.decode, content)
    return ok and type(data) == "table" and data or nil
end

function applyUpdateManifest(data)
    if data and data.version and data.version ~= thisScript().version then
        State.update.version = data.version
        State.update.url = data.url
        State.update.text = data.text or "Доступна новая версия!"
        State.update.available = true
        UI.show_update_window[0] = true
    end
end

function fetchFromMirrors(urls, idx, validator, on_success, on_fail)
    if idx > #urls then
        if on_fail then on_fail("all_mirrors_failed") end
        return
    end
    HttpManager.request(
        "GET",
        urls[idx],
        { timeout = 15, external = true },
        function(res)
            local text = type(res.text) == "string" and res.text or ""
            if tonumber(res.status_code) == 200 and text ~= "" and (not validator or validator(text)) then
                on_success(text, urls[idx])
            else
                fetchFromMirrors(urls, idx + 1, validator, on_success, on_fail)
            end
        end,
        function()
            fetchFromMirrors(urls, idx + 1, validator, on_success, on_fail)
        end,
        false,
        1,
        true
    )
end

function checkForUpdates()
    if not doesDirectoryExist(UI.ROOT_DIR) then pcall(function() Dependencies.lfs.mkdir(UI.ROOT_DIR) end) end
    local update_json_path = UI.ROOT_DIR .. 'update.json'
    applyUpdateManifest(readUpdateManifest(update_json_path))
    fetchFromMirrors(
        getDownloadUrls(UI.UPDATE_MANIFEST_URL),
        1,
        function(text)
            local ok, data = pcall(Dependencies.cjson.decode, text)
            return ok and type(data) == "table" and data.version ~= nil
        end,
        function(text)
            local temp_path = update_json_path .. ".download"
            local file = io.open(temp_path, "w")
            if file then
                file:write(text)
                file:close()
                if replaceDownloadedFile(temp_path, update_json_path) then
                    applyUpdateManifest(readUpdateManifest(update_json_path))
                else
                    pcall(os.remove, temp_path)
                end
            end
        end
    )
end

function downloadScriptUpdate(url, dest, callback)
    if not url or url == "" then
        if callback then callback(false, "Пустой URL обновления") end
        return
    end
    fetchFromMirrors(
        getDownloadUrls(url),
        1,
        function(text)
            return #text > 1000 and text:find("script_name", 1, true) ~= nil
        end,
        function(text)
            local temp_path = dest .. ".download"
            local file = io.open(temp_path, "wb")
            if not file then
                if callback then callback(false, "Не удалось открыть файл для записи") end
                return
            end
            file:write(text)
            file:close()
            if replaceDownloadedFile(temp_path, dest) then
                if callback then callback(true, "Успешно") end
            else
                pcall(os.remove, temp_path)
                if callback then callback(false, "Не удалось заменить файл скрипта") end
            end
        end,
        function(reason)
            if callback then callback(false, tostring(reason)) end
        end
    )
end

function processPRVariables(text)
    if not text then return "" end
    local _, myId = sampGetPlayerIdByCharHandle(PLAYER_PED)
    local myName = UI.player_nickname ~= "" and UI.player_nickname or "Unknown"
    local vars = {
        ["{id}"] = tostring(myId),
        ["{name}"] = myName,
        ["{name_space}"] = myName:gsub("_", " "),
        ["{lvl}"] = tostring(sampGetPlayerScore(myId)),
        ["{time}"] = os.date("%H:%M")
    }
    return text:gsub("{(.-)}", function(k) return vars["{"..k.."}"] or "{"..k.."}" end)
end

function cleanTextColors(text)
    if type(text) ~= 'string' or text == "" then return "" end
    return text:gsub("{%x%x%x%x%x%x}", ""):gsub("%[%x%x%x%x%x%x%]", ""):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
end

function enhancedCleanItemName(name)
    if not name or name == "" then return "" end
    name = tostring(name):gsub("{%x%x%x%x%x%x}", ""):gsub("^[оеш]?[втг]%s+", "")
    return name:match("^%s*(.-)%s*$") or ""
end

function getQualityTier(quality)
    local q = tonumber(quality)
    if not q or q <= 0 then return nil end
    return math.floor(q / 100) * 100
end

function stripItemMetadata(name)
    if not name or name == "" then return "" end
    local s = enhancedCleanItemName(name)
    s = s:gsub("%s*%(Перенос:.-%)", "")
    s = s:gsub("%s*%[Кач%.%s*%d+%-?%d*%]", "")
    s = s:gsub("%s*%(x%d+%)", "")
    s = s:gsub("%s*%(id:%s*%d+%)", "")
    s = s:gsub("%s*%(%d+%s*шт%.?%)", "")
    s = s:match("^%s*(.-)%s*$") or ""
    if not (UI.item_names_reversed and UI.item_names_reversed[s]) then
        s = s:gsub("%s*%[%+%d+%]$", "")
        s = s:gsub("%s+%+%d+$", "")
    end
    return s:match("^%s*(.-)%s*$") or ""
end

function parseItemMetadata(raw_name)
    if not raw_name or raw_name == "" then
        return { base_name = "", enchant = nil, quality = nil, transferred_from = nil }
    end
    local s = enhancedCleanItemName(raw_name)
    local transfer_from = s:match("%s*%(Перенос:%s*(.-)%)")
    if transfer_from then
        transfer_from = transfer_from:match("^%s*(.-)%s*$")
        if transfer_from == "" then transfer_from = nil end
    end
    local qual_str = s:match("%[Кач%.%s*(%d+)")
    local quality = qual_str and tonumber(qual_str) or nil
    if quality and quality <= 0 then quality = nil end
    local body = s:gsub("%s*%(Перенос:.-%)", "")
        :gsub("%s*%[Кач%.%s*%d+%-?%d*%]", "")
        :gsub("%s*%(x%d+%)", "")
        :gsub("%s*%(id:%s*%d+%)", "")
        :gsub("%s*%(%d+%s*шт%.?%)", "")
    body = body:match("^%s*(.-)%s*$") or ""
    local enchant = nil
    if not (UI.item_names_reversed and UI.item_names_reversed[body]) then
        local ench_str = body:match("%[%+(%d+)%]$") or body:match("%s%+(%d+)$")
        enchant = ench_str and tonumber(ench_str) or nil
        if enchant and enchant <= 0 then enchant = nil end
    end
    local base_name = stripItemMetadata(s)
    return {
        base_name = base_name,
        enchant = enchant,
        quality = quality,
        transferred_from = transfer_from
    }
end

function cleanItemName(name)
    if not name or name == "" then return "" end
    name = enhancedCleanItemName(name)
    name = name:gsub("%s*%(x%d+%)", "")
    name = name:gsub("%s*%(id:%s*%d+%)", "")
    name = name:gsub("%s*%(%d+%s*шт%.?%)", "")
    name = name:gsub("^[Тт][Юю][Нн][Ии][Нн][Гг]%s+", "")
    for i = 1, #UI.ITEM_PREFIXES do
        local pfx = UI.ITEM_PREFIXES[i]
        local pfx_pattern = "^[" .. pfx:sub(1, 1):upper() .. pfx:sub(1, 1):lower() .. "]" .. pfx:sub(2) .. "%s+"
        name = name:gsub(pfx_pattern, "")
    end
    if name ~= "" then
        local first_byte = name:byte(1)
        if first_byte >= 224 and first_byte <= 255 then
            name = string.char(first_byte - 32) .. name:sub(2)
        elseif first_byte == 184 then
            name = string.char(168) .. name:sub(2)
        end
    end
    return name:match("^%s*(.-)%s*$") or name
end

function formatWireItemName(item)
    if not item then return "" end
    local base = cleanItemName(stripItemMetadata(item.original_name or item.name or ""))
    if base == "" then base = cleanItemName(item.name or "") end
    local parts = { base }
    local ench = tonumber(item.enchant)
    if ench and ench > 0 then table.insert(parts, "+" .. math.floor(ench)) end
    local qual = tonumber(item.quality)
    if qual and qual > 0 then table.insert(parts, "[Кач. " .. math.floor(qual) .. "]") end
    if item.transferred_from and item.transferred_from ~= "" then
        table.insert(parts, "(Перенос: " .. item.transferred_from .. ")")
    end
    return table.concat(parts, " ")
end

function roundPriceToClean(price)
    price = tonumber(price) or 0
    if price < 1000 then return math.floor(price / 10 + 0.5) * 10 end
    local step = 100
    if price >= 100000000 then step = 100000
    elseif price >= 10000000 then step = 10000
    elseif price >= 1000000 then step = 5000
    elseif price >= 100000 then step = 1000
    else step = 100 end
    return math.floor(price / step + 0.5) * step
end

function findRealIndexByName(name)
    if not name or name == "" then return nil end
    local clean_target = enhancedCleanItemName(name):lower()
    if UI.item_names_reversed and UI.item_names_reversed[clean_target] then
        return UI.item_names_reversed[clean_target]
    end
    local stripped_target = cleanItemName(stripItemMetadata(name)):lower()
    if UI.item_names_reversed and UI.item_names_reversed[stripped_target] then
        return UI.item_names_reversed[stripped_target]
    end
    return nil
end

function normalizeServerId(ip_port)
    local address = tostring(ip_port or ""):lower()
    for _, srv in ipairs(UI.RODINA_SERVERS_DATA) do
        if address:find(srv.ip, 1, true)
            or (srv.domain and address:find(srv.domain, 1, true))
            or address == srv.id:lower()
            or address == srv.name:lower() then
            return srv.id
        end
    end
    local ok, hostname = pcall(sampGetCurrentServerName)
    if ok and hostname then
        local host_clean = hostname:lower():gsub("{......}", "")
        for _, srv in ipairs(UI.RODINA_SERVERS_DATA) do
            if host_clean:find(srv.name:lower(), 1, true) then
                return srv.id
            end
        end
    end
    return "Unknown"
end

function warnUnknownServer()
    if UI.unknown_server_warning_shown then return end
    UI.unknown_server_warning_shown = true
    sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Не удалось определить сервер. Данные не отправлены.", -1)
end

function getServerDisplayName(id)
    for _, srv in ipairs(UI.RODINA_SERVERS_DATA) do
        if srv.id == id then return srv.name end
    end
    return id
end

function saveJsonFile(path, data)
    local clean_path = path:gsub("\\", "/")
    if not doesDirectoryExist(UI.ROOT_DIR) then pcall(function() Dependencies.lfs.mkdir(UI.ROOT_DIR) end) end
    if not doesDirectoryExist(UI.ROOT_DIR .. 'data') then pcall(function() Dependencies.lfs.mkdir(UI.ROOT_DIR .. 'data') end) end
    if not doesDirectoryExist(UI.PATH_LOGS) then pcall(function() Dependencies.lfs.mkdir(UI.PATH_LOGS) end) end
    local f = io.open(clean_path, "w")
    if f then f:write(Dependencies.cjson.encode(data)); f:close() end
end

function loadJsonFile(path)
    local f = io.open(path, "r")
    if f then
        local str = f:read("*a")
        f:close()
        local ok, res = pcall(Dependencies.cjson.decode, str)
        return ok and res or {}
    end
    return {}
end

function refreshLogDates()
    if not doesDirectoryExist(UI.ROOT_DIR) then pcall(function() Dependencies.lfs.mkdir(UI.ROOT_DIR) end) end
    if not doesDirectoryExist(UI.PATH_LOGS) then pcall(function() Dependencies.lfs.mkdir(UI.PATH_LOGS) end) end
    local files = {}
    local ok_dir, iter, dir_obj = pcall(function() return Dependencies.lfs.dir(UI.PATH_LOGS) end)
    if ok_dir and iter and dir_obj then
        for file in iter, dir_obj do
            if file:match("^%d%d%d%d%-%d%d%-%d%d%.json$") then
                table.insert(files, file:sub(1, -6))
            end
        end
    end
    table.sort(files, function(a, b) return a > b end)
    LogsState.logs_dates_cache = files
end

function loadLogsForDate(date_str)
    local path = UI.PATH_LOGS .. date_str .. ".json"
    return loadJsonFile(path)
end

function updateLogView()
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

function calculateTodayStats()
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

function sendTelegramNotification(transaction)
    if not isTokenVerified() then return end
    local ip, port = sampGetCurrentServerAddress()
    local srv_id = normalizeServerId(ip .. ":" .. port)
    if srv_id == "Unknown" then
        warnUnknownServer()
        return
    end
    local ok_money, money_val = pcall(getPlayerMoney)
    local current_balance = ok_money and money_val or 0
    local my_nick = getSafeLocalNickname()
    local other_nick = (transaction.player or "Unknown"):gsub("_", " ")
    local is_sale_tx = (transaction.type == "sale")
    local qty = math.max(1, math.floor(tonumber(transaction.amount) or 1))
    local tot = math.max(0, math.floor(tonumber(transaction.total) or 0))
    local unit_p = qty > 0 and math.floor(tot / qty) or math.floor(tonumber(transaction.price) or 0)
    local resolved_item_id = tonumber(transaction.model_id or transaction.item_id) or findRealIndexByName(transaction.item) or 0
    local avg_buy_price = 0
    local item_profit = 0
    if is_sale_tx then
        avg_buy_price = getAveragePriceForItem({ name = transaction.item, model_id = resolved_item_id, quality = transaction.quality }, "buy", false) or 0
        if avg_buy_price > 0 then
            item_profit = math.floor((unit_p - avg_buy_price) * qty)
        end
    end
    local payload = {
        secret_key = Settings.api_key,
        data = {
            type = transaction.type,
            trade_type = is_sale_tx and "sell" or "buy",
            player = other_nick,
            buyer = other_nick,
            seller_nick = is_sale_tx and my_nick or other_nick,
            buyer_nick = is_sale_tx and other_nick or my_nick,
            item = transaction.item or "Unknown",
            item_id = resolved_item_id,
            quality = tonumber(transaction.quality) or 0,
            enchant = tonumber(transaction.enchant) or 0,
            amount = qty,
            quantity = qty,
            price = unit_p,
            unit_price = unit_p,
            total = tot,
            timestamp = tonumber(transaction.timestamp) or os.time(),
            tax_percent = 0,
            tax_amount = 0,
            net_total = tot,
            est_item_profit = item_profit,
            avg_buy_price = avg_buy_price,
            server = srv_id,
            server_id = srv_id,
            balance = current_balance,
            earned = LogsState.today.earned,
            spent = LogsState.today.spent,
            profit = LogsState.today.earned - LogsState.today.spent,
            account = my_nick
        }
    }
    if transaction.type == "car_sale" then
        payload.data.car_name = transaction.item or "Unknown"
    end
    signedRequest("POST", "/notify", payload)
end

function sendDisconnectNotification(reason)
    if not isTokenVerified() then return end
    local now = os.time()
    if now - (State.last_disconnect_notif_time or 0) < 60 then return end
    State.last_disconnect_notif_time = now
    local ip, port = sampGetCurrentServerAddress()
    local server_id = normalizeServerId(ip .. ":" .. port)
    local server_name = getServerDisplayName(server_id)
    clearMobileMarketplace(true)
    signedRequest("POST", "/notify", {
        secret_key = Settings.api_key,
        data = {
            type = "connection_status",
            reason = tostring(reason or "Unknown"),
            server = tostring(server_name or "Unknown"),
            account = tostring(getSafeLocalNickname() or "Unknown")
        }
    })
end

function sendPayDayData()
    if not State.payday.active then return end
    State.payday.active = false
    Tasks.remove_by_name("payday_fallback")
    if not isTokenVerified() then return end
    signedRequest("POST", "/notify", {
        secret_key = Settings.api_key,
        data = {
            type = "payday",
            deposit = tonumber(State.payday.data.dep) or 0,
            deposit_current = tonumber(State.payday.data.dep_cur) or 0,
            bank = tonumber(State.payday.data.bank) or 0,
            bank_current = tonumber(State.payday.data.bank_cur) or 0,
            exp = tonumber(State.payday.data.exp) or 0,
            exp_current = tonumber(State.payday.data.exp_cur) or 0,
            exp_max = tonumber(State.payday.data.exp_max) or 0,
            az = tonumber(State.payday.data.az) or 0,
            az_current = tonumber(State.payday.data.az_cur) or 0,
            level = tonumber(State.payday.data.lvl) or 0,
            shard = State.payday.data.shard and tostring(State.payday.data.shard) or "",
            account = tostring(getSafeLocalNickname() or "Unknown")
        }
    })
end

function addTransactionLog(transaction, source)
    if not transaction then return end

    local signature = table.concat({
        tostring(transaction.type or ""),
        tostring(transaction.item or ""):lower():gsub("%s+", " "),
        tostring(tonumber(transaction.amount) or 1),
        tostring(tonumber(transaction.total) or 0)
    }, "\0")
    local now = os.clock()
    for cached_signature, sources in pairs(State.recent_transactions) do
        local latest = math.max(sources.shop_message or 0, sources.success_message or 0)
        if now - latest > 5 then State.recent_transactions[cached_signature] = nil end
    end
    local sources = State.recent_transactions[signature] or {}
    local duplicate_source = source == "shop_message" and "success_message" or "shop_message"
    local previous = sources[duplicate_source]
    if previous and now - previous <= 5 then
        sources[source] = now
        State.recent_transactions[signature] = sources
        return
    end
    sources[source] = now
    State.recent_transactions[signature] = sources

    if not transaction.model_id or tonumber(transaction.model_id) <= 0 then
        transaction.model_id = findRealIndexByName(transaction.item) or 0
    end

    if not doesDirectoryExist(UI.PATH_LOGS) then Dependencies.lfs.mkdir(UI.PATH_LOGS) end
    local current_date_str = os.date("%Y-%m-%d")
    local file_path = UI.PATH_LOGS .. current_date_str .. ".json"
    local day_logs = loadJsonFile(file_path)
    table.insert(day_logs, transaction)
    saveJsonFile(file_path, day_logs)
    if updateMobileMarketplaceFromTransaction then
        updateMobileMarketplaceFromTransaction(transaction)
    end
    calculateTodayStats()
    if UI.active_tab == 3 then
        refreshLogDates()
        LogsState.cached_income, LogsState.cached_expense = updateLogView()
    end
    sendTelegramNotification(transaction)
end

UI.config_sell = loadJsonFile(UI.PATH_CFG_SELL)
UI.config_buy = loadJsonFile(UI.PATH_CFG_BUY)
UI.average_prices = {}
UI.daily_prices = {}
UI.average_prices_by_id = {}
UI.caches_loaded = false
ApiState.vip_users_cache = loadJsonFile(UI.PATH_VIP_CACHE)
StateArbitrage.blacklist = loadJsonFile(UI.PATH_ARB_BLACKLIST)
if type(StateArbitrage.blacklist) ~= "table" then StateArbitrage.blacklist = {} end

local function readFileAsync(path)
    local ok_t, th = pcall(function()
        return Dependencies.effil.thread(function(p)
            local f = io.open(p, "r")
            if not f then return nil end
            local s = f:read("*a")
            f:close()
            return s
        end)(path)
    end)
    if ok_t and th then
        while not State.is_terminating do
            local ok_s, st = pcall(function() return th:status() end)
            if not ok_s then break end
            if st == 'completed' then
                local ok_g, content = pcall(function() return th:get() end)
                return ok_g and content or nil
            elseif st ~= 'running' and st ~= 'paused' then
                break
            end
            wait(0)
        end
        return nil
    end
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

UI.loaded_sets = loadJsonFile(UI.PATH_SETTINGS)
if UI.loaded_sets.auto_name ~= nil then Settings.auto_name = UI.loaded_sets.auto_name end
if UI.loaded_sets.shop_name then Settings.shop_name = UI.loaded_sets.shop_name end
if UI.loaded_sets.api_key then Settings.api_key = UI.loaded_sets.api_key end
if UI.loaded_sets.auto_pr then Settings.auto_pr = UI.loaded_sets.auto_pr end
if UI.loaded_sets.show_live_hud ~= nil then Settings.show_live_hud = UI.loaded_sets.show_live_hud else Settings.show_live_hud = true end
if UI.loaded_sets.show_float_btn ~= nil then Settings.show_float_btn = UI.loaded_sets.show_float_btn else Settings.show_float_btn = true end
if UI.loaded_sets.hud_pos_x then Settings.hud_pos_x = UI.loaded_sets.hud_pos_x end
if UI.loaded_sets.hud_pos_y then Settings.hud_pos_y = UI.loaded_sets.hud_pos_y end
if UI.loaded_sets.rm_btn_x then Settings.rm_btn_x = UI.loaded_sets.rm_btn_x end
if UI.loaded_sets.rm_btn_y then Settings.rm_btn_y = UI.loaded_sets.rm_btn_y end
if UI.loaded_sets.trade_delay then Settings.trade_delay = UI.loaded_sets.trade_delay else Settings.trade_delay = 1200 end
if UI.loaded_sets.win_w_percent then Settings.win_w_percent = UI.loaded_sets.win_w_percent end
if UI.loaded_sets.win_h_percent then Settings.win_h_percent = UI.loaded_sets.win_h_percent end
if UI.loaded_sets.ui_scale then Settings.ui_scale = UI.loaded_sets.ui_scale end
if UI.loaded_sets.last_nickname and UI.loaded_sets.last_nickname ~= "" then
    Settings.last_nickname = UI.loaded_sets.last_nickname
    UI.player_nickname = UI.loaded_sets.last_nickname
end
if UI.loaded_sets.last_nickname_rus and UI.loaded_sets.last_nickname_rus ~= "" then
    Settings.last_nickname_rus = UI.loaded_sets.last_nickname_rus
    UI.player_nickname_rus = UI.loaded_sets.last_nickname_rus
end
if UI.loaded_sets.last_account_id and tonumber(UI.loaded_sets.last_account_id) > 0 then
    Settings.last_account_id = tonumber(UI.loaded_sets.last_account_id)
    UI.account_id = Settings.last_account_id
end

if isTokenPresent() then
    ApiState.token_state = "checking"
else
    ApiState.token_state = "missing"
end

UI.b_auto_name = Dependencies.imgui.new.bool(Settings.auto_name)
UI.b_show_hud = Dependencies.imgui.new.bool(Settings.show_live_hud)
UI.b_show_float = Dependencies.imgui.new.bool(Settings.show_float_btn)
UI.buf_shop_name = Dependencies.ffi.new('char[64]', Settings.shop_name)
UI.buf_api_key = Dependencies.ffi.new('char[128]', Settings.api_key)
UI.sl_delay = Dependencies.imgui.new.int(Settings.trade_delay)
UI.sl_win_w = Dependencies.imgui.new.int(math.floor(Settings.win_w_percent * 100))
UI.sl_win_h = Dependencies.imgui.new.int(math.floor(Settings.win_h_percent * 100))
UI.sl_ui_scale = Dependencies.imgui.new.int(math.floor(Settings.ui_scale * 100))

UI.inv_items = loadJsonFile(UI.PATH_INV)

function saveSessionToken()
    saveJsonFile(UI.PATH_SESSION, { token = Marketplace.session_token or "" })
end

function loadSessionToken()
    local data = loadJsonFile(UI.PATH_SESSION)
    if type(data) == "table" and type(data.token) == "string" then
        Marketplace.session_token = data.token
    end
end

function saveLiveShopState()
    saveJsonFile(UI.PATH_LIVE_SHOP, {
        sell = Marketplace.sell or {},
        buy = Marketplace.buy or {},
        is_active = Marketplace.enabled,
        marketplace_enabled = Marketplace.enabled,
        marketplace_uid = Marketplace.lavka_uid,
        publish_sell = Marketplace.publish_sell,
        publish_buy = Marketplace.publish_buy,
        saved_at = os.time()
    })
end

function loadLiveShopState()
    local data = loadJsonFile(UI.PATH_LIVE_SHOP)
    if type(data) == "table" and next(data) ~= nil then
        Marketplace.sell = {}
        if type(data.sell) == "table" then
            for k, v in pairs(data.sell) do Marketplace.sell[tonumber(k) or k] = v end
        end
        Marketplace.buy = {}
        if type(data.buy) == "table" then
            for k, v in pairs(data.buy) do Marketplace.buy[tonumber(k) or k] = v end
        end
        local saved_time = tonumber(data.saved_at) or 0
        if (os.time() - saved_time) <= 86400 and (data.is_active or data.marketplace_enabled) then
            Marketplace.enabled = true
            Marketplace.is_cleared = false
            Marketplace.lavka_uid = tonumber(data.marketplace_uid) or os.time()
            Marketplace.publish_sell = data.publish_sell or false
            Marketplace.publish_buy = data.publish_buy or false
            Marketplace.last_sync = 0
        else
            Marketplace.enabled = false
            Marketplace.is_cleared = true
        end
    else
        Marketplace.sell = {}
        Marketplace.buy = {}
    end
end

function countTable(tbl)
    local count = 0
    for _ in pairs(tbl) do count = count + 1 end
    return count
end

function isItemDbEmpty()
    return countTable(UI.item_names) < 10
end

local function fillFields1(line, out)
    local start = 1
    local idx = 0
    local len = #line
    while true do
        idx = idx + 1
        local pos = line:find("\1", start, true)
        if not pos then
            out[idx] = line:sub(start, len)
            break
        end
        out[idx] = line:sub(start, pos - 1)
        start = pos + 1
    end
    return idx
end

local function _itemsDbWorker(names_path, pkg_path, pkg_cpath)
    if pkg_path and pkg_path ~= '' then package.path = pkg_path end
    if pkg_cpath and pkg_cpath ~= '' then package.cpath = pkg_cpath end
    local f = io.open(names_path, "r")
    if not f then return true, "" end
    local raw_str = f:read("*a")
    f:close()
    if not raw_str or raw_str == "" then return true, "" end
    local ok_cjson, cjson = pcall(require, 'cjson')
    if not ok_cjson or not cjson then return false, raw_str end
    local ok_dec, raw_names = pcall(cjson.decode, raw_str)
    if not ok_dec or type(raw_names) ~= "table" then return true, "" end
    local extra_map = {
        [0x0401] = 168, [0x0451] = 184, [0x0404] = 170, [0x0454] = 186,
        [0x0406] = 178, [0x0456] = 179, [0x0407] = 175, [0x0457] = 191,
        [0x0490] = 165, [0x0491] = 180, [0x2116] = 185, [0x2013] = 150,
        [0x2014] = 151, [0x2018] = 145, [0x2019] = 146, [0x201C] = 147,
        [0x201D] = 148, [0x201E] = 132, [0x2026] = 133, [0x00AB] = 171,
        [0x00BB] = 187
    }
    local function toCp1251(str)
        if type(str) ~= 'string' or not str:find("[\128-\255]") then return str end
        local out = {}
        local i, len = 1, #str
        while i <= len do
            local b1 = str:byte(i)
            if b1 < 0x80 then
                out[#out + 1] = string.char(b1)
                i = i + 1
            elseif b1 >= 0xC2 and b1 <= 0xDF and i + 1 <= len then
                local b2 = str:byte(i + 1)
                if b2 >= 0x80 and b2 <= 0xBF then
                    local cp = (b1 - 0xC0) * 64 + (b2 - 0x80)
                    if cp >= 0x0410 and cp <= 0x044F then
                        out[#out + 1] = string.char(cp - 0x0410 + 192)
                    elseif extra_map[cp] then
                        out[#out + 1] = string.char(extra_map[cp])
                    else
                        out[#out + 1] = "?"
                    end
                    i = i + 2
                else
                    return str
                end
            elseif b1 >= 0xE0 and b1 <= 0xEF and i + 2 <= len then
                local b2, b3 = str:byte(i + 1, i + 2)
                if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF then
                    local cp = ((b1 - 0xE0) * 4096) + ((b2 - 0x80) * 64) + (b3 - 0x80)
                    out[#out + 1] = extra_map[cp] and string.char(extra_map[cp]) or "?"
                    i = i + 3
                else
                    return str
                end
            elseif b1 >= 0xF0 and b1 <= 0xF4 and i + 3 <= len then
                i = i + 4
            else
                return str
            end
        end
        return table.concat(out)
    end
    local items = {}
    for k, v in pairs(raw_names) do
        local id_num = tonumber(k)
        if id_num then
            local raw_name = type(v) == "table" and (v.n or "") or tostring(v)
            local final_name = toCp1251(tostring(raw_name)):gsub("[\1\n\r]", "")
            items[#items + 1] = { id = id_num, name = final_name }
        end
    end
    table.sort(items, function(a, b) return a.id < b.id end)
    local lines = {}
    for i = 1, #items do
        local it = items[i]
        lines[i] = tostring(it.id) .. "\1" .. it.name
    end
    return true, table.concat(lines, "\n")
end

local function _pricesLoadWorker(prices_path, pkg_path, pkg_cpath)
    if pkg_path and pkg_path ~= '' then package.path = pkg_path end
    if pkg_cpath and pkg_cpath ~= '' then package.cpath = pkg_cpath end
    local f = io.open(prices_path, "r")
    if not f then return true, "" end
    local raw_str = f:read("*a")
    f:close()
    if not raw_str or raw_str == "" then return true, "" end
    local ok_cjson, cjson = pcall(require, 'cjson')
    if not ok_cjson or not cjson then return false, raw_str end
    local ok_dec, loaded = pcall(cjson.decode, raw_str)
    if not ok_dec or type(loaded) ~= "table" then return true, "" end
    local lines = {}
    for p_key, p_entry in pairs(loaded) do
        if type(p_entry) == "table" and type(p_key) == "string" then
            local pid = tonumber(p_entry.id) or 0
            local qt = tonumber(p_entry.qt)
            if not qt then
                local q_str = p_key:match("%[Кач%.%s*(%d+)")
                qt = q_str and (math.floor(tonumber(q_str) / 100) * 100) or -1
            end
            local k_clean = p_key:gsub("[\1\n\r]", "")
            lines[#lines + 1] = table.concat({
                k_clean,
                pid,
                qt,
                tonumber(p_entry.fair) or 0,
                tonumber(p_entry.sell) or 0,
                tonumber(p_entry.buy) or 0,
                tonumber(p_entry.min) or 0,
                tonumber(p_entry.max) or 0,
                tostring(p_entry.confidence or "low"),
                tonumber(p_entry.deals) or 0,
                tonumber(p_entry.vol) or 0,
                tonumber(p_entry.price) or 0
            }, "\1")
        end
    end
    return true, table.concat(lines, "\n")
end

local function finalizeItemNamesConfig()
    local sell_config_changed = false
    for _, item in ipairs(UI.config_sell) do
        local item_id = item.model_id or item.index
        local db_name = item_id and UI.item_names[tostring(item_id)]
        if db_name and item.name ~= db_name then
            item.name = db_name
            sell_config_changed = true
        end
    end
    local buy_config_changed = false
    for _, item in ipairs(UI.config_buy) do
        local item_id = item.model_id or item.index
        local db_name = item_id and UI.item_names[tostring(item_id)]
        if db_name and item.name ~= db_name then
            item.name = db_name
            buy_config_changed = true
        end
    end
    if sell_config_changed then saveJsonFile(UI.PATH_CFG_SELL, UI.config_sell) end
    if buy_config_changed then saveJsonFile(UI.PATH_CFG_BUY, UI.config_buy) end
    ui_cache_sell.query = nil
    ui_cache_sell.index = nil
    ui_cache_buy.query = nil
    ui_cache_buy.index = nil
    for _, shop in ipairs(StateMarket.shops_list) do
        if shop.sell_list then
            for _, item in ipairs(shop.sell_list) do
                if item.model_id and UI.item_names[tostring(item.model_id)] and tostring(item.name):find("^Предмет_%d+$") then
                    item.name = UI.item_names[tostring(item.model_id)]
                    item.base_name = item.name
                end
            end
        end
        if shop.buy_list then
            for _, item in ipairs(shop.buy_list) do
                if item.model_id and UI.item_names[tostring(item.model_id)] and tostring(item.name):find("^Предмет_%d+$") then
                    item.name = UI.item_names[tostring(item.model_id)]
                    item.base_name = item.name
                end
            end
        end
    end
    StateMarket.search_cache_key = nil
end

local function processItemNamesAsync()
    local names_path = UI.PATH_NAMES:gsub("\\", "/")
    local ok_th, th = pcall(function()
        return Dependencies.effil.thread(_itemsDbWorker)(names_path, package.path, package.cpath)
    end)
    local worker_ok, payload = false, nil
    if ok_th and th then
        while not State.is_terminating do
            local ok_s, st = pcall(function() return th:status() end)
            if not ok_s then break end
            if st == 'completed' then
                local ok_g, a, b = pcall(function() return th:get() end)
                if ok_g then
                    worker_ok = a == true
                    payload = b
                end
                break
            elseif st ~= 'running' and st ~= 'paused' then
                break
            end
            wait(0)
        end
    end
    local new_names = {}
    local new_reversed = {}
    local new_db = {}
    if worker_ok then
        if type(payload) == "string" and payload ~= "" then
            local processed = 0
            local slice_start = os.clock()
            local fields = {}
            for line in payload:gmatch("([^\n]+)") do
                if State.is_terminating then return end
                local n = fillFields1(line, fields)
                if n >= 2 then
                    local id_str = fields[1]
                    local final_name = fields[2]
                    new_names[id_str] = final_name
                    if final_name ~= "" then
                        local id_num = tonumber(id_str)
                        local clean_key = enhancedCleanItemName(final_name):lower()
                        new_reversed[clean_key] = id_num
                        local stripped_key = cleanItemName(final_name):lower()
                        if stripped_key ~= "" and not new_reversed[stripped_key] then
                            new_reversed[stripped_key] = id_num
                        end
                        if id_num then
                            new_db[#new_db + 1] = { name = final_name, index = id_num }
                        end
                    end
                end
                processed = processed + 1
                if processed % 25 == 0 or (os.clock() - slice_start) >= 0.002 then
                    wait(0)
                    slice_start = os.clock()
                end
            end
        end
    else
        local raw_str = type(payload) == "string" and payload or readFileAsync(UI.PATH_NAMES)
        if type(raw_str) == "string" and raw_str ~= "" then
            local ok_dec, raw_names = pcall(Dependencies.cjson.decode, raw_str)
            wait(0)
            if ok_dec and type(raw_names) == "table" then
                local processed = 0
                local slice_start = os.clock()
                for k, v in pairs(raw_names) do
                    if State.is_terminating then return end
                    local id_str = tostring(k)
                    local raw_name = type(v) == "table" and (v.n or "") or tostring(v)
                    local final_name = utf8ToCp1251Fast(tostring(raw_name))
                    new_names[id_str] = final_name
                    if final_name ~= "" then
                        local id_num = tonumber(id_str)
                        local clean_key = enhancedCleanItemName(final_name):lower()
                        new_reversed[clean_key] = id_num
                        local stripped_key = cleanItemName(final_name):lower()
                        if stripped_key ~= "" and not new_reversed[stripped_key] then
                            new_reversed[stripped_key] = id_num
                        end
                        if id_num then
                            new_db[#new_db + 1] = { name = final_name, index = id_num }
                        end
                    end
                    processed = processed + 1
                    if processed % 25 == 0 or (os.clock() - slice_start) >= 0.002 then
                        wait(0)
                        slice_start = os.clock()
                    end
                end
                wait(0)
                table.sort(new_db, function(a, b) return a.index < b.index end)
            end
        end
    end
    UI.item_names = new_names
    UI.item_names_reversed = new_reversed
    UI.db_items = new_db
    finalizeItemNamesConfig()
end

function loadItemNamesFromFile(on_done)
    lua_thread.create(function()
        processItemNamesAsync()
        if on_done then pcall(on_done) end
    end)
end

function startStartupCacheLoad()
    lua_thread.create(function()
        processItemNamesAsync()
        wait(0)
        local prices_path = UI.PATH_PRICES:gsub("\\", "/")
        local ok_th, th = pcall(function()
            return Dependencies.effil.thread(_pricesLoadWorker)(prices_path, package.path, package.cpath)
        end)
        local worker_ok, payload = false, nil
        if ok_th and th then
            while not State.is_terminating do
                local ok_s, st = pcall(function() return th:status() end)
                if not ok_s then break end
                if st == 'completed' then
                    local ok_g, a, b = pcall(function() return th:get() end)
                    if ok_g then
                        worker_ok = a == true
                        payload = b
                    end
                    break
                elseif st ~= 'running' and st ~= 'paused' then
                    break
                end
                wait(0)
            end
        end
        if worker_ok then
            if type(payload) == "string" and payload ~= "" then
                local new_prices = {}
                local new_by_id = {}
                local processed = 0
                local slice_start = os.clock()
                local fields = {}
                for line in payload:gmatch("([^\n]+)") do
                    if State.is_terminating then return end
                    local n = fillFields1(line, fields)
                    if n >= 12 then
                        local item_id = tonumber(fields[2]) or 0
                        local qt = tonumber(fields[3]) or -1
                        local entry = {
                            id = item_id,
                            qt = qt,
                            fair = tonumber(fields[4]) or 0,
                            sell = tonumber(fields[5]) or 0,
                            buy = tonumber(fields[6]) or 0,
                            min = tonumber(fields[7]) or 0,
                            max = tonumber(fields[8]) or 0,
                            confidence = fields[9],
                            deals = tonumber(fields[10]) or 0,
                            vol = tonumber(fields[11]) or 0,
                            price = tonumber(fields[12]) or 0,
                            source = "engine"
                        }
                        new_prices[fields[1]] = entry
                        if item_id > 0 then
                            if qt >= 0 then
                                new_by_id[tostring(item_id) .. "_q" .. tostring(qt)] = entry
                            else
                                new_by_id[item_id] = entry
                            end
                        end
                    end
                    processed = processed + 1
                    if processed % 30 == 0 or (os.clock() - slice_start) >= 0.002 then
                        wait(0)
                        slice_start = os.clock()
                    end
                end
                UI.average_prices = new_prices
                UI.average_prices_by_id = new_by_id
            end
        else
            local prices_raw = type(payload) == "string" and payload or readFileAsync(UI.PATH_PRICES)
            if type(prices_raw) == "string" and prices_raw ~= "" then
                local ok_dec, loaded_prices = pcall(Dependencies.cjson.decode, prices_raw)
                wait(0)
                if ok_dec and type(loaded_prices) == "table" then
                    local new_by_id = {}
                    local processed = 0
                    local slice_start = os.clock()
                    for p_key, p_entry in pairs(loaded_prices) do
                        if State.is_terminating then return end
                        if type(p_entry) == "table" then
                            local pid = tonumber(p_entry.id) or 0
                            local qt = tonumber(p_entry.qt)
                            if not qt then
                                local q_str = tostring(p_key):match("%[Кач%.%s*(%d+)")
                                qt = q_str and getQualityTier(tonumber(q_str)) or -1
                                p_entry.qt = qt
                            end
                            if pid > 0 then
                                if qt >= 0 then
                                    new_by_id[tostring(pid) .. "_q" .. tostring(qt)] = p_entry
                                else
                                    new_by_id[pid] = p_entry
                                end
                            end
                        end
                        processed = processed + 1
                        if processed % 30 == 0 or (os.clock() - slice_start) >= 0.002 then
                            wait(0)
                            slice_start = os.clock()
                        end
                    end
                    UI.average_prices = loaded_prices
                    UI.average_prices_by_id = new_by_id
                end
            end
        end
        UI.caches_loaded = true
    end)
end
loadItemNamesFromFile()

function safeParseMarketItems(ids_tbl, counts_tbl, prices_tbl, names_tbl)
    local list = {}
    if type(ids_tbl) ~= "table" then return list end
    local function pushEntry(k)
        local model_id = tonumber(ids_tbl[k]) or 0
        if model_id <= 0 then return end
        local c_val = type(counts_tbl) == "table" and (counts_tbl[k] or counts_tbl[tostring(k)] or counts_tbl[tonumber(k)] or 0) or 0
        local p_val = type(prices_tbl) == "table" and (prices_tbl[k] or prices_tbl[tostring(k)] or prices_tbl[tonumber(k)] or 0) or 0
        local n_val = type(names_tbl) == "table" and (names_tbl[k] or names_tbl[tostring(k)] or names_tbl[tonumber(k)]) or nil
        local item_name = UI.item_names[tostring(model_id)] or ("Предмет_" .. tostring(model_id))
        if type(n_val) == "string" and n_val ~= "" then
            item_name = utf8ToCp1251Fast(n_val)
        end
        local meta = parseItemMetadata(item_name)
        list[#list + 1] = {
            name = item_name,
            base_name = (meta.base_name ~= "" and meta.base_name) or item_name,
            model_id = model_id,
            amount = tonumber(c_val) or 0,
            price = tonumber(p_val) or 0,
            enchant = meta.enchant,
            quality = meta.quality,
            transferred_from = meta.transferred_from
        }
    end
    local n_arr = #ids_tbl
    if n_arr > 0 then
        for k = 1, n_arr do
            pushEntry(k)
        end
    else
        local keys = {}
        for k, _ in pairs(ids_tbl) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
        for i = 1, #keys do
            pushEntry(keys[i])
        end
    end
    return list
end

function getPriceRecordForItem(item)
    if not item or type(UI.average_prices) ~= "table" then return nil end
    local mid = tonumber(item.model_id) or tonumber(item.index)
    local q_val = tonumber(item.quality)
    if (not q_val or q_val <= 0) and type(item.name) == "string" then
        local q_match = item.name:match("%[Кач%.%s*(%d+)")
        if q_match then q_val = tonumber(q_match) end
    end
    local q_tier = getQualityTier(q_val)
    if q_tier ~= nil then
        if mid and mid > 0 and UI.average_prices_by_id then
            local rec_q = UI.average_prices_by_id[tostring(mid) .. "_q" .. tostring(q_tier)]
            if rec_q then return rec_q end
        end
        if item.name then
            local base_clean = cleanItemName(stripItemMetadata(item.original_name or item.name))
            local tier_key = base_clean .. " [Кач. " .. q_tier .. "-" .. (q_tier + 99) .. "]"
            if UI.average_prices[tier_key] then return UI.average_prices[tier_key] end
            local lower_tier = to_lower(tier_key)
            for db_name, db_data in pairs(UI.average_prices) do
                if to_lower(db_name) == lower_tier then return db_data end
            end
        end
    end
    if mid and mid > 0 and UI.average_prices_by_id and UI.average_prices_by_id[mid] then
        return UI.average_prices_by_id[mid]
    end
    if not item.name then return nil end
    local target_name = stripItemMetadata(item.original_name or item.name)
    local clean_key_1 = enhancedCleanItemName(target_name)
    local clean_key_2 = cleanItemName(target_name)
    local found_data = UI.average_prices[clean_key_1] or UI.average_prices[clean_key_2]
    if not found_data then
        local lower_k = to_lower(clean_key_2)
        for db_name, db_data in pairs(UI.average_prices) do
            if to_lower(db_name) == lower_k then
                found_data = db_data
                break
            end
        end
    end
    return found_data
end

function getAveragePriceForItem(item, mode, strict)
    if not item or (not item.name and not item.model_id and not item.index) then return nil end
    mode = mode or "sell"
    local found_data = getPriceRecordForItem(item)
    if not found_data then return nil end
    local fair_val = tonumber(found_data.fair) or tonumber(found_data.price) or 0
    local final_price = nil
    if mode == "fair" then
        final_price = fair_val > 0 and fair_val or found_data.sell
    elseif mode == "sell" then
        final_price = found_data.sell
        if (not final_price or final_price == 0) and not strict then
            if fair_val > 0 then
                final_price = fair_val
            elseif found_data.buy and found_data.buy > 0 then
                final_price = math.floor(found_data.buy * 1.2)
            end
        end
    elseif mode == "buy" then
        final_price = found_data.buy
        if (not final_price or final_price == 0) and not strict then
            local base = (found_data.sell and found_data.sell > 0) and found_data.sell or fair_val
            if base and base > 0 then
                final_price = math.floor(base * 0.8)
            end
        end
    end
    if (not final_price or final_price == 0) and not strict then
        final_price = fair_val > 0 and fair_val or found_data.price
    end
    if final_price and final_price > 0 then return final_price end
    return nil
end

local function _pricesParseWorker(body, prices_path, meta_path, now_ts, pkg_path, pkg_cpath)
    if pkg_path and pkg_path ~= '' then package.path = pkg_path end
    if pkg_cpath and pkg_cpath ~= '' then package.cpath = pkg_cpath end
    local ok_cjson, cjson = pcall(require, 'cjson')
    if not ok_cjson or not cjson then
        return false, 'no_cjson'
    end
    local ok_dec, data = pcall(cjson.decode, body)
    if not ok_dec or type(data) ~= 'table' then
        return true, 0, ''
    end
    local extra_map = {
        [0x0401] = 168, [0x0451] = 184, [0x0404] = 170, [0x0454] = 186,
        [0x0406] = 178, [0x0456] = 179, [0x0407] = 175, [0x0457] = 191,
        [0x0490] = 165, [0x0491] = 180, [0x2116] = 185, [0x2013] = 150,
        [0x2014] = 151, [0x2018] = 145, [0x2019] = 146, [0x201C] = 147,
        [0x201D] = 148, [0x201E] = 132, [0x2026] = 133, [0x00AB] = 171,
        [0x00BB] = 187
    }
    local function toCp1251(str)
        if type(str) ~= 'string' or not str:find("[\128-\255]") then return str end
        local out = {}
        local i, len = 1, #str
        while i <= len do
            local b1 = str:byte(i)
            if b1 < 0x80 then
                out[#out + 1] = string.char(b1)
                i = i + 1
            elseif b1 >= 0xC2 and b1 <= 0xDF and i + 1 <= len then
                local b2 = str:byte(i + 1)
                if b2 >= 0x80 and b2 <= 0xBF then
                    local cp = (b1 - 0xC0) * 64 + (b2 - 0x80)
                    if cp >= 0x0410 and cp <= 0x044F then
                        out[#out + 1] = string.char(cp - 0x0410 + 192)
                    elseif extra_map[cp] then
                        out[#out + 1] = string.char(extra_map[cp])
                    else
                        out[#out + 1] = "?"
                    end
                    i = i + 2
                else
                    return str
                end
            elseif b1 >= 0xE0 and b1 <= 0xEF and i + 2 <= len then
                local b2, b3 = str:byte(i + 1, i + 2)
                if b2 >= 0x80 and b2 <= 0xBF and b3 >= 0x80 and b3 <= 0xBF then
                    local cp = ((b1 - 0xE0) * 4096) + ((b2 - 0x80) * 64) + (b3 - 0x80)
                    out[#out + 1] = extra_map[cp] and string.char(extra_map[cp]) or "?"
                    i = i + 3
                else
                    return str
                end
            elseif b1 >= 0xF0 and b1 <= 0xF4 and i + 3 <= len then
                i = i + 4
            else
                return str
            end
        end
        return table.concat(out)
    end
    local prefixes = {
        "Улучшение оружия", "Унив. тюнинг", "Виз. тюнинг", "Тех. тюнинг", "Авто. номер",
        "Аксессуар", "Сертификат", "Приманка", "Саженец", "Улучшение",
        "Винила", "Объект", "Одежда", "Телефон", "Урожай", "Чертёж",
        "Предмет", "Актер", "Ларец", "Рыба", "Семя", "Туша", "Шкура", "Ящик"
    }
    local function cleanName(name)
        if not name or name == "" then return "" end
        name = name:gsub("{%x%x%x%x%x%x}", ""):gsub("^[оеш]?[втг]%s+", "")
        name = name:match("^%s*(.-)%s*$") or ""
        name = name:gsub("%s*%(x%d+%)", ""):gsub("%s*%(id:%s*%d+%)", ""):gsub("%s*%(%d+%s*шт%.?%)", "")
        name = name:gsub("^[Тт][Юю][Нн][Ии][Нн][Гг]%s+", "")
        for i = 1, #prefixes do
            local pfx = prefixes[i]
            local pat = "^[" .. pfx:sub(1, 1):upper() .. pfx:sub(1, 1):lower() .. "]" .. pfx:sub(2) .. "%s+"
            name = name:gsub(pat, "")
        end
        if name ~= "" then
            local fb = name:byte(1)
            if fb >= 224 and fb <= 255 then
                name = string.char(fb - 32) .. name:sub(2)
            elseif fb == 184 then
                name = string.char(168) .. name:sub(2)
            end
        end
        return name:match("^%s*(.-)%s*$") or name
    end
    local function roundClean(price)
        price = tonumber(price) or 0
        if price < 1000 then return math.floor(price / 10 + 0.5) * 10 end
        local step = 100
        if price >= 100000000 then step = 100000
        elseif price >= 10000000 then step = 10000
        elseif price >= 1000000 then step = 5000
        elseif price >= 100000 then step = 1000 end
        return math.floor(price / step + 0.5) * step
    end
    local function safeNum(v, def)
        if type(v) == "number" then return v end
        if type(v) == "string" then return tonumber(v) or def end
        return def
    end
    local new_prices = {}
    local lines = {}
    local count = 0
    for raw_name, info in pairs(data) do
        if type(info) == "table" and type(raw_name) == "string" then
            local clean_key = cleanName(toCp1251(raw_name)):gsub("[\1\n\r]", "")
            local item_id = safeNum(info.id, 0)
            local fair_price = safeNum(info.f, 0)
            local daily_sell = safeNum(info.s, 0)
            local daily_buy = safeNum(info.b, 0)
            local min_p = safeNum(info.min, 0)
            local max_p = safeNum(info.max, 0)
            local conf = type(info.conf) == "string" and info.conf or "low"
            local deals = safeNum(info.cnt, 0)
            local vol = safeNum(info.v, 0)
            if clean_key ~= "" and (fair_price > 0 or daily_sell > 0 or daily_buy > 0) then
                local base_sell = daily_sell > 0 and daily_sell or fair_price
                local qt = safeNum(info.qt, -1)
                if qt < 0 then
                    local q_str = clean_key:match("%[Кач%.%s*(%d+)")
                    qt = q_str and (math.floor(tonumber(q_str) / 100) * 100) or -1
                end
                local f_val = roundClean(fair_price > 0 and fair_price or base_sell)
                local s_val = roundClean(base_sell)
                local b_val = roundClean(daily_buy)
                local mn_val = roundClean(min_p)
                local mx_val = roundClean(max_p)
                local p_val = fair_price > 0 and fair_price or daily_sell
                new_prices[clean_key] = {
                    id = item_id, qt = qt, fair = f_val, sell = s_val, buy = b_val,
                    min = mn_val, max = mx_val, confidence = conf, deals = deals,
                    vol = vol, price = p_val, source = "engine"
                }
                lines[#lines + 1] = table.concat({
                    clean_key, item_id, qt, f_val, s_val, b_val, mn_val, mx_val, conf, deals, vol, p_val
                }, "\1")
                count = count + 1
            end
        end
    end
    if count > 0 then
        local ok_e, enc = pcall(cjson.encode, new_prices)
        if ok_e and type(enc) == "string" then
            local f1 = io.open(prices_path, "w")
            if f1 then f1:write(enc); f1:close() end
        end
        local ok_m, menc = pcall(cjson.encode, { last_update = now_ts })
        if ok_m and type(menc) == "string" then
            local f2 = io.open(meta_path, "w")
            if f2 then f2:write(menc); f2:close() end
        end
    end
    return true, count, table.concat(lines, "\n")
end

function api_DownloadAveragePrices()
    if not isTokenVerified() then
        if isTokenPresent() then
            ApiState.pending_manual_price_download = true
            if not ApiState.vip_checking_in_progress then checkVipStatus(Settings.api_key, 0) end
            sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Скачивание начнётся после проверки ключа.", -1)
        else
            sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Требуется привязка Telegram ключа!", -1)
        end
        return
    end
    if State.is_downloading_prices then return end
    local ip, port = sampGetCurrentServerAddress()
    local srv_id = normalizeServerId(ip .. ":" .. port)
    if srv_id == "Unknown" then
        warnUnknownServer()
        return
    end
    State.is_downloading_prices = true
    sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Скачивание средних цен...", -1)
    signedRequest("GET", "/get_prices?server=" .. url_encode(srv_id), nil, function(code, body)
        if code == 200 and body ~= "" then
            lua_thread.create(function()
                if not doesDirectoryExist(UI.ROOT_DIR) then pcall(function() Dependencies.lfs.mkdir(UI.ROOT_DIR) end) end
                local prices_path = UI.PATH_PRICES:gsub("\\", "/")
                local meta_path = UI.PATH_PRICE_META:gsub("\\", "/")
                local ok_th, th = pcall(function()
                    return Dependencies.effil.thread(_pricesParseWorker)(body, prices_path, meta_path, os.time(), package.path, package.cpath)
                end)
                local worker_ok, count, packed = false, 0, ""
                if ok_th and th then
                    while not State.is_terminating do
                        local ok_s, st = pcall(function() return th:status() end)
                        if not ok_s then break end
                        if st == 'completed' then
                            local ok_g, a, b, c = pcall(function() return th:get() end)
                            if ok_g and a then
                                worker_ok = true
                                count = tonumber(b) or 0
                                packed = tostring(c or "")
                            end
                            break
                        elseif st ~= 'running' and st ~= 'paused' then
                            break
                        end
                        wait(0)
                    end
                end
                if worker_ok then
                    if count > 0 and packed ~= "" then
                        local new_prices = {}
                        local new_prices_by_id = {}
                        local processed = 0
                        local slice_start = os.clock()
                        local fields = {}
                        for line in packed:gmatch("([^\n]+)") do
                            if State.is_terminating then
                                State.is_downloading_prices = false
                                return
                            end
                            local n = fillFields1(line, fields)
                            if n >= 12 then
                                local item_id = tonumber(fields[2]) or 0
                                local qt = tonumber(fields[3]) or -1
                                local entry = {
                                    id = item_id,
                                    qt = qt,
                                    fair = tonumber(fields[4]) or 0,
                                    sell = tonumber(fields[5]) or 0,
                                    buy = tonumber(fields[6]) or 0,
                                    min = tonumber(fields[7]) or 0,
                                    max = tonumber(fields[8]) or 0,
                                    confidence = fields[9],
                                    deals = tonumber(fields[10]) or 0,
                                    vol = tonumber(fields[11]) or 0,
                                    price = tonumber(fields[12]) or 0,
                                    source = "engine"
                                }
                                new_prices[fields[1]] = entry
                                if item_id > 0 then
                                    if qt >= 0 then
                                        new_prices_by_id[tostring(item_id) .. "_q" .. tostring(qt)] = entry
                                    else
                                        new_prices_by_id[item_id] = entry
                                    end
                                end
                            end
                            processed = processed + 1
                            if processed % 25 == 0 or (os.clock() - slice_start) >= 0.002 then
                                wait(0)
                                slice_start = os.clock()
                            end
                        end
                        UI.average_prices = new_prices
                        UI.average_prices_by_id = new_prices_by_id
                        sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Средние цены успешно обновлены (" .. count .. ")!", -1)
                    else
                        sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Сервер вернул пустой список цен.", -1)
                    end
                else
                    local ok_dec, data = pcall(Dependencies.cjson.decode, body)
                    wait(0)
                    if ok_dec and type(data) == "table" and next(data) ~= nil then
                        local fallback_count = 0
                        local processed = 0
                        local new_prices = {}
                        local new_prices_by_id = {}
                        local function safeNum(v, def)
                            if type(v) == "number" then return v end
                            if type(v) == "string" then return tonumber(v) or def end
                            return def
                        end
                        for raw_name, info in pairs(data) do
                            if State.is_terminating then
                                State.is_downloading_prices = false
                                return
                            end
                            if type(info) == "table" and type(raw_name) == "string" then
                                local clean_key = cleanItemName(utf8ToCp1251Fast(raw_name))
                                local item_id = safeNum(info.id, 0)
                                local fair_price = safeNum(info.f, 0)
                                local daily_sell = safeNum(info.s, 0)
                                local daily_buy = safeNum(info.b, 0)
                                local min_p = safeNum(info.min, 0)
                                local max_p = safeNum(info.max, 0)
                                local conf = type(info.conf) == "string" and info.conf or "low"
                                local deals = safeNum(info.cnt, 0)
                                local vol = safeNum(info.v, 0)
                                if fair_price > 0 or daily_sell > 0 or daily_buy > 0 then
                                    local base_sell = daily_sell > 0 and daily_sell or fair_price
                                    local qt = safeNum(info.qt, -1)
                                    if qt < 0 then
                                        local q_str = clean_key:match("%[Кач%.%s*(%d+)")
                                        qt = q_str and getQualityTier(tonumber(q_str)) or -1
                                    end
                                    local entry = {
                                        id = item_id,
                                        qt = qt,
                                        fair = roundPriceToClean(fair_price > 0 and fair_price or base_sell),
                                        sell = roundPriceToClean(base_sell),
                                        buy = roundPriceToClean(daily_buy),
                                        min = roundPriceToClean(min_p),
                                        max = roundPriceToClean(max_p),
                                        confidence = conf,
                                        deals = deals,
                                        vol = vol,
                                        price = fair_price > 0 and fair_price or daily_sell,
                                        source = "engine"
                                    }
                                    new_prices[clean_key] = entry
                                    if item_id > 0 then
                                        if qt >= 0 then
                                            new_prices_by_id[tostring(item_id) .. "_q" .. tostring(qt)] = entry
                                        else
                                            new_prices_by_id[item_id] = entry
                                        end
                                    end
                                    fallback_count = fallback_count + 1
                                end
                            end
                            processed = processed + 1
                            if processed % 50 == 0 then wait(0) end
                        end
                        if fallback_count > 0 then
                            UI.average_prices = new_prices
                            UI.average_prices_by_id = new_prices_by_id
                            wait(0)
                            saveJsonFile(UI.PATH_PRICES, UI.average_prices)
                            wait(0)
                            saveJsonFile(UI.PATH_PRICE_META, { last_update = os.time() })
                            sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Средние цены успешно обновлены (" .. fallback_count .. ")!", -1)
                        else
                            sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Сервер вернул пустой список цен.", -1)
                        end
                    else
                        sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Нет данных о сделках на этом сервере.", -1)
                    end
                end
                State.is_downloading_prices = false
            end)
        elseif code == 401 then
            State.is_downloading_prices = false
            ApiState.key_valid = false
            ApiState.token_state = "invalid"
            ApiState.authenticated_loads_started = false
            sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ключ не подтвержден.", -1)
        else
            State.is_downloading_prices = false
            sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ошибка сети при скачивании цен (HTTP " .. tostring(code) .. ").", -1)
        end
    end)
end

local function marketShopKey(server_id, nickname)
    return tostring(server_id or "") .. "\0" .. tostring(nickname or "")
end

local function makeMarketShopObject(shop, key)
    local sell_list = safeParseMarketItems(shop.items_sell, shop.count_sell, shop.price_sell, shop.names_sell)
    local buy_list = safeParseMarketItems(shop.items_buy, shop.count_buy, shop.price_buy, shop.names_buy)
    if #sell_list == 0 and #buy_list == 0 then return nil end
    local nickname = utf8ToCp1251Fast(shop.username or shop.user or "Unknown")
    local server_id = shop.serverId or shop.server_id
    local is_vip = shop.vip or false
    if is_vip then
        if not ApiState.vip_users_cache[nickname] then ApiState.vip_users_cache[nickname] = 1 end
        if not ApiState.vip_users_cache[nickname:gsub(" ", "_")] then ApiState.vip_users_cache[nickname:gsub(" ", "_")] = 1 end
    end
    return {
        _market_key = key or marketShopKey(server_id, nickname),
        nickname = nickname,
        serverId = server_id,
        vip = is_vip,
        is_passive = shop.is_passive or false,
        sell_count = #sell_list,
        buy_count = #buy_list,
        sell_list = sell_list,
        buy_list = buy_list,
        playerId = shop.playerId
    }
end

local function isArbitrageBlacklisted(item_name)
    local clean = cleanItemName(stripItemMetadata(item_name or ""))
    for _, b_name in ipairs(StateArbitrage.blacklist) do
        if b_name == clean then return true end
    end
    return false
end

function api_FetchArbitrage(silent)
    if not isTokenVerified() or not isVerifiedVip() then
        StateArbitrage.list = {}
        StateArbitrage.is_loading = false
        return
    end
    if StateArbitrage.is_loading then return end
    local ip, port = sampGetCurrentServerAddress()
    local srv_id = normalizeServerId(ip .. ":" .. port)
    if srv_id == "Unknown" then
        warnUnknownServer()
        return
    end
    StateArbitrage.is_loading = true
    StateArbitrage.last_error = nil
    local sort_keys = { "profit", "roi", "qty" }
    local sort_param = sort_keys[StateArbitrage.sort_mode] or "profit"
    local tax_param = tonumber(StateArbitrage.tax_pct) or 8
    local url = "/vip_analytics?action=arbitrage&server=" .. url_encode(srv_id) .. "&tax=" .. tostring(tax_param) .. "&sort=" .. sort_param
    signedRequest("GET", url, nil, function(status, body)
        if status == 200 and body ~= "" then
            lua_thread.create(function()
                local ok_dec, raw = pcall(Dependencies.cjson.decode, body)
                wait(0)
                if ok_dec and type(raw) == "table" then
                    if raw.error == "vip_required" then
                        ApiState.is_vip = false
                        ApiState.server_vip_verified = false
                        StateArbitrage.list = {}
                        StateArbitrage.is_loading = false
                        return
                    end
                    local out = {}
                    local slice_start = os.clock()
                    for idx, row in ipairs(raw) do
                        if State.is_terminating then
                            StateArbitrage.is_loading = false
                            return
                        end
                        if type(row) == "table" then
                            out[#out + 1] = {
                                name = utf8ToCp1251Fast(tostring(row.name or "")),
                                model_id = tonumber(row.model_id) or 0,
                                seller_nick = utf8ToCp1251Fast(tostring(row.seller_nick or "Unknown")),
                                buyer_nick = utf8ToCp1251Fast(tostring(row.buyer_nick or "Unknown")),
                                server_id = tostring(row.server_id or srv_id),
                                buy_from_price = tonumber(row.buy_from_price) or 0,
                                sell_to_price = tonumber(row.sell_to_price) or 0,
                                net_received = tonumber(row.net_received) or 0,
                                tax_pct = tonumber(row.tax_pct) or tax_param,
                                profit_one = tonumber(row.profit_one) or 0,
                                max_qty = tonumber(row.max_qty) or 1,
                                total_profit = tonumber(row.total_profit) or 0,
                                roi = tonumber(row.roi) or 0
                            }
                        end
                        if idx % 25 == 0 or (os.clock() - slice_start) >= 0.002 then
                            wait(0)
                            slice_start = os.clock()
                        end
                    end
                    StateArbitrage.list = out
                    StateArbitrage.last_fetch = os.time()
                    StateArbitrage.is_loading = false
                    if not silent then
                        sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Арбитраж обновлен (" .. #out .. " связок)!", -1)
                    end
                    return
                end
                StateArbitrage.is_loading = false
                StateArbitrage.last_error = "decode_error"
            end)
        elseif status == 403 then
            ApiState.is_vip = false
            ApiState.server_vip_verified = false
            StateArbitrage.list = {}
            StateArbitrage.is_loading = false
            if not silent then
                sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Арбитраж доступен только для VIP!", -1)
            end
        elseif status == 401 then
            ApiState.key_valid = false
            ApiState.token_state = "invalid"
            ApiState.authenticated_loads_started = false
            StateArbitrage.is_loading = false
        else
            StateArbitrage.is_loading = false
            StateArbitrage.last_error = "http_" .. tostring(status)
            if not silent then
                sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ошибка загрузки арбитража (HTTP " .. tostring(status) .. ").", -1)
            end
        end
    end)
end

function api_FetchMarketList(silent)
    if not isTokenVerified() then
        StateMarket.is_loading = false
        return
    end
    if StateMarket.is_loading then return end
    StateMarket.is_loading = true
    local ip, port = sampGetCurrentServerAddress()
    StateMarket.current_server_id = normalizeServerId(ip .. ":" .. port)
    StateMarket.request_id = (StateMarket.request_id or 0) + 1
    local request_id = StateMarket.request_id
    StateMarket.request_started_at = os.time()
    StateMarket.loading_started_at = os.clock()
    StateMarket.loading_stage = "handshake"
    StateMarket.loading_response_bytes = 0
    StateMarket.request_silent = silent == true
    StateMarket.next_auto_refresh_at = os.time() + 60

    local handshake_nonce = string.format("m%d-%d-%d", os.time(), math.floor(os.clock() * 1000), request_id)
    local request_cursor = 0
    local snapshot_id, snapshot_time = 0, 0
    local base_snapshot_id = tonumber(StateMarket.loaded_snapshot_id) or 0
    local base_snapshot_time = tonumber(StateMarket.loaded_snapshot_time) or 0
    local base_snapshot_epoch = StateMarket.loaded_snapshot_epoch or ""
    local target_snapshot_epoch = ""
    local transfer_mode = "full"
    local received_shops = {}
    local received_changes = {}
    local page_retry = 0

    local function failMarketTransfer(error_text)
        if request_id ~= StateMarket.request_id then return end
        StateMarket.request_started_at = 0
        StateMarket.last_error = true
        StateMarket.loading_stage = "error"
        StateMarket.refresh_failures = StateMarket.refresh_failures + 1
        StateMarket.next_auto_refresh_at = os.time() + math.min(60 * (2 ^ math.min(StateMarket.refresh_failures - 1, 4)), 600)
        StateMarket.is_loading = false
        if not silent then
            sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ошибка загрузки маркета: " .. tostring(error_text), -1)
        end
    end

    local sendHandshake
    local requestMarketPage

    requestMarketPage = function()
        if request_id ~= StateMarket.request_id then return end
        local expected_cursor = request_cursor
        StateMarket.request_started_at = os.time()
        StateMarket.loading_stage = "request"
        local page_url = "/marketplace?action=list&batch=1&limit=1000&format=compact"
            .. "&request_id=" .. tostring(request_id)
            .. "&protocol=2"
            .. "&cursor=" .. tostring(expected_cursor)
            .. "&snapshot_id=" .. tostring(snapshot_id)
            .. "&snapshot_time=" .. tostring(snapshot_time)
            .. (transfer_mode == "delta" and ("&delta=1&base_snapshot_id=" .. tostring(base_snapshot_id)) or "")
            .. "&t=" .. tostring(os.time())

        signedRequest("GET", page_url, nil, function(status, response_text)
            if request_id ~= StateMarket.request_id or expected_cursor ~= request_cursor then return end
            StateMarket.request_started_at = 0
            response_text = type(response_text) == "string" and response_text or ""
            StateMarket.loading_response_bytes = StateMarket.loading_response_bytes + #response_text
            StateMarket.loading_stage = "processing"

            if status == 403 or status == 409 then
                base_snapshot_id = 0
                base_snapshot_time = 0
                base_snapshot_epoch = ""
                received_changes = {}
                received_shops = {}
                request_cursor = 0
                snapshot_id, snapshot_time = 0, 0
                transfer_mode = "full"
                page_retry = 0
                sendHandshake(0)
                return
            end

            if status == 401 then
                ApiState.key_valid = false
                ApiState.token_state = "invalid"
                ApiState.authenticated_loads_started = false
                failMarketTransfer("HTTP 401")
                return
            end

            if status >= 500 or status == 0 then
                if page_retry < 2 then
                    page_retry = page_retry + 1
                    Tasks.add("market_page_retry", function()
                        if request_id == StateMarket.request_id then requestMarketPage() end
                    end, 500 * page_retry)
                    return
                end
                failMarketTransfer("HTTP " .. tostring(status))
                return
            end

            if status == 200 then
                lua_thread.create(function()
                    if request_id ~= StateMarket.request_id then return end
                    local ok_p, page = pcall(Dependencies.cjson.decode, response_text)
                    wait(0)
                    if request_id ~= StateMarket.request_id then return end
                    local page_rows = ok_p and type(page) == "table" and (transfer_mode == "delta" and page.changes or page.shops) or nil
                    if ok_p and type(page) == "table"
                        and page.type == "market_page_ack"
                        and tonumber(page.protocol) == 2
                        and tostring(page.request_id) == tostring(request_id)
                        and tonumber(page.cursor) == expected_cursor
                        and page.mode == transfer_mode
                        and type(page_rows) == "table" then
                        for idx, row in ipairs(page_rows) do
                            if transfer_mode == "delta" then
                                if type(row) ~= "table" or type(row[2]) ~= "string" then
                                    failMarketTransfer("invalid_delta_row")
                                    return
                                end
                                local key_cp = utf8ToCp1251Fast(row[2])
                                if row[1] == "delete" then
                                    received_changes[#received_changes + 1] = { op = "delete", key = key_cp }
                                elseif row[1] == "upsert" and type(row[3]) == "table" then
                                    local compact = row[3]
                                    received_changes[#received_changes + 1] = {
                                        op = "upsert",
                                        key = key_cp,
                                        shop = {
                                            username = compact[1], serverId = compact[2], vip = compact[3],
                                            is_passive = compact[4], items_sell = compact[5], count_sell = compact[6],
                                            price_sell = compact[7], items_buy = compact[8], count_buy = compact[9],
                                            price_buy = compact[10], playerId = compact[11],
                                            names_sell = compact[12], names_buy = compact[13]
                                        }
                                    }
                                else
                                    failMarketTransfer("unknown_delta_op")
                                    return
                                end
                            else
                                local shop = row
                                if type(row) == "table" and row[1] ~= nil then
                                    shop = {
                                        username = row[1], serverId = row[2], vip = row[3], is_passive = row[4],
                                        items_sell = row[5], count_sell = row[6], price_sell = row[7],
                                        items_buy = row[8], count_buy = row[9], price_buy = row[10], playerId = row[11],
                                        names_sell = row[12], names_buy = row[13]
                                    }
                                end
                                if type(shop) ~= "table" or type(shop.username) ~= "string" then
                                    failMarketTransfer("invalid_shop_row")
                                    return
                                end
                                received_shops[#received_shops + 1] = shop
                            end
                            if idx % 25 == 0 then wait(0) end
                        end
                        if page.has_more == true then
                            local next_cursor = tonumber(page.next_cursor)
                            if not next_cursor or next_cursor <= expected_cursor then
                                failMarketTransfer("invalid_next_cursor")
                                return
                            end
                            request_cursor = next_cursor
                            page_retry = 0
                            requestMarketPage()
                            return
                        end
                        StateMarket.loading_stage = "applying"
                        local new_shops = {}
                        local slice_start = os.clock()
                        if transfer_mode == "delta" then
                            local shops_by_key = {}
                            for _, shop in ipairs(StateMarket.shops_list or {}) do
                                local key = shop._market_key or marketShopKey(shop.serverId, shop.nickname)
                                shop._market_key = key
                                shops_by_key[key] = shop
                            end
                            for idx, change in ipairs(received_changes) do
                                if request_id ~= StateMarket.request_id then return end
                                if change.op == "delete" then
                                    shops_by_key[change.key] = nil
                                else
                                    local shop_obj = makeMarketShopObject(change.shop, change.key)
                                    if shop_obj then shops_by_key[change.key] = shop_obj end
                                end
                                if idx % 2 == 0 or (os.clock() - slice_start) >= 0.002 then
                                    wait(0)
                                    slice_start = os.clock()
                                end
                            end
                            for _, shop in ipairs(StateMarket.shops_list or {}) do
                                local key = shop._market_key or marketShopKey(shop.serverId, shop.nickname)
                                if shops_by_key[key] then
                                    table.insert(new_shops, shops_by_key[key])
                                    shops_by_key[key] = nil
                                end
                            end
                            for _, change in ipairs(received_changes) do
                                if change.op == "upsert" and shops_by_key[change.key] then
                                    table.insert(new_shops, shops_by_key[change.key])
                                    shops_by_key[change.key] = nil
                                end
                            end
                        else
                            for idx, shop in ipairs(received_shops) do
                                if request_id ~= StateMarket.request_id then return end
                                local shop_obj = makeMarketShopObject(shop)
                                if shop_obj then table.insert(new_shops, shop_obj) end
                                if idx % 2 == 0 or (os.clock() - slice_start) >= 0.002 then
                                    wait(0)
                                    slice_start = os.clock()
                                end
                            end
                        end
                        if request_id ~= StateMarket.request_id then return end
                        StateMarket.last_error = nil
                        StateMarket.refresh_failures = 0
                        StateMarket.next_auto_refresh_at = os.time() + 60
                        StateMarket.shops_list = new_shops
                        StateMarket.online_count = #new_shops
                        StateMarket.last_fetch = os.time()
                        StateMarket.loaded_snapshot_id = snapshot_id
                        StateMarket.loaded_snapshot_time = snapshot_time
                        StateMarket.loaded_snapshot_epoch = target_snapshot_epoch
                        StateMarket.is_loading = false
                        StateMarket.loading_stage = "ready"
                        StateMarket.search_cache_key = nil
                        if StateMarket.selected_shop then
                            local found = false
                            for _, s in ipairs(StateMarket.shops_list) do
                                if s.nickname == StateMarket.selected_shop.nickname and s.serverId == StateMarket.selected_shop.serverId then
                                    StateMarket.selected_shop = s
                                    found = true
                                    break
                                end
                            end
                            if not found then StateMarket.selected_shop = nil end
                        end
                        if not silent then
                            sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Список лавок обновлен (" .. #new_shops .. ")!", -1)
                        end
                        return
                    end
                    failMarketTransfer("invalid_page_ack")
                end)
            else
                failMarketTransfer("HTTP " .. tostring(status))
            end
        end)
    end

    sendHandshake = function(attempt)
        if request_id ~= StateMarket.request_id then return end
        StateMarket.request_started_at = os.time()
        StateMarket.loading_stage = "handshake"
        local handshake_url = "/marketplace?action=handshake&nonce=" .. handshake_nonce .. "&protocol=2"
        if base_snapshot_id > 0 and base_snapshot_time > 0 and base_snapshot_epoch ~= "" then
            handshake_url = handshake_url
                .. "&base_snapshot_id=" .. tostring(base_snapshot_id)
                .. "&base_snapshot_time=" .. tostring(base_snapshot_time)
                .. "&base_epoch=" .. base_snapshot_epoch
        end
        handshake_url = handshake_url .. "&t=" .. tostring(os.time())
        signedRequest("GET", handshake_url, nil, function(status, response_text)
            if request_id ~= StateMarket.request_id then return end
            StateMarket.request_started_at = 0
            local ack = apiDecodeJson(response_text or "")
            if status == 200 and type(ack) == "table"
                and ack.type == "market_handshake_ack"
                and tonumber(ack.protocol) == 2
                and ack.nonce == handshake_nonce
                and type(ack.epoch) == "string"
                and (ack.mode == "unchanged" or ack.mode == "delta" or ack.mode == "full")
                and tonumber(ack.snapshot_id) ~= nil
                and tonumber(ack.snapshot_time) ~= nil then
                snapshot_id = math.floor(tonumber(ack.snapshot_id) or 0)
                snapshot_time = math.floor(tonumber(ack.snapshot_time) or 0)
                target_snapshot_epoch = ack.epoch
                if ack.mode == "unchanged"
                    and base_snapshot_id == snapshot_id
                    and base_snapshot_time == snapshot_time
                    and base_snapshot_epoch == target_snapshot_epoch then
                    StateMarket.is_loading = false
                    StateMarket.last_error = nil
                    StateMarket.last_fetch = os.time()
                    StateMarket.loading_stage = "ready"
                    StateMarket.next_auto_refresh_at = os.time() + 60
                    StateMarket.search_cache_key = nil
                    return
                end
                transfer_mode = ack.mode == "delta" and "delta" or "full"
                request_cursor = 0
                page_retry = 0
                received_shops = {}
                received_changes = {}
                requestMarketPage()
                return
            end
            if status == 401 then
                ApiState.key_valid = false
                ApiState.token_state = "invalid"
                ApiState.authenticated_loads_started = false
                failMarketTransfer("HTTP 401")
                return
            end
            if attempt >= 2 then
                failMarketTransfer("handshake_failed_" .. tostring(status))
                return
            end
            Tasks.add("market_handshake_retry", function()
                if request_id == StateMarket.request_id then sendHandshake(attempt + 1) end
            end, 500 * (attempt + 1))
        end)
    end

    sendHandshake(0)
end

function parseMobileMarketPrice(text)
    if type(text) == "number" then return text end
    if type(text) ~= "string" then return tonumber(text) or 0 end
    local s = text:gsub("{.-}", ""):gsub("[%s\194\160]", "")
    s = s:gsub("руб%.?", ""):gsub("р%.?", "")
    local num_str, suffix = s:match("^([%d%,%.]+)(.*)")
    if not num_str then return tonumber((s:gsub("%D", ""))) or 0 end
    if suffix and suffix ~= "" then
        local num = tonumber((num_str:gsub(",", "."))) or 0
        local lower_suf = suffix:lower()
        local _, k_c = lower_suf:gsub("[kк]", "")
        local _, m_c = lower_suf:gsub("[mм]", "")
        if k_c >= 3 then return math.floor(num * 1000000000) end
        if k_c == 2 or m_c >= 1 then return math.floor(num * 1000000) end
        if k_c == 1 then return math.floor(num * 1000) end
    end
    return tonumber((num_str:gsub("[%,%.]", ""))) or 0
end

function queueMarketplaceSync(immediate)
    Marketplace.dirty = true
    if immediate then
        Marketplace.sync_queued_at = 0
        Marketplace.last_sync = 0
    else
        Marketplace.sync_queued_at = os.time() + 2
    end
end

function appendMarketplaceItems(items, ids, counts, prices, names)
    local slots = {}
    for slot in pairs(items) do slots[#slots + 1] = tonumber(slot) or slot end
    table.sort(slots, function(a, b) return a < b end)
    for _, slot in ipairs(slots) do
        local item = items[slot] or items[tostring(slot)]
        if type(item) == "table" and (tonumber(item.amount) or 0) > 0 and (tonumber(item.price) or 0) >= 10 then
            ids[#ids + 1] = tonumber(item.model_id) or 0
            counts[#counts + 1] = math.floor(tonumber(item.amount) or 0)
            prices[#prices + 1] = math.floor(tonumber(item.price) or 0)
            names[#names + 1] = formatWireItemName(item)
        end
    end
end

function buildMarketplacePayload()
    local ip, port = sampGetCurrentServerAddress()
    local srv_id = normalizeServerId(ip .. ":" .. port)
    Marketplace.username = getSafeLocalNickname()
    Marketplace.server_id = srv_id
    if Marketplace.lavka_uid == 0 then Marketplace.lavka_uid = os.time() end
    local payload = {
        username = Marketplace.username,
        enabled = true,
        serverId = Marketplace.server_id,
        token = Marketplace.session_token or "",
        playerId = -1,
        LavkaUid = Marketplace.lavka_uid,
        vip = ApiState and ApiState.is_vip or false,
        items_sell = {},
        count_sell = {},
        price_sell = {},
        names_sell = {},
        items_buy = {},
        count_buy = {},
        price_buy = {},
        names_buy = {}
    }
    local ok, player_id = pcall(function()
        local found, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
        return found and id or -1
    end)
    if ok then payload.playerId = player_id end
    appendMarketplaceItems(Marketplace.sell, payload.items_sell, payload.count_sell, payload.price_sell, payload.names_sell)
    appendMarketplaceItems(Marketplace.buy, payload.items_buy, payload.count_buy, payload.price_buy, payload.names_buy)
    return payload
end

function processMarketplaceSync(force)
    if Marketplace.sync_in_progress or Marketplace.clear_in_progress then return end
    if Marketplace.clear_pending then
        if os.time() >= Marketplace.clear_retry_at then
            local clear_payload = Marketplace.clear_pending
            Marketplace.clear_pending = nil
            sendMarketplaceClear(clear_payload)
        end
        return
    end
    if State.selling.active or State.buying.active or State.inventory_scan.active then return end
    if not Marketplace.enabled or not isTokenVerified() then return end

    local now = os.time()
    if not force and not Marketplace.dirty and (now - Marketplace.last_sync) < Marketplace.sync_interval then return end
    if not force and Marketplace.dirty and now < Marketplace.sync_queued_at then return end

    local payload = buildMarketplacePayload()
    if payload.username == "" or payload.username == "Unknown Player" or payload.serverId == "Unknown" then return end

    Marketplace.sync_in_progress = true
    Marketplace.dirty = false
    Marketplace.last_sync = now

    signedRequest("POST", "/marketplace?action=insert", payload, function(status, body)
        Marketplace.sync_in_progress = false
        if Marketplace.clear_pending then
            local clear_payload = Marketplace.clear_pending
            Marketplace.clear_pending = nil
            sendMarketplaceClear(clear_payload)
            return
        end
        if status == 200 and body ~= "" then
            local response = apiDecodeJson(body)
            if type(response) == "table" and response.token and Marketplace.session_token ~= response.token then
                Marketplace.session_token = response.token
                saveSessionToken()
            end
        elseif status == 401 or status == 403 then
            Marketplace.session_token = ""
            ApiState.key_valid = false
            ApiState.token_state = "invalid"
        else
            Marketplace.dirty = true
            Marketplace.sync_queued_at = os.time() + 15
        end
    end)
end

function processMarketplacePing()
    if not isTokenVerified() then return end
    if not Marketplace.enabled or not Marketplace.session_token or Marketplace.session_token == "" then return end
    local now = os.time()
    if now < (Marketplace.last_ping + Marketplace.ping_interval) then return end
    Marketplace.last_ping = now
    local ip, port = sampGetCurrentServerAddress()
    local srv_id = Marketplace.server_id ~= "Unknown" and Marketplace.server_id or normalizeServerId(ip .. ":" .. port)
    local uname = Marketplace.username ~= "" and Marketplace.username or getSafeLocalNickname()
    if uname == "Unknown Player" or srv_id == "Unknown" then return end
    signedRequest("POST", "/marketplace?action=ping", {
        username = uname,
        serverId = srv_id,
        token = Marketplace.session_token
    }, function(status)
        if status == 404 or status == 403 then
            Marketplace.session_token = ""
            Marketplace.last_sync = 0
            saveSessionToken()
        else
            saveLiveShopState()
        end
    end)
end

function sendMarketplaceClear(payload)
    Marketplace.clear_in_progress = true
    signedRequest("POST", "/marketplace?action=insert", payload, function(status, body)
        Marketplace.clear_in_progress = false
        local response = apiDecodeJson(body or "")
        if status ~= 200 or type(response) ~= "table" or response.status ~= "cleared" then
            Marketplace.clear_pending = payload
            Marketplace.clear_retry_at = os.time() + 15
        end
    end)
end

function clearMobileMarketplace(force)
    if not Marketplace.enabled and not force then return end
    if Marketplace.is_cleared and not force then return end
    local username = Marketplace.username ~= "" and Marketplace.username or getSafeLocalNickname()
    if not username or username == "" or username == "Unknown Player" then return end
    local server_id = Marketplace.server_id
    if server_id == "Unknown" then
        local ip, port = sampGetCurrentServerAddress()
        server_id = normalizeServerId(ip .. ":" .. port)
    end
    local payload = {
        username = username,
        serverId = server_id,
        enabled = false,
        token = Marketplace.session_token,
        items_sell = {},
        count_sell = {},
        price_sell = {},
        items_buy = {},
        count_buy = {},
        price_buy = {}
    }
    Marketplace.enabled = false
    Marketplace.is_cleared = true
    Marketplace.publish_sell = false
    Marketplace.publish_buy = false
    Marketplace.dirty = false
    Marketplace.sell = {}
    Marketplace.buy = {}
    Marketplace.sell_seen = false
    Marketplace.buy_seen = false
    Marketplace.pending_cef = {}
    Marketplace.session_token = ""
    Marketplace.lavka_uid = 0
    Marketplace.clear_retry_at = 0
    saveSessionToken()
    saveLiveShopState()
    local normalized_name = username:gsub(" ", "_"):lower()
    for index = #StateMarket.shops_list, 1, -1 do
        local shop = StateMarket.shops_list[index]
        if (shop.nickname or ""):gsub(" ", "_"):lower() == normalized_name
            and tostring(shop.serverId):lower() == tostring(server_id):lower() then
            if StateMarket.selected_shop == shop then StateMarket.selected_shop = nil end
            table.remove(StateMarket.shops_list, index)
        end
    end
    if Marketplace.sync_in_progress then
        Marketplace.clear_pending = payload
    else
        sendMarketplaceClear(payload)
    end
end

function api_SubmitPassiveShop()
    if not isTokenVerified() then return end
    if not Marketplace.current_shop_owner or Marketplace.current_shop_owner == "" then return end
    local ip, port = sampGetCurrentServerAddress()
    local server_id = normalizeServerId(ip .. ":" .. port)
    if server_id == "Unknown" then return end
    local s_ids, s_counts, s_prices, s_titles = {}, {}, {}, {}
    local b_ids, b_counts, b_prices, b_titles = {}, {}, {}, {}
    for _, item in ipairs(Marketplace.remote_shop_items) do
        if item.model_id and item.amount and item.raw_price and item.raw_price >= 10 then
            if item.shop_type == 9 then
                table.insert(s_ids, tonumber(item.model_id))
                table.insert(s_counts, tonumber(item.amount) or 1)
                table.insert(s_prices, tonumber(item.raw_price) or 0)
                table.insert(s_titles, formatWireItemName(item))
            elseif item.shop_type == 10 then
                table.insert(b_ids, tonumber(item.model_id))
                table.insert(b_counts, tonumber(item.amount) or 1)
                table.insert(b_prices, tonumber(item.raw_price) or 0)
                table.insert(b_titles, cleanItemName(item.name or ""))
            end
        end
    end
    if #s_ids == 0 and #b_ids == 0 then return end
    signedRequest("POST", "/marketplace?action=insert_passive", {
        username = Marketplace.current_shop_owner,
        enabled = true,
        serverId = server_id,
        token = "",
        playerId = tonumber(Marketplace.current_shop_id) or -1,
        LavkaUid = 0,
        vip = false,
        items_sell = s_ids,
        count_sell = s_counts,
        price_sell = s_prices,
        names_sell = s_titles,
        items_buy = b_ids,
        count_buy = b_counts,
        price_buy = b_prices,
        names_buy = b_titles
    })
end

function captureMarketplaceCEF(msgId, subId, data)
    if msgId == 6 and subId == 0 and type(data.text) == "string" then
        local txt = ensureCP1251(data.text)
        if txt:find("Вы завершили торговлю", 1, true) then
            clearMobileMarketplace(true)
            return
        end
    end
    if msgId ~= 60 then return end

    if subId == 1 and type(data.name) == "string" then
        local raw_name = cleanTextColors(ensureCP1251(data.name))
        if raw_name:find("_") and #raw_name >= 3 and #raw_name <= 24 and not raw_name:find(" ") and not raw_name:match("^%d+$") then
            Marketplace.owner_name = raw_name
            local my_nick = getSafeLocalNickname():gsub(" ", "_")
            if raw_name:lower() ~= my_nick:lower() then
                if Marketplace.current_shop_owner ~= raw_name then
                    Marketplace.current_shop_owner = raw_name
                    Marketplace.current_shop_id = -1
                    local cur_type = Marketplace.last_updated_type
                    for i = #Marketplace.remote_shop_items, 1, -1 do
                        if Marketplace.remote_shop_items[i].shop_type ~= cur_type then
                            table.remove(Marketplace.remote_shop_items, i)
                        end
                    end
                end
                Tasks.remove_by_name("submit_passive_shop")
                Tasks.add("submit_passive_shop", api_SubmitPassiveShop, 2500)
            else
                replayPendingMarketplaceCEF()
            end
        end
        return
    end

    if (subId ~= 0 and subId ~= 2) or type(data.items) ~= "table"
        or (tonumber(data.type) ~= 9 and tonumber(data.type) ~= 10) then return end

    local ip, port = sampGetCurrentServerAddress()
    local server_id = normalizeServerId(ip .. ":" .. port)
    if server_id == "Unknown" then
        warnUnknownServer()
        return
    end

    local shop_type = tonumber(data.type)
    local now = os.clock()
    local time_since_last = now - (Marketplace.last_packet_time or 0)
    local is_same_sequence = (time_since_last < 2.0) and (Marketplace.last_updated_type == shop_type)
    Marketplace.last_packet_time = now
    Marketplace.last_updated_type = shop_type

    if subId == 0 and not is_same_sequence then
        if time_since_last > 15.0 then
            Marketplace.current_shop_owner = nil
            Marketplace.remote_shop_items = {}
        else
            for i = #Marketplace.remote_shop_items, 1, -1 do
                if Marketplace.remote_shop_items[i].shop_type == shop_type then
                    table.remove(Marketplace.remote_shop_items, i)
                end
            end
        end
    end

    for _, item in ipairs(data.items) do
        local slot = tonumber(item.slot)
        if slot ~= nil then
            if tonumber(item.available) == 1 and tonumber(item.item) then
                local model_id = tonumber(item.item)
                local item_name = UI.item_names[tostring(model_id)] or ("Предмет_" .. model_id)
                local raw_price_text = item.text and ensureCP1251(tostring(item.text)) or "0"
                local real_price = parseMobileMarketPrice(raw_price_text)
                local amount = tonumber(item.amount) or tonumber(item.count) or 1
                local q_val = tonumber(item.quality)
                if not q_val or q_val <= 0 then q_val = nil end
                local e_val = tonumber(item.enchant)
                if not e_val or e_val <= 0 then e_val = nil end
                local new_entry = {
                    name = item_name,
                    model_id = model_id,
                    slot = slot,
                    amount = amount,
                    raw_price = real_price,
                    shop_type = shop_type,
                    quality = q_val,
                    enchant = e_val
                }
                local found_idx = nil
                for i, existing in ipairs(Marketplace.remote_shop_items) do
                    if existing.slot == slot and existing.shop_type == shop_type then
                        found_idx = i
                        break
                    end
                end
                if found_idx then
                    Marketplace.remote_shop_items[found_idx] = new_entry
                else
                    table.insert(Marketplace.remote_shop_items, new_entry)
                end
            elseif tonumber(item.available) == 0 then
                for i = #Marketplace.remote_shop_items, 1, -1 do
                    if Marketplace.remote_shop_items[i].slot == slot and Marketplace.remote_shop_items[i].shop_type == shop_type then
                        table.remove(Marketplace.remote_shop_items, i)
                        break
                    end
                end
            end
        end
    end

    local local_name = getSafeLocalNickname():gsub(" ", "_")
    if local_name == "Unknown_Player" or not Marketplace.owner_name then
        if #Marketplace.pending_cef < 16 then
            Marketplace.pending_cef[#Marketplace.pending_cef + 1] = { sub_id = subId, data = data }
        end
        return
    end
    local owner = Marketplace.owner_name:gsub(" ", "_"):lower()
    if owner ~= local_name:lower() then
        Marketplace.pending_cef = {}
        return
    end

    local is_sell = (shop_type == 9)
    if subId == 0 and not is_same_sequence then
        if is_sell then Marketplace.sell = {} else Marketplace.buy = {} end
    end
    local target = is_sell and Marketplace.sell or Marketplace.buy
    local has_active_items = false
    for _, item in ipairs(data.items) do
        local slot = tonumber(item.slot)
        if slot ~= nil then
            if tonumber(item.available) == 1 and tonumber(item.item) then
                has_active_items = true
                local model_id = tonumber(item.item)
                local name = UI.item_names[tostring(model_id)] or ("Предмет_" .. model_id)
                local q_val = tonumber(item.quality)
                if not q_val or q_val <= 0 then q_val = nil end
                local e_val = tonumber(item.enchant)
                if not e_val or e_val <= 0 then e_val = nil end
                target[slot] = {
                    model_id = model_id,
                    name = name,
                    amount = tonumber(item.amount) or tonumber(item.count) or 1,
                    price = parseMobileMarketPrice(item.text and ensureCP1251(tostring(item.text)) or "0"),
                    quality = q_val,
                    enchant = e_val
                }
            elseif tonumber(item.available) == 0 then
                target[slot] = nil
            end
        end
    end

    if has_active_items then
        Marketplace.enabled = true
        Marketplace.is_cleared = false
        if is_sell then Marketplace.publish_sell = true else Marketplace.publish_buy = true end
    end
    if not Marketplace.enabled then return end

    Marketplace.username = getSafeLocalNickname()
    Marketplace.server_id = server_id
    if Marketplace.lavka_uid == 0 then Marketplace.lavka_uid = os.time() end
    if is_sell then Marketplace.sell_seen = true else Marketplace.buy_seen = true end
    saveLiveShopState()
    queueMarketplaceSync()
end

function replayPendingMarketplaceCEF()
    local local_name = getSafeLocalNickname():gsub(" ", "_")
    if local_name == "Unknown_Player" or not Marketplace.owner_name then return end
    if Marketplace.owner_name:gsub(" ", "_"):lower() ~= local_name:lower() then
        Marketplace.pending_cef = {}
        return
    end
    local pending = Marketplace.pending_cef
    Marketplace.pending_cef = {}
    for _, packet in ipairs(pending) do
        captureMarketplaceCEF(60, packet.sub_id, packet.data)
    end
end

function trimText(text)
    return text:match("^%s*(.-)%s*$")
end

function parseStatsDialog(text)
    local data = { level = 0, vip = "Нет", cash = 0, bank = 0, deposit = 0, job = "Нет", org = "Нет", fam = "Нет" }
    for line in text:gmatch("[^\r\n]+") do
        local clean_line = line:gsub("{%x+}", ""):gsub("%[[%x]+%]", ""):gsub("\t", " "):gsub("\194\160", " "):gsub("%s+", " ")
        clean_line = trimText(clean_line)
        if clean_line:find("Наличные деньги:") then
            local num_str = clean_line:match("Наличные деньги:%s*([%d%.]+)")
            if num_str then data.cash = tonumber((num_str:gsub("%.", ""))) or 0 end
        elseif clean_line:find("Деньги в банке:") then
            local num_str = clean_line:match("Деньги в банке:%s*([%d%.]+)")
            if num_str then data.bank = tonumber((num_str:gsub("%.", ""))) or 0 end
        elseif clean_line:find("Деньги на депозите:") then
            local num_str = clean_line:match("Деньги на депозите:%s*([%d%.]+)")
            if num_str then data.deposit = tonumber((num_str:gsub("%.", ""))) or 0 end
        elseif clean_line:find("Уровень:") then
            local lvl = clean_line:match("Уровень:%s*(%d+)")
            if lvl then data.level = tonumber(lvl) end
        elseif clean_line:find("VIP статус:") then
            local vip = clean_line:match("VIP статус:%s*(.+)")
            if vip then data.vip = trimText(vip) end
        elseif clean_line:find("Работа:") and not clean_line:find("Опыт") then
            local job_val = clean_line:match("Работа:%s*(.*)")
            if job_val then data.job = trimText(job_val:gsub(" Организация:.*", "")) end
        elseif clean_line:find("Организация:") then
            local org_val = clean_line:match("Организация:%s*(.*)")
            if org_val then data.org = trimText(org_val:gsub(" Должность:.*", "")) end
        elseif clean_line:find("Семья:") and not clean_line:find("В семье с") then
            local fam_val = clean_line:match("Семья:%s*(.*)")
            if fam_val then data.fam = trimText(fam_val:gsub("%s*%[ID:.-%]", ""):gsub(" Ранг.*", "")) end
        elseif clean_line:find("Имя %(рус%.%):") then
            local rus = clean_line:match("Имя %(рус%.%):%s*(.*)")
            if rus then
                UI.player_nickname_rus = trimText(rus):gsub("_", " ")
                data.nickname_rus = UI.player_nickname_rus
            end
        end
    end
    return data
end

function sendStatsToAPI(statsData)
    if not isTokenVerified() then return end
    local ok, my_id = pcall(function()
        local found, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
        return found and id or -1
    end)
    if not ok or not my_id or my_id < 0 then return end
    local real_nick = sampGetPlayerNickname(my_id)
    if not real_nick or real_nick == "" then return end
    real_nick = real_nick:gsub("_", " ")
    local dialog_acc = tonumber(statsData.account_id) or 0
    if dialog_acc > 0 and (tonumber(UI.account_id) or 0) > 0 and dialog_acc ~= UI.account_id then return end
    local dialog_nick = statsData.nickname and tostring(statsData.nickname):gsub("_", " ") or ""
    if dialog_nick ~= "" and dialog_nick:lower() ~= real_nick:lower() then return end
    statsData.nickname = real_nick
    if dialog_acc <= 0 then statsData.account_id = tonumber(UI.account_id) or 0 end
    if not statsData.job or statsData.job == "" then statsData.job = "Нет" end
    if not statsData.org or statsData.org == "" then statsData.org = "Нет" end
    if not statsData.fam or statsData.fam == "" then statsData.fam = "Нет" end
    statsData.job = tostring(statsData.job)
    statsData.org = tostring(statsData.org)
    statsData.fam = tostring(statsData.fam)
    if statsData.nickname_rus then statsData.nickname_rus = tostring(statsData.nickname_rus) end
    signedRequest("POST", "/receive_stats", {
        secret_key = Settings.api_key,
        data = statsData
    })
end

function api_SyncInventory()
    if not isTokenVerified() then return end
    local account_name = getSafeLocalNickname()
    if account_name == "Unknown Player" then return end
    local inv_payload = {}
    for _, item in ipairs(UI.inv_items) do
        table.insert(inv_payload, {
            name = tostring(item.name or "Unknown"),
            model_id = tonumber(item.model_id) or 0,
            amount = tonumber(item.amount) or 1,
            slot = tonumber(item.slot) or -1,
            is_blocked = false
        })
    end
    signedRequest("POST", "/sync_inventory", {
        secret_key = Settings.api_key,
        inventory = inv_payload,
        account = tostring(account_name)
    })
end

function finishInventoryScan()
    State.inventory_scan.active = false
    table.sort(UI.inv_items, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
    saveJsonFile(UI.PATH_INV, UI.inv_items)
    ui_cache_sell.query = nil
    ui_cache_sell.index = nil
    api_SyncInventory()
    sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Инвентарь считан: " .. #UI.inv_items .. " слотов.", -1)
    UI.win_state[0] = true
end

function startInventoryScan()
    if State.inventory_scan.active then return end
    if isItemDbEmpty() then
        State.show_db_modal = true
        State.pending_scan_after_db = true
        return
    end
    UI.inv_items = {}
    State.inventory_scan.active = true
    State.inventory_scan.stage = "waiting_user"
    sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Открываю инвентарь для сканирования...", -1)
    sampSendChat("/invent")
end

function api_CheckAndDownloadItemsDB(force)
    if force and not isTokenVerified() then
        sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Для загрузки базы привяжите ключ в настройках.", -1)
        return
    end
    if State.is_downloading_db then return end
    State.is_downloading_db = true
    if force then
        sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Скачивание базы предметов...", -1)
    end
    local url = "/data/Rodina/items_db.json?t=" .. os.time()
    HttpManager.request(
        "GET",
        url,
        { timeout = 20 },
        function(res)
            State.is_downloading_db = false
            local code = tonumber(res.status_code) or 0
            local body = type(res.text) == "string" and res.text or ""
            if code == 200 and #body > 100 then
                if not doesDirectoryExist(UI.ROOT_DIR) then pcall(function() Dependencies.lfs.mkdir(UI.ROOT_DIR) end) end
                if not doesDirectoryExist(UI.ROOT_DIR .. 'data') then pcall(function() Dependencies.lfs.mkdir(UI.ROOT_DIR .. 'data') end) end
                local f = io.open(UI.PATH_NAMES, "w")
                if f then
                    f:write(body)
                    f:close()
                    loadItemNamesFromFile(function()
                        sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}База предметов обновлена: " .. countTable(UI.item_names) .. " шт.", -1)
                        if State.pending_scan_after_db then
                            State.pending_scan_after_db = false
                            State.show_db_modal = false
                            startInventoryScan()
                        end
                    end)
                end
            elseif force then
                sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ошибка скачивания базы (HTTP " .. tostring(code) .. ")", -1)
            end
        end,
        function()
            State.is_downloading_db = false
            if force then
                sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Ошибка сети при скачивании базы.", -1)
            end
        end,
        false
    )
end

function triggerCloudSync()
    CloudSync.needs_push = true
    CloudSync.status = "syncing"
end

function api_SyncConfigsToMiniApp()
    if not isTokenVerified() or CloudSync.is_syncing then return end
    local account_name = getSafeLocalNickname()
    if account_name == "Unknown Player" then return end
    CloudSync.is_syncing = true
    CloudSync.status = "syncing"
    local payload = {
        secret_key = Settings.api_key,
        account = tostring(account_name),
        configs = {
            sell = { { name = "Основная", items = UI.config_sell or {} } },
            buy = { { name = "Основная", items = UI.config_buy or {} } }
        }
    }
    signedRequest("POST", "/action?type=upload_configs", payload, function(status)
        CloudSync.is_syncing = false
        CloudSync.status = (status == 200) and "synced" or "error"
    end)
end

function api_PullConfigsFromCloud(token)
    token = tostring(token or Settings.api_key or ""):match("^%s*(.-)%s*$") or ""
    if #token < 16 or not isTokenVerified() then return end
    signedRequest("POST", "/action?type=download_configs", { secret_key = token }, function(status, body)
        if status == 200 and body ~= "" then
            local res = apiDecodeJson(body)
            if type(res) == "table" and res.status == "success" and type(res.configs) == "table" then
                local cloud_configs = res.configs
                local has_changes = false
                if type(cloud_configs.sell) == "table" and #cloud_configs.sell > 0 and type(cloud_configs.sell[1]) == "table" and type(cloud_configs.sell[1].items) == "table" then
                    UI.config_sell = cloud_configs.sell[1].items
                    saveJsonFile(UI.PATH_CFG_SELL, UI.config_sell)
                    ui_cache_sell.query = nil
                    ui_cache_sell.index = nil
                    has_changes = true
                end
                if type(cloud_configs.buy) == "table" and #cloud_configs.buy > 0 and type(cloud_configs.buy[1]) == "table" and type(cloud_configs.buy[1].items) == "table" then
                    UI.config_buy = cloud_configs.buy[1].items
                    saveJsonFile(UI.PATH_CFG_BUY, UI.config_buy)
                    ui_cache_buy.query = nil
                    ui_cache_buy.index = nil
                    has_changes = true
                end
                if not has_changes then
                    triggerCloudSync()
                else
                    CloudSync.status = "synced"
                end
            end
        end
    end)
end

function api_SubmitCarSale(car_name, price)
    if not isTokenVerified() then return end
    local ip, port = sampGetCurrentServerAddress()
    local server_id = normalizeServerId(ip .. ":" .. port)
    if server_id == "Unknown" then return end
    signedRequest("POST", "/cars/submit", {
        server = server_id,
        car_name = tostring(car_name or ""),
        price = tonumber(price) or 0
    })
end

function checkRemoteActions()
    if not isTokenVerified() then return end
    if State.inventory_scan.active or State.selling.active or State.buying.active then return end
    if UI.is_checking_remote then return end
    UI.is_checking_remote = true

    signedRequest("GET", "/action?type=check", nil, function(code, body)
        UI.is_checking_remote = false
        if code == 200 and body ~= "" then
            local d = apiDecodeJson(body)
            if type(d) == "table" and d.command and d.command ~= "none" then
                if d.command == 'stats' then
                    State.silent_stats = true
                    sampSendChat("/stats")
                elseif d.command == 'scan_inventory' then
                    if os.clock() - (State.last_inventory_scan_time or 0) > 10 then
                        State.last_inventory_scan_time = os.clock()
                        startInventoryScan()
                    end
                elseif d.command == 'phone_msg' and type(d.payload) == "table" and d.payload.text then
                    sampSendChat(tostring(d.payload.text))
                elseif d.command == 'start_sell' and type(d.payload) == "table" then
                    UI.config_sell = {}
                    for _, item in ipairs(d.payload) do
                        local dec_name = tostring(item.name or "")
                        local m_id = tonumber(item.model_id) or -1
                        if m_id == -1 then
                            m_id = findRealIndexByName(dec_name) or -1
                        end
                        table.insert(UI.config_sell, {
                            name = dec_name,
                            model_id = m_id,
                            price = tonumber(item.price) or 1000,
                            amount = tonumber(item.amount) or 1,
                            auto_max = false
                        })
                    end
                    saveJsonFile(UI.PATH_CFG_SELL, UI.config_sell)
                    State.selling = { active = true, stage = 'waiting_dialog', current_idx = 1, total = #UI.config_sell, current_item = nil, available_items = {}, last_packet_time = 0 }
                    sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Команда MiniApp: Продажа! Открываю лавку (стойте рядом с ней)...", -1)
                    UI.force_alt_sync_frames = 20
                elseif d.command == 'start_buy' and type(d.payload) == "table" then
                    UI.config_buy = {}
                    for _, item in ipairs(d.payload) do
                        local dec_name = tostring(item.name or "")
                        local item_idx = tonumber(item.model_id)
                        if not item_idx or item_idx <= 0 then
                            item_idx = findRealIndexByName(dec_name) or -1
                        end
                        table.insert(UI.config_buy, {
                            name = dec_name,
                            index = item_idx,
                            model_id = item_idx,
                            price = tonumber(item.price) or 100,
                            amount = tonumber(item.amount) or 1
                        })
                    end
                    saveJsonFile(UI.PATH_CFG_BUY, UI.config_buy)
                    State.buying = { active = true, stage = 'waiting_dialog', current_idx = 1, total = #UI.config_buy, current_item = nil }
                    sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Команда MiniApp: Скупка! Открываю лавку (стойте рядом с ней)...", -1)
                    UI.force_alt_sync_frames = 20
                end
            end
        elseif code == 401 then
            ApiState.key_valid = false
            ApiState.token_state = "invalid"
            ApiState.authenticated_loads_started = false
        end
    end)
end

function sendMobileCEFClick(slot, model_id, amount)
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

function processSellingCoroutine()
    sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Активных слотов в лавке: " .. #State.selling.available_items .. ". Ищем совпадения...", -1)
    wait(1000) 
    
    local sell_queue = {}
    local used_slots = {}
    
    for i, config_item in ipairs(UI.config_sell) do
        local target_model_id = tonumber(config_item.model_id)
        if not target_model_id then
            for _, inv_item in ipairs(UI.inv_items) do
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

function Dependencies.events.onShowDialog(id, style, title, b1, b2, text)
    local clean_title = cleanTextColors(title)
    local clean_text = cleanTextColors(text)

    if (id == 1295 or id == 1296) and State.auto_pr.pending_vr_response then
        sampSendDialogResponse(id, 1, -1, "")
        if id == 1295 then State.auto_pr.pending_vr_response = false end
        return false
    end

    if clean_title:find("Статистика игрока") or clean_text:find("Текущее состояние счета") then
        local found_nick = nil
        local found_acc_id = 0
        for line in clean_text:gmatch("[^\r\n]+") do
            if line:find("Имя %(en%.%):") then
                local nick_match = line:match("Имя %(en%.%):%s*([%w_]+)")
                if nick_match then found_nick = nick_match end
            end
            if line:find("Номер аккаунта:") then
                local id_match = line:match("Номер аккаунта:%s*(%d+)")
                if id_match then found_acc_id = tonumber(id_match) end
            end
        end

        local settings_changed = false
        if found_nick and UI.player_nickname ~= found_nick then
            UI.player_nickname = found_nick
            Settings.last_nickname = found_nick
            settings_changed = true
            replayPendingMarketplaceCEF()
        end
        if found_acc_id > 0 and UI.account_id ~= found_acc_id then
            UI.account_id = found_acc_id
            Settings.last_account_id = found_acc_id
            settings_changed = true
        end

        local stats = parseStatsDialog(text)
        if UI.player_nickname_rus ~= "" and Settings.last_nickname_rus ~= UI.player_nickname_rus then
            Settings.last_nickname_rus = UI.player_nickname_rus
            settings_changed = true
        end
        if settings_changed then
            saveJsonFile(UI.PATH_SETTINGS, Settings)
        end

        if stats and stats.level and stats.level > 0 then
            if found_acc_id > 0 then stats.account_id = found_acc_id end
            sendStatsToAPI(stats)
        end

        if State.pending_test_tg then
            local pending = State.pending_test_tg
            State.pending_test_tg = nil
            Tasks.remove_by_name("tg_stats_wait")
            executeTestTgRequest(pending.token, pending.callback, pending.options, 1)
        elseif found_acc_id > 0 and isTokenPresent() and not ApiState.key_valid then
            checkVipStatus(Settings.api_key, 0)
        end

        if State.stats_requested then
            State.stats_requested = false
            if isTokenPresent() then checkVipStatus(Settings.api_key, 0) end
            return false
        end
        if State.silent_stats then
            State.silent_stats = false
            if State.pending_nickname_bind_check then
                State.pending_nickname_bind_check = false
                if UI.player_nickname ~= "" and isTokenPresent() then
                    checkVipStatus(Settings.api_key, 0)
                end
            end
            return false
        end
    end

    if id == 8 and (title:find("Название лавки") or title:find("Название")) then
        if Settings.auto_name and Settings.shop_name ~= "" then
            lua_thread.create(function()
                wait(200)
                sampSendDialogResponse(id, 1, 0, Dependencies.u8:decode(Settings.shop_name))
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

    if State.buying.active then
        if State.buying.stage == 'waiting_dialog' and (title:find("Управление лавкой") or title:find("Лавка") or id == 9) then
            State.buying.current_item = UI.config_buy[State.buying.current_idx]
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
                if not State.buying.active then return end
                State.buying.stage = 'waiting_search_input'
                sampSendDialogResponse(id, 1, 0, "")
            end)
            return false
        end

        if (State.buying.stage == 'waiting_search_input' or State.buying.stage == 'processing_delay') and (id == 909 or id == 800 or text:find("название") or text:find("индекс")) then
            State.buying.stage = 'waiting_amount_price'
            local item_id = State.buying.current_item.model_id or State.buying.current_item.index
            if not item_id then
                for _, db_item in ipairs(UI.db_items) do
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
                State.buying.current_item = UI.config_buy[State.buying.current_idx]
                State.buying.stage = 'waiting_search_menu'
            end
            return false
        end

        if State.buying.stage == 'closing' then
            sampSendDialogResponse(id, 0, 0, "")
            if title:find("Управление лавкой") or title:find("Лавка") or id == 9 then
                State.buying.active = false
                UI.win_state[0] = true
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
                UI.win_state[0] = true
            end
            return false
        end
    end
end

function onSendPlayerSync(data)
    if UI.force_alt_sync_frames > 0 then
        data.keysData = Dependencies.bit.bor(data.keysData, 1024)
        UI.force_alt_sync_frames = UI.force_alt_sync_frames - 1
    end
end

Dependencies.events.onSendPlayerSync = onSendPlayerSync

function Dependencies.events.onServerMessage(color, text)
    local clean = cleanTextColors(text)
    local is_chat_message = clean:find("говорит:", 1, true) or clean:find("кричит:", 1, true) or clean:find("шепчет:", 1, true) or clean:find("%[%d+%]%s*:")

    if not is_chat_message then
        if clean:find("^Server closed the connection%.") or clean:find("^Сервер закрыл соединение%.") then
            sendDisconnectNotification("Кик / Сервер закрыл соединение")
        elseif clean:find("^You are banned from this server%.") then
            sendDisconnectNotification("IP или Аккаунт заблокирован сервером")
        elseif clean:find("^Вы были кикнуты") or clean:find("^You were kicked") then
            sendDisconnectNotification("Вас кикнул Администратор")
        end

        local admin_name, kick_reason = clean:match("^%[Информация%] Администратор (.-) %[%d+%] закончил торговлю Вашей лавки, причина: (.+)")
        if admin_name and kick_reason then
            clearMobileMarketplace(true)
            if isTokenVerified() then
                local ip, port = sampGetCurrentServerAddress()
                local server_name = getServerDisplayName(normalizeServerId(ip .. ":" .. port))
                signedRequest("POST", "/notify", {
                    secret_key = Settings.api_key,
                    data = {
                        type = "admin_closed_shop",
                        admin = admin_name,
                        reason = kick_reason,
                        account = getSafeLocalNickname(),
                        server = server_name
                    }
                })
            end
        end

        if clean:find("^[_=]+.*Банковский чек") or clean:find("^[_=]+.*PAYDAY") then
            State.payday.active = true
            State.payday.timer = os.clock()
            State.payday.data = { dep = 0, dep_cur = 0, bank = 0, bank_cur = 0, exp = 0, exp_cur = 0, exp_max = 0, az = 0, az_cur = 0, lvl = 0, shard = nil }
            Tasks.add("payday_fallback", sendPayDayData, 1500)
        elseif State.payday.active then
            if os.clock() - State.payday.timer > 8.0 then
                sendPayDayData()
            elseif clean:find("Депозит в банке:") then
                local current = clean:match("Депозит в банке:%s*([%d%.,%s]+)")
                local plus = clean:match("%+%s*([%d%.,%s]+)")
                if current then State.payday.data.dep_cur = current:gsub("[%.,%s]", "") end
                if plus then State.payday.data.dep = plus:gsub("[%.,%s]", "") end
            elseif clean:find("На банковском счету:") then
                local current = clean:match("На банковском счету:%s*([%d%.,%s]+)")
                local plus = clean:match("%+%s*([%d%.,%s]+)")
                if current then State.payday.data.bank_cur = current:gsub("[%.,%s]", "") end
                if plus then State.payday.data.bank = plus:gsub("[%.,%s]", "") end
            elseif clean:find("Ваш игровой уровень:") then
                local lvl, exp_c, exp_m = clean:match("уровень:%s*(%d+).-опыта:%s*(%d+)%s*/%s*(%d+)")
                local plus = clean:match("опыта.-%+%s*([%d%.,%s]+)")
                if lvl then State.payday.data.lvl = lvl end
                if exp_c then State.payday.data.exp_cur = exp_c end
                if exp_m then State.payday.data.exp_max = exp_m end
                if plus then State.payday.data.exp = plus:gsub("[%.,%s]", "") end
            elseif clean:find("Всего донат%-очков:") then
                local current = clean:match("донат%-очков:%s*([%d%.,%s]+)")
                local plus = clean:match("%+%s*([%d%.,%s]+)")
                if current then State.payday.data.az_cur = current:gsub("[%.,%s]", "") end
                if plus then State.payday.data.az = plus:gsub("[%.,%s]", "") end
            elseif clean:find("%[Бонус%] Вы получили Осколок") then
                local shard_name = clean:match("%[Бонус%] Вы получили (Осколок [^%.]+)")
                if shard_name then State.payday.data.shard = shard_name end
            elseif clean:find("^%s*[_=]+%s*$") then
                sendPayDayData()
            end
        end

        if clean:match("^%[Авторынок%]") and clean:find("Вы продали", 1, true) then
            local car_name, buyer, price_str = clean:match("^%[Авторынок%]%s*Вы продали%s+(.-)%s+игроку%s+(.-)%s+за%s+([%d%.%,%s]+)%s*руб%.?")
            if car_name and buyer and price_str then
                car_name = car_name:match("^%s*(.-)%s*$")
                buyer = buyer:match("^%s*(.-)%s*$")
                local price = tonumber((price_str:gsub("%D", ""))) or 0
                if price > 0 then
                    api_SubmitCarSale(car_name, price)
                    addTransactionLog({
                        timestamp = os.time(),
                        date = os.date("%Y-%m-%d %H:%M:%S"),
                        type = "car_sale",
                        player = buyer,
                        item = car_name,
                        amount = 1,
                        price = price,
                        total = price
                    }, "shop_message")
                end
            end
        end
    end

    if not is_chat_message and clean:match("^%[Лавка%]") then
        local shop_text = clean:gsub("^%[Лавка%]%s*", "")
        if shop_text:find("Вы отказались от аренды лавки", 1, true)
            or shop_text:find("Вы сняли лавку", 1, true)
            or shop_text:find("Ваша лавка была закрыта", 1, true)
            or shop_text:find("Вы покинули лавку", 1, true) then
            clearMobileMarketplace(true)
        else
            local is_sale, player, raw_item_and_amount, total_str
            if shop_text:find("приобрел у Вас", 1, true) then
                is_sale = true
                player, raw_item_and_amount, total_str = shop_text:match("^(.-) приобрел у Вас (.-) за ([%d%.%,%s]+) руб%.?")
            elseif shop_text:find("продал Вам", 1, true) then
                is_sale = false
                player, raw_item_and_amount, total_str = shop_text:match("^(.-) продал Вам (.-) за ([%d%.%,%s]+) руб%.?")
            end
            if player and not player:find("%[%d+%]") and not player:find(":") and raw_item_and_amount and total_str then
                local model_id = tonumber(raw_item_and_amount:match("%(id:%s*(%d+)%)")) or 0
                raw_item_and_amount = raw_item_and_amount:gsub("%s*%(id:%s*%d+%)$", ""):gsub("%s*%(id:%s*%d+%)%s*", " ")
                local item, amount = raw_item_and_amount:match("^(.-)%s*%((%d+)%s*шт%.?%)$")
                if not item then item, amount = raw_item_and_amount, "1" end
                amount = tonumber(amount) or 1
                local total = tonumber((total_str:gsub("%D", ""))) or 0
                local clean_i = cleanItemName(item)
                if model_id <= 0 then model_id = findRealIndexByName(clean_i) or 0 end
                addTransactionLog({
                    timestamp = os.time(),
                    date = os.date("%Y-%m-%d %H:%M:%S"),
                    type = is_sale and "sale" or "purchase",
                    player = player,
                    item = clean_i,
                    model_id = model_id,
                    amount = amount,
                    price = amount > 0 and math.floor(total / amount) or total,
                    total = total
                }, "shop_message")
            end
        end
    end

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

    if not is_chat_message and (clean:find("Вы успешно продали") or clean:find("Вы успешно купили"))
        and not clean:find("бочка", 1, true) and not clean:find("бочку", 1, true)
        and not clean:find("Бочка", 1, true) and not clean:find("Бочку", 1, true) then
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
            local clean_i = cleanItemName(item)
            local seller_nick = Marketplace.current_shop_owner or State.last_manual_buy_seller or "Игрок"
            addTransactionLog({
                timestamp = os.time(),
                date = os.date("%Y-%m-%d %H:%M:%S"),
                type = is_sale and "sale" or "purchase",
                player = seller_nick,
                item = clean_i,
                model_id = findRealIndexByName(clean_i) or 0,
                amount = amount,
                price = price,
                total = total
            }, "success_message")
            State.last_manual_buy_seller = nil
        end
    end
end

function parseMobileCEF(msgId, subId, json_str)
    local ok, data = pcall(Dependencies.cjson.decode, json_str)
    if not ok or type(data) ~= "table" then return end
    captureMarketplaceCEF(msgId, subId, data)
    if type(data.items) ~= "table" then return end

    if State.selling.active and State.selling.stage == 'waiting_cef_data' and msgId == 52 and tonumber(data.type) == 1 then
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

    if State.inventory_scan.active and (msgId == 52 or msgId == 64 or msgId == 67)
        and tonumber(data.type) == 1 then
        if State.inventory_scan.stage == "waiting_user" then State.inventory_scan.stage = "parsing" end
        local max_slot = tonumber(data.max_slot)
        local reached_end = false

        for _, item in ipairs(data.items) do
            local slot_id = tonumber(item.slot)

            if slot_id then
                if max_slot and max_slot > 0 and slot_id == max_slot - 1 then
                    reached_end = true
                end

                local item_amt = tonumber(item.count) or tonumber(item.amount)
                local has_explicit_amount = item_amt ~= nil

                if not item_amt and item.text then
                    local clean_txt = tostring(item.text):gsub("{%x%x%x%x%x%x}", "")
                    local num_str = clean_txt:match("%d+")
                    if num_str then
                        item_amt = tonumber(num_str)
                        has_explicit_amount = true
                    end
                end

                item_amt = item_amt or 1

                local existing_item
                for _, v in ipairs(UI.inv_items) do
                    if v.slot == slot_id then
                        existing_item = v
                        break
                    end
                end

                if existing_item then
                    if has_explicit_amount and item_amt > 1 then
                        existing_item.amount = item_amt
                        existing_item.max_amount = item_amt
                    end
                elseif item.item and tonumber(item.available) == 1 and tonumber(item.is_use) ~= 1 then
                    local m_id = tonumber(item.item)

                    if m_id then
                        local name = UI.item_names[tostring(m_id)]
                        if name and name ~= "" then
                            table.insert(UI.inv_items, {
                                name = name,
                                amount = item_amt,
                                model_id = m_id,
                                slot = slot_id,
                                max_amount = item_amt
                            })
                        end
                    end
                end
            end
        end

        if reached_end then finishInventoryScan() end
    end
end

function onReceiveRpc(id, bs)
    if id == 130 then
        sendDisconnectNotification("Подключение отклонено (Слишком много попыток)")
    end
end

addEventHandler('onReceivePacket', function(id, bs)
    if id == 32 then
        sendDisconnectNotification("Потеря соединения (Disconnection Notification)")
        return
    elseif id == 33 then
        sendDisconnectNotification("Потеряно соединение (Таймаут / Краш интернета)")
        return
    elseif id == 36 then
        sendDisconnectNotification("Вам забанило IP адрес")
        return
    end
    if id == 220 then
        local saved_offset = raknetBitStreamGetReadOffset(bs)
        raknetBitStreamIgnoreBits(bs, 8)
        local pType = raknetBitStreamReadInt8(bs)
        
        if pType == 84 then
            local interfaceid = raknetBitStreamReadInt8(bs)
            local subid = raknetBitStreamReadInt8(bs)
            local should_parse = (interfaceid == 60 and (subid == 0 or subid == 1 or subid == 2))
                or (interfaceid == 6 and subid == 0)
                or (State.selling.active and interfaceid == 52 and subid == 2)
                or (State.inventory_scan.active and (interfaceid == 52 or interfaceid == 64 or interfaceid == 67))

            if should_parse then
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
                    parseMobileCEF(interfaceid, subid, json_str)
                end
            end
        end
        
        raknetBitStreamSetReadOffset(bs, saved_offset)
    end
end)

function formatMoney(amount)
    local left, num, right = string.match(tostring(amount), '^([^%d]*%d)(%d*)(.-)$')
    return left .. (num:reverse():gsub('(%d%d%d)', '%1.'):reverse()) .. right
end

function getCurrencyIcon()
    if UI.currency_icon then return UI.currency_icon end
    local ok, icon = pcall(Dependencies.fa, 'ruble_sign')
    if not ok or type(icon) ~= "string" or icon == "" then
        icon = Dependencies.fa('coins')
    end
    UI.currency_icon = icon
    return icon
end

function measureMoney(amount)
    Dependencies.imgui.PushFont(UI.font_main)
    local value_width = Dependencies.imgui.CalcTextSize(formatMoney(amount)).x
    Dependencies.imgui.PopFont()
    Dependencies.imgui.PushFont(UI.font_fa)
    local icon_width = Dependencies.imgui.CalcTextSize(getCurrencyIcon()).x
    Dependencies.imgui.PopFont()
    return value_width + icon_width + D(5), value_width
end

function drawMoney(dl, x, y, amount, color)
    local value = formatMoney(amount)
    local total_width, value_width = measureMoney(amount)
    Dependencies.imgui.PushFont(UI.font_main)
    dl:AddText(Dependencies.imgui.ImVec2(x, y), Dependencies.imgui.ColorConvertFloat4ToU32(color), value)
    Dependencies.imgui.PopFont()
    Dependencies.imgui.PushFont(UI.font_fa)
    dl:AddText(Dependencies.imgui.ImVec2(x + value_width + D(5), y), Dependencies.imgui.ColorConvertFloat4ToU32(color), getCurrencyIcon())
    Dependencies.imgui.PopFont()
    return total_width
end

UI.LOWERCASE_MAP = {}
for i = 0, 255 do
    local char = string.char(i)
    if i >= 192 and i <= 223 then
        UI.LOWERCASE_MAP[char] = string.char(i + 32)
    elseif i == 168 then
        UI.LOWERCASE_MAP[char] = string.char(184)
    else
        UI.LOWERCASE_MAP[char] = string.lower(char)
    end
end

function to_lower(str)
    if type(str) ~= "string" then return "" end
    return (str:gsub(".", UI.LOWERCASE_MAP))
end

SmartSearch.levenshteinWithin = function(s1, s2, max_distance)
    if math.abs(#s1 - #s2) > max_distance then return max_distance + 1 end
    if #s1 == 0 then return #s2 end
    if #s2 == 0 then return #s1 end

    local previous = {}
    for j = 0, math.min(#s2, max_distance) do previous[j] = j end

    for i = 1, #s1 do
        local current = {}
        local start_j = math.max(1, i - max_distance)
        local end_j = math.min(#s2, i + max_distance)
        if start_j == 1 then current[0] = i else current[start_j - 1] = max_distance + 1 end
        local row_min = max_distance + 1

        for j = start_j, end_j do
            local cost = s1:sub(i, i) == s2:sub(j, j) and 0 or 1
            current[j] = math.min(
                (previous[j] or max_distance + 1) + 1,
                (current[j - 1] or max_distance + 1) + 1,
                (previous[j - 1] or max_distance + 1) + cost
            )
            row_min = math.min(row_min, current[j])
        end

        if row_min > max_distance then return max_distance + 1 end
        previous = current
    end

    return previous[#s2] or max_distance + 1
end

SmartSearch.fixLayout = function(text)
    local result = {}
    for i = 1, #text do
        local char = text:sub(i, i)
        table.insert(result, UI.LAYOUT_MAP[char] or char)
    end
    return table.concat(result)
end

SmartSearch.tokenize = function(text)
    local tokens = {}
    for word in text:gmatch("%S+") do table.insert(tokens, word) end
    return tokens
end

SmartSearch.prepareQuery = function(query)
    local fixed = SmartSearch.fixLayout(query)
    return {
        text = query,
        tokens = SmartSearch.tokenize(query),
        fixed = fixed,
        fixed_tokens = SmartSearch.tokenize(fixed)
    }
end

SmartSearch.getMatchScore = function(query, entry)
    local q_norm = query.text
    local t_norm = entry.search_name
    if q_norm == t_norm then return 100 end
    local find_start = t_norm:find(q_norm, 1, true)
    if find_start then
        if find_start == 1 or t_norm:sub(find_start-1, find_start-1) == " " then return 90 else return 80 end
    end
    local q_tokens = query.tokens
    if #q_tokens > 1 then
        local all_words_found = true
        for _, q_word in ipairs(q_tokens) do
            if not t_norm:find(q_word, 1, true) then all_words_found = false break end
        end
        if all_words_found then return 75 end
    end
    local q_fixed = query.fixed
    if q_fixed ~= q_norm then
        if t_norm:find(q_fixed, 1, true) then return 70 end
        local fixed_tokens = query.fixed_tokens
        if #fixed_tokens > 1 then
            local all_fixed_found = true
            for _, f_word in ipairs(fixed_tokens) do
                if not t_norm:find(f_word, 1, true) then all_fixed_found = false break end
            end
            if all_fixed_found then return 65 end
        end
    end
    if #q_norm > 3 then
        local t_tokens = entry.search_tokens
        if not t_tokens then
            t_tokens = SmartSearch.tokenize(t_norm)
            entry.search_tokens = t_tokens
        end
        local total_words_matched = 0
        local fuzzy_penalty = 0
        for _, q_word in ipairs(q_tokens) do
            local best_word_score = 0
            for _, t_word in ipairs(t_tokens) do
                if t_word == q_word then best_word_score = 10
                elseif t_word:find(q_word, 1, true) then best_word_score = 8
                elseif #q_word > 2 and #t_word > 2 then
                    local allowed_errors = math.floor(#q_word / 3) 
                    local dist = SmartSearch.levenshteinWithin(q_word, t_word, allowed_errors)
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

function updateResponsiveUi()
    local screen_w, screen_h = getScreenResolution()
    local short_side = math.min(screen_w, screen_h)
    UI.scale = math.min(1.6, math.max(0.75, short_side / 720.0)) * Settings.ui_scale

    local io = Dependencies.imgui.GetIO()
    io.FontGlobalScale = UI.scale

    local style = Dependencies.imgui.GetStyle()
    style.WindowRounding = D(8)
    style.ChildRounding = D(6)
    style.FrameRounding = D(6)
    style.ScrollbarSize = Touch(24)
    style.ScrollbarRounding = D(6)
    style.WindowPadding = Dependencies.imgui.ImVec2(D(16), D(14))
    style.FramePadding = Dependencies.imgui.ImVec2(D(12), D(10))
    style.ItemSpacing = Dependencies.imgui.ImVec2(D(10), D(10))
    style.ItemInnerSpacing = Dependencies.imgui.ImVec2(D(8), D(8))
    style.GrabMinSize = Touch(24)
end

function DrawRowAligned(label, val_str, val_col, icon, content_w, is_money)
    local icon_width = 0
    local currency_width = 0
    Dependencies.imgui.PushFont(UI.font_main)
    local label_size = Dependencies.imgui.CalcTextSize(label)
    local value_size = Dependencies.imgui.CalcTextSize(val_str)
    Dependencies.imgui.PopFont()
    if is_money then currency_width = measureMoney(val_str) - value_size.x end
    if UI.font_fa and icon then
        Dependencies.imgui.PushFont(UI.font_fa)
        icon_width = Dependencies.imgui.CalcTextSize(icon).x
        Dependencies.imgui.TextColored(THEME.text_secondary, icon)
        Dependencies.imgui.PopFont()
        Dependencies.imgui.SameLine(0, D(8))
    end
    Dependencies.imgui.PushFont(UI.font_main)
    Dependencies.imgui.TextColored(THEME.text_secondary, label)
    if icon_width + label_size.x + value_size.x + currency_width + D(16) <= content_w then
        Dependencies.imgui.SameLine(D(14) + content_w - value_size.x - currency_width)
    end
    Dependencies.imgui.TextColored(val_col, val_str)
    if is_money then
        Dependencies.imgui.SameLine(0, D(5))
        Dependencies.imgui.PushFont(UI.font_fa)
        Dependencies.imgui.TextColored(val_col, getCurrencyIcon())
        Dependencies.imgui.PopFont()
    end
    Dependencies.imgui.PopFont()
end

function renderLiveProfitHUD()
    if not Settings.show_live_hud or UI.win_state[0] or cfg_modal.active or State.show_db_modal
        or State.inventory_scan.active or State.selling.active or State.buying.active then return end

    local sw, sh = getScreenResolution()
    local expanded = UI.hud_expanded
    local max_width = math.max(D(220), sw - D(24))
    local hud_w = math.min(max_width, D(expanded and 350 or 320))
    local hud_h = expanded and D(220) or Touch(58)

    if Settings.hud_pos_x == nil or Settings.hud_pos_y == nil or Settings.hud_pos_x == -1 then
        Dependencies.imgui.SetNextWindowPos(Dependencies.imgui.ImVec2(sw - D(16), sh - D(16)), Dependencies.imgui.Cond.Always, Dependencies.imgui.ImVec2(1, 1))
    else
        Settings.hud_pos_x = math.max(0, math.min(Settings.hud_pos_x, sw - hud_w))
        Settings.hud_pos_y = math.max(0, math.min(Settings.hud_pos_y, sh - hud_h))
        Dependencies.imgui.SetNextWindowPos(Dependencies.imgui.ImVec2(Settings.hud_pos_x, Settings.hud_pos_y), Dependencies.imgui.Cond.Always)
    end
    Dependencies.imgui.SetNextWindowSize(Dependencies.imgui.ImVec2(hud_w, hud_h), Dependencies.imgui.Cond.Always)

    Dependencies.imgui.PushStyleVarVec2(Dependencies.imgui.StyleVar.WindowPadding, Dependencies.imgui.ImVec2(0, 0))
    Dependencies.imgui.PushStyleVarFloat(Dependencies.imgui.StyleVar.WindowRounding, expanded and D(12) or hud_h / 2)
    Dependencies.imgui.PushStyleVarFloat(Dependencies.imgui.StyleVar.WindowBorderSize, 0)
    Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.WindowBg, Dependencies.imgui.ImVec4(0, 0, 0, 0))
    Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Border, Dependencies.imgui.ImVec4(0, 0, 0, 0))

    local flags = Dependencies.imgui.WindowFlags.NoTitleBar + Dependencies.imgui.WindowFlags.NoResize
        + Dependencies.imgui.WindowFlags.NoSavedSettings + Dependencies.imgui.WindowFlags.NoScrollbar
        + Dependencies.imgui.WindowFlags.NoScrollWithMouse + Dependencies.imgui.WindowFlags.NoBackground

    if Dependencies.imgui.Begin("##LiveProfitHUDMob", nil, flags) then
        local dl = Dependencies.imgui.GetWindowDrawList()
        local p = Dependencies.imgui.GetWindowPos()
        local bounds = Dependencies.imgui.ImVec2(p.x + hud_w, p.y + hud_h)
        local rounding = expanded and D(12) or hud_h / 2
        local earned = LogsState.today.earned or 0
        local spent = LogsState.today.spent or 0
        local trades_count = LogsState.today.trades or 0
        local dt = Dependencies.imgui.GetIO().DeltaTime
        UI.hud_anim.e = UI.hud_anim.e + (earned - UI.hud_anim.e) * dt * 8.0
        UI.hud_anim.s = UI.hud_anim.s + (spent - UI.hud_anim.s) * dt * 8.0
        local profit = math.floor(UI.hud_anim.e) - math.floor(UI.hud_anim.s)
        local profit_color = profit >= 0 and THEME.accent_success or THEME.accent_danger
        local profit_bg = profit >= 0
            and Dependencies.imgui.ImVec4(THEME.accent_success.x, THEME.accent_success.y, THEME.accent_success.z, 0.12)
            or Dependencies.imgui.ImVec4(THEME.accent_danger.x, THEME.accent_danger.y, THEME.accent_danger.z, 0.12)

        local close_size = Touch(40)
        local drag_w = expanded and (hud_w - close_size - D(5)) or hud_w
        local drag_h = expanded and Touch(48) or hud_h
        Dependencies.imgui.SetCursorScreenPos(p)
        local clicked = Dependencies.imgui.InvisibleButton(expanded and "##live_hud_header_drag" or "##live_hud_surface", Dependencies.imgui.ImVec2(drag_w, drag_h))
        local dragging = Dependencies.imgui.IsItemActive() and Dependencies.imgui.IsMouseDragging(0, -1.0)
        if dragging then
            UI.hud_dragged = true
            local delta = Dependencies.imgui.GetMouseDragDelta(0, -1.0)
            Settings.hud_pos_x = math.max(0, math.min(p.x + delta.x, sw - hud_w))
            Settings.hud_pos_y = math.max(0, math.min(p.y + delta.y, sh - hud_h))
            Dependencies.imgui.ResetMouseDragDelta(0)
            saveJsonFile(UI.PATH_SETTINGS, Settings)
        end
        if clicked then
            if not UI.hud_dragged and not expanded then UI.hud_expanded = true end
            UI.hud_dragged = false
        elseif Dependencies.imgui.IsMouseReleased(0) then
            UI.hud_dragged = false
        end

        dl:AddRectFilled(p, bounds, Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(0.055, 0.075, 0.085, 0.97)), rounding)
        dl:AddRect(p, bounds, Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_primary), rounding, 15, D(1.5))

        if expanded then
            local title_y = p.y + D(13)
            local dot = Dependencies.imgui.ImVec2(p.x + D(20), title_y + D(10))
            dl:AddCircleFilled(dot, D(5), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_success))
            Dependencies.imgui.PushFont(UI.font_main)
            dl:AddText(Dependencies.imgui.ImVec2(p.x + D(34), title_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), Dependencies.u8"RMarket Live")
            local trades_text = Dependencies.u8(tostring(trades_count) .. " сделок")
            local trades_w = Dependencies.imgui.CalcTextSize(trades_text).x
            dl:AddText(Dependencies.imgui.ImVec2(p.x + hud_w - D(54) - trades_w, title_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_secondary), trades_text)
            Dependencies.imgui.PopFont()

            local close_pos = Dependencies.imgui.ImVec2(p.x + hud_w - close_size - D(5), p.y + D(5))
            Dependencies.imgui.SetCursorScreenPos(close_pos)
            if Dependencies.imgui.InvisibleButton("##live_hud_close", Dependencies.imgui.ImVec2(close_size, close_size)) then
                UI.hud_expanded = false
            end
            local close_active = Dependencies.imgui.IsItemActive()
            local close_hovered = Dependencies.imgui.IsItemHovered()
            local close_color = (close_active or close_hovered) and THEME.text_primary or THEME.text_secondary
            if close_active or close_hovered then
                local close_bg = close_active and THEME.accent_danger or THEME.bg_tertiary
                dl:AddCircleFilled(Dependencies.imgui.ImVec2(close_pos.x + close_size / 2, close_pos.y + close_size / 2), close_size / 2, Dependencies.imgui.ColorConvertFloat4ToU32(close_bg))
            end
            local close_icon = Dependencies.fa('xmark')
            Dependencies.imgui.PushFont(UI.font_fa_large)
            local close_icon_size = Dependencies.imgui.CalcTextSize(close_icon)
            dl:AddText(Dependencies.imgui.ImVec2(close_pos.x + (close_size - close_icon_size.x) / 2, close_pos.y + (close_size - close_icon_size.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(close_color), close_icon)
            Dependencies.imgui.PopFont()

            local rows = {
                { label = Dependencies.u8"Доход сегодня", value = math.floor(UI.hud_anim.e), color = THEME.accent_success, icon = Dependencies.fa('arrow_up') },
                { label = Dependencies.u8"Расход сегодня", value = math.floor(UI.hud_anim.s), color = THEME.accent_danger, icon = Dependencies.fa('arrow_down') },
                { label = Dependencies.u8"Чистая прибыль", value = profit, color = profit_color, icon = Dependencies.fa('chart_pie') }
            }
            local row_h = D(46)
            local start_y = p.y + D(58)
            for i, row in ipairs(rows) do
                local row_y = start_y + (i - 1) * row_h
                if i == 3 then
                    dl:AddRectFilled(Dependencies.imgui.ImVec2(p.x + D(8), row_y - D(2)), Dependencies.imgui.ImVec2(p.x + hud_w - D(8), row_y + row_h - D(3)), Dependencies.imgui.ColorConvertFloat4ToU32(profit_bg), D(8))
                elseif i > 1 then
                    dl:AddLine(Dependencies.imgui.ImVec2(p.x + D(16), row_y - D(5)), Dependencies.imgui.ImVec2(p.x + hud_w - D(16), row_y - D(5)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), D(1))
                end
                local money_w = measureMoney(row.value)
                local value_x = p.x + hud_w - D(16) - money_w
                local icon_center = Dependencies.imgui.ImVec2(p.x + D(27), row_y + row_h / 2)
                dl:AddCircleFilled(icon_center, D(12), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(row.color.x, row.color.y, row.color.z, 0.14)))
                Dependencies.imgui.PushFont(UI.font_fa)
                local row_icon_size = Dependencies.imgui.CalcTextSize(row.icon)
                dl:AddText(Dependencies.imgui.ImVec2(icon_center.x - row_icon_size.x / 2, icon_center.y - row_icon_size.y / 2 - D(2)), Dependencies.imgui.ColorConvertFloat4ToU32(row.color), row.icon)
                Dependencies.imgui.PopFont()
                dl:PushClipRect(Dependencies.imgui.ImVec2(p.x + D(44), row_y), Dependencies.imgui.ImVec2(value_x - D(8), row_y + row_h), true)
                Dependencies.imgui.PushFont(UI.font_main)
                dl:AddText(Dependencies.imgui.ImVec2(p.x + D(44), row_y + D(10)), Dependencies.imgui.ColorConvertFloat4ToU32(i == 3 and THEME.text_primary or THEME.text_secondary), row.label)
                Dependencies.imgui.PopFont()
                dl:PopClipRect()
                drawMoney(dl, value_x, row_y + D(10), row.value, row.color)
            end
        else
            local dot = Dependencies.imgui.ImVec2(p.x + D(22), p.y + hud_h / 2)
            local pulse = (math.sin(os.clock() * 5) + 1) * 0.5
            dl:AddCircleFilled(dot, D(9), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(THEME.accent_success.x, THEME.accent_success.y, THEME.accent_success.z, 0.18 + pulse * 0.18)))
            dl:AddCircleFilled(dot, D(4), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_success))
            local live_text = Dependencies.u8"LIVE"
            Dependencies.imgui.PushFont(UI.font_main)
            local live_size = Dependencies.imgui.CalcTextSize(live_text)
            local left_x = p.x + D(38)
            local text_y = p.y + (hud_h - live_size.y) / 2
            dl:AddText(Dependencies.imgui.ImVec2(left_x, text_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), live_text)
            Dependencies.imgui.PopFont()
            local money_w = measureMoney(profit)
            drawMoney(dl, p.x + hud_w - D(16) - money_w, p.y + (hud_h - live_size.y) / 2, profit, profit_color)
        end
    end
    Dependencies.imgui.End()
    Dependencies.imgui.PopStyleColor(2)
    Dependencies.imgui.PopStyleVar(3)
end

Dependencies.imgui.OnInitialize(function()
    local io = Dependencies.imgui.GetIO()
    io.IniFilename = nil
    
    local style = Dependencies.imgui.GetStyle()
    style.WindowRounding    = 16.0
    style.ChildRounding     = 12.0
    style.FrameRounding     = 12.0
    style.ScrollbarSize     = 20.0
    style.ScrollbarRounding = 10.0
    style.WindowPadding     = Dependencies.imgui.ImVec2(0, 0)
    style.ItemSpacing       = Dependencies.imgui.ImVec2(10, 10)

    style.Colors[Dependencies.imgui.Col.WindowBg]             = THEME.bg_main
    style.Colors[Dependencies.imgui.Col.ChildBg]              = THEME.bg_secondary
    style.Colors[Dependencies.imgui.Col.Text]                 = THEME.text_primary
    style.Colors[Dependencies.imgui.Col.TextDisabled]         = THEME.text_secondary
    style.Colors[Dependencies.imgui.Col.Border]               = THEME.border
    style.Colors[Dependencies.imgui.Col.ScrollbarBg]          = Dependencies.imgui.ImVec4(0,0,0,0)
    style.Colors[Dependencies.imgui.Col.ScrollbarGrab]        = THEME.bg_tertiary
    style.Colors[Dependencies.imgui.Col.ScrollbarGrabHovered] = THEME.bg_tertiary
    style.Colors[Dependencies.imgui.Col.ScrollbarGrabActive]  = THEME.accent_primary

    local config = Dependencies.imgui.ImFontConfig()
    config.MergeMode = false
    
    local font_path = getWorkingDirectory() .. '/resource/fonts/trebucbd.ttf'
    
    UI.font_main = io.Fonts:AddFontFromFileTTF(font_path, 20.0, config, io.Fonts:GetGlyphRangesCyrillic())
    
    local icon_config = Dependencies.imgui.ImFontConfig()
    icon_config.MergeMode = true
    icon_config.GlyphOffset = Dependencies.imgui.ImVec2(0, 0)
    local fa_ranges = Dependencies.imgui.new.ImWchar[3](Dependencies.fa.min_range, Dependencies.fa.max_range, 0)
    
    UI.font_fa = io.Fonts:AddFontFromMemoryCompressedBase85TTF(Dependencies.fa.get_font_data_base85('solid'), 20.0, icon_config, fa_ranges)
    
    local large_icon_config = Dependencies.imgui.ImFontConfig()
    UI.font_fa_large = io.Fonts:AddFontFromMemoryCompressedBase85TTF(Dependencies.fa.get_font_data_base85('solid'), 28.0, large_icon_config, fa_ranges)

end)

function renderSourceCard(item, is_sell, index, target_table)
    local w = Dependencies.imgui.GetContentRegionAvail().x
    local h = D(96)
    local p = Dependencies.imgui.GetCursorScreenPos()
    local dl = Dependencies.imgui.GetWindowDrawList()

    local is_added = false
    if is_sell then
        for _, v in ipairs(target_table) do
            if v.name == item.name then is_added = true break end
        end
    end

    Dependencies.imgui.SetCursorScreenPos(p)
    Dependencies.imgui.InvisibleButton("##src_"..tostring(is_sell).."_"..index, Dependencies.imgui.ImVec2(w, h))
    local is_active = Dependencies.imgui.IsItemActive()

    if Dependencies.imgui.IsItemHovered() and Dependencies.imgui.IsMouseReleased(0) and not touch_state.is_dragging then
        if not is_added then
            table.insert(target_table, {
                name = item.name,
                model_id = item.model_id or item.index,
                amount = item.max_amount or 1, 
                max_amount = item.max_amount,
                price = 1000,
                auto_max = is_sell
            })
            if is_sell then saveJsonFile(UI.PATH_CFG_SELL, UI.config_sell) else saveJsonFile(UI.PATH_CFG_BUY, UI.config_buy) end
        end
    end

    local bg_col = THEME.bg_secondary
    local border_col = THEME.border
    if is_added then
        bg_col = Dependencies.imgui.ImVec4(THEME.accent_success.x, THEME.accent_success.y, THEME.accent_success.z, 0.15)
        border_col = Dependencies.imgui.ImVec4(THEME.accent_success.x, THEME.accent_success.y, THEME.accent_success.z, 0.4)
    elseif is_active then
        bg_col = THEME.bg_tertiary
    end

    dl:AddRectFilled(p, Dependencies.imgui.ImVec2(p.x + w, p.y + h), Dependencies.imgui.ColorConvertFloat4ToU32(bg_col), D(8))
    dl:AddRect(p, Dependencies.imgui.ImVec2(p.x + w, p.y + h), Dependencies.imgui.ColorConvertFloat4ToU32(border_col), D(8), 15, D(1.5))

    local icon_sz = D(52)
    local icon_x = p.x + D(16)
    local icon_y = p.y + (h - icon_sz) / 2
    local icon_bg = is_added and THEME.accent_success or THEME.bg_main
    local icon_text_col = is_added and THEME.bg_main or THEME.text_secondary
    dl:AddCircleFilled(Dependencies.imgui.ImVec2(icon_x + icon_sz/2, icon_y + icon_sz/2), icon_sz/2, Dependencies.imgui.ColorConvertFloat4ToU32(icon_bg))
    
    Dependencies.imgui.PushFont(UI.font_fa_large)
    local item_icon = is_added and Dependencies.fa('check') or (is_sell and Dependencies.fa('box') or Dependencies.fa('tag'))
    local isz = Dependencies.imgui.CalcTextSize(item_icon)
    dl:AddText(Dependencies.imgui.ImVec2(icon_x + (icon_sz - isz.x)/2, icon_y + (icon_sz - isz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(icon_text_col), item_icon)
    Dependencies.imgui.PopFont()

    local plus_area_w = Touch(64)
    local plus_x = p.x + w - plus_area_w
    dl:AddRectFilled(Dependencies.imgui.ImVec2(plus_x, p.y), Dependencies.imgui.ImVec2(p.x + w, p.y + h), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(0,0,0,0.1)), D(8), 6)
    dl:AddLine(Dependencies.imgui.ImVec2(plus_x, p.y), Dependencies.imgui.ImVec2(plus_x, p.y + h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), D(1.5))

    Dependencies.imgui.PushFont(UI.font_fa_large)
    local plus_icon = is_added and Dependencies.fa('check') or Dependencies.fa('plus')
    local psz = Dependencies.imgui.CalcTextSize(plus_icon)
    local p_col = is_added and THEME.accent_success or (is_active and THEME.accent_success or THEME.text_secondary)
    dl:AddText(Dependencies.imgui.ImVec2(plus_x + (plus_area_w - psz.x)/2, p.y + (h - psz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(p_col), plus_icon)
    Dependencies.imgui.PopFont()

    local text_x = icon_x + icon_sz + D(16)
    Dependencies.imgui.PushFont(UI.font_main)
    local name_str = Dependencies.u8(item.name)
    local text_y = p.y + (h - Dependencies.imgui.GetFontSize()) / 2
    
    dl:PushClipRect(Dependencies.imgui.ImVec2(text_x, p.y), Dependencies.imgui.ImVec2(plus_x - D(12), p.y + h), true)
    
    if not is_sell and item.amount then
        dl:AddText(Dependencies.imgui.ImVec2(text_x, p.y + D(18)), Dependencies.imgui.ColorConvertFloat4ToU32(is_added and THEME.text_secondary or THEME.text_primary), name_str)
        dl:AddText(Dependencies.imgui.ImVec2(text_x, p.y + D(48)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_secondary), Dependencies.u8"В наличии: " .. item.amount)
    else
        dl:AddText(Dependencies.imgui.ImVec2(text_x, text_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), name_str)
    end
    
    dl:PopClipRect()
    Dependencies.imgui.PopFont()

    Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(12)))
end

function renderTargetCard(item, is_sell, index, target_table)
    local w = Dependencies.imgui.GetContentRegionAvail().x
    local h = D(108)
    local p = Dependencies.imgui.GetCursorScreenPos()
    local dl = Dependencies.imgui.GetWindowDrawList()

    Dependencies.imgui.SetCursorScreenPos(p)
    Dependencies.imgui.InvisibleButton("##tgt_"..tostring(is_sell).."_"..index, Dependencies.imgui.ImVec2(w, h))
    local is_active = Dependencies.imgui.IsItemActive()

    if Dependencies.imgui.IsItemHovered() and Dependencies.imgui.IsMouseReleased(0) and not touch_state.is_dragging then
        cfg_modal.active = true
        cfg_modal.item = item
        cfg_modal.index = index
        cfg_modal.is_sell = is_sell
        cfg_modal.target_table = target_table
        cfg_modal.auto_max = item.auto_max or false
        Dependencies.ffi.copy(cfg_modal.buf_price, tostring(item.price))
        Dependencies.ffi.copy(cfg_modal.buf_amount, tostring(item.amount or 1))
    end

    local bg_col = is_active and THEME.bg_tertiary or THEME.bg_secondary
    dl:AddRectFilled(p, Dependencies.imgui.ImVec2(p.x + w, p.y + h), Dependencies.imgui.ColorConvertFloat4ToU32(bg_col), D(8))
    dl:AddRect(p, Dependencies.imgui.ImVec2(p.x + w, p.y + h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), D(8), 15, D(1.5))
    
    local accent = is_sell and THEME.accent_success or THEME.accent_primary
    dl:AddRectFilled(p, Dependencies.imgui.ImVec2(p.x + D(6), p.y + h), Dependencies.imgui.ColorConvertFloat4ToU32(accent), D(8), 9)

    local gear_area_w = Touch(64)
    local gear_x = p.x + w - gear_area_w
    dl:AddRectFilled(Dependencies.imgui.ImVec2(gear_x, p.y), Dependencies.imgui.ImVec2(p.x + w, p.y + h), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(0,0,0,0.1)), D(8), 6)
    dl:AddLine(Dependencies.imgui.ImVec2(gear_x, p.y), Dependencies.imgui.ImVec2(gear_x, p.y + h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), D(1.5))

    Dependencies.imgui.PushFont(UI.font_fa_large)
    local gear_icon = Dependencies.fa('gear')
    local gsz = Dependencies.imgui.CalcTextSize(gear_icon)
    dl:AddText(Dependencies.imgui.ImVec2(gear_x + (gear_area_w - gsz.x)/2, p.y + (h - gsz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(is_active and THEME.text_primary or THEME.text_secondary), gear_icon)
    Dependencies.imgui.PopFont()

    local text_x = p.x + D(20)
    Dependencies.imgui.PushFont(UI.font_main)
    local name_str = Dependencies.u8(item.name)
    
    dl:PushClipRect(Dependencies.imgui.ImVec2(text_x, p.y), Dependencies.imgui.ImVec2(gear_x - D(12), p.y + h), true)
    dl:AddText(Dependencies.imgui.ImVec2(text_x, p.y + D(14)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), name_str)
    dl:PopClipRect()

    local money_width = drawMoney(dl, text_x, p.y + D(62), item.price, accent)
    local quantity_text = Dependencies.u8("| " .. tostring(math.floor(tonumber(item.amount) or 1)) .. " шт.")
    dl:AddText(Dependencies.imgui.ImVec2(text_x + money_width + D(6), p.y + D(62)), Dependencies.imgui.ColorConvertFloat4ToU32(accent), quantity_text)
    Dependencies.imgui.PopFont()

    Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(12)))
end

function renderUndoSnackbar()
    if #UI.undo_stack == 0 then return end
    
    local now = os.clock()
    if now > UI.undo_timer then
        UI.undo_stack = {}
        return
    end

    local sw, sh = getScreenResolution()
    local last_deleted = UI.undo_stack[#UI.undo_stack]
    local name_short = last_deleted.item.name
    if #name_short > 20 then name_short = name_short:sub(1, 20) .. "..." end
    
    local text = Dependencies.u8"Удалено: " .. Dependencies.u8(name_short)
    local btn_text = Dependencies.u8"ВЕРНУТЬ"
    
    Dependencies.imgui.PushFont(UI.font_main)
    local t_sz = Dependencies.imgui.CalcTextSize(text)
    local b_sz = Dependencies.imgui.CalcTextSize(btn_text)
    Dependencies.imgui.PopFont()

    local box_w = t_sz.x + b_sz.x + D(64)
    local box_h = Touch(48)
    local box_x = (sw - box_w) / 2
    local box_y = D(24)

    local alpha = 1.0
    local time_left = UI.undo_timer - now
    if time_left < 0.5 then alpha = time_left * 2.0 end

    Dependencies.imgui.SetNextWindowPos(Dependencies.imgui.ImVec2(box_x, box_y), Dependencies.imgui.Cond.Always)
    Dependencies.imgui.SetNextWindowSize(Dependencies.imgui.ImVec2(box_w, box_h), Dependencies.imgui.Cond.Always)
    Dependencies.imgui.PushStyleVarFloat(Dependencies.imgui.StyleVar.WindowRounding, D(8))
    Dependencies.imgui.PushStyleVarVec2(Dependencies.imgui.StyleVar.WindowPadding, Dependencies.imgui.ImVec2(0, 0))
    Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.WindowBg, Dependencies.imgui.ImVec4(0.12, 0.12, 0.14, 0.95 * alpha))
    Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Border, Dependencies.imgui.ImVec4(1, 1, 1, 0.1 * alpha))
    Dependencies.imgui.PushStyleVarFloat(Dependencies.imgui.StyleVar.WindowBorderSize, 2.0)

    if Dependencies.imgui.Begin("##UndoSnackbar", nil, Dependencies.imgui.WindowFlags.NoTitleBar + Dependencies.imgui.WindowFlags.NoResize + Dependencies.imgui.WindowFlags.NoMove + Dependencies.imgui.WindowFlags.NoSavedSettings) then
        local dl = Dependencies.imgui.GetWindowDrawList()
        
        Dependencies.imgui.PushFont(UI.font_main)
        dl:AddText(Dependencies.imgui.ImVec2(box_x + D(16), box_y + (box_h - t_sz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(0.8, 0.8, 0.8, alpha)), text)
        
        local btn_x = box_x + box_w - b_sz.x - D(16)
        
        Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(btn_x - D(8), box_y))
        if Dependencies.imgui.InvisibleButton("##undo_btn", Dependencies.imgui.ImVec2(b_sz.x + D(16), box_h)) then
            local target_list = (last_deleted.list == "sell") and UI.config_sell or UI.config_buy
            local target_index = math.min(last_deleted.index, #target_list + 1)
            
            table.insert(target_list, target_index, last_deleted.item)
            table.remove(UI.undo_stack, #UI.undo_stack)
            
            if last_deleted.list == "sell" then saveJsonFile(UI.PATH_CFG_SELL, UI.config_sell) else saveJsonFile(UI.PATH_CFG_BUY, UI.config_buy) end
        end
        
        local btn_col = Dependencies.imgui.IsItemActive() and THEME.text_primary or THEME.accent_primary
        dl:AddText(Dependencies.imgui.ImVec2(btn_x, box_y + (box_h - b_sz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(btn_col.x, btn_col.y, btn_col.z, alpha)), btn_text)
        Dependencies.imgui.PopFont()
    end
    Dependencies.imgui.End()
    Dependencies.imgui.PopStyleColor(2)
    Dependencies.imgui.PopStyleVar(3)
end

function DrawStyledButton(id, label, w, h, col, icon, dl)
    local p = Dependencies.imgui.GetCursorScreenPos()
    local clicked = false
    if Dependencies.imgui.InvisibleButton(id, Dependencies.imgui.ImVec2(w, h)) then clicked = true end
    local active = Dependencies.imgui.IsItemActive()
    local bg = active and Dependencies.imgui.ImVec4(col.x*0.8, col.y*0.8, col.z*0.8, 1) or col
    dl:AddRectFilled(p, Dependencies.imgui.ImVec2(p.x + w, p.y + h), Dependencies.imgui.ColorConvertFloat4ToU32(bg), D(8))
    
    local c_w = 0
    Dependencies.imgui.PushFont(UI.font_fa)
    local i_sz = icon and Dependencies.imgui.CalcTextSize(icon) or Dependencies.imgui.ImVec2(0,0)
    Dependencies.imgui.PopFont()
    Dependencies.imgui.PushFont(UI.font_main)
    local t_sz = Dependencies.imgui.CalcTextSize(label)
    Dependencies.imgui.PopFont()
    
    if icon then c_w = i_sz.x + D(8) + t_sz.x else c_w = t_sz.x end
    local start_x = p.x + (w - c_w) / 2
    
    if icon then
        Dependencies.imgui.PushFont(UI.font_fa)
        dl:AddText(Dependencies.imgui.ImVec2(start_x, p.y + (h - i_sz.y)/2), 0xFFFFFFFF, icon)
        Dependencies.imgui.PopFont()
        start_x = start_x + i_sz.x + D(8)
    end
    Dependencies.imgui.PushFont(UI.font_main)
    dl:AddText(Dependencies.imgui.ImVec2(start_x, p.y + (h - t_sz.y)/2), 0xFFFFFFFF, label)
    Dependencies.imgui.PopFont()
    
    return clicked
end

function renderDbRequiredModal()
    if not State.show_db_modal then return end
    local sw, sh = getScreenResolution()
    local m_w, m_h = math.min(sw - D(32), D(460)), math.min(sh - D(32), D(300))
    Dependencies.imgui.SetNextWindowPos(Dependencies.imgui.ImVec2(sw / 2, sh / 2), Dependencies.imgui.Cond.Always, Dependencies.imgui.ImVec2(0.5, 0.5))
    Dependencies.imgui.SetNextWindowSize(Dependencies.imgui.ImVec2(m_w, m_h), Dependencies.imgui.Cond.Always)

    Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.WindowBg, Dependencies.imgui.ImVec4(THEME.bg_secondary.x, THEME.bg_secondary.y, THEME.bg_secondary.z, 0.98))
    Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Border, THEME.accent_primary)
    Dependencies.imgui.PushStyleVarFloat(Dependencies.imgui.StyleVar.WindowRounding, D(8))
    Dependencies.imgui.PushStyleVarFloat(Dependencies.imgui.StyleVar.WindowBorderSize, 2.0)
    Dependencies.imgui.PushStyleVarVec2(Dependencies.imgui.StyleVar.WindowPadding, Dependencies.imgui.ImVec2(0, 0))

    local modal_flags = Dependencies.imgui.WindowFlags.NoTitleBar + Dependencies.imgui.WindowFlags.NoResize
        + Dependencies.imgui.WindowFlags.NoMove + Dependencies.imgui.WindowFlags.NoScrollbar
        + Dependencies.imgui.WindowFlags.NoScrollWithMouse
    if Dependencies.imgui.Begin("##DbRequiredModal", nil, modal_flags) then
        local p = Dependencies.imgui.GetCursorScreenPos()
        local dl = Dependencies.imgui.GetWindowDrawList()

        local icon_sz = D(56)
        local center_icon = Dependencies.imgui.ImVec2(p.x + m_w / 2, p.y + D(48))
        dl:AddCircleFilled(center_icon, icon_sz / 2, Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_main))

        Dependencies.imgui.PushFont(UI.font_fa_large)
        local icon = Dependencies.fa('cloud_arrow_down')
        local isz = Dependencies.imgui.CalcTextSize(icon)
        dl:AddText(Dependencies.imgui.ImVec2(center_icon.x - isz.x / 2, center_icon.y - isz.y / 2), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_primary), icon)
        Dependencies.imgui.PopFont()

        Dependencies.imgui.PushFont(UI.font_main)
        local title = Dependencies.u8"Требуется база предметов"
        local t_sz = Dependencies.imgui.CalcTextSize(title)
        dl:AddText(Dependencies.imgui.ImVec2(p.x + (m_w - t_sz.x) / 2, p.y + D(92)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), title)

        local sub1 = Dependencies.u8"Для сканирования инвентаря нужна база"
        local s1_sz = Dependencies.imgui.CalcTextSize(sub1)
        dl:AddText(Dependencies.imgui.ImVec2(p.x + (m_w - s1_sz.x) / 2, p.y + D(124)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_secondary), sub1)

        local sub2 = Dependencies.u8"предметов сервера. Нажмите «Скачать»."
        local s2_sz = Dependencies.imgui.CalcTextSize(sub2)
        dl:AddText(Dependencies.imgui.ImVec2(p.x + (m_w - s2_sz.x) / 2, p.y + D(148)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_secondary), sub2)

        local btn_h = Touch(52)
        local btn_w = (m_w - D(48)) / 2
        local btn_y = p.y + m_h - btn_h - D(16)

        if State.is_downloading_db then
            local wait_txt = Dependencies.u8"Загрузка..."
            local wt_sz = Dependencies.imgui.CalcTextSize(wait_txt)
            dl:AddText(Dependencies.imgui.ImVec2(p.x + (m_w - wt_sz.x) / 2, btn_y + (btn_h - wt_sz.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_hint), wait_txt)
        else
            Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(p.x + D(16), btn_y))
            if Dependencies.imgui.InvisibleButton("##dl_db_confirm", Dependencies.imgui.ImVec2(btn_w, btn_h)) then
                api_CheckAndDownloadItemsDB(true)
            end
            local dl_c = THEME.accent_success
            local dl_c_bg = Dependencies.imgui.IsItemActive() and Dependencies.imgui.ImVec4(dl_c.x * 0.8, dl_c.y * 0.8, dl_c.z * 0.8, 1) or dl_c
            dl:AddRectFilled(Dependencies.imgui.ImVec2(p.x + D(16), btn_y), Dependencies.imgui.ImVec2(p.x + D(16) + btn_w, btn_y + btn_h), Dependencies.imgui.ColorConvertFloat4ToU32(dl_c_bg), D(8))
            local lbl = Dependencies.u8"Скачать"
            local l_sz = Dependencies.imgui.CalcTextSize(lbl)
            dl:AddText(Dependencies.imgui.ImVec2(p.x + D(16) + (btn_w - l_sz.x) / 2, btn_y + (btn_h - l_sz.y) / 2), 0xFFFFFFFF, lbl)

            Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(p.x + D(32) + btn_w, btn_y))
            if Dependencies.imgui.InvisibleButton("##dl_db_cancel", Dependencies.imgui.ImVec2(btn_w, btn_h)) then
                State.show_db_modal = false
                State.pending_scan_after_db = false
            end
            local cancel_bg = Dependencies.imgui.IsItemActive() and THEME.bg_main or THEME.bg_tertiary
            dl:AddRectFilled(Dependencies.imgui.ImVec2(p.x + D(32) + btn_w, btn_y), Dependencies.imgui.ImVec2(p.x + D(32) + btn_w * 2, btn_y + btn_h), Dependencies.imgui.ColorConvertFloat4ToU32(cancel_bg), D(8))
            local clbl = Dependencies.u8"Отмена"
            local cl_sz = Dependencies.imgui.CalcTextSize(clbl)
            dl:AddText(Dependencies.imgui.ImVec2(p.x + D(32) + btn_w + (btn_w - cl_sz.x) / 2, btn_y + (btn_h - cl_sz.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), clbl)
        end

        Dependencies.imgui.PopFont()
    end
    Dependencies.imgui.End()
    Dependencies.imgui.PopStyleColor(2)
    Dependencies.imgui.PopStyleVar(3)
end

function drawUpdateButton(id, label, icon, bx, by, bw, color, btn_h, dl)
    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(bx, by))
    local clicked = false
    if Dependencies.imgui.InvisibleButton(id, Dependencies.imgui.ImVec2(bw, btn_h)) then clicked = true end
    local bg = Dependencies.imgui.IsItemActive() and Dependencies.imgui.ImVec4(color.x * 0.8, color.y * 0.8, color.z * 0.8, 1) or color
    dl:AddRectFilled(Dependencies.imgui.ImVec2(bx, by), Dependencies.imgui.ImVec2(bx + bw, by + btn_h), Dependencies.imgui.ColorConvertFloat4ToU32(bg), D(8))
    Dependencies.imgui.PushFont(UI.font_fa_large)
    local icon_size = Dependencies.imgui.CalcTextSize(icon)
    Dependencies.imgui.PopFont()
    local text_size = Dependencies.imgui.CalcTextSize(Dependencies.u8(label))
    local center_x = bx + (bw - (icon_size.x + D(12) + text_size.x)) / 2
    Dependencies.imgui.PushFont(UI.font_fa_large)
    dl:AddText(Dependencies.imgui.ImVec2(center_x, by + (btn_h - icon_size.y) / 2), 0xFFFFFFFF, icon)
    Dependencies.imgui.PopFont()
    dl:AddText(Dependencies.imgui.ImVec2(center_x + icon_size.x + D(12), by + (btn_h - text_size.y) / 2), 0xFFFFFFFF, Dependencies.u8(label))
    return clicked
end

function drawCenteredText(text, y, color, position, width)
    for line in text:gmatch("[^\r\n]+") do
        local text_size = Dependencies.imgui.CalcTextSize(line)
        Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(position.x + (width - text_size.x) / 2, y))
        Dependencies.imgui.TextColored(color, line)
        y = y + Dependencies.imgui.GetFontSize() + D(4)
    end
    return y
end

function drawModalButton(id, label, icon, button_x, button_y, button_w, color, button_h, dl)
    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(button_x, button_y))
    local clicked = false
    if Dependencies.imgui.InvisibleButton(id, Dependencies.imgui.ImVec2(button_w, button_h)) then clicked = true end
    local bg = Dependencies.imgui.IsItemActive() and Dependencies.imgui.ImVec4(color.x * 0.8, color.y * 0.8, color.z * 0.8, 1) or color
    dl:AddRectFilled(Dependencies.imgui.ImVec2(button_x, button_y), Dependencies.imgui.ImVec2(button_x + button_w, button_y + button_h), Dependencies.imgui.ColorConvertFloat4ToU32(bg), D(8))
    Dependencies.imgui.PushFont(UI.font_fa_large)
    local icon_size = Dependencies.imgui.CalcTextSize(icon)
    Dependencies.imgui.PopFont()
    Dependencies.imgui.PushFont(UI.font_main)
    local text_size = Dependencies.imgui.CalcTextSize(Dependencies.u8(label))
    local center_x = button_x + (button_w - (icon_size.x + D(12) + text_size.x)) / 2
    Dependencies.imgui.PushFont(UI.font_fa_large)
    dl:AddText(Dependencies.imgui.ImVec2(center_x, button_y + (button_h - icon_size.y) / 2), 0xFFFFFFFF, icon)
    Dependencies.imgui.PopFont()
    dl:AddText(Dependencies.imgui.ImVec2(center_x + icon_size.x + D(12), button_y + (button_h - text_size.y) / 2), 0xFFFFFFFF, Dependencies.u8(label))
    Dependencies.imgui.PopFont()
    return clicked
end

function drawNavigationTab(id, icon, y_offset, position, start_y, nav_w, tab_h, dl)
    local selected = UI.active_tab == id
    local tab_position = Dependencies.imgui.ImVec2(position.x, start_y + y_offset)
    Dependencies.imgui.SetCursorScreenPos(tab_position)
    if Dependencies.imgui.InvisibleButton("##tab_" .. id, Dependencies.imgui.ImVec2(nav_w, tab_h)) then
        UI.active_tab = id
        UI.active_sub_tab = 1
        if id == 4 and #StateMarket.shops_list == 0 then api_FetchMarketList() end
        if id == 7 and isTokenVerified() and isVerifiedVip() and #StateArbitrage.list == 0 then api_FetchArbitrage(true) end
    end
    local bg = selected and THEME.bg_tertiary or (Dependencies.imgui.IsItemActive() and Dependencies.imgui.ImVec4(THEME.bg_tertiary.x, THEME.bg_tertiary.y, THEME.bg_tertiary.z, 0.5) or Dependencies.imgui.ImVec4(0, 0, 0, 0))
    dl:AddRectFilled(tab_position, Dependencies.imgui.ImVec2(tab_position.x + nav_w, tab_position.y + tab_h), Dependencies.imgui.ColorConvertFloat4ToU32(bg))
    if selected then dl:AddRectFilled(tab_position, Dependencies.imgui.ImVec2(tab_position.x + D(4), tab_position.y + tab_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_primary)) end
    local color = selected and THEME.accent_primary or THEME.text_secondary
    Dependencies.imgui.PushFont(UI.font_fa_large)
    local icon_size = Dependencies.imgui.CalcTextSize(icon)
    dl:AddText(Dependencies.imgui.ImVec2(tab_position.x + (nav_w - icon_size.x) / 2, tab_position.y + (tab_h - icon_size.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(color), icon)
    Dependencies.imgui.PopFont()
end

function drawScrollZone(id, x, y, w, h, io, dl)
    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(x, y))
    Dependencies.imgui.InvisibleButton(id, Dependencies.imgui.ImVec2(w, h))
    local active = Dependencies.imgui.IsItemActive()
    local bg = active and Dependencies.imgui.ImVec4(THEME.accent_primary.x, THEME.accent_primary.y, THEME.accent_primary.z, 0.4) or Dependencies.imgui.ImVec4(THEME.bg_secondary.x, THEME.bg_secondary.y, THEME.bg_secondary.z, 0.8)
    dl:AddRectFilled(Dependencies.imgui.ImVec2(x, y), Dependencies.imgui.ImVec2(x + w, y + h), Dependencies.imgui.ColorConvertFloat4ToU32(bg), D(8))
    dl:AddRect(Dependencies.imgui.ImVec2(x, y), Dependencies.imgui.ImVec2(x + w, y + h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), D(8), 15, D(1.5))
    Dependencies.imgui.PushFont(UI.font_fa_large)
    local icon = Dependencies.fa('arrows_up_down')
    local icon_size = Dependencies.imgui.CalcTextSize(icon)
    dl:AddText(Dependencies.imgui.ImVec2(x + (w - icon_size.x) / 2, y + (h - icon_size.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(active and THEME.text_primary or THEME.text_secondary), icon)
    Dependencies.imgui.PopFont()
    return active and io.MouseDelta.y * 1.5 or 0
end

function CenterText(text, color, max_w)
    local text_size = Dependencies.imgui.CalcTextSize(text)
    Dependencies.imgui.SetCursorPosX((max_w - text_size.x) / 2)
    Dependencies.imgui.TextColored(color, text)
end

function drawInventorySegmentButton(id, label, icon, is_left, list_x, segment_y, half_w, segment_h, dl)
    local button_x = is_left and list_x or (list_x + half_w)
    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(button_x, segment_y))
    if Dependencies.imgui.InvisibleButton("##seg_" .. id, Dependencies.imgui.ImVec2(half_w, segment_h)) then UI.active_sub_tab = id end
    local selected = UI.active_sub_tab == id
    if selected then
        dl:AddRectFilled(Dependencies.imgui.ImVec2(button_x + D(6), segment_y + D(6)), Dependencies.imgui.ImVec2(button_x + half_w - D(6), segment_y + segment_h - D(6)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_tertiary), D(8))
        dl:AddRect(Dependencies.imgui.ImVec2(button_x + D(6), segment_y + D(6)), Dependencies.imgui.ImVec2(button_x + half_w - D(6), segment_y + segment_h - D(6)), Dependencies.imgui.ColorConvertFloat4ToU32(UI.active_tab == 1 and THEME.accent_success or THEME.accent_primary), D(8), 15, D(2))
    end
    Dependencies.imgui.PushFont(UI.font_fa_large)
    local icon_size = Dependencies.imgui.CalcTextSize(icon)
    Dependencies.imgui.PopFont()
    Dependencies.imgui.PushFont(UI.font_main)
    local text_size = Dependencies.imgui.CalcTextSize(Dependencies.u8(label))
    Dependencies.imgui.PopFont()
    local content_w = icon_size.x + D(14) + text_size.x
    local content_x = button_x + (half_w - content_w) / 2
    local color = selected and THEME.text_primary or THEME.text_secondary
    Dependencies.imgui.PushFont(UI.font_fa_large)
    dl:AddText(Dependencies.imgui.ImVec2(content_x, segment_y + (segment_h - icon_size.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(color), icon)
    Dependencies.imgui.PopFont()
    Dependencies.imgui.PushFont(UI.font_main)
    dl:AddText(Dependencies.imgui.ImVec2(content_x + icon_size.x + D(14), segment_y + (segment_h - text_size.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(color), Dependencies.u8(label))
    Dependencies.imgui.PopFont()
end

function drawLogStatCard(x, y, label, value, color, card_w, card_h, dl)
    dl:AddRectFilled(Dependencies.imgui.ImVec2(x, y), Dependencies.imgui.ImVec2(x + card_w, y + card_h), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(color.x, color.y, color.z, 0.16)), D(8))
    dl:AddRect(Dependencies.imgui.ImVec2(x, y), Dependencies.imgui.ImVec2(x + card_w, y + card_h), Dependencies.imgui.ColorConvertFloat4ToU32(color), D(8), 15, D(1.5))
    dl:AddText(Dependencies.imgui.ImVec2(x + D(16), y + D(14)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_secondary), Dependencies.u8(label))
    drawMoney(dl, x + D(16), y + D(48), value, THEME.text_primary)
end

function sortMarketplaceSearchResults(a, b)
    if a.shop.vip ~= b.shop.vip then return a.shop.vip end
    return (tonumber(a.item.price) or 0) < (tonumber(b.item.price) or 0)
end

function searchMarketplaceItems(query)
    local sell_results, buy_results = {}, {}
    local search_text = to_lower(query)
    local server_id = StateMarket.server_filter_idx > 0
        and UI.RODINA_SERVERS_DATA[StateMarket.server_filter_idx].id

    for _, shop in ipairs(StateMarket.shops_list) do
        if not server_id or shop.serverId == server_id then
            for _, item in ipairs(shop.sell_list) do
                if to_lower(item.name):find(search_text, 1, true) then
                    sell_results[#sell_results + 1] = { shop = shop, item = item, is_sell = true }
                end
            end
            for _, item in ipairs(shop.buy_list) do
                if to_lower(item.name):find(search_text, 1, true) then
                    buy_results[#buy_results + 1] = { shop = shop, item = item, is_sell = false }
                end
            end
        end
    end

    table.sort(sell_results, sortMarketplaceSearchResults)
    table.sort(buy_results, sortMarketplaceSearchResults)
    return sell_results, buy_results
end

function drawMarketSearchSegmentButton(id, label, is_left, position, half_w, segment_h, dl)
    local button_x = is_left and position.x or (position.x + half_w)
    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(button_x, position.y))
    if Dependencies.imgui.InvisibleButton("##mkt_seg_" .. id, Dependencies.imgui.ImVec2(half_w, segment_h)) then StateMarket.search_sub_tab = id end
    local selected = StateMarket.search_sub_tab == id
    if selected then
        dl:AddRectFilled(Dependencies.imgui.ImVec2(button_x + D(6), position.y + D(6)), Dependencies.imgui.ImVec2(button_x + half_w - D(6), position.y + segment_h - D(6)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_tertiary), D(8))
        dl:AddRect(Dependencies.imgui.ImVec2(button_x + D(6), position.y + D(6)), Dependencies.imgui.ImVec2(button_x + half_w - D(6), position.y + segment_h - D(6)), Dependencies.imgui.ColorConvertFloat4ToU32(id == 1 and THEME.accent_success or THEME.accent_primary), D(8), 15, D(2))
    end
    Dependencies.imgui.PushFont(UI.font_main)
    local text_size = Dependencies.imgui.CalcTextSize(Dependencies.u8(label))
    local color = selected and THEME.text_primary or THEME.text_secondary
    dl:AddText(Dependencies.imgui.ImVec2(button_x + (half_w - text_size.x) / 2, position.y + (segment_h - text_size.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(color), Dependencies.u8(label))
    Dependencies.imgui.PopFont()
end

function drawMarketSearchCard(res, idx, x, y, card_w, card_h, dl)
    local compact = card_w < D(760)
    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(x, y))
    if Dependencies.imgui.InvisibleButton("##mkt_item_" .. tostring(res.is_sell) .. "_" .. idx, Dependencies.imgui.ImVec2(card_w, card_h)) then
        StateMarket.selected_shop = res.shop
        UI.search_buf_market[0] = 0
        StateMarket.details_tab = res.is_sell and 1 or 2
    end
    local active = Dependencies.imgui.IsItemActive()
    local bg = active and THEME.bg_tertiary or THEME.bg_secondary
    dl:AddRectFilled(Dependencies.imgui.ImVec2(x, y), Dependencies.imgui.ImVec2(x + card_w, y + card_h), Dependencies.imgui.ColorConvertFloat4ToU32(bg), D(8))
    dl:AddRect(Dependencies.imgui.ImVec2(x, y), Dependencies.imgui.ImVec2(x + card_w, y + card_h), Dependencies.imgui.ColorConvertFloat4ToU32(res.shop.vip and Dependencies.imgui.ImVec4(1.0, 0.72, 0.20, 0.8) or THEME.border), D(8), 15, res.shop.vip and D(2) or D(1.5))
    local accent = res.is_sell and THEME.accent_success or THEME.accent_primary
    dl:AddRectFilled(Dependencies.imgui.ImVec2(x, y), Dependencies.imgui.ImVec2(x + D(6), y + card_h), Dependencies.imgui.ColorConvertFloat4ToU32(accent), D(8), 9)
    local gear_area_w = Touch(compact and 52 or 68)
    local gear_x = x + card_w - gear_area_w
    dl:AddRectFilled(Dependencies.imgui.ImVec2(gear_x, y), Dependencies.imgui.ImVec2(x + card_w, y + card_h), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(0, 0, 0, 0.1)), D(8), 6)
    dl:AddLine(Dependencies.imgui.ImVec2(gear_x, y), Dependencies.imgui.ImVec2(gear_x, y + card_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), D(1.5))
    Dependencies.imgui.PushFont(UI.font_fa_large)
    local gear_icon = Dependencies.fa('store')
    local gear_size = Dependencies.imgui.CalcTextSize(gear_icon)
    dl:AddText(Dependencies.imgui.ImVec2(gear_x + (gear_area_w - gear_size.x) / 2, y + (card_h - gear_size.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(active and THEME.text_primary or THEME.text_secondary), gear_icon)
    Dependencies.imgui.PopFont()
    local text_x = x + D(18)
    Dependencies.imgui.PushFont(UI.font_main)
    dl:PushClipRect(Dependencies.imgui.ImVec2(text_x, y), Dependencies.imgui.ImVec2(gear_x - 10, y + card_h), true)
    dl:AddText(Dependencies.imgui.ImVec2(text_x, y + D(compact and 8 or 16)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), Dependencies.u8(res.item.name))
    local shop_info = res.shop.nickname .. " | " .. getServerDisplayName(res.shop.serverId)
    local quantity = Dependencies.u8("| " .. tostring(math.floor(tonumber(res.item.amount) or 1)) .. " шт.")
    local quantity_size = Dependencies.imgui.CalcTextSize(quantity)
    if compact then
        local money_width = drawMoney(dl, text_x, y + D(34), res.item.price, accent)
        dl:AddText(Dependencies.imgui.ImVec2(text_x + money_width + D(6), y + D(34)), Dependencies.imgui.ColorConvertFloat4ToU32(accent), quantity)
        dl:AddText(Dependencies.imgui.ImVec2(text_x, y + D(62)), Dependencies.imgui.ColorConvertFloat4ToU32(res.shop.vip and Dependencies.imgui.ImVec4(1.0, 0.72, 0.20, 1.0) or THEME.text_secondary), Dependencies.u8(shop_info))
    else
        dl:AddText(Dependencies.imgui.ImVec2(text_x, y + D(44)), Dependencies.imgui.ColorConvertFloat4ToU32(res.shop.vip and Dependencies.imgui.ImVec4(1.0, 0.72, 0.20, 1.0) or THEME.text_secondary), Dependencies.u8(shop_info))
    end
    dl:PopClipRect()
    if not compact then
        local money_width = measureMoney(res.item.price)
        local price_width = money_width + quantity_size.x + D(6)
        local price_x = gear_x - price_width - D(12)
        local price_y = y + (card_h - Dependencies.imgui.GetFontSize()) / 2
        local actual_money_width = drawMoney(dl, price_x, price_y, res.item.price, accent)
        dl:AddText(Dependencies.imgui.ImVec2(price_x + actual_money_width + D(6), price_y), Dependencies.imgui.ColorConvertFloat4ToU32(accent), quantity)
    end
    Dependencies.imgui.PopFont()
end

function renderArbitrageTab(list_x, list_w, content_y, content_h, scroll_w, current_search_str, io, dl)
    if not isTokenVerified() then
        local w_av = list_w
        local h_av = content_h - D(32)
        Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(list_x, content_y + D(16)))
        Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ChildBg, THEME.bg_secondary)
        if Dependencies.imgui.BeginChild("ArbNoKey", Dependencies.imgui.ImVec2(w_av, h_av), true) then
            local avail_w = Dependencies.imgui.GetContentRegionAvail().x
            local avail_h = Dependencies.imgui.GetContentRegionAvail().y
            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, math.max(D(24), avail_h / 2 - D(72))))
            if UI.font_fa then
                Dependencies.imgui.PushFont(UI.font_fa_large or UI.font_fa)
                local icon = Dependencies.fa('key')
                local isz = Dependencies.imgui.CalcTextSize(icon)
                Dependencies.imgui.SetCursorPosX((avail_w - isz.x) / 2)
                Dependencies.imgui.TextColored(THEME.accent_primary, icon)
                Dependencies.imgui.PopFont()
            end
            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(8)))
            local t1 = Dependencies.u8"Требуется привязка ключа"
            Dependencies.imgui.SetCursorPosX((avail_w - Dependencies.imgui.CalcTextSize(t1).x) / 2)
            Dependencies.imgui.TextColored(THEME.text_primary, t1)
            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(16)))
            local bw = math.min(Touch(200), avail_w - D(32))
            local bh = Touch(52)
            Dependencies.imgui.SetCursorPosX((avail_w - bw) / 2)
            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Button, THEME.accent_primary)
            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ButtonHovered, THEME.accent_primary)
            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ButtonActive, THEME.accent_primary)
            if Dependencies.imgui.Button(Dependencies.u8"Ввести ключ", Dependencies.imgui.ImVec2(bw, bh)) then
                UI.active_tab = 6
            end
            Dependencies.imgui.PopStyleColor(3)
        end
        Dependencies.imgui.EndChild()
        Dependencies.imgui.PopStyleColor()
        return
    end

    if not isVerifiedVip() then
        local w_av = list_w
        local h_av = content_h - D(32)
        Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(list_x, content_y + D(16)))
        Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ChildBg, THEME.bg_secondary)
        if Dependencies.imgui.BeginChild("ArbNoVip", Dependencies.imgui.ImVec2(w_av, h_av), true) then
            local avail_w = Dependencies.imgui.GetContentRegionAvail().x
            local avail_h = Dependencies.imgui.GetContentRegionAvail().y
            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, math.max(D(24), avail_h / 2 - D(78))))
            if UI.font_fa then
                Dependencies.imgui.PushFont(UI.font_fa_large or UI.font_fa)
                local icon = Dependencies.fa('crown')
                local isz = Dependencies.imgui.CalcTextSize(icon)
                Dependencies.imgui.SetCursorPosX((avail_w - isz.x) / 2)
                Dependencies.imgui.TextColored(Dependencies.imgui.ImVec4(1.0, 0.84, 0.0, 1.0), icon)
                Dependencies.imgui.PopFont()
            end
            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(8)))
            local t1 = Dependencies.u8"Доступно только с VIP статусом"
            Dependencies.imgui.SetCursorPosX((avail_w - Dependencies.imgui.CalcTextSize(t1).x) / 2)
            Dependencies.imgui.TextColored(THEME.text_primary, t1)
            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(6)))
            local t2 = Dependencies.u8"Оформите VIP в боте @rdnMarket_bot для доступа к Арбитражу."
            Dependencies.imgui.SetCursorPosX((avail_w - Dependencies.imgui.CalcTextSize(t2).x) / 2)
            Dependencies.imgui.TextColored(THEME.text_secondary, t2)
            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(16)))
            local bw = math.min(Touch(220), avail_w - D(32))
            local bh = Touch(52)
            Dependencies.imgui.SetCursorPosX((avail_w - bw) / 2)
            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Button, Dependencies.imgui.ImVec4(0.85, 0.65, 0.10, 1.0))
            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ButtonHovered, Dependencies.imgui.ImVec4(0.95, 0.75, 0.20, 1.0))
            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ButtonActive, Dependencies.imgui.ImVec4(0.75, 0.55, 0.05, 1.0))
            if Dependencies.imgui.Button(Dependencies.u8"Скопировать ссылку на бота", Dependencies.imgui.ImVec2(bw, bh)) then
                pcall(setClipboardText, "https://t.me/rdnMarket_bot")
                sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Ссылка на бота скопирована: https://t.me/rdnMarket_bot", -1)
            end
            Dependencies.imgui.PopStyleColor(3)
        end
        Dependencies.imgui.EndChild()
        Dependencies.imgui.PopStyleColor()
        return
    end

    if isItemDbEmpty() and UI.caches_loaded then
        local w_av = list_w
        local h_av = content_h - D(32)
        Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(list_x, content_y + D(16)))
        Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ChildBg, THEME.bg_secondary)
        if Dependencies.imgui.BeginChild("ArbNoDB", Dependencies.imgui.ImVec2(w_av, h_av), true) then
            local avail_w = Dependencies.imgui.GetContentRegionAvail().x
            local avail_h = Dependencies.imgui.GetContentRegionAvail().y
            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, math.max(D(24), avail_h / 2 - D(78))))
            if UI.font_fa then
                Dependencies.imgui.PushFont(UI.font_fa_large or UI.font_fa)
                local icon = Dependencies.fa('cloud_arrow_down')
                local isz = Dependencies.imgui.CalcTextSize(icon)
                Dependencies.imgui.SetCursorPosX((avail_w - isz.x) / 2)
                Dependencies.imgui.TextColored(THEME.accent_primary, icon)
                Dependencies.imgui.PopFont()
            end
            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(8)))
            local t1 = Dependencies.u8"База предметов не скачана"
            Dependencies.imgui.SetCursorPosX((avail_w - Dependencies.imgui.CalcTextSize(t1).x) / 2)
            Dependencies.imgui.TextColored(THEME.text_primary, t1)
            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(16)))
            if not State.is_downloading_db then
                local bw = math.min(Touch(220), avail_w - D(32))
                local bh = Touch(52)
                Dependencies.imgui.SetCursorPosX((avail_w - bw) / 2)
                Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Button, THEME.accent_success)
                Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ButtonHovered, THEME.accent_success)
                Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ButtonActive, THEME.accent_success)
                if Dependencies.imgui.Button(Dependencies.u8"Скачать базу предметов", Dependencies.imgui.ImVec2(bw, bh)) then
                    api_CheckAndDownloadItemsDB(true)
                end
                Dependencies.imgui.PopStyleColor(3)
            end
        end
        Dependencies.imgui.EndChild()
        Dependencies.imgui.PopStyleColor()
        return
    end

    local filtered_arbs = {}
    for _, arb in ipairs(StateArbitrage.list) do
        if not isArbitrageBlacklisted(arb.name) then
            local match = (current_search_str == "")
                or to_lower(arb.name):find(current_search_str, 1, true)
                or to_lower(arb.seller_nick):find(current_search_str, 1, true)
                or to_lower(arb.buyer_nick):find(current_search_str, 1, true)
            if match then
                filtered_arbs[#filtered_arbs + 1] = arb
            end
        end
    end

    local seg_w = list_w
    local seg_h = Touch(56)
    local seg_y = content_y + D(14)
    local half_w = seg_w / 2
    dl:AddRectFilled(Dependencies.imgui.ImVec2(list_x, seg_y), Dependencies.imgui.ImVec2(list_x + seg_w, seg_y + seg_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), D(8))
    dl:AddRect(Dependencies.imgui.ImVec2(list_x, seg_y), Dependencies.imgui.ImVec2(list_x + seg_w, seg_y + seg_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), D(8), 15, D(1.5))

    local function drawArbSeg(id, label, icon, is_left)
        local bx = is_left and list_x or (list_x + half_w)
        Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(bx, seg_y))
        if Dependencies.imgui.InvisibleButton("##arb_seg_" .. id, Dependencies.imgui.ImVec2(half_w, seg_h)) then
            StateArbitrage.sub_tab = id
        end
        local sel = StateArbitrage.sub_tab == id
        if sel then
            dl:AddRectFilled(Dependencies.imgui.ImVec2(bx + D(6), seg_y + D(6)), Dependencies.imgui.ImVec2(bx + half_w - D(6), seg_y + seg_h - D(6)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_tertiary), D(8))
            dl:AddRect(Dependencies.imgui.ImVec2(bx + D(6), seg_y + D(6)), Dependencies.imgui.ImVec2(bx + half_w - D(6), seg_y + seg_h - D(6)), Dependencies.imgui.ColorConvertFloat4ToU32(id == 1 and THEME.accent_success or THEME.accent_danger), D(8), 15, D(2))
        end
        Dependencies.imgui.PushFont(UI.font_fa)
        local isz = Dependencies.imgui.CalcTextSize(icon)
        Dependencies.imgui.PopFont()
        Dependencies.imgui.PushFont(UI.font_main)
        local tsz = Dependencies.imgui.CalcTextSize(Dependencies.u8(label))
        Dependencies.imgui.PopFont()
        local cw = isz.x + D(8) + tsz.x
        local cx = bx + (half_w - cw) / 2
        local col = sel and THEME.text_primary or THEME.text_secondary
        Dependencies.imgui.PushFont(UI.font_fa)
        dl:AddText(Dependencies.imgui.ImVec2(cx, seg_y + (seg_h - isz.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(col), icon)
        Dependencies.imgui.PopFont()
        Dependencies.imgui.PushFont(UI.font_main)
        dl:AddText(Dependencies.imgui.ImVec2(cx + isz.x + D(8), seg_y + (seg_h - tsz.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(col), Dependencies.u8(label))
        Dependencies.imgui.PopFont()
    end

    drawArbSeg(1, "СВЯЗКИ (" .. #filtered_arbs .. ")", Dependencies.fa('scale_balanced'), true)
    drawArbSeg(2, "ИСКЛЮЧЕНИЯ (" .. #StateArbitrage.blacklist .. ")", Dependencies.fa('ban'), false)

    local ctrl_y = seg_y + seg_h + D(10)
    local ctrl_h = Touch(46)
    local ctrl_gap = D(10)
    local ctrl_w = (list_w - ctrl_gap) / 2

    local sort_labels = { "Сорт: Профит", "Сорт: ROI %", "Сорт: Кол-во" }
    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(list_x, ctrl_y))
    if DrawStyledButton("##arb_sort_btn", Dependencies.u8(sort_labels[StateArbitrage.sort_mode] or "Сорт: Профит"), ctrl_w, ctrl_h, THEME.bg_secondary, Dependencies.fa('arrow_down_wide_short'), dl) then
        StateArbitrage.sort_mode = (StateArbitrage.sort_mode % 3) + 1
        api_FetchArbitrage(true)
    end

    local tax_steps = { 0, 1, 3, 4, 8 }
    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(list_x + ctrl_w + ctrl_gap, ctrl_y))
    if DrawStyledButton("##arb_tax_btn", Dependencies.u8("Комиссия: " .. tostring(StateArbitrage.tax_pct) .. "%"), ctrl_w, ctrl_h, THEME.bg_secondary, Dependencies.fa('percent'), dl) then
        local next_tax = tax_steps[1]
        for idx, val in ipairs(tax_steps) do
            if val == StateArbitrage.tax_pct then
                next_tax = tax_steps[(idx % #tax_steps) + 1]
                break
            end
        end
        StateArbitrage.tax_pct = next_tax
        api_FetchArbitrage(true)
    end

    local arb_list_y = ctrl_y + ctrl_h + D(12)
    local arb_list_h = content_h - (seg_h + ctrl_h + D(46))
    local a_delta = drawScrollZone("##scroll_arb", list_x + list_w + D(10), arb_list_y, scroll_w, arb_list_h, io, dl)

    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(list_x, arb_list_y))
    Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ChildBg, Dependencies.imgui.ImVec4(0, 0, 0, 0))
    if Dependencies.imgui.BeginChild("ArbitrageChild", Dependencies.imgui.ImVec2(list_w, arb_list_h), false, Dependencies.imgui.WindowFlags.NoScrollbar) then
        local c_pos = Dependencies.imgui.GetWindowPos()
        local c_size = Dependencies.imgui.GetWindowSize()
        dl:PushClipRect(c_pos, Dependencies.imgui.ImVec2(c_pos.x + c_size.x, c_pos.y + c_size.y), true)
        if a_delta ~= 0 then Dependencies.imgui.SetScrollY(Dependencies.imgui.GetScrollY() - a_delta) end
        Dependencies.imgui.PushFont(UI.font_main)

        if StateArbitrage.sub_tab == 2 then
            if #StateArbitrage.blacklist == 0 then
                Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(50)))
                CenterText(Dependencies.u8"Список исключений пуст.", THEME.text_secondary, list_w)
            else
                local card_h = D(78)
                local spacing = D(10)
                local clipper = Dependencies.imgui.ImGuiListClipper(#StateArbitrage.blacklist)
                while clipper:Step() do
                    for i = clipper.DisplayStart + 1, clipper.DisplayEnd do
                        local b_name = StateArbitrage.blacklist[i]
                        local cp = Dependencies.imgui.GetCursorScreenPos()
                        dl:AddRectFilled(cp, Dependencies.imgui.ImVec2(cp.x + list_w, cp.y + card_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), D(8))
                        dl:AddRectFilled(cp, Dependencies.imgui.ImVec2(cp.x + D(6), cp.y + card_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_danger), D(8), 9)
                        local btn_w = Touch(120)
                        local btn_h = Touch(46)
                        local bx = cp.x + list_w - btn_w - D(12)
                        local by = cp.y + (card_h - btn_h) / 2
                        dl:PushClipRect(Dependencies.imgui.ImVec2(cp.x + D(18), cp.y), Dependencies.imgui.ImVec2(bx - D(10), cp.y + card_h), true)
                        dl:AddText(Dependencies.imgui.ImVec2(cp.x + D(18), cp.y + (card_h - Dependencies.imgui.GetFontSize()) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), Dependencies.u8(b_name))
                        dl:PopClipRect()
                        Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(bx, by))
                        if DrawStyledButton("##arb_restore_" .. i, Dependencies.u8"ВЕРНУТЬ", btn_w, btn_h, THEME.accent_success, nil, dl) then
                            table.remove(StateArbitrage.blacklist, i)
                            saveJsonFile(UI.PATH_ARB_BLACKLIST, StateArbitrage.blacklist)
                        end
                        Dependencies.imgui.SetCursorScreenPos(cp)
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(list_w, card_h + spacing))
                    end
                end
            end
        elseif StateArbitrage.is_loading then
            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(50)))
            CenterText(Dependencies.u8"Загрузка арбитражных связок с сервера...", THEME.accent_primary, list_w)
        elseif #filtered_arbs == 0 then
            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(50)))
            CenterText(Dependencies.u8"Подходящих связок не найдено. Нажмите ОБНОВИТЬ внизу.", THEME.text_secondary, list_w)
        else
            local card_h = D(224)
            local spacing = D(14)
            local start_p = Dependencies.imgui.GetCursorScreenPos()
            local pad = D(14)
            local compact_card = list_w < D(460)
            local clipper = Dependencies.imgui.ImGuiListClipper(#filtered_arbs)
            while clipper:Step() do
                for i = clipper.DisplayStart + 1, clipper.DisplayEnd do
                    local arb = filtered_arbs[i]
                    local cy = start_p.y + (i - 1) * (card_h + spacing)
                    local cx = start_p.x
                    local inner_x = cx + D(18)
                    local inner_w = list_w - D(18) - pad

                    dl:AddRectFilled(Dependencies.imgui.ImVec2(cx, cy), Dependencies.imgui.ImVec2(cx + list_w, cy + card_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), D(10))
                    dl:AddRect(Dependencies.imgui.ImVec2(cx, cy), Dependencies.imgui.ImVec2(cx + list_w, cy + card_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), D(10), 15, D(1.5))
                    dl:AddRectFilled(Dependencies.imgui.ImVec2(cx, cy), Dependencies.imgui.ImVec2(cx + D(6), cy + card_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_success), D(10), 9)

                    local ban_sz = D(40)
                    local ban_x = cx + list_w - ban_sz - pad
                    local ban_y = cy + D(12)
                    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(ban_x, ban_y))
                    if Dependencies.imgui.InvisibleButton("##arb_ban_" .. i, Dependencies.imgui.ImVec2(ban_sz, ban_sz)) then
                        local clean_b = cleanItemName(stripItemMetadata(arb.name or ""))
                        local exists = false
                        for _, v in ipairs(StateArbitrage.blacklist) do
                            if v == clean_b then exists = true break end
                        end
                        if not exists and clean_b ~= "" then
                            table.insert(StateArbitrage.blacklist, clean_b)
                            saveJsonFile(UI.PATH_ARB_BLACKLIST, StateArbitrage.blacklist)
                            sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Товар скрыт из арбитража: " .. clean_b, -1)
                        end
                    end
                    local ban_bg = Dependencies.imgui.IsItemActive() and THEME.accent_danger or THEME.bg_tertiary
                    dl:AddRectFilled(Dependencies.imgui.ImVec2(ban_x, ban_y), Dependencies.imgui.ImVec2(ban_x + ban_sz, ban_y + ban_sz), Dependencies.imgui.ColorConvertFloat4ToU32(ban_bg), D(8))
                    Dependencies.imgui.PushFont(UI.font_fa)
                    local b_ic = Dependencies.fa('ban')
                    local b_isz = Dependencies.imgui.CalcTextSize(b_ic)
                    dl:AddText(Dependencies.imgui.ImVec2(ban_x + (ban_sz - b_isz.x) / 2, ban_y + (ban_sz - b_isz.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_danger), b_ic)
                    Dependencies.imgui.PopFont()

                    dl:PushClipRect(Dependencies.imgui.ImVec2(inner_x, cy + D(10)), Dependencies.imgui.ImVec2(ban_x - D(10), cy + D(40)), true)
                    dl:AddText(Dependencies.imgui.ImVec2(inner_x, cy + D(14)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), Dependencies.u8(arb.name))
                    dl:PopClipRect()

                    local prof_y = cy + D(46)
                    local prof_lbl = Dependencies.u8("Чистая прибыль: +")
                    local prof_lbl_w = Dependencies.imgui.CalcTextSize(prof_lbl).x
                    local roi_txt = Dependencies.u8(string.format("+%.1f%% ROI", arb.roi))
                    local roi_sz = Dependencies.imgui.CalcTextSize(roi_txt)
                    local roi_pad_x = D(10)
                    local roi_w = roi_sz.x + roi_pad_x * 2
                    local roi_h = D(24)
                    local roi_x = ban_x - roi_w - D(10)
                    dl:AddRectFilled(Dependencies.imgui.ImVec2(roi_x, prof_y - D(2)), Dependencies.imgui.ImVec2(roi_x + roi_w, prof_y - D(2) + roi_h), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(1.0, 0.72, 0.15, 0.16)), D(6))
                    dl:AddText(Dependencies.imgui.ImVec2(roi_x + roi_pad_x, prof_y), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(1.0, 0.78, 0.20, 1.0)), roi_txt)

                    dl:PushClipRect(Dependencies.imgui.ImVec2(inner_x, prof_y - D(2)), Dependencies.imgui.ImVec2(roi_x - D(8), prof_y + D(26)), true)
                    dl:AddText(Dependencies.imgui.ImVec2(inner_x, prof_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_success), prof_lbl)
                    drawMoney(dl, inner_x + prof_lbl_w, prof_y, arb.total_profit, THEME.accent_success)
                    dl:PopClipRect()

                    local sub_y = cy + D(74)
                    local sub_txt = Dependencies.u8(string.format("С 1 шт: +%s   |   Лимит: %d шт.   |   Комиссия: %d%%", formatMoney(arb.profit_one), arb.max_qty, arb.tax_pct or StateArbitrage.tax_pct))
                    dl:PushClipRect(Dependencies.imgui.ImVec2(inner_x, sub_y), Dependencies.imgui.ImVec2(cx + list_w - pad, sub_y + D(24)), true)
                    dl:AddText(Dependencies.imgui.ImVec2(inner_x, sub_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_secondary), sub_txt)
                    dl:PopClipRect()

                    local row_h = D(52)
                    local gps_w = D(compact_card and 112 or 136)
                    local gps_h = D(40)
                    local badge_w = D(compact_card and 74 or 86)
                    local badge_h = D(26)

                    local r1_y = cy + D(104)
                    dl:AddRectFilled(Dependencies.imgui.ImVec2(inner_x, r1_y), Dependencies.imgui.ImVec2(inner_x + inner_w, r1_y + row_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_main), D(8))
                    dl:AddRect(Dependencies.imgui.ImVec2(inner_x, r1_y), Dependencies.imgui.ImVec2(inner_x + inner_w, r1_y + row_h), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(THEME.accent_success.x, THEME.accent_success.y, THEME.accent_success.z, 0.35)), D(8), 15, D(1.2))

                    local b1_x = inner_x + D(8)
                    local b1_y = r1_y + (row_h - badge_h) / 2
                    dl:AddRectFilled(Dependencies.imgui.ImVec2(b1_x, b1_y), Dependencies.imgui.ImVec2(b1_x + badge_w, b1_y + badge_h), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(THEME.accent_success.x, THEME.accent_success.y, THEME.accent_success.z, 0.16)), D(6))
                    local tag1 = Dependencies.u8"КУПИТЬ"
                    local tag1_sz = Dependencies.imgui.CalcTextSize(tag1)
                    dl:AddText(Dependencies.imgui.ImVec2(b1_x + (badge_w - tag1_sz.x) / 2, b1_y + (badge_h - tag1_sz.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_success), tag1)

                    local gps1_x = inner_x + inner_w - gps_w - D(6)
                    local gps1_y = r1_y + (row_h - gps_h) / 2
                    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(gps1_x, gps1_y))
                    if DrawStyledButton("##arb_gps_s_" .. i, Dependencies.u8"ПРОДАВЕЦ", gps_w, gps_h, Dependencies.imgui.ImVec4(0.14, 0.36, 0.24, 1.0), Dependencies.fa('location_dot'), dl) then
                        StateMarket.gps_active = true
                        StateMarket.gps_target = arb.seller_nick:gsub(" ", "_")
                        Tasks.add("gps_timeout", function()
                            StateMarket.gps_active = false
                            StateMarket.gps_target = nil
                        end, 6000)
                        sampSendChat("/id " .. StateMarket.gps_target)
                        sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Поиск лавки продавца " .. StateMarket.gps_target .. "...", -1)
                    end

                    local s_info_x = b1_x + badge_w + D(10)
                    local s_txt = Dependencies.u8(string.format("%s  —  %s", arb.seller_nick, formatMoney(arb.buy_from_price)))
                    dl:PushClipRect(Dependencies.imgui.ImVec2(s_info_x, r1_y), Dependencies.imgui.ImVec2(gps1_x - D(8), r1_y + row_h), true)
                    dl:AddText(Dependencies.imgui.ImVec2(s_info_x, r1_y + (row_h - Dependencies.imgui.GetFontSize()) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), s_txt)
                    dl:PopClipRect()

                    local r2_y = r1_y + row_h + D(10)
                    dl:AddRectFilled(Dependencies.imgui.ImVec2(inner_x, r2_y), Dependencies.imgui.ImVec2(inner_x + inner_w, r2_y + row_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_main), D(8))
                    dl:AddRect(Dependencies.imgui.ImVec2(inner_x, r2_y), Dependencies.imgui.ImVec2(inner_x + inner_w, r2_y + row_h), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(THEME.accent_primary.x, THEME.accent_primary.y, THEME.accent_primary.z, 0.35)), D(8), 15, D(1.2))

                    local b2_x = inner_x + D(8)
                    local b2_y = r2_y + (row_h - badge_h) / 2
                    dl:AddRectFilled(Dependencies.imgui.ImVec2(b2_x, b2_y), Dependencies.imgui.ImVec2(b2_x + badge_w, b2_y + badge_h), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(THEME.accent_primary.x, THEME.accent_primary.y, THEME.accent_primary.z, 0.16)), D(6))
                    local tag2 = Dependencies.u8"СДАТЬ"
                    local tag2_sz = Dependencies.imgui.CalcTextSize(tag2)
                    dl:AddText(Dependencies.imgui.ImVec2(b2_x + (badge_w - tag2_sz.x) / 2, b2_y + (badge_h - tag2_sz.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_primary), tag2)

                    local gps2_x = inner_x + inner_w - gps_w - D(6)
                    local gps2_y = r2_y + (row_h - gps_h) / 2
                    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(gps2_x, gps2_y))
                    if DrawStyledButton("##arb_gps_b_" .. i, Dependencies.u8"СКУПЩИК", gps_w, gps_h, Dependencies.imgui.ImVec4(0.10, 0.34, 0.38, 1.0), Dependencies.fa('location_dot'), dl) then
                        StateMarket.gps_active = true
                        StateMarket.gps_target = arb.buyer_nick:gsub(" ", "_")
                        Tasks.add("gps_timeout", function()
                            StateMarket.gps_active = false
                            StateMarket.gps_target = nil
                        end, 6000)
                        sampSendChat("/id " .. StateMarket.gps_target)
                        sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Поиск лавки скупщика " .. StateMarket.gps_target .. "...", -1)
                    end

                    local b_info_x = b2_x + badge_w + D(10)
                    local b_txt = Dependencies.u8(string.format("%s  —  %s (на руки %s)", arb.buyer_nick, formatMoney(arb.sell_to_price), formatMoney(arb.net_received)))
                    dl:PushClipRect(Dependencies.imgui.ImVec2(b_info_x, r2_y), Dependencies.imgui.ImVec2(gps2_x - D(8), r2_y + row_h), true)
                    dl:AddText(Dependencies.imgui.ImVec2(b_info_x, r2_y + (row_h - Dependencies.imgui.GetFontSize()) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), b_txt)
                    dl:PopClipRect()
                end
            end
            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, #filtered_arbs * (card_h + spacing) + D(12)))
        end
        Dependencies.imgui.PopFont()
        dl:PopClipRect()
    end
    Dependencies.imgui.EndChild()
    Dependencies.imgui.PopStyleColor()
end

function Interface()
    updateResponsiveUi()
        pcall(renderLiveProfitHUD)
        pcall(renderUndoSnackbar)
        
        if UI.show_update_window[0] then
            local sw, sh = getScreenResolution()
            local m_w = math.min(sw - D(32), D(480))
            
            Dependencies.imgui.SetNextWindowPos(Dependencies.imgui.ImVec2(sw / 2, sh / 2), Dependencies.imgui.Cond.Always, Dependencies.imgui.ImVec2(0.5, 0.5))
            Dependencies.imgui.SetNextWindowSize(Dependencies.imgui.ImVec2(m_w, -1), Dependencies.imgui.Cond.Always)
            
            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.WindowBg, THEME.bg_secondary)
            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Border, THEME.accent_primary)
            Dependencies.imgui.PushStyleVarFloat(Dependencies.imgui.StyleVar.WindowRounding, 24.0)
            Dependencies.imgui.PushStyleVarFloat(Dependencies.imgui.StyleVar.WindowBorderSize, 3.0)
            Dependencies.imgui.PushStyleVarVec2(Dependencies.imgui.StyleVar.WindowPadding, Dependencies.imgui.ImVec2(0, 0))
            local update_modal_flags = Dependencies.imgui.WindowFlags.NoTitleBar + Dependencies.imgui.WindowFlags.NoResize
                + Dependencies.imgui.WindowFlags.NoMove + Dependencies.imgui.WindowFlags.AlwaysAutoResize
                + Dependencies.imgui.WindowFlags.NoScrollbar + Dependencies.imgui.WindowFlags.NoScrollWithMouse
            if Dependencies.imgui.Begin("##UpdateModal", UI.show_update_window, update_modal_flags) then
                local p = Dependencies.imgui.GetCursorScreenPos()
                local dl = Dependencies.imgui.GetWindowDrawList()
                
                local cur_y = p.y + D(24)
                
                Dependencies.imgui.PushFont(UI.font_fa_large)
                local brand_ic = Dependencies.fa('store')
                local ic_sz = Dependencies.imgui.CalcTextSize(brand_ic)
                Dependencies.imgui.PopFont()
                
                Dependencies.imgui.PushFont(UI.font_main)
                local brand_txt = " RMARKET"
                local txt_sz = Dependencies.imgui.CalcTextSize(brand_txt)
                
                local total_brand_w = ic_sz.x + txt_sz.x
                local brand_x = p.x + (m_w - total_brand_w) / 2
                
                Dependencies.imgui.PushFont(UI.font_fa_large)
                dl:AddText(Dependencies.imgui.ImVec2(brand_x, cur_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_primary), brand_ic)
                Dependencies.imgui.PopFont()
                dl:AddText(Dependencies.imgui.ImVec2(brand_x + ic_sz.x, cur_y + (ic_sz.y - txt_sz.y)/2), 0xFFFFFFFF, brand_txt)
                
                cur_y = cur_y + ic_sz.y + D(18)
                dl:AddLine(Dependencies.imgui.ImVec2(p.x, cur_y), Dependencies.imgui.ImVec2(p.x + m_w, cur_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), D(1.5))
                
                cur_y = cur_y + D(18)
                
                local t_str = Dependencies.u8"ДОСТУПНО ОБНОВЛЕНИЕ"
                local t_sz = Dependencies.imgui.CalcTextSize(t_str)
                dl:AddText(Dependencies.imgui.ImVec2(p.x + (m_w - t_sz.x)/2, cur_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), t_str)
                
                cur_y = cur_y + t_sz.y + 8
                
                local v_str = Dependencies.u8"Новая версия: " .. State.update.version
                local v_sz = Dependencies.imgui.CalcTextSize(v_str)
                dl:AddText(Dependencies.imgui.ImVec2(p.x + (m_w - v_sz.x)/2, cur_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_success), v_str)
                
                cur_y = cur_y + v_sz.y + D(28)
                
                Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, cur_y - p.y))
                
                local btn_y = Dependencies.imgui.GetCursorScreenPos().y
                local btn_w = (m_w - D(48)) / 2
                local btn_h = Touch(54)
                
                if drawUpdateButton("##btn_upd_later", "ПОЗЖЕ", Dependencies.fa('clock'), p.x + D(16), btn_y, btn_w, THEME.bg_tertiary, btn_h, dl) then
                    UI.show_update_window[0] = false
                end
                
                if drawUpdateButton("##btn_upd_now", "ОБНОВИТЬ", Dependencies.fa('download'), p.x + D(32) + btn_w, btn_y, btn_w, THEME.accent_success, btn_h, dl) then
                    UI.show_update_window[0] = false
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
                
                Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, btn_h + D(10)))
                Dependencies.imgui.PopFont()
            end
            Dependencies.imgui.End()
            Dependencies.imgui.PopStyleVar(3)
            Dependencies.imgui.PopStyleColor(2)
        end
        
        local io = Dependencies.imgui.GetIO()
        local sw, sh = getScreenResolution()
        
        local btn_w = math.min(sw - D(24), Touch(280))
        local btn_h = Touch(64)
        local padding = D(12)
        local win_w, win_h = btn_w + padding * 2, btn_h + padding * 2
        
        if Settings.rm_btn_x == nil then Settings.rm_btn_x = sw - win_w - 10 end
        if Settings.rm_btn_y == nil then Settings.rm_btn_y = sh / 2 - win_h / 2 end
        Settings.rm_btn_x = math.max(0, math.min(Settings.rm_btn_x, sw - win_w))
        Settings.rm_btn_y = math.max(0, math.min(Settings.rm_btn_y, sh - win_h))
        
        if Settings.show_float_btn then
            Dependencies.imgui.SetNextWindowPos(Dependencies.imgui.ImVec2(Settings.rm_btn_x, Settings.rm_btn_y), Dependencies.imgui.Cond.Always)
            Dependencies.imgui.SetNextWindowSize(Dependencies.imgui.ImVec2(win_w, win_h), Dependencies.imgui.Cond.Always)
            
            Dependencies.imgui.PushStyleVarFloat(Dependencies.imgui.StyleVar.WindowRounding, btn_h / 2)
            Dependencies.imgui.PushStyleVarVec2(Dependencies.imgui.StyleVar.WindowPadding, Dependencies.imgui.ImVec2(0, 0))
            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.WindowBg, Dependencies.imgui.ImVec4(0,0,0,0))
            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Border, Dependencies.imgui.ImVec4(0,0,0,0))
            Dependencies.imgui.PushStyleVarFloat(Dependencies.imgui.StyleVar.WindowBorderSize, 0.0)
            
            if Dependencies.imgui.Begin("##RMFloatingBtn", nil, Dependencies.imgui.WindowFlags.NoTitleBar + Dependencies.imgui.WindowFlags.NoResize + Dependencies.imgui.WindowFlags.NoSavedSettings + Dependencies.imgui.WindowFlags.NoBackground) then
                local dl = Dependencies.imgui.GetWindowDrawList()
                local p = Dependencies.imgui.GetWindowPos()
                
                local c_x_start = p.x + padding
                local c_y_start = p.y + padding
                
                Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(c_x_start, c_y_start))
                local clicked = Dependencies.imgui.InvisibleButton("##rm_float_click", Dependencies.imgui.ImVec2(btn_w, btn_h))
                
                local is_active = Dependencies.imgui.IsItemActive()
                local is_hov = Dependencies.imgui.IsItemHovered()
                
                if is_active and Dependencies.imgui.IsMouseDragging(0, -1.0) then
                    UI.float_btn_dragged = true
					local delta = Dependencies.imgui.GetMouseDragDelta(0, -1.0)
					Settings.rm_btn_x = Settings.rm_btn_x + delta.x
					Settings.rm_btn_y = Settings.rm_btn_y + delta.y
					Dependencies.imgui.ResetMouseDragDelta(0)
					saveJsonFile(UI.PATH_SETTINGS, Settings)
				end
                if clicked then
                    if not UI.float_btn_dragged then UI.win_state[0] = not UI.win_state[0] end
                    UI.float_btn_dragged = false
                elseif Dependencies.imgui.IsMouseReleased(0) then
                    UI.float_btn_dragged = false
                end
                
                local r = btn_h / 2
                local scale = is_active and 0.95 or 1.0
                local dw = (btn_w - (btn_w * scale)) / 2
                local dh = (btn_h - (btn_h * scale)) / 2
                local base_p = Dependencies.imgui.ImVec2(c_x_start + dw, c_y_start + dh)
                local base_sz = Dependencies.imgui.ImVec2(c_x_start + btn_w - dw, c_y_start + btn_h - dh)

                for i = 1, 8 do
                    local s_a = 0.20 - (i * 0.025)
                    dl:AddRectFilled(Dependencies.imgui.ImVec2(base_p.x - i, base_p.y - i + 2), Dependencies.imgui.ImVec2(base_sz.x + i, base_sz.y + i + 2), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(THEME.accent_primary.x, THEME.accent_primary.y, THEME.accent_primary.z, s_a)), r + i)
                end

                dl:AddRectFilled(base_p, base_sz, Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(0.08, 0.08, 0.1, 0.95)), r)
                
                local t = os.clock() * 1.5
                local pulse = (math.sin(t) + 1) * 0.5
                local pulse_color = Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(THEME.accent_primary.x, THEME.accent_primary.y, THEME.accent_primary.z, 0.15 + pulse * 0.15))
                dl:AddRectFilled(base_p, base_sz, pulse_color, r)

                dl:AddRect(base_p, base_sz, Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_primary), r, 15, 2.5)
                
                if is_hov then dl:AddRectFilled(base_p, base_sz, Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(1, 1, 1, 0.08)), r) end
                
                Dependencies.imgui.PushFont(UI.font_fa_large)
                local icon = Dependencies.fa('store')
                local isz = Dependencies.imgui.CalcTextSize(icon)
                Dependencies.imgui.PopFont()
                
                Dependencies.imgui.PushFont(UI.font_main)
                local txt = Dependencies.u8"RMARKET"
                local tsz = Dependencies.imgui.CalcTextSize(txt)
                Dependencies.imgui.PopFont()

                local total_w = isz.x + 15 + tsz.x
                local cx = base_p.x + (btn_w * scale - total_w) / 2

                Dependencies.imgui.PushFont(UI.font_fa_large)
                dl:AddText(Dependencies.imgui.ImVec2(cx, base_p.y + (btn_h * scale - isz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_primary), icon)
                Dependencies.imgui.PopFont()
                
                Dependencies.imgui.PushFont(UI.font_main)
                dl:AddText(Dependencies.imgui.ImVec2(cx + isz.x + 15, base_p.y + (btn_h * scale - tsz.y)/2), 0xFFFFFFFF, txt)
                Dependencies.imgui.PopFont()
            end
            Dependencies.imgui.End()
            Dependencies.imgui.PopStyleVar(3)
            Dependencies.imgui.PopStyleColor(2)
        end
        
        if not (UI.win_state[0] or State.show_db_modal or State.inventory_scan.active or State.selling.active or State.buying.active) then return end

        local io = Dependencies.imgui.GetIO()
        local sw, sh = getScreenResolution()

        if State.show_db_modal then
            renderDbRequiredModal()
        end

        local win_w = sw * Settings.win_w_percent
		local win_h = sh * Settings.win_h_percent

        if State.inventory_scan.active or State.selling.active or State.buying.active then
            local mod_w, mod_h = math.min(sw - D(32), D(460)), math.min(sh - D(32), D(320))
            Dependencies.imgui.SetNextWindowPos(Dependencies.imgui.ImVec2(sw / 2, sh / 2), Dependencies.imgui.Cond.Always, Dependencies.imgui.ImVec2(0.5, 0.5))
            Dependencies.imgui.SetNextWindowSize(Dependencies.imgui.ImVec2(mod_w, mod_h), Dependencies.imgui.Cond.Always)
            
            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.WindowBg, Dependencies.imgui.ImVec4(THEME.bg_secondary.x, THEME.bg_secondary.y, THEME.bg_secondary.z, 0.98))
            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Border, THEME.accent_primary)
            Dependencies.imgui.PushStyleVarFloat(Dependencies.imgui.StyleVar.WindowRounding, 20.0)
            Dependencies.imgui.PushStyleVarFloat(Dependencies.imgui.StyleVar.WindowBorderSize, 2.0)
            Dependencies.imgui.PushStyleVarVec2(Dependencies.imgui.StyleVar.WindowPadding, Dependencies.imgui.ImVec2(0, 0))
            local scanning_modal_flags = Dependencies.imgui.WindowFlags.NoTitleBar + Dependencies.imgui.WindowFlags.NoResize
                + Dependencies.imgui.WindowFlags.NoMove + Dependencies.imgui.WindowFlags.NoScrollbar
                + Dependencies.imgui.WindowFlags.NoScrollWithMouse
            if Dependencies.imgui.Begin("##ScanningModal", nil, scanning_modal_flags) then
                local p = Dependencies.imgui.GetCursorScreenPos()
                local dl = Dependencies.imgui.GetWindowDrawList()
                
                local title = ""
                local subtitle = ""
                local icon = Dependencies.fa('spinner')
                local is_waiting = false
                local items_count = 0
                local accent_color = THEME.accent_primary

                if State.inventory_scan.active then
                    accent_color = THEME.accent_success
                    icon = Dependencies.fa('box_open')
                    items_count = #UI.inv_items
                    if State.inventory_scan.stage == "waiting_user" then
                        title = Dependencies.u8"Ожидание инвентаря"
                        subtitle = Dependencies.u8"Откройте инвентарь или\nвведите /rec для точного кол-ва"
                        is_waiting = true
                    elseif State.inventory_scan.stage == "settings" then
                        title = Dependencies.u8"Настройка инвентаря"
                        subtitle = Dependencies.u8"Подготовка интерфейса CEF..."
                    elseif State.inventory_scan.stage == "parsing" then
                        title = Dependencies.u8"Чтение предметов"
                        subtitle = Dependencies.u8"Сбор данных... Не закрывайте окно"
                    end
                elseif State.selling.active then
                    icon = Dependencies.fa('paper_plane')
                    items_count = State.selling.total
                    if State.selling.stage == 'waiting_dialog' then
                        title = Dependencies.u8"Ожидание лавки"
                        subtitle = Dependencies.u8"Откройте диалоговое окно лавки"
                        is_waiting = true
                    elseif State.selling.stage == 'waiting_cef' then
                        title = Dependencies.u8"Загрузка инвентаря"
                        subtitle = Dependencies.u8"Ожидание интерфейса лавки..."
                    elseif State.selling.stage == 'waiting_input' or State.selling.stage == 'next_item' then
                        title = Dependencies.u8"Выставление товаров"
                        local cur_name = State.selling.current_item and Dependencies.u8(State.selling.current_item.name) or Dependencies.u8"Товар"
                        subtitle = string.format(Dependencies.u8"Товар (%d из %d):\n%s", State.selling.current_idx, State.selling.total, cur_name)
                    elseif State.selling.stage == 'closing' then
                        title = Dependencies.u8"Завершение"
                        subtitle = Dependencies.u8"Закрываем окна..."
                    end
                elseif State.buying.active then
                    icon = Dependencies.fa('cart_arrow_down')
                    items_count = State.buying.total
                    if State.buying.stage == 'waiting_dialog' then
                        title = Dependencies.u8"Ожидание лавки"
                        subtitle = Dependencies.u8"Откройте диалоговое окно лавки"
                        is_waiting = true
                    elseif State.buying.stage == 'closing' then
                        title = Dependencies.u8"Завершение"
                        subtitle = Dependencies.u8"Закрываем окна..."
                    else
                        title = Dependencies.u8"Скупка товаров"
                        local cur_name = State.buying.current_item and Dependencies.u8(State.buying.current_item.name) or Dependencies.u8"Товар"
                        subtitle = string.format(Dependencies.u8"Товар (%d из %d):\n%s", State.buying.current_idx, State.buying.total, cur_name)
                    end
                end

                local icon_sz = D(56)
                local center_icon = Dependencies.imgui.ImVec2(p.x + mod_w/2, p.y + D(48))

                dl:AddCircleFilled(center_icon, icon_sz/2, Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_main))

                if is_waiting then
                    local pulse = (math.sin(os.clock() * 5) + 1) * 0.5
                    local radius = (icon_sz/2) + (pulse * 10)
                    dl:AddCircle(center_icon, radius, Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(accent_color.x, accent_color.y, accent_color.z, 0.5 - pulse*0.5)), 32, 2.0)
                else
                    local time = os.clock() * 3
                    local a_min = time
                    local a_max = time + math.pi * 1.2
                    dl:PathArcTo(center_icon, (icon_sz/2) + 6, a_min, a_max, 32)
                    dl:PathStroke(Dependencies.imgui.ColorConvertFloat4ToU32(accent_color), false, 4.0)
                end

                Dependencies.imgui.PushFont(UI.font_fa_large)
                local isz = Dependencies.imgui.CalcTextSize(icon)
                dl:AddText(Dependencies.imgui.ImVec2(center_icon.x - isz.x/2, center_icon.y - isz.y/2), Dependencies.imgui.ColorConvertFloat4ToU32(accent_color), icon)
                Dependencies.imgui.PopFont()

                Dependencies.imgui.PushFont(UI.font_main)
                
                local title_y = drawCenteredText(title, p.y + D(96), THEME.text_primary, p, mod_w)
                local sub_y = drawCenteredText(subtitle, title_y + D(4), THEME.text_secondary, p, mod_w)
                
                if items_count > 0 then
                    local badge_txt = Dependencies.u8"Найдено товаров: " .. items_count
                    local bsz = Dependencies.imgui.CalcTextSize(badge_txt)
                    local bx = p.x + (mod_w - (bsz.x + D(24)))/2
                    local by = sub_y + D(8)
                    dl:AddRectFilled(Dependencies.imgui.ImVec2(bx, by), Dependencies.imgui.ImVec2(bx + bsz.x + D(24), by + bsz.y + D(12)), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(accent_color.x, accent_color.y, accent_color.z, 0.2)), D(8))
                    dl:AddText(Dependencies.imgui.ImVec2(bx + D(12), by + D(6)), Dependencies.imgui.ColorConvertFloat4ToU32(accent_color), badge_txt)
                end
                
                Dependencies.imgui.PopFont()

                local btn_h = Touch(52)
                local btn_w = mod_w - D(32)
                local btn_y = p.y + mod_h - btn_h - D(16)
                local btn_x = p.x + D(16)

                Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(btn_x, btn_y))
                if Dependencies.imgui.InvisibleButton("##cancel_scan", Dependencies.imgui.ImVec2(btn_w, btn_h)) then
                    State.inventory_scan.active = false
                    State.inventory_scan.stage = ""
                    State.selling.active = false
                    State.selling.stage = "cancelled"
                    State.selling.current_item = nil
                    State.buying.active = false
                    State.buying.stage = "cancelled"
                    State.buying.current_item = nil
                    UI.win_state[0] = true
                end

                local btn_active = Dependencies.imgui.IsItemActive()
                local c_bg = btn_active and Dependencies.imgui.ImVec4(THEME.accent_danger.x*0.8, THEME.accent_danger.y*0.8, THEME.accent_danger.z*0.8, 1) or THEME.bg_main
                
                dl:AddRectFilled(Dependencies.imgui.ImVec2(btn_x, btn_y), Dependencies.imgui.ImVec2(btn_x + btn_w, btn_y + btn_h), Dependencies.imgui.ColorConvertFloat4ToU32(c_bg), D(8))
                dl:AddRect(Dependencies.imgui.ImVec2(btn_x, btn_y), Dependencies.imgui.ImVec2(btn_x + btn_w, btn_y + btn_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_danger), D(8), 15, D(1.5))

                Dependencies.imgui.PushFont(UI.font_main)
                local c_txt = Dependencies.u8"ОТМЕНИТЬ ОПЕРАЦИЮ"
                local csz = Dependencies.imgui.CalcTextSize(c_txt)
                dl:AddText(Dependencies.imgui.ImVec2(btn_x + (btn_w - csz.x)/2, btn_y + (btn_h - csz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_danger), c_txt)
                Dependencies.imgui.PopFont()
            end
            Dependencies.imgui.End()
            Dependencies.imgui.PopStyleVar(3)
            Dependencies.imgui.PopStyleColor(2)
            if not UI.win_state[0] then return end
        end

        Dependencies.imgui.SetNextWindowPos(Dependencies.imgui.ImVec2(sw / 2, sh / 2), Dependencies.imgui.Cond.Always, Dependencies.imgui.ImVec2(0.5, 0.5))
        Dependencies.imgui.SetNextWindowSize(Dependencies.imgui.ImVec2(win_w, win_h), Dependencies.imgui.Cond.Always)
        local flags = Dependencies.imgui.WindowFlags.NoTitleBar + Dependencies.imgui.WindowFlags.NoResize
            + Dependencies.imgui.WindowFlags.NoMove + Dependencies.imgui.WindowFlags.NoCollapse
            + Dependencies.imgui.WindowFlags.NoScrollbar + Dependencies.imgui.WindowFlags.NoScrollWithMouse
        
        if Dependencies.imgui.Begin("RMarketMobile", UI.win_state, flags) then
            local p = Dependencies.imgui.GetWindowPos()
            local dl = Dependencies.imgui.GetWindowDrawList()

            if cfg_modal.active then
                dl:AddRectFilled(p, Dependencies.imgui.ImVec2(p.x + win_w, p.y + win_h), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(0.05, 0.05, 0.07, 0.95)), D(8))
                
                local m_w = math.min(win_w * 0.92, D(700))
                local m_h = math.min(win_h * 0.90, D(700))
                local m_x = p.x + (win_w - m_w) / 2
                local m_y = p.y + (win_h - m_h) / 2
                
                dl:AddRectFilled(Dependencies.imgui.ImVec2(m_x, m_y), Dependencies.imgui.ImVec2(m_x + m_w, m_y + m_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), D(8))
                dl:AddRect(Dependencies.imgui.ImVec2(m_x, m_y), Dependencies.imgui.ImVec2(m_x + m_w, m_y + m_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_primary), D(8), 15, D(2))
                
                local cur_y = m_y + D(20)
                Dependencies.imgui.PushFont(UI.font_fa_large)
                dl:AddText(Dependencies.imgui.ImVec2(m_x + D(26), cur_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_primary), Dependencies.fa('sliders'))
                Dependencies.imgui.PopFont()
                
                Dependencies.imgui.PushFont(UI.font_main)
                dl:AddText(Dependencies.imgui.ImVec2(m_x + D(64), cur_y + D(4)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_secondary), Dependencies.u8"НАСТРОЙКИ ТОВАРА")
                cur_y = cur_y + D(40)
                dl:AddLine(Dependencies.imgui.ImVec2(m_x, cur_y), Dependencies.imgui.ImVec2(m_x + m_w, cur_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), D(1.5))
                
                cur_y = cur_y + D(16)
                local item_name = Dependencies.u8(cfg_modal.item.name)
                local n_sz = Dependencies.imgui.CalcTextSize(item_name)
                dl:AddText(Dependencies.imgui.ImVec2(m_x + (m_w - n_sz.x)/2, cur_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_success), item_name)
                
                cur_y = cur_y + D(28)
                local average_price
                if UI.average_prices then
                    local clean_k = cleanItemName(cfg_modal.item.name)
                    local price_info = UI.average_prices[clean_k]
                    if not price_info then
                        local normalized_name = to_lower(clean_k)
                        for saved_name, saved_prices in pairs(UI.average_prices) do
                            if to_lower(cleanItemName(saved_name)) == normalized_name then
                                price_info = saved_prices
                                break
                            end
                        end
                    end
                    if price_info then
                        local p_val = cfg_modal.is_sell and price_info.sell or price_info.buy
                        if p_val and p_val > 0 then average_price = p_val end
                    end
                end
                local average_label = Dependencies.u8"Средняя цена: "
                if average_price then
                    local label_width = Dependencies.imgui.CalcTextSize(average_label).x
                    local total_width = label_width + measureMoney(average_price)
                    local average_x = m_x + (m_w - total_width) / 2
                    dl:AddText(Dependencies.imgui.ImVec2(average_x, cur_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_secondary), average_label)
                    drawMoney(dl, average_x + label_width, cur_y, average_price, THEME.text_secondary)
                else
                    local average_text = average_label .. Dependencies.u8"Нет данных"
                    local average_size = Dependencies.imgui.CalcTextSize(average_text)
                    dl:AddText(Dependencies.imgui.ImVec2(m_x + (m_w - average_size.x) / 2, cur_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_secondary), average_text)
                end

                cur_y = cur_y + D(32)
                local input_w = m_w - D(48)
                local input_x = m_x + D(24)
                
                local price_label = Dependencies.u8"Цена за 1 шт."
                local price_label_width = Dependencies.imgui.CalcTextSize(price_label).x
                dl:AddText(Dependencies.imgui.ImVec2(input_x + D(4), cur_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), price_label)
                Dependencies.imgui.PushFont(UI.font_fa)
                local currency_icon = getCurrencyIcon()
                local currency_icon_size = Dependencies.imgui.CalcTextSize(currency_icon)
                dl:AddText(Dependencies.imgui.ImVec2(input_x + D(4) + price_label_width + D(6), cur_y + (Dependencies.imgui.GetFontSize() - currency_icon_size.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_success), currency_icon)
                Dependencies.imgui.PopFont()
                cur_y = cur_y + D(28)
                Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(input_x, cur_y))
                Dependencies.imgui.SetNextItemWidth(input_w)
                
                Dependencies.imgui.PushStyleVarVec2(Dependencies.imgui.StyleVar.FramePadding, Dependencies.imgui.ImVec2(D(18), D(16)))
                Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.FrameBg, THEME.bg_main)
                Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Text, THEME.text_primary)
                Dependencies.imgui.InputText("##cfg_price", cfg_modal.buf_price, 32, Dependencies.imgui.InputTextFlags.CharsDecimal)
                
                cur_y = cur_y + D(72)
                local amt_label = cfg_modal.is_sell and Dependencies.u8"Количество:" or Dependencies.u8"Кол-во / Цвет (если аксессуар):"
                
                dl:AddText(Dependencies.imgui.ImVec2(input_x + 5, cur_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), amt_label)
                cur_y = cur_y + D(28)
                Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(input_x, cur_y))
                
                if cfg_modal.is_sell then
                    local max_btn_w = Touch(92)
                    local inp_w = input_w - max_btn_w - D(12)
                    
                    if cfg_modal.auto_max then
                        dl:AddRectFilled(Dependencies.imgui.ImVec2(input_x, cur_y), Dependencies.imgui.ImVec2(input_x + inp_w, cur_y + Touch(52)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_main), D(8))
                        local txt = Dependencies.u8"Все доступные"
                        local sz = Dependencies.imgui.CalcTextSize(txt)
                        dl:AddText(Dependencies.imgui.ImVec2(input_x + (inp_w - sz.x)/2, cur_y + (70 - sz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_secondary), txt)
                    else
                        Dependencies.imgui.SetNextItemWidth(inp_w)
                        Dependencies.imgui.InputText("##cfg_amount", cfg_modal.buf_amount, 32, Dependencies.imgui.InputTextFlags.CharsDecimal)
                    end
                    
                    local max_x = input_x + inp_w + 15.0
                    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(max_x, cur_y))
                    if Dependencies.imgui.InvisibleButton("##btn_max", Dependencies.imgui.ImVec2(max_btn_w, Touch(52))) then cfg_modal.auto_max = not cfg_modal.auto_max end
                    
                    local max_bg = cfg_modal.auto_max and THEME.accent_success or THEME.bg_tertiary
                    if Dependencies.imgui.IsItemActive() then max_bg = Dependencies.imgui.ImVec4(max_bg.x*0.8, max_bg.y*0.8, max_bg.z*0.8, 1) end
                    dl:AddRectFilled(Dependencies.imgui.ImVec2(max_x, cur_y), Dependencies.imgui.ImVec2(max_x + max_btn_w, cur_y + Touch(52)), Dependencies.imgui.ColorConvertFloat4ToU32(max_bg), D(8))
                    
                    Dependencies.imgui.PushFont(UI.font_main)
                    local max_txt = "MAX"
                    local max_sz = Dependencies.imgui.CalcTextSize(max_txt)
                    dl:AddText(Dependencies.imgui.ImVec2(max_x + (max_btn_w - max_sz.x)/2, cur_y + (Touch(52) - max_sz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(cfg_modal.auto_max and THEME.bg_main or THEME.text_primary), max_txt)
                    Dependencies.imgui.PopFont()
                else
                    Dependencies.imgui.SetNextItemWidth(input_w)
                    Dependencies.imgui.InputText("##cfg_amount", cfg_modal.buf_amount, 32, Dependencies.imgui.InputTextFlags.CharsDecimal)
                end
                
                Dependencies.imgui.PopStyleColor(2)
                Dependencies.imgui.PopStyleVar()
                Dependencies.imgui.PopFont()

                local btn_h = Touch(56)
                local btn_gap = D(12)
                local btn_y_1 = m_y + m_h - (btn_h * 2) - btn_gap - D(18)
                local btn_y_2 = m_y + m_h - btn_h - D(18)
                
                if drawModalButton("##m_save", "СОХРАНИТЬ", Dependencies.fa('check'), input_x, btn_y_1, input_w, THEME.accent_success, btn_h, dl) then
                    local new_price = tonumber(Dependencies.ffi.string(cfg_modal.buf_price)) or 1000
                    local new_amount = tonumber(Dependencies.ffi.string(cfg_modal.buf_amount)) or 1
                    cfg_modal.target_table[cfg_modal.index].price = new_price
                    cfg_modal.target_table[cfg_modal.index].amount = new_amount
                    if cfg_modal.is_sell then cfg_modal.target_table[cfg_modal.index].auto_max = cfg_modal.auto_max end
                    if cfg_modal.is_sell then saveJsonFile(UI.PATH_CFG_SELL, UI.config_sell) else saveJsonFile(UI.PATH_CFG_BUY, UI.config_buy) end
                    triggerCloudSync()
                    cfg_modal.active = false
                end
                
                local sub_w = (input_w - btn_gap) / 2
                if drawModalButton("##m_cancel", "ОТМЕНА", Dependencies.fa('xmark'), input_x, btn_y_2, sub_w, THEME.bg_tertiary, btn_h, dl) then cfg_modal.active = false end
                if drawModalButton("##m_del", "УДАЛИТЬ", Dependencies.fa('trash'), input_x + sub_w + btn_gap, btn_y_2, sub_w, THEME.accent_danger, btn_h, dl) then
                    local deleted_copy = {}
                    for k,v in pairs(cfg_modal.target_table[cfg_modal.index]) do deleted_copy[k] = v end
                    table.insert(UI.undo_stack, { list = cfg_modal.is_sell and "sell" or "buy", index = cfg_modal.index, item = deleted_copy })
                    UI.undo_timer = os.clock() + 5.0
                    table.remove(cfg_modal.target_table, cfg_modal.index)
                    if cfg_modal.is_sell then saveJsonFile(UI.PATH_CFG_SELL, UI.config_sell) else saveJsonFile(UI.PATH_CFG_BUY, UI.config_buy) end
                    cfg_modal.active = false
                end

            else

            local compact_layout = sw < D(820)
            local nav_w = compact_layout and D(76) or D(108)
            local header_h = D(88)
            local hide_arb_footer = UI.active_tab == 7 and (not isTokenVerified() or not isVerifiedVip() or isItemDbEmpty())
            local hide_mkt_footer = UI.active_tab == 4 and (not isTokenVerified() or isItemDbEmpty())
            local footer_h = (UI.active_tab == 5 or UI.active_tab == 6 or hide_arb_footer or hide_mkt_footer) and 0 or D(96)
            local c_x = p.x + nav_w
            local c_w = win_w - nav_w
            local content_y = p.y + header_h
			local content_h = win_h - header_h - footer_h
			if content_h < D(160) then content_h = D(160) end

            dl:AddRectFilled(p, Dependencies.imgui.ImVec2(p.x + nav_w, p.y + win_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), D(8), 1 + 8)
            dl:AddLine(Dependencies.imgui.ImVec2(p.x + nav_w, p.y), Dependencies.imgui.ImVec2(p.x + nav_w, p.y + win_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), 2.0)

            Dependencies.imgui.PushFont(UI.font_fa_large)
            local code_ic = Dependencies.fa('code')
            local code_sz = Dependencies.imgui.CalcTextSize(code_ic)
            dl:AddText(Dependencies.imgui.ImVec2(p.x + (nav_w - code_sz.x)/2, p.y + 35), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_primary), code_ic)
            Dependencies.imgui.PopFont()

            local close_sz = Touch(52)
            local close_y = p.y + win_h - close_sz - D(12)
            local start_y = p.y + D(84)
            local available_tab_h = (close_y - start_y - D(12)) / 7
            local tab_h = math.max(D(40), math.min(Touch(72), available_tab_h))
            
            drawNavigationTab(1, Dependencies.fa('arrow_up_from_bracket'), 0, p, start_y, nav_w, tab_h, dl)
            drawNavigationTab(2, Dependencies.fa('arrow_down_to_bracket'), tab_h, p, start_y, nav_w, tab_h, dl)
            drawNavigationTab(3, Dependencies.fa('file_lines'), tab_h * 2, p, start_y, nav_w, tab_h, dl)
            drawNavigationTab(4, Dependencies.fa('globe'), tab_h * 3, p, start_y, nav_w, tab_h, dl)
            drawNavigationTab(7, Dependencies.fa('scale_balanced'), tab_h * 4, p, start_y, nav_w, tab_h, dl)
            drawNavigationTab(5, Dependencies.fa('bullhorn'), tab_h * 5, p, start_y, nav_w, tab_h, dl)
            drawNavigationTab(6, Dependencies.fa('gear'), tab_h * 6, p, start_y, nav_w, tab_h, dl)

            Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(p.x + (nav_w - close_sz)/2, close_y))
            if Dependencies.imgui.InvisibleButton("##close_btn", Dependencies.imgui.ImVec2(close_sz, close_sz)) then UI.win_state[0] = false end
            local c_col = Dependencies.imgui.IsItemActive() and THEME.accent_danger or THEME.text_secondary
            dl:AddRectFilled(Dependencies.imgui.ImVec2(p.x + (nav_w - close_sz)/2, close_y), Dependencies.imgui.ImVec2(p.x + (nav_w + close_sz)/2, close_y + close_sz), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(1,1,1,0.05)), D(8))
            Dependencies.imgui.PushFont(UI.font_fa_large)
            local cxsz = Dependencies.imgui.CalcTextSize(Dependencies.fa('xmark'))
            dl:AddText(Dependencies.imgui.ImVec2(p.x + (nav_w - cxsz.x)/2, close_y + (close_sz - cxsz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(c_col), Dependencies.fa('xmark'))
            Dependencies.imgui.PopFont()

            dl:AddRectFilled(Dependencies.imgui.ImVec2(c_x, p.y), Dependencies.imgui.ImVec2(p.x + win_w, p.y + header_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_main), D(8), 2)
            dl:AddLine(Dependencies.imgui.ImVec2(c_x, p.y + header_h), Dependencies.imgui.ImVec2(p.x + win_w, p.y + header_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), 2.0)

            local current_buf = UI.search_buf_sell
            if UI.active_tab == 2 then current_buf = UI.search_buf_buy
            elseif UI.active_tab == 4 then current_buf = UI.search_buf_market
            elseif UI.active_tab == 7 then current_buf = StateArbitrage.search_buf end

            local search_w = c_w * (compact_layout and 0.48 or 0.55)
            local search_h = Touch(56)
            local search_x = c_x + D(20)
            local search_y = p.y + (header_h - search_h) / 2
            
            if UI.active_tab ~= 3 and UI.active_tab ~= 5 and UI.active_tab ~= 6 then
                dl:AddRectFilled(Dependencies.imgui.ImVec2(search_x, search_y), Dependencies.imgui.ImVec2(search_x + search_w, search_y + search_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_tertiary), D(8))
                dl:AddRect(Dependencies.imgui.ImVec2(search_x, search_y), Dependencies.imgui.ImVec2(search_x + search_w, search_y + search_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), D(8), 15, D(1.5))
                
                Dependencies.imgui.PushFont(UI.font_fa_large)
                local search_icon = Dependencies.fa('magnifying_glass')
                local sisz = Dependencies.imgui.CalcTextSize(search_icon)
                dl:AddText(Dependencies.imgui.ImVec2(search_x + D(18), search_y + (search_h - sisz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_secondary), search_icon)
                Dependencies.imgui.PopFont()
     
                Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(search_x + D(56), search_y))
                local clear_size = Touch(40)
                local search_input_w = math.max(D(48), search_w - D(56) - clear_size - D(12))
                Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.FrameBg, Dependencies.imgui.ImVec4(0,0,0,0))
                Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Text, THEME.text_primary)
                Dependencies.imgui.PushFont(UI.font_main)
                Dependencies.imgui.PushStyleVarVec2(Dependencies.imgui.StyleVar.FramePadding, Dependencies.imgui.ImVec2(0, (search_h - Dependencies.imgui.GetFontSize()) / 2))
                local hint_text = UI.active_tab == 1 and Dependencies.u8"Поиск в инвентаре..."
                    or (UI.active_tab == 4 and Dependencies.u8"Поиск лавки или товара..."
                    or (UI.active_tab == 7 and Dependencies.u8"Поиск в арбитраже..."
                    or Dependencies.u8"Поиск товара..."))
                if UI.search_focus_requested then
                    Dependencies.imgui.SetKeyboardFocusHere()
                    UI.search_focus_requested = false
                end
                Dependencies.imgui.SetNextItemWidth(search_input_w)
                Dependencies.imgui.InputTextWithHint("##search_bar_" .. UI.active_tab, hint_text, current_buf, 128)
                if Dependencies.ffi.string(current_buf) ~= "" then
                    local clear_x = search_x + search_w - clear_size - D(6)
                    local clear_y = search_y + (search_h - clear_size) / 2
                    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(clear_x, clear_y))
                    if Dependencies.imgui.InvisibleButton("##search_clear_" .. UI.active_tab, Dependencies.imgui.ImVec2(clear_size, clear_size)) then
                        current_buf[0] = 0
                        UI.search_focus_requested = true
                    end
                    local clear_color = Dependencies.imgui.IsItemHovered() and THEME.text_primary or THEME.text_secondary
                    Dependencies.imgui.PushFont(UI.font_fa_large)
                    local clear_icon = Dependencies.fa('xmark')
                    local clear_icon_size = Dependencies.imgui.CalcTextSize(clear_icon)
                    dl:AddText(
                        Dependencies.imgui.ImVec2(clear_x + (clear_size - clear_icon_size.x) / 2, clear_y + (clear_size - clear_icon_size.y) / 2),
                        Dependencies.imgui.ColorConvertFloat4ToU32(clear_color),
                        clear_icon
                    )
                    Dependencies.imgui.PopFont()
                end
                Dependencies.imgui.PopStyleVar()
                Dependencies.imgui.PopFont()
                Dependencies.imgui.PopStyleColor(2)
            else
                Dependencies.imgui.PushFont(UI.font_main)
                local title_text = ""
                if UI.active_tab == 3 then title_text = Dependencies.u8"ИСТОРИЯ СДЕЛОК"
                elseif UI.active_tab == 5 then title_text = Dependencies.u8"АВТОМАТИЧЕСКИЙ ПИАР"
                elseif UI.active_tab == 6 then title_text = Dependencies.u8"НАСТРОЙКИ RMARKET" end
                local title_sz = Dependencies.imgui.CalcTextSize(title_text)
                dl:AddText(Dependencies.imgui.ImVec2(c_x + 40, p.y + (header_h - title_sz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), title_text)
                Dependencies.imgui.PopFont()
            end

            local btn_sz = Touch(56)
            local right_cursor = p.x + win_w - btn_sz - D(20)
            local top_btn_y = p.y + (header_h - btn_sz) / 2

            if UI.active_tab == 4 then
                local srv_names = {"Все серверы"}
                for _, srv in ipairs(UI.RODINA_SERVERS_DATA) do table.insert(srv_names, srv.name) end
                local filter_w = compact_layout and btn_sz or D(220)
                right_cursor = right_cursor - filter_w + btn_sz
                Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(right_cursor, top_btn_y))
                local current_srv_name = srv_names[StateMarket.server_filter_idx + 1]
                local filter_label = compact_layout and "" or Dependencies.u8(current_srv_name)
                if DrawStyledButton("##srv_filter_hdr", filter_label, filter_w, btn_sz, THEME.bg_tertiary, Dependencies.fa('server'), dl) then Dependencies.imgui.OpenPopup("ServerFilterPopupHeaderMobile") end
                Dependencies.imgui.SetNextWindowPos(Dependencies.imgui.ImVec2(right_cursor, top_btn_y + btn_sz + D(8)))
                Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.PopupBg, THEME.bg_secondary)
                if Dependencies.imgui.BeginPopup("ServerFilterPopupHeaderMobile") then
                    Dependencies.imgui.PushFont(UI.font_main)
                    Dependencies.imgui.PushStyleVarVec2(Dependencies.imgui.StyleVar.ItemSpacing, Dependencies.imgui.ImVec2(15, 25))
                    for i, name in ipairs(srv_names) do
                        if Dependencies.imgui.Selectable(Dependencies.u8(name)) then
                            StateMarket.server_filter_idx = i - 1
                        end
                    end
                    Dependencies.imgui.PopStyleVar()
                    Dependencies.imgui.PopFont()
                    Dependencies.imgui.EndPopup()
                end
                Dependencies.imgui.PopStyleColor()
            end

            if UI.active_tab == 1 or UI.active_tab == 2 then
                if UI.active_tab == 1 then
                    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(right_cursor, top_btn_y))
                    if Dependencies.imgui.InvisibleButton("##scan_btn", Dependencies.imgui.ImVec2(btn_sz, btn_sz)) then
                        startInventoryScan()
                    end
                    local scan_hov = Dependencies.imgui.IsItemHovered()
                    local scan_icon = Dependencies.fa('magnifying_glass')
                    local scan_col = THEME.accent_success
                    if Dependencies.imgui.IsItemActive() then dl:AddCircleFilled(Dependencies.imgui.ImVec2(right_cursor + btn_sz/2, top_btn_y + btn_sz/2), btn_sz/2, Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(scan_col.x, scan_col.y, scan_col.z, 0.3))) end
                    Dependencies.imgui.PushFont(UI.font_fa_large)
                    local sx_sz = Dependencies.imgui.CalcTextSize(scan_icon)
                    dl:AddText(Dependencies.imgui.ImVec2(right_cursor + (btn_sz - sx_sz.x)/2, top_btn_y + (btn_sz - sx_sz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(scan_hov and THEME.text_primary or scan_col), scan_icon)
                    Dependencies.imgui.PopFont()

                    right_cursor = right_cursor - btn_sz - 20.0
                    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(right_cursor, top_btn_y))
                    if Dependencies.imgui.InvisibleButton("##dl_prices_btn", Dependencies.imgui.ImVec2(btn_sz, btn_sz)) then api_DownloadAveragePrices() end
                    local p_col = Dependencies.imgui.ImVec4(0.2, 0.6, 0.9, 1.0)
                    if Dependencies.imgui.IsItemActive() then dl:AddCircleFilled(Dependencies.imgui.ImVec2(right_cursor + btn_sz/2, top_btn_y + btn_sz/2), btn_sz/2, Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(p_col.x, p_col.y, p_col.z, 0.3))) end
                    Dependencies.imgui.PushFont(UI.font_fa_large)
                    local px_sz = Dependencies.imgui.CalcTextSize(Dependencies.fa('cloud_arrow_down'))
                    dl:AddText(Dependencies.imgui.ImVec2(right_cursor + (btn_sz - px_sz.x)/2, top_btn_y + (btn_sz - px_sz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.IsItemHovered() and THEME.text_primary or p_col), Dependencies.fa('cloud_arrow_down'))
                    Dependencies.imgui.PopFont()
                elseif UI.active_tab == 2 then
                    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(right_cursor, top_btn_y))
                    if Dependencies.imgui.InvisibleButton("##dl_db_btn", Dependencies.imgui.ImVec2(btn_sz, btn_sz)) then
                        api_CheckAndDownloadItemsDB(true)
                    end
                    local dl_hov = Dependencies.imgui.IsItemHovered()
                    local dl_icon = Dependencies.fa('cloud_arrow_down')
                    local dl_col = THEME.accent_primary
                    if Dependencies.imgui.IsItemActive() then dl:AddCircleFilled(Dependencies.imgui.ImVec2(right_cursor + btn_sz/2, top_btn_y + btn_sz/2), btn_sz/2, Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(dl_col.x, dl_col.y, dl_col.z, 0.3))) end
                    Dependencies.imgui.PushFont(UI.font_fa_large)
                    local dx_sz = Dependencies.imgui.CalcTextSize(dl_icon)
                    dl:AddText(Dependencies.imgui.ImVec2(right_cursor + (btn_sz - dx_sz.x)/2, top_btn_y + (btn_sz - dx_sz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(dl_hov and THEME.text_primary or dl_col), dl_icon)
                    Dependencies.imgui.PopFont()
                end
            end

            local scroll_w = Touch(compact_layout and 42 or 64)
            local list_w = c_w - scroll_w - D(40)
            local list_x = c_x + D(20)

            local current_search_str = to_lower(Dependencies.u8:decode(Dependencies.ffi.string(current_buf)))

            if UI.active_tab == 1 or UI.active_tab == 2 then
                local seg_w = list_w
                local seg_h = Touch(68)
                local seg_y = content_y + D(16)
                
                dl:AddRectFilled(Dependencies.imgui.ImVec2(list_x, seg_y), Dependencies.imgui.ImVec2(list_x + seg_w, seg_y + seg_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), D(8))
                dl:AddRect(Dependencies.imgui.ImVec2(list_x, seg_y), Dependencies.imgui.ImVec2(list_x + seg_w, seg_y + seg_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), D(8), 15, D(1.5))

                local half_w = seg_w / 2
                drawInventorySegmentButton(1, UI.active_tab == 1 and "ИНВЕНТАРЬ ИГРОКА" or "БАЗА ТОВАРОВ", Dependencies.fa('database'), true, list_x, seg_y, half_w, seg_h, dl)
                local tgt_count = #(UI.active_tab == 1 and UI.config_sell or UI.config_buy)
                drawInventorySegmentButton(2, (UI.active_tab == 1 and "СПИСОК НА ПРОДАЖУ (" or "СПИСОК НА СКУПКУ (") .. tgt_count .. ")", Dependencies.fa('list_check'), false, list_x, seg_y, half_w, seg_h, dl)

                local actual_list_y = seg_y + seg_h + D(18)
                local actual_list_h = content_h - (seg_h + D(34))

                local delta = drawScrollZone("##main_scroll", list_x + list_w + D(10), actual_list_y, scroll_w, actual_list_h, io, dl)

                Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(list_x, actual_list_y))
                Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ChildBg, Dependencies.imgui.ImVec4(0,0,0,0))
                if Dependencies.imgui.BeginChild("MainList", Dependencies.imgui.ImVec2(list_w, actual_list_h), false, Dependencies.imgui.WindowFlags.NoScrollbar) then
                    local c_pos = Dependencies.imgui.GetWindowPos()
                    local c_size = Dependencies.imgui.GetWindowSize()
                    dl:PushClipRect(c_pos, Dependencies.imgui.ImVec2(c_pos.x + c_size.x, c_pos.y + c_size.y), true)
                    if delta ~= 0 then Dependencies.imgui.SetScrollY(Dependencies.imgui.GetScrollY() - delta) end
                    
                    if UI.active_sub_tab == 1 then
                        local source_items = UI.active_tab == 1 and UI.inv_items or UI.db_items
                        local target_config = UI.active_tab == 1 and UI.config_sell or UI.config_buy
                        local cache = UI.active_tab == 1 and ui_cache_sell or ui_cache_buy

                        if not cache.index then
                            cache.index = {}
                            for i, item in ipairs(source_items) do
                                local item_name
                                if UI.active_tab == 1 then
                                    item_name = UI.item_names[tostring(item.model_id)]
                                else
                                    item_name = item.name
                                end
                                if item_name and item_name ~= "" then
                                    item.name = item_name
                                    cache.index[#cache.index + 1] = {
                                        data = item,
                                        original_index = i,
                                        search_name = to_lower(item_name)
                                    }
                                end
                            end
                        end

                        if cache.query ~= current_search_str then
                            if cache.pending_query ~= current_search_str then
                                cache.pending_query = current_search_str
                                cache.pending_since = os.clock()
                            end

                            local search_ready = cache.query == nil
                                or current_search_str == ""
                                or os.clock() - cache.pending_since >= 0.2
                            if search_ready then
                                local matches = {}
                                local prepared_query = current_search_str ~= "" and SmartSearch.prepareQuery(current_search_str) or nil

                                for _, entry in ipairs(cache.index) do
                                    local score = prepared_query and SmartSearch.getMatchScore(prepared_query, entry) or 0
                                    if not prepared_query or score > 0 then
                                        matches[#matches + 1] = {
                                            data = entry.data,
                                            original_index = entry.original_index,
                                            score = score
                                        }
                                    end
                                end

                                if prepared_query then
                                    table.sort(matches, function(a, b)
                                        return a.score > b.score
                                    end)
                                end
                                    Dependencies.imgui.PopStyleVar(3)
                                cache.items = matches
                                cache.query = current_search_str
                                cache.pending_query = nil
                                cache.pending_since = nil
                            end
                        end

						if cache.items and #cache.items > 0 then
							local clipper = Dependencies.imgui.ImGuiListClipper(#cache.items)
							while clipper:Step() do
								for i = clipper.DisplayStart + 1, clipper.DisplayEnd do
									local entry = cache.items[i]
									renderSourceCard(entry.data, (UI.active_tab == 1), entry.original_index, target_config)
								end
							end
						else
							Dependencies.imgui.PushFont(UI.font_main)
							Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, 50))
                            local empty_text = current_search_str ~= "" and "Ничего не найдено."
                                or (UI.active_tab == 1 and "Нет предметов из базы в инвентаре." or "База предметов пуста.")
                            CenterText(Dependencies.u8(empty_text), THEME.text_secondary, list_w)
							Dependencies.imgui.PopFont()
						end
                    else
                        local target_config = UI.active_tab == 1 and UI.config_sell or UI.config_buy
                        if #target_config == 0 then
                            Dependencies.imgui.PushFont(UI.font_main)
                            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, 50))
                            CenterText(Dependencies.u8"Список пуст. Перейдите в базу для добавления.", THEME.text_secondary, list_w)
                            Dependencies.imgui.PopFont()
                        else
                            for i, item in ipairs(target_config) do
                                renderTargetCard(item, (UI.active_tab == 1), i, target_config)
                            end
                        end
                    end
                    dl:PopClipRect()
                end
                Dependencies.imgui.EndChild()
                Dependencies.imgui.PopStyleColor()

            elseif UI.active_tab == 3 then
                if LogsState.logs_current_date_idx == 0 then
                    refreshLogDates()
                    LogsState.cached_income, LogsState.cached_expense = updateLogView()
                    LogsState.logs_current_date_idx = 1
                end

                local delta = drawScrollZone("##scroll_logs", list_x + list_w + D(10), content_y + D(16), scroll_w, content_h - D(32), io, dl)

                Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(list_x, content_y + D(16)))
                Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ChildBg, Dependencies.imgui.ImVec4(0,0,0,0))
                if Dependencies.imgui.BeginChild("LogsChild", Dependencies.imgui.ImVec2(list_w, content_h - D(32)), false, Dependencies.imgui.WindowFlags.NoScrollbar) then
                    local c_pos = Dependencies.imgui.GetWindowPos()
                    local c_size = Dependencies.imgui.GetWindowSize()
                    dl:PushClipRect(c_pos, Dependencies.imgui.ImVec2(c_pos.x + c_size.x, c_pos.y + c_size.y), true)
                    if delta ~= 0 then Dependencies.imgui.SetScrollY(Dependencies.imgui.GetScrollY() - delta) end
                    
                    Dependencies.imgui.PushFont(UI.font_main)
                    local stat_card_w = (list_w - D(32)) / 3
                    local stat_card_h = D(96)
                    
                    local profit = LogsState.cached_income - LogsState.cached_expense
                    local profit_col = profit >= 0 and THEME.accent_success or THEME.accent_danger
                    drawLogStatCard(c_pos.x, c_pos.y, "Доход", LogsState.cached_income, THEME.accent_success, stat_card_w, stat_card_h, dl)
                    drawLogStatCard(c_pos.x + stat_card_w + D(16), c_pos.y, "Расход", LogsState.cached_expense, THEME.accent_primary, stat_card_w, stat_card_h, dl)
                    drawLogStatCard(c_pos.x + stat_card_w*2 + D(32), c_pos.y, "Прибыль", profit, profit_col, stat_card_w, stat_card_h, dl)
                    
                    Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, stat_card_h + D(24)))
                    
                    local filters_y = c_pos.y + stat_card_h + D(32)
                    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(c_pos.x, filters_y))
                    
                    if Dependencies.imgui.Checkbox(Dependencies.u8"Продажи", log_filters.show_sales) then LogsState.cached_income, LogsState.cached_expense = updateLogView() end
                    Dependencies.imgui.SameLine(0, D(32))
                    if Dependencies.imgui.Checkbox(Dependencies.u8"Покупки", log_filters.show_purchases) then LogsState.cached_income, LogsState.cached_expense = updateLogView() end
                    
                    Dependencies.imgui.SameLine(0, D(40))
                    local combo_w = math.min(list_w, D(400))
                    local combo_h = Touch(56)
                    local combo_x = Dependencies.imgui.GetCursorScreenPos().x
                    local combo_y = filters_y - D(12)
                    
                    if DrawStyledButton("##date_combo_btn", LogsState.logs_dates_cache[LogsState.logs_current_date_idx] or Dependencies.u8"Выберите дату", combo_w, combo_h, THEME.bg_tertiary, Dependencies.fa('calendar_days'), dl) then Dependencies.imgui.OpenPopup("DateFilterPopupMobile") end
                    Dependencies.imgui.SetNextWindowPos(Dependencies.imgui.ImVec2(combo_x, combo_y + combo_h + D(8)))
                    Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.PopupBg, THEME.bg_secondary)
                    if Dependencies.imgui.BeginPopup("DateFilterPopupMobile") then
                        Dependencies.imgui.PushStyleVarVec2(Dependencies.imgui.StyleVar.ItemSpacing, Dependencies.imgui.ImVec2(D(12), D(18)))
                        for i, date_str in ipairs(LogsState.logs_dates_cache) do
                            if Dependencies.imgui.Selectable(date_str, LogsState.logs_current_date_idx == i) then
                                LogsState.logs_current_date_idx = i
                                LogsState.cached_income, LogsState.cached_expense = updateLogView()
                            end
                        end
                        Dependencies.imgui.PopStyleVar()
                        Dependencies.imgui.EndPopup()
                    end
                    Dependencies.imgui.PopStyleColor()
                    
                    Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, 30))
                    dl:AddLine(Dependencies.imgui.ImVec2(c_pos.x, Dependencies.imgui.GetCursorScreenPos().y), Dependencies.imgui.ImVec2(c_pos.x + list_w, Dependencies.imgui.GetCursorScreenPos().y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), 2.0)
                    Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, 20))
                    
                    if #LogsState.current_view_logs == 0 then
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, 50))
                        CenterText(Dependencies.u8"Нет операций за эту дату", THEME.text_secondary, list_w)
                    else
                        for i, log in ipairs(LogsState.current_view_logs) do
                            local item_p = Dependencies.imgui.GetCursorScreenPos()
                            local item_h = D(96)
                            local is_sale = log.type == "sale"
                            local acc_col = is_sale and THEME.accent_success or THEME.accent_primary
                            
                            dl:AddRectFilled(item_p, Dependencies.imgui.ImVec2(item_p.x + list_w, item_p.y + item_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), D(8))
                            dl:AddRectFilled(item_p, Dependencies.imgui.ImVec2(item_p.x + D(6), item_p.y + item_h), Dependencies.imgui.ColorConvertFloat4ToU32(acc_col), D(8), 9)
                            
                            Dependencies.imgui.PushFont(UI.font_fa_large)
                            local ic = is_sale and Dependencies.fa('arrow_up_from_bracket') or Dependencies.fa('cart_shopping')
                            dl:AddText(Dependencies.imgui.ImVec2(item_p.x + D(24), item_p.y + (item_h - D(24))/2), Dependencies.imgui.ColorConvertFloat4ToU32(acc_col), ic)
                            Dependencies.imgui.PopFont()
                            
                            dl:PushClipRect(Dependencies.imgui.ImVec2(item_p.x + D(68), item_p.y), Dependencies.imgui.ImVec2(item_p.x + list_w - D(200), item_p.y + item_h), true)
                            dl:AddText(Dependencies.imgui.ImVec2(item_p.x + D(68), item_p.y + D(16)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), Dependencies.u8(log.item))
                            local meta_str = string.format("%s | %s", log.player or "Игрок", log.date:match("%d%d:%d%d:%d%d") or "")
                            dl:AddText(Dependencies.imgui.ImVec2(item_p.x + D(68), item_p.y + D(52)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_secondary), Dependencies.u8(meta_str))
                            dl:PopClipRect()
                            
                            local total_width = measureMoney(log.total)
                            drawMoney(dl, item_p.x + list_w - total_width - D(20), item_p.y + D(16), log.total, acc_col)

                            local details_y = item_p.y + D(52)
                            if log.amount > 1 then
                                local quantity_text = Dependencies.u8(string.format("%d шт. x ", log.amount))
                                local quantity_width = Dependencies.imgui.CalcTextSize(quantity_text).x
                                local price_width = measureMoney(log.price)
                                local details_x = item_p.x + list_w - quantity_width - price_width - D(20)
                                dl:AddText(Dependencies.imgui.ImVec2(details_x, details_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_secondary), quantity_text)
                                drawMoney(dl, details_x + quantity_width, details_y, log.price, THEME.text_secondary)
                            else
                                local details = Dependencies.u8"1 шт."
                                local details_width = Dependencies.imgui.CalcTextSize(details).x
                                dl:AddText(Dependencies.imgui.ImVec2(item_p.x + list_w - details_width - D(20), details_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_secondary), details)
                            end
                            
                            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, item_h + D(16)))
                        end
                    end
                    Dependencies.imgui.PopFont()
                    dl:PopClipRect()
                end
                Dependencies.imgui.EndChild()
                Dependencies.imgui.PopStyleColor()

            elseif UI.active_tab == 4 then
                if not isTokenVerified() then
                    local w_av = list_w
                    local h_av = content_h - D(32)
                    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(list_x, content_y + D(16)))
                    Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ChildBg, THEME.bg_secondary)
                    if Dependencies.imgui.BeginChild("MarketNoKey", Dependencies.imgui.ImVec2(w_av, h_av), true) then
                        local avail_w = Dependencies.imgui.GetContentRegionAvail().x
                        local avail_h = Dependencies.imgui.GetContentRegionAvail().y
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, math.max(D(24), avail_h / 2 - D(72))))
                        if UI.font_fa then
                            Dependencies.imgui.PushFont(UI.font_fa_large or UI.font_fa)
                            local icon = Dependencies.fa('key')
                            local isz = Dependencies.imgui.CalcTextSize(icon)
                            Dependencies.imgui.SetCursorPosX((avail_w - isz.x) / 2)
                            Dependencies.imgui.TextColored(THEME.accent_primary, icon)
                            Dependencies.imgui.PopFont()
                        end
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(8)))
                        local t1 = ApiState.token_state == "checking"
                            and Dependencies.u8"Проверка ключа..."
                            or (ApiState.token_state == "invalid"
                                and Dependencies.u8"Ключ не подтверждён"
                                or (ApiState.token_state == "error"
                                    and Dependencies.u8"Не удалось подтвердить ключ"
                                    or Dependencies.u8"Требуется привязка ключа"))
                        Dependencies.imgui.SetCursorPosX((avail_w - Dependencies.imgui.CalcTextSize(t1).x) / 2)
                        Dependencies.imgui.TextColored(THEME.text_primary, t1)
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(6)))
                        local t2 = Dependencies.u8"Ключ выдается ботом @rdnMarket_bot или в ВК (vk.ru/rdnmarket)."
                        Dependencies.imgui.SetCursorPosX((avail_w - Dependencies.imgui.CalcTextSize(t2).x) / 2)
                        Dependencies.imgui.TextColored(THEME.text_secondary, t2)
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(16)))

                        local gap = D(10)
                        local bw = math.min(Touch(148), (avail_w - gap) / 2)
                        local bh = Touch(52)
                        local total_w = bw * 2 + gap
                        Dependencies.imgui.SetCursorPosX((avail_w - total_w) / 2)

                        Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Button, THEME.accent_primary)
                        Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ButtonHovered, THEME.accent_primary)
                        Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ButtonActive, THEME.accent_primary)
                        if Dependencies.imgui.Button(Dependencies.u8"Ввести ключ", Dependencies.imgui.ImVec2(bw, bh)) then
                            UI.active_tab = 6
                        end
                        Dependencies.imgui.PopStyleColor(3)

                        Dependencies.imgui.SameLine(0, gap)
                        Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Button, Dependencies.imgui.ImVec4(0.25, 0.55, 0.85, 1.0))
                        Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ButtonHovered, Dependencies.imgui.ImVec4(0.30, 0.60, 0.90, 1.0))
                        Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ButtonActive, Dependencies.imgui.ImVec4(0.20, 0.50, 0.80, 1.0))
                        if isTokenPresent() then
                            if Dependencies.imgui.Button(Dependencies.u8"Проверить снова", Dependencies.imgui.ImVec2(bw, bh)) then
                                checkVipStatus(Settings.api_key, 0)
                            end
                        else
                            if Dependencies.imgui.Button(Dependencies.u8"Открыть бота", Dependencies.imgui.ImVec2(bw, bh)) then
                                os.execute('explorer "https://t.me/rdnMarket_bot?start=script"')
                            end
                        end
                        Dependencies.imgui.PopStyleColor(3)
                    end
                    Dependencies.imgui.EndChild()
                    Dependencies.imgui.PopStyleColor()
                elseif not UI.caches_loaded then
                    local w_av = list_w
                    local h_av = content_h - D(32)
                    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(list_x, content_y + D(16)))
                    Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ChildBg, THEME.bg_secondary)
                    if Dependencies.imgui.BeginChild("MarketLoadingDB", Dependencies.imgui.ImVec2(w_av, h_av), true) then
                        local avail_w = Dependencies.imgui.GetContentRegionAvail().x
                        local avail_h = Dependencies.imgui.GetContentRegionAvail().y
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, math.max(D(24), avail_h / 2 - D(20))))
                        local t1 = Dependencies.u8"Загрузка базы предметов..."
                        Dependencies.imgui.SetCursorPosX((avail_w - Dependencies.imgui.CalcTextSize(t1).x) / 2)
                        Dependencies.imgui.TextColored(THEME.accent_primary, t1)
                    end
                    Dependencies.imgui.EndChild()
                    Dependencies.imgui.PopStyleColor()
                elseif isItemDbEmpty() then
                    local w_av = list_w
                    local h_av = content_h - D(32)
                    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(list_x, content_y + D(16)))
                    Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ChildBg, THEME.bg_secondary)
                    if Dependencies.imgui.BeginChild("MarketNoDB", Dependencies.imgui.ImVec2(w_av, h_av), true) then
                        local avail_w = Dependencies.imgui.GetContentRegionAvail().x
                        local avail_h = Dependencies.imgui.GetContentRegionAvail().y
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, math.max(D(24), avail_h / 2 - D(78))))
                        if UI.font_fa then
                            Dependencies.imgui.PushFont(UI.font_fa_large or UI.font_fa)
                            local icon = Dependencies.fa('cloud_arrow_down')
                            local isz = Dependencies.imgui.CalcTextSize(icon)
                            Dependencies.imgui.SetCursorPosX((avail_w - isz.x) / 2)
                            Dependencies.imgui.TextColored(THEME.accent_primary, icon)
                            Dependencies.imgui.PopFont()
                        end
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(8)))
                        local t1 = State.is_downloading_db
                            and Dependencies.u8"Скачивание базы предметов..."
                            or Dependencies.u8"База предметов не скачана"
                        Dependencies.imgui.SetCursorPosX((avail_w - Dependencies.imgui.CalcTextSize(t1).x) / 2)
                        Dependencies.imgui.TextColored(THEME.text_primary, t1)
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(6)))
                        local t2 = Dependencies.u8"Без базы товары в лавках отображаются как Предмет_123."
                        Dependencies.imgui.SetCursorPosX((avail_w - Dependencies.imgui.CalcTextSize(t2).x) / 2)
                        Dependencies.imgui.TextColored(THEME.text_secondary, t2)
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(16)))
                        if not State.is_downloading_db then
                            local bw = math.min(Touch(220), avail_w - D(32))
                            local bh = Touch(52)
                            Dependencies.imgui.SetCursorPosX((avail_w - bw) / 2)
                            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Button, THEME.accent_success)
                            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ButtonHovered, THEME.accent_success)
                            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ButtonActive, THEME.accent_success)
                            if Dependencies.imgui.Button(Dependencies.u8"Скачать базу предметов", Dependencies.imgui.ImVec2(bw, bh)) then
                                api_CheckAndDownloadItemsDB(true)
                            end
                            Dependencies.imgui.PopStyleColor(3)
                        end
                    end
                    Dependencies.imgui.EndChild()
                    Dependencies.imgui.PopStyleColor()
                else
                    local m_delta = drawScrollZone("##scroll_market", list_x + list_w + D(10), content_y + D(16), scroll_w, content_h - D(32), io, dl)

                    Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(list_x, content_y + D(16)))
                    Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ChildBg, Dependencies.imgui.ImVec4(0,0,0,0))
                    if Dependencies.imgui.BeginChild("MarketChild", Dependencies.imgui.ImVec2(list_w, content_h - D(32)), false, Dependencies.imgui.WindowFlags.NoScrollbar) then
                        local c_pos = Dependencies.imgui.GetWindowPos()
                        local c_size = Dependencies.imgui.GetWindowSize()
                        dl:PushClipRect(c_pos, Dependencies.imgui.ImVec2(c_pos.x + c_size.x, c_pos.y + c_size.y), true)
                        
                        if m_delta ~= 0 then Dependencies.imgui.SetScrollY(Dependencies.imgui.GetScrollY() - m_delta) end
                        
                        if StateMarket.is_loading then
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, 50))
                        CenterText(Dependencies.u8"Загрузка лавок с сервера...", THEME.accent_primary, list_w)
                    elseif StateMarket.selected_shop then
                        local shop = StateMarket.selected_shop
                        Dependencies.imgui.PushFont(UI.font_main)
                        
                        local top_bar_h = Touch(56)
                        local compact_market = list_w < D(460)
                        local back_w = compact_market and math.min(D(88), list_w * 0.38) or D(220)
                        local gps_w = compact_market and (list_w - back_w - D(10)) or D(260)
                        if DrawStyledButton("##mkt_back", compact_market and "" or Dependencies.u8"НАЗАД", back_w, top_bar_h, THEME.bg_tertiary, Dependencies.fa('arrow_left'), dl) then StateMarket.selected_shop = nil end
                        Dependencies.imgui.SameLine(nil, compact_market and D(10) or D(20))
                        
                        local gps_btn_col = StateMarket.gps_active and THEME.bg_tertiary or THEME.accent_primary
                        local gps_btn_txt = StateMarket.gps_active and Dependencies.u8"Поиск..." or (compact_market and Dependencies.u8"МЕТКА" or Dependencies.u8"МЕТКА НА ЛАВКУ")
                        if DrawStyledButton("##mkt_gps", gps_btn_txt, gps_w, top_bar_h, gps_btn_col, Dependencies.fa('location_dot'), dl) then
                            if not StateMarket.gps_active then
                                StateMarket.gps_active = true
                                StateMarket.gps_target = shop.nickname:gsub(" ", "_")
                                sampSendChat("/id " .. StateMarket.gps_target)
                                sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Поиск игрока " .. StateMarket.gps_target .. "...", -1)
                            end
                        end
                        
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(22)))
                        local srv_name = getServerDisplayName(shop.serverId)
                        
                        if shop.vip then
                            Dependencies.imgui.PushFont(UI.font_fa_large)
                            Dependencies.imgui.TextColored(Dependencies.imgui.ImVec4(1.0, 0.84, 0.0, 1.0), Dependencies.fa('crown'))
                            Dependencies.imgui.PopFont()
                            Dependencies.imgui.SameLine(nil, D(10))
                        end
                        Dependencies.imgui.SetCursorPosY(Dependencies.imgui.GetCursorPosY() + D(4))
                        Dependencies.imgui.TextColored(shop.vip and Dependencies.imgui.ImVec4(1.0, 0.84, 0.0, 1.0) or THEME.text_primary, Dependencies.u8(shop.nickname .. " | " .. srv_name))
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(16)))
                        
                        if not StateMarket.details_tab then StateMarket.details_tab = 1 end
                        local d_tab_w = list_w / 2
                        local d_tab_h = Touch(64)
                        local d_p = Dependencies.imgui.GetCursorScreenPos()
                        
                        Dependencies.imgui.SetCursorScreenPos(d_p)
                        if Dependencies.imgui.InvisibleButton("##d_tab_sell", Dependencies.imgui.ImVec2(d_tab_w, d_tab_h)) then StateMarket.details_tab = 1 end
                        local is_s_act = StateMarket.details_tab == 1
                        dl:AddRectFilled(d_p, Dependencies.imgui.ImVec2(d_p.x + d_tab_w, d_p.y + d_tab_h), Dependencies.imgui.ColorConvertFloat4ToU32(is_s_act and THEME.bg_tertiary or THEME.bg_secondary), D(8), 1 + 2)
                        local s_txt = Dependencies.u8("В ПРОДАЖЕ (" .. #shop.sell_list .. ")")
                        local s_sz = Dependencies.imgui.CalcTextSize(s_txt)
                        dl:AddText(Dependencies.imgui.ImVec2(d_p.x + (d_tab_w - s_sz.x)/2, d_p.y + (d_tab_h - s_sz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(is_s_act and THEME.text_primary or THEME.text_secondary), s_txt)
                        if is_s_act then dl:AddRectFilled(Dependencies.imgui.ImVec2(d_p.x, d_p.y + d_tab_h - D(4)), Dependencies.imgui.ImVec2(d_p.x + d_tab_w, d_p.y + d_tab_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_success)) end
                        
                        Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(d_p.x + d_tab_w, d_p.y))
                        if Dependencies.imgui.InvisibleButton("##d_tab_buy", Dependencies.imgui.ImVec2(d_tab_w, d_tab_h)) then StateMarket.details_tab = 2 end
                        local is_b_act = StateMarket.details_tab == 2
                        dl:AddRectFilled(Dependencies.imgui.ImVec2(d_p.x + d_tab_w, d_p.y), Dependencies.imgui.ImVec2(d_p.x + list_w, d_p.y + d_tab_h), Dependencies.imgui.ColorConvertFloat4ToU32(is_b_act and THEME.bg_tertiary or THEME.bg_secondary), D(8), 4 + 8)
                        local b_txt = Dependencies.u8("В СКУПКЕ (" .. #shop.buy_list .. ")")
                        local b_sz = Dependencies.imgui.CalcTextSize(b_txt)
                        dl:AddText(Dependencies.imgui.ImVec2(d_p.x + d_tab_w + (d_tab_w - b_sz.x)/2, d_p.y + (d_tab_h - b_sz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(is_b_act and THEME.text_primary or THEME.text_secondary), b_txt)
                        if is_b_act then dl:AddRectFilled(Dependencies.imgui.ImVec2(d_p.x + d_tab_w, d_p.y + d_tab_h - D(4)), Dependencies.imgui.ImVec2(d_p.x + list_w, d_p.y + d_tab_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_primary)) end

                        Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(d_p.x, d_p.y + d_tab_h + D(18)))
                        
                        local current_list = StateMarket.details_tab == 1 and shop.sell_list or shop.buy_list
                        local is_sell = StateMarket.details_tab == 1
                        
                        if #current_list == 0 then
                            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, 50))
                            CenterText(Dependencies.u8"В этой категории товаров нет.", THEME.text_secondary, list_w)
                        else
                            local cols = list_w < D(760) and 1 or 2
                            local spacing = cols == 1 and D(12) or D(20)
                            local card_w = (list_w - spacing * (cols - 1)) / cols
                            local card_h = D(112)
                            local start_pos = Dependencies.imgui.GetCursorScreenPos()
                            
                            local total_rows = math.ceil(#current_list / cols)
                            local clipper = Dependencies.imgui.ImGuiListClipper(total_rows)
                            while clipper:Step() do
                                for row = clipper.DisplayStart, clipper.DisplayEnd - 1 do
                                    for col = 0, cols - 1 do
                                        local i = row * cols + col + 1
                                        if i > #current_list then break end
                                        local item = current_list[i]
                                        local cx = start_pos.x + col * (card_w + spacing)
                                        local cy = start_pos.y + row * (card_h + spacing)
                                        
                                        dl:AddRectFilled(Dependencies.imgui.ImVec2(cx, cy), Dependencies.imgui.ImVec2(cx + card_w, cy + card_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), D(8))
                                        dl:AddRectFilled(Dependencies.imgui.ImVec2(cx, cy), Dependencies.imgui.ImVec2(cx + D(6), cy + card_h), Dependencies.imgui.ColorConvertFloat4ToU32(is_sell and THEME.accent_success or THEME.accent_primary), D(8), 9)
                                        
                                        local icon_sz = D(cols == 1 and 42 or 52)
                                        local icon_x = cx + D(cols == 1 and 14 or 22)
                                        dl:AddCircleFilled(Dependencies.imgui.ImVec2(icon_x + icon_sz/2, cy + D(26) + icon_sz/2), icon_sz/2, Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_tertiary))
                                        Dependencies.imgui.PushFont(UI.font_fa_large)
                                        local ic = is_sell and Dependencies.fa('box') or Dependencies.fa('basket_shopping')
                                        local isz = Dependencies.imgui.CalcTextSize(ic)
                                        dl:AddText(Dependencies.imgui.ImVec2(icon_x + (icon_sz-isz.x)/2, cy + D(26) + (icon_sz-isz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(is_sell and THEME.accent_success or THEME.accent_primary), ic)
                                        Dependencies.imgui.PopFont()
                                        
                                        local text_x = icon_x + icon_sz + D(cols == 1 and 10 or 16)
                                        dl:PushClipRect(Dependencies.imgui.ImVec2(text_x, cy), Dependencies.imgui.ImVec2(cx + card_w - D(10), cy + card_h), true)
                                        dl:AddText(Dependencies.imgui.ImVec2(text_x, cy + D(18)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_primary), Dependencies.u8(item.name))
                                        dl:PopClipRect()
                                        
                                        local price_color = is_sell and THEME.accent_success or THEME.accent_primary
                                        local price_width = drawMoney(dl, text_x, cy + D(48), item.price, price_color)
                                        local quantity_text = Dependencies.u8(tostring(math.floor(tonumber(item.amount) or 1)) .. " шт.")
                                        dl:AddText(Dependencies.imgui.ImVec2(text_x + price_width + D(6), cy + D(48)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_secondary), quantity_text)
                                    end
                                end
                            end
                            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, total_rows * (card_h + spacing) + 20))
                        end
                        Dependencies.imgui.PopFont()
                    else
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, 15))
                        if #StateMarket.shops_list == 0 then
                            Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, 50))
                            Dependencies.imgui.PushFont(UI.font_main)
                            CenterText(Dependencies.u8"Нет активных лавок. Нажмите ОБНОВИТЬ СПИСОК внизу.", THEME.text_secondary, list_w)
                            Dependencies.imgui.PopFont()
                        else
                            local search_q = current_search_str
                            Dependencies.imgui.PushFont(UI.font_main)
                            
                            if search_q ~= "" then
                                local cache_key = search_q .. ":" .. StateMarket.server_filter_idx
                                if StateMarket.search_cache_key ~= cache_key then
                                    UI.market_search_results_sell, UI.market_search_results_buy = searchMarketplaceItems(search_q)
                                    StateMarket.search_cache_key = cache_key
                                end

                                if #UI.market_search_results_sell == 0 and #UI.market_search_results_buy == 0 then
                                    Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, 50))
                                    CenterText(Dependencies.u8"Товары не найдены.", THEME.text_secondary, list_w)
                                else
                                    local results_sell = UI.market_search_results_sell
                                    local results_buy = UI.market_search_results_buy
                                    
                                    local start_pos = Dependencies.imgui.GetCursorScreenPos()
                                    local seg_w = list_w
                                    local seg_h = Touch(56)
                                    
                                    dl:AddRectFilled(Dependencies.imgui.ImVec2(start_pos.x, start_pos.y), Dependencies.imgui.ImVec2(start_pos.x + seg_w, start_pos.y + seg_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), D(8))
                                    dl:AddRect(Dependencies.imgui.ImVec2(start_pos.x, start_pos.y), Dependencies.imgui.ImVec2(start_pos.x + seg_w, start_pos.y + seg_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), D(8), 15, D(1.5))

                                    if not StateMarket.search_sub_tab then StateMarket.search_sub_tab = 1 end
                                    local half_w = seg_w / 2
                                    local sell_label = list_w < D(460) and ("ПРОДАЖА " .. #results_sell) or ("В ПРОДАЖЕ (" .. #results_sell .. ")")
                                    local buy_label = list_w < D(460) and ("СКУПКА " .. #results_buy) or ("В СКУПКЕ (" .. #results_buy .. ")")
                                    drawMarketSearchSegmentButton(1, sell_label, true, start_pos, half_w, seg_h, dl)
                                    drawMarketSearchSegmentButton(2, buy_label, false, start_pos, half_w, seg_h, dl)
                                    
                                    local list_start_y = start_pos.y + seg_h + 20.0
                                    local current_res = StateMarket.search_sub_tab == 1 and results_sell or results_buy
                                    local item_card_h = D(list_w < D(760) and 104 or 112)
                                    local spacing = D(12)
                                    local card_w = list_w
                                    
                                    local clipper = Dependencies.imgui.ImGuiListClipper(#current_res)
                                    while clipper:Step() do
                                        for i = clipper.DisplayStart + 1, clipper.DisplayEnd do
                                            local res = current_res[i]
                                            local cy = list_start_y + (i - 1) * (item_card_h + spacing)
                                            drawMarketSearchCard(res, i, start_pos.x, cy, card_w, item_card_h, dl)
                                        end
                                    end
                                    Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, seg_h + 20.0 + #current_res * (item_card_h + spacing) + 20))
                                end
                            else
                                local filtered_shops = {}
                                for _, shop in ipairs(StateMarket.shops_list) do
                                    local pass_srv = false
                                    if StateMarket.server_filter_idx == 0 then pass_srv = true
                                    elseif StateMarket.server_filter_idx > 0 and shop.serverId == UI.RODINA_SERVERS_DATA[StateMarket.server_filter_idx].id then pass_srv = true end
                                    if pass_srv then table.insert(filtered_shops, shop) end
                                end
                                table.sort(filtered_shops, function(a, b)
                                    if a.vip ~= b.vip then return a.vip end
                                    return a.nickname < b.nickname
                                end)
                                
                                if #filtered_shops == 0 then
                                    Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, 50))
                                    CenterText(Dependencies.u8"На этом сервере нет лавок.", THEME.text_secondary, list_w)
                                else
                                    local cols = list_w < D(760) and 1 or 2
                                    local spacing = cols == 1 and D(12) or D(20)
                                    local card_w = (list_w - spacing * (cols - 1)) / cols
                                    local card_h = D(148)
                                    local start_pos = Dependencies.imgui.GetCursorScreenPos()
                                    local total_rows = math.ceil(#filtered_shops / cols)
                                    
                                    local clipper = Dependencies.imgui.ImGuiListClipper(total_rows)
                                    while clipper:Step() do
                                        for row = clipper.DisplayStart, clipper.DisplayEnd - 1 do
                                            for col = 0, cols - 1 do
                                                local i = row * cols + col + 1
                                                if i > #filtered_shops then break end
                                                local shop = filtered_shops[i]
                                                local cx = start_pos.x + col * (card_w + spacing)
                                                local cy = start_pos.y + row * (card_h + spacing)
                                                
                                                Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(cx, cy))
                                                if Dependencies.imgui.InvisibleButton("##shop_grid_"..i, Dependencies.imgui.ImVec2(card_w, card_h)) then StateMarket.selected_shop = shop end
                                                
                                                local bg_col = Dependencies.imgui.IsItemActive() and THEME.bg_tertiary or THEME.bg_secondary
                                                local border_col = THEME.border
                                                if shop.vip then 
                                                    bg_col = Dependencies.imgui.ImVec4(0.25, 0.20, 0.05, 1.0)
                                                    border_col = Dependencies.imgui.ImVec4(1.0, 0.84, 0.0, 0.8)
                                                end
                                                
                                                dl:AddRectFilled(Dependencies.imgui.ImVec2(cx, cy), Dependencies.imgui.ImVec2(cx + card_w, cy + card_h), Dependencies.imgui.ColorConvertFloat4ToU32(bg_col), D(8))
                                                dl:AddRect(Dependencies.imgui.ImVec2(cx, cy), Dependencies.imgui.ImVec2(cx + card_w, cy + card_h), Dependencies.imgui.ColorConvertFloat4ToU32(border_col), D(8), 15, shop.vip and D(2) or D(1.5))
                                                
                                                Dependencies.imgui.PushFont(UI.font_fa_large)
                                                local icon_col = shop.vip and Dependencies.imgui.ImVec4(1.0, 0.84, 0.0, 1.0) or THEME.accent_primary
                                                local shop_icon = shop.vip and Dependencies.fa('crown') or Dependencies.fa('store')
                                                local icon_sz = D(46)
                                                local icon_x = cx + D(16)
                                                local icon_y = cy + D(18)
                                                local text_x = cx + D(76)
                                                dl:AddCircleFilled(Dependencies.imgui.ImVec2(icon_x + icon_sz / 2, icon_y + icon_sz / 2), icon_sz / 2, Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_tertiary))
                                                local shop_icon_size = Dependencies.imgui.CalcTextSize(shop_icon)
                                                dl:AddText(Dependencies.imgui.ImVec2(icon_x + (icon_sz - shop_icon_size.x) / 2, icon_y + (icon_sz - shop_icon_size.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(icon_col), shop_icon)
                                                Dependencies.imgui.PopFont()
                                                
                                                dl:PushClipRect(Dependencies.imgui.ImVec2(text_x, cy), Dependencies.imgui.ImVec2(cx + card_w - D(10), cy + card_h), true)
                                                dl:AddText(Dependencies.imgui.ImVec2(text_x, cy + D(15)), Dependencies.imgui.ColorConvertFloat4ToU32(shop.vip and icon_col or THEME.text_primary), Dependencies.u8(shop.nickname))
                                                dl:AddText(Dependencies.imgui.ImVec2(text_x, cy + D(47)), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.text_secondary), Dependencies.u8(getServerDisplayName(shop.serverId)))
                                                dl:PopClipRect()

                                                local badge_y = cy + D(91)
                                                local badge_gap = D(10)
                                                local badge_w = (card_w - (text_x - cx) - D(20) - badge_gap) / 2
                                                local badge_h = Touch(42)
                                                local badges = {
                                                    { x = text_x, label = Dependencies.u8("Продажа " .. tostring(shop.sell_count)), color = THEME.accent_success },
                                                    { x = text_x + badge_w + badge_gap, label = Dependencies.u8("Скупка " .. tostring(shop.buy_count)), color = THEME.accent_primary }
                                                }
                                                for _, badge in ipairs(badges) do
                                                    dl:AddRectFilled(Dependencies.imgui.ImVec2(badge.x, badge_y), Dependencies.imgui.ImVec2(badge.x + badge_w, badge_y + badge_h), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.ImVec4(badge.color.x, badge.color.y, badge.color.z, 0.13)), D(8))
                                                    local badge_size = Dependencies.imgui.CalcTextSize(badge.label)
                                                    dl:AddText(Dependencies.imgui.ImVec2(badge.x + (badge_w - badge_size.x) / 2, badge_y + (badge_h - badge_size.y) / 2), Dependencies.imgui.ColorConvertFloat4ToU32(badge.color), badge.label)
                                                end
                                            end
                                        end
                                    end
                                    Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, total_rows * (card_h + spacing) + 20))
                                end
                            end
                            Dependencies.imgui.PopFont()
                        end
                    end
                    dl:PopClipRect()
                end
                Dependencies.imgui.EndChild()
                Dependencies.imgui.PopStyleColor()
                end

            elseif UI.active_tab == 7 then
                renderArbitrageTab(list_x, list_w, content_y, content_h, scroll_w, current_search_str, io, dl)
            elseif UI.active_tab == 5 or UI.active_tab == 6 then
                local delta = drawScrollZone("##scroll_pr_sets", list_x + list_w + D(10), content_y + D(16), scroll_w, content_h - D(32), io, dl)

                Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(list_x, content_y + D(16)))
                Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.ChildBg, Dependencies.imgui.ImVec4(0,0,0,0))
                
                if UI.active_tab == 5 then
                    if Dependencies.imgui.BeginChild("AutoPRChild", Dependencies.imgui.ImVec2(list_w, content_h - D(32)), false, Dependencies.imgui.WindowFlags.NoScrollbar) then
                        local c_pos = Dependencies.imgui.GetWindowPos()
                        local c_size = Dependencies.imgui.GetWindowSize()
                        dl:PushClipRect(c_pos, Dependencies.imgui.ImVec2(c_pos.x + c_size.x, c_pos.y + c_size.y), true)
                        
                        if delta ~= 0 then Dependencies.imgui.SetScrollY(Dependencies.imgui.GetScrollY() - delta) end
                        Dependencies.imgui.PushFont(UI.font_main)
                        
                        local is_pr_active = Settings.auto_pr.active
                        local btn_w = (list_w - D(24)) / 2
                        
                        if DrawStyledButton("##pr_main_btn", is_pr_active and Dependencies.u8"ОСТАНОВИТЬ ПИАР" or Dependencies.u8"ЗАПУСТИТЬ ПИАР", btn_w, Touch(68), is_pr_active and THEME.accent_danger or THEME.accent_success, is_pr_active and Dependencies.fa('stop') or Dependencies.fa('play'), dl) then
                            Settings.auto_pr.active = not Settings.auto_pr.active
                            if Settings.auto_pr.active then
                                local now = os.time()
                                for i, item in ipairs(Settings.auto_pr.items) do item.next_send = now + 2 + i end
                                sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Авто-пиар запущен!", -1)
                            else
                                State.auto_pr.pending_vr_response = false
                                sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Авто-пиар остановлен!", -1)
                            end
                            saveJsonFile(UI.PATH_SETTINGS, Settings)
                        end
                        
                        Dependencies.imgui.SameLine(nil, D(16))
                        if DrawStyledButton("##pr_add_btn", Dependencies.u8"ДОБАВИТЬ ФРАЗУ", btn_w, Touch(68), THEME.accent_primary, Dependencies.fa('plus'), dl) then
                            table.insert(Settings.auto_pr.items, { text = "", channel = 1, delay = 60, active = true, next_send = 0 })
                            saveJsonFile(UI.PATH_SETTINGS, Settings)
                        end
                        
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(24)))
                        
                        for i, item in ipairs(Settings.auto_pr.items) do
                            local p_item = Dependencies.imgui.GetCursorScreenPos()
                            local item_h = D(160)
                            dl:AddRectFilled(p_item, Dependencies.imgui.ImVec2(p_item.x + list_w, p_item.y + item_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), D(8))

                            local top_y = p_item.y + D(14)
                            local inner_w = list_w - D(32)
                            local start_x = p_item.x + D(16)
                            
                            local t_p = Dependencies.imgui.ImVec2(start_x, top_y)
                            Dependencies.imgui.SetCursorScreenPos(t_p)
                            if Dependencies.imgui.InvisibleButton("##pr_act_"..i, Dependencies.imgui.ImVec2(Touch(48), Touch(48))) then
                                item.active = not item.active
                                if item.active and Settings.auto_pr.active then item.next_send = os.time() + 2 end
                                saveJsonFile(UI.PATH_SETTINGS, Settings)
                            end
                            dl:AddRectFilled(t_p, Dependencies.imgui.ImVec2(t_p.x + Touch(48), t_p.y + Touch(48)), Dependencies.imgui.ColorConvertFloat4ToU32(item.active and THEME.accent_success or THEME.bg_main), D(8))
                            if item.active then
                                Dependencies.imgui.PushFont(UI.font_fa_large)
                                local check_sz = Dependencies.imgui.CalcTextSize(Dependencies.fa('check'))
                                dl:AddText(Dependencies.imgui.ImVec2(t_p.x + (Touch(48) - check_sz.x)/2, t_p.y + (Touch(48) - check_sz.y)/2), 0xFFFFFFFF, Dependencies.fa('check'))
                                Dependencies.imgui.PopFont()
                            end
                            
                            local ch_names = {"VR", "/b", "/s", "Chat", "/fam", "/al"}
                            local ch_colors = {0xFF00AAFF, 0xFFCCCCCC, 0xFFFFFFFF, 0xFF66FF66, 0xFFFFFF00, 0xFF00FFFF}
                            local curr_ch = item.channel or 1
                            
                            local ch_w = Touch(96)
                            local ch_p = Dependencies.imgui.ImVec2(t_p.x + Touch(48) + D(10), top_y)
                            Dependencies.imgui.SetCursorScreenPos(ch_p)
                            if Dependencies.imgui.InvisibleButton("##pr_ch_"..i, Dependencies.imgui.ImVec2(ch_w, Touch(48))) then
                                item.channel = (item.channel % 6) + 1
                                saveJsonFile(UI.PATH_SETTINGS, Settings)
                            end
                            dl:AddRect(ch_p, Dependencies.imgui.ImVec2(ch_p.x + ch_w, ch_p.y + Touch(48)), ch_colors[curr_ch], D(8), 15, D(2))
                            local ch_txt = ch_names[curr_ch]
                            local ctx_sz = Dependencies.imgui.CalcTextSize(ch_txt)
                            dl:AddText(Dependencies.imgui.ImVec2(ch_p.x + (ch_w - ctx_sz.x)/2, ch_p.y + (Touch(48) - ctx_sz.y)/2), ch_colors[curr_ch], ch_txt)
                            
                            local trash_sz = Touch(48)
                            local del_btn_p = Dependencies.imgui.ImVec2(start_x + inner_w - trash_sz, top_y)
                            
                            local del_w = inner_w - (Touch(48) + D(10) + ch_w + D(10) + D(10) + trash_sz)
                            if del_w < Touch(80) then del_w = Touch(80) end
                            local del_p = Dependencies.imgui.ImVec2(ch_p.x + ch_w + D(10), top_y)
                            
                            Dependencies.imgui.SetCursorScreenPos(del_p)
                            Dependencies.imgui.SetNextItemWidth(del_w)
                            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.FrameBg, THEME.bg_tertiary)
                            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Text, THEME.text_primary)
                            Dependencies.imgui.PushStyleVarVec2(Dependencies.imgui.StyleVar.FramePadding, Dependencies.imgui.ImVec2(D(12), (Touch(48) - Dependencies.imgui.GetFontSize()) / 2))
                            if Dependencies.imgui.InputText("##pr_del_"..i, getPRDelayBuffer(i, item.delay), 32, Dependencies.imgui.InputTextFlags.CharsDecimal) then
                                item.delay = tonumber(Dependencies.ffi.string(getPRDelayBuffer(i))) or 60
                                saveJsonFile(UI.PATH_SETTINGS, Settings)
                            end
                            Dependencies.imgui.PopStyleVar()
                            Dependencies.imgui.PopStyleColor(2)
                            
                            Dependencies.imgui.SetCursorScreenPos(del_btn_p)
                            if Dependencies.imgui.InvisibleButton("##pr_trash_"..i, Dependencies.imgui.ImVec2(trash_sz, trash_sz)) then
                                table.remove(Settings.auto_pr.items, i)
                                saveJsonFile(UI.PATH_SETTINGS, Settings)
                                break
                            end
                            dl:AddRectFilled(del_btn_p, Dependencies.imgui.ImVec2(del_btn_p.x + trash_sz, del_btn_p.y + trash_sz), Dependencies.imgui.ColorConvertFloat4ToU32(Dependencies.imgui.IsItemHovered() and THEME.bg_main or THEME.bg_tertiary), D(8))
                            Dependencies.imgui.PushFont(UI.font_fa_large)
                            local tr_sz = Dependencies.imgui.CalcTextSize(Dependencies.fa('trash'))
                            dl:AddText(Dependencies.imgui.ImVec2(del_btn_p.x + (trash_sz - tr_sz.x)/2, del_btn_p.y + (trash_sz - tr_sz.y)/2), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.accent_danger), Dependencies.fa('trash'))
                            Dependencies.imgui.PopFont()
                            
                            Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(start_x, top_y + Touch(48) + D(10)))
                            Dependencies.imgui.SetNextItemWidth(inner_w)
                            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.FrameBg, THEME.bg_tertiary)
                            Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Text, THEME.text_primary)
                            Dependencies.imgui.PushStyleVarVec2(Dependencies.imgui.StyleVar.FramePadding, Dependencies.imgui.ImVec2(D(16), (Touch(48) - Dependencies.imgui.GetFontSize()) / 2))
                            if Dependencies.imgui.InputText("##pr_txt_"..i, getPRBuffer(i, item.text), 256) then
                                item.text = Dependencies.ffi.string(getPRBuffer(i))
                                saveJsonFile(UI.PATH_SETTINGS, Settings)
                            end
                            Dependencies.imgui.PopStyleVar()
                            Dependencies.imgui.PopStyleColor(2)
                            
                            Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(p_item.x, p_item.y + item_h + D(12)))
                        end
                        Dependencies.imgui.PopFont()
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(16)))
                        dl:PopClipRect()
                    end
                    Dependencies.imgui.EndChild()
                elseif UI.active_tab == 6 then
                    if Dependencies.imgui.BeginChild("SettingsChild", Dependencies.imgui.ImVec2(list_w, content_h - D(20)), false, Dependencies.imgui.WindowFlags.NoScrollbar) then
                        local c_pos = Dependencies.imgui.GetWindowPos()
                        local c_size = Dependencies.imgui.GetWindowSize()
                        dl:PushClipRect(c_pos, Dependencies.imgui.ImVec2(c_pos.x + c_size.x, c_pos.y + c_size.y), true)
                        
                        if delta ~= 0 then Dependencies.imgui.SetScrollY(Dependencies.imgui.GetScrollY() - delta) end
                        Dependencies.imgui.PushFont(UI.font_main)
                        
                        Dependencies.imgui.PushStyleVarVec2(Dependencies.imgui.StyleVar.FramePadding, Dependencies.imgui.ImVec2(D(20), D(22)))
                        Dependencies.imgui.PushStyleVarVec2(Dependencies.imgui.StyleVar.ItemSpacing, Dependencies.imgui.ImVec2(D(10), D(24)))
                        
                        Dependencies.imgui.TextColored(THEME.accent_primary, Dependencies.u8"АВТОМАТИЗАЦИЯ ЛАВКИ")
                        
                        local t_p = Dependencies.imgui.GetCursorScreenPos()
                        if Dependencies.imgui.InvisibleButton("##cb_auto_name", Dependencies.imgui.ImVec2(Touch(52), Touch(52))) then
                            UI.b_auto_name[0] = not UI.b_auto_name[0]
                            Settings.auto_name = UI.b_auto_name[0]
                            saveJsonFile(UI.PATH_SETTINGS, Settings)
                        end
                        local cb_bg = UI.b_auto_name[0] and THEME.accent_success or (Dependencies.imgui.IsItemHovered() and Dependencies.imgui.ImVec4(1,1,1,0.1) or THEME.bg_tertiary)
                        dl:AddRectFilled(t_p, Dependencies.imgui.ImVec2(t_p.x + Touch(52), t_p.y + Touch(52)), Dependencies.imgui.ColorConvertFloat4ToU32(cb_bg), D(8))
                        if UI.b_auto_name[0] then
                            Dependencies.imgui.PushFont(UI.font_fa_large)
                            local isz = Dependencies.imgui.CalcTextSize(Dependencies.fa('check'))
                            dl:AddText(Dependencies.imgui.ImVec2(t_p.x + (Touch(52) - isz.x)/2, t_p.y + (Touch(52) - isz.y)/2), 0xFFFFFFFF, Dependencies.fa('check'))
                            Dependencies.imgui.PopFont()
                        end
                        
                        Dependencies.imgui.SameLine(nil, D(20))
                        Dependencies.imgui.SetCursorPosY(Dependencies.imgui.GetCursorPosY() + D(16))
                        Dependencies.imgui.Text(Dependencies.u8"Автоматически вводить название")
                        
                        Dependencies.imgui.TextColored(THEME.text_secondary, Dependencies.u8"Желаемое название лавки:")
                        Dependencies.imgui.PushItemWidth(list_w)
                        Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.FrameBg, THEME.bg_tertiary)
                        Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Text, THEME.text_primary)
                        if Dependencies.imgui.InputText("##shopname", UI.buf_shop_name, 64) then
                            Settings.shop_name = Dependencies.ffi.string(UI.buf_shop_name)
                            saveJsonFile(UI.PATH_SETTINGS, Settings)
                        end
                        Dependencies.imgui.PopStyleColor(2)
                        Dependencies.imgui.PopItemWidth()
                        
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, D(24)))
                        
                        Dependencies.imgui.TextColored(THEME.accent_primary, Dependencies.u8"УВЕДОМЛЕНИЯ ТЕЛЕГРАМ / ВК")
                        
                        Dependencies.imgui.TextColored(THEME.text_secondary, Dependencies.u8"Секретный ключ (из бота RMarket):")
                        Dependencies.imgui.PushItemWidth(list_w)
                        Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.FrameBg, THEME.bg_tertiary)
                        Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.Text, THEME.text_primary)
                        if Dependencies.imgui.InputText("##apikey", UI.buf_api_key, 128, Dependencies.imgui.InputTextFlags.Password) then
                            local next_token = Dependencies.ffi.string(UI.buf_api_key):match("^%s*(.-)%s*$") or ""
                            if next_token ~= Settings.api_key then
                                Settings.api_key = next_token
                                ApiState.checking = false
                                ApiState.key_valid = false
                                ApiState.key_checked = false
                                ApiState.is_vip = false
                                ApiState.server_vip_verified = false
                                ApiState.vip_checking_in_progress = false
                                ApiState.authenticated_loads_started = false
                                ApiState.pending_manual_price_download = false
                                ApiState.token_state = (#next_token >= 16) and "checking" or "missing"
                                State.pending_test_tg = nil
                                Tasks.remove_by_name("tg_stats_wait")
                                Tasks.remove_by_name("key_verify_retry")
                                Tasks.remove_by_name("saved_token_verify_retry")
                                saveJsonFile(UI.PATH_SETTINGS, Settings)
                            end
                        end
                        Dependencies.imgui.PopStyleColor(2)
                        Dependencies.imgui.PopItemWidth()
                        
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, 20))
                        if DrawStyledButton("##test_tg", Dependencies.u8"ПРОВЕРИТЬ КЛЮЧ", list_w, Touch(56), THEME.accent_primary, Dependencies.fa('paper_plane'), dl) then
                            if Settings.api_key ~= "" then
                                api_TestTelegramToken()
                            else
                                sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Введите ключ перед проверкой!", -1)
                            end
                        end
                        
                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, 30))
                        Dependencies.imgui.TextColored(THEME.accent_primary, Dependencies.u8"ЗАДЕРЖКА ВЫСТАВЛЕНИЯ")
                        Dependencies.imgui.TextColored(THEME.text_secondary, Dependencies.u8"Пауза между товарами в лавке (мс):")
                        
                        Dependencies.imgui.PushItemWidth(list_w)
                        Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.FrameBg, THEME.bg_tertiary)
                        Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.SliderGrab, THEME.accent_primary)
                        Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.SliderGrabActive, THEME.accent_success)
                        if Dependencies.imgui.SliderInt("##trade_delay_slider", UI.sl_delay, 100, 3000, "%d ms") then
                            Settings.trade_delay = UI.sl_delay[0]
                            saveJsonFile(UI.PATH_SETTINGS, Settings)
                        end
                        Dependencies.imgui.PopStyleColor(3)
						Dependencies.imgui.PopItemWidth()

						Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, 30))
						Dependencies.imgui.TextColored(THEME.accent_primary, Dependencies.u8"РАЗМЕР ОКНА И МАСШТАБ")

						Dependencies.imgui.TextColored(THEME.text_secondary, Dependencies.u8"Ширина окна:")
						Dependencies.imgui.PushItemWidth(list_w)
						Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.FrameBg, THEME.bg_tertiary)
						Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.SliderGrab, THEME.accent_primary)
						Dependencies.imgui.PushStyleColor(Dependencies.imgui.Col.SliderGrabActive, THEME.accent_success)
						if Dependencies.imgui.SliderInt("##win_w_slider", UI.sl_win_w, 50, 100, "%d%%") then
							Settings.win_w_percent = UI.sl_win_w[0] / 100.0
							saveJsonFile(UI.PATH_SETTINGS, Settings)
						end

						Dependencies.imgui.TextColored(THEME.text_secondary, Dependencies.u8"Высота окна:")
						if Dependencies.imgui.SliderInt("##win_h_slider", UI.sl_win_h, 50, 100, "%d%%") then
							Settings.win_h_percent = UI.sl_win_h[0] / 100.0
							saveJsonFile(UI.PATH_SETTINGS, Settings)
						end

						Dependencies.imgui.TextColored(THEME.text_secondary, Dependencies.u8"Масштаб интерфейса (шрифт и элементы):")
						if Dependencies.imgui.SliderInt("##ui_scale_slider", UI.sl_ui_scale, 55, 180, "%d%%") then
							Settings.ui_scale = UI.sl_ui_scale[0] / 100.0
							saveJsonFile(UI.PATH_SETTINGS, Settings)
						end
						Dependencies.imgui.PopStyleColor(3)
						Dependencies.imgui.PopItemWidth()

						Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, 30))
						Dependencies.imgui.TextColored(THEME.accent_primary, Dependencies.u8"ИНТЕРФЕЙС")
                        
                        local hud_p = Dependencies.imgui.GetCursorScreenPos()
                        if Dependencies.imgui.InvisibleButton("##cb_show_hud", Dependencies.imgui.ImVec2(Touch(52), Touch(52))) then
                            UI.b_show_hud[0] = not UI.b_show_hud[0]
                            Settings.show_live_hud = UI.b_show_hud[0]
                            saveJsonFile(UI.PATH_SETTINGS, Settings)
                        end
                        local hud_bg = UI.b_show_hud[0] and THEME.accent_success or (Dependencies.imgui.IsItemHovered() and Dependencies.imgui.ImVec4(1,1,1,0.1) or THEME.bg_tertiary)
                        dl:AddRectFilled(hud_p, Dependencies.imgui.ImVec2(hud_p.x + Touch(52), hud_p.y + Touch(52)), Dependencies.imgui.ColorConvertFloat4ToU32(hud_bg), D(8))
                        if UI.b_show_hud[0] then
                            Dependencies.imgui.PushFont(UI.font_fa_large)
                            local isz = Dependencies.imgui.CalcTextSize(Dependencies.fa('check'))
                            dl:AddText(Dependencies.imgui.ImVec2(hud_p.x + (Touch(52) - isz.x)/2, hud_p.y + (Touch(52) - isz.y)/2), 0xFFFFFFFF, Dependencies.fa('check'))
                            Dependencies.imgui.PopFont()
                        end
                        
                        Dependencies.imgui.SameLine(nil, D(20))
                        Dependencies.imgui.SetCursorPosY(Dependencies.imgui.GetCursorPosY() + 15)
                        Dependencies.imgui.BeginGroup()
                        Dependencies.imgui.Text(Dependencies.u8"RMarket Live (HUD Прибыли)")
                        Dependencies.imgui.TextColored(THEME.text_secondary, Dependencies.u8"Виджет дохода на экране")
                        Dependencies.imgui.EndGroup()

                        Dependencies.imgui.Dummy(Dependencies.imgui.ImVec2(0, 10))

                        local float_p = Dependencies.imgui.GetCursorScreenPos()
                        if Dependencies.imgui.InvisibleButton("##cb_show_float", Dependencies.imgui.ImVec2(Touch(52), Touch(52))) then
                            UI.b_show_float[0] = not UI.b_show_float[0]
                            Settings.show_float_btn = UI.b_show_float[0]
                            saveJsonFile(UI.PATH_SETTINGS, Settings)
                        end
                        local float_bg = UI.b_show_float[0] and THEME.accent_success or (Dependencies.imgui.IsItemHovered() and Dependencies.imgui.ImVec4(1,1,1,0.1) or THEME.bg_tertiary)
                        dl:AddRectFilled(float_p, Dependencies.imgui.ImVec2(float_p.x + Touch(52), float_p.y + Touch(52)), Dependencies.imgui.ColorConvertFloat4ToU32(float_bg), D(8))
                        if UI.b_show_float[0] then
                            Dependencies.imgui.PushFont(UI.font_fa_large)
                            local isz = Dependencies.imgui.CalcTextSize(Dependencies.fa('check'))
                            dl:AddText(Dependencies.imgui.ImVec2(float_p.x + (Touch(52) - isz.x)/2, float_p.y + (Touch(52) - isz.y)/2), 0xFFFFFFFF, Dependencies.fa('check'))
                            Dependencies.imgui.PopFont()
                        end
                        
                        Dependencies.imgui.SameLine(nil, D(20))
                        Dependencies.imgui.SetCursorPosY(Dependencies.imgui.GetCursorPosY() + D(10))
                        Dependencies.imgui.BeginGroup()
                        Dependencies.imgui.Text(Dependencies.u8"Плавающая кнопка")
                        Dependencies.imgui.TextColored(THEME.text_secondary, Dependencies.u8"Кнопка быстрого доступа на экране")
                        Dependencies.imgui.EndGroup()
                        
                        Dependencies.imgui.PopStyleVar(2)
                        Dependencies.imgui.PopFont()
                        dl:PopClipRect()
                    end
                    Dependencies.imgui.EndChild()
                end
                Dependencies.imgui.PopStyleColor()
            end

            if footer_h > 0 then
            local footer_y = p.y + win_h - footer_h
            dl:AddRectFilled(Dependencies.imgui.ImVec2(c_x, footer_y), Dependencies.imgui.ImVec2(c_x + c_w, p.y + win_h), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.bg_secondary), D(8), 4)
            dl:AddLine(Dependencies.imgui.ImVec2(c_x, footer_y), Dependencies.imgui.ImVec2(c_x + c_w, footer_y), Dependencies.imgui.ColorConvertFloat4ToU32(THEME.border), 2.0)
            
            local btn_h = Touch(60)
            local btn_w = c_w - D(40)
            local btn_x = c_x + D(20)
            local btn_y = footer_y + (footer_h - btn_h) / 2
            
            Dependencies.imgui.SetCursorScreenPos(Dependencies.imgui.ImVec2(btn_x, btn_y))
            if Dependencies.imgui.InvisibleButton("##main_action_btn", Dependencies.imgui.ImVec2(btn_w, btn_h)) then
                if UI.active_tab == 1 then
                    if #UI.config_sell == 0 then sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Список на продажу пуст!", -1) else
                        State.selling = { active = true, stage = 'waiting_dialog', current_idx = 1, total = #UI.config_sell, current_item = nil }
                        sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Откройте лавку для выставления товаров!", -1)
                        UI.win_state[0] = false
                    end
                elseif UI.active_tab == 2 then
                    if #UI.config_buy == 0 then sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Список на скупку пуст!", -1) else
                        State.buying = { active = true, stage = 'waiting_dialog', current_idx = 1, total = #UI.config_buy, current_item = nil }
                        sampAddChatMessage("{5CB85C}[RMarket] {FFFFFF}Откройте лавку для выставления товаров на скупку!", -1)
                        UI.win_state[0] = false
                    end
                elseif UI.active_tab == 3 then LogsState.cached_income, LogsState.cached_expense = updateLogView()
                elseif UI.active_tab == 4 then api_FetchMarketList()
                elseif UI.active_tab == 7 then api_FetchArbitrage(false) end
            end
            
            local base_btn_col = THEME.bg_tertiary
            if UI.active_tab == 1 then base_btn_col = THEME.accent_success
            elseif UI.active_tab == 2 then base_btn_col = THEME.accent_primary end
            local btn_color = Dependencies.imgui.IsItemActive() and Dependencies.imgui.ImVec4(base_btn_col.x*0.8, base_btn_col.y*0.8, base_btn_col.z*0.8, 1.0) or base_btn_col
            dl:AddRectFilled(Dependencies.imgui.ImVec2(btn_x, btn_y), Dependencies.imgui.ImVec2(btn_x + btn_w, btn_y + btn_h), Dependencies.imgui.ColorConvertFloat4ToU32(btn_color), D(8))
            
            local action_txt, action_icon = "", ""
            if UI.active_tab == 1 then action_txt, action_icon = Dependencies.u8"ВЫСТАВИТЬ ТОВАРЫ НА ПРОДАЖУ", Dependencies.fa('paper_plane')
            elseif UI.active_tab == 2 then action_txt, action_icon = Dependencies.u8"НАЧАТЬ СКУПКУ", Dependencies.fa('shop')
            elseif UI.active_tab == 3 then action_txt, action_icon = Dependencies.u8"ОБНОВИТЬ ИСТОРИЮ", Dependencies.fa('arrows_rotate')
            elseif UI.active_tab == 4 then action_txt, action_icon = Dependencies.u8"ОБНОВИТЬ СПИСОК ЛАВОК", Dependencies.fa('arrows_rotate')
            elseif UI.active_tab == 7 then action_txt, action_icon = Dependencies.u8"ОБНОВИТЬ АРБИТРАЖ", Dependencies.fa('arrows_rotate') end
            
            Dependencies.imgui.PushFont(UI.font_fa_large)
            local a_isz = Dependencies.imgui.CalcTextSize(action_icon)
            Dependencies.imgui.PopFont()
            Dependencies.imgui.PushFont(UI.font_main)
            local a_tsz = Dependencies.imgui.CalcTextSize(action_txt)
            local center_ax = btn_x + (btn_w - (a_isz.x + 20 + a_tsz.x)) / 2
            
            Dependencies.imgui.PushFont(UI.font_fa_large)
            dl:AddText(Dependencies.imgui.ImVec2(center_ax, btn_y + (btn_h - a_isz.y)/2), 0xFFFFFFFF, action_icon)
            Dependencies.imgui.PopFont()
            dl:AddText(Dependencies.imgui.ImVec2(center_ax + a_isz.x + 20, btn_y + (btn_h - a_tsz.y)/2), 0xFFFFFFFF, action_txt)
            Dependencies.imgui.PopFont()
            
            end
            end

        end
        Dependencies.imgui.End()
    end

    Dependencies.imgui.OnFrame(function() return true end, function() Interface() end)

function api_TestTelegramToken()
    if not isTokenPresent() then
        sampAddChatMessage("{D9534F}[RMarket] {FFFFFF}Введите ключ перед проверкой!", -1)
        return
    end
    sampAddChatMessage("{F0AD4E}[RMarket] {FFFFFF}Проверка и привязка ключа...", -1)
    checkApiKey(Settings.api_key, nil, {})
end

function main()
    while not isSampAvailable() do wait(100) end
    collectgarbage("setpause", 250)
    collectgarbage("setstepmul", 200)
    startStartupCacheLoad()
    while not sampIsLocalPlayerSpawned() do wait(100) end

    checkForUpdates()
    loadSessionToken()
    loadLiveShopState()

    local ip, port = sampGetCurrentServerAddress()
    local my_srv_id = normalizeServerId(ip .. ":" .. port)
    for i, srv in ipairs(UI.RODINA_SERVERS_DATA) do
        if srv.id == my_srv_id then
            StateMarket.server_filter_idx = i
            break
        end
    end

    if isTokenPresent() then
        checkVipStatus(Settings.api_key, 0)
    end

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
        UI.win_state[0] = not UI.win_state[0]
    end)

    sampAddChatMessage("{5CB85C}[RMarket Mobile] {FFFFFF}Скрипт успешно запущен. Введите {5CB85C}/rmenu", -1)

    if not isTokenPresent() then
        sampAddChatMessage("{F0AD4E}[RMarket Mobile] {FFFFFF}Привяжите ключ из @rdnMarket_bot (вкладка Настройки) для доступа к Маркету.", -1)
    end

    local last_action_check = 0
    while true do
        wait(0)

        if StateMarket.is_loading and StateMarket.request_started_at > 0 and os.time() - StateMarket.request_started_at >= 90 then
            StateMarket.request_id = StateMarket.request_id + 1
            StateMarket.request_started_at = 0
            StateMarket.is_loading = false
            StateMarket.last_error = true
            StateMarket.refresh_failures = StateMarket.refresh_failures + 1
            StateMarket.next_auto_refresh_at = os.time() + math.min(60 * (2 ^ math.min(StateMarket.refresh_failures - 1, 4)), 600)
        end

        if UI.active_tab == 4 and isTokenVerified() and StateMarket.last_fetch == 0 and not StateMarket.last_error and not StateMarket.is_loading and os.time() >= (StateMarket.next_auto_refresh_at or 0) then
            api_FetchMarketList(true)
        end

        local current_gamestate = sampGetGamestate()
        if State.last_gamestate == 3 and current_gamestate ~= 3 then
            if not State.is_currently_disconnected then
                State.is_currently_disconnected = true
                sendDisconnectNotification("Потеря соединения (Кик / Рестарт сервера / Таймаут)")
            end
        elseif current_gamestate == 3 then
            State.is_currently_disconnected = false
        end
        State.last_gamestate = current_gamestate

        if Settings.auto_pr and Settings.auto_pr.active then
            local now = os.time()
            if now >= State.auto_pr.global_cooldown then
                local best_item
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
                    local decoded_text = Dependencies.u8:decode(best_item.text or "")
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

        if CloudSync.needs_push and not CloudSync.is_syncing then
            if os.clock() - CloudSync.last_push > 3.0 then
                api_SyncConfigsToMiniApp()
                CloudSync.needs_push = false
                CloudSync.last_push = os.clock()
            end
        end

        if os.clock() - last_action_check > 8.0 then
            checkRemoteActions()
            last_action_check = os.clock()
        end

        Tasks.process()
        processMarketplaceSync()
        processMarketplacePing()
    end
end

function updateMobileMarketplaceFromTransaction(transaction)
    if not Marketplace.enabled or (transaction.type ~= "sale" and transaction.type ~= "purchase") then return end
    local target = transaction.type == "sale" and Marketplace.sell or Marketplace.buy
    local target_name = to_lower(cleanItemName(stripItemMetadata(transaction.item or "")))
    local target_mid = (tonumber(transaction.model_id) and tonumber(transaction.model_id) > 0) and tonumber(transaction.model_id) or findRealIndexByName(transaction.item)
    local remaining = math.max(1, tonumber(transaction.amount) or 1)
    local slots = {}
    for slot in pairs(target) do slots[#slots + 1] = tonumber(slot) or slot end
    table.sort(slots, function(a, b) return a < b end)

    local best_slot = nil
    for _, slot in ipairs(slots) do
        local item = target[slot] or target[tostring(slot)]
        if type(item) == "table" then
            local same_model = target_mid and target_mid > 0 and tonumber(item.model_id) == target_mid
            local same_name = to_lower(cleanItemName(stripItemMetadata(item.name or ""))) == target_name
            if same_model or same_name then
                local unit_p = tonumber(transaction.price) or 0
                if unit_p > 0 and tonumber(item.price) == unit_p then
                    best_slot = slot
                    break
                elseif not best_slot then
                    best_slot = slot
                end
            end
        end
    end

    local updated = false
    if best_slot then
        local item = target[best_slot] or target[tostring(best_slot)]
        if type(item) == "table" then
            if item.quality and not transaction.quality then transaction.quality = item.quality end
            if item.enchant and not transaction.enchant then transaction.enchant = item.enchant end
            local available = tonumber(item.amount) or 1
            local deducted = math.min(available, remaining)
            item.amount = available - deducted
            if item.amount <= 0 then target[best_slot] = nil end
            updated = true
        end
    end

    if updated then
        saveLiveShopState()
        local my_nick_clean = to_lower(getSafeLocalNickname():gsub(" ", "_"))
        for _, shop in ipairs(StateMarket.shops_list) do
            if to_lower((shop.nickname or ""):gsub(" ", "_")) == my_nick_clean then
                local target_list = (transaction.type == "sale") and shop.sell_list or shop.buy_list
                if target_list then
                    for s_idx = #target_list, 1, -1 do
                        local s_item = target_list[s_idx]
                        local s_clean = to_lower(cleanItemName(stripItemMetadata(s_item.name or "")))
                        local s_mid_match = target_mid and target_mid > 0 and tonumber(s_item.model_id) == target_mid
                        if s_clean == target_name or s_mid_match then
                            s_item.amount = (tonumber(s_item.amount) or 1) - remaining
                            if s_item.amount <= 0 then table.remove(target_list, s_idx) end
                            break
                        end
                    end
                    if transaction.type == "sale" then
                        shop.sell_count = #shop.sell_list
                    else
                        shop.buy_count = #shop.buy_list
                    end
                end
                break
            end
        end
        StateMarket.search_cache_key = nil
        queueMarketplaceSync(true)
        processMarketplaceSync(true)
    end
end