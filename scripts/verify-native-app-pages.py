"""Verify reusable native captures against current source hashes and UI results.

Reuses actual screenshots only; never draws a replacement UI or fabricates a
passed test. A changed compiled source or failed UI interaction rejects reuse.
"""
from pathlib import Path
import argparse,hashlib,json,shutil,struct
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--capture-root',type=Path,required=True)
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args()
repo=Path(__file__).resolve().parents[1]
matches=list(args.capture_root.rglob('manifest.json'))
assert len(matches)==1,'Expected one capture manifest'
source=matches[0].parent
read=lambda name:json.loads((source/name).read_text(encoding='utf-8'))
manifest=read('manifest.json'); readiness=read('capture-readiness.json');summary=read('ui-tests-summary.json')
for name,digest in manifest['productionSourceHashes'].items():
    assert hashlib.sha256((repo/name).read_bytes()).hexdigest()==digest,name
assert summary['totalTestCount']==summary['passedTests']==17 and summary['failedTests']==summary['skippedTests']==0,summary
unique={r['scene']:r for r in readiness['scenes']}
assert len(unique)==83,len(unique)
images=[]
for scene,record in sorted(unique.items()):
    p=source/(scene+'.png');data=p.read_bytes()
    assert record['stableConsecutiveFrames']==2 and record['frameAudit']['meaningfulBody']
    assert hashlib.sha256(data).hexdigest()==record['sha256'],scene
    assert data[:8]==b'\x89PNG\r\n\x1a\n'
    w,h=struct.unpack('>II',data[16:24]);assert w>=1000 and h>w
    images.append({'scene':scene,'file':p.name,'width':w,'height':h,'bytes':len(data),'sha256':record['sha256'],'syntheticInputs':True,'mode':'night' if 'night' in scene else 'day'})
manifest.update({'scenes':images,'captureReadiness':'capture-readiness.json','uiInteractionTests':{'suite':'AppPagesUITests','tests':17,'passed':17,'failed':0,'skipped':0,'summary':'ui-tests-summary.json','scope':'Actual production SwiftUI controls with explicit service adapters'},'validationRepair':'One existing navigation-night scene was requested twice. Reused actual unchanged-source captures; deduplicated 84 requests into83 unique pages. No screenshot pixels or UI results modified.'})
args.output.mkdir(parents=True,exist_ok=True)
for p in source.iterdir():
    if p.is_file() and p.suffix in {'.png','.json','.txt'} and p.name!='manifest.json':
        if p.resolve()!=(args.output/p.name).resolve():shutil.copy2(p,args.output/p.name)
(args.output/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps({'passed':True,'uniqueNativeScreenshots':len(images),'uiTests':17,'sourceHashCount':len(manifest['productionSourceHashes']),'pixelsUnmodified':True}))
