--!strict
--!optimize 2
-- A refusal a writer or reader raised, as the line a caller reads, its interned numbers turned
-- back into the words they stand for.

local Log = require("./Log")

-- The two tables a rejection's numbers are read back through.
type Names = {
    read paths: { read texts: { string } },
    read expected: { read texts: { string } },
}

return function(thrown: unknown, names: Names): string
    if typeof(thrown) ~= "table" then return tostring(thrown) end
    local rejection = thrown :: any
    if rejection.code == nil then return tostring(thrown) end
    local facts = table.clone(rejection.facts)
    if typeof(facts.pathId) == "number" then facts.path = names.paths.texts[facts.pathId] end
    if typeof(facts.expectId) == "number" then
        facts.expected = names.expected.texts[facts.expectId]
    end
    return Log.format(rejection.code, facts)
end
