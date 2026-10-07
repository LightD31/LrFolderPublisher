--[[----------------------------------------------------------------------------
FPFiles.lua
File-system operations used by Folder Publisher.
------------------------------------------------------------------------------]]

local LrDate = import 'LrDate'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrTasks = import 'LrTasks'

local FPCore = require 'FPCore'
local logger = require 'FPLog'

local FPFiles = {}

-- Files the OS sprinkles into folders; they don't keep a folder "non-empty".
local JUNK_FILES = {
	['.ds_store'] = true,
	['thumbs.db'] = true,
	['desktop.ini'] = true,
	['._.ds_store'] = true,
}

function FPFiles.isJunkFile( path )
	return JUNK_FILES[ string.lower( LrPathUtils.leafName( path ) ) ] == true
end

--- Expands a leading "~" to the user's home folder.
function FPFiles.expandRoot( root )
	root = FPCore.trim( tostring( root or '' ) )
	if root == '~' or root:match( '^~[\\/]' ) then
		local home = LrPathUtils.getStandardFilePath( 'home' )
		root = home .. root:sub( 2 )
	end
	return root
end

--- Converts a relative ('/'-separated) remote id into an absolute path.
function FPFiles.absolute( root, rel )
	local path = root
	for part in tostring( rel ):gmatch( '[^\\/]+' ) do
		path = LrPathUtils.child( path, part )
	end
	return path
end

function FPFiles.exists( path )
	return LrFileUtils.exists( path ) ~= false
end

function FPFiles.isDirectory( path )
	return LrFileUtils.exists( path ) == 'directory'
end

--- Moves the rendered file `src` to `dest`, replacing any existing file.
-- Falls back to copy + delete when a plain move is not possible (e.g. when
-- the destination is on another volume).
-- Returns true, or false and an error message.
function FPFiles.place( src, dest )
	local parent = LrPathUtils.parent( dest )
	if not FPFiles.isDirectory( parent ) then
		-- Network shares sometimes need a second attempt.
		for _ = 1, 3 do
			LrFileUtils.createAllDirectories( parent )
			if FPFiles.isDirectory( parent ) then
				break
			end
			LrTasks.sleep( 0.5 )
		end
		if not FPFiles.isDirectory( parent ) then
			return false, 'Could not create folder ' .. parent
		end
	end

	if FPFiles.exists( dest ) then
		local ok, msg = LrFileUtils.delete( dest )
		if not ok and FPFiles.exists( dest ) then
			return false, 'Could not replace ' .. dest .. ( msg and ( ': ' .. tostring( msg ) ) or '' )
		end
	end

	local moved = pcall( LrFileUtils.move, src, dest )
	if moved and FPFiles.exists( dest ) then
		return true
	end

	local copied = pcall( LrFileUtils.copy, src, dest )
	if copied and FPFiles.exists( dest ) then
		LrFileUtils.delete( src )
		return true
	end

	return false, 'Could not write ' .. dest
end

--- Removes a published file according to `mode` ('delete', 'trash', 'keep').
-- Returns true when the file is gone (or intentionally kept).
function FPFiles.remove( path, mode )
	if mode == 'keep' or not FPFiles.exists( path ) then
		return true
	end
	local ok, msg
	if mode == 'trash' then
		ok, msg = LrFileUtils.moveToTrash( path )
	else
		ok, msg = LrFileUtils.delete( path )
	end
	if not ok and FPFiles.exists( path ) then
		logger:warn( 'Could not remove ' .. path .. ': ' .. tostring( msg ) )
		return false
	end
	return true
end

--- Removes a published file plus its .xmp sidecar (for raw originals).
function FPFiles.removePublished( path, mode )
	local ok = FPFiles.remove( path, mode )
	local ext = LrPathUtils.extension( path )
	if FPCore.usesXmpSidecar( ext ) then
		FPFiles.remove( LrPathUtils.replaceExtension( path, 'xmp' ), mode )
	end
	return ok
end

local function isEffectivelyEmpty( dir )
	for entry in LrFileUtils.directoryEntries( dir ) do
		if not FPFiles.isJunkFile( entry ) then
			return false
		end
	end
	return true
end

--- Deletes `dir` and its parents while they are empty, never going above
-- (or deleting) `root`.
function FPFiles.pruneEmptyFolders( dir, root )
	while dir do
		local below = FPCore.componentsBelow( dir, root )
		if not below or #below == 0 then
			return
		end
		if not FPFiles.isDirectory( dir ) or not isEffectivelyEmpty( dir ) then
			return
		end
		for entry in LrFileUtils.directoryEntries( dir ) do
			LrFileUtils.delete( entry )
		end
		if not LrFileUtils.delete( dir ) then
			return
		end
		logger:trace( 'Removed empty folder ' .. dir )
		dir = LrPathUtils.parent( dir )
	end
end

local function shellQuote( s )
	return "'" .. s:gsub( "'", "'\\''" ) .. "'"
end

--- Sets the modification (and, on Windows, creation) date of a file to an
-- Lightroom time value (seconds since 2001-01-01, as returned by
-- photo:getRawMetadata('dateTimeOriginal')).
function FPFiles.setFileTime( path, lrTime )
	if not lrTime then
		return false
	end
	local cmd
	if WIN_ENV then
		local stamp = LrDate.timeToUserFormat( lrTime, '%Y%m%d%H%M%S' )
		local ps = string.format(
			"$d=[datetime]::ParseExact('%s','yyyyMMddHHmmss',$null);"
				.. "$i=Get-Item -LiteralPath '%s';$i.LastWriteTime=$d;$i.CreationTime=$d",
			stamp, ( path:gsub( "'", "''" ) ) )
		-- The outer quotes are consumed by cmd.exe, which LrTasks.execute uses.
		cmd = '"powershell.exe -NoProfile -NonInteractive -Command "' .. ps .. '""'
	else
		local stamp = LrDate.timeToUserFormat( lrTime, '%Y%m%d%H%M.%S' )
		cmd = 'touch -m -t ' .. stamp .. ' ' .. shellQuote( path )
	end
	local status = LrTasks.execute( cmd )
	if status ~= 0 then
		logger:warn( 'Setting the file date failed (' .. tostring( status ) .. '): ' .. cmd )
		return false
	end
	return true
end

return FPFiles
