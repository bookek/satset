--!strict
--!optimize 2
-- Strings and bytes, the two counted kinds, and the alphabet form that packs a string per symbol.

local Base = require("./Base")
local Legality = require("./Legality")
local Log = require("../kernel/Log")
local Types = require("../Types")

local Text = {}

-- A symbol set indexes its own bytes, so a byte appearing twice is two indices decoding to one
-- value. Walked a byte at a time because the set is bytes: a character past ASCII is several.
local function checkSymbols(symbols: string)
    if type(symbols) ~= "string" then
        Log.refuse(`an alphabet takes a symbol set, not a {typeof(symbols)}`)
    end
    if symbols == "" then Log.refuse("an alphabet takes at least one symbol") end

    local seen = {}
    for at = 1, #symbols do
        local byte = string.byte(symbols, at)
        if seen[byte] then
            Log.refuse(`an alphabet takes each symbol once, and {string.char(byte)} is twice`)
        end
        seen[byte] = true
    end
end

local function alphabet(symbols: string, min: number, max: number): Types.Codec<string>
    checkSymbols(symbols)
    Legality.counts("str", min, max)
    return Base.make("str", { symbols = symbols, min = min, max = max })
end

-- The bare form, reached through the metamethod, which hands the table over ahead of the bounds.
local function plain(_: any, min: number, max: number): Types.Codec<string>
    Legality.counts("str", min, max)
    return Base.make("str", { min = min, max = max })
end

-- One name carrying two forms. What tells them apart downstream is whether a symbol set exists.
Text.str = table.freeze(setmetatable({ alphabet = alphabet }, { __call = plain }))

-- Bytes nobody opens, counted the same way and carrying no set to be outside of.
function Text.buffer(min: number, max: number): Types.Codec<buffer>
    Legality.counts("buffer", min, max)
    return Base.make("buffer", { min = min, max = max })
end

return table.freeze(Text)
