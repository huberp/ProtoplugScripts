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

-- local lanes = require "lanes".configure()
-- f = lanes.gen( function( n) return 2 * n end)
-- a = f( 1)
-- b = f( 2)
-- print( a[1], b[1] )     -- 2    4

local socket = require("include/socket")

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
-- A Wrapper which allows me to add a "Handler" to a Socket which handles stuff when the socket has been "selected"
-- Handlers are Accept-Handler and Read-Handler
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
-- Implement getfd as it is used in select, see https://lunarmodules.github.io/luasocket/tcp.html#getfd, https://lunarmodules.github.io/luasocket/socket.html#select. It wordwards to the wrapped socket
function WrappedSocket:getfd()
	return self.originalSocket:getfd()
end
-- Implement dirty as it is used in select, see https://lunarmodules.github.io/luasocket/tcp.html#dirty,https://lunarmodules.github.io/luasocket/socket.html#select. It wordwards to the wrapped socket
function WrappedSocket:dirty()
	return self.originalSocket:dirty()
end
function WrappedSocket:getOriginal()
    return self.originalSocket
end
function WrappedSocket:handle(inReceivers, inSenders)
    return self.handler(self, inReceivers, inSenders)
end
--
-- A Base class for sockets that should be used by 'select'
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
local GLOBAL_SIZE=0      -- overall size of a Buffer to receive samples, i.e. it may contain samples worth 2 fullbeats

local NUM_BEATS = 1

local SAMPLE_RATE = 0
local BPM = 0
local MILLISECONDS_PER_BEAT = 0
local SAMPLES_PER_MILLISECOND = 0
local SAMPLES_PER_BEAT = 0

