// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryListViewController.swift
//  Rivulet
//
//  A movie or show library (Plex or Jellyfin) as one long list: the focused title's
//  poster, facts and summary on the left (Infuse's layout), the titles on
//  the right in the Apple TV app's sidebar rows, over the focused title's
//  artwork reduced to its colours. Fast scrolling is the system's: the
//  collection scrolls itself, so the focus engine's index bar works, and a
//  title sort feeds it letters.
//

import UIKit
import Combine

@MainActor
final class LibraryListViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {

    private enum Layout {
        static let margin: CGFloat = 80
        /// The list's capsules span this column; the preview takes everything left of it.
        static let listX: CGFloat = 940
        static let headerTop: CGFloat = 92
        static let listTop: CGFloat = 186
        static let fade: CGFloat = 36
    }

    private static let pageSize = 100
    private static let lookAhead = 30
    private static let detailDelay: Duration = .milliseconds(180)

    private let library: MediaLibrary
    /// Where sort is saved: the Plex section key, or a provider library's `settingsKey`.
    private let settingsKey: String
    private let viewMenu: () -> UIMenu?

    private let ambient = AmbientBackdropView()
    /// Keeps white text legible on a bright wash.
    private let scrim = UIView()
    private let preview = LibraryListPreviewView()
    private let titleLabel = MusicChrome.label(size: 57, weight: .medium)
    private let sortButton = SortButton()
    private let viewButton = SortButton()
    private let listContainer = UIView()
    private let fadeMask = CAGradientLayer()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private let spinner = UIActivityIndicatorView(style: .large)
    private let emptyLabel = MusicChrome.label(size: 31, weight: .regular, color: UIColor(white: 1, alpha: 0.6))
    /// Holds focus while there are no rows, so Menu and Left still work.
    private let anchor = PreviewFocusAnchorView()

    private var rows: [MediaItem?] = []
    private var loaded = false
    private var pagesRequested = Set<Int>()
    private var generation = 0
    private var sort: LibrarySortOption
    private var alphabet: LibraryAlphabetIndex?
    private var focusedSlot: Int?
    private var pendingTopFocus = false
    /// Genres and cast, which list items do not carry, fetched once a row settles.
    private var details: [MediaItemRef: MediaItemDetail] = [:]
    private var previewTask: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()

