// util.uc - shared helpers for SponsorBlockTV ucode runtime.
// SPDX-License-Identifier: GPL-3.0-or-later

'use strict';

import * as fs from 'fs';
import { md5, sha256 } from 'digest';

// --- logging -------------------------------------------------------------

let log_level = 1; // 0=debug, 1=info, 2=warn, 3=error

function set_log_level(level) {
	log_level = level;
}

function _ts() {
	let t = gmtime();
	return sprintf('%04d-%02d-%02d %02d:%02d:%02d',
		t.year, t.mon, t.mday, t.hour, t.min, t.sec);
}

function debug(tag, msg) {
	if (log_level <= 0)
		fs.stderr.write(sprintf('%s - %s - DEBUG - %s\n', _ts(), tag, msg));
}

function info(tag, msg) {
	if (log_level <= 1)
		fs.stderr.write(sprintf('%s - %s - INFO - %s\n', _ts(), tag, msg));
}

function warn(tag, msg) {
	if (log_level <= 2)
		fs.stderr.write(sprintf('%s - %s - WARN - %s\n', _ts(), tag, msg));
}

function error(tag, msg) {
	if (log_level <= 3)
		fs.stderr.write(sprintf('%s - %s - ERROR - %s\n', _ts(), tag, msg));
}

// --- misc -----------------------------------------------------------------

function now_ms() {
	return time() * 1000;
}

