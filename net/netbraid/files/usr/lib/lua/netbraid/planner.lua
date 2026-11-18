local planner = {}

local modes = {
    ["src-address"] = { "saddr" },
    ["dst-address"] = { "daddr" },
    ["both-addresses"] = { "saddr", "daddr" },
    ["src-port"] = { "sport" },
    ["dst-port"] = { "dport" },
    ["both-ports"] = { "sport", "dport" },
    ["src-address-and-port"] = { "saddr", "sport" },
    ["dst-address-and-port"] = { "daddr", "dport" },
    ["both-addresses-and-ports"] = { "saddr", "daddr", "sport", "dport" }
}

local function integer(number, minimum, maximum)
    return type(number) == "number" and number == math.floor(number)
        and number >= minimum and number <= maximum
end

local function identifier(name)
    return type(name) == "string" and #name <= 15 and name:match("^[%w_][%w_.%-]*$") ~= nil
end

local function overlaps(left, right)
    for _ = 1, 32 do
        if left % 2 == 1 and right % 2 == 1 then return true end
        left, right = math.floor(left / 2), math.floor(right / 2)
    end
    return false
end

function planner.validateResources(resources, occupied)
    assert(type(resources) == "table", "resources required")
    assert(integer(resources.markShift, 16, 24), "mark shift must be between 16 and 24")
    assert(integer(resources.tableBase, 10000, 50000), "table base outside supported range")
    assert(integer(resources.priorityBase, 20000, 30000), "priority base outside supported range")
    assert(type(occupied) == "table" and occupied.complete == true, "complete resource inventory required")
    local markMask = 255 * 2 ^ resources.markShift
    for _, mask in ipairs(occupied.markMasks or {}) do
        assert(integer(mask, 0, 4294967295), "invalid occupied mark mask")
        assert(not overlaps(markMask, mask), "fwmark mask collision")
    end
    for _, tableId in ipairs(occupied.tableIds or {}) do
        assert(not (tableId >= resources.tableBase and tableId <= resources.tableBase + 254), "routing table collision")
    end
    for _, priority in ipairs(occupied.priorities or {}) do
        assert(not (priority >= resources.priorityBase and priority <= resources.priorityBase + 254), "rule priority collision")
    end
    return markMask
end

function planner.compile(policy, members, resources, occupied)
    assert(type(policy) == "table" and modes[policy.mode], "unsupported PCC mode")
    local markMask = planner.validateResources(resources, occupied)
    local seenNames, seenIds, selected, bestPriority = {}, {}, {}, nil
    assert(type(members) == "table" and #members > 0 and #members <= 255, "one to 255 members required")
    for _, member in ipairs(members) do
        assert(identifier(member.name), "invalid member name")
        assert(not seenNames[member.name], "duplicate member name")
        assert(integer(member.id, 1, 255) and not seenIds[member.id], "invalid or duplicate stable member id")
        assert(integer(member.weight, 1, 256), "weight must be between 1 and 256")
        assert(integer(member.priority, 1, 65535), "invalid member priority")
        assert(type(member.online) == "boolean", "member health must be explicit")
        seenNames[member.name], seenIds[member.id] = true, true
        if member.online then
            if not bestPriority or member.priority < bestPriority then
                selected, bestPriority = {}, member.priority
            end
            if member.priority == bestPriority then selected[#selected + 1] = member end
        end
    end
    table.sort(selected, function(left, right) return left.id < right.id end)
    local plan = { mode = policy.mode, markMask = markMask, totalWeight = 0, buckets = {} }
    for _, member in ipairs(selected) do
        local firstBucket = plan.totalWeight
        plan.totalWeight = plan.totalWeight + member.weight
        plan.buckets[#plan.buckets + 1] = {
            name = member.name, firstBucket = firstBucket, lastBucket = plan.totalWeight - 1,
            mark = member.id * 2 ^ resources.markShift,
            tableId = resources.tableBase + member.id - 1,
            priority = resources.priorityBase + member.id - 1
        }
    end
    return plan
end

function planner.hashExpression(mode, family, hasPorts)
    assert(modes[mode], "unsupported PCC mode")
    assert(family == "ip" or family == "ip6", "invalid address family")
    local fields = {}
    for _, field in ipairs(modes[mode]) do
        if field == "sport" or field == "dport" then
            if hasPorts then fields[#fields + 1] = "th " .. field end
        else
            fields[#fields + 1] = family .. " " .. field
        end
    end
    if #fields == 0 then fields = { family .. " saddr", family .. " daddr" } end
    return table.concat(fields, " . ")
end

function planner.renderClassification(plan, family, hasPorts)
    assert(plan.totalWeight > 0, "no healthy members; no classification generated")
    local expression = planner.hashExpression(plan.mode, family, hasPorts)
    local rules = {}
    local guard = hasPorts and "meta l4proto { tcp, udp } " or "meta l4proto != { tcp, udp } "
    local inverseMask = 4294967295 - plan.markMask
    for _, bucket in ipairs(plan.buckets) do
        rules[#rules + 1] = string.format(
            "meta nfproto %s %sct state new ct mark & 0x%08x == 0 meta mark == 0 jhash %s mod %d seed 0x52425244 %d-%d ct mark set (ct mark & 0x%08x) | 0x%08x",
            family == "ip" and "ipv4" or "ipv6", guard, plan.markMask, expression,
            plan.totalWeight, bucket.firstBucket, bucket.lastBucket, inverseMask, bucket.mark)
    end
    return rules
end

return planner
