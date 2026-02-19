require 'lib.moonloader'
local raknet = require 'lib.samp.raknet'
local events = require 'lib.samp.events'
local json = require 'dkjson'
local encoding = require 'encoding'
encoding.default = 'CP1251'
local u8 = encoding.UTF8

local State = {
    active = false,
    spawns = {},
    current_index = 1,
    items_per_row = 4
}

local JS_SETUP_UI = [[
    (function() {
        if (!document.getElementById('spawn-selector-css')) {
            const style = document.createElement('style');
            style.id = 'spawn-selector-css';
            style.innerHTML = `
                .kb-selected .spawn-item {
                    border: 3px solid #00ffaa !important;
                    box-shadow: 0 0 30px rgba(0, 255, 170, 0.6) !important;
                    transform: scale(1.05);
                    z-index: 999;
                    transition: all 0.15s cubic-bezier(0.175, 0.885, 0.32, 1.275);
                }
                
                .spawn-selection__list {
                    scroll-behavior: smooth;
                    padding-bottom: 20px; 
                }

                .kb-hint-overlay {
                    position: fixed;
                    bottom: 40px;
                    left: 50%;
                    transform: translateX(-50%);
                    background: linear-gradient(90deg, rgba(20, 20, 25, 0.95) 0%, rgba(30, 30, 35, 0.95) 100%);
                    border: 1px solid rgba(0, 255, 170, 0.3);
                    border-radius: 50px;
                    padding: 10px 30px;
                    display: flex;
                    align-items: center;
                    gap: 25px;
                    box-shadow: 0 10px 40px rgba(0,0,0,0.6);
                    z-index: 10000;
                    opacity: 0;
                    animation: kbFadeIn 0.6s cubic-bezier(0.2, 0.8, 0.2, 1) forwards;
                    pointer-events: none;
                }

                .kb-hint-group {
                    display: flex;
                    align-items: center;
                    gap: 10px;
                }

                .kb-key-icon {
                    background: rgba(255, 255, 255, 0.1);
                    border: 1px solid rgba(255, 255, 255, 0.2);
                    border-radius: 6px;
                    padding: 4px 8px;
                    color: #fff;
                    font-family: 'Ubuntu', sans-serif;
                    font-weight: 700;
                    font-size: 12px;
                    box-shadow: 0 2px 0 rgba(0,0,0,0.3);
                }

                .kb-hint-text {
                    color: rgba(255, 255, 255, 0.8);
                    font-family: 'Ubuntu', sans-serif;
                    font-size: 14px;
                    font-weight: 500;
                    text-transform: uppercase;
                    letter-spacing: 0.5px;
                }

                .kb-accent { color: #00ffaa; }

                @keyframes kbFadeIn {
                    from { opacity: 0; transform: translate(-50%, 30px); }
                    to { opacity: 1; transform: translate(-50%, 0); }
                }
            `;
            document.head.appendChild(style);
        }

        if (!document.getElementById('kb-hint-ui')) {
            const ui = document.createElement('div');
            ui.id = 'kb-hint-ui';
            ui.className = 'kb-hint-overlay';
            ui.innerHTML = `
                <div class="kb-hint-group">
                    <div class="kb-key-icon">Стрелочки</div>
                    <span class="kb-hint-text">Навигация</span>
                </div>
                <div style="width: 1px; height: 16px; background: rgba(255,255,255,0.15);"></div>
                <div class="kb-hint-group">
                    <div class="kb-key-icon" style="border-color: rgba(0,255,170,0.4); color: #00ffaa;">ENTER</div>
                    <span class="kb-hint-text kb-accent">Выбрать</span>
                </div>
            `;
            document.body.appendChild(ui);
        }
    })();
]]

local JS_CLEANUP = [[
    (function() {
        const ui = document.getElementById('kb-hint-ui');
        if (ui) ui.remove();
        const style = document.getElementById('spawn-selector-css');
        if (style) style.remove();
        document.querySelectorAll('.kb-selected').forEach(el => el.classList.remove('kb-selected'));
    })();
]]

function safeCall(fn, ...)
    local ok, res = pcall(fn, ...)
    return ok and res or nil
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

function updateVisuals()
    local js_index = State.current_index - 1
    local js = string.format([[
        (function() {
            const items = document.querySelectorAll('.spawn-selection__list-item');
            if (items.length === 0) return;
            
            document.querySelectorAll('.kb-selected').forEach(el => el.classList.remove('kb-selected'));
            
            if (items[%d]) {
                const target = items[%d];
                target.classList.add('kb-selected');
                target.scrollIntoView({behavior: 'smooth', block: 'center', inline: 'center'});
            }
        })();
    ]], js_index, js_index)
    
    injectJS(js)
