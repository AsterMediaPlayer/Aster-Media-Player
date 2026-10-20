# Channel tags

A channel is a Jellyfin video playlist set up with tags, so the server is the one place channels live and every device finds the same ones. Edit Channels in Aster writes these for you; you can also add them by hand in the playlist's **Edit Metadata ▸ Tags**. Only a server administrator can change them.

## Playlist tags

| Tag | Meaning | Default |
| --- | --- | --- |
| `aster:channel` | This playlist is a channel | not a channel |
| `aster:number=101` | Its channel number | numbered after the rest, by name |
| `aster:mode=blocks` | `rotation`, `blocks`, `shuffle`, `sequential` or `airdate` (everything in the order it first aired) | `rotation` |
| `aster:logo=on` | The playlist's picture is the channel's logo | off (the name is shown) |
| `aster:reshuffle=week` | How long one order of shows lasts: `day`, `week` (Monday to Monday) or `month` | `day` |
| `aster:seed=2` | Deals a fresh lineup; any other number deals another | the channel's original lineup |
| `aster:blocks=3-6` | How many episodes play in a row in Blocks mode | 2 to 4 |
| `aster:bug=on` | The logo, faint in the corner while the channel plays | off |
| `aster:bug-location=top-left` | The bug's corner: `top-left`, `top-right`, `bottom-left` or `bottom-right` | `bottom-right` |
| `aster:bug-size=150%` | The bug's size, 25% to 300% of the usual | `100%` |
| `aster:bug-hide=30` | Seconds the bug shows after tuning in or a programme starting, then fades | `off` (always shown) |
| `aster:bug-opacity=60%` | How solid the bug is, 5% to 100% | `45%` |
| `aster:genre=Horror` | Also plays every movie and episode in this genre; repeat the tag for more genres (any of them) | none |
| `aster:network=NBC` | Also plays every movie and episode from this studio or network; repeat for more | none |
| `aster:collection=Star Wars Collection` | Also plays everything in this collection; repeat for more | none |
| `aster:type=movies` | With genres, networks or collections: `all`, `movies` or `shows` | `all` |
| `aster:years=1980-1989` | With genres, networks or collections: only titles from these years (or one year, `1994`) | any year |
| `aster:rating=TV-PG,PG` | With genres, networks or collections: only titles with these content ratings | any rating |
| `aster:library=TV Shows` | With genres or networks: only from this library; repeat for more | every library |
| `aster:weight=Friends:2` | This show takes two turns (up to 5) to every other show's one; repeat for more shows | 1 each |
| `aster:min-length=20` | Leaves out anything shorter, in minutes | none |
| `aster:max-length=60` | Leaves out anything longer, in minutes | none |
| `aster:filler-playlists=Hazbin Bumpers` | A filler playlist (one tagged `aster:filler`) for its breaks between programmes; repeat for more. Each clip's own tag says what it is | none |
| `aster:filler-types=commercials,bumpers` | With filler: which kinds of clip to play: `bumpers`, `promos`, `commercials`, `trailers`, `interstitials`, or `all` | `all` |
| `aster:bumpers-at=out` | With breaks: a bumper `both` before and after each break, only before it (`out`), or only after (`in`) | `both` |
| `aster:break-length=4` | With breaks: minutes of commercials in each break, 0 to 30 | `2` |
| `aster:promo-count=2` | With breaks: promos in each break, 0 to 5 | `1` |
| `aster:trailer-count=2` | With breaks: trailers in each break, 0 to 5 | `1` |
| `aster:interstitial-count=2` | With breaks, not lined up: interstitials in each break, 0 to 5 | `1` |
| `aster:break-every=2` | With breaks, not lined up: a break after every programme, or every 2nd to 10th | `1` |
| `aster:align-fit=exact` | Lined up: `best` fills each gap with whole clips of every kind the channel has, as near the mark as they get without passing it (a programme can start a few seconds early); `exact` fills with interstitials and cuts the last one short to land on it | `best` |
| `aster:align=30` | With breaks: every programme starts on the half hour (or every 5, 10, 15, 20 or 60 minutes), its break running on to the mark | `off` |
| `aster:user=peppy,jd` | Only these users (by Jellyfin user name) get the channel in Aster; repeat for more. It doesn't hide the playlist in Jellyfin | everyone |
| `aster:channel-name=Late Night` | The channel's name, in place of the playlist's | the playlist's name |

Turning a playlist on in Aster writes every tag, defaults included (all but the name), so each one is there to change in Jellyfin; turning it off writes `aster:channel=off` and keeps the rest. Case doesn't matter, other tags are left alone, and a value Aster doesn't understand falls back to the default. Tags written before the app was renamed (`asterfin:…`) still work, and are rewritten as `aster:…` the first time an administrator signs in.

## Breaks

add bumpers, promos, commercials, trailers and interstitials to Jellyfin as ordinary videos and tag each with what it is: `aster:commercial`, `aster:promo`, `aster:trailer`, `aster:interstitial` or `aster:bumper`. A bumper tagged `aster:bumper=in` only closes a break, right before the programme (a countdown), and `aster:bumper=out` only opens one; a clip without a tag isn't played. Put them in playlists, any mix, tagged `aster:filler`, and name those on a channel with `aster:filler-playlists=` (or pick them in Edit Channels, which offers only filler playlists), so one playlist of commercials can serve many channels. Each break plays a bumper, its commercials, its promos, its trailers, its interstitials, and a bumper back. With `aster:align=30`, programmes line up on the hour and half hour: by default each break is filled with whole commercials, promos, trailers, interstitials and bumpers, as near the mark as they get without passing it, so a programme may start a few seconds early; with `aster:align-fit=exact`, interstitials fill to the mark and the last is cut short to land right on it. Breaks are the same on every device, and the guide folds each one into the programme before it.

## Filling a channel

New Channel in Edit Channels makes a channel that fills itself from genres (Horror, Comedy, …), networks (NBC, Cartoon Network, …) and collections, narrowed to movies or shows, years, content ratings and libraries if you like, along with anything added to its playlist by hand. A show brings every one of its episodes. It's shared with everyone on the server.

## Keeping other apps in step

Everything that reads or writes these tags is checked against [`AsterFINTests/Conformance/channel-tags.json`](../AsterFINTests/Conformance/channel-tags.json): playlists' tags in, whether they make a channel, and every tag a save writes back, in order.
