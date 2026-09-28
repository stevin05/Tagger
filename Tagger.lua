local ADDON_NAME = ...

local mode = "OFF"
local pending_mode
local pending_target_name
local pending_target_command
local tag_spell
local target_name
local target_command
local quest_stage
local target_quest_npc
local update_gui
local apply_mode

local tag_spells = {
    DRUID = {
        8925, -- Moonfire
    },
    HUNTER = {
        3044, -- Arcane Shot
    },
    MAGE = {
        2136, -- Fire Blast
    },
    PRIEST = {
        589, -- Shadow Word: Pain
    },
    WARLOCK = {
        172, -- Corruption
    },
    SHAMAN = {
        8042, -- Earth Shock
        403, -- Lightning Bolt
    },
    PALADIN = {
        20271, -- Judgement
    },
    ROGUE = {
        2764, -- Throw
    },
    WARRIOR = {
        100, -- Charge
    },
}

local binding_owner
local tagger_gui
local spell_selection_pending = false
local spell_selection_hide_hook_installed = false
local spell_selection_displayed_callback_registered = false
local spell_selection_frame
local spell_selection_overlays = {}
local clear_spell_selection_overlays
local TAGGER_MACRO_NAME = "Tagger"
local TAGGER_MACRO_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local function is_exact_mode()
    return target_command == "targetexact"
end

local function has_target_name()
    return string.match(target_name or "", "%S") ~= nil
end

local function get_spell_name_by_id(spell_id)
    if not spell_id then
        return nil
    end

    if C_Spell and C_Spell.GetSpellName then
        return C_Spell.GetSpellName(spell_id)
    end
end

local function get_saved_preferred_spell()
    local preferred_spell_id = TaggerDB.preferred_spell_id

    if preferred_spell_id and get_spell_name_by_id(preferred_spell_id) then
        return preferred_spell_id
    end

    TaggerDB.preferred_spell_id = nil
    return nil
end

local function set_preferred_spell(spell_id)
    if not spell_id then
        return
    end

    TaggerDB.preferred_spell_id = spell_id
end

local function find_tag_spell()
    local preferred_spell_id = get_saved_preferred_spell()

    if preferred_spell_id then
        local spell_name = get_spell_name_by_id(preferred_spell_id)
        if spell_name then
            return {
                id = preferred_spell_id,
                name = spell_name,
            }
        end
    end

    local _, class_token = UnitClass("player")
    local candidates = tag_spells[class_token]

    if not candidates then
        return nil
    end

    for _, spell_id in ipairs(candidates) do
        if C_SpellBook.IsSpellKnown(spell_id) then
            return {
                id = spell_id,
                name = C_Spell.GetSpellName(spell_id)
            }
        end
    end
end

local function finish_spell_selection(selected_spell_id)
    if not spell_selection_pending or not selected_spell_id then
        return
    end

    if not get_spell_name_by_id(selected_spell_id) then
        print("Tagger: Could not identify the selected spell.")
        return
    end

    set_preferred_spell(selected_spell_id)
    spell_selection_pending = false
    clear_spell_selection_overlays()
    if PlayerSpellsFrame and PlayerSpellsFrame:IsShown() then
        HideUIPanel(PlayerSpellsFrame)
    end
    if mode == "TAG" then
        apply_mode("TAG", target_name, target_command)
    else
        update_gui()
    end
end

clear_spell_selection_overlays = function()
    for index = #spell_selection_overlays, 1, -1 do
        local overlay = spell_selection_overlays[index]
        overlay:Hide()
        spell_selection_overlays[index] = nil
    end
end

