cmake_minimum_required(VERSION 3.4.1)

# Create native library
add_library(paddle_ocr SHARED
    paddle_ocr_jni.cpp)

# Include directories
target_include_directories(paddle_ocr PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
)

# Link ONNX Runtime Mobile
find_library(onnxruntime-lib onnxruntime)

# Link libraries
target_link_libraries(paddle_ocr
    android
    log
    jnigraphics
    ${onnxruntime-lib}
)
