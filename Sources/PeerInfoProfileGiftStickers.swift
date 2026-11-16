import Foundation
import UIKit
import Display
import TelegramCore
import SwiftSignalKit
import AccountContext
import TelegramPresentationData
import GiftItemComponent
import PeerInfoVisualMediaPaneNode
import WalletGiftStickerMediaComponent
import WalletCardComponent

/// Concept: collectible gifts as stickers on your own profile.
///
/// A gift is peeled out of the Gifts tab with a long press, carried by the finger and laid down on the
/// profile header; a sticker that is already there can be peeled off again, moved, or dropped outside
/// the header to take it off. The peel / carry / lay-down motion is the one the wallet card uses for
/// its gift stickers (WalletGiftStickerCoordinator); the die-cut border takes the colour of the header
/// under the sticker instead of white.
///
/// This is a client-side prototype: placements are kept on the device only.
final class PeerInfoProfileGiftStickers: NSObject, UIGestureRecognizerDelegate {
    private struct Placement: Codable, Equatable {
        var slug: String
        var x: Double
        var y: Double
        var angle: Double
        var scale: Double
    }

    private struct Pose {
        var center: CGPoint
        var side: CGFloat
        var angle: CGFloat
        var lift: CGFloat = 0.0
        var front: CGFloat = 1.0
        var bend: CGFloat = 0.0
        var shade: CGFloat = 0.0
        var border: CGFloat = 1.0
        var opacity: CGFloat = 1.0
        var axis = CGPoint(x: 0.0, y: 1.0)
        var tilt: CGFloat = 0.0
    }

    private struct Drag {
        let gift: StarGift.UniqueGift
        let original: Pose
        let start: Double
        let fromSurface: Bool
        var center: CGPoint
        let offset: CGPoint
        var samples: [(time: Double, point: CGPoint)] = []

        func velocity(at now: Double) -> CGPoint {
            guard let first = self.samples.first, let last = self.samples.last, last.time - first.time > 0.008 else {
                return .zero
            }
            let dt = last.time - first.time
            let fade = exp(-max(0.0, now - last.time) / 0.09)
            return CGPoint(x: (last.point.x - first.point.x) / dt * fade, y: (last.point.y - first.point.y) / dt * fade)
        }
    }

    private struct Flight {
        let gift: StarGift.UniqueGift
        let from: Pose
        let start: Double
        let sticking: Bool
        var contacted = false
        var handedOff = false
    }

    private final class StickerView: UIView {
        let outline = UIImageView()
        let art = UIImageView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            self.isUserInteractionEnabled = false
            self.outline.layer.shadowColor = UIColor.black.cgColor
            self.outline.layer.shadowOpacity = 0.34
            self.addSubview(self.outline)
            self.addSubview(self.art)
        }

        required init?(coder: NSCoder) {
            preconditionFailure()
        }

