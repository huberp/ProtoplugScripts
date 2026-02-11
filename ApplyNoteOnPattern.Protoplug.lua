--[[
name: Apply Note Hight on a pattern
description: apply note hight coming in in channel 1 to a mono-note pattern on channel 2
author: https://github.com/huberp
--]]

require "include/protoplug"


-- https://www.gammon.com.au/scripts/doc.php?lua=package.loadlib
package.cpath = package.cpath..";"..protoplug_dir.."/lib/?.dll"
package.path  = package.path.. ";"..protoplug_dir.."/include/?.lua"
package.path  = package.path.. ";"..protoplug_dir.."/ProtoplugScripts/lib/?.lua"
--
local Logger = require("Logger")
local util = require("util")
local LOG = Logger:new(Logger.LEVELS.DEBUG)
--======================================================================================================================
--
-- Import SyncGlobals module
--
local SyncGlobals = require("SyncGlobals")
local GLOBALS = SyncGlobals.GLOBALS
local EVT_VAL_CTX = SyncGlobals.EVT_VAL_CTX
local CTX_VAL_MIDI_BUFFER = SyncGlobals.CTX_VAL_MIDI_BUFFER
local CTX_VAL_DAW_POSITION = SyncGlobals.CTX_VAL_DAW_POSITION
local CTX_VAL_NUM_SAMPLES_IN_FRAME = SyncGlobals.CTX_VAL_NUM_SAMPLES_IN_FRAME
local CTX_VAL_SAMPLES_OF_FRAME = SyncGlobals.CTX_VAL_SAMPLES_OF_FRAME
local CTX_VAL_EPOCH = SyncGlobals.CTX_VAL_EPOCH
local unpackCtx = SyncGlobals.unpackCtx
local packCtx = SyncGlobals.packCtx
local eventFromEvent = SyncGlobals.eventFromEvent

