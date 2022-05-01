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
local lengthModifiers = {
	normal = 1.0,
	dotted = 3.0 / 2.0,
	triplet = 2.0 / 3.0
}

-- ppq is based on 1/4 notes
local ppqBaseValue = {
	noteNum = 1.0,
	noteDenom = 4.0,
	ratio = 0.25
}

local _1over64 = {name = "1/64", ratio = 1.0 / 64.0}
local _1over32 = {name = "1/32", ratio = 1.0 / 32.0}
local _1over16 = {name = "1/16", ratio = 1.0 / 16.0}
local _1over8 = {name = "1/8", ratio = 1.0 / 8.0}
local _1over4 = {name = "1/4", ratio = 1.0 / 4.0}
local _1over2 = {name = "1/2", ratio = 1.0 / 2.0}
local _1over1 = {name = "1/1", ratio = 1.0 / 1.0}

--
--
--  Local Fct Pointer
--
--
local m_2int = math.ceil
local m_floor = math.floor;
local m_ceil = math.ceil;
local m_max = math.max;
local m_min = math.min;
--
--
--  Debug Stuff
--
--
function noop()
end

local dbg = noop
-- _D_ebug flag for using in D and "" or <do stuff>
local D = true -- set to true if there's no debugging D and "" or <concatenate string>
--
--
--MAIN LOOP
--
--
local left = 0 --left channel
local right = 1 --right channel
local runs = 0 -- just for debugging purpose. counts the number processBlock has been called
local lastppq = 0 --  use it to be able to compute the distance in samples based on the ppq delta from loop a to a+1
local selectedNoteLen = {
	syncOption = _1over8,
	ratio = _1over8.ratio,
	modifier = lengthModifiers.normal,
	ratio_mult_modifier = _1over8.ratio * lengthModifiers.normal
}
local globals = {
	samplesCount = 0,
	sampleRate = -1,
	sampleRateByMsec = -1,
	isPlaying = false,
	bpm = 0
}

--
--
-- Define Process - the process covers all data relevant to process a "sync frame"
--
--
local ProcessData = {
	maxSample = -1,
	currentSample = -1,
	--delta = -1;
	power = 0.0,
	processingShape = {}, -- the processing shape which is used to manipulate the incoming samples
	processingShapeByPower = {}, -- the processing shape taking the "power" parameter already into account
	bufferUn = {},
	bufferProc = {},
	shapeFunction = initSigmoid, --computeSpline; --initSigmoid
	onceAtLoopStartFunction = noop
}


function plugin.processBlock(samples, smax) -- let's ignore midi for this example
	position = plugin.getCurrentPosition()
	if position.bpm ~= globals.bpm then
		--TODO: add an eventing mechanism.
		resetProcessingShape(ProcessData)
	end
	globals.bpm = position.bpm
	--
	-- preset samplesToNextCount;
	local samplesToNextCount = -1

	-- compute stuff
	-- 1. length in milliseconds of the selected noteLength
	local noteLenInMsec = noteLength2Milliseconds(selectedNoteLen, position.bpm)
	-- 2. length of a slected noteLength in samples
	local noteLenInSamples = noteLength2Samples(noteLenInMsec, globals.sampleRateByMsec)

	ProcessData.onceAtLoopStartFunction(ProcessData)
	ProcessData.onceAtLoopStartFunction = noop

	if position.isPlaying then
		-- 3. "ppq" of the specified notelen ... if we don't count 1/4 we have to count more/lesse depending on selected noteLength
		local ppqOfNoteLen = position.ppqPosition * quater2selectedNoteFactor(selectedNoteLen)
		-- 4. the delta in "ppq" relative to the selected noteLength
		local deltaToNextCount = m_2int(ppqOfNoteLen) - ppqOfNoteLen
		-- 5. the number of samples that is delta to the next count based on selected noteLength
		samplesToNextCount = m_2int(deltaToNextCount * noteLenInSamples)

		setProcessAt(ProcessData, samplesToNextCount, noteLenInSamples)

		if not globals.isPlaying then
			globals.isPlaying = true
		end

		-- next is debug stmt: computes the estimate of processed samples based on a difference of ppq between loops
		-- print((ppqOfNoteLen - lastppq)*noteLenInSamples);

		-- NOTE: if  samplesToNextCount < smax then what ever you are supposed to start has to start in this frame!
		if samplesToNextCount < smax then
			dbg(
				D and "" or
					"Playing: runs=" ..
						runs ..
							"; ppq=" ..
								position.ppqPosition ..
									"; 1/8 base ppq=" ..
										ppqOfNoteLen ..
											"( " ..
												noteLenInSamples ..
													" ); samplesToNextCount=" ..
														samplesToNextCount ..
															"; maxSample=" .. ProcessData.maxSample .. "; currentSample=" .. ProcessData.currentSample .. "; smax=" .. smax
			)
		end
		if ProcessData.currentSample + samplesToNextCount > ProcessData.maxSample then
			dbg(
				D and "" or
					"Warning: runs=" ..
						runs ..
							"; ppq=" ..
								position.ppqPosition ..
									"; 1/8 base ppq=" ..
										ppqOfNoteLen ..
											"( " ..
												noteLenInSamples ..
													" ); samplesToNextCount=" ..
														samplesToNextCount ..
															"; maxSample=" .. ProcessData.maxSample .. "; currentSample=" .. ProcessData.currentSample .. "; smax=" .. smax
			)
		end
		runs = runs + 1
		lastppq = ppqOfNoteLen
	else
		-- in none playing mode we don't have the help of the ppq... we have to do heuristics by using the globalSamples...
		-- 3. a heuristically computed position based on the samples
		local noteCount = globals.samplesCount / noteLenInSamples
		-- 4. the delta to the count
		local deltaToNextCount = m_2int(noteCount) - noteCount
		-- 5. the number of samples that is delta to the next count based on selected noteLength
		samplesToNextCount = m_2int(deltaToNextCount * noteLenInSamples)

		setProcessAt(ProcessData, samplesToNextCount, noteLenInSamples)

		if globals.isPlaying then
			globals.isPlaying = false
		end

		if samplesToNextCount < smax then
			dbg(
				D and "" or
					"NOT Playing - global samples: " ..
						globals.samplesCount ..
							" 1/8 base count: " ..
								noteCount ..
									"(" .. noteLenInSamples .. ") --> " .. samplesToNextCount .. " ProcessData.currentSample:" .. ProcessData.currentSample
			)
		end
	end

	-- post condition here: samplesToNextCount != -1
	for i = 0, smax do
		if i == samplesToNextCount then
			-- we have reached a frame end
			createImageStereo(ProcessData, ProcessData.currentSample - i, i)
			repaintIt()
			setProcessAt(ProcessData, 0, noteLenInSamples)
		else
			if not progress(ProcessData) then
				dbg(D and "" or "Warning i: " .. i .. "; samplesToNextCount: " .. samplesToNextCount)
			end
		end
		samples[0][i] = apply(left, ProcessData, samples[0][i]) -- left channel
		samples[1][i] = apply(right, ProcessData, samples[1][i]) -- right channel
	end
	if samplesToNextCount >= smax then
		createImageStereo(ProcessData, ProcessData.currentSample - smax, smax)
	end

	globals.samplesCount = globals.samplesCount + smax + 1
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
	return (ppqBaseValue.ratio) / (inNoteLength.ratio_mult_modifier)
