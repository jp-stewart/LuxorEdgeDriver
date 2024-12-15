local capabilities = require "st.capabilities"
local Driver = require "st.driver"
local cosock = require "cosock"
local socket = require "cosock.socket"
local http = cosock.asyncify "socket.http"
local https = cosock.asyncify "ssl.https"
http.TIMEOUT = 3
https.TIMEOUT = 3
local ltn12 = require "ltn12"
local log = require "log"

local json = require "dkjson"
local ds = require "datastore"

local luxor_driver = {}

-- ****************************************
-- *
-- * Network, HTTP, & Utility functions
-- *
-- ****************************************

local function validate_ip_address(ipAddress)

  local valid = true

  local chunks = {ipAddress:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")}
  if #chunks == 4 then
    for _, v in pairs(chunks) do
      if tonumber(v) > 255 then
        valid = false
        break
      end
    end
  else
    valid = false
  end

  return valid

end

local function backOff(controllerDevice)

  local delay = 1.2
  local currentValue = controllerDevice:get_field("backOff")


  if (currentValue == nil) then
    currentValue = 0
  end

  currentValue = currentValue + delay
  controllerDevice:set_field("backOff",currentValue)

  controllerDevice.thread:call_with_delay(delay,function() 
    local updateValue = controllerDevice:get_field("backOff")
    updateValue = updateValue - delay
    if (updateValue < 0) then
      updateValue = 0
    end
    controllerDevice:set_field("backOff",updateValue)
   end )

  return currentValue

end

local function initializeDriver(driver, value)

  log.info(string.format("Initialize Driver called requesting value: <%s>",value))

  if (value == nil or value == true) then
    driver.datastore["initialized"] = true;
  else
    driver.datastore["initialized"] = false;
  end
end

local function isInitialized(driver)

  local driverInitialized = driver.datastore["initialized"]
  local deviceCount = driver:get_devices()

  log.info(string.format("Checking Driver Initialization. Value: <%s> Device Count: <%d>",driverInitialized,#deviceCount))

  if (driverInitialized == nil or driverInitialized == false) then
    return false
  end

  if (#deviceCount == 0) then
    log.warn("Driver reports initialized but there are zero devices // overriding result and setting initialized to false.")
    initializeDriver(driver,false)
    return false
  end

  return true
end

-- Send http or https request and emit response, or handle errors
local function http_request(url, requestBody)

  local responsechunks = {}
  local sendheaders = {}
  local body, code, headers, status
  
  url = url:gsub("%s", "%%20")

  sendheaders["Content-Type"] = "application/json"
  
  if requestBody then
    
    sendheaders["Content-Length"] = string.len(requestBody)

    body, code, headers, status = http.request{
      method = 'POST',
      url = url,
      headers = sendheaders,
      source = ltn12.source.string(requestBody),
      sink = ltn12.sink.table(responsechunks)
     }
     
  else

    body, code, headers, status = http.request{
      method = 'POST',
      url = url,
      headers = sendheaders,
      sink = ltn12.sink.table(responsechunks)
     }

  end

  local response = table.concat(responsechunks)
  
  log.info(string.format("response code=<%s>, status=<%s>", code, status))
  
  local returnstatus = 'unknown'
  local httpcode_str
  local httpcode_num
  
  if type(code) == 'number' then
    httpcode_num = code
  else
    httpcode_str = code
  end
  
  if httpcode_num then
    if (httpcode_num >= 200) and (httpcode_num < 300) then
      returnstatus = 'OK'
      log.debug (string.format('Response:\n>>>%s<<<', response))
      
      return response
    elseif httpcode_num == 1 then
      returnstatus = "Unknown Method"
    elseif httpcode_num == 101 then
      returnstatus = "Unparseable Request"
    elseif httpcode_num == 102 then
      returnstatus = "Invalid Request"
    elseif httpcode_num == 151 then
      returnstatus = "Color Value Out of Range"
    elseif httpcode_num == 201 then
      returnstatus = "Precondition Failed"
    elseif httpcode_num == 202 then
      returnstatus = "Group Name In Use"
    elseif httpcode_num == 205 then
      returnstatus = "Group Number In Use"
    elseif httpcode_num == 241 then
      returnstatus = "Item Does Not Exist"
    elseif httpcode_num == 242 then
      returnstatus = "Bad Group Number"
    elseif httpcode_num == 243 then
      returnstatus = "Theme Index Out Of Range"
    elseif httpcode_num == 251 then
      returnstatus = "Bad Theme Index"
    elseif httpcode_num == 252 then
      returnstatus = "Theme Changes Restricted"
    else
      returnstatus = 'Unknown Failure'
    end
    
    log.warn (string.format("HTTP request to %s failed with http code %s, status: %s -- Error: %s", url, tostring(httpcode_num), status, returnstatus))
  
  else
    
    if httpcode_str then
      if string.find(httpcode_str, "closed") then
        log.warn ("Socket closed unexpectedly: ", url)
        returnstatus = "No response"
      elseif string.find(httpcode_str, "refused") then
        log.warn("Connection refused: ", url)
        returnstatus = "Refused"
      elseif string.find(httpcode_str, "timeout") then
        log.warn("HTTP request timed out: ", url)
        returnstatus = "Timeout"
      else
        log.error (string.format("HTTP request to %s failed with code: %s, status: %s", url, httpcode_str, status))
        returnstatus = 'Failed'
      end
    else
      log.warn ("No response code returned")
      returnstatus = "No response code"
    end

  end

  return returnstatus
  
end

-- ****************************************
-- *
-- * Controller Group Logic & Functions
-- *
-- ****************************************

local function updateGroupState(device, name, number, level)

  --Check for whether name has changed.
  if (device.vendor_provided_label ~= name) then
    device:try_update_metadata({vendor_provided_label = name})
  end

  if (device.label ~= name) then
    device:try_update_metadata({label = name})
  end

  if level == 0 then
    device:emit_event(capabilities.switch.switch('off'))
  else
    device:emit_event(capabilities.switchLevel.level(level))
    device:emit_event(capabilities.switch.switch('on'))
  end

  --Update/refresh stored device data
  device:set_field('Name', name, { ['persist'] = true })
  device:set_field('group', number, { ['persist'] = true })
  device:set_field('isOn', (level > 0), { ['persist'] = true })
  device:set_field('switchLevel', level, { ['persist'] = true })

end

--NOTE/WARNING, smartthings function device:get_child_by_parent_assigned_key does not work at all in my experience.
--              The root cause is not entirely clear, however I was never able to "see" parent_assigned_key set on child devices when passed in via metadata.
--              Because of this, I had to create this function, and also thread/time delay updating/setting of the switch values during refresh.
--              Its not elegant, since every switch goes through this for-loop. A TODO item would be to store the child drivers in the controller persistent store
--              however, that also requires lifecycle management of those entries as well. This method does not.
local function findChildByNetId(parent,netId)

  log.info(string.format("Find child by NetId. Parent: %s Child Net Id to find: %s",parent.device_network_id,netId))

  local child_list = parent:get_child_list()

  if (child_list == nil or #child_list == 0) then
    log.error(parent.device_network_id .. " has no children.")
    return
  end

  for i,child in ipairs(child_list) do
    if (child.device_network_id == netId) then
      log.info(string.format("Matching network id found, returning: %s - %s",child.device_network_id,child.label))
      return child
    else
      log.info(string.format("Network id does not match: %s - %s",child.device_network_id,child.label))
    end
  end

end

local function find_and_update_group_switch(controller,label,groupNum,level)

  local key = string.format("luxor-group-%s-%d",controller.preferences.controller,groupNum)
  local newDevice = findChildByNetId(controller,key)

  if (newDevice ~= nil) then
      controller.thread:queue_event(updateGroupState,newDevice,label,groupNum,level)
  else
      log.error(string.format("Error finding new device by id: <%s> after creating group switch: <%s>. Controller: <%s> Group: <%s> Level: <%s>",key,label,controller.preferences.controller,groupNum, level))
  end

end

local function create_group_switch(driver, parent, name, groupNum, level, address)

  log.info(string.format("Creating a group switch Controller:<%s> Group:<%s> Number:<%d> Level:<%s>", address, name, groupNum, level))

  local MFG_NAME = 'JP Edge Drivers'
  local VEND_LABEL = string.format('%s', name)
  local MODEL = 'luxor-group'
  local ID = 'luxor-group' .. '-' .. address .. '-' .. groupNum
  local PROFILE = 'luxor-group'
  local KEY = string.format("group-%d",groupNum)

  log.debug (string.format('Creating additional device: label=<%s>, id=<%s>, key=<%s>', VEND_LABEL, ID, KEY))

  local create_device_msg = {
                              type = "LAN",
                              device_network_id = ID,
                              label = VEND_LABEL,
                              profile = PROFILE,
                              manufacturer = MFG_NAME,
                              model = MODEL,
                              vendor_provided_label = VEND_LABEL,
                              parent_device_id = parent.id,
                              parent_assigned_child_key = VEND_LABEL, --KEY,
                              external_id = tostring(groupNum),
                              level_value = tostring(level)
                            }

  local success = assert (driver:try_create_device(create_device_msg), "failed to create luxor group switch")

  if success ~= false then
    
    parent.thread:call_with_delay(3,function() find_and_update_group_switch(parent,VEND_LABEL,groupNum,level) end )

  else
    log.debug ("try create group switch failed")
    log.debug (success)
  end

end

local function enumerate_groups(driver, device)

  if (device.model ~= "luxor-controller" or device.preferences.controller == '192.168.1.xxx' or not validate_ip_address(device.preferences.controller)) then
    return
  end

  -- Cannot overload the controller web server
  local http_underway = device:get_field("http_underway")
  if (http_underway ~= nil and http_underway == true) then
    -- try again incremental time
    local backofftime = backOff(device)
    log.info(string.format("Controller Busy - Delaying Enumeration by %f seconds", backofftime))
    device.thread:call_with_delay(backofftime,function() enumerate_groups(driver,device) end )
    return
  end

  device:set_field("http_underway",true)

  local timeStamp = os.time()

  device:set_field("lastRefresh",timeStamp)

  log.info(string.format("Enumerating Lighting Groups at: <%s> - Time: <%s>", device.preferences.controller, timeStamp))


  local req_url = string.format("http://%s/GroupListGet.json",device.preferences.controller)

  local result = http_request(req_url)

  local rtable, pos, err

  --Clear the pending request in 1s

  device.thread:call_with_delay(1,function() 
    device:set_field("http_underway",false)
  end)

  if result:find('{', 1, true) == 1 then -- Check for json indicator in the return string
  
    log.debug ('Parsing response for groups')

    rtable, pos, err = json.decode (result, 1, nil)

    if err then
      log.error ("JSON decode error:", err)
      return nil
    end

  else

    log.error(string.format("Error, could not find '{' in return result from server. Result: %s", result))
    return nil
  end

  log.debug(string.format("Table Entries: <#%d>", #rtable.GroupList))

  if #rtable.GroupList >= 1 then    
    
    for i,group in next,rtable.GroupList do

      local key = string.format("group-%d",group.Grp)
      
      log.debug(string.format("Enumerating group switch for group: <%s> Num:<#%d> Level:<#%d>", group.Name, group.Grp, group.Inten))

      log.debug(string.format("Searching children for existing group by Key: %s",key))

      local lookupKey = string.format("luxor-group-%s-%d",device.preferences.controller,group.Grp)
      local childDevice = findChildByNetId(device,lookupKey)

      if (childDevice == nil) then
        log.warn(string.format("No match for: %s found as a child. Creating new device.",lookupKey))
        device.thread:queue_event(create_group_switch,driver, device, group.Name, group.Grp, group.Inten, device.preferences.controller)
      else
        log.debug(string.format("Match found. Updating values. Controller: %s Group: %d Name: %s Level %d", device.preferences.controller, group.Grp, group.Name, group.Inten))

        device.thread:queue_event(updateGroupState,childDevice, group.Name, group.Grp, group.Inten)
      end

    end

  end

end

local function timerFunction(driver, device)

  if device.model ~= "luxor-controller" or device.preferences.controller == '192.168.1.xxx' or not validate_ip_address(device.preferences.controller) then
    log.warn(string.format("Controller Address not set OR Non-controller device calling timer function! Addres: <%s> Device Model: <%s> Id: <%s>",device.preferences.controller,device.model, device.device_network_id))
    return
  end

  local currentTime = os.time()
  local lastRefresh = device:get_field('lastRefresh')
  if (lastRefresh == nil) then lastRefresh = currentTime end

  local timeSince = os.difftime(currentTime,lastRefresh)

  log.debug(string.format("Controller Refresh Timer: <%s> -- Controller: <%s> -- time:<%s> lastRefresh:<%s> diff:<%d>", 
    device.device_network_id, device.preferences.controller,
    currentTime, lastRefresh, timeSince ))

  device.thread:queue_event(enumerate_groups, driver, device)
  
end

local function serialHttpRequestNoReturn(driver, controllerDevice, url,optionalBody)

  if controllerDevice.model ~= "luxor-controller" or controllerDevice.preferences.controller == '192.168.1.xxx' then
    log.warn(string.format("Controller Address not set OR Non-controller device calling serialHttpRequestNoReturn function! Addres: <%s> Device Model: <%s> Id: <%s>",controllerDevice.preferences.controller,controllerDevice.model, controllerDevice.device_network_id))
    return
  end

  local checkUnderway = controllerDevice:get_field("http_underway")

  if (checkUnderway ~= nil and checkUnderway == true) then
    local backofftime = backOff(controllerDevice)

    controllerDevice.thread:call_with_delay(backofftime,function() 
      controllerDevice.thread:queue_event(serialHttpRequestNoReturn, driver, controllerDevice, url, optionalBody)
    end)
    return
  end

  controllerDevice:set_field("http_underway",true)

  http_request(url, optionalBody)

  controllerDevice.thread:call_with_delay(1,function() 
    controllerDevice:set_field("http_underway",false)

    controllerDevice.thread:queue_event(timerFunction, driver, controllerDevice)
  end)

end

-- ****************************************
-- *
-- * Creating Controller device and Discovery Handler
-- *
-- ****************************************

local function create_controller(driver)

  log.info("Creating a controller")

  local device_list = driver:get_devices()

  local MFG_NAME = 'JP Edge Drivers'
  local VEND_LABEL = "Luxor Controller" 
  local MODEL = 'luxor-controller'
  local ID = 'luxor-controller' .. '-' .. socket.gettime()
  local PROFILE = 'luxor-controller'

  if #device_list > 0 then
    VEND_LABEL = string.format('%s %d', VEND_LABEL, #device_list)
  end

  log.debug (string.format('Creating luxor controller device: label=<%s>, id=<%s>, Device Count:<%d>', VEND_LABEL, ID, #device_list))

  local create_device_msg = {
                              type = "LAN",
                              device_network_id = ID,
                              label = VEND_LABEL,
                              profile = PROFILE,
                              manufacturer = MFG_NAME,
                              model = MODEL,
                              vendor_provided_label = VEND_LABEL
                            }

  local result = assert (driver:try_create_device(create_device_msg), "failed to create luxor controller")

  if result ~= false then
    initializeDriver(driver)
  else
    log.debug ("Luxor Controller Creation Failed")
    log.debug (result)
  end
   
end

local function discovery_handler(driver, _, should_continue)

  local driverInitialized = isInitialized(driver)

  if not driverInitialized then

    log.info("Creating new Luxor Controller")

    create_controller(driver)

    log.debug("Exiting device creation")

  else
    log.info ('At least one luxor controller exists -- spawn new controller from settings')
  end

end

-- ****************************************
-- *
-- * Ux / Button Event Handling
-- *
-- ****************************************

local function queued_on(driver, device, command)
  
  log.debug (string.format('On Button: device=<%s>, command=<%s>', device, json.encode(command)))

  if device.model == "luxor-group" then
    local parent = device:get_parent_device()

    local name = device.label
    local groupNum = device:get_field('group')
    local address = parent.preferences.controller
    local level = device:get_field('switchLevel')

    if level == 0 then
      level = 100
    end
  
    local req_url = string.format("http://%s/IlluminateGroup.json",address)
    local body = string.format("{\"GroupNumber\":%d,\"Intensity\":%d}", groupNum, level)

    log.info (string.format("Illuminating Group %s(%d) to Level %d on Controller: <%s> - URL: <%s> Body: <%s>", name, groupNum, level, address,req_url,body))
  
    serialHttpRequestNoReturn(driver, parent, req_url, body)

  end

end

local function handle_on(driver, device, command)
  device.thread:queue_event(queued_on, driver, device, command)
end

local function queued_off(driver, device, command)

  log.debug (string.format('Off Button: device=<%s>, command=<%s>', device, json.encode(command)))

  if device.model == "luxor-group" then
    local parent = device:get_parent_device()

    local name = device.label
    local groupNum = device:get_field('group')
    local address = parent.preferences.controller

    local req_url = string.format("http://%s/IlluminateGroup.json",address)
    local body = string.format("{\"GroupNumber\":%d,\"Intensity\":%d}", groupNum, 0)

    log.info (string.format("Illuminating Group %s(%d) to Level %d on Controller: <%s> - URL: <%s> Body: <%s>", name, groupNum, 0, address,req_url,body))
  
    serialHttpRequestNoReturn(driver, parent, req_url, body)

  end

end

local function handle_off(driver, device, command)
  device.thread:queue_event(queued_off, driver, device, command)
end

local function queued_set_level(driver, device, command)

  log.debug (string.format('Set Level: device=<%s>, Model: <%s>, Level: <%d>', device, device.model,command.args.level))
  
  if command.args.level == 0 then
    handle_off(driver, device, command)
  else
    device:set_field('switchLevel', command.args.level, { ['persist'] = true })
    handle_on(driver, device, command)
  end

end

local function handle_set_level(driver, device, command)
  device.thread:queue_event(queued_set_level, driver, device, command)
end

local function handle_refresh(driver, device, command)

  log.debug (string.format('Refresh: device=<%s>, Model: <%s>, Args=<%s>', device, device.model, json.encode(command)))

  if device.model == "luxor-controller" and device.preferences.controller ~= '192.168.1.xxx' then
    timerFunction(driver,device)
  end

  if device.model == "luxor-group" then
    local parent = device:get_parent_device()

    timerFunction(driver,parent)
  end

end

local function handle_pushed(driver, device, command, bypass)
  
  log.debug (string.format('Button Pushed: device=<%s>, command=<%s>', device, json.encode(command)))

  log.debug (string.format('Button Pushed: name=<%s>, device label: <%s> profilename=<%s>, profileid=<%s>, component=<%s>', 
    device.st_store.driver.name, 
    device.label,
    device.st_store.profile.name,
    device.st_store.profile.id,
    command.component))

  if command.component == 'allOn' and device.model == "luxor-controller" and device.preferences.controller ~= '192.168.1.xxx' then

    local req_url = string.format("http://%s/IlluminateAll.json",device.preferences.controller)
    log.info(string.format("Illuminating All Groups on Controller: <%s> -- URL: <%s>", device.preferences.controller, req_url))
    
    serialHttpRequestNoReturn(driver, device, req_url)
  end

  if command.component == 'allOff' and device.model == "luxor-controller" and device.preferences.controller ~= '192.168.1.xxx'  then

    local req_url = string.format("http://%s/ExtinguishAll.json",device.preferences.controller)
    log.info(string.format("Extinguising All Groups on Controller: <%s> -- URL: <%s>", device.preferences.controller,req_url))

    serialHttpRequestNoReturn(driver, device, req_url)

  end
end

-- ****************************************
-- *
-- * Edge Driver Event Handlers
-- *
-- ****************************************

-- Lifecycle handler to initialize existing devices AND newly discovered devices
local function device_init(driver, device, args)

  log.debug(string.format("Device Initialization - Id: <%s> Network Id: <%s> Model: <%s> Label: <%s> Args: <%s>",device.id, device.device_network_id, device.model, device.label, args))

end


-- Called when device was just created in SmartThings
local function device_added (driver, device)

  log.debug(string.format("Device Added - Id: <%s> Network Id: <%s> Model: <%s> Label: <%s>",device.id, device.device_network_id, device.model, device.label))

  device:online()
    
  initializeDriver(driver)

end


-- Called when SmartThings thinks the device needs provisioning
local function device_doconfigure (driver, device)
  
  log.debug(string.format("Device doConfigure - Id: <%s> Network Id: <%s> Model: <%s> Label: <%s>",device.id, device.device_network_id, device.model, device.label))

  if device.model == "luxor-controller" then
    local refreshRate = device.preferences.refreshRate

    local existingTimer = device:get_field("timer")
    
    if (existingTimer ~= nil) then
      log.debug(string.format("Canceling Existing Controller Timer"))

      local status, result = pcall(device.thread.cancel_timer,existingTimer)

      log.debug(string.format("Cancelation result: %s",status))
    end

    local refreshTimer = device.thread:call_on_schedule(refreshRate, function() timerFunction(driver,device) end, 'refreshTimer')

    device:set_field('timer',refreshTimer)

    log.debug(string.format("Created Refresh Timer With Cycle of <%d> seconds",refreshRate))

    log.info ('Calling Timer function because of Controller doConfigure event.')
    
    timerFunction(driver,device)
  end

end


-- Called when device was deleted via mobile app
local function device_removed(driver, device)

  log.warn(string.format("Device Removed - Id: <%s> Network Id: <%s> Model: <%s> Label: <%s>",device.id, device.device_network_id, device.model, device.label))

  if device.model == "luxor-controller" then
    local refreshTimer = device:get_field('timer')

    log.debug(string.format("Canceling Controller Timer"))

    local status, result = pcall(device.thread.cancel_timer,refreshTimer)

    log.debug(string.format("Cancelation result: %s",status))

  end

end


local function handler_driverchanged(driver, device, event, args)

  local device_list = driver:get_devices()

  log.debug (string.format('*** Driver changed handler invoked *** - Device Count: <%d> Event: <%s> Args: <%s> Device: <%s>',#device_list, json.encode(event),json.encode(args),device:pretty_print()))

  initializeDriver(driver,(#device_list > 0))

end


local function shutdown_handler(driver, event)
  
  local device_list = driver:get_devices()

  log.debug (string.format('*** Driver shutdown invoked *** - Device Count: <%d> Event: <%s>',#device_list, json.encode(event)))

  initializeDriver(driver,(#device_list > 0))
end


local function handler_infochanged (driver, device, event, args)

  log.debug ('Info changed handler invoked - ' .. device:pretty_print())
  local refreshNeeded = false

  -- Did preferences change?
  if device.model == "luxor-controller" and args.old_st_store.preferences then

    if args.old_st_store.preferences.controller ~= device.preferences.controller then
      log.info ('controller address changed to: ', device.preferences.controller)
      
      if (device.preferences.controller ~= '192.168.1.xxx' and validate_ip_address(device.preferences.controller)) then
        refreshNeeded = true
      end
    end
    
    if args.old_st_store.preferences.refreshRate ~= device.preferences.refreshRate then
      log.info ('Refresh Rate changed to: ', device.preferences.refreshRate)

      local refreshTimer = device:get_field('timer')

      log.debug(string.format("Canceling Controller Timer"))

      local status, result = pcall(device.thread.cancel_timer,refreshTimer)

      log.debug(string.format("Cancelation result: %s",status))

      local newRefreshTimer = device.thread:call_on_schedule(device.preferences.refreshRate,
        function()        
          timerFunction(driver, device) 
        end,
        'refreshTimer')

      device:set_field('timer',newRefreshTimer)

      log.debug(string.format("Created Refresh Timer With Cycle of %d seconds",device.preferences.refreshRate))
      
      refreshNeeded = true
    end

    if args.old_st_store.preferences.duplicate == true and device.preferences.duplicate == false then
      create_controller(driver)
    end

    if refreshNeeded then
      timerFunction(driver,device)
    end

  end

end

-- ****************************************
-- *
-- * Defining and creating the root driver
-- *
-- ****************************************

local luxor_controller_template = {
  discovery = discovery_handler,
  lifecycle_handlers = {
    init = device_init,
    added = device_added,
    driverSwitched = handler_driverchanged,
    infoChanged = handler_infochanged,
    doConfigure = device_doconfigure,
    removed = device_removed
  },
  driver_lifecycle = shutdown_handler,
  supported_capabilities = {
    capabilities.momentary,
    capabilities.switch,
    capabilities.switchLevel,
    capabilities.refresh
  },
  capability_handlers = {
    [capabilities.switch.ID] = {
      [capabilities.switch.commands.on.NAME] = handle_on,
      [capabilities.switch.commands.off.NAME] = handle_off,
    },
    [capabilities.switchLevel.ID] = {
        [capabilities.switchLevel.commands.setLevel.NAME] = handle_set_level
    },
    [capabilities.momentary.ID] = {
      [capabilities.momentary.commands.push.NAME] = handle_pushed
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh
    }
  }
}

luxor_driver = Driver("Luxor Controller", luxor_controller_template)

luxor_driver:run()
