--!strict
--!optimize 2
-- The orientation mappings: a direction folded onto a square, and a turn as the three components
-- it keeps.

local Grid = require("./Grid")
local Protocol = require("../wire/Protocol")

local Rotation = {}

-- Constants -----------------------------------------------------------

local AT_X = Protocol.QUAT_X
local AT_Y = Protocol.QUAT_Y
local AT_Z = Protocol.QUAT_Z
local AT_W = Protocol.QUAT_W

-- How near two of the four have to be before the first of them wins, how much better one spelling
-- has to score before it is taken as better, and how near a component sits to a point to be one.
local LEVEL = 1e-9
local TIGHTER = 1 - 1e-9
local NEARLY = 1e-9

-- How near two quaternions have to be, by their dot product, to be one spelling of one rotation
-- rather than two: a part in 2^43, far under any grid step and far over a last bit of noise.
local SAME = 1e-13

-- Types ---------------------------------------------------------------

-- The pair of points a value lies between. Both grids a precision lays down are stepped, since
-- neither starts at zero, so each answers that itself.
type Window = (value: any) -> (number?, number, number, number)

-- A direction either way. `plane` answers the two grid indices the wire carries, nil for a reading
-- that is no direction. `sphere` takes them back to a unit vector.
export type Octahedral = {
    read plane: (x: number, y: number, z: number) -> (number?, number?),
    read sphere: (u: number, v: number) -> (number, number, number),
}

-- A turn either way. The platform builds a CFrame from four numbers and hands none back, so the way
-- in is off the rotation matrix and the way out is the four the constructor takes.
export type Smallest = {
    read parts: (
        _x: number,
        _y: number,
        _z: number,
        r00: number,
        r01: number,
        r02: number,
        r10: number,
        r11: number,
        r12: number,
        r20: number,
        r21: number,
        r22: number
    ) -> (number, number?, number?, number?),
    read whole: (
        largest: number,
        a: number,
        b: number,
        c: number
    ) -> (number, number, number, number),
}

-- Private -------------------------------------------------------------

-- Zero counts as positive, so a component exactly on an axis folds the same way on both machines.
local function sign(value: number): number
    return if value >= 0 then 1 else -1
end

-- The fold across the square's diagonals, which is its own inverse.
local function folded(u: number, v: number): (number, number)
    return (1 - math.abs(v)) * sign(u), (1 - math.abs(u)) * sign(v)
end

-- The one of the two names a point on the square's outer edge has.
local function only(span: number, atU: number, atV: number): (number, number)
    local edgeU = atU == 0 or atU == span
    local edgeV = atV == 0 or atV == span
    if edgeU and span - atV > atV then atV = span - atV end
    if edgeV and span - atU > atU then atU = span - atU end
    return atU, atV
end

local function normalized(
    x: number,
    y: number,
    z: number,
    w: number
): (number, number, number, number)
    local length = math.sqrt(x * x + y * y + z * z + w * w)
    return x / length, y / length, z / length, w / length
end

-- The three a tag sends and the one it leaves behind, from whichever of q and -q has the named
-- component positive, since both spell one rotation. A named component that is nothing settles
-- no sign, so the first kept component that is something decides instead, and a rotation two
-- machines decode to the same points is spelled with the same signs by both.
local function apart(
    tag: number,
    x: number,
    y: number,
    z: number,
    w: number
): (number, number, number, number)
    local a, b, c, named
    if tag == AT_X then
        a, b, c, named = y, z, w, x
    elseif tag == AT_Y then
        a, b, c, named = x, z, w, y
    elseif tag == AT_Z then
        a, b, c, named = x, y, w, z
    else
        a, b, c, named = x, y, z, w
    end
    local lead = named
    if math.abs(lead) <= NEARLY then
        lead = if math.abs(a) > NEARLY then a elseif math.abs(b) > NEARLY then b else c
    end
    if lead < 0 then return -a, -b, -c, -named end
    return a, b, c, named
end

-- The three that travelled and the one rebuilt, back in component order.
local function laid(
    largest: number,
    a: number,
    b: number,
    c: number,
    d: number
): (number, number, number, number)
    if largest == AT_X then return d, a, b, c end
    if largest == AT_Y then return a, d, b, c end
    if largest == AT_Z then return a, b, d, c end
    return a, b, c, d
end

-- Public --------------------------------------------------------------