    init(library: MediaLibrary, settingsKey: String, viewMenu: @escaping () -> UIMenu?) {
        self.library = library
        self.settingsKey = settingsKey
        self.viewMenu = viewMenu
        self.sort = LibrarySettingsManager.shared.getSortOption(for: settingsKey)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var provider: (any MediaProvider)? {
        MediaProviderRegistry.shared.provider(for: library.providerID)
    }

    // MARK: - View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        // Music's Now Playing wash: the artwork reduced to its colours, as the TV app's library does.
        ambient.showsVignette = false
        ambient.imageTransform = MusicNowPlayingViewController.wash
        scrim.backgroundColor = UIColor(white: 0, alpha: 0.38)
        for layer in [ambient, scrim] as [UIView] {
            layer.frame = view.bounds
            layer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(layer)
        }

        preview.frame = CGRect(x: Layout.margin, y: ShellPillMetrics.contentClearance,
                               width: Layout.listX - Layout.margin * 2,
                               height: view.bounds.height - ShellPillMetrics.contentClearance - 50)
        view.addSubview(preview)

        titleLabel.text = library.title
        titleLabel.frame = CGRect(x: Layout.listX + 30, y: Layout.headerTop, width: 520, height: 72)
        view.addSubview(titleLabel)
        for button in [sortButton, viewButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(button)
        }
        let columnTrailing = view.bounds.width - Layout.margin
        NSLayoutConstraint.activate([
            viewButton.trailingAnchor.constraint(equalTo: view.leadingAnchor, constant: columnTrailing),
            viewButton.centerYAnchor.constraint(equalTo: view.topAnchor, constant: Layout.headerTop + 36),
            sortButton.trailingAnchor.constraint(equalTo: viewButton.leadingAnchor, constant: -20),
            sortButton.centerYAnchor.constraint(equalTo: viewButton.centerYAnchor),
        ])
        configureButtons()

        // The container masks the list's top and bottom into the page; it is wider
        // than the column so a focused capsule's scale and shadow are not clipped.
        let bleed: CGFloat = 40
        listContainer.frame = CGRect(x: Layout.listX - bleed, y: Layout.listTop,
                                     width: columnTrailing - Layout.listX + bleed * 2,
                                     height: view.bounds.height - Layout.listTop)
        fadeMask.frame = listContainer.bounds
        let height = listContainer.bounds.height
        fadeMask.colors = [UIColor.clear, .black, .black, .clear].map(\.cgColor)
        fadeMask.locations = [0, Layout.fade / height, 1 - Layout.fade * 3 / height, 1].map { NSNumber(value: Double($0)) }
        listContainer.layer.mask = fadeMask
        view.addSubview(listContainer)

        collectionView.frame = listContainer.bounds.insetBy(dx: bleed, dy: 0)
        collectionView.backgroundColor = .clear
        collectionView.clipsToBounds = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.contentInset = UIEdgeInsets(top: Layout.fade, left: 0, bottom: Layout.fade * 3, right: 0)
        collectionView.remembersLastFocusedIndexPath = true
        collectionView.register(LibraryListRowCell.self, forCellWithReuseIdentifier: LibraryListRowCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        listContainer.addSubview(collectionView)

        let stateFrame = CGRect(x: Layout.listX, y: Layout.listTop + Layout.fade,
                                width: columnTrailing - Layout.listX, height: 90)
        emptyLabel.frame = stateFrame
        emptyLabel.isHidden = true
        spinner.center = CGPoint(x: stateFrame.midX, y: stateFrame.midY)
        anchor.frame = stateFrame
        [emptyLabel, spinner, anchor].forEach(view.addSubview)
        spinner.startAnimating()

        NotificationCenter.default.publisher(for: .plexDataNeedsRefresh)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadLoadedPages() }
            .store(in: &observers)

        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        MenuPressInterceptor.register(self)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        MenuPressInterceptor.resign(self)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        anchor.isHidden ? [collectionView] : [anchor]
    }

