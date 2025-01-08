
require "include/protoplug"
package.cpath = package.cpath .. ";"..protoplug_dir.."/lib/?.dll"

local socket = require("include/socket")

--local connected = socket.connect("127.0.0.1",8000)

math.randomseed(socket.gettime())

-- client-no; ppq; num-points; points*

local clientNo = 1

local PLAYING = false
local connected = nil

local PROCESS_BLOCK_COUNTER = 0

local collectedSamplesNumber = nil
local collectedSamples = nil
local toBeSent = nil

function plugin.processBlock(samples, smax, midiBuf)
    local pluginPosition = plugin.getCurrentPosition()
    local ppq = pluginPosition.ppqPosition
    --
    if not PLAYING and pluginPosition.isPlaying then
        -- switch from not playing to playing
        PLAYING = true
        connected = socket.connect("127.0.0.1",8000)
        connected:settimeout(0)
        connected:setoption("tcp-nodelay",true)
    end
    if PLAYING and not pluginPosition.isPlaying then
        -- switch from playing to not playing
        PLAYING = false
        connected:close()
        connected = nil
    end
    --
    if (PROCESS_BLOCK_COUNTER % 2 == 0) then
        collectedSamplesNumber = 0
        collectedSamples = ""
        toBeSent = clientNo..";"..ppq
    end
    --
    local dereferencedSamples = samples[0]
    for i = 0,smax do
        -- result = result .. string.format("%f",samples[0][i]) .. ";"
        collectedSamples = collectedSamples .. tostring(dereferencedSamples[i]) .. ";"
    end
    --
    collectedSamplesNumber = collectedSamplesNumber + smax + 1
    --
    if (PROCESS_BLOCK_COUNTER % 2 == 1) then
        if PLAYING and connected then
            toBeSent = toBeSent..";"..collectedSamplesNumber..";"..collectedSamples.."\r\n"
            --print(toBeSent)
            connected:send(toBeSent)
        end
    end
    --
    PROCESS_BLOCK_COUNTER = PROCESS_BLOCK_COUNTER + 1
end
