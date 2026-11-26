'use strict';
import {valid_policy_value,initial_policy,VALID_CATEGORIES,NEW_TV_POLICY,build_config,parse_uci_show} from './lib/config.uc';
import {SponsorBlockClient,process_segments,segment_seek_target,segment_bounded_end} from './lib/sponsorblock.uc';
import {DeviceListener} from './lib/runtime.uc';
import {snapshot} from './lib/live.uc';
import * as util from './lib/util.uc';
function check(ok,msg){if(!ok)die(msg);}
let cfg={devices:[],skip_categories:['sponsor','intro']};
let h=SponsorBlockClient(cfg);
check(initial_policy(cfg,{}).skip_categories=='sponsor,intro','category defaults');
check(length(VALID_CATEGORIES)==10 && NEW_TV_POLICY.skip_categories==join(',',VALID_CATEGORIES),'new TV defaults enable all ten categories');
check(valid_policy_value('skip_categories',NEW_TV_POLICY.skip_categories,false),'all categories valid');
check(initial_policy({},{}).skip_categories==NEW_TV_POLICY.skip_categories,'missing seed uses all categories');
check(initial_policy(cfg,{skip_categories:[]}).skip_categories=='none','explicit disabled categories preserved');
check(initial_policy(cfg,{skip_categories:['sponsor']}).skip_categories=='sponsor','explicit prior selection preserved');

check(valid_policy_value('skip_categories','sponsor,intro',false),'valid category selection');
check(!valid_policy_value('skip_categories','sponsor,sponsor',false),'duplicate rejected');
check(!valid_policy_value('skip_categories','sponsor:mute',false),'invalid category rejected');
let l=DeviceListener(h,cfg,{screen_id:'fixture',name:'TV',statistics:true,skip_categories:['sponsor']},false);
check(join(',',l.api_helper.skip_categories)=='sponsor','category filtering');
let r=process_segments({segments:[
 {segment:[10,20],UUID:'a',category:'sponsor',actionType:'skip'},
 {segment:[15,30],UUID:'b',category:'intro',actionType:'skip'},
 {segment:[30,40],UUID:'c',category:'outro',actionType:'skip'}
]},0,l.api_helper.skip_categories);
check(length(r[0])==1 && r[0][0].end==20,'unselected category disabled');
let end=null;l._schedule_skip=(d,e)=>end=e;
l._current_state={duration:100};l._time_start=util.monotonic_ms();
l._time_to_segment(r[0],21);
check(end==null,'unselected category cannot schedule');
l._time_to_segment(r[0],12);check(end==20,'auto still schedules');
check(initial_policy(cfg,{}).statistics=='0','statistics off by default');
l.apply_policy('statistics','0');l.record_segment_skip(9);l.record_stat('ad_skips',8);
check(snapshot(l).segment_stats==null && l.segment_stats.skips==0,'off stops collection');
l.apply_policy('statistics','1');
l.record_segment_skip(8);l.record_segment_skip(2.5);l.record_segment_skip(-1);
l.record_stat('ad_skips',14.75);l.record_stat('ad_mutes',0);
check(snapshot(l).segment_stats.total_seconds==25 && snapshot(l).segment_stats.ad_skips==1 && snapshot(l).segment_stats.ad_mutes==1,'combined time without mute time');
l.apply_policy('statistics','0');l.record_stat('ad_skips',40);l.apply_policy('statistics','1');
check(snapshot(l).segment_stats.ad_skips==1,'disable preserves existing totals');
check(snapshot(l).segment_stats.skips==2 && snapshot(l).segment_stats.seconds==10,'session statistics while offline');
check(segment_seek_target(100,{duration:100})==99.75,'terminal VOD natural finish');
check(segment_bounded_end(100.241,{duration:100})==100 && segment_seek_target(100.241,{duration:100})==99.75,'rounded terminal segment accepted');
check(segment_bounded_end(102,{duration:100})==null,'large overhang rejected');
check(segment_bounded_end(252.241,{duration:252.1,seekableStart:0.001,seekableEnd:252})==252 && segment_seek_target(252.241,{duration:252.1,seekableStart:0.001,seekableEnd:252})==251.75,'fractional TV bounds');
check(segment_bounded_end(100.2,{duration:100,seekableStart:10,seekableEnd:100})==null,'DVR overhang rejected');

check(segment_seek_target(99,{duration:100})==99,'ordinary segment unchanged');
check(segment_seek_target(100,{duration:100,seekableStart:10,seekableEnd:100})==100,'DVR bounds unchanged');
end=null;l._time_start=util.monotonic_ms();
l._time_to_segment([{start:90,end:100,UUID:['end']}],99.8);
check(end==null,'do not repeatedly seek back from terminal tail');
print('PASS: category policy migration, validation, manual isolation, session statistics\n');
