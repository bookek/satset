--!strict
--!optimize 2
-- The public binding: every name the surface offers, bound once and frozen.

local Codecs = require("@self/codec")
local Define = require("@self/api/Define")
local Encoding = require("@self/api/Encoding")
local Group = require("@self/channel/Group")
local Lifecycle = require("@self/api/Lifecycle")
local Log = require("@self/kernel/Log")
local Packet = require("@self/api/Packet")
local Query = require("@self/api/Query")
local Recipients = require("@self/channel/Recipients")
local Set = require("@self/api/Set")
local Types = require("@self/Types")

-- Types ---------------------------------------------------------------

-- Infer, Schema and Update are absent because Luau cannot alias a type function. A consumer that
-- needs one requires the Types module beside this one.
export type All = Types.All
export type Cause = Types.Cause
export type Codec<T> = Types.Codec<T>
export type Connection = Types.Connection
export type Except = Types.Except
export type Group = Types.Group
export type LogData = Types.LogData
export type LogKind = Types.LogKind
export type None = Types.None
export type Outcome<R> = Types.Outcome<R>
export type OutcomeCode = Types.OutcomeCode
export type OutcomeData = Types.OutcomeData
export type Packet<T> = Types.Packet<T>
export type Query<Q, R> = Types.Query<Q, R>
export type Recipient = Types.Recipient
export type Set<T> = Types.Set<T>
export type ValidateContext = Types.ValidateContext

-- Public --------------------------------------------------------------

local Lync = {
    define = Define.define,
    start = Lifecycle.start,
    flush = Lifecycle.flush,
    close = Lifecycle.close,

    packet = Packet.new,
    query = Query.new,
    replicate = Set.new,
    group = Group.new,
    encode = Encoding.encode,
    decode = Encoding.decode,

    all = Recipients.ALL,
    except = Recipients.except,
    none = Set.NONE,

    onLog = Log.onLog,
    console = Log.console,

    empty = Codecs.empty,
    bool = Codecs.bool,
    int = Codecs.int,
    quant = Codecs.quant,
    angle = Codecs.angle,
    f32 = Codecs.f32,
    f64 = Codecs.f64,
    vlq = Codecs.vlq,
    vli = Codecs.vli,
    str = Codecs.str,
    buffer = Codecs.buffer,

    struct = Codecs.struct,
    array = Codecs.array,
    map = Codecs.map,
    optional = Codecs.optional,
    tagged = Codecs.tagged,
    enum = Codecs.enum,
    bitfield = Codecs.bitfield,

    vec2 = Codecs.vec2,
    vec3 = Codecs.vec3,
    cframe = Codecs.cframe,
    rotation = Codecs.rotation,
    color3 = Codecs.color3,
    inst = Codecs.inst,
}

return table.freeze(Lync)
