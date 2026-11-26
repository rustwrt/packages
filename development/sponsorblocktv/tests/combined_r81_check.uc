'use strict';
import {DeviceListener} from './lib/runtime.uc';
import {SponsorBlockClient,process_segments,segment_request_url} from './lib/sponsorblock.uc';
import {valid_policy_value} from './lib/config.uc';
import {snapshot} from './lib/live.uc';
let u=require('uloop');u.init();
function check(ok,msg){if(!ok)die(msg);}
let id='abcdefghijk',cfg={devices:[],skip_categories:['sponsor']};
let l=DeviceListener(SponsorBlockClient(cfg),cfg,{screen_id:'fixture',name:'TV',statistics:true,skip_categories:['sponsor','intro']},false),a=l.lounge;
check(join(',',l.api_helper.skip_categories)=='sponsor,intro','enabled categories');
let parsed=process_segments({segments:[{segment:[10,20],UUID:'s',category:'sponsor',actionType:'skip'},{segment:[19,25],UUID:'m',category:'sponsor',actionType:'mute'}]},0,l.api_helper.skip_categories)[0];
check(length(parsed)==1 && parsed[0].end==20 && !parsed[0].mute,'native mute records ignored');
check(index(segment_request_url('https://sponsor.ajay.app/api/',id,['sponsor']),'actionType=mute')<0,'request skips only');
l.api_helper._segment_cache.set(id,parsed,false);l.metadata_id=id;
a._sid='s';a._gsession='g';a._subscribe_active=true;l.phase='connected';
let calls=[],done=[];
a._send_command=(n,p,cb)=>{push(calls,[n,{...p}]);push(done,cb);};
function pos(p){a._process_event('nowPlaying',[{videoId:id,state:1,currentTime:p,duration:100}]);}
a._process_event('onVolumeChanged',[{volume:40,muted:false}]);pos(12);
u.timer(100,()=>{
 check(length(calls)==1 && calls[0][0]=='seekTo' && calls[0][1].newTime==20,'automatic skip without mute');
 pos(20);done[0](true);
 check(l.segment_stats.skips==1 && a.volume_state.muted=='false','skip counted and audio unchanged');
 a._connection_lost();print('PASS: skip-only filtering, automatic skip and audio preservation\n');u.end();
});
u.run();
