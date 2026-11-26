'use strict';
import * as util from './lib/util.uc';
import {YtLoungeApi} from './lib/lounge.uc';
import {command,snapshot} from './lib/live.uc';
let u=require('uloop');u.init();
function check(ok,msg){if(!ok)die(msg);}
let n=0, handle;
handle=util.repeat_timer(u,5,()=>{
    n++;
    if(n==3){handle.cancel();handle.cancel();handle=null;}
});
let a=YtLoungeApi({screen_id:'fixture',lounge_token:'token'});
a._sid='s';a._gsession='g';a._subscribe_active=true;
let l={phase:'connected',lounge:a};
a.on_state_change=(state)=>{l._current_state={...state};l._time_start=util.monotonic_ms();};
a._process_event('nowPlaying',[{videoId:'abcdefghijk',state:1,currentTime:5,duration:60}]);
let cb=null;
a._send_command=(n,p,done)=>{cb=done;};
check(command(l,'pause',0,'').accepted,'pause accepted');
a._process_event('onStateChange',[{state:2,currentTime:5}]);
check(l.command_pending,'state event before HTTP still preserves transport ordering');
u.timer(50,()=>{
    check(n==3,'self cancel stops recurring timeout');
    cb(true);
    let s=snapshot(l);
    check(s.command_status=='sent' && s.command_timing.action=='pause' && s.command_timing.observed_ms<=s.command_timing.http_ms && s.command_timing.total_ms>=s.command_timing.http_ms,'measured early observation and HTTP separately');
    check(a._command_verify==null,'verifier cleared');
    a._connection_lost();
    print('Periodic timeout self-cancel and command phase timings OK\n');
    u.end();
});
u.run();
