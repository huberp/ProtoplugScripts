--[[
name: Apply Note Hight on a pattern
description: apply note hight coming in in channel 1 to a mono-note pattern on channel 2
author: https://github.com/huberp
--]]

require "include/protoplug"


-- https://www.gammon.com.au/scripts/doc.php?lua=package.loadlib
package.cpath = package.cpath..";"..protoplug_dir.."/lib/?.dll"
package.path  = package.path.. ";"..protoplug_dir.."/include/?.lua"
package.path  = package.path.. ";"..protoplug_dir.."/ProtoplugScripts/lib/?.lua"
--
local Logger = require("Logger")
local util = require("util")
local LRFilters = require("LinkwitzRileyFilter")
local MBandOptimized = require("MultiBandOptimized_5_48")
local LOG = Logger:new(Logger.LEVELS.DEBUG)
--======================================================================================================================
--
-- Import SyncGlobals module
--
local SyncGlobals = require("SyncGlobals")
local GLOBALS = SyncGlobals.GLOBALS
local EVT_VAL_CTX = SyncGlobals.EVT_VAL_CTX
local CTX_VAL_MIDI_BUFFER = SyncGlobals.CTX_VAL_MIDI_BUFFER
local CTX_VAL_DAW_POSITION = SyncGlobals.CTX_VAL_DAW_POSITION
local CTX_VAL_NUM_SAMPLES_IN_FRAME = SyncGlobals.CTX_VAL_NUM_SAMPLES_IN_FRAME
local CTX_VAL_SAMPLES_OF_FRAME = SyncGlobals.CTX_VAL_SAMPLES_OF_FRAME
local CTX_VAL_EPOCH = SyncGlobals.CTX_VAL_EPOCH
local unpackCtx = SyncGlobals.unpackCtx
local packCtx = SyncGlobals.packCtx
local eventFromEvent = SyncGlobals.eventFromEvent

print("GLOBALS: ".. #GLOBALS.eventListeners)

plugin.addHandler("prepareToPlay", function() GLOBALS:updateSampleRate(plugin.getSampleRate()) end)


local crossoverTOP = nil
local crossoverA = nil
local crossoverB = nil
local multiBand = nil
local multiBandOptimized = nil
local function initCrossover()
	crossoverTOP = LRFilters.CrossOver.new(LRFilters.Slope.DB48, 1000.0, plugin.getSampleRate())
	crossoverA   = LRFilters.CrossOver.new(LRFilters.Slope.DB48, 300.0,  plugin.getSampleRate())
	crossoverB   = LRFilters.CrossOver.new(LRFilters.Slope.DB48, 4000.0, plugin.getSampleRate())
	multiBand    = LRFilters.MultiBandN.new(LRFilters.Slope.DB48,{300.0, 1000.0, 4000.0, 8000.0}, plugin.getSampleRate())
	multiBandOptimized = MBandOptimized.new(300.0, 1000.0, 4000.0, 8000.0, plugin.getSampleRate())
end

plugin.addHandler("prepareToPlay", initCrossover)

local GAINS = {1.0, 1.0, 1.0, 1.0, 1.0}
local function setBandGain(bandIndex, gainValue)
	if GAINS ~= nil then
		GAINS[bandIndex] = gainValue
	end
end

function plugin.processBlock(samples, smax, midiBuf)
	--#region
	--
	local bands = multiBandOptimized:processStereoBlock({[1]=samples[0], [2]=samples[1]}, smax)
	local sumL, sumR = multiBandOptimized:sumBands(bands, smax, GAINS)
	for i = 0, smax do
		samples[0][i] = sumL[i]
		samples[1][i] = sumR[i]
	end
	--
	--
    --[[ local stereoIn = {[1]=samples[0], [2]=samples[1]}
    
    -- Get LP and HP outputs for stereo
    local lp, hp = crossoverTOP:processStereoBlock(stereoIn, smax)
    local lpA, hpA = crossoverA:processStereoBlock(lp, smax)
    local lpB, hpB = crossoverB:processStereoBlock(hp, smax)
    
    -- Sum all 4 bands (should reconstruct original signal)
    for i = 0, smax do
        samples[0][i] = lpA[1][i] + hpA[1][i] + lpB[1][i] + hpB[1][i]
        samples[1][i] = lpA[2][i] + hpA[2][i] + lpB[2][i] + hpB[2][i]
    end ]]
	--
	--
	--[[ -- Get LP and HP outputs for stereo
	local lp, hp = crossoverTOP:processStereoBlock({samples[0], samples[1]}, smax)
	local lpA, hpA = crossoverA:processStereoBlock(lp, smax)
	local lpB, hpB = crossoverB:processStereoBlock(hp, smax)
	--# lpA, hpA
	local lpA_L, lpA_R = lpA[1], lpA[2]
	local hpA_L, hpA_R = hpA[1], hpA[2]
	--# lpB, hpB
	local lpB_L, lpB_R = lpB[1], lpB[2]
	local hpB_L, hpB_R = hpB[1], hpB[2]
	--
	local lpL, lpR = lp[1], lp[2]
	local hpL, hpR = hp[1], hp[2]
	-- Example: sum LP+HP (should reconstruct original signal)
	for i = 0, smax do
		samples[0][i] = lpA_L[i] + hpA_L[i] + lpB_L[i] + hpB_L[i] --lpL[i] + hpL[i]
		samples[1][i] = lpA_R[i] + hpA_R[i] + lpB_R[i] + hpB_R[i] --lpR[i] + hpR[i]
	end ]]
	--
	--#region All-pass filter example
	--[[ local apL, apR = allPass:processStereoBlock({samples[0], samples[1]}, smax)
	for i = 0, smax do
		samples[0][i] = apL[i]
		samples[1][i] = apR[i]
	end  ]]
end

params =
	plugin.manageParams {
	{
		name = "Band 1 Gain",
		min = 0.0,
		max = 1.0,
		changed = function(val)
			setBandGain(1, val)
		end
	},
	{
		name = "Band 2 Gain",
		min = 0.0,
		max = 1.0,
		changed = function(val)
			setBandGain(2, val)
		end
	},
	{
		name = "Band 3 Gain",
		min = 0.0,
		max = 1.0,
		changed = function(val)
			setBandGain(3, val)
		end
	},
	{
		name = "Band 4 Gain",
		min = 0.0,
		max = 1.0,
		changed = function(val)
			setBandGain(4, val)
		end
	},
	{
		name = "Band 5 Gain",
		min = 0.0,
		max = 1.0,
		changed = function(val)
			setBandGain(5, val)
		end
	},
}
