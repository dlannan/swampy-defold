local tinsert 	= table.insert
local tremove 	= table.remove

local swampy 	= require "swampy.swampy"
local url 		= require "swampy.utils.url"
local json 		= require "swampy.utils.json"

-- Some general settings. This is game specific.
local MAX_CONNECT_ATTEMPTS		= 10

-- ---------------------------------------------------------------------------
-- Game level states.
--   These track where you are in the login and running process
local GAME		 	= {
	LOGGING_IN 		= 1,
	LOGIN_OK		= 2,
	LOGIN_FAIL		= 3,
	
	SETUP			= 10,

	GAME_JOINING	= 20, 

	EXIT 			= 90,
}

-- ---------------------------------------------------------------------------
-- User defined events - these are handled in your module
local USER_EVENT 	= {
	REQUEST_GAME 	= 1,
	POLL 			= 2,

	REQUEST_READY	= 10,
	REQUEST_START 	= 20,
	REQUEST_WAITING = 30,
	REQUEST_ROUND 	= 40,
}

-- ---------------------------------------------------------------------------
local function resetclient(self)
	self.device_id = url.uuid()
end 

-- ---------------------------------------------------------------------------

local function websocket_callback(self, conn, data)
	if data.event == websocket.EVENT_DISCONNECTED then
		log("Disconnected: " .. tostring(conn))
		self.connection = nil
		update_gui(self)
	elseif data.event == websocket.EVENT_CONNECTED then
		update_gui(self)
		log("Connected: " .. tostring(conn))
	elseif data.event == websocket.EVENT_ERROR then
		log("Error: '" .. data.message .. "'")
	elseif data.event == websocket.EVENT_MESSAGE then
		log("Receiving: '" .. tostring(data.message) .. "'")
	end
end

-- ---------------------------------------------------------------------------
-- Check connection when calling swampy funcs

local function check_connect(self)

	local ok = nil
	local resp = { status = "ERROR" } 
	if(self.swp_account == nil) then  resp.status = "Connect Error: No valid swampy account."; return ok, resp end
	
	if(self.swp_client.state == nil) then resp.status = "Connect Error: failed to connect."; return ok, resp end
	if(self.client_id == nil) then  resp.status = "Connect Error: No Client Id."; return ok, resp end
	if(self.user_id == nil) then  resp.status = "Connect Error: No User Id."; return ok, resp end 
	if(self.swp_account == nil) then  resp.status = "Connect Error: No valid swampy account."; return ok, resp end
	ok = true 
	-- Handle other connect issues here
	return ok, resp
end

-- ---------------------------------------------------------------------------
-- Setup server 
local function setup_swampy(self, modulename)

	swampy.setmodulename(modulename) 

	-- The Nakama server configuration
	local config = {}
	
	config.host 		= "45.125.247.75"
	config.port 		= 5000
	config.use_ssl 		= true 
	config.api_token 	= "j3mHKlgGZ4" 
	
	self.login_attemps 	= 0
	self.gamestate 		= 0
	

	self.user_id		= "blahblah"
	self.device_id		= 12345

	self.swp_client = swampy.create_client(config)
	--pprint(self.swp_client)
end

-- ---------------------------------------------------------------------------
-- our login function using a device token
local function device_login(self, callback)

	if(self.debugClient == 1) then resetclient(self) end
	--pprint("Config:")
	--pprint(self.config_data)
	
	self.gamestate = GAME.LOGGING_IN
	-- login using the token and create an account if the user
	-- doesn't already exist
	swampy.do_login(self.swp_client, self.user_id, self.device_id, function(resp, id, result)

		local data = json.decode(result.response)
		if data.status == "OK" then
			-- store the token and use it when communicating with the server
			self.swp_token = data.bearertoken
			swampy.set_bearer_token(self.swp_client, self.swp_token)
			pprint(self.swp_client)
			
			print("Successful login")
			if(callback) then callback() end
			self.gamestate = GAME.LOGIN_OK
			return
		end
	
		print("Unable to login")
		self.login_attemps = self.login_attemps + 1
		if(self.login_attemps > 10) then 

			self.gamestate = GAME.LOGIN_FAIL
		else 
			resetclient(self)
			self.gamestate = GAME.SETUP
		end
	end)
end


-- ---------------------------------------------------------------------------
-- Update match player name
local function updateplayername( self, match_data )

	for k,user in pairs(self.client_party.people) do 
		if(user.user_id == match_data.presence.user_id) then 
			local playerdata = json.decode(match_data.data)
			user.player_name = playerdata.player_name
		end
	end
end	

