--[[
name: ArpKarate
description: A sample accurate arp and something plugin
author: ] Peter:H [
--]]
require "include/protoplug"

--
--
--  Local Fct Pointer and Utilities
--
--
local m_2int = math.ceil
local m_floor = math.floor;
local m_ceil = math.ceil;
local m_max = math.max;
local m_min = math.min;
--
--
--  Debug Stuff
--
--
local function noop()
end

local dbg = noop
-- _D_ebug flag for using in D and "" or <do stuff>
local D = true -- set to true if there's no debugging D and "" or <concatenate string>

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
--
--  Basic "counting time" definitions
--
--
local lengthModifiers = {
	normal = 1.0,
	dotted = 3.0 / 2.0,
	triplet = 2.0 / 3.0
}

-- ppq is based on 1/4 notes
local ppqBaseValue = {
	MSEC=60000.0, -- we base everything around this coordinates, so we even need the "right" time base...if we chose to base everything around 1/1 notes we need to set respective values here
	noteNum = 1.0,
	noteDenom = 4.0,
	ratio = 0.25
}
-- all based on whole note! important to note - we compute based on whole note.
local _1over64 = {name = "1/64", ratio = 1.0 / 64.0}
local _1over32 = {name = "1/32", ratio = 1.0 / 32.0}
local _1over16 = {name = "1/16", ratio = 1.0 / 16.0}
local _1over8 = {name = "1/8", ratio = 1.0 / 8.0}
local _1over4 = {name = "1/4", ratio = 1.0 / 4.0}
local _1over2 = {name = "1/2", ratio = 1.0 / 2.0}
local _1over1 = {name = "1/1", ratio = 1.0 / 1.0}

local allSyncOptions = {
	_1over64, _1over32, _1over16, _1over8, _1over4, _1over2, _1over1,
}
-- add synthetic ratio for doing the ratios from our ppqBaseValue
-- 1/4 / 1/4 --> 1; 1/1 / 1/4 --> 4 use to compute noteLenghts based on quarter base values
for i=1,#allSyncOptions do
	allSyncOptions[i].fromQuarterRatio=allSyncOptions[i].ratio / ppqBaseValue.ratio 
end

-- create a name --> sync option table
local allSyncOptionsByName = {}
for i = 1, #allSyncOptions do
	allSyncOptionsByName[allSyncOptions[i].name] = allSyncOptions[i]
