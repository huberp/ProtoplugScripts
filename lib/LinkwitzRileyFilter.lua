

-- Linkwitz-Riley 4th order filter class (LP/HP) for Protoplug
-- Based on https://www.musicdsp.org/en/latest/Filters/266-4th-order-linkwitz-riley-filters.html

---@alias FilterType '"lp"'|'"hp"'|'"allpass"'

---@enum Slope
--- Slope enum: use Slope.DB24 or Slope.DB48
--- DB24 = 24 dB/octave (4th order, 2 cascaded biquads)
--- DB48 = 48 dB/octave (8th order, 4 cascaded biquads)
local Slope = {
    DB24 = 24,
    DB48 = 48
}

---Validate slope value
---@param slope Slope the slope value to validate
---@return Slope slope the validated slope value
local function validateSlope(slope)
    if slope ~= Slope.DB24 and slope ~= Slope.DB48 then
        error("Invalid slope: " .. tostring(slope) .. ". Use Slope.DB24 or Slope.DB48")
    end
    return slope
end

---@class BiquadState
---@field x1 number previous input sample
---@field x2 number input sample before x1
---@field y1 number previous output sample
---@field y2 number output sample before y1

---@class BiquadCoeffs
---@field b0 number feedforward coefficient 0
---@field b1 number feedforward coefficient 1
---@field b2 number feedforward coefficient 2
---@field a1 number feedback coefficient 1
---@field a2 number feedback coefficient 2

---@class LinkwitzRileyFilter
---@field type FilterType filter type
---@field slope Slope filter slope
---@field freq number cutoff frequency in Hz
---@field sampleRate number sample rate in Hz
---@field numStages integer number of cascaded biquad stages
---@field stages BiquadState[] array of biquad delay states
---@field coeffsList BiquadCoeffs[] array of biquad coefficients (one per stage)
local LinkwitzRileyFilter = {}
LinkwitzRileyFilter.__index = LinkwitzRileyFilter

---Calculate biquad coefficients for 2nd order filter with specified Q
---@param type FilterType filter type: "lp", "hp", or "allpass"
---@param freq number cutoff frequency in Hz
---@param sampleRate number sample rate in Hz
---@param Q number quality factor
---@return BiquadCoeffs coeffs table with normalized coefficients
local function calcBiquadCoeffsWithQ(type, freq, sampleRate, Q)
    local omega = 2 * math.pi * freq / sampleRate
    local sn = math.sin(omega)
    local cs = math.cos(omega)
    local alpha = sn / (2 * Q)
    local b0, b1, b2, a0, a1, a2
    if type == "lp" then
        b0 = (1 - cs) / 2
        b1 = 1 - cs
        b2 = (1 - cs) / 2
        a0 = 1 + alpha
        a1 = -2 * cs
        a2 = 1 - alpha
    elseif type == "hp" then
        b0 = (1 + cs) / 2
        b1 = -(1 + cs)
        b2 = (1 + cs) / 2
        a0 = 1 + alpha
        a1 = -2 * cs
        a2 = 1 - alpha
    elseif type == "allpass" then
        b0 = 1 - alpha
        b1 = -2 * cs
        b2 = 1 + alpha
        a0 = 1 + alpha
        a1 = -2 * cs
        a2 = 1 - alpha
    else
        error("Unknown filter type: " .. tostring(type))
    end
    return {
        b0 = b0 / a0,
        b1 = b1 / a0,
        b2 = b2 / a0,
        a1 = a1 / a0,
        a2 = a2 / a0
    }
end

-- Q values for Butterworth filters
-- LR4 (24dB/oct) = 2nd order Butterworth squared: Q = 1/sqrt(2) = 0.7071
-- LR8 (48dB/oct) = 4th order Butterworth squared: Q1 = 0.5412, Q2 = 1.3065
local Q_LR4 = 1 / math.sqrt(2)  -- 0.7071
local Q_LR8_1 = 1 / (2 * math.cos(math.pi / 8))   -- 0.5412 (for stages 1,2)
local Q_LR8_2 = 1 / (2 * math.cos(3 * math.pi / 8)) -- 1.3065 (for stages 3,4)

