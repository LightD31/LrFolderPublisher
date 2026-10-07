--[[----------------------------------------------------------------------------
FPLog.lua
Shared logger. Messages go to "FolderPublisher.log" in Lightroom's log folder
(Documents/LrClassicLogs on both macOS and Windows).
------------------------------------------------------------------------------]]

local LrLogger = import 'LrLogger'

local logger = LrLogger( 'FolderPublisher' )
logger:enable( 'logfile' )

return logger