-- The octahedral mapping over one grid, which is `vec3.unit`.
function Rotation.octahedral(of: Grid.Grid): Octahedral
    local span, fromIndex, window = of.span, of.fromIndex, of.window :: Window

    local function sphere(u: number, v: number): (number, number, number)
        local x, y = fromIndex(u), fromIndex(v)
        local z = 1 - math.abs(x) - math.abs(y)
        if z < 0 then
            x, y = folded(x, y)
        end
        local length = math.sqrt(x * x + y * y + z * z)
        return x / length, y / length, z / length
    end

    -- The pair whose direction is nearest rather than the pair nearest the projection, since the
    -- projection is no isometry. A corner is scored by how far along the vector it points.
    local function plane(x: number, y: number, z: number): (number?, number?)
        local reach = math.abs(x) + math.abs(y) + math.abs(z)
        local u, v = x / reach, y / reach
        if z < 0 then
            u, v = folded(u, v)
        end

        local u0, u1 = window(u)
        local v0, v1 = window(v)
        if u0 == nil or v0 == nil then return nil, nil end

        local best, atU, atV = -math.huge, u0, v0
        for _, tryU in { u0, u1 } do
            for _, tryV in { v0, v1 } do
                local ax, ay, az = sphere(tryU, tryV)
                local along = ax * x + ay * y + az * z
                if along > best then
                    best, atU, atV = along, tryU, tryV
                end
            end
        end
        return only(span, atU, atV)
    end

    return table.freeze({ plane = plane, sphere = sphere })
end

