// sponsorblock.uc - SponsorBlock API client.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Mirrors upstream api_helpers.py: segment fetching with a conditional TTL
// cache, whitelist checks, viewed-segment reporting, and device pairing.

'use strict';

import * as util from './util.uc';
import * as http from './http.uc';
import * as fs from 'fs';
let uloop=require('uloop');

const SPONSORBLOCK_SERVICE = 'youtube';
const SPONSORBLOCK_ACTIONTYPE = 'skip';
const YOUTUBE_API = 'https://www.googleapis.com/youtube/v3/';
const LOUNGE_API_BASE = 'https://www.youtube.com/api/lounge';
// Official extension uses a five-hex hash prefix. Keep the legacy prefix on
// custom servers for compatibility; never truncate segment UUIDs for reporting.
function segment_request_url(base,vid,categories){
    let prefix=base=='https://sponsor.ajay.app/api/'?5:4;
    return base+'skipSegments/'+substr(util.sha256_hex(vid),0,prefix)+'?'+util.query_encode({
        category:categories,actionType:SPONSORBLOCK_ACTIONTYPE,service:SPONSORBLOCK_SERVICE
    });
}


const VALID_CATEGORIES = [
	'sponsor', 'selfpromo', 'intro', 'outro', 'music_offtopic',
	'interaction', 'exclusive_access', 'preview', 'filler', 'hook',
];

// --- conditional TTL cache ------------------------------------------------

// A simple TTL cache with per-entry "ignore_ttl" (locked segments cached
// forever). Mirrors AsyncConditionalTTL.
function TtlCache(time_to_live_ms, maxsize, maxbytes) {
	let self = proto({}, {
		get: function(key) {
			let e = this.entries[key];
			if (!e)
				return null;
			if (e.expires_at != null && e.expires_at <= util.monotonic_ms()) {
				this.remove(key);
				return null;
			}
			this._remove_order(key);push(this.order,key);
			return e.value;
		},
		set: function(key, value, ignore_ttl) {
			let expires_at=util.monotonic_ms()+(ignore_ttl?86400000:this.ttl_ms);
			let size=length(sprintf('%.J',value));
			this.remove(key);
			for(let old in [...this.order])if(this.entries[old].expires_at<=util.monotonic_ms())this.remove(old);
			if(size>this.maxbytes)return false;
			push(this.order,key);
			this.entries[key] = { value: value, expires_at: expires_at, size:size };
			this.bytes+=size;
			// Evict oldest if over maxsize.
			while (length(this.order) > this.maxsize || this.bytes>this.maxbytes) {
				this.remove(this.order[0]);
			}
			return true;
		},
		remove:function(key){
			let e=this.entries[key];if(!e)return;
			this.bytes-=e.size;delete this.entries[key];this._remove_order(key);
		},
		_remove_order: function(key) {
			for (let i = 0; i < length(this.order); i++) {
				if (this.order[i] == key) {
					splice(this.order, i, 1);
					return;
				}
			}
		},
	});
	self.ttl_ms = time_to_live_ms;
	self.maxsize = maxsize || 1024;
	self.maxbytes=maxbytes||262144;
	self.bytes=0;
	self.entries = {}; // key -> { value, expires_at }
	self.order = [];
	return self;
}

