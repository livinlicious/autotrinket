------------------------------------------------------
-- AutoTrinket - Priority-based Trinket Swapping
------------------------------------------------------

AutoTrinketDB = AutoTrinketDB or {
    trinkets = {},
    defaults = {},
    enabled = false,
    itemBuffs = {} 
}

local TRINKET_SLOT_TOP = 13
local TRINKET_SLOT_BOTTOM = 14
local CD_THRESHOLD = 31 
local UPDATE_INTERVAL = 0.5
local UI_UPDATE_INTERVAL = 0.1
local timeSinceLastUpdate = 0
local timeSinceLastUIUpdate = 0
local debugMode = false

-- Manual Learning Mode State
local isLearningMode = false
local learningQueue = {} 
local learningSlots = { [13] = nil, [14] = nil } 
local pendingScans = {} 
local slotStatus = { [13] = "INIT", [14] = "INIT" } 

------------------------------------------------------
-- UTILITY
------------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff88ccff[AutoTrinket]|r " .. msg)
end

local function Debug(msg)
    if debugMode then
        DEFAULT_CHAT_FRAME:AddMessage("|cffaaaaaa[AT-Debug]|r " .. msg)
    end
end

local function ParseItemID(link)
    if not link then return nil end
    local _, _, id = string.find(link, "item:(%d+):")
    return tonumber(id)
end

local function GetItemNameFromLink(link)
    if not link then return nil end
    local _, _, name = string.find(link, "%[(.+)%]")
    return name
end

local function FindItemInBags(name)
    if not name then return nil end
    local searchName = string.lower(name)
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            if link then
                if string.find(string.lower(link), searchName, 1, true) then
                    return bag, slot
                end
            end
        end
    end
    return nil
end

local function GetEquippedTrinketName(slot)
    local link = GetInventoryItemLink("player", slot)
    if link then
        return GetItemNameFromLink(link)
    end
    return nil
end

local function GetTrinketCooldown(name)
    if not name then return 999999 end
    local searchName = string.lower(name)

    local bag, bagSlot = FindItemInBags(name)
    if bag then
        local start, duration = GetContainerItemCooldown(bag, bagSlot)
        if start == 0 or duration == 0 then
            return 0 
        end
    end

    local eq13 = GetEquippedTrinketName(TRINKET_SLOT_TOP)
    if eq13 and string.find(string.lower(eq13), searchName, 1, true) then
        local start, duration = GetInventoryItemCooldown("player", TRINKET_SLOT_TOP)
        if start > 0 and duration > 0 then
             return max(start + duration - GetTime(), 0)
        end
        return 0
    end

    local eq14 = GetEquippedTrinketName(TRINKET_SLOT_BOTTOM)
    if eq14 and string.find(string.lower(eq14), searchName, 1, true) then
        local start, duration = GetInventoryItemCooldown("player", TRINKET_SLOT_BOTTOM)
        if start > 0 and duration > 0 then
             return max(start + duration - GetTime(), 0)
        end
        return 0
    end
    
    if bag then
         local start, duration = GetContainerItemCooldown(bag, bagSlot)
         return max(start + duration - GetTime(), 0)
    end

    return 999999 
end

local function CanSwap()
    if UnitAffectingCombat("player") then return false end
    if UnitIsDeadOrGhost("player") then return false end
    if CursorHasItem() then return false end
    if UnitIsCasting and UnitIsCasting("player") then return false end 
    return true
end

local function EquipTrinket(name, slot)
    if not name then return false end
    if not CanSwap() then return false end
    if IsInventoryItemLocked(slot) then return false end
    
    -- 1. Check Bags
    local bag, bagSlot = FindItemInBags(name)
    if bag then
        PickupContainerItem(bag, bagSlot)
        EquipCursorItem(slot)
        return true
    end
    
    -- 2. Check Other Slot (Swap 13<->14)
    local otherSlot = (slot == TRINKET_SLOT_TOP) and TRINKET_SLOT_BOTTOM or TRINKET_SLOT_TOP
    local otherLink = GetInventoryItemLink("player", otherSlot)
    if otherLink then
        local otherName = GetItemNameFromLink(otherLink)
        if otherName and string.lower(otherName) == string.lower(name) then
            PickupInventoryItem(otherSlot)
            EquipCursorItem(slot)
            return true
        end
    end
    return false
