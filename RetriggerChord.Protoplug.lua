--[[
name: Chord Retriggerer
description: rerigger chords which are recorded on channel 1 by notes coming in on channel 2
author: https://github.com/huberp
--]]

require "include/protoplug"

-- all events that are currently playing, an array
local playedEvents = {}
-- all recorded chord events, a hashtable with key midid note number
local chordEvents = {}
-- all stuff that needs to be emitted in the current frame, an array
local blockEvents = {}

function plugin.processBlock(samples, smax, midiBuf)
	blockEvents = {}
	-- analyse midi buffer and prepare a chord for each note
	for ev in midiBuf:eachEvent() do
		-- Channel 1 processing: It's for the chord notes
		if(ev:getChannel() == 1) then
			if (ev:isNoteOn()) then
				insertChordNote(ev)
			elseif (ev:isNoteOff() ) then 
				-- please note - don't filter based on noteFamily. It might cause hanging notes when param is changed
				removeChordNote(ev)
			end
		-- Channel 2 processing: Get "triggers" and play the chords that are currently in the buffer
		elseif(ev:getChannel() == 2) then
			if (ev:isNoteOn()) then
				playChord(ev)
			elseif (ev:isNoteOff() ) then 
				-- please note - don't filter based on noteFamily. It might cause hanging notes when param is changed
				stopChord(ev.time)
			end	
		end
	end
	-- fill midi buffer with prepared notes
	midiBuf:clear()
	if #blockEvents>0 then
		for _,e in ipairs(blockEvents) do
			midiBuf:addEvent(e)
		end
	end
end

--[[
	On receiving a note-on trigger on channel 2 then play all chord notes that are currently in the buffer
	Record all notes that are going to be emitted in the "playedEvents" table
 ]]--
function playChord(triggerEvent)
	-- 1st copy all note on's from chord to played events
	-- 2nd copy all played event to buffer to actually play
	-- paranoia - start with a stop chord to start with clean everything
	local when = (triggerEvent.time > 0) and (triggerEvent.time-1) or 0 
	stopChord(when)
	local i = 1
	for _,chordEvt in pairs(chordEvents) do
		local nuEvt = midi.Event.noteOn(
			chordEvt:getChannel(),
			chordEvt:getNote(),
			chordEvt:getVel(),
			when)
		playedEvents[i] = nuEvt
		i = i + 1
		table.insert(blockEvents,nuEvt)
	end
end

--[[
	On receiving a note-off trigger on channel 2 then stop all "playedEvents"
	"playedEvents" will be empty after returning
 ]]--
function stopChord(when)
	for i=1,#playedEvents do
		local playedEvt = playedEvents[i]
		local nuEvt = midi.Event.noteOff(
			playedEvt:getChannel(),
			playedEvt:getNote(),
			playedEvt:getVel(),
			when)
		table.insert(blockEvents,nuEvt)
	end
	playedEvents = {}
end

--[[
	simple helper function which computes the size of a hashtable (not an array)
 ]]--
function sizeOf(hashMap)
	local size = 0
	for _ in pairs(hashMap) do size = size + 1 end
	return size
end

--[[
	On receiving a note-on trigger on channel 1 take the note and add it to the buffer "chordEvents"
 ]]--
function insertChordNote(root)
	-- register a note as to be played
	local test = {}
	local note = root:getNote()
	local newEvt = midi.Event.noteOn(
			root:getChannel(),
			root:getNote(),
			root:getVel())
	print("Before add: Size="..sizeOf(chordEvents).."; note="..tostring(note))
	local key = tostring(note)
	chordEvents[ key ] = newEvt
	print("After add: Size="..sizeOf(chordEvents).."; key:"..key.."; key type="..type(key))
end

--[[
	On receiving a note-off trigger on channel 1 take the note and remove it from the buffer "chordEvents"
 ]]--
function removeChordNote(root)
	-- deregister a note as to be played
	local note = root:getNote()
	print("Before remove: Size="..#chordEvents)
	chordEvents [ tostring(note) ] = nil
	print("After remove: Size="..#chordEvents)
	-- could be that still some note of this pitch is playing (i.e. in playedEvents)
	-- we decide to remove it immediately and not only on the next "note-off"
	if( playedEvents[note] ~= nil) then
		local newEv = midi.Event.noteOff(
			root:getChannel(),
			note,
			0,
			root.time)
		playedEvents[note] = nil
	end
end