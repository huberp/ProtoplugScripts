-- Optimized 5-band 48dB/octave Linkwitz-Riley crossover
-- All filter operations collapsed into a single function for maximum performance
-- Eliminates method call overhead and table lookups in the hot path

local math_pi = math.pi
local math_sin = math.sin
local math_cos = math.cos

-- Q values for LR8 (48dB/oct = 4th order Butterworth squared)
local Q_LR8_1 = 1 / (2 * math_cos(math_pi / 8))      -- 0.5412
local Q_LR8_2 = 1 / (2 * math_cos(3 * math_pi / 8))  -- 1.3065

---@class MultiBandOptimized_5_48
---@field freqs number[] crossover frequencies {f1, f2, f3, f4}
---@field sampleRate number sample rate in Hz
---@field coeffs table all biquad coefficients (flattened)
---@field stateL table all biquad states for left channel
---@field stateR table all biquad states for right channel
local MultiBandOptimized_5_48 = {}
MultiBandOptimized_5_48.__index = MultiBandOptimized_5_48

---Calculate biquad coefficients
---@param filterType string "lp", "hp", or "allpass"
---@param freq number cutoff frequency
---@param sampleRate number sample rate
---@param Q number quality factor
---@return number, number, number, number, number b0, b1, b2, a1, a2
local function calcCoeffs(filterType, freq, sampleRate, Q)
    local omega = 2 * math_pi * freq / sampleRate
    local sn = math_sin(omega)
    local cs = math_cos(omega)
    local alpha = sn / (2 * Q)
    local b0, b1, b2, a0, a1, a2
    
    if filterType == "lp" then
        b0 = (1 - cs) / 2
        b1 = 1 - cs
        b2 = (1 - cs) / 2
    elseif filterType == "hp" then
        b0 = (1 + cs) / 2
        b1 = -(1 + cs)
        b2 = (1 + cs) / 2
    else -- allpass
        b0 = 1 - alpha
        b1 = -2 * cs
        b2 = 1 + alpha
    end
    a0 = 1 + alpha
    a1 = -2 * cs
    a2 = 1 - alpha
    
    return b0/a0, b1/a0, b2/a0, a1/a0, a2/a0
end

---Create a new optimized 5-band 48dB/oct crossover
---@param f1 number first crossover frequency
---@param f2 number second crossover frequency
---@param f3 number third crossover frequency
---@param f4 number fourth crossover frequency
---@param sampleRate number sample rate in Hz
---@return MultiBandOptimized_5_48
function MultiBandOptimized_5_48.new(f1, f2, f3, f4, sampleRate)
    local self = setmetatable({}, MultiBandOptimized_5_48)
    self.freqs = {f1, f2, f3, f4}
    self.sampleRate = sampleRate
    
    -- Pre-allocate all state variables (44 biquads × 4 state vars = 176 per channel)
    -- Using flat arrays for cache-friendly access
    self.stateL = {}
    self.stateR = {}
    for i = 1, 176 do
        self.stateL[i] = 0
        self.stateR[i] = 0
    end
    
    -- Pre-allocate output buffers
    self._bandsBuffer = {}
    for b = 1, 5 do
        self._bandsBuffer[b] = {[1] = {}, [2] = {}}
    end
    self._sumL = {}
    self._sumR = {}
    
    -- Calculate all coefficients
    self:_calcAllCoeffs()
    
    return self
end

---Calculate all filter coefficients
function MultiBandOptimized_5_48:_calcAllCoeffs()
    local freqs = self.freqs
    local sr = self.sampleRate
    
    -- Store coefficients in flat arrays for fastest access
    -- Each biquad needs 5 coeffs: b0, b1, b2, a1, a2
    -- Index: (biquadIndex-1)*5 + coeffIndex
    
    self.coeffs = {}
    local c = self.coeffs
    local idx = 1
    
    -- Helper to store 4 biquads for LP or HP at a frequency (LR8 = 4 stages)
    local function store4Biquads(ftype, freq)
        local b0, b1, b2, a1, a2
        -- Stages 1,2 use Q1
        b0, b1, b2, a1, a2 = calcCoeffs(ftype, freq, sr, Q_LR8_1)
        c[idx], c[idx+1], c[idx+2], c[idx+3], c[idx+4] = b0, b1, b2, a1, a2
        idx = idx + 5
        c[idx], c[idx+1], c[idx+2], c[idx+3], c[idx+4] = b0, b1, b2, a1, a2
        idx = idx + 5
        -- Stages 3,4 use Q2
        b0, b1, b2, a1, a2 = calcCoeffs(ftype, freq, sr, Q_LR8_2)
        c[idx], c[idx+1], c[idx+2], c[idx+3], c[idx+4] = b0, b1, b2, a1, a2
        idx = idx + 5
        c[idx], c[idx+1], c[idx+2], c[idx+3], c[idx+4] = b0, b1, b2, a1, a2
        idx = idx + 5
    end
    
    -- Helper to store 2 biquads for allpass at a frequency (LR8 allpass = 2 stages)
    local function store2Allpass(freq)
        local b0, b1, b2, a1, a2
        b0, b1, b2, a1, a2 = calcCoeffs("allpass", freq, sr, Q_LR8_1)
        c[idx], c[idx+1], c[idx+2], c[idx+3], c[idx+4] = b0, b1, b2, a1, a2
        idx = idx + 5
        b0, b1, b2, a1, a2 = calcCoeffs("allpass", freq, sr, Q_LR8_2)
        c[idx], c[idx+1], c[idx+2], c[idx+3], c[idx+4] = b0, b1, b2, a1, a2
        idx = idx + 5
    end
    
    -- Layout (44 biquads total):
    -- LP1: 4 biquads (idx 1-20)
    -- HP1: 4 biquads (idx 21-40)
    -- LP2: 4 biquads (idx 41-60)
    -- HP2: 4 biquads (idx 61-80)
    -- LP3: 4 biquads (idx 81-100)
    -- HP3: 4 biquads (idx 101-120)
    -- LP4: 4 biquads (idx 121-140)
    -- HP4: 4 biquads (idx 141-160)
    -- AP2 (for band1): 2 biquads (idx 161-170)
    -- AP3 (for band1): 2 biquads (idx 171-180)
    -- AP4 (for band1): 2 biquads (idx 181-190)
    -- AP3 (for band2): 2 biquads (idx 191-200)
    -- AP4 (for band2): 2 biquads (idx 201-210)
    -- AP4 (for band3): 2 biquads (idx 211-220)
    
    store4Biquads("lp", freqs[1])   -- LP1
    store4Biquads("hp", freqs[1])   -- HP1
    store4Biquads("lp", freqs[2])   -- LP2
    store4Biquads("hp", freqs[2])   -- HP2
    store4Biquads("lp", freqs[3])   -- LP3
    store4Biquads("hp", freqs[3])   -- HP3
    store4Biquads("lp", freqs[4])   -- LP4
    store4Biquads("hp", freqs[4])   -- HP4
    
    store2Allpass(freqs[2])  -- AP2 for band1
    store2Allpass(freqs[3])  -- AP3 for band1
    store2Allpass(freqs[4])  -- AP4 for band1
    store2Allpass(freqs[3])  -- AP3 for band2
    store2Allpass(freqs[4])  -- AP4 for band2
    store2Allpass(freqs[4])  -- AP4 for band3
