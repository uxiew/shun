# 插件自己的一小段 JNI：开 PTY、fork + exec 随 APK 安装的 mosh-client、改窗口尺寸、等子进程退出。
cmake_minimum_required(VERSION 3.22)
project(moshpty C)
add_library(moshpty SHARED moshpty.c)
target_compile_options(moshpty PRIVATE -Wall -Wextra -Werror -O2)
# 16 KiB 页设备（Android 15+）要求 LOAD 段 16 KiB 对齐；NDK r28 默认就是，这里写明，换 NDK 也不退回 4 KiB。
target_link_options(moshpty PRIVATE -Wl,-z,max-page-size=16384)
target_link_libraries(moshpty log)
