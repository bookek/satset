--!strict
--!optimize 2
-- The bit width of a span: how many bits address every value from zero to span.

local Bits = {}

-- A logarithm rounds short from 2^50 up, and a width one short encodes cleanly and decodes as a
-- different value, so the exponent is read off the float instead.
function Bits.width(span: number): number
    if span <= 0 then return 0 end
    return (select(2, math.frexp(span)))
end

return table.freeze(Bits)
