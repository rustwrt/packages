'use strict';
import {DeviceListener} from './lib/runtime.uc';
import {SponsorBlockClient} from './lib/sponsorblock.uc';
import {read_stats,save_stats} from './lib/config.uc';
import {snapshot} from './lib/live.uc';
import * as fs from 'fs';
let u=require('uloop');u.init();
function check(ok,msg){if(!ok)die(msg);}
let dir=getenv('SB_TEST_STATS_DIR');
if(!dir){print('SKIP: native root-owned temporary statistics directory required\n');exit(0);}
let cfg={devices:[],skip_categories:['sponsor']},dev={screen_id:'fixture',name:'TV',statistics:true};
function listener(){let l=DeviceListener(SponsorBlockClient(cfg),cfg,dev,false);l.enable_stats_store(dir);return l;}
let a=listener();
check(a._stats_dir==dir && snapshot(a).lifetime_stats.skips==0,'empty counter');
a.record_segment_skip(5.25);a.record_segment_skip(10.75);a.record_segment_skip(-1);a.record_stat('ad_skips',12.5);a.record_stat('ad_mutes',0);
check(a._stats_timer && a._stats_dirty,'batched flush');
a.flush_segment_stats();
check(!a._stats_dirty && read_stats(dir,a.public_id).milliseconds==16000,'atomic persisted counters');
let path=dir+'/tv-stats-'+a.public_id+'.json';
check((fs.lstat(path).mode&63)==0,'private stats file');
let b=listener();
check(snapshot(b).lifetime_stats.skips==2 && snapshot(b).lifetime_stats.seconds==16 && snapshot(b).segment_stats.skips==0 && snapshot(b).lifetime_stats.total_seconds==28 && snapshot(b).lifetime_stats.ad_skips==1 && snapshot(b).lifetime_stats.ad_mutes==1,'restart loads total but not session');
b.record_segment_skip(2);
b.lounge.disconnect=cb=>cb(true);
b.cancel(()=>{});
check(read_stats(dir,b.public_id).skips==3 && read_stats(dir,b.public_id).milliseconds==18000,'shutdown flush');
let rejected=false;try{save_stats(dir,b.public_id,{skips:-1,milliseconds:3});}catch(e){rejected=true;}
check(rejected && read_stats(dir,b.public_id).skips==3,'invalid counters cannot replace file');
a._stats_timer.cancel();
print('PASS: root-only atomic totals, batched writes, restart and shutdown flush\n');
