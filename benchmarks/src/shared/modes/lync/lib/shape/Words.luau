--!strict
--!native
-- The windows a run of bit fields is cut into, where each field sits in them, and how one window's
-- bytes are laid and taken.

local Protocol = require("../wire/Protocol")

local Words = {}

-- Constants -----------------------------------------------------------

local BYTE = Protocol.BYTE_BITS

-- The windows a run is cut into, widest first, in bytes.
local WIDE = 4
local PAIR = 2
local ONE = 1

-- Types ---------------------------------------------------------------

-- A part carries its shift, how far up its field it starts, so the emitter places each piece of
-- a straddling field on its own.
export type Part = {
    read field: number,
    read offset: number,
    read width: number,
    read shift: number,
}

export type Word = {
    read bytes: number,
    read at: number,
    read parts: { Part },
}

-- Private -------------------------------------------------------------

local function total(widths: { number }): number
    local bits = 0
    for _, width in widths do
        bits += width
    end
    return bits
end

local function spent(plan: { Word }): number
    local bytes = 0
    for _, window in plan do
        bytes += window.bytes
    end
    return bytes
end

-- The widest window the bits still to come would fill, counted in whole bytes. Counting bits takes
-- a narrower window than the same bytes would hold, and cuts a field that would have fitted.
local function windowFor(left: number): number
    local whole = (left + BYTE - 1) // BYTE
    if whole >= WIDE then return WIDE end
    return if whole >= PAIR then PAIR else ONE
end

local function part(field: number, offset: number, width: number, shift: number): Part
    return { field = field, offset = offset, width = width, shift = shift }
end

-- A run laid out without cutting a field where a later one would have fitted in its place. A
-- field in one piece is read and written whole, and the bits it leaves behind are what can cost.
local function fitted(widths: { number }): { Word }
    local count = #widths
    local placed = table.create(count, 0)
    local left = total(widths)
    local plan: { Word } = {}
    local at = 0

    while left > 0 do
        local bytes = windowFor(left)
        local room = bytes * BYTE
        local parts: { Part } = {}
        local offset = 0

        -- Whatever still fits whole, in declaration order.
        for index = 1, count do
            local rest = widths[index] - placed[index]
            if rest == 0 or rest > room - offset then continue end
            table.insert(parts, part(index, offset, rest, placed[index]))
            offset += rest
            placed[index] = widths[index]
            left -= rest
        end

        -- Nothing fitting means what is left is wider than the window, so it is cut after all.
        if #parts == 0 then
            for index = 1, count do
                local rest = widths[index] - placed[index]
                if rest == 0 then continue end
                local width = math.min(rest, room)
                table.insert(parts, part(index, 0, width, placed[index]))
                placed[index] += width
                left -= width
                break
            end
        end

        table.insert(plan, { bytes = bytes, at = at, parts = parts })
        at += bytes
    end
    return plan
end

-- Fields laid in declaration order and cut wherever a window ends. A field placed whole, like one
-- of no width, is stepped past at the top of the walk when its remainder reads as nothing.
local function cutting(widths: { number }): { Word }
    local count = #widths
    local left = total(widths)
    local plan: { Word } = {}
    local field, placed, at = 1, 0, 0

    while left > 0 do
        local bytes = windowFor(left)
        local room = bytes * BYTE
        local parts: { Part } = {}
        local offset = 0

        while offset < room and field <= count do
            local rest = widths[field] - placed
            if rest == 0 then
                field, placed = field + 1, 0
                continue
            end
            local width = math.min(rest, room - offset)
            table.insert(parts, part(field, offset, width, placed))
            offset += width
            placed += width
        end

        table.insert(plan, { bytes = bytes, at = at, parts = parts })
        at += bytes
        left -= room
    end
    return plan
end

-- Public --------------------------------------------------------------

-- One window's bytes, laid down and taken back as the one unsigned integer they are.
function Words.put(b: buffer, at: number, bytes: number, acc: number)
    if bytes == ONE then
        buffer.writeu8(b, at, acc)
    elseif bytes == PAIR then
        buffer.writeu16(b, at, acc)
    else
        buffer.writeu32(b, at, acc)
    end
end

function Words.take(b: buffer, at: number, bytes: number): number
    if bytes == ONE then return buffer.readu8(b, at) end
    if bytes == PAIR then return buffer.readu16(b, at) end
    return buffer.readu32(b, at)
end

-- Whichever plan spends fewer bytes, and the one that cuts nothing where they tie. A schema is laid
-- out once and written for as long as it runs.
function Words.plan(widths: { number }): { Word }
    local cut = cutting(widths)
    local whole = fitted(widths)
    return if spent(whole) <= spent(cut) then whole else cut
end

return table.freeze(Words)