end

------------------------------------------------------
-- BUFF MONITORING & USAGE HOOK
------------------------------------------------------

local function IsBuffActive(buffName)
    local i = 1
    while UnitBuff("player", i) do
        if not AutoTrinketScannerComp then
             CreateFrame("GameTooltip", "AutoTrinketScannerComp", nil, "GameTooltipTemplate")
             AutoTrinketScannerComp:SetOwner(UIParent, "ANCHOR_NONE")
        end
        AutoTrinketScannerComp:ClearLines()
        AutoTrinketScannerComp:SetUnitBuff("player", i)
        local name = AutoTrinketScannerCompTextLeft1:GetText()
        if name and string.lower(name) == string.lower(buffName) then
            return true
        end
        i = i + 1
    end
    return false
end

local function GetCurrentBuffs()
    local buffs = {}
    local i = 1
    while UnitBuff("player", i) do
        if not AutoTrinketScannerComp then
             CreateFrame("GameTooltip", "AutoTrinketScannerComp", nil, "GameTooltipTemplate")
             AutoTrinketScannerComp:SetOwner(UIParent, "ANCHOR_NONE")
        end
        AutoTrinketScannerComp:ClearLines()
        AutoTrinketScannerComp:SetUnitBuff("player", i)
        local name = AutoTrinketScannerCompTextLeft1:GetText()
        if name then buffs[name] = true end
        i = i + 1
    end
    return buffs
end

-- HOOK
if not AT_Original_UseInventoryItem then
    AT_Original_UseInventoryItem = UseInventoryItem
end
function UseInventoryItem(slot)
    AT_Original_UseInventoryItem(slot)
    
    if isLearningMode and (slot == 13 or slot == 14) then
        if learningSlots[slot] then 
             local preBuffs = GetCurrentBuffs()
             pendingScans[slot] = { time = GetTime(), preBuffs = preBuffs }
             Print("  Scanning buffs for " .. (learningSlots[slot] or "Item") .. "...") 
        end
    end
end

local function HasActiveTrinketBuff(slot)
    local link = GetInventoryItemLink("player", slot)
    if not link then return false end
    
    local id = ParseItemID(link)
    if not id then return false end
    
    local buffName = AutoTrinketDB.itemBuffs[id]
    if buffName and buffName ~= "NONE" then
        if IsBuffActive(buffName) then
             return true
        end
    end
    return false
end

------------------------------------------------------
-- DUAL SLOT LEARNING LOGIC
------------------------------------------------------

function AutoTrinket_IsLearning()
    return isLearningMode
end

function AutoTrinket_StartLearning()
    if isLearningMode then 
        isLearningMode = false
        Print("Learning mode Cancelled.")
        AutoTrinketConfigFrameStatusValue:SetText("Stopped")
        return
    end
    
    learningQueue = {}
    for _, t in ipairs(AutoTrinketDB.trinkets) do
        table.insert(learningQueue, t.name)
    end
    
    if table.getn(learningQueue) == 0 then
        Print("List is empty.")
        return
    end
    
    isLearningMode = true
    learningSlots = { [13] = nil, [14] = nil }
    pendingScans = {}
    slotStatus = { [13] = "INIT", [14] = "INIT" }
    
    Print("Manual Learning Mode: Dual Slot")
    Print("I will rotate trinkets into Top/Bottom slots.")
    Print("Use them when READY to learn their buffs.")
end

