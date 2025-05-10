/// Generate information about a runnable target, including its executable path.
public func generateRunnableInfo(
    for request: SWBBuildRequest,
    targetID: String,
    delegate: any SWBPlanningOperationDelegate
) async throws -> SWBRunnableInfo {
    guard let workspaceContext = self.workspaceContext else {
        throw WorkspaceNotLoadedError()
    }

    guard let target = workspaceContext.workspace.target(for: targetID) else {
        throw TargetNotFoundError(targetID: targetID)
    }

    guard target.type.isExecutable else {
         throw TargetNotRunnableError(targetID: targetID, targetType: target.type)
    }

    guard let project = workspaceContext.workspace.project(for: target) else {
         throw ProjectNotFoundError(targetID: targetID)
     }

    let coreParameters: BuildParameters
    do {
        coreParameters = try BuildParameters(from: request.parameters)
    } catch {
        throw ParameterConversionError(underlyingError: error)
    }

    let buildRequestContext = BuildRequestContext(workspaceContext: workspaceContext)

    let settings = Settings(workspaceContext: workspaceContext, buildRequestContext: buildRequestContext, parameters: coreParameters, project: project, target: target, purpose: .build)

    let scope = settings.globalScope
    let builtProductsDirPath = scope.evaluate(BuiltinMacros.BUILT_PRODUCTS_DIR)
    let executableSubPathString = scope.evaluate(BuiltinMacros.EXECUTABLE_PATH)

    let finalExecutablePath = builtProductsDirPath.join(Path(executableSubPathString))
    let absoluteExecutablePath: AbsolutePath
    do {
         absoluteExecutablePath = try AbsolutePath(validating: finalExecutablePath.str)
    } catch {
        throw PathValidationError(pathString: finalExecutablePath.str, underlyingError: error)
    }

    return SWBRunnableInfo(executablePath: absoluteExecutablePath)
}