end

---Update crossover frequencies
---@param f1 number? first crossover frequency (nil to keep current)
---@param f2 number? second crossover frequency (nil to keep current)
---@param f3 number? third crossover frequency (nil to keep current)
---@param f4 number? fourth crossover frequency (nil to keep current)
---@param sampleRate number? sample rate (nil to keep current)
function MultiBandOptimized_5_48:setParams(f1, f2, f3, f4, sampleRate)
    self.freqs[1] = f1 or self.freqs[1]
    self.freqs[2] = f2 or self.freqs[2]
    self.freqs[3] = f3 or self.freqs[3]
    self.freqs[4] = f4 or self.freqs[4]
    self.sampleRate = sampleRate or self.sampleRate
    self:_calcAllCoeffs()
end

---Reset all filter states
function MultiBandOptimized_5_48:reset()
    for i = 1, 176 do
        self.stateL[i] = 0
        self.stateR[i] = 0
    end
end

---Process a single stereo sample through all filters
---Returns 5 band outputs for left and right channels
---@param inL number left input sample
---@param inR number right input sample
---@return number, number, number, number, number, number, number, number, number, number band1L, band1R, band2L, band2R, band3L, band3R, band4L, band4R, band5L, band5R
function MultiBandOptimized_5_48:processSample(inL, inR)
    local c = self.coeffs
    local sL = self.stateL
    local sR = self.stateR
    
    -- Inline biquad processing
    -- state index: (biquadIdx-1)*4 + 1 for x1, +2 for x2, +3 for y1, +4 for y2
    -- coeff index: (biquadIdx-1)*5 + 1 for b0, +2 for b1, +3 for b2, +4 for a1, +5 for a2
    
    local y, x1, x2, y1, y2
    local b0, b1, b2, a1, a2
    
    -- =====================================================================
    -- Process LEFT channel
    -- =====================================================================
    local inputL = inL
    
    -- ========== STAGE 1: Split at f1 ==========
    -- LP1: 4 biquads (coeffs 1-20, state 1-16)
    x1, x2, y1, y2 = sL[1], sL[2], sL[3], sL[4]
    b0, b1, b2, a1, a2 = c[1], c[2], c[3], c[4], c[5]
    y = b0*inputL + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[2], sL[1], sL[4], sL[3] = x1, inputL, y1, y
    local lp1_1L = y
    
    x1, x2, y1, y2 = sL[5], sL[6], sL[7], sL[8]
    b0, b1, b2, a1, a2 = c[6], c[7], c[8], c[9], c[10]
    y = b0*lp1_1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[6], sL[5], sL[8], sL[7] = x1, lp1_1L, y1, y
    local lp1_2L = y
    
    x1, x2, y1, y2 = sL[9], sL[10], sL[11], sL[12]
    b0, b1, b2, a1, a2 = c[11], c[12], c[13], c[14], c[15]
    y = b0*lp1_2L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[10], sL[9], sL[12], sL[11] = x1, lp1_2L, y1, y
    local lp1_3L = y
    
    x1, x2, y1, y2 = sL[13], sL[14], sL[15], sL[16]
    b0, b1, b2, a1, a2 = c[16], c[17], c[18], c[19], c[20]
    y = b0*lp1_3L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[14], sL[13], sL[16], sL[15] = x1, lp1_3L, y1, y
    local lp1L = y
    
    -- HP1: 4 biquads (coeffs 21-40, state 17-32)
    x1, x2, y1, y2 = sL[17], sL[18], sL[19], sL[20]
    b0, b1, b2, a1, a2 = c[21], c[22], c[23], c[24], c[25]
    y = b0*inputL + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[18], sL[17], sL[20], sL[19] = x1, inputL, y1, y
    local hp1_1L = y
    
    x1, x2, y1, y2 = sL[21], sL[22], sL[23], sL[24]
    b0, b1, b2, a1, a2 = c[26], c[27], c[28], c[29], c[30]
    y = b0*hp1_1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[22], sL[21], sL[24], sL[23] = x1, hp1_1L, y1, y
    local hp1_2L = y
    
    x1, x2, y1, y2 = sL[25], sL[26], sL[27], sL[28]
    b0, b1, b2, a1, a2 = c[31], c[32], c[33], c[34], c[35]
    y = b0*hp1_2L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[26], sL[25], sL[28], sL[27] = x1, hp1_2L, y1, y
    local hp1_3L = y
    
    x1, x2, y1, y2 = sL[29], sL[30], sL[31], sL[32]
    b0, b1, b2, a1, a2 = c[36], c[37], c[38], c[39], c[40]
    y = b0*hp1_3L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[30], sL[29], sL[32], sL[31] = x1, hp1_3L, y1, y
    local hp1L = y
    
    -- ========== STAGE 2: Split HP1 output at f2 ==========
    -- LP2: 4 biquads (coeffs 41-60, state 33-48)
    x1, x2, y1, y2 = sL[33], sL[34], sL[35], sL[36]
    b0, b1, b2, a1, a2 = c[41], c[42], c[43], c[44], c[45]
    y = b0*hp1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[34], sL[33], sL[36], sL[35] = x1, hp1L, y1, y
    local lp2_1L = y
    
    x1, x2, y1, y2 = sL[37], sL[38], sL[39], sL[40]
    b0, b1, b2, a1, a2 = c[46], c[47], c[48], c[49], c[50]
    y = b0*lp2_1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[38], sL[37], sL[40], sL[39] = x1, lp2_1L, y1, y
    local lp2_2L = y
    
    x1, x2, y1, y2 = sL[41], sL[42], sL[43], sL[44]
    b0, b1, b2, a1, a2 = c[51], c[52], c[53], c[54], c[55]
    y = b0*lp2_2L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[42], sL[41], sL[44], sL[43] = x1, lp2_2L, y1, y
    local lp2_3L = y
    
    x1, x2, y1, y2 = sL[45], sL[46], sL[47], sL[48]
    b0, b1, b2, a1, a2 = c[56], c[57], c[58], c[59], c[60]
    y = b0*lp2_3L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[46], sL[45], sL[48], sL[47] = x1, lp2_3L, y1, y
    local lp2L = y
    
    -- HP2: 4 biquads (coeffs 61-80, state 49-64)
    x1, x2, y1, y2 = sL[49], sL[50], sL[51], sL[52]
    b0, b1, b2, a1, a2 = c[61], c[62], c[63], c[64], c[65]
    y = b0*hp1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[50], sL[49], sL[52], sL[51] = x1, hp1L, y1, y
    local hp2_1L = y
    
    x1, x2, y1, y2 = sL[53], sL[54], sL[55], sL[56]
    b0, b1, b2, a1, a2 = c[66], c[67], c[68], c[69], c[70]
    y = b0*hp2_1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[54], sL[53], sL[56], sL[55] = x1, hp2_1L, y1, y
    local hp2_2L = y
    
    x1, x2, y1, y2 = sL[57], sL[58], sL[59], sL[60]
    b0, b1, b2, a1, a2 = c[71], c[72], c[73], c[74], c[75]
    y = b0*hp2_2L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[58], sL[57], sL[60], sL[59] = x1, hp2_2L, y1, y
    local hp2_3L = y
    
    x1, x2, y1, y2 = sL[61], sL[62], sL[63], sL[64]
    b0, b1, b2, a1, a2 = c[76], c[77], c[78], c[79], c[80]
    y = b0*hp2_3L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[62], sL[61], sL[64], sL[63] = x1, hp2_3L, y1, y
    local hp2L = y
    
    -- ========== STAGE 3: Split HP2 output at f3 ==========
    -- LP3: 4 biquads (coeffs 81-100, state 65-80)
    x1, x2, y1, y2 = sL[65], sL[66], sL[67], sL[68]
    b0, b1, b2, a1, a2 = c[81], c[82], c[83], c[84], c[85]
    y = b0*hp2L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[66], sL[65], sL[68], sL[67] = x1, hp2L, y1, y
    local lp3_1L = y
    
    x1, x2, y1, y2 = sL[69], sL[70], sL[71], sL[72]
    b0, b1, b2, a1, a2 = c[86], c[87], c[88], c[89], c[90]
    y = b0*lp3_1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[70], sL[69], sL[72], sL[71] = x1, lp3_1L, y1, y
    local lp3_2L = y
    
    x1, x2, y1, y2 = sL[73], sL[74], sL[75], sL[76]
    b0, b1, b2, a1, a2 = c[91], c[92], c[93], c[94], c[95]
    y = b0*lp3_2L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[74], sL[73], sL[76], sL[75] = x1, lp3_2L, y1, y
    local lp3_3L = y
    
    x1, x2, y1, y2 = sL[77], sL[78], sL[79], sL[80]
    b0, b1, b2, a1, a2 = c[96], c[97], c[98], c[99], c[100]
    y = b0*lp3_3L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[78], sL[77], sL[80], sL[79] = x1, lp3_3L, y1, y
    local lp3L = y
    
    -- HP3: 4 biquads (coeffs 101-120, state 81-96)
    x1, x2, y1, y2 = sL[81], sL[82], sL[83], sL[84]
    b0, b1, b2, a1, a2 = c[101], c[102], c[103], c[104], c[105]
    y = b0*hp2L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[82], sL[81], sL[84], sL[83] = x1, hp2L, y1, y
    local hp3_1L = y
    
    x1, x2, y1, y2 = sL[85], sL[86], sL[87], sL[88]
    b0, b1, b2, a1, a2 = c[106], c[107], c[108], c[109], c[110]
    y = b0*hp3_1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[86], sL[85], sL[88], sL[87] = x1, hp3_1L, y1, y
    local hp3_2L = y
    
    x1, x2, y1, y2 = sL[89], sL[90], sL[91], sL[92]
    b0, b1, b2, a1, a2 = c[111], c[112], c[113], c[114], c[115]
    y = b0*hp3_2L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[90], sL[89], sL[92], sL[91] = x1, hp3_2L, y1, y
    local hp3_3L = y
    
    x1, x2, y1, y2 = sL[93], sL[94], sL[95], sL[96]
    b0, b1, b2, a1, a2 = c[116], c[117], c[118], c[119], c[120]
    y = b0*hp3_3L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[94], sL[93], sL[96], sL[95] = x1, hp3_3L, y1, y
    local hp3L = y
    
    -- ========== STAGE 4: Split HP3 output at f4 ==========
    -- LP4: 4 biquads (coeffs 121-140, state 97-112)
    x1, x2, y1, y2 = sL[97], sL[98], sL[99], sL[100]
    b0, b1, b2, a1, a2 = c[121], c[122], c[123], c[124], c[125]
    y = b0*hp3L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[98], sL[97], sL[100], sL[99] = x1, hp3L, y1, y
    local lp4_1L = y
    
    x1, x2, y1, y2 = sL[101], sL[102], sL[103], sL[104]
    b0, b1, b2, a1, a2 = c[126], c[127], c[128], c[129], c[130]
    y = b0*lp4_1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[102], sL[101], sL[104], sL[103] = x1, lp4_1L, y1, y
    local lp4_2L = y
    
    x1, x2, y1, y2 = sL[105], sL[106], sL[107], sL[108]
    b0, b1, b2, a1, a2 = c[131], c[132], c[133], c[134], c[135]
    y = b0*lp4_2L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[106], sL[105], sL[108], sL[107] = x1, lp4_2L, y1, y
    local lp4_3L = y
    
    x1, x2, y1, y2 = sL[109], sL[110], sL[111], sL[112]
    b0, b1, b2, a1, a2 = c[136], c[137], c[138], c[139], c[140]
    y = b0*lp4_3L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[110], sL[109], sL[112], sL[111] = x1, lp4_3L, y1, y
    local lp4L = y
    
    -- HP4: 4 biquads (coeffs 141-160, state 113-128)
    x1, x2, y1, y2 = sL[113], sL[114], sL[115], sL[116]
    b0, b1, b2, a1, a2 = c[141], c[142], c[143], c[144], c[145]
    y = b0*hp3L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[114], sL[113], sL[116], sL[115] = x1, hp3L, y1, y
    local hp4_1L = y
    
    x1, x2, y1, y2 = sL[117], sL[118], sL[119], sL[120]
    b0, b1, b2, a1, a2 = c[146], c[147], c[148], c[149], c[150]
    y = b0*hp4_1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[118], sL[117], sL[120], sL[119] = x1, hp4_1L, y1, y
    local hp4_2L = y
    
    x1, x2, y1, y2 = sL[121], sL[122], sL[123], sL[124]
    b0, b1, b2, a1, a2 = c[151], c[152], c[153], c[154], c[155]
    y = b0*hp4_2L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[122], sL[121], sL[124], sL[123] = x1, hp4_2L, y1, y
    local hp4_3L = y
    
    x1, x2, y1, y2 = sL[125], sL[126], sL[127], sL[128]
    b0, b1, b2, a1, a2 = c[156], c[157], c[158], c[159], c[160]
    y = b0*hp4_3L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[126], sL[125], sL[128], sL[127] = x1, hp4_3L, y1, y
    local hp4L = y
    
    -- ========== ALLPASS COMPENSATION ==========
    -- Band 1 needs AP2, AP3, AP4 (state 129-152)
    -- AP2 for band1: 2 biquads (coeffs 161-170, state 129-136)
    x1, x2, y1, y2 = sL[129], sL[130], sL[131], sL[132]
    b0, b1, b2, a1, a2 = c[161], c[162], c[163], c[164], c[165]
    y = b0*lp1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[130], sL[129], sL[132], sL[131] = x1, lp1L, y1, y
    local band1_ap2_1L = y
    
    x1, x2, y1, y2 = sL[133], sL[134], sL[135], sL[136]
    b0, b1, b2, a1, a2 = c[166], c[167], c[168], c[169], c[170]
    y = b0*band1_ap2_1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[134], sL[133], sL[136], sL[135] = x1, band1_ap2_1L, y1, y
    local band1_ap2L = y
    
    -- AP3 for band1: 2 biquads (coeffs 171-180, state 137-144)
    x1, x2, y1, y2 = sL[137], sL[138], sL[139], sL[140]
    b0, b1, b2, a1, a2 = c[171], c[172], c[173], c[174], c[175]
    y = b0*band1_ap2L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[138], sL[137], sL[140], sL[139] = x1, band1_ap2L, y1, y
    local band1_ap3_1L = y
    
    x1, x2, y1, y2 = sL[141], sL[142], sL[143], sL[144]
    b0, b1, b2, a1, a2 = c[176], c[177], c[178], c[179], c[180]
    y = b0*band1_ap3_1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[142], sL[141], sL[144], sL[143] = x1, band1_ap3_1L, y1, y
    local band1_ap3L = y
    
    -- AP4 for band1: 2 biquads (coeffs 181-190, state 145-152)
    x1, x2, y1, y2 = sL[145], sL[146], sL[147], sL[148]
    b0, b1, b2, a1, a2 = c[181], c[182], c[183], c[184], c[185]
    y = b0*band1_ap3L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[146], sL[145], sL[148], sL[147] = x1, band1_ap3L, y1, y
    local band1_ap4_1L = y
    
    x1, x2, y1, y2 = sL[149], sL[150], sL[151], sL[152]
    b0, b1, b2, a1, a2 = c[186], c[187], c[188], c[189], c[190]
    y = b0*band1_ap4_1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[150], sL[149], sL[152], sL[151] = x1, band1_ap4_1L, y1, y
    local band1L = y
    
    -- Band 2 needs AP3, AP4 (state 153-168)
    -- AP3 for band2: 2 biquads (coeffs 191-200, state 153-160)
    x1, x2, y1, y2 = sL[153], sL[154], sL[155], sL[156]
    b0, b1, b2, a1, a2 = c[191], c[192], c[193], c[194], c[195]
    y = b0*lp2L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[154], sL[153], sL[156], sL[155] = x1, lp2L, y1, y
    local band2_ap3_1L = y
    
    x1, x2, y1, y2 = sL[157], sL[158], sL[159], sL[160]
    b0, b1, b2, a1, a2 = c[196], c[197], c[198], c[199], c[200]
    y = b0*band2_ap3_1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[158], sL[157], sL[160], sL[159] = x1, band2_ap3_1L, y1, y
    local band2_ap3L = y
    
    -- AP4 for band2: 2 biquads (coeffs 201-210, state 161-168)
    x1, x2, y1, y2 = sL[161], sL[162], sL[163], sL[164]
    b0, b1, b2, a1, a2 = c[201], c[202], c[203], c[204], c[205]
    y = b0*band2_ap3L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[162], sL[161], sL[164], sL[163] = x1, band2_ap3L, y1, y
    local band2_ap4_1L = y
    
    x1, x2, y1, y2 = sL[165], sL[166], sL[167], sL[168]
    b0, b1, b2, a1, a2 = c[206], c[207], c[208], c[209], c[210]
    y = b0*band2_ap4_1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[166], sL[165], sL[168], sL[167] = x1, band2_ap4_1L, y1, y
    local band2L = y
    
    -- Band 3 needs AP4 (state 169-176)
    -- AP4 for band3: 2 biquads (coeffs 211-220, state 169-176)
    x1, x2, y1, y2 = sL[169], sL[170], sL[171], sL[172]
    b0, b1, b2, a1, a2 = c[211], c[212], c[213], c[214], c[215]
    y = b0*lp3L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[170], sL[169], sL[172], sL[171] = x1, lp3L, y1, y
    local band3_ap4_1L = y
    
    x1, x2, y1, y2 = sL[173], sL[174], sL[175], sL[176]
    b0, b1, b2, a1, a2 = c[216], c[217], c[218], c[219], c[220]
    y = b0*band3_ap4_1L + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sL[174], sL[173], sL[176], sL[175] = x1, band3_ap4_1L, y1, y
    local band3L = y
    
    -- Band 4 = lp4L (no allpass needed)
    local band4L = lp4L
    
    -- Band 5 = hp4L (no allpass needed)
    local band5L = hp4L
    
    -- =====================================================================
    -- Process RIGHT channel (same structure)
    -- =====================================================================
    local inputR = inR
    
    -- LP1: 4 biquads
    x1, x2, y1, y2 = sR[1], sR[2], sR[3], sR[4]
    b0, b1, b2, a1, a2 = c[1], c[2], c[3], c[4], c[5]
    y = b0*inputR + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[2], sR[1], sR[4], sR[3] = x1, inputR, y1, y
    local lp1_1R = y
    
    x1, x2, y1, y2 = sR[5], sR[6], sR[7], sR[8]
    b0, b1, b2, a1, a2 = c[6], c[7], c[8], c[9], c[10]
    y = b0*lp1_1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[6], sR[5], sR[8], sR[7] = x1, lp1_1R, y1, y
    local lp1_2R = y
    
    x1, x2, y1, y2 = sR[9], sR[10], sR[11], sR[12]
    b0, b1, b2, a1, a2 = c[11], c[12], c[13], c[14], c[15]
    y = b0*lp1_2R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[10], sR[9], sR[12], sR[11] = x1, lp1_2R, y1, y
    local lp1_3R = y
    
    x1, x2, y1, y2 = sR[13], sR[14], sR[15], sR[16]
    b0, b1, b2, a1, a2 = c[16], c[17], c[18], c[19], c[20]
    y = b0*lp1_3R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[14], sR[13], sR[16], sR[15] = x1, lp1_3R, y1, y
    local lp1R = y
    
    -- HP1: 4 biquads
    x1, x2, y1, y2 = sR[17], sR[18], sR[19], sR[20]
    b0, b1, b2, a1, a2 = c[21], c[22], c[23], c[24], c[25]
    y = b0*inputR + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[18], sR[17], sR[20], sR[19] = x1, inputR, y1, y
    local hp1_1R = y
    
    x1, x2, y1, y2 = sR[21], sR[22], sR[23], sR[24]
    b0, b1, b2, a1, a2 = c[26], c[27], c[28], c[29], c[30]
    y = b0*hp1_1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[22], sR[21], sR[24], sR[23] = x1, hp1_1R, y1, y
    local hp1_2R = y
    
    x1, x2, y1, y2 = sR[25], sR[26], sR[27], sR[28]
    b0, b1, b2, a1, a2 = c[31], c[32], c[33], c[34], c[35]
    y = b0*hp1_2R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[26], sR[25], sR[28], sR[27] = x1, hp1_2R, y1, y
    local hp1_3R = y
    
    x1, x2, y1, y2 = sR[29], sR[30], sR[31], sR[32]
    b0, b1, b2, a1, a2 = c[36], c[37], c[38], c[39], c[40]
    y = b0*hp1_3R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[30], sR[29], sR[32], sR[31] = x1, hp1_3R, y1, y
    local hp1R = y
    
    -- LP2: 4 biquads
    x1, x2, y1, y2 = sR[33], sR[34], sR[35], sR[36]
    b0, b1, b2, a1, a2 = c[41], c[42], c[43], c[44], c[45]
    y = b0*hp1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[34], sR[33], sR[36], sR[35] = x1, hp1R, y1, y
    local lp2_1R = y
    
    x1, x2, y1, y2 = sR[37], sR[38], sR[39], sR[40]
    b0, b1, b2, a1, a2 = c[46], c[47], c[48], c[49], c[50]
    y = b0*lp2_1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[38], sR[37], sR[40], sR[39] = x1, lp2_1R, y1, y
    local lp2_2R = y
    
    x1, x2, y1, y2 = sR[41], sR[42], sR[43], sR[44]
    b0, b1, b2, a1, a2 = c[51], c[52], c[53], c[54], c[55]
    y = b0*lp2_2R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[42], sR[41], sR[44], sR[43] = x1, lp2_2R, y1, y
    local lp2_3R = y
    
    x1, x2, y1, y2 = sR[45], sR[46], sR[47], sR[48]
    b0, b1, b2, a1, a2 = c[56], c[57], c[58], c[59], c[60]
    y = b0*lp2_3R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[46], sR[45], sR[48], sR[47] = x1, lp2_3R, y1, y
    local lp2R = y
    
    -- HP2: 4 biquads
    x1, x2, y1, y2 = sR[49], sR[50], sR[51], sR[52]
    b0, b1, b2, a1, a2 = c[61], c[62], c[63], c[64], c[65]
    y = b0*hp1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[50], sR[49], sR[52], sR[51] = x1, hp1R, y1, y
    local hp2_1R = y
    
    x1, x2, y1, y2 = sR[53], sR[54], sR[55], sR[56]
    b0, b1, b2, a1, a2 = c[66], c[67], c[68], c[69], c[70]
    y = b0*hp2_1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[54], sR[53], sR[56], sR[55] = x1, hp2_1R, y1, y
    local hp2_2R = y
    
    x1, x2, y1, y2 = sR[57], sR[58], sR[59], sR[60]
    b0, b1, b2, a1, a2 = c[71], c[72], c[73], c[74], c[75]
    y = b0*hp2_2R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[58], sR[57], sR[60], sR[59] = x1, hp2_2R, y1, y
    local hp2_3R = y
    
    x1, x2, y1, y2 = sR[61], sR[62], sR[63], sR[64]
    b0, b1, b2, a1, a2 = c[76], c[77], c[78], c[79], c[80]
    y = b0*hp2_3R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[62], sR[61], sR[64], sR[63] = x1, hp2_3R, y1, y
    local hp2R = y
    
    -- LP3: 4 biquads
    x1, x2, y1, y2 = sR[65], sR[66], sR[67], sR[68]
    b0, b1, b2, a1, a2 = c[81], c[82], c[83], c[84], c[85]
    y = b0*hp2R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[66], sR[65], sR[68], sR[67] = x1, hp2R, y1, y
    local lp3_1R = y
    
    x1, x2, y1, y2 = sR[69], sR[70], sR[71], sR[72]
    b0, b1, b2, a1, a2 = c[86], c[87], c[88], c[89], c[90]
    y = b0*lp3_1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[70], sR[69], sR[72], sR[71] = x1, lp3_1R, y1, y
    local lp3_2R = y
    
    x1, x2, y1, y2 = sR[73], sR[74], sR[75], sR[76]
    b0, b1, b2, a1, a2 = c[91], c[92], c[93], c[94], c[95]
    y = b0*lp3_2R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[74], sR[73], sR[76], sR[75] = x1, lp3_2R, y1, y
    local lp3_3R = y
    
    x1, x2, y1, y2 = sR[77], sR[78], sR[79], sR[80]
    b0, b1, b2, a1, a2 = c[96], c[97], c[98], c[99], c[100]
    y = b0*lp3_3R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[78], sR[77], sR[80], sR[79] = x1, lp3_3R, y1, y
    local lp3R = y
    
    -- HP3: 4 biquads
    x1, x2, y1, y2 = sR[81], sR[82], sR[83], sR[84]
    b0, b1, b2, a1, a2 = c[101], c[102], c[103], c[104], c[105]
    y = b0*hp2R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[82], sR[81], sR[84], sR[83] = x1, hp2R, y1, y
    local hp3_1R = y
    
    x1, x2, y1, y2 = sR[85], sR[86], sR[87], sR[88]
    b0, b1, b2, a1, a2 = c[106], c[107], c[108], c[109], c[110]
    y = b0*hp3_1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[86], sR[85], sR[88], sR[87] = x1, hp3_1R, y1, y
    local hp3_2R = y
    
    x1, x2, y1, y2 = sR[89], sR[90], sR[91], sR[92]
    b0, b1, b2, a1, a2 = c[111], c[112], c[113], c[114], c[115]
    y = b0*hp3_2R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[90], sR[89], sR[92], sR[91] = x1, hp3_2R, y1, y
    local hp3_3R = y
    
    x1, x2, y1, y2 = sR[93], sR[94], sR[95], sR[96]
    b0, b1, b2, a1, a2 = c[116], c[117], c[118], c[119], c[120]
    y = b0*hp3_3R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[94], sR[93], sR[96], sR[95] = x1, hp3_3R, y1, y
    local hp3R = y
    
    -- LP4: 4 biquads
    x1, x2, y1, y2 = sR[97], sR[98], sR[99], sR[100]
    b0, b1, b2, a1, a2 = c[121], c[122], c[123], c[124], c[125]
    y = b0*hp3R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[98], sR[97], sR[100], sR[99] = x1, hp3R, y1, y
    local lp4_1R = y
    
    x1, x2, y1, y2 = sR[101], sR[102], sR[103], sR[104]
    b0, b1, b2, a1, a2 = c[126], c[127], c[128], c[129], c[130]
    y = b0*lp4_1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[102], sR[101], sR[104], sR[103] = x1, lp4_1R, y1, y
    local lp4_2R = y
    
    x1, x2, y1, y2 = sR[105], sR[106], sR[107], sR[108]
    b0, b1, b2, a1, a2 = c[131], c[132], c[133], c[134], c[135]
    y = b0*lp4_2R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[106], sR[105], sR[108], sR[107] = x1, lp4_2R, y1, y
    local lp4_3R = y
    
    x1, x2, y1, y2 = sR[109], sR[110], sR[111], sR[112]
    b0, b1, b2, a1, a2 = c[136], c[137], c[138], c[139], c[140]
    y = b0*lp4_3R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[110], sR[109], sR[112], sR[111] = x1, lp4_3R, y1, y
    local lp4R = y
    
    -- HP4: 4 biquads
    x1, x2, y1, y2 = sR[113], sR[114], sR[115], sR[116]
    b0, b1, b2, a1, a2 = c[141], c[142], c[143], c[144], c[145]
    y = b0*hp3R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[114], sR[113], sR[116], sR[115] = x1, hp3R, y1, y
    local hp4_1R = y
    
    x1, x2, y1, y2 = sR[117], sR[118], sR[119], sR[120]
    b0, b1, b2, a1, a2 = c[146], c[147], c[148], c[149], c[150]
    y = b0*hp4_1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[118], sR[117], sR[120], sR[119] = x1, hp4_1R, y1, y
    local hp4_2R = y
    
    x1, x2, y1, y2 = sR[121], sR[122], sR[123], sR[124]
    b0, b1, b2, a1, a2 = c[151], c[152], c[153], c[154], c[155]
    y = b0*hp4_2R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[122], sR[121], sR[124], sR[123] = x1, hp4_2R, y1, y
    local hp4_3R = y
    
    x1, x2, y1, y2 = sR[125], sR[126], sR[127], sR[128]
    b0, b1, b2, a1, a2 = c[156], c[157], c[158], c[159], c[160]
    y = b0*hp4_3R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[126], sR[125], sR[128], sR[127] = x1, hp4_3R, y1, y
    local hp4R = y
    
    -- Allpass for right channel
    -- AP2 for band1
    x1, x2, y1, y2 = sR[129], sR[130], sR[131], sR[132]
    b0, b1, b2, a1, a2 = c[161], c[162], c[163], c[164], c[165]
    y = b0*lp1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[130], sR[129], sR[132], sR[131] = x1, lp1R, y1, y
    local band1_ap2_1R = y
    
    x1, x2, y1, y2 = sR[133], sR[134], sR[135], sR[136]
    b0, b1, b2, a1, a2 = c[166], c[167], c[168], c[169], c[170]
    y = b0*band1_ap2_1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[134], sR[133], sR[136], sR[135] = x1, band1_ap2_1R, y1, y
    local band1_ap2R = y
    
    -- AP3 for band1
    x1, x2, y1, y2 = sR[137], sR[138], sR[139], sR[140]
    b0, b1, b2, a1, a2 = c[171], c[172], c[173], c[174], c[175]
    y = b0*band1_ap2R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[138], sR[137], sR[140], sR[139] = x1, band1_ap2R, y1, y
    local band1_ap3_1R = y
    
    x1, x2, y1, y2 = sR[141], sR[142], sR[143], sR[144]
    b0, b1, b2, a1, a2 = c[176], c[177], c[178], c[179], c[180]
    y = b0*band1_ap3_1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[142], sR[141], sR[144], sR[143] = x1, band1_ap3_1R, y1, y
    local band1_ap3R = y
    
    -- AP4 for band1
    x1, x2, y1, y2 = sR[145], sR[146], sR[147], sR[148]
    b0, b1, b2, a1, a2 = c[181], c[182], c[183], c[184], c[185]
    y = b0*band1_ap3R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[146], sR[145], sR[148], sR[147] = x1, band1_ap3R, y1, y
    local band1_ap4_1R = y
    
    x1, x2, y1, y2 = sR[149], sR[150], sR[151], sR[152]
    b0, b1, b2, a1, a2 = c[186], c[187], c[188], c[189], c[190]
    y = b0*band1_ap4_1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[150], sR[149], sR[152], sR[151] = x1, band1_ap4_1R, y1, y
    local band1R = y
    
    -- AP3 for band2
    x1, x2, y1, y2 = sR[153], sR[154], sR[155], sR[156]
    b0, b1, b2, a1, a2 = c[191], c[192], c[193], c[194], c[195]
    y = b0*lp2R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[154], sR[153], sR[156], sR[155] = x1, lp2R, y1, y
    local band2_ap3_1R = y
    
    x1, x2, y1, y2 = sR[157], sR[158], sR[159], sR[160]
    b0, b1, b2, a1, a2 = c[196], c[197], c[198], c[199], c[200]
    y = b0*band2_ap3_1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[158], sR[157], sR[160], sR[159] = x1, band2_ap3_1R, y1, y
    local band2_ap3R = y
    
    -- AP4 for band2
    x1, x2, y1, y2 = sR[161], sR[162], sR[163], sR[164]
    b0, b1, b2, a1, a2 = c[201], c[202], c[203], c[204], c[205]
    y = b0*band2_ap3R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[162], sR[161], sR[164], sR[163] = x1, band2_ap3R, y1, y
    local band2_ap4_1R = y
    
    x1, x2, y1, y2 = sR[165], sR[166], sR[167], sR[168]
    b0, b1, b2, a1, a2 = c[206], c[207], c[208], c[209], c[210]
    y = b0*band2_ap4_1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[166], sR[165], sR[168], sR[167] = x1, band2_ap4_1R, y1, y
    local band2R = y
    
    -- AP4 for band3
    x1, x2, y1, y2 = sR[169], sR[170], sR[171], sR[172]
    b0, b1, b2, a1, a2 = c[211], c[212], c[213], c[214], c[215]
    y = b0*lp3R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[170], sR[169], sR[172], sR[171] = x1, lp3R, y1, y
    local band3_ap4_1R = y
    
    x1, x2, y1, y2 = sR[173], sR[174], sR[175], sR[176]
    b0, b1, b2, a1, a2 = c[216], c[217], c[218], c[219], c[220]
    y = b0*band3_ap4_1R + b1*x1 + b2*x2 - a1*y1 - a2*y2
    sR[174], sR[173], sR[176], sR[175] = x1, band3_ap4_1R, y1, y
    local band3R = y
    
    local band4R = lp4R
    local band5R = hp4R
    
    return band1L, band1R, band2L, band2R, band3L, band3R, band4L, band4R, band5L, band5R
