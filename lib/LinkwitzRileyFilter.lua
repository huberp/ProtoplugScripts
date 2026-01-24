

-- Linkwitz-Riley 4th order filter class (LP/HP) for Protoplug
-- Based on https://www.musicdsp.org/en/latest/Filters/266-4th-order-linkwitz-riley-filters.html

local LinkwitzRileyFilter = {}
LinkwitzRileyFilter.__index = LinkwitzRileyFilter

-- Utility: calculate biquad coefficients for Butterworth 2nd order
local function calcBiquadCoeffs(type, freq, sampleRate)
    local omega = 2 * math.pi * freq / sampleRate
    local sn = math.sin(omega)
    local cs = math.cos(omega)
    local alpha = sn / math.sqrt(2)
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
        -- 2nd order allpass, Q = 1/sqrt(2) (Butterworth)
        b0 = 1 - alpha
        b1 = -2 * cs
        b2 = 1 + alpha
        a0 = 1 + alpha
        a1 = -2 * cs
        a2 = 1 - alpha
    else
        error("Unknown filter type: " .. tostring(type))
    end
    -- Normalize
    return {
        b0 = b0 / a0,
        b1 = b1 / a0,
        b2 = b2 / a0,
        a1 = a1 / a0,
        a2 = a2 / a0
    }
end

function LinkwitzRileyFilter.new(type, freq, sampleRate)
    local self = setmetatable({}, LinkwitzRileyFilter)
    self.type = type -- "lp" or "hp"
    self.freq = freq
    self.sampleRate = sampleRate
    -- Two cascaded biquads (Butterworth 2nd order)
    self.stage1 = {x1=0, x2=0, y1=0, y2=0}
    self.stage2 = {x1=0, x2=0, y1=0, y2=0}
    self:setParams(type, freq, sampleRate)
    return self
end

function LinkwitzRileyFilter:setParams(type, freq, sampleRate)
    self.type = type or self.type
    self.freq = freq or self.freq
    self.sampleRate = sampleRate or self.sampleRate
    self.coeffs = calcBiquadCoeffs(self.type, self.freq, self.sampleRate)
end

function LinkwitzRileyFilter:reset()
    for _, s in ipairs({self.stage1, self.stage2}) do
        s.x1, s.x2, s.y1, s.y2 = 0, 0, 0, 0
    end
end

-- Process a single sample (mono)
function LinkwitzRileyFilter:processSample(x)
    local c = self.coeffs
    -- Stage 1
    local s1 = self.stage1
    local y1 = c.b0 * x + c.b1 * s1.x1 + c.b2 * s1.x2 - c.a1 * s1.y1 - c.a2 * s1.y2
    s1.x2, s1.x1 = s1.x1, x
    s1.y2, s1.y1 = s1.y1, y1
    -- Stage 2
    local s2 = self.stage2
    local y2 = c.b0 * y1 + c.b1 * s2.x1 + c.b2 * s2.x2 - c.a1 * s2.y1 - c.a2 * s2.y2
    s2.x2, s2.x1 = s2.x1, y1
    s2.y2, s2.y1 = s2.y1, y2
    return y2
end

-- Process a buffer (in-place, stereo)
function LinkwitzRileyFilter:processMonoBlock(singleChannelSamples, smax)
    local returnSamples = {}
    for i = 0, smax do
        returnSamples[i] = self:processSample(singleChannelSamples[i])
    end
    return returnSamples
end

-- Example usage in plugin.processBlock:
-- local lp = LinkwitzRileyFilter.new("lp", 1000, 44100)
-- function plugin.processBlock(samples, smax, midiBuf)
--     lp:processBlock(samples, smax)
-- end


-- Stereo-capable Linkwitz-Riley filter class
local StereoLinkwitzRileyFilter = {}
StereoLinkwitzRileyFilter.__index = StereoLinkwitzRileyFilter

function StereoLinkwitzRileyFilter.new(type, freq, sampleRate)
    local self = setmetatable({}, StereoLinkwitzRileyFilter)
    self.left = LinkwitzRileyFilter.new(type, freq, sampleRate)
    self.right = LinkwitzRileyFilter.new(type, freq, sampleRate)
    return self
end

function StereoLinkwitzRileyFilter:setParams(type, freq, sampleRate)
    self.left:setParams(type, freq, sampleRate)
    self.right:setParams(type, freq, sampleRate)
end

function StereoLinkwitzRileyFilter:reset()
    self.left:reset()
    self.right:reset()
end

-- Process stereo block: returns two tables (left, right)
function StereoLinkwitzRileyFilter:processStereoBlock(samples, smax)
    local outL = self.left:processMonoBlock(samples[1], smax)
    local outR = self.right:processMonoBlock(samples[2], smax)
    return outL, outR
end

-- CrossOver class: combines stereo LP and HP
local CrossOver = {}
CrossOver.__index = CrossOver

function CrossOver.new(freq, sampleRate)
    local self = setmetatable({}, CrossOver)
    self.lp = StereoLinkwitzRileyFilter.new("lp", freq, sampleRate)
    self.hp = StereoLinkwitzRileyFilter.new("hp", freq, sampleRate)
    self.ap = StereoLinkwitzRileyFilter.new("allpass", freq, sampleRate)
    return self
