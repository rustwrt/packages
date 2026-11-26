'use strict';
import {build_config,parse_uci_show,validate_runtime_config} from './lib/config.uc';
import * as util from './lib/util.uc';
function check(ok,msg){if(!ok)die(msg);}
function rejects(fn){try{fn();return false;}catch(e){return true;}}
let prefix='sponsorblocktv.main=sponsorblocktv\n';
function cfg(t){return build_config(parse_uci_show(prefix+t));}
let c=cfg("sponsorblocktv.main.skip_categories='sponsor' 'intro'\nsponsorblocktv.main.skip_categories='outro' 'sponsor'\n");
check(join(',',c.skip_categories)=='sponsor,intro,outro','mixed list entries expanded and deduplicated');
check(!length(cfg("sponsorblocktv.main.skip_categories='sponsor' 'none'\nsponsorblocktv.main.skip_categories='intro'\n").skip_categories),'explicit disabled list wins');
for(let bad in ['-1','1.5','1junk','604801','999999999'])check(rejects(()=>cfg("sponsorblocktv.main.minimum_skip_length='"+bad+"'\n")),'invalid minimum '+bad);
check(cfg("sponsorblocktv.main.minimum_skip_length='0'\n").minimum_skip_length==0,'zero limit');
check(cfg("sponsorblocktv.main.minimum_skip_length='604800'\n").minimum_skip_length==604800,'upper limit');
let w=cfg("sponsorblocktv.@whitelist[0]=whitelist\nsponsorblocktv.@whitelist[0].id='UCfixture'\nsponsorblocktv.@whitelist[1]=whitelist\nsponsorblocktv.@whitelist[1].id='UCfixture'\n");
check(length(w.channel_whitelist)==1,'duplicate channels collapsed');
for(let bad in ['https://example.test:0/api','https://example.test:65536/api','https://[::1]:99999/api','https://example.test/a\\b',123])check(rejects(()=>util.normalize_api_url(bad)),'invalid URL rejected');
check(util.normalize_api_url('http://[::1]:65535/api')=='http://[::1]:65535/api/','valid upper port');
print('Mixed UCI list, whitelist dedup, minimum length and API endpoint bounds OK\n');

// Regression: a newly paired TV has explicit policies in UCI.
let seed="sponsorblocktv.cfg123=device\nsponsorblocktv.cfg123.screen_id='fixture123'\nsponsorblocktv.cfg123.name='Fixture TV'\nsponsorblocktv.cfg123.offset='0'\nsponsorblocktv.cfg123.skip_ads='1'\nsponsorblocktv.cfg123.mute_ads='1'\nsponsorblocktv.cfg123.auto_play='1'\nsponsorblocktv.cfg123.skip_sponsorblock='1'\nsponsorblocktv.cfg123.skip_categories='sponsor,intro'\nsponsorblocktv.cfg123.minimum_skip_length='1'\n";
for(let mode in ['cooperative','standard','passive']){
    let c=cfg(seed+"sponsorblocktv.cfg123.controller_mode='"+mode+"'\n");
    validate_runtime_config(c,true);
    check(length(c.devices)==1 && c.devices[0].controller_mode==mode && c.devices[0].minimum_skip_length==1 && join(',',c.devices[0].skip_categories)=='sponsor,intro','new TV policy roundtrip '+mode);
}
check(rejects(()=>cfg(seed+"sponsorblocktv.cfg123.controller_mode='invalid'\n")),'bad controller rejected');
let c2=cfg(seed+"sponsorblocktv.cfg123.controller_mode='cooperative'\n");
c2.devices[0].controller_mode='invalid';
check(rejects(()=>validate_runtime_config(c2,true)),'invalid JSON controller rejected');
print('New TV explicit UCI policies and runtime config validation OK\n');
