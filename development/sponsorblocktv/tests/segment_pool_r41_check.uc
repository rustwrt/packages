'use strict';
import {SponsorBlockClient} from './lib/sponsorblock.uc';
import {validate_runtime_config} from './lib/config.uc';
let u=require('uloop');u.init();
function check(ok,msg){if(!ok)die(msg);}
let devices=[];for(let i=0;i<64;i++)push(devices,{screen_id:'fixture'+i});
let c=SponsorBlockClient({devices:devices});
check(c._segment_cache.maxsize==64 && c.skip_categories[0]=='sponsor','cache sized for configured TVs and default category');
let ready,received=0,failed=0;
c.is_whitelisted=(id,cb)=>{ready=cb;};
for(let i=0;i<64;i++)c.get_segments('abcdefghijk',()=>received++,()=>failed++);
check(length(c._segment_pending.abcdefghijk)==64,'64 TVs share one pending request');
ready(true);ready(true);
check(received==64 && failed==0 && !length(keys(c._segment_pending)),'all 64 callbacks completed exactly once');
let d=SponsorBlockClient({devices:[]});
d._segment_deadline_ms=35;
let stale,errors=0;
d.is_whitelisted=(id,cb)=>{stale=cb;};
d.get_segments('abcdefghij1',()=>die('unexpected result'),(e)=>{check(e=='Segment request deadline exceeded','deadline message');errors++;});
u.timer(90,()=>{
    check(errors==1 && !length(keys(d._segment_pending)),'hung lookup releases slot');
    stale(true);check(d._segment_cache.get('abcdefghij1')==null,'late callback cannot populate cache');
    let next;
    d.is_whitelisted=(id,cb)=>{next=cb;};
    d.get_segments('abcdefghij1',()=>received++);
    next(true);check(received==65,'retry works after timeout');
    let rejected=false;
    try{validate_runtime_config({devices:devices,join_name:'bad\nname'},false);}catch(e){rejected=true;}
    check(rejected,'invalid join name rejected');
    print('64-TV fanout, segment deadline, stale callback isolation and configuration bounds OK\n');
    u.end();
});
u.run();
