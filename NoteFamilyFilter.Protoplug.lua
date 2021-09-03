--[[
name: midi note family filter
description: MIDI processor VST/AU. Notes go in, only Notes of a certain family come out
author: https://github.com/huberp
--]]

require "include/protoplug"

-- what kind of notes https://musicinformationretrieval.com/midi_conversion_table.html?
-- we define here a set of note families by a ground note which is reresented by noteNumer % 12
-- because all D's across the keyboard have the same modulo 12 value. So there's no need to enumerate all D's
-- note 	midi-ET 	Hertz-ET 	midi-PT 	Hertz-PT

local Cb0 = { "Cb0",	11%12, 	15.434, 	10.804, 	15.261 }
local C0  = { "C0",		12%12, 	16.352, 	11.941, 	16.296 }
local Db0 = { "C#0/Db0",	13%12, 	17.324, 	12.844, 	17.168}
--local Cs0 = { "C#0",	13%12, 	17.324, 	13.078, 	17.402}
local D0  = { "D0",		14%12, 	18.354, 	13.980, 	18.333}
local Eb0 = { "D#0/Eb0",	15%12, 	19.445, 	14.883, 	19.314}
--local Ds0 = { "D#0",	15%12, 	19.445, 	15.117, 	19.578}
--local Fb0 = { "Fb0",	16%12, 	20.602, 	15.785, 	20.347}
local E0  = { "E0/Fb0",		16%12, 	20.602, 	16.020, 	20.625}
local F0  = { "F0/E#0",		17%12, 	21.827, 	16.922, 	21.728}
--local Es0 = { "E#0",	17%12, 	21.827, 	17.156, 	22.025}
local Gb0 = { "F#0/Gb0",	18%12, 	23.125, 	17.824, 	22.891}
--local Fs0 = { "F#0",	18%12, 	23.125, 	18.059, 	23.203}
local G0  = { "G0",		19%12, 	24.5, 		18.961, 	24.444}
local Ab0 = { "G#0/Ab0",	20%12, 	25.957, 	19.863, 	25.752}
--local Gs0 = { "G#0",	20%12, 	25.957, 	20.098, 	26.104}
local A0  = { "A0",		21%12, 	27.5, 		21.000, 	27.5}
local Bb0 = { "A#0/Bb0",	22%12, 	29.135, 	21.902, 	28.971}
--local As0 = { "A#0",	22%12, 	29.135, 	22.137, 	29.366}

families = { Cb0, C0, Db0, D0, Eb0,  E0, F0, Gb0,  G0, Ab0,  A0, Bb0 }

selectedNoteFamily = D0

local blockEvents = {}

function plugin.processBlock(samples, smax, midiBuf)
	blockEvents = {}
	-- analyse midi buffer and prepare a chord for each note
	for ev in midiBuf:eachEvent() do
		--print (ev:getNote()%12)
		--print (selectedNoteFamily[2])
		if (ev:isNoteOn() and ev:getNote()%12 == selectedNoteFamily[2]) then
		    insertNoteOn(ev)
		elseif (ev:isNoteOff() ) then 
		    -- please note - don't filter based on noteFamily. It might cause hanging notes when param is changed
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

-- based on the family name of the parameter set the selectedFamily
function updateFamily(arg)
  for i,s in ipairs(families) do
    if(arg==s[1]) then
      --print("selected: ".. arg)
      selectedNoteFamily=s
    end
  end 
end

-- function to get all familyNames of the table of all families
function familyNames()
  local tbl = {}
  for i,s in ipairs(families) do
    --print(s[1])
    table.insert(tbl,s[1]) 
  end 
  return tbl
end

params = plugin.manageParams {
	{
		name = "Family";
		type = "list";
		values = familyNames();
		default = familyNames()[1];
		changed = function(val) updateFamily(val) end;
	};

}

