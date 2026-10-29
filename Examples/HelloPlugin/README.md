# HelloPlugin

A minimal Swift plugin for Linvell protocol 1, available in source builds.

Follow the [bilingual quick start](https://linvell.fuluwa.top/plugins.html#quickstart) to build the app and plugin with all generated files under `~/dev/build`, copy this manifest and the executable into one package folder, then load it with **Edit → Load Development Plugin…**.

- `hello.greet`: display a configured greeting and a persistent invocation count.
- `hello.prefix`: insert the configured prefix with a versioned UTF-16 range edit (Command-Control-9).
- `hello.events`: display the document event count and most recent lifecycle event.
- `hello.uppercase`: replace the active document with uppercase text, using the editor’s undo transaction. Existing auto-save settings still apply.

The package declares `document.read`, `document.write` and `storage`, and subscribes to open/change/save/close. Commands appear under Plugins → Hello Swift. The same menu opens user/workspace JSONC configuration; effective values merge defaults, user and workspace overrides. Events store their count and last kind in the plugin’s own global state. It runs as your user outside a security sandbox. Load only code you trust. It is not a VSIX extension.

P3 adds Example Tree, Example List, Example Status and Example Tools, typed settings, the Plugin Forest theme, SF Symbol/file icons and a Swift Greeting Function snippet. `hello.inspect` reports UI item identity; `hello.refresh` publishes a new list snapshot. `onDocumentEvent` updates the status counter while persisting event state. Use the plugin menu for views/settings/resources; the command palette also exposes views, themes and snippets.

Snippets support one editor selection, numbered unique tab stops and Tab/Shift-Tab navigation; mirrors, nested placeholders and VSIX compatibility are outside this preview.

The example now depends on the standalone `Sources/LinvellPluginKit` package and can build on Linux with Swift 6. For SSH execution set `execution` to `workspace` and provide a Linux binary through the `executables` target map. See the website guide for build, runtime and transfer limits. Strip release binaries before packaging; static Swift linking still requires the host system C/C++ libraries.
