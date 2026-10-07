-- Library > Plug-in Extras > Folder Publisher: Find Moved, Renamed or Missing Photos…

local LrDialogs = import 'LrDialogs'
local LrTasks = import 'LrTasks'

local FPMaintenance = require 'FPMaintenance'

LrTasks.startAsyncTask( function()
	local ok, err = LrTasks.pcall( function()
		local service = FPMaintenance.chooseService( 'Find Moved, Renamed or Missing Photos' )
		if service then
			FPMaintenance.checkService( service )
		end
	end )
	if not ok then
		LrDialogs.message( 'Folder Publisher', 'The check failed: ' .. tostring( err ), 'critical' )
	end
end )
