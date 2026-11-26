// runtime.uc - SponsorBlockTV runtime (device listeners + main loop).
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Mirrors upstream main.py: for each paired device, maintain a Lounge
// connection, subscribe to playback events, fetch SponsorBlock segments, and
// skip/mute as needed.

'use strict';

import * as util from './util.uc';
import * as lounge from './lounge.uc';
import * as sb from './sponsorblock.uc';
import * as live from './live.uc';
import * as http from './http.uc';
import {POLICY_KEYS,initial_policy,valid_policy_value,read_policy,save_policy,read_stats,save_stats,validate_data_dir} from './config.uc';

let uloop = require('uloop');

// --- DeviceListener -------------------------------------------------------

function DeviceListener(api_helper, config, device, debug, controller_id) {
	let self = proto({}, {
		_start_refresh_loop: function() {
	let self = this;
	this._refresh_timer = util.repeat_timer(uloop,24 * 3600 * 1000, () => {
		self.lounge.refresh_auth(() => {});
	});
		},
		loop: function() {
	let self = this;
	this._start_refresh_loop();
	this._run_loop();
		},
        _retry: function(network,fast) {
            if(this.cancelled)return;
            if(this._loop_timer)this._loop_timer.cancel();
            let self=this;
            let delay=(network ? [2500,5000,10000,20000,30000][min(4,this._retry_count++)] : [1000,2000,3000,5000,5000][min(4,this._offline_count++)])+this._retry_jitter;
            let now=util.monotonic_ms();
            // At most one expedited recovery in 30 seconds, only after an
            // established session. Offline/auth failures retain backoff.
            if(fast && this.lounge.linked() && (!this._last_fast_retry || now-this._last_fast_retry>=30000)){
                this._last_fast_retry=now;delay=300+this._retry_jitter;
            }
            this._loop_timer=uloop.timer(int(delay),()=>{self._loop_timer=null;self._run_loop();});
        },
		_run_loop: function() {
	let self = this;
	if (this.cancelled)
		return;

	if (this.phase != 'offline' && this.phase != 'network_error' && this.phase != 'auth_error') this.phase = 'connecting';
	// Ensure linked (refresh auth).
	if (!this.lounge.linked()) {
		this.lounge.refresh_auth((ok) => {
			if (self.cancelled) return;
			if (!ok) {
				self.phase = 'auth_error';
				self._retry(true);
				return;
			}
			self._run_loop();
		});
		return;
	}

	// Wait for device availability.
	this.lounge.is_available((available) => {
		if (self.cancelled) return;
		if (!available) {
            self.lounge._screen_missing=true;
			self.phase = 'offline';
			self._retry(false);
			return;
		}
		self._offline_count=0;
        // Cloud availability is only permission to attempt a bind; it is not TV liveness.
		self.phase = self.lounge._screen_missing?'offline':'connecting';
		self._connect_and_subscribe();
	}, (err) => {
		if (self.cancelled) return;
		self.phase = 'network_error';
		self._retry(true);
	});
		},
		_connect_and_subscribe: function() {
	let self = this;
	this.lounge.connect((connected) => {
		if (self.cancelled) {if(connected)self.lounge.detach();return;}
		if (!connected) {
			self.phase = self.lounge._screen_missing?'offline':'reconnecting';
			self._retry(true);
			return;
		}
		self.phase = 'connected';
        if(!self.lounge._session_started)self.lounge._session_started=util.monotonic_ms();
		util.debug(self.logger_tag, sprintf('Lounge session opened for %s (%s)',
			self.lounge._screen_name || self.name, self.name));
        let api=self.lounge, epoch=api._command_epoch, sid=api._sid, empty_polls=0;
        let established_at=util.monotonic_ms();
        function subscribe_session(){
            if(self.cancelled)return;
            let cursor=api._last_event_id, started=util.monotonic_ms();
            api.subscribe((subscribed) => {
            if(self.cancelled)return;
            // A successful, complete long-poll response is not a TV disconnect.
            // Continue with the same SID and AID; keep ad/mute/command state.
            if(subscribed && api.connected() && api._command_epoch==epoch && api._sid==sid){
                if(api._last_event_id!=cursor || util.monotonic_ms()-started>=2000)empty_polls=0;
                else empty_polls++;
                if(empty_polls<3){
                    util.debug(self.logger_tag,'Lounge backchannel renewed (same session)');
                    subscribe_session();return;
                }
                util.warn(self.logger_tag,'Repeated empty backchannel responses; reconnecting');
            }
            util.debug(self.logger_tag,'Lounge session ended; reconnecting');
			if (self._status_timer) { self._status_timer.cancel(); self._status_timer = null; }
			self.phase = api._screen_missing?'offline':'reconnecting';
			self._state_revision++;
			self._current_state = null;
			self._segment_generation++;self._segment_video=null;self._segment_fetch=false;
			live.update_metadata(self,null);
			if(self._seek_abort)self._seek_abort();
            self._seek_pending=false;self._seek_dispatched=false;self._seek_generation++;
            self._seek_latency_samples=[];
			self.command_pending=false;self.command_action=null;self.command_status='failed';
			self.command_generation=(self.command_generation||0)+1;
			if (self._skip_timer) { self._skip_timer.cancel(); self._skip_timer = null; }
            let fast=util.monotonic_ms()-established_at>=5000;
			if(api._command_epoch==epoch)self.lounge._connection_lost();
			if (!subscribed) {
				self._retry(true,fast);
				return;
			}
			// The clean response was not renewable; establish a new session.
			self._offline_count=0;
			self._retry(false,fast);
		    });
        }
        subscribe_session();
		// Seed mute state first so the earliest advertisement can be muted without a query.
        if(self.lounge.mute_ads){
            self.lounge._command('getVolume',{},null,null,null,true);
            self.lounge.get_now_playing();
        }else{
            self.lounge.get_now_playing();
            self.lounge._command('getVolume');
        }
		if (self.lounge._subscribe_active && self.phase=='connected') self._status_timer = util.repeat_timer(uloop,6000, () => {
			if (self.cancelled || !self.lounge.connected() || !self.lounge._subscribe_active) return;
            // Let the backchannel deliver the unlock event without competing
            // periodic foreground requests around the usual five-second mark.
            let api=self.lounge;
            self._check_screen_presence();
            if(api._command_mutex || length(api._command_queue) || self.command_pending || self._seek_pending)return;
            if(api._ad_mute_pending || api._ad_unlock_window() || (api._ad_active && (api.ad.skip_pending || api.ad.skip_sent || api._ad_retry_timer)))return;
			self.lounge.get_now_playing();
			if (self.lounge.volume_state.muted == null || !api._last_screen_event_time || util.monotonic_ms()-api._last_screen_event_time>=6000) self.lounge._command('getVolume');
			else if(!self.lounge._ad_active || !self.lounge.mute_ads)self.lounge._restore_ad_mute();
		});
	});
		},
        // A negative cloud availability response can confirm absence. Positive
        // responses may be cached after power-off and must never renew liveness.
        _check_screen_presence: function(){
            let api=this.lounge, now=util.monotonic_ms(), self=this;
            if(this.cancelled || !api.connected() || !api._subscribe_active || api._presence_pending ||
               api._ad_active || (api._last_screen_event_time && now-api._last_screen_event_time<12000))return;
            let epoch=api._command_epoch, revision=api._screen_revision;
            api._presence_pending=true;
            function complete(available){
                if(api._command_epoch!=epoch)return;
                api._presence_pending=false;
                if(self.cancelled || !api.connected() || !api._subscribe_active || api._screen_revision!=revision || available==null)return;
                if(!available){api._screen_missing=true;api._screen_confirmed=false;api._last_screen_event_time=0;}
            }
            api.is_available(complete,()=>complete(null));
        },
        _can_auto_seek: function(){
            let api=this.lounge, st=this._current_state, now=util.monotonic_ms();
            return this.skip_sponsorblock!==false && !api.passive() && now>=(this._remote_seek_hold_until||0) && !this.cancelled && api.connected() && api._subscribe_active && api._screen_confirmed && !api._screen_missing &&
                !api._ad_active && st?.position_known===true && st.state==lounge.STATE_PLAYING &&
                (st.seekableEnd??st.duration)>(st.seekableStart??0) &&
                api._position_report_ms>0 && now-api._position_report_ms<=15000 &&
                api._last_screen_event_time>0 && now-api._last_screen_event_time<=18000;
        },
        _cancel_skip: function(){
            if(this._skip_timer)this._skip_timer.cancel();
            this._skip_timer=null;this._skip_task=null;
        },
        // Cancel queued automatic seeks immediately; dispatched commands cannot be recalled.
        _invalidate_queued_seek: function(){
            this._cancel_skip();
            if(this._seek_pending && !this._seek_dispatched){
                this._seek_generation++;
                this._seek_pending=false;
            }
        },
        _on_state_change: function(state){
            let self=this, changed=this._current_state?.videoId!=state.videoId;
            let previous=this._current_state,now=util.monotonic_ms();
            let predicted=previous?.currentTime??0;
            if(previous?.state==1)predicted+=max(0,now-this._time_start)/1000.0*this.lounge.playback_speed;
            // A position discontinuity is evidence of a seek, not proof of
            // which controller issued it. Yield briefly to manual navigation.
            if(this.lounge.shared_control() && this.lounge.controllers!=null &&
                !changed && !this._seek_dispatched && !this.command_pending && !this.lounge._ad_active &&
                previous?.position_known===true && state.position_known===true &&
                max(state.currentTime-predicted,predicted-state.currentTime)>4){
                this._remote_seek_hold_until=now+3000;
                this._invalidate_queued_seek();
            }
            if(changed)this._remote_seek_hold_until=0;
            this._retry_count=0;
            this._current_state={...state};
            this._state_revision++;
            live.update_metadata(this,state.videoId);
            this._time_start=util.monotonic_ms();
            if(this._seek_verify)this._seek_verify();
            if(changed || !this._can_auto_seek())this._invalidate_queued_seek();
            this._refresh_segments(changed);
        },
        // Policy changes reschedule from the existing playback sample, not a fake TV event.
        _refresh_segments: function(changed){
            let self=this,state=this._current_state;
            if(!state)return;
            if(this.skip_sponsorblock===false || this.lounge.passive() || this.lounge._ad_active || !state.videoId || !length(this.api_helper.skip_categories||[]))return;
            if(this._segment_video!=state.videoId){
                this._segment_video=state.videoId;this._segment_fetch=false;this._segment_retry_at=0;
                this._segment_generation++;
            }
            let cached=this.api_helper._segment_cache.get(state.videoId);
            if(cached!=null){
                if(this._can_auto_seek())this._time_to_segment(cached,state.currentTime);
                return;
            }
            this._cancel_skip();
            if(this._segment_fetch || util.monotonic_ms()<(this._segment_retry_at||0) && !changed)return;
            this._segment_fetch=true;
            let generation=this._segment_generation,video=state.videoId;
            this.api_helper.get_segments(video,(segments)=>{
                if(self.cancelled || generation!=self._segment_generation)return;
                self._segment_fetch=false;
                let cached=self.api_helper._segment_cache.get(video);
                if(cached!=null && self._current_state?.videoId==video && self._can_auto_seek()){
                    self._time_to_segment(cached,self._current_state.currentTime);
                }
            },(err)=>{
                if(generation==self._segment_generation){self._segment_fetch=false;self._segment_retry_at=util.monotonic_ms()+5000;}
            });
        },
		_on_lounge_event: function(event_type, args) {
	let self = this;
	if (event_type == 'adPlaying' || event_type == 'onAdStateChange') {
		this._state_revision++;
        if(this._seek_abort)this._seek_abort();
        if(this._seek_pending){this._seek_pending=false;this._seek_dispatched=false;this._seek_generation++;}
		this._cancel_skip();
	}
	if (this.skip_sponsorblock!==false && !this.lounge.passive() && (event_type == 'autoplayUpNext' || event_type == 'adPlaying')) {
		let vid_id = null;
		if (event_type == 'autoplayUpNext' && length(args) > 0)
			vid_id = args[0].videoId;
		else if (event_type == 'adPlaying' && length(args) > 0)
			vid_id = args[0].contentVideoId;
		if (vid_id) {
			util.info(this.logger_tag, 'Getting segments for next video: ' + vid_id);
			this.api_helper.get_segments(vid_id, () => {});
		}
	}
		},
        _seek_lead: function(){
            // Preserve an explicitly configured offset (including negative values).
            // A confirmation includes network and reporting delay, not just execution:
            // use only a conservative fraction of recent samples, bounded to 150 ms.
            if(this.offset!=0 || length(this._seek_latency_samples)<3)return this.offset;
            let samples=[...this._seek_latency_samples];sort(samples,(a,b)=>a-b);
            return min(0.15,samples[0]/4000.0);
        },
        _time_to_segment: function(segments, position) {
            if (this.skip_sponsorblock===false || this.lounge.passive() || this._seek_pending || (this.command_pending && index(['seek','back10','forward10','skip_segment','play_video','next','previous','queue_move','play','pause','speed','dpad'],this.command_action) >= 0)) return;
            let speed = this.lounge.playback_speed || 1;
            if (speed <= 0) return;
            let elapsed = max(0, util.monotonic_ms() - this._time_start) / 1000.0;
            let current = position + elapsed * speed;
            for (let segment in segments) {
                let state=this._current_state||{};
                let lower=state.seekableStart??0,upper=state.seekableEnd??state.duration;
                let end=sb.segment_bounded_end(segment.end,state);
                if(end==null || end<=current || end<=segment.start)continue;
                let target=sb.segment_seek_target(segment.end,state);
                if(target<=current+0.25 && target!=segment.end)continue;
                let delay = max(0, (segment.start - current) / speed - this._seek_lead());
                this._schedule_skip(delay, segment.end, segment.UUID,segment.start);
                return;
            }
            this._cancel_skip();
        },
        _schedule_skip: function(time_to, position, uuids, start) {
            let self=this, video=this._current_state?.videoId;
            let due=util.monotonic_ms()+max(0,int(time_to*1000));
            let previous=this._skip_task;
            if(this._skip_timer && previous?.video==video && previous.end==position && previous.due-due<=75 && due-previous.due<=75)return;
            this._cancel_skip();
            let task={video:video,end:position,start:start??position,due:due,lead:this._seek_lead()};
            this._skip_task=task;
            this._skip_timer=uloop.timer(max(0,due-util.monotonic_ms()),()=>{
                if(self._skip_task!=task)return;
                self._skip_timer=null;self._skip_task=null;
                function allowed(){
                    if(!self._can_auto_seek() || self._current_state?.videoId!=video ||
                       (self.command_pending && index(['seek','back10','forward10','skip_segment','play_video','next','previous','queue_move','play','pause','speed','dpad'],self.command_action)>=0))return false;
                    let st=self._current_state, current=st.currentTime+max(0,util.monotonic_ms()-self._time_start)/1000.0*self.lounge.playback_speed;
                    let upper=st.seekableEnd??st.duration;
                    let cached=self.api_helper._segment_cache.get(video);
                    if(cached==null || !length(filter(cached,(seg)=>seg.start==task.start && seg.end==task.end && join(',',seg.UUID)==join(',',uuids))))return false;
                    let end=sb.segment_bounded_end(position,st);
                    return end!=null && current<end && (start==null || current+task.lead*self.lounge.playback_speed>=start-0.15) && end>task.start;
                }
                if(self._seek_pending || !allowed())return;
                self._seek_pending=true;self._seek_dispatched=false;
                let generation=++self._seek_generation,epoch=self.lounge._command_epoch;
                let sample=self.lounge._revisions.position,sent=0,origin=0,rate=1,dispatched=false;
                let helper=self.api_helper, target=position;
                let finished=false,probe=null,deadline=null,verify=null;
                function finish(ok){
                    if(finished)return;finished=true;
                    if(probe){probe.cancel();probe=null;}
                    if(deadline){deadline.cancel();deadline=null;}
                    if(self._seek_verify==verify){self._seek_verify=null;self._seek_abort=null;}
                    if(self._seek_generation!=generation)return;
                    self._seek_pending=false;self._seek_dispatched=false;
                    if(ok){
                        helper.mark_viewed_segments(uuids);
                        self.record_segment_skip(max(0,target-max(task.start,origin)));
                        let elapsed=util.monotonic_ms()-sent;
                        // Do not learn from natural playback arriving at the target.
                        if(elapsed>=0 && elapsed<=2000 && origin+elapsed/1000.0*rate<target-0.5){
                            push(self._seek_latency_samples,elapsed);
                            if(length(self._seek_latency_samples)>8)shift(self._seek_latency_samples);
                            util.debug(self.logger_tag,sprintf('Segment seek confirmed in %d ms; adaptive lead %d ms',elapsed,int(self._seek_lead()*1000)));
                        }
                    }
                }
                verify=()=>{
                    if(finished)return;
                    if(self.cancelled || self._seek_generation!=generation || epoch!=self.lounge._command_epoch ||
                        self.lounge._ad_active || self._current_state?.videoId!=video || self.lounge._screen_missing){finish(false);return;}
                    let elapsed=util.monotonic_ms()-sent;
                    if(dispatched && self.lounge._revisions.position!=sample && self._current_state.position_known===true &&
                        self._current_state.currentTime>=target-0.5 && self._current_state.currentTime<=target+2+elapsed/1000.0*rate){
                        // Natural playback reaching the target is not evidence of a seek.
                        finish(origin+elapsed/1000.0*rate<target-0.5);
                    }
                };
                target=sb.segment_seek_target(position,self._current_state);
                self.lounge.seek_to(target,(ok)=>{
                    if(finished)return;
                    if(!dispatched){finish(false);return;}
                    // HTTP success alone is not a seek confirmation.
                    verify();
                },()=>{
                    if(!allowed() || self._seek_generation!=generation || helper!=self.api_helper)return false;
                    sample=self.lounge._revisions.position;sent=util.monotonic_ms();dispatched=true;
                    rate=self.lounge.playback_speed;
                    origin=self._current_state.currentTime+max(0,sent-self._time_start)/1000.0*rate;
                    if(sb.segment_seek_target(position,self._current_state)!=target || (target!=position && origin>=target-0.25)){
                        dispatched=false;return false;
                    }
                    self._seek_dispatched=true;
                    self._seek_verify=verify;self._seek_abort=()=>finish(false);
                    probe=uloop.timer(350,()=>{
                        probe=null;verify();
                        if(!finished)self.lounge.get_now_playing(null,()=>!finished && self._seek_generation==generation && !self.lounge._ad_active);
                    });
                    deadline=uloop.timer(10000,()=>{deadline=null;verify();if(!finished)finish(false);});
                    return true;
                });
            });
        },
		cancel: function(done) {
	if(this.cancelled){if(done)done();return;}
	this.cancelled = true;
    if(this._stats_timer)this._stats_timer.cancel();
    this.flush_segment_stats();
    if(this._seek_abort)this._seek_abort();
	this._seek_generation++;this._seek_pending=false;this._seek_dispatched=false;
	this.command_generation=(this.command_generation||0)+1;this.command_pending=false;
	live.update_metadata(this,null);
	if (this._status_timer) { this._status_timer.cancel(); this._status_timer = null; }
	if (this._skip_timer) {
		this._skip_timer.cancel();
		this._skip_timer = null;
	}
	if (this._refresh_timer) {
		this._refresh_timer.cancel();
		this._refresh_timer = null;
	}
	if (this._loop_timer) {
		this._loop_timer.cancel();
		this._loop_timer = null;
	}
	let api=this.lounge;
    api._detaching=true;
    let completed=false;
    function finish(){if(completed)return;completed=true;api.detach();if(done)done();}
    // Manual mute intent takes precedence over automatic restoration.
    if(api.connected() && api._ad_mute_owned && !api._manual_mute_pending && !api.ad.manual_mute_override){
        api.mute(false,true,(ok)=>{if(ok)api._ad_mute_owned=false;finish();},
            ()=>api._ad_mute_owned && !api._manual_mute_pending && !api.ad.manual_mute_override);
    }else finish();
		},
	});
	self.api_helper = api_helper;
	self.offset = (device.offset || 0) / 1000.0; // configured milliseconds to seconds
	self.name = device.name;
	self.cancelled = false;
	self.phase = 'connecting';
	self.public_id = util.md5_hex(device.screen_id);
    self.config_section=device.config_section;
    self.policy_overrides=initial_policy(config,device);
    self.skip_sponsorblock=self.policy_overrides.skip_sponsorblock=='1';
    // Retain shared helpers for identical rules; switch caches when filtering changes.
    self.policy_helper=function(policy){
        let cats=policy.skip_categories=='none'?[]:split(policy.skip_categories,',');
        let minimum=int(policy.minimum_skip_length);
        if(join(',',api_helper.skip_categories||[])==join(',',cats) && api_helper.minimum_skip_length==minimum)return api_helper;
        return sb.SponsorBlockClient({...config,skip_categories:cats,minimum_skip_length:minimum});
    };
    self.api_helper=self.policy_helper(self.policy_overrides);
    self.segment_stats={skips:0,seconds:0,ad_skips:0,ad_seconds:0,ad_mutes:0};
    self._lifetime_stats={skips:0,milliseconds:0,ad_skips:0,ad_milliseconds:0,ad_mutes:0};self._stats_dirty=false;self._stats_timer=null;
    self._stats_dir=null;
    self.flush_segment_stats=function(){
        if(!this._stats_dir || !this._stats_dirty)return;
        try{save_stats(this._stats_dir,this.public_id,this._lifetime_stats);this._stats_dirty=false;}
        catch(e){
            util.warn(this.logger_tag,'Unable to save aggregate statistics');
            if(!this.cancelled && !this._stats_timer){
                let self=this;this._stats_timer=uloop.timer(60000,()=>{self._stats_timer=null;self.flush_segment_stats();});
            }
        }
    };
    self.enable_stats_store=function(dir){
        try{this._lifetime_stats=read_stats(dir,this.public_id);this._stats_dir=dir;}
        catch(e){util.warn(this.logger_tag,'Statistics storage unavailable');}
    };
    self.record_stat=function(kind,seconds){
        if(this.policy_overrides.statistics!='1')return;
        if(index(['skips','ad_skips','ad_mutes'],kind)<0)return;
        this.segment_stats[kind]++;
        this._lifetime_stats[kind]++;
        if(seconds>0 && seconds<=604800 && index(['skips','ad_skips'],kind)>=0){
            let session=kind=='skips'?'seconds':'ad_seconds',total=kind=='skips'?'milliseconds':'ad_milliseconds';
            this.segment_stats[session]+=seconds;this._lifetime_stats[total]+=int(seconds*1000);
        }
        this._stats_dirty=true;
        if(this._stats_dir && !this._stats_timer){
            let self=this;
            this._stats_timer=uloop.timer(10000,()=>{self._stats_timer=null;self.flush_segment_stats();});
        }
    };
    self.record_segment_skip=function(seconds){
        if(seconds>0 && seconds<=604800)this.record_stat('skips',seconds);
    };
	self.video_title = '';
	self.video_author = '';
	self.metadata_id = '';
	self.command_status = '';
	self.command_pending = false;
	self.logger_tag = 'SponsorBlockTV-' + substr(self.public_id,0,8);
	self.lounge = lounge.YtLoungeApi({
		screen_id: device.screen_id,
        controller_id: controller_id,
        controller_mode:self.policy_overrides.controller_mode,
		device_name: config.join_name || 'SponsorBlockTV',
		lounge_token: null,
		mute_ads: self.policy_overrides.mute_ads=='1' && self.policy_overrides.controller_mode!='passive',
		skip_ads: self.policy_overrides.skip_ads=='1' && self.policy_overrides.controller_mode!='passive',
		auto_play: self.policy_overrides.auto_play=='1',
        on_stat: (kind,seconds)=>self.record_stat(kind,seconds),
		on_event: (event_type, args) => self._on_lounge_event(event_type, args),
		on_state_change: (state) => self._on_state_change(state),
		on_disconnected: (reason) => {
			self.phase = reason=='watchdog:transport_stale'?'network_error':'offline';
			util.info(self.logger_tag, 'Disconnected: ' + (reason || 'unknown'));
		},
	});
	self._skip_timer = null;
	self._skip_task = null;
	self._seek_pending = false;self._seek_dispatched=false;
	self._seek_generation=0;
    self._seek_verify=null;self._seek_abort=null;self._seek_latency_samples=[];
	self._segment_generation=0;self._segment_video=null;self._segment_fetch=false;
	self._time_start = 0;
	self._current_state = null;
	self._state_revision = 0;
	self._retry_count = 0;
	self._offline_count=0;
	self._retry_jitter=(ord(substr(self.public_id,0,1))*31+ord(substr(self.public_id,1,1))*17+ord(substr(self.public_id,2,1)))%500;
	self._status_timer = null;
	self._refresh_timer = null;
	self._loop_timer = null;
    self.apply_policy=function(key,value){
        let effective=value=='1',api=this.lounge;
        if(this.policy_overrides[key]!=value && index(['controller_mode','skip_categories','minimum_skip_length','skip_sponsorblock'],key)>=0)this._invalidate_queued_seek();
        this.policy_overrides[key]=value;
        if(key=='statistics'){
            if(!effective)this.flush_segment_stats();
        }else if(key=='controller_mode'){
            api.controller_mode=value;
            this._cancel_skip();
            if(value=='passive'){
                api.skip_ads=false;api.mute_ads=false;api._restore_ad_mute();
            }else{
                api.skip_ads=this.policy_overrides.skip_ads=='1';
                api.mute_ads=this.policy_overrides.mute_ads=='1';
                if(api.connected()){
                    api.set_auto_play_mode(api.auto_play);
                    if(api._ad_active){if(api.skip_ads && api.ad.can_skip)api.skip_ad();if(api.mute_ads)api._apply_ad_mute();}
                }
                if(this._current_state?.videoId)this._refresh_segments(false);
            }
        }else if(key=='skip_categories' || key=='minimum_skip_length'){
            this._cancel_skip();
            this._segment_generation++;this._segment_video=null;this._segment_fetch=false;this._segment_retry_at=0;
            this.api_helper=this.policy_helper(this.policy_overrides);
            if(this._current_state?.videoId && this.skip_sponsorblock)this._refresh_segments(false);
        }else if(key=='skip_sponsorblock'){
            this.skip_sponsorblock=effective;
            if(!effective){this._cancel_skip();}
            else if(this._current_state?.videoId && this._can_auto_seek())this._refresh_segments(false);
        }else if(key=='auto_play'){
            api.auto_play=effective;
            if(api.connected())api.set_auto_play_mode(effective);
        }else if(key=='mute_ads'){
            api.mute_ads=effective && !api.passive();
            if(api.connected() && api._ad_active){
                if(api.mute_ads){api.ad.manual_mute_override=false;api._apply_ad_mute();}
                else api._restore_ad_mute();
            }
        }else if(key=='skip_ads'){
            api.skip_ads=effective && !api.passive();
            if(api.skip_ads && api.connected() && api._ad_active && api.ad.can_skip && api.ad.attempts<3)api.skip_ad();
        }
    };
    self.enable_policy_store=function(dir){
        this.policy_ready=false;
        try{
            let saved=read_policy(dir,this.public_id),next={...this.policy_overrides};
            for(let key in POLICY_KEYS)if(saved[key]!=null && saved[key]!='inherit')next[key]=saved[key];
            // Materialize every field once, freezing old inherited settings on upgrade.
            if(util.json_dumps(saved)!=util.json_dumps(next))save_policy(dir,this.public_id,next);
            for(let key in POLICY_KEYS)if(next[key]!=this.policy_overrides[key])this.apply_policy(key,next[key]);
            this.policy_ready=true;
        }catch(e){util.warn(this.logger_tag,'TV policy storage unavailable: '+e);return;}
        this.save_device_policy=function(key,value){
            if(this.cancelled || !valid_policy_value(key,value,false))return {error:'Invalid TV policy'};
            let next={...this.policy_overrides};next[key]=value;
            if(next[key]===this.policy_overrides[key])
                return {saved:true,policies:this.policy_overrides};
            try{save_policy(dir,this.public_id,next);}
            catch(e){util.warn(this.logger_tag,'TV policy save failed: '+e);return {error:'Unable to persist TV settings'};}
            // Durable write precedes the in-memory policy update.
            this.apply_policy(key,value);
            return {saved:true,policies:this.policy_overrides};
        };
    };
	return self;
}