local function refresh_spell_selection_overlays()
    if not spell_selection_pending or not spell_selection_frame then
        return
    end

    clear_spell_selection_overlays()
    spell_selection_frame:ForEachDisplayedSpell(function(item_frame)
        local item_info = item_frame.spellBookItemInfo
        local item_button = item_frame.Button
        if not item_info
            or item_info.itemType ~= Enum.SpellBookItemType.Spell
            or item_frame.spellBank ~= Enum.SpellBookSpellBank.Player
            or not item_button then
            return
        end

        local overlay = item_frame.taggerSelectionOverlay
        if not overlay then
            overlay = CreateFrame("Button", nil, item_frame)
            overlay:SetAllPoints(item_frame)
            overlay:RegisterForClicks("LeftButtonUp")
            overlay:SetScript("OnEnter", function(self)
                local item = self:GetParent()
                local button = item and item.Button
                if not button then
                    return
                end
                local on_enter = button:GetScript("OnEnter")
                if on_enter then
                    on_enter(button)
                end
            end)
            overlay:SetScript("OnLeave", function(self)
                local item = self:GetParent()
                local button = item and item.Button
                if not button then
                    return
                end
                local on_leave = button:GetScript("OnLeave")
                if on_leave then
                    on_leave(button)
                end
            end)
            overlay:SetScript("OnClick", function(self)
                local item = self:GetParent()
                local current_item = item and item.spellBookItemInfo
                if current_item
                    and current_item.itemType == Enum.SpellBookItemType.Spell
                    and item.spellBank == Enum.SpellBookSpellBank.Player then
                    finish_spell_selection(current_item.actionID)
                end
            end)
            item_frame.taggerSelectionOverlay = overlay
        end

        overlay:SetFrameLevel(item_frame:GetFrameLevel() + 5)
        overlay:Show()
        table.insert(spell_selection_overlays, overlay)
    end)
end

local function begin_spell_selection()
    if InCombatLockdown() then
        print("Tagger: Spell selection is unavailable during combat.")
        return
    end

    if not PlayerSpellsUtil or not PlayerSpellsUtil.OpenToSpellBookTab then
        print("Tagger: Unable to load the spellbook UI.")
        return
    end

    PlayerSpellsUtil.OpenToSpellBookTab()
    spell_selection_frame = PlayerSpellsFrame and PlayerSpellsFrame.SpellBookFrame
    if not spell_selection_frame or not spell_selection_frame.ForEachDisplayedSpell then
        print("Tagger: Spellbook panel is unavailable.")
        return
    end

    if not spell_selection_hide_hook_installed then
        spell_selection_frame:HookScript("OnHide", function()
            if spell_selection_pending then
                spell_selection_pending = false
                clear_spell_selection_overlays()
            end
        end)
        spell_selection_hide_hook_installed = true
    end

    if not spell_selection_displayed_callback_registered and EventRegistry then
        EventRegistry:RegisterCallback("PlayerSpellsFrame.SpellBookFrame.DisplayedSpellsChanged", function()
            refresh_spell_selection_overlays()
        end)
        spell_selection_displayed_callback_registered = true
    end

    spell_selection_pending = true
    refresh_spell_selection_overlays()
end

