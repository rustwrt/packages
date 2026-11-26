'use strict';
import {url_matches_ip,extract_screen_id} from './lib/dial.uc';
import {pair_with_code} from './lib/sponsorblock.uc';
function check(v,m){if(!v)die(m);}
let ip='192.168.1.20';
for(let url in ['http://192.168.1.20','http://192.168.1.20:8008/apps/','https://192.168.1.20:443/apps'])
    check(url_matches_ip(url,ip),'valid DIAL URL');
for(let url in ['http://192.168.1.21/apps','http://192.168.1.20:0/apps','http://192.168.1.20:65536/apps','http://192.168.1.20:80@other/apps','http://192.168.1.20/apps?x=1','http://192.168.1.20/apps#x','http://192.168.1.20/apps\n','http://192.168.1.20/apps space','file:///tmp/apps'])
    check(!url_matches_ip(url,ip),'invalid DIAL URL');
check(!url_matches_ip('http://192.168.1.020/apps','192.168.1.020'),'noncanonical address');
check(extract_screen_id('<screenId> abcdefghijk </screenId>')=='abcdefghijk','trim screen ID');
check(extract_screen_id('<screenId>bad&amp;id</screenId>')==null,'reject malformed screen ID');
check(extract_screen_id(null)==null,'nonstring response rejected');
let rejected=0;
pair_with_code('invalid',()=>die('unexpected pairing result'),()=>rejected++);
check(rejected==1,'invalid code rejected before request');
print('DIAL URL and screen validation, invalid pairing code OK\n');