local PROCESS_BLOCK_COUNTER = 0
--
--
--
local function INIT_BUFFERS(inNumBeats, inSamplesPerBeat)
    local  totalNumSamples = inNumBeats * inSamplesPerBeat
    local temp = {}
    for j=1,4 do
        temp[j] = {}
        for i = 1,totalNumSamples do
            temp[j][i] = 0.0
        end
    end
    GLOBAL_BUFFER, GLOBAL_SIZE = temp, totalNumSamples
    print("Buffer size: "..GLOBAL_SIZE.."; Buffers: "..#GLOBAL_BUFFER)
    for j=1,4 do
        local count = 0;
        for i = 1,totalNumSamples do
            if nil == GLOBAL_BUFFER[j][i] then
                count = count + 1
            end
        end
        print("BUFFER: "..j.."; #nils: "..count.."; table: "..tostring(GLOBAL_BUFFER[j]).."; length: "..#GLOBAL_BUFFER[j])
    end
end
--
--
--
local function stringTokenizer(inString, inSeperator)
    local startIdx=1
    return function()
        local foundIdx = string.find(inString,inSeperator,startIdx,true)
        if foundIdx == nil then
            return nil
        end
        local currentStartIdx = startIdx
        startIdx = foundIdx+1 -- set for next run
        return string.sub(inString, currentStartIdx, foundIdx-1)
    end
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
local PATH_BUCKETS_PER_BEAT = 48
local GLOBAL_JUCE_PATHS = { {}, {}, {}, {} }
local GUI_TRANSLATE_TRAFO = juce.AffineTransform():translated(0,200)
local function finishBucket(inReceivedClientID, inStartPositionOfLastRead, inEndPositionOfLastRead)

    local samplesPerBucket = SAMPLES_PER_BEAT / PATH_BUCKETS_PER_BEAT
    local startBucket = floor(inStartPositionOfLastRead / samplesPerBucket)
    local endBucket   = floor(inEndPositionOfLastRead   / samplesPerBucket)
    if startBucket == endBucket then
        -- nothing to do
        return
    end

    -- print("BUCKET READY: startBucket: "..startBucket
        --     .."; endBucket: "..endBucket
        --     .."; startPosition: "..moduloPosition
        --     .."; endPosition: "..moduloPosition+receivedNumPoints
        --     .."; lastINsertIDx: "..idxToGlobalBufferOfClient
        --     .."; receivedNumPoints: "..receivedNumPoints
        --     .."; actualReceived: "..actualReceivedPoints
        --     .."; SAMPLES_PER_BEAT: "..SAMPLES_PER_BEAT
        --     .."; samplesPerQuaterBeat: "..samplesPerQuaterBeat)

    local GLOB_BUF = GLOBAL_BUFFER[inReceivedClientID]
    local trafoScaleX = 1600 / GLOBAL_SIZE
    for dirtyBucketsIdx = startBucket, endBucket do
        local bucketSampleStartIdx = ceil((dirtyBucketsIdx * samplesPerBucket) % GLOBAL_SIZE)
        -- print("FINISH BUCKET: clientIdx: "..inReceivedClientID
        --     .."; bucket: "..inStartBucket
        --     .."; moduloPosition: "..inModuloPosition.."; bucketStartIdx: "..bucketStartIdx.."; bucketEndIdx: "..(bucketStartIdx+inSamplesPerQuaterBeat)
        --     .."; samplesPerQuaterBeat: "..inSamplesPerQuaterBeat
        --     .."; table: "..tostring(GLOB_BUF))
        local tempPath = juce.Path()
        for i = 1,samplesPerBucket,2 do
            local idx = bucketSampleStartIdx+i
            local yVal = GLOB_BUF[idx]
            -- if nil == yVal then
            --     print("ALARM: idx:"..bucketStartIdx+i.."; size: "..#GLOB_BUF)
            --     for k = (bucketStartIdx+i-5),(bucketStartIdx+i+5) do
            --         print("IDX: "..k.."; val: "..tostring(GLOB_BUF[k]))
            --     end
            -- end
            if 1 == i then
                tempPath:startNewSubPath(bucketSampleStartIdx,yVal)
            else
                tempPath:lineTo(idx, yVal)
            end
        end
        local transform = juce.AffineTransform():scaled(trafoScaleX,300)--:followedBy(GUI_TRANSLATE_TRAFO)
        tempPath:applyTransform(transform)
        GLOBAL_JUCE_PATHS[inReceivedClientID][(dirtyBucketsIdx%PATH_BUCKETS_PER_BEAT)+1] = { path = tempPath, dirty = true }
    end
end
--
local function jucePathOf(inClientID, inBucket)
    local maxBucketsNumber = NUM_BEATS * 4
    local indexFromCoordinates = ((inClientID-1) * maxBucketsNumber) + inBucket
    return GLOBAL_JUCE_PATHS[indexFromCoordinates]
end
--
--
-- READ HANDLER: Reads Data from Clients
--
--
local function readHandler(inWrappedSocket, inReceivers, inSenders)
    local originalSocket = inWrappedSocket:getOriginal()
    --print("READ START: " .. tostring(originalSocket))
    local received, error, partial = originalSocket:receive()
    --if received = (received~=nil) and received or "empty"
    if error == nil then
        --print("READ END: " .. string.sub(tostring(received),-60))
        --
        -- NOTE: We do not use the Iterator returned by gmatch directly in a for-loop
        -- therefore we need to us a while loop later and CANNOT use for a in iterator...
        local receivedIterator  = stringTokenizer(received,";")--string.gmatch(received,"(.-);")
        local receivedClientID  = tonumber(receivedIterator())
        local receivedPpq       = tonumber(receivedIterator())
        local receivedNumPoints = tonumber(receivedIterator())
        --
        -- just a simple cached / dereferenced variable in order to speed things up in the loop below
        local globalBufferOfClientid = GLOBAL_BUFFER[receivedClientID]
        --
        -- compute the "Positions" here.
        local moduloPPQ = receivedPpq % NUM_BEATS
        local moduloPosition = ceil(moduloPPQ*SAMPLES_PER_BEAT)
        --
        local idxToGlobalBufferOfClient = moduloPosition
        -- print("READ: clt:"..receivedClientID.."; ppq:"..receivedPpq)
        --
        -- NOTE: Now here we use the while loop... with a naive for a in iterator
        -- continue using the iterator 'receivedIterator' we would get NIL values in the array!
        local actualReceivedPoints = 0
        for receivedSample in receivedIterator do
            local sample = tonumber(receivedSample)
            actualReceivedPoints = actualReceivedPoints +1
            -- if sample == nil then
            --     -- SHOULD NEVER HAPPEN
            --     print("NIL: client: "..receivedClientID.."; ppq: "..receivedPpq.."; idx: "..currentIDX)
            --     print("NIL2: received"..received)
            --     print(sample)
            -- end
            globalBufferOfClientid[idxToGlobalBufferOfClient]=sample
            --
            -- keep loop state up to data
            idxToGlobalBufferOfClient = ceil((idxToGlobalBufferOfClient + 1) % GLOBAL_SIZE)
            -- if(idxToGlobalBufferOfClient > GLOBAL_SIZE) then
            --     print("ALARM: GLOBAL_SIZE:"..GLOBAL_SIZE
            --     .."; IDX: "..idxToGlobalBufferOfClient
            --     .."; mPPQ: "..moduloPPQ
            --     .."; mPos: "..moduloPosition.."; delta: "..(GLOBAL_SIZE-moduloPosition)
            --     .."; table: "..tostring(globalBufferOfClientid)
            --     )
            -- end
        end
        --print("INSERT IDX: start:"..moduloPosition.."; final: "..idxToGlobalBufferOfClient.."; table: "..tostring(globalBufferOfClientid))
        --
        -- now we think again about quarter beats in order to "redraw" only the quarters we have to
        finishBucket(receivedClientID, moduloPosition, moduloPosition+receivedNumPoints) -- finish buckets
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
        newClient:setoption("tcp-nodelay",true)
        newClient:settimeout(0)
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
        MILLISECONDS_PER_BEAT = 60000 / BPM
        SAMPLES_PER_MILLISECOND = SAMPLE_RATE / 1000
        SAMPLES_PER_BEAT = MILLISECONDS_PER_BEAT * SAMPLES_PER_MILLISECOND
        INIT_BUFFERS(NUM_BEATS, SAMPLES_PER_BEAT)
        print("BPM: "..inBPM.."; msec/beat: "..MILLISECONDS_PER_BEAT.."; samp/msec: "..SAMPLES_PER_MILLISECOND.."; samp/beat: "..SAMPLES_PER_BEAT)
    end
end
--
--
--
local function computeMeans()
    local sectionsLen = floor(SAMPLES_PER_BEAT / 4.0)
    local GLOB_BUF_1 = GLOBAL_BUFFER[1]
    local GLOB_BUF_2 = GLOBAL_BUFFER[2]
    local GLOB_BUF_3 = GLOBAL_BUFFER[3]
    local GLOB_BUF_4 = GLOBAL_BUFFER[4]
    local summed = {}
    for i = 1,#GLOB_BUF_1 do
        local squareIt = GLOB_BUF_1[i] + GLOB_BUF_2[i] + GLOB_BUF_3[i] +GLOB_BUF_4[i]
        summed[#summed+1] = squareIt * squareIt
    end
    local means = {}
    for i = 1,#GLOB_BUF_1-sectionsLen,sectionsLen do
        local mean=0
        for h = 1,sectionsLen-1 do
            local squared_sample  = summed[i+h]
            if(squared_sample == nil) then
                print("ERROR: size: "..#GLOB_BUF.."; idx:"..(i+h).."; client: "..inClient.."; sectionsLen: "..sectionsLen)
            end
            mean = mean + squared_sample
        end
        means[#means+1] = mean / sectionsLen
    end
    return means, sectionsLen
end

-- ================================================
--
-- MAIN LOOP
--
-- ================================================
function plugin.processBlock(samples, smax, midiBuf)
    local pluginPosition = plugin.getCurrentPosition()
    local bpm     = pluginPosition.bpm
    --local ppq     = pluginPosition.ppqPosition
    --
    checkBPMChange(bpm)
    --
    -- print("before select")
    local selected = socket.select(receivers:getSelectings(), nil, 0)
    -- print("after select: " .. #selected)
    for i = 1, #selected do
        selected[i]:handle(receivers, senders)
    end
    PROCESS_BLOCK_COUNTER = PROCESS_BLOCK_COUNTER + 1
    if (PROCESS_BLOCK_COUNTER % 2 == 0) then
        repaintIt()
    end
end



local alpha = 100
local COLS = {
    juce.Colour(255, 0, 0, alpha),
    juce.Colour(0, 255, 0, alpha),
    juce.Colour(255, 0, 255, alpha),
    juce.Colour(255, 255, 0, alpha)
}
local BLACK = juce.Colour(0, 0, 0)
local gridYMin = -200
local gridYMax = 200

local imageForDisplay = juce.Image (juce.Image.PixelFormat.RGB, 1600, 400, true)
local gImage = juce.Graphics(imageForDisplay)
-- set the global transform for the Display
gImage:addTransform(GUI_TRANSLATE_TRAFO)
local args = {thickness = 2}
function gui.paint(g)
    local bounds = g:getClipBounds()
    if not g:isClipEmpty() then
        --print("Clip: x:"..bounds.x.."; y:"..bounds.y.."; w:"..bounds.w.."; h:"..bounds.h)
    end
	--g:setColour(BLACK)
    --g:fillAll()
    g:addTransform(GUI_TRANSLATE_TRAFO)
    --
    local trafoScaleX = 1600 / GLOBAL_SIZE
    local bucketDeltaX = (SAMPLES_PER_BEAT / PATH_BUCKETS_PER_BEAT) * trafoScaleX
    --
    --
    --samples
    for clientIdx=1,3 do
        --g:setColour(COLS[j])
        local pathsOfClientDeref = GLOBAL_JUCE_PATHS[clientIdx]
        for bucketPathIdx = 1,PATH_BUCKETS_PER_BEAT do
            local singlePathOfBucket = pathsOfClientDeref[bucketPathIdx]
            if nil ~= singlePathOfBucket then
                local dirty = singlePathOfBucket["dirty"]
                if dirty then
                    -- first clean stuff here
                    g:setColour(BLACK)
                    local xMax = ceil(bucketDeltaX*bucketPathIdx)
                    local xMin = floor(xMax - bucketDeltaX) -- actually this would be 100+bucketDeltaX*(bucketPathIdx-1) ...but for performance reasons
                    g:fillRect(xMin,gridYMin, ceil(bucketDeltaX),400)
                    -- print("WIPE: xmin:"..xMin.."; xmax: "..xMax)
                    -- theres one path dirty in this bucket then re-draw all paths of the same bucket as well
                    for clientIdx_INNER = 1, 3 do
                        local singlePathOfBucket_INNER = GLOBAL_JUCE_PATHS[clientIdx_INNER][bucketPathIdx]
                        if nil ~= singlePathOfBucket_INNER then
                            local thePath = singlePathOfBucket_INNER["path"]
                            g:setColour(COLS[clientIdx_INNER])
                            g:strokePath(thePath)
                            local boundingBox = thePath:getBounds()
                            --print("Bounding: x:"..boundingBox.x.."; y:"..boundingBox.y.."; w:"..boundingBox.w.."; h:"..boundingBox.h)
                            singlePathOfBucket_INNER["dirty"] = false
                        end
                    end
                end
            end
        end
    end
    --
    --
    --grid
    local gridDeltaX = (SAMPLES_PER_BEAT / 4.0) * trafoScaleX
    g:setColour(juce.Colour(255, 255, 255, alpha))
    local gridPath = juce.Path ()
    for i = 0,4 do
        local gridX = gridDeltaX * i
        gridPath:startNewSubPath(gridX,gridYMin)
        gridPath:lineTo(gridX,gridYMax)
    end
    --gridPath:applyTransform(GUI_TRANSLATE_TRAFO)
    g:strokePath(gridPath)
    gridPath = nil
    --
    --
    --means
    g:setColour(juce.Colour(255, 160, 0, alpha))
    local means, sectionLen = computeMeans()
    local width = sectionLen * (1600/GLOBAL_SIZE)
    local meansPath = juce.Path ()
    for i = 1,#means do
        local x = (i-1)*width
        local y = means[i] * 1600
        meansPath:startNewSubPath(x,y)
        meansPath:lineTo(x+width,y)
    end
    --meansPath:applyTransform(GUI_TRANSLATE_TRAFO)
    g:strokePath(meansPath)
    --
    --finally draw image
    --g:drawImageAt(imageForDisplay, 100, 100)
end