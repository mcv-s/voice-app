#!/usr/bin/env python3
"""Optional development helper: cache selected model weights under build/.
Usage: scripts/cache-models.py senseVoice whisperBase (or --all).
Never bundles these downloads into the app.
"""
import base64, concurrent.futures, hashlib, json, pathlib, sys, time, urllib.request
ROOT=pathlib.Path(__file__).resolve().parent.parent
catalog=json.loads((ROOT/'VoiceApp/ModelCatalog.json').read_text());wanted=set(sys.argv[1:])
models=[m for m in catalog if '--all' in wanted or m['id'] in wanted]
root=ROOT/'build/model-cache';root.mkdir(exist_ok=True)
crc_table=[]
for i in range(256):
 v=i
 for _ in range(8):v=(v>>1)^0x82f63b78 if v&1 else v>>1
 crc_table.append(v)
def verify(path,asset):
 if not path.exists() or path.stat().st_size!=asset['size']:return False
 if asset['checksumType']=='sha256':
  h=hashlib.sha256()
  with path.open('rb') as f:
   for data in iter(lambda:f.read(1024*1024),b''):h.update(data)
  return h.hexdigest()==asset['checksum']
 crc=0xffffffff
 with path.open('rb') as f:
  for data in iter(lambda:f.read(1024*1024),b''):
   for b in data:crc=crc_table[(crc^b)&255]^(crc>>8)
 return base64.b64encode((crc^0xffffffff).to_bytes(4,'big')).decode()==asset['checksum']
def fetch(item):
 model,asset=item;path=root/model['id']/asset['path'];path.parent.mkdir(parents=True,exist_ok=True)
 if verify(path,asset):return
 tmp=path.with_name(path.name+'.download')
 for attempt in range(3):
  try:
   urllib.request.urlretrieve(asset['url']+'?download=true&request='+str(time.time_ns()),tmp)
   if not verify(tmp,asset):raise RuntimeError('checksum mismatch')
   tmp.replace(path);print(model['id'],asset['path'],flush=True);return
  except Exception:
   if attempt==2:raise RuntimeError(model['id']+' '+asset['path']+' download failed')
with concurrent.futures.ThreadPoolExecutor(6) as pool:
 list(pool.map(fetch,[(m,a) for m in models for a in m['files']]))
for m in models:
 (root/m['id']/'installed.txt').write_text('\n'.join(a['path']+a['checksum'] for a in m['files']))
print('Verified',len(models),'models',flush=True)
