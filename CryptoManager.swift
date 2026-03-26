import Foundation
import CryptoKit
import Security

/// Handles encryption/decryption of sensitive data using AES-GCM
/// Data is encrypted at rest and decrypted only when needed
@Observable
final class CryptoManager {
    static let shared = CryptoManager()
    
    private let keyTag = "com.fahmiaquinas.DiPo.encryptionKey"
    private var encryptionKey: SymmetricKey?
    
    private init() {
        // Load or generate encryption key from Keychain
        encryptionKey = loadOrCreateKey()
    }
    
    // MARK: - Key Management
    
    /// Load encryption key from Keychain or create new one if doesn't exist
    private func loadOrCreateKey() -> SymmetricKey {
        // Try to load existing key
        if let existingKey = loadKeyFromKeychain() {
            return existingKey
        }
        
        // Generate new key if none exists
        let newKey = SymmetricKey(size: .bits256)
        saveKeyToKeychain(newKey)
        return newKey
    }
    
    private func loadKeyFromKeychain() -> SymmetricKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag.data(using: .utf8)!,
            kSecReturnData: true,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let keyData = result as? Data else {
            return nil
        }
        
        return SymmetricKey(data: keyData)
    }
    
    private func saveKeyToKeychain(_ key: SymmetricKey) {
        let keyData = key.withUnsafeBytes { Data($0) }
        
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag.data(using: .utf8)!,
            kSecValueData: keyData,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        // Delete any existing key first
        SecItemDelete(query as CFDictionary)
        
        // Add new key
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("[DiPo] Failed to save encryption key: \(status)")
        }
    }
    
    // MARK: - Encryption/Decryption
    
    /// Encrypt plain text to base64 string
    /// - Parameter plainText: Text to encrypt
    /// - Returns: Base64 encoded encrypted data, or empty string if encryption fails
    func encrypt(_ plainText: String) -> String {
        guard let key = encryptionKey,
              let data = plainText.data(using: .utf8) else {
            print("[DiPo] Encryption failed: invalid input")
            return ""
        }
        
        do {
            let sealedBox = try AES.GCM.seal(data, using: key)
            
            // Combine nonce + ciphertext + tag for storage
            guard let combined = sealedBox.combined else {
                print("[DiPo] Encryption failed: could not combine sealed box")
                return ""
            }
            
            return combined.base64EncodedString()
        } catch {
            print("[DiPo] Encryption error: \(error)")
            return ""
        }
    }
    
    /// Decrypt base64 encoded encrypted data
    /// - Parameter encryptedBase64: Base64 encoded encrypted data
    /// - Returns: Decrypted plain text, or empty string if decryption fails
    func decrypt(_ encryptedBase64: String) -> String {
        guard let key = encryptionKey,
              !encryptedBase64.isEmpty,
              let combined = Data(base64Encoded: encryptedBase64) else {
            return ""
        }
        
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: combined)
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
            
            return String(data: decryptedData, encoding: .utf8) ?? ""
        } catch {
            print("[DiPo] Decryption error: \(error)")
            return ""
        }
    }
    
    // MARK: - Utilities
    
    /// Mask card number for display (show only last 4 digits)
    /// - Parameter cardNumber: Full card number
    /// - Returns: Masked card number (e.g., "**** **** **** 1234")
    static func maskCardNumber(_ cardNumber: String) -> String {
        let digits = cardNumber.filter { $0.isNumber }
        guard digits.count >= 4 else { return "****" }
        
        let last4 = String(digits.suffix(4))
        return "**** **** **** \(last4)"
    }
    
    /// Mask phone number for display (show only last 4 digits)
    /// - Parameter phoneNumber: Full phone number
    /// - Returns: Masked phone number (e.g., "+62 ***-***-1234")
    static func maskPhoneNumber(_ phoneNumber: String) -> String {
        let digits = phoneNumber.filter { $0.isNumber }
        guard digits.count >= 4 else { return "****" }
        
        let last4 = String(digits.suffix(4))
        
        // For Indonesian numbers
        if phoneNumber.hasPrefix("+62") || phoneNumber.hasPrefix("62") {
            return "+62 ***-***-\(last4)"
        } else if phoneNumber.hasPrefix("0") {
            return "0***-***-\(last4)"
        }
        
        return "***-\(last4)"
    }
    
    /// Delete all encryption keys (use with caution - data will be unrecoverable)
    func deleteAllKeys() {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: keyTag.data(using: .utf8)!
        ]
        
        SecItemDelete(query as CFDictionary)
        encryptionKey = nil
    }
}

// MARK: - BankCard Extension for Secure Storage

extension BankCard {
    
    /// Get masked card number for display
    var maskedCardNumber: String {
        guard !isDigitalWallet else { return walletProvider }
        return CryptoManager.maskCardNumber(cardNumber)
    }
    
    /// Get masked phone number for display (for digital wallets)
    var maskedPhoneNumber: String {
        guard isDigitalWallet else { return "" }
        return CryptoManager.maskPhoneNumber(phoneNumber)
    }
    
    /// Get last 4 digits of card number
    var last4Digits: String {
        let digits = cardNumber.filter { $0.isNumber }
        return String(digits.suffix(4))
    }
}
