import AppKit

enum FileIcon {
    private static var cache: [String:NSImage] = [:]
    static func image(for url: URL?,folder: Bool = false,expanded: Bool = false) -> NSImage {
        if folder { return symbol(expanded ? "folder.fill" : "folder") }
        let ext = url?.pathExtension.lowercased() ?? "",name = url?.lastPathComponent.lowercased() ?? ""
        let types: [String:String] = ["swift":"swift","py":"python","pyw":"python","js":"javascript","mjs":"javascript","cjs":"javascript","ts":"typescript","tsx":"react","jsx":"react","html":"html5","htm":"html5","css":"css3","json":"json","jsonc":"json","yml":"yaml","yaml":"yaml","md":"markdown","markdown":"markdown","rs":"rust","go":"go","c":"c","h":"c","cpp":"cplusplus","cc":"cplusplus","hpp":"cplusplus","cs":"csharp","java":"java","kt":"kotlin","kts":"kotlin","rb":"ruby","php":"php"]
        let key = name == "dockerfile" ? "docker" : name == ".gitignore" || name == ".gitattributes" ? "git" : types[ext]
        if let key {
            if let cached = cache[key] { return cached }
            if let path = Bundle.main.url(forResource:key,withExtension:"png",subdirectory:"FileIcons"),let image = NSImage(contentsOf:path) {
                image.size = NSSize(width:16,height:16); image.isTemplate = ["rust","markdown"].contains(key); cache[key] = image; return image
            }
        }
        let symbol: String
        switch ext {
        case "sh","bash","zsh","fish": symbol = "terminal"
        case "toml","ini","conf","config","plist","env": symbol = "gearshape"
        case "sql","sqlite","db": symbol = "cylinder"
        case "svg","png","jpg","jpeg","webp","gif","icns": symbol = "photo"
        case "zip","dmg","gz","tar": symbol = "archivebox"
        default: symbol = "doc.text"
        }
        return Self.symbol(symbol)
    }
    private static func symbol(_ name: String) -> NSImage {
        let key = "symbol:"+name
        if let image = cache[key] { return image }
        let image = NSImage(systemSymbolName:name,accessibilityDescription:nil)!; cache[key] = image; return image
    }
    static func view(for url: URL?,folder: Bool = false,expanded: Bool = false) -> NSImageView {
        let image = image(for:url,folder:folder,expanded:expanded),view = NSImageView(image:image)
        view.contentTintColor = folder ? Theme.accent : image.isTemplate ? Theme.secondary : nil
        view.imageScaling = .scaleProportionallyUpOrDown
        view.widthAnchor.constraint(equalToConstant:16).isActive = true; view.heightAnchor.constraint(equalToConstant:16).isActive = true
        return view
    }
}