// Process raw segment response into a list of {start, end, UUID}.
// TV VOD metadata can round duration down to whole seconds. Allow only
// a small terminal overhang, never a segment beyond a live/DVR window.
function segment_bounded_end(end,state){
    let duration=state?.duration,upper=state?.seekableEnd??state?.seek_end??duration,lower=state?.seekableStart??state?.seek_start??0;
    if(!(upper>lower) || end<=lower)return null;
    if(end<=upper)return end;
    if(lower>=0 && lower<1 && duration>=1 && upper-duration<=1 && duration-upper<=1 && end-upper<=1)return upper;
    return null;
}
function segment_seek_target(end,state){
    let duration=state?.duration, upper=state?.seekableEnd??state?.seek_end??duration, lower=state?.seekableStart??state?.seek_start??0;
    if(type(duration)!='int' && type(duration)!='double')return end;
    let bounded=segment_bounded_end(end,state);
    if(bounded!=null)end=bounded;
    if(duration>=1 && lower>=0 && lower<1 && upper-duration<=1 && duration-upper<=1 && end==upper)return upper-0.25;
    return end;
}
function process_segments(response, minimum_skip_length, categories) {
    let valid=[], merged=[], all_locked=true, malformed=false;
    if(type(response?.segments)!='array' || length(response.segments)>1024) return [[],false,true];
    for(let seg in response.segments) {
        if(type(seg)!='object' || type(seg.segment)!='array' || length(seg.segment)!=2 ||
           index(['int','double'],type(seg.segment[0]))<0 || index(['int','double'],type(seg.segment[1]))<0 ||
           !(seg.segment[0]>=0 && seg.segment[1]>seg.segment[0] && seg.segment[1]<=604800) ||
           type(seg.UUID)!='string' || !match(seg.UUID,/^[A-Za-z0-9_-]{1,128}$/)) {
            malformed=true;continue;
        }
        if(seg.actionType!=null && seg.actionType!='skip')continue;
        if(categories && index(categories,seg.category)<0)continue;
        all_locked=all_locked && seg.locked==1;
        push(valid,{start:seg.segment[0],end:seg.segment[1],UUID:seg.UUID});
    }
    sort(valid,(a,b)=>a.start-b.start || a.end-b.end);
    let last=null, seen={};
    for(let seg in valid) {
        if(!last || seg.start>last.end) {
            last={start:seg.start,end:seg.end,UUID:[]};
            push(merged,last);seen={};
        }else last.end=max(last.end,seg.end);
        if(!seen[seg.UUID]){seen[seg.UUID]=true;push(last.UUID,seg.UUID);}
    }
    sort(merged,(a,b)=>a.start-b.start || a.end-b.end);
    return [filter(merged,(seg)=>seg.end-seg.start>=minimum_skip_length),all_locked&&!malformed,malformed];
}
// Public watch metadata is not an official API. Accept only a structured
// player response for the requested video, never a channel ID from suggestions.
function watch_channel_id(body,vid){
    if(type(body)!='string' || length(body)>2097152)return null;
    let marker='>var ytInitialPlayerResponse = ',i=index(body,marker);
    if(i<0)return null;
    let start=i+length(marker),tail=substr(body,start),end=index(tail,'</script>');
    if(end<0 || end>524288)return null;
    let raw=util.trim(substr(tail,0,end));
    if(substr(raw,-1)==';')raw=substr(raw,0,length(raw)-1);
    try{
        let data=json(raw),d=data?.videoDetails;
        if(d?.videoId===vid && type(d.channelId)=='string' && match(d.channelId,/^UC[A-Za-z0-9_-]{22}$/))return d.channelId;
    }catch(e){}
    return null;
}
// Shared across all device-specific SponsorBlock clients. Limit memory and
// concurrent page downloads; cache failures briefly so retries cannot hammer YT.
function ChannelResolver(fetch){
    let good=TtlCache(3600000,256,32768),bad=TtlCache(30000,128,8192),pending={};
    return function(vid,done){
        if(type(vid)!='string' || !match(vid,/^[A-Za-z0-9_-]{11}$/)){done(null);return;}
        let cached=good.get(vid);if(cached!=null){done(cached);return;}
        if(bad.get(vid)!=null){done(null);return;}
        if(pending[vid]){
            if(length(pending[vid])<64)push(pending[vid],done);else done(null);
            return;
        }
        if(length(keys(pending))>=2){done(null);return;}
        let waiters=[done];pending[vid]=waiters;
        function finish(channel){
            if(pending[vid]!=waiters)return;
            delete pending[vid];
            if(type(channel)=='string' && match(channel,/^UC[A-Za-z0-9_-]{22}$/))good.set(vid,channel,false);
            else {channel=null;bad.set(vid,true,false);}
            for(let cb in waiters)try{cb(channel);}catch(e){util.warn('sponsorblocktv','Channel lookup callback failed');}
        }
        try{fetch(vid,finish);}catch(e){finish(null);}
    };
}
// The native uclient watch-page request stalls on some YouTube responses.
 // Use the existing system Python for bounded HTML transport only; parsing and
 // whitelist decisions remain in ucode. The private directory is per request.
