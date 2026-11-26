'use strict';
import {DeviceListener} from './lib/runtime.uc';
import {SponsorBlockClient} from './lib/sponsorblock.uc';
import {YtLoungeApi} from './lib/lounge.uc';
import {command,snapshot} from './lib/live.uc';
import * as util from './lib/util.uc';
let u=require('uloop');u.init();
function check(ok,msg){if(!ok)die(msg);}
let cfg={devices:[],skip_categories:['sponsor']},id='abcdefghijk';
function fixture(){
    let l=DeviceListener(SponsorBlockClient(cfg),cfg,{screen_id:'fixture',name:'TV'},false),a=l.lounge;
    a._sid='s';a._gsession='g';a._subscribe_active=true;l.phase='connected';l.metadata_id=id;
    l.api_helper._segment_cache.set(id,[{start:10,end:30,UUID:['fixture']}],false);
    a._process_event('loungeStatus',[{devices:[{type:'LOUNGE_SCREEN',id:'tv'},{type:'REMOTE_CONTROL',id:a.device_id},{type:'REMOTE_CONTROL',id:'phone'}]}]);
    a._process_event('nowPlaying',[{videoId:id,state:1,currentTime:15,duration:100}]);
    return l;
}
let l=fixture(),a=l.lounge,sent=[],callbacks=[];
a._send_command=(n,p,cb)=>{push(sent,n);push(callbacks,cb);};
a._command('getVolume');
u.timer(60,()=>{
    check(l._seek_pending && !l._seek_dispatched,'auto seek queued');
    let old=l._seek_generation;
    l.apply_policy('skip_sponsorblock','0');l.apply_policy('skip_sponsorblock','1');
    check(l._seek_generation>old && !l._seek_pending,'policy invalidates queued seek even after re-enable');
    check(command(l,'pause',0,'').accepted,'manual pause accepted');
    callbacks[0](true);
    check(index(sent,'seekTo')<0 && index(sent,'pause')>=0,'stale seek never dispatched');
    l.cancel();
    let m=fixture(),b=m.lounge,dispatch=[];
    b._send_command=(n,p,cb)=>{push(dispatch,n);};
    b._command('getVolume');
    u.timer(60,()=>{
        check(m._seek_pending && !m._seek_dispatched,'second auto seek queued');
        check(command(m,'pause',0,'').accepted && !m._seek_pending,'manual command preempts queued auto seek');
        m.cancel();
        let c=YtLoungeApi({screen_id:'fixture',controller_mode:'cooperative',mute_ads:true});
        c._sid='s';c._gsession='g';
        c._process_event('loungeStatus',[{devices:[{type:'LOUNGE_SCREEN',id:'tv'},{type:'REMOTE_CONTROL',id:c.device_id}]}]);
        check(!c.shared_control(),'fresh sole controller');
        c.controller_observed_ms=util.monotonic_ms()-121000;
        check(c.shared_control(),'stale roster treated conservatively');
        c._ad_mute_owned=true;c._ad_mute_pending=true;c.volume_state.muted='false';
        c._connection_lost();check(!c._ad_mute_owned,'unconfirmed mute cannot claim ownership after reconnect');
        c._sid='s';c._gsession='g';c._ad_mute_owned=true;c.volume_state.muted='true';
        c._connection_lost();check(c._ad_mute_owned,'confirmed ownership retained within process');
        c._sid='s';c._gsession='g';c._process_event('onVolumeChanged',[{muted:false,volume:40}]);
        check(!c._ad_mute_owned,'fresh unmute invalidates ownership');
        print('PASS: stale auto seek, manual preemption, roster age and reconnect mute ownership\n');u.end();
    });
});
u.run();
