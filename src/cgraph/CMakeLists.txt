set(CGRAPH_TARGET_OBJECTS)

# Add the cgraph source files
foreach(tgt cgraph build_ctg_graph ctg_graph walk_ctg_graph spanner splinter)
  add_library(${tgt} OBJECT ${tgt}.cpp)
  
  # Link with UPCXX libraries if available
  if(CMAKE_VERSION VERSION_GREATER_EQUAL 3.12)
    target_link_libraries(${tgt} ${UPCXX_LIBRARIES} ${UPCXX_UTILS_LIBRARIES})
  endif()
  
  # Append target objects for later use
  list(APPEND CGRAPH_TARGET_OBJECTS $<TARGET_OBJECTS:${tgt}>)
endforeach()

# Create the main cgraph library
add_library(CGRAPH_LIBRARY ${CGRAPH_TARGET_OBJECTS})

# Include directories for cgraph
include_directories(${CMAKE_CURRENT_SOURCE_DIR})

# Handle Kokkos configurations if enabled
if(ENABLE_KOKKOS)
  target_link_libraries(CGRAPH_LIBRARY Kokkos::kokkos)
  include_directories("cgraph-kokkos")  # Prepare for future Kokkos implementation
endif()

# Link the main CGRAPH_LIBRARY with the necessary libraries
target_link_libraries(CGRAPH_LIBRARY ${UPCXX_LIBRARIES} ${UPCXX_UTILS_LIBRARIES})