-- ---------------------------------------------------------------------------
local function connect(self, callback)

	-- The connect process for the time beiing is to enable an account with user info 
	--  attached to the device the user has and the user generated token they are connecting with.
	self.swp_conn_attempts = (self.swp_conn_attempts or 0) + 1
	if(self.swp_conn_attempts > MAX_CONNECT_ATTEMPTS) then callback({ status = "Connect Error: Exceeded connect attempts." }); return end
	
	self.client_id 		= nil
	self.user_id 		= nil
	self.swp_account 	= nil
	
	if(self.swp_client.state ~= "CONNECTING") then 
		self.swp_client.state = "CONNECTING"
		swampy.connect( self.swp_client, self.player_name, self.device_id, function(rdata)

			if(rdata.status == "OK") then 
				self.swp_account = rdata.data
				-- Not sure this is needed anymore (nakama legacy)
				self.client_id = self.swp_account.username 
				self.user_id = self.swp_account.uid

				print("Connected ok.")
				self.swp_client.state = "CONNECTED"
			else 
				print("Connect failed.")
				self.swp_client.state = nil
			end
			callback(rdata.status)
		end)
	end
end

-- ---------------------------------------------------------------------------
local function updateaccount(self, callback)

	local ok, resp = check_connect(self) 
	if(ok == nil) then callback(resp); return nil end 
	
	-- Only bother with display name initially
	local useracct = self.swp_account
	useracct.username = self.player_name
	local body = swampy.update_user(self.swp_client, self.device_id, self.player_name, useracct.lang, function(resp)

		-- pprint(resp)
		if resp.status ~= "OK" then
			print("Error:", resp.status)
		end  
		callback(resp)
	end)
end 

-- ---------------------------------------------------------------------------
local function make_requestgamestate(client, game_name, device_id) 

	-- User submission data must be in this format - will be checked
	local userdata = {

		state       = GAME.GAME_JOINING,   
		uid         = device_id,
		name        = game_name,
		round       = 0,
		timestamp   = os.time(),

		event       = USER_EVENT.REQUEST_GAME,
		json        = "",
	}
	return userdata
end 

-- ---------------------------------------------------------------------------
-- A normal updategame does a "request_round" event with no other data sent
local function updategame(self, callback) 

	local ok, resp = check_connect(self) 
	if(ok == nil) then callback(resp); return nil end 
	if(self.game == nil) then return end 
	
	local body = make_requestgamestate( self.swp_client, self.game_name, self.device_id)
	local bodystr = json.encode(body)
	swampy.game_update( self.swp_client, self.game_name, self.device_id, function(data)

		if(data.status == "OK") then 
			callback(data.result)
		else 
			print("Error updating game: ", data.results)
			callback(nil)
		end 
	end, bodystr)
end 

-- ---------------------------------------------------------------------------
-- An update that doesnt return anything, just keeps connect alive
local function pollgame(self) 

	local ok, resp = check_connect(self) 
	if(ok == nil) then print(resp.status); return nil end 
	
	local body = make_requestgamestate( self.swp_client, self.game_name, self.device_id )
	body.event = USER_EVENT.POLL
	local bodystr = json.encode(body)
	swampy.game_update( self.swp_client, self.game_name, self.device_id, function(data)
		-- Can do stuff here if you need something to happen ;)
	end, bodystr)
end 

-- ---------------------------------------------------------------------------

local function updateready(self, ready) 

	local ok, resp = check_connect(self) 
	if(ok == nil) then print(resp.status); return nil end 
	
	if(self.game.state ~= GAME.GAME_JOINING) then return end

	local body = make_requestgamestate( self.swp_client, self.game_name, self.device_id )
	body.event = USER_EVENT.REQUEST_READY
	body.json = { state = tostring(ready or 0) }
	local bodystr = json.encode(body)

	swampy.game_update( self.swp_client, self.game_name, self.device_id, function(data)

	end, bodystr)
end 

-- ---------------------------------------------------------------------------

local function startgame(self, callback)

	local ok, resp = check_connect(self) 
	if(ok == nil) then callback(resp); return nil end 
	if(self.game.state ~= GAME.GAME_JOINING) then return end
	
	-- This sets the server game state to match the owner	
	local body = make_requestgamestate( self.swp_client, self.game_name, self.device_id )
	body.state = self.game.state
	body.event = USER_EVENT.REQUEST_START
	local bodystr = json.encode(body)
	swampy.game_update( self.swp_client, self.game_name, self.device_id, function(data)

		-- The game is returned on start - use this for game obj
		if(data.status == "OK") then 
			callback(data.result)
		else 
			print("Error starting game: ", data.results)
		end 
	end, bodystr)
end 

-- ---------------------------------------------------------------------------

