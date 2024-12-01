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
-- * Network & HTTP functions
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

-- convert headers into a table format from a starting table or from csv
local function convertHeaders(inputHeaders)

  local found_accept = false
  local headers = {}

  if inputHeaders then
    
    local tempTable = {}
    
    -- support headers provided either by a table or by csv string
    if (#inputHeaders >= 1 and inputHeaders:find(',',1,true) == nil) then
      tempTable = inputHeaders
    elseif inputHeaders:find(',',1,true) >= 1 then
      for row in string.gmatch(inputHeaders, '([^,]+)') do
        table.insert(tempTable, row);
      end
    end
    
    for _, header in ipairs(tempTable) do
      local key, value = header:match('([^=]+)=([^=]+)$')
      key = key:gsub("%s+", "")
      value = value:match'^%s*(.*)'
      if key and value then
        headers[key] = value
        if string.lower(key) == 'accept' then found_accept = true end
      end
    end
  end
  
  if not found_accept then
    headers["Accept"] = '*/*'
  end
  
  return headers
end

-- Send http or https request and emit response, or handle errors
local function http_request(method, url, requestBody, addedHeaders)

  local responsechunks = {}
  local body, code, headers, status
  
  local protocol = url:match('^(%a+):')
  
  local sendheaders = convertHeaders(addedHeaders)
  
  if requestBody then
    sendheaders["Content-Length"] = string.len(requestBody)
  end
  
  -- replace spaces with '%20'
  url = url:gsub("%s", "%%20")
  
  if protocol == 'https' and requestBody then
  
    body, code, headers, status = https.request{
      method = method,
      url = url,
      headers = sendheaders,
      protocol = "any",
      options =  {"all"},
      verify = "none",
      source = ltn12.source.string(requestBody),
      sink = ltn12.sink.table(responsechunks)
     }

  elseif protocol == 'https' then
  
    body, code, headers, status = https.request{
      method = method,
      url = url,
      headers = sendheaders,
      protocol = "any",
      options =  {"all"},
      verify = "none",
      sink = ltn12.sink.table(responsechunks)
     }

  elseif protocol == 'http' and requestBody then

    body, code, headers, status = http.request{
      method = method,
      url = url,
      headers = sendheaders,
      source = ltn12.source.string(requestBody),
      sink = ltn12.sink.table(responsechunks)
     }
     
  else

    body, code, headers, status = http.request{
      method = method,
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
  protocol = string.upper(protocol)
  
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
    else
      log.warn (string.format("HTTP %s request to %s failed with http code %s, status: %s", method, url, tostring(httpcode_num), status))
      returnstatus = 'Failed'
    end
  
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
        log.error (string.format("HTTP %s request to %s failed with code: %s, status: %s", method, url, httpcode_str, status))
        returnstatus = 'Failed'
      end
    else
      log.warn ("No response code returned")
      returnstatus = "No response code"
    end

  end

  return returnstatus
  
end


-- TODO
-- protected getStatus(result): string {
--   switch (result) {
--     case 0:
--       return ('Ok'); //StatusOk
--     case (1):
--       return ('Unknown Method'); //StatusUnknownMethod
--     case (101):
--       return ('Unparseable Request'); //StatusUnparseableRequest
--     case (102):
--       return ('Invalid Request'); //StatusInvalidRequest
--     case (151):
--       return ('Color Value Out of Range');
--     case (201):
--       return ('Precondition Failed'); //StatusPreconditionFailed
--     case (202):
--       return ('Group Name In Use'); //StatusGroupNameInUse
--     case (205):
--       return ('Group Number In Use'); //StatusGroupNumberInUse
--     case (241):
--       return ('Item Does Not Exist'); //StatusThemeIndexOutOfRange
--     case (242):
--       return ('Bad Group Number'); //StatusThemeIndexOutOfRange
--     case (243):
--       return ('Theme Index Out Of Range'); //StatusThemeIndexOutOfRange
--     case (251):
--       return ('Bad Theme Index'); //StatusThemeIndexOutOfRange
--     case (252):
--       return ('Theme Changes Restricted'); //StatusThemeIndexOutOfRange
--     default:
--       return ('Unknown status');
--   }
-- }


-- ****************************************
-- *
-- * Controller Group Logic & Functions
-- *
-- ****************************************

local function create_group_switch(driver, name, groupNum, level, address)

  log.info(string.format("Creating a group switch Controller:<%s> Group:<%s> Number:<%d> Level:<%s>", address, name, groupNum, level))

  local MFG_NAME = 'JP Edge Drivers'
  local VEND_LABEL = string.format('%s', name)
  local MODEL = 'luxor-group'
  local ID = 'luxor-group' .. '-' .. address .. '-' .. groupNum
  local PROFILE = 'luxor-group'

  log.debug("storing group values in datastore for initialization")

  driver:fill_group_switch_cache(ID, address, name, groupNum, level)

  log.debug (string.format('Creating additional device: label=<%s>, id=<%s>', VEND_LABEL, ID))

  local create_device_msg = {
                              type = "LAN",
                              device_network_id = ID,
                              label = VEND_LABEL,
                              profile = PROFILE,
                              manufacturer = MFG_NAME,
                              model = MODEL,
                              vendor_provided_label = VEND_LABEL
                            }

  local success = assert (driver:try_create_device(create_device_msg), "failed to create luxor group switch")

  if success ~= false then

  else
    log.debug ("try create group switch failed")
    log.debug (success)
  end

end


local function enumerate_groups(driver, device, address, refresh, bypass)

  local pending_request = device:get_field("PendingRequest")
  local request_delay = device:get_field("RequestDelay")

  if pending_request and bypass == nil then return end

  device:set_field("PendingRequest",true)

  if (request_delay > 0 and bypass == nil) then
    request_delay = request_delay + 1.2    
    device:set_field('RequestDelay', request_delay, { ['persist'] = true })
    log.debug("Delaying enumerate_groups by " .. request_delay .. " seconds")
    driver:call_with_delay(request_delay,function() enumerate_groups(driver, device, address, refresh, true) end )    
    return
  elseif bypass == nil then
    request_delay = request_delay + 1.2    
    device:set_field('RequestDelay', request_delay, { ['persist'] = true })
  end

  driver:call_with_delay(1.2, function()
    request_delay = device:get_field("RequestDelay")
    if (request_delay >= 1.2) then
      request_delay = request_delay - 1.2
    else
      request_delay = 0
    end
    device:set_field('RequestDelay', request_delay, { ['persist'] = true })
    log.debug("request_delay: " .. request_delay)
  end)

  log.info(string.format("Enumerating Lighting Groups at: <%s> Refresh: <%s>", address, refresh))

  driver.lastRefresh = os.time()

  local req_url = string.format("http://%s/GroupListGet.json",address)

  local result = http_request('POST',req_url)

  local rtable, pos, err

  device:set_field("PendingRequest",false)

  if result:find('{', 1, true) == 1 then
  
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
    
    local currentdevices = driver:get_devices()
    
    for i,group in next,rtable.GroupList do
      
      log.debug(string.format("Enumerating group switch for group: <%s> Num:<#%d> Level:<#%d>", group.Name, group.Grp, group.Inten))

      local nodevicefound = true

      log.debug(string.format("Searching existing groups for matches. %d",#currentdevices))

      for k,search in next,currentdevices do
        
        log.debug(k .. " - " ..  search.id .. " - " .. search.model .. " - " .. search.label)

        if search.model == "luxor-group" and search:get_field("Controller") == address and search:get_field("Num") == group.Grp then

          log.debug(string.format("Match found. Updating values. k: %s Controller: %s Group: %d Name: %s Level %d", k, address, group.Grp, group.Name, group.Inten))

          nodevicefound = false

          --Report on test results here

          local testdevice = driver:device_from_netId('luxor-group' .. '-' .. address .. '-' .. group.Grp)

          if (testdevice ~= nil and testdevice.id == search.id) then
            log.debug("Test for device_from_netId succeeded!")
          else
            log.warn("Test for device_from_netId failed!")
          end

          --Check for whether name has changed.

          if (search.vendor_provided_label ~= group.Name) then
            search:try_update_metadata({vendor_provided_label = group.Name})
          end

          if (search.label ~= group.Name) then
            search:try_update_metadata({label = group.Name})
          end

          --Check whether level has changed

          if (search:get_field('Level') ~= group.Inten) then
            if group.Inten == 0 then
              search:emit_event(capabilities.switch.switch('off'))
            else
              search:emit_event(capabilities.switchLevel.level(group.Inten))
              search:emit_event(capabilities.switch.switch('on'))
            end
          end

          search:set_field('Name', group.Name, { ['persist'] = true })
          search:set_field('Level', group.Inten, { ['persist'] = true })

        end
      end

      if nodevicefound and refresh ~= true then
        create_group_switch(driver, group.Name, group.Grp, group.Inten, address)
      end

    end

  end

end

-- ****************************************
-- *
-- * Creating Factory and Controller devices
-- *
-- ****************************************

local function create_controller(driver)

  log.info("Creating a controller")

  local device_list = driver:get_devices()

  local MFG_NAME = 'JP Edge Drivers'
  local VEND_LABEL = string.format('Luxor Controller %d', #device_list)
  local MODEL = 'luxor-controller'
  local ID = 'luxor-controller' .. '-' .. socket.gettime()
  local PROFILE = 'luxor-controller'

  if #device_list == 0 then
    VEND_LABEL = "Luxor Controller"
  end

  log.debug (string.format('Creating additional device: label=<%s>, id=<%s>', VEND_LABEL, ID))

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
    driver.initialized = true
  else
    log.debug ("Luxor Controller Creation Failed")
    log.debug (result)
  end
   
end


local function discovery_handler(driver, _, should_continue)

  if not driver.initialized then

    log.info("Creating new Luxor Controller")

    create_controller(driver)

    log.debug("Exiting device creation")

  else
    log.info ('luxor controller factory already created')
  end

end

-- ****************************************
-- *
-- * Ux / Button Event Handling
-- *
-- ****************************************

local function queued_on(driver, device, command, bypass)
  
  local request_delay = device:get_field("RequestDelay")

  if (request_delay > 0 and bypass == nil) then
    request_delay = request_delay + 1.2
    device:set_field('RequestDelay', request_delay, { ['persist'] = true })
    log.debug("Delaying handle_on by " .. request_delay .. " seconds")
    device.thread:call_with_delay(request_delay,function() queued_on(driver, device, command, true) end )    
    return
  elseif bypass == nil then
    request_delay = request_delay + 1.2    
    device:set_field('RequestDelay', request_delay, { ['persist'] = true })
  end

  device.thread:call_with_delay(1.2, function()
    request_delay = device:get_field("RequestDelay")
    if (request_delay >= 1.2) then
      request_delay = request_delay - 1.2
    else
      request_delay = 0
    end
    device:set_field('RequestDelay', request_delay, { ['persist'] = true })
    log.debug("request_delay: " .. request_delay)
  end)

  log.debug (string.format('On Button: device=<%s>, command=<%s>, delay=<%f>', device, command, request_delay))

  if device.model == "luxor-group" then
    local name = device:get_field('Name')
    local level = device:get_field('Level')
    local groupNum = device:get_field('Num')
    local controller = device:get_field("Controller")

    if level == 0 then
      level = 100
      device:emit_event(capabilities.switchLevel.level(level))
      device:set_field('Level', level, { ['persist'] = true })
    end
  
    log.info (string.format("Illuminating Group %s(%d) to Level %d on Controller: <%s>", name, groupNum, level, controller))
  
    local req_url = string.format("http://%s/IlluminateGroup.json",controller)

    local result = http_request('POST',req_url, string.format("{\"GroupNumber\":%d,\"Intensity\":%d}", groupNum, level))

    enumerate_groups(driver, device, controller, true)
  end

  device:set_field('isOn', true, { ['persist'] = true })
  device:emit_event(capabilities.switch.switch('on'))
end

local function handle_on(driver, device, command)
  device.thread:queue_event(queued_on, driver, device, command)
end

local function queued_off(driver, device, command, bypass)
  local request_delay = device:get_field("RequestDelay")
  if (request_delay > 0 and bypass == nil) then
    request_delay = request_delay + 1.2    
    device:set_field('RequestDelay', request_delay, { ['persist'] = true })
    log.debug("Delaying handle_Off by " .. request_delay .. " seconds")
    device.thread:call_with_delay(request_delay,function() queued_off(driver, device, command, true) end )
    return
  elseif bypass == nil then
    request_delay = request_delay + 1.2    
    device:set_field('RequestDelay', request_delay, { ['persist'] = true })
  end

  device.thread:call_with_delay(1.2, function()
    request_delay = device:get_field("RequestDelay")
    if (request_delay >= 1.2) then
      request_delay = request_delay - 1.2
    else
      request_delay = 0
    end
    device:set_field('RequestDelay', request_delay, { ['persist'] = true })
    log.debug("request_delay: " .. request_delay)
  end)

  log.debug (string.format('Off Button: device=<%s>, command=<%s>, delay=<%f>', device, command, request_delay))

  if device.model == "luxor-group" then

    local name = device:get_field('Name')
    local groupNum = device:get_field('Num')
    local controller = device:get_field("Controller")

    log.info (string.format("Illuminating Group %s(%d) to Level %d on Controller: <%s>", name, groupNum, 0, controller))
  
    local req_url = string.format("http://%s/IlluminateGroup.json",controller)

    local result = http_request('POST',req_url, string.format("{\"GroupNumber\":%d,\"Intensity\":%d}", groupNum, 0))

    enumerate_groups(driver, device, controller, true)
  end

  device:set_field('isOn', false, { ['persist'] = true })
  device:emit_event(capabilities.switch.switch('off'))

end

local function handle_off(driver, device, command)
  device.thread:queue_event(queued_off, driver, device, command)
end

local function queued_set_level(driver, device, command)

  local request_delay = device:get_field("RequestDelay")

  log.debug (string.format('Set Level: device=<%s>, Model: <%s>, Level: <%d>, Delay: <%f>', device, device.model,command.args.level, request_delay))
  
  device:set_field('Level', command.args.level, { ['persist'] = true })

  if command.args.level == 0 then
    device:emit_event(capabilities.switchLevel.level(0))
    device:emit_event(capabilities.switch.switch('off'))

    handle_off(driver, device, command)
  else
    device:emit_event(capabilities.switchLevel.level(command.args.level))
    device:emit_event(capabilities.switch.switch('on'))

    handle_on(driver, device, command)
  end

end

local function handle_set_level(driver, device, command)
  device.thread:queue_event(queued_set_level, driver, device, command)
end

local function handle_refresh(driver, device, command)

  log.debug (string.format('Refresh: device=<%s>, Model: <%s>, Args=<%s>', device, device.model, json.encode(command)))

  if device.model == "luxor-controller" and device.preferences.controller ~= '192.168.1.xxx' then
    enumerate_groups(driver, device, device.preferences.controller, true)
  end

  if device.model == "luxor-group" then

    local timeSince = os.difftime(os.time(),driver.lastRefresh)

    log.debug(string.format("Refresh Group: <%s> -- Controller: <%s> -- time:<%s> lastRefresh:<%s> diff:<%d>", device.device_network_id, device:get_field("Controller"),
    os.time(), driver.lastRefresh, timeSince ))

    if timeSince >=3 then
      enumerate_groups(driver, device, device:get_field("Controller"), true)
    end

  end

end

local function handle_pushed(driver, device, command, bypass)
  
  local request_delay

  log.debug (string.format('Button Pushed: device=<%s>, command=<%s>', device, json.encode(command)))

  log.debug (string.format('Button Pushed: name=<%s>, device label: <%s> profilename=<%s>, profileid=<%s>, component=<%s>', 
    device.st_store.driver.name, 
    device.label,
    device.st_store.profile.name,
    device.st_store.profile.id,
    command.component))

  if device.label == 'Luxor Controller Factory' then
      log.debug ("Spawning new Controller")
    create_controller(driver)
  end

  if command.component == 'allOn' and device.model == "luxor-controller" and device.preferences.controller ~= '192.168.1.xxx' then

    request_delay = device:get_field("RequestDelay")
    
    if (request_delay > 0 and bypass == nil) then
      request_delay = request_delay + 1.2    
      device:set_field('RequestDelay', request_delay, { ['persist'] = true })
      log.debug("Delaying allOn by " .. request_delay .. " seconds")
      device.thread:call_with_delay(request_delay,function() handle_pushed(driver, device, command, true) end )
      return
    elseif bypass == nil then
      request_delay = request_delay + 1.2    
      device:set_field('RequestDelay', request_delay, { ['persist'] = true })
    end

    device.thread:call_with_delay(1.2, function()
      request_delay = device:get_field("RequestDelay")
      if (request_delay >= 1.2) then
        request_delay = request_delay - 1.2
      else
        request_delay = 0
      end
      device:set_field('RequestDelay', request_delay, { ['persist'] = true })
      log.debug("request_delay: " .. request_delay)
    end)

    log.info ("Illuminating All Groups on Controller: <%s>", device.preferences.controller)

    local req_url = string.format("http://%s/IlluminateAll.json",device.preferences.controller)

    local result = http_request('POST',req_url)

    enumerate_groups(driver, device, device.preferences.controller, true)

  end

  if command.component == 'allOff' and device.model == "luxor-controller" and device.preferences.controller ~= '192.168.1.xxx'  then

    request_delay = device:get_field("RequestDelay")

    if (request_delay > 0 and bypass == nil) then
      request_delay = request_delay + 1.2    
      device:set_field('RequestDelay', request_delay, { ['persist'] = true })
      log.debug("Delaying allOff by " .. request_delay .. " seconds")
      device.thread:call_with_delay(request_delay,function() handle_pushed(driver, device, command, true) end )
      return
    elseif bypass == nil then
      request_delay = request_delay + 1.2    
      device:set_field('RequestDelay', request_delay, { ['persist'] = true })
    end

    device.thread:call_with_delay(1.2, function()
      request_delay = device:get_field("RequestDelay")
      if (request_delay >= 1.2) then
        request_delay = request_delay - 1.2
      else
        request_delay = 0
      end
      device:set_field('RequestDelay', request_delay, { ['persist'] = true })
      log.debug("request_delay: " .. request_delay)
    end)

    log.info ("Extinguising All Groups on Controller: <%s>", device.preferences.controller)

    local req_url = string.format("http://%s/ExtinguishAll.json",device.preferences.controller)

    local result = http_request('POST',req_url)

    enumerate_groups(driver, device, device.preferences.controller, true)

  end

end


-- ****************************************
-- *
-- * Edge Driver Event Handlers
-- *
-- ****************************************

-- Lifecycle handler to initialize existing devices AND newly discovered devices
local function device_init(driver, device)

  log.debug(device.id .. ": " .. device.device_network_id .. "> INITIALIZING")

  log.debug(string.format("Device Label: <%s> Model: <%s> Network Id: <%s>", device.label, device.model, device.device_network_id))

  driver:record_netId(device)

  if device.model == "luxor-controller" then
    local refreshTimer = device.thread:call_on_schedule(1200, 
      function()

        local timeSince = os.difftime(os.time(),driver.lastRefresh)

        log.debug(string.format("Controller Refresh Timer: <%s> -- Controller: <%s> -- time:<%s> lastRefresh:<%s> diff:<%d>", 
          device.device_network_id, device.preferences.controller,
          os.time(), driver.lastRefresh, timeSince ))

        if timeSince >=2 and device.preferences.controller ~= '192.168.1.xxx' then
          enumerate_groups(driver, device, device.preferences.controller, true)
        end

      end,
      'refreshTimer')

      device:set_field('timer',refreshTimer)

      log.debug("Created Refresh Timer With Cycle of 1200 seconds")
  end

  if device.model == "luxor-group" then
    driver:rehydrate_group_switch(driver)

    local level = device:get_field('Level')
    local isOn = device:get_field('isOn')

    log.debug(string.format("Device isOn: <%s> Level: <%s> Network Id: <%s>", isOn, level, device.device_network_id))
  end

  log.debug('Exiting device initialization')

end


-- Called when device was just created in SmartThings
local function device_added (driver, device)

  log.info(device.id .. ": " .. device.device_network_id .. "> ADDED")

  log.debug(string.format("Added device network id: %s", device.device_network_id))

  if device.model == "luxor-group" then
    
    log.debug(string.format("Added device is a group switch"))

    local controllerAddress, name, groupNum, level = driver:group_switch_from_netId(device.device_network_id)
  
    log.debug(string.format("Setting device storage: Name:%s Num:%s Level:%s Controller:%s", name, groupNum, level, controllerAddress))
  
    device:set_field('Name', name, { ['persist'] = true })
    device:set_field('Num', groupNum, { ['persist'] = true })
    device:set_field('Level', level, { ['persist'] = true })
    device:set_field('Controller', controllerAddress, { ['persist'] = true })
    device:set_field('PendingRequest', false, { ['persist'] = true })
    device:set_field('RequestDelay', 0, { ['persist'] = true })
  
    device:emit_event(capabilities.switchLevel.level(level))

    if level == 0 then
      device:emit_event(capabilities.switch.switch('off'))
    else
      device:emit_event(capabilities.switch.switch('on'))
    end
  
    device:online()
    driver.initialized = true

  end

  if device.model == "luxor-controller" then
    device:online()
    driver.initialized = true
  end

  if device.model == "luxor-factory" then
    device:online()
    driver.initialized = true
  end

end


-- Called when SmartThings thinks the device needs provisioning
local function device_doconfigure (_, device)

log.info ('Device doConfigure lifecycle invoked')

end


-- Called when device was deleted via mobile app
local function device_removed(driver, device)

  log.warn(device.id .. ": " .. device.device_network_id .. "> removed")

  if device.model == "luxor-controller" then
    local refreshTimer = device:get_field('timer')

    log.debug("Canceling Timer: %s", refreshTimer)

    device.thread:cancel_timer(refreshTimer)
  end

  driver:remove_netId(device.device_network_id)

  local device_list = driver:get_devices()
  if #device_list == 0 then
    log.warn ('All devices removed')
    driver.initialized = false
  end

end


local function handler_driverchanged(driver, device, event, args)

  log.debug ('*** Driver changed handler invoked *** - ' .. device:pretty_print() .. ' - event:' .. json.encode(event) .. ' - args:' .. json.encode(args))

  local device_list = driver:get_devices()

  driver.initialized = (#device_list > 0)

end


local function shutdown_handler(driver, event)

  log.debug ('*** Driver shutdown invoked *** - ' .. json.encode(event))

  local device_list = driver:get_devices()

  driver.initialized = (#device_list > 0)
end


local function handler_infochanged (driver, device, event, args)

  log.debug ('Info changed handler invoked - ' .. device:pretty_print())

  -- Did preferences change?
  if device.model == "luxor-controller" and args.old_st_store.preferences then

    if args.old_st_store.preferences.controller ~= device.preferences.controller then
      log.info ('controller address changed to: ', device.preferences.controller)
      
      if (device.preferences.controller ~= '192.168.1.xxx' and validate_ip_address(device.preferences.controller)) then
        enumerate_groups(driver, device, device.preferences.controller)
      end
    end

    if args.old_st_store.preferences.duplicate == true and device.preferences.duplicate == false then
      create_controller(driver)
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
  },
  initialized = false,
  device_from_netId = function(self, networkId)
    if self.datastore.device_network_id == nil then return nil end
    local deviceId = self.datastore.netId_to_deviceId[networkId]
    if not deviceId then return nil end
    return self:get_device_info(deviceId)
  end,
  record_netId = function(self,device)
    local netId = device.device_network_id
    local deviceId = device.id
    if (self.datastore["netId_to_deviceId"] == nil) then
      self.datastore["netId_to_deviceId"] = {}
      self.datastore.netId_to_deviceId[netId] = deviceId
    elseif (self.datastore.netId_to_deviceId[netId] == nil or self.datastore.netId_to_deviceId[netId] ~= deviceId) then
      self.datastore.netId_to_deviceId[netId] = deviceId
    end
  end,
  remove_netId = function(self,networkId)
    if self.datastore.device_network_id == nil then return end
    self.datastore.netId_to_deviceId[networkId] = nil
  end,
  fill_group_switch_cache = function(self, netId, controllerAddress, name, groupNum, level)
    if (self.datastore["group_switch_cache"] == nil) then
      self.datastore["group_switch_cache"] = {}
    end

    log.debug(string.format("Storing group switch cache info: NetId:<%s> Controller:<%s> Name:<%s> Group:<%d> Level:<%s>",
      netId, controllerAddress, name, groupNum, level))

    self.datastore.group_switch_cache[netId] = {}
    self.datastore.group_switch_cache[netId]["Controller"] = controllerAddress
    self.datastore.group_switch_cache[netId]["Name"] = name
    self.datastore.group_switch_cache[netId]["Num"] = groupNum
    self.datastore.group_switch_cache[netId]["Level"] = level
  end,
  group_switch_from_netId = function(self, netId)
    if self.datastore.group_switch_cache[netId] == nil then return nil end

    local controllerAddress = self.datastore.group_switch_cache[netId]["Controller"]
    local name = self.datastore.group_switch_cache[netId]["Name"]
    local groupNum = self.datastore.group_switch_cache[netId]["Num"]
    local level = self.datastore.group_switch_cache[netId]["Level"]

    return controllerAddress, name, groupNum, level
  end,
  rehydrate_group_switch = function (self, device)
    if device.device_network_id == nil then return nil end

    local controllerAddress = device:get_field('Controller');
    local name = device:get_field('Name');
    local groupNum = device:get_field('Num');
    local level = device:get_field('Level');

    self:fill_group_switch_cache(device.device_network_id, controllerAddress, name, groupNum, level)
  end,
  lastRefresh = os.time()
}

luxor_driver = Driver("Luxor Controller", luxor_controller_template)

if luxor_driver.datastore["group_switch_cache"] == nil then
  luxor_driver.datastore["group_switch_cache"] = {}
end

if luxor_driver.datastore["netId_to_deviceId"] == nil then
  luxor_driver.datastore["netId_to_deviceId"] = {}
end

luxor_driver:run()
