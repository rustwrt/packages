'use strict';
import {valid_ipv4,select_scan_device,select_scan_candidate,select_add_target} from './lib/discovery.uc';
import {url_matches_ip} from './lib/dial.uc';
function check(ok,msg){if(!ok)die(msg);}
for(let bad in ['999.1.2.3','192.168.001.1','127.0.0.1','224.0.0.1','0.0.0.0','1.2.3',null,123])check(!valid_ipv4(bad),'invalid interface');
check(valid_ipv4('192.168.1.1') && valid_ipv4('10.0.0.1'),'valid LAN IPv4');
check(!url_matches_ip('http://192.0.2.1/a\\b','192.0.2.1'),'ambiguous URL rejected');
check(url_matches_ip('http://192.0.2.1:8008/apps','192.0.2.1'),'normal DIAL URL accepted');
print('LAN interface validation and DIAL URL normalization OK\n');

let scan={scan_id:'fixture',pending:true,devices:[{screen_id:'early-screen',name:'TV'}],unpaired:[{id:'unknown-screen'}]};
check(select_scan_device(scan,'fixture','early-screen')?.name=='TV','verified early result eligible while scan pending');
check(!select_scan_device(scan,'fixture','unknown-screen'),'unpaired screen rejected');
check(!select_scan_device(scan,'other','early-screen'),'wrong scan rejected');
check(!select_scan_device(scan,'fixture','invalid!'),'invalid id rejected');
scan.pending=false;
check(select_scan_device(scan,'fixture','early-screen')?.name=='TV','completed scan still eligible');
print('Pending and completed scan selection OK\n');

let cid='128ab78b-d6af-12a4-be36-daa5564b3830';
scan.unpaired=[{id:cid,source:'Cast',host:'192.168.50.105',port:8009,name:'TV'}];
check(select_scan_candidate(scan,'fixture',cid)?.host=='192.168.50.105','Cast candidate allowed');
check(!select_scan_candidate(scan,'wrong',cid),'wrong scan rejected');
scan.pending=true;
check(!select_scan_candidate(scan,'fixture',cid),'active scan rejected');
scan.pending=false;
scan.unpaired[0].host='127.0.0.1';
check(!select_scan_candidate(scan,'fixture',cid),'loopback rejected');
scan.unpaired[0].host='192.168.50.105';
scan.unpaired[0].port=22;
check(!select_scan_candidate(scan,'fixture',cid),'non Cast port rejected');
print('Explicit Cast candidate validation OK\n');

scan.unpaired[0].port=8009;
check(select_add_target(scan,'fixture','cast:'+cid)?.candidate?.id==cid,'unified add selects Cast');
check(select_add_target(scan,'fixture','early-screen')?.device?.screen_id=='early-screen','unified add selects ready Screen ID');
check(!select_add_target(scan,'wrong','cast:'+cid),'unified add rejects wrong scan');
check(!select_add_target(scan,'fixture','cast:invalid'),'unified add rejects invalid Cast selector');
scan.pending=true;
check(!select_add_target(scan,'fixture','cast:'+cid),'unified add keeps pending Cast guard');
check(select_add_target(scan,'fixture','early-screen')?.device,'ready still actionable during scan');
scan.pending=false;
scan.unpaired=[];
scan.devices=[{id:cid,source:'Cast',screen_id:'now-ready-screen'}];
check(select_add_target(scan,'fixture','cast:'+cid)?.device?.screen_id=='now-ready-screen','candidate promoted to ready uses existing Screen ID');
print('Unified Add target selection OK\n');