---Calculate biquad coefficients for Butterworth 2nd order filter (Q = 1/sqrt(2))
---@param type FilterType filter type: "lp", "hp", or "allpass"
---@param freq number cutoff frequency in Hz
---@param sampleRate number sample rate in Hz
---@return BiquadCoeffs coeffs table with normalized coefficients
local function calcBiquadCoeffs(type, freq, sampleRate)
    return calcBiquadCoeffsWithQ(type, freq, sampleRate, Q_LR4)
end

---Create a new mono Linkwitz-Riley filter
---@param type FilterType filter type: "lp", "hp", or "allpass"
---@param slope Slope? filter slope: Slope.DB24 or Slope.DB48 (default: Slope.DB24)
---@param freq number cutoff frequency in Hz
---@param sampleRate number sample rate in Hz
---@return LinkwitzRileyFilter filter new filter instance
function LinkwitzRileyFilter.new(type, slope, freq, sampleRate)
    local self = setmetatable({}, LinkwitzRileyFilter)
    self.type = type -- "lp", "hp", or "allpass"
    self.slope = validateSlope(slope or Slope.DB24)
    self.freq = freq
    self.sampleRate = sampleRate
    self.numStages = (self.slope == Slope.DB48) and 4 or 2
    self.stages = {}
    for i = 1, self.numStages do
        self.stages[i] = {x1=0, x2=0, y1=0, y2=0}
    end
    self:setParams(type, slope, freq, sampleRate)
    return self
end

---Update filter parameters
---@param type FilterType? filter type (nil to keep current)
---@param slope Slope? filter slope (nil to keep current)
---@param freq number? cutoff frequency in Hz (nil to keep current)
---@param sampleRate number? sample rate in Hz (nil to keep current)
function LinkwitzRileyFilter:setParams(type, slope, freq, sampleRate)
    self.type = type or self.type
    self.slope = slope and validateSlope(slope) or self.slope
    self.freq = freq or self.freq
    self.sampleRate = sampleRate or self.sampleRate
    self.numStages = (self.slope == Slope.DB48) and 4 or 2
    -- Recreate stages if slope changed
    if not self.stages or #self.stages ~= self.numStages then
        self.stages = {}
        for i = 1, self.numStages do
            self.stages[i] = {x1=0, x2=0, y1=0, y2=0}
        end
    end
    -- Calculate coefficients for each stage with appropriate Q
    self.coeffsList = {}
    if self.slope == Slope.DB24 then
        -- LR4: 2 stages, both with Q = 0.7071
        local c = calcBiquadCoeffsWithQ(self.type, self.freq, self.sampleRate, Q_LR4)
        self.coeffsList[1] = c
        self.coeffsList[2] = c
    else
        -- LR8: 4 stages - stages 1,2 with Q1, stages 3,4 with Q2
        local c1 = calcBiquadCoeffsWithQ(self.type, self.freq, self.sampleRate, Q_LR8_1)
        local c2 = calcBiquadCoeffsWithQ(self.type, self.freq, self.sampleRate, Q_LR8_2)
        self.coeffsList[1] = c1
        self.coeffsList[2] = c1
        self.coeffsList[3] = c2
        self.coeffsList[4] = c2
    end
end

---Reset all filter state (clear delay line history)
function LinkwitzRileyFilter:reset()
    for _, s in ipairs(self.stages) do
        s.x1, s.x2, s.y1, s.y2 = 0, 0, 0, 0
    end
end

---Process a single sample (mono)
---@param x number input sample value
---@return number y filtered output sample
function LinkwitzRileyFilter:processSample(x)
    local y = x
    for i = 1, self.numStages do
        local c = self.coeffsList[i]
        local s = self.stages[i]
        local y0 = c.b0 * y + c.b1 * s.x1 + c.b2 * s.x2 - c.a1 * s.y1 - c.a2 * s.y2
        s.x2 = s.x1
        s.x1 = y
        s.y2 = s.y1
        s.y1 = y0
        y = y0
    end
    return y
end

---@alias SampleBuffer table<integer, number> 0-indexed sample buffer

