// Cloudflare WARP account/session helper. Invoke only via warp-reg (lock and umask).
import * as fs from 'fs';

const root = '/tmp/warp', accounts = '/etc/warp-reg/accounts';
let bind_config = '';
function die(s) { warn('warp-reg: ' + s + '\n'); exit(1); }
function str(s) { return type(s) == 'string'; }
function obj(s) { return type(s) == 'object'; }
function name_ok(s) { return str(s) && length(s) <= 32 && match(s, /^[A-Za-z0-9_][A-Za-z0-9_-]*$/); }
function uuid_ok(s) { return str(s) && match(s, /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/); }
function shell(s) { return "'" + replace(s, /'/g, "'\\''") + "'"; }
function config_quote(s) { return '"' + replace(replace(s, /\\/g, '\\\\'), /"/g, '\\"') + '"'; }
function interface_config(dev) {
    if (!dev) return '';
    if (!str(dev) || length(dev)>15 || !match(dev, /^[A-Za-z0-9_.-]+$/)) return null;
    return 'interface = ' + config_quote('if!' + dev) + '\n';
}
function read_file(path, limit) {
    let f = fs.open(path, 'r');
    if (!f) return null;
    let data = f.read(limit+1); f.close();
    return str(data) && length(data)<=limit ? data : null;
}
function write_file(path, data) {
    let f = fs.open(path, 'w', 0600);
    if (!f) return false;
    let n = f.write(data), ok = f.close();
    return n == length(data) && ok;
}
function decode(raw) {
    if (!str(raw)) return null;
    try { let v = json(raw); return obj(v) ? v : null; } catch(e) { return null; }
}
function read_json(path,limit) { return decode(read_file(path,limit)); }
function save_json(path,data) {
    let tmp=path+'.new';
    if (write_file(tmp,sprintf('%J',data)) && fs.rename(tmp,path)) return true;
    fs.unlink(tmp); return false;
}
function valid_account(a) {
    return obj(a) && uuid_ok(a.device_id) && str(a.access_token) && length(a.access_token)>=8 &&
        length(a.access_token)<=4096 && !match(a.access_token, /[[:cntrl:]]/);
}
function load_account(name) {
    let a = name_ok(name) ? read_json(accounts+'/'+name+'.json',65536) : null;
    return valid_account(a) ? a : null;
}
function new_temp() { return fs.mkdtemp(root+'/.request.XXXXXX'); }
function remove_request(dir) {
    if (!str(dir) || !match(dir,/^\/tmp\/warp\/[.]request[.][A-Za-z0-9]+$/)) return;
    for (let file in ['response','status','private.key','account.json']) fs.unlink(dir+'/'+file);
    fs.rmdir(dir);
}
function api(a, method, payload) {
    let dir=new_temp();
    if (!dir) return ['000',null,null];
    let cmd='umask 077; curl -q --silent --connect-timeout 10 --max-time 25 --config - --output '+shell(dir+'/response')+
        ' --write-out "%{http_code}" > '+shell(dir+'/status')+' 2>/dev/null; printf " %s" "$?" >> '+shell(dir+'/status');
    let p=fs.popen(cmd,'w');
    if (!p) { remove_request(dir); return ['000',null,null]; }
    let url='https://api.cloudflareclient.com/v0a5641/reg'+(a ? '/'+a.device_id : '');
    let cfg='url = '+config_quote(url)+'\n'+bind_config+
        'user-agent = "1.1.1.1/6.38.9-5641 (Android 16.0.0)"\nnoproxy = "*"\nheader = "CF-Client-Version: a-6.38.9-5641"\nheader = "Accept: application/json"\n';
    if (a) cfg+='header = '+config_quote('Authorization: Bearer '+a.access_token)+'\n';
    if (method!='GET') {
        cfg+='request = '+config_quote(method)+'\nheader = "Content-Type: application/json"\n';
        if (payload) cfg+='data = '+config_quote(sprintf('%J',payload))+'\n';
    }
    p.write(cfg); p.close();
    let status=match(read_file(dir+'/status',16)||'',/^([0-9]{3}) ([0-9]+)$/);
    let response=read_json(dir+'/response',1048576); remove_request(dir);
    return status ? [status[1],response,int(status[2])] : ['000',null,null];
}
function suffix(r) { return r[0]=='000' && r[2]!=null ? ' (curl '+r[2]+')' : ' (HTTP '+r[0]+')'; }
function check_http(r,op) {
    if (r[0]=='200'||r[0]=='204') return;
    if (r[0]=='429') die(op+': API rate limit; retry later');
    die(op+suffix(r));
}
function valid_key(s) { return str(s) && match(s,/^[A-Za-z0-9+\/]{42}[AEIMQUYcgkosw048]=$/); }
function generate(dir) {
    if (system('umask 077; wg genkey > '+shell(dir+'/private.key')+' 2>/dev/null')!=0) return null;
    let p=fs.popen('wg pubkey < '+shell(dir+'/private.key')+' 2>/dev/null','r');
    if (!p) return null;
    let key=trim(p.read(128)||''); if (p.close()!=0 || !valid_key(key)) return null;
    return key;
}
function ipv4(s) {
    if (!str(s)) return false;
    let m=match(s,/^([0-9]{1,3})[.]([0-9]{1,3})[.]([0-9]{1,3})[.]([0-9]{1,3})$/);
    return m && int(m[1])<=255 && int(m[2])<=255 && int(m[3])<=255 && int(m[4])<=255;
}
function ipv6(s) {
    if (!str(s)||!match(s,/^[0-9a-fA-F:]+$/)||index(s,':')<0||index(s,':::')>=0) return false;
    let parts=split(s,'::');
    if (length(parts)>2) return false;
    let count=0;
    for (let part in parts) {
        if (!part) continue;
        for (let group in split(part,':')) {
            if (!match(group,/^[0-9a-fA-F]{1,4}$/)) return false;
            count++;
        }
    }
    return length(parts)==2 ? count<8 : count==8;
}
function session_data(data,privatepath) {
    let cfg=obj(data)?data.config:null;
    let it=obj(cfg)?cfg.interface:null, addr=obj(it)?it.addresses:null;
    let p=obj(cfg)&&type(cfg.peers)=='array'?cfg.peers[0]:null;
    let ep=obj(p)?p.endpoint:null;
    if (!obj(addr)||!ipv4(addr.v4)||(addr.v6!=null&&!ipv6(addr.v6))||!obj(ep)||!valid_key(p.public_key)) return null;
    let m=str(ep.v4)?match(ep.v4,/^([0-9.]+):([0-9]+)$/):null;
    if (!m||!ipv4(m[1])) return null;
    let port=int(m[2]);
    if (!port) port=type(ep.ports)=='array' && ep.ports[0]!=null ? int(ep.ports[0]) : 2408;
    if (port<1||port>65535||!str(cfg.client_id)||!match(cfg.client_id,/^[A-Za-z0-9+\/]{4}$/)) return null;
    let out={ipv4:addr.v4,peer:p.public_key,endpoint:m[1]+':'+port,client_id:cfg.client_id,private_key_file:privatepath};
    if (addr.v6!=null) out.ipv6=addr.v6;
    return out;
}
function registration_payload(input,key) {
    if (input==null) input={};
    if (!obj(input)) die('invalid registration parameters');
    function field(name,def,max) {
        let v=input[name];
        if (v==null||v=='') return def;
        if (!str(v)||length(v)>max||match(v,/[[:cntrl:]]/)) die('invalid registration parameter: '+name);
        return v;
    }
    let p=fs.popen("date -u +%Y-%m-%dT%H:%M:%SZ",'r');
    let tos=p?trim(p.read(64)||''):'';
    if (!p||p.close()!=0||!match(tos,/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/)) die('invalid registration timestamp');
    return {key:key,install_id:field('install_id','',256),fcm_token:'',tos:tos,type:field('type','Android',64),
        model:field('model','PC',128),locale:field('locale','en_US',32),warp_enabled:true,
        serial_number:field('serial_number','',256),os_version:field('os_version','16.0.0',64),
        key_type:'curve25519',tunnel_type:'wireguard'};
}
function register_account(path,options,retain) {
    if (fs.stat(path)) die('account already exists');
    let payload=registration_payload(options,null);
    let key=options?options.key:null;
    if (key && (!valid_key(key)||match(key,/^A{43}=$/))) die('invalid registration public key');
    let dir=new_temp();
    if (!dir) die('cannot create registration workspace');
    if (!key) {
        key=generate(dir);
        if (!key||!fs.unlink(dir+'/private.key')) { remove_request(dir); die('key generation or cleanup failed'); }
    }
    remove_request(dir);
    payload.key=key;
    let r=api(null,'POST',payload);
    if (r[0]!='201') check_http(r,'register account');
    let a=obj(r[1])?{device_id:r[1].id,access_token:r[1].token}:null;
    if (!valid_account(a)) die('invalid registration response');
    if (retain && !save_json(path,a)) die('cannot store registered account');
    let v=api(a,'GET');
    if (v[0]!='200'||!obj(v[1])||v[1].id!=a.device_id||v[1].key!=key||!session_data(v[1],'')) die('registered account could not be verified');
    if (!retain && !save_json(path,a)) die('cannot store registered account');
    return a;
}
function reserve_fresh() {
    let path='/etc/warp-reg/fresh-attempts.json';
    let ledger=fs.stat(path)?read_json(path,65536):{entries:[]};
    if (!obj(ledger)||type(ledger.entries)!='array') die('invalid registration ledger');
    let now=time(), last=0;
    if (now<1577836800) die('system clock required');
    for (let entry in ledger.entries) {
        if (!obj(entry)||type(entry.at)!='int'||entry.at>now||!str(entry.account)||!match(entry.account,/^auto-[0-9]+-[0-9]+$/)) die('invalid registration ledger');
        if (entry.at>last) last=entry.at;
    }
    if (last && now-last<60) {
        let delay=60-(now-last);
        warn('warp-reg: registration cooldown; waiting '+delay+' seconds\n');
        if (system('sleep '+delay)!=0||time()-last<60) die('registration cooldown interrupted');
        now=time();
    }
    let reference='auto-'+now+'-'+(length(ledger.entries)+1);
    let accountPath=accounts+'/'+reference+'.json';
    if (fs.stat(accountPath)) die('registration account already exists');
    push(ledger.entries,{at:now,account:reference});
    if (!save_json(path,ledger)) die('cannot persist registration limit');
    return [accountPath,reference];
}
function interface_account(iface) {
    let binding='/etc/warp-reg/binding-'+iface+'.json';
    if (fs.stat(binding)) {
        let b=read_json(binding,4096);
        if (!obj(b)||!name_ok(b.account)||!match(b.account,/^auto-[0-9]+-[0-9]+$/)) die('invalid interface account binding');
        let path=accounts+'/'+b.account+'.json';
        if (fs.stat(path)) {
            let a=read_json(path,65536);
            if (!valid_account(a)) die('saved interface account is invalid');
            return a;
        }
    }
    let reservation=reserve_fresh();
    if (!save_json(binding,{account:reservation[1]})) die('cannot store interface account binding');
    return register_account(reservation[0],{},true);
}
function cleanup(dest) {
    for (let file in ['private.key','session.json','underlay.route','health4','health6','health-state','owner']) fs.unlink(dest+'/'+file);
    return fs.rmdir(dest);
}
function mask_id(id) { return substr(id,0,4)+'...'+substr(id,-4); }
function main(args) {
    let command=args[0],name=args[1],extra=args[2],device=args[3],owner=args[4];
    if (command=='register') device=extra;
    let randomMode=command=='random-session',freshMode=command=='fresh-session';
    if (command=='session'||randomMode||freshMode||command=='register') {
        bind_config=interface_config(device);
        if (bind_config==null) die('invalid underlying network device');
        if (owner&&(!match(owner,/^[0-9]+$/)||length(owner)>12)) die('invalid session owner');
    }
    if (command=='ui-generate'||command=='ui-import') {
        let raw=fs.stdin.read(8193),req=decode(raw);
        if (!str(raw)||length(raw)>8192||!req) die('invalid request');
        let a;
        if (command=='ui-generate') {
            let dir=new_temp(); if(!dir) die('workspace unavailable');
            a=register_account(dir+'/account.json',req.registration,false);
            remove_request(dir);
        } else {
            if (!str(req.account_id_token)||length(req.account_id_token)>6144) die('invalid credential');
            a=decode(req.account_id_token);
            if (!valid_account(a)||a.version!=1) die('invalid credential');
        }
        let v=api(a,'GET'),verified=v[1];
        if (v[0]!='200'||!obj(verified)||verified.id!=a.device_id||!session_data(verified,'')) die('credential verification failed');
        let id=obj(verified.account)?verified.account.id:null;
        if (!uuid_ok(id)||(a.account_id&&a.account_id!=id)) die('account identity mismatch');
        let envelope={version:1,account_id:id,device_id:a.device_id,access_token:a.access_token};
        let ref=replace(lc(a.device_id),/-/g,''),path=accounts+'/'+ref+'.json';
        let stored=read_json(path,65536);
        if (fs.stat(path)&&(!stored||stored.device_id!=a.device_id||stored.access_token!=a.access_token)) die('credential conflict');
        if (!stored&&!save_json(path,envelope)) die('credential storage failed');
        let response={account:ref};
        if(command=='ui-generate') response.account_id_token=sprintf('%J',envelope);
        printf('%J\n',response);
        return;
    }
    if (!name_ok(name)) die('invalid account name');
    if (command=='register') {
        register_account(accounts+'/'+name+'.json',null,false); print('account registered\n');
    } else if (command=='import') {
        let raw=fs.stdin.read(65537),a=decode(raw);
        if (!str(raw)||length(raw)>65536) die('invalid account input');
        if (!a) {
            a={};
            for (let line in split(raw,'\n')) {
                let m=match(line,/^[[:space:]]*(device_id|access_token)[[:space:]]*=[[:space:]]*["']([^"']+)["']/);
                if (m) a[m[1]]=m[2];
            }
        }
        if (!valid_account(a)) die('device_id and access_token are required');
        let path=accounts+'/'+name+'.json';
        if (fs.stat(path)) die('account already exists');
        let r=api(a,'GET'); check_http(r,'verify account');
        if (!obj(r[1])||r[1].id!=a.device_id) die('account identity could not be verified');
        if (!save_json(path,{device_id:a.device_id,access_token:a.access_token})) die('cannot store account');
        print('account imported\n');
    } else if (command=='status') {
        let a=load_account(name); if (!a) die('account not found or invalid');
        let r=api(a,'GET'); check_http(r,'read account');
        if (!obj(r[1])) die('invalid API response');
        printf('%J\n',{device_id_masked:mask_id(a.device_id),enabled:r[1].enabled==true,registered:true});
    } else if (command=='session'||randomMode||freshMode) {
        if (!name_ok(extra)) die('invalid interface name');
        let a;
        if (freshMode) {
            name='fresh-'+extra;
            if (fs.stat(root+'/account-'+name+'.lease')||fs.stat(root+'/session-'+extra+'/owner')) die('session is already in use');
            a=interface_account(extra);
        } else if (randomMode) {
            name='random-'+extra;
            let path=root+'/'+name+'.json';
            a=fs.stat(path)?read_json(path,65536):register_account(path,null,false);
        } else a=load_account(name);
        if (!valid_account(a)) die('account not found or invalid');
        let dest=root+'/session-'+extra,lease=root+'/account-'+name+'.lease';
        if (fs.stat(lease)) die('account is already in use by another session');
        if (!fs.mkdir(dest)) die('session exists or cannot be created');
        function fail(msg) { cleanup(dest); fs.unlink(lease); die(msg); }
        if (owner&&!write_file(dest+'/owner',owner)) { cleanup(dest); die('cannot reserve session'); }
        if (!write_file(lease,extra)) fail('cannot reserve account');
        let before=api(a,'GET');
        if (before[0]!='200'||!obj(before[1])||before[1].id!=a.device_id) fail('cannot read account'+suffix(before));
        let pub=generate(dest); if (!pub) fail('key generation failed');
        let r=api(a,'PATCH',{key:pub});
        if (r[0]!='200'&&r[0]!='204') fail('key update failed'+suffix(r));
        let after=api(a,'GET');
        if (after[0]!='200'||!obj(after[1])||after[1].id!=a.device_id||after[1].key!=pub) fail('new key could not be verified'+suffix(after));
        let data=session_data(after[1],dest+'/private.key'); if (!data) fail('incomplete or invalid WARP config');
        data.account=name; data.account_mode=freshMode?'fresh':randomMode?'random':'custom';
        data.device_id_masked=mask_id(a.device_id); data.started_at=time();
        if (device) data.underlay_device=device;
        if (!write_file(dest+'/session.json',sprintf('%J',data))) fail('cannot store session config');
        print('session created\n');
    } else if (command=='clear') {
        if (!name_ok(extra)) die('invalid interface name');
        let dest=root+'/session-'+extra,lease=root+'/account-'+name+'.lease';
        if (read_file(lease,128)!=extra) die('account does not own this session');
        let o=read_file(dest+'/owner',32);
        if (str(o)&&match(o,/^[0-9]+$/)) fs.unlink(root+'/public-refresh-'+extra+'-'+o);
        if (!cleanup(dest)) die('cannot remove session or session does not exist');
        fs.unlink(lease); print('session removed\n');
    } else die('supported commands: register, import, status, session, random-session, fresh-session, clear');
}
main(ARGV);
