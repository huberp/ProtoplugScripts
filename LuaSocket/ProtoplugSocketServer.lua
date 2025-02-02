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
-- Tokenizer: Returns an Iterator which splits a given string at a given Seperator
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
local PADDINGS = { "     ", "    ", "   ", "  ", " ", "" }
function padTo2(inNum)
    local str = tostring(inNum)
    local pad = string.len(str)
    if pad >= 2 then return str end
    return PADDINGS[pad+4] .. str
end
function padTo3(inNum)
    local str = tostring(inNum)
    local pad = string.len(str)
    if pad >= 3 then return str end
    return PADDINGS[pad+3] .. str
end
function padTo4(inNum)
    local str = tostring(inNum)
    local pad = string.len(str)
    if pad >= 4 then return str end
    return PADDINGS[pad+2] .. str
end
function padTo5(inNum)
    local str = tostring(inNum)
    local pad = string.len(str)
    if pad >= 5 then return str end
    return PADDINGS[pad+1] .. str
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
--======================================================================================================================
--
--
-- A Base class for sockets that should be used by 'select'
-- Users can register a handler for events on a socket.
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
--======================================================================================================================
--
--
-- common event and event-context attribute names
-- use these names to put into or get from events or the event-context and thus get hold of the "DAW context" an single
-- event happened in.
--
local EVT_VAL_CTX = "CONTEXT"
local CTX_VAL_MIDI_BUFFER = "midiBuffer"
local CTX_VAL_DAW_POSITION = "position"
local CTX_VAL_NUM_SAMPLES_IN_FRAME = "numberOfSamplesInFrame"
local CTX_VAL_SAMPLES_OF_FRAME = "samplesOfFrame"
local CTX_VAL_EPOCH = "epoch"
--
-- helper allows to get all 5 context values of a main process ing loop from a list, ...
-- ... assuming they are stored under the defined key-names, CTX_VAL_MIDI_BUFFER, etc.
--
local function unpackCtx(inEvent)
	local ctx = inEvent[EVT_VAL_CTX]
	return
		ctx[CTX_VAL_SAMPLES_OF_FRAME],
		ctx[CTX_VAL_NUM_SAMPLES_IN_FRAME],
		ctx[CTX_VAL_MIDI_BUFFER],
		ctx[CTX_VAL_DAW_POSITION],
		ctx[CTX_VAL_EPOCH]
end
--
-- creates an event-context object form the parameters passed in
-- 
local function packCtx(inSamples, inSamplesNumberOfCurrentFrame, inMidiBuffer, inDAWPosition, inEpoch)
	return {
		[CTX_VAL_SAMPLES_OF_FRAME] = inSamples,
		[CTX_VAL_NUM_SAMPLES_IN_FRAME] = inSamplesNumberOfCurrentFrame,
		[CTX_VAL_MIDI_BUFFER] = inMidiBuffer,
		[CTX_VAL_DAW_POSITION] = inDAWPosition,
		[CTX_VAL_EPOCH] = inEpoch
	}
end
local function eventFromEvent(inTriggeringEvent, inNewEvt)
	inNewEvt[EVT_VAL_CTX] = inTriggeringEvent[EVT_VAL_CTX]
	return inNewEvt
end
--======================================================================================================================
--
--
-- EventSource Base Class
--
--
local EventSource = {}
function EventSource:new()
	local o = { eventListeners = {} }
	setmetatable(o, self)
	self.__index = self
	return o
