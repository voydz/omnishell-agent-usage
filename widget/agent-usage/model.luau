-- Turns a CodexBar `/usage` response into the rows the widget draws.
-- Everything here is pure: no host services, no clock.

local M = {}

local NAMES = {
    claude = "Claude",
    codex = "Codex",
    copilot = "Copilot",
    cursor = "Cursor",
    gemini = "Gemini",
    openai = "OpenAI",
    opencode = "OpenCode",
    openrouter = "OpenRouter",
    zai = "Z.ai",
}

-- Corrections to detail rows whose CodexBar label misleads, by provider and
-- original label. OpenRouter's "API key used" is the key's all-time spend, but
-- sits between a limit and a remainder that reset monthly.
local ROW_FIXES = {
    openrouter = {
        ["API key used"] = { label = "API key used all time", last = true },
    },
}

local SLOTS = { "primary", "secondary", "tertiary" }
local SLOT_LABELS = { primary = "Usage", secondary = "Secondary", tertiary = "Tertiary" }
local MAX_DETAIL_ROWS = 12
local GLANCE_ROWS = 3
local MAX_STATS = 4

-- JSON null decodes to a userdata sentinel, so these also reject it.
local function object(value)
    return if type(value) == "table" then value else nil
end

local function number(value)
    return if type(value) == "number" and value == value and math.abs(value) ~= math.huge then value else nil
end

local function text(value)
    return if type(value) == "string" and value ~= "" then value else nil
end

local function capitalize(value)
    return string.upper(string.sub(value, 1, 1)) .. string.sub(value, 2)
end

function M.name(id)
    return NAMES[id] or capitalize(id)
end

-- ISO 8601 timestamp to Unix seconds; nil when it cannot be read.
function M.time(value)
    if type(value) ~= "string" then
        return nil
    end
    local year, month, day, hour, minute, second, rest =
        string.match(value, "^(%d%d%d%d)%-(%d%d)%-(%d%d)[Tt ](%d%d):(%d%d):(%d%d)(.*)$")
    if not year then
        return nil
    end
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if month < 1 or month > 12 or day < 1 or day > 31 then
        return nil
    end
    if month <= 2 then
        year -= 1
    end
    local era = year // 400
    local yearOfEra = year - era * 400
    local dayOfYear = (153 * ((month + 9) % 12) + 2) // 5 + day - 1
    local dayOfEra = yearOfEra * 365 + yearOfEra // 4 - yearOfEra // 100 + dayOfYear
    local seconds = (era * 146097 + dayOfEra - 719468) * 86400
        + tonumber(hour) * 3600 + tonumber(minute) * 60 + tonumber(second)
    local sign, offsetHours, offsetMinutes = string.match(rest, "([+-])(%d%d):?(%d%d)$")
    if sign then
        local offset = tonumber(offsetHours) * 3600 + tonumber(offsetMinutes) * 60
        seconds -= if sign == "-" then -offset else offset
    end
    return seconds
end

function M.duration(seconds)
    local minutes = math.floor(seconds / 60)
    if minutes < 1 then
        return "under a minute"
    end
    local days, hours = minutes // 1440, (minutes % 1440) // 60
    if days > 0 then
        return if hours > 0 then string.format("%dd %dh", days, hours) else string.format("%dd", days)
    end
    if hours > 0 then
        return string.format("%dh %dm", hours, minutes % 60)
    end
    return string.format("%dm", minutes)
end

function M.money(amount, currency)
    if currency == nil or currency == "USD" then
        return string.format("$%.2f", amount)
    end
    return string.format("%.2f %s", amount, currency)
end

