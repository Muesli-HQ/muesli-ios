// Adapted from stephancill/ios-keyboard-dictation (MIT License,
// Copyright (c) 2026 Stephan Cilliers):
// https://github.com/stephancill/ios-keyboard-dictation/blob/main/Sources/KeyboardDictationDemoKeyboard/WebAudioCapture.swift
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions: The above copyright
// notice and this permission notice shall be included in all copies or
// substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

import UIKit
import WebKit

/// Captures microphone audio from inside the keyboard extension by running
/// `getUserMedia` in a hidden `WKWebView`.
///
/// `AVAudioEngine` / `AudioQueue` input in a keyboard process is routinely
/// invalidated by the host app even with Full Access. WebKit performs capture in
/// its own WebContent/GPU processes, so the keyboard only receives PCM over a
/// script message handler. Emits 16 kHz mono Int16 PCM chunks through `onAudio`.
@MainActor
final class WebAudioCapture: NSObject {
    static let sampleRate: Double = 16_000
    private static let baseURL = URL(string: "https://muesli-keyboard-capture.invalid/")
    private static let startupTimeout: Duration = .seconds(5)

    var onReady: (() -> Void)?
    var onStarted: (() -> Void)?
    var onAudio: ((Data, Float) -> Void)?
    var onEnded: ((String) -> Void)?

