
local json = require "swampy.utils.json"
local url  = require "swampy.utils.url"

-- ---------------------------------------------------------------------------

local swampy = {
	GAME_MODULENAME		= "MyGame",				-- Default dummy game module
}

local end_points = {
	user 	= {
		login 			= "/user/login", 		--%?userid={name}&uid={device_uid}",
		authenticate 	= "/user/authenticate", --%?logintoken={token}&uid={device_uid}",
		connect 		= "/user/connect", 		--%?logintoken={token}&uid={device_uid}",
		update 			= "/user/update", 		--%?playername={playername}&uid={device_uid}&lang={lang_tag}&username={username}
	},
	data 	= {
		gettable 		= "/data/gettable", 	--%?name={dbname}&limit={row_limit}",
		settable 		= "/data/settable", 	--%?name={dbname}",  + body of data
	},
	game 	= {
		create 			= "/game/create",		-- ?name={game_name}&uid={device_id}&limit={max_players}
		find 			= "/game/find",			-- ?name={game_name}&uid={device_id}
		join 			= "/game/join",			-- ?name={game_name}&uid={device_id}
		leave 			= "/game/leave",		-- ?name={game_name}&uid={device_id}
		update 			= "/game/update",		-- ?name={game_name}&uid={device_id}
		close 			= "/game/close",		-- ?name={game_name}&uid={device_id}
	},
}

-- ---------------------------------------------------------------------------

local function genname()
	m,c = math.random,("").char 
	name = ((" "):rep(9):gsub(".",function()return c(("aeiouy"):byte(m(1,6)))end):gsub(".-",function()return c(m(97,122))end))
	return(string.sub(name, 1, math.random(4) + 5))
end

-- ---------------------------------------------------------------------------

local function setmodulename( name )
	swampy.GAME_MODULENAME = name
end

-- ---------------------------------------------------------------------------
-- TODO: Make a nice way to do blocking requests
local function http_request(url, method, header)
	local co = coroutine.running()
	print("fetching...", url, method, header)
	http.request(url, method, function(self, id, response)
		print('result is fetched')
		coroutine.resume(co, response)
	end, header)
	return coroutine.yield()
end

local function http_req_blocking( url, method, header )

	local co = coroutine.create(function()
		print('request is executed')
		local response = http_request(url, method, header)
		print('should not be executed before fetched result')
	end)

	local ok, err = coroutine.resume(co)
	print(ok, err)
	co2 = coroutine.running()
	pprint(co2)
-- 	while(ok == true) do
-- 		co2 = coroutine.running()
-- 		print(ok, err)
-- 	end
end 

-- ---------------------------------------------------------------------------
-- TODO: If a relatime port is needed we will use this 
--
-- function init(self)
-- 	self.url = "ws://echo.websocket.org"
-- 	local params = {
-- 		timeout = 3000,
-- 		headers = "Sec-WebSocket-Protocol: chat\r\nOrigin: mydomain.com\r\n"
-- 	}
-- 	self.connection = websocket.connect(self.url, params, websocket_callback)
-- end
-- 
-- -- ---------------------------------------------------------------------------
-- 
-- function finalize(self)
-- 	if self.connection ~= nil then
-- 		websocket.disconnect(self.connection)
-- 	end
-- end
-- 

-- ---------------------------------------------------------------------------

local function http_result(self, _, response)
	print(response.status)
	print(response.response)
	pprint(response.headers)
end

-- ---------------------------------------------------------------------------

local function create_client(cfg) 

	local client = cfg 
	client.method = cfg.method or "GET"
	client.scheme = "http://"
	if(cfg.use_ssl) then client.scheme = "https://" end
	client.uri = client.scheme..client.host..":"..client.port
	client.base_path = "/api/v1/"
	client.api_token = cfg.api_token
	client.handler = http_result
	return client 
end 

-- ---------------------------------------------------------------------------

local function makeHeader(client) 
	local header = { 
		["Authorization"] = client.bearertoken or "",
		["APIToken"] = client.api_token,
	}
	return header
end 	

-- ---------------------------------------------------------------------------

local function do_login( client, userid, device_id, callback )

	local fail = nil
	if(userid == nil) then fail = true end
	if(device_id == nil) then fail = true end

	if(fail == true) then  
		callback(nil, nil, { response = json.encode( { status = 'ERR' } ) } )
		return
	end

	local qlogin = url.parse(client.uri..client.base_path..end_points.user.login)
	qlogin.query.userid = userid
	qlogin.query.uid = device_id

	-- store in client for caching 
	client.uid = userid 
	client.device_id = device_id 

	local header = makeHeader(client)
	
	-- We do a quick handshake to create a bearer token.
	http.request(tostring(qlogin), client.method, function(self, _, response)

		if(response.response and string.len(response.response) > 0) then 
			local resp = json.decode(response.response)
			local qauth = url.parse(client.uri..client.base_path..end_points.user.authenticate)
			qauth.query.logintoken = resp.uuid
			qauth.query.uid = device_id 
		
			http.request(tostring(qauth), client.method, callback)
		else 
			-- If this occurs, then the request failed for some reason.
			callback(nil, nil, { response = json.encode( { status = 'ERR' } ) } )
		end
	end, header)