end

-- It's based on the formular for quarters into seconds, i.e. 60/BPM
-- this here is then giving milliseconds (1000) and can compute based on any given noteLength. So for 1/4 to get the 60 we have to start with 240...
-- and we even don't forget modifiers, i.e. dotted and triplet...
function noteLength2Milliseconds(inNoteLength, inBPM)
	--return (1000 * 240 * (inNoteLength.noteNum / inNoteLength.noteDenom) * inNoteLength.lengthModifier) / inBPM;
	return (240000.0 * inNoteLength.ratio_mult_modifier) / inBPM
end

-- Have a conversion function to get samples per noteLenght
-- assume we have rate = 48000 samples/second, that is rate/1000 as samples per millisecond.
-- then just multiplay the length in milliseconds based on the current beat.
function noteLength2Samples(inNoteLengthInMsec, inSampleRateByMsec)
	return inSampleRateByMsec * inNoteLengthInMsec
end

-----------------------------------------------
-- computes a sigmoid function processing shape
-- in: size in samples
-- return: sigmoid function array
function initSigmoid(sizeInSamples)
	local expFct = math.exp
	local sigmoid = {}
	local delta = (6 - (-6)) / sizeInSamples
	for i = 1, sizeInSamples + 10 do
		local t = -6 + i * delta
		sigmoid[i] = 1 / (1 + expFct(-t))
	end
	dbg(D and "" or "INIT Sigmoid " .. #sigmoid .. " sizeInSamples: " .. sizeInSamples)
	return sigmoid
end


-- Sets the current "position" (in samples) when we are processing one specific "sync frame"
--
-- inSamplesToNextCount - the number of samples left in this "sync frame". if 1/8 for example requires 9730 samples and we have already counted 7000, then there's 2730 samples left.
-- inNoteLenInSamples - the number of a sync frame, i.e. probably it's 9730 samples for 1/8 based on 148 bpm.
--
-- outProcess.maxSample, outProcess.currentSample
function setProcessAt(outProcess, inSamplesToNextCount, inNoteLenInSamples)
	local intNoteLenInSamples = m_2int(inNoteLenInSamples)
	outProcess.maxSample = intNoteLenInSamples
	if 0 == inSamplesToNextCount then
		-- here we reached the end of the curent counting time
		outProcess.currentSample = 0
	else
		-- here we set the current sample
		outProcess.currentSample = intNoteLenInSamples - inSamplesToNextCount
	end
	if #outProcess.processingShape == 0 then
		outProcess.processingShape = outProcess.shapeFunction(outProcess.maxSample)
		computeProcessingShapeByPower(outProcess)
	end
	--print("INIT-AT: sig="..#process.processingShape.."; maxSample=".. process.maxSample .."; currentSample="..process.currentSample.."; samplesToNextCount="..samplesToNextCount);

	if outProcess.currentSample + inSamplesToNextCount > outProcess.maxSample then
		dbg(
			D and "" or
				"SET-AT: Assertion Fail. position + rmaining samples computation exceeds maxSamples" ..
				"; currentSample=" .. outProcess.currentSample ..
				"; inSamplesToNextCount=" .. inSamplesToNextCount ..
				"; maxSample=" .. outProcess.maxSample
		)
	end
end

--
-- computes a cached version of the processing shape which already takes the "power" parameter into consideration
--
function computeProcessingShapeByPower(outProcess)
	if #outProcess.processingShape ~= 0 then
		for i = 0, #outProcess.processingShape do
			outProcess.processingShapeByPower[i] = 1 - outProcess.power + outProcess.processingShape[i] * outProcess.power
		end
	end
end

--
-- resets the processingShape and processingShapeByPower to be empty
--
function resetProcessingShape(inProcess)
	inProcess.processingShape = {}
	inProcess.processingShapeByPower = {}
end

function progress(inProcess)
	inProcess.currentSample = inProcess.currentSample + 1
	if (#inProcess.processingShape < inProcess.currentSample) then
		dbg(
			D and "" or
				"Warning! progress: sig=" ..
					#inProcess.processingShape ..
						"; maxSample=" .. inProcess.maxSample .. "; currentSample=" .. inProcess.currentSample
		)
		return false
	end
	return true
end
--
-- applies the processingShapeByPower to the incoming samples and takes inProcess.currentSample into account.
--
function apply(inChannel, inProcess, inSample)
	--print("Sig: "..process.currentSample)
	local currentSample = inProcess.currentSample
	if (#inProcess.processingShape < currentSample) then
		dbg(
			D and "" or
				"Warning! apply: sig=" ..
					#inProcess.processingShape .. "; maxSample=" .. inProcess.maxSample .. "; currentSample=" .. currentSample
		)
	end
	--print("Apply: processingShape="..#inProcess.processingShapeByPower..", currentSample="..currentSample..", max="..maximum(inProcess.processingShapeByPower)..", min="..minimum(inProcess.processingShapeByPower));
	--print("Value: "..inProcess.processingShapeByPower[currentSample]);
	local result = inProcess.processingShapeByPower[currentSample] * inSample
	local idx = (currentSample * 2) + inChannel
	inProcess.bufferUn  [idx] = inSample
	inProcess.bufferProc[idx] = result
	return result
end

local function prepareToPlayFct()
	globals.sampleRate = plugin.getSampleRate()
	globals.sampleRateByMsec = plugin.getSampleRate() / 1000.0
	--print("Sample Rate:"..global.sampleRate)
end

plugin.addHandler("prepareToPlay", prepareToPlayFct)

--
--
-- GUI Definitions
--
--
local colourSampleProcessed = juce.Colour(0, 255, 0, 192)
local colourSampleOriginald = juce.Colour(255, 0, 0, 128)
local coloursSamples = {colourSampleOriginald, colourSampleProcessed}

local colourSplinePoints = juce.Colour(255, 255, 255, 255)
local colourProcessingShapePoints = juce.Colour(0, 64, 255, 255)

local width = 840
local height = 360
local frame = juce.Rectangle_int(100, 10, width, height)

-- double buffering
local db1 = juce.Image(juce.Image.PixelFormat.RGB, width, height, true) -- juce.Image.PixelFormat.ARGB
local db2 = juce.Image(juce.Image.PixelFormat.RGB, width, height, true)
local dbufImage = {[0] = db1, [1] = db2}
local dbufGraphics = {[0] = juce.Graphics(db1), [1] = juce.Graphics(db2)}
local dbufIndex = 0
--
local ControlPointsDefinition = {
	side = 16,
	offset = 8,
	colour = juce.Colour(255, 64, 0, 255),
	fill = juce.FillType(juce.Colour(255, 64, 0, 255))
}

--
--
-- GUI Functions
--
--
function repaintIt()
	local guiComp = gui:getComponent()
	if guiComp and ProcessData.currentSample > 0 then
		--createImageStereo(process);
		--createImageMono(left);
		guiComp:repaint(frame)
	end
end

function createImageStereo(inProcess, optFrom, optLen)
	-- keep in mind we have intertwind left right... so compute the buffer index with that in mind.
	local from = (optFrom or 0) * 2
	local len = (optLen or inProcess.maxSample - from) * 2
	local to = from + len

	if from == 0 and len == 0 then
		dbg(D and "" or "createImageStereo; from=" .. from .. "; to=" .. to)
		return
	end
	--
	--dbufIndex = 1-dbufIndex;
	--local img = dbufImage[dbufIndex];
	local imgG = dbufGraphics[dbufIndex]
	--local middleY = frame.h/2
	local maxHeight = frame.h / 4
	local middleYLeft = frame.h / 4
	local middleYRight = middleYLeft + frame.h / 2
	--imgG:fillAll();

	local maxSample = inProcess.maxSample
	if maxSample > 0 then
		--remember we have interwined left and right channel, i.e. double the size samples... therefore we need 0.5 delta
		local delta = 0.5 * (frame.w / maxSample)
		local compactSize = m_ceil(maxSample / frame.w) -- if there's lots more samples than x-coordinates...
		if compactSize < 2 then
			compactSize = 2 -- minimum is 2 because of the intertwined samples
		end
		local deltaX = compactSize * delta; --- we can us this to simply add xcoordinates
		--
		local buffers = {inProcess.bufferUn, inProcess.bufferProc}
		-- now first fill the current "window" representing the current sample-buffer
		imgG:setColour(juce.Colour.black)
		imgG:fillRect(from * delta, 0, to * delta, frame.h)
		-- then fill with the sample data
		imgG:setColour(juce.Colour.green)
		imgG:drawRect(1, 1, frame.w, frame.h)
		for i = 1, #buffers do
			local buf = buffers[i]
			imgG:setColour(coloursSamples[i])
			local x = from * delta; -- start x coordinate from here ...
			for j = from, to, compactSize do
				local yLeft  = middleYLeft  - buf[j + left]  * maxHeight;
				local yRight = middleYRight - buf[j + right] * maxHeight;
				imgG:drawVerticalLine(x, m_min(middleYLeft,yLeft),   m_max(middleYLeft,yLeft));
				imgG:drawVerticalLine(x, m_min(middleYRight,yRight), m_max(middleYRight,yRight));
				x = x + deltaX -- add delta x as we go
			end
		end
	end
end

function createImageMono(inWhich)
	if inWhich ~= left and inWhich ~= right then
		return
	end
	dbufIndex = 1 - dbufIndex
	local img = dbufImage[dbufIndex]
	local imgG = juce.Graphics(img)
	local middleY = frame.h / 2
	imgG:fillAll()
	imgG:setColour(juce.Colour.green)
	imgG:drawRect(1, 1, frame.w, frame.h)
	if ProcessData.maxSample > 0 then
		local delta = frame.w / ProcessData.maxSample
		local compactSize = m_ceil(ProcessData.maxSample / frame.w)
		if compactSize < 1 then
			compactSize = 1
		end
		local buffers = {ProcessData.bufferUn, ProcessData.bufferProc}
		for i = 1, #buffers do
			local b = buffers[i]
			imgG:setColour(coloursSamples[i])
			--remember we have interwined left and right channel, i.e. double the size samples of an individual channel...
			local deltaReal = delta * 0.5
			for j = 0, #b - 1, compactSize do
				local x = j * deltaReal
				--local samp = math.abs(b[i]);
				imgG:drawLine(x, middleY, x, middleY - b[j + inWhich] * middleY)
			end
		end
	end
end

function gui.paint(g)
	g:fillAll()
	paintPoints(g)
end

-- 
--
-- Editing the Pumping function
--
--
function rectangleSorter(a, b)
	--print("Sorter: "..a.x..", "..b.x);
	return a.x < b.x
end

--
--  Coordinate Stuff
--
-- coordinate system to display and manage editor points in
local editorFrame = frame
local editorStartPoint = juce.Point(editorFrame.x, editorFrame.y + editorFrame.h)
local editorEndPoint = juce.Point(editorFrame.x + editorFrame.w, editorFrame.y + editorFrame.h)

--
-- some "cached" things, 1st the linear path, 2nd the catmul spline.
--
local MsegGuiModelData = {
	listOfPoints = {},
	computedPath = nil,
	cachedSplineForLenEstimate = nil
}

--
-- Creates a control point given in gui model space
-- if we have coordiantes in gui model space, simply create it.
-- source could be mouseevent
-- in: inX and inY given in gui model space
-- out: a juce.Rectangle
--
function createControlPointAtGuiModelCoord(inX, inY)
	local side = ControlPointsDefinition.side
	local offset = ControlPointsDefinition.offset
	return juce.Rectangle_int(inX - offset, inY - offset, side, side)
end
--
-- Creates a control point given in gui model space
-- if we have coordiantes in gui model space, simply create it.
-- source could be mouseevent
-- in: inCoord.x, inCoord.y given in gui model space
-- out: a juce.Rectangle
--
function createControlPointAtGuiModelCoord(inCoord)
	local side = ControlPointsDefinition.side
	local offset = ControlPointsDefinition.offset
	return juce.Rectangle_int(inCoord.x - offset, inCoord.y - offset, side, side)
end
--
-- Creates a control point given in normalized [0,1] space
-- if we have coordiantes in normalized space, simply create it.
-- source could be a serialized/state saved point
-- in: inX, inY in normalized space
-- out: a juce.Rectangle in gui model space
--
function createControlPointAtNormalizedCoord(inX, inY)
	local side = ControlPointsDefinition.side
	local offset = ControlPointsDefinition.offset
	return juce.Rectangle_int(
		inX * editorFrame.w + editorFrame.x - offset,
		(1.0 - inY) * editorFrame.h + editorFrame.y - offset,
		side,
		side
	)
end
--
-- Transforms from gui model control point to normalized space point
--
function controlPointToNormalizedPoint(inControlPoint)
	--local side = ControlPointsDefinition.side;
	local offset = ControlPointsDefinition.offset
	return Point:new {
		x = (inControlPoint.x + offset - editorFrame.x) / editorFrame.w,
		-- turn y upside down!
		y = (editorFrame.h - inControlPoint.y + offset - editorFrame.y) / editorFrame.h
	}
end

--
-- editing points
--
DragState = {
	dragging = false,
	fct = nil,
	selected = nil,
	counter = 0
}

function DragState:startDrag(inMouseEvent)
	local listOfPoints = MsegGuiModelData.listOfPoints
	dbg(D and "" or "StartDrag: " .. inMouseEvent.x .. "," .. inMouseEvent.y)
	for i = 1, #listOfPoints do
		-- the listOfPoints is all in the sample view coordinate system.
		dbg(D and "" or listOfPoints[i]:contains(inMouseEvent))
		if listOfPoints[i]:contains(inMouseEvent) then
			--we hit an existing point here --> remove it
			DragState.selected = listOfPoints[i]
			DragState.fct = DragState.doDrag
			DragState.dragging = true
			return
		end
	end
end

DragState.fct = DragState.startDrag

function DragState:doDrag(inMouseEvent)
	local listOfPoints = MsegGuiModelData.listOfPoints
	if editorFrame:contains(inMouseEvent) then
		dbg(
			D and "" or
				"DoDrag: " ..
					inMouseEvent.x .. "," .. inMouseEvent.y .. "; " .. DragState.selected.x .. ", " .. DragState.selected.y
		)
		if DragState.selected then
			local offset = ControlPointsDefinition.offset
			if editorFrame:contains(inMouseEvent) then
				DragState.selected.x = inMouseEvent.x - offset
				DragState.selected.y = inMouseEvent.y - offset
			end
			table.sort(listOfPoints, rectangleSorter)
			-- NOTE: don't call the controlPointsHaveBeenChangedHandler in the course of a drag - it's not efficient
			computePath()
			DragState.counter = (DragState.counter + 1) % 20
			if DragState.counter==0 then 
				repaintIt()
			end;
		end
	end
end

function mouseUpHandler(inMouseEvent)
	dbg(D and "" or "Mouse up: " .. inMouseEvent.x .. "," .. inMouseEvent.y)
	if DragState.dragging then
		local offset = ControlPointsDefinition.offset
		if editorFrame:contains(inMouseEvent) then
			DragState.selected.x = inMouseEvent.x - offset
			DragState.selected.y = inMouseEvent.y - offset
		end
		DragState.fct = DragState.startDrag
		DragState.selected = nil
		DragState.dragging = false
		ProcessData.onceAtLoopStartFunction = resetProcessingShape
	end
end

function mouseDragHandler(inMouseEvent)
	dbg(D and "" or "Drag: " .. inMouseEvent.x .. "," .. inMouseEvent.y .. "; " .. (DragState.fct and "fct" or "nil"))
	if nil == DragState.fct then
		DragState.fct = DragState.startDrag
	end
	DragState:fct(inMouseEvent)
end

function mouseDoubleClickHandler(inMouseEvent)
	local dirty = mouseDoubleClickExecution(inMouseEvent)
	if dirty then
		controlPointsHaveBeenChangedHandler()
	end
end

function controlPointsHaveBeenChangedHandler()
	computePath()
	ProcessData.onceAtLoopStartFunction = resetProcessingShape
	--repaintIt()
end

-- in: MouseEvent from framework
-- return: true if dirty - point has been removed or added. stuff needs recalculation
function mouseDoubleClickExecution(inMouseEvent)
	local listOfPoints = MsegGuiModelData.listOfPoints
	-- first figure out whether we hit an existing point - if yes deletet this point.
	dbg(D and "" or "DblClick: x=" .. inMouseEvent.x .. ", y=" .. inMouseEvent.y .. ", len=" .. #listOfPoints)
	for i = 1, #listOfPoints do
		-- the listOfPoints is all in the sample view coordinate system.
		print(listOfPoints[i]:contains(inMouseEvent))
		if listOfPoints[i]:contains(inMouseEvent) then
			--we hit an existing point here --> remove it
			table.remove(listOfPoints, i)
			return true
		end
	end
	-- seems we create a new one here
	if editorFrame:contains(inMouseEvent) then
		-- relative to editor frame
		dbg("Create Point: " .. inMouseEvent.x .. "," .. inMouseEvent.y)
		local newPoint = createControlPointAtGuiModelCoord(inMouseEvent)
		listOfPoints[#listOfPoints + 1] = newPoint
		-- the point is added at the end of the table, though it could be in the middle of the display.
		-- in order to draw the path correctly later we sort the points according to their x coordinate.
		table.sort(listOfPoints, rectangleSorter)
		return true
	end
	return false
end

function computePath()
	local listOfPoints = MsegGuiModelData.listOfPoints
	if #listOfPoints > 1 then
		local path = juce:Path()
		path:startNewSubPath(editorStartPoint.x, editorStartPoint.y)
		local side = ControlPointsDefinition.side
		local offset = ControlPointsDefinition.offset
		for i = 1, #listOfPoints do
			path:lineTo(listOfPoints[i].x + offset, listOfPoints[i].y + offset)
		end
		path:lineTo(editorEndPoint.x, editorEndPoint.y)
		MsegGuiModelData.computedPath = path
		PRenderer:updatePath(path)
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
	local maxY = editorFrame.y + editorFrame.h
	local heigth = editorFrame.h
	local deltaX = editorFrame.w / inNumberOfValuesInSyncFrame
	local newProcessingShape = {}
	--print("Computed Processing Shape Start: inNumberOfValuesInSyncFrame="..inNumberOfValuesInSyncFrame..", #inPointsOnPath="..#inPointsOnPath..", #inSpline="..#inSpline..", inOverallLength="..inOverallLength..", deltaX="..deltaX);
	local shapeMinY = 10000
	local shapeMaxY = -10000
	--
	-- first pass compute raw values
	-- note: the values can be lower than 0 and higher than 1 due to the nature of the spline.
	for i = 1, inNumberOfValuesInSyncFrame + 1 do
		local xcoord = editorFrame.x + deltaX * i
		local IDX = -1
		for j = #inSpline - 1, 1, -1 do
			if inSpline[j].x < xcoord then
				IDX = j
				break
			end
		end
		-- IDX < xcoord
		-- IDX+1 > xcoord
		--print("IDX xcoord="..xcoord..", IDX="..IDX)
		--print("IDX x[IDX]="..inSpline[IDX].x..", x[IDX+1]="..inSpline[IDX+1].x);
		local tangent = (inSpline[IDX + 1].y - inSpline[IDX].y) / (inSpline[IDX + 1].x - inSpline[IDX].x)
		local valueY = inSpline[IDX].y + (xcoord - inSpline[IDX].x) * tangent
		local normalizedY = (maxY - valueY) / heigth
		--
		--if normalizedY < 0 then normalizedY = 0 end;
		shapeMinY = (normalizedY < shapeMinY) and normalizedY or shapeMinY
		shapeMaxY = (normalizedY > shapeMaxY) and normalizedY or shapeMaxY
		--
		newProcessingShape[i - 1] = normalizedY
	end
	--
	-- second pass compute adjusted values in [0,1]
	-- note: the values can be lower than 0 and higher than 1 due to the nature of the spline.
	-- note: array index is 0 based in this loop!
	local adjustMin = 0
	local process = false
	if shapeMinY < 0 then
		adjustMin = shapeMinY
		process = true
	end
	local factor = 1
	if shapeMaxY - shapeMinY > 1 then
		factor = 1 / (shapeMaxY - shapeMinY)
		process = true
	end
	dbg(D and "" or
		"Adjusting Processing Shape: size=" ..
			#newProcessingShape ..
				", max=" .. shapeMaxY .. ", min=" .. shapeMinY .. ", factor=" .. factor .. ", adjust=" .. adjustMin
	)
	if process then
		for i = 0, #newProcessingShape - 1 do
			newProcessingShape[i] = factor * (newProcessingShape[i] - adjustMin)
		end
	end
	dbg(D and "" or
		"Adjusted Processing Shape: size=" ..
			#newProcessingShape .. ", max=" .. maximum(newProcessingShape) .. ", min=" .. minimum(newProcessingShape)
	)

	return newProcessingShape
end

-----------------------------------
-- in: number of values/samplesrepresenting a sync frame
-- return: processing shape based on spline, index is 0-based!!!!
function computeSpline(inNumberOfValuesInSyncFrame)
	local listOfPoints = MsegGuiModelData.listOfPoints
	local spline = {}
	local points = {}
	local numPoint = #listOfPoints
	-- we need at least 4 points
	points[1] = editorStartPoint
	points[#points + 1] = editorStartPoint
	if numPoint >= 1 then
		local offset = ControlPointsDefinition.offset
		for i = 1, numPoint do
			points[#points + 1] = {x = listOfPoints[i].x + offset, y = listOfPoints[i].y + offset, len = 0}
		end
	end
	-- insert 2 points because we need an extra point by the nature of the computation: it needs 4 points for each segment, i.e. endpoint + one
	points[#points + 1] = editorEndPoint
	points[#points + 1] = editorEndPoint

	--
	--print("Sort");
	table.sort(points, rectangleSorter)
	--for i = 1,#points do
	--print("X-Coord: "..points[i].x);
	--end
	-- now compute spline points for the length estimate
	local delta = 0.05 --(#points-3) / inNumberOfSteps
	local sqrtFct = math.sqrt
	local oldPoint = {x = editorStartPoint.x, y = editorStartPoint.y, len = 0}
	local overallLength = 0.0
	spline[1] = oldPoint
	for t = 1.0, (#points - 2), delta do
		local nuPoint = PointOnPath(points, t)
		oldPoint.len = sqrtFct((nuPoint.x - oldPoint.x) ^ 2 + (nuPoint.y - oldPoint.y) ^ 2)
		overallLength = overallLength + oldPoint.len
		spline[#spline + 1] = nuPoint
		oldPoint = nuPoint
	end
	--for i = 1,#spline do
	--	print("LEN: "..spline[i].len);
	--end
	--table.sort(spline, rectangleSorter)
	--table.insert(spline, PointOnPath(points,(#points-2)));
	--print("Computed spline: numOfSteps="..inNumberOfSteps..", #editorPoints="..(#points-2)..", #spline size="..#spline..", delta="..delta..", spline overallLength="..overallLength);
	MsegGuiModelData.cachedSplineForLenEstimate = spline
	newProcessingShape = computeProcessingShape(inNumberOfValuesInSyncFrame, points, spline, overallLength)
	dbg(D and "" or
		"Computed Processing Shape: size=" ..
			#newProcessingShape ..
				", process.maxSample=" ..
					ProcessData.maxSample .. ", max=" .. maximum(newProcessingShape) .. ", min=" .. minimum(newProcessingShape)
	)
	return newProcessingShape
end

ProcessData.shapeFunction = computeSpline

--
--
-- simple gui renderer class
-- https://wiki.cheatengine.org/index.php?title=Tutorials:Lua:ObjectOriented
-- https://www.tutorialspoint.com/lua/lua_object_oriented.htm
--
-- https://somedudesays.com/2020/02/getting-classy-with-inheritance-in-lua/
--
local Renderer = {}
function Renderer:new(inPrio)
	local o = { prio = inPrio and inPrio or 0; dirty = false}
	setmetatable(o, self)
	self.__index = self
	return o
end

function Renderer:init(inContext, inConfig)
	print("Renderer INIT; self=".. string.format("%s", self) );
end

--
-- IN: inClipArea - the original Clip Area of the portion to render new
--
function Renderer:render(inContext, inGraphics, inClipArea)
end

function Renderer:isDirty(inContext)
	return self.dirty
end

--
local RendererList = {}
function RendererList:new()
	local o = { list = {} }
	setmetatable(o, self)
	self.__index = self
	return o
end

function RendererList:add(inRenderer)
	inRenderer.prio = inRenderer.prio or -1
	self.list[#self.list + 1] = inRenderer
	table.sort(
		self.list,
		function(a, b)
			return a.prio < b.prio
		end
	)
	return self
end

function RendererList:render(inContext, inGraphics, inClipArea)
	--print("RendererList: size="..#self.list);
	for i = 1, #self.list do
		self.list[i]:render(inContext, inGraphics, inClipArea)
	end
end

--
-- Renderer Base Class which uses directly renders to a area on screen
-- can be configured with x,y,w,h
--
local DirectFrameRenderer = {}
function DirectFrameRenderer:new(inPrio)
	local o = Renderer:new(inPrio)
	o.dirty = true
	setmetatable(o, self)
	self.__index = self
	return o
end

function DirectFrameRenderer:init(inContext, inConfig)
	print("DirectFrameRenderer INIT; self=".. string.format("%s", self) .."; inConfig.x="..inConfig.x.."; inConfig.y="..inConfig.y.."; inConfig.w="..(inConfig.w or "N/A").."; inConfig.h="..(inConfig.h or "N/A"));
	Renderer.init(self, inContext, inConfig) --super call with explicit self!
	self.x = inConfig.x
	self.y = inConfig.y
	self.w = inConfig.w
	self.h = inConfig.h
	self.dirty = false
end

--
-- GridRenderer Class which renders a grid
-- subcass of DirectFrameRenderer
-- Note: Understand the using GridRenderer = DirectFrameRenderer:new() means GridRenderer already inherits all stuff from DirectFrameRenderer
--
local GridRenderer = {} 
function GridRenderer:new(inPrio)
	local o = DirectFrameRenderer:new(inPrio) -- super
	o.dirty=true
	setmetatable(o, self)
	self.__index = self
	return o
end

function GridRenderer:init(inContext, inConfig)
	print("GridRenderer INIT; self=".. string.format("%s", self));
	DirectFrameRenderer.init(self, inContext, inConfig) --super call with explicit self!
	self.ratio = inConfig.ratio or _1over1
	self.mod =  inConfig.m or lengthModifiers.normal
	self.lw = inConfig.lw or 1;
	self.opacity = inConfig.opacity or 1;
	if self.opacity > 1 then self.opacity = 1 end
	if self.opacity < 0 then self.opacity = 0 end
	self.dirty = true
	local delta_i = self.w * self.ratio.ratio * self.mod
	local halfLineWidth = self.lw/2
	local lines = {}
	for i = 0, self.w, delta_i do
		lines[#lines+1] = self.x+i-halfLineWidth
	end
	self.lines = lines;
end

function GridRenderer:render(inContext, inGraphics, inClipArea)
	--print("GridRenderer render; lw=" .. self.lw .. "; self.h=" .. (self.h or "N/A"))
	local g = inGraphics
	g:setColour(juce.Colour(255, 255, 255))
	g:setOpacity(self.opacity)
	local lines = self.lines;
	for i = 1,#lines do
		g:fillRect(lines[i], self.y, self.lw, self.h)
	end
	self.dirty = false
end

--
-- PathRenderer Class which renders a grid
--
local PathRenderer = {}
function PathRenderer:new(inPrio)
	local o = Renderer:new(inPrio)
	setmetatable(o, self)
	self.__index = self
	o.dirty = true
	o.path = nil
	o.trafo = nil;
	o.super = PathRenderer
	return o;
end

function PathRenderer:init(inContext, inConfig)
	print("PathRenderer INIT")
	Renderer.init(self, inContext, inConfig)
	self.trafo = juce.AffineTransform():translated(inConfig.dx, inConfig.dy)
end

function PathRenderer:updatePath(inComputedPath)
	self.path = inComputedPath
	self.dirty = true
end

function PathRenderer:render(inContext, inGraphics, inClipArea)
	--local bounds = self.path:getBoundsTransformed(self.trafo)
	local g = inGraphics
	g:saveState()
	g:setColour(ControlPointsDefinition.colour)
	g:addTransform(self.trafo)
	if self.path then
		g:strokePath(self.path)
	end
	g:restoreState()
	self.dirty = false
end

--
-- SampleImage Renderer Class which renders the sample data
--
local SampleRenderer = {}
function SampleRenderer:new(inPrio)
	local o = DirectFrameRenderer:new(inPrio)
	setmetatable(o, self)
	self.__index = self
	o.dirty = true
	return o;
end

function SampleRenderer:init(inContext, inConfig)
	--print("SampleImage INIT")
	DirectFrameRenderer.init(self, inContext, inConfig) --super call with explicit self!
	self.opacity = inConfig.opacity or 1;
	if self.opacity > 1 then self.opacity = 1 end
	if self.opacity < 0 then self.opacity = 0 end
end

function SampleRenderer:render(inContext, inGraphics, inClipArea)
	local img = dbufImage[dbufIndex]
	inGraphics:drawImageAt(img, self.x, self.y)
end

--
-- XYWH Renderer Class which renders objects which have x,y,w,h properties
--
local XYWHRenderer = {}
function XYWHRenderer:new(inPrio)
	local o = Renderer:new(inPrio)
	setmetatable(o, self)
	self.__index = self
	o.dirty = true
	o.list = {}
	return o
end

function XYWHRenderer:init(inContext, inConfig)
	--print("XYWHRenderer INIT")
	--self.super:init(inContext, inConfig) --super call with explicit self!
	self.opacity = inConfig.opacity or 1;
	if self.opacity > 1 then self.opacity = 1 end
	if self.opacity < 0 then self.opacity = 0 end
	self.filled = inConfig.filled or true;
	self.colour = inConfig.colour or ControlPointsDefinition.colour;
end

function XYWHRenderer:updateRectangleList(list)
	self.list = list
	self.dirty = true
end

function XYWHRenderer:render(inContext, inGraphics, inClipArea)
	--print("XYWHRenderer render; self.list=".. string.format("%s",self.list));
	local listOfPoints = MsegGuiModelData.listOfPoints --self.list
	local fct = inGraphics.drawRect
	inGraphics:saveState();
	if self.filled then
		inGraphics:setFillType(juce.FillType(self.colour))
		fct = inGraphics.fillRect
	end	
	for i = 1, #listOfPoints do
		--print("Draw Rect: "..listOfPoints[i].x..","..listOfPoints[i].y.." / "..listOfPoints[i].w..","..listOfPoints[i].h);
		fct(inGraphics, listOfPoints[i].x, listOfPoints[i].y, listOfPoints[i].w, listOfPoints[i].h)
	end
	inGraphics:restoreState();
end




--
-- build the list of renderer objects
local renderList = RendererList:new()
--
--
Grid1Renderer = GridRenderer:new(1)
Grid1Renderer:init({}, {x = editorFrame.x, y = editorFrame.y, w = editorFrame.w, h = editorFrame.h, lw = 5, opacity=0.5, ratio = _1over8})
--CompCachingRenderer:add(Grid1Renderer)
renderList:add(Grid1Renderer);
--
Grid2Renderer = GridRenderer:new(2)
Grid2Renderer:init({}, {x = editorFrame.x, y = editorFrame.y, w = editorFrame.w, h = editorFrame.h, lw = 2, opacity=1, ratio = _1over8, m = lengthModifiers.dotted})
--CompCachingRenderer:add(Grid2Renderer)
--renderList:add(Grid2Renderer);
--
PRenderer = PathRenderer:new(3);
PRenderer:init({}, {x = 0, y = 0, w = editorFrame.w, h = editorFrame.h, dx=0, dy=0})
--CompCachingRenderer:add(PRenderer)
renderList:add(PRenderer);
--
SampRenderer = SampleRenderer:new(0);
SampRenderer:init({}, {x = editorFrame.x, y = editorFrame.y, opacity=0.75})
renderList:add(SampRenderer);
--
CtrlPtsRenderer = XYWHRenderer:new(4);
CtrlPtsRenderer:init({}, {x = 0, y = 0, w = editorFrame.w, h = editorFrame.h, filled=false})
renderList:add(CtrlPtsRenderer);

function paintPoints(g)

	--
	-- all renderers
	--
	local ctx = {}
	renderList:render(ctx, g)


	local listOfPoints = MsegGuiModelData.listOfPoints
	local cachedSplineForLenEstimate = MsegGuiModelData.cachedSplineForLenEstimate
	--g:setColour   (controlPoints.colour);
	--g:setFillType(controlPoints.fill)

	--for i = 1, #listOfPoints do
	--	--print("Draw Rect: "..listOfPoints[i].x..","..listOfPoints[i].y.." / "..listOfPoints[i].w..","..listOfPoints[i].h);
	--	g:fillRect(listOfPoints[i].x, listOfPoints[i].y, listOfPoints[i].w, listOfPoints[i].h)
	--end
	--
	-- spline stuff
	--
	if cachedSplineForLenEstimate then
		--print("Draw spline: "..#cachedSplineForLenEstimate)
		--g:setColour (colourSplinePoints);
		g:setFillType(juce.FillType.white)
		local delta = 256
		while (#cachedSplineForLenEstimate / delta) < 200 and delta > 2 do
			delta = delta / 2
		end
		for i = 1, #cachedSplineForLenEstimate, delta do
			local p = cachedSplineForLenEstimate[i]
			g:fillRect(p.x - 2, p.y - 2, 4, 4)
		end
	end
	--
	-- processing curve
	--
	if ProcessData.processingShape then
		g:setColour(colourProcessingShapePoints)
		local curve = ProcessData.processingShape
		local num = #curve
		local deltaX = editorFrame.w / num
		local deltaI = 512
		while (num / deltaI) < 150 and deltaI > 2 do
			deltaI = deltaI / 2
		end
		local ex = editorFrame.x;
		local ey = editorFrame.y;
		local eh = editorFrame.h
		for i = 0, num - 1, deltaI do
			local x = ex + i * deltaX
			local y = ey + curve[i] * eh
			g:drawRect(x - 2, y - 2, 4, 4)
		end
	end
	
end

gui.addHandler("mouseDrag", mouseDragHandler)
gui.addHandler("mouseUp", mouseUpHandler)
gui.addHandler("mouseDoubleClick", mouseDoubleClickHandler)

function maximum(a)
	local mi = 1 -- maximum index
	local m = a[mi] -- maximum value
	for i, val in ipairs(a) do
		if val > m then
			mi = i
			m = val
		end
	end
	return m
end

function minimum(a)
	local mi = 1 -- maximum index
	local m = a[mi] -- maximum value
	for i, val in ipairs(a) do
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

local allSyncOptions = {_1over64, _1over32, _1over16, _1over8, _1over4, _1over2, _1over1}
local allSyncOptionsByName = {}
for i = 1, #allSyncOptions do
	allSyncOptionsByName[allSyncOptions[i].name] = allSyncOptions[i]
end

-- function to get all getAllSyncOptionNames of the table of all families
function getAllSyncOptionNames()
	local tbl = {}
	for i, s in ipairs(allSyncOptions) do
		--print(s["name"])
		tbl[#tbl + 1] = s["name"]
	end
	return tbl
end

-- based on the sync name of the parameter set the selected sync values
function updateSync(arg)
	local s = allSyncOptionsByName[arg]
	if s ~= selectedNoteLen.syncOption then
		newNoteLen = {
			syncOption = s,
			ratio = s["ratio"],
			modifier = selectedNoteLen.modifier,
			ratio_mult_modifier = s["ratio"] * selectedNoteLen.modifier
		}
		selectedNoteLen = newNoteLen
		ProcessData.onceAtLoopStartFunction = resetProcessingShape
	end
	return
end

params =
	plugin.manageParams {
	{
		name = "Sync",
		type = "list",
		values = getAllSyncOptionNames(),
		default = getAllSyncOptionNames()[1],
		changed = function(val)
			updateSync(val)
		end
	},
	{
		name = "Power",
		min = 0.0,
		max = 1.0,
		changed = function(val)
			ProcessData.power = val
			computeProcessingShapeByPower(ProcessData)
		end
	},
	{
		name = "Normalize",
		type = "list",
		values = {"false", "true"},
		default = "false",
		changed = function(val)
			ProcessData.normalizeTero = (val == "true")
		end
	}
}

--------------------------------------------------------------------------------------------------------------------
--
-- Load and Save Data
--
local header = "AmplitudeKungFu"

function script.loadData(data)
	-- check data begins with our header
	if string.sub(data, 1, string.len(header)) ~= header then
		return
	end
	print("Deserialized: allData=" .. data)
	local vers = string.match(data, '"fileVersion"%s*:%s*(%w*),')
	print("Deserialized: version=" .. vers)
	--
	local sync = string.match(data, '"sync"%s*:%s*(%d*%.?%d*),')
	print("Deserialized: sync=" .. sync)
	plugin.setParameter(0, sync)
	--
	local power = string.match(data, '"power"%s*:%s*(%d*%.?%d*),')
	print("Deserialized: power=" .. power)
	plugin.setParameter(1, power)
	--
	local points = string.match(data, '"points"%s*:%s*%[%s*(.-)%s*%]')
	print("Deserialized: points=" .. points)
	--
	local floatValues = {}
	for s in string.gmatch(points, '"[xy]"%s*=%s*(.-)[,%}]') do
		floatValues[#floatValues + 1] = s
	end
	local newListOfPoints = {}
	for i = 1, #floatValues, 2 do
		local p = createControlPointAtNormalizedCoord(floatValues[i], floatValues[i + 1])
		newListOfPoints[#newListOfPoints + 1] = p
	end
	table.sort(newListOfPoints, rectangleSorter)
	MsegGuiModelData.listOfPoints = newListOfPoints
	controlPointsHaveBeenChangedHandler()
end

function script.saveData()
	local listOfPoints = MsegGuiModelData.listOfPoints
	local picktable = {}
	for i = 1, #listOfPoints do
		picktable[i] = controlPointToNormalizedPoint(listOfPoints[i])
		--print("LOP: x="..listOfPoints[i].x+offset.."; y="..listOfPoints[i].y+offset);
		--print("POINT: "..string.format("%s",picktable[i]));
	end
	local serialized =
		header ..
		": { " ..
			'"fileVersion": V1' ..
				', "sync": ' ..
					plugin.getParameter(0) ..
						', "power": ' .. plugin.getParameter(1) .. ', "points": [' .. serializeListofPoints(picktable) .. "]" .. " }"
	print("Serialized: " .. serialized)
	return serialized
end

function serializeListofPoints(inListOfPoints)
	local s = ""
	local sep = ""
	for i = 1, #inListOfPoints do
		s = s .. sep .. string.format("%s", inListOfPoints[i])
		sep = ","
	end
	return s
end

--
--
-- simple point class with a  __tostring metamethod
-- https://wiki.cheatengine.org/index.php?title=Tutorials:Lua:ObjectOriented
--
--
Point = {x = 0, y = 0}
function Point:__tostring() 
	return '{"x"=' .. self.x .. ', "y"=' .. self.y .. '}'
end

function Point:newFromCoords(inX, inY)
	return Point:new{ x = inX or 0.0, y = inY or 0.0 }
end

function Point:new(inXYObj)
	--local o = { x = inX and inX or 0, y = inY and inY or 0 }
	local o = inXYObj or { x=0, y=0 }
	setmetatable(o, self)
	self.__index = self
	--print("Point: x="..o.x..", y="..o.y)
	return o;
end

--
-- simple rectangle class with a callback
--
Rectangle = {}
function Rectangle:new(inCenterX,inCenterY, inW, inH)
	local o = { centerX = inCenterX or 0, y = centerY or 0, w = inW or 10, h = inH or 10 }
	setmetatable(o, self)
	self.__index = self
	o.callback = noop;
	-- computed values
	o:moveCenterTo(o.centerX, o.centerY)
	return o;
end

function Rectangle:setCallback(inCallback)
	self.callback = inCallback or noop;
end

function Rectangle:moveCenterTo(inX, inY) 
	self.centerX=inX
	self.centerY=inY
	self.x  = self.centerX - 0.5 * w;
	self.y  = self.centerY - 0.5 * h;
end

function Rectangle:contains(inX, inY)
	return self.x < inX and self.x + self.w > inX and
		   self.y < inY and self.y + self.h > inY
end

---------------------------------------------------------------------------------------------------------------------
--
-- spline computation routine
-- https://forums.coregames.com/t/spline-generator-through-a-sequence-of-points/401
-- https://pastebin.com/2JZi2wvH
-- https://www.youtube.com/watch?v=9_aJGUTePYo
--

function PointOnPath(inPoints, t) -- catmull-rom cubic hermite interpolation
	if progress == 1 then
		return nodeList[#nodeList]
	end
	local p0 = m_floor(t)
	--print("P0"..p0..", t="..t);
	local p1 = p0 + 1
	local p2 = p1 + 1
	local p3 = p2 + 1

	t = t - p0;--math.floor(t)

	--optimize when t=0 or t=1 then immediately return
	if t==0 then
		local p = inPoints[p1];
		return {x = p.x, y = p.y, len = 0};
	elseif t==1 then
		local p = inPoints[p2];
		return {x = p.x, y = p.y, len = 0};
	end

	local tt = t * t
	local ttt = tt * t
	local _3ttt = 3 * ttt
	local _2tt = tt + tt
	local _4tt = _2tt + _2tt
	local _5tt = _4tt + tt

	local q0 = -ttt + _2tt - t
	local q1 = _3ttt - _5tt + 2.0
	local q2 = -_3ttt + _4tt + t
	local q3 = ttt - tt
	--print("Spline: "..p0..","..p1..","..p2..","..p3.."; "..#points.."; "..t);
	local tx = 0.5 * (inPoints[p0].x * q0 + inPoints[p1].x * q1 + inPoints[p2].x * q2 + inPoints[p3].x * q3)
	local ty = 0.5 * (inPoints[p0].y * q0 + inPoints[p1].y * q1 + inPoints[p2].y * q2 + inPoints[p3].y * q3)

	return {x = tx, y = ty, len = 0}
end

--
-- Second approach for centripetal catmull-rom
-- https://en.wikipedia.org/wiki/Centripetal_Catmull%E2%80%93Rom_spline
--
local function tj(inTi, inPi, inPj, inAlpha)
	local dx = (inPj.x - inPi.x);
	local dy = (inPj.y - inPi.y);
	-- actually it would be sqrt(...)^alpha ... we can make it streamlined by using sqrt = ^0.5 
	return  (dx*dx+dy*dy)^(inAlpha*0.5)
end

