require "include/protoplug"
--Welcome to Lua Protoplug effect (version 1.4.0)

package.path  = (package.path..";"..protoplug_dir.."\\include\\extra\\?.lua"
   ..";"..protoplug_dir.."\\include\\extra\\luapower\\?.lua"
   ..";"..protoplug_dir.."\\include\\extra\\glfw\\?.lua"
   ..";"..protoplug_dir.."\\include\\extra\\imgui\\?.lua")
print("PATH:  "..package.path)
package.cpath = package.cpath .. ";"..protoplug_dir.."/lib/?.dll"
print("CPATH: "..package.cpath)

local lanes = require "include/lanes".configure()
local thread = require'thread'
local pthread = require'pthread'
local luastate = require'luastate'
local time = require'time'
local glue = require'glue'
local status, tds = pcall(require, 'tds')
--
glfw = ffi.load(protoplug_dir.."/lib/glfw3.dll")
local lj_glfw = require "glfw"
local gllib = require"gl"

cimgui = ffi.load(protoplug_dir.."\\lib\\cimgui_glfw.dll")

local t1 = lanes.gen("*",
function(protoplug_dir)

	package.path  = (package.path..";"..protoplug_dir.."\\include\\extra\\?.lua"
	   ..";"..protoplug_dir.."\\include\\extra\\luapower\\?.lua"
	   ..";"..protoplug_dir.."\\include\\extra\\glfw\\?.lua"
	   ..";"..protoplug_dir.."\\include\\extra\\imgui\\?.lua")

	local igwin = require"imgui.window"
	--local win = igwin:SDL(800,400, "widgets")
	local win = igwin:GLFW(800,400, "widgets")


	local ffi = require"ffi"
	local val = ffi.new("float[1]")
	local padval = ffi.new("float[2]")
	local curve = win.ig.Curve("mycurve",12,100)
	local Quat = ffi.new("quat",{1,0,0,0}) 
	local v3 = ffi.new("G3Dvec3",{1,0,0})
	local mat4 = win.ig.mat4_cast(Quat)

	function win:draw(ig)

		if ig.Begin("widgets",nil, ig.lib.ImGuiWindowFlags_AlwaysAutoResize) then
			if ig.TreeNode"dial" then
				ig.dial("turns",val,nil,0.5/math.pi)
				ig.SameLine()
				ig.dial("radians",val)
				ig.TreePop();
				ig.Separator();
			end
			if ig.TreeNode"pad" then
				ig.pad("mypad", padval)
				ig.InputFloat2("vals",padval)
				ig.TreePop();
				ig.Separator();
			end
			if ig.TreeNode"curve" then
				if curve:draw(ig.ImVec2(400,300)) then
				--do something with curve.LUT array of 100 floats
				end
				ig.InputFloat2("first two",curve.LUT, nil, ig.lib.ImGuiInputTextFlags_ReadOnly)
				ig.TreePop();
				ig.Separator();
			end
			if ig.TreeNode"gizmoquat" then

				if ig.gizmo3D("###guizmo0",v3,Quat,150) then 
					mat4 = ig.mat4_pos_cast(Quat,v3)
				end
				
				ig.SameLine()
				ig.BeginGroup()
				ig.InputFloat4("##1",mat4.f, nil, ig.lib.ImGuiInputTextFlags_ReadOnly)
				ig.InputFloat4("##2",mat4.f+4, nil, ig.lib.ImGuiInputTextFlags_ReadOnly)
				ig.InputFloat4("##3",mat4.f+8, nil, ig.lib.ImGuiInputTextFlags_ReadOnly)
				ig.InputFloat4("##4",mat4.f+12, nil, ig.lib.ImGuiInputTextFlags_ReadOnly)
				ig.EndGroup()
				ig.imguiGizmo_setDirectionColor(ig.ImVec4(1,0,0,1))
				ig.gizmo3D("guizmo3",v3,150)
				ig.imguiGizmo_restoreDirectionColor()
				ig.InputFloat3("dir",ffi.new("float[3]",{v3.x,v3.y,v3.z}), nil, ig.lib.ImGuiInputTextFlags_ReadOnly)
				ig.TreePop();
				ig.Separator();
			end
		end
		ig.End()
	end
	win:start()

end)(protoplug_dir)

v, err = t1:join()   -- no propagation
if v == nil then
	error( "'a' faced error"..tostring(err))   -- manual propagation
else
	print("\nV: "..v)
end

	
local lps=0
function plugin.processBlock (samples, smax) -- let's ignore midi for this example
     if lps % 100 == 0 then
		print("MAIN LOOP "..lps)
	 end
	 lps=lps+1
end