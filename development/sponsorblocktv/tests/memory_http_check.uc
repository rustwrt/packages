'use strict';
import {request_with_client} from './lib/http.uc';
let u=require('uloop'),fs=require('fs');u.init();
function rss(){
 let m=match(fs.readfile('/proc/self/status'),/VmRSS:[[:blank:]]*([0-9]+)/);
 return m?int(m[1]):0;
}
let count=0,total=1000,peak=rss(),before=peak;
function step(){
 let callbacks,reads=0,payload=join('',map([0,1,2,3,4,5,6,7],i=>sprintf('%08192d',i)));
 let client;client={set_timeout:()=>{},connect:()=>true,request:()=>true,disconnect:()=>{},free:()=>{delete client.data_read;delete client.data_eof;callbacks=null;payload=null;},status:()=>({status:200}),get_headers:()=>({}),read:()=>reads++?null:payload};
 let h=request_with_client({url:'http://fixture/',timeout_ms:1000,on_done:(status,headers,body)=>{
  if(status!=200 || length(body)!=65536)die('incorrect body');
  count++;
  if(count%250==0){peak=max(peak,rss());printf('MEM %d %d kB\n',count,rss());}
  if(count==total){printf('MEM_DONE before=%d after=%d peak=%d kB\n',before,rss(),peak);u.end();}
  else u.timer(0,step);
 },on_error:(err)=>die(err)},(url,proxy,cb)=>{callbacks=cb;return client;});
 client.data_read=callbacks.data_read;client.data_eof=callbacks.data_eof;client.data_read();client.data_eof();
}
step();u.run();
if(count!=total || rss()-before>8192)die('HTTP memory regression: expected 1000 completed requests and growth <= 8 MiB');
