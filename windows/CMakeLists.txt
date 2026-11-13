# Project-level configuration.
cmake_minimum_required(VERSION 3.18)
project(jellyfin_client LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "kurage")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

# === Full libmpv ===
# media_kit bundles a trimmed libmpv (2023) without bitmap subtitle decoders,
# so PGS (Blu-ray) and DVD subtitles don't show. Ship a full build instead:
# same libmpv client API, current mpv/FFmpeg. Pinned and hash-checked.
set(LIBMPV_FULL_VERSION "20261012-git-88eb9f2e73")
set(LIBMPV_FULL_ARCHIVE "mpv-dev-x86_64-${LIBMPV_FULL_VERSION}.7z")
set(LIBMPV_FULL_URL "https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261012/${LIBMPV_FULL_ARCHIVE}")
set(LIBMPV_FULL_SHA256 "a739eef92a907dfb8ea997564a3fa565b2a4f376f20a25755e7645d0c70fe5e6")
set(LIBMPV_FULL_DIR "${CMAKE_BINARY_DIR}/libmpv-full/${LIBMPV_FULL_VERSION}")
if(NOT EXISTS "${LIBMPV_FULL_DIR}/libmpv-2.dll")
  message(STATUS "Downloading ${LIBMPV_FULL_ARCHIVE}...")
  file(DOWNLOAD "${LIBMPV_FULL_URL}" "${CMAKE_BINARY_DIR}/${LIBMPV_FULL_ARCHIVE}"
    EXPECTED_HASH SHA256=${LIBMPV_FULL_SHA256} STATUS LIBMPV_FULL_STATUS)
  list(GET LIBMPV_FULL_STATUS 0 LIBMPV_FULL_CODE)
  if(NOT LIBMPV_FULL_CODE EQUAL 0)
    message(FATAL_ERROR "Couldn't download ${LIBMPV_FULL_URL}: ${LIBMPV_FULL_STATUS}")
  endif()
  file(ARCHIVE_EXTRACT INPUT "${CMAKE_BINARY_DIR}/${LIBMPV_FULL_ARCHIVE}"
    DESTINATION "${LIBMPV_FULL_DIR}" PATTERNS libmpv-2.dll)
  file(REMOVE "${CMAKE_BINARY_DIR}/${LIBMPV_FULL_ARCHIVE}")
endif()
list(FILTER PLUGIN_BUNDLED_LIBRARIES EXCLUDE REGEX "libmpv-2\\.dll$")
list(APPEND PLUGIN_BUNDLED_LIBRARIES "${LIBMPV_FULL_DIR}/libmpv-2.dll")


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

# The icon Windows shows for the app in its media overlay (see main.cpp).
install(FILES "runner/resources/app_icon.ico" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
