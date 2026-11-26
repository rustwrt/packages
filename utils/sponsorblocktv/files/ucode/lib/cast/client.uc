// client.uc - Chromecast Cast V2 operations via the pychromecast bridge.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// The Cast v2 protocol (TLS + protobuf) is delegated to a Python pychromecast
// bridge (/usr/sbin/sponsorblocktv-cast-bridge). This keeps the ucode runtime
// free of a native TLS module while still supporting Chromecast discovery and
// YouTube MDX screen_id lookup.

'use strict';

import * as fs from 'fs';
import * as util from './../util.uc';

const BRIDGE = '/usr/sbin/sponsorblocktv-cast-bridge';

// Run the bridge with the given argv and return the parsed JSON result.
// Returns null on failure.
function run_bridge(argv) {
	let proc = null;
	try {
		proc = fs.popen(util.shell_command(argv), 'r');
		if (!proc)
			return null;
		let out = proc.read('all');
		proc.close();
		if (out == null || length(out) == 0)
			return null;
		return json(out);
	}
	catch (e) {
		util.debug('cast', 'bridge error: ' + e);
		if (proc)
			try { proc.close(); } catch (e2) {}
		return null;
	}
}

// Query a Chromecast by host for its YouTube MDX screen_id.
//   opts: { host, name, timeout_ms, on_result(screen_id, name), on_error(err) }
function query_youtube_screen_id(opts) {
	let argv = [BRIDGE, 'query', opts.host];
	if (opts.name)
		argv[length(argv)] = opts.name;

	let result = run_bridge(argv);
	if (!result) {
		if (opts.on_error) opts.on_error('bridge failed');
		return null;
	}
	if (result.error) {
		if (opts.on_error) opts.on_error(result.error);
		return null;
	}
	if (result.screen_id) {
		if (opts.on_result)
			opts.on_result(result.screen_id, result.name || opts.name || 'Chromecast');
		return null;
	}
	if (opts.on_error) opts.on_error('no screen_id');
	return null;
}

// Discover Chromecast devices and return their YouTube screen_ids.
//   opts: { on_device(device), on_done(), on_error(err) }
function discover_chromecasts(opts) {
	let result = run_bridge([BRIDGE, 'discover']);
	if (!result) {
		if (opts.on_error) opts.on_error('bridge failed');
		if (opts.on_done) opts.on_done();
		return;
	}
	if (result.error) {
		if (opts.on_error) opts.on_error(result.error);
		if (opts.on_done) opts.on_done();
		return;
	}
	let unpaired = result.unpaired || [];
	for (let i = 0; i < length(unpaired); i++) {
		if (opts.on_candidate) opts.on_candidate(unpaired[i]);
	}
	let devices = result.devices || [];
	for (let i = 0; i < length(devices); i++) {
		if (opts.on_device)
			opts.on_device(devices[i]);
	}
	if (opts.on_done) opts.on_done();
}

export { query_youtube_screen_id, discover_chromecasts };
