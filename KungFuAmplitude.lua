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


globals = {
	samplesCount = 0;
	sampleRate = -1;
	isPlaying = false;
} 

--
--
-- GUI Definitions
--
--
local frame1 = juce.Rectangle_int (100,10,900,450);
local xmin = frame1.x;
local ymin = frame1.y+frame1.h;
local col1 = juce.Colour(0,255,0,128);
local col2 = juce.Colour(255,0,0,128);
local cols = { col2, col1 };
local db1 = juce.Image(juce.Image.PixelFormat.ARGB, frame1.w, frame1.h, true);
local db2 = juce.Image(juce.Image.PixelFormat.ARGB, frame1.w, frame1.h, true);
local dbufPaint = { [0] = db1, [1] = db2 }
local dbufIndex = 0;
--
--
--MAIN LOOPGUI Definitions
--
--
local runs = 0;
local lastppq = 0;
function plugin.processBlock (samples, smax) -- let's ignore midi for this example
	position = plugin.getCurrentPosition();
	--
	-- preset samplesToNextCount;
	samplesToNextCount = -1
	
	-- compute stuff
	-- 1. length in milliseconds of the selected noteLength
	noteLenInMsec = noteLength2Milliseconds(selectedNoteLen, position.bpm);
	-- 2. length of a slected noteLength in samples 
	noteLenInSamples = noteLength2Samples(noteLenInMsec, globals.sampleRate);
	
	if #process.sigmoid == 0 then
		init(noteLenInSamples)
	end
	
	if position.isPlaying then
		-- 3. "ppq" of the specified notelen ... if we don't count 1/4 we have to count more/lesse depending on selected noteLength
		ppqOfNoteLen  = position.ppqPosition * quater2selectedNoteFactor(selectedNoteLen);
		-- 4. the delta in "ppq" relative to the selected noteLength
		deltaToNextCount = math.ceil(ppqOfNoteLen) - ppqOfNoteLen;
		-- 5. the number of samples that is delta to the next count based on selected noteLength
		samplesToNextCount = math.ceil(deltaToNextCount * noteLenInSamples);
		
		initAt(samplesToNextCount, noteLenInSamples)
		
		if not isPlaying then
			isPlaying = true;
		end
		
		print((ppqOfNoteLen - lastppq)*noteLenInSamples);
		
		-- NOTE: if  samplesToNextCount < smax then what ever you are supposed to start has to start in this frame!
		if samplesToNextCount < smax then
			print("Playing: runs="..runs.."; ppq=" .. position.ppqPosition .. "; 1/8 base ppq=" .. ppqOfNoteLen.. "( "..noteLenInSamples.." ); samplesToNextCount="..samplesToNextCount.."; maxSample=".. process.maxSample .."; currentSample="..process.currentSample.."; smax="..smax);
		end
		if process.currentSample + samplesToNextCount > process.maxSample then
			print("Warning: runs="..runs.."; ppq=" .. position.ppqPosition .. "; 1/8 base ppq=" .. ppqOfNoteLen.. "( "..noteLenInSamples.." ); samplesToNextCount="..samplesToNextCount.."; maxSample=".. process.maxSample .."; currentSample="..process.currentSample.."; smax="..smax);
			k = j[0]/1.0;
		end
		runs = runs +1;
		lastppq = ppqOfNoteLen;
	else 
		-- in none playing mode we don't have the help of the ppq... we have to do heuristics by using the globalSamples...
		-- 3. a heuristically computed position based on the samples
		noteCount = globals.samplesCount / noteLenInSamples;
		-- 4. the delta to the count
		deltaToNextCount = math.ceil(noteCount) - noteCount;
		-- 5. the number of samples that is delta to the next count based on selected noteLength
		samplesToNextCount = math.ceil(deltaToNextCount * noteLenInSamples);
		
		if isPlaying then
			initAt(samplesToNextCount, noteLenInSamples)
			isPlaying = false;
		end
		
		if samplesToNextCount < smax then
			print("NOT Playing - global samples: " .. globals.samplesCount .. " 1/8 base count: " .. noteCount.. "("..noteLenInSamples..") --> "..samplesToNextCount.." process.currentSample:" .. process.currentSample);
		end
	end
	
	-- post condition here: samplesToNextCount != -1
	
    for i = 0, smax do
		if i == samplesToNextCount then
		
			local guiComp = gui:getComponent();
			if guiComp and process.currentSample > 0 then
				createImage();
				guiComp:repaint(frame1);
			end
			
			init(noteLenInSamples);
		else
			if not progress() then
				print("Warning i: "..i.."; samplesToNextCount: "..samplesToNextCount)
			end
		end
        samples[0][i] = apply(samples[0][i]) -- left channel
        samples[1][i] = apply(samples[1][i]) -- right channel    
    end
	globals.samplesCount = globals.samplesCount + smax + 1;
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
process = {
	maxSample = -1;
	currentSample = -1;
	delta = -1;
	sigmoid = {};
	bufferUn = {};
	bufferProc = {};
}

