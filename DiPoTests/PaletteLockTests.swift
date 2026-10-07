import XCTest
import SwiftUI
import UIKit
@testable import DiPo

/// The palette is frozen. Every colour the app ships is pinned here, in both
/// themes.
///
/// The point is not that these values are perfect; it is that they were
/// DECIDED, and a decision anyone can quietly overwrite is not a decision. The
/// emerald is DiPo's original green, kept over every alternative tried since,
/// and the rest were fitted around it in one lightness band.
///
/// If one of these fails, nothing is broken yet — a colour changed. Either put
/// it back, or agree the new value with Fahmi FIRST and update the constant
/// here in the same commit, so this file keeps saying what the app really does.
///
/// Adding a new token is fine and needs no entry until it ships in the UI.
@MainActor
final class PaletteLockTests: XCTestCase {

    private func hex(_ color: Color, _ style: UIUserInterfaceStyle) -> String {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    func testThemeTokensAreUnchanged() {
        // name, colour, dark, light
        let tokens: [(String, Color, String, String)] = [
            ("bg",            AppTheme.bg,            "#1A1F1E", "#F2F4F3"),
            ("cardDark",      AppTheme.cardDark,      "#222827", "#FFFFFF"),
            ("cardMid",       AppTheme.cardMid,       "#2A3330", "#E4EAE8"),
            ("textPrimary",   AppTheme.textPrimary,   "#FFFFFF", "#0D1514"),
            ("textSecondary", AppTheme.textSecondary, "#8A9693", "#4D6B62"),

            // The brand green, identical in both themes on purpose.
            ("accent",        AppTheme.accent,        "#1DB87A", "#1DB87A"),
            ("red",           AppTheme.red,           "#FF6166", "#E5484D"),
            ("orange",        AppTheme.orange,        "#FB923C", "#CF5F04"),
            ("blue",          AppTheme.blue,          "#38BDF8", "#0789C3"),
            ("purple",        AppTheme.purple,        "#A78BFA", "#8B66F8"),
            ("teal",          AppTheme.teal,          "#06B6D4", "#058DA4"),
            ("amber",         AppTheme.amber,         "#FBBF24", "#A67803"),
            ("indigo",        AppTheme.indigo,        "#818CF8", "#6673F6"),
            ("fuchsia",       AppTheme.fuchsia,       "#E879F9", "#D819F5"),
            ("slate",         AppTheme.slate,         "#94A3B8", "#6E829F"),

            ("accentTrack",   AppTheme.accentTrack,   "#2A3330", "#E4EAE8"),
            // DiPo Lari Hemat scenery.
            ("gameSkyTop",     AppTheme.gameSkyTop,    "#0B1622", "#A8DCEB"),
            ("gameSkyLow",     AppTheme.gameSkyLow,    "#18302C", "#E6F5EC"),
            ("gameHillFar",    AppTheme.gameHillFar,   "#1C3A32", "#A9D9B9"),
            ("gameHillNear",   AppTheme.gameHillNear,  "#24493D", "#7CC79A"),
            ("gameTree",       AppTheme.gameTree,      "#1F4237", "#4FA977"),
            ("gameSoil",       AppTheme.gameSoil,      "#3A3022", "#E7D3A8"),
            ("gameSoilDeep",   AppTheme.gameSoilDeep,  "#2A2318", "#D6BC87"),
            ("gameSun",        AppTheme.gameSun,       "#F1E7C6", "#FFD66B"),
            ("gameCloud",      AppTheme.gameCloud,     "#3C525C", "#FFFFFF"),
            ("gamePost",       AppTheme.gamePost,      "#5A4630", "#9B7A4E"),
            ("gameGrassDeep",  AppTheme.gameGrassDeep, "#159462", "#17A36B"),
            // DiPo's Royal bubble.
            ("royalGold",      AppTheme.royalGold,      "#C9A24D", "#C9A24D"),
            ("royalGoldLight", AppTheme.royalGoldLight, "#F1DDA0", "#F1DDA0"),
            ("royalGoldText",  AppTheme.royalGoldText,  "#E2C277", "#8E6A1F"),
            // DiPo talking, the same in both themes.
            ("bubbleFill",    AppTheme.bubbleFill,    "#FFFFFF", "#FFFFFF"),
            ("bubbleInk",     AppTheme.bubbleInk,     "#1A120C", "#1A120C"),
            ("dipoCrown",     AppTheme.dipoCrown,     "#F2B51E", "#F2B51E"),
            ("dipoSweat",     AppTheme.dipoSweat,     "#7CC8FF", "#7CC8FF"),
            ("onVividFill",   AppTheme.onVividFill,   "#0D1514", "#FFFFFF"),
        ]

        for (name, color, dark, light) in tokens {
            XCTAssertEqual(hex(color, .dark), dark,
                           "AppTheme.\(name) changed in DARK mode. Agree it with Fahmi before editing.")
            XCTAssertEqual(hex(color, .light), light,
                           "AppTheme.\(name) changed in LIGHT mode. Agree it with Fahmi before editing.")
        }
    }

    /// Aliases, so a refactor cannot quietly point one of them somewhere else.
    func testRoleAliasesStillResolveToTheirToken() {
        XCTAssertEqual(hex(AppTheme.green, .dark),      hex(AppTheme.accent, .dark))
        XCTAssertEqual(hex(AppTheme.accentFill, .dark), hex(AppTheme.accent, .dark))
        XCTAssertEqual(hex(AppTheme.flowIn, .dark),     hex(AppTheme.accent, .dark))
        XCTAssertEqual(hex(AppTheme.redFill, .dark),    hex(AppTheme.red, .dark))
        XCTAssertEqual(hex(AppTheme.flowOut, .dark),    hex(AppTheme.red, .dark))
        XCTAssertEqual(hex(AppTheme.onSolid, .light),   hex(AppTheme.onVividFill, .light))
    }

    /// The category hues, which are what a user actually recognises a category
    /// by — the orange circle IS "Shopping" on every screen.
    func testCategoryColoursAreUnchanged() {
        let expected: [TxCategory: String] = [
            .shopping: "#F97316", .food: "#F59E0B", .travel: "#0EA5E9",
            .bills: "#8B5CF6", .transport: "#6366F1", .health: "#D946EF",
            .commitment: "#14B8A6", .other: "#5B6F6B", .salary: "#1DB87A",
            .freelance: "#0EA5E9", .business: "#8B5CF6", .investment: "#1DB87A",
            .bonus: "#F59E0B", .gift: "#D946EF", .incomeOther: "#5B6F6B",
            .debtPayment: "#64748B",
        ]
        // Every case, so a new category cannot arrive unpinned.
        XCTAssertEqual(expected.count, TxCategory.allCases.count,
                       "A category was added or removed — pin its colour here too.")
        for category in TxCategory.allCases {
            XCTAssertEqual(category.iconBg.uppercased(), expected[category],
                           "\(category.rawValue) changed colour. Agree it with Fahmi before editing.")
        }
    }

    /// A rule the palette was built on: no expense category may borrow the
    /// money-in green or the money-out red, or a list of ordinary expenses
    /// starts reading as a wall of warnings.
    func testNoExpenseCategoryBorrowsASemanticColour() {
        let expenseCategories: [TxCategory] = [
            .shopping, .food, .travel, .bills, .transport, .health, .commitment, .other,
        ]
        let green = hex(AppTheme.accent, .dark)
        let red = hex(AppTheme.red, .dark)
        for category in expenseCategories {
            XCTAssertNotEqual(category.iconBg.uppercased(), green)
            XCTAssertNotEqual(category.iconBg.uppercased(), red)
        }
    }
}
