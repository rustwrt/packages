'use strict';
function parse_args(argv) {
    let args={code:null,section:'',name:'',list:false};
    let seen={};
    for(let i=0;i<length(argv);i++){
        let key=argv[i];
        if(seen[key] || index(['--list','--code','--section','--name'],key)<0)return null;
        seen[key]=true;
        if(key=='--list'){args.list=true;continue;}
        let val=argv[++i];if(val==null)return null;
        if(key=='--code')args.code=val;
        else if(key=='--section')args.section=val;
        else args.name=val;
    }
    if(args.list && (seen['--section']||seen['--name']))return null;
    if(seen['--section'] && !match(args.section,/^([A-Za-z0-9_]+|@device\[[0-9]+\])$/))return null;
    if(length(args.name)>200 || match(args.name,/[[:cntrl:]]/))return null;
    if(!args.code || !match(replace(args.code,/[- ]/g,''),/^[0-9]{12}$/))return null;
    return args;
}
function check(v,m){if(!v)die(m);}
let code=join('',[1234,5678,9012]);
check(parse_args(['--list','--code',code]).list,'read-only order');
check(parse_args(['--code',code,'--list']).list,'legacy order');
check(!parse_args(['--list','--code',code,'--section','main']),'no write flags with list');
check(!parse_args(['--code',code,'--code',code]),'reject duplicate flags');
check(!parse_args(['--code','invalid']),'reject invalid code');
check(!parse_args(['--code',code,'--section','bad.section']),'invalid section rejected');
check(!parse_args(['--code',code,'--name','bad\nname']),'invalid name rejected');
print('Pairing argument order and validation OK\n');
