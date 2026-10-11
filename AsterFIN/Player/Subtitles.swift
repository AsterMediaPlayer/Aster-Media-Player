//
//  Subtitles.swift
//  AsterFIN
//
//  Subtitles drawn by the app over the video. AVPlayer only renders
//  subtitles delivered inside an HLS stream, which Jellyfin times wrongly
//  for fMP4 and extracts too slowly for playback to wait on. Instead the
//  chosen track is fetched once as the server's JSON cue list (the format
//  Jellyfin's web player uses) and the cue under the playhead is shown here.
//

import MediaAccessibility
import SwiftUI

/// One subtitle line, in seconds from the start of the title.
nonisolated struct SubtitleCue: Sendable, Equatable {
    var start: Double
    var end: Double
    var text: String

    /// The cues showing at `time`, top to bottom, or nil for none.
    /// `cues` must be sorted by start.
    static func text(at time: Double, in cues: [SubtitleCue]) -> String? {
        guard !cues.isEmpty else { return nil }
        // First cue starting after `time`; everything before it may be showing.
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].start <= time { low = mid + 1 } else { high = mid }
        }
        // Cues overlap rarely and briefly, so a short look back finds them all.
        var showing: [String] = []
        for position in stride(from: low - 1, through: max(0, low - 8), by: -1) where cues[position].end > time {
            showing.insert(cues[position].text, at: 0)
        }
        return showing.isEmpty ? nil : showing.joined(separator: "\n")
    }

    // MARK: Parsing

    /// Decodes Jellyfin's `Stream.js` response: `{"TrackEvents":[...]}` with
    /// positions in ticks and text that may carry HTML or ASS markup.
    static func parse(json data: Data) throws -> [SubtitleCue] {
        struct Track: Decodable {
            struct Event: Decodable {
                var Text: String?
                var StartPositionTicks: Int64
                var EndPositionTicks: Int64
            }
            var TrackEvents: [Event]
        }
        let track = try JSONDecoder().decode(Track.self, from: data)
        return track.TrackEvents.compactMap { event in
            let text = plainText(event.Text ?? "")
            guard !text.isEmpty else { return nil }
            return SubtitleCue(
                start: Double(event.StartPositionTicks) / 10_000_000,
                end: Double(event.EndPositionTicks) / 10_000_000,
                text: text
            )
        }
        .sorted { $0.start < $1.start }
    }

    /// Cue text as it should read on screen: line breaks kept, markup
    /// (`<i>`, `{\an8}`, `<br>`) removed, entities decoded.
    static func plainText(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&nbsp;": "\u{00A0}"]
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Draws the current cue near the bottom of the picture, in the viewer's
/// system caption style (Settings › Accessibility › Subtitles & Captioning).
struct SubtitleOverlayView: View {
    let text: String?

    var body: some View {
        VStack {
            Spacer()
            if let text {
                Text(text)
                    .font(.system(size: 42 * Self.textScale, weight: .medium))
                    .foregroundStyle(Self.foreground)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(Self.background, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                    .padding(.horizontal, 160)
                    .padding(.bottom, 110)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.linear(duration: 0.08), value: text)
    }

    // MARK: System caption style

    private static var textScale: CGFloat {
        let scale = MACaptionAppearanceGetRelativeCharacterSize(.user, nil)
        return scale > 0 ? scale : 1
    }

    private static var foreground: Color {
        let color = MACaptionAppearanceCopyForegroundColor(.user, nil).takeRetainedValue()
        let opacity = MACaptionAppearanceGetForegroundOpacity(.user, nil)
        return Color(UIColor(cgColor: color)).opacity(opacity > 0 ? opacity : 1)
    }

    private static var background: Color {
        let color = MACaptionAppearanceCopyBackgroundColor(.user, nil).takeRetainedValue()
        let opacity = MACaptionAppearanceGetBackgroundOpacity(.user, nil)
        return Color(UIColor(cgColor: color)).opacity(opacity > 0 ? opacity : 0.65)
    }
}

/// Language codes as Jellyfin reports them (mostly ISO 639-2, three
/// letters) normalized to BCP 47 tags, which AVFoundation and Locale use.
nonisolated enum LanguageTag {
    static func bcp47(from code: String?) -> String {
        guard let code = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !code.isEmpty else {
            return "und"
        }
        if code.count == 2 {
            return code
        }
        if let mapped = iso639_2to1[code] {
            return mapped
        }
        if let id = Locale.Language(components: .init(identifier: code)).languageCode?.identifier {
            return id
        }
        return code
    }

    /// Whether two codes name the same language, whatever their form.
    static func sameLanguage(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let left = bcp47(from: a)
        let right = bcp47(from: b)
        return left != "und" && left == right
    }

    private static let iso639_2to1: [String: String] = [
        "aar": "aa", "abk": "ab", "afr": "af", "aka": "ak", "alb": "sq", "sqi": "sq",
        "amh": "am", "ara": "ar", "arg": "an", "arm": "hy", "hye": "hy", "asm": "as",
        "ava": "av", "ave": "ae", "aym": "ay", "aze": "az", "bak": "ba", "bam": "bm",
        "baq": "eu", "eus": "eu", "bel": "be", "ben": "bn", "bih": "bh", "bis": "bi",
        "bos": "bs", "bre": "br", "bul": "bg", "bur": "my", "mya": "my", "cat": "ca",
        "cha": "ch", "che": "ce", "chi": "zh", "zho": "zh", "chv": "cv", "cor": "kw",
        "cos": "co", "cre": "cr", "cze": "cs", "ces": "cs", "dan": "da", "div": "dv",
        "dut": "nl", "nld": "nl", "dzo": "dz", "eng": "en", "epo": "eo", "est": "et",
        "ewe": "ee", "fao": "fo", "fij": "fj", "fin": "fi", "fre": "fr", "fra": "fr",
        "fry": "fy", "ful": "ff", "geo": "ka", "kat": "ka", "ger": "de", "deu": "de",
        "gla": "gd", "gle": "ga", "glg": "gl", "glv": "gv", "gre": "el", "ell": "el",
        "grn": "gn", "guj": "gu", "hat": "ht", "hau": "ha", "heb": "he", "her": "hz",
        "hin": "hi", "hmo": "ho", "hrv": "hr", "hun": "hu", "ibo": "ig", "ice": "is",
        "isl": "is", "ido": "io", "iii": "ii", "iku": "iu", "ile": "ie", "ina": "ia",
        "ind": "id", "ipk": "ik", "ita": "it", "jav": "jv", "jpn": "ja", "kal": "kl",
        "kan": "kn", "kas": "ks", "kaz": "kk", "khm": "km", "kik": "ki", "kin": "rw",
        "kir": "ky", "kom": "kv", "kon": "kg", "kor": "ko", "kua": "kj", "kur": "ku",
        "lao": "lo", "lat": "la", "lav": "lv", "lim": "li", "lin": "ln", "lit": "lt",
        "ltz": "lb", "lub": "lu", "lug": "lg", "mac": "mk", "mkd": "mk", "mah": "mh",
        "mal": "ml", "mao": "mi", "mri": "mi", "mar": "mr", "may": "ms", "msa": "ms",
        "mlg": "mg", "mlt": "mt", "mon": "mn", "nau": "na", "nav": "nv", "nbl": "nr",
        "nde": "nd", "ndo": "ng", "nep": "ne", "nno": "nn", "nob": "nb", "nor": "no",
        "nya": "ny", "oci": "oc", "oji": "oj", "ori": "or", "orm": "om", "oss": "os",
        "pan": "pa", "per": "fa", "fas": "fa", "pli": "pi", "pol": "pl", "por": "pt",
        "pus": "ps", "que": "qu", "roh": "rm", "rum": "ro", "ron": "ro", "run": "rn",
        "rus": "ru", "sag": "sg", "san": "sa", "sin": "si", "slo": "sk", "slk": "sk",
        "slv": "sl", "sme": "se", "smo": "sm", "sna": "sn", "snd": "sd", "som": "so",
        "sot": "st", "spa": "es", "srd": "sc", "srp": "sr", "ssw": "ss", "sun": "su",
        "swa": "sw", "swe": "sv", "tah": "ty", "tam": "ta", "tat": "tt", "tel": "te",
        "tgk": "tg", "tgl": "tl", "tha": "th", "tib": "bo", "bod": "bo", "tir": "ti",
        "ton": "to", "tsn": "tn", "tso": "ts", "tuk": "tk", "tur": "tr", "twi": "tw",
        "uig": "ug", "ukr": "uk", "urd": "ur", "uzb": "uz", "ven": "ve", "vie": "vi",
        "vol": "vo", "wel": "cy", "cym": "cy", "wln": "wa", "wol": "wo", "xho": "xh",
        "yid": "yi", "yor": "yo", "zha": "za", "zul": "zu",
    ]
}
