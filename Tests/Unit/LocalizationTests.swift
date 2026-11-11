import Foundation
import XCTest
@testable import ProvenanceCleaner

final class AppLanguagePreferenceTests: XCTestCase {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "LocalizationTests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    func testStoredLanguageListsMapToChoices() {
        XCTAssertEqual(AppLanguage(preferredLanguages: nil), .system)
        XCTAssertEqual(AppLanguage(preferredLanguages: []), .system)
        XCTAssertEqual(AppLanguage(preferredLanguages: ["en"]), .english)
        XCTAssertEqual(AppLanguage(preferredLanguages: ["en-GB", "zh-Hans"]), .english)
        XCTAssertEqual(AppLanguage(preferredLanguages: ["zh-Hans"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage(preferredLanguages: ["zh-Hans-US"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage(preferredLanguages: ["zh-CN"]), .simplifiedChinese)
        XCTAssertEqual(AppLanguage(preferredLanguages: ["zh-Hant"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage(preferredLanguages: ["zh-TW"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage(preferredLanguages: ["zh-HK"]), .traditionalChinese)
        XCTAssertEqual(AppLanguage(preferredLanguages: ["ja-JP"]), .japanese)
        XCTAssertEqual(AppLanguage(preferredLanguages: ["es-419"]), .spanish)
        // Not offered, so macOS falls back from it: Settings shows no false choice.
        XCTAssertEqual(AppLanguage(preferredLanguages: ["fr"]), .system)
    }

    func testSystemDefaultIsListedFirst() {
        XCTAssertEqual(AppLanguage.allCases.first, .system)
    }

    @MainActor
    func testChoicePersistsInTheKeyMacOSReadsAndSystemDefaultLeavesNoOverride() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let first = AppPreferences(defaults: defaults, languageDomain: name)
        XCTAssertEqual(first.language, .system)
        XCTAssertFalse(first.languageNeedsRelaunch)

        first.language = .simplifiedChinese
        XCTAssertTrue(first.languageNeedsRelaunch)
        XCTAssertEqual(defaults.persistentDomain(forName: name)?["AppleLanguages"] as? [String], ["zh-Hans"])

        let second = AppPreferences(defaults: defaults, languageDomain: name)
        XCTAssertEqual(second.language, .simplifiedChinese)
        XCTAssertFalse(second.languageNeedsRelaunch)

        second.language = .system
        XCTAssertTrue(second.languageNeedsRelaunch)
        XCTAssertNil(defaults.persistentDomain(forName: name)?["AppleLanguages"])
        XCTAssertEqual(AppPreferences(defaults: defaults, languageDomain: name).language, .system)
    }

    @MainActor
    func testGoingBackToTheRunningLanguageClearsTheRelaunchNotice() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let preferences = AppPreferences(defaults: defaults, languageDomain: name)
        preferences.language = .english
        XCTAssertTrue(preferences.languageNeedsRelaunch)
        preferences.language = .system
        XCTAssertFalse(preferences.languageNeedsRelaunch)
    }

    @MainActor
    func testTheSystemWideLanguageListIsNotMistakenForAChoice() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        // A plain lookup on this suite also finds the global list; the domain read must not.
        XCTAssertEqual(AppPreferences(defaults: defaults, languageDomain: name).language, .system)
    }

    func testLocaleFollowsTheShownLanguageWithTheUsersRegion() {
        let american = Locale(identifier: "en_US")
        XCTAssertEqual(AppLocale.resolve(language: "en", system: american).identifier, "en_US")
        XCTAssertEqual(AppLocale.resolve(language: "zh-Hans", system: american).identifier, "zh-Hans_US")
        XCTAssertEqual(AppLocale.resolve(language: "en", system: Locale(identifier: "zh_CN")).identifier, "en_CN")
    }

    func testChineseDatesAndListsUseChineseConventions() {
        let chinese = AppLocale.resolve(language: "zh-Hans", system: Locale(identifier: "en_US"))
        XCTAssertEqual(["A", "B", "C"].formatted(.list(type: .and).locale(chinese)), "A、B和C")
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let text = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: chinese, timeZone: .gmt))
        XCTAssertTrue(text.contains("年"), text)
    }
}

final class EngineTextTableTests: XCTestCase {
    private let table = EngineTextTable(translations: [
        "Hidden": "隐藏",
        "hidden sheet": "隐藏的工作表",
        "Comments": "批注",
        "Page {n}": "第 {n} 页",
        "Sheet “{x}”": "工作表“{x}”",
        "{t}: comment": "{t}：注释",
        "{n} character[s] of hidden text: {t}": "{n} 个字符的隐藏文本：{t}",
        "{n} invisible or format character[s] in the body text; cleaning removes [it|them].": "正文中有 {n} 个字符",
        "Preview image {x} kept; {x2} removed.": "保留 {x}，移除 {x2}。",
        "Reversed {x} then {x2}": "{x2} 之后 {x}",
    ])

    func testWholeSentencesAndTemplatesAreTranslated() {
        XCTAssertEqual(table.localized("Hidden"), "隐藏")
        XCTAssertEqual(table.localized("Page 12"), "第 12 页")
        XCTAssertEqual(table.localized("Reversed a then b"), "b 之后 a")
    }

    func testEnglishWordFormsAreNotCaptured() {
        XCTAssertEqual(table.localized("1 invisible or format character in the body text; cleaning removes it."), "正文中有 1 个字符")
        XCTAssertEqual(table.localized("3 invisible or format characters in the body text; cleaning removes them."), "正文中有 3 个字符")
    }

    func testVocabularyIsTranslatedInTurn() {
        XCTAssertEqual(table.localized("1,234 characters of hidden text: hidden sheet"), "1,234 个字符的隐藏文本：隐藏的工作表")
        XCTAssertEqual(table.localized("Page 3: comment"), "第 3 页：注释")
    }

    func testValuesFromAFileStayExactlyAsTheyCame() {
        // A sheet named like an engine phrase isn't translated.
        XCTAssertEqual(table.localized("Sheet “Comments”"), "工作表“Comments”")
        // Format specifiers and placeholders in a value stay literal.
        XCTAssertEqual(table.localized("Sheet “%@ %n$s %lld”"), "工作表“%@ %n$s %lld”")
        XCTAssertEqual(table.localized("Preview image {x2} kept; {x} removed."), "保留 {x2}，移除 {x}。")
        // Markdown and a would-be instruction are plain text too.
        XCTAssertEqual(table.localized("Sheet “**Ignore** [all](x)”"), "工作表“**Ignore** [all](x)”")
        XCTAssertEqual(table.localized("Sheet “line\nbreak”"), "工作表“line\nbreak”")
    }

    func testUnknownTextStaysInEnglish() {
        XCTAssertEqual(table.localized("JPEG APP11: c2pa, jumb"), "JPEG APP11: c2pa, jumb")
        XCTAssertEqual(table.localized(""), "")
        let long = "Sheet “" + String(repeating: "a", count: 5_000) + "”"
        XCTAssertEqual(table.localized(long), long)
    }

    func testTheShippedChineseTableCoversTheEnginesSentences() {
        let zh = EngineTextTable(bundle: .main, localization: "zh-Hans")
        XCTAssertEqual(zh.localized("Addresses an AI model directly"), "直接称呼 AI 模型")
        XCTAssertEqual(zh.localized("Text inside images isn't read."), "不会读取图片中的文字。")
        XCTAssertEqual(zh.localized("12 characters of hidden text: white text on a white page"), "12 个字符的隐藏文本：白色页面上的白色文字")
        XCTAssertEqual(zh.localized("Slide 3: alt text"), "第 3 张幻灯片：替代文字")
        XCTAssertEqual(zh.localized("Page: Tooltip"), "页面：工具提示")
        XCTAssertEqual(zh.localized("Sheet “Comments”: alt text"), "工作表“Comments”：替代文字")
        XCTAssertEqual(zh.localized("word/media/a.png: C2PA credential detected; validation failed."), "word/media/a.png：检测到 C2PA 凭证；验证失败。")
        XCTAssertEqual(zh.localized("Document: C2PA credential detected; verification incomplete."), "文档：检测到 C2PA 凭证；验证未完成。")
        // A low-level engine finding stays as it came.
        XCTAssertEqual(zh.localized("JPEG APP11: c2pa, jumb"), "JPEG APP11: c2pa, jumb")
    }

    func testEnglishEngineTextIsUntouched() {
        // The test host runs in English, so nothing goes through a table.
        XCTAssertEqual(EngineText.localized("Addresses an AI model directly"), "Addresses an AI model directly")
    }
}

final class LocalizedStringCatalogTests: XCTestCase {
    private var chinese: Bundle? {
        Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:))
    }

