'use strict';
'require view';
'require netbraid';

return view.extend({
	load: function() { return Promise.all([ netbraid.fetch('diagnostics'), netbraid.fetch('validate') ]); },
	render: function(results) {
		return E('div', {}, [
			E('h2', {}, _('Diagnostics')),
			netbraid.preview(),
			E('p', {}, _('Read-only diagnostics and validation inspect saved configuration. Save pending form edits before validating. No commands or routing changes are executed by this page.')),
			netbraid.status('validate', _('Saved configuration validation'), results[1]),
			netbraid.status('diagnostics', _('Runtime diagnostics'), results[0])
		]);
	},
	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
