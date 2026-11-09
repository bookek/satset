--!strict
--!optimize 2

--[=[
	Result: frozen success or error values that middleware passes along

	Return type: SUCCESS, FAILURE, Unpack, Success and Error
	Example usage:
		local Ok, Value = Result.Unpack(Result.Success(5))
--]=]

local Types = require("./Types")
type Result<T, E> = Types.Result<T, E>

local function MakeSuccess<T>(Value: T): Result<T, any>
	local Res: Result<T, unknown> = { Result = "Success", Value = Value }
	return table.freeze(Res)
end

local function MakeError<T>(Reason: T): Result<any, T>
	local Res: Result<T, unknown> = { Result = "Error", Reason = Reason }
	return table.freeze(Res)
end

local function UnpackResult(Result: Result<any, any>): (boolean, any)
	if Result.Result == "Success" then
		return true, Result.Value
	else
		return false, Result.Reason
	end
end

return table.freeze({
	SUCCESS = MakeSuccess(nil),
	FAILURE = MakeError(nil),

	Unpack = UnpackResult,
	Success = MakeSuccess,
	Error = MakeError,
})