local function create_gui()
    if tagger_gui then
        return tagger_gui
    end

    local frame = CreateFrame("Frame", ADDON_NAME .. "GUI", UIParent, "DefaultPanelTemplate")
    frame:SetSize(300, 104)
    frame:SetPoint("TOP", 0, -24)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
    end)
    frame:SetTitle("Tagger")
    local close_button = CreateFrame("Button", nil, frame, "UIPanelCloseButtonDefaultAnchors")
    close_button:HookScript("OnClick", function()
        if InCombatLockdown() then
            return
        end
        apply_mode("OFF")
    end)
    frame.CloseButton = close_button
    frame:Hide()

    local icon_button = CreateFrame("Button", nil, frame)
    icon_button:SetSize(24, 24)
    icon_button:SetPoint("TOPLEFT", frame, "TOPLEFT", 15, -62)
    local icon = icon_button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    frame.icon = icon
    frame.icon_button = icon_button
    icon_button:SetScript("OnClick", begin_spell_selection)
    icon_button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Click to choose your tag spell", 1, 1, 1, 1)
        GameTooltip:Show()
    end)
    icon_button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    local arrow_button = CreateFrame("Button", nil, frame)
    arrow_button:SetSize(18, 18)
    arrow_button:SetPoint("LEFT", icon_button, "RIGHT", 4, 0)
    local arrow = arrow_button:CreateTexture(nil, "OVERLAY")
    arrow:SetAtlas("shop-header-arrow")
    arrow:SetAllPoints()
    arrow:SetVertexColor(0.8, 0.8, 0.8, 1)
    arrow:SetRotation(math.rad(180))
    local function show_arrow_tooltip()
        GameTooltip:SetOwner(arrow_button, "ANCHOR_RIGHT")
        if is_exact_mode() then
            GameTooltip:SetText("Exact match enabled", 1, 1, 1, 1)
        else
            GameTooltip:SetText("Prefix match enabled", 1, 1, 1, 1)
        end
        GameTooltip:Show()
    end
    arrow_button:SetScript("OnEnter", function(self)
        show_arrow_tooltip()
    end)
    arrow_button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    arrow_button:SetScript("OnClick", function()
        if InCombatLockdown() then
            return
        end
        if is_exact_mode() then
            target_command = "target"
        else
            target_command = "targetexact"
        end
        if mode == "TAG" then
            apply_mode("TAG", target_name, target_command)
        end
        update_gui()
        if GameTooltip:GetOwner() == arrow_button then
            show_arrow_tooltip()
        end
    end)
    frame.arrow = arrow
    frame.arrow_button = arrow_button

    local input_name = CreateFrame("EditBox", nil, frame, "InputBoxInstructionsTemplate")
    input_name:SetSize(184, 20)
    input_name:SetPoint("LEFT", arrow, "RIGHT", 10, 0)
    input_name:SetAutoFocus(false)
    input_name.Instructions:SetText("NPC Name")
    input_name:SetText(target_name or "")
    local function commit_target_name(self)
        if InCombatLockdown() then
            self:ClearFocus()
            update_gui()
            return
        end

        local entered_name = string.match(self:GetText() or "", "^%s*(.-)%s*$")
        if entered_name == "" or string.lower(entered_name) == "%t" then
            if UnitExists("target") then
                entered_name = UnitName("target") or ""
                if entered_name ~= "" then
                    target_command = "targetexact"
                end
            else
                entered_name = ""
                print("Tagger: Select a target to fill the NPC name.")
            end
            self:SetText(entered_name)
        end

        self:ClearFocus()
        target_name = entered_name
        if has_target_name() then
            local selected_mode = mode == "OFF" and "TAG" or mode
            apply_mode(selected_mode, target_name, target_command)
        end
        update_gui()
    end
    input_name:SetScript("OnEnterPressed", commit_target_name)
    input_name:SetScript("OnTabPressed", commit_target_name)
    input_name:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
        self:SetText(target_name or "")
        update_gui()
    end)
    input_name:HookScript("OnTextChanged", function(self)
        if self:HasFocus() then
            if InCombatLockdown() then
                self:SetText(target_name or "")
                self:ClearFocus()
                update_gui()
                return
            end
            target_name = self:GetText() or ""
            update_gui()
        end
    end)
    frame.input_name = input_name

    local mode_track = CreateFrame("Frame", nil, frame)
    mode_track:SetSize(276, 26)
    mode_track:SetPoint("TOPLEFT", 12, -32)
    local track_background = mode_track:CreateTexture(nil, "BACKGROUND")
    track_background:SetAllPoints()
    track_background:SetColorTexture(0.035, 0.035, 0.035, 0.95)
    frame.mode_track = mode_track

    local mode_options = {
        { mode = "OFF", label = "Disabled" },
        { mode = "TAG", label = "Tag Mob" },
        { mode = "QUEST", label = "Start Quest" },
    }
    local mode_buttons = {}
    local segment_width = 92

    for index, option in ipairs(mode_options) do
        local button = CreateFrame("Button", nil, mode_track)
        button:SetSize(segment_width, 26)
        button:SetPoint("LEFT", mode_track, "LEFT", (index - 1) * segment_width, 0)

        local selection_background = button:CreateTexture(nil, "BACKGROUND")
        selection_background:SetPoint("TOPLEFT", 2, -2)
        selection_background:SetPoint("BOTTOMRIGHT", -2, 2)
        selection_background:SetColorTexture(0.18, 0.34, 0.22, 1)
        selection_background:Hide()
        button.selection_background = selection_background

        local label = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        label:SetPoint("CENTER")
        label:SetText(option.label)
        button.label = label

        local selected_mode = option.mode
        button:SetScript("OnClick", function()
            if InCombatLockdown() then
                return
            end
            if selected_mode ~= "OFF" and not has_target_name() then
                return
            end
            apply_mode(selected_mode, target_name or "", target_command or "target")
            update_gui()
        end)
        button:SetScript("OnEnter", function(self)
            if selected_mode ~= "OFF" and not has_target_name() then
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText("Enter an NPC name to enable " .. option.label .. " mode.", 1, 1, 1, 1)
                GameTooltip:Show()
            elseif selected_mode ~= mode then
                self.selection_background:SetColorTexture(0.14, 0.14, 0.14, 1)
                self.selection_background:Show()
            end
        end)
        button:SetScript("OnLeave", function()
            GameTooltip:Hide()
            update_gui()
        end)
        mode_buttons[selected_mode] = button
    end
    frame.mode_buttons = mode_buttons

    tagger_gui = frame
    return frame
