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
function noop() end;
local dbg = noop


--
--
--MAIN LOOP 
--
--
local left  = 0; --left channel
local right = 1; --right channel
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
	
	process.onceAtLoopStartFunction();
	process.onceAtLoopStartFunction = noop;
	
	if #process.processingShape == 0 then
		initProcess(process, noteLenInSamples)
	end
	
	if position.isPlaying then
		-- 3. "ppq" of the specified notelen ... if we don't count 1/4 we have to count more/lesse depending on selected noteLength
		ppqOfNoteLen  = position.ppqPosition * quater2selectedNoteFactor(selectedNoteLen);
		-- 4. the delta in "ppq" relative to the selected noteLength
		deltaToNextCount = mathToInt(ppqOfNoteLen) - ppqOfNoteLen;
		-- 5. the number of samples that is delta to the next count based on selected noteLength
		samplesToNextCount = mathToInt(deltaToNextCount * noteLenInSamples);
		
		initProcessAt(process, samplesToNextCount, noteLenInSamples)
		
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
			initProcessAt(process, samplesToNextCount, noteLenInSamples);
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
			initProcess(process, noteLenInSamples);
		else
			if not progress(process) then
				dbg("Warning i: "..i.."; samplesToNextCount: "..samplesToNextCount)
			end
		end
        samples[0][i] = apply(left,  process, samples[0][i]) -- left channel
        samples[1][i] = apply(right, process, samples[1][i]) -- right channel    
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


