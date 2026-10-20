//
//  RAVEPageDriver+Frames.swift
//  RAVEBrowser
//
//  Iframes, for the driver: where each sits on the page, and what is in them.
//
//  WebKit hands out a frame's `WKFrameInfo` (`RAVEPageFrames`), but not its
//  parent or its position. So each document reports its own iframes'
//  content boxes, and a child frame is matched to the iframe whose `src` is
//  its address, top-down: the page's iframes first, then theirs. A frame
//  with no match (a `src` that redirected elsewhere, one written by script)
//  is still listed by `frames()` and reachable through `evaluate(frame:)`,
//  but its elements are listed only for the whole page and can only be
//  pressed synthetically.
//
//  An iframe's elements are numbered after the page's own, so a model sees
//  one list. Their boxes are moved into the page's viewport, which is what a
//  marked snapshot draws and where a real click must land, and an element
//  covered by something on the page (a dialog over a payment form) is left
//  out of a viewport listing as it would be in the page itself.
//

#if canImport(WebKit)
import CoreGraphics
import Foundation
import WebKit

extension RAVEPageDriver {
    /// One iframe's content box, as its parent document reports it.
    struct FrameGeometry: Decodable {
        struct Child: Decodable {
            var src: String
            var x: Double
            var y: Double
            var w: Double
            var h: Double
            var shown: Bool
        }

        var id: String?
        var url: String
        var width: Double
        var height: Double
        var frames: [Child]
    }

    struct PlacedFrame {
        var frame: RAVEPageFrames.Frame
        var url: String
        /// The frame's viewport origin in the page's viewport, when placed.
        var offset: CGPoint?
        /// The part of it on screen, in the page's viewport.
        var visible: CGRect?
        /// Which of the page's own iframes it is, or is inside of.
        var topIndex: Int?
    }

    /// The page's iframes: id, address, and where each is on screen.
    public func frames() async -> [RAVEPageFrame] {
        await placeFrames().map { placed in
            RAVEPageFrame(id: placed.frame.id, url: placed.url,
                          x: placed.offset.map { Double($0.x) }, y: placed.offset.map { Double($0.y) },
                          w: placed.visible.map { Double($0.width) }, h: placed.visible.map { Double($0.height) },
                          visible: placed.visible.map { !$0.isEmpty } ?? false)
        }
    }

    /// Asks every registered frame for its geometry, drops the ones that are
    /// gone or have moved on to another document, and places the rest.
    func placeFrames() async -> [PlacedFrame] {
        guard let registry = frames, !registry.frames.isEmpty,
              let top: FrameGeometry = try? await run(RAVEPageScripts.frameGeometry) else { return [] }
        var geometries: [String: FrameGeometry] = [:]
        var live: [RAVEPageFrames.Frame] = []
        for frame in registry.frames {
            let geometry: FrameGeometry? = try? await run(RAVEPageScripts.frameGeometry, deadline: .seconds(2), in: frame.info)
            guard let geometry, geometry.id == frame.id else {
                registry.forget(frame.id)
                continue
            }
            geometries[frame.id] = geometry
            live.append(frame)
        }

        var placed: [String: PlacedFrame] = [:]
        let page = CGRect(x: 0, y: 0, width: top.width, height: top.height)
        // Breadth first: the page's iframes, then the ones inside each.
        var parents: [(children: [FrameGeometry.Child], offset: CGPoint, visible: CGRect, topIndex: Int?)] = [
            (top.frames, .zero, page, nil),
        ]
        while !parents.isEmpty {
            let parent = parents.removeFirst()
            for (index, child) in parent.children.enumerated() where child.shown {
                guard let frame = live.first(where: { placed[$0.id] == nil && Self.sameDocument(geometries[$0.id]?.url, child.src) })
                else { continue }
                let offset = CGPoint(x: parent.offset.x + child.x, y: parent.offset.y + child.y)
                let visible = parent.visible.intersection(CGRect(origin: offset, size: CGSize(width: child.w, height: child.h)))
                let topIndex = parent.topIndex ?? index
                placed[frame.id] = PlacedFrame(frame: frame, url: geometries[frame.id]?.url ?? frame.url, offset: offset,
                                               visible: visible.isNull ? .zero : visible, topIndex: topIndex)
                if let geometry = geometries[frame.id] {
                    parents.append((geometry.frames, offset, visible.isNull ? .zero : visible, topIndex))
                }
            }
        }
        return live.map { frame in
            placed[frame.id] ?? PlacedFrame(frame: frame, url: geometries[frame.id]?.url ?? frame.url,
                                            offset: nil, visible: nil, topIndex: nil)
        }
    }

    /// The same address, ignoring the fragment: an iframe's `src` and the
    /// document it loaded.
    static func sameDocument(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        func strip(_ s: String) -> String { s.split(separator: "#", maxSplits: 1).first.map(String.init) ?? s }
        return strip(a) == strip(b)
    }

    /// Appends each placed frame's elements to `list`, numbered after it,
    /// and records their routes.
    func addFrameElements(to list: inout RAVEPageElements, scope: Scope, limit: Int) async {
        let placed = await placeFrames()
        var next = (list.elements.map(\.ref).max() ?? 0) + 1
        // What the page itself listed fills `limit`; frames get room of their
        // own, so a page full of links still shows the payment form in its
        // iframe.
        var budget = min(100, max(30, limit - list.elements.count))
        for frame in placed where budget > 0 {
            guard scope == .page || frame.visible.map({ !$0.isEmpty }) == true else { continue }
            guard let inner: RAVEPageElements = try? await run(
                RAVEPageScripts.elements, ["scope": scope.rawValue, "limit": budget], in: frame.frame.info)
            else { continue }
            var found: [(element: RAVEPageElement, local: Int)] = []
            for var element in inner.elements {
                let local = element.ref
                if let offset = frame.offset {
                    element.x += offset.x
                    element.y += offset.y
                }
                if scope == .viewport, let visible = frame.visible,
                   !visible.contains(CGPoint(x: element.x + element.w / 2, y: element.y + element.h / 2)) { continue }
                element.inFrame = URL(string: frame.url)?.host() ?? frame.url
                found.append((element, local))
            }
            // Covered on the page: a dialog over the iframe hides what is in it.
            if scope == .viewport, let topIndex = frame.topIndex, !found.isEmpty {
                let points = found.map { [$0.element.x + $0.element.w / 2, $0.element.y + $0.element.h / 2] }
                if let shown: [Bool] = try? await run(RAVEPageScripts.framePointsShown, ["points": points, "frame": topIndex]),
                   shown.count == found.count {
                    found = zip(found, shown).filter(\.1).map(\.0)
                }
            }
            for (element, local) in found {
                var element = element
                element.ref = next
                routes[next] = Route(frame: frame.frame, local: local, offset: frame.offset)
                list.elements.append(element)
                next += 1
                budget -= 1
            }
            list.total += found.count
        }
    }
}
#endif
