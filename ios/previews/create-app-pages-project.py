"""Build a disposable SDK-free simulator project from real production UI files."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
build = root / '.build' / 'app-pages-preview'
project = build / 'MotoNavPages.xcodeproj'
project.mkdir(parents=True, exist_ok=True)
production = [
    'ContentView.swift', 'PreparationViews.swift', 'KeySetupView.swift',
    'IndependentRouteView.swift', 'NaviScreen.swift', 'RideTools.swift',
    'RotationDial.swift', 'RouteCoverageSummaryView.swift', 'Settings.swift',
    'Weather.swift', 'TextImage.swift', 'QWeatherForecast.swift', 'MapDefaults.swift',
    'MapGeo.swift', 'LocationReadiness.swift', 'MapReadiness.swift',
    'NavigationRecovery.swift', 'PreparationRecovery.swift', 'PipelineDiagnostics.swift',
    'RideStore.swift',
    'IndependentRecalculationNotice.swift',
    'JourneyPolicy.swift', 'JourneyStore.swift', 'JourneyViews.swift',
    'AppPalette.swift',
    'HomeMapView.swift', 'NavigationPalette.swift',
    'RouteCoverage.swift', 'RouteFlowPolicy.swift', 'Config.swift',
]
app_files = [root / 'ios' / 'MotoNav' / name for name in production]
app_files += [root / 'ios' / 'previews' / name for name in ['AppPagesAdapters.swift', 'AppPagesPreview.swift']]
test_file = root / 'ios' / 'previews' / 'AppPagesUITests.swift'
objects = []
def ident(key): return hashlib.sha256(key.encode()).hexdigest()[:24].upper()
def q(value): return json.dumps(str(value), ensure_ascii=False)
def add(key, content):
    identifier = ident(key); objects.append(f'{identifier} = {{ {content} }};'); return identifier

refs, app_sources = [], []
for path in app_files + [test_file]:
    assert path.is_file(), path
    ref = add('file:' + str(path), f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(path)}; sourceTree = "<absolute>";')
    refs.append(ref)
    item = add('build:' + str(path), f'isa = PBXBuildFile; fileRef = {ref};')
    if path != test_file: app_sources.append(item)
    else: test_source = item
app_product = add('app-product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = MotoNavPages.app; sourceTree = BUILT_PRODUCTS_DIR;')
test_product = add('test-product', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = MotoNavPagesUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
products = add('products', f'isa = PBXGroup; children = ({app_product}, {test_product}); name = Products; sourceTree = "<group>";')
group = add('main-group', f'isa = PBXGroup; children = ({", ".join(refs)}, {products}); sourceTree = "<group>";')
def phase(key, kind, files=''):
    return add(key, f'isa = {kind}; buildActionMask = 2147483647; files = ({files}); runOnlyForDeploymentPostprocessing = 0;')
app_phases = [phase('app-sources', 'PBXSourcesBuildPhase', ', '.join(app_sources)), phase('app-frameworks','PBXFrameworksBuildPhase'),phase('app-resources','PBXResourcesBuildPhase')]
test_phases = [phase('test-sources','PBXSourcesBuildPhase',test_source), phase('test-frameworks','PBXFrameworksBuildPhase'),phase('test-resources','PBXResourcesBuildPhase')]
base = 'CLANG_ENABLE_MODULES = YES; IPHONEOS_DEPLOYMENT_TARGET = 18.0; SDKROOT = iphonesimulator; SWIFT_VERSION = 5.0; ONLY_ACTIVE_ARCH = YES; SWIFT_OPTIMIZATION_LEVEL = "-Onone"; CODE_SIGNING_ALLOWED = NO; TARGETED_DEVICE_FAMILY = 1;'
def configs(key, extra):
    ids = [add(key+name, f'isa = XCBuildConfiguration; buildSettings = {{ {base} {extra} }}; name = {name};') for name in ['Debug','Release']]
    return add(key+'-list', f'isa = XCConfigurationList; buildConfigurations = ({", ".join(ids)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;')
project_cfg = configs('project-config','')
app_cfg = configs('app-config','PRODUCT_BUNDLE_IDENTIFIER = local.motonav.app-pages-preview; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; OTHER_SWIFT_FLAGS = "$(inherited) -DMOTONAV_SCREENSHOTS";')
test_cfg = configs('test-config','PRODUCT_BUNDLE_IDENTIFIER = local.motonav.app-pages-uitests; PRODUCT_NAME = "$(TARGET_NAME)"; GENERATE_INFOPLIST_FILE = YES; TEST_TARGET_NAME = MotoNavPages;')
app_id, test_id, proj_id = ident('app-target'), ident('test-target'), ident('project')
proxy = add('test-app-proxy',f'isa = PBXContainerItemProxy; containerPortal = {proj_id}; proxyType = 1; remoteGlobalIDString = {app_id}; remoteInfo = MotoNavPages;')
dependency = add('test-dependency',f'isa = PBXTargetDependency; target = {app_id}; targetProxy = {proxy};')
add('app-target', f'isa = PBXNativeTarget; buildConfigurationList = {app_cfg}; buildPhases = ({", ".join(app_phases)}); buildRules = (); dependencies = (); name = MotoNavPages; productName = MotoNavPages; productReference = {app_product}; productType = "com.apple.product-type.application";')
add('test-target', f'isa = PBXNativeTarget; buildConfigurationList = {test_cfg}; buildPhases = ({", ".join(test_phases)}); buildRules = (); dependencies = ({dependency}); name = MotoNavPagesUITests; productName = MotoNavPagesUITests; productReference = {test_product}; productType = "com.apple.product-type.bundle.ui-testing";')
add('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1640; TargetAttributes = {{ {test_id} = {{ TestTargetID = {app_id}; }}; }}; }}; buildConfigurationList = {project_cfg}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, "zh-Hans"); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({app_id}, {test_id});')
(project / 'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {proj_id}; }}\n',encoding='utf-8')
schemes = project / 'xcshareddata' / 'xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
def ref(identifier,name,product):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{identifier}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:MotoNavPages.xcodeproj"/>'
(schemes/'MotoNavPages.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1640" version="1.7">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
 <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref(app_id,'MotoNavPages','MotoNavPages.app')}</BuildActionEntry>
 <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{ref(test_id,'MotoNavPagesUITests','MotoNavPagesUITests.xctest')}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ref(test_id,'MotoNavPagesUITests','MotoNavPagesUITests.xctest')}</TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{ref(app_id,'MotoNavPages','MotoNavPages.app')}</BuildableProductRunnable></LaunchAction>
</Scheme>''',encoding='utf-8')
out = root/'output'/'ios'/'app-pages'; out.mkdir(parents=True,exist_ok=True)
manifest = {'schema':'motonav.native-ui-previews.v1','sourceCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'platform':'iOS Simulator','host':'disposable test-only native SwiftUI app','productionUIFiles':production[:8]+['Weather.swift','JourneyViews.swift'], 'productionSourceHashes':{str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in app_files if p.parent.name=='MotoNav'},'adapters':['Bluetooth','GPS','AMap SDK','search/route services','map preparation controller'], 'limitations':['No physical device, live map SDK, live service, BLE throughput or FPS validation.','SDK map surfaces are visibly labelled placeholders; production controls are unchanged.','Journey management uses the production library and bounded file store in the disposable app sandbox; draft tests call production apply/cancel closures.','Navigation and maintenance tests verify UI-to-adapter calls; separate regression suites validate production persistence and navigation.']}
(out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(project)
