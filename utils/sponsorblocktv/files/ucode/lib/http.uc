// http.uc - asynchronous HTTP/HTTPS client wrapper over ucode-mod-uclient.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Provides a small promise-like API on top of the uclient module. All network
// I/O runs inside the uloop event loop. Callers register completion callbacks
// and the event loop drives the request.

'use strict';

import * as util from './util.uc';

let uloop = require('uloop');
let uclient = require('uclient');
let tracing=false;
function set_tracing(enabled){tracing=!!enabled;}

// --- low-level request ----------------------------------------------------

// Perform a single HTTP request.
//   opts: {
//     url, method ('GET'|'POST'|...), headers: {}, body (string|null),
//     timeout_ms (default 30000), verify_ssl (default true),
//     on_data(chunk) optional streaming callback,
//     on_done(status, headers, body) called on completion,
//     on_error(err) called on failure
//   }
// The wrapper owns the native resource and delivers completion at most once.
// Defer disposal out of native callbacks, where freeing the client can be unsafe.
function request_with_client(opts, factory){
    let body='',uc=null,finished=false,cancelled=false,deadline=null,started=util.monotonic_ms(),limit=opts.max_body_bytes??2097152;
    let timeout=opts.timeout_ms??30000;
    function trace(status){if(tracing)util.info('http',sprintf('%s status=%s elapsed=%dms',opts.method||'GET',status,util.monotonic_ms()-started));}
    function finish(ok,status,headers,message,notify){
        if(finished)return;
        finished=true;if(deadline){deadline.cancel();deadline=null;}trace(ok?status:'error');
        uloop.timer(0,()=>{
            let client=uc;uc=null;
            if(client){
                // OpenWrt 24.10 uclient may leave native timers armed if an
                // active request is freed directly. Disconnect first, then
                // dispose outside the native callback. Tested on 88ae8f20.
                try{if(client.disconnect)client.disconnect();}catch(e){}
                try{client.free();}catch(e){}
            }
            client=null;
            // Native resource finalizers may retain the callback environment.
            // Detach the caller and response before invoking its completion.
            let cb=notify===false || cancelled ? null : (ok?opts.on_done:opts.on_error);
            let response=ok && cb?body:null;
            body='';opts=null;factory=null;
            try{
                if(cb){if(ok)cb(status,headers,response);else cb(message);}
            }catch(e){util.warn('http','Request completion callback failed');}
            cb=null;response=null;headers=null;message=null;
        });
    }
    function fail(message){finish(false,0,null,message,true);}
    let handle={free:()=>{cancelled=true;finish(false,0,null,'cancelled',false);}};
    try{
        uc=factory(opts.url,null,{
            data_read:function(){
                if(finished)return;
                try{
                    let chunk,status=this.status()?.status;
                    while(!finished && (chunk=this.read())!=null){
                        if(!length(chunk))break;
                        if(opts.on_data && status>=200 && status<300)opts.on_data(chunk);
                        else{
                            if(length(body)+length(chunk)>limit){fail('response too large');return;}
                            body+=chunk;
                        }
                    }
                }catch(e){fail('response processing failed');}
            },
            data_eof:function(){
                if(finished)return;
                try{finish(true,this.status().status,this.get_headers(),null,true);}
                catch(e){fail('invalid HTTP response');}
            },
            error:function(cb,code){fail('uclient error '+code);}
        });
        if(!uc){fail('invalid URL');return handle;}
        if(index(opts.url,'https://')==0 && !uc.ssl_init({verify:opts.verify_ssl!==false,ca_files:['/etc/ssl/certs/ca-certificates.crt']})){
            fail('could not initialize TLS');return handle;
        }
        uc.set_timeout(timeout);
        // Native timeout can be an inactivity limit; enforce a total deadline too.
        if(timeout>0 && !finished)deadline=uloop.timer(timeout,()=>{deadline=null;fail('request deadline exceeded');});
        if(!uc.connect() || !uc.request(opts.method||'GET',{headers:opts.headers||{},post_data:opts.body}))fail('request failed');
    }catch(e){fail('request setup failed');}
    return handle;
}
// OpenWrt 24.10 uclient's ucode binding does not release ssl_ctx in
// free_uclient(). Reuse disconnected clients and their TLS contexts.
// Keep callbacks attached only for the lifetime of a single lease.
// Pool both HTTP and HTTPS: the old binding also clears registry[idx+1]
// on free, which can invalidate an adjacent live client's callbacks.
// Up to 64 TVs, each with backchannel, foreground and metadata traffic.
const MAX_CLIENTS=256;
let clients=[];
function new_slot(url,key){
    let i=length(clients);
    push(clients,{native:null,lease:null,key:key,initialized:false});
    clients[i].native=uclient.new(url,null,{
        data_read:function(){if(clients[i].lease)clients[i].lease.data_read();},
        data_eof:function(){if(clients[i].lease)clients[i].lease.data_eof();},
        error:function(cb,code){if(clients[i].lease)clients[i].lease.error(cb,code);}
    });
    if(!clients[i].native){pop(clients);return null;}
    return i;
}
function acquire(url,key,callbacks){
    let i=null;
    for(let j=0;j<length(clients);j++){
        if(clients[j].key==key && !clients[j].lease && !clients[j].broken){i=j;break;}
    }
    if(i==null){
        if(length(clients)>=MAX_CLIENTS)return null;
        i=new_slot(url,key);
        if(i==null)return null;
    }else if(!clients[i].native.set_url(url))return null;
    let lease={
        ssl_init:(options)=>{
            if(clients[i].initialized)return true;
            if(!clients[i].native.ssl_init(options)){clients[i].broken=true;return false;}
            clients[i].initialized=true;return true;
        },
        set_timeout:(ms)=>clients[i].native.set_timeout(ms>0?ms:30000),
        connect:()=>clients[i].native.connect(),
        request:(method,args)=>clients[i].native.request(method,args),
        status:()=>clients[i].native.status(),
        get_headers:()=>clients[i].native.get_headers(),
        read:()=>clients[i].native.read(),
        disconnect:()=>clients[i].native.disconnect(),
        free:()=>{
            clients[i].lease=null;
            try{if(!clients[i].native.set_url(key=='http'?'http://localhost/':'https://localhost/'))clients[i].broken=true;}
            catch(e){clients[i].broken=true;}
        },
        ...callbacks
    };
    clients[i].lease=lease;return lease;
}
function request(opts){
    let key=index(opts.url,'https://')==0?(opts.verify_ssl===false?'tls-insecure':'tls-verified'):'http';
    return request_with_client(opts,(url,proxy,callbacks)=>acquire(url,key,callbacks));
}

