-- Run with: luau tests/model_test.luau
local model = require("../widget/agent-usage/model")

local failures = 0

local function check(name, actual, expected)
    if actual ~= expected then
        failures += 1
        print(string.format("FAIL %s: expected %s, got %s", name, tostring(expected), tostring(actual)))
    end
end

local function near(name, actual, expected)
    if type(actual) ~= "number" or math.abs(actual - expected) > 1e-9 then
        failures += 1
        print(string.format("FAIL %s: expected %s, got %s", name, tostring(expected), tostring(actual)))
    end
end

-- Stands in for the host's JSON null, which is a userdata sentinel.
local null = newproxy()

-- Timestamps
check("epoch", model.time("1970-01-01T00:00:00Z"), 0)
check("utc", model.time("2026-11-10T17:09:57Z"), 1794330597)
check("fraction", model.time("2026-11-10T17:09:57.123Z"), 1794330597)
check("positive offset", model.time("2026-11-10T18:09:57+01:00"), 1794330597)
check("negative offset", model.time("2026-11-10T06:17:24-08:00"), model.time("2026-11-10T14:17:24Z"))
check("leap day", model.time("2024-02-29T12:00:00Z"), 1709208000)
check("january", model.time("2027-01-01T00:00:00Z"), 1798761600)
check("not a date", model.time("Dec 1 at 1:00 AM"), nil)
check("null date", model.time(null), nil)

-- Durations and money
check("seconds", model.duration(42), "under a minute")
check("minutes", model.duration(59 * 60), "59m")
check("hours", model.duration(2 * 3600 + 38 * 60 + 10), "2h 38m")
check("days", model.duration(5 * 86400 + 23 * 3600 + 59), "5d 23h")
check("whole days", model.duration(3 * 86400), "3d")
check("usd", model.money(269.07, "USD"), "$269.07")
check("other currency", model.money(12.5, "EUR"), "12.50 EUR")

-- Names
check("known name", model.name("openrouter"), "OpenRouter")
check("unknown name", model.name("kilo"), "Kilo")