local function ProcessLearningMode()
    if not isLearningMode then return end
    
    if UnitAffectingCombat("player") then
        isLearningMode = false
        Print("Combat detected. Learning Cancelled.")
        return
    end
    
    if table.getn(learningQueue) == 0 and not learningSlots[13] and not learningSlots[14] then
         isLearningMode = false
         Print("|cff00ff00Learning Complete! Resuming Auto-Swap.|r")
         AutoTrinket_RefreshUI()
         return
    end
    
    -- 1. REPLENISH
    for slot = 13, 14 do
        if not learningSlots[slot] and table.getn(learningQueue) > 0 then
            local nextItem = table.remove(learningQueue, 1)
            learningSlots[slot] = nextItem
            slotStatus[slot] = "EQUIPPING"
        end
    end
    
    -- 2. MANAGE EQUIPS
    for slot = 13, 14 do
        local target = learningSlots[slot]
        if target then
             local current = GetEquippedTrinketName(slot)
             if not current or not string.find(string.lower(current), string.lower(target), 1, true) then
                 if slotStatus[slot] ~= "SWAPPING" then
                      if EquipTrinket(target, slot) then
                          slotStatus[slot] = "SWAPPING"
                      end
                 end
             else
                 local start, duration = GetInventoryItemCooldown("player", slot)
                 if start == 0 and duration == 0 then
                      if slotStatus[slot] ~= "READY" then
                          slotStatus[slot] = "READY"
                          local slotName = (slot==13 and "Top" or "Bottom")
                          Print("|cff00ff00" .. slotName .. " [" .. target .. "] READY! Use it.|r")
                      end
                 else
                      if slotStatus[slot] ~= "COOLDOWN" then
                          slotStatus[slot] = "COOLDOWN"
                      end
                 end
             end
        end
    end
    
    -- 3. PROCESS SCANS
    for slot = 13, 14 do
        if pendingScans[slot] then
            local elapsed = GetTime() - pendingScans[slot].time
            if elapsed > 0.5 then
                local preBuffs = pendingScans[slot].preBuffs
                local currentBuffs = GetCurrentBuffs()
                local newBuff = nil
                
                for name, _ in pairs(currentBuffs) do
                    if not preBuffs[name] then
                        newBuff = name
                        break
                    end
                end
                
                local done = false
                
                if newBuff then
                    local link = GetInventoryItemLink("player", slot)
                    if link then
                        local id = ParseItemID(link)
                        if id then
                            AutoTrinketDB.itemBuffs[id] = newBuff
                            Print("|cff00ff00Learned: [" .. newBuff .. "] for " .. (learningSlots[slot] or "Item") .. "|r")
                        end
                    end
                    done = true
                elseif elapsed > 4.0 then
                    Print("No new buff found. Moving on.")
                    local link = GetInventoryItemLink("player", slot)
                    if link then
                        local id = ParseItemID(link)
                        if id then
                            AutoTrinketDB.itemBuffs[id] = "NONE" 
                        end
                    end
                    done = true
                end
                
                if done then
                    pendingScans[slot] = nil
                    learningSlots[slot] = nil
                    slotStatus[slot] = "DONE"
                end
            end
        end
    end
end


------------------------------------------------------
-- UI & SETUP FUNCTIONS
------------------------------------------------------

local PriorityListItems = {} 

local function IsTrinket(bag, slot, link)
    if not link then
        if bag and slot then
            link = GetContainerItemLink(bag, slot)
        end
    end
    if not link then return false end
    local name, _, _, _, _, _, _, _, equipLoc = GetItemInfo(link)
    if name and equipLoc and equipLoc == "INVTYPE_TRINKET" then return true end
    
    if not AutoTrinketScanTooltip then
        CreateFrame("GameTooltip", "AutoTrinketScanTooltip", UIParent, "GameTooltipTemplate")
    end
    AutoTrinketScanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    AutoTrinketScanTooltip:ClearLines()
    if bag and slot then
        AutoTrinketScanTooltip:SetBagItem(bag, slot)
    else
        AutoTrinketScanTooltip:SetHyperlink(link)
    end
    for i = 2, 4 do
        local leftLine = getglobal("AutoTrinketScanTooltipTextLeft" .. i)
        local rightLine = getglobal("AutoTrinketScanTooltipTextRight" .. i)
        if leftLine then
            local text = leftLine:GetText()
            if text and (string.find(text, "Trinket") or string.find(text, "Bijou")) then
                 if not string.find(text, "^Use:") and not string.find(text, "^Equip:") then return true end
            end
        end
        if rightLine then
            local text = rightLine:GetText()
            if text and (string.find(text, "Trinket") or string.find(text, "Bijou")) then
                 if not string.find(text, "^Use:") and not string.find(text, "^Equip:") then return true end
            end
        end
    end
    return false
