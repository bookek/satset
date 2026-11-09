--!strict

local Config = {
	validate = false,
	stats = false,
	earlyQueue = true,
	promise = nil :: any,
}

function Config.apply(options: { [string]: any }?): ()
	if not options then
		return
	end

	if options.validate ~= nil then
		Config.validate = options.validate == true
	end

	if options.stats ~= nil then
		Config.stats = options.stats == true
	end

	if options.earlyQueue ~= nil then
		Config.earlyQueue = options.earlyQueue == true
	end

	if options.promise ~= nil then
		Config.promise = options.promise
	end
end

return Config