end
function EventSource:addEventListener(inEventListener)
	local listeners = self.eventListeners
	listeners[#listeners+1] = inEventListener
	LOG:log(LOG_L.DEBUG, "EventSource:addEventListener: self.eventListeners: ",listeners)
	return inEventListener
end
function EventSource:removeEventListener(inEventListener)
	local listeners = self.eventListeners
	local size = #listeners
	array_remove(listeners, function(t,i) return t[i]~= inEventListener end)
	LOG:log(LOG_L.DEBUG, "EventSource:removeEventListener: ", listeners)
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
--======================================================================================================================
--
--
-- GLOBALS Singleton
--
--
local PPQ_BASE_VALUE = {
	MSEC=60000.0, -- we base everything around this coordinates, so we even need the "right" time base...if we chose to base everything around 1/1 notes we need to set respective values here
	noteNum = 1.0,
	noteDenom = 4.0,
	ratio = 0.25
}
local GLOBALS = {
	runs = 0, -- number of plugin.processBlock has been called
	samplesCount = 0, -- sum of all sample blocks that we have seen.
	sampleRate = -1,
	sampleRateByMsec = -1, --computed; how many samples per milisecond we have
	isPlaying = false,
	bpm = 0,
	msecPerBeat = 0, --computed; based on whole note
	samplesPerBeat = 0, --computed; based on whole note
}
-- do a little dirty inheritance here, as GLOBALS is not really a class but just a global table where we want to add the event stuff.
setmetatable(GLOBALS, { __index= EventSource:new() })
print("GLOBALS: ".. #GLOBALS.eventListeners)

function GLOBALS:finishRun(inSmax)
	self.runs = self.runs+1
	self.samplesCount = self.samplesCount + inSmax
end
function GLOBALS:getCurrentSampleCount()
	return self.samplesCount
end
--
-- updates the globals at the BEGINNING of a new frame
-- returns the CONTEXT object of this frame
-- see pack Context
--
function GLOBALS:updateDAWGlobals(inSamples, inSamplesNumberOfCurrentFrame, inMidiBuffer, inDAWPosition)
	--print("Debug: Update Position; inHostPosition.bpm: " .. inHostPosition.bpm)
	local newBPM = inDAWPosition.bpm
	local oldBPM = self.bpm;
	local evtCtx = packCtx(inSamples, inSamplesNumberOfCurrentFrame, inMidiBuffer, inDAWPosition, self.runs)
	-- now pack the context and return it.
	local ctx = packCtx(inSamples, inSamplesNumberOfCurrentFrame, inMidiBuffer, inDAWPosition, self.epoch)
	if newBPM ~= oldBPM then
		-- remember old stuff
		local oldValues = { bpm=oldBPM, msecPerBeat=self.msecPerBeat, samplesPerBeat=self.samplesPerBeat, ppqBaseValue=PPQ_BASE_VALUE }
		-- compute and set new stuff
		self.bpm = newBPM
		self.msecPerBeat = PPQ_BASE_VALUE.MSEC / newBPM -- usually beats is based on quarters ... 
		self.samplesPerBeat = self.msecPerBeat * self.sampleRateByMsec
		-- pack new Values
		local newValues= { bpm=self.bpm, msecPerBeat=self.msecPerBeat, samplesPerBeat=self.samplesPerBeat, ppqBaseValue=PPQ_BASE_VALUE }
		-- fire event
		self:fireEvent({ type= "BPM",
				source=self,
				oldValues=oldValues,
				newValues=newValues,
				[EVT_VAL_CTX]  = evtCtx
			}
		)
	end
	local newIsPlaying = inDAWPosition.isPlaying
	local oldIsPlaying = self.isPlaying
	if newIsPlaying ~= oldIsPlaying then
		self.isPlaying = newIsPlaying
		self:fireEvent({
				type= "IS-PLAYING",
				source=self,
				oldValue=oldIsPlaying, newValue=newIsPlaying,
				[EVT_VAL_CTX]  = evtCtx
			}
		)
	end
	return ctx
end
function GLOBALS:updateSampleRate(inSampleRate)
	local oldSampleRate = self.sampleRate
	if inSampleRate ~= oldSampleRate then
		self.sampleRate = inSampleRate
		self.sampleRateByMsec = inSampleRate / 1000.0
		self:fireEvent({ type= "SAMPLE-RATE", old=oldSampleRate, new=inSampleRate; source=self })
	end
end

plugin.addHandler("prepareToPlay", function() GLOBALS:updateSampleRate(plugin.getSampleRate()) end)


--======================================================================================================================
--
-- Specific Global Data for this plugin
-- Must be refactored because it is to some extent a copy of the "other" Globals
--
local BUFFERS = {
    GLOBAL_SAMPLE_BUFFER = {}, -- takes up to n "ringbuffers" which receive samples form incoming clients
    GLOBAL_SIZE=0,             -- overall size of a Buffer to receive samples, i.e. it may contain samples worth 2 fullbeats
    NUM_BEATS = 1,
    SAMPLE_RATE = 0,
    BPM = 0,
    MILLISECONDS_PER_BEAT = 0,
    SAMPLES_PER_MILLISECOND = 0,
    SAMPLES_PER_BEAT = 0,
    PROCESS_BLOCK_COUNTER = 0,
}
--
--
--
function BUFFERS:initBuffers(inNumBeats, inSamplesPerBeat)
    local  totalNumSamples = inNumBeats * inSamplesPerBeat
    local temp = {}
    for j=1,4 do
        temp[j] = {}
        for i = 1,totalNumSamples do
            temp[j][i] = 0.0
        end
    end
    self.GLOBAL_SAMPLE_BUFFER, self.GLOBAL_SIZE = temp, totalNumSamples
    local bufferProtocol = "Buffer size: "..self.GLOBAL_SIZE.."; Buffers: "..#self.GLOBAL_SAMPLE_BUFFER
    for j=1,4 do
        local count = 0;
        for i = 1,totalNumSamples do
            if nil == self.GLOBAL_SAMPLE_BUFFER[j][i] then
                count = count + 1
            end
        end
        bufferProtocol = bufferProtocol .. "\nBUFFER: "..j.."; #nils: "..count.."; table: "..tostring(self.GLOBAL_SAMPLE_BUFFER[j]).."; length: "..#self.GLOBAL_SAMPLE_BUFFER[j]
    end
    print(bufferProtocol)
end
--
-- Listen to changes of Global settings
--
function BUFFERS:listenToGlobalsChange(inEvent)
	--print("GLOBAL Listener: ".. string.format("%s",self))
	if "BPM" == inEvent.type then
		-- local
		local eventNewValues = inEvent.newValues
		-- cache event values
        local newBPM = eventNewValues.bpm
		if self.BPM ~= newBPM then
            self.BPM=newBPM
            self.MILLISECONDS_PER_BEAT = 60000 / self.BPM
            self.SAMPLES_PER_BEAT = self.MILLISECONDS_PER_BEAT * self.SAMPLES_PER_MILLISECOND
            self:initBuffers(self.NUM_BEATS, self.SAMPLES_PER_BEAT)
            print("SMP: "..self.SAMPLES_PER_BEAT)
        end
	elseif "SAMPLE-RATE" == inEvent.type then
        local newSampleRate = inEvent.new
        self.SAMPLE_RATE = newSampleRate
        self.SAMPLES_PER_MILLISECOND = self.SAMPLE_RATE / 1000
        
    end
    print("BPM: "..self.BPM.."; msec/beat: "..self.MILLISECONDS_PER_BEAT
                .."; samp/msec: "..self.SAMPLES_PER_MILLISECOND.."; samp/beat: "..self.SAMPLES_PER_BEAT.."; evt.type: "..inEvent.type)
end
GLOBALS:addEventListener( function(inEvent) BUFFERS:listenToGlobalsChange(inEvent) end)
--======================================================================================================================
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
-- returns a structure with maxSamples, samplesPerBucket and array with buckets, ie #, start, last each
--
local function computeBuckets(inMaxSamples, inNumberOfBuckets)
    local samplesPerBucket = inMaxSamples / inNumberOfBuckets
    local buckets = {}
    local endIdx = 0
    local startIdx = 0
    local bucketNo = 0
    for idx = 0, inNumberOfBuckets-1 do
        bucketNo = idx                          -- zero based; from 0 to inBuckets (excl)
        -- for instance; samplesPerBucket = 2000
        -- then we have buckets [0*2000+1, 0*2000+1+2000-1], [1*2000+1, 1*2000+1+2000-1], [2*2000+1,2*2000+1+2000-1]
        -- that is [1, 2000], [2001,4000], [4001, 6000], ...
        startIdx = (idx * samplesPerBucket) + 1   -- one based array index within the bucket
        endIdx   = startIdx + samplesPerBucket -1 -- including end idx
        if(idx==inNumberOfBuckets-1) then
            endIdx = inMaxSamples
        end
        buckets[bucketNo+1] = { bNo=bucketNo, start = floor(startIdx), last = floor(endIdx) }
    end
    return {
        maxSamples       = inMaxSamples,
        samplesPerBucket = samplesPerBucket,
        buckets          = buckets
    }
end
local function computeSmpIdx(inSmaplesPerBucket, inBucketNo, inIdxInBucket)
    return (inBucketNo * inSmaplesPerBucket) + inIdxInBucket
end
local function toStringBuckets(inComputedBucketLayout)
    local computedBuckets = inComputedBucketLayout.buckets
    local str = "BUCKETS: "..#computedBuckets.."\n"
    for i = 1, #computedBuckets do
        str = str .. "no:"..padTo3(computedBuckets[i].bNo).."; start:"..padTo5(computedBuckets[i].start).."; last:"..padTo5(computedBuckets[i].last).."\n"
    end
    return str
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
    --print("startBucketNo: ".. startBucketNo.."; endBucketNo: "..endBucketNo.."; num buckets: "..numberOfBuckets)
    --print("Intermediat Buckets, bucketNoIdx: "..(bucketNoIdx+1).."; endBucketNo: "..endBucketNo)
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
    local test = computeBuckets(20000,12)
    print(toStringBuckets(test))
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
local PATH_BUCKETS_PER_BEAT = 4
local GLOBAL_JUCE_PATHS = { {}, {}, {}, {} }
local function finishBucket(inReceivedClientID, inStartPositionOfLastRead, inEndPositionOfLastRead, inNumberOfNewSamples)

    local samplesPerRMSBucket = BUFFERS.SAMPLES_PER_BEAT / PATH_BUCKETS_PER_BEAT
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

    local GLOB_BUF = BUFFERS.GLOBAL_SAMPLE_BUFFER[inReceivedClientID]
    local trafoScaleX = 1600 / BUFFERS.GLOBAL_SIZE
    for dirtyBucketsIdx = startBucket, endBucket do
        local bucketSampleStartIdx = floor((dirtyBucketsIdx * samplesPerRMSBucket) % BUFFERS.GLOBAL_SIZE)
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
        local transform = juce.AffineTransform():scaled(trafoScaleX,300)
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
local RMS = {
    RMS_BUCKETS_PER_BEAT = 4,
    GLOBAL_SAMPLE_SQUARES = { },
    GLOBAL_RMS = { },
}
function RMS:finishRMS(inReceivedClientID, inStartPositionOfLastRead, inEndPositionOfLastRead)
    local GLOB_BUF_1 = BUFFERS.GLOBAL_SAMPLE_BUFFER[1]
    local GLOB_BUF_2 = BUFFERS.GLOBAL_SAMPLE_BUFFER[2]
    local GLOB_BUF_3 = BUFFERS.GLOBAL_SAMPLE_BUFFER[3]
    local GLOB_BUF_4 = BUFFERS.GLOBAL_SAMPLE_BUFFER[4]
    -- square the new samples
    for i = inStartPositionOfLastRead+1,inEndPositionOfLastRead do
        local squareIt = GLOB_BUF_1[i] + GLOB_BUF_2[i] + GLOB_BUF_3[i] + GLOB_BUF_4[i]
        self.GLOBAL_SAMPLE_SQUARES[i] = squareIt * squareIt
    end
    --
    local bucketLayout = computeBuckets(BUFFERS.SAMPLES_PER_BEAT, self.RMS_BUCKETS_PER_BEAT)
    local affectedBuckets = getAffectedBuckets(bucketLayout, inStartPositionOfLastRead, inEndPositionOfLastRead)
    for i = 1,#affectedBuckets do
        local affectedBucketNo =  affectedBuckets[i]
        local startSampleIdx = bucketLayout.buckets[affectedBucketNo].start
        local lastSampleIdx  = bucketLayout.buckets[affectedBucketNo].last
        local numberOfSamplesInBucket = lastSampleIdx - startSampleIdx + 1
        local tempRMS = 0
        for smpIdx = startSampleIdx, lastSampleIdx do
            local val = RMS.GLOBAL_SAMPLE_SQUARES[smpIdx]
            if val == nil then val = 0 end
            tempRMS = tempRMS + val
        end
        self.GLOBAL_RMS[affectedBucketNo] = sqrt(tempRMS / numberOfSamplesInBucket)
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
        local receivedIterator  = stringTokenizer(received,";")
        local receivedClientID  = tonumber(receivedIterator())
        local receivedPpq       = tonumber(receivedIterator())
        local receivedNumPoints = tonumber(receivedIterator())
        --
        -- just a simple cached / dereferenced variable in order to speed things up in the loop below
        local globalBufferOfClientid = BUFFERS.GLOBAL_SAMPLE_BUFFER[receivedClientID]
        --
        -- compute the "Positions" here.
        local moduloPPQ = receivedPpq % BUFFERS.NUM_BEATS
        local moduloPosition = ceil(moduloPPQ*BUFFERS.SAMPLES_PER_BEAT)
        --
        local idxToGlobalBufferOfClient = moduloPosition
        if(idxToGlobalBufferOfClient==0) then
            print("idxToGlobalBufferOfClient: 0")
        end

        print("READ: clt:"..receivedClientID.."; ppq:"..receivedPpq.."; moduloPPQ: "..moduloPPQ.."; moduloPos: "..moduloPosition)
        --
        -- NOTE: Now here we use the while loop... with a naive for a in iterator
        -- continue using the iterator 'receivedIterator' we would get NIL values in the array!
        local actualReceivedPoints = 0
        local lastInsertIdx = idxToGlobalBufferOfClient
        print(idxToGlobalBufferOfClient)
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
            idxToGlobalBufferOfClient = ceil((idxToGlobalBufferOfClient + 1) % BUFFERS.GLOBAL_SIZE)
            -- if(idxToGlobalBufferOfClient > GLOBAL_SIZE) then
            --     print("ALARM: GLOBAL_SIZE:"..GLOBAL_SIZE
            --     .."; IDX: "..idxToGlobalBufferOfClient
            --     .."; mPPQ: "..moduloPPQ
            --     .."; mPos: "..moduloPosition.."; delta: "..(GLOBAL_SIZE-moduloPosition)
            --     .."; table: "..tostring(globalBufferOfClientid)
            --     )
            -- end
        end
        --[[
        if(1==receivedClientID)then
            print("INSERT IDX: start:"..moduloPosition.."; lastInsertIdx: "..lastInsertIdx.."; idxToGlobalBufferOfClient: "..lastInsertIdx.."; actualReceivedPoints: "..actualReceivedPoints)
        end
        --]]
        --
        -- now we think again about quarter beats in order to "redraw" only the quarters we have to
        finishBucket (receivedClientID, moduloPosition, lastInsertIdx, actualReceivedPoints) -- finish path buckets
        RMS:finishRMS(receivedClientID, moduloPosition, lastInsertIdx, actualReceivedPoints) -- finish rms buckets
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


-- ================================================
--
-- MAIN LOOP
--
-- ================================================
function plugin.processBlock(samples, smax, midiBuffer)
    local pluginPosition = plugin.getCurrentPosition()
    GLOBALS:updateDAWGlobals(samples, smax+1, midiBuffer, pluginPosition)
    --
    -- print("before select")
    local selected = socket.select(receivers:getSelectings(), nil, 0)
    -- print("after select: " .. #selected)
    for i = 1, #selected do
        selected[i]:handle(receivers, senders)
    end
    GLOBALS:finishRun(smax)
    if (GLOBALS.runs % 2 == 0) then
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

function fAndP5(inNum)
    return padTo5(floor(inNum))
end
--
-- PAINT IT
--
function gui.paint(g)
    local bounds = g:getClipBounds()
    if not g:isClipEmpty() then
        --print("Clip: x:"..bounds.x.."; y:"..bounds.y.."; w:"..bounds.w.."; h:"..bounds.h)
    end
	--g:setColour(BLACK)
    --g:fillAll()
    g:addTransform(GUI_TRANSLATE_TRAFO)
    --
    local trafoScaleX = 1600 / BUFFERS.GLOBAL_SIZE
    local bucketDeltaX = (BUFFERS.SAMPLES_PER_BEAT / PATH_BUCKETS_PER_BEAT) * trafoScaleX
    --
    --
    --samples
    local paintProtocol       = "PAINT "
    local boundingBoxProtocol = "BBOX  "
    local atLeastOneWasDirty = false
    for clientIdx=1,3 do
        --g:setColour(COLS[j])
        local pathsOfClientDeref = GLOBAL_JUCE_PATHS[clientIdx]
        for bucketPathIdx = 1,PATH_BUCKETS_PER_BEAT do
            local singlePathOfBucket = pathsOfClientDeref[bucketPathIdx]
            if nil ~= singlePathOfBucket then
                local dirty = singlePathOfBucket["dirty"]
                if dirty then
                    atLeastOneWasDirty = true
                    -- first clean stuff here
                    g:setColour(BLACK)
                    local xMin = floor(bucketDeltaX*(bucketPathIdx-1))
                    g:fillRect(xMin,gridYMin, ceil(bucketDeltaX),400)
                    paintProtocol = paintProtocol .."; wipe: xmin:"..padTo5(xMin).."; xmax: "..padTo5(xMin+bucketDeltaX).."                   "
                    -- theres one path dirty in this bucket then re-draw all paths of the same bucket as well
                    for clientIdx_INNER = 1, 3 do
                        local singlePathOfBucket_INNER = GLOBAL_JUCE_PATHS[clientIdx_INNER][bucketPathIdx]
                        if nil ~= singlePathOfBucket_INNER then
                            local thePath = singlePathOfBucket_INNER["path"]
                            --g:setColour(COLS[clientIdx_INNER])
                            --g:strokePath(thePath)
                            local boundingBox = thePath:getBounds()
                            boundingBoxProtocol = boundingBoxProtocol .. "; box : xmin:"..fAndP5(boundingBox.x).."; ymin:"..fAndP5(boundingBox.y).."; w:"..fAndP5(boundingBox.w).."; h:"..fAndP5(boundingBox.h)
                            singlePathOfBucket_INNER["dirty"] = false
                        end
                    end
                end
            end
        end
    end
    if atLeastOneWasDirty then
        print(paintProtocol) 
        print(boundingBoxProtocol)
    end
    --
    --
    --grid
    local gridDeltaX = (BUFFERS.SAMPLES_PER_BEAT / 4.0) * trafoScaleX
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
    local sectionLen = BUFFERS.SAMPLES_PER_BEAT / RMS.RMS_BUCKETS_PER_BEAT
    local width = sectionLen * (1600/BUFFERS.GLOBAL_SIZE)
    local meansPath = juce.Path ()
    local rmsDATA = RMS.GLOBAL_RMS
    for i = 1,#rmsDATA do
        local x = (i-1)*width
        local y = rmsDATA[i] * 800
        meansPath:startNewSubPath(x,y)
        meansPath:lineTo(x+width,y)
    end
    --meansPath:applyTransform(GUI_TRANSLATE_TRAFO)
    g:strokePath(meansPath)
    --
    --finally draw image
    --g:drawImageAt(imageForDisplay, 100, 100)
end