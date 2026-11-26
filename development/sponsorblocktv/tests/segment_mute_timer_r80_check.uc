'use strict';
import {DeviceListener} from './lib/runtime.uc';
import {SponsorBlockClient} from './lib/sponsorblock.uc';
let u=require('uloop');u.init();
function check(ok,msg){if(!ok)die(msg);}
let id='abcdefghijk',cfg={devices:[],skip_categories:['sponsor']};
let l=DeviceListener(SponsorBlockClient(cfg),cfg,{screen_id:'fixture',name:'TV'},false),a=l.lounge;
l.metadata_id=id;a._sid='s';a._gsession='g';a._subscribe_active=true;l.phase='connected';
l.api_helper._segment_cache.set(id,[],false);
let calls=[];a._send_command=(n,p,cb)=>push(calls,n);
a._process_event('onVolumeChanged',[{volume:40,muted:false}]);
a._process_event('nowPlaying',[{videoId:id,state:1,currentTime:9.9,duration:100}]);
u.timer(1400,()=>{check(!length(calls) && a.volume_state.muted=='false','no scheduled mute without segments');a._connection_lost();print('PASS: no segment mute timer\n');u.end();});
u.run();