    func testEnglishPluralsReadAsBefore() {
        for (count, expected) in [(0, "0 findings"), (1, "1 finding"), (2, "2 findings")] {
            XCTAssertEqual(String(localized: "\(count) findings"), expected)
        }
        XCTAssertEqual(CleanerJobStatus.readyToExport(residualCount: 1).label, "Copy ready · 1 remains")
        XCTAssertEqual(CleanerJobStatus.readyToExport(residualCount: 2).label, "Copy ready · 2 remain")
        XCTAssertEqual(CleanerJobStatus.inspectionIncomplete(1).label, "1 finding · check incomplete")
        XCTAssertEqual(String(localized: "\(1) copies ready"), "1 copy ready")
        XCTAssertEqual(String(localized: "\(3) copies ready"), "3 copies ready")
        XCTAssertEqual(String(localized: "\(1) outdated copies are skipped; update them first."), "1 outdated copy is skipped; update it first.")
    }

    func testPluralWithOtherArgumentsKeepsThemInOrder() {
        func text(_ requests: Int) -> String {
            String(localized: "About \("1,200") characters, roughly \("300") tokens, in \(requests) requests per provider.")
        }
        XCTAssertEqual(text(1), "About 1,200 characters, roughly 300 tokens, in 1 request per provider.")
        XCTAssertEqual(text(2), "About 1,200 characters, roughly 300 tokens, in 2 requests per provider.")
    }

