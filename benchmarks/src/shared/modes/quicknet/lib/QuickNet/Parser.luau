local Enums = require(script.Parent.Enums)
local EnumsToNative = require(script.Parent.EnumsToNativeTypes)
local Types = require(script.Parent.Types)

local SOURCE = "[QuickNet]"

local function keyValueSwap(tbl: {[any]: any}): {[any]: any}
	local new = {}
	for k, v in tbl do
		new[v] = k
	end
	return new
end

local reverseEnums = keyValueSwap(Enums)

local fastPaths = {
	Array = {
		[Enums.NumberU4] = Enums.FastNumberU4Array,
		[Enums.NumberU8] = Enums.FastNumberU8Array,
		[Enums.NumberI32] = Enums.FastNumberI32Array,
		[Enums.NumberF32] = Enums.FastNumberF32Array,
		[Enums.Boolean] = Enums.FastBoolArray,
		[Enums.String] = Enums.FastStringArray,
	},

	DictStatic = {
		[Enums.NumberU4] = Enums.FastNumberU8DictStatic,
		[Enums.NumberU8] = Enums.FastNumberU8DictStatic,
		[Enums.NumberI32] = Enums.FastNumberI32DictStatic,
		[Enums.NumberF32] = Enums.FastNumberF32DictStatic,
		[Enums.Boolean] = Enums.FastBoolDictStatic,
		[Enums.String] = Enums.FastStringDictStatic,
	},

	Dict = {
		[Enums.NumberU4] = Enums.FastNumberU8Dict,
		[Enums.NumberU8] = Enums.FastNumberU8Dict,
		[Enums.NumberI32] = Enums.FastNumberI32Dict,
		[Enums.NumberF32] = Enums.FastNumberF32Dict,
		[Enums.Boolean] = Enums.FastBoolDict,
		[Enums.String] = Enums.FastStringDict,
	}
}

local function checkSameTypes(data: {any}): (boolean, number)
	local sameValTypes = true
	local prevVal = data[1]

	for _, val in data do
		if val ~= prevVal then
			sameValTypes = false
			break
		end
		prevVal = val
	end
	return sameValTypes, prevVal
end

--Indexes
--1: Type
--2: Data
--3: FastPath
local function arrayStatic(data: {any}): {any}
	local sameTypes, dataType = checkSameTypes(data)

	local schema = {
		Enums.ArrayStatic, 
		data,
		sameTypes and fastPaths.Array[dataType] or nil
	}
	return schema
end

local function array<T>(data: {T}): {T}
	local dataType = data[1]
	local schema = {
		Enums.Array, 
		dataType,
		fastPaths.Array[dataType],
	}
	return schema
end

local function arrayDynamic(): {any}
	local schema = {
		Enums.ArrayDynamic,
	}
	return schema
end

local dictId = 1

local function getDictId(): number
	local id = dictId
	dictId += 1
	return id
end

--1: Type
--2: Data
--3: KeysMap
--4: Template
--5: FastPath
local function dictStatic(data: {[string | number]: any}): {[string | number]: any}
	local keys = {}
	for key, val in data do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		local aType = type(a)
		local bType = type(b)

		if aType ~= bType then
			return aType < bType
		end
		return a < b
	end)

	local vals = {}
	local template = {}
	for idx, key in keys do		
		vals[idx] = data[key]
		template[key] = 123
	end	
	local sameTypes, dataType = checkSameTypes(vals)

	local schema = {
		Enums.DictStatic,
		vals,
		keys,
		template,
		sameTypes and fastPaths.DictStatic[dataType] or nil,
	}
	return schema
end

--1: Type
--2: KeyData
--3: ValueData
--4: KeyFastPath
--5: ValueFastPath
local function dict<K, V>(data: {[K]: V}): {[K]: V}
	local keyData, valData = next(data)
	local keyFastPath = fastPaths.Dict[keyData]
	local valFastPath = fastPaths.Dict[valData]

	local schema = {
		[1] = Enums.Dict,
		[2] = keyData,
		[3] = valData,
		[4] = keyFastPath,
		[5] = valFastPath,
		[6] = getDictId(),
	}
	return schema
end

local function dictDynamic(): {[any]: any}
	local schema = {
		Enums.DictDynamic,
	}
	return schema
end

