-- Library > Plug-in Extras > Folder Publisher: Check & Publish…

local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local FPMaintenance = require 'FPMaintenance'
local FPText = require 'FPText'

LrTasks.startAsyncTask( function()
	local ok, err = LrTasks.pcall( function()
		local service = FPMaintenance.chooseService( FPText.T( 'Menu/CheckPublishTitle', 'Check & Publish' ) )
		if service then
			FPMaintenance.checkAndPublish( service )
		end
	end )
	if not ok then
		LrDialogs.message( 'Folder Publisher', FPText.T( 'Menu/Failed', 'The command failed: ^1', tostring( err ) ),
			'critical' )
	end
end )
