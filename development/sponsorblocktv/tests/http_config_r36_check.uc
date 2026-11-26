'use strict';
import {request_with_client} from './lib/http.uc';
import {SponsorBlockClient} from './lib/sponsorblock.uc';
import {build_config,parse_uci_show} from './lib/config.uc';
import * as util from './lib/util.uc';
let u=require('uloop');u.init();
function check(ok,msg){if(!ok)die(msg);}
for(let url in ['https://example.test/api','https://example.test/api/','https://example.test/api///'])
    check(util.normalize_api_url(url)=='https://example.test/api/','single trailing slash');
check(util.normalize_api_url('http://[::1]:8080/api')=='http://[::1]:8080/api/','local IPv6 API');
for(let bad in ['https://example.test/api?q=1','https://example.test/api#x','https://user@example.test/api','file:///tmp/foo']){
    let rejected=false;try{util.normalize_api_url(bad);}catch(e){rejected=true;}
    check(rejected,'invalid API rejected');
}
let prefix='sponsorblocktv.main=sponsorblocktv\n';
check(length(build_config(parse_uci_show(prefix)).skip_categories)==1,'default sponsor retained');
check(length(build_config(parse_uci_show(prefix+"sponsorblocktv.main.skip_categories='none'\n")).skip_categories)==0,'explicit disable persists');
let c=SponsorBlockClient({skip_categories:['sponsor'],devices:[]});
let complete,count=0;
c.is_whitelisted=(id,ok)=>{complete=ok;};
c.get_segments('abcdefghijk',()=>die('fixture callback'));
c.get_segments('abcdefghijk',()=>count++);
complete(true);complete(true);
check(count==1 && !length(keys(c._segment_pending)),'fanout isolates callbacks and duplicate completion');
let d=SponsorBlockClient({skip_categories:['sponsor'],devices:[]});
d.is_whitelisted=()=>die('fixture setup');
d.get_segments('abcdefghijk',()=>{},()=>count++);
check(count==2 && !length(keys(d._segment_pending)),'failed setup releases pending slot');
let clients=[];
function factory(url,proxy,cb){
    let f={...cb,status_code:200,chunks:[],freed:0,status:()=>({status:200}),
        read:function(){return shift(this.chunks);},get_headers:()=>({}),ssl_init:()=>true,
        set_timeout:()=>{},connect:()=>true,request:()=>true,free:function(){this.freed++;}};
    f.status=()=>({status:f.status_code});
    push(clients,f);return f;
}
let failures=0,done=0,streamed=0,body='';
request_with_client({url:'http://fixture/',max_body_bytes:4,on_error:()=>failures++},factory);
clients[0].chunks=['12345'];clients[0].data_read();clients[0].data_eof();clients[0].error(null,1);
check(clients[0].freed==0,'dispose deferred out of native read');
request_with_client({url:'http://fixture/',on_data:()=>streamed++,on_done:(st,h,b)=>{check(st==400,'status retained');body=b;done++;}},factory);
clients[1].status_code=400;clients[1].chunks=['Unknown SID'];clients[1].data_read();clients[1].data_eof();
let h=request_with_client({url:'http://fixture/',on_done:()=>die('cancel delivered'),on_error:()=>die('cancel delivered')},factory);
h.free();h.free();clients[2].data_eof();
request_with_client({url:'http://fixture/',on_data:()=>die('fixture parser'),on_error:()=>failures++},factory);
clients[3].chunks=['data'];clients[3].data_read();
request_with_client({url:'http://fixture/',on_error:()=>failures++},()=>die('fixture native setup'));
u.timer(100,()=>{
    check(failures==3 && done==1 && body=='Unknown SID' && streamed==0,'single completion and error body preserved');
    for(let f in clients)check(f.freed==1,'native freed once');
    print('URL validation, explicit disable, fanout isolation, native lifecycle and HTTP error body OK\n');
    u.end();
});
u.run();