end

function AutoTrinket_RefreshPriorityList()
    if not AutoTrinketConfigFrame then return end
    
    for _, item in pairs(PriorityListItems) do
        if item.fontString then item.fontString:Hide() end
        if item.cdString then item.cdString:Hide() end
        if item.removeButton then item.removeButton:Hide() end
        if item.upButton then item.upButton:Hide() end
        if item.downButton then item.downButton:Hide() end
        if item.checkButton then item.checkButton:Hide() end
    end
    
    local yOffset = 8
    
    for i, trinket in ipairs(AutoTrinketDB.trinkets) do
        if not PriorityListItems[i] then
            PriorityListItems[i] = {}
        end
        local row = PriorityListItems[i]

        -- CheckBox (Use for Rotation)
        if not row.checkButton then
            row.checkButton = CreateFrame("CheckButton", nil, AutoTrinketConfigFramePriorityListFrame, "UICheckButtonTemplate")
            row.checkButton:SetWidth(20)
            row.checkButton:SetHeight(20)
            row.checkButton:SetScript("OnClick", function()
                AutoTrinketDB.trinkets[this.index].useForRotation = this:GetChecked()
            end)
        end
        row.checkButton:SetPoint("TOPLEFT", 10, -yOffset + 4)
        row.checkButton.index = i
        row.checkButton:SetChecked(trinket.useForRotation == nil or trinket.useForRotation)
        row.checkButton:Show()
        
        -- Text (Shifted Right to x=35)
        if not row.fontString then
            row.fontString = AutoTrinketConfigFramePriorityListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.fontString:SetJustifyH("LEFT")
            row.fontString:SetWidth(125)
        end
        row.fontString:SetPoint("TOPLEFT", 35, -yOffset)
        row.fontString:SetText(i .. ". " .. trinket.name)
        row.fontString:Show()
        
        -- CD
        if not row.cdString then
            row.cdString = AutoTrinketConfigFramePriorityListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.cdString:SetJustifyH("LEFT")
            row.cdString:SetWidth(60)
        end
        row.cdString:SetPoint("TOPLEFT", 160, -yOffset)
        local cd = GetTrinketCooldown(trinket.name)
        local cdText = cd == 0 and "|cff00ff00READY|r" or (cd > 1000 and "|cffff0000?|r" or "|cffffff00" .. math.floor(cd) .. "s|r")
        row.cdString:SetText(cdText)
        row.cdString:Show()
        
        -- Remove Button
        if not row.removeButton then
            row.removeButton = CreateFrame("Button", nil, AutoTrinketConfigFramePriorityListFrame)
            row.removeButton:SetWidth(16)
            row.removeButton:SetHeight(16)
            row.removeButton:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
            row.removeButton:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
            row.removeButton:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
            row.removeButton:SetScript("OnClick", function()
                AutoTrinket_RemoveTrinket(this.index)
                AutoTrinket_RefreshPriorityList() 
            end)
        end
        row.removeButton:SetPoint("TOPRIGHT", -5, -yOffset)
        row.removeButton.index = i 
        row.removeButton:Show()
        
        -- Down Button
        if not row.downButton then
            row.downButton = CreateFrame("Button", nil, AutoTrinketConfigFramePriorityListFrame)
            row.downButton:SetWidth(16)
            row.downButton:SetHeight(16)
            row.downButton:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
            row.downButton:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
            row.downButton:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight")
            row.downButton:SetScript("OnClick", function()
                if this.index < table.getn(AutoTrinketDB.trinkets) then
                    AutoTrinket_MoveTrinket(this.index, this.index + 1)
                    AutoTrinket_RefreshPriorityList()
                end
            end)
        end
        row.downButton:SetPoint("RIGHT", row.removeButton, "LEFT", -2, 0)
        row.downButton.index = i 
        row.downButton:Show()
        
        -- Up Button
        if not row.upButton then
            row.upButton = CreateFrame("Button", nil, AutoTrinketConfigFramePriorityListFrame)
            row.upButton:SetWidth(16)
            row.upButton:SetHeight(16)
            row.upButton:SetNormalTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up")
            row.upButton:SetPushedTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Down")
            row.upButton:SetHighlightTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Highlight")
            row.upButton:SetScript("OnClick", function()
                if this.index > 1 then
                    AutoTrinket_MoveTrinket(this.index, this.index - 1)
                    AutoTrinket_RefreshPriorityList()
                end
            end)
        end
        row.upButton:SetPoint("RIGHT", row.downButton, "LEFT", -2, 0)
        row.upButton.index = i 
        row.upButton:Show()
        
        yOffset = yOffset + 24 -- Increased row height slightly to accommodate checkbox
    end
