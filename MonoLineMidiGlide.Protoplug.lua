--[[
name: Chord Retriggerer
description: rerigger chords which are recorded on channel 1 by notes coming in on channel 2
author: https://github.com/huberp
--]]

require "include/protoplug"

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

local m_floor = math.floor
local m_ceil = math.ceil

function m_round(val)
	local fl = m_floor(val)
	if val - fl < 0.5 then return fl end
	return m_ceil(val)
end

-- all events that are currently playing, an array
local playedEvents = {}
-- all recorded chord events, a hashtable with key midid note number
local noteStack = {}
-- all stuff that needs to be emitted in the current frame, an array
local blockEvents = {}

local sampleCounter = 0

local currentGlide = nil

-- mode: legato glide
-- already note A pressed, new note B is coming in: Difference A-B
--    if difference is zero - do nothing fancy
--    compute the steps A --> B; remember "return note" A
--    execute the steps A --> B; first note-off for A
--         when A is unpressed: remove return note
--         when B is unpressed, let's say we are at note C in current process: 
--				no return note: stop playing
--				return note: stop current process and start new process C -> return note
-- 		   when no A or B: do nothing
-- 
-- mode: always glide
--
local GlideProcess = {}
-- incoming are note events
-- this ctor takey tables with { evt=noteEvent, note=the note, sampleCounter=counted number of samples}, see addNote
function GlideProcess:new(inNoteA, inNoteB)
	local o = {
		noteA = inNoteA,
		noteB = inNoteB,
		position=1;
	}
	local steps = {}
	--
	local numberSteps = 9
	-- strategy 1: play each note regardless of how far the distance is
	-- local numberSteps = math.abs(noteB-noteA)+1
	-- local delta = (noteB-noteA > 0) and 1 or -1
	-- strategy 2: play only 8 steps fixed
	local nA = inNoteA.note
	local nB = inNoteB.note
	local deltaN = (nB-nA) / (numberSteps-1)
	o.deltaN = deltaN
	--
	local vA = inNoteA.vel
	local vB = inNoteB.vel
	local deltaV = (vB-vA) / (numberSteps-1)
	o.deltaV = deltaV
	--
	-- compute numberSteps steps of notes and velocity from start to target
	for i=1, numberSteps+1 do
		steps[i] = {
			note = m_round(nA + (i-1) * deltaN),
			vel =  m_round(vA + (i-1) * deltaV),
			cha = inNoteA.cha
		}
	end
	-- only for precautions .. in some cases rounding off might not get us to the final note
	steps[#steps] = {
		note=nB,
		vel=vB
	}
	o.numberSteps = numberSteps
	o.steps = steps
	setmetatable(o, self)
	self.__index = self
	o:randomize()
	return o
end
function GlideProcess:currentAndNext()
	local pos = self.position
	local valueCurrent = self.steps[pos]
	--next line needs controll
	local valueNext = self.steps[pos+1]
	self.position = pos+1
	return valueCurrent, valueNext;
end
function GlideProcess:getCurrent()
	return self.steps[self.position]
end
function GlideProcess:hasNext()
	return self.position < self.numberSteps
end
function GlideProcess:compareNote(inNoteEvt)
	local note = inNoteEvt:getNote()
	return (note == self.noteA.note), (note == self.noteB.note)
end

local rand = math.random

function GlideProcess:randomize()
	local steps = self.steps
	if #steps <= 2 then return end
	-- now kind of randomize the steps, but leave 1st and last step untouched
	for i=2,#steps-3 do
		if rand() > 0.5 then
			local val = steps[i+1]
			steps[i+1] = steps[i]
			steps[i] = val
		end
	end
end


function printCurrentGlide(inID)
	print("ID="..inID.."; process="..toStringGlideProcess(currentGlide))
end

function toStringGlideProcess(inGP)
	return "GlideProcess: noteA="..inGP.noteA.note.."; noteB="..inGP.noteB.note.."; steps="..inGP.numberSteps.."; deltaN="..inGP.deltaN.."; deltaV="..inGP.deltaV
end

function toStringNoteTable(inNoteT)
	--print(serialize_list(inNoteT))
	return "note="..inNoteT.note.."; vel="..inNoteT.vel.."; cha="..inNoteT.cha
end

local count = 0

