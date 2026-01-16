require("include/protoplug")
require("table.new")
--
-- locals
local ceil = math.ceil
local floor = math.floor
local sqrt = math.sqrt
local tostring = tostring
local s_len = string.len

--Welcome to Lua Protoplug effect (version 1.4.0)
--package.path=package.path .. ";C:/Program Files/Common Files/VST3/Protoplug/ProtoplugFiles/lib/socket/?.dll"
print("###")
-- https://www.gammon.com.au/scripts/doc.php?lua=package.loadlib
package.cpath = package.cpath..";"..protoplug_dir.."/lib/?.dll"
package.path  = package.path.. ";"..protoplug_dir.."/include/?.lua"
--
-- additional requires
local base64 = require("based/64/rfc")
local base64_decode = base64.decode
--
local mp = require("CBOR")
mp.set_float'double'
mp.set_array'without_hole'
mp.set_string'text_string'
local mp_decode = mp.decode
--
local vector_ffi = script.ffiLoad(protoplug_dir.."/lib/vector_simde_avx2.dll")
local vector_add = require("vector_simd")
--
local socket = require("socket")

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
local nl = string.char(10) -- newline
local function serialize_list (tabl, indent)
    indent = indent and (indent.."  ") or ""
    local str = ''
    str = str .. indent.."{"..nl
    for key, value in pairs (tabl) do
        local pr = (type(key)=="string") and ('["'..key..'"]=') or ""
        if type (value) == "table" then
            str = str..indent..pr..serialize_list (value, indent)
        elseif type (value) == "string" then
            str = str..indent..pr..'"'..tostring(value)..'",'..nl
        else
            str = str..indent..pr..tostring(value)..','..nl
        end
    end
    str = str .. indent.."},"..nl
    return str
