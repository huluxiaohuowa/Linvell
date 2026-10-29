import LinvellPluginKit

try PluginServer.run(onEvent: { event in
    let count = event.environment?.globalState["eventCount"]?.number ?? 0
    return [
        PluginStateUpdate(scope:.global,key:"eventCount",value:.number(count+1)),
        PluginStateUpdate(scope:.global,key:"lastEvent",value:.string("\(event.kind.rawValue) @ revision \(event.revision)"))
    ]
}) { context in
    let environment = context.environment
    switch context.command {
    case "hello.greet":
        let greeting = environment?.configuration["greeting"]?.string ?? "Hello from a Swift plugin!"
        let runs = (environment?.globalState["runs"]?.number ?? 0)+1
        return PluginCommandResult(message:"\(greeting) (#\(Int(runs)))",stateUpdates:[PluginStateUpdate(scope:.global,key:"runs",value:.number(runs))])
    case "hello.uppercase":
        guard let document = context.document else { return PluginCommandResult(message:"Open a text document first.") }
        return PluginCommandResult(message:"Converted document to uppercase.",replacementText:document.text.uppercased())
    case "hello.prefix":
        guard let document = context.document else { return PluginCommandResult(message:"Open a text document first.") }
        let prefix = environment?.configuration["prefix"]?.string ?? "Hello: "
        return PluginCommandResult(message:"Inserted a prefix with a range edit.",edits:[PluginTextEdit(location:0,length:0,text:prefix)],documentRevision:document.revision)
    case "hello.events":
        let count = environment?.globalState["eventCount"]?.number ?? 0
        let last = environment?.globalState["lastEvent"]?.string ?? "none"
        return PluginCommandResult(message:"Document events: \(Int(count)); last: \(last)")
    default: return PluginCommandResult(message:"Unknown command.")
    }
}
