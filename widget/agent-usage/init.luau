-- Agent usage: a bar button and popout showing AI subscription usage read
-- from a local `codexbar serve` (see README.md).

interval = 30

local look = require("../lib/look")
local model = require("@self/model")

local SYMBOL = "sparkles"
local TRACK = "foreground/0.08"
local DEFAULT_PROVIDERS = { "codex", "cursor", "copilot" }
local MAX_PROVIDERS = 12
local CONCURRENCY = 4
local REQUEST_TIMEOUT = 60
local RETRY_SECONDS = 20
local SETTLE_SECONDS = 0.1

-- One VM serves every display, so data and the polling loop live here and
-- `ctx.state` only carries a revision that makes the host redraw.
local config = { providers = DEFAULT_PROVIDERS, port = 18487, refresh = 120, percent = true }
local store = {}
local loop = { generation = 0, active = 0, queue = {}, requests = {}, timer = nil, beat = nil, target = nil,
    retry = false, stalled = nil }

local poll

local function providers(value)
    if type(value) ~= "table" then
        return DEFAULT_PROVIDERS
    end
    local list, seen = {}, {}
    for _, raw in value do
        local id = type(raw) == "string" and string.lower(raw) or ""
        if string.match(id, "^[%w][%w_%-]*$") and not seen[id] and #list < MAX_PROVIDERS then
            seen[id] = true
            list[#list + 1] = id
        end
    end
    return list
end

local function configure(ctx)
    local settings = ctx.data.settings or {}
    local port, refresh = settings.port, settings.refresh
    config.providers = providers(settings.providers)
    config.port = if type(port) == "number" and port >= 1024 and port <= 65535 then math.floor(port) else 18487
    config.refresh = if type(refresh) == "number" then math.clamp(refresh, 60, 3600) else 120
    config.percent = settings.percent ~= false
end

-- What a poll fetches; a change means the last poll no longer matches the options.
local function target()
    return table.concat(config.providers, ",") .. ":" .. config.port
end

local function touch(state)
    state.revision = (state.revision or 0) + 1
end

local function failure(result)
    if result.error == "network_not_approved" then
        return "Allow this widget to reach 127.0.0.1 when OmniWM asks.", true
    end
    if result.error == "network_denied" or result.error == "network_blocked" then
        return "Access to 127.0.0.1 is denied. Change it in Settings > Network & Permissions.", false
    end
    if result.status == 0 then
        return string.format("The CodexBar server is not answering on port %d.", config.port), true
    end
    if result.error == "http_status" then
        return string.format("The CodexBar server answered HTTP %d.", result.status), false
    end
    return "The CodexBar server sent a response this widget cannot read.", false
end

local function schedule(state)
    local delay = if loop.retry then math.min(RETRY_SECONDS, config.refresh) else config.refresh
    local generation = loop.generation
    local timer, err = omniwm.after(delay, function()
        if generation == loop.generation then
            loop.timer = nil
            poll(state, false)
        end
    end)
    loop.timer = timer
    loop.stalled = if timer then nil else tostring(err)
end

local function pump(state, force)
    local generation = loop.generation
    while loop.active < CONCURRENCY and #loop.queue > 0 do
        local id = table.remove(loop.queue, 1)
        local entry = store[id] or {}
        store[id] = entry
        local url = string.format("http://127.0.0.1:%d/usage?provider=%s%s", config.port, id,
            force and "&refresh=1" or "")
        local request, err = omniwm.http({
            url = url, response = "json", timeout = REQUEST_TIMEOUT, maxBytes = 1048576,
        }, function(result)
            if generation ~= loop.generation then
                return
            end
            loop.requests[id] = nil
            local snapshot, problem = model.read(id, result.json)
            if not snapshot and not problem then
                local retry
                problem, retry = failure(result)
                loop.retry = loop.retry or retry
            end
            if snapshot then
                entry.snapshot = snapshot
                entry.fetchedAt = os.time()
            end
            entry.error = problem
            loop.active -= 1
            touch(state)
            pump(state, force)
        end)
        if request then
            loop.active += 1
            loop.requests[id] = request
        else
            entry.error = "Could not start the request: " .. tostring(err)
        end
    end
    if loop.active == 0 and #loop.queue == 0 then
        schedule(state)
    end
end

poll = function(state, force)
    if loop.timer then
        loop.timer:cancel()
        loop.timer = nil
    end
    for _, request in loop.requests do
        request:cancel()
    end
    loop.generation += 1
    loop.active = 0
    loop.requests = {}
    loop.retry = false
    loop.beat = os.time()
    loop.target = target()
    loop.queue = table.clone(config.providers)
    touch(state)
    pump(state, force)
end

-- Starts the loop, or restarts it when it has gone quiet (its timer and
-- requests end with the display instance that created them).
local function ensure(ctx)
    configure(ctx)
    if not loop.beat or os.time() - loop.beat > config.refresh + REQUEST_TIMEOUT * 3 then
        poll(ctx.state, false)
    end
end

-- Reads the options while drawing and, when the provider list or port has
-- changed since the last poll, fetches again without waiting for the timer.
local function follow(ctx)
    configure(ctx)
    if loop.beat and loop.target ~= target() then
        local state = ctx.state
        loop.target = target()
        omniwm.after(SETTLE_SECONDS, function()
            poll(state, false)
        end)
    end
end

local function refresh(ctx)
    configure(ctx)
    if loop.active > 0 and loop.beat and os.time() - loop.beat < REQUEST_TIMEOUT then
        return
    end
    poll(ctx.state, true)
end

function trigger(ctx, event)
    if event.name == "refresh" then
        refresh(ctx)
    else
        ensure(ctx)
    end
end

local function tint(used)
    if used >= 1 then
        return "error"
    end
    return if used >= 0.8 then "warning" else nil
end

local function stale(entry, now)
    return entry.snapshot ~= nil
        and (entry.error ~= nil or now - (entry.fetchedAt or 0) > config.refresh * 3 + REQUEST_TIMEOUT)
end

-- The provider closest to a limit, for the bar slot and its tooltip.
local function summary(ctx)
    local top, parts, problem = nil, {}, nil
    for _, id in config.providers do
        local entry = store[id] or {}
        local used = entry.snapshot and entry.snapshot.headline
        problem = problem or entry.error
        if used then
            parts[#parts + 1] = string.format("%s %s", model.name(id), ctx.format.percent(used))
            top = if top and top > used then top else used
        end
    end
    local help = if #parts > 0 then table.concat(parts, " · ") else "Agent usage"
    return top, if problem then help .. "\n" .. problem else help, problem
end

function render(ctx)
    follow(ctx)
    -- Reading the clock redraws every `interval`, which also picks up data
    -- fetched on behalf of another display.
    local _ = ctx.data.seconds
    local top, help, problem = summary(ctx)
    local scale = look.scale(ctx)
    local color = top and tint(top)
    local props = { onClick = ui.popout, help = help }
    props[#props + 1] = look.glyph{ name = SYMBOL, size = look.px(ctx, "symbol"),
        color = color or (if top then nil elseif problem then "warning" else "mutedForeground") }
    if top and config.percent then
        local vertical = ctx.data.bar.style.vertical
        props[#props + 1] = look.text{ text = ctx.format.percent(top), color = color,
            size = if vertical then 10 * scale else look.px(ctx, "text"),
            reserve = if vertical then nil else ctx.format.percent(1) }
    end
    return look.bar(ctx, props)
end

local function resetLine(item, now)
    if item.resetsAt then
        local left = item.resetsAt - now
        return if left > 0 then "Resets in " .. model.duration(left) else "Reset due"
    end
    return item.resetText
end

local function meter(ctx, inner, label, value, used, note)
    local color = tint(used)
    local column = { w = inner, gap = 5, center = false,
        ui.row{ w = inner, gap = 8,
            look.text{ text = label, size = 12, grow = 1 },
            look.text{ text = value, size = 12, weight = "medium", color = color } },
        ui.progress{ value = used, w = inner, h = 4, radius = 2, fill = TRACK, color = color or "accent" } }
    if note then
        column[#column + 1] = look.text{ text = note, size = 11, color = "secondaryForeground", maxWidth = inner }
    end
    return ui.column(column)
end

local function detail(inner, row)
    local column = { w = inner, gap = 3, center = false,
        ui.row{ w = inner, gap = 8,
            look.text{ text = row.label, size = 12, grow = 1 },
            look.text{ text = row.value, size = 12, weight = "medium" } } }
    if row.note then
        column[#column + 1] = look.text{ text = row.note, size = 11, color = "secondaryForeground", maxWidth = inner }
    end
    return ui.column(column)
end

local function notice(text, width, color)
    return look.text{ text = text, size = 11, color = color or "secondaryForeground", maxWidth = width, lines = 4 }
end

local function card(ctx, id, now, width, inner, shared)
    local entry = store[id] or {}
    local snapshot = entry.snapshot
    local title = { w = inner, gap = 8,
        look.text{ text = model.name(id), size = 13, weight = "semibold", grow = 1 } }
    if snapshot and stale(entry, now) then
        title[#title + 1] = look.text{ text = "Stale", size = 11, color = "warning" }
    end
    if snapshot and snapshot.plan then
        title[#title + 1] = look.text{ text = snapshot.plan, size = 11, color = "secondaryForeground" }
    end
    local group = { w = width, gap = 10, ui.row(title) }
    if snapshot then
        local first = snapshot.windows[1]
        for _, item in snapshot.windows do
            -- Sub-lanes reset with the first window, so one countdown covers them.
            group[#group + 1] = meter(ctx, inner, item.label, ctx.format.percent(item.used), item.used,
                if item.lane then nil else resetLine(item, now))
        end
        local spend = snapshot.spend
        if spend then
            local value = model.money(spend.used, spend.currency) .. " / " .. model.money(spend.limit, spend.currency)
            local sameReset = first and first.resetsAt and first.resetsAt == spend.resetsAt
            group[#group + 1] = meter(ctx, inner, spend.label, value, math.clamp(spend.used / spend.limit, 0, 1),
                if sameReset then nil else resetLine(spend, now))
        end
        for _, row in snapshot.rows do
            group[#group + 1] = detail(inner, row)
        end
        if #snapshot.windows == 0 and not spend and #snapshot.rows == 0 then
            group[#group + 1] = notice("No usage figures reported.", inner)
        end
    end
    if entry.error and not shared then
        group[#group + 1] = notice(entry.error, inner, "warning")
    elseif not snapshot and not entry.error then
        group[#group + 1] = notice("Loading…", inner)
    end
    return look.group(group)
end

-- One message when every provider failed the same way (server down, consent).
local function sharedProblem()
    local problem
    for _, id in config.providers do
        local entry = store[id]
        if not entry or not entry.error or (problem and problem ~= entry.error) then
            return nil
        end
        problem = entry.error
    end
    return if #config.providers > 1 then problem else nil
end

local function status(now)
    if loop.active > 0 or #loop.queue > 0 then
        return "Refreshing…"
    end
    local latest
    for _, id in config.providers do
        local fetched = store[id] and store[id].fetchedAt
        if fetched and (not latest or fetched > latest) then
            latest = fetched
        end
    end
    if not latest then
        return "No data yet"
    end
    local age = now - latest
    return if age < 60 then "Updated just now" else "Updated " .. model.duration(age) .. " ago"
end

function popout(ctx)
    follow(ctx)
    local _ = ctx.data.seconds
    local now = os.time()
    local width = look.panelWidth("agent-usage")
    local inner = width - 24
    local props = { w = width + 32, pad = 16, gap = 12, scroll = true,
        ui.row{ w = width, gap = 8,
            look.text{ text = "Agent usage", size = 14, weight = "semibold", grow = 1 },
            look.text{ text = status(now), size = 11, color = "secondaryForeground" },
            look.button("arrow.clockwise", refresh, { key = "refresh", help = "Refresh now" }) } }
    local shared = sharedProblem()
    if shared then
        props[#props + 1] = look.group{ w = width, notice(shared, inner, "warning") }
    end
    if loop.stalled then
        props[#props + 1] = look.group{ w = width,
            notice("Automatic refresh stopped: " .. loop.stalled, inner, "warning") }
    end
    if #config.providers == 0 then
        props[#props + 1] = look.group{ w = width,
            notice("No providers selected. Add CodexBar provider IDs in this widget's options.", inner) }
    end
    for _, id in config.providers do
        local entry = store[id]
        if not shared or (entry and entry.snapshot) then
            props[#props + 1] = card(ctx, id, now, width, inner, shared ~= nil)
        end
    end
    return look.panel(ctx, props)
end
