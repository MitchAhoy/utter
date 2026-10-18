import Foundation

struct DictationLanguage: Identifiable {
    let id: String
    let name: String
    static let choices: [DictationLanguage] = [
        .init(id: "", name: "Detect automatically"),
        .init(id: "en", name: "English"), .init(id: "es", name: "Spanish"),
        .init(id: "fr", name: "French"), .init(id: "de", name: "German"),
        .init(id: "it", name: "Italian"), .init(id: "pt", name: "Portuguese"),
        .init(id: "nl", name: "Dutch"), .init(id: "ja", name: "Japanese"),
        .init(id: "zh", name: "Chinese"), .init(id: "ko", name: "Korean"),
        .init(id: "hi", name: "Hindi"), .init(id: "ar", name: "Arabic"),
        .init(id: "ru", name: "Russian"), .init(id: "uk", name: "Ukrainian")
    ]
}
