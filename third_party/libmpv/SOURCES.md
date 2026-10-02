# Resource preview library sources

ProxyPin dynamically loads an unmodified, replaceable `libmpv-2.dll`. ProxyPin
source keeps its Apache-2.0 license. The selected combined library is distributed
under LGPL-3.0-or-later; its upstream mpv portion is LGPL-2.1-or-later.

## Pinned binary

- Release: https://github.com/media-kit/libmpv-win32-video-cmake/releases/tag/20241021
- Archive: https://github.com/media-kit/libmpv-win32-video-cmake/releases/download/20241021/mpv-dev-x86_64-20241021-git-0f78584.7z
- Archive SHA256: `e23701df0adc1fe57c8ede3ff313513b0b80519870058c2d35ff02754284a007`
- DLL SHA256: `56f9a69200863c2dcd2fb6367427ffedc35550d26f947d6c36eab37bd2a65fd5`
- Runtime mpv version: `v0.39.0-179-g0f78584518`
- Runtime FFmpeg version: `N-117622-g8d940a07d`

## Corresponding source references

The source and build recipes are available without charge at these pinned
references. GitHub's archive links provide downloadable source code.

| Component | Exact source | Source archive |
| --- | --- | --- |
| mpv | https://github.com/mpv-player/mpv/tree/0f7858451817c5fd5ebdb74a807a7c997662c390 | https://github.com/mpv-player/mpv/archive/0f7858451817c5fd5ebdb74a807a7c997662c390.tar.gz |
| FFmpeg | https://github.com/FFmpeg/FFmpeg/tree/8d940a07d19023a98689f353e4425a14688547e9 | https://github.com/FFmpeg/FFmpeg/archive/8d940a07d19023a98689f353e4425a14688547e9.tar.gz |
| Windows build recipes, dependency recipes and patches | https://github.com/media-kit/libmpv-win32-video-cmake/tree/8ddbe5472465950b87853789f7173f2eedc5586a | https://github.com/media-kit/libmpv-win32-video-cmake/archive/8ddbe5472465950b87853789f7173f2eedc5586a.tar.gz |
| Dart API | https://github.com/media-kit/media-kit | https://pub.dev/api/archives/media_kit-1.2.6.tar.gz |

The release tag `20241021` points to the build-recipe commit above. The build
uses `mpv -Dgpl=false` and FFmpeg `--disable-gpl --disable-nonfree
--enable-version3`. These settings must remain in any replacement redistributed
under LGPL. The old 2023 DLL from `media_kit_libs_windows_video` 1.0.11 is not used.

To rebuild the library, follow the pinned build repository's
`.github/workflows/mpv_clang.yml`, using the x86_64 toolchain. Check out the mpv
and FFmpeg commits above and preserve the patches and library dependency recipes
in that build repository. Its original workflow updates upstream repositories;
pin source revisions when preparing a reproducible replacement. The build
scripts describe the other linked dependencies; see DEPENDENCIES.md.

## Distribution and replacement

Keep the notices and full LGPL/GPL texts next to each binary distribution. A
binary distributor must also make the complete Corresponding Source of the
library and its linked dependencies available under the applicable licenses,
including the build scripts and patches. Preserve or mirror the references
above and supply the complete source archive with a published binary release;
source links alone must not be represented as a substitute for unavailable
Corresponding Source. This notice is not an unfulfilled written source offer.

For modifications, rebuild the library and replace `libmpv-2.dll` next to
`ProxyPin.exe` with an interface-compatible DLL. Runtime loading does not verify
the upstream DLL hash and does not prevent this replacement. The host
application communicates through libmpv's stable client API. The Windows build
does not statically link ProxyPin to libmpv or to FFmpeg.
