-- This file is part of the Satset networking library and is licensed under MIT License; see LICENSE.txt for details
-- Guard runs Satset's server-side token bucket.

local RunService = game:GetService("RunService")

local IS_STUDIO = RunService:IsStudio()
local DEFAULT_MAX_TOKENS = 1000
local DEFAULT_REFILL_RATE = 500
local DEFAULT_STUDIO_BYPASS = true

export type GuardConfig = {
	maxTokens: number?,
	refillRate: number?,
	onFlood: ((player: Player) -> ())?,
	studioBypass: boolean?,
}

type PlayerBucket = {
	tokens: number,
	lastRefill: number,
}

export type Guard = {
	consume: (self: Guard, player: Player) -> boolean,
	removePlayer: (self: Guard, player: Player) -> (),
}

type GuardImpl = Guard & {
	_maxTokens: number,
	_refillRate: number,
	_onFlood: ((player: Player) -> ())?,
	_studioBypass: boolean,
	_buckets: { [Player]: PlayerBucket },
}

local Guard = {}
Guard.__index = Guard

function Guard.new(config: GuardConfig?): Guard
	local cfg: GuardConfig = config or {}
	local maxTokens = cfg.maxTokens or DEFAULT_MAX_TOKENS
	local refillRate = cfg.refillRate or DEFAULT_REFILL_RATE
	local studioBypass = if cfg.studioBypass ~= nil then cfg.studioBypass else DEFAULT_STUDIO_BYPASS

	local self = setmetatable({
		_maxTokens = math.max(maxTokens, 1),
		_refillRate = math.max(refillRate, 1),
		_onFlood = cfg.onFlood,
		_studioBypass = studioBypass,
		_buckets = {} :: { [Player]: PlayerBucket },
	}, Guard)

	return (self :: any) :: Guard
end

local function getBucket(guard: GuardImpl, player: Player): PlayerBucket
	local bucket = guard._buckets[player]
	if not bucket then
		bucket = {
			tokens = guard._maxTokens,
			lastRefill = os.clock(),
		}
		guard._buckets[player] = bucket
	end
	return bucket
end

function Guard:consume(player: Player): boolean
	local guard = (self :: any) :: GuardImpl

	if IS_STUDIO and guard._studioBypass then
		return true
	end

	local bucket = getBucket(guard, player)
	local now = os.clock()
	local elapsed = now - bucket.lastRefill

	bucket.tokens = math.min(guard._maxTokens, bucket.tokens + elapsed * guard._refillRate)
	bucket.lastRefill = now

	if bucket.tokens >= 1 then
		bucket.tokens -= 1
		return true
	end

	if guard._onFlood then
		guard._onFlood(player)
	end

	return false
end

function Guard:removePlayer(player: Player)
	local guard = (self :: any) :: GuardImpl
	guard._buckets[player] = nil
end

return Guard
