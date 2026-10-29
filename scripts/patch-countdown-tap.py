#!/usr/bin/env python3
"""Post-link the isolated arm64 observer before signing. No service/config patches.

Replace only direct BL instructions to the two pinned SDK methods with calls to
our ABI-compatible wrappers. The wrappers invoke the originals exactly once.
Refuse unexpected architectures, SDK versions, caller sets, missing wrappers,
out-of-range branches, stale sentinels or unavailable file-backed slots.
"""
from pathlib import Path
import argparse, bisect, hashlib, json, struct

PARSE='__ZN4dice11naviservice20TrafficLightProvider14parseLightInfoEiPKhj'
SIGNAL='__ZN4dice11naviservice20TrafficLightProvider25onUpdateTrafficSignalInfoEPKNS_13TrafficSignalEj'
PREFIX='__ZN4dice11naviservice20TrafficLightProvider'
CALLERS={PARSE:{PREFIX+'15processHttpDataEiiPKhj':1}, SIGNAL:{
    PREFIX+'15notifyHideLightEb':2,
    PREFIX+'15notifyLightInfoERKNSt3__16vectorINS0_12trafficlight16NaviTrafficLightENS2_9allocatorIS5_EEEE':1,
    PREFIX+'11updateLightEv':1}}
SLOTS={PARSE:('_MNCountdownParseRVA',0x4d4e435450415253,'_MNCountdownParse'),
       SIGNAL:('_MNCountdownSignalRVA',0x4d4e43545349474e,'_MNCountdownSignal')}

def fingerprint(code):
    """Mask PC/address relocation operands; retain all load/store field offsets."""
    output=bytearray()
    for (w,) in struct.iter_unpack('<I',code):
        if w&0x7c000000==0x14000000: w &= 0xfc000000  # B / BL
        elif w&0x1f000000==0x10000000: w &= ~0x60ffffe0  # ADR / ADRP
        elif w&0x1f000000==0x11000000: w &= ~0x003ffc00  # ADD/SUB address immediates
        elif w&0x3b000000==0x18000000: w &= ~0x00ffffe0  # PC-relative literal
        output.extend(struct.pack('<I',w))
    return hashlib.sha256(output).hexdigest()

