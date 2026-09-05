addon.name = 'nbajam';
addon.author = 'Brunas';
addon.version = '1.0.0';
addon.desc = 'Plays NBA Jam callouts for Sidewinder, Slug Shot, TP, skillchains, and Quick Draw.';
addon.link = 'https://github.com/chrisalleng/nbajam';

require 'common';

local bit = require 'bit';
local chat = require 'chat';
local ffi = require 'ffi';
local logic = require 'logic';

ffi.cdef[[
    int __stdcall PlaySoundA(const char* pszSound, void* hmod, unsigned int fdwSound);
]];

local winmm = ffi.load('winmm');

local SND_ASYNC = 0x0001;
local SND_NODEFAULT = 0x0002;
local SND_FILENAME = 0x00020000;
local PLAY_FLAGS = bit.bor(SND_ASYNC, SND_NODEFAULT, SND_FILENAME);
local REBOUND_WINDOW_SECONDS = 10.0;
local COMBAT_CALLOUT_DELAY_SECONDS = 1.0;

local source_path = debug.getinfo(1, 'S').source;
if (source_path:sub(1, 1) == '@') then
    source_path = source_path:sub(2);
end
source_path = source_path:gsub('/', '\\');

local addon_path = source_path:match('^(.*\\)')
    or (AshitaCore:GetInstallPath() .. 'addons\\nbajam\\');
local sound_path = addon_path .. 'NBA Jam - Tournament Edition Sounds\\';

local sounds = {
    rebound = {
        '24 -  The Rebound (7.3k).wav',
    },
    skillchain = {
        "50 - He's On Fire (7.3k).wav",
        '52 Yes (slow).wav',
        '58 - Kaboom (slightly slow).wav',
    },
    close = {
        '23 - Monster Jam (6k).wav',
        '5 -  Hooks it in.wav',
        '72 - Lays it up.wav',
    },
    far = {
        '7 - From the Outside (7.3k).wav',
        '21 - From Downtown (6k).wav',
    },
    hit = {
        "6 - It's Good (7.3k).wav",
        '12 - For Two.wav',
        '20 - Count It.wav',
        '22 - Scores.wav',
        '27 - Hello.wav',
        '57 - Two Points (7.3k).wav',
    },
    miss = {
        '8 - Terrible Shot.wav',
        '9 -  Wild Shot.wav',
        '10 - Woah.wav',
        '11 - Ugly Shot.wav',
        '56 - No Good.wav',
        '77 - Rejected (7.3k).wav',
    },
    tp = {
        '51 Heating Up (slow).wav',
        '68 - Showtime.wav',
    },
    stolen = {
        '2 - Stolen.wav',
        '71 - Intercepted (7.3k).wav',
    },
    quickdraw = {
        '3 - Razzle Dazzle.wav',
    },
};

local state = {
    enabled = true,
    previous_tp = nil,
    shot_misses = {},
    last_callout = nil,
    schedule_generation = 0,
};

local function message(text)
    print(chat.header(addon.name):append(chat.message(text)));
end

local function error_message(text)
    print(chat.header(addon.name):append(chat.error(text)));
end