---Process a mono buffer of samples
---@param singleChannelSamples SampleBuffer table of input samples (0-indexed)
---@param smax integer maximum sample index
---@return SampleBuffer samples table of filtered output samples (0-indexed)
function LinkwitzRileyFilter:processMonoBlock(singleChannelSamples, smax)
    local returnSamples = {}
    for i = 0, smax do
        returnSamples[i] = self:processSample(singleChannelSamples[i])
    end
    return returnSamples
end

-- Example usage in plugin.processBlock:
-- local Slope = require("LinkwitzRileyFilter").Slope
-- local lp24 = LinkwitzRileyFilter.new("lp", Slope.DB24, 1000, 44100) -- 24dB/oct
-- local lp48 = LinkwitzRileyFilter.new("lp", Slope.DB48, 1000, 44100) -- 48dB/oct
-- function plugin.processBlock(samples, smax, midiBuf)
--     lp24:processBlock(samples, smax)
-- end


---@class StereoLinkwitzRileyFilter
---@field left LinkwitzRileyFilter left channel filter
---@field right LinkwitzRileyFilter right channel filter
--- Stereo-capable Linkwitz-Riley filter class
--- Wraps two mono filters for left and right channels
local StereoLinkwitzRileyFilter = {}
StereoLinkwitzRileyFilter.__index = StereoLinkwitzRileyFilter

---Create a new stereo Linkwitz-Riley filter
---@param type FilterType filter type: "lp", "hp", or "allpass"
---@param slope Slope filter slope: Slope.DB24 or Slope.DB48
---@param freq number cutoff frequency in Hz
---@param sampleRate number sample rate in Hz
---@return StereoLinkwitzRileyFilter filter new stereo filter instance
function StereoLinkwitzRileyFilter.new(type, slope, freq, sampleRate)
    local self = setmetatable({}, StereoLinkwitzRileyFilter)
    self.left = LinkwitzRileyFilter.new(type, slope, freq, sampleRate)
    self.right = LinkwitzRileyFilter.new(type, slope, freq, sampleRate)
    return self
end

---Update filter parameters for both channels
---@param type FilterType? filter type (nil to keep current)
---@param slope Slope? filter slope (nil to keep current)
---@param freq number? cutoff frequency in Hz (nil to keep current)
---@param sampleRate number? sample rate in Hz (nil to keep current)
function StereoLinkwitzRileyFilter:setParams(type, slope, freq, sampleRate)
    self.left:setParams(type, slope, freq, sampleRate)
    self.right:setParams(type, slope, freq, sampleRate)
end

---Reset filter state for both channels
function StereoLinkwitzRileyFilter:reset()
    self.left:reset()
    self.right:reset()
end

---@alias StereoBuffer {[1]: SampleBuffer, [2]: SampleBuffer} stereo sample buffer

---Process stereo block of samples
---@param samples StereoBuffer table with [1]=left channel, [2]=right channel
---@param smax integer maximum sample index
---@return SampleBuffer outL left channel output
---@return SampleBuffer outR right channel output
function StereoLinkwitzRileyFilter:processStereoBlock(samples, smax)
    local outL = self.left:processMonoBlock(samples[1], smax)
    local outR = self.right:processMonoBlock(samples[2], smax)
    return outL, outR
end

---@class CrossOver
---@field slope Slope filter slope
---@field lp StereoLinkwitzRileyFilter low-pass filter
---@field hp StereoLinkwitzRileyFilter high-pass filter
---@field ap StereoLinkwitzRileyFilter allpass filter (for phase correction)
--- CrossOver class: 2-band stereo crossover filter
--- Splits signal into low-pass and high-pass bands at the crossover frequency
local CrossOver = {}
CrossOver.__index = CrossOver

