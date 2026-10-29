# HelloPlugin

A minimal Swift plugin for Linvell protocol 1, available in source builds.

Follow the [bilingual quick start](https://linvell.fuluwa.top/plugins.html#quickstart) to build the app and plugin with all generated files under `~/dev/build`, copy this manifest and the executable into one package folder, then load it with **Edit → Load Development Plugin…**.

- `hello.greet`: display a status message.
- `hello.uppercase`: replace the active document with uppercase text, using the editor’s undo transaction. Existing auto-save settings still apply.

The package declares `document.read` and `document.write`. It runs as your user outside a security sandbox. Load only code you trust. It is not a VSIX extension.
