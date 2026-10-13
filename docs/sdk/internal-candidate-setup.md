# Internal SDK candidate setup

Formal binary SDK distribution, signing, licensing and the final installation
format are not yet delivered. This workflow is for developers authorized to
obtain a matching internal candidate. It does not download a package or verify
its publisher, signatures, ABI or runtime behavior. Keep the original package
and its recorded identity separate from the client checkout.

Use Flutter 3.47.2 / Dart 3.13.2 and PowerShell 7. The normal client requires the
SDK and has one entrypoint, `lib/main.dart`. Its media and session API overrides
select the canonical public contracts; do not edit the candidate's pubspec.

From the public client checkout, run:

```powershell
pwsh -NoProfile -File tool/configure_media_sdk.ps1 -SdkPath /absolute/path/to/package -TargetPlatform macos -SkipPubGet
flutter pub get --offline
flutter analyze --no-pub
flutter test --no-pub
flutter build macos --release --no-pub
```

Offline resolution requires the locked dependencies to already be cached.
For a fresh authorized development environment, use `flutter pub get` to obtain
dependencies before the offline check. Windows developers select
`-TargetPlatform windows` with a matching Windows SDK and build Windows instead;
Mac-only candidates reject that target. Platform-specific SDK prerequisites
remain in the package's actual instructions.

The configurator creates `.local/media-sdk/package` as a link. It leaves the
client manifest and normal entrypoint intact. Repeating the same command is
safe; another SDK path or an existing real destination directory is rejected.
There is no automatic upgrade or replacement. A pub get failure retains the
correct link so that the same command can be retried after resolving the error.

For the current Mac thin candidate, actual configuration, repeated setup,
unsupported Windows target rejection, conflicting package rejection and
subsequent offline dependency resolution were checked with private SDK source
and planning reads denied. The detailed build result is tracked separately;
this is development configuration, not formal installation acceptance.

The configurator and pub resolution work in the tested Chinese/space project
path. With the locked toolchain, that project path caused the analysis server's
LSP initialize JSON parsing to fail before source analysis. Use an ASCII project
path for the current analysis/build workflow; full Chinese-path toolchain
acceptance remains pending. This limitation does not justify rewriting an
installed SDK or claiming the failed analysis passed.