---Create a new 2-band crossover
---@param slope Slope? filter slope: Slope.DB24 or Slope.DB48
---@param freq number crossover frequency in Hz
---@param sampleRate number sample rate in Hz
---@return CrossOver crossover new crossover instance
function CrossOver.new(slope, freq, sampleRate)
    local self = setmetatable({}, CrossOver)
    self.slope = slope or 24
    self.lp = StereoLinkwitzRileyFilter.new("lp", self.slope, freq, sampleRate)
    self.hp = StereoLinkwitzRileyFilter.new("hp", self.slope, freq, sampleRate)
    self.ap = StereoLinkwitzRileyFilter.new("allpass", self.slope, freq, sampleRate)
    return self
end

---Update crossover parameters
---@param slope Slope? filter slope (nil to keep current)
---@param freq number? crossover frequency in Hz (nil to keep current)
---@param sampleRate number? sample rate in Hz (nil to keep current)
function CrossOver:setParams(slope, freq, sampleRate)
    self.slope = slope or self.slope
    self.lp:setParams("lp", self.slope, freq, sampleRate)
    self.hp:setParams("hp", self.slope, freq, sampleRate)
    self.ap:setParams("allpass", self.slope, freq, sampleRate)
end

---Reset all filter states
function CrossOver:reset()
    self.lp:reset()
    self.hp:reset()
    self.ap:reset()
end

---Process stereo block and split into LP and HP bands
---@param samples StereoBuffer table with [1]=left channel, [2]=right channel
---@param smax integer maximum sample index
---@return StereoBuffer lpBand low-pass band {lpL, lpR}
---@return StereoBuffer hpBand high-pass band {hpL, hpR}
function CrossOver:processStereoBlock(samples, smax)
    local lpL, lpR = self.lp:processStereoBlock(samples, smax)
    local hpL, hpR = self.hp:processStereoBlock(samples, smax)
    --local apL, apR = self.ap:processStereoBlock({lpL, lpR}, smax)
    return {lpL, lpR}, {hpL, hpR}
end


---@class MultiBand5
---@field slope Slope filter slope
---@field lp1 StereoLinkwitzRileyFilter LP at f1 for band 1
---@field hp1 StereoLinkwitzRileyFilter HP at f1 for band 2
---@field lp2 StereoLinkwitzRileyFilter LP at f2 for band 2
---@field hp2 StereoLinkwitzRileyFilter HP at f2 for band 3
---@field lp3 StereoLinkwitzRileyFilter LP at f3 for band 3
---@field hp3 StereoLinkwitzRileyFilter HP at f3 for band 4
---@field lp4 StereoLinkwitzRileyFilter LP at f4 for band 4
---@field hp4 StereoLinkwitzRileyFilter HP at f4 for band 5
---@field f1 number first crossover frequency
---@field f2 number second crossover frequency
---@field f3 number third crossover frequency
---@field f4 number fourth crossover frequency
---@field sampleRate number sample rate in Hz
--- MultiBand5 class: 5-band stereo crossover with PARALLEL topology
--- Each band has dedicated HP+LP filters processing the ORIGINAL signal
--- Band 1: LP(f1)
--- Band 2: HP(f1) -> LP(f2)  (cascaded on same signal)
--- Band 3: HP(f2) -> LP(f3)
--- Band 4: HP(f3) -> LP(f4)
--- Band 5: HP(f4)
local MultiBand5 = {}
MultiBand5.__index = MultiBand5

---Create a new 5-band crossover
---@param slope Slope? filter slope: Slope.DB24 or Slope.DB48
---@param f1 number first crossover frequency in Hz
---@param f2 number second crossover frequency in Hz
---@param f3 number third crossover frequency in Hz
---@param f4 number fourth crossover frequency in Hz
---@param sampleRate number sample rate in Hz
---@return MultiBand5 multiband new 5-band crossover instance
function MultiBand5.new(slope, f1, f2, f3, f4, sampleRate)
    local self = setmetatable({}, MultiBand5)
    self.slope = slope or 24
    -- Band 1: just LP at f1
    self.lp1 = StereoLinkwitzRileyFilter.new("lp", self.slope, f1, sampleRate)
    -- Band 2: HP at f1, then LP at f2
    self.hp1 = StereoLinkwitzRileyFilter.new("hp", self.slope, f1, sampleRate)
    self.lp2 = StereoLinkwitzRileyFilter.new("lp", self.slope, f2, sampleRate)
    -- Band 3: HP at f2, then LP at f3
    self.hp2 = StereoLinkwitzRileyFilter.new("hp", self.slope, f2, sampleRate)
    self.lp3 = StereoLinkwitzRileyFilter.new("lp", self.slope, f3, sampleRate)
    -- Band 4: HP at f3, then LP at f4
    self.hp3 = StereoLinkwitzRileyFilter.new("hp", self.slope, f3, sampleRate)
    self.lp4 = StereoLinkwitzRileyFilter.new("lp", self.slope, f4, sampleRate)
    -- Band 5: just HP at f4
    self.hp4 = StereoLinkwitzRileyFilter.new("hp", self.slope, f4, sampleRate)
    self.f1, self.f2, self.f3, self.f4 = f1, f2, f3, f4
    self.sampleRate = sampleRate
    return self