local function exitgame(self, callback)

	local ok, resp = check_connect(self) 
	if(ok == nil) then callback(resp); return nil end 
	local body = make_requestgamestate( self.swp_client, self.game_name, self.device_id )
	body.state = GAME.EXIT
	local bodystr = json.encode(body)
	swampy.game_update( self.swp_client, self.game_name, self.device_id, function(data)
		callback()
	end, bodystr)
end 

-- ---------------------------------------------------------------------------

local function updategamestate(self, callback)

	local ok, resp = check_connect(self) 
	if(ok == nil) then callback(resp); return nil end 
	if(self.game.state == nil or self.game.state < GAME.GAME_JOINING) then return end

	local body = make_requestgamestate( self.swp_client, self.game_name, self.device_id )
	body.state = self.game.state
	body.event = USER_EVENT.REQUEST_ROUND
	local bodystr = json.encode(body)
	swampy.game_update( self.swp_client, self.game_name, self.device_id, function(data)

		-- The game is returned on start - use this for game obj
		if(data.status == "OK") then 
			callback(data.result)
		else 
			print("Error updating round: ", data.results)
		end 
	end, bodystr)
end 

-- ---------------------------------------------------------------------------

local function waiting(self)

	local ok, resp = check_connect(self) 
	if(ok == nil) then print(resp.status); return nil end 
	if(self.game == nil) then pprint("Invalid Game: ", self.game); return end 
	
	local body = make_requestgamestate( self.swp_client, self.game_name, self.device_id )
	body.state = self.game.state or GAME.GAME_JOINING
	body.event = USER_EVENT.REQUEST_WAITING
	local bodystr = json.encode(body)
	pprint("WAITING: "..tostring(body.state))
	swampy.game_update( self.swp_client, self.game_name, self.device_id, function(data)

		-- The game is returned on start - use this for game obj
		if(data.status ~= "OK") then 
			print("Error updating scenario: ", data.results)
		end 
	end, bodystr)
end 

-- ---------------------------------------------------------------------------

local function doupdate(self, callback)

	updategame(self, function(data) 

		-- Replace incoming data for the game object 
		if(data) then 
			self.game = data

			if(self.game) then 
				updategamestate(self, function(data)
				self.round = tmerge(self.round, data)
				if(callback) then callback(data) end
				if(self.game == nil or self.game.state == nil) then return end
				if(self.gamestate ~= self.game.state) then 
				end
			end)
			end
			
		-- Something has kicked us out return to previous page
		else
			self.swp_account = nil 
			self.game = nil
		end
	end)
end 

-- ---------------------------------------------------------------------------
-- Just a wrapper in case want to insert extra functionality
local function findgame( self, gamename, callback )

	local ok, resp = check_connect(self) 
	if(ok == nil) then callback(resp); return nil end 
	
	swampy.game_find( self.swp_client, gamename, self.device_id, callback, nil )
end

-- ---------------------------------------------------------------------------
-- Just a wrapper in case want to insert extra functionality
local function creategame( self, gamename, callback )

	local ok, resp = check_connect(self) 
	if(ok == nil) then callback(resp); return nil end 
	
	local limit = 10 -- 10 players - this is not being used in MyGame.
	swampy.game_create( self.swp_client, gamename, self.device_id, limit, function(data)
		self.game_name = gamename 
		callback(data)
	end )
end

-- ---------------------------------------------------------------------------

local function joingame( self, gamename, callback )

	local ok, resp = check_connect(self) 
	if(ok == nil) then callback(resp); return nil end 
	
	swampy.game_join( self.swp_client, gamename, self.device_id, function(data)
		self.game_name = gamename 
		callback(data)
	end, nil )
end

-- ---------------------------------------------------------------------------

local function leavegame( self, gamename, callback )

	local ok, resp = check_connect(self) 
	if(ok == nil) then callback(resp); return nil end 
	
	swampy.game_leave( self.swp_client, gamename, self.device_id, callback, nil )
end

-- ---------------------------------------------------------------------------

local function closegame( self, gamename, callback )

	local ok, resp = check_connect(self) 
	if(ok == nil) then callback(resp); return nil end 
	
	swampy.game_close( self.swp_client, gamename, self.device_id, callback, nil )
end

-- ---------------------------------------------------------------------------
return {
	setup 			= setup_swampy,
	login 			= device_login,
	connect 		= connect,
	updateaccount 	= updateaccount,
	resetclient		= resetclient,

	creategame 		= creategame,
	findgame		= findgame,
	joingame		= joingame,
	leavegame		= leavegame,
	closegame		= closegame,
	
	updategame		= updategame,
	pollgame		= pollgame,
	doupdate		= doupdate,
	updateready		= updateready,
	startgame		= startgame,
	exitgame		= exitgame,

	updateround 	= updateround,

	waiting 		= waiting,
}

-- ---------------------------------------------------------------------------