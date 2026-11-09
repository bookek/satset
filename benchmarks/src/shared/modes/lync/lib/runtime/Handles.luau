--!strict
--!optimize 2
-- What a handle is bound to, and what it was asked to do before there was anything to bind it to.

local Types = require("../Types")

local Handles = {}

-- Types ---------------------------------------------------------------

-- What a handle knows about where it ended up. The names are written where a namespace is
-- declared and the rest where one starts, so a handle held before either knows only that it is one.
export type Live = {
    space: string?,
    name: string?,
    id: number?,
    def: any,
    session: any,
    isServer: boolean,
    waiting: { (any) -> () },
}

-- An attachment made before there was anything to attach to, ended the same way as one that was.
export type Waiting = {
    connected: boolean,
    held: Types.Connection?,
}

-- Private -------------------------------------------------------------

local Attached = {}
Attached.__index = Attached

function Attached.disconnect(self: Waiting)
    self.connected = false
    local held = self.held
    if held ~= nil then held:disconnect() end
end

-- Public --------------------------------------------------------------

function Handles.live(): Live
    return {
        space = nil,
        name = nil,
        id = nil,
        def = nil,
        session = nil,
        isServer = false,
        waiting = {},
    }
end

-- Something to do to this handle once there is a session to do it with: run now where there is
-- one and held where there is not.
function Handles.waiting(of: Live, run: (any) -> ())
    local session = of.session
    if session ~= nil then
        run(session)
        return
    end
    table.insert(of.waiting, run)
end

-- A listener attached whenever the caller liked, and the connection that ends it either way.
function Handles.later(of: Live, bind: (any) -> Types.Connection): Types.Connection
    local session = of.session
    if session ~= nil then return bind(session) end
    local held: Waiting = setmetatable({ connected = true, held = nil }, Attached) :: any
    table.insert(of.waiting, function(opened: any)
        if not held.connected then return end
        local made = bind(opened)
        held.held = made
        -- A bind that attached nothing hands back a connection already over, and this one follows.
        held.connected = made.connected
    end)
    return (held :: any) :: Types.Connection
end

-- A handle bound to what its namespace compiled it into, then everything it was owed since. The
-- binding is written first, because what waits reaches back through the handle for its id.
function Handles.opened(of: Live, def: any, session: any, isServer: boolean)
    of.id = def.id
    of.def = def
    of.session = session
    of.isServer = isServer
    for _, run in of.waiting do
        run(session)
    end
    table.clear(of.waiting)
end

return table.freeze(Handles)
