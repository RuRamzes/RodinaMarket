local events = require('lib.samp.events')

App.Hooks.RenderCarMarkers = function()
    if not Data.settings.car_hints or not CarMarket.isPlayerInAutoBazar() then return end
    if not CarMarket.markers or #CarMarket.markers == 0 then return end

    local res_ped, myX, myY, myZ = pcall(getCharCoordinates, PLAYER_PED)
    if not res_ped then return end

    local draw_list = imgui.GetBackgroundDrawList()

    for i = #CarMarket.markers, 1, -1 do
        local m = CarMarket.markers[i]
        local handle = sampGetObjectHandleBySampId(m.objId)
        
        if handle and doesObjectExist(handle) then
            local res, x, y, z = getObjectCoordinates(handle)
            if res then
                local dist = math.sqrt((myX-x)^2 + (myY-y)^2 + (myZ-z)^2)
                if dist < 50.0 then
                    local rX, rY = convert3DCoordsToScreen(x, y, z + 1.2 + math.sin(os.clock() * 3) * 0.1)
                    
                    if rX and rY and rX > 0 and rY > 0 then
                        local diff = m.avg - m.price
                        local title = u8(m.name)
                        local sub = u8(string.format("Выгода: +%s $", formatMoney(diff)))
                        
                        imgui.PushFont(font_default)
                        local t_sz = imgui.CalcTextSize(title)
                        local s_sz = imgui.CalcTextSize(sub)
                        imgui.PopFont()
                        
                        local w = math.max(t_sz.x, s_sz.x) + S(30)
                        local h = S(50)
                        
                        local box_x = rX - w/2
                        local box_y = rY - h
                        
                        draw_list:AddRectFilled(imgui.ImVec2(box_x, box_y), imgui.ImVec2(box_x + w, box_y + h), imgui.ColorConvertFloat4ToU32(imgui.ImVec4(0.1, 0.12, 0.1, 0.95)), S(8))
                        draw_list:AddRect(imgui.ImVec2(box_x, box_y), imgui.ImVec2(box_x + w, box_y + h), 0xFF34C759, S(8), 15, S(2))
                        
                        draw_list:AddTriangleFilled(
                            imgui.ImVec2(rX - S(8), box_y + h - 1),
                            imgui.ImVec2(rX + S(8), box_y + h - 1),
                            imgui.ImVec2(rX, box_y + h + S(10)),
                            0xFF34C759
                        )
                        
                        imgui.PushFont(font_default)
                        draw_list:AddText(imgui.ImVec2(box_x + (w - t_sz.x)/2, box_y + S(5)), 0xFFFFFFFF, title)
                        draw_list:AddText(imgui.ImVec2(box_x + (w - s_sz.x)/2, box_y + S(25)), 0xFF34C759, sub)
                        imgui.PopFont()
                    end
                end
            end
        else
            table.remove(CarMarket.markers, i)
        end
    end
end

function events.onSetObjectMaterialText(objectId, data)
    if not App.script_loaded then return end
    if not Data.settings.car_hints then return end

    local handle = sampGetObjectHandleBySampId(objectId)
    if handle and doesObjectExist(handle) and getObjectModel(handle) == 6885 then
        
        local success, result = pcall(function()
            if not data.text or data.text:match("id:%s*%d+") then return nil end
            
            local car_name, price_str = data.text:match("^(.-)%s*\n.-([%d%.]+)%s*руб")
            if not car_name or not price_str then
                car_name, price_str = data.text:match("^(.-)%s+.-([%d%.]+)%s*руб")
            end
            
            if car_name and price_str then
                car_name = car_name:gsub("{......}", ""):match("^%s*(.-)%s*$")
                local price = tonumber((price_str:gsub("%.", "")))
                
                if car_name and car_name ~= "" and price and price > 0 then
                    CarMarket.processPrice(car_name, price)
                    
                    local srv_db, _ = CarMarket.getCurrentServerDB()
                    local avg = 0
                    if srv_db[car_name] and #srv_db[car_name].p > 0 then
                        local sum = 0
                        for _, p in ipairs(srv_db[car_name].p) do sum = sum + p end
                        avg = math.floor(sum / #srv_db[car_name].p)
                    end

                    local price_color = "{FFFFFF}"
                    local extra_text = ""
                    
                    if avg > 0 then
                        local diff = avg - price
                        if diff > 0 then
                            price_color = "{34C759}" 
                            extra_text = string.format("\n{34C759}Рынок: %s$", formatMoney(avg))
                            
                            if (diff / avg) >= 0.05 then
                                local exists = false
                                for _, m in ipairs(CarMarket.markers) do
                                    if m.objId == objectId then exists = true break end
                                end
                                if not exists then
                                    table.insert(CarMarket.markers, {objId = objectId, name = car_name, price = price, avg = avg, time = os.clock()})
                                    sampAddChatMessage(string.format("[RMarket] {34C759}Выгодное авто! {FFFFFF}%s продают за {34C759}%s$ {FFFFFF}(Рынок: %s$)", car_name, formatMoney(price), formatMoney(avg)), -1)
                                end
                            end
                        else
                            price_color = "{FF4444}" 
                            extra_text = string.format("\n{FF4444}Рынок: %s$", formatMoney(avg))
                        end
                    else
                        extra_text = "\n{AAAAAA}Рынок: Нет данных"
                    end
                    
                    local final_text = string.format("%s\n%s%s руб.%s", car_name, price_color, formatMoney(price), extra_text)
                    if #final_text > 2040 then final_text = string.sub(final_text, 1, 2040) end
                    
                    data.text = final_text
                    return {objectId, data}
                end
            end
            return nil
        end)

        if success and result then
            return result
        end
    end
end