
require "include/protoplug"
package.cpath = package.cpath..";"..protoplug_dir.."/lib/?.dll"
package.path  = package.path.. ";"..protoplug_dir.."/include/?.lua"

local socket = require("socket")
--
local base64 = require("based/64/rfc")
local base64_encode = base64.encode
--
local mp = require("CBOR")
mp.set_float'double'
mp.set_array'without_hole'
mp.set_string'text_string'
local mp_encode = mp.encode

local tostring = tostring
local s_len = string.len
--math.randomseed(socket.gettime())

local clientNo = 1

local PLAYING = false
local connected = nil

local PROCESS_BLOCK_COUNTER = 0
local COLLECT_ROUNDS = 2 * clientNo + (clientNo % 2) -- better use Client1=3, Client2=7

local collectedSamplesNumber = nil
local collectedSamplesArray = nil
local toBeSent = nil

function plugin.processBlock(samples, smax, midiBuf)
    local pluginPosition = plugin.getCurrentPosition()
    local ppq = pluginPosition.ppqPosition
    --
    if not PLAYING and pluginPosition.isPlaying then
        -- switch from not playing to playing 
        PLAYING = true
        connected, error = socket.connect("127.0.0.1",8000)
        if connected == nil then
            print("Error connecting: "..error)
        else
            connected:settimeout(0)
            connected:setoption("tcp-nodelay",true)
        end
    end
    if PLAYING and not pluginPosition.isPlaying then
        -- switch from playing to not playing
        PLAYING = false
        if connected ~= nil then
            connected:close()
            connected = nil
        end
    end
    --
    if (PROCESS_BLOCK_COUNTER % COLLECT_ROUNDS == 0) then
        collectedSamplesNumber = 0
        collectedSamplesArray = {}
        toBeSent = { cNo=clientNo, cPpq=ppq, size=0, smp=nil }
    end
    --
    local dereferencedSamples = samples[0]
    for i = 0,smax do
        collectedSamplesArray[#collectedSamplesArray+1] = dereferencedSamples[i]
    end
    --
    collectedSamplesNumber = collectedSamplesNumber + smax + 1
    --
    if (PROCESS_BLOCK_COUNTER % COLLECT_ROUNDS == (COLLECT_ROUNDS-1)) then
        if PLAYING and connected then
            toBeSent.size = collectedSamplesNumber
            toBeSent.smp  = collectedSamplesArray
            local encoded = base64_encode(mp_encode(toBeSent))
            print("SEND: "..s_len(encoded).."; samples: "..collectedSamplesNumber)
            connected:send(encoded.."\n")
            toBeSent = nil
            collectedSamplesNumber = 0
            collectedSamplesArray = nil
        end
    end
    --
    PROCESS_BLOCK_COUNTER = PROCESS_BLOCK_COUNTER + 1
end