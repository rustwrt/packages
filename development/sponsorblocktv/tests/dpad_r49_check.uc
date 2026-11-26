'use strict';
import {YtLoungeApi} from './lib/lounge.uc';
import {command} from './lib/live.uc';
import {SponsorBlockClient} from './lib/sponsorblock.uc';
import * as util from './lib/util.uc';
let u=require('uloop');u.init();
function check(ok,msg){if(!ok)die(msg);}
let a=YtLoungeApi({screen_id:'fixture',lounge_token:'token'});
a._sid='s';a._gsession='g';a._subscribe_active=true;
let l={phase:'connected',lounge:a,api_helper:SponsorBlockClient({devices:[]}),_time_start:util.monotonic_ms()};
a.on_state_change=(st)=>{l._current_state={...st};l._time_start=util.monotonic_ms();};
a._process_event('nowPlaying',[{videoId:'abcdefghijk',state:1,currentTime:15,duration:100}]);
let sent=[],guard,cb;
a._command=(n,p,done,err,g)=>{push(sent,[n,p]);guard=g;cb=done;};
for(let key in ['UP','DOWN','LEFT','RIGHT','ENTER','BACK']){
    check(command(l,'dpad',0,key).accepted,'valid key accepted');
    check(guard(),'guard permits connected key');cb(true);
    check(l.command_status=='delivered' && !l.command_pending,'delivery distinguished from confirmation');
    check(sent[-1][0]=='dpadCommand' && sent[-1][1].key==key,'wire command matches reference');
}
check(!command(l,'dpad',0,'HOME').accepted,'unsupported system key rejected');
check(!command(l,'dpad',1,'UP').accepted,'invalid value rejected');
check(command(l,'dpad',0,'UP').accepted,'key queued');
cb(true);check(l.command_status=='failed','undispatched key rejected');
l._seek_pending=true;check(!command(l,'dpad',0,'DOWN').accepted,'auto seek conflict rejected');
l._seek_pending=false;
check(command(l,'dpad',0,'BACK').accepted && guard(),'key dispatched');
cb(false);check(l.command_status=='failed','network failure reported');
print('Six D-pad keys, delivery semantics and stale guards OK\n');
