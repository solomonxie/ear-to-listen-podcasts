import SwiftUI
import WebKit

/// YouTube's own embedded player, in a web view `PlaybackEngine` drives the way it drives
/// `AVPlayer`. Lives as long as the engine, not the page, so closing the player or
/// scrolling the video away leaves it playing.
@MainActor
final class YouTubeEmbed: NSObject {
    var onTime: (@MainActor (TimeInterval) -> Void)?
    var onPlaying: (@MainActor (Bool) -> Void)?
    var onDuration: (@MainActor (TimeInterval) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onDisplay: (@MainActor (Display) -> Void)?

    /// Whether there's a video worth looking at. Until it has actually played, the page
    /// shows the thumbnail — YouTube's error screens (a "sign in to confirm you're not a
    /// bot" wall, embedding turned off) are never put in front of anyone.
    enum Display { case loading, showing, blocked }

    private(set) var display: Display = .loading {
        didSet { if display != oldValue { onDisplay?(display) } }
    }
    private var watchdog: Task<Void, Never>?
    /// Long enough for a slow connection to get a video started; a wall gives no event at
    /// all, so this is the only way some of them are ever noticed.
    private static let startTimeout: Duration = .seconds(10)

    private(set) var videoID: String?
    private(set) var isReady = false
    private var lastTime: TimeInterval = 0
    private var playWhenReady = false

    /// The embed refuses to play without a Referer naming the app (error 152/153) — the
    /// form YouTube asks native apps to send is `https://<bundle id>`.
    private static let origin = "https://" + (Bundle.main.bundleIdentifier ?? "app").lowercased()

    private(set) lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(WeakHandler(self), name: "yt")
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.errorScreenWatch, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        )
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.customUserAgent = Self.safariUserAgent
        view.navigationDelegate = self
        view.uiDelegate = self
        return view
    }()

    /// A web view's own user agent leaves out Safari's `Version/… Safari/…`, and YouTube
    /// reads a browser it can't name as a likely bot — the "sign in to confirm you're
    /// not a bot" wall in place of the video.
    private static var safariUserAgent: String {
        let version = UIDevice.current.systemVersion
        let parts = version.split(separator: ".")
        let short = parts.prefix(2).joined(separator: ".") + (parts.count == 1 ? ".0" : "")
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(version.replacingOccurrences(of: ".", with: "_")) like Mac OS X) "
            + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(short) Mobile/15E148 Safari/604.1"
    }

    func load(id: String, start: TimeInterval, autoplay: Bool) {
        guard YouTubeVideo.isValidID(id) else { return }
        videoID = id
        lastTime = start
        isReady = false
        playWhenReady = autoplay
        display = .loading
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.startTimeout)
            guard !Task.isCancelled, let self, self.display == .loading else { return }
            self.block()
        }
        webView.loadHTMLString(Self.page(id: id, start: Int(start)), baseURL: URL(string: Self.origin))
    }

    func play() {
        guard isReady else { playWhenReady = true; return }
        run("player.playVideo()")
    }

    func pause() {
        playWhenReady = false
        run("player.pauseVideo()")
    }

    func seek(to time: TimeInterval) { run("player.seekTo(\(max(time, 0)), true)") }

    func stop() {
        guard videoID != nil else { return }
        videoID = nil
        isReady = false
        playWhenReady = false
        watchdog?.cancel()
        display = .loading
        webView.loadHTMLString("", baseURL: nil)
    }

    private func run(_ script: String) {
        guard isReady else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let event = message["e"] as? String else { return }
        switch event {
        case "ready":
            isReady = true
            if let duration = message["d"] as? Double, duration > 0 { onDuration?(duration) }
            if playWhenReady { run("player.playVideo()") }
        case "state":
            // -1 unstarted, 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued.
            let state = message["s"] as? Int ?? -1
            if let duration = message["d"] as? Double, duration > 0 { onDuration?(duration) }
            if state == 1 {
                isReady = true
                watchdog?.cancel()
                display = .showing
            }
            if state == 0 { onEnded?() } else if state == 1 || state == 2 { onPlaying?(state == 1) }
        case "time":
            if let time = message["t"] as? Double {
                lastTime = time
                onTime?(time)
            }
        case "error", "blocked":
            block()
        default:
            break
        }
    }

    /// Nothing here plays, so the engine's own clock takes over from the video.
    private func block() {
        watchdog?.cancel()
        webView.evaluateJavaScript("try{player.pauseVideo()}catch(e){}", completionHandler: nil)
        isReady = false
        display = .blocked
        onPlaying?(false)
    }

    /// Runs inside YouTube's own player frame, which the page around it can't see into:
    /// reports the player's error screen — the bot wall is one — the moment it appears.
    /// By class rather than wording, so it holds in every language.
    private static let errorScreenWatch = """
        (function(){
          if (window === window.top || location.hostname.indexOf('youtube') < 0) return;
          var tries = 0;
          var timer = setInterval(function(){
            if (document.querySelector('.ytp-error')) {
              try { window.webkit.messageHandlers.yt.postMessage({e:'blocked'}) } catch(e) {}
              clearInterval(timer);
            } else if (++tries > 60) { clearInterval(timer) }
          }, 500);
        })();
        """

    private static func page(id: String, start: Int) -> String {
        """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#p{position:absolute;inset:0;width:100%;height:100%}</style>
        </head><body><div id="p"></div>
        <script>
        var player;
        function post(m){window.webkit.messageHandlers.yt.postMessage(m)}
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('p',{videoId:'\(id)',
            playerVars:{playsinline:1,start:\(start),rel:0,origin:'\(origin)'},
            events:{
              onReady:function(){post({e:'ready',d:player.getDuration()})},
              onStateChange:function(ev){post({e:'state',s:ev.data,d:player.getDuration()})},
              onError:function(ev){post({e:'error',c:ev.data})}
            }});
          setInterval(function(){
            if(player&&player.getPlayerState&&player.getPlayerState()===1){post({e:'time',t:player.getCurrentTime()})}
          },500);
        }
        </script>
        <script src="https://www.youtube.com/iframe_api" onerror="post({e:'error',c:-2})"></script>
        </body></html>
        """
    }
}

