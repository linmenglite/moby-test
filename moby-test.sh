#!/usr/bin/env bash

set -euo pipefail


# 切换到存储库目录
cd $GOPATH/src/github.com/moby

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
