--!strict

local Stats = require(script.Parent.Parent.Diagnostics.Stats)

type Bucket = {
	tokens: number,
	updatedAt: number,
}

export type PacketPolicy = {
	rate: number?,
	burst: number?,
	validate: ((Player?, any) -> boolean)?,
	onViolation: string,
	buckets: { [Player]: Bucket },
}

local Policy = {}
local RATE_ERROR = '[VNet]: packet policy rate must be a positive number or "10/s".'

local function parseRate(value: any): number?
	if value == nil then
		return nil
	end

	if typeof(value) == "number" then
		if value <= 0 then
			error("[VNet]: packet policy rate must be greater than 0.", 4)
		end

		return value
	end

	if typeof(value) ~= "string" then
		error(RATE_ERROR, 4)
	end

	local amountText, unitText = string.match(value, "^%s*(%d+%.?%d*)%s*/%s*([%a]*)%s*$")
	local amount = if amountText then tonumber(amountText) else nil

	if not amount or amount <= 0 then
		error(RATE_ERROR, 4)
	end

	local unit = string.lower(unitText or "s")

	if unit == "" or unit == "s" or unit == "sec" or unit == "second" then
		return amount
	end

	if unit == "m" or unit == "min" or unit == "minute" then
		return amount / 60
	end

	if unit == "h" or unit == "hr" or unit == "hour" then
		return amount / 3600
	end

	error("[VNet]: packet policy rate unit must be s, m, or h.", 4)
end

local function policyConfig(config: { [any]: any }): { [any]: any }?
	local policy = config.policy

	if policy ~= nil then
		if typeof(policy) ~= "table" then
			error("[VNet]: packet policy must be a table.", 4)
		end

		return policy
	end

	if
		config.rate ~= nil
		or config.burst ~= nil
		or config.onViolation ~= nil
		or typeof(config.validate) == "function"
	then
		return config
	end

	return nil
end

function Policy.fromConfig(config: { [any]: any }): PacketPolicy?
	local policy = policyConfig(config)

	if not policy then
		return nil
	end

	local rate = parseRate(policy.rate)
	local burst = policy.burst

	if burst ~= nil then
		if typeof(burst) ~= "number" or burst <= 0 then
			error("[VNet]: packet policy burst must be greater than 0.", 4)
		end
	elseif rate ~= nil then
		burst = math.max(1, rate)
	end

	local validator = policy.validator

	if validator == nil and typeof(policy.validate) == "function" then
		validator = policy.validate
	end

	if validator ~= nil and typeof(validator) ~= "function" then
		error("[VNet]: packet policy validate must be a function.", 4)
	end

	local onViolation = policy.onViolation or "drop"

	if typeof(onViolation) ~= "string" then
		error("[VNet]: packet policy onViolation must be a string.", 4)
	end

	return {
		rate = rate,
		burst = burst,
		validate = validator,
		onViolation = string.lower(onViolation),
		buckets = setmetatable({}, {
			__mode = "k",
		}) :: any,
	}
end

local function drop(
	policy: PacketPolicy,
	packetName: string,
	sender: Player?,
	reason: string
): boolean
	Stats.bump("droppedPackets")

	if policy.onViolation == "warn" then
		Stats.warn(`[VNet]: Dropped "{packetName}": {reason}.`)
	elseif policy.onViolation == "kick" and sender then
		sender:Kick(`[VNet]: {packetName} rejected: {reason}`)
	elseif policy.onViolation == "error" then
		error(`[VNet]: Packet "{packetName}" rejected: {reason}.`, 3)
	end

	return false
end

local function consumeRate(policy: PacketPolicy, packetName: string, sender: Player?): boolean
	local rate = policy.rate

	if not rate or not sender then
		return true
	end

	local burst = policy.burst or rate
	local now = os.clock()
	local bucket = policy.buckets[sender]

	if not bucket then
		bucket = {
			tokens = burst,
			updatedAt = now,
		}
		policy.buckets[sender] = bucket
	else
		local elapsed = math.max(0, now - bucket.updatedAt)
		bucket.updatedAt = now
		bucket.tokens = math.min(burst, bucket.tokens + elapsed * rate)
	end

	if bucket.tokens < 1 then
		return drop(policy, packetName, sender, "rate limit")
	end

	bucket.tokens -= 1
	return true
end

function Policy.accept(
	policy: PacketPolicy?,
	packetName: string,
	sender: Player?,
	payload: any
): boolean
	if not policy then
		return true
	end

	if not consumeRate(policy, packetName, sender) then
		return false
	end

	local validator = policy.validate

	if not validator then
		return true
	end

	local ok, allowed = pcall(validator, sender, payload)

	if not ok then
		return drop(policy, packetName, sender, "validator error")
	end

	if allowed ~= true then
		return drop(policy, packetName, sender, "validator returned false")
	end

	return true
end

return table.freeze(Policy)
