'use strict';
import {DeviceListener} from './lib/runtime.uc';
import {SponsorBlockClient} from './lib/sponsorblock.uc';
import {YtLoungeApi} from './lib/lounge.uc';
import {snapshot} from './lib/live.uc';
import * as util from './lib/util.uc';
let u=require('uloop');u.init();
function check(ok,msg){if(!ok)die(msg);}
let cfg={devices:[],skip_categories:['sponsor'],skip_ads:false,mute_ads:false};
let l=DeviceListener(SponsorBlockClient(cfg),cfg,{screen_id:'fixture',name:'TV'},false),a=l.lounge;
a._sid='s';a._gsession='g';a._subscribe_active=true;l.phase='connected';
a._send_command=(n,p,cb)=>cb(true);
l.api_helper._segment_cache.set('abcdefghijk',[],false);
a._process_event('nowPlaying',[{videoId:'abcdefghijk',state:1,currentTime:20,duration:100}]);
l._time_start=util.monotonic_ms()-6000;
let before=snapshot(l).position,stamp=l._time_start,rev=l._state_revision;
for(let policy in [['minimum_skip_length','2'],['skip_categories','intro'],['skip_sponsorblock','0'],['skip_sponsorblock','1'],['controller_mode','passive'],['controller_mode','cooperative']]){
    l.apply_policy(policy[0],policy[1]);
    check(snapshot(l).position>=before && l._time_start==stamp && l._state_revision==rev,'policy must not create playback sample: '+policy[0]);
}
l.cancel();
function ad_case(position,duration,explicit,expected){
    let b=YtLoungeApi({screen_id:'fixture',lounge_token:'token'});
    b._sid='s';b._gsession='g';
    b._send_command=(n,p,cb)=>cb(true);
    b._process_event('adPlaying',[{adVideoId:'ad1',currentTime:position,duration:duration,isSkipEnabled:true}]);
    let result=null,stats=0;
    b.on_stat=(kind,seconds)=>{if(kind=='ad_skips')stats++;};
    check(b.skip_ad(ok=>result=ok),'manual skip dispatched');
    if(explicit)b._process_event('onAdStateChange',[{adState:1082}]);
    else b._process_event('adPlaying',[{adVideoId:'ad2',currentTime:0,duration:10,isSkipEnabled:false}]);
    check(result===expected && stats==(expected?1:0),'manual result and stats must agree');
    b.detach();
}
ad_case(10,10,false,false);
ad_case(10,null,false,false);
ad_case(5,30,false,true);
ad_case(10,10,true,true);
function shutdown_case(manual,override,owned,expected){
    let c=DeviceListener(SponsorBlockClient(cfg),cfg,{screen_id:'fixture2',name:'TV'},false),d=c.lounge;
    d._sid='s';d._gsession='g';d._ad_mute_owned=owned;d._manual_mute_pending=manual;d.ad.manual_mute_override=override;
    d.volume_state={muted:'true',volume:40};
    let restore=0,done=0;
    d.mute=(mute,force,cb,guard)=>{check(!mute && force && guard(),'owned restoration guard');restore++;cb(true);};
    c.cancel(()=>done++);
    check(restore==expected && done==1 && !d.connected(),'shutdown respects mute ownership');
}
shutdown_case(true,false,true,0);
shutdown_case(false,true,true,0);
shutdown_case(false,false,false,0);
shutdown_case(false,false,true,1);
print('PASS: policy preserves playback clock, ad completion evidence, shutdown mute arbitration\n');
