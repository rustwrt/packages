// config.uc - translate UCI configuration into upstream config.json.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// SponsorBlockTV reads a single JSON file (<data_dir>/config.json) and has no
// UCI awareness. This module reads `uci show sponsorblocktv` and produces the
// equivalent JSON document so the init script can remain a thin procd wrapper.

'use strict';

import * as fs from 'fs';
import * as util from './util.uc';

const PACKAGE = 'sponsorblocktv';

const DEFAULT_JOIN_NAME = 'SponsorBlockTV';
const DEFAULT_SPONSORBLOCK_API = 'https://sponsor.ajay.app/api/';
const DEFAULT_MINIMUM_SKIP_LENGTH = 1;

const VALID_CATEGORIES = [
	'sponsor', 'selfpromo', 'intro', 'outro', 'music_offtopic',
	'interaction', 'exclusive_access', 'preview', 'filler', 'hook',
];

// Policy declarations must precede build_config and runtime validation in ucode.
const POLICY_KEYS=['skip_ads','mute_ads','auto_play','skip_sponsorblock','statistics','skip_categories','minimum_skip_length','controller_mode'];
const NEW_TV_POLICY={skip_ads:'1',mute_ads:'1',auto_play:'1',skip_sponsorblock:'1',statistics:'0',skip_categories:join(',',VALID_CATEGORIES),minimum_skip_length:'1',controller_mode:'cooperative'};
function valid_policy_value(key,value,legacy){
    if(index(POLICY_KEYS,key)<0 || type(value)!='string')return false;
    if(legacy && value=='inherit')return true;
    if(key=='controller_mode')return index(['cooperative','standard','passive'],value)>=0;
    if(key=='minimum_skip_length')return !!match(value,/^(0|[1-9][0-9]{0,5})$/) && int(value)<=604800;
    if(key=='skip_categories'){
        if(value=='none')return true;
        let cats=split(value,','),seen={};
        if(!length(cats) || length(cats)>length(VALID_CATEGORIES))return false;
        for(let cat in cats){if(index(VALID_CATEGORIES,cat)<0 || seen[cat])return false;seen[cat]=true;}
        return true;
    }
    return index(['0','1'],value)>=0;
}

// --- UCI parsing ----------------------------------------------------------

// Parse `uci show <package>` output into an ordered section list.
// Each entry: { name, type, options: {}, lists: {} }.
function parse_uci_show(text) {
	let sections = {};
	let order = [];

	function ensure_section(name) {
		if (!sections[name]) {
			sections[name] = { name: name, type: '', options: {}, lists: {} };
			order[length(order)] = name;
		}
		return sections[name];
	}

	function add_value(section, key, value) {
		if (key in section.lists) {
			section.lists[key][length(section.lists[key])] = value;
		}
		else if (key in section.options) {
			// A repeated scalar option is a UCI list (uci show has no marker).
			let first = section.options[key];
			delete section.options[key];
			section.lists[key] = [ first, value ];
		}
		else {
			section.options[key] = value;
		}
	}

	function unquote(v) {
		v = util.trim(v);
		if (length(v) >= 2) {
			let first = substr(v, 0, 1);
			let last = substr(v, length(v) - 1, 1);
			if (first == last && (first == "'" || first == '"'))
				return join("'",split(substr(v,1,length(v)-2), "'\\''"));
		}
		return v;
	}

	let lines = split(text, '\n');
	for (let li = 0; li < length(lines); li++) {
		let line = util.trim(lines[li]);
		if (!line)
			continue;

		// `uci export` spelling: "list <package>.<section>.<option> 'value'".
		if (match(line, /^list /)) {
			let rest = util.trim(substr(line, 5));
			let sp = index(rest, ' ');
			let key = sp < 0 ? rest : substr(rest, 0, sp);
			let raw = sp < 0 ? '' : util.trim(substr(rest, sp + 1));
			line = key + '=' + raw;
		}

		let eq = index(line, '=');
		if (eq < 0)
			continue;
		let left = util.trim(substr(line, 0, eq));
		let right = unquote(substr(line, eq + 1));

		let dots = split(left, '.');
		if (length(dots) < 2)
			continue;
		let pkg = dots[0];
		if (pkg != PACKAGE)
			continue;

		if (length(dots) == 2) {
			// Section header such as "sponsorblocktv.main=device".
			let section = ensure_section(dots[1]);
			section.type = right;
			continue;
		}

		let section_name = dots[1];
		let option = join('.', slice(dots, 2));
		let section = ensure_section(section_name);

		if (match(option, /^list /)) {
			let key = util.trim(substr(option, 5));
			if (!section.lists[key])
				section.lists[key] = [];
			section.lists[key][length(section.lists[key])] = right;
		}
		else {
			add_value(section, option, right);
		}
	}

	let result = [];
	for (let i = 0; i < length(order); i++)
		result[length(result)] = sections[order[i]];
	return result;
}

