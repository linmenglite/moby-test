#!/usr/bin/env bash

set -euo pipefail

GO_VERSION="1.21.11"
GO_BASE_URL="https://golang.google.cn/dl"
REPO_URL="https://gitee.com/mahaoliang/moby.git"
REPO_DIR="src/github.com/docker/docker"

# 检测平台架构
ARCH=$(uname -m)

# 根据架构设置下载URL
case "$ARCH" in
    x86_64)
        GO_TAR="go${GO_VERSION}.linux-amd64.tar.gz"
        ;;
    loongarch64)
        GO_TAR="go${GO_VERSION}.linux-loong64.tar.gz"
        ;;
    aarch64)
        GO_TAR="go${GO_VERSION}.linux-arm64.tar.gz"
        ;;
    riscv64)
        GO_TAR="go${GO_VERSION}.linux-riscv64.tar.gz"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

GO_URL="${GO_BASE_URL}/${GO_TAR}"

# 输出当前平台和安装包名称
echo "Current platform: $ARCH"
echo "Download package: $GO_TAR"

BASE_DIR=$(cd "$(dirname "$0")"; pwd)
cd ${BASE_DIR}

# 如果不存在go${GO_VERSION}目录，则下载并解压
if [ ! -d "go${GO_VERSION}" ]; then
    # 下载Go安装包
    echo "Downloading Go from ${GO_URL}..."
    curl -LO ${GO_URL}

    # 解压安装包
    echo "Extracting Go..."
    tar -xzf ${GO_TAR}

    # 移动并重命名解压后的目录
    mv go go${GO_VERSION}
else
    echo "Directory go${GO_VERSION} already exists. Skipping download."
fi

# 更新PATH环境变量
export PATH=${BASE_DIR}/go${GO_VERSION}/bin:$PATH

# 验证安装
echo "Go installation completed. Version:"
go version


# 设置Go环境变量
export GOTOOLCHAIN=local
export GO111MODULE=off
export GOPATH=${BASE_DIR}/gopath
export GOROOT=${BASE_DIR}/go${GO_VERSION}
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# 创建GOPATH目录
mkdir -p ${GOPATH}

# 创建存储库目录
REPO_PATH="${GOPATH}/${REPO_DIR}"
if [ ! -d "${REPO_PATH}" ]; then
    echo "Creating directory ${REPO_PATH}..."
    mkdir -p ${REPO_PATH}

    # 克隆存储库
    echo "Cloning repository from ${REPO_URL}..."
    git clone ${REPO_URL} ${REPO_PATH}
else
    echo "Directory ${REPO_PATH} already exists. Skipping repository clone."
fi

# 切换到存储库目录
cd ${REPO_PATH}

# 设置测试标志和目录
BUILDFLAGS=" "
TESTFLAGS+=" -test.timeout=${TIMEOUT:-30m}"
TESTDIRS="${TESTDIRS:-./...}"
exclude_paths='/vendor/|/integration'
pkg_list=$(go list $TESTDIRS | grep -vE "($exclude_paths)")

base_pkg_list=$(echo "${pkg_list}" | grep --fixed-strings -v "/libnetwork" || :)
libnetwork_pkg_list=$(echo "${pkg_list}" | grep --fixed-strings "/libnetwork" || :)

reports=${BASE_DIR}/reports/$(date +%Y%m%d%H%M%S)

mkdir -p ${reports}

run_performance_counter() {
    ${BASE_DIR}/performance_counter_920.sh "${1}" "${2}"
}

## 运行基础单元测试
if [ -n "${base_pkg_list}" ]; then
    set +e
    go clean -testcache
    go test -v ${BUILDFLAGS} ${TESTFLAGS} ${base_pkg_list} | tee "${reports}/test_base_result"
    go clean -testcache
    run_performance_counter "go test -v ${BUILDFLAGS} ${TESTFLAGS} ${base_pkg_list}" "${reports}/test_base_perf"
    set -e
fi

## 运行libnetwork相关的单元测试
if [ -n "${libnetwork_pkg_list}" ]; then
    # libnetwork tests invoke iptables, and cannot be run in parallel. Execute
    # tests within /libnetwork with '-p=1' to run them sequentially. See
    # https://github.com/moby/moby/issues/42458#issuecomment-873216754 for details.
    # Run performance counter script before tests
    set +e
    go clean -testcache
    go test -v ${BUILDFLAGS} -p=1 ${TESTFLAGS} ${libnetwork_pkg_list} | tee "${reports}/test_libnetwork_result"
    go clean -testcache
    run_performance_counter "go test -v ${BUILDFLAGS} -p=1 ${TESTFLAGS} ${libnetwork_pkg_list}" "${reports}/test_libnetwork_perf"
    set -e
fi

# 定义一个函数来分析和打印测试结果
analyze_test_results() {
    result_file=$1
    echo "Analyzing test results in ${result_file}"

    # 检查文件是否存在
    if [[ ! -f "$result_file" ]]; then
        echo "File not found: $result_file"
        return 1
    fi

    set +e

    # 统计通过的测试用例数
    total_passes=$(grep -- '- PASS:' "$result_file" | wc -l)

    # 统计失败的测试用例数
    total_fails=$(grep -- '- FAIL:' "$result_file" | wc -l)

    # 总测试用例数为通过和失败的总和
    total_tests=$((total_passes + total_fails))

    echo "Total tests: $total_tests"
    echo "Passed tests: $total_passes"
    echo "Failed tests: $total_fails"

    set -e
}


# 分析base和libnetwork测试结果
# 计算base_pkg_list中包的数量
base_pkg_count=$(echo "$base_pkg_list" | wc -l)
echo "Number of packages in base_pkg_list: $base_pkg_count"
analyze_test_results "${reports}/test_base_result"

# 计算blibnetwork_pkg_list中包的数量
libnetwork_pkg_count=$(echo "$libnetwork_pkg_list" | wc -l)
echo "Number of packages in libnetwork_pkg_list: $libnetwork_pkg_count"
analyze_test_results "${reports}/test_libnetwork_result"
