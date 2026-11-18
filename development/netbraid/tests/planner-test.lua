local planner = require("routebraid.planner")
local resources = { markShift = 16, tableBase = 10000, priorityBase = 20000 }
local occupied = { complete = true, markMasks = { 65535 }, tableIds = { 51820 }, priorities = { 1, 15001 } }
local members = {
    { name = "wan", id = 1, weight = 3, priority = 1, online = true },
    { name = "lan", id = 2, weight = 2, priority = 1, online = true },
    { name = "wwan", id = 3, weight = 1, priority = 1, online = true },
    { name = "backup", id = 4, weight = 1, priority = 2, online = true }
}
local function rejected(callback)
    assert(not pcall(callback), "unsafe input accepted")
end
local plan = planner.compile({ mode = "both-addresses-and-ports" }, members, resources, occupied)
assert(plan.totalWeight == 6 and #plan.buckets == 3)
assert(plan.buckets[1].firstBucket == 0 and plan.buckets[1].lastBucket == 2)
assert(plan.buckets[2].firstBucket == 3 and plan.buckets[2].lastBucket == 4)
assert(plan.buckets[3].firstBucket == 5 and plan.buckets[3].lastBucket == 5)
assert(plan.buckets[3].tableId == 10002)
local rules = planner.renderClassification(plan, "ip6", true)
assert(#rules == 3 and rules[1]:find("ip6 saddr . ip6 daddr . th sport . th dport", 1, true))
assert(rules[1]:find("meta mark == 0", 1, true))
assert(rules[1]:find("ct mark & 0xff00ffff", 1, true))
for _, mode in ipairs({ "src-address", "dst-address", "both-addresses", "src-port", "dst-port", "both-ports", "src-address-and-port", "dst-address-and-port", "both-addresses-and-ports" }) do
    for _, family in ipairs({ "ip", "ip6" }) do
        assert(#planner.hashExpression(mode, family, true) > 0)
        assert(not planner.hashExpression(mode, family, false):find("th ", 1, true))
    end
end
members[1].online = false
local reduced = planner.compile({ mode = "src-address" }, members, resources, occupied)
assert(reduced.totalWeight == 3 and reduced.buckets[1].mark == plan.buckets[2].mark)
members[2].online, members[3].online = false, false
assert(planner.compile({ mode = "src-address" }, members, resources, occupied).buckets[1].name == "backup")
members[4].online = false
local offline = planner.compile({ mode = "src-address" }, members, resources, occupied)
assert(offline.totalWeight == 0)
rejected(function() planner.renderClassification(offline, "ip", true) end)
rejected(function() planner.validateResources(resources, { complete = false }) end)
rejected(function() planner.validateResources(resources, { complete = true, markMasks = { 4294967295 } }) end)
rejected(function() planner.validateResources(resources, { complete = true, tableIds = { 10005 } }) end)
rejected(function() planner.validateResources(resources, { complete = true, priorities = { 20005 } }) end)
members[1].name = "wan; reboot"
rejected(function() planner.compile({ mode = "src-address" }, members, resources, occupied) end)
print("PASS planner-test")