end

-- ---------------------------------------------------------------------------

local function connect(client, name, device_id, callback) 

	local qtable = url.parse(client.uri..client.base_path..end_points.user.connect)
	qtable.query.module = swampy.GAME_MODULENAME
	qtable.query.name = name or genname()
	qtable.query.uid = device_id

	local header = makeHeader(client)

	http.request(tostring(qtable), client.method, function(self, _, resp)
		
		if(resp.response) then 
			local respdata = json.decode(resp.response)
			callback(respdata)
		end
	end, header)
end

-- ---------------------------------------------------------------------------

local function get_table( client, name, limit, callback )

	local qtable = url.parse(client.uri..client.base_path..end_points.data.gettable)
	qtable.query.name = name
	qtable.query.limit = limit

	local header = makeHeader(client)

	http.request(tostring(qtable), client.method, function(self, _, resp)

		if(resp.response) then 
			callback(resp)
		end
	end, header)
end

-- ---------------------------------------------------------------------------

local function set_table( client, name, data, callback )

	local qtable = url.parse(client.uri..client.base_path..end_points.data.settable)
	qtable.query.name = name

	if(type(data) ~= "string") then return nil end
	body = data		-- must be string
	
	local header = makeHeader(client)

	http.request(tostring(qtable), "POST", function(self, _, resp)

		if(resp.response) then 
			callback(resp)
		end
	end, header, body)
end

-- ---------------------------------------------------------------------------

local function set_bearer_token( client, btoken )

	client.bearertoken = btoken 
end

-- ---------------------------------------------------------------------------

local function update_user( client, device_id, playername, lang_tag, callback )

	local quser = url.parse(client.uri..client.base_path..end_points.user.update)
	quser.query.playername = playername 
	quser.query.lang = lang_tag
	quser.query.uid = device_id

	local header = makeHeader(client)
	
	http.request(tostring(quser), client.method, function(self, _, resp)

		if(resp.response) then 
			local respdata = json.decode(resp.response)
			callback(respdata)
		end
	end, header)
end 

-- ---------------------------------------------------------------------------

local function game_create( client, gamename, device_id, limit, callback )

	local qgame = url.parse(client.uri..client.base_path..end_points.game.create)
	qgame.query.name = gamename
	qgame.query.uid = device_id
	qgame.query.limit = limit

	local header = makeHeader(client)

	http.request(tostring(qgame), client.method, function(self, _, resp)

		if(resp.response) then 
			local respdata = json.decode(resp.response)
			callback(respdata)
		end
	end, header)
end 

-- ---------------------------------------------------------------------------

local function game_func( client, ep, gamename, device_id, callback, body )

	local qgame = url.parse(client.uri..client.base_path..ep)
	qgame.query.name = gamename 
	qgame.query.uid = device_id
	-- qgame.query.tick = os.time()

	local header = makeHeader(client)
	local method = client.method 
	if(body) then method = "POST" end

	-- Special blocking requests - should rarely be used!!!
	-- if(callback == nil) then 
	-- 	print("Blocking request")
	-- 	http_req_blocking(tostring(qgame), method, header)
	-- else
		http.request(tostring(qgame), method, function(self, _, resp)

			if(resp.response) then 
				local respdata = nil 
				if(resp.response) then respdata = json.decode(resp.response) end
				callback(respdata)
			end
		end, header, body)
	-- end 
end 

-- ---------------------------------------------------------------------------

return {

	setmodulename		= setmodulename,		-- Set the module name that is to be used
	create_client 		= create_client,		-- create client http connect details
	do_login 			= do_login,				-- handshake and create a bearertoken which is device + uid
	connect 			= connect,				-- create a username <-> device + uid
	set_bearer_token	= set_bearer_token,		-- set client bearertoken from server login
	update_user 		= update_user,			-- set user details (name, lang etc)

	get_table 			= get_table,			-- get a table from the server
	set_table 			= set_table,			-- set a table on the server

	game_create 		= game_create,
	game_find 			= function(c, gn, uid, cb, body) game_func(c, end_points.game.find, gn, uid, cb, body) end,
	game_join 			= function(c, gn, uid, cb, body) game_func(c, end_points.game.join, gn, uid, cb, body) end,
	game_leave 			= function(c, gn, uid, cb, body) game_func(c, end_points.game.leave, gn, uid, cb, body) end,
	game_update 		= function(c, gn, uid, cb, body) game_func(c, end_points.game.update, gn, uid, cb, body) end,
	game_close			= function(c, gn, uid, cb, body) game_func(c, end_points.game.close, gn, uid, cb, body) end,
}
-- ---------------------------------------------------------------------------
