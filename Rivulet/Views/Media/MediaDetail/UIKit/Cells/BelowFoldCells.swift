// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  Collection cells hosting the below-fold views, plus the section header. Each forwards
//  focus to its view and resets it in prepareForReuse, or fast scrolls leave a stuck scale.

import UIKit

// MARK: - Episode

final class EpisodeCollectionCell: UICollectionViewCell {
    static let reuseID = "EpisodeCollectionCell"
    private let episodeView = EpisodeCell()
    /// Fires when the thumb or description gains focus, including moves within the row,
    /// which the collection's didUpdateFocus misses. Drives season-pill tracking.
    var onFocused: ((Bool) -> Void)?
    /// Thumb Select → play this episode.
    var onPlay: (() -> Void)?
    /// Description Select → open the episode detail page.
    var onShowDetails: (() -> Void)?
    /// Held Select → the episode menu, from the thumb's window frame.
    var onLongPress: ((CGRect) -> Void)?
    /// Reports which sub-target is focused (thumb / description / none).
    var onFocusKind: ((EpisodeFocusKind) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(episodeView)
        pinFilling(episodeView, to: contentView)
        // The cell itself is non-focusable (canFocusItemAt = false in
        // BelowFoldCollectionView); the EpisodeCell's thumb + description are the
        // real focus targets and report focus/select up through these closures.
        episodeView.onPlay = { [weak self] in self?.onPlay?() }
        episodeView.onShowDetails = { [weak self] in self?.onShowDetails?() }
        episodeView.onLongPress = { [weak self] frame in self?.onLongPress?(frame) }
        episodeView.onFocusKindChanged = { [weak self] kind in
            self?.onFocusKind?(kind)
            if kind != .none { self?.onFocused?(true) }
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(episode: MediaItem, showSeasonPrefix: Bool) {
        episodeView.configure(episode: episode, showSeasonPrefix: showSeasonPrefix)
    }

    /// Trailers render with the SAME episode card so the two rows match exactly.
    func configure(trailer: BelowFoldTrailer) {
        episodeView.configure(trailer: trailer)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onFocused = nil
        onPlay = nil
        onShowDetails = nil
        onLongPress = nil
        onFocusKind = nil
        episodeView.resetFocusVisual()
    }
}

// MARK: - Season pill

final class SeasonPillCollectionCell: UICollectionViewCell {
    static let reuseID = "SeasonPillCollectionCell"
    private let pillView = SeasonPillView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(pillView)
        pinFilling(pillView, to: contentView)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(label: String, isSelected: Bool) {
        pillView.configure(label: label, isSelected: isSelected)
    }
    func setSelected(asSeason selected: Bool) { pillView.setSelected(selected) }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = isSelfFocused(context)
        coordinator.addCoordinatedAnimations { [weak self] in self?.pillView.setFocused(focused) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        pillView.setFocused(false)
    }
}

// MARK: - Cast

final class CastCollectionCell: UICollectionViewCell {
    static let reuseID = "CastCollectionCell"
    private let castView = CastCell()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(castView)
        pinFilling(castView, to: contentView)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(person: MediaPerson, fallbackSubtitle: String?) {
        castView.configure(person: person, fallbackSubtitle: fallbackSubtitle)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = isSelfFocused(context)
        coordinator.addCoordinatedAnimations { [weak self] in self?.castView.setFocused(focused) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        castView.setFocused(false)
    }
}

// MARK: - Section header

final class BelowFoldSectionHeader: UICollectionReusableView {
    static let reuseID = "BelowFoldSectionHeader"
    /// Baseline above the first row's frame top, measured on device (tvOS 27): a card
    /// frame carries 20 of focus reserve, so the artwork sits 34.5 below. Cast circles have none beyond 20 above.
    static let cardBaseline: CGFloat = 14.5
    static let castBaseline: CGFloat = 41.5
    private let titleLabel = UILabel()
    private var baselineConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = MediaRowMetrics.headerFont
        titleLabel.textColor = MediaRowMetrics.headerColor
        addSubview(titleLabel)
        baselineConstraint = titleLabel.lastBaselineAnchor.constraint(equalTo: bottomAnchor, constant: -Self.cardBaseline)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            baselineConstraint,
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, baseline: CGFloat = BelowFoldSectionHeader.cardBaseline) {
        titleLabel.text = title
        baselineConstraint.constant = -baseline
    }
}

// MARK: - Season divider

/// An unfocusable season boundary in the episode rail: a broken hairline with a chip ("S3", "SP").
final class SeasonDividerCell: UICollectionViewCell {
    static let reuseID = "SeasonDividerCell"
    /// Wide enough that the chip is fully off screen when the next season's
    /// first episode rests on the 80 pt margin.
    static let cardWidth: CGFloat = 140

    private let topLine = UIView()
    private let bottomLine = UIView()
    private let chip = UILabel()

    override var canBecomeFocused: Bool { false }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for line in [topLine, bottomLine] {
            line.translatesAutoresizingMaskIntoConstraints = false
            line.backgroundColor = UIColor.white.withAlphaComponent(0.18)
            line.layer.cornerRadius = 1
            contentView.addSubview(line)
        }
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.font = .systemFont(ofSize: 29, weight: .semibold)
        chip.textColor = UIColor.white.withAlphaComponent(0.55)
        chip.textAlignment = .center
        contentView.addSubview(chip)
        NSLayoutConstraint.activate([
            // Centered on the thumb band (the cell spans the full card height,
            // text zone included, so the marker aligns with the artwork).
            chip.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            chip.centerYAnchor.constraint(equalTo: contentView.topAnchor, constant: EpisodeCell.thumbHeight / 2),
            topLine.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            topLine.widthAnchor.constraint(equalToConstant: 2),
            topLine.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            topLine.bottomAnchor.constraint(equalTo: chip.topAnchor, constant: -12),
            bottomLine.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            bottomLine.widthAnchor.constraint(equalToConstant: 2),
            bottomLine.topAnchor.constraint(equalTo: chip.bottomAnchor, constant: 12),
            bottomLine.bottomAnchor.constraint(equalTo: contentView.topAnchor, constant: EpisodeCell.thumbHeight - 8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SeasonDividerCell is not Storyboard-backed") }

    func configure(label: String) {
        chip.text = label
    }
}

// MARK: - Helpers

private extension UICollectionViewCell {
    func isSelfFocused(_ context: UIFocusUpdateContext) -> Bool {
        guard let next = context.nextFocusedView else { return false }
        return next === self || next.isDescendant(of: self)
    }
}

private func pinFilling(_ inner: UIView, to container: UIView) {
    inner.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        inner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        inner.topAnchor.constraint(equalTo: container.topAnchor),
        inner.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        inner.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
    ])
}