end
--
local LOG_L = {
	TRACE=4,
    DEBUG=3,
	FINE=2,
	INFO=1
}
local LOG = {
	SET_LEVEL=LOG_L.FINE
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
            str = value
        else
            str = tostring(value)
        end
		res = res .. str
	end
	print(res)
end
function LOG:forLevel(level)
	if level <= self.SET_LEVEL then
        return function(...)
            LOG:log(level,...)
        end
    else
        return function() end
    end
end
function LOG:setupLoggers()
    LOG.trace=LOG:forLevel(LOG_L.TRACE)
    LOG.debug=LOG:forLevel(LOG_L.DEBUG)
    LOG.fine=LOG:forLevel(LOG_L.FINE)
    LOG.info=LOG:forLevel(LOG_L.INFO)
end
LOG:setupLoggers()
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
    local pad = s_len(str)
    if pad >= 2 then return str end
    return PADDINGS[pad+4] .. str
end
function padTo3(inNum)
    local str = tostring(inNum)
    local pad = s_len(str)
    if pad >= 3 then return str end
    return PADDINGS[pad+3] .. str
end
function padTo4(inNum)
    local str = tostring(inNum)
    local pad = s_len(str)
    if pad >= 4 then return str end
    return PADDINGS[pad+2] .. str
end
function padTo5(inNum)
    local str = tostring(inNum)
    local pad = s_len(str)
    if pad >= 5 then return str end
    return PADDINGS[pad+1] .. str
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
	LOG.debug("EventSource:addEventListener: self.eventListeners: ",listeners)
	return inEventListener
end
function EventSource:removeEventListener(inEventListener)
	local listeners = self.eventListeners
	local size = #listeners
	array_remove(listeners, function(t,i) return t[i]~= inEventListener end)
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
--
--
--[[ local jitprof = require("jit.p")
--local profile = require("jit.profile")

local function profileCB(inThread,inSamples,inVMState)
    print("PROFILE.CB: "..tostring(inThread).."; "..tostring(inSamples).."; "..tostring(inVMState))
end
local function profileActivate(inEvent)
    print("PROFILE.1: "..tostring(inEvent))
    if nil == inEvent then
        print("PROFILE.3"..debug.traceback())
    end
    if "IS-PLAYING" == inEvent.type then
        print("PROFILE.2: ".. tostring(profile).." ; "..tostring(inEvent))
        if inEvent.newValue then
            jitprof.start("i2000", "C:/temp/jitprof.log")
            --profile.start("f,i2000", profileCB)
        else
            jitprof.stop()
            --profile.stop()
        end 
    end
end
GLOBALS:addEventListener( function(inEvent) profileActivate(inEvent) end)
 ]]
--======================================================================================================================
--
-- Specific Global Data for this plugin
-- Must be refactored because it is to some extent a copy of the "other" Globals
--
local BUFFERS = {
    GLOBAL_NUM_OF_CLIENTS = 4,
    GLOBAL_SAMPLE_BUFFER = {}, -- takes up to n "ringbuffers" which receive samples form incoming clients
    GLOBAL_SIZE=0,             -- overall size of a Buffer to receive samples, i.e. it may contain samples worth 2 fullbeats
    NUM_BEATS = 1,
    SAMPLE_RATE = 0,
    BPM = 0,
    MILLISECONDS_PER_BEAT = 0,
    SAMPLES_PER_MILLISECOND = 0,
    SAMPLES_PER_BEAT = 0,
}
-- do a little dirty inheritance here, as GLOBALS is not really a class but just a global table where we want to add the event stuff.
setmetatable(BUFFERS, { __index= EventSource:new() })
--
--
function BUFFERS:byNumBeats(inCount)
    return self.NUM_BEATS * inCount
end
function BUFFERS:getBufferForClient(inClientNo)
    return self.GLOBAL_SAMPLE_BUFFER[inClientNo]
end
function BUFFERS:getBufferForClientArray(inClientNo)
    return self.GLOBAL_SAMPLE_BUFFER[inClientNo]()
end
function BUFFERS:initBuffers(inNumBeats, inSamplesPerBeat)
    local totalNumSamples = inNumBeats * inSamplesPerBeat
    local bufferProtocol = "BUFFER Protocol"
    --
    -- do a "prepare and swap", i.e. preparing the new tables,initialize them and then swap them in just one line.
    local temp = {}
    local roundedBufferSize = ceil(totalNumSamples)
    for j=1,self.GLOBAL_NUM_OF_CLIENTS do
        -- local tempj = vec.new(totalNumSamples)
        local tempj, simdBufferSize =  vector_add.allocate_aligned_memory(roundedBufferSize)
        for i = 0,totalNumSamples-1 do
            tempj[i] = 0.0
        end
        if roundedBufferSize ~= simdBufferSize then
            bufferProtocol = bufferProtocol.."\nSIMD-LEN j:"..j.."; rounded: "..roundedBufferSize.."; simd: "..simdBufferSize        
        end
        temp[j]=tempj
    end
    self.GLOBAL_SAMPLE_BUFFER, self.GLOBAL_SIZE = temp, totalNumSamples
    bufferProtocol = bufferProtocol.."\nBuffer size: "..self.GLOBAL_SIZE.."; Buffers: "..#self.GLOBAL_SAMPLE_BUFFER
    for j=1,self.GLOBAL_NUM_OF_CLIENTS do
        local count = 0;
        for i = 0,totalNumSamples-1 do
            if nil == self.GLOBAL_SAMPLE_BUFFER[j].ptr[i] then
                count = count + 1
            end
        end
        bufferProtocol = bufferProtocol .. "\nBUFFER: "..j.."; #nils: "..count.."; table: "
                    ..tostring(self.GLOBAL_SAMPLE_BUFFER[j]).."; length: "..self.GLOBAL_SIZE
    end
    LOG.trace(bufferProtocol)
    print(bufferProtocol)
    -- pack new Values
	local newValues= { numOfBeats=self.NUM_BEATS, 
                       samplesPerBeat=self.SAMPLES_PER_BEAT,
                       totalSampleBufferSize=self.GLOBAL_SIZE,
                       sampleBuffers = self.GLOBAL_SAMPLE_BUFFER }
    self:fireEvent({ type= "BUFFERS-CHANGED",
				     source=self,
				     newValues=newValues
			      })
end
--
-- Listen to changes of Global settings
--
function BUFFERS:listenToGlobalsChange(inEvent)
	--print("GLOBAL Listener: ".. string.format("%s",self))
	if "BPM" == inEvent.type then
		-- BPM has changed that means, that central values like SAMPLES_PER_BEAT have to be computed newly
		local eventNewValues = inEvent.newValues
		-- cache event values
        local newBPM = eventNewValues.bpm
		if self.BPM ~= newBPM then
            self.BPM=newBPM
            self.MILLISECONDS_PER_BEAT = 60000 / self.BPM
            self.SAMPLES_PER_BEAT = self.MILLISECONDS_PER_BEAT * self.SAMPLES_PER_MILLISECOND
            self:initBuffers(self.NUM_BEATS, self.SAMPLES_PER_BEAT)
            LOG.trace("SMP: ", self.SAMPLES_PER_BEAT)
        end
	elseif "SAMPLE-RATE" == inEvent.type then
        local newSampleRate = inEvent.new
        self.SAMPLE_RATE = newSampleRate
        self.SAMPLES_PER_MILLISECOND = self.SAMPLE_RATE / 1000
    end
    LOG.trace("BPM: ",self.BPM,"; msec/beat: ",self.MILLISECONDS_PER_BEAT,
                "; samp/msec: ",self.SAMPLES_PER_MILLISECOND,"; samp/beat: ",self.SAMPLES_PER_BEAT,"; evt.type: ",inEvent.type)
end
GLOBALS:addEventListener( function(inEvent) BUFFERS:listenToGlobalsChange(inEvent) end)
--===============================================================================================
--
-- BUCKET BASE FUNCTIONALITY
--
-- returns a BucketLayout structure with maxSamples, samplesPerBucket and array with buckets, ie #, start, last, len each
--===============================================================================================
local function computeBuckets(inMaxSamples, inNumberOfBuckets)
    local samplesPerBucket = inMaxSamples / inNumberOfBuckets
    local buckets = {}
    for idx = 0, inNumberOfBuckets-1 do
        local bucketNo = idx -- zero based; from 0 to inBuckets (excl)
        -- for instance; samplesPerBucket = 2000
        -- then we have buckets [0*2000+1, 0*2000+1+2000-1], [1*2000+1, 1*2000+1+2000-1], [2*2000+1,2*2000+1+2000-1]
        -- that is [1, 2000], [2001,4000], [4001, 6000], ...
        local startIdx = (idx * samplesPerBucket) + 1   -- one based array index within the bucket
        local endIdx   = startIdx + samplesPerBucket -1 -- including end idx
        if(idx==inNumberOfBuckets-1) then
            endIdx = inMaxSamples
        end
        -- we add 0-based bucketNo value here for convenience. as lua works 1-based it is nevertheless often needed to start counting at 0
        -- for instance when computing a gui x-offset for the 1st bucket, which should be 0 * x-size-of-bucket
        buckets[bucketNo+1] = {
            bNo   = bucketNo,
            start = floor(startIdx),
            last  = floor(endIdx),
            len   = floor(endIdx) - floor(startIdx) + 1
        }
    end
    return {
            maxSamples       = inMaxSamples,
            samplesPerBucket = samplesPerBucket,
            buckets          = buckets
        }
end
--
-- creates a string representation of a given Bucketlayout for debugging purpose
--
local function toStringBuckets(inComputedBucketLayout)
    local computedBuckets = inComputedBucketLayout.buckets
    local str = "BUCKETS: "..#computedBuckets.."\n"
    for i = 1, #computedBuckets do
        str = str .. "idx:"..padTo2(i)..": no:"..padTo3(computedBuckets[i].bNo).."; start:"..padTo5(computedBuckets[i].start).."; last:"..padTo5(computedBuckets[i].last).."\n"
    end
    return str
end
--
-- BucketLayout class
--
local BucketLayout = {}
function BucketLayout:new(inMaxSamples, inNumberOfBuckets)
	local o = computeBuckets(inMaxSamples, inNumberOfBuckets)
	setmetatable(o, self)
	self.__index = self
	return o
end
function BucketLayout:tostring()
    return toStringBuckets(self)
end
--
-- Computes a list of BucketNumbers which are affected by a sample fill affecting the buffer indexes [inLastUpdateStartSampleIdx, inLastUpdateEndSampleIdx]
-- returns a 1-based list of indexes of affected buckets in [1, #inBucketsLayout.buckets]
--
function BucketLayout:getAffectedBuckets(inLastUpdateStartSampleIdx, inLastUpdateEndSampleIdx)
    local samplesPerBucket  = self.samplesPerBucket
    local buckets           = self.buckets
    local numberOfBuckets   = #buckets
    local startBucketNo     = floor(inLastUpdateStartSampleIdx / samplesPerBucket) + 1 -- floor will give us zero, max number of buckets - 1, therefore we  do + 1
    local endBucketNo       = floor(inLastUpdateEndSampleIdx   / samplesPerBucket) + 1 -- floor will give us zero, max number of buckets - 1, therefore we  do + 1
    local startBucketEndIdx = buckets[startBucketNo].last
    local endBucketEndIdx   = buckets[endBucketNo].last -- about "endBucket": keep in mind that the endBucket most probabaly has not been finished completely, therefore we have to check this
    --
    -- now find affected bucketNumbers
    -- is startBucket affected and only startBucket?
    if startBucketNo == endBucketNo then
        if inLastUpdateEndSampleIdx == startBucketEndIdx then
            -- the startbucket has been filled up right to it's own end, but we don't have anything more
            return { startBucketNo }
        else
            -- the starBucket has not been filled up to the end ... nothing todo right now.
            return {}
        end
    end
    -- now here we are in the case where more than one bucket is affected, say it's like buckets 3,4,5,6 have been affected
    -- add the first bucket to the list in any case, i.e. 3
    local resultBucketNumberList = { startBucketNo }
    -- now all buckets inbetween first and last but excluding the last one should be added, this would add 4 and 5
    local bucketNoIdx = (startBucketNo % numberOfBuckets) -- will be between 0 and numberOfBuckets-1
    -- note: we do the + 1 here because we want to exclude the end bucket. it needs special treatment, see block below
    while bucketNoIdx+1 ~= endBucketNo do
        resultBucketNumberList[#resultBucketNumberList+1] = bucketNoIdx+1
        bucketNoIdx = ((bucketNoIdx+1) % numberOfBuckets)
    end
    --
    -- now look at the last bucket. only if it has been filled up completely, it goes into the result.
    -- That means we add bucket 6 only if the bucket 6 was filled completely
    if inLastUpdateEndSampleIdx == endBucketEndIdx then
        resultBucketNumberList[#resultBucketNumberList+1] = endBucketNo
    end
    return resultBucketNumberList
end
--
-- Number of buckets in this bucketlayouts
--
function BucketLayout:getNumberOfBuckets(inBucketNo)
    return #self.buckets
end
--
-- Returns number of Smaples in each bucket
--
function BucketLayout:getBucketSizeInSamples()
    return self.samplesPerBucket
end
--
-- get bucket 
--
function BucketLayout:getBucket(inBucketNo)
    return self.buckets[inBucketNo]
end
--
-- returns length of bucket
--
function BucketLayout:getLenOfBucket(inBucketNo)
    return self.buckets[inBucketNo].len
end
--
-- returns the "range" of the bucket given by inBucketNo, i.e. bucket.start, bucket.last, bucket.len
--
function BucketLayout:getIdxRangeOfBucket(inBucketNo)
    -- todo add index oob check
    local bucket = self.buckets[inBucketNo]
    return bucket.start, bucket.last, bucket.len
end
--
local function testBuckets()
    local test = BucketLayout:new(20000,12)
    print(toStringBuckets(test))
    print("TEST")
    local idxs = test:getAffectedBuckets(14880, 15839)
    for i=1,#idxs do
        print("affected: idx:"..idxs[i])
    end
    print("===")
    test = BucketLayout:new(20000, 12)
    print("TEST, 12, 1")
    local idxs = test:getAffectedBuckets(20000 - 12, 3000)
    for i=1,#idxs do
        print("affected: idx:"..idxs[i])
    end
    print("TEST, 12,1,2")
    idxs = test:getAffectedBuckets(20000 - 12, 3333)
    for i=1,#idxs do
        print("affected: idx:"..idxs[i])
    end
    print("TEST,2")
    idxs = test:getAffectedBuckets(1667, 3333)
    for i=1,#idxs do
        print("affected: idx:"..idxs[i])
    end
    print("TEST,1,2")
    idxs = test:getAffectedBuckets(1666, 3333)
    for i=1,#idxs do
        print("affected: idx:"..idxs[i])
    end
    print("TEST,1,2")
    idxs = test:getAffectedBuckets(1666, 3334)
    for i=1,#idxs do
        print("affected: idx:"..idxs[i])
    end
    print("TEST,1")
    idxs = test:getAffectedBuckets(0, 1667)
    for i=1,#idxs do
        print("affected: idx:"..idxs[i])
    end
end
testBuckets()

--
--
--
local GUI_COMPONENT = gui:getComponent()
local function repaintIt()
	if GUI_COMPONENT then
		GUI_COMPONENT:repaint()
	end
end
--
--
local SAMPLE_VIEW_PORT_WIDTH = 1000
--
--
--======================================================================================================================
--
-- PATHS COMPUTATION
--
--
local CLIENT_PATHS = {
    PATH_SCALE_TRAFO = nil, -- scales the paths from y=[-1,1] --> [-300, 300] and x according width of viewport in relation to total samplesize
    PATH_BUCKETS_NO = 8,
    GLOBAL_JUCE_PATHS = { {}, {}, {}, {} },
    BUCKET_LAYOUT = nil,
    DIRTY_LIST = {},
    CLEAN_RECTS = {}
}
--
-- Listen to Changes to the Global Buffers
--
function CLIENT_PATHS:getDirtyList()
    return self.DIRTY_LIST
end
function CLIENT_PATHS:resetDirtyList()
    for bucket = 1,self.PATH_BUCKETS_NO do
        self.DIRTY_LIST[bucket] = false
    end
end
function CLIENT_PATHS:setBucketDirty(inBucketNo)
    self.DIRTY_LIST[inBucketNo] = true
end
function CLIENT_PATHS:getDirtyBucketIdxs()
    local maxBuckets = self.PATH_BUCKETS_NO
    local list = self.DIRTY_LIST
    local result = {}
    for bucketIdx = 1,maxBuckets do
        if list[bucketIdx] then
            result[#result+1] = bucketIdx
        end
    end
    return result
end
function CLIENT_PATHS:getDirtyBuckets()
    local maxBuckets = self.PATH_BUCKETS_NO
    local bucketLayout = self.BUCKET_LAYOUT
    local list = self.DIRTY_LIST
    local result = {}
    for bucketIdx = 1,maxBuckets do
        if list[bucketIdx] then
            result[#result+1] = bucketLayout:getBucket(bucketIdx)
        end
    end
    return result
end
function CLIENT_PATHS:getPathForBucket(inClientNo, inBucketNo)
    return self.GLOBAL_JUCE_PATHS[inClientNo][inBucketNo]
end
function CLIENT_PATHS:initCleanRectangles()
    self.CLEAN_RECTS = {}
    local bucketLayout = self.BUCKET_LAYOUT
    print("CLEAN RECT CREATE: "..tostring(bucketLayout))
    for bucket = 1,bucketLayout:getNumberOfBuckets() do
        local startSampleIdx,lastSampleIdx, len = bucketLayout:getIdxRangeOfBucket(bucket)
        local tempPath = juce.Path()
        tempPath:addRectangle(startSampleIdx, -1, len, 2)
        tempPath:applyTransform(self.PATH_SCALE_TRAFO)
        self.CLEAN_RECTS[#self.CLEAN_RECTS+1] = tempPath 
        print("CLEAN RECT CREATE: "..bucket.."; "..tostring(tempPath))
    end
end
function CLIENT_PATHS:getCleanUpPath(inBucketNo)
    local result = self.CLEAN_RECTS[inBucketNo]
    --print("CLEAN RECT RESULTS: "..inBucketNo.."; "..tostring(result))
    return result
end
function CLIENT_PATHS:getDirtySamplePathsOfClient(inClientID)
    local result = {}
    local dirtyBucketIdxs = CLIENT_PATHS:getDirtyBucketIdxs()
    for dirtyBucketIdxsIdx = 1,#dirtyBucketIdxs do
        local path = CLIENT_PATHS:getPathForBucket(inClientID, dirtyBucketIdxs[dirtyBucketIdxsIdx])
        result[#result+1] = path
    end
    return result
end
function CLIENT_PATHS:getCleanUpPaths()
    local result = {}
    local dirtyBucketIdxs = CLIENT_PATHS:getDirtyBucketIdxs()
    for dirtyBucketIdxsIdx = 1,#dirtyBucketIdxs do
        local cleanPath = CLIENT_PATHS:getCleanUpPath(dirtyBucketIdxs[dirtyBucketIdxsIdx])
        result[#result+1] = cleanPath
    end
    return result
end
function CLIENT_PATHS:listenToBufferChanges(inEvent)
    print("CLIENT_PATHS: EVENT New BucketLayout: "..inEvent.newValues.totalSampleBufferSize)
    --
    -- inits data that is required for computation of paths
    local totalSampleBufferSize = inEvent.newValues.totalSampleBufferSize
    self.BUCKET_LAYOUT = BucketLayout:new(totalSampleBufferSize, self.PATH_BUCKETS_NO)
    print(toStringBuckets(self.BUCKET_LAYOUT))
    --
    LOG.debug("INIT Client Paths")
    for buckets = 1,self.PATH_BUCKETS_NO do
        for clients = 1,4 do
            self.GLOBAL_JUCE_PATHS[clients][buckets] = juce.Path()
            LOG.debug("PATH: "..clients.."; "..buckets.."; "..tostring(self.GLOBAL_JUCE_PATHS[clients][buckets]))
        end
    end
    --
    local trafoScaleX = SAMPLE_VIEW_PORT_WIDTH / totalSampleBufferSize
    self.PATH_SCALE_TRAFO = juce.AffineTransform():scaled(trafoScaleX,150)
    --
    self:resetDirtyList()
    --
    self:initCleanRectangles()
end
BUFFERS:addEventListener( function(inEvent) CLIENT_PATHS:listenToBufferChanges(inEvent) end)
--
-- Listen to Changes to the Global Buffers
--
function CLIENT_PATHS:finishSamplePaths(inReceivedClientID, inStartPositionOfLastUpdate, inEndPositionOfLastUpdate, inNumberOfNewSamples)
    local bucketLayout         = self.BUCKET_LAYOUT
    local affectedBuckets      = bucketLayout:getAffectedBuckets(inStartPositionOfLastUpdate, inEndPositionOfLastUpdate)
    local GLOBAL_BUF_OF_CLIENT = BUFFERS:getBufferForClientArray(inReceivedClientID)
    for i = 1,#affectedBuckets do
        -- getAffectedBuckets might return a list of arbitrarily sorted INDEXes of buckets.
        -- therefore we have to get the real index of a bucket first
        local affectedBucketNo = affectedBuckets[i]
        local tempPath         = self:getPathForBucket(inReceivedClientID, affectedBucketNo)
        local startSampleIdx,lastSampleIdx = bucketLayout:getIdxRangeOfBucket(affectedBucketNo)
        --if tempPath == nil then
        --    LOG.debug("PATH: cId: "..inReceivedClientID.."; bucket: "..affectedBucketNo.."; "..tostring(tempPath))
        --end
        tempPath:clear()
        for smpIdx = startSampleIdx, lastSampleIdx,8 do
            local yVal = GLOBAL_BUF_OF_CLIENT[smpIdx-1] -- 0-based cdata
            if startSampleIdx == smpIdx then
                tempPath:startNewSubPath(smpIdx,yVal)
            else
                tempPath:lineTo(smpIdx, yVal)
            end
        end
        tempPath:applyTransform(self.PATH_SCALE_TRAFO)
        self:setBucketDirty(affectedBucketNo)
    end
end
--======================================================================================================================
--
-- RMS COMPUTATION
--
--
local RMS = {
    RMS_BUCKETS_PER_BEAT = 16,
    GLOBAL_SAMPLE_SQUARES = { },
    GLOBAL_RMS = { },
    BUCKET_LAYOUT = nil,
    GLOBAL_TEMP = nil
}
--
-- Listen to Changes to the Global Buffers
--
function RMS:listenToBufferChanges(inEvent)
    print("RMS: EVENT New BucketLayout: "..inEvent.newValues.totalSampleBufferSize)
    local totalSampleBufferSize = inEvent.newValues.totalSampleBufferSize
    self.GLOBAL_BUFFER_SIZE     = totalSampleBufferSize
    self.GLOBAL_SAMPLE_SQUARES  = vector_add.allocate_aligned_memory(totalSampleBufferSize)
    self.GLOBAL_TEMP_1          = vector_add.allocate_aligned_memory(totalSampleBufferSize)
    self.GLOBAL_TEMP_2          = vector_add.allocate_aligned_memory(totalSampleBufferSize)
    self.BUCKET_LAYOUT          = BucketLayout:new(totalSampleBufferSize, self.RMS_BUCKETS_PER_BEAT * BUFFERS.NUM_BEATS)
    --
    self.SQUARED_DIFFERENCE           = vector_add.allocate_aligned_memory(totalSampleBufferSize)
    self.SQUARED_DIFFERENCE_PROJECTED = vector_add.allocate_aligned_memory(totalSampleBufferSize)
    print(self.BUCKET_LAYOUT:tostring())
end
BUFFERS:addEventListener( function(inEvent) RMS:listenToBufferChanges(inEvent) end)

function RMS:getNumberOfBuckets()
    return self.RMS_BUCKETS_PER_BEAT * BUFFERS.NUM_BEATS
end
function RMS:getBucketSizeInSamples()
    return self.BUCKET_LAYOUT:getBucketSizeInSamples()
end

local writeRMSLogSummaries = false

function RMS:finishRMS2( _, inStartPositionOfLastUpdate, inEndPositionOfLastUpdate)
    local GLOB_BUF_1 = BUFFERS:getBufferForClient(1)
    local GLOB_BUF_2 = BUFFERS:getBufferForClient(2)
    local GLOB_BUF_3 = BUFFERS:getBufferForClient(3)
    local GLOB_BUF_4 = BUFFERS:getBufferForClient(4)
    local TEMP_1     = self.GLOBAL_TEMP_1
    local TEMP_2     = self.GLOBAL_TEMP_2
    local GLOB_SQURS = self.SQUARED_DIFFERENCE
    local size       = self.GLOBAL_BUFFER_SIZE
    -- square the new samples
    vector_add.add_vectors_into(GLOB_BUF_1, GLOB_BUF_2, TEMP_1, size)
    vector_add.add_vectors_into(GLOB_BUF_3, GLOB_BUF_4, TEMP_2, size)
    vector_add.add_vectors_into(TEMP_1,     TEMP_2,     TEMP_1, size)
    self.GLOBAL_RMS = vector_add.compute_rms_windowed(TEMP_1, size, self:getBucketSizeInSamples())
    --print("RMS: "..#self.GLOBAL_RMS)
    --
    vector_add.squared_difference_into  (GLOB_BUF_1, GLOB_BUF_2, TEMP_1, size)
    --
    vector_add.compute_abs_diff_sum_into(GLOB_BUF_1, GLOB_BUF_2, TEMP_2, size)
    --
    vector_add.mul_vectors_into(TEMP_1, TEMP_2, GLOB_SQURS, size)
    --
    vector_add.compute_a_plus_bx_into(-100.0,-1600.0,GLOB_SQURS,self.SQUARED_DIFFERENCE_PROJECTED, size)
end
-- ===================================================
--
-- READ HANDLER: Reads Data from TCP/IP Clients
--
-- ===================================================
local SAMPLE_RECEIVER = {
    callbacks = {},
}

function SAMPLE_RECEIVER:addCallback(inCallback)
	local listeners = self.callbacks
	listeners[#listeners+1] = inCallback
	LOG.debug("SAMPLE_RECEIVERurce:addCallback: self.callbacks: ",listeners)
	return inCallback
end
function SAMPLE_RECEIVER:removeCallBack(inCallback)
	local listeners = self.callbacks
	local size = #listeners
	array_remove(listeners, function(t,i) return t[i]~= inCallback end)
	LOG.debug("SAMPLE_RECEIVER:removeCallback: ", listeners)
	return size ~= #listeners
end
function SAMPLE_RECEIVER:fireCallback(inReceivedClientID, inStartIdx, inEndIdx, inNumberOfSamples)
	local listeners = self.callbacks
	local n=#listeners
	for i=1,n do
		listeners[i](inReceivedClientID, inStartIdx, inEndIdx, inNumberOfSamples)
	end
end


local function errorHandlerFct(x)
    print ("err called", x)
    print(debug.traceback())
  end

local RingBufferIdx = {}
function RingBufferIdx:newFromPPQ(inPPQ, inMaxPPQ, inSamplesPerBeat)
    if inPPQ == nil or inMaxPPQ == nil or inPPQ < 0 then
        print(debug.traceback())
        error("IN PPQ oob: "..inPPQ.."; "..inMaxPPQ)
    end
    if inSamplesPerBeat == nil or inSamplesPerBeat <= 0 then
        print(debug.traceback())
        error("IN SamplesPerBeat oob: "..inSamplesPerBeat)
    end

    --given a max ppq and samples per beat compute a max index
    local maxIdx = ceil(inMaxPPQ * inSamplesPerBeat)
    -- compute the "Positions" based on the ppq transfered from the client
    local moduloPPQ = inPPQ % inMaxPPQ -- modulo is 0-based
    local startIdx  = ceil(moduloPPQ * inSamplesPerBeat)
    if startIdx < 1 or startIdx > maxIdx then
        error("startIdx oob: cIdx: "..startIdx)
    end
    --
    local o = {}
    o.ctorVal    = "[PPQ:"..moduloPPQ.."]"
    o.maxIdx     = maxIdx
    o.startIdx   = startIdx
    o.currentIdx = startIdx
    o.distance   = 0
    --
	setmetatable(o, self)
    self.__index = self
    self.__tostring = function(obj)
        return "RingBufferIdx[maxIdx:"..obj.maxIdx.."; ctorVal:"..obj.ctorVal
            .."; interval["..obj.startIdx.."," ..obj.currentIdx.."[; dst:"..obj.distance.."]"
    end
    o:checkLimits()
	return o
end
function RingBufferIdx:checkLimits()
    local cIdx = self.currentIdx
    if cIdx <=0 or cIdx > self.maxIdx then
        error("Limits exceeded: cIdx: "..cIdx)
    end
end
function RingBufferIdx:getIdx()
    return self.currentIdx
end
function RingBufferIdx:getDistance()
    return self.distance
end
function RingBufferIdx:getStartIdx()
    return self.startIdx
end
function RingBufferIdx:getLastExclusiveIdx()
    return self.startIdx
end
function RingBufferIdx:getInterval()
    return self.startIdx, self.currentIdx
end
function RingBufferIdx:getAndInc()
    local cIdx = self.currentIdx
    local nextIdx = cIdx + 1
    if nextIdx > self.maxIdx then
        nextIdx = 1
    end
    self.distance = self.distance+1
    self.currentIdx = nextIdx
    self:checkLimits()
    return cIdx
end

--
-- actually does the reading from warpped socket in inWrappedSocket and returns the decoded data
--
local ACC_TIME = 0
local ACC_CALLS = 0
local function timed(inIdent, inWrappedFct)
    return function(...)
        local start = os.clock()
        local result = inWrappedFct(...)
        local elapsed = os.clock() - start
        ACC_TIME = ACC_TIME + elapsed
        ACC_CALLS = ACC_CALLS + 1
        if(ACC_CALLS % 1000 == 0) then
            print("TIMED: "..inIdent.."; time:"..ACC_TIME.. "; calls:"..ACC_CALLS.."; AVERAGE:"..ACC_TIME/ACC_CALLS)
        end
        return result, elapsed
    end
end

local function _unmarshall(inRawData)
    return mp_decode(base64_decode(inRawData))
    --local statusB64, resultB64 = pcall(base64.decode, inRawData, errHandlerFct)
    --local statusUP, resultUP = pcall(mp.unpack, resultB64, errHandlerFct)
    --if statusUP then return resultUP end
    --
    -- result is now the error
    --LOG.debug(inRawData)
    --LOG.debug("UNMARSHALL ERROR: ",resultB64,"; ", resultUP, "; ",s_len(inRawData))
end
local unmarshall = timed("Marshall", _unmarshall)

local GLOBAL_REQUESTS_FOR_GUI = {}

function readHandler(inWrappedSocket, inReceivers, inSenders)
    local originalSocket = inWrappedSocket:getOriginal()
    --print("READ START: " .. tostring(originalSocket))
    local receivedEncoded, error, partial = originalSocket:receive()
    --
    -- some quick bail outs .. these lines feel a little like ugly cheats
    -- I have added them in a coding session where after a while the decoding of incoming data failed
    if receivedEncoded == nil and error == nil then return end
    if receivedEncoded ~= nil and s_len(receivedEncoded) == 0 then return end
    --
    if error == nil then
        LOG.trace("READ END: ", s_len(receivedEncoded))
        --
        -- decode the structure coming from a client
        -- Format is { cNo=clientNo, cPpq=ppq, size=0, smp=nil }
        local receivedDecoded   = unmarshall(receivedEncoded)
        local receivedClientID  = receivedDecoded.cNo
        local receivedClientPPQ = receivedDecoded.cPpq

        receivedEncoded = nil -- free memory
        --LOG.trace("RECEIVED: ",receivedClientID,"; ppq: ",receivedClientPPQ)
        --
        -- just a simple cached / dereferenced variable in order to speed things up in the loop below
        local GLOBAL_BUF_OF_CLIENT = BUFFERS:getBufferForClientArray(receivedClientID)
        --
        -- compute the "Positions" based on the ppq transfered from the client
        local ringBufferIdx = RingBufferIdx:newFromPPQ(receivedClientPPQ, BUFFERS.NUM_BEATS, BUFFERS.SAMPLES_PER_BEAT)
        if ringBufferIdx:getIdx()-1 < 0 then
            error("OOB < 0")
        end
        --print("READ: clt:"..receivedClientID.."; ppq:"..receivedPpq.."; moduloPPQ: "..moduloPPQ.."; moduloPos: "..moduloPosition)
        --
         -- keep track of Idx and allow for debugging
        local clientSamples  = receivedDecoded.smp -- make the received samples local
        local ceilBufferSize = ceil(BUFFERS.GLOBAL_SIZE)
        local minIdx,maxIdx  = BUFFERS.GLOBAL_SIZE,0 -- just for debugging
        for clientSmpIdx = 1,#clientSamples do
            local currentIdx = ringBufferIdx:getAndInc()
            if currentIdx < minIdx then
                minIdx = currentIdx
            elseif currentIdx > maxIdx then
                maxIdx = currentIdx
            end
            if currentIdx-1 > ceilBufferSize then
                error("OOB > max")
            end
            GLOBAL_BUF_OF_CLIENT[currentIdx-1]=clientSamples[clientSmpIdx] -- 0-based cdata!
        end
        --
        -- now we think again about quarter beats in order to "redraw" only the quarters we have to
        local startIdx, endIdx = ringBufferIdx:getInterval()
        LOG:trace("INSERTS: ",GLOBAL_BUF_OF_CLIENT,"; ",ringBufferIdx,"; start:",startIdx,"; end:",endIdx,"; min:",minIdx,"; max",maxIdx)
        
        local f = timed("SamplePaths", function()
            CLIENT_PATHS:finishSamplePaths(receivedClientID, startIdx, endIdx, ringBufferIdx:getDistance()) -- finish path buckets
            RMS:finishRMS2                (receivedClientID, startIdx, endIdx, ringBufferIdx:getDistance()) -- finish rms buckets
        end)
        GLOBAL_REQUESTS_FOR_GUI[#GLOBAL_REQUESTS_FOR_GUI+1] = f
    else
        print("READ ERROR: " .. tostring(error))
        inReceivers:removeSelecting(inWrappedSocket)
        originalSocket:close()
    end
end

-- ==============================================
--
--  Socket Stuff
--
-- ==============================================

--
-- A Wrapper Class which allows me to add a "Handler" to a Socket which handles stuff when the socket has been "selected"
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
--[[=========================================================================================
--
-- A Base class for sockets that should be used by 'select'
-- Users can register a handler for events on a socket.
--]]
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
function Selectings:getSize()
    return #self.eventListeners
end

local bound = socket.bind("127.0.0.1",8000)
bound:settimeout(0)
print(bound)
print(bound:getfd())

local WrappedBound = WrappedSocket:new(bound,
    function(inWrappedSocket, inReceivers, inSenders)
        local originalSocket = inWrappedSocket:getOriginal()
        print("ACCEPT START: " .. tostring(originalSocket))
        local newClient = originalSocket:accept()
        newClient:setoption("tcp-nodelay",true)
        newClient:settimeout(0)
        local wrappedNewClient = WrappedSocket:new(newClient, readHandler)
        inReceivers:addSelecting(wrappedNewClient)
        print("ACCEPT END: "..tostring(newClient).."; wrapped: "..tostring(wrappedNewClient).."; receivers: "..inReceivers:getSize())
        return wrappedNewClient
    end
)
--
--
-- JUST ADD THE SINGLE accept socket for now
local receivers = Selectings:new()
      receivers:addSelecting(WrappedBound)
local senders = Selectings:new()


--
local function prepareToPlayHandler()
    BUFFERS.SAMPLE_RATE=plugin.getSampleRate()
    print("PREPARE TO PLAY: "..(BUFFERS.SAMPLE_RATE))
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
    local selected = socket.select(receivers:getSelectings(), nil, 0)
    -- print("after select: " .. #selected)
    for i = 1, #selected do
        selected[i]:handle(receivers, senders)
    end
    GLOBALS:finishRun(smax)
    if (GLOBALS.runs % 4 == 0) then
        repaintIt()
    end
end




local alpha = 100
local COL_BACKGRD = juce.Colour(80, 80, 80)
local COL_GRID    = juce.Colour(255, 255, 255)
local COL_RMS     = juce.Colour(255, 160, 0)
local COL_SQDIF   = juce.Colour(200, 0, 255, 128)
local COLS = {
    juce.Colour(255, 0, 50),
    juce.Colour(0, 255, 50),
    juce.Colour(255, 0, 255),
    juce.Colour(255, 255, 0)
}
local GUI_TRANSLATE_TRAFO = juce.AffineTransform():translated(50,200) -- move right and down, (0,0) is tope left.
local GUI_UPDATES = 0
local BLACK = juce.Colour(0, 0, 0)
local gridYMin = -150
local gridYMax =  150

local imageForDisplay = juce.Image (juce.Image.PixelFormat.ARGB, SAMPLE_VIEW_PORT_WIDTH, 300, true)
local gImage = juce.Graphics(imageForDisplay)
-- set the global transform for the Display
gImage:addTransform(juce.AffineTransform():translated(0,gridYMax))
local args = {thickness = 2}

local function fAndP5(inNum)
    return padTo4(floor(inNum))
end
local function formatBoxWH(idx, xmin,ymin,w,h)
    return string.format("(i:%2d xi:%4i yi:%4i xa:%4i ya:%4i)",idx,xmin,ymin,xmin+w,ymin+h)
end
local function formatBoxMX(idx, xmin,ymin,xmax,ymax)
    return string.format("(i:%2d xi:%4i yi:%4i xa:%4i ya:%4i)",idx,xmin,ymin,xmax,ymax)
end
local writeLogSummaries = false
--
-- PAINT IT
--
function gui.paint(g)
    --local bounds = g:getClipBounds()
    --if not g:isClipEmpty() then
        --print("Clip: x:"..bounds.x.."; y:"..bounds.y.."; w:"..bounds.w.."; h:"..bounds.h)
    --end
	--g:setColour(BLACK)
    --g:fillAll()
    --g:addTransform(GUI_TRANSLATE_TRAFO)
    --
    -- SWAP THE REQUESTS WITH PROCESS THREAD
    local Requests = GLOBAL_REQUESTS_FOR_GUI
    GLOBAL_REQUESTS_FOR_GUI = {}
    local lenRequest = #Requests
    for i = 1,lenRequest do
        Requests[i]()
    end
    --
    local trafoScaleX = SAMPLE_VIEW_PORT_WIDTH / BUFFERS.GLOBAL_SIZE
    local bucketDeltaX = (BUFFERS.GLOBAL_SIZE / CLIENT_PATHS.PATH_BUCKETS_NO) * trafoScaleX
    local ceil_bucketDeltaX = ceil(bucketDeltaX)
    --
    --
    --samples
    do
        local paintLogSummary       = "PAINT "
        local boundingBoxLogSummary = "BBOX  "
        local atLeastOneWasDirty = false
        local cleanUpPaths = CLIENT_PATHS:getCleanUpPaths()
        gImage:setColour(COL_BACKGRD)
        --1st Pass: clean area where we are going to update paths
        --print("====")
        for cleanUp = 1,#cleanUpPaths do
            gImage:fillPath(cleanUpPaths[cleanUp])
        end
        --2nd Pass: draw all paths, tirst those of client 1, then 2, ...
        for clientIdx=1,3 do
            gImage:setColour(COLS[clientIdx])
            local collectedPath = juce.Path()
            local dirtyPathsOfClient = CLIENT_PATHS:getDirtySamplePathsOfClient(clientIdx)
            for dirtyPathIdx = 1,#dirtyPathsOfClient do
                collectedPath:addPath(dirtyPathsOfClient[dirtyPathIdx])
            end
            gImage:strokePath(collectedPath)
        end
        CLIENT_PATHS:resetDirtyList()
    end
    --
    --
    --grid
    do
        local gridDeltaX = (BUFFERS.SAMPLES_PER_BEAT / 4.0) * trafoScaleX
        gImage:setColour(COL_GRID)
        for i = 1,(4*BUFFERS.NUM_BEATS)-1 do
            local gridX = gridDeltaX * i
            gImage:drawLine(gridX,gridYMin,gridX,gridYMax)
        end
        gridPath = nil
    end
    --
    --
    --mean
    do
        gImage:setColour(COL_RMS)
        local sectionLenInSamples = RMS:getBucketSizeInSamples()
        local width = sectionLenInSamples * trafoScaleX
        local rmsDATA = RMS.GLOBAL_RMS
        local x = 0
        for i = 1,#rmsDATA do
            local y = rmsDATA[i] * 400
            gImage:drawLine(x,y,x+width,y)
            x = x + width
        end
    end
    --
    -- squared difference
    if GUI_UPDATES % 4 == 0 then
        gImage:setColour(COL_SQDIF)
        local squaredDiff = RMS.SQUARED_DIFFERENCE_PROJECTED()
        local squaredDiffPath = juce.Path ()
        squaredDiffPath:startNewSubPath(0,0)
        for i = 0,BUFFERS.GLOBAL_SIZE-1,32 do
            local x = i * trafoScaleX
            squaredDiffPath:lineTo(x,squaredDiff[i])
        end
        gImage:strokePath(squaredDiffPath)
    end

    --finally draw image
    g:drawImageAt(imageForDisplay, 20, 20)
    GUI_UPDATES = GUI_UPDATES + 1
end