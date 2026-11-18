-- NetBraid shared validation and formatting helpers.
-- Pure Lua 5.1: no OpenWrt-only dependencies, safe to unit test on any host.

local util = {}

function util.isFiniteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

function util.isInteger(value, minimum, maximum)
    if not util.isFiniteNumber(value) or value ~= math.floor(value) then
        return false
    end
    if minimum ~= nil and value < minimum then
        return false
    end
    if maximum ~= nil and value > maximum then
        return false
    end
    return true
end

function util.requireTable(value, label)
    assert(type(value) == "table", label .. " must be a table")
    return value
end

function util.requireString(value, label)
    assert(type(value) == "string" and value ~= "", label .. " must be a nonempty string")
    return value
end

function util.requireInteger(value, minimum, maximum, label)
    assert(util.isInteger(value, minimum, maximum),
        string.format("%s must be an integer between %s and %s", label, tostring(minimum), tostring(maximum)))
    return value
end

function util.requireBoolean(value, label)
    assert(type(value) == "boolean", label .. " must be a boolean")
    return value
end

function util.requireArray(value, label)
    util.requireTable(value, label)
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

-- Identifier safe for nft/uci/ip objects: leading letter or underscore.
function util.identifier(value, maxLength)
    maxLength = maxLength or 32
    return type(value) == "string" and #value >= 1 and #value <= maxLength
        and value:match("^[%a_][%w_.%-]*$") ~= nil
end

-- Convert an application camelCase key to the snake_case wire form.
function util.toSnakeCase(name)
    if type(name) ~= "string" then
        return name
    end
    name = name:gsub("(%u)(%u%l)", "%1_%2")
    name = name:gsub("(%l)(%u)", "%1_%2")
    return name:lower()
end

-- Recursively normalise application-owned table keys to snake_case for a wire boundary.
-- Values are copied; opaque payload strings are never rewritten.
function util.snakeCaseKeys(input)
    if type(input) ~= "table" then
        return input
    end
    local output = {}
    for key, value in pairs(input) do
        local wireKey = type(key) == "string" and util.toSnakeCase(key) or key
        output[wireKey] = util.snakeCaseKeys(value)
    end
    return output
end

-- Recursively copy so callers cannot mutate shared configuration.
function util.deepCopy(input)
    if type(input) ~= "table" then
        return input
    end
    local output = {}
    for key, value in pairs(input) do
        output[key] = util.deepCopy(value)
    end
    return output
end

function util.deepEqual(left, right)
    if type(left) ~= type(right) then
        return false
    end
    if type(left) ~= "table" then
        return left == right
    end
    for key, value in pairs(left) do
        if not util.deepEqual(value, right[key]) then
            return false
        end
    end
    for key in pairs(right) do
        if left[key] == nil then
            return false
        end
    end
    return true
end

return util
