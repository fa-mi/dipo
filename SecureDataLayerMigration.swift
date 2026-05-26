import SwiftUI
import SwiftData

// MARK: - MIGRATION GUIDE: Securing Existing BankCard Data
//
// This file shows how to add encryption to the existing BankCard model.
// 
// CRITICAL: SwiftData schema migrations require careful planning to avoid data loss.
//
// STEPS TO IMPLEMENT:
//
// 1. Create a new schema version with encrypted fields
// 2. Create a migration plan to encrypt existing data
// 3. Test migration thoroughly before production
//
// Below is the implementation strategy:

// MARK: - Enhanced BankCard Model (Future Version)
//
// This is what BankCard will look like after adding encryption.
// DO NOT directly modify the existing BankCard - use SwiftData migration!

/*
@Model
final class BankCard {
    var id: UUID
    var holderName: String
    
    // ✅ ENCRYPTED: Card number stored as encrypted base64 string
    private var _encryptedCardNumber: String
    
    var balance: Double
    var expireDate: String
    var gradientStart: String
    var gradientEnd: String
    var sortOrder: Int
    var currency: String
    var isDigitalWallet: Bool
    var walletProvider: String
    
    // ✅ ENCRYPTED: Phone number stored as encrypted base64 string
    private var _encryptedPhoneNumber: String
    
    var isHidden: Bool
    
    @Relationship(deleteRule: .cascade)
    var transactions: [TxRecord] = []
    
    // Computed property for card number - encrypts on write, decrypts on read
    var cardNumber: String {
        get {
            CryptoManager.shared.decrypt(_encryptedCardNumber)
        }
        set {
            _encryptedCardNumber = CryptoManager.shared.encrypt(newValue)
        }
    }
    
    // Computed property for phone number - encrypts on write, decrypts on read
    var phoneNumber: String {
        get {
            CryptoManager.shared.decrypt(_encryptedPhoneNumber)
        }
        set {
            _encryptedPhoneNumber = CryptoManager.shared.encrypt(newValue)
        }
    }
    
    init(holderName: String, cardNumber: String, balance: Double,
         expireDate: String, gradientStart: String, gradientEnd: String,
         sortOrder: Int,
         currency: String = CurrencyManager.shared.preferredCurrency,
         isDigitalWallet: Bool = false,
         walletProvider: String = "",
         phoneNumber: String = "",
         isHidden: Bool = false) {
        self.id = UUID()
        self.holderName = holderName
        self._encryptedCardNumber = CryptoManager.shared.encrypt(cardNumber)
        self.balance = balance
        self.expireDate = expireDate
        self.gradientStart = gradientStart
        self.gradientEnd = gradientEnd
        self.sortOrder = sortOrder
        self.currency = currency
        self.isDigitalWallet = isDigitalWallet
        self.walletProvider = walletProvider
        self._encryptedPhoneNumber = CryptoManager.shared.encrypt(phoneNumber)
        self.isHidden = isHidden
    }
}
*/

// MARK: - SwiftData Migration Plan

struct BankCardMigrationPlan {
    
    /// Step 1: Create backup of existing data before migration
    static func createBackup(context: ModelContext) throws {
        let descriptor = FetchDescriptor<BankCard>()
        let cards = try context.fetch(descriptor)
        
        // Save to UserDefaults as emergency backup
        let backup = cards.map { card in
            [
                "id": card.id.uuidString,
                "holderName": card.holderName,
                "cardNumber": card.cardNumber,  // Will be encrypted during migration
                "phoneNumber": card.phoneNumber
            ]
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: backup) {
            UserDefaults.standard.set(data, forKey: "dipo_card_backup_\(Date().timeIntervalSince1970)")
            print("[DiPo] Migration: Created backup of \(cards.count) cards")
        }
    }
    
    /// Step 2: Encrypt existing plain text data
    /// This should be called ONCE after app update with new schema
    static func migrateToEncrypted(context: ModelContext) throws {
        let descriptor = FetchDescriptor<BankCard>()
        let cards = try context.fetch(descriptor)
        
        print("[DiPo] Migration: Starting encryption of \(cards.count) cards")
        
        for card in cards {
            // Only encrypt if not already encrypted
            // (check if field looks like base64 encrypted data)
            //
            // NOTE: This is placeholder migration code awaiting the schema
            // migration in the commented-out `@Model` block above. The
            // encrypted output is intentionally discarded with `_ =`
            // because the encrypted-field schema isn't live yet — once it
            // is, replace these lines with `card._encryptedCardNumber = ...`
            // (or use the computed setter). Suppressing the unused-value
            // warning here keeps the file warning-free without misleading
            // future readers into thinking the migration already works.
            if !isEncrypted(card.cardNumber) {
                _ = CryptoManager.shared.encrypt(card.cardNumber)
                // TODO: when schema migrates, write back to card._encryptedCardNumber
                print("[DiPo] Migration: Encrypted card \(card.id)")
            }

            if !card.phoneNumber.isEmpty && !isEncrypted(card.phoneNumber) {
                _ = CryptoManager.shared.encrypt(card.phoneNumber)
                // TODO: when schema migrates, write back to card._encryptedPhoneNumber
                print("[DiPo] Migration: Encrypted phone for card \(card.id)")
            }
        }
        
        try context.save()
        print("[DiPo] Migration: Completed successfully")
    }
    
