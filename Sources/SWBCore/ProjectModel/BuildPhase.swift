//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

public import SWBUtil
public import SWBProtocol
public import SWBMacro

// MARK: Build phase abstract class


public class BuildPhase: ProjectModelItem, @unchecked Sendable
{
    /// The name of the build phase, typically for reporting issues.
    public var name: String { fatalError("abstract \(type(of: self)) build phase asked for its name") }

    /// The GUID of the build phase.
    public let guid: String

    static func create(_ model: SWBProtocol.BuildPhase, _ pifLoader: PIFLoader) -> BuildPhase {
        switch model {
        case let model as SWBProtocol.AppleScriptBuildPhase: return AppleScriptBuildPhase(model, pifLoader)
        case let model as SWBProtocol.CopyFilesBuildPhase: return CopyFilesBuildPhase(model, pifLoader)
        case let model as SWBProtocol.FrameworksBuildPhase: return FrameworksBuildPhase(model, pifLoader)
        case let model as SWBProtocol.HeadersBuildPhase: return HeadersBuildPhase(model, pifLoader)
        case let model as SWBProtocol.JavaArchiveBuildPhase: return JavaArchiveBuildPhase(model, pifLoader)
        case let model as SWBProtocol.ResourcesBuildPhase: return ResourcesBuildPhase(model, pifLoader)
        case let model as SWBProtocol.RezBuildPhase: return RezBuildPhase(model, pifLoader)
        case let model as SWBProtocol.ShellScriptBuildPhase: return ShellScriptBuildPhase(model, pifLoader)
        case let model as SWBProtocol.SourcesBuildPhase: return SourcesBuildPhase(model, pifLoader)
        default:
            fatalError("unexpected model: \(model)")
        }
    }

    init(_ model: SWBProtocol.BuildPhase, _ pifLoader: PIFLoader) {
        self.guid = model.guid
    }

    init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader) throws {
        self.guid = try Self.parseValueForKeyAsString(PIFKey_guid, pifDict: pifDict)
    }

    init(guid: String) {
        self.guid = guid
    }

    /// Parses a ProjectModelItemPIF dictionary as an object of the appropriate subclass of BuildPhase.
    @_spi(Testing) public class func parsePIFDictAsBuildPhase(_ pifDict: ProjectModelItemPIF, pifLoader: PIFLoader) throws -> BuildPhase {
        // Get the type of the reference.  This is required, so if there isn't one then it will die.
        switch try parseValueForKeyAsStringEnum(PIFKey_type, pifDict: pifDict) as PIFBuildPhaseTypeValue {
        case .sources:
            return try SourcesBuildPhase(fromDictionary: pifDict, withPIFLoader: pifLoader)
        case .frameworks:
            return try FrameworksBuildPhase(fromDictionary: pifDict, withPIFLoader: pifLoader)
        case .headers:
            return try HeadersBuildPhase(fromDictionary: pifDict, withPIFLoader: pifLoader)
        case .resources:
            return try ResourcesBuildPhase(fromDictionary: pifDict, withPIFLoader: pifLoader)
        case .copyfiles:
            return try CopyFilesBuildPhase(fromDictionary: pifDict, withPIFLoader: pifLoader)
        case .shellscript:
            return try ShellScriptBuildPhase(fromDictionary: pifDict, withPIFLoader: pifLoader)
        case .rez:
            return try RezBuildPhase(fromDictionary: pifDict, withPIFLoader: pifLoader)
        case .applescript:
            return try AppleScriptBuildPhase(fromDictionary: pifDict, withPIFLoader: pifLoader)
        case .javaarchive:
            return try JavaArchiveBuildPhase(fromDictionary: pifDict, withPIFLoader: pifLoader)
        }
    }

    public var description: String
    {
        return "\(type(of: self))<>"
    }
}


// MARK: Build phase with build files abstract class


public class BuildPhaseWithBuildFiles: BuildPhase, @unchecked Sendable
{
    public let buildFiles: [BuildFile]

    init(_ model: SWBProtocol.BuildPhaseWithBuildFiles, _ pifLoader: PIFLoader)
    {
        buildFiles = model.buildFiles.map{ BuildFile($0, pifLoader) }
        super.init(model, pifLoader)
    }

