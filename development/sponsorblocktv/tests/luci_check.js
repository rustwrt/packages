'use strict';

/*
 * Host-side harness for luci/luci-app-sponsorblocktv/.../sponsorblocktv.js.
 *
 * Loads the real view source against minimal LuCI stubs and asserts:
 *   - every UCI option the shipped config exposes is bound by the form,
 *   - the pairing/control widgets survive a Map.reset() re-render,
 *   - the exec commands the view issues match the rpcd ACL patterns.
 *
 * Run: node tests/luci_check.js   (exit 0 = pass)
 */

const fs = require('fs');
const path = require('path');

const REPO = path.resolve(__dirname, '..');
const VIEW = process.env.SBTV_VIEW || path.join(REPO, '..', '..', 'luci', 'luci-app-sponsorblocktv',
	'htdocs', 'luci-static', 'resources', 'view', 'sponsorblocktv.js');
const ACL = path.join(REPO, '..', '..', 'luci', 'luci-app-sponsorblocktv',
	'root', 'usr', 'share', 'rpcd', 'acl.d', 'luci-app-sponsorblocktv.json');
const UCI = path.join(REPO, '..', '..', 'utils', 'sponsorblocktv', 'files',
	'sponsorblocktv.config');

const failures = [];
function check(name, cond, detail) {
	if (!cond)
		failures.push(`${name}${detail ? `: ${detail}` : ''}`);
}

/* ---------------------------------------------------------------- DOM stubs */

class El {
	constructor(tag, attrs, children) {
		this.tag = tag;
		this.attrs = attrs || {};
		this.style = {
			setProperty: (k, v) => { this.style[k] = v; },
			removeProperty: (k) => { delete this.style[k]; }
		};
		this.isConnected = true;
		this.children = [];
		this.parent = null;
		if (children)
			[].concat(children).forEach((c) => this.appendChild(c));
	}
	appendChild(c) {
		if (c == null)
			return c;
		if (c instanceof El)
			c.parent = this;
		this.children.push(c);
		return c;
	}
	insertBefore(node, ref) {
		if (node instanceof El)
			node.parent = this;
		const i = ref ? this.children.indexOf(ref) : -1;
		if (i >= 0)
			this.children.splice(i, 0, node);
		else
			this.children.push(node);
		return node;
	}
	get firstChild() { return this.children[0] || null; }
	get nextSibling() {
		if (!this.parent)
			return null;
		const i = this.parent.children.indexOf(this);
		return this.parent.children[i + 1] || null;
	}
	querySelector() { return null; }
	querySelectorAll() { return []; }
	addEventListener() {}
	setAttribute(name, value) { this.attrs[name] = value; }
	removeAttribute(name) { delete this.attrs[name]; delete this[name]; }
	remove() {
		if (this.parent) {
			const i = this.parent.children.indexOf(this);
			if (i >= 0)
				this.parent.children.splice(i, 1);
			this.parent = null;
		}
	}
	replaceWith(node) { if(this.parent){const i=this.parent.children.indexOf(this);this.parent.children[i]=node;node.parent=this.parent;this.parent=null;} }
    replaceChildren(...nodes) {
		this.children = [];
		[].concat(nodes).forEach((c) => this.appendChild(c));
	}
	get innerHTML() { return this._html || ''; }
	set innerHTML(v) { this._html = v; this.children = []; }
}

function text(el) {
	if (el == null)
		return '';
	if (typeof el === 'string')
		return el;
	return (el.children || []).map(text).join('');
}

function walk(el, out) {
	out = out || [];
	if (el instanceof El) {
		out.push(el);
		(el.children || []).forEach((c) => walk(c, out));
	}
	return out;
}

function E(tag, attrs, children) {
	if (Array.isArray(attrs)) {
		children = attrs;
		attrs = {};
	}
	return new El(tag, attrs, children);
}

const inputs = {
	'#sbtv-pair-code': new El('input'),
	'#sbtv-pair-status': new El('span')
};

const manualInputs = {
	'sbtv-manual-screen': new El('input'),
	'sbtv-manual-name': new El('input'),
	'sbtv-manual-offset': new El('input')
};
Object.keys(manualInputs).forEach(id=>manualInputs[id].attrs.id=id);
manualInputs['sbtv-manual-screen'].value = '';
manualInputs['sbtv-manual-name'].value = '';
manualInputs['sbtv-manual-offset'].value = '0';

const pairSegments = [ new El('input'), new El('input'), new El('input') ];
pairSegments[0].value = '1234';
pairSegments[1].value = '5678';
pairSegments[2].value = '9012';

const documentStub = {
	querySelector: (sel) => inputs[sel] || null,
	querySelectorAll: (sel) => {
		if (sel === '.sbtv-pair-segment')
			return pairSegments;
		return [];
	},
	getElementById: id => manualInputs[id] || walk(dialog).find(el => el.attrs.id === id) || walk(FakeMap.instances[0]?.root).find(el => el.attrs.id === id)
};

const frameCallbacks = [];
const feedbackTimers=new Map(), scanTimers=new Map();let timerId=0;
const windowStub = { clearTimeout(id) {feedbackTimers.delete(id);scanTimers.delete(id);}, setTimeout(fn,ms) {const id=++timerId;if(ms===3000)feedbackTimers.set(id,fn);if(ms===400||ms===900)scanTimers.set(id,fn);return id;}, requestAnimationFrame: fn => frameCallbacks.push(fn) };

/* --------------------------------------------------------- LuCI module stubs */

const execCalls = [];
let pairFailure = null;
let offlinePolicy={skip_ads:'1',mute_ads:'1',auto_play:'1',skip_sponsorblock:'1',statistics:'0',skip_categories:'sponsor',minimum_skip_length:'1',controller_mode:'cooperative'};
let serviceRunning = false;
const fsStub = {
	exec: (cmd, params) => {
		execCalls.push({ cmd, params });
        if(cmd==='/usr/sbin/sponsorblocktv-policy'){
            if(params[0]==='set')offlinePolicy[params[2]]=params[3];
            return Promise.resolve({code:0,stdout:JSON.stringify({saved:params[0]==='set',policies:offlinePolicy,deferred:true})});
        }

        if (cmd === '/usr/sbin/sponsorblocktv-pair' && pairFailure) return Promise.resolve({code:1,stderr:pairFailure});
        if (cmd === '/usr/sbin/sponsorblocktv-pair') return Promise.resolve({ code: 0, stdout: JSON.stringify({ screen_id: 'paired-screen-fixture', name: 'Paired TV' }) });
		if (cmd === '/etc/init.d/sponsorblocktv') {
			if (params[0] === 'running') return Promise.resolve({ code: serviceRunning ? 0 : 1 });
			serviceRunning = params[0] !== 'stop';
		}
		return Promise.resolve({ code: 0, stdout: '', stderr: '' });
	}
};

const notifications = [];
let dialog;
const uiStub = {
	showModal: (title, children) => { dialog = E('div', {}, children); },
	hideModal: () => { dialog = null; },
	addNotification: (a, b, c) => notifications.push(c),
	createHandlerFn: (ctx, fn) => fn,
	changes: { apply: () => Promise.resolve() }
};

const loadCalls = [];
let configured = true, liveCalls = 0, liveRefresh;
let liveDevices = [], liveCommands = [], finishLiveCommand;
const fixtureDevice={'.name':'dev1',screen_id:'screen-abc'};
const policyWrites=[], newTVWrites=[];
const freshValues={};
const uciStub = {
    state:{values:{sponsorblocktv:{}}},
    callLoad:async()=>freshValues,
	load: (pkg) => { loadCalls.push(pkg); return Promise.resolve(); },
	sections: (pkg, type) => {
		// Return a fake device section so serviceAction's device check passes.
		if (type === 'device')
			return configured ? [fixtureDevice] : [];
		if (type === 'sponsorblocktv')
			return [{ '.name': 'main', enabled: '1' }];
		return [];
	},
	get: (pkg, section, opt) => {
		if (opt === 'enabled') return '1';
		return null;
	},
	set: (pkg,sid,key,value) => { if(sid==='dev1'){fixtureDevice[key]=value;policyWrites.push([sid,key,value]);} else if(sid==='newdev')newTVWrites.push([key,value]); },
    unset: (pkg,sid,key) => {if(sid==='dev1'){delete fixtureDevice[key];policyWrites.push([sid,key,null]);}},
	add: () => 'newdev',
	save: () => Promise.resolve(),
	apply: () => Promise.resolve()
};

