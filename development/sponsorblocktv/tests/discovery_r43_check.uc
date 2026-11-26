'use strict';
import {normalize_device,scan_device_info} from './lib/discovery.uc';
import {normalize_pair_response} from './lib/sponsorblock.uc';
function check(v,m){if(!v)die(m);}
check(normalize_device({screen_id:123},true)==null,'bad screen id');
check(normalize_device({id:'bad\nkey'},false)==null,'bad candidate id');
let d=normalize_device({screen_id:'fixture123',name:{bad:true},host:'TV.LOCAL',source:{bad:true},model:4,unknown:'discard'},true);
check(d.name=='YouTube TV' && d.host=='tv.local' && d.source=='YouTube' && d.model=='' && d.unknown==null,'strict field normalization');
let v=normalize_device({id:'fixture',name:'Living\nroom',source:'Cast',host:'192.0.2.1'},false);
check(v.name=='Living room' && v.source=='Cast','control chars sanitized');
check(normalize_pair_response({screen:{screenId:123}})==null,'invalid pairing response rejected');
let pair=normalize_pair_response({screen:{screenId:'fixture123',name:[],loungeToken:{bad:true}}});
check(pair.name=='YouTube on TV' && pair.lounge_token==null,'invalid remote fields replaced');
check(normalize_pair_response({screen:{screenId:'fixture123',name:'  '}}).name=='YouTube on TV','empty name falls back');
print('Discovery and pairing response normalization OK\n');

import {descriptor_info,dial_app_info} from './lib/dial.uc';
let desc=descriptor_info('<device><friendlyName>TizenTube (Living &amp; Dining)</friendlyName><manufacturer>Samsung</manufacturer><modelName>QN90C</modelName><UDN>uuid:12345678-abcd-1234-abcd-123456789abc</UDN></device>');
check(desc.name=='TizenTube (Living & Dining)' && desc.manufacturer=='Samsung' && desc.model=='QN90C','DIAL metadata and XML entities');
let app=dial_app_info('<service><name>YouTube</name><state>running</state></service>',desc.name);
check(app.application=='TizenTube' && app.app_state=='running','advertised TizenTube and state');
check(descriptor_info('<device/>').manufacturer=='' && descriptor_info('<device/>').model=='','unknown metadata not guessed');
let full=scan_device_info({...desc,...app,screen_id:'fixture123',id:'dial:fixture',host:'192.0.2.15',port:8008,source:'DIAL'},true);
check(full.manufacturer=='Samsung' && full.model=='QN90C' && full.host=='192.0.2.15' && full.port==8008 && full.uuid==desc.uuid && full.application=='TizenTube' && full.app_state=='running' && full.type=='DIAL','ready snapshot retains metadata');
let candidate=scan_device_info({id:'fixture',name:'Cast TV',manufacturer:'Sony',model:'BRAVIA',host:'192.0.2.16',port:8009,source:'Cast'},false);
check(candidate.manufacturer=='Sony' && candidate.model=='BRAVIA' && candidate.port==8009 && !candidate.screen_id,'candidate metadata');
print('Full discovery metadata and unknown values OK\n');