function section_by_type(sections, stype) {
	for (let i = 0; i < length(sections); i++)
		if (sections[i].type == stype)
			return sections[i];
	return { name: '', type: stype, options: {}, lists: {} };
}

function sections_by_type(sections, stype) {
	let out = [];
	for (let i = 0; i < length(sections); i++)
		if (sections[i].type == stype)
			out[length(out)] = sections[i];
	return out;
}

// Return every value for `key` whether UCI stored a list or a scalar.
function values(section, key) {
	if (key in section.lists)
		return section.lists[key];
	let v = section.options[key];
	if (v == null)
		return [];
	let text = util.trim('' + v);
	return text ? [ text ] : [];
}

// --- config.json construction ---------------------------------------------

function build_config(sections) {
	let main = section_by_type(sections, 'sponsorblocktv');
	let opts = main.options;

	let devices = [];
	let seen_screen_ids = {};
	let device_sections = sections_by_type(sections, 'device');
	for (let i = 0; i < length(device_sections); i++) {
		let section = device_sections[i];
		let screen_id = util.trim('' + (section.options.screen_id || ''));
		if (!screen_id)
			continue; // skip until paired
		if (seen_screen_ids[screen_id]) {
			util.warn('config', sprintf('Ignoring duplicate device %s (already defined by section %s)',
				section.name, seen_screen_ids[screen_id]));
			continue;
		}
		let offset=util.trim(section.options.offset??'')||'0';
		if(!match(''+offset,/^-?[0-9]{1,6}$/) || int(offset)<-10000 || int(offset)>10000)die('Invalid device offset in '+section.name+' (range -10000..10000 ms)');
		seen_screen_ids[screen_id] = section.name;
        let device = {
            screen_id: screen_id,
            name: util.trim('' + (section.options.name || '')) || 'YouTube on TV',
            offset: int(offset),
        };
        // Stable UCI section IDs are provided by uci -X, not positional aliases.
        if(match(section.name,/^[A-Za-z0-9_]+$/))device.config_section=section.name;
        for(let key in ['mute_ads','skip_ads','auto_play','skip_sponsorblock','statistics']){
            let value=section.options[key];
            if(section.lists[key]!=null)die('Invalid device policy list: '+key);
            if(value==null || value=='' || value=='inherit')continue;
            if(value!='0' && value!='1')die('Invalid device policy: '+key);
            device[key]=value=='1';
        }
        for(let key in ['skip_categories','minimum_skip_length','controller_mode']){
            let value=section.options[key];
            if(section.lists[key]!=null)die('Invalid device policy list: '+key);
            if(value!=null && value!='inherit'){
                if(!valid_policy_value(key,value,false))die('Invalid device policy: '+key);
                device[key]=key=='skip_categories'?(value=='none'?[]:split(value,',')):index(['controller_mode'],key)>=0?value:int(value);
            }
        }
        push(devices,device);
	}

	let whitelist = [], seen_channels={};
	let whitelist_sections = sections_by_type(sections, 'whitelist');
	for (let i = 0; i < length(whitelist_sections); i++) {
		let section = whitelist_sections[i];
		let channel_id = util.trim('' + (section.options.id || ''));
		if (!channel_id || seen_channels[channel_id])
			continue;
		seen_channels[channel_id]=true;
		whitelist[length(whitelist)] = {
			id: channel_id,
			name: util.trim('' + (section.options.name || '')),
		};
	}

	let skip_categories = [];
	let raw_cats = values(main, 'skip_categories');
	let expanded=[];
	for(let raw in raw_cats)for(let cat in split(raw,"' '"))push(expanded,cat);
	raw_cats=expanded;
	for (let i = 0; i < length(raw_cats); i++) {
		let category = util.trim(raw_cats[i]);
		if (!category)
			continue;
		if(category=='none')continue;
		if (index(VALID_CATEGORIES, category) < 0) {
			util.warn('config', sprintf('Ignoring unknown SponsorBlock category %r', category));
			continue;
		}
		if (index(skip_categories, category) < 0)
			skip_categories[length(skip_categories)] = category;
	}
	if (opts.skip_categories == null && !main.lists.skip_categories)
		skip_categories = [ 'sponsor' ];
	if(index(raw_cats,'none')>=0)skip_categories=[];

	let minimum=opts.minimum_skip_length;
	if(minimum==null || minimum=='')minimum=''+DEFAULT_MINIMUM_SKIP_LENGTH;
	if(!match(''+minimum,/^[0-9]{1,6}$/) || int(minimum)>604800)die('Invalid minimum segment length (0..604800 seconds)');
	return {
		devices: devices,
		skip_categories: skip_categories,
		skip_count_tracking: util.to_bool(opts.skip_count_tracking, true),
		mute_ads: util.to_bool(opts.mute_ads, true),
		skip_ads: util.to_bool(opts.skip_ads, true),
		minimum_skip_length: int(minimum),
		auto_play: util.to_bool(opts.auto_play, true),
		join_name: util.trim('' + (opts.join_name || '')) || DEFAULT_JOIN_NAME,
		apikey: util.trim('' + (opts.apikey || '')),
		channel_whitelist: whitelist,
		use_proxy: util.to_bool(opts.use_proxy, false),
		sponsorblock_api_url: util.normalize_api_url(opts.sponsorblock_api_url || DEFAULT_SPONSORBLOCK_API),
	};
}