end

local function GetAllTrinkets()
    local list = {}
    local seen = {}
    for _, t in ipairs(AutoTrinketDB.trinkets) do
        if not seen[t.name] then
            table.insert(list, t.name)
            seen[t.name] = true
        end
    end
    for bag = 0, 4 do
        for slot = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, slot)
            if link then
                local _, _, itemName = string.find(link, "%[(.+)%]")
                 if itemName and not seen[itemName] then
                     if IsTrinket(bag, slot, link) then
                         table.insert(list, itemName)
                         seen[itemName] = true
                     end
                end
            end
        end
    end
    for i = 13, 14 do
        local link = GetInventoryItemLink("player", i)
        if link then
            local _, _, itemName = string.find(link, "%[(.+)%]")
            if itemName and not seen[itemName] then
                table.insert(list, itemName)
                seen[itemName] = true
            end
        end
    end
    table.sort(list)
    return list
end

------------------------------------------------------
-- MAIN LOGIC
------------------------------------------------------

local function IsSameTrinket(name1, name2)
    if not name1 or not name2 then return false end
    return string.lower(name1) == string.lower(name2)
end

local function ManageTrinkets()
    if isLearningMode then return end -- Don't swap if learning
    if not AutoTrinketDB.enabled then return end
    if not CanSwap() then return end

    if HasActiveTrinketBuff(TRINKET_SLOT_TOP) then return end
    if HasActiveTrinketBuff(TRINKET_SLOT_BOTTOM) then return end

    local candidates = {}
    for i, trinket in ipairs(AutoTrinketDB.trinkets) do
        local cd = GetTrinketCooldown(trinket.name)
        if cd <= CD_THRESHOLD then 
            table.insert(candidates, {name = trinket.name, index = i})
        end
    end

    local desired = {}
    if table.getn(candidates) >= 1 then table.insert(desired, candidates[1]) end
    if table.getn(candidates) >= 2 then table.insert(desired, candidates[2]) end
    
    local needed = 2 - table.getn(desired)
    if needed > 0 then
        local def1 = AutoTrinketDB.defaults[1]
        local def2 = AutoTrinketDB.defaults[2]
        
        local function isDesired(n) 
            if not n then return true end 
            for _, d in ipairs(desired) do 
                if IsSameTrinket(d.name, n) then return true end 
            end 
            return false 
        end
        
        if def1 and not isDesired(def1) and needed > 0 then
             table.insert(desired, {name = def1, index = 99})
             needed = needed - 1
        end
        if def2 and not isDesired(def2) and needed > 0 then
             table.insert(desired, {name = def2, index = 99})
             needed = needed - 1
        end
    end

    local eq13 = GetEquippedTrinketName(TRINKET_SLOT_TOP)
    local eq14 = GetEquippedTrinketName(TRINKET_SLOT_BOTTOM)
    
    local missing = {}
    for _, d in ipairs(desired) do
        local inTop = IsSameTrinket(eq13, d.name)
        local inBottom = IsSameTrinket(eq14, d.name)
        if not inTop and not inBottom then
            table.insert(missing, d)
        end
    end
    
    if table.getn(missing) == 0 then return end
    
    local targetItem = missing[1]
    
    local topIsDesired = false
    local bottomIsDesired = false
    for _, d in ipairs(desired) do
        if IsSameTrinket(eq13, d.name) then topIsDesired = true end
        if IsSameTrinket(eq14, d.name) then bottomIsDesired = true end
    end
    
    local targetSlot = nil
    
    if not topIsDesired and not bottomIsDesired then
        targetSlot = TRINKET_SLOT_TOP 
    elseif not topIsDesired then
        targetSlot = TRINKET_SLOT_TOP
    elseif not bottomIsDesired then
        targetSlot = TRINKET_SLOT_BOTTOM
    end
    
    if targetSlot then
        Debug("Optimizing: Need ["..targetItem.name.."]. Replacing slot "..targetSlot)
        EquipTrinket(targetItem.name, targetSlot)
    end
