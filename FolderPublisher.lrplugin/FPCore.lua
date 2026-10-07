--[[----------------------------------------------------------------------------
FPCore.lua
Pure-Lua logic for Folder Publisher: path mapping, filename templates,
sanitising and collision handling.

This module must not depend on any Lightroom SDK namespace so that it can be
unit tested with a stock Lua 5.1 interpreter (see tests/run.lua).

Relative paths produced here ("remote ids") always use '/' as separator,
regardless of platform.
------------------------------------------------------------------------------]]

local FPCore = {}

--------------------------------------------------------------------------------
-- Small string helpers

local function trim( s )
	return ( s:gsub( '^%s+', '' ):gsub( '%s+$', '' ) )
end

local function lower( s )
	return string.lower( s or '' )
end

local function escapePattern( s )
	return ( s:gsub( '[%^%$%(%)%%%.%[%]%*%+%-%?]', '%%%0' ) )
end

FPCore.trim = trim

--------------------------------------------------------------------------------
-- Path splitting

--- Splits an absolute or relative path into its components.
-- Returns components (array) and a prefix description table:
--   { drive = 'C:' } for Windows drive paths,
--   { unc = { 'server', 'share' } } for UNC paths,
--   { absolute = true } for POSIX absolute paths.
-- The drive / UNC host+share are NOT part of the returned components.
function FPCore.splitPath( path )
	path = path or ''
	local prefix = {}

	local unc = path:match( '^[\\/][\\/]([^\\/].*)$' )
	if unc then
		path = unc
		prefix.unc = {}
	else
		local drive, rest = path:match( '^(%a:)(.*)$' )
		if drive then
			prefix.drive = drive
			path = rest
		elseif path:match( '^[\\/]' ) then
			prefix.absolute = true
		end
	end

	local comps = {}
	for part in path:gmatch( '[^\\/]+' ) do
		if part ~= '.' then
			comps[ #comps + 1 ] = part
		end
	end

	if prefix.unc then
		-- first two components are \\server\share
		prefix.unc[1] = table.remove( comps, 1 )
		prefix.unc[2] = table.remove( comps, 1 )
	end

	return comps, prefix
end

--- Returns the components of `path` that follow `base`, or nil if `base` is
-- not a parent of (or equal to) `path`. Comparison is case-insensitive since
-- both macOS and Windows default to case-insensitive file systems.
function FPCore.componentsBelow( path, base )
	local p, pp = FPCore.splitPath( path )
	local b, bp = FPCore.splitPath( base )
	if lower( pp.drive ) ~= lower( bp.drive ) then
		return nil
	end
	if ( pp.unc ~= nil ) ~= ( bp.unc ~= nil ) then
		return nil
	end
	if pp.unc then
		if lower( pp.unc[1] ) ~= lower( bp.unc[1] ) or lower( pp.unc[2] ) ~= lower( bp.unc[2] ) then
			return nil
		end
	end
	if #b > #p then
		return nil
	end
	for i = 1, #b do
		if lower( b[i] ) ~= lower( p[i] ) then
			return nil
		end
	end
	local rest = {}
	for i = #b + 1, #p do
		rest[ #rest + 1 ] = p[i]
	end
	return rest
end

--------------------------------------------------------------------------------
-- Folder mapping

--- Computes the folder components (relative to the publish root) that mirror
-- the Lightroom folder of a photo.
--
-- @param folderPath  absolute path of the folder holding the master file
-- @param topFolders  array of absolute paths of Lightroom's top-level folders
-- @param mode        'lrRoot'          -> include the top-level folder's name
--                    'lrRootContents'  -> start below the top-level folder
--                    'full'            -> full path (minus drive / UNC share)
-- @param skip        number of leading components to drop
-- @param maxDepth    keep at most this many components (0 = unlimited)
function FPCore.mirrorFolder( folderPath, topFolders, mode, skip, maxDepth )
	local comps

	if mode ~= 'full' then
		-- Find the deepest top-level folder that contains this photo.
		local bestBase, bestRest
		for _, top in ipairs( topFolders or {} ) do
			local rest = FPCore.componentsBelow( folderPath, top )
			if rest and ( not bestRest or #rest < #bestRest ) then
				bestBase, bestRest = top, rest
			end
		end
		if bestBase then
			comps = {}
			if mode == 'lrRoot' then
				local baseComps = FPCore.splitPath( bestBase )
				if #baseComps > 0 then
					comps[1] = baseComps[ #baseComps ]
				end
			end
			for _, c in ipairs( bestRest ) do
				comps[ #comps + 1 ] = c
			end
		end
	end

	if not comps then
		comps = FPCore.splitPath( folderPath )
	end

	skip = tonumber( skip ) or 0
	maxDepth = tonumber( maxDepth ) or 0

	local out = {}
	for i = skip + 1, #comps do
		if maxDepth > 0 and #out >= maxDepth then
			break
		end
		out[ #out + 1 ] = comps[i]
	end
	return out
end

--------------------------------------------------------------------------------
-- Sanitising

local WINDOWS_RESERVED = {
	con = true, prn = true, aux = true, nul = true,
	com1 = true, com2 = true, com3 = true, com4 = true, com5 = true,
	com6 = true, com7 = true, com8 = true, com9 = true,
	lpt1 = true, lpt2 = true, lpt3 = true, lpt4 = true, lpt5 = true,
	lpt6 = true, lpt7 = true, lpt8 = true, lpt9 = true,
}

local MAX_COMPONENT_BYTES = 240 -- leaves headroom for "-NN" and extensions

--- Truncates a UTF-8 string to at most n bytes without splitting a character.
function FPCore.utf8Truncate( s, n )
	if #s <= n then
		return s
	end
	local cut = n
	-- Step back while the byte after the cut is a continuation byte.
	while cut > 0 do
		local b = s:byte( cut + 1 )
		if not b or b < 0x80 or b >= 0xC0 then
			break
		end
		cut = cut - 1
	end
	return s:sub( 1, cut )
end

--- Makes a single path component safe on Windows, macOS and Linux.
function FPCore.sanitizeComponent( s )
	s = tostring( s or '' )
	s = s:gsub( '[%c<>:"/\\|%?%*]', '_' )
	s = trim( s )
	-- Windows silently strips trailing dots and spaces.
	s = s:gsub( '[%.%s]+$', '' )
	if s == '' then
		return '_'
	end
	if s == '.' or s == '..' then
		return '_'
	end
	local stem = lower( s:match( '^([^%.]*)' ) )
	if WINDOWS_RESERVED[ stem ] then
		s = '_' .. s
	end
	return FPCore.utf8Truncate( s, MAX_COMPONENT_BYTES )
end

--- Splits a template result on '/' or '\' and sanitises every component.
-- Empty components are dropped.
function FPCore.sanitizeRelative( s )
	local out = {}
	for part in tostring( s or '' ):gmatch( '[^\\/]+' ) do
		part = trim( part )
		if part ~= '' then
			out[ #out + 1 ] = FPCore.sanitizeComponent( part )
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- File-name helpers

function FPCore.splitExtension( name )
	local base, ext = name:match( '^(.+)%.([^%./\\]+)$' )
	if base then
		return base, ext
	end
	return name, nil
end

local NON_RAW_EXTENSIONS = {
	jpg = true, jpeg = true, tif = true, tiff = true, png = true, psd = true,
	psb = true, heic = true, heif = true, avif = true, webp = true, jxl = true,
	dng = true, gif = true, bmp = true,
	mp4 = true, mov = true, m4v = true, avi = true, mts = true, m2ts = true,
	mpg = true, mpeg = true, ['3gp'] = true, xmp = true,
}

--- True if files with this extension get an .xmp sidecar when exported as
-- "Original" (i.e. camera raw files).
function FPCore.usesXmpSidecar( ext )
	ext = lower( ext )
	return ext ~= '' and not NON_RAW_EXTENSIONS[ ext ]
end

--------------------------------------------------------------------------------
-- Templates

local function pad2( n )
	return string.format( '%02d', n )
end

--- Token resolvers. Each receives (ctx, arg) and returns a string or nil.
-- ctx fields (all optional):
--   filename, copyName, folderName, folderPath (array), date (table with
--   year, month, day, hour, min, sec), collection, collectionPath (array),
--   service, formatted(key), raw(key)
local TOKENS = {}

TOKENS.filename = function( ctx ) return ctx.filename end
TOKENS.filenamebase = function( ctx )
	return ctx.filename and ( FPCore.splitExtension( ctx.filename ) )
end
TOKENS.ext = function( ctx )
	return ctx.filename and select( 2, FPCore.splitExtension( ctx.filename ) )
end
TOKENS.copyname = function( ctx ) return ctx.copyName end
TOKENS.folder = function( ctx ) return ctx.folderName end
TOKENS.foldername = TOKENS.folder
TOKENS.folderpath = function( ctx )
	return ctx.folderPath and table.concat( ctx.folderPath, '/' )
end

TOKENS.yyyy = function( ctx ) return ctx.date and tostring( ctx.date.year ) end
TOKENS.yy = function( ctx ) return ctx.date and pad2( ctx.date.year % 100 ) end
TOKENS.mm = function( ctx ) return ctx.date and pad2( ctx.date.month ) end
TOKENS.dd = function( ctx ) return ctx.date and pad2( ctx.date.day ) end
TOKENS.hh = function( ctx ) return ctx.date and pad2( ctx.date.hour ) end
TOKENS.min = function( ctx ) return ctx.date and pad2( ctx.date.min ) end
TOKENS.ss = function( ctx ) return ctx.date and pad2( ctx.date.sec ) end
TOKENS.date = function( ctx )
	local d = ctx.date
	return d and string.format( '%04d-%02d-%02d', d.year, d.month, d.day )
end

local function formatted( key )
	return function( ctx )
		return ctx.formatted and ctx.formatted( key )
	end
end

TOKENS.title = formatted( 'title' )
TOKENS.caption = formatted( 'caption' )
TOKENS.headline = formatted( 'headline' )
TOKENS.label = formatted( 'label' )
TOKENS.camera = formatted( 'cameraModel' )
TOKENS.lens = formatted( 'lens' )
TOKENS.iso = formatted( 'isoSpeedRating' )
TOKENS.keywords = formatted( 'keywordTags' )
TOKENS.city = formatted( 'city' )
TOKENS.state = formatted( 'stateProvince' )
TOKENS.country = formatted( 'country' )
TOKENS.location = formatted( 'location' )
TOKENS.creator = formatted( 'creator' )
TOKENS.jobidentifier = formatted( 'jobIdentifier' )

TOKENS.rating = function( ctx )
	local r = ctx.raw and ctx.raw( 'rating' )
	return r and tostring( r )
end

TOKENS.collection = function( ctx ) return ctx.collection end
TOKENS.collectionpath = function( ctx )
	return ctx.collectionPath and table.concat( ctx.collectionPath, '/' )
end
TOKENS.service = function( ctx ) return ctx.service end

TOKENS.meta = function( ctx, arg )
	return arg and ctx.formatted and ctx.formatted( arg )
end
TOKENS.raw = function( ctx, arg )
	local v = arg and ctx.raw and ctx.raw( arg )
	if v == nil or type( v ) == 'table' then
		return nil
	end
	return tostring( v )
end

FPCore.TOKEN_NAMES = {
	'Filename', 'FilenameBase', 'Ext', 'CopyName', 'Folder', 'FolderPath',
	'YYYY', 'YY', 'MM', 'DD', 'HH', 'MIN', 'SS', 'Date',
	'Title', 'Caption', 'Headline', 'Label', 'Rating', 'Camera', 'Lens', 'ISO',
	'Keywords', 'City', 'State', 'Country', 'Location', 'Creator', 'JobIdentifier',
	'Collection', 'CollectionPath', 'Service', 'Meta:<key>', 'Raw:<key>',
}

local function resolveOne( alt, ctx, unknown )
	alt = trim( alt )
	local literal = alt:match( '^"(.*)"$' )
	if literal then
		return literal
	end
	local name, arg = alt:match( '^([%w_]+):(.*)$' )
	if not name then
		name = alt
	end
	local fn = TOKENS[ lower( name ) ]
	if not fn then
		unknown[ #unknown + 1 ] = alt
		return nil
	end
	local v = fn( ctx, arg )
	if v == nil then
		return nil
	end
	v = tostring( v )
	if v == '' then
		return nil
	end
	return v
end

--- Expands a template such as "{YYYY}/{Title|FilenameBase}".
-- Inside braces, alternatives are separated by '|'; the first one that
-- yields a non-empty value is used. "quoted" alternatives are literal text.
-- Returns the expanded string and an array of unknown tokens.
function FPCore.expandTemplate( template, ctx )
	local unknown = {}
	local result = tostring( template or '' ):gsub( '{([^{}]*)}', function( inner )
		for alt in ( inner .. '|' ):gmatch( '([^|]*)|' ) do
			local v = resolveOne( alt, ctx, unknown )
			if v then
				return v
			end
		end
		return ''
	end )
	return result, unknown
end

--------------------------------------------------------------------------------
-- Relative target paths

--- Joins arrays of (already sanitised) components with '/'.
function FPCore.joinRelative( ... )
	local out = {}
	for _, list in ipairs( { ... } ) do
		for _, c in ipairs( list ) do
			out[ #out + 1 ] = c
		end
	end
	return table.concat( out, '/' )
end

--- Builds the relative target path for a photo.
-- @param args.subfolder      expanded collection sub-folder (string, may contain '/')
-- @param args.folders        mirrored folder components (array, unsanitised)
-- @param args.name           expanded file name without extension (may contain '/')
-- @param args.ext            extension of the rendered file
function FPCore.buildRelativePath( args )
	local sub = FPCore.sanitizeRelative( args.subfolder )
	local folders = {}
	for _, c in ipairs( args.folders or {} ) do
		folders[ #folders + 1 ] = FPCore.sanitizeComponent( c )
	end
	local nameParts = FPCore.sanitizeRelative( args.name )
	if #nameParts == 0 then
		nameParts = { 'untitled' }
	end
	local ext = args.ext and args.ext ~= '' and ( '.' .. lower( args.ext ) ) or ''
	nameParts[ #nameParts ] = nameParts[ #nameParts ] .. ext
	return FPCore.joinRelative( sub, folders, nameParts )
end

--- Case-insensitive key for comparing relative paths.
function FPCore.pathKey( rel )
	return lower( ( tostring( rel or '' ):gsub( '\\', '/' ) ) )
end

--- Inserts "-n" before the extension of a relative path.
function FPCore.withSuffix( rel, n )
	if not n or n < 2 then
		return rel
	end
	local dir, file = rel:match( '^(.*/)([^/]*)$' )
	if not dir then
		dir, file = '', rel
	end
	local base, ext = FPCore.splitExtension( file )
	return dir .. base .. '-' .. n .. ( ext and ( '.' .. ext ) or '' )
end

--- Picks the first of rel, rel-2, rel-3, ... that is not claimed by another
-- photo. `claims` maps pathKey -> { [ownerId] = number of references }
-- (the same photo can be published to the same file from several
-- collections of a service).
function FPCore.resolveCollision( rel, ownerId, claims )
	local n = 1
	while true do
		local candidate = FPCore.withSuffix( rel, n )
		local owners = claims[ FPCore.pathKey( candidate ) ]
		local free = true
		if owners then
			for id in pairs( owners ) do
				if id ~= ownerId then
					free = false
					break
				end
			end
		end
		if free then
			return candidate
		end
		n = n + 1
	end
end

--- Records one reference of `ownerId` to `rel`.
function FPCore.claim( claims, rel, ownerId )
	local key = FPCore.pathKey( rel )
	local owners = claims[ key ] or {}
	claims[ key ] = owners
	owners[ ownerId ] = ( owners[ ownerId ] or 0 ) + 1
end

--- Drops one reference of `ownerId` to `rel`.
function FPCore.unclaim( claims, rel, ownerId )
	local key = FPCore.pathKey( rel )
	local owners = claims[ key ]
	if owners and owners[ ownerId ] then
		owners[ ownerId ] = owners[ ownerId ] - 1
		if owners[ ownerId ] <= 0 then
			owners[ ownerId ] = nil
		end
		if next( owners ) == nil then
			claims[ key ] = nil
		end
	end
end

--- True if any published entry still references `rel`.
function FPCore.isClaimed( claims, rel )
	return claims[ FPCore.pathKey( rel ) ] ~= nil
end

--- True if `actual` is `expected` or `expected` with a collision suffix.
function FPCore.matchesTarget( actual, expected )
	local a, e = FPCore.pathKey( actual ), FPCore.pathKey( expected )
	if a == e then
		return true
	end
	local dir, file = e:match( '^(.*/)([^/]*)$' )
	if not dir then
		dir, file = '', e
	end
	local base, ext = FPCore.splitExtension( file )
	local pattern = '^' .. escapePattern( dir .. base ) .. '%-%d+'
		.. ( ext and escapePattern( '.' .. ext ) or '' ) .. '$'
	return a:match( pattern ) ~= nil
end

--- Returns true if a relative path is safe to join with the root, i.e. it
-- is not absolute and contains no '..' component.
function FPCore.isSafeRelative( rel )
	rel = tostring( rel or '' )
	if rel == '' or rel:match( '^[\\/]' ) or rel:match( '^%a:' ) then
		return false
	end
	for part in rel:gmatch( '[^\\/]+' ) do
		if part == '..' then
			return false
		end
	end
	return true
end

--- Encodes an absolute path as a file:// URL.
function FPCore.fileUrl( path )
	local p = tostring( path or '' ):gsub( '\\', '/' )
	if not p:match( '^/' ) then
		p = '/' .. p
	end
	p = p:gsub( '[^%w%-%._~/:]', function( c )
		return string.format( '%%%02X', c:byte() )
	end )
	return 'file://' .. p
end

return FPCore
