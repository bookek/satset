local Enums = require(script.Parent.Enums)
local Parser = require(script.Parent.Parser)

local dataTypes = {
	NumberU4 = Enums.NumberU4,
	NumberU8 = Enums.NumberU8,	
	NumberU16 = Enums.NumberU16,
	NumberU32 = Enums.NumberU32,
	NumberI8 = Enums.NumberI8,
	NumberI16 = Enums.NumberI16,
	NumberI32 = Enums.NumberI32,
	NumberF16 = Enums.NumberF16,
	NumberF32 = Enums.NumberF32,
	NumberF64 = Enums.NumberF64,
	
	--cframes
	CFrameFX8 = Enums.CFrameFX8 :: CFrame,
	CFrameI16FX16 = Enums.CFrameI16FX16 :: CFrame,
	CFrameFX16 = Enums.CFrameFX16 :: CFrame,
	CFrameF16 = Enums.CFrameF16 :: CFrame,
	CFrameF32Aligned = Enums.CFrameF32Aligned :: CFrame,
	CFrameF32FX16 = Enums.CFrameF32FX16 :: CFrame,
	CFrameF32 = Enums.CFrameF32 :: CFrame,
	
	--vector3
	Vector3FX8 = Enums.Vector3FX8 :: Vector3,
	Vector3I16 = Enums.Vector3I16 :: Vector3,
	Vector3FX16 = Enums.Vector3FX16 :: Vector3,
	Vector3F16 = Enums.Vector3F16 :: Vector3,
	Vector3F32 = Enums.Vector3F32 :: Vector3,
	
	--vector2
	Vector2FX8 = Enums.Vector2FX8 :: Vector2,
	Vector2I16 = Enums.Vector2I16 :: Vector2,
	Vector2FX16 = Enums.Vector2FX16 :: Vector2,
	Vector2F16 = Enums.Vector2F16 :: Vector2,
	Vector2F32 = Enums.Vector2F32 :: Vector2,
	
	--misc
	String = Enums.String :: string,
	StringLong = Enums.StringLong :: string,
	Color3 = Enums.Color3 :: Color3,
	BrickColor = Enums.BrickColor :: BrickColor,
	Boolean = Enums.Boolean :: boolean,
	Nil = Enums.Nil :: any,
	Buffer = Enums.Buffer :: buffer,
	EnumItem = Enums.EnumItem :: EnumItem,
	Instance = Enums.Instance :: Instance,
	Player = Enums.Player :: Player,
	DateTime32 = Enums.DateTime32 :: DateTime,
	DateTime64 = Enums.DateTime64 :: DateTime,
	TweenInfo = Enums.TweenInfo :: TweenInfo,
	ColorSequence = Enums.ColorSequence :: ColorSequence,
	NumberSequence = Enums.NumberSequence :: NumberSequence,
	NumberRange = Enums.NumberRange :: NumberRange,
	UDim = Enums.UDim :: UDim,
	UDim2 = Enums.UDim2 :: UDim2,
	Region3 = Enums.Region3 :: Region3,
	PhysicalProperties = Enums.PhysicalProperties :: PhysicalProperties,
	Rect = Enums.Rect :: Rect,
	
	--custom
	Any = Enums.Any :: any,
	optional = Parser.optional,
	union = Parser.union,
	unionMany = Parser.unionMany,
	literal = Parser.literal,
}

return dataTypes
