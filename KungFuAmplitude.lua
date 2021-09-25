--[[
name: Sync stuff to the clock
description: how easy it is to do stuff based on muical counts
author: ] Peter:H [
--]]
require "include/protoplug"

lengthModifiers = {
	normal = 1.0;
	dotted = 3.0/2.0;
	triplet = 2.0/3.0;
}

-- ppq is based on 1/4 notes
ppqBaseValue = {
	noteNum = 1.0;
	noteDenom = 4.0;
}

-- actually this is exactly 1/4 based, i.e. the base ppq is computed
noteLength1 = {
	noteNum = 1.0;
	noteDenom = 4.0;
	lengthModifier = lengthModifiers.normal;
}

-- a definition of a lane that is based on 1/8 notes. 
noteLength2 = {
	noteNum = 1.0;
	noteDenom = 8.0;
	lengthModifier = lengthModifiers.normal;
}

selectedNoteLen = noteLength2

 
globalSamplesCount = 0;

globalSampleRate = -1;


function plugin.processBlock (samples, smax) -- let's ignore midi for this example
	position = plugin.getCurrentPosition();
	globalSamplesCount = globalSamplesCount + smax;
	--
	-- preset samplesToNextCount;
	samplesToNextCount = -1
	
	-- compute stuff
	-- 1. length in milliseconds of the selected noteLength
	noteLenInMsec = noteLength2Milliseconds(selectedNoteLen, position.bpm);
	-- 2. length of a slected noteLength in samples 
	noteLenInSamples = noteLength2Samples(noteLenInMsec, globalSampleRate);
	
	if #sigmoid == 0 then
		init(noteLenInSamples)
	end
	
	if position.isPlaying then
		-- 3. "ppq" of the specified notelen ... if we don't count 1/4 we have to count more/lesse depending on selected noteLength
		ppqOfNoteLen  = position.ppqPosition * quater2selectedNoteFactor(selectedNoteLen);
		-- 4. the delta in "ppq" relative to the selected noteLength
		deltaToNextCount = math.ceil(ppqOfNoteLen) - ppqOfNoteLen;
		-- 5. the number of samples that is delta to the next count based on selected noteLength
		samplesToNextCount = deltaToNextCount * noteLenInSamples;
		
		-- NOTE: if  samplesToNextCount < smax then what ever you are supposed to start has to start in this frame!
		if samplesToNextCount < smax then
			print("Playing - ppq: " .. position.ppqPosition .. " 1/8 base ppq: " .. ppqOfNoteLen.. "("..noteLenInMsec..") --> "..samplesToNextCount);
		end
	else 
		-- in none playing mode we don't have the help of the ppq... we have to do heuristics by using the globalSamples...
		-- 3. a heuristically computed position based on the samples
		noteCount = globalSamplesCount / noteLength2Samples(noteLenInMsec, globalSampleRate)
		-- 4. the delta to the count
		deltaToNextCount = math.ceil(noteCount) - noteCount;
		-- 5. the number of samples that is delta to the next count based on selected noteLength
		samplesToNextCount = deltaToNextCount * noteLenInSamples;
		
		if samplesToNextCount < smax then
			print("NOT Playing - global samples: " .. globalSamplesCount .. " 1/8 base count: " .. noteCount.. "("..noteLenInMsec..") --> "..samplesToNextCount);
		end
	end
	
	-- post condition here: samplesToNextCount != -1
	
    for i = 0, smax do
		if i >= samplesToNextCount then
			init(noteLenInSamples);
		else
			progress();
		end
        samples[0][i] = apply(samples[0][i]) -- left channel
        samples[1][i] = apply(samples[1][i])  -- right channel
           
    end
end

--
--
-- Helpers computing note timing
--
--

-- ppq is based on 1/4. now say we want rather count in 1/8 - we have to count twice as much... (1/4) / (1/8) 
-- but keep in mind that a.) there could be 2/8 or even 3/8 and b.) there could be triplets or dotted as well.
-- this function will give you the appropriate relation-factor to multiply with ppq, or msec, or samplesPerNote.
function quater2selectedNoteFactor(inNoteLength) 
	return (ppqBaseValue.noteNum * inNoteLength.noteDenom) / (ppqBaseValue.noteDenom * inNoteLength.noteNum * inNoteLength.lengthModifier);
end

-- It's based on the formular for quarters into seconds, i.e. 60/BPM
-- this here is then giving milliseconds (1000) and can compute based on any given noteLength. So for 1/4 to get the 60 we have to start with 240...
-- and we even don't forget modifiers, i.e. dotted and triplet...
function noteLength2Milliseconds(inNoteLength, inBPM)
	--return (1000 * 240 * (inNoteLength.noteNum / inNoteLength.noteDenom) * inNoteLength.lengthModifier) / inBPM;
	return (240000.0 * (inNoteLength.noteNum / inNoteLength.noteDenom) * inNoteLength.lengthModifier) / inBPM;
end

-- Have a conversion function to get samples per noteLenght
-- assume we have rate = 48000 samples/second, that is rate/1000 as samples per millisecond.
-- then just multiplay the length in milliseconds based on the current beat.
function noteLength2Samples(inNoteLengthInMsec, inSampleRate)
	return (inSampleRate / 1000.0) * inNoteLengthInMsec;
end

--
--
-- Define Process
--
--

maxSample = -1
currentSample = -1
delta = -1
sigmoid = {}

function init(noteLenInSamples) 
	maxSample = math.floor(noteLenInSamples+1);
	currentSample = 0;
	delta = (6 - (-6)) / maxSample;
	if #sigmoid == 0 then
		for i=0,maxSample+2 do
			t = -6 + i*delta;
			sigmoid[i] = 1 / (1+math.exp(-t));
		end
	end
	print("INIT ".. #sigmoid .. " maxSample: "..maxSample)
end

function progress()
	currentSample =  currentSample + 1;
end

function apply(inSample)
	--print("Sig: "..currentSample)
	return sigmoid[currentSample] * inSample;
end


local function prepareToPlayFct()
	globalSampleRate = plugin.getSampleRate();
	--print("Sample Rate:"..globalSampleRate)
end

plugin.addHandler("prepareToPlay", prepareToPlayFct);


params = plugin.manageParams {
	{
		name = "Power";
		min = 1;
		max = 0.01;
		changed = function (val) power = val end;
	};
}