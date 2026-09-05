local logic = {};

logic.SIDEWINDER_ID = 196;
logic.SLUG_SHOT_ID = 212;
logic.QUICK_DRAW_FIRST_ID = 125;
logic.QUICK_DRAW_LAST_ID = 132;

local power_shot_ranges = {
    [logic.SIDEWINDER_ID] = { close = 6.0, far = 15.0 },
    [logic.SLUG_SHOT_ID] = { close = 3.0, far = 10.0 },
};

local skillchain_action_categories = {
    [3] = true,  -- Player weapon skill
    [4] = true,  -- Blue Magic / Immanence spell
    [6] = true,  -- Job ability fallback used by chainbound abilities
    [11] = true, -- Trust/NPC TP move, BST pet, or PUP automaton
    [13] = true, -- Summoner Blood Pact
    [14] = true, -- Konzen-ittai / Wild Flourish
};

-- Returns the highest-priority Sidewinder / Slug Shot callout that applies.
function logic.classify_power_shot(has_skillchain, distance, hit, action_id)
    if (has_skillchain) then
        return 'skillchain';
    end

    if (not hit) then
        return 'miss';
    end

    local ranges = power_shot_ranges[action_id];
    if (ranges ~= nil and distance ~= nil and distance < ranges.close) then
        return 'close';
    end

    if (ranges ~= nil and distance ~= nil and distance > ranges.far) then
        return 'far';
    end

    return 'hit';
end

function logic.is_power_shot(category, action_id)
    return category == 3
        and (action_id == logic.SIDEWINDER_ID or action_id == logic.SLUG_SHOT_ID);
end

function logic.is_quick_draw(category, action_id)
    return category == 6
        and action_id >= logic.QUICK_DRAW_FIRST_ID
        and action_id <= logic.QUICK_DRAW_LAST_ID;
end

function logic.is_skillchain_animation(animation)
    return animation ~= nil and animation >= 1 and animation <= 16;
end

function logic.is_skillchain_action_category(category)
    return skillchain_action_categories[category] == true;
end

-- Returns the most recent qualifying miss actor, or nil when the hitter has no
-- rebound opportunity. A player cannot rebound their own missed power shot.
function logic.find_rebound_miss(misses, hitter_id, now, window_seconds)
    local match_id = nil;
    local match_time = -math.huge;

    for actor_id, miss_time in pairs(misses) do
        local age = now - miss_time;
        if (actor_id ~= hitter_id
            and age >= 0
            and age <= window_seconds
            and miss_time > match_time) then
            match_id = actor_id;
            match_time = miss_time;
        end
    end

    return match_id;
end

function logic.crossed_tp_threshold(previous_tp, current_tp)
    return previous_tp ~= nil and previous_tp < 1000 and current_tp >= 1000;
end

return logic;