end
--compute all getAllSyncOptionNames of the table of all families
local allSyncOptionNames = {}
for _ , s in ipairs(allSyncOptions) do
	--print(s["name"])
	allSyncOptionNames[#allSyncOptionNames + 1] = s["name"]
end
local function getAllSyncOptionNames()
	return allSyncOptionNames;
end
--
--
--
--MAIN LOOP
--
--
local left = 0 --left channel
local right = 1 --right channel
local runs = 0 -- just for debugging purpose. counts the number processBlock has been called

--
-- common event attribute names
-- use these names to put into or get from events and thus get hold of the "DAW context" a certain event happened. 
--
local EVT_VAL_MIDI_BUFFER = "midiBuffer"
local EVT_VAL_DAW_POSITION = "position"

local EventSource = {}
function EventSource:new()
	local o = { eventListeners = {} }
	setmetatable(o, self)
	self.__index = self
	return o
end
function EventSource:addEventListener(inEventListener)
	print("EventSource:addEventListener: self.eventListeners: "..string.format("%s",self.eventListeners).."; inListener: "..string.format("%s",inEventListener))
	self.eventListeners[#self.eventListeners+1] = inEventListener
end
function EventSource:removeEventListener(inEventListener)
	-- todo
	print("TODO EventSource:removeEventListener: "..string.format("%s",self))
end
function EventSource:fireEvent(inEvent)
	--print("EventSource: fireEvent: "..string.format("%s", self.eventListeners))
	local listeners = self.eventListeners
	local n=#listeners
	for i=1,n do
		listeners[i](inEvent)
	end
end

local globals = {
	runs = 0, -- number of plugin.processBlock has been called
	samplesCount = 0, -- summ of all sample blocks that we have seen.
	sampleRate = -1,
	sampleRateByMsec = -1, --computed
	isPlaying = false,
	bpm = 0,
	msecPerBeat = 0, --computed; based on whole note
	samplesPerBeat = 0, --computed; based on whole note
}
-- do a little dirty inheritance here, as globals is not really a class but just a global table where we want to add the event stuff.
setmetatable(globals, { __index= EventSource:new() })
print("GLOBALS: ".. #globals.eventListeners)

function globals:finishRun(inSmax)
	self.runs = self.runs+1
	self.samplesCount = self.samplesCount + inSmax
end
function globals:updateDAWGlobals(inSamples, inSamplesNumberOfCurrentFrame, inMidiBuffer, inDAWPosition)
	--print("Debug: Update Position; inHostPosition.bpm: " .. inHostPosition.bpm)
	local newBPM = inDAWPosition.bpm
	local oldBPM = self.bpm;
	if newBPM ~= oldBPM then
		-- remember old stuff
		local oldValues = { bpm=oldBPM, msecPerBeat=self.msecPerBeat, samplesPerBeat=self.samplesPerBeat, perBeatBase=ppqBaseValue }
		-- compute and set new stuff
		self.bpm = newBPM
		self.msecPerBeat = ppqBaseValue.MSEC / newBPM -- usually beats is based on quarters ... 
		self.samplesPerBeat = self.msecPerBeat * globals.sampleRateByMsec
		-- pack new Values
		local newValues= { bpm=self.bpm, msecPerBeat=self.msecPerBeat, samplesPerBeat=self.samplesPerBeat, perBeatBase=ppqBaseValue }
		-- fire event
		self:fireEvent({ type= "BPM", midiBuffer=inMidiBuffer, oldValues=oldValues, newValues=newValues; source=self })
	end
	local newIsPlaying = inDAWPosition.isPlaying
	local oldIsPlaying = self.isPlaying
	if newIsPlaying ~= oldIsPlaying then
		self.isPlaying = newIsPlaying
		self:fireEvent({ type= "IS-PLAYING", midiBuffer=inMidiBuffer, oldValue=oldIsPlaying, newValue=newIsPlaying; source=self })
	end
end
function globals:updateSampleRate(inSampleRate)
	local oldSampleRate = self.sampleRate
	if inSampleRate ~= oldSampleRate then
		self.sampleRate = inSampleRate
		self.sampleRateByMsec = inSampleRate / 1000.0
		self:fireEvent({ type= "SAMPLE-RATE", old=oldSampleRate, new=inSampleRate; source=self })
	end
end

plugin.addHandler("prepareToPlay", function() globals:updateSampleRate(plugin.getSampleRate()) end)

local NoteLenSyncer = EventSource:new()
function NoteLenSyncer:new(inSyncOption, inModifier)
	local syncOption = inSyncOption or _1over8;
	local modifier = inModifier or lengthModifiers.normal
	local o = EventSource:new()
	o.sync = syncOption
	o.modifier = modifier
	-- from globals event
	o.msecPerBeat = 0
	o.samplesPerBeat = 0
	o.perBeatBase = nil
	-- computed
	o.noteLenInMsec=0
	o.noteLenInSamples=0;
	setmetatable(o, self)
	self.__index = self
	return o
end
function NoteLenSyncer:start()
	print("NoteLenSyncer Listener: Start")
	globals:addEventListener( function(inEvent) self:listenToBPMChange(inEvent) end)
end
function NoteLenSyncer:listenToBPMChange(inEvent)
	print("NoteLenSyncer Listener: ".. string.format("%s",self))
	if "BPM" == inEvent.type then
		-- local
		local eventNewValues = inEvent.newValues
		-- cache event values
		self.msecPerBeat    = eventNewValues.msecPerBeat
		self.samplesPerBeat = eventNewValues.samplesPerBeat
		self.perBeatBase    = eventNewValues.perBeatBase
		--
		self:updateStateAndFire()
	end
end
function NoteLenSyncer:updateSyncValue(inSync, inMod)
	local changed = false
	local oldSync = self.sync
	local oldMod  = self.modifier
	if inSync and inSync.ratio ~= self.ratio then
		self.sync = inSync
		changed = true
	end
	if inMod and inMod ~= self.modifier  then
		self.modifier = inMod
		changed = true
	end
	if changed then
		self:updateStateAndFire()
	end
end
function NoteLenSyncer:updateStateAndFire()
	local sync = self.sync
	local mod  = self.modifier
	local oldValues = { noteLenInMsec= self.noteLenInMsec; noteLenInSamples=self.noteLenInSamples }
	local factor = sync.fromQuarterRatio * mod -- based on our base value we compute the specifc lengths
	self.noteLenInMsec    = self.msecPerBeat    * factor
	self.noteLenInSamples = self.samplesPerBeat * factor
	local newValues = { noteLenInMsec = self.noteLenInMsec; noteLenInSamples=self.noteLenInSamples; sync=self.sync, modifier = self.modifier }
	self:fireEvent({ type= "NOTE-LEN-VALUES", oldValues=oldValues, newValues=newValues; source=self })
end
function NoteLenSyncer:getSync()
	return self.sync
end
function NoteLenSyncer:getSyncRatio()
	return self.sync.ratio
end
function NoteLenSyncer:getModifier()
	return self.modifier
end
function NoteLenSyncer:getNoteLenInSamples()
	return self.noteLenInSamples
end
function NoteLenSyncer:getNoteLenInMSec()
	return self.noteLenInMsec
end
function NoteLenSyncer:dawPPQinPPNote(inPPQ)
	-- here it's actually inverse when ...
	-- for example in 1/4 (i.e. ppq) we have a value of 3.5 
	-- we have ...
	-- in 1/2 it is 1.75 and 
	-- in 1/8 it is 7
	-- whereas if we think in samples size the factors are inverse
	local sync = self.sync
	return inPPQ / (sync.fromQuarterRatio * self.modifier)
end

local StandardSyncer = NoteLenSyncer:new();
StandardSyncer:start()
StandardSyncer:addEventListener( function(evt) print(serialize_list(evt)) end)
--
local _1over8FixedSyncer = NoteLenSyncer:new(_1over8);
_1over8FixedSyncer:start()

--
-- Tickers actually follow the DAW and tick with it playing
-- they may use NoteSyncer to get the appropriate sync values, i.e. length in sample, msecs of the syncers 
-- if this ticker is configured with a 1/8 syncer it will emit events each 1/8.
-- keep in mind it will emit an event in the DAW "frame" when th next 1/8 must happen. always remember the sample offset! 
--
local PPQTicker = EventSource:new()
function PPQTicker:new(inSyncer)
	local o = EventSource:new()
	-- cached
	o.syncer = inSyncer
	-- from Event
	o.noteLenInSamples = 0
	-- state
	o.countSamples = 0
	o.countFrames = 0
	-- computed
	o.samplesToNextCount = 0
	setmetatable(o, self)
	self.__index = self
	return o
end
function PPQTicker:start()
	print("PPQTicker Listener: Start")
	self.syncer:addEventListener( function(inEvent) self:listenToSyncerChange(inEvent) end)
end
function PPQTicker:listenToSyncerChange(inEvent)
	print("PPQTicker Listener: ".. serialize_list(inEvent))
	if "NOTE-LEN-VALUES" == inEvent.type then
		self.noteLenInSamples = inEvent.newValues.noteLenInSamples
	end
end

function PPQTicker:updateDAWPosition(inSamples, inSamplesNumberOfCurrentFrame, inMidiBuffer, inDAWPosition)
	if inDAWPosition.isPlaying then
		-- 3. "ppq" of the specified notelen ... if we don't count 1/4 we have to count more/lesse depending on selected noteLength
		local ppqOfNoteLen = self.syncer:dawPPQinPPNote(inDAWPosition.ppqPosition)
		-- 4. the delta to the next count in "ppq" relative to the selected noteLength
		local currentCount = m_floor(ppqOfNoteLen)
		local nextCount    = m_ceil(ppqOfNoteLen)
		local deltaToNextCount = nextCount - ppqOfNoteLen
		-- 5. the number of samples that is delta to the next count based on selected noteLength
		local samplesToNextCount = m_ceil(deltaToNextCount * self.noteLenInSamples)
		self.samplesToNextCount = samplesToNextCount
		-- 6. note switch in this frame
		local switch = samplesToNextCount < inSamplesNumberOfCurrentFrame
		self:fireEvent(
			{ type="SYNC",
				source=self,
				[EVT_VAL_MIDI_BUFFER]  = inMidiBuffer,
				[EVT_VAL_DAW_POSITION] = inDAWPosition,
				numberOfSamplesInFrame=inSamplesNumberOfCurrentFrame, 
				samples=inSamples,
				switchCountFlag=switch,
				currentCount = currentCount,
				nextCount = nextCount,
				samplesToNextCount=samplesToNextCount,
				ppnToNextCount = deltaToNextCount} )
		self.countSamples = self.countSamples + inSamplesNumberOfCurrentFrame
		self.countFrames = self.countFrames + 1
	end
end
function PPQTicker:getNoteLenInSamples()
	return self.noteLenInSamples
end
function PPQTicker:getSyncer()
	return self.syncer
end
function PPQTicker:getSamplesToNextCount()
	return self.samplesToNextCount
end
--
local StandardPPQTicker =  PPQTicker:new(StandardSyncer)
StandardPPQTicker:start()
StandardPPQTicker:addEventListener(
	function(evt)
		if evt.switchCountFlag then
			print(serialize_list({evt.switchCountFlag, evt.samplesToNextCount, evt.ppnToNextCount, evt.currentCount, evt.nextCount}))
		end
	end)


--
-- Tickers actually follow the DAW and tick with it playing
-- they may use NoteSyncer to get the appropriate sync values, i.e. length in sample, msecs of the syncers 
--
local PatternEmitter = EventSource:new()
function PatternEmitter:new(inTicker)
	local o = EventSource:new()
	-- cached
	o.ticker = inTicker
	-- from Event
	o.noteLenInSamples = 0
	-- state
	o.count = 0
	o.pattern = {1,0,0,0,2,0,0,1,0,0,1,0,0,2,0,0}
	setmetatable(o, self)
	self.__index = self
	return o
end
function PatternEmitter:start()
	print("PatternEmitter Listener: Start")
	self.ticker:addEventListener( function(inEvent) self:listenToTicker(inEvent) end)
end
function PatternEmitter:listenToTicker(inSyncEvent)
	print("PatternEmitter Listener: ".. serialize_list(inSyncEvent))
	if "SYNC" == inSyncEvent.type then
		if inSyncEvent.switchCountFlag then
			local pattern=self.pattern
			local patternLen=#pattern
			local nextCount =inSyncEvent.nextCount
			local patternIndex = (nextCount % patternLen)+1
			local patternElem = pattern[patternIndex]
			if patternElem ~=0 then
				self:fireEvent( 
					{ type="PATTERN",
						source=self,
						patternLen=patternLen,
						patternIndex=patternIndex,
						patternElem=patternElem,
						[EVT_VAL_MIDI_BUFFER]  = inSyncEvent[EVT_VAL_MIDI_BUFFER],
						[EVT_VAL_DAW_POSITION] = inSyncEvent[EVT_VAL_DAW_POSITION]
						} )
			end
		end
	end
end

local a1= { 37,110 }
local a2= { 49,110 }
local StupidMidiEmitter = {
	pattern={a1,0,0,0,a2,0,0,a1,0,0,a1,0,0,a2,0,0},
	trackingList = {},
	maxAge=18000
}
function StupidMidiEmitter:listenNoteLenght(inNoteLenEvent)
	print("PPQTicker Listener: ".. serialize_list(inNoteLenEvent))
	if "NOTE-LEN-VALUES" == inNoteLenEvent.type then
		self.maxAge = inNoteLenEvent.newValues.noteLenInSamples
	end
end
function StupidMidiEmitter:listenPulse(inSyncEvent)
	local numberOfSamplesInFrame = inSyncEvent.numberOfSamplesInFrame
	local midiBuffer = inSyncEvent.midiBuffer
	local trackingList = self.trackingList
	local maxAge = self.maxAge
	local n=#trackingList
	-- to get rid of aged events we build a new list with only the still relevant events.
	local updatedList = {}
	for i=1,n do
		local age = trackingList[i].age
		local nuAge = age+numberOfSamplesInFrame
		if nuAge > maxAge then
			local noteOn = trackingList[i].midiEvent
			local noteOff = midi.Event.noteOff(1,noteOn:getNote(),0,maxAge-age)
			print("NoteOff: age="..age.."; nuAge="..nuAge.."; maxAge="..maxAge.."; offset="..maxAge-age)
			midiBuffer:addEvent(noteOff)
		else
			trackingList[i].age = nuAge
			updatedList[#updatedList+1] = trackingList[i]
		end
	end
	if inSyncEvent.switchCountFlag then
		local pattern=self.pattern
		local lenPattern=#pattern
		local nextCount =inSyncEvent.nextCount
		local patternElem = pattern[(nextCount % lenPattern)+1]
		if patternElem ~=0 then
			local midiEvent = midi.Event.noteOn(1,patternElem[1],patternElem[2],inSyncEvent.samplesToNextCount)
			-- note when we place the note sample accurate into this frame then it already has a ertain amount
			-- of samples as "age" in this very frame
			local eventTrack = { age = numberOfSamplesInFrame - inSyncEvent.samplesToNextCount, midiEvent=midiEvent}
			midiBuffer:addEvent(midiEvent)
			updatedList[#updatedList+1] = eventTrack
		end
	end
	-- swap list
	self.trackingList=updatedList
end
function StupidMidiEmitter:listenPlayingOff(inGlobalEvent)
	if "IS-PLAYING" == inGlobalEvent.type and inGlobalEvent.oldValue == true and inGlobalEvent.newValue == false then
		local midiBuffer = inGlobalEvent[EVT_VAL_MIDI_BUFFER]
		local trackingList = self.trackingList
		local n=#trackingList
		for i=1,n do
			local age = trackingList[i].age
			local noteOn = trackingList[i].midiEvent
			local noteOff = midi.Event.noteOff(1,noteOn:getNote(),0,0)
			print("PlayingOff: age="..age)
			midiBuffer:addEvent(noteOff)
		end
	end
	self.trackingList={}
end
_1over8FixedSyncer:addEventListener( function(evt) StupidMidiEmitter:listenNoteLenght(evt) end)
StandardPPQTicker:addEventListener( function(evt) StupidMidiEmitter:listenPulse(evt) end )
globals:addEventListener(function(evt) StupidMidiEmitter:listenPlayingOff(evt) end )

--
--
-- main plugin code
--
--
function plugin.processBlock(samples, smax, midi) -- let's ignore midi for this example
	local position = plugin.getCurrentPosition()
	globals:updateDAWGlobals(samples, smax, midi, position)
	StandardPPQTicker:updateDAWPosition(samples, smax, midi, position)

	globals:finishRun( smax + 1 )
end

function maximum(a)
	local mi = 1 -- maximum index
	local m = a[mi] -- maximum value
	for i, val in ipairs(a) do
		if val > m then
			mi = i
			m = val
		end
	end
	return m
end

function minimum(a)
	local mi = 1 -- maximum index
	local m = a[mi] -- maximum value
	for i, val in ipairs(a) do
		if val < m then
			mi = i
			m = val
		end
	end
	return m
end

--
--
-- Params
--
--
-- based on the sync name of the parameter set the selected sync values
function updateSync(arg)
	local s = allSyncOptionsByName[arg]
	if s ~= StandardSyncer:getSync() then
		StandardSyncer:updateSyncValue(s)
	end
	return
end

params =
	plugin.manageParams {
	{
		name = "Sync",
		type = "list",
		values = getAllSyncOptionNames(),
		default = getAllSyncOptionNames()[1],
		changed = function(val)
			updateSync(val)
		end
	},
}

--------------------------------------------------------------------------------------------------------------------
--
-- Load and Save Data
--
local header = "Arp"

function script.loadData(data)
	-- check data begins with our header
	if string.sub(data, 1, string.len(header)) ~= header then
		return
	end
end

function script.saveData()
	local serialized = header 
	print("Serialized: " .. serialized)
	return serialized
end

function serializeListofPoints(inListOfPoints)
	local s = ""
	local sep = ""
	for i = 1, #inListOfPoints do
		s = s .. sep .. string.format("%s", inListOfPoints[i])
		sep = ","
	end
	return s
end