// A base endpoint cannot contain a query or fragment; append exactly one slash.
function normalize_api_url(value){
    if(value!=null && type(value)!='string')die('Invalid SponsorBlock API base URL');
    let url=trim(value||'')||'https://sponsor.ajay.app/api/';
    if(length(url)>2048 || !match(url,/^https?:\/\/(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+)(:[0-9]{1,5})?(\/[^?#[:space:]]*)?$/))
        die('Invalid SponsorBlock API base URL');
    let authority=match(url,/^https?:\/\/(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9._-]+)(:([0-9]{1,5}))?/);
    if(authority[3] && (int(authority[3])<1 || int(authority[3])>65535))die('Invalid SponsorBlock API port');
    if(index(url,'\\')>=0 || match(url,/[[:cntrl:]]/))die('Invalid SponsorBlock API base URL');
    while(substr(url,length(url)-1,1)=='/')url=substr(url,0,length(url)-1);
    return url+'/';
}

// Avoid native repeating fd/interval lifetime hazards when a callback stops
// its own timer or triggers a session teardown. A single pending timeout is
// owned by the wrapper; never cancel the timeout that is currently firing.
function repeat_timer(loop,ms,callback){
    let stopped=false,pending=null;
    function arm(){
        if(stopped)return;
        pending=loop.timer(ms,()=>{
            let active=pending;
            pending=null;
            if(stopped)return;
            try{callback();}catch(e){warn('timer','Periodic callback failed');}
            if(!stopped)arm();
        });
    }
    let handle={cancel:()=>{
        if(stopped)return;
        stopped=true;
        let old=pending;pending=null;
        if(old)old.cancel();
    }};
    arm();
    return handle;
}

function monotonic_ms() {
	let t = clock(true);
	return t[0] * 1000 + int(t[1] / 1000000);
}

function sleep_ms(ms) {
	// Blocking sleep. Only used in short, non-event-loop contexts (pairing
	// retries). The event-loop runtime uses uloop timers instead.
	global.sleep(ms);
}

function sleep(seconds) {
	sleep_ms(seconds * 1000);
}

// --- string helpers -------------------------------------------------------

function trim(s) {
	return replace(s, /^\s+|\s+$/g, '');
}

function to_bool(value, default_value) {
	if (value == null)
		return default_value;
	let text = trim('' + value);
	// Case-insensitive check without toLowerCase() (not available in ucode)
	if (text == '1' || text == 'true' || text == 'True' || text == 'TRUE' ||
	    text == 'yes' || text == 'Yes' || text == 'YES' ||
	    text == 'on' || text == 'On' || text == 'ON')
		return true;
	if (text == '0' || text == 'false' || text == 'False' || text == 'FALSE' ||
	    text == 'no' || text == 'No' || text == 'NO' ||
	    text == 'off' || text == 'Off' || text == 'OFF' || text == '')
		return false;
	return default_value;
}

function to_int(value, default_value) {
	if (value == null || value == '')
		return default_value;
	let n = int(value);
	if (n != n)  // NaN
		return default_value;
	return n;
}

function to_float(value, default_value) {
	if (value == null || value == '')
		return default_value;
	let f = (1.0 * value);
	if (f != f)  // NaN
		return default_value;
	return f;
}

// --- JSON helpers ---------------------------------------------------------

function json_dumps(obj) {
	return sprintf('%.J', obj);
}

function json_loads(text) {
	return json(text);
}

// --- crypto ---------------------------------------------------------------

function md5_hex(s) {
	return md5(s);
}

function sha256_hex(s) {
	return sha256(s);
}

// --- URL helpers ----------------------------------------------------------

function urlencode(s) {
	// Percent-encode a string for use in a query string / form body.
	let out = '';
	for (let i = 0; i < length(s); i++) {
		let c = substr(s, i, 1);
		let code = ord(c);
		if ((code >= 0x30 && code <= 0x39) || // 0-9
		    (code >= 0x41 && code <= 0x5a) || // A-Z
		    (code >= 0x61 && code <= 0x7a) || // a-z
		    c == '-' || c == '_' || c == '.' || c == '~')
			out += c;
		else
			out += sprintf('%%%02X', code);
	}
	return out;
}

function form_encode(params) {
	// Encode an object of scalar values into application/x-www-form-urlencoded.
	let parts = [];
	for (let k in params) {
		let v = params[k];
		if (v == null)
			continue;
		parts[length(parts)] = urlencode(k) + '=' + urlencode('' + v);
	}
	return join('&', parts);
}

function query_encode(params) {
	// Same as form_encode but values may be arrays (repeated keys).
	let parts = [];
	for (let k in params) {
		let v = params[k];
		if (v == null)
			continue;
		if (type(v) == 'array') {
			for (let i = 0; i < length(v); i++)
				parts[length(parts)] = urlencode(k) + '=' + urlencode('' + v[i]);
		}
		else {
			parts[length(parts)] = urlencode(k) + '=' + urlencode('' + v);
		}
	}
	return join('&', parts);
}

// --- misc -----------------------------------------------------------------

function shell_command(argv) {
	return join(' ', map(argv, (arg) => "'" + replace('' + arg, "'", "'\\''") + "'"));
}

function uniq(arr) {
	let seen = {};
	let out = [];
	for (let i = 0; i < length(arr); i++) {
		let v = arr[i];
		if (!seen[v]) {
			seen[v] = true;
			out[length(out)] = v;
		}
	}
	return out;
}

// Availability is a single-token request. Some responses omit screenId.
 // Explicit identifiers must agree; ambiguous responses are rejected.
function availability_status(data,screen_id,token){
    if(type(screen_id)!='string' || !length(screen_id) || type(token)!='string' || !length(token) || match(token,/[,[:space:][:cntrl:]]/))return null;
    // A valid single-token request can return {} or an empty screens array
    // when no screen is available. Other malformed or mismatched replies stay unknown.
    if(type(data)!='object')return null;
    if(!length(keys(data)))return false;
    if(type(data.screens)!='array')return null;
    if(!length(data.screens))return false;
    let matches=[];
    for(let d in data.screens){
        if(type(d)!='object')continue;
        if(d.screenId!=null && d.screenId!==screen_id)continue;
        if(d.loungeToken!=null && d.loungeToken!==token)continue;
        if(d.lounge_token!=null && d.lounge_token!==token)continue;
        if(d.screenId===screen_id || d.loungeToken===token || d.lounge_token===token || length(data.screens)==1)push(matches,d);
    }
    if(length(matches)!=1)return null;
    return matches[0].status=='online'?true:matches[0].status=='offline'?false:null;
}

export { availability_status, normalize_api_url,
	set_log_level, debug, info, warn, error,
	now_ms, monotonic_ms, repeat_timer, sleep_ms, sleep,
	trim, to_bool, to_int, to_float,
	json_dumps, json_loads,
	md5_hex, sha256_hex,
	urlencode, form_encode, query_encode,
	uniq, shell_command
};
