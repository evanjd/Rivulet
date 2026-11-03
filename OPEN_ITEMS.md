# Open items

Known follow-ups, parked on purpose. Remove an entry when it lands.

## Plex: Recently Added seasons
Plex's Recently Added groups several new episodes of one season into a season
item, as Jellyfin's `Items/Latest` does. On Jellyfin each season is now swapped
for its newest episode (`JellyfinProvider.newestEpisodes(replacingSeasonsIn:)`),
so the tile opens with the episode's synopsis, air date and Play target. Plex
still shows the season, whose detail page has none of those. Do the same on
the Plex path.

## iOS: season and episode number labels
`ff44bb39` stopped tvOS from grouping year-numbered seasons ("Season 2,026",
"Play S2,026, E182") by interpolating the number as text, which renamed those
keys from `%lld` to `%@`. Left on iOS:
- `RivuletiOS/Localizable.xcstrings` still has the old `%lld` keys. The shared
  `SeasonTitle` and the Plex Live TV episode line (`PlexLiveTVModels`) now look
  up `%@` keys there and fall back to English.
- Three iOS call sites still interpolate an `Int`: `IOSPlexActions.swift`,
  `IOSDownloadsView.swift`, `IOSPlexDetailView.swift`. Route them through
  `SeasonTitle.title(_:)`.