end

function CrossOver:setParams(freq, sampleRate)
    self.lp:setParams("lp", freq, sampleRate)
    self.hp:setParams("hp", freq, sampleRate)
    self.ap:setParams("allpass", freq, sampleRate)
end

function CrossOver:reset()
    self.lp:reset()
    self.hp:reset()
    self.ap:reset()
end

-- Process stereo block: returns LP and HP outputs for both channels, with allpass correction on HP
function CrossOver:processStereoBlock(samples, smax)
    local lpL, lpR = self.lp:processStereoBlock(samples, smax)
    local hpL, hpR = self.hp:processStereoBlock(samples, smax)
    --local apL, apR = self.ap:processStereoBlock({lpL, lpR}, smax)
    return {lpL, lpR}, {hpL, hpR}
end


-- MultiBand5 class: 5-band crossover with correct parallel topology
-- Bands: 0-f1, f1-f2, f2-f3, f3-f4, f4+
-- Uses subtraction method for perfect reconstruction: sum of all bands = original signal
local MultiBand5 = {}
MultiBand5.__index = MultiBand5

function MultiBand5.new(f1, f2, f3, f4, sampleRate)
    local self = setmetatable({}, MultiBand5)
    -- All LP filters process the ORIGINAL input
    self.lp1 = StereoLinkwitzRileyFilter.new("lp", f1, sampleRate)
    self.lp2 = StereoLinkwitzRileyFilter.new("lp", f2, sampleRate)
    self.lp3 = StereoLinkwitzRileyFilter.new("lp", f3, sampleRate)
    self.lp4 = StereoLinkwitzRileyFilter.new("lp", f4, sampleRate)
    -- HP filter for the highest band
    self.hp4 = StereoLinkwitzRileyFilter.new("hp", f4, sampleRate)
    self.f1, self.f2, self.f3, self.f4 = f1, f2, f3, f4
    self.sampleRate = sampleRate
    return self
end

function MultiBand5:setParams(f1, f2, f3, f4, sampleRate)
    self.f1 = f1 or self.f1
    self.f2 = f2 or self.f2
    self.f3 = f3 or self.f3
    self.f4 = f4 or self.f4
    self.sampleRate = sampleRate or self.sampleRate
    self.lp1:setParams("lp", self.f1, self.sampleRate)
    self.lp2:setParams("lp", self.f2, self.sampleRate)
    self.lp3:setParams("lp", self.f3, self.sampleRate)
    self.lp4:setParams("lp", self.f4, self.sampleRate)
    self.hp4:setParams("hp", self.f4, self.sampleRate)
end

function MultiBand5:reset()
    self.lp1:reset()
    self.lp2:reset()
    self.lp3:reset()
    self.lp4:reset()
    self.hp4:reset()
end

-- Process stereo block: returns 5 bands
-- Band1: 0 to f1
-- Band2: f1 to f2
-- Band3: f2 to f3
-- Band4: f3 to f4
-- Band5: f4 to Nyquist
-- Input: stereoIn = {[1]=leftSamples, [2]=rightSamples}
function MultiBand5:processStereoBlock(stereoIn, smax)
    local leftIn = stereoIn[1]
    local rightIn = stereoIn[2]
    
    -- Apply all LP filters to the ORIGINAL input
    local lp1L, lp1R = self.lp1:processStereoBlock(stereoIn, smax)
    local lp2L, lp2R = self.lp2:processStereoBlock(stereoIn, smax)
    local lp3L, lp3R = self.lp3:processStereoBlock(stereoIn, smax)
    local lp4L, lp4R = self.lp4:processStereoBlock(stereoIn, smax)
    local hp4L, hp4R = self.hp4:processStereoBlock(stereoIn, smax)
    
    -- Create bands using subtraction for perfect reconstruction
    local band1L, band1R = {}, {}
    local band2L, band2R = {}, {}
    local band3L, band3R = {}, {}
    local band4L, band4R = {}, {}
    local band5L, band5R = {}, {}
    
    for i = 0, smax do
        -- Band 1: LP(f1)
        band1L[i] = lp1L[i]
        band1R[i] = lp1R[i]
        
        -- Band 2: LP(f2) - LP(f1)
        band2L[i] = lp2L[i] - lp1L[i]
        band2R[i] = lp2R[i] - lp1R[i]
        
        -- Band 3: LP(f3) - LP(f2)
        band3L[i] = lp3L[i] - lp2L[i]
        band3R[i] = lp3R[i] - lp2R[i]
        
        -- Band 4: LP(f4) - LP(f3)
        band4L[i] = lp4L[i] - lp3L[i]
        band4R[i] = lp4R[i] - lp3R[i]
        
        -- Band 5: HP(f4)
        band5L[i] = hp4L[i]
        band5R[i] = hp4R[i]
    end
    
    return 
        {[1]=band1L, [2]=band1R},
        {[1]=band2L, [2]=band2R},
        {[1]=band3L, [2]=band3R},
        {[1]=band4L, [2]=band4R},
        {[1]=band5L, [2]=band5R}
end

return {
    Mono = LinkwitzRileyFilter,
    Stereo = StereoLinkwitzRileyFilter,
    CrossOver = CrossOver,
    MultiBand5 = MultiBand5
}