end

local function OnUpdate()
    if isLearningMode then
        timeSinceLastUpdate = timeSinceLastUpdate + arg1
        if timeSinceLastUpdate > 0.3 then 
             timeSinceLastUpdate = 0
             ProcessLearningMode()
        end
        return
    end

    if not AutoTrinketDB or not AutoTrinketDB.enabled then return end
    timeSinceLastUpdate = timeSinceLastUpdate + arg1
    if timeSinceLastUpdate < UPDATE_INTERVAL then return end
    timeSinceLastUpdate = 0
    ManageTrinkets()
end

function AutoTrinket_ConfigOnUpdate()
    if not AutoTrinketConfigFrame:IsVisible() then return end
    timeSinceLastUIUpdate = timeSinceLastUIUpdate + arg1
    if timeSinceLastUIUpdate < UI_UPDATE_INTERVAL then return end
    timeSinceLastUIUpdate = 0
    
    for i, trinket in ipairs(AutoTrinketDB.trinkets) do
        if PriorityListItems[i] and PriorityListItems[i].cdString then
            local cd = GetTrinketCooldown(trinket.name)
            local cdText = cd == 0 and "|cff00ff00READY|r" or (cd > 1000 and "|cffff0000?|r" or "|cffffff00" .. math.floor(cd) .. "s|r")
            PriorityListItems[i].cdString:SetText(cdText)
        end
    end
end

------------------------------------------------------
-- DROPDOWN SUPPORT
------------------------------------------------------

function AutoTrinket_Default1DropDown_Initialize()
    local info = {}
    local trinkets = GetAllTrinkets()
    
    info.text = "(None)"
    info.checked = (AutoTrinketDB.defaults[1] == nil)
    info.func = function() 
        AutoTrinketDB.defaults[1] = nil
        AutoTrinket_RefreshUI()
        UIDropDownMenu_SetText("(None)", AutoTrinketDefault1DropDown)
    end
    UIDropDownMenu_AddButton(info)
    
    for _, name in ipairs(trinkets) do
        info = {}
        info.text = name
        info.checked = (AutoTrinketDB.defaults[1] == name)
        info.func = function() 
            AutoTrinketDB.defaults[1] = this:GetText() 
            AutoTrinket_RefreshUI()
            UIDropDownMenu_SetText(this:GetText(), AutoTrinketDefault1DropDown)
        end
        UIDropDownMenu_AddButton(info)
    end
