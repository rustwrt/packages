'use strict';
import {TtlCache} from './lib/sponsorblock.uc';
import {build_config,parse_uci_show,validate_runtime_config} from './lib/config.uc';
import * as util from './lib/util.uc';
function check(v,m){if(!v)die(m);}
function rejects(fn){try{fn();return false;}catch(e){return true;}}
let c=TtlCache(1000,2,100);
c.set('a','old',false);check(c.set('a',join('',map([1,2,3,4,5,6,7,8,9,10],()=> '01234567890')),false)==false && c.get('a')==null && c.bytes==0,'oversize replacement invalidates stale value');
c.set('a','active',false);c.set('b','old',false);c.entries.b.expires_at=util.monotonic_ms()-1;
c.set('c','new',false);check(c.get('a')=='active' && c.get('b')==null && c.get('c')=='new','expired entries pruned first');
c.get('a');c.set('d','fourth',false);check(c.get('a')=='active' && c.get('c')==null && c.bytes>0,'LRU keeps active entry');
let prefix="sponsorblocktv.main=sponsorblocktv\nsponsorblocktv.@device[0]=device\nsponsorblocktv.@device[0].screen_id='valid-screen'\n";
for(let v in ['999999999','-10001','1.5','garbage'])check(rejects(()=>build_config(parse_uci_show(prefix+"sponsorblocktv.@device[0].offset='"+v+"'\n"))),'invalid offset rejected');
let cfg=build_config(parse_uci_show(prefix+"sponsorblocktv.@device[0].offset='-10000'\n"));
check(validate_runtime_config(cfg,false) && cfg.devices[0].offset==-10000,'valid boundary');
check(rejects(()=>validate_runtime_config({devices:[null]},false)),'null device rejected');
check(rejects(()=>validate_runtime_config({devices:[{screen_id:'valid-screen'},{screen_id:'valid-screen'}]},false)),'duplicate JSON device rejected');
check(rejects(()=>validate_runtime_config({devices:[{screen_id:'valid-screen'}],skip_categories:'sponsor'},false)),'wrong category type');
check(validate_runtime_config({devices:[]},true),'empty config accepted for removal');
print('Cache eviction, offset bounds and configuration validation OK\n');
