--!strict
--!optimize 2
-- The three remote instances, and the only module that touches them.

local Transport = {}
Transport.__index = Transport

-- Constants -----------------------------------------------------------

-- The folder every namespace's remotes sit under. Named apart from the library module, which the
-- project mounts as ReplicatedStorage.Lync, since a lookup by name cannot tell the two apart.
local FOLDER = "LyncRemotes"
local CHANNELS: { Channel } = { "handshake", "reliable", "unreliable" }
local LOSSY: Channel = "unreliable"

-- Types ---------------------------------------------------------------

export type Channel = "handshake" | "reliable" | "unreliable"

-- Which machine this is, taken rather than read, since one place reads the engine for both ends.
export type Side = "server" | "client"

export type Sidecar = { { Instance } }

export type Received = (from: Player?, bytes: buffer, refs: Sidecar?) -> ()

export type Transport = {
    read open: (self: Transport) -> (),
    read fire: (self: Transport, at: Channel, to: Player?, bytes: buffer, refs: Sidecar?) -> (),
    read onReceive: (self: Transport, at: Channel, take: Received) -> (),
    read close: (self: Transport) -> (),
}

-- The unreliable lane is an UnreliableRemoteEvent held as a RemoteEvent, since the two classes
-- declare the same fire methods and signals.
type Self = {
    namespace: string,
    isServer: boolean,
    remotes: { [Channel]: RemoteEvent },
    heard: { RBXScriptConnection },
}

-- Private -------------------------------------------------------------

-- The one folder every namespace sits under, made by the first to open and found by the rest.
local function rooted(storage: Instance): Instance
    local found = storage:FindFirstChild(FOLDER)
    if found ~= nil then return found end
    local made = Instance.new("Folder")
    made.Name = FOLDER
    made.Parent = storage
    return made
end

-- Public --------------------------------------------------------------

Transport.FOLDER = FOLDER

function Transport.new(namespace: string, side: Side): Transport
    local self: Self = {
        namespace = namespace,
        isServer = side == "server",
        remotes = {},
        heard = {},
    }
    return (setmetatable(self, Transport) :: any) :: Transport
end

-- A client waits without a deadline: a namespace slow to replicate is a slow join, and a deadline
-- would make it a failure with nothing to recover to.
function Transport.open(self: Self)
    local storage = game:GetService("ReplicatedStorage")
    if not self.isServer then
        local folder = storage:WaitForChild(FOLDER):WaitForChild(self.namespace)
        for _, at in CHANNELS do
            self.remotes[at] = folder:WaitForChild(at) :: RemoteEvent
        end
        return
    end

    local folder = Instance.new("Folder")
    folder.Name = self.namespace
    for _, at in CHANNELS do
        local remote: RemoteEvent = if at == LOSSY
            then Instance.new("UnreliableRemoteEvent") :: any
            else Instance.new("RemoteEvent")
        remote.Name = at
        remote.Parent = folder
        self.remotes[at] = remote
    end
    folder.Parent = rooted(storage)
end

-- A client names nobody and reaches the server. A server naming nobody reaches everyone.
function Transport.fire(self: Self, at: Channel, to: Player?, bytes: buffer, refs: Sidecar?)
    local remote = self.remotes[at]
    if not self.isServer then return remote:FireServer(bytes, refs) end
    if to ~= nil then return remote:FireClient(to, bytes, refs) end
    remote:FireAllClients(bytes, refs)
end

-- A server receiver is the engine's own, since the player it names is the authenticated sender.
function Transport.onReceive(self: Self, at: Channel, take: Received)
    local remote = self.remotes[at]
    if self.isServer then
        table.insert(self.heard, remote.OnServerEvent:Connect(take))
        return
    end
    local function relay(bytes: buffer, refs: Sidecar?)
        take(nil, bytes, refs)
    end
    table.insert(self.heard, remote.OnClientEvent:Connect(relay))
end

-- Released rather than destroyed, since destroying the remotes would take the namespace out from
-- under a counterparty still running on it.
function Transport.close(self: Self)
    for _, made in self.heard do
        made:Disconnect()
    end
    table.clear(self.heard)
end

return table.freeze(Transport)
