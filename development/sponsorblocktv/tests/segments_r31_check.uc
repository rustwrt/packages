'use strict';
import { process_segments, TtlCache, SponsorBlockClient } from './lib/sponsorblock.uc';
import { DeviceListener } from './lib/runtime.uc';
import * as util from './lib/util.uc';
let uloop=require('uloop');
uloop.init();
function check(ok,msg){if(!ok)die(msg);}
let raw={segments:[
    {segment:[20,25],UUID:'c',locked:1,category:'sponsor',actionType:'skip'},
    {segment:[10,18],UUID:'a',locked:1,category:'sponsor',actionType:'skip'},
    {segment:[15,19],UUID:'b',locked:1,category:'sponsor',actionType:'skip'},
    {segment:[25.5,30],UUID:'d',locked:0,category:'sponsor',actionType:'skip'},
    {segment:[1,5],UUID:'e',locked:0,category:'intro',actionType:'skip'},
    {segment:[30,50],UUID:'f',locked:1,category:'sponsor',actionType:'poi'}
]};
let out=process_segments(raw,0,['sponsor']);
check(!out[2] && !out[1] && length(out[0])==3,'category/action filtering and gaps preserved');
check(out[0][0].start==10 && out[0][0].end==19 && length(out[0][0].UUID)==2,'overlap union');
check(out[0][2].start==25.5 && raw.segments[1].segment[1]==18,'input unchanged');
for(let bad in [{segment:[-1,2],UUID:'x'},{segment:[1,0],UUID:'x'},{segment:['1',2],UUID:'x'},{segment:null},{segment:[1,2],UUID:null}])
    check(process_segments({segments:[bad]},0)[2],'invalid input flagged');
let many=[];
for(let i=0;i<1025;i++)push(many,{segment:[i,i+1],UUID:'a'});
check(process_segments({segments:many},0)[2],'oversized response rejected');
let cache=TtlCache(10000,3,100);
cache.set('a','1234567890123456789012345678901234567890',false);
cache.set('b','1234567890123456789012345678901234567890',false);
cache.set('c','1234567890123456789012345678901234567890',false);
check(cache.bytes<=100 && cache.get('a')==null && cache.get('c')!=null,'byte budget eviction');
let h=SponsorBlockClient({skip_categories:['sponsor'],devices:[]});
let l=DeviceListener(h,{}, {screen_id:'fixture',name:'fixture',offset:0},false);
let scheduled=null;
l._schedule_skip=(d,e)=>{scheduled=e;};
l._current_state={duration:100,seekableStart:10,seekableEnd:90};
l._time_start=util.monotonic_ms();
l._time_to_segment([{start:2,end:8,UUID:['a']},{start:80,end:95,UUID:['b']}],5);
check(scheduled==null,'DVR bounds reject invalid targets');
l._time_to_segment([{start:20,end:30,UUID:['c']}],15);
check(scheduled==30,'DVR valid seek');
print('Segment validation, exact overlap union, bounded cache and DVR checks OK\n');
