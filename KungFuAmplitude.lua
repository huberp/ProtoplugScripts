--[[
name: AmplitudeKungFu
description: A sample accurate volume shaper based on catmul-rom splines
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
	syncOption = _1over8;
	ratio = _1over8.ratio;
	modifier = lengthModifiers.normal;
	ratio_mult_modifier = _1over8.ratio * lengthModifiers.normal;
}
local globals = {
	samplesCount = 0;
	sampleRate = -1;
	sampleRateByMsec = -1;
	isPlaying = false;
	bpm = 0;
} 

function plugin.processBlock (samples, smax) -- let's ignore midi for this example
	position = plugin.getCurrentPosition();
	if position.bpm ~= globals.bpm then
		resetProcessingShape(process);
	end
	globals.bpm = position.bpm;
	--
	-- preset samplesToNextCount;
	samplesToNextCount = -1
	
	-- compute stuff
	-- 1. length in milliseconds of the selected noteLength
	noteLenInMsec = noteLength2Milliseconds(selectedNoteLen, position.bpm);
	-- 2. length of a slected noteLength in samples 
	noteLenInSamples = noteLength2Samples(noteLenInMsec, globals.sampleRateByMsec);
	
	process.onceAtLoopStartFunction(process);
	process.onceAtLoopStartFunction = noop;
	
	if position.isPlaying then
		-- 3. "ppq" of the specified notelen ... if we don't count 1/4 we have to count more/lesse depending on selected noteLength
		ppqOfNoteLen  = position.ppqPosition * quater2selectedNoteFactor(selectedNoteLen);
		-- 4. the delta in "ppq" relative to the selected noteLength
		deltaToNextCount = mathToInt(ppqOfNoteLen) - ppqOfNoteLen;
		-- 5. the number of samples that is delta to the next count based on selected noteLength
		samplesToNextCount = mathToInt(deltaToNextCount * noteLenInSamples);
		
		setProcessAt(process, samplesToNextCount, noteLenInSamples)
		
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
		
		setProcessAt(process, samplesToNextCount, noteLenInSamples);
		
		if isPlaying then
			isPlaying = false;
		end
		
		if samplesToNextCount < smax then
			dbg("NOT Playing - global samples: " .. globals.samplesCount .. " 1/8 base count: " .. noteCount.. "("..noteLenInSamples..") --> "..samplesToNextCount.." process.currentSample:" .. process.currentSample);
		end
	end
	
	-- post condition here: samplesToNextCount != -1
    for i = 0, smax do
		if i == samplesToNextCount then
			createImageStereo(process, process.currentSample-i,i);
			repaintIt() 
			setProcessAt(process, 0, noteLenInSamples);
		else
			if not progress(process) then
				dbg("Warning i: "..i.."; samplesToNextCount: "..samplesToNextCount)
			end
		end
        samples[0][i] = apply(left,  process, samples[0][i]) -- left channel
        samples[1][i] = apply(right, process, samples[1][i]) -- right channel    
    end
	if samplesToNextCount >= smax then 
		createImageStereo(process, process.currentSample-smax,smax);
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
-- Define Process - the process covers all data relevant to process a "sync frame"
--
--
process = {
	maxSample = -1;
	currentSample = -1;
	--delta = -1;
	power = 0.0;
	processingShape = {}; -- the processing shape which is used to manipulate the incoming samples
	bufferUn = {};
	bufferProc = {};
	shapeFunction = initSigmoid;--computeSpline; --initSigmoid
	onceAtLoopStartFunction = noop;
}

-- Sets the current position in processing one specific "sync frame"
--
-- inSamplesToNextCount - the number of samples left in this "sync frame". if 1/8 for example requires 9730 samples and we have already counted 7000, then there's 2730 samples left. 
-- inNoteLenInSamples - the number of a sync frame, i.e. probably it's 9730 samples for 1/8 based on 148 bpm.
--
-- outProcess.maxSample, outProcess.currentSample
function setProcessAt(outProcess, inSamplesToNextCount, inNoteLenInSamples) 
	local intNoteLenInSamples = mathToInt(inNoteLenInSamples);
	outProcess.maxSample = intNoteLenInSamples;
	if 0 == inSamplesToNextCount then
		-- here we reached the end of the curent counting time
		outProcess.currentSample = 0;
	else 
		-- here we set the current sample
		outProcess.currentSample = intNoteLenInSamples - inSamplesToNextCount;
	end
	if #outProcess.processingShape == 0 then
		outProcess.processingShape = outProcess.shapeFunction(outProcess.maxSample);
	end
	--print("INIT-AT: sig="..#process.processingShape.."; maxSample=".. process.maxSample .."; currentSample="..process.currentSample.."; samplesToNextCount="..samplesToNextCount);
	
	if outProcess.currentSample + samplesToNextCount > outProcess.maxSample then
		dbg("SET-AT: Warning - ppq=" .. position.ppqPosition .. "; 1/8 base ppq=" .. ppqOfNoteLen.. "( "..inNoteLenInSamples.." ); samplesToNextCount="..inSamplesToNextCount.."; maxSample=".. outProcess.maxSample .."; currentSample="..outProcess.currentSample);
	end
end 


function resetProcessingShape(inProcess)
	inProcess.processingShape = {};
end


function progress(inProcess)
	inProcess.currentSample =  inProcess.currentSample + 1;
	if(#inProcess.processingShape < inProcess.currentSample) then
		dbg("Warning! progress: sig="..#inProcess.processingShape.."; maxSample=".. inProcess.maxSample .."; currentSample="..inProcess.currentSample)
		return false;
	end
	return true;
end

function apply(inChannel, inProcess, inSample)
	--print("Sig: "..process.currentSample)
	local currentSample = inProcess.currentSample;
	if(#inProcess.processingShape < currentSample) then
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
local colourSampleProcessed = juce.Colour(0,255,0,128);
local colourSampleOriginald = juce.Colour(255,0,0,128);
local coloursSamples = { colourSampleOriginald, colourSampleProcessed };

local colourSplinePoints = juce.Colour(255,255,255,255);
local colourProcessingShapePoints = juce.Colour(0,64,255,255);

local width = 840;
local height = 360;
local frame = juce.Rectangle_int (100,10, width, height);

-- double buffering
local db1 = juce.Image(juce.Image.PixelFormat.ARGB, width, height, true); -- juce.Image.PixelFormat.ARGB
local db2 = juce.Image(juce.Image.PixelFormat.ARGB, width, height, true);
local dbufImage = { [0] = db1, [1] = db2 };
local dbufGraphics = { [0] = juce.Graphics(db1), [1] = juce.Graphics(db2) };
local dbufIndex = 0;
--
local controlPoints = {
	side = 16;
	offset = 8;
	colour = juce.Colour(255,64,0,255);
	fill = juce.FillType(juce.Colour(255,64,0,255));
}
 
--
--
-- GUI Functions
--
--
function repaintIt() 
	local guiComp = gui:getComponent();
	if guiComp and process.currentSample > 0 then
		--createImageStereo(process);
		--createImageMono(left);
		guiComp:repaint(frame);
	end
end


function createImageStereo(inProcess, optFrom, optLen) 
	-- keep in mind we have intertwind left right... so compute the buffer index with that in mind.
	local from = (optFrom or 0)*2;
	local len  = (optLen or inProcess.maxSample - from)*2;
	local to = from+len;
	
	if from==0 and len==0 then 
		dbg("createImageStereo; from="..from.."; to="..to);
		return 
	end;
	--
	--dbufIndex = 1-dbufIndex;
	local dbufIndex = dbufIndex;
	local frame = frame;
	--local img = dbufImage[dbufIndex];
	local imgG = dbufGraphics[dbufIndex];
	--local middleY = frame.h/2
	local maxHeight = frame.h/4;
	local middleYLeft  = frame.h/4;
	local middleYRight = middleYLeft + frame.h/2;
    --imgG:fillAll();
	
	local maxSample = inProcess.maxSample;
	if maxSample > 0 then
		--remember we have interwined left and right channel, i.e. double the size samples... therefore we need 0.5 delta
		local delta = 0.5 * (frame.w / maxSample);
		local compactSize = math.ceil(maxSample / frame.w);
		if compactSize < 2 then compactSize=2 end;
		local buffers = {inProcess.bufferUn, inProcess.bufferProc};
		-- now first fill the current "window" representing the current sample-buffer
		imgG:setColour (juce.Colour.black);
		imgG:fillRect(from*delta,0,to*delta,frame.h);
		-- then fill with the sample data
		imgG:setColour (juce.Colour.green);
		imgG:drawRect (1,1,frame.w,frame.h);
		for i=1,#buffers do
			local buf = buffers[i];
			imgG:setColour (coloursSamples[i]);
			for j=from,to,compactSize do
				local x = j*delta;
				imgG:drawLine(x, middleYLeft,  x, middleYLeft -buf[j+left] *maxHeight);
				imgG:drawLine(x, middleYRight, x, middleYRight-buf[j+right]*maxHeight);
			end
		end
	end
end


function createImageMono(inWhich) 
	if inWhich~=left and inWhich ~= right then
		return
	end
	dbufIndex = 1-dbufIndex;
	local img = dbufImage[dbufIndex];
	local imgG = juce.Graphics(img);
	local middleY = frame.h/2
    imgG:fillAll();
	imgG:setColour (juce.Colour.green)
    imgG:drawRect (1,1,frame.w,frame.h)
	if process.maxSample > 0 then
		local delta = frame.w / process.maxSample;
		local compactSize = math.ceil(process.maxSample / frame.w);
		if compactSize < 1 then compactSize=1 end;
		local buffers = {process.bufferUn, process.bufferProc};
		for i=1,#buffers do
			local b = buffers[i];
			imgG:setColour (coloursSamples[i]);
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
	local img = dbufImage[dbufIndex];
	g:drawImageAt(img, frame.x, frame.y);
	paintPoints(g)
end



--
--
-- Editing the Pumping function
--
--
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

-- 
-- some "cached" things, 1st the linear path, 2nd, the spline catmul spline.
--
local MsegGuiModelData = {
	listOfPoints = {};
	computedPath = nil;
	cachedSplineForLenEstimate = nil;
}

--
-- Creates a control point given in gui model space
-- if we have coordiantes in gui model space, simply create it.
-- source could be mouseevent
--
function createControlPointAtGuiModelCoord(inX, inY) 
	local side = controlPoints.side;
	local offset = controlPoints.offset;
	return juce.Rectangle_int (inX-offset,inY-offset,side,side);
end
--
-- Creates a control point given in gui model space
-- if we have coordiantes in gui model space, simply create it.
-- source could be mouseevent
--
function createControlPointAtGuiModelCoord(inCoord) 
	local side = controlPoints.side;
	local offset = controlPoints.offset;
	return juce.Rectangle_int (inCoord.x-offset,inCoord.y-offset,side,side);
end
--
-- Creates a control point given in normalized [0,1] space
-- if we have coordiantes in normalized space, simply create it.
-- source could be a serialized/state saved point
--
function createControlPointAtNormalizedCoord(inX, inY) 
	local side = controlPoints.side;
	local offset = controlPoints.offset;
	return juce.Rectangle_int (inX*editorFrame.w+editorFrame.x-offset,(1.0-inY)*editorFrame.h+editorFrame.y-offset,side,side);
end
--
-- Transforms from gui model control point to normalized space point
--
function controlPointToNormalizedPoint(inControlPoint) 
	--local side = controlPoints.side;
	local offset = controlPoints.offset;
	return Point:new{ 
		x=(inControlPoint.x+offset-editorFrame.x) / editorFrame.w, 
		-- turn y upside down!
		y=(editorFrame.h-inControlPoint.y+offset-editorFrame.y) / editorFrame.h  };
end

--
-- editing points
-- 
dragState = {
	dragging = false;
	fct = startDrag;
	selected=nil;
}

function startDrag(inMouseEvent) 
	local listOfPoints = MsegGuiModelData.listOfPoints;
	dbg("StartDrag: "..inMouseEvent.x..","..inMouseEvent.y);
	for i=1,#listOfPoints do
		-- the listOfPoints is all in the sample view coordinate system.
		dbg(listOfPoints[i]:contains(inMouseEvent)) 
		if listOfPoints[i]:contains(inMouseEvent) then
			--we hit an existing point here --> remove it
			dragState.selected=listOfPoints[i];
			dragState.fct = doDrag;
			dragState.dragging=true;
			return;
		end
	end
end

function doDrag(inMouseEvent)
	local listOfPoints = MsegGuiModelData.listOfPoints;
	if editorFrame:contains(inMouseEvent) then
		dbg("DoDrag: "..inMouseEvent.x..","..inMouseEvent.y.."; "..dragState.selected.x..", "..dragState.selected.y);
		if dragState.selected then
			local offset = controlPoints.offset;
			dragState.selected.x = inMouseEvent.x-offset;
			dragState.selected.y = inMouseEvent.y-offset;
			table.sort(listOfPoints,rectangleSorter);
			computePath();
			repaintIt();
		end
	end
end

function mouseUpHandler(inMouseEvent)
	print("Mouse up: "..inMouseEvent.x..","..inMouseEvent.y);
	if dragState.dragging then
		local offset = controlPoints.offset;
		dragState.selected.x = inMouseEvent.x-offset;
		dragState.selected.y = inMouseEvent.y-offset;
		dragState.fct = startDrag;
		dragState.selected=nil;
		dragState.dragging = false;
		process.onceAtLoopStartFunction = resetProcessingShape;
	end;
end


function mouseDragHandler(inMouseEvent)
	dbg("Drag: "..inMouseEvent.x..","..inMouseEvent.y.."; "..(dragState.fct and "fct" or "nil"));
	if nil == dragState.fct then
		dragState.fct = startDrag;
	end
	dragState.fct(inMouseEvent);
end


function mouseDoubleClickHandler(inMouseEvent)
	local dirty = mouseDoubleClickExecution(inMouseEvent);
	if dirty then
		controlPointsHaveBeenChangedHandler();
	end
end

function controlPointsHaveBeenChangedHandler()
	computePath();
	process.onceAtLoopStartFunction = resetProcessingShape; 
	repaintIt();
end

-- in: MouseEvent from framework
-- return: true if dirty - point has been removed or added. stuff needs recalculation
function mouseDoubleClickExecution(inMouseEvent)
	local listOfPoints = MsegGuiModelData.listOfPoints;
	-- first figure out whether we hit an existing point - if yes deletet this point.
	dbg("DblClick: x="..inMouseEvent.x..", y="..inMouseEvent.y..", len="..#listOfPoints);
	for i=1,#listOfPoints do
		-- the listOfPoints is all in the sample view coordinate system.
		print(listOfPoints[i]:contains(inMouseEvent)) 
		if listOfPoints[i]:contains(inMouseEvent) then
			--we hit an existing point here --> remove it
			table.remove(listOfPoints, i);
			return true;
		end
	end
	-- seems we create a new one here
	if editorFrame:contains(inMouseEvent) then
		-- relative to editor frame
		dbg("Create Point: "..inMouseEvent.x..","..inMouseEvent.y);
		local newPoint = createControlPointAtGuiModelCoord(inMouseEvent);
		listOfPoints[#listOfPoints+1] = newPoint;
		-- the point is added at the end of the table, though it could be in the middle of the display. 
		-- in order to draw the path correctly later we sort the points according to their x coordinate.
		table.sort(listOfPoints,rectangleSorter);
		return true;
	end
	return false;
end


function computePath() 
	local listOfPoints = MsegGuiModelData.listOfPoints;
	if #listOfPoints > 1 then
		path = juce:Path();
		path:startNewSubPath(editorStartPoint.x, editorStartPoint.y);
		local side = controlPoints.side;
		local offset = controlPoints.offset;
		for i=1,#listOfPoints do
			p = juce.Point(listOfPoints[i].x+offset, listOfPoints[i].y+offset);
			--cp1 = juce.Point(listOfPoints[i].x+5, listOfPoints[i].y+5);
			path:lineTo(p);
		end
		path:lineTo(editorEndPoint.x, editorEndPoint.y);
		computedPath = path;
		--print("Path Length: "..computedPath:getLength());
	end
end

-----------------------------------
-- this transforms the spline points into a "valid" processing shape. it does two things:
-- 1.) the spline points are in GUI model coordinate system but must be in the "sync-frame" system, 
--     i.e. we need processing values for each incoming sample in a sync frame in the range of [0, 1]
-- 2.) the spline curve has one problem: it is not a pure function, i.e. it sometimes bends in a way where at one x coordinate there are many y's
--     to avoid these "backwards" bends, the algorithm startd from the back and iterates towards the beginning
--     this way it is able to find a good value representing the x value. but this is only a heuristic, I need to check the algorithm...
-- 
--
function computeProcessingShape(inNumberOfValuesInSyncFrame, inPointsOnPath, inSpline, inOverallLength)
	local maxY = editorFrame.y + editorFrame.h ;
	local heigth = editorFrame.h;
	local deltaX = editorFrame.w / inNumberOfValuesInSyncFrame;
	local newProcessingShape = {};
	--print("Computed Processing Shape Start: inNumberOfValuesInSyncFrame="..inNumberOfValuesInSyncFrame..", #inPointsOnPath="..#inPointsOnPath..", #inSpline="..#inSpline..", inOverallLength="..inOverallLength..", deltaX="..deltaX);
	for i=1, inNumberOfValuesInSyncFrame+1 do
		local xcoord = editorFrame.x + deltaX * i;
		local IDX = -1;
		for j = #inSpline-1,1,-1 do
			if inSpline[j].x < xcoord then IDX = j; break end
		end
		-- IDX < xcoord
		-- IDX+1 > xcoord
		--print("IDX xcoord="..xcoord..", IDX="..IDX)
		--print("IDX x[IDX]="..inSpline[IDX].x..", x[IDX+1]="..inSpline[IDX+1].x);
		local tangent = (inSpline[IDX+1].y - inSpline[IDX].y) / (inSpline[IDX+1].x - inSpline[IDX].x);
		local valueY = inSpline[IDX].y + (xcoord - inSpline[IDX].x) * tangent;
		local normalizedY = (maxY - valueY) / heigth
		if normalizedY < 0 then normalizedY = 0 end;
		newProcessingShape[i-1] = normalizedY
	end
	return newProcessingShape;
end


-----------------------------------
-- in: number of values/samplesrepresenting a sync frame
-- return: processing shape based on spline, index is 0-based!!!!
function computeSpline(inNumberOfValuesInSyncFrame) 
	local listOfPoints = MsegGuiModelData.listOfPoints;
	local spline = {};
	local points = {};
	points[1] = editorStartPoint;
	points[2] = editorStartPoint;
	if #listOfPoints >= 1 then
		local offset = controlPoints.offset;
		for i=1,#listOfPoints do
			points[#points+1] = {x=listOfPoints[i].x+offset; y=listOfPoints[i].y+offset; len=0};
		end
	end
	-- insert 2 points because we need an extra point by the nature of the computation: it needs 4 points for each segment, i.e. endpoint + one
	points[#points+1] = editorEndPoint;
	points[#points+1] = editorEndPoint;

	--
	--print("Sort");
	table.sort(points, rectangleSorter);
	--for i = 1,#points do
		--print("X-Coord: "..points[i].x);
	--end
	-- now compute spline points for the length estimate
	local delta = 0.005; --(#points-3) / inNumberOfSteps
	local sqrtFct = math.sqrt;
	local oldPoint = { x=editorStartPoint.x; y=editorStartPoint.y; len = 0; }
	local overallLength = 0.0;
	spline[1]=oldPoint;
	for t = 1.0, (#points-2),delta do
		local nuPoint = PointOnPath(points,t);
		oldPoint.len = sqrtFct((nuPoint.x - oldPoint.x)^2 + (nuPoint.y - oldPoint.y)^2);
		overallLength = overallLength + oldPoint.len
		spline[#spline+1] = nuPoint;
		oldPoint = nuPoint;
	end
	--for i = 1,#spline do
	--	print("LEN: "..spline[i].len);
	--end
	table.sort(spline, rectangleSorter);
	--table.insert(spline, PointOnPath(points,(#points-2)));
	--print("Computed spline: numOfSteps="..inNumberOfSteps..", #editorPoints="..(#points-2)..", #spline size="..#spline..", delta="..delta..", spline overallLength="..overallLength);
	cachedSplineForLenEstimate = spline;
	newProcessingShape = computeProcessingShape(inNumberOfValuesInSyncFrame, points, spline, overallLength);
	print("Computed Processing Shape: size="..#newProcessingShape..", process.maxSample="..process.maxSample..", max="..maximum(newProcessingShape)..", min="..minimum(newProcessingShape));
	return newProcessingShape
end

process.shapeFunction = computeSpline;



--
--
-- simple gui renderer class 
-- https://wiki.cheatengine.org/index.php?title=Tutorials:Lua:ObjectOriented
-- https://www.tutorialspoint.com/lua/lua_object_oriented.htm
-- 
-- 
Renderer = { prio = 0; };

function Renderer:new(inObj)
	obj = inObj or { prio = 0; };
	setmetatable(obj, {
		__index = Renderer,
		});
	self.__index = self;
	return obj;
end

function Renderer:init(inContext, inConfig)
end

function Renderer:render(inContext, inGraphics)
end

RendererList = {};
function RendererList:new()
	obj = { list={}; };
	setmetatable(obj, {
		__index = RendererList,
		});
	self.__index = self;
	return obj;
end

function RendererList:add(inRenderer) 
	inRenderer.prio = inRenderer.prio or -1;
	self.list[#self.list+1] = inRenderer;
	table.sort(self.list, function(a,b) return a.prio < b.prio end);
end

function RendererList:render(inContext, inGraphics)
	print("RendererList: size="..#self.list);
	for i = 1, #self.list do
		self.list[i]:render(inContext, inGraphics);
	end
end


GridRenderer = Renderer:new();
function GridRenderer:new(inPrio)
	obj = {};
	setmetatable(obj, {
		__index = GridRenderer,
		});
	self.__index = self;
	self.prio = inPrio or -1;
	self.dirty=true;
	return obj;
end

function GridRenderer:init(inContext, inConfig)
	self.x = inConfig.x;
	self.y = inConfig.y;
	self.w = inConfig.w;
	self.h = inConfig.h;
	self.m = inConfig.m or lengthModifiers.normal;
	self.lw = inConfig.lw or 1;
	self.image = juce.Image(juce.Image.PixelFormat.ARGB, self.w, self.h, true);
	self.graphics = juce.Graphics(self.image);
	local g = self.graphics;
	local wi = (self.w / 8) * self.m;
	g:setFillType (juce.FillType(juce.Colour(0,0,0,0)));
	g:fillAll();
	g:setColour(juce.Colour(255,255,255,64))
	for i = 0, self.w, wi do
		g:drawLine(i, 0, i, self.h, self.lw);
	end
	self.dirty = false;
end

function GridRenderer:render(inContext, inGraphics)
	print("GridRenderer");
	if self.dirty then
		-- update image
		self.dirty = false;
	else
		inGraphics:drawImageAt(self.image, self.x, self.y)
	end
end



local grid1 = GridRenderer:new();
grid1:init({}, {x=editorFrame.x, y=editorFrame.y, w=editorFrame.w, h=editorFrame.h, lw=5} );
local grid2 = GridRenderer:new();
grid2:init({}, {x=editorFrame.x, y=editorFrame.y, w=editorFrame.w, h=editorFrame.h, lw=1, m=lengthModifiers.dotted} );
local renderList = RendererList:new();
renderList:add(grid1); 
renderList:add(grid2);

function paintPoints(g) 
	local listOfPoints = MsegGuiModelData.listOfPoints;
	g:setColour   (controlPoints.colour);
	g:setFillType (controlPoints.fill);
	if #listOfPoints > 1 and computedPath then
		g:strokePath(computedPath);
	end
	for i=1,#listOfPoints do
		--print("Draw Rect: "..listOfPoints[i].x..","..listOfPoints[i].y.." / "..listOfPoints[i].w..","..listOfPoints[i].h);
		g:fillRect (listOfPoints[i].x, listOfPoints[i].y, listOfPoints[i].w, listOfPoints[i].h);
	end
	--
	-- spline stuff
	--
	if cachedSplineForLenEstimate then
		--print("Draw spline: "..#cachedSplineForLenEstimate)
		--g:setColour (colourSplinePoints);
		g:setFillType (juce.FillType.white);
		local delta = 256
		while (#cachedSplineForLenEstimate/delta) < 100  and delta > 2 do
			delta = delta/2;
		end;
		for i = 1,#cachedSplineForLenEstimate,delta do
			local p = cachedSplineForLenEstimate[i]
			g:fillRect(p.x-2, p.y-2, 4,4);
		end
	end
	--
	-- processing curve
	--
	if process.processingShape then
		g:setColour (colourProcessingShapePoints);
		curve = process.processingShape
		num=#curve;
		deltaX = editorFrame.w / num;
		local deltaI = 512
		while (num/deltaI) < 150  and deltaI > 2 do
			deltaI = deltaI/2;
		end;
		for i=0,num-1,deltaI do
			x = editorFrame.x+i*deltaX;
			y = editorFrame.y+curve[i]*editorFrame.h;
			g:drawRect(x-2, y-2, 4,4);
		end
	end
	--
	-- all renderers
	--
	local ctx = {}
	renderList:render(ctx,g);
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
--
-- Params
--
--

local allSyncOptions = { _1over64,_1over32,_1over16,_1over8,_1over4,_1over2,_1over1}; 
local allSyncOptionsByName = {}
for i=1,#allSyncOptions do
	allSyncOptionsByName[ allSyncOptions[i].name ] = allSyncOptions[i];  
end

-- function to get all getAllSyncOptionNames of the table of all families
function getAllSyncOptionNames()
  local tbl = {}
  for i,s in ipairs(allSyncOptions) do
    --print(s["name"])
    tbl[#tbl+1]=s["name"];
  end 
  return tbl
end

-- based on the sync name of the parameter set the selected sync values
function updateSync(arg)
	local s = allSyncOptionsByName[arg];
	if s ~= selectedNoteLen.syncOption then
		newNoteLen = { syncOption=s; ratio=s["ratio"]; modifier=selectedNoteLen.modifier; ratio_mult_modifier =  s["ratio"] * selectedNoteLen.modifier;};
		selectedNoteLen = newNoteLen;
		process.onceAtLoopStartFunction = resetProcessingShape;
	end
	return; 
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
	{
		name = "Normalize negative to zero";
		type = "list";
		values = { "false", "true"};
		default = "false";
		changed = function (val) process.normalizeTero = (val=="true") end;
	};
}

--------------------------------------------------------------------------------------------------------------------
--
-- Load and Save Data
--	
local header = "AmplitudeKungFu"

function script.loadData(data)
	-- check data begins with our header
	if string.sub(data, 1, string.len(header)) ~= header then return end
	print("Deserialized: allData="..data);
	local vers = string.match(data, "\"fileVersion\"%s*:%s*(%w*),");
	print("Deserialized: version="..vers);
	--
	local sync = string.match(data, "\"sync\"%s*:%s*(%d*%.?%d*),");
	print("Deserialized: sync="..sync);
	plugin.setParameter(0,sync);
	--
	local power = string.match(data, "\"power\"%s*:%s*(%d*%.?%d*),");
	print("Deserialized: power="..power);
	plugin.setParameter(1,power);
	--
	local points = string.match(data, "\"points\"%s*:%s*%[%s*(.-)%s*%]");
	print("Deserialized: points="..points);
	--
	local floatValues = {}
	for s in string.gmatch(points, "\"[xy]\"%s*=%s*(.-)[,%}]") do
		floatValues[#floatValues+1]=s;
	end
	local newListOfPoints ={};
	for i=1,#floatValues,2 do
		local p = createControlPointAtNormalizedCoord(floatValues[i], floatValues[i+1]);
		newListOfPoints[#newListOfPoints+1] = p;
	end
	table.sort(newListOfPoints, rectangleSorter);
	MsegGuiModelData.listOfPoints = newListOfPoints;
	controlPointsHaveBeenChangedHandler();
end

function script.saveData()
	local listOfPoints=MsegGuiModelData.listOfPoints;
	local picktable = {};
	local offset = controlPoints.offset;
	for i=1,#listOfPoints do
		picktable[i] = controlPointToNormalizedPoint(listOfPoints[i]);
		--print("LOP: x="..listOfPoints[i].x+offset.."; y="..listOfPoints[i].y+offset);
		--print("POINT: "..string.format("%s",picktable[i]));
	end
	local serialized=header..": { "
	        .."\"fileVersion\": V1"
			..", \"sync\": "..plugin.getParameter(0)
			..", \"power\": " ..plugin.getParameter(1)
			..", \"points\": [".. serializeListofPoints(picktable).."]" 
		.." }";
	print("Serialized: "..serialized);
	return serialized;
end

function serializeListofPoints(inListOfPoints)
	local s ="";
	local sep="";
	for i=1,#inListOfPoints do
		s=s..sep..string.format("%s",inListOfPoints[i]);
		sep=",";
	end
	return s;
end

--
--
-- simple point class with a  __tostring metamethod
-- https://wiki.cheatengine.org/index.php?title=Tutorials:Lua:ObjectOriented
-- 
-- 
Point = {x = 0; y=0 };

function Point:new(inObj)
	inObj = inObj or {}
	setmetatable(inObj, {
		__index = Point,
		__tostring = function(a)
			return "{\"x\"="..a.x..", \"y\"="..a.y.."}";
		end
		});
	self.__index = self;
	return inObj;
end

function Point.from(inControlPoint) 
	return ;
end



---------------------------------------------------------------------------------------------------------------------
--
-- spline computation routine
-- https://forums.coregames.com/t/spline-generator-through-a-sequence-of-points/401
-- https://pastebin.com/2JZi2wvH
-- https://www.youtube.com/watch?v=9_aJGUTePYo
--
function PointOnPath(inPoints, t) -- catmull-rom cubic hermite interpolation
    if progress == 1 then return nodeList[#nodeList] end
	p0 = math.floor(t);
	--print("P0"..p0..", t="..t);
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
	
	return { x=tx; y=ty; len=0 };
end
