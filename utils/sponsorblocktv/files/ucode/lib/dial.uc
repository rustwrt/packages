// dial.uc - DIAL/SSDP discovery of YouTube-capable devices.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sends an SSDP M-SEARCH for DIAL devices, listens for responses, then queries
// each device's DIAL application URL to extract the YouTube screen_id. Mirrors
// upstream dial_client.py.

'use strict';

import * as fs from 'fs';
import * as util from './util.uc';
import * as http from './http.uc';
import * as sb from './sponsorblock.uc';

let uloop = require('uloop');
let global_pending=0;
let socket = require('socket');

const SSDP_MULTICAST = '239.255.255.250';
const SSDP_PORT = 1900;
const DIAL_SEARCH_TARGET = 'urn:dial-multiscreen-org:service:dial:1';
const MAX_WAIT = 3;

// --- helpers --------------------------------------------------------------

function get_local_ip() {
	// Resolve the logical LAN through netifd, not the default WAN route.
	try {
		let pipe = fs.popen('ubus call network.interface.lan status', 'r');
		if (!pipe) return null;
		let raw = pipe.read('all');
		pipe.close();
		let status = json(raw);
		if (status.up && length(status['ipv4-address'] || []))
			return status['ipv4-address'][0].address;
	}
	catch (e) {
		util.warn('dial', 'LAN lookup failed: ' + e);
	}
	return null;
}

