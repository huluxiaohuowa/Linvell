# HelloPlugin

A minimal Swift plugin for Linvell protocol 1, available in source builds.

Follow the [bilingual quick start](https://linvell.fuluwa.top/plugins.html#quickstart) to build the app and plugin with all generated files under `~/dev/build`, copy this manifest and the executable into one package folder, then load it with **Edit → Load Development Plugin…**.

- `hello.greet`: display a configured greeting and a persistent invocation count.
- `hello.prefix`: insert the configured prefix with a versioned UTF-16 range edit (Command-Control-9).
- `hello.events`: display the document event count and most recent lifecycle event.
- `hello.uppercase`: replace the active document with uppercase text, using the editor’s undo transaction. Existing auto-save settings still apply.

The package declares `document.read`, `document.write` and `storage`, and subscribes to open/change/save/close. Commands appear under Plugins → Hello Swift. The same menu opens user/workspace JSONC configuration; effective values merge defaults, user and workspace overrides. Events store their count and last kind in the plugin’s own global state. It runs as your user outside a security sandbox. Load only code you trust. It is not a VSIX extension.