local function span(minutes)
    if not minutes or minutes <= 0 then
        return nil
    end
    if minutes % 1440 == 0 then
        local days = minutes // 1440
        if days == 1 then
            return "Daily"
        elseif days == 7 then
            return "Weekly"
        elseif days >= 28 and days <= 31 then
            return "Monthly"
        end
        return string.format("%d days", days)
    end
    if minutes % 60 == 0 then
        return string.format("%d hours", minutes // 60)
    end
    return string.format("%d minutes", minutes)
end

local function window(raw, label)
    local value = object(raw)
    local used = value and number(value.usedPercent)
    if not used then
        return nil
    end
    local minutes = number(value.windowMinutes)
    return {
        label = label or span(minutes),
        used = math.clamp(used / 100, 0, 1),
        minutes = minutes,
        resetsAt = M.time(value.resetsAt),
        resetText = text(value.resetDescription),
    }
end

-- Drops a lead-in the surrounding heading already says: "Cursor Enterprise"
-- under Cursor becomes "Enterprise", "API key limit" under API key, "Limit".
local function trim(label, lead)
    local prefix = string.lower(lead) .. " "
    if string.lower(string.sub(label, 1, #prefix)) == prefix and #label > #prefix then
        label = string.sub(label, #prefix + 1)
    end
    return capitalize(label)
end

local function plan(usage, name)
    local label = text(usage.loginMethod)
    return label and trim(label, name)
end

local function windows(entry, usage)
    local labels = object(entry.rateWindowLabels) or {}
    local list = {}
    local first
    for _, slot in SLOTS do
        local item = window(usage[slot], text(labels[slot]))
        if item then
            item.label = item.label or SLOT_LABELS[slot]
            -- A later window with the primary's exact period subdivides it
            -- (Cursor's "Third Party") rather than limiting on its own.
            item.lane = first ~= nil and item.resetsAt ~= nil
                and item.resetsAt == first.resetsAt and item.minutes == first.minutes
            first = first or item
            list[#list + 1] = item
        end
    end
    for _, extra in object(usage.extraRateWindows) or {} do
        local raw = object(extra)
        local item = raw and window(raw.window, text(raw.title))
        if item then
            item.label = item.label or "Extra"
            item.extra = true
            list[#list + 1] = item
        end
    end
    return list
end

local function spend(usage)
    local cost = object(usage.providerCost)
    local used, limit = cost and number(cost.used), cost and number(cost.limit)
    if not used or not limit or limit <= 0 then
        return nil
    end
    local period = text(cost.period)
    return {
        label = if period then period .. " spend" else "Spend",
        used = used,
        limit = limit,
        currency = text(cost.currencyCode),
        resetsAt = M.time(cost.resetsAt),
    }
end

local function amount(value, unit)
    if unit and string.match(unit, "^%u%u%u$") then
        return M.money(value, unit)
    end
    local shown = if value % 1 == 0 then string.format("%d", value) else string.format("%.2f", value)
    return if unit then shown .. " " .. unit else shown
end

-- The figures a provider charts (OpenRouter: spend today, this week, this
-- month), from the first detail section that has any.
local function stats(usage)
    for _, section in object(usage.details) or {} do
        local chart = object(section) and object(section.chart)
        local list = {}
        for _, raw in chart and object(chart.points) or {} do
            local point = object(raw)
            local label, value = point and text(point.label), point and number(point.value)
            if label and value and #list < MAX_STATS then
                list[#list + 1] = { label = label, value = amount(value, text(chart.unit)) }
            end
        end
        if #list > 0 then
            return list, section
        end
    end
    return {}, nil
end

-- CodexBar's placeholder for a figure it could not get, such as OpenRouter's
-- 30-day spend without a Management API key.
local function missing(value)
    return string.match(string.lower(value), "^unavailable") ~= nil
end

-- Puts the expanded rows under their section titles when they come from more
-- than one section; the first row of each section carries the heading.
local function sectioned(rows)
    local titles, last = 0, nil
    for _, row in rows do
        if row.section ~= last then
            titles += 1
            last = row.section
        end
    end
    if titles < 2 then
        return
    end
    last = nil
    for _, row in rows do
        local title = row.section
        if title then
            row.heading = if title ~= last then title else nil
            row.label = trim(row.label, title)
        end
        last = title
    end
end

-- Detail rows, split into the few shown at a glance and the rest. A card that
-- already leads with meters or stats keeps its rows for the expanded view.
local function details(id, entry, usage, charted, section, lead)
    local glance, more = {}, {}
    local function add(row, pinned)
        if #glance + #more >= MAX_DETAIL_ROWS then
            return
        end
        if pinned or (not lead and #glance < GLANCE_ROWS) then
            glance[#glance + 1] = row
        else
            more[#more + 1] = row
        end
    end
    local credits = object(entry.credits)
    local remaining = credits and number(credits.remaining)
    if remaining and remaining > 0 then
        add({ label = "Credits left", value = string.format("%.1f", remaining) }, true)
    end
    local shown = {}
    for _, item in charted do
        shown[item.label] = true
    end
    local fixes = ROW_FIXES[id] or {}
    for _, group in object(usage.details) or {} do
        local trailing = {}
        for _, raw in object(group) and object(group.rows) or {} do
            local row = object(raw)
            local label = row and text(row.label)
            local value = row and (text(row.value) or (number(row.value) and tostring(row.value)))
            -- A row that repeats a charted figure would only say it twice, and
            -- one that only reports a figure as unavailable says nothing.
            if label and value and not (group == section and shown[label]) and not missing(value) then
                local fix = fixes[label]
                local item = { label = fix and fix.label or label, value = value, note = text(row.secondaryValue),
                    section = text(group.title) }
                if fix and fix.last then
                    trailing[#trailing + 1] = item
                else
                    add(item, false)
                end
            end
        end
        for _, item in trailing do
            add(item, false)
        end
    end
    sectioned(more)
    return glance, more
end

-- The tightest limit that stands on its own: sub-lanes and extra allowances
-- only show in the popout.
local function headline(list)
    local top
    for _, item in list do
        if not item.lane and not item.extra and (not top or item.used > top) then
            top = item.used
        end
    end
    return top
end

local function account(usage)
    local identity = object(usage.identity)
    return text(usage.accountEmail) or (identity and text(identity.accountEmail)) or nil
end

-- One account's snapshot; nil when the entry reports neither usage nor an
-- error. An entry with an error but no usage becomes an `empty` snapshot, so
-- the account still gets a card.
local function snapshot(id, entry)
    local failure = object(entry.error)
    local problem = failure and (text(failure.message) or "The provider reported an error.") or nil
    local usage = object(entry.usage)
    if not usage then
        if not problem then
            return nil
        end
        return { empty = true, problem = problem, windows = {}, stats = {}, rows = {}, more = {} }
    end
    local name = M.name(id)
    local list = windows(entry, usage)
    local cost = spend(usage)
    local charted, section = stats(usage)
    local rows, more = details(id, entry, usage, charted, section, #list > 0 or cost ~= nil or #charted > 0)
    return {
        account = account(usage),
        problem = problem,
        plan = plan(usage, name),
        windows = list,
        headline = headline(list),
        spend = cost,
        stats = charted,
        rows = rows,
        more = more,
        updatedAt = M.time(usage.updatedAt),
    }
end

-- Returns `snapshots, problem`. `snapshots` holds one snapshot per account in
-- the server's order (CodexBar reports every signed-in Codex account, one
-- account for other providers); each carries its own `problem`. The second
-- value is the server's message when it could not answer at all.
function M.read(id, body)
    local root = object(body)
    if not root then
        return nil, nil
    end
    if text(root.error) then
        return nil, root.error
    end
    local list = {}
    for _, raw in root do
        local entry = object(raw)
        if entry and entry.provider == id then
            local item = snapshot(id, entry)
            if item then
                list[#list + 1] = item
            end
        end
    end
    if #list == 0 then
        return nil, nil
    end
    return list, nil
end

return M