function fetch_watch_channel(vid,done){
    let dir=null,path=null,finished=false;
    function finish(channel){
        if(finished)return;finished=true;
        if(path)fs.unlink(path);
        if(dir)fs.rmdir(dir);
        done(channel);
    }
    try{
        let rng=fs.open('/dev/urandom','r');
        if(!rng){finish(null);return;}
        let bytes=rng.read(32);rng.close();
        if(length(bytes)!=32){finish(null);return;}
        let candidate='/tmp/sbtv-channel-'+util.md5_hex(bytes);
        if(!fs.mkdir(candidate,0700)){finish(null);return;}
        dir=candidate;path=dir+'/page';
        let proc=uloop.process('/usr/sbin/sponsorblocktv-watch-page',[vid,path],{},(status)=>{
            let channel=null;
            try{
                let st=fs.lstat(path);
                if(status==0 && st?.type=='file' && st.uid==0 && st.size<=2097152 && (st.mode&511)==384)
                    channel=watch_channel_id(fs.readfile(path),vid);
            }catch(e){}
            finish(channel);
        });
        if(!proc)finish(null);
    }catch(e){finish(null);}
}
let public_channel=ChannelResolver(fetch_watch_channel);
// --- SponsorBlock client --------------------------------------------------

function SponsorBlockClient(config, resolve_public_channel) {
	let self = proto({}, {
		get_channel_id: function(vid_id, on_result, on_error) {
            if (!this.apikey) {
                (resolve_public_channel||public_channel)(vid_id,(channel)=>{
                    if(channel==null && on_error)on_error('Unknown video channel (public metadata unavailable)');
                    else if(on_result)on_result(channel);
                });
                return;
            }
			let params = util.query_encode({
				id: vid_id, key: this.apikey, part: 'snippet',
			});
			let url = YOUTUBE_API + 'videos?' + params;
			http.get_json({
				url: url,
				timeout_ms:6000,
				on_done: (data, status) => {
					if (status != 200 || !data || data.error || type(data.items)!='array' || !length(data.items)) {
						if (on_result) on_result(null);
						return;
					}
					let item=filter(data.items,(x)=>type(x)=='object' && x.id==vid_id)[0];
					if (type(item)!='object' || item.kind != 'youtube#video' || item.id!=vid_id) {
						if (on_result) on_result(null);
						return;
					}
					let channel=item.snippet?.channelId;
					if(on_result)on_result(type(channel)=='string' && match(channel,/^UC[A-Za-z0-9_-]{22}$/)?channel:null);
				},
				on_error: (err) => {
					if (on_error) on_error(err);
					else if (on_result) on_result(null);
				},
			});
		},
		is_whitelisted: function(vid_id, on_result, on_error) {
			let self2 = this;
			if (length(this.channel_whitelist) == 0) {
				if (on_result) on_result(false);
				return;
			}
			let cached = this._whitelist_cache.get(vid_id);
			if (cached != null) {
				if (on_result) on_result(cached);
				return;
			}
			this.get_channel_id(vid_id, (channel_id) => {
				if (!channel_id) { if(on_error) on_error('Unknown video channel'); else if(on_result) on_result(true); return; }
				let whitelisted = false;
				if (channel_id) {
					for (let i = 0; i < length(self2.channel_whitelist); i++) {
						if (self2.channel_whitelist[i].id == channel_id) {
							whitelisted = true;
							break;
						}
					}
				}
				self2._whitelist_cache.set(vid_id, whitelisted, false);
				if (on_result) on_result(whitelisted);
			}, on_error);
		},
        get_segments: function(vid_id, on_result, on_error) {
            let self2 = this;
            if (type(vid_id)!='string' || !match(vid_id, /^[A-Za-z0-9_-]{11}$/) || !length(this.skip_categories || [])) {
                if (on_result) on_result([], true);
                return;
            }
            let cached = this._segment_cache.get(vid_id);
            if (cached != null) {
                if (on_result) on_result(cached, true);
                return;
            }
            let waiting = this._segment_pending[vid_id];
            if (waiting) {
                if(length(waiting)<128)push(waiting,[on_result,on_error]);
                else if(on_error)on_error('Too many pending segment callbacks');else if(on_result)on_result([],false);
                return;
            }
            if(length(keys(this._segment_pending))>=8){if(on_error)on_error('Segment request limit');else if(on_result)on_result([],false);return;}
            let pending=[[on_result,on_error]],finished=false,deadline=null,request_started=false,handle=null;
            this._segment_pending[vid_id]=pending;
            function finish(segments, locked, error) {
                if(finished || self2._segment_pending[vid_id]!=pending)return;
                finished=true;
                if(deadline){deadline.cancel();deadline=null;}
                if(handle){handle.free();handle=null;}
                let callbacks=pending;
                delete self2._segment_pending[vid_id];
                if (!error) self2._segment_cache.set(vid_id, segments, locked && length(segments) > 0);
                for (let cb in callbacks) {
                    try{if(error && cb[1])cb[1](error);else if(cb[0])cb[0](segments,locked);}catch(e){util.warn('sponsorblocktv','Segment consumer callback failed');}
                }
            }
            deadline=uloop.timer(this._segment_deadline_ms,()=>finish([],false,'Segment request deadline exceeded'));
            try{this.is_whitelisted(vid_id, (whitelisted) => {
                if(finished || request_started)return;
                request_started=true;
                if (whitelisted) { finish([], false); return; }
                let url=segment_request_url(self2.sponsorblock_api_url,vid_id,self2.skip_categories);
                handle=http.get_json({
                    url: url, headers: { Accept: 'application/json', 'X-CLIENT-NAME':'SponsorBlockTV OpenWrt' }, timeout_ms: 6000,max_body_bytes:524288,
                    on_done: (data, status) => {
                        if (status == 404) { finish([], false); return; }
                        if (status != 200 || type(data) != 'array') { finish([], false, 'SponsorBlock HTTP ' + status); return; }
                        let response = null;
                        for (let item in data) if (type(item)=='object' && item.videoID == vid_id) { response = item; break; }
                        if (!response) { finish([], false); return; }
                        let result = process_segments(response, self2.minimum_skip_length,self2.skip_categories);
                        if(result[2]){finish([],false,"Malformed SponsorBlock response");return;}
                        finish(result[0], result[1]);
                    },
                    on_error: (err) => finish([], false, err)
                });
            }, (err) => finish([], false, err));}catch(e){finish([],false,'Segment request setup failed');}
        },
        _send_view: function(id,done){
            let url=this.sponsorblock_api_url+'viewedVideoSponsorTime/?'+util.query_encode({UUID:id});
            http.post_form({url:url,data:{},timeout_ms:5000,on_done:done,on_error:done});
        },
        _pump_views: function(){
            let self=this;
            while(this._view_active<2 && length(this._view_queue)){
                let id=shift(this._view_queue),finished=false;
                this._view_active++;
                function done(){
                    if(finished)return;finished=true;self._view_active--;delete self._view_pending[id];
                    if(!self._view_timer)self._view_timer=require('uloop').timer(250,()=>{self._view_timer=null;self._pump_views();});
                }
                try{this._send_view(id,done);}catch(e){done();}
            }
        },
        mark_viewed_segments: function(uuids){
            if(!this.skip_count_tracking)return;
            for(let id in uuids||[]){
                if(length(this._view_queue)>=128){if(util.monotonic_ms()>=(this._view_warn_at||0)){util.warn('sponsorblocktv','Viewed-segment queue full; some statistics dropped');this._view_warn_at=util.monotonic_ms()+60000;}break;}
                if(type(id)!='string' || !match(id,/^[A-Za-z0-9_-]{1,128}$/) || this._view_pending[id])continue;
                this._view_pending[id]=true;push(this._view_queue,id);
            }
            this._pump_views();
        },

	});
	self.apikey = config.apikey || '';
	self.skip_categories = config.skip_categories ?? ['sponsor'];
	self.channel_whitelist = config.channel_whitelist || [];
	self.skip_count_tracking = config.skip_count_tracking !== false;
	self.minimum_skip_length = config.minimum_skip_length ?? 1;
	self.sponsorblock_api_url = util.normalize_api_url(config.sponsorblock_api_url);
	self.num_devices = length(config.devices || []);
	self._view_queue=[];self._view_pending={};self._view_active=0;self._view_timer=null;

	// segment cache: 5 minutes for non-locked segments
	self._segment_cache = TtlCache(300 * 1000, max(32,min(64,self.num_devices)), 131072);
	self._segment_pending = {};
	self._segment_deadline_ms=13000;
	// whitelist cache: 1 hour
	self._whitelist_cache = TtlCache(3600 * 1000, 100);
	return self;
}

