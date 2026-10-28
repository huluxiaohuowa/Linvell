import Foundation

// A little room to think.
// Built for the way your mind moves.

struct Workspace {
    let name: String
    var files: [String]

    func open(_ filename: String) {
        print("Opening \(filename) in \(name)")
    }
}

let workspace = Workspace(
    name: "Something worth making",
    files: ["Welcome.swift", "Notes.md"]
)

workspace.open("Welcome.swift")

// ⌘O         Open a file
// ⌘K ⌘O      Open a folder
// ⇧⌘O        Go to symbol
// ⌘F         Find and replace
// ⌘\         Split the editor
// Control+`  Open the terminal
// ⌘+ / ⌘-    Make yourself comfortable
