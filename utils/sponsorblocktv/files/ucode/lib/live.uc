// Live playback API over the local OpenWrt ubus socket.
'use strict';
import * as util from './util.uc';
import * as http from './http.uc';
import {TtlCache,segment_bounded_end,segment_seek_target} from './sponsorblock.uc';
let ubus = require('ubus');
let uloop = require('uloop');
let conn, object;

// Shared metadata scheduler: same video shares one request, stale consumers are removed.
function MetadataPool(fetch){
    let pool={active:0,queue:[],jobs:{},cache:TtlCache(3600000,64,65536),pumping:false};
    function valid_waiter(w){try{return !!w.valid();}catch(e){return false;}}
    function deliver(w,value){if(valid_waiter(w)){try{w.done(value);}catch(e){util.warn('live','Metadata callback failed');}}}
    function prune(){
        for(let id in keys(pool.jobs)){
            let job=pool.jobs[id];
            job.waiters=filter(job.waiters,valid_waiter);
            if(!job.active && !length(job.waiters))delete pool.jobs[id];
        }
        pool.queue=filter(pool.queue,(id)=>pool.jobs[id]!=null);
    }
    function pump(){
        if(pool.pumping)return;
        pool.pumping=true;prune();
        while(pool.active<3 && length(pool.queue)){
            let id=shift(pool.queue),job=pool.jobs[id];
            if(!job || !length(job.waiters))continue;
            job.active=true;pool.active++;
            let finished=false;
            function done(data,status){
                if(finished)return;finished=true;
                pool.active--;delete pool.jobs[id];
                let value=null;
                if(status==200 && type(data?.title)=='string' && length(data.title)){
                    value={title:substr(data.title,0,250),author:type(data.author_name)=='string'?substr(data.author_name,0,150):''};
                    pool.cache.set(id,value,false);
                }
                for(let w in job.waiters)deliver(w,value);
                pump();
            }
            try{fetch(id,done);}catch(e){done(null,0);}
        }
        pool.pumping=false;
    }
    pool.prune=prune;
    pool.request=(id,valid,done)=>{
        prune();
        let cached=pool.cache.get(id);
        if(cached!=null){deliver({valid:valid,done:done},cached);return;}
        let job=pool.jobs[id];
        if(job){
            if(length(job.waiters)>=64){deliver({valid:valid,done:done},null);return;}
            push(job.waiters,{valid:valid,done:done});return;
        }
        if(length(pool.queue)>=32){deliver({valid:valid,done:done},null);return;}
        pool.jobs[id]={active:false,waiters:[{valid:valid,done:done}]};push(pool.queue,id);pump();
    };
    return pool;
}
let metadata_pool=MetadataPool((id,done)=>http.get_json({
    url:'https://www.youtube.com/oembed?format=json&url='+util.urlencode('https://www.youtube.com/watch?v='+id),
    timeout_ms:6000,on_done:done,on_error:()=>done(null,0)
}));
function update_metadata(listener,id){
    if(id==listener.metadata_id && (listener.metadata_pending || listener.video_title || util.monotonic_ms()<(listener.metadata_retry_at||0)))return;
    listener.metadata_id=id;
    let generation=(listener.metadata_generation||0)+1;listener.metadata_generation=generation;
    listener.metadata_pending=false;listener.metadata_retry_at=0;listener.video_title='';listener.video_author='';
    metadata_pool.prune();
    if(listener.cancelled || !id || !match(id,/^[A-Za-z0-9_-]{11}$/))return;
    listener.metadata_pending=true;
    metadata_pool.request(id,()=>!listener.cancelled && listener.metadata_generation==generation,(value)=>{
        listener.metadata_pending=false;
        if(!value){listener.metadata_retry_at=util.monotonic_ms()+30000;return;}
        listener.video_title=value.title;listener.video_author=value.author;
    });
}

