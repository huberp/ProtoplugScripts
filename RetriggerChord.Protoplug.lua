--[[
name: Chord Retirggerer
description: rerigger chords which are recorded on channel 1 by notes coming in on channel 2
author: https://github.com/huberp
--]]

require "include/protoplug"

-- all events that are currently playing
local playedEvents = {}
-- all recorded chord events
local chordEvents = {}
-- all stuff that needs to be emitted in this frame
local blockEvents = {}

function plugin.processBlock(samples, smax, midiBuf)
	blockEvents = {}
	-- analyse midi buffer and prepare a chord for each note
	for ev in midiBuf:eachEvent() do
		--print (ev:getNote()%12)
		--print (selectedNoteFamily[2])
		if(ev:getChannel() == 1) then
			if (ev:isNoteOn()) then
				insertChordNote(ev)
			elseif (ev:isNoteOff() ) then 
				-- please note - don't filter based on noteFamily. It might cause hanging notes when param is changed
				removeChordNote(ev)
			end	
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

function playChord(triggerEvent)
	-- 1st copy all note ons from chord to played events
	-- 2nd copy all played event to buffer to actually play
	-- paranoia - start with a stop chord to start with clean everything
	local when = (triggerEvent.time > 0) and (triggerEvent.time-1) or 0 
	stopChord(when)
	for i=1,#chordEvents do
		local chordEvt = chordEvents[i]
		local nuEvt = midi.Event.noteOn(
			chordEvt:getChannel(),
			chordEvt:getNote(),
			chordEvt:getVel(),
			triggerEvent.time)
		playedEvents[i] = nuEvt
		table.insert(blockEvents,nuEvt)
	end
end

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
end

function insertChordNote(root)
	-- register a note as to be played
	local note = root:getNote()
	local newEv = midi.Event.noteOn(
			root:getChannel(),
			root:getNote(),
			root:getVel())
	table.insert(chordEvents, newEv)
end

function removeChordNote(root)
	-- deregister a note as to be played
	local note = root:getNote()
	table.remove(chordEvents, note)
	-- could be that still some note of this pitch is playing
	-- we decide to remove it immediately and not only on the next "note-off"
	if( playedEvents[note] ~= nil) then
		local newEv = midi.Event.noteOff(
			root:getChannel(),
			note,
			0,
			root.time)
	end
end