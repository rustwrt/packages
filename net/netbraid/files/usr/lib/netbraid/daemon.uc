'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';
import { isInteger } from './util.uc';
import { collect, readDaemon, writeSnapshot } from './runtime.uc';

let confDir = '/etc/config';
let statusPath = '/var/run/netbraid/status.json';
let interval = 10;
let detectionEnabled = null;
let detectionRetention = 900;
for (let i = 0; i < length(ARGV); i++) {
	if (ARGV[i] == '--config-dir') confDir = ARGV[++i];
	else if (ARGV[i] == '--status-file') statusPath = ARGV[++i];
	else if (ARGV[i] == '--interval') interval = int(ARGV[++i]);
	else if (ARGV[i] == '--detection-enabled') detectionEnabled = ARGV[++i] == '1';
	else if (ARGV[i] == '--detection-retention') detectionRetention = int(ARGV[++i]);
	else die('unknown daemon argument: ' + ARGV[i]);
}
if (!isInteger(detectionRetention, 60, 86400))
	die('invalid detection retention');
if (substr(confDir, 0, 1) != '/' || substr(statusPath, 0, 1) != '/' || interval < 5 || interval > 60)
	die('invalid daemon configuration');
let previous = readDaemon(statusPath);
let startedAt = previous.running ? previous.startedAt : time();
let stopping = false;
let timer = null;
function update() {
	try {
		let snapshot = collect(confDir, { startedAt: startedAt });
		writeSnapshot(snapshot, statusPath);
	}
	catch (error) {
		warn('netbraidd snapshot error: %s\n', error);
	}
}
function stop() {
	if (stopping)
		return;
	stopping = true;
	try { fs.unlink(statusPath); } catch (error) {}
	if (timer)
		timer.cancel();
}
uloop.init();
uloop.signal('TERM', stop);
uloop.signal('INT', stop);
timer = uloop.interval(interval * 1000, function() { update(); });
update();
uloop.run();