    private(set) var isReady = false
    var isCapturing: Bool { activeAttemptID != nil }
    private let webView: WKWebView
    private var activeAttemptID: String?
    private var heartbeat: Timer?
    private var startupTimeoutTask: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        super.init()
        configuration.userContentController.add(WeakCaptureMessageHandler(self), name: "capture")
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.alpha = 0.01
        webView.isOpaque = false
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
    }

    /// The web view must stay in the keyboard's window; WebKit throttles
    /// detached web views and capture never starts.
    func attach(to view: UIView) {
        guard webView.superview !== view else { return }
        view.addSubview(webView)
        view.sendSubviewToBack(webView)
        // An https base URL gives the page the secure context getUserMedia requires.
        webView.loadHTMLString(Self.page, baseURL: Self.baseURL)
    }

    func start() {
        guard isReady, !isCapturing else { return }
        let attemptID = UUID().uuidString
        activeAttemptID = attemptID
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.activeAttemptID == attemptID else { return }
                self.webView.evaluateJavaScript("captureHeartbeat('\(attemptID)')", completionHandler: nil)
            }
        }
        startupTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.startupTimeout)
            guard !Task.isCancelled else { return }
            self?.finish(reason: "start timed out", attemptID: attemptID)
        }
        webView.evaluateJavaScript("startCapture('\(attemptID)'); 0") { [weak self] _, error in
            guard let error else { return }
            let reason = "start failed: \(error.localizedDescription)"
            Task { @MainActor in self?.finish(reason: reason, attemptID: attemptID) }
        }
    }

    func stop() {
        guard let attemptID = activeAttemptID else { return }
        finish(reason: Self.stoppedReason, attemptID: attemptID)
    }

    func tearDown() {
        stop()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "capture")
        webView.removeFromSuperview()
        isReady = false
    }

    static let stoppedReason = "stopped"

    private func finish(reason: String, attemptID: String) {
        guard activeAttemptID == attemptID else { return }
        activeAttemptID = nil
        heartbeat?.invalidate()
        heartbeat = nil
        clearStartupTimeout()
        if isReady {
            webView.evaluateJavaScript("stopCapture('\(attemptID)'); 0", completionHandler: nil)
        }
        onEnded?(reason)
    }

    private func clearStartupTimeout() {
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
    }

    fileprivate func handle(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        if type == "ready" {
            isReady = true
            onReady?()
            return
        }
        guard let attemptID = message["attemptID"] as? String, activeAttemptID == attemptID else { return }
        switch type {
        case "started":
            clearStartupTimeout()
            onStarted?()
        case "audio":
            guard let base64 = message["data"] as? String,
                  let data = Data(base64Encoded: base64) else { return }
            onAudio?(data, (message["rms"] as? NSNumber)?.floatValue ?? 0)
        case "interrupted", "failed":
            finish(reason: "\(type): \(message["reason"] as? String ?? "unknown")", attemptID: attemptID)
        default:
            break
        }
    }

    private static let page = """
    <!doctype html><html><body><script>
    const targetRate = \(Int(sampleRate));
    const post = message => window.webkit.messageHandlers.capture.postMessage(message);
    const encode = samples => {
      const bytes = new Uint8Array(samples.buffer, 0, samples.length * 2);
      let binary = '';
      for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
      return btoa(binary);
    };
    let activeCapture;
    window.captureHeartbeat = attemptID => {
      if (activeCapture?.attemptID === attemptID) activeCapture.lastHeartbeat = performance.now();
    };
    window.stopCapture = attemptID => {
      if (activeCapture?.attemptID === attemptID) activeCapture.stop();
    };
    window.startCapture = async attemptID => {
      activeCapture?.stop();
      let stopping = false, stream, context, source, processor, sink;
      const audioSession = navigator.audioSession;
      const previousType = audioSession?.type ?? 'auto';
      const cleanup = () => {
        if (stopping) return;
        stopping = true;
        activeCapture = undefined;
        clearInterval(watchdog);
        if (processor) { processor.onaudioprocess = null; processor.disconnect(); }
        source?.disconnect();
        sink?.disconnect();
        stream?.getTracks().forEach(track => track.stop());
        context?.close().catch(() => {});
        if (audioSession) {
          audioSession.onstatechange = null;
          try { audioSession.type = previousType; } catch (_) {}
        }
      };
      const interrupted = reason => { if (!stopping) { cleanup(); post({ type: 'interrupted', attemptID, reason }); } };
      const capture = { attemptID, lastHeartbeat: performance.now(), stop: cleanup };
      activeCapture = capture;
      // Protect startup as well as recording if the keyboard process stops pinging.
      const watchdog = setInterval(() => {
        if (performance.now() - capture.lastHeartbeat > 3000) interrupted('native-heartbeat-expired');
      }, 500);
      try {
        try { if (audioSession) audioSession.type = 'play-and-record'; } catch (_) {}
        stream = await navigator.mediaDevices.getUserMedia({
          audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
        });
        if (stopping) { stream.getTracks().forEach(track => track.stop()); return; }
        const track = stream.getAudioTracks()[0];
        track.onended = () => interrupted('track-ended');
        // Defer the AudioContext until capture: creating one can take audio focus.
        context = new AudioContext({ latencyHint: 'interactive' });
        await context.resume();
        if (stopping) return;
        processor = context.createScriptProcessor(1024, 1, 1);
        sink = context.createGain();
        sink.gain.value = 0;
        processor.connect(sink);
        sink.connect(context.destination);
        source = context.createMediaStreamSource(stream);
        source.connect(processor);
        context.onstatechange = () => { if (context.state !== 'running') interrupted('context-' + context.state); };
        if (audioSession) audioSession.onstatechange = () => { if (audioSession.state === 'interrupted') interrupted('audio-session-interrupted'); };
        const step = context.sampleRate / targetRate;
        let position = 0, sum = 0, count = 0;
        processor.onaudioprocess = event => {
          const input = event.inputBuffer.getChannelData(0);
          const output = new Int16Array(Math.ceil(input.length / step) + 1);
          let written = 0, energy = 0;
          for (const sample of input) {
            energy += sample * sample; sum += sample; count += 1; position += 1;
            if (position >= step) {
              position -= step;
              output[written++] = Math.max(-1, Math.min(1, sum / count)) * 32767;
              sum = 0; count = 0;
            }
          }
          if (written > 0) post({ type: 'audio', attemptID, data: encode(output.subarray(0, written)), rms: Math.sqrt(energy / input.length) });
        };
        post({ type: 'started', attemptID, sampleRate: context.sampleRate });
      } catch (error) {
        if (stopping) return;
        cleanup();
        post({ type: 'failed', attemptID, reason: error.name + ': ' + error.message });
      }
    };
    post({ type: 'ready' });
    </script></body></html>
    """
}

extension WebAudioCapture: WKUIDelegate, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
    ) {
        // The app-level microphone permission still applies; only skip
        // WebKit's own per-page prompt, and only for the microphone.
        decisionHandler(type == .microphone ? .grant : .deny)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        if let attemptID = activeAttemptID {
            finish(reason: "web content process terminated", attemptID: attemptID)
        }
        webView.loadHTMLString(Self.page, baseURL: Self.baseURL)
    }
}

/// Breaks the retain cycle between `WKUserContentController` and its handler.
@MainActor
private final class WeakCaptureMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WebAudioCapture?

    init(_ target: WebAudioCapture) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.handle(message.body)
    }
}
