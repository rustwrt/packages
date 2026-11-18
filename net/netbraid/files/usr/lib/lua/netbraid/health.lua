local health = {}

local function requireTime(now)
    assert(type(now) == "number" and now >= 0 and now < math.huge, "time must be a finite nonnegative number")
end

local function withDefault(value, fallback)
    if value == nil then
        return fallback
    end
    return value
end

local function requireInteger(value, minimum, label)
    assert(type(value) == "number" and value < math.huge and value == math.floor(value) and value >= minimum,
        label .. " must be an integer >= " .. minimum)
    return value
end

function health.validate(config)
    assert(type(config) == "table", "config must be a table")
    assert(type(config.targets) == "table" and #config.targets > 0, "targets must be a nonempty array")
    local targets, seen = {}, {}
    for index, target in ipairs(config.targets) do
        assert(type(target) == "string" and target ~= "", "target must be a nonempty string")
        assert(not seen[target], "duplicate target: " .. target)
        seen[target] = true
        targets[index] = target
    end
    for key in pairs(config.targets) do
        assert(type(key) == "number" and key >= 1 and key <= #targets and key == math.floor(key), "targets must be a dense array")
    end
    local minimumTargets = requireInteger(withDefault(config.minimumTargets, #targets), 1, "minimumTargets")
    assert(minimumTargets <= #targets, "minimumTargets exceeds target count")
    local recoveryDelay = withDefault(config.recoveryDelay, 0)
    requireTime(recoveryDelay)
    assert(config.enabled == nil or type(config.enabled) == "boolean", "enabled must be boolean")
    return {
        targets = targets,
        minimumTargets = minimumTargets,
        failureThreshold = requireInteger(withDefault(config.failureThreshold, 3), 1, "failureThreshold"),
        recoveryThreshold = requireInteger(withDefault(config.recoveryThreshold, 2), 1, "recoveryThreshold"),
        recoveryDelay = recoveryDelay,
        enabled = config.enabled ~= false
    }
end

function health.new(config, now)
    requireTime(now)
    local validatedConfig = health.validate(config)
    return {
        config = validatedConfig,
        status = validatedConfig.enabled and "Offline" or "Disabled",
        enabled = validatedConfig.enabled,
        failureCount = 0,
        recoveryCount = 0,
        workingTargets = 0,
        updatedAt = now,
        changedAt = now
    }
end

local function countWorkingTargets(config, probeResults)
    assert(type(probeResults) == "table", "probeResults must be an array")
    local configuredTargets, seen, workingTargets, resultCount = {}, {}, 0, 0
    for _, target in ipairs(config.targets) do
        configuredTargets[target] = true
    end
    for _, result in ipairs(probeResults) do
        assert(type(result) == "table", "probe result must be a table")
        assert(type(result.target) == "string" and configuredTargets[result.target], "probe target is not configured")
        assert(not seen[result.target], "duplicate probe target: " .. result.target)
        assert(type(result.success) == "boolean", "probe success must be boolean")
        seen[result.target] = true
        resultCount = resultCount + 1
        if result.success then
            workingTargets = workingTargets + 1
        end
    end
    for key in pairs(probeResults) do
        assert(type(key) == "number" and key >= 1 and key <= resultCount and key == math.floor(key), "probeResults must be a dense array")
    end
    return workingTargets
end

function health.step(state, probeResults, now, enabled)
    assert(type(state) == "table", "state must be a table")
    requireTime(now)
    assert(now >= state.updatedAt, "time must not move backwards")
    assert(enabled == nil or type(enabled) == "boolean", "enabled must be boolean")
    local nextState = health.new(state.config, now)
    nextState.enabled = withDefault(enabled, state.enabled)
    nextState.changedAt = state.changedAt
    if not nextState.enabled then
        nextState.status = "Disabled"
    else
        assert(now > state.updatedAt or state.status == "Disabled", "probe rounds require increasing time")
        local config = nextState.config
        local workingTargets = countWorkingTargets(config, probeResults)
        local wasAvailable = state.status == "Online" or state.status == "Degraded"
        nextState.workingTargets = workingTargets
        if workingTargets >= config.minimumTargets then
            nextState.failureCount = 0
            if wasAvailable then
                nextState.status = workingTargets == #config.targets and "Online" or "Degraded"
            else
                nextState.recoveryCount = math.min(state.status == "Recovering" and state.recoveryCount + 1 or 1, config.recoveryThreshold)
                nextState.recoveryStartedAt = state.status == "Recovering" and state.recoveryStartedAt or now
                if nextState.recoveryCount >= config.recoveryThreshold and now - nextState.recoveryStartedAt >= config.recoveryDelay then
                    nextState.status = workingTargets == #config.targets and "Online" or "Degraded"
                    nextState.recoveryStartedAt = nil
                else
                    nextState.status = "Recovering"
                end
            end
        else
            nextState.failureCount = math.min(state.failureCount + 1, config.failureThreshold)
            nextState.status = wasAvailable and nextState.failureCount < config.failureThreshold and "Degraded" or "Offline"
        end
    end
    if nextState.status ~= state.status then
        nextState.changedAt = now
    end
    return nextState
end

return health