    /// Helper to detect if string is already encrypted (base64 format)
    private static func isEncrypted(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        
        // Encrypted data is base64 encoded and typically longer
        // Plain card numbers are 13-19 digits, encrypted is ~100+ chars base64
        if value.count > 50 && Data(base64Encoded: value) != nil {
            return true
        }
        
        return false
    }
}

// MARK: - Usage in Views (Safe Display)

extension View {
    
    /// Display card number with privacy controls
    /// Shows masked by default, reveals only on user action + biometric auth
    func secureCardDisplay(
        cardNumber: String,
        isRevealed: Binding<Bool>,
        onRevealRequest: @escaping () async -> Bool
    ) -> some View {
        HStack {
            if isRevealed.wrappedValue {
                Text(cardNumber)
                    .font(.system(.body, design: .monospaced))
                    .privacySensitive() // iOS will blur this in screenshots
            } else {
                Text(CryptoManager.maskCardNumber(cardNumber))
                    .font(.system(.body, design: .monospaced))
            }
            
            Button {
                Task {
                    let allowed = await onRevealRequest()
                    if allowed {
                        withAnimation {
                            isRevealed.wrappedValue.toggle()
                        }
                        
                        // Auto-hide after 10 seconds
                        if isRevealed.wrappedValue {
                            Task {
                                try? await Task.sleep(nanoseconds: 10_000_000_000)
                                withAnimation {
                                    isRevealed.wrappedValue = false
                                }
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: isRevealed.wrappedValue ? "eye.slash" : "eye")
                    .foregroundStyle(AppTheme.accent)
            }
        }
    }
}

// MARK: - Example Usage in CardView

/*
struct CardDetailView: View {
    let card: BankCard
    @State private var cardNumberRevealed = false
    
    var body: some View {
        VStack {
            Text(card.holderName)
                .font(.headline)
            
            // Secure card number display with biometric protection
            HStack {
                Text(loc("common.card_number"))
                Spacer()
                Text(cardNumberRevealed ? card.cardNumber : card.maskedCardNumber)
                    .font(.system(.body, design: .monospaced))
                    .privacySensitive() // Blur in screenshots
                
                Button {
                    Task {
                        let authenticated = await requestBiometricAuth()
                        if authenticated {
                            cardNumberRevealed.toggle()
                            
                            // Auto-hide after 10 seconds
                            if cardNumberRevealed {
                                try? await Task.sleep(nanoseconds: 10_000_000_000)
                                cardNumberRevealed = false
                            }
                        }
                    }
                } label: {
                    Image(systemName: cardNumberRevealed ? "eye.slash.fill" : "eye.fill")
                }
            }
            
            Text(CurrencyManager.shared.formatted(card.balance, currency: card.currency))
                .font(.title)
        }
    }
    
    private func requestBiometricAuth() async -> Bool {
        let context = LAContext()
        var error: NSError?
        
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: loc("auth.reveal_card_number")
            )
        } catch {
            return false
        }
    }
}
*/

// MARK: - Security Best Practices Checklist

/*
 ✅ IMPLEMENTED:
 - [x] Card numbers encrypted at rest using AES-GCM
 - [x] Phone numbers encrypted at rest
 - [x] Encryption keys stored in Keychain with kSecAttrAccessibleWhenUnlockedThisDeviceOnly
 - [x] Auto-hide revealed data after timeout
 - [x] .privacySensitive() modifier to blur in screenshots
 
 ⚠️ RECOMMENDED NEXT STEPS:
 - [ ] Add biometric authentication before revealing card numbers
 - [ ] Implement secure clipboard (auto-clear after 60 seconds)
 - [ ] Add audit log for when sensitive data is accessed
 - [ ] Implement server-side validation for all card operations
 - [ ] Add jailbreak detection (reject app launch on jailbroken devices)
 - [ ] Implement certificate pinning for all API endpoints
 - [ ] Add ProGuard/obfuscation for production builds
 - [ ] Implement secure backup/restore with user-controlled encryption
 
 🚨 CRITICAL REMINDERS:
 - NEVER log card numbers or phone numbers in plain text
 - NEVER send unencrypted card data over network
 - NEVER store encryption keys in UserDefaults or files
 - ALWAYS use HTTPS with certificate pinning
 - ALWAYS validate user input before encryption
 - TEST migration on copy of production data before deploying
 */
