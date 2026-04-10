#!/bin/bash

# 这个脚本在 Docker 容器内执行，完成 Xilinx xc7a35tfgg484-2 类 FPGA 项目的编译流程，不包含烧录步骤
# 把下面的变量按情况修改成你自己的项目结构和文件名
# 先 docker-compose up -d 启动容器
# 然后 docker exec -it fpga_openxc7_env "docker/compile.sh" 即可执行编译
# 最终生成的设计文件会保存在 $BUILD_DIR/design.bit 中，之后可以使用 openFPGALoader 烧录到 FPGA 上

set -e

# 一些文件
# workdir 是 docker/ 目录的父目录，也就是项目根目录
PROJ_NAME="QKD-BB84-FPGA-Control"
TOP_MODULE="top"
SRC_FILE="user/src/*.v"
XDC_FILE="user/data/top.xdc"
BUILD_DIR="build"

# 建立构建目录
PROJ_BUILD_DIR="$BUILD_DIR/$PROJ_NAME"
mkdir -p $PROJ_BUILD_DIR

# 1. 逻辑综合
yosys -p "synth_xilinx -flatten -abc9 -arch xc7 -top $TOP_MODULE; write_json $PROJ_BUILD_DIR/design.json" $SRC_FILE 2>&1 | tee $PROJ_BUILD_DIR/yosys.log

# 2. 生成芯片架构数据库 chipdb
if [ ! -f "$PROJ_BUILD_DIR/xc7a35t.bin" ]; then
    echo "Generating chipdb for xc7a35tfgg484-2..."
    # 提取器件数据并生成 BBA 文本文件
    pypy3 /nextpnr-xilinx/xilinx/python/bbaexport.py --device xc7a35tfgg484-2 --bba $PROJ_BUILD_DIR/xc7a35t.bba
    # 将 BBA 文本编译为 nextpnr 可读的 BIN 二进制文件
    bbasm -l $PROJ_BUILD_DIR/xc7a35t.bba "$PROJ_BUILD_DIR/xc7a35t.bin"
    # 删除庞大的临时中间文件以节省空间
    rm -f $PROJ_BUILD_DIR/xc7a35t.bba
fi

# 3. 物理布局布线
nextpnr-xilinx --chipdb "$PROJ_BUILD_DIR/xc7a35t.bin" --xdc $XDC_FILE --json $PROJ_BUILD_DIR/design.json --write $PROJ_BUILD_DIR/design_routed.json --fasm $PROJ_BUILD_DIR/design.fasm
# 4. 生成比特流
/prjxray/env/bin/fasm2frames --part xc7a35tfgg484-2 --db-root /nextpnr-xilinx/xilinx/external/prjxray-db/artix7 $PROJ_BUILD_DIR/design.fasm > $PROJ_BUILD_DIR/design.frames
xc7frames2bit --part_file /nextpnr-xilinx/xilinx/external/prjxray-db/artix7/xc7a35tfgg484-2/part.yaml --part_name xc7a35tfgg484-2 --frm_file $PROJ_BUILD_DIR/design.frames --output_file $PROJ_BUILD_DIR/design.bit
echo "FPGA design compiled successfully! The bitstream is located at: $PROJ_BUILD_DIR/design.bit"