end

function sendSpawnSelectionPacket(spawn_id)
    local payload = 'spawnSelection.start|' .. tostring(spawn_id)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 220)
    raknetBitStreamWriteInt8(bs, 18)
    raknetBitStreamWriteInt16(bs, #payload)
    raknetBitStreamWriteString(bs, payload)
    raknetBitStreamWriteInt32(bs, 0)
    raknetSendBitStreamEx(bs, 2, 9, 6)
    raknetDeleteBitStream(bs)
end

function extractSpawnJsonFromMsg(msg)
    if not msg or type(msg) ~= 'string' then return nil end
    local s, e = msg:find('%[%[')
    local se, ee = msg:find('%]%]')
    if s and ee and ee > s then
        local inner = msg:sub(s + 2, ee - 1)
        inner = inner:gsub('^%s*', ''):gsub('%s*$', '')
        if inner:sub(1,1) == '[' and inner:sub(-1) == ']' then
            return inner
        else
            return '[' .. inner .. ']'
        end
    end
    return nil
end

addEventHandler('onReceivePacket', function(id, bs)
    if id == 220 then
        local offset = raknetBitStreamGetReadOffset(bs)
        safeCall(raknetBitStreamIgnoreBits, bs, 8)
        local subId = safeCall(raknetBitStreamReadInt8, bs)
        
        if subId == 17 then
            safeCall(raknetBitStreamIgnoreBits, bs, 32)
            local length = safeCall(raknetBitStreamReadInt16, bs)
            local isEncoded = safeCall(raknetBitStreamReadInt8, bs)
            
            local msg = nil
            if isEncoded ~= 0 then
                msg = safeCall(raknetBitStreamDecodeString, bs, length + isEncoded)
            else
                msg = safeCall(raknetBitStreamReadString, bs, length)
            end
            
            if msg then
                if msg:find("event.spawn%-selection.initializeSpawns") then
                    local json_str = extractSpawnJsonFromMsg(msg)
                    if json_str then
                        local status, decoded = pcall(json.decode, json_str)
                        if status and decoded then
                            local list = decoded
                            if type(decoded[1]) == 'table' and decoded[1][1] then list = decoded[1] end
                            
                            State.spawns = {}
                            for _, item in ipairs(list) do
                                table.insert(State.spawns, {
                                    id = item.id,
                                    title = item.title or "Unknown"
                                })
                            end
                            
                            if #State.spawns > 0 then
                                State.items_count = #State.spawns
                                State.current_index = 1
                                State.active = true
                                
                                
                                lua_thread.create(function()
                                    wait(500) 
                                    injectJS(JS_SETUP_UI) 
                                    wait(100)
                                    updateVisuals()
                                end)
                            end
                        end
                    end
                end
                
                if msg:find("event.setActiveView") then
                    if not msg:find("SpawnSelection") then
                        if State.active then
                            State.active = false
                            injectJS(JS_CLEANUP)
                        end
                    end
                end
            end
        end
        raknetBitStreamSetReadOffset(bs, offset)
    end
end)

function main()
    while not isSampAvailable() do wait(100) end

    while true do
        wait(0)
        
        if State.active then
            local changed = false
            
            if wasKeyPressed(0x27) then 
                if State.current_index < State.items_count then
                    State.current_index = State.current_index + 1
                    changed = true
                end
            elseif wasKeyPressed(0x25) then
                if State.current_index > 1 then
                    State.current_index = State.current_index - 1
                    changed = true
                end
            elseif wasKeyPressed(0x28) then
                if State.current_index + State.items_per_row <= State.items_count then
                    State.current_index = State.current_index + State.items_per_row
                    changed = true
                elseif State.current_index < State.items_count then
                    State.current_index = State.items_count 
                    changed = true
                end
            elseif wasKeyPressed(0x26) then 
                if State.current_index - State.items_per_row >= 1 then
                    State.current_index = State.current_index - State.items_per_row
                    changed = true
                elseif State.current_index > 1 then
                    State.current_index = 1 
                    changed = true
                end
            elseif wasKeyPressed(0x0D) then 
                local selected = State.spawns[State.current_index]
                if selected then
                    sendSpawnSelectionPacket(selected.id)
                    injectJS(JS_CLEANUP)
                    State.active = false
                    wait(500)
                end
            end
            
            if changed then
                updateVisuals()
            end
        end
    end
end