    override init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader) throws {
        // Build files are required.
        self.buildFiles = try Self.parseValueForKeyAsArrayOfProjectModelItems(PIFKey_BuildPhase_buildFiles, pifDict: pifDict, pifLoader: pifLoader, construct: { try BuildFile(fromDictionary: $0, withPIFLoader: pifLoader) } )

        try super.init(fromDictionary: pifDict, withPIFLoader: pifLoader)
    }

    init(guid: String, buildFiles: [BuildFile]) {
        self.buildFiles = buildFiles
        super.init(guid: guid)
    }

    public func filteredBuildFiles(_ platformFilter: PlatformFilter?) -> [BuildFile] {
        guard let platformFilter else {
            return buildFiles
        }
        return buildFiles.filter({ platformFilter.matches($0.platformFilters) })
    }

    override public var description: String
    {
        return "\(type(of: self))<\(buildFiles.count) files>"
    }

    /// Returns a string that can be used as a suffix for the base name of a derived file in order to make its filename unique. This is based on the file's path but contains only characters that have no special meaning in filenames.  For example, the string will never contain a path separator character.
    public static func filenameUniquefierSuffixFor(path: Path) -> String {
        let digester = InsecureHashContext.init()
        digester.add(string: path.normalize().str)
        return digester.signature.asString
    }
}


// MARK: Sources build phase class


public final class SourcesBuildPhase: BuildPhaseWithBuildFiles, @unchecked Sendable
{
    public override var name: String { return "Compile Sources" }
}


// MARK: Frameworks build phase class


public final class FrameworksBuildPhase: BuildPhaseWithBuildFiles, @unchecked Sendable
{
    public override var name: String { return "Link Binary" }
}


// MARK: Headers build phase class


public final class HeadersBuildPhase: BuildPhaseWithBuildFiles, @unchecked Sendable
{
    public override var name: String { return "Copy Headers" }
}


// MARK: Resources build phase class


public final class ResourcesBuildPhase: BuildPhaseWithBuildFiles, @unchecked Sendable
{
    public override var name: String { return "Copy Bundle Resources" }
}


// MARK: Copy files build phase class


public final class CopyFilesBuildPhase: BuildPhaseWithBuildFiles, @unchecked Sendable
{
    public override var name: String { return "Copy Files" }

    /// The destination subfolder to copy to.  This will commonly be a location relative to `$(TARGET_BUILD_DIR)/$(WRAPPER_NAME)`, but can also be a special indicator such as `<absolute>` or `<builtProductsDir>`.
    public let destinationSubfolder: MacroStringExpression
    /// The subpath relative to the destination subfolder to copy to.  Will often be empty.
    public let destinationSubpath: MacroStringExpression
    /// If `true` then the contents of this phase will only be copied when `$(DEPLOYMENT_POSTPROCESSING)` is enabled.
    public let runOnlyForDeploymentPostprocessing: Bool

    init(_ model: SWBProtocol.CopyFilesBuildPhase, _ pifLoader: PIFLoader)
    {
        var destinationSubfolder = model.destinationSubfolder
        var destinationSubpath = model.destinationSubpath

        // Special case: If this condition is true, then we are dealing with the unfortunate definition for the XPCServices folder, and we want to convert it to a better definition here.  In particular we want to go through $(TARGET_BUILD_DIR) rather than $(BUILT_PRODUCTS_DIR).
        if case .string(let dsf) = destinationSubfolder, dsf == "<builtProductsDir>", case .string(let dsp) = destinationSubpath, dsp == "$(CONTENTS_FOLDER_PATH)/XPCServices" {
            destinationSubfolder = .string("$(XPCSERVICES_FOLDER_PATH)")
            destinationSubpath = .string("")
        }

        self.destinationSubfolder = pifLoader.userNamespace.parseString(destinationSubfolder)
        self.destinationSubpath = pifLoader.userNamespace.parseString(destinationSubpath)
        self.runOnlyForDeploymentPostprocessing = model.runOnlyForDeploymentPostprocessing

        super.init(model, pifLoader)
    }

    override init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader) throws {
        var destinationSubfolder = try Self.parseValueForKeyAsString(PIFKey_BuildPhase_destinationSubfolder, pifDict: pifDict)
        var destinationSubpath = try Self.parseValueForKeyAsString(PIFKey_BuildPhase_destinationSubpath, pifDict: pifDict)

        // Special case: If this condition is true, then we are dealing with the unfortunate definition for the XPCServices folder, and we want to convert it to a better definition here.  In particular we want to go through $(TARGET_BUILD_DIR) rather than $(BUILT_PRODUCTS_DIR).
        if destinationSubfolder == "<builtProductsDir>", destinationSubpath == "$(CONTENTS_FOLDER_PATH)/XPCServices" {
            destinationSubfolder = "$(XPCSERVICES_FOLDER_PATH)"
            destinationSubpath = ""
        }

        self.destinationSubfolder = pifLoader.userNamespace.parseString(destinationSubfolder)
        self.destinationSubpath = pifLoader.userNamespace.parseString(destinationSubpath)
        self.runOnlyForDeploymentPostprocessing = try Self.parseValueForKeyAsBool(PIFKey_BuildPhase_runOnlyForDeploymentPostprocessing, pifDict: pifDict)

        try super.init(fromDictionary: pifDict, withPIFLoader: pifLoader)
    }

    public init(guid: String, buildFiles: [BuildFile], destinationSubfolder: MacroStringExpression, destinationSubpath: MacroStringExpression, runOnlyForDeploymentPostprocessing: Bool) {
        self.destinationSubfolder = destinationSubfolder
        self.destinationSubpath = destinationSubpath
        self.runOnlyForDeploymentPostprocessing = runOnlyForDeploymentPostprocessing
        super.init(guid: guid, buildFiles: buildFiles)
    }
}