    private func makeLayout() -> UICollectionViewLayout {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1),
                                          heightDimension: .absolute(LibraryListRowCell.pitch))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size,
                                                     subitems: [NSCollectionLayoutItem(layoutSize: size)])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsetsReference = .none
        return UICollectionViewCompositionalLayout(section: section)
    }

    // MARK: - Header

    private func configureButtons() {
        sortButton.configure(sortName: sort.displayName)
        sortButton.menu = UIMenu(children: PlexHomeViewController.providerSortOptions(for: library.kind).map { option in
            UIAction(title: option.displayName, state: option == sort ? .on : .off) { [weak self] _ in
                self?.applySort(option)
            }
        })
        sortButton.showsMenuAsPrimaryAction = true
        viewButton.configure(view: .list, menu: viewMenu())
    }

    // Fresh View items on focus: Collections joins once the grid has seen some.
    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.nextFocusedView === viewButton { viewButton.menu = viewMenu() }
    }

    private func applySort(_ option: LibrarySortOption) {
        guard option != sort else { return }
        sort = option
        LibrarySettingsManager.shared.setSortOption(option, for: settingsKey)
        configureButtons()
        reload()
    }

    // MARK: - Data

    /// Page 0 and the letter counts together, so the index bar is right from the first frame.
    private func reload() {
        generation += 1
        let gen = generation
        pagesRequested = [0]
        focusedSlot = nil
        guard let provider else { updateState(failed: true); return }
        let library = self.library, sort = self.sort
        let wantsLetters = sort == .titleAsc || sort == .titleDesc
        Task { [weak self] in
            async let page = provider.items(in: library, sort: PlexHomeViewController.providerSort(sort),
                                            page: Page(offset: 0, limit: Self.pageSize))
            async let letters: [PlexFirstCharacter]? = wantsLetters ? try? provider.letterCounts(in: library) : nil
            let result = try? await page
            let characters = await letters
            guard let self, gen == self.generation else { return }
            self.loaded = true
            self.alphabet = characters
                .map { LibraryAlphabetIndex(characters: $0, descending: sort == .titleDesc) }
                .flatMap { $0.entries.count > 1 ? $0 : nil }
            let items = result?.items ?? []
            let total = result?.total ?? items.count
            self.rows = Array(repeating: nil, count: total)
            for (offset, item) in items.enumerated() where offset < total { self.rows[offset] = item }
            if result == nil { self.pagesRequested = [] }
            self.collectionView.reloadData()
            self.collectionView.setContentOffset(CGPoint(x: 0, y: -self.collectionView.contentInset.top), animated: false)
            self.updateState(failed: result == nil)
            if let first = self.rows.first ?? nil { self.showPreview(first) }
        }
    }

    /// Fetches the page holding `slot` unless it is loaded or in flight. Slots keep
    /// their identity, so a landed page only reconfigures the cells on screen.
    private func loadPage(containing slot: Int) {
        guard loaded, slot >= 0, slot < rows.count, let provider else { return }
        let page = slot / Self.pageSize
        guard pagesRequested.insert(page).inserted else { return }
        let gen = generation, library = self.library, sort = PlexHomeViewController.providerSort(self.sort)
        let start = page * Self.pageSize
        Task { [weak self] in
            let result = try? await provider.items(in: library, sort: sort, page: Page(offset: start, limit: Self.pageSize))
            guard let self, gen == self.generation else { return }
            guard let result else { self.pagesRequested.remove(page); return }
            self.land(result.items, at: start)
        }
    }

    private func land(_ page: [MediaItem], at start: Int) {
        let end = min(start + page.count, rows.count)
        guard start < end else { return }
        for slot in start..<end { rows[slot] = page[slot - start] }
        let visible = collectionView.indexPathsForVisibleItems.filter { (start..<end).contains($0.item) }
        if !visible.isEmpty { collectionView.reconfigureItems(at: visible) }
        if let focusedSlot, (start..<end).contains(focusedSlot), let item = rows[focusedSlot] { showPreview(item) }
    }

    /// Watch state may have changed: re-read every page already loaded, in place.
    private func reloadLoadedPages() {
        guard loaded else { return }
        let pages = pagesRequested
        pagesRequested = []
        generation += 1
        for page in pages.sorted() { loadPage(containing: page * Self.pageSize) }
    }

    private func updateState(failed: Bool) {
        let empty = rows.isEmpty
        spinner.stopAnimating()
        spinner.isHidden = true
        emptyLabel.text = failed ? String(localized: "Couldn't load this library") : String(localized: "This library is empty.")
        emptyLabel.isHidden = !empty
        let hadNoRows = !anchor.isHidden
        anchor.isHidden = !empty
        if hadNoRows, !empty {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
            NotificationCenter.default.post(name: .contentBecameFocusable, object: nil)
        }
    }

    // MARK: - Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: LibraryListRowCell.reuseID,
                                                      for: indexPath) as! LibraryListRowCell
        if let item = rows[indexPath.item] {
            cell.configure(title: item.title, state: LibraryWatchGlyphView.State(item))
        } else {
            cell.configure(title: "", state: nil)
        }
        return cell
    }

    /// The fast-scroll index's letters, only while the list is sorted by title.
    func indexTitles(for collectionView: UICollectionView) -> [String]? {
        alphabet?.entries.map(\.title)
    }

    func collectionView(_ collectionView: UICollectionView, indexPathForIndexTitle title: String, at index: Int) -> IndexPath {
        let slot = alphabet?.entries[safe: index]?.offset ?? 0
        loadPage(containing: slot)
        return IndexPath(item: min(slot, max(0, rows.count - 1)), section: 0)
    }

    // MARK: - Delegate

    // Paging is keyed on display, not focus: during a fast scroll the engine issues no focus moves.
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        loadPage(containing: indexPath.item)
        loadPage(containing: indexPath.item + Self.lookAhead)
        loadPage(containing: indexPath.item - Self.lookAhead)
    }

    func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        let path = IndexPath(item: focusedSlot ?? 0, section: 0)
        return collectionView.cellForItem(at: path) != nil ? path : nil
    }

    func collectionView(_ collectionView: UICollectionView, didUpdateFocusIn context: UICollectionViewFocusUpdateContext,
                        with coordinator: UIFocusAnimationCoordinator) {
        guard let path = context.nextFocusedIndexPath else { return }
        focusedSlot = path.item
        if let item = rows[safe: path.item] ?? nil { showPreview(item) }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let item = rows[safe: indexPath.item] ?? nil else { return }
        if PlexHomeViewController.openCollectionIfNeeded(item, from: self) { return }
        let detail = PreviewCarouselViewController(
            items: [item], selectedIndex: 0, sourceFrame: .zero, sourceTarget: nil,
            standaloneDetail: true, onDismiss: { _ in })
        present(detail, animated: true)
    }

    // MARK: - Preview

    /// What the list item carries shows at once; genres and cast follow once
    /// focus has rested on the row.
    private func showPreview(_ item: MediaItem) {
        let ref = item.ref
        preview.show(item, detail: details[ref])
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            try? await Task.sleep(for: Self.detailDelay)
            guard let self, !Task.isCancelled else { return }
            ambient.setAmbient(url: item.artwork.backdrop ?? item.artwork.poster)
            guard details[ref] == nil, item.kind != .collection, let provider,
                  let detail = try? await provider.fullDetail(for: ref) else { return }
            details[ref] = detail
            guard !Task.isCancelled, rows[safe: focusedSlot ?? -1]??.ref == ref else { return }
            preview.show(item, detail: detail)
        }
    }

    // MARK: - Scroll

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        guard pendingTopFocus else { return }
        pendingTopFocus = false
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }
}

