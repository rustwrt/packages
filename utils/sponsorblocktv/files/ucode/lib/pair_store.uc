// pair_store.uc - store a paired device into UCI (shared by pair/discover).
// SPDX-License-Identifier: GPL-3.0-or-later

'use strict';

import * as fs from 'fs';
import * as util from './util.uc';
import {parse_uci_show,NEW_TV_POLICY} from './config.uc';

const PACKAGE = 'sponsorblocktv';

function uci_command(args) {
	let override = getenv('SBTV_UCI_BIN');
	let base = override ? split(override, ' ') : [ 'uci' ];
	return [ ...base, ...args ];
}

function uci_output(args) {
	let proc = fs.popen(util.shell_command(uci_command(args)), 'r');
	if (!proc) die('could not start uci');
	let out = proc.read('all') || '';
	let rc = proc.close();
	if (rc != 0)
		die('uci '+args[0]+' failed');
	return out;
}

function uci(args) {
	uci_output(args);
}

function section_exists(section) {
	try {
		uci_output([ 'get', PACKAGE + '.' + section ]);
		return true;
	}
	catch (e) {
		return false;
	}
}

function section_type(section) {
	if (match(section, /^@/)) {
		let m = match(section, /^@([^\[]+)/);
		return m ? m[1] : 'device';
	}
	return 'device';
}

function plan_device(sections,section,screen_id,name){
    section=section??'';
    if(type(screen_id)!='string' || !match(screen_id,/^[A-Za-z0-9_-]{8,128}$/))die('invalid Screen ID');
    if(type(section)!='string' || (section && !match(section,/^([A-Za-z0-9_]+|@device\[[0-9]+\])$/)))die('invalid device section');
    if(name!=null && (type(name)!='string' || length(name)>200 || match(name,/[[:cntrl:]]/)))die('invalid device name');
    let devices=filter(sections,(d)=>d.type=='device'), target=null, existing=null, count=0;
    let alias=match(section,/^@device\[([0-9]+)\]$/);
    if(alias){let i=int(alias[1]);if(i<0 || i>=length(devices))die('section is not an existing device');section=devices[i].name;}
    for(let d in devices){
        let id=util.trim(d.options.screen_id||'');
        if(d.name==section)target=d;
        if(id){count++;if(id==screen_id){if(!existing)existing=d;if(section && d.name!=section)die('Screen ID already registered in another device');}}
    }
    if(section && !target)die('section is not an existing device');
    if(existing && !section)return {section:existing.name,unchanged:true};
    if(count>=64 && (!target || !util.trim(target.options.screen_id||'')))die('Maximum 64 configured devices');
    return {section:section,unchanged:false};
}
// Allocate a display name for new devices only; Screen ID remains identity.
function unique_device_name(sections,name,exclude){
    let base=util.trim(name||'')||'YouTube on TV',used={};
    for(let d in sections){
        if(d.type=='device' && d.name!=exclude && util.trim(d.options.screen_id||''))
            used['name:'+lc(util.trim(d.options.name||'')||'YouTube on TV')]=true;
    }
    if(!used['name:'+lc(base)])return base;
    for(let i=2;i<=65;i++){
        let suffix=' #'+i,candidate=substr(base,0,200-length(suffix))+suffix;
        if(!used['name:'+lc(candidate)])return candidate;
    }
    die('Cannot allocate device display name');
}
function store_locked(section, screen_id, name) {
    let sections=parse_uci_show(uci_output(['-X','show',PACKAGE]));
    let plan=plan_device(sections,section,screen_id,name);
    let existing=filter(sections,(d)=>d.type=='device' && d.name==plan.section)[0];
    let new_device=!existing || util.trim(existing.options.screen_id||'')!=screen_id;
    section=plan.section;
    if(plan.unchanged)return section;
    if(new_device)name=unique_device_name(sections,name,section);
	if (!section) {
		let created = util.trim(uci_output([ 'add', PACKAGE, section_type(section) ]));
		if (!match(created,/^[A-Za-z0-9_]+$/))
			die('uci add did not return a valid section identifier');
		section = created;
	}

	uci([ 'set', PACKAGE + '.' + section + '.screen_id=' + screen_id ]);
	if (name)
		uci([ 'set', PACKAGE + '.' + section + '.name=' + name ]);
    if(new_device)for(let key in keys(NEW_TV_POLICY))
        uci(['set',PACKAGE+'.'+section+'.'+key+'='+NEW_TV_POLICY[key]]);
	uci([ 'commit', PACKAGE ]);
	fs.chmod('/etc/config/sponsorblocktv',0600);
	return section;
}

function store_device(section,screen_id,name) {
    let lock='/tmp/sbtv-pair-lock';
    if(!fs.mkdir(lock,0700)) {
        let st=fs.lstat(lock);
        if(!st || st.uid!=0 || st.type!='directory' || time()-st.mtime<60 || !fs.rmdir(lock) || !fs.mkdir(lock,0700))
            die('Another pairing operation is active');
    }
    let result,error;
    try {result=store_locked(section,screen_id,name);} catch(e){error=e;}
    fs.rmdir(lock);
    if(error)die(error);
    return result;
}
export { store_device, section_exists, section_type, plan_device, unique_device_name };
