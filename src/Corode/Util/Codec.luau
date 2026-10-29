--!strict
--[[
	Codec
	Turns values into bytes and back, for K.Net packets. Each type writes a
	value, reads it back, and checks it before it's sent.

		local Hit = K.Net.Packet("Hit", {
			Position = K.Net.Vector3,
			Damage = K.Net.U16,
			Critical = K.Net.Bool,
		})

	Numbers: U8, U16, U32 (whole numbers from 0), I8, I16, I32 (whole numbers),
	F32 (about 7 digits) and F64 or Number (any number).
	Others: Bool, String (up to 1000 bytes, or String(max)), Primitive (a number,
	text or true/false), Vector3,
	Vector2, CFrame, Color3, Instance (or Instance("BasePart")), Enum({ "A", "B" }),
	Optional(type), Array(type, max?), Map(key, value, max?), and a table of
	fields like the one above (tables inside it work too).

	Reading never trusts the bytes: lengths, counts and positions are checked,
	text must be valid UTF-8 and numbers finite, so a broken or forged packet
	fails to read instead of reaching your code.
]]

export type Writer = { Buffer: buffer, Cursor: number, Instances: { Instance } }
export type Reader = { Buffer: buffer, Cursor: number, Length: number, Instances: { any } }

export type Type = {
	-- Describes the type; both sides compare these to find packets that don't match.
	Name: string,
	Write: (Writer, any) -> (),
	Read: (Reader) -> any,
	-- Returns false and why when a value can't be written as this type.
	Check: (any) -> (boolean, string?),
}

local Errors = require(script.Parent.Errors)

local DEFAULT_MAX_TEXT = 1000
local DEFAULT_MAX_ITEMS = 1000
local MAX_U16 = 65535

local Codec = {}

------------------------------------------------------------------------------
-- Writing and reading bytes
------------------------------------------------------------------------------

function Codec.writer(size: number?): Writer
	return { Buffer = buffer.create(size or 64), Cursor = 0, Instances = {} }
end

function Codec.reader(data: buffer, start: number?, length: number?, instances: { any }?): Reader
	local first = start or 0
	return { Buffer = data, Cursor = first, Length = first + (length or (buffer.len(data) - first)), Instances = instances or {} }
end

-- Makes room for `bytes` more, growing the buffer when it's full.
local function reserve(writer: Writer, bytes: number)
	local size = buffer.len(writer.Buffer)
	local needed = writer.Cursor + bytes
	if needed > size then
		local grown = buffer.create(math.max(size * 2, needed))
		buffer.copy(grown, 0, writer.Buffer, 0, writer.Cursor)
		writer.Buffer = grown
	end
end

-- Moves past `bytes` and returns where they start, or fails when they aren't there.
local function take(reader: Reader, bytes: number): number
	local at = reader.Cursor
	if at + bytes > reader.Length then
		error("ran past the end", 0)
	end
	reader.Cursor = at + bytes
	return at
end

-- Whole numbers from 0 to 2^32 - 1 in 1 to 5 bytes; small numbers take one.
function Codec.writeVarint(writer: Writer, value: number)
	reserve(writer, 5)
	repeat
		local byte = value % 128
		value = value // 128
		buffer.writeu8(writer.Buffer, writer.Cursor, if value > 0 then byte + 128 else byte)
		writer.Cursor += 1
	until value == 0
end

function Codec.readVarint(reader: Reader): number
	local value, scale = 0, 1
	for _ = 1, 5 do
		local byte = buffer.readu8(reader.Buffer, take(reader, 1))
		value += (byte % 128) * scale
		if byte < 128 then
			return value
		end
		scale *= 128
	end
	error("a length is too long", 0)
end

-- Appends the bytes another writer wrote.
function Codec.append(writer: Writer, from: Writer)
	reserve(writer, from.Cursor)
	buffer.copy(writer.Buffer, writer.Cursor, from.Buffer, 0, from.Cursor)
	writer.Cursor += from.Cursor
end

-- The bytes written so far, as a buffer of exactly that size.
function Codec.finish(writer: Writer): buffer
	local result = buffer.create(writer.Cursor)
	buffer.copy(result, 0, writer.Buffer, 0, writer.Cursor)
	return result
end

------------------------------------------------------------------------------
-- Building types
------------------------------------------------------------------------------

