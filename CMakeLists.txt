cmake_minimum_required(VERSION 3.20)
project(CommentToggler VERSION 1.0.0 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0")
set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# Host plugin interface + Scintilla (read-only; NO host changes)
set(NPP_MACOS_DIR      "${CMAKE_SOURCE_DIR}/../../notepad-plus-plus-macos")
set(NPP_PLUGIN_INCLUDE "${NPP_MACOS_DIR}/src")
set(SCINTILLA_INCLUDE  "${NPP_MACOS_DIR}/scintilla/include")

add_library(CommentToggler SHARED src/CommentToggler.mm)
target_include_directories(CommentToggler PRIVATE ${NPP_PLUGIN_INCLUDE} ${SCINTILLA_INCLUDE})
target_link_libraries(CommentToggler PRIVATE "-framework Cocoa")
target_compile_options(CommentToggler PRIVATE
    -Wall -Wno-unused-parameter -fvisibility=hidden
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
set_target_properties(CommentToggler PROPERTIES PREFIX "" SUFFIX ".dylib")
target_link_options(CommentToggler PRIVATE "-Wl,-current_version,${PROJECT_VERSION}")

# Install (real plugins dir). Toolbar PNGs live at the plugin root (host looks
# there first); langs.model.xml in resources/.
set(PLUGIN_INSTALL_DIR "$ENV{HOME}/Library/Application Support/Nextpad++/plugins/CommentToggler")
install(TARGETS CommentToggler DESTINATION "${PLUGIN_INSTALL_DIR}")
install(FILES "${CMAKE_SOURCE_DIR}/toolbar.png" "${CMAKE_SOURCE_DIR}/toolbar_dark.png"
        DESTINATION "${PLUGIN_INSTALL_DIR}")
install(FILES "${CMAKE_SOURCE_DIR}/resources/langs.model.xml"
        DESTINATION "${PLUGIN_INSTALL_DIR}/resources")
