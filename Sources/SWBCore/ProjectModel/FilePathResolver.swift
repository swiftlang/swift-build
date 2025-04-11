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
public import SWBMacro
import SWBProtocol

/// A FilePathResolver is used to resolve the absolute paths for Reference objects.
public final class FilePathResolver: Sendable
{
    /// The MacroEvaluationScope used to expand source trees.
    private let scope: MacroEvaluationScope

    /// The evaluated value $(PROJECT_DIR) which is used as the default backstop for source trees which evaluate to relative paths, or to nothing at all.
    private let projectDir: Path

    /// Private table used to cache paths already evaluated for FileGroups.
    private let fileGroupCache = Cache<FileGroup, Path>()

    /// Private table use to cache paths already evaluated for build settings in the MacroEvaluationScope.
    private let buildSettingCache = Cache<MacroDeclaration, Path>()

    public init(scope: MacroEvaluationScope, projectDir: Path? = nil)
    {
        self.scope = scope
        self.projectDir = projectDir ?? scope.evaluate(BuiltinMacros.PROJECT_DIR)

        if let projectDir {
            precondition(projectDir.isAbsolute, "projectDir must be an absolute path but it is \(projectDir)")
        } else {
            precondition(self.projectDir.isAbsolute, "$(PROJECT_DIR) must be an absolute path but it is \(self.projectDir)")
        }
    }

    /// Resolve and return the absolute path for a Reference.
    public func resolveAbsolutePath(_ reference: Reference) -> Path
    {
        // If this is a FileGroup, look it up in the cache.
        if let fileGroup = reference as? FileGroup
        {
            return fileGroupCache.getOrInsert(fileGroup) {
                return computeAbsolutePath(fileGroup)
            }
        }

        return computeAbsolutePath(reference)
    }

    /// Computes the absolute path for a Reference and returns it.  This method does no memoizing of the result, so resolveAbsolutePath() is the preferred client method.
    private func computeAbsolutePath(_ reference: Reference) -> Path
    {
        // Evaluate the path for the reference.
        switch reference
        {
        case let groupTreeReference as GroupTreeReference:
            // A GroupTreeReference has a parent, source tree, and path.  Use those to resolve it.

            // First evaluate the reference's path.  If it is absolute, then we can return it immediately.
            let evaluatedRefPath = self.resolvePath(groupTreeReference.path, forReference: groupTreeReference)
            if evaluatedRefPath.isAbsolute { return evaluatedRefPath.normalize() }

            // Now get absolute path to use as the source tree.
            let sourceTreePath = self.resolveSourceTree(groupTreeReference.sourceTree, forReference: groupTreeReference)

            // The reference's path is relative, to append it to the source tree.
            return sourceTreePath.join(evaluatedRefPath, normalize: true)

        case let productReference as ProductReference:
            // In general a product reference's path is $(TARGET_BUILD_DIR) followed by its name and in install-style builds it is $(BUILT_PRODUCTS_DIR) followed by its name.
            let sourceTreePath: Path
            if scope.evaluate(BuiltinMacros.DEPLOYMENT_LOCATION) {
                sourceTreePath = resolveSourceTree(.buildSetting("BUILT_PRODUCTS_DIR"), forReference: reference)
            } else {
                sourceTreePath = resolveSourceTree(.buildSetting("TARGET_BUILD_DIR"), forReference: reference)
            }

            // FIXME: We are relying on the product reference name being constant here. This is currently true, given how our path resolver works, but it is possible to construct an Xcode project for which this doesn't work (Xcode doesn't, however, handle that situation very well). We should resolve this: <rdar://problem/29410050> Swift Build doesn't support product references with non-constant basenames
            return sourceTreePath.join(productReference.name)

        default:
            preconditionFailure("Cannot resolve the path for a \(type(of: reference))")
        }
    }

    /// Resolve and return the absolute path for a Reference's source tree.  This method will always return an absolute path even if sourceTree is .Absolute, so that it can be prepended to a path even if that path should be absolute but is not.  So the caller should use the result appropriately based on what it will be prepended to.
    func resolveSourceTree(_ sourceTree: SourceTree, forReference reference: Reference) -> Path
    {
        // Resolve the source tree.
        // Note: If the Reference's path is relative, then we want to always append it to something, so we always compute a value for the source tree here, defaulting to $(PROJECT_DIR) if no other value can be determined
        switch sourceTree
        {
        case .absolute:
            // Return the value of $(PROJECT_DIR) as the source root in case the Reference's path is not actually absolute.
            return projectDir

        case .groupRelative:
            // The reference is group-relative, so the source tree is the path of the Reference's parent.
            let parentPath = (reference as? GroupTreeReference)?.parent.map(resolveAbsolutePath)

            // If we couldn't get a path for the parent (e.g., because there isn't a parent), then default to the value of $(PROJECT_DIR).
            return parentPath ?? projectDir

        // Replace SOURCE_ROOT with PROJECT_DIR during reference resolution. (When is SOURCE_ROOT not equal to PROJECT_DIR? -> When SRCROOT is overridden on the command line.) This substitution does not apply to build settings expansion - it only applies to the reference SourceTree.
        case .buildSetting(BuiltinMacros.SOURCE_ROOT.name):
            return projectDir

        case .buildSetting(let buildSetting):
            guard !buildSetting.isEmpty else { return projectDir }

            // Look up the build setting declaration in the scope's namespace.  If it is not defined, then we return the value of $(PROJECT_DIR).
            guard let buildSettingDecl = scope.table.namespace.lookupMacroDeclaration(buildSetting) else { return projectDir }

            // Get or compute the value for the setting.
            return buildSettingCache.getOrInsert(buildSettingDecl) {
                let pathString: String = scope.evaluateAsString(buildSettingDecl)
                var pathForSetting = Path(pathString)

                // If the path for the setting is not absolute, then we append it to the value of $(PROJECT_DIR).
                if !pathForSetting.isAbsolute
                {
                    pathForSetting = projectDir.join(pathForSetting)
                }

                // Use the value as the result.
                return pathForSetting.normalize()
            }
        }
    }

    /// Resolve and return the path for a Reference's path property, evaluating any build settings in it if necessary.
    func resolvePath(_ refPath: MacroStringExpression, forReference reference: Reference) -> Path
    {
        return Path(scope.evaluate(refPath))
    }

}
