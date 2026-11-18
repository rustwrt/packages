local health = require("routebraid.health")

local config = {
    targets = { "first", "second", "third" },
    minimumTargets = 2,
    failureThreshold = 2,
    recoveryThreshold = 2,
    recoveryDelay = 5
}
local good = {
    { target = "first", success = true },
    { target = "second", success = true },
    { target = "third", success = true }
}
local partial = { { target = "first", success = true }, { target = "second", success = true } }
local bad = { { target = "first", success = false } }
local initial = health.new(config, 0)
assert(initial.status == "Offline")
config.targets[1] = "changed"
assert(initial.config.targets[1] == "first")
local state = health.step(initial, good, 1)
assert(state.status == "Recovering" and state.recoveryCount == 1)
assert(initial.status == "Offline" and initial.recoveryCount == 0)
state = health.step(state, good, 2)
assert(state.status == "Recovering" and state.recoveryCount == 2)
state = health.step(state, good, 6)
assert(state.status == "Online" and state.changedAt == 6)
state = health.step(state, partial, 7)
assert(state.status == "Degraded" and state.workingTargets == 2 and state.failureCount == 0)
state = health.step(state, bad, 8)
assert(state.status == "Degraded" and state.failureCount == 1 and state.changedAt == 7)
state = health.step(state, {}, 9)
assert(state.status == "Offline" and state.failureCount == 2)
state = health.step(state, good, 10)
assert(state.status == "Recovering")
state = health.step(state, bad, 11)
assert(state.status == "Offline" and state.recoveryCount == 0 and state.recoveryStartedAt == nil)
state = health.step(state, good, 12)
state = health.step(state, partial, 17)
assert(state.status == "Degraded" and state.failureCount == 0)
state = health.step(state, good, 18)
assert(state.status == "Online")
state = health.step(state, nil, 19, false)
assert(state.status == "Disabled" and state.recoveryCount == 0 and not state.enabled)
state = health.step(state, nil, 20)
assert(state.status == "Disabled")
state = health.step(state, good, 21, true)
assert(state.status == "Recovering" and state.recoveryCount == 1)
state = health.step(state, good, 26)
assert(state.status == "Online")

local disabled = health.new({ targets = { "first" }, enabled = false, recoveryThreshold = 1 }, 0)
assert(disabled.status == "Disabled")
assert(health.step(disabled, { { target = "first", success = true } }, 0, true).status == "Online")
local delayed = health.new({ targets = { "first" }, recoveryThreshold = 3 }, 0)
for now = 1, 2 do
    delayed = health.step(delayed, { { target = "first", success = true } }, now)
    assert(delayed.status == "Recovering")
end
delayed = health.step(delayed, { { target = "first", success = true } }, 3)
assert(delayed.status == "Online")

local function fails(callback, message)
    local success, failure = pcall(callback)
    assert(not success and tostring(failure):find(message, 1, true), tostring(failure))
end
for _, invalidConfig in ipairs({
    { targets = {} },
    { targets = { "a", "a" } },
    { targets = { "a" }, minimumTargets = 2 },
    { targets = { "a" }, minimumTargets = 0 },
    { targets = { "a" }, failureThreshold = 0 },
    { targets = { "a" }, recoveryThreshold = 1.5 },
    { targets = { "a" }, recoveryDelay = -1 },
    { targets = { "a" }, recoveryDelay = math.huge },
    { targets = { "a" }, enabled = 1 },
    { targets = { "a", other = "b" } }
}) do
    fails(function() health.new(invalidConfig, 0) end, "")
end
fails(function() health.step(state, good, 25) end, "backwards")
fails(function() health.step(state, good, 26) end, "increasing time")
fails(function() health.step(state, { { target = "other", success = true } }, 27) end, "not configured")
fails(function() health.step(state, { { target = "first", success = 1 } }, 27) end, "boolean")
fails(function() health.step(state, { good[1], good[1] }, 27) end, "duplicate")
fails(function() health.step(state, { extra = good[1] }, 27) end, "dense array")
fails(function() health.new({ targets = { "a" } }, 0 / 0) end, "finite")
assert(state.status == "Online" and state.updatedAt == 26)

return true