end

---Update crossover parameters
---@param slope Slope? filter slope (nil to keep current)
---@param f1 number? first crossover frequency in Hz (nil to keep current)
---@param f2 number? second crossover frequency in Hz (nil to keep current)
---@param f3 number? third crossover frequency in Hz (nil to keep current)
---@param f4 number? fourth crossover frequency in Hz (nil to keep current)
---@param sampleRate number? sample rate in Hz (nil to keep current)
function MultiBand5:setParams(slope, f1, f2, f3, f4, sampleRate)
    self.slope = slope or self.slope
    self.f1 = f1 or self.f1
    self.f2 = f2 or self.f2
    self.f3 = f3 or self.f3
    self.f4 = f4 or self.f4
    self.sampleRate = sampleRate or self.sampleRate
    self.lp1:setParams("lp", self.slope, self.f1, self.sampleRate)
    self.hp1:setParams("hp", self.slope, self.f1, self.sampleRate)
    self.lp2:setParams("lp", self.slope, self.f2, self.sampleRate)
    self.hp2:setParams("hp", self.slope, self.f2, self.sampleRate)
    self.lp3:setParams("lp", self.slope, self.f3, self.sampleRate)
    self.hp3:setParams("hp", self.slope, self.f3, self.sampleRate)
    self.lp4:setParams("lp", self.slope, self.f4, self.sampleRate)
    self.hp4:setParams("hp", self.slope, self.f4, self.sampleRate)
end

---Reset all filter states
function MultiBand5:reset()
    self.lp1:reset()
    self.hp1:reset()
    self.lp2:reset()
    self.hp2:reset()
    self.lp3:reset()
    self.hp3:reset()
    self.lp4:reset()
    self.hp4:reset()
end

---Process stereo block and split into 5 frequency bands
---Uses SERIAL CASCADING: Input → XO1 → LP=Band1, HP → XO2 → LP=Band2, HP → ...
---This guarantees LP+HP=Input at each stage for perfect reconstruction
---@param stereoIn StereoBuffer table with [1]=left channel, [2]=right channel
---@param smax integer maximum sample index
---@return StereoBuffer band1 band 0-f1
---@return StereoBuffer band2 band f1-f2
---@return StereoBuffer band3 band f2-f3
---@return StereoBuffer band4 band f3-f4
---@return StereoBuffer band5 band f4-Nyquist
function MultiBand5:processStereoBlock(stereoIn, smax)
    -- Stage 1: Split at f1
    local lp1L, lp1R = self.lp1:processStereoBlock(stereoIn, smax)
    local hp1L, hp1R = self.hp1:processStereoBlock(stereoIn, smax)
    -- Band 1 = LP(f1)
    
    -- Stage 2: Split HP1 at f2
    local hp1_buf = {[1]=hp1L, [2]=hp1R}
    local lp2L, lp2R = self.lp2:processStereoBlock(hp1_buf, smax)
    local hp2L, hp2R = self.hp2:processStereoBlock(hp1_buf, smax)
    -- Band 2 = LP(f2) of HP(f1)
    
    -- Stage 3: Split HP2 at f3
    local hp2_buf = {[1]=hp2L, [2]=hp2R}
    local lp3L, lp3R = self.lp3:processStereoBlock(hp2_buf, smax)
    local hp3L, hp3R = self.hp3:processStereoBlock(hp2_buf, smax)
    -- Band 3 = LP(f3) of HP(f2) of HP(f1)
    
    -- Stage 4: Split HP3 at f4
    local hp3_buf = {[1]=hp3L, [2]=hp3R}
    local lp4L, lp4R = self.lp4:processStereoBlock(hp3_buf, smax)
    local hp4L, hp4R = self.hp4:processStereoBlock(hp3_buf, smax)
    -- Band 4 = LP(f4) of HP(f3) of HP(f2) of HP(f1)
    -- Band 5 = HP(f4) of HP(f3) of HP(f2) of HP(f1)
    
    return 
        {[1]=lp1L, [2]=lp1R},
        {[1]=lp2L, [2]=lp2R},
        {[1]=lp3L, [2]=lp3R},
        {[1]=lp4L, [2]=lp4R},
        {[1]=hp4L, [2]=hp4R}
