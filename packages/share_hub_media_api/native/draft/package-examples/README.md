# Non-installable package examples

These JSON files illustrate [the package proposal](../PACKAGING.md). They contain
no usable binary, actual file hashes, release URL, license grant or signature proof.
`exampleOnly: true` is mandatory and causes installation rejection. Null values
mean evidence is absent, never "skip validation". They are not partial installers.

- `native-windows-x64.json`: native-only example root.
- `flutter-windows-x64.json`: thin plugin with the matching nested native example.
- `release-index.json`: partial example matrix; formal release still requires
  Windows x64/ARM64 and macOS universal in native + Flutter form.

The example file inventories show representative required paths. A real package
must enumerate every actual file/link, including all headers/framework internals,
public source snapshots, runtime dependencies and licenses. The examples cannot
be promoted by flipping one boolean or copying placeholder paths into a release.
