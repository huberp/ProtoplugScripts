require "include/protoplug"
--
local ceil = math.ceil
local floor = math.floor

--Welcome to Lua Protoplug effect (version 1.4.0)
--package.path=package.path .. ";C:/Program Files/Common Files/VST3/Protoplug/ProtoplugFiles/lib/socket/?.dll"
print("###")
-- https://www.gammon.com.au/scripts/doc.php?lua=package.loadlib
package.cpath = package.cpath .. ";"..protoplug_dir.."/lib/?.dll"
print(package.cpath)
print("---")
print(package.path)
print("---")
print(protoplug_dir)
print("---")


local socket = require("socket")

local bound = socket.bind("0.0.0.0",8000)
bound:settimeout(0)
print(bound)
print(bound:getfd())
--
-- https://stackoverflow.com/questions/12394841/safely-remove-items-from-an-array-table-while-iterating
local function array_remove(t, fnKeep)
    local j, n = 1, #t;

    for i=1,n do
        if (fnKeep(t, i)) then
            -- Move i's kept value to j's position, if it's not already there.
            if (i ~= j) then
                t[j] = t[i];
                t[i] = nil;
            end
            j = j + 1; -- Increment position of where we'll place the next kept value.
        else
            t[i] = nil;
        end
    end
    return t;
end
--
--
--  Log Stuff
--
--
local LOG_L = {
	DEBUG=3,
	FINE=2,
	INFO=1
}
local LOG = {
	SET_LEVEL=LOG_L.INFO
}
function LOG:log(level,...)
	if level > self.SET_LEVEL then
		return
	end
	local res = "[LOGGER]"
	for i = 1, select('#', ...) do
		local value = select(i, ...)
		local str
		if type (value) == "table" then
            str = serialize_list (value, indent)
        elseif type (value) == "string" then
            str = tostring(value)
        else
            str = tostring(value)
        end
		res = res .. str
	end
	print(res)
end

--
--
--
local WrappedSocket = {}
function WrappedSocket:new(inOriginalSocket, inHandler)
	local o = {
        originalSocket = inOriginalSocket,
        handler = inHandler
    }
	setmetatable(o, self)
	self.__index = self
	return o
end
function WrappedSocket:getfd()
	return self.originalSocket:getfd()
end
function WrappedSocket:getOriginal()
    return self.originalSocket
end
function WrappedSocket:handle(inReceivers, inSenders)
    return self.handler(self, inReceivers, inSenders)
end
--
--
--
local Selectings = {}
function Selectings:new()
	local o = { eventListeners = {} }
	setmetatable(o, self)
	self.__index = self
	return o