end

update_gui = function()
    local frame = create_gui()
    local combat_locked = InCombatLockdown()

    for button_mode, button in pairs(frame.mode_buttons) do
        local enabled = not combat_locked and (button_mode == "OFF" or has_target_name())
        button:SetEnabled(enabled)
        if not enabled then
            button.selection_background:Hide()
            button.label:SetTextColor(0.4, 0.4, 0.4, 1)
        elseif button_mode == mode then
            button.selection_background:SetColorTexture(0.18, 0.34, 0.22, 1)
            button.selection_background:Show()
            button.label:SetTextColor(0.55, 1, 0.65, 1)
        else
            button.selection_background:Hide()
            button.label:SetTextColor(0.85, 0.85, 0.85, 1)
        end
    end

    frame.input_name:SetEnabled(not combat_locked)
    frame.arrow_button:SetEnabled(not combat_locked)
    frame.icon_button:SetEnabled(not combat_locked)
    frame.CloseButton:SetEnabled(not combat_locked)

    local displayed_target_name = target_name or ""
    if frame.input_name:GetText() ~= displayed_target_name then
        frame.input_name:SetText(displayed_target_name)
    end
    if mode == "QUEST" then
        frame.icon:SetAtlas("ClassHall-QuestIcon-Desaturated")
    else
        local display_spell = tag_spell or find_tag_spell()
        local spell_texture = display_spell and display_spell.id
            and C_Spell.GetSpellTexture(display_spell.id)

        frame.icon:SetTexture(spell_texture or TAGGER_MACRO_ICON)
    end

    if is_exact_mode() then
        frame.arrow:SetVertexColor(0.3, 1, 0.45, 1)
    else
        frame.arrow:SetVertexColor(0.8, 0.8, 0.8, 1)
    end
end

local function clear_bindings()
    if binding_owner then
        ClearOverrideBindings(binding_owner)
    end
end

local function set_wheel_command(command)
    SetOverrideBinding(binding_owner, true, "MOUSEWHEELUP", command)
    SetOverrideBinding(binding_owner, true, "MOUSEWHEELDOWN", command)
end

local function find_macro_index()
    for index = 1, GetNumMacros() do
        local name = GetMacroInfo(index)

        if name == TAGGER_MACRO_NAME then
            return index
        end
    end
end

local function configure_macro(requested_mode)
    if requested_mode == "TAG" then
        tag_spell = find_tag_spell()
    end

    local selected_spell = tag_spell
    local spell_name = selected_spell and selected_spell.name

    if not target_name or (requested_mode == "TAG" and not spell_name) then
        return false
    end

    target_name = string.gsub(target_name, "[\r\n]", "")

    if target_name == "" then
        return false
    end

    local macro_body

    if requested_mode == "TAG" then
        macro_body = string.format(
            "#showtooltip\n/cleartarget\n/%s %s\n/ping [@target,exists,nodead] assist\n/cast [@target,exists,nodead,harm] %s",
            target_command,
            target_name,
            spell_name
        )
    else
        macro_body = string.format(
            "/cleartarget\n/%s %s\n/ping [@target,exists,nodead] assist",
            target_command,
            target_name
        )
    end
    local macro_index = find_macro_index()

    if macro_index then
        EditMacro(macro_index, TAGGER_MACRO_NAME, TAGGER_MACRO_ICON, macro_body)
    else
        macro_index = CreateMacro(TAGGER_MACRO_NAME, TAGGER_MACRO_ICON, macro_body, false)
    end

    if not macro_index then
        print("Tagger: Unable to create the Tagger macro.")
        return false
    end

    return true
