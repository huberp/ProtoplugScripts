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
local m_random = math.random;
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
local _1over128 = {name = "1/128", ratio = 1.0 / 128.0}
local _1over64 = {name = "1/64", ratio = 1.0 / 64.0}
local _1over32 = {name = "1/32", ratio = 1.0 / 32.0}
local _1over16 = {name = "1/16", ratio = 1.0 / 16.0}
local _1over8 = {name = "1/8", ratio = 1.0 / 8.0}
local _1over4 = {name = "1/4", ratio = 1.0 / 4.0}
local _1over2 = {name = "1/2", ratio = 1.0 / 2.0}
local _1over1 = {name = "1/1", ratio = 1.0 / 1.0}

local allSyncOptions = {
	_1over128, _1over64, _1over32, _1over16, _1over8, _1over4, _1over2, _1over1,
}
-- add synthetic ratio for doing the ratios from our ppqBaseValue. ppq is based on 1/4
-- 1/4 / 1/4 --> 1; 1/1 / 1/4 --> 4 use to compute noteLenghts based on quarter base values
-- so let's assume a 1/4 has length 10000 samples length
-- if we no rather see a 1/8 the lenght in samples is 5000 = (1/8 / 1/4) * 10000
-- if we see 1/2 the lenght ins samples is 20000 = 2 * 10000 = (1/2 / 1/4) * 10000
--
-- if on the other hand we want to compute from DAW ppq (pules per quarter) a specific ppn (pules per notelength)
-- we need to use the invers. when we count 1/8 rather than 1/4 we count double the number in the same time...
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
local EVT_VAL_NUM_SAMPLES_IN_FRAME = "numberOfSamplesInFrame"
local EVT_VAL_SAMPLES_OF_FRAME = "samplesOfFrame"
local EVT_VAL_EPOCH = "epoch"
--
-- helper allows to get all 4 context values of a main process ing loop from a list, ...
-- ... assuming they are stored under the defined key-names, EVT_VAL_MIDI_BUFFER, etc.
-- 
local function unpackEvt(inEvent)
	return inEvent[EVT_VAL_SAMPLES_OF_FRAME], inEvent[EVT_VAL_NUM_SAMPLES_IN_FRAME],
		inEvent[EVT_VAL_MIDI_BUFFER], inEvent[EVT_VAL_DAW_POSITION]
end
local function eventFromEvent(inTriggeringEvent, inNewEvt)
	inNewEvt[EVT_VAL_NUM_SAMPLES_IN_FRAME] = inTriggeringEvent[EVT_VAL_NUM_SAMPLES_IN_FRAME]
	inNewEvt[EVT_VAL_SAMPLES_OF_FRAME] = inTriggeringEvent[EVT_VAL_SAMPLES_OF_FRAME]
	inNewEvt[EVT_VAL_DAW_POSITION] = inTriggeringEvent[EVT_VAL_DAW_POSITION]
	inNewEvt[EVT_VAL_MIDI_BUFFER]  = inTriggeringEvent[EVT_VAL_MIDI_BUFFER]
	inNewEvt[EVT_VAL_EPOCH] = inTriggeringEvent[EVT_VAL_EPOCH]
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
	print("EventSource:addEventListener: self.eventListeners: "..serialize_list(listeners))
	return inEventListener
