package.path = "routebraid/files/usr/lib/lua/?.lua;" .. package.path
for _, path in ipairs({ "tests/planner-test.lua", "tests/discovery-test.lua", "tests/health-test.lua" }) do
    local success, message = pcall(dofile, path)
    if not success then
        io.stderr:write("FAIL ", path, ": ", tostring(message), "\n")
        os.exit(1)
    end
end
print("PASS all Lua unit suites")
