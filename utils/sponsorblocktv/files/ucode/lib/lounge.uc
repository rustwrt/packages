// lounge.uc - YouTube Lounge API client (long-poll based).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Mirrors pyytlounge wrapper.py + upstream ytlounge.py. The YouTube Lounge
// API uses HTTP long-polling on /bc/bind (not WebSocket). We drive it with
// uclient inside the uloop event loop.

'use strict';

import * as util from './util.uc';
import * as fs from 'fs';
import * as http from './http.uc';

let uloop = require('uloop');

const API_BASE = 'https://www.youtube.com/api/lounge';

const BLACKLISTED_CLIENTS = [ 'TVHTML5_FOR_KIDS' ];

// Playback states (mirrors models.State).
const STATE_STOPPED = -1;
const STATE_BUFFERING = 0;
const STATE_PLAYING = 1;
const STATE_PAUSED = 2;
const STATE_STARTING = 3;
const STATE_CUED = 5;
const STATE_ADVERTISEMENT = 1081;
const STATE_AD_SKIPPED = 1082;

function valid_number(v,lo,hi) {
    return v!=null && (type(v)=='int' || type(v)=='double' || (type(v)=='string' && match(v,/^[0-9]+([.][0-9]+)?$/))) && 1.0*v>=lo && 1.0*v<=hi;
}
function valid_state(v) { return v!=null && index(['-1','0','1','2','3','5','1081','1082'],''+v)>=0; }
function valid_ad_state(v){return v!=null && index(['0','1080','1081','1082','1083'],''+v)>=0;}
function valid_video(v) { return type(v)=='string' && (v=='' || match(v,/^[A-Za-z0-9_-]{11}$/)); }
// Keep only reported remote names and internal IDs, never raw deviceInfo.
function new_remote_id(){
    let f=fs.open('/dev/urandom','r');
    if(!f)die('Cannot generate remote identity');
    let bytes=f.read(32);f.close();
    if(length(bytes)!=32)die('Cannot generate remote identity');
    return util.md5_hex(bytes);
}
// Persist an installation seed; derive independent identities for each TV.
function controller_seed(dir){
    let owner=fs.lstat(dir);
    if(!owner || owner.type!='directory' || (owner.mode & 18))die('Unsafe controller identity directory');
    let path=dir+'/controller-id',st=fs.lstat(path);
    if(st){
        if(st.type!='file' || st.uid!=owner.uid || (st.mode & 63) || st.size!=32)
            die('Unsafe controller identity file');
        let seed=fs.readfile(path);
        if(type(seed)!='string' || !match(seed,/^[a-f0-9]{32}$/))
            die('Invalid controller identity');
        return seed;
    }
    let seed=new_remote_id(),tmp=path+'.'+fs.readlink('/proc/self')+'.tmp';
    if(fs.lstat(tmp))die('Controller identity temporary file exists');
    let f=fs.open(tmp,'w',0600),written=f?f.write(seed):0;
    if(f)f.close();
    if(written!=32 || !fs.chmod(tmp,0600) || !fs.rename(tmp,path)){
        fs.unlink(tmp);die('Cannot persist controller identity');
    }
    return seed;
}
function persistent_controller_id(seed,screen_id){
    if(type(seed)!='string' || !match(seed,/^[a-f0-9]{32}$/))
        die('Invalid controller seed');
    return util.md5_hex('rustwrt-sponsorblocktv:'+seed+':'+screen_id);
}
function remote_name(v){
    return type(v)=='string' && length(v)>0 && length(v)<=160 && !match(v,/[[:cntrl:]]/) ? v : '';
}
function remote_id(v){
    return type(v)=='string' && length(v)>0 && length(v)<=256 && !match(v,/[[:cntrl:]]/) ? v : null;
}
function controller_roster(devices,self_id){
    if(type(devices)!='array' || length(devices)>128)return null;
    let remotes=[],seen={};
    for(let d in devices){
        if(type(d)!='object' || type(d.type)!='string')return null;
        if(d.type!='REMOTE_CONTROL')continue;
        let id=remote_id(d.id);
        if(id!=null && seen['id:'+id])continue;
        if(id!=null)seen['id:'+id]=true;
        push(remotes,{id:id,name:remote_name(d.name),self:id!=null && id===self_id});
    }
    return remotes;
}
function parse_state(s) {
	let n = int(s);
	if (n != n)
		return STATE_STOPPED;
	return n;
}

// --- Lounge client --------------------------------------------------------

