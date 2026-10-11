//
//  DiscMenuModels.swift
//  AsterFIN
//
//  The resolved disc-menu document served by the JellyDisc plugin at
//  GET /DiscMenus/{itemId}/Menu (see docs/CLIENT_GUIDE.md §3). Unknown
//  properties are ignored; unknown enum values fall back to defaults at use.
//

import Foundation

nonisolated struct DiscMenuDocument: Codable, Sendable, Equatable {
    var menuId: String?
    var root: String
    var menus: [String: DiscMenuScreenSpec]
    var background: DiscBackground?
    var theme: DiscTheme?
    var layout: DiscLayout?
    var audio: DiscAudio?
    var chapters: [DiscChapter]?
    var trailers: [DiscTrailer]?
    var themeSongs: [String]?

    enum CodingKeys: String, CodingKey {
        case menuId = "MenuId"
        case root = "Root"
        case menus = "Menus"
        case background = "Background"
        case theme = "Theme"
        case layout = "Layout"
        case audio = "Audio"
        case chapters = "Chapters"
        case trailers = "Trailers"
        case themeSongs = "ThemeSongs"
    }
}

nonisolated struct DiscMenuScreenSpec: Codable, Sendable, Equatable {
    var title: String
    var entries: [DiscMenuEntry]
    var background: DiscBackground?
    var theme: DiscTheme?
    var layout: DiscLayout?
    var audio: DiscAudio?
    var maxPerPage: Int?

    enum CodingKeys: String, CodingKey {
        case title = "Title"
        case entries = "Entries"
        case background = "Background"
        case theme = "Theme"
        case layout = "Layout"
        case audio = "Audio"
        case maxPerPage = "MaxPerPage"
    }

    init(title: String, entries: [DiscMenuEntry], background: DiscBackground? = nil, theme: DiscTheme? = nil, layout: DiscLayout? = nil, audio: DiscAudio? = nil, maxPerPage: Int? = nil) {
        self.title = title
        self.entries = entries
        self.background = background
        self.theme = theme
        self.layout = layout
        self.audio = audio
        self.maxPerPage = maxPerPage
    }
}

nonisolated enum DiscAction: String, Sendable {
    case playFeature, playExtra, playSequence, submenu, chapters, back, home
    // Client-only actions: never sent by the server.
    case playChapter, pagePrev, pageNext
    case unknown
}

nonisolated struct DiscMenuEntry: Codable, Sendable, Equatable {
    var action: String
    var label: String
    var position: DiscPosition?
    var style: String?
    var image: String?
    var imageFocus: String?
    var startChapter: Int?
    var itemId: String?
    var itemIds: [String]?
    var menu: String?
    var perPage: Int?

    // Produced by the client for chapter and paging buttons; never decoded.
    var sub: String? = nil
    var thumbURL: URL? = nil
    var startTicks: Int64? = nil

    enum CodingKeys: String, CodingKey {
        case action = "Action"
        case label = "Label"
        case position = "Position"
        case style = "Style"
        case image = "Image"
        case imageFocus = "ImageFocus"
        case startChapter = "StartChapter"
        case itemId = "ItemId"
        case itemIds = "ItemIds"
        case menu = "Menu"
        case perPage = "PerPage"
    }

    init(action: String, label: String, position: DiscPosition? = nil, style: String? = nil, image: String? = nil, imageFocus: String? = nil, startChapter: Int? = nil, itemId: String? = nil, itemIds: [String]? = nil, menu: String? = nil, perPage: Int? = nil, sub: String? = nil, thumbURL: URL? = nil, startTicks: Int64? = nil) {
        self.action = action
        self.label = label
        self.position = position
        self.style = style
        self.image = image
        self.imageFocus = imageFocus
        self.startChapter = startChapter
        self.itemId = itemId
        self.itemIds = itemIds
        self.menu = menu
        self.perPage = perPage
        self.sub = sub
        self.thumbURL = thumbURL
        self.startTicks = startTicks
    }

    var kind: DiscAction { DiscAction(rawValue: action) ?? .unknown }

    /// True when the cell should be given a height (artwork or a chapter thumbnail).
    var isTall: Bool {
        !(image ?? "").isEmpty || thumbURL != nil
    }
}

nonisolated struct DiscPosition: Codable, Sendable, Hashable {
    var x: Double
    var y: Double
    var w: Double?
    var h: Double?
    var anchor: String?

    enum CodingKeys: String, CodingKey {
        case x = "X"
        case y = "Y"
        case w = "W"
        case h = "H"
        case anchor = "Anchor"
    }

    init(x: Double, y: Double, w: Double? = nil, h: Double? = nil, anchor: String? = nil) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.anchor = anchor
    }
}

nonisolated struct DiscBackground: Codable, Sendable, Equatable {
    var source: String?
    var imageType: String?
    var index: Int?
    var tmdbFilePath: String?
    var tmdbSize: String?
    var fanartId: String?
    var color: String?
    var image: String?
    var trailerIndex: Int?
    var muted: Bool?
    var poster: String?
    var dim: Double?

    enum CodingKeys: String, CodingKey {
        case source = "Source"
        case imageType = "ImageType"
        case index = "Index"
        case tmdbFilePath = "TmdbFilePath"
        case tmdbSize = "TmdbSize"
        case fanartId = "FanartId"
        case color = "Color"
        case image = "Image"
        case trailerIndex = "TrailerIndex"
        case muted = "Muted"
        case poster = "Poster"
        case dim = "Dim"
    }
}

