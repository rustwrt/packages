-- NetBraid resource allocator.
-- Assigns stable member IDs and verifies the fwmark region, routing table IDs and
-- rule priorities do not intersect any occupied resource (including WARP allocations).
-- The occupied inventory must be explicit and complete; an incomplete inventory is rejected.

local util = require("netbraid.util")

local allocator = {}

local function masksOverlap(left, right)
    for _ = 1, 32 do
        if left % 2 == 1 and right % 2 == 1 then
            return true
        end
        left, right = math.floor(left / 2), math.floor(right / 2)
    end
    return false
end

allocator.masksOverlap = masksOverlap

function allocator.assignIds(members)
    util.requireArray(members, "members")
    local ordered = {}
    for _, member in ipairs(members) do
        ordered[#ordered + 1] = util.deepCopy(member)
    end
    table.sort(ordered, function(left, right) return left.name < right.name end)
    assert(#ordered <= 254, "at most 254 members are supported")
    for index, member in ipairs(ordered) do
        member.id = index
    end
    return ordered
end

function allocator.markMask(main)
    return 255 * 2 ^ main.markShift
end

function allocator.build(main, members, occupied)
    util.requireTable(occupied, "occupied inventory")
    assert(occupied.complete == true, "complete resource inventory required")
    local markMask = allocator.markMask(main)
    local occupiedMarks = occupied.markMasks or {}
    local occupiedTables = occupied.tableIds or {}
    local occupiedPriorities = occupied.priorities or {}

    for _, mask in ipairs(occupiedMarks) do
        util.requireInteger(mask, 0, 4294967295, "occupied mark mask")
        assert(not masksOverlap(markMask, mask), "fwmark mask collision with occupied resource")
    end

    local tableIds, priorities = {}, {}
    for _, value in ipairs(occupiedTables) do
        assert(util.isInteger(value), "invalid occupied table id")
        tableIds[value] = true
    end
    for _, value in ipairs(occupiedPriorities) do
        assert(util.isInteger(value), "invalid occupied priority")
        priorities[value] = true
    end

    local assignments = {}
    for _, member in ipairs(allocator.assignIds(members)) do
        local tableId = main.tableBase + member.id - 1
        local priority = main.priorityBase + member.id - 1
        assert(not tableIds[tableId], "routing table collision for member " .. member.name)
        assert(not priorities[priority], "rule priority collision for member " .. member.name)
        assert(not masksOverlap(markMask, member.id * 2 ^ main.markShift),
            "member mark collides with occupied mask for " .. member.name)
        assignments[#assignments + 1] = {
            name = member.name,
            id = member.id,
            mark = member.id * 2 ^ main.markShift,
            tableId = tableId,
            priority = priority,
            weight = member.weight,
            memberPriority = member.priority
        }
    end
    return { markMask = markMask, markShift = main.markShift, assignments = assignments }
end

return allocator
