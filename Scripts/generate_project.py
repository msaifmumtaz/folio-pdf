#!/usr/bin/env python3
"""Regenerate the dependency-free Xcode project after adding/removing source files."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT = Path(__file__).resolve().parent.parent
objects = {}
# Preserve user-owned signing/identity settings across regeneration.
existing_settings = {}
project_file = ROOT / "Folio.xcodeproj/project.pbxproj"
if project_file.exists():
    project_data = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(project_file)]))
    for obj in project_data["objects"].values():
        settings = obj.get("buildSettings", {})
        if settings.get("PRODUCT_BUNDLE_IDENTIFIER") == "com.folio.pdf":
            existing_settings[obj.get("name", "Debug")] = settings


def uid(value):
    return hashlib.sha1(value.encode()).hexdigest()[:24].upper()

def q(value):
    return json.dumps(str(value))

def add(name, body):
    key = uid(name)
    objects[key] = body
    return key

def array(items):
    return "(" + ", ".join(items) + ("," if items else "") + ")"

def config_list(name, base):
    configs = []
    for config in ["Debug", "Release"]:
        settings = dict(base)
        settings.update({"SWIFT_OPTIMIZATION_LEVEL": "-Onone" if config == "Debug" else "-O",
                         "DEBUG_INFORMATION_FORMAT": "dwarf" if config == "Debug" else "dwarf-with-dsym"})
        if config == "Debug":
            settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
            settings["ENABLE_TESTABILITY"] = "YES"
        if name == "Folio":
            old = existing_settings.get(config, {})
            for key in ["DEVELOPMENT_TEAM", "PRODUCT_BUNDLE_IDENTIFIER", "INFOPLIST_KEY_CFBundleDisplayName", "INFOPLIST_KEY_UISupportedInterfaceOrientations"]:
                if key in old:
                    settings[key] = old[key]
        configs.append(add(name + config, "isa = XCBuildConfiguration; name = " + config +
            "; buildSettings = {" + "".join(f"{k} = {q(v)};" for k, v in settings.items()) + "};"))
    return add(name + "Configs", f"isa = XCConfigurationList; buildConfigurations = {array(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

common = {
    "SDKROOT": "iphoneos", "IPHONEOS_DEPLOYMENT_TARGET": "26.0",
    "SWIFT_VERSION": "5.0", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
    "TARGETED_DEVICE_FAMILY": "1", "CODE_SIGN_STYLE": "Automatic",
    "MARKETING_VERSION": "1.0", "CURRENT_PROJECT_VERSION": "1",
    "GENERATE_INFOPLIST_FILE": "YES", "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
    "ENABLE_USER_SCRIPT_SANDBOXING": "YES"
}
products = []
groups = []
targets = []
projectID = uid("project")
appID = uid("Folio")
for name, directory, extension, product_type in [
    ("Folio", "Folio", "app", "application"),
    ("FolioTests", "FolioTests", "xctest", "bundle.unit-test"),
    ("FolioUITests", "FolioUITests", "xctest", "bundle.ui-testing"),
]:
    refs, sources, resources = [], [], []
    for path in sorted((ROOT / directory).rglob("*")):
        if path.suffix not in [".swift", ".xcassets", ".xcprivacy", ".wav", ".mp3"] or any(p.suffix == ".xcassets" for p in path.parents):
            continue
        relative = str(path.relative_to(ROOT))
        filetype = {".swift": "sourcecode.swift", ".xcassets": "folder.assetcatalog", ".xcprivacy": "text.xml", ".wav": "audio.wav", ".mp3": "audio.mp3"}[path.suffix]
        ref = add(relative, f"isa = PBXFileReference; lastKnownFileType = {filetype}; path = {q(relative)}; sourceTree = SOURCE_ROOT;")
        refs.append(ref)
        build = add(relative + "build", f"isa = PBXBuildFile; fileRef = {ref};")
        (sources if path.suffix == ".swift" else resources).append(build)
    groups.append(add(name + "group", f"isa = PBXGroup; name = {q(name)}; children = {array(refs)}; sourceTree = \"<group>\";"))
    phases = []
    for phase, files in [("Sources", sources), ("Frameworks", []), ("Resources", resources)]:
        phases.append(add(name + phase, f"isa = PBX{phase}BuildPhase; buildActionMask = 2147483647; files = {array(files)}; runOnlyForDeploymentPostprocessing = 0;"))
    product = add(name + "product", f"isa = PBXFileReference; explicitFileType = {'wrapper.application' if extension == 'app' else 'wrapper.cfbundle'}; path = {name}.{extension}; sourceTree = BUILT_PRODUCTS_DIR;")
    products.append(product)
    settings = dict(common, PRODUCT_BUNDLE_IDENTIFIER="com.folio.pdf" + ("" if name == "Folio" else "." + name),
                    PRODUCT_NAME="$(TARGET_NAME)", LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/Frameworks @loader_path/Frameworks")
    dependencies = []
    if name == "Folio":
        settings.update(INFOPLIST_FILE="Folio/Info.plist", ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon",
                        CODE_SIGN_ENTITLEMENTS="Folio/Folio.entitlements",
                        INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace="YES",
                        INFOPLIST_KEY_UISupportedInterfaceOrientations="UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight",
                        INFOPLIST_KEY_CFBundleDisplayName="Folio PDF")
    else:
        proxy = add(name + "proxy", f"isa = PBXContainerItemProxy; containerPortal = {projectID}; proxyType = 1; remoteGlobalIDString = {appID}; remoteInfo = Folio;")
        dependencies.append(add(name + "dependency", f"isa = PBXTargetDependency; target = {appID}; targetProxy = {proxy};"))
        if name == "FolioTests":
            settings.update(TEST_HOST="$(BUILT_PRODUCTS_DIR)/Folio.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Folio",
                            BUNDLE_LOADER="$(TEST_HOST)")
        else:
            settings.update(TEST_TARGET_NAME="Folio")
    configs = config_list(name, settings)
    targets.append(add(name, f"isa = PBXNativeTarget; buildConfigurationList = {configs}; buildPhases = {array(phases)}; buildRules = (); dependencies = {array(dependencies)}; name = {name}; productName = {name}; productReference = {product}; productType = \"com.apple.product-type.{product_type}\";"))
productsGroup = add("products", f"isa = PBXGroup; name = Products; children = {array(products)}; sourceTree = \"<group>\";")
main = add("main", f"isa = PBXGroup; children = {array(groups + [productsGroup])}; sourceTree = \"<group>\";")
configs = config_list("project", {"CLANG_ENABLE_MODULES": "YES", "ENABLE_STRICT_OBJC_MSGSEND": "YES"})
add("project", f"isa = PBXProject; attributes = {{LastUpgradeCheck = 2700; BuildIndependentTargetsInParallel = YES;}}; buildConfigurationList = {configs}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {main}; productRefGroup = {productsGroup}; projectDirPath = \"\"; projectRoot = \"\"; targets = {array(targets)};")
project = ROOT / "Folio.xcodeproj"
project.mkdir(exist_ok=True)
(project / "project.pbxproj").write_text("// !$*UTF8*$!\n{\narchiveVersion = 1;\nclasses = {};\nobjectVersion = 56;\nobjects = {\n" +
    "\n".join(f"{key} = {{{value}}};" for key, value in objects.items()) + f"\n}};\nrootObject = {projectID};\n}}\n")
scheme = project / "xcshareddata/xcschemes"
scheme.mkdir(parents=True, exist_ok=True)
def reference(name, ext):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid(name)}" BuildableName="{name}.{ext}" BlueprintName="{name}" ReferencedContainer="container:Folio.xcodeproj"/>'
(scheme / "Folio.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
<BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference("Folio", "app")}</BuildActionEntry>
</BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
<Testables><TestableReference skipped="NO">{reference("FolioTests", "xctest")}</TestableReference><TestableReference skipped="NO">{reference("FolioUITests", "xctest")}</TestableReference></Testables>
</TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES">
<BuildableProductRunnable runnableDebuggingMode="0">{reference("Folio", "app")}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference("Folio", "app")}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print("Generated Folio.xcodeproj")
