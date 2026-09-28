# Non-installable package examples

These JSON files illustrate [the package proposal](../PACKAGING.md). They contain
no usable binary, actual file hashes, release URL, license grant or signature proof.
`exampleOnly: true` is mandatory and causes installation rejection. Null values
mean evidence is absent, never "skip validation". They are not partial installers.
The media API fields describe the current `0.8.0` planning target; empty
`testedVersions` means no binary artifact has passed that compatibility check.

- `native-windows-x64.json` and `flutter-windows-x64.json`: matching Windows x64 roots.
- `native-windows-arm64.json` and `flutter-windows-arm64.json`: matching Windows ARM64 roots.
- `native-macos-universal.json` and `flutter-macos-universal.json`: matching macOS arm64/x86_64 roots.
- `release-index.json`: all six required attachment identities, with no actual
  artifact hashes or completed matrix. A real release index must pin the exact
  signed and packaged bytes of every attachment.

The example file inventories show representative required paths. A real package
must enumerate every actual file/link, including all headers/framework internals,
public source snapshots, runtime dependencies and licenses. The examples cannot
be promoted by flipping one boolean or copying placeholder paths into a release.
