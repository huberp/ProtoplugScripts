--[[
name: Sync stuff to the clock
description: how easy it is to do stuff based on muical counts
author: ] Peter:H [
--]]
require "include/protoplug"

--
--
--  Basic "counting time" definitions
--
--
lengthModifiers = {
	normal = 1.0;
	dotted = 3.0/2.0;
	triplet = 2.0/3.0;
}

-- ppq is based on 1/4 notes
ppqBaseValue = {
	noteNum = 1.0;
	noteDenom = 4.0;
	ratio = 0.25;
}

local _1over64 = { name= "1/64", ratio=1.0/64.0 };
local _1over32 = { name= "1/32", ratio=1.0/32.0 };
local _1over16 = { name= "1/16", ratio=1.0/16.0 };
local _1over8  = { name= "1/8",	 ratio=1.0/8.0 };
local _1over4  = { name= "1/4",	 ratio=1.0/4.0 };
local _1over2  = { name= "1/2",	 ratio=1.0/2.0 };
local _1over1  = { name= "1/1",	 ratio=1.0/1.0 };

--
--
--  Local Fct Pointer
--
--
mathToInt = math.ceil

--
--
--  Debug Stuff
--
--
function zilch() end;
local dbg = zilch


--
--
--MAIN LOOP 
--
--
local runs = 0;    -- just for debugging purpose. counts the number processBlock has been called
local lastppq = 0; --  use it to be able to compute the distance in samples based on the ppq delta from loop a to a+1
local selectedNoteLen = {
	ratio = _1over8.ratio;
	modifier = lengthModifiers.normal;
	ratio_mult_modifier = _1over8.ratio * lengthModifiers.normal;
}
local globals = {
	samplesCount = 0;
	sampleRate = -1;
	sampleRateByMsec = -1;
	isPlaying = false;
} 

function plugin.processBlock (samples, smax) -- let's ignore midi for this example
	position = plugin.getCurrentPosition();
	--
	-- preset samplesToNextCount;
	samplesToNextCount = -1
	
	-- compute stuff
	-- 1. length in milliseconds of the selected noteLength
	noteLenInMsec = noteLength2Milliseconds(selectedNoteLen, position.bpm);
	-- 2. length of a slected noteLength in samples 
	noteLenInSamples = noteLength2Samples(noteLenInMsec, globals.sampleRateByMsec);
	
	if #process.sigmoid == 0 then
		init(noteLenInSamples)
	end
	
	if position.isPlaying then
		-- 3. "ppq" of the specified notelen ... if we don't count 1/4 we have to count more/lesse depending on selected noteLength
		ppqOfNoteLen  = position.ppqPosition * quater2selectedNoteFactor(selectedNoteLen);
		-- 4. the delta in "ppq" relative to the selected noteLength
		deltaToNextCount = mathToInt(ppqOfNoteLen) - ppqOfNoteLen;
		-- 5. the number of samples that is delta to the next count based on selected noteLength
		samplesToNextCount = mathToInt(deltaToNextCount * noteLenInSamples);
		
		setAt(samplesToNextCount, noteLenInSamples)
		
		if not isPlaying then
			isPlaying = true;
		end
		
		-- next is debug stmt: computes the estimate of processed samples based on a difference of ppq between loops
		-- print((ppqOfNoteLen - lastppq)*noteLenInSamples);
		
		-- NOTE: if  samplesToNextCount < smax then what ever you are supposed to start has to start in this frame!
		if samplesToNextCount < smax then
			dbg("Playing: runs="..runs.."; ppq=" .. position.ppqPosition .. "; 1/8 base ppq=" .. ppqOfNoteLen.. "( "..noteLenInSamples.." ); samplesToNextCount="..samplesToNextCount.."; maxSample=".. process.maxSample .."; currentSample="..process.currentSample.."; smax="..smax);
		end
		if process.currentSample + samplesToNextCount > process.maxSample then
			dbg("Warning: runs="..runs.."; ppq=" .. position.ppqPosition .. "; 1/8 base ppq=" .. ppqOfNoteLen.. "( "..noteLenInSamples.." ); samplesToNextCount="..samplesToNextCount.."; maxSample=".. process.maxSample .."; currentSample="..process.currentSample.."; smax="..smax);
			k = j[0]/1.0;
		end
		runs = runs +1;
		lastppq = ppqOfNoteLen;
	else 
		-- in none playing mode we don't have the help of the ppq... we have to do heuristics by using the globalSamples...
		-- 3. a heuristically computed position based on the samples
		noteCount = globals.samplesCount / noteLenInSamples;
		-- 4. the delta to the count
		deltaToNextCount = mathToInt(noteCount) - noteCount;
		-- 5. the number of samples that is delta to the next count based on selected noteLength
		samplesToNextCount = mathToInt(deltaToNextCount * noteLenInSamples);
		
		if isPlaying then
			setAt(samplesToNextCount, noteLenInSamples);
			isPlaying = false;
		end
		
		if samplesToNextCount < smax then
			dbg("NOT Playing - global samples: " .. globals.samplesCount .. " 1/8 base count: " .. noteCount.. "("..noteLenInSamples..") --> "..samplesToNextCount.." process.currentSample:" .. process.currentSample);
		end
	end
	
	-- post condition here: samplesToNextCount != -1
	
    for i = 0, smax do
		if i == samplesToNextCount then
			repaintIt() 
			init(noteLenInSamples);
		else
			if not progress() then
				dbg("Warning i: "..i.."; samplesToNextCount: "..samplesToNextCount)
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
	return (ppqBaseValue.ratio) / (inNoteLength.ratio_mult_modifier);
end