end

function AutoTrinket_Default2DropDown_Initialize()
    local info = {}
    local trinkets = GetAllTrinkets()
    
    info.text = "(None)"
    info.checked = (AutoTrinketDB.defaults[2] == nil)
    info.func = function() 
        AutoTrinketDB.defaults[2] = nil
        AutoTrinket_RefreshUI()
        UIDropDownMenu_SetText("(None)", AutoTrinketDefault2DropDown)
    end
    UIDropDownMenu_AddButton(info)
    
    for _, name in ipairs(trinkets) do
        info = {}
        info.text = name
        info.checked = (AutoTrinketDB.defaults[2] == name)
        info.func = function() 
            AutoTrinketDB.defaults[2] = this:GetText() 
            AutoTrinket_RefreshUI()
            UIDropDownMenu_SetText(this:GetText(), AutoTrinketDefault2DropDown)
        end
        UIDropDownMenu_AddButton(info)
    end
end

------------------------------------------------------
-- AUTO USE LOGIC
------------------------------------------------------

function AutoTrinket_Use()
    local topName = GetEquippedTrinketName(TRINKET_SLOT_TOP)
    local bottomName = GetEquippedTrinketName(TRINKET_SLOT_BOTTOM)
    
    local topInfo = nil
    local bottomInfo = nil
    
    -- Find list info for equipped items
    for i, t in ipairs(AutoTrinketDB.trinkets) do
        local use = (t.useForRotation == nil) or t.useForRotation
        if IsSameTrinket(t.name, topName) then
            topInfo = { index = i, use = use, slot = TRINKET_SLOT_TOP }
        elseif IsSameTrinket(t.name, bottomName) then
             bottomInfo = { index = i, use = use, slot = TRINKET_SLOT_BOTTOM }
        end
    end
    
    local best = nil
    
    -- Check Top
    if topInfo and topInfo.use then
        local cd = GetInventoryItemCooldown("player", TRINKET_SLOT_TOP)
        if cd == 0 then
            best = topInfo
        end
    end
    
    -- Check Bottom
    if bottomInfo and bottomInfo.use then
        local cd = GetInventoryItemCooldown("player", TRINKET_SLOT_BOTTOM)
        if cd == 0 then
            if not best or bottomInfo.index < best.index then
                best = bottomInfo
            end
        end
    end
    
    if best then
        UseInventoryItem(best.slot)
    end
end

------------------------------------------------------
-- COMMANDS
------------------------------------------------------

function AutoTrinket_Toggle()
    if not AutoTrinketDB.trinkets then AutoTrinketDB.trinkets = {} end
    AutoTrinketDB.enabled = not AutoTrinketDB.enabled
end

function AutoTrinket_AddTrinket(name)
    if not name then return false end
    if not AutoTrinketDB.trinkets then AutoTrinketDB.trinkets = {} end

    for i, trinket in ipairs(AutoTrinketDB.trinkets) do
        if string.lower(trinket.name) == string.lower(name) then
            return false
        end
    end

    table.insert(AutoTrinketDB.trinkets, {name = name, useForRotation = true})
    Print("Added: " .. name)
    return true
end

function AutoTrinket_AddAllTrinkets()
    local names = GetAllTrinkets()
    local added = 0
    for _, name in ipairs(names) do
        if AutoTrinket_AddTrinket(name) then
            added = added + 1
        end
    end
    Print("Added " .. added .. " trinket(s).")
    AutoTrinket_RefreshPriorityList()
end