end


---@class MultiBandN
---@field slope Slope filter slope
---@field numBands integer number of frequency bands
---@field freqs number[] array of crossover frequencies
---@field sampleRate number sample rate in Hz
---@field lpFiltersL LinkwitzRileyFilter[] LP filters for left channel
---@field lpFiltersR LinkwitzRileyFilter[] LP filters for right channel
---@field hpFiltersL LinkwitzRileyFilter[] HP filters for left channel
---@field hpFiltersR LinkwitzRileyFilter[] HP filters for right channel
--- MultiBandN class: configurable N-band stereo crossover (2 to 7 bands)
--- Uses SERIAL CASCADING: at each crossover, LP+HP process SAME signal
--- This guarantees FLAT SUM because LP(f)+HP(f) = allpass at each stage
--- Band 1 = LP(f1)
--- Band 2 = LP(f2) of HP(f1) output
--- Band N = HP(fN-1) output
local MultiBandN = {}
MultiBandN.__index = MultiBandN

---Create a new N-band crossover
---@param slope Slope? filter slope: Slope.DB24 or Slope.DB48
---@param freqs number[] table of crossover frequencies {f1, f2, ...} (N-1 frequencies for N bands)
---@param sampleRate number sample rate in Hz
---@return MultiBandN multiband new N-band crossover instance
---Example: 3 bands needs 2 frequencies: {300, 3000} -> bands: 0-300, 300-3000, 3000+
function MultiBandN.new(slope, freqs, sampleRate)
    local numFreqs = #freqs
    if numFreqs < 1 or numFreqs > 6 then
        error("MultiBandN requires 1-6 crossover frequencies (2-7 bands)")
    end
    
    local self = setmetatable({}, MultiBandN)
    self.slope = slope or 24
    self.numBands = numFreqs + 1
    self.freqs = {}
    self.sampleRate = sampleRate
    self.lpFiltersL = {}
    self.lpFiltersR = {}
    self.hpFiltersL = {}
    self.hpFiltersR = {}
    
    -- Create LP and HP filter pairs for each crossover frequency
    for i = 1, numFreqs do
        self.freqs[i] = freqs[i]
        self.lpFiltersL[i] = LinkwitzRileyFilter.new("lp", self.slope, freqs[i], sampleRate)
        self.lpFiltersR[i] = LinkwitzRileyFilter.new("lp", self.slope, freqs[i], sampleRate)
        self.hpFiltersL[i] = LinkwitzRileyFilter.new("hp", self.slope, freqs[i], sampleRate)
        self.hpFiltersR[i] = LinkwitzRileyFilter.new("hp", self.slope, freqs[i], sampleRate)
    end
    
    return self
end

