-- Library > Plug-in Extras > Folder Publisher: Clean Up Orphaned Files…

local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local FPMaintenance = require 'FPMaintenance'
local FPText = require 'FPText'
local logger = require 'FPLog'

LrTasks.startAsyncTask( function()
	local ok, err = LrTasks.pcall( function()
		local service = FPMaintenance.chooseService( FPText.T( 'Menu/OrphansTitle', 'Clean Up Orphaned Files' ) )
		if service then
			FPMaintenance.cleanOrphans( service )
		end
	end )
	if not ok then
		logger:error( 'MenuOrphans failed: ' .. tostring( err ) )
		LrDialogs.message( 'Folder Publisher', FPText.T( 'Menu/Failed', 'The command failed: ^1', tostring( err ) ),
			'critical' )
	end
end )
