-- Unit tests for the Lightroom-independent parts of Folder Publisher.
-- Run from the repository root with:  lua5.1 tests/run.lua

package.path = 'FolderPublisher.lrplugin/?.lua;' .. package.path

local FPCore = require 'FPCore'

local passed, failed = 0, 0

local function show( v )
	if type( v ) == 'table' then
		local parts = {}
		for i, x in ipairs( v ) do
			parts[i] = show( x )
		end
		return '{' .. table.concat( parts, ', ' ) .. '}'
	end
	return string.format( '%q', tostring( v ) )
end

local function deepEqual( a, b )
	if type( a ) ~= type( b ) then
		return false
	end
	if type( a ) ~= 'table' then
		return a == b
	end
	for k, v in pairs( a ) do
		if not deepEqual( v, b[k] ) then
			return false
		end
	end
	for k in pairs( b ) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function test( name, fn )
	local ok, err = pcall( fn )
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		print( 'FAIL: ' .. name .. '\n      ' .. tostring( err ) )
	end
end

local function eq( actual, expected, label )
	if not deepEqual( actual, expected ) then
		error( ( label and ( label .. ': ' ) or '' ) .. 'expected ' .. show( expected )
			.. ', got ' .. show( actual ), 2 )
	end
end

--------------------------------------------------------------------------------

test( 'splitPath posix', function()
	local comps, prefix = FPCore.splitPath( '/Users/me/Pictures/2024/Trip' )
	eq( comps, { 'Users', 'me', 'Pictures', '2024', 'Trip' } )
	eq( prefix.absolute, true )
end )

test( 'splitPath windows drive', function()
	local comps, prefix = FPCore.splitPath( 'D:\\Photos\\2024\\Trip\\' )
	eq( comps, { 'Photos', '2024', 'Trip' } )
	eq( prefix.drive, 'D:' )
end )

test( 'splitPath UNC', function()
	local comps, prefix = FPCore.splitPath( '\\\\nas\\photos\\2024\\Trip' )
	eq( comps, { '2024', 'Trip' } )
	eq( prefix.unc, { 'nas', 'photos' } )
end )

test( 'componentsBelow is case-insensitive', function()
	eq( FPCore.componentsBelow( 'D:\\Photos\\2024\\Trip', 'd:/photos' ), { '2024', 'Trip' } )
	eq( FPCore.componentsBelow( '/a/b', '/a/b' ), {} )
	eq( FPCore.componentsBelow( '/a/bc', '/a/b' ), nil )
	eq( FPCore.componentsBelow( 'C:\\a', 'D:\\a' ), nil )
	eq( FPCore.componentsBelow( '\\\\nas\\x\\a', '\\\\nas\\y' ), nil )
end )

test( 'mirrorFolder lrRoot includes the top-level folder name', function()
	local tops = { '/Users/me/Pictures', '/Volumes/Archive/Photos' }
	eq( FPCore.mirrorFolder( '/Users/me/Pictures/2024/Trip', tops, 'lrRoot', 0, 0 ),
		{ 'Pictures', '2024', 'Trip' } )
	eq( FPCore.mirrorFolder( '/Volumes/Archive/Photos/Old', tops, 'lrRoot', 0, 0 ),
		{ 'Photos', 'Old' } )
end )

test( 'mirrorFolder picks the deepest top-level folder', function()
	local tops = { '/Users/me', '/Users/me/Pictures' }
	eq( FPCore.mirrorFolder( '/Users/me/Pictures/2024', tops, 'lrRootContents', 0, 0 ), { '2024' } )
end )

test( 'mirrorFolder lrRootContents', function()
	local tops = { 'D:\\Photos' }
	eq( FPCore.mirrorFolder( 'D:\\Photos\\2024\\Trip', tops, 'lrRootContents', 0, 0 ),
		{ '2024', 'Trip' } )
	eq( FPCore.mirrorFolder( 'D:\\Photos', tops, 'lrRootContents', 0, 0 ), {} )
end )

test( 'mirrorFolder full path, skip and depth', function()
	eq( FPCore.mirrorFolder( 'D:\\Photos\\2024\\Trip\\Day1', {}, 'full', 0, 0 ),
		{ 'Photos', '2024', 'Trip', 'Day1' } )
	eq( FPCore.mirrorFolder( 'D:\\Photos\\2024\\Trip\\Day1', {}, 'full', 1, 0 ),
		{ '2024', 'Trip', 'Day1' } )
	eq( FPCore.mirrorFolder( 'D:\\Photos\\2024\\Trip\\Day1', {}, 'full', 1, 2 ),
		{ '2024', 'Trip' } )
	eq( FPCore.mirrorFolder( '/a/b', {}, 'full', 5, 0 ), {} )
end )

