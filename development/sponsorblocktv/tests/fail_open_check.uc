'use strict';
import {YtLoungeApi} from './lib/lounge.uc';
import {DeviceListener} from './lib/runtime.uc';
import {SponsorBlockClient} from './lib/sponsorblock.uc';
let u=require('uloop');u.init();
function check(ok,msg){if(!ok)die(msg);}
function fixture(){
    let a=YtLoungeApi({screen_id:'fixture',lounge_token:'token'});
    a._sid='s';a._gsession='g';
    return a;
}
let a=fixture(),sent=[],callbacks=[],results=[];
a._send_command=(n,p,cb)=>{push(sent,n);push(callbacks,cb);};
a._command('getVolume',{},ok=>push(results,ok));
a._command('setPlaylist',{videoId:'abcdefghijk'},ok=>push(results,ok));
a._detaching=true;
a._command('pause',{},ok=>push(results,ok));
callbacks[0](true);
check(length(sent)==1 && length(results)==3,'shutdown blocks new and queued playback commands');
a.detach();
check(!a.connected() && !a.lounge_token && !length(a._command_queue),'detach clears session locally');
let b=fixture(),replayed=[];
b._send_command=(n,p,cb)=>{push(replayed,n);cb(true);};
b._process_event('loungeScreenDisconnected',[{reason:'disconnectedByUserScreenInitiated'}]);
check(!b.connected(),'screen disconnect clears local session');
b._sid='new';b._gsession='new';
b._process_event('onSubtitlesTrackChanged',[{videoId:'abcdefghijk'}]);
check(!length(replayed),'no automatic restart on reconnect');
let cfg={devices:[],skip_categories:[]};
let l=DeviceListener(SponsorBlockClient(cfg),cfg,{screen_id:'fixture',name:'TV'},false);
let c=l.lounge,done=0,restored=0;
c._sid='s';c._gsession='g';c._ad_mute_owned=true;
c.mute=(mute,override,cb)=>{check(!mute && override,'restore owned mute only');restored++;cb(true);};
l.cancel(()=>done++);
check(done==1 && restored==1 && !c.connected() && !c._ad_mute_owned,'restore owned mute then detach');
l.cancel(()=>done++);
check(done==2 && restored==1,'repeated cancellation is harmless');
print('PASS: fail-open detach, queue cancellation, no playback restart, owned mute restore\n');
