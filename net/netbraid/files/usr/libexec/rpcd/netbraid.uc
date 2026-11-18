'use strict';

import { query, toWire } from '/usr/lib/netbraid/runtime.uc';
import { detectionStatus } from '/usr/lib/netbraid/detection-status.uc';

function callMethod(request) {
	let method = request.info.method;
	try {
		if (method == 'detection')
			return toWire(detectionStatus('/etc/config'));
		return toWire(query(method, '/etc/config'));
	}
	catch (error) {
		return { error: '' + error };
	}
}

return {
	'luci.netbraid': {
		status: { call: callMethod },
		interfaces: { call: callMethod },
		detection: { call: callMethod },
		portal: { call: callMethod },
		diagnostics: { call: callMethod },
		validate: { call: callMethod }
	}
};