end

---Process stereo block and split into 5 frequency bands
---@param stereoIn table stereo input {[1]=left, [2]=right}
---@param smax integer maximum sample index
---@return table[] bands array of 5 bands, each {[1]=left, [2]=right}
function MultiBandOptimized_5_48:processStereoBlock(stereoIn, smax)
    local inL = stereoIn[1]
    local inR = stereoIn[2]
    local bands = self._bandsBuffer
    
    -- Get output buffer references
    local b1L, b1R = bands[1][1], bands[1][2]
    local b2L, b2R = bands[2][1], bands[2][2]
    local b3L, b3R = bands[3][1], bands[3][2]
    local b4L, b4R = bands[4][1], bands[4][2]
    local b5L, b5R = bands[5][1], bands[5][2]
    
    for i = 0, smax do
        local o1L, o1R, o2L, o2R, o3L, o3R, o4L, o4R, o5L, o5R = 
            self:processSample(inL[i], inR[i])
        b1L[i], b1R[i] = o1L, o1R
        b2L[i], b2R[i] = o2L, o2R
        b3L[i], b3R[i] = o3L, o3R
        b4L[i], b4R[i] = o4L, o4R
        b5L[i], b5R[i] = o5L, o5R
    end
    
    return bands
end

---Sum all bands with optional per-band gains
---@param bands table[] bands from processStereoBlock
---@param smax integer maximum sample index
---@param gains number[]? optional gains per band
---@return table sumL left channel sum
---@return table sumR right channel sum
function MultiBandOptimized_5_48:sumBands(bands, smax, gains)
    local g1 = gains and gains[1] or 1.0
    local g2 = gains and gains[2] or 1.0
    local g3 = gains and gains[3] or 1.0
    local g4 = gains and gains[4] or 1.0
    local g5 = gains and gains[5] or 1.0
    
    local b1L, b1R = bands[1][1], bands[1][2]
    local b2L, b2R = bands[2][1], bands[2][2]
    local b3L, b3R = bands[3][1], bands[3][2]
    local b4L, b4R = bands[4][1], bands[4][2]
    local b5L, b5R = bands[5][1], bands[5][2]
    
    local sumL = self._sumL
    local sumR = self._sumR
    
    for i = 0, smax do
        sumL[i] = g1*b1L[i] + g2*b2L[i] + g3*b3L[i] + g4*b4L[i] + g5*b5L[i]
        sumR[i] = g1*b1R[i] + g2*b2R[i] + g3*b3R[i] + g4*b4R[i] + g5*b5R[i]
    end
    
    return sumL, sumR
end

---Get number of bands (always 5)
---@return integer
function MultiBandOptimized_5_48:getNumBands()
    return 5
end

---Get crossover frequencies
---@return number[] freqs
function MultiBandOptimized_5_48:getFrequencies()
    return self.freqs
end

return MultiBandOptimized_5_48