local function isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function describe(value: any): string
	local kind = typeof(value)
	if kind == "string" then
		return `the text "{if #value > 30 then string.sub(value, 1, 30) .. "..." else value}"`
	elseif kind == "number" or kind == "boolean" then
		return `{kind} {tostring(value)}`
	end
	return kind
end

local function newType(name: string, write: (Writer, any) -> (), read: (Reader) -> any, check: (any) -> (boolean, string?)): Type
	return table.freeze({ Name = name, Write = write, Read = read, Check = check })
end

local function integer(
	name: string,
	bytes: number,
	min: number,
	max: number,
	writeAt: (buffer, number, number) -> (),
	readAt: (buffer, number) -> number
): Type
	return newType(name, function(writer, value)
		reserve(writer, bytes)
		writeAt(writer.Buffer, writer.Cursor, value)
		writer.Cursor += bytes
	end, function(reader)
		return readAt(reader.Buffer, take(reader, bytes))
	end, function(value)
		if type(value) ~= "number" or value % 1 ~= 0 or value < min or value > max then
			return false, `expected a whole number from {min} to {max}, but got {describe(value)}`
		end
		return true, nil
	end)
end

local function float(name: string, bytes: number, writeAt: (buffer, number, number) -> (), readAt: (buffer, number) -> number): Type
	return newType(name, function(writer, value)
		reserve(writer, bytes)
		writeAt(writer.Buffer, writer.Cursor, value)
		writer.Cursor += bytes
	end, function(reader)
		local value = readAt(reader.Buffer, take(reader, bytes))
		if not isFinite(value) then
			error("a number isn't finite", 0)
		end
		return value
	end, function(value)
		if not isFinite(value) then
			return false, `expected a number, but got {describe(value)}`
		end
		return true, nil
	end)
end

Codec.U8 = integer("U8", 1, 0, 255, buffer.writeu8, buffer.readu8)
Codec.U16 = integer("U16", 2, 0, MAX_U16, buffer.writeu16, buffer.readu16)
Codec.U32 = integer("U32", 4, 0, 4294967295, buffer.writeu32, buffer.readu32)
Codec.I8 = integer("I8", 1, -128, 127, buffer.writei8, buffer.readi8)
Codec.I16 = integer("I16", 2, -32768, 32767, buffer.writei16, buffer.readi16)
Codec.I32 = integer("I32", 4, -2147483648, 2147483647, buffer.writei32, buffer.readi32)
Codec.F32 = float("F32", 4, buffer.writef32, buffer.readf32)
Codec.F64 = float("F64", 8, buffer.writef64, buffer.readf64)
Codec.Number = Codec.F64

Codec.Bool = newType("Bool", function(writer, value)
	reserve(writer, 1)
	buffer.writeu8(writer.Buffer, writer.Cursor, if value then 1 else 0)
	writer.Cursor += 1
end, function(reader)
	local byte = buffer.readu8(reader.Buffer, take(reader, 1))
	if byte > 1 then
		error("a true/false isn't 0 or 1", 0)
	end
	return byte == 1
end, function(value)
	if type(value) ~= "boolean" then
		return false, `expected true or false, but got {describe(value)}`
	end
	return true, nil
end)

-- Text up to `max` bytes (1000 by default, at most 65535).
local function text(max: number): Type
	if type(max) ~= "number" or max % 1 ~= 0 or max < 1 or max > MAX_U16 then
		Errors.raise(`K.Net.String expected a length from 1 to {MAX_U16}, but got {describe(max)}.`)
	end
	return newType(`String({max})`, function(writer, value)
		local length = #value
		reserve(writer, 2 + length)
		buffer.writeu16(writer.Buffer, writer.Cursor, length)
		buffer.writestring(writer.Buffer, writer.Cursor + 2, value)
		writer.Cursor += 2 + length
	end, function(reader)
		local length = buffer.readu16(reader.Buffer, take(reader, 2))
		if length > max then
			error("a text is too long", 0)
		end
		local value = buffer.readstring(reader.Buffer, take(reader, length), length)
		if utf8.len(value) == nil then
			error("a text isn't valid UTF-8", 0)
		end
		return value
	end, function(value)
		if type(value) ~= "string" then
			return false, `expected text, but got {describe(value)}`
		elseif #value > max then
			return false, `expected text of at most {max} bytes, but got {#value}`
		elseif utf8.len(value) == nil then
			return false, "expected valid UTF-8 text"
		end
		return true, nil
	end)