-- It's based on the formular for quarters into seconds, i.e. 60/BPM
-- this here is then giving milliseconds (1000) and can compute based on any given noteLength. So for 1/4 to get the 60 we have to start with 240...
-- and we even don't forget modifiers, i.e. dotted and triplet...
function noteLength2Milliseconds(inNoteLength, inBPM)
	--return (1000 * 240 * (inNoteLength.noteNum / inNoteLength.noteDenom) * inNoteLength.lengthModifier) / inBPM;
	return (240000.0 * inNoteLength.ratio_mult_modifier) / inBPM;
end

-- Have a conversion function to get samples per noteLenght
-- assume we have rate = 48000 samples/second, that is rate/1000 as samples per millisecond.
-- then just multiplay the length in milliseconds based on the current beat.
function noteLength2Samples(inNoteLengthInMsec, inSampleRateByMsec)
	return inSampleRateByMsec * inNoteLengthInMsec;
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
	process.maxSample = mathToInt(noteLenInSamples);
	process.currentSample = 0;
	process.delta = (6 - (-6)) / process.maxSample;
	if #process.sigmoid == 0 then
		initSigmoid(noteLenInSamples);
	end
	dbg("INIT: sig="..#process.sigmoid.."; maxSample=".. process.maxSample .."; currentSample="..process.currentSample);
end

function setAt(samplesToNextCount, noteLenInSamples) 
	process.maxSample = mathToInt(noteLenInSamples);
	if 0 == samplesToNextCount then
		process.currentSample = 0;
	else 
		process.currentSample = process.maxSample - samplesToNextCount;
	end
	process.delta = (6 - (-6)) / process.maxSample;
	if #process.sigmoid == 0 then
		initSigmoid(process.maxSample);
	end
	--print("INIT-AT: sig="..#process.sigmoid.."; maxSample=".. process.maxSample .."; currentSample="..process.currentSample.."; samplesToNextCount="..samplesToNextCount);
	
	if process.currentSample + samplesToNextCount > process.maxSample then
		dbg("SET-AT: Warning - ppq=" .. position.ppqPosition .. "; 1/8 base ppq=" .. ppqOfNoteLen.. "( "..noteLenInSamples.." ); samplesToNextCount="..samplesToNextCount.."; maxSample=".. process.maxSample .."; currentSample="..process.currentSample);
	end
	
end 


function initSigmoid(sizeInSamples) 
	local expFct = math.exp
	if #process.sigmoid == 0 then
		for i=0,sizeInSamples+10 do
			t = -6 + i*process.delta;
			process.sigmoid[i] = 1 / (1+expFct(-t));
		end
	end
	dbg("INIT Sigmoid ".. #process.sigmoid .. " process.maxSample: "..process.maxSample)
end

function resetSigmoid()
	process.sigmoid = {};
end


function progress()
	process.currentSample =  process.currentSample + 1;
	if(#process.sigmoid <= process.currentSample) then
		dbg("Warning! progress: sig="..#process.sigmoid.."; maxSample=".. process.maxSample .."; currentSample="..process.currentSample)
		return false;
	end
	return true;
end

function apply(inSample)
	--print("Sig: "..process.currentSample)
	local currentSample = process.currentSample;
	if(#process.sigmoid <= currentSample) then
		dbg("Warning! apply: sig="..#process.sigmoid.."; maxSample=".. process.maxSample .."; currentSample="..currentSample)
	end
	local result = process.sigmoid[currentSample] * inSample;
	process.bufferUn[currentSample] = inSample;
	process.bufferProc[currentSample] = result;
	return result;
end


local function prepareToPlayFct()
	globals.sampleRate = plugin.getSampleRate();
	globals.sampleRateByMsec = plugin.getSampleRate() / 1000.0;
	--print("Sample Rate:"..global.sampleRate)
end

plugin.addHandler("prepareToPlay", prepareToPlayFct);


--
--
-- GUI Definitions
--
--
local frame1 = juce.Rectangle_int (100,10,400,225);
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
-- GUI Functions
--
--
function repaintIt() 
	local guiComp = gui:getComponent();
	if guiComp and process.currentSample > 0 then
		createImage();
		guiComp:repaint(frame1);
	end
end


function createImage() 
	dbufIndex = 1-dbufIndex;
	local img = dbufPaint[dbufIndex];
	local imgG = juce.Graphics(img);
	local middleY = frame1.h/2
    imgG:fillAll();
	imgG:setColour (juce.Colour.green)
    imgG:drawRect (1,1,frame1.w,frame1.h)
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
				--local samp = math.abs(b[i]);
				imgG:drawLine(x,middleY,x,middleY-b[i]*middleY)
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
		name = "Mix";
		min = 0.01;
		max = 1;
		changed = function (val) power = val end;
	};
}


local allSyncOptions = {_1over64,_1over32,_1over16,_1over8,_1over4,_1over2,_1over1}; 

-- function to get all getAllSyncOptionNames of the table of all families
function getAllSyncOptionNames()
  local tbl = {}
  for i,s in ipairs(allSyncOptions) do
    print(s["name"])
    table.insert(tbl,s["name"]) 
  end 
  return tbl
end

-- based on the sync name of the parameter set the selected sync values
function updateSync(arg)
  for i,s in ipairs(allSyncOptions) do
    if(arg==s["name"]) then
      --print("selected: ".. arg)
      newNoteLen = { ratio=s["ratio"]; modifier=selectedNoteLen.modifier; ratio_mult_modifier =  s["ratio"] * selectedNoteLen.modifier;};
	  resetSigmoid();
	  selectedNoteLen = newNoteLen;
	  return;
    end
  end 
end

params = plugin.manageParams {
	{
		name = "Sync";
		type = "list";
		values = getAllSyncOptionNames();
		default = getAllSyncOptionNames()[1];
		changed = function(val) updateSync(val) end;
	};

}