def patch(binary, lock, report_path, dry_run=False):
    assert '  - AMapNavi (10.1.600)' in lock.read_text(), 'Only the inspected locked SDK is supported'
    original=binary.read_bytes(); data=bytearray(original)
    assert struct.unpack_from('<II',data)==(0xfeedfacf,0x100000c),'Expected thin arm64 Mach-O'
    segments=[];sections=[];symbols={};at=32
    for _ in range(struct.unpack_from('<I',data,16)[0]):
        cmd,size=struct.unpack_from('<II',data,at);assert size>=8 and at+size<=len(data)
        if cmd==0x19:
            name=data[at+8:at+24].split(b'\0')[0].decode()
            va,vs,off,fs=struct.unpack_from('<QQQQ',data,at+24)
            segments.append((name,va,off,fs))
            for i in range(struct.unpack_from('<I',data,at+64)[0]):
                p=at+72+80*i;assert p+80<=at+size
                sn=data[p:p+16].split(b'\0')[0].decode();sv,ss,so=struct.unpack_from('<QQI',data,p+32)
                sections.append((sn,sv,ss,so))
        elif cmd==2:
            so,n,st,sz=struct.unpack_from('<IIII',data,at+8);assert so+16*n<=len(data) and st+sz<=len(data)
            strings=data[st:st+sz]
            for i in range(n):
                ix,kind,sect,desc,va=struct.unpack_from('<IBBHQ',data,so+16*i)
                if ix>=sz or not va or kind&0xe!=0xe:continue
                e=strings.find(b'\0',ix);assert e>=ix
                name=strings[ix:e].decode(errors='replace')
                symbols[name]=va
        at+=size
    base=next(va for name,va,off,size in segments if name=='__TEXT')
    def offset(va,n=4):
        for _,addr,off,size in segments:
            if addr<=va and va+n<=addr+size:return off+va-addr
        raise AssertionError('Target must be file backed')
    starts=sorted({va for va in symbols.values()}); names={va:[] for va in starts}
    for n,v in symbols.items():names[v].append(n)
    guards=json.loads(Path(__file__).with_name('countdown-abi-fingerprints.json').read_text())
    for symbol,expected in guards['functions'].items():
        assert symbol in symbols, 'Missing guarded SDK function'
        start=symbols[symbol];end=starts[bisect.bisect_right(starts,start)]
        assert end-start==expected['bytes'], 'Changed SDK function boundary'
        code=original[offset(start,end-start):offset(start,end-start)+end-start]
        assert fingerprint(code)==expected['sha256'], 'SDK ABI fingerprint changed: '+symbol
    text=next(s for s in sections if s[0]=='__text')
    found={key:[] for key in SLOTS};changes=[]
    for key,(slot,magic,wrapper) in SLOTS.items():
        assert all(n in symbols for n in [key,slot,wrapper]),'Missing retained observer/original symbol'
        assert struct.unpack_from('<Q',data,offset(symbols[slot],8))[0]==magic,'Observer already patched or wrong sentinel'
    targets={symbols[key]:key for key in SLOTS}
    for i,(word,) in enumerate(struct.iter_unpack('<I',original[text[3]:text[3]+text[2]])):
        if word&0xfc000000!=0x94000000:continue
        va=text[1]+i*4;imm=word&0x3ffffff
        if imm&0x2000000:imm-=0x4000000
        target=va+(imm<<2)
        if target not in targets:continue
        key=targets[target];caller=names[starts[bisect.bisect_right(starts,va)-1]]
        matching=[n for n in caller if n in CALLERS[key]]
        assert len(matching)==1,'Unexpected caller to pinned method: '+str(caller)
        destination=symbols[SLOTS[key][2]];delta=destination-va
        assert delta%4==0 and -(1<<27)<=delta<(1<<27),'Wrapper out of BL range'
        replacement=0x94000000|((delta>>2)&0x3ffffff)
        struct.pack_into('<I',data,text[3]+i*4,replacement)
        found[key].append(matching[0]);changes.append(dict(at=hex(va),caller=matching[0],originalTarget=key,wrapper=SLOTS[key][2]))
    for key,(slot,magic,wrapper) in SLOTS.items():
        actual={n:found[key].count(n) for n in set(found[key])}
        assert actual==CALLERS[key],f'Incomplete/unexpected caller set: {actual}'
        struct.pack_into('<Q',data,offset(symbols[slot],8),symbols[key]-base)
    # Exactly five branch words and two RVA slots may differ. Validate again
    # before the single file replacement; no network/auth/freshness checks change.
    allowed=set()
    for item in changes:allowed.update(range(offset(int(item['at'],16)),offset(int(item['at'],16))+4))
    for slot,_,_ in SLOTS.values():allowed.update(range(offset(symbols[slot],8),offset(symbols[slot],8)+8))
    assert all(a==b or i in allowed for i,(a,b) in enumerate(zip(original,data)))
    report=dict(sdk='10.1.600',architecture='arm64',observerOnly=True,originalChecksChanged=False,
                inputSHA256=hashlib.sha256(original).hexdigest(),outputSHA256=hashlib.sha256(data).hexdigest(),
                callsites=changes,branchesChanged=len(changes),rvaSlotsChanged=2,dryRun=dry_run)
    report['sdkABIFingerprintsVerified']=len(guards['functions'])
    if not dry_run:
        temporary=binary.with_name(binary.name+'.countdown.tmp');temporary.write_bytes(data);temporary.replace(binary)
    report_path.parent.mkdir(parents=True,exist_ok=True)
    report_path.write_text(json.dumps(report,indent=2)+'\n')
    return report

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('binary',type=Path)
    p.add_argument('--lock',type=Path,default=Path(__file__).resolve().parents[1]/'ios/Podfile.lock')
    p.add_argument('--report',type=Path,required=True);p.add_argument('--dry-run',action='store_true');a=p.parse_args()
    print(json.dumps(patch(a.binary,a.lock,a.report,a.dry_run)))