end
function Selectings:addSelecting(inSelecting)
	local listeners = self.eventListeners
	listeners[#listeners+1] = inSelecting
	return inSelecting
end
function Selectings:removeSelecting(inSelecting)
	local listeners = self.eventListeners
	local size = #listeners
	array_remove(listeners, function(t,i) return t[i]~= inSelecting end)
	return size ~= #listeners
end
function Selectings:getSelectings()
    return self.eventListeners
end
--
--
--
local GLOBAL_BUFFER = {} -- takes up to n "ringbuffers" which receive samples form incoming clients
local GLOBAL_COUNT=0     -- curent Index in the "ringbuffers" in GLOBAL_BUFFER. We add "smax" each run and take the modulo GLOBAL_SIZE
local GLOBAL_SIZE=0      -- overall size of a Buffer to receive samples, i.e. it may contain samples worth 2 fullbeats

local NUM_BEATS = 2

local PLAYING = false
local SAMPLE_RATE = 0
local BPM = 0
local MILLISECONDS_PER_BEAT = 0
local SAMPLES_PER_MILLISECOND = 0
local SAMPLES_PER_BEAT = 0

local PROCESS_BLOCK_COUNTER = 0

local function INIT_BUFFERS(inSamples)
    local temp = {} 
    for j=1,4 do
        temp[j] = {}
        for i = 1,inSamples do
            temp[j][i] = 0.0
        end
    end
    GLOBAL_BUFFER, GLOBAL_SIZE = temp, inSamples
    print("Buffer size: "..GLOBAL_SIZE)
end
--
--
--
local function repaintIt()
	local guiComp = gui:getComponent()
	if guiComp then
		--createImageStereo(process);
		--createImageMono(left);
		guiComp:repaint()
	end
end
--
--
--
local function readHandler(inWrappedSocket, inReceivers, inSenders)
    local originalSocket = inWrappedSocket:getOriginal()
    --print("READ START: " .. tostring(originalSocket))
    local received, error, partial = originalSocket:receive()
    --if received = (received~=nil) and received or "empty"
    if error == nil then
        --print("READ END: " .. tostring(received))
        local incomingBuffer = {}
        for part in string.gmatch(received,"(.-);") do
            incomingBuffer[#incomingBuffer+1]=tonumber(part)
        end
        --for i = 1,#incomingBuffer do
        --    print(tostring(incomingBuffer[i])..":")
        --end
        local clientID = incomingBuffer[1]
        local ppq = incomingBuffer[2]
        local numPoints = incomingBuffer[3]

        local moduloPPQ = ppq % NUM_BEATS
        local moduloPosition = ceil(moduloPPQ*SAMPLES_PER_BEAT)
        local currentIDX = moduloPosition
        -- print("ADD AT: "..currentIDX)
        local copyToBuffer = GLOBAL_BUFFER[clientID]
        for i = 4,#incomingBuffer do
            copyToBuffer[currentIDX]=incomingBuffer[i]
            currentIDX = currentIDX + 1
        end
    else
        print("READ ERROR: " .. tostring(error))
        inReceivers:removeSelecting(inWrappedSocket)
        originalSocket:close()
    end
end


--
--
--
local fakeBound = WrappedSocket:new(bound,
    function(inWrappedSocket, inReceivers, inSenders)
        local originalSocket = inWrappedSocket:getOriginal()
        print("ACCEPT START: " .. tostring(originalSocket))
        local newClient = originalSocket:accept()
        local wrappedNewClient = WrappedSocket:new(newClient, readHandler)
        inReceivers:addSelecting(wrappedNewClient)
        print("ACCEPT END: "..tostring(newClient).."; wrapped: "..tostring(wrappedNewClient))
        return wrappedNewClient
    end
)
--
--
-- JUST ADD THE SINGLE accept socket for now
local receivers = Selectings:new()
      receivers:addSelecting(fakeBound)
local senders = Selectings:new()


--
local function prepareToPlayHandler()
    SAMPLE_RATE=plugin.getSampleRate()
    print("PREPARE TO PLAY: "..SAMPLE_RATE)
end
plugin.addHandler("prepareToPlay",prepareToPlayHandler)


local function checkBPMChange(inBPM)
    if BPM ~= inBPM then
        BPM=inBPM
        MILLISECONDS_PER_BEAT = ceil(60000 / BPM)
        SAMPLES_PER_MILLISECOND = SAMPLE_RATE / 1000
        SAMPLES_PER_BEAT = ceil(MILLISECONDS_PER_BEAT * SAMPLES_PER_MILLISECOND)
        local samples = NUM_BEATS * SAMPLES_PER_BEAT
        INIT_BUFFERS(samples)
        print("BPM: "..inBPM.."; msec/beat: "..MILLISECONDS_PER_BEAT.."; samp/msec: "..SAMPLES_PER_MILLISECOND.."; samp/beat: "..SAMPLES_PER_BEAT)
    end
end

function plugin.processBlock(samples, smax, midiBuf)
    local pluginPosition = plugin.getCurrentPosition()
    local bpm = pluginPosition.bpm
    local ppq = pluginPosition.ppqPosition
    --
    checkBPMChange(bpm)
    --

    if not PLAYING and pluginPosition.isPlaying then
        -- switch from not playing to playing
        PLAYING = true
    end
    if PLAYING and not pluginPosition.isPlaying then
        -- switch from playing to not playing
        PLAYING = false
    end

    if PLAYING then
        local moduloPPQ = ppq % NUM_BEATS
        local moduloPosition = ceil(moduloPPQ*SAMPLES_PER_BEAT)
        --print("PPQ: "..moduloPPQ.."; Samples: "..moduloPosition.."; ToEnd: "..GLOBAL_SIZE-moduloPosition)
    end
    --
    -- print("before select")
    local selected = socket.select(receivers:getSelectings(), nil, 0)
    -- print("after select: " .. #selected)
    for i = 1, #selected do
        selected[i]:handle(receivers, senders)
    end
    GLOBAL_COUNT = (GLOBAL_COUNT+smax) % GLOBAL_SIZE
    PROCESS_BLOCK_COUNTER = PROCESS_BLOCK_COUNTER + 1
    if(PROCESS_BLOCK_COUNTER %2 == 0) then
        repaintIt()
    end
end

local alpha = 127
local COLS = {
    juce.Colour(255, 0, 0, alpha),
    juce.Colour(0, 255, 0, alpha),
    juce.Colour(255, 0, 255, alpha),
    juce.Colour(255, 255, 0, alpha)
}

function gui.paint(g)
    g:setColour(juce.Colour(0, 0, 0))
	g:fillAll()
    for j=1,3 do
        g:setColour(COLS[j])
        local GLOB_BUF = GLOBAL_BUFFER[j]
        local deltaX = 1600 / #GLOB_BUF
        local stepsize = 1 / deltaX
        if stepsize < 1 then
            stepsize = 1
        elseif stepsize > 10 then
            stepsize = 10
        else
            stepsize = floor(stepsize)
        end
        for i = 1,#GLOB_BUF,stepsize do
            local x= 100 + i * deltaX
            local y= 300 + GLOB_BUF[i]*200
            --g:setPixel(x,y)
            g:drawRect(x,y,1,1)
        end
    end
end