// --- convenience wrappers -------------------------------------------------

// GET returning parsed JSON. on_done(json_or_null, status).
function get_json(opts) {
	return request({
		url: opts.url,
		method: 'GET',
		headers: opts.headers,
		timeout_ms: opts.timeout_ms,
		max_body_bytes: opts.max_body_bytes,
		verify_ssl: opts.verify_ssl,
		on_done: (status, headers, body) => {
			let data = null;
			if (status >= 200 && status < 300) {
				try {
					data = json(body);
				}
				catch (e) {
					data = null;
				}
			}
			if (opts.on_done)
				opts.on_done(data, status, body);
		},
		on_error: (err) => {
			if (opts.on_error)
				opts.on_error(err);
		},
	});
}

// POST form-encoded, returning parsed JSON.
function post_form(opts) {
	let body = util.form_encode(opts.data || {});
	let headers = { ...(opts.headers || {}) };
	headers['Content-Type'] = 'application/x-www-form-urlencoded';
	return request({
		url: opts.url,
		method: 'POST',
		headers: headers,
		body: body,
		timeout_ms: opts.timeout_ms,
		max_body_bytes: opts.max_body_bytes,
		verify_ssl: opts.verify_ssl,
		on_done: (status, hdrs, body) => {
			let data = null;
			if (status >= 200 && status < 300) {
				try {
					data = json(body);
				}
				catch (e) {
					data = null;
				}
			}
			if (opts.on_done)
				opts.on_done(data, status, body);
		},
		on_error: (err) => {
			if (opts.on_error)
				opts.on_error(err);
		},
	});
}

// POST raw body, returning raw text. on_done(status, headers, body).
function post_raw(opts) {
	let headers = { ...(opts.headers || {}) };
	if (opts.content_type)
		headers['Content-Type'] = opts.content_type;
	return request({
		url: opts.url,
		method: 'POST',
		headers: headers,
		body: opts.body || '',
		timeout_ms: opts.timeout_ms,
		max_body_bytes: opts.max_body_bytes,
		verify_ssl: opts.verify_ssl,
		on_done: opts.on_done,
		on_error: opts.on_error,
	});
}

// GET raw text. on_done(status, headers, body).
function get_raw(opts) {
	return request({
		url: opts.url,
		method: 'GET',
		headers: opts.headers,
		timeout_ms: opts.timeout_ms,
		max_body_bytes: opts.max_body_bytes,
		verify_ssl: opts.verify_ssl,
		on_done: opts.on_done,
		on_error: opts.on_error,
	});
}

export { request_with_client, set_tracing, request, get_json, post_form, post_raw, get_raw };