function url_matches_ip(url, expected_ip) {
    if(type(url)!='string' || length(url)>2048 || type(expected_ip)!='string' || (match(url,/[[:space:][:cntrl:]]/) || index(url,'\\')>=0))return false;
    let m=match(url,/^https?:\/\/([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)(:([0-9]{1,5}))?(\/[^?#]*)?$/);
    if(!m || m[1]!=expected_ip || (m[3] && (int(m[3])<1 || int(m[3])>65535)))return false;
    for(let part in split(m[1],'.'))if(length(part)>3 || int(part)>255 || (length(part)>1 && substr(part,0,1)=='0'))return false;
    return true;
}

function extract_screen_id(xml) {
    if(type(xml)!='string')return null;
    let m=match(xml,/<screenId>([^<]+)<\/screenId>/);
    let id=m?util.trim(m[1]):null;
    return id && match(id,/^[A-Za-z0-9_-]{8,128}$/)?id:null;
}

function generate_pairing_code() {
	let source = fs.open('/dev/urandom', 'r');
	let out = '';
	while (length(out) < 12) {
		let byte = ord(source.read(1));
		if (byte < 250) out += '' + (byte % 10);
	}
	source.close();
	return out;
}

function xml_text(xml,pattern){
    let m=type(xml)=='string'?match(xml,pattern):null;
    if(!m)return '';
    let v=replace(m[1],/&lt;/g,'<');
    v=replace(v,/&gt;/g,'>');v=replace(v,/&quot;/g,'"');
    v=replace(v,/&apos;/g,"'");v=replace(v,/&amp;/g,'&');
    return substr(util.trim(replace(v,/[[:cntrl:]]/g,' ')),0,100);
}
function descriptor_info(xml){
    return {
        name:xml_text(xml,/<friendlyName>([^<]+)<\/friendlyName>/)||'YouTube TV',
        manufacturer:xml_text(xml,/<manufacturer>([^<]+)<\/manufacturer>/),
        model:xml_text(xml,/<modelName>([^<]+)<\/modelName>/),
        uuid:xml_text(xml,/<UDN>([^<]+)<\/UDN>/)
    };
}
function dial_app_info(xml,name){
    let app=match(name||'',/^TizenTube([[:space:](]|$)/i)?'TizenTube':xml_text(xml,/<name>([^<]+)<\/name>/);
    let state=lc(xml_text(xml,/<state>([^<]+)<\/state>/));
    return {application:app||'YouTube',app_state:index(['running','stopped','hidden'],state)>=0?state:''};
}

// DIAL receivers may reject chunked POSTs. OpenWrt uclient always uses
// chunked encoding for request bodies, so use fixed-length HTTP for LAN DIAL.
// The URL has already been checked against the SSDP response address.
function dial_post_fixed(url, headers, body, on_done, on_error) {
	let m = match(url, /^http:\/\/([0-9.]+)(:([0-9]+))?(\/[^[:space:]]*)$/);
	if (!m || match(url, /[[:cntrl:]]/)) {
		on_error('invalid DIAL HTTP URL');
		return;
	}
	let host = m[1], port = m[3] ? int(m[3]) : 80, path = m[4];
	if (port < 1 || port > 65535) {
		on_error('invalid DIAL port');
		return;
	}
	let conn = socket.connect(host, port, { family: socket.AF_INET, socktype: socket.SOCK_STREAM }, 2000);
	if (!conn) {
		on_error('DIAL connect failed: ' + socket.error());
		return;
	}
	let status = 0, response_headers = {}, failure = null;
	try {
		let request = 'POST ' + path + ' HTTP/1.1\r\nHost: ' + host + ':' + port + '\r\nConnection: close\r\nContent-Length: ' + length(body) + '\r\n';
		for (let k in headers) request += k + ': ' + headers[k] + '\r\n';
		request += '\r\n' + body;
		let deadline = util.monotonic_ms() + 5000;
		while (length(request)) {
			let left = deadline - util.monotonic_ms();
			if (left <= 0) die('DIAL send timeout');
			let ready = socket.poll(left, [conn, socket.POLLOUT]);
			if (!ready || !(ready[0][1] & socket.POLLOUT)) die('DIAL send timeout');
			let n = conn.send(request, socket.MSG_DONTWAIT | socket.MSG_NOSIGNAL);
			if (!n || n < 0) die('DIAL send failed');
			request = substr(request, n);
		}
		let raw = '';
		while (index(raw, '\r\n\r\n') < 0 && length(raw) < 16384) {
			let left = deadline - util.monotonic_ms();
			if (left <= 0) die('DIAL response timeout');
			let ready = socket.poll(left, conn);
			if (!ready || !(ready[0][1] & socket.POLLIN)) die('DIAL response unavailable');
			let chunk = conn.recv(4096, socket.MSG_DONTWAIT);
			if (!length(chunk)) die('DIAL response incomplete');
			raw += chunk;
		}
		let end = index(raw, '\r\n\r\n');
		if (end < 0) die('DIAL response headers too large');
		let lines = split(substr(raw, 0, end), '\r\n');
		let first = match(lines[0], /^HTTP\/1\.[01] ([0-9]{3})/);
		if (!first) die('invalid DIAL HTTP response');
		status = int(first[1]);
		for (let i = 1; i < length(lines); i++) {
			let colon = index(lines[i], ':');
			if (colon > 0) response_headers[lc(util.trim(substr(lines[i], 0, colon)))] = util.trim(substr(lines[i], colon + 1));
		}
	}
	catch (e) { failure = '' + e; }
	conn.close();
	if (failure) on_error(failure);
	else on_done(status, response_headers, '');
}

function launch_and_pair(opts, youtube_url, name) {
	let pairing_code = generate_pairing_code();
	util.info('dial', 'Launching YouTube on ' + name);
	let launch_headers = {
		Origin: 'https://www.youtube.com',
		'Content-Type': 'application/x-www-form-urlencoded',
	};
	let launch_data = util.form_encode({ pairingCode: pairing_code, theme: 'cl' });

	function launch_done(status, headers, body) {
		util.info('dial', 'YouTube launch HTTP ' + status);
		if (!(status >= 200 && status < 300)) {
			if (opts.on_result) opts.on_result(null);
			return;
		}
		let attempts = 0;
		function retry() {
			attempts++;
			sb.pair_with_code(pairing_code, (device) => {
				if (device && device.screen_id) {
					util.info('dial', 'YouTube pairing succeeded');
					if (opts.on_result) opts.on_result({ screen_id: device.screen_id, name: name, offset: 0 });
				}
				else if (attempts >= 10) {
					util.warn('dial', 'YouTube pairing did not return a screen ID');
					if (opts.on_result) opts.on_result(null);
				}
				else uloop.timer(2000, retry);
			});
		}
		uloop.timer(2000, retry);
	}
	function launch_error(err) {
		util.warn('dial', 'YouTube launch failed: ' + err);
		if (opts.on_result) opts.on_result(null);
	}
	if (index(youtube_url, 'http://') == 0)
		dial_post_fixed(youtube_url, launch_headers, launch_data, launch_done, launch_error);
	else
		http.post_raw({url: youtube_url, headers: launch_headers, body: launch_data,
			timeout_ms: 10000, on_done: launch_done, on_error: launch_error});
}

// --- DIAL device query ----------------------------------------------------

// Query a DIAL device's YouTube app for a screen_id.
//   opts: { url_location, expected_ip, active, on_result(device|null) }
function find_youtube_app(opts) {
	let self = this;
	if (!url_matches_ip(opts.url_location, opts.expected_ip)) {
		util.debug('dial', sprintf('Ignoring DIAL LOCATION from %s with non-matching URL %s',
			opts.expected_ip, opts.url_location));
		if (opts.on_result) opts.on_result(null);
		return;
	}

	http.get_raw({
		url: opts.url_location,
		timeout_ms: 4000,max_body_bytes:65536,
		on_done: (status, headers, body) => {
			if (status != 200) {
				if (opts.on_result) opts.on_result(null);
				return;
			}
			let info=descriptor_info(body),name=info.name;
			let app_url = null;
			for (let key in headers)
				if (lc(key) == 'application-url') app_url = headers[key];
			util.info('dial', 'DIAL descriptor HTTP ' + status + '; application URL: ' + (app_url || '(missing)'));
			if (!app_url || !url_matches_ip(app_url, opts.expected_ip)) {
				util.debug('dial', sprintf('Ignoring DIAL application-url from %s with non-matching URL %s',
					opts.expected_ip, app_url));
				if (opts.on_result) opts.on_result(null);
				return;
			}

			let youtube_url = replace(app_url, /\/$/, '') + '/YouTube';
			
			let request_headers = { Origin: 'https://www.youtube.com' };
			http.get_raw({
				url: youtube_url,
				headers: request_headers,
				timeout_ms: 4000,max_body_bytes:65536,
				on_done: (status2, hdrs2, body2) => {
					util.info('dial', 'YouTube DIAL status HTTP ' + status2);
					let address=match(youtube_url,/^http:\/\/[0-9.]+(:([0-9]+))?\//);
                let metadata={...info,...dial_app_info(body2,name),id:'dial:'+util.md5_hex(opts.url_location),host:opts.expected_ip,port:address && address[2]?int(address[2]):80,source:'DIAL'};
                if (status2 == 200 && opts.on_candidate)try{opts.on_candidate(metadata);}catch(e){util.warn('dial','Candidate callback failed');}
                if (status2 == 404 && opts.on_cast_hint && lc(info.manufacturer)=='google' && metadata.port==8008)
                    try{opts.on_cast_hint(metadata);}catch(e){util.warn('dial','Cast hint callback failed');}
					let screen_id = status2 == 200 ? extract_screen_id(body2) : null;
					if (screen_id) {
						if (opts.on_result)
							opts.on_result({ ...metadata, screen_id: screen_id, offset: 0 });
						return;
					}
					// Passive mode: don't launch the app.
					if (!opts.active) {
						if (opts.on_result) opts.on_result(null);
						return;
					}
					// Active mode: launch YouTube with a pairing code.
					launch_and_pair(opts, youtube_url, name);
				},
				on_error: () => {
					if (opts.on_result) opts.on_result(null);
				},
			});
		},
		on_error: () => {
			if (opts.on_result) opts.on_result(null);
		},
	});
}

// --- SSDP discovery -------------------------------------------------------

// Discover YouTube devices via DIAL. on_device(device) is called for each
// device found; on_done() when the discovery cycle completes.
//   opts: { active, on_device(device), on_done(), on_error(err) }
function discover(opts) {
	let active = opts.active !== false;
	let bounded = opts.bounded || active;
	let seen_screen_ids = {};
	let seen_locations = {};
	let pending = 0, waiting=[],pump_timer,closed=false,timers=[],seen_count=0,screen_order=[];
	let done = false, queue_warned=false;
	let deadline=util.monotonic_ms()+18000;

	let local_ip = opts.local_ip || get_local_ip();
	if (!local_ip) {
		if (opts.on_error) opts.on_error('No active LAN IPv4 address');
		return null;
	}

	// Create a UDP socket bound to the local IP, join the SSDP multicast group.
	let sock = socket.create(socket.AF_INET, socket.SOCK_DGRAM | socket.SOCK_NONBLOCK, 0);
	if (!sock) {
		if (opts.on_error) opts.on_error('failed to create UDP socket');
		return null;
	}

	try {
		if (!sock.bind({address:local_ip, port:0}) ||
		    !sock.setopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, { address: local_ip }))
			die('Failed to bind LAN multicast socket');
		// SSDP search replies are unicast; explicitly select the LAN for sends.
	}
	catch (e) {
		sock.close();
		if (opts.on_error) opts.on_error('LAN multicast setup failed: ' + e);
		return null;
	}

	// Build the M-SEARCH request.
	let search = join('\r\n', [
		'M-SEARCH * HTTP/1.1',
		'HOST: ' + SSDP_MULTICAST + ':' + SSDP_PORT,
		'MAN: "ssdp:discover"',
		'MX: ' + MAX_WAIT,
		'ST: ' + DIAL_SEARCH_TARGET,
		'',
		'',
	]);

	let handle;
	function cleanup() {
		if(closed)return;closed=true;waiting=[];
		if(pump_timer)pump_timer.cancel();
		for(let t in timers)if(t)t.cancel();timers=[];
		if (handle) handle.delete();
		if (sock) sock.close();
	}

	function check_done() {
		if (!closed && done && pending == 0 && !length(waiting)) {
			cleanup();
			if (opts.on_done) opts.on_done();
		}
	}

    function pump(){
        if(closed)return;
        if(bounded && util.monotonic_ms()>=deadline && length(waiting)){if(opts.on_warning)opts.on_warning("DIAL deadline: "+length(waiting)+" queued responses not queried");waiting=[];}
        while(length(waiting) && pending<12 && global_pending<24){
            let item=shift(waiting),finished=false;
            pending++;global_pending++;
            function complete(device){
                if(finished)return;finished=true;
                pending--;global_pending--;
                if(!closed && device && device.screen_id && !seen_screen_ids[device.screen_id]){
                    if(length(screen_order)>=256)delete seen_screen_ids[shift(screen_order)];
                    push(screen_order,device.screen_id);seen_screen_ids[device.screen_id]=true;
                    if(opts.on_device)try{opts.on_device(device);}catch(e){util.warn('dial','Device callback failed');}
                }
                check_done();
            }
            try{find_youtube_app({url_location:item.url_location,expected_ip:item.expected_ip,active:active,
                on_candidate:(d)=>{if(!closed && opts.on_candidate)opts.on_candidate(d);},on_cast_hint:(d)=>{if(!closed && opts.on_cast_hint)opts.on_cast_hint(d);},on_result:complete});}
            catch(e){complete(null);}
        }
        check_done();
    }

	function process_response(data, expected_ip) {
		// Parse the SSDP response headers.
		let lines = split(data, '\r\n');
		if(!match(lines[0]||'',/^HTTP\/1\.[01] 200( |$)/))return;
		let headers = {};
		for (let i = 0; i < length(lines); i++) {
			let line = lines[i];
			let colon = index(line, ':');
			if (colon > 0) {
				let k = lc(util.trim(substr(line, 0, colon)));
				let v = util.trim(substr(line, colon + 1));
				headers[k] = v;
			}
		}
		if(headers.st && lc(headers.st)!=DIAL_SEARCH_TARGET)return;
		let location = headers.location;
		if (closed || done || !url_matches_ip(location,expected_ip) || (bounded && seen_locations[expected_ip + '|' + location]))return;
		if(bounded && seen_count>=256){if(!queue_warned && opts.on_warning)opts.on_warning('DIAL discovery limit reached');queue_warned=true;return;}
		if(length(waiting)>=64){if(!queue_warned && opts.on_warning)opts.on_warning("DIAL queue full; scan may be incomplete");queue_warned=true;return;}
		if(bounded){seen_locations[expected_ip + '|' + location]=true;seen_count++;}
		util.info('dial', 'SSDP response from ' + expected_ip + ': ' + location);
        push(waiting,{url_location:location,expected_ip:expected_ip});
        pump();
    }

	// Check the multicast send result.
	let sent = sock.send(search, 0, { address: SSDP_MULTICAST, port: SSDP_PORT });
	if (sent != length(search)) {
		cleanup();
		if (opts.on_error) opts.on_error('SSDP send failed: ' + socket.error());
		return null;
	}
	util.info('dial', 'SSDP M-SEARCH sent from ' + local_ip);
	pump_timer=uloop.interval(100,pump);

	// Read responses for ~4 seconds (active) or poll indefinitely (passive).
	
	handle = uloop.handle(sock, (events) => {
		if (events & uloop.ULOOP_READ) {
			let peer = {};
			let data = sock.recv(8192, 0, peer);
			if (type(data)=='string' && length(data)<8192 && type(peer.address)=='string') {
				process_response(data, peer.address);
			}
		}
	}, uloop.ULOOP_READ);

	// Active mode: repeat M-SEARCH to recover lost multicast packets.
	if (bounded) {
		let repeat = uloop.timer(1800, () => {
			if (!closed && !done) sock.send(search, 0, { address: SSDP_MULTICAST, port: SSDP_PORT });
		});
		let repeat2 = uloop.timer(4000, () => { if (!closed && !done) sock.send(search, 0, { address: SSDP_MULTICAST, port: SSDP_PORT }); });
		let timer = uloop.timer(8000, () => {
			done = true;
			check_done();
		});
		timers=[repeat,repeat2,timer];
	}
	else {
		// Passive mode: poll every 15 seconds.
		let interval = uloop.interval(15000, () => {
			if(!closed)sock.send(search, 0, { address: SSDP_MULTICAST, port: SSDP_PORT });
		});
		push(timers,interval);
	}

	return { sock: sock, handle: handle, stop: cleanup };
}

export { discover, find_youtube_app, get_local_ip, extract_screen_id, url_matches_ip, descriptor_info, dial_app_info };