end

local function vector(name: string, components: number, make: (...number) -> any, parts: (any) -> ...number, kind: string): Type
	local bytes = components * 4
	return newType(name, function(writer, value)
		reserve(writer, bytes)
		local values = { parts(value) }
		for index = 1, components do
			buffer.writef32(writer.Buffer, writer.Cursor + (index - 1) * 4, values[index])
		end
		writer.Cursor += bytes
	end, function(reader)
		local at = take(reader, bytes)
		local values = table.create(components)
		for index = 1, components do
			local component = buffer.readf32(reader.Buffer, at + (index - 1) * 4)
			if not isFinite(component) then
				error("a number isn't finite", 0)
			end
			values[index] = component
		end
		return make(table.unpack(values))
	end, function(value)
		if typeof(value) ~= kind then
			return false, `expected a {kind}, but got {describe(value)}`
		end
		for _, component in { parts(value) } do
			if not isFinite(component) then
				return false, `expected a {kind} of finite numbers`
			end
		end
		return true, nil
	end)
end

Codec.Vector3 = vector("Vector3", 3, Vector3.new, function(value)
	return value.X, value.Y, value.Z
end, "Vector3")

Codec.Vector2 = vector("Vector2", 2, Vector2.new, function(value)
	return value.X, value.Y
end, "Vector2")

-- Position plus the rotation as an axis scaled by its angle: 24 bytes.
Codec.CFrame = vector("CFrame", 6, function(x, y, z, rx, ry, rz)
	local position = CFrame.new(x, y, z)
	local rotation = Vector3.new(rx, ry, rz)
	local angle = rotation.Magnitude
	return if angle < 1e-6 then position else position * CFrame.fromAxisAngle(rotation / angle, angle)
end, function(value)
	local axis, angle = value:ToAxisAngle()
	local rotation = axis * angle
	return value.X, value.Y, value.Z, rotation.X, rotation.Y, rotation.Z
end, "CFrame")

Codec.Color3 = newType("Color3", function(writer, value)
	reserve(writer, 3)
	buffer.writeu8(writer.Buffer, writer.Cursor, math.clamp(math.round(value.R * 255), 0, 255))
	buffer.writeu8(writer.Buffer, writer.Cursor + 1, math.clamp(math.round(value.G * 255), 0, 255))
	buffer.writeu8(writer.Buffer, writer.Cursor + 2, math.clamp(math.round(value.B * 255), 0, 255))
	writer.Cursor += 3
end, function(reader)
	local at = take(reader, 3)
	return Color3.fromRGB(buffer.readu8(reader.Buffer, at), buffer.readu8(reader.Buffer, at + 1), buffer.readu8(reader.Buffer, at + 2))
end, function(value)
	if typeof(value) ~= "Color3" then
		return false, `expected a Color3, but got {describe(value)}`
	end
	return true, nil
end)

