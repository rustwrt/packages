-- NetBraid configuration model.
-- Parses a UCI-shaped document (array of sections with .type/.name) into a validated,
-- immutable internal camelCase model. JSON/wire conversion happens only at the API boundary.

local util = require("netbraid.util")

local config = {}

config.modes = {
    "src-address", "dst-address", "both-addresses",
    "src-port", "dst-port", "both-ports",
    "src-address-and-port", "dst-address-and-port", "both-addresses-and-ports"
}

local modeSet = {}
for _, name in ipairs(config.modes) do
    modeSet[name] = true
end

local function toBoolean(value, fallback)
    if value == nil then
        return fallback
    end
    if type(value) == "boolean" then
        return value
    end
    if value == "1" or value == 1 or value == "true" or value == "on" or value == "yes" then
        return true
    end
    if value == "0" or value == 0 or value == "false" or value == "off" or value == "no" then
        return false
    end
    return nil
end

local function toInteger(value, fallback)
    if value == nil then
        return fallback
    end
    local number = tonumber(value)
    return number
end

local function toList(value)
    if value == nil then
        return {}
    end
    if type(value) == "table" then
        return util.requireArray(value, "list value")
    end
    return { value }
end

local function sectionValue(section, key)
    return section[key]
end

function config.parse(document)
    util.requireArray(document, "config document")
    local document_ = document
    local result = {
        main = {
            enabled = false,
            markShift = 16,
            tableBase = 10000,
            priorityBase = 20000,
            healthEnabled = true,
            detectorEnabled = false,
            portalEnabled = false,
            routerOriginated = false,
            logLevel = "notice"
        },
        health = {},
        members = {},
        policies = {},
        detector = { enabled = false },
        portal = { enabled = false }
    }
    local seenNames = {}
    for index, section in ipairs(document_) do
        util.requireTable(section, "config section " .. index)
        local sectionType = util.requireString(section[".type"], "config section .type")
        local sectionName = util.requireString(section[".name"], "config section .name")
        if sectionType == "netbraid" or sectionType == "main" then
            assert(sectionName == "main", "netbraid section must be named main")
            local main = result.main
            main.enabled = toBoolean(sectionValue(section, "enabled"), false)
            main.markShift = toInteger(sectionValue(section, "mark_shift"), 16)
            main.tableBase = toInteger(sectionValue(section, "table_base"), 10000)
            main.priorityBase = toInteger(sectionValue(section, "priority_base"), 20000)
            main.healthEnabled = toBoolean(sectionValue(section, "health_enabled"), true)
            main.detectorEnabled = toBoolean(sectionValue(section, "detector_enabled"), false)
            main.portalEnabled = toBoolean(sectionValue(section, "portal_enabled"), false)
            main.routerOriginated = toBoolean(sectionValue(section, "router_originated"), false)
            main.logLevel = tostring(sectionValue(section, "log_level") or "notice")
        elseif sectionType == "health" then
            assert(not result.health[sectionName], "duplicate health section: " .. sectionName)
            result.health[sectionName] = {
                name = sectionName,
                targets = toList(sectionValue(section, "target")),
                minimumTargets = toInteger(sectionValue(section, "minimum_targets"), nil),
                interval = toInteger(sectionValue(section, "interval"), 5),
                timeout = toInteger(sectionValue(section, "timeout"), 2),
                failureThreshold = toInteger(sectionValue(section, "failure_threshold"), 3),
                recoveryThreshold = toInteger(sectionValue(section, "recovery_threshold"), 2),
                recoveryDelay = toInteger(sectionValue(section, "recovery_delay"), 0),
                protocols = toList(sectionValue(section, "protocol")),
                enabled = toBoolean(sectionValue(section, "enabled"), true)
            }
        elseif sectionType == "member" then
            assert(not seenNames["member:" .. sectionName], "duplicate member: " .. sectionName)
            seenNames["member:" .. sectionName] = true
            result.members[#result.members + 1] = {
                name = sectionName,
                interface = sectionValue(section, "interface"),
                device = sectionValue(section, "device"),
                weight = toInteger(sectionValue(section, "weight"), 1),
                priority = toInteger(sectionValue(section, "priority"), 1),
                health = sectionValue(section, "health"),
                family = sectionValue(section, "family") or "auto",
                enabled = toBoolean(sectionValue(section, "enabled"), true)
            }
        elseif sectionType == "policy" then
            assert(not seenNames["policy:" .. sectionName], "duplicate policy: " .. sectionName)
            seenNames["policy:" .. sectionName] = true
            result.policies[#result.policies + 1] = {
                name = sectionName,
                mode = sectionValue(section, "mode"),
                members = toList(sectionValue(section, "member")),
                family = sectionValue(section, "family") or "auto",
                routerOriginated = toBoolean(sectionValue(section, "router_originated"), false),
                enabled = toBoolean(sectionValue(section, "enabled"), true)
            }
        elseif sectionType == "detector" then
            result.detector = {
                enabled = toBoolean(sectionValue(section, "enabled"), false),
                interval = toInteger(sectionValue(section, "interval"), 30),
                ttlEnabled = toBoolean(sectionValue(section, "ttl"), true),
                dhcpEnabled = toBoolean(sectionValue(section, "dhcp"), true),
                conntrackEnabled = toBoolean(sectionValue(section, "conntrack"), true),
                neighborEnabled = toBoolean(sectionValue(section, "neighbor"), true),
                synEnabled = toBoolean(sectionValue(section, "syn"), false),
                wifiEnabled = toBoolean(sectionValue(section, "wifi"), true)
            }
        elseif sectionType == "portal" then
            result.portal = {
                enabled = toBoolean(sectionValue(section, "enabled"), false),
                interface = sectionValue(section, "interface"),
                sessionTimeout = toInteger(sectionValue(section, "session_timeout"), 3600),
                guestNetwork = sectionValue(section, "guest_network") or "guest",
                title = sectionValue(section, "title"),
                terms = sectionValue(section, "terms")
            }
        else
            assert(false, "unknown section type: " .. sectionType)
        end
    end
    return config.validate(result)
