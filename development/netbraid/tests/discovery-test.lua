local discovery = require("routebraid.discovery")

local dump = { interface = {
    {
        interface = "office",
        up = true,
        device = "br-office",
        l3_device = "br-office.20",
        ["ipv4-address"] = { { address = "192.0.2.2", mask = 24 } },
        ["ipv6-address"] = { { address = "2001:db8::2", mask = 64 } },
        ["ipv6-prefix-assignment"] = {
            { ["local-address"] = { address = "2001:db8:1::1", mask = 64 } }
        },
        route = {
            { target = "0.0.0.0", mask = 0, nexthop = "192.0.2.1", metric = 7 },
            { target = "::", mask = 0, nexthop = "fe80::1", table = 254 },
            { target = "192.0.2.0", mask = 24 }
        }
    },
    { interface = "wan", up = true, route = { { target = "10.0.0.0", mask = 8 } } },
    { interface = "cellular", up = false, route = { { target = "0.0.0.0", mask = "0" } } },
    { interface = "warp", up = true, device = "@office", dependencies = { "office", "unknown" },
        route = { { target = "::", mask = 0 } } }
} }
local normalized = discovery.normalize(dump)
assert(#normalized.interfaces == 4)
assert(#normalized.candidates == 2)
assert(normalized.candidates[1].name == "office")
assert(normalized.candidates[2].name == "warp")
assert(#normalized.cycles == 0)
local office = normalized.candidates[1]
assert(office.device == "br-office.20" and office.up)
assert(#office.addresses == 3)
assert(office.addresses[1].family == 4 and office.addresses[1].mask == 24)
assert(office.addresses[3].family == 6)
assert(office.routes[1].gateway == "192.0.2.1" and office.routes[1].metric == 7)
assert(office.routes[2].family == 6 and office.routes[2].table == 254)
assert(not office.routes[3].defaultRoute)
assert(normalized.candidates[2].dependencies[1] == "office")
assert(#normalized.candidates[2].dependencies == 2)
office.addresses[1].address = "modified"
assert(dump.interface[1]["ipv4-address"][1].address == "192.0.2.2")

local cyclic = discovery.normalize({ interface = {
    { interface = "a", device = "@b" },
    { interface = "b", dependencies = { "c" } },
    { interface = "c", dependencies = { "a" } },
    { interface = "self", dependencies = { "self" } }
} })
assert(#cyclic.cycles == 2)
assert(table.concat(cyclic.cycles[1], ",") == "a,b,c,a")
assert(table.concat(cyclic.cycles[2], ",") == "self,self")
assert(#discovery.normalize({ interface = {} }).interfaces == 0)

local function fails(input, message)
    local success, failure = pcall(discovery.normalize, input)
    assert(not success and tostring(failure):find(message, 1, true), tostring(failure))
end
fails({}, "ubusDump.interface")
fails({ interface = { { interface = "a" }, { interface = "a" } } }, "duplicate interface")
fails({ interface = { { interface = "a", up = "yes" } } }, "interface.up")
fails({ interface = { { interface = "a", route = { { target = "::", mask = 129 } } } } }, "route.mask")
fails({ interface = { { interface = "a", dependencies = { "@" } } } }, "dependency")

return true
