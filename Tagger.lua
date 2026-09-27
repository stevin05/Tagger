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
        100, -- Throw
    },
}

local binding_owner
local TAGGER_MACRO_NAME = "Tagger"
local TAGGER_MACRO_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local function find_tag_spell()
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
            "#showtooltip\n/%s %s\n/cast [harm,nodead] %s",
            target_command,
            target_name,
            spell_name
        )
    else
        macro_body = string.format("/%s %s", target_command, target_name)
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

local function apply_mode(requested_mode, requested_target_name, requested_target_command)
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
    target_name = requested_target_name
    target_command = requested_target_command
    quest_stage = requested_mode == "QUEST" and "TARGET" or nil

    if requested_mode == "TAG" or requested_mode == "QUEST" then
        if not configure_macro(requested_mode) then
            if not target_name then
                print("Tagger: Enter a target name: /tag <name>")
            elseif requested_mode == "TAG" then
                print("Tagger: No supported tag ability found for your character.")
            end
            return
        end

        set_wheel_command("MACRO " .. TAGGER_MACRO_NAME)
        mode = requested_mode

        if requested_mode == "QUEST" then
            target_quest_npc()
        end

        if requested_mode == "TAG" then
            print("Tagger: TAG mode enabled - " .. (tag_spell and tag_spell.name or "unknown") .. " -> " .. target_name)
        else
            print("Tagger: QUEST mode enabled - target and interact with the wheel; quests auto-select and accept.")
        end
    else
        target_name = nil
        target_command = nil
        quest_stage = nil
        print("Tagger: mouse-wheel overrides disabled.")
    end
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
        print("Tagger: tag spell succeeded on the requested target; disabling tag mode.")
        apply_mode("OFF")
    else
        print("Tagger: tag spell succeeded, but the current target was not the requested target.")
    end
end

local function handle_tag_command(message)
    local target = string.match(message or "", "^%s*(.-)%s*$")

    if target == "" then
        apply_mode("OFF")
    else
        apply_mode("TAG", target, "target")
    end
end

local function handle_tagger_command(message)
    local command, argument = string.match(message or "", "^%s*(%S+)%s*(.-)%s*$")
    command = command and string.lower(command)

    if not command then
        if mode == "OFF" then
            print("Tagger: /tag <NPC> to tag, /tag to disable")
            print("Tagger: /tagger quest <NPC> to target and accept quests")
            print("Tagger: /tagger exact <NPC> or /tagger exactquest <NPC>")
            print("Tagger: /tagger status, /tagger off")
        else
            print_status()
        end
    elseif command == "status" then
        print_status()
    elseif command == "off" then
        apply_mode("OFF")
    elseif command == "exact" and argument ~= "" then
        apply_mode("TAG", argument, "targetexact")
    elseif command == "quest" and argument ~= "" then
        apply_mode("QUEST", argument, "target")
    elseif command == "exactquest" and argument ~= "" then
        apply_mode("QUEST", argument, "targetexact")
    else
        print("Tagger: /tag <NPC> to enable, /tag to disable")
        print("Tagger: /tagger exact <NPC>")
        print("Tagger: /tagger quest <NPC>, /tagger exactquest <NPC>")
        print("Tagger: /tagger status, /tagger off")
    end
end

local event_frame = CreateFrame("Frame")
event_frame:RegisterEvent("PLAYER_LOGIN")
event_frame:RegisterEvent("PLAYER_REGEN_ENABLED")
event_frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
event_frame:RegisterEvent("PLAYER_TARGET_CHANGED")
event_frame:RegisterEvent("QUEST_GREETING")
event_frame:RegisterEvent("GOSSIP_SHOW")
event_frame:RegisterEvent("QUEST_DETAIL")
event_frame:RegisterEvent("QUEST_ACCEPT_CONFIRM")
event_frame:RegisterEvent("QUEST_ACCEPTED")
event_frame:RegisterEvent("QUEST_FINISHED")
event_frame:SetScript("OnEvent", function(_, event, unit, _, spell_id)
    if event == "PLAYER_LOGIN" then
        binding_owner = CreateFrame("Frame", ADDON_NAME .. "BindingOwner", UIParent)
        SLASH_TAG1 = "/tag"
        _G.SlashCmdList.TAG = handle_tag_command
        SLASH_TAGGER1 = "/tagger"
        _G.SlashCmdList.TAGGER = handle_tagger_command
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        handle_successful_cast(unit, spell_id)
    elseif event == "PLAYER_TARGET_CHANGED" then
        target_quest_npc()
    elseif event == "QUEST_GREETING" then
        select_first_greeting_quest()
    elseif event == "GOSSIP_SHOW" then
        select_first_gossip_quest()
    elseif event == "QUEST_DETAIL" then
        accept_quest_detail()
    elseif event == "QUEST_ACCEPT_CONFIRM" then
        confirm_quest_acceptance()
    elseif event == "QUEST_ACCEPTED" then
        if mode == "QUEST" then
            quest_stage = "INTERACT"
        end
    elseif event == "QUEST_FINISHED" and mode == "QUEST" then
        print("Tagger: quest interaction finished; disabling quest mode.")
        apply_mode("OFF")
    elseif pending_mode then
        local requested_mode = pending_mode
        apply_mode(requested_mode, pending_target_name, pending_target_command)
    end
end)
