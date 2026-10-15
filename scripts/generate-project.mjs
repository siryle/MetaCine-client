#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const projectDir = path.join(root, "MetaCine.xcodeproj");
const id = (key) => crypto.createHash("sha256").update(key).digest("hex").slice(0, 24).toUpperCase();
const quote = (value) => JSON.stringify(String(value));
const objects = [];
const add = (key, isa, fields) => {
  objects.push(`\t\t${id(key)} = {\n\t\t\tisa = ${isa};\n${fields.map(([name, value]) => `\t\t\t${name} = ${value};`).join("\n")}\n\t\t};`);
  return id(key);
};
const list = (values) => `(${values.map((value) => `\n\t\t\t\t${value},`).join("")}\n\t\t\t)`;
const settings = (values) => `{\n${Object.entries(values).map(([key, value]) => `\t\t\t\t${key} = ${quote(value)};`).join("\n")}\n\t\t\t}`;

function swiftFiles(directory) {
  return fs.readdirSync(path.join(root, directory), { withFileTypes: true })
    .flatMap((entry) => entry.isDirectory() ? swiftFiles(`${directory}/${entry.name}`) :
      entry.name.endsWith(".swift") ? [`${directory}/${entry.name}`] : [])
    .sort();
}
const appSources = swiftFiles("MetaCine");
const testSources = swiftFiles("MetaCineTests");
const refs = new Map();
for (const source of [...appSources, ...testSources]) {
  const ref = add(`file:${source}`, "PBXFileReference", [
    ["lastKnownFileType", "sourcecode.swift"], ["path", quote(source)], ["sourceTree", quote("<group>")],
  ]);
  refs.set(source, ref);
  add(`build:${source}`, "PBXBuildFile", [["fileRef", ref]]);
}
const assets = add("assets", "PBXFileReference", [
  ["lastKnownFileType", "folder.assetcatalog"], ["path", quote("MetaCine/Resources/Assets.xcassets")],
  ["sourceTree", quote("<group>")],
]);
const plist = add("plist", "PBXFileReference", [
  ["lastKnownFileType", "text.plist.xml"], ["path", quote("MetaCine/Resources/Info.plist")],
  ["sourceTree", quote("<group>")],
]);
add("build:assets", "PBXBuildFile", [["fileRef", assets]]);
const appProduct = add("product:app", "PBXFileReference", [
  ["explicitFileType", "wrapper.application"], ["includeInIndex", "0"],
  ["path", quote("MetaCine.app")], ["sourceTree", "BUILT_PRODUCTS_DIR"],
]);
const testProduct = add("product:tests", "PBXFileReference", [
  ["explicitFileType", "wrapper.cfbundle"], ["includeInIndex", "0"],
  ["path", quote("MetaCineTests.xctest")], ["sourceTree", "BUILT_PRODUCTS_DIR"],
]);
const products = add("products", "PBXGroup", [
  ["children", list([appProduct, testProduct])], ["name", quote("Products")], ["sourceTree", quote("<group>")],
]);
const appGroup = add("group:app", "PBXGroup", [
  ["children", list([...appSources.map((file) => refs.get(file)), assets, plist])],
  ["name", quote("MetaCine")], ["sourceTree", quote("<group>")],
]);
const testGroup = add("group:tests", "PBXGroup", [
  ["children", list(testSources.map((file) => refs.get(file)))],
  ["name", quote("MetaCineTests")], ["sourceTree", quote("<group>")],
]);
add("rootGroup", "PBXGroup", [
  ["children", list([appGroup, testGroup, products])], ["sourceTree", quote("<group>")],
]);
for (const [name, files] of [["app", appSources], ["tests", testSources]]) {
  add(`sources:${name}`, "PBXSourcesBuildPhase", [
    ["buildActionMask", "2147483647"], ["files", list(files.map((file) => id(`build:${file}`)))],
    ["runOnlyForDeploymentPostprocessing", "0"],
  ]);
  add(`frameworks:${name}`, "PBXFrameworksBuildPhase", [
    ["buildActionMask", "2147483647"], ["files", "()"], ["runOnlyForDeploymentPostprocessing", "0"],
  ]);
  add(`resources:${name}`, "PBXResourcesBuildPhase", [
    ["buildActionMask", "2147483647"], ["files", name === "app" ? list([id("build:assets")]) : "()"],
    ["runOnlyForDeploymentPostprocessing", "0"],
  ]);
}
const common = {
  CLANG_ENABLE_MODULES: "YES", CLANG_ENABLE_OBJC_ARC: "YES", CLANG_WARN_DOCUMENTATION_COMMENTS: "YES",
  CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER: "YES", GCC_C_LANGUAGE_STANDARD: "gnu17",
  IPHONEOS_DEPLOYMENT_TARGET: "17.0", SDKROOT: "iphoneos", SWIFT_VERSION: "5.0",
  SWIFT_STRICT_CONCURRENCY: "targeted", ENABLE_USER_SCRIPT_SANDBOXING: "YES",
};
const app = {
  PRODUCT_NAME: "$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER: "app.metacine.ios",
  INFOPLIST_FILE: "MetaCine/Resources/Info.plist", GENERATE_INFOPLIST_FILE: "NO",
  MARKETING_VERSION: "1.0.0", CURRENT_PROJECT_VERSION: "1", TARGETED_DEVICE_FAMILY: "1",
  SUPPORTS_MACCATALYST: "NO", SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: "NO",
  SUPPORTED_PLATFORMS: "iphoneos iphonesimulator", CODE_SIGN_STYLE: "Automatic",
  ASSETCATALOG_COMPILER_APPICON_NAME: "AppIcon", ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: "AccentColor",
  LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/Frameworks",
  ENABLE_PREVIEWS: "YES", SWIFT_EMIT_LOC_STRINGS: "YES",
};
const tests = {
  PRODUCT_NAME: "$(TARGET_NAME)", PRODUCT_BUNDLE_IDENTIFIER: "app.metacine.ios.tests",
  GENERATE_INFOPLIST_FILE: "YES", TARGETED_DEVICE_FAMILY: "1",
  SUPPORTED_PLATFORMS: "iphoneos iphonesimulator",
  TEST_HOST: "$(BUILT_PRODUCTS_DIR)/MetaCine.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/MetaCine",
  BUNDLE_LOADER: "$(TEST_HOST)", LD_RUNPATH_SEARCH_PATHS: "$(inherited) @executable_path/Frameworks @loader_path/Frameworks",
};
for (const [name, values] of [["project", common], ["app", app], ["tests", tests]]) {
  for (const configuration of ["Debug", "Release"]) {
    const optimization = name === "project" ? configuration === "Debug" ? {
      DEBUG_INFORMATION_FORMAT: "dwarf", ENABLE_TESTABILITY: "YES", GCC_OPTIMIZATION_LEVEL: "0",
      SWIFT_ACTIVE_COMPILATION_CONDITIONS: "DEBUG $(inherited)", SWIFT_OPTIMIZATION_LEVEL: "-Onone",
    } : {
      DEBUG_INFORMATION_FORMAT: "dwarf-with-dsym", SWIFT_COMPILATION_MODE: "wholemodule", SWIFT_OPTIMIZATION_LEVEL: "-O",
    } : {};
    add(`config:${name}:${configuration}`, "XCBuildConfiguration", [
      ["buildSettings", settings({ ...values, ...optimization })], ["name", quote(configuration)],
    ]);
  }
  add(`configs:${name}`, "XCConfigurationList", [
    ["buildConfigurations", list(["Debug", "Release"].map((value) => id(`config:${name}:${value}`)))],
    ["defaultConfigurationIsVisible", "0"], ["defaultConfigurationName", quote("Release")],
  ]);
}
add("proxy", "PBXContainerItemProxy", [
  ["containerPortal", id("project")], ["proxyType", "1"], ["remoteGlobalIDString", id("target:app")],
  ["remoteInfo", quote("MetaCine")],
]);
add("dependency", "PBXTargetDependency", [["target", id("target:app")], ["targetProxy", id("proxy")]]);
for (const [name, targetName, product] of [["app", "MetaCine", appProduct], ["tests", "MetaCineTests", testProduct]]) {
  add(`target:${name}`, "PBXNativeTarget", [
    ["buildConfigurationList", id(`configs:${name}`)],
    ["buildPhases", list(["sources", "frameworks", "resources"].map((phase) => id(`${phase}:${name}`)))],
    ["buildRules", "()"], ["dependencies", name === "tests" ? list([id("dependency")]) : "()"],
    ["name", quote(targetName)], ["productName", quote(targetName)], ["productReference", product],
    ["productType", quote(name === "app" ? "com.apple.product-type.application" : "com.apple.product-type.bundle.unit-test")],
  ]);
}
add("project", "PBXProject", [
  ["attributes", "{ LastUpgradeCheck = 1600; BuildIndependentTargetsInParallel = YES; }"],
  ["buildConfigurationList", id("configs:project")], ["compatibilityVersion", quote("Xcode 14.0")],
  ["developmentRegion", quote("zh_CN")], ["hasScannedForEncodings", "0"],
  ["knownRegions", list([quote("en"), quote("zh-Hans"), quote("Base")])],
  ["mainGroup", id("rootGroup")], ["productRefGroup", products],
  ["projectDirPath", quote("")], ["projectRoot", quote("")],
  ["targets", list([id("target:app"), id("target:tests")])],
]);
const pbx = `// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n${objects.join("\n")}\n\t};\n\trootObject = ${id("project")};\n}\n`;
fs.mkdirSync(projectDir, { recursive: true });
fs.writeFileSync(path.join(projectDir, "project.pbxproj"), pbx);
const schemes = path.join(projectDir, "xcshareddata", "xcschemes");
fs.mkdirSync(schemes, { recursive: true });
const ref = (name, targetName) => `<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${id(`target:${name}`)}" BuildableName="${targetName}.${name === "app" ? "app" : "xctest"}" BlueprintName="${targetName}" ReferencedContainer="container:MetaCine.xcodeproj"/>`;
const scheme = `<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">${ref("app", "MetaCine")}</BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables><TestableReference skipped="NO">${ref("tests", "MetaCineTests")}</TestableReference></Testables>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
    <BuildableProductRunnable runnableDebuggingMode="0">${ref("app", "MetaCine")}</BuildableProductRunnable>
  </LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">${ref("app", "MetaCine")}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
`;
fs.writeFileSync(path.join(schemes, "MetaCine.xcscheme"), scheme);
console.log(`Generated Xcode project: ${appSources.length} app sources, ${testSources.length} test sources.`);