// Normalize a pairing code (strip dashes/spaces).
function normalize_pairing_code(code) {
	return replace('' + code, /[- ]/g, '');
}

function normalize_pair_response(data){
    let screen=data?.screen;
    if(type(screen)!='object' || type(screen.screenId)!='string' || !match(screen.screenId,/^[A-Za-z0-9_-]{8,128}$/))return null;
    let name=type(screen.name)=='string'?substr(util.trim(replace(screen.name,/[[:cntrl:]]/g,' ')),0,100):'';
    return {screen_id:screen.screenId,name:name||'YouTube on TV',lounge_token:type(screen.loungeToken)=='string' && length(screen.loungeToken)<=4096?screen.loungeToken:null};
}

// Pair with a code via the YouTube Lounge API. on_result(device|null).
function pair_with_code(code, on_result, on_error) {
	let normalized = normalize_pairing_code(code);
	if(!match(normalized,/^[0-9]{12}$/)){if(on_error)on_error('Invalid pairing code');else if(on_result)on_result(null);return;}
	let url = LOUNGE_API_BASE + '/pairing/get_screen';
	http.post_form({
		url: url,
		data: { pairing_code: normalized },timeout_ms:8000,max_body_bytes:65536,
		on_done: (data, status) => {
			if (status != 200 || !data) {
				if (on_result) on_result(null);
				return;
			}
			if(on_result)on_result(normalize_pair_response(data));
		},
		on_error: (err) => {
			if (on_error) on_error(err);
			else if (on_result) on_result(null);
		},
	});
}

