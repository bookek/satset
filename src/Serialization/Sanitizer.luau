--!native
--!optimize 2
-- This file is part of the Satset networking library and is licensed under MIT License; see LICENSE.txt for details
-- Sanitizer holds byte bounds and float poison checks.

local Sanitizer = {}

function Sanitizer.sanitizeFloat(value: number): number
	-- NaN check, plus Infinity for physics safety
	if value ~= value or value == math.huge or value == -math.huge then
		return 0
	end

	return value
end

function Sanitizer.checkBounds(b: buffer, cursor: number, readSize: number): boolean
	return cursor >= 0 and (cursor + readSize) <= buffer.len(b)
end

return Sanitizer