-- Codex: two independent limits, credits object with a zero limit
local codex = model.read("codex", { {
    provider = "codex",
    source = "oauth",
    rateWindowLabels = { primary = "Session", secondary = "Weekly" },
    credits = { remaining = 0 },
    usage = {
        loginMethod = "plus",
        primary = { usedPercent = 12, windowMinutes = 300, resetsAt = "2026-11-10T17:09:57Z" },
        secondary = { usedPercent = 55, windowMinutes = 10080, resetsAt = "2026-11-16T13:53:07Z" },
        tertiary = null,
        providerCost = { currencyCode = "Credits", limit = 0, used = 0, period = "Extra usage" },
        updatedAt = "2026-11-10T14:29:33Z",
    },
} })
check("codex plan", codex.plan, "Plus")
check("codex window count", #codex.windows, 2)
check("codex first label", codex.windows[1].label, "Session")
check("codex weekly is not a lane", codex.windows[2].lane, false)
near("codex headline is the tighter limit", codex.headline, 0.55)
check("codex zero limit has no spend row", codex.spend, nil)
check("codex zero credits has no row", #codex.rows, 0)
check("codex updatedAt", codex.updatedAt, model.time("2026-11-10T14:29:33Z"))

-- Cursor: sub-lanes share the primary's period, plus an extra allowance and spend
local reset = "2026-11-29T09:38:50Z"
local cursor = model.read("cursor", { {
    provider = "cursor",
    rateWindowLabels = { primary = "Total", secondary = "Cursor", tertiary = "Third Party" },
    usage = {
        loginMethod = "Cursor Enterprise",
        primary = { usedPercent = 37.8296, windowMinutes = 44640, resetsAt = reset },
        secondary = { usedPercent = 25.92, windowMinutes = 44640, resetsAt = reset },
        tertiary = { usedPercent = 100, windowMinutes = 44640, resetsAt = reset },
        extraRateWindows = { { id = "cursor-grok-bot", title = "Grok Bot", window = { usedPercent = 0 } } },
        providerCost = { currencyCode = "USD", limit = 360, used = 269.07, period = "Monthly", resetsAt = reset },
    },
} })
check("cursor plan drops the provider name", cursor.plan, "Enterprise")
check("cursor window count", #cursor.windows, 4)
check("cursor primary is not a lane", cursor.windows[1].lane, false)
check("cursor third party is a lane", cursor.windows[3].lane, true)
check("cursor extra flagged", cursor.windows[4].extra, true)
check("cursor extra label", cursor.windows[4].label, "Grok Bot")
near("cursor headline ignores the exhausted lane", cursor.headline, 0.378296)
check("cursor spend label", cursor.spend.label, "Monthly spend")
check("cursor spend limit", cursor.spend.limit, 360)

-- Copilot: no windows, only detail rows
local copilot = model.read("copilot", { {
    provider = "copilot",
    usage = {
        loginMethod = "Business",
        primary = null,
        secondary = null,
        tertiary = null,
        details = { { title = "Credits", rows = {
            { label = "Credits used", value = "0", secondaryValue = "Dec 1 at 1:00 AM", usageValue = 0 },
        } } },
    },
} })
check("copilot has no windows", #copilot.windows, 0)
check("copilot has no headline", copilot.headline, nil)
check("copilot row label", copilot.rows[1].label, "Credits used")
check("copilot row value", copilot.rows[1].value, "0")
check("copilot row note", copilot.rows[1].note, "Dec 1 at 1:00 AM")

-- Labels fall back to the window length, then to the slot
local unlabeled = model.read("kilo", { {
    provider = "kilo",
    usage = {
        primary = { usedPercent = 150, windowMinutes = 300 },
        secondary = { usedPercent = -5 },
    },
} })
check("label from window length", unlabeled.windows[1].label, "5 hours")
check("label from slot", unlabeled.windows[2].label, "Secondary")
check("percent clamps high", unlabeled.windows[1].used, 1)
check("percent clamps low", unlabeled.windows[2].used, 0)
check("no login method, no plan", unlabeled.plan, nil)

-- Credits and row limits
local credited = model.read("codex", { {
    provider = "codex",
    credits = { remaining = 112.44 },
    usage = { details = { { rows = {
        { label = "a", value = 1 }, { label = "b", value = "2" }, { label = "c", value = "3" },
        { label = "d", value = "4" }, { label = "e", value = "5" }, { label = "f", value = "6" },
        { label = "", value = "skipped" }, { label = "no value" },
    } } } },
} })
check("credits row", credited.rows[1].value, "112.4")
check("numeric row value", credited.rows[2].value, "1")
check("rows are capped", #credited.rows, 6)

-- Failures
local snapshot, problem = model.read("openrouter", { {
    provider = "openrouter",
    source = "auto",
    error = { kind = "provider", code = 1, message = "Enter an API key." },
} })
check("provider error has no snapshot", snapshot, nil)
check("provider error message", problem, "Enter an API key.")

snapshot, problem = model.read("nope", { error = "Unknown provider 'nope'." })
check("server error has no snapshot", snapshot, nil)
check("server error message", problem, "Unknown provider 'nope'.")

snapshot, problem = model.read("codex", { {
    provider = "codex",
    usage = { primary = { usedPercent = 10 } },
    error = { message = "Using last known usage." },
} })
near("usage survives alongside an error", snapshot.windows[1].used, 0.1)
check("error is still reported", problem, "Using last known usage.")

snapshot, problem = model.read("codex", { { provider = "cursor", usage = {} } })
check("other provider is ignored", snapshot, nil)
check("other provider has no problem", problem, nil)

snapshot, problem = model.read("codex", "not json")
check("garbage body", snapshot, nil)
snapshot, problem = model.read("codex", null)
check("null body", snapshot, nil)

-- With several accounts, the first one that has usage wins
local accounts = model.read("codex", {
    { provider = "codex", error = { message = "expired" } },
    { provider = "codex", usage = { loginMethod = "pro" } },
    { provider = "codex", usage = { loginMethod = "plus" } },
})
check("first account with usage", accounts.plan, "Pro")

if failures > 0 then
    error(string.format("%d check(s) failed", failures))
end
print("model: all checks passed")