// Refresh the lounge token for a screen_id. on_result(token|null).
function refresh_auth(screen_id, on_result, on_error) {
	let url = LOUNGE_API_BASE + '/pairing/get_lounge_token_batch';
	http.post_form({
		url: url,
		data: { screen_ids: screen_id },
		on_done: (data, status) => {
			if (status != 200 || type(data?.screens)!='array' || !length(data.screens)) {
				if (on_result) on_result(null);
				return;
			}
			let screen=filter(data.screens,(x)=>type(x)=='object' && x.screenId==screen_id)[0];
			if(!screen || type(screen.loungeToken)!='string' || !length(screen.loungeToken) || length(screen.loungeToken)>4096){if(on_result)on_result(null);return;}
			if (on_result)
				on_result({
					screen_id: screen.screenId,
					lounge_token: screen.loungeToken,
				});
		},
		on_error: (err) => {
			if (on_error) on_error(err);
			else if (on_result) on_result(null);
		},
	});
}

// Check screen availability. on_result(online:boolean).
function is_available(screen_id, lounge_token, on_result, on_error) {
	let url = LOUNGE_API_BASE + '/pairing/get_screen_availability';
	http.post_form({
		url: url,
		data: { lounge_token: lounge_token },
		on_done: (data, status) => {
            let online=status==200?util.availability_status(data,screen_id,lounge_token):null;
            if(online==null){if(on_error)on_error('Screen availability failed');else if(on_result)on_result(false);return;}
			if (on_result) on_result(online);
		},
		on_error: (err) => {
			if (on_error) on_error(err);
			else if (on_result) on_result(false);
		},
	});
}

export { watch_channel_id, ChannelResolver,
	SponsorBlockClient, TtlCache,
	normalize_pairing_code, normalize_pair_response, pair_with_code, refresh_auth, is_available,
	process_segments, segment_request_url, segment_seek_target, segment_bounded_end,
	VALID_CATEGORIES
};
