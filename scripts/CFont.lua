require 'lib.moonloader'
local raknet = require 'lib.samp.raknet'
local samp = require 'lib.samp.events'

local STYLE_ID = 'global-custom-font'

local currentFontURL = 'https://fonts.googleapis.com/css2?family=Montserrat:wght@800&display=swap'
local currentFontFamily = 'Montserrat'
local currentFontWeight = '800'

-- ==============================

function buildCSS()
    return string.format([[
@import url('%s');

* {
    font-family: '%s', sans-serif !important;
    font-weight: %s !important;
}

body, html {
    font-family: '%s', sans-serif !important;
    font-weight: %s !important;
}
]], currentFontURL, currentFontFamily, currentFontWeight, currentFontFamily, currentFontWeight)
end

function buildJS()
    local css = buildCSS()
    return string.format([[
(function() {
    const id = '%s';
    let style = document.getElementById(id);
    if (!style) {
        style = document.createElement('style');
        style.id = id;
        document.head.appendChild(style);
    }
    style.innerHTML = `%s`;
})();
]], STYLE_ID, css)
end

local JS_REMOVE = string.format([[
(function() {
    const style = document.getElementById('%s');
    if (style) style.remove();
})();
]], STYLE_ID)

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

function safeCall(fn, ...)
    local ok, res = pcall(fn, ...)
    return ok and res or nil
end

function applyFont()
    lua_thread.create(function()
        wait(100)
        injectJS(buildJS())
        wait(250)
        injectJS(buildJS())
    end)
end

function cmd_cfont(arg)
    if arg == nil or arg == '' then
        sampAddChatMessage('{FFAA00}[CFont]{FFFFFF} Использование: /cfont <google fonts url>', -1)
        return
    end

    if not arg:find('fonts.googleapis.com') then
        sampAddChatMessage('{FF0000}[CFont] Ссылка должна быть с Google Fonts!', -1)
        return
    end

    local family = arg:match('family=([^:&]+)')
    if family then
        family = family:gsub('+', ' ')
    else
        sampAddChatMessage('{FF0000}[CFont] Не удалось определить family!', -1)
        return
    end

    local weight = arg:match('wght@(%d+)') or '400'

    currentFontURL = arg
    currentFontFamily = family
    currentFontWeight = weight

    sampAddChatMessage(string.format('{00FF00}[CFont] Шрифт изменён на: %s (%s)', family, weight), -1)

    applyFont()
end

function main()
    if not isSampLoaded() or not isSampAvailable() then return end

    sampRegisterChatCommand('cfont', cmd_cfont)

    sampAddChatMessage('{00FF00}[CFont] Загружен. Дефолт: Montserrat 800', -1)

    wait(-1)
end

addEventHandler('onScriptTerminate', function(scr)
    if scr == script.this then
        injectJS(JS_REMOVE)
    end
end)

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
                if msg:find('event.setActiveView') 
                or msg:find('cef') 
                or msg:find('browser') then
                    applyFont()
                end
            end
        end

        raknetBitStreamSetReadOffset(bs, offset)
    end
end)