function plugin.processBlock(samples, smax, midiBuf)
	blockEvents = {}

	--
	if nil ~= currentGlide then
		if count % 4 == 0 then
			if currentGlide:hasNext() then
				local currentOFF,nextON = currentGlide:currentAndNext()
				print("Gliding: c:"..toStringNoteTable(currentOFF).."; n:"..toStringNoteTable(nextON))
				addGlideNotes(currentOFF,nextON)
			else
				print("Gliding: ended at="..currentGlide:getCurrent().note)
				--stopGlide(currentGlide)
				currentGlide = nil
			end
		end
		count = count + 1
	end

	-- analyse midi buffer and prepare a chord for each note
	for ev in midiBuf:eachEvent() do
		if (ev:isNoteOn()) then
			addNote(ev, sampleCounter)
			if #noteStack>1 then
				--in this case the latest added note is the glide target
				local noteB=noteStack[#noteStack]
				local noteA=nil
				if currentGlide == nil then
					-- there was no currentGlide
					noteA=noteStack[#noteStack-1]
				else
					-- there was a currentGlide, let's eee where it got stuck
					noteA=currentGlide:getCurrent()
				end
				currentGlide = GlideProcess:new(noteA, noteB)
				printCurrentGlide("from ON")
			else
				-- here we have not anything going... start with the first note
				insertNoteOn(ev)
			end
		elseif (ev:isNoteOff() ) then
			local numberBeforeOff = #noteStack
			removeNote(ev)
			if nil ~= currentGlide then
				if #noteStack==0 then
					currentGlide = nil
				else
					-- there's no glide going on, but the user has more than one note pressed
					-- that means (s)he has run through a glide and might now release a key.
					-- which would require us to react
					local cmpA, cmpB = currentGlide:compareNote(ev)
					print("GlideProcess CMP: cmpA="..tostring(cmpA).."; cmpB="..tostring(cmpB).."; gp="..toStringGlideProcess(currentGlide))
					if cmpB then
						--the glide target key has been removed but it seems the fallback key is still present
						--lets glide back
						print("OFF 1")
						stopGlide(currentGlide)
						currentGlide = GlideProcess:new(currentGlide:getCurrent(), currentGlide.noteA)
						printCurrentGlide("from OFF 1")
					end
				end
			else
				--current glide might be nil, but there might still be a return note held
				--lets get the next note
				if numberBeforeOff>1 then
					print("OFF 2")
					stopGlide(currentGlide)
					currentGlide = GlideProcess:new(getGlideElemFromNoteEvt(ev,sampleCounter), noteStack[#noteStack])
					printCurrentGlide("from OFF 2")
				end
			end 
			insertNoteOff(ev)
		end
	end
	-- fill midi buffer with prepared notes
	midiBuf:clear()
	if #blockEvents>0 then
		for _,e in ipairs(blockEvents) do
			midiBuf:addEvent(e)
		end
	end
	sampleCounter = sampleCounter+smax
end

function insertNoteOn(root)
	local newEv = midi.Event.noteOn(
		root:getChannel(), 
		root:getNote(), 
		root:getVel())
	table.insert(blockEvents, newEv)
end

function insertNoteOff(root)
	local newEv = midi.Event.noteOff(
		root:getChannel(), 
		root:getNote())
	table.insert(blockEvents, newEv)
end

function stopGlide(inGlide)
	if nil == inGlide then return end
	local offNote=inGlide:getCurrent()
	local off = midi.Event.noteOff(offNote.cha, offNote.note, 0, 1)
	table.insert(blockEvents, off)
end

function addGlideNotes(inOff, inOn)
	local off = midi.Event.noteOff(inOff.cha, inOff.note, 0, 1)
	table.insert(blockEvents, off)
	local on = midi.Event.noteOn  (inOn.cha,  inOn.note,  inOn.vel, 3)
	table.insert(blockEvents, on)
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
function addNote(inNoteEvt, inSampleCounter)
	-- register a note as to be played
	local nu = getGlideElemFromNoteEvt(inNoteEvt, inSampleCounter)
	print("Before add: Size="..#noteStack.."; nu="..serialize_list(nu))
	noteStack[#noteStack+1] = nu
	print("After add: Size="..#noteStack)
end

function getGlideElemFromNoteEvt(inNoteEvt, inSampleCounter)
	local note = inNoteEvt:getNote()
	local vel = inNoteEvt:getVel()
	local cha = inNoteEvt:getChannel()
	local pos = inNoteEvt.time
	local nu = { note = note, vel = vel, cha = cha, pos = pos, sampleCounter = inSampleCounter + pos }
	return nu
end

--[[
	On receiving a note-off trigger on channel 1 take the note and remove it from the buffer "chordEvents"
 ]]--
function removeNote(inNoteEvt)
	-- deregister a note as to be played
	local note = inNoteEvt:getNote()
	print("Before remove: Size="..#noteStack)
	local removeIdx = -1
	for i=1,#noteStack do
		if noteStack[i].note == note then
			removeIdx = i
			local value = table.remove(noteStack,i)
			break;
		end
	end
	print("After remove: Size="..#noteStack.."; removeIdx="..removeIdx)
	return value
end