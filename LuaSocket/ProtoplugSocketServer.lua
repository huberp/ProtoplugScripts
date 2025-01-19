require "include/protoplug"

--
local ceil = math.ceil
local floor = math.floor
local sqrt = math.sqrt

--Welcome to Lua Protoplug effect (version 1.4.0)
--package.path=package.path .. ";C:/Program Files/Common Files/VST3/Protoplug/ProtoplugFiles/lib/socket/?.dll"
print("###")
-- https://www.gammon.com.au/scripts/doc.php?lua=package.loadlib
package.cpath = package.cpath .. ";"..protoplug_dir.."/lib/?.dll"

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
local GLOBAL_SAMPLE_BUFFER = {} -- takes up to n "ringbuffers" which receive samples form incoming clients
local GLOBAL_SIZE=0             -- overall size of a Buffer to receive samples, i.e. it may contain samples worth 2 fullbeats

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
    GLOBAL_SAMPLE_BUFFER, GLOBAL_SIZE = temp, totalNumSamples
    print("Buffer size: "..GLOBAL_SIZE.."; Buffers: "..#GLOBAL_SAMPLE_BUFFER)
    for j=1,4 do
        local count = 0;
        for i = 1,totalNumSamples do
            if nil == GLOBAL_SAMPLE_BUFFER[j][i] then
                count = count + 1
            end
        end
        print("BUFFER: "..j.."; #nils: "..count.."; table: "..tostring(GLOBAL_SAMPLE_BUFFER[j]).."; length: "..#GLOBAL_SAMPLE_BUFFER[j])
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
-- BUCKET STUFF
--
-- creates a function which computes a ringbuffer index for a ring buffer of size inMaxSamples
-- The provided function returns the one-based index, [1, inMaxSamples]
local function newRingBufferIndexFct(inMaxSamples)
    return function(inGiven) -- returns an 1-based index
        local relValue = inGiven
        if inGiven < 0 then
            relValue = inMaxSamples - relValue
        end
        return floor(relValue % inMaxSamples) + 1 -- modulo wraps around to zero therefore use + 1
    end
end
--
-- returns a structure with maxSamples, saplesPerBucket and array with buckets, ie #, start, last each
--
local function computeBuckets(inMaxSamples, inNumberOfBuckets)
    local samplesPerBucket = inMaxSamples / inNumberOfBuckets
    local buckets = {}
    local endIdx = 0
    local startIdx = 0
    local bucketNo = 0
    for idx = 0, inNumberOfBuckets-1 do
        bucketNo = idx+1 -- from 1 to inBuckets (incl)
        startIdx = endIdx + 1 -- one based 
        endIdx   = startIdx + samplesPerBucket - 1 -- including end idx
        if(idx==inNumberOfBuckets-1) then
            endIdx = inMaxSamples
        end
        buckets[bucketNo] = { bNo=bucketNo, start = floor(startIdx), last = floor(endIdx) }
    end
    print("Buckets size inBuckets: "..inNumberOfBuckets.."; resultSize: "..#buckets.."; maxSamples: "..inMaxSamples.."; samplesPerBucket: "..samplesPerBucket)
    for i = 1,#buckets do
        print("Bucket nr: "..buckets[i].bNo.."; s: "..buckets[i].start.."; e:"..buckets[i].last.."; size: "..(buckets[i].last - buckets[i].start + 1))
    end
    return {
        maxSamples = inMaxSamples,
        samplesPerBucket = samplesPerBucket,
        buckets = buckets
    }
end
--
-- Computes a list of BucketNumbers which are affected by a sample fill affecting the buffer indexes [inStartSampleIdx, inEndSampleIdx]
--
local function getAffectedBuckets(inComputedBuckets, inStartSampleIdx, inEndSampleIdx)
    local maxIdx = #inComputedBuckets
    local maxSamples = inComputedBuckets.maxSamples
    local samplesPerBucket = inComputedBuckets.samplesPerBucket
    local buckets = inComputedBuckets.buckets
    local numberOfBuckets = #buckets

    local startBucketNo = floor(inStartSampleIdx / samplesPerBucket) + 1 -- floor will give us zero, max number of buckets - 1, therefore we  do + 1
    local endBucketNo   = floor(inEndSampleIdx   / samplesPerBucket) + 1 -- floor will give us zero, max number of buckets - 1, therefore we  do + 1
    --local startBucketStartIdx = buckets[startBucketNo].start
    local startBucketEndIdx   = buckets[startBucketNo].last
    -- about "endBucket": keep in mind that the endBucket most probabaly has not been finished completely, therefore we have to check this
    --local endBucketStartIdx   = buckets[endBucketNo].start
    local endBucketEndIdx     = buckets[endBucketNo].last
    --
    -- now find affected bucketNumbers
    -- is startBucket affected and only startBucket?
    if startBucketNo == endBucketNo then
        if inEndSampleIdx == startBucketEndIdx then
            -- the startbucket has been filled up rght to it's own end, but we don't have anything more
            return { startBucketNo }
        else
            -- the starBucket has not been filled up to the end ... nothing todo right now.
            return {}
        end
    end
    -- now all buckets inbetween but the last one
    local resultBucketNumberList = { startBucketNo }
    local bucketNoIdx = (startBucketNo % numberOfBuckets)
    print("startBucketNo: ".. startBucketNo.."; endBucketNo: "..endBucketNo.."; num buckets: "..numberOfBuckets)
    print("Intermediat Buckets, bucketNoIdx: "..(bucketNoIdx+1).."; endBucketNo: "..endBucketNo)
    while bucketNoIdx+1 ~= endBucketNo do
        resultBucketNumberList[#resultBucketNumberList+1] = bucketNoIdx+1
        bucketNoIdx = ((bucketNoIdx+1) % numberOfBuckets)
    end
    -- now look at the last one. only if it has been fieled up completely, it goes into the seresult.
    if inEndSampleIdx == endBucketEndIdx then
        resultBucketNumberList[#resultBucketNumberList+1] = endBucketNo
    end
    return resultBucketNumberList
end
--
local function testBuckets()
    local test = computeBuckets(20000, 4)
    print("TEST")
    local idxs = getAffectedBuckets(test, 14880, 15839)
    for i=1,#idxs do
        print("affected: idx:"..idxs[i])
    end
    print("===")
    test = computeBuckets(20000, 12)
    print("TEST, 12, 1")
    local idxs = getAffectedBuckets(test, 20000 - 12, 3000)
    for i=1,#idxs do
        print("affected: idx:"..idxs[i])
    end
    print("TEST, 12,1,2")
    idxs = getAffectedBuckets(test, 20000 - 12, 3333)
    for i=1,#idxs do
        print("affected: idx:"..idxs[i])
    end
    print("TEST,2")
    idxs = getAffectedBuckets(test, 1667, 3333)
    for i=1,#idxs do
        print("affected: idx:"..idxs[i])
    end
    print("TEST,1,2")
    idxs = getAffectedBuckets(test, 1666, 3333)
    for i=1,#idxs do
        print("affected: idx:"..idxs[i])
    end
    print("TEST,1,2")
    idxs = getAffectedBuckets(test, 1666, 3334)
    for i=1,#idxs do
        print("affected: idx:"..idxs[i])
    end
    print("TEST,1")
    idxs = getAffectedBuckets(test, 0, 1667)
    for i=1,#idxs do
        print("affected: idx:"..idxs[i])
    end
end
testBuckets()

--
--
--
local EXAMPLE_BUCKETS = 4
local function finishExample(inReceivedClientID, inStartPositionOfLastRead, inEndPositionOfLastRead)
    if 1==inReceivedClientID then
        local first = nil
        local current = nil
        idx = false
        for bucket, aIdx, rIdx in newBucketIterator(GLOBAL_SIZE, EXAMPLE_BUCKETS, inStartPositionOfLastRead, inEndPositionOfLastRead) do
            current = "Bucketeer: bucket: "..tostring(bucket).."; aIdx: "..tostring(aIdx).."; rIdx: "..tostring(rIdx)
            if not idx then
                first = current
            end
            idx = true
        end
        if idx then
            print(first)
            print(current)
            print("=====")
        end
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
local GUI_TRANSLATE_TRAFO = juce.AffineTransform():translated(0,200)
--
--
--
local PATH_BUCKETS_PER_BEAT = 48
local GLOBAL_JUCE_PATHS = { {}, {}, {}, {} }
local function finishBucket(inReceivedClientID, inStartPositionOfLastRead, inEndPositionOfLastRead, inNumberOfNewSamples)

    local samplesPerRMSBucket = SAMPLES_PER_BEAT / PATH_BUCKETS_PER_BEAT
    local startBucket = floor(inStartPositionOfLastRead / samplesPerRMSBucket)
    local endBucket   = floor(inEndPositionOfLastRead   / samplesPerRMSBucket)
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

    local GLOB_BUF = GLOBAL_SAMPLE_BUFFER[inReceivedClientID]
    local trafoScaleX = 1600 / GLOBAL_SIZE
    for dirtyBucketsIdx = startBucket, endBucket do
        local bucketSampleStartIdx = floor((dirtyBucketsIdx * samplesPerRMSBucket) % GLOBAL_SIZE)
        -- print("FINISH BUCKET: clientIdx: "..inReceivedClientID
        --     .."; bucket: "..inStartBucket
        --     .."; moduloPosition: "..inModuloPosition.."; bucketStartIdx: "..bucketStartIdx.."; bucketEndIdx: "..(bucketStartIdx+inSamplesPerQuaterBeat)
        --     .."; samplesPerQuaterBeat: "..inSamplesPerQuaterBeat
        --     .."; table: "..tostring(GLOB_BUF))
        local tempPath = juce.Path()
        for i = 1,samplesPerRMSBucket,1 do
            local idx = bucketSampleStartIdx+i
            local yVal = GLOB_BUF[idx]
            if nil == yVal then
                print("ALARM: idx:"..bucketSampleStartIdx+i.."; size: "..#GLOB_BUF)
                for k = (bucketSampleStartIdx+i-5),(bucketSampleStartIdx+i+5) do
                    print("IDX: "..k.."; val: "..tostring(GLOB_BUF[k]))
                end
            end
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
--
local RMS_BUCKETS_PER_BEAT = 4
local GLOBAL_SAMPLE_SQUARES = { }
local GLOBAL_RMS = { }
local function finishRMS(inReceivedClientID, inStartPositionOfLastRead, inEndPositionOfLastRead)
    local samplesPerRMSBucket = SAMPLES_PER_BEAT / RMS_BUCKETS_PER_BEAT

    local GLOB_BUF_1 = GLOBAL_SAMPLE_BUFFER[1]
    local GLOB_BUF_2 = GLOBAL_SAMPLE_BUFFER[2]
    local GLOB_BUF_3 = GLOBAL_SAMPLE_BUFFER[3]
    local GLOB_BUF_4 = GLOBAL_SAMPLE_BUFFER[4]
    -- square the new samples
    for i = inStartPositionOfLastRead+1,inEndPositionOfLastRead do
        local squareIt = GLOB_BUF_1[i] + GLOB_BUF_2[i] + GLOB_BUF_3[i] + GLOB_BUF_4[i]
        GLOBAL_SAMPLE_SQUARES[i] = squareIt * squareIt
    end
    --
    local bucketLayout = computeBuckets(SAMPLES_PER_BEAT, RMS_BUCKETS_PER_BEAT)
    local affectedBuckets = getAffectedBuckets(bucketLayout, inStartPositionOfLastRead, inEndPositionOfLastRead)
    for i = 1,#affectedBuckets do
        local affectedBucketNo =  affectedBuckets[i]
        local startSampleIdx = bucketLayout.buckets[affectedBucketNo].start
        local lastSampleIdx  = bucketLayout.buckets[affectedBucketNo].last
        local tempRMS = 0
        for smpIdx = startSampleIdx, lastSampleIdx do
            local val = GLOBAL_SAMPLE_SQUARES[smpIdx]
            if val == nil then val = 0 end
            tempRMS = tempRMS + val
        end
        GLOBAL_RMS[affectedBucketNo] = sqrt(tempRMS / samplesPerRMSBucket)
    end
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
        local globalBufferOfClientid = GLOBAL_SAMPLE_BUFFER[receivedClientID]
        --
        -- compute the "Positions" here.
        local moduloPPQ = receivedPpq % NUM_BEATS
        local moduloPosition = ceil(moduloPPQ*SAMPLES_PER_BEAT)
        --
        local idxToGlobalBufferOfClient = moduloPosition
        if(idxToGlobalBufferOfClient==0) then
            print("idxToGlobalBufferOfClient: 0")
        end

        -- print("READ: clt:"..receivedClientID.."; ppq:"..receivedPpq)
        --
        -- NOTE: Now here we use the while loop... with a naive for a in iterator
        -- continue using the iterator 'receivedIterator' we would get NIL values in the array!
        local actualReceivedPoints = 0
        local lastInsertIdx = idxToGlobalBufferOfClient
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
            lastInsertIdx = idxToGlobalBufferOfClient
            -- print("READ: clt:"..receivedClientID.."; ppq:"..receivedPpq.."; idx: "..currentIDX.."; sample: "..sample)

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
        if(1==receivedClientID)then
            print("INSERT IDX: start:"..moduloPosition.."; lastInsertIdx: "..lastInsertIdx.."; idxToGlobalBufferOfClient: "..lastInsertIdx.."; actualReceivedPoints: "..actualReceivedPoints)
        end
        --
        -- now we think again about quarter beats in order to "redraw" only the quarters we have to
        finishBucket (receivedClientID, moduloPosition, lastInsertIdx, actualReceivedPoints) -- finish path buckets
        --finishExample(receivedClientID, moduloPosition, lastInsertIdx, actualReceivedPoints) -- finish path buckets
        finishRMS    (receivedClientID, moduloPosition, lastInsertIdx, actualReceivedPoints) -- finish rms buckets
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
    local GLOB_BUF_1 = GLOBAL_SAMPLE_BUFFER[1]
    local GLOB_BUF_2 = GLOBAL_SAMPLE_BUFFER[2]
    local GLOB_BUF_3 = GLOBAL_SAMPLE_BUFFER[3]
    local GLOB_BUF_4 = GLOBAL_SAMPLE_BUFFER[4]
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
    local sectionLen = SAMPLES_PER_BEAT / RMS_BUCKETS_PER_BEAT
    local width = sectionLen * (1600/GLOBAL_SIZE)
    local meansPath = juce.Path ()
    for i = 1,#GLOBAL_RMS do
        local x = (i-1)*width
        local y = GLOBAL_RMS[i] * 800
        meansPath:startNewSubPath(x,y)
        meansPath:lineTo(x+width,y)
    end
    --meansPath:applyTransform(GUI_TRANSLATE_TRAFO)
    g:strokePath(meansPath)
    --
    --finally draw image
    --g:drawImageAt(imageForDisplay, 100, 100)
end