import json, subprocess, socket, uuid, time
from zeroconf import Zeroconf, ServiceInfo, IPVersion
name='SBTV-r28-fixture'
uid=uuid.uuid4().hex
scan=uuid.uuid4().hex
z=Zeroconf(interfaces=['192.168.1.1'],ip_version=IPVersion.V4Only)
service=ServiceInfo('_googlecast._tcp.local.',name+'._googlecast._tcp.local.',addresses=[socket.inet_aton('192.168.1.1')],port=8009,properties={'id':uid,'fn':name,'md':'Chromecast','ca':'5','st':'0'},server='sbtv-r28-fixture.local.')
try:
 z.register_service(service)
 t=time.monotonic()
 p=subprocess.Popen(['/usr/sbin/sponsorblocktv-discover','--scan',scan],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
 first=None
 while p.poll() is None and time.monotonic()-t<40:
  d=json.loads(subprocess.check_output(['/usr/sbin/sponsorblocktv-discover','--status',scan],text=True))
  if any(x['name']==name for x in d.get('unpaired',[])) and first is None:
   first=time.monotonic()-t
   other=subprocess.run(['/usr/sbin/sponsorblocktv-discover','--scan',uuid.uuid4().hex],capture_output=True,text=True,timeout=3)
   assert other.returncode!=0 and 'Another network scan' in other.stdout, other.stdout
   print('Concurrent scan rejected; first candidate %.2fs'%first,flush=True)
  time.sleep(.4)
 out,err=p.communicate(timeout=5)
 d=json.loads(out)
 assert p.returncode==0 and first is not None and not d['pending'] and any(x['name']==name for x in d['unpaired']), (out,err)
 bad=subprocess.run(['/usr/sbin/sponsorblocktv-discover','--add','invalid-screen','--scan',scan],capture_output=True,text=True)
 assert bad.returncode!=0 and 'not found' in bad.stdout
 print('Scan completed %.2fs; unverified screen rejected'%(time.monotonic()-t),flush=True)
finally:
 z.unregister_service(service); z.close()
