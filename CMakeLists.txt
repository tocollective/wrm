cmake_minimum_required(VERSION 3.16)

set(PROJECT_NAME "wrm081632")
project(${PROJECT_NAME} LANGUAGES C)

find_package(Git QUIET)

set(WRM081632_VERSION "unknown")

if(Git_FOUND)
    execute_process(
        COMMAND "${GIT_EXECUTABLE}" describe --tags --always --dirty
        WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
        OUTPUT_VARIABLE GIT_VERSION
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_QUIET
        RESULT_VARIABLE GIT_RESULT
    )

    if(GIT_RESULT STREQUAL "0")
        set(WRM081632_VERSION "${GIT_VERSION}")
    endif()
endif()

configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/include/version.h.in"
    "${CMAKE_CURRENT_BINARY_DIR}/generated/version.h"
    @ONLY
)

file(GLOB_RECURSE WRM081632_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/source/*.c"
    "${CMAKE_CURRENT_SOURCE_DIR}/include/*.h"
)

#
if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/vendor/SDL/CMakeLists.txt")
    message(FATAL_ERROR
        "SDL submodule is missing. Run: git submodule update --init --recursive")
endif()

if(EMSCRIPTEN)
    # no shared libraries on the web
    set(SDL_STATIC ON CACHE BOOL "" FORCE)
    set(SDL_SHARED OFF CACHE BOOL "" FORCE)
else()
    set(SDL_STATIC OFF  CACHE BOOL "" FORCE)
    set(SDL_SHARED ON CACHE BOOL "" FORCE)
endif()
set(SDL_TEST_LIBRARY OFF CACHE BOOL "" FORCE)
set(SDL_TESTS OFF CACHE BOOL "" FORCE)
set(SDL_EXAMPLES OFF CACHE BOOL "" FORCE)
set(SDL_INSTALL OFF CACHE BOOL "" FORCE)

add_subdirectory(vendor/SDL EXCLUDE_FROM_ALL)

#
add_executable(${PROJECT_NAME} ${WRM081632_SOURCES})

target_include_directories(${PROJECT_NAME}  PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_BINARY_DIR}/generated"
)

target_link_libraries(${PROJECT_NAME} PRIVATE SDL3::SDL3)

set_target_properties(${PROJECT_NAME} PROPERTIES
    C_STANDARD 99
    C_STANDARD_REQUIRED YES
    C_EXTENSIONS NO
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/bin/$<0:>"
)

#
if(EMSCRIPTEN)
    # The browser has no filesystem of its own: the firmware is packed into
    # a .data file and shows up in the virtual FS where config.c expects it.
    set(WRM081632_WEB_FIRMWARE "${CMAKE_CURRENT_SOURCE_DIR}/bin/firmware.rom"
        CACHE FILEPATH "Firmware image preloaded into the web build")

    if(NOT EXISTS "${WRM081632_WEB_FIRMWARE}")
        message(FATAL_ERROR
            "Firmware for the web build is missing: ${WRM081632_WEB_FIRMWARE}")
    endif()

    set_target_properties(${PROJECT_NAME} PROPERTIES SUFFIX ".html")
    set_property(TARGET ${PROJECT_NAME} APPEND PROPERTY LINK_DEPENDS
        "${WRM081632_WEB_FIRMWARE}")

    target_link_options(${PROJECT_NAME} PRIVATE
        "SHELL:--preload-file \"${WRM081632_WEB_FIRMWARE}@/firmware.rom\""
        "-sALLOW_MEMORY_GROWTH=1" # ROM alone is 32MB
    )
endif()
