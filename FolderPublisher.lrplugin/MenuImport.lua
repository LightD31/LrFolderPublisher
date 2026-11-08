-- Library > Plug-in Extras > Folder Publisher: Import from Another Publish Service…

local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local FPMigration = require 'FPMigration'
local FPText = require 'FPText'
local logger = require 'FPLog'

LrTasks.startAsyncTask( function()
	local ok, err = LrTasks.pcall( FPMigration.run )
	if not ok then
		logger:error( 'MenuImport failed: ' .. tostring( err ) )
		LrDialogs.message( 'Folder Publisher', FPText.T( 'Menu/Failed', 'The command failed: ^1', tostring( err ) ),
			'critical' )
	end
end )
