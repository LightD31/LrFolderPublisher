#!/bin/sh
# Builds the installable plug-in zip: dist/FolderPublisher.lrplugin.zip
# Prints the plug-in version (from Info.lua) on stdout.
set -eu
cd "$(dirname "$0")/.."

version=$(lua5.1 -e '
	LOC = function( s ) return ( s:gsub( "^%$%$%$/[^=]*=", "" ) ) end
	local v = dofile( "FolderPublisher.lrplugin/Info.lua" ).VERSION
	io.write( string.format( "%d.%d.%d", v.major, v.minor, v.revision ) )')

rm -rf dist
mkdir -p dist
zip -q -r -X dist/FolderPublisher.lrplugin.zip FolderPublisher.lrplugin \
	-x '*/.DS_Store' '*/Thumbs.db' '*/desktop.ini'
echo "$version"