end

apply_mode = function(requested_mode, requested_target_name, requested_target_command)
    if InCombatLockdown() then
        pending_mode = requested_mode
        pending_target_name = requested_target_name
        pending_target_command = requested_target_command
        print("Tagger: Cannot change mode during combat; the request is queued.")
        return
    end

    pending_mode = nil
    pending_target_name = nil
    pending_target_command = nil
    clear_bindings()
    mode = "OFF"
    tag_spell = nil
    target_name = requested_target_name or target_name or ""
    target_command = requested_target_command or target_command or "target"
    quest_stage = requested_mode == "QUEST" and "TARGET" or nil

    if requested_mode == "TAG" then
        if target_name == "" then
            print("Tagger: Enter an NPC name in the box to enable tagging.")
            update_gui()
            return
        end

        tag_spell = find_tag_spell()
        if not tag_spell then
            print("Tagger: No supported tag ability found for your character.")
            update_gui()
            return
        end

        if not configure_macro(requested_mode) then
            update_gui()
            return
        end

        set_wheel_command("MACRO " .. TAGGER_MACRO_NAME)
        mode = requested_mode
        print("Tagger: TAG mode enabled - " .. tag_spell.name .. " -> " .. target_name)
    elseif requested_mode == "QUEST" then
        if target_name == "" then
            print("Tagger: Enter an NPC name in the box to enable quest mode.")
            update_gui()
            return
        end

        if not configure_macro(requested_mode) then
            update_gui()
            return
        end

        set_wheel_command("MACRO " .. TAGGER_MACRO_NAME)
        mode = requested_mode
        target_quest_npc()
        print("Tagger: QUEST mode enabled - target and interact with the wheel; quests auto-select and accept.")
    else
        target_name = target_name or ""
        target_command = target_command or "target"
        quest_stage = nil
        print("Tagger: disabled.")
    end

    update_gui()
end

local function print_status()
    print("Tagger: Mode: " .. mode)

    if mode == "TAG" and tag_spell then
        print("Tagger: Tag spell: " .. tag_spell.name)
        print("Tagger: Target name: " .. (target_name or "none"))
        print("Tagger: Target command: /" .. (target_command or "target"))
        print("Tagger: Wheel: MOUSEWHEELUP / MOUSEWHEELDOWN")
    elseif mode == "QUEST" then
        print("Tagger: Quest target: " .. (target_name or "none"))
        print("Tagger: Quest stage: " .. (quest_stage or "none"))
    end
end

local function target_matches_request(require_hostile)
    if not UnitExists("target") or UnitIsDeadOrGhost("target") then
        return false
    end

    if require_hostile and not UnitCanAttack("player", "target") then
        return false
    end

    local current_target_name = UnitName("target")
    local requested_name = string.lower(target_name or "")
    local actual_name = current_target_name and string.lower(current_target_name) or ""

    if target_command == "targetexact" then
        return actual_name == requested_name
    end

    return string.sub(actual_name, 1, string.len(requested_name)) == requested_name
end

target_quest_npc = function()
    if mode ~= "QUEST" or quest_stage ~= "TARGET" or not target_matches_request(false) then
        return
    end

    set_wheel_command("INTERACTTARGET")
    quest_stage = "INTERACT"
    print("Tagger: target acquired; wheel now interacts with the NPC.")
end

local function quest_event_is_for_requested_npc()
    return mode == "QUEST" and target_matches_request(false)
end

local function select_first_greeting_quest()
    if not quest_event_is_for_requested_npc() then
        return
    end

    for index = 1, GetNumAvailableQuests() do
        local title, is_complete = GetAvailableTitle(index)

        if title and not is_complete then
            quest_stage = "QUEST_SELECT"
            SelectAvailableQuest(index)
            return
        end
    end

    print("Tagger: no available quest remains; disabling quest mode.")
    apply_mode("OFF")