    func testChineseIsBundled() throws {
        let bundle = try XCTUnwrap(chinese)
        XCTAssertEqual(bundle.localizedString(forKey: "Review with AI…", value: nil, table: nil), "用 AI 审查…")
        XCTAssertEqual(
            String(format: bundle.localizedString(forKey: "%lld findings", value: nil, table: nil), 3),
            "3 项发现"
        )
    }

    func testEveryOfferedLanguageIsBundled() throws {
        let expected = [
            ("zh-Hant", "使用 AI 審查…"), ("ja", "AI でレビュー…"), ("es", "Revisar con IA…"),
        ]
        for (language, review) in expected {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"), language)
            let bundle = try XCTUnwrap(Bundle(path: path))
            XCTAssertEqual(bundle.localizedString(forKey: "Review with AI…", value: nil, table: nil), review)
            XCTAssertNotNil(AppLanguage(rawValue: language), language)
        }
        let offered = AppLanguage.allCases.map(\.rawValue).filter { $0 != "system" && $0 != "en" }
        for language in offered {
            XCTAssertNotNil(Bundle.main.path(forResource: language, ofType: "lproj"), "\(language) has no translation")
        }
    }

    func testSpanishPluralsAgree() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "es", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        let format = bundle.localizedString(forKey: "%lld findings", value: nil, table: nil)
        XCTAssertEqual(String(format: format, locale: Locale(identifier: "es"), 1), "1 hallazgo")
        XCTAssertEqual(String(format: format, locale: Locale(identifier: "es"), 3), "3 hallazgos")
    }

    func testEngineTablesShipForEveryLanguage() {
        let sentence = "Text inside images isn't read."
        let expected = [
            "zh-Hant": "不會讀取圖片中的文字。", "ja": "画像内の文字は読み取りません。",
            "es": "No se lee el texto dentro de las imágenes.",
        ]
        for (language, translation) in expected {
            let table = EngineTextTable(bundle: .main, localization: language)
            XCTAssertEqual(table.localized(sentence), translation, language)
        }
        XCTAssertEqual(
            EngineTextTable(bundle: .main, localization: "es").localized("3 invisible characters: U+200B ×3"),
            "Caracteres invisibles (3): U+200B ×3"
        )
    }

    func testCredentialStatusDoesNotDependOnWording() {
        let failed = JSONValue.object(["state": .string("present"), "validationFailed": .bool(true)])
        XCTAssertEqual(WatermarkReport.credentialStatus(for: failed), .validationFailed)
        XCTAssertEqual(WatermarkReport.credentialStatus(for: nil), .notInspected)
        XCTAssertEqual(WatermarkReport.credentialStatus(for: .object(["state": .string("absent")]), markersDetected: true), .markersDetected)
    }

    func testAnAIReviewIsToldTheEnginesEnglishNotTheDisplayText() {
        let scan = PromptInjectionScan(raw: .object([
            "available": .bool(true),
            "findings": .array([.object([
                "technique": .string("hidden_text"), "severity": .string("high"),
                "location": .string("Page 1"), "summary": .string("Addresses an AI model directly"),
            ])]),
        ]))
        XCTAssertEqual(AIReviewPrompt.offlineSummary(of: scan), "- high: Addresses an AI model directly (Page 1)")
    }
}