// MARK: - Menu

extension LibraryListViewController: MenuBackHandling {
    /// Menu below the first row scrolls back to it; on the first row it is the shell's.
    func handleMenuBack() -> Bool {
        guard presentedViewController == nil,
              let focused = UIFocusSystem.focusSystem(for: view)?.focusedItem as? UIView,
              focused.isDescendant(of: collectionView),
              let slot = focusedSlot, slot > 0 else { return false }
        focusedSlot = 0
        let top = CGPoint(x: 0, y: -collectionView.contentInset.top)
        if collectionView.contentOffset.y > top.y + 1 {
            pendingTopFocus = true
            collectionView.setContentOffset(top, animated: true)
        } else {
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
        return true
    }
}

// MARK: - Row

/// One title, in the Apple TV app's sidebar row: a solid white capsule with dark
/// content on focus, dimmed white at rest. A watch-state glyph leads, as in Infuse.
@MainActor
final class LibraryListRowCell: UICollectionViewCell {
    static let reuseID = "library.listRow"
    static let pitch: CGFloat = 78
    private static let capsuleHeight: CGFloat = 70

    private let capsule = UIView()
    private let glyph = LibraryWatchGlyphView()
    private let title = MusicChrome.label(size: 34, weight: .medium)
    private var isFocusedRow = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
        capsule.backgroundColor = UIColor.white.withAlphaComponent(0.91)
        capsule.layer.cornerRadius = Self.capsuleHeight / 2
        capsule.layer.cornerCurve = .continuous
        capsule.layer.shadowColor = UIColor.black.cgColor
        capsule.layer.shadowOpacity = 0.3
        capsule.layer.shadowRadius = 18
        capsule.layer.shadowOffset = CGSize(width: 0, height: 10)
        capsule.alpha = 0
        [capsule, glyph, title].forEach(contentView.addSubview)
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title text: String, state: LibraryWatchGlyphView.State?) {
        title.text = text
        glyph.state = state
        glyph.isHidden = state == nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isFocusedRow = false
        capsule.alpha = 0
        transform = .identity
        applyColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        capsule.frame = CGRect(x: 0, y: (bounds.height - Self.capsuleHeight) / 2,
                               width: bounds.width, height: Self.capsuleHeight)
        capsule.layer.shadowPath = UIBezierPath(roundedRect: capsule.bounds,
                                                cornerRadius: Self.capsuleHeight / 2).cgPath
        glyph.frame = CGRect(x: 30, y: (bounds.height - 30) / 2, width: 30, height: 30)
        title.frame = CGRect(x: 82, y: 0, width: bounds.width - 82 - 30, height: bounds.height)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        guard focused != isFocusedRow else { return }
        isFocusedRow = focused
        coordinator.addCoordinatedAnimations {
            self.capsule.alpha = focused ? 1 : 0
            self.transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
            self.applyColors()
        }
    }

    private func applyColors() {
        let content: UIColor = isFocusedRow ? .black : UIColor.white.withAlphaComponent(0.85)
        title.textColor = content
        glyph.tintColor = content
    }
}

// MARK: - Watch glyph

