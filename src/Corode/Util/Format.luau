--[[
	Format
	Turns numbers into text for the screen.

		K.Format.Short(1234567)   --> "1.2M"
		K.Format.Comma(1234567)   --> "1,234,567"
		K.Format.Time(75)         --> "01:15"
]]

local Errors = require(script.Parent.Errors)

local Format = {}

local SUFFIXES = { "", "K", "M", "B", "T", "Qa", "Qi", "Sx", "Sp", "Oc", "No", "Dc" }

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function trimZeros(text: string): string
	if string.find(text, ".", 1, true) then
		text = string.gsub(text, "0+$", "")
		text = string.gsub(text, "%.$", "")
	end
	return text
end

-- 950 --> "950", 1234 --> "1.2K", 5600000 --> "5.6M"
function Format.Short(value: number, decimals: number?): string
	Errors.expect(value, "number", "the number", "K.Format.Short")
	if not isFinite(value) then
		return tostring(value)
	end
	local places = decimals or 1
	local pattern = `%.{places}f`
	local sign = if value < 0 then "-" else ""
	local absolute = math.abs(value)
	if absolute < 1000 then
		return sign .. trimZeros(string.format(pattern, absolute))
	end
	local index = math.min(math.floor(math.log10(absolute) / 3), #SUFFIXES - 1)
	local text = string.format(pattern, absolute / 10 ^ (index * 3))
	-- 999,950 rounds to "1000.0K"; move up to "1M" instead.
	if (tonumber(text) :: number) >= 1000 and index < #SUFFIXES - 1 then
		index += 1
		text = string.format(pattern, absolute / 10 ^ (index * 3))
	end
	return sign .. trimZeros(text) .. SUFFIXES[index + 1]
end

-- 1234567 --> "1,234,567"
function Format.Comma(value: number): string
	Errors.expect(value, "number", "the number", "K.Format.Comma")
	if not isFinite(value) then
		return tostring(value)
	end
	local sign = if value < 0 then "-" else ""
	local digits = string.format("%.0f", math.floor(math.abs(value)))
	local grouped = string.reverse((string.gsub(string.reverse(digits), "(%d%d%d)", "%1,")))
	if string.sub(grouped, 1, 1) == "," then
		grouped = string.sub(grouped, 2)
	end
	return sign .. grouped
end

-- 75 --> "01:15", 3725 --> "1:02:05"
function Format.Time(seconds: number): string
	Errors.expect(seconds, "number", "the seconds", "K.Format.Time")
	local total = if isFinite(seconds) then math.max(0, math.floor(seconds)) else 0
	local hours = total // 3600
	local minutes = (total % 3600) // 60
	local secs = total % 60
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, secs)
	end
	return string.format("%02d:%02d", minutes, secs)
end

return Errors.strict(Format, "K.Format")
