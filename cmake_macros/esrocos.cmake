macro(esrocos_init)
  # Additional CMake modules for ESROCOS 
  list(APPEND CMAKE_MODULE_PATH "${CMAKE_INSTALL_PREFIX}/cmake_modules")
  list(APPEND CMAKE_MODULE_PATH "${CMAKE_INSTALL_PREFIX}/cmake_modules/codecov")
  list(APPEND CMAKE_MODULE_PATH "${CMAKE_INSTALL_PREFIX}/cmake_modules/pybind11")
  
  #PKGCONFIG ENV
  set(ENV{PKG_CONFIG_PATH} "${CMAKE_INSTALL_PREFIX}/lib/pkgconfig/")

  file(WRITE ${CMAKE_BINARY_DIR}/linkings.yml "")

  # PkgConfig
  INCLUDE(FindPkgConfig)
 
  install(FILES noopfile
          DESTINATION noopfile
          OPTIONAL)

  # TASTE install prefix
  execute_process(
    COMMAND taste-config --prefix
    OUTPUT_VARIABLE TASTE_PREFIX
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
  set(TASTE_PREFIX ${TASTE_PREFIX} CACHE INTERNAL TASTE_PREFIX FORCE)
  message(STATUS "set cache variable TASTE_PREFIX=${TASTE_PREFIX}")

  add_custom_target(init_esrocos ALL)
endmacro(esrocos_init)

function(esrocos_export_function FUNCTION_DIR INSTALL_DIR)

  add_custom_target(create_install_dir ALL 
                  COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_INSTALL_PREFIX}/${INSTALL_DIR})
  add_custom_target(create_zip ALL
                  COMMAND ${CMAKE_COMMAND} -E tar "cfv" "${CMAKE_BINARY_DIR}/${FUNCTION_DIR}.zip" "--format=zip" "${FUNCTION_DIR}"
		  WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
                  DEPENDS create_install_dir)

  install(FILES ${CMAKE_BINARY_DIR}/${FUNCTION_DIR}.zip
                ${CMAKE_SOURCE_DIR}/${CMAKE_PROJECT_NAME}_iv.aadl
          DESTINATION ${CMAKE_INSTALL_PREFIX}/${INSTALL_DIR})

endfunction(esrocos_export_function)

