--[[----------------------------------------------------------------------------
FPText.lua
Localised text. Every user-visible string goes through T( key, english, ... ),
which looks the key up in TranslatedStrings_<language>.txt (in the plug-in
folder) and falls back to the English text.

Keys may only contain a-z, A-Z, 0-9 and '/'. ^1 … ^9 in the text are replaced
by the extra arguments.
------------------------------------------------------------------------------]]

local FPText = {}

-- Lightroom wants plain ASCII in the default text of a ZString: encode other
-- characters as ^U+XXXX.
local function encode( s )
	return ( s:gsub( '[\194-\239][\128-\191]+', function( ch )
		local b1, b2, b3 = ch:byte( 1, 3 )
		local cp
		if b1 < 0xE0 then
			cp = ( b1 - 0xC0 ) * 64 + ( b2 - 0x80 )
		else
			cp = ( b1 - 0xE0 ) * 4096 + ( b2 - 0x80 ) * 64 + ( ( b3 or 0x80 ) - 0x80 )
		end
		return string.format( '^U+%04X', cp )
	end ) )
end

FPText.encode = encode

function FPText.T( key, english, ... )
	return LOC( '$$$/FolderPublisher/' .. key .. '=' .. encode( english ), ... )
end

-- "1 photo" / "3 photos"
function FPText.count( n, key, one, many )
	if n == 1 then
		return FPText.T( key .. '/One', one, n )
	end
	return FPText.T( key .. '/Many', many, n )
end

return FPText
