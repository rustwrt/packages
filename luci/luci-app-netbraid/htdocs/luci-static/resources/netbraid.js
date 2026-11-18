'use strict';
'require baseclass';
'require rpc';
'require form';
'require uci';
'require ui';

const calls = {
	status: rpc.declare({ object: 'luci.netbraid', method: 'status', expect: { '': {} }, reject: true }),
	interfaces: rpc.declare({ object: 'luci.netbraid', method: 'interfaces', expect: { '': {} }, reject: true }),
	detection: rpc.declare({ object: 'luci.netbraid', method: 'detection', expect: { '': {} }, reject: true }),
	portal: rpc.declare({ object: 'luci.netbraid', method: 'portal', expect: { '': {} }, reject: true }),
	diagnostics: rpc.declare({ object: 'luci.netbraid', method: 'diagnostics', expect: { '': {} }, reject: true }),
	validate: rpc.declare({ object: 'luci.netbraid', method: 'validate', expect: { '': {} }, reject: true })
};

function fromWire(reply) {
	if (Array.isArray(reply))
		return reply.map(fromWire);
	if (reply && typeof reply === 'object') {
		const model = {};
		Object.keys(reply).forEach(function(key) {
			const name = key.replace(/_([a-z])/g, function(match, letter) { return letter.toUpperCase(); });
			model[name] = [ 'data', 'metadata', 'value' ].indexOf(key) >= 0 ? reply[key] : fromWire(reply[key]);
		});
		return model;
	}
	return reply;
}

function detailTable(model, depth) {
	if (model == null)
		return E('span', {}, _('Not reported'));
	if (typeof model === 'boolean')
		return E('span', {}, model ? _('Yes') : _('No'));
	if (typeof model !== 'object')
		return E('span', {}, String(model));
	const keys = Object.keys(model);
	if (!keys.length)
		return E('em', {}, _('No records reported.'));
	if (depth > 5)
		return E('span', {}, _('Additional nested records omitted.'));
	return E('div', { 'class': 'table cbi-section-table', 'role': 'table' }, keys.slice(0, 100).map(function(key) {
		return E('div', { 'class': 'tr', 'role': 'row' }, [
			E('div', { 'class': 'td left', 'role': 'rowheader' }, Array.isArray(model) ? String(Number(key) + 1) : key.replace(/([A-Z])/g, ' $1')),
			E('div', { 'class': 'td left', 'role': 'cell' }, [ detailTable(model[key], depth + 1) ])
		]);
	}).concat(keys.length > 100 ? [ E('p', {}, _('Only the first 100 records are shown.')) ] : []));
}

return baseclass.extend({
	fetch: function(method) {
		return calls[method]().then(function(reply) {
			if (!reply || typeof reply !== 'object' || !Object.keys(reply).length)
				throw new Error(_('No status was returned by luci.netbraid.'));
			const model = fromWire(reply);
			if (model.error)
				throw new Error(typeof model.error === 'string' ? model.error : _('The backend rejected the request.'));
			return { model: model };
		}).catch(function(error) {
			return { error: error.message || String(error) };
		});
	},

	status: function(method, title, result) {
		const body = E('div', { 'aria-live': 'polite' });
		const paint = function(nextResult) {
			body.replaceChildren(nextResult.error
				? E('div', { 'class': 'alert-message warning', 'role': 'alert' }, [
					E('strong', {}, _('Status unavailable')),
					E('p', {}, nextResult.error),
					E('p', {}, _('Check that netbraid and rpcd are running and your account has NetBraid read permission, then refresh.'))
				])
				: detailTable(nextResult.model, 0));
		};
		paint(result);
		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, title),
			E('button', {
				'class': 'cbi-button cbi-button-neutral',
				'type': 'button',
				'click': ui.createHandlerFn(this, function() { return this.fetch(method).then(paint); })
			}, _('Refresh status')),
			body
		]);
	},

	preview: function() {
		return E('div', { 'class': 'alert-message warning', 'role': 'note' }, [
			E('strong', {}, _('Routing preview only')),
			E('p', {}, _('Save & Apply stores UCI configuration. Safe routing activation is not implemented; saved members, policies and rules are not proof of active forwarding.'))
		]);
	},

	map: function(title, description) {
		return new form.Map('netbraid', title, description);
	},

	grid: function(map, sectionType, title) {
		const section = map.section(form.GridSection, sectionType, title);
		section.anonymous = false;
		section.addremove = true;
		section.nodescriptions = true;
		section.addbtntitle = _('Add configuration');
		section.renderSectionAdd = function() {
			const element = form.GridSection.prototype.renderSectionAdd.apply(this, arguments);
			const nameInput = element.querySelector('.cbi-section-create-name');
			if (nameInput)
				ui.addValidator(nameInput, 'uciname', true, function(sectionName) {
					if (!/^[A-Za-z_][A-Za-z0-9_]{0,31}$/.test(sectionName))
						return _('Use up to 32 letters, digits or underscores, starting with a letter or underscore.');
					return uci.get('netbraid', sectionName) ? _('This section name is already in use.') : true;
				}, 'blur', 'keyup');
			return element;
		};
		return section;
	},

	flag: function(section, optionName, title, defaultValue, description) {
		const option = section.option(form.Flag, optionName, title, description);
		option.default = defaultValue ? '1' : '0';
		option.rmempty = false;
		return option;
	},

	number: function(section, optionName, title, minimum, maximum, defaultValue, description) {
		const option = section.option(form.Value, optionName, title, description);
		option.datatype = 'range(' + minimum + ',' + maximum + ')';
		option.default = String(defaultValue);
		option.rmempty = false;
		return option;
	},

	family: function(section) {
		const option = section.option(form.ListValue, 'family', _('Address family'));
		option.value('auto', _('IPv4 and IPv6'));
		option.value('ipv4', _('IPv4'));
		option.value('ipv6', _('IPv6'));
		option.default = 'auto';
		return option;
	},

	reference: function(section, optionName, title, sectionType, multiple) {
		const option = section.option(multiple ? form.MultiValue : form.ListValue, optionName, title);
		uci.sections('netbraid', sectionType).forEach(function(entry) { option.value(entry['.name']); });
		option.validate = function(sectionId, selected) {
			const names = selected == null || selected === '' ? [] : (Array.isArray(selected) ? selected : [ selected ]);
			return names.every(function(name) { return uci.get('netbraid', name) === sectionType; })
				? true : _('Select an existing configuration section.');
		};
		return option;
	},

	details: function(model) { return detailTable(model, 0); }
});
