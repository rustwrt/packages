// Parallel bounded LAN discovery.
'use strict';
import * as util from './util.uc';
import * as fs from 'fs';
import * as dial from './dial.uc';
let uloop = require('uloop');
// Normalize untrusted discovery fields before publishing or comparing devices.
function clean_text(value,limit,fallback){
    if(type(value)!='string')return fallback;
    let v=util.trim(replace(value,/[[:cntrl:]]/g,' '));
    return length(v)?substr(v,0,limit):fallback;
}
function normalize_device(d,paired){
    if(type(d)!='object')return null;
    if(paired && (type(d.screen_id)!='string' || !match(d.screen_id,/^[A-Za-z0-9_-]{8,128}$/)))return null;
    if(!paired && (type(d.id)!='string' || !length(d.id) || length(d.id)>256 || match(d.id,/[[:cntrl:]]/)))return null;
    let source=index(['Cast','DIAL','YouTube','LAN'],d.source)>=0?d.source:(paired?'YouTube':'LAN');
    let out={name:clean_text(d.name,100,'YouTube TV'),model:clean_text(d.model,100,''),
        manufacturer:clean_text(d.manufacturer,100,''),application:clean_text(d.application,100,''),source:source};
    if(type(d.uuid)=='string' && match(d.uuid,/^(uuid:)?[a-fA-F0-9-]{8,64}$/))out.uuid=lc(d.uuid);
    if(type(d.port)=='int' && d.port>=1 && d.port<=65535)out.port=d.port;
    if(index(['running','stopped','hidden'],d.app_state)>=0)out.app_state=d.app_state;
    if(paired)out.screen_id=d.screen_id;
    if(type(d.id)=='string' && length(d.id)<=256 && !match(d.id,/[[:cntrl:]]/))out.id=d.id;
    if(type(d.host)=='string' && length(d.host)<=253 && match(d.host,/^[A-Za-z0-9_.:-]+$/))out.host=lc(d.host);
    return out;
}
function valid_ipv4(ip){
    if(type(ip)!='string' || !match(ip,/^[0-9]{1,3}(\.[0-9]{1,3}){3}$/))return false;
    for(let part in split(ip,'.'))if(int(part)>255 || (length(part)>1 && substr(part,0,1)=='0'))return false;
    let first=int(split(ip,'.')[0]);return first>0 && first<224 && first!=127;
}
function discover_youtube_devices(opts) {
    let ips=[];
    try {
        let p=fs.popen('/usr/sbin/sponsorblocktv-cast-bridge interfaces','r');
        if(p) { let out=p.read('all'); p.close(); let data=json(out); if(type(data?.ipv4)=='array') for(let ip in data.ipv4)if(valid_ipv4(ip) && index(ips,ip)<0 && length(ips)<16)push(ips,ip); }
    } catch(e) {}
    if(!length(ips)) { let ip=dial.get_local_ip(); if(valid_ipv4(ip)) ips=[ip]; }
    let pending=1+length(ips), finished=false, seen={}, candidates={}, scans=[];
    function emit(d) {
        d=normalize_device(d,true);
        if(finished || !d || seen[d.screen_id] || length(keys(seen))>=128)return;
        seen[d.screen_id]=true;
        if(opts.on_device)try{opts.on_device(d);}catch(e){util.warn('discovery','Device consumer failed');}
    }
    function candidate(d) {
        d=normalize_device(d,false);
        if(finished || !d || (!candidates[d.id] && length(keys(candidates))>=128))return;
        let key=sprintf('%.J',d);if(length(key)>4096)return;
        if(candidates[d.id]==key) return;
        candidates[d.id]=key;
        if(opts.on_candidate)try{opts.on_candidate(d);}catch(e){util.warn('discovery','Candidate consumer failed');}
    }
    function done() {
        if (!finished && --pending==0) { finished=true; if(opts.on_done) opts.on_done(); }
    }
    function read_cast() {
        try {
            let st=fs.lstat(opts.cast_path);if(!st || st.type!='file' || st.size>262144)return null;
            let data=json(fs.readfile(opts.cast_path)||'{}');
            if(type(data?.unpaired)=='array')for(let d in slice(data.unpaired,0,128))candidate(d);
            if(type(data?.devices)=='array')for(let d in slice(data.devices,0,128))emit(d);
            return data.error;
        } catch(e) { return null; }
    }
    let probe_count=0, probe_hosts={};
    function cast_hint(d) {
        if(finished || probe_count>=8 || !valid_ipv4(d?.host) || probe_hosts[d.host])return;
        let uid=lc(replace(d.uuid||'',/^uuid:/i,''));
        if(!match(uid,/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/))return;
        probe_hosts[d.host]=true;probe_count++;pending++;
        let path=replace(opts.cast_path,/cast\.json$/,'probe-'+uid+'.json');
        if(path==opts.cast_path){done();return;}
        let child=uloop.process('/usr/sbin/sponsorblocktv-cast-bridge',['probe-lan',d.host,uid,path],{},(status)=>{
            if(finished)return;
            try{
                let st=fs.lstat(path);
                if(status==0 && st && st.type=='file' && st.size<=4096){
                    let result=json(fs.readfile(path));
                    if(result?.cast===true){
                        let info={...d,id:uid,uuid:uid,source:'Cast',port:8009,application:'',app_state:''};
                        candidate(info);
                        if(result.screen_id)emit({...info,screen_id:result.screen_id,application:'YouTube MDX'});
                    }
                }
            }catch(e){}
            fs.unlink(path);fs.unlink(replace(path,/\.json$/,'.tmp'));done();
        });
        if(!child)done();
    }
    let cast_done=false;
    let timer=uloop.interval(350,read_cast);
    let proc=uloop.process('/usr/sbin/sponsorblocktv-cast-bridge',['discover',opts.cast_path],{},(status)=>{
        if(cast_done || finished)return;cast_done=true;
        timer.cancel(); let err=read_cast();
        if(status!=0 || err) { if(opts.on_warning) opts.on_warning('mDNS: '+(err||status)); }
        done();
    });
    if(!proc && !cast_done) { cast_done=true;timer.cancel(); if(opts.on_warning) opts.on_warning('mDNS process unavailable'); done(); }
    if (!length(ips) && opts.on_warning) opts.on_warning('SSDP: No trusted LAN IPv4 interface');
    for(let ip in ips){
        let ended=false;
        function finish(){if(ended)return;ended=true;done();}
        function error(e){if(opts.on_warning)opts.on_warning('SSDP '+ip+': '+e);finish();}
        try{let scan=dial.discover({local_ip:ip,active:false,bounded:true,on_device:emit,on_candidate:candidate,on_cast_hint:cast_hint,on_done:finish,on_warning:(e)=>{if(opts.on_warning)opts.on_warning('SSDP '+ip+': '+e);},on_error:error});
            if(scan)push(scans,scan);
            else if(!ended)error('Discovery unavailable');
        }catch(e){error('Discovery setup failed');}
    }
    return {stop:()=>{if(finished)return;finished=true;timer.cancel();for(let scan in scans)scan.stop();}};
}
function select_scan_device(snapshot,scan_id,screen_id){
    if(type(snapshot)!='object' || snapshot.scan_id!=scan_id || type(snapshot.devices)!='array')return null;
    if(type(screen_id)!='string' || !match(screen_id,/^[A-Za-z0-9_-]{8,128}$/))return null;
    for(let d in snapshot.devices)if(d?.screen_id==screen_id)return d;
    return null;
}
function scan_device_info(d,paired){
    let out=normalize_device(d,paired);
    if(!out)return null;
    if(paired)out.type=out.source;
    return out;
}
function select_scan_candidate(snapshot,scan_id,id){
    if(type(snapshot)!='object' || snapshot.scan_id!=scan_id || snapshot.pending!==false || type(snapshot.unpaired)!='array')return null;
    if(type(id)!='string' || !match(id,/^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$/))return null;
    for(let d in snapshot.unpaired)
        if(d?.id==id && d.source=='Cast' && d.port==8009 && valid_ipv4(d.host))return d;
    return null;
}
// One Add action. A typed Cast selector cannot collide with a YouTube Screen ID.
function select_add_target(snapshot,scan_id,selector){
    if(type(selector)!='string')return null;
    if(index(selector,'cast:')==0){
        let id=substr(selector,5);
        let candidate=select_scan_candidate(snapshot,scan_id,id);
        if(candidate)return {candidate:candidate};
        // A receiver may become ready between displaying the row and clicking Add.
        if(snapshot?.scan_id==scan_id && snapshot.pending===false &&
           type(snapshot.devices)=='array' && match(id,/^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$/))
            for(let d in snapshot.devices)
                if(d?.id==id && d.source=='Cast' && select_scan_device(snapshot,scan_id,d.screen_id))
                    return {device:d};
        return null;
    }
    let device=select_scan_device(snapshot,scan_id,selector);
    return device?{device:device}:null;
}
export { discover_youtube_devices, normalize_device, valid_ipv4, select_scan_device, select_scan_candidate, select_add_target, scan_device_info };
