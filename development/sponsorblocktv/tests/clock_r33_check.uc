'use strict';
import {YtLoungeApi} from './lib/lounge.uc';
import {DeviceListener} from './lib/runtime.uc';
import {SponsorBlockClient} from './lib/sponsorblock.uc';
import {snapshot} from './lib/live.uc';
import * as util from './lib/util.uc';
let u=require('uloop');u.init();
function check(ok,msg){if(!ok)die(msg);}
let client=SponsorBlockClient({skip_categories:['sponsor'],skip_count_tracking:true,devices:[]});
let id='abcdefghijk';
client._segment_cache.set(id,[{start:10,end:20,UUID:['fixture']}],false);
let l=DeviceListener(client,{}, {screen_id:'fixture',name:'fixture',offset:0,skip_categories:['sponsor']},false);
l.metadata_id=id;l.video_title='Fixture';
let a=l.lounge;a._sid='s';a._gsession='g';a._subscribe_active=true;l.phase='connected';
let seeks=0,marked=0;
client.mark_viewed_segments=()=>marked++;
a._command=(n,p,cb)=>{if(cb)cb(true);};
a.seek_to=(pos,cb,guard)=>{
    check(guard(),'guard at dispatch');
    seeks++;
    // Screen state may arrive before the response to the seek.
    a._process_event('nowPlaying',[{videoId:id,state:1,currentTime:pos,duration:100}]);
    cb(true);
};
a._process_event('nowPlaying',[{videoId:id,state:1,currentTime:12,duration:100}]);
a._position_report_ms=util.monotonic_ms()-16000;
check(!l._can_auto_seek() && !snapshot(l).position_known,'stale playback blocks seek');
u.timer(80,()=>{
    check(seeks==0,'timer cannot seek stale screen');
    a._process_event('nowPlaying',[{videoId:id,state:1,currentTime:12,duration:100}]);
});
u.timer(350,()=>{
    check(seeks==1 && marked==1,'early screen confirmation accepted exactly once');
    a._process_event('nowPlaying',[{videoId:id,state:1,currentTime:40,duration:100}]);
    a._process_event('adPlaying',[{adVideoId:'ad',isSkipEnabled:false}]);
    a._playback_sample_ms=util.monotonic_ms()-30000;
    a._process_event('onAdStateChange',[{adState:'1082'}]);
    a._process_event('onStateChange',[{state:1}]);
    check(!snapshot(l).position_known && !l._can_auto_seek(),'ad end needs fresh content sample');
    a._process_event('nowPlaying',[{videoId:id,state:1,currentTime:40,duration:100}]);
    check(snapshot(l).position>=40 && snapshot(l).position<=41,'ad time not added');
    let callbacks=0;a.on_event=(e,args)=>{if(e=='autoplayUpNext')callbacks++;};
    a._process_event('autoplayUpNext',[{videoId:'lmnopqrstuv'}]);
    check(callbacks==1,'up next once');
    let b=SponsorBlockClient({skip_count_tracking:true,devices:[]}),jobs=[];
    b._send_view=(id,done)=>push(jobs,done);
    let ids=[];for(let i=0;i<200;i++)push(ids,'id'+i);
    b.mark_viewed_segments(ids);
    check(b._view_active==2 && length(b._view_queue)<=128 && length(jobs)==2,'view reporting bounded');
    jobs[0]();jobs[0]();
    check(b._view_active==1,'duplicate completion ignored');
    print('Freshness, ad clock, early seek confirmation, event dedup and reporting budget OK\n');
    u.end();
});
u.run();
