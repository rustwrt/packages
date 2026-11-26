'use strict';
import {YtLoungeApi} from './lib/lounge.uc';
import * as util from './lib/util.uc';
let u=require('uloop');u.init();
function check(ok,msg){if(!ok)die(msg);}
function api(opts){
    let a=YtLoungeApi({screen_id:'fixture',lounge_token:'token',...opts});
    a._sid='s';a._gsession='g';a._subscribe_active=true;return a;
}
let stats=[];let a=api({skip_ads:true,mute_ads:true,on_stat:(k,s)=>push(stats,[k,s])}),sent=[],done=[];
a._send_command=(n,p,cb)=>{push(sent,n);push(done,cb);};
a._process_event('onVolumeChanged',[{volume:40,muted:false}]);
a._process_event('adPlaying',[{adVideoId:'one',currentTime:5,duration:30,isSkipEnabled:true}]);
check(sent[0]=='skipAd' && a.ad.skip_dispatched_at!=null,'skip dispatched before mute');
check(length(sent)==1 && length(a._command_queue)==1,'single foreground request retained');
a._process_event('onAdStateChange',[{adState:1082}]);
done[0](true);
check(length(stats)==1 && stats[0][0]=='ad_skips' && stats[0][1]>24 && stats[0][1]<=25,'confirmed ad skip and conservative saved time');
a._process_event('onAdStateChange',[{adState:1082}]);
check(length(stats)==1,'duplicate ad end not counted');
check(index(sent,'setVolume')<0,'queued auto mute cannot touch resumed content');
a._connection_lost();
let b=api({skip_ads:true}),calls=[];
b._send_command=(n,p,cb)=>{push(calls,n);};
b._process_event('onAdStateChange',[{isSkipEnabled:true}]);
check(!b._ad_active && length(calls)==0,'partial unlock cannot invent an ad');
b._process_event('adPlaying',[{adVideoId:'two',currentTime:4,isSkippable:true,isSkipEnabled:false}]);
check(b._ad_unlock_window() && length(calls)==0 && b._ad_probe_timer!=null,'unlock window reserves foreground');
b._process_event('onAdStateChange',[{adVideoId:'old',isSkipEnabled:true}]);
check(!b.ad.can_skip && length(calls)==0,'foreign partial event rejected');
b._process_event('onAdStateChange',[{isSkipEnabled:true}]);
check(calls[0]=='skipAd' && b._ad_probe_timer==null,'partial unlock triggers immediate skip and cancels probe');
b._process_event('onAdStateChange',[{isSkipEnabled:true}]);
check(length(calls)==1,'duplicate unlock deduplicated');
b._connection_lost();
let c=api({skip_ads:true}),queries=[];
c._send_command=(n,p,cb)=>{push(queries,n);cb(true);};
c._process_event('adPlaying',[{adVideoId:'three',currentTime:5.1,duration:20,isSkippable:true,isSkipEnabled:false}]);
u.timer(300,()=>{
    check(length(queries)==1 && queries[0]=='getNowPlaying' && !c.ad.can_skip,'estimated threshold only queries status');
    c._process_event('onAdStateChange',[{adState:1081,currentTime:5.5,isSkipEnabled:false}]);
    check(c._ad_probe_timer==null,'one probe per advertisement');
    c._process_event('onAdStateChange',[{adState:1081,currentTime:5.6,isSkipEnabled:true}]);
    check(queries[1]=='skipAd','confirmed skip after probe');
    c._connection_lost();
    print('Immediate unlock dispatch, mute priority, bounded refresh and stale guards OK\n');
    u.end();
});
u.run();
