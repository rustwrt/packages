-- Experimental account/session helper for OpenWrt. API is unofficial.
-- Invoke via /usr/sbin/warp-reg so umask, tmpfs and flock protections apply.
local cjson = require('cjson')
local root, accounts = '/tmp/warp', '/etc/warp-reg/accounts'
local bind_config = ''
local function die(s) io.stderr:write('warp-reg: ',s,'\n'); os.exit(1) end
local function name_ok(s) return type(s)=='string' and #s>=1 and #s<=32 and s:match('^[%w_%-]+$')~=nil end
local function uuid_ok(s)
 if type(s)~='string' then return false end
 local a,b,c,d,e=s:match('^(%x+)%-(%x+)%-(%x+)%-(%x+)%-(%x+)$')
 return a~=nil and #a==8 and #b==4 and #c==4 and #d==4 and #e==12
end
local function shell(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
local function config_quote(s) return '"' .. s:gsub('\\','\\\\'):gsub('"','\\"') .. '"' end
local function interface_config(dev)
 if not dev or dev=='' then return '' end
 if type(dev)~='string' or #dev>15 or not dev:match('^[A-Za-z0-9_.%-]+$') then return nil end
 return 'interface = '..config_quote('if!'..dev)..'\n'
end
local function read(path,limit)
 local f=io.open(path,'rb');if not f then return nil end
 local s=f:read((limit or 1048576)+1);f:close();if not s or #s>(limit or 1048576) then return nil end;return s
end
local function write(path,data)
 local f=io.open(path,'wb');if not f then return false end
 local ok=f:write(data);if not ok then f:close();return false end
 return f:close() ~= nil
end
local function decode(raw)
 if not raw then return nil end
 local ok,v=pcall(cjson.decode,raw);if not ok or type(v)~='table' then return nil end;return v
end
local function valid_account(a)
 return type(a)=='table' and uuid_ok(a.device_id) and type(a.access_token)=='string' and #a.access_token>=8 and #a.access_token<=4096 and not a.access_token:find('%c')
end
local function load_account(name)
 if not name_ok(name) then return nil end
 local a=decode(read(accounts..'/'..name..'.json',65536));if valid_account(a) then return a end
end
local function new_temp()
 local p=io.popen('umask 077; mktemp -d '..shell(root..'/.request.XXXXXXXX')..' 2>/dev/null','r')
 if not p then return nil end
 local d=p:read('*l');p:close()
 if not d or not d:match('^/tmp/warp/%.request%.[%w]+$') then return nil end
 return d
end
local function remove_request(dir)
 if not dir or not dir:match('^/tmp/warp/%.request%.[%w]+$') then return end
 os.remove(dir..'/response');os.remove(dir..'/status');os.remove(dir..'/private.key')
 os.execute('rmdir '..shell(dir)..' 2>/dev/null')
end
local function api(a, method, payload)
 local dir=new_temp();if not dir then return '000',nil end
 local cmd='umask 077; curl -q --silent --connect-timeout 10 --max-time 25 --config - --output '..shell(dir..'/response')..' --write-out "%{http_code}" > '..shell(dir..'/status')..' 2>/dev/null; printf " %s" "$?" >> '..shell(dir..'/status')
 local p=io.popen(cmd,'w');if not p then remove_request(dir);return '000',nil end
 local url='https://api.cloudflareclient.com/v0a5641/reg';if a then url=url..'/'..a.device_id end
 p:write('url = ',config_quote(url),'\n')
 if bind_config~='' then p:write(bind_config) end
 p:write('user-agent = "1.1.1.1/6.38.9-5641 (Android 16.0.0)"\nnoproxy = "*"\nheader = "CF-Client-Version: a-6.38.9-5641"\nheader = "Accept: application/json"\n')
 if a then p:write('header = ',config_quote('Authorization: Bearer '..a.access_token),'\n') end
 if method~='GET' then
  p:write('request = ',config_quote(method),'\nheader = "Content-Type: application/json"\n')
  if payload then p:write('data = ',config_quote(cjson.encode(payload)),'\n') end
 end
 p:close()
 local result=read(dir..'/status',16) or '';local response=decode(read(dir..'/response',1048576));remove_request(dir)
 local status,rc=result:match('^(%d%d%d) (%d+)$')
 if not status then return '000',nil,nil end
 return status,response,tonumber(rc)
end
local function error_suffix(code,rc)
 if code=='000' and type(rc)=='number' and rc>=0 and rc<=255 then return ' (curl '..rc..')' end
 return ' (HTTP '..code..')'
end
local function check_http(code,op,rc)
 if code=='200' or code=='204' then return end
 if code=='429' then die(op..': API rate limit; retry later') end
 if code=='401' then die(op..': invalid authentication (HTTP 401)') end
 if code=='403' then die(op..': access denied (HTTP 403)') end
 if code=='000' then die(op..': TLS or network error'..error_suffix(code,rc)) end
 die(op..': HTTP '..code)
end
local function valid_key(s)
 return type(s)=='string' and #s==44 and s:match('^[A-Za-z0-9+/]+=$')~=nil
  and ('AEIMQUYcgkosw048'):find(s:sub(43,43),1,true)~=nil
end
local function valid_client_id(s)
 return type(s)=='string' and #s==4 and s:match('^[A-Za-z0-9+/]+$')~=nil
end
local function generate(dir)
 local result=os.execute('umask 077; wg genkey > '..shell(dir..'/private.key')..' 2>/dev/null')
 if result~=0 and result~=true then return nil end
 local p=io.popen('wg pubkey < '..shell(dir..'/private.key')..' 2>/dev/null','r');if not p then return nil end
 local pub=p:read('*l');p:close()
 if not valid_key(pub) then return nil end
 return pub
end
local function ipv4(s)
 if type(s)~='string' then return false end
 local a,b,c,d=s:match('^(%d+)%.(%d+)%.(%d+)%.(%d+)$')
 return a~=nil and tonumber(a)<=255 and tonumber(b)<=255 and tonumber(c)<=255 and tonumber(d)<=255
end
local function ipv6(s)
 if type(s)~='string' or s:find('[^%x:]') or not s:find(':',1,true) or s:find(':::',1,true) then return false end
 local _,compressed=s:gsub('::','')
 if compressed>1 then return false end
 if s:sub(1,1)==':' and s:sub(1,2)~='::' then return false end
 if s:sub(-1)==':' and s:sub(-2)~='::' then return false end
 local count=0
 for part in s:gmatch('[^:]+') do
  if #part>4 then return false end
  count=count+1
 end
 return (compressed==1 and count<8) or (compressed==0 and count==8)
end
local function session_data(data,privatepath)
 local cfg=type(data)=='table' and data.config;local it=type(cfg)=='table' and cfg.interface
 local addresses=type(it)=='table' and it.addresses;local p=type(cfg)=='table' and type(cfg.peers)=='table' and cfg.peers[1]
 local ep=type(p)=='table' and p.endpoint
 if type(addresses)~='table' or not ipv4(addresses.v4) or type(ep)~='table' then return nil end
 if addresses.v6~=nil and not ipv6(addresses.v6) then return nil end
 if not valid_key(p.public_key) then return nil end
 local host,port;if type(ep.v4)=='string' then host,port=ep.v4:match('^(%d+%.%d+%.%d+%.%d+):(%d+)$') end
 if not host or not ipv4(host) then return nil end
 port=tonumber(port);if port==0 then port=tonumber(type(ep.ports)=='table' and ep.ports[1]) or 2408 end
 if not port or port<1 or port>65535 or port%1~=0 then return nil end
 if not valid_client_id(cfg.client_id) then return nil end
 return {ipv4=addresses.v4,ipv6=addresses.v6,peer=p.public_key,endpoint=host..':'..port,client_id=cfg.client_id,private_key_file=privatepath}
end
-- Registration overrides are ephemeral: they are accepted only for this
-- request and are never placed in UCI or command-line arguments.
local function registrationPayload(input,publicKey)
 if input==nil then input={} end
 if type(input)~='table' then die('invalid registration parameters') end
 local function textField(name,default,maxLength)
  local value=input[name]
  if value==nil or value=='' then return default end
  if type(value)~='string' or #value>maxLength or value:find('%c') then die('invalid registration parameter: '..name) end
  return value
 end
 local tos=os.date('!%Y-%m-%dT%H:%M:%SZ')
 if not tos:match('^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$') then die('invalid registration timestamp') end
 return {
  key=publicKey, install_id=textField('install_id','',256), fcm_token='',
  tos=tos, type=textField('type','Android',64), model=textField('model','PC',128),
  locale=textField('locale','en_US',32), warp_enabled=true,
  serial_number=textField('serial_number','',256), os_version=textField('os_version','16.0.0',64),
  key_type='curve25519', tunnel_type='wireguard'
 }
end
local function registerAccount(path,options,retainUnverified)
 if read(path,65536) then die('account already exists') end
 local payload=registrationPayload(options,nil)
 local publicKey=options and options.key
 if publicKey~=nil and publicKey~='' then
  if not valid_key(publicKey) or publicKey==string.rep('A',43)..'=' then die('invalid registration public key') end
 else publicKey=nil end
 local dir=new_temp();if not dir then die('cannot create registration workspace') end
 local generated=false
 if not publicKey then publicKey=generate(dir);generated=publicKey~=nil end
 if not publicKey then remove_request(dir);die('key generation failed') end
 -- The registration private key is needed only to derive its public key.
 -- Delete it before sending any request; do not create an unmanaged account
 -- if its temporary private key cannot be removed.
 if generated and not os.remove(dir..'/private.key') then remove_request(dir);die('cannot remove temporary registration key') end
 remove_request(dir)
 payload.key=publicKey
 local code,response,rc=api(nil,'POST',payload)
 if code~='200' and code~='201' then check_http(code,'register account',rc) end
 local account=type(response)=='table' and {device_id=response.id,access_token=response.token}
 if not valid_account(account) then die('invalid registration response') end
 local function saveAccount()
  local temporaryPath=path..'.new'
  if not write(temporaryPath,cjson.encode(account)) or not os.rename(temporaryPath,path) then os.remove(temporaryPath);die('cannot store registered account') end
 end
 -- Preserve credentials before verification for managed per-connection accounts.
 -- A later GET failure must not discard a successful registration.
 if retainUnverified then saveAccount() end
 local verifyCode,verified=api(account,'GET')
 if verifyCode~='200' or type(verified)~='table' or verified.id~=account.device_id or verified.key~=publicKey or not session_data(verified,'') then die('registered account could not be verified') end
 if not retainUnverified then saveAccount() end
 return account
end
-- Persist attempts before contacting Cloudflare and retain a cooldown across
-- reboot or timeout; previously recorded attempts remain intact.
local function reserveFreshRegistration()
 local path='/etc/warp-reg/fresh-attempts.json'
 local raw=read(path,65536)
 local ledger
 if raw then ledger=decode(raw)
 else
  local exists=io.open(path,'rb');if exists then exists:close();die('registration ledger unavailable') end
  ledger={entries={}}
 end
 if not ledger or type(ledger.entries)~='table' then die('invalid registration ledger') end
 local now=os.time()
 if type(now)~='number' or now<1577836800 then die('system clock required for registration limit') end
 local count,last=0,0
 for index,entry in pairs(ledger.entries) do
  if type(index)~='number' or index<1 or index%1~=0 or type(entry)~='table' or type(entry.at)~='number' or entry.at%1~=0 or type(entry.account)~='string' or not entry.account:match('^auto%-%d+%-%d+$') or entry.at>now then die('invalid registration ledger') end
  count=count+1
  if entry.at>last then last=entry.at end
 end
 for i=1,count do if not ledger.entries[i] then die('invalid registration ledger') end end
 if last>0 and now-last<60 then
  local delay=60-(now-last)
  io.stderr:write('warp-reg: registration cooldown; waiting ',tostring(delay),' seconds\n')
  local waited=os.execute('sleep '..tostring(delay))
  if waited~=0 and waited~=true then die('registration cooldown interrupted') end
  now=os.time()
  if type(now)~='number' or now-last<60 then die('registration cooldown; retry later') end
 end
 local reference='auto-'..tostring(now)..'-'..tostring(count+1)
 local accountPath=accounts..'/'..reference..'.json'
 local existing=io.open(accountPath,'rb');if existing then existing:close();die('registration account already exists') end
 ledger.entries[#ledger.entries+1]={at=now,account=reference}
 local tmp=path..'.new'
 if not write(tmp,cjson.encode(ledger)) or not os.rename(tmp,path) then os.remove(tmp);die('cannot persist registration limit') end
 return accountPath,reference
end
-- Keep the registration-to-interface association on persistent storage.  The
-- binding is written before POST, so a credential stored after a successful
-- POST can be recovered even if verification or setup fails or power is lost.
local function interfaceAccount(iface)
 local bindingPath='/etc/warp-reg/binding-'..iface..'.json'
 local raw=read(bindingPath,4096)
 if raw then
  local binding=decode(raw)
  if not binding or type(binding.account)~='string' or not binding.account:match('^auto%-%d+%-%d+$') or not name_ok(binding.account) then
   die('invalid interface account binding')
  end
  local path=accounts..'/'..binding.account..'.json'
  local stored=read(path,65536)
  if stored then
   local account=decode(stored)
   if not valid_account(account) then die('saved interface account is invalid') end
   return account
  end
  local file=io.open(path,'rb')
  if file then file:close();die('saved interface account is unreadable') end
 else
  local file=io.open(bindingPath,'rb')
  if file then file:close();die('interface account binding is unreadable') end
 end
 local profile={} -- fixed automatic defaults; legacy UCI fields are ignored
 local accountPath,reference=reserveFreshRegistration()
 local tmp=bindingPath..'.new'
 if not write(tmp,cjson.encode({account=reference})) or not os.rename(tmp,bindingPath) then
  os.remove(tmp);die('cannot store interface account binding')
 end
 return registerAccount(accountPath,profile,true)
end
local command, name, extra, device, owner = arg[1],arg[2],arg[3],arg[4],arg[5]
if command=='ui-generate' or command=='ui-import' then
 local request=decode(io.read(8193))
 if not request then die('invalid request') end
 local dir=new_temp();if not dir then die('workspace unavailable') end
 local account,verified
 if command=='ui-generate' then
  local profile=request.registration
  account=registerAccount(dir..'/account.json',profile)
  os.remove(dir..'/account.json')
 else
  local token=request.account_id_token
  if type(token)~='string' or #token>6144 then remove_request(dir);die('invalid credential') end
  account=decode(token)
  if not valid_account(account) or account.version~=1 then remove_request(dir);die('invalid credential') end
 end
 local code
 code,verified=api(account,'GET')
 if code~='200' or type(verified)~='table' or verified.id~=account.device_id or not session_data(verified,'') then remove_request(dir);die('credential verification failed') end
 local accountId=type(verified.account)=='table' and verified.account.id or nil
 if not uuid_ok(accountId) then remove_request(dir);die('account identity unavailable') end
 if account.account_id and account.account_id~=accountId then remove_request(dir);die('account identity mismatch') end
 local envelope={version=1,account_id=accountId,device_id=account.device_id,access_token=account.access_token}
 local reference=account.device_id:lower():gsub('%-','')
 local path=accounts..'/'..reference..'.json'
 local existing=decode(read(path,65536))
 if existing and (existing.device_id~=account.device_id or existing.access_token~=account.access_token) then remove_request(dir);die('credential conflict') end
 if not existing and (not write(path..'.new',cjson.encode(envelope)) or not os.rename(path..'.new',path)) then os.remove(path..'.new');remove_request(dir);die('credential storage failed') end
 remove_request(dir)
 print(cjson.encode({account=reference,account_id_token=command=='ui-generate' and cjson.encode(envelope) or nil}))
 return
end
if command=='register' then device=extra end
local randomMode=command=='random-session'
local freshMode=command=='fresh-session'
if command=='session' or randomMode or freshMode or command=='register' then
 bind_config=interface_config(device)
 if not bind_config then die('invalid underlying network device') end
 if owner and owner~='' and (not owner:match('^%d+$') or #owner>12) then die('invalid session owner') end
end
if not name_ok(name) then die('invalid account name') end
if command=='register' then
 registerAccount(accounts..'/'..name..'.json')
 print('account registered')
elseif command=='import' then
 local raw=io.read(65537);if not raw or #raw>65536 then die('invalid account input') end
 local a=decode(raw)
 if not a then
  a={};for line in raw:gmatch('[^\r\n]+') do
   local k,v=line:match([=[^%s*([%w_]+)%s*=%s*["']([^"']+)["']]=])
   if k=='device_id' or k=='access_token' then a[k]=v end
  end
 end
 raw=nil;if not valid_account(a) then die('device_id and access_token are required') end
 local path=accounts..'/'..name..'.json';local exists=io.open(path,'rb');if exists then exists:close();die('account already exists') end
 local code,device=api(a,'GET');check_http(code,'verify account')
 if type(device)~='table' or device.id~=a.device_id then die('account identity could not be verified') end
 local tmp=path..'.new';if not write(tmp,cjson.encode({device_id=a.device_id,access_token=a.access_token})) then os.remove(tmp);die('cannot store account') end
 if not os.rename(tmp,path) then os.remove(tmp);die('cannot store account') end
 print('account imported')
elseif command=='status' then
 local a=load_account(name);if not a then die('account not found or invalid') end
 local code,data=api(a,'GET');check_http(code,'read account')
 if type(data)~='table' then die('invalid API response') end
 print(cjson.encode({device_id_masked=a.device_id:sub(1,4)..'...'..a.device_id:sub(-4),enabled=data.enabled==true,registered=true}))
elseif command=='session' or randomMode or freshMode then
 if not name_ok(extra) then die('invalid interface name') end
 local a
 if freshMode then
  name='fresh-'..extra
  if read(root..'/account-'..name..'.lease',128) or read(root..'/session-'..extra..'/owner',128) then die('session is already in use') end
  a=interfaceAccount(extra)
 elseif randomMode then
  name='random-'..extra
  local randomPath=root..'/'..name..'.json'
  a=decode(read(randomPath,65536))
  if a and not valid_account(a) then die('invalid random account') end
  if not a then a=registerAccount(randomPath) end
 else a=load_account(name) end
 if not a then die('account not found or invalid') end
 local dest=root..'/session-'..extra
 local lease=root..'/account-'..name..'.lease'
 if read(lease,128) then die('account is already in use by another session') end
  local made=os.execute('umask 077; mkdir '..shell(dest)..' 2>/dev/null')
  if made~=0 and made~=true then die('session exists or cannot be created') end
 if owner and owner~='' and not write(dest..'/owner',owner) then os.execute('rmdir '..shell(dest)..' 2>/dev/null');die('cannot reserve session') end
 if not write(lease,extra) then os.remove(dest..'/owner');os.execute('rmdir '..shell(dest)..' 2>/dev/null');die('cannot reserve account') end
 local function fail(msg) os.remove(dest..'/private.key');os.remove(dest..'/session.json');os.remove(dest..'/underlay.route');os.remove(dest..'/health4');os.remove(dest..'/health6');os.remove(dest..'/health-state');os.remove(dest..'/owner');os.execute('rmdir '..shell(dest)..' 2>/dev/null');os.remove(lease);die(msg) end
  local before_code,before,before_rc=api(a,'GET');if before_code~='200' or type(before)~='table' or before.id~=a.device_id then fail('cannot read account'..error_suffix(before_code,before_rc)) end
 local pub=generate(dest);if not pub then fail('key generation failed') end
 local code,_,patch_rc=api(a,'PATCH',{key=pub});if code~='200' and code~='204' then fail('key update failed'..error_suffix(code,patch_rc)) end
  local verify_code,after,verify_rc=api(a,'GET');if verify_code~='200' or type(after)~='table' or after.id~=a.device_id or after.key~=pub then fail('new key could not be verified'..error_suffix(verify_code,verify_rc)) end
 local data=session_data(after,dest..'/private.key');if not data then fail('incomplete or invalid WARP config') end
  data.account=name
  data.account_mode=freshMode and 'fresh' or (randomMode and 'random' or 'custom')
  data.device_id_masked=a.device_id:sub(1,4)..'...'..a.device_id:sub(-4)
 data.started_at=os.time()
 if device and device~='' then data.underlay_device=device end
 if not write(dest..'/session.json',cjson.encode(data)) then fail('cannot store session config') end
 print('session created')
elseif command=='clear' then
 if not name_ok(extra) then die('invalid interface name') end
 local dest=root..'/session-'..extra;local lease=root..'/account-'..name..'.lease'
 if read(lease,128)~=extra then die('account does not own this session') end
 local sessionOwner=read(dest..'/owner',32)
 if sessionOwner and sessionOwner:match('^%d+$') then os.remove(root..'/public-refresh-'..extra..'-'..sessionOwner) end
 os.remove(dest..'/private.key');os.remove(dest..'/session.json');os.remove(dest..'/underlay.route');os.remove(dest..'/health4');os.remove(dest..'/health6');os.remove(dest..'/health-state');os.remove(dest..'/owner')
  local removed=os.execute('rmdir '..shell(dest)..' 2>/dev/null')
  if removed~=0 and removed~=true then die('cannot remove session or session does not exist') end
 os.remove(lease)
 print('session removed')
else die('supported commands: register, import, status, session, random-session, fresh-session, clear') end