function init(noteLenInSamples) 
	process.maxSample = math.ceil(noteLenInSamples);
	process.currentSample = 0;
	process.delta = (6 - (-6)) / process.maxSample;
	if #process.sigmoid == 0 then
		initSigmoid(noteLenInSamples);
	end
	print("INIT: sig="..#process.sigmoid.."; maxSample=".. process.maxSample .."; currentSample="..process.currentSample);
end

function initAt(samplesToNextCount, noteLenInSamples) 
	process.maxSample = math.ceil(noteLenInSamples);
	if 0 == samplesToNextCount then
		process.currentSample = 0;
	else 
		process.currentSample = process.maxSample - samplesToNextCount;
	end
	process.delta = (6 - (-6)) / process.maxSample;
	if #process.sigmoid == 0 then
		initSigmoid(noteLenInSamples);
	end
	--print("INIT-AT: sig="..#process.sigmoid.."; maxSample=".. process.maxSample .."; currentSample="..process.currentSample.."; samplesToNextCount="..samplesToNextCount);
	
	if process.currentSample + samplesToNextCount > noteLenInSamples then
		print("INIT-AT: Warning - ppq=" .. position.ppqPosition .. "; 1/8 base ppq=" .. ppqOfNoteLen.. "( "..noteLenInSamples.." ); samplesToNextCount="..samplesToNextCount.."; maxSample=".. process.maxSample .."; currentSample="..process.currentSample);
	end
	
end 


function initSigmoid(noteLenInSamples) 
	if #process.sigmoid == 0 then
		for i=0,process.maxSample+10 do
			t = -6 + i*process.delta;
			process.sigmoid[i] = 1 / (1+math.exp(-t));
		end
	end
	print("INIT Sigmoid ".. #process.sigmoid .. " process.maxSample: "..process.maxSample)
end


function progress()
	process.currentSample =  process.currentSample + 1;
	if(#process.sigmoid <= process.currentSample) then
		print("Warning! progress: sig="..#process.sigmoid.."; maxSample=".. process.maxSample .."; currentSample="..process.currentSample)
		return false;
	end
	return true;
end

function apply(inSample)
	--print("Sig: "..process.currentSample)
	if(#process.sigmoid <= process.currentSample) then
		print("Warning! apply: sig="..#process.sigmoid.."; maxSample=".. process.maxSample .."; currentSample="..process.currentSample)
	end
	local result = process.sigmoid[process.currentSample] * inSample;
	process.bufferUn[process.currentSample] = inSample;
	process.bufferProc[process.currentSample] = result;
	return result;
end


local function prepareToPlayFct()
	globals.sampleRate = plugin.getSampleRate();
	--print("Sample Rate:"..global.sampleRate)
end

plugin.addHandler("prepareToPlay", prepareToPlayFct);



--
--
-- GUI Routine
--
--

function createImage() 
	dbufIndex = 1-dbufIndex;
	local img = dbufPaint[dbufIndex];
	local imgG = juce.Graphics(img);
    imgG:fillAll();
	imgG:setColour (juce.Colour.green)
    --imgG:drawRect (frame1)
	if process.maxSample > 0 then
		local delta = frame1.w / process.maxSample;
		local compactSize = math.floor(process.maxSample / frame1.w);
		if compactSize < 1 then compactSize=1 end;
		local buffers = {process.bufferUn, process.bufferProc};
		for i=1,#buffers do
			local b = buffers[i];
			imgG:setColour (cols[i]);
			for i=0,#b,compactSize do
				local x = i*delta;
				local samp = math.abs(b[i]);
				imgG:drawLine(x,frame1.h,x,frame1.h-samp*frame1.h)
			end
		end
	end
end


function gui.paint (g)
	g:fillAll ();
	local img = dbufPaint[dbufIndex];
	g:drawImageAt(img, frame1.x, frame1.y);
end

--
--
-- Params
--
--
params = plugin.manageParams {
	{
		name = "Power";
		min = 1;
		max = 0.01;
		changed = function (val) power = val end;
	};
}