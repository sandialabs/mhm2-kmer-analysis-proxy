# Specify the source files for the future Kokkos implementation
set(SRCS
    kokkos_cgraph.cpp          # Future Kokkos implementation of cgraph
    kokkos_ctg_graph.cpp       # Future Kokkos implementation of ctg_graph
    kokkos_walk_ctg_graph.cpp   # Future Kokkos implementation of walk_ctg_graph
    kokkos_spanner.cpp         # Future Kokkos implementation of spanner
    kokkos_splinter.cpp        # Future Kokkos implementation of splinter
    kokkos_build_ctg_graph.cpp # Future Kokkos implementation of build_ctg_graph
)

# Create an object library for the Kokkos implementation
add_library(CGRAPH_KOKKOS_LIBRARY_obj OBJECT ${SRCS})

# Link with UPCXX libraries if available
if(CMAKE_VERSION VERSION_GREATER_EQUAL 3.12)
    target_link_libraries(CGRAPH_KOKKOS_LIBRARY_obj ${UPCXX_LIBRARIES} ${UPCXX_UTILS_LIBRARIES})
endif()

# Create a static library from the object library
add_library(CGRAPH_KOKKOS_LIBRARY_static STATIC
                $<TARGET_OBJECTS:CGRAPH_KOKKOS_LIBRARY_obj>)

# Link Kokkos to the static library if enabled
if(ENABLE_KOKKOS)
    target_link_libraries(CGRAPH_KOKKOS_LIBRARY_static Kokkos::kokkos)
endif()

# Install the static library
install(TARGETS CGRAPH_KOKKOS_LIBRARY_static ARCHIVE DESTINATION lib)

# Link the object library with Kokkos and UPCXX libraries
target_link_libraries(CGRAPH_KOKKOS_LIBRARY_obj ${UPCXX_LIBRARIES} ${UPCXX_UTILS_LIBRARIES})
