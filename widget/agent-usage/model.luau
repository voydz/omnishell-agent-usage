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

local SLOTS = { "primary", "secondary", "tertiary" }
local SLOT_LABELS = { primary = "Usage", secondary = "Secondary", tertiary = "Tertiary" }
local MAX_DETAIL_ROWS = 12

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

local function plan(usage, name)
    local label = text(usage.loginMethod)
    if not label then
        return nil
    end
    local prefix = string.lower(name) .. " "
    if string.lower(string.sub(label, 1, #prefix)) == prefix and #label > #prefix then
        label = string.sub(label, #prefix + 1)
    end
    return capitalize(label)
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

local function details(entry, usage)
    local rows = {}
    local credits = object(entry.credits)
    local remaining = credits and number(credits.remaining)
    if remaining and remaining > 0 then
        rows[#rows + 1] = { label = "Credits left", value = string.format("%.1f", remaining) }
    end
    for _, section in object(usage.details) or {} do
        for _, raw in object(section) and object(section.rows) or {} do
            local row = object(raw)
            local label = row and text(row.label)
            local value = row and (text(row.value) or (number(row.value) and tostring(row.value)))
            if label and value and #rows < MAX_DETAIL_ROWS then
                rows[#rows + 1] = { label = label, value = value, note = text(row.secondaryValue) }
            end
        end
    end
    return rows
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

-- Returns `snapshot, problem`. A snapshot is only returned when the provider
-- reported usage; `problem` is the provider's or server's own message.
function M.read(id, body)
    local root = object(body)
    if not root then
        return nil, nil
    end
    if text(root.error) then
        return nil, root.error
    end
    local entry
    for _, raw in root do
        local item = object(raw)
        if item and item.provider == id and (not entry or (object(item.usage) and not object(entry.usage))) then
            entry = item
        end
    end
    if not entry then
        return nil, nil
    end
    local failure = object(entry.error)
    local problem = failure and (text(failure.message) or "The provider reported an error.") or nil
    local usage = object(entry.usage)
    if not usage then
        return nil, problem
    end
    local name = M.name(id)
    local list = windows(entry, usage)
    return {
        plan = plan(usage, name),
        windows = list,
        headline = headline(list),
        spend = spend(usage),
        rows = details(entry, usage),
        updatedAt = M.time(usage.updatedAt),
    }, problem
end

return M
