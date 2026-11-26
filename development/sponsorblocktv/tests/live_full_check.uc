'use strict';
import { YtLoungeApi } from './lib/lounge.uc';
import { snapshot, command } from './lib/live.uc';
import { SponsorBlockClient } from './lib/sponsorblock.uc';
import * as util from './lib/util.uc';
let uloop=require('uloop');
uloop.init();
function check(ok,msg){ if(!ok) die(msg); }
let a=YtLoungeApi({screen_id:'fixture',lounge_token:'token',auto_play:true,skip_ads:false,mute_ads:false});
a._sid='sid'; a._gsession='gs'; a._subscribe_active=true;
let c=SponsorBlockClient({skip_categories:['sponsor'],skip_count_tracking:false,devices:[]});
let l={phase:'connected',lounge:a,public_id:'fixture',api_helper:c,_time_start:util.monotonic_ms(),_current_state:{videoId:'abcdefghijk',state:1,currentTime:15,duration:100,seekableStart:10,seekableEnd:90}};
let calls=[];
a._command=(name,args,cb,err,guard)=>{
    if(guard && !guard()){if(cb)cb(false);return;}
    push(calls,[name,args]);
    if(name=='seekTo'){l._current_state.currentTime=args.newTime;a._process_event('nowPlaying',[{videoId:l._current_state.videoId,currentTime:args.newTime,state:1}]);}
    if(name=='setAutoplayMode') a._process_event('onAutoplayModeChanged',[{autoplayMode:args.autoplayMode}]);
    if(name=='addVideo') push(a.queue,args.videoId);
    if(name=='insertVideo') splice(a.queue,1,0,args.videoId);
    if(name=='removeVideo') splice(a.queue,index(a.queue,args.videoId),1);
    if(name=='setPlaylist' && args.videoIds) a.queue=split(args.videoIds,',');
    else if(name=='setPlaylist'){l._current_state.videoId=args.videoId;a._process_event('nowPlaying',[{videoId:args.videoId,state:1,currentTime:0}]);}
    if(index(['addVideo','insertVideo','removeVideo'],name)>=0 || (name=='setPlaylist' && args.videoIds))a._process_event('playlistModified',[{videoIds:join(',',a.queue)}]);
    if(cb) cb(true);
};
a._process_event('nowPlaying',[{state:'1',videoId:'abcdefghijk',currentTime:15,duration:100}]);
a._process_event('playlistModified',[{videoIds:'abcdefghijk,lmnopqrstuv,01234567890'}]);
a._process_event('onPlaybackSpeedChanged',[{playbackSpeed:'1'}]);
a._process_event('onAutoplayModeChanged',[{autoplayMode:'ENABLED'}]);
c._segment_cache.set('abcdefghijk',[{start:10,end:20,UUID:['fixture']}],false);
check(length(snapshot(l).segments)==1,'SponsorBlock markers');
function run(action,value,text,expected){
    let n=length(calls);
    check(command(l,action,value,text).accepted,'accepted '+action);
    check(l.command_status=='sent','confirmed '+action);
    check(calls[n][0]==expected,'command '+action);
}
run('back10',0,'','seekTo');check(l._current_state.currentTime==10,'DVR lower bound');
run('forward10',0,'','seekTo');check(l._current_state.currentTime==20,'forward seek');
l._current_state.currentTime=15;run('skip_segment',0,'','seekTo');
check(!command(l,'speed',150,'').accepted,'removed speed RPC rejected');
check(!command(l,'captions',0,'vi').accepted,'removed caption RPC rejected');
check(!command(l,'autoplay',0,'').accepted && a.auto_play,'legacy autoplay cannot override saved policy');
run('queue_add',0,'abcdefghij1','addVideo');run('queue_next',0,'abcdefghij2','insertVideo');
run('queue_move',1,'abcdefghij2','setPlaylist');run('queue_remove',0,'abcdefghij1','removeVideo');
check(!command(l,'play_video',0,'bad').accepted,'invalid id rejected');
check(!command(l,'seek',99,'').accepted,'DVR upper bound');
a._process_event('adPlaying',[{isSkipEnabled:false}]);check(!command(l,'next',0,'').accepted,'no control conflict during ad');
a._process_event('onAdStateChange',[{adState:'1082'}]);
run('play_video',0,'abcdefghij3','setPlaylist');
print('Full live controls: DVR, segments, speed, autoplay, queue, validation and confirmation OK\n');
