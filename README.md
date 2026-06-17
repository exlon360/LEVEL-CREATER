# LEVEL CREATER

A standalone iOS level creator and playtester app.

## Features

- Touch-first level editor with drag painting.
- Block Library with feature blocks.
- Playtest mode with movement, jumping, attacking, enemies, water, moving platforms, and checkpoints.
- Multi-level slots.
- Unsigned IPA build workflow on GitHub Actions.

## Build

Run the iOS CI workflow, or build locally on macOS:

```bash
xcodebuild -project LevelCreator.xcodeproj -scheme LevelCreator -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
```

Create an unsigned IPA:

```bash
bash scripts/build_level_creator_unsigned_ipa.sh
```

Tag a release to publish an IPA:

```bash
git tag v0.1.0
git push origin v0.1.0
```
