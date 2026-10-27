cmake_minimum_required(VERSION 3.22)
# This project is C + ASM only. Requesting the default C/CXX project here makes
# CMake 3.22.1 run a needless C++ compiler probe, which crashes (0xC0000409)
# with the installed NDK on Windows before the build starts.
project(dfroot C)

set(JNI_DIR ${CMAKE_CURRENT_SOURCE_DIR})

set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS}")
set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS} ${C_FLAGS} -Wall -Wextra -fno-stack-protector -fomit-frame-pointer")

set(SPLICEHELPER "${JNI_DIR}/splicehelper")
add_custom_command(
    OUTPUT "${SPLICEHELPER}"
    COMMAND "${CMAKE_C_COMPILER}"
            --target=${CMAKE_C_COMPILER_TARGET}
            --sysroot=${CMAKE_SYSROOT}
            "${JNI_DIR}/splicehelper.c"
            -o "${SPLICEHELPER}"
            -nodefaultlibs -nostartfiles -ffreestanding -static
    COMMAND "${CMAKE_STRIP}" "${SPLICEHELPER}"
    DEPENDS "${JNI_DIR}/splicehelper.c"
    COMMENT "Building splicehelper"
)
add_custom_target(splicehelper_bin DEPENDS "${SPLICEHELPER}")

set(KO_FILES
    "${JNI_DIR}/ko/dfroot-android12-4.19.ko"
    "${JNI_DIR}/ko/dfroot-android12-5.10.ko"
    "${JNI_DIR}/ko/dfroot-android13-5.10.ko"
    "${JNI_DIR}/ko/dfroot-android13-5.15.ko"
    "${JNI_DIR}/ko/dfroot-android14-5.15.ko"
    "${JNI_DIR}/ko/dfroot-android14-6.1.ko"
    "${JNI_DIR}/ko/dfroot-android15-6.6.ko"
    "${JNI_DIR}/ko/dfroot-android16-6.12.ko"
    "${JNI_DIR}/ko/dfroot-android17-6.18.ko"
)

# AGP only packages lib*.so, so the executable is named libdfroot.so and lands
# in the APK's native lib dir. The app execs it from nativeLibraryDir, which is
# executable (app data dir is not).
add_executable(dfroot exp.c libcxx.S elf_parser.c)
# libcxx.S is assembly, but CMake's ASM compiler probe also crashes with
# this CMake/NDK combination on Windows. Let the C driver assemble it; clang
# recognizes the .S extension and runs the preprocessor.
set_source_files_properties(libcxx.S PROPERTIES LANGUAGE C COMPILE_OPTIONS "-x;assembler-with-cpp")
# Use CMake's own include handling: it quotes paths correctly, so the project
# builds from any directory (even ones with spaces or parentheses).
target_include_directories(dfroot PRIVATE "${JNI_DIR}")
add_dependencies(dfroot splicehelper_bin)
set_target_properties(dfroot PROPERTIES
    PREFIX "lib"
    SUFFIX ".so"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}")

set_source_files_properties(exp.c PROPERTIES
    OBJECT_DEPENDS "${KO_FILES};${SPLICEHELPER}")

target_link_libraries(dfroot log)
target_link_options(dfroot PRIVATE -Wl,-z,max-page-size=16384)

add_executable(bootstrap bootstrap.c)
set_target_properties(bootstrap PROPERTIES
    PREFIX "lib"
    SUFFIX ".so"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_LIBRARY_OUTPUT_DIRECTORY}")
target_link_options(bootstrap PRIVATE -Wl,-z,max-page-size=16384)


