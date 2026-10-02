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
    var onFailed: (@MainActor (Int) -> Void)?

    private(set) var videoID: String?
    private(set) var isReady = false
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
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        return view
    }()

    func load(id: String, start: TimeInterval, autoplay: Bool) {
        guard YouTubeVideo.isValidID(id) else { return }
        videoID = id
        isReady = false
        playWhenReady = autoplay
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
            if state == 0 { onEnded?() } else if state == 1 || state == 2 { onPlaying?(state == 1) }
        case "time":
            if let time = message["t"] as? Double { onTime?(time) }
        case "error":
            isReady = false
            onFailed?(message["c"] as? Int ?? -1)
        default:
            break
        }
    }

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