// Explicit screen availability takes precedence over a complete queue.
function navigation_available(api,vid,action){
    if(!vid || !match(vid,/^[A-Za-z0-9_-]{11}$/))return false;
    let flag=action=='next'?api.has_next:api.has_previous;
    if(type(flag)=='bool')return flag;
    if(!api.queue_complete || type(api.queue)!='array' || length(filter(api.queue,id=>id==vid))!=1)return false;
    let i=index(api.queue,vid);
    return action=='next'?i+1<length(api.queue):i>0;
}
function snapshot(listener) {
	let api = listener.lounge;
	let session = listener.phase == 'connected' && api.connected() && api._subscribe_active;
	let age = api._last_event_time ? (util.monotonic_ms() - api._last_event_time) / 1000 : -1;
	let screen_age = api._last_screen_event_time ? (util.monotonic_ms() - api._last_screen_event_time) / 1000 : -1;
	let screen_fresh=api._screen_confirmed && screen_age>=0 && screen_age<18;
    let connected = session && !api._screen_missing && age >= 0 && age <= 30 && screen_fresh;
    let playback_fresh=connected;
    let started=api._session_started||api._subscribe_started;
    let missing=api._screen_missing || (session && (screen_age>=18 || (!api._screen_confirmed && started && util.monotonic_ms()-started>=10000)));
    let connection=connected?'connected':index(['network_error','auth_error'],listener.phase)>=0?listener.phase:
        missing?'offline':session?'checking':listener.phase=='connected'?'reconnecting':listener.phase;
	let state = playback_fresh ? (listener._current_state || {}) : {};
	let known=state.position_known!==false && state.currentTime!=null && api._position_report_ms>0 && util.monotonic_ms()-api._position_report_ms<=15000;
	let position = known ? state.currentTime : 0;
	let duration = state.duration || 0;
	if (known && connected && !api._ad_active && state.state == 1 && listener._time_start)
		position += (util.monotonic_ms() - listener._time_start) / 1000 * api.playback_speed;
	let seek_start = max(0, state.seekableStart || 0);
	let seek_end = max(seek_start, state.seekableEnd ?? duration);
	if (seek_end > seek_start && position > seek_end) position = seek_end;
	let ad = api.ad || {};
	let ad_active = playback_fresh && api._ad_active;
	let ad_position = ad.position;
	if (ad_active && ad_position != null && ad.running && ad.sampled) ad_position += (util.monotonic_ms() - ad.sampled) / 1000.0;
	if (ad.duration != null && ad_position != null && ad_position > ad.duration) ad_position = ad.duration;
    // YouTube's usual skippable in-stream format unlocks at five seconds.
    // This estimate never authorizes skipAd; only the TV's isSkipEnabled does.
    let skip_at=null,skip_in=null,skip_estimated=false;
    if(ad_active && ad.can_skip && ad.skip_observed_at!=null && (ad.duration==null || ad.skip_observed_at<=ad.duration))skip_at=ad.skip_observed_at;
    else if(ad_active && !ad.can_skip && ad.skippable===true && ad_position!=null && ad_position<5 && (ad.duration==null || ad.duration>5)){
        skip_at=5;skip_estimated=true;
        let remaining=5-ad_position;skip_in=int(remaining)+(remaining>int(remaining)?1:0);
    }
    let controllers=connected && api.controllers!=null?api.controllers:null;
    let observed=controllers!=null?max(0,int((util.monotonic_ms()-api.controller_observed_ms)/1000)):null;
    let conflict=controllers!=null && api.controller_conflict!=null ? api.controller_conflict : null;
    return {
        has_next: playback_fresh && !ad_active && navigation_available(api,state.videoId,'next'),
        has_previous: playback_fresh && !ad_active && navigation_available(api,state.videoId,'previous'),
        controller_count: controllers!=null?length(controllers):null,
        controllers: controllers!=null?map(controllers,(r)=>({name:r.name,self:r.self})):null,
        controller_age: observed,
        controller_changes: controllers!=null?map(api.controller_changes,(r)=>({kind:r.kind,name:r.name,self:r.self,age:max(0,int((util.monotonic_ms()-r.at)/1000))})):[],
        controller_conflict: conflict!=null?({action:conflict.action,age:max(0,int((util.monotonic_ms()-conflict.at)/1000)),count:api.controller_conflict_count}):null,
        id: listener.public_id, name: listener.name,
        config_section: listener.config_section,
        policy_ready: listener.policy_ready===true,
        policy_overrides: listener.policy_overrides,
        segment_stats: listener.policy_overrides?.statistics=='1' && listener.segment_stats?{...listener.segment_stats,seconds:int(listener.segment_stats.seconds),ad_seconds:int(listener.segment_stats.ad_seconds),total_seconds:int(listener.segment_stats.seconds+listener.segment_stats.ad_seconds)}:null,
        lifetime_stats: listener.policy_overrides?.statistics=='1' && listener._stats_dir && listener._lifetime_stats?{skips:listener._lifetime_stats.skips,seconds:int(listener._lifetime_stats.milliseconds/1000),ad_skips:listener._lifetime_stats.ad_skips,ad_seconds:int(listener._lifetime_stats.ad_milliseconds/1000),ad_mutes:listener._lifetime_stats.ad_mutes,total_seconds:int((listener._lifetime_stats.milliseconds+listener._lifetime_stats.ad_milliseconds)/1000)}:null,
		connection: connection,
		video_id: connected ? (state.videoId || '') : '',
		title: playback_fresh ? listener.video_title : '', author: playback_fresh ? listener.video_author : '',
		position_known: connected && known && !api._ad_active,
		position: connected && known ? int(position) : 0, duration: connected ? int(duration) : 0,
		seek_start: connected ? int(seek_start) + (seek_start > int(seek_start) ? 1 : 0) : 0, seek_end: connected ? int(seek_end) : 0,
		playback: connected ? (ad_active ? 1081 : (state.state!=null ? int(state.state) : -2)) : -2,
		volume: playback_fresh && api.volume_state.volume != null ? int(api.volume_state.volume) : -1,
		muted: playback_fresh && (api.volume_state.muted == 'true' || api.volume_state.muted == true),
        mute_known: playback_fresh && api.volume_state.muted != null,
        mute_busy: !!api._ad_mute_pending,
		ad_active: ad_active,
		ad_position: ad_active && ad_position != null ? int(ad_position) : null,
		ad_duration: ad_active && ad.duration != null ? int(ad.duration) : null,
		ad_can_skip: ad_active && ad.can_skip,
        ad_skippable: ad_active ? ad.skippable : null,
        ad_skip_at: skip_at, ad_skip_in: skip_in, ad_skip_estimated: skip_estimated,
		ad_skip_pending: ad_active && (ad.skip_pending || ad.skip_sent || api._ad_retry_timer != null),
		ad_skip_cooldown: ad_active && ad.skip_attempt && util.monotonic_ms() - ad.skip_attempt < 1200,
		speed: connected && api.speed_known ? api.playback_speed : null,
		autoplay: connected ? api.autoplay_mode : null,
		queue: playback_fresh ? api.queue : null,
		queue_complete: playback_fresh && api.queue_complete,
        queue_requests: playback_fresh && !api.queue_complete ? (api.queue_requests||[]) : [],
		quality: connected && !ad_active && state.videoId ? api.quality : null,
		up_next: playback_fresh ? api.up_next : null,
		segments: connected && state.videoId && listener.api_helper ? map(filter(listener.api_helper._segment_cache.get(state.videoId)||[],s=>{let end=segment_bounded_end(s.end,state);return end!=null && min(end,int(seek_end))>s.start;}),s=>({...s,end:min(segment_bounded_end(s.end,state),int(seek_end))})) : [],
		auto_seek_pending: !!listener._seek_pending,
		command_pending: listener.command_pending,
        command_timing: listener.command_timing,
		command_status: listener.command_status,
		last_event_age: age >= 0 ? int(age) : -1
	};
}
function command(listener, action, value, text) {
    if(action=='autoplay')return {error:'Autoplay is managed in TV settings'};
	if(listener.cancelled)return {error:'Service stopping'};
	if(type(action)!='string' || type(value)!='int' || type(text)!='string')return {error:'Invalid command parameters'};
	if (snapshot(listener).connection != 'connected') return { error: 'TV is not connected' };
	if (listener.command_pending) return { error: 'Another command is pending' };
    if(index(['mute','volume'],action)>=0 && listener.lounge._ad_mute_pending)return {error:'Advertisement mute is being confirmed; retry shortly'};
	if(listener._seek_pending && index(['seek','back10','forward10','skip_segment','play_video','next','previous','queue_move','play','pause','dpad','speed'],action)>=0 && (listener._seek_dispatched!==false || !listener._invalidate_queued_seek))return {error:'Automatic skip is being confirmed; try again shortly'};
	let name, args = {};
	let api = listener.lounge;
    if(api.passive())return {error:'Passive controller mode'};
	let epoch=api._command_epoch;
	let snap = snapshot(listener);
	let segment = null;
	let prior_autoplay = api.auto_play;
	let expected_queue = null, expected_next=null, native_queue_add=index(['queue_add','queue_next'],action)>=0;
	let queue_before=api._revisions.queue, prior_video=snap.video_id;
	if (api._ad_active && index(['volume','mute','skip_ad'], action) < 0) return { error: 'Unavailable during advertisement' };
    if(action=='next' && !snap.has_next)return {error:'No next video available'};
    if(action=='previous' && !snap.has_previous)return {error:'No previous video available'};
    if (action == 'skip_ad') {
		if (!listener.lounge._ad_active || !listener.lounge.ad.can_skip || listener.lounge.ad.skip_pending) return { error: 'Ad cannot be skipped now' };
		listener.command_pending = true;
		listener.command_status = 'pending';
		let generation=(listener.command_generation||0)+1;listener.command_generation=generation;
		let accepted = listener.lounge.skip_ad((ok) => {
			if(listener.command_generation!=generation || api._command_epoch!=epoch)return;
			listener.command_pending = false;
			listener.command_status = ok ? 'sent' : 'failed';
			if (ok) listener.lounge.get_now_playing();
		});
		return accepted ? { accepted: true } : { error: 'Ad skip already attempted; retry shortly' };
	}
	if (action == 'play' || action == 'pause' || action == 'next' || action == 'previous') name = action;
	else if ((action == 'back10' || action == 'forward10') && snap.position_known && snap.seek_end > snap.seek_start) {
        name = 'seekTo'; args.newTime = max(snap.seek_start, min(snap.seek_end, snap.position + (action == 'back10' ? -10 : 10)));
    }
    else if (action == 'dpad' && value == 0 && index(['UP','DOWN','LEFT','RIGHT','ENTER','BACK'],text)>=0) {
        name='dpadCommand';args.key=text;
    }
    else if (index(['play_video','queue_add','queue_next','queue_remove'], action) >= 0 && type(text) == 'string' && match(text, /^[A-Za-z0-9_-]{11}$/)) {
        if (native_queue_add && !snap.video_id) return {error:'Play a video before adding to queue'};
        if(native_queue_add && !api.queue_complete && length(api.queue_requests||[])>=200)return {error:'Queue request limit reached'};
        if (action == 'queue_remove' && (!api.queue_complete || api.queue == null)) return { error: 'Queue unavailable' };
        if (action == 'queue_remove' && (text == snap.video_id || index(api.queue, text) < 0)) return { error: 'Cannot remove current or unknown video' };
        name = ({play_video:'setPlaylist',queue_add:'addVideo',queue_next:'insertVideo',queue_remove:'removeVideo'})[action];
        args.videoId = text;
        if (action != 'play_video' && api.queue_complete && api.queue != null) {
            expected_queue = length(filter(api.queue, (id) => id == text)) + (action == 'queue_remove' ? -1 : 1);
            if(action=='queue_next'){
                let i=index(api.queue,snap.video_id);
                if(i>=0 && length(filter(api.queue,(id)=>id==snap.video_id))==1){
                    let ids=[...api.queue];splice(ids,i+1,0,text);expected_next=join(',',ids);
                }
            }
        }
    }
    else if (action == 'queue_move' && snap.position_known && type(text) == 'string' && api.queue != null && api.queue_complete && (value == -1 || value == 1)) {
        let ids = [...api.queue];
        let current_index = index(ids, snap.video_id);
        let i = index(ids,text);
        let j = i + value;
        if (current_index < 0 || i <= current_index || j <= current_index || j >= length(ids)) return {error:'Cannot move this queue entry'};
        if (length(filter(ids,(id)=>id == text)) != 1 || length(filter(ids,(id)=>id == snap.video_id)) != 1) return {error:'Duplicate IDs cannot be safely reordered'};
        ids[i] = ids[j]; ids[j] = text; expected_queue = join(',',ids);
        name = 'setPlaylist'; args.videoId = snap.video_id; args.videoIds = join(',',ids); args.currentIndex = current_index; args.currentTime = snap.position;
    }
    else if (action == 'skip_segment' && snap.position_known && snap.duration > 0 && value >= 0 && value < length(snap.segments)) {
        segment = snap.segments[value];
        if (listener.skip_sponsorblock===false || snap.position < segment.start - 1 || snap.position >= segment.end || segment.end > snap.seek_end || segment.end < snap.seek_start) return { error: 'No active SponsorBlock segment' };
        name = 'seekTo'; args.newTime = segment_seek_target(segment.end,snap);
        if(args.newTime<=snap.position)return {error:'No active SponsorBlock segment'};
    }
    else if (action == 'seek' && snap.position_known && !listener.lounge._ad_active && snap.seek_end > snap.seek_start && value >= snap.seek_start && value <= snap.seek_end) {
		name = 'seekTo'; args.newTime = value;
	}
	else if (action == 'volume' && value >= 0 && value <= 100) {
		name = 'setVolume'; args.volume = value;
	}
	else if (action == 'mute' && (value == 0 || value == 1) && listener.lounge.volume_state.volume != null && listener.lounge.volume_state.muted != null) {
		name = 'setVolume'; args.volume = int(listener.lounge.volume_state.volume); args.muted = value ? 'true' : 'false';
		// Manual mute ownership changes only once the new volume state is confirmed.
	}
	else return { error: 'Invalid or unavailable command' };
    // A validated manual playback action supersedes an automatic seek not yet sent.
    if(listener._seek_pending && listener._seek_dispatched===false && index(['seek','back10','forward10','skip_segment','play_video','next','previous','queue_move','play','pause','dpad','speed'],action)>=0)listener._invalidate_queued_seek();
    let manual_ad=api._ad_active?api.ad:null;
    if(action=='mute')api._manual_mute_pending=true;
	listener.command_pending = true;
	listener.command_status = 'pending';
	listener.command_action = action;
    // HTTP success is not proof that the TV applied a command.
    let sid = api._sid;
    let generation=(listener.command_generation||0)+1;listener.command_generation=generation;
    let domain=name=='seekTo'?'position':name=='setVolume'?(action=='mute'?'mute':'volume'):index(['play','pause'],action)>=0?'playback':index(['next','previous','play_video'],action)>=0?'video':index(['queue_add','queue_next','queue_remove','queue_move'],action)>=0?'queue':action;
    let revision=api._revisions[domain];
    let completed=false,dispatched=false,segment_origin=snap.position;
    let accepted_at=util.monotonic_ms(),dispatch_at=null,http_at=null,observed_at=null;
    let verify_timer=null,probe_timer=null,verify_callback=null;
    function complete(ok, status) {
        if(completed)return;
        completed=true;
        if(verify_timer){verify_timer.cancel();verify_timer=null;}
        if(probe_timer){probe_timer.cancel();probe_timer=null;}
        if(api._command_verify==verify_callback)api._command_verify=null;
        if(listener.command_generation!=generation)return;
        if(api._command_epoch!=epoch){ok=false;status='failed';}
        listener.command_pending = false;
        listener.command_status = status || (ok ? 'sent' : 'failed');
        let now=util.monotonic_ms();
        listener.command_timing={action:action,status:listener.command_status,total_ms:now-accepted_at,
            queue_ms:dispatch_at!=null?dispatch_at-accepted_at:null,
            http_ms:http_at!=null && dispatch_at!=null?http_at-dispatch_at:null,
            observed_ms:observed_at!=null && dispatch_at!=null?observed_at-dispatch_at:null};
        util.debug('live',sprintf('Command result: %s %s total=%dms queue=%s http=%s observed=%s',action,listener.command_status,now-accepted_at,
            listener.command_timing.queue_ms??'-',listener.command_timing.http_ms??'-',listener.command_timing.observed_ms??'-'));
        // Track delivered requests separately from authoritative TV queue data.
        if(listener.command_status=='delivered' && native_queue_add && api._command_epoch==epoch &&
            api._sid==sid && snapshot(listener).video_id==prior_video && !api.queue_complete){
            if(!api.queue_requests)api.queue_requests=[];
            if(length(api.queue_requests)<200){
                if(action=='queue_next')unshift(api.queue_requests,text);
                else push(api.queue_requests,text);
            }
        }
        if(ok && action=='play_video')api.queue_requests=[];
        listener.command_action = null;
        if(action=='mute'){
            api._manual_mute_pending=false;
            if(ok){
                api._ad_mute_owned=false;
                if(manual_ad && api._ad_active && api.ad==manual_ad)manual_ad.manual_mute_override=true;
            }
            if(api._ad_active)api._apply_ad_mute();
            else api._restore_ad_mute();
        }
        if (ok && segment){
            listener.api_helper.mark_viewed_segments(segment.UUID);
            if(listener.record_segment_skip && dispatch_at!=null && segment_origin+(now-dispatch_at)/1000.0*api.playback_speed<args.newTime-0.5)listener.record_segment_skip(max(0,args.newTime-max(segment.start,segment_origin)));
        }
        if (!ok && api.connected() && name == 'seekTo') api.get_now_playing();
    }
    function applied() {
        if(!dispatched || api._revisions[domain]==revision)return false;
        let current = snapshot(listener);
        if(current.connection!='connected')return false;
        if (action == 'play') return current.playback == 1;
        if (action == 'pause') return current.playback == 2;
        if (action == 'play_video') return current.video_id == text;
        if (action == 'volume') return current.volume == value;
        if (action == 'mute') return api.volume_state.muted != null && current.muted == !!value;
        if (name == 'seekTo') return current.position_known && current.video_id == snap.video_id && current.position >= args.newTime - 3 && current.position <= args.newTime + 3;
        if (action == 'next' || action == 'previous') return current.video_id && current.video_id != snap.video_id;
        if (action == 'queue_move') return api.queue_complete && join(',',api.queue) == expected_queue;
        if(action=='queue_next'){
            if(!api.queue_complete || current.video_id!=prior_video)return false;
            if(expected_next!=null)return join(',',api.queue)==expected_next;
            // With no complete baseline, only confirm the observed next position.
            let i=index(api.queue,prior_video);
            return i>=0 && length(filter(api.queue,id=>id==prior_video))==1 && api.queue[i+1]==text;
        }
        if(action=='queue_add' && expected_queue==null)return api.queue_complete && current.video_id==prior_video && api.queue[length(api.queue)-1]==text;
        if (index(['queue_add','queue_next','queue_remove'],action)>=0)
            return api.queue_complete && api.queue != null && current.video_id==prior_video && length(filter(api.queue,(id)=>id==text)) == expected_queue;
        return true;
    }
    function observe(expired){
        if(completed || listener.command_generation!=generation || api._command_epoch!=epoch || api._sid!=sid)return;
        if(applied() && observed_at==null)observed_at=util.monotonic_ms();
    }
    function finish(ok) {
        http_at=util.monotonic_ms();
        observe(false);
        if(listener.cancelled || api._command_epoch!=epoch || api._sid!=sid){complete(false);return;}
        // Lounge provides no per-key focus acknowledgement. Distinguish HTTP
        // delivery from confirmed playback state instead of waiting on a fake revision.
        if(action=='dpad'){complete(dispatched && ok,dispatched && ok?'delivered':'failed');return;}
        if (!dispatched || (!ok && !applied())) { complete(false); return; }
        // If the backchannel already confirmed the operation, do not enqueue
        // an unnecessary status request which could delay the next command.
        if(applied()){complete(true);return;}
        // State events drive confirmation. A single deadline preserves the
        // failure path. Give the backchannel a short head start before polling.
        verify_callback=function(expired){
            if(completed)return;
            if(listener.cancelled || listener.command_generation!=generation || api._command_epoch!=epoch || api._sid!=sid || !api.connected()){complete(false);return;}
            observe(false);
            if(applied()){complete(true);return;}
            if(expired){
                if(api.controllers!=null && length(api.controllers)>1 && api._revisions[domain]!=revision &&
                    index(['play','pause','play_video','volume','mute','queue_move'],action)>=0 &&
                    !api._ad_active && snapshot(listener).connection=='connected'){
                    api.controller_conflict={action:action,at:util.monotonic_ms()};
                    api.controller_conflict_count++;
                    util.debug('live','Possible remote contention: command not confirmed by fresh state ('+action+')');
                }
                complete(false,native_queue_add && !api.queue_complete && ok?'delivered':'unconfirmed');
            }
        };
        api._command_verify=verify_callback;
        verify_timer=uloop.timer(5000,()=>{verify_timer=null;verify_callback(true);});
        probe_timer=uloop.timer(250,()=>{
            probe_timer=null;
            verify_callback(false);
            if(completed)return;
            if(name=='setVolume')api._command('getVolume');
            else api.get_now_playing();
        });
        verify_callback(false);
    }
    if (index(['seek','back10','forward10','skip_segment','play_video','next','previous','queue_move','play','pause','dpad'],action)>=0 && listener._skip_timer) { listener._skip_timer.cancel(); listener._skip_timer = null; listener._skip_task=null; }

	listener.lounge._command(name, args, finish, () => finish(false), () => {
        let now=snapshot(listener);
        if(listener.cancelled || api._command_epoch!=epoch || api._sid!=sid || now.connection!='connected' || (api._ad_active && index(['volume','mute'],action)<0))return false;
        if(index(['next','previous'],action)>=0 && (now.video_id!=prior_video || !(action=='next'?now.has_next:now.has_previous)))return false;
        if(name=='seekTo' && (!now.position_known || now.video_id!=prior_video || args.newTime<now.seek_start || args.newTime>now.seek_end))return false;
        if(action=='skip_segment')segment_origin=now.position;
        if(action=='skip_segment' && (listener.skip_sponsorblock===false || !length(filter(now.segments,(s)=>s.start==segment.start && s.end==segment.end && join(',',s.UUID)==join(',',segment.UUID))) || now.position>=segment.end || now.position<segment.start-1))return false;
        if(native_queue_add && (!now.video_id || now.video_id!=prior_video || api._revisions.queue!=queue_before))return false;
        if(index(['queue_remove','queue_move'],action)>=0 && (!api.queue_complete || api._revisions.queue!=queue_before || now.video_id!=prior_video))return false;
        if(action=='queue_move'){if(!now.position_known)return false;args.currentTime=now.position;}
        if(action=='mute'){
            if(api._ad_mute_pending || api.volume_state.volume==null || api.volume_state.muted==null || (manual_ad && (!api._ad_active || api.ad!=manual_ad)) || (!manual_ad && api._ad_active))return false;
            // Preserve the latest volume at dispatch, rather than an earlier UI sample.
            args.volume=int(api.volume_state.volume);
        }
        revision=api._revisions[domain];dispatched=true;dispatch_at=util.monotonic_ms();
        if(action!='dpad'){verify_callback=observe;api._command_verify=verify_callback;}
        return true;
    });
	return { accepted: true };
}

