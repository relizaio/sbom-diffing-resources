cmake_minimum_required(VERSION 3.20)
project(calc_cli CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(fmt CONFIG REQUIRED)
find_package(CLI11 CONFIG REQUIRED)

add_executable(calc_cli
    src/main.cpp
    src/calculator.cpp
    src/utils.cpp
)

target_include_directories(calc_cli PRIVATE src)
target_link_libraries(calc_cli PRIVATE fmt::fmt CLI11::CLI11)