test( 'mirrorFolder falls back to full path when no top folder matches', function()
	eq( FPCore.mirrorFolder( '/x/y', { '/a' }, 'lrRoot', 0, 0 ), { 'x', 'y' } )
end )

test( 'sanitizeComponent', function()
	eq( FPCore.sanitizeComponent( 'a:b*c?d' ), 'a_b_c_d' )
	eq( FPCore.sanitizeComponent( 'name. ' ), 'name' )
	eq( FPCore.sanitizeComponent( '  ' ), '_' )
	eq( FPCore.sanitizeComponent( '..' ), '_' )
	eq( FPCore.sanitizeComponent( 'CON' ), '_CON' )
	eq( FPCore.sanitizeComponent( 'con.txt' ), '_con.txt' )
	eq( FPCore.sanitizeComponent( 'Été à Paris' ), 'Été à Paris' )
	eq( FPCore.sanitizeComponent( 'a\tb' ), 'a_b' )
end )

test( 'utf8Truncate never splits a character', function()
	local s = string.rep( 'é', 10 ) -- 20 bytes
	eq( #FPCore.utf8Truncate( s, 5 ), 4 )
	eq( FPCore.utf8Truncate( 'abc', 5 ), 'abc' )
	local long = FPCore.sanitizeComponent( string.rep( 'é', 200 ) )
	eq( #long <= 240, true )
	eq( #long % 2, 0 )
end )

test( 'sanitizeRelative splits and drops empty components', function()
	eq( FPCore.sanitizeRelative( '2024//Trip/ a:b /' ), { '2024', 'Trip', 'a_b' } )
	eq( FPCore.sanitizeRelative( '' ), {} )
	eq( FPCore.sanitizeRelative( '../x' ), { '_', 'x' } )
end )

test( 'splitExtension', function()
	eq( { FPCore.splitExtension( 'IMG_1.CR2' ) }, { 'IMG_1', 'CR2' } )
	eq( { FPCore.splitExtension( 'archive.tar.gz' ) }, { 'archive.tar', 'gz' } )
	eq( { FPCore.splitExtension( 'noext' ) }, { 'noext' } )
	eq( { FPCore.splitExtension( '.hidden' ) }, { '.hidden' } )
end )

test( 'usesXmpSidecar', function()
	eq( FPCore.usesXmpSidecar( 'CR2' ), true )
	eq( FPCore.usesXmpSidecar( 'nef' ), true )
	eq( FPCore.usesXmpSidecar( 'JPG' ), false )
	eq( FPCore.usesXmpSidecar( 'dng' ), false )
	eq( FPCore.usesXmpSidecar( nil ), false )
end )

local function ctx()
	return {
		filename = 'IMG_0042.CR3',
		copyName = 'Copy 1',
		folderName = 'Trip',
		folderPath = { 'Pictures', '2024', 'Trip' },
		date = { year = 2024, month = 7, day = 3, hour = 9, min = 5, sec = 7 },
		collection = 'Best',
		collectionPath = { 'Portfolio', 'Best' },
		service = 'Mirror',
		formatted = function( key )
			local t = { title = 'Sunset', caption = '', cameraModel = 'X100V' }
			return t[ key ]
		end,
		raw = function( key )
			local t = { rating = 4, pickStatus = 1, keywords = {} }
			return t[ key ]
		end,
	}
end

test( 'expandTemplate basic tokens', function()
	eq( FPCore.expandTemplate( '{FilenameBase}', ctx() ), 'IMG_0042' )
	eq( FPCore.expandTemplate( '{filename}', ctx() ), 'IMG_0042.CR3' )
	eq( FPCore.expandTemplate( '{Ext}', ctx() ), 'CR3' )
	eq( FPCore.expandTemplate( '{YYYY}-{MM}-{DD} {HH}.{MIN}.{SS}', ctx() ), '2024-07-03 09.05.07' )
	eq( FPCore.expandTemplate( '{YY}{Date}', ctx() ), '242024-07-03' )
	eq( FPCore.expandTemplate( '{Folder}|{FolderPath}', ctx() ), 'Trip|Pictures/2024/Trip' )
	eq( FPCore.expandTemplate( '{Collection} in {CollectionPath} of {Service}', ctx() ),
		'Best in Portfolio/Best of Mirror' )
	eq( FPCore.expandTemplate( '{Rating}*', ctx() ), '4*' )
	eq( FPCore.expandTemplate( '{Camera}', ctx() ), 'X100V' )
	eq( FPCore.expandTemplate( '{Meta:cameraModel}/{Raw:pickStatus}', ctx() ), 'X100V/1' )
end )

test( 'expandTemplate alternatives and literals', function()
	eq( FPCore.expandTemplate( '{Caption|Title}', ctx() ), 'Sunset' )
	eq( FPCore.expandTemplate( '{Caption|"No caption"}', ctx() ), 'No caption' )
	eq( FPCore.expandTemplate( '{Caption}', ctx() ), '' )
	local c = ctx()
	c.date = nil
	eq( FPCore.expandTemplate( '{YYYY|"Undated"}/{FilenameBase}', c ), 'Undated/IMG_0042' )
	eq( FPCore.expandTemplate( '{Raw:keywords|"none"}', ctx() ), 'none' )
end )

test( 'expandTemplate reports unknown tokens', function()
	local out, unknown = FPCore.expandTemplate( '{Nope}-{FilenameBase}', ctx() )
	eq( out, '-IMG_0042' )
	eq( unknown, { 'Nope' } )
end )

test( 'buildRelativePath', function()
	eq( FPCore.buildRelativePath { subfolder = '', folders = { 'Pictures', '2024' }, name = 'IMG_1', ext = 'JPG' },
		'Pictures/2024/IMG_1.jpg' )
	eq( FPCore.buildRelativePath { subfolder = 'Best/', folders = {}, name = '2024/IMG:1', ext = 'jpg' },
		'Best/2024/IMG_1.jpg' )
	eq( FPCore.buildRelativePath { subfolder = nil, folders = { 'a?' }, name = '', ext = nil },
		'a_/untitled' )
end )

test( 'buildRelativePath with append, stripComponents', function()
	eq( FPCore.buildRelativePath { subfolder = 'pre', folders = { 'a', 'b' }, append = 'post/x', name = 'n', ext = 'jpg' },
		'pre/a/b/post/x/n.jpg' )
	eq( FPCore.stripComponents( { 'a', 'b', 'c', 'd' }, 1, 2 ), { 'b' } )
	eq( FPCore.stripComponents( { 'a', 'b' }, 1, 5 ), {} )
	eq( FPCore.stripComponents( { 'a' }, 0, 0 ), { 'a' } )
end )

test( 'detectLayout: plain mirror', function()
	local l, n = FPCore.detectLayout {
		{ mirrored = { 'Guilde', '2025 Weekend' }, actual = { 'Guilde', '2025 Weekend' } },
		{ mirrored = { 'Guilde', 'Other' }, actual = { 'guilde', 'other' } },
	}
	eq( n, 2 )
	eq( { l.lead, l.trail, #l.prefix, #l.suffix }, { 0, 0, 0, 0 } )
end )

test( 'detectLayout: strip, prepend and append', function()
	local l, n = FPCore.detectLayout {
		{ mirrored = { 'Lightroom sync', 'Guilde', 'A', 'raw' }, actual = { 'Web', 'Guilde', 'A', 'small' } },
		{ mirrored = { 'Lightroom sync', 'Guilde', 'B', 'raw' }, actual = { 'Web', 'Guilde', 'B', 'small' } },
		{ mirrored = { 'Lightroom sync', 'Other', 'raw' }, actual = { 'Web', 'Other', 'small' } },
	}
	eq( n, 3 )
	eq( { l.lead, l.trail }, { 1, 1 } )
	eq( l.prefix, { 'Web' } )
	eq( l.suffix, { 'small' } )
end )

test( 'detectLayout: flattened collection', function()
	local l, n = FPCore.detectLayout {
		{ mirrored = { 'a', 'b' }, actual = { 'Best' } },
		{ mirrored = { 'c' }, actual = { 'Best' } },
	}
	eq( n, 2 )
	eq( l.flatten, true )
	eq( l.prefix, { 'Best' } )
end )

test( 'detectLayout: majority wins over outliers', function()
	local l, n = FPCore.detectLayout {
		{ mirrored = { 'a' }, actual = { 'a' } },
		{ mirrored = { 'b' }, actual = { 'b' } },
		{ mirrored = { 'c' }, actual = { 'zzz' } },
	}
	eq( n, 2 )
	eq( { l.lead, l.trail, #l.prefix, #l.suffix }, { 0, 0, 0, 0 } )
	local none, zero = FPCore.detectLayout {}
	eq( none, nil )
	eq( zero, 0 )
end )

test( 'withSuffix', function()
	eq( FPCore.withSuffix( 'a/b/IMG.jpg', 1 ), 'a/b/IMG.jpg' )
	eq( FPCore.withSuffix( 'a/b/IMG.jpg', 2 ), 'a/b/IMG-2.jpg' )
	eq( FPCore.withSuffix( 'IMG', 3 ), 'IMG-3' )
end )

test( 'resolveCollision is stable and case-insensitive', function()
	local claims = {}
	FPCore.claim( claims, 'x/IMG.jpg', 'A' )
	-- the owner keeps its own name
	eq( FPCore.resolveCollision( 'x/IMG.jpg', 'A', claims ), 'x/IMG.jpg' )
	-- another photo (RAW+JPEG pair, or different case) gets a suffix
	eq( FPCore.resolveCollision( 'X/img.JPG', 'B', claims ), 'X/img-2.JPG' )
	FPCore.claim( claims, 'x/IMG-2.jpg', 'B' )
	eq( FPCore.resolveCollision( 'x/IMG.jpg', 'C', claims ), 'x/IMG-3.jpg' )
	eq( FPCore.resolveCollision( 'x/IMG.jpg', 'B', claims ), 'x/IMG-2.jpg' )
	FPCore.unclaim( claims, 'x/IMG.jpg', 'A' )
	eq( FPCore.resolveCollision( 'x/IMG.jpg', 'C', claims ), 'x/IMG.jpg' )
end )

test( 'claims are reference counted', function()
	local claims = {}
	-- same photo published to the same file from two collections
	FPCore.claim( claims, 'a/IMG.jpg', 'A' )
	FPCore.claim( claims, 'A/img.jpg', 'A' )
	FPCore.unclaim( claims, 'a/IMG.jpg', 'A' )
	eq( FPCore.isClaimed( claims, 'a/IMG.jpg' ), true )
	FPCore.unclaim( claims, 'a/IMG.jpg', 'A' )
	eq( FPCore.isClaimed( claims, 'a/IMG.jpg' ), false )
	-- unclaiming something unknown is harmless
	FPCore.unclaim( claims, 'nope', 'Z' )
	eq( next( claims ), nil )
end )

test( 'matchesTarget', function()
	eq( FPCore.matchesTarget( 'a/IMG.jpg', 'A/img.JPG' ), true )
	eq( FPCore.matchesTarget( 'a/IMG-2.jpg', 'a/IMG.jpg' ), true )
	eq( FPCore.matchesTarget( 'a/IMG-12.jpg', 'a/IMG.jpg' ), true )
	eq( FPCore.matchesTarget( 'a/IMG-x.jpg', 'a/IMG.jpg' ), false )
	eq( FPCore.matchesTarget( 'b/IMG.jpg', 'a/IMG.jpg' ), false )
	eq( FPCore.matchesTarget( 'a/IMG.tif', 'a/IMG.jpg' ), false )
	eq( FPCore.matchesTarget( 'a/I.M.G-2.jpg', 'a/I.M.G.jpg' ), true )
	eq( FPCore.matchesTarget( 'a/IXMXG-2.jpg', 'a/I.M.G.jpg' ), false )
	eq( FPCore.matchesTarget( 'IMG-2', 'IMG' ), true )
end )

test( 'isSafeRelative', function()
	eq( FPCore.isSafeRelative( 'a/b.jpg' ), true )
	eq( FPCore.isSafeRelative( '/a/b.jpg' ), false )
	eq( FPCore.isSafeRelative( 'C:\\a' ), false )
	eq( FPCore.isSafeRelative( 'a/../b' ), false )
	eq( FPCore.isSafeRelative( '' ), false )
end )

test( 'fileUrl', function()
	eq( FPCore.fileUrl( '/Users/me/My Photos/a.jpg' ), 'file:///Users/me/My%20Photos/a.jpg' )
	eq( FPCore.fileUrl( 'C:\\P\\a#1.jpg' ), 'file:///C:/P/a%231.jpg' )
end )

--------------------------------------------------------------------------------

print( string.format( '%d passed, %d failed', passed, failed ) )
os.exit( failed == 0 and 0 or 1 )
