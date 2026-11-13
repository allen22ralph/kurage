# Patched copy of media_kit_libs_android_video 1.3.8

Only change: `android/build.gradle` downloads the **full** libmpv variant
(media-kit/libmpv-android-video-build v1.1.11) instead of "default" v1.1.7,
because "default" has no bitmap subtitle decoders, so PGS (Blu-ray) and DVD
subtitles don't show. Used through `dependency_overrides` in pubspec.yaml.

To update: copy the new upstream package here and re-apply that change
(URLs + MD5s of the four `full-*.jar` files).
