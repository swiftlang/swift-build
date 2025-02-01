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

import SWBUtil
import Foundation
public import SWBMacro

extension SDKVariant {
    private func shouldSkip(targetDeviceName: String, productType: ProductTypeSpec?, in scope: MacroEvaluationScope, usingDefaultTargetDeviceIdentifiers: Bool) -> Bool {
        let targetDeviceIdentifierStrings = usingDefaultTargetDeviceIdentifiers ? deviceFamilies.targetDeviceIdentifierStrings : scope.targetedDeviceFamily
        // special case requirement for when device 7 exists, exclude ipad and iphone devices
        let skipIt = (targetDeviceName == "ipad" || targetDeviceName == "iphone") && targetDeviceIdentifierStrings.contains("7") && [11, 12].contains(buildVersionPlatformID)

        // Special case / optimization: by default, don't include iPad assets for Mac Catalyst apps/appexts deploying to 14.0+ if they include Mac assets
        return skipIt
        || (name == MacCatalystInfo.sdkVariantName
            && productType?.onlyPreferredAssets == true
            && ((try? Version(scope.evaluate(BuiltinMacros.IPHONEOS_DEPLOYMENT_TARGET))) ?? Version()) >= Version(14)
            && targetDeviceName == "ipad"
            && targetDeviceIdentifierStrings.contains("6"))
    }

    public func evaluateTargetedDeviceFamilyBuildSetting(_ scope: MacroEvaluationScope, _ productType: ProductTypeSpec?) -> (filteredDeviceIdentifiers: Set<Int>, effectiveDeviceIdentifiers: Set<Int>, effectiveDeviceNames: [String], unexpectedValues: [String]) {
        var unexpectedValues = [String]()

        // int values, filtered to ones supported by the current platform
        let filteredDeviceIdentifiers = Set(scope.targetedDeviceFamily.sorted().compactMap { string -> Int? in
            guard !string.isEmpty else { return nil }
            if let int = Int(string), int != 0 {
                // Platforms with an explicit target device name don't use identifiers at all
                if deviceFamilies.explicitTargetDeviceName != nil {
                    return nil
                }

                // Only add this value to the list if it's actually supported by this platform.
                // That is, we filter out values not associated with the current platform in order to
                // allow TARGETED_DEVICE_FAMILY to contain all possible values in cross platform targets.
                if deviceFamilies.targetDeviceIdentifiers.contains(int) {
                    if let targetDeviceName = deviceFamilies.targetDeviceName(for: int), !targetDeviceName.isEmpty, shouldSkip(targetDeviceName: targetDeviceName, productType: productType, in: scope, usingDefaultTargetDeviceIdentifiers: false) {
                        return nil
                    }

                    return int
                }

                return nil
            } else {
                unexpectedValues.append(string)
                return nil
            }
        })

        // int values we're actually going to use (if we got no values compatible, we use the default set)
        let effectiveDeviceIdentifiers = !filteredDeviceIdentifiers.isEmpty ? filteredDeviceIdentifiers : Set(deviceFamilies.targetDeviceIdentifiers.compactMap { int -> Int? in
            // perform any shouldSkip filtering of values from the default deviceFamilies.targetDeviceIdentifiers set
            if let targetDeviceName = deviceFamilies.targetDeviceName(for: int), !targetDeviceName.isEmpty, shouldSkip(targetDeviceName: targetDeviceName, productType: productType, in: scope, usingDefaultTargetDeviceIdentifiers: true) {
                return nil
            }
            return int
        })

        // string values we're actually going to use (for platforms with an explicit name we use that, otherwise the effective IDs mapped to strings)
        let effectiveDeviceNames = { () -> [String] in
            if let explicitName = deviceFamilies.explicitTargetDeviceName {
                return [explicitName]
            } else {
                return effectiveDeviceIdentifiers.sorted().compactMap { id -> String? in
                    if let name = deviceFamilies.targetDeviceName(for: id), !name.isEmpty {
                        return name
                    }
                    return nil
                }
            }
        }()

        return (filteredDeviceIdentifiers, effectiveDeviceIdentifiers, effectiveDeviceNames, unexpectedValues)
    }
}

fileprivate extension MacroEvaluationScope {
    var targetedDeviceFamily: Set<String> {
        return Set(evaluate(BuiltinMacros.TARGETED_DEVICE_FAMILY).components(separatedBy: CharacterSet(charactersIn: " ,")))
    }
}