-- An Instance, sent next to the bytes. It must exist on the other side when the
-- packet arrives, or the packet fails to read; use Optional for ones that may not.
local function instance(className: string?): Type
	return newType(if className then `Instance({className})` else "Instance", function(writer, value)
		table.insert(writer.Instances, value)
		reserve(writer, 2)
		buffer.writeu16(writer.Buffer, writer.Cursor, #writer.Instances)
		writer.Cursor += 2
	end, function(reader)
		local index = buffer.readu16(reader.Buffer, take(reader, 2))
		local value = reader.Instances[index]
		if typeof(value) ~= "Instance" then
			error("an object is missing", 0)
		elseif className and not (value :: Instance):IsA(className) then
			error(`an object isn't a {className}`, 0)
		end
		return value
	end, function(value)
		if typeof(value) ~= "Instance" then
			return false, `expected an object, but got {describe(value)}`
		elseif className and not (value :: Instance):IsA(className) then
			return false, `expected a {className}, but got a {(value :: Instance).ClassName}`
		end
		return true, nil
	end)
end

-- Both K.Net.String and K.Net.String(50) work, and the same for Instance.
local function callable(default: Type, make: (any) -> Type): any
	return setmetatable(table.clone(default :: any), {
		__call = function(_, argument)
			return make(argument)
		end,
	})
end

-- Typed any: the old type solver can't call a table that is also a type.
Codec.String = callable(text(DEFAULT_MAX_TEXT), text) :: any
local LONG_TEXT = text(MAX_U16)
Codec.Instance = callable(instance(nil), instance) :: any

-- A number, text or true/false; one byte says which.
Codec.Primitive = newType("Primitive", function(writer, value)
	local kind = type(value)
	reserve(writer, 1)
	buffer.writeu8(writer.Buffer, writer.Cursor, if kind == "boolean" then (if value then 1 else 0) elseif kind == "number" then 2 else 3)
	writer.Cursor += 1
	if kind == "number" then
		Codec.F64.Write(writer, value)
	elseif kind == "string" then
		LONG_TEXT.Write(writer, value)
	end
end, function(reader)
	local tag = buffer.readu8(reader.Buffer, take(reader, 1))
	if tag <= 1 then
		return tag == 1
	elseif tag == 2 then
		return Codec.F64.Read(reader)
	elseif tag == 3 then
		return LONG_TEXT.Read(reader)
	end
	error("a value has an unknown kind", 0)
end, function(value)
	local kind = type(value)
	if kind == "boolean" then
		return true, nil
	elseif kind == "number" then
		return Codec.F64.Check(value)
	elseif kind == "string" then
		return LONG_TEXT.Check(value)
	end
	return false, `expected a number, text or true/false, but got {describe(value)}`
end)

-- One of a fixed list of texts, sent as its position in the list (1 byte).
function Codec.Enum(values: { string }): Type
	if type(values) ~= "table" or #values == 0 or #values > 255 then
		Errors.raise("K.Net.Enum expected a list of 1 to 255 texts.")
	end
	local positions: { [string]: number } = {}
	for index, value in values do
		if type(value) ~= "string" or positions[value] then
			Errors.raise(`K.Net.Enum: item {index} must be text that isn't in the list twice.`)
		end
		positions[value] = index
	end
	local list = table.clone(values)
	return newType(`Enum({table.concat(list, ",")})`, function(writer, value)
		reserve(writer, 1)
		buffer.writeu8(writer.Buffer, writer.Cursor, positions[value])
		writer.Cursor += 1
	end, function(reader)
		local value = list[buffer.readu8(reader.Buffer, take(reader, 1))]
		if value == nil then
			error("an Enum value isn't in the list", 0)
		end
		return value
	end, function(value)
		if type(value) ~= "string" or positions[value] == nil then
			return false, `expected one of {table.concat(list, ", ")}, but got {describe(value)}`
		end
		return true, nil
	end)
end

-- Turns a table of fields into a type; other values must already be types.
local compile: (any, string) -> Type

function Codec.Optional(inner: any): Type
	local kind = compile(inner, "K.Net.Optional")
	return newType(`Optional({kind.Name})`, function(writer, value)
		reserve(writer, 1)
		buffer.writeu8(writer.Buffer, writer.Cursor, if value == nil then 0 else 1)
		writer.Cursor += 1
		if value ~= nil then
			kind.Write(writer, value)
		end
	end, function(reader)
		local present = buffer.readu8(reader.Buffer, take(reader, 1))
		if present > 1 then
			error("an Optional flag isn't 0 or 1", 0)
		end
		return if present == 1 then kind.Read(reader) else nil
	end, function(value)
		if value == nil then
			return true, nil
		end
		return kind.Check(value)
	end)
end

local function checkMax(max: any, functionName: string): number
	local limit = if max == nil then DEFAULT_MAX_ITEMS else max
	if type(limit) ~= "number" or limit % 1 ~= 0 or limit < 1 or limit > MAX_U16 then
		Errors.raise(`{functionName} expected a maximum from 1 to {MAX_U16}, but got {describe(limit)}.`)
	end
	return limit
end

-- A list of up to `max` values (1000 by default).
function Codec.Array(item: any, max: number?): Type
	local kind = compile(item, "K.Net.Array")
	local limit = checkMax(max, "K.Net.Array")
	return newType(`Array({kind.Name},{limit})`, function(writer, value)
		reserve(writer, 2)
		buffer.writeu16(writer.Buffer, writer.Cursor, #value)
		writer.Cursor += 2
		for _, child in value do
			kind.Write(writer, child)
		end
	end, function(reader)
		local count = buffer.readu16(reader.Buffer, take(reader, 2))
		if count > limit then
			error("a list is too long", 0)
		end
		local list = table.create(count)
		for index = 1, count do
			list[index] = kind.Read(reader)
		end
		return list
	end, function(value)
		if type(value) ~= "table" then
			return false, `expected a list, but got {describe(value)}`
		end
		local count = #value
		if count > limit then
			return false, `expected at most {limit} items, but got {count}`
		end
		for key, child in value do
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > count then
				return false, "expected a list without gaps or other keys"
			end
			local ok, reason = kind.Check(child)
			if not ok then
				return false, `item {key}: {reason}`
			end
		end
		return true, nil
	end)
end

-- A table of up to `max` key-value pairs (1000 by default).
function Codec.Map(key: any, value: any, max: number?): Type
	local keyKind = compile(key, "K.Net.Map")
	local valueKind = compile(value, "K.Net.Map")
	local limit = checkMax(max, "K.Net.Map")
	return newType(`Map({keyKind.Name},{valueKind.Name},{limit})`, function(writer, map)
		local count = 0
		for _ in map do
			count += 1
		end
		reserve(writer, 2)
		buffer.writeu16(writer.Buffer, writer.Cursor, count)
		writer.Cursor += 2
		for mapKey, mapValue in map do
			keyKind.Write(writer, mapKey)
			valueKind.Write(writer, mapValue)
		end
	end, function(reader)
		local count = buffer.readu16(reader.Buffer, take(reader, 2))
		if count > limit then
			error("a table has too many entries", 0)
		end
		local map = {}
		for _ = 1, count do
			local mapKey = keyKind.Read(reader)
			map[mapKey] = valueKind.Read(reader)
		end
		return map
	end, function(map)
		if type(map) ~= "table" then
			return false, `expected a table, but got {describe(map)}`
		end
		local count = 0
		for mapKey, mapValue in map do
			count += 1
			local ok, reason = keyKind.Check(mapKey)
			if ok then
				ok, reason = valueKind.Check(mapValue)
			end
			if not ok then
				return false, `entry {tostring(mapKey)}: {reason}`
			end
		end
		if count > limit then
			return false, `expected at most {limit} entries, but got {count}`
		end
		return true, nil
	end)
end

local function isType(value: any): boolean
	return type(value) == "table" and type(value.Write) == "function" and type(value.Read) == "function"
end

-- A table of named fields, written in name order so both sides agree.
local function fields(schema: { [any]: any }, functionName: string): Type
	local names: { string } = {}
	local kinds: { [string]: Type } = {}
	for name, kind in schema do
		if type(name) ~= "string" then
			Errors.raise(`{functionName}: field names must be text, but found {describe(name)}.`)
		end
		kinds[name] = compile(kind, functionName)
		table.insert(names, name)
	end
	table.sort(names)
	local parts = {}
	for _, name in names do
		table.insert(parts, `{name}:{kinds[name].Name}`)
	end
	return newType(`\{{table.concat(parts, ",")}\}`, function(writer, value)
		for _, name in names do
			kinds[name].Write(writer, value[name])
		end
	end, function(reader)
		local value = {}
		for _, name in names do
			value[name] = kinds[name].Read(reader)
		end
		return value
	end, function(value)
		if type(value) ~= "table" then
			return false, `expected a table, but got {describe(value)}`
		end
		for key in value do
			if kinds[key] == nil then
				return false, `{tostring(key)} isn't one of its fields ({table.concat(names, ", ")})`
			end
		end
		for _, name in names do
			local ok, reason = kinds[name].Check(value[name])
			if not ok then
				return false, `{name}: {reason}`
			end
		end
		return true, nil
	end)
end

function compile(schema: any, functionName: string): Type
	if isType(schema) then
		return schema
	elseif type(schema) == "table" then
		return fields(schema, functionName)
	end
	Errors.raise(`{functionName} expected a K.Net type (like K.Net.U8) or a table of them, but got {describe(schema)}.`)
	return nil :: any
end

-- A type from a K.Net type or a table of fields.
function Codec.compile(schema: any, functionName: string): Type
	return compile(schema, functionName)
end

return table.freeze(Codec)
