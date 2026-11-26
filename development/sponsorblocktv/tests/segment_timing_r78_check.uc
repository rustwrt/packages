'use strict';
import {DeviceListener} from './lib/runtime.uc';
import {SponsorBlockClient,segment_request_url} from './lib/sponsorblock.uc';
import * as util from './lib/util.uc';
let u=require('uloop');u.init();
function check(ok,msg){if(!ok)die(msg);}
let id='abcdefghijk',cfg={skip_categories:['sponsor'],devices:[]};
let h=SponsorBlockClient(cfg);
let hash=util.sha256_hex(id);
check(index(segment_request_url('https://sponsor.ajay.app/api/',id,['sponsor']),'/skipSegments/'+substr(hash,0,5)+'?')>=0,'official five character prefix');
check(index(segment_request_url('https://example.test/api/',id,['sponsor']),'/skipSegments/'+substr(hash,0,4)+'?')>=0,'custom server compatibility');
h._segment_cache.set(id,[{start:10,end:20,UUID:['a']},{start:30,end:40,UUID:['b']},{start:50,end:60,UUID:['c']}],false);
let l=DeviceListener(h,cfg,{screen_id:'fixture',name:'TV',offset:0},false),a=l.lounge;
a._sid='s';a._gsession='g';a._subscribe_active=true;l.phase='connected';l.metadata_id=id;
let sent=[],completions=[],marks=0,reads=0;
h.mark_viewed_segments=()=>marks++;
a.get_now_playing=(cb,guard)=>{if(!guard || guard())reads++;if(cb)cb(true);};
a.seek_to=(pos,cb,guard)=>{check(guard(),'dispatch guard');push(sent,pos);push(completions,cb);};
function position(p){a._process_event('nowPlaying',[{videoId:id,state:1,currentTime:p,duration:100}]);}
position(12);
u.timer(60,()=>{
 check(length(sent)==1 && l._seek_pending,'first seek dispatched');
 position(20);check(marks==1 && !l._seek_pending && reads==0,'screen confirmation before HTTP; no poll');
 completions[0](true);check(marks==1,'HTTP completion no duplicate');
 position(32);
});
u.timer(150,()=>{
 check(length(sent)==2,'second seek');
 completions[1](true);
 check(marks==1 && reads==0 && l._seek_pending,'HTTP ack alone not confirmation');
 position(40);check(marks==2 && !l._seek_pending,'second confirmed');
 position(52);
});
u.timer(260,()=>{
 check(length(sent)==3,'third seek');
 position(60);completions[2](true);
 check(marks==3 && length(l._seek_latency_samples)==3 && l._seek_lead()>=0 && l._seek_lead()<=0.15,'bounded learning');
 l._seek_latency_samples=[800,900,1000];
 check(l._seek_lead()==0.15,'adaptive lead cap');
 l.offset=-0.25;check(l._seek_lead()==-0.25,'manual negative offset preserved');
 l.offset=0;
 h._segment_cache.set(id,[{start:70,end:80,UUID:['d']}],false);
 position(72);
});
u.timer(330,()=>{
 check(length(sent)==4 && l._seek_pending,'fourth seek pending');
 a._process_event('adPlaying',[{adVideoId:'ad',isSkipEnabled:false}]);
 check(!l._seek_pending && l._seek_verify==null,'ad invalidates verification');
 completions[3](true);check(marks==3,'stale completion ignored');
 a._connection_lost();
});
u.timer(700,()=>{
 check(reads==0,'no delayed redundant polls after confirmation or cancellation');
 print('PASS: five-character hash, event-first confirmation, bounded adaptive lead and ad isolation\n');u.end();
});
u.run();
