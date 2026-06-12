-- Mode loader. Each mode wraps a networking library with a common interface.
-- Disabled modes are skipped (set to true to disable).
local BenchmarkConfig = require(script.Parent.BenchmarkConfig)

local DISABLED_MODES = {}

local function isSelected(name: string): boolean
	local selectedTools = BenchmarkConfig.selectedTools
	return not selectedTools or selectedTools[name] == true
end

local Modes = {}
for _, Mode in script:GetChildren() do
	if Mode == script then
		continue
	end
	if DISABLED_MODES[Mode.Name] or not Mode:IsA("ModuleScript") or not isSelected(Mode.Name) then
		continue
	end
	Modes[Mode.Name] = require(Mode)
end

return Modes