end

-- Read a live UCI configuration. `cursor` must expose get_all(name) -> array or
-- get(name, section, option) semantics; a plain document table is also accepted.
function config.load(source)
    if type(source) == "table" and source[1] ~= nil then
        return config.parse(source)
    end
    assert(source and source.get, "load requires a UCI cursor or parsed document")
    local document = {}
    for _, sectionName in ipairs(source:get_all("netbraid") or {}) do
        local descriptor = source:get_all("netbraid", sectionName) or {}
        local entry = { [".name"] = sectionName, [".type"] = descriptor[".type"] or "netbraid" }
        for key, value in pairs(descriptor) do
            entry[key] = value
        end
        document[#document + 1] = entry
    end
    return config.parse(document)
end

function config.validate(model)
    util.requireTable(model, "config model")
    local main = util.requireTable(model.main, "config.main")
    util.requireBoolean(main.enabled, "main.enabled")
    util.requireInteger(main.markShift, 16, 24, "main.markShift")
    util.requireInteger(main.tableBase, 10000, 50000, "main.tableBase")
    util.requireInteger(main.priorityBase, 20000, 30000, "main.priorityBase")
    util.requireBoolean(main.healthEnabled, "main.healthEnabled")
    util.requireBoolean(main.detectorEnabled, "main.detectorEnabled")
    util.requireBoolean(main.portalEnabled, "main.portalEnabled")

    for name, health in pairs(model.health or {}) do
        util.requireString(name, "health.name")
        util.requireArray(health.targets, "health.targets")
        util.requireInteger(health.interval, 1, 3600, "health.interval")
        util.requireInteger(health.timeout, 1, 60, "health.timeout")
        util.requireInteger(health.failureThreshold, 1, 100, "health.failureThreshold")
        util.requireInteger(health.recoveryThreshold, 1, 100, "health.recoveryThreshold")
        util.requireInteger(health.recoveryDelay, 0, 86400, "health.recoveryDelay")
        local minimum = health.minimumTargets
        if minimum ~= nil then
            util.requireInteger(minimum, 1, #health.targets, "health.minimumTargets")
        end
    end

    local seenMembers = {}
    for _, member in ipairs(util.requireArray(model.members, "config.members")) do
        util.requireTable(member, "member")
        assert(util.identifier(member.name, 32), "invalid member name")
        assert(not seenMembers[member.name], "duplicate member: " .. member.name)
        seenMembers[member.name] = true
        util.requireString(member.interface, "member.interface")
        util.requireInteger(member.weight, 1, 256, "member.weight")
        util.requireInteger(member.priority, 1, 65535, "member.priority")
        if member.health ~= nil then
            assert(model.health[member.health], "member references unknown health section: " .. tostring(member.health))
        end
    end

    for _, policy in ipairs(util.requireArray(model.policies, "config.policies")) do
        util.requireTable(policy, "policy")
        assert(util.identifier(policy.name, 32), "invalid policy name")
        assert(modeSet[policy.mode], "unsupported policy mode: " .. tostring(policy.mode))
        util.requireArray(policy.members, "policy.members")
        for _, memberName in ipairs(policy.members) do
            assert(seenMembers[memberName], "policy references unknown member: " .. tostring(memberName))
        end
    end
    return model
end

function config.enabledMembers(model)
    local members = {}
    for _, member in ipairs(model.members) do
        if member.enabled ~= false then
            members[#members + 1] = util.deepCopy(member)
        end
    end
    return members
end

return config