// MARK: Shell script build phase class


public final class ShellScriptBuildPhase: BuildPhase, @unchecked Sendable
{
    public override var name: String { return _name.isEmpty ? "Run Script" : _name }

    /// The name of the shell script phase.
    private let _name: String

    /// The path of the shell interpreter to run.
    public let shellPath: MacroStringExpression

    /// The shell script itself.
    public let scriptContents: String

    /// The original object ID for this phase. This is used to represent the phase in console output.
    public let originalObjectID: String

    /// The list of input file paths.
    public let inputFilePaths: [MacroStringExpression]

    /// The list of input file list paths.
    public let inputFileListPaths: [MacroStringExpression]

    /// The list of output file paths.
    public let outputFilePaths: [MacroStringExpression]

    /// The list of output file list paths.
    public let outputFileListPaths: [MacroStringExpression]

    /// Whether the environment should be logged as part of running the shell script.
    public let emitEnvironment: Bool

    /// Override passed by clients to force-{disable,enable} sandboxing
    public let sandboxingOverride: SWBProtocol.SandboxingOverride

    /// Whether the shell script should only be run when doing deployment postprocessing.
    public let runOnlyForDeploymentPostprocessing: Bool

    /// The dependency info format
    public let dependencyInfo: DependencyInfoFormat?

    /// Allows Script task to execute on every build.
    public let alwaysOutOfDate: Bool

    /// Whether the script phase is configured to run based on dependency analysis and meets the minimum dependency specification requirements (at least one output)
    public var hasSpecifiedDependencies: Bool {
        (outputFilePaths.count + outputFileListPaths.count) > 0 && !alwaysOutOfDate
    }

    /// Whether the script phase should also run for `installhdrs` and `installapi` builds, regardless of what `INSTALLHDRS_SCRIPT_PHASE` is set to.
    public let alwaysRunForInstallHdrs: Bool

    init(_ model: SWBProtocol.ShellScriptBuildPhase, _ pifLoader: PIFLoader)
    {
        _name = model.name
        // FIXME: This should be a string list, but this matches PBXBuild. Also, this shouldn't ever be a Path.
        shellPath = pifLoader.userNamespace.parseString(model.shellPath.str)
        scriptContents = model.scriptContents
        originalObjectID = model.originalObjectID
        inputFilePaths = model.inputFilePaths.map{ pifLoader.userNamespace.parseString($0) }
        inputFileListPaths = model.inputFileListPaths.map{ pifLoader.userNamespace.parseString($0) }
        outputFilePaths = model.outputFilePaths.map{ pifLoader.userNamespace.parseString($0) }
        outputFileListPaths = model.outputFileListPaths.map{ pifLoader.userNamespace.parseString($0) }
        emitEnvironment = model.emitEnvironment
        sandboxingOverride = model.sandboxingOverride
        runOnlyForDeploymentPostprocessing = model.runOnlyForDeploymentPostprocessing
        dependencyInfo = DependencyInfoFormat.fromPIF(model.dependencyInfo, pifLoader: pifLoader)
        alwaysOutOfDate = model.alwaysOutOfDate
        alwaysRunForInstallHdrs = model.alwaysRunForInstallHdrs
        super.init(model, pifLoader)
    }

