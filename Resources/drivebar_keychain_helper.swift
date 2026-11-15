import Foundation
import Security

// Usage:
//   drivebar_keychain_helper write  --service <service> --account <account>   (reads secret bytes from stdin)
//   drivebar_keychain_helper read   --service <service> --account <account>   (writes secret bytes to stdout)
//   drivebar_keychain_helper delete --service <service> --account <account>

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: drivebar_keychain_helper write|read|delete --service <service> --account <account>\n", stderr)
    exit(2)
}

let action = args[1]
var service = "com.hunglx.DriveBar.gdrive"
var account = ""

var idx = 2
while idx < args.count {
    let flag = args[idx]
    if flag == "--service", idx + 1 < args.count {
        service = args[idx + 1]
        idx += 2
    } else if flag == "--account", idx + 1 < args.count {
        account = args[idx + 1]
        idx += 2
    } else {
        idx += 1
    }
}

guard !service.isEmpty, !account.isEmpty else {
    fputs("Error: --service and --account are required.\n", stderr)
    exit(2)
}

let effectiveService = service.hasSuffix(".v3") ? service : "\(service).v3"

let baseQuery: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: effectiveService,
    kSecAttrAccount as String: account
]

switch action {
case "write":
    let secretData = FileHandle.standardInput.readDataToEndOfFile()
    guard !secretData.isEmpty else {
        fputs("Error: empty secret on stdin.\n", stderr)
        exit(1)
    }

    // Delete any existing item first (avoids legacy ACL update prompts) and add fresh with AfterFirstUnlockThisDeviceOnly
    _ = SecItemDelete(baseQuery as CFDictionary)

    var addQuery = baseQuery
    addQuery[kSecValueData as String] = secretData
    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

    let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
    if addStatus == errSecSuccess {
        exit(0)
    }

    let attributesToUpdate: [String: Any] = [
        kSecValueData as String: secretData,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
    if updateStatus == errSecSuccess {
        exit(0)
    } else {
        fputs("SecItemAdd/Update failed with OSStatus \(addStatus)/\(updateStatus)\n", stderr)
        exit(1)
    }

case "read":
    var readQuery = baseQuery
    readQuery[kSecReturnData as String] = true
    readQuery[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(readQuery as CFDictionary, &item)
    guard status == errSecSuccess, let data = item as? Data else {
        exit(1)
    }
    FileHandle.standardOutput.write(data)
    exit(0)

case "delete":
    let status = SecItemDelete(baseQuery as CFDictionary)
    if status == errSecSuccess || status == errSecItemNotFound {
        exit(0)
    }
    exit(1)

default:
    fputs("Unknown action: \(action)\n", stderr)
    exit(2)
}