nonisolated struct DiscTheme: Codable, Sendable, Equatable {
    var id: String?
    var accent: String?
    var align: String?
    var textColor: String?
    var font: String?
    var fontSize: Double?
    var uppercase: Bool?
    var bold: Bool?
    var letterSpacing: Double?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case accent = "Accent"
        case align = "Align"
        case textColor = "TextColor"
        case font = "Font"
        case fontSize = "FontSize"
        case uppercase = "Uppercase"
        case bold = "Bold"
        case letterSpacing = "LetterSpacing"
    }

    init(id: String? = nil, accent: String? = nil, align: String? = nil, textColor: String? = nil, font: String? = nil, fontSize: Double? = nil, uppercase: Bool? = nil, bold: Bool? = nil, letterSpacing: Double? = nil) {
        self.id = id
        self.accent = accent
        self.align = align
        self.textColor = textColor
        self.font = font
        self.fontSize = fontSize
        self.uppercase = uppercase
        self.bold = bold
        self.letterSpacing = letterSpacing
    }
}

nonisolated struct DiscLayout: Codable, Sendable, Equatable {
    var titlePosition: DiscPosition?
    var hideTitle: Bool?
    var buttonStyle: String?
    var flow: DiscFlow?
    var transition: DiscTransition?
    var layers: [DiscLayer]?

    enum CodingKeys: String, CodingKey {
        case titlePosition = "TitlePosition"
        case hideTitle = "HideTitle"
        case buttonStyle = "ButtonStyle"
        case flow = "Flow"
        case transition = "Transition"
        case layers = "Layers"
    }

    init(titlePosition: DiscPosition? = nil, hideTitle: Bool? = nil, buttonStyle: String? = nil, flow: DiscFlow? = nil, transition: DiscTransition? = nil, layers: [DiscLayer]? = nil) {
        self.titlePosition = titlePosition
        self.hideTitle = hideTitle
        self.buttonStyle = buttonStyle
        self.flow = flow
        self.transition = transition
        self.layers = layers
    }
}

nonisolated struct DiscFlow: Codable, Sendable, Equatable {
    var region: DiscPosition
    var columns: Int
    var rows: Int
    var moreLabel: String?
    var previousLabel: String?

    enum CodingKeys: String, CodingKey {
        case region = "Region"
        case columns = "Columns"
        case rows = "Rows"
        case moreLabel = "MoreLabel"
        case previousLabel = "PreviousLabel"
    }

    init(region: DiscPosition, columns: Int, rows: Int, moreLabel: String? = nil, previousLabel: String? = nil) {
        self.region = region
        self.columns = columns
        self.rows = rows
        self.moreLabel = moreLabel
        self.previousLabel = previousLabel
    }
}

nonisolated struct DiscTransition: Codable, Sendable, Equatable {
    var style: String?
    var durationMs: Int?

    enum CodingKeys: String, CodingKey {
        case style = "Style"
        case durationMs = "DurationMs"
    }
}

nonisolated struct DiscLayer: Codable, Sendable, Hashable {
    var type: String?
    var position: DiscPosition?
    var fill: String?
    var opacity: Double?
    var borderColor: String?
    var borderWidth: Double?
    var radius: Double?
    var image: String?
    var fit: String?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case position = "Position"
        case fill = "Fill"
        case opacity = "Opacity"
        case borderColor = "BorderColor"
        case borderWidth = "BorderWidth"
        case radius = "Radius"
        case image = "Image"
        case fit = "Fit"
    }
}

nonisolated struct DiscAudio: Codable, Sendable, Equatable {
    var music: DiscMusic?
    var sounds: DiscSounds?

    enum CodingKeys: String, CodingKey {
        case music = "Music"
        case sounds = "Sounds"
    }
}

nonisolated struct DiscMusic: Codable, Sendable, Equatable {
    var source: String?
    var file: String?
    var volume: Double?

    enum CodingKeys: String, CodingKey {
        case source = "Source"
        case file = "File"
        case volume = "Volume"
    }
}

nonisolated struct DiscSounds: Codable, Sendable, Equatable {
    var preset: String?
    var volume: Double?
    var move: String?
    var select: String?
    var back: String?

    enum CodingKeys: String, CodingKey {
        case preset = "Preset"
        case volume = "Volume"
        case move = "Move"
        case select = "Select"
        case back = "Back"
    }
}

nonisolated struct DiscChapter: Codable, Sendable, Equatable {
    var index: Int
    var name: String?
    var startTicks: Int64
    var hasImage: Bool?
    var imageStamp: Int64?

    enum CodingKeys: String, CodingKey {
        case index = "Index"
        case name = "Name"
        case startTicks = "StartTicks"
        case hasImage = "HasImage"
        case imageStamp = "ImageStamp"
    }
}

nonisolated struct DiscTrailer: Codable, Sendable, Equatable {
    var kind: String?
    var itemId: String?
    var videoId: String?
    var name: String?

    enum CodingKeys: String, CodingKey {
        case kind = "Kind"
        case itemId = "ItemId"
        case videoId = "VideoId"
        case name = "Name"
    }
}
