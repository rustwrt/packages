local discovery = {}

local function requireTable(value, label)
    assert(type(value) == "table", label .. " must be a table")
    return value
end

local function requireArray(value, label)
    requireTable(value, label)
    local count = 0
    for _ in ipairs(value) do
        count = count + 1
    end
    for key in pairs(value) do
        assert(type(key) == "number" and key == math.floor(key) and key >= 1 and key <= count,
            label .. " must be a dense array")
    end
    return value
end

local function requireString(value, label)
    assert(type(value) == "string" and value ~= "", label .. " must be a nonempty string")
    return value
end

local function readMask(value, maximum, label)
    local mask = tonumber(value)
    assert(mask and mask == math.floor(mask) and mask >= 0 and mask <= maximum, label .. " is invalid")
    return mask
end

local function normalizeAddresses(rawInterface)
    local addresses = {}
    for _, group in ipairs({ { "ipv4-address", 4, 32 }, { "ipv6-address", 6, 128 } }) do
        for _, rawAddress in ipairs(requireArray(rawInterface[group[1]] or {}, group[1])) do
            requireTable(rawAddress, "address")
            addresses[#addresses + 1] = {
                address = requireString(rawAddress.address, "address.address"),
                mask = readMask(rawAddress.mask, group[3], "address.mask"),
                family = group[2]
            }
        end
    end
    for _, assignment in ipairs(requireArray(rawInterface["ipv6-prefix-assignment"] or {}, "ipv6-prefix-assignment")) do
        requireTable(assignment, "prefix assignment")
        local localAddress = assignment["local-address"]
        if localAddress then
            requireTable(localAddress, "local-address")
            addresses[#addresses + 1] = {
                address = requireString(localAddress.address, "local-address.address"),
                mask = readMask(localAddress.mask, 128, "local-address.mask"),
                family = 6
            }
        end
    end
    return addresses
end

local function normalizeRoutes(rawInterface)
    local routes = {}
    for _, rawRoute in ipairs(requireArray(rawInterface.route or {}, "route")) do
        requireTable(rawRoute, "route entry")
        local target = requireString(rawRoute.target, "route.target")
        local family = target:find(":", 1, true) and 6 or 4
        local mask = readMask(rawRoute.mask, family == 6 and 128 or 32, "route.mask")
        local metric = tonumber(rawRoute.metric or 0)
        assert(metric and metric >= 0 and metric < math.huge and metric == math.floor(metric), "route.metric is invalid")
        if rawRoute.nexthop ~= nil then
            requireString(rawRoute.nexthop, "route.nexthop")
        end
        if rawRoute.source ~= nil then
            requireString(rawRoute.source, "route.source")
        end
        assert(rawRoute.table == nil or type(rawRoute.table) == "string" or type(rawRoute.table) == "number",
            "route.table must be a string or number")
        routes[#routes + 1] = {
            target = target,
            family = family,
            mask = mask,
            gateway = rawRoute.nexthop,
            metric = metric,
            table = rawRoute.table,
            source = rawRoute.source,
            defaultRoute = mask == 0 and (target == "0.0.0.0" or target == "::" or target == "0:0:0:0:0:0:0:0")
        }
    end
    return routes
end

local function normalizeDependencies(rawInterface)
    local dependencies, seen = {}, {}
    local function addDependency(name)
        requireString(name, "dependency")
        name = name:gsub("^@", "")
        requireString(name, "dependency")
        if not seen[name] then
            dependencies[#dependencies + 1] = name
            seen[name] = true
        end
    end
    for _, name in ipairs(requireArray(rawInterface.dependencies or {}, "dependencies")) do
        addDependency(name)
    end
    for _, key in ipairs({ "device", "l3_device" }) do
        local device = rawInterface[key]
        if type(device) == "string" and device:sub(1, 1) == "@" then
            addDependency(device)
        end
    end
    table.sort(dependencies)
    return dependencies
end

local function detectCycles(interfaces, byName)
    local cycles, visited, active, stack = {}, {}, {}, {}
    local function visit(name)
        if active[name] then
            local cycle = {}
            for index = active[name], #stack do
                cycle[#cycle + 1] = stack[index]
            end
            cycle[#cycle + 1] = name
            cycles[#cycles + 1] = cycle
            return
        end
        if visited[name] or not byName[name] then
            return
        end
        active[name] = #stack + 1
        stack[#stack + 1] = name
        for _, dependency in ipairs(byName[name].dependencies) do
            visit(dependency)
        end
        stack[#stack] = nil
        active[name] = nil
        visited[name] = true
    end
    for _, interface in ipairs(interfaces) do
        visit(interface.name)
    end
    return cycles
end

function discovery.normalize(ubusDump)
    requireTable(ubusDump, "ubusDump")
    local rawInterfaces = requireArray(ubusDump.interface, "ubusDump.interface")
    local interfaces, candidates, byName = {}, {}, {}
    for _, rawInterface in ipairs(rawInterfaces) do
        requireTable(rawInterface, "interface entry")
        local name = requireString(rawInterface.interface, "interface.interface")
        assert(not byName[name], "duplicate interface: " .. name)
        assert(rawInterface.up == nil or type(rawInterface.up) == "boolean", "interface.up must be boolean")
        local device = rawInterface.l3_device or rawInterface.device
        if device ~= nil then
            requireString(device, "interface.device")
        end
        local interface = {
            name = name,
            device = device,
            up = rawInterface.up == true,
            addresses = normalizeAddresses(rawInterface),
            routes = normalizeRoutes(rawInterface),
            dependencies = normalizeDependencies(rawInterface),
            defaultRouteCandidate = false
        }
        for _, route in ipairs(interface.routes) do
            if interface.up and route.defaultRoute then
                interface.defaultRouteCandidate = true
            end
        end
        interfaces[#interfaces + 1] = interface
        byName[name] = interface
    end
    table.sort(interfaces, function(left, right) return left.name < right.name end)
    for _, interface in ipairs(interfaces) do
        if interface.defaultRouteCandidate then
            candidates[#candidates + 1] = interface
        end
    end
    return { interfaces = interfaces, candidates = candidates, cycles = detectCycles(interfaces, byName) }
end

return discovery
