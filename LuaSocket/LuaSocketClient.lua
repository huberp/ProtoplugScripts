package.cpath = package.cpath .. ";"..protoplug_dir.."/lib/?.dll"

local socket = require("include/socket")
local system = require("include/system")

local connected = socket.connect("127.0.0.1",8000)
connected:setOption("tcp-nodelay",true)

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
local ppq = 3.140982458209348523485
local numPoints = 480

for i = 1,1 do
    local toBeSent = i..";"..ppq..";"..numPoints..";"..result..";\r\n"
    print(toBeSent)
    connected:send(toBeSent)

    system.sleep(2000)

end

connected:close()