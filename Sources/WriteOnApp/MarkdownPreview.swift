import AppKit
import WebKit

/// Offline Markdown-to-HTML renderer. Runtime libraries are bundled as SwiftPM resources.
enum LocalMarkdownRenderer {
    static let maximumCharacters = 5_000_000

    private struct Assets {
        let markdownIt: String
        let purifier: String
        let mermaid: String

        init() throws {
            func read(_ name: String) throws -> String {
                let installedURL = Bundle.main.resourceURL?.appendingPathComponent("DansWriter_WriteOnApp.bundle", isDirectory: true)
                let installed = installedURL.flatMap { Bundle(url: $0) }
#if DEBUG
                let resourceBundle = installed ?? Bundle.module
#else
                guard let resourceBundle = installed else { throw RenderError.missingBundle }
#endif
                guard let url = resourceBundle.url(forResource: name, withExtension: "js", subdirectory: "Markdown"),
                      let value = try? String(contentsOf: url, encoding: .utf8) else {
                    throw RenderError.missingAsset(name)
                }
                return value
            }
            markdownIt = try read("markdown-it.min")
            purifier = try read("purify.min")
            mermaid = try read("mermaid.min")
        }
    }

    private static let assets: Result<Assets, Error> = Result { try Assets() }

    static func render(_ markdown: String, dark: Bool) throws -> String {
        guard markdown.utf8.count <= maximumCharacters else { throw RenderError.tooLarge }
        let bundle: Assets
        do { bundle = try assets.get() } catch { throw error }
        let foreground = dark ? "#eee9df" : "#242a29"
        let background = dark ? "#161d23" : "#faf8f3"
        let accent = dark ? "#8fc9bd" : "#34796f"
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let source = try javascriptString(markdown)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline' 'nonce-\(nonce)'; img-src data:; font-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style nonce="\(nonce)">
        :root{color-scheme:\(dark ? "dark" : "light")}body{font:17px/1.68 -apple-system,BlinkMacSystemFont,sans-serif;color:\(foreground);background:\(background);max-width:790px;margin:42px auto;padding:0 28px 64px}h1,h2,h3,h4,h5,h6{line-height:1.24;margin:1.55em 0 .55em}h1{font-size:2.15em}h2{font-size:1.65em}p,ul,ol,blockquote,table{margin:0 0 1.05em}a{color:\(accent);text-decoration:underline;text-underline-offset:2px}blockquote{border-left:3px solid \(accent);margin-left:0;padding:.1em 0 .1em 1em;opacity:.9}pre{overflow:auto;white-space:pre;background:rgba(127,127,127,.12);padding:14px 16px;border-radius:7px}code{font:0.9em ui-monospace,SFMono-Regular,Menlo,monospace;background:rgba(127,127,127,.12);padding:.12em .28em;border-radius:3px}pre code{background:none;padding:0}table{border-collapse:collapse;display:block;overflow:auto}th,td{border:1px solid rgba(127,127,127,.38);padding:7px 11px;text-align:left}th{font-weight:650}hr{border:0;border-top:1px solid rgba(127,127,127,.35);margin:2em 0}.task-list-item{list-style:none;margin-left:-1.2em}.dw-task-box{display:inline-block;width:1em;margin-right:.4em;color:\(accent);font-family:system-ui,sans-serif}.mermaid{overflow:auto;text-align:center;margin:1.5em 0}.mermaid svg{max-width:100%;height:auto}.render-error{color:#a33}
        </style></head><body><main id="content"></main>
        <script nonce="\(nonce)">\(bundle.markdownIt)</script>
        <script nonce="\(nonce)">\(bundle.purifier)</script>
        <script nonce="\(nonce)">\(bundle.mermaid)</script>
        <script nonce="\(nonce)">
        (()=>{
          window.__dwRenderError='';addEventListener('error',()=>window.__dwRenderError='Preview rendering failed.');addEventListener('unhandledrejection',()=>window.__dwRenderError='Preview rendering failed.');
          window.__dwPolicy=[];addEventListener('securitypolicyviolation',event=>window.__dwPolicy.push(event.effectiveDirective||event.violatedDirective));
          const source=\(source);
          const md=window.markdownit({html:true,linkify:true,breaks:false,typographer:false});
          md.core.ruler.after('inline','dw-task-lists',state=>{
            for(let i=1;i<state.tokens.length;i++){
              const inline=state.tokens[i];
              if(inline.type!=='inline')continue;
              let item=null;
              for(let j=i-1;j>=0;j--){if(state.tokens[j].type==='list_item_close')break;if(state.tokens[j].type==='list_item_open'){item=state.tokens[j];break;}}
              if(!item)continue;
              const match=/^\\[([ xX])\\]\\s+/.exec(inline.content); if(!match)continue;
              const first=inline.children[0];
              if(first&&first.type==='text'&&first.content.startsWith(match[0]))first.content=first.content.slice(match[0].length);
              inline.content=inline.content.slice(match[0].length);
              item.attrJoin('class','task-list-item');
              const checked=match[1].toLowerCase()==='x';
              const box=new state.Token('html_inline','',0); box.content='<span class="dw-task-box'+(checked?' checked':'')+'" aria-label="'+(checked?'complete':'incomplete')+'">'+(checked?'☑':'☐')+'</span>';
              inline.children.unshift(box);
            }
          });
          md.validateLink=url=>/^https?:\\/\\//i.test(url);
          const rendered=md.render(source);
          const safe=DOMPurify.sanitize(rendered,{FORBID_TAGS:['script','style','iframe','object','embed','img','svg','math','form','button'],FORBID_ATTR:['style'],ALLOWED_URI_REGEXP:/^https?:\\/\\//i});
          document.getElementById('content').innerHTML=safe;
          document.querySelectorAll('#content input').forEach(input=>{input.disabled=true;input.setAttribute('aria-label','Task item');});
          document.querySelectorAll('#content a').forEach(a=>{let u;try{u=new URL(a.getAttribute('href'));}catch(_){a.removeAttribute('href');return;}if(!['http:','https:'].includes(u.protocol)||!u.hostname){a.removeAttribute('href');return;}a.setAttribute('rel','noreferrer noopener');});
          mermaid.initialize({startOnLoad:false,securityLevel:'strict',htmlLabels:false,theme:'base',themeVariables:{primaryColor:'\(dark ? "#273932" : "#e2eee9")',primaryTextColor:'\(foreground)',primaryBorderColor:'\(accent)',lineColor:'\(accent)',secondaryColor:'\(dark ? "#29323b" : "#f0eee8")',tertiaryColor:'\(background)'},flowchart:{htmlLabels:false,useMaxWidth:true},maxTextSize:50000,maxEdges:500});
          const diagrams=Array.from(document.querySelectorAll('pre > code.language-mermaid'));
          (async()=>{for(let i=0;i<diagrams.length;i++){
            const code=diagrams[i],pre=code.parentElement,host=document.createElement('div');host.className='mermaid';pre.replaceWith(host);
            const diagram=code.textContent.replace(/%%\\s*\\{[\\s\\S]*?\\}\\s*%%/g,'').replace(/^---\\s*\\n[\\s\\S]*?\\n---\\s*\\n/,'');
            try{const result=await mermaid.render('dw-diagram-'+i,diagram);host.innerHTML=DOMPurify.sanitize(result.svg,{USE_PROFILES:{svg:true},FORBID_TAGS:['a','foreignObject','script','image'],FORBID_ATTR:['href','xlink:href','onload','onclick']});host.querySelectorAll('a').forEach(a=>a.remove());}
            catch(_){host.className='render-error';host.textContent='Diagram could not be rendered safely.';}
          }
          const css=document.querySelector('style').textContent;
          window.__dwReady=true;
          window.__dwExport='<!doctype html><html><head><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src &apos;none&apos;; style-src &apos;unsafe-inline&apos;; img-src data:; font-src &apos;none&apos;; connect-src &apos;none&apos;; frame-src &apos;none&apos;; object-src &apos;none&apos;; form-action &apos;none&apos;; base-uri &apos;none&apos;"><meta name="viewport" content="width=device-width,initial-scale=1"><style>'+css+'</style></head><body>'+document.getElementById('content').innerHTML+'</body></html>';
          })();
        })();
        </script></body></html>
        """
    }

    private static func javascriptString(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed])
        guard let json = String(data: data, encoding: .utf8), json.count >= 2 else { throw RenderError.encoding }
        return json.dropFirst().dropLast()
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    enum RenderError: LocalizedError {
        case tooLarge
        case missingAsset(String)
        case missingBundle
        case encoding
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "This document exceeds the 5 MB preview limit."
            case .missingAsset(let name): return "The bundled Markdown renderer is missing \(name)."
            case .missingBundle: return "The Markdown renderer resources are missing. Reinstall DansWriter from a complete app package."
            case .encoding: return "The document could not be prepared for preview."
            }
        }
    }
}

final class MarkdownPreviewWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    private let webView: WKWebView
    private let sourceView = NSTextView(frame: .zero)
    private let sourceScroll = NSScrollView()
    private let mode = NSSegmentedControl(labels: ["Preview", "HTML"], trackingMode: .selectOne, target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy HTML", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var pending: DispatchWorkItem?
    private var currentBody = ""
    private var currentHTML = ""
    private var dark = false
    private var generation = 0

    #if DEBUG
    /// Runs real WebKit layout and JavaScript checks against bundled assets without network access.
    static func runDebugSelfCheck() throws {
        final class Delegate: NSObject, WKNavigationDelegate {
            var finished = false
            var failure: Error?
            func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
            func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failure = error; finished = true }
            func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failure = error; finished = true }
            func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
                let localDocument = navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame == true && navigationAction.request.url?.absoluteString == "about:blank"
                decisionHandler(localDocument ? .allow : .cancel)
            }
        }
        struct Evidence: Decodable {
            let table: Bool
            let ready: Bool
            let taskItems: Int
            let checkedTask: Bool
            let diagrams: Int
            let scriptExecuted: Bool
            let images: Int
            let unsafeLink: Bool
            let networkBlocked: Bool
            let diagramError: Bool
        }
        let sample = #"""
        | Service | Status |
        |---|---|
        | Writer | Ready |

        - [x] Finished
        - [ ] Next

        ```mermaid
        flowchart TD
          A[Draft] --> B[Publish]
        ```

        ```mermaid
        pie title Work
          "Write" : 7
          "Review" : 3
        ```

        ```mermaid
        xychart-beta
          x-axis [Mon, Tue, Wed]
          y-axis "Count" 0 --> 10
          bar [3, 6, 9]
        ```

        <script>window.__dwPwned=true</script>
        <img src="https://example.invalid/pixel" onerror="window.__dwPwned=true">
        [unsafe](javascript:window.__dwPwned=true)
        <a href="https://[">Malformed link must not break charts</a>
        """#
        let html = try LocalMarkdownRenderer.render(sample, dark: false)
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 850, height: 760), configuration: configuration)
        let delegate = Delegate(); web.navigationDelegate = delegate
        web.loadHTMLString(html, baseURL: nil)
        let navigationDeadline = Date().addingTimeInterval(20)
        while !delegate.finished && Date() < navigationDeadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        if let failure = delegate.failure { throw SelfCheckError.webKit(failure.localizedDescription) }
        guard delegate.finished else { throw SelfCheckError.timeout }

        let probe = #"JSON.stringify({table:!!document.querySelector('table td'),ready:window.__dwReady===true,taskItems:document.querySelectorAll('.task-list-item .dw-task-box').length,checkedTask:!!document.querySelector('.dw-task-box.checked'),diagrams:document.querySelectorAll('svg').length,scriptExecuted:window.__dwPwned===true,images:document.querySelectorAll('#content img').length,unsafeLink:!!document.querySelector('#content a[href^="javascript:"]'),networkBlocked:window.__dwFetchBlocked===true,diagramError:!!document.querySelector('.render-error')})"#
        var evidence: Evidence?
        var latestEvidence: Evidence?
        var networkProbeStarted = false
        let deadline = Date().addingTimeInterval(25)
        while evidence == nil && Date() < deadline {
            var result: Any?
            var complete = false
            web.evaluateJavaScript(probe) { value, _ in result = value; complete = true }
            let evaluationDeadline = Date().addingTimeInterval(2)
            while !complete && Date() < evaluationDeadline { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            if let json = result as? String, let data = json.data(using: .utf8) { latestEvidence = try? JSONDecoder().decode(Evidence.self, from: data) }
            if latestEvidence?.ready == true && !networkProbeStarted {
                web.evaluateJavaScript("window.__dwFetchBlocked=null;fetch('https://example.invalid/probe').then(()=>window.__dwFetchBlocked=false,()=>window.__dwFetchBlocked=window.__dwPolicy.includes('connect-src')||window.__dwPolicy.includes('default-src'))")
                networkProbeStarted = true
            }
            if latestEvidence?.ready == true && latestEvidence?.networkBlocked == true { evidence = latestEvidence }
            else { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.12)) }
        }
        guard let result = evidence else {
            if let last = latestEvidence { throw SelfCheckError.failed("WebKit checks completed but networkBlocked=\(last.networkBlocked), diagrams=\(last.diagrams), taskItems=\(last.taskItems)") }
            throw SelfCheckError.timeout
        }
        guard result.table, result.ready, result.taskItems == 2, result.checkedTask, result.diagrams >= 3,
              !result.scriptExecuted, result.images == 0, !result.unsafeLink, result.networkBlocked, !result.diagramError else {
            throw SelfCheckError.failed("table=\(result.table), tasks=\(result.taskItems), checked=\(result.checkedTask), diagrams=\(result.diagrams), script=\(result.scriptExecuted), images=\(result.images), unsafeLink=\(result.unsafeLink), networkBlocked=\(result.networkBlocked), diagramError=\(result.diagramError)")
        }
        let preview = MarkdownPreviewWindowController(theme: .light)
        preview.sourceView.string = "<table><tr><td>HTML layout fixture</td></tr></table>"
        preview.mode.selectedSegment = 1; preview.changePreviewMode()
        preview.window?.contentView?.layoutSubtreeIfNeeded()
        guard preview.sourceView.frame.width > 100, preview.sourceView.frame.height > 0,
              let container = preview.sourceView.textContainer else { throw SelfCheckError.failed("HTML source view has no usable layout") }
        preview.sourceView.layoutManager?.ensureLayout(for: container)
        guard (preview.sourceView.layoutManager?.glyphRange(for: container).length ?? 0) > 0 else { throw SelfCheckError.failed("HTML source text is invisible") }
        preview.close()
    }

    private enum SelfCheckError: LocalizedError {
        case timeout
        case webKit(String)
        case failed(String)
        var errorDescription: String? {
            switch self { case .timeout: return "Markdown WebKit self-check timed out."; case .webKit(let detail): return "Markdown WebKit failed: \(detail)"; case .failed(let detail): return "Markdown WebKit self-check failed: \(detail)" }
        }
    }
    #endif

    init(theme: WriteOnTheme) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Markdown Preview"; window.minSize = NSSize(width: 600, height: 480); window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.appearance = Self.appearance(theme)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        build()
        update(theme: theme)
    }
    required init?(coder: NSCoder) { nil }

    private static func appearance(_ theme: WriteOnTheme) -> NSAppearance? {
        switch theme { case .system: return nil; case .dark: return NSAppearance(named: .darkAqua); case .light: return NSAppearance(named: .aqua) }
    }

    private func build() {
        guard let content = window?.contentView else { return }
        mode.selectedSegment = 0; mode.target = self; mode.action = #selector(changePreviewMode)
        copyButton.target = self; copyButton.action = #selector(copyHTML)
        for view in [mode, copyButton, webView, status] { view.translatesAutoresizingMaskIntoConstraints = false }
        sourceView.isEditable = false; sourceView.isRichText = false; sourceView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        sourceView.frame = NSRect(x: 0, y: 0, width: 850, height: 700)
        sourceView.minSize = .zero
        sourceView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        sourceView.isVerticallyResizable = true; sourceView.isHorizontallyResizable = false
        sourceView.autoresizingMask = [.width]
        sourceView.textContainer?.widthTracksTextView = true
        sourceView.textContainer?.containerSize = NSSize(width: 850, height: CGFloat.greatestFiniteMagnitude)
        sourceView.textContainerInset = NSSize(width: 16, height: 16)
        sourceScroll.documentView = sourceView; sourceScroll.hasVerticalScroller = true; sourceScroll.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .secondaryLabelColor
        content.addSubview(mode); content.addSubview(copyButton); content.addSubview(status); content.addSubview(webView); content.addSubview(sourceScroll)
        NSLayoutConstraint.activate([
            mode.topAnchor.constraint(equalTo: content.topAnchor, constant: 10), mode.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            copyButton.centerYAnchor.constraint(equalTo: mode.centerYAnchor), copyButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), status.centerYAnchor.constraint(equalTo: mode.centerYAnchor), status.trailingAnchor.constraint(lessThanOrEqualTo: mode.leadingAnchor, constant: -8),
            webView.topAnchor.constraint(equalTo: mode.bottomAnchor, constant: 10), webView.leadingAnchor.constraint(equalTo: content.leadingAnchor), webView.trailingAnchor.constraint(equalTo: content.trailingAnchor), webView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sourceScroll.topAnchor.constraint(equalTo: webView.topAnchor), sourceScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), sourceScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor), sourceScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        sourceScroll.isHidden = true
    }

    func update(body: String? = nil, theme: WriteOnTheme? = nil) {
        if let body { currentBody = body }
        if let theme {
            window?.appearance = Self.appearance(theme)
            dark = theme == .dark || (theme == .system && NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
        pending?.cancel(); generation += 1
        let expected = generation, text = currentBody, isDark = dark
        let work = DispatchWorkItem { [weak self] in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try LocalMarkdownRenderer.render(text, dark: isDark) }
                DispatchQueue.main.async {
                    guard let self, self.generation == expected else { return }
                    switch result {
                    case .success(let html):
                        self.currentHTML = ""; self.sourceView.string = "Rendering Markdown and diagrams…"; self.status.stringValue = ""
                        self.webView.loadHTMLString(html, baseURL: nil)
                    case .failure(let error):
                        self.currentHTML = ""; self.sourceView.string = ""; self.status.stringValue = error.localizedDescription
                        self.webView.loadHTMLString("<!doctype html><meta charset=utf-8><p>\(error.localizedDescription)</p>", baseURL: nil)
                    }
                }
            }
        }
        pending = work; DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func captureGeneratedHTML(generation expected: Int, attempt: Int) {
        guard generation == expected else { return }
        guard attempt < 120 else { status.stringValue = "Preview is taking too long to render."; return }
        webView.evaluateJavaScript("({html:window.__dwExport||'',error:window.__dwRenderError||''})") { [weak self] result, _ in
            guard let self, self.generation == expected else { return }
            let state = result as? [String: String]
            if let message = state?["error"], !message.isEmpty {
                self.status.stringValue = message
            } else if let html = state?["html"], !html.isEmpty {
                self.currentHTML = html
                self.sourceView.string = html
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.captureGeneratedHTML(generation: expected, attempt: attempt + 1) }
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        captureGeneratedHTML(generation: generation, attempt: 0)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        status.stringValue = "Preview unavailable: \(error.localizedDescription)"
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        status.stringValue = "Preview unavailable: \(error.localizedDescription)"
    }

    @objc private func changePreviewMode() {
        let showHTML = mode.selectedSegment == 1
        webView.isHidden = showHTML; sourceScroll.isHidden = !showHTML
    }
    @objc private func copyHTML() {
        guard !currentHTML.isEmpty else { NSSound.beep(); return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(currentHTML, forType: .string)
        status.stringValue = "HTML copied"
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .other, navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.request.url?.absoluteString == "about:blank" {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
           let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
           ["http", "https"].contains(parts.scheme?.lowercased() ?? ""), parts.host?.isEmpty == false {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
    func windowWillClose(_ notification: Notification) { pending?.cancel(); generation += 1; webView.stopLoading() }
}