---Update crossover parameters
---@param slope Slope? filter slope (nil to keep current)
---@param freqs number[] table of crossover frequencies (must match original band count)
---@param sampleRate number? sample rate in Hz (nil to keep current)
function MultiBandN:setParams(slope, freqs, sampleRate)
    local numFreqs = #freqs
    if numFreqs ~= self.numBands - 1 then
        error("Number of frequencies must match original band count")
    end
    
    self.slope = slope or self.slope
    self.sampleRate = sampleRate or self.sampleRate
    
    for i = 1, numFreqs do
        self.freqs[i] = freqs[i]
        self.lpFiltersL[i]:setParams("lp", self.slope, freqs[i], self.sampleRate)
        self.lpFiltersR[i]:setParams("lp", self.slope, freqs[i], self.sampleRate)
        self.hpFiltersL[i]:setParams("hp", self.slope, freqs[i], self.sampleRate)
        self.hpFiltersR[i]:setParams("hp", self.slope, freqs[i], self.sampleRate)
    end
end

---Reset all filter states
function MultiBandN:reset()
    for i = 1, #self.lpFiltersL do
        self.lpFiltersL[i]:reset()
        self.lpFiltersR[i]:reset()
        self.hpFiltersL[i]:reset()
        self.hpFiltersR[i]:reset()
    end
end

---Get the number of frequency bands
---@return integer numBands number of bands
function MultiBandN:getNumBands()
    return self.numBands
end

---Get the crossover frequencies
---@return number[] freqs table of crossover frequencies
function MultiBandN:getFrequencies()
    return self.freqs
end

---Process stereo block and split into N frequency bands
---Uses SERIAL CASCADING: LP and HP both process the SAME signal at each stage
---LP output = this band, HP output = input to next stage
---This guarantees FLAT SUM: LP(f) + HP(f) = allpass (unity magnitude)
---@param stereoIn StereoBuffer table with [1]=left channel, [2]=right channel
---@param smax integer maximum sample index
---@return StereoBuffer[] bands table of bands, each band is {[1]=leftSamples, [2]=rightSamples}
function MultiBandN:processStereoBlock(stereoIn, smax)
    local numFreqs = #self.freqs
    local numBands = self.numBands
    
    -- Initialize output band buffers
    local bands = {}
    for b = 1, numBands do
        bands[b] = {[1] = {}, [2] = {}}
    end
    
    -- Process sample-by-sample with serial cascading
    -- At each stage, BOTH LP and HP process the SAME input
    -- LP output = band, HP output = input to next stage
    for i = 0, smax do
        local inputL = stereoIn[1][i]
        local inputR = stereoIn[2][i]
        
        for f = 1, numFreqs do
            -- Both LP and HP process the SAME input signal
            local lpL = self.lpFiltersL[f]:processSample(inputL)
            local lpR = self.lpFiltersR[f]:processSample(inputR)
            local hpL = self.hpFiltersL[f]:processSample(inputL)
            local hpR = self.hpFiltersR[f]:processSample(inputR)
            
            -- LP output = this band
            bands[f][1][i] = lpL
            bands[f][2][i] = lpR
            
            -- HP output becomes input to next stage
            inputL = hpL
            inputR = hpR
        end
        
        -- Last band = final HP output
        bands[numBands][1][i] = inputL
        bands[numBands][2][i] = inputR
    end
    
    return bands
end

---Sum all bands with optional per-band gains
---@param bands StereoBuffer[] table of bands from processStereoBlock
---@param smax integer maximum sample index
---@param gains number[]? optional table of gain values per band, defaults to 1.0 for each band
---@return SampleBuffer sumL summed left channel output
---@return SampleBuffer sumR summed right channel output
function MultiBandN:sumBands(bands, smax, gains)
    local sumL, sumR = {}, {}
    local numBands = #bands
    
    -- Default gains to 1.0 if not provided
    gains = gains or {}
    for b = 1, numBands do
        gains[b] = gains[b] or 1.0
    end
    
    for i = 0, smax do
        sumL[i] = 0
        sumR[i] = 0
        for b = 1, numBands do
            sumL[i] = sumL[i] + gains[b] * bands[b][1][i]
            sumR[i] = sumR[i] + gains[b] * bands[b][2][i]
        end
    end
    return sumL, sumR
end

return {
    Slope = Slope,
    Mono = LinkwitzRileyFilter,
    Stereo = StereoLinkwitzRileyFilter,
    CrossOver = CrossOver,
    MultiBand5 = MultiBand5,
    MultiBandN = MultiBandN
}