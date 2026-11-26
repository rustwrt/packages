'use strict';
import {build_config,parse_uci_show,validate_runtime_config} from './lib/config.uc';
import {DeviceListener} from './lib/runtime.uc';
import {SponsorBlockClient} from './lib/sponsorblock.uc';
import {snapshot} from './lib/live.uc';
function check(ok,msg){if(!ok)die(msg);}
function rejects(fn){try{fn();return false;}catch(e){return true;}}
let base="sponsorblocktv.main=sponsorblocktv\nsponsorblocktv.main.mute_ads='1'\nsponsorblocktv.main.skip_ads='1'\nsponsorblocktv.main.auto_play='0'\nsponsorblocktv.cfg123=device\nsponsorblocktv.cfg123.screen_id='abcdefghijk'\nsponsorblocktv.cfg123.skip_ads='0'\nsponsorblocktv.cfg123.auto_play='1'\nsponsorblocktv.cfg123.skip_sponsorblock='0'\nsponsorblocktv.cfg456=device\nsponsorblocktv.cfg456.screen_id='lmnopqrstuv'\nsponsorblocktv.cfg456.mute_ads='inherit'\n";
let cfg=build_config(parse_uci_show(base));
validate_runtime_config(cfg,false);
check(cfg.devices[0].config_section=='cfg123' && cfg.devices[0].skip_ads===false && cfg.devices[0].auto_play===true,'explicit device override');
check(cfg.devices[1].mute_ads==null && cfg.devices[1].skip_ads==null,'inherit not materialized');
let helper=SponsorBlockClient(cfg),a=DeviceListener(helper,cfg,cfg.devices[0],false),b=DeviceListener(helper,cfg,cfg.devices[1],false);
check(a.lounge.skip_ads===false && a.lounge.mute_ads===true && a.lounge.auto_play===true && a.skip_sponsorblock===false,'first TV independent policy');
check(b.lounge.skip_ads===true && b.lounge.mute_ads===true && b.lounge.auto_play===false && b.skip_sponsorblock===true,'second TV inherits');
check(snapshot(a).config_section=='cfg123' && snapshot(b).config_section=='cfg456','stable mapping while disconnected');
a._schedule_skip=()=>die('disabled TV attempted automatic skip');
a._time_to_segment([{start:0,end:10,UUID:['fixture']}],0);
check(!a._can_auto_seek(),'disabled TV auto seek blocked');
check(rejects(()=>build_config(parse_uci_show(base+"sponsorblocktv.cfg456.skip_ads='invalid'\n"))),'invalid override rejected');
check(rejects(()=>build_config(parse_uci_show(base+"sponsorblocktv.cfg456.skip_ads='0'\nsponsorblocktv.cfg456.skip_ads='1'\n"))),'duplicate override rejected');
cfg.devices[0].mute_ads='1';
check(rejects(()=>validate_runtime_config(cfg,false)),'JSON override must be boolean');
print('Per-TV inheritance, independent policy, stable mapping and disabled SponsorBlock guard OK\n');
