import Foundation

public struct CodeDocumentEdits {
    public let uri: String
    public let version: Int?
    public let edits: [CodeTextEdit]
}
public enum CodeWorkspaceEdit {
    public static func parse(_ value: Any) throws -> [CodeDocumentEdits] {
        guard let object = value as? [String:Any] else { return [] }
        var result: [CodeDocumentEdits] = []
        if let changes = object["changes"] as? [String:Any] {
            for (uri,edits) in changes { result.append(CodeDocumentEdits(uri:uri,version:nil,edits:try decode(edits))) }
        }
        if let documents = object["documentChanges"] as? [[String:Any]] {
            for document in documents {
                guard document["kind"] == nil,let identity = document["textDocument"] as? [String:Any],let uri = identity["uri"] as? String else {
                    throw LanguageServiceError.message("This refactor includes file creation, deletion or moves. No changes were applied.")
                }
                result.append(CodeDocumentEdits(uri:uri,version:identity["version"] as? Int,edits:try decode(document["edits"] ?? [])))
            }
        }
        guard Set(result.map(\.uri)).count == result.count,result.count <= 500 else { throw LanguageServiceError.message("The refactor contains duplicate files or exceeds 500 files. No changes were applied.") }
        for document in result {
            guard let url = URL(string:document.uri),url.isFileURL,url.host == nil || url.host == "" || url.host == "localhost" else { throw DocumentError.invalidRange }
        }
        return result.sorted { $0.uri < $1.uri }
    }
    private static func decode(_ value: Any) throws -> [CodeTextEdit] { try JSONDecoder().decode([CodeTextEdit].self,from:JSONSerialization.data(withJSONObject:value)) }
}
