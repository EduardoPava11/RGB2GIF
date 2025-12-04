//
//  DataExtensions.swift
//  RGB2GIF
//
//  Shared Data extensions to avoid duplicate symbol conflicts
//

import Foundation

extension Data {
    /// Convert data to hexadecimal string (lowercase)
    var hexString: String {
        map { String(format: "%02hhx", $0) }.joined()
    }
}
