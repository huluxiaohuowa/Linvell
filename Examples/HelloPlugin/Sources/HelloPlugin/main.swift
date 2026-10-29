import LinvellPluginKit

try PluginServer.run { context in
    switch context.command {
    case "hello.greet": return PluginCommandResult(message:"Hello from a Swift plugin!")
    case "hello.uppercase":
        guard let document = context.document else { return PluginCommandResult(message:"Open a text document first.") }
        return PluginCommandResult(message:"Converted document to uppercase.",replacementText:document.text.uppercased())
    default: return PluginCommandResult(message:"Unknown command.")
    }
}
