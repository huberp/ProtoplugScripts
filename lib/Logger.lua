-- Logger module for ProtoplugScripts
local Logger = {}

-- Local constants
local nl = string.char(10) -- newline

-- Log levels
local LOG_LEVELS = {
    TRACE = 4,
    DEBUG = 3,
    FINE = 2,
    INFO = 1
}

-- Serialize table to string representation
local function serialize_list(tabl, indent)
    indent = indent and (indent.."  ") or ""
    local parts = {}
    
    parts[#parts + 1] = indent
    parts[#parts + 1] = "{"
    parts[#parts + 1] = nl
    
    for key, value in pairs(tabl) do
        parts[#parts + 1] = indent
        
        if type(key) == "string" then
            parts[#parts + 1] = '["'
            parts[#parts + 1] = key
            parts[#parts + 1] = '"]='
        end
        
        if type(value) == "table" then
            parts[#parts + 1] = serialize_list(value, indent)
        elseif type(value) == "string" then
            parts[#parts + 1] = '"'
            parts[#parts + 1] = tostring(value)
            parts[#parts + 1] = '",'
            parts[#parts + 1] = nl
        else
            parts[#parts + 1] = tostring(value)
            parts[#parts + 1] = ','
            parts[#parts + 1] = nl
        end
    end
    
    parts[#parts + 1] = indent
    parts[#parts + 1] = "},"
    parts[#parts + 1] = nl
    
    return table.concat(parts)
end

-- Logger class
local LoggerClass = {}
LoggerClass.__index = LoggerClass

function LoggerClass:new(level)
    local instance = {
        SET_LEVEL = level or LOG_LEVELS.FINE
    }
    setmetatable(instance, self)
    instance:setupLoggers()
    return instance
end

function LoggerClass:log(level, ...)
    if level > self.SET_LEVEL then
        return
    end
    
    local parts = {"[LOGGER]"}
    
    for i = 1, select('#', ...) do
        local value = select(i, ...)
        if type(value) == "table" then
            parts[#parts + 1] = serialize_list(value)
        elseif type(value) == "string" then
            parts[#parts + 1] = value
        else
            parts[#parts + 1] = tostring(value)
        end
    end
    
    print(table.concat(parts))
end

function LoggerClass:forLevel(level)
    if level <= self.SET_LEVEL then
        return function(...)
            self:log(level, ...)
        end
    else
        return function() end
    end
end

function LoggerClass:setupLoggers()
    self.trace = self:forLevel(LOG_LEVELS.TRACE)
    self.debug = self:forLevel(LOG_LEVELS.DEBUG)
    self.fine = self:forLevel(LOG_LEVELS.FINE)
    self.info = self:forLevel(LOG_LEVELS.INFO)
end

function LoggerClass:setLevel(level)
    self.SET_LEVEL = level
    self:setupLoggers()
end

-- Module interface
Logger.LEVELS = LOG_LEVELS

-- Handle both Logger:new() and Logger.new() syntax
function Logger:new(level)
    -- If called with colon syntax, first param is the Logger table, second is the level
    if type(self) == "table" and self.LEVELS then
        level = level or LOG_LEVELS.FINE
    else
        -- If called with dot syntax, first param is the level
        level = self or LOG_LEVELS.FINE
    end
    return LoggerClass:new(level)
end

-- Also provide dot syntax
Logger.create = function(level)
    return LoggerClass:new(level)
end

-- Create default logger instance
Logger.default = LoggerClass:new(LOG_LEVELS.FINE)

return Logger