end
function EventSource:removeEventListener(inEventListener)
	local listeners = self.eventListeners
	local size = #listeners
	array_remove(listeners, function(t,i) return t[i]~= inEventListener end)
	print("EventSource:removeEventListener: "..serialize_list(listeners))
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
local GLOBALS = {
	runs = 0, -- number of plugin.processBlock has been called
	samplesCount = 0, -- sum of all sample blocks that we have seen.
	sampleRate = -1,
	sampleRateByMsec = -1, --computed
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
function GLOBALS:updateDAWGlobals(inSamples, inSamplesNumberOfCurrentFrame, inMidiBuffer, inDAWPosition)
	--print("Debug: Update Position; inHostPosition.bpm: " .. inHostPosition.bpm)
	local newBPM = inDAWPosition.bpm
	local oldBPM = self.bpm;
	if newBPM ~= oldBPM then
		-- remember old stuff
		local oldValues = { bpm=oldBPM, msecPerBeat=self.msecPerBeat, samplesPerBeat=self.samplesPerBeat, perBeatBase=ppqBaseValue }
		-- compute and set new stuff
		self.bpm = newBPM
		self.msecPerBeat = ppqBaseValue.MSEC / newBPM -- usually beats is based on quarters ... 
		self.samplesPerBeat = self.msecPerBeat * self.sampleRateByMsec
		-- pack new Values
		local newValues= { bpm=self.bpm, msecPerBeat=self.msecPerBeat, samplesPerBeat=self.samplesPerBeat, perBeatBase=ppqBaseValue }
		-- fire event
		self:fireEvent({ type= "BPM",
				source=self,
				oldValues=oldValues,
				newValues=newValues,
				[EVT_VAL_MIDI_BUFFER]  = inMidiBuffer,
				[EVT_VAL_DAW_POSITION] = inDAWPosition,
				[EVT_VAL_NUM_SAMPLES_IN_FRAME]=inSamplesNumberOfCurrentFrame,
				[EVT_VAL_SAMPLES_OF_FRAME] = inSamples,
				[EVT_VAL_EPOCH] = self.runs
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
				[EVT_VAL_MIDI_BUFFER]  = inMidiBuffer,
				[EVT_VAL_DAW_POSITION] = inDAWPosition,
				[EVT_VAL_NUM_SAMPLES_IN_FRAME]=inSamplesNumberOfCurrentFrame,
				[EVT_VAL_SAMPLES_OF_FRAME] = inSamples,
				[EVT_VAL_EPOCH] = self.runs
			}
		)
	end
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
-- Process incoming midi stuff
-- 
--
local function MidiSortByNot(inEv1, inEv2)
	return inEv1:getNote() < inEv2:getNote()
end

local MIDI_IN_TRACKER = {
	noteEventList = { },
	midiEventSorter = MidiSortByNot
}
setmetatable(MIDI_IN_TRACKER, { __index= EventSource:new() })
function MIDI_IN_TRACKER:updateDAWGlobals(_, _, inMidiBuffer, _)
	-- analyse midi buffer and prepare a chord for each note
	for ev in inMidiBuffer:eachEvent() do
		if ev:isNoteOn() then
			self:addNoteOn(ev)
		elseif ev:isNoteOff() then
			self:removeNote(ev)
		end
	end
	inMidiBuffer:clear()
end
function MIDI_IN_TRACKER:getNoteList()
	return self.noteEventList
end
function MIDI_IN_TRACKER:numberNotes()
	return #self.noteEventList
end
function MIDI_IN_TRACKER:addNoteOn( inMidiEvent )
	local nel = self.noteEventList
	local sizeBefore = #nel
	nel[sizeBefore+1] = midi.Event(inMidiEvent) -- createcopy
	table.sort(nel, self.midiEventSorter)
	print("Note Add: note="..inMidiEvent:getNote())
	if 0 == sizeBefore then
		self:fireEvent({type="FIRST-NOTE-ADDED", source=self})
	end
end
function MIDI_IN_TRACKER:removeNote( inMidiEvent )
	local nel = self.noteEventList
	local note= inMidiEvent:getNote()
	print("Note OFF: note="..inMidiEvent:getNote().."; listed notes before="..serialize_list(self:getAllNotes()))
	for i =1, #nel do
		if note == nel[i]:getNote() then
			--print("Note REMOVE: note="..nel[i]:getNote())
			table.remove(nel, i)
			print("Note REMOVE: listed notes after="..serialize_list(self:getAllNotes()))
			break
		end
	end
	if 0 == #nel then
		self:fireEvent({type="LAST-NOTE-REMOVED", source=self})
	end
end
function MIDI_IN_TRACKER:getAllNotes()
	local nel = self.noteEventList
	local notes = {}
	for i=1,#nel do
		notes[i] = nel[i]:getNote()
	end
	return notes
end

--======================================================================================================================
--
--
-- NoteSyncers keep some values up to date based on NoteLenght and BPM, SampleRate, etc.
--
--
local NoteLenSyncer = EventSource:new()
function NoteLenSyncer:new(inSyncOption, inModifier)
	local syncOption = inSyncOption or _1over8;
	local modifier = inModifier or lengthModifiers.normal
	local o = EventSource:new()
	o.sync = syncOption
	o.modifier = modifier
	-- from GLOBALS event
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
	GLOBALS:addEventListener( function(inEvent) self:listenToBPMChange(inEvent) end)
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
local _1over8FixedSyncer = NoteLenSyncer:new(_1over16);
_1over8FixedSyncer:start()

--======================================================================================================================
--
--
-- Tickers actually follow the DAW and tick with it playing
-- they may use NoteSyncer to get the appropriate sync values, i.e. length in sample, msecs of the syncers 
-- if this ticker is configured with a 1/8 syncer it will emit events each 1/8.
-- keep in mind it will emit an event in the DAW "frame" when th next 1/8 must happen. always remember the sample offset! 
--
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
	local ppqOfNoteLen = 0
	if inDAWPosition.isPlaying then
		-- 1.a "ppq" of the specified notelen ... if we don't count 1/4 we have to count more/less depending on selected noteLength
		-- it's like a "pulse per quater" to a "pulse per note length" conversion
		ppqOfNoteLen = self.syncer:dawPPQinPPNote(inDAWPosition.ppqPosition)
	else
		-- 1.b we don't have any ppq here .. therefore let's derive the ppqOfNoteLen based on samples
		ppqOfNoteLen = GLOBALS:getCurrentSampleCount() / self.syncer:getNoteLenInSamples()
	end

	-- 2. the delta to the next count in "ppq" relative to the selected noteLength
	local currentCount = m_floor(ppqOfNoteLen)
	local nextCount    = m_ceil(ppqOfNoteLen)
	local deltaToNextCount = nextCount - ppqOfNoteLen
	-- 3. the number of samples that is delta to the next count based on selected noteLength
	local samplesToNextCount = m_ceil(deltaToNextCount * self.noteLenInSamples)
	self.samplesToNextCount = samplesToNextCount
	-- 4. note switch in this frame?
	local switch = samplesToNextCount < inSamplesNumberOfCurrentFrame
	-- 5. fire event
	self:fireEvent(
		{ type="SYNC",
			source=self,
			[EVT_VAL_MIDI_BUFFER]  = inMidiBuffer,
			[EVT_VAL_DAW_POSITION] = inDAWPosition,
			[EVT_VAL_NUM_SAMPLES_IN_FRAME]=inSamplesNumberOfCurrentFrame,
			[EVT_VAL_SAMPLES_OF_FRAME] = inSamples,
			[EVT_VAL_EPOCH] = GLOBALS.runs,
			samples=inSamples,
			switchCountFlag=switch,
			currentCount = currentCount,
			nextCount = nextCount,
			numberOfSamplesToNextCount=samplesToNextCount,
			ppnToNextCount = deltaToNextCount} )
	self.countSamples = self.countSamples + inSamplesNumberOfCurrentFrame
	self.countFrames = self.countFrames + 1
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
--StandardPPQTicker:addEventListener(
--	function(evt)
--		if evt.switchCountFlag then
--			print(serialize_list({evt.switchCountFlag, evt.samplesToNextCount, evt.ppnToNextCount, evt.currentCount, evt.nextCount}))
--		end
--	end)

--======================================================================================================================
--
--
-- Tickers actually follow the DAW and tick with it playing
-- they may use NoteSyncer to get the appropriate sync values, i.e. length in sample, msecs of the syncers 
--
--
local PatternEmitter = EventSource:new()
function PatternEmitter:new(inEmitterID, inTicker, inInitEmitting, inPattern)
	local o = EventSource:new()
	-- cached
	o.emitterID = inEmitterID
	o.ticker = inTicker
	o.pattern = inPattern
	-- from Event
	o.noteLenInSamples = 0
	-- state
	o.count = 0
	o.isEmitting = inInitEmitting
	--
	setmetatable(o, self)
	self.__index = self
	return o
end
function PatternEmitter:start()
	print("PatternEmitter Listener: Start")
	self.ticker:addEventListener( function(inEvent) self:listenToTicker(inEvent) end)
end 
function PatternEmitter:getEmitterID()
	return self.emitterID
end
function PatternEmitter:getPattern()
	return self.pattern
end
function PatternEmitter:isEmitting()
	return self.isEmitting
end
function PatternEmitter:setEmitting(inVal)
	local old = self.isEmitting
	self.isEmitting = inVal
	return old
end
function PatternEmitter:toggle(inIndex)
	local pattern = self.pattern
	local oldVal= pattern[inIndex]
	if oldVal == 0 then
		pattern[inIndex] = self.emitterID
	else
		pattern[inIndex] = 0
	end
	self:fireEvent({"PATTERN-CHG-EVT", idx=inIndex, oldVal=oldVal, newVal=pattern[inIndex], source=self})
end
function PatternEmitter:listenToTicker(inSyncEvent)
	--print("PatternEmitter Listener: ".. serialize_list(inSyncEvent))
	if self.isEmitting == false then
		return
	end
	if "SYNC" == inSyncEvent.type then
		if inSyncEvent.switchCountFlag then
			local pattern=self.pattern
			local patternLen=#pattern
			local nextCount =inSyncEvent.nextCount
			local patternIndex = (nextCount % patternLen)+1
			local patternElem = pattern[patternIndex]
			if patternElem ~=0 then
				self:fireEvent(
					eventFromEvent(
						inSyncEvent,
						{ type="PATTERN-ON",
							--orginal values
							source=self,
							emitterID = self.emitterID,
							patternLen=patternLen,
							patternIndex=patternIndex,
							patternElem=patternElem,
							--propagate
							numberOfSamplesToNextCount = inSyncEvent.numberOfSamplesToNextCount,
						}
					)
				)
			end
			self:fireEvent(
					{ type="PATTERN-IDX",
						--orginal values
						source=self,
						emitterID = self.emitterID,
						patternLen=patternLen,
						patternIndex=patternIndex,
						patternElem=patternElem
					}
				)
		end
	end
end
local TestPattern  = PatternEmitter:new(1, StandardPPQTicker, false, {1,0,0,0,1,0,0,1,0,0,1,0,0,0,0,0})
TestPattern:start()
local TestPattern2 = PatternEmitter:new(2, StandardPPQTicker, false, {0,2,0,0,2,0,0,0,0,0,0,0,2,0,0,0})
TestPattern2:start()
local TestPattern3 = PatternEmitter:new(3, StandardPPQTicker, false, {3,0,0,3,3,0,3,0,3,0,3,0,0,3,0,3,0,3})
TestPattern3:start()
local TestPattern4 = PatternEmitter:new(4, StandardPPQTicker, false, {0,0,4,0,0,0,4,0,0,0,4,0,0,0,4,0})
TestPattern4:start()

local function createMidiInListener(inPatternEmitter)
	return function(inEvent)
		local type = inEvent.type
		if "FIRST-NOTE-ADDED" == type then
			print("-------- FIRST NOTE ----------------")
			inPatternEmitter:setEmitting(true)
		elseif "LAST-NOTE-REMOVED" == type then
			inPatternEmitter:setEmitting(false)
		end
	end
end
MIDI_IN_TRACKER:addEventListener(createMidiInListener(TestPattern))
MIDI_IN_TRACKER:addEventListener(createMidiInListener(TestPattern2))
MIDI_IN_TRACKER:addEventListener(createMidiInListener(TestPattern3))
MIDI_IN_TRACKER:addEventListener(createMidiInListener(TestPattern4))

--======================================================================================================================
--
--
-- Synced function executor
--
--
local PatternFunctionExecutor = PatternEmitter:new()
function PatternFunctionExecutor:new(inEmitterID, inTicker, inInitEmitting, inPattern)
	local o = PatternEmitter:new(inEmitterID, inTicker, inInitEmitting, inPattern)
	--
	setmetatable(o, self)
	self.__index = self
	return o
end
function PatternFunctionExecutor:listenToTicker(inSyncEvent)
	--print("PatternEmitter Listener: ".. serialize_list(inSyncEvent))
	if self.isEmitting and "SYNC" == inSyncEvent.type then
		if inSyncEvent.switchCountFlag then
			local pattern=self.pattern
			local patternLen=#pattern
			local nextCount =inSyncEvent.nextCount
			local patternIndex = (nextCount % patternLen)+1
			local patternElem = pattern[patternIndex]
			if patternElem ~=0 then
				patternElem(self, inSyncEvent)
			end
		end
	end
end
local function PAN(inPanValue)
	return function(inPattern, inSyncEvent)
		local midiBuffer = inSyncEvent[EVT_VAL_MIDI_BUFFER]
		local channel = inPattern:getEmitterID()
		local event = midi.Event.control(channel, 10, inPanValue, inSyncEvent.numberOfSamplesToNextCount)
		midiBuffer:addEvent(event)
		print("--------------------------------------------------------------------- PAN: channel="..channel.."; value="..inPanValue)
	end
end

local TestPanPattern  = PatternFunctionExecutor:new(4, StandardPPQTicker, false,
	{ PAN(0), 0, 0, PAN(127), 0, 0, 0, PAN(64), 0, 0, 0, PAN(127), 0, PAN(0), 0, PAN(64)})
TestPanPattern:start()
MIDI_IN_TRACKER:addEventListener(createMidiInListener(TestPanPattern))

--======================================================================================================================
--
--
-- Tickers actually follow the DAW and tick with it playing
-- they may use NoteSyncer to get the appropriate sync values, i.e. length in sample, msecs of the syncers 
--
--
local CompositePatternEmitter = EventSource:new()
function CompositePatternEmitter:new(inEmitterID, inFct, inPatternEmitter1,inPatternEmitter2)
	local o = EventSource:new()
	-- cached
	o.emitterID = inEmitterID
	o.fct = inFct
	o.emitter1 = inPatternEmitter1
	o.emitter2 = inPatternEmitter2
	--state
	o.firstEvent = nil
	o.secondEvent = nil
	setmetatable(o, self)
	self.__index = self
	return o
end
function CompositePatternEmitter:listenPattern(inPatternEvent)
	if inPatternEvent.emitterID == self.emitter1:getEmitterID() then
		self.firstEvent = inPatternEvent.patternElem
	else
		self.secondEvent = inPatternEvent.patternElem
	end
	if nil ~= self.firstEvent and nil ~= self.secondEvent then
		local patternElem=self.fct(self.firstEvent, self.secondEvent)
		if patternElem ~=0 then
			self:fireEvent(
				eventFromEvent(
					inPatternEvent,
					{
						type="PATTERN-ON",
						--orginal values
						source=self,
						emitterID = self.emitterID,
						patternLen=70,
						patternIndex=70,
						patternElem=patternElem,
						--propagate
						numberOfSamplesToNextCount = inPatternEvent.numberOfSamplesToNextCount, 
					}
				)
			)
		end
		self.firstEvent = nil
		self.secondEvent = nil
	end
end
--======================================================================================================================
--
--
-- Midi Event Ager: A Event with given "lenght" in Samples is "aged" here. 
-- If the event grows to old it will be counterd with a note off
--
--
local EventAger = {
	trackingList = {},
}
--
-- incoming sync event --> get rid of all notes that are no longer needed
function EventAger:listenPulse(inSyncEvent)
	local _,numberOfSamplesInFrame,midiBuffer,position = unpackEvt( inSyncEvent )
	local trackingList = self.trackingList
	local n=#trackingList
	-- to get rid of aged events we build a new list which will consist only of the still "alive" events.
	local updatedList = {}
	for i=1,n do
		local singleTrackingItem =  trackingList[i]
		local addedAtEpoch = singleTrackingItem[EVT_VAL_EPOCH]
		-- print("NoteAge: addedAtEpoch="..addedAtEpoch.."; GLOBALS.runs="..GLOBALS.runs);
		if GLOBALS.runs ~= addedAtEpoch then
			-- this if is essential to avoid a premature update in the same "epoch" of creation of the tracking item
			-- if this would happen we would end up with notes ending just one frame to early...
			local age = singleTrackingItem.age
			local eventMaxAge= singleTrackingItem.maxAge
			local nuAge = age+numberOfSamplesInFrame
			-- print("NoteAge: age="..age.."; nuAge="..nuAge.."; maxAge="..eventMaxAge.."; GLOBALS.runs="..GLOBALS.runs)
			if nuAge > eventMaxAge then
				-- END OF LIVE REACHED
				local offset = eventMaxAge-age
				local trackingItemEndFct = singleTrackingItem.endFct
				--local noteOff = midi.Event.noteOff(noteOn:getChannel(),noteOn:getNote(),0, eventMaxAge-age)
				print("AgeOff: age="..age.."; nuAge="..nuAge.."; maxAge="..eventMaxAge
					.."; targetAge="..age+offset.."; offset="..offset.."; ppq="..position.ppqPosition
					.."; samplesToNextCount="..StandardPPQTicker:getSamplesToNextCount().."; GLOBALS.runs="..GLOBALS.runs)
				trackingItemEndFct(midiBuffer,offset)
			else
				singleTrackingItem.age = nuAge
				updatedList[#updatedList+1] = singleTrackingItem
			end
		else
			updatedList[#updatedList+1] = singleTrackingItem
		end
	end
	self.trackingList = updatedList
end
--
-- incoming playing off event --> get rid of all playing notes immediately
function EventAger:listenPlayingOff(inGlobalEvent)
	if "IS-PLAYING" == inGlobalEvent.type and inGlobalEvent.oldValue == true and inGlobalEvent.newValue == false then
		local midiBuffer = inGlobalEvent[EVT_VAL_MIDI_BUFFER]
		local trackingList = self.trackingList
		local n=#trackingList
		for i=1,n do
			local age = trackingList[i].age
			local endFct = trackingList[i].endFct
			print("PlayingOff: age="..age)
			endFct(midiBuffer, 0)
		end
	end
	self.trackingList={}
end
function EventAger:addAgingItem(inItem, inEvent)
	local tl = self.trackingList
	inItem[EVT_VAL_EPOCH] = inEvent[EVT_VAL_EPOCH] -- set the "epoch" value. Essential to avoid creating+update in the same epoch
	tl[#tl+1] = inItem
end
StandardPPQTicker:addEventListener( function(evt) EventAger:listenPulse(evt) end )
GLOBALS:addEventListener(function(evt) EventAger:listenPlayingOff(evt) end )

--======================================================================================================================
--
--
-- Midi Emitter: Emitts Events given by patterns
--
--
local function constantVal(val)
	return function() return val end
end
local returnOne = constantVal(1.0)
local returnHalf = constantVal(0.5)
local returnQuater = constantVal(0.25)
local function humanize(inFunction, inVal)
	local half = inVal/2
	return function()
		return inFunction() - half + (m_random() * inVal)
	end
end

local function toggleValue(valA, valB)
	local toggle = 0
	return function()
		toggle = 1-toggle
		if 0==toggle then
			return valA()
		else
			return valB()
		end
	end
end
local function sequenceValue(inSeq)
	local idx=0
	local len = #inSeq
	return function()
		print("sequenceValue: idx="..idx.."; #inSeq="..len)
		local result = inSeq[idx+1] -- 1 based arrays
		idx = (idx+1) % len
		return result
	end
end

local velocityToggleA = toggleValue(constantVal(120),constantVal(70))
local velocityToggleB = toggleValue(constantVal(50),constantVal(110))
local velocityToggleC = toggleValue(constantVal(110),constantVal(50))
local velocityToggleD = sequenceValue({ 110,50,50 })

local PAT_VAL_IDX_VEL = 1
local PAT_VAL_IDX_LEN = 2
local PatternValues = {
	{ [PAT_VAL_IDX_VEL]=velocityToggleA, [PAT_VAL_IDX_LEN]=returnOne },    -- 1 incoming
	{ [PAT_VAL_IDX_VEL]=velocityToggleB, [PAT_VAL_IDX_LEN]=returnHalf  },  -- 2 incoming
	{ [PAT_VAL_IDX_VEL]=velocityToggleC, [PAT_VAL_IDX_LEN]=humanize(returnHalf,0,25) }, -- 3 incoming
	{ [PAT_VAL_IDX_VEL]=velocityToggleD, [PAT_VAL_IDX_LEN]=humanize(returnQuater,0.1) }  -- 4 incoming
}

local StupidMidiEmitter = {
	ager = EventAger,
	wrapMode = false, -- means if there's a "4" coming in from any pattern but there's only 2 notes then wrap around...
	maxAge=18000
}
function StupidMidiEmitter:listenNoteLenght(inNoteLenEvent)
	print("PPQTicker Listener: ".. serialize_list(inNoteLenEvent))
	if "NOTE-LEN-VALUES" == inNoteLenEvent.type then
		self.maxAge = inNoteLenEvent.newValues.noteLenInSamples
	end
end
function StupidMidiEmitter:createNoteOffTrackingItem(inStartAge, inMaxAge, inMidiNoteOn)
	local result = { age=inStartAge, maxAge=inMaxAge,
		endFct=function(inMidiBuffer, inSamplesToNextCount)
			local noteOff = midi.Event.noteOff(inMidiNoteOn:getChannel(),inMidiNoteOn:getNote(),0, inSamplesToNextCount)
			inMidiBuffer:addEvent(noteOff)
		end
	}
	return result
end
--
-- incoming pattern events --> create new notes
function StupidMidiEmitter:listenPattern(inPatternEvent)
	print("StupidMidiEmitter: ".. serialize_list(inPatternEvent))

	if "PATTERN-ON" ~= inPatternEvent.type then
		return
	end

	local currentLiveEvents = MIDI_IN_TRACKER:getAllNotes();
	local numberLiveEvents = #currentLiveEvents
	if numberLiveEvents == 0 then
		return
	end
	--local patternLen                 = inPatternEvent.patternLen
	--local patternIndex               = inPatternEvent.patternIndex
	local patternElem                = inPatternEvent.patternElem
	if patternElem ~=0 then
		local val = PatternValues[patternElem] -- index into live events
		-- if the numberOfNotes coming from outside is less then the patternElement
		-- and this thingy here is not set to wrap mode ... just return immediately
		if self.wrapMode == false and patternElem > numberLiveEvents then
			return
		end

		-- next stmt use (patternElem-1) because we defined "0" be noop and "1" is the first "active index"
		-- but for working with modulo correctly we need to use not 1 -n but 0 - n-1 as range
		-- then, and this is lua, add 1 to the result for arrays starting at 1
		local indexIntoLiveEvents = 1+ ((patternElem-1) % numberLiveEvents)
		local selectedNoteNumber  = currentLiveEvents[indexIntoLiveEvents]
		--
		local emitterID 				 = inPatternEvent.emitterID
		local numberOfSamplesToNextCount = inPatternEvent.numberOfSamplesToNextCount
		local midiBuffer                 = inPatternEvent[EVT_VAL_MIDI_BUFFER]
		local numberOfSamplesInFrame     = inPatternEvent[EVT_VAL_NUM_SAMPLES_IN_FRAME]
		--
		-- MIDI EVENT
		local midiEvent = midi.Event.noteOn(emitterID,selectedNoteNumber,val[PAT_VAL_IDX_VEL](),numberOfSamplesToNextCount)
		--
		-- note when we place the note sample accurate into this frame then it already has a ertain amount
		-- of samples as "age" in this very frame
		local startAge = numberOfSamplesInFrame - numberOfSamplesToNextCount
		--
		-- then it has a maxAge depending on the noteLenght and our lenght-function (can be 'humanizing' for instance)
		local maxAge = m_ceil( self.maxAge*val[PAT_VAL_IDX_LEN]() )
		--
		-- create tracking item for it
		local trackinItem = self:createNoteOffTrackingItem(startAge, maxAge, midiEvent)
		print("NoteOn: age="..trackinItem.age.."; maxAge="..trackinItem.maxAge.."; offset="..midiEvent.time..", GLOBALS.runs="..GLOBALS.runs.."; indexIntoLiveEvents="..indexIntoLiveEvents)
		--local eventTrack = { age = numberOfSamplesInFrame - numberOfSamplesToNextCount, maxAge=self.maxAge, midiEvent=midiEvent }
		midiBuffer:addEvent(midiEvent)
		self.ager:addAgingItem(trackinItem, inPatternEvent)
	end
end

_1over8FixedSyncer:addEventListener( function(evt) StupidMidiEmitter:listenNoteLenght(evt) end )
local listener = function(evt) StupidMidiEmitter:listenPattern(evt) end
TestPattern:addEventListener( listener )
TestPattern2:addEventListener( listener )
TestPattern3:addEventListener( listener )
TestPattern4:addEventListener( listener )

---------------------------------------------------------------------------------------------------
--
--
-- main plugin code
--
--
function plugin.processBlock(samples, smax, midiBuffer) -- let's ignore midi for this example
	local position = plugin.getCurrentPosition()
	MIDI_IN_TRACKER:updateDAWGlobals(samples, smax+1, midiBuffer, position)

	GLOBALS:updateDAWGlobals(samples, smax+1, midiBuffer, position)

	StandardPPQTicker:updateDAWPosition(samples, smax+1, midiBuffer, position)

	GLOBALS:finishRun( smax + 1 )
end

--======================================================================================================================
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

--======================================================================================================================
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


--======================================================================================================================
--
--
-- UI
--
--

local Colour = {
	juce.Colour(255, 255, 255, 255),
	juce.Colour(255,  64,   0, 255),
	juce.Colour(0,   255,  64, 255),
	juce.Colour(64,    0, 255, 255),
	juce.Colour(255,   0, 255, 255)
}
local ColourOrange = juce.Colour(255, 165,   0, 255)
local ColourBlack =  juce.Colour(  0,   0,   0, 255)

local rectDistance = 40
local rectBorder = 7
local rectWidth = rectDistance - (2*rectBorder)
local rectHeight = rectDistance - (2*rectBorder)
local viewPortX = 50
local viewPortY = 50


local function repaintIt()
	local guiComp = gui:getComponent()
	if guiComp then
		--createImageStereo(process);
		--createImageMono(left);
		guiComp:repaint()
	end
end


local PatternViewModel = EventSource:new()
function PatternViewModel:new(inPatternEmitter)
	local o = EventSource:new()
	-- cached
	o.emitter = inPatternEmitter
	o.patternLen = 0
	o.patternIndex = 0
	o.emitterID = 0
	o.pattern = {}
	o.boxes= {}
	--state
	setmetatable(o, self)
	self.__index = self
	return o
end
--
-- incoming pattern events --> create new notes
function PatternViewModel:listenPattern(inPatternEvent)
	if "PATTERN-IDX" == inPatternEvent.type then
		print("PatternViewModel: Updated, patternLen="..inPatternEvent.patternLen)
		self.patternLen   = inPatternEvent.patternLen
		self.patternIndex = inPatternEvent.patternIndex
		self.emitterID = inPatternEvent.emitterID
		-- the next line - probabaly we should add a "value change event" and listen to when "pattern" value changes
		self.pattern = inPatternEvent.source:getPattern()
	end
end
function PatternViewModel:initBoxes(inBaseX, inBaseY)
	local len = self:getLen()
	---local idx = self.getIndex()
	local pat = self:getPattern()
	---local eID = self.getEmitterID()
	local baseY = inBaseY
	--print("GUI PAINT: len="..len)
	local boxes = {}
	for i=1,len do
		local baseX= inBaseX + (i * rectDistance)
		boxes[#boxes+1] =
		{
			x=baseX, y=baseY, w=rectDistance, h=rectDistance, border=rectBorder,
			click=function() self:toggleControl(i) end,
			val=function() return pat[i] end
		}
	end
	self.boxes=boxes
end
function PatternViewModel:getLen()
	return self.patternLen
end
function PatternViewModel:getIndex()
	return self.patternIndex
end
function PatternViewModel:getPattern()
	return self.pattern
end
function PatternViewModel:getEmitterID()
	return self.emitterID
end
function PatternViewModel:getBoxes()
	return self.boxes
end
-- CONTROL CODE
function PatternViewModel:toggleControl(inIndex)
	self.emitter:toggle(inIndex)
end
-- VIEW CODE
function PatternViewModel:paint(inG)
	local idx = self:getIndex()
	local boxes = self:getBoxes()
	local len = #boxes
	local eID = self:getEmitterID()
	--print("GUI PAINT: len="..len)
	for i=1,len do
		local box = boxes[i];
		local val = box.val();
		if 0==val then
			inG:setColour(Colour[1])
		else
			inG:setColour(Colour[1+eID])
		end
		local border = box.border
		local border2 = 2*border
		inG:fillRect(box.x+border, box.y+border, box.w-border2, box.h-border2)
		if i == idx then
			inG:setColour(ColourOrange)
		else
			inG:setColour(ColourBlack)
		end
		inG:fillRect(box.x+border, box.y+box.h-border+(rectBorder/2), box.w-border2,4)
	end
end

StandardPPQTicker:addEventListener(
	function(evt)
		if evt.switchCountFlag then
			repaintIt()
		end
	end)

local pattern1ViewModel = PatternViewModel:new(TestPattern)
TestPattern:addEventListener(function(evt) pattern1ViewModel:listenPattern(evt) end)

local pattern2ViewModel = PatternViewModel:new(TestPattern2)
TestPattern2:addEventListener(function(evt) pattern2ViewModel:listenPattern(evt) end)

local pattern3ViewModel = PatternViewModel:new(TestPattern3)
TestPattern3:addEventListener(function(evt) pattern3ViewModel:listenPattern(evt) end)

local pattern4ViewModel = PatternViewModel:new(TestPattern4)
TestPattern4:addEventListener(function(evt) pattern4ViewModel:listenPattern(evt) end)

local viewModels = { pattern1ViewModel, pattern2ViewModel, pattern3ViewModel, pattern4ViewModel }


gui.addHandler("mouseUp",
	function(inMouseEvent)
		for model = 1,#viewModels do
			local currentModel=viewModels[model]
			local boxes = currentModel:getBoxes()
			local len = #boxes
			for i=1,len do
				local box = boxes[i];
				print("MouseUp: x="..inMouseEvent.x.."; y="..inMouseEvent.y)
				print("BOX: xmin="..box.x.."; ymin="..box.y.."xmax="..box.x+box.w.."; ymax="..box.y+box.h)
				if inMouseEvent.x > box.x and inMouseEvent.y > box.y 
					and inMouseEvent.x < box.x + box.w and inMouseEvent.y < box.y + box.h then
						box.click()
						return
				end
			end
		end
	end
)

function gui.paint(g)
	g:fillAll()
	--g:setColour(juce.Colour(255, 255, 255))

	for model = 1,#viewModels do
		local currentModel=viewModels[model]
		currentModel:initBoxes(viewPortX, viewPortY+model*rectDistance)
		currentModel:paint(g)
	end
end