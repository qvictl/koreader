import hashlib,json,os,subprocess,time
from pathlib import Path
import argparse
parser=argparse.ArgumentParser()
parser.add_argument('--kodir',type=Path,required=True)
parser.add_argument('--dict-dir',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
opts=parser.parse_args()
root=opts.kodir.resolve();dictionary=opts.dict_dir.resolve();names=[]
for ifo in sorted(dictionary.rglob('*.ifo')):
 for line in ifo.read_text(errors='replace').splitlines():
  if line.startswith('bookname='):names.append(line.split('=',1)[1])
assert len(names)==3
args=[str(root/'sdcv'),'--utf8-input','--utf8-output','--json-output','--non-interactive','--data-dir',str(dictionary)]
for name in names:args+=['-u',name]
words=['test','run','harbor','light','accomodation','qwxzvbnmplk'];rows=[];expected={}
for iteration in range(3):
 for word in words:
  start=time.perf_counter();proc=subprocess.Popen(args+['--',word],stdout=subprocess.PIPE,stderr=subprocess.PIPE,cwd=root)
  raw=proc.stdout.read();pid,status,usage=os.wait4(proc.pid,0);proc.returncode=os.waitstatus_to_exitcode(status)
  elapsed=(time.perf_counter()-start)*1000
  assert proc.returncode in (0,2)
  digest=hashlib.sha256(raw).hexdigest()
  if word in expected:assert expected[word]==digest
  expected[word]=digest
  rows.append(dict(word=word,round=iteration+1,wall_ms=elapsed,user_ms=usage.ru_utime*1000,system_ms=usage.ru_stime*1000,output_bytes=len(raw),results=len(json.loads(raw)),sha256=digest))
opts.output.write_text(json.dumps(rows,indent=2))
import statistics
for word in words:
 r=[r for r in rows if r['word']==word]
 print(word,'wall_ms',round(statistics.median(x['wall_ms'] for x in r),3),'cpu_ms',round(statistics.median(x['user_ms']+x['system_ms'] for x in r),3),'bytes',r[0]['output_bytes'])
