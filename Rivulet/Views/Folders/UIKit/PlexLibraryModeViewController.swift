// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexLibraryModeViewController.swift
//  Rivulet
//
//  A movie or show library tab, on any server: its title list, its title grid or its
//  folders, swapped in place. The choice is saved per library and profile.
//

import UIKit

@MainActor
final class PlexLibraryModeViewController: UIViewController {
    /// The section as the provider seam sees it; the list page reads through it.
    private let library: MediaLibrary
    /// Where the View and sort choices are saved: the Plex section key, or a provider
    /// library's `settingsKey`, matching what the grid already uses for each.
    private let settingsKey: String
    private let makeGrid: () -> PlexHomeViewController
    private let makeFolders: (_ viewMenu: @escaping () -> UIMenu?) -> FolderLibraryViewController
    private var grid: PlexHomeViewController?
    private var list: LibraryListViewController?
    private var folders: FolderLibraryViewController?
    private var active: UIViewController?

    /// A Plex section on the selected server.
    convenience init(library plex: PlexLibrary) {
        let providerID = MediaProviderRegistry.shared.plexProvider?.id ?? "plex"
        self.init(library: PlexMediaMapper.library(plex, providerID: providerID), settingsKey: plex.key,
                  makeGrid: { PlexHomeViewController(mode: .library(key: plex.key, title: plex.title)) },
                  makeFolders: { FolderLibraryViewController(plex: plex, viewMenu: $0) })
    }

    /// A movie or show library on any other server (Jellyfin, the account's other Plex servers).
    convenience init(provider library: MediaLibrary) {
        self.init(library: library, settingsKey: library.settingsKey,
                  makeGrid: { PlexHomeViewController(mode: .library(key: library.settingsKey, title: library.title),
                                                     providerLibrary: library) },
                  makeFolders: { viewMenu in
                      FolderLibraryViewController(title: library.title, viewMenu: viewMenu) {
                          (MediaProviderRegistry.shared.provider(for: library.providerID) as? any FolderProvider)
                              .map { ($0, library) }
                      }
                  })
    }

    private init(library: MediaLibrary, settingsKey: String,
                 makeGrid: @escaping () -> PlexHomeViewController,
                 makeFolders: @escaping (@escaping () -> UIMenu?) -> FolderLibraryViewController) {
        self.library = library
        self.settingsKey = settingsKey
        self.makeGrid = makeGrid
        self.makeFolders = makeFolders
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let mode = LibrarySettingsManager.shared.viewMode(settingsKey)
        if mode == .titles || mode == .collections { gridPage().setGridShowsCollections(mode == .collections) }
        show(page(for: mode))
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] { active.map { [$0] } ?? [] }

    /// The View menu every page shows. Collections only once the grid has seen some.
    private func viewMenu(current: LibraryViewMode) -> UIMenu? {
        let modes: [LibraryViewMode] = grid?.hasCollections == true
            ? [.list, .titles, .collections, .folders] : [.list, .titles, .folders]
        return LibraryViewMode.menu(modes, current: current) { [weak self] in self?.select($0) }
    }

    /// Every page is kept once made, so switching back keeps place and contents.
    private func page(for mode: LibraryViewMode) -> UIViewController {
        switch mode {
        case .titles, .collections:
            return gridPage()
        case .list:
            if let list { return list }
            let page = LibraryListViewController(library: library, settingsKey: settingsKey) { [weak self] in
                self?.viewMenu(current: .list)
            }
            list = page
            return page
        case .folders:
            if let folders { return folders }
            let page = makeFolders { [weak self] in self?.viewMenu(current: .folders) }
            folders = page
            return page
        }
    }

    private func gridPage() -> PlexHomeViewController {
        if let grid { return grid }
        let page = makeGrid()
        page.onSelectViewMode = { [weak self] in self?.select($0) }
        grid = page
        return page
    }

    private func select(_ mode: LibraryViewMode) {
        LibrarySettingsManager.shared.setViewMode(mode, for: settingsKey)
        // Next turn: the menu's button is in the page being removed.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if mode == .titles || mode == .collections { gridPage().setGridShowsCollections(mode == .collections) }
            let next = page(for: mode)
            guard next !== active else { return }
            show(next)
            NotificationCenter.default.post(name: .tabContentReplaced, object: self)
        }
    }

    private func show(_ next: UIViewController) {
        guard next !== active else { return }
        let previous = active
        addChild(next)
        next.view.frame = view.bounds
        next.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(next.view)
        next.didMove(toParent: self)
        active = next
        // Focus is still in the old page, so this request is ours to make.
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
        previous?.willMove(toParent: nil)
        previous?.view.removeFromSuperview()
        previous?.removeFromParent()
    }
}