SLASH_AUTOTRINKET1 = "/autotrinket"
SLASH_AUTOTRINKET2 = "/at"
SlashCmdList["AUTOTRINKET"] = function(msg)
    msg = msg or ""
    local _, _, cmd, arg1 = string.find(msg, "^(%S*)%s*(.-)%s*$")
    cmd = string.lower(cmd or "")

    if cmd == "config" then
        AutoTrinket_ShowConfig()
    elseif cmd == "help" then
        Print("Commands:")
        Print("  /autotrinket config - Open UI")
        Print("  /autotrinket use - Use top priority equipped trinket")
        Print("  /autotrinket - Toggle Addon On/Off")
    elseif cmd == "use" then
        AutoTrinket_Use()
    else
        AutoTrinket_Toggle()
        if AutoTrinketDB.enabled then
             Print("Enabled")
        else
             Print("Disabled")
        end
    end
end

------------------------------------------------------
-- UI FUNCTIONS
------------------------------------------------------

function AutoTrinket_ConfigOnLoad()
end

function AutoTrinket_ShowConfig()
    if AutoTrinketConfigFrame:IsVisible() then
        AutoTrinketConfigFrame:Hide()
    else
        AutoTrinket_RefreshUI()
        AutoTrinket_RefreshPriorityList()
        AutoTrinketConfigFrame:Show()
    end
end

function AutoTrinket_RefreshUI()
    if not AutoTrinketConfigFrame then return end
    if not AutoTrinketDB then return end

    if AutoTrinketDB.enabled then
        AutoTrinketConfigFrameStatusValue:SetText("|cff00ff00Enabled|r")
        AutoTrinketConfigFrameEnableButton:SetText("Disable")
    else
        AutoTrinketConfigFrameStatusValue:SetText("|cffff0000Disabled|r")
        AutoTrinketConfigFrameEnableButton:SetText("Enable")
    end

    local top = GetEquippedTrinketName(TRINKET_SLOT_TOP)
    local bottom = GetEquippedTrinketName(TRINKET_SLOT_BOTTOM)
    AutoTrinketConfigFrameEquippedFrameTopValue:SetText(top or "|cff808080(empty)|r")
    AutoTrinketConfigFrameEquippedFrameBottomValue:SetText(bottom or "|cff808080(empty)|r")

    if AutoTrinketDefault1DropDown then
        UIDropDownMenu_SetText(AutoTrinketDB.defaults[1] or "(None)", AutoTrinketDefault1DropDown)
    end
    if AutoTrinketDefault2DropDown then
        UIDropDownMenu_SetText(AutoTrinketDB.defaults[2] or "(None)", AutoTrinketDefault2DropDown)
    end
end

function AutoTrinket_ClearList()
    AutoTrinketDB.trinkets = {}
    Print("List cleared")
    AutoTrinket_RefreshPriorityList()
end

function AutoTrinket_RemoveTrinket(index)
    if not index or index < 1 or index > table.getn(AutoTrinketDB.trinkets) then return end
    local removed = table.remove(AutoTrinketDB.trinkets, index)
    if removed then
        Print("Removed: " .. removed.name)
    end
end

function AutoTrinket_MoveTrinket(fromIndex, toIndex)
    if not fromIndex or not toIndex then return end
    if fromIndex < 1 or fromIndex > table.getn(AutoTrinketDB.trinkets) then return end
    if toIndex < 1 or toIndex > table.getn(AutoTrinketDB.trinkets) then return end
    local trinket = table.remove(AutoTrinketDB.trinkets, fromIndex)
    table.insert(AutoTrinketDB.trinkets, toIndex, trinket)
end

------------------------------------------------------
-- INIT
------------------------------------------------------

local updateFrame = CreateFrame("Frame")
updateFrame:SetScript("OnUpdate", OnUpdate)

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function()
    Print("|cff00ff00Loaded|r Type /autotrinket help")
    if not AutoTrinketDB.trinkets then AutoTrinketDB.trinkets = {} end
    if not AutoTrinketDB.defaults then AutoTrinketDB.defaults = {} end
    if not AutoTrinketDB.itemBuffs then AutoTrinketDB.itemBuffs = {} end
    if not AutoTrinketScanTooltip then
        CreateFrame("GameTooltip", "AutoTrinketScanTooltip", UIParent, "GameTooltipTemplate")
    end
end)