        func update(frame stickerFrame: WalletGiftStickerFrame, side: CGFloat, color: UIColor) {
            self.bounds = CGRect(origin: CGPoint(), size: CGSize(width: side, height: side))
            self.outline.frame = self.bounds
            self.art.frame = self.bounds
            if self.art.image !== stickerFrame.art {
                self.art.image = stickerFrame.art
                self.outline.image = stickerFrame.silhouette.withRenderingMode(.alwaysTemplate)
            }
            self.outline.tintColor = color
            // the wallet prints this shadow into a 320 px sticker: 2.5 px down, 5.5 px blur
            self.outline.layer.shadowOffset = CGSize(width: 0.0, height: side * 2.5 / 320.0)
            self.outline.layer.shadowRadius = side * 2.75 / 320.0
        }
    }

    private final class DisplayLinkTarget: NSObject {
        weak var owner: PeerInfoProfileGiftStickers?
        @objc func tick() {
            self.owner?.tick()
        }
    }

    static let maxStickers = 10
    /// A sticker's width as a share of the surface width (the wallet card: 83.4 pt of 361).
    private static let widthFraction: CGFloat = 83.4 / 361.0
    private static let defaultScale: CGFloat = 0.9
    private static let heldScale: CGFloat = 1.4
    private static let contact: Double = 0.18
    private static let lay: Double = 0.42
    private static let silhouetteTag = 0x50474653

    private let context: AccountContext
    private let peerId: EnginePeer.Id
    private let profileGifts: ProfileGiftsContext
    private weak var hostView: UIView?
    private weak var headerNode: PeerInfoHeaderNode?
    private let giftsPane: () -> PeerInfoGiftsPaneNode?
    private let setScrollingEnabled: (Bool) -> Void

    private var placements: [Placement] = []
    private var media: [String: WalletGiftStickerMedia] = [:]
    private var stickerViews: [String: StickerView] = [:]
    private var hollowedCells = Set<String>()

    private var drag: Drag?
    private let dragView = WalletStickerWaveView(frame: CGRect())
    private var flights: [String: Flight] = [:]
    private var flightViews: [String: WalletStickerWaveView] = [:]
    private var composed: [String: (color: UIColor, image: UIImage)] = [:]

    private var displayLink: CADisplayLink?
    private var gesture: UILongPressGestureRecognizer?
    private var stateDisposable: Disposable?

    private var coverColors: (inner: UIColor, outer: UIColor, radial: Bool)?
    private var plainColor: UIColor = .white

    init(context: AccountContext, peerId: EnginePeer.Id, profileGifts: ProfileGiftsContext, hostView: UIView, headerNode: PeerInfoHeaderNode, giftsPane: @escaping () -> PeerInfoGiftsPaneNode?, setScrollingEnabled: @escaping (Bool) -> Void) {
        self.context = context
        self.peerId = peerId
        self.profileGifts = profileGifts
        self.hostView = hostView
        self.headerNode = headerNode
        self.giftsPane = giftsPane
        self.setScrollingEnabled = setScrollingEnabled

        super.init()

        if let data = UserDefaults.standard.data(forKey: self.storageKey), let value = try? JSONDecoder().decode([Placement].self, from: data) {
            self.placements = value
        }

        self.dragView.isHidden = true

        let gesture = UILongPressGestureRecognizer(target: self, action: #selector(self.longPress(_:)))
        gesture.minimumPressDuration = 0.3
        gesture.allowableMovement = 12.0
        gesture.delegate = self
        gesture.cancelsTouchesInView = false
        hostView.addGestureRecognizer(gesture)
        self.gesture = gesture

        headerNode.stickerSurfaceUpdated = { [weak self] in
            self?.sync()
        }

        self.stateDisposable = (profileGifts.state
        |> deliverOnMainQueue).start(next: { [weak self] _ in
            self?.sync()
        })
    }

    deinit {
        self.stateDisposable?.dispose()
        self.displayLink?.invalidate()
    }

    private var storageKey: String {
        return "peerInfo.profileGiftStickers.\(self.peerId.toInt64())"
    }

    private var surface: UIView? {
        return self.headerNode?.stickerSurfaceView
    }

    // MARK: Data

    func update(peer: EnginePeer?, presentationData: PresentationData) {
        var coverColors: (inner: UIColor, outer: UIColor, radial: Bool)?
        if let emojiStatus = peer?.emojiStatus, case let .starGift(_, _, _, _, _, innerColor, outerColor, _, _) = emojiStatus.content {
            coverColors = (UIColor(rgb: UInt32(bitPattern: innerColor)), UIColor(rgb: UInt32(bitPattern: outerColor)), true)
        } else if let profileColor = peer?.effectiveProfileColor {
            let colors = self.context.peerNameColors.getProfile(profileColor, dark: presentationData.theme.overallDarkAppearance)
            coverColors = (colors.main, colors.secondary ?? colors.main, false)
        }
        self.coverColors = coverColors
        self.plainColor = presentationData.theme.list.blocksBackgroundColor
        self.sync()
    }

    /// The Gifts grid has laid out its cells again.
    func contentUpdated() {
        self.syncCells()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(self.placements) {
            UserDefaults.standard.set(data, forKey: self.storageKey)
        }
    }

    private func gift(slug: String) -> StarGift.UniqueGift? {
        for item in self.profileGifts.currentState?.gifts ?? [] {
            if case let .unique(gift) = item.gift, gift.slug == slug {
                return gift
            }
        }
        return nil
    }

    private func media(for gift: StarGift.UniqueGift) -> WalletGiftStickerMedia {
        if let current = self.media[gift.slug] {
            return current
        }
        let media = WalletGiftStickerMedia(context: self.context, uniqueGift: gift)
        media.updated = { [weak self] in
            self?.sync()
        }
        self.media[gift.slug] = media
        return media
    }

    /// The header's colour under a point of the sticker surface — what the die-cut border is tinted with.
    private func outlineColor(at point: CGPoint, in size: CGSize) -> UIColor {
        guard let coverColors = self.coverColors, size.width > 0.0, size.height > 0.0 else {
            return self.plainColor
        }
        if coverColors.radial {
            // a worn gift: its inner colour glows around the avatar and falls off to the outer one
            let avatarY = size.height * 134.0 / 277.0
            let t = min(1.0, hypot((point.x - size.width * 0.5) / (size.width * 0.5), (point.y - avatarY) / 127.0))
            return coverColors.inner.mixedWith(coverColors.outer, alpha: t)
        } else {
            // a profile colour: the main colour at the bottom runs to the secondary one at the top
            let t = max(0.0, min(1.0, point.y / size.height))
            return coverColors.outer.mixedWith(coverColors.inner, alpha: t)
        }
    }

    /// The sticker bitmap the peel shader draws: tinted die-cut border with its small shadow, the art on top.
    private func composedImage(slug: String, frame: WalletGiftStickerFrame, color: UIColor) -> UIImage {
        if let current = self.composed[slug], current.color.isEqual(color) {
            return current.image
        }
        let size = frame.art.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let bounds = CGRect(origin: CGPoint(), size: size)
            renderer.cgContext.setShadow(offset: CGSize(width: 0.0, height: size.height * 2.5 / 320.0), blur: size.height * 5.5 / 320.0, color: UIColor.black.withAlphaComponent(0.34).cgColor)
            color.setFill()
            frame.silhouette.withRenderingMode(.alwaysTemplate).draw(in: bounds)
            renderer.cgContext.setShadow(offset: .zero, blur: 0.0, color: nil)
            frame.art.draw(in: bounds)
        }
        self.composed[slug] = (color, image)
        return image
    }

    // MARK: Layout

    private func stickerSide(scale: CGFloat) -> CGFloat {
        return (self.surface?.bounds.width ?? 0.0) * Self.widthFraction * scale
    }

    private func pose(_ placement: Placement) -> Pose? {
        guard let surface = self.surface, let hostView = self.hostView, surface.bounds.width > 0.0 else {
            return nil
        }
        let local = CGPoint(x: CGFloat(placement.x) * surface.bounds.width, y: CGFloat(placement.y) * surface.bounds.height)
        return Pose(center: surface.convert(local, to: hostView), side: self.stickerSide(scale: CGFloat(placement.scale)), angle: CGFloat(placement.angle))
    }

    /// Where a gift's model sits in its grid cell, as a sticker pose (the art is 93% of a sticker's side).
    private func cellPose(_ cell: GiftItemComponent.View) -> Pose? {
        guard let hostView = self.hostView, cell.window != nil else {
            return nil
        }
        let frame = cell.convert(cell.bounds, to: hostView)
        let modelSide = floor(88.0 * frame.width / 116.0)
        return Pose(center: CGPoint(x: frame.midX, y: frame.midY), side: modelSide / WalletGiftStickerMedia.contentFraction, angle: 0.0)
    }

    private func sync() {
        guard let surface = self.surface, surface.bounds.width > 0.0 else {
            return
        }
        let size = surface.bounds.size
        var valid = Set<String>()
        for placement in self.placements {
            guard let gift = self.gift(slug: placement.slug), let frame = self.media(for: gift).first else {
                continue
            }
            valid.insert(placement.slug)
            let view: StickerView
            if let current = self.stickerViews[placement.slug] {
                view = current
            } else {
                view = StickerView(frame: CGRect())
                self.stickerViews[placement.slug] = view
                surface.addSubview(view)
            }
            let center = CGPoint(x: CGFloat(placement.x) * size.width, y: CGFloat(placement.y) * size.height)
            view.transform = .identity
            view.update(frame: frame, side: self.stickerSide(scale: CGFloat(placement.scale)), color: self.outlineColor(at: center, in: size))
            view.center = center
            view.transform = CGAffineTransform(rotationAngle: CGFloat(placement.angle))
            let inTheAir = self.drag?.gift.slug == placement.slug || (self.flights[placement.slug].map { !$0.handedOff } ?? false)
            view.isHidden = inTheAir
        }
        for (slug, view) in self.stickerViews where !valid.contains(slug) {
            view.removeFromSuperview()
            self.stickerViews.removeValue(forKey: slug)
        }
        self.syncCells()
    }

    /// A gift that is out on the profile (or in the air) leaves a hollow of its own shape in its cell.
    private func syncCells() {
        guard let pane = self.giftsPane() else {
            return
        }
        var hollow = Set(self.placements.map { $0.slug })
        if let drag = self.drag {
            hollow.insert(drag.gift.slug)
        }
        for (slug, flight) in self.flights where !flight.sticking {
            hollow.insert(slug)
        }
        for slug in hollow.union(self.hollowedCells) {
            guard let cell = pane.stickerCell(slug: slug) else {
                continue
            }
            let isHollow = hollow.contains(slug)
            cell.setModelHidden(isHollow)
            let silhouette: UIImageView
            if let current = cell.viewWithTag(Self.silhouetteTag) as? UIImageView {
                silhouette = current
            } else if isHollow {
                silhouette = UIImageView()
                silhouette.tag = Self.silhouetteTag
                silhouette.isUserInteractionEnabled = false
                cell.addSubview(silhouette)
            } else {
                continue
            }
            silhouette.isHidden = !isHollow
            if isHollow, let gift = self.gift(slug: slug), let frame = self.media(for: gift).first {
                let side = floor(88.0 * cell.bounds.width / 116.0)
                silhouette.frame = CGRect(x: (cell.bounds.width - side) * 0.5, y: (cell.bounds.height - side) * 0.5, width: side, height: side)
                if silhouette.image == nil {
                    silhouette.image = frame.art.withRenderingMode(.alwaysTemplate)
                }
                var tint = UIColor(white: 0.0, alpha: 0.12)
                for attribute in gift.attributes {
                    if case let .backdrop(_, _, _, outerColor, _, _, _) = attribute {
                        tint = UIColor(rgb: UInt32(bitPattern: outerColor)).withMultiplied(hue: 1.0, saturation: 1.1, brightness: 0.86)
                    }
                }
                silhouette.tintColor = tint
            }
        }
        self.hollowedCells = hollow
    }

    // MARK: Touch

    private func sticker(at point: CGPoint) -> Placement? {
        guard let surface = self.surface, let hostView = self.hostView, surface.alpha > 0.5 else {
            return nil
        }
        let local = hostView.convert(point, to: surface)
        for placement in self.placements.reversed() {
            let center = CGPoint(x: CGFloat(placement.x) * surface.bounds.width, y: CGFloat(placement.y) * surface.bounds.height)
            if hypot(center.x - local.x, center.y - local.y) < self.stickerSide(scale: CGFloat(placement.scale)) * 0.45 {
                return placement
            }
        }
        return nil
    }

    private func candidate(at point: CGPoint) -> (gift: StarGift.UniqueGift, cell: GiftItemComponent.View)? {
        guard let hostView = self.hostView, let pane = self.giftsPane(), let candidate = pane.stickerCandidate(at: point, in: hostView) else {
            return nil
        }
        if self.placements.contains(where: { $0.slug == candidate.gift.slug }) {
            return nil
        }
        return candidate
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let hostView = self.hostView, self.drag == nil else {
            return false
        }
        let point = touch.location(in: hostView)
        return self.sticker(at: point) != nil || self.candidate(at: point) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    @objc private func longPress(_ recognizer: UILongPressGestureRecognizer) {
        guard let hostView = self.hostView else {
            return
        }
        let point = recognizer.location(in: hostView)
        switch recognizer.state {
        case .began:
            if !self.begin(at: point) {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
        case .changed:
            self.move(to: point)
        case .ended:
            self.release(cancelled: false)
        case .cancelled, .failed:
            self.release(cancelled: true)
        default:
            break
        }
    }

    private func begin(at point: CGPoint) -> Bool {
        guard self.drag == nil, let hostView = self.hostView else {
            return false
        }
        let gift: StarGift.UniqueGift
        let original: Pose
        let fromSurface: Bool
        if let placement = self.sticker(at: point), let value = self.gift(slug: placement.slug), let pose = self.pose(placement) {
            gift = value
            original = pose
            fromSurface = true
        } else if let candidate = self.candidate(at: point), let pose = self.cellPose(candidate.cell) {
            gift = candidate.gift
            original = pose
            fromSurface = false
            // the cell's own long press (the context menu) gives way to the sticker
            for recognizer in candidate.cell.gestureRecognizers ?? [] where recognizer.isEnabled {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
        } else {
            return false
        }
        guard self.media(for: gift).first != nil else {
            return false
        }
        self.flights.removeValue(forKey: gift.slug)
        self.flightViews.removeValue(forKey: gift.slug)?.removeFromSuperview()

        self.drag = Drag(gift: gift, original: original, start: CACurrentMediaTime(), fromSurface: fromSurface, center: original.center, offset: CGPoint(x: original.center.x - point.x, y: original.center.y - point.y))
        self.setScrollingEnabled(false)
        if self.dragView.superview !== hostView {
            hostView.addSubview(self.dragView)
        }
        hostView.bringSubviewToFront(self.dragView)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        self.startClock()
        self.sync()
        self.tick()
        return true
    }

    private func move(to point: CGPoint) {
        guard var drag = self.drag else {
            return
        }
        let now = CACurrentMediaTime()
        drag.center = CGPoint(x: point.x + drag.offset.x, y: point.y + drag.offset.y)
        drag.samples.append((now, point))
        drag.samples.removeAll { now - $0.time > 0.12 }
        self.drag = drag
    }

    private func dragPose(_ drag: Drag, now: Double) -> Pose {
        let peel = Self.ease((now - drag.start) / 0.3)
        let raise = Self.ease((now - drag.start - 0.225) / 0.26)
        let side = self.stickerSide(scale: Self.defaultScale) * Self.heldScale
        var pose = Self.mix(drag.original, Pose(center: drag.center, side: side, angle: drag.original.angle), raise)
        let velocity = drag.velocity(at: now)
        let speed = hypot(velocity.x, velocity.y)
        pose.angle += max(-0.25, min(0.25, velocity.x * 0.00035)) * raise
        pose.tilt = min(14.0, speed * 0.009) * raise
        if speed > 1.0 {
            pose.axis = CGPoint(x: -velocity.y / speed, y: velocity.x / speed)
        }
        pose.border = drag.fromSurface ? 1.0 : min(1.0, peel * 1.3)
        pose.lift = raise
        pose.front = 1.0 - peel
        pose.bend = 0.75 * (1.0 - raise)
        pose.shade = 1.0 - raise
        return pose
    }

    private func release(cancelled: Bool) {
        guard let drag = self.drag, let hostView = self.hostView else {
            return
        }
        let now = CACurrentMediaTime()
        let from = self.dragPose(drag, now: now)
        self.drag = nil
        self.dragView.isHidden = true
        self.setScrollingEnabled(true)

        let slug = drag.gift.slug
        var placed = false
        if !cancelled, let surface = self.surface, surface.alpha > 0.5, surface.bounds.width > 0.0 {
            let local = hostView.convert(from.center, to: surface)
            let size = surface.bounds.size
            let reach = self.stickerSide(scale: Self.defaultScale) * 0.3
            let isNew = !self.placements.contains(where: { $0.slug == slug })
            if surface.bounds.insetBy(dx: -reach, dy: -reach).contains(local) && (!isNew || self.placements.count < Self.maxStickers) {
                let edge = self.stickerSide(scale: Self.defaultScale) * 0.3
                let center = CGPoint(x: min(size.width - edge, max(edge, local.x)), y: min(size.height - edge, max(edge, local.y)))
                self.placements.removeAll { $0.slug == slug }
                self.placements.append(Placement(slug: slug, x: Double(center.x / size.width), y: Double(center.y / size.height), angle: Double(max(-0.3, min(0.3, from.angle))), scale: Double(Self.defaultScale)))
                placed = true
            }
        }
        if !placed {
            self.placements.removeAll { $0.slug == slug }
        }
        self.save()
        self.flights[slug] = Flight(gift: drag.gift, from: from, start: now, sticking: placed)
        self.sync()
        self.startClock()
    }

    // MARK: Clock

    private func startClock() {
        guard self.displayLink == nil else {
            return
        }
        let target = DisplayLinkTarget()
        target.owner = self
        let displayLink = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    private func stopClock() {
        self.displayLink?.invalidate()
        self.displayLink = nil
    }

    private func tick() {
        guard let hostView = self.hostView, hostView.window != nil else {
            self.drag = nil
            self.dragView.isHidden = true
            for (_, view) in self.flightViews {
                view.removeFromSuperview()
            }
            self.flights.removeAll()
            self.flightViews.removeAll()
            self.stopClock()
            return
        }
        let now = CACurrentMediaTime()
        if let drag = self.drag, let frame = self.media(for: drag.gift).first {
            self.dragView.isHidden = false
            self.render(self.dragView, gift: drag.gift, frame: frame, pose: self.dragPose(drag, now: now))
        }
        self.tickFlights(now: now)
        if self.drag == nil && self.flights.isEmpty {
            self.stopClock()
        }
    }

    private func tickFlights(now: Double) {
        guard let hostView = self.hostView else {
            return
        }
        for (slug, initial) in self.flights {
            var flight = initial
            let elapsed = max(0.0, now - flight.start)
            let a = flight.from
            var pose = a
            var finished = false
            if flight.sticking, let placement = self.placements.first(where: { $0.slug == slug }), var target = self.pose(placement) {
                // touch down, then lie flat from the top edge to the bottom one
                target.angle = a.angle + atan2(sin(target.angle - a.angle), cos(target.angle - a.angle))
                let e = Self.ease(elapsed / Self.contact)
                pose = Self.mix(a, target, e)
                pose.border = a.border + (1.0 - a.border) * e
                pose.tilt = a.tilt * (1.0 - e)
                pose.axis = a.axis
                pose.lift = a.lift * (1.0 - e)
                pose.bend = 0.75 * e
                pose.shade = e
                pose.front = Self.ease((elapsed - Self.contact) / Self.lay)
                if elapsed >= Self.contact && !flight.contacted {
                    flight.contacted = true
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                }
                if elapsed >= Self.contact + Self.lay {
                    pose.bend = 0.0
                    pose.shade = 0.0
                    if !flight.handedOff {
                        flight.handedOff = true
                        self.flights[slug] = flight
                        self.sync()
                    }
                    pose.opacity = 1.0 - Self.ease((elapsed - Self.contact - Self.lay) / 0.2)
                    finished = elapsed >= Self.contact + Self.lay + 0.2
                }
            } else if let cell = self.giftsPane()?.stickerCell(slug: slug), let target = self.cellPose(cell) {
                // back into its cell: an arc home, the border fades as it lies down
                let travel = 0.44, homeLay = 0.4
                let u = CGFloat(min(1.0, elapsed / travel))
                let e = 1.0 - (1.0 - u) * (1.0 - u)
                let landed = elapsed - travel
                if landed >= 0.0 {
                    let lay = Self.ease(landed / homeLay)
                    pose = target
                    pose.border = a.border * (1.0 - Self.ease(Double((lay - 0.55) / 0.45)))
                    pose.front = lay
                    pose.bend = lay < 1.0 ? 0.75 : 0.0
                    pose.shade = lay < 1.0 ? 1.0 - lay : 0.0
                    finished = landed >= homeLay
                } else {
                    let distance = hypot(target.center.x - a.center.x, target.center.y - a.center.y)
                    let control = CGPoint(x: (a.center.x + target.center.x) * 0.5, y: (a.center.y + target.center.y) * 0.5 - min(90.0, distance * 0.28))
                    let w = 1.0 - e
                    let arc = sin(.pi * e)
                    pose = Self.mix(a, target, e)
                    pose.center = CGPoint(x: w * w * a.center.x + 2.0 * w * e * control.x + e * e * target.center.x, y: w * w * a.center.y + 2.0 * w * e * control.y + e * e * target.center.y)
                    pose.side *= 1.0 + 0.05 * arc
                    pose.angle = a.angle * (1.0 - e)
                    pose.lift = 0.8 * arc
                    pose.border = a.border
                    let tip = Self.ease(Double((u - 0.55) / 0.45))
                    pose.front = 0.0
                    pose.bend = 0.75 * tip
                    pose.shade = tip
                }
            } else {
                // its cell is out of sight: the sticker just lets go
                pose.opacity = 1.0 - CGFloat(min(1.0, elapsed / 0.25))
                finished = elapsed >= 0.25
            }

            if finished {
                self.flights.removeValue(forKey: slug)
                self.flightViews.removeValue(forKey: slug)?.removeFromSuperview()
                self.sync()
                continue
            }
            self.flights[slug] = flight
            guard let frame = self.media(for: flight.gift).first else {
                continue
            }
            let view: WalletStickerWaveView
            if let current = self.flightViews[slug] {
                view = current
            } else {
                view = WalletStickerWaveView(frame: CGRect())
                self.flightViews[slug] = view
                hostView.addSubview(view)
            }
            self.render(view, gift: flight.gift, frame: frame, pose: pose)
        }
    }

    private func render(_ view: WalletStickerWaveView, gift: StarGift.UniqueGift, frame: WalletGiftStickerFrame, pose: Pose) {
        var color = self.plainColor
        if let surface = self.surface, let hostView = self.hostView {
            let local = hostView.convert(pose.center, to: surface)
            let size = surface.bounds.size
            color = self.outlineColor(at: CGPoint(x: min(size.width, max(0.0, local.x)), y: min(size.height, max(0.0, local.y))), in: size)
        }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        view.bounds = CGRect(x: 0.0, y: 0.0, width: pose.side * 1.6, height: pose.side * 1.6)
        view.center = pose.center
        view.alpha = pose.opacity
        var transform = CATransform3DIdentity
        transform.m34 = -1.0 / max(1.0, pose.side * 3.0)
        transform = CATransform3DRotate(transform, pose.angle, 0.0, 0.0, 1.0)
        if !reduceMotion {
            transform = CATransform3DRotate(transform, pose.tilt * .pi / 180.0, pose.axis.x, pose.axis.y, 0.0)
        }
        view.layer.transform = transform
        view.update(image: self.composedImage(slug: gift.slug, frame: frame, color: color), art: frame.art, border: pose.border, front: pose.front, bend: reduceMotion ? 0.0 : pose.bend, shade: reduceMotion ? 0.0 : pose.shade, lift: pose.lift)
    }

    private static func ease(_ value: Double) -> CGFloat {
        let t = CGFloat(max(0.0, min(1.0, value)))
        return t * t * (3.0 - 2.0 * t)
    }

    private static func mix(_ a: Pose, _ b: Pose, _ t: CGFloat) -> Pose {
        return Pose(center: CGPoint(x: a.center.x + (b.center.x - a.center.x) * t, y: a.center.y + (b.center.y - a.center.y) * t), side: a.side + (b.side - a.side) * t, angle: a.angle + (b.angle - a.angle) * t, opacity: a.opacity + (b.opacity - a.opacity) * t)
    }
}
