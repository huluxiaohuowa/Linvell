# Distribution verification

2026-10-28

## App artifacts

- Artifact source commit: `3847a405ce072742130af9d0447b5b67fa14fcc8`.
- Built locally: Universal `arm64` + `x86_64`, minimum macOS 15.6 verified from both Mach-O slices.
- Developer ID + Hardened Runtime signing passed.
- Apple notarization returned `Accepted`; the application ticket was stapled and validated.
- The ZIP was extracted into a separate verification directory. `codesign --verify --deep --strict`, stapler validation and `spctl --assess --type execute` passed against the extracted app.
- ZIP and DMG SHA-256 values matched the checksum file.
- Both artifacts, checksum file and manifest were uploaded to a **draft prerelease** named `v0.1.0-preview.1` in the Linvell repository. No public app release is claimed.
- The subsequent source commit changes only the release push's authentication helper, not application behavior.

Pending: final pinned-terminal runtime, light/dark UI, clean-machine first launch and Intel runtime. The workstation lock interrupted native UI verification. Draft publication remains gated on the remaining local runtime checks.

## Official website

- https://linvell.fuluwa.top/ returned HTTPS 200 with normal certificate validation.
- HTTP returned 301 to the HTTPS URL.
- GitHub Pages reports `built`, the expected custom domain, an approved domain certificate and `https_enforced: true`.
- Live in-app-browser inspection confirmed the expected page text and both images loaded over HTTPS.
- Desktop and mobile layouts, Chinese language switching and development-page navigation were inspected.
- Website repository: `huluxiaohuowa/linvell-web`; Pages serves static files from `main` `/`. No app runner workflow was added.
