-- SyncGlobals module for ProtoplugScripts
-- Singleton that tracks DAW global state (BPM, sample rate, playing state)
-- and fires events when these values change

local EventSource = require("EventSource")

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
-- GLOBALS Singleton
--
--
local PPQ_BASE_VALUE = {
	MSEC=60000.0, -- we base everything around this coordinates, so we even need the "right" time base...if we chose to base everything around 1/1 notes we need to set respective values here
	noteNum = 1.0,
	noteDenom = 4.0,
	ratio = 0.25 -- this value is noteNum/noteDenom but it's technically not possible to do computation in a table initializer.
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

function GLOBALS:isDawPlaying()
    return self.isPlaying
end

-- Export module with GLOBALS singleton and context helper functions
return {
	GLOBALS = GLOBALS,
	EVT_VAL_CTX = EVT_VAL_CTX,
	CTX_VAL_MIDI_BUFFER = CTX_VAL_MIDI_BUFFER,
	CTX_VAL_DAW_POSITION = CTX_VAL_DAW_POSITION,
	CTX_VAL_NUM_SAMPLES_IN_FRAME = CTX_VAL_NUM_SAMPLES_IN_FRAME,
	CTX_VAL_SAMPLES_OF_FRAME = CTX_VAL_SAMPLES_OF_FRAME,
	CTX_VAL_EPOCH = CTX_VAL_EPOCH,
	unpackCtx = unpackCtx,
	packCtx = packCtx,
	eventFromEvent = eventFromEvent
}