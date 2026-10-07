import Foundation
import Testing
@testable import OrgCore

struct OrgProtocolTests {
    static let urls = [
        "org-protocol://capture?template=b&url=https%3A%2F%2Fexample.com%2Fa%3Fq%3D1&title=A+Page&body=some%20text",
        "org-protocol://capture?url=https%3A%2F%2Fx.org&title=&body=",
        "org-protocol:/capture?template=t&title=Just%20a%20title",
        "org-protocol://capture?template=t&url=file%3A%2F%2F%2Ftmp%2Fa.org&title=%5Bweird%5D%20%C3%A9",
        "org-protocol://capture:/b/https%3A%2F%2Fexample.com/Title/Body",
        "org-protocol://capture:/https%3A%2F%2Fexample.com/Title",
        "org-protocol://capture://t/https:/example.com/x/Title",
        "org-protocol://store-link?url=https%3A%2F%2Fexample.com&title=Example",
        "org-protocol://store-link?url=https%3A%2F%2Fexample.com",
        "org-protocol://store-link:/https%3A%2F%2Fexample.com/Old%20Title",
        "https://example.com",
    ]

    func describe(_ request: OrgProtocol.Request?) -> String {
        switch request {
        case .capture(let template, let properties)?:
            return (["capture template=\(template ?? "nil")"] + ["type", "link", "description", "annotation", "initial"].compactMap { key in
                properties[key].map { "\(key)=\($0)" }
            }).joined(separator: "\n")
        case .storeLink(let url, let title)?:
            return "store url=\(url)\ntitle=\(title ?? "nil")"
        case nil:
            return "none"
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORGSTAR_SKIP_ORACLE"] == nil))
    func matchesOrgProtocol() throws {
        let form = """
            (progn
              (require 'org-protocol)
              (let (out (org-stored-links nil))
                (cl-letf (((symbol-function 'raise-frame) #'ignore)
                          ((symbol-function 'org-capture)
                           (lambda (_ template)
                             (setq out (mapconcat #'identity
                                         (cons (format "capture template=%s" (or template "nil"))
                                               (delq nil (mapcar (lambda (k)
                                                                   (let ((v (plist-get org-store-link-plist (intern (concat ":" k)))))
                                                                     (and v (format "%s=%s" k v))))
                                                                 '("type" "link" "description" "annotation" "initial"))))
                                         "\\n")))))
                  (let ((result (org-protocol-check-filename-for-protocol (buffer-string) nil nil)))
                    (cond (out nil)
                          ((null result)
                           (setq out (format "store url=%s\\ntitle=%s" (car (car org-stored-links)) (or (cadr (car org-stored-links)) "nil"))))
                          (t (setq out "none")))))
                (erase-buffer)
                (insert out)))
            """
        let results = try EmacsOracle.run(Self.urls.map { EmacsOracle.Case(text: $0, point: 1, form: form) })
        for (url, result) in zip(Self.urls, results) {
            let ours = describe(OrgProtocol.parse(url))
            #expect(ours == result.text, "\(url)\nours:  \(ours.debugDescription)\nemacs: \(result.text.debugDescription) \(result.error)")
        }
    }

    @Test func captureURLRoundTrips() {
        let url = OrgProtocol.captureURL(template: "w", url: "https://example.com/a?b=1&c=2+3", title: "Tea & cake = 100% café", body: "line one\nline+two")
        #expect(OrgProtocol.parse(url) == .capture(template: "w", properties: [
            "link": "https://example.com/a?b=1&c=2+3", "type": "https",
            "description": "Tea & cake = 100% café", "initial": "line one\nline+two",
            "annotation": "[[https://example.com/a?b=1&c=2+3][Tea & cake = 100% café]]",
        ]))
        #expect(OrgProtocol.parse(OrgProtocol.captureURL(template: nil, url: nil, title: "", body: "just text"))
            == .capture(template: nil, properties: ["description": "", "initial": "just text", "annotation": ""]))
    }
}
