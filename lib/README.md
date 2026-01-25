# Linkwitz-Riley Multiband Crossover Filter

A Lua implementation of Linkwitz-Riley (LR) crossover filters for audio signal processing in Protoplug, supporting configurable N-band splitting with flat frequency response when bands are summed.

## Table of Contents

- [Overview](#overview)
- [The Problem: Multiband Crossovers](#the-problem-multiband-crossovers)
- [Mathematical Foundations](#mathematical-foundations)
- [Implementation Details](#implementation-details)
- [Usage](#usage)
- [API Reference](#api-reference)
- [Appendix: Sources](#appendix-sources)

---

## Overview

Linkwitz-Riley filters are a family of crossover filters designed for audio applications where the sum of the lowpass and highpass outputs must reconstruct the original signal with flat magnitude response. They are characterized by:

- **-6 dB at the crossover frequency** (both LP and HP)
- **In-phase outputs** at the crossover point
- **Flat magnitude response** when LP + HP are summed

This implementation provides:
- **LR4 (24 dB/octave)**: 4th order, 2 cascaded Butterworth biquads
- **LR8 (48 dB/octave)**: 8th order, 4 cascaded Butterworth biquads
- **N-band crossover** (2 to 7 bands) with allpass phase compensation

---

## The Problem: Multiband Crossovers

### Why Simple Topologies Fail

For a **2-band crossover**, Linkwitz-Riley filters sum perfectly flat:

$$LP_{LR4}(f) + HP_{LR4}(f) = \text{allpass}(f) \quad \text{(unity magnitude)}$$

However, for **3+ bands**, naive topologies produce dips at crossover frequencies due to phase misalignment between non-adjacent bands.

From [Linkwitz Lab](https://www.linkwitzlab.com/frontiers_5.htm):

> "The typical parallel arrangement of crossover filters yields a flat summed frequency response **only if** the constituent highpass and lowpass filter responses are **unaffected by adjacent crossover filter sections**."

#### Phase Error Example (4-way at 50Hz, 200Hz, 2kHz)

| Interaction | Phase Error | Magnitude Error |
|-------------|-------------|-----------------|
| 50Hz HP adds to 200Hz LP | +41° | -0.034 dB |
| 200Hz LP adds to 50Hz HP | -41° | -0.43 dB at 100Hz |
| 200Hz HP adds to 2kHz LP | +16° | -0.001 dB |

### The Solution: Allpass Phase Compensation

From [Linkwitz Lab](https://www.linkwitzlab.com/frontiers_5.htm):

> "A maximally flat response is obtained when also the **200 Hz lowpass filter phase shift in the W channel is duplicated in the SW channel by an allpass filter** with the same phase response."

The solution is to add **allpass filters** to lower bands that match the phase response of higher crossover stages:

| Band | Required Allpass Compensation |
|------|-------------------------------|
| Band 1 (lowest) | AP(f2) + AP(f3) + ... + AP(fN-1) |
| Band 2 | AP(f3) + AP(f4) + ... + AP(fN-1) |
| Band 3 | AP(f4) + ... + AP(fN-1) |
| ... | ... |
| Band N-1 | (none, phase already in cascade) |
| Band N (highest) | None |

---

## Mathematical Foundations

### Linkwitz-Riley Transfer Functions

LR filters are created by cascading (squaring) Butterworth filters of order N/2.

**LR4 (24 dB/oct) = Butterworth 2nd order squared:**

$$LP_{LR4}(s) = \frac{1}{(s^2 + \sqrt{2}s + 1)^2}$$

$$HP_{LR4}(s) = \frac{s^4}{(s^2 + \sqrt{2}s + 1)^2}$$

**Sum:**

$$LP_{LR4} + HP_{LR4} = \frac{1 + s^4}{(s^2 + \sqrt{2}s + 1)^2}$$

This sum is a **2nd order allpass** — unity magnitude at all frequencies, but with phase shift.

### Q Values for Cascaded Butterworth Stages

From [Linkwitz Lab Filter Tables](https://www.linkwitzlab.com/filters.htm):

| Filter Type | Stage 1 Q | Stage 2 Q | Stage 3 Q | Stage 4 Q |
|-------------|-----------|-----------|-----------|-----------|
| **LR4 (24dB/oct)** | 0.7071 | 0.7071 | - | - |
| **LR8 (48dB/oct)** | 0.5412 | 0.5412 | 1.3065 | 1.3065 |

The Q values for 4th order Butterworth (used in LR8) are:

$$Q_1 = \frac{1}{2 \cos(\pi/8)} \approx 0.5412$$

$$Q_2 = \frac{1}{2 \cos(3\pi/8)} \approx 1.3065$$

### Allpass Order for Phase Compensation

**Critical insight**: The allpass filter needed to match LP+HP phase is **half the order** of the LR filter:

| LR Type | LP/HP Order | Allpass Order |
|---------|-------------|---------------|
| LR4 (24dB) | 4th (2 biquads) | **2nd** (1 biquad, Q=0.7071) |
| LR8 (48dB) | 8th (4 biquads) | **4th** (2 biquads, Q=0.5412, 1.3065) |

### 2nd Order Allpass Biquad

The allpass transfer function with quality factor Q:

$$H_{AP}(s) = \frac{s^2 - \frac{s}{Q} + 1}{s^2 + \frac{s}{Q} + 1}$$

Digital biquad coefficients (Direct Form I):

```
omega = 2 * pi * freq / sampleRate
sn = sin(omega)
cs = cos(omega)
alpha = sn / (2 * Q)

b0 = 1 - alpha
b1 = -2 * cs
b2 = 1 + alpha
a0 = 1 + alpha
a1 = -2 * cs
a2 = 1 - alpha
```

---

## Implementation Details

### Architecture

```
MultiBandN (5 bands at f1=300, f2=1k, f3=4k, f4=8k)
│
├─ Stage 1 (f1=300Hz)
│   ├─ LP → Band 1 → AP(f2) → AP(f3) → AP(f4) → Output Band 1
│   └─ HP → input to Stage 2
│
├─ Stage 2 (f2=1kHz)  
│   ├─ LP → Band 2 → AP(f3) → AP(f4) → Output Band 2
│   └─ HP → input to Stage 3
│
├─ Stage 3 (f3=4kHz)
│   ├─ LP → Band 3 → AP(f4) → Output Band 3
│   └─ HP → input to Stage 4
│
├─ Stage 4 (f4=8kHz)
│   ├─ LP → Band 4 (no AP needed) → Output Band 4
│   └─ HP → Band 5 (no AP needed) → Output Band 5
```

### Serial Cascading Topology

At each crossover stage, **both LP and HP process the same input signal**:

```lua
for f = 1, numFreqs do
    -- Both LP and HP process the SAME input signal
    local lpL = self.lpFiltersL[f]:processSample(inputL)
    local hpL = self.hpFiltersL[f]:processSample(inputL)
    
    -- LP output = this band (with allpass compensation)
    bands[f][1][i] = applyAllpass(lpL, f)
    
    -- HP output becomes input to next stage
    inputL = hpL
end
```

This topology guarantees that at each crossover:
$$LP(f) + HP(f) = \text{allpass}(f)$$

### Allpass Compensation

Lower bands accumulate phase delay from higher crossover stages. To compensate:

```lua
-- Band f needs allpass at frequencies f+1 through numFreqs
for apFreq = f + 1, numFreqs do
    bandL = self.allpassL[f][apFreq]:processSample(bandL)
end
```

### Biquad Processing (Direct Form I)

```lua
function LinkwitzRileyFilter:processSample(x)
    local y = x
    for i = 1, self.numStages do
        local c = self.coeffsList[i]
        local s = self.stages[i]
        local y0 = c.b0*y + c.b1*s.x1 + c.b2*s.x2 - c.a1*s.y1 - c.a2*s.y2
        s.x2, s.x1 = s.x1, y
        s.y2, s.y1 = s.y1, y0
        y = y0
    end
    return y
end
```

---

## Usage

### Basic 5-Band Crossover

```lua
local LRFilters = require("LinkwitzRileyFilter")

-- Create 5-band crossover at 300Hz, 1kHz, 4kHz, 8kHz
local multiBand = LRFilters.MultiBandN.new(
    LRFilters.Slope.DB48,           -- 48 dB/octave slopes
    {300.0, 1000.0, 4000.0, 8000.0}, -- crossover frequencies
    44100                            -- sample rate
)

function plugin.processBlock(samples, smax, midiBuf)
    local stereoIn = {[1]=samples[0], [2]=samples[1]}
    
    -- Split into 5 bands
    local bands = multiBand:processStereoBlock(stereoIn, smax)
    
    -- Sum all bands (flat frequency response)
    local sumL, sumR = multiBand:sumBands(bands, smax)
    
    -- Or apply per-band gains
    local gains = {1.0, 0.5, 1.0, 0.8, 1.0}
    local sumL, sumR = multiBand:sumBands(bands, smax, gains)
    
    -- Write output
    for i = 0, smax do
        samples[0][i] = sumL[i]
        samples[1][i] = sumR[i]
    end
end
```

### Simple 2-Band Crossover

```lua
local crossover = LRFilters.CrossOver.new(
    LRFilters.Slope.DB24,  -- 24 dB/octave
    1000.0,                -- crossover at 1kHz
    44100                  -- sample rate
)

local lpBand, hpBand = crossover:processStereoBlock(stereoIn, smax)
```

---

## API Reference

### Slope Enum

```lua
LRFilters.Slope.DB24  -- 24 dB/octave (LR4, 2 biquads)
LRFilters.Slope.DB48  -- 48 dB/octave (LR8, 4 biquads)
```

### LinkwitzRileyFilter (Mono)

```lua
local filter = LRFilters.Mono.new(type, slope, freq, sampleRate)
-- type: "lp", "hp", or "allpass"
-- slope: Slope.DB24 or Slope.DB48
-- freq: cutoff frequency in Hz
-- sampleRate: sample rate in Hz

filter:setParams(type, slope, freq, sampleRate)  -- update parameters
filter:reset()                                     -- clear delay states
local y = filter:processSample(x)                 -- process single sample
local out = filter:processMonoBlock(samples, smax) -- process buffer
```

### StereoLinkwitzRileyFilter

```lua
local filter = LRFilters.Stereo.new(type, slope, freq, sampleRate)
local outL, outR = filter:processStereoBlock(stereoIn, smax)
```

### CrossOver (2-Band)

```lua
local xo = LRFilters.CrossOver.new(slope, freq, sampleRate)
local lpBand, hpBand = xo:processStereoBlock(stereoIn, smax)
```

### MultiBandN (N-Band)

```lua
local mb = LRFilters.MultiBandN.new(slope, freqs, sampleRate)
-- freqs: table of crossover frequencies {f1, f2, ...}
-- N bands requires N-1 frequencies

local bands = mb:processStereoBlock(stereoIn, smax)
-- Returns: bands[1..N], each is {[1]=leftSamples, [2]=rightSamples}

local sumL, sumR = mb:sumBands(bands, smax, gains)
-- gains: optional table of per-band gain values

local numBands = mb:getNumBands()
local freqs = mb:getFrequencies()
```

---

## Appendix: Sources

### Primary References

1. **Linkwitz Lab - Crossover Topologies**  
   https://www.linkwitzlab.com/frontiers_5.htm  
   *Critical analysis of phase errors in multiband crossovers and allpass compensation requirements.*

2. **Linkwitz Lab - Active Filters**  
   https://www.linkwitzlab.com/filters.htm  
   *Filter tables with Q values for cascaded Butterworth stages, allpass delay correction.*

3. **Linkwitz Lab - Crossovers**  
   https://www.linkwitzlab.com/crossovers.htm  
   *Duelund 3-way crossover derivation, mathematical foundations.*

4. **MusicDSP - 4th Order Linkwitz-Riley Filters**  
   https://www.musicdsp.org/en/latest/Filters/266-4th-order-linkwitz-riley-filters.html  
   *Digital implementation code and coefficient formulas.*

5. **EarLevel Engineering - Cascading Filters**  
   https://www.earlevel.com/main/2016/09/29/cascading-filters/  
   *Q values for cascaded Butterworth stages.*

### Key Quotes

From Linkwitz Lab on parallel topology failure:
> "The typical parallel arrangement of crossover filters yields a flat summed frequency response **only if** the constituent highpass and lowpass filter responses are **unaffected by adjacent crossover filter sections**."

From Linkwitz Lab on allpass compensation:
> "A maximally flat response is obtained when also the **lowpass filter phase shift in the lower channel is duplicated by an allpass filter** with the same phase response."

From Linkwitz Lab on cascaded topology benefits:
> "In the **cascaded** crossover filter topology, the phase shift from the lower highpass at the upper crossover frequency **is carried into** the upper lowpass and highpass sections. Thus the upper crossover filter sections add correctly."

### Additional Reading

- **Rane Note 160 - Linkwitz-Riley Crossovers**  
  https://www.rane.com/note160.html

- **miniDSP - Linkwitz-Riley Crossovers**  
  https://www.minidsp.com/applications/dsp-basics/linkwitz-riley-crossovers

- **Audio Judgement - Linkwitz-Riley Crossover**  
  https://audiojudgement.com/linkwitz-riley-crossover/

---

## License

This implementation is provided as-is for educational and personal use.

## Author

https://github.com/huberp
