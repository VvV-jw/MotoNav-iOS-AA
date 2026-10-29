"""Register the isolated experiment and increment only its worktree version."""
from pathlib import Path
import hashlib,importlib.util,re
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('validation',ROOT/'scripts/validate-ios-project.py')
v=importlib.util.module_from_spec(spec);spec.loader.exec_module(v)
path=ROOT/'ios/MotoNav.xcodeproj/project.pbxproj';text=path.read_text(encoding='utf-8')
objects=v.parse_openstep(text)['objects']
group=next(k for k,o in objects.items() if o.get('isa')=='PBXGroup' and o.get('path')=='MotoNav')
target=next(o for o in objects.values() if o.get('isa')=='PBXNativeTarget' and o.get('name')=='MotoNav')
phase=next(k for k in target['buildPhases'] if objects[k]['isa']=='PBXSourcesBuildPhase')
def insert(text,identifier,key,line):
 expression=rf'(^\t\t{identifier}(?: /\*[^\n]*\*/)? = \{{\n.*?\n\t\t\t{key} = \(\n)'
 result,n=re.subn(expression,lambda m:m[1]+line,text,count=1,flags=re.M|re.S);assert n==1
 return result
for name,kind in [('NativeCountdownTap.mm','sourcecode.cpp.objcpp'),('NativeCountdownEvidence.swift','sourcecode.swift')]:
 assert (ROOT/'ios/MotoNav'/name).is_file()
 if f'path = {name};' in text:continue
 ref=hashlib.sha256(('countdown-ref:'+name).encode()).hexdigest()[:24].upper()
 build=hashlib.sha256(('countdown-build:'+name).encode()).hexdigest()[:24].upper()
 text=text.replace('/* End PBXBuildFile section */',f'\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n/* End PBXBuildFile section */')
 text=text.replace('/* End PBXFileReference section */',f'\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; path = {name}; sourceTree = "<group>"; }};\n/* End PBXFileReference section */')
 text=insert(text,group,'children',f'\t\t\t\t{ref} /* {name} */,\n')
 text=insert(text,phase,'files',f'\t\t\t\t{build} /* {name} in Sources */,\n')
text=text.replace('MARKETING_VERSION = 0.15.16;','MARKETING_VERSION = 0.15.17;').replace('CURRENT_PROJECT_VERSION = 16;','CURRENT_PROJECT_VERSION = 17;')
path.write_text(text,encoding='utf-8',newline='\n')
(ROOT/'RELEASE_VERSION').write_text('0.15.17\n');(ROOT/'BUILD_NUMBER').write_text('17\n')
p=ROOT/'ios/MotoNav/Config.swift';p.write_text(p.read_text(encoding='utf-8').replace('iOS v0.15.16-aa.16','iOS v0.15.17-countdown.1'),encoding='utf-8')
p=ROOT/'scripts/validate-ios-project.py';p.write_text(p.read_text(encoding='utf-8').replace('expected == "0.15.16" and expected_build == "16"','expected == "0.15.17" and expected_build == "17"'),encoding='utf-8')
print('Registered countdown experiment 0.15.17/build17')