print("GLOBALS: ".. #GLOBALS.eventListeners)

plugin.addHandler("prepareToPlay", function() GLOBALS:updateSampleRate(plugin.getSampleRate()) end)
--
--
-- all events that are currently playing, an array
local PLAYING_EVENTS = {}
-- all recorded chord events, a hashtable with key midid note number
local CHORD_EVENTS = {}
-- all stuff that needs to be emitted in the current frame, an array
local CURRENT_BLOCK_EVENTS = {}
-- "root" note for computing the index off of
local RHYTHM_ROOT_NOTE = 24 -- C1

--#region project functions to local context
local array_remove = util.array_remove
local floor = math.floor
local abs = math.abs
--#endregion



--[[
	Get the chord event by its index in the chordEvents table 
	@param chordNoteIndex1Based index in the chordEvents table (1 based)
	@return the midi.Event or nil if not found
 ]]--
local function getChordEventByIndex(chordNoteIndex1Based)
	-- we have to search the chordEvents hashtable for the index-th element
	if chordNoteIndex1Based < 1 or chordNoteIndex1Based > #CHORD_EVENTS then
		return nil
	end
	return CHORD_EVENTS[ chordNoteIndex1Based ]
end
--[[
	Stop a chord note based on its index in the chordEvents table and an octave offset
	@param when time when to stopped
	@param chordNoteIndex1Based index in the chordEvents table (1 based)
	@param octaveOffset octave offset to apply
	@return true if something was stopped
 ]]--
local function stopChordNote(when, chordNoteIndex1Based, octaveOffset)
	-- which note event to stop?
	local noteEventAtChordIndex = getChordEventByIndex(chordNoteIndex1Based)
	if noteEventAtChordIndex == nil then
		return false
	end
	-- but keep in mind that there's an octave offset
	local noteToStop = noteEventAtChordIndex:getNote() + octaveOffset
	-- now loop over the playedEvents and find the first one with the given note to stop
	print("Stop chord notes: Size="..#PLAYING_EVENTS.."; note="..tostring(chordNoteIndex1Based).."; octave="..tostring(octaveOffset))
	local countBefore = #PLAYING_EVENTS
	array_remove(PLAYING_EVENTS, 
		function(t,i) return t[i]:getNote() ~= noteToStop end,
		function(t,i) 
			-- found it - now create note-off event
			local playedEvt = t[i]
			print("   Stop chord note: Note="..tostring(playedEvt))
			local nuEvt = midi.Event.noteOff(
				2,
				noteToStop,
				playedEvt:getVel(),
				when)
			-- add the nu note off event into the buffer  
			CURRENT_BLOCK_EVENTS[#CURRENT_BLOCK_EVENTS+1] = nuEvt
		end
	)
	return countBefore ~= #PLAYING_EVENTS
end

--[[
	On receiving a note-on trigger on channel 2 then play all chord notes that are currently in the buffer
	Record all notes that are going to be emitted in the "playedEvents" table
	@param triggerEvent the triggering midi.Event 
	@param chordNoteIndex1Based index in the chordEvents table (1 based)
	@param octaveOffset octave offset to apply
 ]]--
local function playChordNote(triggerEvent, chordNoteIndex1Based, octaveOffset)
	-- 1st copy all note on's from chord to played events
	-- 2nd copy all played event to buffer to actually play
	-- paranoia - start with a stop chord to start with clean everything
	local when = (triggerEvent.time > 0) and (triggerEvent.time-1) or 0
	stopChordNote(when, chordNoteIndex1Based, octaveOffset)
	local noteEventAtChordIndex = getChordEventByIndex(chordNoteIndex1Based)
	LOG.debug("Play chord note: Size=",#CHORD_EVENTS,"; note=",chordNoteIndex1Based,"; octave=",octaveOffset)
	if noteEventAtChordIndex == nil then
		return
	end
	local nuEvt = midi.Event.noteOn(
		2,
		noteEventAtChordIndex:getNote() + octaveOffset,
		noteEventAtChordIndex:getVel(),
		when)
	CURRENT_BLOCK_EVENTS[#CURRENT_BLOCK_EVENTS+1] = nuEvt
	PLAYING_EVENTS[#PLAYING_EVENTS+1] = nuEvt
end

--[[

	On receiving a note-on trigger on channel 1 take the note and add it to the buffer "chordEvents"
 ]]--
local function insertChordNote(root)
	-- register a note as to be played
	local note = root:getNote()
	local newEvt = midi.Event.noteOn(
			root:getChannel(),
			note,
			root:getVel())
	print("Before add: Size="..#CHORD_EVENTS.."; note="..tostring(note))
	CHORD_EVENTS[ #CHORD_EVENTS+1 ] = newEvt
	table.sort(CHORD_EVENTS, function(a,b) return a:getNote() < b:getNote() end)
	print("After add: Size="..#CHORD_EVENTS)
end

--[[
	On receiving a note-off trigger on channel 1 take the note and remove it from the buffer "chordEvents"
 ]]--
function removeChordNote(root)
	-- deregister a note as to be played
	local note = root:getNote()
	LOG.debug("Before remove: Size=",#CHORD_EVENTS)
	array_remove(CHORD_EVENTS, function(t,i) return t[i]:getNote() ~= note end)
	LOG.debug("After  remove: Size=",#CHORD_EVENTS)
end


--
-- Listen to changes of Global settings
--
local function listenToGlobalsChange(inGlobalEvent)
	if "IS-PLAYING" == inGlobalEvent.type and inGlobalEvent.oldValue == true and inGlobalEvent.newValue == false then
		-- stop all playing notes
		LOG.debug("Stopping all playing notes because transport stopped. Count=",#PLAYING_EVENTS)
		local when = 0
		for i=1,#PLAYING_EVENTS do
			local playedEvt = PLAYING_EVENTS[i]
			LOG.debug("   Stop chord note: Note=",tostring(playedEvt))
			local nuEvt = midi.Event.noteOff(
				2,
				playedEvt:getNote(),
				playedEvt:getVel(),
				when)
			-- add the nu note off event into the buffer  
			CURRENT_BLOCK_EVENTS[#CURRENT_BLOCK_EVENTS+1] = nuEvt
		end
		-- now clear playing events
		PLAYING_EVENTS = {}
	end
end
GLOBALS:addEventListener( function(inEvent) listenToGlobalsChange(inEvent) end)

function plugin.processBlock(samples, smax, midiBuf)
	-- ---------------------
	-- PLEASE NOTE: THE IMPLEMNTATION IS NOT 100% ROCK SOLID YET. IT MIGHT CAUSE HANGING NOTES IN CERTAIN SITUATIONS.
	-- THE PROCESSING ORDER OF EVENTS IS NOT 100% CORRECT YET.
	-- The buffer should be processed on a "time" basis first and for each point in time 
	-- the ordering of events should be 1.) chord note-off, 2.) pattern off/on, 3.) chord note-on, see the plugin puh-arp
	-- 
	-- ---------------------	
	CURRENT_BLOCK_EVENTS = {}
	local pluginPosition = plugin.getCurrentPosition()
    GLOBALS:updateDAWGlobals(samples, smax+1, midiBuffer, pluginPosition)
    -- PRocessing midi events in order
	-- first we have to copy all events because we need to sort the processing in a very particular order
	-- that is because the DAW might provide events sorted by channel. 
	-- What does that mean: 
	-- * If rhythm events are processed before the chord events are registered, then nothing gonna be played
    -- * If chord events are changed before the note off arrived of a rhythm event, the derived not might get stuck
	local tempEventBuffer = {}
	for ev in midiBuf:eachEvent() do
		tempEventBuffer[#tempEventBuffer+1] = midi.Event(ev)
	end
	--[[ if GLOBALS:isDawPlaying() then
		LOG.debug("plugin.processBlock: Number of incoming events: ",#tempEventBuffer)
		for i=1,#tempEventBuffer do
			LOG.debug("   Event[",i,"]: ",tempEventBuffer[i]:getChannel())
		end
	end ]]
	-- now process all events for note off of the pattern, i.e. channel 16
	-- the means we prevent hanging notes when chord changes happen
	for i=1,#tempEventBuffer do
		local ev = tempEventBuffer[i]
		local cha = ev:getChannel()
		if(cha == 16) and ev:isNoteOff() then
			-- now first compute the INDEX in the CHORD Store based on incoming note relative to root note
			-- so if we have base note nr 24 
			local relativeNoteIndex = ev:getNote() - RHYTHM_ROOT_NOTE
			-- now please keep in mind that this might even come with a "octave" offset
			-- if somebody feeds in note 36, then we have relativeNoteIndex = 12, which means use the chord note 0 but one octave up
			local octaveOffset = floor(relativeNoteIndex / 12) * 12
			local chordNoteIndex1Based = abs(relativeNoteIndex % 12) + 1
			-- stop chord note
			stopChordNote(ev.time, chordNoteIndex1Based, octaveOffset)
		end
	end
	--now we can proceed with all channel 16 events
	for i=1,#tempEventBuffer do
		-- Channel 1 processing: It's for the chord notes
		local ev = tempEventBuffer[i]
		local cha = ev:getChannel()
		if(cha == 1) then
			if (ev:isNoteOn()) then
				insertChordNote(ev)
			elseif (ev:isNoteOff() ) then 
				-- please note - don't filter based on noteFamily. It might cause hanging notes when param is changed
				removeChordNote(ev)
			end
		end
	end
	for i=1,#tempEventBuffer do
		local ev = tempEventBuffer[i]
		local cha = ev:getChannel()
		if(cha == 16) and ev:isNoteOn() then
			-- now first compute the INDEX in the CHORD Store based on incoming note relative to root note
			-- so if we have base note nr 24 
			local relativeNoteIndex = ev:getNote() - RHYTHM_ROOT_NOTE
			-- now please keep in mind that this might even come with a "octave" offset
			-- if somebody feeds in note 36, then we have relativeNoteIndex = 12, which means use the chord note 0 but one octave up
			local octaveOffset = floor(relativeNoteIndex / 12) * 12
			local chordNoteIndex1Based = abs(relativeNoteIndex % 12) + 1
			playChordNote(ev, chordNoteIndex1Based, octaveOffset)
		end
	end
	-- fill midi buffer with prepared notes
	midiBuf:clear()
	if #CURRENT_BLOCK_EVENTS>0 then
		for i=1,#CURRENT_BLOCK_EVENTS do
			midiBuf:addEvent(CURRENT_BLOCK_EVENTS[i])
		end
	end
end