'use strict';
import * as http from './lib/http.uc';
let u=require('uloop'),fs=require('fs');u.init();
let base='https://127.0.0.1:'+ARGV[0],total=500,n=0,failed=null,phase=0,pending=0;
function rss(){return int(match(fs.readfile('/proc/self/status'),/VmRSS:[[:blank:]]*([0-9]+)/)[1]);}
let before=rss();
function fail(msg){failed=msg;u.end();}
let step,parallel;
function req(path,method,headers,body,cb){
    return http.request({url:base+path,method:method,headers:headers,body:body,verify_ssl:false,timeout_ms:3000,
        on_done:cb,on_error:fail});
}
step=()=>{
    let kind=n%4,path=kind==0?'/headers':kind==1?'/headers':kind==2?'/post':'/error';
    req(path,kind==2?'POST':'GET',kind==0?{'X-Fixture':'secret-fixture'}:{},kind==2?'post-fixture':null,
        (status,h,body)=>{
            let expected=kind==0?'secret-fixture':kind==1?'none':kind==2?'post-fixture':'fixture-data';
            if(status!=(kind==3?400:200) || body!=expected){fail(sprintf('stale request state %d status %d length %d',n,status,length(body)));return;}
            n++;
            if(n==total){parallel();return;}
            u.timer(0,step);
        });
};
parallel=()=>{
    pending=4;
    function one(i){
        req('/headers','GET',{'X-Fixture':'parallel-'+i},null,(status,h,body)=>{
            if(status!=200 || body!='parallel-'+i){fail(sprintf('parallel response crossed: expected %d, got %s HTTP %d',i,body,status));return;}
            if(--pending==0){
                let cancelled=req('/slow','GET',{},null,()=>fail('cancelled completion'));
                cancelled.free();
                // A verified request must reject the local self-signed cert,
                // even when an unverified test client was used previously.
                http.request({url:base+'/ok',timeout_ms:3000,
                    on_done:()=>fail('TLS validation bypass'),
                    on_error:()=>{
                        req('/ok','GET',{},null,(s,h,b)=>{
                            if(s!=200 || b!='fixture-data'){fail('recovery after TLS error');return;}
                            phase=1;u.end();
                        });
                    }});
            }
        });
    }
    for(let i=0;i<4;i++)one(i);
};
step();u.run();
printf('TLS requests=%d before=%d after=%d delta=%d kB\n',n,before,rss(),rss()-before);
if(failed || n!=total || phase!=1 || rss()-before>12288)die(failed||'TLS pool memory or lifecycle regression');
print('PASS TLS reuse, request isolation, concurrency, cancellation, verification and recovery\n');
