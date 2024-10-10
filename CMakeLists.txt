# Derived from the Pico SDK, which carries the following
# LICENSE.txt:
# Copyright 2020 (c) 2020 Raspberry Pi (Trading) Ltd.
#
# Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
# following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following
#    disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following
#    disclaimer in the documentation and/or other materials provided with the distribution.
#
# 3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products
#    derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
# INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
# WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

cmake_minimum_required(VERSION 3.13)

set(ENV{PICO_SDK_PATH} "${CMAKE_SOURCE_DIR}/external/pico-sdk")

include(pico_sdk_import.cmake)

project(test_project C CXX ASM)

set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 17)


find_package(Git)
if(NOT GIT_FOUND) 
    message(FATA_ERROR "Git not found")
endif()

# Get all patches in patches directory in a list and apply them
# (debug command)
file(GLOB PATCHES "${CMAKE_SOURCE_DIR}/patches/*")
foreach(PATCH ${PATCHES})
    message(STATUS "Applying patch: ${PATCH}")
    execute_process(
        COMMAND ${GIT_EXECUTABLE} apply ${PATCH}
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
        ERROR_QUIET
        OUTPUT_STRIP_TRAILING_WHITESPACE
        )
endforeach()

# Use git status --porcelain --ignore-submodules=dirty to check if there are uncommited changes.
# There are uncommited changes if there is at least a line starting with something different to "??".
execute_process(
    COMMAND ${GIT_EXECUTABLE} status --porcelain --ignore-submodules=dirty
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    OUTPUT_VARIABLE GIT_STATUS
    ERROR_QUIET
    OUTPUT_STRIP_TRAILING_WHITESPACE
)

# Check every line of GIT_STTUS to see if there is any line starting with something different to "??".
# If there is, then there are uncommited changes.
string(REGEX MATCH "^[^?]" DIRTY_FLAG "${GIT_STATUS}")
if(DIRTY_FLAG)
    message(STATUS "There are uncommited changes")
    set(DIRTY_FLAG "--dirty")
else()
    message(STATUS "There are no uncommited changes")
    set(DIRTY_FLAG "")
endif()

#https://bravenewmethod.com/2017/07/14/git-revision-as-compiler-definition-in-build-with-cmake/
message(STATUS "Resolving GIT Version...")
execute_process(
    COMMAND ${GIT_EXECUTABLE} describe --long --tags --match "[[:digit:]]*" --abbrev=8 ${DIRTY_FLAG} --always
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
    OUTPUT_VARIABLE BUILD_VERSION
    ERROR_QUIET
    OUTPUT_STRIP_TRAILING_WHITESPACE
    )
message( STATUS "GIT hash: ${BUILD_VERSION}")

pico_sdk_init()

# Build the bootloader as a standalone thing

add_executable(bootloader 
	src/main.c
	src/usb-descriptors.c
)

function(target_cl_options option)
    target_compile_options(bootloader PRIVATE ${option})
    target_link_options(bootloader PRIVATE ${option})
endfunction()

target_cl_options("-Os")
target_cl_options("-ffunction-sections")
target_cl_options("-fdata-sections")
target_link_options(bootloader PRIVATE "LINKER:--gc-sections")

pico_add_extra_outputs(bootloader)
pico_set_binary_type(bootloader copy_to_ram)

set_target_properties(bootloader PROPERTIES COMPILE_FLAGS "-Wall")

pico_set_linker_script(bootloader ${CMAKE_CURRENT_SOURCE_DIR}/bootloader.ld)

target_include_directories(bootloader PUBLIC
	./src
	external/pico-sdk/lib/tinyusb/src)

target_link_libraries(bootloader
                      pico_stdlib
					  pico_stdio_usb
                      hardware_dma
                      hardware_flash
                      hardware_structs
                      hardware_resets
                      cmsis_core
					  pico_multicore
					  pico_stdlib_headers
					  tinyusb_device
)

set(BOOTLOADER_DIR "${CMAKE_CURRENT_LIST_DIR}" CACHE INTERNAL "")

# Build a library to embed into applications

function(bootloader_define_library)
	set(NAME bootloader)
	set(ORIGINAL_BIN ${CMAKE_CURRENT_BINARY_DIR}/${NAME}.bin)
	set(BIN_ASM ${CMAKE_CURRENT_BINARY_DIR}/${NAME}_bin.S)

	add_custom_target(${NAME}_bin DEPENDS ${ORIGINAL_BIN})
	add_custom_command(OUTPUT ${ORIGINAL_BIN} DEPENDS ${NAME} COMMAND ${CMAKE_OBJCOPY} -Obinary $<TARGET_FILE:${NAME}> ${ORIGINAL_BIN})

	find_package (Python3 REQUIRED COMPONENTS Interpreter)
	add_custom_target(${NAME}_bin_asm DEPENDS ${BIN_ASM})
	add_custom_command(OUTPUT ${BIN_ASM} DEPENDS ${ORIGINAL_BIN}
		COMMAND ${Python3_EXECUTABLE} ${BOOTLOADER_DIR}/mkasm.py ${ORIGINAL_BIN} ${BIN_ASM}
	)

	add_library(${NAME}_library INTERFACE)
	add_dependencies(${NAME}_library ${NAME}_bin_asm)
	# not strictly (or indeed actually) a link library, but this avoids dependency cycle
	target_link_libraries(${NAME}_library INTERFACE ${BIN_ASM})
endfunction()

bootloader_define_library()

# Provide a helper to build a combined target

function(bootloader_build_combined NAME)
	set(APP ${NAME}_app)
	set(APP_BIN ${CMAKE_CURRENT_BINARY_DIR}/${APP}.bin)
	set(APP_HDR ${CMAKE_CURRENT_BINARY_DIR}/${APP}_hdr.bin)

	set(COMBINED ${NAME}_combined)

	target_link_libraries(${NAME} bootloader_library)

	pico_set_linker_script(${NAME} ${BOOTLOADER_DIR}/combined.ld)

	pico_add_bin_output(${NAME})

	# TODO: The hard-coded 68k here is a bit nasty
	add_custom_target(${APP}_bin DEPENDS ${APP_BIN})
	add_custom_command(OUTPUT ${APP_BIN} DEPENDS ${NAME}.bin
		COMMAND dd ibs=1k iseek=68 if=${NAME}.bin of=${APP_BIN}
	)

	# TODO: The hard-coded address here is a bit nasty
	add_custom_target(${APP}_hdr DEPENDS ${APP}_bin)
	add_custom_command(OUTPUT ${APP_HDR} DEPENDS ${APP_BIN}
		COMMAND ${BOOTLOADER_DIR}/gen_imghdr.py -a 0x10010000 ${APP_BIN} ${APP_HDR}
	)

	add_custom_target(${COMBINED} ALL DEPENDS ${APP_HDR})
	add_custom_command(TARGET ${COMBINED} DEPENDS ${APP_HDR}
		COMMAND ${CMAKE_OBJCOPY} --update-section .app_hdr=${APP_HDR} ${NAME}.elf ${COMBINED}.elf
	)
	add_custom_command(TARGET ${COMBINED} POST_BUILD
		COMMAND ${CMAKE_OBJCOPY} -Obinary ${COMBINED}.elf ${COMBINED}.bin
	)
endfunction()

# Provide a helper to build a standalone target

function(bootloader_build_standalone NAME)
	pico_set_linker_script(${NAME} ${BOOTLOADER_DIR}/standalone.ld)
	pico_add_bin_output(${NAME})
endfunction()