-- The smallest-three mapping over one grid, which is `rotation.quat`.
function Rotation.smallest(of: Grid.Grid): Smallest
    local fromIndex, toIndex, window = of.fromIndex, of.toIndex, of.window :: Window

    -- The dropped component is whatever is left of a unit quaternion, so three that overrun leave
    -- nothing rather than a root of a negative, and three zeros leave the fourth at one.
    local function whole(
        largest: number,
        a: number,
        b: number,
        c: number
    ): (number, number, number, number)
        local ka, kb, kc = fromIndex(a), fromIndex(b), fromIndex(c)
        local kd = math.sqrt(math.max(0, 1 - ka * ka - kb * kb - kc * kc))
        return normalized(laid(largest, ka, kb, kc, kd))
    end

    -- The quaternion off the matrix, from whichever of the four branches is best conditioned. The
    -- first of two level ones wins, since a strict comparison would let a last bit take turns.
    local function extracted(
        r00: number,
        r01: number,
        r02: number,
        r10: number,
        r11: number,
        r12: number,
        r20: number,
        r21: number,
        r22: number
    ): (number, number, number, number, number)
        local trace = r00 + r11 + r22
        local top = math.max(trace, r00, r11, r22) - LEVEL

        local largest, a, b, c, d
        if trace >= top then
            local s = math.sqrt(trace + 1) * 2
            largest, d = AT_W, 0.25 * s
            a, b, c = (r21 - r12) / s, (r02 - r20) / s, (r10 - r01) / s
        elseif r00 >= top then
            local s = math.sqrt(1 + r00 - r11 - r22) * 2
            largest, d = AT_X, 0.25 * s
            a, b, c = (r01 + r10) / s, (r02 + r20) / s, (r21 - r12) / s
        elseif r11 >= top then
            local s = math.sqrt(1 + r11 - r00 - r22) * 2
            largest, d = AT_Y, 0.25 * s
            a, b, c = (r01 + r10) / s, (r12 + r21) / s, (r02 - r20) / s
        else
            local s = math.sqrt(1 + r22 - r00 - r11) * 2
            largest, d = AT_Z, 0.25 * s
            a, b, c = (r02 + r20) / s, (r12 + r21) / s, (r10 - r01) / s
        end

        -- A matrix carried in float32 spells a quaternion a last bit off one.
        local x, y, z, w = normalized(laid(largest, a, b, c, d))
        return largest, x, y, z, w
    end

    -- The lowest tag that spells this rotation, decided on the decoded grid triple alone: each
    -- tag's indices are rebuilt into a quaternion and held to the one decoded by rotation rather
    -- than by any float exactness, so a component that is exactly nothing, which two tags can
    -- spell, is spelled the same by whichever machine writes it.
    local function canonical(
        took: number,
        x: number,
        y: number,
        z: number,
        w: number
    ): (number, number?, number?, number?)
        for tag = AT_X, AT_W do
            local pa, pb, pc = apart(tag, x, y, z, w)
            local ia, ib, ic = toIndex(pa), toIndex(pb), toIndex(pc)
            if ia == nil or ib == nil or ic == nil then continue end

            local ka, kb, kc = fromIndex(ia), fromIndex(ib), fromIndex(ic)
            local over = ka * ka + kb * kb + kc * kc
            if over > 1 + NEARLY then continue end

            local kd = math.sqrt(math.max(0, 1 - over))
            local rx, ry, rz, rw = normalized(laid(tag, ka, kb, kc, kd))
            if math.abs(rx * x + ry * y + rz * z + rw * w) >= 1 - SAME then
                return tag, ia, ib, ic
            end
        end
        return took, nil, nil, nil
    end

    -- The three indices whose quaternion is nearest. The rebuilt component moves with the other
    -- three, so the triple nearest component by component is not the nearest rotation, and one of
    -- the cell's eight corners under one of the four tags always is.
    local function searched(
        r00: number,
        r01: number,
        r02: number,
        r10: number,
        r11: number,
        r12: number,
        r20: number,
        r21: number,
        r22: number
    ): (number, number?, number?, number?)
        local largest, x, y, z, w = extracted(r00, r01, r02, r10, r11, r12, r20, r21, r22)

        -- The named component is the largest and travels under every other tag, so one asking
        -- answers whether the grid holds it for all three.
        local most = if largest == AT_X
            then x
            elseif largest == AT_Y then y
            elseif largest == AT_Z then z
            else w
        local reached = window(most) ~= nil

        local best, took, atA, atB, atC = math.huge, largest, nil, nil, nil
        for tag = AT_X, AT_W do
            if not reached and tag ~= largest then continue end
            local pa, pb, pc, pd = apart(tag, x, y, z, w)

            local a0, a1, ka0, ka1 = window(pa)
            if a0 == nil then continue end
            local b0, b1, kb0, kb1 = window(pb)
            if b0 == nil then continue end
            local c0, c1, kc0, kc1 = window(pc)
            if c0 == nil then continue end

            for stepA = 0, 1 do
                local tryA = if stepA == 0 then a0 else a1
                local ka = if stepA == 0 then ka0 else ka1
                local gapA = (ka - pa) ^ 2
                for stepB = 0, 1 do
                    local tryB = if stepB == 0 then b0 else b1
                    local kb = if stepB == 0 then kb0 else kb1
                    local gapB = gapA + (kb - pb) ^ 2
                    for stepC = 0, 1 do
                        local tryC = if stepC == 0 then c0 else c1
                        local kc = if stepC == 0 then kc0 else kc1

                        -- A triple that overruns the unit quaternion spells nothing, and three gaps
                        -- already past the best stay past it whatever the root adds.
                        local over = ka * ka + kb * kb + kc * kc
                        if over > 1 then continue end
                        local part = gapB + (kc - pc) ^ 2
                        if part >= best * TIGHTER then continue end

                        local kd = math.sqrt(math.max(0, 1 - over))
                        local away = part + (kd - pd) ^ 2
                        if away < best * TIGHTER then
                            best, took, atA, atB, atC = away, tag, tryA, tryB, tryC
                        end
                    end
                end
            end
        end

        if atA == nil or atB == nil or atC == nil then return largest, nil, nil, nil end
        local heldA, heldB, heldC = atA :: number, atB :: number, atC :: number

        local lower, ia, ib, ic = canonical(took, whole(took, heldA, heldB, heldC))
        if ia ~= nil then return lower, ia, ib, ic end
        return took, heldA, heldB, heldC
    end

    -- The last matrix asked about and its answer. A sender standing still hands the same rotation
    -- frame after frame, and nine comparisons buy skipping the whole search.
    local warm = false
    local w00, w01, w02, w10, w11, w12, w20, w21, w22 = 0, 0, 0, 0, 0, 0, 0, 0, 0
    local gotTag, gotA, gotB, gotC = 0, nil :: number?, nil :: number?, nil :: number?

    local function parts(
        _x: number,
        _y: number,
        _z: number,
        r00: number,
        r01: number,
        r02: number,
        r10: number,
        r11: number,
        r12: number,
        r20: number,
        r21: number,
        r22: number
    ): (number, number?, number?, number?)
        if
            warm
            and r00 == w00
            and r01 == w01
            and r02 == w02
            and r10 == w10
            and r11 == w11
            and r12 == w12
            and r20 == w20
            and r21 == w21
            and r22 == w22
        then
            return gotTag, gotA, gotB, gotC
        end

        local tag, ia, ib, ic = searched(r00, r01, r02, r10, r11, r12, r20, r21, r22)
        w00, w01, w02 = r00, r01, r02
        w10, w11, w12 = r10, r11, r12
        w20, w21, w22 = r20, r21, r22
        gotTag, gotA, gotB, gotC = tag, ia, ib, ic
        warm = true
        return tag, ia, ib, ic
    end

    return table.freeze({ parts = parts, whole = whole })
end

return table.freeze(Rotation)
