-- EventSource module for ProtoplugScripts
-- Base class for objects that can fire events to listeners
local EventSource = {}

-- Dependencies
local util = require("util")
local Logger = require("Logger")
local LOG = Logger.default

-- EventSource class
function EventSource:new()
	local o = { eventListeners = {} }
	setmetatable(o, self)
	self.__index = self
	return o
end

function EventSource:addEventListener(inEventListener)
	local listeners = self.eventListeners
	listeners[#listeners+1] = inEventListener
	LOG.debug("EventSource:addEventListener: self.eventListeners: ",listeners)
	return inEventListener
end

function EventSource:removeEventListener(inEventListener)
	local listeners = self.eventListeners
	local size = #listeners
	util.array_remove(listeners, function(t,i) return t[i]~= inEventListener end)
	LOG.debug("EventSource:removeEventListener: ", listeners)
	return size ~= #listeners
end

function EventSource:fireEvent(inEvent)
	--print("EventSource: fireEvent: "..string.format("%s", self.eventListeners))
	local listeners = self.eventListeners
	local n=#listeners
	for i=1,n do
		listeners[i](inEvent)
	end
end

return EventSource