/// `WKUserContentController` holds its handlers strongly; this keeps it from holding the
/// embed, which holds the web view, which holds the controller.
@MainActor
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var embed: YouTubeEmbed?
    init(_ embed: YouTubeEmbed) { self.embed = embed }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { embed?.receive(message.body) }
    }
}

/// Where the video shows: the cover's place on the episode page. Borrows the engine's one
/// web view rather than owning it, so the page coming and going doesn't stop the video.
struct YouTubePlayerView: UIViewRepresentable {
    let embed: YouTubeEmbed

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        adopt(into: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        if embed.webView.superview !== container { adopt(into: container) }
    }

    private func adopt(into container: UIView) {
        let webView = embed.webView
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }
}

/// Anything the player links out to — the title, the logo, "Sign in" — goes to the YouTube
/// app (or Safari) instead. Google refuses sign-in inside an app's web view, and a link
/// opening a new window there otherwise does nothing at all.
extension YouTubeEmbed: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let isLinkOut = action.navigationType == .linkActivated && action.targetFrame?.isMainFrame != false
        guard isLinkOut, let url = action.request.url else { return decisionHandler(.allow) }
        openOutside(url)
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url { openOutside(url) }
        return nil
    }

    /// Sign-in is pointless out there too — it's the video they wanted, so that's what opens.
    private func openOutside(_ url: URL) {
        let isSignIn = url.host?.contains("accounts.google") == true || url.path.contains("signin")
        let target = isSignIn ? videoID.map { YouTubeVideo.watchURL(id: $0, at: lastTime) } ?? url : url
        UIApplication.shared.open(target)
    }
}
