# flutter_qjs: Kikuyomi's maintained fork

This directory is Kikuyomi's fork of [`flutter_qjs`](https://github.com/ekibun/flutter_qjs), the
QuickJS binding that source extensions will run in. ADR-0001 chose it on the condition that the
project carries it as a maintained fork: the published package has had no release for four years
and does not run on current Dart. `README.md` is upstream's own documentation, kept unchanged.

## Upstream

- **Package:** `flutter_qjs` 0.3.7, the archive published on pub.dev
  (`flutter_qjs-0.3.7.tar.gz`, SHA-256
  `123b6a2c95ceb4343a15a2bf4eb8e22f6f30d17c291b7a6c71f759906f817525`).
- **Engine:** QuickJS 2021-03-27, vendored by upstream in `cxx/quickjs/`.
- **Left out:** `example/`, `coverage/` and `flutter_qjs.iml`. None of them is part of the plugin.

The first commit that added this directory is that archive unchanged, so `git log -p` on it shows
every change the fork has made.

## Licences

`LICENSE` is flutter_qjs's MIT licence and `cxx/quickjs/LICENSE` is QuickJS's MIT licence. Both
stay with the code. Changes made here are offered under the same MIT licence as the files they
change.

## Changes from upstream

Only what is needed to build and run. Each is its own commit.

1. **Dart 3.13** (`lib/src/ffi.dart`). Published 0.3.7 fails every call with
   `Pointer.fromFunction cannot be called dynamically`. `channelDispacher` now returns a
   non-nullable pointer, falling back to `nullptr`, and `Pointer.fromFunction` gets its explicit
   `<_JSChannelNative>` type argument. This is `spikes/quickjs_binding/flutter_qjs-dart313.patch`.

## Using it

It is not published and must never be published under upstream's name. Depend on it by path:

```yaml
dependencies:
  flutter_qjs:
    path: <relative path to>/third_party/flutter_qjs
```

It sits outside the pub workspace, so `flutter analyze app packages` and
`dart format app packages` do not cover it. Its test is the probe in
`spikes/quickjs_binding/qjs_probe`, which `.github/workflows/android-emulator.yml` runs on Android
emulators.
