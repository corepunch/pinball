#!/usr/bin/env python3
"""Writes Pinball.xcodeproj. Source folders are file-system-synchronized groups, so
new .m/.h files appear in Xcode with no project edit. Run once; re-run if targets change."""
import hashlib, os, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent

def uid(name):
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()

def sync_group(path):
    return f"""\t\t{uid('group:'+path)} /* {path} */ = {{
\t\t\tisa = PBXFileSystemSynchronizedRootGroup;
\t\t\tpath = {path};
\t\t\tsourceTree = "<group>";
\t\t}};
"""

TARGETS = [
    dict(name="Pinball", product="Pinball.app", type="com.apple.product-type.application",
         groups=["App"], resources=True,
         settings={
             "SDKROOT": "iphoneos", "TARGETED_DEVICE_FAMILY": "1", "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
             "SUPPORTS_MACCATALYST": "NO", "SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD": "NO",
             "PRODUCT_NAME": "Pinball", "PRODUCT_BUNDLE_IDENTIFIER": "com.igorchernakov.pinball",
             "GENERATE_INFOPLIST_FILE": "YES", "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "1.0",
             "INFOPLIST_KEY_UILaunchScreen_Generation": "YES",
             "INFOPLIST_KEY_UIApplicationSceneManifest_Generation": "YES",
             "INFOPLIST_KEY_UIStatusBarHidden": "YES",
             "INFOPLIST_KEY_UIRequiresFullScreen": "YES",
             "INFOPLIST_KEY_UISupportedInterfaceOrientations": "UIInterfaceOrientationPortrait",
             "INFOPLIST_KEY_CFBundleDisplayName": "Pinball",
             "LD_RUNPATH_SEARCH_PATHS": '"@executable_path/Frameworks"',
             "ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS": "NO",
             "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
             "CODE_SIGN_ENTITLEMENTS": "Config/Pinball.entitlements",
             "OTHER_LDFLAGS": '("$(inherited)", "-framework", GameKit, "-framework", SpriteKit)',
         }),
    dict(name="PinballCoreTests", product="PinballCoreTests.xctest", type="com.apple.product-type.bundle.unit-test",
         groups=["App/Core", "App/GameCenter/Scoring", "App/UI/Model", "Tests"], resources=False,
         settings={
             "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0",
             "PRODUCT_NAME": "PinballCoreTests", "PRODUCT_BUNDLE_IDENTIFIER": "com.igorchernakov.pinball.tests",
             "GENERATE_INFOPLIST_FILE": "YES", "CODE_SIGN_IDENTITY": '"-"',
             "HEADER_SEARCH_PATHS": '"$(SRCROOT)/App/Core"',
         }),
]

COMMON = {
    "ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ENABLE_OBJC_ARC": "YES", "CLANG_ENABLE_MODULES": "YES",
    "GCC_C_LANGUAGE_STANDARD": "gnu17", "CLANG_WARN_UNREACHABLE_CODE": "YES", "GCC_WARN_UNUSED_VARIABLE": "YES",
    "COPY_PHASE_STRIP": "NO", "DEBUG_INFORMATION_FORMAT": "dwarf",
    "CLANG_CXX_LANGUAGE_STANDARD": '"gnu++20"',
    "CODE_SIGN_STYLE": "Automatic",
}

def settings_block(d, indent="\t\t\t\t"):
    return "".join(f"{indent}{k} = {v};\n" for k, v in sorted(d.items()))

def config(name, build, settings):
    return f"""\t\t{uid(name)} /* {build} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{settings_block(settings)}\t\t\t}};
\t\t\tname = {build};
\t\t}};
"""

objs = {k: "" for k in ("groups", "products", "phases", "targets", "configs", "lists", "buildfiles", "main", "sync")}

group_paths = sorted({g for t in TARGETS for g in t["groups"]})
# The app compiles its whole tree; tests compile only the selected logic modules.
for p in group_paths:
    objs["sync"] += sync_group(p)