    override init(fromDictionary pifDict: ProjectModelItemPIF, withPIFLoader pifLoader: PIFLoader) throws {
        // Phase name is required (but we allow it to be missing until all PIFs are updated).
        self._name = try Self.parseOptionalValueForKeyAsString(PIFKey_BuildPhase_name, pifDict: pifDict) ?? "<FIXME>"

        // Shell path is required.
        self.shellPath = try pifLoader.userNamespace.parseString(Self.parseValueForKeyAsString(PIFKey_BuildPhase_shellPath, pifDict: pifDict))

        // Script contents is required.
        self.scriptContents = try Self.parseValueForKeyAsString(PIFKey_BuildPhase_scriptContents, pifDict: pifDict)

        // Original object ID is required (but we allow it to be missing until all PIFs are updated).
        self.originalObjectID = try Self.parseOptionalValueForKeyAsString(PIFKey_BuildPhase_originalObjectID, pifDict: pifDict) ?? "<FIXME>"

        // Input file paths is required.
        self.inputFilePaths = try Self.parseValueForKeyAsArrayOfStrings(PIFKey_BuildPhase_inputFilePaths, pifDict: pifDict).map({ return pifLoader.userNamespace.parseString($0) })

        // Input file list paths is required  (but we allow it to be missing until all PIFs are updated).
        self.inputFileListPaths = try (Self.parseOptionalValueForKeyAsArrayOfStrings(PIFKey_BuildPhase_inputFileListPaths, pifDict: pifDict) ?? []).map({ return pifLoader.userNamespace.parseString($0) })

        // Output file paths is required.
        self.outputFilePaths = try Self.parseValueForKeyAsArrayOfStrings(PIFKey_BuildPhase_outputFilePaths, pifDict: pifDict).map({ return pifLoader.userNamespace.parseString($0) })

        // Output file list paths is required (but we allow it to be missing until all PIFs are updated).
        self.outputFileListPaths = try (Self.parseOptionalValueForKeyAsArrayOfStrings(PIFKey_BuildPhase_outputFileListPaths, pifDict: pifDict) ?? []).map({ return pifLoader.userNamespace.parseString($0) })

        // Run only for deployment postprocessing is required.
        self.emitEnvironment = try Self.parseValueForKeyAsBool(PIFKey_BuildPhase_emitEnvironment, pifDict: pifDict)

        // Force-{disable,enable} sandboxing for this phase (optional, default fallback: value of ENABLE_USER_SCRIPT_SANDBOXING)
        if let sandboxingOverride = try Self.parseOptionalValueForKeyAsStringEnum(PIFKey_BuildPhase_sandboxingOverride, pifDict: pifDict) as PIFSandboxingOverrideValue? {
            switch sandboxingOverride {
            case .basedOnBuildSetting:
                self.sandboxingOverride = .basedOnBuildSetting
            case .forceDisabled:
                self.sandboxingOverride = .forceDisabled
            case .forceEnabled:
                self.sandboxingOverride = .forceEnabled
            }
        } else {
            self.sandboxingOverride = .basedOnBuildSetting
        }

        // Run only for deployment postprocessing is required.
        self.runOnlyForDeploymentPostprocessing = try Self.parseValueForKeyAsBool(PIFKey_BuildPhase_runOnlyForDeploymentPostprocessing, pifDict: pifDict)

        if let format = try Self.parseOptionalValueForKeyAsStringEnum(PIFKey_BuildPhase_dependencyFileFormat, pifDict: pifDict) as PIFDependencyFormatValue? {
            let dependencyFilePaths = try Self.parseValueForKeyAsArrayOfStrings(PIFKey_BuildPhase_dependencyFilePaths, pifDict: pifDict).map({ return pifLoader.userNamespace.parseString($0) })

            switch format {
            case .dependencyInfo:
                guard dependencyFilePaths.count == 1 else {
                    throw PIFParsingError.custom("BuildPhase dependencyInfo dependency format expects 1 dependency file path, found \(dependencyFilePaths.count)")
                }
                self.dependencyInfo = .dependencyInfo(dependencyFilePaths[0])
            case .makefile:
                guard dependencyFilePaths.count == 1 else {
                    throw PIFParsingError.custom("BuildPhase makefile dependency format expects 1 dependency file path, found \(dependencyFilePaths.count)")
                }
                self.dependencyInfo = .makefile(dependencyFilePaths[0])
            case .makefiles:
                self.dependencyInfo = .makefiles(dependencyFilePaths)
            }
        } else {
            dependencyInfo = nil
        }

        self.alwaysOutOfDate = try Self.parseValueForKeyAsBool(PIFKey_BuildPhase_alwaysOutOfDate, pifDict: pifDict)

        // Whether to always run for install{hdrs,api}, regardless of `INSTALLHDRS_SCRIPT_PHASE`, is optional; defaults to false.
        self.alwaysRunForInstallHdrs = try Self.parseValueForKeyAsBool(PIFKey_BuildPhase_alwaysRunForInstallHdrs, pifDict: pifDict)

        try super.init(fromDictionary: pifDict, withPIFLoader: pifLoader)
    }
}


// MARK: Rez build phase class


public final class RezBuildPhase: BuildPhaseWithBuildFiles, @unchecked Sendable
{
    public override var name: String { return "Build Carbon Resources" }
}


// MARK: AppleScript build phase class


public final class AppleScriptBuildPhase: BuildPhaseWithBuildFiles, @unchecked Sendable
{
    public override var name: String { return "Compile AppleScript Files" }
}


// MARK: Java archive build phase class


public final class JavaArchiveBuildPhase: BuildPhaseWithBuildFiles, @unchecked Sendable
{
    public override var name: String { return "Build Java Resources" }
}
