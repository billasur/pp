import XCTest
@testable import PpCore

final class WebIntentTests: XCTestCase {

    func testOpenDomainRule() {
        XCTAssertEqual(WebIntentParser.parse("open youtube.com"), .openSite(host: "youtube.com"))
        XCTAssertEqual(WebIntentParser.parse("open google.com"), .openSite(host: "google.com"))
        XCTAssertEqual(WebIntentParser.parse("go to github.com"), .openSite(host: "github.com"))
        XCTAssertEqual(WebIntentParser.parse("go to reddit.com"), .openSite(host: "reddit.com"))
        XCTAssertEqual(WebIntentParser.parse("visit wikipedia.org"), .openSite(host: "wikipedia.org"))
        XCTAssertEqual(WebIntentParser.parse("visit perplexity.ai"), .openSite(host: "perplexity.ai"))
    }

    func testSearchDomainArgumentRule() {
        // Rule (c): "search <domain>" where the argument is a bare domain -> openSite
        // This is the exact reported failure: "search youtube.com" opening a Google search
        XCTAssertEqual(WebIntentParser.parse("search youtube.com"), .openSite(host: "youtube.com"))
        XCTAssertEqual(WebIntentParser.parse("search github.com"), .openSite(host: "github.com"))
        XCTAssertEqual(WebIntentParser.parse("search wikipedia.org"), .openSite(host: "wikipedia.org"))
        XCTAssertEqual(WebIntentParser.parse("search reddit.com"), .openSite(host: "reddit.com"))
        XCTAssertEqual(WebIntentParser.parse("search google.com"), .openSite(host: "google.com"))
    }

    func testSearchSiteForQueryRule() {
        // Rule (b): "search <site> for <query>"
        XCTAssertEqual(WebIntentParser.parse("search youtube for lofi beats"), .search(query: "lofi beats", site: "youtube"))
        XCTAssertEqual(WebIntentParser.parse("search github for swift mlx"), .search(query: "swift mlx", site: "github"))
        XCTAssertEqual(WebIntentParser.parse("search wikipedia for quantum computing"), .search(query: "quantum computing", site: "wikipedia"))
        XCTAssertEqual(WebIntentParser.parse("search google for weather tokyo"), .search(query: "weather tokyo", site: "google"))
        XCTAssertEqual(WebIntentParser.parse("search reddit for mechanical keyboards"), .search(query: "mechanical keyboards", site: "reddit"))
        XCTAssertEqual(WebIntentParser.parse("search spotify for podcast"), .search(query: "podcast", site: "spotify"))
    }

    func testSearchForAndGoogleRule() {
        // Rule (d): "search for <query>", "google <query>"
        XCTAssertEqual(WebIntentParser.parse("search for lofi beats"), .search(query: "lofi beats", site: nil))
        XCTAssertEqual(WebIntentParser.parse("search for best pizza nearby"), .search(query: "best pizza nearby", site: nil))
        XCTAssertEqual(WebIntentParser.parse("google weather in tokyo"), .search(query: "weather in tokyo", site: "google"))
        XCTAssertEqual(WebIntentParser.parse("google swift async await"), .search(query: "swift async await", site: "google"))
    }

    func testPlayOnSiteRule() {
        // Rule (e): "play <query> on <site>"
        XCTAssertEqual(WebIntentParser.parse("play lofi on youtube"), .play(query: "lofi", site: "youtube"))
        XCTAssertEqual(WebIntentParser.parse("play jazz on spotify"), .play(query: "jazz", site: "spotify"))
        XCTAssertEqual(WebIntentParser.parse("play synthwave radio on youtube"), .play(query: "synthwave radio", site: "youtube"))
    }

    func testBareDomainRule() {
        // Rule (f): bare domain with no verb
        XCTAssertEqual(WebIntentParser.parse("youtube.com"), .openSite(host: "youtube.com"))
        XCTAssertEqual(WebIntentParser.parse("github.com"), .openSite(host: "github.com"))
        XCTAssertEqual(WebIntentParser.parse("wikipedia.org"), .openSite(host: "wikipedia.org"))
        XCTAssertEqual(WebIntentParser.parse("perplexity.ai"), .openSite(host: "perplexity.ai"))
    }

    func testURLConstruction() {
        let siteIntent = WebIntent.openSite(host: "youtube.com")
        XCTAssertEqual(siteIntent.url, URL(string: "https://youtube.com"))

        let searchIntent = WebIntent.search(query: "lofi beats", site: "youtube")
        XCTAssertEqual(searchIntent.url?.host, "www.youtube.com")
        XCTAssertTrue(searchIntent.url?.absoluteString.contains("lofi%20beats") == true)

        let playIntent = WebIntent.play(query: "lofi", site: "youtube")
        XCTAssertEqual(playIntent.url?.host, "www.youtube.com")
    }

    func testNegativesNotWebIntents() {
        // Rule (g): "search my email for the invoice" is a screen/app task, NOT a web intent
        XCTAssertEqual(WebIntentParser.parse("search my email for the invoice"), .none)
        XCTAssertEqual(WebIntentParser.parse("search the screen for the cancel button"), .none)
        XCTAssertEqual(WebIntentParser.parse("open Notes"), .none)
        XCTAssertEqual(WebIntentParser.parse("open finder"), .none)
        XCTAssertEqual(WebIntentParser.parse(""), .none)
    }
}