/// Infuse's watch-state marks: a dotted ring (unwatched), a filling pie (part
/// watched; a show by episodes), a ringed check (watched).
@MainActor
final class LibraryWatchGlyphView: UIView {
    enum State: Equatable {
        case unwatched, watched
        case partial(Double)

        init(_ item: MediaItem) {
            if let progress = item.childProgress, item.kind == .show || item.kind == .season {
                if progress.total > 0, progress.played >= progress.total { self = .watched }
                else if progress.total > 0, progress.played > 0 { self = .partial(Double(progress.played) / Double(progress.total)) }
                else { self = .unwatched }
            } else if item.isInProgress, let progress = item.watchProgress {
                self = .partial(progress)
            } else {
                self = item.isWatched ? .watched : .unwatched
            }
        }
    }

    var state: State? { didSet { if state != oldValue { setNeedsDisplay() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let state else { return }
        let line: CGFloat = 2.5
        let ringRect = bounds.insetBy(dx: line / 2 + 1, dy: line / 2 + 1)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = ringRect.width / 2
        tintColor.setStroke()
        tintColor.setFill()
        let ring = UIBezierPath(ovalIn: ringRect)
        ring.lineWidth = line
        switch state {
        case .unwatched:
            let circumference = 2 * .pi * radius
            let dashes: CGFloat = 12
            ring.setLineDash([circumference / dashes * 0.45, circumference / dashes * 0.55], count: 2, phase: 0)
            ring.lineCapStyle = .round
            ring.stroke()
        case .watched:
            ring.stroke()
            let check = UIBezierPath()
            check.move(to: CGPoint(x: center.x - radius * 0.42, y: center.y + radius * 0.02))
            check.addLine(to: CGPoint(x: center.x - radius * 0.1, y: center.y + radius * 0.34))
            check.addLine(to: CGPoint(x: center.x + radius * 0.45, y: center.y - radius * 0.32))
            check.lineWidth = line
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            check.stroke()
        case .partial(let fraction):
            ring.stroke()
            let pie = UIBezierPath()
            let start = -CGFloat.pi / 2
            pie.move(to: center)
            pie.addArc(withCenter: center, radius: radius - line, startAngle: start,
                       endAngle: start + 2 * .pi * CGFloat(min(max(fraction, 0.08), 1)), clockwise: true)
            pie.close()
            pie.fill()
        }
    }
}

// MARK: - Preview

/// The focused title, laid out as Infuse lays it out: genre and cast in a
/// right-aligned column beside the poster, rating and date under the poster,
/// the summary across the bottom. Holds no focus.
@MainActor
final class LibraryListPreviewView: UIView {
    private static let posterWidth: CGFloat = 400
    private static let posterHeight: CGFloat = 600
    private static let gap: CGFloat = 32
    private static let maxCast = 9

    private let poster = UIImageView()
    private let facts = UILabel()
    private let ratingBadge = UILabel()
    private let date = MusicChrome.label(size: 25, weight: .medium, color: UIColor(white: 1, alpha: 0.75))
    private let summary = MusicChrome.label(size: 29, weight: .regular, color: UIColor(white: 1, alpha: 0.92), lines: 6)
    private var posterURL: URL?
    private var shownRef: MediaItemRef?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        poster.contentMode = .scaleAspectFill
        poster.clipsToBounds = true
        poster.layer.cornerRadius = 16
        poster.layer.cornerCurve = .continuous
        poster.backgroundColor = UIColor(white: 1, alpha: 0.08)
        facts.numberOfLines = 0
        ratingBadge.font = .systemFont(ofSize: 21, weight: .bold)
        ratingBadge.textColor = UIColor(white: 1, alpha: 0.85)
        ratingBadge.textAlignment = .center
        ratingBadge.layer.borderColor = UIColor(white: 1, alpha: 0.75).cgColor
        ratingBadge.layer.borderWidth = 2
        ratingBadge.layer.cornerRadius = 6
        date.textAlignment = .right
        [poster, facts, ratingBadge, date, summary].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ item: MediaItem, detail: MediaItemDetail?) {
        let changed = item.ref != shownRef
        shownRef = item.ref
        let apply = {
            self.facts.attributedText = Self.facts(item, detail: detail)
            self.facts.textAlignment = .right
            let rating = item.contentRating.map(Self.displayRating) ?? ""
            self.ratingBadge.text = rating.isEmpty ? nil : rating
            self.ratingBadge.isHidden = rating.isEmpty
            self.date.text = Self.date(item)
            self.summary.text = item.overview
            self.setNeedsLayout()
            self.layoutIfNeeded()
        }
        if changed {
            UIView.transition(with: self, duration: 0.18, options: [.transitionCrossDissolve, .allowUserInteraction],
                              animations: apply)
        } else {
            apply()
        }
        setPoster(item.artwork.poster)
    }

    private func setPoster(_ url: URL?) {
        guard url != posterURL else { return }
        posterURL = url
        guard let url else { poster.image = nil; return }
        if let cached = ImageCacheManager.shared.cachedImage(for: url) {
            poster.image = cached
            return
        }
        Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url, quality: .thumb)
            guard let self, self.posterURL == url else { return }
            UIView.transition(with: self.poster, duration: 0.2, options: .transitionCrossDissolve) {
                self.poster.image = image
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        poster.frame = CGRect(x: width - Self.posterWidth, y: 0, width: Self.posterWidth, height: Self.posterHeight)
        let factsWidth = poster.frame.minX - Self.gap
        let factsHeight = min(Self.posterHeight, facts.sizeThatFits(CGSize(width: factsWidth, height: .greatestFiniteMagnitude)).height)
        facts.frame = CGRect(x: 0, y: 0, width: factsWidth, height: factsHeight)

        var y = poster.frame.maxY + 16
        date.sizeToFit()
        date.frame = CGRect(x: width - date.bounds.width, y: y, width: date.bounds.width, height: 34)
        if !ratingBadge.isHidden {
            let badgeWidth = ratingBadge.intrinsicContentSize.width + 18
            let trailing = date.text?.isEmpty == false ? date.frame.minX - 20 : width
            ratingBadge.frame = CGRect(x: trailing - badgeWidth, y: y + 1, width: badgeWidth, height: 32)
        }
        y += 34 + 28
        let summaryHeight = summary.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        summary.frame = CGRect(x: 0, y: y, width: width, height: min(summaryHeight, bounds.height - y))
    }

    // MARK: Text

    private static func facts(_ item: MediaItem, detail: MediaItemDetail?) -> NSAttributedString {
        let heading: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: UIColor(white: 1, alpha: 0.9),
        ]
        let value: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 27, weight: .regular),
            .foregroundColor: UIColor(white: 1, alpha: 0.7),
        ]
        let text = NSMutableAttributedString()
        func section(_ title: String, _ lines: [String]) {
            guard !lines.isEmpty else { return }
            if text.length > 0 { text.append(NSAttributedString(string: "\n\n", attributes: [.font: UIFont.systemFont(ofSize: 12)])) }
            text.append(NSAttributedString(string: title.uppercased() + "\n", attributes: heading))
            text.append(NSAttributedString(string: lines.joined(separator: "\n"), attributes: value))
        }
        let genres = detail?.genres ?? []
        section(genres.count == 1 ? String(localized: "Genre") : String(localized: "Genres"), Array(genres.prefix(4)))
        let directors = (detail?.directors ?? []).map(\.name)
        if item.kind == .movie {
            section(directors.count == 1 ? String(localized: "Director") : String(localized: "Directors"),
                    Array(directors.prefix(2)))
        }
        section(String(localized: "Cast"), Array((detail?.cast ?? []).map(\.name).prefix(maxCast)))
        return text
    }

    /// "uk/12A" → "12A": Plex prefixes non-US ratings with their country.
    private static func displayRating(_ raw: String) -> String {
        raw.split(separator: "/").last.map(String.init) ?? raw
    }

    private static let dayFormat: Date.FormatStyle = .dateTime.day().month(.abbreviated).year()

    /// The air or release day: a calendar day ("2006-10-11"), read in UTC.
    private static func date(_ item: MediaItem) -> String? {
        if let day = item.releaseDate?.prefix(10),
           let parsed = try? Date(String(day), strategy: .iso8601.year().month().day()) {
            var style = dayFormat
            style.timeZone = TimeZone(identifier: "UTC") ?? .current
            return parsed.formatted(style)
        }
        return item.year.map(String.init)
    }
}
