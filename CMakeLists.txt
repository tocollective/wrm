cmake_minimum_required(VERSION 3.16)

set(PROJECT_NAME "wrm081632")
project(${PROJECT_NAME} LANGUAGES C)

# A fresh build directory gets an optimized build: without -O the machine
# can't keep up with its clock rate. Multi-config generators pick per build.
get_property(WRM081632_MULTI_CONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(NOT WRM081632_MULTI_CONFIG AND NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING
        "Build type: Debug, Release, RelWithDebInfo or MinSizeRel" FORCE)
endif()

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

# miniaudio: sound output only, so the decoders, the node graph and the
# engine are left out
if(NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/vendor/miniaudio/miniaudio.c")
    message(FATAL_ERROR
        "miniaudio submodule is missing. Run: git submodule update --init --recursive")
endif()

add_library(miniaudio STATIC
    "${CMAKE_CURRENT_SOURCE_DIR}/vendor/miniaudio/miniaudio.c")
target_include_directories(miniaudio SYSTEM PUBLIC
    "${CMAKE_CURRENT_SOURCE_DIR}/vendor/miniaudio")
target_compile_definitions(miniaudio PUBLIC
    MA_NO_DECODING
    MA_NO_ENCODING
    MA_NO_GENERATION
    MA_NO_RESOURCE_MANAGER
    MA_NO_NODE_GRAPH
    MA_NO_ENGINE
)
if(NOT EMSCRIPTEN)
    # its audio thread; on the web it plays through Web Audio instead
    find_package(Threads REQUIRED)
    target_link_libraries(miniaudio PUBLIC Threads::Threads ${CMAKE_DL_LIBS})
endif()

#
add_executable(${PROJECT_NAME} ${WRM081632_SOURCES})

target_include_directories(${PROJECT_NAME}  PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}/include"
    "${CMAKE_CURRENT_BINARY_DIR}/generated"
)

target_link_libraries(${PROJECT_NAME} PRIVATE SDL3::SDL3 miniaudio)

# warnings for our own code only, not for SDL and miniaudio
if(MSVC)
    target_compile_options(${PROJECT_NAME} PRIVATE /W4)
else()
    target_compile_options(${PROJECT_NAME} PRIVATE -Wall -Wextra)
endif()

# Sanitizers for our own code, e.g. -DWRM081632_SANITIZE=address,undefined:
# the guest drives device registers and DMA, so a bad index there is a
# bug in the host process. Any report stops the emulator with an error.
set(WRM081632_SANITIZE "" CACHE STRING
    "Sanitizers to build the emulator with (GCC/Clang -fsanitize=...)")
if(WRM081632_SANITIZE)
    if(MSVC)
        message(FATAL_ERROR "WRM081632_SANITIZE needs GCC or Clang")
    endif()
    target_compile_options(${PROJECT_NAME} PRIVATE
        -fsanitize=${WRM081632_SANITIZE}
        -fno-sanitize-recover=all
        -fno-omit-frame-pointer)
    target_link_options(${PROJECT_NAME} PRIVATE
        -fsanitize=${WRM081632_SANITIZE})
endif()

# the network card's sockets: Winsock on Windows; elsewhere they are in
# libc (on the web Emscripten turns them into WebSockets)
if(WIN32)
    target_link_libraries(${PROJECT_NAME} PRIVATE ws2_32)
endif()

# the random number generator's bits come from BCryptGenRandom on Windows
if(WIN32)
    target_link_libraries(${PROJECT_NAME} PRIVATE bcrypt)
endif()

# sqrtf and fmaf of the CPU's floating point (and miniaudio's resampler)
# are in libm on Linux
find_library(WRM081632_LIBM m)
if(WRM081632_LIBM)
    target_link_libraries(${PROJECT_NAME} PRIVATE ${WRM081632_LIBM})
    target_link_libraries(miniaudio PUBLIC ${WRM081632_LIBM})
endif()

set_target_properties(${PROJECT_NAME} PROPERTIES
    C_STANDARD 99
    C_STANDARD_REQUIRED YES
    C_EXTENSIONS NO
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/bin/$<0:>"
)

# Tests: one CTest test per test ROM (tests/<group>/<name>.asm), each
# assembled and run headless by tests/run.py
if(NOT EMSCRIPTEN)
    find_package(Python3 COMPONENTS Interpreter)
    if(Python3_FOUND)
        enable_testing()
        file(GLOB WRM081632_TESTS CONFIGURE_DEPENDS
            "${CMAKE_CURRENT_SOURCE_DIR}/tests/*/*.asm")
        list(FILTER WRM081632_TESTS EXCLUDE REGEX "/tests/common/")
        foreach(test ${WRM081632_TESTS})
            file(RELATIVE_PATH name "${CMAKE_CURRENT_SOURCE_DIR}/tests" "${test}")
            string(REGEX REPLACE "\\.asm$" "" name "${name}")
            add_test(NAME ${name}
                COMMAND "${Python3_EXECUTABLE}"
                    "${CMAKE_CURRENT_SOURCE_DIR}/tests/run.py"
                    --emulator "$<TARGET_FILE:${PROJECT_NAME}>"
                    --jobs 1 "${test}")
        endforeach()
    else()
        message(STATUS "Python 3 not found: tests are disabled")
    endif()
endif()

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
