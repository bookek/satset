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
	local ok, events = pcall(require, Mode)
	if not ok then
		-- A vendor fail mounts its own failure only; other modes keep the run alive.
		warn(`[modes] {Mode.Name} failed to load: {events}`)
		continue
	end
	Modes[Mode.Name] = events
end

return Modes
