// mdns.uc - mDNS discovery of Chromecast devices.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Sends an mDNS PTR query for _googlecast._tcp.local and parses responses to
// find Chromecast devices (host + port). The Cast v2 client then connects to
// each to query the YouTube screen_id.

'use strict';

import { pack, unpack } from 'struct';
import * as util from './util.uc';

let uloop = require('uloop');
let socket = require('socket');

const MDNS_MULTICAST = '224.0.0.251';
const MDNS_PORT = 5353;
const SERVICE = '_googlecast._tcp.local';

// --- DNS message helpers --------------------------------------------------

// Build a DNS query message for a PTR record.
function build_ptr_query() {
	// Header: ID=0, flags=0x0000 (standard query), QDCOUNT=1
	let header = pack('>HHHHHH', 0, 0x0000, 1, 0, 0, 0);
	let qname = encode_name(SERVICE);
	let qtype = pack('>HH', 12, 1); // PTR, IN
	return header + qname + qtype;
}

function encode_name(name) {
	let out = '';
	let labels = split(name, '.');
	for (let i = 0; i < length(labels); i++) {
		let label = labels[i];
		out += pack('C', length(label)) + label;
	}
	out += pack('C', 0);
	return out;
}

// Parse a DNS response, extracting PTR targets and SRV/A records.
// Returns an array of { name, host, port }.
function parse_dns_response(data) {
	let results = [];
	let offset = 0;

	// Skip header (12 bytes).
	if (length(data) < 12)
		return results;
	let header = unpack('>HHHHHH', substr(data, 0, 12));
	let qdcount = header[2];
	let ancount = header[3];
	offset = 12;

	// Skip questions.
	for (let i = 0; i < qdcount; i++) {
		offset = skip_name(data, offset);
		offset += 4; // qtype + qclass
	}

	// Parse answers.
	for (let i = 0; i < ancount; i++) {
		let name = read_name(data, offset);
		offset = name.next;
		if (offset + 10 > length(data))
			break;
		let rr = unpack('>HHIH', substr(data, offset, 10));
		let rtype = rr[0];
		let rclass = rr[1];
		let ttl = rr[2];
		let rdlength = rr[3];
		offset += 10;
		let rdata = substr(data, offset, rdlength);
		offset += rdlength;

		if (rtype == 12) { // PTR
			let ptr = read_name(data, offset - rdlength);
			results[length(results)] = { type: 'ptr', name: ptr.value };
		}
		else if (rtype == 33) { // SRV
			let srv = unpack('>HHH', substr(rdata, 0, 6));
			let target = read_name(data, offset - rdlength + 6);
			results[length(results)] = {
				type: 'srv',
				priority: srv[0],
				weight: srv[1],
				port: srv[2],
				target: target.value,
			};
		}
		else if (rtype == 1) { // A
			let ip = unpack('>CCCC', rdata);
			results[length(results)] = {
				type: 'a',
				ip: ip[0] + '.' + ip[1] + '.' + ip[2] + '.' + ip[3],
			};
		}
	}
	return results;
}

function skip_name(data, offset) {
	let i = offset;
	while (i < length(data)) {
		let len = ord(data[i]);
		if (len == 0) {
			i++;
			break;
		}
		if ((len & 0xc0) == 0xc0) {
			i += 2;
			break;
		}
		i += len + 1;
	}
	return i;
}

function read_name(data, offset) {
	let labels = [];
	let i = offset;
	let jumped = false;
	let next = offset;
	while (i < length(data)) {
		let len = ord(data[i]);
		if (len == 0) {
			i++;
			if (!jumped)
				next = i;
			break;
		}
		if ((len & 0xc0) == 0xc0) {
			let ptr = unpack('>H', substr(data, i, 2))[0] & 0x3fff;
			if (!jumped)
				next = i + 2;
			i = ptr;
			jumped = true;
			continue;
		}
		labels[length(labels)] = substr(data, i + 1, len);
		i += len + 1;
	}
	return { value: join('.', labels), next: next };
}

// --- mDNS discovery -------------------------------------------------------

// Discover Chromecast devices via mDNS. on_device(host, port) per device,
// on_done() when the cycle completes.
//   opts: { timeout_ms, on_device(host, port), on_done(), on_error(err) }
function discover(opts) {
	let timeout_ms = opts.timeout_ms || 5000;
	let seen = {};
	let devices = [];

	let sock = socket.create(socket.AF_INET, socket.SOCK_DGRAM | socket.SOCK_NONBLOCK, 0);
	if (!sock) {
		if (opts.on_error) opts.on_error('failed to create UDP socket');
		return null;
	}

	try {
		sock.bind('0.0.0.0', 0);
		sock.setopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP,
			pack('4C4C', ...iptoarr(MDNS_MULTICAST), ...iptoarr('0.0.0.0')));
	}
	catch (e) {
		util.warn('mdns', 'multicast join failed: ' + e);
	}

	let query = build_ptr_query();
	sock.sendto(query, MDNS_MULTICAST, MDNS_PORT);

	let handle = uloop.handle(sock, (events) => {
		if (events & uloop.ULOOP_READ) {
			let data = sock.recv(65536);
			if (data)
				process_response(data);
		}
	}, uloop.ULOOP_READ);

	function process_response(data) {
		let records = parse_dns_response(data);
		// Collect PTR targets and SRV/A records.
		let ptr_names = [];
		let srv_records = [];
		let a_records = [];
		for (let i = 0; i < length(records); i++) {
			let r = records[i];
			if (r.type == 'ptr') ptr_names[length(ptr_names)] = r.name;
			else if (r.type == 'srv') srv_records[length(srv_records)] = r;
			else if (r.type == 'a') a_records[length(a_records)] = r;
		}
		// Match SRV targets to A records.
		for (let i = 0; i < length(srv_records); i++) {
			let srv = srv_records[i];
			let host = srv.target;
			let ip = null;
			for (let j = 0; j < length(a_records); j++) {
				if (a_records[j].ip) {
					ip = a_records[j].ip;
					break;
				}
			}
			if (ip && !seen[ip]) {
				seen[ip] = true;
				devices[length(devices)] = { host: ip, port: srv.port };
				if (opts.on_device) opts.on_device(ip, srv.port);
			}
		}
	}

	function cleanup() {
		if (handle) handle.delete();
		if (sock) sock.close();
	}

	let timer = uloop.timer(timeout_ms, () => {
		cleanup();
		if (opts.on_done) opts.on_done();
	});

	return { sock: sock, handle: handle, stop: cleanup };
}

export { discover, build_ptr_query, parse_dns_response };
