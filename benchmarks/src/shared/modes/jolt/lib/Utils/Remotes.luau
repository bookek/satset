--!strict
--!native
--!optimize 2

const RunService = game:GetService("RunService")
const IS_SERVER = RunService:IsServer()

const Remotes = {}

const RELIABLE_REMOTE_NAME = "Jolt_Reliable"
const UNRELIABLE_REMOTE_NAME = "Jolt_Unreliable"

export type RemoteGroup = {
	Reliable: RemoteEvent,
	Unreliable: UnreliableRemoteEvent,
}

local cachedRemoteGroup: RemoteGroup? = nil

function Remotes.Get(): RemoteGroup
	if cachedRemoteGroup then
		return cachedRemoteGroup
	end

	local reliableEvent = script:FindFirstChild(RELIABLE_REMOTE_NAME) :: RemoteEvent?
	local unreliableEvent = script:FindFirstChild(UNRELIABLE_REMOTE_NAME) :: UnreliableRemoteEvent?

	if reliableEvent and unreliableEvent then
		const group: RemoteGroup = {
			Reliable = reliableEvent,
			Unreliable = unreliableEvent,
		}
		cachedRemoteGroup = group
		return group
	end

	const startTime = os.clock()
	local warned = false

	while not reliableEvent or not unreliableEvent do
		if not reliableEvent then
			reliableEvent = script:WaitForChild(RELIABLE_REMOTE_NAME, 2) :: RemoteEvent?
		end
		if not unreliableEvent then
			unreliableEvent = script:WaitForChild(UNRELIABLE_REMOTE_NAME, 2) :: UnreliableRemoteEvent?
		end

		if reliableEvent and unreliableEvent then
			break
		end

		local elapsed = os.clock() - startTime
		if elapsed >= 5 and not warned then
			warned = true
			warn("[Jolt] Waiting for RemoteEvents under Jolt.Utils.Remotes... Ensure that a server script requires Jolt at game startup.")
		end

		if elapsed >= 30 then
			error(
				"[Jolt] RemoteEvents under Jolt.Utils.Remotes timed out after 30 seconds during client initialization. "
					.. "Ensure that a server script requires Jolt at startup to instantiate the remotes.",
				2
			)
		end
	end

	const group: RemoteGroup = {
		Reliable = reliableEvent :: RemoteEvent,
		Unreliable = unreliableEvent :: UnreliableRemoteEvent,
	}

	cachedRemoteGroup = group
	return group
end

function Remotes.Create(): RemoteGroup
	if cachedRemoteGroup then
		return cachedRemoteGroup
	end

	local reliableEvent = script:FindFirstChild(RELIABLE_REMOTE_NAME) :: RemoteEvent?
	local unreliableEvent = script:FindFirstChild(UNRELIABLE_REMOTE_NAME) :: UnreliableRemoteEvent?

	if not reliableEvent then
		reliableEvent = Instance.new("RemoteEvent")
		reliableEvent.Name = RELIABLE_REMOTE_NAME
		reliableEvent.Parent = script
	end

	if not unreliableEvent then
		unreliableEvent = Instance.new("UnreliableRemoteEvent")
		unreliableEvent.Name = UNRELIABLE_REMOTE_NAME
		unreliableEvent.Parent = script
	end

	const group: RemoteGroup = {
		Reliable = reliableEvent,
		Unreliable = unreliableEvent,
	}

	cachedRemoteGroup = group
	return group
end

if IS_SERVER then
	Remotes.Create()
end

return Remotes