local function choose(values)
    return values[math.random(1, #values)];
end

local function play_callout(kind)
    if (not state.enabled) then
        return false;
    end

    local choices = sounds[kind];
    if (choices == nil or #choices == 0) then
        return false;
    end

    local filename = choose(choices);
    local full_path = sound_path .. filename;
    if (not ashita.fs.exists(full_path)) then
        error_message(('Sound file is missing: %s'):fmt(filename));
        return false;
    end

    -- PlaySound uses one process-wide asynchronous channel. A new call replaces
    -- the old one, so NBA Jam sounds never overlap each other.
    local result = winmm.PlaySoundA(full_path, nil, PLAY_FLAGS);
    if (result == 0) then
        error_message(('Could not play sound: %s'):fmt(filename));
        return false;
    end

    state.last_callout = kind;
    return true;
end

local function schedule_callout(kind, delay)
    local generation = state.schedule_generation;
    ashita.tasks.once(delay or COMBAT_CALLOUT_DELAY_SECONDS, function ()
        if (state.schedule_generation == generation) then
            play_callout(kind);
        end
    end);
end

local function get_player_id()
    local party = AshitaCore:GetMemoryManager():GetParty();
    if (party:GetMemberIsActive(0) == 0) then
        return 0;
    end
    return party:GetMemberServerId(0);
end

local function get_tp()
    local party = AshitaCore:GetMemoryManager():GetParty();
    if (party:GetMemberIsActive(0) == 0 or party:GetMemberServerId(0) == 0) then
        return nil;
    end
    return party:GetMemberTP(0);
end

local function observe_tp()
    local tp = get_tp();
    if (tp == nil) then
        state.previous_tp = nil;
        return false;
    end

    local crossed = logic.crossed_tp_threshold(state.previous_tp, tp);
    state.previous_tp = tp;
    return crossed;
end

local function get_current_target_id()
    local memory = AshitaCore:GetMemoryManager();
    local index = memory:GetTarget():GetTargetIndex(0);
    if (index == nil or index == 0) then
        return 0;
    end
    return memory:GetEntity():GetServerId(index);
end

local function is_alliance_member(actor_id)
    local party = AshitaCore:GetMemoryManager():GetParty();
    for index = 0, 17 do
        if (party:GetMemberIsActive(index) == 1
            and party:GetMemberServerId(index) == actor_id) then
            return true;
        end
    end

    return false;
end

local function is_alliance_pet(actor_id)
    local memory = AshitaCore:GetMemoryManager();
    local party = memory:GetParty();
    local entity = memory:GetEntity();

    for index = 0, 17 do
        if (party:GetMemberIsActive(index) == 1) then
            local member_index = party:GetMemberTargetIndex(index);
            if (member_index ~= nil and member_index > 0) then
                local pet_index = entity:GetPetTargetIndex(member_index);
                if (pet_index ~= nil
                    and pet_index > 0
                    and entity:GetServerId(pet_index) == actor_id) then
                    return true;
                end
            end
        end
    end

    return false;
end

local function get_alliance_entity_index(actor_id)
    local party = AshitaCore:GetMemoryManager():GetParty();
    local entity = AshitaCore:GetMemoryManager():GetEntity();
    for index = 0, 17 do
        if (party:GetMemberIsActive(index) == 1
            and party:GetMemberServerId(index) == actor_id) then
            local entity_index = party:GetMemberTargetIndex(index);
            if (entity_index ~= nil
                and entity_index > 0
                and entity:GetServerId(entity_index) == actor_id) then
                return entity_index;
            end
        end
    end

    return nil;
end

local function get_entity_index(server_id)
    local entity = AshitaCore:GetMemoryManager():GetEntity();
    local packed_index = bit.band(server_id, 0x7FF);
    if (packed_index < 0x400 and entity:GetServerId(packed_index) == server_id) then
        return packed_index;
    end

    for index = 0x400, 0x8FF do
        if (entity:GetServerId(index) == server_id) then
            return index;
        end
    end

    return nil;
end

local function get_distance_between(actor_id, target_id)
    local actor_index = get_alliance_entity_index(actor_id);
    local target_index = get_entity_index(target_id);
    if (actor_index == nil or target_index == nil) then
        return nil;
    end

    local entity = AshitaCore:GetMemoryManager():GetEntity();
    local dx = entity:GetLocalPositionX(actor_index) - entity:GetLocalPositionX(target_index);
    local dy = entity:GetLocalPositionY(actor_index) - entity:GetLocalPositionY(target_index);
    local dz = entity:GetLocalPositionZ(actor_index) - entity:GetLocalPositionZ(target_index);
    return math.sqrt((dx * dx) + (dy * dy) + (dz * dz));
end

-- Parses FFXI's bit-packed incoming 0x28 action packet. The layout matches
-- Ashita v4.30's ashita.bits API and the standard v4 action packet structure.
local function parse_action_packet(e)
    local bit_offset = 40;
    local max_bits = e.size * 8;
    local malformed = false;

    local function read(length)
        if (bit_offset + length > max_bits) then
            malformed = true;
            return 0;
        end
        local value = ashita.bits.unpack_be(e.data_raw, bit_offset, length);
        bit_offset = bit_offset + length;
        return value;
    end

    local packet = {
        actor_id = read(32),
        target_count = read(6),
        result_count = read(4),
        category = read(4),
        param = read(32),
        recast = read(32),
        targets = {},
    };

    for i = 1, packet.target_count do
        local target = {
            id = read(32),
            action_count = read(4),
            actions = {},
        };

        for j = 1, target.action_count do
            local action = {
                miss = read(3),
                kind = read(2),
                sub_kind = read(12),
                info = read(5),
                scale = read(5),
                param = read(17),
                message = read(10),
                flags = read(31),
                has_proc = false,
                proc_animation = nil,
            };

            action.has_proc = read(1) == 1;
            if (action.has_proc) then
                action.proc_animation = read(6);
                action.proc_effect = read(4);
                action.proc_param = read(17);
                action.proc_message = read(10);
            end

            action.has_reaction = read(1) == 1;
            if (action.has_reaction) then
                action.reaction_animation = read(6);
                action.reaction_effect = read(4);
                action.reaction_param = read(14);
                action.reaction_message = read(10);
            end

            target.actions[j] = action;
        end

        packet.targets[i] = target;
    end

    if (malformed) then
        return nil;
    end
    return packet;
end

local function action_has_skillchain(action)
    return action ~= nil
        and action.has_proc
        and logic.is_skillchain_animation(action.proc_animation);
end

local function prune_shot_misses(now)
    for actor_id, miss_time in pairs(state.shot_misses) do
        if (now - miss_time > REBOUND_WINDOW_SECONDS or now < miss_time) then
            state.shot_misses[actor_id] = nil;
        end
    end
end

local function handle_action_packet(e)
    local packet = parse_action_packet(e);
    if (packet == nil) then
        return;
    end

    local player_id = get_player_id();
    if (player_id == 0) then
        return;
    end

    local action_id = bit.band(packet.param, 0xFFFF);
    local primary_target = packet.targets[1];
    local primary_action = primary_target and primary_target.actions[1] or nil;
    local tp_crossed = observe_tp();
    local is_power_shot = logic.is_power_shot(packet.category, action_id)
        and primary_target ~= nil
        and primary_action ~= nil;
    local is_alliance_power_shot = is_power_shot
        and is_alliance_member(packet.actor_id);

    -- Quick Draw is an independent action rather than part of the power-shot
    -- priority chain.
    if (packet.actor_id == player_id and logic.is_quick_draw(packet.category, action_id)) then
        schedule_callout('quickdraw');
        return;
    end

    -- Highest priority: another alliance player, Trust, pet, or automaton
    -- closes a skillchain on our current target while we have enough TP to
    -- weapon skill. These are the same skillchain-capable action categories
    -- and alliance ownership checks used by Chains.
    if (packet.actor_id ~= player_id
        and logic.is_skillchain_action_category(packet.category)
        and (get_tp() or 0) >= 1000
        and (is_alliance_member(packet.actor_id) or is_alliance_pet(packet.actor_id))) then
        local current_target_id = get_current_target_id();
        for _, target in ipairs(packet.targets) do
            if (target.id == current_target_id) then
                for _, action in ipairs(target.actions) do
                    if (action_has_skillchain(action)) then
                        -- If this action could also be a rebound, consume the
                        -- setup miss so it cannot trigger on a later shot.
                        if (is_alliance_power_shot) then
                            state.shot_misses = {};
                        end

                        schedule_callout('stolen');
                        return;
                    end
                end
            end
        end
    end

    -- Next priority: a different player connects with Sidewinder or Slug Shot
    -- within ten seconds of another player's miss with either skill. Any
    -- qualifying miss may be the setup, including one by the local player.
    if (is_alliance_power_shot) then
        local now = os.clock();
        local hit = primary_action.miss == 0 and primary_action.message ~= 188;
        prune_shot_misses(now);

        if (hit) then
            local missed_actor = logic.find_rebound_miss(
                state.shot_misses,
                packet.actor_id,
                now,
                REBOUND_WINDOW_SECONDS);

            if (missed_actor ~= nil) then
                state.shot_misses = {};
                schedule_callout('rebound');
                return;
            end
        else
            state.shot_misses[packet.actor_id] = now;
        end
    end

    -- After rebound: an alliance member's Sidewinder or Slug Shot.
    if (is_alliance_power_shot) then
        local distance = get_distance_between(packet.actor_id, primary_target.id);
        local hit = primary_action.miss == 0 and primary_action.message ~= 188;
        schedule_callout(logic.classify_power_shot(
            action_has_skillchain(primary_action),
            distance,
            hit,
            action_id));
        return;
    end

    -- Crossing from below 1000 TP to 1000 or more TP.
    if (tp_crossed) then
        play_callout('tp');
        return;
    end

end

local function print_help()
    message('Commands:');
    message('/nbajam on | off | status');
end

ashita.events.register('load', 'load_cb', function ()
    state.previous_tp = get_tp();

    local missing = 0;
    for _, choices in pairs(sounds) do
        for _, filename in ipairs(choices) do
            if (not ashita.fs.exists(sound_path .. filename)) then
                missing = missing + 1;
            end
        end
    end

    if (missing > 0) then
        error_message(('%u configured sound file(s) are missing. Reinstall the addon to restore them.'):fmt(missing));
    end
end);

ashita.events.register('unload', 'unload_cb', function ()
    state.schedule_generation = state.schedule_generation + 1;
    winmm.PlaySoundA(nil, nil, 0);
end);

ashita.events.register('packet_in', 'packet_in_cb', function (e)
    if (not state.enabled) then
        return;
    end

    if (e.id == 0x28) then
        handle_action_packet(e);
    end
end);

ashita.events.register('d3d_present', 'present_cb', function ()
    local tp_crossed = observe_tp();

    if (tp_crossed) then
        play_callout('tp');
    end
end);

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1]:lower() ~= '/nbajam') then
        return;
    end

    e.blocked = true;

    if (#args == 1 or (#args == 2 and args[2]:lower() == 'help')) then
        print_help();
        return;
    end

    local command = args[2]:lower();
    if (command == 'on') then
        state.enabled = true;
        state.previous_tp = get_tp();
        message('Enabled.');
        return;
    end

    if (command == 'off') then
        state.enabled = false;
        state.shot_misses = {};
        state.schedule_generation = state.schedule_generation + 1;
        winmm.PlaySoundA(nil, nil, 0);
        message('Disabled.');
        return;
    end

    if (command == 'status') then
        message(('Status: %s; TP: %s; last callout: %s.'):fmt(
            state.enabled and 'enabled' or 'disabled',
            tostring(get_tp() or 'unavailable'),
            state.last_callout or 'none'));
        return;
    end

    print_help();
end);
