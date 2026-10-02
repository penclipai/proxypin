# Upstream dependency sources and notices

The LGPL libmpv shared library includes statically linked third-party libraries.
They retain their own copyright notices and license terms. The index below is
extracted from the published Windows build recipes, including support-library
recipes. Build flags in those recipes determine which components are linked.

The bundled upstream license and copyright texts are in `dependency-licenses/`.
The exact mpv and FFmpeg source commits are in SOURCES.md. Some upstream
support-library recipes follow Git branches instead of fixed commits. A binary
release publisher must preserve complete Corresponding Source, including those
library revisions and the upstream patches, in addition to the recipe archive.
This index does not claim that an unpinned Git branch is the exact source
revision of the 2024 binary.

| Dependency | Upstream source | Published build recipe |
| --- | --- | --- |
| brotli | https://github.com/google/brotli.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/brotli.cmake) |
| bzip2 | https://gitlab.com/bzip2/bzip2.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/bzip2.cmake) |
| dav1d | https://code.videolan.org/videolan/dav1d.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/dav1d.cmake) |
| expat | https://github.com/libexpat/libexpat.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/expat.cmake) |
| fontconfig | https://gitlab.freedesktop.org/fontconfig/fontconfig.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/fontconfig.cmake) |
| freetype2 | https://github.com/freetype/freetype.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/freetype2.cmake) |
| fribidi | https://github.com/fribidi/fribidi.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/fribidi.cmake) |
| gmp | https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/gmp.cmake) |
| harfbuzz | https://github.com/harfbuzz/harfbuzz.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/harfbuzz.cmake) |
| highway | https://github.com/google/highway.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/highway.cmake) |
| lcms2 | https://github.com/mm2/Little-CMS.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/lcms2.cmake) |
| libarchive | https://github.com/libarchive/libarchive.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libarchive.cmake) |
| libass | https://github.com/libass/libass.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libass.cmake) |
| libbs2b | https://github.com/alexmarsev/libbs2b.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libbs2b.cmake) |
| libiconv | https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.17.tar.gz | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libiconv.cmake) |
| libjpeg | https://github.com/libjpeg-turbo/libjpeg-turbo.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libjpeg.cmake) |
| libjxl | https://github.com/libjxl/libjxl.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libjxl.cmake) |
| libmysofa | https://github.com/hoene/libmysofa.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libmysofa.cmake) |
| libplacebo | https://github.com/haasn/libplacebo.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libplacebo.cmake) |
| libpng | https://github.com/glennrp/libpng.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libpng.cmake) |
| libressl | https://cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-3.1.5.tar.gz | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libressl.cmake) |
| libsoxr | https://gitlab.com/shinchiro/soxr.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libsoxr.cmake) |
| libsrt | https://github.com/Haivision/srt.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libsrt.cmake) |
| libssh | https://gitlab.com/libssh/libssh-mirror.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libssh.cmake) |
| libunibreak | https://github.com/adah1972/libunibreak.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libunibreak.cmake) |
| libvpl | https://github.com/intel/libvpl.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libvpl.cmake) |
| libvpx | https://chromium.googlesource.com/webm/libvpx.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libvpx.cmake) |
| libwebp | https://chromium.googlesource.com/webm/libwebp.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libwebp.cmake) |
| libxml2 | https://github.com/GNOME/libxml2.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libxml2.cmake) |
| libzimg | https://bitbucket.org/the-sekrit-twc/zimg.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/libzimg.cmake) |
| openssl | https://github.com/openssl/openssl.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/openssl.cmake) |
| shaderc | https://github.com/google/shaderc.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/shaderc.cmake) |
| speex | https://github.com/xiph/speex.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/speex.cmake) |
| spirv-cross | https://github.com/KhronosGroup/SPIRV-Cross.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/spirv-cross.cmake) |
| spirv-headers | https://github.com/KhronosGroup/SPIRV-Headers.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/spirv-headers.cmake) |
| spirv-tools | https://github.com/KhronosGroup/SPIRV-Tools.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/spirv-tools.cmake) |
| uchardet | https://gitlab.freedesktop.org/uchardet/uchardet.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/uchardet.cmake) |
| vulkan-header | https://github.com/KhronosGroup/Vulkan-Headers.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/vulkan-header.cmake) |
| vulkan | https://github.com/KhronosGroup/Vulkan-Loader.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/vulkan.cmake) |
| xz | https://gitlab.com/shinchiro/xz.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/xz.cmake) |
| zlib | https://github.com/zlib-ng/zlib-ng.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/zlib.cmake) |
| zstd | https://github.com/facebook/zstd.git | [recipe](https://github.com/media-kit/libmpv-win32-video-cmake/blob/8ddbe5472465950b87853789f7173f2eedc5586a/packages/zstd.cmake) |
