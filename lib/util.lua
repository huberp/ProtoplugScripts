-- Util module for ProtoplugScripts
-- Collection of utility functions
local util = {}

-- https://stackoverflow.com/questions/12394841/safely-remove-items-from-an-array-table-while-iterating
-- Remove items from an array table based on a keep function
-- @param t the table to remove from
-- @param fnKeep function(t,i) returning true if t[i] is to be kept
-- @param fnRemove function(t,i) called when t[i] is to be removed (optional)
function util.array_remove(t, fnKeep, fnRemove)
    local j, n = 1, #t;
	if fnRemove == nil then
		fnRemove = function() end
    end
    for i=1,n do
        if (fnKeep(t, i)) then
            -- Move i's kept value to j's position, if it's not already there.
            if (i ~= j) then
                t[j] = t[i];
                t[i] = nil;
            end
            j = j + 1; -- Increment position of where we'll place the next kept value.
        else
			fnRemove(t, i);
            t[i] = nil;
        end
    end
    return t;
end

-- Get size of a hashtable (not an array)
function util.sizeOf(hashMap)
    local size = 0
    for _ in pairs(hashMap) do 
        size = size + 1 
    end
    return size
end

-- Add more utility functions here as needed

return util