end

local function select_first_gossip_quest()
    if not quest_event_is_for_requested_npc() or not C_GossipInfo then
        return
    end

    local available_quests = C_GossipInfo.GetAvailableQuests()

    for _, quest_info in ipairs(available_quests or {}) do
        if quest_info.questID then
            quest_stage = "QUEST_SELECT"
            C_GossipInfo.SelectAvailableQuest(quest_info.questID)
            return
        end
    end

    print("Tagger: no available gossip quest remains; disabling quest mode.")
    apply_mode("OFF")
end

local function accept_quest_detail()
    if not quest_event_is_for_requested_npc() then
        return
    end

    quest_stage = "QUEST_ACCEPT"

    if QuestGetAutoAccept and QuestGetAutoAccept() then
        CloseQuest()
    else
        AcceptQuest()
    end
end

local function confirm_quest_acceptance()
    if quest_event_is_for_requested_npc() then
        ConfirmAcceptQuest()
    end
end

local function handle_successful_cast(unit, spell_id)
    if unit ~= "player" or mode ~= "TAG" or not tag_spell or spell_id ~= tag_spell.id then
        return
    end

    if target_matches_request(true) then
        print("Tagger: tag spell succeeded on the requested target.")
    else
        print("Tagger: tag spell succeeded, but the current target was not the requested target.")
    end
end

local function handle_tagger_command(message)
    local trimmed = string.match(message or "", "^%s*(.-)%s*$")

    if trimmed == "" then
        if tagger_gui and tagger_gui:IsShown() then
            tagger_gui:Hide()
        else
            create_gui()
            tagger_gui:Show()
            update_gui()
        end
        return
    end
end

local event_frame = CreateFrame("Frame")
local handlers = {}

function event_frame:Register(event, callback)
    local event_handlers = handlers[event]

    if not event_handlers then
        event_handlers = {}
        handlers[event] = event_handlers
        self:RegisterEvent(event)
    end

    table.insert(event_handlers, callback)

    return function()
        for index, handler in ipairs(event_handlers) do
            if handler == callback then
                table.remove(event_handlers, index)
                break
            end
        end

        if #event_handlers == 0 then
            handlers[event] = nil
            self:UnregisterEvent(event)
        end
    end
end

event_frame:SetScript("OnEvent", function(_, event, ...)
    local event_handlers = handlers[event]

    if event_handlers then
        for _, callback in ipairs(event_handlers) do
            callback(...)
        end
    end
end)

event_frame:Register("PLAYER_LOGIN", function()
    binding_owner = CreateFrame("Frame", ADDON_NAME .. "BindingOwner", UIParent)
    target_name = ""
    target_command = "target"
    create_gui()
    update_gui()
    SLASH_TAGGER1 = "/tagger"
    _G.SlashCmdList.TAGGER = handle_tagger_command
end)

event_frame:Register("PLAYER_REGEN_ENABLED", function()
    if pending_mode then
        local requested_mode = pending_mode
        apply_mode(requested_mode, pending_target_name, pending_target_command)
    end
end)

event_frame:Register("UNIT_SPELLCAST_SUCCEEDED", function(unit, _, spell_id)
    handle_successful_cast(unit, spell_id)
end)

event_frame:Register("PLAYER_TARGET_CHANGED", function()
    target_quest_npc()
end)

event_frame:Register("SPELLS_CHANGED", function()
    update_gui()
end)

event_frame:Register("QUEST_GREETING", function()
    select_first_greeting_quest()
end)

event_frame:Register("GOSSIP_SHOW", function()
    select_first_gossip_quest()
end)

event_frame:Register("QUEST_DETAIL", function()
    accept_quest_detail()
end)

event_frame:Register("QUEST_ACCEPT_CONFIRM", function()
    confirm_quest_acceptance()
end)

event_frame:Register("QUEST_ACCEPTED", function()
    if mode == "QUEST" then
        quest_stage = "INTERACT"
    end
end)

event_frame:Register("QUEST_FINISHED", function()
    if mode == "QUEST" then
        print("Tagger: quest interaction finished; disabling quest mode.")
        apply_mode("OFF")
    end
end)