const sections = [];
const options = [];

class FakeSection {
	constructor(cls, type, title, desc) {
		this.cls = cls;
		this.type = type;
        this.sectiontype=type;
		this.title = title;
		this.desc = desc;
		this.load=()=>Promise.resolve();
        this.render=()=>Promise.resolve(new El('div',{id:'cbi-sponsorblocktv-'+type}));
        this.handleAdd = () => uiStub.showModal('Native add', [E('p',{},['Channel editor'])]);
		sections.push({ cls, type, title });
	}
	tab(name,title){this.tabs=this.tabs||{};this.tabs[name]=title;}
    taboption(tab,cls,name,title,desc){const o=this.option(cls,name,title,desc);options[options.length-1].tab=tab;return o;}
	option(cls, name, title, desc) {
		const option = { value: () => true };
        options.push({ type: this.type, cls, name, title, option });
        return option;
	}
}

class FakeMap {
	constructor(config, title, desc) {
		this.config = config;
		this.title = title;
		this.desc = desc;
		this.sections = [];
		this.renderCount = 0;
		FakeMap.instances.push(this);
	}
	section(cls, type, title, desc) {
		const s = new FakeSection(cls, type, title, desc);
		this.sections.push(s);
		return s;
	}
	load() { return Promise.resolve({}); }
	renderContents() {
		this.renderCount++;
		this.root = this.root || new El('div');
		this.root.children = [];
        this.sections.forEach(s=>this.root.appendChild(new El('div',{id:'cbi-sponsorblocktv-'+s.type})));
		return Promise.resolve(this.root);
	}
	render() { return this.load().then(() => this.renderContents()); }
}
FakeMap.instances = [];

const formStub = {
	Map: FakeMap,
	TypedSection: 'TypedSection',
	GridSection: 'GridSection',
	Flag: class Flag { write() { return Promise.resolve(); } },
	Value: 'Value',
	MultiValue: 'MultiValue'
};

String.prototype.format = function () {
	const args = Array.prototype.slice.call(arguments);
	return this.replace(/%[sdj]/g, (m, i) => {
		const v = args.shift();
		return v == null ? m : String(v);
	});
};

const viewStub = { extend: (obj) => obj };

/* ----------------------------------------------------------- load the view */

const source = fs.readFileSync(VIEW, 'utf8');
const factory = new Function(
	'view', 'form', 'uci', 'fs', 'ui', '_', 'E', 'document', 'window', 'location', 'L', 'rpc', 'poll',
	source
);
const view = factory(
	viewStub, formStub, uciStub, fsStub, uiStub, (s) => s, E,
	documentStub, windowStub, { reload: () => {} }, {resource: p => '/luci-static/resources/'+p},
	{ declare: opts => (...args) => {
        if(opts.method==='policy'){
            const [id,key,value]=args;
            const d=liveDevices.find(d=>d.id===id);
            if(!d || !d.policy_ready)return Promise.resolve({error:'Unavailable'});
            if(value==='0' && key==='mute_ads')return Promise.resolve({error:'Fixture write failure'});
            d.policy_overrides=Object.assign({},d.policy_overrides,{[key]:value});
            return Promise.resolve({saved:true,policies:d.policy_overrides});
        }
        if (opts.method === 'control') { liveCommands.push(args); return new Promise(resolve => { finishLiveCommand = resolve; }); }
        liveCalls++; return Promise.resolve({ devices: liveDevices });
    } }, { add: fn => { liveRefresh = fn; } }
);

check('load() exported', typeof view.load === 'function');
check('render() exported', typeof view.render === 'function');

/* ------------------------------------------------------------- assertions */

