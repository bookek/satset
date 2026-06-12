-- Payload variants: static (identical) and moving (per-frame + per-slot).

local PayloadVariants = {}

export type Variant = "static" | "moving"

local VALID_VARIANTS = {
	static = true,
	moving = true,
}

local function byteOne(value: number): number
	return (value % 255) + 1
end

local function makeVector(base: Vector3, frame: number, index: number): Vector3
	local t = frame * 0.125
	return Vector3.new(base.X + math.sin(t + index) * 6, base.Y + (frame % 16) * 0.25, base.Z + math.cos(t + index) * 6)
end

local function makeVectors(base: { Vector3 }, frame: number, slot: number): { Vector3 }
	local out = table.create(#base)
	for index, value in base do
		out[index] = makeVector(value, frame, index + slot * 7)
	end
	return out
end

local function makeBooleans(base: { boolean }, frame: number, slot: number): { boolean }
	local out = table.create(#base)
	for index, value in base do
		out[index] = if (index + frame + slot) % 29 == 0 then not value else value
	end
	return out
end

local function makeEntities(base: { { [string]: number } }, frame: number, slot: number): { { [string]: number } }
	local out = table.create(#base)
	for index, entity in base do
		out[index] = {
			id = entity.id,
			x = byteOne(entity.x + frame + index + slot * 3),
			y = byteOne(entity.y + frame // 2 + index + slot * 5),
			z = byteOne(entity.z + frame // 3 + index + slot * 7),
			orientation = byteOne(entity.orientation + frame + slot),
			animation = byteOne(entity.animation + (frame // 4) + slot * 2),
		}
	end
	return out
end

local function makeString(prefix: string, frame: number, index: number): string
	return string.format("%s_%03d", string.sub(prefix, 1, 20), (frame + index) % 1000)
end

local function makeStrings(base: { string }, frame: number, slot: number): { string }
	local out = table.create(#base)
	for index, value in base do
		out[index] = makeString(value, frame, index + slot * 11)
	end
	return out
end

local function makeMixed(base: { [string]: any }, frame: number, slot: number): { [string]: any }
	return {
		id = base.id,
		health = math.max(0, math.min(100, base.health + ((frame + slot) % 9) - 4)),
		position = makeVector(base.position, frame, 1 + slot * 3),
		velocity = makeVector(base.velocity, frame, 2 + slot * 3),
		name = base.name,
		isRunning = (frame + slot) % 20 < 10,
		animation = byteOne(base.animation + frame // 3 + slot),
		team = base.team,
	}
end

function PayloadVariants.resolve(value: string?): Variant
	if value and VALID_VARIANTS[value] then
		return value :: Variant
	end

	return "static"
end

function PayloadVariants.make(bench: string, base: any, frame: number, variant: string?, slot: number?): any
	local resolved = PayloadVariants.resolve(variant)
	if resolved == "static" then
		return base
	end

	local s = slot or 0

	if bench == "SingleValue" then
		return byteOne(base + frame + s)
	elseif bench == "Vectors" then
		return makeVectors(base, frame, s)
	elseif bench == "Booleans" then
		return makeBooleans(base, frame, s)
	elseif bench == "Entities" then
		return makeEntities(base, frame, s)
	elseif bench == "Strings" then
		return makeStrings(base, frame, s)
	elseif bench == "Mixed" then
		return makeMixed(base, frame, s)
	end

	return base
end

return PayloadVariants