function validate_runtime_config(cfg,allow_empty){
    if(type(cfg)!='object' || type(cfg.devices)!='array' || (!allow_empty && !length(cfg.devices)))die('No paired devices in configuration');
    if(length(cfg.devices)>64)die('Maximum 64 configured devices');
    let seen={};
    for(let d in cfg.devices){
        if(type(d)!='object' || type(d.screen_id)!='string' || !match(d.screen_id,/^[A-Za-z0-9_-]{8,128}$/))die('Invalid device Screen ID');
        if(seen[d.screen_id])die('Duplicate device Screen ID');
        seen[d.screen_id]=true;
        if(d.config_section!=null && (type(d.config_section)!='string' || !match(d.config_section,/^[A-Za-z0-9_]+$/)))die('Invalid device config section');
        for(let key in ['mute_ads','skip_ads','auto_play','skip_sponsorblock','statistics'])if(d[key]!=null && type(d[key])!='bool')die('Invalid device policy: '+key);
        if(d.skip_categories!=null){
            if(type(d.skip_categories)!='array' || length(d.skip_categories)>length(VALID_CATEGORIES))die('Invalid device categories');
            for(let cat in d.skip_categories)if(index(VALID_CATEGORIES,cat)<0)die('Invalid device category');
        }
        if(d.controller_mode!=null && !valid_policy_value('controller_mode',d.controller_mode,false))die('Invalid controller mode');
        if(d.minimum_skip_length!=null && (type(d.minimum_skip_length)!='int' || d.minimum_skip_length<0 || d.minimum_skip_length>604800))die('Invalid device minimum segment length');
        if(d.offset!=null && (type(d.offset)!='int' || d.offset < -10000 || d.offset > 10000))die('Invalid device offset');
        if(d.name!=null && (type(d.name)!='string' || length(d.name)>200 || match(d.name,/[[:cntrl:]]/)))die('Invalid device name');
    }
    if(cfg.skip_categories!=null){
        if(type(cfg.skip_categories)!='array')die('Invalid categories');
        for(let cat in cfg.skip_categories)if(index(VALID_CATEGORIES,cat)<0)die('Unknown SponsorBlock category');
    }
    if(cfg.channel_whitelist!=null){
        if(type(cfg.channel_whitelist)!='array' || length(cfg.channel_whitelist)>1024)die('Invalid channel whitelist');
        for(let ch in cfg.channel_whitelist)if(type(ch)!='object' || type(ch.id)!='string' || !length(ch.id) || length(ch.id)>128 || match(ch.id,/[[:cntrl:]]/))die('Invalid whitelist channel');
    }
    if(cfg.minimum_skip_length!=null && (type(cfg.minimum_skip_length)!='int' || cfg.minimum_skip_length<0 || cfg.minimum_skip_length>604800))die('Invalid minimum segment length');
    for(let k in ['mute_ads','skip_ads','auto_play','skip_count_tracking','use_proxy'])if(cfg[k]!=null && type(cfg[k])!='bool')die('Invalid boolean setting: '+k);
    if(cfg.apikey!=null && (type(cfg.apikey)!='string' || length(cfg.apikey)>512 || match(cfg.apikey,/[[:cntrl:]]/)))die('Invalid API key');
    if(cfg.join_name!=null && (type(cfg.join_name)!='string' || !length(cfg.join_name) || length(cfg.join_name)>200 || match(cfg.join_name,/[[:cntrl:]]/)))die('Invalid join name');
    util.normalize_api_url(cfg.sponsorblock_api_url);
    return true;
}