function(esrocos_export_pkgconfig)
  set(oneValueArgs DESCRIPTION VERSION)
  set(multiValueArgs REQUIRES LIBS STATIC_LIBS CFLAGS)

  cmake_parse_arguments(esrocos_export_pkgconfig "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN} )

  SET(PROJECT_NAME ${CMAKE_PROJECT_NAME})
  SET(PKG_CONFIG_REQUIRES ${esrocos_export_pkgconfig_REQUIRES})
  SET(VERSION ${esrocos_export_pkgconfig_VERSION})
  SET(DESCRIPTION ${esrocos_export_pkgconfig_DESCRIPTION})
  SET(PKG_CONFIG_CFLAGS ${esrocos_export_pkgconfig_CFLAGS})
  SET(PKG_CONFIG_LIBS ${esrocos_export_pkgconfig_LIBS})
  SET(PKG_CONFIG_LIBS_STATIC ${esrocos_export_pkgconfig_STATIC_LIBS})

  CONFIGURE_FILE(
    "${CMAKE_INSTALL_PREFIX}/templates/pkg-config-template.pc.in"
    "${CMAKE_INSTALL_PREFIX}/lib/pkgconfig/${CMAKE_PROJECT_NAME}.pc"
  )
endfunction(esrocos_export_pkgconfig)

function(esrocos_build_project)

add_custom_target(ESROCOS_BUILD_PROJECT ALL)

add_dependencies(ESROCOS_BUILD_PROJECT init_esrocos)

add_custom_command(
    TARGET ESROCOS_BUILD_PROJECT 
    POST_BUILD
    COMMAND ${CMAKE_COMMAND}
    ARGS -P ${CMAKE_INSTALL_PREFIX}/cmake_macros/build_project.cmake
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)


endfunction(esrocos_build_project)
 
function(esrocos_add_dependency)
  set(oneValueArgs PARTITION)
  set(multiValueArgs MODULES)

  cmake_parse_arguments(esrocos_add_dependency "${options}" "${oneValueArgs}" "${multiValueArgs}" ${ARGN} )

  set(LOCAL_WO "${esrocos_add_dependency_PARTITION}:")
  
  foreach(MODULE ${esrocos_add_dependency_MODULES})

    pkg_check_modules(LINK_LIBS REQUIRED ${MODULE})

    foreach(LIB ${LINK_LIBS_STATIC_LIBRARIES})
   
      set(NOT_INCLUDED TRUE)
      foreach(DIR ${LINK_LIBS_STATIC_LIBRARY_DIRS})
        if(EXISTS "${DIR}/lib${LIB}.a") 
          set(LOCAL_WO "${LOCAL_WO}\n- ${DIR}/lib${LIB}.a")
          set(NOT_INCLUDED FALSE)
        elseif(EXISTS "${DIR}/lib${LIB}.so") 
          set(LOCAL_WO "${LOCAL_WO}\n- ${DIR}/lib${LIB}.so")
          set(NOT_INCLUDED FALSE)
        endif()   
      endforeach(DIR)

      if(${NOT_INCLUDED})
        find_library(FOUND ${LIB})
        if(EXISTS ${FOUND})
          set(LOCAL_WO "${LOCAL_WO}\n- ${FOUND}" )
        endif()
        unset (FOUND CACHE)
      endif()
    endforeach(LIB)
  endforeach(MODULE)

  file(APPEND ${CMAKE_BINARY_DIR}/linkings.yml ${LOCAL_WO})

endfunction(esrocos_add_dependency)

# CMake function to build an ASN.1 types package in ESROCOS
#
# Usage:
#       esrocos_asn1_types_package(<name>
#           [[ASN1] <file.asn> ...]
#           [OUTDIR <dir>]
#           [IMPORT <pkg> ...])
#
# Where <name> is the name of the created package, <file.asn> are the 
# ASN.1 type files that compose the package, and <pkg> are the names 
# of existing ASN.1 type packages on which <name> depends. The names 
# are relative to the ESROCOS install directory (e.g., types/base).
# <dir> is the directory where the C files compiled from ASN.1 are 
# written, relative to ${CMAKE_CURRENT_BINARY_DIR} (by default, <name>).
#
# Creates the following targets:
#  - <name>_timestamp: command to compile the ASN.1 files to C creating
#    a timestamp file.
#  - <name>_generate_c: compile the ASN.1 files, checking the timestamp
#    file to recompile only when the input files are changed.
#
# Creates the following cache variables:
#  - <name>_ASN1_SOURCES: ASN.1 files to install
#  - <name>_C_SOURCES: C source files with encoder/decoder functions and
#    constant definitions generated by the ASN.1 compiler.
#  - <name>_TEST_SOURCES: C source files generated by the ASN.1 
#    compiler for unit testing (including the tested encoder/decoder 
#    functions) and the common functions in real.c, etc.
#  - <name>_INCLUDE_DIR: directory where the C source are located.
#


# In order to generate the lists of C files, a first compilation of the
# ASN.1 input files is performed at the CMake configuration stage.
#           
function(esrocos_asn1_types_package NAME)

    # Process optional arguments
    set(MODE "ASN1")
    set(ASN1_OUT_DIR "${CMAKE_CURRENT_BINARY_DIR}/${NAME}")
    file(MAKE_DIRECTORY ${ASN1_OUT_DIR})
    set(ASN1_COMPILER "$ENV{HOME}/tool-inst/share/asn1scc/asn1.exe" CACHE STRING "ASN compiler location")
    set(ASN1_PREFIX "asn1Scc" CACHE STRING "ASN type prefix")
    foreach(ARG ${ARGN})
        if(ARG STREQUAL "ASN1")
            # Set next argument mode to ASN1 file
            set(MODE "ASN1")
        elseif(ARG STREQUAL "IMPORT")
            # Set next argument mode to IMPORT package
            set(MODE "IMPORT")
        elseif(ARG STREQUAL "OUTDIR")
            # Set next argument mode to output directory
            set(MODE "OUTDIR")
        else()
            # File or package name
            if(MODE STREQUAL "ASN1")
                # Add file (path relative to CMAKE_CURRENT_SOURCE_DIR)
                list(APPEND ASN1_LOCAL "${CMAKE_CURRENT_SOURCE_DIR}/${ARG}")
            elseif(MODE STREQUAL "IMPORT")
                # Add imported package
                list(APPEND IMPORTS ${ARG})
            elseif(MODE STREQUAL "OUTDIR")
                # Add imported package
                set(ASN1_OUT_DIR "${ARG}")
                file(MAKE_DIRECTORY "${PROJECT_BINARY_DIR}/${ARG}")
            else()
                # Unexpected mode
                message(FATAL_ERROR "Internal error at esrocos_asn1_types_package(${NAME}): wrong mode ${MODE}.")
            endif()
        endif()
    endforeach()

    # Read the .asn files from the imported packages, assumed to be at
    # ${CMAKE_INSTALL_PREFIX}/types/${PKG}
    foreach(PKG ${IMPORTS})
        file(GLOB NEW_IMPORTS "${CMAKE_INSTALL_PREFIX}/${PKG}/*.asn")
        list(APPEND ASN1_IMPORTS ${NEW_IMPORTS})
    endforeach()

    # List of .asn files to be compiled: local + imported
    list(APPEND ASN1_FILES ${ASN1_LOCAL} ${ASN1_IMPORTS})

    # Timestamp file
    set(${NAME}_timestamp ${CMAKE_CURRENT_BINARY_DIR}/timestamp)

    # First compilation, needed to build the lists of C files
    if(NOT EXISTS ${NAME}_timestamp)
        execute_process(
            COMMAND ${CMAKE_COMMAND} -E make_directory ${ASN1_OUT_DIR}
            COMMAND mono ${ASN1_COMPILER} -c -typePrefix ${ASN1_PREFIX} -uPER -wordSize 8 -ACN -o ${ASN1_OUT_DIR} -atc ${ASN1_FILES}
            RESULT_VARIABLE ASN1SCC_RESULT
        )

        if(${ASN1SCC_RESULT} EQUAL 0)
            execute_process(
                COMMAND ${CMAKE_COMMAND} -E touch ${NAME}_timestamp
            )
            message(STATUS "ASN.1 first compilation successful.")
        else()
            message(FATAL_ERROR "ASN.1 first compilation failed.")
        endif()
    endif()


    # Command for C compilation; creates timestamp file
    add_custom_command(OUTPUT ${NAME}_timestamp
        COMMAND ${CMAKE_COMMAND} -E make_directory ${ASN1_OUT_DIR}
        COMMAND mono ${ASN1_COMPILER} -c -typePrefix ${ASN1_PREFIX} -uPER -wordSize 8 -ACN -o ${ASN1_OUT_DIR} -atc ${ASN1_FILES}
        COMMAND ${CMAKE_COMMAND} -E touch ${NAME}_timestamp
        DEPENDS ${ASN1_FILES}
        COMMENT "Generate header files for: ${ASN1_IMPORTS} ${ASN1_FILES} in ${ASN1_OUT_DIR}"
    )

    # Target for C compilation; uses stamp file to run dependent targets only if changed
    add_custom_target(
        ${NAME}_generate_c
        DEPENDS ${NAME}_timestamp
    )

    # Get generated .c files 
    file(GLOB C_FILES "${ASN1_OUT_DIR}/*.c")
    
    # Get the types .c files, excluding common and test cases
    foreach(F ${C_FILES})
        if (NOT ${F} MATCHES "testsuite.c|mainprogram.c|.*_auto_tcs\\.c")
            list(APPEND C_SOURCES ${F})
        endif()
    endforeach()

    # Export variables
    set(${NAME}_ASN1_SOURCES ${ASN1_LOCAL} CACHE INTERNAL "${NAME}_ASN1_SOURCES" FORCE)
    set(${NAME}_C_SOURCES ${C_SOURCES} CACHE INTERNAL "${NAME}_C_SOURCES" FORCE)
    set(${NAME}_TEST_SOURCES ${C_FILES} CACHE INTERNAL "${NAME}_TEST_SOURCES" FORCE)
    set(${NAME}_INCLUDE_DIR ${ASN1_OUT_DIR} CACHE INTERNAL ${NAME}_INCLUDE_DIR FORCE)
    
    message(STATUS "set cache variable ${NAME}_ASN1_SOURCES")
    message(STATUS "set cache variable ${NAME}_C_SOURCES")
    message(STATUS "set cache variable ${NAME}_TEST_SOURCES")
    message(STATUS "set cache variable ${NAME}_INCLUDE_DIR")

endfunction(esrocos_asn1_types_package)


# CMake function to create an executable for the encoder/decoder unit
# tests generated by the ASN.1 compiler.
#
# Usage:
#       esrocos_asn1_types_test(<name>)
#
# Where <name> is the name of an ASN.1 types package created with the 
# function esrocos_asn1_types_package.
#   
function(esrocos_asn1_types_build_test NAME)
    
    if(DEFINED ${NAME}_ASN1_SOURCES)
        # Unit tests executable
        add_executable(${NAME}_test ${${NAME}_TEST_SOURCES})
        add_dependencies(${NAME}_test ${NAME}_generate_c)
    else()
        message(FATAL_ERROR "esrocos_asn1_types_test(${NAME}): ${NAME}_TEST_SOURCES not defined. Was esrocos_asn1_types_package called?")
    endif()
    
endfunction(esrocos_asn1_types_build_test)


# CMake function to install the ASN.1 type files into the ESROCOS 
# install directory.
#
# Usage:
#       esrocos_asn1_types_install(<name> [<prefix>])
#
# Where <name> is the name of an ASN.1 types package created with the 
# function esrocos_asn1_types_package, and <prefix> is the install
# directory (by default, ${CMAKE_INSTALL_PREFIX}/types/<name>).
#   
function(esrocos_asn1_types_install NAME)

    # Set prefix: 2nd argument or default
    if(ARGC EQUAL 1)
        set(PREFIX "${CMAKE_INSTALL_PREFIX}/types/${NAME}")
    elseif(ARGC EQUAL 2)
        set(PREFIX "${ARGV1}")
    else()
        message(FATAL_ERROR "Wrong number of arguments at esrocos_asn1_types_install(${NAME})")
    endif()
    
    if(DEFINED ${NAME}_ASN1_SOURCES)
        # Install ASN.1 files
        install(FILES ${${NAME}_ASN1_SOURCES} DESTINATION ${PREFIX})
    else()
        message(FATAL_ERROR "esrocos_asn1_types_install(${NAME}): ${NAME}_ASN1_SOURCES not defined. Was esrocos_asn1_types_package called?")
    endif()
    
endfunction(esrocos_asn1_types_install)


# CMake function to create a target dependency on a library to be 
# located with pkg-config. It tries to find the library, and applies 
# the library's include and link options to the target.
#
# Usage:
#       esrocos_pkgconfig_dependency(<target> [<pkgconfig_dep_1> <pkgconfig_dep_2>...])
#
# Where <target> is the name of the CMake library or executable target, 
# and <pkgconfig_dep_N> are the pkg-config packages on which it depends.
#   
function(esrocos_pkgconfig_dependency TAR)
    foreach(PKG ${ARGN})
        pkg_search_module(${PKG} REQUIRED ${PKG})
        if(${PKG}_FOUND)
            target_link_libraries(${TAR} PUBLIC ${${PKG}_LIBRARIES})
            target_include_directories(${TAR} PUBLIC ${${PKG}_INCLUDE_DIRS})
            target_compile_options(${TAR} PUBLIC ${${PKG}_CFLAGS_OTHER})
        else()
            message(SEND_ERROR "Cannot find pkg-config package ${PKG} required by ${TAR}.")
        endif()
    endforeach()
endfunction(esrocos_pkgconfig_dependency)


# Install a symlink
macro(install_symlink filepath sympath)
    install(CODE "message(\"-- Creating symlink: ${sympath} -> ${filepath}\")")
    install(CODE "execute_process(COMMAND ${CMAKE_COMMAND} -E create_symlink ${filepath} ${sympath})")
endmacro(install_symlink)


# CMAKE function to install files in the ESROCOS install folder.
#
# ESROCOS packages that contain TASTE models may define their own ASN.1
# data types. In order to be able to build the TASTE model locally and 
# to use it as a reusable component, the types used in the Data View 
# must be available in the install folder before the TASTE model is 
# built. This function can be called to preinstall local ASN.1 files 
# in the install folder.
#
# Usage:
#   esrocos_preinstall_files(<target> <dest_dir> <files...>)
# 
# Creates <target> that copies <files...> to <dest_dir>, where
# <dest_dir> is relative to the CMAKE_INSTALL_PREFIX.
#
function(esrocos_preinstall_files TAR DEST)

    set(FULLDEST ${CMAKE_INSTALL_PREFIX}/${DEST})

    set(SOURCES "")
    set(DESTINATIONS "")
    foreach(f ${ARGN})
        get_filename_component(barename ${f} NAME)
        if(IS_ABSOLUTE ${f})
            list(APPEND SOURCES ${f})
        else()
            list(APPEND SOURCES ${CMAKE_CURRENT_SOURCE_DIR}/${f})
        endif()
        list(APPEND DESTINATIONS ${FULLDEST}/${barename})
    endforeach()


    add_custom_command(OUTPUT ${DESTINATIONS}
        DEPENDS ${SOURCES}
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
        COMMAND ${CMAKE_COMMAND} -E make_directory ${FULLDEST}
        COMMAND ${CMAKE_COMMAND} -E copy ${SOURCES} ${FULLDEST}
        COMMENT "Preinstalling ${ARGN} in ${DEST}"
    )

    add_custom_target(${TAR} DEPENDS ${DESTINATIONS})

endfunction(esrocos_preinstall_files)


# CMake function to build a TASTE model.
#
# Usage:
#   esrocos_build_taste(<component_name> SOURCES <src_dirs> OUTPUT <binaries>)
#
# where:
#   <component_name> is the name of the TASTE component to be exported
#   (it will contain all the functions in the IV),
#   <src_dirs> are the names of the directories containing the 
#   function implementations, and
#   <binaries> are the paths of the expected binaries to be generated
#   (this is needed to ensure that the model is built successfully).
#
# The function creates a target named <component_name>.
#
# In order to be able to build the TASTE model in the CMake build 
# directory, the model must use ASN.1 files that exist in a fixed 
# full path independent from the model's directory. The function 
# esrocos_preinstall_files may be used to copy the ASN.1 files to the 
# ESROCOS install directory, where they are available for the model 
# independently of its location.
#
# Furthermore, in order to use the functions as TASTE reusable 
# components, the property "Source text" of each function must be 
# set to "<lowercase_function_name>.zip".
#
function(esrocos_build_taste COMPONENT)

    # Parse arguments
    set(SOURCES "")
    set(BINARIES "")
    set(MODE "NONE")
    foreach(ARG ${ARGN})
        if(ARG STREQUAL "SOURCES")
            # Set next argument mode to source directory
            set(MODE "SOURCES")
        elseif(ARG STREQUAL "BINARIES")
            # Set next argument mode to expected binaries
            set(MODE "BINARIES")
        else()
            # File or package name
            if(MODE STREQUAL "SOURCES")
                list(APPEND SOURCES ${ARG})
            elseif(MODE STREQUAL "BINARIES")
                list(APPEND BINARIES ${ARG})
            else()
                # Unexpected mode
                message(FATAL_ERROR "esrocos_build_taste(${NAME}): unexpected argument.")
            endif()
        endif()
    endforeach()
    
    if(NOT SOURCES)
        message(FATAL_ERROR "esrocos_build_taste(${NAME}): no SOURCES specified.")
    elseif(NOT BINARIES)
        message(FATAL_ERROR "esrocos_build_taste(${NAME}): no BINARIES specified.")
    endif() 
    
    # Copy model to build directory
    file(GLOB AADL "*.aadl")
    file(GLOB AADL_EXCLUDE "__*.aadl")
    list(REMOVE_ITEM AADL ${AADL_EXCLUDE})
    file(GLOB USER "user_init_*.sh")
    file(COPY ${AADL} ${USER} build-script.sh DESTINATION .)
    foreach(S ${SOURCES})
        file(COPY ${S} DESTINATION .)
    endforeach()

    # Command to run the build script
    add_custom_command(OUTPUT ${BINARIES}
        COMMAND ${CMAKE_CURRENT_BINARY_DIR}/build-script.sh
        DEPENDS ${SOURCES} ${AADL} ${USER}
        COMMENT "Run build-script.sh for ${COMPONENT}"
    )

    # Prepare Interface View for component export
    add_custom_command(OUTPUT export/interfaceview.aadl
        COMMAND ${CMAKE_COMMAND} -E make_directory export
        COMMAND sed 's/interfaceview/${COMPONENT}/g' InterfaceView.aadl > export/interfaceview.aadl
        DEPENDS InterfaceView.aadl
        COMMENT "Generate export/interfaceview.aadl for ${COMPONENT}"
    )
    
    # Target to build and prepare export
    add_custom_target(${COMPONENT} ALL
        DEPENDS ${BINARIES} export/interfaceview.aadl
    )

    # Install export files
    set(ZIPS "")
    foreach(S ${SOURCES})
        list(APPEND ZIPS ${S}.zip)
    endforeach()
    
    set(ESROCOS_COMPONENT ${CMAKE_INSTALL_PREFIX}/share/taste_components/${COMPONENT})
    
    install(FILES
        ${CMAKE_CURRENT_BINARY_DIR}/DataView.aadl
        ${CMAKE_CURRENT_BINARY_DIR}/export/interfaceview.aadl
        ${CMAKE_CURRENT_BINARY_DIR}/${ZIPS}
        ${USER}
        DESTINATION
        ${ESROCOS_COMPONENT}
    )

endfunction(esrocos_build_taste)