const UCI_TEXT = fs.readFileSync(UCI, 'utf8');
check('managed TV terminology is consistent', !/\btr\(['"][^'"]*\bdevices?\b/i.test(fs.readFileSync(VIEW,'utf8')));

function uciMainOptions() {
	const names = [];
	for (const line of UCI_TEXT.split('\n')) {
		const m = /^\s*(?:option|list)\s+([a-z_]+)\s/.exec(line);
		if (m)
			names.push(m[1]);
	}
	return names;
}

function aclAllows(argv) {
	const acl = JSON.parse(fs.readFileSync(ACL, 'utf8'))['luci-app-sponsorblocktv'];
	const cmdstr = argv.join(' ');
	const patterns = []
		.concat(Object.keys(acl.read.file || {}))
		.concat(Object.keys(acl.write.file || {}));
	return patterns.some((p) => new RegExp('^' + p.replace(/[.+?^${}()|[\]\\]/g, '\\$&')
		.replace(/\*/g, '.*') + '$').test(cmdstr));
}

Promise.resolve()
	.then(() => view.load())
	.then(() => view.render())
	.then(async (mapEl) => {
		check('one initial dependency check scheduled', frameCallbacks.length === 1);
		frameCallbacks.shift()();
		await new Promise(resolve => setImmediate(resolve));
		const map = FakeMap.instances[0];
		configured = false;
		const before = liveCalls;
		await liveRefresh();
		check('empty TV configuration does not call missing live RPC', liveCalls === before);
		const emptyAdd = walk(map.root).find(el => el.tag === 'button' && text(el) === 'Add TV');
		check('empty live player offers Add TV', emptyAdd && emptyAdd.style.display === '');
		emptyAdd.attrs.click();
		check('empty player opens pairing modal', !!dialog && text(dialog).includes('Scan for TVs'));
		configured = true;
		await liveRefresh();
        liveDevices = [{ id: 'live-fixture', config_section:'dev1', policy_ready:true, policy_overrides:{skip_ads:'1',mute_ads:'1',auto_play:'1',skip_sponsorblock:'1',statistics:'0',skip_categories:'sponsor',minimum_skip_length:'1',controller_mode:'cooperative'}, name: 'Living room TV', connection: 'connected', playback: 1,
            duration: 120, position: 10, volume: 50, command_pending: false, command_status: 'sent' }];
        await liveRefresh();
        Object.assign(liveDevices[0],{video_id:'abcdefghijk',seek_start:20,seek_end:120,position:30,segments:[
            {start:10,end:40,UUID:['a']},{start:30,end:40,UUID:['b']},
            {start:70,end:90,UUID:['c']}
        ]});
        await liveRefresh();
        const markerLayer=walk(map.root).find(el=>el.attrs.class==='sbtv-seek-segments');
        const markerNodes=()=>markerLayer.children;
        const rail=walk(map.root).find(el=>el.attrs.class==='sbtv-seek-wrap');
        const played=walk(rail).find(el=>el.attrs.class==='sbtv-seek-played');
        check('segments directly on seek rail',walk(rail).includes(markerLayer) && walk(rail).some(el=>el.attrs.class==='sbtv-seek-input'));
        check('DVR offsets and skip-only ranges accurate',markerNodes().length===2 &&
            markerNodes().map(el=>el.attrs['data-mode']).join(',')==='skip,skip' &&
            markerNodes().map(el=>el.style.left+':'+el.style.width).join(',')==='0%:20%,50%:20%');
        check('played fill aligned with DVR',played.style.width==='10%');
        const details=walk(map.root).find(el=>el.attrs.class==='sbtv-segment-details');
        const ranges=walk(details).filter(el=>el.tag==='li');
        check('accessible segment ranges available',details.style.display==='' && ranges.length===2 && text(ranges[0]).includes('0:20') && text(ranges[0]).includes('0:40'));
        details.open=true;
        const skipButton=walk(map.root).find(el=>el._liveLabel==='Skip segment');
        check('active skip range offers manual skip',skipButton && skipButton.style.display==='' && !skipButton.disabled);
        liveDevices[0].position=55;await liveRefresh();
        check('outside segment hides manual skip',skipButton.style.display==='none');
        liveDevices[0].position=30;await liveRefresh();
        const originalMarker=markerNodes()[0];await liveRefresh();
        check('expanded range list survives polling',details.open && walk(details).filter(el=>el.tag==='li')[0]===ranges[0]);
        check('stable segment markers on poll',markerNodes()[0]===originalMarker);
        liveDevices[0].policy_overrides.skip_sponsorblock='0';await liveRefresh();
        check('disabled SponsorBlock removes cached markers',markerNodes().length===0 && skipButton.style.display==='none');
        liveDevices[0].policy_overrides.skip_sponsorblock='1';await liveRefresh();
        check('enabled SponsorBlock restores markers',markerNodes().length===2);
        liveDevices[0].ad_active=true;await liveRefresh();
        check('native ads hide segment markers',markerNodes().length===0 && details.style.display==='none' && !details.open);
        Object.assign(liveDevices[0],{ad_active:false,connection:'offline'});await liveRefresh();
        check('offline hides segment ranges',markerNodes().length===0 && details.style.display==='none');
        Object.assign(liveDevices[0],{connection:'connected',seek_start:0,seek_end:0,duration:0,segments:[{start:0,end:1},null]});await liveRefresh();
        check('unknown duration never invents marker',markerNodes().length===0);
        liveDevices[0].duration=120;liveDevices[0].seek_end=120;await liveRefresh();
        check('malformed segment ignored',markerNodes().length===1);
        Object.assign(liveDevices[0],{ad_active:false,video_id:'',seek_start:0,seek_end:120,position:10,segments:[]});await liveRefresh();
        let toggle = walk(map.root).find(el => el.tag === 'button' && /Pause/.test(el._liveLabel || ''));
        const originalIcon=toggle.children[0];
        await liveRefresh();
        check('unchanged polling preserves icon node',toggle.children[0]===originalIcon);
        check('one play/pause toggle', !!toggle && walk(map.root).filter(el => el.tag === 'button' && /^(?:Play|Pause)$/.test(el._liveLabel || '')).length === 1);
        let pendingToggle = toggle.attrs.click();
        check('pause action and spinner', liveCommands[0][1] === 'pause' && walk(toggle).some(el => el.attrs.class === 'sbtv-action-spinner'));
        liveDevices[0].playback = 2;
        finishLiveCommand({ accepted: true });
        await pendingToggle;
        check('toggle shows Play after pause', /Play/.test(toggle._liveLabel) && !walk(toggle).some(el => el.attrs.class === 'sbtv-action-spinner'));
        check('no command success message', !text(map.root).includes('Command sent to TV'));
        Object.assign(liveDevices[0], { playback: 1081, ad_active: true, ad_position: 5, ad_duration: 20, ad_can_skip: false });
        await liveRefresh();
        const skip = walk(map.root).find(el => el.tag === 'button' && el._liveLabel === 'Skip ad');
        check('non-skippable ad hides Skip and disables playback toggle', skip.style.display === 'none' && toggle.disabled);
        check('ad progress shown', walk(map.root).some(el => el.tag === 'progress' && el.value === 5 && el.max === 20));
        const adMarker=walk(map.root).find(el=>el.attrs.class==='sbtv-ad-skip-marker');
        const adStatus=walk(map.root).find(el=>el.attrs.class==='sbtv-ad-skip-status');
        Object.assign(liveDevices[0],{ad_skippable:true,ad_skip_estimated:true,ad_skip_at:5,ad_skip_in:3,ad_position:2});
        await liveRefresh();
        check('estimated skip countdown and marker',adStatus.textContent==='Estimated skip in: 3s' && adMarker.style.left==='25%' && adMarker.style.display==='block' && skip.disabled);
        Object.assign(liveDevices[0],{ad_skip_estimated:false,ad_skip_at:null,ad_skip_in:null});
        await liveRefresh();
        check('estimate expires without enabling skip',adStatus.textContent==='Waiting for TV to enable Skip' && skip.disabled);
        Object.assign(liveDevices[0],{ad_skippable:false});
        await liveRefresh();
        check('non-skippable status',adStatus.textContent==='Cannot skip this advertisement' && adMarker.style.display==='none');
        Object.assign(liveDevices[0],{ad_skippable:true,ad_skip_at:7});
        liveDevices[0].ad_can_skip = true;
        await liveRefresh();
        check('skippable ad shows enabled button', skip.style.display !== 'none' && !skip.disabled);
        check('confirmed skip status',adStatus.textContent==='Skip available now' && adMarker.style.left==='35%');
        const pendingSkip = skip.attrs.click();
        check('manual skip action', liveCommands[1][1] === 'skip_ad');
        Object.assign(liveDevices[0], { playback: 1, ad_active: false, ad_can_skip: false });
        finishLiveCommand({ accepted: true });
        await pendingSkip;
        check('skip hidden after ad, playback restored', skip.style.display === 'none' && !toggle.disabled);
        const muteBtn=walk(map.root).find(el=>el.tag==='button' && el._liveLabel==='Mute');
        const vol=walk(map.root).find(el=>el.tag==='input' && el.attrs['aria-label']==='Volume');
        check('playback controls use icons with accessible names', text(toggle)!=='Pause' && toggle.attrs['aria-label']==='Pause');
        check('mute icon represents next action',muteBtn._liveIcon==='volume-x');
        const muting=muteBtn.attrs.click();
        check('mute action sent', liveCommands[liveCommands.length-1][1]==='mute' && liveCommands[liveCommands.length-1][2]===1);
        liveDevices[0].muted=true;
        finishLiveCommand({accepted:true});
        await muting;
        check('muted slider gray and disabled, volume retained', vol.disabled && vol.style.filter==='grayscale(1)' && vol.value===50 && muteBtn.attrs['aria-pressed']==='true' && muteBtn.attrs['aria-label']==='Unmute');
        check('unmute icon represents next action',muteBtn._liveIcon==='volume-2');
        const unmuting=muteBtn.attrs.click();
        liveDevices[0].muted=false;
        finishLiveCommand({accepted:true});
        await unmuting;
        check('unmute restores slider', !vol.disabled && vol.style.filter==='' && vol.value===50);
        check('mute icon restored after unmute',muteBtn._liveIcon==='volume-x');
        Object.assign(liveDevices[0], {video_id:'abcdefghijk',ad_active:false});
        await liveRefresh();
        const transport=walk(map.root).find(el=>el.attrs.class==='sbtv-transport');
        check('five controls in one responsive row',transport.children.length===5);
        check('local Lucide playback icon',walk(toggle).some(el=>el.attrs.class==='sbtv-live-icon' && el.attrs.style.includes('/sponsorblocktv/icons/pause.svg')));
        check('speed picker removed',!walk(map.root).some(el=>el.attrs.class==='sbtv-speed-picker' || el.attrs.class==='sbtv-tools'));
        const remoteIcon=walk(map.root).find(el=>el.tag==='button' && el._liveLabel==='YouTube remote');
        const remoteUp=walk(map.root).find(el=>el.tag==='button' && el._liveLabel==='Up');
        check('remote hidden by default',remoteUp.parent.style.display==='none');
        remoteIcon.attrs.click();
        check('remote opens as 6-key grid',remoteUp.parent.style.display==='grid' && remoteUp.parent.children.length===6);
        const pressing=remoteUp.attrs.click();
        check('remote sends matching key',liveCommands[liveCommands.length-1][1]==='dpad' && liveCommands[liveCommands.length-1][3]==='UP');
        liveDevices[0].command_status='delivered';
        finishLiveCommand({accepted:true});await pressing;
        check('remote stays open for successive key presses',remoteUp.parent.style.display==='grid' && !remoteUp.disabled);
        const volumeRow=walk(map.root).find(el=>el.attrs.class==='sbtv-volume');
        check('remote last in volume row',volumeRow.children.length===4 && volumeRow.children[3]===remoteIcon);
        check('remote keyboard icon',remoteIcon._liveIcon==='keyboard');
        remoteIcon.attrs.click();
        check('remote closes',remoteUp.parent.style.display==='none');
        remoteIcon.attrs.click();
        await liveRefresh();
        check('poll keeps remote open',remoteUp.parent.style.display==='grid');
        liveDevices[0].ad_active=true;await liveRefresh();
        check('ad closes remote and disables it',remoteUp.parent.style.display==='none' && remoteIcon.disabled);
        liveDevices[0].ad_active=false;await liveRefresh();
        liveDevices[0].quality='1080';await liveRefresh();
        const qualityBadge=walk(map.root).find(el=>el.attrs.class==='sbtv-media-quality');
        check('quality remains read-only metadata',qualityBadge.textContent==='1080p' && !walk(map.root).some(el=>el.tag==='button' && /^Video quality/.test(el._liveLabel||'')));
        liveDevices[0].quality='hd720';await liveRefresh();
        check('quality badge updates',qualityBadge.textContent==='720p');
        liveDevices[0].ad_active=true;await liveRefresh();
        check('quality badge hidden during ad',qualityBadge.style.display==='none');
        check('quick autoplay removed',!walk(map.root).some(el=>el.tag==='button' && /^(Enable|Disable) autoplay$/.test(el.attrs['aria-label']||'')));
        Object.assign(liveDevices[0],{controllers:[{name:'SponsorBlockTV',self:true},{name:'Phone',self:false}],controller_count:2,controller_changes:[{kind:'joined',name:'Phone',self:false,age:0}],controller_conflict:null});
        await liveRefresh();
        const controllerLabel=walk(map.root).find(el=>el.attrs.class==='sbtv-controller-label');
        const controllerList=walk(map.root).find(el=>el.attrs.class==='sbtv-controller-list');
        const controllerNotice=walk(map.root).find(el=>el.attrs.class==='sbtv-controller-notice');
        check('controller count and reported names',controllerLabel.textContent==='Controllers (2)' && text(controllerList).includes('Phone') && text(controllerList).includes('This service'));
        const firstController=controllerList.children[0];await liveRefresh();
        check('controller nodes stable during poll',controllerList.children[0]===firstController);
        liveDevices[0].controller_conflict={age:1,action:'pause',count:1};await liveRefresh();
        check('possible conflict is qualified',controllerNotice.textContent.includes('Possible control conflict'));
        liveDevices[0].controllers=null;liveDevices[0].controller_count=null;await liveRefresh();
        check('unknown controller count not zero',controllerLabel.textContent.includes('Not reported'));
        const settings=walk(map.root).find(el=>el.tag==='button' && el.attrs['aria-label']==='TV settings');
        check('TV settings available even during ad',settings && !settings.disabled);
        settings.attrs.click();
        let policyInputs=walk(dialog).filter(el=>el.tag==='select');
        check('per-device controls explicit defaults',policyInputs.length===6 && policyInputs.filter(el=>['Skip native ads','Mute native ads','Autoplay','Video segments'].includes(el.attrs['aria-label'])).every(el=>el.value==='1') && policyInputs.some(el=>el.attrs['aria-label']==='Statistics' && el.value==='0') && policyInputs.some(el=>el.attrs['aria-label']==='Controller mode' && el.value==='cooperative'));
        check('categories checkbox only',walk(dialog).find(el=>el.attrs['aria-label']==='Enable category: Sponsor').checked && !walk(dialog).find(el=>el.attrs['aria-label']==='Enable category: Intro').checked && !policyInputs.some(el=>el.attrs['aria-label']==='Sponsor' || el.attrs['aria-label']==='Intro'));
        const statistics=policyInputs.find(el=>el.attrs['aria-label']==='Statistics');
        const statsBox=walk(map.root).find(el=>String(el.attrs.class||'').includes('sbtv-statistics'));
        const cardChildren=statsBox.parent.children;
        check('play video and queue removed',!text(statsBox.parent).includes('Play video and queue') && !walk(statsBox.parent).some(el=>/sbtv-(queue|search)-/.test(String(el.attrs.class||''))));
        check('statistics hidden by default',statsBox.style.display==='none');
        liveDevices[0].lifetime_stats={skips:3,ad_skips:2,ad_mutes:1,total_seconds:125};
        liveDevices[0].policy_overrides.statistics='1';await liveRefresh();
        const metric=k=>walk(statsBox).find(el=>el.attrs['data-stat']===k);
        check('statistics displays separate counters and total',statsBox.style.display==='' && metric('total_seconds').textContent==='0 hr 02 min 05 sec' && metric('ad_skips').textContent==='2' && metric('ad_mutes').textContent==='1' && metric('skips').textContent==='3');
        for(const [seconds,expected] of [[0,'0 hr 00 min 00 sec'],[3600,'1 hr 00 min 00 sec'],[93784,'26 hr 03 min 04 sec']]){
            liveDevices[0].lifetime_stats.total_seconds=seconds;await liveRefresh();
            check('explicit duration '+seconds,metric('total_seconds').textContent===expected);
        }
        check('two distinct statistics groups',walk(statsBox).filter(el=>el.attrs.class==='sbtv-stat-group').length===2);
        const oldMetric=metric('ad_skips');await liveRefresh();
        check('statistic nodes stable on polling',metric('ad_skips')===oldMetric);
        liveDevices[0].lifetime_stats.ad_skips=5;await liveRefresh();
        check('statistic updates in place',metric('ad_skips')===oldMetric && oldMetric.textContent==='5');
        liveDevices[0].lifetime_stats=null;await liveRefresh();
        check('unavailable totals do not show false zeroes',walk(statsBox).find(el=>el.attrs.class==='sbtv-stat-body').style.display==='none');
        liveDevices[0].policy_overrides.statistics='0';await liveRefresh();
        check('statistics disabled hides totals',statsBox.style.display==='none');
        const modeRow=walk(dialog).find(el=>String(el.attrs.class||'').includes('sbtv-policy-mode'));
        check('controller mode uses two logical grid children',modeRow && modeRow.children.length===2 && modeRow.children[1].attrs['aria-label']==='Controller mode');
        const skipSetting=policyInputs.find(el=>el.attrs['aria-label']==='Skip native ads');
        skipSetting.value='0';await skipSetting.attrs.change();
        check('realtime policy only changes this device',liveDevices[0].policy_overrides.skip_ads==='0' && policyWrites.length===0);
        const policyStatus=walk(dialog).find(el=>el.attrs.role==='status');
        check('successful save is silent',policyStatus.style.display==='none' && !feedbackTimers.has(policyStatus._feedbackTimer));
        const muteSetting=policyInputs.find(el=>el.attrs['aria-label']==='Mute native ads');
        muteSetting.value='0';await muteSetting.attrs.change();
        check('failed write rolls back selector',muteSetting.value==='1' && liveDevices[0].policy_overrides.mute_ads==='1');
        check('error remains visible',policyStatus.style.display==='block' && !feedbackTimers.has(policyStatus._feedbackTimer));

        walk(dialog).find(el=>el.tag==='button' && text(el)==='Done').attrs.click();
        settings.attrs.click();
        policyInputs=walk(dialog).filter(el=>el.tag==='select');
        const reset=policyInputs.find(el=>el.attrs['aria-label']==='Skip native ads');
        check('reopened settings preserve saved value',reset.value==='0');
        reset.value='1';await reset.attrs.change();
        check('explicit setting stored',liveDevices[0].policy_overrides.skip_ads==='1');
        const min=walk(dialog).find(el=>el.attrs['aria-label']==='Minimum segment length');
        min.value='3';await min.attrs.change();
        check('minimum stored realtime',liveDevices[0].policy_overrides.minimum_skip_length==='3');
        const enableIntro=walk(dialog).find(el=>el.attrs['aria-label']==='Enable category: Intro');
        enableIntro.checked=true;await enableIntro.attrs.change();
        check('enabled categories skip automatically',liveDevices[0].policy_overrides.skip_categories==='sponsor,intro');
        enableIntro.checked=false;await enableIntro.attrs.change();
        check('disabled category excluded',liveDevices[0].policy_overrides.skip_categories==='sponsor');
        enableIntro.checked=true;await enableIntro.attrs.change();
        const segmentsToggle=policyInputs.find(el=>el.attrs['aria-label']==='Video segments');
        const segmentOptions=walk(dialog).find(el=>el.attrs.class==='sbtv-segment-options');
        check('segment options visible initially',segmentOptions.style.display!=='none');
        const savedCategories=liveDevices[0].policy_overrides.skip_categories;
        segmentsToggle.value='0';await segmentsToggle.attrs.change();
        check('disabled segments hide options',segmentOptions.style.display==='none' && segmentOptions.attrs['aria-hidden']==='true');
        check('disabled segments retain policy',liveDevices[0].policy_overrides.skip_categories===savedCategories && liveDevices[0].policy_overrides.minimum_skip_length==='3');
        segmentsToggle.value='1';await segmentsToggle.attrs.change();
        check('enabled segments restore options',segmentOptions.style.display!=='none' && enableIntro.checked && min.value==='3');

        walk(dialog).find(el=>el.tag==='button' && text(el)==='Done').attrs.click();
        Object.assign(liveDevices[0],{ad_active:false,queue:['abcdefghijk','lmnopqrstuv'],queue_complete:true,video_id:'abcdefghijk',title:'Current song'});
        await liveRefresh();
        const prevBtn=walk(map.root).find(el=>el._liveLabel==='Previous');
        const nextBtn=walk(map.root).find(el=>el._liveLabel==='Next');
        check('unknown navigation disabled',prevBtn.disabled && nextBtn.disabled);
        Object.assign(liveDevices[0],{has_previous:false,has_next:true});await liveRefresh();
        check('first video next only',prevBtn.disabled && !nextBtn.disabled);
        Object.assign(liveDevices[0],{has_previous:true,has_next:false});await liveRefresh();
        check('last video previous only',!prevBtn.disabled && nextBtn.disabled);
        Object.assign(liveDevices[0],{has_previous:true,has_next:true});await liveRefresh();
        check('both navigation directions enabled',!prevBtn.disabled && !nextBtn.disabled);
        liveDevices[0].ad_active=true;await liveRefresh();
        check('ad disables both directions',prevBtn.disabled && nextBtn.disabled);
        liveDevices[0].ad_active=false;await liveRefresh();
        check('queue and search data do not render controls',!walk(map.root).some(el=>/sbtv-(queue|search)-/.test(String(el.attrs.class||''))||['YouTube URL or video ID','Search YouTube','Add to queue','Play next'].includes(el.attrs['aria-label'])||['Add to queue','Play next','Play video'].includes(el._liveLabel)));
        Object.assign(liveDevices[0],{connection:'checking',video_id:'',queue:null,queue_complete:false,volume:-1});
        await liveRefresh();
        const idleCard=walk(map.root).find(el=>el.attrs.class==='sbtv-live-card sbtv-enter');
        check('idle state marked for compact CSS',idleCard.attrs['data-has-video']==='false' && idleCard.attrs['data-ad-active']==='false');
        const liveBody=idleCard.children.find(el=>el.attrs.class==='sbtv-live-body');
        const header=idleCard.children.find(el=>el.attrs.class==='sbtv-tv-header');
        check('all connected controls grouped separately from header',idleCard.children.length===2 && !!liveBody && !!header);
        for(const phase of ['checking','connecting','reconnecting','offline','network_error','auth_error','unavailable','inactive','unknown']){
            liveDevices[0].connection=phase;await liveRefresh();
            check('header only during '+phase,idleCard.attrs['data-connected']==='false' && liveBody.hidden && liveBody.inert && liveBody.style.display==='none' && !walk(header).find(el=>el.attrs['aria-label']==='TV settings').disabled);
        }
        liveDevices[0].connection='connected';liveDevices[0].playback=-2;await liveRefresh();
        check('connected restores existing body',idleCard.attrs['data-connected']==='true' && !liveBody.hidden && !liveBody.inert && liveBody.style.display==='');

        check('connected with unknown playback omits Unknown suffix',walk(idleCard).some(el=>el.textContent==='Connected') && !walk(idleCard).some(el=>String(el.textContent).includes('Connected \u00b7 Unknown')));
        liveDevices[0].playback=-1;await liveRefresh();
        check('reported idle remains visible',walk(idleCard).some(el=>el.textContent==='Connected \u00b7 Idle'));

        liveDevices = [];
        await liveRefresh();
        const offlineSettings=walk(map.root).find(el=>el.attrs['aria-label']==='TV settings');
        check('configured inactive TV settings enabled',offlineSettings && !offlineSettings.disabled);
        await offlineSettings.attrs.click();
        const offSkip=walk(dialog).find(el=>el.attrs['aria-label']==='Skip native ads');
        check('inactive settings load durable policy',offSkip && offSkip.value==='1');
        offSkip.value='0';await offSkip.attrs.change();
        check('inactive setting saved without service start',offlinePolicy.skip_ads==='0' && execCalls.some(c=>c.cmd==='/usr/sbin/sponsorblocktv-policy' && c.params.join(' ')==='set dev1 skip_ads 0'));
        walk(dialog).find(el=>el.tag==='button' && text(el)==='Done').attrs.click();
        await offlineSettings.attrs.click();
        check('inactive setting survives reopening',walk(dialog).find(el=>el.attrs['aria-label']==='Skip native ads').value==='0');
        walk(dialog).find(el=>el.tag==='button' && text(el)==='Done').attrs.click();
        offlinePolicy.skip_ads='1';




		check('load() requests the sponsorblocktv config',
			loadCalls.includes('sponsorblocktv'), JSON.stringify(loadCalls));

		check('render() resolves to the map element', mapEl instanceof El);

		const mainOpts = options.filter((o) => o.type === 'sponsorblocktv').map((o) => o.name);
		const expectedMain = ['debug', 'http_tracing', 'data_dir', 'join_name',
			'apikey', 'skip_count_tracking', 'use_proxy', 'sponsorblock_api_url'];
		check('all main UCI options are bound',
			expectedMain.every((n) => mainOpts.includes(n)),
			'missing ' + JSON.stringify(expectedMain.filter((n) => !mainOpts.includes(n))));
		check('no unbound main options',
			mainOpts.every((n) => uciMainOptions().includes(n)),
			'extra ' + JSON.stringify(mainOpts.filter((n) => !uciMainOptions().includes(n))));

        for(const [type,name] of [['device','screen_id'],['whitelist','id'],['whitelist','name']]){
            const o=options.find(x=>x.type===type && x.name===name).option;
            check(type+' '+name+' required',o.rmempty===false && o.validate('fixture','')!==true && o.validate('fixture','  ')!==true);
        }
        const endpoint = options.find(o => o.name === 'sponsorblock_api_url').option;
        check('endpoint rejects invalid port', endpoint.validate('main','https://example.test:65536/api') !== true);
        check('endpoint rejects port zero', endpoint.validate('main','http://example.test:0/api') !== true);
        check('endpoint accepts IPv6', endpoint.validate('main','http://[::1]:8080/api') === true);
        check('general advanced tab grouping',options.filter(o=>o.type==='sponsorblocktv').every(o=>o.tab===(['debug','http_tracing','data_dir','use_proxy','sponsorblock_api_url'].includes(o.name)?'advanced':'general')));
        check('live TV before service control',map.root.children.findIndex(el=>el.attrs.class==='cbi-section sbtv-panel sbtv-live-section')<map.root.children.findIndex(el=>el.attrs.class==='cbi-section sbtv-panel sbtv-service-panel'));
        check('playback policies absent from common form',['skip_categories','minimum_skip_length','mute_ads','skip_ads','auto_play','skip_sponsorblock'].every(k=>!mainOpts.includes(k)));
		const devOpts = options.filter((o) => o.type === 'device').map((o) => o.name);
		check('device section binds name/screen_id/offset',
			['name', 'screen_id', 'offset'].every((n) => devOpts.includes(n)),
			JSON.stringify(devOpts));
		const wlOpts = options.filter((o) => o.type === 'whitelist').map((o) => o.name);
		check('whitelist section binds name/id',
			['name', 'id'].every((n) => wlOpts.includes(n)), JSON.stringify(wlOpts));

		check('single main TypedSection', sections.filter(
			(s) => s.cls === 'TypedSection' && s.type === 'sponsorblocktv').length === 1);

		function addDevice() {
			// The "Add device" button lives in the pairing modal (pairBox),
			// opened by the device section's handleAdd. Open it and find the
			// button in the dialog.
			const devSection = map.sections.find((s) => s.cls === 'GridSection' && s.type === 'device');
			if (devSection && typeof devSection.handleAdd === 'function')
				devSection.handleAdd();
			return dialog ? walk(dialog).find(el => el.tag === 'button' && el.attrs.id === 'sbtv-manual-submit' && text(el)==='Add TV') : null;
		}
		check('add device and service controls present', !!addDevice() && text(mapEl).includes('Service control'));
		// Exercise the real discovered-TV handler with deferred RPC completion.
		const originalExec = fsStub.exec;
        const wl = map.sections.find(section => section.type === 'whitelist');
        const originalAdd=uciStub.add, originalSave=uciStub.save, originalSet=uciStub.set;
        let channelAdds=0, channelSaves=0, channelWrites=[];
        uciStub.add=(pkg,type)=>{channelAdds++;return 'newchannel';};
        uciStub.save=()=>{channelSaves++;return Promise.resolve();};
        uciStub.set=(...args)=>channelWrites.push(args);
        const initialLoads=loadCalls.length, initialRenders=map.renderCount;
        for(let i=0;i<10;i++){
            wl.handleAdd();
            const name=documentStub.getElementById('sbtv-whitelist-name');
            const id=documentStub.getElementById('sbtv-whitelist-id');
            check('whitelist add opens immediately, empty and neutral',!!name && !!id && !name.value && !id.value && !name.attrs['aria-invalid']);
            name.value='Unsaved draft';
            walk(dialog).find(el=>el.tag==='button'&&text(el)==='Dismiss').attrs.click();
            check('dismiss closes immediately',!dialog);
        }
        check('ten cancelled drafts do not touch UCI or rerender',channelAdds===0&&channelSaves===0&&channelWrites.length===0&&loadCalls.length===initialLoads&&map.renderCount===initialRenders);
        wl.handleAdd();
        const name=documentStub.getElementById('sbtv-whitelist-name'), id=documentStub.getElementById('sbtv-whitelist-id');
        const saveChannel=walk(dialog).find(el=>el.tag==='button'&&text(el)==='Save');
        saveChannel.attrs.click();
        check('blank channel draft shows required errors',name.attrs['aria-invalid']==='true'&&id.attrs['aria-invalid']==='true'&&channelAdds===0);
        name.value='Example channel';id.value='UCabcdefghijklmnopqrstuv';
        name.attrs.input({target:name});id.attrs.input({target:id});
        check('valid channel clears errors',!name.attrs['aria-invalid']&&!id.attrs['aria-invalid']);
        const originalGridLoad=wl.load, originalGridRender=wl.render;
        let refreshes=0;
        wl.load=()=>{refreshes++;return Promise.resolve();};
        wl.render=()=>{refreshes++;return originalGridRender();};
        const settingsBefore=documentStub.getElementById('cbi-sponsorblocktv-sponsorblocktv');
        await saveChannel.attrs.click();
        check('save refreshes only whitelist grid',channelAdds===1&&channelSaves===1&&channelWrites.length===2&&refreshes===2&&!dialog&&map.renderCount===initialRenders&&documentStub.getElementById('cbi-sponsorblocktv-sponsorblocktv')===settingsBefore);
        wl.load=originalGridLoad;wl.render=originalGridRender;
        uciStub.add=originalAdd;uciStub.save=originalSave;uciStub.set=originalSet;
        check('LAN advertisement is absent', !options.some(opt => opt.name === 'advertise_lan'));
        check('LAN advertisement commands are absent', !JSON.stringify(JSON.parse(fs.readFileSync(ACL,'utf8'))).includes('sponsorblocktv-check-mdns') && !JSON.stringify(JSON.parse(fs.readFileSync(ACL,'utf8'))).includes('install-deps mdns'));
        addDevice();
		let finishAdd, addCalls = 0, addArgs;
		fsStub.exec = (cmd, args) => {
			if (cmd !== '/usr/sbin/sponsorblocktv-discover') return originalExec(cmd, args);
			if (args[0] === '--scan') return Promise.resolve({ code: 0, stdout: JSON.stringify({ scan_id: args[1], pending: false, unpaired: [{ id: '128ab78b-d6af-12a4-be36-daa5564b3830', name: 'Connectable Cast', host:'192.0.2.13', port:8009, source:'Cast' }, { id: 'cast-fixture', name: 'Cast without Screen ID', model: 'BRAVIA', manufacturer:'Sony', host:'192.0.2.12', port:8009, source:'Cast' }], devices: [{ name: 'Test TV', screen_id: 'test-screen', type: 'DIAL', source:'DIAL', manufacturer:'Samsung', model:'QN90C', host:'192.0.2.11', port:8008, application:'TizenTube', app_state:'running',uuid:'uuid:12345678-abcd-1234-abcd-123456789abc' }] }) });
			addCalls++;
            addArgs = args;
			return new Promise(resolve => { finishAdd = resolve; });
		};
		const scanBtn = walk(dialog).find(el => el.tag === 'button' && text(el) === 'Scan for TVs');
		let scanCalls = 0;
		const successExec = fsStub.exec;
		fsStub.exec = (cmd, args) => {
			if (cmd === '/usr/sbin/sponsorblocktv-discover' && args[0] === '--scan' && ++scanCalls === 1)
				return Promise.reject(new Error('Test scan timeout'));
			return successExec(cmd, args);
		};
		const sameDialog = dialog;
		const firstScan = scanBtn.attrs.click();
		check('scan stays focused and shows busy state', scanBtn.attrs['aria-disabled'] === 'true' && !scanBtn.disabled);
        check('scan allows closing but locks pairing', !documentStub.getElementById('sbtv-close-device').disabled && documentStub.getElementById('sbtv-pair-submit').disabled);
		scanBtn.attrs.click();
		await firstScan;
		check('scan failure stays in same modal and permits retry', dialog === sameDialog && scanBtn.textContent === 'Retry scan' && scanCalls === 1);
        check('scan failure unlocks other actions', !documentStub.getElementById('sbtv-close-device').disabled && !documentStub.getElementById('sbtv-pair-submit').disabled);
		await scanBtn.attrs.click();
		check('scan retry succeeds in same modal', dialog === sameDialog && scanBtn.textContent === 'Scan again' && scanCalls === 2);
        check('scan success visible with counts',text(documentStub.getElementById('sbtv-scan-status')).includes('Scan completed successfully.') && text(documentStub.getElementById('sbtv-scan-status')).includes('Ready to add: 2') && text(documentStub.getElementById('sbtv-scan-status')).includes('TV code required: 1'));
		check('unpaired receiver has guidance without redundant button', text(dialog).includes('Cast without Screen ID') && text(dialog).includes('Pair using the TV code below.') && !walk(dialog).some(el => el.tag === 'button' && text(el) === 'Use TV code'));
		fsStub.exec = successExec;
		const addBtn = walk(dialog).find(el => el.tag === 'button' && text(el) === 'Add TV');
        const deviceRow = addBtn.parent;
        const deviceStatus = deviceRow.children[2];
        check('ready devices appear first with consistent card styling', deviceRow.attrs['data-ready']==='true' && documentStub.getElementById('sbtv-discover-results').children[0]===deviceRow && deviceRow.attrs.class==='sbtv-discover-device');
        check('idle add feedback does not reserve blank space', deviceStatus.attrs.style.includes('display:none'));
        const codeNotice=walk(documentStub.getElementById('sbtv-discover-results')).find(el=>el.attrs['data-ready']==='false' && el.attrs['data-connect']!=='true');
        check('unpaired receiver uses single informational row', codeNotice && codeNotice.children.length===1 && !walk(codeNotice).some(el=>el.tag==='button') && codeNotice.attrs.class.includes('sbtv-discover-code-notice'));
        const advanced=walk(deviceRow).find(el=>el.tag==='details');
        check('compact ready identity and collapsed technical details', advanced && !advanced.open && text(advanced).includes('Port: 8008') && text(advanced).includes('UUID:') && text(deviceRow.children[0].children[1]).includes('Samsung'));
        check('IP address only appears inside device details',text(advanced).includes('IP address: 192.0.2.11') && deviceRow.children[0].children.filter(el=>el.tag!=='details').every(el=>!text(el).includes('192.0.2.11')));
        const unpairedAdvanced=walk(codeNotice).find(el=>el.tag==='details');
        check('unpaired IP also only appears in details',unpairedAdvanced && text(unpairedAdvanced).includes('IP address: 192.0.2.12') && codeNotice.children[0].children.filter(el=>el.tag!=='details').every(el=>!text(el).includes('192.0.2.12')));

        check('pair-only device has no action button and retains technical details', walk(codeNotice).some(el=>el.tag==='details') && !walk(codeNotice).some(el=>el.tag==='button'));
        check('ready device displays all advertised metadata', ['Manufacturer: Samsung','Model: QN90C','IP address: 192.0.2.11','Port: 8008','Application: TizenTube','Protocol: DIAL','Application status: Running','UUID: uuid:12345678-abcd-1234-abcd-123456789abc'].every(x=>text(deviceRow).includes(x)));
        check('unpaired device retains model, IP and manufacturer', ['Manufacturer: Sony','Model: BRAVIA','IP address: 192.0.2.12','Protocol: Cast'].every(x=>text(codeNotice).includes(x)) && !text(codeNotice).includes('Application:'));

		const pendingAdd = addBtn.attrs.click();
        check('busy feedback becomes visible', deviceStatus.style.display === 'block');
		check('add TV immediately shows busy state', addBtn.disabled && scanBtn.disabled && addBtn.textContent === 'Adding TV...');
		check('add TV shows progress', walk(dialog).some(el => el.tag === 'progress' && el.attrs['aria-label'] === 'Adding TV...'));
		addBtn.attrs.click();
		await Promise.resolve();
		check('duplicate add clicks ignored', addCalls === 1);
        check('add reuses completed scan and ACL permits it', addArgs.length === 4 && addArgs[2] === '--scan' && /^[a-f0-9]{32}$/.test(addArgs[3]) && aclAllows(['/usr/sbin/sponsorblocktv-discover'].concat(addArgs)));
		finishAdd({ code: 1, stdout: '{"error":"Test failure"}' });
		await pendingAdd;
		check('add failure enables retry', !addBtn.disabled && !scanBtn.disabled && addBtn.textContent === 'Retry add TV' && text(dialog).includes('Test failure'));
		const retryAdd = addBtn.attrs.click();
		await Promise.resolve();
        uciStub.state.values.sponsorblocktv.local={'.type':'device',name:'local draft'};
        freshValues.local={'.type':'device',name:'server version'};
        freshValues.newcast={'.type':'device',screen_id:'test-screen',name:'Test TV'};
		finishAdd({ code: 0, stdout: '{"added":true}' });

		await retryAdd;
        check('new discovery merged without overwriting cached local row',uciStub.state.values.sponsorblocktv.newcast.screen_id==='test-screen'&&uciStub.state.values.sponsorblocktv.local.name==='local draft');

		check('add success shows confirmation', addBtn.disabled && !scanBtn.disabled && addBtn.textContent === 'Added' && text(dialog).includes('TV added successfully.'));
        const connectRow=walk(dialog).find(el=>el.attrs['data-connect']==='true');
        const connectBtn=walk(connectRow).find(el=>el.tag==='button' && text(el)==='Add TV');
        check('no separate Connect TV button',!walk(dialog).some(el=>el.tag==='button' && text(el)==='Connect TV'));
        check('discovered Cast can be connected explicitly',connectBtn && !connectBtn.disabled);
        const pendingConnect=connectBtn.attrs.click();
        await Promise.resolve();
        check('connect uses scan ID and write ACL',addArgs[0]==='--add' && addArgs[1]==='cast:128ab78b-d6af-12a4-be36-daa5564b3830' && addArgs[2]==='--scan' && aclAllows(['/usr/sbin/sponsorblocktv-discover'].concat(addArgs)));
        finishAdd({code:1,stdout:'{"error":"Open YouTube or use the TV code"}'});
        await pendingConnect;
        check('connect failure offers retry',!connectBtn.disabled && connectBtn.textContent==='Retry add TV');
        // Real polling order: one screen is discovered before the scan completes.
        let finishScan, activeScanId, addDuringScanCalls=0, progressCount=0;
        const fixtureTV={name:'Early TV',screen_id:'early-screen',type:'Cast'};
        const secondTV={name:'Second TV',screen_id:'second-screen',type:'Cast'};
        const snapshotResult=(pending,devices)=>({code:0,stdout:JSON.stringify({scan_id:activeScanId,pending,devices,unpaired:[]})});
        fsStub.exec=(cmd,args)=>{
            if(cmd!=='/usr/sbin/sponsorblocktv-discover')return originalExec(cmd,args);
            if(args[0]==='--scan'){activeScanId=args[1];return new Promise(resolve=>{finishScan=resolve;});}
            if(args[0]==='--status'){progressCount++;return Promise.resolve(snapshotResult(true,progressCount===1?[fixtureTV]:[{...fixtureTV,manufacturer:"Sony",host:"192.0.2.20"},secondTV]));}
            addDuringScanCalls++;addArgs=args;return new Promise(resolve=>{finishAdd=resolve;});
        };
        async function pollScan(){
            const entry=scanTimers.entries().next().value;
            check('scan poll scheduled',!!entry);
            if(entry){scanTimers.delete(entry[0]);entry[1]();}
            for(let i=0;i<6;i++)await Promise.resolve();
        }
        const earlyScan=scanBtn.attrs.click();
        await pollScan();
        const earlyBtn=walk(documentStub.getElementById('sbtv-discover-results')).find(el=>el.tag==='button');
        check('early Add enabled before scan completion',earlyBtn && !earlyBtn.disabled && scanBtn.attrs['aria-busy']==='true' && !documentStub.getElementById('sbtv-discover-results').inert);
        const earlyAdd=earlyBtn.attrs.click();
        await Promise.resolve();
        check('early Add uses active scan id',addDuringScanCalls===1 && addArgs[3]===activeScanId);
        await pollScan();
        const duringRows=walk(documentStub.getElementById('sbtv-discover-results')).filter(el=>el.tag==='button');
        check('poll preserves adding row and locks other adds',duringRows[0]===earlyBtn && earlyBtn.textContent==='Adding TV...' && duringRows.length===2 && duringRows[1].disabled && text(earlyBtn.parent).includes('Manufacturer: Sony'));
        finishAdd({code:0,stdout:'{"added":true}'});
        await earlyAdd;
        check('early add success preserved while scan continues',earlyBtn.disabled && earlyBtn.textContent==='Added' && !duringRows[1].disabled && !documentStub.getElementById('sbtv-close-device').disabled);
        const secondAdd=duringRows[1].attrs.click();
        await Promise.resolve();
        finishScan(snapshotResult(false,[{...fixtureTV,manufacturer:"Sony",host:"192.0.2.20"},secondTV]));
        await earlyScan;
        check('scan finish does not unlock active add',scanBtn.disabled && documentStub.getElementById('sbtv-close-device').disabled && duringRows[1].textContent==='Adding TV...');
        finishAdd({code:0,stdout:'{"added":true}'});
        await secondAdd;
        check('both successes persist and modal unlocks',earlyBtn.disabled && duringRows[1].disabled && duringRows[1].textContent==='Added' && !scanBtn.disabled && !documentStub.getElementById('sbtv-close-device').disabled);

        documentStub.getElementById('sbtv-close-device').attrs.click();
        addDevice();
        check('completed scan does not persist on reopen',documentStub.getElementById('sbtv-discover-results').children.length===0 && scanBtn.textContent==='Scan for TVs');
		fsStub.exec = originalExec;

		return map.renderContents().then(() => {
			check('widgets survive reset without scheduling another dependency check',
				!!addDevice() && text(mapEl).includes('Service control') && frameCallbacks.length === 0);
			const manualBtn = addDevice();
            const noticeCount = notifications.length;
            const pairStatus = documentStub.getElementById('sbtv-pair-status');
            const screenInput=walk(dialog).find(el=>el.attrs.id==='sbtv-manual-screen');
            const screen=manualInputs['sbtv-manual-screen'];
            screen.value='';
            screenInput.attrs.input({target:screen});
            check('pristine manual field is not marked',!screen.attrs['aria-invalid']);
            screenInput.attrs.blur({target:screen});
            check('empty required field marked on blur',screen.attrs['aria-invalid']==='true');
            manualBtn.attrs.click();
            check('empty screen rejected on submit',text(documentStub.getElementById('sbtv-manual-screen-error')).includes('This field is required.') || documentStub.getElementById('sbtv-manual-screen-error').textContent==='This field is required.');
            screen.value='valid-screen-id';
            screenInput.attrs.input({target:screen});
            check('valid input immediately clears red state',!screen.attrs['aria-invalid']);
            check('optional name remains valid blank',!manualInputs['sbtv-manual-name'].attrs['aria-invalid']);
            manualInputs['sbtv-manual-screen'].value = 'bad';
            manualBtn.attrs.click();
            check('invalid screen ID stays inside modal', documentStub.getElementById('sbtv-manual-screen-error').textContent==='Invalid or duplicate Screen ID.' && pairStatus.style.display === 'none' && notifications.length === noticeCount);
            check('invalid screen ID marked', manualInputs['sbtv-manual-screen'].attrs['aria-invalid'] === 'true');
            manualInputs['sbtv-manual-screen'].value = 'screen-abc';
            manualBtn.attrs.click();
            check('duplicate screen ID stays inside modal', documentStub.getElementById('sbtv-manual-screen-error').textContent==='Invalid or duplicate Screen ID.' && notifications.length === noticeCount);
            manualInputs['sbtv-manual-screen'].value = 'valid-screen-id';
            manualInputs['sbtv-manual-offset'].value = 'invalid';
            manualBtn.attrs.click();
            check('invalid offset stays inside modal', documentStub.getElementById('sbtv-manual-offset-error').textContent==='Enter an offset from -10000 to 10000 ms.' && notifications.length === noticeCount);
            manualInputs['sbtv-manual-screen'].value = '';
            manualInputs['sbtv-manual-offset'].value = '0';
			check('re-render performed', map.renderCount === 2, String(map.renderCount));

			// pairing: capture the button handler and invoke it
			const pairBtn = walk(dialog).find((el) =>
				el.tag === 'button' && typeof el.attrs.click === 'function' &&
				text(el).includes('Pair TV'));
			check('pair button present', !!pairBtn);
			const codeInput=walk(dialog).find(el=>el.attrs.id==='sbtv-pair-code');
            check('pairing placeholder uses four groups of three',codeInput.attrs.placeholder==='000 000 000 000');
            const requiredCode=inputs['#sbtv-pair-code'];
            requiredCode.value='';
            codeInput.attrs.blur({target:requiredCode});
            check('empty TV code marked on blur',requiredCode.attrs['aria-invalid']==='true');
            requiredCode.value='123 456';
            codeInput.attrs.input({target:requiredCode});
            check('partial TV code remains marked',requiredCode.attrs['aria-invalid']==='true');
            requiredCode.value='';

            const field={value:'012345678901',selectionStart:12,setSelectionRange(a,b){this.selectionStart=a;this.selectionEnd=b;}};
            codeInput.attrs.input({target:field});
            check('12 digits format as four triples with leading zero',field.value==='012 345 678 901' && field.selectionStart===15);
            field.value='123-456-789-012';field.selectionStart=15;
            codeInput.attrs.input({target:field});
            check('pasted code normalized',field.value==='123 456 789 012');
            field.value='123 456';field.selectionStart=4;field.selectionEnd=4;
            codeInput.attrs.keydown({target:field,key:'Backspace'});
            check('backspace handles group separator',field.selectionStart===2 && field.selectionEnd===4);
            fixtureDevice.name='Paired TV';
            inputs['#sbtv-pair-code'].value = '123 456 789 012';
				execCalls.length = 0;
			return Promise.resolve(codeInput.attrs.input({target:inputs['#sbtv-pair-code']})).then(() => {
				check('complete input automatically execs pair helper',
					execCalls.length === 1 &&
					execCalls[0].cmd === '/usr/sbin/sponsorblocktv-pair',
					JSON.stringify(execCalls));
			check('pairing resolves code through existing helper',
				execCalls.length === 1 &&
				JSON.stringify(execCalls[0].params) ===
					JSON.stringify(['--list', '--code', '123456789012']),
				JSON.stringify(['--list', '--code', '123456789012']));
				check('pairing argv is ACL-covered',
					execCalls.length === 1 && aclAllows(
						['/usr/sbin/sponsorblocktv-pair'].concat(execCalls[0].params)));

                check('no name field in pair code mode', !walk(dialog).some(el => el.attrs.id === 'sbtv-pair-name'));
                check('new TV enables every category by default',newTVWrites.some(([key,value])=>key==='skip_categories'&&value==='sponsor,selfpromo,intro,outro,music_offtopic,interaction,exclusive_access,preview,filler,hook'));
                check('paired code saves without second click',inputs['#sbtv-pair-status'].style.display==='block' && text(inputs['#sbtv-pair-status']).includes('TV added successfully.'));
                const methodSelect=documentStub.getElementById('sbtv-add-method');
                methodSelect.attrs.change({target:{value:'pair'}});
                check('return to pair keeps submit hidden',documentStub.getElementById('sbtv-pair-submit').style.display==='none');
                check('return to pair clears previous code',inputs['#sbtv-pair-code'].value==='');
                methodSelect.attrs.change({target:{value:'manual'}});
                methodSelect.attrs.change({target:{value:'pair'}});
                check('repeated method changes keep submit hidden',documentStub.getElementById('sbtv-pair-submit').style.display==='none');
                return (async()=>{
                    pairFailure='2026-11-24 22:47:35 - pair - ERROR - pairing failed: invalid code, or the TV did not respond';
                    inputs['#sbtv-pair-code'].value='123 456 789 012';
                    await codeInput.attrs.input({target:inputs['#sbtv-pair-code']});
                    const failureText=text(inputs['#sbtv-pair-status']);
                    check('pair failure is concise',failureText.includes('Invalid TV code or TV not responding.') && !failureText.includes('2026-11-24') && !failureText.includes('ERROR'),failureText);
                    check('retry visible after failure',documentStub.getElementById('sbtv-pair-submit').style.display==='');
                    pairFailure=null;
                    methodSelect.attrs.change({target:{value:'manual'}});
                    methodSelect.attrs.change({target:{value:'pair'}});
                    check('retry hidden after method switch',documentStub.getElementById('sbtv-pair-submit').style.display==='none');
                })().then(()=>{

                delete fixtureDevice.name;

				// service control buttons
				const svcButtons = walk(mapEl).filter((el) =>
					el.tag === 'button' && typeof el.attrs.click === 'function' &&
					['Restart', 'Stop', 'Start'].some((l) => text(el).includes(l)));
				check('three service buttons present', svcButtons.length === 3,
					String(svcButtons.length));
				execCalls.length = 0;
				const button = action => documentStub.getElementById('sbtv-control-' + action);
				const visible = action => button(action) && !button(action).disabled;
				return (async () => {
					check('stopped controls', visible('start') && !visible('stop') && !visible('restart'));
					await Promise.all([button('start').attrs.click(), button('start').attrs.click()]);
					check('running controls', !visible('start') && visible('stop') && visible('restart'));
                    const serviceFeedback=documentStub.getElementById('sbtv-action-feedback');
                    check('service success auto hides',feedbackTimers.has(serviceFeedback._feedbackTimer));
                    const stale=feedbackTimers.get(serviceFeedback._feedbackTimer);
                    stale();
                    check('service success hidden',serviceFeedback.style.display==='none');

					await button('restart').attrs.click();
					await button('stop').attrs.click();
					check('stopped again', visible('start') && !visible('stop') && !visible('restart'));
				})().then(() => {
						const used = execCalls
							.filter((c) => c.cmd === '/etc/init.d/sponsorblocktv')
							.map((c) => c.params[0]).sort();
						check('service buttons exec init actions',
							JSON.stringify(used) === JSON.stringify(['restart', 'running', 'running', 'running', 'start', 'stop']),
							JSON.stringify(used));
						check('service exec argv is ACL-covered',
							execCalls.filter((c) => c.cmd === '/etc/init.d/sponsorblocktv')
								.every((c) => aclAllows([c.cmd].concat(c.params))));
					});
                });
			});
		});
	})
	.then(() => {
		if (failures.length) {
			console.error('luci_check.js FAILED:');
			failures.forEach((f) => console.error('  - ' + f));
			process.exit(1);
		}
		console.log(`luci_check.js OK (${options.length} options, ${sections.length} sections)`);
	})
	.catch((err) => {
		console.error('luci_check.js ERROR:', err && err.stack || err);
		process.exit(1);
	});