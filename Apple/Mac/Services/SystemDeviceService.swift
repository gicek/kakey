import Foundation
import SystemConfiguration

enum SystemDeviceService {
    static var computerName: String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return name
        }

        if let localizedName = Host.current().localizedName,
            !localizedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return localizedName
        }

        return ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
    }
}
