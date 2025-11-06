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

import Foundation
import Testing
import SWBTestSupport
import SWBUtil
@Suite(.skipHostOS(.windows))
fileprivate struct LinuxDistributionTests {

    /// Test helper to create a mock filesystem with specific files
    private func withMockLinuxDistribution<T>(
        osReleaseContent: String? = nil,
        distributionFiles: [String: String] = [:],
        operation: (PseudoFS) async throws -> T
    ) async throws -> T {
        let fs = PseudoFS()

        // Create /etc directory
        try fs.createDirectory(Path("/etc"), recursive: true)

        // Add /etc/os-release if provided
        if let content = osReleaseContent {
            try fs.write(Path("/etc/os-release"), contents: ByteString(encodingAsUTF8: content))
        }

        // Add distribution-specific files
        for (filePath, content) in distributionFiles {
            try fs.write(Path(filePath), contents: ByteString(encodingAsUTF8: content))
        }

        return try await operation(fs)
    }

    /// Test parsing various /etc/os-release formats for different distributions
    @Test
    func detectUbuntuFromOSRelease() async throws {
        let osReleaseContent = """
        NAME="Ubuntu"
        VERSION="22.04.3 LTS (Jammy Jellyfish)"
        ID=ubuntu
        ID_LIKE=debian
        PRETTY_NAME="Ubuntu 22.04.3 LTS"
        VERSION_ID="22.04"
        HOME_URL="https://www.ubuntu.com/"
        SUPPORT_URL="https://help.ubuntu.com/"
        BUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"
        PRIVACY_POLICY_URL="https://www.ubuntu.com/legal/terms-and-policies/privacy-policy"
        VERSION_CODENAME=jammy
        UBUNTU_CODENAME=jammy
        """

        try await withMockLinuxDistribution(osReleaseContent: osReleaseContent) { fs in
            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            let ubuntuDist = try #require(distribution)
            #expect(ubuntuDist.kind == .ubuntu)
            #expect(ubuntuDist.version == "22.04")
            #expect(ubuntuDist.displayName == "Ubuntu 22.04")
        }
    }

    @Test
    func detectDebianFromOSRelease() async throws {
        let osReleaseContent = """
        PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
        NAME="Debian GNU/Linux"
        VERSION_ID="12"
        VERSION="12 (bookworm)"
        VERSION_CODENAME=bookworm
        ID=debian
        HOME_URL="https://www.debian.org/"
        SUPPORT_URL="https://www.debian.org/support"
        BUG_REPORT_URL="https://bugs.debian.org/"
        """

        try await withMockLinuxDistribution(osReleaseContent: osReleaseContent) { fs in
            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            let debianDist = try #require(distribution)
            #expect(debianDist.kind == .debian)
            #expect(debianDist.version == "12")
            #expect(debianDist.displayName == "Debian 12")
        }
    }

    @Test
    func detectFedoraFromOSRelease() async throws {
        let osReleaseContent = """
        NAME="Fedora Linux"
        VERSION="39 (Workstation Edition)"
        ID=fedora
        VERSION_ID=39
        VERSION_CODENAME=""
        PLATFORM_ID="platform:f39"
        PRETTY_NAME="Fedora Linux 39 (Workstation Edition)"
        ANSI_COLOR="0;38;2;60;110;180"
        LOGO=fedora-logo-icon
        CPE_NAME="cpe:/o:fedoraproject:fedora:39"
        DEFAULT_HOSTNAME="fedora"
        HOME_URL="https://fedoraproject.org/"
        DOCUMENTATION_URL="https://docs.fedoraproject.org/en-US/fedora/f39/system-administrators-guide/"
        SUPPORT_URL="https://ask.fedoraproject.org/"
        BUG_REPORT_URL="https://bugzilla.redhat.com/"
        REDHAT_BUGZILLA_PRODUCT="Fedora"
        REDHAT_BUGZILLA_PRODUCT_VERSION=39
        REDHAT_SUPPORT_PRODUCT="Fedora"
        REDHAT_SUPPORT_PRODUCT_VERSION=39
        SUPPORT_END=2024-11-12
        VARIANT="Workstation Edition"
        VARIANT_ID=workstation
        """

        try await withMockLinuxDistribution(osReleaseContent: osReleaseContent) { fs in
            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            let fedoraDist = try #require(distribution)
            #expect(fedoraDist.kind == .fedora)
            #expect(fedoraDist.version == "39")
            #expect(fedoraDist.displayName == "Fedora 39")
        }
    }

    @Test
    func detectAmazonLinuxFromOSRelease() async throws {
        let osReleaseContent = """
        NAME="Amazon Linux"
        VERSION="2023"
        ID="amzn"
        ID_LIKE="fedora"
        VERSION_ID="2023"
        PLATFORM_ID="platform:al2023"
        PRETTY_NAME="Amazon Linux 2023"
        ANSI_COLOR="0;33"
        CPE_NAME="cpe:2.3:o:amazon:amazon_linux:2023"
        HOME_URL="https://aws.amazon.com/linux/"
        BUG_REPORT_URL="https://github.com/amazonlinux/amazon-linux-2023"
        SUPPORT_END="2028-03-15"
        """

        try await withMockLinuxDistribution(osReleaseContent: osReleaseContent) { fs in
            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            let amazonDist = try #require(distribution)
            #expect(amazonDist.kind == .amazon)
            #expect(amazonDist.version == "2023")
            #expect(amazonDist.displayName == "Amazon Linux 2023")
        }
    }

    @Test
    func detectRHELFromOSRelease() async throws {
        let osReleaseContent = """
        NAME="Red Hat Enterprise Linux"
        VERSION="9.3 (Plow)"
        ID="rhel"
        ID_LIKE="fedora"
        VERSION_ID="9.3"
        PLATFORM_ID="platform:el9"
        PRETTY_NAME="Red Hat Enterprise Linux 9.3 (Plow)"
        ANSI_COLOR="0;31"
        CPE_NAME="cpe:/o:redhat:enterprise_linux:9::baseos"
        HOME_URL="https://www.redhat.com/"
        DOCUMENTATION_URL="https://access.redhat.com/documentation/red_hat_enterprise_linux/9/"
        BUG_REPORT_URL="https://bugzilla.redhat.com/"
        REDHAT_BUGZILLA_PRODUCT="Red Hat Enterprise Linux 9"
        REDHAT_BUGZILLA_PRODUCT_VERSION=9.3
        REDHAT_SUPPORT_PRODUCT="Red Hat Enterprise Linux"
        REDHAT_SUPPORT_PRODUCT_VERSION="9.3"
        """

        try await withMockLinuxDistribution(osReleaseContent: osReleaseContent) { fs in
            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            let rhelDist = try #require(distribution)
            #expect(rhelDist.kind == .rhel)
            #expect(rhelDist.version == "9.3")
            #expect(rhelDist.displayName == "Red Hat Enterprise Linux 9.3")
        }
    }

    @Test
    func detectOpenSUSEFromOSRelease() async throws {
        let osReleaseContent = """
        NAME="openSUSE Tumbleweed"
        # VERSION="20231201"
        ID="opensuse-tumbleweed"
        ID_LIKE="opensuse suse"
        VERSION_ID="20231201"
        PRETTY_NAME="openSUSE Tumbleweed"
        ANSI_COLOR="0;32"
        CPE_NAME="cpe:2.3:o:opensuse:tumbleweed:20231201:*:*:*:*:*:*:*"
        BUG_REPORT_URL="https://bugs.opensuse.org"
        SUPPORT_URL="https://bugs.opensuse.org"
        HOME_URL="https://www.opensuse.org/"
        DOCUMENTATION_URL="https://en.opensuse.org/Portal:Tumbleweed"
        LOGO="distributor-logo-Tumbleweed"
        """

        try await withMockLinuxDistribution(osReleaseContent: osReleaseContent) { fs in
            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            let suseDist = try #require(distribution)
            #expect(suseDist.kind == .suse)
            #expect(suseDist.version == "20231201")
            #expect(suseDist.displayName == "SUSE 20231201")
        }
    }

    @Test
    func detectAlpineFromOSRelease() async throws {
        let osReleaseContent = """
        NAME="Alpine Linux"
        ID=alpine
        VERSION_ID=3.18.4
        PRETTY_NAME="Alpine Linux v3.18"
        HOME_URL="https://alpinelinux.org/"
        BUG_REPORT_URL="https://gitlab.alpinelinux.org/alpine/aports/-/issues"
        """

        try await withMockLinuxDistribution(osReleaseContent: osReleaseContent) { fs in
            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            let alpineDist = try #require(distribution)
            #expect(alpineDist.kind == .alpine)
            #expect(alpineDist.version == "3.18.4")
            #expect(alpineDist.displayName == "Alpine Linux 3.18.4")
        }
    }

    @Test
    func detectArchFromOSRelease() async throws {
        let osReleaseContent = """
        NAME="Arch Linux"
        PRETTY_NAME="Arch Linux"
        ID=arch
        BUILD_ID=rolling
        ANSI_COLOR="38;2;23;147;209"
        HOME_URL="https://archlinux.org/"
        DOCUMENTATION_URL="https://wiki.archlinux.org/"
        SUPPORT_URL="https://bbs.archlinux.org/"
        BUG_REPORT_URL="https://bugs.archlinux.org/"
        PRIVACY_POLICY_URL="https://terms.archlinux.org/docs/privacy-policy/"
        LOGO=archlinux-logo
        """

        try await withMockLinuxDistribution(osReleaseContent: osReleaseContent) { fs in
            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            let archDist = try #require(distribution)
            #expect(archDist.kind == .arch)
            #expect(archDist.version == nil) // Arch doesn't typically have VERSION_ID
            #expect(archDist.displayName == "Arch Linux")
        }
    }

    @Test
    func detectFromIDLikeFallback() async throws {
        let osReleaseContent = """
        NAME="Custom Ubuntu Derivative"
        VERSION="1.0"
        ID=customubuntu
        ID_LIKE="ubuntu debian"
        VERSION_ID="1.0"
        PRETTY_NAME="Custom Ubuntu Derivative 1.0"
        """

        try await withMockLinuxDistribution(osReleaseContent: osReleaseContent) { fs in
            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            let customDist: LinuxDistribution = try #require(distribution)
            #expect(customDist.kind == .ubuntu) // Should detect ubuntu first from ID_LIKE
            #expect(customDist.version == "1.0")
        }
    }

    @Test
    func handleMalformedOSRelease() async throws {
        let malformedContent = """
        NAME=Ubuntu without quotes
        ID=ubuntu
        VERSION_ID=22.04
        INVALID_LINE_WITHOUT_EQUALS
        =INVALID_LINE_STARTING_WITH_EQUALS
        """

        try await withMockLinuxDistribution(osReleaseContent: malformedContent) { fs in
            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            // Should still work despite malformed lines
            let ubuntuDist = try #require(distribution)
            #expect(ubuntuDist.kind == .ubuntu)
            #expect(ubuntuDist.version == "22.04")
        }
    }

    @Test
    func handleEmptyOSRelease() async throws {
        try await withMockLinuxDistribution(osReleaseContent: "") { fs in
            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            // Empty content should result in no detection
            #expect(distribution == nil)
        }
    }

    // MARK: - Fallback Distribution-Specific File Tests

    @Test
    func detectUbuntuFromFallbackFile() async throws {
        try await withMockLinuxDistribution(
            distributionFiles: ["/etc/ubuntu-release": "Ubuntu 20.04.6 LTS"]
        ) { fs in
            // Test that we can detect Ubuntu from /etc/ubuntu-release when /etc/os-release is missing
            #expect(fs.exists(Path("/etc/ubuntu-release")))
            #expect(!fs.exists(Path("/etc/os-release")))

            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            let ubuntuDist = try #require(distribution)
            #expect(ubuntuDist.kind == .ubuntu)
            #expect(ubuntuDist.version == nil) // Fallback files don't provide version parsing
            #expect(ubuntuDist.displayName == "Ubuntu")
        }
    }

    @Test
    func detectDebianFromFallbackFile() async throws {
        try await withMockLinuxDistribution(
            distributionFiles: ["/etc/debian_version": "12.2"]
        ) { fs in
            #expect(fs.exists(Path("/etc/debian_version")))
            #expect(!fs.exists(Path("/etc/os-release")))

            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            let debianDist = try #require(distribution)
            #expect(debianDist.kind == .debian)
        }
    }

    @Test
    func fallbackPriorityOrder() async throws {
        // Test that the fallback files are checked in the correct priority order
        try await withMockLinuxDistribution(
            distributionFiles: [
                "/etc/ubuntu-release": "Ubuntu 20.04.6 LTS",
                "/etc/debian_version": "12.2",
                "/etc/fedora-release": "Fedora release 39"
            ]
        ) { fs in
            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            let ubuntuDist = try #require(distribution)
            #expect(ubuntuDist.kind == .ubuntu) // Should be Ubuntu, not Debian or Fedora
        }
    }

    // MARK: - Edge Case Tests

    @Test
    func noDistributionFilesFound() async throws {
        try await withMockLinuxDistribution() { fs in
            // No /etc/os-release and no fallback files
            #expect(!fs.exists(Path("/etc/os-release")))

            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            #expect(distribution == nil) // Should return nil when no files are found
        }
    }

    @Test
    func osReleaseWithoutIDField() async throws {
        let osReleaseContent = """
        NAME="Custom Linux Distribution"
        VERSION="1.0"
        PRETTY_NAME="Custom Linux Distribution 1.0"
        VERSION_ID="1.0"
        """

        try await withMockLinuxDistribution(osReleaseContent: osReleaseContent) { fs in
            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            // Should return nil when ID is not found and no ID_LIKE fallback
            #expect(distribution == nil)
        }
    }

    @Test
    func osReleaseWithUnknownID() async throws {
        let osReleaseContent = """
        NAME="Unknown Linux Distribution"
        VERSION="1.0"
        ID=unknowndistro
        VERSION_ID="1.0"
        PRETTY_NAME="Unknown Linux Distribution 1.0"
        """

        try await withMockLinuxDistribution(osReleaseContent: osReleaseContent) { fs in
            let operatingSystem = OperatingSystem.linux
            let distribution = operatingSystem.detectHostLinuxDistribution(fs: fs)

            // Unknown ID should map to nil
            #expect(distribution == nil)
        }
    }
}