-----------------------------------------------
-- computes a sigmoid function processing shape
-- in: size in samples
-- return: sigmoid function array
function initSigmoid(sizeInSamples) 
	local expFct = math.exp
	local sigmoid = {};
	local delta = (6 - (-6)) /sizeInSamples;
	for i=1,sizeInSamples+10 do
		t = -6 + i*delta;
		sigmoid[i] = 1 / (1+expFct(-t));
	end
	dbg("INIT Sigmoid ".. #sigmoid .. " sizeInSamples: "..sizeInSamples)
	return sigmoid;
end

--
--
-- Define Process
--
--
process = {
	maxSample = -1;
	currentSample = -1;
	--delta = -1;
	power = 0.0;
	processingShape = {};
	bufferUn = {};
	bufferProc = {};
	shapeFunction = initSigmoid;--computeSpline; --initSigmoid
	onceAtLoopStartFunction = noop;
}

function initProcess(inProcess, inNoteLenInSamples) 
	inProcess.maxSample = mathToInt(inNoteLenInSamples);
	inProcess.currentSample = 0;
	if not inProcess.processingShape or #inProcess.processingShape == 0 then
		inProcess.processingShape = inProcess.shapeFunction(inProcess.maxSample);
	end
	dbg("INIT: sig="..#inProcess.processingShape.."; maxSample=".. inProcess.maxSample .."; currentSample="..inProcess.currentSample);
end

function initProcessAt(inProcess, inSamplesToNextCount, inNoteLenInSamples) 
	inProcess.maxSample = mathToInt(inNoteLenInSamples);
	if 0 == inSamplesToNextCount then
		inProcess.currentSample = 0;
	else 
		inProcess.currentSample = inProcess.maxSample - inSamplesToNextCount;
	end
	if #inProcess.processingShape == 0 then
		inProcess.processingShape = inProcess.shapeFunction(process.maxSample);
	end
	--print("INIT-AT: sig="..#process.processingShape.."; maxSample=".. process.maxSample .."; currentSample="..process.currentSample.."; samplesToNextCount="..samplesToNextCount);
	
	if inProcess.currentSample + samplesToNextCount > inProcess.maxSample then
		dbg("SET-AT: Warning - ppq=" .. position.ppqPosition .. "; 1/8 base ppq=" .. ppqOfNoteLen.. "( "..inNoteLenInSamples.." ); samplesToNextCount="..inSamplesToNextCount.."; maxSample=".. inProcess.maxSample .."; currentSample="..inProcess.currentSample);
	end
	
end 


function resetProcessingShape(inProcess)
	inProcess.processingShape = {};
end


function progress(inProcess)
	inProcess.currentSample =  inProcess.currentSample + 1;
	if(#inProcess.processingShape <= inProcess.currentSample) then
		dbg("Warning! progress: sig="..#inProcess.processingShape.."; maxSample=".. inProcess.maxSample .."; currentSample="..inProcess.currentSample)
		return false;
	end
	return true;
end

function apply(inChannel, inProcess, inSample)
	--print("Sig: "..process.currentSample)
	local currentSample = inProcess.currentSample;
	if(#inProcess.processingShape <= currentSample) then
		dbg("Warning! apply: sig="..#inProcess.processingShape.."; maxSample=".. inProcess.maxSample .."; currentSample="..currentSample)
	end
	--print("Apply: processingShape="..#inProcess.processingShape..", currentSample="..currentSample..", max="..maximum(inProcess.processingShape)..", min="..minimum(inProcess.processingShape));
	local result = (1-((1-inProcess.processingShape[currentSample])*inProcess.power)) * inSample;
	local idx= inChannel + currentSample*2 -- we intertwin left an right channel...
	inProcess.bufferUn[idx] = inSample;
	inProcess.bufferProc[idx] = result;
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
local col1 = juce.Colour(0,255,0,128);
local col2 = juce.Colour(255,0,0,128);
local cols = { col2, col1 };
local width = 400;
local height = 225;
local frame = juce.Rectangle_int (100,10, width, height);
local db1 = juce.Image(juce.Image.PixelFormat.ARGB, width, height, true);
local db2 = juce.Image(juce.Image.PixelFormat.ARGB, width, height, true);
local dbufPaint = { [0] = db1, [1] = db2 };
local dbufIndex = 0;

--
--
-- GUI Functions
--
--
function repaintIt() 
	local guiComp = gui:getComponent();
	if guiComp and process.currentSample > 0 then
		createImageStereo();
		--createImageMono(left);
		guiComp:repaint(frame);
	end
end


function createImageStereo() 
	dbufIndex = 1-dbufIndex;
	local dbufIndex = dbufIndex;
	local frame = frame;
	local img = dbufPaint[dbufIndex];
	local imgG = juce.Graphics(img);
	--local middleY = frame.h/2
	local maxHeight = frame.h/4;
	local middleYLeft  = frame.h/4;
	local middleYRight = middleYLeft + frame.h/2;
    imgG:fillAll();
	imgG:setColour (juce.Colour.green)
    imgG:drawRect (1,1,frame.w,frame.h)
	if process.maxSample > 0 then
		local delta = (frame.w / process.maxSample);
		local compactSize = math.floor(process.maxSample / frame.w);
		if compactSize < 1 then compactSize=1 end;
		local buffers = {process.bufferUn, process.bufferProc};
		for i=1,#buffers do
			local b = buffers[i];
			imgG:setColour (cols[i]);
			--remember we have interwined left and right channel, i.e. double the size samples...
			deltaReal = delta * 0.5
			for j=0,#b-1,compactSize do
				local x = j*deltaReal;
				imgG:drawLine(x, middleYLeft,  x, middleYLeft -b[j+left] *maxHeight);
				imgG:drawLine(x, middleYRight, x, middleYRight-b[j+right]*maxHeight);
			end
		end
	end
end


function createImageMono(inWhich) 
	if inWhich~=left and inWhich ~= right then
		return
	end
	dbufIndex = 1-dbufIndex;
	local img = dbufPaint[dbufIndex];
	local imgG = juce.Graphics(img);
	local middleY = frame.h/2
    imgG:fillAll();
	imgG:setColour (juce.Colour.green)
    imgG:drawRect (1,1,frame.w,frame.h)
	if process.maxSample > 0 then
		local delta = frame.w / process.maxSample;
		local compactSize = math.floor(process.maxSample / frame.w);
		if compactSize < 1 then compactSize=1 end;
		local buffers = {process.bufferUn, process.bufferProc};
		for i=1,#buffers do
			local b = buffers[i];
			imgG:setColour (cols[i]);
			--remember we have interwined left and right channel, i.e. double the size samples...
			deltaReal = delta * 0.5
			for j=0,#b-1,compactSize do
				local x = j*deltaReal;
				--local samp = math.abs(b[i]);
				imgG:drawLine(x,middleY,x,middleY-b[j+inWhich]*middleY)
			end
		end
	end
end


function gui.paint (g)
	g:fillAll ();
	local img = dbufPaint[dbufIndex];
	g:drawImageAt(img, frame.x, frame.y);
	paintPoints(g)
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
    --print(s["name"])
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
	  resetProcessingShape(process);
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
	{
		name = "Power";
		min = 0.0;
		max = 1.0;
		changed = function (val) process.power = val end;
	};
}

--
--
-- Editing the Pumping function
--
--
local listOfPoints = {};
function rectangleSorter(a,b) 
	--print("Sorter: "..a.x..", "..b.x);
	return a.x < b.x 
end;

--
--  Coordinate Stuff
--
-- coordinate system to display and manage editor points in
local editorFrame = frame;
local editorStartPoint = juce.Point(editorFrame.x, editorFrame.y+editorFrame.h);
local editorEndPoint   = juce.Point(editorFrame.x+editorFrame.w, editorFrame.y+editorFrame.h);
-- in model coordiantes we only use ranges [0,1] both for x and y.
local modelFrame = juce.Rectangle_float (0.0, 0.0, 1.0, 1.0);
local editorToModelTrafo = {
	xTranslate = -editorFrame.x;
	yTranslate = -editorFrame.y;
	xScale = 1.0/editorFrame.w;
	yScale = 1.0/editorFrame.h;
	yInvert = function(y) return 1.0-y end;
}
local modelToEditorTrafo = {
	xTranslate = editorFrame.x;
	yTranslate = editorFrame.y;
	xScale = editorFrame.w;
	yScale = editorFrame.h;
	yInvert = function(y) return editorFrame.h-y end;
}
-- editor to gui model
local editorToGuiModelTrafo = {
	xTranslate = -editorFrame.x;
	yTranslate = -editorFrame.y;
	xScale = 1.0;
	yScale = 1.0;
	yInvert = function(y) return y end;
}
local guiToEditorTrafo = {
	xTranslate = editorFrame.x;
	yTranslate = editorFrame.y;
	xScale = 1.0;
	yScale = 1.0;
	yInvert = function(y) return y end;
}
local zeroTrafo = {
	xTranslate = 0.0;
	yTranslate = 0.0;
	xScale = 1.0;
	yScale = 1.0;
	yInvert = function(y) return y end;
}
local function transform(inTrafo, inPoint)
	local x = (inPoint.x + inTrafo.xTranslate) * inTrafo.xScale;
	local y = inTrafo.yInvert((inPoint.y + inTrafo.yTranslate) * inTrafo.yScale);
	return juce.Point(x,y);
end

--
-- editiing points
-- 
dragState = {
	fct = startDrag;
	selected=nil;
}

function startDrag(inMouseEvent) 
	-- have a second representation of the mous point relative to the sample display view port frame.
	local mousePointRelative = transform(zeroTrafo, inMouseEvent);
	print("StartDrag: "..mousePointRelative.x..","..mousePointRelative.y);
	for i=1,#listOfPoints do
		-- the listOfPoints is all in the sample view coordinate system.
		print(listOfPoints[i]:contains(mousePointRelative)) 
		if listOfPoints[i]:contains(mousePointRelative) then
			--we hit an existing point here --> remove it
			dragState.selected=listOfPoints[i];
			dragState.fct = doDrag;
			return;
		end
	end
end

function doDrag(inMouseEvent)
	local mousePointAbsolute = transform(zeroTrafo, inMouseEvent);
	if editorFrame:contains(mousePointAbsolute) then
		local mousePointRelative = transform(zeroTrafo, inMouseEvent);
		print("DoDrag: "..mousePointRelative.x..","..mousePointRelative.y.."; "..dragState.selected.x..", "..dragState.selected.y);
		if dragState.selected then
			dragState.selected.x = mousePointRelative.x-5;
			dragState.selected.y = mousePointRelative.y-5;
			table.sort(listOfPoints,rectangleSorter);
			computePath();
			computeSpline(process.maxSample);
			--resetProcessingShape(process);
			repaintIt();
		end
	end
end

function mouseUpHandler(inMouseEvent)
	-- have a second representation of the mous point relative to the sample display view port frame.
	local mousePointRelative = transform(zeroTrafo, inMouseEvent);
	print("StartDrag: "..mousePointRelative.x..","..mousePointRelative.y);
	dragState.fct = startDrag;
	dragState.selected=nil;
	resetProcessingShape(process);
end


function mouseDragHandler(inMouseEvent)
	print("Drag: "..inMouseEvent.x..","..inMouseEvent.y.."; "..(dragState.fct and "fct" or "nil"));
	if nil == dragState.fct then
		dragState.fct = startDrag;
	end
	dragState.fct(inMouseEvent);
end


function mouseDoubleClickHandler(inMouseEvent)
	local dirty = mouseDoubleClickExecution(inMouseEvent);
	if dirty then
		computePath();
		computeSpline(process.maxSample);
		resetProcessingShape(process);
		repaintIt();
	end
end

-- in: MouseEvent from framework
-- return: true if dirty - point has been removed or added. stuff needs recalculation
function mouseDoubleClickExecution(inMouseEvent)
	-- first figure out whether we hit an existing point - if yes deletet this point.
	-- let's first create the original mouse point - that is relative to the whole GUI window
	local mousePointAbsolute = transform(zeroTrafo, inMouseEvent);
	-- have a second representation of the mous point relative to the sample display view port frame.
	local mousePointRelative = transform(zeroTrafo, inMouseEvent);
	print("DblClick: "..mousePointRelative.x..","..mousePointRelative.y);
	for i=1,#listOfPoints do
		-- the listOfPoints is all in the sample view coordinate system.
		print(listOfPoints[i]:contains(mousePointRelative)) 
		if listOfPoints[i]:contains(mousePointRelative) then
			--we hit an existing point here --> remove it
			table.remove(listOfPoints, i);
			return true;
		end
	end
	-- seems we create a new one here
	if editorFrame:contains(mousePointAbsolute) then
		-- relative to editor frame
		local x = mousePointRelative.x;
		local y = mousePointRelative.y;
		print("Create Point: "..x..","..y);
		local newPoint = juce.Rectangle_int (x-5,y-5,10,10);
		table.insert(listOfPoints,newPoint);
		-- the point is added at the end of the table, though it could be in the middle of the display. 
		-- in order to draw the path correctly later we sort the points according to their x coordinate.
		table.sort(listOfPoints,rectangleSorter);
		return true;
	end
	return false;
end

-- this one helps to transform the path which might be in a different coord system... actually it is not.
local affineT = juce.AffineTransform():translated(zeroTrafo.xTranslate, zeroTrafo.yTranslate);
-- some "cached" things, 1st the linear path, 2nd, the spline catmul spline.
local computedPath = nil;
local computedSpline = nil;

function computePath() 
	if #listOfPoints > 1 then
		path = juce:Path();
		--path:startNewSubPath (listOfPoints[1].x+5, listOfPoints[1].y+5)
		path:startNewSubPath(editorStartPoint.x, editorStartPoint.y);
		for i=1,#listOfPoints do
			p = juce.Point(listOfPoints[i].x+5, listOfPoints[i].y+5);
			cp1 = juce.Point(listOfPoints[i].x+5, listOfPoints[i].y+5);
			path:quadraticTo(cp1,p);
		end
		path:quadraticTo(editorEndPoint.x, editorEndPoint.y, editorEndPoint.x, editorEndPoint.y);
		--path:applyTransform(affineT);
		computedPath = path;
		--print("Path Length: "..computedPath:getLength());
	end
end

-----------------------------------
--
--
function computeProcessingShape(inNumberOfSteps) 
	-- be aware that all this is in coordinate system of the editor window, we havt to transform it.
	-- 
	if computedSpline and #computedSpline >= inNumberOfSteps then
		local newProcessingShape = {};
		local maxY = editorFrame.y + editorFrame.h 
		for i = 1,#computedSpline do
			local p = computedSpline[i]
			newProcessingShape[i-1] = (maxY - p.y) / editorFrame.h; -- 0-based!!!!!
		end
		--print("Computed Processing Shape: size="..#newProcessingShape..", process.maxSample="..process.maxSample..", max="..maximum(newProcessingShape)..", min="..minimum(newProcessingShape));
		return newProcessingShape;
	end
end


-----------------------------------
-- in: number of steps
-- return: processing shape based on spline, index is 0-based!!!!
function computeSpline(inNumberOfSteps) 
	spline = {};
	points = {};
	table.insert(points, editorStartPoint);
	table.insert(points, editorStartPoint);
	if #listOfPoints >= 1 then
		for i=1,#listOfPoints do
			table.insert(points, listOfPoints[i]);
		end
	end
	-- insert 2 points because we need an extra point by the nature of the computation: it needs 4 points for each segment, i.e. endpoint + one
	table.insert(points, editorEndPoint);
	table.insert(points, editorEndPoint);
	--print("Sort");
	table.sort(points, rectangleSorter);
	--for i = 1,#points do
		--print("X-Coord: "..points[i].x);
	--end
	local delta = (#points-3) / inNumberOfSteps
	for t = 1, #points-2,delta do
		table.insert(spline, PointOnPath(points,t));
	end
	print("Computed spline: numOfSteps="..inNumberOfSteps..", inSize="..(#points-2)..", size="..#spline..", delta="..delta);
	computedSpline = spline;
	newProcessingShape = computeProcessingShape(inNumberOfSteps)
	print("Computed Processing Shape: size="..#newProcessingShape..", process.maxSample="..process.maxSample..", max="..maximum(newProcessingShape)..", min="..minimum(newProcessingShape));
	return newProcessingShape
end

process.shapeFunction = computeSpline;

function paintPoints(g) 
	--print("Build path: "..#listOfPoints);
	g:setColour (juce.Colour.red)
	if #listOfPoints > 1 and computedPath then
		g:strokePath(computedPath);
	end
	for i=1,#listOfPoints do
		--print("Draw Rect: "..listOfPoints[i].x..","..listOfPoints[i].y.." / "..listOfPoints[i].w..","..listOfPoints[i].h);
		g:drawRect (listOfPoints[i].x, listOfPoints[i].y, listOfPoints[i].w, listOfPoints[i].h);
	end
	--
	-- spline stuff
	--
	if computedSpline then
		--print("Draw spline: "..#computedSpline)
		g:setColour (juce.Colour.white)
		
		local delta = 512
		while (#computedSpline/delta) < 50  and delta > 2 do
			delta = delta/2;
		end;
		for i = 1,#computedSpline,delta do
			local p = computedSpline[i]
			g:drawRect(p.x-5, p.y-5, 10,10);
		end
	end
end


gui.addHandler("mouseDrag", mouseDragHandler);
gui.addHandler("mouseUp", mouseUpHandler);
gui.addHandler("mouseDoubleClick", mouseDoubleClickHandler);


function maximum (a)
  local mi = 1          -- maximum index
  local m = a[mi]       -- maximum value
  for i,val in ipairs(a) do
	if val > m then
	  mi = i
	  m = val
	end
  end
  return m
end

function  minimum (a)
  local mi = 1          -- maximum index
  local m = a[mi]       -- maximum value
  for i,val in ipairs(a) do
	if val < m then
	  mi = i
	  m = val
	end
  end
  return m
end



--
-- TODO
-- spline stuff!
-- https://forums.coregames.com/t/spline-generator-through-a-sequence-of-points/401
-- https://pastebin.com/2JZi2wvH
-- https://www.youtube.com/watch?v=9_aJGUTePYo
--
function PointOnPath(inPoints, t) -- catmull-rom cubic hermite interpolation
    if progress == 1 then return nodeList[#nodeList] end
	p0 = math.floor(t);
	p1 = p0+1;
	p2 = p1+1;
	p3 = p2+1;
    
	t = t - math.floor(t);
	
	tt = t*t;
	ttt = tt*t;
	_3ttt = 3*ttt;
	_2tt  = tt+tt;
	_4tt  = _2tt+_2tt;
	_5tt  = _4tt+tt;
	
	q0 =   -ttt + _2tt - t;
	q1 =  _3ttt - _5tt + 2.0;
	q2 = -_3ttt + _4tt + t;
	q3 =    ttt -   tt;
	--print("Spline: "..p0..","..p1..","..p2..","..p3.."; "..#points.."; "..t);
	tx = 0.5 * (inPoints[p0].x * q0 + inPoints[p1].x * q1 + inPoints[p2].x * q2 + inPoints[p3].x * q3);
	ty = 0.5 * (inPoints[p0].y * q0 + inPoints[p1].y * q1 + inPoints[p2].y * q2 + inPoints[p3].y * q3);
	
	return juce.Point(tx,ty);
end