function run(config, opts) {
	let listeners = [];
	http.set_tracing(opts.http_tracing);
	let api_helper = sb.SponsorBlockClient(config);
    // Never silently generate a new identity when persistent storage fails.
    let seed=null;
    if(opts.data_dir && length(config.devices)){
        validate_data_dir(opts.data_dir);
        seed=lounge.controller_seed(opts.data_dir);
    }

	for (let i = 0; i < length(config.devices); i++) {
		let device = config.devices[i];
		let listener = DeviceListener(api_helper, config, device, opts.debug, seed ? lounge.persistent_controller_id(seed,device.screen_id) : null);
        if(opts.data_dir){listener.enable_policy_store(opts.data_dir);listener.enable_stats_store(opts.data_dir);}
		listeners[length(listeners)] = listener;
		listener._loop_timer=uloop.timer(min(5000,i*150),()=>{listener._loop_timer=null;if(!listener.cancelled)listener.loop();});
	}

	// Publish a local-only, ACL-protected live player API.
	live.publish(listeners);

    let stopping=false;
    function shutdown(){
        if(stopping)return;
        stopping=true;
        let pending=length(listeners), finished=false;
        function finish(){if(finished)return;finished=true;if(opts.on_exit)opts.on_exit();uloop.end();}
        let deadline=uloop.timer(4500,finish);
        if(!pending){deadline.cancel();finish();return;}
        for(let listener in listeners)listener.cancel(()=>{if(--pending==0){deadline.cancel();finish();}});
    }
    uloop.signal('SIGTERM',shutdown);
    uloop.signal('SIGINT',shutdown);

	return listeners;
}


export { DeviceListener, run };
