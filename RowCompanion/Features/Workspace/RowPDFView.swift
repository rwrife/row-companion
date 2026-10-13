import SwiftUI
import PDFKit
import UIKit

/// SwiftUI wrapper around `PDFView` with the MVP security/privacy contract:
/// - **No automatic external actions:** selection is disabled and this view
///   never installs link/URL handling, so PDFKit can never follow a document
///   link or destination on the user's behalf (issue #3 acceptance: "no
///   automatic external PDF links/actions"). PDFKit only ever opens a URI
///   when app code calls it; this wrapper structurally cannot.
/// - **Restore page then zoom/location after layout** — the stored viewport
///   is applied once after the document attaches and the view has non-zero
///   bounds (PLAN: not on every redraw).
/// - The user's *source* file is never opened here; `documentURL` is the
///   verified app-owned copy from `RowRepository.documentFileURL`.
struct RowPDFView: UIViewRepresentable {
    let documentURL: URL
    let reference: ReferenceState
    /// Report-only highlight anchors (issue #17). Drawn on the *in-memory*
    /// document only; the app-owned PDF bytes are never rewritten, and the
    /// source document's stored checksum therefore never changes.
    var highlights: [DocumentAnnotation] = []
    /// Explicit navigation target set from the annotation list; when it
    /// changes the view scrolls there (button-driven, no required gesture).
    var navigationTarget: DocumentAnnotation?
    /// Reports (0-based page, normalized visible rect) after user scrolling.
    let onMoved: (Int, NormalizedRect) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMoved: onMoved)
    }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        #if os(macOS)
        // Selection/link UI is an AppKit PDFView surface; iOS PDFView does
        // not expose it (so it structurally cannot follow document links).
        view.isSelectionEnabled = false
        #endif
        view.document = openDocument()
        view.delegate = context.coordinator
        context.coordinator.pdfView = view
        context.coordinator.attachedURL = documentURL
        context.coordinator.observePageChanges(on: view)
        context.coordinator.scheduleRestore(of: reference)
        context.coordinator.apply(highlights: highlights)
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        // Only re-apply the *stored* viewport when the document target
        // changed; user scrolling within a document must never be reverted
        // mid-session (a redraw is not a restore trigger).
        if context.coordinator.attachedURL != documentURL {
            uiView.document = openDocument()
            context.coordinator.attachedURL = documentURL
            context.coordinator.scheduleRestore(of: reference)
        }
        context.coordinator.apply(highlights: highlights)
        if let target = navigationTarget, context.coordinator.lastNavigationID != target.id {
            context.coordinator.lastNavigationID = target.id
            context.coordinator.navigate(to: target)
        }
    }

    private func openDocument() -> PDFDocument? {
        guard let data = try? Data(contentsOf: documentURL),
              let pdf = PDFDocument(data: data),
              !pdf.isEncrypted else { return nil }
        return pdf
    }

    @MainActor
    final class Coordinator: NSObject, PDFViewDelegate {
        let onMoved: (Int, NormalizedRect) -> Void
        weak var pdfView: PDFView?
        var attachedURL: URL?
        var lastNavigationID: UUID?
        private var drawnAnnotations: [PDFAnnotation] = []
        private var drawnSignature = ""
        private var restorePending = false
        private var pendingState: ReferenceState?
        /// True while the page-changed observer is echoing our own restore.
        private var restoring = false

        init(onMoved: @escaping (Int, NormalizedRect) -> Void) {
            self.onMoved = onMoved
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func observePageChanges(on view: PDFView) {
            // PDFKit posts this (legacy `NSPDFDocumentViewPageChanged`) when
            // the visible page changes; referenced by raw string so SDK
            // symbol drift cannot silently disable reporting — a missed
            // report only defers a viewport save, never corrupts it.
            // Selector-based observer: no captured closure state, so it is
            // Swift 6 strict-concurrency safe.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged),
                name: Notification.Name("PDFDocumentViewPageChanged"),
                object: view
            )
        }

        @objc private func pageChanged() {
            reportMoved()
        }

        /// "Restore page then zoom/location after view layout": wait until the
        /// view has real bounds, then scroll to the stored location once.
        func scheduleRestore(of state: ReferenceState) {
            restorePending = true
            pendingState = state
            attemptRestore()
        }

        private func attemptRestore() {
            guard restorePending, let view = pdfView, pendingState != nil,
                  view.document != nil else { return }
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, let state = self.pendingState else { return }
                guard view.bounds.width > 0, view.bounds.height > 0,
                      let document = view.document else { return }
                self.restorePending = false
                self.restoring = true
                defer { self.restoring = false; self.pendingState = nil }
                // Restore page first, then zoom (PLAN: "restore page then
                // zoom/location after view layout"). Zoom is derived from the
                // stored visible-width fraction and clamped to a sane band, so
                // a degenerate/tampered stored rect can never zoom to
                // infinity; the horizontal center of the stored rect is then
                // re-centered on the page.
                let index = ViewportClamp.clamp(pageIndex: state.pageIndex, pageCount: document.pageCount)
                guard let page = document.page(at: index) else { return }
                view.go(to: page)
                let pageSize = page.bounds(for: .mediaBox)
                guard pageSize.width > 0, pageSize.height > 0 else { return }
                let target = PDFCoordinateSpace.pageRect(for: state.visibleRect, pageSize: pageSize.size)
                let scale = Swift.max(1, Swift.min(view.bounds.width / Swift.max(target.width, 1), 4))
                view.scaleFactor = scale
            }
        }

        /// Re-draw the report-only highlight overlay on the in-memory
        /// document. Idempotent: only rebuilds when the anchor set changed.
        /// Bookmarks/notes need no on-page art (they live in the list); only
        /// `.highlight` draws. Nothing here is ever saved back to disk.
        func apply(highlights: [DocumentAnnotation]) {
            guard let document = pdfView?.document else { return }
            let signature = highlights
                .filter { $0.kind == .highlight }
                .map { "\($0.id)\($0.pageIndex)\($0.rect.x),\($0.rect.y),\($0.rect.width),\($0.rect.height):\($0.title)" }
                .joined(separator: "|")
            guard signature != drawnSignature else { return }
            drawnSignature = signature
            for annotation in drawnAnnotations { annotation.page?.removeAnnotation(annotation) }
            drawnAnnotations.removeAll()
            for item in highlights where item.kind == .highlight {
                guard let page = document.page(at: item.pageIndex) else { continue }
                let pageSize = page.bounds(for: .mediaBox)
                let rect = PDFCoordinateSpace.pageRect(for: item.rect, pageSize: pageSize.size)
                guard rect.width > 0, rect.height > 0 else { continue }
                let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
                annotation.color = UIColor.systemYellow.withAlphaComponent(0.4)
                page.addAnnotation(annotation)
                drawnAnnotations.append(annotation)
            }
        }

        /// Scroll to an annotation from an explicit list tap. Then report the
        /// new position so the piece's reference follows the jump.
        func navigate(to item: DocumentAnnotation) {
            guard let view = pdfView, let document = view.document,
                  let page = document.page(at: ViewportClamp.clamp(pageIndex: item.pageIndex,
                                                                   pageCount: document.pageCount)) else { return }
            restoring = true
            defer { restoring = false }
            view.go(to: page)
            let pageSize = page.bounds(for: .mediaBox)
            guard pageSize.width > 0, pageSize.height > 0 else { return }
            let target = PDFCoordinateSpace.pageRect(for: item.rect, pageSize: pageSize.size)
            let scale = Swift.max(1, Swift.min(view.bounds.width / Swift.max(target.width, 1), 4))
            view.scaleFactor = scale
            view.go(to: PDFDestination(page: page, at: CGPoint(x: target.midX, y: target.midY)))
        }

        /// Echo the user's final scroll position upward (never while we are
        /// restoring, so restoring cannot "move" the user).
        func reportMoved() {
            guard !restoring, let view = pdfView,
                  let page = view.currentPage, let document = view.document else { return }
            let pageSize = page.bounds(for: .mediaBox)
            let visible = view.convert(view.bounds, to: page)
            let visibleInPage = PDFCoordinateSpace.normalizedRect(for: visible, pageSize: pageSize.size)
            onMoved(document.index(for: page), visibleInPage)
        }
    }
}