function publish(listeners) {
	conn = ubus.connect();
	if (!conn) { util.warn('live', 'ubus connection unavailable'); return; }
	object = conn.publish('sponsorblocktv.live', {
		status: { args: { ubus_rpc_session: '' }, call: (req) => {
			let devices = [];
			for (let i = 0; i < length(listeners); i++) devices[length(devices)] = snapshot(listeners[i]);
			req.reply({ devices: devices });
		}},
        policy: { args: { id:'', key:'', value:'', ubus_rpc_session:'' }, call: (req) => {
            let a=req.args;
            for(let listener in listeners){
                if(listener.public_id==a.id){
                    req.reply(listener.policy_ready && listener.save_device_policy ? listener.save_device_policy(a.key,a.value) : {error:'TV policy storage unavailable'});return;
                }
            }
            req.reply({error:'Unknown device'});
        }},
		control: { args: { id: '', action: '', value: 0, text: '', ubus_rpc_session: '' }, call: (req) => {
			let a = req.args;
			for (let i = 0; i < length(listeners); i++) {
				let listener = listeners[i];
				if (listener.public_id == a.id) { req.reply(command(listener, a.action, a.value, a.text)); return; }
			}
			req.reply({ error: 'Unknown device' });
		}}
	});
	if (!object) util.warn('live', 'Failed to publish live API');
	else util.info('live', 'Published live API');
}
export { publish, update_metadata, snapshot, command, MetadataPool };