resources_ref = uid("ref:resources")
products_children = ""
target_ids = ""
for t in TARGETS:
    n = t["name"]
    tid, prod = uid("target:" + n), uid("product:" + n)
    src, res = uid("sources:" + n), uid("resources:" + n)
    products_children += f"\t\t\t\t{prod} /* {t['product']} */,\n"
    target_ids += f"\t\t\t\t{tid} /* {n} */,\n"
    ext = "wrapper.application" if t["product"].endswith(".app") else "wrapper.cfbundle"
    objs["products"] += f'\t\t{prod} /* {t["product"]} */ = {{isa = PBXFileReference; explicitFileType = {ext}; includeInIndex = 0; path = "{t["product"]}"; sourceTree = BUILT_PRODUCTS_DIR; }};\n'
    objs["phases"] += f"\t\t{src} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n"
    res_files = ""
    if t["resources"]:
        bf = uid("bf:res:" + n)
        objs["buildfiles"] += f"\t\t{bf} /* Resources in Resources */ = {{isa = PBXBuildFile; fileRef = {resources_ref} /* Resources */; }};\n"
        res_files = f"\t\t\t\t{bf} /* Resources in Resources */,\n"
    objs["phases"] += f"\t\t{res} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n{res_files}\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n"
    groups = "".join(f"\t\t\t\t{uid('group:'+g)} /* {g} */,\n" for g in t["groups"])
    # Test groups reference the same source files without compiling the app host.
    objs["targets"] += f"""\t\t{tid} /* {n} */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {uid('list:'+n)};
\t\t\tbuildPhases = (
\t\t\t\t{src} /* Sources */,
\t\t\t\t{res} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tfileSystemSynchronizedGroups = (
{groups}\t\t\t);
\t\t\tname = {n};
\t\t\tproductName = {n};
\t\t\tproductReference = {prod} /* {t['product']} */;
\t\t\tproductType = "{t['type']}";
\t\t}};
"""
    s = dict(t["settings"])
    for b in ("Debug", "Release"):
        objs["configs"] += config(f"cfg:{n}:{b}", b, s)
    objs["lists"] += f"""\t\t{uid('list:'+n)} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{uid(f'cfg:{n}:Debug')} /* Debug */,
\t\t\t\t{uid(f'cfg:{n}:Release')} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Debug;
\t\t}};
"""

debug = dict(COMMON, ONLY_ACTIVE_ARCH="YES", GCC_OPTIMIZATION_LEVEL="1", ENABLE_TESTABILITY="YES",
             GCC_PREPROCESSOR_DEFINITIONS='("DEBUG=1", "$(inherited)")')
release = dict(COMMON, GCC_OPTIMIZATION_LEVEL="s", ENABLE_NS_ASSERTIONS="NO", VALIDATE_PRODUCT="YES",
               DEBUG_INFORMATION_FORMAT='"dwarf-with-dsym"')
objs["configs"] += config("cfg:proj:Debug", "Debug", debug) + config("cfg:proj:Release", "Release", release)
objs["lists"] += f"""\t\t{uid('list:proj')} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{uid('cfg:proj:Debug')} /* Debug */,
\t\t\t\t{uid('cfg:proj:Release')} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Debug;
\t\t}};
"""

main_children = "".join(f"\t\t\t\t{uid('group:'+g)} /* {g} */,\n" for g in group_paths)
game_center_targets = "".join(
    f"\t\t\t\t\t{uid('target:'+t['name'])} = {{SystemCapabilities = {{com.apple.GameCenter = {{enabled = 1; }}; }}; }};\n"
    for t in TARGETS if t["resources"]
)
pbx = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{
\t}};
\tobjectVersion = 77;
\tobjects = {{

/* Begin PBXBuildFile section */
{objs['buildfiles']}/* End PBXBuildFile section */

/* Begin PBXFileReference section */
\t\t{resources_ref} /* GameData */ = {{isa = PBXFileReference; lastKnownFileType = folder; name = GameData; path = GameData; sourceTree = "<group>"; }};
{objs['products']}/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
{objs['sync']}/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXGroup section */
\t\t{uid('group:main')} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{main_children}\t\t\t\t{resources_ref} /* Resources */,
\t\t\t\t{uid('group:products')} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{uid('group:products')} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{products_children}\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
{objs['targets']}/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{uid('project')} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tTargetAttributes = {{
{game_center_targets}\t\t\t\t}};
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastUpgradeCheck = 2700;
\t\t\t}};
\t\t\tbuildConfigurationList = {uid('list:proj')};
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {uid('group:main')};
\t\t\tminimizedProjectReferenceProxies = 1;
\t\t\tpreferredProjectObjectVersion = 77;
\t\t\tproductRefGroup = {uid('group:products')} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
{target_ids}\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase / PBXSourcesBuildPhase section */
{objs['phases']}/* End build phases */

/* Begin XCBuildConfiguration section */
{objs['configs']}/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
{objs['lists']}/* End XCConfigurationList section */
\t}};
\trootObject = {uid('project')} /* Project object */;
}}
"""
proj = ROOT / "Pinball.xcodeproj"
proj.mkdir(exist_ok=True)
(proj / "project.pbxproj").write_text(pbx)
print("wrote", proj)