// A YtLoungeApi instance for one screen.
//   opts: {
//     screen_id, device_name, lounge_token,
//     mute_ads, skip_ads, auto_play,
//     on_event(event_type, args), on_state_change(state), on_connected(),
//     on_disconnected(reason), on_error(err)
//   }
function YtLoungeApi(opts) {
	let self = proto({}, {
		paired: function() {
	return this.screen_id != null;
		},
		linked: function() {
	return this.paired() && this.lounge_token != null;
		},
        shared_control: function(){
            return this.controller_mode=='cooperative' && (this.controllers==null || !this.controller_observed_ms || util.monotonic_ms()-this.controller_observed_ms>120000 || length(filter(this.controllers,(r)=>!r.self))>0);
        },
        passive: function(){return this.controller_mode=='passive';},
		connected: function() {
	return this._sid != null && this._gsession != null;
		},
		_connection_lost: function() {
    // Snapshot ownership before abort callbacks can clear the last volume state.
    if(this._manual_mute_pending || (this._ad_mute_pending && this.volume_state.muted!='true'))this._ad_mute_owned=false;
    this._mute_reconnecting=!!this._ad_mute_owned;
	this._sid = null;
    this._gsession = null;
    this._command_epoch++;
    if(this._mute_verify)this._mute_verify();
    if(this._subscribe_active && this._subscribe_abort)this._subscribe_abort();
    let inflight=this._command_inflight;
    this._command_inflight=null;
    this._ad_mute_pending=false;
    this._manual_mute_pending=false;
    this._content_confirmed=false;
    let abandoned = this._command_queue;
    this._command_queue = [];
    this._command_mutex = false;

	this._last_event_id = null;
	this._last_event_time=0;
	this._subscribe_buffer='';this._current_chunk='';this._chunk_remaining=-1;
	this._screen_confirmed = false;
	this._last_screen_event_time = 0;
    this._session_started=0;
    this._presence_pending=false;
    this.controllers=null;this.controller_changes=[];this.controller_observed_ms=0;
    this.controller_conflict=null;this.controller_conflict_count=0;
	this._clear_ad(false);
	this._now_playing_pending = false;
	this._volume_query_pending = false;
	this.playback_speed = 1.0;
	this._playback_state = { currentTime: 0, duration: 0, videoId: "", state: -2, position_known:false };
	this._playback_sample_ms=0;
	this._position_report_ms=0;
	this._last_ad_video=null;this._last_ad_end_ms=0;
	this.volume_state = {};
	this.queue = null; this.queue_complete = false; this.queue_requests=[];
	this.speed_known = false;
	this.autoplay_mode = null;
    this._autoplay_request=null;
	this.quality = null;
	this.up_next = null; this.has_next=null;this.has_previous=null;
    if(inflight)inflight.finish(false,'session disconnected');
    for(let entry in abandoned)entry.finish(false,'session disconnected');
    if(this._command_verify)this._command_verify(false);
        },
		_lounge_token_expired: function() {
	this.lounge_token = null;
	this._auth_generation++;
		},
		refresh_auth: function(on_result, on_error) {
	let self = this;
	if (!this.paired()) {
		if (on_error) on_error('not paired');
		else if (on_result) on_result(false);
		return;
	}
	let request=++this._auth_generation, screen_id=this.screen_id;
	let url = API_BASE + '/pairing/get_lounge_token_batch';
	http.post_form({
		url: url,
		data: { screen_ids: this.screen_id },
        timeout_ms:8000,max_body_bytes:65536,
		on_done: (data, status) => {
			if (status != 200 || type(data?.screens)!='array' || !length(data.screens)) {
				if (on_result) on_result(false);
				return;
			}
			let screen=filter(data.screens,(x)=>type(x)=='object' && x.screenId==screen_id)[0];
			if(request!=self._auth_generation || !screen || type(screen.loungeToken)!='string' || !length(screen.loungeToken) || length(screen.loungeToken)>4096){if(on_result)on_result(false);return;}
			self.lounge_token = screen.loungeToken;
			util.info('lounge', 'Refreshed Lounge authentication');
			if (on_result) on_result(self.linked());
		},
		on_error: (err) => {
			if (on_error) on_error(err);
			else if (on_result) on_result(false);
		},
	});
		},
		is_available: function(on_result, on_error) {
	let self = this;
	if (!this.linked()) {
		if (on_error) on_error('not linked');
		else if (on_result) on_result(false);
		return;
	}
	let token=this.lounge_token,epoch=this._command_epoch;
	let url = API_BASE + '/pairing/get_screen_availability';
	http.post_form({
		url: url,
		data: { lounge_token: token },
        timeout_ms:8000,max_body_bytes:65536,
		on_done: (data, status) => {
            if(self._command_epoch!=epoch || self.lounge_token!=token){if(on_error)on_error('stale availability');else if(on_result)on_result(false);return;}
			if (status == 401) self._lounge_token_expired();
			if (status != 200 || type(data)!='object') {
				if (on_error) on_error("availability HTTP " + status);
				else if (on_result) on_result(false);
				return;
			}
            let online=util.availability_status(data,self.screen_id,token);
            if(online==null){if(on_error)on_error('Screen availability mismatch or invalid response');else if(on_result)on_result(false);return;}
			util.debug('lounge', 'Screen availability HTTP ' + status + ': ' + (online ? 'online' : 'offline'));
			if (on_result) on_result(online);
		},
		on_error: (err) => {
			if (on_error) on_error(err);
			else if (on_result) on_result(false);
		},
	});
		},
		_common_connection_parameters: function() {
	return {
		name: this.device_name,
		loungeIdToken: this.lounge_token,
		SID: this._sid,
		AID: this._last_event_id,
		gsessionid: this._gsession,
		device: 'REMOTE_CONTROL',
		app: 'ytios-phone-20.15.1',
		VER: '8',
		v: '2',
	};
		},
		connect: function(on_result, on_error) {
	let self = this;
	if (!this.linked()) {
		if (on_error) on_error('not linked');
		else if (on_result) on_result(false);
		return;
	}

	let generation=++this._connect_generation,epoch=this._command_epoch;
    // Keep this listener's unique identity across reconnects to avoid
    // orphaning a new remote on each bind. Independent listeners differ.
	let connect_body = {
		id: this.device_id,
		'mdx-version': '3',
		TYPE: 'xmlhttp',
		theme: 'cl',
		sessionSource: 'MDX_SESSION_SOURCE_UNKNOWN',
		connectParams: sprintf('%.J', { setStatesParams: sprintf('%.J', { playbackSpeed: 0 }) }),
		RID: '1',
		CVER: '1',
		capabilities: 'que,dsdtr,atp,vsp',
		ui: 'false',
		app: 'ytios-phone-20.15.1',
		pairing_type: 'manual',
		VER: '8',
		loungeIdToken: this.lounge_token,
		device: 'REMOTE_CONTROL',
		name: this.device_name,
	};

	let url = API_BASE + '/bc/bind?RID=1&VER=8&CVER=1&auth_failure_option=send_error';
	http.post_form({
		url: url,
		data: connect_body,
		timeout_ms: 15000,max_body_bytes:1048576,
		on_done: (data, status, body) => {
            if(self._connect_generation!=generation || self._command_epoch!=epoch){if(on_result)on_result(false);return;}
			if (status == 401) {
				util.warn('lounge', 'Connection denied; refreshing authorization');
				self._lounge_token_expired();
				if (on_result) on_result(false);
				return;
			}
			if (status != 200) {
				util.warn('lounge', sprintf('Unknown reply to connect %d', status));
				if (on_result) on_result(false);
				return;
			}
			// Parse the event chunks from the response body.
			let parsed=self._parse_event_chunks(body,(events)=>self._process_events(events));
            if(!parsed || !self.connected()){if(self.connected() || self._sid || self._gsession)self._connection_lost();if(on_result)on_result(false);return;}
			self._command_offset = 1;
			if (on_result) on_result(self.connected());
		},
		on_error: (err) => {
			if (on_error) on_error(err);
			else if (on_result) on_result(false);
		},
	});
		},
		_connect_as_screen: function() {
	util.error('lounge', 'Connected as screen: please force close the app on the device for SponsorBlockTV to work properly');
	util.warn('lounge', 'Exiting in 5 seconds');
	// In the original this exits; here we just log and let the caller retry.
		},
        _process_events: function(events){
            if(type(events)!='array')return;
            let epoch=this._command_epoch;
            for(let event in events){
                if(type(event)!='array' || length(event)<2 || !valid_number(event[0],0,2147483647) || int(event[0])!=1.0*event[0])continue;
                let id=int(event[0]),payload=event[1];
                if(type(payload)!='array' || !length(payload) || type(payload[0])!='string')continue;
                if(this._last_event_id!=null && id<=this._last_event_id)continue;
                let event_type=payload[0],args=slice(payload,1);
                this._last_event_id=id;
                this._last_event_time=util.monotonic_ms();
                if(event_type=='c' || event_type=='S'){
                    if(type(args[0])!='string' || !length(args[0]) || length(args[0])>512)continue;
                    if(event_type=='c')this._sid=args[0];else this._gsession=args[0];
                }else {
                    try{this._process_event(event_type,args);}catch(e){
                        util.warn('lounge','Ignoring malformed event: '+event_type);
                    }
                    if(this._command_epoch!=epoch)return;
                }
            }
        },
        // Notify only after the event has updated the authoritative state.
        _process_event: function(event_type,args) {
            this._apply_event(event_type,args);
            if(this._mute_verify)this._mute_verify();
            if(this._command_verify)this._command_verify(false);
        },
        _update_queue: function(ids){
            if(ids==null)return;
            if((type(ids)!='array' && type(ids)!='string') || length(ids)>16384){this.queue=null;this.queue_complete=false;this._revisions.queue++;return;}
            ids=type(ids)=='array'?ids:split(ids,',');
            let valid=filter(slice(ids,0,201),id=>type(id)=='string' && match(id,/^[A-Za-z0-9_-]{11}$/));
            this.queue_complete=length(valid)<=200 && (length(valid)==length(ids) || (length(ids)==1 && ids[0]==''));
            this.queue=slice(valid,0,200);
            if(this.queue_complete)this.queue_requests=[];
            this._revisions.queue++;
        },
        _update_navigation: function(data){
            for(let key in ['hasNext','hasPrevious']){
                if(index(['true','false','1','0'],''+data[key])>=0)
                    this[key=='hasNext'?'has_next':'has_previous']=index(['true','1'],''+data[key])>=0;
            }
        },
        _apply_event: function(event_type, args) {
	let self = this;
	this._last_event_time = util.monotonic_ms();

    let data=type(args?.[0])=='object'?args[0]:{};
    let playback=event_type=='nowPlaying'||event_type=='onStateChange';
    let position=valid_number(data.currentTime,0,604800);
    let video=valid_video(data.videoId);
    let state=valid_state(data.state);
    let volume=valid_number(data.volume,0,100);
    let muted=data.muted!=null && index(['true','false','0','1'],''+data.muted)>=0;
    let skip_flag=data.isSkipEnabled!=null && index(['true','false','0','1'],''+data.isSkipEnabled)>=0;
    let ad_signal=(event_type=='adPlaying' && ((type(data.adVideoId)=='string' && length(data.adVideoId)>0 && length(data.adVideoId)<=128)||(valid_video(data.videoId)&&data.videoId!='')||(data.isSkippable!=null && index(['true','false','0','1'],''+data.isSkippable)>=0)||(data.isSkipEnabled!=null && index(['true','false','0','1'],''+data.isSkipEnabled)>=0)||position||valid_number(data.adCurrentTime,0,604800))) ||
        (event_type=='onAdStateChange' && (valid_ad_state(data.adState) ||
            (data.adState==null && this._ad_active && skip_flag &&
             (!(data.adVideoId||data.adId) || (data.adVideoId||data.adId)==this.ad.id))));
    let useful=(playback && (position||video||state)) || (event_type=='onVolumeChanged' && (volume||muted)) || ad_signal;
    if(useful){this._screen_confirmed=true;this._screen_missing=false;this._last_screen_event_time=this._last_event_time;this._screen_revision++;}
    if(playback && !(position||video||state||valid_number(data.duration,0,604800)||valid_number(data.seekableStartTime,0,604800)||valid_number(data.seekableEndTime,0,604800)))return;
    if((event_type=='adPlaying'||event_type=='onAdStateChange') && !ad_signal)return;
    if(event_type=='onVolumeChanged' && !volume && !muted)return;
    let defer_ad_event=event_type=='adPlaying'||event_type=='onAdStateChange'||(playback && state && (''+data.state)=='1081');
    if (!defer_ad_event && this.on_event) this.on_event(event_type,args);
    if(playback){
        let p=this._playback_state,now=util.monotonic_ms();
        // Ad playback packets must not mutate the content ID, duration or DVR bounds.
        if(state && (''+data.state)=='1081'){
            let ad_data={adState:1081,adVideoId:data.adVideoId||data.adId||(video && data.videoId!=p.videoId?data.videoId:null),
                adCurrentTime:data.adCurrentTime,adDuration:data.adDuration,isSkippable:data.isSkippable,isSkipEnabled:data.isSkipEnabled};
            this._update_ad(ad_data,false);
            if(this.on_event)this.on_event(event_type,args);
            return;
        }
        if(state && (''+data.state)=='1082'){
            this._process_event('onAdStateChange',[{adState:1082}]);
            return;
        }
        // Ordinary state packets can describe background content during ads.
        // Promote them only once the fallback end detector has confirmed resumption.
        if(this._ad_active){
            this._consider_ad_end(data);
            if(this._ad_active)return;
        }
        if(video && data.videoId && data.videoId==this._last_ad_video && now-this._last_ad_end_ms<5000)return;
        let changed=video && data.videoId!=p.videoId;
        if(changed){this.quality=null;this.up_next=null;this.has_next=null;this.has_previous=null;this._position_report_ms=0;p.currentTime=0;p.duration=0;p.seekableStart=null;p.seekableEnd=null;p.position_known=false;p.state=-2;p.videoId=data.videoId;}
        else if(!position && p.position_known && p.state==STATE_PLAYING && !this._ad_active && this._playback_sample_ms)
            p.currentTime+=max(0,now-this._playback_sample_ms)/1000.0*this.playback_speed;
        if(changed && data.videoId){
            let i=index(this.queue_requests||[],data.videoId);
            if(i>=0)splice(this.queue_requests,i,1);
        }
        if(changed && this.queue_complete && index(this.queue||[],data.videoId)<0){this.queue=null;this.queue_complete=false;this._revisions.queue++;}
        this._update_navigation(data);
        if(data.videoIds!=null)this._update_queue(data.videoIds);
        if(position && data.state!=1081 && data.state!=1082){p.currentTime=1.0*data.currentTime;p.position_known=true;this._position_report_ms=now;this._revisions.position++;}
        if(valid_number(data.duration,0,604800))p.duration=1.0*data.duration;
        if(valid_number(data.seekableStartTime,0,604800))p.seekableStart=1.0*data.seekableStartTime;
        if(valid_number(data.seekableEndTime,0,604800))p.seekableEnd=1.0*data.seekableEndTime;
        if(state)p.state=parse_state(data.state);
        if(video)this._revisions.video++;
        if(state)this._revisions.playback++;
        this._playback_sample_ms=now;
        if(!this._ad_active && state && index(['1','2','-1','5'],''+data.state)>=0)this._content_confirmed=true;
        if(!this._ad_active)this._restore_ad_mute();
        if(this.on_state_change)this.on_state_change(p);
    }
    else if (event_type == 'onAdStateChange') {
        let data = args[0] || {};
        if (data.adState == '0' || data.adState == '1082') {
            let was_ad = this._ad_active;
            this._clear_ad(true,data.adState==1082);
            this._content_confirmed=true;
            if (was_ad) this._restore_ad_mute();
            if(was_ad){this._playback_state.position_known=false;this._position_report_ms=0;this._playback_sample_ms=util.monotonic_ms();if(this.on_state_change)this.on_state_change(this._playback_state);}
            if (was_ad) this.get_now_playing();
        } else if (data.adState != null || (this._ad_active && skip_flag)) {
            this._update_ad(data, false);
        }
        if(this.on_event)this.on_event(event_type,args);
    }
	else if (event_type == 'onVolumeChanged') {
		let data = args[0] || {};
		if(volume){this.volume_state.volume=data.volume;this._revisions.volume++;}
		if(muted){this.volume_state.muted=(data.muted===true||data.muted==='true'||data.muted===1||data.muted==='1')?'true':'false';this._revisions.mute++;}
        // A fresh unmuted state after reconnect invalidates prior ownership.
        if(muted && this._mute_reconnecting){
            this._mute_reconnecting=false;
            if(this.volume_state.muted==='false'){
                this._ad_mute_owned=false;
                if(this._ad_active)this.ad.manual_mute_override=true;
            }
        }
        // A fresh unmute after our mute was confirmed is user intent;
        // don't re-mute or restore over that change in this advertisement.

        if(this.shared_control() && this._ad_active && muted && this.volume_state.muted==='false' && this._ad_mute_owned && !this._ad_mute_pending){
            this._ad_mute_owned=false;this.ad.manual_mute_override=true;
        }
		if (this._ad_active && this.mute_ads) this._apply_ad_mute();
        else this._restore_ad_mute();
	}
	else if (event_type == 'playlistModified' || event_type == 'onPlaylistModified' || event_type == 'nowPlayingPlaylist') {
		let d = args[0] || {};
        this._update_navigation(d);
        if(d.videoIds!=null)this._update_queue(d.videoIds);
        else {this.queue=null;this.queue_complete=false;this._revisions.queue++;}
	}
	else if (event_type == 'onVideoQualityChanged') {
		// The quality event belongs to the current content, never an ad or a
        // previous video. A quality label is telemetry, not a selectable list.
        let vid=this._playback_state.videoId,q=data.qualityLevel??data.quality;
        if(this._ad_active || !vid || (data.videoId!=null && data.videoId!=vid))return;
        if(type(q)=='string' && length(q)>0 && length(q)<=64 && !match(q,/[[:cntrl:]]/))this.quality=q;
	}
    else if(event_type=='hasPreviousNextChanged' || event_type=='onHasPreviousNextChanged'){
        this._update_navigation(data);
    }
    else if(event_type=='autoplayUpNext'){
        this.up_next=valid_video(args[0]?.videoId) && args[0].videoId!=this._playback_state.videoId?args[0].videoId:null;
    }
    else if (event_type == 'adPlaying') {
        this._update_ad(args[0] || {}, true);
        if(this.on_event)this.on_event(event_type,args);
    }
    else if (event_type == 'loungeStatus') {
        let data=args[0]||{},devices;
        if(data.devices==null)return;
        try {devices=type(data.devices)=='array'?data.devices:json(data.devices);}catch(e){return;}
        let roster=controller_roster(devices,this.device_id);
        if(roster==null)return;
        this._screen_confirmed=false;
        for(let d in devices){
            if(d.type!='LOUNGE_SCREEN')continue;
            this._screen_confirmed=true;
            this._screen_revision++;
            this._screen_missing=false;
            this._last_screen_event_time=this._last_event_time;
            this._screen_name=d.name;
            let info=null;
            try{info=type(d.deviceInfo)=='object'?d.deviceInfo:json(d.deviceInfo||'null');}catch(e){}
            this._device_info=info;
            if(info && index(BLACKLISTED_CLIENTS,info.clientName||'')>=0){this._connection_lost();return;}
            break;
        }
        if(!this._screen_confirmed){this._screen_missing=true;this._last_screen_event_time=0;this._screen_revision++;}
        // Only diff complete snapshots with stable identifiers. An initial
        // snapshot (or a row without ID) is not evidence of a join/leave.
        let previous=this.controllers,now=util.monotonic_ms(),changes=[];
        if(previous!=null && !length(filter(previous,(r)=>r.id==null)) && !length(filter(roster,(r)=>r.id==null))){
            for(let r in roster)if(!length(filter(previous,(p)=>p.id===r.id)))push(changes,{kind:'joined',name:r.name,self:r.self,at:now});
            for(let r in previous)if(!length(filter(roster,(p)=>p.id===r.id)))push(changes,{kind:'left',name:r.name,self:r.self,at:now});
        }
        let was_shared=this.shared_control();
        this.controllers=roster;this.controller_observed_ms=now;
        if(was_shared && !this.shared_control() && !this.passive() && this.autoplay_mode!=null)
            this.set_auto_play_mode(this.auto_play);

        if(length(changes)){
            this.controller_changes=slice([...this.controller_changes,...changes],-8);
            util.debug('lounge',sprintf('Remote roster changed: %d change(s), %d controller(s)',length(changes),length(roster)));
        }
    }
	else if (event_type == 'loungeScreenDisconnected') {
        // A screen disconnect is not permission to restart or replace playback.
        this._screen_missing=true;this._screen_revision++;
		if (this.on_disconnected)
			this.on_disconnected(args[0] && args[0].reason);
		this._connection_lost();
		this._lounge_token_expired();
	}
	else if (event_type == 'onAutoplayModeChanged') {
		let mode = args[0]?.autoplayMode;
		if (mode == 'ENABLED' || mode == 'DISABLED') {
			this.autoplay_mode = mode;this._revisions.autoplay++;
			if (!this.shared_control() && !this.passive() && (mode == 'ENABLED') != this.auto_play) this.set_auto_play_mode(this.auto_play);
		}
	}
	else if (event_type == 'onPlaybackSpeedChanged') {
		let data=args[0]||{};
        if(!valid_number(data.playbackSpeed,0.1,4))return;
        let p=this._playback_state, now=util.monotonic_ms();
        if(p.position_known && p.state==STATE_PLAYING && !this._ad_active && this._playback_sample_ms)
            p.currentTime+=max(0,now-this._playback_sample_ms)/1000.0*this.playback_speed;
        this._playback_sample_ms=now;
        this.playback_speed=1.0*data.playbackSpeed;
        this.speed_known=true;this._revisions.speed++;
        if(this.on_state_change && p.position_known)this.on_state_change(p);
	}
	else if (event_type == 'noop') {
		// no-op
	}
		},
        _command: function(command, command_parameters, on_result, on_error, guard, ad_priority) {
            let self = this;
            if(this._detaching && command!='getVolume' &&
                !(command=='setVolume' && command_parameters?.muted=='false' && this._ad_mute_owned)){
                if(on_error)on_error('controller detaching');else if(on_result)on_result(false);
                return;
            }
            if(command=='getVolume'){
                let i=0;
                while(i<length(this._command_queue) && this._command_queue[i].name!='getVolume')i++;
                if(i<length(this._command_queue)){
                    if(ad_priority){
                        let queued=this._command_queue[i];
                        splice(this._command_queue,i,1);
                        let pos=0;
                        while(pos<length(this._command_queue) && (this._command_queue[pos].name=='skipAd' || this._command_queue[pos].ad_priority))pos++;
                        queued.ad_priority=true;
                        // This read is now needed by the ad path, not just the old probe.
                        queued.guard=null;
                        splice(this._command_queue,pos,0,queued);
                    }
                    if(on_result)on_result(false);
                    this._drain_commands();return;
                }
            }
            let entry = {name:command,args:command_parameters||{},epoch:this._command_epoch,
                queued:util.monotonic_ms(),ad:command=='skipAd'?this.ad:null,guard:guard,ad_priority:!!ad_priority};
            entry.finish = (ok,err) => {
                if(entry.finished)return;entry.finished=true;
                try{if(err && on_error)on_error(err);else if(on_result)on_result(ok);}catch(e){util.warn('lounge','Command completion callback failed');}
            };
            if (!this.connected() || length(this._command_queue)>=(command=='skipAd'?26:ad_priority?25:24)) { entry.finish(false,'not connected or command queue full'); return; }
            // Ad skipping takes precedence over background status polling.
            if (command=='skipAd') unshift(this._command_queue,entry);
            else if (ad_priority || (command=='setVolume' && this._ad_active)) { let i=0; while(i<length(this._command_queue) && (this._command_queue[i].name=='skipAd' || this._command_queue[i].ad_priority)) i++; splice(this._command_queue,i,0,entry); }
            else if(index(['getNowPlaying','getVolume'],command)<0){
                // Preserve mutation order while moving queued read-only polls behind them.
                let i=length(this._command_queue);
                while(i>0 && index(['getNowPlaying','getVolume'],this._command_queue[i-1].name)>=0)i--;
                splice(this._command_queue,i,0,entry);
            }else push(this._command_queue,entry);
            this._drain_commands();
        },
        _drain_commands: function() {
            let self=this;
            if(this._command_mutex || !this.connected()) return;
            while(this.connected() && !this._command_mutex && length(this._command_queue)) {
                let entry=shift(this._command_queue);
                if(!this.connected() || entry.epoch!=this._command_epoch || util.monotonic_ms()-entry.queued>8000 ||
                    (entry.ad && (entry.ad!=this.ad || !this._ad_active || !this.ad.can_skip))) {
                    entry.finish(false,'stale command'); continue;
                }
                if(this._detaching && entry.name!='getVolume' &&
                    !(entry.name=='setVolume' && entry.args.muted=='false' && this._ad_mute_owned)){
                    entry.finish(false,'controller detaching');continue;
                }
                if(this.passive() && index(['getNowPlaying','getVolume'],entry.name)<0 &&
                    !(entry.name=='setVolume' && entry.args.muted=='false' && this._ad_mute_owned)){
                    entry.finish(false,'passive controller');continue;
                }
                let allowed=true;
                try{if(entry.guard)allowed=!!entry.guard();}catch(e){allowed=false;}
                if(!allowed || !this.connected() || entry.epoch!=this._command_epoch){
                    entry.finish(false,'stale command');continue;
                }
                this._command_mutex=true;
                this._command_inflight=entry;
                if(entry.name=='skipAd' && entry.ad){
                    entry.ad.skip_dispatched_at=util.monotonic_ms();
                    let ad=entry.ad;
                    ad.skip_remaining=ad.duration!=null && ad.position!=null ? max(0,ad.duration-ad.position-(ad.running && ad.sampled?max(0,ad.skip_dispatched_at-ad.sampled)/1000.0:0)):null;
                    util.debug('lounge',sprintf('Skip dispatch: queued %d ms, enabled %d ms earlier',
                        entry.ad.skip_dispatched_at-entry.queued,entry.ad.skip_dispatched_at-(entry.ad.skip_enabled_at??entry.queued)));
                }
                let sent_at=util.monotonic_ms(),mutation=index(['getNowPlaying','getVolume'],entry.name)<0;
                if(mutation)util.debug('lounge',sprintf('Command dispatch: %s queue=%dms',entry.name,sent_at-entry.queued));
                let finished=false;
                function finish(ok,err) {
                    if(finished) return;
                    finished=true;
                    if(entry.epoch!=self._command_epoch || self._command_inflight!=entry)return;
                    self._command_inflight=null;
                    if(mutation)util.debug('lounge',sprintf('Command HTTP: %s ok=%s elapsed=%dms',entry.name,ok?'yes':'no',util.monotonic_ms()-sent_at));
                    // Hold the mutex while callbacks enqueue follow-up requests.
                    try {entry.finish(ok,err);} catch(e) {util.warn('lounge','command callback failed: '+e);}
                    if(entry.epoch==self._command_epoch){self._command_mutex=false;self._drain_commands();}
                }
                try{this._send_command(entry.name,entry.args,(ok)=>finish(ok),(err)=>finish(false,err));}catch(e){finish(false,'transport exception');}
                return;
            }
        },
        _send_command: function(command, command_parameters, on_result, on_error) {
	let self = this;
	if (!this.connected()) {
		if (on_error) on_error('not connected');
		else if (on_result) on_result(false);
		return;
	}

	let sid = this._sid,epoch=this._command_epoch;
	let command_body = { count: 1, ofs: this._command_offset, 'req0__sc': command };
	if (command_parameters) {
		for (let k in command_parameters)
			command_body['req0_' + k] = command_parameters[k];
	}
	this._command_offset += 1;

	let params = this._common_connection_parameters();
	params.RID = this._command_offset;
	let url = API_BASE + '/bc/bind?' + util.query_encode(params);

	http.post_form({
		url: url,
		data: command_body,
		timeout_ms: index(['getNowPlaying','getVolume'],command)>=0 ? ((this.skip_ads || this.mute_ads) ? 1000 : 1800) : (command == 'skipAd' || command == 'setVolume' ? 4000 : 5000),
		on_done: (data, status, body) => {
			if (self._command_epoch!=epoch || self._sid != sid || !self._handle_session_result(status, body)) {
				if (on_result) on_result(false);
				return;
			}
			if (on_result) on_result(status >= 200 && status < 300);
		},
		on_error: (err) => {
			if (on_error) on_error(err);
			else if (on_result) on_result(false);
		},
	});
		},
		_handle_session_result: function(status_code, reason) {
	if (status_code == 400 && match(reason, /Unknown SID/)) {
        util.debug('lounge','Session rejected: Unknown SID');
		this._connection_lost();
		return false;
	}
	if (status_code == 410 && match(reason, /Gone/)) {
        util.debug('lounge','Session rejected: Gone');
		this._connection_lost();
		return false;
	}
	if (status_code == 401) {
        util.debug('lounge','Session rejected: HTTP 401');
		this._connection_lost();
		this._lounge_token_expired();
		return false;
	}
	return true;
		},
        // Verify automatic mute with backchannel events; poll once only if needed.
        mute: function(mute, override, done, guard) {
            let self=this, desired=mute?'true':'false', epoch=this._command_epoch;
            if(!override && this.volume_state.muted===desired){if(done)done(true);return;}
            let args={muted:desired};
            if(this.volume_state.volume!=null)args.volume=this.volume_state.volume;
            let revision=this._revisions.mute, finished=false, dispatched=false, sent_at=null;
            let probe=null, deadline=null, verify=null;
            function finish(ok){
                if(finished)return;finished=true;
                if(probe)probe.cancel();
                if(deadline)deadline.cancel();
                if(self._mute_verify==verify)self._mute_verify=null;
                if(self._command_epoch==epoch){
                    if(sent_at!=null)util.debug('lounge',sprintf('Ad %s confirmation: %s %d ms',mute?'mute':'unmute',ok?'OK':'failed',util.monotonic_ms()-sent_at));
                    if(done)done(ok);
                }
            }
            verify=()=>{
                if(self._command_epoch!=epoch || !self.connected()){finish(false);return;}
                if(self._revisions.mute!=revision && self.volume_state.muted===desired)finish(true);
            };
            this._command('setVolume',args,(ok)=>{
                if(finished || self._command_epoch!=epoch)return;
                if(!ok && !dispatched){finish(false);return;}
                self._mute_verify=verify;
                verify();
                if(finished)return;
                probe=uloop.timer(250,()=>{
                    probe=null;verify();
                    if(!finished)self._command('getVolume',{},null,null,()=>!finished && self._command_epoch==epoch,true);
                });
                deadline=uloop.timer(4000,()=>{deadline=null;verify();if(!finished)finish(false);});
            },null,()=>{
                revision=self._revisions.mute;
                if(self.volume_state.volume!=null)args.volume=self.volume_state.volume;
                if(self._command_epoch!=epoch || (guard && !guard()) || (mute && self._ad_mute_owned && !self._auto_mute_wanted()))return false;
                dispatched=true;sent_at=util.monotonic_ms();self._mute_verify=verify;return true;
            },true);
        },
        _count_owned_mute: function(){
            if(!this._ad_mute_owned || this._ad_mute_pending || this.volume_state.muted!='true')return;
            if(this._ad_active && this.mute_ads && !this.ad.manual_mute_override){
                if(!this.ad.stats_muted){this.ad.stats_muted=true;if(this.on_stat)this.on_stat('ad_mutes',0);}

            }
        },
        _apply_ad_mute: function() {
            this._count_owned_mute();
            if (this.passive() || !this.mute_ads || !this._ad_active || this.ad.manual_mute_override || this._manual_mute_pending || this._ad_mute_owned || this._ad_mute_pending) return;
            let muted = this.volume_state.muted;
            if (muted === true || muted === 'true') return;
            if (muted == null) {
                if (!this._volume_query_pending && this._command_inflight?.name!='getVolume') {
                    let self = this;
                    this._volume_query_pending = true;
                    this._command('getVolume', {}, () => { self._volume_query_pending = false; },null,null,true);
                }
                return;
            }
            let self = this;
            this._ad_mute_owned = true;
            this._ad_mute_pending = true;
            let target_ad=this.ad, dispatched=false;
            this.mute(true, false, (ok) => {
                self._ad_mute_pending = false;
                if(!ok && (!dispatched || self.volume_state.muted==='false'))self._ad_mute_owned=false;
                if(ok)self._count_owned_mute();
                if(!self._ad_active || !self.mute_ads)self._restore_ad_mute();
                else if(self.ad!=target_ad)self._apply_ad_mute();
            },()=>{
                if(!self._ad_active || self.ad!=target_ad || !self.mute_ads || target_ad.manual_mute_override || self._manual_mute_pending || self.volume_state.muted!='false')return false;
                dispatched=true;
                util.debug('lounge',sprintf('Ad mute dispatch: %d ms after first signal',util.monotonic_ms()-(target_ad.started_at??target_ad.last_signal)));
                return true;
            });
        },
        _auto_mute_wanted: function(){
            return this._ad_active && this.mute_ads;
        },
        _restore_ad_mute: function() {
            if (!this._ad_mute_owned || this._manual_mute_pending || this._ad_mute_pending || this._auto_mute_wanted() || !this.connected() || (!this._ad_active && !this._content_confirmed) || this.volume_state.muted == null) return;
            if (this.volume_state.muted === false || this.volume_state.muted === 'false' || this.volume_state.muted === 0 || this.volume_state.muted === '0') { this._ad_mute_owned=false; return; }
            let self = this;
            if(util.monotonic_ms()<(this._mute_restore_at||0))return;
            this._mute_restore_at=util.monotonic_ms()+1500;
            this._ad_mute_pending = true;
            this.mute(false, true, (ok) => {
                self._ad_mute_pending = false;
                if (ok) self._ad_mute_owned = false;
                if(self._ad_active && self.mute_ads)self._apply_ad_mute();
            },()=>!self._auto_mute_wanted() && !self._manual_mute_pending);
        },
		play_video: function(video_id) {
	return this._command('setPlaylist', { videoId: video_id });
		},
		get_now_playing: function(on_result, guard) {
	if (this._now_playing_pending) { if (on_result) on_result(false); return; }
	let self = this;
	this._now_playing_pending = true;
	let epoch=this._command_epoch;
	return this._command('getNowPlaying', {}, (ok) => { if(self._command_epoch==epoch)self._now_playing_pending = false; if (on_result) on_result(ok); },null,guard);
		},
		seek_to: function(time, on_result, guard) {
	return this._command('seekTo', { newTime: time }, on_result, null, guard);
		},
        _consider_ad_end: function(data) {
            if(!this._ad_active || index(['1','2','-1','5'],''+data.state)<0) return;
            // Generic playback samples may still describe the underlying content.
            // Only infer an end from two advancing content samples after ad signals stop.
            let ad=this.ad, now=util.monotonic_ms();
            let quiet=ad.skip_sent ? 2200 : 6000;
            if(now-ad.last_signal<quiet || data.currentTime==null || !match(''+data.currentTime,/^[0-9]+([.][0-9]+)?$/)) return;
            if(!valid_number(data.currentTime,0,604800))return;
            let vid=valid_video(data.videoId)&&data.videoId?data.videoId:this._playback_state.videoId;
            if(!vid || (ad.id && vid==ad.id && vid!=this._playback_state.videoId))return;
            let pos=1.0*data.currentTime;
            if(ad.normal_sample && ad.normal_sample.video==vid && now-ad.normal_sample.at>=1500 && pos>ad.normal_sample.pos+0.5) this._clear_ad(true);
            else if(!ad.normal_sample || ad.normal_sample.video!=vid || now-ad.normal_sample.at>=1500) ad.normal_sample={at:now,pos:pos,video:vid};
        },
        _ad_unlock_window: function() {
            let ad=this.ad;
            if(!this.skip_ads || !this._ad_active || !ad.running || ad.can_skip || ad.skippable===false || ad.position==null || !ad.sampled)return false;
            let pos=ad.position+max(0,util.monotonic_ms()-ad.sampled)/1000.0;
            return pos>=3 && pos<7;
        },
        _schedule_ad_probe: function() {
            // The estimated unlock time is used ONLY for a bounded status query.
            // Never send skipAd until the TV reports isSkipEnabled.
            if(this._ad_probe_timer){this._ad_probe_timer.cancel();this._ad_probe_timer=null;}
            let ad=this.ad,self=this;
            if(!this.connected() || !this.skip_ads || !this._ad_active || !ad.running || ad.can_skip ||
               ad.skippable!==true || ad.probed || ad.position==null || !ad.sampled || (ad.duration!=null && ad.duration<=5))return;
            let pos=ad.position+max(0,util.monotonic_ms()-ad.sampled)/1000.0;
            if(pos>=7 || (ad.duration!=null && pos>=ad.duration))return;
            this._ad_probe_timer=uloop.timer(max(0,int((5.2-pos)*1000)),()=>{
                self._ad_probe_timer=null;
                if(self.ad!=ad || !self.connected() || !self.skip_ads || !self._ad_active || !ad.running || ad.can_skip || ad.skippable!==true || ad.probed)return;
                let estimated=ad.position+max(0,util.monotonic_ms()-ad.sampled)/1000.0;
                if(estimated>=7 || (ad.duration!=null && estimated>=ad.duration))return;
                if(self._command_mutex || length(self._command_queue) || self._now_playing_pending){
                    // Retry only within the bounded unlock window; never queue
                    // a speculative skip or a second concurrent status request.
                    self._ad_probe_timer=uloop.timer(100,()=>{
                        self._ad_probe_timer=null;
                        if(self.ad==ad)self._schedule_ad_probe();
                    });
                    return;
                }
                ad.probed=true;
                util.debug('lounge','Ad unlock check: requesting current TV state');
                self.get_now_playing();
            });
        },
        _clear_ad: function(confirmed,explicit_skip) {
    if(this._ad_probe_timer){this._ad_probe_timer.cancel();this._ad_probe_timer=null;}
    if(this._skip_confirm_timer){this._skip_confirm_timer.cancel();this._skip_confirm_timer=null;}
    if (this._ad_retry_timer) { this._ad_retry_timer.cancel(); this._ad_retry_timer = null; }
    let previous=this.ad;
    if(this._ad_active && previous?.skip_dispatched_at!=null)
        util.debug('lounge',sprintf('Ad end: %d ms after skip dispatch',util.monotonic_ms()-previous.skip_dispatched_at));
    if(this._ad_active && previous?.id){this._last_ad_video=previous.id;this._last_ad_end_ms=util.monotonic_ms();}
    let skipped=false,saved=0;
    if(this._ad_active && confirmed===true && previous?.skip_dispatched_at!=null){
        let remaining=previous.skip_remaining;
        saved=remaining==null?0:max(0,remaining-(util.monotonic_ms()-previous.skip_dispatched_at)/1000.0);
        // A natural transition without remaining time is not confirmation.
        skipped=!!explicit_skip || (remaining!=null && saved>0);
        if(skipped && this.on_stat)this.on_stat('ad_skips',saved);
    }
    this._ad_active = false;
    this.ad = { active: false, position: null, duration: null, sampled: 0,
        running: false, can_skip: false, skippable:null, skip_observed_at:null, skip_enabled_at:null, skip_dispatched_at:null, probed:false, manual_mute_override:false, skip_pending: false, skip_attempt: 0, attempts: 0, skip_sent: false, id: '', last_signal:0, normal_sample:null, confirm:null };
    if(previous?.confirm) { let cb=previous.confirm; previous.confirm=null; try{cb(skipped);}catch(e){util.warn('lounge','Ad completion callback failed');} }
        },
        _update_ad: function(data, playing) {
    let now = util.monotonic_ms();
    let id = data.adVideoId || data.adId || (playing ? data.videoId : '') || '';
    if(!this._ad_active){
        let p=this._playback_state;
        if(p.position_known && p.state==STATE_PLAYING && this._playback_sample_ms)
            p.currentTime+=max(0,now-this._playback_sample_ms)/1000.0*this.playback_speed;
        this._playback_sample_ms=now;
        p.position_known=false;this._position_report_ms=0;
    }
    if (!this._ad_active || (id && this.ad.id && id != this.ad.id)) {
        this._clear_ad(true);
        this._ad_active = true;
        this.ad.active = true;
        this.ad.started_at=now;
    }
    let ad = this.ad;
    this._content_confirmed=false;
    this._playback_state.position_known=false;this._position_report_ms=0;
    ad.last_signal=now; ad.normal_sample=null;
    if (id) ad.id = id;
    // Only use ad-specific event timing, never the main video's duration.
    let pos = data.adCurrentTime ?? data.currentTime;
    let dur = data.adDuration ?? data.duration;
    if (valid_number(pos,0,604800)) {
        ad.position = 1.0 * pos;
        ad.sampled = now;
    } else if (ad.position != null && ad.running && ad.sampled) {
        ad.position += (now - ad.sampled) / 1000.0;
        ad.sampled = now;
    }
    if (valid_number(dur,0.001,604800))
        ad.duration = 1.0 * dur;
    if (data.isSkippable != null && index(['true','false','0','1'],''+data.isSkippable)>=0)
        ad.skippable = index(['true','1'],''+data.isSkippable)>=0;
    if (data.isSkipEnabled != null && index(['true','false','0','1'],''+data.isSkipEnabled)>=0) {
        let enabled=index(['true','1'],''+data.isSkipEnabled)>=0;
        if(enabled && !ad.can_skip)ad.skip_enabled_at=now;
        if(!enabled)ad.skip_enabled_at=null;
        ad.can_skip=enabled;
        if(ad.can_skip){
            ad.skippable=true;
            // This is the observed enabled position, not a server-supplied threshold.
            if(ad.skip_observed_at==null && valid_number(pos,0,604800))ad.skip_observed_at=1.0*pos;
        }else ad.skip_observed_at=null;
    }
    if(ad.can_skip)ad.skippable=true;
    if (playing || data.adState == '1081' || data.adState == 1081) ad.running = true;
    else if (data.adState != null) ad.running = false;
    // Start the skip before any new mute or background state request.
    if (this.skip_ads && ad.can_skip && !ad.skip_sent && !this._ad_retry_timer && ad.attempts < 3) this.skip_ad();
    if (this.mute_ads) this._apply_ad_mute();
    this._schedule_ad_probe();
    if(this.on_state_change)this.on_state_change(this._playback_state);
        },
        skip_ad: function(on_result) {
    let ad = this.ad;
    let self = this;
    if (this.passive() || !this.connected() || !this._ad_active || !ad.can_skip || ad.skip_pending || ad.skip_sent || this._ad_retry_timer ||
        (ad.skip_attempt && util.monotonic_ms() - ad.skip_attempt < 1200)) {
        if (on_result) on_result(false);
        return false;
    }
    ad.skip_pending = true;
    ad.skip_attempt = util.monotonic_ms();
    ad.attempts++;
    if(on_result) ad.confirm=on_result;
    let manual=!!ad.confirm;
    this._command('skipAd', {}, (ok) => {
        if(self.ad!=ad) return;
        ad.skip_pending=false;
        if(!self.connected() || !self._ad_active) {
            if(ad.confirm) {let cb=ad.confirm;ad.confirm=null;cb(false);}
            return;
        }
        if(ad.skip_dispatched_at!=null)util.debug('lounge',sprintf('Skip HTTP %s after %d ms',ok?'OK':'failed',util.monotonic_ms()-ad.skip_dispatched_at));
        if(ok) {
            ad.skip_sent=true;
            // The ad-end event is authoritative. Avoid competing reads while it arrives.
            if(!self._now_playing_pending && !length(filter(self._command_queue,(e)=>e.name=='getNowPlaying'))){
                self._skip_confirm_timer=uloop.timer(250,()=>{
                    self._skip_confirm_timer=null;
                    if(self.ad==ad && self._ad_active && ad.skip_sent && !self._ad_mute_pending)self.get_now_playing();
                });
            }
        }
        if(self._ad_retry_timer) self._ad_retry_timer.cancel();
        self._ad_retry_timer=uloop.timer(ok?2200:1300,()=>{
            self._ad_retry_timer=null;
            if(self.ad!=ad || !self._ad_active) return;
            ad.skip_sent=false;
            if(self.skip_ads && self.connected() && ad.can_skip && ad.attempts<3 && util.monotonic_ms()-ad.last_signal<10000) self.skip_ad();
            else if(ad.confirm) {let cb=ad.confirm;ad.confirm=null;cb(false);}
        });
    },null,()=>self.ad==ad && self._ad_active && ad.can_skip && (manual || self.skip_ads));
    return true;
        },
        set_auto_play_mode: function(enabled) {
            if(!this.connected() || this.passive() || this.shared_control() || this.auto_play!==enabled)return;
            let mode=enabled?'ENABLED':'DISABLED',self=this;
            if(this.autoplay_mode==mode || this._autoplay_request?.mode==mode)return;
            let pending={mode:mode,epoch:this._command_epoch};
            this._autoplay_request=pending;
            function done(){if(self._autoplay_request==pending)self._autoplay_request=null;}
            return this._command('setAutoplayMode',{autoplayMode:mode},done,done,
                ()=>!self.passive() && !self.shared_control() && self.auto_play===enabled && self.autoplay_mode!=mode);
        },
		set_volume: function(volume) {
	return this._command('setVolume', { volume: volume });
		},
		subscribe: function(on_result, on_error) {
	let self = this;
	if (!this.connected()) {
		if (on_error) on_error('not connected');
		else if (on_result) on_result(false);
		return;
	}

	let params = this._common_connection_parameters();
	params.RID = 'rpc';
	params.CI = '0';
	params.TYPE = 'xmlhttp';
	let url = API_BASE + '/bc/bind?' + util.query_encode(params);

	util.info('lounge', 'Subscribing to Lounge events');

	if(this._subscribe_active || this._subscribe_abort_pending){if(on_error)on_error('subscription already active');else if(on_result)on_result(false);return;}
    this._subscribe_active = true;
    let generation=++this._subscribe_generation;
    let ended=false;
    let epoch=this._command_epoch;
    this._subscribe_started=util.monotonic_ms();
    if(!this._session_started)this._session_started=this._subscribe_started;
    if(!this._last_event_time)this._last_event_time=this._subscribe_started;
    function end_once(ok,err){
        if(ended || self._subscribe_generation!=generation)return;
        ended=true;
        self._subscribe_abort=null;self._subscribe_abort_pending=false;
        self._subscribe_active=false;self._subscribe_uc=null;self._stop_watchdog();
        if(err && on_error)on_error(err);else if(on_result)on_result(ok);
    }

    this._subscribe_abort=()=>{
        if(ended || self._subscribe_generation!=generation)return;
        let old=self._subscribe_uc;
        self._subscribe_abort_pending=true;
        self._subscribe_active=false;
        self._stop_watchdog();
        self._subscribe_abort=null;
        uloop.timer(0,()=>{
            if(old){try{old.free();}catch(e){}}
            if(ended || self._subscribe_generation!=generation)return;
            end_once(false);
        });
    };
	// Drop any partial data left over from a previous subscription so a stale
	// half-event from the old connection is never mixed into this one.
	this._subscribe_buffer = '';
	this._chunk_remaining = -1;
	this._current_chunk = '';

	// Start the watchdog.
	this._start_watchdog(() => end_once(false));

	let handle = http.request({
		url: url,
		method: 'GET',
		timeout_ms: 0, // no timeout; long-poll
		on_data: (chunk) => {
			if(ended || self._subscribe_generation!=generation || self._command_epoch!=epoch)return;
			self._subscribe_buffer = (self._subscribe_buffer || '') + chunk;
			self._process_subscribe_buffer();
		},
        on_done:(status,headers,body)=>{
            if(ended || self._subscribe_generation!=generation)return;
            let ok=self._command_epoch==epoch && self._handle_session_result(status,body||'') && status>=200 && status<300 && self._chunk_remaining<0 && !length(self._subscribe_buffer);
            if(!ok)util.debug('lounge',sprintf('Backchannel ended: HTTP %d, partial frame=%s',status,self._chunk_remaining>=0 || length(self._subscribe_buffer)>0?'yes':'no'));
            end_once(ok);
        },
        on_error:(err)=>{util.debug('lounge','Backchannel transport error: '+err);end_once(false,err);},
	});
    if(!ended && this._subscribe_generation==generation)this._subscribe_uc=handle;
		},
		_process_subscribe_buffer: function() {
	let self = this;
	// The long-poll response is a stream of length-prefixed JSON chunks. Each
	// chunk is a decimal length line (the length counts the JSON bytes plus the
	// trailing newline) followed by that many bytes of JSON. uclient may split
	// the stream at any byte, so we parse incrementally: read a length line up
	// to the newline, then consume exactly that many bytes of content. The
	// in-progress length and accumulated JSON are kept on the instance so a
	// chunk split across reads is reassembled correctly and delivered once.
	let buf = this._subscribe_buffer;
	while (true) {
		if (this._chunk_remaining < 0) {
			// Waiting for a length line (terminated by newline).
			let nl = index(buf, '\n');
			if (nl < 0) { if(length(buf)>16){this._subscribe_buffer='';this._connection_lost();return;} break; } // need more data
			let line = substr(buf, 0, nl);
			buf = substr(buf, nl + 1);
			if(!match(line,/^[0-9]{1,7}$/) || int(line)>1048576) {this._subscribe_buffer='';this._chunk_remaining=-1;this._current_chunk='';this._connection_lost();return;}
			this._chunk_remaining = int(line);
			if (this._chunk_remaining != this._chunk_remaining)
				this._chunk_remaining = 0;
			this._current_chunk = '';
			if (this._chunk_remaining == 0)
				this._chunk_remaining = -1; // skip an invalid zero-length chunk
		}
		else {
			// Reading content: consume up to chunk_remaining bytes.
			if (length(buf) == 0)
				break; // need more data
			let take = this._chunk_remaining < length(buf) ? this._chunk_remaining : length(buf);
			this._current_chunk += substr(buf, 0, take);
			buf = substr(buf, take);
			this._chunk_remaining -= take;
			if (this._chunk_remaining == 0) {
				// The length counts the trailing newline; strip it before parsing.
				let chunk = replace(this._current_chunk, /\n$/, '');
				this._current_chunk = '';
				this._chunk_remaining = -1;
				let events;
				try {
					events = json(chunk);
				}
				catch (e) {
					events = null;
				}
				if(type(events)!='array'){this._subscribe_buffer='';this._connection_lost();return;}
                if (events) {
					self._process_events(events);
					if (!self.connected()) {
						self._subscribe_buffer='';self._current_chunk='';self._chunk_remaining=-1;
						return;
					}
				}
			}
		}
	}
	this._subscribe_buffer = buf;
		},
		_start_watchdog: function(on_timeout) {
	let self = this;
	if (this._watchdog_timer)
		return;
    let generation=this._subscribe_generation,epoch=this._command_epoch;
    this._watchdog_timer=util.repeat_timer(uloop,5000,()=>{
        let now=util.monotonic_ms();
        let transport_age=now-self._last_event_time;
        let proof=self._last_screen_event_time;
        let screen_age=now-(proof||self._session_started||self._subscribe_started);
        let screen_limit=proof?18000:10000;
        let reason=!self.connected()?'session_lost':screen_age>=screen_limit?'screen_stale':transport_age>30000?'transport_stale':null;
        if(!reason)return;
        util.debug('lounge',sprintf('Watchdog: %s (transport %d ms, screen %d ms)',reason,transport_age,screen_age));
        self._stop_watchdog();
        // Teardown runs after the firing native timer callback has unwound.
        // A rollover or explicit disconnect before then supersedes this job.
        uloop.timer(0,()=>{
            if(self._subscribe_generation!=generation || self._command_epoch!=epoch)return;
            if(reason=='screen_stale')self._screen_missing=true;
            if(self.on_disconnected)self.on_disconnected('watchdog:'+reason);
            if(self._subscribe_active && self._subscribe_abort){
                // Single abort path invalidates state immediately and delivers
                // completion once; native disposal is deferred by http.uc.
                self._connection_lost();
            }else{
                self._connection_lost();
                if(on_timeout)on_timeout();
            }
        });
    });
		},
		_stop_watchdog: function() {
	if (this._watchdog_timer) {
		this._watchdog_timer.cancel();
		this._watchdog_timer = null;
	}
		},
        // Technical teardown is local only. Never send a user-initiated
        // MDX termination: the TV owns its current playback session.
        detach: function() {
            this._detaching=true;
            this._stop_watchdog();
            this._connection_lost();
            this._lounge_token_expired();
        },
        _parse_event_chunks: function(body,on_events){
            if(type(body)!='string')return false;
            let offset=0,epoch=this._command_epoch;
            while(offset<length(body)){
                let rel=index(substr(body,offset),'\n');
                let nl=rel<0?-1:offset+rel;
                if(nl<0 || nl-offset>7)return false;
                let line=substr(body,offset,nl-offset);
                if(!match(line,/^[0-9]{1,7}$/) || int(line)>1048576)return false;
                let n=int(line);offset=nl+1;
                if(!n)continue;
                if(offset+n>length(body))return false;
                let raw=substr(body,offset,n);offset+=n;
                let events;
                try{events=json(raw);}catch(e){return false;}
                if(type(events)!='array')return false;
                on_events(events);
                if(this._command_epoch!=epoch)return false;
            }
            return true;
        },

	});
	self.screen_id = opts.screen_id;
	self.device_name = opts.device_name || 'SponsorBlockTV';
	self.lounge_token = opts.lounge_token || null;
	self.mute_ads = opts.mute_ads || false;
	self.skip_ads = opts.skip_ads || false;
	self.auto_play = opts.auto_play !== false;
	self.on_event = opts.on_event;
    self.on_stat=opts.on_stat;
	self.on_state_change = opts.on_state_change;
	self.on_connected = opts.on_connected;
	self.on_disconnected = opts.on_disconnected;
	self.on_error = opts.on_error;
	self.device_id = opts.controller_id ?? new_remote_id();
	if(!match(self.device_id,/^[a-f0-9]{32}$/))die('Invalid controller ID');
    self.controller_mode=opts.controller_mode||'standard';
	self._sid = null;
	self._gsession = null;
	self._last_event_id = null;
	self._command_offset = 1;
	self._screen_name = null;
	self._device_info = null;
	self.volume_state = {};
	self.queue = null; self.queue_complete = false; self.queue_requests=[]; self.speed_known = false; self.autoplay_mode = null; self.quality = null; self.up_next = null; self.has_next=null;self.has_previous=null;
	self.playback_speed = 1.0;
    self._detaching = false;
	self._playback_state = {
		currentTime: 0.0,
		duration: 0.0,
		videoId: '',
		state: STATE_STOPPED,
	};
	self._subscribe_active = false;
	self._subscribe_uc = null;
	self._watchdog_timer = null;
	self._last_event_time = 0;
	self._screen_confirmed = false;
	self._last_screen_event_time = 0;
    self.controllers=null;self.controller_changes=[];self.controller_observed_ms=0;
    self.controller_conflict=null;self.controller_conflict_count=0;
	self._ad_retry_timer = null;
    self._ad_probe_timer = null;
    self._skip_confirm_timer = null;
    self._mute_verify = null;
	self._content_confirmed = false;
	self._ad_mute_owned = false;
	self._ad_mute_pending = false;
	self._manual_mute_pending = false;
	self._volume_query_pending = false;
	self._now_playing_pending = false;
	self._clear_ad();
	self._command_mutex = false;
	self._command_queue = [];
	self._command_epoch = 0;
	self._command_inflight=null;
	self._subscribe_generation=0;
	self._subscribe_abort=null;
	self._subscribe_abort_pending=false;
	self._connect_generation=0;
	self._auth_generation=0;
	self._subscribe_started=0;
    self._session_started=0;
    self._screen_missing=false;
    self._presence_pending=false;self._screen_revision=0;
	self._playback_sample_ms=0;
	self._position_report_ms=0;
	self._revisions={position:0,video:0,playback:0,volume:0,mute:0,queue:0,speed:0,autoplay:0};
	self._subscribe_buffer = '';
	self._chunk_remaining = -1;
	self._current_chunk = '';
	return self;
}

export {
	YtLoungeApi, controller_seed, persistent_controller_id,
	STATE_STOPPED, STATE_BUFFERING, STATE_PLAYING, STATE_PAUSED,
	STATE_STARTING, STATE_CUED, STATE_ADVERTISEMENT, STATE_AD_SKIPPED,
	parse_state
};