local function optional<T>(dataType: T): T?
	return {
		Enums.Optional,
		dataType,
	}
end

local function parseUnion(data: any, union: {any})
	local isTable = type(data) == "table"

	if isTable then
		local enum = data[1]
		if enum == Enums.Optional then
			error(SOURCE.." optional type cannot be unioned", 2)
			return
				
		elseif enum == Enums.Any then
			error(SOURCE.." Any type cannot be unioned", 2)
			return
				
		elseif enum == Enums.Literal then
			error(SOURCE.." literal types cannot be unioned", 2)
			return
		end
		union["table"] = data
	else
		local native = EnumsToNative[data]
		if not native then
			error(SOURCE.." invalid union type", 2)
			return
		end
		if union[native] ~= nil then
			error(SOURCE.. " cannot union multiple types of the same native type", 2)
			return
		end
		union[native] = data
	end
end

local function union<T1, T2>(data1: T1, data2: T2): T1 | T2
	local union = {}
	parseUnion(data1, union)
	parseUnion(data2, union)
	union[1] = Enums.Union
	return union
end

local function unionMany<T...>(...: T...): any
	local union = {}
	for _, data in {...} do
		parseUnion(data, union)
	end
	union[1] = Enums.Union
	return union
end

local function literal<T...>(...: T...): Types.Literal
	local map = {...}
	for _, val in map do
		local dt = typeof(val)
		if dt ~= "string" and dt ~= "number" and dt ~= "boolean" and dt ~= "Vector3" then
			error(SOURCE.." unsupported literal type: "..dt, 2)
			return
		end
	end
	local reverseMap = keyValueSwap(map)
	local literal = {
		Enums.Literal,
		map,
		reverseMap,
	}
	return literal
end

local function processSchema(schema: {[any]: any})
	if type(schema) ~= "table" then
		if not reverseEnums[schema] then
			error(SOURCE.." invalid data type", 2)
		end
		return schema
	end
	
	local dt = schema[1]	
	local isLiteral = dt == Enums.Literal
	if isLiteral then return schema end
	
	local isOptional = dt == Enums.Optional
	if isOptional then
		schema[2] = processSchema(schema[2])
		return schema
	end
	
	local isUnion = dt == Enums.Union
	if isUnion then
		local reverseMap = {}
		for k, val in schema do
			if type(k) ~= "string" then
				continue
			end			
			local processed = processSchema(val)
			schema[k] = processed
			
			local enum
			if type(processed) == "table" then
				enum = processed[1]
			else
				enum = processed
			end			
			reverseMap[enum] = processed
		end
		
		for enum, processed in reverseMap do
			schema[enum] = processed
		end
		return schema
	end

	local newSchema
	local isArrayStatic = true
	local count = 0
	for i, arg in schema do
		count += 1
		if i ~= count then
			isArrayStatic = false
		end
	end

	local k, v = next(schema)
	local isArray = count == 1 and k == 1
	local isDict = not isArray and count == 1
	local isDictStatic = not isArrayStatic and count > 1

	if isArray then
		newSchema = array(schema)
		local data = newSchema[2]
		if data == Enums.Any then
			newSchema = arrayDynamic()
		else
			newSchema[2] = processSchema(data)
		end

	elseif isArrayStatic then
		newSchema = arrayStatic(schema)
		local data = newSchema[2]
		local newData = {}
		for i, val in data do
			newData[i] = processSchema(val)
		end
		newSchema[2] = newData

	elseif isDict then
		newSchema = dict(schema)
		local key = newSchema[2]
		local val = newSchema[3]
		if key == Enums.Any and val == Enums.Any then
			newSchema = dictDynamic()
		else
			newSchema[2] = processSchema(key)
			newSchema[3] = processSchema(val)
		end

	elseif isDictStatic then
		newSchema = dictStatic(schema)
		local vals = newSchema[2]
		for i, val in vals do
			vals[i] = processSchema(val)
		end

	else
		error(SOURCE.. " invalid schema", 2)
	end
	return newSchema
end

local function getSchema(...)
	local args = {...}
	for i, arg in args do
		args[i] = processSchema(arg)
	end
	return args
end

local Parser = {
	getSchema = getSchema,
	optional = optional,
	union = union,
	unionMany = unionMany,
	literal = literal,
}

return Parser
