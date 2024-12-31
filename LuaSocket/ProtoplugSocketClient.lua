
require "include/protoplug"
package.cpath = package.cpath .. ";"..protoplug_dir.."/lib/?.dll"

local socket = require("socket")

--local connected = socket.connect("127.0.0.1",8000)

math.randomseed(socket.gettime())

-- client-no; ppq; num-points; points*

local values = {}
for i=1,480 do
    values[i] = ((math.random(0,100)-50) / 100.0)
end

local result = ""
for i = 1,#values do
    result = result .. values[i] .. ";"
end
--print(result)

local clientNo = 1

--local toBeSent = clientNo..";"..ppq..";"..numPoints..";"..result..";\r\n"
--print(toBeSent)
--connected:send(toBeSent)

--connected:close()

local PLAYING = false
local connected = nil

function plugin.processBlock(samples, smax, midiBuf)
    local pluginPosition = plugin.getCurrentPosition()
    local ppq = pluginPosition.ppqPosition
    --
    if not PLAYING and pluginPosition.isPlaying then
        -- switch from not playing to playing
        PLAYING = true
        connected = socket.connect("127.0.0.1",8000)
    end
    if PLAYING and not pluginPosition.isPlaying then
        -- switch from playing to not playing
        PLAYING = false
        connected:close()
        connected = nil
    end
    --
    local result = ""
    for i = 0,smax do
        result = result .. string.format("%f",samples[0][i]) .. ";"
    end

    if PLAYING and connected then
        local toBeSent = clientNo..";"..ppq..";"..smax..";"..result..";\r\n"
        --print(toBeSent)
        connected:send(toBeSent)
    end
end
