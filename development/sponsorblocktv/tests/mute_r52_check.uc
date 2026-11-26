'use strict';
import {YtLoungeApi} from './lib/lounge.uc';
import {command,snapshot} from './lib/live.uc';
let u=require('uloop');u.init();
function check(ok,msg){if(!ok)die(msg);}
let a=YtLoungeApi({screen_id:'fixture',lounge_token:'token',mute_ads:true});
a._sid='sid';a._gsession='gs';a._subscribe_active=true;
let l={phase:'connected',lounge:a};
a.on_state_change=(st)=>{l._current_state={...st};};
a._process_event('nowPlaying',[{videoId:'abcdefghijk',state:1,currentTime:10,duration:100}]);
let calls=[],guard,callback,args;
a._command=(n,p,cb,err,g)=>{
    push(calls,n);
    if(n=='setVolume'){args=p;guard=g;callback=cb;}
};
check(!snapshot(l).mute_known && !command(l,'mute',1,'').accepted,'unknown mute state not guessed');
a._process_event('onVolumeChanged',[{volume:45,muted:false}]);
check(snapshot(l).mute_known && command(l,'mute',1,'').accepted,'manual mute accepted');
a._process_event('onVolumeChanged',[{volume:47,muted:false}]);
check(guard() && args.volume==47 && args.muted=='true','dispatch preserves current volume');
check(!snapshot(l).muted && l.command_pending,'no optimistic mute state');
a._process_event('onVolumeChanged',[{volume:47,muted:true}]);callback(true);
check(l.command_status=='sent' && snapshot(l).muted && !a._manual_mute_pending,'confirmed mute');
check(command(l,'mute',0,'').accepted && guard() && args.muted=='false','unmute request');
a._process_event('onVolumeChanged',[{volume:47,muted:false}]);callback(true);
check(l.command_status=='sent' && !snapshot(l).muted && snapshot(l).volume==47,'confirmed unmute preserves volume');
a._process_event('adPlaying',[{adVideoId:'ad1',currentTime:1,isSkipEnabled:false}]);
check(a._ad_mute_pending && !command(l,'mute',0,'').accepted,'automatic mute conflict rejected');
check(guard(),'automatic mute dispatch');
a._process_event('onVolumeChanged',[{volume:47,muted:true}]);callback(true);
check(a._ad_mute_owned && !a._ad_mute_pending,'automatic mute confirmed');
check(command(l,'mute',0,'').accepted && guard(),'manual unmute during ad');
a._process_event('onVolumeChanged',[{volume:47,muted:false}]);callback(true);
let n=length(calls);
a._process_event('adPlaying',[{adVideoId:'ad1',currentTime:3,isSkipEnabled:false}]);
check(!snapshot(l).muted && a.ad.manual_mute_override && length(calls)==n,'manual override lasts for current ad');
a._process_event('adPlaying',[{adVideoId:'ad2',currentTime:1,isSkipEnabled:false}]);
check(a._ad_mute_pending && !a.ad.manual_mute_override,'next ad restores automatic policy');
print('Confirmed mute/unmute, current volume, unknown state and automatic mute arbitration OK\n');
