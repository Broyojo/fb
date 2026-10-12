import Foundation
import WebKit

@MainActor
final class FBSchemeHandler: NSObject, WKURLSchemeHandler, WKScriptMessageHandlerWithReply {
    let engine: FBEngine
    private struct Loading {
        let task: any WKURLSchemeTask
        let request: FBEngineRequest
    }
    private var loading: [ObjectIdentifier: Loading] = [:]
    private var navigationURLs: Set<String> = []
    private var scriptRequests: [UUID: FBEngineRequest] = [:]

    init(engine: FBEngine) { self.engine = engine }

    func configure(_ configuration: WKWebViewConfiguration) {
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(self, forURLScheme: "fb")
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "fbRead")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.fetchAdapter, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    func prepareNavigation(to url: URL) {
        navigationURLs.insert(Self.resourceKey(url))
        for request in scriptRequests.values { request.cancel() }
    }

    func cancelAll() {
        let requests = loading.values.map(\.request)
        loading.removeAll()
        navigationURLs.removeAll()
        for request in requests { request.cancel() }
        for request in scriptRequests.values { request.cancel() }
    }

    private static func resourceKey(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.string ?? url.absoluteString
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.scheme == "fb", url.host == "local" else {
            urlSchemeTask.didFailWithError(FBError.message("This address is not a local fb document."))
            return
        }
        let request = urlSchemeTask.request
        let document = navigationURLs.remove(Self.resourceKey(url)) != nil ||
            (request.value(forHTTPHeaderField: "Accept")?.contains("text/html") ?? false)
        let operation = FBEngineRequest(engine: engine, description: FBRequestDescription(
            url: url.absoluteString, method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:], document: document,
            bodyBase64: request.httpBody?.base64EncodedString()))
        let key = ObjectIdentifier(urlSchemeTask)
        loading[key] = Loading(task: urlSchemeTask, request: operation)
        Task.detached(priority: .userInitiated) { [weak self] in
            defer { operation.finish() }
            do {
                let head = try operation.begin()
                if let status = head.status, (300..<400).contains(status),
                   let location = head.headers?.first(where: { $0.key.lowercased() == "location" })?.value,
                   let destination = URL(string: location, relativeTo: url)?.absoluteURL {
                    await self?.redirect(key: key, destination: destination, document: document, webView: webView)
                    return
                }
                await self?.receive(head: head, key: key, url: url)
                while let data = try operation.read() { await self?.receive(data: data, key: key) }
                await self?.finish(key: key, error: nil)
            } catch { await self?.finish(key: key, error: error) }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        loading.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.request.cancel()
    }

    private func receive(head: FBResponseHead, key: ObjectIdentifier, url: URL) {
        guard let entry = loading[key] else { return }
        guard let response = HTTPURLResponse(url: url, statusCode: head.status ?? 200,
                                            httpVersion: "HTTP/1.1", headerFields: head.headers) else {
            finish(key: key, error: FBError.message("The document engine returned invalid response metadata."))
            entry.request.cancel()
            return
        }
        entry.task.didReceive(response)
    }

    private func receive(data: Data, key: ObjectIdentifier) { loading[key]?.task.didReceive(data) }

    private func finish(key: ObjectIdentifier, error: Error?) {
        guard let entry = loading.removeValue(forKey: key) else { return }
        if let error { entry.task.didFailWithError(error) } else { entry.task.didFinish() }
    }

    private func redirect(key: ObjectIdentifier, destination: URL, document: Bool, webView: WKWebView) {
        guard let entry = loading.removeValue(forKey: key) else { return }
        entry.request.cancel()
        entry.task.didFailWithError(URLError(.cancelled))
        guard document, destination.scheme == "fb", destination.host == "local" else { return }
        prepareNavigation(to: destination)
        webView.load(URLRequest(url: destination))
    }

    /// WebKit's Fetch implementation rejects non-HTTP URL schemes. Only our own main-frame,
    /// read-only local requests use this adapter; external fetches keep WebKit's normal behavior.
    static let fetchAdapter = """
    (() => {
      if (location.protocol !== 'fb:' || location.hostname !== 'local') return;
      const originalFetch = window.fetch.bind(window);
      window.fetch = async function(input, options) {
        const request = new Request(input, options);
        const url = new URL(request.url, location.href);
        if (url.protocol !== 'fb:' || url.hostname !== 'local') return originalFetch(input, options);
        if (!['GET', 'HEAD'].includes(request.method)) throw new TypeError('Local documents are read-only');
        if (request.signal.aborted) throw new DOMException('Aborted', 'AbortError');
        const result = await window.webkit.messageHandlers.fbRead.postMessage({
          url: url.href, method: request.method, headers: Object.fromEntries(request.headers.entries())
        });
        if (request.signal.aborted) throw new DOMException('Aborted', 'AbortError');
        const bytes = Uint8Array.from(atob(result.bodyBase64), c => c.charCodeAt(0));
        return new Response(request.method === 'HEAD' ? null : bytes, {status: result.status, headers: result.headers});
      };
    })();
    """

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "fb",
              message.frameInfo.securityOrigin.host == "local",
              message.frameInfo.request.url?.scheme == "fb",
              message.frameInfo.request.url?.host == "local",
              let body = message.body as? [String: Any], let address = body["url"] as? String,
              let url = URL(string: address), url.scheme == "fb", url.host == "local",
              let method = body["method"] as? String, ["GET", "HEAD"].contains(method) else {
            replyHandler(nil, "Only read-only requests from local fb pages are supported.")
            return
        }
        let operation = FBEngineRequest(engine: engine, description: FBRequestDescription(
            url: url.absoluteString, method: method, headers: body["headers"] as? [String: String] ?? [:]))
        let id = UUID()
        scriptRequests[id] = operation
        Task {
            defer { scriptRequests[id] = nil }
            do {
                let (head, data) = try await Task.detached(priority: .userInitiated) {
                    defer { operation.finish() }
                    let head = try operation.begin()
                    var data = Data()
                    while let chunk = try operation.read() {
                        guard data.count + chunk.count <= 8 * 1024 * 1024 else {
                            operation.cancel()
                            throw FBError.message("This scripted response exceeds the 8 MB limit. Open the file directly instead.")
                        }
                        data.append(chunk)
                    }
                    return (head, data)
                }.value
                replyHandler(["status": head.status ?? 200, "headers": head.headers ?? [:],
                              "bodyBase64": data.base64EncodedString()], nil)
            } catch { replyHandler(nil, error.localizedDescription) }
        }
    }
}
