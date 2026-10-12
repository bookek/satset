type Listener = {
	callback: (...any) -> (),
	connected: boolean,
}

type ListenerSet = {
	reliable: { Listener },
	unreliable: { Listener },
}

type ClientState = {
	listeners: ListenerSet,
	connected: boolean,
}

export type Connection = {
	Disconnect: (self: Connection) -> (),
}

export type MockNetwork = {
	server: (self: MockNetwork) -> any,
	addClient: (self: MockNetwork, player: any) -> any,
	removeClient: (self: MockNetwork, player: any) -> (),
	getStats: (self: MockNetwork) -> Stats,
	resetStats: (self: MockNetwork) -> (),
}

export type Stats = {
	targetedSends: number,
	broadcastSends: number,
	clientToServerSends: number,
	bytesSent: number,
}

local function listenersFor(set: ListenerSet, reliable: boolean): { Listener }
	return if reliable then set.reliable else set.unreliable
end

local function connect(listeners: { Listener }, callback: (...any) -> ()): Connection
	local listener: Listener = {
		callback = callback,
		connected = true,
	}
	table.insert(listeners, listener)

	return {
		Disconnect = function(_)
			listener.connected = false
		end,
	}
end

local function emit(listeners: { Listener }, ...: any)
	for _, listener in listeners do
		if listener.connected then
			listener.callback(...)
		end
	end
end

local MockTransport = {}

function MockTransport.new(): MockNetwork
	local serverListeners: ListenerSet = {
		reliable = {},
		unreliable = {},
	}
	local clients: { [any]: ClientState } = {}
	local stats: Stats = {
		targetedSends = 0,
		broadcastSends = 0,
		clientToServerSends = 0,
		bytesSent = 0,
	}

	local network = {} :: MockNetwork

	function network:server()
		return {
			sendToServer = function()
				error("server transport cannot send to server", 2)
			end,
			sendToClient = function(_, reliable, player, payload)
				local client = clients[player]
				assert(client and client.connected, "unknown mock player")
				stats.targetedSends += 1
				stats.bytesSent += buffer.len(payload)
				emit(listenersFor(client.listeners, reliable), payload)
			end,
			sendToAllClients = function(_, reliable, payload)
				stats.broadcastSends += 1
				for _, client in clients do
					stats.bytesSent += buffer.len(payload)
					emit(listenersFor(client.listeners, reliable), payload)
				end
			end,
			onServer = function(_, reliable, callback)
				return connect(listenersFor(serverListeners, reliable), callback)
			end,
			onClient = function()
				error("server transport cannot listen as a client", 2)
			end,
		}
	end

	function network:addClient(player: any)
		assert(clients[player] == nil, "mock player already connected")

		local client: ClientState = {
			listeners = {
				reliable = {},
				unreliable = {},
			},
			connected = true,
		}
		clients[player] = client

		return {
			sendToServer = function(_, reliable, payload)
				assert(client.connected, "mock player is disconnected")
				stats.clientToServerSends += 1
				stats.bytesSent += buffer.len(payload)
				emit(listenersFor(serverListeners, reliable), player, payload)
			end,
			sendToClient = function()
				error("client transport cannot send to a client", 2)
			end,
			sendToAllClients = function()
				error("client transport cannot broadcast", 2)
			end,
			onServer = function()
				error("client transport cannot listen as the server", 2)
			end,
			onClient = function(_, reliable, callback)
				assert(client.connected, "mock player is disconnected")
				return connect(listenersFor(client.listeners, reliable), callback)
			end,
		}
	end

	function network:removeClient(player: any)
		local client = clients[player]
		if client then
			client.connected = false
			clients[player] = nil
		end
	end

	function network:getStats(): Stats
		return {
			targetedSends = stats.targetedSends,
			broadcastSends = stats.broadcastSends,
			clientToServerSends = stats.clientToServerSends,
			bytesSent = stats.bytesSent,
		}
	end

	function network:resetStats()
		stats.targetedSends = 0
		stats.broadcastSends = 0
		stats.clientToServerSends = 0
		stats.bytesSent = 0
	end

	return network
end

return MockTransport
