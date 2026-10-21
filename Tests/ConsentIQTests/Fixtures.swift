import Foundation
@testable import ConsentIQ

enum Fixtures {
    static let propertyKey = "pk_test_property"
    static let apiURL = URL(string: "https://consent.example.test")!
    static let turnstileSiteKey = "1x00000000000000000000AA"

    static let configPath = "/api/public/config/\(propertyKey)"
    static let consentPath = "/api/public/consent"

    static func consentLookupPath(_ subjectId: String) -> String {
        "/api/public/consent/\(propertyKey)/\(subjectId)"
    }

    static func configJSON(
        requireCaptcha: Bool = false,
        turnstileSiteKey: String? = nil,
        defaultLanguage: String? = "en",
        resolvedRegulation: String? = "DPDPA",
        tcf: String? = nil
    ) -> String {
        let language = defaultLanguage.map { "\"\($0)\"" } ?? "null"
        let regulation = resolvedRegulation.map { "\"\($0)\"" } ?? "null"
        let siteKey = turnstileSiteKey.map { "\"\($0)\"" } ?? "null"
        let tcfBlock = tcf.map { "\"tcf\": \($0)," } ?? ""
        return """
        {
          "property": {
            "id": "prop-1", "name": "Test App", "identifier": "ai.iqworks.test", "platform": "ios",
            "defaultLanguage": \(language), "supportedLanguages": ["en", "ar"]
          },
          "banner": {
            "position": "bottom", "layout": "banner", "theme": "dark", "showLogo": false,
            "primaryColor": "#112233", "cornerStyle": "rounded", "showCookieIcon": false, "overlay": false,
            "noticeUrl": "https://consent.example.test/api/public/privacy/\(propertyKey)?notice=n-1"
          },
          "categories": [
            { "code": "necessary", "enabled": true, "defaultState": true, "name": "Necessary", "isRequired": true },
            { "code": "analytics", "enabled": true, "defaultState": false, "name": "Analytics",
              "description": "Usage stats", "isRequired": false },
            { "code": "marketing", "enabled": true, "defaultState": false, "name": "Marketing", "isRequired": false },
            { "code": "functional", "enabled": true, "defaultState": true, "name": "Functional", "isRequired": false }
          ],
          "marketingChannels": [
            { "code": "email", "name": "Email", "description": "Newsletters", "requiresDoubleOptin": false }
          ],
          "geoRules": [ { "countries": ["IN"], "regulation": "DPDPA", "requireExplicitConsent": true } ],
          "resolvedRegulation": \(regulation),
          "privacyNotices": [
            { "id": "n-1", "name": "Cookie notice", "contentTranslations": { "en": "<p>Hi</p>" }, "noticeType": "cookie", "version": 3 }
          ],
          "formConsentSources": [
            { "selector": null, "isAutoResolved": false, "privacyNotice": { "id": "n-1", "name": "Cookie notice", "type": "cookie" } }
          ],
          "privacyNoticeUrl": "/api/public/privacy/\(propertyKey)",
          "requireCaptcha": \(requireCaptcha),
          "turnstileSiteKey": \(siteKey),
          "autoBlock": false,
          \(tcfBlock)
          "translations": {
            "en": {
              "bannerDescription": "We use cookies.",
              "categories": { "analytics": { "title": "Analytics", "description": "Helps us improve." } }
            },
            "ar": { "bannerDescription": "نستخدم ملفات تعريف الارتباط.", "categories": {} }
          },
          "labels": {
            "en": {
              "title": "We value your privacy", "acceptAll": "Accept all", "acceptRequired": "Accept only required",
              "reject": "Reject all", "customize": "Customize", "save": "Save preferences",
              "preferencesTitle": "Cookie preferences", "viewNotice": "View cookie notice"
            },
            "ar": {
              "title": "نحن نحترم خصوصيتك", "acceptAll": "قبول الكل",
              "acceptRequired": "قبول الضروري فقط", "reject": "رفض الكل",
              "customize": "تخصيص", "save": "حفظ التفضيلات",
              "preferencesTitle": "تفضيلات", "viewNotice": "عرض الإشعار"
            }
          },
          "rtl": ["ar", "ur", "ks", "sd"],
          "someFutureField": { "nested": true }
        }
        """
    }

    static let savedConsentJSON = """
    {
      "consent": {
        "id": "c-1",
        "cookieConsents": { "necessary": true, "analytics": true, "marketing": false, "preferences": false, "social": false },
        "marketingConsents": { "email": true },
        "consentedAt": "2026-01-01T00:00:00.000Z",
        "expiresAt": null,
        "regulationApplied": "DPDPA",
        "consentVersion": null
      }
    }
    """

    static func tcfJSON(cmpId: Int = 300, gdprApplies: Bool = true, enabled: Bool = true) -> String {
        """
        {
          "enabled": \(enabled), "gdprApplies": \(gdprApplies), "vendorIds": [1, 755],
          "publisherCountryCode": "DE",
          "publisherRestrictions": [ { "purposeId": 2, "restrictionType": 1, "vendorIds": [755] } ],
          "repromptMonths": 6, "tcfPolicyVersion": 5, "cmpId": \(cmpId), "cmpVersion": 1,
          "vendorListUrl": "https://consent.example.test/api/public/tcf/\(propertyKey)/vendor-list",
          "futureField": [1, 2]
        }
        """
    }

    static func tcfDecisionJSON(scope: String?, consent: String) -> String {
        let scopeField = scope.map { ", \"scope\": \"\($0)\"" } ?? ""
        return #"{"type":"decision","tcString":"CQ-s","keys":{"IABTCF_gdprApplies":1},"consent":\#(consent)\#(scopeField)}"#
    }

    static let tcfDecisionJSON = """
    {
      "type": "decision",
      "tcString": "CQ-test",
      "keys": {
        "IABTCF_CmpSdkID": 300, "IABTCF_CmpSdkVersion": 1, "IABTCF_PolicyVersion": 5, "IABTCF_gdprApplies": 1,
        "IABTCF_PublisherCC": "DE", "IABTCF_PurposeOneTreatment": 0, "IABTCF_TCString": "CQ-test",
        "IABTCF_PurposeConsents": "1101", "IABTCF_PublisherRestrictions2": "_1"
      },
      "stored": { "tcString": "CQ-test", "vendorIds": [1, 755], "restrictionsKey": "2:1:755" },
      "consent": { "necessary": true, "analytics": true, "marketing": false }
    }
    """

    static let captchaConfigJSON = configJSON(requireCaptcha: true, turnstileSiteKey: turnstileSiteKey)

    static let noConsentJSON = #"{"consent":null}"#
    static let expiredConsentJSON = #"{"consent":null,"expired":true}"#
    static let submitResultJSON = #"{"success":true,"consentId":"c-2","proofHash":"abc123"}"#

    static func decodeConfig(_ json: String = configJSON()) throws -> PropertyConfig {
        try JSONDecoder().decode(PropertyConfig.self, from: Data(json.utf8))
    }
}
