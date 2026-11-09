--!strict
--!optimize 2
-- A binary min-heap of number keys with a number value beside each, over parallel arrays.

local Heap = {}
Heap.__index = Heap

-- Types ---------------------------------------------------------------

-- `count` is the truth, not `#keys`. A pop leaves the arrays at the size they reached, so a heap
-- draining at frame rate stops allocating.
export type Heap = typeof(setmetatable(
    {} :: { keys: { number }, values: { number }, count: number },
    {} :: typeof(Heap)
))

-- Public --------------------------------------------------------------

function Heap.new(): Heap
    return setmetatable({ keys = {}, values = {}, count = 0 }, Heap) :: Heap
end

-- Parents move down into the vacated slot, so a climb of n levels costs n moves rather than swaps.
function Heap.push(self: Heap, key: number, value: number)
    local keys, values = self.keys, self.values
    local at = self.count + 1
    self.count = at

    while at > 1 do
        local parent = at // 2
        if keys[parent] <= key then break end
        keys[at], values[at] = keys[parent], values[parent]
        at = parent
    end
    keys[at], values[at] = key, value
end

function Heap.peek(self: Heap): (number?, number?)
    if self.count == 0 then return nil, nil end
    return self.keys[1], self.values[1]
end

function Heap.pop(self: Heap): (number?, number?)
    local count = self.count
    if count == 0 then return nil, nil end

    local keys, values = self.keys, self.values
    local key, value = keys[1], values[1]
    local size = count - 1
    self.count = size
    if size == 0 then return key, value end

    local moved, movedValue = keys[count], values[count]
    local at = 1
    local half = size // 2
    while at <= half do
        local child = at * 2
        if child < size and keys[child + 1] < keys[child] then
            child += 1
        end
        if keys[child] >= moved then break end
        keys[at], values[at] = keys[child], values[child]
        at = child
    end
    keys[at], values[at] = moved, movedValue
    return key, value
end

-- Emptied, keeping the arrays at the size they reached.
function Heap.clear(self: Heap)
    self.count = 0
end

return table.freeze(Heap)
