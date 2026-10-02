# The resource preview uses package:media_kit with the upstream LGPL libmpv
# build. Do not use media_kit_libs_windows_video 1.0.11: its older bundled
# FFmpeg build enables GPL and nonfree components.
if(CMAKE_SIZEOF_VOID_P LESS 8 OR
   CMAKE_GENERATOR_PLATFORM MATCHES "^(Win32|ARM64)$" OR
   CMAKE_SYSTEM_PROCESSOR MATCHES "^(ARM64|aarch64)$")
  message(FATAL_ERROR "The pinned resource preview libmpv build supports Windows x64.")
endif()

set(RESOURCE_PREVIEW_LIBMPV_ARCHIVE_NAME
  "mpv-dev-x86_64-20241021-git-0f78584.7z")
set(RESOURCE_PREVIEW_LIBMPV_URL
  "https://github.com/media-kit/libmpv-win32-video-cmake/releases/download/20241021/${RESOURCE_PREVIEW_LIBMPV_ARCHIVE_NAME}")
set(RESOURCE_PREVIEW_LIBMPV_ARCHIVE_SHA256
  "e23701df0adc1fe57c8ede3ff313513b0b80519870058c2d35ff02754284a007")
set(RESOURCE_PREVIEW_LIBMPV_DLL_SHA256
  "56f9a69200863c2dcd2fb6367427ffedc35550d26f947d6c36eab37bd2a65fd5")
set(RESOURCE_PREVIEW_LIBMPV_CACHE "${CMAKE_BINARY_DIR}/resource_preview_libmpv")
set(RESOURCE_PREVIEW_LIBMPV_ARCHIVE
  "${RESOURCE_PREVIEW_LIBMPV_CACHE}/${RESOURCE_PREVIEW_LIBMPV_ARCHIVE_NAME}"
  CACHE FILEPATH "Verified upstream libmpv archive; may be supplied for an offline build")
set(RESOURCE_PREVIEW_LIBMPV_DLL "${RESOURCE_PREVIEW_LIBMPV_CACHE}/libmpv-2.dll")

set(_resource_preview_libmpv_valid FALSE)
if(EXISTS "${RESOURCE_PREVIEW_LIBMPV_DLL}")
  file(SHA256 "${RESOURCE_PREVIEW_LIBMPV_DLL}" _resource_preview_libmpv_hash)
  if(_resource_preview_libmpv_hash STREQUAL RESOURCE_PREVIEW_LIBMPV_DLL_SHA256)
    set(_resource_preview_libmpv_valid TRUE)
  endif()
endif()

if(NOT _resource_preview_libmpv_valid)
  file(MAKE_DIRECTORY "${RESOURCE_PREVIEW_LIBMPV_CACHE}")
  if(NOT EXISTS "${RESOURCE_PREVIEW_LIBMPV_ARCHIVE}")
    message(STATUS "Downloading the pinned LGPL resource preview libmpv library")
    file(DOWNLOAD "${RESOURCE_PREVIEW_LIBMPV_URL}"
      "${RESOURCE_PREVIEW_LIBMPV_ARCHIVE}.download"
      EXPECTED_HASH "SHA256=${RESOURCE_PREVIEW_LIBMPV_ARCHIVE_SHA256}"
      TLS_VERIFY ON
      TIMEOUT 180
      INACTIVITY_TIMEOUT 30
      STATUS _resource_preview_libmpv_download)
    list(GET _resource_preview_libmpv_download 0 _resource_preview_libmpv_status)
    if(NOT _resource_preview_libmpv_status EQUAL 0)
      list(GET _resource_preview_libmpv_download 1 _resource_preview_libmpv_error)
      message(FATAL_ERROR "libmpv download failed: ${_resource_preview_libmpv_error}")
    endif()
    # Preserve a retryable cache when a download is interrupted. A supplied
    # offline archive is never overwritten by a failed network request.
    configure_file("${RESOURCE_PREVIEW_LIBMPV_ARCHIVE}.download"
      "${RESOURCE_PREVIEW_LIBMPV_ARCHIVE}" COPYONLY)
  endif()

  file(SHA256 "${RESOURCE_PREVIEW_LIBMPV_ARCHIVE}" _resource_preview_libmpv_archive_hash)
  if(NOT _resource_preview_libmpv_archive_hash STREQUAL RESOURCE_PREVIEW_LIBMPV_ARCHIVE_SHA256)
    message(FATAL_ERROR "The resource preview libmpv archive SHA256 does not match the pinned release.")
  endif()
  execute_process(
    COMMAND "${CMAKE_COMMAND}" -E tar xzf "${RESOURCE_PREVIEW_LIBMPV_ARCHIVE}" -- libmpv-2.dll
    WORKING_DIRECTORY "${RESOURCE_PREVIEW_LIBMPV_CACHE}"
    RESULT_VARIABLE _resource_preview_libmpv_extract)
  if(NOT _resource_preview_libmpv_extract EQUAL 0 OR
     NOT EXISTS "${RESOURCE_PREVIEW_LIBMPV_DLL}")
    message(FATAL_ERROR "Could not extract the resource preview libmpv library.")
  endif()
  file(SHA256 "${RESOURCE_PREVIEW_LIBMPV_DLL}" _resource_preview_libmpv_hash)
  if(NOT _resource_preview_libmpv_hash STREQUAL RESOURCE_PREVIEW_LIBMPV_DLL_SHA256)
    message(FATAL_ERROR "The resource preview libmpv DLL SHA256 does not match the pinned release.")
  endif()
endif()

# The Dart adapter loads this replaceable shared library at runtime. Its
# installed copy is deliberately not hash-enforced: LGPL users may substitute
# an interface-compatible library. The hashes above verify build inputs only.
install(FILES "${RESOURCE_PREVIEW_LIBMPV_DLL}"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
install(DIRECTORY "${CMAKE_CURRENT_LIST_DIR}/../../third_party/libmpv/"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}/licenses/libmpv" COMPONENT Runtime)