// --- file writing ---------------------------------------------------------

function validate_data_dir(data_dir) {
    if (type(data_dir) != 'string' || !match(data_dir, /^\/(etc\/sponsorblocktv|mnt|overlay|root|tmp\/sponsorblocktv)\/[A-Za-z0-9_.\/-]+$/) ||
        match(data_dir, /(^|\/)\.\.?($|\/)/) || match(data_dir, /\/\//))
        die('invalid data directory: use a dedicated directory under /etc/sponsorblocktv, /mnt, /overlay, /root or /tmp/sponsorblocktv');
    let cur='';
    for(let part in split(data_dir,'/')) {
        if(!part) continue;
        cur+='/'+part;
        let st=fs.lstat(cur);
        if(st && (st.type!='directory' || st.uid!=0 || (cur!='/tmp' && (st.mode & 18)))) die('unsafe data directory component: '+cur);
    }
    if(match(data_dir,/\/$/)) die('data directory must not end with slash');

}
function write_config(config, data_dir) {
    validate_data_dir(data_dir);
	// Ensure the parent directory exists (fs.mkdir does not create parents).
	let parent = fs.dirname(data_dir);
	if (!fs.stat(parent) && !fs.mkdir(parent, 0755)) die('cannot create ' + parent);
	if (!fs.stat(data_dir) && !fs.mkdir(data_dir, 0700)) die('cannot create ' + data_dir);
	if (!fs.chmod(data_dir, 0700)) die('cannot protect data directory');

	let path = data_dir + '/config.json';
	let tmp_path = path + '.' + fs.readlink('/proc/self') + '.tmp';
	let text = util.json_dumps(config) + '\n';
	if(length(text)>1048576)die('Configuration exceeds 1 MiB');
	if (fs.lstat(tmp_path)) die('temporary config path already exists');
	let f=fs.open(tmp_path,'w',0600);
	let written=f ? f.write(text) : 0;
	if(f)f.close();
	if (written != length(text) || !fs.chmod(tmp_path, 0600) || !fs.rename(tmp_path, path)) {
		fs.unlink(tmp_path);
		die('cannot write ' + path);
	}
	return path;
}

// Separate atomic device policy record: never commit unrelated UCI changes.
function initial_policy(config,device){
    // Old global fields are read only to migrate TVs without their own seed.
    let p={};
    for(let key in POLICY_KEYS){
        let v=device[key]??config[key];
        if(v==null)p[key]=NEW_TV_POLICY[key];
        else if(key=='skip_categories')p[key]=length(v)?join(',',v):'none';
        else if(key=='minimum_skip_length' || key=='controller_mode')p[key]=''+v;
        else p[key]=v?'1':'0';
    }
    return p;
}
function validate_policy(policy){
    if(type(policy)!='object')die('Invalid TV policy');
    for(let key in keys(policy))
        if(!valid_policy_value(key,policy[key],true))die('Invalid TV policy option');
    return policy;
}
// Persist only aggregate counters, never video IDs or viewing history.
function stats_path(data_dir,id){
    validate_data_dir(data_dir);
    if(type(id)!='string' || !match(id,/^[a-f0-9]{32}$/))die('Invalid TV statistics ID');
    return data_dir+'/tv-stats-'+id+'.json';
}
function validate_stats(s){
    let fields=['skips','milliseconds','ad_skips','ad_milliseconds','ad_mutes'];
    if(type(s)!='object' || length(keys(s))!=5)die('Invalid TV statistics');
    let result={};
    for(let k in fields){
        let v=s[k];
        if(type(v)!='int' || v<0 || v>(index(['milliseconds','ad_milliseconds'],k)>=0?9007199254740991:1000000000))die('Invalid TV statistics');
        result[k]=v;
    }
    return result;
}
function read_stats(dir,id){
    let path=stats_path(dir,id),st=fs.lstat(path);
    if(!st)return {skips:0,milliseconds:0,ad_skips:0,ad_milliseconds:0,ad_mutes:0};
    if(st.type!='file' || st.uid!=0 || (st.mode & 63) || st.size<2 || st.size>256)die('Unsafe TV statistics file');
    return validate_stats(json(fs.readfile(path)));
}
function save_stats(dir,id,s){
    s=validate_stats(s);
    let path=stats_path(dir,id);read_stats(dir,id);
    let tmp=path+'.'+fs.readlink('/proc/self')+'.tmp';
    if(fs.lstat(tmp))die('Statistics temporary file exists');
    let text=util.json_dumps(s)+'\n',f=fs.open(tmp,'w',0600),written=f?f.write(text):0;
    if(f)f.close();
    if(written!=length(text) || !fs.chmod(tmp,0600) || !fs.rename(tmp,path)){
        fs.unlink(tmp);die('Cannot save TV statistics');
    }
}
function policy_path(data_dir,id){
    validate_data_dir(data_dir);
    if(type(id)!='string' || !match(id,/^[a-f0-9]{32}$/))die('Invalid TV policy ID');
    return data_dir+'/tv-policy-'+id+'.json';
}
function read_policy(data_dir,id){
    let path=policy_path(data_dir,id),st=fs.lstat(path);
    if(!st)return {};
    if(st.type!='file' || st.uid!=0 || (st.mode & 63) || st.size<2 || st.size>4096)die('Unsafe TV policy file');
    let text=fs.readfile(path);
    if(type(text)!='string' || length(text)>4096)die('Cannot read TV policy');
    return validate_policy(json(text));
}
function save_policy(data_dir,id,policy){
    validate_policy(policy);
    let path=policy_path(data_dir,id);
    // Refuse to replace a malformed or unsafe existing record.
    read_policy(data_dir,id);
    let tmp=path+'.'+fs.readlink('/proc/self')+'.tmp';
    if(fs.lstat(tmp))die('Temporary TV policy file exists');
    let text=util.json_dumps(policy)+'\n',f=fs.open(tmp,'w',0600);
    let written=f?f.write(text):0;
    if(f)f.close();
    if(written!=length(text) || !fs.chmod(tmp,0600) || !fs.rename(tmp,path)){
        fs.unlink(tmp);die('Cannot save TV policy');
    }
    return true;
}

// --- CLI ------------------------------------------------------------------

function read_uci() {
	// Honour an SBTV_UCI_CMD override (tests).
	let override = getenv('SBTV_UCI_CMD');
	let argv;
	if (override)
		argv = [ ...split(override, ' '), 'show', PACKAGE ];
	else
		argv = [ 'uci', '-q', '-X', 'show', PACKAGE ];

	let proc = fs.popen(util.shell_command(argv), 'r');
	if (!proc) die('could not start uci');
	let out = proc.read('all') || '';
	let rc = proc.close();
	if (rc != 0)
		die(sprintf("'%s' failed (%d)", join(' ', argv), rc));
	return out;
}

function main(argv) {
	let data_dir = null;
	if (length(argv) >= 2)
		data_dir = argv[1];
	if (!data_dir)
		data_dir = getenv('SBTV_DATA_DIR') || '/etc/sponsorblocktv/data';

	let text;
	try {
		text = read_uci();
	}
	catch (e) {
		util.error('write-config', '' + e);
		return 1;
	}

	let config = build_config(parse_uci_show(text));
	validate_runtime_config(config,true);
	let path = write_config(config, data_dir);
	util.info('write-config', sprintf('Wrote %s (%d device(s))', path, length(config.devices)));
	return 0;
}

export {
	parse_uci_show, build_config, write_config, read_uci, main,
	PACKAGE, VALID_CATEGORIES, validate_data_dir, validate_runtime_config, POLICY_KEYS, NEW_TV_POLICY, initial_policy, valid_policy_value, read_policy, save_policy, validate_policy, read_stats, save_stats
};
